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

## Prompting Best Practices (Compliance)

Use clear, explicit instructions and structured outputs to reduce ambiguity and improve task quality. Follow these guidelines:
- Put critical constraints and gates near the top of relevant sections.
- Use consistent, labeled sections and compact tables for mappings and validation.
- Ask clarifying questions rather than guessing when plan details are ambiguous or missing.
- Separate **context** from **requirements** from **output format**.
- Be explicit about required output formats and include short, representative examples.
- Use clear headings and bullet lists; avoid unstructured paragraphs for requirements.
- Avoid contradicting instructions; if conflicts exist, call them out and resolve before generating tasks.
- Prefer precise, concrete language; avoid vague qualifiers like "maybe" or "as needed".
- Put instructions before context, and use clear delimiters (e.g., `###` or `"""`) to separate them.
- If you forbid something, say what to do instead (positive instruction over negative-only).
- Use checklists/tables for multi-step validation; avoid burying gates in prose.
- Treat `CLAUDE.md` (if present) as authoritative for repo-specific conventions and constraints.

### Phase 1: Load Plan Context

1. **Locate plan file**:
   - If `--from-plan` provided, use that path
   - Otherwise, find most recent `*-plan.md` in `docs/` or `~/.claude/plans/`
   - If no plan found, abort: "No plan found. Run /create-plan first."

2. **Load repo guidance (if present)**:
   - If `CLAUDE.md` exists, read it for repo conventions (tests, commands, style, ownership)

3. **Extract from plan**:
   - Context & Goals (feature summary)
   - Scope & Non-Goals (boundaries)
   - High-Level Approach (phases, technical approach)
   - Technical Design (architecture, data model, interfaces)
   - File Impact Summary (primary source of file paths)
   - Risks & Edge Cases
   - Testing & Validation Strategy
   - Acceptance Criteria Coverage table

4. **Plan completeness check**:
   - If plan contains `[TBD]` in Technical Design or Testing Strategy:
     - **Warn** the user that plan is incomplete
     - **Default**: Abort and recommend running `/create-plan` review gate
     - **Override** (only if user explicitly requests): Create a preliminary "Clarify design gaps" task before implementation tasks

5. **Extract artifact references** (do not load yet):
   - Note paths to referenced artifacts:
     - Spec file (for user stories, priorities, AC)
     - Data model (for entity tasks)
     - Contracts (for API tasks)
     - Any other docs referenced by path
   - These will be verified in Phase 2 before loading

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

4. **Missing referenced artifact gate**:
   - If the plan references any spec/doc/contract/data-model by path and it does not exist:
     - If listed as `New` in plan: Create a prerequisite "Author `<artifact>`" task; downstream tasks that need it must depend on this task; use plan-only decomposition until artifact exists
     - If not listed as `New`: **abort**: "Missing referenced artifact: `<path>`. Provide it or update the plan."
   - This prevents plans from diverging from implementation by ensuring all referenced design docs are available for review.

5. **Handle ambiguous paths**:
   - If any paths remain "Ambiguous", create a dedicated "Clarify file locations" task
   - All tasks depending on those files must block on the clarification task

6. **Load verified artifacts**:
   - Now load companion artifacts that passed verification (spec, data model, contracts)
   - Extract user stories, priorities, AC from spec
   - Extract entity definitions from data model
   - Extract API signatures from contracts

### Phase 3: Task Decomposition

Generate tasks following these rules:

#### Obligation Extraction & Coverage

**Goal**: Ensure all plan obligations are captured, owned by tasks, and verifiable.

1. **Extract obligations**: Identify all plan statements using MUST / SHALL / REQUIRED / PROHIBIT / FORBID / FAIL-FAST / DEPRECATED / BREAKING CHANGE.
2. **Map to tasks**: Every obligation must map to at least one task with explicit verification.
3. **Create an Obligation Coverage table** (plan clause → task + verification). This table is required output (see Phase 4b).

#### TDD Task Ordering

**Goal**: Produce tasks that enforce "red before green" and keep parallel work safe: (1) code compiles early, (2) end-to-end behavior is specified early via failing integration tests, (3) implementation tasks turn tests green with local unit tests.

**Definitions**:
- **Feature**: the user-visible capability being delivered (often 1 user story). If multiple user stories share one top-level execution path, treat them as one feature for integration-path coverage.
- **Integration-path test**: an integration test that traverses the composition root / DI / container wiring path.
- **Skeleton**: compile-ready stubs + wiring only (no real behavior).

**Per-Feature Steps** — follow in order for each feature/user story:

1. **Skeleton + Integration test task** (combined when creating new modules/classes)
   - Outcome: project builds/compiles AND at least one integration test fails for the intended reason (behavior unimplemented), not because of missing imports/wiring.
   - Skeleton work: define types/interfaces/signatures, exports, DI bindings, routes/handlers registration, and stub bodies. Stubs return empty/default or raise/throw `NotImplemented`.
   - Integration test work: write failing integration test(s) that exercise the end-to-end behavior.
   - Coverage: exactly one task per feature MUST include `[integration-path-test]` in the task title.
   - Path: the tagged test MUST traverse the composition root/DI/container path (entrypoint/factory/container resolution).
   - Note: Skeleton and integration test are combined because they're tightly coupled—you can't write the integration test without the skeleton, and a skeleton without tests provides no value.

2. **Implementation tasks** (parallel where possible)
   - Outcome: make the integration tests pass by implementing behavior with unit tests + production code in the same task.
   - Dependency: every implementation task depends on the skeleton+integration task.
   - Within-task TDD steps:
     a. Write failing unit test(s)
     b. Implement the smallest change to pass unit tests
     c. Confirm integration test(s) pass
   - Integration test stability: keep integration test files unchanged during implementation tasks. If integration tests must change, create a dedicated small task "Adjust integration tests" and add dependencies.
   - **Final implementation task verification**: The last implementation task in each feature must include verification that all tests pass (unit and integration). Do NOT create a separate "verify tests pass" or "run all tests" task—this verification must be part of the final implementation task's Verification section.

**Bugfix Variant**:
1. Create a failing regression test first (integration or unit).
2. Fix in an implementation task that includes unit tests + code changes (same task).
3. If the regression test is an integration-path test for that feature, tag it with `[integration-path-test]`.

**Dependency Rules**:
- Required order: Skeleton+Integration → Implementation.
- Chain-length constraint: keep dependency chains ≤ 4 tasks by splitting implementation into parallel tasks that touch different files.
- Clarification/gate tasks (e.g., "Clarify file locations") count as Foundation phase, not toward feature chain length.

**Example** (new module):
- T001 [integration-path-test] Skeleton + Integration: add `src/foo/service.ts` + DI registration (stubs) + failing end-to-end test via `create_app()`
- T002 Implement behavior A (unit tests + code)
  Dependencies: T002 → T001
- T003 Implement behavior B (unit tests + code) [parallel if files don't overlap]
  Dependencies: T003 → T001

#### Plan → Task Mapping

- **Setup/Foundation phases**: Derive from `Prerequisites` and infra/config items in `High-Level Approach`
- **US1/US2/USn phases**: Map from spec user stories (when spec loaded) using priority order (P1, P2, P3), applying TDD ordering within each story
- **File assignments**: Use `File Impact Summary` to assign `Primary Files` to each task
- **AC → task mapping**: Use `Acceptance Criteria Coverage` table to ensure every AC has exactly one primary owner task (supporting tasks may reference ACs but must not claim ownership)

#### Sizing Rules

Size tasks by **files touched** and **subsystems crossed** — these are the best observable proxies for context window consumption, the true limiting factor for LLM agents.

**Target range**: 3-8 files, 1-2 subsystems per task.

**Hard limits**:
- Maximum 12 files
- Maximum 3 subsystems
- Maximum 3 acceptance criteria

**Mechanical sweep exception** (same change across many files):
- Up to 18 files allowed
- Must stay within 1 subsystem
- Requires grep-able pattern + scripted verification
- Consider batching: POC in 2-3 files first, then rollout

**Split triggers** — if any are true, task is too big:
- Description contains "and then", "after that", "finally"
- More than 3 acceptance criteria
- Crosses 3+ subsystems (already at hard limit)
- Contains "figure out", "investigate", or "determine where"
- Red flags: "central integration point", "ties everything together"

**Prefer fewer, larger tasks** — batching small fixes beats many micro-tasks. Aim for 5-15 tasks per feature/epic.

**Defining subsystems**: A subsystem is a distinct functional area of the codebase with its own responsibilities. Count subsystems by identifying the top-level domains or modules touched:
- Examples: `auth`, `api`, `database`, `email`, `ui`, `config`, `cli`
- Heuristic: first directory under `src/` or top-level package name
- Wiring/DI files count toward the subsystem they configure, not as separate
- If unsure, ask: "Would a different team own this?" — if yes, it's a different subsystem

#### Scope Atomicity
- **One outcome per task** — single verifiable "done" state
- **Avoid mixing unrelated add + modify** — separate new files from modifications when they serve different outcomes. Exception: Skeleton tasks may add new module files AND update existing wiring/composition roots as a single "compile-ready wiring surface" outcome.
- **Phase boundaries** — each execution phase is a separate task

#### Decomposition Anti-Patterns

**Avoid long dependency chains:**
- Maximum chain length: 4 tasks
- If T001 → T002 → T003 → T004 → T005, merge or restructure to allow parallelism

**Avoid vague polish/cleanup tasks:**
- ❌ "Polish auth flow" with no concrete changes
- ✅ Specific improvements: "Add error messages for auth failures" with testable ACs

**Avoid overlapping AC ownership:**
- Each AC is the primary responsibility of exactly one task
- Supporting tasks may reference ACs but must not claim full ownership

**Cross-cutting changes** (same pattern across many files):
1. One design/POC task in a small slice
2. 1-2 implementation tasks grouped by subsystem
3. Optional cleanup/flag-removal task

**Feature flags**: When flags are involved, create three tasks:
1. Add flag + guarded implementation
2. Enable flag + verify
3. Flag removal/cleanup (optional, can be deferred)

#### Wiring & Propagation Rules

These rules prevent cross-layer gaps where changes are made in one layer but wiring in composition roots, adapters, or DI builders is never updated.

**Identifying wiring files**: Look for these patterns to find the "composition root" / wiring layer:
- Entry points: `main.py`, `main.ts`, `app.py`, `index.ts`, CLI entrypoints
- Factory functions: `create_app()`, `build_container()`, `configure_services()`
- DI/wiring modules: `*_wiring.py`, `container.ts`, `di.py`, `providers.ts`
- Adapter layers: `*_adapter.py`, files that import from multiple domains

**End-to-end wiring checkpoint**:
- For any new data, config, or templates, include a flow map: `Origin → transport → consumption`
- Ensure tasks cover each hop, including composition root / orchestration wiring / DI builders
- If any hop is unclear, create a blocking "wire the path" task
- Example: `config.yaml → OrchestratorConfig → AgentSessionConfig → SessionRunner`

**Adapter/bridge coverage**:
- When fields are added, renamed, removed, or semantically changed in shared objects/DTOs/config structs, tasks MUST update all adapters/mappers/constructors/DI builders that bridge layers
- **Enumerate all provider implementations**: If multiple implementations exist (e.g., `DomainPromptProvider` and `PipelinePromptProvider`), explicitly list how each handles the change:
  - Maps the field (task covers it)
  - Explicitly unsupported (raises error)
  - Deliberately ignored (with test proving this is intentional)
- List the mapping sites explicitly in `Changes` (e.g., "Update `orchestration_wiring.py` to map new prompt fields")
- This prevents "field exists but never wired" bugs

**Template lifecycle**:
- For new template/resource files, tasks MUST cover all three stages:
  1. **Load**: File exists and parser can read it
  2. **Pass through**: Wired into runtime (injected, passed to consumers)
  3. **Used**: Consumed in actual behavior (rendered, executed)
- Missing any stage becomes a dedicated task

#### Parallelization & Dependencies

**Dependency notation**: `T002 → T001` means "T002 depends on T001" (T001 must complete before T002 can start). This matches `bd dep add T002 T001`.

- **File overlap = dependency** — tasks touching same file cannot parallelize
- **Central file contention**: If many tasks overlap a central file (e.g., `main.py`, `container.ts`), create a dedicated "shared foundation" task for that file, then parallelize downstream tasks that no longer touch it
- **Err toward more dependencies** — safer than too few
- **Chain length limit (4)** is a heuristic; prefer restructuring (shared foundation task, re-slicing) over dropping uncertain deps

#### Execution Phases (in generated output)

These describe the structure of the *generated tasks*, not the workflow phases above:

- **Setup**: Project init, dependencies
- **Foundation**: Blocking prerequisites
- **User Stories**: In priority order (P1, P2, P3...)
- **Polish**: Cross-cutting cleanup

### Phase 4: Generate Task Specs

For each task, create a rich specification:

```markdown
### [T001] Title

**Type**: task | bug | feature | chore
**Priority**: P0 | P1 | P2 | P3
**Story**: [US1] | [US2] | (none for setup/foundation)
**Parallel**: [P] if parallelizable, blank if sequential
**Primary Files**: path1.ts, path2.ts
**Subsystems**: auth, api (list all subsystems touched)
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

**Wiring Map** (required when introducing new data/config/templates):
- `<origin> → <transport> → <consumption>` (one line per new field/config/template)
- Example: `idle_timeout config → OrchestratorConfig → AgentSessionConfig.idle_timeout → SessionRunner`

**Acceptance Criteria**:
- Observable outcome 1
- Observable outcome 2

**Verification**:
- How to verify this task is complete
- Test commands to run
- **Config override test** (required for new configurable values): At least one test proving a non-default override reaches runtime via the normal load/construction path (not by constructing config objects directly in the test)
- **Merge/precedence semantics** (if applicable): Explicit tests for merge/override/precedence/default behavior
- **Negative cases** (if applicable): At least one test covering rejection/error/invalid input behavior

**Integration Path Test** (per-feature, not per-task):
- At least one task per feature must include a test exercising the top-level construction path
- Examples: `main.py` → full app, `create_app()` factory, CLI entrypoint, DI container resolution
- Mark that task with `[integration-path-test]` so validation can verify coverage
- Other tasks may depend on this task or include it in final verification

**Notes for Agent**:
- Edge cases, gotchas, constraints
```

### Phase 4b: Sizing Verification

After generating task specs, produce a **sizing summary table** and verify all tasks are within bounds:

```markdown
| Task | Files | Subsystems | ACs | Mechanical? | Status | Action |
|------|-------|------------|-----|-------------|--------|--------|
| T001 | 4 | 1 | 2 | No | OK | — |
| T002 | 8 | 2 | 3 | No | OK | — |
| T003 | 14 | 4 | 2 | No | Over | MUST split (>12 files, >3 subsystems) |
| T004 | 16 | 1 | 1 | Yes | OK | Mechanical sweep allowed |
```

**Gating rule**: No tasks exceeding hard limits may proceed:
- Standard tasks: 12 files, 3 subsystems, 3 ACs
- Mechanical sweeps: 18 files, 1 subsystem, grep-able pattern required

Split and re-estimate until all pass.

### Phase 4c: Required Coverage Artifacts

Provide the following **required** artifacts after task specs:

**Obligation Coverage** (required):

```markdown
| Plan Clause | Task(s) | Verification |
|------------|---------|--------------|
| "MUST ... " | T001 | Unit test X + integration test Y |
```

**Propagation Map** (required for new/repurposed inputs/fields/signals):

```markdown
| Input/Field/Signal | Origin | Transport | Consumption | Verification |
|-------------------|--------|-----------|-------------|--------------|
| idle_timeout | config.yaml | OrchestratorConfig → AgentSessionConfig | SessionRunner | Integration test T001 |
```

#### Worked Example

Plan proposes: "Implement full password reset flow (backend + email + UI)"

1. **Initial candidate**: T001 – Implement password reset flow
2. **Estimate**: 9 files, 3 subsystems (backend, email, UI) → at subsystem limit
3. **Check**: Can it be summarized without "and"? No: "backend AND email AND UI"
4. **Split by subsystem**:
   - T001 – [integration-path-test] Skeleton + Integration: Backend endpoints + token model stubs + failing e2e test (5 files, 1 subsystem) → OK
   - T002 – Implement backend logic (unit tests + code) (3 files, 1 subsystem) → OK
   - T003 – Email template + sending (3 files, 1 subsystem) → OK  
   - T004 – UI pages + routing (4 files, 1 subsystem) → OK
5. **Dependencies**: T002, T003, T004 → T001 (skeleton+integration must exist first)
6. **Re-check**: All tasks 3-5 files, 1 subsystem — within limits ✓

### Phase 5: Validation (Gating)

**This is a gate, not advisory.** If any check fails, you MUST adjust tasks (merge/split/add deps) and re-run the checklist before proceeding to output.

| Check | Gate | Rule | Fix |
|-------|------|------|-----|
| **Obligation coverage** | Hard | All MUST/SHALL/REQUIRED/PROHIBIT/FORBID/FAIL-FAST/DEPRECATED/BREAKING CHANGE clauses mapped to tasks + verification | Add task(s) or update verification |
| **File overlap** | Hard | No two parallel tasks share files | Add dependency |
| **AC coverage** | Hard | Every spec AC maps to exactly one primary task (if spec present) | Add task or reassign |
| **No orphan ACs** | Hard | No AC claimed by multiple tasks as primary (if spec present) | Reassign ownership |
| **Dependencies complete** | Hard | When uncertain, add the dep | Add dependency |
| **One outcome per task** | Hard | No bundled multi-behavior tasks | Split task |
| **Sizing: standard** | Hard | No task over 12 files / 3 subsystems / 3 ACs | MUST split |
| **Sizing: mechanical** | Hard | Mechanical sweeps: max 18 files, must be 1 subsystem, grep-able pattern | Split by subsystem or convert to standard |
| **No vague tasks** | Hard | Every task has concrete files + verification steps | Rewrite or delete |
| **Startup vs runtime** | Hard | Config/boot-time semantics have separate startup/load-path verification | Add startup/load-path test |
| **Negative-case coverage** | Hard | Rejection/error/invalid inputs have explicit negative tests | Add negative tests |
| **Merge/precedence semantics** | Hard | Merge/override/precedence/defaults have explicit tests | Add tests |
| **End-to-end wiring** | Hard | New data/config/templates have wiring maps; tasks cover each hop | Add wiring map + missing tasks/deps |
| **Adapter/bridge coverage** | Hard | Field changes mapped across all adapters/mappers/DI builders | Add/update adapter tasks |
| **Config override test** | Hard | New config values have override tests reaching runtime | Add override test |
| **Template lifecycle** | Hard | New templates are loaded, passed through, and used | Add missing lifecycle steps |
| **Missing referenced artifacts** | Hard | Plan-referenced docs/specs exist (or declared `New` with prereq task) | Abort or add prereq task |
| **Integration path test** | Hard | At least one task marked `[integration-path-test]` per feature | Add integration test task |
| **Sizing: target** | Advisory | Aim for 3-8 files, 1-2 subsystems | Consider splitting if outside range |

**Hard gates** block output. **Advisory** checks are recommendations.

**Validation loop**: Run checks → fix violations → re-run checks → repeat until all pass.

### Phase 6: Output Generation

Only proceed here after Phase 5 validation passes.

#### If `--beads` flag is set:

Use the **beads skill** to create issues. Follow these patterns:

##### Type & Priority Mapping

| Plan Context | Type | Priority |
|--------------|------|----------|
| New feature from spec | feature | P1-P2 (based on story priority) |
| Refactor/restructure | task | P2 |
| Bug fix from risks section | bug | P1 |
| Infrastructure/setup | task | P1 |
| Documentation/polish | chore | P3 |
| Parent grouping (3+ child tasks) | epic | P1 |
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
   
   **Important**: Tasks should NEVER depend on their parent epic. The `--parent` flag establishes the parent-child relationship. Dependencies should only be between sibling tasks (e.g., T002 depends on T001) for file overlap or logical ordering.
   ```

5. **Verify the task graph**:
   ```bash
   bd ready
   ```

#### If no `--beads` flag (default):

Generate `TODO.md` in the same directory as the plan.

Use `templates/tasks-template.md` if it exists; otherwise use the following fallback structure.

**TODO.md format**: Embed full task specs (from Phase 4) in collapsible `<details>` blocks under each checklist item, so agents have complete context without needing separate files.

Key sections to include:
- **Header**: Feature name, generated date, links to plan/spec
- **Task Summary table**: Phase, task count, parallel count, dependencies
- **Phase sections**: Setup → Foundation → US1/US2/USn → Polish
- **Per-task format**: `- [ ] **T00X** [P] [USn] Description` with Files/Depends/Verify
- **Dependencies Graph**: ASCII visualization of task ordering
- **AC Coverage table**: Map spec acceptance criteria to tasks

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

## Quality Checks

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

Handled by Phase 2 "Missing referenced artifact gate". Summary:
- **Not referenced in plan**: Generate tasks from plan only (no abort). Mark AC coverage as "N/A - no spec" if spec not referenced.
- **Referenced and marked `New`**: Create prerequisite "Author `<artifact>`" task; downstream tasks depend on it.
- **Referenced but missing and NOT marked `New`**: Abort with "Missing referenced artifact: `<path>`".

### Output Issues
- **Beads not available**: Fall back to TODO.md with warning
- **`bd` command fails mid-run**: Stop immediately, report what was created, don't leave half-created epic graph
- **Existing TODO.md**: Ask whether to overwrite or append
- **Existing Beads epic for this feature**: Ask whether to add tasks to existing epic or create new one
