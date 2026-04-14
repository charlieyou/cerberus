// @i-know-the-amp-plugin-api-is-wip-and-very-experimental-right-now
import type { PluginAPI } from '@ampcode/plugin'
import { readFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { createGateState, saveGateState, setActiveGate } from './lib/gate'
import type { ReviewerName } from './lib/runners'
import { runAllReviewers, writeRunnerResult } from './lib/runners'

const PLUGIN_ROOT = resolve(import.meta.dir, '..', '..')
const PROMPTS_DIR = join(PLUGIN_ROOT, 'prompts')
const STATE_DIR = join(PLUGIN_ROOT, '.tmp', 'cerberus')

export function getPluginRoot() {
	return PLUGIN_ROOT
}

export function getPromptsDir() {
	return PROMPTS_DIR
}

export function getStateDir() {
	return STATE_DIR
}

export async function loadPrompt(relativePath: string): Promise<string> {
	const fullPath = join(PROMPTS_DIR, relativePath)
	return readFile(fullPath, 'utf8')
}

export function resolveThreadStateDir(threadId: string): string {
	return join(STATE_DIR, sanitizeId(threadId))
}

function sanitizeId(id: string): string {
	return id.replace(/[^a-zA-Z0-9._-]/g, '_')
}

const VALID_REVIEWERS = new Set<string>(['codex', 'gemini', 'claude'])
const VALID_MODES = ['fast', 'smart', 'max']

export default function cerberus(amp: PluginAPI) {
	amp.on('session.start', async (_event, _ctx) => {})

	amp.registerCommand(
		'review-code',
		{
			title: 'Review Code',
			category: 'Cerberus',
			description: 'Iterative code review with external reviewers (Codex, Gemini, Claude)',
		},
		async (ctx) => {
			const threadId = ctx.thread?.id
			if (!threadId) {
				await ctx.ui.notify('Cerberus: open a thread before starting a review.')
				return
			}

			const diffMode = await ctx.ui.input({
				title: 'Review Code – Diff Mode',
				helpText: 'Enter diff selector: --uncommitted, --base <branch>, --commit <sha>, or a range (e.g. main..feature). Leave blank for uncommitted.',
				initialValue: '--uncommitted',
				submitButtonText: 'Next',
			})
			if (diffMode === undefined) return

			const modeInput = await ctx.ui.input({
				title: 'Review Code – Intelligence Mode',
				helpText: `Choose model intelligence: ${VALID_MODES.join(', ')}`,
				initialValue: 'smart',
				submitButtonText: 'Next',
			})
			if (modeInput === undefined) return

			const reviewersInput = await ctx.ui.input({
				title: 'Review Code – Reviewers',
				helpText: 'Comma-separated reviewer list: codex, gemini, claude',
				initialValue: 'codex,gemini,claude',
				submitButtonText: 'Next',
			})
			if (reviewersInput === undefined) return

			const consensusInput = await ctx.ui.input({
				title: 'Review Code – Consensus Mode',
				helpText: 'Consensus: majority, all, or any',
				initialValue: 'majority',
				submitButtonText: 'Next',
			})
			if (consensusInput === undefined) return

			const maxRoundsInput = await ctx.ui.input({
				title: 'Review Code – Max Rounds',
				helpText: 'Maximum number of review iterations (0 = single round, no auto-respawn)',
				initialValue: '3',
				submitButtonText: 'Start Review',
			})
			if (maxRoundsInput === undefined) return

			const reviewers = parseReviewers(reviewersInput)
			const maxRounds = Number.parseInt(maxRoundsInput, 10)

			if (reviewers.length === 0) {
				await ctx.ui.notify('Cerberus: no valid reviewers selected.')
				return
			}
			if (!Number.isFinite(maxRounds) || maxRounds < 0) {
				await ctx.ui.notify('Cerberus: max rounds must be a non-negative integer.')
				return
			}

			const gateId = `review-${Date.now()}`
			const reviewerStates: Record<string, { outputFile: string; sentinelFile: string; completedAt: string | null; result: unknown | null }> = {}
			for (const r of reviewers) {
				reviewerStates[r] = { outputFile: '', sentinelFile: '', completedAt: null, result: null }
			}

			const gate = createGateState({
				triggerSource: 'command:review-code',
				reviewers: reviewerStates,
				iteration: 1,
			})
			await saveGateState(threadId, gateId, gate)
			await setActiveGate(threadId, gateId)

			await ctx.ui.notify(`Cerberus: starting code review (gate ${gateId}) with ${reviewers.join(', ')}`)

			const promptFile = join(PLUGIN_ROOT, 'prompts', 'reviewers', 'code-review.md')

			const execFn = async (cmd: string[], opts: { timeout?: number; env?: Record<string, string> }) => {
				const result = await ctx.$`/bin/sh -lc ${cmd.join(' ')}${{ timeout: opts.timeout, env: opts.env }}`
				return {
					stdout: result.stdout?.toString() ?? '',
					stderr: result.stderr?.toString() ?? '',
					exitCode: result.exitCode ?? 1,
				}
			}

			const results = await runAllReviewers({
				reviewers,
				promptFile,
				mode: modeInput,
				exec: execFn,
			})

			for (const result of results) {
				const files = await writeRunnerResult(threadId, gateId, result)
				if (reviewerStates[result.reviewer]) {
					reviewerStates[result.reviewer].outputFile = files.outputFile
					reviewerStates[result.reviewer].sentinelFile = files.sentinelFile
					reviewerStates[result.reviewer].completedAt = new Date().toISOString()
					reviewerStates[result.reviewer].result = result.result
				}
			}

			await saveGateState(threadId, gateId, {
				...gate,
				reviewers: reviewerStates,
			})

			const passed = results.filter(r => r.success).length
			const failed = results.length - passed
			await ctx.ui.notify(`Cerberus: review round complete. ${passed} succeeded, ${failed} failed.`)
		},
	)
}

function parseReviewers(input: string): ReviewerName[] {
	return input
		.split(',')
		.map(s => s.trim().toLowerCase())
		.filter((s): s is ReviewerName => VALID_REVIEWERS.has(s))
}

