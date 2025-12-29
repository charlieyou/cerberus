# Architecture Review Analysis

**IMPORTANT: This is a READ-ONLY review. Do NOT modify any files. Only analyze and report findings.**

Perform a **principal-engineer-level** architecture review focused on **high-leverage design improvements**. Optimize for **maximum long-term payoff per hour invested**. Prefer **functional patterns** (pure functions, explicit data flow, composition) unless the codebase clearly benefits from OO constructs.

This is not a correctness bug hunt. Only flag correctness issues if they block architectural change or reveal systemic design flaws.

## Guidelines for Flagging Issues

1. The issue meaningfully impacts maintainability, scalability, or correctness.
2. The issue is discrete and actionable (not a general concern about "architecture").
3. The issue targets structural problems, not code style.
4. To claim a boundary violation, you must identify both sides of the boundary.
5. The fix should provide leverage - improving multiple areas, not just one.
6. Avoid speculative concerns - identify concrete structural problems.
7. Only cite issues you can point to in code you actually inspected.
8. Do not rely on unstated assumptions; if you're not confident, skip it.
9. Keep line ranges as tight as possible (avoid ranges over 5-10 lines).
10. Use one issue per distinct problem.
11. If there is no issue a maintainer would definitely fix, prefer no findings.

## Comment Guidelines

1. Be clear about why the structural issue matters.
2. Communicate severity appropriately - don't overstate.
3. Keep descriptions brief (1 paragraph max per issue).
4. Reference specific modules, files, and dependency paths.
5. Suggest concrete refactoring approaches.
6. Acknowledge trade-offs (e.g., "This adds complexity but improves X").
7. Maintain a matter-of-fact, helpful tone.
8. If you include code, quote 3 lines or fewer.
9. Call out the concrete scenario that makes the issue matter.

## Traversal Strategy

1. **Map boundaries** (quick pass): entry points, public APIs, services, and core domains
2. **Trace dependency flow**: identify layers and check for dependency inversions
3. **Run hotspot analysis**: use metrics to rank candidates before deep-diving
   - Target: cyclomatic complexity >= 15, function length >= 80 lines, file length >= 500 lines
4. **Validate reachability**: ensure hotspots are on real execution paths; skip dead code

Stop traversal once you have enough evidence to populate the top 6-12 issues.

## What to Look For

### 1. Boundary & Dependency Smells
- Circular dependencies across layers
- UI/API code reaching into persistence or infra details
- Domain logic scattered across `utils/` or unrelated modules
- Inconsistent error handling or data validation across similar flows

### 2. Complexity & Duplication Hotspots
- Functions with complex branching or deep nesting
- Copy/paste logic across modules that should be shared
- "One-off" helpers duplicated in multiple files

### 3. Oversized or Confused Modules
- Files that mix IO + business rules + formatting
- "God classes" with too many responsibilities
- Classes that are only bags of functions (prefer a module of pure functions)

### 4. Abstraction Mismatch
- Over-abstracted layers that add indirection but no value
- Under-abstracted logic where similar flows diverge unnecessarily
- Leaky abstractions that force callers to know internal details

### 5. Testability Friction
- Hidden global state, time, randomness, or IO in core logic
- Heavy constructors or framework setup required just to test logic
- Tight coupling that makes unit tests impossible without integration scaffolding

## Priority Levels

- [P0] - Critical. Architecture causes production risk or data integrity issues (use sparingly).
- [P1] - Urgent. Architectural debt blocking feature velocity or safe changes.
- [P2] - Normal. Design friction that slows changes but is not blocking.
- [P3] - Low. Improvement opportunity with limited ROI.

## Priority Order for Analysis

When in doubt, prioritize:
1. **Boundary clarity & dependency direction** - modules should have crisp responsibilities and one-way dependencies
2. **Testability & change isolation** - changes should be easy to validate without heavy setup
3. **Complexity & duplication hotspots** - high cyclomatic complexity, copy/paste logic, tangled flows
4. **Size & cohesion** - oversized files/modules, "god classes", mixed concerns
5. **Abstraction fitness** - too much abstraction (YAGNI) or too little (leaky, repetitive)

## Functional Design Bias (prefer these refactors)

- Move side effects to the edges; keep core logic **pure and deterministic**
- Use **data-in/data-out** functions and compose with pipelines
- Replace stateful classes with **stateless modules** where possible
- Pass dependencies explicitly (function params) rather than via globals or singletons
- Model transformations as **small pure functions**; keep orchestration thin

Use OO only when it clearly improves ergonomics (e.g., polymorphism with real behavior variance).

## Out of Scope (Do Not Report)

- Style/formatting issues (leave to linters)
- Minor naming inconsistencies
- Missing documentation unless it blocks understanding
- Single-use code that's appropriately inlined
- Test coverage gaps (unless they indicate untestable design)
- Performance micro-optimizations without measured impact
- Dead code, ghost features, or AI-specific API misuse (covered by healthcheck)
- Hygiene cleanup (debug logs, stale TODOs, build artifacts)

## Output Format

Produce a structured architecture review with:

1. **Method** block (3-6 bullets): tools run, entry points reviewed, key files scanned, assumptions/unknowns

2. **Issues** sorted by priority [P0-P3], each with:
   - **Priority tag and title** (e.g., "[P1] Circular dependency between auth and users")
   - **Primary files**: paths with approximate line numbers
   - **Category**: Boundaries | Testability | Complexity | Duplication | Cohesion | Abstraction
   - **Context**: What's wrong, why it matters (1 paragraph max)
   - **Fix**: Concrete action to resolve (1-3 sentences)
   - **Acceptance Criteria**: 1-3 bullets

## CRITICAL RULES

1. **DO NOT modify, create, or delete any files** - this is analysis only
2. **DO NOT attempt to fix issues** - only report them
3. **DO NOT install packages or run commands that change state**
4. You may only use read operations: list files, read files, search content
