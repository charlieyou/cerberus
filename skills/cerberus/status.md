---
name: status
description: Show current Cerberus review-gate status as JSON (read-only; never mutates state).
---

# Cerberus — Status (Codex skill)

Print the current review-gate status for the active run as a single JSON
document on stdout. The skill never mutates gate state — `status --json`
is the read-only contract verified by `bin/tests/test-status-command.sh`.

This skill is the Codex-host wrapper around `bin/review-gate status --json`.
It sets `CERBERUS_HOST=codex` so the backend resolves state under the
Codex runtime tree.

## Usage

```
status
```

The skill takes no arguments. The active run key is resolved from the
session registry written by `bin/codex-session-init` during `SessionStart`.
If you want to inspect a specific (non-active) run, pass `--session-key`
to `bin/review-gate status --json` directly.

## Run

```bash
export CERBERUS_HOST=codex
"${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-.}}/bin/review-gate" status --json
```

## Output

`status --json` emits a single JSON object on stdout. The shape varies by
gate state, but the top-level keys you can rely on are:

- `status` — one of `no_active_gate`, `pending`, `passed`, `failed`,
  `cleared`, `error`, `unknown` (failure-open).
- `host` — the host that owns the run (`claude`, `codex`, `amp`, …).
- `run_key` — the run key resolved by `__cerberus_resolve_run_key`.
- Additional shape per state: `reviewers`, `findings`, `verdict`,
  `iteration`, `last_emit`, etc., depending on the gate's progress.

Exit codes:

- `0` — gate found, body emitted.
- `4` — no active gate (body: `{"status":"no_active_gate"}`).
- non-zero / non-4 — backend failure; body is `{"status":"unknown",...}`.

The skill always emits valid JSON on stdout; consumers should parse the
JSON rather than rely on the exit code alone.
