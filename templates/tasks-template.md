<!--
  Canonical TODO.md schema for `/create-tasks` (when no --beads flag).
  Each checklist task is a projection of the richer internal task spec
  defined in create-tasks.md Phase 4 (source documents, outcome/Goal,
  scope/constraints, changes, acceptance criteria, verification, and
  completion-response expectations).
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

Project initialization and prerequisites. Include setup tasks only when required by the plan.

- [ ] **T001** Create project structure per plan
  - **Source Documents**:
    - Plan: [plan.md#L45-L60](path/to/plan.md#L45-L60) — Section: Project Structure
    - Spec: N/A (or link to spec if setup is tied to a spec requirement)
  - **Goal**: Create the plan-required project structure needed by downstream implementation tasks.
  - **Context**: The plan introduces new source, test, or configuration locations that later tasks depend on.
  - **Scope**:
    - In: Create only the directories/files explicitly required by the plan.
    - Out: Do not add implementation behavior or generic scaffolding not referenced by the plan.
  - **Changes**:
    - `src/` — [New|Exists] — add the plan-required module location
    - `tests/` — [New|Exists] — add the plan-required test location
  - **Acceptance Criteria**:
    - Required paths exist and match the plan's file impact summary.
    - No unrelated files or placeholder behavior are added.
  - **Verification**: Run the narrowest filesystem or repo command that confirms the required paths exist.
  - **Completion Response**: Summarize paths created, verification result, and any blocker or risk.

---

## Phase 2: Foundation

Blocking prerequisites for all user stories.

- [ ] **T002** [P] Implement base types/interfaces
  - **Source Documents**:
    - Plan: [plan.md#L80-L95](path/to/plan.md#L80-L95) — Section: Data Model
    - Spec: [spec.md#L25-L35](path/to/spec.md#L25-L35) — US1: User can create entity
  - **Dependencies**: T001
  - **Goal**: Define the shared types/interfaces required by the first feature slice.
  - **Context**: Downstream service and API tasks depend on these contracts matching the plan's data model.
  - **Scope**:
    - In: Add only the type/interface definitions named in the plan.
    - Out: Do not implement persistence, service behavior, or API handlers.
  - **Changes**:
    - `src/types/index.ts` — [New] — define plan-required types/interfaces
  - **Acceptance Criteria**:
    - Types/interfaces expose the fields and states specified by the plan/spec.
    - Downstream imports can compile against the definitions.
  - **Verification**: Run the narrowest typecheck/compile command that proves the contracts compile.
  - **Completion Response**: Summarize contracts added, verification result, and any mismatch or risk.

---

## Phase 3: US1 - [User Story Name] (P1)

[Brief description of user story from spec]

**Independent Test**: [How to verify this story works in isolation]

### Models

- [ ] **T003** [P] [US1] Create [Entity] model
  - **Source Documents**:
    - Plan: [plan.md#L120-L140](path/to/plan.md#L120-L140) — Section: Entity Design
    - Spec: [spec.md#L25-L35](path/to/spec.md#L25-L35) — US1: User can create entity
  - **Dependencies**: T002
  - **Goal**: Define the entity model with the fields and validation rules required for US1.
  - **Context**: This model owns the entity shape used by the service/API slice for US1.
  - **Scope**:
    - In: Implement the entity fields, validation, and model-level errors described by the plan.
    - Out: Do not add service orchestration, storage, or endpoint behavior.
  - **Changes**:
    - `src/models/entity.ts` — [New] — implement the entity model and validation
    - `tests/models/entity.test.ts` — [New] — cover valid and invalid model construction
  - **Acceptance Criteria**:
    - Valid entity inputs construct the expected model state.
    - Invalid entity inputs fail with the planned validation behavior.
  - **Verification**: Run the focused model test command and expect all model tests to pass.
  - **Completion Response**: Summarize model behavior, files changed, verification result, and any remaining risk.

### Services

- [ ] **T004** [US1] Implement [Entity]Service
  - **Source Documents**:
    - Plan: [plan.md#L145-L165](path/to/plan.md#L145-L165) — Section: Service Layer
    - Spec: [spec.md#L25-L35](path/to/spec.md#L25-L35) — US1: User can create entity
  - **Dependencies**: T003
  - **Goal**: Implement the US1 service behavior using the entity model.
  - **Context**: The service is the planned boundary between the model and the endpoint layer.
  - **Scope**:
    - In: Implement the service methods and error handling required for US1.
    - Out: Do not add endpoint wiring or UI behavior.
  - **Changes**:
    - `src/services/entity_service.ts` — [New] — implement service methods
    - `tests/services/entity_service.test.ts` — [New] — cover service success and negative cases
  - **Acceptance Criteria**:
    - Service returns the planned result for valid US1 inputs.
    - Service rejects invalid or missing inputs with the planned errors.
  - **Verification**: Run the focused service unit test command and expect all service tests to pass.
  - **Completion Response**: Summarize service behavior, files changed, verification result, and any remaining risk.

### Endpoints/UI

- [ ] **T005** [US1] Create [Entity] API endpoint
  - **Source Documents**:
    - Plan: [plan.md#L170-L190](path/to/plan.md#L170-L190) — Section: API Endpoints
    - Spec: [spec.md#L25-L35](path/to/spec.md#L25-L35) — US1: User can create entity
    - Spec: [spec.md#L40-L45](path/to/spec.md#L40-L45) — AC1: API returns 201 on success
  - **Dependencies**: T004
  - **Goal**: Expose the US1 entity creation behavior through the planned API endpoint.
  - **Context**: This task owns the externally observable request/response behavior for AC1.
  - **Scope**:
    - In: Add endpoint handler, route registration, and endpoint tests required for US1.
    - Out: Do not add unrelated API actions or UI flows.
  - **Changes**:
    - `src/api/entity.ts` — [New] — implement endpoint handler
    - `src/api/routes.ts` — [Exists] — register the endpoint if required by the plan
    - `tests/api/entity.test.ts` — [New] — cover success and error responses
  - **Acceptance Criteria**:
    - Given a valid request, the endpoint returns the planned success status/body.
    - Given invalid input, the endpoint returns the planned error status/body.
  - **Verification**: Run the focused API test command and any final suite command required by the plan/risk for this feature slice.
  - **Completion Response**: Summarize endpoint behavior, files changed, verification result, and any remaining risk.

---

## Phase 4: US2 - [User Story Name] (P2)

[Brief description of user story from spec]

**Independent Test**: [How to verify this story works in isolation]

- [ ] **T006** [P] [US2] [Task description]
  - **Source Documents**:
    - Plan: [plan.md#L200-L220](path/to/plan.md#L200-L220) — Section: [Relevant section]
    - Spec: [spec.md#L50-L65](path/to/spec.md#L50-L65) — US2: [User story title]
  - **Dependencies**: T002
  - **Goal**: [Concrete outcome this task accomplishes]
  - **Context**: [Task-specific reason this work is needed for US2]
  - **Scope**:
    - In: [Changes included]
    - Out: [Explicit non-goals]
  - **Changes**:
    - `path/to/file` — [New|Exists] — [what to do]
  - **Acceptance Criteria**:
    - [Observable outcome]
  - **Verification**: [Narrowest command/check and expected passing signal]
  - **Completion Response**: Summarize outcome, files changed, verification result, and any remaining risk.

---

## Phase N: Polish & Cross-Cutting

Plan-required documentation, cleanup, or rollout work. Do not add standalone verification-only tasks; include final suite checks in the final implementation or polish task only when the plan/risk warrants them.

- [ ] **T007** Update documentation
  - **Source Documents**:
    - Plan: [plan.md#L275-L290](path/to/plan.md#L275-L290) — Section: Documentation Requirements
    - Spec: N/A (or link to spec if exists)
  - **Dependencies**: T005, T006
  - **Goal**: Update documentation for the plan-delivered behavior.
  - **Context**: The plan requires user/developer-facing documentation to reflect the shipped behavior.
  - **Scope**:
    - In: Update only docs named in the plan.
    - Out: Do not document deferred or out-of-scope behavior.
  - **Changes**:
    - `README.md` — [Exists] — document the new behavior if required by the plan
    - `docs/` — [Exists] — update plan-required docs
  - **Acceptance Criteria**:
    - Docs describe the delivered behavior and omit non-goals/deferred work.
  - **Verification**: Run the narrowest docs lint/check command if available, otherwise inspect the changed docs against the plan requirements.
  - **Completion Response**: Summarize docs changed, verification result, and any remaining risk.

---

## Dependencies Graph

```
T001 → T002 → T003 → T004 → T005 ─┬→ T007
      └──────────────→ T006 ──────┘
```

## Acceptance Criteria Coverage

| Spec AC | Covered By | Verified |
|---------|------------|----------|
| AC1: [Description] | T005 | [ ] |
| AC2: [Description] | T006 | [ ] |

## File Impact Summary

| File | Status | Tasks |
|------|--------|-------|
| `src/models/entity.ts` | New | T003 |
| `src/services/entity_service.ts` | New | T004 |
| `src/api/entity.ts` | New | T005 |

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
  - **Dependencies**: T00Y, T00Z
  - **Goal**: The concrete outcome this task accomplishes
  - **Context**: Why this matters and only the task-specific background needed to execute safely
  - **Scope**: In/out boundaries or constraints when needed
  - **Changes**: path1.ts (New|Exists) — what to do; path2.ts (New|Exists) — what to do
  - **Acceptance Criteria**: Observable outcomes that define "good"
  - **Verification**: Narrowest commands/checks and expected passing signal
  - **Completion Response**: Summarize outcome, files changed, verification results, and remaining risks/blockers
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
