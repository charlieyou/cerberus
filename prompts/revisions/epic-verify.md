Please revise the **code** to satisfy the following unmet acceptance criteria:

${ISSUES}

## Fixing Strategy

Use the Task tool to spawn sub-agents to fix each issue. For each unmet criterion listed above, launch a separate sub-agent with a clear description of the specific criterion to implement. **Run sub-agents sequentially** (one at a time) to avoid conflicts when multiple issues affect the same files.

Example:
```
Task(description="Implement [criterion name]", prompt="Implement this acceptance criterion: [full details]. Edit the relevant files.")
```

## Communicating with Reviewers

**When to use author-context:**
- Reviewers flagged a **false positive** (decision is intentional or already correct)
- A finding was **addressed this iteration** and you want to prevent re-flagging
- There are **non-obvious constraints** (scope, product decisions) justifying keeping something as-is
- You have **questions for reviewers** ("we considered A vs B; please confirm B is acceptable")

**Do NOT use author-context instead of implementing** clear, correct issues.

When you believe a previously flagged issue is now resolved, briefly note this in author-context. This gives reviewers a checklist to verify.

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate author-context 'Resolved: [what was fixed]. False Positives: [why X is intentional]. Questions: [any open items].'
```

Keep it to 1-2 paragraphs max. Update each iteration to reflect current state; do not keep outdated notes. Once all findings are resolved, clear with `author-context --clear`.

## Self-Review Before Stopping

After all sub-agents complete their fixes:
1. Review the changes made by each sub-agent
2. Verify the fixes address the original issues
3. Check for any obvious regressions or new issues introduced
4. Set author-context if there are false positives or clarifications for reviewers
5. Only then finalize and STOP

**Commit Policy (${DIFF_ARGS}):**
${COMMIT_INSTRUCTIONS}

**After fixing and self-reviewing, STOP immediately.** The stop hook will automatically re-run epic verification.
