# Spec Creation (Generator)

**IMPORTANT: This is a READ-ONLY task. Do NOT modify any files. Only analyze the provided context and draft a spec.**

You are a generator producing a feature specification from the context appended below.

## Tier System

Specs scale with complexity. The context will specify a tier (S/M/L). Include only the sections required for that tier.

| Tier | Use Case | Sections Required |
|------|----------|-------------------|
| **S** | Bug fix, tiny tweak | Problem, change summary, scope boundary, UX impact, acceptance bullets, validation method, open questions |
| **M** | Small feature | S + Goal, success criteria, non-goals, primary flow, key states, requirements with MUST + verification examples, basic instrumentation |
| **L** | Multi-flow project | M + Constraints, alternate flows, full Given/When/Then, edge cases per requirement, detailed instrumentation, launch checklist |

**Canonical field mapping:**
- **S only:** Change summary, Scope boundary, UX impact (yes/no), Acceptance bullets, Validation after release
- **M adds:** Goal, Success criteria, Non-goals, Primary flow, Key states, Requirements (R1/R2 with MUST + examples), Instrumentation (light)
- **L adds:** Constraints, Alternate flows, Edge cases per requirement, Full GWT verification, Launch checklist

## Requirements

1. **Output only the spec markdown** (no preamble or analysis).
2. Use the template structure below, **omitting sections not required for the tier**.
3. If details are missing or ambiguous, list them in **Open Questions** instead of inventing.
4. Reference existing codebase structure when provided (files, modules, patterns).
5. **Verification must be concrete and testable** - write as "Given X, when Y, then Z" for Tier L, or simple bullets for Tier S/M.
6. **No implementation details** - do NOT include code snippets, line numbers, function signatures, data models, or test code.

## What NOT to Include (Implementation Details)

A spec defines **what** to build and **why**, not **how**. Leave these for the implementation plan:

- ❌ Code snippets or pseudo-code
- ❌ Exact line numbers or line ranges in files
- ❌ Step-by-step implementation instructions
- ❌ Specific function signatures or method names
- ❌ Data models, schemas, or type definitions
- ❌ Test code examples
- ❌ "Before/After" code comparisons

Instead, use high-level descriptions:
- ✅ "Add a new event to the MalaEventSink protocol"
- ❌ "Add `def on_validation_started(self, agent_id: str) -> None:` at line 399"

## Spec Template

Include only sections marked for the specified tier. Omit sections for higher tiers.

```markdown
# [Feature Name]

**Tier:** S / M / L
**Owner:** [Owner name/team]
**Target ship:** [Date or milestone]
**Links:** [Figma, ticket, related docs]

## 1. Outcome & Scope

**Problem / context** *(S/M/L)*
[2-3 sentences: What's broken/missing today? Who is impacted?]

**Change summary** *(S only)*
[What are we changing and why?]

**Scope boundary** *(S only)*
[Only affects X; does not change Y/Z.]

**Goal** *(M/L)*
[One sentence: "Enable <user> to <do X> so that <benefit>."]

**Success criteria** *(M/L)*
- [Metric + threshold + timeframe, e.g., "≥80% of users complete X within 7 days"]

**Non-goals** *(M/L)*
- [Explicitly excluded functionality]

**Constraints** *(L)*
- Compatibility: [Any existing clients/integrations affected]
- [Other constraints: performance, security, environment]

## 2. User Experience & Flows

**UX impact** *(S only)*
- User-visible? (yes/no)
- If yes: [When user does A, they now see B instead of C.]

**Primary flow** *(M/L)*
1. [Step 1]
2. [Step 2]
3. [Step 3]

**Key states** *(M/L)*
- Empty state: [What user sees when no data]
- Loading state: [Feedback during operations]
- Success state: [Confirmation of completion]
- Error state(s): [How errors are communicated]

**Alternate flows** *(L)*
- [Scenario]: [Expected outcome]

## 3. Requirements + Verification

**Acceptance criteria** *(S)*
- When [X happens], then [Y]
- Also verify: [regression checks]

**R1 — [Short name]** *(M/L)*
- **Requirement:** The system MUST [observable behavior]
- **Verification:** *(M: example; L: full Given/When/Then)*
- **Edge cases:** *(L only)* [Boundary conditions]

**R2 — [Short name]** *(M/L)*
- **Requirement:** The system MUST [observable behavior]
- **Verification:** *(M: example; L: full Given/When/Then)*
- **Edge cases:** *(L only)* [Boundary conditions]

## 4. Instrumentation & Release Checks

**Validation after release** *(S)*
- How to confirm: [Try scenario X in env Y]
- Known risks: [Blast radius]

**Instrumentation** *(M/L)*
- Events to track: [Feature entry, completion, failure reasons]

**Launch checklist** *(L)*
- [ ] All MUST requirements verifiable
- [ ] Key error states covered
- [ ] Metrics available to confirm success criteria
- [ ] Rollback condition defined

**Open questions** *(S/M/L)*
- [Unresolved decisions that may affect implementation]
```

## Acceptance Criteria Quality

Acceptance criteria must describe **observable outcomes**, not **proxy metrics** that can be gamed or satisfied without achieving the actual goal.

Numeric targets are acceptable only when they directly measure user-visible behavior or system SLOs (e.g., latency, error rate), not internal structure (file size, LOC) or process (test counts, time spent).

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

The spec context will be appended below by the caller. Use it as your source of truth.
