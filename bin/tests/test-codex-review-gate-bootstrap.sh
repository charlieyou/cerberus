#!/usr/bin/env bash

set -euo pipefail

unset CERBERUS_HOST CERBERUS_RUN_KEY CERBERUS_STATE_ROOT CERBERUS_PROJECT_KEY \
      CERBERUS_SESSION_ID CERBERUS_TRANSCRIPT_PATH CERBERUS_ROOT \
      CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH CLAUDE_PROJECT_DIR \
      REVIEW_GATE_SESSION_KEY REVIEW_GATE_TRANSCRIPT_PATH \
      REVIEW_GATE_SESSION_SOURCE REVIEW_GATE_SESSION_ID \
      AMP_THREAD_ID AMP_CURRENT_THREAD_ID 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REVIEW_GATE="$PLUGIN_ROOT/bin/review-gate"
RUNNER_BASH="${BASH:-/bin/bash}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TEST_DIR=""

log_test() { echo -e "${YELLOW}TEST:${NC} $1"; }
log_pass() { echo -e "${GREEN}PASS:${NC} $1"; }
log_fail() { echo -e "${RED}FAIL:${NC} $1"; exit 1; }

cleanup() {
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

if ! command -v jq >/dev/null 2>&1; then
    echo "jq not available; skipping Codex review-gate bootstrap test" >&2
    exit 0
fi

TEST_DIR="$(mktemp -d -t cerberus-codex-review-gate-bootstrap.XXXXXX)"
WORKSPACE="$TEST_DIR/workspace"
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$WORKSPACE" "$FAKE_BIN"

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
printf '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}\n'
exit 0
EOF
chmod +x "$FAKE_BIN/codex"

expected_project_key() {
    local workspace_root="$1"
    echo "$workspace_root" | sed 's|^/|-|' | tr '/' '-'
}

assert_json_field() {
    local file="$1"
    local jq_path="$2"
    local expected="$3"
    local label="$4"
    local actual
    actual="$(jq -r "$jq_path" "$file" 2>/dev/null || echo "<jq-error>")"
    if [[ "$actual" != "$expected" ]]; then
        log_fail "$label: expected '$expected', got '$actual' from $file"
    fi
}

wait_for_file() {
    local file="$1"
    local attempts="${2:-30}"
    local i=0
    while [[ "$i" -lt "$attempts" ]]; do
        if [[ -f "$file" ]]; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

PROJECT_KEY="$(expected_project_key "$WORKSPACE")"
PLAN_PATH="$TEST_DIR/plan.md"
cat > "$PLAN_PATH" <<'EOF'
# Codex Bootstrap Plan

Review-gate should derive the Codex run key without requiring callers to source cerberus-skill-env.
EOF

log_test "direct artifact-path bootstraps Codex run key from CODEX_THREAD_ID"
ARTIFACT_HOME="$TEST_DIR/artifact-home"
mkdir -p "$ARTIFACT_HOME"
ARTIFACT_OUT="$TEST_DIR/artifact.out"
(
    cd "$WORKSPACE"
    env -u CERBERUS_RUN_KEY -u REVIEW_GATE_SESSION_KEY \
        -u CLAUDE_SESSION_ID -u CLAUDE_TRANSCRIPT_PATH -u CLAUDE_PROJECT_DIR \
        -u AMP_THREAD_ID -u AMP_CURRENT_THREAD_ID \
        HOME="$ARTIFACT_HOME" \
        CERBERUS_ROOT="$PLUGIN_ROOT" \
        CODEX_THREAD_ID="codex-direct-artifact-001" \
        "$REVIEW_GATE" artifact-path
) > "$ARTIFACT_OUT"
EXPECTED_ARTIFACT_PATH="$ARTIFACT_HOME/.cerberus/projects/$PROJECT_KEY/codex-direct-artifact-001/latest.md"
if [[ "$(cat "$ARTIFACT_OUT")" != "$EXPECTED_ARTIFACT_PATH" ]]; then
    log_fail "artifact-path used wrong path: $(cat "$ARTIFACT_OUT")"
fi
ARTIFACT_REGISTRY="$ARTIFACT_HOME/.cerberus/runtime/codex/$PROJECT_KEY/active-session.json"
assert_json_field "$ARTIFACT_REGISTRY" '.session_id' 'codex-direct-artifact-001' "artifact registry session_id"
assert_json_field "$ARTIFACT_REGISTRY" '.run_key' 'codex-direct-artifact-001' "artifact registry run_key"
log_pass "direct artifact-path uses Codex registry bootstrap"

log_test "direct spawn-plan-review works in Codex without sourcing cerberus-skill-env"
SPAWN_HOME="$TEST_DIR/spawn-home"
SPAWN_OUT="$TEST_DIR/spawn.out"
SPAWN_ERR="$TEST_DIR/spawn.err"
mkdir -p "$SPAWN_HOME"
(
    cd "$WORKSPACE"
    env -u CERBERUS_RUN_KEY -u REVIEW_GATE_SESSION_KEY \
        -u CLAUDE_SESSION_ID -u CLAUDE_TRANSCRIPT_PATH -u CLAUDE_PROJECT_DIR \
        -u AMP_THREAD_ID -u AMP_CURRENT_THREAD_ID \
        HOME="$SPAWN_HOME" \
        PATH="$FAKE_BIN:$PATH" \
        CERBERUS_ROOT="$PLUGIN_ROOT" \
        CODEX_THREAD_ID="codex-direct-spawn-001" \
        REVIEW_GATE_REVIEWER_TIMEOUT=5 \
        "$REVIEW_GATE" spawn-plan-review \
            --mode fast \
            --max-rounds 0 \
            --agents codex \
            "$PLAN_PATH"
) > "$SPAWN_OUT" 2> "$SPAWN_ERR"
SPAWN_DIR="$SPAWN_HOME/.cerberus/projects/$PROJECT_KEY/codex-direct-spawn-001"
SPAWN_STATE="$SPAWN_DIR/gate-state.json"
SPAWN_REGISTRY="$SPAWN_HOME/.cerberus/runtime/codex/$PROJECT_KEY/active-session.json"
if [[ ! -f "$SPAWN_STATE" ]]; then
    log_fail "spawn-plan-review did not write gate-state.json; stderr:\n$(cat "$SPAWN_ERR")"
fi
assert_json_field "$SPAWN_REGISTRY" '.session_id' 'codex-direct-spawn-001' "spawn registry session_id"
assert_json_field "$SPAWN_REGISTRY" '.run_key' 'codex-direct-spawn-001' "spawn registry run_key"
assert_json_field "$SPAWN_STATE" '.owner.host' 'codex' "spawn owner.host"
assert_json_field "$SPAWN_STATE" '.owner.run_key' 'codex-direct-spawn-001' "spawn owner.run_key"
wait_for_file "$SPAWN_DIR/reviews/codex.done" 10 || true
log_pass "direct spawn-plan-review bootstraps Codex state"

log_test "explicit CERBERUS_RUN_KEY on Codex spawn refreshes registry for stop hook"
CUSTOM_HOME="$TEST_DIR/custom-home"
CUSTOM_OUT="$TEST_DIR/custom.out"
CUSTOM_ERR="$TEST_DIR/custom.err"
mkdir -p "$CUSTOM_HOME"
(
    cd "$WORKSPACE"
    env -u REVIEW_GATE_SESSION_KEY \
        -u CLAUDE_SESSION_ID -u CLAUDE_TRANSCRIPT_PATH -u CLAUDE_PROJECT_DIR \
        -u AMP_THREAD_ID -u AMP_CURRENT_THREAD_ID \
        HOME="$CUSTOM_HOME" \
        PATH="$FAKE_BIN:$PATH" \
        CERBERUS_ROOT="$PLUGIN_ROOT" \
        CODEX_THREAD_ID="codex-direct-custom-001" \
        CERBERUS_RUN_KEY="codex-custom-run-001" \
        REVIEW_GATE_REVIEWER_TIMEOUT=5 \
        "$REVIEW_GATE" spawn-plan-review \
            --mode fast \
            --max-rounds 0 \
            --agents codex \
            "$PLAN_PATH"
) > "$CUSTOM_OUT" 2> "$CUSTOM_ERR"
CUSTOM_DIR="$CUSTOM_HOME/.cerberus/projects/$PROJECT_KEY/codex-custom-run-001"
CUSTOM_STATE="$CUSTOM_DIR/gate-state.json"
CUSTOM_REGISTRY="$CUSTOM_HOME/.cerberus/runtime/codex/$PROJECT_KEY/active-session.json"
if [[ ! -f "$CUSTOM_STATE" ]]; then
    log_fail "custom-key spawn did not write gate-state.json; stderr:\n$(cat "$CUSTOM_ERR")"
fi
assert_json_field "$CUSTOM_REGISTRY" '.session_id' 'codex-direct-custom-001' "custom registry session_id"
assert_json_field "$CUSTOM_REGISTRY" '.run_key' 'codex-custom-run-001' "custom registry run_key"
assert_json_field "$CUSTOM_STATE" '.owner.host' 'codex' "custom owner.host"
assert_json_field "$CUSTOM_STATE" '.owner.run_key' 'codex-custom-run-001' "custom owner.run_key"
wait_for_file "$CUSTOM_DIR/reviews/codex.done" 10 || true
log_pass "explicit Codex spawn run key is visible to stop hook registry"
