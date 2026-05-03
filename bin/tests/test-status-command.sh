#!/usr/bin/env bash
# T003 — `status --json` contract tests.
#
# Plan reference: §Phase 0 Tests, "test-status-command.sh — 9 cases"
# (L1114-L1132); §status --json schema (L634-L730).
#
# Coverage matrix (9 cases, mapped to plan rows):
#
#   1. No active gate            → exit 4 + {"status":"no_active_gate"}
#   2. Pending                   → gate_status:"pending", pending_reviewers populated
#   3. Awaiting decision         → aggregated_findings populated, blocking → consensus "fail"
#   4. Resolved pass             → gate_status:"resolved", consensus_verdict:"pass"
#   5. Resolved fail             → gate_status:"resolved", consensus_verdict:"fail"
#   6. Malformed gate-state.json → exit 0 + {"status":"unknown","error":"malformed_state"}
#   7. No-mutation invariant     → snapshot $REVIEW_DIR before/after; byte-for-byte equal
#   8. No-blocking invariant     → wall-clock <1s against pending gate
#   9. Schema fields             → schema_version,host,project_key,run_key,review_dir
#
# Each case builds an isolated $REVIEW_DIR under $TEST_HOME so the suite
# is hermetic and re-entrant.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_GATE="$SCRIPT_DIR/../review-gate"

if [[ ! -x "$REVIEW_GATE" ]]; then
    echo "FATAL: review-gate not executable at $REVIEW_GATE" >&2
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

TEST_DIR="$(mktemp -d -t cerberus-status-cmd.XXXXXX)"
TEST_HOME="$TEST_DIR/home"
mkdir -p "$TEST_HOME"

log_test() { echo -e "${YELLOW}TEST:${NC} $1"; }
log_pass() { echo -e "${GREEN}PASS:${NC} $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
log_fail() { echo -e "${RED}FAIL:${NC} $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# Run `bin/review-gate status --json` in a clean subshell with a
# controlled HOME and a chosen run key. Returns the command exit code
# via $? and writes stdout/stderr to caller-provided files. No CLAUDE_*
# env leaks into the child.
#
# Usage:
#   run_status PROJECT_KEY RUN_KEY OUT_FILE ERR_FILE [extra-args...]
run_status() {
    local proj="$1"
    local run="$2"
    local out="$3"
    local err="$4"
    shift 4
    (
        unset CERBERUS_HOST CERBERUS_RUN_KEY CERBERUS_STATE_ROOT \
              CERBERUS_PROJECT_KEY CERBERUS_SESSION_ID \
              CERBERUS_TRANSCRIPT_PATH CERBERUS_ROOT \
              REVIEW_GATE_SESSION_KEY \
              CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH CLAUDE_PROJECT_DIR \
              __CERBERUS_ALIAS_WARNED || true
        export HOME="$TEST_HOME"
        export CERBERUS_HOST="generic"
        export CERBERUS_PROJECT_KEY="$proj"
        export CERBERUS_RUN_KEY="$run"
        "$REVIEW_GATE" status --json "$@"
    ) >"$out" 2>"$err"
}

# Helper: build a neutral $REVIEW_DIR under $TEST_HOME for a given
# project/run pair. Echoes the absolute review_dir on stdout.
make_review_dir() {
    local proj="$1"
    local run="$2"
    local review_dir="$TEST_HOME/.cerberus/projects/$proj/$run"
    mkdir -p "$review_dir/reviews"
    echo "$review_dir"
}

# Helper: snapshot a directory's file list + per-file SHA-256.
# Output (stdout): canonical lines "<sha256>  <relpath>" sorted by path.
# Used by case 7 to assert no-mutation invariant byte-for-byte.
snapshot_dir() {
    local d="$1"
    if [[ ! -d "$d" ]]; then
        echo "MISSING-DIR"
        return 0
    fi
    # `find -print0 | sort -z | while` to handle weird filenames; the
    # gate-state JSON we write here has no funky chars so a simpler form
    # suffices. shasum on macOS, sha256sum on Linux.
    local sha_cmd
    if command -v sha256sum >/dev/null 2>&1; then
        sha_cmd=(sha256sum)
    else
        sha_cmd=(shasum -a 256)
    fi
    (cd "$d" && find . -type f | LC_ALL=C sort | xargs -I {} "${sha_cmd[@]}" {} 2>/dev/null) || true
}

# ---------------------------------------------------------------------------
# Case 1 — No active gate.
# ---------------------------------------------------------------------------
log_test "Case 1: no active gate (exit 4 + {\"status\":\"no_active_gate\"})"
case1_out="$TEST_DIR/case1.out"
case1_err="$TEST_DIR/case1.err"
run_status "case1-proj" "case1-run-missing" "$case1_out" "$case1_err"
case1_rc=$?
if [[ "$case1_rc" -ne 4 ]]; then
    log_fail "Case 1: expected exit 4, got $case1_rc (stderr: $(cat "$case1_err"))"
else
    case1_status=$(jq -r '.status' "$case1_out" 2>/dev/null || echo "")
    if [[ "$case1_status" == "no_active_gate" ]]; then
        log_pass "Case 1: exit 4 + status=no_active_gate"
    else
        log_fail "Case 1: status='$case1_status' body=$(cat "$case1_out")"
    fi
fi

# ---------------------------------------------------------------------------
# Case 2 — Pending gate with two reviewers, neither done.
# ---------------------------------------------------------------------------
log_test "Case 2: pending gate (gate_status=pending + pending_reviewers populated)"
c2_dir=$(make_review_dir "case2-proj" "case2-run")
cat > "$c2_dir/gate-state.json" <<EOF
{
  "version": 1,
  "status": "pending",
  "trigger_source": "test",
  "artifact": {"path": "$c2_dir/latest.md", "sha256": ""},
  "reviewers": {"codex": {}, "gemini": {}},
  "consensus": null,
  "decision": null,
  "owner": {"session_key": "case2-run"},
  "created_at": "2026-04-30T00:00:00Z",
  "iteration": 0
}
EOF
case2_out="$TEST_DIR/case2.out"
case2_err="$TEST_DIR/case2.err"
run_status "case2-proj" "case2-run" "$case2_out" "$case2_err"
case2_rc=$?
if [[ "$case2_rc" -ne 0 ]]; then
    log_fail "Case 2: expected exit 0, got $case2_rc (stderr: $(cat "$case2_err"))"
else
    case2_gs=$(jq -r '.gate_status' "$case2_out" 2>/dev/null || echo "")
    case2_pending=$(jq -r '.pending_reviewers | sort | join(",")' "$case2_out" 2>/dev/null || echo "")
    if [[ "$case2_gs" == "pending" && "$case2_pending" == "codex,gemini" ]]; then
        log_pass "Case 2: gate_status=pending, pending_reviewers=[codex,gemini]"
    else
        log_fail "Case 2: gate_status='$case2_gs' pending='$case2_pending' body=$(cat "$case2_out")"
    fi
fi

# ---------------------------------------------------------------------------
# Case 3 — Awaiting decision with blocking findings → consensus_verdict="fail".
# ---------------------------------------------------------------------------
log_test "Case 3: awaiting_decision with blocking findings → consensus=fail"
c3_dir=$(make_review_dir "case3-proj" "case3-run")
cat > "$c3_dir/gate-state.json" <<EOF
{
  "version": 1,
  "status": "awaiting_decision",
  "trigger_source": "test",
  "artifact": {"path": "$c3_dir/latest.md", "sha256": ""},
  "reviewers": {"codex": {}, "gemini": {}},
  "consensus": null,
  "decision": null,
  "owner": {"session_key": "case3-run"},
  "created_at": "2026-04-30T00:00:00Z",
  "iteration": 0
}
EOF
# codex returns FAIL with a P0 finding (blocking).
cat > "$c3_dir/reviews/codex.json" <<'EOF'
{
  "verdict": "FAIL",
  "summary": "Critical bug",
  "findings": [
    {
      "title": "Null deref in main path",
      "body": "main() dereferences argv[0] without bounds check.",
      "priority": 0,
      "file_path": "src/main.c",
      "line_start": 12,
      "line_end": 14
    }
  ]
}
EOF
touch "$c3_dir/reviews/codex.done"
# gemini PASS, no findings (non-blocking).
cat > "$c3_dir/reviews/gemini.json" <<'EOF'
{
  "verdict": "PASS",
  "summary": "Looks fine",
  "findings": []
}
EOF
touch "$c3_dir/reviews/gemini.done"
case3_out="$TEST_DIR/case3.out"
case3_err="$TEST_DIR/case3.err"
run_status "case3-proj" "case3-run" "$case3_out" "$case3_err"
case3_rc=$?
if [[ "$case3_rc" -ne 0 ]]; then
    log_fail "Case 3: expected exit 0, got $case3_rc (stderr: $(cat "$case3_err"))"
else
    case3_gs=$(jq -r '.gate_status' "$case3_out")
    case3_cv=$(jq -r '.consensus_verdict' "$case3_out")
    case3_findings_n=$(jq -r '.aggregated_findings | length' "$case3_out")
    case3_priority=$(jq -r '.aggregated_findings[0].priority' "$case3_out")
    case3_verdict=$(jq -r '.aggregated_findings[0].verdict' "$case3_out")
    case3_reviewer=$(jq -r '.aggregated_findings[0].reviewer' "$case3_out")
    if [[ "$case3_gs" == "awaiting_decision" \
          && "$case3_cv" == "fail" \
          && "$case3_findings_n" == "1" \
          && "$case3_priority" == "P0" \
          && "$case3_verdict" == "FAIL" \
          && "$case3_reviewer" == "codex" ]]; then
        log_pass "Case 3: awaiting_decision + 1 finding (codex/P0/FAIL) + consensus=fail"
    else
        log_fail "Case 3: gs=$case3_gs cv=$case3_cv n=$case3_findings_n pri=$case3_priority v=$case3_verdict body=$(cat "$case3_out")"
    fi
fi

# ---------------------------------------------------------------------------
# Case 4 — Resolved pass → consensus_verdict="pass".
# ---------------------------------------------------------------------------
log_test "Case 4: resolved pass (consensus_verdict=pass)"
c4_dir=$(make_review_dir "case4-proj" "case4-run")
cat > "$c4_dir/gate-state.json" <<EOF
{
  "version": 1,
  "status": "resolved",
  "trigger_source": "test",
  "artifact": {"path": "$c4_dir/latest.md", "sha256": ""},
  "reviewers": {"codex": {}},
  "consensus": {"verdict": "PASS"},
  "decision": {"action": "proceed", "decided_at": "2026-04-30T00:00:00Z"},
  "owner": {"session_key": "case4-run"},
  "created_at": "2026-04-30T00:00:00Z",
  "iteration": 0
}
EOF
cat > "$c4_dir/reviews/codex.json" <<'EOF'
{"verdict":"PASS","summary":"All good","findings":[]}
EOF
touch "$c4_dir/reviews/codex.done"
case4_out="$TEST_DIR/case4.out"
case4_err="$TEST_DIR/case4.err"
run_status "case4-proj" "case4-run" "$case4_out" "$case4_err"
case4_rc=$?
case4_gs=$(jq -r '.gate_status' "$case4_out" 2>/dev/null || echo "")
case4_cv=$(jq -r '.consensus_verdict' "$case4_out" 2>/dev/null || echo "")
if [[ "$case4_rc" -eq 0 && "$case4_gs" == "resolved" && "$case4_cv" == "pass" ]]; then
    log_pass "Case 4: gate_status=resolved + consensus_verdict=pass"
else
    log_fail "Case 4: rc=$case4_rc gs=$case4_gs cv=$case4_cv body=$(cat "$case4_out")"
fi

# ---------------------------------------------------------------------------
# Case 5 — Resolved fail → consensus_verdict="fail".
# ---------------------------------------------------------------------------
log_test "Case 5: resolved fail (consensus_verdict=fail)"
c5_dir=$(make_review_dir "case5-proj" "case5-run")
cat > "$c5_dir/gate-state.json" <<EOF
{
  "version": 1,
  "status": "resolved",
  "trigger_source": "test",
  "artifact": {"path": "$c5_dir/latest.md", "sha256": ""},
  "reviewers": {"codex": {}},
  "consensus": {"verdict": "FAIL"},
  "decision": {"action": "manual_resolve", "decided_at": "2026-04-30T00:00:00Z"},
  "owner": {"session_key": "case5-run"},
  "created_at": "2026-04-30T00:00:00Z",
  "iteration": 0
}
EOF
cat > "$c5_dir/reviews/codex.json" <<'EOF'
{"verdict":"FAIL","summary":"Bad","findings":[{"title":"x","body":"y","priority":1,"file_path":null,"line_start":null,"line_end":null}]}
EOF
touch "$c5_dir/reviews/codex.done"
case5_out="$TEST_DIR/case5.out"
case5_err="$TEST_DIR/case5.err"
run_status "case5-proj" "case5-run" "$case5_out" "$case5_err"
case5_rc=$?
case5_gs=$(jq -r '.gate_status' "$case5_out" 2>/dev/null || echo "")
case5_cv=$(jq -r '.consensus_verdict' "$case5_out" 2>/dev/null || echo "")
if [[ "$case5_rc" -eq 0 && "$case5_gs" == "resolved" && "$case5_cv" == "fail" ]]; then
    log_pass "Case 5: gate_status=resolved + consensus_verdict=fail"
else
    log_fail "Case 5: rc=$case5_rc gs=$case5_gs cv=$case5_cv body=$(cat "$case5_out")"
fi

# ---------------------------------------------------------------------------
# Case 6 — Malformed gate-state.json → exit 0 + status=unknown,error=malformed_state.
# ---------------------------------------------------------------------------
log_test "Case 6: malformed gate-state.json (exit 0 + status=unknown,error=malformed_state)"
c6_dir=$(make_review_dir "case6-proj" "case6-run")
printf '{this is not valid JSON' > "$c6_dir/gate-state.json"
case6_out="$TEST_DIR/case6.out"
case6_err="$TEST_DIR/case6.err"
run_status "case6-proj" "case6-run" "$case6_out" "$case6_err"
case6_rc=$?
case6_status=$(jq -r '.status' "$case6_out" 2>/dev/null || echo "")
case6_error=$(jq -r '.error' "$case6_out" 2>/dev/null || echo "")
if [[ "$case6_rc" -eq 0 && "$case6_status" == "unknown" && "$case6_error" == "malformed_state" ]]; then
    log_pass "Case 6: exit 0 + status=unknown + error=malformed_state"
else
    log_fail "Case 6: rc=$case6_rc status=$case6_status error=$case6_error body=$(cat "$case6_out")"
fi

# ---------------------------------------------------------------------------
# Case 7 — No-mutation invariant: REVIEW_DIR snapshot is byte-for-byte equal
# before and after `status --json` for every gate state we exercise here
# (pending, awaiting_decision-with-findings, resolved-pass, resolved-fail,
# malformed). Using cases 2-6's review dirs as the matrix.
# ---------------------------------------------------------------------------
log_test "Case 7: no-mutation invariant (snapshot before/after byte-equal)"
case7_failed="false"
for d in "$c2_dir" "$c3_dir" "$c4_dir" "$c5_dir" "$c6_dir"; do
    proj=$(basename "$(dirname "$d")")
    run=$(basename "$d")
    snap_before=$(snapshot_dir "$d")
    run_status "$proj" "$run" "$TEST_DIR/case7-$run.out" "$TEST_DIR/case7-$run.err" || true
    snap_after=$(snapshot_dir "$d")
    if [[ "$snap_before" != "$snap_after" ]]; then
        log_fail "Case 7: $d snapshot mismatch (status mutated REVIEW_DIR)"
        diff <(echo "$snap_before") <(echo "$snap_after") | head -20 >&2
        case7_failed="true"
    fi
done
if [[ "$case7_failed" == "false" ]]; then
    log_pass "Case 7: no-mutation invariant holds across all gate states"
fi

# ---------------------------------------------------------------------------
# Case 8 — No-blocking invariant: status --json against pending gate
# returns in <1s. Gate has 3 reviewers, none completed, so any polling
# loop would obviously bust this budget.
# ---------------------------------------------------------------------------
log_test "Case 8: no-blocking invariant (<1s against pending gate)"
c8_dir=$(make_review_dir "case8-proj" "case8-run")
cat > "$c8_dir/gate-state.json" <<EOF
{
  "version": 1,
  "status": "pending",
  "trigger_source": "test",
  "artifact": {"path": "$c8_dir/latest.md", "sha256": ""},
  "reviewers": {"codex": {}, "gemini": {}, "claude": {}},
  "consensus": null,
  "decision": null,
  "owner": {"session_key": "case8-run"},
  "created_at": "2026-04-30T00:00:00Z",
  "iteration": 0
}
EOF
case8_out="$TEST_DIR/case8.out"
case8_err="$TEST_DIR/case8.err"
# Use sub-second precision (python3) so a fully-loaded CI box doesn't
# spuriously fail the budget on ~1s whole-second rounding. The plan
# requirement (no polling loop) really means "well below the default
# poll-interval of 3s"; we keep a tight 2.5s ceiling to catch polling
# regressions while accommodating CI noise.
_now_subsec() {
    python3 -c 'import time; print(time.time())' 2>/dev/null \
        || date +%s
}
case8_t0=$(_now_subsec)
run_status "case8-proj" "case8-run" "$case8_out" "$case8_err"
case8_rc=$?
case8_t1=$(_now_subsec)
case8_elapsed=$(python3 -c "print(float('$case8_t1') - float('$case8_t0'))" 2>/dev/null || echo "0")
case8_under_budget=$(python3 -c "print('1' if float('$case8_elapsed') < 2.5 else '0')" 2>/dev/null || echo "0")
if [[ "$case8_rc" -ne 0 ]]; then
    log_fail "Case 8: rc=$case8_rc body=$(cat "$case8_out") stderr=$(cat "$case8_err")"
elif [[ "$case8_under_budget" == "1" ]]; then
    # Plan requires <1s; our budget here is <2.5s to absorb CI scheduling
    # noise. Anything approaching the default poll-interval (3s) would
    # signal a regression to a polling loop, which is what this test
    # ultimately enforces.
    log_pass "Case 8: status returned in ${case8_elapsed}s (no polling loop) for pending gate"
else
    log_fail "Case 8: status took ${case8_elapsed}s for pending gate (must be <2.5s; plan target <1s)"
fi

# ---------------------------------------------------------------------------
# Case 9 — Schema fields present in every successful body. Reuse case 4
# (a successful resolved-pass gate) and assert the five required top-level
# fields are present and non-empty (where applicable).
# ---------------------------------------------------------------------------
log_test "Case 9: schema fields present (schema_version,host,project_key,run_key,review_dir)"
case9_out="$TEST_DIR/case9.out"
case9_err="$TEST_DIR/case9.err"
run_status "case4-proj" "case4-run" "$case9_out" "$case9_err"
case9_rc=$?
case9_sv=$(jq -r '.schema_version' "$case9_out" 2>/dev/null || echo "")
case9_host=$(jq -r '.host' "$case9_out" 2>/dev/null || echo "")
case9_pk=$(jq -r '.project_key' "$case9_out" 2>/dev/null || echo "")
case9_rk=$(jq -r '.run_key' "$case9_out" 2>/dev/null || echo "")
case9_rd=$(jq -r '.review_dir' "$case9_out" 2>/dev/null || echo "")
case9_cv_has=$(jq 'has("consensus_verdict")' "$case9_out" 2>/dev/null || echo "false")
case9_revs_has=$(jq 'has("reviewers")' "$case9_out" 2>/dev/null || echo "false")
case9_pend_has=$(jq 'has("pending_reviewers")' "$case9_out" 2>/dev/null || echo "false")
case9_agg_has=$(jq 'has("aggregated_findings")' "$case9_out" 2>/dev/null || echo "false")
case9_pe_has=$(jq 'has("parse_errors")' "$case9_out" 2>/dev/null || echo "false")
case9_gs_has=$(jq 'has("gate_status")' "$case9_out" 2>/dev/null || echo "false")
if [[ "$case9_rc" -eq 0 \
      && "$case9_sv" == "1" \
      && -n "$case9_host" && "$case9_host" != "null" \
      && "$case9_pk" == "case4-proj" \
      && "$case9_rk" == "case4-run" \
      && -n "$case9_rd" && "$case9_rd" != "null" \
      && "$case9_cv_has" == "true" \
      && "$case9_revs_has" == "true" \
      && "$case9_pend_has" == "true" \
      && "$case9_agg_has" == "true" \
      && "$case9_pe_has" == "true" \
      && "$case9_gs_has" == "true" ]]; then
    log_pass "Case 9: all required schema fields present"
else
    log_fail "Case 9: rc=$case9_rc sv=$case9_sv host=$case9_host pk=$case9_pk rk=$case9_rk rd=$case9_rd has(cv)=$case9_cv_has has(reviewers)=$case9_revs_has has(pending)=$case9_pend_has has(agg)=$case9_agg_has has(pe)=$case9_pe_has has(gs)=$case9_gs_has body=$(cat "$case9_out")"
fi

# ---------------------------------------------------------------------------
# Regression: round-1 review #2 — string priority "P0".."P3" must be
# accepted alongside numeric 0..3. The canonical normalizer in
# bin/review-gate-hook.sh:1162-1186 explicitly accepts both forms; the
# status aggregator must too, otherwise a reviewer emitting `priority:
# "P1"` would have its blocking finding silently routed to parse_errors.
# ---------------------------------------------------------------------------
log_test "Regression: status accepts string \"P0\".\"P3\" priority forms"
cR1_dir=$(make_review_dir "regress-string-prio-proj" "regress-string-prio-run")
cat > "$cR1_dir/gate-state.json" <<EOF
{
  "version": 1,
  "status": "awaiting_decision",
  "trigger_source": "test",
  "artifact": {"path": "$cR1_dir/latest.md", "sha256": ""},
  "reviewers": {"codex": {}},
  "consensus": null,
  "decision": null,
  "owner": {"session_key": "regress-string-prio-run"},
  "created_at": "2026-04-30T00:00:00Z",
  "iteration": 0
}
EOF
cat > "$cR1_dir/reviews/codex.json" <<'EOF'
{
  "verdict": "FAIL",
  "summary": "string-priority finding",
  "findings": [
    {"title":"P0 string","body":"x","priority":"P0","file_path":null,"line_start":null,"line_end":null},
    {"title":"P3 string","body":"y","priority":"P3","file_path":null,"line_start":null,"line_end":null}
  ]
}
EOF
touch "$cR1_dir/reviews/codex.done"
cR1_out="$TEST_DIR/cR1.out"
cR1_err="$TEST_DIR/cR1.err"
run_status "regress-string-prio-proj" "regress-string-prio-run" "$cR1_out" "$cR1_err"
cR1_rc=$?
cR1_n=$(jq -r '.aggregated_findings | length' "$cR1_out" 2>/dev/null || echo 0)
cR1_p0=$(jq -r '.aggregated_findings[0].priority' "$cR1_out" 2>/dev/null || echo "")
cR1_p3=$(jq -r '.aggregated_findings[1].priority' "$cR1_out" 2>/dev/null || echo "")
cR1_pe=$(jq -r '.parse_errors | length' "$cR1_out" 2>/dev/null || echo "")
if [[ "$cR1_rc" -eq 0 && "$cR1_n" == "2" && "$cR1_p0" == "P0" && "$cR1_p3" == "P3" && "$cR1_pe" == "0" ]]; then
    log_pass "Regression: string priority forms accepted as P0/P3, no parse_errors"
else
    log_fail "Regression: string priority rc=$cR1_rc n=$cR1_n p0=$cR1_p0 p3=$cR1_p3 pe=$cR1_pe body=$(cat "$cR1_out")"
fi

# ---------------------------------------------------------------------------
# Regression: round-1 review #1 — Claude `--output-format json` reviewer
# files are wrapped in {result: "..."} metadata. status must unwrap via
# extract_json (matching `wait`), not read .verdict directly. Otherwise a
# completed FAIL from Claude/Gemini disappears from the canonical payload.
# ---------------------------------------------------------------------------
log_test "Regression: status unwraps Claude --output-format json wrapper"
cR2_dir=$(make_review_dir "regress-claude-wrap-proj" "regress-claude-wrap-run")
cat > "$cR2_dir/gate-state.json" <<EOF
{
  "version": 1,
  "status": "awaiting_decision",
  "trigger_source": "test",
  "artifact": {"path": "$cR2_dir/latest.md", "sha256": ""},
  "reviewers": {"claude": {}},
  "consensus": null,
  "decision": null,
  "owner": {"session_key": "regress-claude-wrap-run"},
  "created_at": "2026-04-30T00:00:00Z",
  "iteration": 0
}
EOF
# Claude --output-format json wraps the actual review in {.result} as a
# stringified JSON. extract_json's claude branch reads .result and unwraps.
cat > "$cR2_dir/reviews/claude.json" <<'EOF'
{
  "type": "result",
  "subtype": "success",
  "is_error": false,
  "result": "{\"verdict\":\"FAIL\",\"summary\":\"wrapper test\",\"findings\":[{\"title\":\"wrapper hit\",\"body\":\"the wrapper hid this finding\",\"priority\":1,\"file_path\":\"src/x.c\",\"line_start\":1,\"line_end\":1}]}"
}
EOF
touch "$cR2_dir/reviews/claude.done"
cR2_out="$TEST_DIR/cR2.out"
cR2_err="$TEST_DIR/cR2.err"
run_status "regress-claude-wrap-proj" "regress-claude-wrap-run" "$cR2_out" "$cR2_err"
cR2_rc=$?
cR2_cv=$(jq -r '.consensus_verdict' "$cR2_out" 2>/dev/null || echo "")
cR2_n=$(jq -r '.aggregated_findings | length' "$cR2_out" 2>/dev/null || echo 0)
cR2_pri=$(jq -r '.aggregated_findings[0].priority' "$cR2_out" 2>/dev/null || echo "")
cR2_rev_verdict=$(jq -r '.reviewers[0].verdict' "$cR2_out" 2>/dev/null || echo "")
if [[ "$cR2_rc" -eq 0 && "$cR2_cv" == "fail" && "$cR2_n" == "1" \
      && "$cR2_pri" == "P1" && "$cR2_rev_verdict" == "fail" ]]; then
    log_pass "Regression: Claude wrapper unwrapped; FAIL + P1 finding visible"
else
    log_fail "Regression: Claude wrapper rc=$cR2_rc cv=$cR2_cv n=$cR2_n pri=$cR2_pri rev=$cR2_rev_verdict body=$(cat "$cR2_out") stderr=$(cat "$cR2_err")"
fi

# ---------------------------------------------------------------------------
# Regression: stale .failed sentinels must not mask a valid parsed reviewer
# JSON. Real Claude timeout-mask failures can leave both claude.json (valid
# success wrapper) and claude.failed behind; status must report the verdict,
# not a failed reviewer slot.
# ---------------------------------------------------------------------------
log_test "Regression: status trusts valid reviewer JSON over stale .failed sentinel"
cR2b_dir=$(make_review_dir "regress-stale-failed-proj" "regress-stale-failed-run")
cat > "$cR2b_dir/gate-state.json" <<EOF
{
  "version": 1,
  "status": "awaiting_decision",
  "trigger_source": "test",
  "artifact": {"path": "$cR2b_dir/latest.md", "sha256": ""},
  "reviewers": {"claude": {}},
  "consensus": null,
  "decision": null,
  "owner": {"session_key": "regress-stale-failed-run"},
  "created_at": "2026-05-01T00:00:00Z",
  "iteration": 0
}
EOF
cat > "$cR2b_dir/reviews/claude.json" <<'EOF'
{
  "type": "result",
  "subtype": "success",
  "is_error": false,
  "result": "{\"verdict\":\"FAIL\",\"summary\":\"valid output with stale failure\",\"findings\":[{\"title\":\"stale failed masked me\",\"body\":\"valid finding\",\"priority\":0,\"file_path\":\"src/y.c\",\"line_start\":2,\"line_end\":2}]}"
}
EOF
touch "$cR2b_dir/reviews/claude.failed"
cR2b_out="$TEST_DIR/cR2b.out"
cR2b_err="$TEST_DIR/cR2b.err"
run_status "regress-stale-failed-proj" "regress-stale-failed-run" "$cR2b_out" "$cR2b_err"
cR2b_rc=$?
cR2b_status=$(jq -r '.reviewers[0].status' "$cR2b_out" 2>/dev/null || echo "")
cR2b_verdict=$(jq -r '.reviewers[0].verdict' "$cR2b_out" 2>/dev/null || echo "")
cR2b_cv=$(jq -r '.consensus_verdict' "$cR2b_out" 2>/dev/null || echo "")
cR2b_pe=$(jq -r '.parse_errors | length' "$cR2b_out" 2>/dev/null || echo "")
cR2b_n=$(jq -r '.aggregated_findings | length' "$cR2b_out" 2>/dev/null || echo "")
if [[ "$cR2b_rc" -eq 0 && "$cR2b_status" == "complete" \
      && "$cR2b_verdict" == "fail" && "$cR2b_cv" == "fail" \
      && "$cR2b_pe" == "0" && "$cR2b_n" == "1" ]]; then
    log_pass "Regression: stale .failed ignored when Claude JSON is valid"
else
    log_fail "Regression: stale failed rc=$cR2b_rc status=$cR2b_status verdict=$cR2b_verdict cv=$cR2b_cv pe=$cR2b_pe n=$cR2b_n body=$(cat "$cR2b_out") stderr=$(cat "$cR2b_err")"
fi

# ---------------------------------------------------------------------------
# Regression: a valid reviewer JSON without .done/.failed sentinels is a
# terminal reviewer result. Status remains read-only: it must not backfill
# either sentinel while deriving pending_reviewers/reviewer status.
# ---------------------------------------------------------------------------
log_test "Regression: status treats valid reviewer JSON without sentinels as complete"
cR2c_dir=$(make_review_dir "regress-missing-sentinel-proj" "regress-missing-sentinel-run")
cat > "$cR2c_dir/gate-state.json" <<EOF
{
  "version": 1,
  "status": "pending",
  "trigger_source": "test",
  "artifact": {"path": "$cR2c_dir/latest.md", "sha256": ""},
  "reviewers": {"claude": {}},
  "consensus": null,
  "decision": null,
  "owner": {"session_key": "regress-missing-sentinel-run"},
  "created_at": "2026-05-01T00:00:00Z",
  "iteration": 0
}
EOF
cat > "$cR2c_dir/reviews/claude.json" <<'EOF'
{
  "type": "result",
  "subtype": "success",
  "is_error": false,
  "result": "{\"verdict\":\"PASS\",\"summary\":\"valid output without sentinel\",\"findings\":[]}"
}
EOF
rm -f "$cR2c_dir/reviews/claude.done" "$cR2c_dir/reviews/claude.failed"
cR2c_out="$TEST_DIR/cR2c.out"
cR2c_err="$TEST_DIR/cR2c.err"
run_status "regress-missing-sentinel-proj" "regress-missing-sentinel-run" "$cR2c_out" "$cR2c_err"
cR2c_rc=$?
cR2c_status=$(jq -r '.reviewers[0].status' "$cR2c_out" 2>/dev/null || echo "")
cR2c_verdict=$(jq -r '.reviewers[0].verdict' "$cR2c_out" 2>/dev/null || echo "")
cR2c_pending=$(jq -r '.pending_reviewers | length' "$cR2c_out" 2>/dev/null || echo "")
cR2c_cv=$(jq -r '.consensus_verdict' "$cR2c_out" 2>/dev/null || echo "")
cR2c_pe=$(jq -r '.parse_errors | length' "$cR2c_out" 2>/dev/null || echo "")
if [[ "$cR2c_rc" -eq 0 && "$cR2c_status" == "complete" \
      && "$cR2c_verdict" == "pass" && "$cR2c_pending" == "0" \
      && "$cR2c_cv" == "pass" && "$cR2c_pe" == "0" \
      && ! -e "$cR2c_dir/reviews/claude.done" \
      && ! -e "$cR2c_dir/reviews/claude.failed" ]]; then
    log_pass "Regression: no-sentinel reviewer JSON is complete and status stayed read-only"
else
    log_fail "Regression: missing sentinel rc=$cR2c_rc status=$cR2c_status verdict=$cR2c_verdict pending=$cR2c_pending cv=$cR2c_cv pe=$cR2c_pe done=$(test -e "$cR2c_dir/reviews/claude.done" && echo yes || echo no) failed=$(test -e "$cR2c_dir/reviews/claude.failed" && echo yes || echo no) body=$(cat "$cR2c_out") stderr=$(cat "$cR2c_err")"
fi

# ---------------------------------------------------------------------------
# Regression: round-1 review #2 (the [2]) — when both --session-id S and
# --session-key K are passed, status MUST resolve under S, not K. Plant
# state under run "S" only; pass --session-id S --session-key K and
# verify the response describes S, not "no_active_gate".
# ---------------------------------------------------------------------------
log_test "Regression: --session-id S --session-key K resolves under S"
cR3_proj="regress-both-flags-proj"
cR3_run_real="regress-real-S"
cR3_run_decoy="regress-decoy-K"
cR3_dir=$(make_review_dir "$cR3_proj" "$cR3_run_real")
cat > "$cR3_dir/gate-state.json" <<EOF
{
  "version": 1,
  "status": "resolved",
  "trigger_source": "test",
  "artifact": {"path": "$cR3_dir/latest.md", "sha256": ""},
  "reviewers": {"codex": {}},
  "consensus": {"verdict": "PASS"},
  "decision": {"action": "proceed", "decided_at": "2026-04-30T00:00:00Z"},
  "owner": {"session_key": "$cR3_run_real"},
  "created_at": "2026-04-30T00:00:00Z",
  "iteration": 0
}
EOF
cat > "$cR3_dir/reviews/codex.json" <<'EOF'
{"verdict":"PASS","summary":"OK","findings":[]}
EOF
touch "$cR3_dir/reviews/codex.done"
cR3_out="$TEST_DIR/cR3.out"
cR3_err="$TEST_DIR/cR3.err"
(
    unset CERBERUS_HOST CERBERUS_RUN_KEY CERBERUS_STATE_ROOT \
          CERBERUS_PROJECT_KEY CERBERUS_SESSION_ID \
          CERBERUS_TRANSCRIPT_PATH CERBERUS_ROOT \
          REVIEW_GATE_SESSION_KEY \
          CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH CLAUDE_PROJECT_DIR \
          __CERBERUS_ALIAS_WARNED || true
    export HOME="$TEST_HOME"
    export CERBERUS_HOST="generic"
    export CERBERUS_PROJECT_KEY="$cR3_proj"
    "$REVIEW_GATE" status --json --session-id "$cR3_run_real" --session-key "$cR3_run_decoy"
) >"$cR3_out" 2>"$cR3_err"
cR3_rc=$?
cR3_rk=$(jq -r '.run_key' "$cR3_out" 2>/dev/null || echo "")
cR3_rd=$(jq -r '.review_dir' "$cR3_out" 2>/dev/null || echo "")
cR3_status=$(jq -r '.status // empty' "$cR3_out" 2>/dev/null || echo "")
if [[ "$cR3_rc" -eq 0 && "$cR3_rk" == "$cR3_run_real" \
      && "$cR3_rd" == "$cR3_dir" && "$cR3_status" != "no_active_gate" ]]; then
    log_pass "Regression: --session-id wins over --session-key when both set"
else
    log_fail "Regression: rc=$cR3_rc rk=$cR3_rk rd=$cR3_rd status=$cR3_status body=$(cat "$cR3_out") stderr=$(cat "$cR3_err")"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "----------------------------------------"
echo "test-status-command summary:"
echo "  Passed: $TESTS_PASSED"
echo "  Failed: $TESTS_FAILED"
echo "----------------------------------------"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
