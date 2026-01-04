# Prioritized BFS Interview Engine

> **Canonical path:** `${CLAUDE_PLUGIN_ROOT}/prompts/interview-engine.md`
> If you copy this file, keep it identical to avoid drift.

This document defines the shared interview mechanism used by `/create-spec` and `/create-plan`. The goal is to ask questions **in order of importance**, **high-level first**, and **keep asking until the user says to stop**.

## Tooling Integration

**Use `AskUserQuestion` for all interview batches.** Put the entire batch (coverage status + numbered questions + off-ramp) inside a single tool call. Plain text output is not interactive.

## Core Principle: Prioritized Breadth-First Search

Questions are organized by:
1. **Priority** (P0-P3): Most critical questions first
2. **Depth** (L0-L3): High-level before details
3. **Topic rotation**: Cover all topics at a depth before drilling into any one

## Eligibility & Ordering Rules

**Queue ordering** (sort key): `priority ASC → depth ASC → topic rotation → stable tie-breaker`

**Topic rotation algorithm**:
- Track `last_topic_asked`
- When multiple eligible questions share same priority+depth, pick from a different topic than `last_topic_asked`
- Tie-breaker: alphabetical order of topic name, then alphabetical order of TBD tag

**Eligibility rules** — a question is eligible if:
- `depth <= max_depth` (user hasn't capped depth)
- `priority <= max_priority` (user hasn't said "skip P2/P3")
- `topic not capped` (user hasn't said "enough about [topic]")
- Prerequisites satisfied (ask deeper questions only after prerequisites at current depth are resolved, unless user explicitly requests a deep dive)

**Coverage definition**: A topic is "covered at depth Lk" when its Lk-level TBDs are either filled, turned into an explicit Decision, or moved to Open Questions with an owner.

**State update procedure** — after each user response:
1. For each answered question: update its `[TBD]` to filled content
2. For each skipped question: move to Open Questions with owner (ask for owner if unclear)
3. For "you decide": write a Decision with rationale, then stop deeper follow-ups on that item

---

## Priority Levels

| Priority | Description | Examples |
|----------|-------------|----------|
| **P0** | Blockers / correctness | Definition of done, scope boundaries, safety/security, backwards compatibility, data loss risks, acceptance criteria |
| **P1** | Major design choices | Architecture shape, API contracts, ownership, primary UX flows, testing strategy |
| **P2** | Completeness / edge cases | Alternate flows, failure modes, performance, observability, migration details |
| **P3** | Polish / nice-to-have | Ergonomics, refactors, optimizations, minor UX improvements |

---

## Depth Levels

| Depth | Scope | Examples |
|-------|-------|----------|
| **L0** | Vision / outcome | What problem? Who? Success criteria? Scope/non-goals? Definition of done? |
| **L1** | Architecture / approach | High-level design, boundaries, data flow, APIs conceptually, rollout stance |
| **L2** | Components / decomposition | Subsystems, modules, entities, endpoints, state machines, test layers |
| **L3** | Implementation details | File-level, exact schemas, payloads, algorithms, test cases, telemetry fields |

**Rule of thumb**: A question's depth is "the deepest artifact it commits you to."

---

## Stop Signals (CRITICAL)

Listen for these signals and **immediately adjust** the interview flow.

### Global Stop (end interview now)
- "enough detail"
- "that's enough"
- "stop here"
- "we're good"
- "no more questions"
- "ship it" / "good to proceed"
- "that level is enough"

When triggered: End interview. Convert remaining `[TBD]` to Open Questions.

### Depth Cap (stop at a depth level)
- "stop at L0/L1/L2"
- "keep it high-level"
- "don't go into implementation"
- "no deep dive"
- "architecture level is enough"
- "details later"

When triggered: Set `max_depth` and continue within that cap.

### Per-Topic Stop (stop drilling one area)
- "enough about [topic]"
- "skip the rest of [topic]"
- "don't drill into [topic]"
- "park [topic]"
- "we'll decide [topic] later"

When triggered: Mark topic as capped, continue with other topics.

### Priority Cap (skip lower-priority items)
- "skip P2/P3"
- "just blockers"
- "P0/P1 only"
- "focus on the important stuff"

When triggered: Set `max_priority` (e.g., P1). Convert lower-priority items to Open Questions or Future Improvements.

### Per-Question Skip
- "skip this one"
- "next question"
- "not relevant"

When triggered: Mark that TBD as Open Question; do not enqueue deeper follow-ups for it.

### Delegation Signals
| Signal | Action |
|--------|--------|
| "you decide" | Pick safe default, record in Decisions, stop deeper on this question |
| "I don't know" | Offer 2-3 options; if declined, record as Open Question |
| "whatever's standard" | Use codebase conventions, record decision, stop deeper |

---

## Interview Loop Mechanism

### Before Each Batch

1. **Check current coverage**:
   - Which priority levels are complete at which depths?
   - Format: "P0 complete through L1; P1 complete through L0"

2. **Select next batch** (up to 3-5 questions):
   - Filter: `depth <= max_depth`, `priority <= max_priority`, `topic not capped`
   - Sort by: priority ASC → depth ASC → topic rotation
   - Include questions from multiple topics (breadth)
   - Smaller batches are fine when eligible queue is small

### Batch Presentation Format

Present questions with explicit context and an off-ramp:

```
**Interview Batch [N]** (Priority: P{X}, Depth: L{Y})

Current coverage: [P0 complete through L1, P1 complete through L0]

Questions (answer any, skip any):

1. [Topic: Scope] What are the explicit non-goals?
   - Options: [A] Exclude X and Y, [B] Exclude only X, [C] You decide
   
2. [Topic: Testing] What test types are required?
   - Options: [A] Unit only, [B] Unit + integration, [C] Full pyramid
   
3. [Topic: Data] Are there schema changes?
   - Evidence (verified): I see migrations in `db/migrations/`

---
Reply using `1: <answer> 2: <answer>` format (skip numbers you want to leave as Open Questions).
Or say "enough detail" to stop, "keep it high-level" to cap depth.
```

**Evidence rule**: Only include an "Evidence" line if you have actually observed it via tools or provided context. Otherwise omit evidence entirely. Never invent or assume file paths exist.

### After Each Answer

1. **Update skeleton immediately**:
   - Fill the `[TBD]` placeholder, OR
   - Mark as Open Question (with owner if possible), OR
   - Record as Decision (especially for "you decide")

2. **Check for stop signals** in the response

3. **Decide whether to enqueue deeper follow-ups**:
   - Only if user hasn't capped that topic
   - Only if all P0 breadth at current depth is covered (BFS rule)

### End-of-Batch Check-in

After each batch, ask ONE meta-question (not a pile):

> "Continue to next depth (L{k+1}), stop here, or drill deeper on a specific topic?"

If user gives any stop phrase → terminate interview; remaining `[TBD]` become Open Questions.

---

## TBD Tag Format (Recommended)

Use tagged TBDs so the system can auto-queue questions:

```markdown
[TBD P0 L1 topic=testing: required test types and coverage]
[TBD P1 L0 topic=scope: explicit non-goals]
[TBD P2 L2 topic=api: endpoint payload structure]
```

This enables:
- Automatic priority/depth sorting
- Topic-based filtering when user caps a topic
- Progress tracking

---

## Mode-Based Defaults

| Mode | Default Max Depth | Batch Size | Exit Behavior |
|------|-------------------|------------|---------------|
| fast | L1 | 3-4 | Stop at first "enough", mark rest as Open Questions |
| smart | L2 | 4-5 | Ask through P1/L1, prompt for deeper |
| max | L3 | 5-6 | Proactively probe for edge cases, push to L2/L3 |

---

## Topic Lists

### For Specs
- `scope`: problem, goals, non-goals, boundaries
- `ux`: flows, states, user feedback
- `requirements`: MUST statements, acceptance criteria
- `verification`: GWT, test approach, validation
- `rollout`: instrumentation, launch checks
- `constraints`: compatibility, security, performance

### For Plans
- `scope`: starting point, spec reference, boundaries
- `architecture`: high-level approach, boundaries, ownership
- `data`: schema, migrations, compatibility
- `api`: interfaces, contracts, breaking changes
- `testing`: strategy, coverage, verification
- `implementation`: file targets, dependencies
- `rollout`: flags, monitoring, operational concerns

---

## Applying to Review Gates

During review refinement, treat reviewer findings as queue items:
- `priority` = reviewer severity (P0-P3)
- `depth` = how invasive the clarification is

Ask breadth-first: resolve all P0 findings across sections before drilling into any single finding.

Present findings grouped by priority:
> "Reviewers found 2 P0 issues and 3 P1 issues. Let's address P0s first:
> 1. [Section: Scope] Unclear what happens when X fails
> 2. [Section: Testing] No verification for requirement R3"
