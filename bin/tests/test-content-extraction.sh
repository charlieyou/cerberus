#!/usr/bin/env bash
# Unit tests for content extraction functions in generate script
#
# Tests verify that extract_claude_content and extract_gemini_content
# correctly handle various JSON output formats including:
# - Simple top-level .result strings
# - Content arrays with {type:"text", text:"..."} blocks
# - Nested message structures
# - Fallback to raw file on parse failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

# Define extraction functions (copied from generate script for testing)
# These must match the implementations in bin/generate

extract_claude_content() {
    local raw_file="$1"
    local content
    content=$(jq -r '
        # Strategy 1: Simple top-level string fields (most common for CLI output)
        if (.result | type) == "string" and (.result | length) > 0 then .result
        elif (.response | type) == "string" and (.response | length) > 0 then .response

        # Strategy 2: Content as array of content blocks (Claude API format)
        elif (.content | type) == "array" then
            [.content[] | select(.type == "text" or .type == "output_text") | .text // empty] | join("")

        # Strategy 3: Content as direct string
        elif (.content | type) == "string" and (.content | length) > 0 then .content

        # Strategy 4: Nested message.content array
        elif (.message.content | type) == "array" then
            [.message.content[] | select(.type == "text") | .text // empty] | join("")
        elif (.message.content | type) == "string" then .message.content

        # Strategy 5: messages array with assistant responses
        elif (.messages | type) == "array" then
            [.messages[] | select(.role == "assistant") |
             if (.content | type) == "array" then
                 [.content[] | select(.type == "text") | .text // empty] | join("")
             elif (.content | type) == "string" then .content
             else empty end
            ] | join("\n\n")

        # Strategy 6: text field directly
        elif (.text | type) == "string" and (.text | length) > 0 then .text

        # Strategy 7: output field (alternative naming)
        elif (.output | type) == "string" and (.output | length) > 0 then .output

        else empty
        end
    ' "$raw_file" 2>/dev/null)

    if [[ -z "$content" ]]; then
        cat "$raw_file"
    else
        printf '%s' "$content"
    fi
}

extract_gemini_content() {
    local raw_file="$1"
    local json_file="$raw_file"
    local tmp_json=""
    if ! jq -e . "$raw_file" >/dev/null 2>&1; then
        tmp_json=$(mktemp)
        awk 'found || $0 ~ /^[[:space:]]*\{/ || $0 ~ /^[[:space:]]*\[/ { found=1; print }' "$raw_file" > "$tmp_json"
        json_file="$tmp_json"
    fi
    local content
    content=$(jq -r '
        # Strategy 1: Simple top-level string fields
        if (.response | type) == "string" and (.response | length) > 0 then .response
        elif (.text | type) == "string" and (.text | length) > 0 then .text

        # Strategy 2: Content as array of content blocks (Gemini API format)
        elif (.content | type) == "array" then
            [.content[] | select(.type == "text" or .text) | .text // empty] | join("")

        # Strategy 3: Content as direct string
        elif (.content | type) == "string" and (.content | length) > 0 then .content

        # Strategy 4: Candidates array (Gemini API response format)
        elif (.candidates | type) == "array" then
            [.candidates[].content.parts[]? | select(.text) | .text] | join("")

        # Strategy 5: result field
        elif (.result | type) == "string" and (.result | length) > 0 then .result

        # Strategy 6: output field
        elif (.output | type) == "string" and (.output | length) > 0 then .output

        else empty
        end
    ' "$json_file" 2>/dev/null || true)
    [[ -n "$tmp_json" ]] && rm -f "$tmp_json"

    if [[ -z "$content" ]]; then
        cat "$raw_file"
    else
        printf '%s' "$content"
    fi
}

extract_codex_content() {
    local raw_file="$1"
    local content
    content=$(jq -R -s -r '
        split("\n")
        | map(select(length > 0) | try fromjson catch empty)
        |
        ([.[] | select(
            (.type // "") == "item.completed" and
            (.item.type // "") == "agent_message"
        ) | .item.text // empty] | last // "") as $agent_message |
        ([.[] | select(.item.content) | .item.content |
          if type == "array" then .[] | select(.text) | .text
          elif type == "string" then .
          else empty end
        ] | join("")) as $item_content |
        ([.[] | select(.role == "assistant" and .content) | .content] | join("")) as $assistant |
        ([.[] | select(.response.output_text) | .response.output_text] | join("")) as $resp_out |
        ([.[] | select(.output and (.output | type) == "string") | .output] | join("")) as $output |
        ([.[] | select(.message.content) | .message.content] | join("")) as $msg |
        ([.[] | select(.content and (.content | type) == "string") | .content] | join("")) as $content |
        ([.[] | select(.text and (.text | type) == "string") | .text] | join("")) as $text |
        ([.[] | select(.item.output) | .item.output |
          if type == "string" then . else empty end
        ] | join("")) as $item_output |

        if ($agent_message | length) > 0 then $agent_message
        elif ($item_content | length) > 0 then $item_content
        elif ($assistant | length) > 0 then $assistant
        elif ($resp_out | length) > 0 then $resp_out
        elif ($output | length) > 0 then $output
        elif ($msg | length) > 0 then $msg
        elif ($content | length) > 0 then $content
        elif ($text | length) > 0 then $text
        elif ($item_output | length) > 0 then $item_output
        else empty
        end
    ' "$raw_file" 2>/dev/null || true)

    if [[ -z "$content" ]]; then
        cat "$raw_file"
    else
        printf '%s' "$content"
    fi
}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

log_test() {
    echo -e "${YELLOW}TEST:${NC} $1"
}

log_pass() {
    echo -e "${GREEN}PASS:${NC} $1"
    ((TESTS_PASSED++)) || true
}

log_fail() {
    echo -e "${RED}FAIL:${NC} $1"
    ((TESTS_FAILED++)) || true
}

# =============================================================================
# Claude Content Extraction Tests
# =============================================================================

test_claude_simple_result() {
    ((TESTS_RUN++)) || true
    log_test "extract_claude_content with simple .result string"

    local result
    result=$(extract_claude_content "$FIXTURES_DIR/claude-output.json")

    if [[ "$result" == *"# Code Review"* && "$result" == *"Looks good!"* ]]; then
        log_pass "Extracted content from .result field"
    else
        log_fail "Failed to extract from .result field: ${result:0:100}"
    fi
}

test_claude_content_array() {
    ((TESTS_RUN++)) || true
    log_test "extract_claude_content with content array format"

    local result
    result=$(extract_claude_content "$FIXTURES_DIR/claude-output-content-array.json")

    if [[ "$result" == *"# Code Review"* && "$result" == *"This code looks great!"* && "$result" == *"All tests pass"* ]]; then
        log_pass "Extracted and concatenated content from content array"
    else
        log_fail "Failed to extract from content array: ${result:0:100}"
    fi
}

test_claude_nested_message() {
    ((TESTS_RUN++)) || true
    log_test "extract_claude_content with nested message.content"

    local result
    result=$(extract_claude_content "$FIXTURES_DIR/claude-output-nested-message.json")

    if [[ "$result" == *"# Architecture Review"* && "$result" == *"best practices"* ]]; then
        log_pass "Extracted content from nested message.content"
    else
        log_fail "Failed to extract from nested message: ${result:0:100}"
    fi
}

test_claude_fallback_raw() {
    ((TESTS_RUN++)) || true
    log_test "extract_claude_content falls back to raw file on unknown format"

    # Create a temp file with non-JSON content
    local tmp_file
    tmp_file=$(mktemp)
    echo "Plain text response without JSON structure" > "$tmp_file"

    local result
    result=$(extract_claude_content "$tmp_file")
    rm -f "$tmp_file"

    if [[ "$result" == *"Plain text response"* ]]; then
        log_pass "Fell back to raw file contents"
    else
        log_fail "Fallback failed: ${result:0:100}"
    fi
}

test_claude_empty_content_array() {
    ((TESTS_RUN++)) || true
    log_test "extract_claude_content handles empty content array gracefully"

    local tmp_file
    tmp_file=$(mktemp)
    echo '{"content": [], "session_id": "test"}' > "$tmp_file"

    local result
    result=$(extract_claude_content "$tmp_file")
    rm -f "$tmp_file"

    # Should fall back to raw file since content array yields empty
    if [[ -n "$result" ]]; then
        log_pass "Handled empty content array (fell back to raw)"
    else
        log_fail "Empty content array produced empty result"
    fi
}

test_claude_mixed_content_types() {
    ((TESTS_RUN++)) || true
    log_test "extract_claude_content filters for text type in content array"

    local tmp_file
    tmp_file=$(mktemp)
    cat > "$tmp_file" << 'EOF'
{
  "content": [
    {"type": "text", "text": "Hello "},
    {"type": "tool_use", "id": "123", "name": "read_file"},
    {"type": "text", "text": "World!"},
    {"type": "thinking", "thinking": "internal thoughts"}
  ]
}
EOF

    local result
    result=$(extract_claude_content "$tmp_file")
    rm -f "$tmp_file"

    if [[ "$result" == "Hello World!" ]]; then
        log_pass "Correctly filtered for text type blocks"
    else
        log_fail "Filter failed, got: $result"
    fi
}

# =============================================================================
# Gemini Content Extraction Tests
# =============================================================================

test_gemini_simple_response() {
    ((TESTS_RUN++)) || true
    log_test "extract_gemini_content with simple .response string"

    local result
    result=$(extract_gemini_content "$FIXTURES_DIR/gemini-output.json")

    if [[ -n "$result" ]]; then
        log_pass "Extracted content from gemini output"
    else
        log_fail "Failed to extract gemini content"
    fi
}

test_gemini_candidates_format() {
    ((TESTS_RUN++)) || true
    log_test "extract_gemini_content with candidates array (API format)"

    local tmp_file
    tmp_file=$(mktemp)
    cat > "$tmp_file" << 'EOF'
{
  "candidates": [
    {
      "content": {
        "parts": [
          {"text": "Part 1 of response. "},
          {"text": "Part 2 of response."}
        ]
      }
    }
  ]
}
EOF

    local result
    result=$(extract_gemini_content "$tmp_file")
    rm -f "$tmp_file"

    if [[ "$result" == *"Part 1"* && "$result" == *"Part 2"* ]]; then
        log_pass "Extracted from candidates array format"
    else
        log_fail "Failed candidates extraction: ${result:0:100}"
    fi
}

test_gemini_ignores_retry_preamble() {
    ((TESTS_RUN++)) || true
    log_test "extract_gemini_content ignores retry preamble before JSON"

    local tmp_file
    tmp_file=$(mktemp)
    cat > "$tmp_file" <<'EOF'
Attempt 1 failed: transient quota. Retrying...
{
  "response": "Recovered Gemini response"
}
EOF

    local result
    result=$(extract_gemini_content "$tmp_file")
    rm -f "$tmp_file"

    if [[ "$result" == "Recovered Gemini response" ]]; then
        log_pass "Ignored Gemini preamble and extracted JSON response"
    else
        log_fail "Gemini preamble extraction failed: ${result:0:100}"
    fi
}

# =============================================================================
# Codex Content Extraction Tests
# =============================================================================

test_codex_agent_message_preferred() {
    ((TESTS_RUN++)) || true
    log_test "extract_codex_content prefers final agent_message over tool output"

    local tmp_file
    tmp_file=$(mktemp)
    cat > "$tmp_file" <<'EOF'
{"type":"item.completed","item":{"type":"function_call_output","output":"tool output should not win"}}
{"type":"item.completed","item":{"type":"agent_message","text":"final codex draft"}}
{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}
EOF

    local result
    result=$(extract_codex_content "$tmp_file")
    rm -f "$tmp_file"

    if [[ "$result" == "final codex draft" ]]; then
        log_pass "Extracted final agent_message"
    else
        log_fail "Expected final agent_message, got: ${result:0:100}"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo "=========================================="
    echo "Content Extraction Unit Tests"
    echo "=========================================="
    echo ""

    # Claude tests
    test_claude_simple_result
    test_claude_content_array
    test_claude_nested_message
    test_claude_fallback_raw
    test_claude_empty_content_array
    test_claude_mixed_content_types

    # Gemini tests
    test_gemini_simple_response
    test_gemini_candidates_format
    test_gemini_ignores_retry_preamble

    # Codex tests
    test_codex_agent_message_preferred

    echo ""
    echo "=========================================="
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
    echo "=========================================="

    if [[ $TESTS_FAILED -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
