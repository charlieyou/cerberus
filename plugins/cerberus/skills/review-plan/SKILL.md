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
    echo "review-plan: cannot find Cerberus backend; set CERBERUS_ROOT to the Cerberus checkout root (the directory containing bin/review-gate)" >&2
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

# Verify a plan-path-shaped positional arg is present BEFORE handing off to
# the backend. The backend's `spawn-plan-review` falls back to the most-recent
# plan in `$HOME/.claude/plans/` when no path is supplied, which violates the
# Codex v1 contract that a missing path is a clear user error. We mirror the
# backend's path-detection heuristic (existing file, `/`-prefixed,
# `./`/`../`-prefixed, `.md`-suffixed, or contains `/`) so any positional
# the backend would accept as a plan path also passes this guard, and any
# bare flag-only or free-text-only invocation fails fast.
__looks_like_plan_path() {
    [ -f "$1" ] && return 0
    case "$1" in
        /*|./*|../*|*/*|*.md) return 0 ;;
        *) return 1 ;;
    esac
}

have_plan_path=0
i=1
while [ "$i" -le "$#" ]; do
    a="${!i}"
    case "$a" in
        --agents|--max-rounds|--mode|--consensus|--context-file|--focus|--debate-seed|--session-id|--transcript-path)
            i=$((i + 2)); continue ;;
        --debate|-h|--help)
            i=$((i + 1)); continue ;;
        --)
            # Backend treats everything after `--` as forced focus, never path.
            break ;;
        --*=*|-*)
            i=$((i + 1)); continue ;;
        *)
            if __looks_like_plan_path "$a"; then
                have_plan_path=1
                break
            fi
            i=$((i + 1)); continue ;;
    esac
done

if [ "$have_plan_path" -eq 0 ]; then
    echo "review-plan: a plan path is required (Codex v1 has no plan registry; pass an explicit path/to/plan.md)" >&2
    exit 2
fi

"$review_gate" spawn-plan-review "$@"
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
