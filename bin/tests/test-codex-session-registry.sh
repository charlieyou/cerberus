#!/usr/bin/env bash
# T008 — Phase 1 tests for bin/codex-session-init.
#
# Plan reference: §Phase 1 — Codex Tests, "test-codex-session-registry.sh"
# (plan L1136-L1149) and §Data Model, "Codex session registry" (plan
# L478-L508) plus the atomic-write algorithm (plan L509-L523).
#
# Coverage matrix (8 cases + 2 happy-path probes carried forward from
# T007). Every case is a real PASS/FAIL; no TODO scaffolds remain.
#
#   Case 1: Fresh SessionStart writes registry with all required v1
#           fields.
#   Case 2: Second SessionStart updates last_seen and preserves run_key
#           when the Codex session id is unchanged.
#   Case 3: Concurrent writes (background jobs, distinct PIDs) converge
#           to one valid JSON; final state is one of the two writers'
#           payloads (last writer wins).
#   Case 4: Registry parent directory missing → mkdir -p succeeds and
#           the registry file is written.
#   Case 5: Malformed existing registry is overwritten cleanly (no
#           read-before-write parse failure).
#   Case 6: Atomic-write invariant: kill writer between temp creation
#           and `mv` → no `active-session.json` exists; orphan tmp file
#           remains.
#   Case 7: Schema correctness: written JSON validates against the v1
#           registry schema (all required fields present and typed).
#   Case 8: Inherited CERBERUS_PROJECT_KEY is ignored; registry path is
#           derived from Codex hook cwd/workspace_root.
#
# Happy path A (carried over from T007): script entry point exists,
#   regular file, executable.
# Happy path B (carried over from T007): script reads stdin and emits
#   no error on a valid SessionStart payload (exit 0). At T008 the
#   payload also validates against the schema.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_SESSION_INIT="$SCRIPT_DIR/../codex-session-init"

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

cleanup() {
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

TEST_DIR="$(mktemp -d -t cerberus-codex-session-registry.XXXXXX)"
TEST_HOME="$TEST_DIR/home"
mkdir -p "$TEST_HOME"

log_test() { echo -e "${YELLOW}TEST:${NC} $1"; }
log_pass() { echo -e "${GREEN}PASS:${NC} $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
log_fail() { echo -e "${RED}FAIL:${NC} $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# Compute the expected registry path for a given workspace_root using
# the same transform as bin/review-gate-lib.sh `get_project_hash`.
expected_project_key() {
    local workspace_root="$1"
    echo "$workspace_root" | sed 's|^/|-|' | tr '/' '-'
}

expected_registry_path() {
    local home_dir="$1"
    local workspace_root="$2"
    local pk
    pk="$(expected_project_key "$workspace_root")"
    echo "$home_dir/.cerberus/runtime/codex/$pk/active-session.json"
}

# Run codex-session-init in a clean subshell with controlled HOME.
# Stdout/stderr captured to files in $TEST_DIR.
run_init() {
    local home_dir="$1"
    local stdin_payload="$2"
    local out_file="$3"
    local err_file="$4"
    shift 4
    local rc=0
    (
        export HOME="$home_dir"
        # Strip any inherited neutral env so tests don't accidentally
        # pick up state from the runner's shell.
        unset CERBERUS_RUN_KEY REVIEW_GATE_SESSION_KEY \
              CERBERUS_PROJECT_KEY CERBERUS_HOST CERBERUS_STATE_ROOT \
              CERBERUS_TEST_PRE_MV_SLEEP CLAUDE_PROJECT_DIR
        for kv in "$@"; do
            export "$kv"
        done
        printf '%s' "$stdin_payload" | "$CODEX_SESSION_INIT" \
            >"$out_file" 2>"$err_file"
    ) || rc=$?
    return $rc
}

# Helper: assert a JSON file has expected fields with expected values.
assert_json_field() {
    local file="$1"
    local jq_path="$2"
    local expected="$3"
    local label="$4"
    local actual
    actual="$(jq -r "$jq_path" "$file" 2>/dev/null || echo "<jq-error>")"
    if [[ "$actual" == "$expected" ]]; then
        return 0
    fi
    log_fail "$label: $jq_path expected '$expected', got '$actual'"
    return 1
}

# ---------------------------------------------------------------------------
# Case 1 — Fresh SessionStart writes registry with all required v1 fields.
# ---------------------------------------------------------------------------
log_test "Case 1 — fresh SessionStart writes registry (schema v1)"
case1_home="$TEST_DIR/case1"
mkdir -p "$case1_home"
case1_workspace="/tmp/some-codex-workspace-c1"
case1_payload="$(jq -nc \
    --arg sid "sess-c1-001" \
    --arg ws "$case1_workspace" \
    --arg tp "/tmp/transcripts/c1.jsonl" \
    '{session_id: $sid, workspace_root: $ws, transcript_path: $tp}')"
case1_out="$TEST_DIR/c1.out"
case1_err="$TEST_DIR/c1.err"
case1_rc=0
run_init "$case1_home" "$case1_payload" "$case1_out" "$case1_err" \
    || case1_rc=$?
case1_registry="$(expected_registry_path "$case1_home" "$case1_workspace")"
if [[ "$case1_rc" -ne 0 ]]; then
    log_fail "Case 1 — exit $case1_rc; stderr=$(cat "$case1_err")"
elif [[ ! -f "$case1_registry" ]]; then
    log_fail "Case 1 — registry not written at $case1_registry"
elif ! jq empty "$case1_registry" >/dev/null 2>&1; then
    log_fail "Case 1 — registry not valid JSON: $(cat "$case1_registry")"
else
    case1_ok=1
    assert_json_field "$case1_registry" '.schema_version' '1' "Case 1" \
        || case1_ok=0
    assert_json_field "$case1_registry" '.host' 'codex' "Case 1" \
        || case1_ok=0
    assert_json_field "$case1_registry" '.workspace_root' \
        "$case1_workspace" "Case 1" || case1_ok=0
    assert_json_field "$case1_registry" '.session_id' \
        'sess-c1-001' "Case 1" || case1_ok=0
    assert_json_field "$case1_registry" '.codex_session_id' \
        'sess-c1-001' "Case 1" || case1_ok=0
    assert_json_field "$case1_registry" '.run_key' \
        'sess-c1-001' "Case 1" || case1_ok=0
    assert_json_field "$case1_registry" '.transcript_path' \
        '/tmp/transcripts/c1.jsonl' "Case 1" || case1_ok=0
    expected_pk="$(expected_project_key "$case1_workspace")"
    assert_json_field "$case1_registry" '.project_key' \
        "$expected_pk" "Case 1" || case1_ok=0
    # last_seen must be a non-empty ISO 8601 UTC string.
    last_seen="$(jq -r '.last_seen' "$case1_registry")"
    if ! [[ "$last_seen" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        log_fail "Case 1 — last_seen not ISO 8601 UTC: '$last_seen'"
        case1_ok=0
    fi
    if [[ "$case1_ok" -eq 1 ]]; then
        log_pass "Case 1 — fresh SessionStart wrote registry with all v1 fields"
    fi
fi

# ---------------------------------------------------------------------------
# Case 2 — Second SessionStart updates last_seen, preserves run_key when
# Codex session id is unchanged.
# ---------------------------------------------------------------------------
log_test "Case 2 — second SessionStart updates last_seen, preserves run_key"
case2_home="$TEST_DIR/case2"
mkdir -p "$case2_home"
case2_workspace="/tmp/some-codex-workspace-c2"
case2_sid="sess-c2-007"
case2_payload="$(jq -nc \
    --arg sid "$case2_sid" \
    --arg ws "$case2_workspace" \
    '{session_id: $sid, workspace_root: $ws}')"
case2_registry="$(expected_registry_path "$case2_home" "$case2_workspace")"

# First write — caller picks an explicit run_key via env so we can
# observe it being preserved on the refresh.
run_init "$case2_home" "$case2_payload" \
    "$TEST_DIR/c2-1.out" "$TEST_DIR/c2-1.err" \
    "CERBERUS_RUN_KEY=user-explicit-run-c2"
first_run_key="$(jq -r '.run_key' "$case2_registry" 2>/dev/null || echo "")"
first_last_seen="$(jq -r '.last_seen' "$case2_registry" 2>/dev/null || echo "")"

# Force at least 1s of wall-clock between writes so last_seen will
# differ at second-precision (LAST_SEEN uses %Y-%m-%dT%H:%M:%SZ).
sleep 1.1

# Second write — same Codex session id, no env override. Should
# preserve the previously-recorded run_key.
run_init "$case2_home" "$case2_payload" \
    "$TEST_DIR/c2-2.out" "$TEST_DIR/c2-2.err"
second_run_key="$(jq -r '.run_key' "$case2_registry" 2>/dev/null || echo "")"
second_last_seen="$(jq -r '.last_seen' "$case2_registry" 2>/dev/null || echo "")"

if [[ "$first_run_key" != "user-explicit-run-c2" ]]; then
    log_fail "Case 2 — first write run_key wrong: '$first_run_key'"
elif [[ "$second_run_key" != "user-explicit-run-c2" ]]; then
    log_fail "Case 2 — second write did not preserve run_key: '$second_run_key' (expected 'user-explicit-run-c2')"
elif [[ "$first_last_seen" == "$second_last_seen" ]]; then
    log_fail "Case 2 — last_seen did not advance (both '$first_last_seen')"
else
    log_pass "Case 2 — second SessionStart preserved run_key, advanced last_seen"
fi

# ---------------------------------------------------------------------------
# Regression — lifecycle session id can change across Codex prompt turns while
# the same Cerberus gate is still active. Preserve the existing active run_key
# so the Stop hook keeps looking at the review directory that spawn created.
# ---------------------------------------------------------------------------
log_test "Regression — changed lifecycle id preserves active pending run_key"
c2b_home="$TEST_DIR/case2b"
mkdir -p "$c2b_home"
c2b_workspace="/tmp/some-codex-workspace-c2b"
c2b_pk="$(expected_project_key "$c2b_workspace")"
c2b_registry="$(expected_registry_path "$c2b_home" "$c2b_workspace")"
c2b_run="active-run-c2b"
c2b_payload_old="$(jq -nc \
    --arg sid "sess-c2b-old" \
    --arg ws "$c2b_workspace" \
    '{session_id: $sid, workspace_root: $ws}')"
c2b_payload_new="$(jq -nc \
    --arg sid "sess-c2b-new" \
    --arg ws "$c2b_workspace" \
    '{session_id: $sid, workspace_root: $ws}')"
run_init "$c2b_home" "$c2b_payload_old" \
    "$TEST_DIR/c2b-1.out" "$TEST_DIR/c2b-1.err" \
    "CERBERUS_RUN_KEY=$c2b_run"
mkdir -p "$c2b_home/.cerberus/projects/$c2b_pk/$c2b_run"
jq -n --arg status "pending" '{version:1,status:$status}' \
    > "$c2b_home/.cerberus/projects/$c2b_pk/$c2b_run/gate-state.json"
run_init "$c2b_home" "$c2b_payload_new" \
    "$TEST_DIR/c2b-2.out" "$TEST_DIR/c2b-2.err"
c2b_sid="$(jq -r '.session_id // empty' "$c2b_registry" 2>/dev/null || echo "")"
c2b_run_after="$(jq -r '.run_key // empty' "$c2b_registry" 2>/dev/null || echo "")"
if [[ "$c2b_sid" == "sess-c2b-new" && "$c2b_run_after" == "$c2b_run" ]]; then
    log_pass "Regression — active pending gate keeps prior run_key across lifecycle id change"
else
    log_fail "Regression c2b: session_id='$c2b_sid' run_key='$c2b_run_after' registry=$(cat "$c2b_registry" 2>/dev/null || true) stderr=$(cat "$TEST_DIR/c2b-2.err" 2>/dev/null || true)"
fi

# ---------------------------------------------------------------------------
# Regression — once the prior gate is resolved, a new lifecycle id may become
# the next run_key. This avoids pinning future reviews to stale completed runs.
# ---------------------------------------------------------------------------
log_test "Regression — resolved prior gate does not preserve stale run_key"
c2c_home="$TEST_DIR/case2c"
mkdir -p "$c2c_home"
c2c_workspace="/tmp/some-codex-workspace-c2c"
c2c_pk="$(expected_project_key "$c2c_workspace")"
c2c_registry="$(expected_registry_path "$c2c_home" "$c2c_workspace")"
c2c_run="resolved-run-c2c"
c2c_payload_old="$(jq -nc \
    --arg sid "sess-c2c-old" \
    --arg ws "$c2c_workspace" \
    '{session_id: $sid, workspace_root: $ws}')"
c2c_payload_new="$(jq -nc \
    --arg sid "sess-c2c-new" \
    --arg ws "$c2c_workspace" \
    '{session_id: $sid, workspace_root: $ws}')"
run_init "$c2c_home" "$c2c_payload_old" \
    "$TEST_DIR/c2c-1.out" "$TEST_DIR/c2c-1.err" \
    "CERBERUS_RUN_KEY=$c2c_run"
mkdir -p "$c2c_home/.cerberus/projects/$c2c_pk/$c2c_run"
jq -n --arg status "resolved" '{version:1,status:$status,consensus:{verdict:"PASS"}}' \
    > "$c2c_home/.cerberus/projects/$c2c_pk/$c2c_run/gate-state.json"
run_init "$c2c_home" "$c2c_payload_new" \
    "$TEST_DIR/c2c-2.out" "$TEST_DIR/c2c-2.err"
c2c_sid="$(jq -r '.session_id // empty' "$c2c_registry" 2>/dev/null || echo "")"
c2c_run_after="$(jq -r '.run_key // empty' "$c2c_registry" 2>/dev/null || echo "")"
if [[ "$c2c_sid" == "sess-c2c-new" && "$c2c_run_after" == "sess-c2c-new" ]]; then
    log_pass "Regression — resolved gate allows new lifecycle id to become run_key"
else
    log_fail "Regression c2c: session_id='$c2c_sid' run_key='$c2c_run_after' registry=$(cat "$c2c_registry" 2>/dev/null || true) stderr=$(cat "$TEST_DIR/c2c-2.err" 2>/dev/null || true)"
fi

# ---------------------------------------------------------------------------
# Regression — explicit run-key env still wins over active-gate preservation.
# ---------------------------------------------------------------------------
log_test "Regression — explicit CERBERUS_RUN_KEY overrides active-gate preservation"
c2d_home="$TEST_DIR/case2d"
mkdir -p "$c2d_home"
c2d_workspace="/tmp/some-codex-workspace-c2d"
c2d_pk="$(expected_project_key "$c2d_workspace")"
c2d_registry="$(expected_registry_path "$c2d_home" "$c2d_workspace")"
c2d_run="active-run-c2d"
c2d_explicit="explicit-new-run-c2d"
c2d_payload_old="$(jq -nc \
    --arg sid "sess-c2d-old" \
    --arg ws "$c2d_workspace" \
    '{session_id: $sid, workspace_root: $ws}')"
c2d_payload_new="$(jq -nc \
    --arg sid "sess-c2d-new" \
    --arg ws "$c2d_workspace" \
    '{session_id: $sid, workspace_root: $ws}')"
run_init "$c2d_home" "$c2d_payload_old" \
    "$TEST_DIR/c2d-1.out" "$TEST_DIR/c2d-1.err" \
    "CERBERUS_RUN_KEY=$c2d_run"
mkdir -p "$c2d_home/.cerberus/projects/$c2d_pk/$c2d_run"
jq -n --arg status "awaiting_decision" '{version:1,status:$status}' \
    > "$c2d_home/.cerberus/projects/$c2d_pk/$c2d_run/gate-state.json"
run_init "$c2d_home" "$c2d_payload_new" \
    "$TEST_DIR/c2d-2.out" "$TEST_DIR/c2d-2.err" \
    "CERBERUS_RUN_KEY=$c2d_explicit"
c2d_run_after="$(jq -r '.run_key // empty' "$c2d_registry" 2>/dev/null || echo "")"
if [[ "$c2d_run_after" == "$c2d_explicit" ]]; then
    log_pass "Regression — explicit CERBERUS_RUN_KEY wins over active-gate preservation"
else
    log_fail "Regression c2d: run_key='$c2d_run_after' registry=$(cat "$c2d_registry" 2>/dev/null || true) stderr=$(cat "$TEST_DIR/c2d-2.err" 2>/dev/null || true)"
fi

# ---------------------------------------------------------------------------
# Case 3 — Concurrent writes (distinct PIDs); final JSON valid; last
# writer wins. Both invocations use distinct stdin payloads with the
# same workspace_root so they target the same registry file.
# ---------------------------------------------------------------------------
log_test "Case 3 — concurrent writes converge to one valid JSON"
case3_home="$TEST_DIR/case3"
mkdir -p "$case3_home"
case3_workspace="/tmp/some-codex-workspace-c3"
case3_registry="$(expected_registry_path "$case3_home" "$case3_workspace")"
case3_payload_a="$(jq -nc \
    --arg sid "sess-c3-A" \
    --arg ws "$case3_workspace" \
    '{session_id: $sid, workspace_root: $ws}')"
case3_payload_b="$(jq -nc \
    --arg sid "sess-c3-B" \
    --arg ws "$case3_workspace" \
    '{session_id: $sid, workspace_root: $ws}')"

# Launch both writers in background. Each gets a distinct PID and
# therefore a distinct *.tmp.$$ filename, satisfying the plan L1013
# concurrency note.
(run_init "$case3_home" "$case3_payload_a" \
    "$TEST_DIR/c3-A.out" "$TEST_DIR/c3-A.err") &
case3_pid_a=$!
(run_init "$case3_home" "$case3_payload_b" \
    "$TEST_DIR/c3-B.out" "$TEST_DIR/c3-B.err") &
case3_pid_b=$!
wait "$case3_pid_a" 2>/dev/null || true
wait "$case3_pid_b" 2>/dev/null || true

if [[ ! -f "$case3_registry" ]]; then
    log_fail "Case 3 — no registry produced after concurrent writes"
elif ! jq empty "$case3_registry" >/dev/null 2>&1; then
    log_fail "Case 3 — registry is not valid JSON: $(cat "$case3_registry")"
else
    final_sid="$(jq -r '.session_id' "$case3_registry")"
    if [[ "$final_sid" != "sess-c3-A" && "$final_sid" != "sess-c3-B" ]]; then
        log_fail "Case 3 — final session_id '$final_sid' is neither writer's input"
    else
        # No leftover *.tmp.$$ should remain after both writers exited
        # cleanly (mv removes the temp; they did not race-kill).
        leftover_tmp=$(find "$(dirname "$case3_registry")" -maxdepth 1 \
            -name 'active-session.json.tmp.*' 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$leftover_tmp" != "0" ]]; then
            log_fail "Case 3 — leftover tmp files after clean concurrent writes: $leftover_tmp"
        else
            log_pass "Case 3 — concurrent writes converged to one valid JSON ($final_sid)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Case 4 — Registry parent directory missing → mkdir -p succeeds and
# the registry file is written.
# ---------------------------------------------------------------------------
log_test "Case 4 — registry directory missing; mkdir -p succeeds"
case4_home="$TEST_DIR/case4"
# Deliberately do NOT create $case4_home/.cerberus or any subpath; the
# script must mkdir -p the full chain.
case4_workspace="/tmp/some-codex-workspace-c4"
case4_payload="$(jq -nc \
    --arg sid "sess-c4-001" \
    --arg ws "$case4_workspace" \
    '{session_id: $sid, workspace_root: $ws}')"
case4_registry="$(expected_registry_path "$case4_home" "$case4_workspace")"
case4_rc=0
run_init "$case4_home" "$case4_payload" \
    "$TEST_DIR/c4.out" "$TEST_DIR/c4.err" || case4_rc=$?
if [[ "$case4_rc" -ne 0 ]]; then
    log_fail "Case 4 — exit $case4_rc; stderr=$(cat "$TEST_DIR/c4.err")"
elif [[ ! -f "$case4_registry" ]]; then
    log_fail "Case 4 — registry not at expected path $case4_registry"
elif ! jq empty "$case4_registry" >/dev/null 2>&1; then
    log_fail "Case 4 — registry not valid JSON"
else
    log_pass "Case 4 — mkdir -p chain created and registry written"
fi

# ---------------------------------------------------------------------------
# Case 5 — Malformed existing registry overwritten cleanly.
# ---------------------------------------------------------------------------
log_test "Case 5 — malformed existing registry overwritten cleanly"
case5_home="$TEST_DIR/case5"
mkdir -p "$case5_home"
case5_workspace="/tmp/some-codex-workspace-c5"
case5_registry="$(expected_registry_path "$case5_home" "$case5_workspace")"
mkdir -p "$(dirname "$case5_registry")"
# Plant an invalid JSON file at the registry path.
printf 'this is not { json: %s\n' '"' > "$case5_registry"
case5_payload="$(jq -nc \
    --arg sid "sess-c5-001" \
    --arg ws "$case5_workspace" \
    '{session_id: $sid, workspace_root: $ws}')"
case5_rc=0
run_init "$case5_home" "$case5_payload" \
    "$TEST_DIR/c5.out" "$TEST_DIR/c5.err" || case5_rc=$?
if [[ "$case5_rc" -ne 0 ]]; then
    log_fail "Case 5 — exit $case5_rc; stderr=$(cat "$TEST_DIR/c5.err")"
elif ! jq empty "$case5_registry" >/dev/null 2>&1; then
    log_fail "Case 5 — registry still malformed after overwrite: $(cat "$case5_registry")"
else
    sid_after="$(jq -r '.session_id' "$case5_registry")"
    if [[ "$sid_after" != "sess-c5-001" ]]; then
        log_fail "Case 5 — overwrite produced wrong session_id '$sid_after'"
    else
        log_pass "Case 5 — malformed registry overwritten cleanly"
    fi
fi

# ---------------------------------------------------------------------------
# Case 6 — Atomic-write invariant: kill writer between temp creation
# and `mv`. The test uses CERBERUS_TEST_PRE_MV_SLEEP to widen the race
# window deterministically. After SIGTERM the orphan tmp file must
# remain and active-session.json must be absent (since no prior file
# existed).
# ---------------------------------------------------------------------------
log_test "Case 6 — atomic-write: kill writer pre-mv leaves no active-session.json"
case6_home="$TEST_DIR/case6"
mkdir -p "$case6_home"
case6_workspace="/tmp/some-codex-workspace-c6"
case6_payload="$(jq -nc \
    --arg sid "sess-c6-001" \
    --arg ws "$case6_workspace" \
    '{session_id: $sid, workspace_root: $ws}')"
case6_registry="$(expected_registry_path "$case6_home" "$case6_workspace")"
case6_dir="$(dirname "$case6_registry")"

(run_init "$case6_home" "$case6_payload" \
    "$TEST_DIR/c6.out" "$TEST_DIR/c6.err" \
    "CERBERUS_TEST_PRE_MV_SLEEP=10") &
case6_pid=$!

# Wait up to ~5s for the tmp file to appear.
case6_tmp=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
         21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 \
         41 42 43 44 45 46 47 48 49 50; do
    if [[ -d "$case6_dir" ]]; then
        # Find any active-session.json.tmp.* under the registry dir.
        candidate=$(find "$case6_dir" -maxdepth 1 \
            -name 'active-session.json.tmp.*' 2>/dev/null | head -n 1)
        if [[ -n "$candidate" ]]; then
            case6_tmp="$candidate"
            break
        fi
    fi
    sleep 0.1
done

if [[ -z "$case6_tmp" ]]; then
    kill -KILL "$case6_pid" 2>/dev/null || true
    wait "$case6_pid" 2>/dev/null || true
    log_fail "Case 6 — tmp file never appeared; cannot exercise pre-mv kill"
else
    # Kill mid-sleep — tmp exists, mv has not happened yet.
    kill -TERM "$case6_pid" 2>/dev/null || true
    wait "$case6_pid" 2>/dev/null || true
    if [[ -f "$case6_registry" ]]; then
        log_fail "Case 6 — active-session.json appeared despite pre-mv kill"
    elif [[ ! -f "$case6_tmp" ]]; then
        log_fail "Case 6 — orphan tmp file removed (expected to remain): $case6_tmp"
    else
        log_pass "Case 6 — pre-mv kill left orphan tmp; active-session.json absent"
    fi
fi

# ---------------------------------------------------------------------------
# Case 7 — Schema correctness: written JSON validates against the v1
# schema (every required field present and typed correctly).
# ---------------------------------------------------------------------------
log_test "Case 7 — written JSON validates against registry schema v1"
case7_home="$TEST_DIR/case7"
mkdir -p "$case7_home"
case7_workspace="/tmp/some-codex-workspace-c7"
case7_payload="$(jq -nc \
    --arg sid "sess-c7-001" \
    --arg ws "$case7_workspace" \
    --arg tp "/tmp/c7-transcript.jsonl" \
    '{session_id: $sid, workspace_root: $ws, transcript_path: $tp}')"
case7_registry="$(expected_registry_path "$case7_home" "$case7_workspace")"
run_init "$case7_home" "$case7_payload" \
    "$TEST_DIR/c7.out" "$TEST_DIR/c7.err"

# jq filter: returns "ok" when every required field is present and
# typed; else returns a diagnostic.
case7_check="$(jq -r '
    def is_str: type == "string" and length > 0;
    def is_int(v): (.[v] | type) == "number";
    if (.schema_version == 1)
       and (.host == "codex")
       and (.workspace_root | is_str)
       and (.project_key | is_str)
       and (.session_id | is_str)
       and (.codex_session_id == .session_id)
       and (.run_key | is_str)
       and (.transcript_path | type == "string")
       and (.last_seen | is_str)
    then "ok"
    else "missing-or-malformed-field"
    end
' "$case7_registry" 2>/dev/null || echo "jq-error")"
if [[ "$case7_check" == "ok" ]]; then
    log_pass "Case 7 — registry JSON conforms to schema v1"
else
    log_fail "Case 7 — schema check returned '$case7_check'; payload=$(cat "$case7_registry")"
fi

# ---------------------------------------------------------------------------
# Case 8 — Inherited CERBERUS_PROJECT_KEY is ignored for Codex registry
# namespace. Hook stdin cwd/workspace_root is authoritative.
# ---------------------------------------------------------------------------
log_test "Case 8 — inherited CERBERUS_PROJECT_KEY ignored for registry path"
case8_home="$TEST_DIR/case8"
mkdir -p "$case8_home"
case8_workspace="/tmp/some-codex-workspace-c8"
case8_payload="$(jq -nc \
    --arg sid "sess-c8-001" \
    --arg ws "$case8_workspace" \
    '{session_id: $sid, cwd: $ws}')"
case8_registry="$(expected_registry_path "$case8_home" "$case8_workspace")"
case8_wrong_registry="$case8_home/.cerberus/runtime/codex/wrong-env-key/active-session.json"
case8_rc=0
run_init "$case8_home" "$case8_payload" \
    "$TEST_DIR/c8.out" "$TEST_DIR/c8.err" \
    "CERBERUS_PROJECT_KEY=wrong-env-key" || case8_rc=$?
if [[ "$case8_rc" -ne 0 ]]; then
    log_fail "Case 8 — exited with $case8_rc; stderr=$(cat "$TEST_DIR/c8.err")"
elif [[ ! -f "$case8_registry" ]]; then
    log_fail "Case 8 — cwd-derived registry not written at $case8_registry"
elif [[ -e "$case8_wrong_registry" ]]; then
    log_fail "Case 8 — wrote registry under inherited CERBERUS_PROJECT_KEY: $case8_wrong_registry"
else
    log_pass "Case 8 — registry path derived from Codex cwd, not inherited env"
fi

# ---------------------------------------------------------------------------
# Happy path A — script entry point is a regular file, executable.
# ---------------------------------------------------------------------------
log_test "Happy A — bin/codex-session-init exists, is a regular file, executable"
if [[ -f "$CODEX_SESSION_INIT" && -x "$CODEX_SESSION_INIT" ]]; then
    log_pass "Happy A — entry point present and executable"
else
    log_fail "Happy A — entry point missing or not executable: $CODEX_SESSION_INIT"
fi

# ---------------------------------------------------------------------------
# Happy path B — script reads stdin and emits valid JSON registry on
# exit 0. (Carried over from T007 as a smoke probe.)
# ---------------------------------------------------------------------------
log_test "Happy B — stub reads stdin and writes a valid registry, exit 0"
hb_home="$TEST_DIR/happy-b"
mkdir -p "$hb_home"
hb_workspace="/tmp/some-codex-workspace-hb"
hb_payload="$(jq -nc \
    --arg sid "sess-hb" \
    --arg ws "$hb_workspace" \
    '{session_id: $sid, workspace_root: $ws}')"
hb_registry="$(expected_registry_path "$hb_home" "$hb_workspace")"
hb_rc=0
run_init "$hb_home" "$hb_payload" \
    "$TEST_DIR/hb.out" "$TEST_DIR/hb.err" || hb_rc=$?
if [[ "$hb_rc" -ne 0 ]]; then
    log_fail "Happy B — exited with $hb_rc; stderr=$(cat "$TEST_DIR/hb.err")"
elif [[ ! -f "$hb_registry" ]]; then
    log_fail "Happy B — registry not written"
elif ! jq empty "$hb_registry" >/dev/null 2>&1; then
    log_fail "Happy B — registry not valid JSON"
else
    log_pass "Happy B — registry written and valid"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "----------------------------------------"
echo "Codex session-registry test summary:"
echo "  Passed: $TESTS_PASSED"
echo "  Failed: $TESTS_FAILED"
echo "----------------------------------------"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
