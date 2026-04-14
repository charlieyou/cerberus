#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_GATE="$SCRIPT_DIR/../review-gate"

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
ARTIFACT_PATH="$TEST_DIR/artifact.md"
TRANSCRIPT_PATH="$TEST_DIR/transcript.jsonl"

cat > "$ARTIFACT_PATH" <<'EOF'
# Artifact
EOF

touch "$TRANSCRIPT_PATH"

log_test "system bash can parse --agents without associative-array support"

set +e
output=$(
    /bin/bash "$REVIEW_GATE" spawn \
        --session-id test-bash3-session \
        --transcript-path "$TRANSCRIPT_PATH" \
        --agents codex,codex,bad \
        "$ARTIFACT_PATH" 2>&1
)
status=$?
set -e

if [[ "$status" -ne 2 ]]; then
    log_fail "expected exit code 2, got $status\n$output"
fi

if [[ "$output" == *"local: -A: invalid option"* ]]; then
    log_fail "bash 3.2 still hit associative-array parsing\n$output"
fi

if [[ "$output" != *"Unknown agent 'bad'. Valid: codex, gemini, claude"* ]]; then
    log_fail "unexpected output\n$output"
fi

log_pass "system bash reaches agent validation without crashing"
