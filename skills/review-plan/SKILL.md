---
name: review-plan
disable-model-invocation: true
description: Iterative plan review with external reviewers
argument-hint: '[--debate] [--mode <fast|smart|max>] [--consensus <majority|all|any>] [--agents <list>] [--max-rounds <n>] [path/to/plan.md] ["<focus area>"]'
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


# Plan Review (Iterative)

Spawn external reviewers (Codex, Gemini, Claude) to evaluate a plan file directly. Fix issues until consensus is reached (default: majority).

## Usage

Pass `$ARGUMENTS` directly. The CLI accepts `--agents`, `--max-rounds`, `--mode`, `--consensus` (majority/all/any), an optional plan path, plus an optional focus string (either `--focus "<text>"` or trailing free-text; use `--` to force focus when needed).

**Consensus modes:**
- `majority` (default): At least 2 reviewers PASS, or all valid reviewers PASS
- `all`: All valid reviewers must PASS (errored reviewers are skipped)
- `any`: At least one reviewer PASS

Note: FAIL verdicts and P0/P1 findings always block regardless of consensus mode.

```bash
set +u; if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${PLUGIN_ROOT:-}" ]; then host=codex; elif [ -n "${CLAUDE_SESSION_ID}" ] || [ -n "${CLAUDE_PLUGIN_ROOT}" ] || [ -n "${CLAUDE_SKILL_DIR}" ]; then host=claude; else host="${CERBERUS_HOST:-}"; if [ "$host" = claude-code ]; then host=claude; fi; fi; root="${CERBERUS_ROOT:-}"; if [ -z "$root" ] && [ "$host" = codex ]; then root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then cache_home="${HOME:-}"; [ -n "$cache_home" ] || cache_home="${USERPROFILE:-}"; if [ -n "$cache_home" ]; then cache_file="$cache_home/.codex/cerberus/sessions/$CODEX_THREAD_ID/plugin-root"; if [ -r "$cache_file" ]; then IFS= read -r root < "$cache_file" || true; fi; fi; fi; if [ -z "$root" ] && [ "$host" != codex ]; then root="${CLAUDE_PLUGIN_ROOT}"; [ -n "$root" ] || root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" != codex ]; then skill_dir="${CLAUDE_SKILL_DIR}"; if [ -n "$skill_dir" ]; then root="$(cd "$skill_dir/../.." && pwd)"; fi; fi; [ -n "$root" ] || { echo "cerberus: plugin root not set; set CERBERUS_ROOT and retry" >&2; exit 127; }; bin="$root/bin/cerberus"; export CERBERUS_ROOT="$root"; claude_session="${CLAUDE_SESSION_ID}"; if [ "$host" = claude ]; then export CERBERUS_HOST=claude; elif [ "$host" = codex ]; then export CERBERUS_HOST=codex; fi; if [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then export CERBERUS_HOST=codex CERBERUS_SESSION_ID="$CODEX_THREAD_ID"; elif [ "$host" = claude ] && [ -n "$claude_session" ]; then export CERBERUS_HOST=claude CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$claude_session}"; fi; command -v make >/dev/null 2>&1 || { echo "cerberus: make not found on PATH; install make and retry." >&2; exit 127; }; if ! make -q -C "$root" build >/dev/null 2>&1; then command -v go >/dev/null 2>&1 || { echo "cerberus: Go >= 1.22 not found on PATH; install Go and retry." >&2; exit 127; }; echo "cerberus: building... (this happens once after clone or upgrade)" >&2; start=$(date +%s); make -C "$root" build >&2 || exit $?; end=$(date +%s); echo "cerberus: build complete in $((end-start))s" >&2; fi; "$bin" spawn-plan-review $ARGUMENTS
```

**IMPORTANT: After running the spawn command, STOP IMMEDIATELY.** Do not poll, wait, or run any further commands. The Stop hook will automatically check for reviewer consensus when you stop.

When running under Claude Code, use the documented skill substitutions `${CLAUDE_PLUGIN_ROOT}`, `${CLAUDE_SKILL_DIR}`, and `${CLAUDE_SESSION_ID}` rather than embedding it inside shell-default expansion forms. When running under Codex, set `CERBERUS_HOST=codex` and `CERBERUS_SESSION_ID` to the current `CODEX_THREAD_ID` before spawning if they are not already exported. The command above does that automatically when `CODEX_THREAD_ID` is present and `CERBERUS_HOST` is unset or already `codex`. If host state is still missing or stale, start a new host session and verify the hooks are installed.

Examples:
```bash
# User: /review-plan path/to/plan.md
set +u; if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${PLUGIN_ROOT:-}" ]; then host=codex; elif [ -n "${CLAUDE_SESSION_ID}" ] || [ -n "${CLAUDE_PLUGIN_ROOT}" ] || [ -n "${CLAUDE_SKILL_DIR}" ]; then host=claude; else host="${CERBERUS_HOST:-}"; if [ "$host" = claude-code ]; then host=claude; fi; fi; root="${CERBERUS_ROOT:-}"; if [ -z "$root" ] && [ "$host" = codex ]; then root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then cache_home="${HOME:-}"; [ -n "$cache_home" ] || cache_home="${USERPROFILE:-}"; if [ -n "$cache_home" ]; then cache_file="$cache_home/.codex/cerberus/sessions/$CODEX_THREAD_ID/plugin-root"; if [ -r "$cache_file" ]; then IFS= read -r root < "$cache_file" || true; fi; fi; fi; if [ -z "$root" ] && [ "$host" != codex ]; then root="${CLAUDE_PLUGIN_ROOT}"; [ -n "$root" ] || root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" != codex ]; then skill_dir="${CLAUDE_SKILL_DIR}"; if [ -n "$skill_dir" ]; then root="$(cd "$skill_dir/../.." && pwd)"; fi; fi; [ -n "$root" ] || { echo "cerberus: plugin root not set; set CERBERUS_ROOT and retry" >&2; exit 127; }; bin="$root/bin/cerberus"; export CERBERUS_ROOT="$root"; claude_session="${CLAUDE_SESSION_ID}"; if [ "$host" = claude ]; then export CERBERUS_HOST=claude; elif [ "$host" = codex ]; then export CERBERUS_HOST=codex; fi; if [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then export CERBERUS_HOST=codex CERBERUS_SESSION_ID="$CODEX_THREAD_ID"; elif [ "$host" = claude ] && [ -n "$claude_session" ]; then export CERBERUS_HOST=claude CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$claude_session}"; fi; command -v make >/dev/null 2>&1 || { echo "cerberus: make not found on PATH; install make and retry." >&2; exit 127; }; if ! make -q -C "$root" build >/dev/null 2>&1; then command -v go >/dev/null 2>&1 || { echo "cerberus: Go >= 1.22 not found on PATH; install Go and retry." >&2; exit 127; }; echo "cerberus: building... (this happens once after clone or upgrade)" >&2; start=$(date +%s); make -C "$root" build >&2 || exit $?; end=$(date +%s); echo "cerberus: build complete in $((end-start))s" >&2; fi; "$bin" spawn-plan-review path/to/plan.md

# User: /review-plan "focus on error handling"
set +u; if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${PLUGIN_ROOT:-}" ]; then host=codex; elif [ -n "${CLAUDE_SESSION_ID}" ] || [ -n "${CLAUDE_PLUGIN_ROOT}" ] || [ -n "${CLAUDE_SKILL_DIR}" ]; then host=claude; else host="${CERBERUS_HOST:-}"; if [ "$host" = claude-code ]; then host=claude; fi; fi; root="${CERBERUS_ROOT:-}"; if [ -z "$root" ] && [ "$host" = codex ]; then root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then cache_home="${HOME:-}"; [ -n "$cache_home" ] || cache_home="${USERPROFILE:-}"; if [ -n "$cache_home" ]; then cache_file="$cache_home/.codex/cerberus/sessions/$CODEX_THREAD_ID/plugin-root"; if [ -r "$cache_file" ]; then IFS= read -r root < "$cache_file" || true; fi; fi; fi; if [ -z "$root" ] && [ "$host" != codex ]; then root="${CLAUDE_PLUGIN_ROOT}"; [ -n "$root" ] || root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" != codex ]; then skill_dir="${CLAUDE_SKILL_DIR}"; if [ -n "$skill_dir" ]; then root="$(cd "$skill_dir/../.." && pwd)"; fi; fi; [ -n "$root" ] || { echo "cerberus: plugin root not set; set CERBERUS_ROOT and retry" >&2; exit 127; }; bin="$root/bin/cerberus"; export CERBERUS_ROOT="$root"; claude_session="${CLAUDE_SESSION_ID}"; if [ "$host" = claude ]; then export CERBERUS_HOST=claude; elif [ "$host" = codex ]; then export CERBERUS_HOST=codex; fi; if [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then export CERBERUS_HOST=codex CERBERUS_SESSION_ID="$CODEX_THREAD_ID"; elif [ "$host" = claude ] && [ -n "$claude_session" ]; then export CERBERUS_HOST=claude CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$claude_session}"; fi; command -v make >/dev/null 2>&1 || { echo "cerberus: make not found on PATH; install make and retry." >&2; exit 127; }; if ! make -q -C "$root" build >/dev/null 2>&1; then command -v go >/dev/null 2>&1 || { echo "cerberus: Go >= 1.22 not found on PATH; install Go and retry." >&2; exit 127; }; echo "cerberus: building... (this happens once after clone or upgrade)" >&2; start=$(date +%s); make -C "$root" build >&2 || exit $?; end=$(date +%s); echo "cerberus: build complete in $((end-start))s" >&2; fi; "$bin" spawn-plan-review --focus "focus on error handling"

# User: /review-plan --mode max plan.md "check dependencies"
set +u; if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${PLUGIN_ROOT:-}" ]; then host=codex; elif [ -n "${CLAUDE_SESSION_ID}" ] || [ -n "${CLAUDE_PLUGIN_ROOT}" ] || [ -n "${CLAUDE_SKILL_DIR}" ]; then host=claude; else host="${CERBERUS_HOST:-}"; if [ "$host" = claude-code ]; then host=claude; fi; fi; root="${CERBERUS_ROOT:-}"; if [ -z "$root" ] && [ "$host" = codex ]; then root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then cache_home="${HOME:-}"; [ -n "$cache_home" ] || cache_home="${USERPROFILE:-}"; if [ -n "$cache_home" ]; then cache_file="$cache_home/.codex/cerberus/sessions/$CODEX_THREAD_ID/plugin-root"; if [ -r "$cache_file" ]; then IFS= read -r root < "$cache_file" || true; fi; fi; fi; if [ -z "$root" ] && [ "$host" != codex ]; then root="${CLAUDE_PLUGIN_ROOT}"; [ -n "$root" ] || root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" != codex ]; then skill_dir="${CLAUDE_SKILL_DIR}"; if [ -n "$skill_dir" ]; then root="$(cd "$skill_dir/../.." && pwd)"; fi; fi; [ -n "$root" ] || { echo "cerberus: plugin root not set; set CERBERUS_ROOT and retry" >&2; exit 127; }; bin="$root/bin/cerberus"; export CERBERUS_ROOT="$root"; claude_session="${CLAUDE_SESSION_ID}"; if [ "$host" = claude ]; then export CERBERUS_HOST=claude; elif [ "$host" = codex ]; then export CERBERUS_HOST=codex; fi; if [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then export CERBERUS_HOST=codex CERBERUS_SESSION_ID="$CODEX_THREAD_ID"; elif [ "$host" = claude ] && [ -n "$claude_session" ]; then export CERBERUS_HOST=claude CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$claude_session}"; fi; command -v make >/dev/null 2>&1 || { echo "cerberus: make not found on PATH; install make and retry." >&2; exit 127; }; if ! make -q -C "$root" build >/dev/null 2>&1; then command -v go >/dev/null 2>&1 || { echo "cerberus: Go >= 1.22 not found on PATH; install Go and retry." >&2; exit 127; }; echo "cerberus: building... (this happens once after clone or upgrade)" >&2; start=$(date +%s); make -C "$root" build >&2 || exit $?; end=$(date +%s); echo "cerberus: build complete in $((end-start))s" >&2; fi; "$bin" spawn-plan-review --mode max --focus "check dependencies" plan.md

# User: /review-plan --agents codex,gemini path/to/plan.md
set +u; if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${PLUGIN_ROOT:-}" ]; then host=codex; elif [ -n "${CLAUDE_SESSION_ID}" ] || [ -n "${CLAUDE_PLUGIN_ROOT}" ] || [ -n "${CLAUDE_SKILL_DIR}" ]; then host=claude; else host="${CERBERUS_HOST:-}"; if [ "$host" = claude-code ]; then host=claude; fi; fi; root="${CERBERUS_ROOT:-}"; if [ -z "$root" ] && [ "$host" = codex ]; then root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then cache_home="${HOME:-}"; [ -n "$cache_home" ] || cache_home="${USERPROFILE:-}"; if [ -n "$cache_home" ]; then cache_file="$cache_home/.codex/cerberus/sessions/$CODEX_THREAD_ID/plugin-root"; if [ -r "$cache_file" ]; then IFS= read -r root < "$cache_file" || true; fi; fi; fi; if [ -z "$root" ] && [ "$host" != codex ]; then root="${CLAUDE_PLUGIN_ROOT}"; [ -n "$root" ] || root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" != codex ]; then skill_dir="${CLAUDE_SKILL_DIR}"; if [ -n "$skill_dir" ]; then root="$(cd "$skill_dir/../.." && pwd)"; fi; fi; [ -n "$root" ] || { echo "cerberus: plugin root not set; set CERBERUS_ROOT and retry" >&2; exit 127; }; bin="$root/bin/cerberus"; export CERBERUS_ROOT="$root"; claude_session="${CLAUDE_SESSION_ID}"; if [ "$host" = claude ]; then export CERBERUS_HOST=claude; elif [ "$host" = codex ]; then export CERBERUS_HOST=codex; fi; if [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then export CERBERUS_HOST=codex CERBERUS_SESSION_ID="$CODEX_THREAD_ID"; elif [ "$host" = claude ] && [ -n "$claude_session" ]; then export CERBERUS_HOST=claude CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$claude_session}"; fi; command -v make >/dev/null 2>&1 || { echo "cerberus: make not found on PATH; install make and retry." >&2; exit 127; }; if ! make -q -C "$root" build >/dev/null 2>&1; then command -v go >/dev/null 2>&1 || { echo "cerberus: Go >= 1.22 not found on PATH; install Go and retry." >&2; exit 127; }; echo "cerberus: building... (this happens once after clone or upgrade)" >&2; start=$(date +%s); make -C "$root" build >&2 || exit $?; end=$(date +%s); echo "cerberus: build complete in $((end-start))s" >&2; fi; "$bin" spawn-plan-review --agents codex,gemini path/to/plan.md

# User: /review-plan --max-rounds 3 path/to/plan.md
set +u; if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${PLUGIN_ROOT:-}" ]; then host=codex; elif [ -n "${CLAUDE_SESSION_ID}" ] || [ -n "${CLAUDE_PLUGIN_ROOT}" ] || [ -n "${CLAUDE_SKILL_DIR}" ]; then host=claude; else host="${CERBERUS_HOST:-}"; if [ "$host" = claude-code ]; then host=claude; fi; fi; root="${CERBERUS_ROOT:-}"; if [ -z "$root" ] && [ "$host" = codex ]; then root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then cache_home="${HOME:-}"; [ -n "$cache_home" ] || cache_home="${USERPROFILE:-}"; if [ -n "$cache_home" ]; then cache_file="$cache_home/.codex/cerberus/sessions/$CODEX_THREAD_ID/plugin-root"; if [ -r "$cache_file" ]; then IFS= read -r root < "$cache_file" || true; fi; fi; fi; if [ -z "$root" ] && [ "$host" != codex ]; then root="${CLAUDE_PLUGIN_ROOT}"; [ -n "$root" ] || root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" != codex ]; then skill_dir="${CLAUDE_SKILL_DIR}"; if [ -n "$skill_dir" ]; then root="$(cd "$skill_dir/../.." && pwd)"; fi; fi; [ -n "$root" ] || { echo "cerberus: plugin root not set; set CERBERUS_ROOT and retry" >&2; exit 127; }; bin="$root/bin/cerberus"; export CERBERUS_ROOT="$root"; claude_session="${CLAUDE_SESSION_ID}"; if [ "$host" = claude ]; then export CERBERUS_HOST=claude; elif [ "$host" = codex ]; then export CERBERUS_HOST=codex; fi; if [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then export CERBERUS_HOST=codex CERBERUS_SESSION_ID="$CODEX_THREAD_ID"; elif [ "$host" = claude ] && [ -n "$claude_session" ]; then export CERBERUS_HOST=claude CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$claude_session}"; fi; command -v make >/dev/null 2>&1 || { echo "cerberus: make not found on PATH; install make and retry." >&2; exit 127; }; if ! make -q -C "$root" build >/dev/null 2>&1; then command -v go >/dev/null 2>&1 || { echo "cerberus: Go >= 1.22 not found on PATH; install Go and retry." >&2; exit 127; }; echo "cerberus: building... (this happens once after clone or upgrade)" >&2; start=$(date +%s); make -C "$root" build >&2 || exit $?; end=$(date +%s); echo "cerberus: build complete in $((end-start))s" >&2; fi; "$bin" spawn-plan-review --max-rounds 3 path/to/plan.md
set +u; if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${PLUGIN_ROOT:-}" ]; then host=codex; elif [ -n "${CLAUDE_SESSION_ID}" ] || [ -n "${CLAUDE_PLUGIN_ROOT}" ] || [ -n "${CLAUDE_SKILL_DIR}" ]; then host=claude; else host="${CERBERUS_HOST:-}"; if [ "$host" = claude-code ]; then host=claude; fi; fi; root="${CERBERUS_ROOT:-}"; if [ -z "$root" ] && [ "$host" = codex ]; then root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then cache_home="${HOME:-}"; [ -n "$cache_home" ] || cache_home="${USERPROFILE:-}"; if [ -n "$cache_home" ]; then cache_file="$cache_home/.codex/cerberus/sessions/$CODEX_THREAD_ID/plugin-root"; if [ -r "$cache_file" ]; then IFS= read -r root < "$cache_file" || true; fi; fi; fi; if [ -z "$root" ] && [ "$host" != codex ]; then root="${CLAUDE_PLUGIN_ROOT}"; [ -n "$root" ] || root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" != codex ]; then skill_dir="${CLAUDE_SKILL_DIR}"; if [ -n "$skill_dir" ]; then root="$(cd "$skill_dir/../.." && pwd)"; fi; fi; [ -n "$root" ] || { echo "cerberus: plugin root not set; set CERBERUS_ROOT and retry" >&2; exit 127; }; bin="$root/bin/cerberus"; export CERBERUS_ROOT="$root"; claude_session="${CLAUDE_SESSION_ID}"; if [ "$host" = claude ]; then export CERBERUS_HOST=claude; elif [ "$host" = codex ]; then export CERBERUS_HOST=codex; fi; if [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then export CERBERUS_HOST=codex CERBERUS_SESSION_ID="$CODEX_THREAD_ID"; elif [ "$host" = claude ] && [ -n "$claude_session" ]; then export CERBERUS_HOST=claude CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$claude_session}"; fi; command -v make >/dev/null 2>&1 || { echo "cerberus: make not found on PATH; install make and retry." >&2; exit 127; }; if ! make -q -C "$root" build >/dev/null 2>&1; then command -v go >/dev/null 2>&1 || { echo "cerberus: Go >= 1.22 not found on PATH; install Go and retry." >&2; exit 127; }; echo "cerberus: building... (this happens once after clone or upgrade)" >&2; start=$(date +%s); make -C "$root" build >&2 || exit $?; end=$(date +%s); echo "cerberus: build complete in $((end-start))s" >&2; fi; "$bin" spawn-plan-review --max-rounds 0 path/to/plan.md  # Disable auto-respawn

# User: /review-plan --consensus any path/to/plan.md
set +u; if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${PLUGIN_ROOT:-}" ]; then host=codex; elif [ -n "${CLAUDE_SESSION_ID}" ] || [ -n "${CLAUDE_PLUGIN_ROOT}" ] || [ -n "${CLAUDE_SKILL_DIR}" ]; then host=claude; else host="${CERBERUS_HOST:-}"; if [ "$host" = claude-code ]; then host=claude; fi; fi; root="${CERBERUS_ROOT:-}"; if [ -z "$root" ] && [ "$host" = codex ]; then root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then cache_home="${HOME:-}"; [ -n "$cache_home" ] || cache_home="${USERPROFILE:-}"; if [ -n "$cache_home" ]; then cache_file="$cache_home/.codex/cerberus/sessions/$CODEX_THREAD_ID/plugin-root"; if [ -r "$cache_file" ]; then IFS= read -r root < "$cache_file" || true; fi; fi; fi; if [ -z "$root" ] && [ "$host" != codex ]; then root="${CLAUDE_PLUGIN_ROOT}"; [ -n "$root" ] || root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" != codex ]; then skill_dir="${CLAUDE_SKILL_DIR}"; if [ -n "$skill_dir" ]; then root="$(cd "$skill_dir/../.." && pwd)"; fi; fi; [ -n "$root" ] || { echo "cerberus: plugin root not set; set CERBERUS_ROOT and retry" >&2; exit 127; }; bin="$root/bin/cerberus"; export CERBERUS_ROOT="$root"; claude_session="${CLAUDE_SESSION_ID}"; if [ "$host" = claude ]; then export CERBERUS_HOST=claude; elif [ "$host" = codex ]; then export CERBERUS_HOST=codex; fi; if [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then export CERBERUS_HOST=codex CERBERUS_SESSION_ID="$CODEX_THREAD_ID"; elif [ "$host" = claude ] && [ -n "$claude_session" ]; then export CERBERUS_HOST=claude CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$claude_session}"; fi; command -v make >/dev/null 2>&1 || { echo "cerberus: make not found on PATH; install make and retry." >&2; exit 127; }; if ! make -q -C "$root" build >/dev/null 2>&1; then command -v go >/dev/null 2>&1 || { echo "cerberus: Go >= 1.22 not found on PATH; install Go and retry." >&2; exit 127; }; echo "cerberus: building... (this happens once after clone or upgrade)" >&2; start=$(date +%s); make -C "$root" build >&2 || exit $?; end=$(date +%s); echo "cerberus: build complete in $((end-start))s" >&2; fi; "$bin" spawn-plan-review --consensus any path/to/plan.md

# User: /review-plan plan.md focus on error handling
set +u; if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${PLUGIN_ROOT:-}" ]; then host=codex; elif [ -n "${CLAUDE_SESSION_ID}" ] || [ -n "${CLAUDE_PLUGIN_ROOT}" ] || [ -n "${CLAUDE_SKILL_DIR}" ]; then host=claude; else host="${CERBERUS_HOST:-}"; if [ "$host" = claude-code ]; then host=claude; fi; fi; root="${CERBERUS_ROOT:-}"; if [ -z "$root" ] && [ "$host" = codex ]; then root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then cache_home="${HOME:-}"; [ -n "$cache_home" ] || cache_home="${USERPROFILE:-}"; if [ -n "$cache_home" ]; then cache_file="$cache_home/.codex/cerberus/sessions/$CODEX_THREAD_ID/plugin-root"; if [ -r "$cache_file" ]; then IFS= read -r root < "$cache_file" || true; fi; fi; fi; if [ -z "$root" ] && [ "$host" != codex ]; then root="${CLAUDE_PLUGIN_ROOT}"; [ -n "$root" ] || root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" != codex ]; then skill_dir="${CLAUDE_SKILL_DIR}"; if [ -n "$skill_dir" ]; then root="$(cd "$skill_dir/../.." && pwd)"; fi; fi; [ -n "$root" ] || { echo "cerberus: plugin root not set; set CERBERUS_ROOT and retry" >&2; exit 127; }; bin="$root/bin/cerberus"; export CERBERUS_ROOT="$root"; claude_session="${CLAUDE_SESSION_ID}"; if [ "$host" = claude ]; then export CERBERUS_HOST=claude; elif [ "$host" = codex ]; then export CERBERUS_HOST=codex; fi; if [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then export CERBERUS_HOST=codex CERBERUS_SESSION_ID="$CODEX_THREAD_ID"; elif [ "$host" = claude ] && [ -n "$claude_session" ]; then export CERBERUS_HOST=claude CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$claude_session}"; fi; command -v make >/dev/null 2>&1 || { echo "cerberus: make not found on PATH; install make and retry." >&2; exit 127; }; if ! make -q -C "$root" build >/dev/null 2>&1; then command -v go >/dev/null 2>&1 || { echo "cerberus: Go >= 1.22 not found on PATH; install Go and retry." >&2; exit 127; }; echo "cerberus: building... (this happens once after clone or upgrade)" >&2; start=$(date +%s); make -C "$root" build >&2 || exit $?; end=$(date +%s); echo "cerberus: build complete in $((end-start))s" >&2; fi; "$bin" spawn-plan-review plan.md focus on error handling
```

If no path is provided, the most recent plan from `~/.claude/plans/` will be used.

## How It Works

1. External reviewers (Codex, Gemini, Claude) evaluate the plan for:
   - Completeness and correctness
   - Order of operations and dependencies
   - Edge cases and error handling
   - Breaking changes and testability

2. The Stop hook waits for reviewers and checks consensus:
   - If consensus passes (per `--consensus` mode): You may proceed (but check for remaining issues first)
   - If any reviewer finds blocking issues (FAIL verdict or P0/P1 findings): You must fix the plan and try again

3. Fix issues in the plan file based on reviewer feedback, then the review automatically re-runs.

## After Passing

When consensus passes, you MUST fix any remaining issues or suggestions noted in the feedback before proceeding.

## Review Criteria

Reviewers evaluate the plan for:

- **Template & Structure** - Does it follow the standard implementation plan template (context, scope, assumptions/constraints, prerequisites, high-level approach, technical design, risks, testing, open questions)?
- **Completeness** - Does it cover all necessary design decisions, including architecture, data model, interfaces, file impact, and monitoring?
- **Correctness** - Are the proposed design choices technically sound and grounded in the described codebase?
- **Prerequisites & Dependencies** - Are prerequisites called out explicitly (access, infra, flags)? Are external dependencies clear?
- **Edge Cases & Risk** - Are error paths, fallbacks, and failure modes addressed?
- **Testability & Verification** - Is there a clear testing strategy that maps to acceptance criteria?
- **Scope** - Is the plan appropriately scoped (MVP vs follow-ups, clear non-goals)?

When recording or applying review feedback, use durable references such as plan section names, file paths, and module names. Do not add file line numbers or `#L...` anchors; they become stale quickly.

Note: Plans should NOT contain detailed task breakdowns (Task 1, Task 2, etc.) — that is handled separately by `/create-tasks`.

## Iteration Loop

The iterative review continues until:
- Consensus is reached (per `--consensus` mode, default: majority)
- Maximum iterations (default 3, configurable via --max-rounds; set `0` to disable auto-respawn) are reached
- You manually resolve with `set +u; if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${PLUGIN_ROOT:-}" ]; then host=codex; elif [ -n "${CLAUDE_SESSION_ID}" ] || [ -n "${CLAUDE_PLUGIN_ROOT}" ] || [ -n "${CLAUDE_SKILL_DIR}" ]; then host=claude; else host="${CERBERUS_HOST:-}"; if [ "$host" = claude-code ]; then host=claude; fi; fi; root="${CERBERUS_ROOT:-}"; if [ -z "$root" ] && [ "$host" = codex ]; then root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then cache_home="${HOME:-}"; [ -n "$cache_home" ] || cache_home="${USERPROFILE:-}"; if [ -n "$cache_home" ]; then cache_file="$cache_home/.codex/cerberus/sessions/$CODEX_THREAD_ID/plugin-root"; if [ -r "$cache_file" ]; then IFS= read -r root < "$cache_file" || true; fi; fi; fi; if [ -z "$root" ] && [ "$host" != codex ]; then root="${CLAUDE_PLUGIN_ROOT}"; [ -n "$root" ] || root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" != codex ]; then skill_dir="${CLAUDE_SKILL_DIR}"; if [ -n "$skill_dir" ]; then root="$(cd "$skill_dir/../.." && pwd)"; fi; fi; [ -n "$root" ] || { echo "cerberus: plugin root not set; set CERBERUS_ROOT and retry" >&2; exit 127; }; bin="$root/bin/cerberus"; export CERBERUS_ROOT="$root"; claude_session="${CLAUDE_SESSION_ID}"; if [ "$host" = claude ]; then export CERBERUS_HOST=claude; elif [ "$host" = codex ]; then export CERBERUS_HOST=codex; fi; if [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then export CERBERUS_HOST=codex CERBERUS_SESSION_ID="$CODEX_THREAD_ID"; elif [ "$host" = claude ] && [ -n "$claude_session" ]; then export CERBERUS_HOST=claude CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$claude_session}"; fi; command -v make >/dev/null 2>&1 || { echo "cerberus: make not found on PATH; install make and retry." >&2; exit 127; }; if ! make -q -C "$root" build >/dev/null 2>&1; then command -v go >/dev/null 2>&1 || { echo "cerberus: Go >= 1.22 not found on PATH; install Go and retry." >&2; exit 127; }; echo "cerberus: building... (this happens once after clone or upgrade)" >&2; start=$(date +%s); make -C "$root" build >&2 || exit $?; end=$(date +%s); echo "cerberus: build complete in $((end-start))s" >&2; fi; "$bin" resolve`

Note: FAIL verdicts and P0/P1 findings always block regardless of consensus mode.
