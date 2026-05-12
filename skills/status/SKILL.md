---
name: status
description: Show current Cerberus gate status as JSON (read-only; never mutates state).
disable-model-invocation: true
---

## Host-Neutral Execution

Before running any Bash snippet in this skill, run the shared Cerberus resolver below. It lazily builds and executes `bin/cerberus` from the configured plugin root.

```bash
# --- shared resolver (canonical body; identical across all callers) ---
set +u
if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${PLUGIN_ROOT:-}" ]; then
    host=codex
elif [ -n "${CLAUDE_SESSION_ID}" ] || [ -n "${CLAUDE_PLUGIN_ROOT}" ] || [ -n "${CLAUDE_SKILL_DIR}" ]; then
    host=claude
else
    host="${CERBERUS_HOST:-}"
    if [ "$host" = claude-code ]; then
        host=claude
    fi
fi
root="${CERBERUS_ROOT:-}"
if [ -z "$root" ] && [ "$host" = codex ]; then
    root="${PLUGIN_ROOT:-}"
fi
if [ -z "$root" ] && [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then
    cache_home="${HOME:-}"
    [ -n "$cache_home" ] || cache_home="${USERPROFILE:-}"
    if [ -n "$cache_home" ]; then
        cache_file="$cache_home/.codex/cerberus/sessions/$CODEX_THREAD_ID/plugin-root"
        if [ -r "$cache_file" ]; then
            IFS= read -r root < "$cache_file" || true
        fi
    fi
fi
if [ -z "$root" ] && [ "$host" != codex ]; then
    root="${CLAUDE_PLUGIN_ROOT}"
    [ -n "$root" ] || root="${PLUGIN_ROOT:-}"
fi
if [ -z "$root" ] && [ "$host" != codex ]; then
    skill_dir="${CLAUDE_SKILL_DIR}"
    if [ -n "$skill_dir" ]; then
        root="$(cd "$skill_dir/../.." && pwd)"
    fi
fi
[ -n "$root" ] || { echo "cerberus: plugin root not set; set CERBERUS_ROOT and retry" >&2; exit 127; }
bin="$root/bin/cerberus"
export CERBERUS_ROOT="$root"
claude_session="${CLAUDE_SESSION_ID}"
if [ "$host" = claude ]; then
    export CERBERUS_HOST=claude
elif [ "$host" = codex ]; then
    export CERBERUS_HOST=codex
fi
if [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then
    export CERBERUS_HOST=codex CERBERUS_SESSION_ID="$CODEX_THREAD_ID"
elif [ "$host" = claude ] && [ -n "$claude_session" ]; then
    export CERBERUS_HOST=claude CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$claude_session}"
fi
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
# --- shared resolver (canonical body; identical across all callers) ---
set +u
if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${PLUGIN_ROOT:-}" ]; then
    host=codex
elif [ -n "${CLAUDE_SESSION_ID}" ] || [ -n "${CLAUDE_PLUGIN_ROOT}" ] || [ -n "${CLAUDE_SKILL_DIR}" ]; then
    host=claude
else
    host="${CERBERUS_HOST:-}"
    if [ "$host" = claude-code ]; then
        host=claude
    fi
fi
root="${CERBERUS_ROOT:-}"
if [ -z "$root" ] && [ "$host" = codex ]; then
    root="${PLUGIN_ROOT:-}"
fi
if [ -z "$root" ] && [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then
    cache_home="${HOME:-}"
    [ -n "$cache_home" ] || cache_home="${USERPROFILE:-}"
    if [ -n "$cache_home" ]; then
        cache_file="$cache_home/.codex/cerberus/sessions/$CODEX_THREAD_ID/plugin-root"
        if [ -r "$cache_file" ]; then
            IFS= read -r root < "$cache_file" || true
        fi
    fi
fi
if [ -z "$root" ] && [ "$host" != codex ]; then
    root="${CLAUDE_PLUGIN_ROOT}"
    [ -n "$root" ] || root="${PLUGIN_ROOT:-}"
fi
if [ -z "$root" ] && [ "$host" != codex ]; then
    skill_dir="${CLAUDE_SKILL_DIR}"
    if [ -n "$skill_dir" ]; then
        root="$(cd "$skill_dir/../.." && pwd)"
    fi
fi
[ -n "$root" ] || { echo "cerberus: plugin root not set; set CERBERUS_ROOT and retry" >&2; exit 127; }
bin="$root/bin/cerberus"
export CERBERUS_ROOT="$root"
claude_session="${CLAUDE_SESSION_ID}"
if [ "$host" = claude ]; then
    export CERBERUS_HOST=claude
elif [ "$host" = codex ]; then
    export CERBERUS_HOST=codex
fi
if [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then
    export CERBERUS_HOST=codex CERBERUS_SESSION_ID="$CODEX_THREAD_ID"
elif [ "$host" = claude ] && [ -n "$claude_session" ]; then
    export CERBERUS_HOST=claude CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$claude_session}"
fi
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
exec "$bin" status --json $ARGUMENTS
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
