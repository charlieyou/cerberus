#!/usr/bin/env bash
# Tests for bin/review-gate completion-check, the compact lifecycle envelope
# consumed by the Amp agent.end plugin hook.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REVIEW_GATE="$REPO_ROOT/bin/review-gate"

if ! command -v jq >/dev/null 2>&1; then
    echo "FATAL: jq required for completion-check tests" >&2
    exit 2
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR=""

log_test() { echo -e "${YELLOW}TEST:${NC} $1"; }
log_pass() { echo -e "${GREEN}PASS:${NC} $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
log_fail() { echo -e "${RED}FAIL:${NC} $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

TEST_DIR="$(mktemp -d -t cerberus-completion-check.XXXXXX)"
STATE_ROOT="$TEST_DIR/projects"
PROJECT_KEY="completion-project"
RUN_KEY="completion-run"
RUN_DIR="$STATE_ROOT/$PROJECT_KEY/$RUN_KEY"
REVIEWS_DIR="$RUN_DIR/reviews"
mkdir -p "$REVIEWS_DIR"

write_state() {
    local status="$1"
    local consensus="$2"
    local decision_action="${3:-}"
    jq -n \
        --arg status "$status" \
        --arg consensus "$consensus" \
        --arg decision_action "$decision_action" \
        --arg project_key "$PROJECT_KEY" \
        --arg run_key "$RUN_KEY" \
        '{
            status: $status,
            host: "amp",
            owner: {project_key: $project_key, session_key: $run_key},
            reviewers: {},
            consensus: (if $consensus == "" then {} else {verdict: $consensus} end),
            decision: (if $decision_action == "" then {} else {action: $decision_action} end)
        }' > "$RUN_DIR/gate-state.json"
}

run_check() {
    CERBERUS_HOST=amp \
    CERBERUS_STATE_ROOT="$STATE_ROOT" \
    CERBERUS_PROJECT_KEY="$PROJECT_KEY" \
    CERBERUS_RUN_KEY="$RUN_KEY" \
        "$REVIEW_GATE" completion-check --host amp --json
}

assert_decision() {
    local name="$1"
    local expected_decision="$2"
    local expected_reason="$3"
    local body="$4"
    local actual_decision actual_reason
    actual_decision="$(printf '%s' "$body" | jq -r '.decision // empty')"
    actual_reason="$(printf '%s' "$body" | jq -r '.reason // empty')"
    if [[ "$actual_decision" != "$expected_decision" ]]; then
        log_fail "$name - decision '$actual_decision' (expected '$expected_decision'); body=$body"
    elif [[ "$actual_reason" != "$expected_reason" ]]; then
        log_fail "$name - reason '$actual_reason' (expected '$expected_reason'); body=$body"
    else
        log_pass "$name"
    fi
}

log_test "completion-check allows when no active gate exists"
body="$(run_check)"
assert_decision "no active gate" "allow" "no_active_gate" "$body"

log_test "completion-check continues for pending gate"
write_state "pending" ""
body="$(run_check)"
assert_decision "pending gate" "continue" "pending" "$body"

log_test "completion-check allows resolved PASS"
write_state "resolved" "PASS"
body="$(run_check)"
assert_decision "resolved pass" "allow" "resolved_pass" "$body"

log_test "completion-check continues resolved FAIL"
write_state "resolved" "FAIL"
body="$(run_check)"
assert_decision "resolved fail" "continue" "resolved_fail" "$body"

log_test "completion-check allows manual resolve even when prior consensus failed"
write_state "resolved" "FAIL" "manual_resolve"
body="$(run_check)"
assert_decision "manual resolve" "allow" "manual_resolve" "$body"

echo ""
echo "completion-check test summary:"
echo "  Passed: $TESTS_PASSED"
echo "  Failed: $TESTS_FAILED"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
