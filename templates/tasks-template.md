<!--
  Canonical TODO.md schema for `/create-tasks` (when no --beads flag).
  Each checklist task is a projection of the richer internal task spec
  defined in create-tasks.md Phase 4 (Type, Priority, Story, Goal, etc.).
-->

# TODO: [Feature Name]

**Generated**: YYYY-MM-DD
**Plan**: [link to plan.md]
**Spec**: [link to spec.md or "N/A"]

## Overview

[1-2 sentence summary from plan's Context & Goals]

## Task Summary

| Phase | Tasks | Parallel | Dependencies |
|-------|-------|----------|--------------|
| Setup | N | M | — |
| Foundation | N | M | Setup |
| US1: [Name] (P1) | N | M | Foundation |
| US2: [Name] (P2) | N | M | Foundation |
| Polish | N | M | US1, US2 |

---

## Phase 1: Setup

Project initialization and dependencies.

- [ ] **T001** Create project structure per plan
  - **Files**: `src/`, `tests/`, `config/`
  - **Verify**: Directory structure exists, matches plan

- [ ] **T002** Install dependencies
  - **Files**: `package.json` or equivalent
  - **Depends**: T001
  - **Verify**: Install command succeeds

---

## Phase 2: Foundation

Blocking prerequisites for all user stories.

- [ ] **T003** [P] Implement base types/interfaces
  - **Files**: `src/types/index.ts` (New)
  - **Depends**: T002
  - **Verify**: Types compile without errors

- [ ] **T004** [P] Set up configuration
  - **Files**: `src/config/index.ts` (New)
  - **Depends**: T002
  - **Verify**: Config loads correctly

---

## Phase 3: US1 - [User Story Name] (P1)

[Brief description of user story from spec]

**Independent Test**: [How to verify this story works in isolation]

### Models

- [ ] **T005** [P] [US1] Create [Entity] model
  - **Files**: `src/models/entity.ts` (New)
  - **Depends**: T003
  - **Goal**: Define entity with fields, validation rules
  - **Verify**: Model instantiation works, validation enforced

### Services

- [ ] **T006** [US1] Implement [Entity]Service
  - **Files**: `src/services/entity_service.ts` (New)
  - **Depends**: T005
  - **Goal**: CRUD operations for entity
  - **Verify**: Unit tests pass

### Endpoints/UI

- [ ] **T007** [US1] Create [Entity] API endpoint
  - **Files**: `src/api/entity.ts` (New)
  - **Depends**: T006
  - **Goal**: REST endpoint for entity operations
  - **Verify**: API responds correctly to requests

---

## Phase 4: US2 - [User Story Name] (P2)

[Brief description of user story from spec]

**Independent Test**: [How to verify this story works in isolation]

- [ ] **T008** [P] [US2] [Task description]
  - **Files**: [paths]
  - **Depends**: T003
  - **Verify**: [How to verify]

---

## Phase N: Polish & Cross-Cutting

Final validation and cleanup.

- [ ] **T0XX** Run full test suite
  - **Depends**: All previous tasks
  - **Verify**: All tests pass, coverage meets requirements

- [ ] **T0XX** Update documentation
  - **Files**: `README.md`, `docs/`
  - **Verify**: Docs reflect new functionality

---

## Dependencies Graph

```
T001 → T002 → T003 ─┬→ T005 → T006 → T007
                    └→ T004
                    
T003 → T008

T007 ─┬→ T0XX (Polish)
T008 ─┘
```

## Acceptance Criteria Coverage

| Spec AC | Covered By | Verified |
|---------|------------|----------|
| AC1: [Description] | T005, T006, T007 | [ ] |
| AC2: [Description] | T008 | [ ] |

## File Impact Summary

| File | Status | Tasks |
|------|--------|-------|
| `src/models/entity.ts` | New | T005 |
| `src/services/entity_service.ts` | New | T006 |
| `src/api/entity.ts` | New | T007 |

## Notes

- **Total tasks**: N
- **Parallelizable**: M (tasks marked [P])
- **Estimated phases**: X
- **MVP scope**: Phase 1-3 (Setup + Foundation + US1)

---

## Task Format Reference

Each task follows this format:

```markdown
- [ ] **T00X** [P] [USn] Description
  - **Files**: path1.ts (New|Exists), path2.ts
  - **Depends**: T00Y, T00Z
  - **Goal**: What this accomplishes (optional, for complex tasks)
  - **Verify**: How to confirm completion
```

**Format key:**
- `[P]` = Parallelizable (no file overlap with concurrent tasks)
- `[USn]` = Maps to User Story N from spec
- `(New)` = File to be created
- `(Exists)` = Existing file to modify
