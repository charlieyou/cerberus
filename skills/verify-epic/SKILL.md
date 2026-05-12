---
name: verify-epic
disable-model-invocation: true
description: Verify epic acceptance criteria against the codebase with multi-model consensus
argument-hint: '[--debate] <epic-file-or-criteria> [--mode <fast|smart|max>] [--consensus <majority|all|any>] [--agents <list>] [--max-rounds <n>]'
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


# Epic Verification (Iterative)

Multi-model verification that checks whether the codebase satisfies acceptance criteria. External reviewers (Codex, Gemini, Claude) explore the repository using their tools to verify each criterion is implemented, and you fix the code until consensus passes.

## Usage

```
/cerberus:verify-epic docs/specs/my-epic.md                    # Verify epic file
/cerberus:verify-epic "- Users can login\n- Sessions expire"   # Verify raw criteria
/cerberus:verify-epic docs/specs/my-epic.md --agents codex,gemini  # Only run selected reviewers
/cerberus:verify-epic docs/specs/my-epic.md --max-rounds 3     # Limit to 3 verification iterations
/cerberus:verify-epic docs/specs/my-epic.md --mode max         # Use max intelligence mode
/cerberus:verify-epic docs/specs/my-epic.md --consensus all    # Require unanimous approval
```

## Input Requirements

You can provide either:
- **A file path** to an epic/spec file containing acceptance criteria
- **Raw criteria text** directly (reviewers will verify these criteria against the codebase)

Reviewers will use their tools to read any referenced spec/plan files.

## How It Works

1. **Determine Input**: Detect if input is a file path or raw criteria
2. **Spawn Verification**: Run the spawn command to start verification
3. **Reviewers Explore**: Each reviewer (Codex, Gemini, Claude) uses a subagent architecture:
   - **Phase 1**: Read epic/spec to enumerate all acceptance criteria
   - **Phase 2**: Spawn verification subagents to explore codebase in parallel
   - **Phase 3**: Collect subagent results and produce final verdict
4. **Fix Issues**: If reviewers find unmet criteria, fix the code
5. **Re-verify**: Verification automatically re-runs after changes (unless `--max-rounds 0`)
6. **Pass**: When consensus is reached, the gate resolves

## Run the Verification

Use the Bash tool to spawn the epic verification:

```bash
set +u; if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${PLUGIN_ROOT:-}" ]; then host=codex; elif [ -n "${CLAUDE_SESSION_ID}" ] || [ -n "${CLAUDE_PLUGIN_ROOT}" ] || [ -n "${CLAUDE_SKILL_DIR}" ]; then host=claude; else host="${CERBERUS_HOST:-}"; if [ "$host" = claude-code ]; then host=claude; fi; fi; root="${CERBERUS_ROOT:-}"; if [ -z "$root" ] && [ "$host" = codex ]; then root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then cache_home="${HOME:-}"; [ -n "$cache_home" ] || cache_home="${USERPROFILE:-}"; if [ -n "$cache_home" ]; then cache_file="$cache_home/.codex/cerberus/sessions/$CODEX_THREAD_ID/plugin-root"; if [ -r "$cache_file" ]; then IFS= read -r root < "$cache_file" || true; fi; fi; fi; if [ -z "$root" ] && [ "$host" != codex ]; then root="${CLAUDE_PLUGIN_ROOT}"; [ -n "$root" ] || root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" != codex ]; then skill_dir="${CLAUDE_SKILL_DIR}"; if [ -n "$skill_dir" ]; then root="$(cd "$skill_dir/../.." && pwd)"; fi; fi; [ -n "$root" ] || { echo "cerberus: plugin root not set; set CERBERUS_ROOT and retry" >&2; exit 127; }; bin="$root/bin/cerberus"; export CERBERUS_ROOT="$root"; claude_session="${CLAUDE_SESSION_ID}"; if [ "$host" = claude ]; then export CERBERUS_HOST=claude; elif [ "$host" = codex ]; then export CERBERUS_HOST=codex; fi; if [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then export CERBERUS_HOST=codex CERBERUS_SESSION_ID="$CODEX_THREAD_ID"; elif [ "$host" = claude ] && [ -n "$claude_session" ]; then export CERBERUS_HOST=claude CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$claude_session}"; fi; command -v make >/dev/null 2>&1 || { echo "cerberus: make not found on PATH; install make and retry." >&2; exit 127; }; if ! make -q -C "$root" build >/dev/null 2>&1; then command -v go >/dev/null 2>&1 || { echo "cerberus: Go >= 1.22 not found on PATH; install Go and retry." >&2; exit 127; }; echo "cerberus: building... (this happens once after clone or upgrade)" >&2; start=$(date +%s); make -C "$root" build >&2 || exit $?; end=$(date +%s); echo "cerberus: build complete in $((end-start))s" >&2; fi; "$bin" spawn-epic-verify "$EPIC_FILE" $ARGUMENTS
```

Pass all remaining `$ARGUMENTS` directly. The CLI accepts:
- `--agents <list>` - comma-separated: codex, gemini, claude
- `--max-rounds <n>` - iteration limit (default: 3, use 0 to disable)
- `--mode <fast|smart|max>` - intelligence level
- `--consensus <majority|all|any>` - approval threshold

**Consensus modes:**
- `majority` (default): At least 2 reviewers PASS, or all valid reviewers PASS
- `all`: All valid reviewers must PASS (errored reviewers are skipped)
- `any`: At least one reviewer PASS

Note: FAIL verdicts and P0/P1 findings always block regardless of consensus mode.

**IMPORTANT: After running the spawn command, STOP IMMEDIATELY.** Do not poll, wait, or run any further commands. The Stop hook will automatically check for reviewer consensus when you stop.

Examples:
```bash
# User: /verify-epic specs/auth-epic.md --mode fast
set +u; if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${PLUGIN_ROOT:-}" ]; then host=codex; elif [ -n "${CLAUDE_SESSION_ID}" ] || [ -n "${CLAUDE_PLUGIN_ROOT}" ] || [ -n "${CLAUDE_SKILL_DIR}" ]; then host=claude; else host="${CERBERUS_HOST:-}"; if [ "$host" = claude-code ]; then host=claude; fi; fi; root="${CERBERUS_ROOT:-}"; if [ -z "$root" ] && [ "$host" = codex ]; then root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then cache_home="${HOME:-}"; [ -n "$cache_home" ] || cache_home="${USERPROFILE:-}"; if [ -n "$cache_home" ]; then cache_file="$cache_home/.codex/cerberus/sessions/$CODEX_THREAD_ID/plugin-root"; if [ -r "$cache_file" ]; then IFS= read -r root < "$cache_file" || true; fi; fi; fi; if [ -z "$root" ] && [ "$host" != codex ]; then root="${CLAUDE_PLUGIN_ROOT}"; [ -n "$root" ] || root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" != codex ]; then skill_dir="${CLAUDE_SKILL_DIR}"; if [ -n "$skill_dir" ]; then root="$(cd "$skill_dir/../.." && pwd)"; fi; fi; [ -n "$root" ] || { echo "cerberus: plugin root not set; set CERBERUS_ROOT and retry" >&2; exit 127; }; bin="$root/bin/cerberus"; export CERBERUS_ROOT="$root"; claude_session="${CLAUDE_SESSION_ID}"; if [ "$host" = claude ]; then export CERBERUS_HOST=claude; elif [ "$host" = codex ]; then export CERBERUS_HOST=codex; fi; if [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then export CERBERUS_HOST=codex CERBERUS_SESSION_ID="$CODEX_THREAD_ID"; elif [ "$host" = claude ] && [ -n "$claude_session" ]; then export CERBERUS_HOST=claude CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$claude_session}"; fi; command -v make >/dev/null 2>&1 || { echo "cerberus: make not found on PATH; install make and retry." >&2; exit 127; }; if ! make -q -C "$root" build >/dev/null 2>&1; then command -v go >/dev/null 2>&1 || { echo "cerberus: Go >= 1.22 not found on PATH; install Go and retry." >&2; exit 127; }; echo "cerberus: building... (this happens once after clone or upgrade)" >&2; start=$(date +%s); make -C "$root" build >&2 || exit $?; end=$(date +%s); echo "cerberus: build complete in $((end-start))s" >&2; fi; "$bin" spawn-epic-verify specs/auth-epic.md --mode fast

# User: /verify-epic specs/feature.md --agents codex,gemini
set +u; if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${PLUGIN_ROOT:-}" ]; then host=codex; elif [ -n "${CLAUDE_SESSION_ID}" ] || [ -n "${CLAUDE_PLUGIN_ROOT}" ] || [ -n "${CLAUDE_SKILL_DIR}" ]; then host=claude; else host="${CERBERUS_HOST:-}"; if [ "$host" = claude-code ]; then host=claude; fi; fi; root="${CERBERUS_ROOT:-}"; if [ -z "$root" ] && [ "$host" = codex ]; then root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then cache_home="${HOME:-}"; [ -n "$cache_home" ] || cache_home="${USERPROFILE:-}"; if [ -n "$cache_home" ]; then cache_file="$cache_home/.codex/cerberus/sessions/$CODEX_THREAD_ID/plugin-root"; if [ -r "$cache_file" ]; then IFS= read -r root < "$cache_file" || true; fi; fi; fi; if [ -z "$root" ] && [ "$host" != codex ]; then root="${CLAUDE_PLUGIN_ROOT}"; [ -n "$root" ] || root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" != codex ]; then skill_dir="${CLAUDE_SKILL_DIR}"; if [ -n "$skill_dir" ]; then root="$(cd "$skill_dir/../.." && pwd)"; fi; fi; [ -n "$root" ] || { echo "cerberus: plugin root not set; set CERBERUS_ROOT and retry" >&2; exit 127; }; bin="$root/bin/cerberus"; export CERBERUS_ROOT="$root"; claude_session="${CLAUDE_SESSION_ID}"; if [ "$host" = claude ]; then export CERBERUS_HOST=claude; elif [ "$host" = codex ]; then export CERBERUS_HOST=codex; fi; if [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then export CERBERUS_HOST=codex CERBERUS_SESSION_ID="$CODEX_THREAD_ID"; elif [ "$host" = claude ] && [ -n "$claude_session" ]; then export CERBERUS_HOST=claude CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$claude_session}"; fi; command -v make >/dev/null 2>&1 || { echo "cerberus: make not found on PATH; install make and retry." >&2; exit 127; }; if ! make -q -C "$root" build >/dev/null 2>&1; then command -v go >/dev/null 2>&1 || { echo "cerberus: Go >= 1.22 not found on PATH; install Go and retry." >&2; exit 127; }; echo "cerberus: building... (this happens once after clone or upgrade)" >&2; start=$(date +%s); make -C "$root" build >&2 || exit $?; end=$(date +%s); echo "cerberus: build complete in $((end-start))s" >&2; fi; "$bin" spawn-epic-verify specs/feature.md --agents codex,gemini

# User: /verify-epic specs/refactor.md --consensus all
set +u; if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${PLUGIN_ROOT:-}" ]; then host=codex; elif [ -n "${CLAUDE_SESSION_ID}" ] || [ -n "${CLAUDE_PLUGIN_ROOT}" ] || [ -n "${CLAUDE_SKILL_DIR}" ]; then host=claude; else host="${CERBERUS_HOST:-}"; if [ "$host" = claude-code ]; then host=claude; fi; fi; root="${CERBERUS_ROOT:-}"; if [ -z "$root" ] && [ "$host" = codex ]; then root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then cache_home="${HOME:-}"; [ -n "$cache_home" ] || cache_home="${USERPROFILE:-}"; if [ -n "$cache_home" ]; then cache_file="$cache_home/.codex/cerberus/sessions/$CODEX_THREAD_ID/plugin-root"; if [ -r "$cache_file" ]; then IFS= read -r root < "$cache_file" || true; fi; fi; fi; if [ -z "$root" ] && [ "$host" != codex ]; then root="${CLAUDE_PLUGIN_ROOT}"; [ -n "$root" ] || root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" != codex ]; then skill_dir="${CLAUDE_SKILL_DIR}"; if [ -n "$skill_dir" ]; then root="$(cd "$skill_dir/../.." && pwd)"; fi; fi; [ -n "$root" ] || { echo "cerberus: plugin root not set; set CERBERUS_ROOT and retry" >&2; exit 127; }; bin="$root/bin/cerberus"; export CERBERUS_ROOT="$root"; claude_session="${CLAUDE_SESSION_ID}"; if [ "$host" = claude ]; then export CERBERUS_HOST=claude; elif [ "$host" = codex ]; then export CERBERUS_HOST=codex; fi; if [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then export CERBERUS_HOST=codex CERBERUS_SESSION_ID="$CODEX_THREAD_ID"; elif [ "$host" = claude ] && [ -n "$claude_session" ]; then export CERBERUS_HOST=claude CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$claude_session}"; fi; command -v make >/dev/null 2>&1 || { echo "cerberus: make not found on PATH; install make and retry." >&2; exit 127; }; if ! make -q -C "$root" build >/dev/null 2>&1; then command -v go >/dev/null 2>&1 || { echo "cerberus: Go >= 1.22 not found on PATH; install Go and retry." >&2; exit 127; }; echo "cerberus: building... (this happens once after clone or upgrade)" >&2; start=$(date +%s); make -C "$root" build >&2 || exit $?; end=$(date +%s); echo "cerberus: build complete in $((end-start))s" >&2; fi; "$bin" spawn-epic-verify specs/refactor.md --consensus all
```

## Verification Architecture

Each reviewer uses a **subagent architecture** for thorough codebase exploration:

```
┌─────────────────────────────────────────────────────────────┐
│                    COORDINATOR (Reviewer)                    │
│                                                              │
│  Phase 1: Read epic/spec, enumerate ALL acceptance criteria  │
│  Phase 2: Spawn verification subagents (parallel when safe)  │
│  Phase 3: Collect results, produce final JSON verdict        │
└─────────────────────────────────────────────────────────────┘
                              │
          ┌───────────────────┼───────────────────┐
          ▼                   ▼                   ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│ Verify Subagent │ │ Verify Subagent │ │ Verify Subagent │
│ (AC-1, AC-2)    │ │ (AC-3, AC-4)    │ │ (AC-5, AC-6)    │
│                 │ │                 │ │                 │
│ Uses: grep,     │ │ Uses: grep,     │ │ Uses: grep,     │
│ glob, Read,     │ │ glob, Read,     │ │ glob, Read,     │
│ finder          │ │ finder          │ │ finder          │
└─────────────────┘ └─────────────────┘ └─────────────────┘
```

Each subagent verifies its assigned criteria by:

1. **Searching for implementations** - Use grep/glob to find relevant code
2. **Tracing entrypoints** - Find where the feature is invoked
3. **Following code paths** - Verify wiring from entrypoint to implementation
4. **Checking correctness** - Does the implementation match the specification?
5. **Gathering evidence** - Cite specific file:line references

Non-code criteria (tests, linting, CI, docs) are explicitly out of scope unless stated in the epic.

## Revision Cycle

When reviewers find unmet criteria:

1. The stop hook presents unmet criteria from each reviewer
2. Fix the code to satisfy the criteria
3. Verification automatically re-runs (configurable via --max-rounds)

## Completion

- **Consensus passes**: Auto-resolves and allows stop
- **Max iterations reached**: Falls back to manual decision

## Manual Override

If needed after max iterations:

```bash
set +u; if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${PLUGIN_ROOT:-}" ]; then host=codex; elif [ -n "${CLAUDE_SESSION_ID}" ] || [ -n "${CLAUDE_PLUGIN_ROOT}" ] || [ -n "${CLAUDE_SKILL_DIR}" ]; then host=claude; else host="${CERBERUS_HOST:-}"; if [ "$host" = claude-code ]; then host=claude; fi; fi; root="${CERBERUS_ROOT:-}"; if [ -z "$root" ] && [ "$host" = codex ]; then root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then cache_home="${HOME:-}"; [ -n "$cache_home" ] || cache_home="${USERPROFILE:-}"; if [ -n "$cache_home" ]; then cache_file="$cache_home/.codex/cerberus/sessions/$CODEX_THREAD_ID/plugin-root"; if [ -r "$cache_file" ]; then IFS= read -r root < "$cache_file" || true; fi; fi; fi; if [ -z "$root" ] && [ "$host" != codex ]; then root="${CLAUDE_PLUGIN_ROOT}"; [ -n "$root" ] || root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" != codex ]; then skill_dir="${CLAUDE_SKILL_DIR}"; if [ -n "$skill_dir" ]; then root="$(cd "$skill_dir/../.." && pwd)"; fi; fi; [ -n "$root" ] || { echo "cerberus: plugin root not set; set CERBERUS_ROOT and retry" >&2; exit 127; }; bin="$root/bin/cerberus"; export CERBERUS_ROOT="$root"; claude_session="${CLAUDE_SESSION_ID}"; if [ "$host" = claude ]; then export CERBERUS_HOST=claude; elif [ "$host" = codex ]; then export CERBERUS_HOST=codex; fi; if [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then export CERBERUS_HOST=codex CERBERUS_SESSION_ID="$CODEX_THREAD_ID"; elif [ "$host" = claude ] && [ -n "$claude_session" ]; then export CERBERUS_HOST=claude CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$claude_session}"; fi; command -v make >/dev/null 2>&1 || { echo "cerberus: make not found on PATH; install make and retry." >&2; exit 127; }; if ! make -q -C "$root" build >/dev/null 2>&1; then command -v go >/dev/null 2>&1 || { echo "cerberus: Go >= 1.22 not found on PATH; install Go and retry." >&2; exit 127; }; echo "cerberus: building... (this happens once after clone or upgrade)" >&2; start=$(date +%s); make -C "$root" build >&2 || exit $?; end=$(date +%s); echo "cerberus: build complete in $((end-start))s" >&2; fi; "$bin" resolve  # Resolve the current gate
```
