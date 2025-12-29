---
description: Iterative plan review with external reviewers
argument-hint: [--agents <list>] [path/to/plan.md]
---

# Plan Review (Iterative)

Spawn external reviewers (Codex, Gemini, Claude) to evaluate a plan file directly. Fix issues until all reviewers pass.

## Usage

Run the spawn command with the plan path (or use session plan if none provided):

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-plan-review $ARGUMENTS
```

If no path is provided, the most recent plan from `~/.claude/plans/` will be used.

Example to run a subset of reviewers:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-plan-review --agents codex,gemini path/to/plan.md
```

## How It Works

1. External reviewers (Codex, Gemini, Claude) evaluate the plan for:
   - Completeness and correctness
   - Order of operations and dependencies
   - Edge cases and error handling
   - Breaking changes and testability

2. The Stop hook waits for reviewers and checks consensus:
   - If all reviewers PASS: You may proceed
   - If any reviewer finds issues: You must fix the plan and try again

3. Fix issues in the plan file based on reviewer feedback, then the review automatically re-runs.

## Review Criteria

Reviewers evaluate the plan for:

- **Completeness** - Does it cover all necessary changes?
- **Correctness** - Are the proposed modifications technically sound?
- **Order of Operations** - Are steps sequenced correctly (dependencies first)?
- **Edge Cases** - Are error paths, fallbacks, and corner cases addressed?
- **Breaking Changes** - Are backwards compatibility concerns identified?
- **Testability** - Can the implementation be verified?

## Iteration Loop

The iterative review continues until:
- All reviewers agree the plan passes (unanimous PASS)
- Maximum iterations (5) are reached
- You manually resolve with `${CLAUDE_PLUGIN_ROOT}/bin/review-gate resolve proceed` or `${CLAUDE_PLUGIN_ROOT}/bin/review-gate resolve abort`
