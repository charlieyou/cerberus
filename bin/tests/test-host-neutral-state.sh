#!/usr/bin/env bash
# T001 integration-path test for the Phase 0 host-neutral state resolver.
#
# Plan reference: §Phase 0 Tests (L1074-L1113) and §State Resolution
# Algorithm (L300-L353).
#
# Coverage matrix (15 rows). T001 turns rows 1-7 GREEN — these are the
# resolver-only behaviors implemented directly by the changes to
# resolve_review_dir() and get_project_hash() in bin/review-gate-lib.sh
# plus the centralized helpers in bin/review-gate. Rows 8-15 are scaffolded
# placeholders that explain which downstream task wires them up:
#
#   Row  8: T002 — alias precedence + once-per-process warning
#   Row  9: T002 — alias-only legacy run key
#   Row 10: T002 — empty-string env vars treated as unset
#   Row 11: T004 — concurrent runs in same project
#   Row 12: T002 — missing run key in generic mode (fail diagnostic)
#   Row 13: T004 — invalid CERBERUS_STATE_ROOT diagnostics through bin/review-gate
#   Row 14: T004 — path-traversal rejection through bin/review-gate
#   Row 15: T002/T003 — wait + status --session-key under neutral state
#
# Skipped rows still emit log_skip lines so downstream tasks know exactly
# which scaffold rows to flip to assertions.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_PATH="$SCRIPT_DIR/../review-gate-lib.sh"
REVIEW_GATE="$SCRIPT_DIR/../review-gate"

if [[ ! -f "$LIB_PATH" ]]; then
    echo "FATAL: review-gate-lib.sh not found at $LIB_PATH" >&2
    exit 2
fi
if [[ ! -x "$REVIEW_GATE" ]]; then
    echo "FATAL: review-gate not executable at $REVIEW_GATE" >&2
    exit 2
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
GRAY='\033[0;37m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
TEST_DIR=""

cleanup() {
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

TEST_DIR="$(mktemp -d -t cerberus-host-neutral.XXXXXX)"
TEST_HOME="$TEST_DIR/home"
mkdir -p "$TEST_HOME"

log_test() { echo -e "${YELLOW}TEST:${NC} $1"; }
log_pass() { echo -e "${GREEN}PASS:${NC} $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
log_fail() { echo -e "${RED}FAIL:${NC} $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }
log_skip() { echo -e "${GRAY}SKIP:${NC} $1"; TESTS_SKIPPED=$((TESTS_SKIPPED + 1)); }

# Run resolve_review_dir() in a clean subshell with controlled env. The
# subshell isolates env mutations so each row is independent.
#
# Args:
#   $1  newline-separated VAR=value list (will be eval-exported); pass "" to
#       export nothing beyond HOME.
#   $2  session_id positional arg
#   $3  transcript_path positional arg
#   $4  HOME override (defaults to $TEST_HOME)
#
# Stdout: resolver output (or empty on failure).
# Stderr: resolver diagnostics if any.
# Returns: resolver exit code.
resolve_in_subshell() {
    local env_block="$1"
    local sid="$2"
    local tp="$3"
    local home_override="${4:-$TEST_HOME}"
    (
        unset CERBERUS_HOST CERBERUS_RUN_KEY CERBERUS_STATE_ROOT \
              CERBERUS_PROJECT_KEY CERBERUS_SESSION_ID \
              CERBERUS_TRANSCRIPT_PATH CERBERUS_ROOT \
              REVIEW_GATE_SESSION_KEY \
              CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH CLAUDE_PROJECT_DIR \
              __CERBERUS_ALIAS_WARNED || true
        export HOME="$home_override"
        if [[ -n "$env_block" ]]; then
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                # shellcheck disable=SC2163
                export "$line"
            done <<<"$env_block"
        fi
        # shellcheck disable=SC1090
        source "$LIB_PATH" >/dev/null 2>&1
        resolve_review_dir "$sid" "$tp"
    )
}

assert_resolved_eq() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        log_pass "$label"
    else
        log_fail "$label: expected='$expected' actual='$actual'"
    fi
}

# ---------------------------------------------------------------------------
# Row 1 — Legacy Claude path (byte-for-byte equivalence).
# No CERBERUS_*; full Claude env. Expected: legacy ~/.claude/projects layout.
# ---------------------------------------------------------------------------
log_test "Row 1 — legacy Claude path (no CERBERUS_*, full Claude env)"
ROW1_TP="$TEST_HOME/.claude/projects/-tmp-row1/sess.jsonl"
ROW1_SID="claude-sess-001"
row1_env="$(cat <<EOF
CLAUDE_SESSION_ID=$ROW1_SID
CLAUDE_TRANSCRIPT_PATH=$ROW1_TP
EOF
)"
row1_actual="$(resolve_in_subshell "$row1_env" "$ROW1_SID" "$ROW1_TP")"
row1_expected="$TEST_HOME/.claude/projects/-tmp-row1/cerberus/$ROW1_SID"
assert_resolved_eq "Row 1: legacy Claude byte-for-byte" "$row1_expected" "$row1_actual"

# ---------------------------------------------------------------------------
# Row 2 — Generic neutral path.
# CERBERUS_HOST=generic + project + run keys → ~/.cerberus/projects/<key>/<run>.
# ---------------------------------------------------------------------------
log_test "Row 2 — generic neutral path (CERBERUS_HOST=generic)"
row2_env="$(cat <<EOF
CERBERUS_HOST=generic
CERBERUS_PROJECT_KEY=row2-key
CERBERUS_RUN_KEY=row2-run
EOF
)"
row2_actual="$(resolve_in_subshell "$row2_env" "" "")"
row2_expected="$TEST_HOME/.cerberus/projects/row2-key/row2-run"
assert_resolved_eq "Row 2: generic neutral layout" "$row2_expected" "$row2_actual"

# ---------------------------------------------------------------------------
# Row 3 — Codex neutral path.
# Same shape as Row 2 with CERBERUS_HOST=codex.
# ---------------------------------------------------------------------------
log_test "Row 3 — codex neutral path (CERBERUS_HOST=codex)"
row3_env="$(cat <<EOF
CERBERUS_HOST=codex
CERBERUS_PROJECT_KEY=row3-key
CERBERUS_RUN_KEY=row3-run
EOF
)"
row3_actual="$(resolve_in_subshell "$row3_env" "" "")"
row3_expected="$TEST_HOME/.cerberus/projects/row3-key/row3-run"
assert_resolved_eq "Row 3: codex neutral layout" "$row3_expected" "$row3_actual"

# ---------------------------------------------------------------------------
# Row 4 — Amp neutral path.
# Same shape as Row 2 with CERBERUS_HOST=amp.
# ---------------------------------------------------------------------------
log_test "Row 4 — amp neutral path (CERBERUS_HOST=amp)"
row4_env="$(cat <<EOF
CERBERUS_HOST=amp
CERBERUS_PROJECT_KEY=row4-key
CERBERUS_RUN_KEY=row4-run
EOF
)"
row4_actual="$(resolve_in_subshell "$row4_env" "" "")"
row4_expected="$TEST_HOME/.cerberus/projects/row4-key/row4-run"
assert_resolved_eq "Row 4: amp neutral layout" "$row4_expected" "$row4_actual"

# ---------------------------------------------------------------------------
# Row 5 — Custom CERBERUS_STATE_ROOT override.
# Override reaches resolver output via the normal env path, not by mocking.
# ---------------------------------------------------------------------------
log_test "Row 5 — custom CERBERUS_STATE_ROOT override"
ROW5_ROOT="$TEST_DIR/custom-state"
row5_env="$(cat <<EOF
CERBERUS_HOST=generic
CERBERUS_STATE_ROOT=$ROW5_ROOT
CERBERUS_PROJECT_KEY=row5-key
CERBERUS_RUN_KEY=row5-run
EOF
)"
row5_actual="$(resolve_in_subshell "$row5_env" "" "")"
row5_expected="$ROW5_ROOT/row5-key/row5-run"
assert_resolved_eq "Row 5: CERBERUS_STATE_ROOT override" "$row5_expected" "$row5_actual"

# ---------------------------------------------------------------------------
# Row 6 — Host auto-detect from CLAUDE_SESSION_ID.
# No CERBERUS_HOST, but CLAUDE_SESSION_ID set → host=claude → legacy layout.
# ---------------------------------------------------------------------------
log_test "Row 6 — host auto-detect from CLAUDE_SESSION_ID"
row6_env="$(cat <<EOF
CLAUDE_SESSION_ID=row6-sid
CERBERUS_PROJECT_KEY=row6-key
CERBERUS_RUN_KEY=row6-run
EOF
)"
row6_actual="$(resolve_in_subshell "$row6_env" "" "")"
row6_expected="$TEST_HOME/.claude/projects/row6-key/cerberus/row6-run"
assert_resolved_eq "Row 6: auto-detect Claude from CLAUDE_SESSION_ID" "$row6_expected" "$row6_actual"

# ---------------------------------------------------------------------------
# Row 7 — Host auto-detect default (generic).
# No CERBERUS_HOST, no CLAUDE_*, and no transcript_path arg → host=generic.
# ---------------------------------------------------------------------------
log_test "Row 7 — host auto-detect default (no CLAUDE_*, no transcript)"
row7_env="$(cat <<EOF
CERBERUS_PROJECT_KEY=row7-key
CERBERUS_RUN_KEY=row7-run
EOF
)"
row7_actual="$(resolve_in_subshell "$row7_env" "" "")"
row7_expected="$TEST_HOME/.cerberus/projects/row7-key/row7-run"
assert_resolved_eq "Row 7: auto-detect default to generic" "$row7_expected" "$row7_actual"

# ---------------------------------------------------------------------------
# Row 8 — Run-key alias precedence + once-per-process warning.
# TODO(T002): assert (a) CERBERUS_RUN_KEY wins over REVIEW_GATE_SESSION_KEY
# when both set, (b) exactly one warning fires per process via
# __CERBERUS_ALIAS_WARNED, (c) a second invocation in the same process emits
# zero additional warnings.
# ---------------------------------------------------------------------------
log_test "Row 8 — alias precedence + once-per-process warning"
log_skip "Row 8: scaffolded; T002 turns this row green"

# ---------------------------------------------------------------------------
# Row 9 — Alias-only legacy.
# TODO(T002): only REVIEW_GATE_SESSION_KEY set (no CERBERUS_RUN_KEY) still
# resolves to .../<legacy-key>; no warning fires.
# ---------------------------------------------------------------------------
log_test "Row 9 — alias-only legacy run key"
log_skip "Row 9: scaffolded; T002 turns this row green"

# ---------------------------------------------------------------------------
# Row 10 — Empty-string env vars treated as unset.
# TODO(T002): CERBERUS_HOST="" + CLAUDE_SESSION_ID="" + transcript_path=""
# behaves as fully unset (host=generic), and CERBERUS_RUN_KEY="" falls
# through to REVIEW_GATE_SESSION_KEY (then session_id positional).
# ---------------------------------------------------------------------------
log_test "Row 10 — empty-string env vars treated as unset"
log_skip "Row 10: scaffolded; T002 turns this row green"

# ---------------------------------------------------------------------------
# Row 11 — Concurrent runs in same project resolve to distinct dirs.
# TODO(T004): two background spawns with distinct CERBERUS_RUN_KEYs in the
# same CERBERUS_PROJECT_KEY produce non-overlapping state directories;
# host/owner metadata recorded by T004 disambiguates them.
# ---------------------------------------------------------------------------
log_test "Row 11 — concurrent runs in same project (distinct dirs)"
log_skip "Row 11: scaffolded; T004 turns this row green"

# ---------------------------------------------------------------------------
# Row 12 — Missing run key in generic mode exits non-zero with diagnostic.
# TODO(T002): bin/review-gate spawn-* without a run key under
# CERBERUS_HOST=generic must fail safely with a diagnostic. The diagnostic
# wiring lives in the spawn surface, not the resolver, so this row activates
# in T002.
# ---------------------------------------------------------------------------
log_test "Row 12 — missing run key in generic mode (fail diagnostic)"
log_skip "Row 12: scaffolded; T002 turns this row green"

# ---------------------------------------------------------------------------
# Row 13 — Invalid CERBERUS_STATE_ROOT (empty / relative / literal '~').
# TODO(T004): exercises the failure-path diagnostics surfaced by
# bin/review-gate's state-creation paths. Resolver-level validation already
# rejects relative paths and literal '~' (T001); this row drives the
# end-to-end CLI surface.
# ---------------------------------------------------------------------------
log_test "Row 13 — invalid CERBERUS_STATE_ROOT (empty/relative/literal-tilde)"
log_skip "Row 13: scaffolded; T004 turns this row green"

# ---------------------------------------------------------------------------
# Row 14 — Path-traversal rejection on run-key / project-key.
# TODO(T004): values containing '/', '.', '..' are rejected end-to-end.
# Resolver-level rejection lives in T001; T004 wires CLI surface diagnostics.
# ---------------------------------------------------------------------------
log_test "Row 14 — path-traversal rejection on run-key/project-key"
log_skip "Row 14: scaffolded; T004 turns this row green"

# ---------------------------------------------------------------------------
# Row 15 — wait + status --session-key parity under neutral state.
# TODO(T002/T003): spawn under CERBERUS_RUN_KEY=k and verify BOTH
# wait --session-key k AND status --session-key k succeed without Claude
# env. Requires T002 (env propagation) and T003 (status subcommand).
# ---------------------------------------------------------------------------
log_test "Row 15 — wait + status --session-key parity under neutral state"
log_skip "Row 15: scaffolded; T002/T003 turn this row green"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "----------------------------------------"
echo "Host-neutral state test summary:"
echo "  Passed:  $TESTS_PASSED"
echo "  Failed:  $TESTS_FAILED"
echo "  Skipped: $TESTS_SKIPPED  (TODO rows for T002/T003/T004)"
echo "----------------------------------------"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
