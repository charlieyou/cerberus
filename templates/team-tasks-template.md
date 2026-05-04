<!--
  Canonical team task schema for `/create-tasks --agent-team`.

  Parser contract for `/cerberus:run-team`:
  - Each task starts with a level-two heading at column 0: `## T### — <subject>`.
  - The first fenced block immediately under that heading MUST be ```meta.
  - The meta block SHOULD include `phase` so `/cerberus:run-team` can run
    completed-phase epic verification after each execution phase.
  - No narrative text may appear between the heading and the meta block.
  - The task body begins after the first meta fence closes and continues until
    the next `## ` heading at column 0 or EOF.
  - Task bodies may contain other fenced code blocks; the parser must treat only
    the first fence under the heading as metadata.
-->

---
plan: <path-to-plan>.md
spec: <path-to-spec>.md # or N/A
generated: <ISO timestamp>
---

# Team Tasks: <Feature>

**Generated**: <ISO timestamp>
**Plan**: [<path-to-plan>.md](<path-to-plan>.md)
**Spec**: [<path-to-spec>.md](<path-to-spec>.md) or N/A

## Overview

<1-2 sentence summary from the plan's Context & Goals.>

## Task Summary

| Phase | Tasks | Dependencies |
|-------|-------|--------------|
| Setup | T001 | [] |
| Foundation | T002 | [T001] |
| US1: <Name> | T003, T004 | [T002] |

---

## T001 — <subject>
```meta
phase: Setup
files: [path/a.py, path/b.py]
depends: []
acceptance: [AC1, AC2]
plan_link: <plan>.md#L45-L67
```

### Source Documents

- Plan: [<plan>.md#L45-L67](<plan>.md#L45-L67) — Section: <section title>
- Spec: [<spec>.md#L12-L34](<spec>.md#L12-L34) — <story or AC label> (or `Spec: N/A` if no spec exists)

### Dependencies

- None

### Goal

<The concrete outcome this task accomplishes.>

### Context

<Why this task matters and only the task-specific plan/spec background needed to execute safely.>

### Scope

- In: <task-specific changes>
- Out: <non-goals and constraints>

### Changes

- `path/a.py` — [New|Exists] — <what to do>
- `path/b.py` — [New|Exists] — <what to do>

### Acceptance Criteria

- <Observable outcome that defines good for this task.>

### Verification

- <Narrowest command/check and expected passing signal>

### Notes for Agent

- <Task-specific edge cases, gotchas, and constraints only.>

### Completion Response

- Summarize outcome, files changed, verification results, and any remaining risks/blockers.

---

## T002 — <subject>
```meta
phase: Foundation
files: [path/c.py]
depends: [T001]
acceptance: [AC3]
plan_link: <plan>.md#L68-L90
```

### Source Documents

- Plan: [<plan>.md#L68-L90](<plan>.md#L68-L90) — Section: <section title>
- Spec: N/A (or link to spec if this task traces to a spec requirement)

### Dependencies

- T001

### Goal

<The concrete outcome this task accomplishes.>

### Context

<Why this task matters and only the task-specific plan/spec background needed to execute safely.>

### Scope

- In: <task-specific changes>
- Out: <non-goals and constraints>

### Changes

- `path/c.py` — [New|Exists] — <what to do>

### Acceptance Criteria

- <Observable outcome that defines good for this task.>

### Verification

- <Narrowest command/check and expected passing signal>

### Notes for Agent

- <Task-specific edge cases, gotchas, and constraints only.>

### Completion Response

- Summarize outcome, files changed, verification results, and any remaining risks/blockers.

---

## Dependencies Graph

```text
T001 -> T002
```

## Acceptance Criteria Coverage

| Acceptance Criterion | Primary Task | Verified |
|----------------------|--------------|----------|
| AC1: <description> | T001 | [ ] |
| AC2: <description> | T001 | [ ] |
| AC3: <description> | T002 | [ ] |

## File Impact Summary

| File | Status | Tasks |
|------|--------|-------|
| `path/a.py` | New | T001 |
| `path/b.py` | Exists | T001 |
| `path/c.py` | New | T002 |

## Sizing Summary

| Task | Files | Subsystems | ACs | Mechanical? | Status | Action |
|------|-------|------------|-----|-------------|--------|--------|
| T001 | N | N | N | No | OK | — |
| T002 | N | N | N | No | OK | — |

## Requirements Snapshot

| Requirement Type | Source | Text (verbatim) |
|------------------|--------|-----------------|
| Objective | Plan | ... |
| AC | Plan | ... |
| MUST/SHALL | Plan | ... |

## Consistency Audit

| Item | Spec/Legacy | Plan | Status | Notes |
|------|-------------|------|--------|-------|
| ... | ... | ... | Match/Deviation | ... |

## Deviation Log

| Source | Deviation | Rationale | Approved? |
|--------|-----------|-----------|-----------|
| None | None | N/A | N/A |

## Obligation Coverage

| Plan Clause | Task(s) | Verification |
|-------------|---------|--------------|
| "MUST ..." | T001 | ... |

## System Wiring Coverage

Required when applicable; otherwise `N/A`.

| Flow | Wiring Task(s) | Verification |
|------|----------------|--------------|
| ... | ... | ... |

## Propagation Map

Required for new or repurposed inputs, fields, signals, config, or templates; otherwise `N/A`.

| Input/Field/Signal | Origin | Transport | Consumption | Verification |
|--------------------|--------|-----------|-------------|--------------|
| ... | ... | ... | ... | ... |

## Notes

- Total tasks: N
- Execution model: `/cerberus:run-team` may run independent same-phase tasks in parallel when dependencies and file scopes are safe; completion/review remains serialized
- Each implementer commit must include a `Cerberus-Task: T###` trailer
