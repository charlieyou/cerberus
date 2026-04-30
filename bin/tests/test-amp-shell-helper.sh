#!/usr/bin/env bash
# T013 — Phase 2 scaffold for the Amp Toolbox shell helper.
#
# Plan reference: §Phase 2 — Amp Tests, "test-amp-shell-helper.sh"
# (plan L1180-L1198), §Amp command surface (L778-L800), §Amp run-key
# durability (L156-L162). Resolved spike: docs/AMP.md §"Phase 2 Spike
# Findings" (commit bbb8fd8 — T012).
#
# DIVERGENCE FROM ORIGINAL TASK SPEC. The plan and the T013 task context
# describe the helper as `.amp/plugins/cerberus.ts`. The T012 spike
# determined that Amp CLI 0.0.1777572045-g97f3b8 does NOT expose a
# `.amp/plugins/` loader; the actual extension surface is the Amp
# Toolbox (subprocess scripts driven by the TOOLBOX_ACTION env var).
# The helper therefore lives at `.amp/toolbox/cerberus.sh` and this
# test drives that surface. See docs/AMP.md §Phase 2 Spike Findings
# for the source of truth on the pivot.
#
# Coverage matrix (9 cases from plan L1182-L1198). After T013 (this
# file) every numbered case below is a TODO-stub that prints a
# "T014: not yet implemented" marker and is counted in
# TODOS_REMAINING (not in FAILED). T014 lands the real assertions —
# env mapping, AMP_THREAD_ID resolution, persisted-UUID fallback at
# ~/.cerberus/runtime/amp/<workspace-key>/active-session.json — flips
# each TODO to a real PASS/FAIL, and removes its entry from
# TODOS_REMAINING.
#
# Three HAPPY-PATH cases exist today and MUST PASS at T013 — they
# confirm that the stub `.amp/toolbox/cerberus.sh` (a) is wired,
# executable, on the expected path, (b) emits a valid describe payload
# listing the six Cerberus commands when invoked with
# TOOLBOX_ACTION=describe, and (c) emits a NotImplemented marker (not
# a missing-command or shell error) when invoked with
# TOOLBOX_ACTION=execute. These probes protect the right-reason
# failure mode demanded by the T013 acceptance criteria
# (`AC-amp-helper-test-fails-for-right-reason`): T014's failing tests
# should fail because the env-mapping / thread-id-resolution /
# fallback-UUID logic is missing, not because the script entry point
# is missing or broken.
#
# Coverage matrix (plan L1182-L1198 verbatim):
#
#   Case 1 (TODO T014): Thread id present — `AMP_THREAD_ID` used as
#                       run key (renamed from plan's `ctx.thread.id`
#                       per docs/AMP.md OQ-3 resolution).
#   Case 2 (TODO T014): Thread id absent — UUID generated, persisted
#                       at
#                       ~/.cerberus/runtime/amp/<workspace-key>/active-session.json.
#   Case 3 (TODO T014): Second invocation reads persisted UUID; same
#                       run key returned.
#   Case 4 (TODO T014): Env mapping completeness — spawned
#                       bin/review-gate invocation includes all
#                       required CERBERUS_* vars (CERBERUS_HOST=amp,
#                       CERBERUS_ROOT, CERBERUS_PROJECT_KEY,
#                       CERBERUS_RUN_KEY).
#   Case 5 (TODO T014): CLAUDE_PLUGIN_ROOT compat alias still passed
#                       during migration window.
#   Case 6 (TODO T014): Run key surfaced in stdout — command output
#                       contains run key for user pass-through (plan
#                       exit criterion §964).
#   Case 7 (TODO T014): Missing backend — clear diagnostic surfaced
#                       when bin/review-gate not on path.
#   Case 8 (TODO T014): Missing reviewer CLI — error from backend
#                       surfaced cleanly.
#   Case 9 (TODO T014): Thread id flips mid-session — helper detects
#                       mismatch with persisted value, logs warning,
#                       uses persisted UUID for continuity.
#
# Happy path A (PASS today): stub script exists, is a regular file,
#   and is executable.
# Happy path B (PASS today): TOOLBOX_ACTION=describe emits valid JSON
#   listing the six commands (review-code, review-plan, review-spec,
#   ask-panel, status, clear-gate) — Amp's enumeration surface.
# Happy path C (PASS today): TOOLBOX_ACTION=execute with a valid
#   command on stdin emits valid JSON with status=not_implemented and
#   task=T014 — confirms the helper fails for the right reason
#   (NotImplemented), not for a missing entrypoint.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLBOX_SCRIPT="$REPO_ROOT/.amp/toolbox/cerberus.sh"

if [[ ! -f "$TOOLBOX_SCRIPT" ]]; then
    echo "FATAL: .amp/toolbox/cerberus.sh not found at $TOOLBOX_SCRIPT" >&2
    exit 2
fi
if [[ ! -x "$TOOLBOX_SCRIPT" ]]; then
    echo "FATAL: .amp/toolbox/cerberus.sh not executable at $TOOLBOX_SCRIPT" >&2
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "FATAL: jq required for these tests but is not on PATH" >&2
    exit 2
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
GRAY='\033[0;37m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TODOS_REMAINING=0
TEST_DIR=""

cleanup() {
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

TEST_DIR="$(mktemp -d -t cerberus-amp-shell-helper.XXXXXX)"

log_test() { echo -e "${YELLOW}TEST:${NC} $1"; }
log_pass() { echo -e "${GREEN}PASS:${NC} $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
log_fail() { echo -e "${RED}FAIL:${NC} $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }
# log_todo: scaffold marker for tests that T013 enumerates but does
# not implement. T014 flips these to real pass/fail. Counted in
# TODOS_REMAINING; does NOT contribute to TESTS_FAILED.
log_todo() {
    local task="$1"
    local label="$2"
    echo -e "${GRAY}TODO ${task}:${NC} ${label} — not yet implemented"
    TODOS_REMAINING=$((TODOS_REMAINING + 1))
}

# The six commands the toolbox describe action MUST enumerate. Order
# follows plan §Amp command surface table (L780-L787); equality (not
# subset) is asserted in Happy B.
EXPECTED_COMMANDS=(
    "review-code"
    "review-plan"
    "review-spec"
    "ask-panel"
    "status"
    "clear-gate"
)

# ---------------------------------------------------------------------------
# Case 1 — Thread id present: AMP_THREAD_ID used as run key.
# ---------------------------------------------------------------------------
log_test "Case 1 — AMP_THREAD_ID present, used as run key"
log_todo "T014" "Case 1 — AMP_THREAD_ID present, used as run key"

# ---------------------------------------------------------------------------
# Case 2 — Thread id absent: UUID generated and persisted.
# ---------------------------------------------------------------------------
log_test "Case 2 — AMP_THREAD_ID absent; UUID generated + persisted"
log_todo "T014" "Case 2 — AMP_THREAD_ID absent; UUID generated + persisted"

# ---------------------------------------------------------------------------
# Case 3 — Second invocation reads persisted UUID; same run key returned.
# ---------------------------------------------------------------------------
log_test "Case 3 — second invocation reads persisted UUID"
log_todo "T014" "Case 3 — second invocation reads persisted UUID"

# ---------------------------------------------------------------------------
# Case 4 — Env mapping completeness for spawned bin/review-gate.
# ---------------------------------------------------------------------------
log_test "Case 4 — env mapping (CERBERUS_HOST=amp, _ROOT, _PROJECT_KEY, _RUN_KEY)"
log_todo "T014" "Case 4 — env mapping (CERBERUS_HOST=amp, _ROOT, _PROJECT_KEY, _RUN_KEY)"

# ---------------------------------------------------------------------------
# Case 5 — CLAUDE_PLUGIN_ROOT compat alias still passed.
# ---------------------------------------------------------------------------
log_test "Case 5 — CLAUDE_PLUGIN_ROOT compat alias still passed"
log_todo "T014" "Case 5 — CLAUDE_PLUGIN_ROOT compat alias still passed"

# ---------------------------------------------------------------------------
# Case 6 — Run key surfaced in stdout for user pass-through.
# ---------------------------------------------------------------------------
log_test "Case 6 — run key surfaced in stdout"
log_todo "T014" "Case 6 — run key surfaced in stdout"

# ---------------------------------------------------------------------------
# Case 7 — Missing backend: clear diagnostic surfaced.
# ---------------------------------------------------------------------------
log_test "Case 7 — missing backend (bin/review-gate) — clear diagnostic"
log_todo "T014" "Case 7 — missing backend (bin/review-gate) — clear diagnostic"

# ---------------------------------------------------------------------------
# Case 8 — Missing reviewer CLI: error from backend surfaced cleanly.
# ---------------------------------------------------------------------------
log_test "Case 8 — missing reviewer CLI — backend error surfaced"
log_todo "T014" "Case 8 — missing reviewer CLI — backend error surfaced"

# ---------------------------------------------------------------------------
# Case 9 — Thread id flips mid-session: helper detects mismatch, logs
# warning, uses persisted UUID for continuity.
# ---------------------------------------------------------------------------
log_test "Case 9 — AMP_THREAD_ID mismatch with persisted UUID — continuity"
log_todo "T014" "Case 9 — AMP_THREAD_ID mismatch with persisted UUID — continuity"

# ---------------------------------------------------------------------------
# Happy path A — stub script entry point exists, executable, on path.
# ---------------------------------------------------------------------------
log_test "Happy A — .amp/toolbox/cerberus.sh exists, is a regular file, executable"
if [[ -f "$TOOLBOX_SCRIPT" && -x "$TOOLBOX_SCRIPT" ]]; then
    log_pass "Happy A — stub entry point present and executable"
else
    log_fail "Happy A — stub entry point missing or not executable: $TOOLBOX_SCRIPT"
fi

# ---------------------------------------------------------------------------
# Happy path B — TOOLBOX_ACTION=describe emits valid JSON listing the
# six commands. We invoke the script with TOOLBOX_ACTION=describe in
# a clean subshell, then assert (a) exit 0, (b) valid JSON on stdout,
# (c) the `commands` array equals EXPECTED_COMMANDS in order. Order
# parity is asserted (not just subset) so plan §Amp command surface
# table parity remains a hard contract — T014's expansion of the
# describe payload (e.g. adding command-level inputSchema entries)
# must still preserve this enumeration.
# ---------------------------------------------------------------------------
log_test "Happy B — TOOLBOX_ACTION=describe lists six Cerberus commands"
hb_out="$TEST_DIR/happy-b.out"
hb_err="$TEST_DIR/happy-b.err"
hb_rc=0
TOOLBOX_ACTION=describe "$TOOLBOX_SCRIPT" >"$hb_out" 2>"$hb_err" || hb_rc=$?
if [[ "$hb_rc" -ne 0 ]]; then
    log_fail "Happy B — describe exited with $hb_rc; stderr=$(cat "$hb_err")"
elif ! jq -e . "$hb_out" >/dev/null 2>&1; then
    log_fail "Happy B — describe stdout is not valid JSON: $(cat "$hb_out")"
else
    # Compare the actual `commands` array against the expected list
    # entry-by-entry, in order. jq's `--argjson` plus `.commands ==`
    # would also work, but a literal-equality check is easier to
    # diagnose if it diverges.
    actual_count=$(jq -r '.commands | length' "$hb_out" 2>/dev/null || echo "0")
    expected_count="${#EXPECTED_COMMANDS[@]}"
    if [[ "$actual_count" != "$expected_count" ]]; then
        log_fail "Happy B — commands count mismatch: expected=$expected_count actual=$actual_count body=$(cat "$hb_out")"
    else
        mismatch=""
        for i in "${!EXPECTED_COMMANDS[@]}"; do
            actual=$(jq -r ".commands[$i]" "$hb_out" 2>/dev/null || echo "")
            expected="${EXPECTED_COMMANDS[$i]}"
            if [[ "$actual" != "$expected" ]]; then
                mismatch="index=$i expected='$expected' actual='$actual'"
                break
            fi
        done
        if [[ -n "$mismatch" ]]; then
            log_fail "Happy B — commands list mismatch ($mismatch); body=$(cat "$hb_out")"
        else
            log_pass "Happy B — describe lists six commands in expected order"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Happy path C — TOOLBOX_ACTION=execute with a valid command on stdin
# emits valid JSON with status=not_implemented and task=T014. This
# confirms the helper fails for the RIGHT REASON (NotImplemented
# marker, T014 placeholder), not for a missing entrypoint, missing
# dispatch field handler, or shell-level error.
# ---------------------------------------------------------------------------
log_test "Happy C — TOOLBOX_ACTION=execute returns NotImplemented marker"
hc_out="$TEST_DIR/happy-c.out"
hc_err="$TEST_DIR/happy-c.err"
hc_rc=0
echo '{"command":"review-code"}' \
    | TOOLBOX_ACTION=execute "$TOOLBOX_SCRIPT" >"$hc_out" 2>"$hc_err" || hc_rc=$?
if [[ "$hc_rc" -ne 0 ]]; then
    log_fail "Happy C — execute exited with $hc_rc; stderr=$(cat "$hc_err")"
elif ! jq -e . "$hc_out" >/dev/null 2>&1; then
    log_fail "Happy C — execute stdout is not valid JSON: $(cat "$hc_out")"
else
    hc_status=$(jq -r '.status // empty' "$hc_out")
    hc_task=$(jq -r '.task // empty' "$hc_out")
    if [[ "$hc_status" == "not_implemented" && "$hc_task" == "T014" ]]; then
        log_pass "Happy C — execute returns {status:not_implemented, task:T014}"
    else
        log_fail "Happy C — expected status=not_implemented task=T014; got status='$hc_status' task='$hc_task' body=$(cat "$hc_out")"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "----------------------------------------"
echo "Amp shell-helper test scaffold summary:"
echo "  Passed:  $TESTS_PASSED"
echo "  Failed:  $TESTS_FAILED"
echo "  TODO (T014): $TODOS_REMAINING"
echo "----------------------------------------"

# Exit non-zero only if a test that is supposed to PASS today (the
# happy-path probes) fails. TODOs are expected scaffolds and do not
# block the verification gate during Phase 2 skeleton (T013). T014
# converts each TODO into a real test and the script becomes strictly
# pass/fail at that point.
if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
