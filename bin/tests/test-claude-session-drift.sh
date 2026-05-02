#!/usr/bin/env bash

set -euo pipefail

unset CERBERUS_HOST CERBERUS_RUN_KEY CERBERUS_STATE_ROOT CERBERUS_PROJECT_KEY \
      CERBERUS_SESSION_ID CERBERUS_TRANSCRIPT_PATH CERBERUS_ROOT \
      CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH CLAUDE_PROJECT_DIR \
      REVIEW_GATE_SESSION_KEY REVIEW_GATE_TRANSCRIPT_PATH \
      REVIEW_GATE_SESSION_SOURCE REVIEW_GATE_SESSION_ID 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REVIEW_GATE="$PLUGIN_ROOT/bin/review-gate"
RUNNER_BASH="${BASH:-/bin/bash}"

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

if ! command -v jq >/dev/null 2>&1; then
    echo "jq not available; skipping Claude session drift test" >&2
    exit 0
fi

TEST_DIR=$(mktemp -d -t cerberus-claude-session-drift.XXXXXX)
export HOME="$TEST_DIR/home"
mkdir -p "$HOME"

FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/codex" <<EOF
#!$RUNNER_BASH
set -euo pipefail
if [[ "\${1:-}" == "exec" && "\${2:-}" == "--help" ]]; then
    printf '%s\n' '--ephemeral'
    exit 0
fi
out_file=""
prev=""
for arg in "\$@"; do
    if [[ "\$prev" == "-o" || "\$prev" == "--output-last-message" ]]; then
        out_file="\$arg"
        prev=""
        continue
    fi
    prev="\$arg"
done
cat >/dev/null || true
if [[ -n "\$out_file" ]]; then
    printf '%s' '{"verdict":"PASS","summary":"ok","findings":[]}' > "\$out_file"
fi
printf '{"type":"thread.started","thread_id":"drift-fixture"}\n'
printf '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}\n'
exit 0
EOF
chmod +x "$FAKE_BIN/codex"

PROJECT_KEY="-tmp-claude-session-drift"
PLAN_PATH="$TEST_DIR/plan.md"
cat > "$PLAN_PATH" <<'EOF'
# Plan

Ship the smallest safe change.
EOF

run_spawn_plan_review() {
    local stale_session="$1"
    local transcript_session="$2"
    local out_file="$3"
    local err_file="$4"
    local transcript_path="$HOME/.claude/projects/$PROJECT_KEY/${transcript_session}.jsonl"

    mkdir -p "$(dirname "$transcript_path")"
    : > "$transcript_path"

    env \
        HOME="$HOME" \
        PATH="$FAKE_BIN:$PATH" \
        CLAUDE_SESSION_ID="$stale_session" \
        CLAUDE_TRANSCRIPT_PATH="$transcript_path" \
        REVIEW_GATE_REVIEWER_TIMEOUT=5 \
        "$REVIEW_GATE" spawn-plan-review \
            --mode fast \
            --max-rounds 0 \
            --agents codex \
            "$PLAN_PATH" >"$out_file" 2>"$err_file"
}

run_spawn_plan_review_with_explicit_session() {
    local explicit_session="$1"
    local stale_session="$2"
    local transcript_session="$3"
    local out_file="$4"
    local err_file="$5"
    local transcript_path="$HOME/.claude/projects/$PROJECT_KEY/${transcript_session}.jsonl"

    mkdir -p "$(dirname "$transcript_path")"
    : > "$transcript_path"

    env \
        HOME="$HOME" \
        PATH="$FAKE_BIN:$PATH" \
        CERBERUS_SESSION_ID="$explicit_session" \
        CLAUDE_SESSION_ID="$stale_session" \
        CLAUDE_TRANSCRIPT_PATH="$transcript_path" \
        REVIEW_GATE_REVIEWER_TIMEOUT=5 \
        "$REVIEW_GATE" spawn-plan-review \
            --mode fast \
            --max-rounds 0 \
            --agents codex \
            "$PLAN_PATH" >"$out_file" 2>"$err_file"
}

assert_spawn_used_session() {
    local label="$1"
    local expected_session="$2"
    local unexpected_session="$3"
    local expected_transcript_session="${4:-$expected_session}"
    local current_dir="$HOME/.claude/projects/$PROJECT_KEY/cerberus/$expected_session"
    local stale_dir="$HOME/.claude/projects/$PROJECT_KEY/cerberus/$unexpected_session"

    if [[ ! -f "$current_dir/latest.md" ]]; then
        log_fail "$label: expected artifact under $current_dir"
    fi
    if [[ ! -f "$current_dir/gate-state.json" ]]; then
        log_fail "$label: expected gate-state.json under $current_dir"
    fi
    if [[ -e "$stale_dir/latest.md" || -e "$stale_dir/gate-state.json" ]]; then
        log_fail "$label: found state under stale session dir $stale_dir"
    fi

    local owner_session owner_transcript
    owner_session=$(jq -r '.owner.session_id // empty' "$current_dir/gate-state.json")
    owner_transcript=$(jq -r '.owner.transcript_path // empty' "$current_dir/gate-state.json")
    if [[ "$owner_session" != "$expected_session" ]]; then
        log_fail "$label: owner.session_id='$owner_session', expected '$expected_session'"
    fi
    if [[ "$(basename "$owner_transcript")" != "${expected_transcript_session}.jsonl" ]]; then
        log_fail "$label: owner.transcript_path='$owner_transcript' does not point at expected transcript"
    fi
}

log_test "spawn-plan-review prefers current transcript session over stale CLAUDE_SESSION_ID"
MISMATCH_OUT="$TEST_DIR/mismatch.out"
MISMATCH_ERR="$TEST_DIR/mismatch.err"
if run_spawn_plan_review "stale-claude-session" "current-transcript-session" "$MISMATCH_OUT" "$MISMATCH_ERR"; then
    assert_spawn_used_session "mismatched Claude env" "current-transcript-session" "stale-claude-session"
    if ! grep -q 'SESSION_ID disagrees with transcript basename' "$MISMATCH_ERR"; then
        log_fail "mismatched Claude env: expected drift warning, stderr:\n$(cat "$MISMATCH_ERR")"
    fi
    log_pass "mismatched Claude env writes state under transcript session"
else
    log_fail "spawn-plan-review failed for mismatched Claude env\nstdout:\n$(cat "$MISMATCH_OUT")\nstderr:\n$(cat "$MISMATCH_ERR")"
fi

log_test "spawn-plan-review keeps matching Claude session behavior"
MATCH_OUT="$TEST_DIR/match.out"
MATCH_ERR="$TEST_DIR/match.err"
if run_spawn_plan_review "matching-session" "matching-session" "$MATCH_OUT" "$MATCH_ERR"; then
    assert_spawn_used_session "matching Claude env" "matching-session" "unused-stale-session"
    if grep -q 'SESSION_ID disagrees with transcript basename' "$MATCH_ERR"; then
        log_fail "matching Claude env: did not expect drift warning, stderr:\n$(cat "$MATCH_ERR")"
    fi
    log_pass "matching Claude env writes state under matching session"
else
    log_fail "spawn-plan-review failed for matching Claude env\nstdout:\n$(cat "$MATCH_OUT")\nstderr:\n$(cat "$MATCH_ERR")"
fi

log_test "explicit CERBERUS_SESSION_ID still overrides transcript session"
EXPLICIT_OUT="$TEST_DIR/explicit.out"
EXPLICIT_ERR="$TEST_DIR/explicit.err"
if run_spawn_plan_review_with_explicit_session "explicit-cerberus-session" "stale-for-explicit" "transcript-for-explicit" "$EXPLICIT_OUT" "$EXPLICIT_ERR"; then
    assert_spawn_used_session "explicit Cerberus session" "explicit-cerberus-session" "stale-for-explicit" "transcript-for-explicit"
    transcript_dir="$HOME/.claude/projects/$PROJECT_KEY/cerberus/transcript-for-explicit"
    if [[ -e "$transcript_dir/latest.md" || -e "$transcript_dir/gate-state.json" ]]; then
        log_fail "explicit Cerberus session: found state under transcript session dir $transcript_dir"
    fi
    log_pass "explicit CERBERUS_SESSION_ID remains authoritative"
else
    log_fail "spawn-plan-review failed for explicit Cerberus session\nstdout:\n$(cat "$EXPLICIT_OUT")\nstderr:\n$(cat "$EXPLICIT_ERR")"
fi
