Please revise the **code** to satisfy the following unmet acceptance criteria:

${ISSUES}

## Fixing Strategy (MANDATORY)

**YOU MUST use the Task tool to spawn sub-agents to implement fixes.** Delegate each unmet criterion to a sub-agent. This preserves your context for self-review and ensures focused, high-quality implementations.

**For each unmet criterion (or tightly related cluster in the same area):**
1. Call the Task tool with the specific criterion details
2. Wait for the sub-agent to complete and review its changes
3. Run sub-agents **sequentially** (one at a time) to avoid edit conflicts

**Parent responsibilities:** After each sub-agent completes, verify its changes satisfy the criterion. If conflicts arise or changes are incomplete, spawn a follow-up Task. You orchestrate; sub-agents execute.

**Task sub-agent format:**
```
Task(
  description="Implement AC: User receives error message on invalid input",
  prompt="Implement this acceptance criterion:

Criterion: User receives error message on invalid input
Epic: User Registration Flow
Current behavior: Form silently fails on invalid email format
Expected: Display 'Please enter a valid email address' error message

Instructions:
1. Find the registration form validation code
2. Add email validation with appropriate error message
3. Verify the fix works for the expected scenarios
4. Report what you changed"
)
```

Now call the Task tool (not in a code block) using the structure above for each unmet criterion.

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
