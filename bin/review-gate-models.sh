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

is_truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
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
            CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT_OVERRIDE:-medium}"
            # Mode determines model - respect override, then base var, then mode default
            GEMINI_MODEL_EFFECTIVE="${GEMINI_MODEL_OVERRIDE:-${GEMINI_MODEL:-gemini-3-flash-preview}}"
            CLAUDE_MODEL_EFFECTIVE="${CLAUDE_MODEL_OVERRIDE:-${CLAUDE_MODEL:-sonnet}}"
            ;;
        smart)
            CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT_OVERRIDE:-high}"
            GEMINI_MODEL_EFFECTIVE="${GEMINI_MODEL_OVERRIDE:-${GEMINI_MODEL:-gemini-3-pro-preview}}"
            CLAUDE_MODEL_EFFECTIVE="${CLAUDE_MODEL_OVERRIDE:-${CLAUDE_MODEL:-opus}}"
            ;;
        max)
            CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT_OVERRIDE:-xhigh}"
            GEMINI_MODEL_EFFECTIVE="${GEMINI_MODEL_OVERRIDE:-${GEMINI_MODEL:-gemini-3-pro-preview}}"
            CLAUDE_MODEL_EFFECTIVE="${CLAUDE_MODEL_OVERRIDE:-${CLAUDE_MODEL:-opus}}"
            PROMPT_ULTRATHINK="true"
            ;;
    esac

    # Codex model does not vary by mode.
    CODEX_MODEL_EFFECTIVE="${CODEX_MODEL_OVERRIDE:-${CODEX_MODEL:-gpt-5.2}}"
}

# Read-only tool policy for external CLIs.
GEMINI_READONLY_SETTINGS_PATH="${GEMINI_READONLY_SETTINGS_PATH:-$PLUGIN_ROOT/config/gemini-readonly-settings.json}"
CLAUDE_READONLY_ALLOWED_TOOLS="${CLAUDE_READONLY_ALLOWED_TOOLS:-Read Glob Grep LS}"
CLAUDE_READONLY_DISALLOWED_TOOLS="${CLAUDE_READONLY_DISALLOWED_TOOLS:-Bash Edit Write WebFetch WebSearch}"

gemini_readonly_settings_path() {
    local settings_path="${GEMINI_READONLY_SETTINGS_PATH:-}"
    if [[ -z "$settings_path" ]]; then
        rg_log "review-gate: GEMINI_READONLY_SETTINGS_PATH not set"
        return 1
    fi
    if [[ ! -f "$settings_path" ]]; then
        rg_log "review-gate: gemini read-only settings missing at $settings_path"
        return 1
    fi
    echo "$settings_path"
}

default_review_schema() {
    cat <<'SCHEMA'
{
  "type": "object",
  "properties": {
    "verdict": {
      "type": "string",
      "enum": ["PASS", "FAIL", "NEEDS_WORK"]
    },
    "summary": {
      "type": "string"
    },
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "title": {"type": "string"},
          "body": {"type": "string"},
          "priority": {"type": "integer", "minimum": 0, "maximum": 3},
          "file_path": {"type": ["string", "null"]},
          "line_start": {"type": ["integer", "null"]},
          "line_end": {"type": ["integer", "null"]}
        },
        "required": ["title", "body", "priority", "file_path", "line_start", "line_end"],
        "additionalProperties": false
      }
    }
  },
  "required": ["verdict", "summary", "findings"],
  "additionalProperties": false
}
SCHEMA
}

repair_review_output() {
    local raw_output="$1"
    local schema_file="$2"
    local reviewer="$3"
    local reason="${4:-parse_failure}"

    if ! is_truthy "${REVIEW_REPAIR_ENABLED:-true}"; then
        rg_log "review-gate: repair_json disabled (reviewer=$reviewer reason=$reason)"
        return 1
    fi

    if [[ -z "$raw_output" ]]; then
        rg_log "review-gate: repair_json empty raw output (reviewer=$reviewer reason=$reason)"
        return 1
    fi

    local provider="${REVIEW_REPAIR_PROVIDER:-}"
    if [[ -n "$provider" ]]; then
        # Normalize provider to lowercase for command lookup and case matching
        provider=$(printf '%s' "$provider" | tr '[:upper:]' '[:lower:]')
        if [[ "$provider" == "auto" ]]; then
            provider=""
        fi
    fi
    if [[ -z "$provider" ]]; then
        if command -v claude >/dev/null 2>&1; then
            provider="claude"
        elif command -v codex >/dev/null 2>&1; then
            provider="codex"
        elif command -v gemini >/dev/null 2>&1; then
            provider="gemini"
        else
            rg_log "review-gate: repair_json no provider available"
            return 1
        fi
    fi

    local model="${REVIEW_REPAIR_MODEL:-}"
    if ! command -v "$provider" >/dev/null 2>&1; then
        rg_log "review-gate: repair_json provider '$provider' not found"
        return 1
    fi
    case "$provider" in
        claude)
            [[ -z "$model" ]] && model="haiku"
            ;;
        codex)
            [[ -z "$model" ]] && model="gpt-5.1-codex-mini"
            ;;
        gemini)
            [[ -z "$model" ]] && model="gemini-2.5-flash-lite"
            ;;
        *)
            rg_log "review-gate: repair_json unknown provider '$provider'"
            return 1
            ;;
    esac

    local schema_text=""
    if [[ -n "$schema_file" && -f "$schema_file" ]]; then
        schema_text=$(cat "$schema_file")
    else
        schema_text=$(default_review_schema)
    fi

    local prompt_file out_file
    prompt_file=$(mktemp)
    out_file=$(mktemp)

    {
        echo "You are a JSON repair tool."
        echo "Convert the following reviewer output into JSON that matches this schema:"
        echo ""
        printf '%s\n' "$schema_text"
        echo ""
        echo "Rules:"
        echo "- Output JSON only. No code fences or extra text."
        echo "- Required top-level keys: verdict, summary, findings."
        echo "- verdict must be PASS, FAIL, or NEEDS_WORK (choose best match)."
        echo "- summary: 1-2 sentences."
        echo "- findings: array of objects with title, body, priority (0-3), file_path, line_start, line_end."
        echo "- Map P0->0, P1->1, P2->2, P3->3 if mentioned."
        echo "- If details are unknown, use null for file_path/line_start/line_end."
        echo "- If no issues are described, output verdict PASS and empty findings."
        echo ""
        echo "Reviewer output:"
        echo ""
        printf '%s\n' "$raw_output"
    } > "$prompt_file"

    rg_log "review-gate: repair_json start reviewer=$reviewer provider=$provider model=$model reason=$reason"

    local repaired=""
    case "$provider" in
        claude)
            local -a claude_allowed_tools
            local -a claude_disallowed_tools
            read -r -a claude_allowed_tools <<< "$CLAUDE_READONLY_ALLOWED_TOOLS"
            read -r -a claude_disallowed_tools <<< "$CLAUDE_READONLY_DISALLOWED_TOOLS"
            if claude -p --model "$model" --output-format json \
                --allowedTools "${claude_allowed_tools[@]}" \
                --disallowedTools "${claude_disallowed_tools[@]}" \
                < "$prompt_file" > "$out_file" 2>&1; then
                local result_str
                result_str=$(jq -r '.result // empty' "$out_file" 2>/dev/null || true)
                if [[ -n "$result_str" ]]; then
                    repaired=$(echo "$result_str" | jq -c '.' 2>/dev/null || true)
                    if [[ -z "$repaired" ]]; then
                        local stripped
                        stripped=$(echo "$result_str" | sed '/^```json$/d; /^```$/d')
                        repaired=$(echo "$stripped" | jq -c '.' 2>/dev/null || true)
                    fi
                    if [[ -z "$repaired" ]]; then
                        local tmp_file
                        tmp_file=$(mktemp)
                        printf '%s' "$result_str" > "$tmp_file"
                        repaired=$(extract_last_json_object "$tmp_file" "false" 2>/dev/null || true)
                        rm -f "$tmp_file"
                    fi
                fi
            else
                rg_log "review-gate: repair_json claude failed (model=$model)"
            fi
            ;;
        codex)
            local schema_path="$schema_file"
            local temp_schema=""
            if [[ -z "$schema_path" || ! -f "$schema_path" ]]; then
                schema_path=$(mktemp)
                temp_schema="$schema_path"
                printf '%s\n' "$schema_text" > "$schema_path"
            fi
            if codex exec -m "$model" -s read-only --output-schema "$schema_path" - < "$prompt_file" > "$out_file" 2>&1; then
                repaired=$(extract_last_json_object "$out_file" "false" 2>/dev/null || true)
                if [[ -n "$repaired" ]]; then
                    repaired=$(unwrap_review_json "$repaired" 2>/dev/null || echo "")
                fi
            else
                rg_log "review-gate: repair_json codex failed (model=$model)"
            fi
            [[ -n "$temp_schema" ]] && rm -f "$temp_schema"
            ;;
        gemini)
            local gemini_settings=""
            if ! gemini_settings=$(gemini_readonly_settings_path); then
                rg_log "review-gate: repair_json gemini missing read-only settings"
            else
                if GEMINI_CLI_SYSTEM_SETTINGS_PATH="$gemini_settings" \
                    gemini -m "$model" -o json < "$prompt_file" > "$out_file" 2>&1; then
                    # Use extract_last_json_object directly (consistent with extract_json)
                    # This handles arbitrary preamble/noise before JSON
                    repaired=$(extract_last_json_object "$out_file" "false" 2>/dev/null || true)
                    if [[ -n "$repaired" ]]; then
                        repaired=$(unwrap_review_json "$repaired" 2>/dev/null || echo "")
                    fi
                else
                    rg_log "review-gate: repair_json gemini failed (model=$model)"
                fi
            fi
            ;;
    esac

    rm -f "$prompt_file" "$out_file"

    if [[ -z "$repaired" ]]; then
        rg_log "review-gate: repair_json failed to extract JSON (reviewer=$reviewer)"
        return 1
    fi

    if ! echo "$repaired" | jq -c '.' >/dev/null 2>&1; then
        rg_log "review-gate: repair_json produced invalid JSON (reviewer=$reviewer)"
        return 1
    fi

    rg_log "review-gate: repair_json success reviewer=$reviewer"
    printf '%s' "$repaired"
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
    local raw_output=""
    local repaired="false"
    local schema_file=""

    if [[ -f "$file" ]]; then
        file_size=$(wc -c < "$file" 2>/dev/null || echo 0)
        rg_log "review-gate: extract_json START reviewer=$reviewer file=$file size=$file_size"
        raw_output=$(cat "$file" 2>/dev/null || true)
        schema_file="$(dirname "$file")/review-schema.json"
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
            # Gemini: output may have multiple lines of stderr noise before JSON
            # Use extract_last_json_object directly which handles arbitrary preamble
            rg_log "review-gate: extract_json gemini using extract_last_json_object"

            # Single call with debug=true captures both stderr (debug) and stdout (result)
            local extract_stderr extract_stdout
            extract_stderr=$(mktemp)
            extract_stdout=$(mktemp)
            if extract_last_json_object "$file" "true" 2>"$extract_stderr" >"$extract_stdout"; then
                json=$(cat "$extract_stdout")
            fi
            # Log debug output from stderr
            while IFS= read -r line; do
                [[ -n "$line" ]] && rg_log "review-gate: $line"
            done < "$extract_stderr"
            rm -f "$extract_stderr" "$extract_stdout"

            if [[ -n "$json" ]]; then
                rg_log "review-gate: extract_json gemini extracted len=${#json}"
                local preview="${json:0:200}"
                rg_log "review-gate: extract_json gemini preview: $preview"
            else
                rg_log "review-gate: extract_json gemini extract_last_json_object FAILED (empty result)"
            fi
            ;;
        claude)
            # Claude: --output-format json wraps result in metadata object
            # Extract .result field which contains the actual response (may have markdown fences)
            rg_log "review-gate: extract_json claude extracting from metadata wrapper"
            local result_str
            result_str=$(jq -r '.result // empty' "$file" 2>/dev/null || true)
            if [[ -n "$result_str" ]]; then
                raw_output="$result_str"
            fi
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
        if json=$(repair_review_output "$raw_output" "$schema_file" "$reviewer" "no_json_extracted"); then
            repaired="true"
        else
            return 1
        fi
    fi

    rg_log "review-gate: extract_json $reviewer before unwrap len=${#json}"
    if ! json=$(unwrap_review_json "$json" 2>/dev/null); then
        rg_log "review-gate: extract_json $reviewer unwrap FAILED"
        if [[ "$repaired" != "true" ]] && json=$(repair_review_output "$raw_output" "$schema_file" "$reviewer" "unwrap_failed"); then
            repaired="true"
            if ! json=$(unwrap_review_json "$json" 2>/dev/null); then
                return 1
            fi
        else
            return 1
        fi
    fi

    rg_log "review-gate: extract_json $reviewer after unwrap len=${#json}"

    if ! echo "$json" | jq -c '.' >/dev/null 2>&1; then
        rg_log "review-gate: extract_json $reviewer final jq validation FAILED"
        if [[ "$repaired" != "true" ]] && json=$(repair_review_output "$raw_output" "$schema_file" "$reviewer" "jq_failed"); then
            repaired="true"
        else
            return 1
        fi
        if ! echo "$json" | jq -c '.' >/dev/null 2>&1; then
            return 1
        fi
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
    local codex_reasoning="${CODEX_REASONING_EFFORT:-high}"

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
            local gemini_settings=""
            if ! gemini_settings=$(gemini_readonly_settings_path); then
                echo "Skipping gemini: read-only settings missing" >&2
                return 1
            fi
            GEMINI_CLI_SYSTEM_SETTINGS_PATH="$gemini_settings" \
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
            CLAUDE_ALLOWED_TOOLS="$CLAUDE_READONLY_ALLOWED_TOOLS" \
            CLAUDE_DISALLOWED_TOOLS="$CLAUDE_READONLY_DISALLOWED_TOOLS" \
            REVIEW_OUT="$output_file" \
            REVIEW_DONE="$sentinel_file" \
            REVIEW_FAIL="$failed_file" \
            REVIEW_PROMPT="$prompt_file" \
            REVIEW_MODEL="$claude_model" \
            nohup setsid bash -c '
                read -r -a claude_allowed_tools <<< "$CLAUDE_ALLOWED_TOOLS"
                read -r -a claude_disallowed_tools <<< "$CLAUDE_DISALLOWED_TOOLS"
                if claude -p --model "$REVIEW_MODEL" --output-format json \
                    --allowedTools "${claude_allowed_tools[@]}" \
                    --disallowedTools "${claude_disallowed_tools[@]}" \
                    < "$REVIEW_PROMPT" > "$REVIEW_OUT" 2>&1; then
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
