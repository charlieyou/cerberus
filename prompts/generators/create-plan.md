# Implementation Plan Creation (Generator)

**IMPORTANT: This is a READ-ONLY task. Do NOT modify any files. Only analyze the provided context and draft an implementation plan.**

You are a generator producing a complete, executable implementation plan from the context appended below.

## Interview Phase (Required)

Before generating the plan, you MUST ask clarifying questions if ANY of the following are unclear or ambiguous:

1. **Scope boundaries** - What's explicitly in vs out of scope?
2. **Constraints** - Performance requirements, backwards compatibility needs, testing requirements?
3. **Dependencies** - What must exist before this work can begin? What teams/systems need to be coordinated with?
4. **Feature flags** - Should this be flag-gated for safer changes?
5. **Risk tolerance** - How much testing/validation is expected before shipping?

Base your questions on gaps or ambiguities in the provided spec/context; reference specific sections or assumptions when possible.

If the spec and context are clear and complete, you may skip questions and proceed directly to generating the plan. But if you're making assumptions that could affect the implementation, **ask first**. When in doubt about clarity on any of the above areas, err on the side of asking questions before proceeding.

Format questions as a numbered list. Your first response must be EITHER (a) only the numbered clarifying questions, OR (b) the implementation plan (if no clarifications are needed). Do NOT include both questions and a plan in the same response. Wait for answers before generating the plan.

## Requirements

1. **Output only the plan markdown** (no preamble or analysis), and only after either (a) you have asked clarifying questions and received answers, or (b) you have explicitly determined that no clarifications are needed.
2. Use the exact template structure below.
3. If details are missing or ambiguous, list them in **Open Questions** instead of inventing.
4. Make external dependencies explicit (systems, teams, prerequisites).
5. **Prerequisites must be called out** before the Technical Design.
6. **Testing strategy must be included** (types of tests, verification approach).
7. When referencing specific files/modules/config:
   - Prefer using paths and modules that appear in the provided context.
   - If you are introducing a new file/module, label it clearly as **New** (e.g., "New: `path/to/file.ts`").
   - Do **not** claim a file/module already exists unless the context strongly supports it.
8. Keep scope explicit:
   - Clearly distinguish MVP from follow-up/nice-to-have work when relevant.
   - Include clear **Non-Goals**.
9. Keep the plan concrete and design-focused:
    - Focus on architecture, data model, interfaces, and file impact.
    - Do NOT include detailed task breakdowns (Task 1, Task 2, etc.) — that is handled by `/create-tasks`.
10. **Trace back to spec**: Reference which spec Acceptance Criteria are addressed by which parts of the design.
11. **Include constraints**: Capture architectural and testing constraints that guide implementation.
12. **Acceptance Criteria quality**: Ensure all AC describe observable outcomes, not proxy metrics. See **Acceptance Criteria Quality** below.

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
[Checklist of things that must be true before starting implementation.]

- [ ] [Access, credentials, or approvals required]
- [ ] [Feature flag framework or config mechanism available]
- [ ] [Any infra, schema, or tooling that must be in place]
- [ ] [Optional: alignment on spec or product decisions]

## High-Level Approach
[1–2 paragraphs or a brief ordered list describing the overall strategy.]

1. [High-level step 1]
2. [High-level step 2]
3. [High-level step 3]

## Technical Design

### Architecture
[How components fit together, data flow, key boundaries. Include diagrams if helpful.]

### Data Model
[Entities, relationships, state transitions — or "N/A" if not applicable.]

### API/Interface Design
[Key interfaces, contracts, protocols — or "N/A" if not applicable.]

### File Impact Summary

[Enumerate files that will be created or modified. Use the verification table from context.]

| Path | Status | Description |
|------|--------|-------------|
| `src/module/file.ts` | Exists | Add new method/handler |
| `src/module/new_file.ts` | **New** | New component for X |
| `tests/module/file.test.ts` | **New** | Tests for new functionality |

## Risks, Edge Cases & Breaking Changes

### Edge Cases & Failure Modes
[Enumerate edge cases from the spec and describe how each is handled, tested, and monitored. Add implementation-only failure modes as needed.]

- [Edge case from spec]: [Expected behavior/handling]
- [Failure mode]: [Fallback or degraded behavior]
- [External dependency failures]: [Timeouts, retries, circuit breakers, etc.]

### Breaking Changes & Compatibility
[Implement the spec's Backwards Compatibility requirements. If any requirement can't be met, list under Open Questions.]

- **Potential Breaking Changes**:
  - [Describe any change that might affect existing clients or workflows]
- **Mitigations**:
  - [Feature flags, dual-writing, versioned APIs, etc.]

## Testing & Validation Strategy

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
  - [Metrics, logs, and alerts to watch]

### Acceptance Criteria Coverage
| Spec AC | Covered By |
|---------|------------|
| AC #1: [summary] | Technical Design section X, Unit tests |
| AC #2: [summary] | Data Model, E2E tests |

## Open Questions

[Unresolved decisions or areas where the implementer must follow up.]

- [Question 1] — [Which area it affects]
- [Question 2]

## Next Steps

After this plan is approved, run `/create-tasks` to generate:
- `--beads` → Beads issues with dependencies for multi-agent execution
- (default) → TODO.md checklist for simpler tracking
```

## Acceptance Criteria Quality

Acceptance criteria must describe **observable outcomes**, not **proxy metrics** that can be gamed or satisfied without achieving the actual goal.

Numeric targets are acceptable only when they directly measure user-visible behavior or system SLOs (e.g., latency, error rate), not internal structure (file size, LOC) or process (test counts, time spent).

If the spec's AC are gameable, your plan should reference and reinforce corrected, observable-outcome AC rather than repeating proxy metrics.

### Anti-patterns (Gameable)

| Type | ❌ Bad AC | Why it fails |
|------|----------|--------------|
| Refactoring | "File under 500 lines" | Can inline, delete docs, split arbitrarily |
| Features | "Add 3 unit tests" | Tests can be trivial/meaningless |
| Performance | "Reduce function calls by 50%" | Can inline everything, hurt readability |
| Coverage | "Achieve 80% coverage" | Can add tests that assert nothing |
| Bugs | "Fix the crash" | Doesn't verify correct behavior restored |
| Process metrics | "Spend 2 days refactoring" / "Touch 5 files" | Time/effort/file-count says nothing about outcome |

### Good AC Patterns

| Type | ✅ Good AC | Why it works |
|------|-----------|--------------|
| Refactoring | "X delegates to Y; no direct Z manipulation" | Describes responsibility boundaries |
| Features | "Given X, when Y, then Z" | Observable behavior |
| Performance | "P95 latency < 200ms under load L" | Measurable user impact |
| Bugs | "Given [repro], system returns [expected]" | Verifies correct behavior |
| Cleanup | "No references to deprecated API remain" | Verifiable state |

### The Malicious Compliance Test

Before finalizing AC, ask:
1. **Can this be satisfied while missing the point?** → Rewrite
2. **Does this focus on a side effect (size, count, coverage) instead of behavior or invariants?** → Rewrite to describe the behavior or invariant
3. **Would a malicious-compliance agent pass this?** → Add behavioral constraint

## Context

The plan context will be appended below by the caller. Use it as your source of truth.
- Use provided file/module references whenever possible.
- If the context is silent, prefer generic descriptions plus explicit "New:" markers instead of guessing exact file paths.
