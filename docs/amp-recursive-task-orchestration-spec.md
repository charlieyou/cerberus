# Amp Recursive Task Orchestration Spec

## Status

Draft design. This document describes a Cerberus-native Amp plugin workflow for long-running, recursively planned coding work. It is not an implementation plan and does not define a shipped command surface yet.

## Summary

Build an Amp plugin that turns one lead Amp thread into a recursive planner for a tree of focused implementation tasks. The plugin is the only interface for orchestration state, spawning, messaging, and lifecycle transitions. It spawns every lead, planner, and worker Amp session in a visible tmux pane, keeps each worker alive only long enough to complete its one task and respond to review feedback, and delegates all code review decisions to Cerberus review gates.

The design follows Cursor's scaling pattern for long-running coding agents: do not give many agents equal status and ask them to coordinate through an agent-visible shared file or lock; instead, use a simple planner/worker hierarchy, keep workers focused, let planners continuously create and refine work, and start fresh agents at cycle boundaries to combat drift. Planning may recurse indefinitely in principle: planners can create planner children, which can create further planners or worker tasks. In practice, run budgets, backpressure, and review gates bound each execution.

Cerberus is the judge. Amp threads may plan or implement, but they do not make code-acceptance decisions. Implementation leaves are accepted only when Cerberus passes the relevant diff or artifact through Codex, Gemini, and Claude consensus.

## Goals

- Provide a plugin-only Amp orchestration workflow; do not add a separate CLI wrapper.
- Use one plugin tool, `team`, for all state mutations and agent-facing operations.
- Support recursive, continuous planning rather than one up-front static task list.
- Avoid flat peer coordination, shared task files, and agent-visible locking protocols.
- Use fresh planner or worker starts as a deliberate anti-drift mechanism.
- Keep implementation workers single-task focused and disposable.
- Keep workers alive during Cerberus review so review feedback returns to the same task context.
- Use Cerberus, not Amp reviewer agents, as the review and quality gate.
- Run every spawned Amp session visibly in tmux so humans can observe and steer individual Amp sessions.
- Use one shared repository working tree for the first implementation, with plugin-owned file locks to permit safe parallel workers.
- Preserve Amp thread IDs for each spawned planner and worker so runs are auditable and resumable through Amp thread history.
- Use durable local state so a lead can recover after crashes or context resets.

## Non-Goals

- Do not clone Claude Code Agent Teams exactly.
- Do not build a second command-line interface such as `amp-team`.
- Do not create persistent role-based teammates such as `backend`, `frontend`, or `qa`.
- Do not let implementation workers self-coordinate through shared files, locks, optimistic-write retries, or arbitrary queue claiming.
- Do not replace Cerberus review gates with Amp reviewers.
- Do not add a generic Amp integrator role for quality control; Cerberus gates and scoped remediation tasks handle acceptance and gaps.
- Do not require per-worker git worktrees for the initial shared-tree implementation.
- Do not make the initial version fully autonomous across unsafe git or deployment operations.
- Do not require every task to run in parallel; safe serialization is acceptable when file scope or integration risk is unclear.

## Settled Runtime Decisions

- Every lead, planner, worker, and replacement thread runs as an Amp process in a plugin-managed tmux pane. Headless or SDK-based execution can be an internal spawn mechanism only if the resulting session is still visible and steerable through tmux.
- The initial implementation uses one shared repository working tree. Workers prepare changes in that tree; the plugin validates, stages, and commits task changes onto the current branch. It does not create one worktree per worker.
- Parallelism in the shared tree is allowed only through plugin-owned file locks and concrete disjoint scopes. Workers do not acquire or release locks themselves; the plugin acquires locks before spawning or continuing workers and releases them on task closure, abandonment, or escalation.
- Git index, commit, verification, and Cerberus review-target creation are protected by a plugin-owned repo gate so concurrent workers cannot corrupt the shared working tree or review the wrong diff.
- `team(action: "start_run")` must run from an Amp session that is already inside tmux. If the root Amp session is not in tmux, the plugin fails closed and tells the user to restart or attach Amp inside tmux before starting the run.
- The shared tree must have a clean baseline before scheduling. By default the plugin refuses to start with modified, staged, or untracked files; an explicit user-approved dirty baseline may be recorded, but baseline paths are treated as out of scope for workers unless separately locked.

## Existing Cerberus Context

Cerberus already provides the review layer this system needs:

- `README.md` defines Cerberus as a multi-model consensus review system using Codex, Gemini, and Claude.
- `skills/review-code/SKILL.md` describes iterative code review that spawns external reviewers, accepts fixes, re-runs review, and resolves on consensus.
- `skills/run-team/SKILL.md` already encodes several important invariants for Claude Agent Teams: implementers are single-use, the lead should not edit files, and review is gate-driven.

This design keeps those invariants, but moves orchestration into an Amp plugin and changes the team model from role-based teammates to recursive task-scoped threads.

## Cursor Scaling Lessons Applied

Cursor's long-running agents writeup is a design input, not just inspiration. This spec adopts the following lessons directly:

- Flat equal-peer coordination fails under scale. Agents that all read and write a shared coordination file, claim work, and manage locks tend to hold locks too long, forget to release them, bypass the protocol, or spend most of their time waiting.
- Optimistic concurrency is not enough by itself. Even if state writes are made safer, a hierarchy-less group has no owner for hard problems; agents gravitate toward small safe changes and churn without end-to-end progress.
- Planners and workers need separate jobs. Planners continuously explore and decompose; workers focus entirely on one assigned task and do not coordinate with peers.
- Planning is recursive and ongoing. A planner can create sub-planners for specific areas, and planners wake after child completion or review outcomes to decide what to do next.
- Fresh starts are a control primitive. Workers are fresh for each task, and planners can be replaced or refreshed with summarized state when they drift, run too long, or finish a planning cycle.
- Judges sit at cycle boundaries. Cursor used a judge agent to decide whether to continue; this Cerberus-native design uses Cerberus review gates instead, so acceptance comes from the existing Codex/Gemini/Claude consensus layer.
- Simpler structures scale better. The plugin owns coordination, scheduling, and lifecycle transitions; agents see a small `team` tool instead of lock files, ad hoc queues, or distributed-systems-style protocols.
- The right amount of structure is in the middle. Too little structure creates duplicate work and drift; too much structure creates fragile bottlenecks. Prompt contracts, budgets, and Cerberus gates carry more weight than elaborate coordination protocols.

## Architecture

```text
User
  |
  v
Root Amp thread with Cerberus team plugin enabled
  |
  | team(action: "start_run" | "create_task" | "spawn_task" | "status" | ...)
  v
Plugin scheduler and lifecycle controller
  |
  | owns all writes, scheduling, file locks, and git critical sections
  | agents do not claim queue work or edit coordination files
  v
Local orchestration state (.amp-team/<run>/team.sqlite)
  |
  +-- planner Amp threads in tmux panes, refreshed at cycle boundaries
  |     |
  |     +-- explore bounded branch scope
  |     +-- create child planner tasks for broad or risky areas
  |     +-- create concrete worker tasks with files and acceptance criteria
  |     +-- wake after child completion, review outcome, or backlog pressure
  |
  +-- fresh worker Amp threads in tmux panes
        |
        +-- run in the shared repository working tree
        +-- implement exactly one task
        +-- prepare task-scoped changes
        +-- ask plugin to validate, stage, commit, and review
        +-- wait during Cerberus review
        +-- fix same task if Cerberus rejects
        +-- shutdown after Cerberus passes

Implementation leaf completion
  |
  v
Cerberus review gate
  |
  +-- PASS -> accept task -> worker final handoff -> shutdown -> wake parent planner
  |
  +-- NEEDS_WORK / FAIL -> send findings to same worker -> worker fixes
  |
  +-- infra failure / unclear verdict -> stop branch and escalate
```

## Core Design Principles

### Plugin Is The Only Interface

All orchestration state changes go through the Amp plugin. There is no external CLI that also writes task state, sends messages, or claims work.

The plugin may call shell commands internally through Amp's plugin API. Those shell calls are implementation details, not a user-facing interface.

### No Flat Peer Coordination

Agents do not poll a shared task file, acquire locks, claim arbitrary backlog items, or negotiate work with each other. The plugin is the sole scheduler: planners propose tasks through `team`, the plugin records them, and the root lead or plugin scheduler decides what to spawn.

SQLite provides transactional durability for the plugin, not a distributed lock protocol for agents. Agents may inspect status through `team(action: "status")`, but they must not mutate `.amp-team` files directly or build side-channel coordination files.

### One Tool Surface

Expose one agent-facing tool named `team`. Do not expose separate tools such as `team_send_message`, `team_claim_task`, or `team_update_task` in the first design. A single tool keeps the LLM-facing API small and makes permissioning and audit easier.

Example shape:

```json
{
  "action": "create_task",
  "parent_id": "task_123",
  "kind": "work",
  "objective": "Implement the token refresh endpoint",
  "scope": {
    "files": ["src/auth/routes.ts", "src/auth/session.ts"],
    "out_of_scope": ["frontend/**", "migrations/**"]
  },
  "acceptance": ["Refresh token rotates on success", "Expired token returns 401"],
  "budget": { "max_turns": 8, "max_review_rounds": 3 }
}
```

### Planners Plan, Workers Work, Cerberus Reviews

There are three distinct responsibilities:

- Planners explore, decompose, and create tasks.
- Workers execute exactly one assigned implementation or investigation task.
- Cerberus reviews code and artifacts through existing review gates.

Workers should not become planners except to report that their task is too broad or blocked. The plugin then creates a child planner task rather than letting the worker coordinate a subtree.

### Simple Hierarchy Over Integrator Roles

The hierarchy is intentionally small: root lead, planners, workers, and Cerberus gates. Do not add a permanent integrator, queue manager, merge czar, or reviewer teammate unless a future implementation proves the need. Integration conflicts, gaps, and review failures should become scoped remediation tasks or Cerberus gate outcomes rather than a new standing role.

### Task Identity Beats Role Identity

Workers are named after tasks, not roles:

- Good: `work-T014-refresh-token-endpoint`
- Good: `work-T027-fix-review-findings-round-2`
- Avoid: `backend`
- Avoid: `qa`

Workers may receive an expertise lens inside a prompt, but their durable identity is the task.

### Review Keeps Worker Alive

When a worker finishes a task, it enters `cerberus_reviewing`. It remains reachable until Cerberus accepts or the branch is escalated. Review findings are sent back to the same worker so it can fix with the task context still loaded.

### Continuous Planning

Planning happens throughout the run. Planner threads wake when relevant child tasks finish, when Cerberus rejects work, when a subtree is judged incomplete, when backlog drops below a threshold, or when a task stalls.

This avoids the brittleness of a static all-up-front plan and allows the tree to deepen as the codebase reveals complexity. Every accepted worker task is a cycle boundary: the worker shuts down, the parent planner receives a compact completion summary and Cerberus result, and the planner decides whether to create more tasks, spawn a sub-planner, request branch verification, or declare the branch ready for review.

### Fresh Starts Prevent Drift

Workers always start fresh for a single task. They keep context only across the Cerberus feedback loop for that same task, then shut down after acceptance or escalation.

Planners may live across a branch, but they are also refreshable. When a planner exceeds its turn budget, accumulates too much stale context, loops without useful decomposition, or finishes a planning cycle that needs a different lens, the plugin can spawn a replacement planner with a compact branch brief, completed-child summaries, open risks, and remaining budgets.

### Prompts And Role Fit Matter

The prompts are part of the orchestration system. Planner and worker prompts must explicitly encode focus, non-coordination rules, handoff shape, and budget behavior; do not rely on the state schema alone to produce good multi-agent behavior.

If Amp exposes per-thread model selection, choose models by role rather than assuming one universal best model. Planner threads should prioritize decomposition quality, persistence, and low drift; worker threads should prioritize precise implementation and test execution. Cerberus reviewer model selection remains governed by Cerberus configuration.

## Agent Types

### Root Lead

The root lead is the user's main Amp thread. It is long-lived for the run and is responsible for starting, supervising, and summarizing the orchestration.

Responsibilities:

- Interpret the user's root objective.
- Start a run through `team(action: "start_run")`.
- Spawn initial planner tasks.
- Monitor high-level progress.
- Decide when to pause, escalate, or stop.
- Produce the final report.

The root lead should not directly edit repository files for implementation work and should not become a manual integrator for routine conflicts or gaps. It steers the plugin and summarizes outcomes; scoped implementation and remediation remain worker tasks gated by Cerberus.

### Planner Task

A planner is a task-scoped Amp thread whose deliverable is a set of child tasks or a decision that the branch is complete.

Responsibilities:

- Explore a bounded area of the codebase.
- Create child planner tasks when the area is too broad.
- Create worker tasks when work is concrete and scoped.
- Wake after child completions and decide whether more work is needed.
- Request Cerberus plan/spec review for high-risk plans when useful.
- Declare its planning branch ready for branch review when no more child tasks are needed.
- Summarize branch state so a fresh replacement planner can resume without inheriting stale context.

Planner threads can recurse. A planner can create a child planner for any sub-area that would otherwise overload its context, create too much uncertainty for one prompt, or require a different architectural lens.

### Worker Task

A worker is a task-scoped Amp thread with one implementation, investigation, or remediation objective.

Responsibilities:

- Read the task spec and relevant project guidance.
- Modify only files in scope while the plugin holds path locks for that scope.
- Run targeted checks while working.
- Prepare task-scoped changes without staging or committing them.
- Request plugin-owned validation, commit creation, and Cerberus review through `team(action: "complete_task")`.
- Respond to Cerberus findings if the task is rejected.
- Produce final handoff and shut down after acceptance.

A worker must not inspect a global queue, claim work, coordinate with other workers, stage files, commit, reset, clean, or pick up another task after it is accepted or abandoned. If the assigned task is too broad, blocked, or unsafe, it reports that through `team` so a planner can split or replace it.

### Cerberus Gate

Cerberus is the review layer, not an Amp teammate. The plugin invokes existing Cerberus review mechanisms for code, plans, specs, or epic verification.

Responsibilities:

- Run Codex, Gemini, and Claude reviewers according to Cerberus configuration.
- Aggregate verdicts and findings.
- Decide PASS, NEEDS_WORK, FAIL, or manual decision states at cycle boundaries.
- Provide findings that the plugin can route back to the worker or planner.

Cerberus replaces the "judge agent" role from Cursor's pattern. The plugin may use Cerberus verdicts to wake planners, create remediation tasks, pause a branch, or close a branch, but Amp teammates do not overrule those verdicts.

## State Model

Use SQLite for mutable coordination state. JSONL is acceptable for append-only event logs, but task assignment, message delivery, review-gate records, and lifecycle transitions need transactional updates.

SQLite is deliberately plugin-owned. It is not a shared markdown file, an agent-visible lock directory, or an agent-visible compare-and-swap queue. Planners and workers call `team`; the plugin performs the state transition and writes an audit event.

Recommended path:

```text
.amp-team/<run-id>/team.sqlite
.amp-team/<run-id>/events.jsonl
.amp-team/<run-id>/artifacts/
.amp-team/<run-id>/reviews/
.amp-team/<run-id>/locks/
```

### Tables

```sql
create table runs (
  id text primary key,
  root_thread_id text,
  workspace_root text not null,
  start_head text,
  baseline_manifest_path text,
  baseline_json text not null default '{}',
  objective text not null,
  status text not null,
  created_at text not null,
  updated_at text not null,
  budget_json text not null default '{}'
);

create table tasks (
  id text primary key,
  run_id text not null,
  parent_id text,
  root_id text not null,
  kind text not null,              -- plan | work | remediation | verify
  objective text not null,
  status text not null,
  depth integer not null,
  generation integer not null,
  owner_thread_id text,
  tmux_target text,
  scope_json text not null default '{}',
  acceptance_json text not null default '[]',
  budget_json text not null default '{}',
  created_by_thread_id text,
  created_at text not null,
  updated_at text not null,
  stale_after_at text
);

create table messages (
  id text primary key,
  run_id text not null,
  task_id text,
  sender_thread_id text,
  recipient_thread_id text,
  recipient_task_id text,
  kind text not null,              -- instruction | review_feedback | blocked | shutdown | status
  body text not null,
  status text not null,            -- created | delivered | acknowledged | resolved
  created_at text not null,
  delivered_at text,
  acknowledged_at text,
  resolved_at text
);

create table review_gates (
  id text primary key,
  run_id text not null,
  task_id text not null,
  kind text not null,              -- code | plan | spec | epic
  status text not null,
  cerberus_session_key text,
  artifact_path text,
  state_path text,
  verdict text,
  findings_json text,
  created_at text not null,
  updated_at text not null
);

create table task_artifacts (
  id text primary key,
  run_id text not null,
  task_id text not null,
  base_sha text,
  commit_sha text,
  commit_range text,
  changed_files_json text not null default '[]',
  staged_files_json text not null default '[]',
  review_patch_path text,
  verification_command text,
  verification_result_path text,
  cerberus_target_type text,       -- commit | patch | branch | artifact
  created_at text not null
);

create table locks (
  id text primary key,
  run_id text not null,
  task_id text,
  kind text not null,              -- path | repo_gate
  resource text not null,
  owner_thread_id text,
  acquired_at text not null,
  expires_at text
);

create table events (
  id integer primary key autoincrement,
  run_id text not null,
  task_id text,
  type text not null,
  payload_json text not null,
  created_at text not null
);
```

### Task Statuses

Planning statuses:

```text
created
spawned
planning
children_created
waiting_for_children
ready_for_branch_review
branch_reviewing
branch_verified
branch_complete
blocked
failed
closed
```

Worker statuses:

```text
created
spawned
running
worker_done
cerberus_reviewing
needs_changes
fixing
cerberus_passed
accepted
shutdown_requested
closed
blocked
abandoned
infra_failed
needs_human
```

Run statuses:

```text
created
running
paused
waiting_for_human
completed
failed
cancelled
```

## Plugin API Usage

### Required Amp Events

Use Amp's plugin API events:

- `session.start`: register the active thread, environment, role, tmux target, and run membership.
- `agent.start`: inject relevant task context, unread messages, and current constraints into the user message.
- `agent.end`: inspect completion state and return `{ action: "continue", userMessage }` when the thread should immediately continue.
- `tool.call` and `tool.result`: audit use of the `team` tool and optionally enforce risky command policy.

The critical behavior is `agent.end`: when an agent stops, the plugin checks for pending messages, review feedback, planner wakeups, fresh-start requests, or shutdown requests. If any exist, it starts the next Amp turn automatically with a bounded continuation message.

### Automatic Continuation

Use continuation carefully to avoid infinite loops.

Continuation triggers:

- A message is waiting for the current thread.
- Cerberus findings are available for the current worker through a synchronous tool result or a future async wakeup path.
- A planner child completed and the planner should re-evaluate the branch.
- A Cerberus PASS closed a worker cycle and the parent planner should decide the next step.
- A planner or worker exceeded its context, turn, or wall-clock budget and needs a fresh replacement thread.
- A shutdown request needs final handoff.
- A stale task deadline or infra error requires escalation.

Continuation guards:

- Per-thread auto-continue budget.
- Per-task max turns.
- Per-task max Cerberus review rounds.
- Run-level cost and wall-clock budget.
- No continuation on repeated identical inbox state.
- No continuation after accepted shutdown except final archival bookkeeping.
- Prefer spawning a fresh replacement over repeatedly continuing a drifting planner.

## Single `team` Tool

### Actions

The single tool should support these actions over time. Phase 1 can implement a smaller subset (`start_run`, `create_task`, `spawn_task`, `message`, `complete_task`, `status`, `shutdown_task`) as long as later capabilities stay behind the same `team` surface.

```text
start_run
create_task
spawn_task
message
complete_task
request_review
record_review_result
accept_task
reject_task
shutdown_task
status
pause_run
resume_run
cancel_run
```

There is intentionally no `claim_task` action. Workers are assigned one task by the plugin when they are spawned; planners create or refine tasks but do not race each other to acquire queue items.

The single tool surface is still permissioned by caller. Exposing one tool does not mean every thread can invoke every action:

| Caller | Allowed actions |
|--------|-----------------|
| Worker | `complete_task`, `status`, `message` only to parent/plugin, `message(kind: "blocked")` |
| Planner | `create_task`, `request_review`, `status`, `message` only to parent or direct children through plugin-routed lifecycle messages |
| Root lead | `start_run`, `spawn_task`, `pause_run`, `resume_run`, `cancel_run`, `status`, steering `message` |
| Plugin/Cerberus internal | `record_review_result`, `accept_task`, `reject_task`, lock release, task closure |

The plugin must reject a worker or planner that attempts to record review results, accept work, reject work, message a peer worker, or mutate lifecycle state outside its role.

### Action Semantics

`start_run` runs preflight, records the clean or explicitly approved baseline, then creates the run state and root task.

`create_task` creates a child task but does not necessarily spawn it.

`spawn_task` starts an Amp thread in tmux for a planner or worker task and records the plugin-owned assignment.

`message` sends an instruction or information only along allowed routing paths. Workers may report to the parent planner or plugin, but may not message peer workers. Planners may message direct children or their parent through plugin-controlled lifecycle events. Cross-branch or peer coordination must become planner-created tasks, not direct chat.

`complete_task` is called by workers when they believe their task is done; for code tasks it triggers Cerberus review.

`request_review` explicitly starts a Cerberus gate for an artifact or subtree.

`record_review_result` records Cerberus output and changes task state. It is plugin/Cerberus-internal only.

`accept_task` marks a task accepted after required gates pass. It is plugin/Cerberus-internal only.

`reject_task` sends feedback to the same task worker or planner. It is plugin/Cerberus-internal only.

`shutdown_task` asks the thread to summarize and stop.

`status` returns run, task, branch, and gate state.

`pause_run`, `resume_run`, and `cancel_run` control scheduling.

### Tool Permissions

The plugin should treat `team` as the only state-mutating API. Agents may read files and use normal Amp tools, but they may not update `.amp-team` SQLite state directly through Bash or file edits.

Workers may edit repository files within their locked scope, but they may not run `git add`, `git commit`, `git reset`, `git clean`, or any command that manipulates the shared index or history. The plugin owns staging, commit creation, review-target creation, acceptance, and lock release.

## Tmux And Amp Thread Runtime

The plugin creates tmux sessions and panes internally. All active lead, planner, worker, and replacement Amp sessions run in tmux panes. The user still interacts through Amp, not a separate CLI.

Headless Amp execution, stream JSON, or an SDK can be used behind the scenes only as a way to bootstrap or monitor a tmux-pane process. They are not alternative user-visible runtimes for this design.

The root lead is not silently migrated into tmux. `start_run` checks the current environment for tmux membership and fails before creating run state if the user started Amp outside tmux. In the initial runtime, the plugin adopts the existing root tmux pane as the lead pane and creates/manages child planner, worker, and log panes around it. A future bootstrap mode may create a new tmux lead pane and transfer control there, but that is not the initial runtime.

Recommended layout:

```text
tmux session: amp-team-<run-id>

window 0: lead
  pane 0: root Amp thread

window 1: planners
  panes: planner task threads

window 2: workers
  panes: worker task threads

window 3: logs
  panes: event tail, Cerberus review output, test logs
```

Each spawned Amp session should run with environment variables that bind it to the run and task:

```text
PLUGINS=all
AMP_TEAM_RUN_ID=<run-id>
AMP_TEAM_TASK_ID=<task-id>
AMP_TEAM_DB=<absolute path to team.sqlite>
AMP_TEAM_KIND=planner|worker
```

The plugin captures each worker's Amp thread ID from stream JSON output or from `session.start` when the plugin initializes in the child session.

The tmux target is durable run state. If the root lead crashes or loses context, status can show the pane target and thread ID for every active task so a human or replacement lead can inspect, pause, or steer the session.

## Start Run Preflight

`team(action: "start_run")` must fail before creating mutable run state unless these checks pass:

- The root Amp session is running inside tmux.
- The repository root can be identified and matches the intended workspace.
- The git index and working tree are clean, including untracked files, or the user explicitly approves recording a dirty baseline.
- Any approved dirty baseline is written to run state as a manifest and excluded from worker scopes unless the user explicitly assigns those paths to a task.
- The initial `start_head` is recorded.
- No active Cerberus gate, stale run lock, or leftover repo gate from the same workspace can be confused with the new run.

During the run, the plugin compares observed dirty paths against active task path locks. Unexpected dirty files, staged files not owned by the repo gate, or HEAD movement outside plugin-owned task commits pause scheduling and require human recovery.

## Cerberus Integration

Cerberus is the cycle judge for implementation leaves and branch verification. The plugin may automate review-gate invocation and result routing, but it must not reinterpret failed Cerberus findings as accepted work.

### Code Review

When a worker calls `team(action: "complete_task")`, Phase 1 uses a synchronous tool call: the worker waits for the plugin to validate, create the task commit, run or target verification, invoke Cerberus, and return either review findings or shutdown instructions. Later async review is allowed only after a specific wake mechanism for the same tmux-pane Amp thread is designed.

For code tasks the plugin performs these steps:

1. Confirm the task is a worker task and is not already under review.
2. Acquire the repo gate. This is a coarse critical section for validation, staging, commit creation, verification target creation, Cerberus target creation, and state recording.
3. Validate that dirty paths for this worker are within the task's locked scope and that no unexpected staged files exist.
4. Reject or escalate if the task changed files outside its locked scope, touched a serialization-only path, or depends on another active worker's dirty files.
5. Stage only the task's locked pathspecs.
6. Create a task-scoped commit with trailers such as `Amp-Team-Run: <run-id>` and `Amp-Team-Task: <task-id>`.
7. Record `base_sha`, `commit_sha`, changed files, staged files, and any patch artifact in `task_artifacts`.
8. Create an immutable Cerberus review target: preferably the task commit or a saved patch artifact. Cerberus should not review the live working tree when other workers may have dirty changes.
9. Run only verification that can be trusted for the immutable target or for a quiesced tree. If full-repo verification needs live filesystem state and other workers have dirty changes, defer it to a branch-level gate or pause/quiesce active workers first.
10. Spawn Cerberus code review with task context and the immutable target.
11. Wait for the Cerberus verdict using a unique session key.
12. Store review artifacts in `review_gates`.
13. Release the repo gate only after the review target, task artifact state, and lock state are durable.
14. If PASS, move task to `cerberus_passed`, send a shutdown message, and wake the parent planner with the accepted commit, file manifest, tests, and Cerberus summary.
15. If NEEDS_WORK or FAIL, move task to `needs_changes` and send findings to the same worker. The worker fixes the same task in the shared tree; the next `complete_task` creates a new task commit or patch and re-runs the gate against the aggregate task range from the original `base_sha` through the latest task commit.
16. If Cerberus fails operationally, move task to `infra_failed` or `needs_human` and pause the branch.

### Plan And Spec Review

Planner tasks may request Cerberus plan or spec review for high-risk artifacts. This is not required for every planning node; use it when the planner proposes a significant architecture, migration, public API, or risky test strategy.

### Epic Or Branch Verification

After a planner believes a branch is complete, it marks the branch `ready_for_branch_review`; it does not close the branch itself. The plugin may run Cerberus epic verification against branch acceptance criteria. If the verifier passes, the plugin can mark the branch `branch_verified`, then `branch_complete` or `closed` when parent dependencies allow. If the verifier finds gaps, the plugin creates remediation worker tasks under that branch.

Branch-level verification should be required for multi-task features, public API changes, migrations, risky refactors, or user-provided acceptance criteria. For small single-task leaves, the task-level Cerberus code gate may be sufficient unless the planner or root lead requests additional verification.

### Reviewers Are Not Amp Teammates

The plugin must not spawn Amp threads named `reviewer`, `qa`, `security-reviewer`, or similar for code acceptance. Cerberus reviewers are the code acceptance authority.

If a planner needs critique of a plan or branch, it should request a Cerberus plan/spec/epic gate rather than creating an Amp reviewer teammate.

## Recursive Planning

Recursive planning is the main scaling mechanism. The initial planner does not need to foresee the full project; it only needs to create the next useful frontier of sub-planners and concrete worker tasks. Each completion cycle feeds evidence back into the relevant planner so the tree can grow, shrink, split, or close based on what the codebase and Cerberus gates reveal.

### Task Tree

All work is a tree rooted at the user's objective. Some nodes can also form a DAG through dependency metadata, but parent-child ownership is a tree.

```text
root objective
  planner: auth subsystem
    planner: token lifecycle
      worker: implement refresh endpoint
      worker: add rotation tests
    planner: session cleanup
      worker: expire old sessions
  planner: frontend login UX
    worker: update login form
```

### Continuous Replanning Cycle

Each branch repeats this cycle until it closes or escalates:

1. A planner explores a bounded branch and creates a small set of child planners or concrete worker tasks.
2. The plugin schedules safe ready tasks without exposing a shared queue or lock to agents.
3. A fresh worker completes exactly one task and calls `team(action: "complete_task")`.
4. The plugin validates the worker's scoped changes, creates a task commit or patch artifact, and asks Cerberus to review that immutable target.
5. On PASS, the worker writes a final handoff and shuts down; the parent planner wakes with the task summary, commit range, tests, and Cerberus verdict.
6. On NEEDS_WORK or FAIL, the same worker receives findings while its task context is still loaded; after acceptance or exhaustion, the parent planner wakes and adjusts the branch.
7. The planner either creates more tasks, creates a sub-planner, requests branch-level Cerberus verification, refreshes itself into a new planner thread, or declares the branch ready for plugin/Cerberus closure.

### Wakeup Rules

Planners wake when:

- A direct child task closes.
- A child task fails or asks for decomposition.
- Cerberus accepts a remediation task.
- Branch backlog falls below the desired minimum.
- A child task exceeds its stale-after deadline.
- A human sends a steering message to the branch.
- The planner's own continuation budget suggests a fresh replacement should take over.

### Recursion Rules

- A planner may create child planners when scope is broad, ambiguous, or risky.
- A planner may create worker tasks only when objective, scope, files, and acceptance criteria are concrete.
- A worker may ask for decomposition but should not spawn child work directly.
- A planner should prefer a few high-signal child tasks over a huge up-front task list.
- A fresh planner can replace a drifting planner at the same branch node using summarized state.
- A branch may close only after required children and branch-level Cerberus gates pass.

## Parallelism

Parallelism is allowed but conservative.

Parallelism is scheduled by the plugin, not negotiated by workers. Workers should never wait on each other, edit a shared coordination file, or acquire a lock before starting work; if the plugin cannot prove that a cohort is safe, it should serialize.

The initial runtime uses a shared repository working tree. Parallel workers can run in that tree only when the plugin owns the relevant locks and the task scopes are concrete enough to prevent overlap.

Run tasks in parallel only when all are true:

- They have clearly disjoint file scopes and the plugin has acquired path locks for those scopes.
- Their dependencies are complete.
- They do not touch shared-risk files such as lockfiles, migrations, global config, generated schemas, or shared fixtures.
- The run is under active agent, token, and wall-clock budgets.
- Cerberus review capacity is available.

When uncertain, serialize.

### Shared-Tree File Lock Strategy

The first implementation uses one shared working tree and plugin-owned lock files under the run directory:

```text
.amp-team/<run-id>/locks/paths/<path-hash>.lock
.amp-team/<run-id>/locks/repo-gate.lock
```

Lock ownership is also recorded in SQLite for status, recovery, and stale-lock cleanup. The lock files are implementation details of the plugin; workers see only their assignment and scope.

Path locks protect files and directories that a worker may edit. The plugin should acquire path locks before spawning or continuing a worker. If a task has broad or ambiguous scope, the plugin serializes it or asks a planner to split it.

Path lock rules:

- Canonicalize every lock to a repo-relative, symlink-resolved path using the repository's filesystem case rules.
- Treat a directory lock as covering all descendants.
- Reject overlapping file and directory locks.
- Require planners to declare expected new-file paths or directories before spawning a worker.
- Treat lockfiles, migrations, generated schemas, global config, package manifests, and shared fixtures as serialization-only unless the root lead explicitly permits parallelism.
- At `complete_task`, compare the actual changed-file manifest with the locked scope and reject or escalate on any out-of-scope file, rename, deletion, generated file, or symlink surprise.
- Pause scheduling if the user or another process modifies a path not covered by an active task lock or the approved baseline.

The repo gate is a coarse critical section for validation, staging, commit creation, verification target creation, Cerberus review-target creation, and durable state recording. This lets implementation work proceed in parallel while the shared branch advances through one reviewed task transition at a time.

The initial design should review immutable task commits or saved patch artifacts. If the selected Cerberus path or verification command must read the live working tree, the plugin must either quiesce active workers and confirm no unrelated dirty files are present, or defer that verification to a branch-level gate. It must not run live-tree review against a tree containing another worker's dirty changes.

Per-worker worktrees remain a possible future isolation upgrade, but they are not the initial default.

## Failure Handling

### Cerberus NEEDS_WORK Or FAIL

- Keep the worker alive.
- Send aggregated findings to the same worker.
- Move task to `needs_changes`.
- Let the worker fix and call `complete_task` again.
- Stop after max review rounds and mark `needs_human`.

### Worker Abandons Task

If a worker goes idle without completion, escalation, or a valid blocked state:

- Mark task `abandoned`.
- Notify parent planner and root lead.
- The planner may spawn a replacement worker or split the task.
- Preserve the original worker thread and logs.

### Worker Reports Task Too Broad

If a worker discovers that its assignment is too broad, ambiguous, or unsafe for one focused implementation thread:

- Mark the task `blocked` or `needs_human` with the worker's evidence.
- Wake the parent planner.
- Prefer splitting the branch into child planner or worker tasks over asking the same worker to coordinate a subtree.
- Spawn fresh workers for the resulting concrete tasks.

### Planner Drift

If a planner creates overly small tasks, avoids hard problems, or loops without progress:

- Mark planner `blocked` or `failed`.
- Spawn a fresh sibling planner with a tighter prompt and the accumulated state.
- Optionally ask Cerberus `ask` or plan review for a critique of the planning branch.

### Thread Runs Too Long

If any planner or worker exceeds its turn, wall-clock, or context budget:

- Stop automatic continuation for that thread.
- Preserve its thread ID, transcript, partial summary, and artifacts.
- For a worker, either send a final bounded continuation for handoff or mark the task abandoned and let the planner split or replace it.
- For a planner, spawn a fresh planner at the same branch node with a compact summary rather than extending a drifting context indefinitely.

### Infra Failure

Infra failures include tmux spawn failure, missing Amp plugin support, invalid Cerberus state, reviewer timeout, malformed reviewer output that cannot be repaired, SQLite corruption, stale plugin-owned locks that cannot be safely recovered, or shared-tree git/index state that does not match the task ledger.

Policy:

- Pause scheduling for the affected branch.
- Preserve artifacts.
- Report exact recovery commands when known.
- Do not destructively reset the shared tree, delete lock artifacts, or discard worker changes without explicit user approval.

### Human Intervention

Ask the user only for decisions that cannot be made safely:

- Destructive git operations.
- Publishing, deployment, or production data mutation.
- Secret or credential use.
- Material ambiguity in task objective.
- Cerberus manual-decision states after reviewer degradation.

## Prompt Contracts

### Planner Prompt Contract

Every planner receives:

- Root objective and parent objective.
- Current branch tree and known completed work.
- Explicit instruction not to implement.
- Criteria for when to create child planners vs workers.
- Budget and max child creation guidance.
- Requirement that worker tasks have concrete file scopes suitable for shared-tree path locking.
- Requirement to use `team` for all state changes.
- Warning not to create shared coordination files, lock protocols, or worker-to-worker handoff schemes.
- Requirement to emit a compact branch summary when closing, blocking, or handing off to a fresh planner.

Planner behavior:

```text
Explore only what is needed for your planning branch. Create concrete child
tasks with file scope and acceptance criteria. If the branch is too broad,
create child planner tasks. Prefer a small next frontier over a giant static
task list. Do not edit repository files. Do not coordinate workers through
shared files or locks. Do not review code; Cerberus is the review gate.
```

### Worker Prompt Contract

Every worker receives:

- One task objective.
- Files in scope and out of scope.
- Notice that the plugin has already acquired any required path locks; the worker must stay within that scope rather than managing locks itself.
- Acceptance criteria.
- Dependency context from parent tasks.
- Verification commands or pointers.
- Cerberus review loop instructions.
- Explicit instruction not to accept another task.
- Explicit instruction not to inspect a global backlog, negotiate with other workers, or mutate `.amp-team` state directly.

Worker behavior:

```text
Complete only this task. Modify only files in scope unless you ask for scope
expansion. Run targeted checks, but do not stage or commit; the plugin owns
the shared index and task commit. When done, call team(action: "complete_task").
If Cerberus sends findings, fix this same task and request review again. After
acceptance, write a final handoff and stop. If the task is too broad or blocked,
report that through team and stop; do not become a planner or coordinator.
```

### Shutdown Prompt Contract

Workers receive one final shutdown continuation:

```text
Your task has been accepted. Write a concise final handoff with changed files,
commits or diff summary, tests run, Cerberus verdict, and caveats. Then stop.
Do not begin new work.
```

## Safety And Permissions

- The plugin API is experimental and must run only in trusted workspaces with `PLUGINS=all`.
- The plugin can execute shell commands; treat it as trusted code.
- Use Amp permissions or plugin `tool.call` handling to reject destructive git commands from workers unless explicitly allowed.
- Workers should not run `git reset --hard`, `git clean`, force pushes, deploys, or secret-reading commands.
- The plugin should write audit events for every state transition and shell action it performs.

## Budgets And Backpressure

Run-level budgets:

- Max active Amp threads.
- Max active worker threads.
- Max active planner threads.
- Max total tasks created.
- Max depth before human confirmation.
- Max tasks created per planner cycle.
- Max branch backlog size before requiring planner consolidation.
- Max total wall-clock time.
- Max per-thread wall-clock time before fresh-start replacement.
- Max Cerberus review rounds per task.
- Max concurrent Cerberus gates.
- Max auto-continuations per thread without new external input.
- Max repeated failures in the same branch before pausing expansion.

Backpressure rules:

- Do not spawn more workers when Cerberus review backlog is saturated.
- Prefer planners when backlog is empty and uncertainty is high.
- Prefer workers when there are concrete ready tasks and review capacity is available.
- Prefer fresh planner replacement over extending a planner that is looping or carrying stale context.
- Ask planners to consolidate when they create too many tiny low-value tasks.
- Pause branch expansion after repeated Cerberus failures in the same area.

## Observability

The plugin should provide status through the same `team` tool and optional command-palette UI, but not a separate CLI.

Status should show:

- Run objective and status.
- Active planners and workers.
- Task tree with statuses.
- Active path locks and repo gate ownership.
- Task artifacts: base SHA, commit SHA or patch path, changed-file manifest, and verification result.
- Current Cerberus gates.
- Blocked tasks and reasons.
- Recent events.
- tmux targets for manual inspection.
- Amp thread IDs for all spawned sessions.

Event logs should be append-only JSONL for easy debugging:

```json
{"type":"task.status_changed","task_id":"T014","from":"running","to":"worker_done","at":"..."}
{"type":"lock.acquired","task_id":"T014","kind":"path","resource":"src/auth/routes.ts","at":"..."}
{"type":"cerberus.verdict","task_id":"T014","verdict":"NEEDS_WORK","findings":2,"at":"..."}
```

## Implementation Phases

### Phase 1: Minimal Shared-Tree Prototype

- One plugin file in `.amp/plugins/`.
- One `team` tool.
- SQLite state.
- Plugin-managed tmux pane for every root, planner, and worker Amp session.
- Shared working tree on the current branch.
- Root lead can create and spawn one worker task at a time.
- No worker queue claiming, shared coordination file, or agent-visible locks.
- Plugin-owned path locks and a repo gate exist even if the first cut runs serially.
- Fresh worker thread for every task.
- Worker calls `complete_task`.
- Plugin validates scope, stages, creates the task commit or patch artifact, and runs Cerberus code review.
- Findings return to the same worker through the synchronous `complete_task` result; later async wakeups must target the same tmux-pane thread.
- Worker shuts down after Cerberus PASS.

### Phase 2: Continuous Planner Loop

- Add planner task kind.
- Add child task creation.
- Add planner wakeups when children close.
- Wake parent planners after Cerberus PASS, NEEDS_WORK exhaustion, branch verification, or blocked child tasks.
- Add compact branch summaries for fresh planner replacement.
- Add branch status and branch completion.

### Phase 3: Shared-Tree Parallel Scheduling

- Spawn multiple safe workers in tmux panes when their declared file scopes are disjoint.
- Acquire plugin-owned path locks before worker spawn or continuation.
- Serialize validation, staging, commit creation, verification target creation, and Cerberus review-target creation with the repo gate.
- Surface active locks in `team(action: "status")`.

### Phase 4: Tmux Monitoring And Recovery

- Plugin-managed tmux sessions and panes.
- Thread ID registration.
- Status output with tmux targets.
- Human steering through the lead and plugin messages.
- Recovery flow for orphaned tmux panes, stale locks, and shared-tree dirty state.

### Phase 5: Optional Worktree Isolation

- Optional future upgrade if shared-tree locks become too constraining.
- One worktree per worker, branch naming, and merge/cherry-pick flow.
- Cerberus review on task branch diffs or immutable commit snapshots.
- Conflict remediation tasks still go through fresh workers and Cerberus.

### Phase 6: Recursive Continuous Planning And Fresh Starts

- Planner subtrees.
- Branch-level Cerberus verification.
- Budgeted recursive expansion.
- Replacement planners for drift.
- Backpressure based on active threads, branch backlog, review capacity, depth, and repeated failures.

## Open Questions

- Should the plugin live in this Cerberus repo as an Amp-native companion, or should it remain a design until Amp's plugin API stabilizes?
- Should initial code review use existing `bin/review-gate` directly, or should Cerberus expose a smaller plugin-friendly API for review spawn and wait?
- What exact lock implementation should the plugin use: advisory `flock`, atomic lock directories, SQLite lock rows plus lock files, or a hybrid that works on macOS and Linux?
- How should stale path locks and repo gates be detected and safely recovered when a tmux pane or Amp process dies?
- How should shared-branch task commits be identified most robustly for Cerberus review: task trailers, captured before/after SHAs, staged file manifests, or a combination?
- What run budget should require human confirmation before deeper recursive planning continues?
- What model choices should be used per role if Amp exposes role-specific model selection for planners versus workers?
- What thresholds should trigger fresh planner replacement: turn count, wall-clock time, context size, repeated weak tasks, or Cerberus critique?
- Should branch-level verification run after every accepted worker, after planner-declared milestones, or only at branch closure?

## Acceptance Criteria For A Future Implementation

- A user can start a run from one Amp thread with `PLUGINS=all amp` and no separate orchestration CLI.
- All orchestration state mutations go through `team`.
- Workers cannot claim arbitrary queue work or coordinate through shared files, locks, or direct `.amp-team` edits.
- Every spawned lead, planner, worker, and replacement session runs visibly in a plugin-managed tmux pane.
- The initial runtime uses one shared working tree with plugin-owned path locks and a repo gate.
- Parallel workers run only when their scopes are concrete, disjoint, and locked by the plugin.
- A worker receives exactly one task and is never reused for another task.
- A worker that finishes implementation remains alive while Cerberus reviews.
- Cerberus NEEDS_WORK or FAIL findings are delivered back to the same worker.
- Cerberus PASS triggers final handoff and worker shutdown.
- A planner can create child planner tasks and worker tasks.
- A planner wakes after child completion and can continue planning.
- Planner wakeups happen after Cerberus outcomes, not only after static task-list completion.
- Fresh worker starts are mandatory and fresh planner replacement is available when drift or budget limits require it.
- Recursive planning is bounded by configurable budgets.
- Backpressure prevents unbounded task creation, active threads, review gates, depth, and auto-continuations.
- The status surface shows task tree, active threads, tmux targets, active locks, task artifacts, and Cerberus gates.
- No Amp reviewer teammates are spawned for code acceptance; Cerberus is the review authority.
