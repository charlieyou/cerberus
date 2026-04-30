# Cerberus on Amp CLI

> **Status:** Phase 2 release-ready (pending the human-required
> cross-host manual smoke; see [Manual Smoke Test](#manual-smoke-test-phase-2-release-gate)).
> This document is the user-facing install / configure / use guide for
> running Cerberus under Sourcegraph's Amp CLI. The shared backend
> (`bin/review-gate`, `bin/generate`, debate, telemetry) is identical
> to the Claude and Codex experiences; only the lifecycle adapter and
> packaging differ.
>
> **Feature scope (v1).** Amp ships with the **six Tier-1 review
> commands** (`review-code`, `review-plan`, `review-spec`, `ask-panel`,
> `status`, `clear-gate`) surfaced as a single Amp Toolbox tool.
> Generator workflows (`/cerberus:create-plan`, `/cerberus:create-spec`,
> `/cerberus:healthcheck`, `/cerberus:architecture-review`), Cerberus
> team-automation (`/cerberus:run-team`, the task-completed and
> teammate-idle hooks), and Amp lifecycle handlers (`session.start`,
> `agent.start`, `agent.end`, `tool.call`, `tool.result`) are **not
> supported on Amp in v1**. They remain Claude-only until Phase 3
> (generators) and Phase 4 (team automation) ship; the lifecycle
> handlers are not exposed by the Amp build inspected during the
> Phase 2 spike (see [Phase 2 Spike Findings](#phase-2-spike-findings)).

## Install

The Cerberus Amp surface ships as a single **Amp Toolbox** shell
script: `.amp/toolbox/cerberus.sh`. Amp discovers toolbox tools by
scanning `$AMP_TOOLBOX` (a colon-separated list of directories or a
single absolute file path) and invokes each executable per the
[Amp Toolbox protocol](https://ampcode.com/manual) (`TOOLBOX_ACTION=describe`
to enumerate the tool's commands; `TOOLBOX_ACTION=execute` with JSON
parameters on stdin to run a command). No Amp-specific plugin runtime
is required — the script is a plain `bash` executable.

> **Divergence from the original plan.** The plan
> (`docs/2026-04-29-codex-amp-plugin-port-plan.md`) originally pre-committed
> the Amp surface to a TypeScript plugin at `.amp/plugins/cerberus.ts`
> registered via `amp.registerCommand`. The Phase 2 spike (T012) found
> that the Amp build available to this team (CLI 0.0.1777572045-g97f3b8,
> released 2026-04-30) does **not** expose a `.amp/plugins/` loader, an
> `amp.registerCommand` API, or the named lifecycle events the plan
> referenced. Amp's actual user-extension surface in this build is the
> Amp Toolbox (subprocess scripts driven by `TOOLBOX_ACTION`). T013 and
> T014 retargeted the surface to `.amp/toolbox/cerberus.sh`. See
> [Phase 2 Spike Findings](#phase-2-spike-findings) for the full
> rationale.

### Prerequisites

The Cerberus shared backend is `bash` + `jq` + `python3`. You also
need the reviewer CLIs you intend to enable; missing reviewers are
skipped with a warning, so a one- or two-reviewer install is fine.

| Tool | Purpose | Install hint |
|---|---|---|
| `bash` (≥3.2) | Backend runtime; toolbox script entry point | system |
| `jq` | JSON describe payload + atomic registry write | `brew install jq` / `apt install jq` |
| `python3` | Atomic JSON writers / hash helpers | system |
| `uuidgen` | Fallback UUID when `AMP_THREAD_ID` is absent (optional — `/proc/sys/kernel/random/uuid` is consulted next, then a PID/RANDOM blob) | system |
| `amp` | Sourcegraph Amp CLI (host) | [Amp CLI](https://ampcode.com/) |
| `codex` | OpenAI Codex reviewer | [OpenAI CLI](https://platform.openai.com/docs/guides/command-line) |
| `gemini` | Google Gemini reviewer | [Gemini CLI](https://ai.google.dev/gemini-api/docs/get-started/cli) |
| `claude` | Anthropic Claude reviewer | [Claude Code](https://docs.anthropic.com/en/docs/claude-code) |

> **Bun runtime not required.** The Amp surface ships as a `bash`
> script, not as TypeScript. Operators who already have Amp installed
> get the bundled `~/.amp/bin/bun` (Bun 1.3.0 on the spike host) for
> free, but Bun is **not** consulted by `.amp/toolbox/cerberus.sh`. CI
> machines that do not run Amp do not need Bun to exercise
> `bin/tests/test-amp-shell-helper.sh`; only `bash`, `jq`, and standard
> POSIX utilities are needed.

### Step 1 — Clone the repository

Clone the Cerberus repository (or your fork) to a stable absolute path
on the machine that runs Amp. The directory you clone into is your
**install root** — the directory that contains `bin/`, `skills/`,
`.amp/toolbox/`, etc.

```bash
git clone https://github.com/charlieyou/cerberus.git ~/code/cerberus
```

### Step 2 — Wire the toolbox script into Amp

Add `<install-root>/.amp/toolbox` to your `AMP_TOOLBOX` environment
variable so Amp discovers `cerberus.sh` on every CLI invocation. Amp
treats `AMP_TOOLBOX` as a colon-separated path list (a single absolute
file path also works).

```bash
# In ~/.zshrc or ~/.bashrc:
export AMP_TOOLBOX="$HOME/code/cerberus/.amp/toolbox${AMP_TOOLBOX:+:$AMP_TOOLBOX}"
```

Alternatively, symlink the script into a directory Amp already scans
(typically `~/.amp/toolbox/` if it exists on your platform):

```bash
mkdir -p ~/.amp/toolbox
ln -s "$HOME/code/cerberus/.amp/toolbox/cerberus.sh" ~/.amp/toolbox/cerberus.sh
```

After Step 2, restart Amp (or start a new thread) so the new toolbox
path is picked up.

### Verifying the install

From an Amp thread, ask the model to enumerate available toolbox tools
or describe `cerberus`. The tool's describe payload lists six
commands in the canonical order:

```text
review-code, review-plan, review-spec, ask-panel, status, clear-gate
```

You can also exercise the describe action directly to confirm
discovery:

```bash
TOOLBOX_ACTION=describe ~/code/cerberus/.amp/toolbox/cerberus.sh
```

The output is a single JSON document with `name: "cerberus"`,
`status: "active"`, and a `commands` array enumerating the six
commands above. If the script exits non-zero or the body is not valid
JSON, check the Troubleshooting section below.

## Repo-Trust and Security Model

Amp's Toolbox execution model runs the configured toolbox scripts as
subprocesses on every tool invocation. `.amp/toolbox/cerberus.sh` is
shipped from your install root and invoked by absolute path, so the
**install root is part of your trusted compute boundary** — anyone
who can write to that directory can change what runs every time the
model invokes the Cerberus tool.

Concrete consequences:

- **Pin your install root.** Don't install Cerberus into a directory
  that is writable by other users, scripts, or untrusted package
  managers. `/opt/cerberus` (root-owned, world-readable) and
  `~/code/cerberus` (your user only) are reasonable choices;
  `/tmp/cerberus` is not.
- **Audit the install root before exporting `AMP_TOOLBOX`.** The
  directory listed in `AMP_TOOLBOX` becomes a literal subprocess
  invocation surface. Treat it with the same care you treat any
  other auto-loaded executable path on your system.
- **Sandbox / read-only constraints come from the reviewer CLIs.**
  The Cerberus backend itself does not gate writes; reviewer-side
  read-only enforcement (e.g. Gemini's Policy Engine via
  `config/gemini-readonly-policy.toml`) is what keeps reviewers
  from modifying your repo. If you change `--agents` or disable the
  policy file, that protection goes with it.

The toolbox script writes exactly one file: an atomic registry under
`~/.cerberus/runtime/amp/<workspace-key>/active-session.json`. No
files outside `~/.cerberus/` are touched by `.amp/toolbox/cerberus.sh`
itself; the spawned `bin/review-gate` subprocess writes review state
under `~/.cerberus/projects/<workspace-key>/<run-key>/` per the shared
backend contract.

## Commands

All six Tier-1 workflows are surfaced through the single Amp Toolbox
tool `cerberus`. Each command is selected by the `command` field in
the JSON parameter body Amp posts on stdin during
`TOOLBOX_ACTION=execute`. The exact way Amp's UI exposes a Toolbox
tool to the user is host-dependent; the **command name** is the
canonical handle.

The toolbox dispatcher exports `CERBERUS_HOST=amp` before handing off
to the shared backend, so `gate-state.json` is recorded with
`host: "amp"` and state is rooted under the Amp runtime tree. The
dispatcher also resolves `CERBERUS_RUN_KEY` from `AMP_THREAD_ID` (or
the persisted fallback registry — see [Run-Key Durability](#run-key-durability))
before dispatch, so every command works correctly whether Amp set
`AMP_THREAD_ID` or not.

| Command | Backend invocation | Required JSON params | Optional JSON params |
|---|---|---|---|
| `review-code` | `bin/review-gate spawn-code-review` | none | (none — pass review flags via the Amp CLI environment if needed) |
| `review-plan` | `bin/review-gate spawn-plan-review <plan_path>` | `plan_path` (absolute path) | (none) |
| `review-spec` | `bin/review-gate spawn-spec-review <spec_path>` | `spec_path` (absolute path) | (none) |
| `ask-panel` | `bin/review-gate spawn-ask <question>` then `wait --json --finalize` | `question` (free text) | (none) |
| `status` | `bin/review-gate status --json` | none | (none — state is read-only; the resolver targets the active run) |
| `clear-gate` | `bin/review-gate resolve --reason <reason>` | none | `reason` (defaults to `"manual clear via Amp toolbox"`) |

Every successful invocation prints a single header line on stdout
before any backend output:

```text
Cerberus run key: <run-key>
```

This is the explicit pass-through hook documented in plan §Phase 2
exit criteria — users can copy the run key into a subsequent Amp
thread or external script that needs to address the same review run
(e.g. `bin/review-gate wait --json --session-key <run-key>`).

### `review-code`

Spawns the multi-model code-review panel against the current
uncommitted git diff in the workspace and returns immediately. The
panel runs asynchronously; poll `status` (described below) to observe
progress, or wait directly:

```bash
"$CERBERUS_ROOT/bin/review-gate" wait --json --session-key <run-key>
```

Review the diff modes (`--uncommitted`, `--base`, `--commit`, range)
in the main [README](../README.md#code-review). Amp v1 invokes
`spawn-code-review` with no flags; if you need a non-default diff
scope, run `bin/review-gate spawn-code-review` directly from a shell.

### `review-plan` and `review-spec`

Both **require an explicit absolute path** to the plan or spec
markdown file in the JSON params (`plan_path` or `spec_path`). v1 of
the Amp port does not consult a plan or spec registry; the dispatcher
exits with a clear error if the field is missing. There is no
Claude-style "use the most recent plan" fallback. (See
[Limitations](#limitations).)

### `ask-panel`

Spawns the panel with the user's question and **waits** for the panel
to finish (`bin/review-gate wait --json --finalize`). The synthesized
panel answer is emitted on stdout for the model to incorporate into
the in-thread response. Use this for open-ended questions that benefit
from a Cerberus consensus (it is the closest analogue to the
Claude `/cerberus:ask` slash command).

### `status`

Read-only. Emits a single JSON document on stdout. The body has two
distinct shapes depending on what the resolver finds:

- **Active gate** (canonical body): top-level keys include
  `schema_version`, `host` (`amp` for runs created from Amp),
  `project_key`, `run_key`, `review_dir`, `gate_status` (one of
  `pending`, `awaiting_decision`, `resolved`, or `unknown`),
  `consensus_verdict` (one of `pass`, `fail`, `needs_revision`, or
  JSON `null`), `reviewers`, `pending_reviewers`,
  `aggregated_findings`, `parse_errors`.
- **Special / error body**: a smaller body keyed off `status` instead
  of `gate_status`. The two values you'll observe are
  `{"status":"no_active_gate"}` (exit 4) and
  `{"status":"unknown","error":"malformed_state"}` (exit 0,
  failure-open path).

Exit codes match the shared backend: `0` = body emitted (active gate
or malformed-state failure-open), `4` = no active gate, anything else
= backend failure (body still valid JSON). The command **never**
mutates state — this is the contract verified by
`bin/tests/test-status-command.sh`.

### `clear-gate`

Operator escape hatch. Resolves the active gate so the thread can move
on without completing the review cycle. The default `reason` is
`"manual clear via Amp toolbox"` so the audit trail makes the source
of the clear unambiguous; pass `reason` in the JSON params to override.

## Limitations

Amp's Phase 2 surface is intentionally narrower than the Claude
experience. The following capabilities are **not supported on Amp in
v1**:

- **`review-plan` and `review-spec` require explicit paths.** Non-Claude
  hosts have no plan or spec registry per plan §Out Of Scope (plan
  L165-L166). The dispatcher rejects calls without `plan_path` or
  `spec_path`.
- **Generator workflows are Claude-only.** `/cerberus:create-plan`,
  `/cerberus:create-spec`, `/cerberus:healthcheck`, and
  `/cerberus:architecture-review` are not surfaced as Amp Toolbox
  commands. They remain Claude-only until Phase 3 (plan §Out Of Scope,
  §Phase 3).
- **Cerberus team automation is Claude-only.**
  `/cerberus:run-team`, the `TaskCompleted` hook, and the
  `TeammateIdle` hook are not available from Amp. They remain
  Claude-only until Phase 4 (plan §Out Of Scope, §Phase 4).
- **Amp lifecycle handlers are out of scope.** v1 surfaces the six
  Tier-1 commands only. There is no equivalent of Claude's
  `SessionStart` / `Stop` hook or Codex's `SessionStart` / `Stop`
  lifecycle adapter (plan L953-L955). The Phase 2 spike confirmed that
  the Amp build inspected does not expose lifecycle callbacks
  (`session.start`, `agent.start`, `agent.end`, `tool.call`,
  `tool.result`) to user code; future Amp releases that publish such
  hooks may re-evaluate.
- **No `--debate` flag pass-through from the Amp tool.** v1 invokes
  the backend without `--debate`. Operators who want
  [Debate Mode](../README.md#debate-mode) can run `bin/review-gate`
  directly from a shell with the appropriate run key.

## Run-Key Durability

The Amp Toolbox tool resolves `CERBERUS_RUN_KEY` per the **OQ-3
contract** documented in [Phase 2 Spike Findings](#phase-2-spike-findings).
Summary of the algorithm (canonical source: header comment of
`.amp/toolbox/cerberus.sh`):

1. **Primary key — `AMP_THREAD_ID`.** Amp propagates the current
   thread id into every subprocess via the `AMP_THREAD_ID` (and
   `AMP_CURRENT_THREAD_ID`) environment variable, formatted as
   `T-<lower-hex-with-hyphens>` (e.g.
   `T-019de015-d2d1-70dc-ac7c-bf5ccc46dd68`). When this variable is
   present and well-formed, the dispatcher uses it as the run key
   verbatim and persists `{ run_key, amp_thread_id }` into the
   workspace registry.
2. **UUID-fallback continuity case.** If a previous invocation in the
   same workspace ran *without* `AMP_THREAD_ID` (so the registry
   recorded `amp_thread_id: null` and a fallback UUID), the dispatcher
   keeps the persisted UUID as the run key — even if a valid
   `AMP_THREAD_ID` is now available — so any review-gate state
   already addressed under the UUID directory remains reachable.
   A single warning line is emitted to stderr so the operator knows
   a thread id is available but is being ignored for continuity.
   Override this by exporting `CERBERUS_RUN_KEY=<thread-id>` to flip
   the workspace into thread-id mode.
3. **Thread → thread transitions are new threads.** If the registry
   recorded a different valid `AMP_THREAD_ID` previously and a new
   one arrives, the dispatcher treats it as a normal new Amp thread
   and rebinds the registry. Without lifecycle hooks the dispatcher
   cannot distinguish a true mid-thread re-key from a legitimate new
   thread, so we choose the conservative behavior of trusting the
   live thread id.
4. **`AMP_THREAD_ID` absent / malformed.** The dispatcher reads the
   persisted run key from the workspace registry. If no registry
   exists, it generates a fresh UUID (via `uuidgen`,
   `/proc/sys/kernel/random/uuid`, or a PID/RANDOM blob in that order)
   and atomic-writes the registry with `amp_thread_id: null` so
   subsequent invocations recognize the workspace as UUID-mode.

The registry shape is:

```json
{
  "schema_version": 1,
  "host": "amp",
  "workspace_root": "/Users/me/code/myproject",
  "project_key": "-Users-me-code-myproject",
  "run_key": "T-019de015-d2d1-70dc-ac7c-bf5ccc46dd68",
  "amp_thread_id": "T-019de015-d2d1-70dc-ac7c-bf5ccc46dd68",
  "last_seen": "2026-04-30T12:34:56Z"
}
```

The atomic-write idiom is identical to `bin/codex-session-init`:
write to `<file>.tmp.$$`, validate with `jq empty`, then `mv` to the
final path. `mv` is POSIX-atomic on the same filesystem; a kill
mid-write leaves either the previous valid registry or no registry,
never a torn write.

## Reattach Behavior

The Amp Toolbox tool maintains **no in-process memory** across
invocations — every `TOOLBOX_ACTION=execute` call is a fresh `bash`
subprocess. All durable state lives on disk:

- The workspace registry at
  `~/.cerberus/runtime/amp/<workspace-key>/active-session.json`
  records the current run key for the workspace.
- The shared backend's gate state at
  `~/.cerberus/projects/<workspace-key>/<run-key>/gate-state.json`
  records the active review's status, reviewer outputs, and consensus
  verdict.

This means **plugin/CLI reload mid-review reattaches automatically**:
when the Amp CLI restarts (or the user resumes a thread via
`amp threads continue <id>`), the next invocation of the Cerberus
tool reads the registry, recovers the run key, and queries the same
shared backend gate state. There is no in-memory cache to invalidate
and no shutdown hook to run. Plan §Reattach (L948-L949, L962) calls
this out as the canonical reattach contract; the Amp surface
implements it by being entirely stateless on the tool side.

The header line emitted on every successful invocation
(`Cerberus run key: <run-key>`) is the explicit pass-through hook for
external callers and operators who need to address the same run from
outside Amp (e.g. from a shell, from a CI script, or from a sibling
Claude/Codex session in the same workspace).

## Troubleshooting

### `AMP_THREAD_ID` ignored after a UUID-fallback session

**Symptom:** A workspace ran first without `AMP_THREAD_ID` (UUID was
generated); a subsequent invocation has `AMP_THREAD_ID` set, but the
run key remains the original UUID and the dispatcher emits a warning
of the form:

```text
cerberus.sh: WARNING: AMP_THREAD_ID '<id>' is now available, but a
fallback-UUID run_key '<uuid>' is already persisted for this
workspace; reusing UUID for continuity.
```

**Fix:** This is intentional — the dispatcher prioritizes continuity
of any review-gate state already addressed under the UUID directory
over switching to thread-id mode mid-workspace. To force a switch,
either:

- Export `CERBERUS_RUN_KEY=<thread-id>` once to flip the workspace,
  or
- Delete the registry to start fresh:

```bash
rm ~/.cerberus/runtime/amp/<workspace-key>/active-session.json
```

The next invocation will re-resolve the run key from the live
`AMP_THREAD_ID`.

### `bin/review-gate` not found

**Symptom:** `cerberus.sh: backend not found or not executable: <path>`
on stderr; non-zero exit.

**Fix:** The dispatcher resolves `bin/review-gate` relative to its own
location (`<install-root>/.amp/toolbox/cerberus.sh` →
`<install-root>/bin/review-gate`). Confirm:

- The toolbox script lives inside the Cerberus install root (not
  copied into a flat `~/.amp/toolbox/` without the surrounding repo).
- `bin/review-gate` is executable (`chmod +x`).
- If you copied or symlinked the script outside the install root,
  set `CERBERUS_ROOT=/Users/me/code/cerberus` so the dispatcher
  resolves the backend explicitly.

### Reviewer CLI missing or `jq` not installed

**Symptom:** Reviewer panel reports `0 reviewers available` or the
backend exits non-zero with `jq: command not found`. The dispatcher
propagates the backend's exit code and stderr verbatim.

**Fix:** Install the missing CLI (see [Prerequisites](#prerequisites)).
The Cerberus backend skips missing reviewers with a warning, but it
hard-requires `jq`, `bash`, and `python3`. You can run with one or
two reviewers if the third CLI isn't available; `--debate` mode
hard-errors with fewer than two reviewers.

### `Cerberus: Status` returns `no_active_gate` after CLI restart

**Symptom:** A review was running, Amp restarted, and `status` now
returns `{"status":"no_active_gate"}`.

**Fix:** Confirm the workspace registry survives:

```bash
cat ~/.cerberus/runtime/amp/<workspace-key>/active-session.json
```

If the `run_key` matches what you expected, the registry is intact;
the `no_active_gate` body means the shared backend completed and
cleared its in-flight state. The recovery path is to re-spawn the
review:

```bash
TOOLBOX_ACTION=execute ~/code/cerberus/.amp/toolbox/cerberus.sh \
    <<<'{"command":"review-code"}'
```

If `run_key` is missing or the registry file is absent, `SessionStart`
equivalent never ran (Amp does not expose a SessionStart hook in v1);
just invoke any Cerberus command and the dispatcher will write a fresh
registry on first call.

### `Cerberus: Clear Gate` resolves a different run than expected

**Symptom:** `clear-gate` resolves a different run than the one
displayed by `status`.

**Fix:** The dispatcher resolves the run key from `AMP_THREAD_ID`
first, then the persisted registry. If `status` was inspected by
explicitly passing `--session-key <K>` to the backend (outside the
toolbox tool), that's the cause. To target a non-active run, set
`CERBERUS_RUN_KEY=<K>` in the environment Amp invokes the tool from:

```bash
CERBERUS_RUN_KEY=<run-key> \
    TOOLBOX_ACTION=execute ~/code/cerberus/.amp/toolbox/cerberus.sh \
    <<<'{"command":"clear-gate","reason":"manual clear from Amp"}'
```

The toolbox script honors `CERBERUS_RUN_KEY` because the shared
backend's run-key resolver (`__cerberus_resolve_run_key`) gives it
precedence over `AMP_THREAD_ID` and the persisted registry.

### Toolbox describe action emits no commands

**Symptom:** `TOOLBOX_ACTION=describe ~/code/cerberus/.amp/toolbox/cerberus.sh`
emits a JSON body with an empty or missing `commands` array.

**Fix:** This indicates `jq` is missing on the path Amp invokes the
script from. The describe action requires `jq` to render the canonical
six-command body; without it, the script falls back to a hard-coded
JSON literal, which still lists all six commands but signals that the
local environment is not fully provisioned. Install `jq` (`brew
install jq` / `apt install jq`) and re-run.

## Manual Smoke Test (Phase 2 Release Gate)

The agent-completable verification is covered by the Phase 0/1/2
automated test suite (`bin/tests/test-host-neutral-state.sh`,
`bin/tests/test-status-command.sh`,
`bin/tests/test-codex-session-registry.sh`,
`bin/tests/test-codex-stop-hook.sh`,
`bin/tests/test-amp-shell-helper.sh`, plus the existing Claude
regression suite). Before tagging the **Cerberus vX+2** release the
maintainer also runs the following manual cross-host smoke on a clean
install. None of these are automated — an LLM agent cannot
autonomously verify them — they're a release gate, not a CI gate.

1. **Install.** Clone the repo and add
   `<install-root>/.amp/toolbox` to `AMP_TOOLBOX` per
   [Install](#install). Confirm the `describe` action emits the
   six-command JSON body.
2. **Three-host start.** In the same git repo, start a code review
   from each host with distinct workspaces or threads:
   - **Claude Code:** `/cerberus:review-code`.
   - **Codex CLI:** invoke the `review-code` skill (per
     [`docs/CODEX.md`](CODEX.md)).
   - **Amp CLI:** invoke the `cerberus` toolbox tool with
     `{"command":"review-code"}`.
3. **Three independent state directories.** Confirm three
   `gate-state.json` files coexist without colliding:
   - Claude: `~/.claude/projects/<workspace-key>/cerberus/<sid>/gate-state.json`
   - Codex: `~/.cerberus/projects/<workspace-key>/<run-key>/gate-state.json`
     with `host: "codex"`
   - Amp: `~/.cerberus/projects/<workspace-key>/<run-key>/gate-state.json`
     with `host: "amp"`
   Each `host` field matches its origin host.
4. **Reattach across plugin reload.** Mid-review (panel still
   `pending`), restart the Amp CLI (or run
   `amp threads continue <id>` against the original thread).
   Re-invoke the `cerberus` tool with `{"command":"status"}`.
   Confirm the same `run_key` is reported and the in-flight gate
   state is reattached.
5. **`ask-panel` synthesis.** From Amp, invoke
   `{"command":"ask-panel","question":"Should we ship this design?"}`.
   Confirm the panel answer is synthesized and emitted on stdout for
   the in-thread response.
6. **`clear-gate`.** From Amp, invoke
   `{"command":"clear-gate","reason":"manual clear from Amp smoke"}`.
   Confirm `gate-state.json.status == "resolved"` for the Amp-originated
   run.
7. **No-regression smoke.** After the Phase 2 release lands, re-run a
   Claude review and a Codex review in the same workspace and confirm
   both behave byte-for-byte identically to before the Amp port (no
   shared-backend regression).

If any of the seven steps fails, do **not** tag the release. The Phase
2 exit criteria (plan L959-L965) require all seven to pass on a clean
cross-host install, plus the full Phase 0 + Phase 1 + Phase 2
automated test suite green.

### Phase 2 Exit Criteria Recap

These are the testable exit criteria from the plan
(`docs/2026-04-29-codex-amp-plugin-port-plan.md` L957-L965):

| Criterion | Verified by |
|---|---|
| Amp commands register under the toolbox surface | `bin/tests/test-amp-shell-helper.sh` (Happy A/B) — T013 + T014 |
| Amp can start code, plan, and spec reviews through the shared backend | `bin/tests/test-amp-shell-helper.sh` (Happy C, Cases 4-5) + manual smoke step 2 |
| Amp can reattach to status after plugin reload or CLI restart | Manual smoke step 4 |
| Amp `ask-panel` returns a synthesized in-thread answer | Manual smoke step 5 |
| Amp `clear-gate` resolves the intended run | Manual smoke step 6 |
| Run key surfaced in command stdout for user pass-through | `bin/tests/test-amp-shell-helper.sh` (Case 6) |
| Claude and Codex behavior remain unchanged | Existing `bin/tests/*.sh` (regression) + manual smoke step 7 |

Once all seven rows are green (automated + manual), the Cerberus vX+2
release tag may be cut.

## Phase 2 Spike Findings

These findings are the resolution of **OQ-3** (Amp `ctx.thread.id`
durability across command handlers and lifecycle events) from
`docs/2026-04-29-codex-amp-plugin-port-plan.md`, recorded
**2026-04-30**. They are preserved here for auditability of the
design decisions that shaped Phase 2; future contributors can revisit
them when an authoritative Amp plugin runtime or schema lands.

> **Source disclosure.** This spike is **best-effort** and partly
> divergent from the plan's pre-spike framing. The plan §Host
> Assumptions (L153-L163) describes Amp's extension surface as a
> TypeScript plugin loaded from `.amp/plugins/`, registered via
> `amp.registerCommand`, with lifecycle events `session.start`,
> `agent.start`, `agent.end`, `tool.call`, `tool.result`, gated by an
> `experimental` directive comment and `PLUGINS=all amp`. The plan's
> intended verification path was: "Write a minimal Amp plugin that
> logs `ctx.thread.id` from each lifecycle event ... and from a
> registered command. Run `PLUGINS=all amp` and exercise."
>
> The spike author had access to **Amp CLI 0.0.1777572045-g97f3b8**
> (released 2026-04-30) on macOS. Static inspection of the published
> bundle (`@sourcegraph/amp` package, `dist/main.js`) and the public
> CLI surface (`amp --help`, `amp skill --help`, `amp tools make
> --help`) finds **no evidence** of:
>
> - A `.amp/plugins/` TypeScript loader.
> - An `amp.registerCommand` API.
> - Named lifecycle events `session.start`, `agent.start`,
>   `agent.end`, `tool.call`, `tool.result` reachable from user code.
> - A `PLUGINS=all` environment-variable gate that changes loader
>   behavior (running `PLUGINS=all amp threads list` produces
>   identical output to `amp threads list`; the bundle contains zero
>   `PLUGINS=` references).
>
> Therefore the OQ-3 spike is reframed below to answer the
> **substantive** question (is Amp's run key durable enough to use as
> the default Cerberus run key?) using Amp's actual extension
> mechanism in this build, while flagging the divergence so that
> T013/T014/T015 can land an extension surface that matches what Amp
> actually ships.

### Amp extension surfaces in 0.0.1777572045 (the build the spike inspected)

Amp 0.0.1777572045 exposes **two** documented user-extension
mechanisms via the public CLI:

1. **Toolbox tools** — subprocess scripts placed under `$AMP_TOOLBOX`
   that follow the [Amp Toolbox protocol](https://ampcode.com/manual)
   (driven by `TOOLBOX_ACTION=describe|execute` env var; tool params
   on stdin as JSON; tool output on stdout/stderr is fed back to the
   model). Generated by `amp tools make <name> [--bun|--zsh|--bash]`.
   The default skeleton is a Bun/TypeScript script.
2. **Skills** — installed via `amp skill add <source>` (GitHub or
   local). Listed by `amp skill list`. Skill files are markdown +
   manifest, similar in spirit to Codex skills.

Neither surface is a TypeScript plugin runtime with lifecycle
callbacks in the shape the plan assumed. The closest mapping is
**toolbox tools** — Cerberus's six review commands (Review Code,
Review Plan, Review Spec, Ask Panel, Status, Clear Gate) translate
naturally to a single toolbox tool dispatching on a `command` field.
T013 landed the skeleton; T014 implemented dispatch + run-key
resolution; T015 (this task) finalized the user-facing documentation
and the cross-host smoke.

### OQ-3 — Amp run-key durability (best-effort)

**Resolution:** **Stable in tool invocations.** Amp propagates the
current thread id to subprocess tools via the `AMP_THREAD_ID` (and
`AMP_CURRENT_THREAD_ID`) environment variable, with format
`T-<uuid7>` (lower-case hex with hyphens). The id is durable across
multiple tool invocations within the same thread, across `amp
threads continue <id>` resumes after CLI restart, and across plugin
or settings reloads (the id is owned by the thread record on disk,
not by the in-process plugin/tool memory).

**Evidence:**

1. The shipped bundle (`/Users/<user>/.amp/package/dist/main.js` in
   the install surface) contains literal env-write expressions
   ```
   AMP_THREAD_ID: J?.thread?.id || ""
   AMP_CURRENT_THREAD_ID: X.thread?.id || ""
   ```
   in two distinct subprocess-launch sites. This means every tool
   that Amp invokes receives the live thread id in its environment,
   sourced from the same `thread.id` field the plan referred to as
   `ctx.thread.id`.
2. `amp threads list` displays thread ids in the `T-<uuid7>` format
   (e.g. `T-019de015-d2d1-70dc-ac7c-bf5ccc46dd68`), and the same id
   round-trips through `amp threads continue <id>`, `amp threads
   markdown <id>`, and `amp threads export <id>`. Thread state is
   persisted under `~/.amp/file-changes/T-<uuid7>/` and
   `~/.amp/in/T-<uuid7>.log`, confirming on-disk thread persistence
   independent of the running CLI process.
3. The bundled environment-variable register (`AMP_API_KEY`,
   `AMP_CONNECT`, `AMP_CURRENT_THREAD_ID`, `AMP_DEBUG`, `AMP_HOME`,
   `AMP_LOG_FILE`, `AMP_LOG_LEVEL`, `AMP_RIPGREP_PATH`,
   `AMP_SETTINGS_FILE`, `AMP_THREAD_ID`, `AMP_TOOLBOX`, `AMP_URL`,
   etc.) treats `AMP_THREAD_ID` as a first-class published name.

**Lifecycle (`session.start`, `agent.start`, ...):** **Not durable
because not exposed.** No public lifecycle-callback surface exists in
this Amp build. A toolbox tool only runs when the model (or a slash
command) invokes it; it has no equivalent of Claude's `Stop` or
`SessionStart` hook. The plan's existing carve-out — "Lifecycle
handlers ... out of v1 scope. Explicit commands only." (plan §954)
— is therefore correct on substance, although the underlying
*reason* differs from the plan's framing: the lifecycle surface is
absent, not merely deferred.

**Mapping to the plan's decision tree (plan §T012 task context):**

> - Stable everywhere → use `ctx.thread.id` as default; fallback dead
>   code (still implemented for resilience).
> - **Stable in commands but not lifecycle** → use thread id in
>   commands, fallback to persisted UUID in lifecycle handlers (out
>   of v1 anyway).
> - Unstable → use UUID-from-creation-time persistence as primary;
>   thread id is opportunistic only.

**Selected branch: "Stable in commands but not lifecycle."** T013 and
T014 implemented:

1. `process.env.AMP_THREAD_ID` (read from the toolbox-tool subprocess
   environment) is the **default** run key. Read the field name from
   env, not via a `ctx` argument — the toolbox protocol doesn't pass
   a context object.
2. `AMP_THREAD_ID` is treated as opportunistic: if it's absent, empty,
   or not in the expected `T-<uuid7>` shape, fall back to the
   workspace-scoped persisted UUID at
   `~/.cerberus/runtime/amp/<workspace-key>/active-session.json`
   (mirrors the Codex registry shape, plan §159-163). This fallback
   remains *correct insurance* — not dead code — because future Amp
   builds may invoke tools without setting `AMP_THREAD_ID` (e.g. a
   pre-thread-creation hook surface, or a non-thread context).
3. The resolved run key is surfaced in tool stdout for explicit
   pass-through (plan exit criterion §964), so users can verify which
   id was used and override with `--run-key` / `CERBERUS_RUN_KEY`.

### Verification limits and follow-ups

The plan's intended human verification step ("A human runs `PLUGINS=all
amp` against a minimal logging plugin and reports the observed
durability of `ctx.thread.id` across command invocations, plugin
reloads, and (if relevant) lifecycle events") is **not runnable
against Amp 0.0.1777572045** because the assumed plugin runtime is
not present. The substantive durability question is answered above
via static evidence (env-write sites, on-disk thread persistence,
CLI-level thread continue) plus the live `amp threads list` output.

Implementation history:

- T013 landed the skeleton at `.amp/toolbox/cerberus.sh` (toolbox-tool
  surface; six commands enumerated by `TOOLBOX_ACTION=describe`).
- T014 implemented dispatch + the run-key resolver:
  `AMP_THREAD_ID` (validated `T-<uuid7>` shape) → persisted UUID
  fallback → fresh UUID + atomic write of
  `~/.cerberus/runtime/amp/<workspace-key>/active-session.json`.
- T015 (this task) finalized the user-facing sections of this
  document, linked them from the host catalog in `README.md`, and
  documented the cross-host manual smoke as the human-required
  release blocker.

If a future Amp release publishes a TypeScript plugin runtime
matching the plan's original assumption, the toolbox-tool path can
either remain (it's the smaller surface) or be migrated; the run-key
resolver code does not change because it already reads from env.

### Operator-facing prerequisite confirmation

- Amp CLI installs a private Bun runtime at
  `~/.amp/bin/bun`. Running `~/.amp/bin/bun --version` returns
  `1.3.0` on the spike host. The plan §227-229 "Bun (or the Amp CLI
  which bundles Bun) installed on Phase 2 CI and smoke-test machines"
  prerequisite is satisfied automatically by an Amp install — no
  separate Bun install is required for users who already have Amp.
  Note that the shipped surface is a `bash` script, not Bun, so this
  prerequisite is informational only.
- Operators **without** Amp installed (e.g. CI machines that only run
  Cerberus's local tests) do not need Bun separately; the shipping
  surface is plain `bash` + `jq`.
