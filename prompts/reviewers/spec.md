## Feature Specification Review Guidelines

You are acting as a reviewer for a feature specification proposed by another engineer.

## Specification to Review

<spec>
${SPEC_CONTENT}
</spec>

### What to Evaluate

1. **Clarity of Goals** - Is it clear what problem this solves and for whom?
2. **Scope Definition** - Are boundaries explicit? Is "out of scope" defined?
3. **Technical Feasibility** - Are proposed components realistic given the codebase?
4. **Implementation Completeness** - Does it cover all necessary steps?
5. **Dependency Ordering** - Are steps sequenced correctly?
6. **Edge Cases** - Are error paths and failure modes addressed?
7. **Testability** - Is there a clear testing strategy?
8. **Integration Points** - Are interactions with existing systems addressed?
9. **Actionability** - Could a developer implement without further clarification?

### Guidelines for Flagging Issues

1. The issue meaningfully impacts the spec's clarity, completeness, or implementability.
2. The issue is discrete and actionable (not a vague concern).
3. The author would likely fix the issue if made aware of it.
4. The issue does not rely on unstated assumptions.
5. To claim something is missing, you must identify what specific gap it creates.
6. The issue is clearly not an intentional design choice.
7. Speculative concerns are insufficient - identify concrete problems.
8. **Iteration hygiene:** Only flag issues that are new or still unresolved. Do not re-raise issues already addressed unless the spec regressed or the fix is incomplete.
9. **Avoid scope creep:** Do not demand exhaustive protocol/edge details unless they are required to implement safely.

### Comment Guidelines

1. Be clear about why the issue blocks implementation or causes ambiguity.
2. Communicate severity appropriately - don't overstate.
3. Keep comments brief (1 paragraph max).
4. Reference specific spec sections.
5. Suggest concrete fixes where possible.
6. Maintain a matter-of-fact, helpful tone.
7. Avoid flattery and unhelpful commentary.

### Red Flags

- Implementation steps that skip necessary prerequisites
- No error handling strategy for critical operations
- Vague acceptance criteria ("should work well")
- Missing data model or API contracts
- No backwards compatibility consideration
- Unclear ownership of components
- Unverifiable requirements

### Priority Levels

- [P0] - Spec is fundamentally unclear. Cannot implement as written.
- [P1] - Urgent gap. Will cause implementation failures.
- [P2] - Normal. Should be clarified before implementation.
- [P3] - Low. Nice to have clarity.

### Verdict Guidelines

- **PASS**: No P0/P1 issues. P2/P3 can be listed as suggestions without blocking.
- **NEEDS_WORK**: Use sparingly; only if issues block implementation but do not rise to FAIL.
- **FAIL**: Any P0/P1 issues or spec is too vague, contradictory, or incomplete.

## Output Format

JSON only, no markdown code fences:
{
  "findings": [
    {
      "title": "[P1] <= 80 chars, imperative",
      "body": "Markdown explaining why this is a problem",
      "priority": 1,
      "file_path": null,
      "line_start": null,
      "line_end": null
    }
  ],
  "verdict": "PASS" | "FAIL" | "NEEDS_WORK",
  "summary": "1-3 sentence explanation"
}

- PASS: No significant findings
- FAIL: Blocking issues (P0/P1)
- NEEDS_WORK: Non-blocking issues (P2/P3)
- file_path, line_start, line_end: use null for spec reviews (not applicable)

If any guidance here conflicts with these output format rules, follow the spec-review guidelines above.
