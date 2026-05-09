# Cerberus v2 — Go Core, First-Class Debate, Multi-Instance Roster, Native Codex Plugin

**Tier:** L
**Owner:** charlieyou (sole maintainer).
**Target ship:** v2.0.0 milestone, date pinned by implementation plan.
**Links:** `README.md`, `docs/debate.md`, `docs/CODEX.md`, `TODO.md`, `docs/2026-04-25-debate-spec.md`, `docs/2026-04-25-debate-plan.md`

---

## 1. Outcome & Scope

### Problem / context

Cerberus v1 is ~17K lines of Bash across 14 scripts under `bin/`. The runtime works, but it has hit a complexity ceiling:

- **Multi-instance / multi-version reviewers** are not expressible: `bin/review-gate-models.sh` resolves one `{CLAUDE,CODEX,GEMINI}_MODEL_EFFECTIVE` per panel and assumes 1-of-each.
- **Debate is bolted on, not first-class.** `--debate` hands off to `review-gate-debate.sh` (3,183 lines) which duplicates state-machine and aggregation code from `review-gate-lib.sh`.
- **Codex CLI is a phase-1 adapter.** `/cerberus:run-team` and parts of `bin/cerberus-task-completed-hook` are Claude-only because Codex lacks the Claude Agent / TaskCompleted / TeammateIdle APIs.
- **Bash portability tax.** BSD vs GNU `mktemp`/`date`, jq piping for every JSON read, manual `nohup setsid`, three implementations of `iso8601_to_epoch`. ~15-25% of bash is duplicated/portability code.
- **Test coverage gaps:** no test for multi-instance same-model rosters, no test for cross-model rosters, no test for Codex inside a debate panel.

A clean Go core fixes the complexity ceiling, makes debate native, and lets Codex be a peer host instead of an adapter.

### Simplification mandate

v2 is a clean rewrite, NOT a v1 port. The same user-visible functionality (13 surviving skills, `--debate`, `--mode`, `--max-rounds`, multi-instance roster, Stop-hook gating, dual-host plugin packaging) ships, but v1's fault-tolerance accretions — JSON output repair, mid-debate degradation paths, hook fail-open semantics, gate-state migration, byte-parity guarantees, BSD/GNU portability gymnastics, env-var alias chains — are NOT carried forward in v2.0 GA. Errors surface loudly (log + non-zero exit). Future iterations rebuild fault tolerance incrementally as real failure modes emerge.

This is the binding design stance for the rest of the spec. Every R below is stated in its simplest form; do not infer additional fault-tolerance requirements from v1's behavior.

### Goal

Ship **Cerberus v2**: a Go-based review/debate engine with one CLI binary, plugin packaging for Claude Code AND Codex CLI as first-class hosts, and a roster surface that supports arbitrary mixes of models — multi-instance same model, multi-version same provider — each with its own reasoning strategy and optional persona.

### Success criteria

| # | Metric | Threshold | Timeframe |
|---|--------|-----------|-----------|
| S1 | Skill parity between Claude and Codex | 13/13 surviving `/cerberus:*` skills work on both hosts (per D9 cascade; run-team removed) | by v2.0 GA |
| S2 | Roster expressiveness | A roster of `{codex×3 different models, gemini×1, claude×2 with distinct strategies}` can be defined without editing source and runs end-to-end | by v2.0 GA |
| S3 | Bash footprint | Zero `bin/*.sh` files in the v2 plugin tree (per Decision D1). All user-facing workflows dispatch through `bin/cerberus`. Plugin manifests contain no shell references beyond the inline hook bootstrap command. | by v2.0 GA |
| S4 | Debate code consolidation | Debate is preserved as the `--debate` opt-in flag (per Decision D2 — same surface as v1), but the implementation is unified: no duplication of state-machine, aggregation, or anonymization between debate and non-debate paths. | by v2.0 GA |
| S5 | Cross-platform builds | `go build` produces darwin-{amd64,arm64} and linux-{amd64,arm64} binaries with no Cgo. Per Decision D3, builds happen on the user's machine via `make install` / `go install`. | by v2.0 GA |
| S6 | Reviewer prompts remain editable | `prompts/**/*.md` stays on disk so users can tune prompts without rebuilding | day-1 |

### Non-goals

- **No new artifact types.** Still: code, plan, spec, epic-verify, ask.
- **No new reviewer providers.** Still shells out to the existing `claude`, `codex`, `gemini` CLIs. No HTTP/SDK calls.
- **No new IDEs / hosts.** Claude Code, Codex CLI, generic only.
- **No change to per-reviewer JSON schema.** `findings[].confidence`, `overall_confidence`, `strategy`, `round`, `peer_responses_seen` keep their v1 shapes.
- **No new gate states.** Still `pending → resolved`.
- **No replacement of the prompt content.** Reviewer/strategy/revision prompt bodies stay equivalent unless explicitly re-tuned.
- **No v1 → v2 state migration.** v2 expects a clean state tree; users on v1 clear state when upgrading (one-line `rm -rf` documented under D11 rollback).
- **No web UI / dashboard.** Telemetry is JSON on disk like v1.
- **No team automation in v2.** Per Decisions D6 + D9, `/cerberus:run-team`, `bin/cerberus-task-completed-hook`, `bin/cerberus-teammate-idle-hook`, `agents/implementer.md`, `templates/team-tasks-template.md`, and the `TaskCompleted` / `TeammateIdle` hook entries are REMOVED. `/cerberus:create-tasks`, `/cerberus:review-tasks`, and `templates/tasks-template.md` SURVIVE as standalone human-use skills.
- **No strategy / mode rotation across rounds.** Per Decision D8, on the TODO backlog. Strategy is fixed per reviewer for the whole run.
- **No K\*, αK telemetry, or sparsification in v2.0.** Recorded as v2.x candidates (open Q14/Q15).
- **No pre-built binaries.** Per Decision D3, users build locally with Go ≥ 1.22.
- **No supported v2 → v1 state downgrade.** Per Decision D11, recovery is a marketplace pin plus state removal.

### Constraints

- **C1 (install)** — Plugin must remain installable via `/plugin install cerberus` on Claude Code AND via Codex's plugin manifest. Per Decision D3, v2 additionally requires the user to have a Go toolchain (`go ≥ 1.22`) installed; first-run `make install` (or equivalent post-install hook) compiles the binary locally. Beyond that, no manual setup beyond installing the upstream `claude`/`codex`/`gemini` CLIs.
- **C2 (env contract)** — v2 reads `CERBERUS_*` env vars and honors `CLAUDE_PLUGIN_ROOT` as a fallback for `CERBERUS_ROOT` only. `REVIEW_GATE_*` aliases are not supported.
- **C3 (no Cgo)** — Cross-compile from CI to darwin/linux × amd64/arm64 with `go build` only.
- **C4 (prompt editability)** — `prompts/**/*.md` remain editable Markdown files. They may also be embedded into the binary as a fallback, but the on-disk version, when present, wins.
- **C5 (Gemini policy engine)** — `config/gemini-readonly-policy.toml` keeps blocking write tools when Gemini participates in any panel (debate or not, Cerberus-driven or not). Multi-instance Gemini panels still apply the same policy file to every Gemini child.
- **C6 (anonymization)** — Debate anonymization scrubs provider/model identifiers; peer-N IDs are assigned deterministically; no provider or model name leaks into anonymized broadcasts.
- **C7 (existing user workflow)** — A user on Claude Code who runs `/cerberus:review-code` today gets an equivalent experience post-v2: same defaults, same reviewer roster (codex+gemini+claude, one each), same Stop-hook gating. Behavior changes only when the user opts in (e.g., `--roster <name>`).

---

## 2. User Experience & Flows

### Primary flow — Review with a multi-instance roster on Codex

1. User has installed Cerberus v2 on Codex CLI with Go ≥ 1.22 and the relevant reviewer CLIs available.
2. User defines a roster in `~/.cerberus/rosters.yaml` (e.g., `diverse-codex`: `[codex/gpt-5.5/verification-first, codex/gpt-5.4/falsification-first, codex/gpt-5.3-codex/decompose, gemini/gemini-3.1-pro]`).
3. User runs `/cerberus:review-code --roster diverse-codex`.
4. If `bin/cerberus` is missing or stale, the skill bootstrap performs a lazy local build (D5), then continues.
5. Cerberus preflights the roster (validates provider/model/strategy/persona refs, assigns instance IDs).
6. Round 1: spawn all reviewers in parallel; each writes a per-reviewer JSON with `findings`, `confidence`, `verdict`.
7. Anonymization: reviewers get `peer_<N>` IDs; round-1 outputs are scrubbed of provider/model names and broadcast to peers.
8. Round 2: each reviewer sees the anonymized peer broadcast + their own round-1 output, then re-runs.
9. Aggregation: confidence-weighted vote across all reviewers. Verdict is `pass | fail | requires_decision`.
10. Stop hook holds session termination until the gate is `resolved`.
11. Telemetry is written to `<state_root>/<project>/<run>/iterations/<N>/` and `run-telemetry.json`.

### Primary flow — Default review on Claude Code (no opt-in)

The existing-user case keeps working: `/cerberus:review-code` with no flags spawns the v1 default panel (one codex, one gemini, one claude) on mode `smart`, at `--max-rounds 3`. Output, gating, and exit-code behavior remain compatible with the v1 user experience for the non-debate path.

### Key states

| State | Trigger | Stop-hook behavior |
|---|---|---|
| **Empty** | No active gate | `cerberus status` reports "no active review"; Stop hook allows termination. |
| **Pending** | Reviewers in flight | Stop hook blocks; polls `gate-state.json.status` every `POLL_INTERVAL_SECONDS` (default 3s) up to `MAX_WAIT_SECONDS` (default 1800s). |
| **Resolved** | Consensus pass / max rounds auto-resolve / manual resolve | Stop hook allows termination. |

A reviewer error is just a non-zero exit; v2 does not fail-open or invent a defensive `error` state.

### Alternate flows

- **First invocation lazy build** — Given `bin/cerberus` is missing or stale, when any surviving skill is invoked, then Cerberus builds locally and proceeds; if Go is unavailable, the user sees a clear install error and no gate is created.
- **Roster with 1 reviewer + debate** — Per Decision D7, refused at preflight. Matches v1 behavior.
- **Single-pass requested** — Default behavior: every review without `--debate` runs single-pass per Decision D2. The `--debate` flag is the explicit opt-in.
- **Mid-flight roster change** — Per Decision D10, the roster is locked within a single run (rounds 1→N). On the next iteration (after a fix commit triggers auto-respawn), the user may pass a different `--roster` to escalate.

---

## 3. Requirements + Verification

### R1 — Single Go binary subsumes the bash runtime

**Requirement.** The system MUST ship a single Go binary `cerberus` that subsumes the v1 review-gate, debate, models, generate, hook, session-init, skill-env, and telemetry libraries. (Run-team scripts are NOT subsumed; per D6/D9 they are removed.) Subcommand surface (at minimum): `spawn`, `wait`, `resolve`, `status`, `check`, `author-context`, `artifact-path`, `generate`, `hook` (host-dispatched: `hook claude-stop`, `hook codex-stop`, etc.). The v2 plugin tree MUST contain zero `bin/*.sh` files.

**Verification.**
- *Given* a fresh v2 checkout with Go ≥ 1.22, *When* the plugin is built, *Then* exactly one binary exists at `bin/cerberus`.
- *Given* the v2 plugin tree, *When* `find bin -name '*.sh' | wc -l` is run, *Then* the count is `0` (per D1).
- *Given* `go build -tags netgo ./cmd/cerberus` on a CI runner, *Then* it produces the binary with no Cgo dependency for darwin-{amd64,arm64} and linux-{amd64,arm64}.
- *Given* `bin/cerberus` is missing or stale, *When* a skill or Stop hook is invoked, *Then* the lazy build runs once and the original command continues after a successful build.
- *Given* Go is absent from PATH, *When* a skill attempts the lazy build, *Then* the user receives a clear single-line error and Cerberus does not create partial gate state.
- *Given* the v2 source tree, *When* `grep -RIl 'task-completed-hook\|teammate-idle-hook' .` is run, *Then* it returns no matches in `skills/`, `hooks/`, `agents/`, or `bin/`.

**Lazy build.** If `bin/cerberus` is missing or older than `cmd/`, `internal/`, or `go.{mod,sum}`, the bootstrap runs `make build` and execs the result. If `make` or `go` is absent, or the build fails, the bootstrap prints a one-line error to stderr and exits non-zero. v2 GA does not provide concurrency locking, atomic-rename, or read-only-install fallback — these are deferred to a later release if real failures surface.

**Edge cases.**
- Reviewer prompts (`prompts/**/*.md`) remain editable on disk; an embedded copy is OK as fallback, but the disk copy wins. Prompt edits do not require rebuilding the binary.
- Binary size budget: ≤ 30 MB stripped on darwin-arm64. Plan revisits if dependencies push above 30 MB; any increase is recorded as an explicit decision.
- **Hook bootstrap.** `hooks/hooks.json` and `hooks/codex-hooks.json` invoke `bin/cerberus` directly. Because hooks fire independently of skill invocation, the lazy-build trigger MUST also be reachable from the hook entry. v2 satisfies this without a `bin/*.sh` file by inlining a small shell `command` in the hook manifest (e.g., `command: "sh -c 'cd \"$CERBERUS_ROOT\" && [ -x bin/cerberus ] || make build && exec bin/cerberus hook claude-stop \"$@\"'"`). The inline command is part of the host's hook manifest, not a tracked `*.sh` file in the plugin tree.
- **Test layout.** v1's bash test fixtures under `bin/tests/` are either ported to Go test files under `internal/.../*_test.go` or moved to a top-level `tests/` directory and excluded from the plugin install bundle.

### R2 — Roster config supports multi-instance and intra-provider model mixes

**Requirement.** The system MUST allow rosters that specify N reviewer slots, where each slot is a tuple `(provider, model, strategy?, persona_path?, mode?)`. Rosters MAY contain duplicate `(provider, model)` pairs distinguished by strategy or persona; rosters MAY also contain duplicate `(provider, model, strategy)` triples distinguished by instance index. Per Decision D4, rosters are defined in a YAML config file at one of:
1. `./.cerberus/rosters.yaml` (per-project; takes precedence)
2. `$XDG_CONFIG_HOME/cerberus/rosters.yaml` or `~/.cerberus/rosters.yaml` (per-user)

CLI invocations select rosters by name (`--roster <name>`) and may append/override slots inline via repeatable `--reviewer <provider>:<model>:<strategy>` flags (CLI overrides win, then file, then v1-default panel). Rosters MUST be definable without editing source code (per S2). Per Decision D12, the concrete YAML field set is finalized in the implementation plan.

**Merge rule.** `--reviewer` flags APPEND new slots to the resolved roster by default — multi-instance is allowed, so two slots with identical `(provider, model, strategy)` triples are NOT a conflict and result in two instances (`#1` and `#2`). To explicitly REPLACE a file-defined slot, the user passes `--replace-slot <instance_id>` (e.g., `--replace-slot codex#2`) alongside a `--reviewer` flag; preflight rejects if no slot with that ID exists in the file roster. The full grammar of `--reviewer` (e.g., persona/mode override syntax) is finalized in plan per D12; this paragraph fixes only the conflict semantics.

**Verification.**
- *Given* a project roster and a user roster with the same name, *When* the user selects that roster, *Then* the project roster is used.
- *Given* a roster with three codex slots (different models, different strategies), *When* `/cerberus:review-code --roster <name>` is invoked, *Then* three `codex` subprocesses spawn with distinct `--model` flags and write per-reviewer JSON keyed by `codex#1 | codex#2 | codex#3`.
- *Given* a roster with `2× claude-opus` differing only in strategy, *Then* both Claude reviewers spawn independently with distinct anonymized peer IDs.
- *Given* file roster `[codex#1/verification-first, codex#2/falsification-first]` + CLI `--reviewer codex:gpt-5.5:verification-first`, *Then* the resulting roster is `[codex#1, codex#2, codex#3]` (append). *With* `--replace-slot codex#2 --reviewer codex:gpt-5.5:decompose`, *Then* the result is `[codex#1, codex#2/decompose]`.
- *Given* multi-instance reviewers, *Then* per-reviewer telemetry rows key on instance ID and aggregate totals include every slot exactly once.

**Schema seed (per D12, finalized in plan).** v2 GA MUST conform to at least:
- **Top-level shape.** YAML with `version: 1` and a `rosters:` map. Each key is a roster name (`[a-z0-9_-]+`); each value has a `reviewers:` list. Optional `defaults:` carries panel-wide settings.
- **Slot tuple.** Each `reviewers:` entry MUST contain `provider` (`claude | codex | gemini`) and `model` (string). Optional: `strategy` (name under `prompts/strategies/` or `none`), `persona` (path to `.md`), `mode` (`fast | smart | max`). Unknown keys at slot level cause preflight to reject.
- **Identity.** v2 assigns each slot an instance ID of the form `<provider>#<index>`, where `<index>` is the 1-based occurrence of `<provider>` in the resolved roster after CLI/file merge. Telemetry rows key on this instance ID.

Anything beyond this seed is plan-phase work.

**Edge cases.**
- Same `(provider, model, strategy)` triple appears twice — disambiguation by instance index in IDs (`codex#1`, `codex#2` even when otherwise identical).
- Unknown provider, unavailable model, missing strategy file, missing persona file, or invalid mode — preflight rejects with the file path and slot index in the error.
- Roster with 0 reviewers, or a roster file that fails to parse — preflight rejects, no gate created.
- A roster with one reviewer is allowed for non-debate and rejected for debate per R3/D7.

### R3 — Debate path is unified internally; CLI surface preserved

**Requirement.** Per Decision D2, debate remains an opt-in `--debate` flag with the v1 invocation surface preserved (no flag removal, no rename). Internally, the v2 implementation MUST eliminate the v1 duplication between `bin/review-gate-debate.sh` (3,183 lines) and the rest of the runtime: state-machine transitions, gate-state.json reads/writes, aggregation, and anonymization MUST live in one Go module and be called by both the debate and non-debate paths.

Multi-instance roster support (R2) extends to debate: a debate panel of `[codex#1/verification-first, codex#2/falsification-first, codex#3/decompose, gemini#1]` MUST run end-to-end with anonymization preserved (R9).

**Verification.**
- *Given* a default review without `--debate`, *When* run, *Then* one round of reviewers spawn, aggregate via majority consensus, and the gate transitions to `resolved`.
- *Given* `--debate` with ≥2 reviewers, *When* run, *Then* multiple rounds run with anonymized peer broadcasts and the gate transitions to `resolved`.
- *Given* the v2 source tree, *When* the architectural test runs, *Then* aggregation, anonymization, and gate-state I/O each live in one Go module shared by both debate and non-debate paths; no other Go package in the tree defines additional exported aggregation or anonymization symbols, or emits gate-state JSON keys directly.
- *Given* a multi-instance debate panel `[codex#1, codex#2, codex#3]` with distinct strategies, *When* round 2 peer broadcasts are generated, *Then* no broadcast contains the strings `codex`, `gpt-5.5`, etc.

**Edge cases.**
- Roster with 1 reviewer + `--debate` — refused at preflight per Decision D7.
- Strategy and mode rotation across rounds remains out of scope per Decision D8.
- v2 ships no `bin/review-gate` executable. Skill prompts and any external integration scripts MUST invoke `${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/cerberus <subcommand>`. The lazy-build bootstrap (D5) runs ahead of the exec.

### R4 — Codex CLI is a first-class plugin host

**Requirement.** Per Decisions D6 + D9 (surgical run-team removal), the surviving 13 `/cerberus:*` skills MUST be available on Codex CLI with feature parity to Claude Code: `review-code`, `review-plan`, `review-spec`, `review-tasks`, `ask`, `status`, `clear-gate`, `healthcheck`, `architecture-review`, `verify-epic`, `create-spec`, `create-plan`, `create-tasks`. The Codex `SessionStart`, `UserPromptSubmit`, and `Stop` hooks are wired the same way Claude's `SessionStart` and `Stop` hooks are. `/cerberus:run-team` MUST be absent.

**Verification.**
- *Given* Codex CLI installed and the cerberus plugin enabled, *Then* exactly the 13 surviving skills are listed and `run-team` is not available.
- *Given* the same fixture artifact on Claude and Codex, *When* each surviving review skill is invoked, *Then* the final verdict, gate lifecycle, and telemetry shape are equivalent.
- *Given* an active gate in Codex, *When* the Codex Stop hook runs, *Then* it blocks via the same poll-wait state machine as Claude's Stop hook.
- *Given* a host where `claude` CLI is absent, *When* `/cerberus:review-code` is invoked with no roster flags, *Then* the panel reduces to `[codex, gemini]`, exactly one stderr warning is emitted, and the review proceeds.
- *Given* a host where ONLY `codex` is present, *When* `/cerberus:review-code --debate` is invoked, *Then* preflight refuses per D7.

**Edge cases.**
- **Default roster on a partial-availability host (resolves Q16, see D13).** v2's default roster is `[claude, codex, gemini]`. At preflight, any reviewer whose CLI is absent on the host is dropped, a single stderr warning per missing CLI is emitted, and the resulting reduced panel proceeds. If the panel has zero reviewers, Cerberus refuses to spawn. If the panel has one reviewer and `--debate` was passed, Cerberus refuses per D7. Custom rosters (selected via `--roster <name>` or `--reviewer` flags) are NOT subject to drop-and-warn — preflight rejects custom rosters that reference unavailable CLIs.
- Host-specific transcript formatting may differ, but Cerberus verdicts and gate state must not.

### R5 — Reasoning strategies and personas configurable per reviewer

**Requirement.** Each reviewer slot in a roster MUST accept:
- `strategy: <verification-first | falsification-first | decompose | <custom-name> | none>` — when set, prepends the contents of `prompts/strategies/<name>.md` to the reviewer prompt; `none` suppresses any strategy injection.
- `persona: <path to .md file>` — when set, prepends the persona file content to the reviewer prompt. Composes with `strategy` (persona first, then strategy, then artifact-type prompt).
- `mode: <fast | smart | max>` — overrides the per-panel mode for this reviewer (defaults to panel mode).

On-disk prompt content (strategy and persona) MUST be read at run time so users can edit prompts without rebuilding `bin/cerberus`.

**Verification.**
- *Given* a slot with `persona: ./personas/security-auditor.md, strategy: falsification-first`, *When* the reviewer is spawned, *Then* the system prompt is `<persona>\n\n<strategy>\n\n<reviewer prompt for artifact type>`.
- *Given* a slot with `strategy: none`, *Then* no strategy content is injected for that slot.
- *Given* an on-disk strategy file is edited before a run, *Then* the edited content is used without rebuilding `bin/cerberus`.
- *Given* two slots using the same provider+model but different strategies, *Then* telemetry shows them as distinct participants.

**Edge cases.**
- Persona file missing — preflight error with file path and roster slot index.
- Custom strategy name with no matching `prompts/strategies/<name>.md` — preflight error.
- Invalid per-slot mode — preflight error.
- Persona + strategy + reviewer prompt exceeds model context window — *plan-phase default per open Q7: log warning and proceed; reviewer CLI handles its own truncation. Final policy decided in plan.*

### R6 — Test parity matrix in CI

**Requirement.** CI MUST run the v2 test suite against:
- `CERBERUS_HOST=claude` with mocked `claude` CLI
- `CERBERUS_HOST=codex` with mocked `codex` CLI
- `CERBERUS_HOST=generic` (no host adapter)

…on darwin and linux runners, blocking merge on any regression. The suite MUST cover at least: host-neutral state resolution, debate rounds, anonymization, multi-instance roster spawning (R2), and persona/strategy injection (R5).

**Verification.**
- *Given* the v2 repo, *When* `make test` is run on each platform, *Then* every test in the matrix passes.
- *Given* darwin and linux CI runners, *When* the build matrix runs, *Then* binaries build without Cgo for darwin-{amd64,arm64} and linux-{amd64,arm64}.
- *Given* a roster with `codex×3` different-models, *Then* all 3 spawn with distinct instance IDs, contribute distinct findings, and telemetry sums correctly.
- *Given* a roster with `claude×2` same-model different-strategy, *Then* both spawn with different system prompts and produce divergent findings (anti-collapse signal — see `docs/debate.md` § K\*).
- *Given* the v2 plugin tree, *When* the structural lint runs, *Then* `find bin -name '*.sh' -o -name '*.bash' | wc -l == 0`; skill SKILL.md and `hooks/*.json` reference no path under `bin/` other than `bin/cerberus` (the inline hook bootstrap command is the only other shell text permitted).

### R7 — Env contract

**Requirement.** v2 reads `CERBERUS_ROOT`, `CERBERUS_HOST`, `CERBERUS_RUN_KEY`, `CERBERUS_SESSION_ID`, `CERBERUS_STATE_ROOT`, `CERBERUS_PROJECT_KEY`, `CERBERUS_TRANSCRIPT_PATH`. `CLAUDE_PLUGIN_ROOT` is honored as a fallback for `CERBERUS_ROOT` only. v1's `REVIEW_GATE_*` aliases are NOT supported in v2; users with v1 CI integrations update their env to `CERBERUS_*`.

**Verification.**
- *Given* `CERBERUS_ROOT` unset and `CLAUDE_PLUGIN_ROOT` set, *When* v2 starts, *Then* `CERBERUS_ROOT` resolves to the `CLAUDE_PLUGIN_ROOT` value.

### R8 — Telemetry

**Requirement.** v2 writes per-iteration and per-run JSON telemetry under `<state_root>/<project>/<run>/iterations/<N>/` and `run-telemetry.json`. Schema is defined in plan. Per the R2 schema seed, every reviewer row uses `reviewer_id = <provider>#<index>` (1-based occurrence within the resolved roster) and carries a separate `instance_index` field — single-slot panels just have `instance_index = 1` and `reviewer_id` like `claude#1`. v1's `reviewer_id = <provider>` shape is NOT preserved (per the simplification mandate; v1 telemetry consumers are not a v2 binding constraint).

**Verification.**
- *Given* a multi-instance run, *When* telemetry is inspected, *Then* each reviewer slot has a distinct identity and aggregate totals include all slots exactly once.

**Edge cases.**
- Multi-instance panels: aggregation totals (tokens, cost) sum across instances; per-reviewer breakdown lists each instance.

### R9 — Anonymization (debate)

**Requirement.** Debate anonymization scrubs provider/model identifiers; peer-N IDs are assigned deterministically; no leakage of provider or model name into anonymized broadcasts. The Gemini read-only Policy Engine still applies to every Gemini child, including in multi-instance panels (C5). Multi-instance reviewers receive anonymous peer IDs and MUST NOT learn which provider/model produced each peer response through Cerberus-generated metadata.

**Verification.**
- *Given* a multi-instance debate panel, *When* peer broadcasts are generated, *Then* no broadcast contains provider names (`claude`, `codex`, `gemini`) or model identifiers; peer IDs are stable across rounds for the same reviewer.
- *Given* Gemini participates in debate, *When* its reviewer process runs, *Then* the Gemini read-only policy remains active.

**Edge cases.**
- Anonymization behaves identically for one-provider multi-instance panels and mixed-provider panels.

### R10 — Plugin packaging supports both Claude and Codex from the same source tree

**Requirement.** The repository MUST ship `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json` simultaneously, both pointing at the same `skills/`, `prompts/`, `hooks/`, and binary tree. v1's split between `hooks/hooks.json` (Claude) and `hooks/codex-hooks.json` (Codex) is preserved. The (now-legacy) `templates/codex-hooks.json` may be removed in v2. Both manifests MUST advertise version `2.0.0` at v2 GA. Run-team skill files, team automation hooks, `agents/implementer.md`, and `templates/team-tasks-template.md` MUST be absent from the v2 plugin surface.

**Verification.**
- *Given* the v2 source tree, *When* a Claude install is performed, *Then* it picks up `.claude-plugin/plugin.json` + `hooks/hooks.json` and works. *Same for Codex with `.codex-plugin/plugin.json` + `hooks/codex-hooks.json`.*
- *Given* either host invokes a surviving skill, *When* lazy build is needed, *Then* both hosts build and execute the same `bin/cerberus`.
- *Given* the plugin manifests are inspected at v2 GA, *Then* both advertise version `2.0.0`.
- *Given* the skill list on either host, *Then* `run-team` is absent and `create-tasks` / `review-tasks` are present.

**Edge cases.**
- Plugin manifest version: `.claude-plugin/plugin.json` is at v1.54.16; `.codex-plugin/plugin.json` is at v1.0.23. v2 starts both at `2.0.0`.
- A user pinned to v1.54.x must remain on v1 until they explicitly update per D11.

---

## 4. Instrumentation & Release Checks

### Validation after release
- Run `/cerberus:review-code` on a real PR with the v1-default panel.
- Run a custom roster (`codex×3` different models).
- Run debate on Codex CLI.
- Confirm Gemini Policy Engine still blocks write tools in multi-instance Gemini panels (C5, R9).
- Given a real Codex CLI session, when each surviving skill is invoked at least once, then all 13 skills execute or fail only for expected fixture reasons (R4, S1).

### Instrumentation events

- `cerberus.build.{started,completed,failed}` — lazy build lifecycle.
- `cerberus.roster.selected` — emitted after roster resolution; includes host, roster name, reviewer count, provider breakdown, debate flag.
- `cerberus.preflight.failed` — emitted when no gate is created due to install, roster, strategy, persona, reviewer, or debate preflight failure.
- `cerberus.review.spawned` — `{host, mode, roster_id, reviewer_count, reviewer_breakdown[provider→count], debate}`
- `cerberus.reviewer.{started,completed,failed}` — per-reviewer lifecycle.
- `cerberus.review.round_complete` — `{round, consensus_pct, abstentions, K_star_estimate?}` *(K\* per `docs/debate.md` § Effective Channels — optional, behind a flag if it adds latency.)*
- `cerberus.debate.{round_started,round_completed,peer_broadcast_written}` — debate-only events.
- `cerberus.review.resolved` — `{verdict, reason, total_tokens, cost_usd, total_rounds, host}`
- `cerberus.hook.{blocked,allowed}` — Stop hook lifecycle.
- Per-reviewer rows in iteration telemetry (R8): `{reviewer_id, instance_index, model, strategy, persona_name?, tokens, cost_usd, peer_id, verdict, overall_confidence, time_to_finish_ms, started_at, ended_at}`

### Launch checklist
- [ ] R1–R10 all verifiable
- [ ] Zero `bin/*.sh` files in the v2 plugin tree (S3)
- [ ] CI matrix (Claude × Codex × generic, darwin × linux) green (R6)
- [ ] Codex smoke test: all 13 surviving skills runnable (R4, S1)
- [ ] Multi-instance roster smoke tests (`codex×3` different models; `claude×2` different strategies) (R2, R5, S2)
- [ ] Debate smoke test covers mixed-provider and same-provider multi-instance panels (R3, R9)
- [ ] 1-reviewer plus `--debate` refuses at preflight (D7)
- [ ] Gemini read-only policy verified in single-pass and debate panels (C5, R9)
- [ ] Rollback path documented per D11: pin v1.54.x; `/plugin update --version 1.54.x` reverts; `rm -rf ~/.claude/projects/<hash>/cerberus/<run>` clears v2-written state.
- [ ] `README.md` and `docs/CODEX.md` rewritten for v2 (roster config, dual-host install, lazy build, Codex first-class)
- [ ] Plugin manifests both advertise `2.0.0` (R10)
- [ ] Run-team files and hook entries absent; `create-tasks`, `review-tasks`, `templates/tasks-template.md` remain (D9)

### Risk analysis

- **First-invoke build failures** — Lazy local builds depend on a working Go toolchain on the user's machine. *Mitigation:* clear missing-Go error pointing at install docs; no partial gate creation; single non-zero exit path.
- **Missing reviewer CLIs** — A user may have `claude` but not `codex`/`gemini` (or vice versa). *Mitigation:* default roster degrades per D13 with a one-line stderr warning per missing CLI; custom rosters reject at preflight.
- **Persona/strategy + reviewer prompt context overflow** — Combined system-prompt content can exceed model context limits on some providers. *Mitigation:* Q7 plan-phase default — log warning and proceed; reviewer CLI handles its own truncation.

### Alternatives Considered

- **D1 alt — Hybrid: keep some Bash wrappers around the Go core.** Could shell out from `bin/review-gate.sh` into `bin/cerberus` for the heavy lifting while preserving v1 paths. *Rejected:* keeps the duplication of state helpers and forces every new feature to live in two languages. Zero-bash is a structural metric (S3) precisely because hybrids drift.
- **D2 alt — Make debate the default.** Promote debate from opt-in to the default review path; remove the `--debate` flag. *Rejected:* debate is ~2–3× cost/latency vs single-pass, and existing v1 users would see a behavior change on a routine `/cerberus:review-code` invocation. "First-class" is fulfilled by internal-architecture cleanup (R3) and multi-instance support (R2), not a default-mode promotion.
- **D3 alt — Ship pre-built binaries via GitHub Releases.** The plugin install would download a per-arch binary instead of building locally. *Rejected:* introduces a release-engineering surface (signing, notarization, supply-chain attestation) that the sole maintainer doesn't want to own. Local build with a clear missing-Go error is simpler.
- **D6 alt — Build a Codex adapter for run-team.** Instead of removing run-team, write Codex equivalents for `TaskCompleted` and `TeammateIdle` hooks so run-team works on both hosts. *Rejected:* run-team is the largest, least-tested, most Claude-specific surface in v1. The maintenance cost vs the use volume isn't worth it; surgical removal (D9) cuts complexity without affecting the review/debate/generator surface that's actually load-bearing.

### Decisions made

- **D1 (Q1) — Zero bash in v2 plugin tree.** Single Go binary at `bin/cerberus` subsumes the v1 runtime: review-gate, review-gate-debate, review-gate-models, review-gate-hook, review-gate-lib, generate, codex-stop-hook, codex-session-init, claude-session-init, cerberus-skill-env, telemetry-lib. (The two run-team hook scripts — `cerberus-task-completed-hook`, `cerberus-teammate-idle-hook` — are NOT subsumed; per D6/D9 they are removed.) Skill prompts under `skills/*/SKILL.md` are updated to invoke `${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/cerberus <subcommand>`. Q12 follow-up resolved: single `cmd/cerberus` binary.
- **D2 (Q2) — `--debate` stays opt-in; CLI surface unchanged from v1.** Debate is NOT promoted to default. The "first-class" intent is fulfilled by (a) eliminating internal duplication between debate and non-debate paths (R3), (b) extending debate to multi-instance rosters and personas, and (c) preserving the v1 byte-parity guarantee on both paths.
- **D3 (Q8) — `make install` / `go install` builds the binary locally.** Plugin distribution lays down source plus a `Makefile` / `go.mod`. Requires Go ≥ 1.22 on the user's machine. No pre-built binaries committed to the repo, no GitHub Releases download.
- **D4 (Q4) — Config file + CLI overrides.** Rosters defined in YAML at `./.cerberus/rosters.yaml` (per-project, wins) and/or `~/.cerberus/rosters.yaml` (per-user). CLI: `--roster <name>` selects; `--reviewer <provider>:<model>:<strategy>` overrides or appends inline.
- **D5 (Q5/Q17/Q18) — Lazy build on first invocation.** Each skill's bootstrap snippet checks for `bin/cerberus` (and its mtime against `cmd/cerberus/main.go`); if missing or stale, runs `make -C "${CERBERUS_ROOT}"` then execs. Self-healing one-time delay on first use. If `go` is absent on PATH, the bootstrap surfaces a single-line error pointing at install docs and exits non-zero.
- **D6 (Q6) — Run-team / team automation REMOVED in v2.** No Codex adapter is built. v2 simply does not ship the team-automation surface.
- **D7 (Q3) — 1-reviewer + `--debate` refuses at preflight.** Exit code 6 (preflight). Preserves v1 behavior per `docs/debate.md` § Hard Error.
- **D8 (Q13) — Strategy / mode rotation OUT OF SCOPE for v2.** Per-round rotation stays on TODO.md backlog. v2 fixes strategy per reviewer for the whole run.
- **D9 (Q20) — Surgical cascade.** Remove: `/cerberus:run-team`, `bin/cerberus-task-completed-hook`, `bin/cerberus-teammate-idle-hook`, `agents/implementer.md`, `templates/team-tasks-template.md`, and run-team-related hook entries in `hooks/*.json`. **Keep** `/cerberus:create-tasks`, `/cerberus:review-tasks`, `templates/tasks-template.md` as standalone skills (markdown task-list generation / review for human use).
- **D10 (Q9) — Roster locked within a run, mutable across iterations.** Within one review-gate run (rounds 1→N of debate), the roster is frozen. On auto-respawn after a fix commit, the user may pass a different `--roster` and the new panel takes over for the next iteration. Lets the user escalate to a stronger panel for fix-rounds without manual gate clearing.
- **D11 (Q11) — Pin v1 plugin version in marketplace.** v2 ships as a major-version bump (2.0.0). Users on 1.54.x stay on 1.54.x until they explicitly `/plugin update`. Standard plugin-store semver. Q10 implicitly resolved: v2 → v1 downgrade is unsupported; recovery is `/plugin update --version 1.54.x` plus a documented one-line `rm -rf` on `~/.claude/projects/<hash>/cerberus/<run>` if v2 had written there.
- **D12 (Q19) — Defer concrete YAML schema to plan phase.** Spec commits to "YAML config at `./.cerberus/rosters.yaml` and `~/.cerberus/rosters.yaml` with named rosters, each containing a list of `(provider, model, strategy?, persona?, mode?)` reviewer slots". The exact field set, validation rules, and inheritance/merge semantics are pinned in the implementation plan, not the spec.
- **D13 (Q16) — Default roster degrades on partial-availability hosts.** The default panel is `[claude, codex, gemini]`. Missing CLIs are dropped at preflight with a one-line stderr warning. The reduced panel must be non-empty, and `--debate` still requires ≥2 reviewers per D7. Custom rosters do not silently degrade — they must list only available CLIs or preflight rejects.

### Open questions

*(User issued a global stop signal after Batch 3. Items below are recorded for the implementation plan, not further spec iteration.)*

- **Q7 — Persona/strategy + reviewer prompt context overflow.** Truncate persona, truncate reviewer prompt, hard-error, log warning and proceed? *Reasonable plan-phase default: log warning and proceed; reviewer CLI handles its own truncation.*
- **Q14 — K\* / αK telemetry.** Per `docs/debate.md` § K\* is a label-free diagnostic for effective channel count. Whether to compute it as part of v2 telemetry is a v2.x candidate.
- **Q15 — Sparsification (CortexDebate / S²-MAD).** Per `docs/debate.md` § Sparsify Communication. v2.x candidate; not part of v2.0 GA.

---

*Tier L per complexity scoring. Iteration 2 of the spec review gate; previously-flagged P1/P2 findings addressed in this revision.*
