---
description: Iterative spec review with external reviewers
argument-hint: [--agents <list>] [--max-rounds <n>] [--mode <fast|smart|max>] <path/to/spec.md>
---

# Spec Review (Iterative)

Spawn external reviewers (Codex, Gemini, Claude) to evaluate a feature specification. Fix issues until all reviewers pass.

## Usage

Run the spawn command with the spec path:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-spec-review $ARGUMENTS
```

**IMPORTANT: After running the spawn command, STOP IMMEDIATELY.** Do not poll, wait, or run any further commands. The Stop hook will automatically check for reviewer consensus when you stop.

Example to run a subset of reviewers:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-spec-review --agents codex,gemini path/to/spec.md
```

Limit the number of iterations:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-spec-review --max-rounds 3 path/to/spec.md
```

Choose an intelligence mode:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-spec-review --mode max path/to/spec.md
```

## How It Works

1. External reviewers (Codex, Gemini, Claude) evaluate the spec for:
   - Clarity of goals and scope definition
   - Technical feasibility and completeness
   - Edge case coverage and testability
   - Actionability for implementation

2. The Stop hook waits for reviewers and checks consensus:
   - If all reviewers PASS: You may proceed
   - If any reviewer finds issues: You must fix the spec and try again

3. Fix issues in the spec file based on reviewer feedback, then the review automatically re-runs.

## Tier System

Specs are tiered by complexity. **Reviewers must respect the stated tier** and only require sections appropriate for that tier.

| Tier | Use Case | Required Sections |
|------|----------|-------------------|
| **S** | Bug fix, tiny tweak | Problem, change summary, scope boundary, UX impact, acceptance bullets, validation method |
| **M** | Small feature | S + Goal, success criteria, non-goals, primary flow, key states, requirements with MUST + examples, basic instrumentation |
| **L** | Multi-flow project | M + Constraints, alternate flows, full GWT, edge cases per requirement, detailed instrumentation, launch checklist |

**Tier mismatch handling:**
- Do NOT fail a Tier S spec for missing M/L sections (goal, success criteria, etc.)
- If you believe the tier is dangerously low for the complexity, flag as **P1 recommendation to upgrade tier**, not a spec failure
- Record tier concerns in your review, but respect the author's tier choice

## Review Criteria by Tier

### Tier S (Bug fix / tiny tweak)
- [ ] Problem/context is clear (what's broken?)
- [ ] Change summary explains what's changing
- [ ] Scope boundary is explicit (only affects X, not Y)
- [ ] UX impact stated (yes/no + description if yes)
- [ ] 2-5 acceptance bullets are testable
- [ ] Validation method defined (how to confirm in prod)

### Tier M (add to S checks)
- [ ] Goal is a single actionable sentence
- [ ] Success criteria are measurable (metric + threshold + timeframe)
- [ ] Non-goals are explicit
- [ ] Primary flow is complete (numbered steps)
- [ ] Key states defined (empty, loading, success, error)
- [ ] 3-7 requirements with MUST statements + verification examples
- [ ] Basic instrumentation defined

### Tier L (add to M checks)
- [ ] Constraints addressed (compatibility, performance, security)
- [ ] Alternate flows covered
- [ ] Each requirement has full Given/When/Then verification
- [ ] Edge cases listed per requirement
- [ ] Detailed instrumentation with events/dimensions
- [ ] Launch checklist complete with rollback condition

### All Tiers
- [ ] Could a developer implement without further clarification?
- [ ] Open questions are genuine unknowns, not gaps in the spec

## Iteration Loop

The iterative review continues until:
- All reviewers agree the spec passes (unanimous PASS)
- Maximum iterations (default 3, configurable via --max-rounds) are reached
- You manually resolve with `${CLAUDE_PLUGIN_ROOT}/bin/review-gate resolve`
