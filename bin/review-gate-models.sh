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
            GEMINI_MODEL_EFFECTIVE="${GEMINI_MODEL_OVERRIDE:-${GEMINI_MODEL:-gemini-3.1-pro-preview}}"
            CLAUDE_MODEL_EFFECTIVE="${CLAUDE_MODEL_OVERRIDE:-${CLAUDE_MODEL:-opus}}"
            ;;
        max)
            CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT_OVERRIDE:-xhigh}"
            GEMINI_MODEL_EFFECTIVE="${GEMINI_MODEL_OVERRIDE:-${GEMINI_MODEL:-gemini-3.1-pro-preview}}"
            CLAUDE_MODEL_EFFECTIVE="${CLAUDE_MODEL_OVERRIDE:-${CLAUDE_MODEL:-opus}}"
            PROMPT_ULTRATHINK="true"
            ;;
    esac

    # Codex model does not vary by mode.
    CODEX_MODEL_EFFECTIVE="${CODEX_MODEL_OVERRIDE:-${CODEX_MODEL:-gpt-5.5}}"
}

# Read-only tool policy for external CLIs.
GEMINI_READONLY_SETTINGS_PATH="${GEMINI_READONLY_SETTINGS_PATH:-$PLUGIN_ROOT/config/gemini-readonly-settings.json}"
GEMINI_READONLY_POLICY_PATH="${GEMINI_READONLY_POLICY_PATH:-$PLUGIN_ROOT/config/gemini-readonly-policy.toml}"
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

gemini_readonly_policy_path() {
    local policy_path="${GEMINI_READONLY_POLICY_PATH:-}"
    if [[ -z "$policy_path" ]]; then
        rg_log "review-gate: GEMINI_READONLY_POLICY_PATH not set"
        return 1
    fi
    if [[ ! -f "$policy_path" ]]; then
        rg_log "review-gate: gemini read-only policy missing at $policy_path"
        return 1
    fi
    echo "$policy_path"
}

# Emit the structured-output review schema bytes to stdout.
#
# Pinned by spec R9: schema bytes MUST be byte-identical to the pre-feature
# bytes when --debate is absent (so the byte-parity guarantee for
# review-schema.json holds), and the debate variant MUST add the additive
# debate fields (overall_confidence, strategy, round, peer_responses_seen at
# the top level; confidence inside findings[*]) as REQUIRED properties with
# nullable type unions, while retaining additionalProperties:false on both
# objects so genuinely unknown fields are still rejected. The required-
# but-nullable shape is needed for OpenAI's strict structured-outputs mode
# (codex), which rejects schemas where any property in `properties` is
# absent from `required`. Mode B parsing in review-gate-debate.sh treats
# null and missing identically (both default to 0.5 for confidence fields),
# so this is byte-equivalent for downstream consumers.
#
# Selection contract:
#   $1 (optional)            "true" enables the debate variant; anything else
#                            (or unset) emits the pre-feature schema bytes.
#   REVIEW_GATE_DEBATE env   Fallback when no positional arg is provided
#                            (1/true/TRUE/yes/YES/on/ON enables debate).
#
# This is the single source of truth for the schema bytes; both the inline
# schema-emission code path in bin/review-gate (formerly an inline heredoc)
# and the repair_review_output() fallback delegate to this function so the
# debate-conditional branch lives in exactly one place.
_emit_review_schema() {
    local debate_arg="${1-}"
    local debate
    if [[ -n "$debate_arg" ]]; then
        debate="$debate_arg"
    else
        debate="${REVIEW_GATE_DEBATE:-false}"
    fi
    case "$debate" in
        1|true|TRUE|yes|YES|on|ON) debate="true" ;;
        *) debate="false" ;;
    esac

    if [[ "$debate" != "true" ]]; then
        # Pre-feature schema. Bytes MUST be byte-identical to the bytes
        # emitted historically by this function and by the inline heredoc in
        # bin/review-gate (lines ~3148-3181 pre-T006). Verified by
        # bin/tests/test-debate-byte-parity.sh against the committed fixtures
        # under bin/tests/fixtures/pre-debate-baseline/.
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
    else
        # Debate variant. Adds the additive debate fields at the top level
        # (overall_confidence, strategy, round, peer_responses_seen) and a
        # findings[*].confidence field. All additive fields are listed in
        # `required` and given a nullable type union so reviewers that do
        # not have a meaningful value MUST still emit the key (with `null`)
        # rather than omitting it. This is required for OpenAI's strict
        # structured-outputs mode (the codex reviewer uses it via
        # `--output-schema`), which rejects schemas where any property in
        # `properties` is absent from `required`. Mode B handling at parse
        # time (in review-gate-debate.sh) treats null and missing values
        # identically — defaulting overall_confidence and per-finding
        # confidence to 0.5 — so this change is byte-equivalent for
        # downstream consumers. Both objects retain `additionalProperties:
        # false` so genuinely unknown fields are still rejected.
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
          "line_end": {"type": ["integer", "null"]},
          "confidence": {"type": ["number", "null"], "minimum": 0, "maximum": 1}
        },
        "required": ["title", "body", "priority", "file_path", "line_start", "line_end", "confidence"],
        "additionalProperties": false
      }
    },
    "overall_confidence": {"type": ["number", "null"], "minimum": 0, "maximum": 1},
    "strategy": {
      "type": ["string", "null"],
      "enum": ["verification-first", "falsification-first", "decompose", null]
    },
    "round": {"type": ["integer", "null"], "minimum": 1},
    "peer_responses_seen": {
      "type": ["array", "null"],
      "items": {"type": "string"}
    }
  },
  "required": ["verdict", "summary", "findings", "overall_confidence", "strategy", "round", "peer_responses_seen"],
  "additionalProperties": false
}
SCHEMA
    fi
}

# Default review schema — thin wrapper around _emit_review_schema for callers
# that read the env-var-driven default (e.g., repair_review_output's fallback
# path when no schema_file is provided). The positional override is honored
# when a caller explicitly passes "true"/"false".
default_review_schema() {
    _emit_review_schema "${1-}"
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
            [[ -z "$model" ]] && model="gpt-5.4-mini"
            ;;
        gemini)
            [[ -z "$model" ]] && model="gemini-3.1-flash-lite-preview"
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
                    repaired=$(printf '%s' "$result_str" | jq -c '.' 2>/dev/null || true)
                    if [[ -z "$repaired" ]]; then
                        local stripped
                        stripped=$(printf '%s' "$result_str" | sed '/^```json$/d; /^```$/d')
                        repaired=$(printf '%s' "$stripped" | jq -c '.' 2>/dev/null || true)
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
            local jsonl_file="${out_file}.jsonl"
            local -a codex_extra_args=()
            if codex exec --help 2>&1 | grep -q -- '--ephemeral'; then
                codex_extra_args=(--ephemeral)
            fi
            if codex exec ${codex_extra_args[@]+"${codex_extra_args[@]}"} -m "$model" -s read-only --skip-git-repo-check \
                --output-schema "$schema_path" --json -o "$out_file" \
                - < "$prompt_file" > "$jsonl_file" 2>&1; then
                if [[ -s "$out_file" ]]; then
                    repaired=$(jq -c '.' "$out_file" 2>/dev/null || true)
                fi
                if [[ -z "$repaired" ]]; then
                    repaired=$(extract_codex_agent_message "$jsonl_file" 2>/dev/null || true)
                fi
                if [[ -n "$repaired" ]]; then
                    repaired=$(unwrap_review_json "$repaired" 2>/dev/null || echo "")
                fi
            else
                rg_log "review-gate: repair_json codex failed (model=$model)"
            fi
            rm -f "$jsonl_file"
            [[ -n "$temp_schema" ]] && rm -f "$temp_schema"
            ;;
        gemini)
            local gemini_settings=""
            local gemini_policy=""
            if ! gemini_settings=$(gemini_readonly_settings_path); then
                rg_log "review-gate: repair_json gemini missing read-only settings"
            elif ! gemini_policy=$(gemini_readonly_policy_path); then
                rg_log "review-gate: repair_json gemini missing read-only policy"
            else
                if GEMINI_CLI_SYSTEM_SETTINGS_PATH="$gemini_settings" \
                    gemini -m "$model" --approval-mode plan -p "" \
                        --policy "$gemini_policy" --admin-policy "$gemini_policy" \
                        --output-format json < "$prompt_file" > "$out_file" 2>&1; then
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

    if ! printf '%s' "$repaired" | jq -c '.' >/dev/null 2>&1; then
        rg_log "review-gate: repair_json produced invalid JSON (reviewer=$reviewer)"
        return 1
    fi

    rg_log "review-gate: repair_json success reviewer=$reviewer"
    printf '%s' "$repaired"
}

# Extract the last agent_message text from a codex --json JSONL file.
# The verdict produced under `codex exec --output-schema` lands as the text of
# the final item.completed event with item.type=="agent_message". This is
# different from extract_last_json_object, which filters top-level objects for
# a direct verdict field — a test that no JSONL event satisfies.
extract_codex_agent_message() {
    local file="$1"
    [[ -s "$file" ]] || return 1

    local text
    text=$(jq -R -s -r '
        split("\n")
        | map(select(length > 0) | try fromjson catch empty)
        | map(select(
            (.type // "") == "item.completed" and
            (.item.type // "") == "agent_message"
        ))
        | if length == 0 then empty else .[-1].item.text // empty end
    ' "$file" 2>/dev/null || true)

    [[ -z "$text" ]] && return 1

    # Preferred: text is the structured verdict JSON (schema-enforced).
    local parsed
    if parsed=$(printf '%s' "$text" | jq -c '.' 2>/dev/null); then
        [[ -n "$parsed" ]] && { printf '%s' "$parsed"; return 0; }
    fi

    # Fallback: text is prose with an embedded verdict — fish out the last
    # review-like object via the existing scanner.
    local tmp
    tmp=$(mktemp)
    printf '%s' "$text" > "$tmp"
    parsed=$(extract_last_json_object "$tmp" "false" 2>/dev/null || true)
    rm -f "$tmp"

    [[ -z "$parsed" ]] && return 1
    printf '%s' "$parsed"
}

# Extract the last JSON object from a file.
extract_last_json_object() {
    local file="$1"
    local debug="${2:-false}"
    python3 - "$file" "$debug" <<'PY'
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
            # New format (codex --json -o FILE): FILE is pure JSON matching the schema.
            # Legacy format (plain stdout): TUI transcript; use extract_last_json_object.
            # If the primary file is empty (codex crashed before writing -o), pull the
            # verdict out of the sibling .jsonl by reading the last agent_message.
            rg_log "review-gate: extract_json codex trying direct jq on $file"
            if [[ -s "$file" ]]; then
                json=$(jq -c '.' "$file" 2>/dev/null || true)
            fi

            if [[ -z "$json" ]]; then
                rg_log "review-gate: extract_json codex falling back to extract_last_json_object"
                local debug_output
                debug_output=$(extract_last_json_object "$file" "true" 2>&1 >/dev/null || true)
                while IFS= read -r line; do
                    [[ -n "$line" ]] && rg_log "review-gate: $line"
                done <<< "$debug_output"
                json=$(extract_last_json_object "$file" "false" 2>/dev/null || true)
            fi

            if [[ -z "$json" && -f "${file%.json}.jsonl" ]]; then
                rg_log "review-gate: extract_json codex falling back to sibling .jsonl agent_message"
                json=$(extract_codex_agent_message "${file%.json}.jsonl" 2>/dev/null || true)
            fi

            if [[ -n "$json" ]]; then
                rg_log "review-gate: extract_json codex extracted len=${#json}"
                local preview="${json:0:200}"
                rg_log "review-gate: extract_json codex preview: $preview"
            else
                rg_log "review-gate: extract_json codex FAILED (empty result)"
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
            # NOTE: Use printf '%s' instead of echo to preserve backslash escapes
            rg_log "review-gate: extract_json claude extracting from metadata wrapper"
            local result_str
            result_str=$(jq -r '.result // empty' "$file" 2>/dev/null || true)
            if [[ -n "$result_str" ]]; then
                raw_output="$result_str"
            fi
            # Already-normalized review JSON path (e.g., the file was promoted
            # by run_debate_coordinator after augmenting with the additive
            # debate fields, so it is no longer in Claude's
            # `--output-format json` metadata wrapper shape). If the file
            # itself parses as a review object with a recognized verdict, use
            # it directly. This keeps the existing wrapper extraction below
            # as the primary path while letting downstream consumers
            # (`extract_json` from `review_gate_wait`, the Stop-hook, T011's
            # gate-report renderer) read the promoted Claude JSON without
            # going through repair.
            if [[ -z "$result_str" ]]; then
                local _claude_direct
                _claude_direct=$(jq -c 'select(type == "object" and (.verdict // null) != null)' "$file" 2>/dev/null || true)
                if [[ -n "$_claude_direct" ]]; then
                    rg_log "review-gate: extract_json claude file is already-normalized review JSON (no .result wrapper); using direct parse"
                    json="$_claude_direct"
                fi
            fi
            if [[ -n "$result_str" ]]; then
                # Try direct parse first (no fences)
                json=$(printf '%s' "$result_str" | jq -c '.' 2>/dev/null || true)
                if [[ -z "$json" ]]; then
                    # Result may be wrapped in ```json fences, strip them
                    local stripped
                    stripped=$(printf '%s' "$result_str" | sed '/^```json$/d; /^```$/d')
                    json=$(printf '%s' "$stripped" | jq -c '.' 2>/dev/null || true)
                fi
                if [[ -z "$json" ]]; then
                    # Fallback to extract_last_json_object using temp file
                    rg_log "review-gate: extract_json claude trying extract_last_json_object on result"
                    local tmp_file
                    tmp_file=$(mktemp)
                    printf '%s' "$result_str" > "$tmp_file"
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

    # NOTE: Use printf '%s' instead of echo to preserve backslash escapes in JSON
    if ! printf '%s' "$json" | jq -c '.' >/dev/null 2>&1; then
        rg_log "review-gate: extract_json $reviewer final jq validation FAILED"
        if [[ "$repaired" != "true" ]] && json=$(repair_review_output "$raw_output" "$schema_file" "$reviewer" "jq_failed"); then
            repaired="true"
        else
            return 1
        fi
        if ! printf '%s' "$json" | jq -c '.' >/dev/null 2>&1; then
            return 1
        fi
    fi

    # Log final extracted verdict for debugging
    local verdict
    verdict=$(printf '%s' "$json" | jq -r '.verdict // "NO_VERDICT"' 2>/dev/null || echo "JQ_ERROR")
    rg_log "review-gate: extract_json $reviewer SUCCESS verdict=$verdict"

    printf '%s' "$json" | jq -c '.'
}

# Spawn a reviewer subprocess.
#
# Args:
#   name         Reviewer name (used in output filenames).
#   cmd          Reviewer CLI command to invoke.
#   prompt_file  Path to the rendered reviewer prompt.
#   schema_file  Path to the structured-output schema (codex only).
#   output_dir   OPTIONAL output directory for {name}.json/.jsonl/.done/.failed.
#                Defaults to $REVIEWS_DIR (existing byte-stable behavior).
#                Debate coordinator (T006+) passes a per-round staging directory
#                like "iterations/<iter>/round-N/" so the canonical $REVIEWS_DIR
#                stays empty until final-round outputs are promoted. Non-debate
#                callers MUST omit this parameter to preserve R9 byte-parity.
spawn_reviewer() {
    local name="$1"
    local cmd="$2"
    local prompt_file="$3"
    local schema_file="$4"
    local output_dir="${5:-${REVIEWS_DIR:-}}"

    spawn_detached_review_shell() {
        local script="$1"
        local bash_bin="${BASH:-/bin/bash}"
        local old_hup old_int old_term child_pid

        if command -v setsid >/dev/null 2>&1; then
            nohup setsid "$bash_bin" -c "$script" </dev/null >/dev/null 2>&1 &
            return
        fi

        old_hup=$(trap -p HUP || true)
        old_int=$(trap -p INT || true)
        old_term=$(trap -p TERM || true)

        trap '' HUP INT TERM
        nohup "$bash_bin" -c "$script" </dev/null >/dev/null 2>&1 &
        child_pid=$!

        if [[ -n "$old_hup" ]]; then eval "$old_hup"; else trap - HUP; fi
        if [[ -n "$old_int" ]]; then eval "$old_int"; else trap - INT; fi
        if [[ -n "$old_term" ]]; then eval "$old_term"; else trap - TERM; fi

        disown "$child_pid" 2>/dev/null || true
    }

    if [[ -z "$output_dir" ]]; then
        echo "spawn_reviewer: output_dir is empty (REVIEWS_DIR unset and no override provided)" >&2
        return 1
    fi

    # Ensure output directory exists
    mkdir -p "$output_dir"

    local codex_model="${CODEX_MODEL_EFFECTIVE:-$CODEX_MODEL}"
    local gemini_model="${GEMINI_MODEL_EFFECTIVE:-$GEMINI_MODEL}"
    local claude_model="${CLAUDE_MODEL_EFFECTIVE:-$CLAUDE_MODEL}"
    local codex_reasoning="${CODEX_REASONING_EFFORT:-high}"
    local reviewer_timeout="${REVIEW_GATE_REVIEWER_TIMEOUT:-1800}"
    local reviewer_timeout_bin="${TIMEOUT_BIN:-$(command -v timeout || command -v gtimeout || true)}"

    local output_file="$output_dir/${name}.json"
    local transcript_file="$output_dir/${name}.jsonl"
    local sentinel_file="$output_dir/${name}.done"
    local failed_file="$output_dir/${name}.failed"

    # Skip missing CLIs with warning
    if ! command -v "$cmd" >/dev/null; then
        echo "Skipping $name: $cmd not found" >&2
        return 1
    fi

    case "$name" in
        gemini)
            local gemini_settings=""
            local gemini_policy=""
            if ! gemini_settings=$(gemini_readonly_settings_path); then
                echo "Skipping gemini: read-only settings missing" >&2
                return 1
            fi
            if ! gemini_policy=$(gemini_readonly_policy_path); then
                echo "Skipping gemini: read-only policy missing" >&2
                return 1
            fi
            echo "Spawning gemini reviewer (model: $gemini_model)..." >&2
            GEMINI_CLI_SYSTEM_SETTINGS_PATH="$gemini_settings" \
            REVIEW_OUT="$output_file" \
            REVIEW_DONE="$sentinel_file" \
            REVIEW_FAIL="$failed_file" \
            REVIEW_PROMPT="$prompt_file" \
            REVIEW_POLICY="$gemini_policy" \
            REVIEW_MODEL="$gemini_model" \
            REVIEW_TIMEOUT="$reviewer_timeout" \
            REVIEW_TIMEOUT_BIN="$reviewer_timeout_bin" \
            spawn_detached_review_shell '
                timeout_prefix=()
                if [[ -n "${REVIEW_TIMEOUT_BIN:-}" && -n "${REVIEW_TIMEOUT:-}" ]]; then
                    timeout_prefix=("$REVIEW_TIMEOUT_BIN" "$REVIEW_TIMEOUT")
                fi
                if "${timeout_prefix[@]}" gemini -m "$REVIEW_MODEL" --approval-mode plan -p "" --policy "$REVIEW_POLICY" --admin-policy "$REVIEW_POLICY" --output-format json < "$REVIEW_PROMPT" > "$REVIEW_OUT" 2>&1; then
                    touch "$REVIEW_DONE"
                else
                    touch "$REVIEW_FAIL"
                fi
            '
            ;;
        codex)
            # Note: the heredoc body runs via spawn_detached_review_shell -> `bash -c`,
            # which starts a fresh shell without `set -u`, so the unguarded
            # "${codex_extra_args[@]}" expansion below is safe under bash 3.2.
            echo "Spawning codex reviewer (model: $codex_model, reasoning: $codex_reasoning)..." >&2
            REVIEW_OUT="$output_file" \
            REVIEW_JSONL="$transcript_file" \
            REVIEW_DONE="$sentinel_file" \
            REVIEW_FAIL="$failed_file" \
            REVIEW_PROMPT="$prompt_file" \
            REVIEW_SCHEMA="$schema_file" \
            REVIEW_MODEL="$codex_model" \
            REVIEW_REASONING="$codex_reasoning" \
            REVIEW_TIMEOUT="$reviewer_timeout" \
            REVIEW_TIMEOUT_BIN="$reviewer_timeout_bin" \
            spawn_detached_review_shell '
                timeout_prefix=()
                if [[ -n "${REVIEW_TIMEOUT_BIN:-}" && -n "${REVIEW_TIMEOUT:-}" ]]; then
                    timeout_prefix=("$REVIEW_TIMEOUT_BIN" "$REVIEW_TIMEOUT")
                fi
                codex_extra_args=()
                if codex exec --help 2>&1 | grep -q -- "--ephemeral"; then
                    codex_extra_args=(--ephemeral)
                fi
                if "${timeout_prefix[@]}" codex exec "${codex_extra_args[@]}" -m "$REVIEW_MODEL" -c "model_reasoning_effort=$REVIEW_REASONING" -s read-only --skip-git-repo-check --output-schema "$REVIEW_SCHEMA" --json -o "$REVIEW_OUT" - < "$REVIEW_PROMPT" > "$REVIEW_JSONL" 2>&1; then
                    touch "$REVIEW_DONE"
                else
                    touch "$REVIEW_FAIL"
                fi
            '
            ;;
        claude)
            echo "Spawning claude reviewer (model: $claude_model)..." >&2
            CLAUDE_ALLOWED_TOOLS="$CLAUDE_READONLY_ALLOWED_TOOLS" \
            CLAUDE_DISALLOWED_TOOLS="$CLAUDE_READONLY_DISALLOWED_TOOLS" \
            REVIEW_OUT="$output_file" \
            REVIEW_DONE="$sentinel_file" \
            REVIEW_FAIL="$failed_file" \
            REVIEW_PROMPT="$prompt_file" \
            REVIEW_MODEL="$claude_model" \
            REVIEW_TIMEOUT="$reviewer_timeout" \
            REVIEW_TIMEOUT_BIN="$reviewer_timeout_bin" \
            spawn_detached_review_shell '
                timeout_prefix=()
                if [[ -n "${REVIEW_TIMEOUT_BIN:-}" && -n "${REVIEW_TIMEOUT:-}" ]]; then
                    timeout_prefix=("$REVIEW_TIMEOUT_BIN" "$REVIEW_TIMEOUT")
                fi
                read -r -a claude_allowed_tools <<< "$CLAUDE_ALLOWED_TOOLS"
                read -r -a claude_disallowed_tools <<< "$CLAUDE_DISALLOWED_TOOLS"
                if "${timeout_prefix[@]}" claude -p --model "$REVIEW_MODEL" --output-format json \
                    --allowedTools "${claude_allowed_tools[@]}" \
                    --disallowedTools "${claude_disallowed_tools[@]}" \
                    < "$REVIEW_PROMPT" > "$REVIEW_OUT" 2>&1; then
                    touch "$REVIEW_DONE"
                else
                    touch "$REVIEW_FAIL"
                fi
            '
            ;;
        *)
            echo "Unknown reviewer: $name" >&2
            return 1
            ;;
    esac

    return 0
}
