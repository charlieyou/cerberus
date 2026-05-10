---
name: review-code
disable-model-invocation: true
description: Iterative code review with external reviewers
argument-hint: '[--debate] [--uncommitted | --base <branch> | --commit <sha...> | <range>] [--mode <fast|smart|max>] [--consensus <majority|all|any>] [--agents <list>] [--max-rounds <n>] [--exclude <pathspec>...] ["<focus area>"]'
---

## Host-Neutral Execution

Before running any Bash snippet in this skill, run the shared Cerberus resolver below. It lazily builds and executes `bin/cerberus` from the configured plugin root.

```bash
# --- shared resolver (canonical body; identical across all callers) ---
root="${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}"
bin="$root/bin/cerberus"
[ -n "$root" ] || { echo "cerberus: plugin root not set" >&2; exit 127; }
export CERBERUS_ROOT="$root"
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

Pass `$ARGUMENTS` directly. The CLI accepts `--agents`, `--max-rounds`, `--mode`, `--consensus` (majority/all/any), `--exclude <pathspec>` (git pathspec exclude syntax like colon-bang or colon-exclude), diff selectors (`--uncommitted`, `--base`, `--commit <sha...>`, or a range containing `..`), plus optional trailing free-text as a focus string (use `--` to force focus when needed).

**Consensus modes:**
- `majority` (default): At least 2 reviewers PASS, or all valid reviewers PASS
- `all`: All valid reviewers must PASS (errored reviewers are skipped)
- `any`: At least one reviewer PASS

Note: FAIL verdicts and P0/P1 findings always block regardless of consensus mode.

```bash
if ! make -q -C "$CERBERUS_ROOT" build >/dev/null 2>&1; then make -C "$CERBERUS_ROOT" build >&2 || exit $?; fi
"$CERBERUS_ROOT/bin/cerberus" spawn-code-review $ARGUMENTS
```

**IMPORTANT: After running the spawn command, STOP IMMEDIATELY.** Do not poll, wait, or run any further commands. The Stop hook will automatically check for reviewer consensus when you stop.

Examples:
```bash
# User: /review-code --mode fast
if ! make -q -C "$CERBERUS_ROOT" build >/dev/null 2>&1; then make -C "$CERBERUS_ROOT" build >&2 || exit $?; fi
"$CERBERUS_ROOT/bin/cerberus" spawn-code-review --mode fast

# User: /review-code "focus on security"
if ! make -q -C "$CERBERUS_ROOT" build >/dev/null 2>&1; then make -C "$CERBERUS_ROOT" build >&2 || exit $?; fi
"$CERBERUS_ROOT/bin/cerberus" spawn-code-review focus on security

# User: /review-code --base main "check error handling"
if ! make -q -C "$CERBERUS_ROOT" build >/dev/null 2>&1; then make -C "$CERBERUS_ROOT" build >&2 || exit $?; fi
"$CERBERUS_ROOT/bin/cerberus" spawn-code-review --base main check error handling

# User: /review-code --exclude 'dist/**' --exclude '**/*.snap'
if ! make -q -C "$CERBERUS_ROOT" build >/dev/null 2>&1; then make -C "$CERBERUS_ROOT" build >&2 || exit $?; fi
"$CERBERUS_ROOT/bin/cerberus" spawn-code-review --exclude 'dist/**' --exclude '**/*.snap'

# User: /review-code main..feature focus on error handling
if ! make -q -C "$CERBERUS_ROOT" build >/dev/null 2>&1; then make -C "$CERBERUS_ROOT" build >&2 || exit $?; fi
"$CERBERUS_ROOT/bin/cerberus" spawn-code-review main..feature focus on error handling
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
${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/cerberus resolve  # Resolve the current gate
```
