---
name: verify-epic
disable-model-invocation: true
description: Verify epic acceptance criteria against the codebase with multi-model consensus
argument-hint: '[--debate] <epic-file-or-criteria> [--mode <fast|smart|max>] [--consensus <majority|all|any>] [--agents <list>] [--max-rounds <n>]'
---

## Host-Neutral Execution

Before running any Bash snippet in this skill, source the shared Cerberus skill environment helper. This keeps the same skill usable from Claude, Codex, Amp, or a generic shell by resolving `CERBERUS_ROOT`, `CERBERUS_HOST`, and the active run key when the host exposes one.

```bash
cerberus_root=""
cerberus_plugin_root='${CLAUDE_PLUGIN_ROOT}'
case "$cerberus_plugin_root" in
    '$'{CLAUDE_PLUGIN_ROOT}) cerberus_plugin_root="${CLAUDE_PLUGIN_ROOT:-}" ;;
esac
cerberus_skill_dir='${CLAUDE_SKILL_DIR}'
case "$cerberus_skill_dir" in
    '$'{CLAUDE_SKILL_DIR}) cerberus_skill_dir="${CLAUDE_SKILL_DIR:-}" ;;
esac

cerberus_candidates=("${CERBERUS_ROOT:-}" "$cerberus_plugin_root")
if [ -n "$cerberus_skill_dir" ]; then
    cerberus_candidates+=("$(cd -P "$cerberus_skill_dir/../.." 2>/dev/null && pwd || true)")
fi
cerberus_git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$cerberus_git_root" ]; then
    cerberus_candidates+=("$cerberus_git_root")
fi
for cerberus_candidate in "${cerberus_candidates[@]}"; do
    if [ -n "$cerberus_candidate" ] && [ -r "$cerberus_candidate/bin/cerberus-skill-env" ]; then
        cerberus_root="$cerberus_candidate"
        break
    fi
done
if [ -z "$cerberus_root" ]; then
    echo "cerberus skill: cannot find Cerberus backend; set CERBERUS_ROOT to the checkout root" >&2
    exit 127
fi
# shellcheck source=/dev/null
. "$cerberus_root/bin/cerberus-skill-env"
```

Use `${CERBERUS_ROOT}` when invoking Cerberus binaries below.


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
${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/review-gate spawn-epic-verify "$EPIC_FILE" $ARGUMENTS
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
${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/review-gate spawn-epic-verify specs/auth-epic.md --mode fast

# User: /verify-epic specs/feature.md --agents codex,gemini
${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/review-gate spawn-epic-verify specs/feature.md --agents codex,gemini

# User: /verify-epic specs/refactor.md --consensus all
${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/review-gate spawn-epic-verify specs/refactor.md --consensus all
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
${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/review-gate resolve  # Resolve the current gate
```
