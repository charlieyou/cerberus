#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../cerberus-task-completed-hook"

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

run_hook() {
    local subject="$1"
    local hook_cwd="${2:-$PWD}"
    printf '{"hook_event_name":"TaskCompleted","task_subject":"%s","cwd":"%s","session_id":"test-session","transcript_path":"%s/transcript.jsonl"}' \
        "$subject" "$hook_cwd" "$TEST_DIR" | TMPDIR="$TMP_ROOT" "$HOOK"
}

write_state() {
    local max_rounds="${1:-5}"
    local _unused_start_sha="${2:-}"
    local repo="${3:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    local state_dir="$TMP_ROOT/cerberus-task-completed-hook/abc123/T001"
    local verify_script_path="$state_dir/verify.sh"
    mkdir -p "$state_dir"
    printf 'context\n' > "$state_dir/task-context.md"
    cat > "$verify_script_path" <<'VERIFY'
#!/usr/bin/env bash
set -euo pipefail
VERIFY
    jq -n \
        --arg task_id T001 \
        --arg claude_task_id task-1 \
        --arg team_hash abc123 \
        --arg task_state_dir "$state_dir" \
        --arg task_context_path "$state_dir/task-context.md" \
        --arg verify_script_path "$verify_script_path" \
        --argjson max_rounds "$max_rounds" \
        '{task_id:$task_id, claude_task_id:$claude_task_id, team_hash:$team_hash, round:0, max_rounds:$max_rounds, task_state_dir:$task_state_dir, task_context_path:$task_context_path, verify_script_path:$verify_script_path}' \
        > "$state_dir/state.json"
    printf '%s' "$state_dir"
}

touch_completion_intent() {
    local state_dir="$1"

    touch "$state_dir/completion_intent"
}

write_task_commits() {
    local state_dir="$1"
    shift

    printf '%s\n' "$@" > "$state_dir/task_commits.txt"
}

assert_no_claimed_intent() {
    local state_dir="$1"

    if compgen -G "$state_dir/completion_intent.claimed.*" >/dev/null; then
        log_fail "expected claimed completion_intent marker to be cleaned up in $state_dir"
    fi
}

make_review_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email test@example.com
    git -C "$repo" config user.name Test
    git -C "$repo" config core.excludesFile /dev/null
    git -C "$repo" commit --allow-empty -q -m init
    printf 'hello\n' > "$repo/hello.txt"
    git -C "$repo" add hello.txt
    git -C "$repo" commit -q -m "T001: add hello" -m "Cerberus-Task: T001"
}

make_fake_review_gate() {
    local plugin_root="$1"
    mkdir -p "$plugin_root/bin"
    cat > "$plugin_root/bin/review-gate" <<'FAKE_REVIEW_GATE'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  spawn-code-review)
    if [[ -n "${FAKE_REVIEW_ARGS_FILE:-}" ]]; then
        printf '%s\n' "$*" > "$FAKE_REVIEW_ARGS_FILE"
    fi
    exit 0
    ;;
  wait)
    if [[ -n "${FAKE_WAIT_SLEEP:-}" ]]; then
        sleep "$FAKE_WAIT_SLEEP"
    fi
    if [[ -n "${FAKE_DIRTY_AFTER_REVIEW_FILE:-}" ]]; then
        printf 'dirty after review\n' >> "$FAKE_DIRTY_AFTER_REVIEW_FILE"
    fi
    if [[ -n "${FAKE_UNTRACKED_AFTER_REVIEW_FILE:-}" ]]; then
        mkdir -p "$(dirname "$FAKE_UNTRACKED_AFTER_REVIEW_FILE")"
        printf 'untracked after review\n' > "$FAKE_UNTRACKED_AFTER_REVIEW_FILE"
    fi
    printf '%s\n' "${FAKE_WAIT_JSON}"
    case "${FAKE_WAIT_RC:-0}" in
      0) exit 0 ;;
      *) exit "${FAKE_WAIT_RC}" ;;
    esac
    ;;
  *)
    echo "unexpected fake review-gate command: ${1:-}" >&2
    exit 2
    ;;
esac
FAKE_REVIEW_GATE
    chmod +x "$plugin_root/bin/review-gate"
}

log_test "unrelated TaskCompleted events fail open"
set +e
output=$(run_hook "ordinary task" 2>&1)
status=$?
set -e
if [[ "$status" -ne 0 || -n "$output" ]]; then
    log_fail "expected unrelated task to exit 0 silently, got status=$status output=$output"
fi
log_pass "unrelated task ignored"

log_test "prefixed task without state writes last_error and blocks"
set +e
output=$(run_hook "[CERBERUS-IMPL/abc123] T001 - test" 2>&1)
status=$?
set -e
last_error="$TMP_ROOT/cerberus-task-completed-hook/abc123/T001/last_error"
if [[ "$status" -ne 2 || ! -f "$last_error" || "$output" != *"INFRA-FAILURE: missing Cerberus state"* ]]; then
    log_fail "expected missing state to exit 2 and write last_error, got status=$status output=$output"
fi
log_pass "missing state blocks completion"

log_test "prefixed task with state but no completion_intent blocks"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
state_dir=$(write_state)
set +e
output=$(run_hook "[CERBERUS-IMPL/abc123] T001 - test" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
if [[ "$status" -ne 2 || "$round" != "0" || "$output" != *"missing completion_intent marker"* ]]; then
    log_fail "expected missing intent event to block without changing round, status=$status round=$round output=$output"
fi
log_pass "missing intent event blocks completion"

log_test "claimed completion_intent blocks duplicate attempts"
touch "$state_dir/completion_intent.claimed.test"
set +e
output=$(run_hook "[CERBERUS-IMPL/abc123] T001 - test" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
if [[ "$status" -ne 2 || "$round" != "0" || "$output" != *"already claimed by another completion attempt"* ]]; then
    log_fail "expected claimed intent to block duplicate attempt, status=$status round=$round output=$output"
fi
rm -f "$state_dir/completion_intent.claimed.test"
log_pass "claimed intent blocks duplicate completion"

log_test "completion_intent without completion_grant proceeds"
touch "$state_dir/completion_intent"
set +e
output=$(run_hook "[CERBERUS-IMPL/abc123] T001 - test" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
if [[ "$status" -ne 2 || "$round" != "1" || -e "$state_dir/completion_intent" || "$output" != *"No explicit task commits recorded for T001"* ]]; then
    log_fail "expected intent without grant to reach commit validation and be consumed, status=$status round=$round output=$output"
fi
assert_no_claimed_intent "$state_dir"
log_pass "intent-only completion reaches hook validation"

log_test "completion_grant without completion_intent blocks and preserves grant"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
state_dir=$(write_state)
touch "$state_dir/completion_grant"
set +e
output=$(run_hook "[CERBERUS-IMPL/abc123] T001 - test" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
if [[ "$status" -ne 2 || "$round" != "0" || ! -e "$state_dir/completion_grant" || "$output" != *"missing completion_intent marker"* ]]; then
    log_fail "expected grant without intent to block and preserve grant, status=$status round=$round output=$output"
fi
rm -f "$state_dir/completion_grant"
log_pass "grant without intent blocks completion"

log_test "stale team completion.lock does not block completion intent"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
state_dir=$(write_state)
mkdir "$TMP_ROOT/cerberus-task-completed-hook/abc123/completion.lock"
touch "$state_dir/completion_intent"
set +e
output=$(run_hook "[CERBERUS-IMPL/abc123] T001 - test" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
if [[ "$status" -ne 2 || "$round" != "1" || -e "$state_dir/completion_intent" || ! -d "$TMP_ROOT/cerberus-task-completed-hook/abc123/completion.lock" || "$output" != *"No explicit task commits recorded for T001"* ]]; then
    log_fail "expected stale completion lock to be ignored while intent is consumed, status=$status round=$round output=$output"
fi
assert_no_claimed_intent "$state_dir"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123/completion.lock"
log_pass "stale completion lock no longer blocks completion"

log_test "state directory comparison tolerates trailing slash in TMPDIR"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
state_dir=$(write_state)
touch "$state_dir/completion_grant"
set +e
output=$(printf '{"hook_event_name":"TaskCompleted","task_subject":"%s","cwd":"%s","session_id":"test-session","transcript_path":"%s/transcript.jsonl"}' \
    "[CERBERUS-IMPL/abc123] T001 - test" "$PWD" "$TEST_DIR" \
    | TMPDIR="${TMP_ROOT}/" "$HOOK" 2>&1)
status=$?
set -e
if [[ "$status" -ne 2 || "$output" != *"missing completion_intent marker"* || -f "$state_dir/last_error" ]]; then
    log_fail "expected trailing-slash TMPDIR to reach completion_intent gate, status=$status output=$output"
fi
log_pass "trailing-slash TMPDIR does not trigger state-dir mismatch"

log_test "explicit completion without recorded commits blocks and increments round"
touch_completion_intent "$state_dir"
set +e
output=$(run_hook "[CERBERUS-IMPL/abc123] T001 - test" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
if [[ "$status" -ne 2 || "$round" != "1" || "$output" != *"No explicit task commits recorded for T001"* ]]; then
    log_fail "expected missing explicit commits to block and increment round, status=$status round=$round output=$output"
fi
assert_no_claimed_intent "$state_dir"
if [[ -e "$state_dir/completion_intent" ]]; then
    log_fail "expected completion_intent to be consumed"
fi
if [[ -e "$state_dir/completion_grant" ]]; then
    log_fail "expected completion_grant to be consumed"
fi
log_pass "missing tagged commit blocks completion"

log_test "final blocking attempt writes exhausted marker"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
state_dir=$(write_state 1)
touch_completion_intent "$state_dir"
set +e
output=$(run_hook "[CERBERUS-IMPL/abc123] T001 - test" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
if [[ "$status" -ne 2 || "$round" != "1" || ! -f "$state_dir/exhausted" ]]; then
    log_fail "expected final failed attempt to write exhausted, status=$status round=$round output=$output"
fi
log_pass "final failed attempt marks exhausted"

log_test "post-exhaustion retry blocks instead of looping"
touch_completion_intent "$state_dir"
set +e
output=$(run_hook "[CERBERUS-IMPL/abc123] T001 - test" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
if [[ "$status" -ne 2 || "$round" != "1" || ! -f "$state_dir/exhausted" || -e "$state_dir/completion_grant" || -e "$state_dir/completion_intent" || "$output" != *"Already exhausted"* ]]; then
    log_fail "expected exhausted retry to block without looping, status=$status round=$round output=$output"
fi
log_pass "post-exhaustion retry blocks without looping"

log_test "PASS review writes reviewed_pass and increments round"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
repo="$TEST_DIR/pass-repo"
make_review_repo "$repo"
state_dir=$(write_state 3 "" "$repo")
pass_sha=$(git -C "$repo" rev-parse HEAD)
write_task_commits "$state_dir" "$pass_sha"
touch_completion_intent "$state_dir"
fake_plugin="$TEST_DIR/fake-plugin-pass"
make_fake_review_gate "$fake_plugin"
set +e
output=$(printf '{"hook_event_name":"TaskCompleted","task_subject":"%s","cwd":"%s","session_id":"test-session","transcript_path":"%s/transcript.jsonl"}' \
    "[CERBERUS-IMPL/abc123] T001 - test" "$repo" "$TEST_DIR" \
    | TMPDIR="$TMP_ROOT" CLAUDE_PLUGIN_ROOT="$fake_plugin" FAKE_WAIT_JSON='{"status":"complete","consensus_verdict":"PASS","aggregated_findings":[]}' "$HOOK" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
task_commits=$(cat "$state_dir/task_commits.txt")
if [[ "$status" -ne 0 || "$round" != "1" || ! -f "$state_dir/reviewed_pass" || "$task_commits" != "$pass_sha" ]]; then
    log_fail "expected PASS review to allow completion, status=$status round=$round output=$output"
fi
assert_no_claimed_intent "$state_dir"
if [[ -e "$state_dir/completion_grant" || -e "$state_dir/completion_intent" ]]; then
    log_fail "expected PASS review to consume grant and intent"
fi
log_pass "PASS review allows completion"

log_test "duplicate TaskCompleted for reviewed HEAD is idempotent without fresh grant"
set +e
output=$(run_hook "[CERBERUS-IMPL/abc123] T001 - test" "$repo" 2>&1)
status=$?
set -e
round_after_duplicate=$(jq -r '.round' "$state_dir/state.json")
if [[ "$status" -ne 0 || -n "$output" || "$round_after_duplicate" != "1" ]]; then
    log_fail "expected duplicate reviewed-head completion to pass without fresh grant, status=$status round=$round_after_duplicate output=$output"
fi
log_pass "reviewed-head duplicate completion is idempotent"

log_test "active completion_intent claim blocks concurrent duplicate attempt"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
repo="$TEST_DIR/concurrent-claim-repo"
make_review_repo "$repo"
state_dir=$(write_state 3 "" "$repo")
write_task_commits "$state_dir" "$(git -C "$repo" rev-parse HEAD)"
touch_completion_intent "$state_dir"
fake_plugin="$TEST_DIR/fake-plugin-concurrent-claim"
make_fake_review_gate "$fake_plugin"
first_output="$TEST_DIR/concurrent-claim-first.out"
set +e
(
    printf '{"hook_event_name":"TaskCompleted","task_subject":"%s","cwd":"%s","session_id":"test-session","transcript_path":"%s/transcript.jsonl"}' \
        "[CERBERUS-IMPL/abc123] T001 - test" "$repo" "$TEST_DIR" \
        | TMPDIR="$TMP_ROOT" CLAUDE_PLUGIN_ROOT="$fake_plugin" FAKE_WAIT_SLEEP=1 FAKE_WAIT_JSON='{"status":"complete","consensus_verdict":"PASS","aggregated_findings":[]}' "$HOOK"
) > "$first_output" 2>&1 &
first_pid=$!
claim_seen="0"
for _ in {1..50}; do
    if compgen -G "$state_dir/completion_intent.claimed.*" >/dev/null; then
        claim_seen="1"
        break
    fi
    sleep 0.1
done
set -e
if [[ "$claim_seen" != "1" ]]; then
    kill "$first_pid" 2>/dev/null || true
    wait "$first_pid" 2>/dev/null || true
    log_fail "expected first hook to hold a claimed completion_intent marker"
fi
set +e
touch "$state_dir/completion_intent"
second_output=$(run_hook "[CERBERUS-IMPL/abc123] T001 - test" "$repo" 2>&1)
second_status=$?
wait "$first_pid"
first_status=$?
set -e
if [[ "$second_status" -ne 2 || "$second_output" != *"already claimed by another completion attempt"* ]]; then
    log_fail "expected concurrent duplicate to block on active claim, status=$second_status output=$second_output"
fi
if [[ -e "$state_dir/completion_intent" ]]; then
    log_fail "expected duplicate attempt's stale bare completion_intent to be consumed"
fi
if [[ "$first_status" -ne 0 ]]; then
    log_fail "expected first in-flight completion to succeed, status=$first_status output=$(cat "$first_output")"
fi
assert_no_claimed_intent "$state_dir"
log_pass "active claim blocks concurrent duplicate completion"

log_test "PASS review ignores new untracked files after review"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
repo="$TEST_DIR/untracked-after-review-repo"
make_review_repo "$repo"
state_dir=$(write_state 3 "" "$repo")
write_task_commits "$state_dir" "$(git -C "$repo" rev-parse HEAD)"
touch_completion_intent "$state_dir"
fake_plugin="$TEST_DIR/fake-plugin-untracked-after-review"
make_fake_review_gate "$fake_plugin"
untracked_file="$repo/cerberus-untracked-after-review.notignored"
set +e
output=$(printf '{"hook_event_name":"TaskCompleted","task_subject":"%s","cwd":"%s","session_id":"test-session","transcript_path":"%s/transcript.jsonl"}' \
    "[CERBERUS-IMPL/abc123] T001 - test" "$repo" "$TEST_DIR" \
    | TMPDIR="$TMP_ROOT" CLAUDE_PLUGIN_ROOT="$fake_plugin" FAKE_UNTRACKED_AFTER_REVIEW_FILE="$untracked_file" FAKE_WAIT_JSON='{"status":"complete","consensus_verdict":"PASS","aggregated_findings":[]}' "$HOOK" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
if [[ "$status" -ne 0 || "$round" != "1" || ! -f "$state_dir/reviewed_pass" || ! -f "$untracked_file" ]]; then
    log_fail "expected untracked file after review not to block success, status=$status round=$round output=$output"
fi
assert_no_claimed_intent "$state_dir"
log_pass "new untracked files after review do not block success"

log_test "PASS review blocks if tracked files become dirty after review"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
repo="$TEST_DIR/dirty-after-review-repo"
make_review_repo "$repo"
state_dir=$(write_state 3 "" "$repo")
write_task_commits "$state_dir" "$(git -C "$repo" rev-parse HEAD)"
touch_completion_intent "$state_dir"
fake_plugin="$TEST_DIR/fake-plugin-dirty-after-review"
make_fake_review_gate "$fake_plugin"
set +e
output=$(printf '{"hook_event_name":"TaskCompleted","task_subject":"%s","cwd":"%s","session_id":"test-session","transcript_path":"%s/transcript.jsonl"}' \
    "[CERBERUS-IMPL/abc123] T001 - test" "$repo" "$TEST_DIR" \
    | TMPDIR="$TMP_ROOT" CLAUDE_PLUGIN_ROOT="$fake_plugin" FAKE_DIRTY_AFTER_REVIEW_FILE="$repo/hello.txt" FAKE_WAIT_JSON='{"status":"complete","consensus_verdict":"PASS","aggregated_findings":[]}' "$HOOK" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
if [[ "$status" -ne 2 || "$round" != "0" || -f "$state_dir/reviewed_pass" || "$output" != *"BLOCKED before accepting completion"* ]]; then
    log_fail "expected dirty tracked file after review to block success, status=$status round=$round output=$output"
fi
assert_no_claimed_intent "$state_dir"
log_pass "dirty tree after review blocks success"

log_test "explicit foreign task commit blocks even when task context exists"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
repo="$TEST_DIR/unlaunched-interleaved-repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name Test
git -C "$repo" commit --allow-empty -q -m init
printf 'one\n' > "$repo/one.txt"
git -C "$repo" add one.txt
git -C "$repo" commit -q -m "T001: add one" -m "Cerberus-Task: T001"
printf 'two\n' > "$repo/two.txt"
git -C "$repo" add two.txt
git -C "$repo" commit -q -m "T002: add two" -m "Cerberus-Task: T002"
t002_sha=$(git -C "$repo" rev-parse HEAD)
state_dir=$(write_state 3 "" "$repo")
mkdir -p "$TMP_ROOT/cerberus-task-completed-hook/abc123/task-contexts"
printf 'context for T002\n' > "$TMP_ROOT/cerberus-task-completed-hook/abc123/task-contexts/T002.md"
write_task_commits "$state_dir" "$t002_sha"
touch_completion_intent "$state_dir"
set +e
output=$(run_hook "[CERBERUS-IMPL/abc123] T001 - test" "$repo" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
if [[ "$status" -ne 2 || "$round" != "1" || "$output" != *"Cerberus-Task: T002, expected T001"* ]]; then
    log_fail "expected explicit T002 commit to block in a T001 review despite context, status=$status round=$round output=$output"
fi
log_pass "explicit foreign task commits are not allowed by context alone"

log_test "explicit task commit not reachable from current HEAD blocks completion"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
repo="$TEST_DIR/unreachable-explicit-commit-repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name Test
git -C "$repo" commit --allow-empty -q -m init
base_branch=$(git -C "$repo" branch --show-current)
git -C "$repo" checkout -q -b task-branch
printf 'one\n' > "$repo/one.txt"
git -C "$repo" add one.txt
git -C "$repo" commit -q -m "T001: add one" -m "Cerberus-Task: T001"
t001_sha=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q "$base_branch"
printf 'current\n' > "$repo/current.txt"
git -C "$repo" add current.txt
git -C "$repo" commit -q -m "current branch work"
state_dir=$(write_state 3 "" "$repo")
write_task_commits "$state_dir" "$t001_sha"
touch_completion_intent "$state_dir"
set +e
output=$(run_hook "[CERBERUS-IMPL/abc123] T001 - test" "$repo" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
if [[ "$status" -ne 2 || "$round" != "1" || "$output" != *"not reachable from current HEAD"* ]]; then
    log_fail "expected unreachable explicit commit to block, status=$status round=$round output=$output"
fi
log_pass "unreachable explicit task commits block completion"

log_test "known interleaved task commits are allowed and only current task commits are reviewed"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
repo="$TEST_DIR/interleaved-repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name Test
git -C "$repo" commit --allow-empty -q -m init
printf 'one\n' > "$repo/one.txt"
git -C "$repo" add one.txt
git -C "$repo" commit -q -m "T001: add one" -m "Cerberus-Task: T001"
t001_sha=$(git -C "$repo" rev-parse HEAD)
printf 'two\n' > "$repo/two.txt"
git -C "$repo" add two.txt
git -C "$repo" commit -q -m "T002: add two" -m "Cerberus-Task: T002"
t002_sha=$(git -C "$repo" rev-parse HEAD)
state_dir=$(write_state 3 "" "$repo")
write_task_commits "$state_dir" "$t001_sha"
touch_completion_intent "$state_dir"
fake_plugin="$TEST_DIR/fake-plugin-interleaved"
make_fake_review_gate "$fake_plugin"
args_file="$TEST_DIR/interleaved-review.args"
set +e
output=$(printf '{"hook_event_name":"TaskCompleted","task_subject":"%s","cwd":"%s","session_id":"test-session","transcript_path":"%s/transcript.jsonl"}' \
    "[CERBERUS-IMPL/abc123] T001 - test" "$repo" "$TEST_DIR" \
    | TMPDIR="$TMP_ROOT" CLAUDE_PLUGIN_ROOT="$fake_plugin" FAKE_REVIEW_ARGS_FILE="$args_file" FAKE_WAIT_JSON='{"status":"complete","consensus_verdict":"PASS","aggregated_findings":[]}' "$HOOK" 2>&1)
status=$?
set -e
task_commits=$(cat "$state_dir/task_commits.txt")
review_args=$(cat "$args_file")
if [[ "$status" -ne 0 || "$task_commits" != *"$t001_sha"* || "$task_commits" == *"$t002_sha"* || "$review_args" != *"--commit $t001_sha"* || "$review_args" == *"$t002_sha"* ]]; then
    log_fail "expected interleaved T002 commit to be allowed but excluded from T001 review, status=$status task_commits=$task_commits review_args=$review_args output=$output"
fi
log_pass "interleaved known task commits do not break T001 completion"

log_test "interleaved task commits do not need accepted tracking after state cleanup"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
repo="$TEST_DIR/accepted-interleaved-repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name Test
git -C "$repo" commit --allow-empty -q -m init
printf 'one\n' > "$repo/one.txt"
git -C "$repo" add one.txt
git -C "$repo" commit -q -m "T001: add one" -m "Cerberus-Task: T001"
t001_sha=$(git -C "$repo" rev-parse HEAD)
printf 'two\n' > "$repo/two.txt"
git -C "$repo" add two.txt
git -C "$repo" commit -q -m "T002: add two" -m "Cerberus-Task: T002"
t002_sha=$(git -C "$repo" rev-parse HEAD)
state_dir=$(write_state 3 "" "$repo")
write_task_commits "$state_dir" "$t001_sha"
touch_completion_intent "$state_dir"
fake_plugin="$TEST_DIR/fake-plugin-accepted-interleaved"
make_fake_review_gate "$fake_plugin"
args_file="$TEST_DIR/accepted-interleaved-review.args"
set +e
output=$(printf '{"hook_event_name":"TaskCompleted","task_subject":"%s","cwd":"%s","session_id":"test-session","transcript_path":"%s/transcript.jsonl"}' \
    "[CERBERUS-IMPL/abc123] T001 - test" "$repo" "$TEST_DIR" \
    | TMPDIR="$TMP_ROOT" CLAUDE_PLUGIN_ROOT="$fake_plugin" FAKE_REVIEW_ARGS_FILE="$args_file" FAKE_WAIT_JSON='{"status":"complete","consensus_verdict":"PASS","aggregated_findings":[]}' "$HOOK" 2>&1)
status=$?
set -e
review_args=$(cat "$args_file")
if [[ "$status" -ne 0 || "$review_args" != *"--commit $t001_sha"* || "$review_args" == *"$t002_sha"* ]]; then
    log_fail "expected interleaved T002 commit to be irrelevant without accepted tracking, status=$status review_args=$review_args output=$output"
fi
log_pass "explicit commit list makes accepted interleaved tracking unnecessary"

log_test "unknown interleaved task commits outside explicit list are ignored"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
repo="$TEST_DIR/unknown-interleaved-repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name Test
git -C "$repo" commit --allow-empty -q -m init
printf 'one\n' > "$repo/one.txt"
git -C "$repo" add one.txt
git -C "$repo" commit -q -m "T001: add one" -m "Cerberus-Task: T001"
t001_sha=$(git -C "$repo" rev-parse HEAD)
printf 'unknown\n' > "$repo/unknown.txt"
git -C "$repo" add unknown.txt
git -C "$repo" commit -q -m "T999: add unknown" -m "Cerberus-Task: T999"
t999_sha=$(git -C "$repo" rev-parse HEAD)
state_dir=$(write_state 3 "" "$repo")
write_task_commits "$state_dir" "$t001_sha"
touch_completion_intent "$state_dir"
fake_plugin="$TEST_DIR/fake-plugin-unknown-interleaved"
make_fake_review_gate "$fake_plugin"
args_file="$TEST_DIR/unknown-interleaved-review.args"
set +e
output=$(printf '{"hook_event_name":"TaskCompleted","task_subject":"%s","cwd":"%s","session_id":"test-session","transcript_path":"%s/transcript.jsonl"}' \
    "[CERBERUS-IMPL/abc123] T001 - test" "$repo" "$TEST_DIR" \
    | TMPDIR="$TMP_ROOT" CLAUDE_PLUGIN_ROOT="$fake_plugin" FAKE_REVIEW_ARGS_FILE="$args_file" FAKE_WAIT_JSON='{"status":"complete","consensus_verdict":"PASS","aggregated_findings":[]}' "$HOOK" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
review_args=$(cat "$args_file")
if [[ "$status" -ne 0 || "$round" != "1" || "$review_args" != *"--commit $t001_sha"* || "$review_args" == *"$t999_sha"* ]]; then
    log_fail "expected unknown interleaved task commit outside explicit list to be ignored, status=$status round=$round review_args=$review_args output=$output"
fi
log_pass "unknown interleaved task commits outside explicit list are ignored"

log_test "PASS on final allowed round does not mark exhausted"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
repo="$TEST_DIR/final-pass-repo"
make_review_repo "$repo"
state_dir=$(write_state 3 "" "$repo")
write_task_commits "$state_dir" "$(git -C "$repo" rev-parse HEAD)"
jq '.round = 2' "$state_dir/state.json" > "$state_dir/state.json.tmp"
mv "$state_dir/state.json.tmp" "$state_dir/state.json"
touch_completion_intent "$state_dir"
fake_plugin="$TEST_DIR/fake-plugin-final-pass"
make_fake_review_gate "$fake_plugin"
set +e
output=$(printf '{"hook_event_name":"TaskCompleted","task_subject":"%s","cwd":"%s","session_id":"test-session","transcript_path":"%s/transcript.jsonl"}' \
    "[CERBERUS-IMPL/abc123] T001 - test" "$repo" "$TEST_DIR" \
    | TMPDIR="$TMP_ROOT" CLAUDE_PLUGIN_ROOT="$fake_plugin" FAKE_WAIT_JSON='{"status":"complete","consensus_verdict":"PASS","aggregated_findings":[]}' "$HOOK" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
if [[ "$status" -ne 0 || "$round" != "3" || ! -f "$state_dir/reviewed_pass" || -f "$state_dir/exhausted" ]]; then
    log_fail "expected final-round PASS to allow completion without exhausted, status=$status round=$round output=$output"
fi
log_pass "final-round PASS remains a success"

log_test "blocking review does not burn a round if tracked files become dirty after review"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
repo="$TEST_DIR/blocking-dirty-after-review-repo"
make_review_repo "$repo"
state_dir=$(write_state 3 "" "$repo")
write_task_commits "$state_dir" "$(git -C "$repo" rev-parse HEAD)"
touch_completion_intent "$state_dir"
fake_plugin="$TEST_DIR/fake-plugin-blocking-dirty-after-review"
make_fake_review_gate "$fake_plugin"
wait_json='{"status":"complete","consensus_verdict":"NEEDS_WORK","aggregated_findings":[{"priority":"P1","file_path":"hello.txt","line_start":1,"body":"broken behavior"}]}'
set +e
output=$(printf '{"hook_event_name":"TaskCompleted","task_subject":"%s","cwd":"%s","session_id":"test-session","transcript_path":"%s/transcript.jsonl"}' \
    "[CERBERUS-IMPL/abc123] T001 - test" "$repo" "$TEST_DIR" \
    | TMPDIR="$TMP_ROOT" CLAUDE_PLUGIN_ROOT="$fake_plugin" FAKE_DIRTY_AFTER_REVIEW_FILE="$repo/hello.txt" FAKE_WAIT_JSON="$wait_json" "$HOOK" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
if [[ "$status" -ne 2 || "$round" != "0" || -f "$state_dir/exhausted" || "$output" != *"BLOCKED before accepting completion"* ]]; then
    log_fail "expected dirty tree after blocking review to block before round increment, status=$status round=$round output=$output"
fi
assert_no_claimed_intent "$state_dir"
log_pass "dirty tree after blocking review does not burn a review round"

log_test "blocking review formats findings and marks exhausted on final round"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
repo="$TEST_DIR/fail-repo"
make_review_repo "$repo"
state_dir=$(write_state 1 "" "$repo")
write_task_commits "$state_dir" "$(git -C "$repo" rev-parse HEAD)"
touch_completion_intent "$state_dir"
fake_plugin="$TEST_DIR/fake-plugin-fail"
make_fake_review_gate "$fake_plugin"
wait_json='{"status":"complete","consensus_verdict":"NEEDS_WORK","aggregated_findings":[{"priority":"P1","file_path":"hello.txt","line_start":1,"body":"broken behavior"}]}'
set +e
output=$(printf '{"hook_event_name":"TaskCompleted","task_subject":"%s","cwd":"%s","session_id":"test-session","transcript_path":"%s/transcript.jsonl"}' \
    "[CERBERUS-IMPL/abc123] T001 - test" "$repo" "$TEST_DIR" \
    | TMPDIR="$TMP_ROOT" CLAUDE_PLUGIN_ROOT="$fake_plugin" FAKE_WAIT_JSON="$wait_json" FAKE_WAIT_RC=1 "$HOOK" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
if [[ "$status" -ne 2 || "$round" != "1" || ! -f "$state_dir/exhausted" || "$output" != *"hello.txt:1 - broken behavior"* ]]; then
    log_fail "expected blocking review to fail with formatted finding and exhausted marker, status=$status round=$round output=$output"
fi
assert_no_claimed_intent "$state_dir"
log_pass "blocking review fails with useful feedback"
