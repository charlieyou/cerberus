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
    local baseline_sha="${2:-$(git rev-parse HEAD)}"
    local repo="${3:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    local state_dir="$TMP_ROOT/cerberus-task-completed-hook/abc123/T001"
    local verify_script_path="$state_dir/verify.sh"
    mkdir -p "$state_dir"
    printf 'context\n' > "$state_dir/task-context.md"
    cat > "$verify_script_path" <<'VERIFY'
#!/usr/bin/env bash
set -euo pipefail
VERIFY
    if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$repo" status --porcelain -z | tr '\0' '\n' | awk '/^\?\? / { print substr($0, 4) }' > "$state_dir/untracked_baseline.txt"
    else
        : > "$state_dir/untracked_baseline.txt"
    fi
    jq -n \
        --arg task_id T001 \
        --arg claude_task_id task-1 \
        --arg team_hash abc123 \
        --arg baseline_sha "$baseline_sha" \
        --arg task_state_dir "$state_dir" \
        --arg task_context_path "$state_dir/task-context.md" \
        --arg verify_script_path "$verify_script_path" \
        --argjson max_rounds "$max_rounds" \
        '{task_id:$task_id, claude_task_id:$claude_task_id, team_hash:$team_hash, baseline_sha:$baseline_sha, round:0, max_rounds:$max_rounds, task_state_dir:$task_state_dir, task_context_path:$task_context_path, verify_script_path:$verify_script_path}' \
        > "$state_dir/state.json"
    printf '%s' "$state_dir"
}

make_review_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email test@example.com
    git -C "$repo" config user.name Test
    git -C "$repo" commit --allow-empty -q -m init
    git -C "$repo" rev-parse HEAD > "$repo/baseline"
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
    log_fail "expected no-intent event to block without changing round, status=$status round=$round output=$output"
fi
log_pass "no-intent event blocks completion"

log_test "completion lock contention blocks without consuming intent"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
state_dir=$(write_state)
mkdir "$TMP_ROOT/cerberus-task-completed-hook/abc123/completion.lock"
touch "$state_dir/completion_intent"
set +e
output=$(run_hook "[CERBERUS-IMPL/abc123] T001 - test" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
if [[ "$status" -ne 2 || "$round" != "0" || ! -e "$state_dir/completion_intent" || "$output" != *"another task completion gate is already running"* ]]; then
    log_fail "expected completion lock contention to block without consuming intent, status=$status round=$round output=$output"
fi
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123/completion.lock"
log_pass "completion lock contention is retryable"

log_test "state directory comparison tolerates trailing slash in TMPDIR"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
state_dir=$(write_state)
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

log_test "explicit completion without tagged commits blocks and increments round"
touch "$state_dir/completion_intent"
set +e
output=$(run_hook "[CERBERUS-IMPL/abc123] T001 - test" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
if [[ "$status" -ne 2 || "$round" != "1" || "$output" != *"No commits found tagged 'Cerberus-Task: T001'"* ]]; then
    log_fail "expected no-commit completion to block and increment round, status=$status round=$round output=$output"
fi
if [[ -e "$state_dir/completion_intent" ]]; then
    log_fail "expected completion_intent to be consumed"
fi
log_pass "missing tagged commit blocks completion"

log_test "final blocking attempt writes exhausted marker"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
state_dir=$(write_state 1)
touch "$state_dir/completion_intent"
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
touch "$state_dir/completion_intent"
set +e
output=$(run_hook "[CERBERUS-IMPL/abc123] T001 - test" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
if [[ "$status" -ne 2 || "$round" != "1" || ! -f "$state_dir/exhausted" || -e "$state_dir/completion_intent" || "$output" != *"Already exhausted"* ]]; then
    log_fail "expected exhausted retry to block without looping, status=$status round=$round output=$output"
fi
log_pass "post-exhaustion retry blocks without looping"

log_test "PASS review writes reviewed_pass and increments round"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
repo="$TEST_DIR/pass-repo"
make_review_repo "$repo"
baseline=$(cat "$repo/baseline")
state_dir=$(write_state 3 "$baseline" "$repo")
touch "$state_dir/completion_intent"
fake_plugin="$TEST_DIR/fake-plugin-pass"
make_fake_review_gate "$fake_plugin"
set +e
output=$(printf '{"hook_event_name":"TaskCompleted","task_subject":"%s","cwd":"%s","session_id":"test-session","transcript_path":"%s/transcript.jsonl"}' \
    "[CERBERUS-IMPL/abc123] T001 - test" "$repo" "$TEST_DIR" \
    | TMPDIR="$TMP_ROOT" CLAUDE_PLUGIN_ROOT="$fake_plugin" FAKE_WAIT_JSON='{"status":"complete","consensus_verdict":"PASS","aggregated_findings":[]}' "$HOOK" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
pass_sha=$(git -C "$repo" rev-parse HEAD)
accepted_commits="$TMP_ROOT/cerberus-task-completed-hook/abc123/accepted_task_commits.txt"
if [[ "$status" -ne 0 || "$round" != "1" || ! -f "$state_dir/reviewed_pass" ]] || ! awk -v sha="$pass_sha" -v task="T001" '$1 == sha && $2 == task { found=1 } END { exit found ? 0 : 1 }' "$accepted_commits"; then
    log_fail "expected PASS review to allow completion, status=$status round=$round output=$output"
fi
log_pass "PASS review allows completion"

log_test "unlaunched task commits block even when task context exists"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
repo="$TEST_DIR/unlaunched-interleaved-repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name Test
git -C "$repo" commit --allow-empty -q -m init
baseline=$(git -C "$repo" rev-parse HEAD)
printf 'one\n' > "$repo/one.txt"
git -C "$repo" add one.txt
git -C "$repo" commit -q -m "T001: add one" -m "Cerberus-Task: T001"
printf 'two\n' > "$repo/two.txt"
git -C "$repo" add two.txt
git -C "$repo" commit -q -m "T002: add two" -m "Cerberus-Task: T002"
state_dir=$(write_state 3 "$baseline" "$repo")
mkdir -p "$TMP_ROOT/cerberus-task-completed-hook/abc123/task-contexts"
printf 'context for T002\n' > "$TMP_ROOT/cerberus-task-completed-hook/abc123/task-contexts/T002.md"
touch "$state_dir/completion_intent"
set +e
output=$(run_hook "[CERBERUS-IMPL/abc123] T001 - test" "$repo" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
if [[ "$status" -ne 2 || "$round" != "1" || "$output" != *"Cerberus-Task: T002"* || "$output" != *"not launched before this commit"* ]]; then
    log_fail "expected unlaunched T002 commit to block despite context, status=$status round=$round output=$output"
fi
log_pass "unlaunched task commits are not allowed by context alone"

log_test "known interleaved task commits are allowed and only current task commits are reviewed"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
repo="$TEST_DIR/interleaved-repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name Test
git -C "$repo" commit --allow-empty -q -m init
baseline=$(git -C "$repo" rev-parse HEAD)
printf 'one\n' > "$repo/one.txt"
git -C "$repo" add one.txt
git -C "$repo" commit -q -m "T001: add one" -m "Cerberus-Task: T001"
t001_sha=$(git -C "$repo" rev-parse HEAD)
printf 'two\n' > "$repo/two.txt"
git -C "$repo" add two.txt
git -C "$repo" commit -q -m "T002: add two" -m "Cerberus-Task: T002"
t002_sha=$(git -C "$repo" rev-parse HEAD)
state_dir=$(write_state 3 "$baseline" "$repo")
mkdir -p "$TMP_ROOT/cerberus-task-completed-hook/abc123/T002"
jq -n --arg baseline_sha "$baseline" '{baseline_sha:$baseline_sha}' > "$TMP_ROOT/cerberus-task-completed-hook/abc123/T002/state.json"
touch "$state_dir/completion_intent"
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

log_test "previously accepted interleaved task commits are allowed after state cleanup"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
repo="$TEST_DIR/accepted-interleaved-repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name Test
git -C "$repo" commit --allow-empty -q -m init
baseline=$(git -C "$repo" rev-parse HEAD)
printf 'one\n' > "$repo/one.txt"
git -C "$repo" add one.txt
git -C "$repo" commit -q -m "T001: add one" -m "Cerberus-Task: T001"
t001_sha=$(git -C "$repo" rev-parse HEAD)
printf 'two\n' > "$repo/two.txt"
git -C "$repo" add two.txt
git -C "$repo" commit -q -m "T002: add two" -m "Cerberus-Task: T002"
t002_sha=$(git -C "$repo" rev-parse HEAD)
state_dir=$(write_state 3 "$baseline" "$repo")
printf '%s\t%s\n' "$t002_sha" T002 > "$TMP_ROOT/cerberus-task-completed-hook/abc123/accepted_task_commits.txt"
touch "$state_dir/completion_intent"
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
    log_fail "expected accepted T002 commit to be allowed but excluded from T001 review, status=$status review_args=$review_args output=$output"
fi
log_pass "accepted interleaved task commits remain allowed after state cleanup"

log_test "unknown interleaved task commits block completion"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
repo="$TEST_DIR/unknown-interleaved-repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name Test
git -C "$repo" commit --allow-empty -q -m init
baseline=$(git -C "$repo" rev-parse HEAD)
printf 'one\n' > "$repo/one.txt"
git -C "$repo" add one.txt
git -C "$repo" commit -q -m "T001: add one" -m "Cerberus-Task: T001"
printf 'unknown\n' > "$repo/unknown.txt"
git -C "$repo" add unknown.txt
git -C "$repo" commit -q -m "T999: add unknown" -m "Cerberus-Task: T999"
state_dir=$(write_state 3 "$baseline" "$repo")
touch "$state_dir/completion_intent"
set +e
output=$(run_hook "[CERBERUS-IMPL/abc123] T001 - test" "$repo" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
if [[ "$status" -ne 2 || "$round" != "1" || "$output" != *"Cerberus-Task: T999"* || "$output" != *"not launched before this commit"* ]]; then
    log_fail "expected unknown interleaved task commit to block, status=$status round=$round output=$output"
fi
log_pass "unknown interleaved task commits block completion"

log_test "PASS on final allowed round does not mark exhausted"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
repo="$TEST_DIR/final-pass-repo"
make_review_repo "$repo"
baseline=$(cat "$repo/baseline")
state_dir=$(write_state 3 "$baseline" "$repo")
jq '.round = 2' "$state_dir/state.json" > "$state_dir/state.json.tmp"
mv "$state_dir/state.json.tmp" "$state_dir/state.json"
touch "$state_dir/completion_intent"
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

log_test "blocking review formats findings and marks exhausted on final round"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
repo="$TEST_DIR/fail-repo"
make_review_repo "$repo"
baseline=$(cat "$repo/baseline")
state_dir=$(write_state 1 "$baseline" "$repo")
touch "$state_dir/completion_intent"
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
log_pass "blocking review fails with useful feedback"
