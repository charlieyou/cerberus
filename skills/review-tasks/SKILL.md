---
name: review-tasks
disable-model-invocation: true
description: Review generated tasks for completeness, correctness, and coherence before execution
argument-hint: '[--from-plan <path/to/plan.md>] [--beads]'
---

## Host-Neutral Execution

Before running any Bash snippet in this skill, source the shared Cerberus skill environment helper. This keeps the same skill usable from Claude, Codex, or a generic shell by resolving `CERBERUS_ROOT`, `CERBERUS_HOST`, and the active run key when the host exposes one.

```bash
cerberus_root=""
cerberus_plugin_root='${CLAUDE_PLUGIN_ROOT}'
case "$cerberus_plugin_root" in
    '$'{CLAUDE_PLUGIN_ROOT}) cerberus_plugin_root="${CLAUDE_PLUGIN_ROOT:-}" ;;
esac
cerberus_skill_dir='${CLAUDE_SKILL_DIR}'
case "$cerberus_skill_dir" in
    '$'{CLAUDE_SKILL_DIR}) cerberus_skill_dir="${CLAUDE_SKILL_DIR:-}" ;;
esac

cerberus_candidates=("${CERBERUS_ROOT:-}" "$cerberus_plugin_root")
if [ -n "$cerberus_skill_dir" ]; then
    cerberus_candidates+=("$(cd -P "$cerberus_skill_dir/../.." 2>/dev/null && pwd || true)")
fi
cerberus_git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$cerberus_git_root" ]; then
    cerberus_candidates+=("$cerberus_git_root")
fi
for cerberus_candidate in "${cerberus_candidates[@]}"; do
    if [ -n "$cerberus_candidate" ] \
        && [[ "$cerberus_candidate" == /* ]] \
        && [ -r "$cerberus_candidate/bin/cerberus-skill-env" ] \
        && [ -x "$cerberus_candidate/bin/review-gate" ] \
        && [ -r "$cerberus_candidate/bin/review-gate-models.sh" ] \
        && [ -r "$cerberus_candidate/config/gemini-readonly-settings.json" ] \
        && [ -r "$cerberus_candidate/config/gemini-readonly-policy.toml" ]; then
        cerberus_root="$cerberus_candidate"
        break
    fi
done
if [ -z "$cerberus_root" ]; then
    echo "cerberus skill: cannot find Cerberus backend; set CERBERUS_ROOT to the checkout root" >&2
    exit 127
fi
export CERBERUS_ROOT="$cerberus_root"
# shellcheck source=/dev/null
. "$cerberus_root/bin/cerberus-skill-env"
```

Use `${CERBERUS_ROOT}` when invoking Cerberus binaries below.


# Review Tasks (Task Graph Validation)

Validate that generated tasks form a coherent, complete, and executable work graph. Ensures the set of tasks will actually accomplish the plan's objectives with no gaps, no orphans, and clear completion criteria.

> **Upstream**: This command validates output from `/create-tasks`.

> ⚠️ **ITERATION REQUIRED**: This command does NOT stop after identifying issues. You MUST attempt safe fixes and re-run validation until verdict is PASS, max iterations are reached, or an unfixable plan-level blocker requires user input. See [Iteration Loop](#iteration-loop-mandatory) section.

## Prompt Contract (GPT-5.5)

### Outcome

Validate the generated task graph against its plan and, when the artifact is editable, apply the smallest safe fixes so the final graph is executable.

### What good means

- Closing every task fully implements the plan: every objective, acceptance criterion, phase, and MUST/SHALL/REQUIRED-style obligation is owned by at least one reachable task.
- The dependency graph is safe for parallel work: no cycles, no unreachable tasks, and no unordered file overlaps or missing logical prerequisites.
- Each task is completable by an implementation agent without extra clarification: source links, outcome, scope/constraints, concrete changes, acceptance criteria, verification, and dependencies are present and objective.
- Required create-tasks artifacts (coverage tables, sizing summary, propagation/wiring maps when applicable) are present and consistent with recomputed review state.
- The final report gives the last validated state only, including iterations used and any remaining blockers if PASS is impossible.

### Constraints

- Treat the validation dimensions below as the product contract, not a fixed script. Choose the smallest reads and recomputations that establish the verdict.
- Keep detailed reasoning internal. Do not print step-by-step analysis, fake subagent transcripts, or intermediate full reports.
- Do not expand scope beyond the plan. Preserve plan/spec wording unless an approved deviation is already documented.
- Ask one narrow question only when the task source, plan source, or a required fix would materially change requirements or create tracker-side risk.
- Do not stop at the first FAIL when blocking issues are safely fixable in the active task artifact. Fix, re-check the affected gates plus global coverage/dependencies, and report only the final iteration.

### Verification

Recompute the state needed for the gates: plan coverage, file-to-task mapping, dependency graph, task format/completability, sizing, TDD/wiring checks when applicable, and the No-Stragglers rollup. For Beads mode, run `br ready` after fixes when tooling is available.

### Final response

Return the Task Review Summary shape below with a PASS / FAIL / FAIL (MAX_ITERATIONS_REACHED) verdict, blocking issues, warnings, iterations used, and machine-readable JSON. Do not include hidden reasoning or earlier failed drafts.

### Large Graph Handling

For task graphs with more than 10 tasks, partition local checks by epic, parent, or phase so each pass stays focused. Global checks must still see summaries of **all** plan items, tasks, file mappings, dependencies, and parent relationships. The No-Stragglers gate is global and cannot be approximated from a sample.

### The Cardinal Rule: NO STRAGGLERS

> **Completing ALL tasks MUST result in completing the FULL and COMPLETE plan.**
>
> This is the single most important property of a valid task graph. If this property fails, the entire review fails. A user who completes every task must have a fully implemented feature—not 90%, not "mostly done", but COMPLETELY DONE.
>
> You MUST NOT pass a review where any plan objective, acceptance criterion, or MUST/SHALL obligation would remain unimplemented after all tasks complete.

## Success Criteria

**This review PASSES when ALL of the following are true:**

1. **Plan Coverage**: Every plan objective, AC, and MUST/SHALL obligation has at least one owning task, AND every task maps to at least one plan item (or is justified as infra/support)
2. **Dependency Correctness**: Dependency graph is acyclic and tasks sharing files have explicit dependencies
3. **Agent Completability**: Every task passes the completability checklist (clear goal, concrete verification, objective ACs)
4. **Task Format Compliance**: Every task includes required sections (Source Documents, Goal/outcome, Context, Scope/constraints, Changes, AC, Verification)
5. **Source Document Links**: Every task has plan links (+ spec links if spec exists) with line numbers pointing to relevant sections
6. **Sizing Compliance**: Every task within hard limits (12 files, 3 subsystems, 3 ACs)
7. **Graph Integrity**: Every task is reachable from `br ready` via dependency completions
8. **Consistency & Fidelity**: Consistency Audit + Deviation Log + Requirement Snapshot are present; tasks do not rewrite plan requirements
9. **No Followups on Close**: No task or epic is marked "needs-followup" or similar unresolved state

**Verdict is FAIL if ANY blocking gate has issues. Attempt safe fixes and re-run validation; stop only under the PASS, max-iterations, or unfixable-plan conditions in the Iteration Loop.**

---

## Review Goals

This review ensures nine critical properties of the task graph:

### 1. Plan Coverage (No Stragglers) — MOST CRITICAL

**Why this matters**: Prevents "done on paper" situations where the epic closes but key acceptance criteria are still unimplemented. Without this check, you can complete 100% of tasks and still have an incomplete feature.

Ensure that completing ALL tasks results in completion of the plan:

- Every plan objective maps to at least one task
- Every acceptance criterion has a primary owner task
- Every MUST/SHALL/REQUIRED obligation from the plan has an owning task with verification
- All phases from the plan have corresponding tasks
- Every task traces back to at least one plan item (no orphan work)
- Rollup check: if you close all tasks, is the feature done?

### 1b. Requirement Fidelity & Consistency (Spec/Legacy → Plan → Tasks)

**Why this matters**: Silent rewrites of requirements cause implementation drift even when all tasks are closed.

Verify that:
- **Consistency Audit** is present and compares spec/legacy → plan (if referenced)
- **Deviation Log** exists for any mismatch, with explicit approval status
- **Requirements Snapshot** includes objectives, AC, MUST/SHALL obligations 
- **Tasks do not rewrite requirements**: any change in list items, thresholds, counts, or states is a FAIL unless logged as an approved deviation
- **"needs-followup" is blocking**: tasks cannot be closed if marked with unresolved followups, TODOs, or similar placeholders

### 2. Dependency Correctness

**Why this matters**: Prevents parallel agents from conflicting on the same files and ensures prerequisites are built before dependents. Incorrect dependencies cause merge conflicts, broken builds, and wasted agent work.

Tasks must have correct dependency relationships:

**File Overlap Dependencies:**
- Ensure that tasks which can run in parallel only touch disjoint sets of files
- If two tasks share a file, add an explicit dependency (one direction)
- Scan each task's `Changes` section for file paths
- Build file→task mapping and flag overlaps without deps

**Logical Dependencies:**
- Types/interfaces defined before implementations using them
- Skeleton/stub tasks before implementation tasks  
- Setup/foundation before feature work
- Integration tests exist before implementation tasks that turn them green

### 3. Agent Completability

**Why this matters**: Ensures any agent can execute tasks without back-and-forth clarification, reducing stalls and misimplementations. Vague tasks lead to incorrect implementations that require rework.

Each task must be completable by an agent with no external clarification:

**Context Sufficiency:**
- Goal is clear and specific (describes the concrete outcome)
- All referenced files are listed in Changes section
- Relevant task-specific background from plan/spec is included without generic process filler
- Edge cases and constraints are documented

**Done Criteria:**
- Verification section has concrete commands or checks
- Acceptance criteria are observable and testable
- Agent knows exactly when to stop
- All acceptance criteria are objective (not "looks good", "feels right")

**Scope Clarity:**
- Single outcome per task (no "and then" / "after that")
- In-scope and out-of-scope are explicit
- Dependencies on other tasks/systems are documented

### 4. Task Format Compliance

**Why this matters**: Ensures tasks follow the standard template so agents can reliably find required information. Missing sections are a common source of incompletable tasks.

Each task must include required sections:

- [ ] **Source Documents**: Links to plan and spec with line numbers (e.g., `plan.md#L45-L67`). Multiple links when task spans multiple sections. "N/A" for spec if none exists.
- [ ] **Goal**: The concrete outcome this task accomplishes (1-2 sentences)
- [ ] **Context**: Why this matters and only the task-specific background needed to execute safely
- [ ] **Scope**: In/Out boundaries and constraints
- [ ] **Changes**: File paths with [Exists|New] and what to do
- [ ] **Acceptance Criteria**: Observable outcomes
- [ ] **Verification**: Narrowest concrete commands/checks and expected passing signal

Conditional sections (required when applicable):
- [ ] **Wiring Map**: Required when introducing new data/config/templates
- [ ] **Notes for Agent**: Required when there are edge cases or gotchas
- [ ] **Completion Response** guidance (or equivalent note): Required for newly generated task prompts so implementers know to report outcome, files changed, verification results, and risks/blockers

**Source Document Links Validation**:
- Every task MUST have `**Source Documents**:` section
- Each link MUST include line numbers in format `#L<start>` or `#L<start>-L<end>`
- Each link MUST include a label after "—" that matches a heading/title in the referenced range
- Plan: At least one plan link required for every task
- Spec: At least one spec link required IF spec exists (see Spec Exists Rule below); otherwise "Spec: N/A"
- Tasks spanning multiple sections MUST list each link separately (no cramming unrelated ranges)

**Spec Exists Rule**: A spec exists if ANY of these are true:
- The plan explicitly references a spec path
- A `*-spec.md` file exists in the same directory as the plan
- A spec path was provided as input

**Line Number Validity Check**:
- Verify referenced files exist
- Verify line ranges are within file bounds
- Verify labels match text actually present in the referenced range (heading/title/AC sentence); do not accept invented labels
- Line numbers MUST be derived by reading the actual file contents; never guess or approximate
- If the referenced range doesn't contain the claimed label/section, it's BLOCKING

### 5. Sizing Compliance

**Why this matters**: Tasks exceeding size limits overwhelm agent context windows, leading to incomplete or incorrect implementations.

Verify all tasks are within bounds:

| Limit | Standard Task | Mechanical Sweep |
|-------|---------------|------------------|
| Files | ≤ 12 | ≤ 18 |
| Subsystems | ≤ 3 | = 1 |
| Acceptance Criteria | ≤ 3 | ≤ 3 |

Mechanical sweeps additionally require:
- Grep-able pattern for verification
- All changes within single subsystem

### 6. Graph Integrity

**Why this matters**: Guarantees there are no dead or unreachable tasks and that work can actually flow from `br ready` to "plan complete". Orphan tasks waste effort; unreachable tasks never get done.

The task graph must be well-formed:

- Every task traces to at least one plan objective or is justified as infra/support
- Dependency graph is acyclic (no circular dependencies)
- Every task is reachable from `br ready` via some sequence of dependency completions
- Parent-child relationships match epic structure
- Each piece of work appears in exactly one task (no duplicates)

### 7. TDD Compliance (if applicable)

**Why this matters**: Enforces "red before green" and ensures tests accurately guard the intended behavior.

If using TDD ordering (per create-tasks):

- Each feature has exactly one `[integration-path-test]` task
- Implementation tasks depend on their skeleton+integration task
- Integration test files remain stable during implementation (or explicit "Adjust integration tests" task exists)
- Final implementation task includes verification that all tests pass

### 8. Wiring & Config Verification

**Why this matters**: Prevents cross-layer gaps where changes are made in one layer but wiring in composition roots, adapters, or DI builders is never updated.

For tasks introducing new config/data/templates:

- Verify Verification section includes a config override test reaching runtime
- Verify wiring maps are present showing `origin → transport → consumption`
- Verify there is at least one verification covering each hop in the wiring map
- For cross-layer field changes, verify tasks cover all adapters/mappers/DI builders

---

## Upstream Artifacts

When `create-tasks` was used to generate the tasks, it produces specific artifacts that this review should consume:

| Artifact | Location | How to Use |
|----------|----------|------------|
| **Obligation Coverage table** | In TODO.md or task descriptions | Cross-check against recomputed coverage; flag discrepancies |
| **Propagation Map** | In TODO.md or task descriptions | Use to verify wiring/adapter coverage checks |
| **Sizing Summary table** | In TODO.md | Compare against recomputed sizing; flag drift |
| **AC Coverage table** | In TODO.md | Verify AC→task mappings match |

If these artifacts exist, load them and verify consistency with recomputed state. Mismatches between artifacts and actual tasks indicate manual edits that may have introduced gaps.

---

## Workflow

### Phase 1: Load Tasks

**State to build**: `plan_items`, `tasks`

1. **Determine task source**:
   - If `--beads` flag: Load from beads (`br list --status open`)
   - Otherwise: Load from `TODO.md` in plan directory

2. **Load the plan** (required for coverage check):
   - If `--from-plan` provided, use that path
   - Otherwise, find most recent plan in `docs/` or `~/.claude/plans/`
   - Extract: objectives, acceptance criteria, phases, file impact summary, MUST/SHALL obligations

3. **Build task inventory**:
   ```
   tasks = [
     {
       id: "T001",
       title: "...",
       description: "...",
       files: ["src/auth/session.ts", ...],
       dependencies: ["T000"],
       parent: "EPIC-001",
       acceptance_criteria: ["AC1", "AC2"],
       has_goal: true,
       has_context: true,
       has_verification: true,
       ...
     },
     ...
   ]
   ```

### Phase 2: Plan Coverage Analysis

**State to update**: `coverage_map`, `issues`

**Goal**: Verify that completing all tasks completes the plan—no stragglers.

1. **Extract plan obligations**:
   ```
   plan_items = [
     { type: "objective", text: "User can reset password", source: "Context & Goals" },
     { type: "ac", text: "AC1: Email sent within 5 seconds", source: "AC Coverage" },
     { type: "phase", text: "Phase 2: Email integration", source: "High-Level Approach" },
     { type: "obligation", text: "MUST rate-limit to 3 requests/minute", source: "Technical Design" },
     ...
   ]
   ```

2. **Map each plan item to tasks**:
   ```
   | Plan Item | Type | Owning Task(s) | Status |
   |-----------|------|----------------|--------|
   | "User can reset password" | objective | T003, T004 | ✓ Covered |
   | "Email sent within 5 seconds" | ac | T005 | ✓ Covered |
   | "Phase 2: Email integration" | phase | T004, T005 | ✓ Covered |
   | "MUST rate-limit to 3/min" | obligation | ??? | ⚠ MISSING |
   ```

3. **Check for orphan tasks** (tasks with no plan mapping):
   - For each task, verify it maps to at least one plan item
   - Infra/setup tasks may be justified—flag but don't auto-fail

4. **Flag coverage gaps**:
   - Plan items with no owning task → **BLOCKING**
   - Tasks with no plan mapping → **WARNING** (unless justified)
   - Acceptance criteria claimed by multiple tasks as primary → **BLOCKING**

5. **Rollup verification**:
   - Mentally simulate: "If I close T001, T002, T003... is the plan done?"
   - Flag any remaining plan work not captured

### Phase 3: Dependency Analysis

**State to update**: `file_task_map`, `dependency_graph`, `issues`

**Goal**: Verify dependency correctness—file overlaps and logical ordering.

1. **Build file→task mapping**:
   ```
   file_task_map = {
     "src/auth/session.ts": ["T001", "T003"],
     "src/auth/middleware.ts": ["T002"],
     "src/api/routes.ts": ["T001", "T002", "T004"]
   }
   ```

2. **Flag file overlaps without dependencies**:
   - For each file with multiple tasks, check if dependency exists (either direction)
   - Missing dependency → **BLOCKING**
   ```
   Issue: T001 and T003 both touch src/auth/session.ts but have no dependency
   Fix: br dep add T003 T001
   ```

3. **Verify logical dependencies**:
   - Types/interfaces defined before use
   - Skeleton tasks before implementation
   - Integration test tasks before "turn tests green" tasks

4. **Detect cycles**:
   - Run cycle detection on dependency graph
   - Circular dependency → **BLOCKING**

### Phase 4: Agent Completability Check

**State to update**: `issues`

**Goal**: Each task can be completed without external clarification.

For each task, evaluate:

**4a. Context Sufficiency Checklist:**
- [ ] Goal describes specific single outcome
- [ ] All files in Changes section exist or marked [New]
- [ ] Background context from plan included (no "see above" / "as discussed")
- [ ] Edge cases documented

**4b. Done Criteria Checklist:**
- [ ] Verification has concrete commands (not just "verify it works")
- [ ] Each AC is testable by the agent
- [ ] Success state is unambiguous
- [ ] All ACs are objective and measurable

**4c. Scope Atomicity Checklist:**
- [ ] Single outcome (task can be summarized without "and")
- [ ] In-scope items are explicit
- [ ] Out-of-scope items are explicit
- [ ] Dependencies on other tasks/systems documented

**Flag problematic tasks:**
```
T003: INCOMPLETE — 3 issues
  - [BLOCKING] Missing verification commands
  - [BLOCKING] AC "looks good" is subjective → rewrite as measurable outcome
  - [WARNING] References "the discussion" without context
```

### Phase 5: Format & Sizing Compliance

**State to update**: `issues`

**5a. Task Format Compliance:**

For each task, verify required sections present:
```
| Task | Goal | Context | Scope | Changes | AC | Verification | Status |
|------|------|---------|-------|---------|-------|--------------|--------|
| T001 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | OK |
| T002 | ✓ | ✗ | ✓ | ✓ | ✓ | ✗ | FAIL |
```

Missing required section → **BLOCKING**

**5b. Sizing Compliance:**

Build sizing summary table:
```
| Task | Files | Subsystems | ACs | Mechanical? | Status | Action |
|------|-------|------------|-----|-------------|--------|--------|
| T001 | 4 | 1 | 2 | No | OK | — |
| T002 | 8 | 2 | 3 | No | OK | — |
| T003 | 14 | 4 | 2 | No | OVER | MUST split (>12 files, >3 subsystems) |
| T004 | 16 | 1 | 1 | Yes | OK | Mechanical sweep allowed |
```

Exceeds hard limits → **BLOCKING**

### Phase 6: Graph Integrity & TDD Check

**State to update**: `issues`

**6a. Graph Integrity:**

1. **Orphan detection**: Tasks with no parent AND no plan mapping
2. **Reachability check**: From `br ready`, trace which tasks can eventually be reached
3. **Duplicate detection**: Tasks with similar titles/files/changes
4. **Epic consistency**: Child tasks have parent relationship, epic completion = all children complete

**6b. TDD Compliance (if applicable):**

1. **Integration test coverage**: Each feature has `[integration-path-test]` task
2. **Ordering**: Skeleton+integration before implementation
3. **Test stability**: Integration test files stable during implementation

**6c. Wiring & Config:**

For tasks with new config/data/templates:
- Verify config override test in Verification section
- Verify wiring map present
- Verify coverage of each wiring hop

---

## Output

### Summary Report Format

```markdown
## Task Review Summary

**Source**: [TODO.md path] or [Beads]
**Plan**: [plan.md path]
**Total Tasks**: N

### 1. Plan Coverage
- Objectives: X/Y covered
- Acceptance criteria: A/B covered  
- MUST/SHALL obligations: M/N covered
- Orphan tasks (no plan mapping): [list or "none"]
- **Status**: PASS / FAIL

### 2. Dependency Correctness
- File overlap violations: N
- Missing logical deps: N
- Long chains (advisory): [list or "none"]
- Circular dependencies: [list or "none"]
- **Status**: PASS / FAIL

### 3. Agent Completability
- Tasks missing context: [list or "none"]
- Tasks with vague verification: [list or "none"]
- Tasks with subjective ACs: [list or "none"]
- **Status**: PASS / FAIL

### 4. Task Format Compliance
- Tasks missing required sections: [list or "none"]
- **Status**: PASS / FAIL

### 5. Sizing Compliance
- Tasks exceeding limits: [list or "none"]
- **Status**: PASS / FAIL

### 6. Graph Integrity
- Orphan tasks: [list or "none"]
- Unreachable tasks: [list or "none"]
- Potential duplicates: [list or "none"]
- **Status**: PASS / FAIL

### 7. TDD Compliance
- Features missing integration tests: [list or "N/A"]
- Ordering violations: [list or "none"]
- **Status**: PASS / N/A

### 8. Wiring & Config
- Tasks missing config override tests: [list or "N/A"]
- Tasks missing wiring maps: [list or "N/A"]
- **Status**: PASS / N/A

---

## Verdict: PASS / FAIL / FAIL (MAX_ITERATIONS_REACHED)

### Blocking Issues (must fix)
1. [Issue description + fix]
2. ...

### Warnings (should fix)
1. [Issue description + fix]
2. ...

### Iteration Notes
- **Iterations used**: N
- **Fixes applied**: [summary of fixes by category]

### Machine-Readable Verdict (JSON)

```json
{
  "verdict": "PASS",
  "iterations_used": 2,
  "blocking_issue_count": 0,
  "warning_count": 1,
  "total_tasks": 12
}
```
```

### Detailed Findings Format

For each issue found:

```markdown
#### Issue: [Category] - [Brief Description]

**Severity**: BLOCKING / WARNING
**Tasks Affected**: T001, T003
**Problem**: [What's wrong]
**Why it matters**: [Impact if not fixed]
**Fix**: [How to fix it]

Example fix (if beads):
```bash
br dep add T003 T001  # T001 must complete before T003
```
```

---

## Worked Examples

### Example: PASS Report

```markdown
## Task Review Summary

**Source**: Beads (cerberus epic)
**Plan**: docs/password-reset-plan.md
**Total Tasks**: 5

### 1. Plan Coverage
- Objectives: 2/2 covered
- Acceptance criteria: 4/4 covered
- MUST/SHALL obligations: 3/3 covered
- Orphan tasks: none
- **Status**: PASS

### 2. Dependency Correctness
- File overlap violations: 0
- Missing logical deps: 0
- Long chains (advisory): none
- Circular dependencies: none
- **Status**: PASS

[... all other sections PASS ...]

## Verdict: PASS

### Blocking Issues
None

### Warnings
1. T003 and T004 could potentially run in parallel if split by subsystem
```

### Example: FAIL → PASS (Iterative Self-Healing)

This example shows the **final output** after internal iteration. Intermediate iterations are not printed.

```markdown
## Task Review Summary

**Source**: Beads (oauth epic)
**Plan**: docs/oauth-plan.md
**Total Tasks**: 10

### 1. Plan Coverage
- Objectives: 3/3 covered
- Acceptance criteria: 7/7 covered
- MUST/SHALL obligations: 4/4 covered
- Orphan tasks: none
- **Status**: PASS

### 2. Dependency Correctness
- File overlap violations: 0
- Missing logical deps: 0
- Long chains: none
- Circular dependencies: none
- **Status**: PASS

[... all other sections PASS ...]

## Verdict: PASS

### Blocking Issues
None

### Warnings
1. Consider parallelizing T003/T004 if split by subsystem

### Iteration Notes
- **Iterations used**: 3
- **Fixes applied**:
  - Iteration 1: Created T008 for missing "revoke tokens" objective, created T009 for missing "refresh token expiry" AC
  - Iteration 2: Added dependency `br dep add T005 T002` (file overlap), split T003 into T003a + T003b (sizing)
  - Iteration 3: Consolidated T004 ACs from 5 → 3
```

### Example: FAIL After Max Iterations

```markdown
## Task Review Summary

**Source**: TODO.md
**Plan**: docs/oauth-plan.md
**Total Tasks**: 8

[... sections with issues ...]

## Verdict: FAIL (MAX_ITERATIONS_REACHED)

### Remaining Blocking Issues
1. **Circular dependency**: T007 ↔ T008 — cannot resolve without changing task boundaries

### Warnings
1. **Long chain**: T001→T002→T003→T004→T005→T006 (6 tasks) — consider restructuring for parallelism

### Iteration Notes
- **Iterations used**: 5 (max)
- **Fixes applied**: 12 issues resolved across 5 iterations
- **Escalation needed**: Remaining issues require plan-level changes
```

---

## Validation Gates

| Check | Severity | Pass Condition | Fix |
|-------|----------|----------------|-----|
| **No-Stragglers Invariant** | BLOCKING | Completing all tasks = plan fully complete; no remaining work | Add missing tasks for uncovered plan items |
| **Plan coverage** | BLOCKING | Every objective/AC/obligation has owning task(s) | Add missing tasks |
| **Task mapping** | BLOCKING | Every task maps to plan item or justified as infra | Remove orphan tasks or add justification |
| **AC ownership** | BLOCKING | Each AC has exactly one primary owner task | Reassign ownership |
| **File overlap deps** | BLOCKING | Tasks sharing files have explicit dependency | Add dependency |
| **Circular deps** | BLOCKING | Dependency graph is acyclic | Restructure dependencies |
| **Context sufficiency** | BLOCKING | Every task has clear goal + concrete `Changes` entries | Expand task description |
| **Done criteria** | BLOCKING | Every task has concrete verification commands | Add verification |
| **Objective ACs** | BLOCKING | All ACs are measurable and testable | Rewrite subjective ACs |
| **Task format** | BLOCKING | All required sections present | Add missing sections |
| **Source document links** | BLOCKING | Every task has `**Source Documents**:` with valid plan link(s), spec link(s) if spec exists per Spec Exists Rule, line numbers in `#L<n>` or `#L<n>-L<m>` format, and labels matching text actually present in referenced range | Add/fix links per Spec Exists Rule and Line Number Validity Check |
| **Sizing: standard** | BLOCKING | Tasks ≤ 12 files, ≤ 3 subsystems, ≤ 3 ACs | Split task |
| **Sizing: mechanical** | BLOCKING | Mechanical sweeps: ≤ 18 files, = 1 subsystem, grep-able | Split or reclassify |
| **Reachability** | BLOCKING | Every task reachable from `br ready` | Fix blocking dependencies |
| **Integration path tests** | BLOCKING when applicable | Each feature in a create-tasks/TDD graph has one `[integration-path-test]` task | Add integration path test task |
| **Config override tests** | BLOCKING when applicable | New configurable values have override tests reaching runtime via the normal load/construction path | Add override test |
| **Wiring maps** | BLOCKING when applicable | New data/config/templates or cross-layer propagation have wiring maps and tasks covering each hop | Add wiring map, missing task, or dependency |
| **Adapter/bridge coverage** | BLOCKING when applicable | Field/DTO/config changes are mapped across all adapters, mappers, constructors, and DI builders | Add adapter/bridge task coverage |
| **Template lifecycle** | BLOCKING when applicable | New templates/resources are loaded, passed through, and used by runtime behavior | Add missing lifecycle coverage |
| **Merge/precedence semantics** | BLOCKING when applicable | Merge, override, precedence, and default behavior have explicit verification | Add merge/precedence tests |
| **Negative cases** | BLOCKING when applicable | Rejection, error, and invalid-input behavior has explicit verification | Add negative-case tests |
| **Duplicates** | WARNING | Each piece of work in exactly one task | Merge tasks |

---

## Post-Review Actions

**After review PASSES:**
- Tasks are ready for execution via `/implement` or manual work
- Run `br ready` to see which tasks can start immediately

**After review FAILS:**
- Attempt safe fixes for all BLOCKING issues immediately when they are within the active task artifact or tracker
- Re-run validation to verify fixes
- Continue iterating until PASS, max iterations, or an unfixable plan-level issue
- See **Iteration Loop** section below for fix actions

**Common fix commands (if using beads):**
```bash
# Add missing dependency
br dep add <blocked-task> <blocker-task>

# Update task description
br update <task-id> --description "..."

# Add missing task
br create "Task title" -p 1 --parent <epic-id> --description "..."

# View task for editing
br show <task-id>
```

---

## Iteration Loop (Mandatory)

The user needs a ready task graph, not a problem list. When a blocking issue is safely fixable in the active task artifact or tracker, apply the smallest safe fix, update review state, and re-check the affected gate plus global No-Stragglers/dependency checks. Do not ask the user to re-run `/review-tasks`.

Stop only when one of these is true:
1. **PASS** — all blocking gates are satisfied.
2. **FAIL (MAX_ITERATIONS_REACHED)** — five fix/recheck iterations were attempted and blockers remain.
3. **Unfixable plan-level issue** — fixing would change requirements, scope, or an external tracker decision that needs user approval.

### Fix Actions by Issue Type

When you encounter blocking issues, apply fixes to the artifact/tracker when safe, mirror them in review state, then re-validate the relevant gates:

| Issue Type | Fix Action |
|------------|------------|
| **Sizing: files > 12** | Split task into 2+ tasks by subsystem; update `tasks` list and `dependency_graph` |
| **Sizing: subsystems > 3** | Split task by subsystem boundary; each new task ≤ 2 subsystems |
| **Sizing: ACs > 3** | Consolidate ACs into 3 by grouping related behaviors; or split task |
| **Long chain (advisory)** | Consider restructuring to allow parallelism; split middle tasks if beneficial |
| **File overlap without dep** | Add dependency to `dependency_graph` |
| **Circular dependency** | Remove one edge; restructure task boundaries if needed |
| **Missing plan coverage** | Add new task to `tasks` list for uncovered objective/AC/obligation |
| **Orphan task** | Add plan mapping justification or remove from `tasks` |
| **Missing verification** | Update task in `tasks` with concrete verification commands |
| **Subjective AC** | Rewrite AC in task with measurable, testable criteria |
| **Missing required section** | Update task in `tasks` with the missing section |
| **Missing/invalid source document links** | Add `**Source Documents**:` section; each link must have `#L<n>` line numbers and a label matching content at those lines; include spec links if spec exists per Spec Exists Rule, else "Spec: N/A" |

### Applying Fixes

**Beads mode**: execute `br` fixes when tooling is available, then refresh task/dependency state. Include applied commands in `### Iteration Notes`.

```bash
br dep add <blocked> <blocker>
br update <task-id> --description "..."
br create "Task for uncovered AC" -p 1 --parent <epic> --description "..."
```

**TODO.md/team-task mode**: edit the file directly by splitting/narrowing tasks, updating dependencies, consolidating or rewriting ACs, adding missing sections, or inserting missing tasks. For team-task files, update both the parser-owned `meta` block's `depends: [...]` field and the human-readable `### Dependencies` section.

**Plan-only or unfixable cases**: do not invent new requirements. Report the blocker as requiring plan/user input.

### Reporting Style

- Emit only the final full `Task Review Summary` for the last iteration.
- Include `### Iteration Notes` with iterations used and the main fix categories or commands applied.
- Do not print intermediate full summaries; keep them internal.

### Structural Deviation Exception

Some blockers may be inherent to the plan structure and unfixable without changing the plan. In these cases, document an `ACCEPTED DEVIATION` with justification and continue only if all remaining gates pass.

Example:
```markdown
### Accepted Deviations
1. **Long sequential chain**: The auth flow has inherent sequential dependencies
   (token → session → permission → access → audit). Parallelization would require
   plan changes. Accepted as structural constraint.
```

## Handling Edge Cases

### No Plan Available
- Verdict is FAIL unless the user explicitly requested a limited format-only review.
- Report that No-Stragglers / plan coverage could not be evaluated without the plan.
- If format-only review was explicitly requested, skip Phase 2, label the result `FORMAT_ONLY`, and do not report PASS for full task-graph validity.

### Mixed TODO.md and Beads
- Default to `--beads` if beads database exists and has open tasks
- Otherwise use TODO.md
- Flag if both exist with different content

### Very Large Task Graphs (>50 tasks)
Use the large-graph handling from the prompt contract. Additionally:
- Run focused batch passes by epic/parent (may use smaller batches of 5-10)
- Summarize findings by category rather than listing all in detail
- Focus detailed output on blocking issues only
- Global coverage and graph checks MUST still see ALL tasks (via summaries)
- The No Stragglers Gate is NON-NEGOTIABLE regardless of task count

### Tasks Already In Progress
- Note tasks with `in_progress` status
- Avoid recommending changes that invalidate ongoing work
- Flag if in-progress tasks have new blocking issues discovered
