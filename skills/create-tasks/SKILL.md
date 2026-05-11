---
name: create-tasks
disable-model-invocation: true
description: Generate actionable tasks from a plan, outputting to Beads issues (--beads), Linear project issues (--linear), or TODO.md
argument-hint: '[--beads | --linear [project]] [--linear-team <team>] [--from-plan <path/to/plan.md>]'
---

## Host-Neutral Execution

Before running any Bash snippet in this skill, run the shared Cerberus resolver below. It lazily builds and executes `bin/cerberus` from the configured plugin root.

```bash
# --- shared resolver (canonical body; identical across all callers) ---
set +u
root="${CERBERUS_ROOT:-}"
[ -n "$root" ] || root="${CLAUDE_PLUGIN_ROOT}"
[ -n "$root" ] || root="${PLUGIN_ROOT:-}"
if [ -z "$root" ]; then
    skill_dir="${CLAUDE_SKILL_DIR}"
    if [ -n "$skill_dir" ]; then
        root="$(cd "$skill_dir/../.." && pwd)"
    fi
fi
bin="$root/bin/cerberus"
[ -n "$root" ] || { echo "cerberus: plugin root not set" >&2; exit 127; }
export CERBERUS_ROOT="$root"
claude_session="${CLAUDE_SESSION_ID}"
if [ "${CERBERUS_HOST:-}" = claude-code ]; then
    export CERBERUS_HOST=claude
fi
if [ -n "${CODEX_THREAD_ID:-}" ] && { [ -z "${CERBERUS_HOST:-}" ] || [ "${CERBERUS_HOST:-}" = codex ]; }; then
    export CERBERUS_HOST=codex CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$CODEX_THREAD_ID}"
elif [ -z "${CERBERUS_HOST:-}" ] && [ -n "$claude_session" ]; then
    export CERBERUS_HOST=claude CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$claude_session}"
fi
command -v make >/dev/null 2>&1 || { echo "cerberus: make not found on PATH; install make and retry." >&2; exit 127; }
if ! make -q -C "$root" build >/dev/null 2>&1; then
    command -v go >/dev/null 2>&1 || { echo "cerberus: Go >= 1.22 not found on PATH; install Go and retry." >&2; exit 127; }
    echo "cerberus: building... (this happens once after clone or upgrade)" >&2
    start=$(date +%s)
    make -C "$root" build >&2 || exit $?
    end=$(date +%s)
    echo "cerberus: build complete in $((end-start))s" >&2
fi
# --- shared resolver above; per-caller exec below (allowed to diverge) ---
exec "$bin" "$@"
```

Use `bin/cerberus` through the configured plugin root when invoking Cerberus commands below.


# Create Tasks (Plan → Execution Artifacts)

Convert a stable implementation plan into actionable, dependency-ordered tasks. Output to **Beads issues** (with `--beads` flag), **Linear issues in a project** (with `--linear`), or a **TODO.md** file (default).

> **Upstream**: This command accepts output from `/create-plan`.
> **Downstream**: Output is validated by `/review-tasks` for local/Beads artifacts, or by applying the same validation checks before creating Linear issues.

## Prompt Contract (GPT-5.5)

### Outcome

Generate a validated execution task graph from a stable plan and write it to the requested target (`TODO.md`, Beads, or Linear).

### What good means

- Completing every generated task fully implements the plan with no remaining plan work.
- Every plan objective, acceptance criterion, and MUST/SHALL/REQUIRED-style obligation has an owning task and verification.
- Each task is a compact engineering ticket: source links, outcome, scope/constraints, concrete changes, observable acceptance criteria, verification, dependencies, and any task-specific notes.
- Dependencies make parallel execution safe: tasks sharing files or logical prerequisites are ordered; unrelated tasks can run independently.
- Output-mode side effects are complete and verified: the file is written, Beads graph is ready, Linear project/issues are synced, or team-task file follows the parser contract.

### Constraints

- Treat repo guidance files and skills as constraints and shortcuts, not as reasons to expand the task graph beyond the plan.
- Use the sections below as the product contract and validation gates; do not narrate or mechanically follow a process when the outcome is already clear.
- Ask one narrow clarifying question only when ambiguity would change requirements, output destination, or a risky project/team/tooling decision.
- Keep generated task prompts outcome-focused. Do not repeat generic agent, repo, or tool rules in every task unless they materially affect that task.
- Preserve requirement wording from the plan/spec. Any task-level rewrite of enumerations, constants, thresholds, states, or acceptance criteria must be logged as an approved deviation.

### Verification

Before writing output, validate the task graph against the gates in this skill. Use the narrowest checks that prove the artifact is executable: coverage tables and dependency checks for all modes, `br ready` for Beads, and project/issue/dependency re-listing for Linear.

### Final response

Return the Phase 7 summary: output location or tracker target, task count, phase/dependency highlights, coverage status, and the next execution command or review step. Do not include hidden reasoning or intermediate drafts.

## The No-Stragglers Invariant

> **Completing ALL generated tasks MUST fully implement the plan.**
>
> This is the fundamental contract of task generation. When a user completes every task in the generated graph, the feature must be 100% complete—not 90%, not "mostly done", but FULLY DONE with no remaining work.
>
> Every objective, acceptance criterion, and MUST/SHALL obligation from the plan MUST have at least one owning task. If this invariant cannot be satisfied, task generation MUST fail.

## Mode Selection

| Flag | Output | Best For |
|------|--------|----------|
| (default) | `TODO.md` in plan directory | Quick projects, no issue tracker |
| `--beads` | Beads issues with dependencies | Multi-agent parallelization, tracked work |
| `--linear [project]` | Linear issues in an existing or newly confirmed Linear project | Teams coordinating work in Linear |

Output modes are mutually exclusive. If more than one of `--beads` or `--linear` is supplied, abort before generating output.

Linear mode details:
- `--linear` enables Linear output. With no project value, derive the project name from the plan title.
- `--linear <id|url|name>` targets a specific Linear project by ID, URL, or exact name. If a name has no exact match, ask whether to create a new project with that name instead of making the user rerun with a different flag.
- `--linear-team <key|id|name>` is optional and only disambiguates team selection. If supplied without `--linear`, abort before generating output.
- Ask one short clarifying question before creating anything when the project or team cannot be inferred unambiguously.

Linear examples:
- `/cerberus:create-tasks --linear` uses the plan title as the Linear project name.
- `/cerberus:create-tasks --linear "Plugin Port"` targets or, after confirmation, creates a project named `Plugin Port`.
- `/cerberus:create-tasks --linear "Plugin Port" --linear-team ENG` disambiguates the Linear team only when needed.

## Input

The user provides either:
- A **plan path** via `--from-plan path/to/plan.md`
- Or expects the most recent plan in `docs/` or `~/.claude/plans/`

## Workflow

Use the phases below to gather enough evidence, generate the graph, and validate it. They are generation constraints, not a transcript format: keep detailed reasoning internal and emit only the required artifacts, validation tables, and final summary.

### Phase 1: Load Plan Context

1. **Locate plan file**:
   - If `--from-plan` provided, use that path
   - Otherwise, find most recent `*-plan.md` in `docs/` or `~/.claude/plans/`
   - If no plan found, abort: "No plan found. Run /create-plan first."

2. **Load repo guidance (if present)**:
   - If repo guidance files such as `CLAUDE.md` or `AGENTS.md` exist, read only the parts needed for conventions that affect generated tasks (tests, commands, style, ownership)

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

### Phase 2b: Consistency Audit (Spec → Plan)

**Goal**: Prevent requirement drift between spec/legacy → plan → tasks.

1. **Build a Requirements Snapshot** from the plan (verbatim):
   - Objectives, Acceptance Criteria, MUST/SHALL obligations
   - Explicit Non-Goals and constraints

2. **Cross-check against spec/legacy** (if referenced):
   - If plan omits or rewrites any spec/legacy requirement, flag as **Deviation**
   - If any deviation is not explicitly acknowledged in the plan, **abort**
   - If a referenced spec/legacy artifact is missing, **abort** rather than inferring

3. **Create a Consistency Audit table** (required output):
   - Columns: Item | Spec/Legacy | Plan | Status | Notes

4. **Create a Deviation Log** (required output):
   - Each deviation must include: source, change, rationale, and explicit user approval status
   - If no deviations, output "None"

5. **Freeze requirements for task generation**:
   - Tasks MUST inherit plan requirements verbatim
   - Any task-level rewrite of enumerations/constants/thresholds/AC text is **forbidden** unless recorded in the Deviation Log

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
- Clarification/gate tasks (e.g., "Clarify file locations") count as Foundation phase.

**Example** (new module):
- T001 [integration-path-test] Skeleton + Integration: add `src/foo/service.ts` + DI registration (stubs) + failing end-to-end test via `create_app()`
- T002 Implement behavior A (unit tests + code)
  Dependencies: T002 → T001
- T003 Implement behavior B (unit tests + code) [parallel if files don't overlap]
  Dependencies: T003 → T001

#### Plan → Task Mapping

- **Setup/Foundation phases**: Derive from `Prerequisites` and infra/config items in `High-Level Approach`
- **System Wiring phase**: If any end-to-end flow or cross-layer data/config/template propagation is introduced, create at least one dedicated wiring task tagged `[system-wiring]`
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

**Avoid unnecessarily long dependency chains:**
- Prefer parallelism where possible—restructure or merge tasks to reduce sequential dependencies

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

**Dependency notation**: `T002 → T001` means "T002 depends on T001" (T001 must complete before T002 can start). This matches `br dep add T002 T001`.

- **File overlap = dependency** — tasks touching same file cannot parallelize
- **Central file contention**: If many tasks overlap a central file (e.g., `main.py`, `container.ts`), create a dedicated "shared foundation" task for that file, then parallelize downstream tasks that no longer touch it
- **Err toward more dependencies** — safer than too few
- Prefer restructuring (shared foundation task, re-slicing) over dropping uncertain deps

#### Execution Phases (in generated output)

These describe the structure of the *generated tasks*, not the workflow phases above:

- **Setup**: Project init, dependencies
- **Foundation**: Blocking prerequisites
- **System Wiring**: Dedicated wiring/integration tasks for end-to-end flows
- **User Stories**: In priority order (P1, P2, P3...)
- **Polish**: Cross-cutting cleanup

### Phase 4: Generate Task Specs

For each task, create a rich specification.

Each task should read like a compact engineering ticket for an implementation agent. Preserve the standard section names below for parser/review compatibility, but keep content task-specific and outcome-focused instead of restating generic agent process.

**Source Document Links (Hard Gate)**:

Every task MUST include a `**Source Documents**:` section. This is validated in Phase 5.

**Requirements**:
1. **Plan links**: At least one link to the plan with line numbers (e.g., `plan.md#L45-L67`). Include multiple links when a task spans Technical Design, File Impact Summary, Testing Strategy, etc.
2. **Spec links**: At least one link to the spec with line numbers if a spec exists. Use "Spec: N/A" only when **no spec exists per the Spec Exists Rule below**.
3. **Section labels**: Each link MUST include a label matching a heading/title found near that line range (e.g., "— Section: Authentication Flow").

**Line Number Accuracy (Anti-Guessing Rule)**:
- Line numbers MUST be derived by reading the actual file contents; never guess or approximate.
- If you cannot locate the relevant section, ask a clarifying question or abort task generation.
- The label after "—" must match text actually present in the referenced line range.

**Spec Exists Rule**: A spec exists if ANY of these are true:
- The plan explicitly references a spec path
- A `*-spec.md` file exists in the same directory as the plan
- A spec path was provided as input

**Why this matters**: These links enable agents executing tasks to quickly reference original requirements without searching. Accurate line numbers prevent "fake compliance" where links exist but don't point to relevant content.

```markdown
### [T001] Title

**Type**: task | bug | feature | chore
**Priority**: P0 | P1 | P2 | P3
**Story**: [US1] | [US2] | (none for setup/foundation)
**Parallel**: [P] if parallelizable, blank if sequential
**Primary Files**: path1.ts, path2.ts
**Subsystems**: auth, api (list all subsystems touched)
**Dependencies**: T000 (if any)

**Source Documents**:
- Plan: [plan-name.md#L45-L67](path/to/plan-name.md#L45-L67) — Section: Technical Design
- Plan: [plan-name.md#L120-L135](path/to/plan-name.md#L120-L135) — Section: File Impact Summary
- Spec: [spec-name.md#L12-L34](path/to/spec-name.md#L12-L34) — US1: User can login
- Spec: [spec-name.md#L50-L55](path/to/spec-name.md#L50-L55) — AC3: Session timeout
<!-- Use "Spec: N/A" if no spec exists per the Spec Exists Rule above -->

**Goal**:
The concrete outcome this task accomplishes (1-2 sentences)

**Context**:
- Why this matters for the plan
- Only the task-specific plan/spec background needed to execute safely

**Scope**:
- In: what will be changed
- Out: explicit non-goals and constraints

**Changes**:
- `path/to/file.ts` — [Exists|New] — what to do
- `path/to/other.ts` — [Exists|New] — what to do

**Wiring Map** (required when introducing new data/config/templates):
- `<origin> → <transport> → <consumption>` (one line per new field/config/template)
- Example: `idle_timeout config → OrchestratorConfig → AgentSessionConfig.idle_timeout → SessionRunner`

**Acceptance Criteria**:
- What good means for this task, expressed as observable outcomes
- Keep to the task's owned behavior; reference supporting ACs without claiming primary ownership

**Verification**:
- The narrowest commands/checks that prove this task is complete
- Test commands to run and the expected passing signal
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
- Completion response should summarize the outcome, files changed, verification commands/results, and any remaining risk or blocker
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

**Requirements Snapshot** (required):

```markdown
| Requirement Type | Source | Text (verbatim) |
|------------------|--------|----------------|
| Objective | Plan | ... |
| AC | Plan | ... |
| MUST/SHALL | Plan | ... |
```

**Consistency Audit** (required):

```markdown
| Item | Spec/Legacy | Plan | Status | Notes |
|------|-------------|------|--------|-------|
| AC #3: ... | ... | ... | Match/Deviation | ... |
```

**Deviation Log** (required):

```markdown
| Source | Deviation | Rationale | Approved? |
|--------|-----------|-----------|-----------|
| Spec AC #3 | ... | ... | Yes/No |
```

**Obligation Coverage** (required):

```markdown
| Plan Clause | Task(s) | Verification |
|------------|---------|--------------|
| "MUST ... " | T001 | Unit test X + integration test Y |
```

**System Wiring Coverage** (required when applicable):

```markdown
| Flow | Wiring Task(s) | Verification |
|------|----------------|--------------|
| config → DI → runtime | T002 [system-wiring] | Integration test |
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
| **Consistency audit** | Hard | Spec/legacy → plan matches, or deviations logged + approved | Add deviations or abort |
| **Requirement freeze** | Hard | Tasks mirror plan requirements verbatim (ACs/enums/constants/thresholds) | Rewrite tasks to match plan |
| **Dependencies complete** | Hard | When uncertain, add the dep | Add dependency |
| **One outcome per task** | Hard | No bundled multi-behavior tasks | Split task |
| **Sizing: standard** | Hard | No task over 12 files / 3 subsystems / 3 ACs | MUST split |
| **Sizing: mechanical** | Hard | Mechanical sweeps: max 18 files, must be 1 subsystem, grep-able pattern | Split by subsystem or convert to standard |
| **No vague tasks** | Hard | Every task has concrete files + verification steps | Rewrite or delete |
| **Startup vs runtime** | Hard | Config/boot-time semantics have separate startup/load-path verification | Add startup/load-path test |
| **Negative-case coverage** | Hard | Rejection/error/invalid inputs have explicit negative tests | Add negative tests |
| **Merge/precedence semantics** | Hard | Merge/override/precedence/defaults have explicit tests | Add tests |
| **End-to-end wiring** | Hard | New data/config/templates have wiring maps; tasks cover each hop | Add wiring map + missing tasks/deps |
| **System wiring coverage** | Hard | End-to-end flows include a `[system-wiring]` task | Add wiring task |
| **Adapter/bridge coverage** | Hard | Field changes mapped across all adapters/mappers/DI builders | Add/update adapter tasks |
| **Config override test** | Hard | New config values have override tests reaching runtime | Add override test |
| **Template lifecycle** | Hard | New templates are loaded, passed through, and used | Add missing lifecycle steps |
| **Missing referenced artifacts** | Hard | Plan-referenced docs/specs exist (or declared `New` with prereq task) | Abort or add prereq task |
| **Integration path test** | Hard | At least one task marked `[integration-path-test]` per feature | Add integration test task |
| **Source document links** | Hard | Every task has `**Source Documents**:` with valid plan link(s), spec link(s) if spec exists per Spec Exists Rule, line numbers in `#L<n>` or `#L<n>-L<m>` format, and labels matching text actually present in referenced range | Read files to get accurate line numbers; add labels matching section headings |
| **Sizing: target** | Advisory | Aim for 3-8 files, 1-2 subsystems | Consider splitting if outside range |

**Hard gates** block output. **Advisory** checks are recommendations.

**Validation loop**: Run checks → fix violations → re-run checks → repeat until all pass.

## Success Criteria

**Task generation succeeds when ALL of the following are true:**

1. **No-Stragglers Invariant**: Every plan objective, AC, and MUST/SHALL obligation has at least one owning task
2. **All Hard Gates Pass**: Zero violations in Phase 5 validation table
3. **Obligation Coverage Complete**: Obligation Coverage table shows 100% mapping with verification
4. **AC Coverage Complete**: Every spec AC (if spec present) maps to exactly one primary owner task
5. **Dependency Graph Valid**: No file overlaps without deps, no cycles
6. **Sizing Compliant**: All tasks within hard limits (12 files / 3 subsystems / 3 ACs)
7. **TDD Ordered**: Each feature has `[integration-path-test]` task, skeleton before implementation
8. **Wiring Complete**: New data/config/templates have wiring maps and coverage
9. **Consistency Audit Passes**: Spec/legacy → plan matches, or deviations logged + approved
10. **System Wiring Covered**: Each end-to-end flow has a `[system-wiring]` task

**Tasks may ONLY be output when all success criteria are met.**

### Phase 6: Output Generation

Only proceed here after Phase 5 validation passes.

#### If `--beads` flag is set:

Use the **beads skill** to create issues. Follow these patterns:

##### Type & Priority Mapping

**Important**: Use only `task` or `epic` types. Do NOT use `bug` or `chore`. Epics are purely organizational containers—if work needs to be done in an agent thread, it must be a `task`.

| Plan Context | Type | Priority |
|--------------|------|----------|
| New feature from spec | task | P1-P2 (based on story priority) |
| Refactor/restructure | task | P2 |
| Bug fix from risks section | task | P1 |
| Infrastructure/setup | task | P1 |
| Documentation/polish | task | P3 |
| Parent grouping (3+ child tasks) | epic | P1 |
| Cleanup/tech debt | task | P3-P4 |

##### Issue Creation Flow

1. **De-duplicate first**: 
   - Check `br list --status open` for existing related issues
   - Use `br search "<keywords>"` to find potential overlaps
   - Use `br list --title-contains "<phrase>"` for exact matches
   - **If existing issue matches**: Update its description with new context via `br update <id> --description "..."` instead of creating duplicate
   - **If partial overlap**: Note relationship in description, ensure dependency exists

2. **Create epic** (if 3+ tasks):
   ```bash
   br create "Epic: [Feature Name]" -p 1 --type epic --description "..."
   # Returns EPIC-ID
   ```

3. **Create tasks with --parent**:
   ```bash
   br create "[T001] Task title" -p 2 --type task --parent EPIC-ID --description "..."
   # Returns TASK-ID
   ```

4. **Add dependencies** (file overlap or logical order):
   ```bash
   br dep add <blocked-task> <blocker-task>
   ```
   
   **Important**: Tasks should NEVER depend on their parent epic. The `--parent` flag establishes the parent-child relationship. Dependencies should only be between sibling tasks (e.g., T002 depends on T001) for file overlap or logical ordering.

5. **Verify the task graph**:
   ```bash
   br ready
   ```

#### If `--linear` flag is set:

Use the available Linear integration (MCP tools, CLI, or API client configured in the environment) to create or update Linear issues. Do not create any Linear objects until Phase 5 validation passes and project/team resolution is complete.

##### Linear Project Resolution

1. **Authenticate/tooling gate**:
   - Verify Linear tooling is available and authenticated before creating anything.
   - If Linear tooling is unavailable, abort with a clear message unless the user explicitly requested TODO.md fallback in the same request.

2. **Resolve the project target**:
   - Let the project target be the value after `--linear`. If no value is supplied, or the next token is another flag, use the plan title as the desired Linear project name.
   - If the target is a Linear project ID or URL, resolve it directly. If it does not resolve, abort; do not reinterpret an invalid ID/URL as a new project name.
   - Otherwise, treat the target as a project name. Search active Linear projects for an exact unique match before creating anything.
   - If exactly one project matches, use it.
   - If multiple projects match, ask the user to choose by project URL/ID before creating issues.
   - If no project matches, plan to create a project with that name. Ask one short confirmation question after team resolution instead of requiring a different flag.

3. **Resolve the team**:
   - Linear issues require a team. Use `--linear-team <key|id|name>` when supplied.
   - When `--linear-team` is supplied for an existing project, verify that the team is compatible with the project before creating or updating issues. If it conflicts, abort rather than guessing.
   - For an existing project with exactly one associated team, use that team if `--linear-team` is omitted.
   - For a new project, use `--linear-team` if supplied. Otherwise, use the only available Linear team or an unambiguous workspace default if the tooling exposes one.
   - If the project spans multiple teams, or a new project needs a team that cannot be inferred, ask one short clarifying question before creating anything.

4. **Create the project only when needed**:
   - If an existing project was resolved, do not create another project.
   - If no project matched by name, create the new project only after resolving the team and confirming the project name with the user.
   - Do not ask the user to rerun with a separate "new project" flag; `--linear` covers both reuse and confirmed creation.

##### Linear Priority Mapping

| Task Priority | Linear Priority |
|---------------|-----------------|
| P0 | Urgent |
| P1 | High |
| P2 | Medium |
| P3 | Low |
| P4 | No priority |

##### Linear Issue Creation Flow

1. **De-duplicate within the target project first**:
   - List existing non-archived issues in the target Linear project, including open and recently closed issues.
   - Compute a stable Cerberus task marker for each generated task from the plan path, plan title, normalized task title without the `T###` prefix, primary files, and source document anchors. Do not include the generated sequence number alone in this marker.
   - Match existing issues by the Cerberus task marker in the issue description first. Treat `[T###]` in the title as display-only, not as identity.
   - If no marker exists on older issues, fall back to normalized title plus primary files only when the match is exact and unique.
   - If an exact task match exists, update its title, description, priority, labels, and project assignment instead of creating a duplicate.
   - If a partial overlap exists, note the relationship in the description and ask before merging or skipping the generated task.

2. **Create or update one Linear issue per generated task**:
   - Title format: `[T001] Task title`.
   - Project: resolved Linear project.
   - Team: resolved Linear team.
   - Priority: mapped from the generated task priority.
   - Labels: include `cerberus`; include phase/story labels when the Linear workspace already uses compatible labels.
   - Description: start with a visible `Cerberus Sync` block containing the plan path, task marker, generated task ID, and generated timestamp. Then include the full Phase 4 task spec, preserving Source Documents, Primary Files, Dependencies, Goal, Context, Scope, Changes, Acceptance Criteria, Verification, and Notes for Agent.

3. **Keep a task-to-issue map**:
   ```text
   T001 -> LIN-123
   T002 -> LIN-124
   ```
   Use this map for dependencies and the Phase 7 report.

4. **Add Linear dependency relations after all issues exist**:
   - For each task dependency `T002 → T001`, set the Linear relation so the `T001` issue blocks the `T002` issue.
   - Add dependency links to each issue description if the Linear tooling cannot create native blocking relations.
   - If native dependency creation fails partway through, backfill explicit dependency links into the descriptions for every missing relation before stopping. Report the run as partial/incomplete and list any relation that could not be represented.

5. **Verify the Linear project graph**:
   - Re-list the target project issues and confirm every generated task ID maps to exactly one Linear issue.
   - Confirm all generated dependencies are represented as Linear blocking relations or explicit dependency links in descriptions.
   - Confirm the project URL/ID, issue count, updated issue count, and created issue count for Phase 7.

#### If no output flag is set (default):

Generate `TODO.md` in the same directory as the plan.

Use `templates/tasks-template.md` if it exists; otherwise use the following fallback structure.

**TODO.md format**: Embed full task specs (from Phase 4) in collapsible `<details>` blocks under each checklist item, so agents have complete context without needing separate files.

Key sections to include:
- **Header**: Feature name, generated date, links to plan/spec
- **Task Summary table**: Phase, task count, parallel count, dependencies
- **Phase sections**: Setup → Foundation → US1/US2/USn → Polish
- **Per-task format**: `- [ ] **T00X** [P] [USn] Description` with Source Documents, Dependencies, Goal, Context, Scope, Changes, Acceptance Criteria, Verification, and Completion Response guidance
- **Dependencies Graph**: ASCII visualization of task ordering
- **AC Coverage table**: Map spec acceptance criteria to tasks
- **Validation Artifacts**: Sizing Summary, Requirements Snapshot, Consistency Audit, Deviation Log, Obligation Coverage, plus System Wiring Coverage and Propagation Map when applicable

### Phase 7: Report

Output summary:

```
## Tasks Generated

**Output**: [TODO.md path] or [Beads epic ID] or [Linear project URL/ID]
**Linear Issues**: Created X, updated Y (only for Linear output)
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
Run `/implement` to begin execution, review TODO.md first, or start from the Linear project backlog.
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
- **`br` command fails mid-run**: Stop immediately, report what was created, don't leave half-created epic graph
- **Linear tooling not available**: Abort with a clear message unless the user explicitly requested TODO.md fallback in the same request
- **Linear project target is ambiguous**: Ask the user to choose a project ID/URL before creating or updating issues
- **Linear project ID/URL is invalid**: Abort with a clear message and ask for a valid project ID/URL or a project name
- **Linear team is ambiguous or missing**: Ask the user for a team key, ID, or name before creating a project or issues
- **Linear issue creation fails mid-run**: Stop immediately, report the created/updated issue map, and do not attempt dependency relations for missing issues
- **Linear dependency creation fails mid-run**: Backfill dependency links into descriptions for every missing relation, then report the run as partial/incomplete
- **Existing TODO.md**: Ask whether to overwrite or append
- **Existing Beads epic for this feature**: Ask whether to add tasks to existing epic or create new one
- **Existing Linear project for this feature**: Use the exact matching project by default; ask only when multiple exact matches exist or the user explicitly asks for a distinct project name
