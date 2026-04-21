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

Verified CLI versions (January 1, 2026):

| Tool | Version |
|------|---------|
| `codex` | `codex-cli 0.77.0` |
| `gemini` | `0.22.4` |
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
| `REVIEW_GATE_MAX_WAIT_SECONDS` | `600` | Max time to wait for reviewers |
| `REVIEW_GATE_POLL_INTERVAL_SECONDS` | `3` | Polling interval |

Other environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `REVIEW_GATE_AUTHOR_CONTEXT` | `` | Inject author context into prompts |
| `REVIEW_REPAIR_ENABLED` | `true` | Attempt JSON repair on reviewer parse failures |
| `REVIEW_REPAIR_PROVIDER` | auto | Repair model provider (`claude`, `codex`, or `gemini`). `auto`/unset picks the first available (prefers Claude). |
| `REVIEW_REPAIR_MODEL` | `haiku` | Repair model name (provider-specific). Defaults are low-cost and do not vary with `--mode`. |

Model override variables (override the mode-based defaults):

| Variable | Description |
|----------|-------------|
| `CODEX_MODEL_OVERRIDE` | Override Codex model (default: `gpt-5.4`) |
| `GEMINI_MODEL_OVERRIDE` | Override Gemini model (e.g., `gemini-3.1-pro-preview`) |
| `CLAUDE_MODEL_OVERRIDE` | Override Claude model (e.g., `sonnet`) |
| `CODEX_REASONING_EFFORT_OVERRIDE` | Override Codex reasoning effort (`medium`/`high`/`xhigh`) |

## License

MIT
