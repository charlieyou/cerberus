#!/usr/bin/env bash
# .amp/toolbox/cerberus.sh — Amp Toolbox adapter for Cerberus (T013 skeleton).
#
# Plan reference: docs/2026-04-29-codex-amp-plugin-port-plan.md §Phase 2 —
# Amp Port (L936-L965), §Amp command surface (L778-L800).
#
# DIVERGENCE FROM ORIGINAL TASK SPEC. The plan and the T013 task context
# describe the Amp extension surface as a TypeScript plugin loaded from
# `.amp/plugins/cerberus.ts` and registered via `amp.registerCommand`.
# The T012 spike (commit bbb8fd8 — see docs/AMP.md "Phase 2 Spike
# Findings") found that Amp CLI 0.0.1777572045-g97f3b8 does NOT expose a
# `.amp/plugins/` loader, an `amp.registerCommand` API, or named
# lifecycle events. Amp's actual user-extension surfaces in this build
# are (1) the Amp Toolbox (subprocess scripts driven by the
# TOOLBOX_ACTION env var; tool params on stdin as JSON; output on
# stdout) and (2) skills. T013 therefore re-targets the skeleton to
# the toolbox surface. docs/AMP.md is the source of truth for this
# pivot; the plan's mapping decision-tree result ("Stable in commands
# but not lifecycle") still applies because this script reads
# AMP_THREAD_ID from the toolbox subprocess environment with a
# persisted-UUID fallback at
# ~/.cerberus/runtime/amp/<workspace-key>/active-session.json (T014
# implements the resolver; this file is pure stub).
#
# Toolbox protocol (per docs/AMP.md §"Amp extension surfaces"):
#   - TOOLBOX_ACTION=describe → emit tool metadata to stdout (JSON);
#     the `commands` array lists the six Cerberus commands the tool
#     dispatches (Review Code, Review Plan, Review Spec, Ask Panel,
#     Status, Clear Gate).
#   - TOOLBOX_ACTION=execute → read tool params (JSON) from stdin;
#     dispatch on `command` field; emit `{"status":"not_implemented"}`
#     marker for T014 to flesh out.
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
# Skeleton scope (T013):
#   - Establish script path, executability, and toolbox protocol shape.
#   - List the six commands so describe consumers (Amp + tests) can
#     enumerate them.
#   - Return a NotImplemented marker for execute so callers receive
#     valid JSON rather than a silent failure or a missing-command error.
#   - DO NOT implement env mapping (CERBERUS_HOST=amp,
#     CERBERUS_ROOT, CERBERUS_PROJECT_KEY, CERBERUS_RUN_KEY,
#     CLAUDE_PLUGIN_ROOT compat alias) — T014 implements.
#   - DO NOT implement AMP_THREAD_ID resolution or persisted-UUID
#     fallback — T014 implements.
#   - DO NOT spawn bin/review-gate — T014 wires the dispatch.
#   - DO NOT register lifecycle handlers (`session.start`, `agent.start`,
#     `agent.end`) — explicitly out of v1 scope (plan L953-L955;
#     docs/AMP.md confirms these surfaces are not exposed by Amp
#     0.0.1777572045 anyway).

set -euo pipefail

# Six Cerberus commands surfaced through this Amp Toolbox tool. Order
# matches the plan §Amp command surface table (L780-L787); tests rely
# on enumeration to confirm parity with that table.
COMMANDS=(
    "review-code"
    "review-plan"
    "review-spec"
    "ask-panel"
    "status"
    "clear-gate"
)

ACTION="${TOOLBOX_ACTION:-}"

case "$ACTION" in
    describe)
        # Emit a JSON describe payload listing the six commands. The
        # exact Amp describe schema is finalized in T014 against the
        # live Amp CLI; until then this stub returns a self-describing
        # JSON object that tests and humans can read directly.
        if command -v jq >/dev/null 2>&1; then
            printf '%s\n' "${COMMANDS[@]}" | jq -R . | jq -s \
                --arg name "cerberus" \
                --arg description "Cerberus multi-model review gate. Dispatches six review commands: review-code, review-plan, review-spec, ask-panel, status, clear-gate. Skeleton (T013); execution lands in T014." \
                --arg version "0.0.0-T013-skeleton" \
                --arg task "T013" \
                '{
                    name: $name,
                    description: $description,
                    version: $version,
                    task: $task,
                    status: "skeleton",
                    commands: .
                }'
        else
            # Fallback: hand-emit JSON if jq is unavailable on the host.
            # Tests on the verification gate require jq, so this branch
            # exists only for defensive completeness.
            printf '{"name":"cerberus","description":"Cerberus multi-model review gate (T013 skeleton).","version":"0.0.0-T013-skeleton","task":"T013","status":"skeleton","commands":["review-code","review-plan","review-spec","ask-panel","status","clear-gate"]}\n'
        fi
        exit 0
        ;;
    execute)
        # Drain stdin so upstream callers blocking on the write side
        # don't EPIPE. We don't act on the params yet — T014 dispatches
        # to bin/review-gate based on the `command` field — but reading
        # stdin matches the final contract.
        _stdin_body=""
        if [ ! -t 0 ]; then
            _stdin_body=$(cat || true)
        fi

        # Best-effort echo of the requested command into the
        # NotImplemented marker so test harnesses can confirm the
        # script saw and parsed the dispatch field. jq is preferred;
        # raw grep is a fallback. Validation/dispatch lands in T014.
        REQUESTED=""
        if [ -n "$_stdin_body" ] && command -v jq >/dev/null 2>&1; then
            REQUESTED=$(printf '%s' "$_stdin_body" | jq -r '.command // empty' 2>/dev/null || true)
        fi

        if command -v jq >/dev/null 2>&1; then
            jq -n \
                --arg status "not_implemented" \
                --arg task "T014" \
                --arg message "Amp Toolbox execute: command dispatch lands in T014. This is a T013 skeleton stub. See docs/AMP.md §Phase 2 Spike Findings for the run-key resolution plan and the divergence note from the plan's original .amp/plugins/cerberus.ts framing." \
                --arg requested "$REQUESTED" \
                '{
                    status: $status,
                    task: $task,
                    message: $message,
                    requested_command: (if $requested != "" then $requested else null end)
                }'
        else
            printf '{"status":"not_implemented","task":"T014","message":"Amp Toolbox execute stub (T013); T014 implements dispatch.","requested_command":null}\n'
        fi
        unset _stdin_body
        exit 0
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
