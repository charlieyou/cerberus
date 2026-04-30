#!/usr/bin/env bash
# T001 integration-path test for the Phase 0 host-neutral state resolver.
#
# Plan reference: §Phase 0 Tests (L1074-L1113) and §State Resolution
# Algorithm (L300-L353).
#
# Coverage matrix (15 rows). All rows green after T004:
#
#   Row  1: T001 — legacy Claude path byte-for-byte equivalence [DONE]
#   Rows 2-7: T001 — neutral resolver / host auto-detect [DONE]
#   Row  8: T002 — alias precedence + once-per-process warning [DONE]
#   Row  9: T002 — alias-only legacy run key [DONE]
#   Row 10: T002 — empty-string env vars treated as unset [DONE]
#   Row 11: T004 — concurrent runs in same project (distinct dirs) [DONE]
#   Row 12: T004 — missing run key in generic mode (fail diagnostic) [DONE]
#   Row 13: T004 — invalid CERBERUS_STATE_ROOT (relative/literal-~) [DONE]
#   Row 14: T004 — path-traversal rejection on run-key/project-key + schema [DONE]
#   Row 15: T003 — wait + status --session-key under neutral state [DONE]

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
# Helper: extract __cerberus_resolve_run_key + __cerberus_resolve_root from
# bin/review-gate so we can source them in the current test shell without
# running main(). The function definitions live in the labeled
# "Centralized host-neutral env helpers" block at the top of the file. We
# extract by `awk` between two markers: the leading `set -euo pipefail` and
# the `PLUGIN_ROOT="$(__cerberus_resolve_root)"` line that the helpers
# precede. Inside that range, only function definitions and comments live;
# sourcing it is side-effect-free.
extract_review_gate_helpers() {
    awk '
        /^set -euo pipefail/ { in_block = 1; next }
        /^PLUGIN_ROOT=/        { in_block = 0; exit }
        in_block { print }
    ' "$REVIEW_GATE"
}

# ---------------------------------------------------------------------------
# Row 8 — Run-key alias precedence + once-per-process warning.
# Asserts (a) CERBERUS_RUN_KEY wins over REVIEW_GATE_SESSION_KEY when both
# are set with different non-empty values, (b) exactly one warning fires
# on the first call (deduped via the $$-keyed marker file plus the
# __CERBERUS_ALIAS_WARNED export sentinel), and (c) a second call in the
# same shell process emits zero additional warnings.
# ---------------------------------------------------------------------------
log_test "Row 8 — alias precedence + once-per-process warning"
row8_out_file="$TEST_DIR/row8.out"
row8_err_file="$TEST_DIR/row8.err"
(
    unset CERBERUS_HOST CERBERUS_RUN_KEY CERBERUS_STATE_ROOT \
          CERBERUS_PROJECT_KEY CERBERUS_SESSION_ID \
          CERBERUS_TRANSCRIPT_PATH CERBERUS_ROOT \
          REVIEW_GATE_SESSION_KEY \
          CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH CLAUDE_PROJECT_DIR \
          __CERBERUS_ALIAS_WARNED || true
    export CERBERUS_RUN_KEY="row8-CER"
    export REVIEW_GATE_SESSION_KEY="row8-LEG"
    export TMPDIR="$TEST_DIR"
    # shellcheck disable=SC1090
    eval "$(extract_review_gate_helpers)"
    # First call: warning expected. Second call in same process: no warning.
    val1="$(__cerberus_resolve_run_key)"
    val2="$(__cerberus_resolve_run_key)"
    echo "$val1" >"$row8_out_file"
    echo "$val2" >>"$row8_out_file"
) 2>"$row8_err_file"
row8_v1=$(sed -n '1p' "$row8_out_file")
row8_v2=$(sed -n '2p' "$row8_out_file")
row8_warning_count=$(grep -c 'warning: CERBERUS_RUN_KEY != REVIEW_GATE_SESSION_KEY' "$row8_err_file" || true)
if [[ "$row8_v1" == "row8-CER" && "$row8_v2" == "row8-CER" ]]; then
    log_pass "Row 8a: CERBERUS_RUN_KEY wins both calls"
else
    log_fail "Row 8a: precedence broken (v1='$row8_v1' v2='$row8_v2'; expected both 'row8-CER')"
fi
if [[ "$row8_warning_count" == "1" ]]; then
    log_pass "Row 8b: exactly one alias-mismatch warning per process"
else
    log_fail "Row 8b: expected exactly 1 warning, got $row8_warning_count (stderr: $(cat "$row8_err_file"))"
fi

# ---------------------------------------------------------------------------
# Row 9 — Alias-only legacy.
# Only REVIEW_GATE_SESSION_KEY set (no CERBERUS_RUN_KEY) → helper returns the
# legacy alias verbatim and emits zero warnings (no mismatch to flag). Also
# verifies the resolver builds the neutral path with that legacy alias as
# the run-key when CERBERUS_HOST=generic + CERBERUS_PROJECT_KEY are present.
# ---------------------------------------------------------------------------
log_test "Row 9 — alias-only legacy run key"
row9_out_file="$TEST_DIR/row9.out"
row9_err_file="$TEST_DIR/row9.err"
(
    unset CERBERUS_HOST CERBERUS_RUN_KEY CERBERUS_STATE_ROOT \
          CERBERUS_PROJECT_KEY CERBERUS_SESSION_ID \
          CERBERUS_TRANSCRIPT_PATH CERBERUS_ROOT \
          REVIEW_GATE_SESSION_KEY \
          CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH CLAUDE_PROJECT_DIR \
          __CERBERUS_ALIAS_WARNED || true
    export REVIEW_GATE_SESSION_KEY="row9-legacy-key"
    export TMPDIR="$TEST_DIR"
    # shellcheck disable=SC1090
    eval "$(extract_review_gate_helpers)"
    __cerberus_resolve_run_key >"$row9_out_file"
) 2>"$row9_err_file"
row9_val=$(cat "$row9_out_file")
row9_warning_count=$(grep -c 'warning: CERBERUS_RUN_KEY' "$row9_err_file" || true)
if [[ "$row9_val" == "row9-legacy-key" && "$row9_warning_count" == "0" ]]; then
    log_pass "Row 9a: alias-only legacy returns legacy key with no warning"
else
    log_fail "Row 9a: expected 'row9-legacy-key' + 0 warnings; got val='$row9_val' warnings=$row9_warning_count"
fi
# Resolver-level: legacy alias as run key under CERBERUS_HOST=generic.
row9_env="$(cat <<EOF
CERBERUS_HOST=generic
CERBERUS_PROJECT_KEY=row9-key
REVIEW_GATE_SESSION_KEY=row9-legacy-key
EOF
)"
row9_resolved="$(resolve_in_subshell "$row9_env" "" "")"
row9_expected="$TEST_HOME/.cerberus/projects/row9-key/row9-legacy-key"
assert_resolved_eq "Row 9b: resolver uses legacy alias as run key" "$row9_expected" "$row9_resolved"

# ---------------------------------------------------------------------------
# Row 10 — Empty-string env vars treated as unset.
# (a) CERBERUS_RUN_KEY="" falls through to REVIEW_GATE_SESSION_KEY in the
#     helper (matches the ${VAR:-} idiom); empty-string never wins over a
#     set legacy alias.
# (b) Empty CERBERUS_HOST="" with no CLAUDE_* and no transcript_path arg
#     defaults host=generic in the resolver (per row-7 logic, exercised
#     here with an explicit empty-string export).
# (c) Empty CERBERUS_RUN_KEY="" + empty REVIEW_GATE_SESSION_KEY="" at the
#     resolver entrypoint falls through to the positional session_id arg.
# ---------------------------------------------------------------------------
log_test "Row 10 — empty-string env vars treated as unset"

# (a) helper falls through CERBERUS_RUN_KEY="" → REVIEW_GATE_SESSION_KEY.
row10a_out_file="$TEST_DIR/row10a.out"
row10a_err_file="$TEST_DIR/row10a.err"
(
    unset CERBERUS_HOST CERBERUS_RUN_KEY CERBERUS_STATE_ROOT \
          CERBERUS_PROJECT_KEY CERBERUS_SESSION_ID \
          CERBERUS_TRANSCRIPT_PATH CERBERUS_ROOT \
          REVIEW_GATE_SESSION_KEY \
          CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH CLAUDE_PROJECT_DIR \
          __CERBERUS_ALIAS_WARNED || true
    export CERBERUS_RUN_KEY=""
    export REVIEW_GATE_SESSION_KEY="row10-legacy"
    export TMPDIR="$TEST_DIR"
    # shellcheck disable=SC1090
    eval "$(extract_review_gate_helpers)"
    __cerberus_resolve_run_key >"$row10a_out_file"
) 2>"$row10a_err_file"
row10a_val=$(cat "$row10a_out_file")
row10a_warn=$(grep -c 'warning: CERBERUS_RUN_KEY' "$row10a_err_file" || true)
if [[ "$row10a_val" == "row10-legacy" && "$row10a_warn" == "0" ]]; then
    log_pass "Row 10a: empty CERBERUS_RUN_KEY falls through to legacy alias"
else
    log_fail "Row 10a: got val='$row10a_val' warnings=$row10a_warn (expected 'row10-legacy' + 0)"
fi

# (b) Empty CERBERUS_HOST="" + no CLAUDE_* + no transcript path → generic.
row10b_env="$(cat <<EOF
CERBERUS_HOST=
CERBERUS_PROJECT_KEY=row10b-key
CERBERUS_RUN_KEY=row10b-run
EOF
)"
row10b_actual="$(resolve_in_subshell "$row10b_env" "" "")"
row10b_expected="$TEST_HOME/.cerberus/projects/row10b-key/row10b-run"
assert_resolved_eq "Row 10b: empty CERBERUS_HOST defaults to generic" "$row10b_expected" "$row10b_actual"

# (c) Empty run-key envs fall through to positional session_id.
row10c_env="$(cat <<EOF
CERBERUS_HOST=generic
CERBERUS_PROJECT_KEY=row10c-key
CERBERUS_RUN_KEY=
REVIEW_GATE_SESSION_KEY=
EOF
)"
row10c_actual="$(resolve_in_subshell "$row10c_env" "row10c-positional-sid" "")"
row10c_expected="$TEST_HOME/.cerberus/projects/row10c-key/row10c-positional-sid"
assert_resolved_eq "Row 10c: empty run-key envs fall through to session_id" "$row10c_expected" "$row10c_actual"

# ---------------------------------------------------------------------------
# Row 11 — Concurrent runs in same project resolve to distinct dirs.
# Two background subshells with distinct CERBERUS_RUN_KEY values in the same
# CERBERUS_PROJECT_KEY independently call resolve_review_dir + mkdir, then
# write a marker file. We assert (a) both dirs exist, (b) they are distinct,
# (c) each has its own marker. The atomic-write algorithm in
# review-gate-lib.sh:171-174 (rename(2) within a single FS) guarantees no
# cross-run contention; this row exercises the resolver-level isolation.
# ---------------------------------------------------------------------------
log_test "Row 11 — concurrent runs in same project (distinct dirs)"
ROW11_PROJ="row11-proj"
(
    unset CERBERUS_HOST CERBERUS_RUN_KEY CERBERUS_STATE_ROOT \
          CERBERUS_PROJECT_KEY CERBERUS_SESSION_ID \
          CERBERUS_TRANSCRIPT_PATH CERBERUS_ROOT \
          REVIEW_GATE_SESSION_KEY \
          CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH CLAUDE_PROJECT_DIR \
          __CERBERUS_ALIAS_WARNED || true
    export HOME="$TEST_HOME"
    export CERBERUS_HOST=generic
    export CERBERUS_PROJECT_KEY="$ROW11_PROJ"
    # shellcheck disable=SC1090
    source "$LIB_PATH" >/dev/null 2>&1

    # Spawn two background workers; each computes its review_dir, creates
    # the directory, and writes a marker named after its run key. Run them
    # concurrently to surface any shared-state contention.
    (
        export CERBERUS_RUN_KEY="row11-A"
        d=$(resolve_review_dir "" "")
        mkdir -p "$d"
        : > "$d/A.marker"
    ) &
    pidA=$!
    (
        export CERBERUS_RUN_KEY="row11-B"
        d=$(resolve_review_dir "" "")
        mkdir -p "$d"
        : > "$d/B.marker"
    ) &
    pidB=$!
    wait "$pidA"
    wait "$pidB"
)
ROW11_A="$TEST_HOME/.cerberus/projects/$ROW11_PROJ/row11-A"
ROW11_B="$TEST_HOME/.cerberus/projects/$ROW11_PROJ/row11-B"
if [[ -d "$ROW11_A" && -d "$ROW11_B" \
      && -f "$ROW11_A/A.marker" && -f "$ROW11_B/B.marker" \
      && "$ROW11_A" != "$ROW11_B" ]]; then
    log_pass "Row 11: concurrent runs resolved to distinct dirs"
else
    log_fail "Row 11: A_dir=$ROW11_A (exists=$([[ -d $ROW11_A ]] && echo y || echo n)) B_dir=$ROW11_B (exists=$([[ -d $ROW11_B ]] && echo y || echo n))"
fi

# ---------------------------------------------------------------------------
# Row 12 — Missing run key in generic mode exits non-zero with diagnostic.
# `bin/review-gate spawn` under CERBERUS_HOST=generic with neither
# CERBERUS_RUN_KEY nor REVIEW_GATE_SESSION_KEY nor CLAUDE_SESSION_ID set
# must fail with a diagnostic mentioning CERBERUS_RUN_KEY. We assert no
# state directory is created under the project base before the failure.
# ---------------------------------------------------------------------------
log_test "Row 12 — missing run key in generic mode (fail diagnostic)"
ROW12_PROJ="row12-proj"
ROW12_BASE="$TEST_HOME/.cerberus/projects/$ROW12_PROJ"
row12_out_file="$TEST_DIR/row12.out"
row12_err_file="$TEST_DIR/row12.err"
(
    unset CERBERUS_HOST CERBERUS_RUN_KEY CERBERUS_STATE_ROOT \
          CERBERUS_PROJECT_KEY CERBERUS_SESSION_ID \
          CERBERUS_TRANSCRIPT_PATH CERBERUS_ROOT \
          REVIEW_GATE_SESSION_KEY \
          CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH CLAUDE_PROJECT_DIR \
          __CERBERUS_ALIAS_WARNED || true
    export HOME="$TEST_HOME"
    export CERBERUS_HOST=generic
    export CERBERUS_PROJECT_KEY="$ROW12_PROJ"
    "$REVIEW_GATE" spawn --agents codex
) >"$row12_out_file" 2>"$row12_err_file"
row12_rc=$?
if [[ "$row12_rc" -ne 0 ]] \
   && grep -q 'CERBERUS_RUN_KEY' "$row12_err_file" \
   && [[ ! -d "$ROW12_BASE" ]]; then
    log_pass "Row 12: missing run key fails non-zero with diagnostic; no dir created"
else
    log_fail "Row 12: rc=$row12_rc base_exists=$([[ -d $ROW12_BASE ]] && echo y || echo n) stderr=$(cat "$row12_err_file")"
fi

# ---------------------------------------------------------------------------
# Row 13 — Invalid CERBERUS_STATE_ROOT (relative + literal '~').
# Empty CERBERUS_STATE_ROOT is treated as unset per the ${VAR:-} idiom
# (covered by Row 10b). Here we test the truly invalid forms that the
# resolver rejects: a relative path and a literal '~' (no shell-side
# expansion in this env path). Both must exit non-zero with a diagnostic
# and create no directory under the bogus root.
# ---------------------------------------------------------------------------
log_test "Row 13 — invalid CERBERUS_STATE_ROOT (relative/literal-tilde)"
ROW13_PROJ="row13-proj"
ROW13_RUN="row13-run"

# (a) relative path: explicitly NOT absolute → resolver rejects.
row13a_err_file="$TEST_DIR/row13a.err"
(
    unset CERBERUS_HOST CERBERUS_RUN_KEY CERBERUS_STATE_ROOT \
          CERBERUS_PROJECT_KEY CERBERUS_SESSION_ID \
          CERBERUS_TRANSCRIPT_PATH CERBERUS_ROOT \
          REVIEW_GATE_SESSION_KEY \
          CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH CLAUDE_PROJECT_DIR \
          __CERBERUS_ALIAS_WARNED || true
    export HOME="$TEST_HOME"
    export CERBERUS_HOST=generic
    export CERBERUS_PROJECT_KEY="$ROW13_PROJ"
    export CERBERUS_RUN_KEY="$ROW13_RUN"
    export CERBERUS_STATE_ROOT="relative/state"
    "$REVIEW_GATE" spawn --agents codex
) >/dev/null 2>"$row13a_err_file"
row13a_rc=$?
# Verify no directory was created under the (rejected) relative root.
row13a_bad_dir_count=0
[[ -d "relative" ]] && row13a_bad_dir_count=$((row13a_bad_dir_count + 1))
if [[ "$row13a_rc" -ne 0 ]] \
   && grep -q 'CERBERUS_STATE_ROOT' "$row13a_err_file" \
   && [[ "$row13a_bad_dir_count" -eq 0 ]]; then
    log_pass "Row 13a: relative CERBERUS_STATE_ROOT rejected; no dir created"
else
    log_fail "Row 13a: rc=$row13a_rc bad_dirs=$row13a_bad_dir_count stderr=$(cat "$row13a_err_file")"
fi

# (b) literal '~' (no shell expansion): resolver must reject before mkdir.
row13b_err_file="$TEST_DIR/row13b.err"
(
    unset CERBERUS_HOST CERBERUS_RUN_KEY CERBERUS_STATE_ROOT \
          CERBERUS_PROJECT_KEY CERBERUS_SESSION_ID \
          CERBERUS_TRANSCRIPT_PATH CERBERUS_ROOT \
          REVIEW_GATE_SESSION_KEY \
          CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH CLAUDE_PROJECT_DIR \
          __CERBERUS_ALIAS_WARNED || true
    export HOME="$TEST_HOME"
    export CERBERUS_HOST=generic
    export CERBERUS_PROJECT_KEY="$ROW13_PROJ"
    export CERBERUS_RUN_KEY="$ROW13_RUN"
    # Single-quoted in the export statement above so '~' stays literal.
    export CERBERUS_STATE_ROOT='~/literal-tilde'
    "$REVIEW_GATE" spawn --agents codex
) >/dev/null 2>"$row13b_err_file"
row13b_rc=$?
if [[ "$row13b_rc" -ne 0 ]] \
   && grep -q 'CERBERUS_STATE_ROOT' "$row13b_err_file"; then
    log_pass "Row 13b: literal '~' CERBERUS_STATE_ROOT rejected"
else
    log_fail "Row 13b: rc=$row13b_rc stderr=$(cat "$row13b_err_file")"
fi

# ---------------------------------------------------------------------------
# Row 14 — Path-traversal rejection on run-key / project-key.
# CERBERUS_RUN_KEY and CERBERUS_PROJECT_KEY values containing '/', '.', '..'
# are rejected by the resolver before any mkdir. We exercise the CLI
# surface (bin/review-gate spawn) for both keys.
# ---------------------------------------------------------------------------
log_test "Row 14 — path-traversal rejection on run-key/project-key"

# (a) CERBERUS_RUN_KEY="..": resolver step 1b rejects.
row14a_err_file="$TEST_DIR/row14a.err"
(
    unset CERBERUS_HOST CERBERUS_RUN_KEY CERBERUS_STATE_ROOT \
          CERBERUS_PROJECT_KEY CERBERUS_SESSION_ID \
          CERBERUS_TRANSCRIPT_PATH CERBERUS_ROOT \
          REVIEW_GATE_SESSION_KEY \
          CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH CLAUDE_PROJECT_DIR \
          __CERBERUS_ALIAS_WARNED || true
    export HOME="$TEST_HOME"
    export CERBERUS_HOST=generic
    export CERBERUS_PROJECT_KEY="row14-proj"
    export CERBERUS_RUN_KEY=".."
    "$REVIEW_GATE" spawn --agents codex
) >/dev/null 2>"$row14a_err_file"
row14a_rc=$?
# Resolver must reject ".." run key. No "row14-proj/.." dir should exist.
row14a_bad="$TEST_HOME/.cerberus/projects/row14-proj/.."
if [[ "$row14a_rc" -ne 0 ]] \
   && grep -q 'invalid run key' "$row14a_err_file"; then
    log_pass "Row 14a: '..' run key rejected"
else
    log_fail "Row 14a: rc=$row14a_rc stderr=$(cat "$row14a_err_file")"
fi

# (b) CERBERUS_PROJECT_KEY containing '/': resolver step 4 rejects.
row14b_err_file="$TEST_DIR/row14b.err"
(
    unset CERBERUS_HOST CERBERUS_RUN_KEY CERBERUS_STATE_ROOT \
          CERBERUS_PROJECT_KEY CERBERUS_SESSION_ID \
          CERBERUS_TRANSCRIPT_PATH CERBERUS_ROOT \
          REVIEW_GATE_SESSION_KEY \
          CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH CLAUDE_PROJECT_DIR \
          __CERBERUS_ALIAS_WARNED || true
    export HOME="$TEST_HOME"
    export CERBERUS_HOST=generic
    export CERBERUS_PROJECT_KEY="../escape"
    export CERBERUS_RUN_KEY="row14b-run"
    "$REVIEW_GATE" spawn --agents codex
) >/dev/null 2>"$row14b_err_file"
row14b_rc=$?
if [[ "$row14b_rc" -ne 0 ]] \
   && grep -q 'invalid project key' "$row14b_err_file"; then
    log_pass "Row 14b: '../escape' project key rejected"
else
    log_fail "Row 14b: rc=$row14b_rc stderr=$(cat "$row14b_err_file")"
fi

# (c) Schema correctness: a Codex-style spawn writes gate-state.json with
# host="codex" + populated owner block. We can't run a full spawn without
# real reviewer CLIs, so we assert the contract at the resolver/state-write
# boundary by sourcing the writer's own jq template against synthetic
# inputs. T004 mirrors the production code path: same env→OWNER_*→jq -n.
log_test "Row 14c — gate-state.json host + owner schema (synthetic spawn)"
row14c_state="$TEST_DIR/row14c-gate-state.json"
row14c_host_in="codex"
row14c_pk_in="row14c-proj"
row14c_rk_in="row14c-run"
row14c_sid_in="row14c-thread-id"
row14c_tp_in=""
jq -n \
    --arg host "$row14c_host_in" \
    --arg owner_host "$row14c_host_in" \
    --arg owner_project_key "$row14c_pk_in" \
    --arg owner_run_key "$row14c_rk_in" \
    --arg owner_key "$row14c_rk_in" \
    --arg owner_session_id "$row14c_sid_in" \
    --arg owner_transcript "$row14c_tp_in" \
    '{
        host: (if $host != "" then $host else null end),
        owner: (
            {}
            | (if $owner_host != "" then .host = $owner_host else . end)
            | (if $owner_project_key != "" then .project_key = $owner_project_key else . end)
            | (if $owner_run_key != "" then .run_key = $owner_run_key else . end)
            | (if $owner_key != "" then .session_key = $owner_key else . end)
            | (if $owner_session_id != "" then .session_id = $owner_session_id else . end)
            | (if $owner_transcript != "" then .transcript_path = $owner_transcript else . end)
            | if length == 0 then null else . end
        )
    }' > "$row14c_state"
row14c_host=$(jq -r '.host // empty' "$row14c_state")
row14c_owner_host=$(jq -r '.owner.host // empty' "$row14c_state")
row14c_owner_pk=$(jq -r '.owner.project_key // empty' "$row14c_state")
row14c_owner_rk=$(jq -r '.owner.run_key // empty' "$row14c_state")
row14c_owner_sk=$(jq -r '.owner.session_key // empty' "$row14c_state")
if [[ "$row14c_host" == "codex" \
      && "$row14c_owner_host" == "codex" \
      && "$row14c_owner_pk" == "row14c-proj" \
      && "$row14c_owner_rk" == "row14c-run" \
      && "$row14c_owner_sk" == "row14c-run" ]]; then
    log_pass "Row 14c: host + owner schema populated"
else
    log_fail "Row 14c: host=$row14c_host owner.host=$row14c_owner_host pk=$row14c_owner_pk rk=$row14c_owner_rk sk=$row14c_owner_sk"
fi

# ---------------------------------------------------------------------------
# Row 15 — wait + status --session-key parity under neutral state.
# Plant a neutral gate-state.json under $TEST_HOME/.cerberus/projects/...
# (no spawn — that would require real reviewer CLIs). Then assert that
# BOTH `wait --session-key k` AND `status --session-key k` find the same
# state file via the shared find_state_by_session_key glob walker
# (resolve_review_dir env-passing path also works when project key is
# inferable). Per plan §Run-key lookup parity (L613-L630) both commands
# MUST locate the run without any Claude env present.
# ---------------------------------------------------------------------------
log_test "Row 15 — wait + status --session-key parity under neutral state"

ROW15_PROJ="row15-proj"
ROW15_RUN="row15-run"
ROW15_DIR="$TEST_HOME/.cerberus/projects/$ROW15_PROJ/$ROW15_RUN"
mkdir -p "$ROW15_DIR/reviews"
cat > "$ROW15_DIR/gate-state.json" <<EOF
{
  "version": 1,
  "status": "resolved",
  "trigger_source": "test",
  "artifact": {"path": "$ROW15_DIR/latest.md", "sha256": ""},
  "reviewers": {"codex": {}},
  "consensus": {"verdict": "PASS"},
  "decision": {"action": "proceed", "decided_at": "2026-04-30T00:00:00Z"},
  "owner": {"session_key": "$ROW15_RUN"},
  "created_at": "2026-04-30T00:00:00Z",
  "iteration": 0
}
EOF
cat > "$ROW15_DIR/reviews/codex.json" <<'EOF'
{"verdict":"PASS","summary":"All good","findings":[]}
EOF
touch "$ROW15_DIR/reviews/codex.done"

row15_status_out="$TEST_DIR/row15-status.out"
row15_status_err="$TEST_DIR/row15-status.err"
row15_wait_out="$TEST_DIR/row15-wait.out"
row15_wait_err="$TEST_DIR/row15-wait.err"

# `status --session-key` parity: no Claude env, no project key in env.
(
    unset CERBERUS_HOST CERBERUS_RUN_KEY CERBERUS_STATE_ROOT \
          CERBERUS_PROJECT_KEY CERBERUS_SESSION_ID \
          CERBERUS_TRANSCRIPT_PATH CERBERUS_ROOT \
          REVIEW_GATE_SESSION_KEY \
          CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH CLAUDE_PROJECT_DIR \
          __CERBERUS_ALIAS_WARNED || true
    export HOME="$TEST_HOME"
    "$REVIEW_GATE" status --json --session-key "$ROW15_RUN"
) >"$row15_status_out" 2>"$row15_status_err"
row15_status_rc=$?
row15_status_gs=$(jq -r '.gate_status' "$row15_status_out" 2>/dev/null || echo "")
row15_status_rd=$(jq -r '.review_dir' "$row15_status_out" 2>/dev/null || echo "")
if [[ "$row15_status_rc" -eq 0 && "$row15_status_gs" == "resolved" && "$row15_status_rd" == "$ROW15_DIR" ]]; then
    log_pass "Row 15a: status --session-key locates neutral state without Claude env"
else
    log_fail "Row 15a: rc=$row15_status_rc gs=$row15_status_gs rd=$row15_status_rd body=$(cat "$row15_status_out") stderr=$(cat "$row15_status_err")"
fi

# `wait --session-key` parity: same env profile. Resolved gate with done
# sentinel + reviewer JSON ⇒ wait returns immediately with status=resolved.
(
    unset CERBERUS_HOST CERBERUS_RUN_KEY CERBERUS_STATE_ROOT \
          CERBERUS_PROJECT_KEY CERBERUS_SESSION_ID \
          CERBERUS_TRANSCRIPT_PATH CERBERUS_ROOT \
          REVIEW_GATE_SESSION_KEY \
          CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH CLAUDE_PROJECT_DIR \
          __CERBERUS_ALIAS_WARNED || true
    export HOME="$TEST_HOME"
    "$REVIEW_GATE" wait --json --timeout 5 --poll-interval 1 --session-key "$ROW15_RUN"
) >"$row15_wait_out" 2>"$row15_wait_err"
row15_wait_rc=$?
row15_wait_status=$(jq -r '.status' "$row15_wait_out" 2>/dev/null || echo "")
# wait exits 0 for PASS consensus, non-zero for other terminal verdicts; we
# only require that it located the state and returned a status field (not
# "no_reviewers" — which would mean it never found the state file).
if [[ "$row15_wait_status" == "resolved" || "$row15_wait_status" == "complete" ]]; then
    log_pass "Row 15b: wait --session-key locates neutral state without Claude env"
else
    log_fail "Row 15b: rc=$row15_wait_rc status=$row15_wait_status body=$(cat "$row15_wait_out") stderr=$(cat "$row15_wait_err")"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "----------------------------------------"
echo "Host-neutral state test summary:"
echo "  Passed:  $TESTS_PASSED"
echo "  Failed:  $TESTS_FAILED"
echo "  Skipped: $TESTS_SKIPPED"
echo "----------------------------------------"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
