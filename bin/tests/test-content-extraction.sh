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
    ' "$raw_file" 2>/dev/null)

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

    echo ""
    echo "=========================================="
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
    echo "=========================================="

    if [[ $TESTS_FAILED -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
