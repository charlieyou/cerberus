#!/usr/bin/env bash

set -euo pipefail

# Env isolation: drop any inherited CERBERUS_*/CLAUDE_*/REVIEW_GATE_* vars
# from the parent shell so the test's stdin-supplied session_id /
# transcript_path are the sole source of truth. T005.5 made the resolver
# honor CLAUDE_TRANSCRIPT_PATH ahead of REVIEW_GATE_TRANSCRIPT_PATH per the
# documented `CERBERUS_* > CLAUDE_* > REVIEW_GATE_*` contract; without this
# unset block, a parent shell that leaked CLAUDE_TRANSCRIPT_PATH (e.g., the
# Claude Code agent host running this test) would route the spawned
# `bin/review-gate resolve` re-entry to the wrong review dir. Same precedent
# as T004's harden-env-isolation commit on test-host-neutral-state.sh.
unset CERBERUS_HOST CERBERUS_RUN_KEY CERBERUS_STATE_ROOT CERBERUS_PROJECT_KEY \
      CERBERUS_SESSION_ID CERBERUS_TRANSCRIPT_PATH CERBERUS_ROOT \
      CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH CLAUDE_PROJECT_DIR \
      CLAUDE_PLUGIN_ROOT \
      REVIEW_GATE_SESSION_KEY REVIEW_GATE_TRANSCRIPT_PATH \
      REVIEW_GATE_SESSION_SOURCE 2>/dev/null || true

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
export HOME="$TEST_DIR/home"
mkdir -p "$HOME"

SESSION_ID="test-empty-running-list-$$"
TRANSCRIPT_PATH="$HOME/.claude/projects/-tmp-check-test/${SESSION_ID}.jsonl"
REVIEW_DIR="$HOME/.claude/projects/-tmp-check-test/cerberus/${SESSION_ID}"
STATE_FILE="$REVIEW_DIR/gate-state.json"
REVIEWS_DIR="$REVIEW_DIR/reviews"

mkdir -p "$REVIEWS_DIR" "$(dirname "$TRANSCRIPT_PATH")"
touch "$TRANSCRIPT_PATH"

cat > "$REVIEWS_DIR/codex.json" <<'EOF'
{"verdict":"PASS","summary":"ok","findings":[]}
EOF
touch "$REVIEWS_DIR/codex.done"

created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > "$STATE_FILE" <<EOF
{
  "version": 1,
  "status": "pending",
  "trigger_source": "plan",
  "artifact": {
    "path": "$REVIEW_DIR/latest.md",
    "sha256": "test"
  },
  "mode": {
    "type": "plan",
    "plan_path": "$REVIEW_DIR/latest.md"
  },
  "config": {
    "max_rounds": 3,
    "consensus_mode": "majority"
  },
  "reviewers": {
    "codex": {
      "output_file": "$REVIEWS_DIR/codex.json",
      "sentinel_file": "$REVIEWS_DIR/codex.done",
      "completed_at": null,
      "result": null
    }
  },
  "consensus": null,
  "decision": null,
  "created_at": "$created_at",
  "iteration": 0
}
EOF

log_test "check handles an empty running reviewer list under nounset"

stdout_file="$TEST_DIR/stdout"
stderr_file="$TEST_DIR/stderr"

set +e
printf '{"session_id":"%s","transcript_path":"%s"}' "$SESSION_ID" "$TRANSCRIPT_PATH" \
    | /bin/bash "$REVIEW_GATE" check >"$stdout_file" 2>"$stderr_file"
status=$?
set -e

stdout=$(cat "$stdout_file")
stderr=$(cat "$stderr_file")

if [[ "$status" -ne 0 ]]; then
    log_fail "expected check to exit 0, got $status\nstdout:\n$stdout\nstderr:\n$stderr"
fi

if [[ "$stdout$stderr" == *"unbound variable"* ]]; then
    log_fail "check crashed on empty running_list\nstdout:\n$stdout\nstderr:\n$stderr"
fi

decision=$(jq -r '.decision // empty' "$stdout_file")
if [[ "$decision" != "block" ]]; then
    log_fail "expected hook to return block JSON after consensus processing, got stdout:\n$stdout\nstderr:\n$stderr"
fi

state_status=$(jq -r '.status' "$STATE_FILE")
if [[ "$state_status" != "resolved" ]]; then
    log_fail "expected auto-approved gate to resolve, got state status $state_status"
fi

consensus=$(jq -r '.consensus.verdict // empty' "$STATE_FILE")
if [[ "$consensus" != "auto_approve" ]]; then
    log_fail "expected consensus auto_approve, got $consensus"
fi

action=$(jq -r '.decision.action // empty' "$STATE_FILE")
if [[ "$action" != "proceed" ]]; then
    log_fail "expected resolved proceed action, got $action"
fi

log_pass "check handles completed reviewers without nounset failure"

SESSION_ID_STALE="test-check-stale-failed-$$"
TRANSCRIPT_PATH_STALE="$HOME/.claude/projects/-tmp-check-test/${SESSION_ID_STALE}.jsonl"
REVIEW_DIR_STALE="$HOME/.claude/projects/-tmp-check-test/cerberus/${SESSION_ID_STALE}"
STATE_FILE_STALE="$REVIEW_DIR_STALE/gate-state.json"
REVIEWS_DIR_STALE="$REVIEW_DIR_STALE/reviews"

mkdir -p "$REVIEWS_DIR_STALE" "$(dirname "$TRANSCRIPT_PATH_STALE")"
touch "$TRANSCRIPT_PATH_STALE"

cat > "$REVIEWS_DIR_STALE/claude.json" <<'EOF'
{
  "type": "result",
  "subtype": "success",
  "is_error": false,
  "result": "{\"verdict\":\"PASS\",\"summary\":\"valid output with stale failure\",\"findings\":[]}"
}
EOF
touch "$REVIEWS_DIR_STALE/claude.failed"

created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > "$STATE_FILE_STALE" <<EOF
{
  "version": 1,
  "status": "pending",
  "trigger_source": "test",
  "artifact": {
    "path": "$REVIEW_DIR_STALE/latest.md",
    "sha256": "test"
  },
  "mode": {
    "type": "plan",
    "plan_path": "$REVIEW_DIR_STALE/latest.md"
  },
  "config": {
    "max_rounds": 3,
    "consensus_mode": "majority"
  },
  "reviewers": {
    "claude": {
      "output_file": "$REVIEWS_DIR_STALE/claude.json",
      "sentinel_file": "$REVIEWS_DIR_STALE/claude.done",
      "completed_at": null,
      "result": null
    }
  },
  "consensus": null,
  "decision": null,
  "created_at": "$created_at",
  "iteration": 0
}
EOF

log_test "check trusts valid reviewer JSON over stale .failed sentinel"

stdout_file="$TEST_DIR/stale-stdout"
stderr_file="$TEST_DIR/stale-stderr"

set +e
printf '{"session_id":"%s","transcript_path":"%s"}' "$SESSION_ID_STALE" "$TRANSCRIPT_PATH_STALE" \
    | /bin/bash "$REVIEW_GATE" check >"$stdout_file" 2>"$stderr_file"
status=$?
set -e

stdout=$(cat "$stdout_file")
stderr=$(cat "$stderr_file")

if [[ "$status" -ne 0 ]]; then
    log_fail "expected check to exit 0 for valid stale-failed output, got $status\nstdout:\n$stdout\nstderr:\n$stderr"
fi

decision=$(jq -r '.decision // empty' "$stdout_file")
if [[ "$decision" != "block" ]]; then
    log_fail "expected hook to return block JSON after auto-approval summary, got stdout:\n$stdout\nstderr:\n$stderr"
fi

state_status=$(jq -r '.status' "$STATE_FILE_STALE")
if [[ "$state_status" != "resolved" ]]; then
    log_fail "expected stale-failed gate to resolve, got state status $state_status"
fi

consensus=$(jq -r '.consensus.verdict // empty' "$STATE_FILE_STALE")
if [[ "$consensus" != "auto_approve" ]]; then
    log_fail "expected stale-failed consensus auto_approve, got $consensus"
fi

if [[ "$stdout" == *"Reviewer process failed"* ]]; then
    log_fail "stale .failed sentinel leaked into hook output\nstdout:\n$stdout\nstderr:\n$stderr"
fi

log_pass "check ignores stale .failed when reviewer JSON is valid"

SESSION_ID_OLD_RERUN="test-check-old-rerun-$$"
TRANSCRIPT_PATH_OLD_RERUN="$HOME/.claude/projects/-tmp-check-test/${SESSION_ID_OLD_RERUN}.jsonl"
REVIEW_DIR_OLD_RERUN="$HOME/.claude/projects/-tmp-check-test/cerberus/${SESSION_ID_OLD_RERUN}"
STATE_FILE_OLD_RERUN="$REVIEW_DIR_OLD_RERUN/gate-state.json"
REVIEWS_DIR_OLD_RERUN="$REVIEW_DIR_OLD_RERUN/reviews"
PLAN_FILE_OLD_RERUN="$REVIEW_DIR_OLD_RERUN/plan.md"
FAKE_BIN_OLD_RERUN="$TEST_DIR/fake-bin-old-rerun"

mkdir -p "$REVIEWS_DIR_OLD_RERUN" "$(dirname "$TRANSCRIPT_PATH_OLD_RERUN")" "$FAKE_BIN_OLD_RERUN"
touch "$TRANSCRIPT_PATH_OLD_RERUN"

cat > "$FAKE_BIN_OLD_RERUN/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
if [[ "${1:-}" == "exec" && "${2:-}" == "--help" ]]; then
    echo "Usage: codex exec"
    exit 0
fi

if [[ "${1:-}" == "exec" ]]; then
    shift
fi

out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o)
            out="${2:-}"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

cat >/dev/null
if [[ -z "$out" ]]; then
    echo "missing -o" >&2
    exit 2
fi

printf '%s\n' '{"verdict":"PASS","summary":"old pending no-reviewer state re-spawned","findings":[]}' > "$out"
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
FAKE_CODEX
chmod +x "$FAKE_BIN_OLD_RERUN/codex"

cat > "$PLAN_FILE_OLD_RERUN" <<'EOF'
# Old pending no-reviewer re-run plan

This fixture verifies an aged clean_for_rerun state still re-spawns reviewers.
EOF

cat > "$REVIEW_DIR_OLD_RERUN/latest.md" <<EOF
<!-- review-type: plan -->
<!-- plan-path: $PLAN_FILE_OLD_RERUN -->
<!-- agents: codex -->
<!-- max-rounds: 3 -->

# Old pending no-reviewer re-run artifact
EOF

cat > "$STATE_FILE_OLD_RERUN" <<EOF
{
  "version": 1,
  "status": "pending",
  "trigger_source": "plan",
  "artifact": {
    "path": "$REVIEW_DIR_OLD_RERUN/latest.md",
    "sha256": "test"
  },
  "mode": {
    "type": "plan",
    "plan_path": "$PLAN_FILE_OLD_RERUN"
  },
  "config": {
    "max_rounds": 3,
    "consensus_mode": "majority"
  },
  "reviewers": {},
  "consensus": null,
  "decision": null,
  "created_at": "2000-01-01T00:00:00Z",
  "iteration": 1
}
EOF

log_test "old pending state with no reviewers re-spawns instead of stale-resolving"

stdout_file="$TEST_DIR/old-rerun-stdout"
stderr_file="$TEST_DIR/old-rerun-stderr"

set +e
printf '{"session_id":"%s","transcript_path":"%s"}' "$SESSION_ID_OLD_RERUN" "$TRANSCRIPT_PATH_OLD_RERUN" \
    | PATH="$FAKE_BIN_OLD_RERUN:$PATH" REVIEW_GATE_MAX_WAIT_SECONDS=10 REVIEW_GATE_POLL_INTERVAL_SECONDS=1 \
        /bin/bash "$REVIEW_GATE" check >"$stdout_file" 2>"$stderr_file"
status=$?
set -e

stdout=$(cat "$stdout_file")
stderr=$(cat "$stderr_file")

if [[ "$status" -ne 0 ]]; then
    log_fail "expected check to exit 0 for old no-reviewer state, got $status\nstdout:\n$stdout\nstderr:\n$stderr"
fi

decision=$(jq -r '.decision // empty' "$stdout_file")
if [[ "$decision" != "block" ]]; then
    log_fail "expected hook to return block JSON after re-spawned review, got stdout:\n$stdout\nstderr:\n$stderr"
fi

state_status=$(jq -r '.status // empty' "$STATE_FILE_OLD_RERUN")
if [[ "$state_status" != "resolved" ]]; then
    log_fail "expected old no-reviewer state to auto-approve after fake re-spawn, got state status $state_status\nstdout:\n$stdout\nstderr:\n$stderr"
fi

reason=$(jq -r '.decision.reason // empty' "$STATE_FILE_OLD_RERUN")
if [[ "$reason" == "stale_timeout" ]]; then
    log_fail "old no-reviewer state was incorrectly stale-resolved\nstdout:\n$stdout\nstderr:\n$stderr"
fi

if [[ ! -f "$REVIEWS_DIR_OLD_RERUN/codex.done" ]]; then
    log_fail "expected fake codex reviewer to be spawned and complete\nstdout:\n$stdout\nstderr:\n$stderr"
fi

log_pass "old pending no-reviewer state re-spawns after long fix interval"
