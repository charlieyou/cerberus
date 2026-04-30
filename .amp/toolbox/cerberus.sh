#!/usr/bin/env bash
# .amp/toolbox/cerberus.sh — Amp Toolbox adapter for Cerberus (T014).
#
# Plan reference: docs/2026-04-29-codex-amp-plugin-port-plan.md
#   §Phase 2 — Amp Port (L936-L965), §Amp command surface (L778-L800),
#   §Amp run-key durability (L156-L162), §Amp fallback session registry
#   schema (L483-L508), §Phase 2 exit criteria (L941-L963).
# Spike resolution: docs/AMP.md §"Phase 2 Spike Findings" (commit
#   bbb8fd8 — T012). T013 landed the skeleton on this exact path.
#
# DIVERGENCE FROM ORIGINAL TASK SPEC. The plan and the T013/T014 task
# contexts describe the Amp extension surface as a TypeScript plugin
# loaded from `.amp/plugins/cerberus.ts` and registered via
# `amp.registerCommand`. The T012 spike (docs/AMP.md) found that the
# Amp CLI build available to this team (0.0.1777572045-g97f3b8) does
# NOT expose a `.amp/plugins/` loader, an `amp.registerCommand` API, or
# named lifecycle events. Amp's actual user-extension surfaces in this
# build are (1) the Amp Toolbox (subprocess scripts driven by the
# TOOLBOX_ACTION env var; tool params on stdin as JSON; output on
# stdout) and (2) skills. T013 re-targeted the skeleton to the toolbox
# surface; T014 (this file) fills in the dispatch, env mapping, and
# run-key resolver. docs/AMP.md is the source of truth for the pivot;
# the plan's mapping decision-tree result ("Stable in commands but not
# lifecycle") still applies.
#
# Toolbox protocol (per docs/AMP.md §"Amp extension surfaces"):
#   - TOOLBOX_ACTION=describe → emit tool metadata to stdout (JSON);
#     the `commands` array lists the six Cerberus commands the tool
#     dispatches (review-code, review-plan, review-spec, ask-panel,
#     status, clear-gate).
#   - TOOLBOX_ACTION=execute → read tool params (JSON) from stdin;
#     dispatch on the `command` field. Other fields are command-
#     specific params (e.g. `plan_path`, `spec_path`, `question`,
#     `reason`).
#
# Run-key resolution (plan §156-162, §1029-1030; docs/AMP.md OQ-3
# resolution). Per the OQ-3 resolution, valid `AMP_THREAD_ID` is the
# primary run key; the persisted registry is the *fallback* for the
# missing/malformed-thread-id case, plus a continuity anchor for
# workspaces that started in UUID-fallback mode.
#
#   1. If `AMP_THREAD_ID` (or `AMP_CURRENT_THREAD_ID` as a documented
#      alias from the Amp bundle) is present and matches the expected
#      `T-<lower-hex-with-hyphens>` shape:
#      a. UUID-fallback continuity case: if the persisted registry
#         has `amp_thread_id == null` (i.e. an earlier invocation in
#         this workspace ran without AMP_THREAD_ID and generated a
#         fallback UUID), keep the persisted UUID as the run key so
#         the user's already-running review-gate state remains
#         addressable. Log a warning so the user knows a thread id is
#         available but is being ignored for continuity.
#      b. Otherwise (fresh workspace, or persisted record was
#         thread-bound): use `AMP_THREAD_ID` as the run key. A
#         different persisted `amp_thread_id` is treated as a normal
#         new Amp thread — the registry is overwritten with the new
#         binding. There is no "flip" detection across thread-bound
#         sessions, because we cannot distinguish a true mid-session
#         re-key from a legitimate new thread without lifecycle hooks
#         (which Amp 0.0.1777572045 does not expose; see docs/AMP.md).
#   2. If `AMP_THREAD_ID` is absent / empty / not in the expected
#      shape: read the persisted run_key from the registry. If absent,
#      generate a fresh UUID and atomic-write the registry with
#      `amp_thread_id=null` so future invocations recognize the
#      workspace as UUID-mode.
#
# The plugin/tool memory is cache only; the on-disk registry is
# authoritative (plan L948-L949).
#
# Env mapping (plan L789-L800):
#   CERBERUS_HOST=amp
#   CERBERUS_ROOT=<plugin root>          (dir containing bin/review-gate)
#   CERBERUS_STATE_ROOT=$HOME/.cerberus/projects   (neutral default)
#   CERBERUS_PROJECT_KEY=<workspace-key>
#   CERBERUS_RUN_KEY=<thread-id-or-fallback-uuid>
#   CLAUDE_PLUGIN_ROOT=<plugin root>      (transient compat alias)
#
# Six commands (plan §Amp command surface, L778-L800):
#
#   command       Backend call                                       Notes
#   ------------- -------------------------------------------------- ---------
#   review-code   bin/review-gate spawn-code-review                  CERBERUS_HOST=amp.
#   review-plan   bin/review-gate spawn-plan-review <plan-path>      Explicit path.
#   review-spec   bin/review-gate spawn-spec-review <spec-path>      Explicit path.
#   ask-panel     bin/review-gate spawn-ask + wait --json --finalize Synthesize.
#   status        bin/review-gate status --json                      Read-only.
#   clear-gate    bin/review-gate resolve --reason "manual …"        Manual clear.
#
# Lifecycle handlers (`session.start`, `agent.start`, `agent.end`) are
# explicitly out of v1 scope (plan L953-L955). docs/AMP.md confirms
# Amp 0.0.1777572045 does not expose those surfaces anyway.
#
# Test hooks (intentional, narrowly scoped — used by
# bin/tests/test-amp-shell-helper.sh; documented here so reviewers can
# audit the surface):
#   CERBERUS_AMP_WORKSPACE      Override workspace_root used to derive
#                               CERBERUS_PROJECT_KEY. Defaults to $PWD.
#   CERBERUS_REVIEW_GATE_BIN    Override the path to bin/review-gate
#                               (for stubbing in tests).
#   CERBERUS_AMP_TEST_PRE_MV_SLEEP
#                               Sleep this many seconds between tmp
#                               write and `mv` of the registry (used
#                               by atomic-write race-window tests; not
#                               currently exercised at T014 but kept
#                               consistent with codex-session-init).

set -euo pipefail

# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The plugin root is the directory containing bin/review-gate. With
# the toolbox layout `<root>/.amp/toolbox/cerberus.sh`, that is two
# levels up from this script.
CERBERUS_ROOT_DEFAULT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CERBERUS_ROOT_VAL="${CERBERUS_ROOT:-$CERBERUS_ROOT_DEFAULT}"
REVIEW_GATE_BIN="${CERBERUS_REVIEW_GATE_BIN:-$CERBERUS_ROOT_VAL/bin/review-gate}"

# Workspace root: Amp invokes toolbox tools from the user's workspace
# directory, but Amp may run the tool from any subdirectory of the
# workspace. To keep the workspace key stable across subdirectories
# we mirror bin/review-gate-lib.sh `get_project_hash` and prefer the
# git toplevel before falling back to PWD. Tests set
# CERBERUS_AMP_WORKSPACE to point at a stub workspace so the registry
# path is deterministic without needing a real git repo on the
# harness machine.
__amp_workspace_root() {
    if [ -n "${CERBERUS_AMP_WORKSPACE:-}" ]; then
        printf '%s' "$CERBERUS_AMP_WORKSPACE"
        return 0
    fi
    local toplevel
    toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$toplevel" ]; then
        printf '%s' "$toplevel"
        return 0
    fi
    printf '%s' "$PWD"
}
WORKSPACE_ROOT="$(__amp_workspace_root)"

# ---------------------------------------------------------------------------
# Project key — host-neutral path mangling. Mirrors
# bin/review-gate-lib.sh `get_project_hash` for the no-transcript /
# no-CERBERUS_PROJECT_KEY path. Inlined (not sourced) so a missing
# bin/ directory still surfaces a clean diagnostic from the helper
# rather than a sourcing failure.
#
# Precedence (matches get_project_hash for the no-transcript path):
#   1. CERBERUS_PROJECT_KEY (explicit override)
#   2. WORKSPACE_ROOT (git toplevel preferred via __amp_workspace_root,
#      then $PWD) → path-mangled with sed/tr.
# ---------------------------------------------------------------------------
__amp_project_key() {
    local ws="$1"
    if [ -n "${CERBERUS_PROJECT_KEY:-}" ]; then
        printf '%s' "$CERBERUS_PROJECT_KEY"
        return 0
    fi
    printf '%s' "$ws" | sed 's|^/|-|' | tr '/' '-'
}

PROJECT_KEY="$(__amp_project_key "$WORKSPACE_ROOT")"

# Validate project_key (matches resolve_review_dir's surface).
case "$PROJECT_KEY" in
    ""|.|..)
        echo "cerberus.sh: invalid project_key '$PROJECT_KEY' (empty, '.', or '..')" >&2
        exit 2
        ;;
    */*)
        echo "cerberus.sh: invalid project_key '$PROJECT_KEY' (must not contain '/')" >&2
        exit 2
        ;;
esac

REGISTRY_DIR="$HOME/.cerberus/runtime/amp/$PROJECT_KEY"
REGISTRY_FILE="$REGISTRY_DIR/active-session.json"

# ---------------------------------------------------------------------------
# AMP_THREAD_ID validation. Format per docs/AMP.md: `T-<uuid7>` with
# lower-case hex segments separated by hyphens (example:
# T-019de015-d2d1-70dc-ac7c-bf5ccc46dd68). The regex accepts any
# `T-` prefix followed by 1+ lower-hex-segments; that matches the
# observed Amp output and rejects empty/invalid forms.
# ---------------------------------------------------------------------------
__amp_thread_id_valid() {
    local val="$1"
    [[ "$val" =~ ^T-[a-f0-9]+(-[a-f0-9]+)*$ ]]
}

# ---------------------------------------------------------------------------
# Generate a fresh UUID (lowercase, hyphenated). uuidgen is universal
# on macOS and most Linux distros. /proc fallback covers Linux without
# uuidgen. The final fallback is a best-effort PID + epoch-seconds +
# RANDOM blob — not a real UUID but unique enough for a
# workspace-scoped registry that's only consulted for run-key
# continuity within the same workspace.
#
# Portability note (intentionally avoided): macOS `date` does not
# support `%N` for nanoseconds and would emit the literal string
# `%N` if used unguarded. We use bash's $RANDOM (0-32767, two draws
# = ~30 bits of entropy) instead so the suffix is well-formed on
# both Darwin and Linux without uuidgen.
# ---------------------------------------------------------------------------
__amp_gen_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
        return 0
    fi
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
        return 0
    fi
    printf 'amp-fallback-%s-%s-%s%s' "$$" "$(date +%s)" "$RANDOM" "$RANDOM"
}

# ---------------------------------------------------------------------------
# Atomic registry write. Same idiom as bin/codex-session-init (T008):
# tmp file with PID suffix → jq validate → mv. mv is POSIX-atomic on
# the same filesystem. No EXIT trap removes the tmp; if the writer is
# killed mid-write the orphan tmp remains and active-session.json is
# either absent or contains the previous valid content.
#
# Args: $1 run_key  $2 amp_thread_id (empty string → null in JSON)
# ---------------------------------------------------------------------------
__amp_write_registry() {
    local run_key="$1"
    local thread_id="${2:-}"
    mkdir -p "$REGISTRY_DIR"
    local last_seen
    last_seen="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    local tmp="$REGISTRY_FILE.tmp.$$"
    if ! jq -n \
        --argjson schema_version 1 \
        --arg host "amp" \
        --arg workspace_root "$WORKSPACE_ROOT" \
        --arg project_key "$PROJECT_KEY" \
        --arg run_key "$run_key" \
        --arg amp_thread_id "$thread_id" \
        --arg last_seen "$last_seen" \
        '{
            schema_version: $schema_version,
            host: $host,
            workspace_root: $workspace_root,
            project_key: $project_key,
            run_key: $run_key,
            amp_thread_id: (if $amp_thread_id == "" then null else $amp_thread_id end),
            last_seen: $last_seen
        }' > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    if ! jq empty "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        return 1
    fi
    if [ -n "${CERBERUS_AMP_TEST_PRE_MV_SLEEP:-}" ]; then
        sleep "$CERBERUS_AMP_TEST_PRE_MV_SLEEP"
    fi
    mv "$tmp" "$REGISTRY_FILE"
}

# ---------------------------------------------------------------------------
# Resolve the effective run key. See file header §"Run-key resolution"
# for the full algorithm. Side effect: writes/refreshes the persisted
# registry on every invocation so `last_seen` advances and the
# registry stays in sync with the resolved run_key.
#
# Returns the resolved run_key on stdout.
# ---------------------------------------------------------------------------
__amp_resolve_run_key() {
    local thread_id="${AMP_THREAD_ID:-${AMP_CURRENT_THREAD_ID:-}}"

    local persisted_run_key=""
    local persisted_thread_id=""
    local has_persisted=0
    if [ -f "$REGISTRY_FILE" ] && jq empty "$REGISTRY_FILE" >/dev/null 2>&1; then
        persisted_run_key="$(jq -r '.run_key // ""' "$REGISTRY_FILE" 2>/dev/null || true)"
        persisted_thread_id="$(jq -r '.amp_thread_id // ""' "$REGISTRY_FILE" 2>/dev/null || true)"
        if [ -n "$persisted_run_key" ]; then
            has_persisted=1
        fi
    fi

    if [ -n "$thread_id" ] && __amp_thread_id_valid "$thread_id"; then
        # UUID-fallback continuity case (the actual "flip" the plan
        # cares about): a previous invocation in this workspace ran
        # without AMP_THREAD_ID and persisted a fallback UUID
        # (`amp_thread_id` recorded as null). Now Amp is providing a
        # thread id. Keep the persisted UUID as the run_key so the
        # user's already-running review-gate state remains addressable.
        # We deliberately keep amp_thread_id=null in the registry so
        # this workspace stays in "UUID-mode" — every subsequent
        # invocation reuses the same UUID until the user explicitly
        # overrides via CERBERUS_RUN_KEY or `review-gate ... --run-key`.
        # Warn so the user knows a thread id is available but ignored.
        if [ "$has_persisted" -eq 1 ] && [ -z "$persisted_thread_id" ]; then
            echo "cerberus.sh: WARNING: AMP_THREAD_ID '$thread_id' is now available, but a fallback-UUID run_key '$persisted_run_key' is already persisted for this workspace; reusing UUID for continuity. Override via CERBERUS_RUN_KEY to switch to the thread id." >&2
            __amp_write_registry "$persisted_run_key" ""
            printf '%s' "$persisted_run_key"
            return 0
        fi

        # Default: per OQ-3 resolution, valid AMP_THREAD_ID is the
        # primary run key. This includes the case where a previous
        # run in the same workspace was bound to a *different* thread
        # id — that's a normal new Amp thread, not a flip; we
        # overwrite the registry binding with the new thread.
        # (Plan §Amp run-key durability L156-162; docs/AMP.md OQ-3.)
        __amp_write_registry "$thread_id" "$thread_id"
        printf '%s' "$thread_id"
        return 0
    fi

    # AMP_THREAD_ID absent / invalid. Read persisted run_key if
    # present — this preserves UUID continuity across invocations,
    # and also keeps a thread-bound run_key addressable if Amp
    # transiently fails to set AMP_THREAD_ID for a single invocation.
    if [ "$has_persisted" -eq 1 ]; then
        __amp_write_registry "$persisted_run_key" "$persisted_thread_id"
        printf '%s' "$persisted_run_key"
        return 0
    fi

    # Fresh workspace, no thread id, no persisted state: generate UUID
    # fallback and persist with amp_thread_id=null so future
    # invocations recognize the workspace as UUID-mode.
    local new_uuid
    new_uuid="$(__amp_gen_uuid)"
    __amp_write_registry "$new_uuid" ""
    printf '%s' "$new_uuid"
}

# ---------------------------------------------------------------------------
# Six Cerberus commands surfaced through this Amp Toolbox tool. Order
# matches the plan §Amp command surface table (L780-L787); tests
# assert ordered equality so plan parity is a hard contract.
# ---------------------------------------------------------------------------
COMMANDS=(
    "review-code"
    "review-plan"
    "review-spec"
    "ask-panel"
    "status"
    "clear-gate"
)

__amp_command_known() {
    local needle="$1"
    local c
    for c in "${COMMANDS[@]}"; do
        if [ "$c" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Dispatch a command to bin/review-gate. Each branch maps to the row
# in the §Amp command surface table. Per-command params are read from
# the stdin JSON body (already validated to be parseable JSON).
#
# The exit code from bin/review-gate is propagated verbatim so a
# missing reviewer CLI / panel error surfaces cleanly to Amp.
# ---------------------------------------------------------------------------
__amp_dispatch() {
    local cmd="$1"
    local params_json="$2"
    case "$cmd" in
        review-code)
            "$REVIEW_GATE_BIN" spawn-code-review
            ;;
        review-plan)
            local plan_path
            plan_path="$(printf '%s' "$params_json" | jq -r '.plan_path // ""' 2>/dev/null || true)"
            if [ -z "$plan_path" ]; then
                echo "cerberus.sh: review-plan requires .plan_path in tool params" >&2
                return 2
            fi
            "$REVIEW_GATE_BIN" spawn-plan-review "$plan_path"
            ;;
        review-spec)
            local spec_path
            spec_path="$(printf '%s' "$params_json" | jq -r '.spec_path // ""' 2>/dev/null || true)"
            if [ -z "$spec_path" ]; then
                echo "cerberus.sh: review-spec requires .spec_path in tool params" >&2
                return 2
            fi
            "$REVIEW_GATE_BIN" spawn-spec-review "$spec_path"
            ;;
        ask-panel)
            local question
            question="$(printf '%s' "$params_json" | jq -r '.question // ""' 2>/dev/null || true)"
            if [ -z "$question" ]; then
                echo "cerberus.sh: ask-panel requires .question in tool params" >&2
                return 2
            fi
            # Spawn-ask kicks the panel; wait --json --finalize
            # synthesizes the answer (plan §Amp command surface row).
            "$REVIEW_GATE_BIN" spawn-ask "$question" \
                && "$REVIEW_GATE_BIN" wait --json --finalize
            ;;
        status)
            "$REVIEW_GATE_BIN" status --json
            ;;
        clear-gate)
            local reason
            reason="$(printf '%s' "$params_json" | jq -r '.reason // ""' 2>/dev/null || true)"
            if [ -z "$reason" ]; then
                reason="manual clear via Amp toolbox"
            fi
            "$REVIEW_GATE_BIN" resolve --reason "$reason"
            ;;
        *)
            # Should be unreachable — caller already validated against
            # COMMANDS — but guard for defense in depth.
            echo "cerberus.sh: unknown command '$cmd' (internal: dispatch fell through validation)" >&2
            return 2
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Toolbox entry-point switch.
# ---------------------------------------------------------------------------
ACTION="${TOOLBOX_ACTION:-}"

case "$ACTION" in
    describe)
        # Emit a JSON describe payload listing the six commands. Amp's
        # describe schema accepts arbitrary keys; the `commands` array
        # is the canonical enumeration consumers (Amp + tests) read.
        if command -v jq >/dev/null 2>&1; then
            printf '%s\n' "${COMMANDS[@]}" | jq -R . | jq -s \
                --arg name "cerberus" \
                --arg description "Cerberus multi-model review gate. Dispatches six review commands: review-code, review-plan, review-spec, ask-panel, status, clear-gate." \
                --arg version "0.0.0-T014" \
                --arg task "T014" \
                '{
                    name: $name,
                    description: $description,
                    version: $version,
                    task: $task,
                    status: "active",
                    commands: .
                }'
        else
            # Defensive fallback: the verification gate requires jq, so
            # this branch is only hit on minimal hosts.
            printf '{"name":"cerberus","description":"Cerberus multi-model review gate.","version":"0.0.0-T014","task":"T014","status":"active","commands":["review-code","review-plan","review-spec","ask-panel","status","clear-gate"]}\n'
        fi
        exit 0
        ;;
    execute)
        # Drain stdin so upstream callers blocking on the write side
        # don't EPIPE.
        _stdin_body=""
        if [ ! -t 0 ]; then
            _stdin_body=$(cat || true)
        fi

        if [ -z "$_stdin_body" ]; then
            echo "cerberus.sh: execute requires JSON tool params on stdin" >&2
            exit 2
        fi

        if ! printf '%s' "$_stdin_body" | jq -e . >/dev/null 2>&1; then
            echo "cerberus.sh: execute params on stdin are not valid JSON" >&2
            exit 2
        fi

        REQUESTED="$(printf '%s' "$_stdin_body" | jq -r '.command // ""' 2>/dev/null || true)"
        if [ -z "$REQUESTED" ]; then
            echo "cerberus.sh: execute params missing required field 'command'" >&2
            exit 2
        fi

        if ! __amp_command_known "$REQUESTED"; then
            echo "cerberus.sh: unknown command '$REQUESTED' (expected one of: ${COMMANDS[*]})" >&2
            exit 2
        fi

        # Verify the backend exists. This produces the clear diagnostic
        # demanded by the missing-backend negative case (plan exit
        # criterion: helper must surface a clean error rather than a
        # mysterious shell failure).
        if [ ! -x "$REVIEW_GATE_BIN" ]; then
            echo "cerberus.sh: backend not found or not executable: $REVIEW_GATE_BIN" >&2
            echo "cerberus.sh: ensure Cerberus is installed and bin/review-gate is on the expected path (CERBERUS_ROOT=$CERBERUS_ROOT_VAL)." >&2
            exit 2
        fi

        # Resolve run key BEFORE building the env block so the resolver's
        # registry side effects are durable even if the backend is going
        # to fail.
        RUN_KEY="$(__amp_resolve_run_key)"

        # Surface run key in stdout for explicit user pass-through (plan
        # exit criterion §964). Users can override on subsequent calls
        # via --run-key / CERBERUS_RUN_KEY.
        printf 'Cerberus run key: %s\n' "$RUN_KEY"

        # Build env block per plan L789-L800.
        export CERBERUS_HOST="amp"
        export CERBERUS_ROOT="$CERBERUS_ROOT_VAL"
        export CERBERUS_STATE_ROOT="${CERBERUS_STATE_ROOT:-$HOME/.cerberus/projects}"
        export CERBERUS_PROJECT_KEY="$PROJECT_KEY"
        export CERBERUS_RUN_KEY="$RUN_KEY"
        # Transient compat alias during the migration window — plan
        # L797-L798. Removed once all downstream call sites are
        # migrated to CERBERUS_ROOT.
        export CLAUDE_PLUGIN_ROOT="$CERBERUS_ROOT_VAL"

        # Dispatch and propagate the backend's exit code. The `||
        # rc=$?` form preserves the original code under set -e; if the
        # backend errors the caller sees the same code Amp would see
        # if it had invoked review-gate directly.
        rc=0
        __amp_dispatch "$REQUESTED" "$_stdin_body" || rc=$?
        unset _stdin_body
        exit "$rc"
        ;;
    "")
        echo "cerberus.sh: TOOLBOX_ACTION not set; expected 'describe' or 'execute'" >&2
        exit 2
        ;;
    *)
        echo "cerberus.sh: unknown TOOLBOX_ACTION='$ACTION'; expected 'describe' or 'execute'" >&2
        exit 2
        ;;
esac
