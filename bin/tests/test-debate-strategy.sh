#!/usr/bin/env bash
# test-debate-strategy.sh
#
# T005 R3 Strategy-Diversity GWT tests for the SHA-256 per-(artifact_id,
# reviewer-canonical-name) strategy assignment + collision walk + per-type
# artifact_id helpers in bin/review-gate-debate.sh.
#
# These tests cover acceptance criteria:
#   AC-StrategyStableAndPermutation
#   AC-ArtifactIdPerType
#   AC-ShasumFallback
#
# All tests are deterministic and Bash 3.2 / macOS-BSD + Linux-GNU compatible:
# the fixture JSONs pin (artifact_id, reviewer-set) → expected strategy
# assignment, computed offline via the algorithm pinned in spec R3.
#
# Run: bash bin/tests/test-debate-strategy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../review-gate-debate.sh"
FIXTURES_DIR="$SCRIPT_DIR/fixtures/r3-strategy-assignment"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

log_test() { echo -e "${YELLOW}TEST:${NC} $1"; }
log_pass() { echo -e "${GREEN}PASS:${NC} $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
log_fail() {
    echo -e "${RED}FAIL:${NC} $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# Source the helper into this shell so we can call its functions directly.
# shellcheck source=../review-gate-debate.sh
source "$HELPER"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run assign_strategies and emit the result as a sorted-by-reviewer
# `<reviewer> <strategy>` listing. The function emits in canonical order
# already; we re-sort here to be explicit so the comparator does not depend
# on iteration order.
run_assignment() {
    local artifact_id="$1"; shift
    assign_strategies "$artifact_id" "$@" | LC_ALL=C sort
}

# Read a fixture JSON and emit the expected `<reviewer> <strategy>` listing
# sorted by reviewer.
fixture_expected() {
    local fixture_path="$1"
    jq -r '.expected[] | "\(.[0]) \(.[1])"' "$fixture_path" | LC_ALL=C sort
}

# Read a fixture JSON and emit the fixture's reviewer list as a series of
# arguments via stdout (one reviewer per line).
fixture_reviewers() {
    local fixture_path="$1"
    jq -r '.reviewers[]' "$fixture_path"
}

# Read fixture artifact_id.
fixture_artifact_id() {
    local fixture_path="$1"
    jq -r '.artifact_id' "$fixture_path"
}

# Compare expected vs. actual `<reviewer> <strategy>` listings; logs PASS / FAIL
# and prints a diff on FAIL.
assert_assignment_eq() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        log_pass "$label"
    else
        log_fail "$label"
        echo "--- expected"
        echo "$expected"
        echo "--- actual"
        echo "$actual"
        echo "---"
    fi
}

# Run a single fixture file end-to-end: load (artifact_id, reviewers, expected),
# call assign_strategies, compare to expected.
run_fixture() {
    local fixture_path="$1"
    local label
    label=$(jq -r '.label' "$fixture_path")
    log_test "$label"

    local artifact_id
    artifact_id=$(fixture_artifact_id "$fixture_path")

    local -a reviewers=()
    local r
    while IFS= read -r r; do
        reviewers+=("$r")
    done < <(fixture_reviewers "$fixture_path")

    local actual expected
    actual=$(run_assignment "$artifact_id" "${reviewers[@]}")
    expected=$(fixture_expected "$fixture_path")

    assert_assignment_eq "$label" "$expected" "$actual"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# Test 1 — N=3 full permutation: each of the 3 strategies appears exactly once.
test_n3_full_permutation() {
    local fixture="$FIXTURES_DIR/n3-full-permutation.json"
    run_fixture "$fixture"
    log_test "N=3 multiset equals {verification-first, falsification-first, decompose}"
    local artifact_id
    artifact_id=$(fixture_artifact_id "$fixture")
    local actual
    actual=$(run_assignment "$artifact_id" claude codex gemini | awk '{print $2}' | LC_ALL=C sort)
    local expected_multi
    expected_multi=$(printf 'decompose\nfalsification-first\nverification-first\n' | LC_ALL=C sort)
    assert_assignment_eq "N=3 full permutation multiset" "$expected_multi" "$actual"
}

# Test 2 — Per-(artifact, reviewer) stability: same input → same output across
# repeated invocations. Regression check on the determinism contract.
test_per_pair_stability() {
    log_test "per-(artifact, reviewer) stability — same artifact_id + same reviewer set yields same assignment across reruns"
    local artifact_id="artifact-1"
    local r1 r2 r3
    r1=$(run_assignment "$artifact_id" claude codex gemini)
    r2=$(run_assignment "$artifact_id" claude codex gemini)
    r3=$(run_assignment "$artifact_id" claude codex gemini)
    if [[ "$r1" == "$r2" && "$r2" == "$r3" ]]; then
        log_pass "stability across 3 reruns"
    else
        log_fail "stability across 3 reruns (mismatch)"
        echo "r1=$r1"
        echo "r2=$r2"
        echo "r3=$r3"
    fi
}

# Test 3 — Different artifact → at least one reviewer's strategy differs.
test_different_artifact_diff() {
    log_test "different artifact_id yields different assignment for at least one reviewer (artifact-1 vs. artifact-4 fixture pair)"
    local a1 a4
    a1=$(run_assignment "artifact-1" claude codex gemini)
    a4=$(run_assignment "artifact-4" claude codex gemini)
    if [[ "$a1" != "$a4" ]]; then
        log_pass "artifact-1 and artifact-4 produce distinct assignments"
    else
        log_fail "artifact-1 and artifact-4 should produce distinct assignments but were identical: $a1"
    fi
}

# Test 4 — N=2 distinct strategies (no collision walk needed).
test_n2_distinct() {
    run_fixture "$FIXTURES_DIR/n2-codex-gemini-baseline.json"

    log_test "N=2 reviewers always receive distinct strategies (never identical)"
    local artifact_id="artifact-1"
    local actual
    actual=$(run_assignment "$artifact_id" codex gemini | awk '{print $2}' | LC_ALL=C sort -u | wc -l | tr -d ' ')
    if [[ "$actual" == "2" ]]; then
        log_pass "N=2 distinct count"
    else
        log_fail "N=2 distinct count expected 2 distinct strategies, got $actual"
    fi
}

# Test 5 — N=4 collision wrap: each strategy appears at least once; one
# strategy duplicates.
test_n4_wrap() {
    local fixture="$FIXTURES_DIR/n4-collision-wrap.json"
    run_fixture "$fixture"

    log_test "N=4 each of the 3 strategies appears at least once"
    local artifact_id
    artifact_id=$(fixture_artifact_id "$fixture")
    local -a reviewers=()
    local r
    while IFS= read -r r; do reviewers+=("$r"); done < <(fixture_reviewers "$fixture")
    local distinct_count
    distinct_count=$(run_assignment "$artifact_id" "${reviewers[@]}" | awk '{print $2}' | LC_ALL=C sort -u | wc -l | tr -d ' ')
    if [[ "$distinct_count" == "3" ]]; then
        log_pass "N=4 each strategy present (3 distinct)"
    else
        log_fail "N=4 expected all 3 strategies to appear at least once; got $distinct_count distinct"
    fi

    log_test "N=4 exactly one strategy duplicates (4 assignments, 3 distinct strategies)"
    local total
    total=$(run_assignment "$artifact_id" "${reviewers[@]}" | wc -l | tr -d ' ')
    if [[ "$total" == "4" ]]; then
        log_pass "N=4 produced 4 assignments"
    else
        log_fail "N=4 expected 4 assignments, got $total"
    fi
}

# Test 6 — No-collision swap: swapping codex→claude on artifact-1 leaves
# gemini's strategy unchanged because claude_idx != gemini_idx.
test_no_collision_swap() {
    run_fixture "$FIXTURES_DIR/n2-codex-gemini-baseline.json"
    run_fixture "$FIXTURES_DIR/n2-claude-gemini-no-collision.json"

    log_test "no-collision swap (codex→claude on artifact-1) preserves gemini's strategy"
    local g_before g_after
    g_before=$(run_assignment "artifact-1" codex gemini | awk '$1=="gemini"{print $2}')
    g_after=$(run_assignment "artifact-1" claude gemini | awk '$1=="gemini"{print $2}')
    if [[ -n "$g_before" && "$g_before" == "$g_after" ]]; then
        log_pass "gemini kept '$g_before' across codex→claude swap"
    else
        log_fail "gemini changed strategy across no-collision swap: before=$g_before after=$g_after"
    fi
}

# Test 7 — Collision-driven shift: swapping codex→claude on artifact-9 forces
# gemini's slot to shift forward because claude_idx == gemini_idx.
test_collision_driven_shift() {
    run_fixture "$FIXTURES_DIR/n2-codex-gemini-shift-baseline.json"
    run_fixture "$FIXTURES_DIR/n2-claude-gemini-collision-shift.json"

    log_test "collision-driven shift (codex→claude on artifact-6) reassigns gemini deterministically"
    local g_before g_after
    g_before=$(run_assignment "artifact-6" codex gemini | awk '$1=="gemini"{print $2}')
    g_after=$(run_assignment "artifact-6" claude gemini | awk '$1=="gemini"{print $2}')
    if [[ -n "$g_before" && -n "$g_after" && "$g_before" != "$g_after" ]]; then
        log_pass "gemini shifted from '$g_before' to '$g_after' under forced collision"
    else
        log_fail "expected gemini to shift; before=$g_before after=$g_after"
    fi

    log_test "collision-driven shift is reproducible from (artifact_id, reviewer-set) alone"
    local g_after_2 g_after_3
    g_after_2=$(run_assignment "artifact-6" claude gemini | awk '$1=="gemini"{print $2}')
    g_after_3=$(run_assignment "artifact-6" claude gemini | awk '$1=="gemini"{print $2}')
    if [[ "$g_after" == "$g_after_2" && "$g_after_2" == "$g_after_3" ]]; then
        log_pass "shifted assignment reproducible across reruns"
    else
        log_fail "shifted assignment not reproducible: $g_after / $g_after_2 / $g_after_3"
    fi
}

# Test 8 — Per-type artifact_id (epic-verify): same epic file via two different
# working directories produces the same artifact_id (realpath); same command
# with raw criteria text uses the verbatim string.
test_artifact_id_per_type() {
    log_test "compute_artifact_id epic-verify: realpath stable across working directories"
    local tmp_root
    tmp_root=$(mktemp -d -t test-debate-strategy.XXXXXX)
    trap 'rm -rf "$tmp_root"' RETURN
    local epic_file="$tmp_root/epic.md"
    printf '# Epic\n' > "$epic_file"
    mkdir -p "$tmp_root/sub-a" "$tmp_root/sub-b"

    local id_from_a id_from_b
    id_from_a=$(cd "$tmp_root/sub-a" && compute_artifact_id epic-verify "../epic.md")
    id_from_b=$(cd "$tmp_root/sub-b" && compute_artifact_id epic-verify "../epic.md")
    if [[ "$id_from_a" == "$id_from_b" ]]; then
        log_pass "epic-verify file: same realpath ($id_from_a) from different cwds"
    else
        log_fail "epic-verify file: realpath differs across cwds: '$id_from_a' vs '$id_from_b'"
    fi

    log_test "compute_artifact_id epic-verify with raw criteria text: verbatim pass-through"
    local raw="ensure the artifact contains a falsifiable acceptance criterion"
    local id_raw
    id_raw=$(compute_artifact_id epic-verify "$raw")
    if [[ "$id_raw" == "$raw" ]]; then
        log_pass "epic-verify raw criteria: verbatim string preserved"
    else
        log_fail "epic-verify raw criteria mismatch: '$id_raw' vs '$raw'"
    fi

    log_test "compute_artifact_id epic-verify with raw criteria yields stable assignment across reruns"
    local first second
    first=$(run_assignment "$raw" claude codex gemini)
    second=$(run_assignment "$raw" claude codex gemini)
    if [[ "$first" == "$second" ]]; then
        log_pass "raw-criteria assignment stable across reruns"
    else
        log_fail "raw-criteria assignment unstable: $first vs $second"
    fi

    log_test "compute_artifact_id plan: realpath of file"
    local plan_file="$tmp_root/plan.md"
    printf '# Plan\n' > "$plan_file"
    local plan_id
    plan_id=$(cd "$tmp_root/sub-a" && compute_artifact_id plan "../plan.md")
    if [[ -f "$plan_id" && "$plan_id" == "$(cd "$tmp_root" && pwd -P)/plan.md" ]]; then
        log_pass "plan: realpath produced"
    else
        log_fail "plan: realpath unexpected: '$plan_id'"
    fi

    log_test "compute_artifact_id code: verbatim diff_args_str"
    local code_id
    code_id=$(compute_artifact_id code "--base main")
    if [[ "$code_id" == "--base main" ]]; then
        log_pass "code: verbatim diff_args_str preserved"
    else
        log_fail "code: verbatim diff_args_str mismatch: '$code_id'"
    fi

    log_test "compute_artifact_id ask: verbatim prompt content"
    local ask_raw=$'question: should we ship?\ncontext: includes --flags and markdown'
    local ask_id
    ask_id=$(compute_artifact_id ask "$ask_raw")
    if [[ "$ask_id" == "$ask_raw" ]]; then
        log_pass "ask: verbatim prompt content preserved"
    else
        log_fail "ask: prompt content mismatch: '$ask_id' vs '$ask_raw'"
    fi
}

# Test 9 — shasum / sha256sum / hard-error coverage.
test_shasum_selection() {
    log_test "AC-ShasumFallback: sha256sum fallback works when shasum is masked"
    local tmp_path
    tmp_path=$(mktemp -d -t test-debate-strategy-shfb.XXXXXX)
    trap 'rm -rf "$tmp_path"' RETURN

    # Build a sandbox PATH that contains sha256sum (real) but no shasum.
    # Find sha256sum if available; otherwise skip this branch (macOS without
    # GNU coreutils does not ship sha256sum — we still verify shasum-only
    # systems pass, just by virtue of the running test using shasum).
    local real_sha256sum=""
    real_sha256sum=$(command -v sha256sum 2>/dev/null || true)
    if [[ -n "$real_sha256sum" ]]; then
        local sandbox_only_sha256sum="$tmp_path/path-only-sha256sum"
        mkdir -p "$sandbox_only_sha256sum"
        ln -s "$real_sha256sum" "$sandbox_only_sha256sum/sha256sum"
        local out_only_sha256sum
        if out_only_sha256sum=$(PATH="$sandbox_only_sha256sum:/usr/bin:/bin" bash -c '
            source "$1"
            printf "%s" "test-input" | _sha256_hex
        ' _ "$HELPER" 2>&1); then
            # verify it's 64 hex chars
            if [[ "${#out_only_sha256sum}" == "64" && "$out_only_sha256sum" =~ ^[0-9a-f]{64}$ ]]; then
                log_pass "sha256sum-only PATH yields 64-hex digest"
            else
                log_fail "sha256sum-only PATH yielded unexpected output: '$out_only_sha256sum'"
            fi
        else
            log_fail "sha256sum-only PATH failed unexpectedly: $out_only_sha256sum"
        fi
    else
        log_pass "sha256sum not available on this system; sha256sum-only branch skipped (shasum branch is exercised by every other test)"
    fi

    log_test "AC-ShasumFallback: shasum-only PATH works when sha256sum is masked"
    local real_shasum=""
    real_shasum=$(command -v shasum 2>/dev/null || true)
    if [[ -n "$real_shasum" ]]; then
        local sandbox_only_shasum="$tmp_path/path-only-shasum"
        mkdir -p "$sandbox_only_shasum"
        cat > "$sandbox_only_shasum/shasum" <<SHASUM_WRAPPER
#!/usr/bin/env bash
exec "$real_shasum" "\$@"
SHASUM_WRAPPER
        chmod +x "$sandbox_only_shasum/shasum"
        local out_only_shasum
        if out_only_shasum=$(PATH="$sandbox_only_shasum:/usr/bin:/bin" bash -c '
            source "$1"
            printf "%s" "test-input" | _sha256_hex
        ' _ "$HELPER" 2>&1); then
            if [[ "${#out_only_shasum}" == "64" && "$out_only_shasum" =~ ^[0-9a-f]{64}$ ]]; then
                log_pass "shasum-only PATH yields 64-hex digest"
            else
                log_fail "shasum-only PATH yielded unexpected output: '$out_only_shasum'"
            fi
        else
            log_fail "shasum-only PATH failed unexpectedly: $out_only_shasum"
        fi
    else
        log_pass "shasum not available on this system; shasum-only branch skipped"
    fi

    log_test "AC-ShasumFallback: hard-error when neither shasum nor sha256sum is on PATH"
    # Build a sandbox PATH that has bash + perl + python3 (basic shell tools)
    # but no shasum and no sha256sum. We achieve this by symlinking just the
    # specific binaries we need into a fresh dir, then invoking bash with that
    # PATH. The current bash binary's absolute path is used directly to avoid
    # PATH lookup issues.
    local hardfail_dir="$tmp_path/no-hash-tools"
    mkdir -p "$hardfail_dir"
    # Don't symlink shasum or sha256sum into the sandbox; they MUST be missing.
    # Use the current bash via absolute path, so the sandbox PATH doesn't need
    # to expose bash.
    local err_out exit_code
    set +e
    err_out=$(PATH="$hardfail_dir" "$BASH" -c '
        source "$1"
        printf "%s" "test-input" | _sha256_hex
    ' _ "$HELPER" 2>&1)
    exit_code=$?
    set -e
    if [[ $exit_code -ne 0 ]] && \
       echo "$err_out" | grep -q "neither shasum nor sha256sum available" && \
       echo "$err_out" | grep -q "shasum" && \
       echo "$err_out" | grep -q "sha256sum"; then
        log_pass "hard-error names both tools and exits non-zero"
    else
        log_fail "hard-error did not match expected stderr / exit code (got code=$exit_code, output:\n$err_out\n)"
    fi

    log_test "AC-ShasumFallback: cross-platform byte-equality of digests (shasum vs sha256sum on same input)"
    if [[ -n "$real_shasum" && -n "$real_sha256sum" ]]; then
        local d_shasum d_sha256sum
        d_shasum=$(printf '%s' "compatibility-probe" | shasum -a 256 | cut -c1-64)
        d_sha256sum=$(printf '%s' "compatibility-probe" | sha256sum | cut -c1-64)
        if [[ "$d_shasum" == "$d_sha256sum" ]]; then
            log_pass "shasum and sha256sum digests are byte-identical"
        else
            log_fail "shasum and sha256sum produced different digests: $d_shasum vs $d_sha256sum"
        fi
    else
        log_pass "only one of shasum/sha256sum installed; cross-platform comparison skipped on this host"
    fi
}

# Test 10 — Empty reviewer list: defensive no-op.
test_empty_reviewer_list() {
    log_test "assign_strategies with empty reviewer list returns empty assignment without error"
    local out
    if out=$(assign_strategies "artifact-1" 2>&1); then
        if [[ -z "$out" ]]; then
            log_pass "empty reviewer list: empty output, exit 0"
        else
            log_fail "empty reviewer list produced unexpected output: '$out'"
        fi
    else
        log_fail "empty reviewer list failed (exit non-zero): '$out'"
    fi
}

# Test 11 — Cross-platform fixture-test replay: assignments are byte-identical
# across reruns (and, by virtue of fixture-pinning, across platforms running
# this test).
test_cross_platform_fixture_replay() {
    log_test "fixture replay: assignments byte-identical across reruns (cross-platform proxy)"
    local fixture
    local all_ok=1
    for fixture in "$FIXTURES_DIR"/*.json; do
        local artifact_id expected_a expected_b
        artifact_id=$(fixture_artifact_id "$fixture")
        local -a reviewers=()
        local r
        while IFS= read -r r; do reviewers+=("$r"); done < <(fixture_reviewers "$fixture")
        expected_a=$(run_assignment "$artifact_id" "${reviewers[@]}")
        expected_b=$(run_assignment "$artifact_id" "${reviewers[@]}")
        if [[ "$expected_a" != "$expected_b" ]]; then
            all_ok=0
            log_fail "fixture $(basename "$fixture") not byte-identical across reruns"
        fi
    done
    if [[ $all_ok -eq 1 ]]; then
        log_pass "all fixtures replay byte-identically"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required to run this test (used to load fixture JSON)." >&2
    exit 1
fi

test_n3_full_permutation
test_per_pair_stability
test_different_artifact_diff
test_n2_distinct
test_n4_wrap
test_no_collision_swap
test_collision_driven_shift
test_artifact_id_per_type
test_shasum_selection
test_empty_reviewer_list
test_cross_platform_fixture_replay

echo ""
echo "================================================================"
echo "Results: ${GREEN}${PASS_COUNT} passed${NC}, ${RED}${FAIL_COUNT} failed${NC}"
echo "================================================================"

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
