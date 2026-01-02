---
description: Generate actionable tasks from a plan, outputting to Beads issues (--beads) or TODO.md
argument-hint: [--beads] [--from-plan <path/to/plan.md>]
---

# Create Tasks (Plan → Execution Artifacts)

Convert a stable implementation plan into actionable, dependency-ordered tasks. Output to either **Beads issues** (with `--beads` flag) or a **TODO.md** file (default).

> **Upstream**: This command accepts output from `/create-plan`.

## Mode Selection

| Flag | Output | Best For |
|------|--------|----------|
| (default) | `TODO.md` in plan directory | Quick projects, no issue tracker |
| `--beads` | Beads issues with dependencies | Multi-agent parallelization, tracked work |

## Input

The user provides either:
- A **plan path** via `--from-plan path/to/plan.md`
- Or expects the most recent plan in `docs/` or `~/.claude/plans/`

## Workflow

### Phase 1: Load Plan Context

1. **Locate plan file**:
   - If `--from-plan` provided, use that path
   - Otherwise, find most recent `*-plan.md` in `docs/` or `~/.claude/plans/`
   - If no plan found, abort: "No plan found. Run /create-plan first."

2. **Extract from plan**:
   - Context & Goals (feature summary)
   - Scope & Non-Goals (boundaries)
   - High-Level Approach (phases, technical approach)
   - Technical Design (architecture, data model, interfaces)
   - File Impact Summary (primary source of file paths)
   - Risks & Edge Cases
   - Testing & Validation Strategy
   - Acceptance Criteria Coverage table
   - Rollback Strategy

3. **Plan completeness check**:
   - If plan contains `[TBD]` in Technical Design, Testing Strategy, or Rollback Strategy:
     - **Warn** the user that plan is incomplete
     - Either (a) abort and recommend running `/create-plan` review gate, or
     - (b) create a preliminary "Clarify design gaps" task before implementation tasks

4. **Load companion artifacts** (if referenced in plan):
   - Spec file (for user stories, priorities, AC)
   - Data model (for entity tasks)
   - Contracts (for API tasks)

### Phase 2: File Existence Verification

Before generating tasks, verify all referenced files:

1. **Extract file paths** from:
   - `File Impact Summary` (primary source)
   - `Technical Design` sections (supplemental)
   - `High-Level Approach` (supplemental mentions)
2. **Classify each path**:
   - **Exists**: File present in repo
   - **New**: Must be created
   - **Ambiguous**: Unclear reference

3. **Build verification table**:
   ```
   - src/auth/middleware.ts — Exists
   - src/auth/session.ts — New (to be created)
   - tests/auth/session.test.ts — New (test file)
   ```

### Phase 3: Task Decomposition

Generate tasks following these rules:

#### Plan → Task Mapping

- **Setup/Foundation phases**: Derive from `Prerequisites` and infra/config items in `High-Level Approach`
- **US1/US2/USn phases**: Map from spec user stories (when spec loaded) using priority order (P1, P2, P3)
- **File assignments**: Use `File Impact Summary` to assign `Primary Files` to each task
- **AC → task mapping**: Use `Acceptance Criteria Coverage` table to ensure every AC has at least one task
- **Rollback per task**: Derive from plan's `Rollback Strategy` section

#### Sizing Rules (from bd-breakdown)
- Each task completable within **140k tokens**
- Touch **2-3 primary files** per task
- If 4+ files, split into parent + children
- **Prefer fewer, larger tasks** over many small ones

#### Scope Atomicity
- **One outcome per task** — single verifiable "done" state
- **Don't mix modify + add** — separate issues for existing vs new code
- **Phase boundaries** — each execution phase is a separate task

#### Parallelization
- **File overlap = dependency** — tasks touching same file cannot parallelize
- **Err toward more dependencies** — safer than too few

#### Structure (Spec Kit inspired)
- **Phase 1**: Setup (project init, dependencies)
- **Phase 2**: Foundation (blocking prerequisites)
- **Phase 3+**: User Stories (in priority order P1, P2, P3...)
- **Final Phase**: Polish & cross-cutting

### Phase 4: Generate Task Specs

For each task, create a rich specification:

```markdown
### [T001] Title

**Type**: task | bug | feature | chore
**Priority**: P0 | P1 | P2 | P3
**Story**: [US1] | [US2] | (none for setup/foundation)
**Parallel**: [P] if parallelizable, blank if sequential
**Primary Files**: path1.ts, path2.ts
**Dependencies**: T000 (if any)

**Goal**:
What this task accomplishes (1-2 sentences)

**Context**:
- Why this matters
- Relevant background from plan/spec

**Scope**:
- In: what will be changed
- Out: explicit non-goals

**Changes**:
- `path/to/file.ts` — [Exists|New] — what to do
- `path/to/other.ts` — [Exists|New] — what to do

**Acceptance Criteria**:
- Observable outcome 1
- Observable outcome 2

**Verification**:
- How to verify this task is complete
- Test commands to run

**Rollback**:
- How to undo if needed

**Notes for Agent**:
- Edge cases, gotchas, constraints
```

### Phase 5: Output Generation

#### If `--beads` flag is set:

Use the **beads skill** to create issues. Follow bd-breakdown patterns:

##### Type & Priority Mapping

| Plan Context | Type | Priority |
|--------------|------|----------|
| New feature from spec | feature | P1-P2 (based on story priority) |
| Refactor/restructure | task | P2 |
| Bug fix from risks section | bug | P1 |
| Infrastructure/setup | task | P1 |
| Documentation/polish | chore | P3 |
| Spans 3+ files/large scope | epic | P1 |
| Cleanup/tech debt | chore | P3-P4 |

##### Issue Creation Flow

1. **De-duplicate first**: 
   - Check `bd list --status open` for existing related issues
   - Use `bd search "<keywords>"` to find potential overlaps
   - Use `bd list --title-contains "<phrase>"` for exact matches
   - **If existing issue matches**: Update its description with new context via `bd update <id> --description "..."` instead of creating duplicate
   - **If partial overlap**: Note relationship in description, ensure dependency exists

2. **Create epic** (if 3+ tasks):
   ```bash
   bd create "Epic: [Feature Name]" -p 1 --type epic --description "..."
   # Returns EPIC-ID
   ```

3. **Create tasks with --parent**:
   ```bash
   bd create "[T001] Task title" -p 2 --type task --parent EPIC-ID --description "..."
   # Returns TASK-ID
   ```

4. **Add dependencies** (file overlap or logical order):
   ```bash
   bd dep add <blocked-task> <blocker-task>
   ```

5. **Add labels**:
   ```bash
   bd label add <task-id> backend,auth
   ```

#### If no `--beads` flag (default):

Generate `TODO.md` in the same directory as the plan:

```markdown
# TODO: [Feature Name]

**Generated**: YYYY-MM-DD
**Plan**: [link to plan.md]
**Spec**: [link to spec.md if exists]

## Overview

[1-2 sentence summary from plan]

## Task Summary

| Phase | Tasks | Parallel | Dependencies |
|-------|-------|----------|--------------|
| Setup | 2 | 0 | — |
| Foundation | 3 | 2 | Setup |
| US1: [Name] | 5 | 3 | Foundation |
| Polish | 2 | 1 | US1 |

## Phase 1: Setup

- [ ] **T001** Create project structure per plan
  - Files: `src/`, `tests/`
  - Verify: Directory structure exists

- [ ] **T002** Install dependencies
  - Files: `package.json`
  - Verify: `npm install` succeeds

## Phase 2: Foundation

- [ ] **T003** [P] Implement base types
  - Files: `src/types/index.ts` (New)
  - Depends: T001
  - Verify: Types compile

[... continue for all phases ...]

## Dependencies Graph

```
T001 → T002 → T003
            ↘ T004 [P]
       T003 → T005
       T004 → T005
```

## Acceptance Criteria Coverage

| Spec AC | Covered By |
|---------|------------|
| AC1: User can login | T005, T006 |
| AC2: Session persists | T007 |

## Notes

- Total tasks: N
- Parallelizable: M
- Estimated phases: X
```

### Phase 6: Validation

Before finalizing, verify:

- [ ] **No file overlap without dependency** — scan Primary Files, ensure no two parallel tasks share files
- [ ] **AC coverage complete** — every spec AC maps to at least one task
- [ ] **Dependencies are complete** — when uncertain, add the dependency
- [ ] **Each task has one outcome** — no bundled multi-behavior tasks
- [ ] **Sizing is reasonable** — no task exceeds 140k token estimate

### Phase 7: Report

Output summary:

```
## Tasks Generated

**Output**: [TODO.md path] or [Beads epic ID]
**Total Tasks**: N
**Phases**: X
**Parallelizable**: M tasks can run concurrently

### Phase Breakdown
- Setup: 2 tasks
- Foundation: 3 tasks  
- US1 [P1]: 5 tasks
- Polish: 2 tasks

### Dependencies Added
- T003 → T005 (file overlap: src/auth/session.ts)
- T004 → T005 (logical: types needed first)

### AC Coverage
- 5/5 acceptance criteria mapped to tasks

### Ready to Execute
Run `/implement` to begin execution, or review TODO.md first.
```

## Quality Checks (from bd-breakdown)

Apply the **malicious compliance test** to all acceptance criteria:
1. Can this be satisfied while missing the point? → Rewrite
2. Does this focus on side effects instead of behavior? → Rewrite
3. Would a malicious-compliance agent pass this? → Add behavioral constraint

## Handling Edge Cases

### Plan Structure Issues
- **Plan has `[TBD]` markers**: Warn user, either abort or create "Clarify gaps" task first
- **Plan missing File Impact Summary**: Derive file paths from Technical Design + High-Level Approach; mark file targets as "approximate"
- **Plan missing AC Coverage table**: Derive acceptance criteria from Context & Goals and spec user stories; mark coverage as "derived"

### Missing Artifacts
- **No spec file**: Generate tasks from plan only, mark AC coverage as "N/A - no spec"
- **No data model/contracts**: Generate tasks from High-Level Approach + Technical Design only

### Output Issues
- **Beads not available**: Fall back to TODO.md with warning
- **`bd` command fails mid-run**: Stop immediately, report what was created, don't leave half-created epic graph
- **Existing TODO.md**: Ask whether to overwrite or append
- **Existing Beads epic for this feature**: Ask whether to add tasks to existing epic or create new one
