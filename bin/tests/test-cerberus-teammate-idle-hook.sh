#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../cerberus-teammate-idle-hook"

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
TMP_ROOT="$TEST_DIR/tmp"
mkdir -p "$TMP_ROOT"

run_hook_json() {
    local json="$1"
    printf '%s' "$json" | TMPDIR="$TMP_ROOT" "$HOOK"
}

log_test "unrelated TeammateIdle events fail open"
set +e
output=$(run_hook_json '{"hook_event_name":"TeammateIdle","team_name":"other-team","teammate_name":"impl-T001"}' 2>&1)
status=$?
set -e
if [[ "$status" -ne 0 || -n "$output" ]]; then
    log_fail "expected unrelated team to exit 0 silently, status=$status output=$output"
fi
log_pass "unrelated team ignored"

log_test "non-TeammateIdle events fail open"
set +e
output=$(run_hook_json '{"hook_event_name":"TaskCompleted","team_name":"cerberus-impl-abc123","teammate_name":"impl-T001"}' 2>&1)
status=$?
set -e
if [[ "$status" -ne 0 || -n "$output" ]]; then
    log_fail "expected non-TeammateIdle event to exit 0 silently, status=$status output=$output"
fi
log_pass "non-TeammateIdle event ignored"

log_test "malformed input fails open"
set +e
output=$(run_hook_json 'not json' 2>&1)
status=$?
set -e
if [[ "$status" -ne 0 || -n "$output" ]]; then
    log_fail "expected malformed input to exit 0 silently, status=$status output=$output"
fi
log_pass "malformed input ignored"

log_test "non-implementer teammates are ignored"
set +e
output=$(run_hook_json '{"hook_event_name":"TeammateIdle","team_name":"cerberus-impl-abc123","teammate_name":"reviewer-T001"}' 2>&1)
status=$?
set -e
if [[ "$status" -ne 0 || -n "$output" ]]; then
    log_fail "expected non-implementer teammate to exit 0 silently, status=$status output=$output"
fi
log_pass "non-implementer teammate ignored"

log_test "first Cerberus implementer idle is allowed and recorded"
set +e
output=$(run_hook_json '{"hook_event_name":"TeammateIdle","team_name":"cerberus-impl-abc123","teammate_name":"impl-T001"}' 2>&1)
status=$?
set -e
marker="$TMP_ROOT/cerberus-task-completed-hook/abc123/.teammate-idle/impl-T001.seen"
if [[ "$status" -ne 0 || -n "$output" || ! -d "$marker" || ! -f "$marker/first_seen_at" ]]; then
    log_fail "expected first idle to be allowed with marker, status=$status output=$output"
fi
log_pass "first idle allowed"

log_test "repeated Cerberus implementer idle stops teammate"
set +e
output=$(run_hook_json '{"hook_event_name":"TeammateIdle","team_name":"cerberus-impl-abc123","teammate_name":"impl-T001"}' 2>&1)
status=$?
set -e
continue_value=$(printf '%s' "$output" | jq -r 'if has("continue") then (.continue | tostring) else "" end' 2>/dev/null || true)
stop_reason=$(printf '%s' "$output" | jq -r '.stopReason // ""' 2>/dev/null || true)
if [[ "$status" -ne 0 || "$continue_value" != "false" || -z "$stop_reason" || "$output" != *"Suppressing repeated idle notifications"* ]]; then
    log_fail "expected repeated idle to emit continue:false, status=$status output=$output"
fi
log_pass "repeated idle stops teammate"

log_test "from field is accepted as teammate name fallback"
set +e
output=$(run_hook_json '{"hook_event_name":"TeammateIdle","team_name":"cerberus-impl-abc123","from":"impl-T002"}' 2>&1)
status=$?
set -e
marker="$TMP_ROOT/cerberus-task-completed-hook/abc123/.teammate-idle/impl-T002.seen"
if [[ "$status" -ne 0 || -n "$output" || ! -d "$marker" ]]; then
    log_fail "expected from field fallback to create marker, status=$status output=$output"
fi
log_pass "from fallback accepted"

log_test "object-form team and teammate fields are accepted"
set +e
output=$(run_hook_json '{"hook_event_name":"TeammateIdle","team":{"name":"cerberus-impl-abc123"},"teammate":{"name":"impl-T003"}}' 2>&1)
status=$?
set -e
marker="$TMP_ROOT/cerberus-task-completed-hook/abc123/.teammate-idle/impl-T003.seen"
if [[ "$status" -ne 0 || -n "$output" || ! -d "$marker" ]]; then
    log_fail "expected object-form fields to create marker, status=$status output=$output"
fi
log_pass "object-form fields accepted"

log_test "string-form team and teammate fields are accepted"
set +e
output=$(run_hook_json '{"hook_event_name":"TeammateIdle","team":"cerberus-impl-abc123","teammate":"impl-T004"}' 2>&1)
status=$?
set -e
marker="$TMP_ROOT/cerberus-task-completed-hook/abc123/.teammate-idle/impl-T004.seen"
if [[ "$status" -ne 0 || -n "$output" || ! -d "$marker" ]]; then
    log_fail "expected string-form fields to create marker, status=$status output=$output"
fi
log_pass "string-form fields accepted"
