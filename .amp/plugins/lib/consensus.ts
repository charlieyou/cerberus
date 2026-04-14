import type { ReviewerName, RunnerResult } from './runners'
import type { ReviewFinding, ReviewResult, ReviewVerdict } from './review-json'

export type ConsensusMode = 'majority' | 'all' | 'any'

export type ConsensusOutcome = 'auto_approve' | 'requires_decision'

export type ReviewerInput = {
	reviewer: ReviewerName
	result: ReviewResult | null
	failed: boolean
}

export type ConsensusEvaluation = {
	outcome: ConsensusOutcome
	mode: ConsensusMode
	counts: {
		pass: number
		fail: number
		needsWork: number
		other: number
		valid: number
	}
	maxPriority: number
}

export function evaluateConsensus(
	inputs: ReviewerInput[],
	mode: ConsensusMode = 'majority',
): ConsensusEvaluation {
	let pass = 0
	let fail = 0
	let needsWork = 0
	let other = 0
	let maxPriority = 99

	for (const input of inputs) {
		if (input.failed || !input.result) {
			other++
			continue
		}

		const lowestPriority = input.result.findings.reduce(
			(min, f) => Math.min(min, f.priority),
			99,
		)
		if (lowestPriority < maxPriority) {
			maxPriority = lowestPriority
		}

		switch (input.result.verdict) {
			case 'PASS':
				pass++
				break
			case 'FAIL':
				fail++
				break
			case 'NEEDS_WORK':
				needsWork++
				break
			default:
				other++
				break
		}
	}

	const valid = pass + fail + needsWork
	const counts = { pass, fail, needsWork, other, valid }

	if (valid < 1) {
		return { outcome: 'requires_decision', mode, counts, maxPriority }
	}

	if (fail > 0) {
		return { outcome: 'requires_decision', mode, counts, maxPriority }
	}

	if (maxPriority <= 1) {
		return { outcome: 'requires_decision', mode, counts, maxPriority }
	}

	let outcome: ConsensusOutcome

	switch (mode) {
		case 'all':
			outcome = pass === valid ? 'auto_approve' : 'requires_decision'
			break
		case 'any':
			outcome = pass >= 1 ? 'auto_approve' : 'requires_decision'
			break
		case 'majority':
		default:
			if (pass === valid) {
				outcome = 'auto_approve'
			} else if (maxPriority >= 2 && pass >= 2) {
				outcome = 'auto_approve'
			} else {
				outcome = 'requires_decision'
			}
			break
	}

	return { outcome, mode, counts, maxPriority }
}

export function isBlocking(finding: ReviewFinding): boolean {
	return finding.priority <= 1
}

export function collectBlockingFindings(inputs: ReviewerInput[]): { reviewer: ReviewerName; finding: ReviewFinding }[] {
	const results: { reviewer: ReviewerName; finding: ReviewFinding }[] = []
	for (const input of inputs) {
		if (input.failed || !input.result) continue
		if (input.result.verdict === 'PASS') continue
		for (const f of input.result.findings) {
			if (isBlocking(f)) {
				results.push({ reviewer: input.reviewer, finding: f })
			}
		}
	}
	return results
}

export function collectAllFindings(inputs: ReviewerInput[]): { reviewer: ReviewerName; finding: ReviewFinding; verdict: ReviewVerdict | null }[] {
	const results: { reviewer: ReviewerName; finding: ReviewFinding; verdict: ReviewVerdict | null }[] = []
	for (const input of inputs) {
		if (input.failed || !input.result) continue
		const verdict = input.result.verdict
		if (verdict === 'PASS') {
			for (const f of input.result.findings) {
				if (f.priority >= 2) {
					results.push({ reviewer: input.reviewer, finding: f, verdict })
				}
			}
		} else {
			for (const f of input.result.findings) {
				results.push({ reviewer: input.reviewer, finding: f, verdict })
			}
		}
	}
	return results
}

export function formatResultsTable(inputs: ReviewerInput[]): string {
	let table = '## Review Results\n\n'
	table += '| Reviewer | Verdict | Summary |\n'
	table += '|----------|---------|---------|\n'

	for (const input of inputs) {
		let verdict = 'ERROR'
		let summary = 'No response'

		if (input.failed) {
			verdict = 'ERROR'
			summary = 'Reviewer process failed'
		} else if (input.result) {
			verdict = input.result.verdict
			summary = input.result.summary || 'No summary'
			if (summary.length > 60) {
				summary = `${summary.slice(0, 57)}...`
			}
		}

		table += `| ${input.reviewer} | ${verdict} | ${summary} |\n`
	}

	return table
}

function formatFindingLine(finding: ReviewFinding): string {
	const prefix = `[P${finding.priority}]`
	const title = finding.title
		? (finding.title.startsWith('[P') ? finding.title : `${prefix} ${finding.title}`)
		: prefix
	const location = finding.file_path
		? ` (${finding.file_path}${finding.line_start ? `:${finding.line_start}` : ''})` : ''
	return `- ${title}${location}: ${finding.body}`
}

export function formatBlockingIssues(inputs: ReviewerInput[]): string {
	const blocking = collectBlockingFindings(inputs)
	if (blocking.length === 0) return ''

	const byReviewer = new Map<string, { reviewer: ReviewerName; verdict: string; findings: ReviewFinding[] }>()
	for (const { reviewer, finding } of blocking) {
		const input = inputs.find((i) => i.reviewer === reviewer)
		const verdict = input?.result?.verdict ?? 'UNCLEAR'
		if (!byReviewer.has(reviewer)) {
			byReviewer.set(reviewer, { reviewer, verdict, findings: [] })
		}
		byReviewer.get(reviewer)!.findings.push(finding)
	}

	let md = '## Blocking Issues (P0/P1)\n\n'
	for (const { reviewer, verdict, findings } of byReviewer.values()) {
		md += `### ${reviewer} (${verdict})\n`
		for (const f of findings) {
			md += `${formatFindingLine(f)}\n`
		}
		md += '\n'
	}

	return md
}

export function formatInformationalFindings(inputs: ReviewerInput[]): string {
	const items: { reviewer: ReviewerName; finding: ReviewFinding }[] = []
	for (const input of inputs) {
		if (input.failed || !input.result) continue
		for (const f of input.result.findings) {
			if (f.priority >= 2) {
				items.push({ reviewer: input.reviewer, finding: f })
			}
		}
	}

	if (items.length === 0) return ''

	const byReviewer = new Map<string, ReviewFinding[]>()
	for (const { reviewer, finding } of items) {
		if (!byReviewer.has(reviewer)) byReviewer.set(reviewer, [])
		byReviewer.get(reviewer)!.push(finding)
	}

	let md = '## Informational Items (P2/P3)\n\nThe following non-blocking items were noted for your awareness:\n\n'
	for (const [reviewer, findings] of byReviewer) {
		md += `### ${reviewer}\n`
		for (const f of findings) {
			md += `${formatFindingLine(f)}\n`
		}
		md += '\n'
	}

	return md
}

export function formatReviewFeedback(
	inputs: ReviewerInput[],
	evaluation: ConsensusEvaluation,
	opts: { iteration: number; maxRounds: number } = { iteration: 1, maxRounds: 3 },
): string {
	const { iteration, maxRounds } = opts
	const parts: string[] = []

	parts.push(formatResultsTable(inputs))

	if (evaluation.outcome === 'auto_approve') {
		parts.push('\n**Consensus: APPROVED** — All checks passed.\n')
		const info = formatInformationalFindings(inputs)
		if (info) parts.push(`\n${info}`)
		return parts.join('\n')
	}

	if (iteration >= maxRounds) {
		parts.push(`\n**Max review rounds reached (${maxRounds}).** Requiring manual decision.\n`)
		const allFindings = formatAllIssues(inputs)
		if (allFindings) parts.push(`\n${allFindings}`)
		return parts.join('\n')
	}

	const blocking = formatBlockingIssues(inputs)
	if (blocking) parts.push(`\n${blocking}`)

	const allIssues = formatAllIssues(inputs)
	if (allIssues && !blocking) parts.push(`\n${allIssues}`)

	const info = formatInformationalFindings(inputs)
	if (info && blocking) parts.push(`\n${info}`)

	parts.push(`\n**Round ${iteration}/${maxRounds}** — Please address the issues above and continue.\n`)

	return parts.join('\n')
}

function formatAllIssues(inputs: ReviewerInput[]): string {
	const findings = collectAllFindings(inputs)
	if (findings.length === 0) return ''

	const byReviewer = new Map<string, { verdict: string; findings: ReviewFinding[] }>()
	for (const { reviewer, finding, verdict } of findings) {
		const key = reviewer
		if (!byReviewer.has(key)) {
			const label = verdict === 'PASS' ? `${verdict} - minor issues` : (verdict ?? 'UNCLEAR')
			byReviewer.set(key, { verdict: label, findings: [] })
		}
		byReviewer.get(key)!.findings.push(finding)
	}

	let md = '## Review Issues\n\n'
	for (const [reviewer, { verdict, findings: fs }] of byReviewer) {
		md += `### ${reviewer} (${verdict})\n`
		for (const f of fs) {
			md += `${formatFindingLine(f)}\n`
		}
		md += '\n'
	}

	return md
}
