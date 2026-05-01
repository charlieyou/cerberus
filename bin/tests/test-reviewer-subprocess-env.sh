#!/usr/bin/env bash

set -euo pipefail

unset CERBERUS_HOST CERBERUS_RUN_KEY CERBERUS_STATE_ROOT CERBERUS_PROJECT_KEY \
      CERBERUS_SESSION_ID CERBERUS_TRANSCRIPT_PATH CERBERUS_ROOT \
      CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH CLAUDE_PROJECT_DIR \
      REVIEW_GATE_SESSION_KEY REVIEW_GATE_TRANSCRIPT_PATH \
      REVIEW_GATE_SESSION_SOURCE REVIEW_GATE_SESSION_ID \
      CERBERUS_REVIEWER_SUBPROCESS REVIEW_GATE_REVIEWER_SUBPROCESS 2>/dev/null || true

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
    echo "jq not available; skipping reviewer subprocess env test" >&2
    exit 0
fi

TEST_DIR=$(mktemp -d)
export HOME="$TEST_DIR/home"
mkdir -p "$HOME"

PARENT_PROJECT_KEY="reviewer-subprocess-proj"
PARENT_RUN_KEY="reviewer-subprocess-parent"
PARENT_REVIEW_DIR="$HOME/.cerberus/projects/$PARENT_PROJECT_KEY/$PARENT_RUN_KEY"
PARENT_TRANSCRIPT="$TEST_DIR/parent-transcript.jsonl"
CHILD_TRANSCRIPT="$TEST_DIR/child-transcript.jsonl"

mkdir -p "$PARENT_REVIEW_DIR/reviews"
touch "$PARENT_TRANSCRIPT" "$CHILD_TRANSCRIPT"

cat > "$PARENT_REVIEW_DIR/gate-state.json" <<EOF
{
  "version": 1,
  "status": "pending",
  "trigger_source": "test",
  "artifact": {"path": "$PARENT_REVIEW_DIR/latest.md", "sha256": ""},
  "reviewers": {"claude": {}},
  "consensus": null,
  "decision": null,
  "owner": {"session_key": "$PARENT_RUN_KEY"},
  "created_at": "2026-05-01T00:00:00Z",
  "iteration": 0
}
EOF

log_test "review-gate check bypasses parent gate inside reviewer subprocesses"

bypass_stdout="$TEST_DIR/bypass.out"
bypass_stderr="$TEST_DIR/bypass.err"
set +e
(
    export HOME
    export CERBERUS_HOST="generic"
    export CERBERUS_PROJECT_KEY="$PARENT_PROJECT_KEY"
    export CERBERUS_RUN_KEY="$PARENT_RUN_KEY"
    export REVIEW_GATE_SESSION_KEY="$PARENT_RUN_KEY"
    export CERBERUS_REVIEWER_SUBPROCESS=1
    export REVIEW_GATE_MAX_WAIT_SECONDS=0
    export REVIEW_GATE_POLL_INTERVAL_SECONDS=1
    printf '{"session_id":"child-session","transcript_path":"%s"}' "$CHILD_TRANSCRIPT" \
        | "$REVIEW_GATE" check
) >"$bypass_stdout" 2>"$bypass_stderr"
bypass_rc=$?
set -e

if [[ "$bypass_rc" -ne 0 ]]; then
    log_fail "expected bypassed check to exit 0, got $bypass_rc\nstdout:\n$(cat "$bypass_stdout")\nstderr:\n$(cat "$bypass_stderr")"
fi

if [[ -s "$bypass_stdout" ]]; then
    bypass_decision=$(jq -r '.decision // empty' "$bypass_stdout" 2>/dev/null || echo "")
    if [[ "$bypass_decision" != "allow" ]]; then
        log_fail "expected bypassed check to emit no output or allow JSON, got:\n$(cat "$bypass_stdout")"
    fi
fi

if ! grep -q 'reviewer subprocess Stop hook; allowing' "$bypass_stderr"; then
    log_fail "expected bypass log line, got stderr:\n$(cat "$bypass_stderr")"
fi

log_pass "reviewer subprocess marker bypasses Stop-hook enforcement"

log_test "spawn_reviewer marks reviewer subprocesses and scrubs parent gate env"

FAKE_BIN="$TEST_DIR/bin"
REVIEWS_DIR="$TEST_DIR/reviews"
PROMPT_FILE="$TEST_DIR/review.prompt"
SCHEMA_FILE="$TEST_DIR/review-schema.json"
ENV_CAPTURE="$TEST_DIR/claude.env"
CHECK_STDOUT="$TEST_DIR/claude-check.out"
CHECK_STDERR="$TEST_DIR/claude-check.err"

mkdir -p "$FAKE_BIN" "$REVIEWS_DIR"

cat > "$PROMPT_FILE" <<'EOF'
review prompt
EOF

cat > "$SCHEMA_FILE" <<'EOF'
{"type":"object"}
EOF

cat > "$FAKE_BIN/claude" <<EOF
#!$RUNNER_BASH
set -euo pipefail
{
    for var in \
        CERBERUS_REVIEWER_SUBPROCESS \
        REVIEW_GATE_REVIEWER_SUBPROCESS \
        CERBERUS_RUN_KEY \
        REVIEW_GATE_SESSION_KEY \
        REVIEW_GATE_SESSION_SOURCE \
        CERBERUS_SESSION_ID \
        CLAUDE_SESSION_ID \
        REVIEW_GATE_SESSION_ID \
        CERBERUS_TRANSCRIPT_PATH \
        CLAUDE_TRANSCRIPT_PATH \
        REVIEW_GATE_TRANSCRIPT_PATH; do
        if [[ \${!var+x} ]]; then
            value="\${!var}"
        else
            value="__UNSET__"
        fi
        printf '%s=%s\n' "\$var" "\$value"
    done
} > "$ENV_CAPTURE"

cat >/dev/null

set +e
printf '{"session_id":"fake-claude-child","transcript_path":"%s"}' "$CHILD_TRANSCRIPT" \
    | REVIEW_GATE_MAX_WAIT_SECONDS=0 REVIEW_GATE_POLL_INTERVAL_SECONDS=1 "$REVIEW_GATE" check \
        > "$CHECK_STDOUT" 2> "$CHECK_STDERR"
check_rc=\$?
set -e
if [[ "\$check_rc" -ne 0 ]]; then
    exit "\$check_rc"
fi
if [[ -s "$CHECK_STDOUT" ]]; then
    decision=\$(jq -r '.decision // empty' "$CHECK_STDOUT" 2>/dev/null || true)
    if [[ "\$decision" == "block" ]]; then
        exit 42
    fi
fi

printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"{\\"verdict\\":\\"PASS\\",\\"summary\\":\\"reviewer subprocess ok\\",\\"findings\\":[]}"}'
EOF

chmod +x "$FAKE_BIN/claude"

env \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    HOME="$HOME" \
    PLUGIN_ROOT="$PLUGIN_ROOT" \
    REVIEWS_DIR="$REVIEWS_DIR" \
    PROMPT_FILE="$PROMPT_FILE" \
    SCHEMA_FILE="$SCHEMA_FILE" \
    CODEX_MODEL="" \
    GEMINI_MODEL="" \
    CLAUDE_MODEL="" \
    CERBERUS_HOST="generic" \
    CERBERUS_PROJECT_KEY="$PARENT_PROJECT_KEY" \
    CERBERUS_RUN_KEY="$PARENT_RUN_KEY" \
    REVIEW_GATE_SESSION_KEY="$PARENT_RUN_KEY" \
    REVIEW_GATE_SESSION_SOURCE="test-parent" \
    CERBERUS_SESSION_ID="parent-cerberus-session" \
    CLAUDE_SESSION_ID="parent-claude-session" \
    REVIEW_GATE_SESSION_ID="parent-review-gate-session" \
    CERBERUS_TRANSCRIPT_PATH="$PARENT_TRANSCRIPT" \
    CLAUDE_TRANSCRIPT_PATH="$PARENT_TRANSCRIPT" \
    REVIEW_GATE_TRANSCRIPT_PATH="$PARENT_TRANSCRIPT" \
    "$RUNNER_BASH" -c '
        source "$PLUGIN_ROOT/bin/review-gate-models.sh"
        spawn_reviewer claude claude "$PROMPT_FILE" "$SCHEMA_FILE"
    '

for ((i = 0; i < 50; i++)); do
    if [[ -f "$REVIEWS_DIR/claude.done" || -f "$REVIEWS_DIR/claude.failed" ]]; then
        break
    fi
    sleep 0.1
done

if [[ ! -f "$REVIEWS_DIR/claude.done" ]]; then
    log_fail "expected claude.done; failed=$(test -f "$REVIEWS_DIR/claude.failed" && echo yes || echo no)\ncheck stdout:\n$(cat "$CHECK_STDOUT" 2>/dev/null || true)\ncheck stderr:\n$(cat "$CHECK_STDERR" 2>/dev/null || true)\nreview output:\n$(cat "$REVIEWS_DIR/claude.json" 2>/dev/null || true)"
fi

if [[ -f "$REVIEWS_DIR/claude.failed" ]]; then
    log_fail "did not expect claude.failed when fake claude emitted valid JSON"
fi

capture_env_value() {
    local key="$1"
    sed -n "s/^${key}=//p" "$ENV_CAPTURE" | head -1
}

if [[ "$(capture_env_value CERBERUS_REVIEWER_SUBPROCESS)" != "1" ]]; then
    log_fail "CERBERUS_REVIEWER_SUBPROCESS was not exported to fake claude; env:\n$(cat "$ENV_CAPTURE")"
fi

if [[ "$(capture_env_value REVIEW_GATE_REVIEWER_SUBPROCESS)" != "1" ]]; then
    log_fail "REVIEW_GATE_REVIEWER_SUBPROCESS was not exported to fake claude; env:\n$(cat "$ENV_CAPTURE")"
fi

for scrubbed in \
    CERBERUS_RUN_KEY \
    REVIEW_GATE_SESSION_KEY \
    REVIEW_GATE_SESSION_SOURCE \
    CERBERUS_SESSION_ID \
    CLAUDE_SESSION_ID \
    REVIEW_GATE_SESSION_ID \
    CERBERUS_TRANSCRIPT_PATH \
    CLAUDE_TRANSCRIPT_PATH \
    REVIEW_GATE_TRANSCRIPT_PATH; do
    if [[ "$(capture_env_value "$scrubbed")" != "__UNSET__" ]]; then
        log_fail "expected $scrubbed to be scrubbed before fake claude; env:\n$(cat "$ENV_CAPTURE")"
    fi
done

if [[ -s "$CHECK_STDOUT" ]]; then
    check_decision=$(jq -r '.decision // empty' "$CHECK_STDOUT" 2>/dev/null || echo "")
    if [[ "$check_decision" == "block" ]]; then
        log_fail "fake claude's nested check blocked instead of bypassing:\n$(cat "$CHECK_STDOUT")\nstderr:\n$(cat "$CHECK_STDERR")"
    fi
fi

log_pass "spawn_reviewer marks child reviewers, scrubs parent env, and nested check does not fail the reviewer"
