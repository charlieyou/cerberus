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
    local max_rounds="${1:-3}"
    local baseline_sha="${2:-$(git rev-parse HEAD)}"
    local state_dir="$TMP_ROOT/cerberus-task-completed-hook/abc123/T001"
    mkdir -p "$state_dir"
    printf 'context\n' > "$state_dir/task-context.md"
    jq -n \
        --arg task_id T001 \
        --arg claude_task_id task-1 \
        --arg team_hash abc123 \
        --arg baseline_sha "$baseline_sha" \
        --arg task_state_dir "$state_dir" \
        --arg task_context_path "$state_dir/task-context.md" \
        --argjson max_rounds "$max_rounds" \
        '{task_id:$task_id, claude_task_id:$claude_task_id, team_hash:$team_hash, baseline_sha:$baseline_sha, round:0, max_rounds:$max_rounds, task_state_dir:$task_state_dir, task_context_path:$task_context_path}' \
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

log_test "prefixed task with state but no completion_intent fails open"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
state_dir=$(write_state)
set +e
output=$(run_hook "[CERBERUS-IMPL/abc123] T001 - test" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
if [[ "$status" -ne 0 || "$round" != "0" || -n "$output" ]]; then
    log_fail "expected no-intent event to exit 0 without state changes, status=$status round=$round output=$output"
fi
log_pass "no-intent event ignored"

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

log_test "post-exhaustion retry clears completion instead of looping"
touch "$state_dir/completion_intent"
set +e
output=$(run_hook "[CERBERUS-IMPL/abc123] T001 - test" 2>&1)
status=$?
set -e
round=$(jq -r '.round' "$state_dir/state.json")
if [[ "$status" -ne 0 || "$round" != "1" || ! -f "$state_dir/exhausted" || -e "$state_dir/completion_intent" || -n "$output" ]]; then
    log_fail "expected exhausted retry to clear completion silently, status=$status round=$round output=$output"
fi
log_pass "post-exhaustion retry clears completion"

log_test "PASS review writes reviewed_pass and increments round"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
repo="$TEST_DIR/pass-repo"
make_review_repo "$repo"
baseline=$(cat "$repo/baseline")
state_dir=$(write_state 3 "$baseline")
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
if [[ "$status" -ne 0 || "$round" != "1" || ! -f "$state_dir/reviewed_pass" ]]; then
    log_fail "expected PASS review to allow completion, status=$status round=$round output=$output"
fi
log_pass "PASS review allows completion"

log_test "PASS on final allowed round does not mark exhausted"
rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
repo="$TEST_DIR/final-pass-repo"
make_review_repo "$repo"
baseline=$(cat "$repo/baseline")
state_dir=$(write_state 3 "$baseline")
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
state_dir=$(write_state 1 "$baseline")
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
