#!/usr/bin/env bash
# review-gate-lib.sh - Shared functions for review-gate scripts
#
# Provides path resolution for session-scoped review gate directories.
# Files are stored in ~/.claude/projects/<project-hash>/review-gate/<session-id>/
#
# Usage: source this file from review-gate-* scripts

# Get project hash from transcript path or calculate from project root
# Args: transcript_path (optional)
# Returns: project hash (e.g., -home-cyou-ai-configs)
get_project_hash() {
    local transcript_path="${1:-}"

    # Method 1: Extract from transcript_path
    # Format: ~/.claude/projects/-home-cyou-ai-configs/512c17bf-....jsonl
    if [[ -n "$transcript_path" ]]; then
        local dir_name
        dir_name=$(basename "$(dirname "$transcript_path")")
        if [[ "$dir_name" == -* ]]; then
            echo "$dir_name"
            return 0
        fi
    fi

    # Method 2: Calculate from project root
    local project_root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    # Convert /home/cyou/ai-configs to -home-cyou-ai-configs
    echo "$project_root" | sed 's|^/|-|' | tr '/' '-'
}

# Resolve the review directory for a session
# Args: session_id, transcript_path (optional)
# Returns: absolute path to review directory
# If session_id is empty, returns the project-level base directory
resolve_review_dir() {
    local session_id="${1:-}"
    local transcript_path="${2:-}"

    local project_hash
    project_hash=$(get_project_hash "$transcript_path")

    local base_dir="$HOME/.claude/projects/$project_hash/review-gate"

    if [[ -n "$session_id" ]]; then
        echo "$base_dir/$session_id"
    else
        echo "$base_dir"
    fi
}

# Get project-level review base directory (for listing all sessions)
# Args: transcript_path (optional)
# Returns: base directory path without session_id
get_review_base_dir() {
    resolve_review_dir "" "${1:-}"
}

# Archive previous reviews to a timestamped directory
# Args: review_dir, reviews_dir, iteration
# Returns: 0 on success (or no-op if no reviews), archive path on stderr
archive_reviews() {
    local review_dir="$1"
    local reviews_dir="$2"
    local iteration="${3:-0}"

    if [[ ! -d "$reviews_dir" ]]; then
        return 0
    fi

    # Check if there are any review files to archive
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

    # Archive directory with iteration number
    local archive_dir="$review_dir/reviews-iter-${iteration}"

    # If archive already exists for this iteration, add timestamp
    if [[ -d "$archive_dir" ]]; then
        local ts
        ts=$(date +%Y%m%d-%H%M%S)
        archive_dir="$review_dir/reviews-iter-${iteration}-${ts}"
    fi

    mv "$reviews_dir" "$archive_dir"
    echo "$archive_dir" >&2
    return 0
}

# Unwrap review JSON from various wrapper formats (codex, gemini)
# Args: json_string
# Returns: unwrapped JSON on stdout, 1 on error
unwrap_review_json() {
    local json="$1"
    if [[ -z "$json" ]]; then
        return 1
    fi

    # Unwrap structured_output wrapper (codex)
    if echo "$json" | jq -e '.structured_output' >/dev/null 2>&1; then
        json=$(echo "$json" | jq -c '.structured_output' 2>/dev/null || echo "")
    fi

    # Unwrap response wrapper (gemini)
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

# Extract the last JSON object from a file that may contain non-JSON text
# Args: file_path
# Returns: JSON on stdout, 1 on error
extract_last_json_object() {
    local file="$1"
    python3 - "$file" <<'PY'
import json, sys

path = sys.argv[1]
text = open(path, "r", errors="ignore").read()
decoder = json.JSONDecoder()

# Collect all valid JSON objects with their positions
objects = []
for i, ch in enumerate(text):
    if ch not in "{[":
        continue
    try:
        obj, end = decoder.raw_decode(text[i:])
        # Only collect dict objects (not arrays)
        if isinstance(obj, dict):
            objects.append((i, i + end, obj))
    except Exception:
        pass

if not objects:
    sys.exit(1)

# Filter to only review-like objects (must have verdict OR be structured_output wrapper)
review_candidates = []
for start, end, obj in objects:
    # Direct review result
    if "verdict" in obj and obj.get("verdict") in ("PASS", "FAIL", "NEEDS_WORK"):
        review_candidates.append((start, end, obj))
    # Codex structured_output wrapper
    elif "structured_output" in obj:
        review_candidates.append((start, end, obj))
    # Gemini response wrapper
    elif "response" in obj and isinstance(obj.get("response"), str):
        review_candidates.append((start, end, obj))

# Use the LAST review candidate, or fall back to last object
if review_candidates:
    result = review_candidates[-1][2]
else:
    result = objects[-1][2]

print(json.dumps(result))
PY
}

# Find active review gate for current project
# Returns session_id of first pending/awaiting gate, or exits 1 if none found
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
