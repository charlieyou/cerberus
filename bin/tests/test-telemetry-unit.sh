#!/usr/bin/env bash
# Unit tests for telemetry-lib.sh
#
# These tests verify:
# 1. Fixture parsing for Claude, Codex, and Gemini output formats
# 2. Atomic file operations (write, JSON update with flock)
# 3. Version detection from plugin.json
# 4. Iteration directory structure and file writing
# 5. Run telemetry aggregation
# 6. Error handling for malformed/missing data

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../telemetry-lib.sh"

FIXTURES_DIR="$SCRIPT_DIR/fixtures"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Track test dirs for cleanup
declare -a TEST_DIRS=()

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

# Create a temporary directory for testing
# Sets TEST_DIR variable
setup_test_dir() {
    TEST_DIR=$(mktemp -d)
    TEST_DIRS+=("$TEST_DIR")
}

# Create a temporary git repo for testing
# Sets TEST_DIR variable and changes to that directory
setup_test_repo() {
    TEST_DIR=$(mktemp -d)
    TEST_DIRS+=("$TEST_DIR")
    cd "$TEST_DIR"
    export HOME="$TEST_DIR/home"
    mkdir -p "$HOME"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"
    
    # Create initial commit
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "initial commit"
}

cleanup_all() {
    for dir in "${TEST_DIRS[@]}"; do
        rm -rf "$dir" 2>/dev/null || true
    done
}

trap cleanup_all EXIT

# Helper to compare JSON with normalization (ignores field ordering and whitespace)
json_equal() {
    local json1="$1"
    local json2="$2"
    local norm1 norm2
    
    norm1=$(printf '%s' "$json1" | jq -S '.' 2>/dev/null) || return 1
    norm2=$(printf '%s' "$json2" | jq -S '.' 2>/dev/null) || return 1
    
    [[ "$norm1" == "$norm2" ]]
}

# Helper to compare specific fields (ignores extracted_at timestamp)
json_fields_match() {
    local actual="$1"
    local expected="$2"
    local fields="$3"
    
    local actual_filtered expected_filtered
    actual_filtered=$(printf '%s' "$actual" | jq -S "{ $fields }" 2>/dev/null) || return 1
    expected_filtered=$(printf '%s' "$expected" | jq -S "{ $fields }" 2>/dev/null) || return 1
    
    [[ "$actual_filtered" == "$expected_filtered" ]]
}

# ============================================================================
# FIXTURE PARSING TESTS
# ============================================================================

test_extract_claude_telemetry() {
    ((TESTS_RUN++)) || true
    log_test "extract_claude_telemetry parses fixture correctly"
    
    local actual expected
    actual=$(extract_claude_telemetry "$FIXTURES_DIR/claude-output.json")
    expected=$(cat "$FIXTURES_DIR/expected-claude-stats.json")
    
    # Compare key fields that extraction produces (ignore extracted_at, total, duration_api_ms)
    local actual_agent actual_session actual_model actual_input actual_output actual_cached actual_duration actual_cost
    actual_agent=$(printf '%s' "$actual" | jq -r '.agent')
    actual_session=$(printf '%s' "$actual" | jq -r '.session_id')
    actual_model=$(printf '%s' "$actual" | jq -r '.model')
    actual_input=$(printf '%s' "$actual" | jq -r '.tokens.input')
    actual_output=$(printf '%s' "$actual" | jq -r '.tokens.output')
    actual_cached=$(printf '%s' "$actual" | jq -r '.tokens.cached')
    actual_duration=$(printf '%s' "$actual" | jq -r '.duration_ms')
    actual_cost=$(printf '%s' "$actual" | jq -r '.cost_usd')
    
    local exp_agent exp_session exp_model exp_input exp_output exp_cached exp_duration exp_cost
    exp_agent=$(printf '%s' "$expected" | jq -r '.agent')
    exp_session=$(printf '%s' "$expected" | jq -r '.session_id')
    exp_model=$(printf '%s' "$expected" | jq -r '.model')
    exp_input=$(printf '%s' "$expected" | jq -r '.tokens.input')
    exp_output=$(printf '%s' "$expected" | jq -r '.tokens.output')
    exp_cached=$(printf '%s' "$expected" | jq -r '.tokens.cached')
    exp_duration=$(printf '%s' "$expected" | jq -r '.duration_ms')
    exp_cost=$(printf '%s' "$expected" | jq -r '.cost_usd')
    
    if [[ "$actual_agent" == "$exp_agent" && "$actual_session" == "$exp_session" && \
          "$actual_model" == "$exp_model" && "$actual_input" == "$exp_input" && \
          "$actual_output" == "$exp_output" && "$actual_cached" == "$exp_cached" && \
          "$actual_duration" == "$exp_duration" && "$actual_cost" == "$exp_cost" ]]; then
        log_pass "claude telemetry extraction matches expected"
    else
        log_fail "claude telemetry mismatch"
        echo "  Actual: $actual"
        echo "  Expected: $expected"
    fi
}

test_extract_codex_telemetry() {
    ((TESTS_RUN++)) || true
    log_test "extract_codex_telemetry parses JSONL fixture correctly"
    
    local actual expected
    actual=$(extract_codex_telemetry "$FIXTURES_DIR/codex-output.jsonl")
    expected=$(cat "$FIXTURES_DIR/expected-codex-stats.json")
    
    # Check key fields - codex parsing extracts thread_id as session_id
    local actual_agent actual_session
    actual_agent=$(printf '%s' "$actual" | jq -r '.agent')
    actual_session=$(printf '%s' "$actual" | jq -r '.session_id')
    
    if [[ "$actual_agent" == "codex" && "$actual_session" == "thread-xyz" ]]; then
        log_pass "codex telemetry extraction matches expected"
    else
        log_fail "codex telemetry mismatch (agent=$actual_agent, session=$actual_session)"
        echo "  Actual: $actual"
    fi
}

test_extract_gemini_telemetry() {
    ((TESTS_RUN++)) || true
    log_test "extract_gemini_telemetry parses fixture correctly"
    
    local actual expected
    actual=$(extract_gemini_telemetry "$FIXTURES_DIR/gemini-output.json")
    expected=$(cat "$FIXTURES_DIR/expected-gemini-stats.json")
    
    # Check key fields
    local actual_agent actual_session actual_model
    actual_agent=$(printf '%s' "$actual" | jq -r '.agent')
    actual_session=$(printf '%s' "$actual" | jq -r '.session_id')
    actual_model=$(printf '%s' "$actual" | jq -r '.model')
    
    if [[ "$actual_agent" == "gemini" && "$actual_session" == "gemini-session-456" && "$actual_model" == "gemini-3.1-pro-preview" ]]; then
        log_pass "gemini telemetry extraction matches expected"
    else
        log_fail "gemini telemetry mismatch (agent=$actual_agent, session=$actual_session, model=$actual_model)"
        echo "  Actual: $actual"
    fi
}

# ============================================================================
# ATOMIC OPERATIONS TESTS
# ============================================================================

test_atomic_write() {
    ((TESTS_RUN++)) || true
    log_test "atomic_write writes file atomically"
    
    setup_test_dir
    local test_file="$TEST_DIR/atomic-test.txt"
    local content="Hello, atomic world!"
    
    atomic_write "$test_file" "$content"
    
    if [[ -f "$test_file" ]]; then
        local actual
        actual=$(cat "$test_file")
        if [[ "$actual" == "$content" ]]; then
            # Check no temp file left behind
            if ! ls "$TEST_DIR"/atomic-test.txt.tmp.* 2>/dev/null | grep -q .; then
                log_pass "atomic write succeeded, no temp files left"
            else
                log_fail "temp files left behind"
            fi
        else
            log_fail "content mismatch: got '$actual', expected '$content'"
        fi
    else
        log_fail "file not created at $test_file"
    fi
}

test_atomic_json_update() {
    ((TESTS_RUN++)) || true
    log_test "atomic_json_update merges JSON with flock"
    
    setup_test_dir
    local test_file="$TEST_DIR/atomic-json.json"
    
    # Initial write
    atomic_write "$test_file" '{"count": 1, "items": ["a"]}'
    
    # Update with merge
    atomic_json_update "$test_file" '.count = .count + 1 | .items += ["b"]'
    
    if [[ -f "$test_file" ]]; then
        local count items
        count=$(jq -r '.count' "$test_file")
        items=$(jq -r '.items | length' "$test_file")
        
        if [[ "$count" == "2" && "$items" == "2" ]]; then
            # Check no lock file left behind
            if [[ ! -f "$test_file.lock" ]]; then
                log_pass "atomic JSON update succeeded"
            else
                log_fail "lock file left behind"
            fi
        else
            log_fail "JSON update incorrect: count=$count, items=$items"
        fi
    else
        log_fail "file not created at $test_file"
    fi
}

# ============================================================================
# VERSION DETECTION TESTS
# ============================================================================

test_get_plugin_version() {
    ((TESTS_RUN++)) || true
    log_test "get_plugin_version extracts version from plugin.json"
    
    setup_test_dir
    local plugin_dir="$TEST_DIR/.claude-plugin"
    mkdir -p "$plugin_dir"
    
    # Create mock plugin.json
    cat > "$plugin_dir/plugin.json" <<'EOF'
{
  "name": "test-plugin",
  "version": "1.2.3",
  "description": "Test plugin"
}
EOF
    
    # Set PLUGIN_ROOT so get_plugin_version finds it
    local old_plugin_root="${PLUGIN_ROOT:-}"
    export PLUGIN_ROOT="$TEST_DIR"
    
    local version
    version=$(get_plugin_version)
    
    # Restore
    if [[ -n "$old_plugin_root" ]]; then
        export PLUGIN_ROOT="$old_plugin_root"
    else
        unset PLUGIN_ROOT
    fi
    
    if [[ "$version" == "1.2.3" ]]; then
        log_pass "plugin version extracted correctly"
    else
        log_fail "expected version '1.2.3', got '$version'"
    fi
}

# ============================================================================
# ITERATION DIRECTORY TESTS
# ============================================================================

test_init_iteration_dir() {
    ((TESTS_RUN++)) || true
    log_test "init_iteration_dir creates directory structure"
    
    setup_test_dir
    local review_dir="$TEST_DIR/review"
    
    local iter_dir
    iter_dir=$(init_iteration_dir "$review_dir" 0)
    
    local all_exist=true
    for agent in claude codex gemini; do
        if [[ ! -d "$iter_dir/agents/$agent" ]]; then
            all_exist=false
            break
        fi
    done
    
    if [[ "$all_exist" == "true" && -d "$iter_dir" ]]; then
        log_pass "iteration directory structure created"
    else
        log_fail "missing expected directories in $iter_dir"
    fi
}

test_write_agent_telemetry() {
    ((TESTS_RUN++)) || true
    log_test "write_agent_telemetry writes files to correct locations"
    
    setup_test_dir
    local review_dir="$TEST_DIR/review"
    local iter_dir
    iter_dir=$(init_iteration_dir "$review_dir" 0)
    
    local stats_json='{"agent":"claude","tokens":{"input":100}}'
    local raw_json='{"raw":"data"}'
    local draft_md="# Review Draft"
    
    write_agent_telemetry "$iter_dir" "claude" "$stats_json" "$raw_json" "$draft_md"
    
    local agent_dir="$iter_dir/agents/claude"
    local all_exist=true
    local errors=""
    
    if [[ ! -f "$agent_dir/stats.json" ]]; then
        all_exist=false
        errors+=" missing stats.json;"
    fi
    if [[ ! -f "$agent_dir/raw.json" ]]; then
        all_exist=false
        errors+=" missing raw.json;"
    fi
    if [[ ! -f "$agent_dir/draft.md" ]]; then
        all_exist=false
        errors+=" missing draft.md;"
    fi
    
    if [[ "$all_exist" == "true" ]]; then
        # Verify content
        local actual_stats
        actual_stats=$(cat "$agent_dir/stats.json")
        if [[ "$actual_stats" == "$stats_json" ]]; then
            log_pass "agent telemetry files written correctly"
        else
            log_fail "stats.json content mismatch"
        fi
    else
        log_fail "files not written:$errors"
    fi
}

# ============================================================================
# RUN TELEMETRY AGGREGATION TESTS
# ============================================================================

test_update_run_telemetry() {
    ((TESTS_RUN++)) || true
    log_test "update_run_telemetry aggregates across iterations"
    
    setup_test_dir
    local review_dir="$TEST_DIR/review"
    mkdir -p "$review_dir"
    
    # Set up mock plugin version
    local plugin_dir="$TEST_DIR/.claude-plugin"
    mkdir -p "$plugin_dir"
    echo '{"version": "1.0.0"}' > "$plugin_dir/plugin.json"
    local old_plugin_root="${PLUGIN_ROOT:-}"
    export PLUGIN_ROOT="$TEST_DIR"
    
    # Add first agent stats (ignore errors from atomic_json_update which may fail due to flock)
    local stats1='{"agent":"claude","tokens":{"input":100,"output":50,"cached":10},"duration_ms":1000,"cost_usd":0.01}'
    update_run_telemetry "$review_dir" "0" "claude" "$stats1" || true
    
    # Add second agent stats
    local stats2='{"agent":"codex","tokens":{"input":200,"output":100,"cached":0},"duration_ms":2000,"cost_usd":0}'
    update_run_telemetry "$review_dir" "0" "codex" "$stats2" || true
    
    # Add stats for iteration 1
    local stats3='{"agent":"claude","tokens":{"input":150,"output":75,"cached":20},"duration_ms":1500,"cost_usd":0.015}'
    update_run_telemetry "$review_dir" "1" "claude" "$stats3" || true
    
    # Restore
    if [[ -n "$old_plugin_root" ]]; then
        export PLUGIN_ROOT="$old_plugin_root"
    else
        unset PLUGIN_ROOT
    fi
    
    local telemetry_file="$review_dir/run-telemetry.json"
    
    if [[ -f "$telemetry_file" ]]; then
        local total_input total_iterations
        total_input=$(jq -r '.totals.tokens.input' "$telemetry_file")
        total_iterations=$(jq -r '.totals.iterations' "$telemetry_file")
        
        # Expected: 100 + 200 + 150 = 450
        if [[ "$total_input" == "450" && "$total_iterations" == "2" ]]; then
            log_pass "run telemetry aggregation correct"
        else
            log_fail "aggregation mismatch: total_input=$total_input (expected 450), iterations=$total_iterations (expected 2)"
        fi
    else
        log_fail "run-telemetry.json not created"
    fi
}

# ============================================================================
# ERROR HANDLING TESTS
# ============================================================================

test_extract_malformed_json() {
    ((TESTS_RUN++)) || true
    log_test "extract_claude_telemetry handles malformed JSON gracefully"
    
    setup_test_dir
    local bad_file="$TEST_DIR/malformed.json"
    echo "{ not valid json }" > "$bad_file"
    
    local result
    result=$(extract_claude_telemetry "$bad_file" 2>/dev/null) || true
    
    # Should return empty telemetry structure, not fail
    if [[ -n "$result" ]]; then
        local agent
        agent=$(printf '%s' "$result" | jq -r '.agent' 2>/dev/null) || agent=""
        if [[ "$agent" == "claude" ]]; then
            log_pass "malformed JSON returns empty telemetry structure"
        else
            log_fail "unexpected result for malformed JSON: $result"
        fi
    else
        log_pass "malformed JSON handled gracefully (empty result)"
    fi
}

test_extract_missing_fields() {
    ((TESTS_RUN++)) || true
    log_test "extract_claude_telemetry handles missing fields"
    
    setup_test_dir
    local partial_file="$TEST_DIR/partial.json"
    # Valid JSON but missing most expected fields
    echo '{"session_id": "test-123"}' > "$partial_file"
    
    local result
    result=$(extract_claude_telemetry "$partial_file" 2>/dev/null) || true
    
    if [[ -n "$result" ]]; then
        local agent tokens_input
        agent=$(printf '%s' "$result" | jq -r '.agent' 2>/dev/null) || agent=""
        tokens_input=$(printf '%s' "$result" | jq -r '.tokens.input // 0' 2>/dev/null) || tokens_input=""
        
        if [[ "$agent" == "claude" && "$tokens_input" == "0" ]]; then
            log_pass "missing fields default to zero/empty"
        else
            log_fail "unexpected handling of missing fields"
        fi
    else
        log_pass "missing fields handled gracefully (empty result)"
    fi
}

test_extract_claude_telemetry_model_string() {
    ((TESTS_RUN++)) || true
    log_test "extract_claude_telemetry handles string model field"

    setup_test_dir
    local model_file="$TEST_DIR/claude-model-string.json"
    cat > "$model_file" <<'EOF'
{
  "model": "claude-test-model",
  "session_id": "session-model-string",
  "tokens": {"input": 1, "output": 2, "cached": 0},
  "duration_ms": 3,
  "total_cost_usd": 0.001
}
EOF

    local result model input output
    result=$(extract_claude_telemetry "$model_file" 2>/dev/null) || true
    model=$(printf '%s' "$result" | jq -r '.model // empty' 2>/dev/null || echo "")
    input=$(printf '%s' "$result" | jq -r '.tokens.input // empty' 2>/dev/null || echo "")
    output=$(printf '%s' "$result" | jq -r '.tokens.output // empty' 2>/dev/null || echo "")

    if [[ "$model" == "claude-test-model" && "$input" == "1" && "$output" == "2" ]]; then
        log_pass "string model field parsed correctly"
    else
        log_fail "string model field parsing failed: $result"
    fi
}

test_safe_extract_telemetry() {
    ((TESTS_RUN++)) || true
    log_test "safe_extract_telemetry wrapper never throws"
    
    setup_test_dir
    local missing_file="$TEST_DIR/nonexistent.json"
    
    # Should not throw even for missing file
    local result
    result=$(safe_extract_telemetry "claude" "$missing_file")
    
    if [[ -n "$result" ]]; then
        local agent
        agent=$(printf '%s' "$result" | jq -r '.agent' 2>/dev/null) || agent=""
        if [[ "$agent" == "claude" ]]; then
            log_pass "safe_extract_telemetry returns empty structure for missing file"
        else
            log_fail "unexpected result from safe_extract_telemetry"
        fi
    else
        log_fail "safe_extract_telemetry returned empty (should return empty structure)"
    fi
    
    # Also test unknown agent
    result=$(safe_extract_telemetry "unknown-agent" "$missing_file")
    if [[ -n "$result" ]]; then
        local agent
        agent=$(printf '%s' "$result" | jq -r '.agent' 2>/dev/null) || agent=""
        if [[ "$agent" == "unknown-agent" ]]; then
            # pass silently
            :
        fi
    fi
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    echo "========================================"
    echo "Telemetry Library Unit Tests"
    echo "========================================"
    echo ""
    
    # Fixture parsing tests
    test_extract_claude_telemetry
    test_extract_codex_telemetry
    test_extract_gemini_telemetry
    
    # Atomic operations tests
    test_atomic_write
    test_atomic_json_update
    
    # Version detection tests
    test_get_plugin_version
    
    # Iteration directory tests
    test_init_iteration_dir
    test_write_agent_telemetry
    
    # Run telemetry aggregation tests
    test_update_run_telemetry
    
    # Error handling tests
    test_extract_malformed_json
    test_extract_missing_fields
    test_extract_claude_telemetry_model_string
    test_safe_extract_telemetry
    
    echo ""
    echo "========================================"
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "${RED}$TESTS_FAILED tests failed${NC}"
        exit 1
    else
        echo -e "${GREEN}All tests passed${NC}"
        exit 0
    fi
}

main "$@"
