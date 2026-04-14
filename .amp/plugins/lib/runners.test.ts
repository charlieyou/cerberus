import { describe, expect, test, mock, beforeEach } from 'bun:test'
import {
	buildReviewerCommand,
	runReviewer,
	runAllReviewers,
	writeRunnerResult,
	readRunnerOutput,
	type ExecFn,
	type RunnerOptions,
	type RunnerResult,
} from './runners'
import { resolveModels } from './models'
import { rm } from 'node:fs/promises'
import { join } from 'node:path'
import { resolveThreadStateDir } from '../cerberus'

const MODELS = resolveModels('smart')

function makeExec(overrides: Partial<{ stdout: string; stderr: string; exitCode: number }> = {}): ExecFn {
	return async () => ({
		stdout: overrides.stdout ?? '',
		stderr: overrides.stderr ?? '',
		exitCode: overrides.exitCode ?? 0,
	})
}

function successOutput(verdict = 'PASS'): string {
	return JSON.stringify({
		verdict,
		summary: 'Looks good',
		findings: [],
	})
}

function makeOpts(reviewer: 'codex' | 'gemini' | 'claude', exec: ExecFn): RunnerOptions {
	return {
		reviewer,
		promptFile: '/tmp/test-prompt.md',
		models: MODELS,
		exec,
	}
}

describe('buildReviewerCommand', () => {
	test('codex command includes model and reasoning effort', () => {
		const { cmd, env } = buildReviewerCommand({
			reviewer: 'codex',
			promptFile: '/tmp/prompt.md',
			models: MODELS,
			exec: makeExec(),
		})
		expect(cmd).toContain('codex')
		expect(cmd).toContain('-m')
		expect(cmd).toContain(MODELS.codexModel)
		expect(cmd).toContain('-s')
		expect(cmd).toContain('read-only')
		expect(cmd.join(' ')).toContain(`model_reasoning_effort=${MODELS.codexReasoningEffort}`)
		expect(Object.keys(env)).toHaveLength(0)
	})

	test('codex command includes schema file when provided', () => {
		const { cmd } = buildReviewerCommand({
			reviewer: 'codex',
			promptFile: '/tmp/prompt.md',
			models: MODELS,
			schemaFile: '/tmp/schema.json',
			exec: makeExec(),
		})
		expect(cmd).toContain('--output-schema')
		expect(cmd).toContain('/tmp/schema.json')
	})

	test('gemini command sets settings env var', () => {
		const { cmd, env } = buildReviewerCommand({
			reviewer: 'gemini',
			promptFile: '/tmp/prompt.md',
			models: MODELS,
			exec: makeExec(),
		})
		expect(cmd).toContain('gemini')
		expect(cmd).toContain('-o')
		expect(cmd).toContain('json')
		expect(cmd).toContain('-m')
		expect(cmd).toContain(MODELS.geminiModel)
		expect(env.GEMINI_CLI_SYSTEM_SETTINGS_PATH).toBeDefined()
	})

	test('claude command includes allowed and disallowed tools', () => {
		const { cmd } = buildReviewerCommand({
			reviewer: 'claude',
			promptFile: '/tmp/prompt.md',
			models: MODELS,
			exec: makeExec(),
		})
		expect(cmd).toContain('claude')
		expect(cmd).toContain('-p')
		expect(cmd).toContain('--model')
		expect(cmd).toContain(MODELS.claudeModel)
		expect(cmd).toContain('--output-format')
		expect(cmd).toContain('json')
		expect(cmd).toContain('--allowedTools')
		expect(cmd).toContain('Read')
		expect(cmd).toContain('--disallowedTools')
		expect(cmd).toContain('Bash')
	})
})

describe('runReviewer', () => {
	test('successful review with parseable output', async () => {
		const exec = makeExec({ stdout: successOutput() })
		const result = await runReviewer(makeOpts('codex', exec))

		expect(result.reviewer).toBe('codex')
		expect(result.success).toBe(true)
		expect(result.result).not.toBeNull()
		expect(result.result!.verdict).toBe('PASS')
		expect(result.error).toBeNull()
		expect(result.durationMs).toBeGreaterThanOrEqual(0)
	})

	test('successful review with NEEDS_WORK verdict', async () => {
		const output = JSON.stringify({
			verdict: 'NEEDS_WORK',
			summary: 'Issues found',
			findings: [{ title: 'Bug', body: 'Fix this', priority: 1, file_path: 'foo.ts', line_start: 10, line_end: 20 }],
		})
		const exec = makeExec({ stdout: output })
		const result = await runReviewer(makeOpts('gemini', exec))

		expect(result.success).toBe(true)
		expect(result.result!.verdict).toBe('NEEDS_WORK')
		expect(result.result!.findings).toHaveLength(1)
	})

	test('non-zero exit code reports failure', async () => {
		const exec = makeExec({ exitCode: 1, stderr: 'command failed' })
		const result = await runReviewer(makeOpts('claude', exec))

		expect(result.success).toBe(false)
		expect(result.result).toBeNull()
		expect(result.error).toContain('exited with code 1')
		expect(result.rawOutput).toBe('command failed')
	})

	test('unparseable output reports parse failure', async () => {
		const exec = makeExec({ stdout: 'not json at all' })
		const result = await runReviewer(makeOpts('codex', exec))

		expect(result.success).toBe(false)
		expect(result.result).toBeNull()
		expect(result.error).toContain('Failed to parse')
	})

	test('timeout exception reports timeout', async () => {
		const exec: ExecFn = async () => {
			throw new Error('Process timeout exceeded')
		}
		const result = await runReviewer({ ...makeOpts('gemini', exec), timeoutMs: 100 })

		expect(result.success).toBe(false)
		expect(result.error).toContain('timed out')
	})

	test('generic exception reports error string', async () => {
		const exec: ExecFn = async () => {
			throw new Error('ENOENT: command not found')
		}
		const result = await runReviewer(makeOpts('codex', exec))

		expect(result.success).toBe(false)
		expect(result.error).toContain('ENOENT')
	})

	test('wrapped codex output is parsed correctly', async () => {
		const wrapped = JSON.stringify({
			structured_output: {
				verdict: 'FAIL',
				summary: 'Major issues',
				findings: [],
			},
		})
		const exec = makeExec({ stdout: wrapped })
		const result = await runReviewer(makeOpts('codex', exec))

		expect(result.success).toBe(true)
		expect(result.result!.verdict).toBe('FAIL')
	})

	test('stdout preferred over stderr when both present', async () => {
		const exec = makeExec({ stdout: successOutput(), stderr: 'some warning' })
		const result = await runReviewer(makeOpts('claude', exec))

		expect(result.success).toBe(true)
		expect(result.rawOutput).toBe(successOutput())
	})

	test('falls back to stderr when stdout is empty', async () => {
		const exec = makeExec({ stdout: '', stderr: 'error detail', exitCode: 1 })
		const result = await runReviewer(makeOpts('claude', exec))

		expect(result.rawOutput).toBe('error detail')
	})
})

describe('runAllReviewers', () => {
	test('runs multiple reviewers in parallel', async () => {
		const calls: string[] = []
		const exec: ExecFn = async (cmd) => {
			calls.push(cmd[0])
			return { stdout: successOutput(), stderr: '', exitCode: 0 }
		}

		const results = await runAllReviewers({
			reviewers: ['codex', 'gemini', 'claude'],
			promptFile: '/tmp/prompt.md',
			mode: 'smart',
			exec,
		})

		expect(results).toHaveLength(3)
		expect(calls).toContain('codex')
		expect(calls).toContain('gemini')
		expect(calls).toContain('claude')
		expect(results.every((r) => r.success)).toBe(true)
	})

	test('partial failures do not block other reviewers', async () => {
		const exec: ExecFn = async (cmd) => {
			if (cmd[0] === 'gemini') {
				throw new Error('gemini not found')
			}
			return { stdout: successOutput(), stderr: '', exitCode: 0 }
		}

		const results = await runAllReviewers({
			reviewers: ['codex', 'gemini', 'claude'],
			promptFile: '/tmp/prompt.md',
			exec,
		})

		expect(results).toHaveLength(3)
		const geminiResult = results.find((r) => r.reviewer === 'gemini')!
		expect(geminiResult.success).toBe(false)
		const codexResult = results.find((r) => r.reviewer === 'codex')!
		expect(codexResult.success).toBe(true)
		const claudeResult = results.find((r) => r.reviewer === 'claude')!
		expect(claudeResult.success).toBe(true)
	})

	test('uses specified mode for model resolution', async () => {
		const capturedCmds: string[][] = []
		const exec: ExecFn = async (cmd) => {
			capturedCmds.push([...cmd])
			return { stdout: successOutput(), stderr: '', exitCode: 0 }
		}

		await runAllReviewers({
			reviewers: ['gemini'],
			promptFile: '/tmp/prompt.md',
			mode: 'fast',
			exec,
		})

		const geminiCmd = capturedCmds.find((c) => c[0] === 'gemini')!
		expect(geminiCmd).toContain('gemini-3-flash-preview')
	})

	test('per-reviewer timeout is forwarded', async () => {
		const capturedTimeouts: (number | undefined)[] = []
		const exec: ExecFn = async (_cmd, opts) => {
			capturedTimeouts.push(opts.timeout)
			return { stdout: successOutput(), stderr: '', exitCode: 0 }
		}

		await runAllReviewers({
			reviewers: ['codex'],
			promptFile: '/tmp/prompt.md',
			timeoutMs: 60_000,
			exec,
		})

		expect(capturedTimeouts[0]).toBe(60_000)
	})

	test('empty reviewer list returns empty results', async () => {
		const results = await runAllReviewers({
			reviewers: [],
			promptFile: '/tmp/prompt.md',
			exec: makeExec(),
		})
		expect(results).toHaveLength(0)
	})
})

describe('writeRunnerResult and readRunnerOutput', () => {
	const threadId = 'test-runner-thread'
	const gateId = 'test-runner-gate'

	beforeEach(async () => {
		await rm(resolveThreadStateDir(threadId), { recursive: true, force: true })
	})

	test('writes and reads back a successful result', async () => {
		const raw = successOutput()
		const result: RunnerResult = {
			reviewer: 'codex',
			success: true,
			result: { verdict: 'PASS', summary: 'Looks good', findings: [] },
			rawOutput: raw,
			error: null,
			durationMs: 1234,
		}

		const { outputFile, sentinelFile } = await writeRunnerResult(threadId, gateId, result)
		expect(outputFile).toContain('codex.json')
		expect(sentinelFile).toContain('codex.done')

		const readBack = await readRunnerOutput(threadId, gateId, 'codex')
		expect(readBack).not.toBeNull()
		expect(readBack!.parsed).not.toBeNull()
		expect(readBack!.parsed!.verdict).toBe('PASS')
	})

	test('writes failed sentinel for unsuccessful result', async () => {
		const result: RunnerResult = {
			reviewer: 'gemini',
			success: false,
			result: null,
			rawOutput: 'error output',
			error: 'Process exited with code 1',
			durationMs: 500,
		}

		const { sentinelFile } = await writeRunnerResult(threadId, gateId, result)
		expect(sentinelFile).toContain('gemini.failed')
	})

	test('readRunnerOutput returns null for missing reviewer', async () => {
		const readBack = await readRunnerOutput(threadId, gateId, 'claude')
		expect(readBack).toBeNull()
	})
})
