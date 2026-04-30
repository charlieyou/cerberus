# mala-lite — extending the cerberus plugin

## Context

The user wants to demonstrate the implementer/reviewer inner loop from `mala` (`/Users/cyou/code/mala`) using Claude's native primitives, but **without modifying mala**. The build is part of the existing **cerberus** plugin (`/Users/cyou/code/cerberus`), reuses `cerberus:review-code` as the reviewer, drives the loop with a **`TaskCompleted` hook** on implementer teammates, and has `cerberus:create-tasks` emit a new "agent-team" output format that this team-runner consumes.

Two recent mala commits motivate the design:
- **`f20f9777`** (reviewer-context guidance in implementer prompt): with the `TaskCompleted` hook approach, findings are injected back into the implementer's context as **stderr feedback** when the hook blocks (`exit 2` is the documented path for `TaskCompleted` to block-with-feedback per https://code.claude.com/docs/en/hooks) — the same idea, native to Claude.
- **`801c1ac2`** (sequential remediation chains): replaced by the `dependencies` field already produced by `create-tasks` — the team runner schedules ready tasks only.

**Result**: a thin set of additions to cerberus that turns a plan → tasks → autonomous implementer/reviewer loop on top of Claude's **agent-team** primitive (`TeamCreate` + `Agent({team_name, name, …})`), gated by `TaskCompleted`-driven multi-model review, and checked by automatic `/cerberus:verify-epic` passes after each execution phase.

## Architecture

```
User: /cerberus:create-plan ...                 (existing)
User: /cerberus:create-tasks --agent-team       (NEW flag → emits team-tasks.md)
User: /cerberus:run-team                        (NEW command → kicks off the team)
   │
   └── Lead Claude (team lead)
         │
         ├── TeamCreate(team_name: "cerberus-impl-<hash>", …)
         ├── For each cerberus task T###:  TaskCreate(subject: "[CERBERUS-IMPL/<hash>] T### — …",
         │                                            metadata: { cerberus_task_id: "T###",
         │                                                        cerberus_team_hash: "<hash>" })
         │
         └── Scheduling loop (strictly serial in initial cut):
               │
               ├── pick one ready cerberus task → write per-task state file
               ├── Agent({team_name, name: "impl-T###",
               │          subagent_type: "implementer",
               │          model: "opus",
               │          prompt: "<bootstrap pointer to TaskList metadata + task context>"})
               │     │
               │     ├── teammate reads task spec, implements, commits with `Cerberus-Task: T###` trailer
               │     ├── teammate sends `STATUS: READY_FOR_COMPLETION T### — commits <short-shas>`
               │     ├── lead drains other teammates, sends `PROCEED_TO_COMPLETE T###`
               │     ├── teammate touches completion_intent, then calls TaskUpdate(status: "completed")
               │     │     ← triggers TaskCompleted hook
               │     │     │
               │     │     └── TaskCompleted hook (NEW — no matcher; gated by lead's hard rule
               │     │           "lead never completes Claude tasks; only teammates do")
               │     │           │
               │     │           └── bin/cerberus-task-completed-hook  (NEW)
               │     │                 ├── reads task_name from hook input; bails out (exit 0)
               │     │                 │   if not prefixed with "[CERBERUS-IMPL/<team_hash>]"
               │     │                 ├── resolves team_hash + cerberus_task_id from metadata
               │     │                 │   (primary) or subject prefix (fallback) → reads
               │     │                 │   state file at <state_root>/<team_hash>/<task_id>/
               │     │                 ├── if round ≥ max_rounds: write `exhausted`, exit 2 with
               │     │                 │   "Already exhausted; SendMessage NEEDS_HUMAN to lead, go idle"
               │     │                 ├── derives commit range, range-contract guard, runs the
               │     │                 │   resolved verification gate, spawns review,
               │     │                 │   polls wait
               │     │                 ├── PASS / NEEDS_WORK-no-P0/P1 → increment round, exit 0 →
               │     │                 │   TaskUpdate succeeds → task marked completed → teammate idle
               │     │                 ├── FAIL / NEEDS_WORK-w/P0/P1   → increment round, exit 2 with
               │     │                 │   findings on stderr → TaskUpdate fails → teammate sees
               │     │                 │   feedback, fixes, commits, sends fresh READY, waits for
               │     │                 │   fresh PROCEED before retrying completion
               │     │                 └── ERROR / no_reviewers / timeout → write `last_error`,
               │     │                     exit 2 with "infra-failure; SendMessage NEEDS_HUMAN
               │     │                     to lead, go idle" (per-round gate state left as inert
               │     │                     files; not the parent's gate, does not block parent Stop)
               │     │
               │     └── on success: TaskUpdate(completed) goes through; teammate goes idle
               │       on retry-loop: teammate keeps the same context across rounds (sees stderr findings)
               │       on terminal failure: teammate SendMessages "STATUS: NEEDS_HUMAN T###" to lead,
               │                            does NOT retry TaskUpdate, goes idle
               │
               └── lead inspects TaskList + state markers + any teammate message → classifies
                   outcome → either schedules next ready task (success) or stops scheduling (failure)
         │
         ├── After each execution phase completes (and no failures):
         │     /cerberus:verify-epic against completed-phase criteria; final phase verifies the full plan/spec.
         │
         └── Final report (passed / failed / skipped + per-phase verify-epic verdicts).
```

The implementer is an **agent-team teammate**, not a regular subagent. Each cerberus task gets a **fresh teammate** (`impl-T001`, `impl-T002`, …) — no cross-task context reuse. Within a single task's review/retry loop, the same teammate keeps its context (sees findings on stderr, fixes, retries).

The `TaskCompleted` hook has no matcher (per docs: "always fires on every occurrence"). Disambiguation is by the lead's hard rule: **the lead never calls `TaskUpdate(status: "completed")` on any team task list** — only teammates do. With that invariant, every `TaskCompleted` event in this team's lifecycle is an implementer signal. As defense-in-depth, the hook also bails out (exit 0) if `task_name` is not prefixed with `[CERBERUS-IMPL/<team_hash>]`, so unrelated task lists from other tooling cannot collide. The `<team_hash>` segment in the prefix doubles as a fallback channel for the hook to discover the team_hash (used to namespace the per-task state directory) when `metadata.cerberus_team_hash` is not exposed at runtime.

**TaskCompleted docs caveat.** The current docs are internally inconsistent: the lifecycle table and agent-teams hook summary describe `TaskCompleted` as firing when a task is being marked complete, while the detailed `TaskCompleted` section also says it can fire when a teammate finishes a turn with in-progress tasks. Cerberus does not rely on that surprising second clause for idle handling. The explicit completion path is identified by the implementer's required `${state_dir}/completion_intent` marker; idle notification suppression is handled by the separate `TeammateIdle` hook.

The lead detects an idle teammate via the separate `TeammateIdle` event + TaskList state inspection. Because Claude Code can repeatedly announce a parked teammate as available, the plugin also installs a `TeammateIdle` hook that lets the first idle signal through for classification and terminates duplicate idle firings for the same single-use implementer.

## Files to add / modify in `/Users/cyou/code/cerberus/`

### MODIFY — `commands/create-tasks.md`
Add a third output branch in **Phase 6: Output Generation** (currently at `commands/create-tasks.md:546-617` with `--beads` at line 550 and default TODO.md at line 602). Insert between them or after:

- New conditional: **`#### If --agent-team flag is set:`**
  - Emit a `*-team-tasks.md` file (next to the plan) using the new template (see below). Use the plan's filename prefix (e.g., `auth-system-plan.md` → `auth-system-team-tasks.md`) so multiple plans in the same directory don't collide.
  - Reuse all task specs from Phase 4 (sizing, source links, dependencies, ACs)
  - Output is a structured list of tasks with explicit `dependencies: [T001, T002]` entries (the existing TODO.md already has this; this format leaves it machine-parsable while staying human-readable)
- Update frontmatter `argument-hint`: `[--beads | --agent-team] [--from-plan <path/to/plan.md>]`
- Update the "Selecting Output Format" table at lines 22-27 to include `--agent-team`
- Hard rule: `--beads` and `--agent-team` are mutually exclusive

No other changes to create-tasks; Phases 1-5 are untouched.

### NEW — `templates/team-tasks-template.md`
Canonical schema for the new output, parallel to the existing `templates/tasks-template.md`. Keep it markdown — but with a YAML frontmatter block and a fenced metadata block per task so the runner can parse it cleanly.

**Parser contract (locked)**: the `meta` fenced block is always the **first** fenced block immediately under each `## T###` heading. The task body extends from after that first fence's close until the next `## ` line at column 0 (or EOF). Task bodies may contain other fenced code blocks; the parser must not confuse them with `meta`. Document this contract at the top of the template file so authors don't accidentally place narrative text between the heading and the meta block.

```markdown
---
plan: <path-to-plan>.md
spec: <path-to-spec>.md   # or N/A
generated: <ISO timestamp>
---

# Team Tasks: <Feature>

## T001 — <subject>
```meta
files: [path/a.py, path/b.py]
depends: []
acceptance: [AC1, AC2]
plan_link: <plan>.md#L45-L67
```
<full task spec body — same as TODO.md collapsible block content>
```

### NEW — `commands/run-team.md`
A new slash command (mirrors the existing kebab-case naming). Frontmatter:
```yaml
description: Run an implementer/reviewer team against a team-tasks.md file
argument-hint: [--from-tasks <path/to/team-tasks.md>] [--max-review-rounds <n>] [--skip-verify]
```

Body is the **lead prompt**, structured similarly to other cerberus commands:

- **Phase 0: Preflight (hard gates — abort with a clear error if any fail)**:
  - **Agent teams enabled and supported version**: this command depends on Claude Code's agent-teams feature, which is experimental and disabled by default (per https://code.claude.com/docs/en/agent-teams).
    - Verify `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` is set in the shell env or in `~/.claude/settings.json` `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`. If not set, abort with: "Agent teams are disabled. Enable them by adding CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 to your shell env or to ~/.claude/settings.json (env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS), then restart Claude Code."
    - Verify Claude Code version is v2.1.32 or later. Run `claude --version` (or read the version another way; `claude --version` is documented as the canonical way to check). Compare to `2.1.32` semver-style. If older, abort with: "Agent teams require Claude Code v2.1.32 or later (you have <detected_version>). Upgrade Claude Code, then retry."
  - **Clean tracked files**: `git status --porcelain --untracked-files=no` must be empty. Implementers commit directly on the current branch in the shared tree, and the implementer's "scoped staging" hard rule forbids `git add -A`/`.`, so untracked files (build artifacts, local notes, etc.) are safe to ignore — but any *modified or staged* tracked file would get swept into the implementer's commits if they slipped past the scoped-staging rule, and would taint the review baseline. Abort with: "Working tree has uncommitted changes to tracked files. Commit, stash, or discard them before running /cerberus:run-team. Untracked files are OK and will be left alone."
  - **Branch is the repo's default branch**: warn but do not abort if on a feature branch — the user may intentionally be running this on a workstream branch.
  - **review-gate per-call session keying confirmed**: this plan relies on `REVIEW_GATE_SESSION_KEY` env var being honored by `spawn-code-review` and on `--session-key` being honored by `wait`. Both are present in `bin/review-gate` today (verified: `bin/review-gate:2116` reads `REVIEW_GATE_SESSION_KEY`; `bin/review-gate:77` documents `--session-key` on `wait`; `bin/review-gate` `resolve` is dispatched at the main switch and is used by the hook on infra failure to clear pending state). Re-confirm during implementation.
  - **jq available**: `jq` must be on `PATH`; task state creation, hook input parsing, and duplicate-idle suppression all depend on it. Abort with: "/cerberus:run-team requires jq for task state, hook input parsing, and duplicate idle suppression. Install jq, then retry."
- **Phase 1: Load** — resolve `--from-tasks`: if explicit, use it; otherwise auto-detect by finding the most recent `*-plan.md` in `docs/` or `~/.claude/plans/` (mirroring how `create-tasks` resolves `--from-plan`) and looking for a `*-team-tasks.md` adjacent to it (matching the prefix-based naming above). Error if zero or multiple candidates. Parse YAML frontmatter + each task's `meta` block, including `phase` when present; build dependency graph; preserve execution phase order from the Task Summary table when available. Resolve `--max-review-rounds` (default 5) and `--skip-verify` (default false, applies to all phase-level epic verifier invocations, not to the per-task project verification gate).
- **Phase 1.5: Project verification discovery (hard gate before team start)** — before `TeamCreate`, `TaskCreate`, or any implementer `Agent` call, the lead discovers the project-specific verification commands.
  - Discover commands from repo guidance and existing automation, in priority order: applicable `AGENTS.md` instructions; README/contributor docs; CI workflows; package/build manifests (`package.json`, `Makefile`, `pyproject.toml`, `tox.ini`, `noxfile.py`, `Cargo.toml`, `go.mod`, etc.); existing scripts under `bin/` or `scripts/`.
  - Choose the smallest command set that collectively covers lint/static checks, build/typecheck/compile, and tests for this repository. Prefer documented or CI-backed commands over invented commands. Avoid deployment, publishing, watch modes, destructive cleanup, or commands requiring secrets unless repo guidance explicitly requires them.
  - Do not ask for routine confirmation when commands are documented, CI-backed, or strongly implied by project manifests. Ask only when every viable command is destructive, deploys/publishes externally, requires secrets/credentials, mutates production data, or task source ambiguity could send implementers at the wrong work.
  - Record the chosen command list plus missing coverage categories in the final report.
  - If the user explicitly confirms that no automated verification should run, write an explicit no-op script that prints that decision. Do not silently omit verification state; the hook fails closed if the resolved script is absent.
  - Persist the resolved commands as `${TMPDIR:-/tmp}/cerberus-task-completed-hook/<team_hash>/verify.sh`; every per-task `state.json` stores `verify_script_path` pointing to that script. The `TaskCompleted` hook runs this script after commit/trailer guards and before `spawn-code-review`.
- **Phase 2: Team setup and scheduling** — **strictly serial in the initial cut** (max 1 implementer at a time). Reasons: (a) all implementers share the same working tree, so concurrent edits would conflict; (b) review-gate state is keyed per top-level session — concurrent hook invocations would clobber each other (see open question 2). With strict serialization, dependent tasks (e.g., T002 depends on T001) automatically see prior commits in the working tree because T001 has finished and committed before T002 is spawned.
  - **Team setup (once, at start)**:
    1. Compute a short hash unique to this invocation from: the team-tasks.md path + an ISO timestamp **with second precision** + 8 hex chars from `/dev/urandom`. Take the first ~10 hex chars of the SHA-256 digest. This guarantees uniqueness across same-day reruns and concurrent runs (a path + calendar-date hash would collide on any same-day retry, inheriting stale state from the prior failed run — see Phase 4 cleanup policy). Concrete example using POSIX-portable tools (`shasum` or `sha256sum`; `head` + `xxd`):
       ```
       team_hash=$(printf '%s|%s|%s' "$tasks_path" "$(date -u +%Y%m%dT%H%M%SZ)" "$(head -c 4 /dev/urandom | xxd -p)" | { command -v shasum >/dev/null && shasum -a 256 || sha256sum; } | cut -c1-10)
       ```
       The `command -v shasum || sha256sum` switch handles both macOS (which ships `shasum`) and most Linux distros (which ship `sha256sum`). Both produce the same digest format (`<hex> <filename>`), so `cut -c1-10` works on either.
    2. **Pre-clean state dir (defense in depth)**: `mkdir -p "${TMPDIR:-/tmp}/cerberus-task-completed-hook/${team_hash}"`. By construction (timestamp + random in `team_hash`), this directory cannot already exist with stale content. If `[ -e "${TMPDIR:-/tmp}/cerberus-task-completed-hook/${team_hash}" ] && [ -n "$(ls -A "${TMPDIR:-/tmp}/cerberus-task-completed-hook/${team_hash}" 2>/dev/null)" ]` (extreme clock-skew or `/dev/urandom` collision), abort with a clear error rather than silently inheriting stale state: "team_hash collision detected at <path>; refusing to overwrite. Re-run /cerberus:run-team to get a fresh team_hash, or wipe the directory manually if you know it's safe."
    3. Write the resolved verification script to `${TMPDIR:-/tmp}/cerberus-task-completed-hook/${team_hash}/verify.sh`, with `set -euo pipefail` followed by the resolved commands. This happens after verification-gate resolution but before `TeamCreate`, so the hook can fail closed if the script is missing.
    4. `TeamCreate(team_name: "cerberus-impl-<hash>", description: "Run team for <feature>", agent_type: "team-lead")`. **Collision detection**: in the rare case `TeamCreate` returns an "already exists" error (e.g., partial cleanup from a prior run left the team config at `~/.claude/teams/cerberus-impl-<hash>/config.json`), abort with a clear message: "Team 'cerberus-impl-<hash>' already exists (likely from an interrupted prior run). Run `TeamDelete` on it from a Claude session and retry /cerberus:run-team."
    5. For each cerberus task T### in the parsed file: `TaskCreate(subject: "[CERBERUS-IMPL/<team_hash>] T### — <subject>", description: <full task spec body>, metadata: { cerberus_task_id: "T###", cerberus_team_hash: "<team_hash>", cerberus_assigned_teammate: "impl-T###", cerberus_state_dir: "${TMPDIR:-/tmp}/cerberus-task-completed-hook/<team_hash>/T###", cerberus_files: [...], cerberus_depends: [...] })`. Do not set TaskList `owner` and do not mark the task `in_progress`; assignment is established by the teammate name, metadata, persistent task context, and bootstrap pointer. Capture the returned Claude task IDs and remember the cerberus T### → Claude task-id mapping. The `[CERBERUS-IMPL/<team_hash>]` subject prefix and the `cerberus_task_id` + `cerberus_team_hash` metadata are **both** what the hook keys on for disambiguation; `cerberus_state_dir` is the preferred absolute path for locating per-task state without depending on the hook runtime's `TMPDIR`. The prefix is the cheap first filter (and a fallback source of the team_hash if metadata is not exposed at runtime), the metadata is the canonical source of task ID, team_hash, and state directory when exposed.
  - **Lead's hard rules** (these go in the lead prompt verbatim):
    - **The lead MUST NOT call `TaskUpdate(status: "completed")` on any task in this team's task list.** Task completion is owned exclusively by implementer teammates. This invariant is what makes the no-matcher `TaskCompleted` hook safe to gate the review flow on every fire.
    - The lead MUST NOT call `TaskUpdate(owner: …)` or `TaskUpdate(status: "in_progress")` for Cerberus implementer tasks. Owner/in-progress updates can enqueue delayed `task_assignment` messages. The lead may call `TaskUpdate(status: "deleted")` for cancellation, but must never move a task to `completed`.
    - The lead never edits files itself — only writes per-task state files via Bash and spawns teammates via Agent.
    - The lead never invokes `/cerberus:review-code` directly — review fires automatically via the `TaskCompleted` hook.
  - **Scheduling loop**:
    - Initialize: ready set = cerberus tasks with empty `depends`.
    - Pick one ready task (lowest ID first). Before spawning:
      1. **Create the per-task state dir and persistent context dir**: `mkdir -p "${TMPDIR:-/tmp}/cerberus-task-completed-hook/${team_hash}/${task_id}" "${TMPDIR:-/tmp}/cerberus-task-completed-hook/${team_hash}/task-contexts"`. The `${team_hash}/` parent was created in team-setup, but the per-task subdirectory and context directory may not exist, so without this `mkdir` the subsequent `state.json` / task context / `untracked_baseline.txt` writes would fail with `ENOENT` and the hook would fall into the `_unknown_<pid>` recovery path on the very first task.
      2. `git rev-parse HEAD` → write to per-task state file at `${TMPDIR:-/tmp}/cerberus-task-completed-hook/<team_hash>/<task_id>/state.json` containing `{ "task_id": "T001", "claude_task_id": "<id>", "team_hash": "<hash>", "baseline_sha": "<sha>", "round": 0, "max_rounds": <resolved>, "task_state_dir": "...", "task_context_path": "${state_root}/task-contexts/T001.md", "verify_script_path": "${state_root}/verify.sh" }`. The `<team_hash>` namespace ensures that retries of the same plan (different invocation → different team_hash, by construction from timestamp + random) and reruns of the same task ID across plans never inherit stale `exhausted` or `last_error` markers from earlier runs.
      3. Write a persistent task-context file at `${state_root}/task-contexts/${task_id}.md` containing the task spec body, files list, dependencies, acceptance criteria from `team-tasks.md`, and the resolved verification script path (the same task content the implementer is given, plus the gate the hook will enforce). Do not store canonical task context only under `${state_dir}`: successful hook state dirs are deleted after task success, but phase verification and `epic-gap` remediation may need immutable task context later. The hook will pass this to `spawn-code-review` via `--context-file` so reviewers see task background, not just the diff; the hook also injects the verification pass summary as `REVIEW_GATE_AUTHOR_CONTEXT` so reviewers can rely on the resolved lint/build/test evidence.
      4. Snapshot the current untracked set: `git status --porcelain -z | tr '\0' '\n' | awk '/^\?\? / { print substr($0, 4) }' > "${state_dir}/untracked_baseline.txt"`. We use `git status --porcelain -z` (NUL-separated) instead of plain porcelain so paths containing spaces or special characters are not quoted/escaped and split incorrectly. The pipeline pipes through `tr '\0' '\n'` to convert NUL terminators to newlines (POSIX-clean on both BSD and GNU; macOS BSD awk does not honor `RS='\0'` — verified empirically, it treats the string as a literal backslash-zero and reads the entire `git status -z` output as a single record — so `tr` is the portable choice), then awk's default newline-RS strips the leading `?? ` via `substr($0, 4)` (3 chars + 1-based indexing). The resulting file is newline-separated for human readability and easy `diff`-style comparison; paths containing literal newlines (extremely rare; would require `core.quotePath=false` and an actual `\n` in the filename) are a known edge case the V1 does not handle.
      5. `Agent({ team_name: "cerberus-impl-<hash>", name: "impl-T001", subagent_type: "implementer", model: "opus", description: "T001 implement <subject>", prompt: <bootstrap pointer with CERBERUS_TASK_ID=T001 + Claude task id + task context path + STATE_DIR=${TMPDIR:-/tmp}/cerberus-task-completed-hook/<team_hash>/T001 + VERIFY_SCRIPT=${TMPDIR:-/tmp}/cerberus-task-completed-hook/<team_hash>/verify.sh> })`. The prompt is not canonical assignment and must be safe if delivered late; the implementer reads TaskList metadata and the persistent task context. Each task gets a fresh `name`, so each task spawns a **fresh teammate with no prior context**. Within this teammate's lifetime, the implementer/reviewer retry loop is in-context (the same teammate sees verification failures and review findings on stderr and retries). The `STATE_DIR` injection gives the implementer a concrete path to `touch` — without it, the implementer would have to compute the path itself from team_hash + task_id, which is fragile.
    - **Wait for outcome.** The lead receives `TeammateIdle` notifications automatically when the teammate stops working. The Cerberus `TeammateIdle` hook allows the first idle signal through and stops duplicate idle firings for the same single-use implementer. After the first idle, the lead inspects:
      - The Claude TaskList task's status (use `TaskGet`): `completed` or not completed. Cerberus tasks may remain `pending` while work is underway.
      - Per-task state markers in `${state_dir}`: `exhausted`, `last_error`.
      - Any messages received from the teammate (e.g., `STATUS: NEEDS_HUMAN T###`).
      The five outcome categories:
      - **success** — Claude task status is `completed`, no `exhausted` marker, no `last_error` marker, both `${state_dir}/verified_pass` and `${state_dir}/reviewed_pass` markers are present, AND `${state_dir}/verified_head` plus `${state_dir}/reviewed_head` both equal `git rev-parse HEAD` (positive evidence that the hook ran the resolved verification gate and code review against the current code). Without both markers and matching head files, the success classification is INVALID and the lead must downgrade to `unverified-failure` (see below). Provisionally classify as success (do NOT yet mark T### done or delete state dir). Run the post-task clean-tree gate (see below). If both gate checks pass: mark cerberus T### done in the lead's local tracking, **then** delete only the per-task hook state directory at `${TMPDIR:-/tmp}/cerberus-task-completed-hook/<team_hash>/<task_id>/`; keep `${state_root}/task-contexts/${task_id}.md` for phase verification and remediation; recompute ready set. If either gate check fails: downgrade to unverified-failure (per the existing rule), retain state dir, stop scheduling.
      - **needs-human** — classify as needs-human if EITHER (a) the teammate sent a `STATUS: NEEDS_HUMAN T###` message AND the Claude task is not completed, OR (b) the `exhausted` marker is present AND the Claude task is not completed (regardless of whether the NEEDS_HUMAN message was received). Rationale: the marker is authoritative — the hook wrote it because review rounds were exhausted, so the task cannot succeed even if the implementer didn't escalate cleanly. Mark failed; retain state dir; stop scheduling (see Phase 3).
      - **unverified-failure** — any of the following: (a) Claude task status is `completed` AND `exhausted` marker present (the implementer ignored the post-exhaustion rule and somehow got `TaskUpdate(completed)` past the hook — should be impossible if the hook is correct, but the lead defends against it); or (b) Claude task status is `completed` AND no `exhausted` marker AND no `last_error` marker AND either `verified_pass`/`reviewed_pass` is missing or `verified_head`/`reviewed_head` does not equal current `HEAD` — "task marked completed but missing positive verification/review evidence for the current HEAD — hook did not run, did not run the resolved project verification gate, did not run review to PASS, or HEAD changed after the gate. Possible causes: TaskCompleted input field mismatch (the prefix filter received empty subject), hook script error, missing `verify_script_path`, runtime hook-firing variance, or external worktree mutation." Mark failed; retain state dir; stop scheduling.
      - **infra-failure** — `last_error` marker present (review-gate ERROR / no_reviewers / PENDING / timeout, or the missing-state recovery path where the hook could not resolve the `<team_hash>/<task_id>` state dir and falls back to a per-PID `${TMPDIR:-/tmp}/cerberus-task-completed-hook/_unknown_<pid>/last_error`). Claude task status is typically not completed (hook blocked the completion). Mark failed; retain state dir; surface the raw wait JSON from `last_error` in the final report; stop scheduling. (The fallback is per-PID rather than a shared `_unknown` so concurrent or sequential runs that hit the missing-state path do not clobber each other's `last_error`.)
      - **abandoned** — Claude task is not completed, the teammate has gone idle (TeammateIdle received), AND none of the above markers/messages apply (no `exhausted`, no `last_error`, no `NEEDS_HUMAN` message, no `completed` status). The teammate left work unfinished without escalating — the implementer ignored its prompt rule (e.g., confused itself, the hook errored in a way that bypassed marker writing, or the teammate's first turn ended without doing anything). Mark failed; retain state dir; stop scheduling. This is a model-behavior failure, not infra; the lead should surface a clear message in the final report distinguishing it from `needs-human` (e.g., "T### abandoned: implementer went idle without completing the task or escalating; this is a model-behavior bug, not an infra failure").
    - Also enforce a **post-task clean-tree gate**: after a `success` classification, run two checks in the repo root. These checks run BEFORE the success classification finalizes (i.e., before state dir cleanup), so they can read `${state_dir}/untracked_baseline.txt` written before spawning.
      - **Tracked-file check**: `git status --porcelain --untracked-files=no` must be empty. If non-empty, downgrade to **unverified-failure** with reason "task left modified tracked files outside its commits" — these would taint the next task's baseline.
      - **New-untracked check**: compute the current untracked set with `git status --porcelain -z | tr '\0' '\n' | awk '/^\?\? / { print substr($0, 4) }'` (NUL-separated, same pipeline as the snapshot — `tr '\0' '\n'` converts NUL terminators to newlines portably across BSD and GNU awk because BSD awk does not honor `RS='\0'`; verified empirically — and `substr($0, 4)` strips the leading `?? `; avoids quoting/escaping of paths with spaces or special characters) and compare against the snapshot in `${state_dir}/untracked_baseline.txt` written before spawning, e.g. `comm -23 <(sort current) <(sort baseline)`. Any path in the current set that is not in the baseline is a **new** untracked file. If any new untracked path exists, downgrade to **unverified-failure** with reason "task left new untracked file(s) outside its commits (forgot to `git add`?); these would be excluded from the reviewed commit range and taint the next task's working tree".
      On either failure, stop scheduling.
    - **Cleanly release the teammate after a terminal idle**: after outcome classification, the teammate has already produced the one idle signal the lead needs. The lead does not need to message it again, and should not rely on `shutdown_request` to quiet duplicate idle notifications. The `TeammateIdle` hook terminates repeated idle firings for `impl-T###`, and the fresh-teammate-per-task rule means we never reuse `impl-T001` for a later task — its name is task-bound by construction.
    - Repeat until ready set empty or any non-success outcome triggered "stop scheduling."
- **Phase 3: Failure handling** — on any non-success outcome, do *not* unblock dependents, retain the per-task state directory for debugging, and **stop scheduling further tasks** (including independent ones). Rationale: the failed task's commits are still on the current branch (no worktree), so any subsequent independent task would run with a tainted baseline — its own commit range would be clean (scoped by trailer), but its working tree and the code its reviewer reads would include the failed task's broken changes. The team runner does **not** auto-`git reset --hard` because (a) it cannot tell whether the partial work is salvageable or whether the user wants to inspect it, and (b) destructive resets without explicit confirmation violate cerberus's "carefully consider blast radius" norm. Instead, the lead surfaces in the final report: the failed task ID, its outcome category, its baseline SHA, the contents of any `last_error` marker, and the recommended manual recovery (`git reset --hard <baseline_sha>` or `git revert <commit_range>`), then proceeds to Phase 4 (which will skip verify-epic given the failure).
- **Phase 4: Epic verification + report**:
  - **Auto-verify-epic gate (NEW)**: after each execution phase completes successfully (no failures) AND `--skip-verify` is not set, the lead invokes the existing `/cerberus:verify-epic` command before scheduling any later-phase task. Non-final phases pass a generated criteria file containing all acceptance criteria assigned to phases completed so far; the final phase passes the full plan/spec path when available, preserving the full acceptance-criteria gate. Implementation: shell out to `${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-epic-verify`, exporting `REVIEW_GATE_SESSION_KEY` on the spawn so the matching `wait --session-key` can find the gate state (`wait` looks up gates via `find_state_by_session_key`, which only matches when the spawn was invoked with that env var set). Each verifier attempt uses a unique session key and review session so one phase's artifacts do not become another attempt's previous-review context. `spawn-epic-verify` also `die`s if `CLAUDE_SESSION_ID` is unset, so it must be present in the env — but the lead is itself a Claude session, so its Bash tool already has `CLAUDE_SESSION_ID` and `REVIEW_GATE_TRANSCRIPT_PATH` (or `CLAUDE_TRANSCRIPT_PATH`) automatically exported; only `REVIEW_GATE_SESSION_KEY` is per-invocation and must be set explicitly inline. Note: `spawn-epic-verify` does NOT accept a `--context-file` flag. Use this command shape per phase attempt:
    ```
    phase_verify_attempt="<1-based-attempt-number-for-this-phase>"
    VERIFY_KEY="cerberus-team-verify-${team_hash}-${phase_index}-${phase_slug}-attempt-${phase_verify_attempt}"
    VERIFY_SESSION_ID="${CLAUDE_SESSION_ID:-cerberus-team}-${VERIFY_KEY}"
    REVIEW_GATE_SESSION_KEY="$VERIFY_KEY" \
      "${CLAUDE_PLUGIN_ROOT}/bin/review-gate" spawn-epic-verify \
        --session-id "$VERIFY_SESSION_ID" \
        --consensus majority --mode fast \
        "<phase-criteria-file-or-plan-or-spec-path>"

    # Poll for verdict using the same key.
    verify_json=""
    verify_rc=0
    verify_json=$("${CLAUDE_PLUGIN_ROOT}/bin/review-gate" wait --json --finalize \
      --session-key "$VERIFY_KEY") || verify_rc=$?
    verify_verdict=$(printf '%s' "$verify_json" | jq -r '.consensus_verdict // empty' 2>/dev/null || true)
    ```
    The verdict is included in the final report. A FAIL, NEEDS_WORK, or inconsistent PASS-with-findings verdict is treated as an implementation gap, not an immediate terminal run failure. Before verifier spawn and before remediation spawn, the lead runs a teammate drain gate: in the normal strict-serial path no teammate is active, but if any teammate is still non-idle or capable of tool use, the lead sends a pause request, waits until idle/paused, and verifies clean tracked state and stable HEAD. If the team cannot be drained cleanly, stop as infrastructure failure. For implementation gaps, create a synthetic `epic-gap` task using the next unused `T###` ID. The gap task's context contains the verifier target, raw verifier JSON, aggregated findings, completed-phase criteria or plan/spec links, and current HEAD. The lead spawns a fresh Opus implementer for that synthetic task, and the normal `TaskCompleted` hook enforces scoped commits, project verification, and code review. If the gap implementer passes, the lead reruns the same phase verifier with a fresh attempt key; if it fails or the phase reaches `max_review_rounds` gap-fix attempts, stop scheduling and report `needs-human`. Verifier infrastructure failures (`ERROR`, timeout, missing verdict, or HEAD mutation during verification) do not spawn implementers; they stop for debugging. A gap implementer passing the normal task gates is not sufficient to pass the phase; it only permits another verifier attempt.
  - **Final report**: table of cerberus tasks (passed / failed / skipped) with commit hashes and review summaries; synthetic `epic-gap` remediation tasks with phase, triggering verdict, outcome, and commit ranges; the resolved per-task verification gate commands; for failed tasks, name the outcome category (`needs-human`, `unverified-failure`, `infra-failure`, or `abandoned`) so the user can distinguish model-behavior failures (`abandoned`) from infra failures and from clean human-escalations; the per-phase verify-epic verdicts + any findings; recovery instructions for any failures. **Retry guidance**: include a note that re-running `/cerberus:run-team` after fixing the root cause is safe — each invocation gets a fresh `team_hash` (timestamp + random) and therefore a fresh state directory, so users do **not** need to manually wipe `${TMPDIR:-/tmp}/cerberus-task-completed-hook/` between attempts. Stale state from a prior failed run remains on disk for debugging but cannot affect the new run.
  - **Cleanup policy**:
    - Delete per-task hook state directories under `${TMPDIR:-/tmp}/cerberus-task-completed-hook/<team_hash>/` only for tasks that **completed successfully**. Keep persistent task contexts under `${TMPDIR:-/tmp}/cerberus-task-completed-hook/<team_hash>/task-contexts/` for phase verification, remediation, and final reporting. Failed tasks' state dirs are retained for debugging at `${TMPDIR:-/tmp}/cerberus-task-completed-hook/<team_hash>/<task_id>/`. To wipe all state for this run after debugging, delete the entire `<team_hash>` subdirectory; this is safe because the team_hash is unique to this invocation (constructed from path + second-precision timestamp + 8 hex chars from `/dev/urandom`) and cannot collide with other plans, concurrent runs, or same-day retries.
    - Optionally call `TeamDelete` to tear down the team and its TaskList. By default, leave the team intact so the user can inspect the TaskList and final teammate states; tell them how to clean up manually with `TeamDelete` from the next session. (If the user is running in `--auto-cleanup` mode — out of scope for the initial cut — delete automatically.)

Note: `--max-parallel` is intentionally **not** exposed in this initial cut. Re-introducing it requires (a) per-task isolation (worktrees) and (b) per-session keying robustness in `bin/review-gate`. Tracked in open questions.

### NEW — `agents/implementer.md`
First custom subagent in cerberus, designed to be invoked as a **teammate** (`Agent({team_name, name, subagent_type: "implementer", …})`). Frontmatter:
```yaml
---
name: implementer
description: Implement a single team task in the current working tree, then signal completion via TaskUpdate(status:"completed"). Completion is gated by automated review; address findings until review passes.
tools: Read, Write, Edit, Bash, Grep, Glob, TaskGet, TaskUpdate, SendMessage
model: opus
---
```

Body (~80 lines), trimmed and adapted from `mala/src/prompts/implementer_prompt.md`:

- **Workflow**:
  1. The lead has assigned you a Claude TaskList task (subject prefixed `[CERBERUS-IMPL/<team_hash>] T### — …`). Read it via `TaskGet` to get the full spec, files list, and acceptance criteria. Capture the cerberus task ID `T###` from the subject prefix or the `metadata.cerberus_task_id` field. The lead also injected `CERBERUS_TASK_ID=T###` in the spawn prompt as redundant signal.
  2. Do not set TaskList `owner` and do not mark the task `in_progress`. The TaskList task may remain `pending` while work is underway; Cerberus lead-local state tracks the running teammate.
  3. Implement, run validation per repo conventions.
  4. Commit on the current branch (do not create a new branch and do not use worktrees) with subject `T###: <subject>` and **a required commit trailer line** `Cerberus-Task: T###`. Both the subject prefix and the trailer are mandatory — the `TaskCompleted` hook uses the trailer to identify which commits to send for review. Use `git commit --trailer Cerberus-Task=T###` (or any equivalent that places the trailer in its own paragraph at the end of the commit message) so `git interpret-trailers` and the hook's `%(trailers:key=Cerberus-Task,valueonly,...)` pretty-format parser pick it up correctly. Do NOT inline the trailer on the subject line — that form is not parseable as a trailer and will cause the hook's existence check to fail.
  5. **Signal readiness, then wait for completion permission**: after task-scoped commits are ready, send `STATUS: READY_FOR_COMPLETION T### — commits <short-shas>` and go idle. Do not touch `completion_intent` and do not call `TaskUpdate(status: "completed")` until the lead sends `PROCEED_TO_COMPLETE T###`.
  6. **Write completion-intent marker, then signal completion**: only after the lead grants `PROCEED_TO_COMPLETE T###`, write `Bash: touch "$STATE_DIR/completion_intent"`, then call `TaskUpdate(taskId: "<claude-task-id>", status: "completed")`. The hook checks for this marker as one of its first gates after ownership is established: if absent, the hook blocks completion with stderr telling you to wait for the lead grant, write the marker, and retry. The hook deletes the marker on every fire (success or failure) so each subsequent `TaskUpdate(completed)` requires a fresh lead grant and fresh `touch`.

     This fires the `TaskCompleted` hook, which runs review.
  7. The hook will either:
     - **Allow the completion through (exit 0)** — review passed; `TaskUpdate` succeeds; the task is now `completed`; you go idle. The lead detects success via TaskList state.
     - **Block the completion (exit 2 with stderr feedback)** — review found blocking issues. You will see the findings in your context (the stderr is injected as feedback). Fix the issues, recommit (new commit, also tagged `Cerberus-Task: T###`), send a fresh `STATUS: READY_FOR_COMPLETION T### — commits <short-shas>`, and wait for a fresh `PROCEED_TO_COMPLETE T###` before touching `completion_intent` and retrying completion.
- **Output template** — terse structured summary in your response: `Implemented`, `Files`, `Tests`, `Commits` (list of SHAs).
- **Hard rules**:
  - Never run `git push`; do not modify history beyond your own commits; do not invoke `/cerberus:review-code` directly (the hook handles it).
  - **Scoped staging**: never `git add -A` or `git add .`. Stage only the files listed in your task's `meta.files` list, plus any new files you intentionally create within scope, plus deletions and renames/moves of in-scope paths (e.g., `git rm <file>` or `git add` after `git mv`). Rationale: implementers share the working tree on the current branch, so a wildcard add could capture unrelated files left behind by another task or by the user.
  - **Final-round signal**: the hook's stderr feedback includes a "round X of MAX" counter. When the hook tells you that you have just used your final reviewed round (round `max_rounds - 1`), AND the verdict was FAIL: review will not run again on a retry. The hook will short-circuit your next `TaskUpdate(status: "completed")` and refuse to allow it through (it will write an `exhausted` marker and exit 2). You **MUST NOT** retry `TaskUpdate(status: "completed")` after a final-round failure. Instead, send a message to the lead via `SendMessage({to: "<lead-name>", message: "STATUS: NEEDS_HUMAN T### — exhausted review rounds", summary: "needs human"})`, leave the task not completed, and go idle. The lead will detect this and stop scheduling.
  - **Infra-failure signal**: if the hook's stderr indicates an infra failure (review-gate ERROR / no_reviewers / timeout — explicitly labeled in the feedback), do not retry. Send `SendMessage(STATUS: NEEDS_HUMAN T### — infra failure)` to the lead and go idle. The lead's classifier will detect the `last_error` marker and report.
  - **Reviewer-context block**: the "False Positives / Resolved / Questions" subsection from `mala/src/prompts/implementer_prompt.md:309-337` is **deliberately omitted** from this initial cut. Rationale: review-gate spawns reviewers from a commit range only — a structured stop message is not part of reviewer input, so a "False Positives / Resolved / Questions" subsection would not be visible to the next round of reviewers. Re-introducing this requires extending `bin/review-gate spawn-code-review` to accept implementer notes (write to a file the reviewer prompt reads); tracked in open questions. Until then, the implementer responds to findings only by changing code or by escalating.

### MODIFY — `hooks/hooks.json`
Add `TaskCompleted` and `TeammateIdle` entries. Neither supports matchers, so both scripts self-gate on Cerberus team/task naming before doing anything:

```json
{
  "hooks": {
    "SessionStart": [...existing...],
    "Stop": [...existing...],
    "TaskCompleted": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/bin/cerberus-task-completed-hook",
            "timeout": 2100
          }
        ]
      }
    ],
    "TeammateIdle": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/bin/cerberus-teammate-idle-hook",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

The hooks are registered globally on this plugin, but each script's first action is to bail out (exit 0) unless the event belongs to a Cerberus implementer task/team. So unrelated task lists and unrelated agent teams are unaffected.

### NEW — `bin/cerberus-teammate-idle-hook`
Small command hook for `TeammateIdle`. It applies only when `team_name` matches `cerberus-impl-*` and `teammate_name` (or `from`) matches `impl-T###`. It writes an atomic team-level marker at `${TMPDIR:-/tmp}/cerberus-task-completed-hook/<team_hash>/.teammate-idle/<teammate>.seen` on the first idle and exits 0 so the lead receives one idle notification. On a repeated idle for the same single-use implementer, it prints JSON `{"continue": false, "stopReason": "..."}` and exits 0, terminating the parked teammate instead of letting Claude Code emit unbounded duplicate idle notifications.

### NEW — `bin/cerberus-task-completed-hook`
Bash script following cerberus's existing bin conventions (compare `bin/review-gate-hook.sh`). Runs under `set -euo pipefail`. Responsibilities:

1. **Read hook input JSON from stdin** with the documented `TaskCompleted` fields: `hook_event_name`, `session_id`, `transcript_path`, `cwd`, `task_id` (Claude task list ID), and the task subject. Read the subject defensively — per https://code.claude.com/docs/en/hooks, TaskCompleted's per-event input field names are not enumerated in the docs (only common fields like `session_id`, `transcript_path`, `cwd`, `hook_event_name` are documented). Read both `task_subject` and `task_name` to be robust against runtime/version differences:
   ```
   subject=$(jq -r '.task_subject // .task_name // ""' <<< "$hook_input")
   ```
   If both are empty, treat as "field not exposed by the runtime" — the hook then bails (exit 0) at the prefix-filter step below, but the lead's success classifier (see Phase 2 of `run-team.md`) requires positive proof of verification and review (the `verified_pass` and `reviewed_pass` markers) and will catch this case as `unverified-failure` rather than mis-classifying as success. Defensive: if `hook_event_name != "TaskCompleted"`, `exit 0`.

   **Export env at script scope for all `bin/review-gate` invocations.** Hooks do not inherit the parent Claude session's env, so the hook script must explicitly export `CLAUDE_SESSION_ID` and `REVIEW_GATE_TRANSCRIPT_PATH` from the hook input JSON. Doing this once at script scope makes both `spawn-code-review` (which `die`s if `CLAUDE_SESSION_ID` is unset, `bin/review-gate:689`) and `wait --finalize` (which reads both env vars at `bin/review-gate:2913-2914`) work without per-call env duplication:
   ```
   # After parsing hook input from stdin and computing local vars:
   export CLAUDE_SESSION_ID="$session_id"
   export REVIEW_GATE_TRANSCRIPT_PATH="$transcript_path"
   ```

2. **Cheap first filter (subject prefix)**. If `subject` does not begin with `[CERBERUS-IMPL/` (followed by a `<team_hash>]` segment), this is some other task list (or the runtime did not expose the subject field) — `exit 0` immediately. This is what makes the no-matcher hook safe across unrelated TaskLists.

3. **Resolve cerberus task ID, team_hash, and locate state file.** Multiple paths in priority order:
   - **Primary (task ID)**: parse `T###` out of `task_name` (it follows the prefix as `[CERBERUS-IMPL/<team_hash>] T### — <subject>`).
   - **Primary (team_hash)**: read `metadata.cerberus_team_hash` from hook input. **Fallback**: parse `<team_hash>` out of the subject prefix (`[CERBERUS-IMPL/<team_hash>]`). Recommended: try metadata first; fall back to subject-prefix parsing if the runtime does not expose `task_metadata` on `TaskCompleted` input (see open question 6).
   - **Primary (state directory)**: read `metadata.cerberus_state_dir` from hook input and prefer it when present. This avoids assuming the lead and hook runtime share the same `TMPDIR` value.
   - **Fallback (task ID, defensive)**: search hook input for a `metadata.cerberus_task_id` field if the runtime exposes it; otherwise grep recent transcript entries for `CERBERUS_TASK_ID=T###`.
   - Read the state file at `metadata.cerberus_state_dir/state.json` when metadata is exposed; otherwise fall back to `${TMPDIR:-/tmp}/cerberus-task-completed-hook/<team_hash>/<task_id>/state.json`. If the state file is missing despite the prefix matching, ownership has already been established, so fail closed: compute a fallback state dir at `${TMPDIR:-/tmp}/cerberus-task-completed-hook/_unknown_${pid}` if needed, write a sentinel marker file `${state_dir}/last_error` containing `state_unresolvable: subject prefix matched but no state file found at ${expected_path}`, and exit 2 with an `INFRA-FAILURE` stderr message. The implementer should SendMessage NEEDS_HUMAN and go idle; the lead's classifier surfaces the retained marker.

3.3. **Normalize to the repository root.** After the state file is resolved, verify the hook `cwd` is inside a Git worktree, compute `repo_root=$(git rev-parse --show-toplevel)`, and `cd "$repo_root"` before commit-range checks, verification, and review. Project verification commands are repository-level commands; running them from an arbitrary hook `cwd` could fail or verify the wrong scope.

3.4. **Completion-intent gate.** Read `${state_dir}/completion_intent`; if absent, block completion with exit 2 and stderr telling the implementer to wait for the lead's `PROCEED_TO_COMPLETE T###`, then run `touch "${state_dir}/completion_intent"` immediately before retrying `TaskUpdate(status:'completed')`. For a `[CERBERUS-IMPL/<team_hash>]` task, missing intent must fail closed rather than allow an owned Cerberus task to complete without verification and review. If present, **delete it** before proceeding (so each subsequent `TaskUpdate(completed)` requires a fresh lead grant and fresh `touch` from the implementer):
   ```
   if [[ ! -f "${state_dir}/completion_intent" ]]; then
     printf 'CERBERUS VERIFY: missing completion_intent marker for %s. After the lead grants PROCEED_TO_COMPLETE, run: touch "%s/completion_intent", then retry TaskUpdate(status:'"'"'completed'"'"').\n' "$task_id" "$state_dir" >&2
     exit 2
   fi
   rm -f "${state_dir}/completion_intent"
   ```
   This is a fail-closed guard. The implementer's prompt requires a lead `PROCEED_TO_COMPLETE` grant before the `touch` immediately preceding `TaskUpdate(completed)`, and missing it should not allow an owned Cerberus task to complete without verification and review.

3.5. **Idempotent on prior PASS (defensive).** If a previous `TaskCompleted` invocation for this same task already passed both the resolved verification gate and review, this is a re-fire. Let it through without re-running verification or review:
   ```
   # Idempotent on prior PASS: if a previous TaskCompleted already passed verification and review,
   # this is a re-fire (e.g., runtime variance, docs change, or retry storm).
   # Let it through without re-running verification or review.
   current_head=$(git rev-parse HEAD)
   if [[ -f "${state_dir}/verified_pass" && -f "${state_dir}/reviewed_pass" && \
         "$(cat "${state_dir}/verified_head")" == "$current_head" && \
         "$(cat "${state_dir}/reviewed_head")" == "$current_head" ]]; then
     exit 0
   fi
   ```
   **Defensive idempotency.** The hook short-circuits if both positive-evidence markers already exist for the current `HEAD`. Without this guard, a re-fire after a successful first pass would rerun verification and burn an additional review round (and possibly fail spuriously). With the guard, the second fire is a no-op only when the exact current code was already verified and reviewed.

4. **Short-circuit on max rounds (exhaustion).** Read `round` and `max_rounds` from the state file. If `round >= max_rounds`, write a marker file `${state_dir}/exhausted` and **exit 2 with stderr feedback** telling the implementer: "Already exhausted (round=$round, max=$max_rounds). Do not retry TaskUpdate(status:'completed'). SendMessage NEEDS_HUMAN T### to the lead and go idle." Do not invoke review-gate. The `TaskUpdate` will not go through; the task remains not completed; the lead's classifier sees `exhausted` + not-completed task status + (eventually) a NEEDS_HUMAN message.

   **Round-counter semantics (locked).** `max_rounds` = the number of review cycles permitted. The implementer gets up to `max_rounds` reviewed `TaskUpdate(completed)` attempts. All boundary checks compare the value of `round` **as read from disk, before any increment in this hook invocation**. With `max_rounds=5`, the sequence is: TaskUpdate #1 → round=0 read, review fires; TaskUpdate #2 → round=1 read, review fires; TaskUpdate #3 → round=2 read, review fires; TaskUpdate #4 → round=3 read, review fires; TaskUpdate #5 → round=4 read, review fires (final-round warning emitted in stderr); TaskUpdate #6 → round=5 read, short-circuits with `exhausted` marker + exit 2 (no review). The implementer is required by the prompt rule to send NEEDS_HUMAN and go idle rather than attempt #6 in the first place; the short-circuit is defense in depth.

5. **Derive commit range and run trailer guards.** With `baseline_sha` from the state file and the `Cerberus-Task: T###` trailer enforced on every implementer commit, use git's first-class trailer parser (avoids `--grep` regex-anchoring portability issues across BRE/ERE/PCRE — see `git interpret-trailers` and the `%(trailers:...)` pretty format):
   ```
   candidate_head=$(git rev-parse HEAD)
   commit_range="${baseline_sha}..${candidate_head}"
   # Existence guard: at least one commit in this range must carry the trailer for this task.
   commits_for_task=$(git log --pretty='%H %(trailers:key=Cerberus-Task,valueonly,separator=%x20)' "${commit_range}" \
                      | awk -v t="${task_id}" '$2 == t { print $1 }')
   ```
   Freezing `candidate_head` makes every downstream gate operate on the same commit range. If `HEAD` changes after trailer validation, block before verification/review because the current code was not fully validated.

   If `commits_for_task` is empty: **increment `round` in `state.json` first** (so a malformed-commit loop still hits the `round >= max_rounds` short-circuit in step 4), then **exit 2 with stderr** telling the implementer to make at least one task-scoped commit with the required trailer (`Cerberus-Task: ${task_id}`), send a fresh `STATUS: READY_FOR_COMPLETION T### — commits <short-shas>`, wait for a fresh `PROCEED_TO_COMPLETE T###`, touch `completion_intent`, and only then retry completion. Include `Round <r> of <max_rounds>` in the feedback.

   **Untagged-commit guard (range-contract enforcement).** After the existence check passes, compute the inverse set: commits in `${commit_range}` that do **not** carry this task's trailer.
   ```
   untagged_in_range=$(git log --pretty='%H %(trailers:key=Cerberus-Task,valueonly,separator=%x20)' "${commit_range}" \
                      | awk -v t="${task_id}" 'NF==1 || $2 != t { print $1 }')
   ```
   If non-empty: increment `round` first, then exit 2 with stderr telling the implementer to fix only its own malformed commits as allowed by the current implementer rules, create a task-scoped correction commit if needed, send a fresh `STATUS: READY_FOR_COMPLETION T### — commits <short-shas>`, wait for a fresh `PROCEED_TO_COMPLETE T###`, touch `completion_intent`, and only then retry completion. Same rationale as the original SubagentStop design: step 7 sends the full range to `spawn-code-review`, so any untagged commit would otherwise be reviewed as in-scope, smuggling unrelated changes through the gate.

6. **Run the resolved project verification gate before review.** Read `verify_script_path` from `state.json`; fail closed as `INFRA-FAILURE` if it is missing or the file does not exist. The lead writes this script only after verification-gate resolution in Phase 1.5, so missing state means the run was started incorrectly.
   - Before running the script, require `git status --porcelain --untracked-files=no` to be empty and compare current untracked paths against `${state_dir}/untracked_baseline.txt`. If tracked changes or new untracked files exist, exit 2 with stderr telling the implementer to commit, remove, or ignore them before retrying. This guarantees the code being verified is exactly the code reviewers will see in `baseline..HEAD`.
   - Run the script from the repo root with `set -euo pipefail` already present in the script. Export useful context for advanced project checks: `CERBERUS_TASK_ID`, `CERBERUS_TEAM_HASH`, `CERBERUS_STATE_DIR`, `CERBERUS_COMMIT_RANGE`, `CERBERUS_BASELINE_SHA`, and `CERBERUS_TASK_CONTEXT_PATH`.
   - Capture stdout/stderr to `${state_dir}/verify-round${round}.log`. If the script exits nonzero, write/touch `${state_dir}/verify_failed`, exit 2, and include the last ~200 log lines in stderr feedback. Do **not** increment the review round; reviewers were not spawned.
   - Capture `HEAD` before running the script and verify `HEAD` is unchanged after it passes. If the verification script changes `HEAD`, write `last_error` and block with stderr explaining that verification commands must not create commits.
   - After the script passes, run the same clean-tree/untracked check again to catch generated artifacts. Then remove `verify_failed`, write the verified head SHA to `${state_dir}/verified_head`, touch `${state_dir}/verified_pass`, and prepare a verification summary (script path, script contents, and output tail) to pass to `spawn-code-review` via `REVIEW_GATE_AUTHOR_CONTEXT` so reviewers can rely on the resolved lint/build/test evidence.

7. **Spawn review** with the range as a positional argument. Verified facts about the current CLI (see `bin/review-gate:57,77,349,2116,3393`):
   - `spawn-code-review` reads `REVIEW_GATE_SESSION_KEY` from the environment to scope state. It rejects unknown options with `die "Unknown option"`, so `--session-key` cannot be passed to `spawn-code-review` (only to `wait`).
   - `spawn-code-review` accepts `--context-file <path>` to inject task context for reviewers (per the usage line at `bin/review-gate:57` and the flag's purpose at `bin/review-gate:349`: "Inject task context from file (provides background for reviewers)"). The hook passes the lead-written task-context file here so reviewers see the task spec, files list, dependencies, and acceptance criteria — not just a diff.
   - `wait` accepts `--session-key`.
   - `--max-rounds 0` "disables auto-respawn"; `--max-rounds > 0` causes review-gate to spawn its own Claude fixer subagent on FAIL, which would clash with the implementer's retry loop. Pass `--max-rounds 0`.
   - `bin/review-gate resolve` only accepts `--reason` and is scoped by `CLAUDE_SESSION_ID` env / `REVIEW_GATE_TRANSCRIPT_PATH` (verified `bin/review-gate:2778-2822`); there is no `--session-key` lookup path. Per-round gate state is therefore intentionally not auto-cleaned: stale per-round gate files use a different `REVIEW_GATE_SESSION_KEY` from the parent session's gate, so they do not block the parent Stop hook (which calls `bin/review-gate check` against the parent session's gate, no `--session-key`); they accumulate as inert files in the cerberus state directory and can be cleaned up manually if desired.

   `CLAUDE_SESSION_ID` and `REVIEW_GATE_TRANSCRIPT_PATH` are already exported at script scope (see step 1), so `spawn-code-review` (which `die`s if `CLAUDE_SESSION_ID` is unset, `bin/review-gate:689`) inherits them from the script env. Only `REVIEW_GATE_SESSION_KEY` is set inline because it's per-invocation (scoped to one round). `spawn-code-review` itself must be captured under `set -e` (same pattern as `wait`):
   ```
   SESSION_KEY="cerberus-impl-${team_hash}-${task_id}-round${round}"
   # The `team_hash` prefix isolates concurrent team runs that may share task IDs
   # (e.g., two runs both reviewing T001 round 0). Without the prefix,
   # `wait --session-key`'s global search across
   # `~/.claude/projects/*/cerberus/*/gate-state.json` could attach to the wrong gate.
   spawn_rc=0
   REVIEW_GATE_SESSION_KEY="$SESSION_KEY" \
     REVIEW_GATE_AUTHOR_CONTEXT="$verification_author_context" \
     "${CLAUDE_PLUGIN_ROOT}/bin/review-gate" spawn-code-review \
       --max-rounds 0 --consensus majority --mode fast \
       --context-file "$task_context_path" \
       "$commit_range" || spawn_rc=$?
   if [[ $spawn_rc -ne 0 ]]; then
     # Spawn itself failed (die path: missing env, jq missing, malformed range).
     # Treat as infra-failure: write last_error, exit 2. Per-round gate state (if any) is
     # left in place — it uses a different REVIEW_GATE_SESSION_KEY from the parent session's
     # gate and is inert; user can clean up manually if desired.
     printf 'spawn_failed: spawn-code-review exited %d\n' "$spawn_rc" > "${state_dir}/last_error"
     printf 'INFRA-FAILURE: spawn-code-review exited %d. Send NEEDS_HUMAN to lead and go idle.\n' "$spawn_rc" >&2
     exit 2
   fi
   ```

8. **Poll for consensus using `review-gate wait --json --finalize --session-key`** (the flag-form is supported here), not `review-gate check`. Rationale: `check` is the parent Stop-hook entrypoint — it consumes hook JSON from stdin and emits `decision:block` even on PASS to prompt a Claude summary. `wait --json --finalize` is the machine-readable polling API that returns terminal `consensus_verdict` plus structured findings. `wait --finalize` blocks and handles its own internal polling, so a single call (no shell-level `sleep` loop) is sufficient. The hook timeout (2100s) caps total wait time.

   **Capture wait output before branching.** `bin/review-gate wait` exits nonzero on every non-PASS terminal state: `0=PASS`, `1=FAIL/NEEDS_WORK`, `2=ERROR`, `3=timeout`, `4=no_reviewers` (per `bin/review-gate:3345-3362,3002`). A bare command substitution would terminate the hook on the most common path (FAIL) before step 9 can branch. The hook must disable `errexit` around the wait invocation, capture both stdout and exit code, then parse the JSON regardless of `wait_rc`. Also guard the `jq` parsing against malformed JSON (e.g., review-gate prints plain text on a fatal crash). `CLAUDE_SESSION_ID` and `REVIEW_GATE_TRANSCRIPT_PATH` are inherited from the script-scope export in step 1 (no per-invocation env needed); `bin/review-gate wait` reads them from env at `bin/review-gate:2913-2914`:
   ```
   wait_json=""
   wait_rc=0
   wait_json=$("${CLAUDE_PLUGIN_ROOT}/bin/review-gate" wait --json --finalize \
     --session-key "$SESSION_KEY") || wait_rc=$?
   verdict=$(printf '%s' "$wait_json" | jq -r '.consensus_verdict // empty' 2>/dev/null || true)
   wait_status=$(printf '%s' "$wait_json" | jq -r '.status // empty' 2>/dev/null || true)
   ```

9. **Branch on `consensus_verdict` from the wait JSON.** The JSON field is authoritative; the exit-code-to-verdict mapping is informational only.
   - `PASS` — before accepting, verify `HEAD` still equals the head captured immediately before `spawn-code-review`; if it changed while reviewers were running, write `last_error` and block because the current code was not reviewed. Otherwise increment `round` in state file, write the reviewed head SHA to `${state_dir}/reviewed_head`, **write a positive-evidence marker** `touch "${state_dir}/reviewed_pass"` (so the lead's success classifier can confirm the hook actually ran to PASS against current HEAD — see Phase 2 of `run-team.md`), then **exit 0**. `TaskUpdate(completed)` goes through; the task is marked `completed`; the teammate goes idle. The lead's classifier sees a clean success.
   - `NEEDS_WORK` (non-blocking P2/P3 only, no P0/P1) — treated like PASS: perform the same HEAD-stability check, increment `round`, write `${state_dir}/reviewed_head`, **also write `${state_dir}/reviewed_pass`** (this is a "review ran cleanly" outcome), exit 0. `--mode fast` with `--max-rounds 0` means review-gate's job is to surface blockers; advisory findings should not loop the implementer indefinitely.
   - `FAIL` (blocking P0/P1 findings present) — increment `round`, **exit 2 with stderr** carrying the findings + final-round warning if applicable (see step 10).
   - `NEEDS_WORK` **with any P0/P1 finding present in `aggregated_findings`** — treat as FAIL (the priority gate documented at `bin/review-gate:363`: "FAIL verdicts and P0/P1 findings always block"). Increment `round`, exit 2 with findings.
   - `ERROR`, `null` (e.g., empty `verdict` from a malformed JSON), `no_reviewers`, or `PENDING`/timeout — infrastructure failures, not implementer fault. Do **not** increment `round`; write `${state_dir}/last_error` containing the verdict + raw wait JSON; then **exit 2 with stderr** labeled `INFRA-FAILURE: <verdict>. Send NEEDS_HUMAN to lead and go idle.`. Per-round gate state is left in place — it uses a different `REVIEW_GATE_SESSION_KEY` from the parent session's gate and is inert (the parent Stop hook calls `bin/review-gate check` against the parent session's gate, not the per-round key), so stale per-round files do not block the lead's final report; they accumulate in the cerberus state directory and can be cleaned up manually. The implementer's prompt rule says: do not retry on infra-failure. The lead detects the `last_error` marker and the in-progress task and classifies as infra-failure.

10. **Stderr formatting on block.** The `TaskCompleted` hook's stderr feedback (when blocking with exit 2) is the documented mechanism for injecting context back to the model on this event. Format the stderr clearly:
   ```
   CERBERUS REVIEW: BLOCKED on task T### (round <r> of <max_rounds>).
   Verdict: FAIL  |  Reviewers: codex/gemini/claude
   Findings:
   - [P1] file:line — body
   - [P1] file:line — body
   - ...

   <if round == max_rounds - 1:>
   THIS IS YOUR FINAL REVIEWED ROUND.
   Review will not fire again on a retry. If your next attempt would still fail,
   you MUST instead SendMessage(STATUS: NEEDS_HUMAN T###) to the lead and go idle.
   Do NOT retry TaskUpdate(status:'completed') after a final-round failure.
   ```
   The "final reviewed round" warning fires when **the value of `round` read at the top of this hook invocation equals `max_rounds - 1`**, matching step 4's locked round-counter convention.

**Propagation of `--max-review-rounds`**: the slash command argument value is written by the lead into `state.json` before spawning, so the hook reads it from there. Slash-command flags are not auto-propagated to hooks — this state-file mechanism is the explicit propagation path. Note: the state file path itself is namespaced by `<team_hash>` (i.e., `${TMPDIR:-/tmp}/cerberus-task-completed-hook/<team_hash>/<task_id>/state.json`), so the hook must first resolve `team_hash` from `metadata.cerberus_team_hash` (primary) or the `[CERBERUS-IMPL/<team_hash>]` subject prefix (fallback) before it can read the state file.

### NEW — `bin/cerberus-task-completed-hook` companion: a small README / inline comment block
Document the per-run state directory layout at `${TMPDIR:-/tmp}/cerberus-task-completed-hook/<team_hash>/<task_id>/`, the subject-prefix gating (`[CERBERUS-IMPL/<team_hash>]`), the `_unknown_<pid>` fallback (per-PID so unrelated runs cannot collide on the missing-state recovery path), and how to clean up state directories manually for failed tasks — typically by removing the entire `<team_hash>` subdirectory after debugging, which is safe because team_hash is unique per invocation (constructed from path + second-precision timestamp + 8 hex chars from `/dev/urandom`, so same-day reruns and concurrent runs each get their own subdirectory) (parallel to existing `bin/` patterns).

## Reuse map (so I don't reinvent)

| Need | Reuse from cerberus | File |
|---|---|---|
| Multi-model review with consensus | `bin/review-gate spawn-code-review` | `bin/review-gate:57` |
| Per-round session keying | `REVIEW_GATE_SESSION_KEY` env + `wait --session-key` | `bin/review-gate:77,2116` |
| Pending-state cleanup on infra failure | (not used in this design; `resolve` only accepts `--reason` and is scoped by `CLAUDE_SESSION_ID` env, so per-round gate state cannot be auto-cleaned by session key) | `bin/review-gate:2778-2822` |
| Hook env / plugin root | `${CLAUDE_PLUGIN_ROOT}` | conventional |
| Phase-based command structure | `commands/create-tasks.md` 7-phase shape | mirror in `commands/run-team.md` |
| Task source links / sizing rules | already produced by `create-tasks` | flow through into `team-tasks.md` |
| Epic-level acceptance verification | `/cerberus:verify-epic` + `bin/review-gate spawn-epic-verify` | `commands/verify-epic.md` + `bin/review-gate:72` + `prompts/reviewers/epic-verify.md` |
| P0/P1/P2/P3 priority semantics | mala `src/prompts/review_agent.md:204-209` | already present in cerberus reviewers |

(Note: the implementer's "False Positives / Resolved / Questions" reviewer-context block from `mala/src/prompts/implementer_prompt.md:309-337` is **deliberately omitted** in this initial cut — see `agents/implementer.md` body and open question 3.)

## Open questions / risks

1. **Per-review session keying — verified.** `bin/review-gate spawn-code-review` reads `REVIEW_GATE_SESSION_KEY`; `wait` accepts `--session-key`. The hook uses env var on spawn and `--session-key` on wait. Re-confirm `git grep REVIEW_GATE_SESSION_KEY bin/review-gate` before implementation.
2. **Re-introducing parallelism.** The initial cut runs implementers strictly serially (max 1) to avoid (a) working-tree conflicts and (b) review-gate state collision. Re-introducing `--max-parallel > 1` requires both per-task isolation (worktrees, with explicit branching from each prerequisite task's branch so dependents see prior work) and verified per-session keying robustness. The agent-team primitive itself supports parallelism (multiple teammates can run concurrently), so the constraint is in the working tree and review-gate state, not in the team protocol. Tracked as a follow-up.
3. **Reviewer-context block for the implementer.** The current design omits mala's "False Positives / Resolved / Questions" subsection because reviewers see only commit ranges, not implementer notes. To restore parity with mala, extend `bin/review-gate spawn-code-review` to accept an optional notes file (path passed via flag) whose contents are concatenated into each reviewer's prompt. Out of scope for this initial cut.
4. **Hook timeout (2100s).** Same as existing Stop hook — should be enough for `--mode fast` reviews. If reviews timeout, the hook treats as infra-failure (per step 9) and writes `last_error`; the implementer is told to escalate, not retry.
5. **Lead writes state before spawning.** Phase 2 of `run-team.md` requires the lead Claude to run `git rev-parse HEAD` and write a JSON file via Bash before each `Agent` call. Lead prompt must explicitly enumerate this preflight step; otherwise the hook will fail to find state and surface a clear error (per step 3 of `bin/cerberus-task-completed-hook`).
6. **`TaskCompleted` input fields are partially undocumented.** Per https://code.claude.com/docs/en/hooks, the event exists and has no matcher and supports `exit 2` block-with-stderr-feedback, but the docs do not enumerate every input JSON field for `TaskCompleted` (only the common fields like `session_id`, `transcript_path`, `cwd` plus the listed `task_id`, `task_name`). The hook's defensive design — subject-prefix filter (which carries `<team_hash>`) + state-file lookup keyed by the parsed `T###` — does not depend on `task_metadata` being passed; metadata-based discovery of `cerberus_team_hash` and `cerberus_task_id` is the recommended primary path, with subject-prefix parsing as the fallback when metadata is not exposed at runtime. Re-confirm during implementation by inspecting actual hook input from a smoke run; if metadata is reliably exposed, prefer it over the subject-prefix fallback.
   - Current docs are inconsistent about whether `TaskCompleted` is completion-only or may also fire when a teammate finishes a turn with in-progress tasks. The implementation does not depend on that ambiguous behavior for idle-ping suppression; duplicate idle notifications are handled by the `TeammateIdle` hook.
   - The hook is idempotent on prior PASS (step 3.5: if both `${state_dir}/verified_pass` and `${state_dir}/reviewed_pass` exist and `verified_head`/`reviewed_head` both equal current `HEAD`, exit 0 immediately). This means the design is robust to TaskCompleted firing more than once for the same task without rerunning verification or burning review rounds, while still rejecting stale markers after `HEAD` changes.
7. **Lead-never-completes-tasks invariant** is the single most important rule for the no-matcher hook. If a future change to `run-team.md` adds any code path where the lead calls `TaskUpdate(status: "completed")`, the hook will fire on a non-implementer event and either (a) bail at the prefix filter (safe — exit 0) or (b) if the prefix happens to match, mis-classify a lead task as implementer work. Add a test or runtime assertion in `run-team.md` that surfaces a clear error if this invariant is violated.
8. **Per-round gate cleanup is intentionally not automated.** `bin/review-gate resolve` only accepts `--reason` and is scoped by `CLAUDE_SESSION_ID` env (verified `bin/review-gate:2778-2822`); there is no `--session-key` lookup path. Per-round gate cleanup is therefore intentionally not automated; stale per-round gate files accumulate as inert state in the cerberus state dir (they use a different `REVIEW_GATE_SESSION_KEY` from the parent session's gate, so they do not block the parent Stop hook's `bin/review-gate check`). If automated cleanup becomes desirable, extend `bin/review-gate resolve` to accept `--session-key` first. Do **not** re-introduce a `resolve --session-key` call in the hook without that change — every such call would `die` with "Invalid argument '--session-key'" and the `|| true` guard would silently swallow it.

   **Edge case — timed-out per-round gates and teammate Stop hooks.** `bin/review-gate wait --finalize` skips finalization when the wait status is `timeout` (the `if [[ "$status" == "timeout" ]]` branch at `bin/review-gate:3345-3347` exits 3 before the finalize block). The per-round gate-state file under the hook's `CLAUDE_SESSION_ID` therefore remains `pending`. **Why teammate Stop hooks cannot see those gate files**: the parent cerberus Stop hook entrypoint (`bin/review-gate check` at `hooks/hooks.json:13-22`) inspects the gate state for the SESSION's gate (no `--session-key`), which is the LEAD's gate, NOT the per-round gate the implementer hook spawned. Teammates do not run cerberus's parent Stop hook — `hooks/hooks.json` is a plugin-level file installed for the user's Claude sessions, and teammates inherit the lead's permission/plugin config but their `Stop` events fire at the teammate level (which we don't gate on). So a stale `pending` per-round gate-state file does NOT block the teammate's idle path. If a future change adds a teammate-level Stop hook that runs `review-gate check`, the hook would need to filter by session key — but no such hook exists today. Manual cleanup remains: delete the team_hash subdirectory after debugging (per Phase 4 cleanup policy).
9. **Agent teams are an experimental feature; the run-team flow's contract may need to evolve when the feature exits experimental status (https://code.claude.com/docs/en/agent-teams). Watch the upstream docs for changes to the env-var name, version requirement, or hook contract.**

## Verification

1. **Install** — cerberus is already installed; restart Claude after edits to pick up new agent + hook.
2. **Sanity** — run existing `/cerberus:review-code` against an arbitrary diff; confirm the parent `Stop` hook still works as before (regression check); confirm `/cerberus:verify-epic` against any spec file works as before.
3. **End-to-end smoke**:
   ```
   cd /tmp/team-test && git init && git commit --allow-empty -m "init"
   ```
   Hand-author a tiny `smoke-team-tasks.md` (skipping create-tasks for the first run) with two trivial tasks:
   ```markdown
   ---
   plan: smoke-plan.md
   ---
   # Team Tasks: smoke
   ## T001 — add hello.py with hello()
   ```meta
   files: [hello.py]
   depends: []
   ```
   Add a hello() function in hello.py that prints "hello".

   ## T002 — add tests
   ```meta
   files: [test_hello.py]
   depends: [T001]
   ```
   Add a test asserting hello() prints "hello".
   ```
   Run `/cerberus:run-team --from-tasks smoke-team-tasks.md --skip-verify`. Expect:
   - Lead discovers a smoke verification gate (for example `python -m pytest` if pytest exists, or an explicit no-op if this tiny repo has no test runner), proceeds without routine confirmation when the gate is safe/documented, and does not call `TeamCreate` until any required destructive/credentialed/ambiguous choice is resolved.
   - After verification gate resolution, lead creates a team `cerberus-impl-<hash>`, writes `${TMPDIR:-/tmp}/cerberus-task-completed-hook/<hash>/verify.sh`, populates the TaskList with two `[CERBERUS-IMPL/<hash>]`-prefixed tasks, writes per-task state file at `${TMPDIR:-/tmp}/cerberus-task-completed-hook/<hash>/T001/state.json`, then spawns T001's implementer teammate.
   - Implementer commits to current branch with `Cerberus-Task: T001` trailer, calls `TaskUpdate(status: "completed")`, `TaskCompleted` hook fires, runs the resolved verification script from the repo root, review-gate spawns reviewers, consensus reaches PASS, hook writes `verified_pass`, `verified_head`, `reviewed_pass`, and `reviewed_head`, exits 0, TaskUpdate succeeds, teammate goes idle.
   - Lead detects `completed` status + `verified_pass` + `reviewed_pass` + matching head files + no failure markers, marks T001 done locally, deletes state dir.
   - T002 unblocks. Lead spawns a fresh `impl-T002` teammate (no reuse of `impl-T001`'s context). Lead writes new state file with baseline = HEAD now (which includes T001's commits). T002's implementer sees `hello.py` already present from T001's commits. Repeats.
   - Final report shows both passed with commit hashes. With `--skip-verify`, no epic verification runs.
4. **Verify-epic wiring** — same smoke setup but include real acceptance criteria in `smoke-plan.md` and run without `--skip-verify`. Expect: after each execution phase passes, lead invokes `spawn-epic-verify`, polls for verdict, and includes every phase verdict in the final report. Non-final phases use generated criteria for all phases completed so far; the final phase verifies `smoke-plan.md`. If a verifier returns findings, expect the lead to pause any active teammates, create a synthetic `epic-gap` task, spawn a fresh implementer to fix the findings, and rerun the same phase verifier before continuing.
5. **Failure modes** — exercise each of the five outcome categories defined in Phase 2 of `run-team.md`:
   - **needs-human**: author a deliberately broken task ("fix bug X that doesn't exist"). Confirm: implementer hits final-round FAIL, hook's stderr warns "FINAL REVIEWED ROUND", implementer respects the rule and SendMessages NEEDS_HUMAN to the lead, does NOT retry TaskUpdate, goes idle. Lead receives the message + sees task is not completed + sees `exhausted` marker → classifies `needs-human` → reports + recovery instructions; no further tasks scheduled.
   - **unverified-failure** (defensive): simulate an implementer that ignores the rule and somehow gets `TaskUpdate(completed)` past the hook (would require hook bypass — exercise by pre-writing `exhausted` marker and then having a test implementer call `TaskUpdate(completed)`). Confirm: lead detects `exhausted` marker present + `completed` status and classifies as `unverified-failure`; state dir retained; no further tasks scheduled.
   - **infra-failure**: temporarily break review-gate (rename `bin/review-gate` or set an unwritable session-key path) so wait returns ERROR/no_reviewers. Confirm: hook writes `last_error` and exits 2 with INFRA-FAILURE stderr (no per-round gate cleanup is performed; stale per-round gate state is inert and does not block the parent Stop hook). Implementer SendMessages NEEDS_HUMAN. Lead detects `last_error` and classifies; final report includes the raw wait JSON.
   - **abandoned**: hand-spawn an implementer with a prompt that immediately goes idle without making any commits or sending any messages. Confirm: lead receives TeammateIdle, sees task not completed + no `exhausted` marker + no `last_error` marker + no `NEEDS_HUMAN` message, classifies as `abandoned`, stops scheduling, final report identifies the model-behavior failure (distinct from `needs-human`).
   - **post-task dirty tree**: author a task whose implementer (in a controlled test) leaves a modified tracked file outside its commits. Confirm lead's post-task tracked-file check downgrades to `unverified-failure` and stops scheduling. Same for an extra new untracked file (post-task new-untracked check).
   - **field-mismatch silent-pass**: simulate the hook receiving an empty subject (e.g., temporarily rename the prefix in TaskCreate to break the match, or stub the hook input so `task_subject` and `task_name` are both empty). Confirm: `TaskUpdate(completed)` goes through, no `verified_pass` or `reviewed_pass` marker is written, lead classifies as `unverified-failure` (NOT success) with the sub-reason "task marked completed but missing positive verification/review evidence — hook did not run or did not run to PASS."
6. **Lead-never-completes invariant** — add a test that runs run-team and asserts no `TaskUpdate(status: "completed")` is called by the lead Claude during the run. (Implementation: instrument the hook to log every `TaskCompleted` event with the task subject; assert all logged events have the `[CERBERUS-IMPL/<team_hash>]` prefix.)
7. **Existing flows** — run `/cerberus:create-tasks --beads` against an existing plan; confirm unchanged behavior. Run `/cerberus:create-tasks --agent-team --from-plan docs/plans/<sample>.md`; confirm `<sample>-team-tasks.md` is emitted next to the plan with the schema above.
