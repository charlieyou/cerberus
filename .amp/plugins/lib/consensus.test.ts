import { describe, expect, test } from 'bun:test'
import {
	evaluateConsensus,
	isBlocking,
	collectBlockingFindings,
	collectAllFindings,
	formatResultsTable,
	formatBlockingIssues,
	formatInformationalFindings,
	formatReviewFeedback,
	type ReviewerInput,
	type ConsensusMode,
} from './consensus'
import type { ReviewResult, ReviewFinding } from './review-json'

function makeFinding(overrides: Partial<ReviewFinding> = {}): ReviewFinding {
	return {
		title: 'Test finding',
		body: 'Details here',
		priority: 2,
		file_path: null,
		line_start: null,
		line_end: null,
		...overrides,
	}
}

function makeResult(verdict: 'PASS' | 'FAIL' | 'NEEDS_WORK', findings: ReviewFinding[] = []): ReviewResult {
	return { verdict, summary: `${verdict} summary`, findings }
}

function makeInput(
	reviewer: 'codex' | 'gemini' | 'claude',
	result: ReviewResult | null = null,
	failed = false,
): ReviewerInput {
	return { reviewer, result, failed }
}

describe('evaluateConsensus', () => {
	describe('majority mode', () => {
		test('all PASS → auto_approve', () => {
			const inputs = [
				makeInput('codex', makeResult('PASS')),
				makeInput('gemini', makeResult('PASS')),
				makeInput('claude', makeResult('PASS')),
			]
			const result = evaluateConsensus(inputs, 'majority')
			expect(result.outcome).toBe('auto_approve')
			expect(result.counts.pass).toBe(3)
			expect(result.counts.valid).toBe(3)
		})

		test('2 PASS + 1 NEEDS_WORK with P2 findings → auto_approve', () => {
			const inputs = [
				makeInput('codex', makeResult('PASS')),
				makeInput('gemini', makeResult('PASS')),
				makeInput('claude', makeResult('NEEDS_WORK', [makeFinding({ priority: 2 })])),
			]
			const result = evaluateConsensus(inputs, 'majority')
			expect(result.outcome).toBe('auto_approve')
		})

		test('1 PASS + 2 NEEDS_WORK with P2 → requires_decision', () => {
			const inputs = [
				makeInput('codex', makeResult('PASS')),
				makeInput('gemini', makeResult('NEEDS_WORK', [makeFinding({ priority: 2 })])),
				makeInput('claude', makeResult('NEEDS_WORK', [makeFinding({ priority: 3 })])),
			]
			const result = evaluateConsensus(inputs, 'majority')
			expect(result.outcome).toBe('requires_decision')
		})

		test('any FAIL → requires_decision regardless of other votes', () => {
			const inputs = [
				makeInput('codex', makeResult('PASS')),
				makeInput('gemini', makeResult('PASS')),
				makeInput('claude', makeResult('FAIL')),
			]
			const result = evaluateConsensus(inputs, 'majority')
			expect(result.outcome).toBe('requires_decision')
			expect(result.counts.fail).toBe(1)
		})

		test('errored reviewers are counted as other, not valid', () => {
			const inputs = [
				makeInput('codex', makeResult('PASS')),
				makeInput('gemini', makeResult('PASS')),
				makeInput('claude', null, true),
			]
			const result = evaluateConsensus(inputs, 'majority')
			expect(result.outcome).toBe('auto_approve')
			expect(result.counts.other).toBe(1)
			expect(result.counts.valid).toBe(2)
		})
	})

	describe('all mode', () => {
		test('all PASS → auto_approve', () => {
			const inputs = [
				makeInput('codex', makeResult('PASS')),
				makeInput('gemini', makeResult('PASS')),
			]
			expect(evaluateConsensus(inputs, 'all').outcome).toBe('auto_approve')
		})

		test('one NEEDS_WORK → requires_decision', () => {
			const inputs = [
				makeInput('codex', makeResult('PASS')),
				makeInput('gemini', makeResult('NEEDS_WORK', [makeFinding({ priority: 3 })])),
			]
			expect(evaluateConsensus(inputs, 'all').outcome).toBe('requires_decision')
		})

		test('errored reviewer still allows auto_approve if all valid PASS', () => {
			const inputs = [
				makeInput('codex', makeResult('PASS')),
				makeInput('gemini', null, true),
			]
			expect(evaluateConsensus(inputs, 'all').outcome).toBe('auto_approve')
		})
	})

	describe('any mode', () => {
		test('one PASS → auto_approve', () => {
			const inputs = [
				makeInput('codex', makeResult('NEEDS_WORK', [makeFinding({ priority: 3 })])),
				makeInput('gemini', makeResult('PASS')),
			]
			expect(evaluateConsensus(inputs, 'any').outcome).toBe('auto_approve')
		})

		test('no PASS → requires_decision', () => {
			const inputs = [
				makeInput('codex', makeResult('NEEDS_WORK', [makeFinding({ priority: 2 })])),
				makeInput('gemini', makeResult('NEEDS_WORK', [makeFinding({ priority: 3 })])),
			]
			expect(evaluateConsensus(inputs, 'any').outcome).toBe('requires_decision')
		})
	})

	describe('P0/P1 blocking', () => {
		test('P0 finding blocks even with all PASS verdicts', () => {
			const inputs = [
				makeInput('codex', makeResult('PASS', [makeFinding({ priority: 0 })])),
				makeInput('gemini', makeResult('PASS')),
			]
			const result = evaluateConsensus(inputs, 'majority')
			expect(result.outcome).toBe('requires_decision')
			expect(result.maxPriority).toBe(0)
		})

		test('P1 finding blocks in any mode', () => {
			const inputs = [
				makeInput('codex', makeResult('PASS')),
				makeInput('gemini', makeResult('NEEDS_WORK', [makeFinding({ priority: 1 })])),
			]
			const result = evaluateConsensus(inputs, 'any')
			expect(result.outcome).toBe('requires_decision')
			expect(result.maxPriority).toBe(1)
		})

		test('P2 findings do not block', () => {
			const inputs = [
				makeInput('codex', makeResult('PASS', [makeFinding({ priority: 2 })])),
				makeInput('gemini', makeResult('PASS', [makeFinding({ priority: 3 })])),
			]
			expect(evaluateConsensus(inputs, 'all').outcome).toBe('auto_approve')
		})
	})

	test('no valid reviewers → requires_decision', () => {
		const inputs = [
			makeInput('codex', null, true),
			makeInput('gemini', null, true),
		]
		const result = evaluateConsensus(inputs, 'majority')
		expect(result.outcome).toBe('requires_decision')
		expect(result.counts.valid).toBe(0)
	})

	test('empty inputs → requires_decision', () => {
		expect(evaluateConsensus([], 'majority').outcome).toBe('requires_decision')
	})
})

describe('isBlocking', () => {
	test('P0 is blocking', () => {
		expect(isBlocking(makeFinding({ priority: 0 }))).toBe(true)
	})

	test('P1 is blocking', () => {
		expect(isBlocking(makeFinding({ priority: 1 }))).toBe(true)
	})

	test('P2 is not blocking', () => {
		expect(isBlocking(makeFinding({ priority: 2 }))).toBe(false)
	})

	test('P3 is not blocking', () => {
		expect(isBlocking(makeFinding({ priority: 3 }))).toBe(false)
	})
})

describe('collectBlockingFindings', () => {
	test('collects P0/P1 from non-PASS reviewers', () => {
		const inputs = [
			makeInput('codex', makeResult('NEEDS_WORK', [
				makeFinding({ priority: 0, title: 'Critical bug' }),
				makeFinding({ priority: 2, title: 'Minor style' }),
			])),
			makeInput('gemini', makeResult('FAIL', [
				makeFinding({ priority: 1, title: 'Security issue' }),
			])),
		]
		const blocking = collectBlockingFindings(inputs)
		expect(blocking).toHaveLength(2)
		expect(blocking[0].finding.title).toBe('Critical bug')
		expect(blocking[1].finding.title).toBe('Security issue')
	})

	test('skips PASS reviewers', () => {
		const inputs = [
			makeInput('codex', makeResult('PASS', [makeFinding({ priority: 0 })])),
		]
		expect(collectBlockingFindings(inputs)).toHaveLength(0)
	})

	test('skips failed reviewers', () => {
		const inputs = [makeInput('codex', null, true)]
		expect(collectBlockingFindings(inputs)).toHaveLength(0)
	})
})

describe('collectAllFindings', () => {
	test('collects all findings from non-PASS, only P2+ from PASS', () => {
		const inputs = [
			makeInput('codex', makeResult('PASS', [
				makeFinding({ priority: 1, title: 'Ignored P1 from PASS' }),
				makeFinding({ priority: 2, title: 'Minor from PASS' }),
			])),
			makeInput('gemini', makeResult('NEEDS_WORK', [
				makeFinding({ priority: 1, title: 'Important P1' }),
				makeFinding({ priority: 3, title: 'Info item' }),
			])),
		]
		const all = collectAllFindings(inputs)
		expect(all).toHaveLength(3)
		expect(all.map((a) => a.finding.title)).toEqual([
			'Minor from PASS',
			'Important P1',
			'Info item',
		])
	})
})

describe('formatResultsTable', () => {
	test('produces markdown table with verdict and summary', () => {
		const inputs = [
			makeInput('codex', makeResult('PASS')),
			makeInput('gemini', null, true),
		]
		const table = formatResultsTable(inputs)
		expect(table).toContain('| codex | PASS |')
		expect(table).toContain('| gemini | ERROR |')
		expect(table).toContain('Reviewer process failed')
	})

	test('truncates long summaries', () => {
		const result = makeResult('PASS')
		result.summary = 'A'.repeat(100)
		const inputs = [makeInput('codex', result)]
		const table = formatResultsTable(inputs)
		expect(table).toContain('...')
		expect(table).not.toContain('A'.repeat(100))
	})
})

describe('formatBlockingIssues', () => {
	test('groups blocking issues by reviewer', () => {
		const inputs = [
			makeInput('codex', makeResult('NEEDS_WORK', [
				makeFinding({ priority: 0, title: 'P0 bug', body: 'Fix it' }),
			])),
			makeInput('gemini', makeResult('FAIL', [
				makeFinding({ priority: 1, title: 'P1 issue', body: 'Also fix' }),
			])),
		]
		const md = formatBlockingIssues(inputs)
		expect(md).toContain('## Blocking Issues (P0/P1)')
		expect(md).toContain('### codex (NEEDS_WORK)')
		expect(md).toContain('### gemini (FAIL)')
		expect(md).toContain('[P0] P0 bug')
		expect(md).toContain('[P1] P1 issue')
	})

	test('returns empty string when no blocking issues', () => {
		const inputs = [
			makeInput('codex', makeResult('PASS', [makeFinding({ priority: 2 })])),
		]
		expect(formatBlockingIssues(inputs)).toBe('')
	})
})

describe('formatInformationalFindings', () => {
	test('collects P2/P3 from all reviewers', () => {
		const inputs = [
			makeInput('codex', makeResult('PASS', [
				makeFinding({ priority: 2, title: 'Style nit' }),
			])),
			makeInput('gemini', makeResult('NEEDS_WORK', [
				makeFinding({ priority: 1, title: 'Blocking' }),
				makeFinding({ priority: 3, title: 'Info note' }),
			])),
		]
		const md = formatInformationalFindings(inputs)
		expect(md).toContain('## Informational Items (P2/P3)')
		expect(md).toContain('Style nit')
		expect(md).toContain('Info note')
		expect(md).not.toContain('Blocking')
	})

	test('returns empty if no P2/P3 findings', () => {
		const inputs = [
			makeInput('codex', makeResult('FAIL', [
				makeFinding({ priority: 0 }),
			])),
		]
		expect(formatInformationalFindings(inputs)).toBe('')
	})
})

describe('formatReviewFeedback', () => {
	test('approved feedback includes table and approval message', () => {
		const inputs = [
			makeInput('codex', makeResult('PASS')),
			makeInput('gemini', makeResult('PASS')),
		]
		const evaluation = evaluateConsensus(inputs, 'majority')
		const md = formatReviewFeedback(inputs, evaluation)
		expect(md).toContain('**Consensus: APPROVED**')
		expect(md).toContain('| codex | PASS |')
	})

	test('failed feedback includes blocking issues and round counter', () => {
		const inputs = [
			makeInput('codex', makeResult('NEEDS_WORK', [
				makeFinding({ priority: 1, title: 'Must fix', body: 'broken' }),
			])),
			makeInput('gemini', makeResult('PASS')),
		]
		const evaluation = evaluateConsensus(inputs, 'majority')
		const md = formatReviewFeedback(inputs, evaluation, { iteration: 1, maxRounds: 3 })
		expect(md).toContain('## Blocking Issues (P0/P1)')
		expect(md).toContain('Must fix')
		expect(md).toContain('Round 1/3')
	})

	test('max round reached includes all issues', () => {
		const inputs = [
			makeInput('codex', makeResult('NEEDS_WORK', [
				makeFinding({ priority: 2, title: 'Still open' }),
			])),
		]
		const evaluation = evaluateConsensus(inputs, 'majority')
		const md = formatReviewFeedback(inputs, evaluation, { iteration: 3, maxRounds: 3 })
		expect(md).toContain('Max review rounds reached')
		expect(md).toContain('Still open')
	})

	test('approved with informational items includes them', () => {
		const inputs = [
			makeInput('codex', makeResult('PASS', [makeFinding({ priority: 2, title: 'Style nit' })])),
			makeInput('gemini', makeResult('PASS')),
		]
		const evaluation = evaluateConsensus(inputs, 'majority')
		const md = formatReviewFeedback(inputs, evaluation)
		expect(md).toContain('**Consensus: APPROVED**')
		expect(md).toContain('Style nit')
	})

	test('mixed verdict with no blocking shows all issues', () => {
		const inputs = [
			makeInput('codex', makeResult('NEEDS_WORK', [
				makeFinding({ priority: 2, title: 'Advisory fix' }),
			])),
			makeInput('gemini', makeResult('PASS')),
		]
		const evaluation = evaluateConsensus(inputs, 'all')
		const md = formatReviewFeedback(inputs, evaluation, { iteration: 1, maxRounds: 3 })
		expect(md).toContain('## Review Issues')
		expect(md).toContain('Advisory fix')
		expect(md).toContain('Round 1/3')
	})
})
