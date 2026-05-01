#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_DIR=""
RUNNER_BASH="${BASH:-/bin/bash}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_test() { echo -e "${YELLOW}TEST:${NC} $1"; }
log_pass() { echo -e "${GREEN}PASS:${NC} $1"; }
log_fail() { echo -e "${RED}FAIL:${NC} $1"; exit 1; }

cleanup() {
    if [[ -n "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

assert_contains() {
    local label="$1"
    local haystack="$2"
    local needle="$3"
    case "$haystack" in
        *"$needle"*) ;;
        *) log_fail "$label: expected to find '$needle' in: $haystack" ;;
    esac
}

TEST_DIR="$(mktemp -d -t cerberus-root-resolution.XXXXXX)"
BAD_ROOT="$TEST_DIR/not-cerberus"
FOREIGN_CWD="$TEST_DIR/foreign-cwd"
mkdir -p "$BAD_ROOT"
mkdir -p "$FOREIGN_CWD"

log_test "review-gate falls back when CERBERUS_ROOT points at a project root"
review_stdout="$TEST_DIR/review.out"
review_stderr="$TEST_DIR/review.err"
CERBERUS_ROOT="$BAD_ROOT" "$PLUGIN_ROOT/bin/review-gate" --help >"$review_stdout" 2>"$review_stderr"
assert_contains "review-gate fallback warning" "$(cat "$review_stderr")" "configured Cerberus root '$BAD_ROOT' is missing backend files; using $PLUGIN_ROOT"
assert_contains "review-gate fallback command path" "$(cat "$review_stdout")" "Usage: $PLUGIN_ROOT/bin/review-gate <command> [args]"
log_pass "review-gate ignores invalid CERBERUS_ROOT for backend files"

log_test "review-gate falls back when only CLAUDE_PLUGIN_ROOT points at a project root"
claude_stdout="$TEST_DIR/claude.out"
claude_stderr="$TEST_DIR/claude.err"
env -u CERBERUS_ROOT CLAUDE_PLUGIN_ROOT="$BAD_ROOT" "$PLUGIN_ROOT/bin/review-gate" --help >"$claude_stdout" 2>"$claude_stderr"
assert_contains "review-gate CLAUDE_PLUGIN_ROOT fallback warning" "$(cat "$claude_stderr")" "configured Cerberus root '$BAD_ROOT' is missing backend files; using $PLUGIN_ROOT"
assert_contains "review-gate CLAUDE_PLUGIN_ROOT command path" "$(cat "$claude_stdout")" "Usage: $PLUGIN_ROOT/bin/review-gate <command> [args]"
log_pass "review-gate ignores invalid CLAUDE_PLUGIN_ROOT for backend files"

log_test "review-gate fallback is independent of caller pwd"
pwd_stdout="$TEST_DIR/pwd-review.out"
pwd_stderr="$TEST_DIR/pwd-review.err"
(
    cd "$FOREIGN_CWD"
    CERBERUS_ROOT="$BAD_ROOT" "$PLUGIN_ROOT/bin/review-gate" --help >"$pwd_stdout" 2>"$pwd_stderr"
)
assert_contains "review-gate foreign-pwd fallback warning" "$(cat "$pwd_stderr")" "configured Cerberus root '$BAD_ROOT' is missing backend files; using $PLUGIN_ROOT"
assert_contains "review-gate foreign-pwd command path" "$(cat "$pwd_stdout")" "Usage: $PLUGIN_ROOT/bin/review-gate <command> [args]"
log_pass "review-gate fallback is pwd-independent"

log_test "review-gate rejects relative root overrides"
relative_stdout="$TEST_DIR/relative-review.out"
relative_stderr="$TEST_DIR/relative-review.err"
(
    cd "$FOREIGN_CWD"
    CERBERUS_ROOT=. "$PLUGIN_ROOT/bin/review-gate" --help >"$relative_stdout" 2>"$relative_stderr"
)
assert_contains "review-gate relative-root fallback warning" "$(cat "$relative_stderr")" "configured Cerberus root '.' is missing backend files; using $PLUGIN_ROOT"
assert_contains "review-gate relative-root command path" "$(cat "$relative_stdout")" "Usage: $PLUGIN_ROOT/bin/review-gate <command> [args]"
log_pass "review-gate relative root override is not cwd-sensitive"

log_test "review-gate rejects relative CLAUDE_PLUGIN_ROOT overrides"
relative_claude_stdout="$TEST_DIR/relative-claude-review.out"
relative_claude_stderr="$TEST_DIR/relative-claude-review.err"
(
    cd "$FOREIGN_CWD"
    env -u CERBERUS_ROOT CLAUDE_PLUGIN_ROOT=. "$PLUGIN_ROOT/bin/review-gate" --help >"$relative_claude_stdout" 2>"$relative_claude_stderr"
)
assert_contains "review-gate relative-CLAUDE_PLUGIN_ROOT fallback warning" "$(cat "$relative_claude_stderr")" "configured Cerberus root '.' is missing backend files; using $PLUGIN_ROOT"
assert_contains "review-gate relative-CLAUDE_PLUGIN_ROOT command path" "$(cat "$relative_claude_stdout")" "Usage: $PLUGIN_ROOT/bin/review-gate <command> [args]"
log_pass "review-gate relative CLAUDE_PLUGIN_ROOT override is not cwd-sensitive"

log_test "generate falls back when CERBERUS_ROOT points at a project root"
generate_stdout="$TEST_DIR/generate.out"
generate_stderr="$TEST_DIR/generate.err"
CERBERUS_ROOT="$BAD_ROOT" "$PLUGIN_ROOT/bin/generate" --help >"$generate_stdout" 2>"$generate_stderr"
assert_contains "generate fallback warning" "$(cat "$generate_stderr")" "configured Cerberus root '$BAD_ROOT' is missing backend files; using $PLUGIN_ROOT"
assert_contains "generate help" "$(cat "$generate_stdout")" "Usage: generate <output-dir> [options]"
log_pass "generate ignores invalid CERBERUS_ROOT for backend files"

log_test "generate falls back when only CLAUDE_PLUGIN_ROOT points at a project root"
generate_claude_stdout="$TEST_DIR/generate-claude.out"
generate_claude_stderr="$TEST_DIR/generate-claude.err"
env -u CERBERUS_ROOT CLAUDE_PLUGIN_ROOT="$BAD_ROOT" "$PLUGIN_ROOT/bin/generate" --help >"$generate_claude_stdout" 2>"$generate_claude_stderr"
assert_contains "generate CLAUDE_PLUGIN_ROOT fallback warning" "$(cat "$generate_claude_stderr")" "configured Cerberus root '$BAD_ROOT' is missing backend files; using $PLUGIN_ROOT"
assert_contains "generate CLAUDE_PLUGIN_ROOT help" "$(cat "$generate_claude_stdout")" "Usage: generate <output-dir> [options]"
log_pass "generate ignores invalid CLAUDE_PLUGIN_ROOT for backend files"

log_test "generate fallback is independent of caller pwd"
pwd_generate_stdout="$TEST_DIR/pwd-generate.out"
pwd_generate_stderr="$TEST_DIR/pwd-generate.err"
(
    cd "$FOREIGN_CWD"
    CERBERUS_ROOT=. "$PLUGIN_ROOT/bin/generate" --help >"$pwd_generate_stdout" 2>"$pwd_generate_stderr"
)
assert_contains "generate relative-root fallback warning" "$(cat "$pwd_generate_stderr")" "configured Cerberus root '.' is missing backend files; using $PLUGIN_ROOT"
assert_contains "generate relative-root help" "$(cat "$pwd_generate_stdout")" "Usage: generate <output-dir> [options]"
log_pass "generate relative root override is not cwd-sensitive"

log_test "generate rejects relative CLAUDE_PLUGIN_ROOT overrides"
relative_claude_generate_stdout="$TEST_DIR/relative-claude-generate.out"
relative_claude_generate_stderr="$TEST_DIR/relative-claude-generate.err"
(
    cd "$FOREIGN_CWD"
    env -u CERBERUS_ROOT CLAUDE_PLUGIN_ROOT=. "$PLUGIN_ROOT/bin/generate" --help >"$relative_claude_generate_stdout" 2>"$relative_claude_generate_stderr"
)
assert_contains "generate relative-CLAUDE_PLUGIN_ROOT fallback warning" "$(cat "$relative_claude_generate_stderr")" "configured Cerberus root '.' is missing backend files; using $PLUGIN_ROOT"
assert_contains "generate relative-CLAUDE_PLUGIN_ROOT help" "$(cat "$relative_claude_generate_stdout")" "Usage: generate <output-dir> [options]"
log_pass "generate relative CLAUDE_PLUGIN_ROOT override is not cwd-sensitive"

log_test "cerberus-skill-env corrects an invalid inherited CERBERUS_ROOT"
resolved_root="$(CERBERUS_ROOT="$BAD_ROOT" "$RUNNER_BASH" -c '. "$1/bin/cerberus-skill-env"; printf "%s\n" "$CERBERUS_ROOT"' _ "$PLUGIN_ROOT")"
if [[ "$resolved_root" != "$PLUGIN_ROOT" ]]; then
    log_fail "expected cerberus-skill-env to reset CERBERUS_ROOT to $PLUGIN_ROOT, got: $resolved_root"
fi
log_pass "cerberus-skill-env resets invalid CERBERUS_ROOT"

log_test "cerberus-skill-env ignores relative inherited CERBERUS_ROOT from foreign pwd"
relative_skill_root="$(
    cd "$FOREIGN_CWD"
    CERBERUS_ROOT=. "$RUNNER_BASH" -c '. "$1/bin/cerberus-skill-env"; printf "%s\n" "$CERBERUS_ROOT"' _ "$PLUGIN_ROOT"
)"
if [[ "$relative_skill_root" != "$PLUGIN_ROOT" ]]; then
    log_fail "expected cerberus-skill-env to reset relative CERBERUS_ROOT to $PLUGIN_ROOT, got: $relative_skill_root"
fi
log_pass "cerberus-skill-env relative root override is not cwd-sensitive"

log_test "cerberus-skill-env survives invalid CLAUDE_SKILL_DIR"
skill_dir_root="$(env -u CERBERUS_ROOT CLAUDE_SKILL_DIR="$TEST_DIR/missing-skill-dir" "$RUNNER_BASH" -c '. "$1/bin/cerberus-skill-env"; printf "%s\n" "$CERBERUS_ROOT"' _ "$PLUGIN_ROOT")"
if [[ "$skill_dir_root" != "$PLUGIN_ROOT" ]]; then
    log_fail "expected cerberus-skill-env to fall back after invalid CLAUDE_SKILL_DIR, got: $skill_dir_root"
fi
log_pass "cerberus-skill-env survives invalid CLAUDE_SKILL_DIR"

log_test "gemini read-only paths stay anchored to Cerberus config after fallback"
settings_path="$(CERBERUS_ROOT="$BAD_ROOT" PLUGIN_ROOT="$PLUGIN_ROOT" "$RUNNER_BASH" -c 'source "$PLUGIN_ROOT/bin/review-gate-models.sh"; gemini_readonly_settings_path')"
policy_path="$(CERBERUS_ROOT="$BAD_ROOT" PLUGIN_ROOT="$PLUGIN_ROOT" "$RUNNER_BASH" -c 'source "$PLUGIN_ROOT/bin/review-gate-models.sh"; gemini_readonly_policy_path')"
if [[ "$settings_path" != "$PLUGIN_ROOT/config/gemini-readonly-settings.json" ]]; then
    log_fail "expected Gemini settings path under Cerberus config, got: $settings_path"
fi
if [[ "$policy_path" != "$PLUGIN_ROOT/config/gemini-readonly-policy.toml" ]]; then
    log_fail "expected Gemini policy path under Cerberus config, got: $policy_path"
fi
log_pass "gemini read-only paths stay anchored to Cerberus config"

log_pass "Cerberus root resolution fallback coverage complete"
