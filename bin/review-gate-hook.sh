#!/usr/bin/env bash
# Hook-specific logic for review-gate.

# Source telemetry library if available (sourced after review-gate-lib.sh by the caller)
# This is a fallback for standalone sourcing of this file
if [[ -z "${_CERBERUS_TELEMETRY_LIB_SOURCED:-}" ]]; then
    _SCRIPT_DIR_HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$_SCRIPT_DIR_HOOK/telemetry-lib.sh" ]]; then
        source "$_SCRIPT_DIR_HOOK/telemetry-lib.sh" 2>/dev/null || true
    fi
fi

# Source review-gate-lib.sh for shared helpers (write_iteration_telemetry, etc.)
# This is a fallback when the hook is invoked without prior sourcing of review-gate-lib.sh
if ! declare -f write_iteration_telemetry >/dev/null 2>&1; then
    _SCRIPT_DIR_HOOK="${_SCRIPT_DIR_HOOK:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    if [[ -f "$_SCRIPT_DIR_HOOK/review-gate-lib.sh" ]]; then
        source "$_SCRIPT_DIR_HOOK/review-gate-lib.sh" 2>/dev/null || true
    fi
fi

review_gate_check() {
    # Defensive error handling: on unexpected errors, allow stop to avoid blocking forever
    # The hook must either output valid JSON or output nothing (allow)
    _check_error_handler() {
        local exit_code=$?
        local line_no="${1:-unknown}"
        # Log the error if possible, then allow stop to avoid deadlock
        echo "[review-gate] INTERNAL ERROR at line $line_no (exit $exit_code) - allowing stop" >&2
        exit 0  # Allow stop on error (fail-open to avoid blocking)
    }
    trap '_check_error_handler $LINENO' ERR

    MAX_ITERATIONS_DEFAULT=3
    MAX_ITERATIONS="${REVIEW_GATE_MAX_ROUNDS:-$MAX_ITERATIONS_DEFAULT}"
    MAX_WAIT_SECONDS="${REVIEW_GATE_MAX_WAIT_SECONDS:-1800}"
    POLL_INTERVAL_SECONDS="${REVIEW_GATE_POLL_INTERVAL_SECONDS:-3}"

    INPUT=$(cat)
    LOG_FILE=""

    log() {
        local msg="$1"
        local ts
        ts=$(date -Iseconds)
        if [[ -n "$LOG_FILE" ]]; then
            printf '%s %s\n' "$ts" "$msg" >> "$LOG_FILE"
        else
            printf '%s %s\n' "$ts" "$msg" >&2
        fi
    }

    setup_log_file() {
        if [[ -n "${REVIEW_GATE_LOG_FILE:-}" ]]; then
            LOG_FILE="$REVIEW_GATE_LOG_FILE"
        else
            LOG_FILE="$REVIEW_DIR/cerberus.log"
        fi
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    }

    # --- Session identification ---
    SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // .sessionId // empty' 2>/dev/null || echo "")
    TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // .transcriptPath // empty' 2>/dev/null || echo "")

    SESSION_KEY=""
    SESSION_SOURCE=""

    if [[ -n "${REVIEW_GATE_SESSION_KEY:-}" ]]; then
        SESSION_KEY="$REVIEW_GATE_SESSION_KEY"
        SESSION_SOURCE="env.REVIEW_GATE_SESSION_KEY"
    elif [[ -n "$SESSION_ID" ]]; then
        SESSION_KEY="$SESSION_ID"
        SESSION_SOURCE="input.session_id"
    elif [[ -n "$TRANSCRIPT_PATH" ]]; then
        SESSION_KEY="$TRANSCRIPT_PATH"
        SESSION_SOURCE="input.transcript_path"
    fi

    if [[ -z "$SESSION_ID" ]]; then
        log "review-gate: missing session_id; allowing stop"
    fi

    # --- Helper: Output block JSON ---
    output_block() {
        local reason="$1"
        log "review-gate: blocking stop: ${reason:0:200}"
        trap - ERR  # Clear error trap before explicit exit
        jq -n --arg reason "$reason" '{"decision": "block", "reason": $reason}'
        exit 0
    }

    # --- Helper: Output allow (exit 0, optionally with warning message) ---
    output_allow() {
        local message="${1:-}"
        if [[ -n "$message" ]]; then
            log "review-gate: allowing stop with warning: ${message:0:200}"
            trap - ERR  # Clear error trap before explicit exit
            # Output JSON with allow decision and warning message so user sees it
            jq -n --arg message "$message" '{"decision": "allow", "message": $message}'
        else
            log "review-gate: allowing stop"
            trap - ERR  # Clear error trap before explicit exit
        fi
        exit 0
    }

    _reviewer_subprocess_marker_truthy() {
        case "${1:-}" in
            1|true|TRUE|yes|YES|on|ON) return 0 ;;
            *) return 1 ;;
        esac
    }

    # Reviewer subprocesses can have their own Stop hooks. They must never
    # enforce the parent gate, otherwise a reviewer can wait on itself until
    # the outer per-reviewer timeout kills an otherwise valid response.
    if _reviewer_subprocess_marker_truthy "${CERBERUS_REVIEWER_SUBPROCESS:-}" || \
       _reviewer_subprocess_marker_truthy "${REVIEW_GATE_REVIEWER_SUBPROCESS:-}"; then
        log "review-gate: reviewer subprocess Stop hook; allowing"
        output_allow
    fi

    stop_hook_depth="${CERBERUS_REVIEW_GATE_STOP_HOOK_DEPTH:-0}"
    case "$stop_hook_depth" in
        ''|*[!0-9]*) stop_hook_depth=0 ;;
    esac
    if [[ "$stop_hook_depth" -ge 1 ]]; then
        log "review-gate: nested Stop hook while review gate active; allowing"
        output_allow
    fi
    export CERBERUS_REVIEW_GATE_STOP_HOOK_DEPTH=$((stop_hook_depth + 1))

    # --- Session-scoped path resolution ---
    # Exit early if no session_id - cannot enforce gate without session context
    if [[ -z "$SESSION_ID" ]]; then
        output_allow
    fi

    REVIEW_DIR=$(resolve_review_dir "$SESSION_ID" "$TRANSCRIPT_PATH")
    STATE_FILE="$REVIEW_DIR/gate-state.json"
    REVIEWS_DIR="$REVIEW_DIR/reviews"
    ARTIFACT_FILE="$REVIEW_DIR/latest.md"
    ITERATION_FILE="$REVIEW_DIR/iteration.txt"
    setup_log_file
    log "review-gate: session_id=$SESSION_ID"
    log "review-gate: transcript_path=$TRANSCRIPT_PATH"
    log "review-gate: review_dir=$REVIEW_DIR"
    log "review-gate: state_file=$STATE_FILE"
    log "review-gate: reviews_dir=$REVIEWS_DIR"
    log "review-gate: artifact_file=$ARTIFACT_FILE"

    # --- [AC1] Allowlist resolve command to prevent deadlock ---
    # IMPORTANT: This check MUST happen before _ensure_review_dir_writable
    # so users can always escape the gate via resolve, even when storage is broken.
    PENDING_CMD=$(echo "$INPUT" | jq -r '.pending_tool_input.command // ""' 2>/dev/null || echo "")
    if [[ -n "$PENDING_CMD" ]]; then
        log "review-gate: pending_tool_input.command=$PENDING_CMD"
    fi
    if [[ "$PENDING_CMD" == *"review-gate resolve"* ]]; then
        log "review-gate: allow resolve command"
        output_allow
    fi

    # --- Ensure review directory is writable ---
    # The review directory MUST be writable for gate enforcement to work.
    # If not writable, this is an error condition that should fail clearly,
    # NOT silently allow stop (which would disable enforcement).
    _ensure_review_dir_writable() {
        local test_file="$REVIEW_DIR/.write-test.$$"
        if ! mkdir -p "$REVIEW_DIR" 2>/dev/null; then
            return 1
        fi
        if ! touch "$test_file" 2>/dev/null; then
            return 1
        fi
        rm -f "$test_file" 2>/dev/null
        return 0
    }

    if ! _ensure_review_dir_writable; then
        log "review-gate: WARNING: review directory not writable: $REVIEW_DIR - failing open"
        # Fail open: if we can't write to storage, we can't persist state or enforce the gate.
        # Blocking here would create a deadlock (user stuck, gate can't track progress).
        # Warn clearly so user knows enforcement is disabled, but allow stop.
        output_allow "Review gate warning: cannot write to review directory ($REVIEW_DIR). Gate enforcement disabled - check permissions or disk space."
    fi

    # --- Helper: Detect review type from artifact frontmatter ---
    detect_review_type() {
        if [[ -f "$ARTIFACT_FILE" ]]; then
            local type_from_frontmatter
            type_from_frontmatter=$(sed -n 's/^<!-- *review-type: *\([^ ]*\) *-->/\1/p' "$ARTIFACT_FILE" | head -1)
            if [[ -n "$type_from_frontmatter" ]]; then
                echo "$type_from_frontmatter"
                return 0
            fi
        fi
        echo ""
    }

    # --- Helper: Extract diff-args (state first, artifact fallback) ---
    extract_diff_args() {
        if [[ -f "$STATE_FILE" ]]; then
            local state_diff_args
            state_diff_args=$(jq -r '.mode.diff_args // empty' "$STATE_FILE" 2>/dev/null || echo "")
            if [[ -n "$state_diff_args" && "$state_diff_args" != "null" ]]; then
                echo "$state_diff_args"
                return 0
            fi
        fi
        if [[ -f "$ARTIFACT_FILE" ]]; then
            sed -n 's/^<!-- *diff-args: *\(.*\) *-->/\1/p' "$ARTIFACT_FILE" | head -1
        fi
    }

    # --- Helper: Extract plan-path from artifact frontmatter ---
    extract_plan_path() {
        if [[ -f "$ARTIFACT_FILE" ]]; then
            sed -n 's/^<!-- *plan-path: *\(.*[^ ]\) *-->/\1/p' "$ARTIFACT_FILE" | head -1
        fi
    }

    extract_plan_path_from_state() {
        if [[ -f "$STATE_FILE" ]]; then
            local path
            path=$(jq -r '.mode.plan_path // empty' "$STATE_FILE" 2>/dev/null || echo "")
            if [[ -n "$path" && "$path" != "null" ]]; then
                echo "$path"
            fi
        fi
    }

    # --- Helper: Extract spec-path from artifact frontmatter ---
    extract_spec_path() {
        if [[ -f "$ARTIFACT_FILE" ]]; then
            sed -n 's/^<!-- *spec-path: *\(.*[^ ]\) *-->/\1/p' "$ARTIFACT_FILE" | head -1
        fi
    }

    extract_spec_path_from_state() {
        if [[ -f "$STATE_FILE" ]]; then
            local path
            path=$(jq -r '.mode.spec_path // empty' "$STATE_FILE" 2>/dev/null || echo "")
            if [[ -n "$path" && "$path" != "null" ]]; then
                echo "$path"
            fi
        fi
    }

    # --- Helper: Extract epic-path from state for epic-verify ---
    extract_epic_path_from_state() {
        if [[ -f "$STATE_FILE" ]]; then
            local path
            path=$(jq -r '.mode.epic_path // empty' "$STATE_FILE" 2>/dev/null || echo "")
            if [[ -n "$path" && "$path" != "null" ]]; then
                echo "$path"
            fi
        fi
    }

    extract_ask_prompt_from_state() {
        if [[ -f "$STATE_FILE" ]]; then
            jq -r '.mode.ask_prompt // empty' "$STATE_FILE" 2>/dev/null || echo ""
        fi
    }

    extract_ask_context_from_state() {
        if [[ -f "$STATE_FILE" ]]; then
            jq -r '.mode.ask_context // empty' "$STATE_FILE" 2>/dev/null || echo ""
        fi
    }

    extract_ask_artifact_section() {
        local heading="$1"
        [[ -f "$ARTIFACT_FILE" ]] || return 0

        awk -v heading="$heading" '
            function strip_fence_indent(s,    i) {
                i = 0
                while (i < 3 && substr(s, 1, 1) == " ") {
                    s = substr(s, 2)
                    i++
                }
                return s
            }
            $0 == heading { seen=1; next }
            seen && !in_block {
                stripped = strip_fence_indent($0)
                if (stripped !~ /^```/) next
                match(stripped, /^`+/)
                fence = substr(stripped, 1, RLENGTH)
                in_block=1
                next
            }
            seen && in_block && strip_fence_indent($0) == fence { exit }
            seen && in_block { print }
        ' "$ARTIFACT_FILE"
    }

    # --- Helper: Extract agents list from artifact frontmatter ---
    extract_agents() {
        if [[ -f "$ARTIFACT_FILE" ]]; then
            sed -n 's/^<!-- *agents: *\(.*\) *-->$/\1/p' "$ARTIFACT_FILE" | head -1 | tr -d '[:space:]'
        fi
    }

    # --- Helper: Extract max-rounds from artifact frontmatter ---
    extract_max_rounds() {
        if [[ -f "$ARTIFACT_FILE" ]]; then
            sed -n 's/^<!-- *max-rounds: *\([0-9][0-9]*\) *-->$/\1/p' "$ARTIFACT_FILE" | head -1
        fi
    }

    # --- Helper: Extract mode from artifact frontmatter ---
    extract_mode_from_artifact() {
        if [[ -f "$ARTIFACT_FILE" ]]; then
            sed -n 's/^<!-- *mode: *\([^ ]*\) *-->$/\1/p' "$ARTIFACT_FILE" | head -1
        fi
    }

    # --- Helper: Extract mode from state config ---
    extract_mode_from_state() {
        if [[ -f "$STATE_FILE" ]]; then
            local mode
            mode=$(jq -r '.config.intelligence_mode // empty' "$STATE_FILE" 2>/dev/null || echo "")
            if [[ "$mode" == "null" ]]; then
                mode=""
            fi
            printf '%s' "$mode"
        fi
    }

    # --- Helper: Resolve intelligence mode (state > artifact) ---
    extract_intelligence_mode() {
        local mode=""
        mode=$(extract_mode_from_state)
        if [[ -z "$mode" ]]; then
            mode=$(extract_mode_from_artifact)
        fi
        printf '%s' "$mode"
    }

    local state_max_rounds
    state_max_rounds=""
    if [[ -f "$STATE_FILE" ]]; then
        state_max_rounds=$(jq -r '.config.max_rounds // empty' "$STATE_FILE" 2>/dev/null || echo "")
        if [[ "$state_max_rounds" == "null" ]]; then
            state_max_rounds=""
        fi
    fi
    if [[ -n "$state_max_rounds" ]]; then
        if [[ "$state_max_rounds" =~ ^[0-9]+$ ]] && [[ "$state_max_rounds" -ge 0 ]]; then
            MAX_ITERATIONS="$state_max_rounds"
        else
            log "review-gate: invalid state max_rounds '$state_max_rounds' (using $MAX_ITERATIONS)"
        fi
    fi
    local max_rounds
    max_rounds=$(extract_max_rounds)
    if [[ -n "$max_rounds" ]]; then
        if [[ "$max_rounds" =~ ^[0-9]+$ ]] && [[ "$max_rounds" -ge 0 ]]; then
            MAX_ITERATIONS="$max_rounds"
        else
            log "review-gate: invalid max-rounds '$max_rounds' (using $MAX_ITERATIONS)"
        fi
    fi
    log "review-gate: max_iterations=$MAX_ITERATIONS"

    # --- Helper: Spawn reviewers for current artifact ---
    # Returns 0 on success (caller should proceed to polling), 1 on failure
    spawn_reviewers() {
        local detected_type
        detected_type=$(detect_review_type)
        log "review-gate: spawn reviewers (type=${detected_type:-none})"

        # Initialize telemetry iteration directory
        local current_iter iter_dir
        current_iter=$(load_iteration 2>/dev/null || echo "0")
        if declare -f init_iteration_dir >/dev/null 2>&1; then
            iter_dir=$(init_iteration_dir "$REVIEW_DIR" "$current_iter" 2>/dev/null) || true
            if [[ -n "$iter_dir" ]]; then
                log "review-gate: telemetry iteration dir: $iter_dir"
                # Export for use by reviewer processes and later telemetry collection
                export TELEMETRY_ITER_DIR="$iter_dir"
            fi
        fi

        local spawn_success=false
        local agents_csv
        agents_csv=$(extract_agents)
        if [[ -n "$agents_csv" ]]; then
            log "review-gate: using agents filter '$agents_csv'"
        fi
        local max_rounds
        max_rounds=$(extract_max_rounds)
        if [[ -n "$max_rounds" ]]; then
            if [[ "$max_rounds" =~ ^[0-9]+$ ]] && [[ "$max_rounds" -ge 1 ]]; then
                log "review-gate: using max-rounds '$max_rounds'"
            else
                log "review-gate: invalid max-rounds '$max_rounds' (ignoring)"
            fi
        fi

        local mode
        mode=$(extract_intelligence_mode)
        if [[ -n "$mode" ]]; then
            log "review-gate: using mode '$mode'"
        fi

        local consensus_mode
        consensus_mode=$(jq -r '.config.consensus_mode // ""' "$STATE_FILE" 2>/dev/null || echo "")
        if [[ -n "$consensus_mode" && "$consensus_mode" != "null" ]]; then
            log "review-gate: using consensus '$consensus_mode'"
        fi

        # Preserve --debate / --debate-seed across auto-respawns. Without
        # these reads the rebuilt spawn_cmd silently drops the user's debate
        # mode opt-in and the next iteration falls back to single-pass review,
        # letting a revised artifact get approved without the debate the
        # caller explicitly requested.
        local debate_flag debate_seed_value
        debate_flag=$(jq -r '.config.debate // empty' "$STATE_FILE" 2>/dev/null || echo "")
        # Only preserve --debate-seed when debate is enabled. Per R9 (AC-5),
        # --debate-seed is a no-op when --debate is absent and MUST NOT be
        # observable in any byte-parity-protected artifact (including the
        # Stop-hook's auto-respawn command line). Guarding the read here
        # ensures the seed never reaches the rebuilt spawn_cmd on a
        # non-debate run, even if a stale .config.debate_seed somehow
        # appeared in gate-state.json.
        if [[ "$debate_flag" == "true" ]]; then
            debate_seed_value=$(jq -r '.config.debate_seed // empty' "$STATE_FILE" 2>/dev/null || echo "")
            log "review-gate: preserving --debate on auto-respawn"
        else
            debate_seed_value=""
        fi

        # For code, re-fetch the diff from current args
        if [[ "$detected_type" == "code" ]]; then
            local diff_args
            diff_args=$(extract_diff_args)
            log "review-gate: code re-spawn with diff_args='$diff_args'"

            # Parse diff_args into array safely (no eval to avoid command injection)
            # Note: This splits on whitespace, so args with spaces won't round-trip.
            # In practice, git diff args (--base, --commit, ranges) don't contain spaces.
            local -a args_array
            read -r -a args_array <<< "$diff_args"

            local -a spawn_cmd=("$0" "spawn-code-review")
            if [[ -n "$agents_csv" ]]; then
                spawn_cmd+=(--agents "$agents_csv")
            fi
            if [[ -n "$max_rounds" ]]; then
                spawn_cmd+=(--max-rounds "$max_rounds")
            fi
            if [[ -n "$mode" ]]; then
                spawn_cmd+=(--mode "$mode")
            fi
            if [[ -n "$consensus_mode" && "$consensus_mode" != "null" ]]; then
                spawn_cmd+=(--consensus "$consensus_mode")
            fi
            if [[ "$debate_flag" == "true" ]]; then
                spawn_cmd+=(--debate)
            fi
            if [[ -n "$debate_seed_value" ]]; then
                spawn_cmd+=(--debate-seed "$debate_seed_value")
            fi
            if [[ -n "$diff_args" ]]; then
                spawn_cmd+=("${args_array[@]}")
            fi

            if REVIEW_GATE_SESSION_KEY="$SESSION_KEY" \
               REVIEW_GATE_SESSION_SOURCE="$SESSION_SOURCE" \
               CLAUDE_SESSION_ID="$SESSION_ID" \
               REVIEW_GATE_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" \
               "${spawn_cmd[@]}" >/dev/null 2>&1; then
                spawn_success=true
            fi
        # For plan, re-read the plan file to capture edits
        elif [[ "$detected_type" == "plan" ]]; then
            local plan_path
            plan_path=$(extract_plan_path_from_state)
            # Ignore state plan_path if it points to the artifact (legacy gates)
            if [[ "$plan_path" == "$ARTIFACT_FILE" ]] || [[ "$plan_path" == *"/latest.md" ]]; then
                plan_path=""
            fi
            [[ -z "$plan_path" ]] && plan_path=$(extract_plan_path)
            log "review-gate: plan re-spawn with plan_path='$plan_path'"

            if [[ -n "$plan_path" && -f "$plan_path" ]]; then
                local -a spawn_cmd=("$0" "spawn-plan-review")
                if [[ -n "$agents_csv" ]]; then
                    spawn_cmd+=(--agents "$agents_csv")
                fi
                if [[ -n "$max_rounds" ]]; then
                    spawn_cmd+=(--max-rounds "$max_rounds")
                fi
                if [[ -n "$mode" ]]; then
                    spawn_cmd+=(--mode "$mode")
                fi
                if [[ -n "$consensus_mode" && "$consensus_mode" != "null" ]]; then
                    spawn_cmd+=(--consensus "$consensus_mode")
                fi
                if [[ "$debate_flag" == "true" ]]; then
                    spawn_cmd+=(--debate)
                fi
                if [[ -n "$debate_seed_value" ]]; then
                    spawn_cmd+=(--debate-seed "$debate_seed_value")
                fi
                spawn_cmd+=("$plan_path")
                if REVIEW_GATE_SESSION_KEY="$SESSION_KEY" \
                   REVIEW_GATE_SESSION_SOURCE="$SESSION_SOURCE" \
                   CLAUDE_SESSION_ID="$SESSION_ID" \
                   REVIEW_GATE_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" \
                   "${spawn_cmd[@]}" >/dev/null 2>&1; then
                    spawn_success=true
                fi
            else
                log "review-gate: plan missing plan_path, falling back to artifact"
                local -a spawn_cmd=("$0" "spawn")
                if [[ -n "$agents_csv" ]]; then
                    spawn_cmd+=(--agents "$agents_csv")
                fi
                if [[ -n "$max_rounds" ]]; then
                    spawn_cmd+=(--max-rounds "$max_rounds")
                fi
                if [[ -n "$mode" ]]; then
                    spawn_cmd+=(--mode "$mode")
                fi
                if [[ -n "$consensus_mode" && "$consensus_mode" != "null" ]]; then
                    spawn_cmd+=(--consensus "$consensus_mode")
                fi
                if [[ "$debate_flag" == "true" ]]; then
                    spawn_cmd+=(--debate)
                fi
                if [[ -n "$debate_seed_value" ]]; then
                    spawn_cmd+=(--debate-seed "$debate_seed_value")
                fi
                spawn_cmd+=("$ARTIFACT_FILE")
                if REVIEW_GATE_SESSION_KEY="$SESSION_KEY" \
                   REVIEW_GATE_SESSION_SOURCE="$SESSION_SOURCE" \
                   CLAUDE_SESSION_ID="$SESSION_ID" \
                   REVIEW_GATE_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" \
                   REVIEW_TYPE="$detected_type" \
                   "${spawn_cmd[@]}" >/dev/null 2>&1; then
                    spawn_success=true
                fi
            fi
        # For spec review, re-read the spec file to capture edits
        elif [[ "$detected_type" == "spec" ]]; then
            local spec_path
            spec_path=$(extract_spec_path_from_state)
            # Ignore state spec_path if it points to the artifact (legacy gates)
            if [[ "$spec_path" == "$ARTIFACT_FILE" ]] || [[ "$spec_path" == *"/latest.md" ]]; then
                spec_path=""
            fi
            [[ -z "$spec_path" ]] && spec_path=$(extract_spec_path)
            log "review-gate: spec re-spawn with spec_path='$spec_path'"

            if [[ -n "$spec_path" && -f "$spec_path" ]]; then
                local -a spawn_cmd=("$0" "spawn-spec-review")
                if [[ -n "$agents_csv" ]]; then
                    spawn_cmd+=(--agents "$agents_csv")
                fi
                if [[ -n "$max_rounds" ]]; then
                    spawn_cmd+=(--max-rounds "$max_rounds")
                fi
                if [[ -n "$mode" ]]; then
                    spawn_cmd+=(--mode "$mode")
                fi
                if [[ -n "$consensus_mode" && "$consensus_mode" != "null" ]]; then
                    spawn_cmd+=(--consensus "$consensus_mode")
                fi
                if [[ "$debate_flag" == "true" ]]; then
                    spawn_cmd+=(--debate)
                fi
                if [[ -n "$debate_seed_value" ]]; then
                    spawn_cmd+=(--debate-seed "$debate_seed_value")
                fi
                spawn_cmd+=("$spec_path")
                if REVIEW_GATE_SESSION_KEY="$SESSION_KEY" \
                   REVIEW_GATE_SESSION_SOURCE="$SESSION_SOURCE" \
                   CLAUDE_SESSION_ID="$SESSION_ID" \
                   REVIEW_GATE_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" \
                   "${spawn_cmd[@]}" >/dev/null 2>&1; then
                    spawn_success=true
                fi
            else
                log "review-gate: spec missing spec_path, falling back to artifact"
                local -a spawn_cmd=("$0" "spawn")
                if [[ -n "$agents_csv" ]]; then
                    spawn_cmd+=(--agents "$agents_csv")
                fi
                if [[ -n "$max_rounds" ]]; then
                    spawn_cmd+=(--max-rounds "$max_rounds")
                fi
                if [[ -n "$mode" ]]; then
                    spawn_cmd+=(--mode "$mode")
                fi
                if [[ -n "$consensus_mode" && "$consensus_mode" != "null" ]]; then
                    spawn_cmd+=(--consensus "$consensus_mode")
                fi
                if [[ "$debate_flag" == "true" ]]; then
                    spawn_cmd+=(--debate)
                fi
                if [[ -n "$debate_seed_value" ]]; then
                    spawn_cmd+=(--debate-seed "$debate_seed_value")
                fi
                spawn_cmd+=("$ARTIFACT_FILE")
                if REVIEW_GATE_SESSION_KEY="$SESSION_KEY" \
                   REVIEW_GATE_SESSION_SOURCE="$SESSION_SOURCE" \
                   CLAUDE_SESSION_ID="$SESSION_ID" \
                   REVIEW_GATE_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" \
                   REVIEW_TYPE="$detected_type" \
                   "${spawn_cmd[@]}" >/dev/null 2>&1; then
                    spawn_success=true
                fi
            fi
        # For epic-verify, re-run verification with saved epic path
        elif [[ "$detected_type" == "epic-verify" ]]; then
            local epic_path
            epic_path=$(extract_epic_path_from_state)
            log "review-gate: epic-verify re-spawn with epic_path='$epic_path'"

            if [[ -n "$epic_path" && -f "$epic_path" ]]; then
                local -a spawn_cmd=("$0" "spawn-epic-verify")
                if [[ -n "$agents_csv" ]]; then
                    spawn_cmd+=(--agents "$agents_csv")
                fi
                if [[ -n "$max_rounds" ]]; then
                    spawn_cmd+=(--max-rounds "$max_rounds")
                fi
                if [[ -n "$mode" ]]; then
                    spawn_cmd+=(--mode "$mode")
                fi
                if [[ -n "$consensus_mode" && "$consensus_mode" != "null" ]]; then
                    spawn_cmd+=(--consensus "$consensus_mode")
                fi
                if [[ "$debate_flag" == "true" ]]; then
                    spawn_cmd+=(--debate)
                fi
                if [[ -n "$debate_seed_value" ]]; then
                    spawn_cmd+=(--debate-seed "$debate_seed_value")
                fi
                spawn_cmd+=("$epic_path")
                if REVIEW_GATE_SESSION_KEY="$SESSION_KEY" \
                   REVIEW_GATE_SESSION_SOURCE="$SESSION_SOURCE" \
                   CLAUDE_SESSION_ID="$SESSION_ID" \
                   REVIEW_GATE_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" \
                   "${spawn_cmd[@]}" >/dev/null 2>&1; then
                    spawn_success=true
                fi
            else
                log "review-gate: epic-verify missing epic_path, falling back to artifact"
                local -a spawn_cmd=("$0" "spawn")
                if [[ -n "$agents_csv" ]]; then
                    spawn_cmd+=(--agents "$agents_csv")
                fi
                if [[ -n "$max_rounds" ]]; then
                    spawn_cmd+=(--max-rounds "$max_rounds")
                fi
                if [[ -n "$mode" ]]; then
                    spawn_cmd+=(--mode "$mode")
                fi
                if [[ -n "$consensus_mode" && "$consensus_mode" != "null" ]]; then
                    spawn_cmd+=(--consensus "$consensus_mode")
                fi
                if [[ "$debate_flag" == "true" ]]; then
                    spawn_cmd+=(--debate)
                fi
                if [[ -n "$debate_seed_value" ]]; then
                    spawn_cmd+=(--debate-seed "$debate_seed_value")
                fi
                spawn_cmd+=("$ARTIFACT_FILE")
                if REVIEW_GATE_SESSION_KEY="$SESSION_KEY" \
                   REVIEW_GATE_SESSION_SOURCE="$SESSION_SOURCE" \
                   CLAUDE_SESSION_ID="$SESSION_ID" \
                   REVIEW_GATE_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" \
                   REVIEW_TYPE="$detected_type" \
                   "${spawn_cmd[@]}" >/dev/null 2>&1; then
                    spawn_success=true
                fi
            fi
        elif [[ "$detected_type" == "ask" ]]; then
            local ask_prompt ask_context ask_prompt_file ask_context_file
            ask_prompt=$(extract_ask_prompt_from_state)
            ask_context=$(extract_ask_context_from_state)
            if [[ -z "$ask_prompt" || "$ask_prompt" == "null" ]]; then
                ask_prompt=$(extract_ask_artifact_section "## Prompt")
            fi
            if [[ -z "$ask_context" || "$ask_context" == "null" ]]; then
                ask_context=$(extract_ask_artifact_section "## Context")
            fi

            if [[ -n "$ask_prompt" ]]; then
                ask_prompt_file=$(mktemp -t review-gate-ask-prompt.XXXXXX)
                printf '%s' "$ask_prompt" > "$ask_prompt_file"
                local -a spawn_cmd=("$0" "spawn-ask" --prompt-file "$ask_prompt_file")
                if [[ -n "$agents_csv" ]]; then
                    spawn_cmd+=(--agents "$agents_csv")
                fi
                if [[ -n "$max_rounds" ]]; then
                    spawn_cmd+=(--max-rounds "$max_rounds")
                fi
                if [[ -n "$mode" ]]; then
                    spawn_cmd+=(--mode "$mode")
                fi
                if [[ -n "$consensus_mode" && "$consensus_mode" != "null" ]]; then
                    spawn_cmd+=(--consensus "$consensus_mode")
                fi
                if [[ "$debate_flag" == "true" ]]; then
                    spawn_cmd+=(--debate)
                fi
                if [[ -n "$debate_seed_value" ]]; then
                    spawn_cmd+=(--debate-seed "$debate_seed_value")
                fi
                if [[ -n "$ask_context" ]]; then
                    ask_context_file=$(mktemp -t review-gate-ask-context.XXXXXX)
                    printf '%s' "$ask_context" > "$ask_context_file"
                    spawn_cmd+=(--context-file "$ask_context_file")
                else
                    ask_context_file=""
                fi

                if REVIEW_GATE_SESSION_KEY="$SESSION_KEY" \
                   REVIEW_GATE_SESSION_SOURCE="$SESSION_SOURCE" \
                   CLAUDE_SESSION_ID="$SESSION_ID" \
                   REVIEW_GATE_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" \
                   "${spawn_cmd[@]}" >/dev/null 2>&1; then
                    spawn_success=true
                fi
                rm -f "$ask_prompt_file" "${ask_context_file:-}" 2>/dev/null || true
            else
                log "review-gate: ask prompt missing, falling back to artifact"
                local -a spawn_cmd=("$0" "spawn")
                if [[ -n "$agents_csv" ]]; then
                    spawn_cmd+=(--agents "$agents_csv")
                fi
                if [[ -n "$max_rounds" ]]; then
                    spawn_cmd+=(--max-rounds "$max_rounds")
                fi
                if [[ -n "$mode" ]]; then
                    spawn_cmd+=(--mode "$mode")
                fi
                if [[ -n "$consensus_mode" && "$consensus_mode" != "null" ]]; then
                    spawn_cmd+=(--consensus "$consensus_mode")
                fi
                if [[ "$debate_flag" == "true" ]]; then
                    spawn_cmd+=(--debate)
                fi
                if [[ -n "$debate_seed_value" ]]; then
                    spawn_cmd+=(--debate-seed "$debate_seed_value")
                fi
                spawn_cmd+=("$ARTIFACT_FILE")
                if REVIEW_GATE_SESSION_KEY="$SESSION_KEY" \
                   REVIEW_GATE_SESSION_SOURCE="$SESSION_SOURCE" \
                   CLAUDE_SESSION_ID="$SESSION_ID" \
                   REVIEW_GATE_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" \
                   REVIEW_TYPE="$detected_type" \
                   "${spawn_cmd[@]}" >/dev/null 2>&1; then
                    spawn_success=true
                fi
            fi
        else
            local -a spawn_cmd=("$0" "spawn")
            if [[ -n "$agents_csv" ]]; then
                spawn_cmd+=(--agents "$agents_csv")
            fi
            if [[ -n "$max_rounds" ]]; then
                spawn_cmd+=(--max-rounds "$max_rounds")
            fi
            if [[ -n "$mode" ]]; then
                spawn_cmd+=(--mode "$mode")
            fi
            if [[ -n "$consensus_mode" && "$consensus_mode" != "null" ]]; then
                spawn_cmd+=(--consensus "$consensus_mode")
            fi
            if [[ "$debate_flag" == "true" ]]; then
                spawn_cmd+=(--debate)
            fi
            if [[ -n "$debate_seed_value" ]]; then
                spawn_cmd+=(--debate-seed "$debate_seed_value")
            fi
            spawn_cmd+=("$ARTIFACT_FILE")
            if REVIEW_GATE_SESSION_KEY="$SESSION_KEY" \
               REVIEW_GATE_SESSION_SOURCE="$SESSION_SOURCE" \
               CLAUDE_SESSION_ID="$SESSION_ID" \
               REVIEW_GATE_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" \
               REVIEW_TYPE="$detected_type" \
               "${spawn_cmd[@]}" >/dev/null 2>&1; then
                spawn_success=true
            fi
        fi

        if [[ "$spawn_success" == "true" ]]; then
            if [[ -f "$STATE_FILE" ]]; then
                local status
                status=$(jq -r '.status // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown")
                if [[ "$status" == "resolved" ]]; then
                    log "review-gate: spawn auto-resolved (no reviewers available)"
                    # No reviewers available - spawn auto-resolved
                    output_allow
                fi
            fi
            # Success: return to caller so it can proceed to polling loop
            log "review-gate: spawn succeeded"
            return 0
        fi

        if ! command -v codex >/dev/null 2>&1 && ! command -v gemini >/dev/null 2>&1 && ! command -v claude >/dev/null 2>&1; then
            log "review-gate: reviewers missing; allowing stop"
            output_allow
        fi

        log "review-gate: spawn failed"
        output_block "Review gate error: failed to spawn reviewers. Run ${CLI_CMD} spawn manually to inspect output."
    }

    # --- [AC6] Check for stale state (>30 min = 1800 seconds) ---
    cleanup_stale_state() {
        rm -f "$STATE_FILE" 2>/dev/null || true
        rm -f "$ITERATION_FILE" 2>/dev/null || true
        rm -rf "$REVIEWS_DIR" 2>/dev/null || true
    }

    mark_stale_resolved() {
        local now tmp
        now=$(date -Iseconds)
        tmp="${STATE_FILE}.tmp.$$"
        jq --arg now "$now" \
           '.status="resolved"
            | .decision = (.decision // {})
            | .decision.reason="stale_timeout"
            | .decision.decided_at=$now' \
           "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    }

    # --- Ensure state has an owner to avoid cross-session blocking ---
    ensure_state_owner() {
        [[ -z "$SESSION_KEY" ]] && return 0
        [[ ! -f "$STATE_FILE" ]] && return 0

        local existing
        existing=$(jq -r '.owner.session_key // ""' "$STATE_FILE" 2>/dev/null || echo "")
        if [[ -n "$existing" ]]; then
            return 0
        fi

        local tmp="${STATE_FILE}.tmp.$$"
        trap 'rm -f "$tmp"' RETURN

        jq --arg key "$SESSION_KEY" \
           --arg source "$SESSION_SOURCE" \
           --arg session_id "$SESSION_ID" \
           --arg transcript "$TRANSCRIPT_PATH" \
           '.owner = (.owner // {}) |
            (if $key != "" then .owner.session_key = $key else . end) |
            (if $source != "" then .owner.source = $source else . end) |
            (if $session_id != "" then .owner.session_id = $session_id else . end) |
            (if $transcript != "" then .owner.transcript_path = $transcript else . end) |
            (if (.owner | length) == 0 then .owner = null else . end)' \
           "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    }

    # --- [AC2] Exit 0 if no artifact exists (when no active state) ---
    if [[ ! -f "$STATE_FILE" ]] && [[ ! -f "$ARTIFACT_FILE" ]]; then
        log "review-gate: no state or artifact; allowing stop"
        output_allow
    fi

    # --- If state exists, process it first (supports manual review-gate paths) ---
    if [[ -f "$STATE_FILE" ]]; then
        log "review-gate: state file exists"
        CREATED_AT=$(jq -r '.created_at // ""' "$STATE_FILE" 2>/dev/null || echo "")
        if [[ -n "$CREATED_AT" ]]; then
            CREATED_EPOCH=$(iso8601_to_epoch "$CREATED_AT")
            NOW_EPOCH=$(date +%s)
            AGE_SECONDS=$((NOW_EPOCH - CREATED_EPOCH))
            log "review-gate: state age ${AGE_SECONDS}s"

            if [[ $AGE_SECONDS -gt 1800 ]]; then
                log "review-gate: stale state; marking resolved"
                mark_stale_resolved
                output_allow
            fi
        fi
        ensure_state_owner
    else
        log "review-gate: state file missing"
    fi

    # --- Get iteration count ---
    get_iteration() {
        load_iteration
    }

    reset_iteration() {
        # Use save_iteration to reset both iteration.txt and state file
        save_iteration 0
    }

    # --- Archive previous reviews (in check context) ---
    archive_previous_reviews_check() {
        local iteration
        iteration=$(load_iteration)
        # Use shared archive function (outputs archive path to stderr for logging)
        archive_reviews "$REVIEW_DIR" "$REVIEWS_DIR" "$iteration"
    }

    # --- Clean state for re-review ---
    clean_for_rerun() {
        # Archive reviews with current iteration
        local current_iter
        current_iter=$(load_iteration)
        archive_reviews "$REVIEW_DIR" "$REVIEWS_DIR" "$current_iter"

        # Increment iteration for next round
        local next_iter=$((current_iter + 1))
        save_iteration "$next_iter"

        # Update state in-place (don't delete - preserves config, mode, owner)
        if [[ -f "$STATE_FILE" ]]; then
            local now
            now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            local tmp="${STATE_FILE}.tmp.$$"
            jq --arg now "$now" '
                .status = "pending"
                | .reviewers = {}
                | .consensus = null
                | .decision = null
                | .created_at = $now
            ' "$STATE_FILE" > "$tmp"
            mv "$tmp" "$STATE_FILE"
        fi

        # Clear reviews directory
        rm -rf "$REVIEWS_DIR" 2>/dev/null || true
        mkdir -p "$REVIEWS_DIR" 2>/dev/null || true
    }

    # --- Check status (if state exists) ---
    STATUS="unknown"
    if [[ -f "$STATE_FILE" ]]; then
        STATUS=$(jq -r '.status // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown")
    fi

    # If resolved or passed, allow stop WITHOUT auto-respawn
    # Edits after pass/resolve require explicit spawn-plan-review call
    if [[ "$STATUS" == "resolved" || "$STATUS" == "passed" ]]; then
        log "review-gate: status $STATUS"

        local detected_type
        detected_type=$(detect_review_type)
        local file_changed=false

        # Check if underlying file changed (for informational logging only)
        if [[ "$detected_type" == "plan" ]]; then
            local plan_path stored_plan_sha current_plan_sha
            plan_path=$(jq -r '.mode.plan_path // empty' "$STATE_FILE" 2>/dev/null || echo "")

            if [[ -n "$plan_path" && -f "$plan_path" ]]; then
                stored_plan_sha=$(jq -r '.artifact.plan_sha // empty' "$STATE_FILE" 2>/dev/null || echo "")
                current_plan_sha=$(compute_sha256 "$plan_path" 2>/dev/null || echo "")

                if [[ -n "$stored_plan_sha" && -n "$current_plan_sha" && "$stored_plan_sha" != "$current_plan_sha" ]]; then
                    file_changed=true
                    log "review-gate: plan file changed after $STATUS (not auto-respawning)"
                fi
            fi
        elif [[ "$detected_type" == "spec" ]]; then
            local spec_path stored_spec_sha current_spec_sha
            spec_path=$(jq -r '.mode.spec_path // empty' "$STATE_FILE" 2>/dev/null || echo "")

            if [[ -n "$spec_path" && -f "$spec_path" ]]; then
                stored_spec_sha=$(jq -r '.artifact.spec_sha // empty' "$STATE_FILE" 2>/dev/null || echo "")
                current_spec_sha=$(compute_sha256 "$spec_path" 2>/dev/null || echo "")

                if [[ -n "$stored_spec_sha" && -n "$current_spec_sha" && "$stored_spec_sha" != "$current_spec_sha" ]]; then
                    file_changed=true
                    log "review-gate: spec file changed after $STATUS (not auto-respawning)"
                fi
            fi
        fi

        # Allow stop regardless of file changes - no auto-respawn after pass/resolve
        # If user wants re-review, they must explicitly call spawn-plan-review
        if [[ "$file_changed" == "true" ]]; then
            log "review-gate: allowing stop; re-run 'review-gate spawn-plan-review' to review changes"
        fi
        output_allow
    fi

    # --- Artifact exists but no state file → spawn reviewers ---
    if [[ ! -f "$STATE_FILE" ]]; then
        log "review-gate: spawning reviewers (no state)"
        # spawn_reviewers either returns 0 (success) or exits via output_allow/output_block
        # If it somehow returns non-zero, block to avoid silently disabling enforcement
        if ! spawn_reviewers; then
            log "review-gate: spawn failed unexpectedly with no existing state"
            output_block "Review gate error: failed to spawn reviewers. Check configuration and reviewer availability."
        fi
    else
        # --- State exists but pending with no reviewers → re-spawn ---
        local status reviewers_count
        status=$(jq -r '.status // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown")
        reviewers_count=$(jq -r '.reviewers | keys | length' "$STATE_FILE" 2>/dev/null || echo "0")

        if [[ "$status" == "pending" && "$reviewers_count" == "0" ]]; then
            log "review-gate: re-spawning reviewers (pending state with no reviewers)"
            export REVIEW_GATE_RERUN=1
            if ! spawn_reviewers; then
                # Spawn failed - block to avoid silently disabling enforcement
                # spawn_reviewers normally exits via output_allow/output_block, so this is defensive
                log "review-gate: re-spawn failed unexpectedly"
                output_block "Review gate error: failed to re-spawn reviewers. Check configuration and reviewer availability."
            fi
        fi
    fi

    # --- Check progress of reviewers ---
    check_progress_raw() {
        local reviewers
        reviewers=$(jq -r '.reviewers | keys[]' "$STATE_FILE" 2>/dev/null || echo "")

        local total=0
        local completed=0
        local running_list=()
        local completed_list=()

        for reviewer in $reviewers; do
            ((total++)) || true

            local sentinel_file="$REVIEWS_DIR/${reviewer}.done"
            local failed_file="$REVIEWS_DIR/${reviewer}.failed"
            local output_file="$REVIEWS_DIR/${reviewer}.json"

            if [[ -f "$sentinel_file" ]] || [[ -f "$failed_file" ]]; then
                ((completed++)) || true
                completed_list+=("$reviewer")
            else
                running_list+=("$reviewer")
            fi
        done

        local running="${running_list[*]-}"
        log "review-gate: progress completed=$completed total=$total running=$running"
        echo "$completed|$total|$running"
    }

    # --- Extract telemetry from completed reviewers ---
    _extract_reviewer_telemetry() {
        # Skip if telemetry functions not available
        if ! declare -f safe_extract_telemetry >/dev/null 2>&1; then
            log "review-gate: telemetry extraction skipped (telemetry-lib not loaded)"
            return 0
        fi

        local reviewers
        reviewers=$(jq -r '.reviewers | keys[]' "$STATE_FILE" 2>/dev/null || echo "")
        [[ -z "$reviewers" ]] && return 0

        local current_iter iter_dir
        current_iter=$(load_iteration 2>/dev/null || echo "0")
        iter_dir="${TELEMETRY_ITER_DIR:-$REVIEW_DIR/iterations/$current_iter}"

        # Ensure iteration directory exists
        if [[ ! -d "$iter_dir/agents" ]]; then
            mkdir -p "$iter_dir/agents" 2>/dev/null || return 0
        fi

        for reviewer in $reviewers; do
            # Normalize reviewer name to canonical agent (claude, codex, gemini)
            # This ensures telemetry is stored in the expected directories
            local base_agent="$reviewer"
            if [[ "$reviewer" == claude* ]]; then
                base_agent="claude"
            elif [[ "$reviewer" == codex* ]]; then
                base_agent="codex"
            elif [[ "$reviewer" == gemini* ]]; then
                base_agent="gemini"
            fi

            # Read .json file for telemetry (.done is an empty sentinel file)
            local output_file="$REVIEWS_DIR/${reviewer}.json"
            local agent_dir="$iter_dir/agents/$base_agent"

            # Skip if already extracted for this agent
            if [[ -f "$agent_dir/stats.json" ]]; then
                log "review-gate: telemetry already extracted for $base_agent (reviewer: $reviewer)"
                continue
            fi

            mkdir -p "$agent_dir" 2>/dev/null || continue

            # Try to extract telemetry from output file if present
            if [[ -f "$output_file" ]]; then
                local stats
                stats=$(safe_extract_telemetry "$reviewer" "$output_file" 2>/dev/null) || stats=""
                if [[ -n "$stats" && "$stats" != "{}" ]]; then
                    # Ensure stats is compact JSON for safe passing to functions
                    stats=$(printf '%s' "$stats" | jq -c '.' 2>/dev/null) || stats=""
                    if [[ -n "$stats" && "$stats" != "{}" ]]; then
                        printf '%s' "$stats" > "$agent_dir/stats.json" 2>/dev/null || true
                        cp "$output_file" "$agent_dir/raw.json" 2>/dev/null || true
                        log "review-gate: extracted telemetry for $base_agent (reviewer: $reviewer)"

                        # Update run telemetry with compact JSON using canonical agent name
                        if declare -f update_run_telemetry >/dev/null 2>&1; then
                            update_run_telemetry "$REVIEW_DIR" "$current_iter" "$base_agent" "$stats" 2>/dev/null || true
                        fi
                    fi
                fi
            fi

            # Copy processed review output as draft
            if [[ -f "$output_file" ]]; then
                cp "$output_file" "$agent_dir/review.json" 2>/dev/null || true
            fi

            # Archive the JSONL transcript as raw.jsonl so safe_extract_telemetry's
            # sibling-lookup works on archived files (it strips .json and appends .jsonl).
            local transcript_file="${output_file%.json}.jsonl"
            if [[ -f "$transcript_file" ]]; then
                cp "$transcript_file" "$agent_dir/raw.jsonl" 2>/dev/null || true
            fi
        done
    }

    # --- Calculate consensus (PRIORITY-BASED with configurable mode) ---
    # Consensus modes:
    #   all      - All reviewers must PASS (unanimous)
    #   any      - At least one reviewer PASS (optimistic)
    #   majority - Default. At least 2 PASS, or all valid PASS (priority-aware)
    #
    # P0/P1 findings always block regardless of mode
    # FAIL verdict always blocks regardless of mode
    calculate_consensus() {
        local reviewers
        reviewers=$(jq -r '.reviewers | keys[]' "$STATE_FILE" 2>/dev/null || echo "")

        # Read consensus mode from state (default: majority)
        local consensus_mode
        consensus_mode=$(jq -r '.config.consensus_mode // "majority"' "$STATE_FILE" 2>/dev/null || echo "majority")
        if [[ -z "$consensus_mode" || "$consensus_mode" == "null" ]]; then
            consensus_mode="majority"
        fi

        local pass_count=0
        local fail_count=0
        local needs_work_count=0  # Used for logging split vote details
        local other_count=0
        local reviewer_count=0
        local max_priority=99  # Track highest (lowest number) priority across all reviewers

        for reviewer in $reviewers; do
            local output_file="$REVIEWS_DIR/${reviewer}.json"
            local failed_file="$REVIEWS_DIR/${reviewer}.failed"
            local result=""

            if [[ -f "$failed_file" ]]; then
                if [[ -f "$output_file" ]] && \
                   result=$(extract_valid_review_json_no_repair "$output_file" "$reviewer" 2>/dev/null); then
                    log "review-gate: ignoring stale failed sentinel for $reviewer; valid reviewer JSON parsed"
                else
                    ((other_count++)) || true
                    ((reviewer_count++)) || true
                    continue
                fi
            elif [[ ! -f "$output_file" ]]; then
                ((other_count++)) || true
                ((reviewer_count++)) || true
                continue
            elif ! result=$(extract_json "$output_file" "$reviewer" 2>/dev/null); then
                ((other_count++)) || true
                ((reviewer_count++)) || true
                continue
            fi

            local verdict
            verdict=$(echo "$result" | jq -r '.verdict // "UNCLEAR"' 2>/dev/null || echo "UNCLEAR")
            if [[ -z "$verdict" || "$verdict" == "null" ]]; then
                verdict="UNCLEAR"
            fi

            # Extract highest priority from findings.
            #
            # Normalize both numeric `0..3` and string `"P0".."P3"` to a
            # canonical numeric form before computing `min`, then surface
            # the numeric integer the rest of the calculator expects.
            # Spec L212 (R6 priority gate): any P0/P1 in any active
            # final-round reviewer's output, at any confidence,
            # MUST trigger requires_decision regardless of consensus
            # mode. Reviewers may emit either form (the schema permits
            # both today, and debate.sh's aggregate normalization
            # explicitly does NOT mutate per-reviewer JSONs at L2863-L2866),
            # so the priority gate has to recognize both at the hook
            # boundary or string `"P1"` is silently downgraded to "no
            # P0/P1 present" and the gate may auto-approve.
            local highest_priority
            highest_priority=$(echo "$result" | jq -r '
                def to_pri_num:
                    if type == "number" then
                        (if . == 0 or . == 1 or . == 2 or . == 3 then . else 99 end)
                    elif type == "string" then
                        (if . == "P0" then 0
                         elif . == "P1" then 1
                         elif . == "P2" then 2
                         elif . == "P3" then 3
                         else 99 end)
                    else 99 end;
                [.findings[]?.priority | to_pri_num] | min // 99
            ' 2>/dev/null || echo "99")
            if [[ "$highest_priority" =~ ^[0-9]+$ ]] && [[ "$highest_priority" -lt "$max_priority" ]]; then
                max_priority="$highest_priority"
            fi

            case "$verdict" in
                PASS)
                    ((pass_count++)) || true
                    ;;
                FAIL)
                    ((fail_count++)) || true
                    ;;
                NEEDS_WORK)
                    ((needs_work_count++)) || true
                    ;;
                *)
                    ((other_count++)) || true
                    ;;
            esac

            ((reviewer_count++)) || true
        done

        # Need at least 1 valid reviewer (not errored)
        local valid_count=$((pass_count + fail_count + needs_work_count))
        if [[ $valid_count -lt 1 ]]; then
            log "review-gate: consensus=requires_decision (no valid reviewers)"
            echo "requires_decision"
            return
        fi

        # Strict: any FAIL verdict → requires_decision (even without P0 finding)
        if [[ $fail_count -gt 0 ]]; then
            log "review-gate: consensus=requires_decision (FAIL verdict detected, mode=$consensus_mode)"
            echo "requires_decision"
            return
        fi

        # Priority-based blocking (applies to all modes):
        # P0 anywhere → requires_decision (FAIL-level)
        if [[ "$max_priority" -eq 0 ]]; then
            log "review-gate: consensus=requires_decision (P0 finding detected, mode=$consensus_mode)"
            echo "requires_decision"
            return
        fi

        # P1 anywhere → requires_decision (must fix before proceeding)
        if [[ "$max_priority" -eq 1 ]]; then
            log "review-gate: consensus=requires_decision (P1 finding detected, mode=$consensus_mode)"
            echo "requires_decision"
            return
        fi

        # Apply consensus mode logic (no P0/P1 blocking issues at this point)
        case "$consensus_mode" in
            all)
                # All valid reviewers must PASS
                if [[ $pass_count -eq $valid_count ]]; then
                    if [[ $other_count -gt 0 ]]; then
                        log "review-gate: consensus=auto_approve (all valid reviewers PASS, $other_count errored, mode=all)"
                    else
                        log "review-gate: consensus=auto_approve (all reviewers PASS, mode=all)"
                    fi
                    echo "auto_approve"
                    return
                fi
                log "review-gate: consensus=requires_decision (not all PASS: pass=$pass_count/$valid_count, mode=all)"
                echo "requires_decision"
                ;;
            any)
                # At least one PASS is sufficient
                if [[ $pass_count -ge 1 ]]; then
                    log "review-gate: consensus=auto_approve ($pass_count PASS, mode=any)"
                    echo "auto_approve"
                    return
                fi
                log "review-gate: consensus=requires_decision (no PASS verdicts, mode=any)"
                echo "requires_decision"
                ;;
            majority|*)
                # Default majority logic:
                # All valid reviewers PASS → auto-approve (ignore errored reviewers)
                if [[ $pass_count -eq $valid_count ]]; then
                    if [[ $other_count -gt 0 ]]; then
                        log "review-gate: consensus=auto_approve (all valid reviewers PASS, $other_count errored, mode=majority)"
                    fi
                    echo "auto_approve"
                    return
                fi

                # No P0/P1, but some NEEDS_WORK votes with only P2/P3 findings:
                # If at least 2 reviewers say PASS, treat as auto_approve (P2/P3 are advisory)
                if [[ "$max_priority" -ge 2 ]] && [[ $pass_count -ge 2 ]]; then
                    log "review-gate: consensus=auto_approve (no P0/P1, $pass_count PASS, P2/P3 advisory, mode=majority)"
                    echo "auto_approve"
                    return
                fi

                # No P0/P1, split opinion but not enough PASS votes → still requires_decision
                if [[ "$max_priority" -ge 2 ]]; then
                    log "review-gate: consensus=requires_decision (no P0/P1 findings, split votes: pass=$pass_count needs_work=$needs_work_count other=$other_count, mode=majority)"
                fi

                echo "requires_decision"
                ;;
        esac
    }

    # --- Format results table ---
    #
    # T011 (Phase F.1) renderer extension: when `aggregate.json` exists in
    # $REVIEWS_DIR (debate runs only) the renderer prepends a one-line
    # "Debate: round N/N (strategies: ...)" indicator + an aggregate-verdict
    # line above the per-reviewer table, and appends a `Strategy` column
    # rightmost in the per-reviewer table. The Stop-hook consensus
    # calculator (calculate_consensus, lines ~924-1080) is UNCHANGED — the
    # renderer extension lives entirely inside this function and the
    # collect_aggregate_issues helper below; the calculator's input
    # (per-reviewer JSON files in $REVIEWS_DIR) and output (PASS/FAIL/
    # requires_decision) are byte-identical regardless of debate state.
    # Per spec L388 / plan L73 (Stop-hook is decision authority).
    format_results() {
        local reviewers
        reviewers=$(jq -r '.reviewers | keys[]' "$STATE_FILE" 2>/dev/null || echo "")

        # Detect debate run via aggregate.json presence. Debate runs only
        # write aggregate.json on the success path (degraded-below-2 hard
        # errors before promotion, so aggregate.json is absent and the
        # legacy non-debate renderer path runs — preserving byte-parity
        # with the pre-feature gate-report.md baseline for non-debate runs).
        local aggregate_file="$REVIEWS_DIR/aggregate.json"
        local is_debate=0
        if [[ -f "$aggregate_file" ]]; then
            is_debate=1
        fi

        local prefix=""
        if [[ $is_debate -eq 1 ]]; then
            local rounds_consumed
            rounds_consumed=$(jq -r '.rounds_consumed // empty' "$aggregate_file" 2>/dev/null || echo "")

            # Strategies rendered in canonical alphabetical order by
            # reviewer name, in the short forms the spec pins
            # (verification-first → verify, falsification-first → falsify,
            # decompose → decompose). Per spec L357 / Decisions Made L388.
            local strategies_csv
            strategies_csv=$(jq -r '
                def short($s):
                    if $s == "verification-first" then "verify"
                    elif $s == "falsification-first" then "falsify"
                    elif $s == "decompose" then "decompose"
                    else $s end;
                (.strategies // {})
                | to_entries | sort_by(.key) | map(short(.value)) | join("/")
            ' "$aggregate_file" 2>/dev/null || echo "")

            if [[ -n "$rounds_consumed" ]]; then
                prefix+="Debate: round ${rounds_consumed}/${rounds_consumed}"
                if [[ -n "$strategies_csv" ]]; then
                    prefix+=" (strategies: $strategies_csv)"
                fi
                prefix+=$'\n'
            fi

            # Verdict-authority split rendering (spec R6 Decision authority,
            # plan L73, task-context Implementation Notes). aggregate.json.verdict
            # is the cross-reviewer presentation surface; the Stop-hook's
            # consensus calculator is the SINGLE decision authority for gate
            # pass/fail. The two values live in different domains
            # (aggregate.verdict ∈ {PASS, NEEDS_WORK, FAIL};
            #  Stop-hook consensus ∈ {auto_approve, requires_decision}),
            # so the renderer ALWAYS displays them side-by-side and labels
            # the Stop-hook value as authoritative — making the decision-
            # authority split unambiguous to humans regardless of whether
            # the values "agree in spirit." Per spec L376 (Verdict authority).
            #
            # The rare "true" divergence (2-reviewer 1-1 PASS/NEEDS_WORK
            # with confidence-driven aggregate tiebreak picking PASS while
            # Stop-hook returns requires_decision) is the case the plan's
            # risk register flags; the unconditional side-by-side rendering
            # surfaces that case automatically without a conditional branch.
            local agg_verdict
            agg_verdict=$(jq -r '.verdict // ""' "$aggregate_file" 2>/dev/null || echo "")
            local consensus="${CONSENSUS:-}"
            if [[ -z "$consensus" ]]; then
                consensus=$(jq -r '.consensus.verdict // ""' "$STATE_FILE" 2>/dev/null || echo "")
            fi
            if [[ -n "$agg_verdict" ]]; then
                if [[ -n "$consensus" ]]; then
                    prefix+="Aggregate verdict: ${agg_verdict} | Stop-hook verdict (authoritative): ${consensus}"$'\n'
                else
                    prefix+="Aggregate verdict: ${agg_verdict}"$'\n'
                fi
            fi

            if [[ -n "$prefix" ]]; then
                prefix+=$'\n'
            fi
        fi

        local table=$'## Review Results\n\n'
        if [[ $is_debate -eq 1 ]]; then
            table+=$'| Reviewer | Verdict | Confidence | Summary | Strategy |\n'
            table+=$'|----------|---------|------------|--------|---------|\n'
        else
            table+=$'| Reviewer | Verdict | Confidence | Summary |\n'
            table+=$'|----------|---------|------------|--------|\n'
        fi

        for reviewer in $reviewers; do
            local output_file="$REVIEWS_DIR/${reviewer}.json"
            local failed_file="$REVIEWS_DIR/${reviewer}.failed"

            local verdict="UNCLEAR"
            local confidence="-"
            local summary="No response"
            local result=""

            if [[ -f "$failed_file" ]]; then
                if [[ -f "$output_file" ]] && \
                   result=$(extract_valid_review_json_no_repair "$output_file" "$reviewer" 2>/dev/null); then
                    :
                else
                    verdict="ERROR"
                    summary="Reviewer process failed"
                fi
            elif [[ -f "$output_file" ]]; then
                if ! result=$(extract_json "$output_file" "$reviewer" 2>/dev/null); then
                    verdict="ERROR"
                    summary="Invalid reviewer output"
                fi
            fi

            if [[ -n "$result" ]]; then
                verdict=$(echo "$result" | jq -r '.verdict // "UNCLEAR"' 2>/dev/null || echo "UNCLEAR")
                if [[ $is_debate -eq 1 ]]; then
                    # Debate per-reviewer JSONs carry overall_confidence
                    # (spec L357 — gate report shows overall_confidence
                    # only). Fall back to .confidence for forward-compat
                    # if a future debate variant ever omits it.
                    confidence=$(echo "$result" | jq -r '.overall_confidence // .confidence // "-"' 2>/dev/null || echo "-")
                else
                    confidence=$(echo "$result" | jq -r '.confidence // "-"' 2>/dev/null || echo "-")
                fi
                summary=$(echo "$result" | jq -r '.summary // "No summary"' 2>/dev/null || echo "No summary")

                if [[ -z "$verdict" || "$verdict" == "null" ]]; then
                    verdict="UNCLEAR"
                fi
                if [[ -z "$confidence" || "$confidence" == "null" ]]; then
                    confidence="-"
                fi
                if [[ -z "$summary" || "$summary" == "null" ]]; then
                    summary="No summary"
                fi

                # Truncate long summaries
                if [[ ${#summary} -gt 60 ]]; then
                    summary="${summary:0:57}..."
                fi
            fi

            if [[ $is_debate -eq 1 ]]; then
                local strategy_short="-"
                local strategy_full
                strategy_full=$(jq -r --arg r "$reviewer" '.strategies[$r] // empty' "$aggregate_file" 2>/dev/null || echo "")
                case "$strategy_full" in
                    verification-first) strategy_short="verify" ;;
                    falsification-first) strategy_short="falsify" ;;
                    decompose) strategy_short="decompose" ;;
                    "") strategy_short="-" ;;
                    *) strategy_short="$strategy_full" ;;
                esac
                table+="| $reviewer | $verdict | $confidence | $summary | $strategy_short |"$'\n'
            else
                table+="| $reviewer | $verdict | $confidence | $summary |"$'\n'
            fi
        done

        printf '%s%s' "$prefix" "$table"
    }

    # --- Collect issues from aggregate.json (debate runs only) ---
    #
    # T011 (Phase F.1): when aggregate.json exists, the renderer surfaces
    # the cross-reviewer-merged finding set sourced from
    # aggregate.json.findings[] as one card per defect, replacing the
    # per-reviewer concatenated-cards path (collect_issues) for debate
    # runs only. Each card includes the priority-prefixed title, optional
    # location (file_path + line range), confidence, raised_by indicator
    # (only when ≥2 reviewers raised the merged finding), and the body.
    # Per spec L357 / plan L213 (aggregate.json single source of cross-
    # reviewer presentation).
    collect_aggregate_issues() {
        local aggregate_file="$REVIEWS_DIR/aggregate.json"
        if [[ ! -f "$aggregate_file" ]]; then
            return 0
        fi

        local cards
        cards=$(jq -r '
            def loc:
                if (.file_path // "") != "" then
                    "  \nlocation: " + .file_path
                    + (if (.line_start // null) != null then
                        ":\(.line_start)"
                        + (if (.line_end // null) != null and .line_end != .line_start then
                            "-\(.line_end)"
                          else "" end)
                       else "" end)
                else "" end;
            def conf:
                if (.confidence // null) != null then
                    "  \nconfidence: " + (.confidence | tostring)
                else "" end;
            def raisedby:
                if (.raised_by // null) != null and ((.raised_by | length) >= 2) then
                    "  \nraised_by: " + (.raised_by | join(", "))
                else "" end;
            def head:
                "### "
                + (if (.priority // "") != "" then "[\(.priority)] " else "" end)
                + (.title // "Finding");
            (.findings // [])
            | map(head + raisedby + loc + conf + "\n\n" + (.body // ""))
            | join("\n\n")
        ' "$aggregate_file" 2>/dev/null || echo "")

        if [[ -n "$cards" ]]; then
            printf '%s\n' "$cards"
        fi
    }

    # --- Collect all issues from reviews ---
    collect_issues() {
        local reviewers
        reviewers=$(jq -r '.reviewers | keys[]' "$STATE_FILE" 2>/dev/null || echo "")

        local all_issues=""

        for reviewer in $reviewers; do
            local output_file="$REVIEWS_DIR/${reviewer}.json"
            local failed_file="$REVIEWS_DIR/${reviewer}.failed"

            if [[ -f "$failed_file" ]]; then
                if [[ ! -f "$output_file" ]] || \
                   ! extract_valid_review_json_no_repair "$output_file" "$reviewer" >/dev/null 2>&1; then
                    continue
                fi
            fi

            if [[ -f "$output_file" ]]; then
                local result
                if ! result=$(extract_json "$output_file" "$reviewer" 2>/dev/null); then
                    continue
                fi

                local verdict
                verdict=$(echo "$result" | jq -r '.verdict // "UNCLEAR"' 2>/dev/null || echo "UNCLEAR")
                if [[ -z "$verdict" || "$verdict" == "null" ]]; then
                    verdict="UNCLEAR"
                fi

                # Collect findings from non-PASS reviews, or P2/P3 findings from PASS reviews
                local dominated_by_pass=false
                if [[ "$verdict" == "PASS" ]]; then
                    # For PASS verdicts, only include if there are P2/P3 findings
                    local p2p3_findings
                    # Normalize priority across numeric `0..3` and string `"P0".."P3"`
                    # forms before filtering / rendering, per spec L212 R6 priority
                    # gate (reviewer outputs may use either form; the schema permits
                    # both and aggregate normalization does NOT mutate per-reviewer
                    # JSONs at debate.sh L2863-L2866).
                    p2p3_findings=$(echo "$result" | jq -r '
                        def to_pri_num:
                            if type == "number" then
                                (if . == 0 or . == 1 or . == 2 or . == 3 then . else null end)
                            elif type == "string" then
                                (if . == "P0" then 0
                                 elif . == "P1" then 1
                                 elif . == "P2" then 2
                                 elif . == "P3" then 3
                                 else null end)
                            else null end;
                        .findings // []
                        | map(. + {_pn: (.priority | to_pri_num)})
                        | map(select(._pn != null and ._pn >= 2))
                        | .[]
                        | "[P\(._pn)] " + (.title // "No title") + ": " + (.body // "")
                    ' 2>/dev/null || echo "")
                    if [[ -n "$p2p3_findings" ]]; then
                        all_issues+=$'### '"$reviewer ($verdict - minor issues)"$'\n'
                        while IFS= read -r finding; do
                            all_issues+="- $finding"$'\n'
                        done <<< "$p2p3_findings"
                        all_issues+=$'\n'
                    fi
                else
                    local findings
                    findings=$(echo "$result" | jq -r '.findings // [] | .[] | (.title // "No title") + ": " + (.body // "")' 2>/dev/null || echo "")

                    if [[ -n "$findings" ]]; then
                        all_issues+=$'### '"$reviewer ($verdict)"$'\n'
                        while IFS= read -r finding; do
                            all_issues+="- $finding"$'\n'
                        done <<< "$findings"
                        all_issues+=$'\n'
                    fi
                fi
            fi
        done

        printf '%s' "$all_issues"
    }

    # --- Collect blocking (P0/P1) issues from non-PASS reviews ---
    collect_blocking_issues() {
        local reviewers
        reviewers=$(jq -r '.reviewers | keys[]' "$STATE_FILE" 2>/dev/null || echo "")

        local all_issues=""

        for reviewer in $reviewers; do
            local output_file="$REVIEWS_DIR/${reviewer}.json"
            local failed_file="$REVIEWS_DIR/${reviewer}.failed"

            if [[ -f "$failed_file" ]]; then
                if [[ ! -f "$output_file" ]] || \
                   ! extract_valid_review_json_no_repair "$output_file" "$reviewer" >/dev/null 2>&1; then
                    continue
                fi
            fi

            if [[ -f "$output_file" ]]; then
                local result
                if ! result=$(extract_json "$output_file" "$reviewer" 2>/dev/null); then
                    log "review-gate: blocking issues: invalid reviewer output for $reviewer"
                    continue
                fi

                local verdict
                verdict=$(echo "$result" | jq -r '.verdict // "UNCLEAR"' 2>/dev/null || echo "UNCLEAR")
                if [[ -z "$verdict" || "$verdict" == "null" ]]; then
                    verdict="UNCLEAR"
                fi

                if [[ "$verdict" == "PASS" ]]; then
                    continue
                fi
                if [[ "$verdict" == "UNCLEAR" ]]; then
                    log "review-gate: blocking issues: skipping $reviewer due to UNCLEAR verdict"
                    continue
                fi

                local findings
                # Normalize priority across numeric `0..3` and string
                # `"P0".."P3"` forms (spec L212 R6) before selecting blocking
                # findings, so the priority gate, the select() filter, and
                # the title-prefix all see a consistent numeric value
                # regardless of which form the reviewer emitted.
                findings=$(echo "$result" | jq -r '
                    def to_pri_num:
                        if type == "number" then
                            (if . == 0 or . == 1 or . == 2 or . == 3 then . else null end)
                        elif type == "string" then
                            (if . == "P0" then 0
                             elif . == "P1" then 1
                             elif . == "P2" then 2
                             elif . == "P3" then 3
                             else null end)
                        else null end;
                    def normalize_title($t; $p):
                      if ($t // "") == "" then
                        if $p != null then "[P" + ($p|tostring) + "]" else "Finding" end
                      else
                        if $t|test("^\\[P[0-3]\\]") then $t
                        elif $p != null then "[P" + ($p|tostring) + "] " + $t
                        else $t
                        end
                      end;
                    .findings // []
                    | map(. + {_pn: (.priority | to_pri_num)})
                    | map(select(
                        if ._pn != null then ._pn <= 1
                        else ((.title // "") | test("\\[P[01]\\]"))
                        end
                      ))
                    | .[]
                    | normalize_title(.title; ._pn) + ": " + (.body // "")
                ' 2>/dev/null || echo "")

                if [[ -n "$findings" ]]; then
                    all_issues+=$'### '"$reviewer ($verdict)"$'\n'
                    while IFS= read -r finding; do
                        all_issues+="- $finding"$'\n'
                    done <<< "$findings"
                    all_issues+=$'\n'
                fi
            fi
        done

        printf '%s' "$all_issues"
    }

    # --- Collect informational (P2/P3) findings from all reviewers ---
    collect_informational_findings() {
        local reviewers
        reviewers=$(jq -r '.reviewers | keys[]' "$STATE_FILE" 2>/dev/null || echo "")

        local info=""

        for reviewer in $reviewers; do
            local output_file="$REVIEWS_DIR/${reviewer}.json"
            local failed_file="$REVIEWS_DIR/${reviewer}.failed"

            if [[ -f "$failed_file" ]]; then
                if [[ ! -f "$output_file" ]] || \
                   ! extract_valid_review_json_no_repair "$output_file" "$reviewer" >/dev/null 2>&1; then
                    continue
                fi
            fi

            if [[ -f "$output_file" ]]; then
                local result
                if ! result=$(extract_json "$output_file" "$reviewer" 2>/dev/null); then
                    log "review-gate: informational findings: invalid reviewer output for $reviewer"
                    continue
                fi

                local verdict
                verdict=$(echo "$result" | jq -r '.verdict // "UNCLEAR"' 2>/dev/null || echo "UNCLEAR")
                if [[ -z "$verdict" || "$verdict" == "null" ]]; then
                    verdict="UNCLEAR"
                fi
                if [[ "$verdict" == "UNCLEAR" ]]; then
                    log "review-gate: informational findings: skipping $reviewer due to UNCLEAR verdict"
                    continue
                fi

                local findings
                # Normalize priority across numeric `0..3` and string
                # `"P0".."P3"` forms (spec L212 R6) for the same reason as
                # collect_blocking_issues — string priorities must not be
                # silently routed to the wrong bucket.
                findings=$(echo "$result" | jq -r '
                    def to_pri_num:
                        if type == "number" then
                            (if . == 0 or . == 1 or . == 2 or . == 3 then . else null end)
                        elif type == "string" then
                            (if . == "P0" then 0
                             elif . == "P1" then 1
                             elif . == "P2" then 2
                             elif . == "P3" then 3
                             else null end)
                        else null end;
                    def normalize_title($t; $p):
                      if ($t // "") == "" then
                        if $p != null then "[P" + ($p|tostring) + "]" else "Finding" end
                      else
                        if $t|test("^\\[P[0-3]\\]") then $t
                        elif $p != null then "[P" + ($p|tostring) + "] " + $t
                        else $t
                        end
                      end;
                    .findings // []
                    | map(. + {_pn: (.priority | to_pri_num)})
                    | map(select(
                        if ._pn != null then ._pn >= 2
                        else ((.title // "") | test("\\[P[23]\\]"))
                        end
                      ))
                    | .[]
                    | normalize_title(.title; ._pn) + ": " + (.body // "")
                ' 2>/dev/null || echo "")

                if [[ -n "$findings" ]]; then
                    info+=$'### '"$reviewer"$'\n'
                    while IFS= read -r finding; do
                        info+="- $finding"$'\n'
                    done <<< "$findings"
                    info+=$'\n'
                fi
            fi
        done

        if [[ -n "$info" ]]; then
            cat <<INFO
## Informational Items (P2/P3)

The following non-blocking items were noted for your awareness:

$info
INFO
        fi
    }

    # --- Resolve revision template ---
    resolve_revision_template() {
        local type="$1"

        local project_root
        project_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

        local search_paths=(
            "$project_root/prompts/revisions/${type}.md"
            "$SCRIPT_DIR/../prompts/revisions/${type}.md"
        )

        for path in "${search_paths[@]}"; do
            if [[ -f "$path" ]]; then
                cat "$path"
                return 0
            fi
        done

        return 1
    }

    # --- Safe template substitution using awk ---
    # Handles special chars (&, \, newlines) that break sed/bash expansion
    # Uses ENVIRON to avoid awk -v backslash interpretation and ARG_MAX limits
    substitute_template() {
        local template="$1"
        local placeholder="$2"
        local replacement="$3"

        # Use ENVIRON to pass values safely (no backslash interpretation, no ARG_MAX)
        SUBST_PLACEHOLDER="$placeholder" \
        SUBST_REPLACEMENT="$replacement" \
        awk '
        BEGIN {
            placeholder = ENVIRON["SUBST_PLACEHOLDER"]
            replacement = ENVIRON["SUBST_REPLACEMENT"]
        }
        {
            line = $0
            idx = index(line, placeholder)
            while (idx > 0) {
                printf "%s%s", substr(line, 1, idx - 1), replacement
                line = substr(line, idx + length(placeholder))
                idx = index(line, placeholder)
            }
            print line
        }
        ' <<< "$template"
    }

    # --- Generate commit instructions based on diff mode ---
    generate_commit_instructions() {
        local diff_args="$1"

        # Parse the diff mode from diff_args
        case "$diff_args" in
            --uncommitted|"")
                echo "Keep your fixes **uncommitted** (do NOT create a commit). The review is tracking uncommitted changes."
                ;;
            --base*)
                echo "You **MUST create a NEW commit** with your fixes. The review is tracking changes from the base branch to HEAD, so uncommitted changes will NOT be visible to reviewers. Do NOT use \`git commit --amend\`."
                ;;
            --commit*)
                echo "You **MUST create a NEW commit** with your fixes. Do NOT use \`git commit --amend\` (amending changes the commit SHA and breaks review tracking)."
                ;;
            *)
                # Assume it's a range like main..feature
                echo "You **MUST create a NEW commit** with your fixes. The review is tracking a commit range, so uncommitted changes will NOT be visible. Do NOT use \`git commit --amend\`."
                ;;
        esac
    }

    # --- Map trigger source to revision template type ---
    # Some trigger sources (healthcheck, architecture-review, etc.) don't have
    # dedicated revision templates, so we map them to the closest match.
    map_trigger_to_template() {
        local trigger="$1"
        local mode_type="$2"
        case "$trigger" in
            code|plan|spec|epic-verify|ask)
                echo "$trigger"
                ;;
            healthcheck|architecture-review|create-tasks)
                # Document-based reviews use plan template
                echo "plan"
                ;;
            ""|null|artifact|auto|manual)
                # Infer from mode_type
                case "$mode_type" in
                    code-diff) echo "code" ;;
                    plan) echo "plan" ;;
                    spec) echo "spec" ;;
                    epic-verify) echo "epic-verify" ;;
                    *) echo "plan" ;;  # Default to plan for document reviews
                esac
                ;;
            *)
                log "review-gate: WARNING: unknown trigger_source '$trigger' (mode=$mode_type); defaulting to 'plan'"
                echo "plan"
                ;;
        esac
    }

    # --- Format revision instructions based on trigger type ---
    format_revision_instructions() {
        local trigger_source="$1"
        local issues="$2"
        local mode_plan_path="$3"
        local mode_spec_path="${4:-}"
        local mode_diff_args="${5:-}"

        # Get mode_type from state for mapping
        local mode_type=""
        if [[ -f "$STATE_FILE" ]]; then
            mode_type=$(jq -r '.mode.type // empty' "$STATE_FILE" 2>/dev/null || echo "")
        fi

        local template_type
        template_type=$(map_trigger_to_template "$trigger_source" "$mode_type")
        log "review-gate: mapping trigger '$trigger_source' (mode=$mode_type) to template '$template_type'"

        case "$template_type" in
            code)
                local template result commit_instructions
                commit_instructions=$(generate_commit_instructions "$mode_diff_args")
                template=$(resolve_revision_template "code") || { log "review-gate: FATAL: code revision template not found"; return 1; }
                result=$(substitute_template "$template" '${ISSUES}' "$issues")
                result=$(substitute_template "$result" '${DIFF_ARGS}' "$mode_diff_args")
                result=$(substitute_template "$result" '${COMMIT_INSTRUCTIONS}' "$commit_instructions")
                echo "$result"
                ;;
            plan)
                local plan_display="$mode_plan_path"
                [[ -z "$plan_display" ]] && plan_display="the plan"
                local template result
                template=$(resolve_revision_template "plan") || { log "review-gate: FATAL: plan revision template not found"; return 1; }
                result=$(substitute_template "$template" '${PLAN_PATH}' "$plan_display")
                result=$(substitute_template "$result" '${ISSUES}' "$issues")
                echo "$result"
                ;;
            spec)
                local spec_display="$mode_spec_path"
                [[ -z "$spec_display" ]] && spec_display="the spec"
                local template result
                template=$(resolve_revision_template "spec") || { log "review-gate: FATAL: spec revision template not found"; return 1; }
                result=$(substitute_template "$template" '${SPEC_PATH}' "$spec_display")
                result=$(substitute_template "$result" '${ISSUES}' "$issues")
                echo "$result"
                ;;
            epic-verify)
                local template result
                template=$(resolve_revision_template "epic-verify") || { log "review-gate: FATAL: epic-verify revision template not found"; return 1; }
                result=$(substitute_template "$template" '${ISSUES}' "$issues")
                echo "$result"
                ;;
            ask)
                cat <<ASK_REVISION
The model panel could not fully converge on the answer.

Review the panel feedback above, answer the user's original prompt as well as possible, and call out any caveats that materially affect the recommendation. If the prompt needs clarification, ask the user directly or re-run /cerberus:ask with a narrower prompt.
ASK_REVISION
                ;;
        esac
    }

    # Check if all reviewers are complete (optionally wait/poll)
    START_TIME=$(date +%s)
    while true; do
        PROGRESS=$(check_progress_raw)
        IFS='|' read -r COMPLETED TOTAL RUNNING <<< "$PROGRESS"

        if [[ "$COMPLETED" -ge "$TOTAL" ]]; then
            log "review-gate: reviewers complete"
            # Extract telemetry from completed reviewers
            _extract_reviewer_telemetry || true
            break
        fi

        if [[ "$MAX_WAIT_SECONDS" -gt 0 ]]; then
            NOW=$(date +%s)
            ELAPSED=$((NOW - START_TIME))
            if [[ "$ELAPSED" -ge "$MAX_WAIT_SECONDS" ]]; then
                progress_msg="Review gate: ${COMPLETED}/${TOTAL} reviewers complete."
                if [[ -n "$RUNNING" ]]; then
                    progress_msg+=" Waiting for: $RUNNING"
                fi
                log "review-gate: timeout after ${ELAPSED}s"
                output_block "$progress_msg"
            fi
            sleep "$POLL_INTERVAL_SECONDS"
            continue
        fi

        progress_msg="Review gate: ${COMPLETED}/${TOTAL} reviewers complete."
        if [[ -n "$RUNNING" ]]; then
            progress_msg+=" Waiting for: $RUNNING"
        fi
        output_block "$progress_msg"
    done

    # Calculate consensus
    CONSENSUS=$(calculate_consensus)

    # Get current iteration
    CURRENT_ITERATION=$(get_iteration)

    # Write iteration telemetry after consensus
    if declare -f write_iteration_telemetry >/dev/null 2>&1; then
        local iter_dir="${TELEMETRY_ITER_DIR:-$REVIEW_DIR/iterations/$CURRENT_ITERATION}"
        write_iteration_telemetry "$iter_dir" "awaiting_decision" "$CONSENSUS" 2>/dev/null || true
        log "review-gate: wrote iteration telemetry (consensus=$CONSENSUS)"
    fi

    # Get trigger source and mode info for revision messages
    TRIGGER_SOURCE=$(jq -r '.trigger_source // "artifact"' "$STATE_FILE" 2>/dev/null || echo "artifact")
    MODE_PLAN_PATH=$(jq -r '.mode.plan_path // ""' "$STATE_FILE" 2>/dev/null || echo "")
    CONSENSUS_MODE=$(jq -r '.config.consensus_mode // "majority"' "$STATE_FILE" 2>/dev/null || echo "majority")
    [[ -z "$CONSENSUS_MODE" || "$CONSENSUS_MODE" == "null" ]] && CONSENSUS_MODE="majority"

    # Update state to awaiting_decision
    TEMP_FILE="${STATE_FILE}.tmp.$$"
    trap 'rm -f "${TEMP_FILE:-}"' EXIT

    jq --arg status "awaiting_decision" \
       --arg consensus "$CONSENSUS" \
       --argjson iteration "$CURRENT_ITERATION" \
       '.status = $status | .consensus = {verdict: $consensus, iteration: $iteration}' \
       "$STATE_FILE" > "$TEMP_FILE"
    mv "$TEMP_FILE" "$STATE_FILE"

    # Format output
    RESULTS=$(format_results)

    if [[ "$CONSENSUS" == "auto_approve" ]]; then
        reset_iteration
        CLAUDE_SESSION_ID="$SESSION_ID" \
            REVIEW_GATE_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" \
            "$0" resolve >&2 || true

        # Update run telemetry on auto_approve resolution
        if declare -f update_run_telemetry_on_resolve >/dev/null 2>&1; then
            update_run_telemetry_on_resolve "$REVIEW_DIR" "auto_approve" "consensus_passed" 2>/dev/null || true
            log "review-gate: updated run telemetry on auto_approve"
        fi

        # Debate runs surface findings from aggregate.json (one card per
        # merged defect) per spec L357. Non-debate runs use the legacy
        # per-reviewer collect_issues path so the gate-report.md byte-
        # parity baseline (bin/tests/fixtures/pre-debate-baseline/) is
        # preserved.
        if [[ -f "$REVIEWS_DIR/aggregate.json" ]]; then
            ALL_ISSUES=$(collect_aggregate_issues)
        else
            ALL_ISSUES=$(collect_issues)
        fi

        # Get telemetry summary for output message
        local telemetry_summary=""
        if declare -f get_telemetry_summary_for_output >/dev/null 2>&1; then
            telemetry_summary=$(get_telemetry_summary_for_output "$REVIEW_DIR" 2>/dev/null) || telemetry_summary=""
        fi

        # Prompt Claude for summary before allowing stop
        local pass_msg
        case "$CONSENSUS_MODE" in
            all)  pass_msg="All valid reviewers passed (consensus=all)." ;;
            any)  pass_msg="At least one reviewer passed (consensus=any)." ;;
            *)    pass_msg="Review passed (consensus=majority)." ;;
        esac
        SUMMARY_PROMPT="$RESULTS

---

## Review Complete

**$pass_msg**"
        if [[ $CURRENT_ITERATION -gt 1 ]]; then
            SUMMARY_PROMPT+=" (after $CURRENT_ITERATION iterations)"
        fi
        if [[ -n "$telemetry_summary" ]]; then
            SUMMARY_PROMPT+="

*$telemetry_summary*"
        fi
        if [[ -n "$ALL_ISSUES" ]]; then
            SUMMARY_PROMPT+="

## Review Findings

$ALL_ISSUES

Please address any issues above, then provide a brief summary of the review outcome."
        else
            SUMMARY_PROMPT+="

Please provide a brief summary of the review outcome, then you may stop."
        fi
        output_block "$SUMMARY_PROMPT"
    else
        # Check iteration limit
        if [[ $CURRENT_ITERATION -ge $MAX_ITERATIONS ]]; then
            log "review-gate: max iterations reached"
            if [[ -f "$REVIEWS_DIR/aggregate.json" ]]; then
                ALL_ISSUES=$(collect_aggregate_issues)
            else
                ALL_ISSUES=$(collect_issues)
            fi
            CLAUDE_SESSION_ID="$SESSION_ID" \
                REVIEW_GATE_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" \
                "$0" resolve --reason auto_proceed_max_iter >&2 || true

            # Update run telemetry on max_iterations resolution
            if declare -f update_run_telemetry_on_resolve >/dev/null 2>&1; then
                update_run_telemetry_on_resolve "$REVIEW_DIR" "auto_proceed" "max_iterations" 2>/dev/null || true
                log "review-gate: updated run telemetry on max_iterations"
            fi
            if [[ "$MAX_ITERATIONS" -eq 0 ]]; then
                # max-rounds=0: Just output results without max-iterations messaging
                REASON="$RESULTS"
                if [[ -n "$ALL_ISSUES" ]]; then
                    REASON+="

## Review Findings

$ALL_ISSUES"
                fi
                REASON+="

Please summarize the review outcome."
            else
                REASON="$RESULTS

---

## Max Iterations Reached

**Max iterations ($MAX_ITERATIONS) reached without consensus.** The gate has been auto-resolved to proceed."
                if [[ -n "$ALL_ISSUES" ]]; then
                    REASON+="

## Remaining Issues

$ALL_ISSUES

**You *MUST* fix all remaining issues above before stopping.** Then summarize the review outcome, noting that max iterations was reached."
                else
                    REASON+="

Please summarize the review outcome, noting that max iterations was reached."
                fi
            fi

            output_block "$REASON"
            exit 0
        fi

        # Collect all issues. Debate runs use aggregate.json's
        # cross-reviewer-merged finding set per spec L357; non-debate
        # runs use the legacy per-reviewer path (preserves byte-parity).
        if [[ -f "$REVIEWS_DIR/aggregate.json" ]]; then
            ALL_ISSUES=$(collect_aggregate_issues)
        else
            ALL_ISSUES=$(collect_issues)
        fi

        # Extract mode paths/args BEFORE cleaning state (which deletes STATE_FILE)
        MODE_SPEC_PATH=$(jq -r '.mode.spec_path // ""' "$STATE_FILE" 2>/dev/null || echo "")
        MODE_DIFF_ARGS=$(jq -r '.mode.diff_args // ""' "$STATE_FILE" 2>/dev/null || echo "")

        # Clean state so reviewers will be re-spawned after revision
        # (Archive uses the current iteration number, so do this before incrementing.)
        clean_for_rerun

        log "review-gate: revision required; incremented iteration"

        # Format type-specific revision instructions (using extracted paths/args)
        REVISION_INSTRUCTIONS=$(format_revision_instructions "$TRIGGER_SOURCE" "$ALL_ISSUES" "$MODE_PLAN_PATH" "$MODE_SPEC_PATH" "$MODE_DIFF_ARGS")

        local required_msg
        case "$CONSENSUS_MODE" in
            all)  required_msg="All reviewers must agree (PASS) before proceeding." ;;
            any)  required_msg="At least one reviewer must pass, with no blocking issues (consensus=any)." ;;
            *)    required_msg="Majority of reviewers must pass before proceeding (consensus=majority)." ;;
        esac
        REASON="$RESULTS

---

## Revision Required (Iteration $((CURRENT_ITERATION + 1))/$MAX_ITERATIONS)

**$required_msg**

$REVISION_INSTRUCTIONS"

        output_block "$REASON"
    fi
}
