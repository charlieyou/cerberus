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
- Roster file locations and schema: [README roster configuration](../README.md#roster-configuration)
- Code-review invocation flags: [README review-code](../README.md#review-code)

## Install And Enable

1. Install Cerberus from the repository checkout using the shared
   [README install](../README.md#install) flow.
2. Enable the Codex plugin from `.codex-plugin/plugin.json`.
3. Start a new Codex session so Codex reloads the plugin manifest, skills, and
   hook manifest.

The Codex plugin manifest points at `skills/` for the `/cerberus:*` skills and
at `hooks/codex-hooks.json` for lifecycle hooks. The hook entries lazy-build
`bin/cerberus` when needed, then execute the Codex hook subcommands described
below.

If your Codex install requires explicit hook feature flags, enable them in
`~/.codex/config.toml`:

```toml
[features]
codex_hooks = true
plugin_hooks = true
```

Set `CERBERUS_ROOT` only when you are running Cerberus from a local checkout or
testing an unpacked plugin. In a normal plugin install, `${PLUGIN_ROOT}` points
the hook manifest at the installed Cerberus plugin root.

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

## State On Codex

Codex-originated Cerberus state lives under the Codex project tree:

```text
~/.codex/projects/<key>/cerberus/
```

Within that tree, each run stores the same v2 state shape used by other hosts:
`gate-state.json`, per-iteration reviewer artifacts, aggregate output, and
telemetry. The host field in run state is `codex` for Codex-originated runs.

The SessionStart and UserPromptSubmit hooks maintain the active Codex session
pointer. Review skills use that hook-maintained state to connect
`/cerberus:review-code` with the later `codex-stop` hook. If the hooks have not
run in the current Codex session, start a new session after enabling the plugin
instead of manually inventing a run key.

## Running Review On Codex

After the plugin is enabled and a new Codex session is running, invoke the
review skill from Codex:

```text
/cerberus:review-code --roster codex-panel --uncommitted
```

The skill spawns reviewer processes, writes gate state under the Codex state
root, and returns control to the host. When Codex reaches the next Stop
boundary, `cerberus hook codex-stop` polls the gate:

- `pending`: keep waiting until reviewers finish or the internal wait budget is
  exhausted.
- `resolved`: allow the stop.
- failed reviewer process, invalid roster, or invalid reviewer output:
  return a non-zero Cerberus error instead of silently passing the gate.

Use `/cerberus:status` to inspect the active gate and `/cerberus:clear-gate` to
manually resolve a gate that you intentionally want to clear.

## Multi-Instance Codex Rosters

Roster files are shared across hosts. The schema, search order, and merge rules
are shared Cerberus behavior; see
[README roster configuration](../README.md#roster-configuration) for the
canonical roster contract.

This Codex-only roster runs three independent Codex reviewers with distinct
models and strategies:

```yaml
version: 1
rosters:
  codex-panel:
    reviewers:
      - provider: codex
        model: gpt-5.5
        strategy: verification-first
      - provider: codex
        model: gpt-5.4
        strategy: falsification-first
      - provider: codex
        model: gpt-5.3-codex
        strategy: decompose
```

Save it as `./.cerberus/rosters.yaml` for a project-specific roster, or as
`~/.cerberus/rosters.yaml` for a user-level roster. Then run:

```text
/cerberus:review-code --roster codex-panel --uncommitted
```

Cerberus assigns instance IDs by provider occurrence after roster resolution:
`codex#1`, `codex#2`, and `codex#3`. Duplicate provider/model pairs are valid;
use different `strategy`, `persona`, or `mode` values when you want reviewers to
approach the same artifact differently.

You can also mix Codex with other providers:

```yaml
version: 1
rosters:
  codex-gemini:
    reviewers:
      - provider: codex
        model: gpt-5.5
        strategy: verification-first
      - provider: codex
        model: gpt-5.4
        strategy: falsification-first
      - provider: gemini
        model: gemini-3.1-pro
        strategy: decompose
```

Gemini reviewers run under the same read-only policy on Codex as they do on
Claude Code. The policy file and environment override are documented in
[README environment contract](../README.md#environment-contract).

## Default Roster Degradation

The built-in default roster is `[claude, codex, gemini]`. On a Codex-only host,
that default roster degrades at preflight according to D13 and D39:

- Missing default reviewer CLIs are dropped.
- Cerberus emits one stderr warning per dropped default reviewer.
- The reduced default panel proceeds when at least one reviewer remains.
- A zero-reviewer panel refuses before creating a gate.

Custom rosters are stricter. If you select a file roster with `--roster` or add
reviewers with `--reviewer`, Cerberus does not silently drop missing providers.
Preflight rejects the invocation and reports the unavailable reviewer slot so
you can install the CLI or edit the roster.

Debate has one additional rule from D7: `--debate` requires at least two active
reviewers after default-roster degradation and custom-roster preflight. If a
Codex-only machine degrades the default roster to one Codex reviewer, this is
valid for a normal review but rejected for:

```text
/cerberus:review-code --debate
```

Install another reviewer CLI or choose a custom multi-instance Codex roster
before using `--debate`.

## Gemini Policy Under Codex

Cerberus does not rely on Codex sandbox settings to make Gemini read-only.
Gemini reviewer subprocesses use the configured Gemini Policy Engine file,
including in multi-instance and debate panels. Keep the default policy enabled
unless you intentionally want Gemini to have broader local tool access.

If Gemini is unavailable and you use the built-in default roster, it is dropped
with a warning. If Gemini is named in a custom roster, preflight rejects the run
until the `gemini` CLI and policy configuration are usable.

## Hook Timeout And Lazy Build Budget

The first Cerberus invocation after clone, upgrade, or source change may spend
time building `bin/cerberus`. The Codex hook manifest performs this lazy build
inside the hook command before executing `cerberus hook ...`.

D38 sets two separate budgets:

- Codex Stop hook manifest timeout: `2100` seconds.
- Internal Go-side Stop wait limit: `MAX_WAIT_SECONDS = 1800` seconds.

The 300-second difference is reserved for lazy build time, cleanup, stderr
messages, and host overhead before Codex enforces its outer timeout. A clean
first build usually consumes seconds to tens of seconds, but that time still
comes out of the `2100` second Stop hook budget. Steady-state hooks skip the
build when `make -q -C "$CERBERUS_ROOT" build` reports that `bin/cerberus` is
current.

Operationally:

- Install Go and `make` before enabling hooks.
- Expect the first Stop after an upgrade to be slower.
- If Stop times out near the host limit, check whether lazy build output appears
  before the review polling messages.

## Troubleshooting

`cerberus: plugin root not set`

The hook resolver could not find `CERBERUS_ROOT`, `CLAUDE_PLUGIN_ROOT`, or
`PLUGIN_ROOT`. In normal plugin installs, Codex provides `PLUGIN_ROOT`. For a
local checkout, export `CERBERUS_ROOT` to the Cerberus repository root before
starting Codex.

`cerberus: make not found on PATH; install make and retry.`

The hook resolver uses `make -q` for staleness checks. Install `make` and start
a new Codex session with the updated PATH.

`cerberus: Go >= 1.22 not found on PATH; install Go and retry.`

`bin/cerberus` is missing or stale and must be rebuilt. Install Go, then invoke
the skill or restart the Codex session.

`codex-stop` allows a stop even though you expected a gate

Check `/cerberus:status`. If there is no active gate, verify that
`codex-session-start` and `codex-prompt-submit` have run in this Codex session
and that state exists under `~/.codex/projects/<key>/cerberus/`.

Custom roster fails but the default roster works

This is expected when a custom roster names an unavailable provider or invalid
strategy/persona. The built-in default roster can degrade with warnings; custom
rosters reject missing reviewer CLIs so a typo does not silently change the
review panel.

`--debate` refuses on a Codex-only host

After default-roster degradation, only one reviewer remains. Debate requires at
least two active reviewers. Use a multi-instance Codex roster or install another
provider CLI.

Gemini appears to have write access

Confirm the Gemini policy path in the shared
[README environment contract](../README.md#environment-contract) and
verify that your custom environment has not overridden or removed the policy
file. Cerberus expects the same Gemini read-only policy under Codex and Claude.

First hook invocation is slow

Look for `cerberus: building... (this happens once after clone or upgrade)` on
stderr. That build time is expected after clone, upgrade, or source edits and
counts against the D38 Stop hook timeout budget.
