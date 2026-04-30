---
name: status
description: Show current Cerberus review-gate status as JSON (read-only; never mutates state).
---

# Cerberus — Status (Codex skill)

Print the current review-gate status for the active run as a single JSON
document on stdout. The skill never mutates gate state — `status --json`
is the read-only contract verified by `bin/tests/test-status-command.sh`.

This skill is the Codex-host wrapper around `bin/review-gate status --json`.
It sets `CERBERUS_HOST=codex` so the backend resolves state under the
Codex runtime tree.

## Usage

```
status
```

The skill takes no arguments. The active run key is resolved from the
session registry written by `bin/codex-session-init` during `SessionStart`.
If you want to inspect a specific (non-active) run, pass `--session-key`
to `bin/review-gate status --json` directly.

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
    __cb_root="${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-.}}"
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

"${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-.}}/bin/review-gate" status --json
```

## Output

`status --json` emits a single JSON object on stdout. The shape varies by
gate state, but the top-level keys you can rely on are:

- `status` — one of `no_active_gate`, `pending`, `passed`, `failed`,
  `cleared`, `error`, `unknown` (failure-open).
- `host` — the host that owns the run (`claude`, `codex`, `amp`, …).
- `run_key` — the run key resolved by `__cerberus_resolve_run_key`.
- Additional shape per state: `reviewers`, `findings`, `verdict`,
  `iteration`, `last_emit`, etc., depending on the gate's progress.

Exit codes:

- `0` — gate found, body emitted.
- `4` — no active gate (body: `{"status":"no_active_gate"}`).
- non-zero / non-4 — backend failure; body is `{"status":"unknown",...}`.

The skill always emits valid JSON on stdout; consumers should parse the
JSON rather than rely on the exit code alone.
