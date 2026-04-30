---
name: review-plan
description: Spawn a multi-model plan review. An explicit plan path is required.
arguments:
  - name: plan-path
    required: true
    description: Path to the plan markdown file to review. Codex hosts have no plan registry — the path must be supplied explicitly.
  - name: flags-and-focus
    required: false
    description: Optional flags ([--mode <fast|smart|max>] [--consensus <majority|all|any>] [--agents <list>] [--max-rounds <n>]) followed by an optional free-text focus area.
---

# Cerberus — Review Plan (Codex skill)

Spawn the external reviewer panel (Codex, Gemini, Claude) on a plan markdown
file and iterate until consensus is reached.

This skill is the Codex-host wrapper around `bin/review-gate spawn-plan-review`.
It sets `CERBERUS_HOST=codex` so the backend records the host and locates state
under the Codex runtime tree.

> **Plan path is required.** v1 of the Codex port does NOT consult a plan
> registry. If you forget the path, the skill exits with a clear error;
> there is no Claude-style "use the most recent plan" fallback.

## Usage

```
review-plan path/to/plan.md
review-plan --mode max path/to/plan.md
review-plan --agents codex,gemini path/to/plan.md
review-plan --max-rounds 3 path/to/plan.md
review-plan --consensus any path/to/plan.md
review-plan path/to/plan.md "focus on error handling"
```

**Consensus modes:**
- `majority` (default): at least 2 reviewers PASS, or all valid reviewers PASS.
- `all`: all valid reviewers must PASS (errored reviewers are skipped).
- `any`: at least one reviewer PASS.

FAIL verdicts and P0/P1 findings always block regardless of consensus mode.

## Run the Review

Invoke the shared backend with `CERBERUS_HOST=codex` exported.

```bash
export CERBERUS_HOST=codex
if [ "$#" -lt 1 ]; then
    echo "review-plan: a plan path is required (Codex v1 has no plan registry)" >&2
    exit 2
fi
"${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-.}}/bin/review-gate" spawn-plan-review "$@"
```

After the spawn returns, **stop the turn**. The Codex `Stop` hook will reattach
to the run on the next stop boundary and either allow the stop or surface
reviewer findings as a continuation message.

## Review Criteria

Reviewers evaluate the plan for:

- **Template & Structure** — does it follow the standard plan template?
- **Completeness** — does it cover architecture, data model, interfaces,
  file impact, and monitoring as needed?
- **Correctness** — are the proposed design choices technically sound and
  grounded in the described codebase?
- **Prerequisites & Dependencies** — are prerequisites called out
  (access, infra, flags)? External dependencies clear?
- **Edge Cases & Risk** — are error paths, fallbacks, and failure modes
  addressed?
- **Testability & Verification** — is there a clear testing strategy that
  maps to acceptance criteria?
- **Scope** — is the plan appropriately scoped (MVP vs follow-ups, clear
  non-goals)?

Plans should NOT contain detailed task breakdowns — that is handled
separately by task-creation workflows.

## Iteration Loop

The iterative review continues until:

- Consensus is reached (per `--consensus`, default `majority`).
- Maximum iterations are reached (default 3, configurable via `--max-rounds`;
  set `0` to disable auto-respawn).
- The user clears the gate via the `clear-gate` skill.
