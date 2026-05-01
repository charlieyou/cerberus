#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export PLUGIN_ROOT

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TEST_DIR=""

log_test() {
    echo -e "${YELLOW}TEST:${NC} $1"
}

log_pass() {
    echo -e "${GREEN}PASS:${NC} $1"
}

log_fail() {
    echo -e "${RED}FAIL:${NC} $1"
    exit 1
}

cleanup() {
    if [[ -n "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}

trap cleanup EXIT

if ! command -v jq >/dev/null 2>&1; then
    echo "jq not available; skipping debate classify stale-failed test" >&2
    exit 0
fi

source "$PLUGIN_ROOT/bin/review-gate-lib.sh"
source "$PLUGIN_ROOT/bin/review-gate-models.sh"
source "$PLUGIN_ROOT/bin/review-gate-debate.sh"

TEST_DIR=$(mktemp -d)
ROUND_DIR="$TEST_DIR/round-1"
mkdir -p "$ROUND_DIR"

cat > "$ROUND_DIR/claude.json" <<'EOF'
{
  "verdict": "PASS",
  "summary": "valid debate output despite stale failed sentinel",
  "overall_confidence": 0.8,
  "findings": []
}
EOF
touch "$ROUND_DIR/claude.failed"

log_test "debate classifier trusts valid reviewer JSON over stale .failed sentinel"

stderr_file="$TEST_DIR/classify.err"
if ! output=$(_rdc_classify_round_outputs "$ROUND_DIR" claude 2>"$stderr_file"); then
    log_fail "classifier returned non-zero\nstderr:\n$(cat "$stderr_file")"
fi

if [[ "$output" != "claude active" ]]; then
    log_fail "expected claude active, got '$output'\nstderr:\n$(cat "$stderr_file")"
fi

if [[ ! -s "$ROUND_DIR/claude.augmented.json" ]]; then
    log_fail "expected augmented JSON for stale-failed valid reviewer"
fi

verdict=$(jq -r '.verdict // empty' "$ROUND_DIR/claude.augmented.json")
if [[ "$verdict" != "PASS" ]]; then
    log_fail "expected augmented verdict PASS, got ${verdict:-<empty>}"
fi

if grep -q 'abstain' "$stderr_file"; then
    log_fail "did not expect stale-failed valid reviewer to log abstain\nstderr:\n$(cat "$stderr_file")"
fi

log_pass "debate classifier ignores stale .failed when reviewer JSON is valid"

ROUND_DIR_PARTIAL="$TEST_DIR/round-partial"
mkdir -p "$ROUND_DIR_PARTIAL"

cat > "$ROUND_DIR_PARTIAL/claude.json" <<'EOF'
{"verdict":"PASS"}
EOF
touch "$ROUND_DIR_PARTIAL/claude.failed"

log_test "debate classifier preserves stale .failed when reviewer JSON is partial"

stderr_file="$TEST_DIR/classify-partial.err"
if ! output=$(_rdc_classify_round_outputs "$ROUND_DIR_PARTIAL" claude 2>"$stderr_file"); then
    log_fail "classifier returned non-zero for partial stale-failed output\nstderr:\n$(cat "$stderr_file")"
fi

if [[ "$output" != "claude abstained" ]]; then
    log_fail "expected claude abstained for partial stale-failed output, got '$output'\nstderr:\n$(cat "$stderr_file")"
fi

if [[ -e "$ROUND_DIR_PARTIAL/claude.augmented.json" ]]; then
    log_fail "did not expect augmented JSON for partial stale-failed reviewer"
fi

log_pass "debate classifier keeps .failed when reviewer JSON is partial"
