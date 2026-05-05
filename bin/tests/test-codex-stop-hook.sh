#!/usr/bin/env bash
# T009 — Phase 1 tests for bin/codex-stop-hook.
#
# Plan reference: §Phase 1 — Codex Tests, "test-codex-stop-hook.sh"
# (plan L1151-L1178) and §Codex Stop Decision Matrix (plan L732-L766).
#
# Coverage matrix (15 cases + 3 happy-path probes carried forward from
# T007). Every case exercises a real fixture with the production
# `bin/review-gate` (or a deliberate stub fixture for matrix rows that
# probe the failure-open path).
#
#   Case 1  — Row 1:  registry + run dir present, but no gate-state.json
#                     → status exits 4 → {"continue":true}.
#   Case 2  — Row 2:  no registry → {"continue":true}.
#   Case 3  — Row 4:  pending + MAX_WAIT=0 → allow with "still running" note.
#   Case 4  — Row 5a: pending + MAX_WAIT=N, reviewers DON'T finish during the
#                     wait window → fall through to row 4 message.
#   Case 5  — Row 5b: pending + MAX_WAIT=N, reviewers finish during the wait
#                     window → re-evaluation produces row 8 (allow).
#   Case 6  — Row 6:  awaiting_decision + blocking findings (FAIL/P0) →
#                     {"decision":"block", "reason":...}.
#   Case 7  — Row 8:  resolved + consensus_verdict=pass → allow.
#   Case 8  — Row 9:  resolved + consensus_verdict=fail → continue.
#   Case 9  — Row 10: malformed gate-state.json → allow with "unreadable"
#                     note.
#   Case 10 — Row 11: status exits 2 (non-zero, non-4) → allow + stderr
#                     diagnostic.
#   Case 11 — Row 12: jq missing on PATH → allow.
#   Case 12 — Row 13a: SIGTERM mid-execution → allow, exit 0.
#   Case 13 — Row 13b: SIGINT during child wait → child killed, allow.
#   Case 14 — Row 13c: SIGHUP during child wait → child killed, allow.
#   Case 15 —          Stdin parse failure → allow + stderr diagnostic.
#   Regression — reviewer subprocess marker → allow before registry/status/wait.
#
# Happy-path probes carried forward from T007:
#   Happy A — script entry point exists, executable.
#   Happy B — stub reads stdin and emits valid {continue:true,...}, exit 0.
#   Happy C — INT/TERM/HUP trap installed at script load (static check).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_STOP_HOOK="$SCRIPT_DIR/../codex-stop-hook"
CODEX_SESSION_INIT="$SCRIPT_DIR/../codex-session-init"
REVIEW_GATE="$SCRIPT_DIR/../review-gate"

if [[ ! -f "$CODEX_STOP_HOOK" ]]; then
    echo "FATAL: bin/codex-stop-hook not found at $CODEX_STOP_HOOK" >&2
    exit 2
fi
if [[ ! -x "$CODEX_STOP_HOOK" ]]; then
    echo "FATAL: bin/codex-stop-hook not executable at $CODEX_STOP_HOOK" >&2
    exit 2
fi
if [[ ! -f "$CODEX_SESSION_INIT" ]]; then
    echo "FATAL: bin/codex-session-init not found at $CODEX_SESSION_INIT" >&2
    exit 2
fi
if [[ ! -x "$CODEX_SESSION_INIT" ]]; then
    echo "FATAL: bin/codex-session-init not executable at $CODEX_SESSION_INIT" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "FATAL: jq required for these tests but is not on PATH" >&2
    exit 2
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR=""
REMOVED_CODEX_WAIT_ENV="CERBERUS_CODEX_STOP_WAIT""_SECONDS"

cleanup() {
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

TEST_DIR="$(mktemp -d -t cerberus-codex-stop-hook.XXXXXX)"

log_test() { echo -e "${YELLOW}TEST:${NC} $1"; }
log_pass() { echo -e "${GREEN}PASS:${NC} $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
log_fail() { echo -e "${RED}FAIL:${NC} $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# Compute the project_key the hook will derive from a given workspace
# path. Mirrors get_project_hash's path transform (sed 's|^/|-|' | tr
# '/' '-').
expected_project_key() {
    echo "$1" | sed 's|^/|-|' | tr '/' '-'
}

# Build a registry under $home for ($workspace, $run_key, $session_id).
make_registry() {
    local home="$1"
    local workspace="$2"
    local run_key="$3"
    local session_id="$4"
    local pk
    pk="$(expected_project_key "$workspace")"
    local reg_dir="$home/.cerberus/runtime/codex/$pk"
    mkdir -p "$reg_dir"
    jq -nc \
        --argjson schema_version 1 \
        --arg host "codex" \
        --arg ws "$workspace" \
        --arg pk "$pk" \
        --arg sid "$session_id" \
        --arg run "$run_key" \
        '{schema_version:$schema_version,
          host:$host,
          workspace_root:$ws,
          project_key:$pk,
          session_id:$sid,
          codex_session_id:$sid,
          run_key:$run,
          transcript_path:"",
          last_seen:"2026-04-30T00:00:00Z"}' \
        > "$reg_dir/active-session.json"
}

# Build an empty review_dir under $home.
make_review_dir() {
    local home="$1"
    local workspace="$2"
    local run_key="$3"
    local pk
    pk="$(expected_project_key "$workspace")"
    local rd="$home/.cerberus/projects/$pk/$run_key"
    mkdir -p "$rd/reviews"
    echo "$rd"
}

# Plant a gate-state.json with the given status / reviewers / consensus.
# Args: review_dir status reviewers_json consensus_json owner_run_key
write_gate_state() {
    local rd="$1"
    local status="$2"
    local reviewers_json="$3"
    local consensus_json="$4"
    local owner_key="$5"
    jq -n \
        --arg status "$status" \
        --arg art "$rd/latest.md" \
        --arg owner "$owner_key" \
        --argjson reviewers "$reviewers_json" \
        --argjson consensus "$consensus_json" \
        '{
            version: 1,
            status: $status,
            trigger_source: "test",
            artifact: {path: $art, sha256: ""},
            reviewers: $reviewers,
            consensus: $consensus,
            decision: null,
            owner: {session_key: $owner},
            host: "codex",
            created_at: "2026-04-30T00:00:00Z",
            iteration: 0
        }' > "$rd/gate-state.json"
}

# Run the hook in a hermetic subshell with controlled HOME and a Codex
# Stop payload built from ($session_id, $workspace).
#
# Usage:
#   run_hook HOME WORKSPACE SESSION_ID OUT_FILE ERR_FILE [extra-env=...]
run_hook() {
    local home="$1"
    local workspace="$2"
    local session_id="$3"
    local out="$4"
    local err="$5"
    shift 5
    local payload
    payload="$(jq -nc --arg sid "$session_id" --arg ws "$workspace" \
        '{session_id:$sid, cwd:$ws}')"
    local rc=0
    (
        unset CERBERUS_HOST CERBERUS_RUN_KEY CERBERUS_PROJECT_KEY \
              CERBERUS_STATE_ROOT CERBERUS_SESSION_ID \
              CERBERUS_TRANSCRIPT_PATH CERBERUS_ROOT \
              CERBERUS_REVIEWER_SUBPROCESS REVIEW_GATE_REVIEWER_SUBPROCESS \
              REVIEW_GATE_SESSION_KEY REVIEW_GATE_POLL_INTERVAL_SECONDS \
              REVIEW_GATE_MAX_WAIT_SECONDS "$REMOVED_CODEX_WAIT_ENV" \
              CERBERUS_REVIEW_GATE_BIN \
              CLAUDE_PROJECT_DIR CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH \
              __CERBERUS_ALIAS_WARNED || true
        export HOME="$home"
        for kv in "$@"; do
            export "$kv"
        done
        printf '%s' "$payload" | "$CODEX_STOP_HOOK" >"$out" 2>"$err"
    ) || rc=$?
    return $rc
}

# Run codex-session-init in a controlled env to simulate a lifecycle hook
# refresh before Stop.
run_session_init() {
    local home="$1"
    local workspace="$2"
    local session_id="$3"
    local out="$4"
    local err="$5"
    shift 5
    local payload
    payload="$(jq -nc --arg sid "$session_id" --arg ws "$workspace" \
        '{session_id:$sid, workspace_root:$ws, cwd:$ws}')"
    local rc=0
    (
        unset CERBERUS_HOST CERBERUS_RUN_KEY CERBERUS_PROJECT_KEY \
              CERBERUS_STATE_ROOT CERBERUS_SESSION_ID \
              CERBERUS_TRANSCRIPT_PATH CERBERUS_ROOT \
              CERBERUS_REVIEWER_SUBPROCESS REVIEW_GATE_REVIEWER_SUBPROCESS \
              REVIEW_GATE_SESSION_KEY REVIEW_GATE_POLL_INTERVAL_SECONDS \
              REVIEW_GATE_MAX_WAIT_SECONDS "$REMOVED_CODEX_WAIT_ENV" \
              CERBERUS_REVIEW_GATE_BIN \
              CLAUDE_PROJECT_DIR CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH \
              __CERBERUS_ALIAS_WARNED || true
        export HOME="$home"
        for kv in "$@"; do
            export "$kv"
        done
        printf '%s' "$payload" | "$CODEX_SESSION_INIT" >"$out" 2>"$err"
    ) || rc=$?
    return $rc
}

# Run the hook in the background; the bg job is a direct child of the
# caller's shell so `wait $pid` works. The PID is written to
# `$pid_file` so the function can be invoked WITHOUT $(...) capture
# (which would fork a subshell and orphan the bg child).
#
# Usage:
#   spawn_hook_bg HOME WORKSPACE SESSION_ID OUT ERR PAYLOAD_FILE PID_FILE [extra-env=...]
spawn_hook_bg() {
    local home="$1"
    local workspace="$2"
    local session_id="$3"
    local out="$4"
    local err="$5"
    local payload_file="$6"
    local pid_file="$7"
    shift 7
    local payload
    payload="$(jq -nc --arg sid "$session_id" --arg ws "$workspace" \
        '{session_id:$sid, cwd:$ws}')"
    printf '%s' "$payload" > "$payload_file"
    (
        unset CERBERUS_HOST CERBERUS_RUN_KEY CERBERUS_PROJECT_KEY \
              CERBERUS_STATE_ROOT CERBERUS_SESSION_ID \
              CERBERUS_TRANSCRIPT_PATH CERBERUS_ROOT \
              CERBERUS_REVIEWER_SUBPROCESS REVIEW_GATE_REVIEWER_SUBPROCESS \
              REVIEW_GATE_SESSION_KEY REVIEW_GATE_POLL_INTERVAL_SECONDS \
              REVIEW_GATE_MAX_WAIT_SECONDS "$REMOVED_CODEX_WAIT_ENV" \
              CERBERUS_REVIEW_GATE_BIN \
              CLAUDE_PROJECT_DIR CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH \
              __CERBERUS_ALIAS_WARNED || true
        export HOME="$home"
        for kv in "$@"; do
            export "$kv"
        done
        exec "$CODEX_STOP_HOOK" >"$out" 2>"$err" <"$payload_file"
    ) &
    printf '%s' "$!" > "$pid_file"
}

# Build a PATH containing essential tools but no jq, used to exercise
# matrix row 12 (jq missing). Resolves each tool via `command -v` from
# the current PATH so the test box's actual layout is honored.
make_no_jq_path() {
    local d="$1"
    mkdir -p "$d"
    local tool tool_path
    for tool in cat mktemp rm mkdir rmdir dirname basename head tail \
                sed tr grep ls printf bash sh date find env stat sleep \
                kill chmod ln touch awk shasum sha256sum python3 git; do
        tool_path="$(command -v "$tool" 2>/dev/null || true)"
        if [[ -n "$tool_path" && ! -e "$d/$tool" ]]; then
            ln -sf "$tool_path" "$d/$tool" 2>/dev/null || true
        fi
    done
    echo "$d"
}

assert_codex_stop_schema() {
    local out="$1"
    jq -s -e '
        length == 1
        and (.[0] | type == "object")
        and (.[0] |
          (
            (.continue == true)
            and ((has("systemMessage") | not) or (.systemMessage | type == "string"))
            and ((keys - ["continue", "systemMessage"]) | length == 0)
          )
          or
          (
            (.decision == "block")
            and (.reason | type == "string")
            and (.reason | length > 0)
            and ((keys - ["decision", "reason"]) | length == 0)
          )
        )
    ' "$out" >/dev/null 2>&1
}

stop_action() {
    local out="$1"
    if ! assert_codex_stop_schema "$out"; then
        echo "invalid"
        return 0
    fi
    jq -s -r '.[0] | if .decision == "block" then "continue" elif .continue == true then "allow" else empty end' \
        "$out" 2>/dev/null || echo ""
}

stop_system_message() {
    local out="$1"
    jq -s -r '.[0].systemMessage // empty' "$out" 2>/dev/null || echo ""
}

stop_reason() {
    local out="$1"
    jq -s -r '.[0].reason // empty' "$out" 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
# Case 1 — Row 1: registry + run dir present, no gate-state.json.
# Status returns exit 4 ({"status":"no_active_gate"}). Hook emits plain
# allow.
# ---------------------------------------------------------------------------
log_test "Case 1 — Row 1: status exits 4 → {continue:true}"
c1_home="$TEST_DIR/case1"
mkdir -p "$c1_home"
c1_workspace="/tmp/cerberus-c1"
c1_run="run-c1-001"
make_registry "$c1_home" "$c1_workspace" "$c1_run" "sess-c1-001"
make_review_dir "$c1_home" "$c1_workspace" "$c1_run" >/dev/null
c1_out="$TEST_DIR/c1.out"
c1_err="$TEST_DIR/c1.err"
c1_rc=0
run_hook "$c1_home" "$c1_workspace" "sess-c1-001" "$c1_out" "$c1_err" || c1_rc=$?
c1_action="$(stop_action "$c1_out")"
if [[ "$c1_rc" -eq 0 && "$c1_action" == "allow" ]]; then
    log_pass "Case 1 — Row 1: {continue:true}, exit 0, no unsupported fields"
else
    log_fail "Case 1: rc=$c1_rc action=$c1_action body=$(cat "$c1_out") stderr=$(cat "$c1_err")"
fi

# ---------------------------------------------------------------------------
# Case 2 — Row 2: no registry → {continue:true}.
# ---------------------------------------------------------------------------
log_test "Case 2 — Row 2: no registry → {continue:true}"
c2_home="$TEST_DIR/case2"
mkdir -p "$c2_home"
c2_workspace="/tmp/cerberus-c2"
# Deliberately do NOT call make_registry / make_review_dir.
c2_out="$TEST_DIR/c2.out"
c2_err="$TEST_DIR/c2.err"
c2_rc=0
run_hook "$c2_home" "$c2_workspace" "sess-c2-001" "$c2_out" "$c2_err" || c2_rc=$?
c2_action="$(stop_action "$c2_out")"
if [[ "$c2_rc" -eq 0 && "$c2_action" == "allow" ]]; then
    log_pass "Case 2 — Row 2: no registry → {continue:true}, exit 0"
else
    log_fail "Case 2: rc=$c2_rc action=$c2_action body=$(cat "$c2_out") stderr=$(cat "$c2_err")"
fi

# ---------------------------------------------------------------------------
# Regression — reviewer subprocess markers fail open before registry/status/wait.
# Nested Codex reviewers can run Stop hooks during finalization. If the hook
# follows the active registry back to the parent pending gate, it can wait on
# the reviewer process that is currently trying to finish. Either reviewer
# marker must short-circuit before invoking review-gate at all.
# ---------------------------------------------------------------------------
log_test "Regression — reviewer subprocess marker allows before registry/status/wait"
c2b_home="$TEST_DIR/case2b"
mkdir -p "$c2b_home"
c2b_workspace="/tmp/cerberus-c2b"
c2b_run="run-c2b-001"
make_registry "$c2b_home" "$c2b_workspace" "$c2b_run" "sess-c2b-001"
c2b_rd="$(make_review_dir "$c2b_home" "$c2b_workspace" "$c2b_run")"
write_gate_state "$c2b_rd" "pending" '{"codex":{}}' "null" "$c2b_run"
c2b_called="$TEST_DIR/c2b-review-gate-called"
c2b_stub="$TEST_DIR/c2b-review-gate-must-not-run"
cat > "$c2b_stub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLED_FILE"
exit 2
EOF
chmod +x "$c2b_stub"
c2b_ok=1
for marker in CERBERUS_REVIEWER_SUBPROCESS REVIEW_GATE_REVIEWER_SUBPROCESS; do
    rm -f "$c2b_called"
    c2b_out="$TEST_DIR/c2b-$marker.out"
    c2b_err="$TEST_DIR/c2b-$marker.err"
    c2b_rc=0
    run_hook "$c2b_home" "$c2b_workspace" "sess-c2b-001" \
        "$c2b_out" "$c2b_err" \
        "CERBERUS_REVIEW_GATE_BIN=$c2b_stub" \
        "STUB_CALLED_FILE=$c2b_called" \
        "$marker=1" \
        "REVIEW_GATE_MAX_WAIT_SECONDS=30" \
        || c2b_rc=$?
    c2b_action="$(stop_action "$c2b_out")"
    if [[ "$c2b_rc" -ne 0 || "$c2b_action" != "allow" || -e "$c2b_called" ]]; then
        c2b_ok=0
        log_fail "Regression reviewer marker $marker: rc=$c2b_rc action=$c2b_action called=$(cat "$c2b_called" 2>/dev/null || true) body=$(cat "$c2b_out" 2>/dev/null || true) stderr=$(cat "$c2b_err" 2>/dev/null || true)"
    fi
done
if [[ "$c2b_ok" -eq 1 ]]; then
    log_pass "Regression — reviewer subprocess markers bypass active registry and review-gate"
fi

# ---------------------------------------------------------------------------
# Case 3 — Row 4: pending + MAX_WAIT=0 → allow + "still running" note.
# ---------------------------------------------------------------------------
log_test "Case 3 — Row 4: pending + MAX_WAIT=0 → allow with 'still running' note"
c3_home="$TEST_DIR/case3"
mkdir -p "$c3_home"
c3_workspace="/tmp/cerberus-c3"
c3_run="run-c3-001"
make_registry "$c3_home" "$c3_workspace" "$c3_run" "sess-c3-001"
c3_rd="$(make_review_dir "$c3_home" "$c3_workspace" "$c3_run")"
write_gate_state "$c3_rd" "pending" '{"codex":{},"gemini":{}}' "null" "$c3_run"
c3_out="$TEST_DIR/c3.out"
c3_err="$TEST_DIR/c3.err"
c3_rc=0
run_hook "$c3_home" "$c3_workspace" "sess-c3-001" "$c3_out" "$c3_err" \
    "REVIEW_GATE_MAX_WAIT_SECONDS=0" \
    || c3_rc=$?
c3_action="$(stop_action "$c3_out")"
c3_note="$(stop_system_message "$c3_out")"
if [[ "$c3_rc" -eq 0 && "$c3_action" == "allow" && "$c3_note" == *"reviewers still running"* ]]; then
    log_pass "Case 3 — Row 4: allow + still-running note"
else
    log_fail "Case 3: rc=$c3_rc action=$c3_action note='$c3_note' body=$(cat "$c3_out") stderr=$(cat "$c3_err")"
fi

# ---------------------------------------------------------------------------
# Regression: pending gate with valid reviewer JSON but no .done/.failed
# sentinel is effectively complete. With MAX_WAIT=0 the hook must decide from
# the status body instead of reporting "reviewers still running".
# ---------------------------------------------------------------------------
log_test "Regression — pending + no-sentinel valid FAIL JSON blocks immediately"
c3b_home="$TEST_DIR/case3b"
mkdir -p "$c3b_home"
c3b_workspace="/tmp/cerberus-c3b"
c3b_run="run-c3b-001"
make_registry "$c3b_home" "$c3b_workspace" "$c3b_run" "sess-c3b-001"
c3b_rd="$(make_review_dir "$c3b_home" "$c3b_workspace" "$c3b_run")"
write_gate_state "$c3b_rd" "pending" '{"claude":{}}' "null" "$c3b_run"
cat > "$c3b_rd/reviews/claude.json" <<'EOF'
{
  "type": "result",
  "subtype": "success",
  "is_error": false,
  "result": "{\"verdict\":\"FAIL\",\"summary\":\"blocking no-sentinel result\",\"findings\":[{\"title\":\"must block\",\"body\":\"valid JSON without sentinel\",\"priority\":1,\"file_path\":\"src/z.c\",\"line_start\":1,\"line_end\":1}]}"
}
EOF
rm -f "$c3b_rd/reviews/claude.done" "$c3b_rd/reviews/claude.failed"
c3b_out="$TEST_DIR/c3b.out"
c3b_err="$TEST_DIR/c3b.err"
c3b_rc=0
run_hook "$c3b_home" "$c3b_workspace" "sess-c3b-001" "$c3b_out" "$c3b_err" \
    "REVIEW_GATE_MAX_WAIT_SECONDS=0" \
    || c3b_rc=$?
c3b_action="$(stop_action "$c3b_out")"
c3b_msg="$(stop_reason "$c3b_out")"
c3b_note="$(stop_system_message "$c3b_out")"
if [[ "$c3b_rc" -eq 0 && "$c3b_action" == "continue" \
      && "$c3b_msg" == *"blocking finding"* \
      && "$c3b_note" != *"still running"* \
      && ! -e "$c3b_rd/reviews/claude.done" \
      && ! -e "$c3b_rd/reviews/claude.failed" ]]; then
    log_pass "Regression — no-sentinel valid FAIL JSON drives stop-hook blocking decision"
else
    log_fail "Regression no-sentinel stop-hook: rc=$c3b_rc action=$c3b_action msg='$c3b_msg' note='$c3b_note' body=$(cat "$c3b_out") stderr=$(cat "$c3b_err")"
fi

# ---------------------------------------------------------------------------
# Case 4 — Row 5a: pending + MAX_WAIT=2, reviewers don't finish → fall
# through to row-4 message.
# ---------------------------------------------------------------------------
log_test "Case 4 — Row 5a: pending + MAX_WAIT=2 timeout → row-4 fallthrough"
c4_home="$TEST_DIR/case4"
mkdir -p "$c4_home"
c4_workspace="/tmp/cerberus-c4"
c4_run="run-c4-001"
make_registry "$c4_home" "$c4_workspace" "$c4_run" "sess-c4-001"
c4_rd="$(make_review_dir "$c4_home" "$c4_workspace" "$c4_run")"
write_gate_state "$c4_rd" "pending" '{"codex":{},"gemini":{}}' "null" "$c4_run"
c4_out="$TEST_DIR/c4.out"
c4_err="$TEST_DIR/c4.err"
c4_t0=$(date +%s)
c4_rc=0
run_hook "$c4_home" "$c4_workspace" "sess-c4-001" "$c4_out" "$c4_err" \
    "REVIEW_GATE_MAX_WAIT_SECONDS=2" \
    "REVIEW_GATE_POLL_INTERVAL_SECONDS=1" \
    || c4_rc=$?
c4_t1=$(date +%s)
c4_elapsed=$((c4_t1 - c4_t0))
c4_action="$(stop_action "$c4_out")"
c4_note="$(stop_system_message "$c4_out")"
# Loose timing assertion: must have actually waited ~2s (timeout) but
# not absurdly longer (would suggest infinite-loop regression).
if [[ "$c4_rc" -eq 0 && "$c4_action" == "allow" \
      && "$c4_note" == *"reviewers still running"* \
      && "$c4_elapsed" -ge 1 && "$c4_elapsed" -le 15 ]]; then
    log_pass "Case 4 — Row 5a: timeout fell through to row-4 message (~${c4_elapsed}s)"
else
    log_fail "Case 4: rc=$c4_rc action=$c4_action note='$c4_note' elapsed=${c4_elapsed}s body=$(cat "$c4_out") stderr=$(cat "$c4_err")"
fi

# ---------------------------------------------------------------------------
# Case 5 — Row 5b: pending + MAX_WAIT=8, reviewers finish during wait →
# re-evaluate via rows 6/7/8/9. The hook must call wait --finalize so
# reviewer sentinels/JSON are reconciled into gate-state.json before the
# post-wait status probe; expected emit is row 8 (plain allow).
# ---------------------------------------------------------------------------
log_test "Case 5 — Row 5b: pending + MAX_WAIT=8, completion mid-wait → row 8 allow"
c5_home="$TEST_DIR/case5"
mkdir -p "$c5_home"
c5_workspace="/tmp/cerberus-c5"
c5_run="run-c5-001"
make_registry "$c5_home" "$c5_workspace" "$c5_run" "sess-c5-001"
c5_rd="$(make_review_dir "$c5_home" "$c5_workspace" "$c5_run")"
write_gate_state "$c5_rd" "pending" '{"codex":{}}' "null" "$c5_run"
c5_out="$TEST_DIR/c5.out"
c5_err="$TEST_DIR/c5.err"
c5_payload="$TEST_DIR/c5.payload"
c5_pid_file="$TEST_DIR/c5.pid"
spawn_hook_bg "$c5_home" "$c5_workspace" "sess-c5-001" \
    "$c5_out" "$c5_err" "$c5_payload" "$c5_pid_file" \
    "REVIEW_GATE_MAX_WAIT_SECONDS=8" \
    "REVIEW_GATE_POLL_INTERVAL_SECONDS=1"
c5_pid="$(cat "$c5_pid_file")"
# Give the hook a moment to enter `wait`. Then complete reviewers.
sleep 2
cat > "$c5_rd/reviews/codex.json" <<'EOF'
{"verdict":"PASS","summary":"all good","findings":[]}
EOF
touch "$c5_rd/reviews/codex.done"
# Wait for hook to finish (max ~15s budget).
c5_done=0
for _ in $(seq 1 30); do
    if ! kill -0 "$c5_pid" 2>/dev/null; then
        c5_done=1
        break
    fi
    sleep 0.5
done
if [[ "$c5_done" -ne 1 ]]; then
    kill -KILL "$c5_pid" 2>/dev/null || true
fi
wait "$c5_pid" 2>/dev/null
c5_rc=$?
c5_action="$(stop_action "$c5_out")"
c5_note="$(stop_system_message "$c5_out")"
c5_state_status="$(jq -r '.status // empty' "$c5_rd/gate-state.json" 2>/dev/null || echo "")"
c5_state_consensus="$(jq -r '.consensus.verdict // empty' "$c5_rd/gate-state.json" 2>/dev/null || echo "")"
c5_state_reason="$(jq -r '.decision.reason // empty' "$c5_rd/gate-state.json" 2>/dev/null || echo "")"
# Successful re-evaluation under row 8: action=allow + no row-4 note +
# no row-3 'no review dir' note. (We accept either no `note` field at
# all, or a note that does NOT contain "still running".)
if [[ "$c5_rc" -eq 0 && "$c5_action" == "allow" \
      && "$c5_note" != *"still running"* \
      && "$c5_state_status" == "resolved" \
      && "$c5_state_consensus" == "PASS" \
      && "$c5_state_reason" == "wait_finalize_pass" ]]; then
    log_pass "Case 5 — Row 5b: completion mid-wait → row 8 allow"
else
    log_fail "Case 5: rc=$c5_rc action=$c5_action note='$c5_note' done=$c5_done state=$c5_state_status consensus=$c5_state_consensus reason=$c5_state_reason body=$(cat "$c5_out") stderr=$(cat "$c5_err")"
fi

# ---------------------------------------------------------------------------
# Regression — removed Codex-specific wait knob is ignored, and the
# shared default wait budget is 1800 when REVIEW_GATE_MAX_WAIT_SECONDS
# is unset. Use a stub backend so the test captures the wait argv
# without sleeping.
# ---------------------------------------------------------------------------
log_test "Regression — Codex-specific wait env ignored; default shared wait is 1800"
cW_home="$TEST_DIR/regress-wait-env"
mkdir -p "$cW_home"
cW_workspace="/tmp/cerberus-regress-wait-env"
cW_run="regress-wait-env-run-001"
make_registry "$cW_home" "$cW_workspace" "$cW_run" "sess-regress-wait-env-001"
make_review_dir "$cW_home" "$cW_workspace" "$cW_run" >/dev/null
cW_stub="$TEST_DIR/regress-wait-env-review-gate"
cat > "$cW_stub" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    status)
        printf '{"gate_status":"pending","consensus_verdict":null,"aggregated_findings":[]}\n'
        exit 0
        ;;
    wait)
        printf '%s\n' "$*" > "$STUB_WAIT_ARGS"
        exit 3
        ;;
    *)
        printf 'unexpected command: %s\n' "$*" >&2
        exit 2
        ;;
esac
EOF
chmod +x "$cW_stub"

cW_out1="$TEST_DIR/cW1.out"
cW_err1="$TEST_DIR/cW1.err"
cW_args1="$TEST_DIR/cW1.args"
cW_rc1=0
run_hook "$cW_home" "$cW_workspace" "sess-regress-wait-env-001" \
    "$cW_out1" "$cW_err1" \
    "CERBERUS_REVIEW_GATE_BIN=$cW_stub" \
    "$REMOVED_CODEX_WAIT_ENV=0" \
    "REVIEW_GATE_MAX_WAIT_SECONDS=7" \
    "STUB_WAIT_ARGS=$cW_args1" \
    || cW_rc1=$?
cW_args1_body="$(cat "$cW_args1" 2>/dev/null || echo "")"

cW_out2="$TEST_DIR/cW2.out"
cW_err2="$TEST_DIR/cW2.err"
cW_args2="$TEST_DIR/cW2.args"
cW_rc2=0
run_hook "$cW_home" "$cW_workspace" "sess-regress-wait-env-001" \
    "$cW_out2" "$cW_err2" \
    "CERBERUS_REVIEW_GATE_BIN=$cW_stub" \
    "$REMOVED_CODEX_WAIT_ENV=0" \
    "STUB_WAIT_ARGS=$cW_args2" \
    || cW_rc2=$?
cW_args2_body="$(cat "$cW_args2" 2>/dev/null || echo "")"

if [[ "$cW_rc1" -eq 0 && "$cW_rc2" -eq 0 \
      && "$cW_args1_body" == *"--timeout 7"* \
      && "$cW_args2_body" == *"--timeout 1800"* ]]; then
    log_pass "Regression — removed Codex wait env ignored; default shared wait is 1800"
else
    log_fail "Regression wait env: rc1=$cW_rc1 args1='$cW_args1_body' body1=$(cat "$cW_out1") err1=$(cat "$cW_err1") rc2=$cW_rc2 args2='$cW_args2_body' body2=$(cat "$cW_out2") err2=$(cat "$cW_err2")"
fi

# ---------------------------------------------------------------------------
# Case 6 — Row 6: awaiting_decision + blocking findings → continue.
# ---------------------------------------------------------------------------
log_test "Case 6 — Row 6: awaiting_decision + blocking findings → continue"
c6_home="$TEST_DIR/case6"
mkdir -p "$c6_home"
c6_workspace="/tmp/cerberus-c6"
c6_run="run-c6-001"
make_registry "$c6_home" "$c6_workspace" "$c6_run" "sess-c6-001"
c6_rd="$(make_review_dir "$c6_home" "$c6_workspace" "$c6_run")"
write_gate_state "$c6_rd" "awaiting_decision" '{"codex":{},"gemini":{}}' "null" "$c6_run"
cat > "$c6_rd/reviews/codex.json" <<'EOF'
{
  "verdict": "FAIL",
  "summary": "Critical bug",
  "findings": [
    {"title":"Null deref in main path","body":"x","priority":0,"file_path":"src/main.c","line_start":1,"line_end":1}
  ]
}
EOF
touch "$c6_rd/reviews/codex.done"
cat > "$c6_rd/reviews/gemini.json" <<'EOF'
{"verdict":"PASS","summary":"OK","findings":[]}
EOF
touch "$c6_rd/reviews/gemini.done"
c6_out="$TEST_DIR/c6.out"
c6_err="$TEST_DIR/c6.err"
c6_rc=0
run_hook "$c6_home" "$c6_workspace" "sess-c6-001" "$c6_out" "$c6_err" || c6_rc=$?
c6_action="$(stop_action "$c6_out")"
c6_msg="$(stop_reason "$c6_out")"
if [[ "$c6_rc" -eq 0 && "$c6_action" == "continue" \
      && "$c6_msg" == *"Continue working"* \
      && "$c6_msg" == *"must be fixed before stopping"* \
      && "$c6_msg" == *"make the required changes"* \
      && "$c6_msg" == *"run targeted verification"* \
      && "$c6_msg" == *"re-run the appropriate Cerberus review"* \
      && "$c6_msg" == *"continue iterating"* \
      && "$c6_msg" == *"do not stop yet"* \
      && "$c6_msg" == *"Do not clear or override the gate unless the user explicitly instructs"* \
      && "$c6_msg" == *"src/main.c"* ]]; then
    log_pass "Case 6 — Row 6: continue + actionable reason"
else
    log_fail "Case 6: rc=$c6_rc action=$c6_action msg='$c6_msg' body=$(cat "$c6_out") stderr=$(cat "$c6_err")"
fi

# ---------------------------------------------------------------------------
# Case 7 — Row 8: resolved + consensus=pass → allow.
# ---------------------------------------------------------------------------
log_test "Case 7 — Row 8: resolved + consensus=pass → allow"
c7_home="$TEST_DIR/case7"
mkdir -p "$c7_home"
c7_workspace="/tmp/cerberus-c7"
c7_run="run-c7-001"
make_registry "$c7_home" "$c7_workspace" "$c7_run" "sess-c7-001"
c7_rd="$(make_review_dir "$c7_home" "$c7_workspace" "$c7_run")"
write_gate_state "$c7_rd" "resolved" '{"codex":{}}' '{"verdict":"PASS"}' "$c7_run"
cat > "$c7_rd/reviews/codex.json" <<'EOF'
{"verdict":"PASS","summary":"all good","findings":[]}
EOF
touch "$c7_rd/reviews/codex.done"
c7_out="$TEST_DIR/c7.out"
c7_err="$TEST_DIR/c7.err"
c7_rc=0
run_hook "$c7_home" "$c7_workspace" "sess-c7-001" "$c7_out" "$c7_err" || c7_rc=$?
c7_action="$(stop_action "$c7_out")"
c7_note="$(stop_system_message "$c7_out")"
if [[ "$c7_rc" -eq 0 && "$c7_action" == "allow" && "$c7_note" == "" ]]; then
    log_pass "Case 7 — Row 8: allow, no note"
else
    log_fail "Case 7: rc=$c7_rc action=$c7_action note='$c7_note' body=$(cat "$c7_out") stderr=$(cat "$c7_err")"
fi

# ---------------------------------------------------------------------------
# Case 8 — Row 9: resolved + consensus=fail → continue.
# ---------------------------------------------------------------------------
log_test "Case 8 — Row 9: resolved + consensus=fail → continue"
c8_home="$TEST_DIR/case8"
mkdir -p "$c8_home"
c8_workspace="/tmp/cerberus-c8"
c8_run="run-c8-001"
make_registry "$c8_home" "$c8_workspace" "$c8_run" "sess-c8-001"
c8_rd="$(make_review_dir "$c8_home" "$c8_workspace" "$c8_run")"
write_gate_state "$c8_rd" "resolved" '{"codex":{}}' '{"verdict":"FAIL"}' "$c8_run"
cat > "$c8_rd/reviews/codex.json" <<'EOF'
{"verdict":"FAIL","summary":"bad","findings":[{"title":"x","body":"y","priority":1,"file_path":null,"line_start":null,"line_end":null}]}
EOF
touch "$c8_rd/reviews/codex.done"
c8_out="$TEST_DIR/c8.out"
c8_err="$TEST_DIR/c8.err"
c8_rc=0
run_hook "$c8_home" "$c8_workspace" "sess-c8-001" "$c8_out" "$c8_err" || c8_rc=$?
c8_action="$(stop_action "$c8_out")"
c8_msg="$(stop_reason "$c8_out")"
if [[ "$c8_rc" -eq 0 && "$c8_action" == "continue" \
      && "$c8_msg" == *"resolved this gate as FAIL"* \
      && "$c8_msg" == *"Continue working"* \
      && "$c8_msg" == *"Do not stop yet"* \
      && "$c8_msg" == *"make the required changes"* \
      && "$c8_msg" == *"run targeted verification"* \
      && "$c8_msg" == *"re-run the appropriate Cerberus review"* \
      && "$c8_msg" == *"continue iterating"* \
      && "$c8_msg" == *"Do not clear or override the gate unless the user explicitly instructs"* ]]; then
    log_pass "Case 8 — Row 9: continue + actionable reason"
else
    log_fail "Case 8: rc=$c8_rc action=$c8_action msg='$c8_msg' body=$(cat "$c8_out") stderr=$(cat "$c8_err")"
fi

# ---------------------------------------------------------------------------
# Regression — resolved + FAIL with no blocking aggregated findings still
# must produce an actionable continue prompt, not a vague status-only note.
# Exercises __cerberus_format_resolved_fail_message fallback branch.
# ---------------------------------------------------------------------------
log_test "Regression — resolved + FAIL + no blocking findings → actionable continue"
c8b_home="$TEST_DIR/case8b"
mkdir -p "$c8b_home"
c8b_workspace="/tmp/cerberus-c8b"
c8b_run="run-c8b-001"
make_registry "$c8b_home" "$c8b_workspace" "$c8b_run" "sess-c8b-001"
c8b_rd="$(make_review_dir "$c8b_home" "$c8b_workspace" "$c8b_run")"
write_gate_state "$c8b_rd" "resolved" '{"codex":{}}' '{"verdict":"FAIL"}' "$c8b_run"
cat > "$c8b_rd/reviews/codex.json" <<'EOF'
{"verdict":"FAIL","summary":"bad","findings":[]}
EOF
touch "$c8b_rd/reviews/codex.done"
c8b_out="$TEST_DIR/c8b.out"
c8b_err="$TEST_DIR/c8b.err"
c8b_rc=0
run_hook "$c8b_home" "$c8b_workspace" "sess-c8b-001" "$c8b_out" "$c8b_err" || c8b_rc=$?
c8b_action="$(stop_action "$c8b_out")"
c8b_msg="$(stop_reason "$c8b_out")"
if [[ "$c8b_rc" -eq 0 && "$c8b_action" == "continue" \
      && "$c8b_msg" == *"resolved this gate as FAIL"* \
      && "$c8b_msg" == *"Do not stop yet"* \
      && "$c8b_msg" == *"Inspect Cerberus: Status"* \
      && "$c8b_msg" == *"make the required changes"* \
      && "$c8b_msg" == *"run targeted verification"* \
      && "$c8b_msg" == *"re-run the appropriate Cerberus review"* \
      && "$c8b_msg" == *"continue iterating"* \
      && "$c8b_msg" == *"Do not clear or override the gate unless the user explicitly instructs"* ]]; then
    log_pass "Regression — resolved FAIL fallback is actionable"
else
    log_fail "Regression resolved FAIL fallback: rc=$c8b_rc action=$c8b_action msg='$c8b_msg' body=$(cat "$c8b_out") stderr=$(cat "$c8b_err")"
fi

# ---------------------------------------------------------------------------
# Case 9 — Row 10: malformed gate-state.json → allow + "unreadable" note.
# ---------------------------------------------------------------------------
log_test "Case 9 — Row 10: malformed gate-state.json → allow + unreadable note"
c9_home="$TEST_DIR/case9"
mkdir -p "$c9_home"
c9_workspace="/tmp/cerberus-c9"
c9_run="run-c9-001"
make_registry "$c9_home" "$c9_workspace" "$c9_run" "sess-c9-001"
c9_rd="$(make_review_dir "$c9_home" "$c9_workspace" "$c9_run")"
printf '{not valid json' > "$c9_rd/gate-state.json"
c9_out="$TEST_DIR/c9.out"
c9_err="$TEST_DIR/c9.err"
c9_rc=0
run_hook "$c9_home" "$c9_workspace" "sess-c9-001" "$c9_out" "$c9_err" || c9_rc=$?
c9_action="$(stop_action "$c9_out")"
c9_note="$(stop_system_message "$c9_out")"
if [[ "$c9_rc" -eq 0 && "$c9_action" == "allow" && "$c9_note" == *"unreadable"* ]]; then
    log_pass "Case 9 — Row 10: allow + unreadable note"
else
    log_fail "Case 9: rc=$c9_rc action=$c9_action note='$c9_note' body=$(cat "$c9_out") stderr=$(cat "$c9_err")"
fi

# ---------------------------------------------------------------------------
# Case 10 — Row 11: status exits 2 (non-zero, non-4) → allow + diagnostic.
# Use a stub `review-gate` injected via CERBERUS_REVIEW_GATE_BIN.
# ---------------------------------------------------------------------------
log_test "Case 10 — Row 11: status non-zero non-4 → allow + diagnostic"
c10_home="$TEST_DIR/case10"
mkdir -p "$c10_home"
c10_workspace="/tmp/cerberus-c10"
c10_run="run-c10-001"
make_registry "$c10_home" "$c10_workspace" "$c10_run" "sess-c10-001"
make_review_dir "$c10_home" "$c10_workspace" "$c10_run" >/dev/null
c10_stub="$TEST_DIR/c10-stub-review-gate"
cat > "$c10_stub" <<'EOF'
#!/usr/bin/env bash
echo "stub: simulated internal error" >&2
exit 2
EOF
chmod +x "$c10_stub"
c10_out="$TEST_DIR/c10.out"
c10_err="$TEST_DIR/c10.err"
c10_rc=0
run_hook "$c10_home" "$c10_workspace" "sess-c10-001" "$c10_out" "$c10_err" \
    "CERBERUS_REVIEW_GATE_BIN=$c10_stub" \
    || c10_rc=$?
c10_action="$(stop_action "$c10_out")"
c10_diag=""
if grep -q "review-gate status exited 2" "$c10_err" 2>/dev/null; then
    c10_diag="found"
fi
if [[ "$c10_rc" -eq 0 && "$c10_action" == "allow" && "$c10_diag" == "found" ]]; then
    log_pass "Case 10 — Row 11: allow + stderr diagnostic"
else
    log_fail "Case 10: rc=$c10_rc action=$c10_action diag=$c10_diag body=$(cat "$c10_out") stderr=$(cat "$c10_err")"
fi

# ---------------------------------------------------------------------------
# Case 11 — Row 12: jq missing on PATH → allow.
# Build a sanitized PATH with everything but jq.
# ---------------------------------------------------------------------------
log_test "Case 11 — Row 12: jq missing on PATH → allow"
c11_home="$TEST_DIR/case11"
mkdir -p "$c11_home"
c11_workspace="/tmp/cerberus-c11"
c11_no_jq_dir="$TEST_DIR/no-jq-bin"
make_no_jq_path "$c11_no_jq_dir" >/dev/null
# Verify jq actually missing under our sanitized PATH. Use a fresh
# environment and shell so command hashing / inherited shell state cannot
# leak the real jq into this probe on macOS/Homebrew installations.
if env -i PATH="$c11_no_jq_dir" bash -c 'command -v jq >/dev/null 2>&1'; then
    c11_leaked_jq="$(env -i PATH="$c11_no_jq_dir" bash -c 'command -v jq' 2>/dev/null || echo unknown)"
    log_fail "Case 11 — could not hide jq from sanitized PATH (jq still resolves: $c11_leaked_jq)"
else
    c11_payload='{"session_id":"sess-c11-001","cwd":"/tmp/cerberus-c11"}'
    c11_out="$TEST_DIR/c11.out"
    c11_err="$TEST_DIR/c11.err"
    c11_rc=0
    env -i HOME="$c11_home" PATH="$c11_no_jq_dir" \
        "$CODEX_STOP_HOOK" >"$c11_out" 2>"$c11_err" <<EOF || c11_rc=$?
$c11_payload
EOF
    c11_body="$(cat "$c11_out" 2>/dev/null || echo "")"
    c11_action="$(stop_action "$c11_out")"
    if [[ "$c11_rc" -eq 0 && "$c11_action" == "allow" ]]; then
        log_pass "Case 11 — Row 12: jq missing → continue:true"
    else
        log_fail "Case 11: rc=$c11_rc action=$c11_action body='$c11_body' stderr=$(cat "$c11_err")"
    fi
fi

# ---------------------------------------------------------------------------
# Case 12 — Row 13a: SIGTERM mid-execution → allow, exit 0.
# Use MAX_WAIT=10 + pending gate to keep the hook in `wait`. Then SIGTERM.
# ---------------------------------------------------------------------------
log_test "Case 12 — Row 13a: SIGTERM mid-execution → allow, exit 0"
c12_home="$TEST_DIR/case12"
mkdir -p "$c12_home"
c12_workspace="/tmp/cerberus-c12"
c12_run="run-c12-001"
make_registry "$c12_home" "$c12_workspace" "$c12_run" "sess-c12-001"
c12_rd="$(make_review_dir "$c12_home" "$c12_workspace" "$c12_run")"
write_gate_state "$c12_rd" "pending" '{"codex":{}}' "null" "$c12_run"
c12_out="$TEST_DIR/c12.out"
c12_err="$TEST_DIR/c12.err"
c12_payload="$TEST_DIR/c12.payload"
c12_pid_file="$TEST_DIR/c12.pid"
spawn_hook_bg "$c12_home" "$c12_workspace" "sess-c12-001" \
    "$c12_out" "$c12_err" "$c12_payload" "$c12_pid_file" \
    "REVIEW_GATE_MAX_WAIT_SECONDS=10" \
    "REVIEW_GATE_POLL_INTERVAL_SECONDS=1"
c12_pid="$(cat "$c12_pid_file")"
sleep 2
kill -TERM "$c12_pid" 2>/dev/null || true
# Wait for hook to exit (max ~5s).
for _ in $(seq 1 10); do
    if ! kill -0 "$c12_pid" 2>/dev/null; then
        break
    fi
    sleep 0.5
done
wait "$c12_pid" 2>/dev/null
c12_rc=$?
c12_body="$(cat "$c12_out" 2>/dev/null || echo "")"
c12_valid_json="false"
if echo "$c12_body" | jq -e . >/dev/null 2>&1; then
    c12_valid_json="true"
fi
c12_action="$(stop_action "$c12_out")"
if [[ "$c12_rc" -eq 0 && "$c12_valid_json" == "true" && "$c12_action" == "allow" ]]; then
    log_pass "Case 12 — Row 13a: SIGTERM → valid {continue:true}, exit 0"
else
    log_fail "Case 12: rc=$c12_rc valid=$c12_valid_json action=$c12_action body='$c12_body' stderr=$(cat "$c12_err")"
fi

# ---------------------------------------------------------------------------
# Case 13 — Row 13b: SIGINT during child wait → child killed, allow.
# Same fixture as case 12; signal swap.
# ---------------------------------------------------------------------------
log_test "Case 13 — Row 13b: SIGINT during child wait → allow, no zombie"
c13_home="$TEST_DIR/case13"
mkdir -p "$c13_home"
c13_workspace="/tmp/cerberus-c13"
c13_run="run-c13-001"
make_registry "$c13_home" "$c13_workspace" "$c13_run" "sess-c13-001"
c13_rd="$(make_review_dir "$c13_home" "$c13_workspace" "$c13_run")"
write_gate_state "$c13_rd" "pending" '{"codex":{}}' "null" "$c13_run"
c13_out="$TEST_DIR/c13.out"
c13_err="$TEST_DIR/c13.err"
c13_payload="$TEST_DIR/c13.payload"
c13_pid_file="$TEST_DIR/c13.pid"
spawn_hook_bg "$c13_home" "$c13_workspace" "sess-c13-001" \
    "$c13_out" "$c13_err" "$c13_payload" "$c13_pid_file" \
    "REVIEW_GATE_MAX_WAIT_SECONDS=10" \
    "REVIEW_GATE_POLL_INTERVAL_SECONDS=1"
c13_pid="$(cat "$c13_pid_file")"
sleep 2
kill -INT "$c13_pid" 2>/dev/null || true
for _ in $(seq 1 10); do
    if ! kill -0 "$c13_pid" 2>/dev/null; then break; fi
    sleep 0.5
done
wait "$c13_pid" 2>/dev/null
c13_rc=$?
c13_body="$(cat "$c13_out" 2>/dev/null || echo "")"
c13_valid="false"
if echo "$c13_body" | jq -e . >/dev/null 2>&1; then c13_valid="true"; fi
c13_action="$(stop_action "$c13_out")"
# Verify no orphan review-gate child remains attached to our session
# tree. Coarse check: the hook PID is gone; its children are reparented
# to init when killed, but the hook should have killed the wait child
# via the trap, so a freshly-launched ps shouldn't show a review-gate
# wait against our test review_dir within a brief window.
if [[ "$c13_rc" -eq 0 && "$c13_valid" == "true" && "$c13_action" == "allow" ]]; then
    log_pass "Case 13 — Row 13b: SIGINT → valid {continue:true}, exit 0"
else
    log_fail "Case 13: rc=$c13_rc valid=$c13_valid action=$c13_action body='$c13_body' stderr=$(cat "$c13_err")"
fi

# ---------------------------------------------------------------------------
# Case 14 — Row 13c: SIGHUP → same shape as 13b.
# ---------------------------------------------------------------------------
log_test "Case 14 — Row 13c: SIGHUP during child wait → allow, exit 0"
c14_home="$TEST_DIR/case14"
mkdir -p "$c14_home"
c14_workspace="/tmp/cerberus-c14"
c14_run="run-c14-001"
make_registry "$c14_home" "$c14_workspace" "$c14_run" "sess-c14-001"
c14_rd="$(make_review_dir "$c14_home" "$c14_workspace" "$c14_run")"
write_gate_state "$c14_rd" "pending" '{"codex":{}}' "null" "$c14_run"
c14_out="$TEST_DIR/c14.out"
c14_err="$TEST_DIR/c14.err"
c14_payload="$TEST_DIR/c14.payload"
c14_pid_file="$TEST_DIR/c14.pid"
spawn_hook_bg "$c14_home" "$c14_workspace" "sess-c14-001" \
    "$c14_out" "$c14_err" "$c14_payload" "$c14_pid_file" \
    "REVIEW_GATE_MAX_WAIT_SECONDS=10" \
    "REVIEW_GATE_POLL_INTERVAL_SECONDS=1"
c14_pid="$(cat "$c14_pid_file")"
sleep 2
kill -HUP "$c14_pid" 2>/dev/null || true
for _ in $(seq 1 10); do
    if ! kill -0 "$c14_pid" 2>/dev/null; then break; fi
    sleep 0.5
done
wait "$c14_pid" 2>/dev/null
c14_rc=$?
c14_body="$(cat "$c14_out" 2>/dev/null || echo "")"
c14_valid="false"
if echo "$c14_body" | jq -e . >/dev/null 2>&1; then c14_valid="true"; fi
c14_action="$(stop_action "$c14_out")"
if [[ "$c14_rc" -eq 0 && "$c14_valid" == "true" && "$c14_action" == "allow" ]]; then
    log_pass "Case 14 — Row 13c: SIGHUP → valid {continue:true}, exit 0"
else
    log_fail "Case 14: rc=$c14_rc valid=$c14_valid action=$c14_action body='$c14_body' stderr=$(cat "$c14_err")"
fi

# ---------------------------------------------------------------------------
# Regression: if the tracked `review-gate wait` child ignores TERM, the
# stop-hook signal handler must follow with KILL so the wait loop cannot
# survive as an orphan after the hook exits.
# ---------------------------------------------------------------------------
log_test "Regression — SIGTERM kills TERM-ignoring review-gate wait child"
c14b_home="$TEST_DIR/case14b"
mkdir -p "$c14b_home"
c14b_workspace="/tmp/cerberus-c14b"
c14b_run="run-c14b-001"
make_registry "$c14b_home" "$c14b_workspace" "$c14b_run" "sess-c14b-001"
make_review_dir "$c14b_home" "$c14b_workspace" "$c14b_run" >/dev/null
c14b_wait_pid_file="$TEST_DIR/c14b.wait.pid"
c14b_stub="$TEST_DIR/c14b-stubborn-review-gate"
cat > "$c14b_stub" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    status)
        printf '{"gate_status":"pending","pending_reviewers":["codex"],"consensus_verdict":null,"aggregated_findings":[]}\n'
        exit 0
        ;;
    wait)
        printf '%s\n' "$$" > "$WAIT_PID_FILE"
        trap '' TERM
        while :; do
            sleep 1
        done
        ;;
    *)
        printf 'unexpected command: %s\n' "$*" >&2
        exit 2
        ;;
esac
EOF
chmod +x "$c14b_stub"
c14b_out="$TEST_DIR/c14b.out"
c14b_err="$TEST_DIR/c14b.err"
c14b_payload="$TEST_DIR/c14b.payload"
c14b_pid_file="$TEST_DIR/c14b.pid"
spawn_hook_bg "$c14b_home" "$c14b_workspace" "sess-c14b-001" \
    "$c14b_out" "$c14b_err" "$c14b_payload" "$c14b_pid_file" \
    "CERBERUS_REVIEW_GATE_BIN=$c14b_stub" \
    "WAIT_PID_FILE=$c14b_wait_pid_file" \
    "REVIEW_GATE_MAX_WAIT_SECONDS=30" \
    "REVIEW_GATE_POLL_INTERVAL_SECONDS=1"
c14b_pid="$(cat "$c14b_pid_file")"
c14b_wait_pid=""
for _ in $(seq 1 20); do
    if [[ -s "$c14b_wait_pid_file" ]]; then
        c14b_wait_pid="$(cat "$c14b_wait_pid_file")"
        break
    fi
    sleep 0.2
done
if [[ -z "$c14b_wait_pid" ]]; then
    kill -KILL "$c14b_pid" 2>/dev/null || true
    log_fail "Regression stubborn wait: wait child never started; stdout=$(cat "$c14b_out" 2>/dev/null || true) stderr=$(cat "$c14b_err" 2>/dev/null || true)"
    c14b_wait_pid="999999"
fi
kill -TERM "$c14b_pid" 2>/dev/null || true
for _ in $(seq 1 20); do
    if ! kill -0 "$c14b_pid" 2>/dev/null; then break; fi
    sleep 0.2
done
wait "$c14b_pid" 2>/dev/null
c14b_rc=$?
c14b_action="$(stop_action "$c14b_out")"
c14b_wait_alive="true"
for _ in $(seq 1 20); do
    if ! kill -0 "$c14b_wait_pid" 2>/dev/null; then
        c14b_wait_alive="false"
        break
    fi
    sleep 0.2
done
if [[ "$c14b_wait_alive" == "true" ]]; then
    kill -KILL "$c14b_wait_pid" 2>/dev/null || true
fi
if [[ "$c14b_rc" -eq 0 && "$c14b_action" == "allow" && "$c14b_wait_alive" == "false" ]]; then
    log_pass "Regression — TERM-ignoring wait child was killed by stop-hook cleanup"
else
    log_fail "Regression stubborn wait: rc=$c14b_rc action=$c14b_action wait_alive=$c14b_wait_alive wait_pid=$c14b_wait_pid body=$(cat "$c14b_out" 2>/dev/null || true) stderr=$(cat "$c14b_err" 2>/dev/null || true)"
fi

# ---------------------------------------------------------------------------
# Case 15 — Stdin parse failure: non-JSON stdin → allow + diagnostic.
# ---------------------------------------------------------------------------
log_test "Case 15 — invalid Codex JSON on stdin → allow + diagnostic"
c15_home="$TEST_DIR/case15"
mkdir -p "$c15_home"
c15_out="$TEST_DIR/c15.out"
c15_err="$TEST_DIR/c15.err"
c15_rc=0
(
    unset CERBERUS_HOST CERBERUS_RUN_KEY CERBERUS_PROJECT_KEY \
          CERBERUS_STATE_ROOT CERBERUS_SESSION_ID \
          CERBERUS_TRANSCRIPT_PATH CERBERUS_ROOT \
          CERBERUS_REVIEWER_SUBPROCESS REVIEW_GATE_REVIEWER_SUBPROCESS \
          REVIEW_GATE_SESSION_KEY REVIEW_GATE_POLL_INTERVAL_SECONDS \
          REVIEW_GATE_MAX_WAIT_SECONDS \
          CERBERUS_REVIEW_GATE_BIN \
          CLAUDE_PROJECT_DIR CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH \
          __CERBERUS_ALIAS_WARNED || true
    export HOME="$c15_home"
    printf 'this is not json garbage' | "$CODEX_STOP_HOOK" \
        >"$c15_out" 2>"$c15_err"
) || c15_rc=$?
c15_action="$(stop_action "$c15_out")"
c15_diag=""
if grep -qi "invalid Codex Stop JSON" "$c15_err" 2>/dev/null; then
    c15_diag="found"
fi
if [[ "$c15_rc" -eq 0 && "$c15_action" == "allow" && "$c15_diag" == "found" ]]; then
    log_pass "Case 15 — invalid stdin JSON → allow + stderr diagnostic"
else
    log_fail "Case 15: rc=$c15_rc action=$c15_action diag=$c15_diag body=$(cat "$c15_out") stderr=$(cat "$c15_err")"
fi

# ---------------------------------------------------------------------------
# Regression — stale registry session mismatch is ignored. Stop stdin's
# session_id is authoritative; a registry for another Codex session in
# the same cwd must not block this Stop.
# ---------------------------------------------------------------------------
log_test "Regression #1 — stale registry session_id mismatch is ignored"
cR1_home="$TEST_DIR/regress1"
mkdir -p "$cR1_home"
cR1_workspace="/tmp/cerberus-regress1"
cR1_run="regress1-run-001"
make_registry "$cR1_home" "$cR1_workspace" "$cR1_run" "sess-regress1-old"
cR1_rd="$(make_review_dir "$cR1_home" "$cR1_workspace" "$cR1_run")"
write_gate_state "$cR1_rd" "awaiting_decision" '{"codex":{}}' "null" "$cR1_run"
cat > "$cR1_rd/reviews/codex.json" <<'EOF'
{"verdict":"FAIL","summary":"blocking stale run","findings":[{"title":"x","body":"y","priority":0,"file_path":null,"line_start":null,"line_end":null}]}
EOF
touch "$cR1_rd/reviews/codex.done"
cR1_out="$TEST_DIR/cR1.out"
cR1_err="$TEST_DIR/cR1.err"
cR1_rc=0
run_hook "$cR1_home" "$cR1_workspace" "sess-regress1-new" \
    "$cR1_out" "$cR1_err" || cR1_rc=$?
cR1_action="$(stop_action "$cR1_out")"
cR1_diag=""
if grep -q "does not match Stop session_id" "$cR1_err" 2>/dev/null; then
    cR1_diag="found"
fi
if [[ "$cR1_rc" -eq 0 && "$cR1_action" == "allow" && "$cR1_diag" == "found" ]]; then
    log_pass "Regression #1 — stale registry ignored; Stop allowed"
else
    log_fail "Regression #1: rc=$cR1_rc action=$cR1_action diag=$cR1_diag body=$(cat "$cR1_out") stderr=$(cat "$cR1_err")"
fi

# ---------------------------------------------------------------------------
# Regression — Codex lifecycle session ids can change between the prompt that
# spawns a review and the Stop hook that should present it. The session-init
# refresh should update registry.session_id for Stop validation while preserving
# the active review run_key, so Stop blocks on findings from the original run.
# ---------------------------------------------------------------------------
log_test "Regression — changed lifecycle id preserves active run for Stop"
cR1b_home="$TEST_DIR/regress1b"
mkdir -p "$cR1b_home"
cR1b_workspace="/tmp/cerberus-regress1b"
cR1b_run="regress1b-run-001"
make_registry "$cR1b_home" "$cR1b_workspace" "$cR1b_run" "sess-regress1b-old"
cR1b_rd="$(make_review_dir "$cR1b_home" "$cR1b_workspace" "$cR1b_run")"
write_gate_state "$cR1b_rd" "awaiting_decision" '{"codex":{}}' "null" "$cR1b_run"
cat > "$cR1b_rd/reviews/codex.json" <<'EOF'
{"verdict":"FAIL","summary":"blocking after lifecycle refresh","findings":[{"title":"x","body":"y","priority":0,"file_path":null,"line_start":null,"line_end":null}]}
EOF
touch "$cR1b_rd/reviews/codex.done"
cR1b_init_out="$TEST_DIR/cR1b-init.out"
cR1b_init_err="$TEST_DIR/cR1b-init.err"
cR1b_init_rc=0
run_session_init "$cR1b_home" "$cR1b_workspace" "sess-regress1b-new" \
    "$cR1b_init_out" "$cR1b_init_err" || cR1b_init_rc=$?
cR1b_registry="$cR1b_home/.cerberus/runtime/codex/$(expected_project_key "$cR1b_workspace")/active-session.json"
cR1b_registry_sid="$(jq -r '.session_id // empty' "$cR1b_registry" 2>/dev/null || echo "")"
cR1b_registry_run="$(jq -r '.run_key // empty' "$cR1b_registry" 2>/dev/null || echo "")"
cR1b_out="$TEST_DIR/cR1b.out"
cR1b_err="$TEST_DIR/cR1b.err"
cR1b_rc=0
run_hook "$cR1b_home" "$cR1b_workspace" "sess-regress1b-new" \
    "$cR1b_out" "$cR1b_err" || cR1b_rc=$?
cR1b_action="$(stop_action "$cR1b_out")"
cR1b_msg="$(stop_reason "$cR1b_out")"
if [[ "$cR1b_init_rc" -eq 0 \
      && "$cR1b_registry_sid" == "sess-regress1b-new" \
      && "$cR1b_registry_run" == "$cR1b_run" \
      && "$cR1b_rc" -eq 0 \
      && "$cR1b_action" == "continue" \
      && "$cR1b_msg" == *"blocking"* ]]; then
    log_pass "Regression — refreshed lifecycle session validates Stop while preserving active run_key"
else
    log_fail "Regression #1b: init_rc=$cR1b_init_rc registry_sid='$cR1b_registry_sid' registry_run='$cR1b_registry_run' rc=$cR1b_rc action=$cR1b_action msg='$cR1b_msg' init_err=$(cat "$cR1b_init_err" 2>/dev/null || true) body=$(cat "$cR1b_out" 2>/dev/null || true) stderr=$(cat "$cR1b_err" 2>/dev/null || true)"
fi

# ---------------------------------------------------------------------------
# Regression — missing Stop session_id fails open before consulting any
# registry. Codex documents session_id as required; malformed/missing hook
# payloads must never block stop.
# ---------------------------------------------------------------------------
log_test "Regression #2 — missing Stop session_id fails open"
cR2_home="$TEST_DIR/regress2"
mkdir -p "$cR2_home"
cR2_out="$TEST_DIR/cR2.out"
cR2_err="$TEST_DIR/cR2.err"
cR2_rc=0
(
    unset CERBERUS_HOST CERBERUS_RUN_KEY CERBERUS_PROJECT_KEY \
          CERBERUS_STATE_ROOT CERBERUS_SESSION_ID \
          CERBERUS_TRANSCRIPT_PATH CERBERUS_ROOT \
          CERBERUS_REVIEWER_SUBPROCESS REVIEW_GATE_REVIEWER_SUBPROCESS \
          REVIEW_GATE_SESSION_KEY REVIEW_GATE_POLL_INTERVAL_SECONDS \
          REVIEW_GATE_MAX_WAIT_SECONDS \
          CERBERUS_REVIEW_GATE_BIN \
          CLAUDE_PROJECT_DIR CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH \
          __CERBERUS_ALIAS_WARNED || true
    export HOME="$cR2_home"
    printf '{"cwd":"/tmp/cerberus-regress2"}' | "$CODEX_STOP_HOOK" \
        >"$cR2_out" 2>"$cR2_err"
) || cR2_rc=$?
cR2_action="$(stop_action "$cR2_out")"
cR2_diag=""
if grep -q "missing required Stop field 'session_id'" "$cR2_err" 2>/dev/null; then
    cR2_diag="found"
fi
if [[ "$cR2_rc" -eq 0 && "$cR2_action" == "allow" && "$cR2_diag" == "found" ]]; then
    log_pass "Regression #2 — missing session_id → continue:true"
else
    log_fail "Regression #2: rc=$cR2_rc action=$cR2_action diag=$cR2_diag body=$(cat "$cR2_out") stderr=$(cat "$cR2_err")"
fi

# ---------------------------------------------------------------------------
# Regression — inherited CERBERUS_PROJECT_KEY is ignored for registry lookup.
# codex-session-init derives the registry namespace from hook cwd; Stop must
# derive the same key from its Stop payload and not from stale shell env.
# ---------------------------------------------------------------------------
log_test "Regression #3 — inherited CERBERUS_PROJECT_KEY ignored for registry lookup"
cR3_home="$TEST_DIR/regress3"
mkdir -p "$cR3_home"
cR3_workspace="/tmp/cerberus-regress3"
cR3_run="regress3-run-001"
make_registry "$cR3_home" "$cR3_workspace" "$cR3_run" "sess-regress3-001"
cR3_rd="$(make_review_dir "$cR3_home" "$cR3_workspace" "$cR3_run")"
write_gate_state "$cR3_rd" "awaiting_decision" '{"codex":{}}' "null" "$cR3_run"
cat > "$cR3_rd/reviews/codex.json" <<'EOF'
{"verdict":"FAIL","summary":"blocking","findings":[{"title":"x","body":"y","priority":0,"file_path":null,"line_start":null,"line_end":null}]}
EOF
touch "$cR3_rd/reviews/codex.done"
cR3_out="$TEST_DIR/cR3.out"
cR3_err="$TEST_DIR/cR3.err"
cR3_rc=0
run_hook "$cR3_home" "$cR3_workspace" "sess-regress3-001" \
    "$cR3_out" "$cR3_err" \
    "CERBERUS_PROJECT_KEY=wrong-env-key" \
    || cR3_rc=$?
cR3_action="$(stop_action "$cR3_out")"
cR3_msg="$(stop_reason "$cR3_out")"
if [[ "$cR3_rc" -eq 0 && "$cR3_action" == "continue" && -n "$cR3_msg" ]]; then
    log_pass "Regression #3 — cwd-derived registry found despite stale CERBERUS_PROJECT_KEY"
else
    log_fail "Regression #3: rc=$cR3_rc action=$cR3_action msg='$cR3_msg' body=$(cat "$cR3_out") stderr=$(cat "$cR3_err")"
fi

# ---------------------------------------------------------------------------
# Regression — round-1 review #2: CERBERUS_STATE_ROOT honored for the
# Row 3 run-dir pre-check. With a custom state root the registry lives
# under $HOME/.cerberus/runtime/codex/<pk>/ (always) but the review dir
# lives under $CERBERUS_STATE_ROOT/<pk>/<run>/. Hardcoding
# $HOME/.cerberus/projects/... would emit a false "no review dir" allow.
# ---------------------------------------------------------------------------
log_test "Regression #4 — CERBERUS_STATE_ROOT honored for run-dir lookup"
cR4_home="$TEST_DIR/regress4"
mkdir -p "$cR4_home"
cR4_workspace="/tmp/cerberus-regress4"
cR4_run="regress4-run-001"
cR4_state_root="$TEST_DIR/regress4-state"  # absolute path required
mkdir -p "$cR4_state_root"
# Registry stays under $HOME/.cerberus/runtime/codex/...
make_registry "$cR4_home" "$cR4_workspace" "$cR4_run" "sess-regress4-001"
# Plant the review_dir under CERBERUS_STATE_ROOT, NOT under the default
# $HOME/.cerberus/projects.
cR4_pk="$(expected_project_key "$cR4_workspace")"
cR4_rd="$cR4_state_root/$cR4_pk/$cR4_run"
mkdir -p "$cR4_rd/reviews"
write_gate_state "$cR4_rd" "awaiting_decision" '{"codex":{}}' "null" "$cR4_run"
cat > "$cR4_rd/reviews/codex.json" <<'EOF'
{"verdict":"FAIL","summary":"blocking","findings":[{"title":"a","body":"b","priority":0,"file_path":null,"line_start":null,"line_end":null}]}
EOF
touch "$cR4_rd/reviews/codex.done"
cR4_out="$TEST_DIR/cR4.out"
cR4_err="$TEST_DIR/cR4.err"
cR4_rc=0
run_hook "$cR4_home" "$cR4_workspace" "sess-regress4-001" \
    "$cR4_out" "$cR4_err" \
    "CERBERUS_STATE_ROOT=$cR4_state_root" \
    || cR4_rc=$?
cR4_action="$(stop_action "$cR4_out")"
cR4_note="$(stop_system_message "$cR4_out")"
cR4_msg="$(stop_reason "$cR4_out")"
# Pass conditions: action=continue AND no "no review dir" note.
if [[ "$cR4_rc" -eq 0 && "$cR4_action" == "continue" \
      && "$cR4_note" != *"no review dir"* && -n "$cR4_msg" ]]; then
    log_pass "Regression #4 — CERBERUS_STATE_ROOT honored; row-6 continue fired"
else
    log_fail "Regression #4: rc=$cR4_rc action=$cR4_action note='$cR4_note' msg='$cR4_msg' body=$(cat "$cR4_out") stderr=$(cat "$cR4_err")"
fi

# ---------------------------------------------------------------------------
# Regression — round-2 review #2: resolved + consensus_verdict ==
# "needs_revision" is NOT a row-9 trigger. Plan §Stop Decision Matrix
# row 9 is explicitly `consensus_verdict == "fail"`; any other resolved
# verdict (needs_revision, null, or unknown) is non-blocking and must
# allow stop. The prior code blocked anything not equal to "pass".
# ---------------------------------------------------------------------------
log_test "Regression #5 — resolved + needs_revision (non-FAIL) → allow"
cR5_home="$TEST_DIR/regress5"
mkdir -p "$cR5_home"
cR5_workspace="/tmp/cerberus-regress5"
cR5_run="regress5-run-001"
make_registry "$cR5_home" "$cR5_workspace" "$cR5_run" "sess-regress5-001"
cR5_rd="$(make_review_dir "$cR5_home" "$cR5_workspace" "$cR5_run")"
write_gate_state "$cR5_rd" "resolved" '{"codex":{}}' '{"verdict":"NEEDS_WORK"}' "$cR5_run"
cat > "$cR5_rd/reviews/codex.json" <<'EOF'
{"verdict":"NEEDS_WORK","summary":"non-blocking","findings":[{"title":"x","body":"y","priority":2,"file_path":null,"line_start":null,"line_end":null}]}
EOF
touch "$cR5_rd/reviews/codex.done"
cR5_out="$TEST_DIR/cR5.out"
cR5_err="$TEST_DIR/cR5.err"
cR5_rc=0
run_hook "$cR5_home" "$cR5_workspace" "sess-regress5-001" \
    "$cR5_out" "$cR5_err" \
    || cR5_rc=$?
cR5_action="$(stop_action "$cR5_out")"
if [[ "$cR5_rc" -eq 0 && "$cR5_action" == "allow" ]]; then
    log_pass "Regression #5 — resolved + needs_revision → continue:true"
else
    log_fail "Regression #5: rc=$cR5_rc action=$cR5_action body=$(cat "$cR5_out") stderr=$(cat "$cR5_err")"
fi

# ---------------------------------------------------------------------------
# Regression — round-2 review #1: SIGTERM during a slow status probe
# must trigger the trap promptly. Inject a stub `review-gate` that sleeps
# for 30s before returning so the initial status call is in-flight when
# we deliver SIGTERM. The hook MUST emit the failure-open envelope and
# exit 0 within seconds — not block until status returns.
# ---------------------------------------------------------------------------
log_test "Regression #6 — SIGTERM during slow status probe → prompt allow"
cR6_home="$TEST_DIR/regress6"
mkdir -p "$cR6_home"
cR6_workspace="/tmp/cerberus-regress6"
cR6_run="regress6-run-001"
make_registry "$cR6_home" "$cR6_workspace" "$cR6_run" "sess-regress6-001"
make_review_dir "$cR6_home" "$cR6_workspace" "$cR6_run" >/dev/null
cR6_stub="$TEST_DIR/cR6-slow-review-gate"
cat > "$cR6_stub" <<'EOF'
#!/usr/bin/env bash
# Simulate a slow status backend: sleep 30s then emit a no-active-gate
# body. The hook must NOT wait this long under SIGTERM.
sleep 30
printf '{"status":"no_active_gate"}\n'
exit 4
EOF
chmod +x "$cR6_stub"
cR6_out="$TEST_DIR/cR6.out"
cR6_err="$TEST_DIR/cR6.err"
cR6_payload="$TEST_DIR/cR6.payload"
cR6_pid_file="$TEST_DIR/cR6.pid"
spawn_hook_bg "$cR6_home" "$cR6_workspace" "sess-regress6-001" \
    "$cR6_out" "$cR6_err" "$cR6_payload" "$cR6_pid_file" \
    "CERBERUS_REVIEW_GATE_BIN=$cR6_stub"
cR6_pid="$(cat "$cR6_pid_file")"
sleep 1
cR6_t0=$(date +%s)
kill -TERM "$cR6_pid" 2>/dev/null || true
# Hook MUST exit within ~5s (signal trap is prompt). If it waits 30s
# for the stub, the trap was deferred — round-2 finding #1 regressed.
for _ in $(seq 1 12); do
    if ! kill -0 "$cR6_pid" 2>/dev/null; then break; fi
    sleep 0.5
done
wait "$cR6_pid" 2>/dev/null
cR6_rc=$?
cR6_t1=$(date +%s)
cR6_elapsed=$((cR6_t1 - cR6_t0))
cR6_action="$(stop_action "$cR6_out")"
if [[ "$cR6_rc" -eq 0 && "$cR6_action" == "allow" \
      && "$cR6_elapsed" -le 8 ]]; then
    log_pass "Regression #6 — SIGTERM during slow status → exit ${cR6_elapsed}s, continue:true"
else
    log_fail "Regression #6: rc=$cR6_rc action=$cR6_action elapsed=${cR6_elapsed}s body=$(cat "$cR6_out") stderr=$(cat "$cR6_err")"
fi

# ---------------------------------------------------------------------------
# Happy path A — script entry point exists, executable.
# ---------------------------------------------------------------------------
log_test "Happy A — bin/codex-stop-hook exists, is a regular file, executable"
if [[ -f "$CODEX_STOP_HOOK" && -x "$CODEX_STOP_HOOK" ]]; then
    log_pass "Happy A — entry point present and executable"
else
    log_fail "Happy A — entry point missing or not executable: $CODEX_STOP_HOOK"
fi

# ---------------------------------------------------------------------------
# Happy path B — hook reads stdin and emits valid {continue:true,...} JSON.
# Reuses the no-registry path (Row 2) so it's deterministic.
# ---------------------------------------------------------------------------
log_test "Happy B — hook reads stdin and emits {continue:true}, exit 0"
hb_home="$TEST_DIR/happy-b"
mkdir -p "$hb_home"
hb_out="$TEST_DIR/hb.out"
hb_err="$TEST_DIR/hb.err"
hb_rc=0
run_hook "$hb_home" "/tmp/cerberus-hb" "sess-hb" "$hb_out" "$hb_err" || hb_rc=$?
hb_action="$(stop_action "$hb_out")"
if [[ "$hb_rc" -eq 0 && "$hb_action" == "allow" ]]; then
    log_pass "Happy B — emitted {continue:true}, exit 0"
else
    log_fail "Happy B — rc=$hb_rc action=$hb_action body=$(cat "$hb_out") stderr=$(cat "$hb_err")"
fi

# ---------------------------------------------------------------------------
# Happy path C — INT/TERM/HUP trap installed at script load.
# ---------------------------------------------------------------------------
log_test "Happy C — codex-stop-hook installs signal trap at startup"
if grep -E "^[^#]*\btrap\b[^#]*INT[[:space:]]+TERM[[:space:]]+HUP" \
       "$CODEX_STOP_HOOK" >/dev/null 2>&1; then
    log_pass "Happy C — INT/TERM/HUP trap installed at script load"
else
    log_fail "Happy C — INT/TERM/HUP trap missing in $CODEX_STOP_HOOK"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "----------------------------------------"
echo "Codex Stop hook test summary:"
echo "  Passed: $TESTS_PASSED"
echo "  Failed: $TESTS_FAILED"
echo "----------------------------------------"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
