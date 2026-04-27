#!/usr/bin/env bash
# test-debate-anonymization.sh
#
# T007 R1 Anonymization GWT tests for the deny-list scrub, peer-ID
# assignment, per-recipient peer ordering (seeded + production), and
# active/abstained peer skeleton rendering helpers in
# bin/review-gate-debate.sh.
#
# Acceptance criteria covered:
#   AC-DenyListScrubAndIteration
#   AC-PeerSkeletonRender
#   AC-SeededAndProductionShuffle
#
# Run: bash bin/tests/test-debate-anonymization.sh
#
# Cross-platform contract: the deny-list scrub uses POSIX ERE under
# `sed -E` and the seeded peer-ordering uses SHA-256; both are byte-stable
# across macOS BSD and Linux GNU implementations, so a single committed
# expected fixture covers both platforms (no per-platform capture needed).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../review-gate-debate.sh"
FIXTURES_DIR="$SCRIPT_DIR/fixtures/r1-anonymization"

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

# assert_cmp_files <label> <actual_path> <expected_path>
assert_cmp_files() {
    local label="$1" actual="$2" expected="$3"
    if cmp -s "$actual" "$expected"; then
        log_pass "$label"
    else
        log_fail "$label"
        echo "--- expected ($expected)"
        cat "$expected"
        echo "--- actual ($actual)"
        cat "$actual"
        echo "---"
    fi
}

# assert_str_eq <label> <actual> <expected>
assert_str_eq() {
    local label="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        log_pass "$label"
    else
        log_fail "$label"
        echo "--- expected"
        printf '%s' "$expected"
        echo
        echo "--- actual"
        printf '%s' "$actual"
        echo
        echo "---"
    fi
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# Test 1 — Each deny-list term scrubbed in isolation (case-insensitive).
test_per_term_isolation() {
    log_test "AC-DenyListScrubAndIteration: each deny-list term scrubbed in isolation"
    local term inputs
    # Pinned terms with surrounding sentence so the boundary captures fire.
    # Capitalization varies to exercise the `i` flag.
    local -a cases=(
        "Claude flagged X.|[REDACTED] flagged X."
        "claude flagged X.|[REDACTED] flagged X."
        "CODEX flagged X.|[REDACTED] flagged X."
        "Gemini flagged X.|[REDACTED] flagged X."
        "GPT flagged X.|[REDACTED] flagged X."
        "Anthropic flagged X.|[REDACTED] flagged X."
        "OpenAI flagged X.|[REDACTED] flagged X."
        "Google flagged X.|[REDACTED] flagged X."
        "Reviewer 1 flagged X.|[REDACTED] flagged X."
        "Reviewer 2 flagged X.|[REDACTED] flagged X."
        "Reviewer 3 flagged X.|[REDACTED] flagged X."
        "Agent 1 flagged X.|[REDACTED] flagged X."
        "Agent 2 flagged X.|[REDACTED] flagged X."
        "Agent 3 flagged X.|[REDACTED] flagged X."
    )
    local pair input expected actual
    for pair in "${cases[@]}"; do
        input="${pair%%|*}"
        expected="${pair#*|}"
        actual=$(printf '%s' "$input" | debate_deny_list_scrub)
        assert_str_eq "scrub: '$input'" "$actual" "$expected"
    done
}

# Test 2 — Pinned positive matches via fixture (GPT-4, gpt-4o, Claude-3.5,
# Anthropic/Claude, Gemini 1.5 Pro, OpenAI's response).
test_positive_matches_fixture() {
    log_test "AC-DenyListScrubAndIteration: pinned positive matches (fixture)"
    local out_tmp
    out_tmp=$(mktemp -t test-debate-anon-pos.XXXXXX)
    trap 'rm -f "$out_tmp"' RETURN
    debate_deny_list_scrub < "$FIXTURES_DIR/positive-matches.input.txt" > "$out_tmp"
    assert_cmp_files "positive matches fixture cmp-equal" \
        "$out_tmp" "$FIXTURES_DIR/positive-matches.expected.txt"
}

# Test 3 — Pinned negative non-matches via fixture (claudication, gptcache,
# geminids, agent13).
test_negative_non_matches_fixture() {
    log_test "AC-DenyListScrubAndIteration: pinned negative non-matches (fixture)"
    local out_tmp
    out_tmp=$(mktemp -t test-debate-anon-neg.XXXXXX)
    trap 'rm -f "$out_tmp"' RETURN
    debate_deny_list_scrub < "$FIXTURES_DIR/negative-non-matches.input.txt" > "$out_tmp"
    assert_cmp_files "negative non-matches fixture cmp-equal" \
        "$out_tmp" "$FIXTURES_DIR/negative-non-matches.expected.txt"
}

# Test 4 — Adjacent-term iteration (Claude Codex). Single-pass non-iterative
# implementations MUST fail this assertion.
test_adjacent_two_terms() {
    log_test "AC-DenyListScrubAndIteration: 'Claude Codex' iterates to '[REDACTED] [REDACTED]'"
    local out_tmp
    out_tmp=$(mktemp -t test-debate-anon-adj2.XXXXXX)
    trap 'rm -f "$out_tmp"' RETURN
    debate_deny_list_scrub < "$FIXTURES_DIR/adjacent-claude-codex.input.txt" > "$out_tmp"
    assert_cmp_files "adjacent two-term iteration cmp-equal" \
        "$out_tmp" "$FIXTURES_DIR/adjacent-claude-codex.expected.txt"
}

# Test 5 — Three adjacent terms (`Claude Codex Gemini`).
test_adjacent_three_terms() {
    log_test "AC-DenyListScrubAndIteration: 'Claude Codex Gemini' iterates to all-redacted"
    local out_tmp
    out_tmp=$(mktemp -t test-debate-anon-adj3.XXXXXX)
    trap 'rm -f "$out_tmp"' RETURN
    debate_deny_list_scrub < "$FIXTURES_DIR/adjacent-three.input.txt" > "$out_tmp"
    assert_cmp_files "adjacent three-term iteration cmp-equal" \
        "$out_tmp" "$FIXTURES_DIR/adjacent-three.expected.txt"
}

# Test 6 — Adjacent terms with hyphen boundary (`claude-codex` — hyphen IS a
# non-word character so both terms redact).
test_adjacent_hyphen_boundary() {
    log_test "AC-DenyListScrubAndIteration: 'claude-codex' iterates to '[REDACTED]-[REDACTED]'"
    local out_tmp
    out_tmp=$(mktemp -t test-debate-anon-hyphen.XXXXXX)
    trap 'rm -f "$out_tmp"' RETURN
    debate_deny_list_scrub < "$FIXTURES_DIR/adjacent-claude-codex-hyphen.input.txt" > "$out_tmp"
    assert_cmp_files "adjacent hyphen-boundary iteration cmp-equal" \
        "$out_tmp" "$FIXTURES_DIR/adjacent-claude-codex-hyphen.expected.txt"
}

# Test 7 — Cross-platform byte-equality of the canonical fixture (all
# deny-list terms in one input). The committed expected fixture was
# generated via debate_deny_list_scrub itself; running the helper on the
# same input on either macOS or Linux MUST produce a byte-identical output.
test_canonical_denylist_fixture() {
    log_test "AC-DenyListScrubAndIteration: canonical deny-list fixture cmp-equal (cross-platform proxy)"
    local out_tmp
    out_tmp=$(mktemp -t test-debate-anon-canon.XXXXXX)
    trap 'rm -f "$out_tmp"' RETURN
    debate_deny_list_scrub < "$FIXTURES_DIR/denylist-canonical.input.txt" > "$out_tmp"
    assert_cmp_files "canonical deny-list fixture cmp-equal" \
        "$out_tmp" "$FIXTURES_DIR/denylist-canonical.expected.txt"
}

# Test 8 — Non-iterative single-pass MUST fail the iteration assertion. This
# guards against regressing the iterative do-while loop into a single sed
# pass (which would leave `Codex` unredacted in `Claude Codex Gemini`).
test_non_iterative_rejected() {
    log_test "AC-DenyListScrubAndIteration: non-iterative single-pass leaves middle term unredacted (negative case)"
    local alt out
    alt=$(_debate_denylist_alternation)
    # Apply ONE pass only — deliberately broken non-iterative form.
    out=$(printf '%s' "Claude Codex Gemini" | sed -E "s/(^|[^A-Za-z0-9_])(${alt})(\$|[^A-Za-z0-9_])/\1[REDACTED]\3/gi")
    # The single pass leaves `Codex` unredacted (the first match consumed
    # the shared space as its trailing boundary, leaving the second term
    # with no preceding boundary in the same pass). Expected from a broken
    # implementation: '[REDACTED] Codex [REDACTED]'.
    if [[ "$out" == *"Codex"* ]]; then
        log_pass "non-iterative single-pass leaves 'Codex' literal (confirms iteration is required)"
    else
        log_fail "non-iterative single-pass DID redact 'Codex' — the test cannot distinguish iterative from non-iterative; fixture is invalid (got: '$out')"
    fi

    log_test "AC-DenyListScrubAndIteration: iterative implementation redacts all three"
    local iter_out
    iter_out=$(printf '%s' "Claude Codex Gemini" | debate_deny_list_scrub)
    if [[ "$iter_out" == "[REDACTED] [REDACTED] [REDACTED]" ]]; then
        log_pass "iterative implementation redacts 'Claude Codex Gemini' fully"
    else
        log_fail "iterative implementation expected '[REDACTED] [REDACTED] [REDACTED]', got: '$iter_out'"
    fi
}

# Test 9 — Active-peer skeleton rendering (with findings, multi-line body
# continuation, deny-list redactions on titles/bodies).
test_active_peer_with_findings() {
    log_test "AC-PeerSkeletonRender: active-peer skeleton with findings + multi-line body"
    local input_json out_tmp
    input_json=$(cat "$FIXTURES_DIR/active-peer-with-findings.input.json")
    out_tmp=$(mktemp -t test-debate-anon-active.XXXXXX)
    trap 'rm -f "$out_tmp"' RETURN
    debate_render_active_peer "Peer-A" "$input_json" > "$out_tmp"
    assert_cmp_files "active-peer-with-findings rendered cmp-equal" \
        "$out_tmp" "$FIXTURES_DIR/active-peer-with-findings.expected.txt"
}

# Test 10 — Empty findings → `Findings: (none)` collapse.
test_active_peer_empty_findings() {
    log_test "AC-PeerSkeletonRender: empty findings renders 'Findings: (none)'"
    local input_json out_tmp
    input_json=$(cat "$FIXTURES_DIR/active-peer-empty-findings.input.json")
    out_tmp=$(mktemp -t test-debate-anon-empty.XXXXXX)
    trap 'rm -f "$out_tmp"' RETURN
    debate_render_active_peer "Peer-B" "$input_json" > "$out_tmp"
    assert_cmp_files "active-peer-empty-findings rendered cmp-equal" \
        "$out_tmp" "$FIXTURES_DIR/active-peer-empty-findings.expected.txt"
}

# Test 11 — Abstained-peer skeleton renders exactly two lines.
test_abstained_peer() {
    log_test "AC-PeerSkeletonRender: abstained-peer skeleton renders exactly the pinned two-line block"
    local out_tmp
    out_tmp=$(mktemp -t test-debate-anon-abst.XXXXXX)
    trap 'rm -f "$out_tmp"' RETURN
    debate_render_abstained_peer "Peer-C" > "$out_tmp"
    assert_cmp_files "abstained-peer rendered cmp-equal" \
        "$out_tmp" "$FIXTURES_DIR/abstained-peer.expected.txt"
}

# Test 12 — Peer-ID assignment in canonical alphabetical order.
test_peer_id_assignment() {
    log_test "AC-PeerSkeletonRender: debate_assign_peer_ids alphabetizes and labels A/B/C"
    local actual expected
    actual=$(debate_assign_peer_ids gemini codex claude | tr '\n' ',')
    expected="claude Peer-A,codex Peer-B,gemini Peer-C,"
    assert_str_eq "peer ID assignment (3 reviewers)" "$actual" "$expected"

    log_test "AC-PeerSkeletonRender: peer ID assignment stable across reruns"
    local r1 r2
    r1=$(debate_assign_peer_ids claude codex gemini)
    r2=$(debate_assign_peer_ids gemini claude codex)
    assert_str_eq "peer ID assignment is order-independent on input" "$r1" "$r2"

    log_test "AC-PeerSkeletonRender: peer ID assignment with 2 reviewers labels A/B"
    actual=$(debate_assign_peer_ids gemini claude | tr '\n' ',')
    expected="claude Peer-A,gemini Peer-B,"
    assert_str_eq "peer ID assignment (2 reviewers, alphabetical)" "$actual" "$expected"

    log_test "AC-PeerSkeletonRender: empty reviewer list returns empty"
    if actual=$(debate_assign_peer_ids 2>&1); then
        if [[ -z "$actual" ]]; then
            log_pass "empty input → empty output, exit 0"
        else
            log_fail "empty input produced unexpected output: '$actual'"
        fi
    else
        log_fail "empty input failed (exit non-zero): '$actual'"
    fi
}

# Test 13 — Seeded peer ordering byte-stable per fixture (cross-platform
# proxy). The fixture pins (seed, recipient, peer-set) → expected order
# computed offline via the same algorithm; macOS and Linux MUST produce
# byte-identical orderings.
test_seeded_ordering_fixture() {
    log_test "AC-SeededAndProductionShuffle: seeded peer ordering matches pinned fixture"
    local fixture="$FIXTURES_DIR/seeded-ordering.json"
    local case_count i seed recipient
    case_count=$(jq '.cases | length' "$fixture")
    i=0
    while [[ $i -lt $case_count ]]; do
        local label expected actual
        label=$(jq -r --argjson i "$i" '.cases[$i].label' "$fixture")
        seed=$(jq -r --argjson i "$i" '.cases[$i].seed' "$fixture")
        recipient=$(jq -r --argjson i "$i" '.cases[$i].recipient' "$fixture")
        local -a peers=()
        local p
        while IFS= read -r p; do
            peers+=("$p")
        done < <(jq -r --argjson i "$i" '.cases[$i].peers[]' "$fixture")
        expected=$(jq -r --argjson i "$i" '.cases[$i].expected[]' "$fixture")
        actual=$(debate_peer_order_seeded "$seed" "$recipient" "${peers[@]}")
        assert_str_eq "seeded ordering: $label" "$actual" "$expected"
        i=$((i + 1))
    done
}

# Test 14 — Seeded ordering is byte-stable across reruns.
test_seeded_ordering_stability() {
    log_test "AC-SeededAndProductionShuffle: seeded ordering byte-stable across reruns"
    local r1 r2 r3
    r1=$(debate_peer_order_seeded 42 claude Peer-A Peer-B Peer-C)
    r2=$(debate_peer_order_seeded 42 claude Peer-A Peer-B Peer-C)
    r3=$(debate_peer_order_seeded 42 claude Peer-A Peer-B Peer-C)
    if [[ "$r1" == "$r2" && "$r2" == "$r3" ]]; then
        log_pass "seeded ordering stable across 3 reruns"
    else
        log_fail "seeded ordering unstable: '$r1' / '$r2' / '$r3'"
    fi
}

# Test 15 — Production shuffle: two runs over the same peer set produce
# different orderings (statistical assertion across N runs).
test_production_shuffle_varies() {
    log_test "AC-SeededAndProductionShuffle: production shuffle (no seed) varies across runs"
    local n=20 i distinct_set
    distinct_set=$(mktemp -t test-debate-prod-shuffle.XXXXXX)
    trap 'rm -f "$distinct_set"' RETURN
    i=0
    while [[ $i -lt $n ]]; do
        # Pass a fixed peer set; the function MUST NOT cross-derive from
        # the peer-ID values, so ordering varies by RNG only.
        debate_peer_order_random Peer-A Peer-B Peer-C | tr '\n' ',' >> "$distinct_set"
        printf '\n' >> "$distinct_set"
        i=$((i + 1))
    done
    local distinct_count
    distinct_count=$(LC_ALL=C sort -u "$distinct_set" | wc -l | tr -d ' ')
    # 3-element shuffle has 6 distinct permutations; with N=20 runs and
    # uniform shuffle, the probability of seeing only 1 permutation is
    # (1/6)^19 — vanishing. Assert >= 2 distinct permutations as the
    # statistical floor that catches "RNG is fixed / cross-derived".
    if [[ "$distinct_count" -ge 2 ]]; then
        log_pass "production shuffle produced $distinct_count distinct permutations across $n runs (>=2 required)"
    else
        log_fail "production shuffle produced only $distinct_count distinct permutation(s) across $n runs — RNG is degenerate or cross-derived"
    fi
}

# Test 16 — Production shuffle MUST NOT cross-derive from byte-parity
# inputs: setting `--debate-seed N` in one run produces a deterministic
# ordering O; production runs (no seed) MUST NOT all collide with O.
test_production_does_not_cross_derive() {
    log_test "AC-SeededAndProductionShuffle: production shuffle doesn't collide with seeded ordering"
    local seeded n=20 i prod
    seeded=$(debate_peer_order_seeded 42 claude Peer-A Peer-B Peer-C)
    local non_collision_count=0
    i=0
    while [[ $i -lt $n ]]; do
        prod=$(debate_peer_order_random Peer-A Peer-B Peer-C)
        if [[ "$prod" != "$seeded" ]]; then
            non_collision_count=$((non_collision_count + 1))
        fi
        i=$((i + 1))
    done
    # If production shuffle were accidentally seed-derived from the peer
    # IDs (or otherwise byte-stable for the same input), all N runs would
    # collide with `$seeded`. Statistically with uniform shuffle on 6
    # permutations, ~5/6 of runs differ from any fixed permutation.
    # Assert at least 5 of 20 differ as a permissive floor that still
    # catches "shuffle is constant / cross-derived".
    if [[ $non_collision_count -ge 5 ]]; then
        log_pass "production shuffle differs from seeded order in $non_collision_count/$n runs (>=5 required)"
    else
        log_fail "production shuffle collides with seeded order $((n - non_collision_count))/$n runs — RNG appears cross-derived"
    fi
}

# Test 17 — Empty peer-set defensive no-op for both ordering helpers.
test_empty_peer_set() {
    log_test "AC-SeededAndProductionShuffle: empty peer set — seeded helper returns empty"
    local out
    out=$(debate_peer_order_seeded 42 claude 2>&1)
    if [[ -z "$out" ]]; then
        log_pass "seeded ordering empty input → empty output"
    else
        log_fail "seeded ordering empty input produced: '$out'"
    fi

    log_test "AC-SeededAndProductionShuffle: empty peer set — production helper returns empty"
    out=$(debate_peer_order_random 2>&1)
    if [[ -z "$out" ]]; then
        log_pass "production ordering empty input → empty output"
    else
        log_fail "production ordering empty input produced: '$out'"
    fi
}

# Test 18 — Trailing newline preservation in scrub output (relevant for
# byte-stable cmp comparisons of multi-line peer bodies).
test_trailing_newline_preservation() {
    log_test "AC-DenyListScrubAndIteration: scrub preserves single trailing LF"
    local out
    out=$(printf 'Claude here.\n' | debate_deny_list_scrub | xxd | tail -1)
    if [[ "$out" == *"0a"* ]]; then
        log_pass "trailing LF preserved in scrub output"
    else
        log_fail "trailing LF NOT preserved (last hex line: '$out')"
    fi

    log_test "AC-DenyListScrubAndIteration: scrub does not introduce trailing LF when input has none"
    local out_bytes input_bytes
    input_bytes=$(printf 'Claude here.' | xxd | tail -1)
    out_bytes=$(printf 'Claude here.' | debate_deny_list_scrub | xxd | tail -1)
    # Input ends with `.` (0x2e); output should also end with `.` (no LF
    # introduced). Scrub-only changes are character-for-character.
    if [[ "$out_bytes" != *"0a"* ]]; then
        log_pass "no trailing LF when input has none"
    else
        log_fail "scrub introduced trailing LF when input had none (out: '$out_bytes')"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required to run this test (used to load fixture JSON and parse peer JSON)." >&2
    exit 1
fi

if ! command -v xxd >/dev/null 2>&1; then
    echo "xxd is required to run trailing-LF byte assertion." >&2
    exit 1
fi

test_per_term_isolation
test_positive_matches_fixture
test_negative_non_matches_fixture
test_adjacent_two_terms
test_adjacent_three_terms
test_adjacent_hyphen_boundary
test_canonical_denylist_fixture
test_non_iterative_rejected
test_active_peer_with_findings
test_active_peer_empty_findings
test_abstained_peer
test_peer_id_assignment
test_seeded_ordering_fixture
test_seeded_ordering_stability
test_production_shuffle_varies
test_production_does_not_cross_derive
test_empty_peer_set
test_trailing_newline_preservation

echo ""
echo "================================================================"
echo "Results: ${GREEN}${PASS_COUNT} passed${NC}, ${RED}${FAIL_COUNT} failed${NC}"
echo "================================================================"

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
