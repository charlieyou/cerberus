# Cerberus on Amp CLI

> **Status:** Phase 2 plugin integration. Cerberus on Amp is now a
> TypeScript Amp plugin at `.amp/plugins/cerberus.ts`, not an Amp Toolbox
> script. The shared backend (`bin/review-gate`, debate, telemetry,
> reviewer spawning, parsing, and consensus) remains authoritative; the
> Amp plugin only resolves Amp context, registers commands/tools, calls
> `bin/review-gate`, and maps completion decisions back into Amp.

## Install

Amp plugins are experimental and are only loaded when Amp is started with
`PLUGINS=all`. Every plugin file must begin with Amp's required WIP API
acknowledgement comment; `.amp/plugins/cerberus.ts` already does.

Clone Cerberus to a trusted path:

```bash
git clone https://github.com/charlieyou/cerberus.git ~/code/cerberus
```

Use the project-local plugin by running Amp from this checkout:

```bash
cd ~/code/cerberus
PLUGINS=all amp
```

For other workspaces, symlink the plugin into Amp's user plugin directory
and point `CERBERUS_ROOT` at the Cerberus install root:

```bash
mkdir -p ~/.config/amp/plugins
ln -s ~/code/cerberus/.amp/plugins/cerberus.ts ~/.config/amp/plugins/cerberus.ts
export CERBERUS_ROOT="$HOME/code/cerberus"
PLUGINS=all amp
```

The generic Cerberus skills are still available from `skills/<skill>/SKILL.md`.
For non-Cerberus workspaces, install or symlink those skills into the
workspace's `.agents/skills` directory if you want direct skill invocation.

## Prerequisites

| Tool | Purpose | Install hint |
|---|---|---|
| `amp` | Host CLI and plugin runtime | [Amp CLI](https://ampcode.com/) |
| `bash` (>=3.2) | Shared backend runtime | system |
| `jq` | Backend JSON processing | `brew install jq` / `apt install jq` |
| `python3` | Backend helper scripts | system |
| `codex` | OpenAI Codex reviewer | [OpenAI CLI](https://platform.openai.com/docs/guides/command-line) |
| `gemini` | Google Gemini reviewer | [Gemini CLI](https://ai.google.dev/gemini-api/docs/get-started/cli) |
| `claude` | Anthropic Claude reviewer | [Claude Code](https://docs.anthropic.com/en/docs/claude-code) |

Missing reviewer CLIs are skipped with a warning, so one- or two-reviewer
installs are supported outside debate mode. The plugin itself uses Amp's
TypeScript plugin runtime; users do not run `.amp/toolbox/cerberus.sh`.

## Security Model

Amp plugins execute local code inside the trusted workspace. Treat the
Cerberus install root as trusted compute: anyone who can edit
`.amp/plugins/cerberus.ts` or `bin/review-gate` can change what runs when
Amp loads the plugin or invokes a Cerberus tool.

The plugin writes a small runtime registry at
`~/.cerberus/runtime/amp/<workspace-key>/active-session.json`. Review state
is written by the shared backend under
`~/.cerberus/projects/<workspace-key>/<run-key>/`. Reviewer read-only
sandboxing is still provided by the reviewer CLIs and their policies, not by
the Amp plugin wrapper.

## Commands And Tools

The plugin registers both command-palette commands and agent-callable tools
for the Tier-1 workflows:

| Amp handle | Backend invocation | Required input |
|---|---|---|
| `review-code` | `bin/review-gate spawn-code-review` | optional diff scope/options |
| `review-plan` | `bin/review-gate spawn-plan-review <plan_path>` | `plan_path` |
| `review-spec` | `bin/review-gate spawn-spec-review <spec_path>` | `spec_path` |
| `ask-panel` | `bin/review-gate spawn-ask <question>` then `wait --json --finalize` | `question` |
| `ask` | Alias for `ask-panel` | `question` |
| `status` | `bin/review-gate status --json` | none |
| `clear-gate` | `bin/review-gate resolve --reason <reason>` | optional `reason` |

Every backend invocation includes a header in the returned text:

```text
Cerberus run key: <run-key>
```

Use that run key from a shell if you need to address the same gate directly:

```bash
CERBERUS_HOST=amp CERBERUS_RUN_KEY=<run-key> \
  ~/code/cerberus/bin/review-gate wait --json --session-key <run-key>
```

`review-code` accepts optional typed inputs so the agent can choose the right
diff scope instead of always using the backend default `--uncommitted`:

```json
{ "diff_mode": "commit", "commit": "HEAD" }
{ "diff_mode": "base", "base": "main" }
{ "diff_mode": "range", "range": "main..feature" }
```

It also passes through backend options including `agents`, `max_rounds`,
`mode`, `consensus`, `context_file`, `focus`, `exclude`, and `debate`.

`review-plan` and `review-spec` require explicit absolute paths on Amp.
There is no Claude-style "latest plan" fallback.

## Lifecycle Enforcement

The plugin uses Amp lifecycle events:

| Event | Cerberus behavior |
|---|---|
| `session.start` | Establishes the workspace registry and resolved run key. |
| `agent.start` | Refreshes the same registry at the start of each turn. |
| `agent.end` | Calls `bin/review-gate completion-check --host amp --json`. |

Amp does not expose a true hard Stop hook like Claude. `agent.end` can only
return `{ action: "continue", userMessage: "..." }`, which causes Amp to
start a follow-up agent turn. Cerberus uses that soft continuation when the
backend reports an uncleared gate: pending review, awaiting decision,
resolved failure, or resolved needs-revision. If the gate is absent, passed,
manually resolved, unreadable, or the backend errors, the plugin fails open.

Reviewer subprocesses bypass enforcement when this marker is truthy:

```bash
CERBERUS_REVIEWER_SUBPROCESS=1
```

Loop protection is stored in the Amp registry. If the same unchanged gate
fingerprint already caused one automatic continuation, `agent.end` allows the
next stop instead of creating an infinite loop.

## Run-Key Resolution

The plugin resolves Amp run identity in this order:

1. `CERBERUS_RUN_KEY` if explicitly set.
2. Amp thread id from `ctx.thread.id`, event `thread.id`, `AMP_THREAD_ID`, or
   `AMP_CURRENT_THREAD_ID`, when it matches `T-<lower-hex-with-hyphens>`.
3. Persisted registry run key from
   `~/.cerberus/runtime/amp/<workspace-key>/active-session.json`.
4. A fresh UUID fallback.

The registry shape is:

```json
{
  "schema_version": 1,
  "host": "amp",
  "workspace_root": "/Users/me/code/project",
  "project_key": "-Users-me-code-project",
  "run_key": "T-019de015-d2d1-70dc-ac7c-bf5ccc46dd68",
  "amp_thread_id": "T-019de015-d2d1-70dc-ac7c-bf5ccc46dd68",
  "last_seen": "2026-05-03T12:34:56.000Z",
  "last_blocking_fingerprint": "optional-loop-guard"
}
```

The shared backend receives the host-neutral env block:

```text
CERBERUS_HOST=amp
CERBERUS_ROOT=<install-root>
CERBERUS_STATE_ROOT=<home>/.cerberus/projects
CERBERUS_PROJECT_KEY=<workspace-key>
CERBERUS_RUN_KEY=<run-key>
AMP_THREAD_ID=<thread-id-when-known>
```

## Troubleshooting

### The Cerberus Commands Do Not Appear

Confirm Amp was started with plugin loading enabled:

```bash
PLUGINS=all amp
```

If the plugin is installed outside this checkout, confirm the symlink exists:

```bash
ls -l ~/.config/amp/plugins/cerberus.ts
```

### Backend Not Found

The plugin resolves `bin/review-gate` relative to `.amp/plugins/cerberus.ts`.
If you symlink only the plugin file into `~/.config/amp/plugins`, set:

```bash
export CERBERUS_ROOT="$HOME/code/cerberus"
```

### Agent Keeps Continuing After Review Failure

Run `status` to inspect the active gate. Fix the findings if they are real.
If a human intentionally overrides the gate, run `clear-gate` with an explicit
reason. Because Amp has soft continuation rather than a hard Stop hook, a user
can still close Amp manually; Cerberus cannot prevent process termination.

### Need To Target A Different Run

Export the run key before launching Amp or before invoking the command from a
shell:

```bash
CERBERUS_RUN_KEY=<run-key> PLUGINS=all amp
```

## Verification

Automated coverage for the Amp adapter lives in
`bin/tests/test-amp-plugin.sh`. It verifies the required plugin header,
command/tool registration, backend env propagation, `ask` two-step dispatch,
`completion-check` allow/continue mapping, reviewer-subprocess bypass, and
loop protection.

Manual cross-host release smoke still requires a human to start reviews from
Claude, Codex, and Amp in the same repository and confirm their state
directories coexist without collisions:

```text
Claude: ~/.claude/projects/<workspace-key>/cerberus/<sid>/gate-state.json
Codex:  ~/.cerberus/projects/<workspace-key>/<run-key>/gate-state.json (host=codex)
Amp:    ~/.cerberus/projects/<workspace-key>/<run-key>/gate-state.json (host=amp)
```
