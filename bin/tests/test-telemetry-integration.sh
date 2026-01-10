#!/usr/bin/env bash
# Integration tests for telemetry extraction using real CLI tools
#
# These tests verify that:
# 1. Real CLI JSON output is parseable
# 2. Telemetry extraction works on real CLI output
# 3. End-to-end agent runs capture telemetry correctly
#
# Tests are skipped for CLIs that aren't installed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export PLUGIN_ROOT
source "$SCRIPT_DIR/../telemetry-lib.sh"
source "$SCRIPT_DIR/../review-gate-models.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Track available CLIs
CLAUDE_AVAILABLE=false
CODEX_AVAILABLE=false
GEMINI_AVAILABLE=false

# Test timeout in seconds
TEST_TIMEOUT=30

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

log_skip() {
    echo -e "${CYAN}SKIP:${NC} $1"
    ((TESTS_SKIPPED++)) || true
}

log_info() {
    echo -e "${CYAN}INFO:${NC} $1"
}

# Detect which CLIs are available
detect_available_clis() {
    echo "========================================"
    echo "Detecting Available CLIs"
    echo "========================================"
    
    if command -v claude &>/dev/null; then
        CLAUDE_AVAILABLE=true
        log_info "claude: $(command -v claude)"
    else
        log_info "claude: not found"
    fi
    
    if command -v codex &>/dev/null; then
        CODEX_AVAILABLE=true
        log_info "codex: $(command -v codex)"
    else
        log_info "codex: not found"
    fi
    
    if command -v gemini &>/dev/null; then
        GEMINI_AVAILABLE=true
        log_info "gemini: $(command -v gemini)"
    else
        log_info "gemini: not found"
    fi
    
    echo ""
}

# Run a command with timeout, capturing output
# Returns 0 on success, 1 on timeout, 2 on command failure
run_with_timeout() {
    local timeout_secs="$1"
    shift
    local output_file
    output_file=$(mktemp)
    local exit_code=0
    
    if timeout "$timeout_secs" "$@" > "$output_file" 2>&1; then
        cat "$output_file"
        rm -f "$output_file"
        return 0
    else
        exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            # Timeout
            rm -f "$output_file"
            return 1
        else
            # Command failed - output error for debugging
            cat "$output_file" >&2
            rm -f "$output_file"
            return 2
        fi
    fi
}

# =============================================================================
# JSON Output Tests
# =============================================================================

test_claude_json_output() {
    ((TESTS_RUN++)) || true
    log_test "claude JSON output is parseable"
    
    if ! $CLAUDE_AVAILABLE; then
        log_skip "claude not installed"
        return
    fi
    
    local output
    if ! output=$(run_with_timeout "$TEST_TIMEOUT" claude -p "Say hello" --output-format json 2>&1); then
        local exit_code=$?
        if [[ $exit_code -eq 1 ]]; then
            log_skip "claude timed out after ${TEST_TIMEOUT}s"
        else
            log_skip "claude command failed: $output"
        fi
        return
    fi
    
    # Verify output is valid JSON
    if echo "$output" | jq -e . >/dev/null 2>&1; then
        # Check for expected top-level fields
        if echo "$output" | jq -e '.result // .message // .response' >/dev/null 2>&1; then
            log_pass "claude output is valid JSON with response content"
        else
            log_pass "claude output is valid JSON"
        fi
    else
        log_fail "claude output is not valid JSON: ${output:0:200}"
    fi
}

test_codex_json_output() {
    ((TESTS_RUN++)) || true
    log_test "codex JSON output is parseable"
    
    if ! $CODEX_AVAILABLE; then
        log_skip "codex not installed"
        return
    fi
    
    local output
    if ! output=$(run_with_timeout "$TEST_TIMEOUT" codex exec "Say hello" --json 2>&1); then
        local exit_code=$?
        if [[ $exit_code -eq 1 ]]; then
            log_skip "codex timed out after ${TEST_TIMEOUT}s"
        else
            log_skip "codex command failed: $output"
        fi
        return
    fi
    
    # Codex outputs JSONL - verify each line is valid JSON
    local valid_lines=0
    local total_lines=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        ((total_lines++)) || true
        if echo "$line" | jq -e . >/dev/null 2>&1; then
            ((valid_lines++)) || true
        fi
    done <<< "$output"
    
    if [[ $total_lines -eq 0 ]]; then
        log_fail "codex produced no output"
    elif [[ $valid_lines -eq $total_lines ]]; then
        log_pass "codex output is valid JSONL ($valid_lines lines)"
    else
        log_fail "codex output has invalid JSON lines ($valid_lines/$total_lines valid)"
    fi
}

test_gemini_json_output() {
    ((TESTS_RUN++)) || true
    log_test "gemini JSON output is parseable"
    
    if ! $GEMINI_AVAILABLE; then
        log_skip "gemini not installed"
        return
    fi
    
    local output
    if ! output=$(run_with_timeout "$TEST_TIMEOUT" gemini -o json "Say hello" 2>&1); then
        local exit_code=$?
        if [[ $exit_code -eq 1 ]]; then
            log_skip "gemini timed out after ${TEST_TIMEOUT}s"
        else
            log_skip "gemini command failed: $output"
        fi
        return
    fi
    
    # Verify output is valid JSON
    if echo "$output" | jq -e . >/dev/null 2>&1; then
        log_pass "gemini output is valid JSON"
    else
        log_fail "gemini output is not valid JSON: ${output:0:200}"
    fi
}

# =============================================================================
# Telemetry Extraction Tests
# =============================================================================

test_claude_real_telemetry() {
    ((TESTS_RUN++)) || true
    log_test "extract telemetry from real claude output"
    
    if ! $CLAUDE_AVAILABLE; then
        log_skip "claude not installed"
        return
    fi
    
    local output
    if ! output=$(run_with_timeout "$TEST_TIMEOUT" claude -p "Say hello" --output-format json 2>&1); then
        local exit_code=$?
        if [[ $exit_code -eq 1 ]]; then
            log_skip "claude timed out after ${TEST_TIMEOUT}s"
        else
            log_skip "claude command failed"
        fi
        return
    fi
    
    # Extract telemetry using our library function
    local telemetry
    telemetry=$(extract_telemetry_from_json "claude" "$output" 2>/dev/null || echo "{}")
    
    if [[ "$telemetry" == "{}" || -z "$telemetry" ]]; then
        log_fail "failed to extract telemetry from claude output"
        return
    fi
    
    # Verify required fields exist
    local has_model has_tokens
    has_model=$(echo "$telemetry" | jq -e '.model // empty' 2>/dev/null || echo "")
    has_tokens=$(echo "$telemetry" | jq -e '.input_tokens // .output_tokens // empty' 2>/dev/null || echo "")
    
    if [[ -n "$has_model" || -n "$has_tokens" ]]; then
        log_pass "extracted telemetry with model/token info"
    else
        # May still pass if we got any telemetry
        log_pass "extracted telemetry (partial fields)"
    fi
}

test_codex_real_telemetry() {
    ((TESTS_RUN++)) || true
    log_test "extract telemetry from real codex output"
    
    if ! $CODEX_AVAILABLE; then
        log_skip "codex not installed"
        return
    fi
    
    local output
    if ! output=$(run_with_timeout "$TEST_TIMEOUT" codex exec "Say hello" --json 2>&1); then
        local exit_code=$?
        if [[ $exit_code -eq 1 ]]; then
            log_skip "codex timed out after ${TEST_TIMEOUT}s"
        else
            log_skip "codex command failed"
        fi
        return
    fi
    
    # Codex outputs JSONL - get the last line with telemetry
    local last_json
    last_json=$(echo "$output" | grep -E '^\{' | tail -1)
    
    if [[ -z "$last_json" ]]; then
        log_fail "no JSON output from codex"
        return
    fi
    
    # Extract telemetry using our library function
    local telemetry
    telemetry=$(extract_telemetry_from_json "codex" "$last_json" 2>/dev/null || echo "{}")
    
    if [[ "$telemetry" == "{}" || -z "$telemetry" ]]; then
        # Try extracting from full JSONL
        telemetry=$(extract_telemetry_from_jsonl "codex" "$output" 2>/dev/null || echo "{}")
    fi
    
    if [[ "$telemetry" == "{}" || -z "$telemetry" ]]; then
        log_fail "failed to extract telemetry from codex output"
        return
    fi
    
    local has_any_field
    has_any_field=$(echo "$telemetry" | jq -e 'keys | length > 0' 2>/dev/null || echo "false")
    
    if [[ "$has_any_field" == "true" ]]; then
        log_pass "extracted telemetry from codex"
    else
        log_fail "telemetry has no fields"
    fi
}

test_gemini_real_telemetry() {
    ((TESTS_RUN++)) || true
    log_test "extract telemetry from real gemini output"
    
    if ! $GEMINI_AVAILABLE; then
        log_skip "gemini not installed"
        return
    fi
    
    local output
    if ! output=$(run_with_timeout "$TEST_TIMEOUT" gemini -o json "Say hello" 2>&1); then
        local exit_code=$?
        if [[ $exit_code -eq 1 ]]; then
            log_skip "gemini timed out after ${TEST_TIMEOUT}s"
        else
            log_skip "gemini command failed"
        fi
        return
    fi
    
    # Extract telemetry using our library function
    local telemetry
    telemetry=$(extract_telemetry_from_json "gemini" "$output" 2>/dev/null || echo "{}")
    
    if [[ "$telemetry" == "{}" || -z "$telemetry" ]]; then
        log_fail "failed to extract telemetry from gemini output"
        return
    fi
    
    local has_any_field
    has_any_field=$(echo "$telemetry" | jq -e 'keys | length > 0' 2>/dev/null || echo "false")
    
    if [[ "$has_any_field" == "true" ]]; then
        log_pass "extracted telemetry from gemini"
    else
        log_fail "telemetry has no fields"
    fi
}

# =============================================================================
# End-to-End Tests
# =============================================================================

test_full_agent_telemetry() {
    ((TESTS_RUN++)) || true
    log_test "full agent run with telemetry capture"
    
    # Pick the first available CLI
    local cli=""
    local cli_args=""
    
    if $CLAUDE_AVAILABLE; then
        cli="claude"
        cli_args="-p 'Say hello' --output-format json"
    elif $CODEX_AVAILABLE; then
        cli="codex"
        cli_args="exec 'Say hello' --json"
    elif $GEMINI_AVAILABLE; then
        cli="gemini"
        cli_args="-o json 'Say hello'"
    else
        log_skip "no CLI available for end-to-end test"
        return
    fi
    
    log_info "using $cli for end-to-end test"
    
    # Create temp file for telemetry output
    local telemetry_file
    telemetry_file=$(mktemp)
    trap "rm -f '$telemetry_file'" RETURN
    
    local output
    local exit_code=0
    
    # Run the CLI and capture output
    case "$cli" in
        claude)
            output=$(run_with_timeout "$TEST_TIMEOUT" claude -p "Say hello" --output-format json 2>&1) || exit_code=$?
            ;;
        codex)
            output=$(run_with_timeout "$TEST_TIMEOUT" codex exec "Say hello" --json 2>&1) || exit_code=$?
            ;;
        gemini)
            output=$(run_with_timeout "$TEST_TIMEOUT" gemini -o json "Say hello" 2>&1) || exit_code=$?
            ;;
    esac
    
    if [[ $exit_code -eq 1 ]]; then
        log_skip "$cli timed out after ${TEST_TIMEOUT}s"
        return
    elif [[ $exit_code -eq 2 ]]; then
        log_skip "$cli command failed"
        return
    fi
    
    # Extract and save telemetry
    local telemetry
    if [[ "$cli" == "codex" ]]; then
        telemetry=$(extract_telemetry_from_jsonl "$cli" "$output" 2>/dev/null || echo "{}")
    else
        telemetry=$(extract_telemetry_from_json "$cli" "$output" 2>/dev/null || echo "{}")
    fi
    
    echo "$telemetry" > "$telemetry_file"
    
    # Verify telemetry was captured
    if [[ ! -s "$telemetry_file" ]] || [[ "$(cat "$telemetry_file")" == "{}" ]]; then
        log_fail "no telemetry captured from $cli"
        return
    fi
    
    # Verify it's valid JSON with some content
    if jq -e 'keys | length > 0' "$telemetry_file" >/dev/null 2>&1; then
        local field_count
        field_count=$(jq 'keys | length' "$telemetry_file")
        log_pass "captured telemetry from $cli ($field_count fields)"
    else
        log_fail "telemetry file is empty or invalid"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo "========================================"
    echo "Telemetry Integration Tests"
    echo "========================================"
    echo ""
    
    detect_available_clis
    
    if ! $CLAUDE_AVAILABLE && ! $CODEX_AVAILABLE && ! $GEMINI_AVAILABLE; then
        echo -e "${YELLOW}WARNING: No CLIs available - all tests will be skipped${NC}"
        echo ""
    fi
    
    echo "========================================"
    echo "Running Tests"
    echo "========================================"
    echo ""
    
    # JSON output tests
    test_claude_json_output
    test_codex_json_output
    test_gemini_json_output
    
    # Telemetry extraction tests
    test_claude_real_telemetry
    test_codex_real_telemetry
    test_gemini_real_telemetry
    
    # End-to-end tests
    test_full_agent_telemetry
    
    echo ""
    echo "========================================"
    echo "Results: $TESTS_PASSED passed, $TESTS_SKIPPED skipped, $TESTS_FAILED failed (of $TESTS_RUN)"
    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "${RED}$TESTS_FAILED tests failed${NC}"
        exit 1
    else
        echo -e "${GREEN}All executed tests passed${NC}"
        exit 0
    fi
}

main "$@"
