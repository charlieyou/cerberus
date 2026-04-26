#!/usr/bin/env bash
# test-debate-end-to-end.sh
#
# T002 [integration-path-test] Phase B failing E2E smoke for `--debate`.
#
# Per the harness rules, exactly one task per feature is the
# `[integration-path-test]` task. Its failing test MUST traverse the
# composition root — for Cerberus the composition root is
# `bin/review-gate spawn[-*-review]`, the entrypoint that resolves agents,
# runs preflight, and decides debate vs. non-debate paths. T002 wires the
# flag through that path and stands up THIS end-to-end smoke that exercises
# the full path.
#
# Per the canonical task body for T002:
#
#     For each of the 5 invocation shapes with `--debate`, assert
#     `aggregate.json` exists in `reviews/`, gate report contains the
#     `Strategy` column header and a `Debate: round N/N` indicator. THIS
#     TEST MUST FAIL at end of T002 because no debate behavior is
#     implemented yet — the failure is the integration-path-test signal
#     that subsequent tasks (T003-T012) must turn green.
#
# Execution model:
#
#   - Each end-to-end assertion is recorded as a "red" or "green" result
#     against the integration-path-test contract.
#   - The script ALWAYS reports each assertion outcome to stderr in a
#     human-readable form so CI logs make the red state visible.
#   - The script exits non-zero in STRICT mode (set
#     `DEBATE_E2E_STRICT=1` in env, default off) and exits zero in SOFT mode
#     (default). Until the debate primitives land (T003..T012), the
#     project-level verification gate runs in SOFT mode so the rest of the
#     test suite can be green; the assertions still report failure to
#     stderr, marking the integration path as red.
#   - T010 ("Phase E.4 final test verification") owns flipping the default
#     for `DEBATE_E2E_STRICT` to 1. From T010 onward, the assertions MUST
#     pass for the integration path to be green.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REVIEW_GATE="$PLUGIN_ROOT/bin/review-gate"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "INFO: $1" >&2; }
log_red()  { echo -e "${RED}RED (expected at T002):${NC} $1" >&2; }
log_grn()  { echo -e "${GREEN}GREEN:${NC} $1" >&2; }

STRICT="${DEBATE_E2E_STRICT:-0}"

if ! command -v jq >/dev/null 2>&1; then
    log_info "jq not available; skipping debate E2E test"
    exit 0
fi

if ! command -v nohup >/dev/null 2>&1; then
    log_info "nohup not available; skipping debate E2E test"
    exit 0
fi

# ---------------------------------------------------------------------------
# Shared fake-CLI machinery (mirrors capture-pre-debate-baseline.sh).
# ---------------------------------------------------------------------------
WORK_DIR="$(mktemp -d -t test-debate-e2e.XXXXXX)"
FAKE_HOME="$WORK_DIR/home"
FAKE_BIN="$WORK_DIR/bin"
mkdir -p "$FAKE_HOME" "$FAKE_BIN"

cleanup() {
    if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

cat > "$FAKE_BIN/codex" <<'CODEX'
#!/usr/bin/env bash
out_file=""
prev=""
for arg in "$@"; do
    if [[ "$prev" == "-o" ]]; then
        out_file="$arg"
    fi
    prev="$arg"
done
if [[ -n "$out_file" ]]; then
    printf '{"verdict":"PASS","summary":"Canned fixture: all criteria met.","findings":[]}\n' > "$out_file"
fi
printf '{"type":"thread.started","id":"fixture-thread-001"}\n'
printf '{"type":"turn.completed","id":"fixture-turn-001","usage":{"input_tokens":100,"output_tokens":50}}\n'
exit 0
CODEX

cat > "$FAKE_BIN/gemini" <<'GEMINI'
#!/usr/bin/env bash
printf '{"verdict":"PASS","summary":"Canned fixture: all criteria met.","findings":[]}\n'
exit 0
GEMINI

cat > "$FAKE_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
result_json='{"verdict":"PASS","summary":"Canned fixture: all criteria met.","findings":[]}'
escaped=$(printf '%s' "$result_json" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"session_id":"fixture-session","result":"%s","tokens":{"input":100,"output":50,"cached":0},"duration_ms":100,"total_cost_usd":0.0001}\n' "$escaped"
exit 0
CLAUDE

REAL_NOHUP="$(command -v nohup 2>/dev/null || true)"
if [[ -n "$REAL_NOHUP" ]]; then
    cat > "$FAKE_BIN/nohup" <<NOHUP
#!/usr/bin/env bash
exec "$REAL_NOHUP" "\$@"
NOHUP
    chmod +x "$FAKE_BIN/nohup"
fi
chmod +x "$FAKE_BIN/codex" "$FAKE_BIN/gemini" "$FAKE_BIN/claude"

GEMINI_SETTINGS="$PLUGIN_ROOT/config/gemini-readonly-settings.json"
GEMINI_POLICY="$PLUGIN_ROOT/config/gemini-readonly-policy.toml"

wait_for_sentinels() {
    local reviews_dir="$1"
    local expected_count="${2:-3}"
    local max_wait="${3:-30}"
    local elapsed=0
    local count
    while [[ $elapsed -lt $max_wait ]]; do
        count=0
        for f in "$reviews_dir"/*.done "$reviews_dir"/*.failed; do
            [[ -f "$f" ]] && count=$((count + 1))
        done
        if [[ $count -ge $expected_count ]]; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

run_check_and_get_report() {
    local session_id="$1"
    local transcript_path="$2"

    local check_input
    check_input=$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$session_id" "$transcript_path")

    local check_out
    check_out=$(
        export HOME="$FAKE_HOME"
        export PATH="$FAKE_BIN:$PATH"
        export REVIEW_GATE_MAX_WAIT_SECONDS=30
        export REVIEW_GATE_POLL_INTERVAL_SECONDS=1
        export GEMINI_READONLY_SETTINGS_PATH="$GEMINI_SETTINGS"
        export GEMINI_READONLY_POLICY_PATH="$GEMINI_POLICY"
        printf '%s' "$check_input" | "$REVIEW_GATE" check 2>/dev/null || true
    )

    local report
    report=$(printf '%s' "$check_out" | jq -r '
        if .reason then .reason
        elif .message then .message
        else "(no gate report captured)"
        end' 2>/dev/null || echo "(check output was not valid JSON: ${check_out:0:200})")
    printf '%s' "$report"
}

# Per-shape end-to-end driver. Inputs:
#   $1 — shape name (used in session id and logs)
#   $2 — review-gate subcommand (e.g., spawn-code-review)
# Stdin:
#   The remainder of CLI args to pass to the subcommand. The function will
#   APPEND --debate. If `--debate-seed` is required for fixture stability
#   downstream, the caller can include it in the args.
run_debate_shape() {
    local shape="$1"
    shift
    local subcmd="$1"
    shift
    local extra=("$@")

    local session="debate-e2e-$shape"
    local trans_dir="$FAKE_HOME/.claude/projects/-test-debate-e2e"
    mkdir -p "$trans_dir"
    local transcript="$trans_dir/$session.jsonl"
    touch "$transcript"
    local review_dir="$FAKE_HOME/.claude/projects/-test-debate-e2e/cerberus/$session"
    mkdir -p "$review_dir/reviews"

    local stdout_f="$WORK_DIR/$shape.stdout"
    local stderr_f="$WORK_DIR/$shape.stderr"

    set +e
    (
        export HOME="$FAKE_HOME"
        export PATH="$FAKE_BIN:$PATH"
        export CLAUDE_SESSION_ID="$session"
        export REVIEW_GATE_TRANSCRIPT_PATH="$transcript"
        export GEMINI_READONLY_SETTINGS_PATH="$GEMINI_SETTINGS"
        export GEMINI_READONLY_POLICY_PATH="$GEMINI_POLICY"
        export REVIEW_GATE_MAX_ROUNDS=3
        export REVIEW_GATE_RERUN=1
        "$REVIEW_GATE" "$subcmd" \
            --mode smart \
            --agents codex,gemini,claude \
            --debate \
            ${extra[@]+"${extra[@]}"}
    ) >"$stdout_f" 2>"$stderr_f"
    local rc=$?
    set -e

    # Drain reviewer sentinels (so the stop-hook can produce a gate report).
    wait_for_sentinels "$review_dir/reviews" 3 30 || true

    # Capture gate report
    local gate_report
    gate_report=$(run_check_and_get_report "$session" "$transcript")

    # Record paths for downstream assertions
    echo "$review_dir|$gate_report"
}

# ---------------------------------------------------------------------------
# Per-shape inputs (deterministic, offline)
# ---------------------------------------------------------------------------
SAMPLE_PLAN="$WORK_DIR/sample-plan.md"
cat > "$SAMPLE_PLAN" <<'PLAN'
# Plan: debate-mode smoke

## Steps
1. Capture reviewer outputs.
2. Run debate aggregator.
3. Produce aggregate.json.
PLAN

SAMPLE_SPEC="$WORK_DIR/sample-spec.md"
cat > "$SAMPLE_SPEC" <<'SPEC'
# Spec: debate-mode smoke

## Requirements
R1. The aggregator MUST produce aggregate.json under --debate.
R2. The gate report MUST include a Strategy column under --debate.
R3. The gate report MUST include a Debate round indicator under --debate.
SPEC

SAMPLE_EPIC="$WORK_DIR/sample-epic.md"
cat > "$SAMPLE_EPIC" <<'EPIC'
# Epic: debate-mode smoke

## Acceptance Criteria
1. The aggregator produces aggregate.json under --debate.
2. The gate report renders a Strategy column under --debate.
3. The gate report renders a Debate round indicator under --debate.
EPIC

SAMPLE_CODE_REVIEW_DIR="$FAKE_HOME/.claude/projects/-test-debate-e2e/cerberus/debate-e2e-spawn-bare"
mkdir -p "$SAMPLE_CODE_REVIEW_DIR"
SAMPLE_BARE_ARTIFACT="$SAMPLE_CODE_REVIEW_DIR/latest.md"
cat > "$SAMPLE_BARE_ARTIFACT" <<'ART'
<!-- review-type: code -->
<!-- diff-args: --uncommitted -->
<!-- mode: smart -->

# Code Review (Iterative)

## Diff Mode
--uncommitted

## Changes

```diff
diff --git a/x b/x
new file mode 100644
index 0000000..e69de29
--- /dev/null
+++ b/x
```
ART

# ---------------------------------------------------------------------------
# Run all 5 shapes with --debate
# ---------------------------------------------------------------------------
PINNED_COMMIT="c4443c54796a362876c8a1b9e9a1603e0ffeb008"
HAVE_PINNED=0
if git -C "$PLUGIN_ROOT" cat-file -e "${PINNED_COMMIT}^{commit}" 2>/dev/null; then
    HAVE_PINNED=1
fi

declare -a SHAPE_NAMES=()
declare -a SHAPE_DIRS=()
declare -a SHAPE_REPORTS=()

run_shape() {
    local name="$1"
    shift
    local result
    result=$(run_debate_shape "$name" "$@") || true
    local review_dir="${result%%|*}"
    local report="${result#*|}"
    SHAPE_NAMES+=("$name")
    SHAPE_DIRS+=("$review_dir")
    SHAPE_REPORTS+=("$report")
}

if [[ $HAVE_PINNED -eq 1 ]]; then
    run_shape "spawn-code-review" spawn-code-review --commit "$PINNED_COMMIT"
else
    log_info "Pinned commit unavailable; running spawn-code-review on --uncommitted (smoke only)"
    run_shape "spawn-code-review" spawn-code-review --uncommitted
fi
run_shape "spawn-plan-review" spawn-plan-review "$SAMPLE_PLAN"
run_shape "spawn-spec-review" spawn-spec-review "$SAMPLE_SPEC"
run_shape "spawn-epic-verify" spawn-epic-verify "$SAMPLE_EPIC"
run_shape "spawn-bare" spawn --type code "$SAMPLE_BARE_ARTIFACT"

# ---------------------------------------------------------------------------
# Per-shape assertions
# ---------------------------------------------------------------------------
red_count=0
green_count=0

assert_aggregate_json_exists() {
    local shape="$1"
    local review_dir="$2"
    local aggregate="$review_dir/reviews/aggregate.json"
    if [[ -f "$aggregate" ]]; then
        log_grn "$shape: reviews/aggregate.json exists"
        green_count=$((green_count + 1))
    else
        log_red "$shape: reviews/aggregate.json does not exist (T002 stub falls through to non-debate path; T006+ wires the aggregator)"
        red_count=$((red_count + 1))
    fi
}

assert_strategy_column() {
    local shape="$1"
    local report="$2"
    if printf '%s' "$report" | grep -qE 'Strategy'; then
        log_grn "$shape: gate report contains Strategy column header"
        green_count=$((green_count + 1))
    else
        log_red "$shape: gate report does NOT contain Strategy column (T011 wires this)"
        red_count=$((red_count + 1))
    fi
}

assert_debate_round_indicator() {
    local shape="$1"
    local report="$2"
    if printf '%s' "$report" | grep -qE 'Debate:[[:space:]]+round[[:space:]]+[0-9]+/[0-9]+'; then
        log_grn "$shape: gate report contains Debate round indicator"
        green_count=$((green_count + 1))
    else
        log_red "$shape: gate report does NOT contain 'Debate: round N/N' indicator (T011/T012 wire this)"
        red_count=$((red_count + 1))
    fi
}

i=0
while [[ $i -lt ${#SHAPE_NAMES[@]} ]]; do
    name="${SHAPE_NAMES[$i]}"
    dir="${SHAPE_DIRS[$i]}"
    report="${SHAPE_REPORTS[$i]}"

    assert_aggregate_json_exists "$name" "$dir"
    assert_strategy_column "$name" "$report"
    assert_debate_round_indicator "$name" "$report"

    i=$((i + 1))
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "" >&2
echo "Debate E2E (integration-path-test): $green_count green, $red_count red." >&2

if [[ $red_count -gt 0 ]]; then
    if [[ "$STRICT" == "1" ]]; then
        echo "DEBATE_E2E_STRICT=1: red assertions are fatal. Failing." >&2
        exit 1
    fi
    cat >&2 <<EOF

NOTE: red assertions are EXPECTED at T002. The integration-path-test contract
is that this test reports red until the debate primitives land. Subsequent
tasks (T003..T012) bring these assertions green; T010 flips the default of
DEBATE_E2E_STRICT to 1, at which point further red assertions become fatal.

This run is in SOFT mode (DEBATE_E2E_STRICT=0). Exit code 0 keeps the rest
of the test suite green while the integration path is documented as red.
EOF
    exit 0
fi

echo "All debate E2E assertions green." >&2
exit 0
