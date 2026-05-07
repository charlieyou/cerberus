---
name: status
description: Show current Cerberus review-gate status as JSON (read-only; never mutates state).
disable-model-invocation: true
---

## Host-Neutral Execution

Before running any Bash snippet in this skill, source the shared Cerberus skill environment helper. This keeps the same skill usable from Claude, Codex, or a generic shell by resolving `CERBERUS_ROOT`, `CERBERUS_HOST`, and the active run key when the host exposes one.

```bash
cerberus_root=""
cerberus_plugin_root='${CLAUDE_PLUGIN_ROOT}'
case "$cerberus_plugin_root" in
    '$'{CLAUDE_PLUGIN_ROOT}) cerberus_plugin_root="${CLAUDE_PLUGIN_ROOT:-}" ;;
esac
cerberus_skill_dir='${CLAUDE_SKILL_DIR}'
case "$cerberus_skill_dir" in
    '$'{CLAUDE_SKILL_DIR}) cerberus_skill_dir="${CLAUDE_SKILL_DIR:-}" ;;
esac

cerberus_candidates=("${CERBERUS_ROOT:-}" "$cerberus_plugin_root")
if [ -n "$cerberus_skill_dir" ]; then
    cerberus_candidates+=("$(cd -P "$cerberus_skill_dir/../.." 2>/dev/null && pwd || true)")
fi
cerberus_git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$cerberus_git_root" ]; then
    cerberus_candidates+=("$cerberus_git_root")
fi
for cerberus_candidate in "${cerberus_candidates[@]}"; do
    if [ -n "$cerberus_candidate" ] \
        && [[ "$cerberus_candidate" == /* ]] \
        && [ -r "$cerberus_candidate/bin/cerberus-skill-env" ] \
        && [ -x "$cerberus_candidate/bin/review-gate" ] \
        && [ -r "$cerberus_candidate/bin/review-gate-models.sh" ] \
        && [ -r "$cerberus_candidate/config/gemini-readonly-settings.json" ] \
        && [ -r "$cerberus_candidate/config/gemini-readonly-policy.toml" ]; then
        cerberus_root="$cerberus_candidate"
        break
    fi
done
if [ -z "$cerberus_root" ]; then
    echo "cerberus skill: cannot find Cerberus backend; set CERBERUS_ROOT to the checkout root" >&2
    exit 127
fi
export CERBERUS_ROOT="$cerberus_root"
# shellcheck source=/dev/null
. "$cerberus_root/bin/cerberus-skill-env" || exit $?
```

Use `${CERBERUS_ROOT}` when invoking Cerberus binaries below.


# Cerberus — Status

Print the current review-gate status for the active run as a single JSON document on stdout. The skill never mutates gate state; `status --json` is the read-only contract verified by `bin/tests/test-status-command.sh`.

## Usage

```text
/cerberus:status
```

The active run key is resolved by the shared backend from the current host environment. To inspect a specific non-active run, pass `--session-key` to `bin/review-gate status --json` directly.

## Run

Use the Bash tool to run the backend status command:

```bash
cerberus_root=""
cerberus_plugin_root='${CLAUDE_PLUGIN_ROOT}'
case "$cerberus_plugin_root" in
    '$'{CLAUDE_PLUGIN_ROOT}) cerberus_plugin_root="${CLAUDE_PLUGIN_ROOT:-}" ;;
esac
cerberus_skill_dir='${CLAUDE_SKILL_DIR}'
case "$cerberus_skill_dir" in
    '$'{CLAUDE_SKILL_DIR}) cerberus_skill_dir="${CLAUDE_SKILL_DIR:-}" ;;
esac

cerberus_candidates=("${CERBERUS_ROOT:-}" "$cerberus_plugin_root")
if [ -n "$cerberus_skill_dir" ]; then
    cerberus_candidates+=("$(cd -P "$cerberus_skill_dir/../.." 2>/dev/null && pwd || true)")
fi
cerberus_git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$cerberus_git_root" ]; then
    cerberus_candidates+=("$cerberus_git_root")
fi
for cerberus_candidate in "${cerberus_candidates[@]}"; do
    if [ -n "$cerberus_candidate" ] \
        && [[ "$cerberus_candidate" == /* ]] \
        && [ -r "$cerberus_candidate/bin/cerberus-skill-env" ] \
        && [ -x "$cerberus_candidate/bin/review-gate" ] \
        && [ -r "$cerberus_candidate/bin/review-gate-models.sh" ] \
        && [ -r "$cerberus_candidate/config/gemini-readonly-settings.json" ] \
        && [ -r "$cerberus_candidate/config/gemini-readonly-policy.toml" ]; then
        cerberus_root="$cerberus_candidate"
        break
    fi
done
if [ -z "$cerberus_root" ]; then
    echo "status: cannot find Cerberus backend; set CERBERUS_ROOT to the checkout root" >&2
    exit 127
fi
export CERBERUS_ROOT="$cerberus_root"
# shellcheck source=/dev/null
. "$cerberus_root/bin/cerberus-skill-env" || exit $?
"$CERBERUS_ROOT/bin/review-gate" status --json $ARGUMENTS
```

## Output

`status --json` emits a single JSON object on stdout. Active gates use the canonical review-gate shape:

- `gate_status` — one of `pending`, `awaiting_decision`, `resolved`, or `unknown`.
- `consensus_verdict` — one of `pass`, `fail`, `needs_revision`, or JSON `null` while still pending.
- `host` — the host that owns the run (`claude`, `codex`, or `generic`).
- `run_key` — the run key resolved by `__cerberus_resolve_run_key`.
- `reviewers`, `pending_reviewers`, `aggregated_findings`, and `parse_errors` describe review progress and findings.

Special/error bodies use a smaller shape keyed by `status`, primarily `{"status":"no_active_gate"}` or `{"status":"unknown","error":"malformed_state"}`.

Exit codes:

- `0` — body emitted for an active gate or malformed-state failure-open path.
- `4` — no active gate (body: `{"status":"no_active_gate"}`).
- non-zero / non-4 — backend failure; body is valid JSON with an error payload.

Parse the JSON body rather than relying on the exit code alone.
