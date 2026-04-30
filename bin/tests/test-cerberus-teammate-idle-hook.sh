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

make_repo() {
    local repo="$1"

    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email test@example.com
    git -C "$repo" config user.name Test
    git -C "$repo" commit --allow-empty -q -m init
}

commit_repo_change() {
    local repo="$1"
    local file_name="$2"
    local content="$3"

    printf '%s\n' "$content" > "${repo}/${file_name}"
    git -C "$repo" add "$file_name"
    git -C "$repo" commit -q -m "change ${file_name}"
}

write_idle_state() {
    local team_hash="$1"
    local task_id="$2"
    local repo_root="${3:-}"
    local state_dir="${TMP_ROOT}/cerberus-task-completed-hook/${team_hash}/${task_id}"
    local baseline_sha=""

    if [[ -n "$repo_root" ]]; then
        baseline_sha="$(git -C "$repo_root" rev-parse HEAD)"
    fi

    mkdir -p "$state_dir"
    jq -n \
        --arg task_id "$task_id" \
        --arg claude_task_id "test-${task_id}" \
        --arg team_hash "$team_hash" \
        --arg baseline_sha "$baseline_sha" \
        --arg repo_root "$repo_root" \
        '{task_id:$task_id, claude_task_id:$claude_task_id, team_hash:$team_hash, baseline_sha:$baseline_sha, round:0, max_rounds:3, repo_root:$repo_root}' \
        > "${state_dir}/state.json"
    printf '%s\n' "$state_dir"
}

idle_event() {
    local team_hash="$1"
    local teammate_name="$2"
    local cwd="${3:-}"

    jq -cn \
        --arg team_name "cerberus-impl-${team_hash}" \
        --arg teammate_name "$teammate_name" \
        --arg cwd "$cwd" \
        '{hook_event_name:"TeammateIdle", team_name:$team_name, teammate_name:$teammate_name} + (if $cwd != "" then {cwd:$cwd} else {} end)'
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

log_test "matched Cerberus implementer with missing state fails open"
set +e
output=$(run_hook_json "$(idle_event abc123 impl-T099)" 2>&1)
status=$?
set -e
idle_dir="$TMP_ROOT/cerberus-task-completed-hook/abc123/.teammate-idle/impl-T099"
if [[ "$status" -ne 0 || -n "$output" || -e "$idle_dir" ]]; then
    log_fail "expected missing state to exit 0 without suppression marker, status=$status output=$output"
fi
log_pass "missing state fails open"

log_test "matched Cerberus implementer with malformed state fails open"
malformed_state_dir="$TMP_ROOT/cerberus-task-completed-hook/abc123/T098"
mkdir -p "$malformed_state_dir"
printf 'not json\n' > "$malformed_state_dir/state.json"
set +e
output=$(run_hook_json "$(idle_event abc123 impl-T098)" 2>&1)
status=$?
set -e
idle_dir="$TMP_ROOT/cerberus-task-completed-hook/abc123/.teammate-idle/impl-T098"
if [[ "$status" -ne 0 || -n "$output" || -e "$idle_dir" ]]; then
    log_fail "expected malformed state to exit 0 without suppression marker, status=$status output=$output"
fi
log_pass "malformed state fails open"

log_test "first Cerberus implementer idle with stable evidence is allowed and recorded"
repo="$TEST_DIR/stable-repo"
make_repo "$repo"
state_dir=$(write_idle_state abc123 T001 "$repo")
event=$(idle_event abc123 impl-T001 "$repo")
set +e
output=$(run_hook_json "$event" 2>&1)
status=$?
set -e
idle_dir="$TMP_ROOT/cerberus-task-completed-hook/abc123/.teammate-idle/impl-T001"
if [[ "$status" -ne 0 || -n "$output" || ! -d "$idle_dir" || ! -f "$idle_dir/last_epoch.txt" || ! -f "$idle_dir/last_seen_at" ]]; then
    log_fail "expected first idle to be allowed with epoch marker, status=$status output=$output"
fi
log_pass "first idle allowed"

log_test "repeated Cerberus implementer idle with unchanged evidence stops teammate"
set +e
output=$(run_hook_json "$event" 2>&1)
status=$?
set -e
continue_value=$(printf '%s' "$output" | jq -r 'if has("continue") then (.continue | tostring) else "" end' 2>/dev/null || true)
stop_reason=$(printf '%s' "$output" | jq -r '.stopReason // ""' 2>/dev/null || true)
if [[ "$status" -ne 0 || "$continue_value" != "false" || -z "$stop_reason" || "$output" != *"task evidence has not changed"* ]]; then
    log_fail "expected repeated idle to emit continue:false, status=$status output=$output"
fi
log_pass "repeated idle stops teammate"

log_test "human-input retry with new commit creates a new idle epoch"
repo="$TEST_DIR/human-retry-repo"
make_repo "$repo"
state_dir=$(write_idle_state abc123 T005 "$repo")
event=$(idle_event abc123 impl-T005 "$repo")
set +e
output=$(run_hook_json "$event" 2>&1)
status=$?
set -e
if [[ "$status" -ne 0 || -n "$output" ]]; then
    log_fail "expected first retry idle to be allowed, status=$status output=$output"
fi
commit_repo_change "$repo" retry.txt retry
set +e
output=$(run_hook_json "$event" 2>&1)
status=$?
set -e
if [[ "$status" -ne 0 || -n "$output" ]]; then
    log_fail "expected changed HEAD to allow a new idle epoch, status=$status output=$output"
fi
set +e
output=$(run_hook_json "$event" 2>&1)
status=$?
set -e
continue_value=$(printf '%s' "$output" | jq -r 'if has("continue") then (.continue | tostring) else "" end' 2>/dev/null || true)
if [[ "$status" -ne 0 || "$continue_value" != "false" ]]; then
    log_fail "expected repeated retry idle at same HEAD to suppress, status=$status output=$output"
fi
log_pass "new commit creates a new idle epoch"

log_test "success evidence at same HEAD creates a new idle epoch"
repo="$TEST_DIR/same-head-success-repo"
make_repo "$repo"
state_dir=$(write_idle_state abc123 T006 "$repo")
event=$(idle_event abc123 impl-T006 "$repo")
set +e
output=$(run_hook_json "$event" 2>&1)
status=$?
set -e
if [[ "$status" -ne 0 || -n "$output" ]]; then
    log_fail "expected pre-success idle to be allowed, status=$status output=$output"
fi
head_sha=$(git -C "$repo" rev-parse HEAD)
touch "$state_dir/verified_pass" "$state_dir/reviewed_pass"
printf '%s\n' "$head_sha" > "$state_dir/verified_head"
printf '%s\n' "$head_sha" > "$state_dir/reviewed_head"
set +e
output=$(run_hook_json "$event" 2>&1)
status=$?
set -e
if [[ "$status" -ne 0 || -n "$output" ]]; then
    log_fail "expected success markers at same HEAD to allow a new idle epoch, status=$status output=$output"
fi
set +e
output=$(run_hook_json "$event" 2>&1)
status=$?
set -e
continue_value=$(printf '%s' "$output" | jq -r 'if has("continue") then (.continue | tostring) else "" end' 2>/dev/null || true)
if [[ "$status" -ne 0 || "$continue_value" != "false" ]]; then
    log_fail "expected repeated success idle to suppress, status=$status output=$output"
fi
log_pass "success markers create a new idle epoch"

log_test "lead epoch allows same-HEAD idle after human input"
repo="$TEST_DIR/lead-epoch-repo"
make_repo "$repo"
state_dir=$(write_idle_state abc123 T008 "$repo")
event=$(idle_event abc123 impl-T008 "$repo")
set +e
output=$(run_hook_json "$event" 2>&1)
status=$?
set -e
if [[ "$status" -ne 0 || -n "$output" ]]; then
    log_fail "expected first pre-input idle to be allowed, status=$status output=$output"
fi
printf 'human-input\n' > "$state_dir/lead_epoch"
set +e
output=$(run_hook_json "$event" 2>&1)
status=$?
set -e
if [[ "$status" -ne 0 || -n "$output" ]]; then
    log_fail "expected lead_epoch change to allow same-HEAD idle, status=$status output=$output"
fi
set +e
output=$(run_hook_json "$event" 2>&1)
status=$?
set -e
continue_value=$(printf '%s' "$output" | jq -r 'if has("continue") then (.continue | tostring) else "" end' 2>/dev/null || true)
if [[ "$status" -ne 0 || "$continue_value" != "false" ]]; then
    log_fail "expected repeated same lead_epoch idle to suppress, status=$status output=$output"
fi
log_pass "lead epoch creates a same-HEAD idle epoch"

log_test "verify_failed evidence allows same-HEAD idle once"
repo="$TEST_DIR/verify-failed-repo"
make_repo "$repo"
state_dir=$(write_idle_state abc123 T009 "$repo")
event=$(idle_event abc123 impl-T009 "$repo")
set +e
output=$(run_hook_json "$event" 2>&1)
status=$?
set -e
if [[ "$status" -ne 0 || -n "$output" ]]; then
    log_fail "expected pre-verify-failed idle to be allowed, status=$status output=$output"
fi
touch "$state_dir/verify_failed"
set +e
output=$(run_hook_json "$event" 2>&1)
status=$?
set -e
if [[ "$status" -ne 0 || -n "$output" ]]; then
    log_fail "expected verify_failed marker to allow same-HEAD idle, status=$status output=$output"
fi
set +e
output=$(run_hook_json "$event" 2>&1)
status=$?
set -e
continue_value=$(printf '%s' "$output" | jq -r 'if has("continue") then (.continue | tostring) else "" end' 2>/dev/null || true)
if [[ "$status" -ne 0 || "$continue_value" != "false" ]]; then
    log_fail "expected repeated verify_failed idle to suppress, status=$status output=$output"
fi
log_pass "verify_failed marker creates a same-HEAD idle epoch"

log_test "round-only state change allows same-HEAD idle once"
repo="$TEST_DIR/round-change-repo"
make_repo "$repo"
state_dir=$(write_idle_state abc123 T010 "$repo")
event=$(idle_event abc123 impl-T010 "$repo")
set +e
output=$(run_hook_json "$event" 2>&1)
status=$?
set -e
if [[ "$status" -ne 0 || -n "$output" ]]; then
    log_fail "expected pre-round-change idle to be allowed, status=$status output=$output"
fi
tmp_state="$state_dir/state.json.tmp"
jq '.round = 1' "$state_dir/state.json" > "$tmp_state"
mv "$tmp_state" "$state_dir/state.json"
set +e
output=$(run_hook_json "$event" 2>&1)
status=$?
set -e
if [[ "$status" -ne 0 || -n "$output" ]]; then
    log_fail "expected round change to allow same-HEAD idle, status=$status output=$output"
fi
set +e
output=$(run_hook_json "$event" 2>&1)
status=$?
set -e
continue_value=$(printf '%s' "$output" | jq -r 'if has("continue") then (.continue | tostring) else "" end' 2>/dev/null || true)
if [[ "$status" -ne 0 || "$continue_value" != "false" ]]; then
    log_fail "expected repeated same round idle to suppress, status=$status output=$output"
fi
log_pass "round-only state change creates a same-HEAD idle epoch"

log_test "exhausted evidence is allowed once and then suppressed"
repo="$TEST_DIR/exhausted-repo"
make_repo "$repo"
state_dir=$(write_idle_state abc123 T007 "$repo")
touch "$state_dir/exhausted"
event=$(idle_event abc123 impl-T007 "$repo")
set +e
output=$(run_hook_json "$event" 2>&1)
status=$?
set -e
if [[ "$status" -ne 0 || -n "$output" ]]; then
    log_fail "expected first exhausted idle to be allowed, status=$status output=$output"
fi
set +e
output=$(run_hook_json "$event" 2>&1)
status=$?
set -e
continue_value=$(printf '%s' "$output" | jq -r 'if has("continue") then (.continue | tostring) else "" end' 2>/dev/null || true)
if [[ "$status" -ne 0 || "$continue_value" != "false" ]]; then
    log_fail "expected repeated exhausted idle to suppress, status=$status output=$output"
fi
log_pass "exhausted evidence suppresses only unchanged repeats"

log_test "from field is accepted as teammate name fallback"
state_dir=$(write_idle_state abc123 T002 "$repo")
set +e
output=$(run_hook_json "$(jq -cn --arg cwd "$repo" '{hook_event_name:"TeammateIdle", team_name:"cerberus-impl-abc123", from:"impl-T002", cwd:$cwd}')" 2>&1)
status=$?
set -e
idle_dir="$TMP_ROOT/cerberus-task-completed-hook/abc123/.teammate-idle/impl-T002"
if [[ "$status" -ne 0 || -n "$output" || ! -d "$idle_dir" || ! -f "$idle_dir/last_epoch.txt" ]]; then
    log_fail "expected from field fallback to create marker, status=$status output=$output"
fi
log_pass "from fallback accepted"

log_test "object-form team and teammate fields are accepted"
state_dir=$(write_idle_state abc123 T003 "$repo")
set +e
output=$(run_hook_json "$(jq -cn --arg cwd "$repo" '{hook_event_name:"TeammateIdle", team:{name:"cerberus-impl-abc123"}, teammate:{name:"impl-T003"}, cwd:$cwd}')" 2>&1)
status=$?
set -e
idle_dir="$TMP_ROOT/cerberus-task-completed-hook/abc123/.teammate-idle/impl-T003"
if [[ "$status" -ne 0 || -n "$output" || ! -d "$idle_dir" || ! -f "$idle_dir/last_epoch.txt" ]]; then
    log_fail "expected object-form fields to create marker, status=$status output=$output"
fi
log_pass "object-form fields accepted"

log_test "string-form team and teammate fields are accepted"
state_dir=$(write_idle_state abc123 T004 "$repo")
set +e
output=$(run_hook_json "$(jq -cn --arg cwd "$repo" '{hook_event_name:"TeammateIdle", team:"cerberus-impl-abc123", teammate:"impl-T004", cwd:$cwd}')" 2>&1)
status=$?
set -e
idle_dir="$TMP_ROOT/cerberus-task-completed-hook/abc123/.teammate-idle/impl-T004"
if [[ "$status" -ne 0 || -n "$output" || ! -d "$idle_dir" || ! -f "$idle_dir/last_epoch.txt" ]]; then
    log_fail "expected string-form fields to create marker, status=$status output=$output"
fi
log_pass "string-form fields accepted"
