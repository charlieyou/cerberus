---
description: Iterative plan review with external reviewers
argument-hint: [--agents <list>] [--max-rounds <n>] [--mode <fast|smart|max>] [path/to/plan.md] ["<focus area>"]
---

# Plan Review (Iterative)

Spawn external reviewers (Codex, Gemini, Claude) to evaluate a plan file directly. Fix issues until all reviewers pass.

## Usage

Pass `$ARGUMENTS` directly. The CLI accepts `--agents`, `--max-rounds`, `--mode`, an optional plan path, plus an optional focus string (either `--focus "<text>"` or trailing free-text; use `--` to force focus when needed).

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-plan-review $ARGUMENTS
```

**IMPORTANT: After running the spawn command, STOP IMMEDIATELY.** Do not poll, wait, or run any further commands. The Stop hook will automatically check for reviewer consensus when you stop.

Examples:
```bash
# User: /review-plan path/to/plan.md
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-plan-review path/to/plan.md

# User: /review-plan "focus on error handling"
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-plan-review --focus "focus on error handling"

# User: /review-plan --mode max plan.md "check dependencies"
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-plan-review --mode max --focus "check dependencies" plan.md

# User: /review-plan --agents codex,gemini path/to/plan.md
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-plan-review --agents codex,gemini path/to/plan.md

# User: /review-plan --max-rounds 3 path/to/plan.md
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-plan-review --max-rounds 3 path/to/plan.md

# User: /review-plan plan.md focus on error handling
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-plan-review plan.md focus on error handling
```

If no path is provided, the most recent plan from `~/.claude/plans/` will be used.

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

- **Template & Structure** - Does it follow the standard implementation plan template (context, scope, prerequisites, detailed tasks with verification and rollback, risks, testing, rollback, open questions)?
- **Completeness** - Does it cover all necessary changes, including migrations, config/env, rollout, rollback, monitoring, and documentation?
- **Correctness** - Are the proposed modifications technically sound and grounded in the described codebase?
- **Order of Operations & Dependencies** - Are steps sequenced correctly (prerequisites and safety work first)?
- **Edge Cases & Risk** - Are error paths, fallbacks, and failure modes addressed?
- **Breaking Changes & Rollout/Rollback** - Are compatibility risks identified, with clear rollout and rollback strategies?
- **Testability & Verification** - Can the implementation be verified, with per-task verification steps and an overall testing strategy?
- **Scope** - Is the plan appropriately scoped (MVP vs follow-ups, clear non-goals)?

## Iteration Loop

The iterative review continues until:
- All reviewers agree the plan passes (unanimous PASS)
- Maximum iterations (default 5, configurable via --max-rounds) are reached
- You manually resolve with `${CLAUDE_PLUGIN_ROOT}/bin/review-gate resolve`
