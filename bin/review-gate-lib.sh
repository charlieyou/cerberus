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

# Get project hash from transcript path or calculate from project root.
# Host-neutral extension: when CERBERUS_PROJECT_KEY is set and non-empty it is
# echoed verbatim and existing fallbacks are skipped. Empty strings are treated
# as unset (matches the existing ${VAR:-} idiom — see plan §Alias precedence).
# Validation of the returned key (path-traversal rejection) lives in
# resolve_review_dir() so the validation surface is a single chokepoint.
get_project_hash() {
    local transcript_path="${1:-}"

    # Neutral override (plan L360-L363).
    if [[ -n "${CERBERUS_PROJECT_KEY:-}" ]]; then
        echo "$CERBERUS_PROJECT_KEY"
        return 0
    fi

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

# Resolve the review directory for a session.
#
# Host-neutral resolver — implements the algorithm from plan §State Resolution
# Algorithm (L300-L353). When no CERBERUS_* env is set the result is byte-for-
# byte equivalent to the legacy Claude path (~/.claude/projects/<hash>/cerberus
# /<session-id>). Per Phase 0 plan, this resolver is the single chokepoint for
# host detection, state-root selection, project-key validation, and run-key
# fallback.
#
# Arguments:
#   $1  session_id      legacy positional run-key fallback (used by the Claude
#                       path when neither CERBERUS_RUN_KEY nor
#                       REVIEW_GATE_SESSION_KEY is set)
#   $2  transcript_path optional transcript path, fed to get_project_hash()
#
# Validation failures (invalid CERBERUS_HOST, non-absolute CERBERUS_STATE_ROOT,
# path-traversal in run/project key) emit a single log() line on stderr and
# return 1. Empty CERBERUS_STATE_ROOT is treated as unset per the "empty as
# unset" rule (plan §Alias precedence). T004 wires the negative-path
# diagnostics into bin/review-gate's state-creation surface; T001 only
# enforces resolver-level validation here.
resolve_review_dir() {
    local session_id="${1:-}"
    local transcript_path="${2:-}"

    # Step 1: resolve effective run key.
    # Delegate to __cerberus_resolve_run_key when bin/review-gate has loaded
    # it (the canonical definition lives near the top of bin/review-gate).
    # When the lib is sourced standalone (test fixtures, future helpers) we
    # fall back to direct env reads with the same precedence — but no
    # alias-mismatch warning here, because the warning is owned by
    # __cerberus_resolve_run_key and guarded by __CERBERUS_ALIAS_WARNED to
    # avoid double-firing across the helper and this fallback.
    local run_key=""
    if declare -f __cerberus_resolve_run_key >/dev/null 2>&1; then
        run_key="$(__cerberus_resolve_run_key)"
    else
        run_key="${CERBERUS_RUN_KEY:-${REVIEW_GATE_SESSION_KEY:-}}"
    fi
    if [[ -z "$run_key" ]]; then
        run_key="$session_id"
    fi

    # Step 1b: validate run-key (path-traversal rejection). An empty run_key
    # is allowed and yields the project-base path; only reject explicit unsafe
    # forms.
    if [[ -n "$run_key" ]]; then
        case "$run_key" in
            */*|.|..)
                log "review-gate: invalid run key '$run_key' (must not contain '/' or be '.'/'..')"
                return 1
                ;;
        esac
    fi

    # Step 2: resolve effective host.
    # Auto-detect: CLAUDE_* env, OR a non-empty transcript_path positional
    # arg (which Claude callers pass even without exporting CLAUDE_* — this
    # is what the existing test fixtures rely on for byte-for-byte parity).
    # Plan §Phase 0 row 7 covers the default-generic case explicitly with no
    # CLAUDE_* AND no transcript_path arg.
    local host="${CERBERUS_HOST:-}"
    if [[ -z "$host" ]]; then
        if [[ -n "${CLAUDE_SESSION_ID:-}" || -n "${CLAUDE_TRANSCRIPT_PATH:-}" \
              || -n "${CLAUDE_PROJECT_DIR:-}" || -n "$transcript_path" ]]; then
            host="claude"
        else
            host="generic"
        fi
    fi
    case "$host" in
        claude|codex|amp|generic) ;;
        *)
            log "review-gate: invalid CERBERUS_HOST='$host' (expected one of claude|codex|amp|generic)"
            return 1
            ;;
    esac

    # Step 3: resolve state root.
    local state_root
    local custom_root="${CERBERUS_STATE_ROOT:-}"
    if [[ -n "$custom_root" ]]; then
        # Reject literal ~ (no shell-side expansion in this env path) and any
        # non-absolute path. Empty strings are unset (handled by ${VAR:-}).
        if [[ "$custom_root" == "~"* || "$custom_root" != /* ]]; then
            log "review-gate: invalid CERBERUS_STATE_ROOT='$custom_root' (must be an absolute path; literal '~' is not expanded)"
            return 1
        fi
        state_root="$custom_root"
    elif [[ "$host" == "claude" ]]; then
        state_root="$HOME/.claude/projects"
    else
        state_root="$HOME/.cerberus/projects"
    fi

    # Step 4: resolve project key.
    local project_key
    project_key=$(get_project_hash "$transcript_path")
    case "$project_key" in
        ""|.|..)
            log "review-gate: invalid project key '$project_key' (must not be empty, '.', or '..')"
            return 1
            ;;
        */*)
            log "review-gate: invalid project key '$project_key' (must not contain '/')"
            return 1
            ;;
    esac

    # Step 5: build path. Claude keeps the legacy "/cerberus" infix for
    # byte-for-byte compatibility; neutral hosts use the flatter neutral
    # layout described in plan §Data Model.
    local base
    if [[ "$host" == "claude" ]]; then
        base="$state_root/$project_key/cerberus"
    else
        base="$state_root/$project_key"
    fi

    if [[ -n "$run_key" ]]; then
        echo "$base/$run_key"
    else
        echo "$base"
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

# get_iteration_dir — return the iterations/<iter>/ path under a review_dir
# WITHOUT creating it. Read-only counterpart to telemetry-lib.sh's
# init_iteration_dir helper, used by debate-mode telemetry surfaces that
# need the iter_dir path before init has run (or that don't want to
# create the directory as a side effect of a path lookup).
#
# Why this is needed (debate-mode partial-state path): the debate
# coordinator's degraded-preflight branch may need to compute the
# iterations/<iter>/ path before any round has spawned a reviewer, in
# order to write iterations/<iter>/debate-telemetry.json. init_iteration_dir
# is path-creating and side-effecting; this helper is path-only.
#
# Args:
#   $1  review_dir   absolute path to a session's $REVIEW_DIR
#   $2  iteration    integer (defaults to 0)
#
# Output (stdout): the unverified iterations/<iter>/ path.
# Returns 1 if review_dir is missing.
get_iteration_dir() {
    local review_dir="$1"
    local iteration="${2:-0}"
    if [[ -z "$review_dir" ]]; then
        return 1
    fi
    printf '%s\n' "$review_dir/iterations/$iteration"
}

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
