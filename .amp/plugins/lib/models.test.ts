import { describe, expect, test } from 'bun:test'
import { normalizeMode, resolveModels } from './models'

describe('normalizeMode', () => {
	test('defaults to smart when empty', () => {
		expect(normalizeMode(undefined)).toBe('smart')
		expect(normalizeMode('')).toBe('smart')
	})

	test('normalizes case', () => {
		expect(normalizeMode('FAST')).toBe('fast')
		expect(normalizeMode('Smart')).toBe('smart')
		expect(normalizeMode('MAX')).toBe('max')
	})

	test('falls back to smart for invalid', () => {
		expect(normalizeMode('turbo')).toBe('smart')
		expect(normalizeMode('unknown')).toBe('smart')
	})
})

describe('resolveModels', () => {
	const emptyEnv: Record<string, string | undefined> = {}

	test('fast mode defaults', () => {
		const r = resolveModels('fast', emptyEnv)
		expect(r.mode).toBe('fast')
		expect(r.codexModel).toBe('gpt-5.4')
		expect(r.codexReasoningEffort).toBe('medium')
		expect(r.geminiModel).toBe('gemini-3-flash-preview')
		expect(r.claudeModel).toBe('sonnet')
		expect(r.ultrathink).toBe(false)
	})

	test('smart mode defaults', () => {
		const r = resolveModels('smart', emptyEnv)
		expect(r.mode).toBe('smart')
		expect(r.codexReasoningEffort).toBe('high')
		expect(r.geminiModel).toBe('gemini-3.1-pro-preview')
		expect(r.claudeModel).toBe('opus')
		expect(r.ultrathink).toBe(false)
	})

	test('max mode defaults', () => {
		const r = resolveModels('max', emptyEnv)
		expect(r.mode).toBe('max')
		expect(r.codexReasoningEffort).toBe('xhigh')
		expect(r.ultrathink).toBe(true)
	})

	test('override env vars take precedence', () => {
		const env = {
			CODEX_MODEL_OVERRIDE: 'custom-codex',
			GEMINI_MODEL_OVERRIDE: 'custom-gemini',
			CLAUDE_MODEL_OVERRIDE: 'custom-claude',
			CODEX_REASONING_EFFORT_OVERRIDE: 'low',
		}
		const r = resolveModels('smart', env)
		expect(r.codexModel).toBe('custom-codex')
		expect(r.geminiModel).toBe('custom-gemini')
		expect(r.claudeModel).toBe('custom-claude')
		expect(r.codexReasoningEffort).toBe('low')
	})

	test('base env vars used when no override', () => {
		const env = {
			CODEX_MODEL: 'base-codex',
			GEMINI_MODEL: 'base-gemini',
			CLAUDE_MODEL: 'base-claude',
		}
		const r = resolveModels('fast', env)
		expect(r.codexModel).toBe('base-codex')
		expect(r.geminiModel).toBe('base-gemini')
		expect(r.claudeModel).toBe('base-claude')
	})

	test('override trumps base env var', () => {
		const env = {
			GEMINI_MODEL: 'base-gemini',
			GEMINI_MODEL_OVERRIDE: 'override-gemini',
		}
		const r = resolveModels('fast', env)
		expect(r.geminiModel).toBe('override-gemini')
	})

	test('defaults to smart for undefined mode', () => {
		const r = resolveModels(undefined, emptyEnv)
		expect(r.mode).toBe('smart')
	})

	test('defaults to smart for invalid mode', () => {
		const r = resolveModels('turbo', emptyEnv)
		expect(r.mode).toBe('smart')
	})
})
