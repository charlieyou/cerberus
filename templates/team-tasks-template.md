<!--
  Canonical team task schema for `/create-tasks --agent-team`.

  Parser contract for `/cerberus:run-team`:
  - Each task starts with a level-two heading at column 0: `## T### — <subject>`.
  - The first fenced block immediately under that heading MUST be ```meta.
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
| Setup | N | [] |
| Foundation | N | [T001] |
| US1: <Name> | N | [T00X] |

---

## T001 — <subject>
```meta
files: [path/a.py, path/b.py]
depends: []
acceptance: [AC1, AC2]
plan_link: <plan>.md#L45-L67
```

### Source Documents

- Plan: [<plan>.md#L45-L67](<plan>.md#L45-L67) — Section: <section title>
- Spec: [<spec>.md#L12-L34](<spec>.md#L12-L34) — <story or AC label>, or N/A

### Files

- `path/a.py` (New|Exists)
- `path/b.py` (New|Exists)

### Depends

- None

### Goal

<What this task accomplishes.>

### Implementation Notes

<Full task spec body from Phase 4, including sizing, source links, dependency rationale, TDD steps, and any file-overlap constraints.>

### Verification

- <Command or behavioral check>

---

## T002 — <subject>
```meta
files: [path/c.py]
depends: [T001]
acceptance: [AC3]
plan_link: <plan>.md#L68-L90
```

### Source Documents

- Plan: [<plan>.md#L68-L90](<plan>.md#L68-L90) — Section: <section title>

### Files

- `path/c.py` (New|Exists)

### Depends

- T001

### Goal

<What this task accomplishes.>

### Implementation Notes

<Full task spec body from Phase 4.>

### Verification

- <Command or behavioral check>

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

## Notes

- Total tasks: N
- Execution model: strictly serial in `/cerberus:run-team` initial cut
- Each implementer commit must include a `Cerberus-Task: T###` trailer
