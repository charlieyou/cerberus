Please revise **${PLAN_PATH}** to address the following issues:

${ISSUES}

While revising, ensure the plan follows the standard template structure:

- Context & Goals
- Scope & Non-Goals
- Assumptions & Constraints
- Prerequisites
- High-Level Approach
- Detailed Tasks (with explicit dependencies, concrete changes, per-task verification, and per-task rollback)
- Risks, Edge Cases & Breaking Changes
- Testing & Validation (including mapping to risky areas)
- Plan-Level Rollback Strategy
- Open Questions (if anything remains unclear)

If the current plan is unstructured, first refactor it into this template, then apply the requested fixes.

## Self-Review Before Stopping

After making your revisions:
1. Re-read the updated plan sections
2. Verify the fixes address the original issues
3. Check for consistency across sections (dependencies, task ordering, rollback strategies)
4. Only then finalize and STOP

**After updating and self-reviewing, STOP immediately.** The stop hook will spawn the next review round.
