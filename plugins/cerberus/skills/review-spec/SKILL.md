---
name: review-spec
description: Spawn a multi-model spec review. An explicit spec path is required.
arguments:
  - name: spec-path
    required: true
    description: Path to the spec markdown file to review. Codex hosts have no spec registry — the path must be supplied explicitly.
  - name: flags
    required: false
    description: Optional flags ([--mode <fast|smart|max>] [--consensus <majority|all|any>] [--agents <list>] [--max-rounds <n>] [--debate] [--debate-seed <n>]). spawn-spec-review does not accept a free-text focus; pass focus inside the spec file itself.
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

## Install

Codex caches the skill markdown when it installs the plugin, so this file is
not edited during install. Set `CERBERUS_ROOT=/abs/path/to/cerberus` in Codex's
shell environment. It must point at the Cerberus backend checkout root: the
directory that contains `bin/review-gate`, `bin/review-gate-lib.sh`, and
`templates/codex-hooks.json`.

## Run the Review

Invoke the shared backend with `CERBERUS_HOST=codex` exported.

```bash
export CERBERUS_HOST=codex

cerberus_root="${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"
if [ -z "$cerberus_root" ] || [ ! -x "$cerberus_root/bin/review-gate" ]; then
    echo "review-spec: cannot find Cerberus backend; set CERBERUS_ROOT to the Cerberus checkout root (the directory containing bin/review-gate)" >&2
    exit 127
fi
export CERBERUS_ROOT="$cerberus_root"
review_gate="$cerberus_root/bin/review-gate"

# Bootstrap CERBERUS_RUN_KEY from the codex-session-init registry on disk.
# Codex doesn't expose a stable session-id env var; the SessionStart hook
# (bin/codex-session-init, wired via templates/codex-hooks.json) persists
# the run-key to ~/.cerberus/runtime/codex/<project-key>/active-session.json
# instead. User shells that invoke a skill mid-session don't normally
# inherit CERBERUS_RUN_KEY, so we re-read it from disk here. The bootstrap
# is a no-op when the env already has CERBERUS_RUN_KEY /
# REVIEW_GATE_SESSION_KEY / CLAUDE_SESSION_ID, so explicit overrides win.
if [ -z "${CERBERUS_RUN_KEY:-}" ] && [ -z "${REVIEW_GATE_SESSION_KEY:-}" ] \
   && [ -z "${CLAUDE_SESSION_ID:-}" ] && command -v jq >/dev/null 2>&1; then
    __cb_root="$cerberus_root"
    if [ -r "$__cb_root/bin/review-gate-lib.sh" ]; then
        # shellcheck source=/dev/null
        . "$__cb_root/bin/review-gate-lib.sh" >/dev/null 2>&1 || :
        if type get_project_hash >/dev/null 2>&1; then
            __cb_pk="$(get_project_hash "" 2>/dev/null || true)"
            __cb_reg="$HOME/.cerberus/runtime/codex/$__cb_pk/active-session.json"
            if [ -n "$__cb_pk" ] && [ -r "$__cb_reg" ]; then
                __cb_rk="$(jq -r '.run_key // empty' "$__cb_reg" 2>/dev/null || true)"
                [ -n "$__cb_rk" ] && export CERBERUS_RUN_KEY="$__cb_rk"
                unset __cb_rk
            fi
            unset __cb_pk __cb_reg
        fi
    fi
    unset __cb_root
fi

# Verify a spec-path-shaped positional arg is present BEFORE handing off to
# the backend. The backend already dies with "Spec path is required" when no
# path is supplied, but a fast pre-flight check produces a clearer Codex-side
# error and is symmetric with the review-plan guard. We mirror the backend's
# path-detection heuristic so any positional the backend would accept as a
# spec path also passes this guard.
__looks_like_spec_path() {
    [ -f "$1" ] && return 0
    case "$1" in
        /*|./*|../*|*/*|*.md) return 0 ;;
        *) return 1 ;;
    esac
}

have_spec_path=0
i=1
while [ "$i" -le "$#" ]; do
    a="${!i}"
    case "$a" in
        --agents|--max-rounds|--mode|--consensus|--context-file|--debate-seed|--session-id|--transcript-path)
            i=$((i + 2)); continue ;;
        --debate|-h|--help)
            i=$((i + 1)); continue ;;
        --)
            # spawn-spec-review breaks out of arg parsing at `--` and never
            # consumes another positional after it, so any post-`--` token
            # is ignored by the backend. Mirror that here so we don't let a
            # post-`--` token satisfy the path requirement.
            break ;;
        --*=*|-*)
            i=$((i + 1)); continue ;;
        *)
            if __looks_like_spec_path "$a"; then
                have_spec_path=1
                break
            fi
            i=$((i + 1)); continue ;;
    esac
done

if [ "$have_spec_path" -eq 0 ]; then
    echo "review-spec: a spec path is required (Codex v1 has no spec registry; pass an explicit path/to/spec.md)" >&2
    exit 2
fi

"$review_gate" spawn-spec-review "$@"
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
