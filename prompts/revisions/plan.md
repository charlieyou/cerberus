Please revise **${PLAN_PATH}** to address the following issues:

${ISSUES}

Your goal is to make the **smallest, most focused changes** necessary to resolve these issues. Avoid introducing new architectures, flows, or abstractions that are not required by the findings, as they create new review surface and slow convergence.

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
- Technical Design (architecture, data model, interfaces, file impact summary)
- Risks, Edge Cases & Breaking Changes
- Testing & Validation (including mapping to risky areas)
- Open Questions (if anything remains unclear)

Note: You may include a high-level task list with dependencies and verification steps, but avoid overly granular implementation checklists.

If the current plan is unstructured, first refactor it into this template **once**, then apply the requested fixes.
On later iterations, avoid large structural refactors; keep changes localized to the sections needed to address the current issues.

## Communicating with Reviewers

**When to use author-context:**
- Reviewers flagged a **false positive** (decision is intentional or already documented)
- A finding was **addressed this iteration** and you want to prevent re-flagging
- There are **scope/constraint decisions** already discussed with the user
- You have **questions for reviewers** ("should we include X given time constraints?")

**Do NOT use author-context instead of fixing** clear, correct issues you can resolve in the plan.
When you believe a previously flagged issue is now resolved, briefly note this in author-context (e.g., "Resolved: [issue title] in [section]"). This gives reviewers a checklist to verify and helps prevent re-flagging or shifting to new P1s.

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate author-context 'Resolved: [what was fixed]. False Positives: [why X is intentional]. Questions: [any open items].'
```

Keep it to a short summary (1-2 paragraphs max). Update each iteration to reflect current state; do not keep outdated notes. Once all findings are resolved, clear with `author-context --clear`.

## Self-Review Before Stopping

After making your revisions:
1. Re-read the updated plan sections, focusing on the areas directly related to the listed issues.
2. Verify the fixes address the original issues **without introducing unrelated new behavior or abstractions**.
3. Check for consistency across sections (dependencies, task ordering), especially around previously flagged P0/P1 areas.
4. Set author-context to summarize which findings were resolved this iteration, and any remaining false positives or clarifications for reviewers.
5. Confirm that changes are as small and localized as possible in this iteration.
6. Only then finalize and STOP.

**After updating and self-reviewing, STOP immediately.** The stop hook will spawn the next review round.
