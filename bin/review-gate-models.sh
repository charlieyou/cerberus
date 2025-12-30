#!/usr/bin/env bash
# Model invocation and output parsing helpers for review-gate.

# Normalize mode value to lowercase, empty input returns empty.
normalize_mode() {
    local value="${1:-}"
    if [[ -z "$value" ]]; then
        echo ""
        return 0
    fi
    printf '%s' "$value" | tr '[:upper:]' '[:lower:]'
}

# Validate mode value (fast|smart|max), empty is allowed.
# Requires a die() function to be defined by the caller.
validate_mode() {
    local value="${1:-}"
    if [[ -z "$value" ]]; then
        return 0
    fi
    case "$value" in
        fast|smart|max) return 0 ;;
        *) die "Invalid --mode '$value' (must be fast|smart|max)" ;;
    esac
}

rg_log() {
    if declare -F log >/dev/null 2>&1; then
        log "$1"
    else
        printf '%s\n' "$1" >&2
    fi
}

# Resolve intelligence mode to model/effort settings.
resolve_intelligence_mode() {
    local mode="${1:-}"
    if [[ -z "$mode" ]]; then
        mode="smart"
    fi
    mode=$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')

    case "$mode" in
        fast|smart|max) ;;
        *)
            rg_log "review-gate: invalid mode '$mode' (defaulting to smart)"
            mode="smart"
            ;;
    esac

    INTELLIGENCE_MODE="$mode"
    PROMPT_ULTRATHINK="false"

    case "$mode" in
        fast)
            CODEX_REVIEW_REASONING_EFFORT="${CODEX_REVIEW_REASONING_EFFORT:-medium}"
            CODEX_GENERATE_REASONING_EFFORT="${CODEX_GENERATE_REASONING_EFFORT:-medium}"
            GEMINI_MODEL_EFFECTIVE="${GEMINI_MODEL:-gemini-3-flash-preview}"
            CLAUDE_MODEL_EFFECTIVE="${CLAUDE_MODEL:-sonnet}"
            ;;
        smart)
            CODEX_REVIEW_REASONING_EFFORT="${CODEX_REVIEW_REASONING_EFFORT:-high}"
            CODEX_GENERATE_REASONING_EFFORT="${CODEX_GENERATE_REASONING_EFFORT:-high}"
            GEMINI_MODEL_EFFECTIVE="${GEMINI_MODEL:-gemini-3-pro-preview}"
            CLAUDE_MODEL_EFFECTIVE="${CLAUDE_MODEL:-opus}"
            ;;
        max)
            CODEX_REVIEW_REASONING_EFFORT="${CODEX_REVIEW_REASONING_EFFORT:-xhigh}"
            CODEX_GENERATE_REASONING_EFFORT="${CODEX_GENERATE_REASONING_EFFORT:-xhigh}"
            GEMINI_MODEL_EFFECTIVE="${GEMINI_MODEL:-gemini-3-pro-preview}"
            CLAUDE_MODEL_EFFECTIVE="${CLAUDE_MODEL:-opus}"
            PROMPT_ULTRATHINK="true"
            ;;
    esac

    # Codex model does not vary by mode.
    CODEX_MODEL_EFFECTIVE="${CODEX_MODEL:-gpt-5.2-codex}"
}

# Extract the last JSON object from a file.
extract_last_json_object() {
    local file="$1"
    local debug="${2:-false}"
    python - "$file" "$debug" <<'PY'
import json, sys

path = sys.argv[1]
debug = sys.argv[2] == "true" if len(sys.argv) > 2 else False

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

if debug:
    print(f"DEBUG: Found {len(objects)} JSON objects in file", file=sys.stderr)
    for idx, (start, end, obj) in enumerate(objects):
        keys = list(obj.keys())[:5]
        preview = str(obj)[:100]
        print(f"DEBUG:   [{idx}] pos={start}-{end} keys={keys} preview={preview}...", file=sys.stderr)

if not objects:
    if debug:
        print("DEBUG: No JSON objects found", file=sys.stderr)
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

if debug:
    print(f"DEBUG: Found {len(review_candidates)} review candidates", file=sys.stderr)

# Use the LAST review candidate, or fall back to last object
if review_candidates:
    result = review_candidates[-1][2]
    if debug:
        print(f"DEBUG: Using last review candidate at pos {review_candidates[-1][0]}", file=sys.stderr)
else:
    result = objects[-1][2]
    if debug:
        print(f"DEBUG: No review candidates, using last object at pos {objects[-1][0]}", file=sys.stderr)

print(json.dumps(result))
PY
}

# Extract reviewer output JSON, including model-specific wrappers.
extract_json() {
    local file="$1"
    local reviewer="$2"
    local json=""
    local file_size=""

    if [[ -f "$file" ]]; then
        file_size=$(wc -c < "$file" 2>/dev/null || echo 0)
        rg_log "review-gate: extract_json START reviewer=$reviewer file=$file size=$file_size"
    else
        rg_log "review-gate: extract_json reviewer=$reviewer MISSING file=$file"
        return 1
    fi

    case "$reviewer" in
        codex)
            # Codex output is complex - use smart JSON extraction directly
            # This finds the LAST review-like JSON object in the file
            rg_log "review-gate: extract_json codex using extract_last_json_object"

            # Capture debug output to log file
            local debug_output
            debug_output=$(extract_last_json_object "$file" "true" 2>&1 >/dev/null || true)
            while IFS= read -r line; do
                [[ -n "$line" ]] && rg_log "review-gate: $line"
            done <<< "$debug_output"

            # Get actual result (without debug)
            json=$(extract_last_json_object "$file" "false" 2>/dev/null || true)

            if [[ -n "$json" ]]; then
                rg_log "review-gate: extract_json codex extracted len=${#json}"
                local preview="${json:0:200}"
                rg_log "review-gate: extract_json codex preview: $preview"
            else
                rg_log "review-gate: extract_json codex extract_last_json_object FAILED (empty result)"
            fi
            ;;
        gemini)
            # Gemini: skip first line (status), parse JSON
            rg_log "review-gate: extract_json gemini trying tail+jq"
            json=$(tail -n +2 "$file" | jq -c '.' 2>/dev/null || true)
            if [[ -n "$json" ]]; then
                rg_log "review-gate: extract_json gemini tail+jq succeeded len=${#json}"
            else
                rg_log "review-gate: extract_json gemini tail+jq failed, trying extract_last_json_object"
                json=$(extract_last_json_object "$file" "false" 2>/dev/null || true)
                rg_log "review-gate: extract_json gemini extract_last_json_object len=${#json}"
            fi
            if [[ -n "$json" ]]; then
                local preview="${json:0:200}"
                rg_log "review-gate: extract_json gemini preview: $preview"
            fi
            ;;
        claude)
            # Claude: --output-format json wraps result in metadata object
            # Extract .result field which contains the actual response (may have markdown fences)
            rg_log "review-gate: extract_json claude extracting from metadata wrapper"
            local result_str
            result_str=$(jq -r '.result // empty' "$file" 2>/dev/null || true)
            if [[ -n "$result_str" ]]; then
                # Try direct parse first (no fences)
                json=$(echo "$result_str" | jq -c '.' 2>/dev/null || true)
                if [[ -z "$json" ]]; then
                    # Result may be wrapped in ```json fences, strip them
                    local stripped
                    stripped=$(echo "$result_str" | sed '/^```json$/d; /^```$/d')
                    json=$(echo "$stripped" | jq -c '.' 2>/dev/null || true)
                fi
                if [[ -z "$json" ]]; then
                    # Fallback to extract_last_json_object using temp file
                    rg_log "review-gate: extract_json claude trying extract_last_json_object on result"
                    local tmp_file
                    tmp_file=$(mktemp)
                    echo "$result_str" > "$tmp_file"
                    json=$(extract_last_json_object "$tmp_file" "false" 2>/dev/null || true)
                    rm -f "$tmp_file"
                fi
            fi
            if [[ -n "$json" ]]; then
                rg_log "review-gate: extract_json claude extracted len=${#json}"
                local preview="${json:0:200}"
                rg_log "review-gate: extract_json claude preview: $preview"
            else
                rg_log "review-gate: extract_json claude FAILED to extract JSON"
            fi
            ;;
        *)
            # Fallback: try raw JSON
            rg_log "review-gate: extract_json $reviewer trying raw jq"
            json=$(jq -c '.' "$file" 2>/dev/null || true)
            ;;
    esac

    if [[ -z "$json" ]]; then
        rg_log "review-gate: extract_json $reviewer NO JSON EXTRACTED"
        return 1
    fi

    rg_log "review-gate: extract_json $reviewer before unwrap len=${#json}"
    if ! json=$(unwrap_review_json "$json" 2>/dev/null); then
        rg_log "review-gate: extract_json $reviewer unwrap FAILED"
        return 1
    fi

    rg_log "review-gate: extract_json $reviewer after unwrap len=${#json}"

    if ! echo "$json" | jq -c '.' >/dev/null 2>&1; then
        rg_log "review-gate: extract_json $reviewer final jq validation FAILED"
        return 1
    fi

    # Log final extracted verdict for debugging
    local verdict
    verdict=$(echo "$json" | jq -r '.verdict // "NO_VERDICT"' 2>/dev/null || echo "JQ_ERROR")
    rg_log "review-gate: extract_json $reviewer SUCCESS verdict=$verdict"

    echo "$json" | jq -c '.'
}

# Spawn a reviewer subprocess.
spawn_reviewer() {
    local name="$1"
    local cmd="$2"
    local prompt_file="$3"
    local schema_file="$4"

    # Ensure reviews directory exists
    mkdir -p "$REVIEWS_DIR"

    local codex_model="${CODEX_MODEL_EFFECTIVE:-$CODEX_MODEL}"
    local gemini_model="${GEMINI_MODEL_EFFECTIVE:-$GEMINI_MODEL}"
    local claude_model="${CLAUDE_MODEL_EFFECTIVE:-$CLAUDE_MODEL}"
    local codex_reasoning="${CODEX_REVIEW_REASONING_EFFORT:-high}"

    local output_file="$REVIEWS_DIR/${name}.json"
    local sentinel_file="$REVIEWS_DIR/${name}.done"
    local failed_file="$REVIEWS_DIR/${name}.failed"

    # Skip missing CLIs with warning
    if ! command -v "$cmd" >/dev/null; then
        echo "Skipping $name: $cmd not found" >&2
        return 1
    fi

    case "$name" in
        gemini)
            REVIEW_OUT="$output_file" \
            REVIEW_DONE="$sentinel_file" \
            REVIEW_FAIL="$failed_file" \
            REVIEW_PROMPT="$prompt_file" \
            REVIEW_MODEL="$gemini_model" \
            nohup setsid bash -c '
                if gemini -m "$REVIEW_MODEL" -o json < "$REVIEW_PROMPT" > "$REVIEW_OUT" 2>&1; then
                    touch "$REVIEW_DONE"
                else
                    touch "$REVIEW_FAIL"
                fi
            ' >/dev/null 2>&1 &
            ;;
        codex)
            REVIEW_OUT="$output_file" \
            REVIEW_DONE="$sentinel_file" \
            REVIEW_FAIL="$failed_file" \
            REVIEW_PROMPT="$prompt_file" \
            REVIEW_SCHEMA="$schema_file" \
            REVIEW_MODEL="$codex_model" \
            nohup setsid bash -c '
                if codex exec -m "$REVIEW_MODEL" -c model_reasoning_effort=\"'"$codex_reasoning"'\" -s read-only --output-schema "$REVIEW_SCHEMA" - < "$REVIEW_PROMPT" > "$REVIEW_OUT" 2>&1; then
                    touch "$REVIEW_DONE"
                else
                    touch "$REVIEW_FAIL"
                fi
            ' >/dev/null 2>&1 &
            ;;
        claude)
            REVIEW_OUT="$output_file" \
            REVIEW_DONE="$sentinel_file" \
            REVIEW_FAIL="$failed_file" \
            REVIEW_PROMPT="$prompt_file" \
            REVIEW_MODEL="$claude_model" \
            nohup setsid bash -c '
                if claude -p --model "$REVIEW_MODEL" --output-format json < "$REVIEW_PROMPT" > "$REVIEW_OUT" 2>&1; then
                    touch "$REVIEW_DONE"
                else
                    touch "$REVIEW_FAIL"
                fi
            ' >/dev/null 2>&1 &
            ;;
        *)
            echo "Unknown reviewer: $name" >&2
            return 1
            ;;
    esac

    return 0
}
