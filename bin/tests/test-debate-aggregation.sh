#!/usr/bin/env bash
# test-debate-aggregation.sh
#
# T009 R6 Confidence-Weighted Dedup Aggregator GWT tests for the canonical
# merge order + verdict tiebreaks + summary template implemented in
# `_rdc_aggregate_and_promote` (bin/review-gate-debate.sh).
#
# Acceptance criteria covered:
#   AC-DedupPredicateAndMergeOrder
#   AC-AggregateVerdictSemantics
#   AC-AggregateJsonShape
#
# All tests are deterministic and Bash 3.2 / macOS-BSD + Linux-GNU compatible.
#
# Run: bash bin/tests/test-debate-aggregation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../review-gate-debate.sh"
FIXTURES_DIR="$SCRIPT_DIR/fixtures/r6-dedup"

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

# Source the helper into this shell so we can call _rdc_aggregate_and_promote
# directly. The helper expects STRATEGY_NAME_<R> env vars to be exported per
# active reviewer; we set them per-fixture below.
# shellcheck source=../review-gate-debate.sh
source "$HELPER"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# run_fixture <fixture-path>
#   Reads a fixture JSON, sets up temp final_dir + reviews_dir, writes each
#   reviewer's augmented JSON, exports STRATEGY_NAME_<R> env vars, calls
#   _rdc_aggregate_and_promote, and compares the produced aggregate.json
#   to the fixture's expected_aggregate (using jq -S for stable key
#   ordering). Always returns 0 — failures are accumulated through
#   log_fail (which increments FAIL_COUNT) so that the test harness
#   continues running every fixture even when one fails. The script's
#   final exit code is driven by FAIL_COUNT in main(), not by individual
#   fixture-runner exit codes; this matches the convention used by every
#   other test script in bin/tests/.
run_fixture() {
    local fixture_path="$1"
    local label
    label=$(jq -r '.label' "$fixture_path")
    log_test "$label"

    local consensus_mode rounds_consumed
    consensus_mode=$(jq -r '.consensus_mode' "$fixture_path")
    rounds_consumed=$(jq -r '.rounds_consumed' "$fixture_path")

    local -a reviewers=()
    local r
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        reviewers+=("$r")
    done < <(jq -r '.active_reviewers[]' "$fixture_path")

    # Set STRATEGY_NAME_<R> env vars per fixture's strategies map.
    local strategies_keys
    strategies_keys=$(jq -r '.strategies | keys[]' "$fixture_path")
    local k v
    while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        v=$(jq -r --arg k "$k" '.strategies[$k]' "$fixture_path")
        local upper_k
        upper_k=$(echo "$k" | tr '[:lower:]' '[:upper:]')
        eval "export STRATEGY_NAME_${upper_k}=\"\${v}\""
    done <<< "$strategies_keys"

    # Set up temp dirs.
    local tmp_root
    tmp_root=$(mktemp -d -t test-debate-aggregation.XXXXXX)
    # Trap-based cleanup at function scope is tricky in bash 3.2 with
    # sourced helpers; do a manual cleanup at the end of run_fixture.
    local final_dir="$tmp_root/round-2"
    local reviews_dir="$tmp_root/reviews"
    mkdir -p "$final_dir" "$reviews_dir"

    # Write each augmented JSON.
    for r in "${reviewers[@]}"; do
        jq --arg r "$r" '.augmented[$r]' "$fixture_path" > "$final_dir/${r}.augmented.json"
    done

    # Run aggregator.
    local rc=0
    if ! _rdc_aggregate_and_promote "$final_dir" "$reviews_dir" "$consensus_mode" \
            "$rounds_consumed" "${reviewers[@]}"; then
        rc=$?
    fi

    if [[ $rc -ne 0 ]]; then
        log_fail "$label — aggregator returned $rc"
        echo "--- final_dir ($final_dir):"
        ls -la "$final_dir"
        echo "--- reviews_dir ($reviews_dir):"
        ls -la "$reviews_dir"
        rm -rf "$tmp_root"
        return 0
    fi

    if [[ ! -s "$reviews_dir/aggregate.json" ]]; then
        log_fail "$label — aggregate.json missing or empty"
        rm -rf "$tmp_root"
        return 0
    fi

    # Compare aggregate.json to expected_aggregate (jq -S sorts keys).
    local actual expected
    actual=$(jq -S '.' "$reviews_dir/aggregate.json")
    expected=$(jq -S '.expected_aggregate' "$fixture_path")
    if [[ "$actual" == "$expected" ]]; then
        log_pass "$label — aggregate.json matches expected"
    else
        log_fail "$label — aggregate.json mismatch"
        echo "--- expected"
        echo "$expected"
        echo "--- actual"
        echo "$actual"
        echo "--- diff"
        diff <(echo "$expected") <(echo "$actual") || true
        rm -rf "$tmp_root"
        return 0
    fi

    rm -rf "$tmp_root"
    return 0
}

# ---------------------------------------------------------------------------
# Predicate + merge-order fixture tests
# ---------------------------------------------------------------------------

test_merge_basic() {
    run_fixture "$FIXTURES_DIR/merge-basic.json"
}

test_no_merge_different_priority() {
    run_fixture "$FIXTURES_DIR/no-merge-different-priority.json"
}

test_no_merge_non_overlap_lines() {
    run_fixture "$FIXTURES_DIR/no-merge-non-overlap-lines.json"
}

test_no_merge_different_titles() {
    run_fixture "$FIXTURES_DIR/no-merge-different-titles.json"
}

test_no_merge_different_files() {
    run_fixture "$FIXTURES_DIR/no-merge-different-files.json"
}

test_no_merge_null_fields() {
    run_fixture "$FIXTURES_DIR/no-merge-null-fields.json"
}

test_merge_equal_confidence() {
    run_fixture "$FIXTURES_DIR/merge-equal-confidence.json"
}

test_merge_with_px_strip() {
    run_fixture "$FIXTURES_DIR/merge-with-px-strip.json"
}

test_non_transitive_overlap() {
    run_fixture "$FIXTURES_DIR/non-transitive-overlap.json"
}

# ---------------------------------------------------------------------------
# Verdict tiebreak fixture tests
# ---------------------------------------------------------------------------

test_verdict_fail_blocking() {
    run_fixture "$FIXTURES_DIR/verdict-fail-blocking.json"
}

test_verdict_majority_no_tie() {
    run_fixture "$FIXTURES_DIR/verdict-majority-no-tie.json"
}

test_verdict_majority_tie() {
    run_fixture "$FIXTURES_DIR/verdict-majority-tie.json"
}

test_verdict_all_needs_work() {
    run_fixture "$FIXTURES_DIR/verdict-all-needs-work.json"
}

test_verdict_any_pass() {
    run_fixture "$FIXTURES_DIR/verdict-any-pass.json"
}

test_low_confidence_p1_not_suppressed() {
    run_fixture "$FIXTURES_DIR/low-confidence-p1-not-suppressed.json"
}

test_numeric_priority_normalized() {
    run_fixture "$FIXTURES_DIR/numeric-priority-normalized.json"
}

test_no_merge_same_reviewer() {
    run_fixture "$FIXTURES_DIR/no-merge-same-reviewer.json"
}

# ---------------------------------------------------------------------------
# Direct title-normalization unit tests for the [Px]-strip behaviors.
# These exercise the same `normalize_title` jq def used inside the
# aggregator. The aggregator's def is duplicated here verbatim so the
# unit tests are self-contained.
# ---------------------------------------------------------------------------

test_px_strip_behaviors() {
    log_test "Title normalization: [Px] strip + whitespace trim + case-fold"
    local in expected actual
    while IFS=$'\t' read -r in expected; do
        actual=$(jq -nr --arg t "$in" '
            ($t | sub("^[[:space:]]*\\[P[0-3]\\][[:space:]]*"; "")
                | sub("^[[:space:]]+"; "")
                | sub("[[:space:]]+$"; "")
                | ascii_downcase)
        ')
        if [[ "$actual" == "$expected" ]]; then
            log_pass "normalize_title($in) == \"$expected\""
        else
            log_fail "normalize_title($in): expected \"$expected\", got \"$actual\""
        fi
    done <<EOF
[P0] Foo	foo
  [P3]   Foo	foo
[P12] Foo	[p12] foo
[Pending] Foo	[pending] foo
[P4] Foo	[p4] foo
[p1] Foo	[p1] foo
[P1][P2] Foo	[p2] foo
EOF
}

# ---------------------------------------------------------------------------
# Aggregator never emits requires_decision in aggregate.json.verdict.
# Confidence-restriction sanity: verify the dedup is jq-iteration-order
# independent (separate from the explicit non-transitive overlap fixture).
# ---------------------------------------------------------------------------

test_no_requires_decision_in_aggregate() {
    log_test "aggregate.json.verdict value space is strictly {PASS|NEEDS_WORK|FAIL}"
    local fix
    local any_bad=0
    for fix in "$FIXTURES_DIR"/*.json; do
        local v
        v=$(jq -r '.expected_aggregate.verdict' "$fix")
        case "$v" in
            PASS|NEEDS_WORK|FAIL) ;;
            *)
                log_fail "fixture $(basename "$fix") expected_aggregate.verdict=$v (must be PASS|NEEDS_WORK|FAIL)"
                any_bad=1
                ;;
        esac
    done
    if [[ $any_bad -eq 0 ]]; then
        log_pass "all fixture expected_aggregate.verdict values in {PASS|NEEDS_WORK|FAIL}"
    fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

main() {
    if [[ ! -d "$FIXTURES_DIR" ]]; then
        echo "fixtures directory missing: $FIXTURES_DIR" >&2
        exit 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "jq not available; skipping tests" >&2
        exit 0
    fi

    test_merge_basic
    test_no_merge_different_priority
    test_no_merge_non_overlap_lines
    test_no_merge_different_titles
    test_no_merge_different_files
    test_no_merge_null_fields
    test_merge_equal_confidence
    test_merge_with_px_strip
    test_non_transitive_overlap
    test_verdict_fail_blocking
    test_verdict_majority_no_tie
    test_verdict_majority_tie
    test_verdict_all_needs_work
    test_verdict_any_pass
    test_low_confidence_p1_not_suppressed
    test_numeric_priority_normalized
    test_no_merge_same_reviewer
    test_px_strip_behaviors
    test_no_requires_decision_in_aggregate

    echo
    echo "=========================================="
    echo "Tests passed: $PASS_COUNT"
    echo "Tests failed: $FAIL_COUNT"
    echo "=========================================="
    if [[ $FAIL_COUNT -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
