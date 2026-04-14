#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_PLUGIN="$SCRIPT_DIR/../update-plugin"

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
TEST_HOME="$TEST_DIR/home"
INVALID_TEST_HOME="$TEST_DIR/home-invalid"
FAKE_BIN="$TEST_DIR/bin"
PLUGIN_VERSION="9.9.9"
RUNNER_BASH="${BASH:-/bin/bash}"
JQ_BIN="$(command -v jq)"
TOOL_PATH="$(dirname "$JQ_BIN")"

mkdir -p "$TEST_HOME/.claude/plugins/cache/cerberus/cerberus/$PLUGIN_VERSION/bin" "$TEST_HOME/.claude/plugins" "$FAKE_BIN"
mkdir -p "$INVALID_TEST_HOME/.claude/plugins" "$INVALID_TEST_HOME/.claude/plugins/cache/cerberus/cerberus"

cat > "$TEST_HOME/.claude/settings.json" <<EOF
{
  "allowlist": [
    "Bash(/tmp/keep-me:*)",
    "Bash($TEST_HOME/.claude/plugins/cache/cerberus/cerberus/1.2.3/bin/review-gate:*)"
  ]
}
EOF

cat > "$TEST_HOME/.claude/plugins/installed_plugins.json" <<EOF
{
  "plugins": {
    "cerberus@cerberus": [
      {"version": "$PLUGIN_VERSION"}
    ]
  }
}
EOF

cat > "$TEST_HOME/.claude/plugins/cache/cerberus/cerberus/$PLUGIN_VERSION/bin/review-gate" <<EOF
#!$RUNNER_BASH
exit 0
EOF

cat > "$FAKE_BIN/claude" <<EOF
#!$RUNNER_BASH
exit 0
EOF

chmod +x "$TEST_HOME/.claude/plugins/cache/cerberus/cerberus/$PLUGIN_VERSION/bin/review-gate" "$FAKE_BIN/claude"

log_test "update-plugin rewrites cerberus allowlist paths without clobbering settings"

HOME="$TEST_HOME" PATH="$FAKE_BIN:$TOOL_PATH:/usr/bin:/bin" "$UPDATE_PLUGIN" >/dev/null

if ! jq empty "$TEST_HOME/.claude/settings.json" >/dev/null 2>&1; then
    log_fail "settings.json is not valid JSON after update-plugin"
fi

if ! grep -q "$TEST_HOME/.claude/plugins/cache/cerberus/cerberus/$PLUGIN_VERSION/bin/review-gate" "$TEST_HOME/.claude/settings.json"; then
    log_fail "expected cerberus path to be rewritten to $PLUGIN_VERSION"
fi

if ! grep -q 'Bash(/tmp/keep-me:\*)' "$TEST_HOME/.claude/settings.json"; then
    log_fail "expected unrelated allowlist entry to remain unchanged"
fi

log_pass "update-plugin rewrites allowlist paths and preserves valid JSON"

cat > "$INVALID_TEST_HOME/.claude/settings.json" <<EOF
{
  "allowlist": [
    "Bash($INVALID_TEST_HOME/.claude/plugins/cache/cerberus/cerberus/1.2.3/bin/review-gate:*)"
  ]
}
EOF

cat > "$INVALID_TEST_HOME/.claude/plugins/installed_plugins.json" <<'EOF'
{invalid json
EOF

original_invalid_settings=$(cat "$INVALID_TEST_HOME/.claude/settings.json")

log_test "update-plugin leaves settings unchanged when rewritten JSON is invalid"

set +e
HOME="$INVALID_TEST_HOME" PATH="$FAKE_BIN:$TOOL_PATH:/usr/bin:/bin" "$UPDATE_PLUGIN" >/dev/null 2>&1
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
    log_fail "expected update-plugin to fail when rewrite produces invalid JSON"
fi

if [[ "$(cat "$INVALID_TEST_HOME/.claude/settings.json")" != "$original_invalid_settings" ]]; then
    log_fail "expected settings.json to remain unchanged after validation failure"
fi

log_pass "update-plugin rejects invalid rewritten JSON without overwriting settings"
