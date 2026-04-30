#!/usr/bin/env bash
# T007 — Phase 1 scaffold for the Codex Stop adapter
# (`bin/codex-stop-hook`).
#
# Plan reference: §Phase 1 — Codex Tests, "test-codex-stop-hook.sh"
# (plan L1151-L1178) and §Codex Stop Decision Matrix (plan L732-L766).
#
# Coverage matrix (15 cases). After T007 (this file) every numbered
# case below is a TODO-stub that prints a "T009: not yet implemented"
# marker and is counted in TODOS_REMAINING (not in FAILED). T009 lands
# the real assertions, flips each TODO to a real PASS/FAIL, and removes
# its entry from TODOS_REMAINING.
#
# Three HAPPY-PATH cases exist today and MUST PASS at T007 — they
# confirm that the stub `bin/codex-stop-hook` (a) is wired and
# executable, (b) reads stdin and emits valid `{"action":"allow",...}`
# JSON with exit 0 (failure-open default), and (c) installs the signal
# trap from day one (plan §Phase 1 exit criteria L760-L765). The trap
# baseline is verified by static inspection of the script source so the
# scaffold does not depend on race-prone signal timing.
#
# Coverage matrix:
#
#   Case 1 (TODO T009): Row 1 — no registry → {"action":"allow"}.
#   Case 2 (TODO T009): Row 2 — registry → no run dir → allow.
#   Case 3 (TODO T009): Row 4 — pending,
#                        CERBERUS_CODEX_STOP_WAIT_SECONDS=0 →
#                        {"action":"allow","note":"..."}.
#   Case 4 (TODO T009): Row 5a — pending, wait knob N=2, reviewers
#                        don't finish → fall through to allow with
#                        "still running" note.
#   Case 5 (TODO T009): Row 5b — pending, wait knob N=2, reviewers
#                        finish during wait → re-evaluate via
#                        rows 6/7/8/9.
#   Case 6 (TODO T009): Row 6 — awaiting decision, blocking findings
#                        → {"action":"continue","userMessage":"..."}.
#   Case 7 (TODO T009): Row 8 — resolved pass → {"action":"allow"}.
#   Case 8 (TODO T009): Row 9 — resolved fail (manual clear or
#                        otherwise) → {"action":"continue", ...}.
#   Case 9 (TODO T009): Row 10 — malformed gate-state.json →
#                        {"action":"allow","note":
#                          "cerberus state unreadable; allowing stop"}.
#   Case 10 (TODO T009): Row 11 — `status --json` exits 2 →
#                        {"action":"allow"}, diagnostic logged.
#   Case 11 (TODO T009): Row 12 — `jq` missing on PATH →
#                        {"action":"allow"}.
#   Case 12 (TODO T009): Row 13a — SIGTERM mid-execution →
#                        {"action":"allow"} emitted, exit 0.
#   Case 13 (TODO T009): Row 13b — SIGINT during child wait → child
#                        killed via stored PID, allow emitted.
#   Case 14 (TODO T009): Row 13c — SIGHUP during child wait — same as
#                        13b.
#   Case 15 (TODO T009): Stdin parse failure: invalid Codex JSON on
#                        stdin → {"action":"allow"}, diagnostic.
#
# Happy path A (PASS today): stub is wired and executable.
# Happy path B (PASS today): stub reads stdin and emits valid
#                            {"action":"allow",...} JSON, exit 0.
# Happy path C (PASS today): signal trap baseline is installed at
#                            startup (static inspection). Plan
#                            §Phase 1 exit criterion L760-L765.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_STOP_HOOK="$SCRIPT_DIR/../codex-stop-hook"

if [[ ! -f "$CODEX_STOP_HOOK" ]]; then
    echo "FATAL: bin/codex-stop-hook not found at $CODEX_STOP_HOOK" >&2
    exit 2
fi
if [[ ! -x "$CODEX_STOP_HOOK" ]]; then
    echo "FATAL: bin/codex-stop-hook not executable at $CODEX_STOP_HOOK" >&2
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

TEST_DIR="$(mktemp -d -t cerberus-codex-stop-hook.XXXXXX)"

log_test() { echo -e "${YELLOW}TEST:${NC} $1"; }
log_pass() { echo -e "${GREEN}PASS:${NC} $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
log_fail() { echo -e "${RED}FAIL:${NC} $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }
log_todo() {
    local task="$1"
    local label="$2"
    echo -e "${GRAY}TODO ${task}:${NC} ${label} — not yet implemented"
    TODOS_REMAINING=$((TODOS_REMAINING + 1))
}

# ---------------------------------------------------------------------------
# Cases 1-15 — Stop Decision Matrix scaffolds (T009 lands assertions).
# ---------------------------------------------------------------------------
log_test "Case 1 — Row 1: no registry → allow"
log_todo "T009" "Case 1 — Row 1: no registry → allow"

log_test "Case 2 — Row 2: registry but no run dir → allow"
log_todo "T009" "Case 2 — Row 2: registry but no run dir → allow"

log_test "Case 3 — Row 4: pending + WAIT=0 → allow with 'still running' note"
log_todo "T009" "Case 3 — Row 4: pending + WAIT=0 → allow w/ note"

log_test "Case 4 — Row 5a: pending + WAIT=N, reviewers don't finish → allow"
log_todo "T009" "Case 4 — Row 5a: pending + WAIT=N timeout"

log_test "Case 5 — Row 5b: pending + WAIT=N, reviewers finish → re-evaluate"
log_todo "T009" "Case 5 — Row 5b: pending + WAIT=N completes mid-wait"

log_test "Case 6 — Row 6: awaiting_decision + blocking findings → continue"
log_todo "T009" "Case 6 — Row 6: awaiting + blocking findings → continue"

log_test "Case 7 — Row 8: resolved pass → allow"
log_todo "T009" "Case 7 — Row 8: resolved pass → allow"

log_test "Case 8 — Row 9: resolved fail → continue with reason"
log_todo "T009" "Case 8 — Row 9: resolved fail → continue"

log_test "Case 9 — Row 10: malformed gate-state.json → allow w/ unreadable note"
log_todo "T009" "Case 9 — Row 10: malformed gate-state.json"

log_test "Case 10 — Row 11: status --json exits 2 → allow + stderr diagnostic"
log_todo "T009" "Case 10 — Row 11: status non-zero non-4"

log_test "Case 11 — Row 12: jq missing on PATH → allow"
log_todo "T009" "Case 11 — Row 12: jq missing"

log_test "Case 12 — Row 13a: SIGTERM mid-execution → allow, exit 0"
log_todo "T009" "Case 12 — Row 13a: SIGTERM mid-execution"

log_test "Case 13 — Row 13b: SIGINT during child wait → child killed + allow"
log_todo "T009" "Case 13 — Row 13b: SIGINT during child wait"

log_test "Case 14 — Row 13c: SIGHUP during child wait → child killed + allow"
log_todo "T009" "Case 14 — Row 13c: SIGHUP during child wait"

log_test "Case 15 — invalid Codex JSON on stdin → allow + diagnostic"
log_todo "T009" "Case 15 — stdin parse failure"

# ---------------------------------------------------------------------------
# Happy path A — stub script entry point exists, executable, on path.
# ---------------------------------------------------------------------------
log_test "Happy A — bin/codex-stop-hook exists, is a regular file, executable"
if [[ -f "$CODEX_STOP_HOOK" && -x "$CODEX_STOP_HOOK" ]]; then
    log_pass "Happy A — stub entry point present and executable"
else
    log_fail "Happy A — stub entry point missing or not executable: $CODEX_STOP_HOOK"
fi

# ---------------------------------------------------------------------------
# Happy path B — stub reads stdin and emits valid {"action":"allow"} JSON.
# ---------------------------------------------------------------------------
log_test "Happy B — stub reads stdin and emits {action:allow}, exit 0"
hb_out="$TEST_DIR/happy-b.out"
hb_err="$TEST_DIR/happy-b.err"
hb_rc=0
printf '{"session_id":"sess-abc","cwd":"%s"}\n' "$TEST_DIR" \
    | "$CODEX_STOP_HOOK" >"$hb_out" 2>"$hb_err" || hb_rc=$?
hb_action=""
if [[ "$hb_rc" -ne 0 ]]; then
    log_fail "Happy B — stub exited with $hb_rc; stderr=$(cat "$hb_err")"
elif command -v jq >/dev/null 2>&1; then
    if ! jq -e . "$hb_out" >/dev/null 2>&1; then
        log_fail "Happy B — stub stdout is not valid JSON: $(cat "$hb_out")"
    else
        hb_action=$(jq -r '.action // empty' "$hb_out" 2>/dev/null || echo "")
        if [[ "$hb_action" == "allow" ]]; then
            log_pass "Happy B — stub emitted {action:allow}, exit 0"
        else
            log_fail "Happy B — stub action=$hb_action expected 'allow'; body=$(cat "$hb_out")"
        fi
    fi
else
    # jq absent: coarse string match.
    if grep -q '"action"[[:space:]]*:[[:space:]]*"allow"' "$hb_out"; then
        log_pass "Happy B — stub emitted action:allow (jq absent; coarse check)"
    else
        log_fail "Happy B — stub did not emit action:allow (jq absent): $(cat "$hb_out")"
    fi
fi

# ---------------------------------------------------------------------------
# Happy path C — signal trap baseline installed at startup.
# Static inspection: the stub MUST install a trap on INT TERM HUP so a
# Codex deployment that picks up T007's stub before T009's matrix is
# implemented still fails open under signal delivery. This is the
# Phase 1 exit criterion at plan L760-L765.
# ---------------------------------------------------------------------------
log_test "Happy C — codex-stop-hook installs signal trap at startup"
# Match a literal "trap '...' INT TERM HUP" line outside comments. The
# stub installs exactly this; T009 may add a richer handler body but
# MUST keep the same trap surface.
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
echo "Codex Stop hook test scaffold summary:"
echo "  Passed:  $TESTS_PASSED"
echo "  Failed:  $TESTS_FAILED"
echo "  TODO (T009): $TODOS_REMAINING"
echo "----------------------------------------"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
