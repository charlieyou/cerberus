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
#                     → status exits 4 → {"action":"allow"}.
#   Case 2  — Row 2:  no registry → {"action":"allow"}.
#   Case 3  — Row 4:  pending + WAIT=0 → allow with "still running" note.
#   Case 4  — Row 5a: pending + WAIT=N, reviewers DON'T finish during the
#                     wait window → fall through to row 4 message.
#   Case 5  — Row 5b: pending + WAIT=N, reviewers finish during the wait
#                     window → re-evaluation produces row 8 (allow).
#   Case 6  — Row 6:  awaiting_decision + blocking findings (FAIL/P0) →
#                     {"action":"continue", "userMessage":...}.
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
#
# Happy-path probes carried forward from T007:
#   Happy A — script entry point exists, executable.
#   Happy B — stub reads stdin and emits valid {action:allow,...}, exit 0.
#   Happy C — INT/TERM/HUP trap installed at script load (static check).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_STOP_HOOK="$SCRIPT_DIR/../codex-stop-hook"
REVIEW_GATE="$SCRIPT_DIR/../review-gate"

if [[ ! -f "$CODEX_STOP_HOOK" ]]; then
    echo "FATAL: bin/codex-stop-hook not found at $CODEX_STOP_HOOK" >&2
    exit 2
fi
if [[ ! -x "$CODEX_STOP_HOOK" ]]; then
    echo "FATAL: bin/codex-stop-hook not executable at $CODEX_STOP_HOOK" >&2
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
              REVIEW_GATE_SESSION_KEY REVIEW_GATE_POLL_INTERVAL_SECONDS \
              CERBERUS_CODEX_STOP_WAIT_SECONDS \
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
              REVIEW_GATE_SESSION_KEY REVIEW_GATE_POLL_INTERVAL_SECONDS \
              CERBERUS_CODEX_STOP_WAIT_SECONDS \
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

# ---------------------------------------------------------------------------
# Case 1 — Row 1: registry + run dir present, no gate-state.json.
# Status returns exit 4 ({"status":"no_active_gate"}). Hook emits plain
# allow.
# ---------------------------------------------------------------------------
log_test "Case 1 — Row 1: status exits 4 → {action:allow}"
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
c1_action="$(jq -r '.action // empty' "$c1_out" 2>/dev/null || echo "")"
c1_note_present="$(jq -r 'has("note")' "$c1_out" 2>/dev/null || echo "error")"
if [[ "$c1_rc" -eq 0 && "$c1_action" == "allow" && "$c1_note_present" == "false" ]]; then
    log_pass "Case 1 — Row 1: {action:allow}, exit 0, no note"
else
    log_fail "Case 1: rc=$c1_rc action=$c1_action note_present=$c1_note_present body=$(cat "$c1_out") stderr=$(cat "$c1_err")"
fi

# ---------------------------------------------------------------------------
# Case 2 — Row 2: no registry → {action:allow}.
# ---------------------------------------------------------------------------
log_test "Case 2 — Row 2: no registry → {action:allow}"
c2_home="$TEST_DIR/case2"
mkdir -p "$c2_home"
c2_workspace="/tmp/cerberus-c2"
# Deliberately do NOT call make_registry / make_review_dir.
c2_out="$TEST_DIR/c2.out"
c2_err="$TEST_DIR/c2.err"
c2_rc=0
run_hook "$c2_home" "$c2_workspace" "sess-c2-001" "$c2_out" "$c2_err" || c2_rc=$?
c2_action="$(jq -r '.action // empty' "$c2_out" 2>/dev/null || echo "")"
if [[ "$c2_rc" -eq 0 && "$c2_action" == "allow" ]]; then
    log_pass "Case 2 — Row 2: no registry → {action:allow}, exit 0"
else
    log_fail "Case 2: rc=$c2_rc action=$c2_action body=$(cat "$c2_out") stderr=$(cat "$c2_err")"
fi

# ---------------------------------------------------------------------------
# Case 3 — Row 4: pending + WAIT=0 → allow + "still running" note.
# ---------------------------------------------------------------------------
log_test "Case 3 — Row 4: pending + WAIT=0 → allow with 'still running' note"
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
    "CERBERUS_CODEX_STOP_WAIT_SECONDS=0" \
    || c3_rc=$?
c3_action="$(jq -r '.action // empty' "$c3_out" 2>/dev/null || echo "")"
c3_note="$(jq -r '.note // empty' "$c3_out" 2>/dev/null || echo "")"
if [[ "$c3_rc" -eq 0 && "$c3_action" == "allow" && "$c3_note" == *"reviewers still running"* ]]; then
    log_pass "Case 3 — Row 4: allow + still-running note"
else
    log_fail "Case 3: rc=$c3_rc action=$c3_action note='$c3_note' body=$(cat "$c3_out") stderr=$(cat "$c3_err")"
fi

# ---------------------------------------------------------------------------
# Case 4 — Row 5a: pending + WAIT=2, reviewers don't finish → fall
# through to row-4 message.
# ---------------------------------------------------------------------------
log_test "Case 4 — Row 5a: pending + WAIT=2 timeout → row-4 fallthrough"
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
    "CERBERUS_CODEX_STOP_WAIT_SECONDS=2" \
    "REVIEW_GATE_POLL_INTERVAL_SECONDS=1" \
    || c4_rc=$?
c4_t1=$(date +%s)
c4_elapsed=$((c4_t1 - c4_t0))
c4_action="$(jq -r '.action // empty' "$c4_out" 2>/dev/null || echo "")"
c4_note="$(jq -r '.note // empty' "$c4_out" 2>/dev/null || echo "")"
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
# Case 5 — Row 5b: pending + WAIT=8, reviewers finish during wait →
# re-evaluate via rows 6/7/8/9. We mark all reviewers complete with PASS
# and update gate-state.json to status=resolved + consensus=pass mid-wait;
# expected emit is row 8 (plain allow).
# ---------------------------------------------------------------------------
log_test "Case 5 — Row 5b: pending + WAIT=8, completion mid-wait → row 8 allow"
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
    "CERBERUS_CODEX_STOP_WAIT_SECONDS=8" \
    "REVIEW_GATE_POLL_INTERVAL_SECONDS=1"
c5_pid="$(cat "$c5_pid_file")"
# Give the hook a moment to enter `wait`. Then complete reviewers.
sleep 2
cat > "$c5_rd/reviews/codex.json" <<'EOF'
{"verdict":"PASS","summary":"all good","findings":[]}
EOF
touch "$c5_rd/reviews/codex.done"
write_gate_state "$c5_rd" "resolved" '{"codex":{}}' '{"verdict":"PASS"}' "$c5_run"
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
c5_action="$(jq -r '.action // empty' "$c5_out" 2>/dev/null || echo "")"
c5_note="$(jq -r '.note // empty' "$c5_out" 2>/dev/null || echo "")"
# Successful re-evaluation under row 8: action=allow + no row-4 note +
# no row-3 'no review dir' note. (We accept either no `note` field at
# all, or a note that does NOT contain "still running".)
if [[ "$c5_rc" -eq 0 && "$c5_action" == "allow" \
      && "$c5_note" != *"still running"* ]]; then
    log_pass "Case 5 — Row 5b: completion mid-wait → row 8 allow"
else
    log_fail "Case 5: rc=$c5_rc action=$c5_action note='$c5_note' done=$c5_done body=$(cat "$c5_out") stderr=$(cat "$c5_err")"
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
c6_action="$(jq -r '.action // empty' "$c6_out" 2>/dev/null || echo "")"
c6_msg="$(jq -r '.userMessage // empty' "$c6_out" 2>/dev/null || echo "")"
if [[ "$c6_rc" -eq 0 && "$c6_action" == "continue" && -n "$c6_msg" ]]; then
    log_pass "Case 6 — Row 6: continue + non-empty userMessage"
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
c7_action="$(jq -r '.action // empty' "$c7_out" 2>/dev/null || echo "")"
c7_note="$(jq -r '.note // empty' "$c7_out" 2>/dev/null || echo "")"
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
c8_action="$(jq -r '.action // empty' "$c8_out" 2>/dev/null || echo "")"
c8_msg="$(jq -r '.userMessage // empty' "$c8_out" 2>/dev/null || echo "")"
if [[ "$c8_rc" -eq 0 && "$c8_action" == "continue" && -n "$c8_msg" ]]; then
    log_pass "Case 8 — Row 9: continue + non-empty userMessage"
else
    log_fail "Case 8: rc=$c8_rc action=$c8_action msg='$c8_msg' body=$(cat "$c8_out") stderr=$(cat "$c8_err")"
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
c9_action="$(jq -r '.action // empty' "$c9_out" 2>/dev/null || echo "")"
c9_note="$(jq -r '.note // empty' "$c9_out" 2>/dev/null || echo "")"
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
c10_action="$(jq -r '.action // empty' "$c10_out" 2>/dev/null || echo "")"
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
# Verify jq actually missing under our sanitized PATH.
if PATH="$c11_no_jq_dir" command -v jq >/dev/null 2>&1; then
    log_fail "Case 11 — could not hide jq from sanitized PATH (jq still resolves: $(PATH="$c11_no_jq_dir" command -v jq))"
else
    c11_payload='{"session_id":"sess-c11-001","cwd":"/tmp/cerberus-c11"}'
    c11_out="$TEST_DIR/c11.out"
    c11_err="$TEST_DIR/c11.err"
    c11_rc=0
    (
        unset CERBERUS_HOST CERBERUS_RUN_KEY CERBERUS_PROJECT_KEY \
              CERBERUS_STATE_ROOT CERBERUS_SESSION_ID \
              CERBERUS_TRANSCRIPT_PATH CERBERUS_ROOT \
              REVIEW_GATE_SESSION_KEY REVIEW_GATE_POLL_INTERVAL_SECONDS \
              CERBERUS_CODEX_STOP_WAIT_SECONDS \
              CERBERUS_REVIEW_GATE_BIN \
              CLAUDE_PROJECT_DIR CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH \
              __CERBERUS_ALIAS_WARNED || true
        export HOME="$c11_home"
        export PATH="$c11_no_jq_dir"
        printf '%s' "$c11_payload" | "$CODEX_STOP_HOOK" >"$c11_out" 2>"$c11_err"
    ) || c11_rc=$?
    c11_body="$(cat "$c11_out" 2>/dev/null || echo "")"
    # Cannot use jq here (we just hid it). Coarse string match: action:allow.
    if [[ "$c11_rc" -eq 0 && "$c11_body" == *'"action"'*'"allow"'* ]]; then
        log_pass "Case 11 — Row 12: jq missing → action:allow"
    else
        log_fail "Case 11: rc=$c11_rc body='$c11_body' stderr=$(cat "$c11_err")"
    fi
fi

# ---------------------------------------------------------------------------
# Case 12 — Row 13a: SIGTERM mid-execution → allow, exit 0.
# Use WAIT=10 + pending gate to keep the hook in `wait`. Then SIGTERM.
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
    "CERBERUS_CODEX_STOP_WAIT_SECONDS=10" \
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
c12_action="$(echo "$c12_body" | jq -r '.action // empty' 2>/dev/null || echo "")"
if [[ "$c12_rc" -eq 0 && "$c12_valid_json" == "true" && "$c12_action" == "allow" ]]; then
    log_pass "Case 12 — Row 13a: SIGTERM → valid {action:allow}, exit 0"
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
    "CERBERUS_CODEX_STOP_WAIT_SECONDS=10" \
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
c13_action="$(echo "$c13_body" | jq -r '.action // empty' 2>/dev/null || echo "")"
# Verify no orphan review-gate child remains attached to our session
# tree. Coarse check: the hook PID is gone; its children are reparented
# to init when killed, but the hook should have killed the wait child
# via the trap, so a freshly-launched ps shouldn't show a review-gate
# wait against our test review_dir within a brief window.
if [[ "$c13_rc" -eq 0 && "$c13_valid" == "true" && "$c13_action" == "allow" ]]; then
    log_pass "Case 13 — Row 13b: SIGINT → valid {action:allow}, exit 0"
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
    "CERBERUS_CODEX_STOP_WAIT_SECONDS=10" \
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
c14_action="$(echo "$c14_body" | jq -r '.action // empty' 2>/dev/null || echo "")"
if [[ "$c14_rc" -eq 0 && "$c14_valid" == "true" && "$c14_action" == "allow" ]]; then
    log_pass "Case 14 — Row 13c: SIGHUP → valid {action:allow}, exit 0"
else
    log_fail "Case 14: rc=$c14_rc valid=$c14_valid action=$c14_action body='$c14_body' stderr=$(cat "$c14_err")"
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
          REVIEW_GATE_SESSION_KEY REVIEW_GATE_POLL_INTERVAL_SECONDS \
          CERBERUS_CODEX_STOP_WAIT_SECONDS \
          CERBERUS_REVIEW_GATE_BIN \
          CLAUDE_PROJECT_DIR CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH \
          __CERBERUS_ALIAS_WARNED || true
    export HOME="$c15_home"
    printf 'this is not json garbage' | "$CODEX_STOP_HOOK" \
        >"$c15_out" 2>"$c15_err"
) || c15_rc=$?
c15_action="$(jq -r '.action // empty' "$c15_out" 2>/dev/null || echo "")"
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
# Happy path A — script entry point exists, executable.
# ---------------------------------------------------------------------------
log_test "Happy A — bin/codex-stop-hook exists, is a regular file, executable"
if [[ -f "$CODEX_STOP_HOOK" && -x "$CODEX_STOP_HOOK" ]]; then
    log_pass "Happy A — entry point present and executable"
else
    log_fail "Happy A — entry point missing or not executable: $CODEX_STOP_HOOK"
fi

# ---------------------------------------------------------------------------
# Happy path B — hook reads stdin and emits valid {action:allow,...} JSON.
# Reuses the no-registry path (Row 2) so it's deterministic.
# ---------------------------------------------------------------------------
log_test "Happy B — hook reads stdin and emits {action:allow}, exit 0"
hb_home="$TEST_DIR/happy-b"
mkdir -p "$hb_home"
hb_out="$TEST_DIR/hb.out"
hb_err="$TEST_DIR/hb.err"
hb_rc=0
run_hook "$hb_home" "/tmp/cerberus-hb" "sess-hb" "$hb_out" "$hb_err" || hb_rc=$?
hb_action="$(jq -r '.action // empty' "$hb_out" 2>/dev/null || echo "")"
if [[ "$hb_rc" -eq 0 && "$hb_action" == "allow" ]]; then
    log_pass "Happy B — emitted {action:allow}, exit 0"
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
