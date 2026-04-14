export type ReviewVerdict = 'PASS' | 'FAIL' | 'NEEDS_WORK'

export type ReviewFinding = {
	title: string
	body: string
	priority: number
	file_path: string | null
	line_start: number | null
	line_end: number | null
}

export type ReviewResult = {
	verdict: ReviewVerdict
	summary: string
	findings: ReviewFinding[]
}

const VALID_VERDICTS = new Set<string>(['PASS', 'FAIL', 'NEEDS_WORK'])

export function extractLastJsonObject(text: string): Record<string, unknown> | null {
	const objects: Record<string, unknown>[] = []
	for (let i = 0; i < text.length; i++) {
		if (text[i] !== '{') continue
		try {
			const candidate = text.slice(i)
			const parsed = JSON.parse(candidate.slice(0, findJsonEnd(candidate)))
			if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) {
				objects.push(parsed)
			}
		} catch {
			// not valid JSON at this position
		}
	}
	if (objects.length === 0) return null

	const reviewCandidates = objects.filter(
		(obj) =>
			(typeof obj.verdict === 'string' && VALID_VERDICTS.has(obj.verdict)) ||
			'structured_output' in obj ||
			(typeof obj.response === 'string'),
	)

	return reviewCandidates.length > 0 ? reviewCandidates[reviewCandidates.length - 1] : objects[objects.length - 1]
}

export function unwrapReviewJson(obj: Record<string, unknown>): Record<string, unknown> | null {
	let current = obj

	if ('structured_output' in current && typeof current.structured_output === 'object' && current.structured_output !== null) {
		current = current.structured_output as Record<string, unknown>
	}

	if ('response' in current && typeof current.response === 'string') {
		const responseStr = current.response
		try {
			const parsed = JSON.parse(responseStr)
			if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) {
				current = parsed
			}
		} catch {
			const extracted = extractLastJsonObject(responseStr)
			if (extracted && typeof extracted.verdict === 'string' && VALID_VERDICTS.has(extracted.verdict)) {
				current = extracted
			} else {
				return null
			}
		}
	}

	if ('result' in current && typeof current.result === 'string') {
		const resultStr = current.result
		try {
			const parsed = JSON.parse(resultStr)
			if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) {
				current = parsed
			}
		} catch {
			const stripped = resultStr.replace(/^```json\n?/m, '').replace(/^```$/m, '')
			try {
				const parsed = JSON.parse(stripped)
				if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) {
					current = parsed
				}
			} catch {
				const extracted = extractLastJsonObject(resultStr)
				if (extracted) {
					current = extracted
				} else {
					return null
				}
			}
		}
	}

	return current
}

export function validateReviewResult(obj: Record<string, unknown>): ReviewResult | null {
	if (typeof obj.verdict !== 'string' || !VALID_VERDICTS.has(obj.verdict)) return null
	if (typeof obj.summary !== 'string') return null
	if (!Array.isArray(obj.findings)) return null

	const findings: ReviewFinding[] = obj.findings.map((f: Record<string, unknown>) => ({
		title: typeof f.title === 'string' ? f.title : '',
		body: typeof f.body === 'string' ? f.body : '',
		priority: typeof f.priority === 'number' ? f.priority : 3,
		file_path: typeof f.file_path === 'string' ? f.file_path : null,
		line_start: typeof f.line_start === 'number' ? f.line_start : null,
		line_end: typeof f.line_end === 'number' ? f.line_end : null,
	}))

	return {
		verdict: obj.verdict as ReviewVerdict,
		summary: obj.summary,
		findings,
	}
}

export function parseReviewOutput(text: string): ReviewResult | null {
	const obj = extractLastJsonObject(text)
	if (!obj) return null
	const unwrapped = unwrapReviewJson(obj)
	if (!unwrapped) return null
	return validateReviewResult(unwrapped)
}

function findJsonEnd(text: string): number {
	let depth = 0
	let inString = false
	let escape = false
	for (let i = 0; i < text.length; i++) {
		const ch = text[i]
		if (escape) {
			escape = false
			continue
		}
		if (ch === '\\') {
			if (inString) escape = true
			continue
		}
		if (ch === '"') {
			inString = !inString
			continue
		}
		if (inString) continue
		if (ch === '{') depth++
		else if (ch === '}') {
			depth--
			if (depth === 0) return i + 1
		}
	}
	return text.length
}
