<!-- review-type: plan -->
<!-- plan-path: /private/var/folders/z3/l8rvvd1109bb1wvnm9k7tql80000gn/T/capture-pre-debate.XXXXXX.7OZh5xLA4C/sample-plan.md -->
<!-- plan-sha: 5b353e2d6f7778b43d6b9112ebe18c7188bc5369925c9e80fa4f07546e6a24d2 -->
<!-- max-rounds: 3 -->
<!-- agents: codex,gemini,claude -->
<!-- mode: smart -->

# Plan Review (Iterative)

## Plan Path
/private/var/folders/z3/l8rvvd1109bb1wvnm9k7tql80000gn/T/capture-pre-debate.XXXXXX.7OZh5xLA4C/sample-plan.md

## Plan Content

```markdown
# Feature Plan: Pre-Debate Baseline Fixture Capture

## Goal

Add baseline golden fixture capture to support R9 byte-parity tests for
the pre-debate feature branch.

## Steps

1. Create capture script at bin/tests/capture-pre-debate-baseline.sh
2. Create sample input documents for each invocation shape
3. Run each invocation shape with canned reviewer outputs
4. Capture prompt, schema, gate-state, and gate-report artifacts
5. Commit fixtures to bin/tests/fixtures/pre-debate-baseline/

## Success Criteria

- All 5 invocation shapes produce non-empty fixture captures
- Prompts match what the current plugin version would produce interactively
- gate-state.json shows status: "resolved" after stop-hook runs
```
