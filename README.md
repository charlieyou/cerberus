# Cerberus

*Three-headed guardian of code quality.*

Multi-model consensus review system that gates Claude Code session termination until code or plans are reviewed and approved. Like its mythological namesake, Cerberus uses three AI heads (Codex, Gemini, Claude) to guard the gates—nothing leaves until all three agree.

## Features

- **Multi-model review**: Codex, Gemini, and Claude evaluate changes in parallel
- **Automatic iteration**: Reviews loop until unanimous approval (up to 5 rounds)
- **Code review**: Review git diffs (uncommitted, branch comparisons, commits, ranges)
- **Plan review**: Review implementation plans before execution
- **Spec review**: Review feature specifications before implementation

## Installation

### Prerequisites

You need the following CLI tools installed:

| Tool | Purpose | Install |
|------|---------|---------|
| `codex` | OpenAI Codex reviewer | [OpenAI CLI](https://platform.openai.com/docs/guides/command-line) |
| `gemini` | Google Gemini reviewer | [Gemini CLI](https://ai.google.dev/gemini-api/docs/get-started/cli) |
| `jq` | JSON processing | `apt install jq` / `brew install jq` |

Missing reviewers are skipped with a warning—you can run with just one or two.

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
/cerberus:review-code --commit abc123    # Review a specific commit
/cerberus:review-code main..feature      # Review a commit range
/cerberus:review-code --agents codex,gemini  # Only run selected reviewers
```

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

### Agent Selection

All review commands accept `--agents <list>` to run a subset of the available reviewers. Provide a comma-separated list such as `codex,gemini` or `claude`.

## How It Works

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────────┐
│ Command invoked │────▶│  Spawn reviewers │────▶│  Codex + Gemini +   │
│ /review-code    │     │  in parallel     │     │  Claude evaluate    │
└─────────────────┘     └──────────────────┘     └─────────────────────┘
                                                          │
                                                          ▼
                               ┌──────────────────────────────────────┐
                               │         All reviewers PASS?          │
                               └──────────────────────────────────────┘
                                        │                    │
                                       YES                   NO
                                        │                    │
                                        ▼                    ▼
                        ┌───────────────────┐    ┌────────────────────┐
                        │   Auto-approve    │    │ Request revision   │
                        │   Session stops   │    │ (loop up to 5x)    │
                        └───────────────────┘    └────────────────────┘
```

1. **Spawn**: Command triggers reviewer spawning
2. **Evaluate**: All reviewers analyze in parallel
3. **Consensus**: Stop hook checks for unanimous PASS
4. **Iterate**: If not all PASS, presents issues and blocks for revision
5. **Repeat**: After changes, review automatically re-runs
6. **Complete**: All PASS = session can stop; 5 iterations = manual decision

## Review Criteria

### Code Review

- **Correctness** - Does the code do what it intends?
- **Security** - Injection, auth bypass, data exposure?
- **Error Handling** - Edge cases covered?
- **Performance** - Obvious inefficiencies?
- **Breaking Changes** - API compatibility?

### Plan Review

- **Completeness** - All necessary changes covered?
- **Correctness** - Technically sound approach?
- **Order of Operations** - Dependencies sequenced correctly?
- **Edge Cases** - Error paths addressed?
- **Testability** - Can it be verified?

### Spec Review

- **Clarity of Goals** - Is it clear what problem this solves?
- **Scope Definition** - Are boundaries explicit?
- **Technical Feasibility** - Are proposed components realistic?
- **Actionability** - Could a developer implement without clarification?
- **Edge Cases** - Are error paths addressed?

## Manual Override

After max iterations (5), use manual resolution:

```bash
# Accept the current state and proceed
${CLAUDE_PLUGIN_ROOT}/bin/review-gate resolve proceed

# Abort and discard
${CLAUDE_PLUGIN_ROOT}/bin/review-gate resolve abort
```

## Configuration

### Hooks

Cerberus ships both hooks in `hooks/hooks.json`:

- **SessionStart**: captures `session_id` and `transcript_path` into `CLAUDE_ENV_FILE` for `CLAUDE_SESSION_ID`/`CLAUDE_TRANSCRIPT_PATH`
- **Stop**: runs the review gate check to enforce consensus before stopping

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CODEX_MODEL` | `gpt-5.2-codex` | Model for Codex reviewer |
| `GEMINI_MODEL` | `gemini-3-flash-preview` | Model for Gemini reviewer |
| `CLAUDE_MODEL` | `opus` | Model for Claude reviewer |
| `REVIEW_GATE_MAX_WAIT_SECONDS` | `600` | Max time to wait for reviewers |
| `REVIEW_GATE_POLL_INTERVAL_SECONDS` | `3` | Polling interval |

## License

MIT
