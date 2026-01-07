---
description: Iterative plan review with external reviewers
argument-hint: [--mode <fast|smart|max>] [--consensus <majority|all|any>] [--agents <list>] [--max-rounds <n>] [path/to/plan.md] ["<focus area>"]
---

# Plan Review (Iterative)

Spawn external reviewers (Codex, Gemini, Claude) to evaluate a plan file directly. Fix issues until consensus is reached (default: majority).

## Usage

Pass `$ARGUMENTS` directly. The CLI accepts `--agents`, `--max-rounds`, `--mode`, `--consensus` (majority/all/any), an optional plan path, plus an optional focus string (either `--focus "<text>"` or trailing free-text; use `--` to force focus when needed).

**Consensus modes:**
- `majority` (default): At least 2 reviewers PASS, or all valid reviewers PASS
- `all`: All valid reviewers must PASS (errored reviewers are skipped)
- `any`: At least one reviewer PASS

Note: FAIL verdicts and P0/P1 findings always block regardless of consensus mode.

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
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-plan-review --max-rounds 0 path/to/plan.md  # Disable auto-respawn

# User: /review-plan --consensus any path/to/plan.md
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-plan-review --consensus any path/to/plan.md

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
   - If consensus passes (per `--consensus` mode): You may proceed (but check for remaining issues first)
   - If any reviewer finds blocking issues (FAIL verdict or P0/P1 findings): You must fix the plan and try again

3. Fix issues in the plan file based on reviewer feedback, then the review automatically re-runs.

## After Passing

When consensus passes, you MUST fix any remaining issues or suggestions noted in the feedback before proceeding.

## Review Criteria

Reviewers evaluate the plan for:

- **Template & Structure** - Does it follow the standard implementation plan template (context, scope, assumptions/constraints, prerequisites, high-level approach, technical design, risks, testing, open questions)?
- **Completeness** - Does it cover all necessary design decisions, including architecture, data model, interfaces, file impact, and monitoring?
- **Correctness** - Are the proposed design choices technically sound and grounded in the described codebase?
- **Prerequisites & Dependencies** - Are prerequisites called out explicitly (access, infra, flags)? Are external dependencies clear?
- **Edge Cases & Risk** - Are error paths, fallbacks, and failure modes addressed?
- **Testability & Verification** - Is there a clear testing strategy that maps to acceptance criteria?
- **Scope** - Is the plan appropriately scoped (MVP vs follow-ups, clear non-goals)?

Note: Plans should NOT contain detailed task breakdowns (Task 1, Task 2, etc.) — that is handled separately by `/create-tasks`.

## Iteration Loop

The iterative review continues until:
- Consensus is reached (per `--consensus` mode, default: majority)
- Maximum iterations (default 3, configurable via --max-rounds; set `0` to disable auto-respawn) are reached
- You manually resolve with `${CLAUDE_PLUGIN_ROOT}/bin/review-gate resolve`

Note: FAIL verdicts and P0/P1 findings always block regardless of consensus mode.
