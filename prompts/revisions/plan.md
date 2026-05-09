Please revise **${PLAN_PATH}** to address the following issues:

${ISSUES}

## Fixing Strategy (MANDATORY)

**YOU MUST use the Task tool to spawn sub-agents to fix issues.** Delegate each fix to a sub-agent. This preserves your context for self-review and ensures focused, high-quality fixes.

**For each finding (or tightly related cluster in the same section):**
1. Call the Task tool with the specific issue details
2. Wait for the sub-agent to complete and review its changes
3. Run sub-agents **sequentially** (one at a time) to avoid edit conflicts

**Parent responsibilities:** After each sub-agent completes, verify its changes address the issue. If conflicts arise or changes are incomplete, spawn a follow-up Task. You orchestrate; sub-agents execute.

**If the plan is unstructured:** Spawn a first Task to refactor it into the standard template (see below), then proceed finding-by-finding. On later iterations, avoid large structural refactors; keep changes localized.

**Task sub-agent format:**
```
Task(
  description="Fix [P1] Missing rollback strategy in deployment section",
  prompt="Fix this plan review issue:

Plan file: ${PLAN_PATH}
Issue: [P1] Missing rollback strategy in deployment section
Section: Technical Design > Deployment
Problem: The plan describes the deployment steps but lacks rollback procedures if deployment fails.

Instructions:
1. Read the plan file to understand the current structure
2. Add rollback strategy to the deployment section
3. Make the smallest change necessary to address this issue
4. Report what you changed"
)
```

Now call the Task tool (not in a code block) using the structure above for each finding.

**Constraints for sub-agents:**
- Edit ONLY the plan file at `${PLAN_PATH}`
- Do NOT edit `latest.md` or any artifact/snapshot files
- Make the **smallest, most focused changes** necessary to resolve these issues
- Avoid introducing new architectures or abstractions not required by the findings

**Standard template structure:**
- Context & Goals
- Scope & Non-Goals
- Assumptions & Constraints
- Prerequisites
- High-Level Approach
- Technical Design (architecture, data model, interfaces, file impact summary)
- Risks, Edge Cases & Breaking Changes
- Testing & Validation (including mapping to risky areas)
- Open Questions (if anything remains unclear)

## Communicating with Reviewers

**When to use author-context:**
- Reviewers flagged a **false positive** (decision is intentional or already correct)
- A finding was **addressed this iteration** and you want to prevent re-flagging
- There are **non-obvious constraints** (scope, product decisions) justifying keeping something as-is
- You have **questions for reviewers** ("we considered A vs B; please confirm B is acceptable")

**Do NOT use author-context instead of fixing** clear, correct issues.

When you believe a previously flagged issue is now resolved, briefly note this in author-context. This gives reviewers a checklist to verify.

```bash
${CLAUDE_PLUGIN_ROOT}/bin/cerberus author-context 'Resolved: [what was fixed]. False Positives: [why X is intentional]. Questions: [any open items].'
```

Keep it to 1-2 paragraphs max. Update each iteration to reflect current state; do not keep outdated notes. Once all findings are resolved, clear with `author-context --clear`.

## Self-Review Before Stopping

After all sub-agents complete their fixes:
1. Review the changes made by each sub-agent
2. Verify the fixes address the original issues
3. Check for any obvious regressions or new issues introduced
4. Set author-context if there are false positives or clarifications for reviewers
5. Only then finalize and STOP

**After updating and self-reviewing, STOP immediately.** The stop hook will spawn the next review round.
