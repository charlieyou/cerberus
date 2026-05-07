---
name: review-code
disable-model-invocation: true
description: Iterative code review with external reviewers
argument-hint: '[--debate] [--uncommitted | --base <branch> | --commit <sha...> | <range>] [--mode <fast|smart|max>] [--consensus <majority|all|any>] [--agents <list>] [--max-rounds <n>] [--exclude <pathspec>...] ["<focus area>"]'
---

## Host-Neutral Execution

Before running any Bash snippet in this skill, source the shared Cerberus skill environment helper. This keeps the same skill usable from Claude, Codex, or a generic shell by resolving `CERBERUS_ROOT`, `CERBERUS_HOST`, and the active run key when the host exposes one.

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
    if [ -n "$cerberus_candidate" ] \
        && [[ "$cerberus_candidate" == /* ]] \
        && [ -r "$cerberus_candidate/bin/cerberus-skill-env" ] \
        && [ -x "$cerberus_candidate/bin/review-gate" ] \
        && [ -r "$cerberus_candidate/bin/review-gate-models.sh" ] \
        && [ -r "$cerberus_candidate/config/gemini-readonly-settings.json" ] \
        && [ -r "$cerberus_candidate/config/gemini-readonly-policy.toml" ]; then
        cerberus_root="$cerberus_candidate"
        break
    fi
done
if [ -z "$cerberus_root" ]; then
    echo "cerberus skill: cannot find Cerberus backend; set CERBERUS_ROOT to the checkout root" >&2
    exit 127
fi
export CERBERUS_ROOT="$cerberus_root"
# shellcheck source=/dev/null
. "$cerberus_root/bin/cerberus-skill-env" || exit $?
```

Use `${CERBERUS_ROOT}` when invoking Cerberus binaries below.


# Code Review (Iterative)

Multi-model code review that automatically iterates until consensus is reached. External reviewers (Codex, Gemini, Claude) evaluate the code diff directly, and you fix the code until the configured consensus threshold passes (default: majority).

## Usage

```
/cerberus:review-code                    # Review uncommitted changes (default)
/cerberus:review-code --uncommitted      # Review uncommitted changes
/cerberus:review-code --base main        # Review changes from main to HEAD
/cerberus:review-code --commit abc123    # Review a single commit (net diff)
/cerberus:review-code --commit abc123 def456  # Review multiple commits (net diff)
/cerberus:review-code main..feature      # Review a commit range
/cerberus:review-code --agents codex,gemini      # Only run selected reviewers
/cerberus:review-code --max-rounds 3     # Limit to 3 review iterations
/cerberus:review-code --max-rounds 0     # Disable auto-respawn (single round)
/cerberus:review-code --mode max         # Use max intelligence mode
/cerberus:review-code --consensus any    # Pass if at least one reviewer approves
/cerberus:review-code --consensus all    # Require unanimous approval
/cerberus:review-code --exclude ':(exclude,glob)dist/**'  # Ignore files using git pathspec syntax
/cerberus:review-code "focus on error handling"  # Focus review on specific area
```

Note: `--commit` generates a single net diff by applying the listed commits onto their merge-base, so non-contiguous commit lists are supported and intermediate commits are not shown individually.

## How It Works

1. **Spawn Review**: Run the spawn command to start the review
2. **Reviewers Evaluate**: Codex, Gemini, and Claude analyze the diff in parallel
3. **Fix Issues**: If reviewers find issues, fix the code
4. **Re-review**: Reviews automatically re-run after you make changes (unless `--max-rounds 0`)
5. **Pass**: When consensus is reached (per `--consensus` mode), the gate resolves

## Run the Review

Use the Bash tool to spawn the code review.

Pass `$ARGUMENTS` directly. The CLI accepts `--agents`, `--max-rounds`, `--mode`, `--consensus` (majority/all/any), `--exclude <pathspec>` (git pathspec exclude syntax like colon-bang or colon-exclude), diff selectors (`--uncommitted`, `--base`, `--commit <sha...>`, or a range containing `..`), plus an optional focus string (either `--focus "<text>"` or trailing free-text; use `--` to force focus when needed).

**Consensus modes:**
- `majority` (default): At least 2 reviewers PASS, or all valid reviewers PASS
- `all`: All valid reviewers must PASS (errored reviewers are skipped)
- `any`: At least one reviewer PASS

Note: FAIL verdicts and P0/P1 findings always block regardless of consensus mode.

```bash
${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/review-gate spawn-code-review $ARGUMENTS
```

**IMPORTANT: After running the spawn command, STOP IMMEDIATELY.** Do not poll, wait, or run any further commands. The Stop hook will automatically check for reviewer consensus when you stop.

Examples:
```bash
# User: /review-code --mode fast
${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/review-gate spawn-code-review --mode fast

# User: /review-code "focus on security"
${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/review-gate spawn-code-review --focus "focus on security"

# User: /review-code --base main "check error handling"
${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/review-gate spawn-code-review --base main --focus "check error handling"

# User: /review-code --exclude 'dist/**' --exclude '**/*.snap'
${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/review-gate spawn-code-review --exclude 'dist/**' --exclude '**/*.snap'

# User: /review-code main..feature focus on error handling
${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/review-gate spawn-code-review main..feature focus on error handling
```

## Review Criteria

Reviewers evaluate for:

1. **Correctness** - Does the code do what it intends? Logic errors?
2. **Security** - Injection, auth bypass, data exposure, secrets in code?
3. **Error Handling** - Failures handled gracefully? Edge cases covered?
4. **Performance** - Obvious inefficiencies?
5. **Breaking Changes** - API changes that could break consumers?

## Revision Cycle

When reviewers don't all agree:

1. The stop hook presents issues from each reviewer
2. Fix the code to address the feedback
3. The review automatically re-runs (default 3, configurable via --max-rounds; set `--max-rounds 0` to disable)

## Completion

- **Consensus passes**: Auto-resolves and allows stop
- **Max iterations reached**: Falls back to manual decision

## Manual Override

If needed after max iterations:

```bash
${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/review-gate resolve  # Resolve the current gate
```
