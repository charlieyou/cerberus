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
     - **Default**: Abort and recommend running `/create-plan` review gate
     - **Override** (only if user explicitly requests): Create a preliminary "Clarify design gaps" task before implementation tasks

4. **Extract artifact references** (do not load yet):
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

#### Plan → Task Mapping

- **Setup/Foundation phases**: Derive from `Prerequisites` and infra/config items in `High-Level Approach`
- **US1/US2/USn phases**: Map from spec user stories (when spec loaded) using priority order (P1, P2, P3)
- **File assignments**: Use `File Impact Summary` to assign `Primary Files` to each task
- **AC → task mapping**: Use `Acceptance Criteria Coverage` table to ensure every AC has exactly one primary owner task (supporting tasks may reference ACs but must not claim ownership)
- **Rollback per task**: Derive from plan's `Rollback Strategy` section

#### Sizing Rules

**Acceptable range**: 2-18 files, 5-55 edits per task.

**Too small** → consider merging (optional):
- < 2 files or < 5 edits
- Description under 10 lines
- Would take <10 minutes

**Too large** → MUST split along module/story/phase boundaries:
- 19+ files or 56+ edits
- 7+ acceptance criteria
- Contains "then", "after that", "finally" (multiple phases)
- Description has subsections or its own TOC
- Red flags: "central integration point", "ties everything together", "largest migration"

**Estimating files and edits:**
- Count files from `File Impact Summary` + Technical Design mentions
- ~1-2 files per component, ~1 file per test suite when ambiguous
- Edits: 3-5 per file for local changes, 6-10 for refactors or new files

**Prefer fewer, larger tasks** — batching small fixes beats many micro-tasks. Aim for 5-20 tasks per feature/epic.

#### Scope Atomicity
- **One outcome per task** — single verifiable "done" state
- **Don't mix modify + add** — separate new files from modifications, unless combined task stays within size bounds and describes a single outcome
- **Phase boundaries** — each execution phase is a separate task

#### Decomposition Anti-Patterns

**Avoid horizontal/layer-based splits:**
- ❌ Separate "Backend", "Frontend", "Tests" tasks for same feature
- ✅ Vertical slices: one task per user story or behavior, including all layers

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
2. 1-2 rollout tasks grouped by subsystem
3. Optional cleanup/flag-removal task

**Feature flags**: When flags are involved, create three tasks:
1. Add flag + guarded implementation
2. Rollout/monitor
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

**Integration Path Test** (per-feature, not per-task):
- At least one task per feature must include a test exercising the top-level construction path
- Examples: `main.py` → full app, `create_app()` factory, CLI entrypoint, DI container resolution
- Mark that task with `[integration-path-test]` so validation can verify coverage
- Other tasks may depend on this task or include it in final verification

**Rollback**:
- How to undo if needed

**Notes for Agent**:
- Edge cases, gotchas, constraints
```

### Phase 4b: Sizing Verification

After generating task specs, produce a **sizing summary table** and verify all tasks are within bounds:

```markdown
| Task | Files | Edits | Status | Action |
|------|-------|-------|--------|--------|
| T001 | 4 | 14 | OK | — |
| T002 | 16 | 45 | OK | — |
| T003 | 22 | 70 | Over | MUST split |
```

**Gating rule**: No tasks marked "Over" (19+ files or 56+ edits) may proceed. Split and re-estimate until all pass.

#### Worked Example

Plan proposes: "Implement full password reset flow (backend + email + UI)"

1. **Initial candidate**: T001 – Implement password reset flow
2. **Estimate**: 9 files, ~28 edits → Large but acceptable
3. **Check**: Can it be summarized without "and"? No: "backend AND email AND UI"
4. **Split by user-visible outcome**:
   - T001 – Backend endpoints + token model (5 files, ~15 edits) → OK
   - T002 – Email template + sending integration (3 files, ~8 edits) → OK  
   - T003 – UI pages + routing (4 files, ~12 edits) → OK
5. **Dependencies**: T002, T003 → T001 (backend must exist first)
6. **Re-check**: All tasks in 3-5 files, 8-15 edits — within standard range ✓

### Phase 5: Validation (Gating)

**This is a gate, not advisory.** If any check fails, you MUST adjust tasks (merge/split/add deps) and re-run the checklist before proceeding to output.

| Check | Gate | Rule | Fix |
|-------|------|------|-----|
| **File overlap** | Hard | No two parallel tasks share files | Add dependency |
| **AC coverage** | Hard | Every spec AC maps to exactly one primary task | Add task or reassign |
| **No orphan ACs** | Hard | No AC claimed by multiple tasks as primary | Reassign ownership |
| **Dependencies complete** | Hard | When uncertain, add the dep | Add dependency |
| **One outcome per task** | Hard | No bundled multi-behavior tasks | Split task |
| **Sizing: minimum** | Advisory | Task under 2 files / 5 edits | Consider merging |
| **Sizing: maximum** | Hard | No task over 18 files / 55 edits | MUST split |
| **No micro-tasks** | Advisory | Single-file fixes batched | Merge related fixes |
| **No vague tasks** | Hard | Every task has concrete files + ACs | Rewrite or delete |
| **End-to-end wiring** | Hard | New data/config/templates have wiring maps; tasks cover each hop | Add wiring map + missing tasks/deps |
| **Adapter/bridge coverage** | Hard | Field changes mapped across all adapters/mappers/DI builders | Add/update adapter tasks |
| **Config override test** | Hard | New config values have override tests reaching runtime | Add override test |
| **Template lifecycle** | Hard | New templates are loaded, passed through, and used | Add missing lifecycle steps |
| **Missing referenced artifacts** | Hard | Plan-referenced docs/specs exist (or declared `New` with prereq task) | Abort or add prereq task |
| **Integration path test** | Hard | At least one task marked `[integration-path-test]` per feature | Add integration test task |

**Hard gates** block output. **Advisory** checks are recommendations only.

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
- **No spec file** (not referenced): Generate tasks from plan only, mark AC coverage as "N/A - no spec"
- **No data model/contracts** (not referenced): Generate tasks from High-Level Approach + Technical Design only
- **Referenced artifact missing**: If the plan explicitly references a doc/spec/contract by path and it doesn't exist, **abort** with "Missing referenced artifact: `<path>`" — do not proceed with task creation until the artifact is provided or the plan is updated to remove the reference

### Output Issues
- **Beads not available**: Fall back to TODO.md with warning
- **`bd` command fails mid-run**: Stop immediately, report what was created, don't leave half-created epic graph
- **Existing TODO.md**: Ask whether to overwrite or append
- **Existing Beads epic for this feature**: Ask whether to add tasks to existing epic or create new one
