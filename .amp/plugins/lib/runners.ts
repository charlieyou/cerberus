import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { getPluginRoot, resolveThreadStateDir } from '../cerberus'
import { resolveModels, type IntelligenceMode, type ResolvedModels } from './models'
import { parseReviewOutput, type ReviewResult } from './review-json'

export type ReviewerName = 'codex' | 'gemini' | 'claude'

export type RunnerResult = {
	reviewer: ReviewerName
	success: boolean
	result: ReviewResult | null
	rawOutput: string
	error: string | null
	durationMs: number
}

export type RunnerOptions = {
	reviewer: ReviewerName
	promptFile: string
	models: ResolvedModels
	timeoutMs?: number
	schemaFile?: string
	exec: ExecFn
}

export type ExecFn = (
	cmd: string[],
	opts: { timeout?: number; env?: Record<string, string> },
) => Promise<{ stdout: string; stderr: string; exitCode: number }>

export type SpawnAllOptions = {
	reviewers: ReviewerName[]
	promptFile: string
	mode?: string
	timeoutMs?: number
	schemaFile?: string
	exec: ExecFn
	env?: Record<string, string | undefined>
}

const DEFAULT_TIMEOUT_MS = 300_000

const CLAUDE_READONLY_ALLOWED_TOOLS = ['Read', 'Glob', 'Grep', 'LS']
const CLAUDE_READONLY_DISALLOWED_TOOLS = ['Bash', 'Edit', 'Write', 'WebFetch', 'WebSearch']

function geminiSettingsPath(): string {
	return join(getPluginRoot(), 'config', 'gemini-readonly-settings.json')
}

export function buildReviewerCommand(opts: RunnerOptions): { cmd: string[]; env: Record<string, string> } {
	const { reviewer, promptFile, models, schemaFile } = opts
	const env: Record<string, string> = {}

	switch (reviewer) {
		case 'codex': {
			const cmd = [
				'codex', 'exec',
				'-m', models.codexModel,
				'-c', `model_reasoning_effort=${models.codexReasoningEffort}`,
				'-s', 'read-only',
			]
			if (schemaFile) {
				cmd.push('--output-schema', schemaFile)
			}
			cmd.push('-', '<', promptFile)
			return { cmd, env }
		}
		case 'gemini': {
			env.GEMINI_CLI_SYSTEM_SETTINGS_PATH = geminiSettingsPath()
			const cmd = [
				'gemini',
				'-m', models.geminiModel,
				'-o', 'json',
				'<', promptFile,
			]
			return { cmd, env }
		}
		case 'claude': {
			const cmd = [
				'claude', '-p',
				'--model', models.claudeModel,
				'--output-format', 'json',
			]
			for (const tool of CLAUDE_READONLY_ALLOWED_TOOLS) {
				cmd.push('--allowedTools', tool)
			}
			for (const tool of CLAUDE_READONLY_DISALLOWED_TOOLS) {
				cmd.push('--disallowedTools', tool)
			}
			cmd.push('<', promptFile)
			return { cmd, env }
		}
	}
}

export async function runReviewer(opts: RunnerOptions): Promise<RunnerResult> {
	const { reviewer, exec, timeoutMs = DEFAULT_TIMEOUT_MS } = opts
	const start = Date.now()

	try {
		const { cmd, env } = buildReviewerCommand(opts)
		const { stdout, stderr, exitCode } = await exec(cmd, { timeout: timeoutMs, env })

		const rawOutput = stdout || stderr

		if (exitCode !== 0) {
			return {
				reviewer,
				success: false,
				result: null,
				rawOutput,
				error: `Process exited with code ${exitCode}`,
				durationMs: Date.now() - start,
			}
		}

		const result = parseReviewOutput(rawOutput)

		return {
			reviewer,
			success: result !== null,
			result,
			rawOutput,
			error: result === null ? 'Failed to parse review output' : null,
			durationMs: Date.now() - start,
		}
	} catch (err) {
		const isTimeout = err instanceof Error && err.message.includes('timeout')
		return {
			reviewer,
			success: false,
			result: null,
			rawOutput: '',
			error: isTimeout ? `Reviewer timed out after ${timeoutMs}ms` : String(err),
			durationMs: Date.now() - start,
		}
	}
}

export async function runAllReviewers(opts: SpawnAllOptions): Promise<RunnerResult[]> {
	const models = resolveModels(opts.mode, opts.env as Record<string, string | undefined>)

	const promises = opts.reviewers.map((reviewer) =>
		runReviewer({
			reviewer,
			promptFile: opts.promptFile,
			models,
			timeoutMs: opts.timeoutMs,
			schemaFile: opts.schemaFile,
			exec: opts.exec,
		}),
	)

	return Promise.all(promises)
}

export function reviewsDir(threadId: string, gateId: string): string {
	return join(resolveThreadStateDir(threadId), gateId, 'reviews')
}

export async function writeRunnerResult(
	threadId: string,
	gateId: string,
	result: RunnerResult,
): Promise<{ outputFile: string; sentinelFile: string }> {
	const dir = reviewsDir(threadId, gateId)
	await mkdir(dir, { recursive: true })

	const outputFile = join(dir, `${result.reviewer}.json`)
	const sentinelFile = join(dir, `${result.reviewer}.${result.success ? 'done' : 'failed'}`)

	await writeFile(outputFile, result.rawOutput || JSON.stringify(result.result), 'utf8')
	await writeFile(sentinelFile, '', 'utf8')

	return { outputFile, sentinelFile }
}

export async function readRunnerOutput(
	threadId: string,
	gateId: string,
	reviewer: ReviewerName,
): Promise<{ raw: string; parsed: ReviewResult | null } | null> {
	try {
		const dir = reviewsDir(threadId, gateId)
		const raw = await readFile(join(dir, `${reviewer}.json`), 'utf8')
		return { raw, parsed: parseReviewOutput(raw) }
	} catch {
		return null
	}
}
