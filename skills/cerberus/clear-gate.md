---
name: clear-gate
description: Manually clear the active Cerberus review gate. Operator escape hatch.
---

# Cerberus — Clear Gate (Codex skill)

Resolve the active review gate so the session can stop without completing
the review cycle. Use this when reviewers are stuck, when you have decided
to land a change despite blocking findings, or when an iteration loop has
exhausted retries and needs a manual override.

This skill is the Codex-host wrapper around
`bin/review-gate resolve --reason "manual clear from Codex"`. It sets
`CERBERUS_HOST=codex` so the backend records the host on the resolution.

> **Operator action.** This is a deliberate override. The reason string
> identifies the host that issued the manual clear so audit trails and
> `gate-state.json` history make the source of the resolution
> unambiguous.

## Usage

```
clear-gate
```

The skill takes no arguments. The active run is resolved from the session
registry written by `bin/codex-session-init` during `SessionStart`. If you
want to clear a specific (non-active) run, pass `--session-key` to
`bin/review-gate resolve` directly.

## Install

The bash block below uses a `<CERBERUS_INSTALL_ROOT>` placeholder. At install
time, either:

- Replace every `<CERBERUS_INSTALL_ROOT>` token in this file with the absolute
  path to your Cerberus checkout (the same substitution applied to
  `templates/codex-hooks.json`), OR
- Export `CERBERUS_ROOT=/abs/path/to/cerberus` in your shell profile so the
  fallback is never reached.

See `templates/codex-hooks.json` for the same install procedure.

## Run

```bash
export CERBERUS_HOST=codex

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
    __cb_root="${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-<CERBERUS_INSTALL_ROOT>}}"
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

"${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-<CERBERUS_INSTALL_ROOT>}}/bin/review-gate" resolve \
    --reason "manual clear from Codex"
```
