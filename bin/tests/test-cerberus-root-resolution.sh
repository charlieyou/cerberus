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

extract_skill_bootstrap() {
    awk '
        /^```bash$/ { in_block=1; next }
        in_block && /^```$/ { exit }
        in_block { print }
    ' "$1"
}

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[&|\]/\\&/g'
}

expected_project_key() {
    echo "$1" | sed 's|^/|-|' | tr '/' '-'
}

TEST_DIR="$(mktemp -d -t cerberus-root-resolution.XXXXXX)"
BAD_ROOT="$TEST_DIR/not-cerberus"
FOREIGN_CWD="$TEST_DIR/foreign-cwd"
mkdir -p "$BAD_ROOT"
mkdir -p "$FOREIGN_CWD"
PLUGIN_ROOT_SED="$(escape_sed_replacement "$PLUGIN_ROOT")"
REVIEW_CODE_SKILL_DIR_SED="$(escape_sed_replacement "$PLUGIN_ROOT/skills/review-code")"

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

log_test "skill bootstrap resolves Claude-substituted CLAUDE_SKILL_DIR"
rendered_bootstrap="$TEST_DIR/bootstrap-rendered-skill-dir.sh"
extract_skill_bootstrap "$PLUGIN_ROOT/skills/review-code/SKILL.md" \
    | sed "s|\${CLAUDE_SKILL_DIR}|$REVIEW_CODE_SKILL_DIR_SED|g" >"$rendered_bootstrap"
rendered_skill_dir_root="$(
    cd "$FOREIGN_CWD"
    env -u CERBERUS_ROOT -u CLAUDE_PLUGIN_ROOT -u CLAUDE_SKILL_DIR "$RUNNER_BASH" -c '. "$1"; printf "%s\n" "$CERBERUS_ROOT"' _ "$rendered_bootstrap"
)"
if [[ "$rendered_skill_dir_root" != "$PLUGIN_ROOT" ]]; then
    log_fail "expected rendered skill bootstrap to resolve $PLUGIN_ROOT, got: $rendered_skill_dir_root"
fi
log_pass "skill bootstrap resolves Claude-substituted CLAUDE_SKILL_DIR"

log_test "skill bootstrap exports selected root before sourcing env helper"
fake_backend="$TEST_DIR/fake-backend"
mkdir -p "$fake_backend/bin" "$fake_backend/config"
cat > "$fake_backend/bin/cerberus-skill-env" <<'EOF'
if [ -z "${CERBERUS_ROOT:-}" ]; then
    export CERBERUS_ROOT="${CLAUDE_PLUGIN_ROOT:-helper-used-host-root}"
fi
EOF
cat > "$fake_backend/bin/review-gate" <<'EOF'
#!/usr/bin/env bash
:
EOF
chmod +x "$fake_backend/bin/review-gate"
: > "$fake_backend/bin/review-gate-models.sh"
: > "$fake_backend/config/gemini-readonly-settings.json"
: > "$fake_backend/config/gemini-readonly-policy.toml"
FAKE_BACKEND_SED="$(escape_sed_replacement "$fake_backend")"
fake_backend_bootstrap="$TEST_DIR/bootstrap-fake-backend.sh"
extract_skill_bootstrap "$PLUGIN_ROOT/skills/review-code/SKILL.md" \
    | sed "s|\${CLAUDE_PLUGIN_ROOT}|$FAKE_BACKEND_SED|g" >"$fake_backend_bootstrap"
fake_backend_resolved_root="$(
    cd "$FOREIGN_CWD"
    env -u CERBERUS_ROOT -u CLAUDE_SKILL_DIR CLAUDE_PLUGIN_ROOT="$BAD_ROOT" \
        "$RUNNER_BASH" -c '. "$1"; printf "%s\n" "$CERBERUS_ROOT"' _ "$fake_backend_bootstrap"
)"
if [[ "$fake_backend_resolved_root" != "$fake_backend" ]]; then
    log_fail "expected bootstrap to export selected backend $fake_backend before helper source, got: $fake_backend_resolved_root"
fi
log_pass "skill bootstrap preserves selected root across env helper source"

log_test "skill bootstrap ignores stale inherited CERBERUS_ROOT with helper only"
stale_root="$TEST_DIR/stale-helper-root"
mkdir -p "$stale_root/bin"
cp "$PLUGIN_ROOT/bin/cerberus-skill-env" "$stale_root/bin/cerberus-skill-env"
stale_bootstrap="$TEST_DIR/bootstrap-stale-root.sh"
extract_skill_bootstrap "$PLUGIN_ROOT/skills/review-code/SKILL.md" \
    | sed "s|\${CLAUDE_PLUGIN_ROOT}|$PLUGIN_ROOT_SED|g" >"$stale_bootstrap"
stale_resolved_root="$(
    cd "$FOREIGN_CWD"
    env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_SKILL_DIR CERBERUS_ROOT="$stale_root" \
        "$RUNNER_BASH" -c '. "$1"; printf "%s\n" "$CERBERUS_ROOT"' _ "$stale_bootstrap"
)"
if [[ "$stale_resolved_root" != "$PLUGIN_ROOT" ]]; then
    log_fail "expected skill bootstrap to ignore stale helper-only CERBERUS_ROOT and resolve $PLUGIN_ROOT, got: $stale_resolved_root"
fi
log_pass "skill bootstrap ignores stale helper-only CERBERUS_ROOT"

log_test "skill bootstrap falls back to current Cerberus git checkout"
unrendered_bootstrap="$TEST_DIR/bootstrap-unrendered.sh"
extract_skill_bootstrap "$PLUGIN_ROOT/skills/review-code/SKILL.md" >"$unrendered_bootstrap"
git_fallback_root="$(
    cd "$PLUGIN_ROOT"
    env -u CERBERUS_ROOT -u CLAUDE_PLUGIN_ROOT -u CLAUDE_SKILL_DIR "$RUNNER_BASH" -c '. "$1"; printf "%s\n" "$CERBERUS_ROOT"' _ "$unrendered_bootstrap"
)"
if [[ "$git_fallback_root" != "$PLUGIN_ROOT" ]]; then
    log_fail "expected unrendered skill bootstrap to resolve $PLUGIN_ROOT from git checkout, got: $git_fallback_root"
fi
log_pass "skill bootstrap falls back to current Cerberus git checkout"

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

log_test "Codex plugin manifest declares bundled lifecycle hooks"
marketplace_path="$(jq -r '.plugins[] | select(.name == "cerberus") | .source.path // empty' "$PLUGIN_ROOT/.agents/plugins/marketplace.json" 2>/dev/null || echo "")"
marketplace_source="$(jq -r '.plugins[] | select(.name == "cerberus") | .source.source // empty' "$PLUGIN_ROOT/.agents/plugins/marketplace.json" 2>/dev/null || echo "")"
marketplace_url="$(jq -r '.plugins[] | select(.name == "cerberus") | .source.url // empty' "$PLUGIN_ROOT/.agents/plugins/marketplace.json" 2>/dev/null || echo "")"
marketplace_ref="$(jq -r '.plugins[] | select(.name == "cerberus") | .source.ref // empty' "$PLUGIN_ROOT/.agents/plugins/marketplace.json" 2>/dev/null || echo "")"
if [[ "$marketplace_source" != "url" ]]; then
    log_fail "expected marketplace source.source='url', got: $marketplace_source"
fi
if [[ "$marketplace_url" != "https://github.com/charlieyou/cerberus.git" ]]; then
    log_fail "expected marketplace source.url to point at the Cerberus Git repository, got: $marketplace_url"
fi
if [[ "$marketplace_ref" != "main" ]]; then
    log_fail "expected marketplace source.ref='main', got: $marketplace_ref"
fi
if [[ -n "$marketplace_path" ]]; then
    log_fail "expected repo-root Git marketplace source to omit source.path, got: $marketplace_path"
fi
manifest_hooks="$(jq -r '.hooks // empty' "$PLUGIN_ROOT/.codex-plugin/plugin.json" 2>/dev/null || echo "")"
if [[ "$manifest_hooks" != "./hooks/codex-hooks.json" ]]; then
    log_fail "expected plugin manifest hooks='./hooks/codex-hooks.json', got: $manifest_hooks"
fi
if [[ ! -f "$PLUGIN_ROOT/hooks/codex-hooks.json" ]]; then
    log_fail "expected bundled Codex hooks file at $PLUGIN_ROOT/hooks/codex-hooks.json"
fi
if ! jq -e '
    .hooks.SessionStart[0].hooks[0].command == "/bin/bash \"${PLUGIN_ROOT}/bin/codex-session-init\""
    and .hooks.UserPromptSubmit[0].hooks[0].command == "/bin/bash \"${PLUGIN_ROOT}/bin/codex-session-init\""
    and .hooks.Stop[0].hooks[0].command == "/bin/bash \"${PLUGIN_ROOT}/bin/codex-stop-hook\""
    and .hooks.Stop[0].hooks[0].timeout == 2100
' "$PLUGIN_ROOT/hooks/codex-hooks.json" >/dev/null 2>&1; then
    log_fail "bundled Codex hooks file does not use expected /bin/bash PLUGIN_ROOT commands"
fi
log_pass "Codex plugin manifest and bundled hooks are wired"

log_test "cerberus-skill-env reads Codex active-session registry"
codex_home="$TEST_DIR/codex-home"
mkdir -p "$codex_home"
codex_pk="$(expected_project_key "$FOREIGN_CWD")"
codex_registry_dir="$codex_home/.cerberus/runtime/codex/$codex_pk"
mkdir -p "$codex_registry_dir"
cat > "$codex_registry_dir/active-session.json" <<EOF
{"schema_version":1,"host":"codex","workspace_root":"$FOREIGN_CWD","project_key":"$codex_pk","session_id":"codex-sess-001","codex_session_id":"codex-sess-001","run_key":"codex-run-001","transcript_path":"","last_seen":"2026-05-02T00:00:00Z"}
EOF
codex_env_output="$TEST_DIR/codex-env.out"
(
    cd "$FOREIGN_CWD"
    env HOME="$codex_home" CERBERUS_HOST=codex CERBERUS_ROOT="$PLUGIN_ROOT" "$RUNNER_BASH" -c '. "$1/bin/cerberus-skill-env" || exit $?; printf "%s\n%s\n" "$CERBERUS_PROJECT_KEY" "$CERBERUS_RUN_KEY"' _ "$PLUGIN_ROOT"
) > "$codex_env_output"
codex_resolved_pk="$(sed -n '1p' "$codex_env_output")"
codex_resolved_run="$(sed -n '2p' "$codex_env_output")"
if [[ "$codex_resolved_pk" != "$codex_pk" ]]; then
    log_fail "expected Codex skill env to export project key $codex_pk, got: $codex_resolved_pk"
fi
if [[ "$codex_resolved_run" != "codex-run-001" ]]; then
    log_fail "expected Codex skill env to export run key codex-run-001, got: $codex_resolved_run"
fi
log_pass "cerberus-skill-env exports Codex registry project/run key"

log_test "cerberus-skill-env bootstraps missing Codex registry from CODEX_THREAD_ID"
thread_home="$TEST_DIR/codex-thread-home"
mkdir -p "$thread_home"
thread_output="$TEST_DIR/codex-thread.out"
thread_registry="$thread_home/.cerberus/runtime/codex/$codex_pk/active-session.json"
(
    cd "$FOREIGN_CWD"
    env HOME="$thread_home" CODEX_THREAD_ID=codex-thread-001 CERBERUS_ROOT="$PLUGIN_ROOT" \
        "$RUNNER_BASH" -c '. "$1/bin/cerberus-skill-env" || exit $?; printf "%s\n%s\n%s\n" "$CERBERUS_HOST" "$CERBERUS_PROJECT_KEY" "$CERBERUS_RUN_KEY"' _ "$PLUGIN_ROOT"
) > "$thread_output"
thread_host="$(sed -n '1p' "$thread_output")"
thread_resolved_pk="$(sed -n '2p' "$thread_output")"
thread_resolved_run="$(sed -n '3p' "$thread_output")"
if [[ "$thread_host" != "codex" ]]; then
    log_fail "expected CODEX_THREAD_ID to select Codex host, got: $thread_host"
fi
if [[ "$thread_resolved_pk" != "$codex_pk" ]]; then
    log_fail "expected Codex thread bootstrap to export project key $codex_pk, got: $thread_resolved_pk"
fi
if [[ "$thread_resolved_run" != "codex-thread-001" ]]; then
    log_fail "expected Codex thread bootstrap to export run key codex-thread-001, got: $thread_resolved_run"
fi
if [[ ! -f "$thread_registry" ]]; then
    log_fail "expected Codex thread bootstrap to write registry at $thread_registry"
fi
if [[ "$(jq -r '.session_id' "$thread_registry")" != "codex-thread-001" ]]; then
    log_fail "expected bootstrapped registry session_id codex-thread-001, got: $(cat "$thread_registry")"
fi
log_pass "cerberus-skill-env writes Codex registry from CODEX_THREAD_ID"

log_test "cerberus-skill-env fails clearly when Codex registry is missing"
missing_home="$TEST_DIR/codex-missing-home"
mkdir -p "$missing_home"
missing_stderr="$TEST_DIR/codex-missing.err"
missing_rc=0
(
    cd "$FOREIGN_CWD"
    env -u CODEX_THREAD_ID HOME="$missing_home" CERBERUS_HOST=codex CERBERUS_ROOT="$PLUGIN_ROOT" "$RUNNER_BASH" -c '. "$1/bin/cerberus-skill-env"' _ "$PLUGIN_ROOT"
) 2> "$missing_stderr" || missing_rc=$?
if [[ "$missing_rc" -eq 0 ]]; then
    log_fail "expected missing Codex registry to make cerberus-skill-env fail"
fi
assert_contains "missing Codex registry diagnostic" "$(cat "$missing_stderr")" "Codex active-session registry not found"
log_pass "cerberus-skill-env does not invent a Codex run key without registry or CODEX_THREAD_ID"

log_test "cerberus-skill-env fails clearly when Codex registry is malformed"
malformed_home="$TEST_DIR/codex-malformed-home"
malformed_dir="$malformed_home/.cerberus/runtime/codex/$codex_pk"
mkdir -p "$malformed_dir"
printf '{not json' > "$malformed_dir/active-session.json"
malformed_stderr="$TEST_DIR/codex-malformed.err"
malformed_rc=0
(
    cd "$FOREIGN_CWD"
    env -u CODEX_THREAD_ID HOME="$malformed_home" CERBERUS_HOST=codex CERBERUS_ROOT="$PLUGIN_ROOT" "$RUNNER_BASH" -c '. "$1/bin/cerberus-skill-env"' _ "$PLUGIN_ROOT"
) 2> "$malformed_stderr" || malformed_rc=$?
if [[ "$malformed_rc" -eq 0 ]]; then
    log_fail "expected malformed Codex registry to make cerberus-skill-env fail"
fi
assert_contains "malformed Codex registry diagnostic" "$(cat "$malformed_stderr")" "Codex active-session registry is malformed"
log_pass "cerberus-skill-env rejects malformed Codex registry"

log_pass "Cerberus root resolution fallback coverage complete"
