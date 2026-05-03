# Cerberus Shell Scripts Functional Spec

This document specifies the shell scripts used by the Cerberus Claude and
Codex plugins. It describes the executable contracts, hook integration,
environment model, state model, command behavior, outputs, errors, and
verification expectations for the production scripts in this repository.

## Scope

In scope:

- Claude plugin lifecycle scripts and shared backend scripts used by
  `.claude-plugin/plugin.json` and `hooks/hooks.json`.
- Codex plugin lifecycle scripts and shared backend scripts used by
  `.codex-plugin/plugin.json` and `hooks/codex-hooks.json`.
- Shared shell helper libraries sourced by the plugin scripts.
- The Amp toolbox adapter, because it uses the same host-neutral backend and
  constrains shared script behavior.
- The release/update helper for installed Claude plugins.

Out of scope:

- `bin/tests/*.sh`, which are test drivers rather than plugin runtime scripts.
- Markdown skills under `skills/`, except where they define the command
  surfaces that invoke the scripts.
- Prompt templates under `prompts/`, except where a script selects or renders
  them.

## Script Inventory

| Path | Kind | Primary host(s) | Functional role |
|---|---|---:|---|
| `bin/review-gate` | executable | Claude, Codex, Amp, generic | Main review gate CLI and shared orchestration backend. |
| `bin/generate` | executable | Claude, Codex, Amp, generic | Multi-model generator backend for plan/spec/healthcheck/architecture drafts. |
| `bin/claude-session-init` | hook executable | Claude | Captures Claude `session_id` and `transcript_path` into `CLAUDE_ENV_FILE`. |
| `bin/codex-session-init` | hook executable | Codex | Writes the Codex active-session registry used by skills and Stop hooks. |
| `bin/codex-stop-hook` | hook executable | Codex | Maps Cerberus gate status to Codex Stop hook allow/block JSON. |
| `bin/review-gate-hook.sh` | sourced helper | Claude | Implements `review-gate check`, the Claude Stop hook gate. |
| `bin/review-gate-lib.sh` | sourced helper | all | Resolves state directories and provides shared state/telemetry helpers. |
| `bin/review-gate-models.sh` | sourced helper | all | Resolves model modes, emits schemas, invokes reviewers, extracts JSON. |
| `bin/review-gate-debate.sh` | sourced helper | all | Implements debate mode hashing, anonymization, rounds, aggregation. |
| `bin/telemetry-lib.sh` | sourced helper | all | Writes and summarizes telemetry for runs, iterations, and agents. |
| `bin/cerberus-skill-env` | sourced helper | Claude, Codex, Amp, generic | Normalizes env vars before skill snippets call backend scripts. |
| `bin/cerberus-task-completed-hook` | hook executable | Claude | Gates Claude agent-team task completion through verification and code review. |
| `bin/cerberus-teammate-idle-hook` | hook executable | Claude | Suppresses duplicate idle notifications for Cerberus implementer teammates. |
| `bin/update-plugin` | executable | Claude maintainer | Updates installed plugin cache and rewrites Claude allowlist paths. |
| `.amp/toolbox/cerberus.sh` | toolbox executable | Amp | Provides the Amp command adapter over the same backend. |

## Hook Manifests

### Claude Hooks

`hooks/hooks.json` registers:

| Hook event | Command | Timeout | Required behavior |
|---|---|---:|---|
| `SessionStart` | `${CLAUDE_PLUGIN_ROOT}/bin/claude-session-init` | host default | Export `CLAUDE_SESSION_ID` and `CLAUDE_TRANSCRIPT_PATH` via `CLAUDE_ENV_FILE`. |
| `Stop` | `${CLAUDE_PLUGIN_ROOT}/bin/review-gate check` | `2100` sec | Enforce the active Cerberus gate before Claude stops. |
| `TaskCompleted` | `${CLAUDE_PLUGIN_ROOT}/bin/cerberus-task-completed-hook` | `2100` sec | Gate Cerberus implementer task completion. |
| `TeammateIdle` | `${CLAUDE_PLUGIN_ROOT}/bin/cerberus-teammate-idle-hook` | `10` sec | Suppress duplicate Cerberus implementer idle events. |

The Claude plugin manifest at `.claude-plugin/plugin.json` exposes `skills/`
and relies on the Claude hook manifest above.

### Codex Hooks

`hooks/codex-hooks.json` registers:

| Hook event | Command | Timeout | Required behavior |
|---|---|---:|---|
| `SessionStart` | `${PLUGIN_ROOT}/bin/codex-session-init` | host default | Write or refresh the active Codex session registry. |
| `UserPromptSubmit` | `${PLUGIN_ROOT}/bin/codex-session-init` | host default | Refresh the active Codex session registry on each prompt. |
| `Stop` | `${PLUGIN_ROOT}/bin/codex-stop-hook` | `2100` sec | Enforce the active Cerberus gate before Codex stops. |

The Codex plugin manifest at `.codex-plugin/plugin.json` exposes `skills/`
and points `hooks` at `./hooks/codex-hooks.json`.

`templates/codex-hooks.json` is a fallback manual install template for Codex
versions that do not load plugin-bundled hooks. It must not be active at the
same time as bundled hooks, because that would run duplicate lifecycle hooks.

## Common Dependencies

All production shell scripts must remain compatible with Bash 3.2 unless a
specific script documents a narrower runtime.

Required for normal operation:

- `bash`
- `jq`
- `git` for code-review and task-completion flows
- `python3` for selected helper paths used by the backend
- Reviewer CLIs selected for a run: `codex`, `gemini`, and/or `claude`

Required by specific features:

- `shasum -a 256` or `sha256sum` for stable hashing. `shasum` is preferred
  when both exist. Debate mode must hard-error if neither exists for its
  cryptographic hash helpers.
- Gemini read-only config files:
  `config/gemini-readonly-settings.json` and
  `config/gemini-readonly-policy.toml`.

Missing reviewer CLIs should degrade by skipping or failing that reviewer
through the existing review-gate error surfaces. Missing structural
dependencies such as `jq` should produce explicit errors or documented
failure-open behavior for hooks.

## Host-Neutral Environment Contract

The shared backend reads canonical `CERBERUS_*` variables, with legacy Claude
aliases preserved.

| Canonical variable | Meaning | Alias or fallback |
|---|---|---|
| `CERBERUS_HOST` | `claude`, `codex`, `amp`, or `generic` | Derived from host-specific env when unset. |
| `CERBERUS_ROOT` | Cerberus plugin/repo root | `CLAUDE_PLUGIN_ROOT`. |
| `CERBERUS_STATE_ROOT` | Base state directory | Host default. Claude uses `~/.claude/projects`; other hosts use `~/.cerberus/projects` unless overridden. |
| `CERBERUS_PROJECT_KEY` | Stable workspace key | Computed by `get_project_hash`. |
| `CERBERUS_SESSION_ID` | Host session/thread id | `CLAUDE_SESSION_ID` or hook input. |
| `CERBERUS_RUN_KEY` | Cerberus run identity | `REVIEW_GATE_SESSION_KEY`. |
| `CERBERUS_TRANSCRIPT_PATH` | Optional transcript path | `CLAUDE_TRANSCRIPT_PATH` or `REVIEW_GATE_TRANSCRIPT_PATH`. |

Precedence requirements:

- `CERBERUS_ROOT` wins over `CLAUDE_PLUGIN_ROOT`.
- `CERBERUS_RUN_KEY` wins over `REVIEW_GATE_SESSION_KEY`.
- Empty strings are treated as unset.
- If canonical and alias variables are both non-empty and disagree, the
  canonical value wins and the process emits one warning to stderr.

## State Model

### Review Directory

`bin/review-gate-lib.sh` owns review directory resolution. The effective path
is:

```text
<state-root>/<project-key>/cerberus/<run-key>
```

Default state roots:

- Claude: `~/.claude/projects`
- Codex, Amp, generic: `~/.cerberus/projects`

The resolver must reject:

- Unknown `CERBERUS_HOST` values.
- Non-absolute `CERBERUS_STATE_ROOT` values.
- Project keys or run keys containing path traversal or `/`.

### Core Files

Within a review directory, the backend may create:

| File or directory | Purpose |
|---|---|
| `latest.md` | Session-scoped artifact under review. |
| `gate-state.json` | Canonical gate status, mode, reviewer, consensus, and decision state. |
| `gate-report.md` | Human-readable report. |
| `reviews/` | Current iteration reviewer outputs and sentinels. |
| `reviews-iter-N/` | Archived prior iteration review directories. |
| `iteration.txt` and `iteration.json` | Review iteration counters and telemetry linkage. |
| `run-telemetry.json` | Run-level telemetry. |
| `cerberus.log` | Hook/backend diagnostic log. |
| `author-context.md` | Optional persisted author context. |

All scripts that mutate JSON state should use atomic-write patterns:
write a temp file in the target directory, validate it with `jq`, then `mv`
over the destination.

### Codex Active-Session Registry

`bin/codex-session-init` writes:

```text
~/.cerberus/runtime/codex/<workspace-key>/active-session.json
```

Schema:

```json
{
  "schema_version": 1,
  "host": "codex",
  "workspace_root": "<absolute path>",
  "project_key": "<workspace key>",
  "session_id": "<Codex session id>",
  "codex_session_id": "<Codex session id>",
  "run_key": "<Cerberus run key>",
  "transcript_path": "<optional transcript path>",
  "last_seen": "<UTC ISO-8601 timestamp>"
}
```

Run-key selection:

1. `CERBERUS_RUN_KEY`
2. `REVIEW_GATE_SESSION_KEY`
3. Existing registry `run_key`, if the same session is refreshed or the prior
   run key still owns a `pending` or `awaiting_decision` gate.
4. Current Codex `session_id`.

The script must reject malformed stdin JSON, missing session id, unsafe
project keys, and unsafe run keys with exit code `2`.

## `bin/review-gate`

### Purpose

`bin/review-gate` is the main backend CLI. It spawns model reviewers,
coordinates debate mode, waits for reviewer completion, computes consensus,
updates gate state, resolves gates, and exposes machine-readable status for
hooks and host adapters.

### Command Surface

```text
review-gate <command> [args]
```

Commands:

| Command | Function |
|---|---|
| `check` | Claude Stop hook logic. Reads hook JSON from stdin. |
| `spawn` | Spawn reviewers for an artifact path or `latest.md`. |
| `spawn-code-review` | Build a git diff artifact and spawn code reviewers. |
| `spawn-plan-review` | Spawn reviewers for a plan file. |
| `spawn-spec-review` | Spawn reviewers for a spec file. |
| `spawn-epic-verify` | Spawn reviewers to verify epic acceptance criteria against the codebase. |
| `spawn-ask` | Ask the reviewer panel an arbitrary question. |
| `wait` | Poll until reviewer consensus or timeout. Requires `--json`. |
| `status` | Emit a non-mutating JSON snapshot. Requires `--json`. |
| `resolve` | Mark the active gate resolved so the host may stop. |
| `artifact-path` | Print the session-scoped artifact path. |
| `author-context` | Set, clear, or print author context for reviewer prompts. |

Global review options used by spawn commands:

| Option | Meaning |
|---|---|
| `--agents <list>` | Comma-separated subset of `codex,gemini,claude`. |
| `--max-rounds <n>` | Maximum outer review iterations. `0` disables auto-respawn. |
| `--mode <fast|smart|max>` | Model effort and model selection mode. |
| `--consensus <majority|all|any>` | Consensus mode. |
| `--context-file <path>` | Additional context injected into reviewer prompts. |
| `--debate` | Enable synchronous debate coordinator. Requires at least two available reviewers. |
| `--session-id <id>` | Explicit session id for state scoping. |
| `--transcript-path <path>` | Explicit transcript path for state scoping. |

Defaults:

- `--mode`: `smart`
- `--max-rounds`: `REVIEW_GATE_MAX_ROUNDS`, else `3`
- `--consensus`: `REVIEW_GATE_CONSENSUS`, else `majority`
- `wait --timeout`: `REVIEW_GATE_MAX_WAIT_SECONDS`, else `1800`
- `wait --poll-interval`: `REVIEW_GATE_POLL_INTERVAL_SECONDS`, else `3`

### Code Review Spawn

`spawn-code-review` supports:

- `--uncommitted` for current uncommitted changes. This is the default.
- `--base <branch>` for branch-to-HEAD diffs.
- `--commit <sha...>` for one or more commits as a net diff. Values may be
  space-separated or comma-separated.
- `<range>` such as `main..feature`.
- `--exclude <pathspec>` repeated to exclude paths.
- `--focus <text>` or trailing focus text.

The command must validate ambiguous positionals. A single unknown git-ref-like
word should error unless the user forces focus text with `--`.

### Plan, Spec, Epic, and Ask Spawn

`spawn-plan-review` accepts an optional plan path. If no path is provided, it
may use the most recent session plan from `~/.claude/plans/`.

`spawn-spec-review` requires a spec path.

`spawn-epic-verify` requires an epic file path or criteria string. Reviewers
must inspect the codebase rather than only review prose.

`spawn-ask` accepts prompt text or `--prompt-file <path>`. `--max-rounds`
defaults to `0` for ask-style one-shot panel questions unless overridden.

### Debate Mode

When `--debate` is absent, review outputs, schemas, prompts, and gate state
must remain compatible with non-debate behavior.

When `--debate` is present:

- Allowed review types are `code`, `plan`, `spec`, `epic-verify`, and `ask`.
- Named subcommands set the type implicitly.
- Bare `spawn --debate` must reject unsupported `--type` values before any
  reviewer invocation.
- The coordinator runs reviewer rounds synchronously in-process:
  Round 1, anonymized peer broadcast, Round 2, and for `--mode max` Round 3.
- Final-round outputs are promoted to the canonical `reviews/` directory.
- `aggregate.json` is written with deduplicated findings and debate metadata.
- `gate-state.json` receives an additive debate block.

Debate helper requirements live in `bin/review-gate-debate.sh`:

- Hashing must use SHA-256 via `shasum -a 256` or `sha256sum`.
- Strategy assignment uses canonical reviewer ordering and deterministic
  collision walking.
- Peer content shown to reviewers must scrub canonical reviewer names and use
  opaque IDs such as `Peer-A`.
- Seeded peer ordering is fixture-only and deterministic.
- Production peer ordering must use a non-deterministic source.
- Abstained peers must be rendered explicitly as `(peer abstained)`.
- Aggregation must deduplicate only findings from different reviewers with
  equal priority, equal non-null file path, overlapping non-null line ranges,
  and equal normalized title.

### Consensus and Blocking

Consensus modes:

- `majority`: at least two reviewers pass, or all valid reviewers pass when
  fewer than two valid reviewers exist.
- `all`: all valid reviewers must pass. Errored reviewers are skipped.
- `any`: at least one reviewer must pass.

Regardless of consensus mode:

- `FAIL` verdicts block.
- P0/P1 findings block.
- Parse errors, reviewer failures, and missing reviewers are surfaced in JSON
  outputs and reports.

### `wait --json`

`wait` must:

- Require `--json`.
- Poll reviewer sentinels and valid outputs until final, timeout, or no
  reviewers.
- Return canonical JSON containing at least `status`, `consensus_verdict`,
  `reviewers`, `aggregated_findings`, and `parse_errors`.
- Exit `0` for successful final states.
- Exit `2` for internal errors.
- Exit `3` for timeout.
- Exit `4` when no reviewers exist.

`--finalize` permits finalization side effects required by status/report
consumers.

### `status --json`

`status` must:

- Require `--json`.
- Be non-mutating and non-blocking.
- Resolve the same run-key and review directory as `wait`.
- Exit `0` on successful snapshot.
- Exit `4` when no active gate exists.
- Exit `2` on internal error.

The JSON shape is consumed by `bin/codex-stop-hook` and Amp status surfaces,
so compatibility is part of the hook contract.

### `resolve`

`resolve` marks the active gate as resolved and records a decision reason.
It must be idempotent when the gate is already resolved.

### `artifact-path`

`artifact-path` prints the path to `latest.md` for the effective session.
It must accept explicit `--session-id` and `--transcript-path` overrides.

### `author-context`

`author-context` must support:

- Setting context from positional text.
- Clearing context with `--clear`.
- Explicit state scoping via `--session-id` and `--transcript-path`.

The stored context is injected into later reviewer prompts.

## `bin/generate`

### Purpose

`bin/generate` runs model generators in parallel and writes generated drafts to
an output directory. It is used by skills such as healthcheck,
architecture-review, create-spec, and create-plan.

### Interface

```text
generate <output-dir> [options]
```

Arguments and options:

| Parameter | Meaning |
|---|---|
| `<output-dir>` | Required directory where draft files are written. |
| `--type <type>` | `healthcheck`, `architecture-review`, `create-spec`, or `create-plan`. Default `healthcheck`. |
| `--mode <fast|smart|max>` | Intelligence mode. |
| `--prompt-file <path>` | Prompt body source file. |
| `--prompt <text>` | Inline prompt replacing the base prompt. |
| `--focus <text>` | Focus text appended to the base prompt. |
| `--analysis-file <path>` | Additional analysis file, repeatable. |
| `--skip-interview` | For create-plan, directs models to make and document decisions autonomously. |
| `[--] <focus>` | Trailing focus text. |

Behavior:

- The first argument must be `<output-dir>`, not an option.
- Unknown options fail with a clear error.
- `CERBERUS_ROOT` takes precedence over `CLAUDE_PLUGIN_ROOT`.
- If the configured root lacks backend files, the script falls back to the
  script-derived root with a warning.
- It sources `review-gate-models.sh` and optionally `telemetry-lib.sh`.
- It must extract content from Claude JSON, Codex JSONL, and Gemini output
  variants and write normalized `draft.md` files under per-agent directories.
- It must keep JSON/telemetry mode usable even when telemetry helpers are
  unavailable by emitting empty telemetry stubs.

Expected draft paths for successful agents:

```text
<output-dir>/codex/draft.md
<output-dir>/gemini/draft.md
<output-dir>/claude/draft.md
```

## `bin/review-gate-models.sh`

### Purpose

This sourced helper centralizes model-mode resolution, schema emission,
reviewer invocation, output extraction, and optional JSON repair.

Functional requirements:

- `normalize_mode` lowercases mode input.
- `validate_mode` accepts only `fast`, `smart`, `max`, or empty.
- `resolve_intelligence_mode` maps modes to effective reviewer settings:
  - `fast`: Codex medium effort, Claude medium effort, Gemini flash default,
    Claude sonnet default.
  - `smart`: Codex medium effort, Claude high effort, Gemini pro default,
    Claude opus default.
  - `max`: Codex xhigh effort, Claude max effort, Gemini pro default,
    Claude opus default.
- Mode defaults may be overridden by model-specific environment variables.
- Gemini reviewer invocation must use the configured read-only settings and
  policy paths.
- `_emit_review_schema` must emit the non-debate schema byte-stably when
  debate is off and a debate-specific schema when debate is on.
- `repair_review_output` may use a configured repair provider and model to
  coerce malformed reviewer output into valid structured review JSON.
- `extract_json` and related helpers must parse wrapper formats from Claude,
  Codex, and Gemini and return the structured review object where possible.
- `spawn_reviewer` must launch selected reviewers and write raw outputs plus
  `.done`/`.failed` sentinels used by wait/check paths.

## `bin/review-gate-hook.sh`

### Purpose

This sourced helper implements the Claude Stop hook logic exposed as
`bin/review-gate check`.

Functional requirements:

- Read Claude hook JSON from stdin.
- Resolve session identity from `REVIEW_GATE_SESSION_KEY`,
  `input.session_id`, or `input.transcript_path`.
- Resolve the review directory and log to `REVIEW_GATE_LOG_FILE` or
  `<review-dir>/cerberus.log`.
- Wait up to `REVIEW_GATE_MAX_WAIT_SECONDS` for pending reviewers, polling at
  `REVIEW_GATE_POLL_INTERVAL_SECONDS`.
- Calculate reviewer status, parse findings, and decide whether stopping is
  allowed.
- Fail open on internal hook errors to avoid permanently trapping the user.
- Emit valid hook JSON when blocking is required.
- Allow stop when no active gate exists, when the gate passes, or when the
  state is unreadable in a way that would otherwise deadlock the host.

## `bin/review-gate-lib.sh`

### Purpose

This sourced helper owns shared state path resolution and common state
operations.

Functional requirements:

- `get_project_hash` returns `CERBERUS_PROJECT_KEY` when set, else derives a
  key from transcript path or git/project root.
- `resolve_review_dir` implements host-neutral state resolution with canonical
  env precedence and validation.
- `get_review_base_dir` returns the review base for a project.
- `iso8601_to_epoch` converts ISO-8601 timestamps for gate freshness checks.
- `archive_reviews` moves current review outputs into iteration archives.
- `load_iteration` and `save_iteration` persist iteration counters.
- `unwrap_review_json` extracts review JSON from model wrapper envelopes.
- `find_active_gate` locates pending or awaiting-decision gates.
- `compute_sha256` provides a cross-platform SHA-256 helper.
- Telemetry wrapper helpers call into `telemetry-lib.sh` when available.

## `bin/review-gate-debate.sh`

### Purpose

This sourced helper implements debate-mode coordination for `review-gate`.

Public/helper contracts:

- `_sha256_hex <input>` emits lowercase SHA-256 from stdin or a literal
  argument and fails if no cryptographic hash tool exists.
- `compute_artifact_id <review_type> <args...>` returns the canonical artifact
  identity for strategy assignment.
- `assign_strategies <artifact_id> <reviewer...>` emits reviewer-strategy
  pairs in canonical order.
- `resolve_strategy_path <strategy>` resolves the prompt fragment for a
  supported strategy.
- `debate_deny_list_scrub` redacts reviewer identities from peer material.
- `debate_assign_peer_ids` assigns stable run-local opaque peer IDs.
- `debate_peer_order_seeded` and `debate_peer_order_random` order peer blocks.
- `debate_build_peer_blocks` renders active and abstained peer blocks.
- `run_debate_coordinator` runs the synchronous round coordinator and promotes
  final outputs.

Coordinator requirements:

- Run only when `--debate` is enabled.
- Require at least two available reviewers before model invocation.
- Persist partial telemetry for each round.
- Treat reviewer abstention as terminal for that reviewer in the debate run.
- On SIGINT, allow the in-flight round to finish, preserve partial telemetry,
  leave the canonical reviews directory unpopulated, and exit without claiming
  consensus.
- On degraded active reviewer count below two after the run has started, write
  an awaiting-decision state requiring user action.
- Aggregation must keep per-reviewer final JSONs intact and write merged
  findings only to `aggregate.json`.

## `bin/telemetry-lib.sh`

### Purpose

This sourced helper writes run, iteration, debate, and per-agent telemetry.

Functional requirements:

- `get_plugin_version` reads `.claude-plugin/plugin.json` when available.
- `detect_cli_json_support` probes reviewer CLI JSON support.
- `atomic_write` and `atomic_json_update` provide safe file updates.
- Agent extraction helpers normalize telemetry from Claude, Codex, and Gemini
  output formats.
- `init_iteration_dir` creates per-iteration telemetry directories.
- `write_debate_telemetry` records debate-specific round metadata.
- `write_agent_telemetry` stores per-agent stats, raw JSON, and draft paths.
- `update_run_telemetry` updates run-level agent summaries.
- `resolve_run_telemetry` records final decisions.
- `get_run_telemetry_summary` returns a summary suitable for reports.
- `safe_extract_telemetry` must return structured empty telemetry rather than
  fail the caller when extraction is impossible.

## `bin/cerberus-skill-env`

### Purpose

This script is sourced by skill Bash snippets before they invoke backend
commands. It normalizes root, host, project, and run-key environment across
Claude, Codex, Amp, and generic shells.

Functional requirements:

- Resolve `CERBERUS_ROOT` from existing `CERBERUS_ROOT`,
  `CLAUDE_PLUGIN_ROOT`, `CLAUDE_SKILL_DIR`, or the script location.
- Verify the root contains backend files; otherwise fall back to the
  script-derived root.
- Infer `CERBERUS_HOST`:
  - `amp` if Amp thread env exists.
  - `claude` if Claude env exists.
  - `codex` if Codex env exists or a Codex registry exists for the current
    project.
  - `generic` otherwise.
- For Amp, use a valid `AMP_THREAD_ID` or `AMP_CURRENT_THREAD_ID` as run key
  when no explicit run key is set.
- For Codex, read the active-session registry and export
  `CERBERUS_PROJECT_KEY` and `CERBERUS_RUN_KEY`.
- If the Codex registry is missing or stale and `CODEX_THREAD_ID` exists,
  bootstrap it by invoking `bin/codex-session-init`.
- Fail with a clear message when a required Codex registry cannot be read.

## `bin/claude-session-init`

### Purpose

This Claude `SessionStart` hook captures session identity for later shell
commands.

Input:

- Hook JSON on stdin with `session_id` and optionally `transcript_path`.

Behavior:

- If `CLAUDE_ENV_FILE` is unset, exit `0` without output.
- Append shell exports for `CLAUDE_SESSION_ID` and `CLAUDE_TRANSCRIPT_PATH` to
  `CLAUDE_ENV_FILE`.
- Fail if required dependencies such as `jq` are unavailable under strict
  shell behavior.

Outputs:

- No stdout contract.
- Writes environment exports to `CLAUDE_ENV_FILE`.

## `bin/codex-session-init`

### Purpose

This Codex `SessionStart` and `UserPromptSubmit` hook writes the active
session registry used by Codex skills and `bin/codex-stop-hook`.

Input:

- Hook JSON on stdin.
- Expected fields: `session_id`; `workspace_root` or `cwd`; optional
  `transcript_path`.

Behavior:

- Validate stdin is non-empty JSON.
- Resolve workspace root from hook JSON or `pwd`.
- Compute project key using `get_project_hash` from `review-gate-lib.sh`.
- Resolve run key using the precedence in the State Model section.
- Preserve an existing active run key when a Codex lifecycle id changes while
  a gate is still pending or awaiting decision.
- Atomically write `active-session.json`.
- Leave orphan temp files rather than risk corrupting the registry if killed
  between temp write and `mv`.

Exit codes:

- `0`: registry written.
- `1`: JSON construction or validation failure.
- `2`: malformed input or invalid project/run key.

## `bin/codex-stop-hook`

### Purpose

This Codex `Stop` hook maps Cerberus gate state to Codex hook JSON. It is
failure-open by design.

Input:

- Codex Stop hook JSON on stdin.

Behavior:

- Always exit `0`.
- Always emit at most one valid JSON response to stdout.
- Resolve workspace and project key from hook input or current directory.
- Read the active Codex registry for the run key.
- Call `review-gate status --json --session-key <run>`.
- If reviewers are still pending, run `review-gate wait --json --timeout
  <budget> --session-key <run>`, then re-read `status`.
- Track child PIDs and temp files so signal handlers can terminate children
  and fail open cleanly.
- On malformed registry, missing registry, missing `jq`, backend error,
  signal, unknown status, or no active gate, allow stop.

Decision matrix:

| Gate status | Condition | Stop response |
|---|---|---|
| no active gate | Any | Allow. |
| `pending` | pending reviewers exist and wait budget remains | Wait, then re-evaluate. |
| `pending` | no pending reviewers and blocking findings exist | Continue/block with findings. |
| `pending` | no pending reviewers and no blockers | Allow. |
| `pending` | reviewers still running after wait | Allow with status guidance. |
| `awaiting_decision` | blocking findings exist | Continue/block with findings. |
| `awaiting_decision` | no blockers | Allow. |
| `resolved` | `consensus_verdict == "fail"` | Continue/block with resolved-fail message. |
| `resolved` | any other verdict | Allow. |
| unknown/error | Any | Allow. |

Output shape:

- Allow: JSON body accepted by Codex as a non-blocking Stop response.
- Block/continue: JSON body with a reason containing actionable Cerberus
  findings or status.

## `bin/cerberus-task-completed-hook`

### Purpose

This Claude `TaskCompleted` hook gates Cerberus implementer tasks created by
the `run-team` skill. It verifies the implementer's committed work and runs a
Cerberus code review before accepting completion.

Ownership detection:

- Ignore all events except `TaskCompleted`.
- Ignore tasks whose subject does not start with `[CERBERUS-IMPL/<team_hash>]`.
- Resolve `team_hash`, `task_id`, and `state_dir` from task metadata or the
  subject.

Required state:

```text
${TMPDIR:-/tmp}/cerberus-task-completed-hook/<team_hash>/<task_id>/
```

Important files:

| File | Meaning |
|---|---|
| `state.json` | Task state with `task_id`, `team_hash`, `round`, `max_rounds`, `task_context_path`, `verify_script_path`. |
| `completion_intent` | Marker touched by implementer after lead grants completion. |
| `task_commits.txt` | Explicit commit refs reported by the implementer and recorded by the lead. |
| `verify.sh` or configured script | User-confirmed verification gate. |
| `verified_pass`, `verified_head` | Pre-review verification success markers. |
| `reviewed_pass`, `reviewed_head` | Code-review success markers. |
| `wait.json` | Machine-readable review result. |
| `last_error` | Diagnostic for lead/human recovery. |

Functional flow:

1. Fail open for unrelated tasks before ownership is established.
2. For owned tasks, fail closed with actionable stderr and exit `2` on
   verification/review blockers.
3. Validate state identity against hook metadata.
4. Require a valid git worktree and repository root.
5. Treat duplicate completion events for an already verified and reviewed HEAD
   as idempotent success.
6. Atomically claim `completion_intent` so only one completion attempt runs.
7. Enforce `round < max_rounds`.
8. Validate `task_context_path` and `verify_script_path`.
9. Require explicit task commits in `task_commits.txt`.
10. Validate each commit is reachable from HEAD and has exactly one
    `Cerberus-Task: <task_id>` trailer.
11. Require no tracked dirty files before and after verification/review.
12. Run the configured verification script and reject if it changes HEAD or
    exits non-zero.
13. Spawn `review-gate spawn-code-review --max-rounds 0 --consensus majority
    --mode fast --context-file <task-context> --commit <task-commits...>`.
14. Wait with `review-gate wait --json --finalize --timeout 1800`.
15. Accept completion if verdict is `PASS`, or if verdict is `NEEDS_WORK`
    without P0/P1 blockers.
16. Block completion on `FAIL` or `NEEDS_WORK` with P0/P1 blockers, increment
    the round, and mark exhausted when max rounds are reached.

The hook must never amend, reset, stash, checkout, restore, or otherwise
rewrite implementer commits.

## `bin/cerberus-teammate-idle-hook`

### Purpose

This Claude `TeammateIdle` hook suppresses duplicate idle notifications from
Cerberus implementer teammates when no task evidence has changed.

Functional requirements:

- Ignore all events except `TeammateIdle`.
- Ignore teams whose name does not match `cerberus-impl-<team_hash>`.
- Ignore teammates whose name does not match `impl-T<number>`.
- Locate state under
  `${TMPDIR:-/tmp}/cerberus-task-completed-hook/<team_hash>/<task_id>`.
- Fail open if `jq`, state, git, or marker data is unavailable.
- Build an epoch digest from task state, repo HEAD, markers, and selected
  files such as `task_commits.txt`, `wait.json`, and `last_error`.
- If the epoch matches the previous idle epoch, emit a hook response that
  suppresses the duplicate notification.
- If the epoch differs, write the new epoch, last-seen timestamp, and raw
  event JSON, then allow the notification through.

## `bin/update-plugin`

### Purpose

This maintainer helper updates an installed Claude plugin and rewrites Claude
settings allowlist paths to the new cached plugin version.

Functional requirements:

- Run `claude plugin marketplace update cerberus`.
- Run `claude plugin update cerberus@cerberus`.
- Read the new installed version from
  `~/.claude/plugins/installed_plugins.json`.
- Rewrite `~/.claude/settings.json` allowlist entries that point at old
  Cerberus cached `bin/` paths so they point at the new version.
- Validate rewritten JSON with `jq`.
- Print the new bin path and available scripts.
- Exit non-zero if the version cannot be determined or settings JSON cannot
  be rewritten validly.

## `.amp/toolbox/cerberus.sh`

### Purpose

The Amp adapter exposes the shared Cerberus backend through Amp Toolbox
actions. It is included here because it uses the same host-neutral state
contract and is a compatibility consumer of `review-gate`.

Toolbox actions:

| `TOOLBOX_ACTION` | Behavior |
|---|---|
| `describe` | Emit JSON metadata and supported command list. |
| `execute` | Read JSON params from stdin and dispatch a Cerberus command. |

Supported commands:

| Command | Required params | Backend call |
|---|---|---|
| `review-code` | none | `review-gate spawn-code-review` |
| `review-plan` | `plan_path` | `review-gate spawn-plan-review <plan_path>` |
| `review-spec` | `spec_path` | `review-gate spawn-spec-review <spec_path>` |
| `ask-panel` | `question` | `review-gate spawn-ask <question>` then `wait --json --finalize` |
| `status` | none | `review-gate status --json` |
| `clear-gate` | optional `reason` | `review-gate resolve --reason <reason>` |

Run-key behavior:

- Explicit `CERBERUS_RUN_KEY` or `REVIEW_GATE_SESSION_KEY` wins.
- A valid `AMP_THREAD_ID` or `AMP_CURRENT_THREAD_ID` is preferred for new
  thread-bound runs.
- If prior registry state used a generated UUID because no thread id existed,
  the adapter preserves that UUID for continuity and logs a warning.
- If no valid thread id or registry exists, generate and persist a UUID.

Before dispatch, the adapter must export:

```text
CERBERUS_HOST=amp
CERBERUS_ROOT=<adapter-resolved root>
CERBERUS_STATE_ROOT=<default or override>
CERBERUS_PROJECT_KEY=<workspace key>
CERBERUS_RUN_KEY=<resolved run key>
CLAUDE_PLUGIN_ROOT=<compat alias>
```

## Security and Safety Requirements

- Hook scripts are part of the trusted plugin boundary. Any actor that can
  modify the plugin cache or checkout can modify lifecycle code.
- Stop hooks must fail open on infrastructure errors to avoid trapping a user
  in an un-stoppable host session.
- Task completion hooks may fail closed only after they prove ownership of a
  Cerberus implementer task.
- Gemini reviewer invocations must use read-only policy/config paths.
- Reviewer prompt generation must not grant write capability to reviewers that
  are intended to be read-only.
- State paths must reject traversal and non-absolute state roots.
- Atomic writers must not leave partially written canonical JSON files.
- Scripts must avoid destructive git operations unless a future explicit
  user-facing command requires them.

## Verification Checklist

Runtime and integration tests should cover:

- Claude `SessionStart` writes expected env exports.
- Claude `Stop` allows no gate, blocks on P0/P1 or `FAIL`, and allows passed
  or resolved non-failing gates.
- Codex `SessionStart` and `UserPromptSubmit` write valid registry JSON and
  preserve active run keys across lifecycle id drift.
- Codex `Stop` always exits `0`, emits valid JSON, blocks only for documented
  blocking states, kills children on signals, and fails open on malformed
  state.
- `cerberus-skill-env` resolves the correct root, host, project key, and run
  key under Claude, Codex, Amp, and generic shells.
- `review-gate status --json` is non-mutating and uses the same run-key
  lookup as `wait`.
- `review-gate wait --json` returns documented statuses and exit codes.
- `review-gate spawn-*` commands validate arguments, create expected state,
  and preserve non-debate compatibility.
- Debate mode requires at least two reviewers, runs the correct round count,
  anonymizes peer content, writes debate telemetry, and promotes only final
  round outputs.
- `generate` rejects missing output dirs and unknown options, writes per-agent
  drafts, and tolerates missing telemetry helpers.
- `cerberus-task-completed-hook` ignores unrelated tasks, validates commit
  trailers, runs verification, detects dirty tracked files, rejects HEAD
  mutation, gates through code review, and marks exhausted rounds.
- `cerberus-teammate-idle-hook` suppresses only duplicate epochs and allows
  changed evidence through.
- `update-plugin` rewrites only Cerberus allowlist paths and preserves valid
  JSON.
- Amp toolbox `describe` and `execute` validate JSON, export host-neutral env,
  and propagate backend exit codes.

## Compatibility Requirements

- Existing Claude users must be able to keep using legacy env vars and
  `/cerberus:*` skill flows without changing invocation syntax.
- Codex skills must rely on the active-session registry rather than inventing
  a run key that the Stop hook cannot discover.
- Non-debate review schema bytes and runtime artifacts must remain compatible
  with existing consumers.
- `status --json` is the supported machine interface for host adapters and
  external orchestration. Human markdown reports may add columns or narrative,
  but JSON consumers should not depend on report table formatting.
- Scripts must keep Bash 3.2 portability because macOS system Bash remains a
  supported runtime.
