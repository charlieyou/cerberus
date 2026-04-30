---
name: review-spec
description: Spawn a multi-model spec review. An explicit spec path is required.
arguments:
  - name: spec-path
    required: true
    description: Path to the spec markdown file to review. Codex hosts have no spec registry — the path must be supplied explicitly.
  - name: flags-and-focus
    required: false
    description: Optional flags ([--mode <fast|smart|max>] [--consensus <majority|all|any>] [--agents <list>] [--max-rounds <n>]) followed by an optional free-text focus area.
---

# Cerberus — Review Spec (Codex skill)

Spawn the external reviewer panel (Codex, Gemini, Claude) on a feature
specification file and iterate until consensus is reached.

This skill is the Codex-host wrapper around `bin/review-gate spawn-spec-review`.
It sets `CERBERUS_HOST=codex` so the backend records the host and resolves
state under the Codex runtime tree.

> **Spec path is required.** v1 of the Codex port does NOT consult a spec
> registry. Failing to supply a path is a clear user error; there is no
> Claude-style fallback.

## Usage

```
review-spec path/to/spec.md
review-spec --mode max path/to/spec.md
review-spec --agents codex,gemini path/to/spec.md
review-spec --max-rounds 3 path/to/spec.md
review-spec --consensus any path/to/spec.md
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
    echo "review-spec: a spec path is required (Codex v1 has no spec registry)" >&2
    exit 2
fi
"${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-.}}/bin/review-gate" spawn-spec-review "$@"
```

After the spawn returns, **stop the turn**. The Codex `Stop` hook will reattach
to the run on the next stop boundary and either allow the stop or surface
reviewer findings as a continuation message.

## Tier System

Specs are tiered by complexity. Reviewers MUST respect the stated tier and
only require sections appropriate for that tier.

| Tier | Use Case            | Required Sections                                                                                                  |
|------|---------------------|--------------------------------------------------------------------------------------------------------------------|
| S    | Bug fix / tiny tweak| Problem, change summary, scope boundary, UX impact, acceptance bullets, validation method                          |
| M    | Small feature       | S + Goal, success criteria, non-goals, primary flow, key states, requirements with MUST + examples, instrumentation |
| L    | Multi-flow project  | M + Constraints, alternate flows, full GWT, edge cases per requirement, detailed instrumentation, launch checklist  |

**Tier mismatch handling:**

- Do NOT fail a Tier S spec for missing M/L sections.
- If you believe the tier is dangerously low for the complexity, flag a
  P1 recommendation to upgrade tier rather than failing the spec.
- Record tier concerns in the review, but respect the author's tier.

## Iteration Loop

The iterative review continues until:

- Consensus is reached (per `--consensus`, default `majority`).
- Maximum iterations are reached (default 3, configurable via `--max-rounds`;
  set `0` to disable auto-respawn).
- The user clears the gate via the `clear-gate` skill.
