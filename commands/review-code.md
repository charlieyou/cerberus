---
description: Iterative code review with external reviewers
argument-hint: [--uncommitted | --base <branch> | --commit <sha> | <range>]
---

# Code Review (Iterative)

Multi-model code review that automatically iterates until all reviewers pass. External reviewers (Codex, Gemini) evaluate the code diff directly, and you fix the code until unanimous pass.

## Usage

```
/cerberus:review-code                    # Review uncommitted changes (default)
/cerberus:review-code --uncommitted      # Review uncommitted changes
/cerberus:review-code --base main        # Review changes from main to HEAD
/cerberus:review-code --commit abc123    # Review a specific commit
/cerberus:review-code main..feature      # Review a commit range
```

## How It Works

1. **Spawn Review**: Run the spawn command to start the review
2. **Reviewers Evaluate**: Codex and Gemini analyze the diff in parallel
3. **Fix Issues**: If reviewers find issues, fix the code
4. **Re-review**: Reviews automatically re-run after you make changes
5. **Pass**: When all reviewers agree (PASS), the gate resolves

## Run the Review

Use the Bash tool to spawn the code review:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-code-review $ARGUMENTS
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
3. The review automatically re-runs (up to 5 iterations)

## Completion

- **All reviewers PASS**: Auto-resolves and allows stop
- **Max iterations reached**: Falls back to manual decision

## Manual Override

If needed after max iterations:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate resolve proceed  # Accept anyway
${CLAUDE_PLUGIN_ROOT}/bin/review-gate resolve abort    # Discard
```
