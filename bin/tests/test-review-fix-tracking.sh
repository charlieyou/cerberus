#!/usr/bin/env bash
# Test that diffs are regenerated from current diff args
#
# These tests verify that:
# 1. base/tip metadata is not written into artifacts
# 2. Re-spawn does not append fix commits unless diff args include them
# 3. Symbolic ranges are re-evaluated on each spawn

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

# Test 1: --commit mode does NOT store base/tip metadata
test_commit_mode_no_tip_sha() {
    ((TESTS_RUN++)) || true || true
    log_test "--commit mode does NOT store base/tip metadata"
    
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
        local tip_sha base_sha
        tip_sha=$(extract_metadata "$artifact_path" "tip-sha")
        base_sha=$(extract_metadata "$artifact_path" "base-sha")
        if [[ -z "$tip_sha" && -z "$base_sha" ]]; then
            log_pass "no base/tip metadata stored"
        else
            log_fail "unexpected base/tip metadata (base=${base_sha:-<empty>} tip=${tip_sha:-<empty>})"
        fi
    else
        log_fail "artifact not created at $artifact_path"
    fi
}

# Test 2: --commit mode does NOT include fix commits on re-spawn
test_commit_mode_does_not_include_fixes() {
    ((TESTS_RUN++)) || true
    log_test "--commit mode does NOT include fix commits on re-spawn"
    
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
        
        # The expected behavior: only original commit diff (no fix)
        if echo "$diff_content" | grep -q "fix1"; then
            log_fail "fix commit unexpectedly included in diff"
        else
            log_pass "fix commit not included (diff regenerated from original args)"
        fi
    else
        log_fail "artifact not created at $artifact_path"
    fi
}

# Test 3: range mode does NOT store base/tip metadata
test_range_mode_no_resolved_shas() {
    ((TESTS_RUN++)) || true
    log_test "range mode does NOT store base/tip metadata"
    
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
        local base_sha tip_sha diff_content
        base_sha=$(extract_metadata "$artifact_path" "base-sha")
        tip_sha=$(extract_metadata "$artifact_path" "tip-sha")
        diff_content=$(extract_diff_from_artifact "$artifact_path")

        if [[ -n "$base_sha" || -n "$tip_sha" ]]; then
            log_fail "unexpected base/tip metadata (base=${base_sha:-<empty>} tip=${tip_sha:-<empty>})"
        elif echo "$diff_content" | grep -q "change2"; then
            log_pass "no base/tip metadata and range diff rendered"
        else
            log_fail "range diff missing expected content"
        fi
    else
        log_fail "artifact not created at $artifact_path"
    fi
}

# Test 4: range mode re-evaluates symbolic range on re-spawn
test_range_mode_re_evaluates_range() {
    ((TESTS_RUN++)) || true
    log_test "range mode re-evaluates symbolic range on re-spawn"
    
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
    
    # Re-spawn - should re-evaluate HEAD~1..HEAD and pick up the new commit
    output=$("$REVIEW_GATE" spawn-code-review --artifact-only HEAD~1..HEAD 2>&1)
    artifact_path=$(get_artifact_path "$output")
    
    if [[ -f "$artifact_path" ]]; then
        local diff_content
        diff_content=$(extract_diff_from_artifact "$artifact_path")
        
        # Expect latest diff to reflect new HEAD (fix content present)
        if echo "$diff_content" | grep -q "fix content"; then
            log_pass "range re-evaluated and includes fix content"
        else
            log_fail "range did not re-evaluate to include fix content"
        fi
    else
        log_fail "artifact not created at $artifact_path"
    fi
}

# Test 5: multiple fix iterations do NOT accumulate without updated diff args
test_multiple_fix_iterations_do_not_accumulate() {
    ((TESTS_RUN++)) || true
    log_test "multiple fix iterations do NOT accumulate without updated diff args"
    
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
        
        # Should NOT show fix2 when reusing the original commit diff args
        if echo "$diff_content" | grep -q "fix2"; then
            log_fail "fix iterations unexpectedly accumulated"
        else
            log_pass "fix iterations not accumulated without updated diff args"
        fi
    else
        log_fail "artifact not created at $artifact_path"
    fi
}

# Test 6: uncommitted diff works without excluded pathspecs
test_uncommitted_without_exclude_creates_artifact() {
    ((TESTS_RUN++)) || true
    log_test "uncommitted diff works without excluded pathspecs"

    setup_test_repo

    echo "uncommitted change" > file.txt

    export CLAUDE_SESSION_ID="test-session-$$-6"
    export REVIEW_GATE_TRANSCRIPT_PATH="$TEST_DIR/transcript.jsonl"

    local output
    output=$("$REVIEW_GATE" spawn-code-review --artifact-only --uncommitted 2>&1)
    local artifact_path
    artifact_path=$(get_artifact_path "$output")

    if [[ -f "$artifact_path" ]]; then
        local diff_content
        diff_content=$(extract_diff_from_artifact "$artifact_path")

        if echo "$diff_content" | grep -q "uncommitted change"; then
            log_pass "uncommitted diff artifact created"
        else
            log_fail "uncommitted diff missing expected content"
        fi
    else
        log_fail "artifact not created at $artifact_path"
    fi
}

# Test 7: --exclude filters uncommitted diffs
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

    export CLAUDE_SESSION_ID="test-session-$$-7"
    export REVIEW_GATE_TRANSCRIPT_PATH="$TEST_DIR/transcript.jsonl"

    local output
    output=$("$REVIEW_GATE" spawn-code-review --artifact-only --exclude "excluded/**" 2>&1)
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

# Test 8: --exclude filters commit diffs across re-spawn
test_exclude_commit_and_fix() {
    ((TESTS_RUN++)) || true
    log_test "--exclude filters commit diffs across re-spawn"

    setup_test_repo

    mkdir -p excluded
    echo "include v1" > include.txt
    echo "skip v1" > excluded/skip.txt
    git add include.txt excluded/skip.txt
    git commit -q -m "commit to review"
    local commit_sha
    commit_sha=$(git rev-parse HEAD)

    export CLAUDE_SESSION_ID="test-session-$$-8"
    export REVIEW_GATE_TRANSCRIPT_PATH="$TEST_DIR/transcript.jsonl"

    local output
    output=$("$REVIEW_GATE" spawn-code-review --artifact-only --commit "$commit_sha" --exclude "excluded/**" 2>&1)
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

    output=$("$REVIEW_GATE" spawn-code-review --artifact-only --commit "$commit_sha" --exclude "excluded/**" 2>&1)
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
        log_pass "excluded paths omitted from commit diffs on re-spawn"
    else
        if ! $commit_ok; then
            log_fail "excluded paths present in commit diff"
        fi
        if ! $fix_ok; then
            log_fail "excluded paths present in re-spawn diff"
        fi
    fi
}

# Test 9: --commit mode produces net diff across non-contiguous commits (including subdirectories)
test_commit_mode_net_diff_non_contig() {
    ((TESTS_RUN++)) || true
    log_test "--commit mode produces net diff across non-contiguous commits (including subdirs)"

    setup_test_repo

    # Create files in subdirectories to test recursion
    mkdir -p subdir/nested
    echo "alpha" > file.txt
    echo "sub_alpha" > subdir/sub.txt
    echo "nested_alpha" > subdir/nested/deep.txt
    git add file.txt subdir/sub.txt subdir/nested/deep.txt
    git commit -q -m "commit A"
    local sha_a
    sha_a=$(git rev-parse HEAD)

    # Commit B: unrelated changes (should not appear in net diff)
    echo "other" > other.txt
    echo "other_sub" > subdir/other.txt
    git add other.txt subdir/other.txt
    git commit -q -m "commit B"
    local sha_b
    sha_b=$(git rev-parse HEAD)

    # Commit C: changes to same files as A (tests net diff merging across subdirs)
    echo "charlie" > file.txt
    echo "sub_charlie" > subdir/sub.txt
    echo "nested_charlie" > subdir/nested/deep.txt
    git add file.txt subdir/sub.txt subdir/nested/deep.txt
    git commit -q -m "commit C"
    local sha_c
    sha_c=$(git rev-parse HEAD)

    export CLAUDE_SESSION_ID="test-session-$$-9"
    export REVIEW_GATE_TRANSCRIPT_PATH="$TEST_DIR/transcript.jsonl"

    local output
    output=$("$REVIEW_GATE" spawn-code-review --artifact-only --commit "$sha_a" "$sha_c" 2>&1)
    local artifact_path
    artifact_path=$(get_artifact_path "$output")

    if [[ -f "$artifact_path" ]]; then
        local diff_content
        diff_content=$(extract_diff_from_artifact "$artifact_path")

        local failed=false
        local fail_reasons=""

        # Verify skipped commit files are NOT included
        if echo "$diff_content" | grep -q "other.txt"; then
            failed=true
            fail_reasons+=" other.txt included from skipped commit;"
        fi
        if echo "$diff_content" | grep -q "subdir/other.txt"; then
            failed=true
            fail_reasons+=" subdir/other.txt included from skipped commit;"
        fi

        # Verify root file changes are in net diff
        if ! echo "$diff_content" | grep -q "charlie"; then
            failed=true
            fail_reasons+=" missing root file content 'charlie';"
        fi
        if echo "$diff_content" | grep -q "+alpha"; then
            failed=true
            fail_reasons+=" intermediate content 'alpha' present (should be net);"
        fi

        # Verify subdirectory file changes are in net diff (tests recursion)
        if ! echo "$diff_content" | grep -q "subdir/sub.txt"; then
            failed=true
            fail_reasons+=" missing subdir/sub.txt in diff;"
        fi
        if ! echo "$diff_content" | grep -q "sub_charlie"; then
            failed=true
            fail_reasons+=" missing subdir content 'sub_charlie';"
        fi

        # Verify nested subdirectory file changes are in net diff (tests deep recursion)
        if ! echo "$diff_content" | grep -q "subdir/nested/deep.txt"; then
            failed=true
            fail_reasons+=" missing subdir/nested/deep.txt in diff;"
        fi
        if ! echo "$diff_content" | grep -q "nested_charlie"; then
            failed=true
            fail_reasons+=" missing nested content 'nested_charlie';"
        fi

        if $failed; then
            log_fail "net diff issues:$fail_reasons"
        else
            log_pass "net diff reflects final content in root and subdirectories"
        fi
    else
        log_fail "artifact not created at $artifact_path"
    fi
}

# Test 10: --commit fallback to per-commit diffs when net diff fails
test_commit_mode_fallback_on_conflict() {
    ((TESTS_RUN++)) || true
    log_test "--commit falls back to per-commit diffs when net diff fails"

    setup_test_repo

    # Create a base state
    echo "base content" > file.txt
    git add file.txt
    git commit -q -m "base"
    local base_sha
    base_sha=$(git rev-parse HEAD)

    # Get current branch name for later checkout
    local main_branch
    main_branch=$(git branch --show-current)

    # Create commit A: changes file.txt
    echo "commit A content" > file.txt
    git add file.txt
    git commit -q -m "commit A: modify file"
    local sha_a
    sha_a=$(git rev-parse HEAD)

    # Create a divergent branch from base
    git checkout -q "$base_sha"
    git checkout -q -b divergent

    # Create commit B on divergent branch: different changes to same file
    # This creates a situation where commits A and B have conflicting changes
    # that cannot be cleanly merged via 3-way merge in net_diff_from_commits
    echo "commit B content (divergent)" > file.txt
    git add file.txt
    git commit -q -m "commit B: divergent modify"
    local sha_b
    sha_b=$(git rev-parse HEAD)

    # Go back to main
    git checkout -q "$main_branch"

    export CLAUDE_SESSION_ID="test-session-$$-10"
    export REVIEW_GATE_TRANSCRIPT_PATH="$TEST_DIR/transcript.jsonl"

    local output
    export REVIEW_GATE_COMMIT_NET_STRICT=0
    # Request both conflicting commits - this should trigger fallback
    output=$("$REVIEW_GATE" spawn-code-review --artifact-only --commit "$sha_a" "$sha_b" 2>&1)
    local artifact_path
    artifact_path=$(get_artifact_path "$output")

    if [[ -f "$artifact_path" ]]; then
        local diff_content
        diff_content=$(extract_diff_from_artifact "$artifact_path")

        local has_commit_a_content=false
        local has_commit_b_content=false
        local has_per_commit_headers=false
        local has_multiple_commits=false

        # Check for content from both commits (per-commit fallback includes both)
        if echo "$diff_content" | grep -q "commit A content"; then
            has_commit_a_content=true
        fi
        if echo "$diff_content" | grep -q "commit B content"; then
            has_commit_b_content=true
        fi

        # Per-commit diffs from git show include commit headers (Author:, Date:, etc.)
        # Net diffs from git diff-tree do NOT include these headers
        # This is the key indicator that fallback was used instead of net diff
        if echo "$diff_content" | grep -qE "^Author:"; then
            has_per_commit_headers=true
        fi

        # Fallback concatenates multiple git show outputs, each starting with "commit <sha>"
        # Count the number of commit headers - should be 2 for our two commits
        local commit_count
        commit_count=$(echo "$diff_content" | grep -cE "^commit [0-9a-f]{40}" || true)
        if [[ "$commit_count" -ge 2 ]]; then
            has_multiple_commits=true
        fi

        local failed=false
        local fail_reasons=""

        if ! $has_commit_a_content; then
            failed=true
            fail_reasons+=" missing commit A content;"
        fi
        if ! $has_commit_b_content; then
            failed=true
            fail_reasons+=" missing commit B content;"
        fi
        if ! $has_per_commit_headers; then
            failed=true
            fail_reasons+=" missing Author: header (suggests net diff was used, not per-commit fallback);"
        fi
        if ! $has_multiple_commits; then
            failed=true
            fail_reasons+=" expected 2 commit headers but found $commit_count (fallback should include both commits separately);"
        fi

        if $failed; then
            log_fail "fallback verification issues:$fail_reasons"
        else
            log_pass "fallback produced per-commit diffs with proper headers"
        fi
    else
        log_fail "artifact not created at $artifact_path"
    fi
}

# Test 11: max-rounds=0 auto-resolves without re-spawn
test_max_rounds_zero_auto_resolves() {
    ((TESTS_RUN++)) || true
    log_test "--max-rounds 0 auto-resolves without re-spawn"

    setup_test_repo

    export CLAUDE_SESSION_ID="test-session-$$-11"
    export REVIEW_GATE_TRANSCRIPT_PATH="$TEST_DIR/transcript.jsonl"

    local artifact_path
    artifact_path=$("$REVIEW_GATE" artifact-path)
    local review_dir
    review_dir=$(dirname "$artifact_path")
    mkdir -p "$review_dir/reviews"

    cat > "$artifact_path" <<'EOF'
<!-- review-type: code -->
<!-- diff-args: --commit deadbeef -->
<!-- max-rounds: 0 -->
EOF

    cat > "$review_dir/gate-state.json" <<EOF
{
  "status": "pending",
  "config": {"max_rounds": 0, "consensus_mode": "majority"},
  "reviewers": {"codex": {}},
  "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "iteration": 0,
  "mode": {"type": "code-diff", "diff_args": "--commit deadbeef"}
}
EOF

    cat > "$review_dir/reviews/codex.json" <<'EOF'
{"verdict":"FAIL","summary":"fail","findings":[{"title":"[P1] fail","body":"nope","priority":1,"file_path":null,"line_start":null,"line_end":null}]}
EOF
    touch "$review_dir/reviews/codex.done"

    local output
    output=$(echo "{\"session_id\":\"$CLAUDE_SESSION_ID\",\"transcript_path\":\"$REVIEW_GATE_TRANSCRIPT_PATH\"}" | "$REVIEW_GATE" check 2>/dev/null || true)

    # max-rounds=0 should NOT include "Max iterations" messaging
    if echo "$output" | grep -q "Max iterations"; then
        log_fail "max-rounds=0 should not include max-iterations message"
        return
    fi
    # But should still contain review results
    if ! echo "$output" | grep -q "codex"; then
        log_fail "missing reviewer name in output"
        return
    fi

    local status
    status=$(jq -r '.status // empty' "$review_dir/gate-state.json" 2>/dev/null || echo "")
    if [[ "$status" != "resolved" ]]; then
        log_fail "expected resolved status, got '${status:-<empty>}'"
        return
    fi

    if [[ -d "$review_dir/reviews-iter-0" ]]; then
        log_fail "unexpected reviews archive created (respawn occurred)"
        return
    fi

    log_pass "auto-resolve triggered without respawn"
}

# Test 12: wait --finalize resolves the gate state
test_wait_finalize_resolves_gate() {
    ((TESTS_RUN++)) || true
    log_test "wait --finalize resolves gate state"

    setup_test_repo

    export CLAUDE_SESSION_ID="test-session-$$-12"
    export REVIEW_GATE_TRANSCRIPT_PATH="$TEST_DIR/transcript.jsonl"

    local artifact_path
    artifact_path=$("$REVIEW_GATE" artifact-path)
    local review_dir
    review_dir=$(dirname "$artifact_path")
    mkdir -p "$review_dir/reviews"

    cat > "$review_dir/gate-state.json" <<EOF
{
  "status": "pending",
  "config": {"max_rounds": 0, "consensus_mode": "majority"},
  "reviewers": {"codex": {}},
  "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "iteration": 0,
  "mode": {"type": "code-diff", "diff_args": "--commit deadbeef"}
}
EOF

    cat > "$review_dir/reviews/codex.json" <<'EOF'
{"verdict":"PASS","summary":"ok","findings":[]}
EOF
    touch "$review_dir/reviews/codex.done"

    "$REVIEW_GATE" wait --json --finalize --session-id "$CLAUDE_SESSION_ID" --transcript-path "$REVIEW_GATE_TRANSCRIPT_PATH" >/dev/null

    local status
    status=$(jq -r '.status // empty' "$review_dir/gate-state.json" 2>/dev/null || echo "")
    if [[ "$status" != "resolved" ]]; then
        log_fail "expected resolved status, got '${status:-<empty>}'"
        return
    fi

    local reason
    reason=$(jq -r '.decision.reason // empty' "$review_dir/gate-state.json" 2>/dev/null || echo "")
    if [[ "$reason" != wait_finalize_* ]]; then
        log_fail "expected decision.reason to start with wait_finalize_, got '${reason:-<empty>}'"
        return
    fi

    log_pass "wait finalized gate state"
}

# Run all tests
main() {
    echo "========================================"
    echo "Review Gate Fix Tracking Tests"
    echo "========================================"
    echo ""
    
    test_commit_mode_no_tip_sha
    test_commit_mode_does_not_include_fixes
    test_range_mode_no_resolved_shas
    test_range_mode_re_evaluates_range
    test_multiple_fix_iterations_do_not_accumulate
    test_uncommitted_without_exclude_creates_artifact
    test_exclude_uncommitted_filters_diff
    test_exclude_commit_and_fix
    test_wait_finalize_resolves_gate
    test_commit_mode_net_diff_non_contig
    test_commit_mode_fallback_on_conflict
    test_max_rounds_zero_auto_resolves
    
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
