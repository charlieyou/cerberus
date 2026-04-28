# Cerberus

*Three-headed guardian of code quality.*

Multi-model consensus review system that gates Claude Code session termination until code or plans are reviewed and approved. Like its mythological namesake, Cerberus uses three AI heads (Codex, Gemini, Claude) to guard the gates—nothing leaves until consensus is reached.

![Cerberus](cerberus.png)

## Features

- **Multi-model review**: Codex, Gemini, and Claude evaluate changes in parallel
- **Automatic iteration**: Reviews loop until consensus passes (default 3 rounds, configurable via `--max-rounds`; set `--max-rounds 0` to disable auto-respawn)
- **Code review**: Review git diffs (uncommitted, branch comparisons, commits, ranges)
- **Plan & spec creation**: Interview + generator flow to draft plans or specs before review
- **Plan & spec review**: Review implementation plans or feature specs before execution

## Installation

### Prerequisites

You need the following CLI tools installed:

| Tool | Purpose | Install |
|------|---------|---------|
| `codex` | OpenAI Codex reviewer | [OpenAI CLI](https://platform.openai.com/docs/guides/command-line) |
| `gemini` | Google Gemini reviewer | [Gemini CLI](https://ai.google.dev/gemini-api/docs/get-started/cli) |
| `jq` | JSON processing | `apt install jq` / `brew install jq` |

Verified CLI versions (April 25, 2026):

| Tool | Version |
|------|---------|
| `codex` | `codex-cli 0.77.0` |
| `gemini` | `0.39.1` |
| `claude` | `2.0.76 (Claude Code)` |

Missing reviewers are skipped with a warning. You can run with just one or two.

### Install Plugin

```bash
# Add the marketplace
/plugin marketplace add charlieyou/cerberus

# Install the plugin
/plugin install cerberus
```

## Usage

### Code Review

Review git changes with external reviewers:

```
/cerberus:review-code                    # Review uncommitted changes (default)
/cerberus:review-code --base main        # Review changes from main to HEAD
/cerberus:review-code --commit abc123    # Review a single commit (net diff)
/cerberus:review-code --commit abc123 def456  # Review multiple commits (net diff)
/cerberus:review-code main..feature      # Review a commit range
/cerberus:review-code --agents codex,gemini  # Only run selected reviewers
/cerberus:review-code --exclude ':(exclude,glob)dist/**'  # Ignore files using git pathspec syntax
```

Note: `--commit` generates a single net diff by applying the listed commits onto their merge-base, so non-contiguous commit lists are supported and intermediate commits are not shown individually.

**Iterative fix tracking:** For `--commit`, `--base`, and range modes, the original review scope is locked at first spawn. Fix commits made during the review session are automatically included in subsequent iterations without shifting the original range.

### Plan Review

Review an implementation plan:

```
/cerberus:review-plan                             # Review most recent session plan
/cerberus:review-plan path/to/plan.md             # Review specific plan file
/cerberus:review-plan --agents codex,gemini path/to/plan.md
```

### Spec Review

Review a feature specification:

```
/cerberus:review-spec path/to/spec.md             # Review a feature spec
/cerberus:review-spec --agents codex,gemini path/to/spec.md
```

### Ask

Ask the Cerberus model panel any question, optionally using debate mode:

```
/cerberus:ask "Should we ship this design?"
/cerberus:ask --debate "Compare these two migration options and recommend one"
/cerberus:ask --mode max --debate --prompt-file /tmp/question.md
```

`/cerberus:ask` waits for the panel, then synthesizes the reviewer answers in the current conversation. Pass `--` before prompt text that starts with a dash.

### Create Spec (Generator)

Interview the user, run multi-model generators, synthesize a spec, then run the spec review gate:

```
/cerberus:create-spec                    # Create spec with smart mode (default)
/cerberus:create-spec --mode fast        # Faster, less thorough interview
/cerberus:create-spec --mode max         # Maximum depth with risk analysis
```

**Workflow phases:**
1. **Codebase research** - Understand existing patterns and integration points
2. **Draft skeleton** - Create spec template with TBD placeholders
3. **Strategic interview** - Ask prioritized questions to fill gaps (coverage varies by mode)
4. **Multi-model generation** - Codex, Gemini, and Claude generate draft specs
5. **Synthesis** - Merge drafts into coherent spec
6. **Interactive review** - Review gate with user consultation on P0-P2 issues

| Mode | Interview Depth | Review Rounds |
|------|-----------------|---------------|
| fast | ~60% coverage | up to 2 |
| smart | ~80% coverage | up to 3 |
| max | ~95% + probing | up to 5 |

Override with `--max-rounds <N>` (e.g. `--max-rounds 0` skips the refinement loop; `--max-rounds 10` allows deeper iteration).

You can also run the generator directly with a custom prompt file that includes your context:

```
${CLAUDE_PLUGIN_ROOT}/bin/generate --type=create-spec --prompt-file path/to/prompt.md
```

### Create Plan (Generator)

Interview the user, run multi-model generators, synthesize an implementation plan, then run the plan review gate:

```
/cerberus:create-plan                              # Create plan with smart mode (default)
/cerberus:create-plan --from-spec docs/spec.md    # Start from an existing spec
/cerberus:create-plan --mode fast                  # Faster, essential questions only
/cerberus:create-plan --mode max                   # Maximum depth with risk analysis
```

**Workflow phases:**
1. **Spec detection** - Use provided spec or ask for one
2. **Codebase research** - Identify files, patterns, and integration points
3. **File verification** - Check which files exist vs need creation
4. **Draft skeleton** - Create plan template with TBD placeholders
5. **Implementation interview** - Ask about scope, constraints, and testing
6. **Multi-model generation** - Codex, Gemini, and Claude generate draft plans
7. **Subagent synthesis** - Merge drafts into coherent plan (preserves context)
8. **Review gate** - Iterate until consensus passes

| Mode | Interview Depth | Review Rounds |
|------|-----------------|---------------|
| fast | ~60% coverage | up to 2 |
| smart | ~80% coverage | up to 3 |
| max | ~95% + probing | up to 5 |

Override with `--max-rounds <N>` (e.g. `--max-rounds 0` skips the refinement loop; `--max-rounds 10` allows deeper iteration).

You can also run the generator directly:

```
${CLAUDE_PLUGIN_ROOT}/bin/generate --type=create-plan --prompt-file path/to/prompt.md
```

### Healthcheck & Architecture Review

Generate multi-model drafts (Codex/Gemini/Claude), then synthesize into a single artifact:

```
/cerberus:healthcheck
/cerberus:architecture-review
```

You can also run the generator directly:

```
${CLAUDE_PLUGIN_ROOT}/bin/generate --type=healthcheck
${CLAUDE_PLUGIN_ROOT}/bin/generate --type=architecture-review
```

### Agent Selection

All review commands accept `--agents <list>` to run a subset of the available reviewers. Provide a comma-separated list such as `codex,gemini` or `claude`.

### Intelligence Modes

All review and generator commands accept `--mode <fast|smart|max>` to trade off speed vs depth. Default is `smart`.

| Mode | Codex reasoning | Gemini model | Claude model | Prompt |
|------|-----------------|--------------|--------------|--------|
| fast | medium | `gemini-3-flash-preview` | `sonnet` | - |
| smart | high | `gemini-3.1-pro-preview` | `opus` | - |
| max | xhigh | `gemini-3.1-pro-preview` | `opus` | `ultrathink` |

Examples:

```
/cerberus:review-code --mode fast
/cerberus:review-plan --mode smart path/to/plan.md
/cerberus:review-spec --mode max path/to/spec.md
/cerberus:create-spec --mode max
/cerberus:create-plan --mode fast --from-spec docs/spec.md
```

## Debate Mode

Opt-in multi-round peer-review mode for the review commands and `/cerberus:ask`.
Off by default. Designed for the cases where a single-pass review is suspected
of sycophantic agreement or missed defects, or where an arbitrary question would
benefit from a debate among models.

### Usage

Pass `--debate` to either the bare `spawn` command or the supported spawn
subcommands:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-code-review --debate
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-plan-review --debate path/to/plan.md
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-spec-review --debate path/to/spec.md
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-epic-verify --debate path/to/epic.md
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-ask --debate "Should we ship this?"
```

`--debate` is silently passed through by the slash-command wrappers, so:

```
/cerberus:review-code --debate
/cerberus:review-plan --debate path/to/plan.md
/cerberus:review-spec --debate path/to/spec.md
/cerberus:verify-epic --debate path/to/epic.md
/cerberus:ask --debate "Should we ship this?"
```

work as well.

### Round Shape

| Mode    | Total rounds |
|---------|--------------|
| `fast`  | 2 |
| `smart` | 2 |
| `max`   | 3 |

Round 1 is the cold first read; the remaining round(s) are peer rounds. Each
peer round shows reviewers an anonymized block of their peers' prior-round
outputs and their own prior-round output, then re-runs them. Reviewers are
assigned distinct reasoning strategies (`verification-first`,
`falsification-first`, `decompose`) per artifact for the duration of the run.

### Cost & Latency

Debate adds full reviewer rounds to the critical path. Approximate cost vs the
non-debate baseline on the same artifact:

| Mode    | Token cost | Wall-clock latency |
|---------|------------|---------------------|
| `fast`  | ~2× | ~2× |
| `smart` | ~2× | ~2× |
| `max`   | ~3× | ~3× |

These are vibes, not budgets — anything in the 1.5×–3.5× band is expected.
**CI jobs sized for single-pass review will time out under `--debate`.** If
you wire `--debate` into CI, raise the job timeout accordingly.

### Hard Error: Fewer Than 2 Reviewers

Debate has no useful single-agent fallback. Running with fewer than 2 available
reviewers (because of `--agents` selection or missing CLIs) exits with a clear
error **before any model is invoked**. The error is also raised mid-debate if
abstentions or per-reviewer timeouts drop the active reviewer count below 2 in
the final peer round; in that case the gate transitions to `awaiting_decision`
with `consensus.verdict = "requires_decision"` so a human resolves it.

Distinct exit codes the debate coordinator emits for its named failure paths
(in addition to the existing `wait --json` codes 0–4):

| Code | Meaning |
|------|---------|
| `5` | Aggregator failure raised by the coordinator's aggregator-fail helper (e.g., malformed reviewer JSON survived repair). `reviews/` left empty; the coordinator does not transition the status, so `gate-state.json.status` stays at the `"pending"` value the spawn wrote on entry, and re-spawn under `REVIEW_GATE_RERUN=1` recovers. |
| `6` (preflight) | Fewer than 2 reviewers available before any model invocation. The coordinator has not yet touched `gate-state.json`, so no active gate is created; recovery is to re-invoke with `--agents` covering ≥2 available reviewers (or install the missing CLIs). `bin/review-gate resolve` does not apply because no gate was created. |
| `6` (mid-debate) | Active reviewer count dropped below 2 during the run (abstentions / per-reviewer timeouts). The coordinator's degraded helper writes `gate-state.json.status="awaiting_decision"` with `consensus.verdict="requires_decision"` before exiting; resolve via `bin/review-gate resolve` or re-spawn under `REVIEW_GATE_RERUN=1`. |
| `130` | SIGINT / Ctrl-C cancellation during a debate run. The coordinator's SIGINT handler defers exit so the in-flight round runs to completion (or hits per-reviewer timeout) before partial telemetry is written; `reviews/` is left empty and the coordinator does not transition status, so `gate-state.json.status` stays at the `"pending"` value the spawn wrote on entry. |

The four codes above are the canonical exits from the named coordinator
helpers (`_rdc_aggregator_fail_exit`, `_rdc_pre_round_degraded_exit`,
`_rdc_degraded_exit`, `_rdc_cancel_exit`). If the coordinator instead returns
a non-zero status from its own argument-validation paths (rather than calling
one of those exit helpers), `bin/review-gate` falls back to exit code `1`,
calls a defensive `_debate_mark_state_failed` helper that transitions
`gate-state.json.status` to `"resolved"` with `consensus.verdict="ERROR"` and
`decision.action="manual_resolve"`, and prints the recovery hint.
`bin/review-gate resolve` is idempotent on a `"resolved"` state, and the
active-gate guard treats `"resolved"` as not-active so a fresh re-spawn does
not require `REVIEW_GATE_RERUN=1`.

### Bare-spawn Whitelist

`bin/review-gate spawn --debate` is only accepted when `--type` is one of
`code`, `plan`, `spec`, `epic-verify`, or `ask`. Any other `--type` (for
example `healthcheck`, `architecture-review`) is rejected at preflight before
any model is invoked. The named review subcommands and `spawn-ask` set a
supported type automatically.

### Byte-parity Guarantee

Every existing CI invocation that does NOT pass `--debate` is byte-for-byte
identical to the prior plugin version, modulo `--help`, `--version`, and error
messages for newly-rejected flag combinations. Reviewer prompts, persisted
schemas, gate report markdown, and `gate-state.json` keys present before this
release are preserved verbatim on the non-debate path.

### Rollback

To roll back debate mode:

1. Drop `--debate` from the affected invocations, OR
2. Revert the plugin to the prior version.

There is **no env-var kill switch.** Debate is opt-in, scoped per invocation,
and cannot be globally disabled by setting an environment variable.

## How It Works

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────────┐
│ Command invoked │────▶│  Spawn reviewers │────▶│  Codex + Gemini +   │
│ /review-code    │     │  in parallel     │     │  Claude evaluate    │
└─────────────────┘     └──────────────────┘     └─────────────────────┘
                                                          │
                                                          ▼
                               ┌──────────────────────────────────────┐
                               │       Consensus reached?             │
                               └──────────────────────────────────────┘
                                        │                    │
                                       YES                   NO
                                        │                    │
                                        ▼                    ▼
                        ┌───────────────────┐    ┌────────────────────┐
                        │   Auto-approve    │    │ Request revision   │
                        │   Session stops   │    │ (loop default 3x)  │
                        └───────────────────┘    └────────────────────┘
```

1. **Spawn**: Command triggers reviewer spawning
2. **Evaluate**: All reviewers analyze in parallel
3. **Consensus**: Stop hook checks if consensus threshold is met (default: majority)
4. **Iterate**: If consensus not reached or blocking issues found (FAIL/P0/P1), presents issues and blocks for revision
5. **Repeat**: After changes, review automatically re-runs (unless `--max-rounds 0`)
6. **Complete**: Consensus reached = session can stop; default 3 iterations = manual decision (configurable via `--max-rounds`, 0 disables auto-respawn)

## Review Criteria

### Code Review

- **Correctness** - Does the code do what it intends?
- **Security** - Injection, auth bypass, data exposure?
- **Error Handling** - Edge cases covered?
- **Performance** - Obvious inefficiencies?
- **Breaking Changes** - API compatibility?

### Plan Review

- **Template & Structure** - Follows standard plan template with all required sections?
- **Completeness** - Covers migrations, config, monitoring, docs?
- **Correctness** - Technically sound and grounded in the codebase?
- **Order of Operations** - Dependencies sequenced correctly (prerequisites first)?
- **Edge Cases & Risk** - Error paths, fallbacks, and failure modes addressed?
- **Breaking Changes & Compatibility** - Compatibility risks identified with clear strategies?
- **Testability & Verification** - Per-task verification steps and overall testing strategy?
- **Scope** - Appropriately scoped (MVP vs follow-ups, clear non-goals)?

### Spec Review

- **Clarity of Goals** - Is it clear what problem this solves?
- **Scope Definition** - Are boundaries explicit?
- **Technical Feasibility** - Are proposed components realistic?
- **Actionability** - Could a developer implement without clarification?
- **Edge Cases** - Are error paths addressed?

**Convergence policy for specs:** reviewers are instructed to PASS when there are no P0/P1 issues, even if they list P2/P3 suggestions. This keeps spec reviews focused on blocking gaps rather than endless detail expansion. If you want stricter behavior, increase reviewer count or lower `--max-rounds` and use manual override.

**Default max rounds:** 3 for all review types (overridable via `--max-rounds` or `REVIEW_GATE_MAX_ROUNDS`; set to `0` to disable auto-respawn).

**Author context example (recommended for spec reviews):**

```
${CLAUDE_PLUGIN_ROOT}/bin/review-gate author-context "Resolved: output format, CLI arg limits. Scope: MVP only. Only flag new/unresolved P0/P1 issues; list P2/P3 as suggestions."
```

Clear it when you're done:

```
${CLAUDE_PLUGIN_ROOT}/bin/review-gate author-context --clear
```

For external integrations, you can inject context directly:

```bash
REVIEW_GATE_AUTHOR_CONTEXT="Issue: align schema names with API v2." \
  ${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn path/to/artifact.md

${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn --context-file path/to/issue.txt path/to/artifact.md
```

## Manual Override

When max iterations are reached, the gate auto-resolves to proceed and surfaces any remaining P0/P1 issues in the stop prompt. Use manual resolution if you need to resolve the gate early:

```
/cerberus:clear-gate                     # Clear the gate via slash command
```

Or via CLI:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate resolve --reason "manual clear"
```

## External Orchestration

Machine-readable wait for external callers:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate wait --json --session-key <key> [--timeout 600] [--poll-interval 3]
```

Exit codes:

| Code | Meaning |
|------|---------|
| `0` | PASS - consensus achieved, no issues |
| `1` | FAIL/NEEDS_WORK - review found issues |
| `2` | Error - parse failures, missing deps, invalid args |
| `3` | Timeout - polling exceeded `--timeout` |
| `4` | No reviewers - no review sessions exist |

## Configuration

### Hooks

Cerberus ships both hooks in `hooks/hooks.json`:

- **SessionStart**: captures `session_id` and `transcript_path` into `CLAUDE_ENV_FILE` for `CLAUDE_SESSION_ID`/`CLAUDE_TRANSCRIPT_PATH`
- **Stop**: runs the review gate check to enforce consensus before stopping

### Environment Variables

Review defaults (precedence: CLI flag > env var > hardcoded default):

| Variable | Default | Description |
|----------|---------|-------------|
| `REVIEW_GATE_MAX_ROUNDS` | `3` | Max review iterations before auto-resolve |
| `REVIEW_GATE_MAX_WAIT_SECONDS` | `1800` | Max time to wait for reviewers |
| `REVIEW_GATE_POLL_INTERVAL_SECONDS` | `3` | Polling interval |

Other environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `REVIEW_GATE_AUTHOR_CONTEXT` | `` | Inject author context into prompts |
| `REVIEW_REPAIR_ENABLED` | `true` | Attempt JSON repair on reviewer parse failures |
| `REVIEW_REPAIR_PROVIDER` | auto | Repair model provider (`claude`, `codex`, or `gemini`). `auto`/unset picks the first available (prefers Claude). |
| `REVIEW_REPAIR_MODEL` | `haiku` | Repair model name (provider-specific). Defaults are low-cost and do not vary with `--mode`. |
| `GEMINI_READONLY_POLICY_PATH` | `config/gemini-readonly-policy.toml` | Gemini CLI Policy Engine rules used to keep Gemini reviewers read-only. |

Model override variables (override the mode-based defaults):

| Variable | Description |
|----------|-------------|
| `CODEX_MODEL_OVERRIDE` | Override Codex model (default: `gpt-5.5`) |
| `GEMINI_MODEL_OVERRIDE` | Override Gemini model (e.g., `gemini-3.1-pro-preview`) |
| `CLAUDE_MODEL_OVERRIDE` | Override Claude model (e.g., `sonnet`) |
| `CODEX_REASONING_EFFORT_OVERRIDE` | Override Codex reasoning effort (`medium`/`high`/`xhigh`) |

## Releasing

### Debate Mode Manual Smoke Checks

Before flagging the [Debate Mode](#debate-mode) feature for general use, the
maintainer runs the following manual smoke checks. None of these are automated;
they're judgment calls on real artifacts.

1. **Gemini read-only policy under debate prompts.** Run `--debate` with the
   Gemini reviewer included against a normal artifact. Confirm the Gemini CLI
   Policy Engine (`config/gemini-readonly-policy.toml`) still blocks any write
   tool — debate prompts inject anonymized peer broadcasts, and the smoke check
   verifies that peer text cannot be used as a jailbreak surface to escape
   read-only mode.
2. **Confidence calibration.** Spot-check `overall_confidence` and
   `findings[*].confidence` in per-reviewer JSONs across a few real runs.
   Anchors should be visibly influencing reviewer behavior — values should NOT
   look like all-0.9 or all-0.5. A finding the reviewer cannot evidence should
   sit lower than one it can.
3. **Token + wall-clock cost band per mode.** Run `--debate` against the same
   artifact under each of `--mode fast`, `--mode smart`, and `--mode max`.
   Confirm token cost and wall-clock latency land roughly within the bands
   documented in [Cost & Latency](#cost--latency) (~2× for fast/smart, ~3× for
   max; the 1.5×–3.5× band is fine).
4. **Vibes review on at least 3 real artifacts.** Compare debate vs non-debate
   gate reports side by side on at least three real artifacts the maintainer
   has independent judgment on. Debate output should look at least as good as
   non-debate; if it looks worse on aggregate, hold the release and
   investigate.

If any of the four checks fails, do not flag the feature for general use.
Roll back via the documented [Rollback](#rollback) path.

## License

MIT
