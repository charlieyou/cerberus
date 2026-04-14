#!/usr/bin/env bash
# Shared helpers for review-gate.

# Fallback log for library context when hook log isn't available.
if ! declare -f log >/dev/null 2>&1; then
    log() { echo "[review-gate-lib] $*" >&2; }
fi

# Source telemetry-lib.sh for init_iteration_dir and other telemetry functions
# This ensures a single authoritative implementation is used
_REVIEW_GATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_REVIEW_GATE_LIB_DIR/telemetry-lib.sh" ]]; then
    source "$_REVIEW_GATE_LIB_DIR/telemetry-lib.sh" 2>/dev/null || true
fi

# Get project hash from transcript path or calculate from project root
get_project_hash() {
    local transcript_path="${1:-}"

    if [[ -n "$transcript_path" ]]; then
        local dir_name
        dir_name=$(basename "$(dirname "$transcript_path")")
        if [[ "$dir_name" == -* ]]; then
            echo "$dir_name"
            return 0
        fi
    fi

    local project_root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    echo "$project_root" | sed 's|^/|-|' | tr '/' '-'
}

# Resolve the review directory for a session
resolve_review_dir() {
    local session_id="${1:-}"
    local transcript_path="${2:-}"

    local project_hash
    project_hash=$(get_project_hash "$transcript_path")

    local base_dir="$HOME/.claude/projects/$project_hash/cerberus"

    if [[ -n "$session_id" ]]; then
        echo "$base_dir/$session_id"
    else
        echo "$base_dir"
    fi
}

# Get project-level review base directory
get_review_base_dir() {
    resolve_review_dir "" "${1:-}"
}

iso8601_to_epoch() {
    local timestamp="${1:-}"
    local epoch=""

    if [[ -z "$timestamp" ]]; then
        echo 0
        return 0
    fi

    epoch=$(python3 - "$timestamp" <<'PY' 2>/dev/null || true
import datetime
import sys

timestamp = sys.argv[1]

try:
    dt = datetime.datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
except ValueError:
    raise SystemExit(1)

print(int(dt.timestamp()))
PY
)
    if [[ "$epoch" =~ ^[0-9]+$ ]]; then
        echo "$epoch"
        return 0
    fi

    epoch=$(date -d "$timestamp" +%s 2>/dev/null || true)
    if [[ "$epoch" =~ ^[0-9]+$ ]]; then
        echo "$epoch"
        return 0
    fi

    echo 0
}

# Archive previous reviews to a timestamped directory
archive_reviews() {
    local review_dir="$1"
    local reviews_dir="$2"
    local iteration="${3:-0}"

    if [[ ! -d "$reviews_dir" ]]; then
        return 0
    fi

    local has_reviews=false
    for f in "$reviews_dir"/*.json; do
        if [[ -f "$f" ]]; then
            has_reviews=true
            break
        fi
    done

    if [[ "$has_reviews" != "true" ]]; then
        return 0
    fi

    local archive_dir="$review_dir/reviews-iter-${iteration}"

    if [[ -d "$archive_dir" ]]; then
        local ts
        ts=$(date +%Y%m%d-%H%M%S)
        archive_dir="$review_dir/reviews-iter-${iteration}-${ts}"
    fi

    mv "$reviews_dir" "$archive_dir"
    echo "$archive_dir" >&2
    return 0
}

# Load iteration from state or iteration.txt (state is authoritative)
load_iteration() {
    local review_dir="${1:-$REVIEW_DIR}"
    local state_file="$review_dir/gate-state.json"
    local iter_file="$review_dir/iteration.txt"

    if [[ -f "$state_file" ]]; then
        local iter
        iter=$(jq -r '.iteration // empty' "$state_file" 2>/dev/null || echo "")
        if [[ "$iter" =~ ^[0-9]+$ ]]; then
            if [[ -f "$iter_file" ]]; then
                local file_iter
                file_iter=$(cat "$iter_file" 2>/dev/null || echo "")
                if [[ "$file_iter" != "$iter" ]]; then
                    log "review-gate: WARNING: iteration.txt ($file_iter) diverged from state ($iter), using state"
                fi
            fi
            echo "$iter"
            return 0
        fi
    fi

    if [[ -f "$iter_file" ]]; then
        local iter
        iter=$(cat "$iter_file" 2>/dev/null || echo "")
        if [[ "$iter" =~ ^[0-9]+$ ]]; then
            echo "$iter"
            return 0
        fi
    fi

    echo "0"
}

# Save iteration to iteration.txt and update state if present
save_iteration() {
    local iter="$1"
    local review_dir="${2:-$REVIEW_DIR}"
    local state_file="$review_dir/gate-state.json"
    local iter_file="$review_dir/iteration.txt"

    echo "$iter" > "$iter_file"

    if [[ -f "$state_file" ]]; then
        local tmp="${state_file}.tmp.$$"
        jq --argjson iter "$iter" '.iteration = $iter' "$state_file" > "$tmp"
        mv "$tmp" "$state_file"
    fi
}

# Unwrap review JSON from various wrapper formats
# NOTE: Uses printf '%s' instead of echo to preserve backslash escapes in JSON
unwrap_review_json() {
    local json="$1"
    if [[ -z "$json" ]]; then
        return 1
    fi

    if printf '%s' "$json" | jq -e '.structured_output' >/dev/null 2>&1; then
        json=$(printf '%s' "$json" | jq -c '.structured_output' 2>/dev/null || echo "")
    fi

    if [[ -n "$json" ]] && printf '%s' "$json" | jq -e '.response' >/dev/null 2>&1; then
        local response
        response=$(printf '%s' "$json" | jq -r '.response' 2>/dev/null || echo "")
        if [[ -n "$response" ]]; then
            # Try direct JSON parse first
            if printf '%s' "$response" | jq -e . >/dev/null 2>&1; then
                json=$(printf '%s' "$response" | jq -c '.' 2>/dev/null || echo "")
            else
                # Response may be prose with embedded JSON - extract last JSON object
                local extracted
                extracted=$(printf '%s' "$response" | python3 -c '
import json, sys
text = sys.stdin.read()
decoder = json.JSONDecoder()
last_obj = None
for i, ch in enumerate(text):
    if ch != "{":
        continue
    try:
        obj, _ = decoder.raw_decode(text[i:])
        if isinstance(obj, dict) and "verdict" in obj:
            last_obj = obj
    except:
        pass
if last_obj:
    print(json.dumps(last_obj))
' 2>/dev/null || echo "")
                if [[ -n "$extracted" ]] && printf '%s' "$extracted" | jq -e . >/dev/null 2>&1; then
                    json="$extracted"
                fi
            fi
        fi
    fi

    if [[ -z "$json" ]]; then
        return 1
    fi

    printf '%s' "$json"
}

# Find active review gate for current project
# Also matches recently auto-resolved gates (from max iterations) so manual override works
find_active_gate() {
    local transcript_path="${1:-}"
    local base_dir
    base_dir=$(get_review_base_dir "$transcript_path")

    [[ ! -d "$base_dir" ]] && return 1

    for session_dir in "$base_dir"/*/; do
        [[ ! -d "$session_dir" ]] && continue
        local state_file="$session_dir/gate-state.json"
        [[ ! -f "$state_file" ]] && continue

        local status
        status=$(jq -r '.status // "unknown"' "$state_file" 2>/dev/null || echo "unknown")

        if [[ "$status" == "pending" || "$status" == "awaiting_decision" ]]; then
            basename "$session_dir"
            return 0
        fi

        # Also match recently auto-resolved gates (max iterations) so manual override works
        if [[ "$status" == "resolved" ]]; then
            local reason
            reason=$(jq -r '.decision.reason // ""' "$state_file" 2>/dev/null || echo "")
            if [[ "$reason" == "auto_proceed_max_iter" ]]; then
                # Check if resolved recently (< 30 min ago) using decided_at timestamp
                local decided_at
                decided_at=$(jq -r '.decision.decided_at // ""' "$state_file" 2>/dev/null || echo "")
                if [[ -n "$decided_at" ]]; then
                    local decided_epoch now_epoch age_seconds
                    decided_epoch=$(iso8601_to_epoch "$decided_at")
                    now_epoch=$(date +%s)
                    age_seconds=$((now_epoch - decided_epoch))
                    if [[ $age_seconds -lt 1800 ]]; then
                        basename "$session_dir"
                        return 0
                    fi
                fi
            fi
        fi
    done

    return 1
}

# --- Helper: Compute sha256 (portable-ish) ---
compute_sha256() {
    local file="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | cut -d' ' -f1
        return 0
    fi

    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | cut -d' ' -f1
        return 0
    fi

    return 1
}

# --- Telemetry Integration Helpers ---
# Note: init_iteration_dir is provided by telemetry-lib.sh (sourced above)

# Write iteration telemetry summary
# Usage: write_iteration_telemetry "$iter_dir" "$status" "$consensus"
write_iteration_telemetry() {
    local iter_dir="$1"
    local status="$2"
    local consensus="$3"
    
    # Aggregate stats from agents
    local total_tokens=0
    local total_cost=0
    
    for stats_file in "$iter_dir"/agents/*/stats.json; do
        [[ -f "$stats_file" ]] || continue
        local tokens cost
        tokens=$(jq -r '((.tokens.input // 0) + (.tokens.output // 0))' "$stats_file" 2>/dev/null || echo "0")
        cost=$(jq -r '.cost_usd // 0' "$stats_file" 2>/dev/null || echo "0")
        total_tokens=$((total_tokens + tokens))
        # Use awk for floating point addition
        total_cost=$(awk "BEGIN {printf \"%.6f\", $total_cost + $cost}" 2>/dev/null || echo "$total_cost")
    done
    
    # Write iteration.json atomically
    if ! jq -n \
        --arg status "$status" \
        --arg consensus "$consensus" \
        --argjson total_tokens "$total_tokens" \
        --argjson total_cost "$total_cost" \
        '{
            status: $status,
            consensus: $consensus,
            tokens: $total_tokens,
            cost_usd: $total_cost,
            completed_at: (now | todate)
        }' > "$iter_dir/iteration.json.tmp.$$" 2>/dev/null; then
        log "review-gate: WARNING: failed to write iteration telemetry"
        rm -f "$iter_dir/iteration.json.tmp.$$"
        return 1
    fi
    mv "$iter_dir/iteration.json.tmp.$$" "$iter_dir/iteration.json"
    log "review-gate: wrote iteration telemetry: $iter_dir/iteration.json"
}

# Update run telemetry when review gate resolves
# Usage: update_run_telemetry_on_resolve "$review_dir" "$decision" "$reason"
update_run_telemetry_on_resolve() {
    local review_dir="$1"
    local decision="$2"
    local reason="$3"
    
    # Source telemetry-lib.sh if not already loaded
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if ! declare -f resolve_run_telemetry >/dev/null 2>&1; then
        if [[ -f "$script_dir/telemetry-lib.sh" ]]; then
            source "$script_dir/telemetry-lib.sh" || {
                log "review-gate: WARNING: failed to source telemetry-lib.sh"
                return 1
            }
        else
            log "review-gate: WARNING: telemetry-lib.sh not found"
            return 1
        fi
    fi

    # Use telemetry-lib function to record resolution
    resolve_run_telemetry "$review_dir" "$decision" "$reason" || true
    log "review-gate: updated run telemetry on resolve: decision=$decision reason=$reason"
}

# Get human-readable telemetry summary
# Usage: get_telemetry_summary_for_output "$review_dir"
get_telemetry_summary_for_output() {
    local review_dir="$1"
    local run_telemetry="$review_dir/run-telemetry.json"
    
    if [[ ! -f "$run_telemetry" ]]; then
        echo ""
        return
    fi
    
    local tokens cost iterations
    tokens=$(jq -r '((.totals.tokens.input // 0) + (.totals.tokens.output // 0))' "$run_telemetry" 2>/dev/null || echo "0")
    cost=$(jq -r '.totals.cost_usd // 0' "$run_telemetry" 2>/dev/null || echo "0")
    iterations=$(jq -r '.iterations | length' "$run_telemetry" 2>/dev/null || echo "0")
    
    printf 'Telemetry: %d tokens, $%.4f across %d iteration(s)' "$tokens" "$cost" "$iterations"
}
