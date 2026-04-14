import { describe, expect, test } from 'bun:test'
import {
	extractLastJsonObject,
	parseReviewOutput,
	unwrapReviewJson,
	validateReviewResult,
} from './review-json'

describe('extractLastJsonObject', () => {
	test('extracts plain JSON', () => {
		const result = extractLastJsonObject('{"verdict":"PASS","summary":"ok","findings":[]}')
		expect(result).toEqual({ verdict: 'PASS', summary: 'ok', findings: [] })
	})

	test('extracts last JSON object from text with preamble', () => {
		const text = 'Here is my review:\n{"verdict":"FAIL","summary":"issues","findings":[]}'
		const result = extractLastJsonObject(text)
		expect(result?.verdict).toBe('FAIL')
	})

	test('prefers review-like objects over generic ones', () => {
		const text = '{"foo":"bar"} then {"verdict":"NEEDS_WORK","summary":"fix","findings":[]}'
		const result = extractLastJsonObject(text)
		expect(result?.verdict).toBe('NEEDS_WORK')
	})

	test('falls back to last object when no review candidates', () => {
		const text = '{"a":1} {"b":2}'
		const result = extractLastJsonObject(text)
		expect(result).toEqual({ b: 2 })
	})

	test('returns null for empty text', () => {
		expect(extractLastJsonObject('')).toBeNull()
	})

	test('returns null for text with no JSON', () => {
		expect(extractLastJsonObject('no json here')).toBeNull()
	})

	test('handles structured_output wrapper', () => {
		const text = '{"structured_output":{"verdict":"PASS","summary":"ok","findings":[]}}'
		const result = extractLastJsonObject(text)
		// extractLastJsonObject finds both the outer wrapper and the inner object;
		// it prefers review candidates (objects with verdict), so returns the inner one
		expect(result?.verdict).toBe('PASS')
	})

	test('handles response string wrapper', () => {
		const text = '{"response":"{\\"verdict\\":\\"PASS\\"}"}'
		const result = extractLastJsonObject(text)
		expect(result).toHaveProperty('response')
	})

	test('handles multiple JSON objects with trailing text', () => {
		const text = 'prefix {"x":1} middle {"verdict":"PASS","summary":"s","findings":[]} suffix'
		const result = extractLastJsonObject(text)
		expect(result?.verdict).toBe('PASS')
	})

	test('handles markdown code fences around JSON', () => {
		const text = '```json\n{"verdict":"PASS","summary":"ok","findings":[]}\n```'
		const result = extractLastJsonObject(text)
		expect(result?.verdict).toBe('PASS')
	})
})

describe('unwrapReviewJson', () => {
	test('passes through direct review object', () => {
		const obj = { verdict: 'PASS', summary: 'ok', findings: [] }
		expect(unwrapReviewJson(obj)).toEqual(obj)
	})

	test('unwraps structured_output', () => {
		const obj = { structured_output: { verdict: 'FAIL', summary: 'bad', findings: [] } }
		const result = unwrapReviewJson(obj)
		expect(result?.verdict).toBe('FAIL')
	})

	test('unwraps response string with valid JSON', () => {
		const inner = JSON.stringify({ verdict: 'PASS', summary: 'ok', findings: [] })
		const obj = { response: inner }
		const result = unwrapReviewJson(obj)
		expect(result?.verdict).toBe('PASS')
	})

	test('unwraps response string with embedded JSON in prose', () => {
		const inner = 'Here is the result: {"verdict":"NEEDS_WORK","summary":"fix","findings":[]}'
		const obj = { response: inner }
		const result = unwrapReviewJson(obj)
		expect(result?.verdict).toBe('NEEDS_WORK')
	})

	test('unwraps result string with code fences', () => {
		const inner = '```json\n{"verdict":"PASS","summary":"ok","findings":[]}\n```'
		const obj = { result: inner }
		const result = unwrapReviewJson(obj)
		expect(result?.verdict).toBe('PASS')
	})

	test('returns null for response string with no JSON', () => {
		const obj = { response: 'no json here at all' }
		expect(unwrapReviewJson(obj)).toBeNull()
	})
})

describe('validateReviewResult', () => {
	test('validates correct review', () => {
		const result = validateReviewResult({
			verdict: 'PASS',
			summary: 'Looks good',
			findings: [],
		})
		expect(result).toEqual({
			verdict: 'PASS',
			summary: 'Looks good',
			findings: [],
		})
	})

	test('validates review with findings', () => {
		const result = validateReviewResult({
			verdict: 'NEEDS_WORK',
			summary: 'Issues found',
			findings: [
				{ title: 'Bug', body: 'Fix it', priority: 0, file_path: 'src/main.ts', line_start: 10, line_end: 20 },
			],
		})
		expect(result?.findings).toHaveLength(1)
		expect(result?.findings[0].priority).toBe(0)
	})

	test('rejects missing verdict', () => {
		expect(validateReviewResult({ summary: 'ok', findings: [] })).toBeNull()
	})

	test('rejects invalid verdict', () => {
		expect(validateReviewResult({ verdict: 'MAYBE', summary: 'ok', findings: [] })).toBeNull()
	})

	test('rejects missing summary', () => {
		expect(validateReviewResult({ verdict: 'PASS', findings: [] })).toBeNull()
	})

	test('rejects missing findings', () => {
		expect(validateReviewResult({ verdict: 'PASS', summary: 'ok' })).toBeNull()
	})

	test('coerces missing finding fields to defaults', () => {
		const result = validateReviewResult({
			verdict: 'FAIL',
			summary: 'bad',
			findings: [{}],
		})
		expect(result?.findings[0]).toEqual({
			title: '',
			body: '',
			priority: 3,
			file_path: null,
			line_start: null,
			line_end: null,
		})
	})
})

describe('parseReviewOutput', () => {
	test('parses clean JSON output', () => {
		const result = parseReviewOutput('{"verdict":"PASS","summary":"ok","findings":[]}')
		expect(result?.verdict).toBe('PASS')
	})

	test('parses wrapped output', () => {
		const wrapped = JSON.stringify({
			structured_output: { verdict: 'FAIL', summary: 'issues', findings: [] },
		})
		const result = parseReviewOutput(wrapped)
		expect(result?.verdict).toBe('FAIL')
	})

	test('parses output with prose wrapper', () => {
		const text = 'I have reviewed the code. Here is my assessment:\n{"verdict":"NEEDS_WORK","summary":"needs fixes","findings":[{"title":"bug","body":"fix","priority":1,"file_path":null,"line_start":null,"line_end":null}]}'
		const result = parseReviewOutput(text)
		expect(result?.verdict).toBe('NEEDS_WORK')
		expect(result?.findings).toHaveLength(1)
	})

	test('returns null for garbage input', () => {
		expect(parseReviewOutput('this is not json at all')).toBeNull()
	})

	test('returns null for valid JSON missing required fields', () => {
		expect(parseReviewOutput('{"foo":"bar"}')).toBeNull()
	})

	test('handles claude result wrapper', () => {
		const claude = JSON.stringify({
			result: '{"verdict":"PASS","summary":"ok","findings":[]}',
		})
		const result = parseReviewOutput(claude)
		expect(result?.verdict).toBe('PASS')
	})

	test('handles claude result with markdown fences', () => {
		const claude = JSON.stringify({
			result: '```json\n{"verdict":"PASS","summary":"ok","findings":[]}\n```',
		})
		const result = parseReviewOutput(claude)
		expect(result?.verdict).toBe('PASS')
	})
})
