# Cerberus

Three-headed guardian of code quality.

Cerberus is a plugin and local Go binary that asks multiple coding agents to
review the same thing, then turns their answers into a quality gate. Use it when
you want a second, third, or fourth opinion before shipping code, plans, specs,
task breakdowns, architecture changes, or an open-ended technical decision.

![Cerberus](cerberus.png)

## Why Cerberus exists

Single-agent review is useful, but it has two recurring failure modes: one model
misses an issue, or one model is confidently wrong. Cerberus makes review more
reliable by running a panel:

1. Build one prompt from the artifact under review.
2. Send it to a roster of reviewers such as Claude, Codex, and Gemini.
3. Optionally run a debate round so reviewers can challenge each other.
4. Aggregate verdicts and findings into a gate.
5. Keep the host session from stopping until the gate passes or you clear it.

The project deliberately keeps the runtime small: one Go binary,
`bin/cerberus`, shared by Claude Code and Codex CLI plugin packaging.

## What you can use it for

| Goal | Command |
| --- | --- |
| Review uncommitted code | `/cerberus:review-code` |
| Review code against a branch | `/cerberus:review-code --base main` |
| Ask the panel a question | `/cerberus:ask "Should we ship this design?"` |
| Review a plan or spec | `/cerberus:review-plan docs/plan.md` or `/cerberus:review-spec docs/spec.md` |
| Verify an epic | `/cerberus:verify-epic docs/epic.md` |
| Generate a spec or plan | `/cerberus:create-spec` or `/cerberus:create-plan` |
| Run a broader codebase check | `/cerberus:healthcheck` or `/cerberus:architecture-review` |
| Inspect or clear the current gate | `/cerberus:status` or `/cerberus:clear-gate` |

Add `--debate` to review and ask commands when you want a multi-round panel
instead of independent one-pass reviews.

## Typical workflows

Use Cerberus at whichever point you need independent pressure on the work:

- **Shape work before coding**: `/cerberus:create-spec` →
  `/cerberus:create-plan` → `/cerberus:create-tasks`.
- **Check an artifact before execution**: `/cerberus:review-spec`,
  `/cerberus:review-plan`, or `/cerberus:review-tasks`.
- **Gate implementation changes**: `/cerberus:review-code`, usually after the
  local tests for the change pass.
- **Get broader judgment**: `/cerberus:ask`, `/cerberus:healthcheck`, or
  `/cerberus:architecture-review`.

## Requirements

Cerberus builds itself locally on first use, so every install needs:

- Go 1.22 or newer.
- `make`.
- At least one reviewer CLI on `PATH`: `claude`, `codex`, or `gemini`.

The built-in default panel is Claude + Codex + Gemini. If one of those CLIs is
missing, the built-in panel drops that reviewer and prints a warning. Custom
rosters are strict: every reviewer you name must be available.

The reviewer CLI contract currently used by Cerberus is below. For all
providers, Cerberus sends the artifact or question prompt on stdin; the table
describes argv and system-prompt shape.

| Reviewer | Invocation shape |
| --- | --- |
| Claude | `claude --print --output-format json [--model <model>] --append-system-prompt <system>` |
| Codex | `codex exec --json --model <model> <system>` |
| Gemini | `gemini --output-format json --model <model> --prompt <system> --policy <policy.toml>` |

After upgrading reviewer CLIs, maintainers should run:

```bash
go test ./tests/integration -run TestProviderCLIContractMatchesMocks -v
```

## Install

### Claude Code

Install from the plugin marketplace:

```text
/plugin marketplace add charlieyou/cerberus
/plugin install cerberus
```

Then run the fresh-install smoke path:

```text
/cerberus:review-code
```

On first use, the plugin builds `bin/cerberus` from source. You can also build
from a checkout yourself:

```bash
make build
```

### Codex CLI

Cerberus also ships Codex plugin metadata and hooks. Enable the plugin from the
`.codex-plugin/` package, start a new Codex session, then review and trust the
Cerberus hooks in `/hooks`.

Codex users get the same skills:

```text
/cerberus:review-code --uncommitted
/cerberus:review-code --debate
/cerberus:ask "Compare these migration options"
```

See [docs/CODEX.md](docs/CODEX.md) for Codex-specific hook trust, session state,
and troubleshooting details.

## First run: what happens

Every skill and hook starts with the same resolver:

1. Find the plugin root from `CERBERUS_ROOT`, `CLAUDE_PLUGIN_ROOT`, or
   `PLUGIN_ROOT`.
2. Check whether `bin/cerberus` is present and current with `make -q build`.
3. If needed, run `make build`.
4. Execute the requested `cerberus` subcommand.

The first command after clone, install, or upgrade may print:

```text
cerberus: building... (this happens once after clone or upgrade)
cerberus: build complete in <N>s
```

After that, normal runs use the already-built binary.

## The review gate model

Review commands spawn a background review run and create gate state for the
current host session. The host Stop hook polls that gate before the assistant is
allowed to stop.

Common outcomes:

- **Pass**: enough reviewers approve under the selected consensus rule.
- **Block**: reviewers reported blocking findings or the consensus rule failed.
- **Requires decision**: the run hit a limit or needs manual judgment.
- **Manual clear**: you intentionally resolved the gate with `/cerberus:clear-gate`.

Run `/cerberus:status` to inspect the active gate. Use `/cerberus:clear-gate`
only when you have made an explicit decision to bypass or conclude the gate.

Cerberus is designed for one active Cerberus review per project at a time.

## Review commands and flags

### Code review

```text
/cerberus:review-code
/cerberus:review-code --uncommitted
/cerberus:review-code --base main
/cerberus:review-code --commit abc123
/cerberus:review-code --commit abc123 --commit def456
/cerberus:review-code main..feature
/cerberus:review-code --exclude ':(exclude,glob)dist/**'
/cerberus:review-code "focus on error handling"
```

### Artifact review

```text
/cerberus:review-plan docs/plan.md
/cerberus:review-spec docs/spec.md
/cerberus:review-tasks --from-plan docs/plan.md
/cerberus:verify-epic docs/epic.md
```

### Ask and generate

```text
/cerberus:ask "Which option is safer?"
/cerberus:ask --debate --mode max "Argue both sides before recommending"
/cerberus:create-spec "Add team audit logs"
/cerberus:create-plan --from-spec docs/spec.md
/cerberus:create-tasks --beads --from-plan docs/plan.md
/cerberus:healthcheck "focus on persistence"
/cerberus:architecture-review
```

### Shared review flags

| Flag | Meaning |
| --- | --- |
| `--mode fast\|smart\|max` | Trade off speed and depth. |
| `--debate` | Run a debate instead of only independent reviews. Requires at least two reviewers. |
| `--max-rounds <N>` | Limit review iterations or debate rounds. |
| `--consensus majority\|all\|any` | Choose how many reviewers must pass. Blocking findings still block. |
| `--agents claude,codex,gemini` | Quick built-in provider filter. Mutually exclusive with rosters and inline reviewers. |
| `--roster <name>` | Select a named YAML roster. |
| `--reviewer provider:model[:strategy]` | Add an inline reviewer slot. |
| `--replace-slot <instance_id>` | Replace one resolved roster slot with the inline reviewer. |

Prefer rosters over `--agents` when you need model versions, repeated providers,
personas, or reviewer strategies.

Ask also accepts ask-only prompt inputs:

| Ask-only flag | Meaning |
| --- | --- |
| `--context-file <path>` | Add context to an ask prompt. |
| `--prompt-file <path>` | Read the ask prompt from a file. |

## Reviewer rosters

Rosters define named panels without changing source code. Cerberus searches for
the first roster file in this order:

1. `./.cerberus/rosters.yaml`
2. `$XDG_CONFIG_HOME/cerberus/rosters.yaml`
3. `~/.cerberus/rosters.yaml`
4. The built-in default panel, if no roster file exists.

If a roster file exists, Cerberus uses it as the source of truth. A missing
requested roster is an error; Cerberus does not silently fall back.

### Schema

```yaml
version: 1
defaults:
  mode: smart
  max_rounds: 3
rosters:
  default:
    reviewers:
      - provider: claude
        model: claude-opus-4-7
      - provider: codex
        model: gpt-5.5
        strategy: verification-first
      - provider: gemini
        model: gemini-3.1-pro-preview
        persona: personas/security.md
```

Allowed providers are `claude`, `codex`, and `gemini`. `strategy`, `mode`, and
`persona` are optional per reviewer. Persona files are resolved relative to the
roster file and must exist. `consensus` is a CLI flag, not a roster YAML key.

### Multi-instance example

```yaml
version: 1
defaults:
  mode: smart
  max_rounds: 3
rosters:
  diverse-codex:
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
      - provider: claude
        model: claude-opus-4-7
      - provider: gemini
        model: gemini-3.1-pro-preview
```

Run it with:

```text
/cerberus:review-code --roster diverse-codex
```

Cerberus assigns instance IDs after roster resolution, for example `codex#1`,
`codex#2`, `codex#3`, `claude#1`, and `gemini#1`. You can use those IDs with
`--replace-slot`:

```text
/cerberus:review-code \
  --roster diverse-codex \
  --replace-slot codex#2 \
  --reviewer codex:gpt-5.5:decompose
```

Exact duplicate reviewer slots are allowed but warn, because they are often
accidental.

## Direct binary use

Most users should invoke Cerberus through `/cerberus:*` skills. Direct CLI usage
is useful for automation and debugging:

```bash
${CERBERUS_ROOT}/bin/cerberus spawn-code-review --mode smart
${CERBERUS_ROOT}/bin/cerberus spawn-code-review --debate --roster diverse-codex
${CERBERUS_ROOT}/bin/cerberus wait --json --session-key "$CERBERUS_RUN_KEY"
${CERBERUS_ROOT}/bin/cerberus status --json
${CERBERUS_ROOT}/bin/cerberus resolve --reason "manual clear"
${CERBERUS_ROOT}/bin/cerberus generate /tmp/create-plan-drafts \
  --type create-plan \
  --prompt-file prompt.md
```

For non-plugin automation, set the host and run identity yourself because there
is no automatic Stop hook:

```bash
export CERBERUS_ROOT=$PWD
export CERBERUS_HOST=generic
export CERBERUS_STATE_ROOT=/tmp/cerberus-state
export CERBERUS_PROJECT_KEY=my-project
export CERBERUS_RUN_KEY="ci-${BUILD_ID:-local}"

bin/cerberus spawn-code-review --agents codex --base main
bin/cerberus wait --json --session-key "$CERBERUS_RUN_KEY"
```

Important direct subcommands:

| Subcommand | Purpose |
| --- | --- |
| `spawn-code-review` | Spawn a code review gate. |
| `spawn-plan-review` / `spawn-spec-review` | Spawn plan or spec review gates. |
| `spawn-ask` | Ask the panel a question. |
| `spawn-epic-verify` | Verify epic acceptance criteria. |
| `wait` | Poll a gate until it resolves or times out. |
| `status` / `check` | Print active gate status. |
| `resolve` | Mark the active gate resolved. |
| `generate` | Produce multi-model drafts for specs, plans, healthchecks, or architecture review. |
| `hook` | Entry point for host lifecycle hooks. |

## Environment contract

Cerberus uses a small host-neutral environment contract. Plugin installs usually
set these for you.

| Variable | Meaning |
| --- | --- |
| `CERBERUS_ROOT` | Plugin or checkout root containing `bin/cerberus`. |
| `CERBERUS_HOST` | `claude`, `codex`, or `generic`. |
| `CERBERUS_RUN_KEY` | Stable identity for the active Cerberus run. |
| `CERBERUS_SESSION_ID` | Host session or thread id. |
| `CERBERUS_STATE_ROOT` | Base directory for Cerberus state. |
| `CERBERUS_PROJECT_KEY` | Stable workspace key under the state root. |
| `CERBERUS_TRANSCRIPT_PATH` | Optional host transcript path. |

`CLAUDE_PLUGIN_ROOT` and `PLUGIN_ROOT` are accepted as root fallbacks. If
`CERBERUS_HOST` is unset, Cerberus infers `codex` from `PLUGIN_ROOT`, `claude`
from `CLAUDE_PLUGIN_ROOT`, and otherwise uses `generic`.

State is written under:

```text
<CERBERUS_STATE_ROOT>/<CERBERUS_PROJECT_KEY>/<CERBERUS_RUN_KEY>/
```

Each run stores gate state, reviewer artifacts, aggregate outputs, logs, and
`run-telemetry.json`.

## Troubleshooting

### `cerberus: plugin root not set`

Set `CERBERUS_ROOT` to the plugin or checkout root. In normal plugin installs,
Claude provides `CLAUDE_PLUGIN_ROOT` and Codex provides `PLUGIN_ROOT`.

### `make not found` or `Go >= 1.22 not found`

Install the missing build dependency, restart the host so `PATH` is updated, and
run the Cerberus command again.

### Build failed during first use

Run the build directly to see the compiler or Makefile error:

```bash
make build
```

`bin/cerberus` is a local build artifact and should not be committed.

### Another gate is already active

Cerberus expects one active run per project. Inspect it with:

```text
/cerberus:status
```

Then either finish the review, address the findings, or intentionally clear the
gate.

### A custom roster references a missing CLI

Install the named provider CLI or remove that reviewer from the roster. Only the
built-in default panel degrades by dropping unavailable reviewers.

### `--debate` says there are not enough reviewers

Debate requires at least two reviewers after roster resolution. Install another
provider CLI, choose a larger roster, add `--reviewer`, or remove `--debate`.

### Missing persona file

Fix `persona` in the roster or create the referenced file. Persona paths are
relative to the roster file.

## Development

Useful maintainer commands:

```bash
make build
make test
make lint
make fixtures-refresh
```

Source layout:

| Path | Purpose |
| --- | --- |
| `cmd/cerberus/` | Binary entry point. |
| `internal/cli/` | Subcommand parsing and host-facing CLI behavior. |
| `internal/orchestrator/` | Review, debate, and gate orchestration. |
| `internal/reviewer/` | Reviewer process invocation and response parsing. |
| `internal/roster/` | Roster loading, validation, degradation, and instance IDs. |
| `skills/` | Claude/Codex skill definitions. |
| `hooks/` | Claude and Codex hook manifests and handlers. |
| `prompts/` | Reviewer, generator, strategy, and revision prompts. |
| `tests/` | Integration tests, fixtures, and mock reviewer CLIs. |

See [CONTRIBUTING.md](CONTRIBUTING.md) for release checks, fixture refreshes,
and project constraints.

## More documentation

- [Codex host guide](docs/CODEX.md)
- [Debate notes](docs/debate.md)
- [v2 rebuild spec](docs/2026-05-08-rebuild-spec.md)
- [v2 rebuild plan](docs/2026-05-08-rebuild-plan.md)
