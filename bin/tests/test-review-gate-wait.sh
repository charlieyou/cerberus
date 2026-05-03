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

SESSION_ID_STALE="test-wait-stale-failed-$$"
TRANSCRIPT_PATH_STALE="$HOME/.claude/projects/-tmp-wait-test/${SESSION_ID_STALE}.jsonl"
REVIEW_DIR_STALE="$HOME/.claude/projects/-tmp-wait-test/cerberus/${SESSION_ID_STALE}"
STATE_FILE_STALE="$REVIEW_DIR_STALE/gate-state.json"

mkdir -p "$REVIEW_DIR_STALE/reviews" "$(dirname "$TRANSCRIPT_PATH_STALE")"
touch "$TRANSCRIPT_PATH_STALE"

cat > "$STATE_FILE_STALE" <<'EOF'
{
  "status": "pending",
  "reviewers": {
    "claude": {}
  },
  "created_at": "2026-05-01T00:00:00Z",
  "iteration": 0
}
EOF

cat > "$REVIEW_DIR_STALE/reviews/claude.json" <<'EOF'
{
  "type": "result",
  "subtype": "success",
  "is_error": false,
  "result": "{\"verdict\":\"PASS\",\"summary\":\"valid response despite stale failed sentinel\",\"findings\":[]}"
}
EOF
touch "$REVIEW_DIR_STALE/reviews/claude.failed"

log_test "wait --json trusts valid reviewer JSON over stale .failed sentinel"

set +e
output=$("$REVIEW_GATE" wait --json --timeout 5 --poll-interval 1 --session-id "$SESSION_ID_STALE" --transcript-path "$TRANSCRIPT_PATH_STALE" 2>&1)
status=$?
set -e

if [[ "$status" -ne 0 ]]; then
    log_fail "expected exit code 0 for valid stale-failed reviewer output, got $status\n$output"
fi

consensus=$(printf '%s' "$output" | jq -r '.consensus_verdict // empty')
if [[ "$consensus" != "PASS" ]]; then
    log_fail "expected consensus PASS from valid stale-failed reviewer output, got ${consensus:-<empty>}\n$output"
fi

reviewer_verdict=$(printf '%s' "$output" | jq -r '.reviewers.claude.verdict // empty')
if [[ "$reviewer_verdict" != "PASS" ]]; then
    log_fail "expected claude reviewer verdict PASS, got ${reviewer_verdict:-<empty>}\n$output"
fi

parse_errors=$(printf '%s' "$output" | jq -r '.parse_errors | length')
if [[ "$parse_errors" != "0" ]]; then
    log_fail "expected no parse errors for valid stale-failed reviewer output, got $parse_errors\n$output"
fi

log_pass "wait ignores stale .failed when reviewer JSON is valid"

SESSION_ID_NO_SENTINEL="test-wait-missing-sentinel-$$"
TRANSCRIPT_PATH_NO_SENTINEL="$HOME/.claude/projects/-tmp-wait-test/${SESSION_ID_NO_SENTINEL}.jsonl"
REVIEW_DIR_NO_SENTINEL="$HOME/.claude/projects/-tmp-wait-test/cerberus/${SESSION_ID_NO_SENTINEL}"
STATE_FILE_NO_SENTINEL="$REVIEW_DIR_NO_SENTINEL/gate-state.json"

mkdir -p "$REVIEW_DIR_NO_SENTINEL/reviews" "$(dirname "$TRANSCRIPT_PATH_NO_SENTINEL")"
touch "$TRANSCRIPT_PATH_NO_SENTINEL"

cat > "$STATE_FILE_NO_SENTINEL" <<'EOF'
{
  "status": "pending",
  "reviewers": {
    "claude": {}
  },
  "created_at": "2026-05-01T00:00:00Z",
  "iteration": 0
}
EOF

cat > "$REVIEW_DIR_NO_SENTINEL/reviews/claude.json" <<'EOF'
{
  "type": "result",
  "subtype": "success",
  "is_error": false,
  "result": "{\"verdict\":\"PASS\",\"summary\":\"valid response without sentinel\",\"findings\":[]}"
}
EOF
rm -f "$REVIEW_DIR_NO_SENTINEL/reviews/claude.done" "$REVIEW_DIR_NO_SENTINEL/reviews/claude.failed"

log_test "wait --json treats valid reviewer JSON without sentinels as complete"

set +e
output=$("$REVIEW_GATE" wait --json --timeout 5 --poll-interval 1 --session-id "$SESSION_ID_NO_SENTINEL" --transcript-path "$TRANSCRIPT_PATH_NO_SENTINEL" 2>&1)
status=$?
set -e

if [[ "$status" -ne 0 ]]; then
    log_fail "expected exit code 0 for valid reviewer output without sentinels, got $status\n$output"
fi

consensus=$(printf '%s' "$output" | jq -r '.consensus_verdict // empty')
if [[ "$consensus" != "PASS" ]]; then
    log_fail "expected consensus PASS from valid no-sentinel reviewer output, got ${consensus:-<empty>}\n$output"
fi

parse_errors=$(printf '%s' "$output" | jq -r '.parse_errors | length')
if [[ "$parse_errors" != "0" ]]; then
    log_fail "expected no parse errors for valid no-sentinel reviewer output, got $parse_errors\n$output"
fi

if [[ -e "$REVIEW_DIR_NO_SENTINEL/reviews/claude.done" || -e "$REVIEW_DIR_NO_SENTINEL/reviews/claude.failed" ]]; then
    log_fail "wait must not backfill sentinels for valid reviewer JSON without sentinels"
fi

log_pass "wait completes from valid reviewer JSON without mutating sentinels"

SESSION_ID_PARTIAL="test-wait-stale-failed-partial-$$"
TRANSCRIPT_PATH_PARTIAL="$HOME/.claude/projects/-tmp-wait-test/${SESSION_ID_PARTIAL}.jsonl"
REVIEW_DIR_PARTIAL="$HOME/.claude/projects/-tmp-wait-test/cerberus/${SESSION_ID_PARTIAL}"
STATE_FILE_PARTIAL="$REVIEW_DIR_PARTIAL/gate-state.json"

mkdir -p "$REVIEW_DIR_PARTIAL/reviews" "$(dirname "$TRANSCRIPT_PATH_PARTIAL")"
touch "$TRANSCRIPT_PATH_PARTIAL"

cat > "$STATE_FILE_PARTIAL" <<'EOF'
{
  "status": "pending",
  "reviewers": {
    "claude": {}
  },
  "created_at": "2026-05-01T00:00:00Z",
  "iteration": 0
}
EOF

cat > "$REVIEW_DIR_PARTIAL/reviews/claude.json" <<'EOF'
{"verdict":"PASS"}
EOF
touch "$REVIEW_DIR_PARTIAL/reviews/claude.failed"

log_test "wait --json keeps stale .failed when reviewer JSON is partial"

set +e
output=$("$REVIEW_GATE" wait --json --timeout 5 --poll-interval 1 --session-id "$SESSION_ID_PARTIAL" --transcript-path "$TRANSCRIPT_PATH_PARTIAL" 2>&1)
status=$?
set -e

if [[ "$status" -ne 2 ]]; then
    log_fail "expected exit code 2 for partial stale-failed reviewer output, got $status\n$output"
fi

consensus=$(printf '%s' "$output" | jq -r '.consensus_verdict // empty')
if [[ "$consensus" != "ERROR" ]]; then
    log_fail "expected consensus ERROR for partial stale-failed reviewer output, got ${consensus:-<empty>}\n$output"
fi

reviewer_verdict=$(printf '%s' "$output" | jq -r '.reviewers.claude.verdict // empty')
if [[ "$reviewer_verdict" != "ERROR" ]]; then
    log_fail "expected claude reviewer verdict ERROR for partial stale-failed output, got ${reviewer_verdict:-<empty>}\n$output"
fi

parse_error=$(printf '%s' "$output" | jq -r '.parse_errors[0].error // empty')
if [[ "$parse_error" != "reviewer_failed" ]]; then
    log_fail "expected reviewer_failed parse error for partial stale-failed output, got ${parse_error:-<empty>}\n$output"
fi

log_pass "wait preserves .failed when reviewer JSON is partial"
