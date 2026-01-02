---
description: Iterative code review with external reviewers
argument-hint: [--uncommitted | --base <branch> | --commit <sha...> | <range>] [--mode <fast|smart|max>] [--agents <list>] [--max-rounds <n>] [--exclude <pathspec>...] ["<focus area>"]
---

# Code Review (Iterative)

Multi-model code review that automatically iterates until all reviewers pass. External reviewers (Codex, Gemini, Claude) evaluate the code diff directly, and you fix the code until unanimous pass.

## Usage

```
/cerberus:review-code                    # Review uncommitted changes (default)
/cerberus:review-code --uncommitted      # Review uncommitted changes
/cerberus:review-code --base main        # Review changes from main to HEAD
/cerberus:review-code --commit abc123    # Review a single commit
/cerberus:review-code --commit abc123 def456  # Review multiple commits
/cerberus:review-code main..feature      # Review a commit range
/cerberus:review-code --agents codex,gemini      # Only run selected reviewers
/cerberus:review-code --max-rounds 3     # Limit to 3 review iterations
/cerberus:review-code --mode max         # Use max intelligence mode
/cerberus:review-code --exclude ':(exclude,glob)dist/**'  # Ignore files using git pathspec syntax
/cerberus:review-code "focus on error handling"  # Focus review on specific area
```

## How It Works

1. **Spawn Review**: Run the spawn command to start the review
2. **Reviewers Evaluate**: Codex, Gemini, and Claude analyze the diff in parallel
3. **Fix Issues**: If reviewers find issues, fix the code
4. **Re-review**: Reviews automatically re-run after you make changes
5. **Pass**: When all reviewers agree (PASS), the gate resolves

## Run the Review

Use the Bash tool to spawn the code review.

Pass `$ARGUMENTS` directly. The CLI accepts `--agents`, `--max-rounds`, `--mode`, `--exclude <pathspec>` (git pathspec exclude syntax like colon-bang or colon-exclude), diff selectors (`--uncommitted`, `--base`, `--commit <sha...>`, or a range containing `..`), plus an optional focus string (either `--focus "<text>"` or trailing free-text; use `--` to force focus when needed).

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-code-review $ARGUMENTS
```

**IMPORTANT: After running the spawn command, STOP IMMEDIATELY.** Do not poll, wait, or run any further commands. The Stop hook will automatically check for reviewer consensus when you stop.

Examples:
```bash
# User: /review-code --mode fast
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-code-review --mode fast

# User: /review-code "focus on security"
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-code-review --focus "focus on security"

# User: /review-code --base main "check error handling"
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-code-review --base main --focus "check error handling"

# User: /review-code --exclude 'dist/**' --exclude '**/*.snap'
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-code-review --exclude 'dist/**' --exclude '**/*.snap'

# User: /review-code main..feature focus on error handling
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-code-review main..feature focus on error handling
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
3. The review automatically re-runs (default 5, configurable via --max-rounds)

## Completion

- **All reviewers PASS**: Auto-resolves and allows stop
- **Max iterations reached**: Falls back to manual decision

## Manual Override

If needed after max iterations:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate resolve  # Resolve the current gate
```
