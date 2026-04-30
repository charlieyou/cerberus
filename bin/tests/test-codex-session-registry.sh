#!/usr/bin/env bash
# T007 — Phase 1 scaffold for the Codex session-registry adapter
# (`bin/codex-session-init`).
#
# Plan reference: §Phase 1 — Codex Tests, "test-codex-session-registry.sh"
# (plan L1136-L1149) and §Data Model, "Codex session registry" (plan
# L478-L508) plus the atomic-write algorithm (plan L509-L523).
#
# Coverage matrix (7 cases). After T007 (this file) every numbered case
# below is a TODO-stub that prints a "T008: not yet implemented" marker
# and is counted in TODOS_REMAINING (not in FAILED). T008 lands the real
# assertions, flips each TODO to a real PASS/FAIL, and removes its
# entry from TODOS_REMAINING.
#
# Two HAPPY-PATH cases exist today and MUST PASS at T007 — they confirm
# that the stub `bin/codex-session-init` (a) is wired, executable, on
# the expected path, and (b) reads stdin and emits valid JSON with
# exit 0. They protect the right-reason failure mode demanded by the
# T007 acceptance criteria: T008's failing tests should fail because
# the registry write logic is missing, not because the script entry
# point is missing or broken.
#
# Coverage matrix:
#
#   Case 1 (TODO T008): Fresh SessionStart writes registry with all
#                       required fields per schema v1.
#   Case 2 (TODO T008): Second SessionStart updates last_seen and
#                       preserves run_key when the Codex session id is
#                       unchanged.
#   Case 3 (TODO T008): Concurrent writes (background jobs, distinct
#                       PIDs): both `tmp.$$` files exist transiently;
#                       final state is one valid JSON; last writer
#                       wins.
#   Case 4 (TODO T008): Registry parent directory missing → mkdir -p
#                       succeeds; registry written.
#   Case 5 (TODO T008): Malformed existing registry is overwritten
#                       cleanly (no read-before-write parse failure).
#   Case 6 (TODO T008): Atomic-write validation: kill writer between
#                       temp creation and `mv` → no
#                       `active-session.json` exists; only orphan tmp
#                       file (which T008 documents as best-effort
#                       cleanup target).
#   Case 7 (TODO T008): Schema correctness: written JSON validates
#                       against the registry schema (v1 fields).
#
# Happy path A (PASS today): stub is executable on PATH layout the
#   Codex hook template expects.
# Happy path B (PASS today): stub reads stdin without error and emits
#   valid JSON to stdout with exit 0.

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

TEST_DIR="$(mktemp -d -t cerberus-codex-session-registry.XXXXXX)"

log_test() { echo -e "${YELLOW}TEST:${NC} $1"; }
log_pass() { echo -e "${GREEN}PASS:${NC} $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
log_fail() { echo -e "${RED}FAIL:${NC} $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }
# log_todo: scaffold marker for tests that T007 enumerates but does not
# implement. Future tasks (e.g. T008) flip these to real pass/fail.
# Counted in TODOS_REMAINING; does NOT contribute to TESTS_FAILED.
log_todo() {
    local task="$1"
    local label="$2"
    echo -e "${GRAY}TODO ${task}:${NC} ${label} — not yet implemented"
    TODOS_REMAINING=$((TODOS_REMAINING + 1))
}

# ---------------------------------------------------------------------------
# Case 1 — Fresh SessionStart writes registry with all required fields.
# ---------------------------------------------------------------------------
log_test "Case 1 — fresh SessionStart writes registry (schema v1)"
log_todo "T008" "Case 1 — fresh SessionStart writes registry (schema v1)"

# ---------------------------------------------------------------------------
# Case 2 — Second SessionStart updates last_seen, preserves run_key.
# ---------------------------------------------------------------------------
log_test "Case 2 — second SessionStart updates last_seen, preserves run_key"
log_todo "T008" "Case 2 — second SessionStart updates last_seen, preserves run_key"

# ---------------------------------------------------------------------------
# Case 3 — Concurrent writes; last writer wins.
# ---------------------------------------------------------------------------
log_test "Case 3 — concurrent writes converge to one valid JSON"
log_todo "T008" "Case 3 — concurrent writes converge to one valid JSON"

# ---------------------------------------------------------------------------
# Case 4 — Registry directory missing → mkdir -p succeeds.
# ---------------------------------------------------------------------------
log_test "Case 4 — registry directory missing; mkdir -p succeeds"
log_todo "T008" "Case 4 — registry directory missing; mkdir -p succeeds"

# ---------------------------------------------------------------------------
# Case 5 — Malformed existing registry overwritten cleanly.
# ---------------------------------------------------------------------------
log_test "Case 5 — malformed existing registry overwritten cleanly"
log_todo "T008" "Case 5 — malformed existing registry overwritten cleanly"

# ---------------------------------------------------------------------------
# Case 6 — Atomic-write validation under writer-kill.
# ---------------------------------------------------------------------------
log_test "Case 6 — atomic-write: kill writer pre-mv leaves no active-session.json"
log_todo "T008" "Case 6 — atomic-write: kill writer pre-mv leaves no active-session.json"

# ---------------------------------------------------------------------------
# Case 7 — Schema correctness against schema v1 fields.
# ---------------------------------------------------------------------------
log_test "Case 7 — written JSON validates against registry schema v1"
log_todo "T008" "Case 7 — written JSON validates against registry schema v1"

# ---------------------------------------------------------------------------
# Happy path A — stub script entry point exists, executable, on path.
# ---------------------------------------------------------------------------
log_test "Happy A — bin/codex-session-init exists, is a regular file, executable"
if [[ -f "$CODEX_SESSION_INIT" && -x "$CODEX_SESSION_INIT" ]]; then
    log_pass "Happy A — stub entry point present and executable"
else
    log_fail "Happy A — stub entry point missing or not executable: $CODEX_SESSION_INIT"
fi

# ---------------------------------------------------------------------------
# Happy path B — stub reads stdin and emits valid JSON with exit 0.
# ---------------------------------------------------------------------------
log_test "Happy B — stub reads stdin and emits valid JSON, exit 0"
hb_out="$TEST_DIR/happy-b.out"
hb_err="$TEST_DIR/happy-b.err"
hb_rc=0
printf '{"session_id":"sess-abc","cwd":"%s"}\n' "$TEST_DIR" \
    | "$CODEX_SESSION_INIT" >"$hb_out" 2>"$hb_err" || hb_rc=$?
if [[ "$hb_rc" -ne 0 ]]; then
    log_fail "Happy B — stub exited with $hb_rc; stderr=$(cat "$hb_err")"
elif ! command -v jq >/dev/null 2>&1; then
    # If jq isn't available, fall back to a non-empty + braces check.
    if [[ -s "$hb_out" ]] && grep -q '{' "$hb_out" && grep -q '}' "$hb_out"; then
        log_pass "Happy B — stub emitted braces-bounded payload (jq absent; coarse check)"
    else
        log_fail "Happy B — stub output not braces-bounded (jq absent): $(cat "$hb_out")"
    fi
elif ! jq -e . "$hb_out" >/dev/null 2>&1; then
    log_fail "Happy B — stub stdout is not valid JSON: $(cat "$hb_out")"
else
    log_pass "Happy B — stub emitted valid JSON, exit 0"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "----------------------------------------"
echo "Codex session-registry test scaffold summary:"
echo "  Passed:  $TESTS_PASSED"
echo "  Failed:  $TESTS_FAILED"
echo "  TODO (T008): $TODOS_REMAINING"
echo "----------------------------------------"

# Exit non-zero only if a test that is supposed to PASS today (the
# happy-path probes) fails. TODOs are expected scaffolds and do not
# block the verification gate during Phase 1 skeleton (T007). T008
# converts each TODO into a real test and the script becomes strictly
# pass/fail at that point.
if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
