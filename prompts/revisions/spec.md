Please revise **${SPEC_PATH}** to address the following issues:

${ISSUES}

## Communicating with Reviewers

**When to use author-context:**
- Reviewers flagged a **false positive** (decision is intentional or out of scope)
- A finding was **addressed this iteration** and you want to prevent re-flagging
- There are **scope decisions** already confirmed with the user
- You have **questions for reviewers** ("is edge case X in scope given MVP constraints?")

**Do NOT use author-context instead of fixing** clear, correct issues you can resolve in the spec.

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate author-context 'Resolved: [what was fixed]. False Positives: [why X is intentional]. Questions: [any open items].'
```

Keep it to a short summary (1-2 paragraphs max). Update each iteration to reflect current state; do not keep outdated notes. Once all findings are resolved, clear with `author-context --clear`.

## Self-Review Before Stopping

After making your revisions:
1. Re-read the updated spec sections
2. Verify the fixes address the original issues
3. Check for consistency (goals align with acceptance criteria, edge cases are covered)
4. Set author-context if there are false positives or clarifications for reviewers
5. Only then finalize and STOP

**After updating and self-reviewing, STOP immediately.** The stop hook will spawn the next review round.
