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
NOHUP_PID_FILE="$TEST_DIR/nohup.pid"
GEMINI_ARGS_FILE="$TEST_DIR/gemini.args"
GEMINI_SETTINGS_FILE="$TEST_DIR/gemini-settings.path"
GEMINI_POLICY_FILE="$TEST_DIR/gemini-policy.path"
TOUCH_BIN="$(command -v touch)"
MKDIR_BIN="$(command -v mkdir)"
SLEEP_BIN="$(command -v sleep)"
CAT_BIN="$(command -v cat)"
GREP_BIN="$(command -v grep)"

mkdir -p "$FAKE_BIN" "$REVIEWS_DIR"

cat > "$FAKE_BIN/nohup" <<EOF
#!$RUNNER_BASH
echo "\$\$" > "$NOHUP_PID_FILE"
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

cat > "$FAKE_BIN/gemini" <<EOF
#!$RUNNER_BASH
printf '%s\n' "\$*" > "$GEMINI_ARGS_FILE"
printf '%s\n' "\${GEMINI_CLI_SYSTEM_SETTINGS_PATH:-}" > "$GEMINI_SETTINGS_FILE"

policy_path=""
admin_policy_path=""
prev=""
for arg in "\$@"; do
    if [[ "\$prev" == "--policy" ]]; then
        policy_path="\$arg"
        prev=""
        continue
    fi
    if [[ "\$prev" == "--admin-policy" ]]; then
        admin_policy_path="\$arg"
        prev=""
        continue
    fi
    prev="\$arg"
done
printf '%s\n' "\$policy_path" > "$GEMINI_POLICY_FILE"

case " \$* " in
    *" --approval-mode plan "*) ;;
    *) echo "missing --approval-mode plan" >&2; exit 11 ;;
esac
case " \$* " in
    *" --skip-trust "*) ;;
    *) echo "missing --skip-trust" >&2; exit 12 ;;
esac
case " \$* " in
    *" --policy "*) ;;
    *) echo "missing --policy" >&2; exit 13 ;;
esac
case " \$* " in
    *" --admin-policy "*) ;;
    *) echo "missing --admin-policy" >&2; exit 14 ;;
esac

if [[ -z "\${GEMINI_CLI_SYSTEM_SETTINGS_PATH:-}" || ! -f "\$GEMINI_CLI_SYSTEM_SETTINGS_PATH" ]]; then
    echo "missing settings file" >&2
    exit 15
fi
if "$GREP_BIN" -Eq '"tools"|"allowed"|"core"|"exclude"' "\$GEMINI_CLI_SYSTEM_SETTINGS_PATH"; then
    echo "settings file still uses deprecated tool allow/exclude keys" >&2
    exit 16
fi
if [[ -z "\$policy_path" || ! -f "\$policy_path" ]]; then
    echo "missing policy file" >&2
    exit 17
fi
if [[ "\$admin_policy_path" != "\$policy_path" ]]; then
    echo "admin policy path did not match policy path" >&2
    exit 18
fi
if ! "$GREP_BIN" -q 'read_many_files' "\$policy_path"; then
    echo "policy does not allow read_many_files" >&2
    exit 19
fi
if ! "$GREP_BIN" -q 'decision = "deny"' "\$policy_path"; then
    echo "policy does not deny non-read tools" >&2
    exit 20
fi

printf '%s' '{"verdict":"PASS","summary":"ok","findings":[]}'
EOF

chmod +x "$FAKE_BIN/nohup" "$FAKE_BIN/mkdir" "$FAKE_BIN/touch" "$FAKE_BIN/gemini"

cat > "$PROMPT_FILE" <<'EOF'
review prompt
EOF

cat > "$SCHEMA_FILE" <<'EOF'
{"type":"object"}
EOF

export PLUGIN_ROOT
export REVIEWS_DIR
export GEMINI_MODEL=""
export CODEX_MODEL=""
export CLAUDE_MODEL=""

log_test "spawn_reviewer invokes gemini with Policy Engine read-only controls"

env \
    PATH="$FAKE_BIN" \
    PLUGIN_ROOT="$PLUGIN_ROOT" \
    REVIEWS_DIR="$REVIEWS_DIR" \
    GEMINI_MODEL="$GEMINI_MODEL" \
    CODEX_MODEL="$CODEX_MODEL" \
    CLAUDE_MODEL="$CLAUDE_MODEL" \
    PROMPT_FILE="$PROMPT_FILE" \
    SCHEMA_FILE="$SCHEMA_FILE" \
    "$RUNNER_BASH" -c '
        source "$PLUGIN_ROOT/bin/review-gate-models.sh"
        spawn_reviewer gemini gemini "$PROMPT_FILE" "$SCHEMA_FILE"
    '

for ((i = 0; i < 40; i++)); do
    if [[ -f "$REVIEWS_DIR/gemini.done" || -f "$REVIEWS_DIR/gemini.failed" ]]; then
        break
    fi
    "$SLEEP_BIN" 0.1
done

if [[ -f "$REVIEWS_DIR/gemini.failed" ]]; then
    output=$(
        if [[ -f "$REVIEWS_DIR/gemini.json" ]]; then
            "$CAT_BIN" "$REVIEWS_DIR/gemini.json"
        fi
    )
    log_fail "gemini reviewer failed; output: $output"
fi

if [[ ! -f "$REVIEWS_DIR/gemini.done" ]]; then
    log_fail "expected gemini.done to be created"
fi

if [[ ! -f "$GEMINI_ARGS_FILE" ]]; then
    log_fail "expected fake gemini to record its arguments"
fi

gemini_args=$("$CAT_BIN" "$GEMINI_ARGS_FILE")
if [[ "$gemini_args" == *"--allowed-tools"* ]]; then
    log_fail "gemini should not receive deprecated --allowed-tools, got: $gemini_args"
fi

settings_path=$("$CAT_BIN" "$GEMINI_SETTINGS_FILE")
if [[ "$settings_path" != "$PLUGIN_ROOT/config/gemini-readonly-settings.json" ]]; then
    log_fail "expected system settings path to point at Cerberus config, got: $settings_path"
fi

policy_path=$("$CAT_BIN" "$GEMINI_POLICY_FILE")
if [[ "$policy_path" != "$PLUGIN_ROOT/config/gemini-readonly-policy.toml" ]]; then
    log_fail "expected policy path to point at Cerberus policy, got: $policy_path"
fi

output=$("$CAT_BIN" "$REVIEWS_DIR/gemini.json")
if [[ "$output" != *'"verdict":"PASS"'* ]]; then
    log_fail "expected reviewer verdict to be written to gemini.json, got: $output"
fi

log_pass "gemini reviewer uses policy-based read-only invocation"
