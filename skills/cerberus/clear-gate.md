---
name: clear-gate
description: Manually clear the active Cerberus review gate. Operator escape hatch.
---

# Cerberus — Clear Gate (Codex skill)

Resolve the active review gate so the session can stop without completing
the review cycle. Use this when reviewers are stuck, when you have decided
to land a change despite blocking findings, or when an iteration loop has
exhausted retries and needs a manual override.

This skill is the Codex-host wrapper around
`bin/review-gate resolve --reason "manual clear from Codex"`. It sets
`CERBERUS_HOST=codex` so the backend records the host on the resolution.

> **Operator action.** This is a deliberate override. The reason string
> identifies the host that issued the manual clear so audit trails and
> `gate-state.json` history make the source of the resolution
> unambiguous.

## Usage

```
clear-gate
```

The skill takes no arguments. The active run is resolved from the session
registry written by `bin/codex-session-init` during `SessionStart`. If you
want to clear a specific (non-active) run, pass `--session-key` to
`bin/review-gate resolve` directly.

## Run

```bash
export CERBERUS_HOST=codex
"${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-.}}/bin/review-gate" resolve \
    --reason "manual clear from Codex"
```
