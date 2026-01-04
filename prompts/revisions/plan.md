Please revise **${PLAN_PATH}** to address the following issues:

${ISSUES}

**IMPORTANT:**
- Edit ONLY the plan file at `${PLAN_PATH}`
- Do NOT edit `latest.md` or any artifact/snapshot files
- The artifact files are read-only representations

While revising, ensure the plan follows the standard template structure:

- Context & Goals
- Scope & Non-Goals
- Assumptions & Constraints
- Prerequisites
- High-Level Approach
- Detailed Tasks (with explicit dependencies, concrete changes, and per-task verification)
- Risks, Edge Cases & Breaking Changes
- Testing & Validation (including mapping to risky areas)
- Open Questions (if anything remains unclear)

If the current plan is unstructured, first refactor it into this template, then apply the requested fixes.

## Communicating with Reviewers

**When to use author-context:**
- Reviewers flagged a **false positive** (decision is intentional or already documented)
- A finding was **addressed this iteration** and you want to prevent re-flagging
- There are **scope/constraint decisions** already discussed with the user
- You have **questions for reviewers** ("should we include X given time constraints?")

**Do NOT use author-context instead of fixing** clear, correct issues you can resolve in the plan.

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate author-context 'Resolved: [what was fixed]. False Positives: [why X is intentional]. Questions: [any open items].'
```

Keep it to a short summary (1-2 paragraphs max). Update each iteration to reflect current state; do not keep outdated notes. Once all findings are resolved, clear with `author-context --clear`.

## Self-Review Before Stopping

After making your revisions:
1. Re-read the updated plan sections
2. Verify the fixes address the original issues
3. Check for consistency across sections (dependencies, task ordering)
4. Set author-context if there are false positives or clarifications for reviewers
5. Only then finalize and STOP

**After updating and self-reviewing, STOP immediately.** The stop hook will spawn the next review round.
