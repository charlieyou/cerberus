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

SESSION_ID="test-empty-running-list-$$"
TRANSCRIPT_PATH="$HOME/.claude/projects/-tmp-check-test/${SESSION_ID}.jsonl"
REVIEW_DIR="$HOME/.claude/projects/-tmp-check-test/cerberus/${SESSION_ID}"
STATE_FILE="$REVIEW_DIR/gate-state.json"
REVIEWS_DIR="$REVIEW_DIR/reviews"

mkdir -p "$REVIEWS_DIR" "$(dirname "$TRANSCRIPT_PATH")"
touch "$TRANSCRIPT_PATH"

cat > "$REVIEWS_DIR/codex.json" <<'EOF'
{"verdict":"PASS","summary":"ok","findings":[]}
EOF
touch "$REVIEWS_DIR/codex.done"

created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > "$STATE_FILE" <<EOF
{
  "version": 1,
  "status": "pending",
  "trigger_source": "plan",
  "artifact": {
    "path": "$REVIEW_DIR/latest.md",
    "sha256": "test"
  },
  "mode": {
    "type": "plan",
    "plan_path": "$REVIEW_DIR/latest.md"
  },
  "config": {
    "max_rounds": 3,
    "consensus_mode": "majority"
  },
  "reviewers": {
    "codex": {
      "output_file": "$REVIEWS_DIR/codex.json",
      "sentinel_file": "$REVIEWS_DIR/codex.done",
      "completed_at": null,
      "result": null
    }
  },
  "consensus": null,
  "decision": null,
  "created_at": "$created_at",
  "iteration": 0
}
EOF

log_test "check handles an empty running reviewer list under nounset"

stdout_file="$TEST_DIR/stdout"
stderr_file="$TEST_DIR/stderr"

set +e
printf '{"session_id":"%s","transcript_path":"%s"}' "$SESSION_ID" "$TRANSCRIPT_PATH" \
    | /bin/bash "$REVIEW_GATE" check >"$stdout_file" 2>"$stderr_file"
status=$?
set -e

stdout=$(cat "$stdout_file")
stderr=$(cat "$stderr_file")

if [[ "$status" -ne 0 ]]; then
    log_fail "expected check to exit 0, got $status\nstdout:\n$stdout\nstderr:\n$stderr"
fi

if [[ "$stdout$stderr" == *"unbound variable"* ]]; then
    log_fail "check crashed on empty running_list\nstdout:\n$stdout\nstderr:\n$stderr"
fi

decision=$(jq -r '.decision // empty' "$stdout_file")
if [[ "$decision" != "block" ]]; then
    log_fail "expected hook to return block JSON after consensus processing, got stdout:\n$stdout\nstderr:\n$stderr"
fi

state_status=$(jq -r '.status' "$STATE_FILE")
if [[ "$state_status" != "resolved" ]]; then
    log_fail "expected auto-approved gate to resolve, got state status $state_status"
fi

consensus=$(jq -r '.consensus.verdict // empty' "$STATE_FILE")
if [[ "$consensus" != "auto_approve" ]]; then
    log_fail "expected consensus auto_approve, got $consensus"
fi

action=$(jq -r '.decision.action // empty' "$STATE_FILE")
if [[ "$action" != "proceed" ]]; then
    log_fail "expected resolved proceed action, got $action"
fi

log_pass "check handles completed reviewers without nounset failure"
