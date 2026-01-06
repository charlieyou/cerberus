#!/usr/bin/env bash
# Hook-specific logic for review-gate.
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
    MAX_WAIT_SECONDS="${REVIEW_GATE_MAX_WAIT_SECONDS:-600}"
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
        mkdir -p "$(dirname "$LOG_FILE")"
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

    # --- Helper: Output allow (exit 0 with no output) ---
    output_allow() {
        log "review-gate: allowing stop"
        trap - ERR  # Clear error trap before explicit exit
        exit 0
    }

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
    PENDING_CMD=$(echo "$INPUT" | jq -r '.pending_tool_input.command // ""' 2>/dev/null || echo "")
    if [[ -n "$PENDING_CMD" ]]; then
        log "review-gate: pending_tool_input.command=$PENDING_CMD"
    fi
    if [[ "$PENDING_CMD" == *"review-gate resolve"* ]]; then
        log "review-gate: allow resolve command"
        output_allow
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

    # --- Helper: Extract diff-args from artifact frontmatter ---
    extract_diff_args() {
        if [[ -f "$ARTIFACT_FILE" ]]; then
            sed -n 's/^<!-- *diff-args: *\(.*\) *-->/\1/p' "$ARTIFACT_FILE" | head -1
        fi
    }

    # --- Helper: Extract base-sha from artifact frontmatter ---
    extract_base_sha() {
        if [[ -f "$ARTIFACT_FILE" ]]; then
            sed -n 's/^<!-- *base-sha: *\([^ ]*\) *-->/\1/p' "$ARTIFACT_FILE" | head -1
        fi
    }

    # --- Helper: Extract tip-sha from artifact frontmatter ---
    extract_tip_sha() {
        if [[ -f "$ARTIFACT_FILE" ]]; then
            sed -n 's/^<!-- *tip-sha: *\([^ ]*\) *-->/\1/p' "$ARTIFACT_FILE" | head -1
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
        if [[ "$state_max_rounds" =~ ^[0-9]+$ ]] && [[ "$state_max_rounds" -ge 1 ]]; then
            MAX_ITERATIONS="$state_max_rounds"
        else
            log "review-gate: invalid state max_rounds '$state_max_rounds' (using $MAX_ITERATIONS)"
        fi
    fi
    local max_rounds
    max_rounds=$(extract_max_rounds)
    if [[ -n "$max_rounds" ]]; then
        if [[ "$max_rounds" =~ ^[0-9]+$ ]] && [[ "$max_rounds" -ge 1 ]]; then
            MAX_ITERATIONS="$max_rounds"
        else
            log "review-gate: invalid max-rounds '$max_rounds' (using $MAX_ITERATIONS)"
        fi
    fi
    log "review-gate: max_iterations=$MAX_ITERATIONS"

    # --- Helper: Spawn reviewers for current artifact ---
    # Returns 0 on success (caller should proceed to polling), exits on error/resolved
    spawn_reviewers() {
        local detected_type
        detected_type=$(detect_review_type)
        log "review-gate: spawn reviewers (type=${detected_type:-none})"

        local spawn_success=false
        local agents_csv
        agents_csv=$(extract_agents)
        local -a agents_arg=()
        if [[ -n "$agents_csv" ]]; then
            agents_arg=(--agents "$agents_csv")
            log "review-gate: using agents filter '$agents_csv'"
        fi
        local max_rounds
        max_rounds=$(extract_max_rounds)
        local -a max_rounds_arg=()
        if [[ -n "$max_rounds" ]]; then
            if [[ "$max_rounds" =~ ^[0-9]+$ ]] && [[ "$max_rounds" -ge 1 ]]; then
                max_rounds_arg=(--max-rounds "$max_rounds")
                log "review-gate: using max-rounds '$max_rounds'"
            else
                log "review-gate: invalid max-rounds '$max_rounds' (ignoring)"
            fi
        fi

        local mode
        mode=$(extract_intelligence_mode)
        local -a mode_arg=()
        if [[ -n "$mode" ]]; then
            mode_arg=(--mode "$mode")
            log "review-gate: using mode '$mode'"
        fi

        local consensus_mode
        consensus_mode=$(jq -r '.config.consensus_mode // ""' "$STATE_FILE" 2>/dev/null || echo "")
        local -a consensus_arg=()
        if [[ -n "$consensus_mode" && "$consensus_mode" != "null" ]]; then
            consensus_arg=(--consensus "$consensus_mode")
            log "review-gate: using consensus '$consensus_mode'"
        fi

        # For code-review-iterative, re-fetch the diff to capture fixes
        if [[ "$detected_type" == "code-review-iterative" ]]; then
            local diff_args
            diff_args=$(extract_diff_args)
            log "review-gate: code-review-iterative re-spawn with diff_args='$diff_args'"
            local base_sha
            base_sha=$(extract_base_sha)
            local tip_sha
            tip_sha=$(extract_tip_sha)
            if [[ -n "$base_sha" ]]; then
                log "review-gate: code-review-iterative using base_sha=$base_sha"
            fi
            if [[ -n "$tip_sha" ]]; then
                log "review-gate: code-review-iterative using tip_sha=$tip_sha"
            fi

            # Parse diff_args into array safely (no eval to avoid command injection)
            # Note: This splits on whitespace, so args with spaces won't round-trip.
            # In practice, git diff args (--base, --commit, ranges) don't contain spaces.
            local -a args_array
            read -r -a args_array <<< "$diff_args"

            if REVIEW_GATE_SESSION_KEY="$SESSION_KEY" \
               REVIEW_GATE_SESSION_SOURCE="$SESSION_SOURCE" \
               CLAUDE_SESSION_ID="$SESSION_ID" \
               REVIEW_GATE_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" \
               REVIEW_GATE_BASE_SHA="$base_sha" \
               REVIEW_GATE_TIP_SHA="$tip_sha" \
               "$0" spawn-code-review "${agents_arg[@]}" "${max_rounds_arg[@]}" "${mode_arg[@]}" "${consensus_arg[@]}" "${args_array[@]}" >/dev/null 2>&1; then
                spawn_success=true
            fi
        # For plan-review-iterative, re-read the plan file to capture edits
        elif [[ "$detected_type" == "plan-review-iterative" ]]; then
            local plan_path
            plan_path=$(extract_plan_path_from_state)
            # Ignore state plan_path if it points to the artifact (legacy gates)
            if [[ "$plan_path" == "$ARTIFACT_FILE" ]] || [[ "$plan_path" == *"/latest.md" ]]; then
                plan_path=""
            fi
            [[ -z "$plan_path" ]] && plan_path=$(extract_plan_path)
            log "review-gate: plan-review-iterative re-spawn with plan_path='$plan_path'"

            if [[ -n "$plan_path" && -f "$plan_path" ]]; then
                if REVIEW_GATE_SESSION_KEY="$SESSION_KEY" \
                   REVIEW_GATE_SESSION_SOURCE="$SESSION_SOURCE" \
                   CLAUDE_SESSION_ID="$SESSION_ID" \
                   REVIEW_GATE_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" \
                   "$0" spawn-plan-review "${agents_arg[@]}" "${max_rounds_arg[@]}" "${mode_arg[@]}" "${consensus_arg[@]}" "$plan_path" >/dev/null 2>&1; then
                    spawn_success=true
                fi
            else
                log "review-gate: plan-review-iterative missing plan_path, falling back to artifact"
                if REVIEW_GATE_SESSION_KEY="$SESSION_KEY" \
                   REVIEW_GATE_SESSION_SOURCE="$SESSION_SOURCE" \
                   CLAUDE_SESSION_ID="$SESSION_ID" \
                   REVIEW_GATE_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" \
                   REVIEW_TYPE="$detected_type" \
                   "$0" spawn "${agents_arg[@]}" "${max_rounds_arg[@]}" "${mode_arg[@]}" "${consensus_arg[@]}" "$ARTIFACT_FILE" >/dev/null 2>&1; then
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
                if REVIEW_GATE_SESSION_KEY="$SESSION_KEY" \
                   REVIEW_GATE_SESSION_SOURCE="$SESSION_SOURCE" \
                   CLAUDE_SESSION_ID="$SESSION_ID" \
                   REVIEW_GATE_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" \
                   "$0" spawn-spec-review "${agents_arg[@]}" "${max_rounds_arg[@]}" "${mode_arg[@]}" "${consensus_arg[@]}" "$spec_path" >/dev/null 2>&1; then
                    spawn_success=true
                fi
            else
                log "review-gate: spec missing spec_path, falling back to artifact"
                if REVIEW_GATE_SESSION_KEY="$SESSION_KEY" \
                   REVIEW_GATE_SESSION_SOURCE="$SESSION_SOURCE" \
                   CLAUDE_SESSION_ID="$SESSION_ID" \
                   REVIEW_GATE_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" \
                   REVIEW_TYPE="$detected_type" \
                   "$0" spawn "${agents_arg[@]}" "${max_rounds_arg[@]}" "${mode_arg[@]}" "${consensus_arg[@]}" "$ARTIFACT_FILE" >/dev/null 2>&1; then
                    spawn_success=true
                fi
            fi
        else
            if REVIEW_GATE_SESSION_KEY="$SESSION_KEY" \
               REVIEW_GATE_SESSION_SOURCE="$SESSION_SOURCE" \
               CLAUDE_SESSION_ID="$SESSION_ID" \
               REVIEW_GATE_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" \
               REVIEW_TYPE="$detected_type" \
               "$0" spawn "${agents_arg[@]}" "${max_rounds_arg[@]}" "${mode_arg[@]}" "${consensus_arg[@]}" "$ARTIFACT_FILE" >/dev/null 2>&1; then
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
        rm -f "$STATE_FILE"
        rm -f "$ITERATION_FILE"
        rm -rf "$REVIEWS_DIR"
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
            CREATED_EPOCH=$(date -d "$CREATED_AT" +%s 2>/dev/null || echo 0)
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
        rm -rf "$REVIEWS_DIR"
        mkdir -p "$REVIEWS_DIR"
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
        if [[ "$detected_type" == "plan-review-iterative" ]]; then
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
        spawn_reviewers
    else
        # --- State exists but pending with no reviewers → re-spawn ---
        local status reviewers_count
        status=$(jq -r '.status // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown")
        reviewers_count=$(jq -r '.reviewers | keys | length' "$STATE_FILE" 2>/dev/null || echo "0")

        if [[ "$status" == "pending" && "$reviewers_count" == "0" ]]; then
            log "review-gate: re-spawning reviewers (pending state with no reviewers)"
            export REVIEW_GATE_RERUN=1
            spawn_reviewers
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

        log "review-gate: progress completed=$completed total=$total running=${running_list[*]}"
        echo "$completed|$total|${running_list[*]}"
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

            # Skip if reviewer failed
            if [[ -f "$failed_file" ]]; then
                ((other_count++)) || true
                ((reviewer_count++)) || true
                continue
            fi

            if [[ ! -f "$output_file" ]]; then
                ((other_count++)) || true
                ((reviewer_count++)) || true
                continue
            fi

            local result
            if ! result=$(extract_json "$output_file" "$reviewer" 2>/dev/null); then
                ((other_count++)) || true
                ((reviewer_count++)) || true
                continue
            fi

            local verdict
            verdict=$(echo "$result" | jq -r '.verdict // "UNCLEAR"' 2>/dev/null || echo "UNCLEAR")
            if [[ -z "$verdict" || "$verdict" == "null" ]]; then
                verdict="UNCLEAR"
            fi

            # Extract highest priority from findings
            local highest_priority
            highest_priority=$(echo "$result" | jq -r '[.findings[]?.priority // 99] | min // 99' 2>/dev/null || echo "99")
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
    format_results() {
        local reviewers
        reviewers=$(jq -r '.reviewers | keys[]' "$STATE_FILE" 2>/dev/null || echo "")

        local table=$'## Review Results\n\n'
        table+=$'| Reviewer | Verdict | Confidence | Summary |\n'
        table+=$'|----------|---------|------------|--------|\n'

        for reviewer in $reviewers; do
            local output_file="$REVIEWS_DIR/${reviewer}.json"
            local failed_file="$REVIEWS_DIR/${reviewer}.failed"

            local verdict="UNCLEAR"
            local confidence="-"
            local summary="No response"

            if [[ -f "$failed_file" ]]; then
                verdict="ERROR"
                summary="Reviewer process failed"
            elif [[ -f "$output_file" ]]; then
                local result
                if ! result=$(extract_json "$output_file" "$reviewer" 2>/dev/null); then
                    verdict="ERROR"
                    summary="Invalid reviewer output"
                else
                    verdict=$(echo "$result" | jq -r '.verdict // "UNCLEAR"' 2>/dev/null || echo "UNCLEAR")
                    confidence=$(echo "$result" | jq -r '.confidence // "-"' 2>/dev/null || echo "-")
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
                fi

                # Truncate long summaries
                if [[ ${#summary} -gt 60 ]]; then
                    summary="${summary:0:57}..."
                fi
            fi

            table+="| $reviewer | $verdict | $confidence | $summary |"$'\n'
        done

        printf '%s' "$table"
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
                continue
            fi

            if [[ -f "$output_file" ]]; then
                local result
                if ! result=$(extract_json "$output_file" "$reviewer" 2>/dev/null); then
                    all_issues+=$'### '"$reviewer (ERROR)"$'\n'
                    all_issues+=$'Summary: Invalid reviewer output\n\n'
                    continue
                fi

                local verdict
                verdict=$(echo "$result" | jq -r '.verdict // "UNCLEAR"' 2>/dev/null || echo "UNCLEAR")
                if [[ -z "$verdict" || "$verdict" == "null" ]]; then
                    verdict="UNCLEAR"
                fi

                # Only collect findings from non-PASS reviews
                if [[ "$verdict" != "PASS" ]]; then
                    local findings
                    findings=$(echo "$result" | jq -r '.findings // [] | .[] | (.title // "No title") + ": " + (.body // "")' 2>/dev/null || echo "")
                    local summary
                    summary=$(echo "$result" | jq -r '.summary // ""' 2>/dev/null || echo "")

                    if [[ -n "$findings" || -n "$summary" ]]; then
                        all_issues+=$'### '"$reviewer ($verdict)"$'\n'
                        if [[ -n "$summary" ]]; then
                            all_issues+="Summary: $summary"$'\n'
                        fi
                        if [[ -n "$findings" ]]; then
                            all_issues+=$'Findings:\n'
                            while IFS= read -r finding; do
                                all_issues+="- $finding"$'\n'
                            done <<< "$findings"
                        fi
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
                continue
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
                findings=$(echo "$result" | jq -r '
                    def normalize_title($t; $p):
                      if ($t // "") == "" then
                        if $p != null then "[P" + ($p|tostring) + "]" else "Finding" end
                      else
                        if $t|test("^\\[P[0-3]\\]") then $t
                        elif $p != null then "[P" + ($p|tostring) + "] " + $t
                        else $t
                        end
                      end;
                    .findings // [] |
                    map(select(
                      if .priority != null then (.priority | tonumber) <= 1
                      else ((.title // "") | test("\\[P[01]\\]"))
                      end
                    )) |
                    .[] |
                    normalize_title(.title; .priority) + ": " + (.body // "")
                ' 2>/dev/null || echo "")
                local summary
                summary=$(echo "$result" | jq -r '.summary // ""' 2>/dev/null || echo "")

                if [[ -n "$findings" ]]; then
                    all_issues+=$'### '"$reviewer ($verdict)"$'\n'
                    if [[ -n "$summary" ]]; then
                        all_issues+="Summary: $summary"$'\n'
                    fi
                    all_issues+=$'Findings:\n'
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
                continue
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
                findings=$(echo "$result" | jq -r '
                    def normalize_title($t; $p):
                      if ($t // "") == "" then
                        if $p != null then "[P" + ($p|tostring) + "]" else "Finding" end
                      else
                        if $t|test("^\\[P[0-3]\\]") then $t
                        elif $p != null then "[P" + ($p|tostring) + "] " + $t
                        else $t
                        end
                      end;
                    .findings // [] |
                    map(select(
                      if .priority != null then (.priority | tonumber) >= 2
                      else ((.title // "") | test("\\[P[23]\\]"))
                      end
                    )) |
                    .[] |
                    normalize_title(.title; .priority) + ": " + (.body // "")
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

    # --- Format revision instructions based on trigger type ---
    format_revision_instructions() {
        local trigger_source="$1"
        local issues="$2"
        local mode_plan_path="$3"
        local mode_spec_path="${4:-}"
        local mode_diff_args="${5:-}"

        case "$trigger_source" in
            code-review-iterative)
                local template result commit_instructions
                commit_instructions=$(generate_commit_instructions "$mode_diff_args")
                if template=$(resolve_revision_template "code"); then
                    result=$(substitute_template "$template" '${ISSUES}' "$issues")
                    result=$(substitute_template "$result" '${DIFF_ARGS}' "$mode_diff_args")
                    result=$(substitute_template "$result" '${COMMIT_INSTRUCTIONS}' "$commit_instructions")
                    echo "$result"
                else
                    # Fallback if template not found
                    cat <<INSTRUCTIONS
Please revise the **code** to address the following issues:

$issues

**Commit Policy ($mode_diff_args):**
$commit_instructions

**After fixing the code, STOP immediately.** The stop hook will automatically re-run the review.
INSTRUCTIONS
                fi
                ;;
            plan-review-iterative)
                local plan_display="$mode_plan_path"
                [[ -z "$plan_display" ]] && plan_display="the plan"
                local template result
                if template=$(resolve_revision_template "plan"); then
                    # Replace specific placeholders first to prevent injection
                    result=$(substitute_template "$template" '${PLAN_PATH}' "$plan_display")
                    result=$(substitute_template "$result" '${ISSUES}' "$issues")
                    echo "$result"
                else
                    cat <<INSTRUCTIONS
Please revise **$plan_display** to address the following issues:

$issues

**After updating the plan, STOP immediately.** The stop hook will spawn the next review round.
INSTRUCTIONS
                fi
                ;;
            spec)
                local spec_display="$mode_spec_path"
                [[ -z "$spec_display" ]] && spec_display="the spec"
                local template result
                if template=$(resolve_revision_template "spec"); then
                    # Replace specific placeholders first to prevent injection
                    result=$(substitute_template "$template" '${SPEC_PATH}' "$spec_display")
                    result=$(substitute_template "$result" '${ISSUES}' "$issues")
                    echo "$result"
                else
                    cat <<INSTRUCTIONS
Please revise **$spec_display** to address the following issues:

$issues

**After updating the spec, STOP immediately.** The stop hook will spawn the next review round.
INSTRUCTIONS
                fi
                ;;
            *)
                cat <<INSTRUCTIONS
Please revise the artifact to address the following issues:

$issues

**After updating the artifact, STOP immediately.** The stop hook will spawn the next review round.
INSTRUCTIONS
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
        INFO_ITEMS=$(collect_informational_findings)
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
        if [[ -n "$INFO_ITEMS" ]]; then
            SUMMARY_PROMPT+="

$INFO_ITEMS

These are non-blocking issues (P2/P3), but you **MUST** fix them before stopping. Please:
1. Address each P2/P3 issue listed above
2. Provide a brief summary of what you fixed
3. Then you may stop"
        else
            SUMMARY_PROMPT+="

Please provide a brief summary of the review outcome, then you may stop."
        fi
        output_block "$SUMMARY_PROMPT"
    else
        # Check iteration limit
        if [[ $CURRENT_ITERATION -ge $MAX_ITERATIONS ]]; then
            log "review-gate: max iterations reached"
            BLOCKING_ISSUES=$(collect_blocking_issues)
            INFO_ITEMS=$(collect_informational_findings)
            CLAUDE_SESSION_ID="$SESSION_ID" \
                REVIEW_GATE_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" \
                "$0" resolve --reason auto_proceed_max_iter >&2 || true
            REASON="$RESULTS

---

## Max Iterations Reached

**Max iterations ($MAX_ITERATIONS) reached without consensus.** The gate has been auto-resolved to proceed."
            if [[ -n "$BLOCKING_ISSUES" ]]; then
                REASON+="

### Remaining Issues (P0/P1)

$BLOCKING_ISSUES"
            else
                REASON+="

No remaining P0/P1 issues were reported by non-PASS reviewers."
            fi
            if [[ -n "$INFO_ITEMS" ]]; then
                REASON+="

$INFO_ITEMS"
            fi
            REASON+="

Please summarize the review outcome, noting that max iterations was reached and listing any unresolved issues."

            output_block "$REASON"
            exit 0
        fi

        # Collect issues from non-PASS reviews
        ISSUES=$(collect_issues)
        INFO_ITEMS=$(collect_informational_findings)

        # Extract mode paths/args BEFORE cleaning state (which deletes STATE_FILE)
        MODE_SPEC_PATH=$(jq -r '.mode.spec_path // ""' "$STATE_FILE" 2>/dev/null || echo "")
        MODE_DIFF_ARGS=$(jq -r '.mode.diff_args // ""' "$STATE_FILE" 2>/dev/null || echo "")

        # Clean state so reviewers will be re-spawned after revision
        # (Archive uses the current iteration number, so do this before incrementing.)
        clean_for_rerun

        log "review-gate: revision required; incremented iteration"

        # Format type-specific revision instructions (using extracted paths/args)
        REVISION_INSTRUCTIONS=$(format_revision_instructions "$TRIGGER_SOURCE" "$ISSUES" "$MODE_PLAN_PATH" "$MODE_SPEC_PATH" "$MODE_DIFF_ARGS")

        local required_msg
        case "$CONSENSUS_MODE" in
            all)  required_msg="All reviewers must agree (PASS) before proceeding." ;;
            any)  required_msg="At least one reviewer must pass, with no FAIL verdicts or P0/P1 findings blocking (consensus=any)." ;;
            *)    required_msg="Majority of reviewers must pass before proceeding (consensus=majority)." ;;
        esac
        REASON="$RESULTS

---

## Revision Required (Iteration $((CURRENT_ITERATION + 1))/$MAX_ITERATIONS)

**$required_msg**

$REVISION_INSTRUCTIONS"
        if [[ -n "$INFO_ITEMS" ]]; then
            REASON+="

$INFO_ITEMS"
        fi

        output_block "$REASON"
    fi
}
