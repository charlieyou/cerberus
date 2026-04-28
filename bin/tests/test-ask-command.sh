#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_GATE="$SCRIPT_DIR/../review-gate"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TEST_DIR=""
PASS_COUNT=0
FAIL_COUNT=0

log_test() { echo -e "${YELLOW}TEST:${NC} $1"; }
log_pass() { echo -e "${GREEN}PASS:${NC} $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
log_fail() { echo -e "${RED}FAIL:${NC} $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

cleanup() {
    if [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

TEST_DIR=$(mktemp -d -t test-ask-command.XXXXXX)
export HOME="$TEST_DIR/home"
mkdir -p "$HOME"

SESSION_ID="test-ask-command"
TRANSCRIPT_PATH="$HOME/.claude/projects/-tmp-ask-test/${SESSION_ID}.jsonl"
REVIEW_DIR="$HOME/.claude/projects/-tmp-ask-test/cerberus/${SESSION_ID}"
PROMPT_FILE="$TEST_DIR/prompt.md"
CONTEXT_FILE="$TEST_DIR/context.md"

mkdir -p "$(dirname "$TRANSCRIPT_PATH")"
touch "$TRANSCRIPT_PATH"

cat > "$PROMPT_FILE" <<'PROMPT'
Should we ship this migration plan?
Preserve this literal placeholder-looking line in the prompt body:
${CONFIDENCE_ANCHORS}
PROMPT

cat > "$CONTEXT_FILE" <<'CONTEXT'
The migration has a two-week rollback window.
CONTEXT

assert_contains() {
    local label="$1"
    local file="$2"
    local expected="$3"
    log_test "$label"
    if grep -F "$expected" "$file" >/dev/null 2>&1; then
        log_pass "$label"
    else
        log_fail "$label: expected '$expected' in $file"
    fi
}

assert_not_contains() {
    local label="$1"
    local file="$2"
    local unexpected="$3"
    log_test "$label"
    if grep -F "$unexpected" "$file" >/dev/null 2>&1; then
        log_fail "$label: did not expect '$unexpected' in $file"
    else
        log_pass "$label"
    fi
}

wait_for_file() {
    local file="$1"
    local attempts=30
    while [[ $attempts -gt 0 ]]; do
        [[ -f "$file" ]] && return 0
        sleep 1
        attempts=$((attempts - 1))
    done
    return 1
}

log_test "spawn-ask --artifact-only writes ask artifact and debate-aware prompt"
if "$REVIEW_GATE" spawn-ask \
        --artifact-only \
        --session-id "$SESSION_ID" \
        --transcript-path "$TRANSCRIPT_PATH" \
        --mode fast \
        --agents codex,gemini \
        --max-rounds 0 \
        --debate \
        --prompt-file "$PROMPT_FILE" \
        --context-file "$CONTEXT_FILE" >/dev/null 2>&1; then
    log_pass "spawn-ask --artifact-only completed"
else
    log_fail "spawn-ask --artifact-only failed"
fi

ARTIFACT="$REVIEW_DIR/latest.md"
RENDERED_PROMPT="$REVIEW_DIR/reviews/review.prompt"

if [[ -f "$ARTIFACT" && -f "$RENDERED_PROMPT" ]]; then
    log_pass "artifact and rendered prompt exist"
else
    log_fail "missing artifact or rendered prompt under $REVIEW_DIR"
fi

assert_contains "artifact marks review type ask" "$ARTIFACT" "<!-- review-type: ask -->"
assert_contains "artifact includes arbitrary prompt text" "$ARTIFACT" "Should we ship this migration plan?"
assert_contains "artifact preserves placeholder-looking prompt bytes" "$ARTIFACT" '${CONFIDENCE_ANCHORS}'
assert_contains "rendered prompt includes arbitrary prompt text" "$RENDERED_PROMPT" "Should we ship this migration plan?"
assert_contains "rendered prompt preserves placeholder-looking prompt bytes" "$RENDERED_PROMPT" '${CONFIDENCE_ANCHORS}'
assert_contains "rendered prompt includes context file" "$RENDERED_PROMPT" "two-week rollback window"
assert_contains "rendered prompt includes debate output shape" "$RENDERED_PROMPT" "overall_confidence"
assert_contains "rendered prompt includes default strategy directive" "$RENDERED_PROMPT" "Strategy: verification-first."

log_test "spawn-ask rerun preserves raw prompt and context through stop-hook respawn"
FAKE_BIN="$TEST_DIR/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<'CODEX'
#!/usr/bin/env bash
if [[ "${1:-}" == "exec" && "${2:-}" == "--help" ]]; then
    exit 0
fi
out_file=""
prev=""
for arg in "$@"; do
    if [[ "$prev" == "-o" ]]; then
        out_file="$arg"
    fi
    prev="$arg"
done
if [[ -n "$out_file" ]]; then
    cat > "$out_file" <<'JSON'
{"verdict":"NEEDS_WORK","summary":"Needs one clarification.","findings":[{"title":"[P2] Clarify rollout owner","body":"The rollout owner is not specified.","priority":2,"file_path":null,"line_start":null,"line_end":null}]}
JSON
fi
printf '{"type":"thread.started","id":"ask-rerun-fixture"}\n'
printf '{"type":"turn.completed","id":"ask-rerun-turn","usage":{"input_tokens":10,"output_tokens":5}}\n'
exit 0
CODEX
chmod +x "$FAKE_BIN/codex"

RERUN_SESSION_ID="test-ask-rerun"
RERUN_TRANSCRIPT_PATH="$HOME/.claude/projects/-tmp-ask-rerun/${RERUN_SESSION_ID}.jsonl"
RERUN_REVIEW_DIR="$HOME/.claude/projects/-tmp-ask-rerun/cerberus/${RERUN_SESSION_ID}"
RERUN_PROMPT_FILE="$TEST_DIR/rerun-prompt.md"
RERUN_CONTEXT_FILE="$TEST_DIR/rerun-context.md"
mkdir -p "$(dirname "$RERUN_TRANSCRIPT_PATH")"
touch "$RERUN_TRANSCRIPT_PATH"
cat > "$RERUN_PROMPT_FILE" <<'PROMPT'
Should we ship the rerun migration?
```sql
select 1;
```
- Nested block:
  ```sh
  echo hi
  ```
PROMPT
cat > "$RERUN_CONTEXT_FILE" <<'CONTEXT'
Rerun context must survive the stop-hook respawn.
```text
rollback checklist
```
- Nested context block:
  ```text
  nested rollback note
  ```
CONTEXT

if PATH="$FAKE_BIN:$PATH" "$REVIEW_GATE" spawn-ask \
        --session-id "$RERUN_SESSION_ID" \
        --transcript-path "$RERUN_TRANSCRIPT_PATH" \
        --agents codex \
        --max-rounds 1 \
        --prompt-file "$RERUN_PROMPT_FILE" \
        --context-file "$RERUN_CONTEXT_FILE" >/dev/null 2>&1 && \
   wait_for_file "$RERUN_REVIEW_DIR/reviews/codex.done"; then
    log_pass "spawn-ask initial rerun fixture completed"
else
    log_fail "spawn-ask initial rerun fixture failed"
fi

state_prompt=$(jq -r '.mode.ask_prompt // empty' "$RERUN_REVIEW_DIR/gate-state.json" 2>/dev/null || echo "")
state_context=$(jq -r '.mode.ask_context // empty' "$RERUN_REVIEW_DIR/gate-state.json" 2>/dev/null || echo "")
if [[ "$state_prompt" == *"Should we ship the rerun migration?"* && "$state_prompt" == *"select 1;"* && "$state_prompt" == *"echo hi"* ]] && \
   [[ "$state_context" == *"Rerun context must survive the stop-hook respawn."* && "$state_context" == *"rollback checklist"* && "$state_context" == *"nested rollback note"* ]]; then
    log_pass "gate state stores raw ask prompt and context"
else
    log_fail "gate state did not store raw ask prompt/context"
fi
assert_contains "ask artifact expands fence for fenced prompt" "$RERUN_REVIEW_DIR/latest.md" '````text'

check_payload=$(printf '{"session_id":"%s","transcript_path":"%s"}' "$RERUN_SESSION_ID" "$RERUN_TRANSCRIPT_PATH")
set +e
PATH="$FAKE_BIN:$PATH" "$REVIEW_GATE" check >/dev/null 2>&1 <<< "$check_payload"
set -e
tmp_state="$RERUN_REVIEW_DIR/gate-state.json.tmp"
jq 'del(.mode.ask_prompt, .mode.ask_context)' "$RERUN_REVIEW_DIR/gate-state.json" > "$tmp_state"
mv "$tmp_state" "$RERUN_REVIEW_DIR/gate-state.json"
set +e
PATH="$FAKE_BIN:$PATH" "$REVIEW_GATE" check >/dev/null 2>&1 <<< "$check_payload"
set -e

RERUN_RENDERED_PROMPT="$RERUN_REVIEW_DIR/reviews/review.prompt"
if wait_for_file "$RERUN_RENDERED_PROMPT"; then
    log_pass "stop-hook ask respawn rendered prompt"
else
    log_fail "stop-hook ask respawn did not render prompt"
fi
assert_contains "respawned ask prompt preserves original prompt" "$RERUN_RENDERED_PROMPT" "Should we ship the rerun migration?"
assert_contains "respawned ask prompt preserves fenced prompt body" "$RERUN_RENDERED_PROMPT" "select 1;"
assert_contains "respawned ask prompt preserves indented fenced prompt body" "$RERUN_RENDERED_PROMPT" "echo hi"
assert_contains "respawned ask prompt preserves original context" "$RERUN_RENDERED_PROMPT" "Rerun context must survive the stop-hook respawn."
assert_contains "respawned ask prompt preserves fenced context body" "$RERUN_RENDERED_PROMPT" "rollback checklist"
assert_contains "respawned ask prompt preserves indented fenced context body" "$RERUN_RENDERED_PROMPT" "nested rollback note"
assert_not_contains "respawned ask prompt does not use artifact wrapper as prompt" "$RERUN_RENDERED_PROMPT" "<!-- review-type: ask -->"

echo ""
echo "Ask command tests: $PASS_COUNT passed, $FAIL_COUNT failed."
if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
