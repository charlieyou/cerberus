# Cerberus on Codex CLI

> **Status:** Phase 1 release-ready. This document is the user-facing
> install / configure / use guide for running Cerberus under OpenAI's
> Codex CLI. The shared backend (`bin/review-gate`, `bin/generate`,
> debate, telemetry) is identical to the Claude experience; only the
> lifecycle adapters and packaging differ.
>
> **Feature scope (v1).** Codex ships with the **six Tier-1 review
> skills** (`review-code`, `review-plan`, `review-spec`, `ask`,
> `status`, `clear-gate`) and the **`SessionStart` + `Stop`** lifecycle
> hooks. Generator workflows (`/cerberus:create-plan`,
> `/cerberus:create-spec`, `/cerberus:healthcheck`,
> `/cerberus:architecture-review`) and Cerberus team-automation
> (`/cerberus:run-team`, the task-completed and teammate-idle hooks)
> are **not supported on Codex in v1**. They remain Claude-only until
> Phase 3 (generators) and Phase 4 (team automation) ship.

## Install

The Cerberus Codex package ships in **two pieces** that you install
separately. The first piece is the plugin manifest plus the skills the
Codex skill picker reads; the second piece is a lifecycle hook template
you wire into Codex's hooks configuration so `SessionStart` and `Stop`
boundaries flow through Cerberus. Codex does not have a Claude-style
`/plugin install` flow today, so both pieces are user-driven.

### Prerequisites

The shared Cerberus backend is `bash` + `jq` + `python3`. You also need
the reviewer CLIs you intend to enable; missing reviewers are skipped
with a warning, so a one- or two-reviewer install is fine.

| Tool | Purpose | Install hint |
|---|---|---|
| `bash` (≥3.2) | Backend runtime | system |
| `jq` | JSON processing | `brew install jq` / `apt install jq` |
| `python3` | Atomic JSON writers / hash helpers | system |
| `codex` | OpenAI Codex CLI (host + reviewer) | [OpenAI CLI](https://platform.openai.com/docs/guides/command-line) |
| `gemini` | Google Gemini reviewer | [Gemini CLI](https://ai.google.dev/gemini-api/docs/get-started/cli) |
| `claude` | Anthropic Claude reviewer | [Claude Code](https://docs.anthropic.com/en/docs/claude-code) |

### Step 1 — Plugin manifest + skills

Clone the Cerberus repository (or your fork) somewhere stable on the
machine that runs Codex. The directory you clone into is your
**install root** — the directory that contains `bin/`, `skills/`,
`.codex-plugin/`, `templates/`, etc.

```bash
git clone https://github.com/charlieyou/cerberus.git ~/code/cerberus
```

The repository ships `.codex-plugin/plugin.json` at the install root.
That manifest declares the package name (`cerberus`), version, and the
six skill descriptors Codex's skill picker reads from
`skills/cerberus/*.md`. No further action is required for the manifest
piece; once Codex's plugin discovery sees `.codex-plugin/plugin.json`,
all six skills become invocable through whatever skill-invocation UX
your Codex install exposes (typically `/skill <name>`,
`@<skill-name>`, or a skill picker).

> **Best-effort manifest.** No public, versioned schema for
> `.codex-plugin/plugin.json` was published as of 2026-04-30, so the
> shipping manifest is best-effort and modeled on
> `.claude-plugin/plugin.json` plus an explicit `skills[]` array. See
> [Phase 1 Spike Findings](#phase-1-spike-findings) below for the full
> schema rationale. If a future Codex release publishes an
> authoritative schema, the manifest will be updated in place.

### Step 2 — Lifecycle hooks (`SessionStart` + `Stop`)

The Cerberus shared backend resolves run state from environment
variables and an on-disk session registry. Codex doesn't expose a
stable session-id env var, so the `SessionStart` hook
(`bin/codex-session-init`) writes the registry that the skills and the
`Stop` hook later read. You must install the lifecycle hook template
into your Codex hooks configuration for skills to behave correctly
across stop boundaries.

The repository ships the hook template at
`templates/codex-hooks.json`. The template uses a literal placeholder
`<CERBERUS_INSTALL_ROOT>` that you replace with the absolute path to
your install root before copying the result into Codex's hooks file.

```bash
# Replace the placeholder and write into Codex's hooks file. Adjust
# the destination path if your Codex install reads hooks from a
# different location (see Codex's own documentation).
sed 's|<CERBERUS_INSTALL_ROOT>|/Users/me/code/cerberus|g' \
    ~/code/cerberus/templates/codex-hooks.json \
    > ~/.codex/hooks.json
```

After Step 2, your Codex hooks file contains a `SessionStart` entry
that runs `<install-root>/bin/codex-session-init` and a `Stop` entry
that runs `<install-root>/bin/codex-stop-hook`. Restart Codex (or
start a new session) so the new hooks take effect.

#### Alternative: shell-expanded `${CERBERUS_ROOT}`

If you prefer not to substitute the placeholder, set
`CERBERUS_ROOT=/Users/me/code/cerberus` in your shell profile and
replace `<CERBERUS_INSTALL_ROOT>` with the literal string
`${CERBERUS_ROOT}` (Codex's hook runner expands shell-style variables
the same way Claude's runner expands `${CLAUDE_PLUGIN_ROOT}`). The
Cerberus backend reads `CERBERUS_ROOT` first via
`__cerberus_resolve_root`, so this path is supported without further
changes. The placeholder approach is the documented default because
it is the most portable across environments where Codex's hook runner
may not expand shell-style variables identically.

### Verifying the install

After both steps, start a Codex session and run the `status` skill
(invocation form is host-dependent; e.g. `/skill status`). You should
see a JSON document on stdout with `status` set to `no_active_gate` or
similar, never an error like "command not found". If you don't, check:

- `<CERBERUS_INSTALL_ROOT>` was substituted with an absolute path that
  actually contains `bin/codex-session-init` and
  `bin/codex-stop-hook`.
- `bin/codex-session-init` and `bin/codex-stop-hook` are executable
  (`chmod +x`).
- `jq` is on the `PATH` Codex's hook runner uses (not just your
  interactive shell).
- `~/.cerberus/runtime/codex/<workspace-key>/active-session.json`
  exists after `SessionStart` fires.

## Repo-Trust and Security Model

Codex's lifecycle-hook execution model runs configured commands from
the user's hooks config every `SessionStart` and `Stop`. The Cerberus
adapters (`bin/codex-session-init`, `bin/codex-stop-hook`) are scripts
shipped from your install root and invoked by absolute path, so the
**install root is part of your trusted compute boundary** — anyone who
can write to that directory can change what runs at every Codex
lifecycle boundary on your machine.

Concrete consequences:

- **Pin your install root.** Don't install Cerberus into a directory
  that is writable by other users, scripts, or untrusted package
  managers. `/opt/cerberus` (root-owned, world-readable) and
  `~/code/cerberus` (your user only) are reasonable choices;
  `/tmp/cerberus` is not.
- **Audit the install root before substituting the placeholder.** The
  hook template uses `<CERBERUS_INSTALL_ROOT>` precisely because the
  resolved path becomes a literal `command:` field in Codex's hook
  runner. Treat that path with the same care you treat any other
  `command:` in your hooks file.
- **Do not point the hook template at a working tree you don't
  control.** If you fork Cerberus and pull from the fork, treat the
  fork as production code. Review changes before pulling. The
  upstream repository is signed and tagged for releases.
- **Sandbox / read-only constraints come from the reviewer CLIs.** The
  Cerberus backend itself does not gate writes; reviewer-side
  read-only enforcement (e.g. Gemini's Policy Engine via
  `config/gemini-readonly-policy.toml`) is what keeps reviewers from
  modifying your repo. If you change `--agents` or disable the policy
  file, that protection goes with it.

The Codex `Stop` adapter never writes to your repo; it only reads
review-gate state and emits a hook response. The `SessionStart`
adapter writes a single JSON file under
`~/.cerberus/runtime/codex/<workspace-key>/active-session.json`. No
files outside `~/.cerberus/` are touched by the lifecycle hooks
themselves.

## Commands (Skills)

All six Tier-1 workflows ship as Codex **skills** under
`skills/cerberus/`. Codex packaging is skills-only — there is no
separate slash-command declaration. The exact invocation verb
(`/skill`, `@`-mention, skill picker UI) is host-dependent; the
skill **name** is what you select.

Every skill exports `CERBERUS_HOST=codex` before handing off to the
shared backend, so `gate-state.json` is recorded with `host: "codex"`
and state is rooted under the Codex runtime tree. Each skill also
bootstraps `CERBERUS_RUN_KEY` from the on-disk session registry so the
skill works correctly when the user shell that triggered it didn't
inherit the env var from `SessionStart`.

| Skill | Backend invocation | Required args | Optional flags |
|---|---|---|---|
| `review-code` | `bin/review-gate spawn-code-review [flags] [focus]` | none | `--mode`, `--consensus`, `--agents`, `--max-rounds`, `--uncommitted`, `--base <branch>`, `--commit <sha...>`, `--exclude <pathspec>`, range (`a..b`), free-text focus |
| `review-plan` | `bin/review-gate spawn-plan-review <plan-path> [flags]` | `<plan-path>` | `--mode`, `--consensus`, `--agents`, `--max-rounds`, `--debate`, free-text focus |
| `review-spec` | `bin/review-gate spawn-spec-review <spec-path> [flags]` | `<spec-path>` | `--mode`, `--consensus`, `--agents`, `--max-rounds`, `--debate` |
| `ask` | `bin/review-gate spawn-ask <question>` then `wait --json --finalize` | none | `--debate`, `--mode`, `--agents`, `--max-rounds`, `--consensus`, `--context-file`, `--prompt-file`, `--` to escape leading dashes |
| `status` | `bin/review-gate status --json` | none | `--session-key <K>` to inspect a non-active run |
| `clear-gate` | `bin/review-gate resolve --reason "manual clear from Codex"` | none | (none — `bin/review-gate resolve` only accepts `--reason`; to target a non-active run, set `CERBERUS_RUN_KEY=<K>` in the environment before invoking) |

### `review-code`

Spawns the multi-model code-review panel and **stops the turn after
spawning**. The Codex `Stop` hook re-evaluates state on the next stop
boundary and either allows the stop (consensus reached) or surfaces a
continuation message describing reviewer findings. Review the diff
modes (`--uncommitted`, `--base`, `--commit`, range) in the main
[README](../README.md#code-review).

### `review-plan` and `review-spec`

Both require an **explicit path** to the plan or spec markdown file.
v1 of the Codex port does not consult a plan or spec registry; the
skill exits with a clear error if you forget the path. There is no
Claude-style "use the most recent plan" fallback. (See
[Limitations](#limitations-v1).)

### `ask`

Unlike the review skills, `ask` waits for the panel to finish and
emits an `ASK_RESULT=<path>` line you read back to synthesize the
panel answer in the current Codex thread. Use `--debate` for
multi-round peer-review behavior. Pass `--` before any prompt text
that begins with a dash so the skill doesn't try to parse it as a
flag.

### `status`

Read-only. Emits a single JSON document on stdout. The body has two
distinct shapes depending on what the resolver finds:

- **Active gate** (canonical body): top-level keys include
  `schema_version`, `host` (`codex` for runs created from Codex),
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
= backend failure (body still valid JSON). The skill **never**
mutates state — this is the contract verified by
`bin/tests/test-status-command.sh`.

### `clear-gate`

Operator escape hatch. Resolves the active gate so the session can
stop without completing the review cycle. The skill takes no
arguments. To target a non-active run, set `CERBERUS_RUN_KEY=<K>` in
the environment before invoking — `bin/review-gate resolve` only
accepts `--reason` on its CLI; the run identity is read via
`__cerberus_resolve_run_key` (which honors `CERBERUS_RUN_KEY`,
`REVIEW_GATE_SESSION_KEY`, and `CLAUDE_SESSION_ID` in that
precedence). The resolution reason is recorded as `manual clear from
Codex` so audit trails make the source of the
clear unambiguous.

## Stop-Hook Wait Knob (`CERBERUS_CODEX_STOP_WAIT_SECONDS`)

Codex `Stop` is a synchronous lifecycle boundary: the hook either
allows the stop or asks Codex to continue with a user message. The
default Cerberus behavior is to **never block the user from stopping**
when reviewers are still running — instead, the hook emits an
`{"action":"allow", "note":"reviewers still running; run Cerberus:
Status to check"}` and returns immediately.

If you want a bounded wait (so reviewers that are about to finish
have a chance to land a verdict before the user stops), set
`CERBERUS_CODEX_STOP_WAIT_SECONDS=N` (positive integer, seconds).
With `N>0` and a `pending` gate, the hook spawns
`bin/review-gate wait --json --timeout N --session-key <run>` as a
backgrounded child, waits up to `N` seconds, then re-evaluates state
via the Stop Decision Matrix:

| `WAIT_SECONDS` | `pending` gate behavior |
|---|---|
| `0` (default) | Emit allow immediately; user stops without waiting. |
| `N > 0` | Wait up to `N` seconds for `wait --json --timeout N`; re-run the matrix on completion. On wait timeout, emit the same "still running" allow as `0`. |

The wait knob applies **only** to `gate_status == "pending"`. Other
states (`awaiting_decision`, `resolved`) are evaluated immediately and
do not respect the wait knob — there's nothing to wait for.

Set the variable in your shell profile or your Codex hooks config's
environment block. Empty / non-numeric values are treated as `0`.

## Failure-Open Behavior

The Codex `Stop` adapter follows a strict failure-open principle:
**users must never be unable to stop Codex due to a Cerberus failure.**
Concretely:

- The hook **always exits 0** and emits exactly one JSON envelope to
  stdout (`{"action":"allow"}` or
  `{"action":"continue","userMessage":...}`). It never aborts mid-write
  or returns a non-zero exit.
- If `bin/review-gate status --json` exits non-zero (other than `4`
  for "no active gate"), the hook logs the error to stderr and emits
  allow.
- If `gate-state.json` is malformed, the hook emits allow with the
  note `"cerberus state unreadable; allowing stop"`.
- If `jq` is missing or the backend isn't invokable, the hook emits
  allow.
- A `SIGINT`, `SIGTERM`, or `SIGHUP` mid-execution triggers the
  signal trap (`__cerberus_stop_safe_exit`), which kills any tracked
  child PIDs (`wait` / `status`), emits a single `{"action":"allow"}`
  envelope, and exits 0. No long-running operations run inside the
  trap.

The only state in which the hook returns `{"action":"continue", ...}`
is when reviewers have **successfully completed** a round and the
result is either `awaiting_decision` with blocking findings (verdict
`FAIL` or priority `P0`/`P1`) or `resolved` with
`consensus_verdict == "fail"`. In every other path the user keeps the
ability to stop.

The `SessionStart` adapter (`bin/codex-session-init`) is **not**
failure-open — it exits non-zero on malformed stdin or invalid
project key / run key. SessionStart failure cannot trap the user the
way a Stop failure could; the worst-case is that subsequent skills
fall back to env-var defaults instead of the registry. The atomic
write algorithm (write to `<file>.tmp.$$`, validate, `mv`) ensures
that a kill mid-write leaves the previous valid registry intact.

## Troubleshooting

### `<CERBERUS_INSTALL_ROOT>` placeholder not substituted

**Symptom:** SessionStart or Stop fails with `command not found:
<CERBERUS_INSTALL_ROOT>/bin/...`.

**Fix:** Re-run the `sed` substitution in [Step 2](#step-2--lifecycle-hooks-sessionstart--stop)
with an absolute path, or set `CERBERUS_ROOT` and switch the template
to `${CERBERUS_ROOT}`. Confirm the resulting `~/.codex/hooks.json`
contains an absolute path (or the literal `${CERBERUS_ROOT}`) in every
`command:` field.

### `CERBERUS_ROOT` and `CLAUDE_PLUGIN_ROOT` both set, pointing at different installs

**Symptom:** A stderr warning of the literal form
`warning: CERBERUS_ROOT != CLAUDE_PLUGIN_ROOT; using CERBERUS_ROOT`
appears once per process (emitted by
`bin/review-gate:88`).

**Fix:** This is intentional — `CERBERUS_ROOT` always wins. The
warning is informational. Either unset `CLAUDE_PLUGIN_ROOT` if you
have fully migrated to the neutral env, or set both to the same path.
The legacy alias is preserved indefinitely so existing Claude users
do not need to migrate.

### Reviewer CLI missing or `jq` not installed

**Symptom:** Reviewer panel reports `0 reviewers available` or
`spawn` fails with `jq: command not found`.

**Fix:** Install the missing CLI (see [Prerequisites](#prerequisites)).
The Cerberus backend skips missing reviewers with a warning, but it
hard-requires `jq`, `bash`, and `python3`. You can run with one or
two reviewers if the third CLI isn't available, but `--debate` mode
hard-errors with fewer than two reviewers.

### Stale `active-session.json` registry

**Symptom:** Skills target an old run key after Codex restarts mid-
session, or `Cerberus: Status` returns `no_active_gate` when you know
a review is in flight.

**Fix:** Trigger `SessionStart` again (typically by starting a fresh
Codex session). `bin/codex-session-init` is **last-writer-wins** by
design (plan §Atomic Write Invariants); the new registry overwrites
the old. If you need to inspect or clear the registry directly:

```bash
ls -l ~/.cerberus/runtime/codex/
cat ~/.cerberus/runtime/codex/<workspace-key>/active-session.json
# To force a fresh registry:
rm ~/.cerberus/runtime/codex/<workspace-key>/active-session.json
```

If you want to target a specific (non-active) run, the two
subcommands take it in different ways. `bin/review-gate status` accepts
the flag directly: `status --json --session-key <run-key>`.
`bin/review-gate resolve` does **not** parse `--session-key` — it only
accepts `--reason` — so to clear a non-active run, set
`CERBERUS_RUN_KEY=<run-key>` in the environment before invoking
`resolve`. Example:

```bash
CERBERUS_RUN_KEY=<run-key> \
    "$CERBERUS_ROOT/bin/review-gate" resolve \
        --reason "manual clear from Codex"
```

### `Cerberus: Status` works but `Cerberus: Clear Gate` doesn't resolve the run I expected

**Symptom:** `clear-gate` resolves a different run than the one
you're inspecting.

**Fix:** `clear-gate` resolves the run identified by the active
session registry, which is read via `__cerberus_resolve_run_key`. If
the registry was written for a different session, override the run
identity by exporting `CERBERUS_RUN_KEY=<K>` in the shell that invokes
the skill (or in the equivalent host-side env block). `resolve` does
not accept `--session-key` on its CLI:

```bash
CERBERUS_RUN_KEY=<K> \
    "$CERBERUS_ROOT/bin/review-gate" resolve \
        --reason "manual clear from Codex"
```

### Stop hook timing out

**Symptom:** Codex reports the Stop hook took longer than its
timeout budget (default `2100` seconds in
`templates/codex-hooks.json`, set high to accommodate
`CERBERUS_CODEX_STOP_WAIT_SECONDS=N` use cases).

**Fix:** The Stop hook is failure-open and should not block longer
than `CERBERUS_CODEX_STOP_WAIT_SECONDS` (default `0`). If you observe
a hang, send SIGTERM to the hook process — the trap will emit a
single allow envelope and exit 0. File a bug report including the
stderr log lines (search for `codex-stop-hook:`).

## Manual Smoke Test (Phase 1 Release Gate)

The agent-completable verification is covered by the Phase 0/1
automated test suite (`bin/tests/test-host-neutral-state.sh`,
`bin/tests/test-status-command.sh`,
`bin/tests/test-codex-session-registry.sh`,
`bin/tests/test-codex-stop-hook.sh`, plus the existing Claude
regression suite). Before tagging the Cerberus vX+1 release the
maintainer also runs the following manual smoke on a clean Codex
install. None of these are automated; they're a release gate, not a
CI gate.

1. **Install.** Clone the repo and substitute the placeholder per
   [Install](#install). Confirm the resulting hooks file points at
   absolute paths inside the install root.
2. **`SessionStart` registry.** Trigger Codex `SessionStart` (start a
   new Codex session). Confirm
   `~/.cerberus/runtime/codex/<workspace-key>/active-session.json`
   exists and contains `host: "codex"`, `session_id`, `run_key`, and
   a recent `last_seen`.
3. **Spawn reviewers.** Invoke the `review-code` skill on a small
   diff. Confirm that:
   - The skill returns promptly (it stops the turn after spawning).
   - `gate-state.json` appears under
     `~/.cerberus/projects/<workspace-key>/<run-key>/`.
   - `gate-state.json.host == "codex"`.
4. **`Stop` matrix — wait disabled.** With reviewers still running
   (`gate_status == "pending"`) and `CERBERUS_CODEX_STOP_WAIT_SECONDS`
   unset (or `0`), trigger Codex `Stop`. Confirm the hook emits
   `{"action":"allow","note":"reviewers still running; run Cerberus:
   Status to check"}` and Codex stops immediately.
5. **`Stop` matrix — wait enabled.** Set
   `CERBERUS_CODEX_STOP_WAIT_SECONDS=10`, repeat the previous step.
   Confirm the hook waits up to ~10 seconds and either:
   - Emits an updated allow (if reviewers landed mid-wait), or
   - Re-emits the "still running" allow with the same wait timeout
     fallback message.
6. **`Cerberus: Status` after completion.** When the panel finishes,
   invoke `status`. The body is the canonical active-gate shape:
   confirm `gate_status` is one of `pending`, `awaiting_decision`, or
   `resolved`; that `consensus_verdict` is one of `pass`, `fail`,
   `needs_revision`, or JSON `null`; and that `aggregated_findings`
   is the expected array. (The smaller special-body shape keyed off
   `status` only appears for `no_active_gate` / `malformed_state`.)
7. **`Cerberus: Clear Gate`.** Invoke `clear-gate`. Confirm
   `gate-state.json.status` flips to `resolved` with reason
   `manual clear from Codex`.
8. **Host-recorded metadata.** For every Codex-originated run created
   above, confirm `gate-state.json.host == "codex"`. Re-run a Claude
   review in the same workspace and confirm the Claude run is
   recorded with `host: "claude"` (cross-host filtering smoke).

If any of the eight steps fails, do **not** tag the release. The Phase
1 exit criteria require all eight to pass on a clean Codex install,
plus the full Phase 0 + Phase 1 automated test suite green.

### Phase 1 Exit Criteria Recap

These are the testable exit criteria from the plan
(`docs/2026-04-29-codex-amp-plugin-port-plan.md` L926-L935):

| Criterion | Verified by |
|---|---|
| Codex `SessionStart` creates or refreshes the session registry atomically | `bin/tests/test-codex-session-registry.sh` (T008) |
| Codex review skills spawn reviewers and reattach across `SessionStart` / `Stop` transitions | T010 skills + manual smoke step 3-6 |
| Codex `Stop` matrix behaves per spec for every row 1–13 | `bin/tests/test-codex-stop-hook.sh` (T009) + manual smoke step 4-5 |
| `Clear Gate` resolves the intended run | T010 skills + manual smoke step 7 |
| Claude plugin behavior remains unchanged (full Claude suite passes) | Existing `bin/tests/*.sh` (regression) |
| `gate-state.json` records `host: "codex"` for Codex-originated runs | T004 host-metadata writer + manual smoke step 8 |

Once all six rows are green (automated + manual), the Cerberus vX+1
release tag may be cut.

## Phase 1 Spike Findings

These findings are the resolutions of **OQ-1** (Codex skill manifest
fields) and **OQ-2** (stable Codex plugin-install path env var) from
`docs/2026-04-29-codex-amp-plugin-port-plan.md`, recorded **2026-04-30**.
They are preserved here for auditability of the design decisions that
shaped Phase 1; future contributors can revisit them when an
authoritative Codex schema or env-var lands.

> **Source disclosure.** No public, versioned schema for
> `.codex-plugin/plugin.json` is published in the OpenAI Codex CLI
> documentation that the spike author had access to as of 2026-04-30.
> The findings below are therefore **best-effort**, derived from the
> following inputs, in order of confidence:
>
> 1. The plan's host assumptions (plan §Host Assumptions L143-L171)
>    which already pre-commit to `"skills only"` packaging via
>    `.codex-plugin/plugin.json` and a separate user-installed
>    `templates/codex-hooks.json` lifecycle template.
> 2. The shape of the existing `.claude-plugin/plugin.json` (the
>    sibling host's manifest) as a credible cross-host reference.
> 3. Conventional plugin-manifest fields shared by other CLI plugin
>    ecosystems (npm, VS Code extensions, Claude Code) which converge
>    on the same minimum metadata set.
>
> Per task **T006** acceptance criteria and plan §Prerequisites
> (L215-L218): "Block Phase 1 implementation until resolved (or
> documented as best-effort)." This spike documents a best-effort
> answer; **`T007` MUST flag the manifest as best-effort** in an inline
> comment and use `version: "1.0.0"`. If a future Codex CLI release
> publishes an authoritative schema that contradicts the assumptions
> below, T007's manifest is updated and `docs/CODEX.md` is amended in
> the same patch.

### OQ-1 — `.codex-plugin/plugin.json` schema (best-effort)

**Resolution:** Use the schema below for T007. It mirrors the
`.claude-plugin/plugin.json` shape and adds an explicit `skills`
declaration array since Codex packaging is **skills-only** per plan
§Host Assumptions.

#### Required top-level fields

| Field | Type | Notes |
|---|---|---|
| `name` | string | Plugin identifier; must equal `"cerberus"` to match the directory layout (`skills/cerberus/*.md`). |
| `version` | string | SemVer. T007 ships `"1.0.0"` to signal "first Codex packaging" independent of the Claude plugin version. |
| `description` | string | One-line description; mirrors `.claude-plugin/plugin.json`. |
| `skills` | array | List of skill descriptors. See **Skill descriptor shape** below. Six entries: `review-code`, `review-plan`, `review-spec`, `ask`, `status`, `clear-gate`. |

#### Optional top-level fields (recommended for parity with the Claude manifest)

| Field | Type | Notes |
|---|---|---|
| `author` | object | `{ "name": "<author>" }`. Same as Claude manifest. |
| `repository` | string | URL. Same as Claude manifest. |
| `license` | string | SPDX id (e.g. `"MIT"`). |
| `keywords` | array of strings | Discoverability tags (e.g. `["code-review", "multi-model", "quality-gate"]`). |
| `homepage` | string | Documentation landing page URL. |

#### Skill descriptor shape

Each entry in `skills[]` is an object:

| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | string | required | The user-facing skill name; matches the markdown filename without `.md` (e.g. `"review-code"` → `skills/cerberus/review-code.md`). |
| `path` | string | required | Plugin-relative path to the skill markdown (e.g. `"skills/cerberus/review-code.md"`). |
| `description` | string | required | One-line summary for skill listings / autocomplete. |
| `arguments` | array of objects | optional | Used for skills that accept positional arguments (`review-plan`, `review-spec`, `ask`). Each entry: `{ "name": "<arg>", "required": <bool>, "description": "<text>" }`. T007 may omit this if Codex's actual schema rejects unknown fields; T010 re-evaluates when authoring final skill markdown. |

#### Slash-command vs skill semantics for the six Tier-1 workflows

Codex packaging is **skills-only**: there is no separate slash-command
declaration in `.codex-plugin/plugin.json`. All six Tier-1 workflows
ship as Codex skills under `skills/cerberus/`. The user invokes them
through Codex's skill-invocation UX (the exact verb — `/skill`, `@`-mention,
or skill picker — is host-dependent and not part of the manifest
contract).

| Workflow | Skill file | Backend invocation | Argument shape |
|---|---|---|---|
| Code review | `skills/cerberus/review-code.md` | `bin/review-gate spawn-code-review [flags]` | Optional flags: `--mode`, `--focus`, `--base`, `--exclude`. Mirrors `commands/review-code.md`. |
| Plan review | `skills/cerberus/review-plan.md` | `bin/review-gate spawn-plan-review <plan-path> [flags]` | **Path required (v1).** Non-Claude hosts have no plan registry per plan §Out Of Scope. |
| Spec review | `skills/cerberus/review-spec.md` | `bin/review-gate spawn-spec-review <spec-path> [flags]` | **Path required (v1).** Same rationale as Plan review. |
| Ask panel | `skills/cerberus/ask.md` | `bin/review-gate spawn-ask <question>` then `wait --json --finalize` | Free-text question; skill synthesizes the panel answer from the wait output. |
| Status | `skills/cerberus/status.md` | `bin/review-gate status --json` | None. Read-only; never mutates state (see plan §Phase 0 exit criteria). |
| Clear gate | `skills/cerberus/clear-gate.md` | `bin/review-gate resolve --reason "manual clear from Codex"` | None. Operator escape hatch. |

#### Sample manifest (verbatim seed for T007)

```json
{
  "name": "cerberus",
  "version": "1.0.0",
  "description": "Three-headed guardian of code quality. Multi-model consensus review with Codex, Gemini, and Claude.",
  "author": {
    "name": "charlieyou"
  },
  "repository": "https://github.com/charlieyou/cerberus",
  "license": "MIT",
  "keywords": ["code-review", "plan-review", "multi-model", "quality-gate", "cerberus"],
  "skills": [
    {
      "name": "review-code",
      "path": "skills/cerberus/review-code.md",
      "description": "Spawn a multi-model code review (Codex + Gemini + Claude consensus)."
    },
    {
      "name": "review-plan",
      "path": "skills/cerberus/review-plan.md",
      "description": "Spawn a multi-model plan review. Requires an explicit plan path."
    },
    {
      "name": "review-spec",
      "path": "skills/cerberus/review-spec.md",
      "description": "Spawn a multi-model spec review. Requires an explicit spec path."
    },
    {
      "name": "ask",
      "path": "skills/cerberus/ask.md",
      "description": "Ask the Cerberus panel an open-ended question."
    },
    {
      "name": "status",
      "path": "skills/cerberus/status.md",
      "description": "Show current review-gate status (read-only)."
    },
    {
      "name": "clear-gate",
      "path": "skills/cerberus/clear-gate.md",
      "description": "Manually clear the active review gate."
    }
  ]
}
```

> **T007 implementer note.** Add an inline comment at the top of
> `.codex-plugin/plugin.json` (in a leading line of the file's commit
> message and as a sibling `README` if Codex's parser is strict-JSON
> and rejects comments) noting: *"Schema is best-effort per
> docs/CODEX.md §Phase 1 Spike Findings; revisit when Codex publishes
> an authoritative manifest schema."*

### OQ-2 — Stable plugin-install path env var

**Resolution:** **No** stable, documented Codex-provided env var
equivalent to Claude's `CLAUDE_PLUGIN_ROOT` is known as of 2026-04-30.

**Fallback approach (adopted, shipping in v1):** `templates/codex-hooks.json`
ships with a documented placeholder string that the user manually edits
during install. The placeholder is:

```text
<CERBERUS_INSTALL_ROOT>
```

It appears in every `command:` field in the hook template that needs
to invoke a Cerberus binary. The user replaces it with the absolute
path to their Cerberus install root (the directory containing
`bin/`, `skills/`, `.codex-plugin/`, etc.) when installing the hook
template into Codex's hooks config.

**Rationale.**

- Plan §Risks (L1033) already calls this case out: *"Codex install root
  path env var unstable across versions | Hook template uses
  placeholder substitution; `docs/CODEX.md` documents manual edit."*
  This spike confirms the assumed risk is real and selects the
  fallback the plan pre-described.
- The shared backend already accepts `CERBERUS_ROOT` as an explicit
  override (plan §API/Interface Design L549). Users who prefer to set
  `CERBERUS_ROOT` in their shell profile rather than substitute the
  placeholder may do so; the hook template documents both paths.
- If a future Codex release ships a stable env var (e.g.
  `CODEX_PLUGIN_ROOT`), `templates/codex-hooks.json` is updated to
  default to `${CODEX_PLUGIN_ROOT}` with the manual-edit step
  documented as a fallback. The shared backend already routes through
  `__cerberus_resolve_root` which picks `CERBERUS_ROOT` first, so
  callers who set `CERBERUS_ROOT` in env continue to work either way.

**Install-time UX (shipping form).**

The two-step Codex install is:

1. Clone or otherwise place the Cerberus repository at a known
   absolute path (the **install root**).
2. Open `templates/codex-hooks.json`, replace every
   `<CERBERUS_INSTALL_ROOT>` token with the absolute install-root path
   (or `${CERBERUS_ROOT}` if you prefer shell expansion), and copy the
   resulting JSON into Codex's hooks configuration (typically
   `~/.codex/hooks.json` or the platform equivalent).

The Cerberus backend itself is unaffected by the placeholder choice;
it continues to read `CERBERUS_ROOT` (with `CLAUDE_PLUGIN_ROOT`
fallback) via `__cerberus_resolve_root`. The placeholder lives **only**
in the hook template, not in any backend code path.

### Implications for downstream tasks (historical)

- **T007** (landed) authored `.codex-plugin/plugin.json` per the OQ-1
  sample above. The manifest's `description` field includes a
  best-effort marker pointing back at this section, and the version is
  `"1.0.0"`.
- **T010** (landed) authored `templates/codex-hooks.json` using the
  `<CERBERUS_INSTALL_ROOT>` placeholder per OQ-2 and ships the six
  Codex skills under `skills/cerberus/`.
- **T011** (this task) finalizes the user-facing sections of this
  document and links them from the host catalog in `README.md`.
