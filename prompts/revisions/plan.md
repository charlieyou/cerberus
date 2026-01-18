Please revise **${PLAN_PATH}** to address the following issues:

${ISSUES}

## Fixing Strategy

Use the Task tool to spawn sub-agents to fix each issue. For each finding listed above, launch a separate sub-agent with a clear description of the specific issue to fix. **Run sub-agents sequentially** (one at a time) to avoid conflicts when multiple issues affect the same files.

Example:
```
Task(description="Fix [P1] issue in [section]", prompt="Revise the plan at ${PLAN_PATH} to fix this issue: [full details]. Make the smallest change necessary.")
```

**IMPORTANT:**
- Edit ONLY the plan file at `${PLAN_PATH}`
- Do NOT edit `latest.md` or any artifact/snapshot files
- Make the **smallest, most focused changes** necessary to resolve these issues
- Avoid introducing new architectures or abstractions not required by the findings

While revising, ensure the plan follows the standard template structure:

- Context & Goals
- Scope & Non-Goals
- Assumptions & Constraints
- Prerequisites
- High-Level Approach
- Technical Design (architecture, data model, interfaces, file impact summary)
- Risks, Edge Cases & Breaking Changes
- Testing & Validation (including mapping to risky areas)
- Open Questions (if anything remains unclear)

If the current plan is unstructured, first refactor it into this template **once**, then apply the requested fixes.
On later iterations, avoid large structural refactors; keep changes localized to the sections needed to address the current issues.

## Communicating with Reviewers

**When to use author-context:**
- Reviewers flagged a **false positive** (decision is intentional or already correct)
- A finding was **addressed this iteration** and you want to prevent re-flagging
- There are **non-obvious constraints** (scope, product decisions) justifying keeping something as-is
- You have **questions for reviewers** ("we considered A vs B; please confirm B is acceptable")

**Do NOT use author-context instead of fixing** clear, correct issues.

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

**After updating and self-reviewing, STOP immediately.** The stop hook will spawn the next review round.
