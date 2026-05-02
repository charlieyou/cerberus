---
name: review-plan
disable-model-invocation: true
description: Iterative plan review with external reviewers
argument-hint: '[--debate] [--mode <fast|smart|max>] [--consensus <majority|all|any>] [--agents <list>] [--max-rounds <n>] [path/to/plan.md] ["<focus area>"]'
---

## Host-Neutral Execution

Before running any Bash snippet in this skill, source the shared Cerberus skill environment helper. This keeps the same skill usable from Claude, Codex, Amp, or a generic shell by resolving `CERBERUS_ROOT`, `CERBERUS_HOST`, and the active run key when the host exposes one.

```bash
cerberus_root=""
cerberus_plugin_root='${CLAUDE_PLUGIN_ROOT}'
case "$cerberus_plugin_root" in
    '$'{CLAUDE_PLUGIN_ROOT}) cerberus_plugin_root="${CLAUDE_PLUGIN_ROOT:-}" ;;
esac
cerberus_skill_dir='${CLAUDE_SKILL_DIR}'
case "$cerberus_skill_dir" in
    '$'{CLAUDE_SKILL_DIR}) cerberus_skill_dir="${CLAUDE_SKILL_DIR:-}" ;;
esac

cerberus_candidates=("${CERBERUS_ROOT:-}" "$cerberus_plugin_root")
if [ -n "$cerberus_skill_dir" ]; then
    cerberus_candidates+=("$(cd -P "$cerberus_skill_dir/../.." 2>/dev/null && pwd || true)")
fi
cerberus_git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$cerberus_git_root" ]; then
    cerberus_candidates+=("$cerberus_git_root")
fi
for cerberus_candidate in "${cerberus_candidates[@]}"; do
    if [ -n "$cerberus_candidate" ] \
        && [[ "$cerberus_candidate" == /* ]] \
        && [ -r "$cerberus_candidate/bin/cerberus-skill-env" ] \
        && [ -x "$cerberus_candidate/bin/review-gate" ] \
        && [ -r "$cerberus_candidate/bin/review-gate-models.sh" ] \
        && [ -r "$cerberus_candidate/config/gemini-readonly-settings.json" ] \
        && [ -r "$cerberus_candidate/config/gemini-readonly-policy.toml" ]; then
        cerberus_root="$cerberus_candidate"
        break
    fi
done
if [ -z "$cerberus_root" ]; then
    echo "cerberus skill: cannot find Cerberus backend; set CERBERUS_ROOT to the checkout root" >&2
    exit 127
fi
export CERBERUS_ROOT="$cerberus_root"
# shellcheck source=/dev/null
. "$cerberus_root/bin/cerberus-skill-env" || exit $?
```

Use `${CERBERUS_ROOT}` when invoking Cerberus binaries below.


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
"$CERBERUS_ROOT/bin/review-gate" spawn-plan-review $ARGUMENTS
```

**IMPORTANT: After running the spawn command, STOP IMMEDIATELY.** Do not poll, wait, or run any further commands. The Stop hook will automatically check for reviewer consensus when you stop.

When running under Codex, `bin/cerberus-skill-env` reads the active run key from `~/.cerberus/runtime/codex/<project-key>/active-session.json`, written by the Codex `SessionStart` / `UserPromptSubmit` hooks. If that registry is missing, start a new Codex session and verify the hooks are installed; skills must not invent run keys because the Stop hook would be unable to associate them with Codex's `session_id`.

Examples:
```bash
# User: /review-plan path/to/plan.md
"$CERBERUS_ROOT/bin/review-gate" spawn-plan-review path/to/plan.md

# User: /review-plan "focus on error handling"
"$CERBERUS_ROOT/bin/review-gate" spawn-plan-review --focus "focus on error handling"

# User: /review-plan --mode max plan.md "check dependencies"
"$CERBERUS_ROOT/bin/review-gate" spawn-plan-review --mode max --focus "check dependencies" plan.md

# User: /review-plan --agents codex,gemini path/to/plan.md
"$CERBERUS_ROOT/bin/review-gate" spawn-plan-review --agents codex,gemini path/to/plan.md

# User: /review-plan --max-rounds 3 path/to/plan.md
"$CERBERUS_ROOT/bin/review-gate" spawn-plan-review --max-rounds 3 path/to/plan.md
"$CERBERUS_ROOT/bin/review-gate" spawn-plan-review --max-rounds 0 path/to/plan.md  # Disable auto-respawn

# User: /review-plan --consensus any path/to/plan.md
"$CERBERUS_ROOT/bin/review-gate" spawn-plan-review --consensus any path/to/plan.md

# User: /review-plan plan.md focus on error handling
"$CERBERUS_ROOT/bin/review-gate" spawn-plan-review plan.md focus on error handling
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
- You manually resolve with `"$CERBERUS_ROOT/bin/review-gate" resolve`

Note: FAIL verdicts and P0/P1 findings always block regardless of consensus mode.
