#!/usr/bin/env bash
# T014 — Phase 2 tests for the Amp Toolbox shell helper.
#
# Plan reference: §Phase 2 — Amp Tests, "test-amp-shell-helper.sh"
# (plan L1180-L1198), §Amp command surface (L778-L800), §Amp run-key
# durability (L156-L162). Resolved spike: docs/AMP.md §"Phase 2 Spike
# Findings" (commit bbb8fd8 — T012).
#
# DIVERGENCE FROM ORIGINAL TASK SPEC. The plan and the T013/T014 task
# contexts describe the helper as `.amp/plugins/cerberus.ts`. The T012
# spike determined that Amp CLI 0.0.1777572045-g97f3b8 does NOT expose
# a `.amp/plugins/` loader; the actual extension surface is the Amp
# Toolbox (subprocess scripts driven by the TOOLBOX_ACTION env var).
# The helper therefore lives at `.amp/toolbox/cerberus.sh` and this
# test drives that surface. See docs/AMP.md §Phase 2 Spike Findings
# for the source of truth on the pivot.
#
# Coverage matrix (9 cases from plan L1182-L1198, every case is a real
# PASS/FAIL at T014):
#
#   Case 1: Thread id present — `AMP_THREAD_ID` used as run key
#           (renamed from plan's `ctx.thread.id` per docs/AMP.md OQ-3).
#   Case 2: Thread id absent — UUID generated, persisted at
#           ~/.cerberus/runtime/amp/<workspace-key>/active-session.json.
#   Case 3: Second invocation reads persisted UUID; same run key.
#   Case 4: Env mapping completeness — spawned bin/review-gate
#           invocation includes all required CERBERUS_* vars
#           (CERBERUS_HOST=amp, CERBERUS_ROOT, CERBERUS_STATE_ROOT,
#           CERBERUS_PROJECT_KEY, CERBERUS_RUN_KEY).
#   Case 5: CLAUDE_PLUGIN_ROOT compat alias still passed during
#           migration window.
#   Case 6: Run key surfaced in stdout — `Cerberus run key: <key>`
#           appears in command output for user pass-through (plan
#           exit criterion §964).
#   Case 7: Missing backend — clear diagnostic surfaced when
#           bin/review-gate is not on path.
#   Case 8: Missing reviewer CLI — backend's non-zero exit and stderr
#           are propagated cleanly (no swallowing).
#   Case 9: Thread id flips mid-session — helper detects mismatch with
#           persisted value, logs warning, reuses persisted run_key.
#
# Happy path A: stub script exists, regular file, executable.
# Happy path B: TOOLBOX_ACTION=describe emits valid JSON listing the
#   six commands in the plan-mandated order.
# Happy path C: TOOLBOX_ACTION=execute with a valid command + a
#   functioning stub backend exits 0 (sanity probe; T013's
#   NotImplemented marker is gone now that dispatch is implemented).

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

TEST_DIR="$(mktemp -d -t cerberus-amp-shell-helper.XXXXXX)"

log_test() { echo -e "${YELLOW}TEST:${NC} $1"; }
log_pass() { echo -e "${GREEN}PASS:${NC} $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
log_fail() { echo -e "${RED}FAIL:${NC} $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

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
# Helpers
# ---------------------------------------------------------------------------

# Compute the expected workspace project_key — same path-mangle as the
# helper's `__amp_project_key` and bin/review-gate-lib.sh's
# `get_project_hash` (no-CERBERUS_PROJECT_KEY no-transcript path).
expected_project_key() {
    local workspace_root="$1"
    echo "$workspace_root" | sed 's|^/|-|' | tr '/' '-'
}

expected_registry_path() {
    local home_dir="$1"
    local workspace_root="$2"
    local pk
    pk="$(expected_project_key "$workspace_root")"
    echo "$home_dir/.cerberus/runtime/amp/$pk/active-session.json"
}

# Build a stub bin/review-gate at a per-case path. The stub:
#   1. Captures the calling env to <case_dir>/env-capture.txt.
#   2. Captures argv to <case_dir>/argv-capture.txt (one arg per line).
#   3. Captures stdin to <case_dir>/stdin-capture.txt.
#   4. Optionally exits with a chosen rc and stderr message.
#
# Args:
#   $1  case_dir   absolute path; created by caller
#   $2  rc         exit code (defaults to 0)
#   $3  stderr     stderr line (optional)
make_stub_review_gate() {
    local case_dir="$1"
    local rc="${2:-0}"
    local stderr_line="${3:-}"
    local stub_path="$case_dir/review-gate"
    cat > "$stub_path" <<STUB
#!/usr/bin/env bash
# Per-test stub for bin/review-gate. Captures env + argv + stdin so
# the harness can assert the helper passed the expected vars.
{
    # Environment, one VAR=value per line. Includes only the env
    # variables the helper is expected to set; keeps the capture
    # deterministic across hosts.
    for v in CERBERUS_HOST CERBERUS_ROOT CERBERUS_STATE_ROOT \
             CERBERUS_PROJECT_KEY CERBERUS_RUN_KEY CLAUDE_PLUGIN_ROOT \
             AMP_THREAD_ID AMP_CURRENT_THREAD_ID; do
        # Use parameter expansion with default to distinguish "unset"
        # from "set to empty"; tests that need that distinction will
        # parse accordingly.
        if [[ -n "\${!v+set}" ]]; then
            printf '%s=%s\n' "\$v" "\${!v}"
        else
            printf '%s=<unset>\n' "\$v"
        fi
    done
} > "$case_dir/env-capture.txt"

# Argv: one per line so a test can assert order.
: > "$case_dir/argv-capture.txt"
for a in "\$@"; do
    printf '%s\n' "\$a" >> "$case_dir/argv-capture.txt"
done

# Stdin (best effort — most subcommands don't read stdin, but capture
# anyway for forward compat).
if [[ ! -t 0 ]]; then
    cat > "$case_dir/stdin-capture.txt" || true
fi

if [[ -n "$stderr_line" ]]; then
    echo "$stderr_line" >&2
fi
exit $rc
STUB
    chmod +x "$stub_path"
    echo "$stub_path"
}

# Run the toolbox helper with controlled HOME / workspace / backend.
# Args:
#   $1  case_dir          absolute path
#   $2  workspace_root    absolute path (used for CERBERUS_AMP_WORKSPACE)
#   $3  review_gate_bin   path to stub backend (or "" to omit override)
#   $4  stdin_body        JSON string for execute params
#   $5  stdout_file
#   $6  stderr_file
#   $@  additional KEY=VALUE env vars (e.g. AMP_THREAD_ID=T-...)
run_helper() {
    local case_dir="$1"
    local workspace_root="$2"
    local review_gate_bin="$3"
    local stdin_body="$4"
    local stdout_file="$5"
    local stderr_file="$6"
    shift 6
    local rc=0
    (
        export HOME="$case_dir/home"
        mkdir -p "$HOME"
        # Strip inherited neutral env so tests don't accidentally pick
        # up state from the runner's shell.
        unset CERBERUS_RUN_KEY REVIEW_GATE_SESSION_KEY \
              CERBERUS_PROJECT_KEY CERBERUS_HOST CERBERUS_STATE_ROOT \
              CLAUDE_PROJECT_DIR CLAUDE_PLUGIN_ROOT \
              AMP_THREAD_ID AMP_CURRENT_THREAD_ID
        export CERBERUS_AMP_WORKSPACE="$workspace_root"
        if [[ -n "$review_gate_bin" ]]; then
            export CERBERUS_REVIEW_GATE_BIN="$review_gate_bin"
        fi
        for kv in "$@"; do
            export "$kv"
        done
        printf '%s' "$stdin_body" \
            | TOOLBOX_ACTION=execute "$TOOLBOX_SCRIPT" \
            >"$stdout_file" 2>"$stderr_file"
    ) || rc=$?
    return $rc
}

# Read VAR from a stub's env-capture.txt. Returns empty string if the
# var is not set.
env_capture_value() {
    local capture_file="$1"
    local var="$2"
    local line
    line="$(grep "^${var}=" "$capture_file" 2>/dev/null | head -n 1)"
    if [[ -z "$line" ]]; then
        echo ""
        return
    fi
    # Strip "VAR=" prefix.
    echo "${line#${var}=}"
}

# ---------------------------------------------------------------------------
# Case 1 — Thread id present: AMP_THREAD_ID used as run key.
# ---------------------------------------------------------------------------
log_test "Case 1 — AMP_THREAD_ID present, used as run key"
c1_dir="$TEST_DIR/case1"
mkdir -p "$c1_dir"
c1_workspace="/tmp/some-amp-workspace-c1"
c1_thread="T-019de015-d2d1-70dc-ac7c-bf5ccc46dd68"
c1_stub="$(make_stub_review_gate "$c1_dir")"
c1_rc=0
run_helper "$c1_dir" "$c1_workspace" "$c1_stub" \
    '{"command":"review-code"}' \
    "$c1_dir/stdout" "$c1_dir/stderr" \
    "AMP_THREAD_ID=$c1_thread" || c1_rc=$?
c1_registry="$(expected_registry_path "$c1_dir/home" "$c1_workspace")"
if [[ "$c1_rc" -ne 0 ]]; then
    log_fail "Case 1 — exit $c1_rc; stderr=$(cat "$c1_dir/stderr")"
elif [[ ! -f "$c1_dir/env-capture.txt" ]]; then
    log_fail "Case 1 — stub backend was not invoked (no env-capture.txt)"
elif [[ ! -f "$c1_registry" ]]; then
    log_fail "Case 1 — registry not written at $c1_registry"
else
    captured_run_key="$(env_capture_value "$c1_dir/env-capture.txt" CERBERUS_RUN_KEY)"
    persisted_run_key="$(jq -r '.run_key' "$c1_registry" 2>/dev/null || echo "")"
    persisted_thread="$(jq -r '.amp_thread_id' "$c1_registry" 2>/dev/null || echo "")"
    if [[ "$captured_run_key" != "$c1_thread" ]]; then
        log_fail "Case 1 — backend received CERBERUS_RUN_KEY='$captured_run_key' (expected '$c1_thread')"
    elif [[ "$persisted_run_key" != "$c1_thread" ]]; then
        log_fail "Case 1 — registry run_key='$persisted_run_key' (expected '$c1_thread')"
    elif [[ "$persisted_thread" != "$c1_thread" ]]; then
        log_fail "Case 1 — registry amp_thread_id='$persisted_thread' (expected '$c1_thread')"
    else
        log_pass "Case 1 — AMP_THREAD_ID used as run key + persisted"
    fi
fi

# ---------------------------------------------------------------------------
# Case 2 — Thread id absent: UUID generated and persisted.
# ---------------------------------------------------------------------------
log_test "Case 2 — AMP_THREAD_ID absent; UUID generated + persisted"
c2_dir="$TEST_DIR/case2"
mkdir -p "$c2_dir"
c2_workspace="/tmp/some-amp-workspace-c2"
c2_stub="$(make_stub_review_gate "$c2_dir")"
c2_rc=0
run_helper "$c2_dir" "$c2_workspace" "$c2_stub" \
    '{"command":"review-code"}' \
    "$c2_dir/stdout" "$c2_dir/stderr" || c2_rc=$?
c2_registry="$(expected_registry_path "$c2_dir/home" "$c2_workspace")"
if [[ "$c2_rc" -ne 0 ]]; then
    log_fail "Case 2 — exit $c2_rc; stderr=$(cat "$c2_dir/stderr")"
elif [[ ! -f "$c2_registry" ]]; then
    log_fail "Case 2 — registry not written at $c2_registry"
else
    persisted_run_key="$(jq -r '.run_key' "$c2_registry" 2>/dev/null || echo "")"
    persisted_thread="$(jq -r '.amp_thread_id' "$c2_registry" 2>/dev/null || echo "")"
    captured_run_key="$(env_capture_value "$c2_dir/env-capture.txt" CERBERUS_RUN_KEY)"
    # The persisted run_key MUST be a non-empty string and MUST NOT
    # match the AMP_THREAD_ID `T-<hex>` shape (since we explicitly
    # didn't supply one). amp_thread_id should be null.
    if [[ -z "$persisted_run_key" ]]; then
        log_fail "Case 2 — registry run_key empty"
    elif [[ "$persisted_run_key" =~ ^T-[a-f0-9]+(-[a-f0-9]+)*$ ]]; then
        log_fail "Case 2 — registry run_key='$persisted_run_key' looks like a thread id, not a fallback UUID"
    elif [[ "$persisted_thread" != "null" ]]; then
        log_fail "Case 2 — registry amp_thread_id='$persisted_thread' (expected JSON null)"
    elif [[ "$captured_run_key" != "$persisted_run_key" ]]; then
        log_fail "Case 2 — backend run_key '$captured_run_key' != persisted '$persisted_run_key'"
    else
        log_pass "Case 2 — UUID generated, persisted (amp_thread_id=null), forwarded to backend"
    fi
fi

# ---------------------------------------------------------------------------
# Case 3 — Second invocation reads persisted UUID; same run key returned.
# ---------------------------------------------------------------------------
log_test "Case 3 — second invocation reads persisted UUID"
c3_dir="$TEST_DIR/case3"
mkdir -p "$c3_dir"
c3_workspace="/tmp/some-amp-workspace-c3"
c3_stub="$(make_stub_review_gate "$c3_dir")"

# First invocation — no thread id, generates UUID.
run_helper "$c3_dir" "$c3_workspace" "$c3_stub" \
    '{"command":"review-code"}' \
    "$c3_dir/stdout-1" "$c3_dir/stderr-1" || true
c3_registry="$(expected_registry_path "$c3_dir/home" "$c3_workspace")"
c3_first_run_key="$(jq -r '.run_key' "$c3_registry" 2>/dev/null || echo "")"

# Second invocation — same workspace, no thread id, same case_dir so
# same HOME so same registry path. The stub overwrites env-capture.txt
# from the second call.
sleep 1.1  # ensure last_seen advances at second precision
c3_second_rc=0
run_helper "$c3_dir" "$c3_workspace" "$c3_stub" \
    '{"command":"review-code"}' \
    "$c3_dir/stdout-2" "$c3_dir/stderr-2" || c3_second_rc=$?
c3_second_run_key="$(env_capture_value "$c3_dir/env-capture.txt" CERBERUS_RUN_KEY)"
c3_persisted_run_key="$(jq -r '.run_key' "$c3_registry" 2>/dev/null || echo "")"

if [[ "$c3_second_rc" -ne 0 ]]; then
    log_fail "Case 3 — second invocation exit $c3_second_rc; stderr=$(cat "$c3_dir/stderr-2")"
elif [[ -z "$c3_first_run_key" ]]; then
    log_fail "Case 3 — first invocation produced empty run_key"
elif [[ "$c3_second_run_key" != "$c3_first_run_key" ]]; then
    log_fail "Case 3 — second invocation run_key '$c3_second_run_key' != first '$c3_first_run_key'"
elif [[ "$c3_persisted_run_key" != "$c3_first_run_key" ]]; then
    log_fail "Case 3 — registry run_key '$c3_persisted_run_key' diverged from first '$c3_first_run_key'"
else
    log_pass "Case 3 — second invocation reused persisted UUID"
fi

# ---------------------------------------------------------------------------
# Case 4 — Env mapping completeness for spawned bin/review-gate.
# ---------------------------------------------------------------------------
log_test "Case 4 — env mapping (CERBERUS_HOST=amp, _ROOT, _STATE_ROOT, _PROJECT_KEY, _RUN_KEY)"
c4_dir="$TEST_DIR/case4"
mkdir -p "$c4_dir"
c4_workspace="/tmp/some-amp-workspace-c4"
c4_thread="T-c4cccccc-1111-7000-aaaa-bbbbccccdddd"
c4_stub="$(make_stub_review_gate "$c4_dir")"
c4_rc=0
run_helper "$c4_dir" "$c4_workspace" "$c4_stub" \
    '{"command":"review-code"}' \
    "$c4_dir/stdout" "$c4_dir/stderr" \
    "AMP_THREAD_ID=$c4_thread" || c4_rc=$?
if [[ "$c4_rc" -ne 0 ]]; then
    log_fail "Case 4 — exit $c4_rc; stderr=$(cat "$c4_dir/stderr")"
elif [[ ! -f "$c4_dir/env-capture.txt" ]]; then
    log_fail "Case 4 — backend stub never ran"
else
    c4_ok=1
    c4_host="$(env_capture_value "$c4_dir/env-capture.txt" CERBERUS_HOST)"
    c4_root="$(env_capture_value "$c4_dir/env-capture.txt" CERBERUS_ROOT)"
    c4_state_root="$(env_capture_value "$c4_dir/env-capture.txt" CERBERUS_STATE_ROOT)"
    c4_pk="$(env_capture_value "$c4_dir/env-capture.txt" CERBERUS_PROJECT_KEY)"
    c4_run_key="$(env_capture_value "$c4_dir/env-capture.txt" CERBERUS_RUN_KEY)"
    expected_pk="$(expected_project_key "$c4_workspace")"
    if [[ "$c4_host" != "amp" ]]; then
        log_fail "Case 4 — CERBERUS_HOST='$c4_host' (expected 'amp')"
        c4_ok=0
    fi
    if [[ -z "$c4_root" || "$c4_root" == "<unset>" ]]; then
        log_fail "Case 4 — CERBERUS_ROOT empty/unset"
        c4_ok=0
    elif [[ "$c4_root" != /* ]]; then
        log_fail "Case 4 — CERBERUS_ROOT='$c4_root' is not an absolute path"
        c4_ok=0
    fi
    if [[ -z "$c4_state_root" || "$c4_state_root" == "<unset>" ]]; then
        log_fail "Case 4 — CERBERUS_STATE_ROOT empty/unset"
        c4_ok=0
    elif [[ "$c4_state_root" != /* ]]; then
        log_fail "Case 4 — CERBERUS_STATE_ROOT='$c4_state_root' is not an absolute path"
        c4_ok=0
    fi
    if [[ "$c4_pk" != "$expected_pk" ]]; then
        log_fail "Case 4 — CERBERUS_PROJECT_KEY='$c4_pk' (expected '$expected_pk')"
        c4_ok=0
    fi
    if [[ "$c4_run_key" != "$c4_thread" ]]; then
        log_fail "Case 4 — CERBERUS_RUN_KEY='$c4_run_key' (expected '$c4_thread')"
        c4_ok=0
    fi
    if [[ "$c4_ok" -eq 1 ]]; then
        log_pass "Case 4 — all required CERBERUS_* env vars set correctly"
    fi
fi

# ---------------------------------------------------------------------------
# Case 5 — CLAUDE_PLUGIN_ROOT compat alias still passed.
# ---------------------------------------------------------------------------
log_test "Case 5 — CLAUDE_PLUGIN_ROOT compat alias still passed"
c5_dir="$TEST_DIR/case5"
mkdir -p "$c5_dir"
c5_workspace="/tmp/some-amp-workspace-c5"
c5_stub="$(make_stub_review_gate "$c5_dir")"
c5_rc=0
run_helper "$c5_dir" "$c5_workspace" "$c5_stub" \
    '{"command":"review-code"}' \
    "$c5_dir/stdout" "$c5_dir/stderr" \
    "AMP_THREAD_ID=T-c5cccccc-2222-7000-aaaa-bbbbccccdddd" || c5_rc=$?
if [[ "$c5_rc" -ne 0 ]]; then
    log_fail "Case 5 — exit $c5_rc; stderr=$(cat "$c5_dir/stderr")"
elif [[ ! -f "$c5_dir/env-capture.txt" ]]; then
    log_fail "Case 5 — backend stub never ran"
else
    c5_root="$(env_capture_value "$c5_dir/env-capture.txt" CERBERUS_ROOT)"
    c5_compat="$(env_capture_value "$c5_dir/env-capture.txt" CLAUDE_PLUGIN_ROOT)"
    if [[ -z "$c5_compat" || "$c5_compat" == "<unset>" ]]; then
        log_fail "Case 5 — CLAUDE_PLUGIN_ROOT not set; alias not propagated during migration"
    elif [[ "$c5_compat" != "$c5_root" ]]; then
        log_fail "Case 5 — CLAUDE_PLUGIN_ROOT='$c5_compat' != CERBERUS_ROOT='$c5_root'"
    else
        log_pass "Case 5 — CLAUDE_PLUGIN_ROOT compat alias = CERBERUS_ROOT"
    fi
fi

# ---------------------------------------------------------------------------
# Case 6 — Run key surfaced in stdout for user pass-through.
# ---------------------------------------------------------------------------
log_test "Case 6 — run key surfaced in stdout"
c6_dir="$TEST_DIR/case6"
mkdir -p "$c6_dir"
c6_workspace="/tmp/some-amp-workspace-c6"
c6_thread="T-c6cccccc-3333-7000-aaaa-bbbbccccdddd"
c6_stub="$(make_stub_review_gate "$c6_dir")"
c6_rc=0
run_helper "$c6_dir" "$c6_workspace" "$c6_stub" \
    '{"command":"review-code"}' \
    "$c6_dir/stdout" "$c6_dir/stderr" \
    "AMP_THREAD_ID=$c6_thread" || c6_rc=$?
if [[ "$c6_rc" -ne 0 ]]; then
    log_fail "Case 6 — exit $c6_rc; stderr=$(cat "$c6_dir/stderr")"
elif ! grep -q "^Cerberus run key: $c6_thread$" "$c6_dir/stdout"; then
    log_fail "Case 6 — stdout missing 'Cerberus run key: $c6_thread'; stdout=$(cat "$c6_dir/stdout")"
else
    log_pass "Case 6 — stdout surfaces 'Cerberus run key: $c6_thread'"
fi

# ---------------------------------------------------------------------------
# Case 7 — Missing backend: clear diagnostic surfaced.
# ---------------------------------------------------------------------------
log_test "Case 7 — missing backend (bin/review-gate) — clear diagnostic"
c7_dir="$TEST_DIR/case7"
mkdir -p "$c7_dir"
c7_workspace="/tmp/some-amp-workspace-c7"
c7_missing_path="$c7_dir/does-not-exist/review-gate"
c7_rc=0
run_helper "$c7_dir" "$c7_workspace" "$c7_missing_path" \
    '{"command":"review-code"}' \
    "$c7_dir/stdout" "$c7_dir/stderr" || c7_rc=$?
if [[ "$c7_rc" -eq 0 ]]; then
    log_fail "Case 7 — helper exited 0 with missing backend (expected non-zero)"
elif ! grep -qi "backend not found" "$c7_dir/stderr"; then
    log_fail "Case 7 — stderr missing clear diagnostic; got: $(cat "$c7_dir/stderr")"
elif ! grep -q "$c7_missing_path" "$c7_dir/stderr"; then
    log_fail "Case 7 — stderr does not name the missing backend path; got: $(cat "$c7_dir/stderr")"
else
    log_pass "Case 7 — missing backend produced clear diagnostic (rc=$c7_rc)"
fi

# ---------------------------------------------------------------------------
# Case 8 — Missing reviewer CLI: backend's error is propagated cleanly.
# ---------------------------------------------------------------------------
log_test "Case 8 — missing reviewer CLI — backend error surfaced"
c8_dir="$TEST_DIR/case8"
mkdir -p "$c8_dir"
c8_workspace="/tmp/some-amp-workspace-c8"
# Stub exits with rc=42 and prints a backend-style "missing reviewer
# CLI" error to stderr. The helper MUST propagate both.
c8_stub="$(make_stub_review_gate "$c8_dir" 42 "review-gate: codex CLI not found on PATH")"
c8_rc=0
run_helper "$c8_dir" "$c8_workspace" "$c8_stub" \
    '{"command":"review-code"}' \
    "$c8_dir/stdout" "$c8_dir/stderr" \
    "AMP_THREAD_ID=T-c8cccccc-4444-7000-aaaa-bbbbccccdddd" || c8_rc=$?
if [[ "$c8_rc" -ne 42 ]]; then
    log_fail "Case 8 — exit $c8_rc (expected 42 from backend); stderr=$(cat "$c8_dir/stderr")"
elif ! grep -q "codex CLI not found" "$c8_dir/stderr"; then
    log_fail "Case 8 — backend stderr not propagated; got: $(cat "$c8_dir/stderr")"
else
    log_pass "Case 8 — backend rc + stderr propagated cleanly"
fi

# ---------------------------------------------------------------------------
# Case 9 — Thread id flips mid-session: helper detects mismatch, logs
# warning, reuses persisted run_key for continuity.
# ---------------------------------------------------------------------------
log_test "Case 9 — AMP_THREAD_ID mismatch with persisted UUID — continuity"
c9_dir="$TEST_DIR/case9"
mkdir -p "$c9_dir"
c9_workspace="/tmp/some-amp-workspace-c9"
c9_thread_a="T-c9aaaaaa-5555-7000-aaaa-bbbbccccdddd"
c9_thread_b="T-c9bbbbbb-6666-7000-aaaa-bbbbccccdddd"
c9_stub="$(make_stub_review_gate "$c9_dir")"

# First invocation pins amp_thread_id=A.
run_helper "$c9_dir" "$c9_workspace" "$c9_stub" \
    '{"command":"review-code"}' \
    "$c9_dir/stdout-1" "$c9_dir/stderr-1" \
    "AMP_THREAD_ID=$c9_thread_a" || true
c9_registry="$(expected_registry_path "$c9_dir/home" "$c9_workspace")"
c9_first_run_key="$(jq -r '.run_key' "$c9_registry" 2>/dev/null || echo "")"
c9_first_thread="$(jq -r '.amp_thread_id' "$c9_registry" 2>/dev/null || echo "")"

# Second invocation passes a DIFFERENT thread id. The helper should
# warn and reuse the persisted run_key.
c9_second_rc=0
run_helper "$c9_dir" "$c9_workspace" "$c9_stub" \
    '{"command":"review-code"}' \
    "$c9_dir/stdout-2" "$c9_dir/stderr-2" \
    "AMP_THREAD_ID=$c9_thread_b" || c9_second_rc=$?
c9_second_run_key="$(env_capture_value "$c9_dir/env-capture.txt" CERBERUS_RUN_KEY)"

if [[ "$c9_second_rc" -ne 0 ]]; then
    log_fail "Case 9 — second invocation exit $c9_second_rc; stderr=$(cat "$c9_dir/stderr-2")"
elif [[ "$c9_first_run_key" != "$c9_thread_a" ]]; then
    log_fail "Case 9 — first invocation didn't bind run_key to thread A: '$c9_first_run_key'"
elif [[ "$c9_first_thread" != "$c9_thread_a" ]]; then
    log_fail "Case 9 — first invocation didn't persist amp_thread_id='$c9_thread_a' (got '$c9_first_thread')"
elif [[ "$c9_second_run_key" != "$c9_thread_a" ]]; then
    log_fail "Case 9 — second invocation produced run_key='$c9_second_run_key' (expected continuity '$c9_thread_a')"
elif ! grep -qi "AMP_THREAD_ID flipped" "$c9_dir/stderr-2"; then
    log_fail "Case 9 — flip warning missing from stderr; got: $(cat "$c9_dir/stderr-2")"
else
    log_pass "Case 9 — flip detected, warning emitted, persisted run_key reused for continuity"
fi

# ---------------------------------------------------------------------------
# Happy path A — script entry point exists, executable, on path.
# ---------------------------------------------------------------------------
log_test "Happy A — .amp/toolbox/cerberus.sh exists, is a regular file, executable"
if [[ -f "$TOOLBOX_SCRIPT" && -x "$TOOLBOX_SCRIPT" ]]; then
    log_pass "Happy A — entry point present and executable"
else
    log_fail "Happy A — entry point missing or not executable: $TOOLBOX_SCRIPT"
fi

# ---------------------------------------------------------------------------
# Happy path B — TOOLBOX_ACTION=describe emits valid JSON listing the
# six commands in plan-mandated order.
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
# Happy path C — TOOLBOX_ACTION=execute with a valid command + a
# functioning stub backend exits 0. Sanity probe that the dispatch
# wiring is end-to-end clean.
# ---------------------------------------------------------------------------
log_test "Happy C — TOOLBOX_ACTION=execute end-to-end with stub backend"
hc_dir="$TEST_DIR/happy-c"
mkdir -p "$hc_dir"
hc_workspace="/tmp/some-amp-workspace-hc"
hc_stub="$(make_stub_review_gate "$hc_dir")"
hc_rc=0
run_helper "$hc_dir" "$hc_workspace" "$hc_stub" \
    '{"command":"status"}' \
    "$hc_dir/stdout" "$hc_dir/stderr" \
    "AMP_THREAD_ID=T-happyccc-7777-7000-aaaa-bbbbccccdddd" || hc_rc=$?
if [[ "$hc_rc" -ne 0 ]]; then
    log_fail "Happy C — execute exited with $hc_rc; stderr=$(cat "$hc_dir/stderr")"
elif [[ ! -f "$hc_dir/argv-capture.txt" ]]; then
    log_fail "Happy C — backend stub did not run"
else
    # 'status' command should invoke `bin/review-gate status --json`.
    if ! grep -q "^status$" "$hc_dir/argv-capture.txt" \
            || ! grep -q "^--json$" "$hc_dir/argv-capture.txt"; then
        log_fail "Happy C — backend argv missing 'status --json'; got: $(tr '\n' ' ' < "$hc_dir/argv-capture.txt")"
    else
        log_pass "Happy C — execute dispatched 'status --json' to backend"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "----------------------------------------"
echo "Amp shell-helper test summary:"
echo "  Passed: $TESTS_PASSED"
echo "  Failed: $TESTS_FAILED"
echo "----------------------------------------"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
