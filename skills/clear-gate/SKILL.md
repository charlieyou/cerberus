---
name: clear-gate
disable-model-invocation: true
description: Clear the review gate and allow the session to stop
---

## Host-Neutral Execution

Before running any Bash snippet in this skill, run the shared Cerberus resolver below. It lazily builds and executes `bin/cerberus` from the configured plugin root.

```bash
# --- shared resolver (canonical body; identical across all callers) ---
set +u
root="${CERBERUS_ROOT:-}"
[ -n "$root" ] || root="${CLAUDE_PLUGIN_ROOT}"
[ -n "$root" ] || root="${PLUGIN_ROOT:-}"
if [ -z "$root" ]; then
    skill_dir="${CLAUDE_SKILL_DIR}"
    if [ -n "$skill_dir" ]; then
        root="$(cd "$skill_dir/../.." && pwd)"
    fi
fi
bin="$root/bin/cerberus"
[ -n "$root" ] || { echo "cerberus: plugin root not set" >&2; exit 127; }
export CERBERUS_ROOT="$root"
claude_session="${CLAUDE_SESSION_ID}"
if [ "${CERBERUS_HOST:-}" = claude-code ]; then
    export CERBERUS_HOST=claude
fi
if [ -n "${CODEX_THREAD_ID:-}" ] && { [ -z "${CERBERUS_HOST:-}" ] || [ "${CERBERUS_HOST:-}" = codex ]; }; then
    export CERBERUS_HOST=codex CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$CODEX_THREAD_ID}"
elif [ -z "${CERBERUS_HOST:-}" ] && [ -n "$claude_session" ]; then
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


Run:

```bash
set +u; root="${CERBERUS_ROOT:-}"; [ -n "$root" ] || root="${CLAUDE_PLUGIN_ROOT}"; [ -n "$root" ] || root="${PLUGIN_ROOT:-}"; if [ -z "$root" ]; then skill_dir="${CLAUDE_SKILL_DIR}"; if [ -n "$skill_dir" ]; then root="$(cd "$skill_dir/../.." && pwd)"; fi; fi; bin="$root/bin/cerberus"; [ -n "$root" ] || { echo "cerberus: plugin root not set" >&2; exit 127; }; export CERBERUS_ROOT="$root"; claude_session="${CLAUDE_SESSION_ID}"; if [ "${CERBERUS_HOST:-}" = claude-code ]; then export CERBERUS_HOST=claude; fi; if [ -n "${CODEX_THREAD_ID:-}" ] && { [ -z "${CERBERUS_HOST:-}" ] || [ "${CERBERUS_HOST:-}" = codex ]; }; then export CERBERUS_HOST=codex CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$CODEX_THREAD_ID}"; elif [ -z "${CERBERUS_HOST:-}" ] && [ -n "$claude_session" ]; then export CERBERUS_HOST=claude CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$claude_session}"; fi; if ! make -q -C "$root" build >/dev/null 2>&1; then make -C "$root" build >&2 || exit $?; fi; "$bin" resolve --reason "manual clear"
```

This resolves the active review gate, allowing you to stop the session without completing the review cycle.
