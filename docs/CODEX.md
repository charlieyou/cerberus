# Cerberus on Codex CLI

> **Status:** Phase 1 release-ready. This document is the user-facing
> install / configure / use guide for running Cerberus under OpenAI's
> Codex CLI. The shared backend (`bin/review-gate`, `bin/generate`,
> debate, telemetry) is identical to the Claude experience; only the
> lifecycle adapters and packaging differ.
>
> **Feature scope.** Codex discovers the same generic Cerberus skills
> used by Claude from `skills/<skill>/SKILL.md`. The
> Tier-1 review skills (`review-code`, `review-plan`, `review-spec`,
> `ask`, `status`, `clear-gate`) are the supported Codex lifecycle
> workflows and use the **`SessionStart` + `UserPromptSubmit` + `Stop`** hooks.

## Install

The Cerberus Codex integration uses the repository checkout as the
single package root. That checkout contains `.codex-plugin/plugin.json`,
`skills/`, `hooks/`, `bin/`, and the shared review backend. Set
`CERBERUS_ROOT` to this directory so skill shell snippets can locate
the shared backend.

Codex plugin installation discovers the skills and, on current Codex
versions, loads the bundled `SessionStart` / `UserPromptSubmit` /
`Stop` lifecycle hooks declared by the plugin manifest.

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

### Step 1 — Checkout + Plugin Package

Clone the Cerberus repository (or your fork) somewhere stable on the
machine that runs Codex. The directory you clone into is the
**backend checkout root**.

```bash
git clone https://github.com/charlieyou/cerberus.git ~/code/cerberus
```

Current Codex CLI (verified with 0.128) expects `.codex-plugin/plugin.json`
to declare `skills` as a directory path. Cerberus points that field at
`skills/`; each skill lives in a child directory named after
the skill and has a `SKILL.md` file.

The local marketplace descriptor at `.agents/plugins/marketplace.json`
registers the Git repository root as `cerberus-local`; add that
marketplace file to Codex, then install and enable
`cerberus@cerberus-local` using your Codex plugin UI or CLI. After
installation, Codex should list the Cerberus skills from `skills/`.

### Step 2 — Runtime Root + Bundled Hooks

The Cerberus shared backend resolves run state from environment
variables and an on-disk session registry. Codex doesn't expose a
stable session-id env var to skill shell commands, so the
`SessionStart` and `UserPromptSubmit` hooks run
`bin/cerberus hook codex-session-start` and
`bin/cerberus hook codex-prompt-submit` with Codex's hook JSON on
stdin. That registry is the only source skills use for the active run
key; skills do not invent fallback run keys because `Stop` would be
unable to associate them with Codex's `session_id`.

Set `CERBERUS_ROOT` in Codex's shell environment to the **repository
checkout root**. Installed skills are cached
by Codex and are not rewritten during install, so they locate the shared
backend through `CERBERUS_ROOT` at runtime.

Enable Codex hooks and plugin-bundled hooks in `~/.codex/config.toml` if
your Codex install has not enabled them already:

```toml
[features]
codex_hooks = true
plugin_hooks = true
```

The plugin manifest points `hooks` at `./hooks/codex-hooks.json`. Codex
loads that lifecycle config from the installed plugin and substitutes
`${PLUGIN_ROOT}` in hook commands with the installed plugin root, so the
hooks can build and call the bundled `bin/cerberus hook
codex-session-start`, `bin/cerberus hook codex-prompt-submit`, and
`bin/cerberus hook codex-stop` without a separate `~/.codex/hooks.json`
installation step. The current contract was validated with
`codex-cli 0.130.0`: hook event JSON is delivered on stdin, Cerberus
accepts `session_id`, `transcript_path`, `project_key`, `transcript`,
`cwd`, `workspace_root`, `prompt`, and `stop_reason`, and unknown
payload fields are ignored.

After changing plugin files or updating Cerberus, push the change and
run `codex plugin marketplace upgrade cerberus-local`, then reinstall
or refresh the plugin from the plugin directory and restart Codex (or
start a new session) so the new manifest, skills, and hooks take
effect.

#### Legacy Manual Hook Template

Older Codex versions may not load plugin-bundled lifecycle hooks. For
those versions, the repository still ships the fallback template at
`templates/codex-hooks.json`; substitute `<CERBERUS_INSTALL_ROOT>` with
the absolute checkout root and copy it to `~/.codex/hooks.json`. Do not
keep both plugin-bundled hooks and the manual template active at the
same time, or Codex will run duplicate Cerberus hooks.

### Verifying the install

After install, start a Codex session and run the `status` skill
(invocation form is host-dependent; e.g. `cerberus:status` from the
skill picker). You should see a JSON document on stdout with `status`
set to `no_active_gate` or similar, never an error like "command not
found". If you don't, check:

- The installed plugin manifest includes `"hooks": "./hooks/codex-hooks.json"`
  and the installed plugin cache contains `hooks/codex-hooks.json`.
- `CERBERUS_ROOT` is set in Codex's shell environment and points at the
  backend checkout root, not at `` or Codex's plugin
  cache.
- `bin/cerberus` exists or Codex's hook runner can find `make` and
  Go on `PATH` to lazy-build it from the checkout.
- `~/.cerberus/runtime/codex/<workspace-key>/active-session.json`
  exists after `SessionStart` or `UserPromptSubmit` fires.

## Repo-Trust and Security Model

Codex's lifecycle-hook execution model runs configured commands from
enabled plugins and hook config layers every `SessionStart`,
`UserPromptSubmit`, and `Stop`. The Cerberus hook manifest resolves the
installed plugin root and invokes the Go binary from that root, so the
**plugin source and installed plugin cache are part of your trusted
compute boundary** — anyone who can write to those directories can
change what runs at every Codex lifecycle boundary on your machine.

Concrete consequences:

- **Pin your backend checkout root.** Don't install Cerberus into a
  directory that is writable by other users, scripts, or untrusted
  package managers. `/opt/cerberus` (root-owned, world-readable) and
  `~/code/cerberus` (your user only) are reasonable choices;
  `/tmp/cerberus` is not.
- **Audit the plugin source before installing or refreshing it.** The
  bundled hook config resolves `${PLUGIN_ROOT}` to the installed plugin
  root, so `bin/cerberus hook ...` from that plugin copy runs at
  lifecycle boundaries. If you fork Cerberus and pull from the fork,
  treat the fork as production code. Review changes before pulling.
- **Sandbox / read-only constraints come from the reviewer CLIs.** The
  Cerberus backend itself does not gate writes; reviewer-side
  read-only enforcement (e.g. Gemini's Policy Engine via
  `config/gemini-readonly-policy.toml`) is what keeps reviewers from
  modifying your repo. If you change `--agents` or disable the policy
  file, that protection goes with it.

The Codex `Stop` adapter never writes to your repo; it only reads
review-gate state and emits a hook response. The `SessionStart` /
`UserPromptSubmit` adapter writes a single JSON file under
`~/.cerberus/runtime/codex/<workspace-key>/active-session.json`. No
files outside `~/.cerberus/` are touched by the lifecycle hooks
themselves.

## Commands (Skills)

Cerberus workflows ship as **skills** under
`skills/<skill>/SKILL.md`. Codex packaging is skills-only —
there is no separate slash-command declaration. The exact
invocation verb (`/skill`, `@`-mention, skill picker UI) is
host-dependent; installed marketplace skills are typically selected as
`cerberus:<skill>`.

Each skill starts from the same prompt text that previously lived under
`commands/`, with a small host-neutral preamble that sources
`bin/cerberus-skill-env`. That helper resolves `CERBERUS_ROOT`, detects
the current host when possible, and bootstraps `CERBERUS_RUN_KEY` from
the on-disk Codex session registry written by Codex hooks. If the
registry is missing or stale but the skill is running in a Codex shell
command with `CODEX_THREAD_ID`, the helper refreshes the registry with
that host-provided session id so the Stop hook can verify the same
identity. If neither registry state nor a Codex thread id is available,
the helper fails clearly rather than generating a run key the Stop hook
cannot verify.

| Skill | Backend invocation | Required args | Optional flags |
|---|---|---|---|
| `review-code` | `bin/review-gate spawn-code-review [flags] [focus]` | none | `--mode`, `--consensus`, `--agents`, `--max-rounds`, `--uncommitted`, `--base <branch>`, `--commit <sha...>`, `--exclude <pathspec>`, range (`a..b`), free-text focus |
| `review-plan` | `bin/review-gate spawn-plan-review [plan-path] [flags]` | none on Claude; explicit path recommended elsewhere | `--mode`, `--consensus`, `--agents`, `--max-rounds`, `--debate`, free-text focus |
| `review-spec` | `bin/review-gate spawn-spec-review <spec-path> [flags]` | `<spec-path>` | `--mode`, `--consensus`, `--agents`, `--max-rounds`, `--debate` |
| `ask` | `bin/review-gate spawn-ask <question>` then `wait --json --finalize` | none | `--debate`, `--mode`, `--agents`, `--max-rounds`, `--consensus`, `--context-file`, `--prompt-file`, `--` to escape leading dashes |
| `status` | `bin/review-gate status --json` | none | `--session-key <K>` to inspect a non-active run |
| `clear-gate` | `bin/review-gate resolve --reason "manual clear"` | none | (none — `bin/review-gate resolve` only accepts `--reason`; to target a non-active run, set `CERBERUS_RUN_KEY=<K>` in the environment before invoking) |

### `review-code`

Spawns the multi-model code-review panel and **stops the turn after
spawning**. The Codex `Stop` hook re-evaluates state on the next stop
boundary and either allows the stop (consensus reached) or surfaces a
continuation message describing reviewer findings. Review the diff
modes (`--uncommitted`, `--base`, `--commit`, range) in the main
[README](../README.md#code-review).

### `review-plan` and `review-spec`

Pass an explicit path to the plan or spec markdown file when using
Codex. The underlying backend can fall back to Claude's recent-plan
registry when running under Claude, but non-Claude hosts should not rely
on that registry being present.

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

## Stop-Hook Wait Behavior

Codex `Stop` is a synchronous lifecycle boundary: the hook either
allows the stop or asks Codex to continue with a user message. The
Cerberus behavior is to wait for pending reviewers before deciding,
matching the Claude Stop hook. When a gate is `pending`, the hook
spawns `bin/review-gate wait --json --timeout N --session-key <run>` as
a backgrounded child, waits up to the shared review wait budget
(`REVIEW_GATE_MAX_WAIT_SECONDS`, default `1800`), then re-evaluates
state via the Stop Decision Matrix.

Other states (`awaiting_decision`, `resolved`) are evaluated
immediately because there is nothing still running to wait for. If the
wait budget is exhausted while reviewers are still pending, the hook
emits `{"continue":true,"systemMessage":"reviewers still running; run
Cerberus: Status to check"}` so the user can stop and inspect status
later.

## Failure-Open Behavior

The Codex `Stop` adapter follows a strict failure-open principle:
**users must never be unable to stop Codex due to a Cerberus failure.**
Concretely:

- The hook **always exits 0** and emits exactly one JSON envelope to
  stdout (`{"continue":true}` or
  `{"decision":"block","reason":...}`). It never aborts mid-write or
  returns a non-zero exit.
- If `bin/review-gate status --json` exits non-zero (other than `4`
  for "no active gate"), the hook logs the error to stderr and emits
  allow.
- If `gate-state.json` is malformed, the hook emits allow with the
  `systemMessage` `"cerberus state unreadable; allowing stop"`.
- If `jq` is missing or the backend isn't invokable, the hook emits
  allow.
- A `SIGINT`, `SIGTERM`, or `SIGHUP` mid-execution triggers the
  signal trap (`__cerberus_stop_safe_exit`), which kills any tracked
  child PIDs (`wait` / `status`), emits a single `{"continue":true}`
  envelope, and exits 0. No long-running operations run inside the
  trap.

The hook returns `{"decision":"block", ...}` only when reviewers have
**successfully completed** a round and the canonical status payload still
contains blocking findings (verdict `FAIL` or priority `P0`/`P1`), or when
the resolved gate has an explicit `consensus_verdict == "fail"`. In every
other path the user keeps the ability to stop.

The `SessionStart` / `UserPromptSubmit` hook path (`bin/cerberus hook
codex-session-start` and `bin/cerberus hook codex-prompt-submit`) is
**not** failure-open — it exits non-zero on malformed stdin or invalid
project key / run key. Hook writer failure cannot trap the user the way
a Stop failure could; the worst-case is that subsequent skills fail
with a clear registry setup diagnostic. The atomic write algorithm
ensures that a kill mid-write leaves the previous valid registry
intact.

## Troubleshooting

### Legacy Manual Template Placeholder Not Substituted

**Symptom:** SessionStart or Stop fails with `command not found:
<CERBERUS_INSTALL_ROOT>/bin/...`.

**Fix:** This only applies to the legacy manual hook template. Re-run
the `sed` substitution with the absolute backend checkout root, or set
`CERBERUS_ROOT` and switch the template to `${CERBERUS_ROOT}`. Confirm
the resulting `~/.codex/hooks.json` contains an absolute path (or the
literal `${CERBERUS_ROOT}`) in every `command:` field. If you are using
plugin-bundled hooks, ensure `plugin_hooks = true` and restart Codex
instead.

### Skill cannot find `bin/review-gate`

**Symptom:** A Codex skill exits with a message like `cannot find
Cerberus backend; set CERBERUS_ROOT to the Cerberus checkout root`.

**Fix:** Set `CERBERUS_ROOT` in Codex's shell environment to the
backend checkout root — the directory containing `bin/review-gate` —
not to `` and not to Codex's plugin cache. Installed
skills are cached markdown files, so they are not patched with a local
checkout path during plugin install.

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

**Fix:** Trigger `UserPromptSubmit` or `SessionStart` again (typically
by submitting another prompt or starting a fresh Codex session).
When a Codex skill runs through a shell command, Codex also exposes
`CODEX_THREAD_ID`; the skill bootstrap and Go backend use Codex hook
state to refresh a missing or stale registry before spawning a review.
`bin/cerberus hook codex-session-start` and `bin/cerberus hook
codex-prompt-submit` are **last-writer-wins** by design (plan §Atomic
Write Invariants); the new registry overwrites the old. The Stop hook
also verifies that `active-session.json.session_id` matches the Stop
payload's `session_id` and ignores stale registries from other sessions.
If you need to inspect or clear the registry directly:

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
        --reason "manual clear"
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
        --reason "manual clear"
```

### Stop hook timing out

**Symptom:** Codex reports the Stop hook took longer than its
timeout budget (default `2100` seconds in
`templates/codex-hooks.json`, set high to accommodate the shared
reviewer wait budget).

**Fix:** The Stop hook is failure-open and should not block longer
than `REVIEW_GATE_MAX_WAIT_SECONDS` (default `1800`). If you observe a
hang, send SIGTERM to the hook process — the trap will emit a single
allow envelope and exit 0. File a bug report including stderr from
`cerberus hook codex-stop`.

## Manual Smoke Test (Phase 1 Release Gate)

The agent-completable verification is covered by the Phase 0/1
automated test suite (`internal/hook/codex_test.go`,
`tests/integration/codex_hook_skeleton_test.go`,
`tests/integration/codex_session_init_test.go`, and
`tests/integration/codex_stop_test.go`, plus the existing Claude
regression suite). Before tagging the Cerberus vX+1 release the
maintainer also runs the following manual smoke on a clean Codex
install. None of these are automated; they're a release gate, not a
CI gate.

1. **Install.** Clone the repo, configure the package from
   the repository root per [Install](#install), set `CERBERUS_ROOT` to
   the backend checkout root, and confirm the installed plugin manifest
   points at `hooks/codex-hooks.json`. Confirm `codex_hooks` and
   `plugin_hooks` are enabled before starting a new Codex session.
2. **Codex session registry.** Trigger Codex `SessionStart` (start a
   new Codex session), then submit a prompt to exercise
   `UserPromptSubmit`. Confirm
   `~/.cerberus/runtime/codex/<workspace-key>/active-session.json`
   exists and contains `host: "codex"`, `session_id`, `run_key`, and
   a recent `last_seen`.
3. **Spawn reviewers.** Invoke the `review-code` skill on a small
   diff. Confirm that:
   - The skill returns promptly (it stops the turn after spawning).
   - `gate-state.json` appears under
     `~/.cerberus/projects/<workspace-key>/<run-key>/`.
   - `gate-state.json.host == "codex"`.
4. **`Stop` matrix — pending wait.** With reviewers still running
   (`gate_status == "pending"`), trigger Codex `Stop`. Confirm the hook
   waits for reviewers up to the shared wait budget and then either
   applies the completed gate decision or emits
   `{"continue":true,"systemMessage":"reviewers still running; run
   Cerberus: Status to check"}` if the budget is exhausted.
5. **`Cerberus: Status` after completion.** When the panel finishes,
   invoke `status`. The body is the canonical active-gate shape:
   confirm `gate_status` is one of `pending`, `awaiting_decision`, or
   `resolved`; that `consensus_verdict` is one of `pass`, `fail`,
   `needs_revision`, or JSON `null`; and that `aggregated_findings`
   is the expected array. (The smaller special-body shape keyed off
   `status` only appears for `no_active_gate` / `malformed_state`.)
6. **`Cerberus: Clear Gate`.** Invoke `clear-gate`. Confirm
   `gate-state.json.status` flips to `resolved` with reason
   `manual clear`.
7. **Host-recorded metadata.** For every Codex-originated run created
   above, confirm `gate-state.json.host == "codex"`. Re-run a Claude
   review in the same workspace and confirm the Claude run is
   recorded with `host: "claude"` (cross-host filtering smoke).

If any of the eight steps fails, do **not** tag the release. The Phase
1 exit criteria require all eight to pass on a clean Codex install,
plus the full Phase 0 + Phase 1 automated test suite green.

### Phase 1 Exit Criteria Recap

These are the testable exit criteria from the original Phase 1 plan:

| Criterion | Verified by |
|---|---|
| Codex `SessionStart` / `UserPromptSubmit` creates or refreshes the session registry atomically | `internal/hook/codex_test.go` + `tests/integration/codex_session_init_test.go` |
| Codex review skills spawn reviewers and reattach across `SessionStart` / `UserPromptSubmit` / `Stop` transitions | T010 skills + manual smoke step 3-6 |
| Codex `Stop` matrix behaves per spec for every row 1–13 | `internal/hook/codex_test.go` + `tests/integration/codex_stop_test.go` + manual smoke step 4-5 |
| `Clear Gate` resolves the intended run | T010 skills + manual smoke step 7 |
| Claude plugin behavior remains unchanged (full Claude suite passes) | Existing `bin/tests/*.sh` (regression) |
| `gate-state.json` records `host: "codex"` for Codex-originated runs | T004 host-metadata writer + manual smoke step 8 |

Once all six rows are green (automated + manual), the Cerberus vX+1
release tag may be cut.

## Phase 1 Spike Findings

These findings are the resolutions of **OQ-1** (Codex skill manifest
fields) and **OQ-2** (stable Codex plugin-install path env var) from
the original Phase 1 plan, recorded **2026-04-30**.
They are preserved here for auditability of the design decisions that
shaped Phase 1; future contributors can revisit them when an
authoritative Codex schema or env-var lands.

> **Source disclosure.** No public, versioned schema for
> `.codex-plugin/plugin.json` was available during the original
> 2026-04-30 spike. The first implementation used a descriptor-array
> `skills` shape modeled on other plugin ecosystems. Live validation
> against Codex CLI 0.128 rejected that shape. The current shipping
> schema below is therefore the empirically verified 0.128-compatible
> shape, not the original best-effort descriptor-array proposal.

### OQ-1 — `.codex-plugin/plugin.json` Schema (Codex 0.128)

**Resolution:** Codex CLI 0.128 expects `skills` to be a string path to
a skill directory. Each child directory is one skill, and each skill
directory contains `SKILL.md` with YAML frontmatter.

#### Required top-level fields

| Field | Type | Notes |
|---|---|---|
| `name` | string | Plugin identifier; this package uses `"cerberus"`. |
| `version` | string | SemVer. The Codex package ships as `"1.0.0"`. |
| `description` | string | One-line package description. |
| `skills` | string | Plugin-relative directory path. Cerberus uses `"./skills/"`. |
| `interface` | object | UI metadata used by current Codex plugin discovery (`displayName`, descriptions, category, capabilities, prompts, brand color). |

#### Skill directory shape

The `skills` path points at directories named after each skill:

```text
skills/
  ask/SKILL.md
  clear-gate/SKILL.md
  review-code/SKILL.md
  review-plan/SKILL.md
  review-spec/SKILL.md
  status/SKILL.md
```

The manifest points at `skills/` so the same flat skill tree is shared
by Claude and Codex.

#### Slash-command vs skill semantics for the six Tier-1 workflows

Codex packaging is **skills-only**: there is no separate slash-command
declaration in `.codex-plugin/plugin.json`. The user invokes the six
Tier-1 workflows through Codex's skill-invocation UX (the exact verb —
`/skill`, `@`-mention, or skill picker — is host-dependent and not part
of the manifest contract).

| Workflow | Skill file | Backend invocation | Argument shape |
|---|---|---|---|
| Code review | `skills/review-code/SKILL.md` | `bin/review-gate spawn-code-review [flags]` | Optional flags: `--mode`, `--consensus`, `--agents`, `--max-rounds`, diff selectors, and optional focus text. |
| Plan review | `skills/review-plan/SKILL.md` | `bin/review-gate spawn-plan-review [plan-path] [flags]` | Explicit path recommended on non-Claude hosts. |
| Spec review | `skills/review-spec/SKILL.md` | `bin/review-gate spawn-spec-review <spec-path> [flags]` | Spec path required by the backend. |
| Ask panel | `skills/ask/SKILL.md` | `bin/review-gate spawn-ask <question>` then `wait --json --finalize` | Free-text question; skill synthesizes the panel answer from the wait output. |
| Status | `skills/status/SKILL.md` | `bin/review-gate status --json` | None. Read-only; never mutates state (see plan §Phase 0 exit criteria). |
| Clear gate | `skills/clear-gate/SKILL.md` | `bin/review-gate resolve --reason "manual clear"` | None. Operator escape hatch. |

#### Sample manifest

This is the manifest shape:

```json
{
  "name": "cerberus",
  "version": "1.0.9",
  "description": "Three-headed guardian of code quality. Multi-model consensus review with Codex, Gemini, and Claude.",
  "author": {
    "name": "charlieyou"
  },
  "repository": "https://github.com/charlieyou/cerberus",
  "license": "MIT",
  "keywords": [
    "code-review",
    "plan-review",
    "multi-model",
    "quality-gate",
    "cerberus"
  ],
  "skills": "./skills/",
  "hooks": "./hooks/codex-hooks.json",
  "interface": {
    "displayName": "Cerberus",
    "shortDescription": "Multi-model review gates for Codex",
    "longDescription": "Run Codex, Gemini, and Claude review panels for code, plans, specs, and open-ended design questions, then gate session stop until consensus is reached.",
    "developerName": "charlieyou",
    "category": "Coding",
    "capabilities": [
      "Interactive",
      "Read",
      "Write"
    ],
    "websiteURL": "https://github.com/charlieyou/cerberus",
    "defaultPrompt": [
      "Review this change with Cerberus",
      "Ask the Cerberus panel for a second opinion",
      "Check the current Cerberus gate status"
    ],
    "brandColor": "#111827"
  }
}
```

### OQ-2 — Stable plugin-install path env var

**Resolution:** **No** stable, documented Codex-provided env var
equivalent to Claude's `CLAUDE_PLUGIN_ROOT` is known as of 2026-04-30.

**Legacy fallback approach:** `templates/codex-hooks.json` ships with a
documented placeholder string for older Codex versions that do not load
plugin-bundled lifecycle hooks. The placeholder is:

```text
<CERBERUS_INSTALL_ROOT>
```

It appears in every `command:` field in the hook template that needs
to invoke a Cerberus binary. In current Codex installs the bundled
`hooks/codex-hooks.json` uses `${PLUGIN_ROOT}`, so no manual placeholder
substitution is required. The legacy `templates/codex-hooks.json`
fallback still contains `<CERBERUS_INSTALL_ROOT>` for older Codex
versions that do not load plugin-bundled lifecycle hooks; if you use
that fallback, replace the placeholder with the absolute Cerberus
backend checkout root (the directory containing `bin/` and
`templates/`). Do not use Codex's plugin cache path for this
substitution.

**Rationale.**

- Plan §Risks (L1033) called out the original placeholder-template
  fallback. Current Codex plugin hooks provide `${PLUGIN_ROOT}`, so the
  bundled hook config is now the primary path and the template remains
  only as a legacy fallback.
- The shared backend already accepts `CERBERUS_ROOT` as an explicit
  override (plan §API/Interface Design L549). Codex skills also require
  this env var because installed skill markdown is cached and is not
  patched with a local checkout path during install.
- The shared backend already routes through `__cerberus_resolve_root`,
  which picks `CERBERUS_ROOT` first, so callers who set `CERBERUS_ROOT`
  in env continue to work with either bundled hooks or the legacy
  manual template.

**Install-time UX (shipping form).**

The Codex install is:

1. Clone or otherwise place the Cerberus repository at a known
   absolute path (the **backend checkout root**).
2. Add `.agents/plugins/marketplace.json` to Codex and install/enable
   `cerberus@cerberus-local`, which points at the repository root.
3. Set `CERBERUS_ROOT` in Codex's shell environment to the backend
   checkout root.
4. Ensure `codex_hooks = true` and `plugin_hooks = true` in Codex's
   feature config, then start a new Codex session so Codex loads the
   plugin-bundled `hooks/codex-hooks.json`.

The Cerberus backend itself continues to read `CERBERUS_ROOT` (with
`CLAUDE_PLUGIN_ROOT` fallback) via `__cerberus_resolve_root`. The
placeholder lives **only** in the legacy hook template, not in any
backend code path or current Codex skill body.

### Implications for downstream tasks (historical)

- **T007** (landed) authored `.codex-plugin/plugin.json`. It was later
  revised after Codex 0.128 rejected the initial descriptor-array
  schema; the current manifest uses `skills` as a directory path and
  includes `interface` metadata.
- **T010** (landed) authored `templates/codex-hooks.json` using the
  `<CERBERUS_INSTALL_ROOT>` placeholder per OQ-2 and shipped the first
  Codex skills. The current package uses the generic skill tree under
  `skills/<skill>/SKILL.md` as the single source.
- **T011** (this task) finalizes the user-facing sections of this
  document and links them from the host catalog in `README.md`.
