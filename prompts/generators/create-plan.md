# Implementation Plan Creation (Generator)

**IMPORTANT: This is a READ-ONLY task. Do NOT modify any files. Only analyze the provided context and draft an implementation plan.**

You are a generator producing a complete, executable implementation plan from the context appended below.

## Requirements

1. **Output only the plan markdown** (no preamble or analysis).
2. Use the exact template structure below.
3. If details are missing or ambiguous, list them in **Open Questions** instead of inventing.
4. Make dependencies explicit between tasks and on external prerequisites.
5. **Prerequisites must be called out** before the detailed tasks.
6. **Every significant task must include verification steps** (how to check that the work is correct).
7. **Rollback must be covered**:
   - At the task level (how to undo that task's changes).
   - At the plan level (how to roll back the feature safely).
8. When referencing specific files/modules/config:
   - Prefer using paths and modules that appear in the provided context.
   - If you are introducing a new file/module, label it clearly as **New** (e.g., "New: `path/to/file.ts`").
   - Do **not** claim a file/module already exists unless the context strongly supports it.
9. Keep scope explicit:
   - Clearly distinguish MVP tasks from follow-up/nice-to-have tasks when relevant.
   - Include clear **Non-Goals**.
10. Keep the plan concrete and actionable:
    - Steps should be small enough that an engineer can execute them without reinterpretation.
    - Use the provided codebase context when deciding where to place changes.
11. **Trace back to spec**: Reference which spec Acceptance Criteria or Edge Cases each task supports.
12. **Include constraints**: Capture architectural and testing constraints that guide implementation.

## Plan Template

```markdown
# Implementation Plan: [Short Name]

## Context & Goals
- **Spec**: [spec_path if available, otherwise "N/A — derived from user description"]
- [1–3 bullets summarizing the feature or change]
- [Who this is for and what it improves]

## Scope & Non-Goals
- **In Scope**
  - [What this plan will deliver]
- **Out of Scope (Non-Goals)**
  - [Mirror Non-Goals from spec; add implementation-specific exclusions]

## Assumptions & Constraints
- [Key assumptions about existing systems, data, traffic, ownership, etc.]
- [Relevant constraints such as performance, compliance, or timelines]

### Implementation Constraints
- [Architectural constraints — e.g., "extend module X, don't add new service"]
- [Areas to avoid touching]
- [Patterns to follow or avoid]

### Testing Constraints
- [Required coverage levels or quality gates]
- [Performance/load testing requirements]
- [Must-have regression coverage]

## Prerequisites
[Checklist of things that must be true before starting the detailed tasks.]

- [ ] [Access, credentials, or approvals required]
- [ ] [Feature flag framework or config mechanism available]
- [ ] [Any infra, schema, or tooling that must be in place]
- [ ] [Optional: alignment on spec or product decisions]

## High-Level Approach
[1–2 paragraphs or a brief ordered list describing the overall strategy.]

1. [High-level step 1]
2. [High-level step 2]
3. [High-level step 3]

## Detailed Plan

[Each task should be small, ordered, and reference concrete files/modules where possible. Use dependencies to make ordering explicit. Reference which spec Acceptance Criteria or Edge Cases each task supports (e.g., "Covers AC #2").]

### Task 1: [Short title]
- **Goal**: [What this task accomplishes]
- **Covers**: [Spec AC #N, Edge Case X, or "Implementation-only"]
- **Depends on**: [Prerequisites or earlier tasks, e.g., "Prerequisites", "Task 2"] (or "None")
- **Changes**:
  - [Code/config changes, with file/module paths when known. Mark new artifacts as **New**: `path/to/file`.]
- **Verification**:
  - [Tests to add/run, commands, or manual checks]
  - [How you confirm this task is correct and safe]
- **Rollback**:
  - [How to undo this task's changes only (e.g., revert commit, disable flag, remove config)]

### Task 2: [Short title]
- **Goal**: [...]
- **Covers**: [...]
- **Depends on**: [...]
- **Changes**:
  - [...]
- **Verification**:
  - [...]
- **Rollback**:
  - [...]

### Task 3: [Short title]
- **Goal**: [...]
- **Covers**: [...]
- **Depends on**: [...]
- **Changes**:
  - [...]
- **Verification**:
  - [...]
- **Rollback**:
  - [...]

[Add more tasks as needed. For follow-up or nice-to-have items, label them clearly (e.g., "Task N (follow-up)").]

## Risks, Edge Cases & Breaking Changes

### Edge Cases & Failure Modes
[Enumerate edge cases from the spec and describe how each is handled, tested, and monitored. Add implementation-only failure modes as needed.]

- [Edge case from spec]: [Expected behavior/handling]
- [Failure mode]: [Fallback or degraded behavior]
- [External dependency failures]: [Timeouts, retries, circuit breakers, etc.]

### Breaking Changes & Compatibility
[Implement the spec's Backwards Compatibility and Rollout requirements. If any requirement can't be met, list under Open Questions.]

- **Potential Breaking Changes**:
  - [Describe any change that might affect existing clients or workflows]
- **Mitigations**:
  - [Feature flags, dual-writing, versioned APIs, etc.]
- **Rollout Strategy**:
  - [How the change will be rolled out: flag gating, staged rollout, canary, etc.]

## Testing & Validation

[Ensure all spec Acceptance Criteria are traceable to tests or manual checks listed here.]

- **Unit Tests**
  - [Modules/components to cover and key cases]
- **Integration / End-to-End Tests**
  - [Critical flows, contracts with external services, or DB interactions]
- **Regression Tests**
  - [Existing behaviors that must not change, esp. around breaking-change risks]
- **Manual Verification**
  - [Scenarios and environments for manual testing]
- **Monitoring / Observability**
  - [Metrics, logs, and alerts to watch during rollout]

### Acceptance Criteria Coverage
| Spec AC | Covered By |
|---------|------------|
| AC #1: [summary] | Task N, Unit test X |
| AC #2: [summary] | Task M, E2E test Y |

## Rollback Strategy (Plan-Level)

[How to roll back the entire change if needed, not just individual tasks.]

- [Steps to disable or revert the feature (e.g., disable flags, revert DB changes, rollback deployment)]
- [How to verify rollback success]
- [Any data repair or cleanup required]

## Open Questions

[Unresolved decisions or areas where the implementer must follow up. Reference affected tasks.]

- [Question 1] — [Which task(s) or area it blocks]
- [Question 2]
```

## Context

The plan context will be appended below by the caller. Use it as your source of truth.
- Use provided file/module references whenever possible.
- If the context is silent, prefer generic descriptions plus explicit "New:" markers instead of guessing exact file paths.
