// @i-know-the-amp-plugin-api-is-wip-and-very-experimental-right-now
import type { PluginAPI } from '@ampcode/plugin'
import { spawnSync } from 'node:child_process'
import { randomUUID, createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const PLUGIN_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..')
const CERBERUS_ROOT = process.env.CERBERUS_ROOT || PLUGIN_ROOT
const REVIEW_GATE_BIN = process.env.CERBERUS_REVIEW_GATE_BIN || resolve(CERBERUS_ROOT, 'bin', 'review-gate')
const COMMANDS = ['review-code', 'review-plan', 'review-spec', 'ask-panel', 'status', 'clear-gate'] as const
const AMP_THREAD_RE = /^T-[a-f0-9]+(-[a-f0-9]+)*$/

type CerberusCommand = (typeof COMMANDS)[number] | 'ask'

interface AmpSession {
	workspaceRoot: string
	projectKey: string
	runKey: string
	threadID: string
	registryPath: string
	explicitOverride: boolean
}

interface RegistryState {
	schema_version: number
	host: 'amp'
	workspace_root: string
	project_key: string
	run_key: string
	amp_thread_id: string | null
	last_seen: string
	last_blocking_fingerprint?: string
}

interface BackendResult {
	stdout: string
	stderr: string
	exitCode: number
}

interface CompletionDecision {
	decision?: 'allow' | 'continue'
	reason?: string
	userMessage?: string
	run_key?: string
	fingerprint?: string
	pending_count?: number
	finding_count?: number
}

interface ThreadLike {
	id?: string
	append?: (messages: { type: 'user-message'; content: string }[]) => Promise<unknown> | unknown
}

interface PollResult {
	done: boolean
	notified: boolean
	retry?: boolean
}

interface MonitorState {
	handle?: NodeJS.Timeout
	stopped: boolean
}

const REVIEW_SPAWNING_COMMANDS = new Set<CerberusCommand>(['review-code', 'review-plan', 'review-spec'])
const MONITORS = new Map<string, MonitorState>()
const NOTIFIED_KEYS = new Map<string, number>()
const THREAD_CACHE = new Map<string, ThreadLike>()
const MONITOR_INTERVAL_MS = Math.max(500, Number(process.env.CERBERUS_AMP_MONITOR_INTERVAL_MS) || 5000)
const MONITOR_DEADLINE_MS = Math.max(MONITOR_INTERVAL_MS, Number(process.env.CERBERUS_AMP_MONITOR_DEADLINE_MS) || 30 * 60_000)
const STATUS_POLL_TIMEOUT_MS = Math.max(500, Number(process.env.CERBERUS_AMP_STATUS_TIMEOUT_MS) || 3000)
const NOTIFIED_KEYS_TTL_MS = Math.max(MONITOR_DEADLINE_MS, 2 * 60 * 60_000)

function pruneNotifiedKeys(): void {
	if (NOTIFIED_KEYS.size < 64) return
	const cutoff = Date.now() - NOTIFIED_KEYS_TTL_MS
	for (const [key, ts] of NOTIFIED_KEYS) {
		if (ts < cutoff) NOTIFIED_KEYS.delete(key)
	}
}

function workspaceRoot(): string {
	if (process.env.CERBERUS_AMP_WORKSPACE) return process.env.CERBERUS_AMP_WORKSPACE
	const git = spawnSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' })
	if (git.status === 0 && git.stdout.trim()) return git.stdout.trim()
	return process.cwd()
}

function projectKeyForWorkspace(root: string): string {
	if (process.env.CERBERUS_PROJECT_KEY) return process.env.CERBERUS_PROJECT_KEY
	return root.replace(/^\//, '-').replaceAll('/', '-')
}

function validateProjectKey(projectKey: string): void {
	if (!projectKey || projectKey === '.' || projectKey === '..' || projectKey.includes('/')) {
		throw new Error(`invalid Cerberus project key: ${projectKey || '<empty>'}`)
	}
}

function homeDir(): string {
	return process.env.HOME || process.env.USERPROFILE || process.cwd()
}

function registryPathFor(projectKey: string): string {
	return resolve(homeDir(), '.cerberus', 'runtime', 'amp', projectKey, 'active-session.json')
}

function readRegistry(path: string): Partial<RegistryState> | null {
	try {
		if (!existsSync(path)) return null
		return JSON.parse(readFileSync(path, 'utf8')) as Partial<RegistryState>
	} catch {
		return null
	}
}

function writeRegistry(path: string, next: RegistryState): void {
	mkdirSync(dirname(path), { recursive: true })
	const tmp = `${path}.tmp.${process.pid}.${Date.now()}`
	writeFileSync(tmp, `${JSON.stringify(next, null, 2)}\n`, 'utf8')
	renameSync(tmp, path)
}

function isValidThreadID(threadID: string): boolean {
	return AMP_THREAD_RE.test(threadID)
}

function truthy(value: string | undefined): boolean {
	return /^(1|true|yes|on)$/i.test(value || '')
}

function threadIDFrom(event?: Record<string, unknown>, ctx?: Record<string, unknown>): string {
	const candidates = [ctx, event]
	for (const candidate of candidates) {
		const thread = candidate?.thread
		if (thread && typeof thread === 'object') {
			const id = (thread as Record<string, unknown>).id
			if (typeof id === 'string' && id) return id
		}
	}
	return process.env.AMP_THREAD_ID || process.env.AMP_CURRENT_THREAD_ID || ''
}

export function ensureAmpSession(event?: Record<string, unknown>, ctx?: Record<string, unknown>): AmpSession {
	const root = workspaceRoot()
	const projectKey = projectKeyForWorkspace(root)
	validateProjectKey(projectKey)

	const registryPath = registryPathFor(projectKey)
	const registry = readRegistry(registryPath)
	const explicitRunKey = process.env.CERBERUS_RUN_KEY || process.env.REVIEW_GATE_SESSION_KEY || ''
	const threadID = threadIDFrom(event, ctx)

	let runKey = explicitRunKey
	let registryThreadID: string | null = threadID && isValidThreadID(threadID) ? threadID : null

	if (!runKey) {
		const persistedRunKey = typeof registry?.run_key === 'string' ? registry.run_key : ''
		const persistedThreadID = typeof registry?.amp_thread_id === 'string' ? registry.amp_thread_id : ''

		if (threadID && isValidThreadID(threadID)) {
			runKey = threadID
			registryThreadID = threadID
		} else if (persistedRunKey) {
			runKey = persistedRunKey
			registryThreadID = persistedThreadID || null
		} else {
			runKey = randomUUID()
			registryThreadID = null
		}
	}

	// Only persist the registry when the run key was auto-derived. An explicit
	// CERBERUS_RUN_KEY / REVIEW_GATE_SESSION_KEY override must remain a one-shot
	// bypass and not corrupt the workspace's normal session tracking.
	if (!explicitRunKey) {
		const nextRegistry: RegistryState = {
			schema_version: 1,
			host: 'amp',
			workspace_root: root,
			project_key: projectKey,
			run_key: runKey,
			amp_thread_id: registryThreadID,
			last_seen: new Date().toISOString(),
		}
		if (registry?.run_key === runKey && typeof registry?.last_blocking_fingerprint === 'string') {
			nextRegistry.last_blocking_fingerprint = registry.last_blocking_fingerprint
		}
		writeRegistry(registryPath, nextRegistry)
	}

	return { workspaceRoot: root, projectKey, runKey, threadID, registryPath, explicitOverride: !!explicitRunKey }
}

function backendEnv(session: AmpSession): NodeJS.ProcessEnv {
	const env: NodeJS.ProcessEnv = { ...process.env }
	for (const key of Object.keys(env)) {
		if (key.startsWith('REVIEW_GATE_')) delete env[key]
	}
	delete env.CLAUDE_PLUGIN_ROOT
	delete env.CLAUDE_PROJECT_DIR
	delete env.CLAUDE_SESSION_ID
	delete env.CLAUDE_TRANSCRIPT_PATH

	return {
		...env,
		CERBERUS_HOST: 'amp',
		CERBERUS_ROOT,
		CERBERUS_STATE_ROOT: process.env.CERBERUS_STATE_ROOT || resolve(homeDir(), '.cerberus', 'projects'),
		CERBERUS_PROJECT_KEY: session.projectKey,
		CERBERUS_RUN_KEY: session.runKey,
		AMP_THREAD_ID: session.threadID || process.env.AMP_THREAD_ID || '',
		AMP_CURRENT_THREAD_ID: session.threadID || process.env.AMP_CURRENT_THREAD_ID || '',
	}
}

function runBackend(args: string[], session: AmpSession, options: { timeoutMs?: number } = {}): BackendResult {
	const result = spawnSync(REVIEW_GATE_BIN, args, {
		cwd: session.workspaceRoot,
		env: backendEnv(session),
		encoding: 'utf8',
		timeout: options.timeoutMs,
	})
	return {
		stdout: result.stdout || '',
		stderr: result.stderr || (result.error ? result.error.message : ''),
		exitCode: typeof result.status === 'number' ? result.status : 1,
	}
}

function stringList(value: unknown): string[] {
	if (Array.isArray(value)) return value.filter((item): item is string => typeof item === 'string' && item.length > 0)
	if (typeof value === 'string' && value) return value.split(',').map(part => part.trim()).filter(Boolean)
	return []
}

function reviewCodeArgs(input: Record<string, unknown>): string[] {
	const args = ['spawn-code-review']
	const agents = typeof input.agents === 'string' ? input.agents : ''
	const maxRounds = typeof input.max_rounds === 'number' ? input.max_rounds : undefined
	const mode = typeof input.mode === 'string' ? input.mode : ''
	const consensus = typeof input.consensus === 'string' ? input.consensus : ''
	const contextFile = typeof input.context_file === 'string' ? input.context_file : ''
	const focus = typeof input.focus === 'string' ? input.focus : ''
	const excludes = stringList(input.exclude)

	if (agents) args.push('--agents', agents)
	if (maxRounds !== undefined) args.push('--max-rounds', String(maxRounds))
	if (mode) args.push('--mode', mode)
	if (consensus) args.push('--consensus', consensus)
	if (contextFile) args.push('--context-file', contextFile)
	if (focus) args.push('--focus', focus)
	for (const exclude of excludes) args.push('--exclude', exclude)
	if (input.debate === true) args.push('--debate')

	const diffMode = typeof input.diff_mode === 'string' ? input.diff_mode : ''
	if (diffMode === 'uncommitted') {
		args.push('--uncommitted')
	} else if (diffMode === 'base') {
		const base = typeof input.base === 'string' ? input.base : ''
		if (!base) throw new Error('review-code diff_mode=base requires base')
		args.push('--base', base)
	} else if (diffMode === 'commit') {
		const commits = stringList(input.commits || input.commit)
		if (commits.length === 0) throw new Error('review-code diff_mode=commit requires commit or commits')
		args.push('--commit', ...commits)
	} else if (diffMode === 'range') {
		const range = typeof input.range === 'string' ? input.range : ''
		if (!range) throw new Error('review-code diff_mode=range requires range')
		args.push(range)
	} else if (diffMode) {
		throw new Error(`review-code unsupported diff_mode: ${diffMode}`)
	}

	return args
}

function backendArgsFor(command: CerberusCommand, input: Record<string, unknown>): string[][] {
	switch (command) {
		case 'review-code':
			return [reviewCodeArgs(input)]
		case 'review-plan': {
			const planPath = typeof input.plan_path === 'string' ? input.plan_path : ''
			if (!planPath) throw new Error('review-plan requires plan_path')
			return [['spawn-plan-review', planPath]]
		}
		case 'review-spec': {
			const specPath = typeof input.spec_path === 'string' ? input.spec_path : ''
			if (!specPath) throw new Error('review-spec requires spec_path')
			return [['spawn-spec-review', specPath]]
		}
		case 'ask':
		case 'ask-panel': {
			const question = typeof input.question === 'string' ? input.question : ''
			if (!question) throw new Error(`${command} requires question`)
			return [['spawn-ask', question], ['wait', '--json', '--finalize']]
		}
		case 'status':
			return [['status', '--json']]
		case 'clear-gate': {
			const reason = typeof input.reason === 'string' && input.reason ? input.reason : 'manual clear via Amp plugin'
			return [['resolve', '--reason', reason]]
		}
	}
}

function rememberThread(thread: ThreadLike | undefined): void {
	if (!thread || typeof thread !== 'object') return
	if (typeof thread.append !== 'function') return
	const id = typeof thread.id === 'string' ? thread.id : ''
	if (id) THREAD_CACHE.set(id, thread)
}

function extractThread(event?: Record<string, unknown>, ctx?: Record<string, unknown>): ThreadLike | undefined {
	let firstThread: ThreadLike | undefined
	for (const candidate of [ctx, event]) {
		const thread = candidate?.thread
		if (!thread || typeof thread !== 'object') continue
		const typed = thread as ThreadLike
		if (!firstThread) firstThread = typed
		if (typeof typed.append === 'function') {
			rememberThread(typed)
			return typed
		}
	}
	return firstThread
}

function persistedThreadIDFromRegistry(session: AmpSession): string {
	const registry = readRegistry(session.registryPath)
	return typeof registry?.amp_thread_id === 'string' ? registry.amp_thread_id : ''
}

function resolveThread(session: AmpSession, event?: Record<string, unknown>, ctx?: Record<string, unknown>): ThreadLike | undefined {
	const direct = extractThread(event, ctx)
	if (direct && typeof direct.append === 'function') return direct
	const candidates: string[] = []
	if (session.threadID) candidates.push(session.threadID)
	const persistedID = persistedThreadIDFromRegistry(session)
	if (persistedID && persistedID !== session.threadID) candidates.push(persistedID)
	if (session.runKey && !candidates.includes(session.runKey)) candidates.push(session.runKey)
	for (const id of candidates) {
		const cached = THREAD_CACHE.get(id)
		if (cached && typeof cached.append === 'function') return cached
	}
	return direct
}

async function appendThreadMessage(thread: ThreadLike, content: string): Promise<boolean> {
	if (typeof thread.append !== 'function') return false
	try {
		const result = thread.append([{ type: 'user-message', content }])
		if (result && typeof (result as Promise<unknown>).then === 'function') {
			await (result as Promise<unknown>)
		}
		return true
	} catch {
		return false
	}
}

function normalizeVerdict(raw: unknown): string {
	if (typeof raw !== 'string' || !raw) return ''
	const v = raw.toLowerCase()
	if (v === 'needs_work' || v === 'needs-revision') return 'needs_revision'
	return v
}

function formatReviewersCompleteMessage(session: AmpSession, body: Record<string, unknown>): string {
	const verdict = normalizeVerdict(body.consensus_verdict) || 'unknown'
	const findings = Array.isArray(body.aggregated_findings) ? (body.aggregated_findings as unknown[]).length : 0
	const gateStatus = typeof body.gate_status === 'string' && body.gate_status ? body.gate_status : 'unknown'
	const findingsLabel = findings === 1 ? '1 finding' : `${findings} findings`
	const reviewers = Array.isArray(body.reviewers) ? (body.reviewers as unknown[]) : []
	const failedReviewers = reviewers.filter(r => r && typeof r === 'object' && (r as Record<string, unknown>).status === 'failed').length
	const parseErrors = Array.isArray(body.parse_errors) ? (body.parse_errors as unknown[]).length : 0
	const needsAction = verdict === 'fail' || verdict === 'needs_revision' || verdict === 'unknown' || findings > 0 || failedReviewers > 0 || parseErrors > 0
	const tail = needsAction
		? 'Address the findings, or use clear-gate with an explicit reason if a human is overriding the gate.'
		: 'Reviewers passed; no action required.'
	const extras: string[] = []
	if (failedReviewers > 0) extras.push(`${failedReviewers} reviewer${failedReviewers === 1 ? '' : 's'} failed`)
	if (parseErrors > 0) extras.push(`${parseErrors} parse error${parseErrors === 1 ? '' : 's'}`)
	const extrasLabel = extras.length ? `; ${extras.join(', ')}` : ''
	return [
		`Cerberus reviewers complete for run ${session.runKey}.`,
		`Gate status: ${gateStatus}; verdict: ${verdict}; ${findingsLabel}${extrasLabel}.`,
		tail,
	].join(' ')
}

function reviewersTerminal(body: Record<string, unknown>): boolean {
	const reviewers = Array.isArray(body.reviewers) ? (body.reviewers as unknown[]) : []
	const reviewerStates = reviewers.filter((r): r is Record<string, unknown> => !!r && typeof r === 'object')
	const declaredPending = Array.isArray(body.pending_reviewers) ? (body.pending_reviewers as unknown[]).length : -1
	if (declaredPending > 0) return false
	const inferredPending = reviewerStates.filter(r => {
		const status = typeof r.status === 'string' ? r.status : ''
		return status === 'pending' || status === 'running' || status === ''
	}).length
	if (declaredPending === -1 && inferredPending > 0) return false
	const anyTerminal = reviewerStates.some(r => {
		const status = typeof r.status === 'string' ? r.status : ''
		return status === 'complete' || status === 'failed'
	})
	const hasConsensus = typeof body.consensus_verdict === 'string' && body.consensus_verdict !== ''
	return anyTerminal || hasConsensus
}

export async function pollCerberusOnce(session: AmpSession, thread: ThreadLike, isCurrent: () => boolean = () => true): Promise<PollResult> {
	let body: Record<string, unknown> | null = null
	try {
		const result = runBackend(['status', '--json'], session, { timeoutMs: STATUS_POLL_TIMEOUT_MS })
		if (result.exitCode === 4) return { done: true, notified: false }
		if (result.exitCode !== 0) return { done: false, notified: false, retry: true }
		body = JSON.parse(result.stdout) as Record<string, unknown>
	} catch {
		return { done: false, notified: false, retry: true }
	}
	if (!body) return { done: false, notified: false, retry: true }

	// Sanity: if status reports a different run key than ours, do not act on it.
	const reportedRunKey = typeof body.run_key === 'string' ? body.run_key : ''
	if (reportedRunKey && session.runKey && reportedRunKey !== session.runKey) {
		return { done: false, notified: false, retry: true }
	}

	const gateStatus = typeof body.gate_status === 'string' ? body.gate_status : ''
	const key = monitorKey(session)

	const tryNotify = async (): Promise<PollResult> => {
		if (NOTIFIED_KEYS.has(key)) return { done: true, notified: false }
		if (!isCurrent()) return { done: false, notified: false }
		const ok = await appendThreadMessage(thread, formatReviewersCompleteMessage(session, body!))
		if (!ok) return { done: false, notified: false, retry: true }
		// Re-check freshness after the async append: a stale in-flight tick
		// must not poison NOTIFIED_KEYS for a freshly-restarted monitor.
		if (!isCurrent()) return { done: true, notified: false }
		NOTIFIED_KEYS.set(key, Date.now())
		pruneNotifiedKeys()
		return { done: true, notified: true }
	}

	// Resolved gate is always terminal: either consensus passed (no message
	// needed) or human-handled. We still notify when findings remain or the
	// verdict is non-pass so the user knows action is required.
	if (gateStatus === 'resolved') {
		const verdict = normalizeVerdict(body.consensus_verdict)
		const findings = Array.isArray(body.aggregated_findings) ? (body.aggregated_findings as unknown[]).length : 0
		if (findings > 0 || (verdict && verdict !== 'pass')) {
			return await tryNotify()
		}
		return { done: true, notified: false }
	}

	if (!reviewersTerminal(body)) return { done: false, notified: false }
	return await tryNotify()
}

function monitorKey(session: AmpSession): string {
	return `${session.projectKey}:${session.runKey}`
}

export function markGateNotified(session: AmpSession): void {
	NOTIFIED_KEYS.set(monitorKey(session), Date.now())
	pruneNotifiedKeys()
}

function cancelMonitor(key: string): void {
	const state = MONITORS.get(key)
	if (!state) return
	state.stopped = true
	if (state.handle) clearTimeout(state.handle)
	MONITORS.delete(key)
}

export function startCerberusMonitor(session: AmpSession, thread: ThreadLike | undefined, options: { restart?: boolean } = {}): boolean {
	const key = monitorKey(session)
	// Cancel + dedupe-clear must happen before any early returns so a
	// review-* dispatch that lacks an append-capable thread still tears down
	// the previous monitor for this run key (no stale timer or NOTIFIED_KEYS
	// leakage).
	if (options.restart) {
		cancelMonitor(key)
		NOTIFIED_KEYS.delete(key)
	}
	if (truthy(process.env.CERBERUS_REVIEWER_SUBPROCESS)) return false
	if (truthy(process.env.CERBERUS_AMP_DISABLE_MONITOR)) return false
	if (!thread || typeof thread.append !== 'function') return false
	if (!options.restart) {
		if (NOTIFIED_KEYS.has(key)) return false
		if (MONITORS.has(key)) return false
	}
	rememberThread(thread)

	const state: MonitorState = { stopped: false }
	MONITORS.set(key, state)

	const deadlineAt = Date.now() + MONITOR_DEADLINE_MS
	const isCurrent = (): boolean => !state.stopped && MONITORS.get(key) === state
	const schedule = (delay: number): void => {
		if (!isCurrent()) return
		state.handle = setTimeout(tick, Math.max(50, delay))
		if (typeof state.handle.unref === 'function') state.handle.unref()
	}
	const tick = (): void => {
		state.handle = undefined
		;(async () => {
			let result: PollResult = { done: false, notified: false }
			try {
				result = await pollCerberusOnce(session, thread, isCurrent)
			} catch {
				result = { done: false, notified: false, retry: true }
			}
			if (!isCurrent()) return
			if (result.done && !result.retry) {
				MONITORS.delete(key)
				return
			}
			if (Date.now() >= deadlineAt) {
				MONITORS.delete(key)
				return
			}
			schedule(MONITOR_INTERVAL_MS)
		})().catch(() => {
			if (MONITORS.get(key) === state) MONITORS.delete(key)
		})
	}

	schedule(MONITOR_INTERVAL_MS)
	return true
}

export function stopCerberusMonitor(session: AmpSession): void {
	cancelMonitor(monitorKey(session))
}

export function executeCerberusCommand(command: CerberusCommand, input: Record<string, unknown> = {}, event?: Record<string, unknown>, ctx?: Record<string, unknown>): string {
	const session = ensureAmpSession(event, ctx)
	let output = `Cerberus run key: ${session.runKey}\n`
	for (const args of backendArgsFor(command, input)) {
		const result = runBackend(args, session)
		output += result.stdout
		if (result.stderr) output += result.stderr
		if (result.exitCode !== 0) {
			if (command === 'status' && result.exitCode === 4) continue
			throw new Error(`${output.trim()}\nCerberus backend exited ${result.exitCode}`)
		}
	}
	if (REVIEW_SPAWNING_COMMANDS.has(command)) {
		// New review on the same run key: drop the persisted loop fingerprint
		// so agent.end can surface a fresh blocking message for this gate.
		try { clearBlockingFingerprint(session) } catch { /* fail open */ }
		const thread = resolveThread(session, event, ctx)
		startCerberusMonitor(session, thread, { restart: true })
	}
	return output.trimEnd()
}

function inputSchemaFor(command: CerberusCommand): Record<string, unknown> {
	if (command === 'review-code') {
		return {
			type: 'object',
			properties: {
				diff_mode: { type: 'string', enum: ['uncommitted', 'base', 'commit', 'range'], description: 'Diff scope to review. Omit to use the backend default (--uncommitted).' },
				base: { type: 'string', description: 'Branch/ref for diff_mode=base, e.g. main.' },
				commit: { type: 'string', description: 'Single commit/ref for diff_mode=commit, e.g. HEAD.' },
				commits: { type: 'array', items: { type: 'string' }, description: 'One or more commits/refs for diff_mode=commit.' },
				range: { type: 'string', description: 'Git revision range for diff_mode=range, e.g. main..feature.' },
				agents: { type: 'string', description: 'Optional comma-separated reviewer list, e.g. codex,gemini.' },
				max_rounds: { type: 'number', description: 'Optional maximum review rounds.' },
				mode: { type: 'string', enum: ['fast', 'smart', 'max'], description: 'Optional reviewer model mode.' },
				consensus: { type: 'string', enum: ['majority', 'all', 'any'], description: 'Optional consensus policy.' },
				context_file: { type: 'string', description: 'Optional path to extra author context.' },
				focus: { type: 'string', description: 'Optional review focus instruction.' },
				exclude: { type: 'array', items: { type: 'string' }, description: 'Optional git pathspec exclusions.' },
				debate: { type: 'boolean', description: 'Enable debate mode.' },
			},
		}
	}
	if (command === 'review-plan') {
		return { type: 'object', properties: { plan_path: { type: 'string', description: 'Absolute path to the plan markdown file.' } }, required: ['plan_path'] }
	}
	if (command === 'review-spec') {
		return { type: 'object', properties: { spec_path: { type: 'string', description: 'Absolute path to the spec markdown file.' } }, required: ['spec_path'] }
	}
	if (command === 'ask' || command === 'ask-panel') {
		return { type: 'object', properties: { question: { type: 'string', description: 'Question to ask the Cerberus review panel.' } }, required: ['question'] }
	}
	if (command === 'clear-gate') {
		return { type: 'object', properties: { reason: { type: 'string', description: 'Optional audit reason for manually clearing the gate.' } } }
	}
	return { type: 'object', properties: {} }
}

function titleFor(command: CerberusCommand): string {
	return `Cerberus: ${command.split('-').map(part => part[0].toUpperCase() + part.slice(1)).join(' ')}`
}

async function inputForCommand(command: CerberusCommand, ctx: Record<string, unknown>): Promise<Record<string, unknown> | null> {
	const ui = (ctx.ui || {}) as { input?: (opts: Record<string, unknown>) => Promise<string | undefined>; notify?: (message: string) => Promise<void> }
	if (command === 'review-plan') {
		const value = await ui.input?.({ title: 'Cerberus Plan Path', helpText: 'Absolute path to the plan markdown file.', submitButtonText: 'Review Plan' })
		return value ? { plan_path: value } : null
	}
	if (command === 'review-spec') {
		const value = await ui.input?.({ title: 'Cerberus Spec Path', helpText: 'Absolute path to the spec markdown file.', submitButtonText: 'Review Spec' })
		return value ? { spec_path: value } : null
	}
	if (command === 'ask' || command === 'ask-panel') {
		const value = await ui.input?.({ title: 'Ask Cerberus Panel', helpText: 'Question to send to the reviewer panel.', submitButtonText: 'Ask Panel' })
		return value ? { question: value } : null
	}
	if (command === 'clear-gate') {
		const value = await ui.input?.({ title: 'Clear Cerberus Gate', helpText: 'Reason recorded in gate-state.json.', initialValue: 'manual clear via Amp plugin', submitButtonText: 'Clear Gate' })
		return { reason: value || 'manual clear via Amp plugin' }
	}
	return {}
}

function runCompletionCheck(event: Record<string, unknown>, ctx: Record<string, unknown>): CompletionDecision | null {
	const session = ensureAmpSession(event, ctx)
	const result = runBackend(['completion-check', '--host', 'amp', '--json'], session)
	if (result.exitCode !== 0) return null
	try {
		return JSON.parse(result.stdout) as CompletionDecision
	} catch {
		return null
	}
}

function fingerprintFor(decision: CompletionDecision): string {
	if (decision.fingerprint) return decision.fingerprint
	return createHash('sha256').update(JSON.stringify(decision)).digest('hex')
}

function clearBlockingFingerprint(session: AmpSession): void {
	const current = readRegistry(session.registryPath)
	if (!current || current.run_key !== session.runKey) return
	if (!current.last_blocking_fingerprint) return
	const persistedThreadID = typeof current.amp_thread_id === 'string' ? current.amp_thread_id : null
	writeRegistry(session.registryPath, {
		schema_version: 1,
		host: 'amp',
		workspace_root: session.workspaceRoot,
		project_key: session.projectKey,
		run_key: session.runKey,
		amp_thread_id: persistedThreadID,
		last_seen: new Date().toISOString(),
	})
}

function rememberBlockingFingerprint(session: AmpSession, fingerprint: string): void {
	const current = readRegistry(session.registryPath) || {}
	// Preserve the persisted run key when the caller is using an explicit
	// CERBERUS_RUN_KEY / REVIEW_GATE_SESSION_KEY override; the override must
	// remain a one-shot bypass and never rebind the workspace's normal
	// session tracking, even when the loop guard records a fingerprint.
	const persistedRunKey = typeof current.run_key === 'string' && current.run_key ? current.run_key : ''
	const persistedThreadID = typeof current.amp_thread_id === 'string' ? current.amp_thread_id : ''
	const runKey = session.explicitOverride && persistedRunKey ? persistedRunKey : session.runKey
	const ampThreadID = session.explicitOverride
		? (persistedThreadID || null)
		: (session.threadID && isValidThreadID(session.threadID) ? session.threadID : null)
	writeRegistry(session.registryPath, {
		schema_version: 1,
		host: 'amp',
		workspace_root: session.workspaceRoot,
		project_key: session.projectKey,
		run_key: runKey,
		amp_thread_id: ampThreadID,
		last_seen: new Date().toISOString(),
		last_blocking_fingerprint: fingerprint || current.last_blocking_fingerprint,
	})
}

export function mapAgentEndDecision(event: Record<string, unknown>, ctx: Record<string, unknown>): { action: 'continue'; userMessage: string } | void {
	if (truthy(process.env.CERBERUS_REVIEWER_SUBPROCESS)) return
	if (typeof event.status === 'string' && event.status !== 'done') return

	let session: AmpSession
	try {
		session = ensureAmpSession(event, ctx)
	} catch {
		return
	}

	let decision: CompletionDecision | null = null
	try {
		decision = runCompletionCheck(event, ctx)
	} catch {
		return
	}
	if (!decision || decision.decision !== 'continue' || !decision.userMessage) return

	// Sanity: if completion-check resolved a different gate than ours, do not
	// continue this Amp turn for someone else's run.
	if (decision.run_key && session.runKey && decision.run_key !== session.runKey) return
	if (decision.reason === 'pending' && typeof decision.pending_count === 'number' && decision.pending_count > 0) return
	if (NOTIFIED_KEYS.has(monitorKey(session))) return

	const fingerprint = fingerprintFor(decision)
	const registry = readRegistry(session.registryPath)
	if (registry?.last_blocking_fingerprint === fingerprint) return

	try {
		rememberBlockingFingerprint(session, fingerprint)
	} catch {
		return
	}
	// Coordinate with the background monitor: agent.end has now surfaced a
	// blocking userMessage for this gate, so the monitor must not push a
	// second 'reviewers complete' message for the same monitor key.
	markGateNotified(session)
	stopCerberusMonitor(session)
	return { action: 'continue', userMessage: decision.userMessage }
}

function registerCerberusTool(amp: PluginAPI, command: CerberusCommand): void {
	amp.registerTool({
		name: command,
		description: `${titleFor(command)}. Thin Amp adapter over bin/review-gate; Cerberus backend remains authoritative.`,
		inputSchema: inputSchemaFor(command) as { type: 'object'; properties?: Record<string, object>; required?: string[] },
		async execute(input: Record<string, unknown>, ctx: Record<string, unknown>) {
			return executeCerberusCommand(command, input, { thread: ctx.thread }, ctx)
		},
	})
}

function registerCerberusCommand(amp: PluginAPI, command: CerberusCommand): void {
	amp.registerCommand(command, {
		title: titleFor(command),
		category: 'Cerberus',
		description: `${titleFor(command)} via the shared Cerberus backend.`,
	}, async (ctx: Record<string, unknown>) => {
		const input = await inputForCommand(command, ctx)
		if (input === null) return
		const output = executeCerberusCommand(command, input, { thread: ctx.thread }, ctx)
		const ui = (ctx.ui || {}) as { notify?: (message: string) => Promise<void> }
		await ui.notify?.(output.length > 1800 ? `${output.slice(0, 1800)}\n...` : output)
	})
}

export default function cerberus(amp: PluginAPI): void {
	for (const command of COMMANDS) {
		registerCerberusTool(amp, command)
		registerCerberusCommand(amp, command)
	}
	registerCerberusTool(amp, 'ask')
	registerCerberusCommand(amp, 'ask')

	amp.on('session.start', async (event, ctx) => {
		try {
			extractThread(event as Record<string, unknown>, ctx as Record<string, unknown>)
			ensureAmpSession(event as Record<string, unknown>, ctx as Record<string, unknown>)
		} catch { /* fail open */ }
	})

	amp.on('agent.start', async (event, ctx) => {
		try {
			extractThread(event as Record<string, unknown>, ctx as Record<string, unknown>)
			ensureAmpSession(event as Record<string, unknown>, ctx as Record<string, unknown>)
		} catch { /* fail open */ }
	})

	amp.on('agent.end', async (event, ctx) => {
		try {
			extractThread(event as Record<string, unknown>, ctx as Record<string, unknown>)
			return mapAgentEndDecision(event as Record<string, unknown>, ctx as Record<string, unknown>)
		} catch {
			return
		}
	})
}
