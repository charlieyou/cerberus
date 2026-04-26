#!/usr/bin/env bash
# test-debate-preflight.sh
#
# T002 Phase B preflight tests for `--debate` and `--debate-seed`:
#
#   1. Whitelist rejection: bare `spawn --type X --debate` for non-judging X
#      MUST exit 2 with stderr that names X and the four allowed values, and
#      MUST NOT invoke any reviewer model.
#   2. Whitelist positive: bare `spawn --type X --debate` for judging X passes
#      preflight (we don't run the model; we just assert preflight does not
#      reject the type).
#   3. <2 reviewers hard error: `--debate` with one or zero available
#      reviewers MUST exit non-zero with a clear error and no model invocation.
#   4. Generator slash command behavior: per R10, generator slash commands
#      that route through `bin/generate` (not `bin/review-gate spawn`) MAY
#      either silently ignore `--debate` or fail downstream. Both are
#      acceptable. Bare `spawn --type <generator-type> --debate` is rejected
#      at preflight (covered by case 1 above).
#   5. Help-output check: `bin/review-gate spawn --help` and each
#      `spawn-*-review --help` MUST mention `--debate`. None of the help
#      outputs may mention `--debate-seed` (hidden flag per R9).
#   6. `--debate-seed` value validation: a non-integer value MUST exit
#      non-zero with a clear error before any model invocation.
#
# These assertions verify the AC-PreflightReject acceptance criterion and the
# `--help` portion of AC-FlagAccept.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_GATE="$SCRIPT_DIR/../review-gate"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TEST_DIR=""
PASS_COUNT=0
FAIL_COUNT=0

log_test() { echo -e "${YELLOW}TEST:${NC} $1"; }
log_pass() { echo -e "${GREEN}PASS:${NC} $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
log_fail() {
    echo -e "${RED}FAIL:${NC} $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

cleanup() {
    if [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

TEST_DIR=$(mktemp -d -t test-debate-preflight.XXXXXX)
ARTIFACT_PATH="$TEST_DIR/artifact.md"
TRANSCRIPT_PATH="$TEST_DIR/transcript.jsonl"
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"

cat > "$ARTIFACT_PATH" <<'ART'
# Artifact for preflight tests
ART
touch "$TRANSCRIPT_PATH"

# Fake reviewer CLIs that never get to run if preflight rejects correctly.
# We instrument them with a marker file so the test can verify "no model
# invocation" for the rejection cases.
MARKER_DIR="$TEST_DIR/markers"
mkdir -p "$MARKER_DIR"

for agent in codex gemini claude; do
    cat > "$FAKE_BIN/$agent" <<MARKER
#!/usr/bin/env bash
touch "$MARKER_DIR/${agent}.invoked"
exit 0
MARKER
    chmod +x "$FAKE_BIN/$agent"
done

# Helper: run review-gate with a clean PATH that puts the fake bin first so
# command -v finds the fakes. This ensures the <2 reviewers preflight sees
# them as available unless we explicitly remove them from PATH.
run_with_fakes() {
    PATH="$FAKE_BIN:$PATH" "$REVIEW_GATE" "$@" 2>&1
}

# Helper: run review-gate WITHOUT the fakes on PATH (so command -v finds none
# unless real CLIs happen to be installed on the host).
run_without_fakes() {
    # Strip directories that resemble user-installed CLIs from PATH. We just
    # use a minimal PATH containing system utilities only.
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" "$REVIEW_GATE" "$@" 2>&1
}

clear_markers() {
    rm -f "$MARKER_DIR"/*.invoked
}

assert_no_model_invoked() {
    local label="$1"
    local found
    found=$(ls "$MARKER_DIR" 2>/dev/null | grep -c '\.invoked$' || true)
    if [[ "$found" -ne 0 ]]; then
        log_fail "$label: expected zero model invocations, but found $found marker file(s)"
        ls -la "$MARKER_DIR" >&2 || true
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Case 1: Whitelist rejection for non-judging --type values
# ---------------------------------------------------------------------------
for nontype in healthcheck architecture-review create-tasks manual auto; do
    log_test "whitelist rejection: bare spawn --type $nontype --debate exits 2 with no model invocation"
    clear_markers
    set +e
    output=$(run_with_fakes spawn \
        --session-id "test-preflight-$nontype" \
        --transcript-path "$TRANSCRIPT_PATH" \
        --type "$nontype" \
        --debate \
        --agents codex,gemini,claude \
        "$ARTIFACT_PATH")
    status=$?
    set -e

    if [[ "$status" -ne 2 ]]; then
        log_fail "$nontype: expected exit 2, got $status. Output:\n$output"
        continue
    fi

    if [[ "$output" != *"$nontype"* ]]; then
        log_fail "$nontype: stderr does not name the rejected --type value. Output:\n$output"
        continue
    fi

    # Must mention all four allowed values
    missing_allowed=""
    for allowed in code plan spec epic-verify; do
        if [[ "$output" != *"$allowed"* ]]; then
            missing_allowed+="$allowed "
        fi
    done
    if [[ -n "$missing_allowed" ]]; then
        log_fail "$nontype: stderr does not name allowed value(s): $missing_allowed. Output:\n$output"
        continue
    fi

    if ! assert_no_model_invoked "$nontype"; then
        continue
    fi

    log_pass "$nontype: rejected at preflight (exit 2, names rejected/allowed values, no model invoked)"
done

# ---------------------------------------------------------------------------
# Case 2: Whitelist positive — judging types pass the whitelist preflight.
# We can't run the full spawn (it would attempt model invocation and the gate
# infrastructure expects setsid/nohup/etc.), so we instead remove the fake
# CLIs from PATH and assert that the rejection error from case 1 does NOT
# fire. Other downstream errors (e.g., <2 reviewers) are acceptable here —
# we only assert that the WHITELIST preflight passes.
# ---------------------------------------------------------------------------
for goodtype in code plan spec epic-verify; do
    log_test "whitelist positive: bare spawn --type $goodtype --debate does not produce a whitelist rejection error"
    clear_markers
    set +e
    output=$(run_without_fakes spawn \
        --session-id "test-preflight-pos-$goodtype" \
        --transcript-path "$TRANSCRIPT_PATH" \
        --type "$goodtype" \
        --debate \
        --agents codex,gemini,claude \
        "$ARTIFACT_PATH")
    status=$?
    set -e

    if [[ "$output" == *"--debate is not supported for --type=$goodtype"* ]]; then
        log_fail "$goodtype: whitelist preflight incorrectly rejected a judging type. Output:\n$output"
        continue
    fi

    if [[ "$output" == *"--debate requires an explicit judging --type"* ]]; then
        log_fail "$goodtype: whitelist preflight incorrectly rejected an explicit judging type. Output:\n$output"
        continue
    fi

    log_pass "$goodtype: passes whitelist preflight (no rejection error)"
done

# ---------------------------------------------------------------------------
# Case 3: <2 reviewers hard error
# Run with a PATH that has zero reviewer CLIs — should hard-error before any
# model invocation.
# ---------------------------------------------------------------------------
log_test "<2 reviewers: bare spawn --type code --debate with zero available reviewers hard-errors"
clear_markers
set +e
output=$(run_without_fakes spawn \
    --session-id "test-preflight-zero-reviewers" \
    --transcript-path "$TRANSCRIPT_PATH" \
    --type code \
    --debate \
    --agents codex,gemini,claude \
    "$ARTIFACT_PATH")
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
    log_fail "expected non-zero exit when zero reviewers available, got 0. Output:\n$output"
elif [[ "$output" != *"--debate requires at least 2 available reviewers"* ]]; then
    log_fail "stderr does not name the <2 reviewers preflight error. Output:\n$output"
elif ! assert_no_model_invoked "<2 reviewers (zero)"; then
    :
else
    log_pass "<2 reviewers (zero available): hard-error before model invocation"
fi

# Run with exactly one available reviewer (only codex on PATH).
log_test "<2 reviewers: --debate with one available reviewer hard-errors"
ONE_REVIEWER_BIN="$TEST_DIR/one-reviewer-bin"
mkdir -p "$ONE_REVIEWER_BIN"
cp "$FAKE_BIN/codex" "$ONE_REVIEWER_BIN/codex"
clear_markers
set +e
output=$(PATH="$ONE_REVIEWER_BIN:/usr/bin:/bin" "$REVIEW_GATE" spawn \
    --session-id "test-preflight-one-reviewer" \
    --transcript-path "$TRANSCRIPT_PATH" \
    --type code \
    --debate \
    --agents codex,gemini,claude \
    "$ARTIFACT_PATH" 2>&1)
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
    log_fail "expected non-zero exit when one reviewer available, got 0. Output:\n$output"
elif [[ "$output" != *"--debate requires at least 2 available reviewers"* ]]; then
    log_fail "stderr does not name the <2 reviewers preflight error. Output:\n$output"
elif ! assert_no_model_invoked "<2 reviewers (one)"; then
    :
else
    log_pass "<2 reviewers (one available): hard-error before model invocation"
fi

# ---------------------------------------------------------------------------
# Case 4: Generator slash command behavior — documented as "either silently
# ignored OR fails downstream" per R10. We do not have a way to run the slash
# command machinery in a unit test, so we simply assert the bare-spawn route
# rejects the corresponding generator --type value (already covered by case
# 1 above for healthcheck/architecture-review/create-tasks). This case
# documents the v1 commitment for posterity.
# ---------------------------------------------------------------------------
log_pass "generator-slash-command: per R10 v1, generator slash commands either silently ignore --debate or fail downstream (out of scope for unit test; bare-spawn rejection of generator --type values is covered above)"

# ---------------------------------------------------------------------------
# Case 5: Help-output checks
# ---------------------------------------------------------------------------
help_must_mention_debate() {
    local subcommand="$1"
    local help_output
    help_output=$("$REVIEW_GATE" "$subcommand" --help 2>&1 || true)
    if [[ "$help_output" != *"--debate"* ]]; then
        log_fail "$subcommand --help does not mention --debate. Output:\n$help_output"
        return 1
    fi
    if [[ "$help_output" == *"--debate-seed"* ]]; then
        log_fail "$subcommand --help mentions hidden flag --debate-seed (must be hidden). Output:\n$help_output"
        return 1
    fi
    log_pass "$subcommand --help mentions --debate and hides --debate-seed"
    return 0
}

log_test "help output: bare spawn --help mentions --debate, hides --debate-seed"
help_must_mention_debate spawn || true

log_test "help output: spawn-code-review --help mentions --debate, hides --debate-seed"
help_must_mention_debate spawn-code-review || true

log_test "help output: spawn-plan-review --help mentions --debate, hides --debate-seed"
help_must_mention_debate spawn-plan-review || true

log_test "help output: spawn-spec-review --help mentions --debate, hides --debate-seed"
help_must_mention_debate spawn-spec-review || true

log_test "help output: spawn-epic-verify --help mentions --debate, hides --debate-seed"
help_must_mention_debate spawn-epic-verify || true

log_test "help output: top-level help mentions --debate, hides --debate-seed"
top_help=$("$REVIEW_GATE" --help 2>&1 || true)
if [[ "$top_help" != *"--debate"* ]]; then
    log_fail "top-level --help does not mention --debate"
elif [[ "$top_help" == *"--debate-seed"* ]]; then
    log_fail "top-level --help mentions hidden flag --debate-seed"
else
    log_pass "top-level --help mentions --debate and hides --debate-seed"
fi

# ---------------------------------------------------------------------------
# Case 6: --debate-seed value validation
# ---------------------------------------------------------------------------
log_test "--debate-seed must be a non-negative integer (rejects 'foo')"
clear_markers
set +e
output=$(run_with_fakes spawn \
    --session-id "test-preflight-bad-seed" \
    --transcript-path "$TRANSCRIPT_PATH" \
    --type code \
    --debate-seed foo \
    --agents codex,gemini,claude \
    "$ARTIFACT_PATH")
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
    log_fail "expected non-zero exit for non-integer --debate-seed, got 0. Output:\n$output"
elif [[ "$output" != *"--debate-seed must be"* ]]; then
    log_fail "stderr does not name the --debate-seed validation error. Output:\n$output"
elif ! assert_no_model_invoked "--debate-seed bad"; then
    :
else
    log_pass "--debate-seed foo: rejected with clear error"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Preflight tests: $PASS_COUNT passed, $FAIL_COUNT failed."
if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
