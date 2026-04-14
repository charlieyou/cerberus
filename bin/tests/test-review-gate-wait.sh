#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_GATE="$SCRIPT_DIR/../review-gate"

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

TEST_DIR=$(mktemp -d)
export HOME="$TEST_DIR/home"
mkdir -p "$HOME"

SESSION_ID="test-wait-resolved-$$"
TRANSCRIPT_PATH="$HOME/.claude/projects/-tmp-wait-test/${SESSION_ID}.jsonl"
REVIEW_DIR="$HOME/.claude/projects/-tmp-wait-test/cerberus/${SESSION_ID}"
STATE_FILE="$REVIEW_DIR/gate-state.json"

mkdir -p "$REVIEW_DIR/reviews" "$(dirname "$TRANSCRIPT_PATH")"
touch "$TRANSCRIPT_PATH"

cat > "$STATE_FILE" <<'EOF'
{
  "status": "resolved",
  "decision": {
    "reason": "stale_timeout",
    "decided_at": "2026-04-13T20:40:58-04:00"
  },
  "reviewers": {
    "codex": {},
    "gemini": {},
    "claude": {}
  },
  "created_at": "2026-04-14T00:40:47Z",
  "iteration": 0
}
EOF

log_test "wait --json returns immediately for resolved gate state"

set +e
output=$("$REVIEW_GATE" wait --json --timeout 5 --poll-interval 1 --session-id "$SESSION_ID" --transcript-path "$TRANSCRIPT_PATH" 2>&1)
status=$?
set -e

if [[ "$status" -ne 2 ]]; then
    log_fail "expected exit code 2 for resolved gate without reviewer output, got $status\n$output"
fi

json_status=$(printf '%s' "$output" | jq -r '.status')
if [[ "$json_status" != "resolved" ]]; then
    log_fail "expected JSON status resolved, got ${json_status:-<empty>}\n$output"
fi

log_pass "wait exits immediately once gate is already resolved"
