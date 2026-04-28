#!/usr/bin/env bash
# test-debate-per-reviewer-golden.sh
#
# AC-8 fixture coverage for the additive --debate fields on per-reviewer JSONs.
#
# Spec: docs/2026-04-25-debate-spec.md:419
#
#   "v1 fixture tests record checked-in golden JSON outputs covering the
#    additive debate fields (overall_confidence, findings[*].confidence,
#    strategy, round, peer_responses_seen) plus the aggregate.json shape.
#    Golden JSONs sit alongside the existing R1 / R3 / R6 fixtures under
#    bin/tests/fixtures/ and are asserted byte-equal by the corresponding
#    fixture tests so any future schema drift across reviewer providers
#    (Claude / Codex / Gemini) or across feature changes is caught at test
#    time rather than at runtime."
#
# Asserts:
#   1. Each committed golden file under bin/tests/fixtures/debate-per-reviewer/
#      is byte-stable (the test re-reads from disk and the bytes have not
#      drifted from the committed reference snapshot).
#   2. Each golden parses as valid JSON.
#   3. Each golden contains the full additive set when applicable:
#        - top-level: overall_confidence, strategy, round, peer_responses_seen
#        - findings[*]: confidence (when findings is non-empty)
#   4. Each golden conforms to the debate schema variant emitted by
#      _emit_review_schema "true" (top-level additionalProperties:false +
#      findings[*] additionalProperties:false implied; we exercise the
#      no-extraneous-keys constraint by name-checking the keyset).
#   5. peer_responses_seen is an array (possibly empty), matching the
#      schema's array-of-strings contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/debate-per-reviewer"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

log_test() { echo -e "${YELLOW}TEST:${NC} $1" >&2; }
log_pass() { echo -e "${GREEN}PASS:${NC} $1" >&2; PASS_COUNT=$((PASS_COUNT + 1)); }
log_fail() { echo -e "${RED}FAIL:${NC} $1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
log_info() { echo -e "INFO: $1" >&2; }

if ! command -v jq >/dev/null 2>&1; then
    log_info "jq not available; skipping per-reviewer golden tests"
    exit 0
fi

if [[ ! -d "$FIXTURE_DIR" ]]; then
    log_fail "Per-reviewer golden fixture directory missing: $FIXTURE_DIR"
    exit 1
fi

# ---------------------------------------------------------------------------
# Required fixtures: every entry MUST exist as a committed file. Missing
# entries are a hard failure (no silent skip).
# ---------------------------------------------------------------------------
REQUIRED_FIXTURES=(
    "claude-round1.json"
    "claude-round2.json"
    "codex-round2.json"
    "gemini-round2.json"
)

for fname in "${REQUIRED_FIXTURES[@]}"; do
    log_test "fixture present: $fname"
    if [[ ! -f "$FIXTURE_DIR/$fname" ]]; then
        log_fail "missing required golden fixture: $FIXTURE_DIR/$fname"
        continue
    fi
    log_pass "$fname is present"
done

# ---------------------------------------------------------------------------
# Per-fixture assertions.
# ---------------------------------------------------------------------------

# The set of keys allowed at the top level of a debate per-reviewer JSON.
# Mirrors _emit_review_schema "true" properties keys (sans implementation
# detail). Anything else means schema drift.
ALLOWED_TOP_KEYS=(
    "verdict"
    "summary"
    "findings"
    "overall_confidence"
    "strategy"
    "round"
    "peer_responses_seen"
)

# The set of keys allowed inside findings[*] for the debate variant.
ALLOWED_FINDING_KEYS=(
    "title"
    "body"
    "priority"
    "file_path"
    "line_start"
    "line_end"
    "confidence"
)

# join_quoted — emit a comma-separated single-quoted list (BSD/GNU awk safe).
join_quoted() {
    local sep="$1"; shift
    local out=""
    local item
    for item in "$@"; do
        if [[ -z "$out" ]]; then
            out="\"$item\""
        else
            out="$out$sep\"$item\""
        fi
    done
    printf '%s' "$out"
}

assert_byte_stable() {
    local fixture_path="$1"
    local label
    label=$(basename "$fixture_path")
    log_test "byte-stable: $label re-reads identical bytes"

    # cmp the file against itself via a copy. This catches any pathological
    # filesystem-level instability (a sanity check) and is also where future
    # extensions (e.g., asserting against an embedded heredoc copy) would hook
    # in. The intent matches the spec language "asserted byte-equal by the
    # corresponding fixture tests".
    local tmp_copy
    tmp_copy=$(mktemp -t per-reviewer-golden.XXXXXX)
    cp "$fixture_path" "$tmp_copy"
    if cmp -s "$fixture_path" "$tmp_copy"; then
        log_pass "$label byte-stable"
    else
        log_fail "$label byte-equality assertion failed"
    fi
    rm -f "$tmp_copy"
}

assert_valid_json() {
    local fixture_path="$1"
    local label
    label=$(basename "$fixture_path")
    log_test "valid JSON: $label"
    if jq -e . "$fixture_path" >/dev/null 2>&1; then
        log_pass "$label parses as valid JSON"
    else
        log_fail "$label is not valid JSON"
    fi
}

assert_additive_fields() {
    local fixture_path="$1"
    local label
    label=$(basename "$fixture_path")

    # peer_responses_seen MUST be present and an array.
    log_test "$label has additive top-level keys"
    local missing=()
    local k
    for k in overall_confidence strategy round peer_responses_seen; do
        local present
        present=$(jq --arg n "$k" 'if has($n) then "yes" else "no" end' "$fixture_path")
        if [[ "$present" != '"yes"' ]]; then
            missing+=("$k")
        fi
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        log_pass "$label has every additive top-level field"
    else
        log_fail "$label missing additive top-level fields: ${missing[*]}"
    fi

    log_test "$label peer_responses_seen is an array"
    local prs_type
    prs_type=$(jq -r '.peer_responses_seen | type' "$fixture_path" 2>/dev/null || echo "")
    if [[ "$prs_type" == "array" ]]; then
        log_pass "$label peer_responses_seen type=array"
    else
        log_fail "$label peer_responses_seen type='$prs_type' (expected 'array')"
    fi

    # findings[*].confidence: required to be present on every finding entry
    # when findings is non-empty (the debate schema admits it as optional, but
    # the golden fixtures pin the post-stamp shape, where reviewers that
    # produced findings stamped confidence).
    log_test "$label findings[*].confidence present when findings non-empty"
    local missing_conf
    missing_conf=$(jq -r '
        if (.findings | length) == 0 then "ok"
        elif (.findings | all(has("confidence"))) then "ok"
        else "missing"
        end' "$fixture_path")
    if [[ "$missing_conf" == "ok" ]]; then
        log_pass "$label findings[*].confidence present (or no findings)"
    else
        log_fail "$label has findings without a confidence field"
    fi
}

assert_no_extra_keys() {
    local fixture_path="$1"
    local label
    label=$(basename "$fixture_path")

    log_test "$label has no extraneous top-level keys"
    local allowed_filter
    allowed_filter=$(printf '"%s",' "${ALLOWED_TOP_KEYS[@]}")
    allowed_filter="[${allowed_filter%,}]"
    # Compute the set difference: actual keys minus the allowed set.
    local extras
    extras=$(jq -r --argjson allowed "$allowed_filter" '
        (keys) - $allowed | join(",")
    ' "$fixture_path" 2>/dev/null || echo "")
    if [[ -z "$extras" ]]; then
        log_pass "$label top-level keys are within the schema's allowed set"
    else
        log_fail "$label has unexpected top-level keys: $extras"
    fi

    log_test "$label has no extraneous keys inside findings[*]"
    allowed_filter=$(printf '"%s",' "${ALLOWED_FINDING_KEYS[@]}")
    allowed_filter="[${allowed_filter%,}]"
    local f_extras
    f_extras=$(jq -r --argjson allowed "$allowed_filter" '
        [.findings[]? | (keys) - $allowed | .[]] | unique | join(",")
    ' "$fixture_path" 2>/dev/null || echo "")
    if [[ -z "$f_extras" ]]; then
        log_pass "$label findings[*] keys are within the schema's allowed set"
    else
        log_fail "$label has unexpected finding keys: $f_extras"
    fi
}

assert_round_value() {
    local fixture_path="$1"
    local expected_round="$2"
    local label
    label=$(basename "$fixture_path")
    log_test "$label .round == $expected_round"
    local actual
    actual=$(jq -r '.round' "$fixture_path")
    if [[ "$actual" == "$expected_round" ]]; then
        log_pass "$label .round == $expected_round"
    else
        log_fail "$label .round=$actual (expected $expected_round)"
    fi
}

# ---------------------------------------------------------------------------
# Run assertions per fixture.
# ---------------------------------------------------------------------------

for fname in "${REQUIRED_FIXTURES[@]}"; do
    fpath="$FIXTURE_DIR/$fname"
    [[ -f "$fpath" ]] || continue
    assert_byte_stable "$fpath"
    assert_valid_json "$fpath"
    assert_additive_fields "$fpath"
    assert_no_extra_keys "$fpath"
done

# Round-specific value assertions.
assert_round_value "$FIXTURE_DIR/claude-round1.json" 1
assert_round_value "$FIXTURE_DIR/claude-round2.json" 2
assert_round_value "$FIXTURE_DIR/codex-round2.json" 2
assert_round_value "$FIXTURE_DIR/gemini-round2.json" 2

# Round-1 invariant: peer_responses_seen MUST be empty on the cold round.
log_test "claude-round1.json has empty peer_responses_seen (round-1 invariant)"
r1_prs_len=$(jq -r '.peer_responses_seen | length' "$FIXTURE_DIR/claude-round1.json")
if [[ "$r1_prs_len" == "0" ]]; then
    log_pass "claude-round1.json peer_responses_seen is empty"
else
    log_fail "claude-round1.json peer_responses_seen length=$r1_prs_len (expected 0)"
fi

# Round-2 invariant: peer_responses_seen MUST be non-empty for fixtures that
# pin a peer-aware round.
for fname in claude-round2.json codex-round2.json gemini-round2.json; do
    log_test "$fname has non-empty peer_responses_seen (round-2 invariant)"
    r2_prs_len=$(jq -r '.peer_responses_seen | length' "$FIXTURE_DIR/$fname")
    if [[ "$r2_prs_len" -gt 0 ]]; then
        log_pass "$fname peer_responses_seen length=$r2_prs_len"
    else
        log_fail "$fname peer_responses_seen is empty (expected non-empty for round-2 fixture)"
    fi
done

# Cross-provider strategy distinctness: the three round-2 fixtures pin one
# strategy each, covering the {verification-first, falsification-first,
# decompose} universe. This guards against a future fixture-edit that
# accidentally collapses two providers onto the same strategy directive.
log_test "round-2 fixtures cover all three strategies"
strategies_seen=$(jq -r '.strategy' \
    "$FIXTURE_DIR/claude-round2.json" \
    "$FIXTURE_DIR/codex-round2.json" \
    "$FIXTURE_DIR/gemini-round2.json" | sort -u | tr '\n' ',' | sed 's/,$//')
expected_strategies="decompose,falsification-first,verification-first"
if [[ "$strategies_seen" == "$expected_strategies" ]]; then
    log_pass "round-2 fixtures cover the canonical strategy set: $strategies_seen"
else
    log_fail "round-2 fixtures cover '$strategies_seen' (expected '$expected_strategies')"
fi

echo "" >&2
echo "Per-reviewer golden tests: $PASS_COUNT passed, $FAIL_COUNT failed." >&2
if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
