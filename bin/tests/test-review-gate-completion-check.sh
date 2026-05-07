#!/usr/bin/env bash
# Tests for bin/review-gate completion-check, the compact lifecycle envelope
# consumed by host adapters.

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
            host: "codex",
            owner: {project_key: $project_key, session_key: $run_key},
            reviewers: {},
            consensus: (if $consensus == "" then {} else {verdict: $consensus} end),
            decision: (if $decision_action == "" then {} else {action: $decision_action} end)
        }' > "$RUN_DIR/gate-state.json"
}

run_check() {
    CERBERUS_HOST=codex \
    CERBERUS_STATE_ROOT="$STATE_ROOT" \
    CERBERUS_PROJECT_KEY="$PROJECT_KEY" \
    CERBERUS_RUN_KEY="$RUN_KEY" \
        "$REVIEW_GATE" completion-check --host codex --json
}

run_resolve() {
    CERBERUS_HOST=codex \
    CERBERUS_STATE_ROOT="$STATE_ROOT" \
    CERBERUS_PROJECT_KEY="$PROJECT_KEY" \
    CERBERUS_RUN_KEY="$RUN_KEY" \
        "$REVIEW_GATE" resolve --reason "$1" >/dev/null
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
pending_count="$(printf '%s' "$body" | jq -r '.pending_count // empty')"
finding_count="$(printf '%s' "$body" | jq -r '.finding_count // empty')"
if [[ "$pending_count" == "0" && "$finding_count" == "0" ]]; then
    log_pass "pending gate exposes counts"
else
    log_fail "pending gate counts missing/wrong; pending_count='$pending_count' finding_count='$finding_count' body=$body"
fi

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

log_test "resolve records manual_resolve so clear-gate overrides failed consensus"
write_state "awaiting_decision" "FAIL"
run_resolve "manual clear via test"
action="$(jq -r '.decision.action // empty' "$RUN_DIR/gate-state.json")"
body="$(run_check)"
if [[ "$action" == "manual_resolve" ]]; then
    log_pass "resolve writes manual_resolve"
else
    log_fail "resolve action '$action' (expected manual_resolve)"
fi
assert_decision "resolved manual clear" "allow" "manual_resolve" "$body"

log_test "completion-check userMessage distinguishes pending reviewers from awaiting decision"
# All reviewers complete (pending_count=0) on a still-pending gate => the
# message must NOT misleadingly say reviewers are pending; it must mention
# 'reviewers complete' and reference the consensus verdict.
write_state "pending" "FAIL"
body="$(run_check)"
message="$(printf '%s' "$body" | jq -r '.userMessage // empty')"
if [[ "$message" == *"reviewers complete but gate not cleared"* ]]; then
    log_pass "reviewers-complete wording"
else
    log_fail "reviewers-complete wording missing; userMessage='$message'"
fi

rm -f "$REVIEWS_DIR"/*
jq -n '{
    status: "pending",
    host: "codex",
    owner: {project_key: "completion-project", session_key: "completion-run"},
    reviewers: {gemini: {}},
    consensus: {verdict: "FAIL"},
    decision: {}
}' > "$RUN_DIR/gate-state.json"
cat > "$REVIEWS_DIR/gemini.json" <<'JSON'
{"verdict":"FAIL","summary":"Bad","findings":[{"title":"x","body":"y","priority":1,"file_path":null,"line_start":null,"line_end":null}]}
JSON
touch "$REVIEWS_DIR/gemini.done"
body="$(run_check)"
pending_count="$(printf '%s' "$body" | jq -r '.pending_count // empty')"
finding_count="$(printf '%s' "$body" | jq -r '.finding_count // empty')"
if [[ "$pending_count" == "0" && "$finding_count" == "1" ]]; then
    log_pass "completed reviewer finding count exposed"
else
    log_fail "completed reviewer counts missing/wrong; pending_count='$pending_count' finding_count='$finding_count' body=$body"
fi

# And when reviewers are still pending, the original wording remains.
rm -f "$REVIEWS_DIR"/*
mkdir -p "$REVIEWS_DIR"
jq -n '{
    status: "pending",
    host: "codex",
    owner: {project_key: "completion-project", session_key: "completion-run"},
    reviewers: {claude: {}, codex: {}},
    consensus: {},
    decision: {}
}' > "$RUN_DIR/gate-state.json"
body="$(run_check)"
message="$(printf '%s' "$body" | jq -r '.userMessage // empty')"
if [[ "$message" == *"Pending reviewers: 2"* ]]; then
    log_pass "pending-reviewers wording"
else
    log_fail "pending-reviewers wording missing; userMessage='$message'"
fi
pending_count="$(printf '%s' "$body" | jq -r '.pending_count // empty')"
if [[ "$pending_count" == "2" ]]; then
    log_pass "pending-reviewers count exposed"
else
    log_fail "pending-reviewers count missing/wrong; pending_count='$pending_count' body=$body"
fi

echo ""
echo "completion-check test summary:"
echo "  Passed: $TESTS_PASSED"
echo "  Failed: $TESTS_FAILED"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
