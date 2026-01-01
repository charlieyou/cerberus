#!/usr/bin/env bash
# Test that --commit and range modes correctly track fix commits
#
# These tests verify that:
# 1. tip_sha is stored for --commit and range modes
# 2. On re-spawn, fixes are included via tip_sha..HEAD diff

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_GATE="$SCRIPT_DIR/../review-gate"

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

# Create a temporary git repo for testing
# Sets TEST_DIR variable and changes to that directory
setup_test_repo() {
    TEST_DIR=$(mktemp -d)
    TEST_DIRS+=("$TEST_DIR")
    cd "$TEST_DIR"
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

# Helper to get artifact path from spawn-code-review output
get_artifact_path() {
    echo "$1" | grep "Artifact written:" | sed 's/Artifact written: //'
}

# Helper to extract diff content from artifact
extract_diff_from_artifact() {
    local artifact_path="$1"
    sed -n '/^```diff$/,/^```$/p' "$artifact_path" | sed '1d;$d'
}

# Helper to extract metadata from artifact
extract_metadata() {
    local artifact_path="$1"
    local field="$2"
    grep "<!-- ${field}:" "$artifact_path" 2>/dev/null | sed "s/<!-- ${field}: \(.*\) -->/\1/" || true
}

# Test 1: --commit mode stores tip_sha
test_commit_mode_stores_tip_sha() {
    ((TESTS_RUN++)) || true || true
    log_test "--commit mode stores tip_sha in artifact"
    
    setup_test_repo
    
    # Create a commit to review
    echo "change1" > file.txt
    git add file.txt
    git commit -q -m "commit to review"
    local commit_sha
    commit_sha=$(git rev-parse HEAD)
    
    export CLAUDE_SESSION_ID="test-session-$$-1"
    export REVIEW_GATE_TRANSCRIPT_PATH="$TEST_DIR/transcript.jsonl"
    
    # Run spawn-code-review and capture artifact path from stderr
    local output
    output=$("$REVIEW_GATE" spawn-code-review --artifact-only --commit "$commit_sha" 2>&1)
    local artifact_path
    artifact_path=$(get_artifact_path "$output")
    
    if [[ -f "$artifact_path" ]]; then
        local tip_sha
        tip_sha=$(extract_metadata "$artifact_path" "tip-sha")
        if [[ -n "$tip_sha" ]]; then
            log_pass "tip_sha stored: $tip_sha"
        else
            log_fail "tip_sha not found in artifact"
        fi
    else
        log_fail "artifact not created at $artifact_path"
    fi
}

# Test 2: --commit mode includes fix commits on re-spawn
test_commit_mode_includes_fixes() {
    ((TESTS_RUN++)) || true
    log_test "--commit mode includes fix commits on re-spawn"
    
    setup_test_repo
    
    # Create a commit to review
    echo "change1" > file.txt
    git add file.txt
    git commit -q -m "commit to review"
    local original_sha
    original_sha=$(git rev-parse HEAD)
    
    export CLAUDE_SESSION_ID="test-session-$$-2"
    export REVIEW_GATE_TRANSCRIPT_PATH="$TEST_DIR/transcript.jsonl"
    
    # First spawn
    local output
    output=$("$REVIEW_GATE" spawn-code-review --artifact-only --commit "$original_sha" 2>&1)
    local artifact_path
    artifact_path=$(get_artifact_path "$output")
    
    # Simulate a fix commit
    echo "fix1" > file.txt
    git add file.txt
    git commit -q -m "fix commit"
    
    # Re-spawn
    output=$("$REVIEW_GATE" spawn-code-review --artifact-only --commit "$original_sha" 2>&1)
    artifact_path=$(get_artifact_path "$output")
    
    if [[ -f "$artifact_path" ]]; then
        local diff_content
        diff_content=$(extract_diff_from_artifact "$artifact_path")
        
        # The expected behavior: shows both original AND fix
        if echo "$diff_content" | grep -q "fix1"; then
            log_pass "fix commit included in diff"
        else
            log_fail "fix commit NOT included in diff (only original shown)"
        fi
    else
        log_fail "artifact not created at $artifact_path"
    fi
}

# Test 3: range mode stores resolved SHAs
test_range_mode_stores_resolved_shas() {
    ((TESTS_RUN++)) || true
    log_test "range mode stores resolved base_sha and tip_sha"
    
    setup_test_repo
    
    # Create commits for a range
    echo "change1" > file.txt
    git add file.txt
    git commit -q -m "first change"
    local first_sha
    first_sha=$(git rev-parse HEAD)
    
    echo "change2" > file.txt
    git add file.txt
    git commit -q -m "second change"
    local second_sha
    second_sha=$(git rev-parse HEAD)
    
    export CLAUDE_SESSION_ID="test-session-$$-3"
    export REVIEW_GATE_TRANSCRIPT_PATH="$TEST_DIR/transcript.jsonl"
    
    # Use symbolic range HEAD~1..HEAD
    local output
    output=$("$REVIEW_GATE" spawn-code-review --artifact-only HEAD~1..HEAD 2>&1)
    local artifact_path
    artifact_path=$(get_artifact_path "$output")
    
    if [[ -f "$artifact_path" ]]; then
        local base_sha tip_sha
        base_sha=$(extract_metadata "$artifact_path" "base-sha")
        tip_sha=$(extract_metadata "$artifact_path" "tip-sha")
        
        # Should be resolved to actual SHAs, not symbolic refs
        if [[ "$base_sha" == "$first_sha" ]] && [[ "$tip_sha" == "$second_sha" ]]; then
            log_pass "SHAs correctly resolved: base=$base_sha tip=$tip_sha"
        elif [[ -n "$base_sha" ]] && [[ -n "$tip_sha" ]]; then
            log_fail "SHAs stored but incorrect: expected base=$first_sha tip=$second_sha, got base=$base_sha tip=$tip_sha"
        else
            log_fail "tip_sha not stored (base_sha=${base_sha:-<empty>}, tip_sha=${tip_sha:-<empty>})"
        fi
    else
        log_fail "artifact not created at $artifact_path"
    fi
}

# Test 4: range mode includes fixes without shifting range
test_range_mode_includes_fixes_without_shift() {
    ((TESTS_RUN++)) || true
    log_test "range mode includes fixes without shifting original range"
    
    setup_test_repo
    
    # Create commits for a range  
    echo "original1" > file.txt
    git add file.txt
    git commit -q -m "original commit 1"
    
    echo "original2" > file.txt
    git add file.txt
    git commit -q -m "original commit 2"
    
    export CLAUDE_SESSION_ID="test-session-$$-4"
    export REVIEW_GATE_TRANSCRIPT_PATH="$TEST_DIR/transcript.jsonl"
    
    # First spawn with range
    local output
    output=$("$REVIEW_GATE" spawn-code-review --artifact-only HEAD~1..HEAD 2>&1)
    local artifact_path
    artifact_path=$(get_artifact_path "$output")
    
    # Make a fix commit (this would shift HEAD~1..HEAD in old implementation)
    echo "fix content" > file.txt
    git add file.txt
    git commit -q -m "fix commit"
    
    # Re-spawn - should use stored SHAs, not re-evaluate HEAD~1..HEAD
    output=$("$REVIEW_GATE" spawn-code-review --artifact-only HEAD~1..HEAD 2>&1)
    artifact_path=$(get_artifact_path "$output")
    
    if [[ -f "$artifact_path" ]]; then
        local diff_content
        diff_content=$(extract_diff_from_artifact "$artifact_path")
        
        # Should contain BOTH original changes AND fix
        local has_original=false
        local has_fix=false
        
        if echo "$diff_content" | grep -q "original"; then
            has_original=true
        fi
        if echo "$diff_content" | grep -q "fix content"; then
            has_fix=true
        fi
        
        if $has_original && $has_fix; then
            log_pass "both original and fix content present"
        elif $has_original && ! $has_fix; then
            log_fail "fix content missing (original range not expanded)"
        elif ! $has_original && $has_fix; then
            log_fail "original content missing (range shifted instead of expanded)"
        else
            log_fail "neither original nor fix content found"
        fi
    else
        log_fail "artifact not created at $artifact_path"
    fi
}

# Test 5: multiple fix iterations accumulate correctly
test_multiple_fix_iterations() {
    ((TESTS_RUN++)) || true
    log_test "multiple fix iterations accumulate correctly"
    
    setup_test_repo
    
    # Create original commit
    echo "original" > file.txt
    git add file.txt
    git commit -q -m "original commit"
    local original_sha
    original_sha=$(git rev-parse HEAD)
    
    export CLAUDE_SESSION_ID="test-session-$$-5"
    export REVIEW_GATE_TRANSCRIPT_PATH="$TEST_DIR/transcript.jsonl"
    
    # First spawn
    local output
    output=$("$REVIEW_GATE" spawn-code-review --artifact-only --commit "$original_sha" 2>&1)
    local artifact_path
    artifact_path=$(get_artifact_path "$output")
    
    # Fix iteration 1
    echo "fix1" > file.txt
    git add file.txt
    git commit -q -m "fix 1"
    output=$("$REVIEW_GATE" spawn-code-review --artifact-only --commit "$original_sha" 2>&1)
    artifact_path=$(get_artifact_path "$output")
    
    # Fix iteration 2
    echo "fix2" > file.txt
    git add file.txt
    git commit -q -m "fix 2"
    output=$("$REVIEW_GATE" spawn-code-review --artifact-only --commit "$original_sha" 2>&1)
    artifact_path=$(get_artifact_path "$output")
    
    if [[ -f "$artifact_path" ]]; then
        local diff_content
        diff_content=$(extract_diff_from_artifact "$artifact_path")
        
        # Should show fix2 (the latest state)
        if echo "$diff_content" | grep -q "fix2"; then
            log_pass "all fix iterations accumulated correctly"
        else
            log_fail "fix iterations not accumulated"
        fi
    else
        log_fail "artifact not created at $artifact_path"
    fi
}

# Test 6: --exclude filters uncommitted diffs
test_exclude_uncommitted_filters_diff() {
    ((TESTS_RUN++)) || true
    log_test "--exclude filters uncommitted diffs"

    setup_test_repo

    mkdir -p excluded
    echo "baseline include" > include.txt
    echo "baseline skip" > excluded/skip.txt
    git add include.txt excluded/skip.txt
    git commit -q -m "baseline include/exclude"

    echo "keep this" > include.txt
    echo "skip this" > excluded/skip.txt

    export CLAUDE_SESSION_ID="test-session-$$-6"
    export REVIEW_GATE_TRANSCRIPT_PATH="$TEST_DIR/transcript.jsonl"

    local output
    output=$("$REVIEW_GATE" spawn-code-review --artifact-only --exclude ":(exclude,glob)excluded/**" 2>&1)
    local artifact_path
    artifact_path=$(get_artifact_path "$output")

    if [[ -f "$artifact_path" ]]; then
        local diff_content
        diff_content=$(extract_diff_from_artifact "$artifact_path")

        if echo "$diff_content" | grep -q "include.txt" && ! echo "$diff_content" | grep -q "excluded/skip.txt"; then
            log_pass "excluded paths omitted from uncommitted diff"
        else
            log_fail "excluded paths still present in diff"
        fi
    else
        log_fail "artifact not created at $artifact_path"
    fi
}

# Test 7: --exclude filters commit and fix diffs
test_exclude_commit_and_fix() {
    ((TESTS_RUN++)) || true
    log_test "--exclude filters commit and fix diffs"

    setup_test_repo

    mkdir -p excluded
    echo "include v1" > include.txt
    echo "skip v1" > excluded/skip.txt
    git add include.txt excluded/skip.txt
    git commit -q -m "commit to review"
    local commit_sha
    commit_sha=$(git rev-parse HEAD)

    export CLAUDE_SESSION_ID="test-session-$$-7"
    export REVIEW_GATE_TRANSCRIPT_PATH="$TEST_DIR/transcript.jsonl"

    local output
    output=$("$REVIEW_GATE" spawn-code-review --artifact-only --commit "$commit_sha" --exclude ":!excluded/**" 2>&1)
    local artifact_path
    artifact_path=$(get_artifact_path "$output")

    local commit_ok=false
    if [[ -f "$artifact_path" ]]; then
        local diff_content
        diff_content=$(extract_diff_from_artifact "$artifact_path")

        if ! echo "$diff_content" | grep -q "excluded/skip.txt"; then
            commit_ok=true
        fi
    fi

    # Fix commit touching excluded path only; should remain excluded on re-spawn
    echo "skip v2" > excluded/skip.txt
    git add excluded/skip.txt
    git commit -q -m "fix commit excluded only"

    output=$("$REVIEW_GATE" spawn-code-review --artifact-only --commit "$commit_sha" --exclude ":!excluded/**" 2>&1)
    artifact_path=$(get_artifact_path "$output")

    local fix_ok=false
    if [[ -f "$artifact_path" ]]; then
        local diff_content
        diff_content=$(extract_diff_from_artifact "$artifact_path")

        if ! echo "$diff_content" | grep -q "skip v2"; then
            fix_ok=true
        fi
    fi

    if $commit_ok && $fix_ok; then
        log_pass "excluded paths omitted from commit and fix diffs"
    else
        if ! $commit_ok; then
            log_fail "excluded paths present in commit diff"
        fi
        if ! $fix_ok; then
            log_fail "excluded paths present in fix diff"
        fi
    fi
}

# Run all tests
main() {
    echo "========================================"
    echo "Review Gate Fix Tracking Tests"
    echo "========================================"
    echo ""
    
    test_commit_mode_stores_tip_sha
    test_commit_mode_includes_fixes
    test_range_mode_stores_resolved_shas
    test_range_mode_includes_fixes_without_shift
    test_multiple_fix_iterations
    test_exclude_uncommitted_filters_diff
    test_exclude_commit_and_fix
    
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
