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
    *" --output-format json "*) ;;
    *) echo "missing --output-format json" >&2; exit 10 ;;
esac
case " \$* " in
    *" -p  "*|*" --prompt  "*) ;;
    *) echo "missing headless prompt flag" >&2; exit 12 ;;
esac
case " \$* " in
    *"--skip-trust"*|*"--skipTrust"*) echo "unsupported skip-trust flag" >&2; exit 21 ;;
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

echo "Gemini warning/preamble" >&2
printf '%s' '{"response":"{\"verdict\":\"PASS\",\"summary\":\"ok\",\"findings\":[]}","stats":{}}'
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
    PATH="$FAKE_BIN:$PATH" \
    PLUGIN_ROOT="$PLUGIN_ROOT" \
    REVIEWS_DIR="$REVIEWS_DIR" \
    GEMINI_MODEL="$GEMINI_MODEL" \
    CODEX_MODEL="$CODEX_MODEL" \
    CLAUDE_MODEL="$CLAUDE_MODEL" \
    PROMPT_FILE="$PROMPT_FILE" \
    SCHEMA_FILE="$SCHEMA_FILE" \
    "$RUNNER_BASH" -c '
        source "$PLUGIN_ROOT/bin/review-gate-lib.sh"
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

if [[ "$gemini_args" == *"--skip-trust"* || "$gemini_args" == *"--skipTrust"* ]]; then
    log_fail "gemini should not receive unsupported skip-trust flags, got: $gemini_args"
fi

settings_path=$("$CAT_BIN" "$GEMINI_SETTINGS_FILE")
if [[ "$settings_path" != "$PLUGIN_ROOT/config/gemini-readonly-settings.json" ]]; then
    log_fail "expected system settings path to point at Cerberus config, got: $settings_path"
fi

policy_path=$("$CAT_BIN" "$GEMINI_POLICY_FILE")
if [[ "$policy_path" != "$PLUGIN_ROOT/config/gemini-readonly-policy.toml" ]]; then
    log_fail "expected policy path to point at Cerberus policy, got: $policy_path"
fi

output=$(
    env \
        PATH="$FAKE_BIN:$PATH" \
        PLUGIN_ROOT="$PLUGIN_ROOT" \
        REVIEWS_DIR="$REVIEWS_DIR" \
        REVIEW_REPAIR_ENABLED="false" \
        "$RUNNER_BASH" -c '
            source "$PLUGIN_ROOT/bin/review-gate-lib.sh"
            source "$PLUGIN_ROOT/bin/review-gate-models.sh"
            extract_json "$REVIEWS_DIR/gemini.json" gemini
        '
)
if [[ "$output" != *'"verdict":"PASS"'* ]]; then
    log_fail "expected extract_json to normalize gemini wrapper output, got: $output"
fi

log_pass "gemini reviewer uses policy-based read-only invocation"

log_test "repair_review_output invokes gemini with Policy Engine read-only controls"

repair_output=$(
    env \
        PATH="$FAKE_BIN:$PATH" \
        PLUGIN_ROOT="$PLUGIN_ROOT" \
        REVIEWS_DIR="$REVIEWS_DIR" \
        REVIEW_REPAIR_PROVIDER="gemini" \
        SCHEMA_FILE="$SCHEMA_FILE" \
        "$RUNNER_BASH" -c '
            source "$PLUGIN_ROOT/bin/review-gate-lib.sh"
            source "$PLUGIN_ROOT/bin/review-gate-models.sh"
            repair_review_output "not json" "$SCHEMA_FILE" gemini unit_test
        '
)

if [[ "$repair_output" != *'"verdict":"PASS"'* ]]; then
    log_fail "expected repair_review_output to return normalized gemini JSON, got: $repair_output"
fi

gemini_args=$("$CAT_BIN" "$GEMINI_ARGS_FILE")
if [[ "$gemini_args" == *"--allowed-tools"* ]]; then
    log_fail "gemini repair should not receive deprecated --allowed-tools, got: $gemini_args"
fi
if [[ "$gemini_args" == *"--skip-trust"* || "$gemini_args" == *"--skipTrust"* ]]; then
    log_fail "gemini repair should not receive unsupported skip-trust flags, got: $gemini_args"
fi

log_pass "gemini repair uses policy-based read-only invocation"

# ---------------------------------------------------------------------------
# Cross-host policy verification (Phase 0, plan L1041 / L1289)
#
# Asserts that `config/gemini-readonly-policy.toml` continues to bound the
# Gemini reviewer's tool/file access when invoked under non-Claude
# CERBERUS_HOST values. The Codex and Amp adapters do NOT need to exist for
# this check; CERBERUS_HOST is just a label the resolver consumes for
# state-path selection.
# ---------------------------------------------------------------------------

assert_cross_host_policy() {
    local host_label="$1"

    log_test "spawn_reviewer with CERBERUS_HOST=$host_label still applies read-only policy"

    # Wipe per-reviewer state and recorded fake-gemini args between cases so
    # the assertions are independent.
    rm -f "$REVIEWS_DIR/gemini.json" \
          "$REVIEWS_DIR/gemini.done" \
          "$REVIEWS_DIR/gemini.failed" \
          "$GEMINI_ARGS_FILE" \
          "$GEMINI_SETTINGS_FILE" \
          "$GEMINI_POLICY_FILE"

    env \
        PATH="$FAKE_BIN:$PATH" \
        PLUGIN_ROOT="$PLUGIN_ROOT" \
        REVIEWS_DIR="$REVIEWS_DIR" \
        GEMINI_MODEL="$GEMINI_MODEL" \
        CODEX_MODEL="$CODEX_MODEL" \
        CLAUDE_MODEL="$CLAUDE_MODEL" \
        PROMPT_FILE="$PROMPT_FILE" \
        SCHEMA_FILE="$SCHEMA_FILE" \
        CERBERUS_HOST="$host_label" \
        CERBERUS_RUN_KEY="cross-host-${host_label}" \
        "$RUNNER_BASH" -c '
            source "$PLUGIN_ROOT/bin/review-gate-lib.sh"
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
        local output=""
        if [[ -f "$REVIEWS_DIR/gemini.json" ]]; then
            output=$("$CAT_BIN" "$REVIEWS_DIR/gemini.json")
        fi
        log_fail "gemini reviewer failed under CERBERUS_HOST=$host_label; output: $output"
    fi

    if [[ ! -f "$REVIEWS_DIR/gemini.done" ]]; then
        log_fail "expected gemini.done under CERBERUS_HOST=$host_label"
    fi

    local cross_args
    cross_args=$("$CAT_BIN" "$GEMINI_ARGS_FILE")
    if [[ "$cross_args" != *"--policy "* ]]; then
        log_fail "CERBERUS_HOST=$host_label: gemini missing --policy flag, got: $cross_args"
    fi
    if [[ "$cross_args" != *"--admin-policy "* ]]; then
        log_fail "CERBERUS_HOST=$host_label: gemini missing --admin-policy flag, got: $cross_args"
    fi
    if [[ "$cross_args" == *"--allowed-tools"* ]]; then
        log_fail "CERBERUS_HOST=$host_label: gemini should not receive deprecated --allowed-tools, got: $cross_args"
    fi
    if [[ "$cross_args" == *"--skip-trust"* || "$cross_args" == *"--skipTrust"* ]]; then
        log_fail "CERBERUS_HOST=$host_label: gemini should not receive skip-trust flags, got: $cross_args"
    fi

    local cross_settings
    cross_settings=$("$CAT_BIN" "$GEMINI_SETTINGS_FILE")
    if [[ "$cross_settings" != "$PLUGIN_ROOT/config/gemini-readonly-settings.json" ]]; then
        log_fail "CERBERUS_HOST=$host_label: settings path drifted, got: $cross_settings"
    fi

    local cross_policy
    cross_policy=$("$CAT_BIN" "$GEMINI_POLICY_FILE")
    if [[ "$cross_policy" != "$PLUGIN_ROOT/config/gemini-readonly-policy.toml" ]]; then
        log_fail "CERBERUS_HOST=$host_label: policy path drifted, got: $cross_policy"
    fi

    log_pass "policy applied cleanly under CERBERUS_HOST=$host_label"
}

assert_cross_host_policy generic
assert_cross_host_policy codex
assert_cross_host_policy amp
