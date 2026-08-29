# Cerberus on Codex CLI

Cerberus v2 treats Codex CLI as a first-class plugin host, with the same
review, debate, generation, and Stop-gate behavior available on Claude Code.
Codex is not a compatibility layer around the Claude integration: it has its
own plugin manifest, lifecycle hooks, session state, and host-aware hook
handlers, all backed by the shared `cerberus` binary.

Use this guide for Codex-specific setup and operation. Shared Cerberus concepts
are documented in the main [README](../README.md):

- Install prerequisites and build behavior: [README install](../README.md#install)
- Host-neutral environment variables: [README env contract](../README.md#environment-contract)
- Config file locations and schema: [README configuration](../README.md#configuration)
- Code-review invocation flags: [README code review](../README.md#code-review)

## Install And Enable

1. Install Cerberus from the repository checkout using the shared
   [README install](../README.md#install) flow.
2. Enable the Codex plugin from `.codex-plugin/plugin.json`.
3. Start a new Codex session so Codex reloads the plugin manifest, skills, and
   hook manifest.
4. Open `/hooks`, review the Cerberus `SessionStart`, `UserPromptSubmit`, and
   `Stop` hooks, and trust them. Codex discovers plugin hooks before trusting
   them, but untrusted or modified hooks stay inactive until reviewed.

The Codex plugin manifest points at `skills/` for the `/cerberus:*` skills and
at `hooks/codex-hooks.json` for lifecycle hooks. The hook entries lazy-build
`bin/cerberus` when needed, then execute the Codex hook subcommands described
below.

Codex exposes `PLUGIN_ROOT` to plugin hooks, not to normal skill Bash tool
calls. The `SessionStart` and `UserPromptSubmit` hooks therefore write the
resolved plugin root to `~/.codex/cerberus/sessions/<thread-id>/plugin-root`.
Skill bootstraps read that cache via `CODEX_THREAD_ID` so they execute the
matching plugin-local `bin/cerberus` binary. The cache key is the same Codex
session/thread identity surfaced as hook payload `session_id` and Bash
`CODEX_THREAD_ID`. Codex host signals override ambient `CERBERUS_HOST` and
`CERBERUS_SESSION_ID` values so a mixed shell environment cannot route a Codex
skill through Claude state.

If your Codex install requires explicit hook feature flags, enable them in
`~/.codex/config.toml`:

```toml
[features]
codex_hooks = true
plugin_hooks = true
```

Set `CERBERUS_ROOT` only when you are running Cerberus from a local checkout or
testing an unpacked plugin. In a normal plugin install, `${PLUGIN_ROOT}` points
the hook manifest at the installed Cerberus plugin root. Codex hook trust pins
the hook command text, not the current value of environment variables, so a
`CERBERUS_ROOT` override can redirect a previously trusted hook to a different
checkout; unset it for normal plugin installs.

## Codex Lifecycle Hooks

Codex invokes Cerberus at three lifecycle boundaries. Hook payload JSON is read
from stdin; hook commands do not depend on positional arguments. Unknown payload
fields are ignored so newer Codex releases can add fields without breaking the
Cerberus v2 hook contract.

| Codex event | Cerberus subcommand | Purpose | Payload fields Cerberus uses |
|---|---|---|---|
| `SessionStart` | `cerberus hook codex-session-start` | Records the active Codex session and initializes host state for later skills. | `session_id`, `transcript_path`, `project_key`, `cwd`, `workspace_root` |
| `UserPromptSubmit` | `cerberus hook codex-prompt-submit` | Refreshes the active session before a user prompt is handled, which keeps long-lived Codex sessions associated with the right project/run key. | `session_id`, `transcript_path`, `project_key`, `transcript`, `cwd`, `workspace_root`, `prompt` |
| `Stop` | `cerberus hook codex-stop` | Blocks or allows Codex to stop based on the active Cerberus gate state. | `session_id`, `transcript_path`, `project_key`, `cwd`, `workspace_root`, `stop_reason` |

The Codex hooks are installed from `hooks/codex-hooks.json`. Each entry uses the
same lazy-build resolver as the skill bootstraps, then runs exactly one fixed
hook subcommand:

```text
cerberus hook codex-session-start
cerberus hook codex-prompt-submit
cerberus hook codex-stop
```

This stdin-only contract is D37. Do not wrap these hooks with scripts that
forward `"$@"`; Codex event data must be passed through stdin.

Codex records a trusted hash for each reviewed hook command. If the Cerberus
hook command changes after an upgrade, Codex marks that hook as modified and it
will not run again until you review and trust the new hash in `/hooks`.

## State On Codex

Codex-originated Cerberus state lives under the Codex project tree:

```text
~/.codex/projects/<key>/cerberus/
```

Within that tree, each run stores the same v2 state shape used by other hosts:
`gate-state.json`, per-iteration reviewer artifacts, aggregate output, and
telemetry. The host field in run state is `codex` for Codex-originated runs.

The SessionStart and UserPromptSubmit hooks maintain the active Codex session
pointer and the session-scoped plugin-root cache. Review skills use that
hook-maintained state to connect `/cerberus:review-code` with the later
`codex-stop` hook. If the hooks have not run in the current Codex session, start
a new session after enabling the plugin instead of manually inventing a run key.

Codex plugin installs normally provide `PLUGIN_ROOT`; Cerberus uses that to
infer `CERBERUS_HOST=codex` when the host variable is not explicitly set. That
keeps review skills, status commands, and the Stop hook on the same Codex state
tree by default.

## Running Review On Codex

After the plugin is enabled and a new Codex session is running, invoke the
review skill from Codex:

```text
/cerberus:review-code --uncommitted
```

The skill spawns reviewer processes, writes gate state under the Codex state
root, and returns control to the host. When Codex reaches the next Stop
boundary, `cerberus hook codex-stop` polls the gate:

- `pending`: keep waiting until reviewers finish or the internal wait budget is
  exhausted.
- `resolved`: allow the stop.
- failed reviewer process, invalid config, or invalid reviewer output:
  return a non-zero Cerberus error instead of silently passing the gate.

Use `/cerberus:status` to inspect the active gate and `/cerberus:clear-gate` to
manually resolve a gate that you intentionally want to clear.

## Multi-Instance Codex Modes

Config files are shared across hosts. See
[README configuration](../README.md#configuration) for the canonical schema
and search order.

This Codex-only mode runs three independent Codex reviewers with distinct
models and strategies:

```yaml
version: 1
roster:
  codex-panel:
    models:
      - provider: codex
        model: gpt-5.6-sol
        effort: high
        strategy: verification-first
      - provider: codex
        model: gpt-5.4
        effort: high
        strategy: falsification-first
      - provider: codex
        model: gpt-5.3-codex
        effort: medium
        strategy: decompose
```

Save it as `./.cerberus/config.yaml` for a project-specific config, or as
`~/.cerberus/config.yaml` for a user-level config. Then run:

```text
/cerberus:review-code --mode codex-panel --uncommitted
```

Cerberus assigns instance IDs by provider occurrence after mode resolution:
`codex#1`, `codex#2`, and `codex#3`. Duplicate provider/model pairs are valid;
use different `strategy`, `persona`, or `effort` values when you want reviewers to
approach the same artifact differently.

You can also mix Codex with other providers:

```yaml
version: 1
roster:
  codex-gemini:
    models:
      - provider: codex
        model: gpt-5.6-sol
        effort: high
        strategy: verification-first
      - provider: codex
        model: gpt-5.4
        effort: medium
        strategy: falsification-first
      - provider: gemini
        model: gemini-3.1-pro-preview
        effort: high
        strategy: decompose
```

Gemini reviewers run under the same read-only policy on Codex as they do on
Claude Code. Cerberus derives that policy path from the plugin root:
`$CERBERUS_ROOT/config/gemini-readonly-policy.toml`. If the file is missing,
Gemini preflight fails instead of running without the read-only policy.
Cerberus passes each Gemini model entry's configured effort as its thinking
level through a temporary `GEMINI_CLI_SYSTEM_SETTINGS_PATH` file and
runs Gemini with the `cerberus-reviewer` model alias.

Claude reviewer subprocesses run with `--restricted --tools Read,Grep,Glob`
on every host, so they can inspect the repository without invoking commands,
editing files, fetching web content, or spawning subagents. This restriction
does not apply to Claude generator subprocesses.

## Default Mode Degradation

The built-in default mode is `[claude, codex, gemini]`. On a Codex-only host,
that default mode degrades at preflight according to D13 and D39:

- Missing default reviewer CLIs are dropped.
- Cerberus emits one stderr warning per dropped default reviewer.
- The reduced default panel proceeds when at least one reviewer remains.
- A zero-reviewer panel refuses before creating a gate.

Configured modes are stricter. Cerberus does not silently drop missing providers
from `config.yaml`. Preflight rejects the invocation and reports the unavailable
model so you can install the CLI or edit the mode.

Debate has one additional rule from D7: `--debate` requires at least two active
reviewers after built-in degradation and configured-mode preflight. If a
Codex-only machine degrades the default mode to one Codex reviewer, this is
valid for a normal review but rejected for:

```text
/cerberus:review-code --debate
```

Install another reviewer CLI or choose a multi-instance Codex mode
before using `--debate`.

## Gemini Policy Under Codex

Cerberus does not rely on Codex sandbox settings to make Gemini read-only.
Gemini reviewer subprocesses use the configured Gemini Policy Engine file,
including in multi-instance and debate panels. Keep the default policy enabled
unless you intentionally want Gemini to have broader local tool access.

If Gemini is unavailable and you use the built-in default mode, it is dropped
with a warning. If Gemini is named in a custom mode, preflight rejects the run
until the `gemini` CLI and policy configuration are usable.

## Hook Timeout And Lazy Build Budget

The first Cerberus invocation after clone, upgrade, or source change may spend
time building `bin/cerberus`. The Codex hook manifest performs this lazy build
inside the hook command before executing `cerberus hook ...`.

Cerberus uses two Stop-hook budgets:

- Codex Stop hook manifest timeout: `3900` seconds.
- Internal Go-side Stop wait limit: `MAX_WAIT_SECONDS = 1800` seconds by
  default, or `3600` seconds for gates started with `--mode max`.

For `--mode max`, the 300-second difference is reserved for lazy build time,
cleanup, stderr messages, and host overhead before Codex enforces its outer
timeout. Non-max gates still use the shorter 1800-second internal wait. A clean
first build usually consumes seconds to tens of seconds, but that time still
comes out of the Stop hook manifest budget. Steady-state hooks skip the build
when `make -q -C "$CERBERUS_ROOT" build` reports that `bin/cerberus` is current.

Operationally:

- Install Go and `make` before enabling hooks.
- Expect the first Stop after an upgrade to be slower.
- If Stop times out near the host limit, check whether lazy build output appears
  before the review polling messages.

## Troubleshooting

`cerberus: plugin root not set; set CERBERUS_ROOT and retry`

The resolver could not find `CERBERUS_ROOT`, hook-provided plugin variables,
or the Codex session plugin-root cache. In normal plugin installs, Codex
provides `PLUGIN_ROOT` to hooks, and the hooks write the cache for skills. If
you see this from a skill, start a new Codex session after trusting hooks; for a
local checkout, export `CERBERUS_ROOT` to the Cerberus repository root before
starting Codex. Codex skills do not fall back to Claude plugin variables; that
prevents a mixed shell environment from selecting the wrong plugin-local binary
or host/session identity.

`cerberus: make not found on PATH; install make and retry.`

The hook resolver uses `make -q` for staleness checks. Install `make` and start
a new Codex session with the updated PATH.

`cerberus: Go >= 1.22 not found on PATH; install Go and retry.`

`bin/cerberus` is missing or stale and must be rebuilt. Install Go, then invoke
the skill or restart the Codex session.

`codex-stop` allows a stop even though you expected a gate

Check `/cerberus:status`. If there is no active gate, verify that
`codex-session-start` and `codex-prompt-submit` have run in this Codex session,
that the Cerberus hooks are trusted in `/hooks`, and that state exists under
`~/.codex/projects/<key>/cerberus/`.

Configured mode fails but the built-in mode works

This is expected when a custom mode names an unavailable provider or invalid
strategy/persona. The built-in default mode can degrade with warnings; custom
configured modes reject missing reviewer CLIs so a typo does not silently
change the review panel.

`--debate` refuses on a Codex-only host

After built-in degradation, only one reviewer remains. Debate requires at
least two active reviewers. Use a multi-instance Codex mode or install another
provider CLI.

Gemini appears to have write access

Confirm that `$CERBERUS_ROOT/config/gemini-readonly-policy.toml` exists in the
plugin or checkout root. Cerberus expects the same Gemini read-only policy under
Codex and Claude, and Gemini preflight fails if the policy file is missing.

First hook invocation is slow

Look for `cerberus: building... (this happens once after clone or upgrade)` on
stderr. That build time is expected after clone, upgrade, or source edits and
counts against the Stop hook timeout budget.
