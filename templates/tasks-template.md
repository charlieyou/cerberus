<!--
  Canonical TODO.md schema for `/create-tasks` (when no --beads flag).
  Each checklist task is a projection of the richer internal task spec
  defined in create-tasks.md Phase 4 (Type, Priority, Story, Goal, etc.).
-->

# TODO: [Feature Name]

**Generated**: YYYY-MM-DD
**Plan**: [feature-plan.md](path/to/feature-plan.md)
**Spec**: [feature-spec.md](path/to/feature-spec.md) or "N/A"

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
  - **Source Documents**:
    - Plan: [plan.md#L45-L60](path/to/plan.md#L45-L60) — Section: Project Structure
  - **Files**: `src/`, `tests/`, `config/`
  - **Verify**: Directory structure exists, matches plan

- [ ] **T002** Install dependencies
  - **Source Documents**:
    - Plan: [plan.md#L62-L75](path/to/plan.md#L62-L75) — Section: Dependencies
  - **Files**: `package.json` or equivalent
  - **Depends**: T001
  - **Verify**: Install command succeeds

---

## Phase 2: Foundation

Blocking prerequisites for all user stories.

- [ ] **T003** [P] Implement base types/interfaces
  - **Source Documents**:
    - Plan: [plan.md#L80-L95](path/to/plan.md#L80-L95) — Section: Data Model
  - **Files**: `src/types/index.ts` (New)
  - **Depends**: T002
  - **Verify**: Types compile without errors

- [ ] **T004** [P] Set up configuration
  - **Source Documents**:
    - Plan: [plan.md#L100-L115](path/to/plan.md#L100-L115) — Section: Configuration
  - **Files**: `src/config/index.ts` (New)
  - **Depends**: T002
  - **Verify**: Config loads correctly

---

## Phase 3: US1 - [User Story Name] (P1)

[Brief description of user story from spec]

**Independent Test**: [How to verify this story works in isolation]

### Models

- [ ] **T005** [P] [US1] Create [Entity] model
  - **Source Documents**:
    - Plan: [plan.md#L120-L140](path/to/plan.md#L120-L140) — Section: Entity Design
    - Spec: [spec.md#L25-L35](path/to/spec.md#L25-L35) — US1: User can create entity
  - **Files**: `src/models/entity.ts` (New)
  - **Depends**: T003
  - **Goal**: Define entity with fields, validation rules
  - **Verify**: Model instantiation works, validation enforced

### Services

- [ ] **T006** [US1] Implement [Entity]Service
  - **Source Documents**:
    - Plan: [plan.md#L145-L165](path/to/plan.md#L145-L165) — Section: Service Layer
    - Spec: [spec.md#L25-L35](path/to/spec.md#L25-L35) — US1: User can create entity
  - **Files**: `src/services/entity_service.ts` (New)
  - **Depends**: T005
  - **Goal**: CRUD operations for entity
  - **Verify**: Unit tests pass

### Endpoints/UI

- [ ] **T007** [US1] Create [Entity] API endpoint
  - **Source Documents**:
    - Plan: [plan.md#L170-L190](path/to/plan.md#L170-L190) — Section: API Endpoints
    - Spec: [spec.md#L25-L35](path/to/spec.md#L25-L35) — US1: User can create entity
    - Spec: [spec.md#L40-L45](path/to/spec.md#L40-L45) — AC1: API returns 201 on success
  - **Files**: `src/api/entity.ts` (New)
  - **Depends**: T006
  - **Goal**: REST endpoint for entity operations
  - **Verify**: API responds correctly to requests

---

## Phase 4: US2 - [User Story Name] (P2)

[Brief description of user story from spec]

**Independent Test**: [How to verify this story works in isolation]

- [ ] **T008** [P] [US2] [Task description]
  - **Source Documents**:
    - Plan: [plan.md#L200-L220](path/to/plan.md#L200-L220) — Section: [Relevant section]
    - Spec: [spec.md#L50-L65](path/to/spec.md#L50-L65) — US2: [User story title]
  - **Files**: [paths]
  - **Depends**: T003
  - **Verify**: [How to verify]

---

## Phase N: Polish & Cross-Cutting

Final validation and cleanup.

- [ ] **T0XX** Run full test suite
  - **Source Documents**:
    - Plan: [plan.md#L250-L270](path/to/plan.md#L250-L270) — Section: Testing & Validation Strategy
    - Spec: N/A (or link to spec if exists)
  - **Depends**: All previous tasks
  - **Verify**: All tests pass, coverage meets requirements

- [ ] **T0XX** Update documentation
  - **Source Documents**:
    - Plan: [plan.md#L275-L290](path/to/plan.md#L275-L290) — Section: Documentation Requirements
    - Spec: N/A (or link to spec if exists)
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
  - **Source Documents**:
    - Plan: [plan.md#L45-L67](path/to/plan.md#L45-L67) — Section: [section title]
    - Spec: [spec.md#L12-L34](path/to/spec.md#L12-L34) — USn: [story title] (if spec exists)
  - **Files**: path1.ts (New|Exists), path2.ts
  - **Depends**: T00Y, T00Z
  - **Goal**: What this accomplishes (optional, for complex tasks)
  - **Verify**: How to confirm completion
```

**Format key:**
- `**Source Documents**` = Links to plan/spec sections with line numbers (REQUIRED for every task)
  - Line numbers in `#L<n>` or `#L<n>-L<m>` format
  - Labels must match text actually present in the referenced range
  - Spec link required if spec exists (plan references it, adjacent `*-spec.md` exists, or provided as input); otherwise "Spec: N/A"
- `[P]` = Parallelizable (no file overlap with concurrent tasks)
- `[USn]` = Maps to User Story N from spec
- `(New)` = File to be created
- `(Exists)` = Existing file to modify
