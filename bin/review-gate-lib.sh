#!/usr/bin/env bash
# Shared helpers for review-gate.

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

# Unwrap review JSON from various wrapper formats
unwrap_review_json() {
    local json="$1"
    if [[ -z "$json" ]]; then
        return 1
    fi

    if echo "$json" | jq -e '.structured_output' >/dev/null 2>&1; then
        json=$(echo "$json" | jq -c '.structured_output' 2>/dev/null || echo "")
    fi

    if [[ -n "$json" ]] && echo "$json" | jq -e '.response' >/dev/null 2>&1; then
        local response
        response=$(echo "$json" | jq -r '.response' 2>/dev/null || echo "")
        if [[ -n "$response" ]] && echo "$response" | jq -e . >/dev/null 2>&1; then
            json=$(echo "$response" | jq -c '.' 2>/dev/null || echo "")
        fi
    fi

    if [[ -z "$json" ]]; then
        return 1
    fi

    echo "$json"
}

# Find active review gate for current project
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
