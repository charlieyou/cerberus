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


Run:

```bash
set +u; if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${PLUGIN_ROOT:-}" ]; then host=codex; elif [ -n "${CLAUDE_SESSION_ID}" ] || [ -n "${CLAUDE_PLUGIN_ROOT}" ] || [ -n "${CLAUDE_SKILL_DIR}" ]; then host=claude; else host="${CERBERUS_HOST:-}"; if [ "$host" = claude-code ]; then host=claude; fi; fi; root="${CERBERUS_ROOT:-}"; if [ -z "$root" ] && [ "$host" = codex ]; then root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then cache_home="${HOME:-}"; [ -n "$cache_home" ] || cache_home="${USERPROFILE:-}"; if [ -n "$cache_home" ]; then cache_file="$cache_home/.codex/cerberus/sessions/$CODEX_THREAD_ID/plugin-root"; if [ -r "$cache_file" ]; then IFS= read -r root < "$cache_file" || true; fi; fi; fi; if [ -z "$root" ] && [ "$host" != codex ]; then root="${CLAUDE_PLUGIN_ROOT}"; [ -n "$root" ] || root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" != codex ]; then skill_dir="${CLAUDE_SKILL_DIR}"; if [ -n "$skill_dir" ]; then root="$(cd "$skill_dir/../.." && pwd)"; fi; fi; [ -n "$root" ] || { echo "cerberus: plugin root not set; set CERBERUS_ROOT and retry" >&2; exit 127; }; bin="$root/bin/cerberus"; export CERBERUS_ROOT="$root"; claude_session="${CLAUDE_SESSION_ID}"; if [ "$host" = claude ]; then export CERBERUS_HOST=claude; elif [ "$host" = codex ]; then export CERBERUS_HOST=codex; fi; if [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then export CERBERUS_HOST=codex CERBERUS_SESSION_ID="$CODEX_THREAD_ID"; elif [ "$host" = claude ] && [ -n "$claude_session" ]; then export CERBERUS_HOST=claude CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$claude_session}"; fi; command -v make >/dev/null 2>&1 || { echo "cerberus: make not found on PATH; install make and retry." >&2; exit 127; }; if ! make -q -C "$root" build >/dev/null 2>&1; then command -v go >/dev/null 2>&1 || { echo "cerberus: Go >= 1.22 not found on PATH; install Go and retry." >&2; exit 127; }; echo "cerberus: building... (this happens once after clone or upgrade)" >&2; start=$(date +%s); make -C "$root" build >&2 || exit $?; end=$(date +%s); echo "cerberus: build complete in $((end-start))s" >&2; fi; "$bin" resolve --reason "manual clear"
```

This resolves the active review gate, allowing you to stop the session without completing the review cycle.
