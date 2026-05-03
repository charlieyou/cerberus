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
	const explicitRunKey = process.env.CERBERUS_RUN_KEY || ''
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

	return { workspaceRoot: root, projectKey, runKey, threadID, registryPath }
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

function runBackend(args: string[], session: AmpSession): BackendResult {
	const result = spawnSync(REVIEW_GATE_BIN, args, {
		cwd: session.workspaceRoot,
		env: backendEnv(session),
		encoding: 'utf8',
	})
	return {
		stdout: result.stdout || '',
		stderr: result.stderr || (result.error ? result.error.message : ''),
		exitCode: typeof result.status === 'number' ? result.status : 1,
	}
}

function backendArgsFor(command: CerberusCommand, input: Record<string, unknown>): string[][] {
	switch (command) {
		case 'review-code':
			return [['spawn-code-review']]
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
	return output.trimEnd()
}

function inputSchemaFor(command: CerberusCommand): Record<string, unknown> {
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

function rememberBlockingFingerprint(session: AmpSession, fingerprint: string): void {
	const current = readRegistry(session.registryPath) || {}
	writeRegistry(session.registryPath, {
		schema_version: 1,
		host: 'amp',
		workspace_root: session.workspaceRoot,
		project_key: session.projectKey,
		run_key: session.runKey,
		amp_thread_id: session.threadID && isValidThreadID(session.threadID) ? session.threadID : null,
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

	const fingerprint = fingerprintFor(decision)
	const registry = readRegistry(session.registryPath)
	if (registry?.last_blocking_fingerprint === fingerprint) return

	try {
		rememberBlockingFingerprint(session, fingerprint)
	} catch {
		return
	}
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
		try { ensureAmpSession(event as Record<string, unknown>, ctx as Record<string, unknown>) } catch { /* fail open */ }
	})

	amp.on('agent.start', async (event, ctx) => {
		try { ensureAmpSession(event as Record<string, unknown>, ctx as Record<string, unknown>) } catch { /* fail open */ }
	})

	amp.on('agent.end', async (event, ctx) => {
		try {
			return mapAgentEndDecision(event as Record<string, unknown>, ctx as Record<string, unknown>)
		} catch {
			return
		}
	})
}
