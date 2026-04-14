#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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
FAKE_BIN="$TEST_DIR/bin"
REVIEWS_DIR="$TEST_DIR/reviews"
PROMPT_FILE="$TEST_DIR/review.prompt"
SCHEMA_FILE="$TEST_DIR/review-schema.json"
RUNNER_BASH="${BASH:-/bin/bash}"
PATH_BASH_MARKER="$TEST_DIR/path-bash-used"
NOHUP_PID_FILE="$TEST_DIR/nohup.pid"
TOUCH_BIN="$(command -v touch)"
MKDIR_BIN="$(command -v mkdir)"
SLEEP_BIN="$(command -v sleep)"
CAT_BIN="$(command -v cat)"

mkdir -p "$FAKE_BIN" "$REVIEWS_DIR"

cat > "$FAKE_BIN/bash" <<EOF
#!$RUNNER_BASH
echo unexpected > "$PATH_BASH_MARKER"
exit 99
EOF

cat > "$FAKE_BIN/nohup" <<EOF
#!$RUNNER_BASH
echo "\$$" > "$NOHUP_PID_FILE"
exec "\$@"
EOF

cat > "$FAKE_BIN/mkdir" <<EOF
#!$RUNNER_BASH
exec "$MKDIR_BIN" "\$@"
EOF

cat > "$FAKE_BIN/touch" <<EOF
#!$RUNNER_BASH
exec "$TOUCH_BIN" "\$@"
EOF

cat > "$FAKE_BIN/codex" <<EOF
#!$RUNNER_BASH
"$SLEEP_BIN" 1
printf '{"verdict":"PASS","summary":"ok","findings":[]}'
EOF

chmod +x "$FAKE_BIN/bash" "$FAKE_BIN/nohup" "$FAKE_BIN/mkdir" "$FAKE_BIN/touch" "$FAKE_BIN/codex"

cat > "$PROMPT_FILE" <<'EOF'
review prompt
EOF

cat > "$SCHEMA_FILE" <<'EOF'
{"type":"object"}
EOF

export PLUGIN_ROOT
export REVIEWS_DIR
export CODEX_MODEL=""
export GEMINI_MODEL=""
export CLAUDE_MODEL=""

log_test "spawn_reviewer falls back when setsid is unavailable"

env \
    PATH="$FAKE_BIN" \
    PLUGIN_ROOT="$PLUGIN_ROOT" \
    REVIEWS_DIR="$REVIEWS_DIR" \
    CODEX_MODEL="$CODEX_MODEL" \
    GEMINI_MODEL="$GEMINI_MODEL" \
    CLAUDE_MODEL="$CLAUDE_MODEL" \
    PROMPT_FILE="$PROMPT_FILE" \
    SCHEMA_FILE="$SCHEMA_FILE" \
    "$RUNNER_BASH" -c '
        source "$PLUGIN_ROOT/bin/review-gate-models.sh"
        spawn_reviewer codex codex "$PROMPT_FILE" "$SCHEMA_FILE"
    '

if [[ -f "$REVIEWS_DIR/codex.done" ]]; then
    log_fail "reviewer finished before the spawning shell exited"
fi

for ((i = 0; i < 20; i++)); do
    if [[ -f "$NOHUP_PID_FILE" ]]; then
        break
    fi
    "$SLEEP_BIN" 0.1
done

if [[ ! -f "$NOHUP_PID_FILE" ]]; then
    log_fail "expected nohup wrapper to record the detached process pid"
fi

detached_pid=$("$CAT_BIN" "$NOHUP_PID_FILE")
kill -TERM "$detached_pid" 2>/dev/null || true
kill -HUP "$detached_pid" 2>/dev/null || true

for ((i = 0; i < 40; i++)); do
    if [[ -f "$REVIEWS_DIR/codex.done" ]]; then
        break
    fi
    "$SLEEP_BIN" 0.1
done

if [[ ! -f "$REVIEWS_DIR/codex.done" ]]; then
    log_fail "expected codex.done to be created without setsid even after TERM/HUP"
fi

if [[ -f "$PATH_BASH_MARKER" ]]; then
    log_fail "spawn_reviewer should use the current bash path instead of resolving bash from PATH"
fi

if [[ -f "$REVIEWS_DIR/codex.failed" ]]; then
    log_fail "did not expect codex.failed to be created"
fi

output=$("$CAT_BIN" "$REVIEWS_DIR/codex.json")
if [[ "$output" != *'"verdict":"PASS"'* ]]; then
    log_fail "expected reviewer output to be written, got: $output"
fi

log_pass "spawn_reviewer launches successfully without setsid"
