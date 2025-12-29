Please revise the **code** to address the following issues:

${ISSUES}

## Fixing Strategy

Use the Task tool to spawn parallel sub-agents to fix each issue concurrently. For each finding listed above, launch a separate sub-agent with subagent_type="general-purpose" and a clear description of the specific issue to fix. This allows multiple fixes to happen in parallel for faster iteration.

Example (spawn one agent per issue, all in parallel):
```
Task(subagent_type="general-purpose", description="Fix [P1] issue title", prompt="Fix this issue: [full issue details]. Edit the relevant files to address the problem.")
```

## Self-Review Before Stopping

After all sub-agents complete their fixes:
1. Review the changes made by each sub-agent
2. Verify the fixes address the original issues
3. Check for any obvious regressions or new issues introduced
4. Only then commit and STOP

**Important:** Create a NEW commit with your fixes. Do NOT use `git commit --amend` as this changes the commit SHA and breaks the review tracking.

**After fixing and self-reviewing, STOP immediately.** The stop hook will automatically re-run the external review.
