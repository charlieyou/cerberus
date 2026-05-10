---
name: status
description: Show current Cerberus gate status as JSON (read-only; never mutates state).
disable-model-invocation: true
---

## Host-Neutral Execution

Before running any Bash snippet in this skill, run the shared Cerberus resolver below. It lazily builds and executes `bin/cerberus` from the configured plugin root.

```bash
# --- shared resolver (canonical body; identical across all callers) ---
root="${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}"
bin="$root/bin/cerberus"
[ -n "$root" ] || { echo "cerberus: plugin root not set" >&2; exit 127; }
command -v make >/dev/null 2>&1 || { echo "cerberus: make not found on PATH; install make and retry." >&2; exit 127; }
if ! make -q -C "$root" build >/dev/null 2>&1; then
    command -v go >/dev/null 2>&1 || { echo "cerberus: Go >= 1.22 not found on PATH; install Go and retry." >&2; exit 127; }
    echo "cerberus: building... (this happens once after clone or upgrade)" >&2
    start=$(date +%s)
    make -C "$root" build >&2 || exit $?
    end=$(date +%s)
    echo "cerberus: build complete in $((end-start))s" >&2
fi
# --- shared resolver above; per-caller exec below (allowed to diverge) ---
exec "$bin" "$@"
```

Use `bin/cerberus` through the configured plugin root when invoking Cerberus commands below.


# Cerberus — Status

Print the current Cerberus gate status for the active run as a single JSON document on stdout. The skill never mutates gate state; `status --json` is the read-only contract verified by `bin/tests/test-status-command.sh`.

## Usage

```text
/cerberus:status
```

The active run key is resolved by the shared backend from the current host environment. To inspect a specific non-active run, pass `--session-key` to `bin/cerberus status --json` directly.

## Run

Use the Bash tool to run the backend status command:

```bash
"${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/cerberus" status --json $ARGUMENTS
```

## Output

`status --json` emits a single JSON object on stdout. Active gates use the canonical gate shape:

- `gate_status` — one of `pending`, `awaiting_decision`, `resolved`, or `unknown`.
- `consensus_verdict` — one of `pass`, `fail`, `needs_revision`, or JSON `null` while still pending.
- `host` — the host that owns the run (`claude`, `codex`, or `generic`).
- `run_key` — the run key resolved by `__cerberus_resolve_run_key`.
- `reviewers`, `pending_reviewers`, `aggregated_findings`, and `parse_errors` describe review progress and findings.

Special/error bodies use a smaller shape keyed by `status`, primarily `{"status":"no_active_gate"}` or `{"status":"unknown","error":"malformed_state"}`.

Exit codes:

- `0` — body emitted for an active gate or malformed-state failure-open path.
- `4` — no active gate (body: `{"status":"no_active_gate"}`).
- non-zero / non-4 — backend failure; body is valid JSON with an error payload.

Parse the JSON body rather than relying on the exit code alone.
