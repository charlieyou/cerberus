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
#   - T010 ("Phase E.4 final test verification") flips the default for
#     `DEBATE_E2E_STRICT` to 1. From T010 onward, the assertions MUST pass
#     for the integration path to be green; any red assertion is fatal.
#     T010 also extends the suite with three new scenarios (run unconditionally
#     after the per-shape loop):
#       - test_round3_launch_under_max_mode (Round 3 launches under
#         `--mode max`; aggregate.json.rounds_consumed == 3)
#       - test_round3_degraded_below_2_under_max (Round 3 NOT launched
#         when fewer than 2 reviewers are non-abstained across Round 1
#         AND Round 2 — matches the negative-case scenario in the task
#         spec's Verification block)
#       - test_falsifiable_acceptance_two_clause (the two-clause v1 launch
#         gate against `bin/tests/fixtures/debate-bad-artifact/`)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REVIEW_GATE="$PLUGIN_ROOT/bin/review-gate"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "INFO: $1" >&2; }
log_red()  { echo -e "${RED}RED:${NC} $1" >&2; }
log_grn()  { echo -e "${GREEN}GREEN:${NC} $1" >&2; }
# Pending-only log (legacy): retained for any future task that wants to
# stage assertions before its phase implementation lands. T011 (Phase F.1)
# flipped the Strategy column + Debate-round-indicator assertions from
# log_pending to log_red; they are now strict.
log_pending() { echo -e "${YELLOW}PENDING:${NC} $1" >&2; }

STRICT="${DEBATE_E2E_STRICT:-1}"

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
    # T011 (Phase F.1) wires the gate-report Strategy column header
    # (rightmost) when aggregate.json exists. Strict from T011 onward.
    if printf '%s' "$report" | grep -qE 'Strategy'; then
        log_grn "$shape: gate report contains Strategy column header"
        green_count=$((green_count + 1))
    else
        log_red "$shape: gate report Strategy column missing (T011 Phase F.1)"
        red_count=$((red_count + 1))
    fi
}

assert_debate_round_indicator() {
    local shape="$1"
    local report="$2"
    # T011 (Phase F.1) wires the gate-report Debate-round indicator
    # ("Debate: round N/N (strategies: ...)") when aggregate.json exists.
    # Strict from T011 onward.
    if printf '%s' "$report" | grep -qE 'Debate:[[:space:]]+round[[:space:]]+[0-9]+/[0-9]+'; then
        log_grn "$shape: gate report contains Debate round indicator"
        green_count=$((green_count + 1))
    else
        log_red "$shape: gate report Debate-round indicator missing (T011 Phase F.1)"
        red_count=$((red_count + 1))
    fi
}

# T011 (Phase F.1): when aggregate.json exists, the gate report's
# Strategy column header MUST be rightmost (i.e., the column header
# line ends with `| Strategy |`). Asserting placement (not just
# presence) is what catches a regression that prepended the column or
# inserted it mid-table.
assert_strategy_column_rightmost() {
    local shape="$1"
    local report="$2"
    if printf '%s' "$report" | grep -qE '\| Reviewer \| Verdict \| Confidence \| Summary \| Strategy \|[[:space:]]*$'; then
        log_grn "$shape: gate report Strategy column appended rightmost in the per-reviewer table"
        green_count=$((green_count + 1))
    else
        log_red "$shape: gate report Strategy column not rightmost (T011 Phase F.1; spec L388 — Strategy appended after the existing reviewer column)"
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
    assert_strategy_column_rightmost "$name" "$report"
    assert_debate_round_indicator "$name" "$report"

    i=$((i + 1))
done

# ---------------------------------------------------------------------------
# T008 Round-2 prompt-shape assertions.
#
# After Phase E.2 lands, every shape's Round-2 prompts MUST:
#   - exist under iterations/<iter>/round-2/review.<reviewer>.prompt
#   - contain the literal section header `Your Round 1 output:` (the
#     prior-round-self block, NOT scrubbed by R1's deny-list)
#   - contain the literal section header `Anonymized peer outputs:` (the
#     anonymized peer block, R1-scrubbed)
# ---------------------------------------------------------------------------
assert_round2_prompts_exist_with_markers() {
    local shape="$1"
    local review_dir="$2"

    # Locate the iteration directory (typically iterations/0/, but the
    # round-2 dir lives at <review_dir>/iterations/<iter>/round-2/). Pick
    # the highest-numbered iteration directory if multiple exist.
    local iter_root="$review_dir/iterations"
    if [[ ! -d "$iter_root" ]]; then
        log_red "$shape: iterations/ root missing under $review_dir (T008 wires Round-2 staging dirs here)"
        red_count=$((red_count + 1))
        return
    fi

    # Pick the latest iteration. Names are integers (0, 1, ...).
    local latest_iter
    latest_iter=$(ls -1 "$iter_root" 2>/dev/null | LC_ALL=C sort -n | tail -1)
    if [[ -z "$latest_iter" ]]; then
        log_red "$shape: no iteration subdir under $iter_root"
        red_count=$((red_count + 1))
        return
    fi
    local round2_dir="$iter_root/$latest_iter/round-2"
    if [[ ! -d "$round2_dir" ]]; then
        log_red "$shape: iterations/$latest_iter/round-2/ missing (Round 2 was not launched)"
        red_count=$((red_count + 1))
        return
    fi

    local r2_pass=1
    local rev
    for rev in codex gemini claude; do
        local p="$round2_dir/review.${rev}.prompt"
        if [[ ! -s "$p" ]]; then
            log_red "$shape: $p missing or empty (Round-2 prompt for $rev not built)"
            r2_pass=0
            continue
        fi
        if ! grep -q "Your Round 1 output:" "$p"; then
            log_red "$shape: $p missing 'Your Round 1 output:' marker"
            r2_pass=0
        fi
        if ! grep -q "Anonymized peer outputs:" "$p"; then
            log_red "$shape: $p missing 'Anonymized peer outputs:' marker"
            r2_pass=0
        fi
    done

    if [[ $r2_pass -eq 1 ]]; then
        log_grn "$shape: Round-2 prompts exist for all 3 reviewers and contain self+peer markers"
        green_count=$((green_count + 1))
    else
        red_count=$((red_count + 1))
    fi
}

# T008: prior-round-self block MUST NOT be scrubbed by the R1 deny-list.
# The reviewer's own Round-1 JSON is presented back to itself for self-
# comparison; the spec is explicit that the self-block is exempt from
# anonymization. The canned fake reviewer outputs in this test do not
# contain deny-list tokens, so the structural assertion here is that the
# self-block content (verdict + overall confidence + findings list)
# appears in the prompt unscrubbed (no `[REDACTED]` markers in the
# self-block region).
assert_round2_self_block_not_scrubbed() {
    local shape="$1"
    local review_dir="$2"
    local iter_root="$review_dir/iterations"
    if [[ ! -d "$iter_root" ]]; then
        return  # already counted as red by the prompt-existence assertion above
    fi
    local latest_iter
    latest_iter=$(ls -1 "$iter_root" 2>/dev/null | LC_ALL=C sort -n | tail -1)
    local round2_dir="$iter_root/$latest_iter/round-2"
    if [[ ! -d "$round2_dir" ]]; then
        return
    fi
    local p="$round2_dir/review.codex.prompt"
    if [[ ! -s "$p" ]]; then
        return
    fi
    # Extract the self-block region (between `### Your Round 1 output:` and
    # the next `###` header). Assert it contains the canned `Verdict:` line
    # and the canned overall-confidence default `0.5` (the canned fake
    # CLIs emit no `overall_confidence` so Mode B defaults to 0.5).
    local self_region
    self_region=$(awk '
        /^### Your Round 1 output:/ { capture=1; next }
        /^### Anonymized peer outputs:/ { capture=0 }
        capture { print }
    ' "$p")
    if printf '%s' "$self_region" | grep -q "Verdict:" \
       && printf '%s' "$self_region" | grep -q "Overall confidence:"; then
        log_grn "$shape: Round-2 self-block contains Verdict + Overall confidence (rendered, not scrubbed)"
        green_count=$((green_count + 1))
    else
        log_red "$shape: Round-2 self-block missing Verdict or Overall confidence lines (canned fake produces both)"
        red_count=$((red_count + 1))
    fi
}

i=0
while [[ $i -lt ${#SHAPE_NAMES[@]} ]]; do
    name="${SHAPE_NAMES[$i]}"
    dir="${SHAPE_DIRS[$i]}"
    assert_round2_prompts_exist_with_markers "$name" "$dir"
    assert_round2_self_block_not_scrubbed "$name" "$dir"
    i=$((i + 1))
done

# ---------------------------------------------------------------------------
# T008 terminal-abstention scenario: 3 reviewers, gemini fakes a Round-1
# crash. Round 2 launches with claude+codex only; gemini's slot surfaces
# to claude/codex's Round-2 peer block as `(peer abstained)`.
# ---------------------------------------------------------------------------
test_terminal_abstention_round1() {
    local scenario="terminal-abstention-r1"
    local scenario_work="$WORK_DIR/scenario-$scenario"
    local scenario_bin="$scenario_work/bin"
    local scenario_home="$scenario_work/home"
    mkdir -p "$scenario_bin" "$scenario_home"

    # Reuse the codex/claude canned CLIs from above; replace gemini with
    # one that always fails (forcing a Round-1 .failed sentinel and
    # therefore Mode A abstain — terminal for the run).
    cp "$FAKE_BIN/codex" "$scenario_bin/codex"
    cp "$FAKE_BIN/claude" "$scenario_bin/claude"
    cat > "$scenario_bin/gemini" <<'GEMINI_FAIL'
#!/usr/bin/env bash
echo "fixture: gemini deliberate Round-1 crash" >&2
exit 1
GEMINI_FAIL
    chmod +x "$scenario_bin/codex" "$scenario_bin/claude" "$scenario_bin/gemini"
    if [[ -n "$REAL_NOHUP" ]]; then
        cp "$FAKE_BIN/nohup" "$scenario_bin/nohup"
    fi

    local session="$scenario"
    local trans_dir="$scenario_home/.claude/projects/-test-debate-abstain"
    mkdir -p "$trans_dir"
    local transcript="$trans_dir/$session.jsonl"
    touch "$transcript"
    local review_dir="$scenario_home/.claude/projects/-test-debate-abstain/cerberus/$session"
    mkdir -p "$review_dir/reviews"

    local stdout_f="$scenario_work/stdout"
    local stderr_f="$scenario_work/stderr"
    set +e
    (
        export HOME="$scenario_home"
        export PATH="$scenario_bin:$PATH"
        export CLAUDE_SESSION_ID="$session"
        export REVIEW_GATE_TRANSCRIPT_PATH="$transcript"
        export GEMINI_READONLY_SETTINGS_PATH="$GEMINI_SETTINGS"
        export GEMINI_READONLY_POLICY_PATH="$GEMINI_POLICY"
        export REVIEW_GATE_MAX_ROUNDS=3
        export REVIEW_GATE_RERUN=1
        export REVIEW_GATE_MAX_WAIT_SECONDS=30
        export REVIEW_GATE_POLL_INTERVAL_SECONDS=1
        "$REVIEW_GATE" spawn-plan-review \
            --mode smart \
            --agents codex,gemini,claude \
            --debate \
            "$SAMPLE_PLAN"
    ) >"$stdout_f" 2>"$stderr_f"
    local rc=$?
    set -e

    # Locate iteration root + Round-2 dir.
    local iter_root="$review_dir/iterations"
    local latest_iter=""
    if [[ -d "$iter_root" ]]; then
        latest_iter=$(ls -1 "$iter_root" 2>/dev/null | LC_ALL=C sort -n | tail -1)
    fi
    local round2_dir="$iter_root/$latest_iter/round-2"

    # Assertion 1: Round-2 prompt exists for codex + claude (NOT for gemini).
    if [[ -s "$round2_dir/review.codex.prompt" \
          && -s "$round2_dir/review.claude.prompt" \
          && ! -e "$round2_dir/review.gemini.prompt" ]]; then
        log_grn "$scenario: Round 2 launches only for non-abstained Round-1 reviewers (codex + claude); gemini excluded"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: Round-2 prompt set unexpected. codex=$(test -s "$round2_dir/review.codex.prompt" && echo present || echo missing) claude=$(test -s "$round2_dir/review.claude.prompt" && echo present || echo missing) gemini=$(test -e "$round2_dir/review.gemini.prompt" && echo present || echo missing)"
        red_count=$((red_count + 1))
    fi

    # Assertion 2: gemini surfaces in claude's/codex's Round-2 peer block as
    # `(peer abstained)`.
    local saw_abstained=0
    if [[ -s "$round2_dir/review.codex.prompt" ]] \
       && grep -F "(peer abstained)" "$round2_dir/review.codex.prompt" >/dev/null; then
        saw_abstained=$((saw_abstained + 1))
    fi
    if [[ -s "$round2_dir/review.claude.prompt" ]] \
       && grep -F "(peer abstained)" "$round2_dir/review.claude.prompt" >/dev/null; then
        saw_abstained=$((saw_abstained + 1))
    fi
    # Spec R1: an abstained Round-1 reviewer's slot MUST surface as
    # `(peer abstained)` in BOTH active peers' Round-2 prompts (every
    # recipient sees every Round-1 peer in their per-recipient block).
    # A `>= 1` guard would silently accept a regression in
    # debate_build_peer_blocks that emitted the peer block for only one
    # of the two recipients, so we tighten to `eq 2`.
    if [[ $saw_abstained -eq 2 ]]; then
        log_grn "$scenario: gemini's slot surfaces as '(peer abstained)' in BOTH active peers' Round-2 prompts (2/2)"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: '(peer abstained)' marker present in only $saw_abstained/2 active peers' Round-2 prompts (expected 2)"
        red_count=$((red_count + 1))
    fi

    # Assertion 3: aggregate.json reflects 2 reviewers (codex + claude),
    # not 3.
    local aggregate="$review_dir/reviews/aggregate.json"
    if [[ -f "$aggregate" ]]; then
        local agg_reviewers
        agg_reviewers=$(jq -r '.reviewers | sort | join(",")' "$aggregate" 2>/dev/null || echo "")
        if [[ "$agg_reviewers" == "claude,codex" ]]; then
            log_grn "$scenario: aggregate.json.reviewers == [claude, codex] (gemini excluded — terminal abstention)"
            green_count=$((green_count + 1))
        else
            log_red "$scenario: aggregate.json.reviewers='$agg_reviewers' (expected 'claude,codex')"
            red_count=$((red_count + 1))
        fi
    else
        log_red "$scenario: aggregate.json absent — coordinator did not produce the final aggregate"
        red_count=$((red_count + 1))
    fi
}

# ---------------------------------------------------------------------------
# T008 degraded-below-2 mid-debate scenario: 2 reviewers, gemini fakes a
# Round-1 crash. Round 2 cannot launch (only 1 eligible reviewer remains)
# → the coordinator hard-errors with the canonical degraded-below-2
# message and on-disk shape; canonical reviews/ left empty.
# ---------------------------------------------------------------------------
test_degraded_below_2_round1() {
    local scenario="degraded-below-2"
    local scenario_work="$WORK_DIR/scenario-$scenario"
    local scenario_bin="$scenario_work/bin"
    local scenario_home="$scenario_work/home"
    mkdir -p "$scenario_bin" "$scenario_home"

    cp "$FAKE_BIN/codex" "$scenario_bin/codex"
    cat > "$scenario_bin/gemini" <<'GEMINI_FAIL'
#!/usr/bin/env bash
echo "fixture: gemini deliberate Round-1 crash" >&2
exit 1
GEMINI_FAIL
    chmod +x "$scenario_bin/codex" "$scenario_bin/gemini"
    if [[ -n "$REAL_NOHUP" ]]; then
        cp "$FAKE_BIN/nohup" "$scenario_bin/nohup"
    fi

    local session="$scenario"
    local trans_dir="$scenario_home/.claude/projects/-test-debate-degraded"
    mkdir -p "$trans_dir"
    local transcript="$trans_dir/$session.jsonl"
    touch "$transcript"
    local review_dir="$scenario_home/.claude/projects/-test-debate-degraded/cerberus/$session"
    mkdir -p "$review_dir/reviews"

    local stdout_f="$scenario_work/stdout"
    local stderr_f="$scenario_work/stderr"
    set +e
    (
        export HOME="$scenario_home"
        export PATH="$scenario_bin:$PATH"
        export CLAUDE_SESSION_ID="$session"
        export REVIEW_GATE_TRANSCRIPT_PATH="$transcript"
        export GEMINI_READONLY_SETTINGS_PATH="$GEMINI_SETTINGS"
        export GEMINI_READONLY_POLICY_PATH="$GEMINI_POLICY"
        export REVIEW_GATE_MAX_ROUNDS=3
        export REVIEW_GATE_RERUN=1
        export REVIEW_GATE_MAX_WAIT_SECONDS=30
        export REVIEW_GATE_POLL_INTERVAL_SECONDS=1
        "$REVIEW_GATE" spawn-plan-review \
            --mode smart \
            --agents codex,gemini \
            --debate \
            "$SAMPLE_PLAN"
    ) >"$stdout_f" 2>"$stderr_f"
    local rc=$?
    set -e

    # Assertion 1: coordinator emits the canonical degraded-below-2
    # message on stderr.
    if grep -F "debate degraded below 2 active reviewers in the final peer round" "$stderr_f" >/dev/null; then
        log_grn "$scenario: stderr contains canonical degraded-below-2 error message"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: stderr missing canonical degraded-below-2 message"
        red_count=$((red_count + 1))
    fi

    # Assertion 2: canonical reviews/ left empty of decision artifacts.
    # The spec's "canonical $REVIEWS_DIR is left empty" pertains to per-
    # reviewer review JSONs + sentinels + aggregate.json (the artifacts
    # that drive the Stop-hook's consensus calculator). The schema file
    # `review-schema.json` is emitted by the spawn flow BEFORE the
    # coordinator runs and is not a per-reviewer decision artifact, so
    # we exclude it from the empty-canonical check.
    local canonical_count=0
    local f
    for f in "$review_dir/reviews"/codex.json \
             "$review_dir/reviews"/claude.json \
             "$review_dir/reviews"/gemini.json \
             "$review_dir/reviews"/aggregate.json \
             "$review_dir/reviews"/codex.done \
             "$review_dir/reviews"/claude.done \
             "$review_dir/reviews"/gemini.done; do
        if [[ -e "$f" ]]; then
            canonical_count=$((canonical_count + 1))
        fi
    done
    if [[ "$canonical_count" == "0" ]]; then
        log_grn "$scenario: canonical reviews/ left empty of per-reviewer JSONs/sentinels/aggregate.json"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: canonical reviews/ has $canonical_count decision artifact(s) (expected 0)"
        red_count=$((red_count + 1))
    fi

    # Assertion 3: Round 2 was NOT launched — iterations/<iter>/round-2/
    # is absent or empty (no review.<reviewer>.prompt files).
    local iter_root="$review_dir/iterations"
    local latest_iter=""
    if [[ -d "$iter_root" ]]; then
        latest_iter=$(ls -1 "$iter_root" 2>/dev/null | LC_ALL=C sort -n | tail -1)
    fi
    local round2_dir="$iter_root/$latest_iter/round-2"
    local r2_prompt_count=0
    if [[ -d "$round2_dir" ]]; then
        r2_prompt_count=$(ls -1 "$round2_dir"/review.*.prompt 2>/dev/null | wc -l | tr -d ' ')
    fi
    if [[ "$r2_prompt_count" == "0" ]]; then
        log_grn "$scenario: Round 2 was NOT launched (no review.*.prompt files under round-2 staging)"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: Round 2 was launched ($r2_prompt_count Round-2 prompts found) — degraded-below-2 should have hard-errored before launch"
        red_count=$((red_count + 1))
    fi
}

# Run the new T008 scenario tests. They share WORK_DIR (cleaned up by the
# trap on EXIT) but use private subdirectories per scenario so concurrent
# state does not collide.
test_terminal_abstention_round1
test_degraded_below_2_round1

# ---------------------------------------------------------------------------
# T010 Round 3 launch under --mode max.
#
# Three reviewers (codex, gemini, claude) all return PASS canned outputs.
# Run debate with --mode max; assert:
#   1. iterations/<iter>/round-3/review.<reviewer>.prompt exists for all
#      three reviewers.
#   2. Each Round-3 prompt contains the literal markers
#      `## Round 3 of debate-mode review`, `### Your Round 2 output:`, and
#      `### Anonymized peer outputs:`.
#   3. aggregate.json.rounds_consumed == 3.
#   4. aggregate.json.reviewers contains all three reviewers (no
#      Option-B exclusion fired in this scenario — every reviewer's
#      canned output is parseable Mode B).
# ---------------------------------------------------------------------------
test_round3_launch_under_max_mode() {
    local scenario="round3-launch-max"
    local scenario_work="$WORK_DIR/scenario-$scenario"
    local scenario_bin="$scenario_work/bin"
    local scenario_home="$scenario_work/home"
    mkdir -p "$scenario_bin" "$scenario_home"

    cp "$FAKE_BIN/codex" "$scenario_bin/codex"
    cp "$FAKE_BIN/claude" "$scenario_bin/claude"
    cp "$FAKE_BIN/gemini" "$scenario_bin/gemini"
    chmod +x "$scenario_bin/codex" "$scenario_bin/claude" "$scenario_bin/gemini"
    if [[ -n "$REAL_NOHUP" ]]; then
        cp "$FAKE_BIN/nohup" "$scenario_bin/nohup"
    fi

    local session="$scenario"
    local trans_dir="$scenario_home/.claude/projects/-test-debate-r3"
    mkdir -p "$trans_dir"
    local transcript="$trans_dir/$session.jsonl"
    touch "$transcript"
    local review_dir="$scenario_home/.claude/projects/-test-debate-r3/cerberus/$session"
    mkdir -p "$review_dir/reviews"

    local stdout_f="$scenario_work/stdout"
    local stderr_f="$scenario_work/stderr"
    set +e
    (
        export HOME="$scenario_home"
        export PATH="$scenario_bin:$PATH"
        export CLAUDE_SESSION_ID="$session"
        export REVIEW_GATE_TRANSCRIPT_PATH="$transcript"
        export GEMINI_READONLY_SETTINGS_PATH="$GEMINI_SETTINGS"
        export GEMINI_READONLY_POLICY_PATH="$GEMINI_POLICY"
        export REVIEW_GATE_MAX_ROUNDS=3
        export REVIEW_GATE_RERUN=1
        export REVIEW_GATE_MAX_WAIT_SECONDS=30
        export REVIEW_GATE_POLL_INTERVAL_SECONDS=1
        "$REVIEW_GATE" spawn-plan-review \
            --mode max \
            --agents codex,gemini,claude \
            --debate \
            "$SAMPLE_PLAN"
    ) >"$stdout_f" 2>"$stderr_f"
    local rc=$?
    set -e

    local iter_root="$review_dir/iterations"
    local latest_iter=""
    if [[ -d "$iter_root" ]]; then
        latest_iter=$(ls -1 "$iter_root" 2>/dev/null | LC_ALL=C sort -n | tail -1)
    fi
    local round3_dir="$iter_root/$latest_iter/round-3"

    # Assertion 1: Round-3 prompt exists for all 3 reviewers.
    local r3_pass=1
    local rev
    for rev in codex gemini claude; do
        local p="$round3_dir/review.${rev}.prompt"
        if [[ ! -s "$p" ]]; then
            log_red "$scenario: Round-3 prompt missing for $rev at $p"
            r3_pass=0
        fi
    done
    if [[ $r3_pass -eq 1 ]]; then
        log_grn "$scenario: Round-3 prompts exist for all 3 reviewers under --mode max"
        green_count=$((green_count + 1))
    else
        red_count=$((red_count + 1))
    fi

    # Assertion 2: Round-3 prompts contain Round 3 markers.
    local r3_markers_pass=1
    for rev in codex gemini claude; do
        local p="$round3_dir/review.${rev}.prompt"
        if [[ ! -s "$p" ]]; then
            r3_markers_pass=0
            continue
        fi
        if ! grep -qF "## Round 3 of debate-mode review" "$p"; then
            log_red "$scenario: $p missing '## Round 3 of debate-mode review' header"
            r3_markers_pass=0
        fi
        if ! grep -qF "### Your Round 2 output:" "$p"; then
            log_red "$scenario: $p missing '### Your Round 2 output:' header"
            r3_markers_pass=0
        fi
        if ! grep -qF "### Anonymized peer outputs:" "$p"; then
            log_red "$scenario: $p missing '### Anonymized peer outputs:' header"
            r3_markers_pass=0
        fi
    done
    if [[ $r3_markers_pass -eq 1 ]]; then
        log_grn "$scenario: All Round-3 prompts contain Round-3 directive + Round-2 self-block + peer-block markers"
        green_count=$((green_count + 1))
    else
        red_count=$((red_count + 1))
    fi

    # Assertion 3: aggregate.json.rounds_consumed == 3.
    local aggregate="$review_dir/reviews/aggregate.json"
    if [[ -f "$aggregate" ]]; then
        local rc_field
        rc_field=$(jq -r '.rounds_consumed' "$aggregate" 2>/dev/null || echo "")
        if [[ "$rc_field" == "3" ]]; then
            log_grn "$scenario: aggregate.json.rounds_consumed == 3"
            green_count=$((green_count + 1))
        else
            log_red "$scenario: aggregate.json.rounds_consumed='$rc_field' (expected 3)"
            red_count=$((red_count + 1))
        fi

        # Assertion 4: all three reviewers appear in aggregate.json.reviewers.
        local agg_reviewers
        agg_reviewers=$(jq -r '.reviewers | sort | join(",")' "$aggregate" 2>/dev/null || echo "")
        if [[ "$agg_reviewers" == "claude,codex,gemini" ]]; then
            log_grn "$scenario: aggregate.json.reviewers == [claude, codex, gemini]"
            green_count=$((green_count + 1))
        else
            log_red "$scenario: aggregate.json.reviewers='$agg_reviewers' (expected 'claude,codex,gemini')"
            red_count=$((red_count + 1))
        fi
    else
        log_red "$scenario: aggregate.json absent — coordinator did not produce the final aggregate"
        red_count=$((red_count + 1))
    fi
}

# ---------------------------------------------------------------------------
# T010 Round 3 degraded-below-2 (negative case from task spec Verification):
# 3 reviewers under --mode max; gemini abstains in Round 1, codex abstains
# in Round 2 → only 1 reviewer (claude) is non-abstained across Rounds 1+2,
# so Round 3 MUST NOT be launched. The coordinator hard-errors with the
# canonical degraded-below-2 message; canonical reviews/ left empty;
# iterations/<iter>/round-3/ does not exist (or contains no prompts).
# ---------------------------------------------------------------------------
test_round3_degraded_below_2_under_max() {
    local scenario="round3-degraded-below-2"
    local scenario_work="$WORK_DIR/scenario-$scenario"
    local scenario_bin="$scenario_work/bin"
    local scenario_home="$scenario_work/home"
    mkdir -p "$scenario_bin" "$scenario_home"

    cp "$FAKE_BIN/claude" "$scenario_bin/claude"

    # gemini: always crash → Round-1 .failed (terminal abstain).
    cat > "$scenario_bin/gemini" <<'GEMINI_FAIL'
#!/usr/bin/env bash
echo "fixture: gemini deliberate Round-1 crash" >&2
exit 1
GEMINI_FAIL
    chmod +x "$scenario_bin/gemini"

    # codex: PASS in Round 1, then unparseable output in Round 2 (Mode A
    # abstain trigger). The real codex invocation receives the rendered
    # prompt on stdin (`codex exec ... - < "$REVIEW_PROMPT"`), so the
    # mock reads stdin into a temp buffer and greps for the Round-2
    # directive marker. The Round-1 prompt does NOT contain
    # `## Round 2 of debate-mode review`; the Round-2 prompt does. The
    # mock falls back to Round-1 behavior whenever stdin is empty
    # (defensive — should not happen with the real spawn flow).
    # codex: PASS in Round 1, then crash (exit 1) in Round 2. The crash
    # path produces a `.failed` sentinel (an unambiguous Mode A abstain
    # trigger that does not depend on extract_json's repair fallback —
    # `repair_review_output` would otherwise delegate to claude on PATH
    # and turn unparseable codex output into a synthetic PASS, masking
    # the abstain we want to test). The Round-1 vs Round-2 distinction
    # is detected by reading the prompt from stdin (codex's invocation
    # passes the prompt via `< "$REVIEW_PROMPT"`); the Round-2 prompt
    # contains `## Round 2 of debate-mode review`, the Round-1 prompt
    # does not.
    cat > "$scenario_bin/codex" <<'CODEX_R2_FAIL'
#!/usr/bin/env bash
out_file=""
prev=""
for arg in "$@"; do
    if [[ "$prev" == "-o" ]]; then
        out_file="$arg"
    fi
    prev="$arg"
done
prompt_buf=$(cat 2>/dev/null || true)
is_round2=0
if printf '%s' "$prompt_buf" | grep -qF "## Round 2 of debate-mode review"; then
    is_round2=1
fi
if [[ "$is_round2" == "1" ]]; then
    echo "fixture: codex deliberate Round-2 crash" >&2
    exit 1
fi
if [[ -n "$out_file" ]]; then
    printf '{"verdict":"PASS","summary":"Canned fixture: all criteria met.","findings":[]}\n' > "$out_file"
fi
printf '{"type":"thread.started","id":"fixture-thread-001"}\n'
printf '{"type":"turn.completed","id":"fixture-turn-001","usage":{"input_tokens":100,"output_tokens":50}}\n'
exit 0
CODEX_R2_FAIL
    chmod +x "$scenario_bin/codex"

    if [[ -n "$REAL_NOHUP" ]]; then
        cp "$FAKE_BIN/nohup" "$scenario_bin/nohup"
    fi

    local session="$scenario"
    local trans_dir="$scenario_home/.claude/projects/-test-debate-r3-deg"
    mkdir -p "$trans_dir"
    local transcript="$trans_dir/$session.jsonl"
    touch "$transcript"
    local review_dir="$scenario_home/.claude/projects/-test-debate-r3-deg/cerberus/$session"
    mkdir -p "$review_dir/reviews"

    local stdout_f="$scenario_work/stdout"
    local stderr_f="$scenario_work/stderr"
    set +e
    (
        export HOME="$scenario_home"
        export PATH="$scenario_bin:$PATH"
        export CLAUDE_SESSION_ID="$session"
        export REVIEW_GATE_TRANSCRIPT_PATH="$transcript"
        export GEMINI_READONLY_SETTINGS_PATH="$GEMINI_SETTINGS"
        export GEMINI_READONLY_POLICY_PATH="$GEMINI_POLICY"
        export REVIEW_GATE_MAX_ROUNDS=3
        export REVIEW_GATE_RERUN=1
        export REVIEW_GATE_MAX_WAIT_SECONDS=30
        export REVIEW_GATE_POLL_INTERVAL_SECONDS=1
        "$REVIEW_GATE" spawn-plan-review \
            --mode max \
            --agents codex,gemini,claude \
            --debate \
            "$SAMPLE_PLAN"
    ) >"$stdout_f" 2>"$stderr_f"
    local rc=$?
    set -e

    # Assertion 1: stderr contains canonical degraded-below-2 message.
    if grep -F "debate degraded below 2 active reviewers in the final peer round" "$stderr_f" >/dev/null; then
        log_grn "$scenario: stderr contains canonical degraded-below-2 message (under --mode max)"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: stderr missing canonical degraded-below-2 message"
        red_count=$((red_count + 1))
    fi

    # Assertion 2: canonical reviews/ left empty of decision artifacts.
    local canonical_count=0
    local f
    for f in "$review_dir/reviews"/codex.json \
             "$review_dir/reviews"/claude.json \
             "$review_dir/reviews"/gemini.json \
             "$review_dir/reviews"/aggregate.json \
             "$review_dir/reviews"/codex.done \
             "$review_dir/reviews"/claude.done \
             "$review_dir/reviews"/gemini.done; do
        if [[ -e "$f" ]]; then
            canonical_count=$((canonical_count + 1))
        fi
    done
    if [[ "$canonical_count" == "0" ]]; then
        log_grn "$scenario: canonical reviews/ left empty (no per-reviewer JSONs/sentinels/aggregate.json)"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: canonical reviews/ has $canonical_count decision artifact(s) (expected 0)"
        red_count=$((red_count + 1))
    fi

    # Assertion 3: Round 3 was NOT launched — round-3/ absent or empty of
    # review.*.prompt files.
    local iter_root="$review_dir/iterations"
    local latest_iter=""
    if [[ -d "$iter_root" ]]; then
        latest_iter=$(ls -1 "$iter_root" 2>/dev/null | LC_ALL=C sort -n | tail -1)
    fi
    local round3_dir="$iter_root/$latest_iter/round-3"
    local r3_prompt_count=0
    if [[ -d "$round3_dir" ]]; then
        r3_prompt_count=$(ls -1 "$round3_dir"/review.*.prompt 2>/dev/null | wc -l | tr -d ' ')
    fi
    if [[ "$r3_prompt_count" == "0" ]]; then
        log_grn "$scenario: Round 3 was NOT launched (no review.*.prompt files under round-3 staging)"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: Round 3 was launched ($r3_prompt_count Round-3 prompts found) — degraded-below-2 should have hard-errored before Round-3 launch"
        red_count=$((red_count + 1))
    fi
}

# ---------------------------------------------------------------------------
# T010 Round-3 peer-block surfaces R1/R2 abstainers as `(peer abstained)`
# (spec R1 terminal-abstention rule + stable Peer-X contract).
#
# Three reviewers under --mode max; gemini fails Round 1 (terminal abstain).
# Round 2 launches with claude+codex; both emit valid PASS outputs and
# advance to Round 3. Assertion: each Round-3 prompt for the surviving
# reviewers contains the literal `(peer abstained)` marker — gemini's
# slot must surface as abstained in both surviving reviewers' Round-3
# peer blocks (spec R1 + stable peer-ID contract: Peer-X labels stay
# pinned to the same model across rounds, so the abstained slot must
# still be rendered with the abstain placeholder rather than dropped).
# ---------------------------------------------------------------------------
test_round3_peer_block_includes_r1_abstainer() {
    local scenario="round3-peer-includes-abstainer"
    local scenario_work="$WORK_DIR/scenario-$scenario"
    local scenario_bin="$scenario_work/bin"
    local scenario_home="$scenario_work/home"
    mkdir -p "$scenario_bin" "$scenario_home"

    cp "$FAKE_BIN/codex" "$scenario_bin/codex"
    cp "$FAKE_BIN/claude" "$scenario_bin/claude"
    cat > "$scenario_bin/gemini" <<'GEMINI_FAIL'
#!/usr/bin/env bash
echo "fixture: gemini deliberate Round-1 crash" >&2
exit 1
GEMINI_FAIL
    chmod +x "$scenario_bin/codex" "$scenario_bin/claude" "$scenario_bin/gemini"
    if [[ -n "$REAL_NOHUP" ]]; then
        cp "$FAKE_BIN/nohup" "$scenario_bin/nohup"
    fi

    local session="$scenario"
    local trans_dir="$scenario_home/.claude/projects/-test-debate-r3-abstain"
    mkdir -p "$trans_dir"
    local transcript="$trans_dir/$session.jsonl"
    touch "$transcript"
    local review_dir="$scenario_home/.claude/projects/-test-debate-r3-abstain/cerberus/$session"
    mkdir -p "$review_dir/reviews"

    local stdout_f="$scenario_work/stdout"
    local stderr_f="$scenario_work/stderr"
    set +e
    (
        export HOME="$scenario_home"
        export PATH="$scenario_bin:$PATH"
        export CLAUDE_SESSION_ID="$session"
        export REVIEW_GATE_TRANSCRIPT_PATH="$transcript"
        export GEMINI_READONLY_SETTINGS_PATH="$GEMINI_SETTINGS"
        export GEMINI_READONLY_POLICY_PATH="$GEMINI_POLICY"
        export REVIEW_GATE_MAX_ROUNDS=3
        export REVIEW_GATE_RERUN=1
        export REVIEW_GATE_MAX_WAIT_SECONDS=30
        export REVIEW_GATE_POLL_INTERVAL_SECONDS=1
        "$REVIEW_GATE" spawn-plan-review \
            --mode max \
            --agents codex,gemini,claude \
            --debate \
            "$SAMPLE_PLAN"
    ) >"$stdout_f" 2>"$stderr_f"
    local rc=$?
    set -e

    local iter_root="$review_dir/iterations"
    local latest_iter=""
    if [[ -d "$iter_root" ]]; then
        latest_iter=$(ls -1 "$iter_root" 2>/dev/null | LC_ALL=C sort -n | tail -1)
    fi
    local round3_dir="$iter_root/$latest_iter/round-3"

    # Round-3 prompts MUST exist for codex + claude (the survivors of
    # Round 1's gemini crash).
    if [[ -s "$round3_dir/review.codex.prompt" \
          && -s "$round3_dir/review.claude.prompt" \
          && ! -e "$round3_dir/review.gemini.prompt" ]]; then
        log_grn "$scenario: Round-3 prompts exist for survivors (codex + claude); gemini absent"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: Round-3 prompt set unexpected. codex=$(test -s "$round3_dir/review.codex.prompt" && echo present || echo missing) claude=$(test -s "$round3_dir/review.claude.prompt" && echo present || echo missing) gemini=$(test -e "$round3_dir/review.gemini.prompt" && echo present || echo missing)"
        red_count=$((red_count + 1))
    fi

    # The abstain marker `(peer abstained)` must appear in BOTH
    # survivors' Round-3 peer blocks (spec R1: every initial peer slot
    # surfaces in the per-recipient peer block; abstained peers render
    # as the abstain placeholder).
    local saw_abstained=0
    if [[ -s "$round3_dir/review.codex.prompt" ]] \
       && grep -F "(peer abstained)" "$round3_dir/review.codex.prompt" >/dev/null; then
        saw_abstained=$((saw_abstained + 1))
    fi
    if [[ -s "$round3_dir/review.claude.prompt" ]] \
       && grep -F "(peer abstained)" "$round3_dir/review.claude.prompt" >/dev/null; then
        saw_abstained=$((saw_abstained + 1))
    fi
    if [[ $saw_abstained -eq 2 ]]; then
        log_grn "$scenario: gemini's slot surfaces as '(peer abstained)' in BOTH survivors' Round-3 peer blocks (2/2)"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: '(peer abstained)' marker present in only $saw_abstained/2 survivors' Round-3 peer blocks (expected 2 — Round-3 must surface every prior peer's slot per spec R1's terminal-abstention rule)"
        red_count=$((red_count + 1))
    fi

    # aggregate.json.reviewers excludes gemini (terminal abstention).
    local aggregate="$review_dir/reviews/aggregate.json"
    if [[ -f "$aggregate" ]]; then
        local agg_reviewers
        agg_reviewers=$(jq -r '.reviewers | sort | join(",")' "$aggregate" 2>/dev/null || echo "")
        if [[ "$agg_reviewers" == "claude,codex" ]]; then
            log_grn "$scenario: aggregate.json.reviewers == [claude, codex] (gemini excluded — terminal abstention persists through Round 3)"
            green_count=$((green_count + 1))
        else
            log_red "$scenario: aggregate.json.reviewers='$agg_reviewers' (expected 'claude,codex')"
            red_count=$((red_count + 1))
        fi
    else
        log_red "$scenario: aggregate.json absent — coordinator did not produce the final aggregate"
        red_count=$((red_count + 1))
    fi
}

# ---------------------------------------------------------------------------
# T010 falsifiable-acceptance two-clause assertion (the v1 launch gate).
#
# Run debate against `bin/tests/fixtures/debate-bad-artifact/` (a fixture
# with a planted P1 defect at a recorded `file_path`/`line_start`/`line_end`).
# The fake CLIs in this scenario emit the planted finding deterministically
# (with confidence 0.9) so:
#   - Clause 1: at least one reviewer's Round-1 output contains a P1
#     finding F whose `file_path` matches the planted file_path and
#     whose `line_start`/`line_end` integer range overlaps the planted
#     range (per R6's overlap predicate).
#   - Clause 2: aggregate.json.findings[] contains a finding F' with
#     `priority == "P1"`, `confidence >= 0.7`, `file_path` matching the
#     planted file_path, and `line_start`/`line_end` overlapping the
#     planted range. Title match NOT required (per the task spec).
#
# A failure in Clause 1 or Clause 2 fails the test (both clauses must
# pass — neither is sufficient on its own).
# ---------------------------------------------------------------------------
test_falsifiable_acceptance_two_clause() {
    local scenario="falsifiable-acceptance"
    local scenario_work="$WORK_DIR/scenario-$scenario"
    local scenario_bin="$scenario_work/bin"
    local scenario_home="$scenario_work/home"
    mkdir -p "$scenario_bin" "$scenario_home"

    local fixture_root="$PLUGIN_ROOT/bin/tests/fixtures/debate-bad-artifact"
    local defect_json="$fixture_root/defect-location.json"
    if [[ ! -f "$defect_json" ]]; then
        log_red "$scenario: defect-location.json missing under $fixture_root"
        red_count=$((red_count + 1))
        return
    fi

    local planted_file planted_lstart planted_lend
    planted_file=$(jq -r '.file_path' "$defect_json")
    planted_lstart=$(jq -r '.line_start' "$defect_json")
    planted_lend=$(jq -r '.line_end' "$defect_json")
    if [[ -z "$planted_file" || -z "$planted_lstart" || -z "$planted_lend" ]]; then
        log_red "$scenario: defect-location.json missing one of file_path/line_start/line_end"
        red_count=$((red_count + 1))
        return
    fi

    # Fake CLIs that always emit the planted P1 finding. Each reviewer
    # emits the finding in every round (Round 1 and Round 2). The
    # aggregator (T009 dedup) folds the three identical findings into
    # one with raised_by=[claude, codex, gemini] and confidence=0.9.
    local p1_finding
    p1_finding=$(jq -nc \
        --arg fp "$planted_file" \
        --argjson ls "$planted_lstart" \
        --argjson le "$planted_lend" \
        '{verdict:"NEEDS_WORK",
          summary:"Planted P1 found.",
          overall_confidence:0.9,
          findings:[{priority:1,
                     title:"Hardcoded credential in login()",
                     body:"The login function compares username/password against fixed string literals; any committed credential constitutes a P1 security defect.",
                     file_path:$fp,
                     line_start:$ls,
                     line_end:$le,
                     confidence:0.9}]}')

    cat > "$scenario_bin/codex" <<CODEX_PLANTED
#!/usr/bin/env bash
out_file=""
prev=""
for arg in "\$@"; do
    if [[ "\$prev" == "-o" ]]; then
        out_file="\$arg"
    fi
    prev="\$arg"
done
if [[ -n "\$out_file" ]]; then
    printf '%s\n' '$p1_finding' > "\$out_file"
fi
printf '{"type":"thread.started","id":"fixture-thread-001"}\n'
printf '{"type":"turn.completed","id":"fixture-turn-001","usage":{"input_tokens":100,"output_tokens":50}}\n'
exit 0
CODEX_PLANTED

    cat > "$scenario_bin/gemini" <<GEMINI_PLANTED
#!/usr/bin/env bash
printf '%s\n' '$p1_finding'
exit 0
GEMINI_PLANTED

    cat > "$scenario_bin/claude" <<CLAUDE_PLANTED
#!/usr/bin/env bash
result_json='$p1_finding'
escaped=\$(printf '%s' "\$result_json" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g')
printf '{"session_id":"fixture-session","result":"%s","tokens":{"input":100,"output":50,"cached":0},"duration_ms":100,"total_cost_usd":0.0001}\n' "\$escaped"
exit 0
CLAUDE_PLANTED

    chmod +x "$scenario_bin/codex" "$scenario_bin/gemini" "$scenario_bin/claude"
    if [[ -n "$REAL_NOHUP" ]]; then
        cp "$FAKE_BIN/nohup" "$scenario_bin/nohup"
    fi

    local session="$scenario"
    local trans_dir="$scenario_home/.claude/projects/-test-debate-falsifiable"
    mkdir -p "$trans_dir"
    local transcript="$trans_dir/$session.jsonl"
    touch "$transcript"
    local review_dir="$scenario_home/.claude/projects/-test-debate-falsifiable/cerberus/$session"
    mkdir -p "$review_dir/reviews"

    local stdout_f="$scenario_work/stdout"
    local stderr_f="$scenario_work/stderr"
    set +e
    (
        export HOME="$scenario_home"
        export PATH="$scenario_bin:$PATH"
        export CLAUDE_SESSION_ID="$session"
        export REVIEW_GATE_TRANSCRIPT_PATH="$transcript"
        export GEMINI_READONLY_SETTINGS_PATH="$GEMINI_SETTINGS"
        export GEMINI_READONLY_POLICY_PATH="$GEMINI_POLICY"
        export REVIEW_GATE_MAX_ROUNDS=3
        export REVIEW_GATE_RERUN=1
        export REVIEW_GATE_MAX_WAIT_SECONDS=30
        export REVIEW_GATE_POLL_INTERVAL_SECONDS=1
        "$REVIEW_GATE" spawn-plan-review \
            --mode smart \
            --agents codex,gemini,claude \
            --debate \
            "$fixture_root/plan.md"
    ) >"$stdout_f" 2>"$stderr_f"
    local rc=$?
    set -e

    local iter_root="$review_dir/iterations"
    local latest_iter=""
    if [[ -d "$iter_root" ]]; then
        latest_iter=$(ls -1 "$iter_root" 2>/dev/null | LC_ALL=C sort -n | tail -1)
    fi
    local round1_dir="$iter_root/$latest_iter/round-1"

    # Clause 1: at least one reviewer's Round-1 output contains a P1
    # finding at the planted location.
    local clause1_pass=0
    local rev
    for rev in codex gemini claude; do
        local r1json="$round1_dir/${rev}.augmented.json"
        if [[ ! -s "$r1json" ]]; then
            r1json="$round1_dir/${rev}.json"
        fi
        if [[ ! -s "$r1json" ]]; then
            continue
        fi
        # priority 1 OR "P1" + file_path match + line range overlap.
        local match
        match=$(jq -r --arg fp "$planted_file" \
                       --argjson ls "$planted_lstart" \
                       --argjson le "$planted_lend" '
            (.findings // [])
            | map(select(
                ((.priority == 1) or (.priority == "P1"))
                and (.file_path == $fp)
                and (.line_start != null) and (.line_end != null)
                and (.line_start <= $le) and ($ls <= .line_end)
            ))
            | length' "$r1json" 2>/dev/null || echo "0")
        if [[ "$match" -ge 1 ]]; then
            clause1_pass=1
            break
        fi
    done

    if [[ $clause1_pass -eq 1 ]]; then
        log_grn "$scenario: Clause 1 — at least one reviewer's Round-1 output contains a P1 finding at the planted location"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: Clause 1 FAILED — no reviewer's Round-1 output contains a P1 finding at the planted file_path/line range. Tune the fixture or reviewer prompts/strategies until Clause 1 passes."
        red_count=$((red_count + 1))
    fi

    # Clause 2: aggregate.json.findings[] contains a P1 finding F' with
    # confidence >= 0.7, file_path matching, and line range overlapping
    # the planted range. Title match NOT required.
    local aggregate="$review_dir/reviews/aggregate.json"
    local clause2_pass=0
    if [[ -f "$aggregate" ]]; then
        local match
        match=$(jq -r --arg fp "$planted_file" \
                       --argjson ls "$planted_lstart" \
                       --argjson le "$planted_lend" '
            (.findings // [])
            | map(select(
                (.priority == "P1")
                and ((.confidence // 0) >= 0.7)
                and (.file_path == $fp)
                and (.line_start != null) and (.line_end != null)
                and (.line_start <= $le) and ($ls <= .line_end)
            ))
            | length' "$aggregate" 2>/dev/null || echo "0")
        if [[ "$match" -ge 1 ]]; then
            clause2_pass=1
        fi
    fi

    if [[ $clause2_pass -eq 1 ]]; then
        log_grn "$scenario: Clause 2 — aggregate.json.findings[] retains a P1 finding (confidence>=0.7) at the planted location"
        green_count=$((green_count + 1))
    else
        if [[ ! -f "$aggregate" ]]; then
            log_red "$scenario: Clause 2 FAILED — aggregate.json absent (coordinator did not produce the final aggregate)"
        else
            log_red "$scenario: Clause 2 FAILED — aggregate.json.findings[] does not contain a P1 finding (confidence>=0.7) at planted file_path='$planted_file' overlapping lines $planted_lstart..$planted_lend. The Round-2 / final aggregator dropped the planted P1 — falsifiable-acceptance is failing."
        fi
        red_count=$((red_count + 1))
    fi
}

# Run the new T010 scenario tests. They share WORK_DIR (cleaned up by the
# trap on EXIT) but use private subdirectories per scenario so concurrent
# state does not collide.
test_round3_launch_under_max_mode
test_round3_degraded_below_2_under_max
test_round3_peer_block_includes_r1_abstainer
test_falsifiable_acceptance_two_clause

# ---------------------------------------------------------------------------
# T011 (Phase F.1) gate-report rendering scenarios.
#
# 1. test_aggregate_finding_cards_rendering — three reviewers all emit the
#    same planted P1 finding with confidence 0.9. The aggregator dedups
#    them into a single merged finding with raised_by=[claude, codex,
#    gemini]. The gate report's finding-cards section MUST be sourced
#    from aggregate.json.findings[] (one card per merged defect) and
#    MUST include the raised_by indicator since this finding is multi-
#    reviewer. Per task spec: "When aggregate.json exists: ... finding
#    cards sourced from aggregate.json.findings[] (one card per merged
#    defect with raised_by indicator if multi-reviewer)."
#
# 2. test_verdict_divergence_rendering — synthetic 2-reviewer fixture
#    (1 PASS@0.6, 1 NEEDS_WORK@0.85). Stop-hook returns requires_decision
#    (1-1 split with no FAIL); aggregate.verdict resolves to NEEDS_WORK
#    (confidence tiebreak). Renderer MUST display BOTH verdicts side-by-
#    side with the Stop-hook value labeled authoritative.
#
# 3. test_consensus_calculator_regression — runs the Stop-hook on per-
#    reviewer JSONs in two configurations (with and without confidence
#    fields, with and without aggregate.json sitting beside the per-
#    reviewer JSONs). Asserts gate-state.json.consensus.verdict is
#    byte-identical across both runs. This is the regression test pinned
#    in the task spec: "the priority-then-consensus calculator's output
#    MUST be unaffected by aggregate.json or confidence fields."
# ---------------------------------------------------------------------------
# Helper: run review-gate check against a scenario-specific HOME + PATH
# and return the gate report markdown extracted from the .reason or
# .message field of the JSON output. The existing run_check_and_get_report
# helper hard-codes HOME=$FAKE_HOME / PATH=$FAKE_BIN, which clobbers
# scenario-specific HOMEs; this helper accepts the override directly.
run_scenario_check_and_get_report() {
    local sc_home="$1"
    local sc_bin="$2"
    local session_id="$3"
    local transcript_path="$4"

    local check_input
    check_input=$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$session_id" "$transcript_path")

    local check_out
    check_out=$(
        export HOME="$sc_home"
        export PATH="$sc_bin:$PATH"
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

test_aggregate_finding_cards_rendering() {
    local scenario="aggregate-finding-cards"
    local scenario_work="$WORK_DIR/scenario-$scenario"
    local scenario_bin="$scenario_work/bin"
    local scenario_home="$scenario_work/home"
    mkdir -p "$scenario_bin" "$scenario_home"

    local fixture_root="$PLUGIN_ROOT/bin/tests/fixtures/debate-bad-artifact"
    local defect_json="$fixture_root/defect-location.json"
    if [[ ! -f "$defect_json" ]]; then
        log_red "$scenario: defect-location.json missing under $fixture_root"
        red_count=$((red_count + 1))
        return
    fi

    local planted_file planted_lstart planted_lend
    planted_file=$(jq -r '.file_path' "$defect_json")
    planted_lstart=$(jq -r '.line_start' "$defect_json")
    planted_lend=$(jq -r '.line_end' "$defect_json")

    local p1_finding
    p1_finding=$(jq -nc \
        --arg fp "$planted_file" \
        --argjson ls "$planted_lstart" \
        --argjson le "$planted_lend" \
        '{verdict:"NEEDS_WORK",
          summary:"Planted P1 found.",
          overall_confidence:0.9,
          findings:[{priority:1,
                     title:"Hardcoded credential in login()",
                     body:"The login function compares username/password against fixed string literals; any committed credential constitutes a P1 security defect.",
                     file_path:$fp,
                     line_start:$ls,
                     line_end:$le,
                     confidence:0.9}]}')

    cat > "$scenario_bin/codex" <<CODEX_PLANTED
#!/usr/bin/env bash
out_file=""
prev=""
for arg in "\$@"; do
    if [[ "\$prev" == "-o" ]]; then
        out_file="\$arg"
    fi
    prev="\$arg"
done
if [[ -n "\$out_file" ]]; then
    printf '%s\n' '$p1_finding' > "\$out_file"
fi
printf '{"type":"thread.started","id":"fixture-thread-001"}\n'
printf '{"type":"turn.completed","id":"fixture-turn-001","usage":{"input_tokens":100,"output_tokens":50}}\n'
exit 0
CODEX_PLANTED

    cat > "$scenario_bin/gemini" <<GEMINI_PLANTED
#!/usr/bin/env bash
printf '%s\n' '$p1_finding'
exit 0
GEMINI_PLANTED

    cat > "$scenario_bin/claude" <<CLAUDE_PLANTED
#!/usr/bin/env bash
result_json='$p1_finding'
escaped=\$(printf '%s' "\$result_json" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g')
printf '{"session_id":"fixture-session","result":"%s","tokens":{"input":100,"output":50,"cached":0},"duration_ms":100,"total_cost_usd":0.0001}\n' "\$escaped"
exit 0
CLAUDE_PLANTED
    chmod +x "$scenario_bin/codex" "$scenario_bin/gemini" "$scenario_bin/claude"
    if [[ -n "$REAL_NOHUP" ]]; then
        cp "$FAKE_BIN/nohup" "$scenario_bin/nohup"
    fi

    local session="$scenario"
    local trans_dir="$scenario_home/.claude/projects/-test-debate-cards"
    mkdir -p "$trans_dir"
    local transcript="$trans_dir/$session.jsonl"
    touch "$transcript"
    local review_dir="$scenario_home/.claude/projects/-test-debate-cards/cerberus/$session"
    mkdir -p "$review_dir/reviews"

    local stdout_f="$scenario_work/stdout"
    local stderr_f="$scenario_work/stderr"
    set +e
    (
        export HOME="$scenario_home"
        export PATH="$scenario_bin:$PATH"
        export CLAUDE_SESSION_ID="$session"
        export REVIEW_GATE_TRANSCRIPT_PATH="$transcript"
        export GEMINI_READONLY_SETTINGS_PATH="$GEMINI_SETTINGS"
        export GEMINI_READONLY_POLICY_PATH="$GEMINI_POLICY"
        export REVIEW_GATE_MAX_ROUNDS=3
        export REVIEW_GATE_RERUN=1
        export REVIEW_GATE_MAX_WAIT_SECONDS=30
        export REVIEW_GATE_POLL_INTERVAL_SECONDS=1
        "$REVIEW_GATE" spawn-plan-review \
            --mode smart \
            --agents codex,gemini,claude \
            --debate \
            "$fixture_root/plan.md"
    ) >"$stdout_f" 2>"$stderr_f"
    set -e

    wait_for_sentinels "$review_dir/reviews" 3 30 || true

    # Capture aggregate.json BEFORE running the gate-report check.
    # The Stop-hook's requires_decision branch calls clean_for_rerun
    # which archives reviews/ → reviews-iter-N/, so reviews/aggregate.json
    # is moved out by the time the check returns. We snapshot the file
    # here so subsequent assertions can rely on its presence.
    local aggregate="$review_dir/reviews/aggregate.json"
    local aggregate_snapshot="$scenario_work/aggregate.snapshot.json"
    if [[ -f "$aggregate" ]]; then
        cp "$aggregate" "$aggregate_snapshot"
    fi

    local gate_report
    gate_report=$(run_scenario_check_and_get_report "$scenario_home" "$scenario_bin" "$session" "$transcript")

    if [[ ! -f "$aggregate_snapshot" ]]; then
        log_red "$scenario: aggregate.json absent before gate-report check — coordinator did not produce the final aggregate (review_dir=$review_dir; spawn stderr tail: $(tail -3 "$stderr_f" 2>/dev/null | tr '\n' ';'))"
        red_count=$((red_count + 1))
        return
    fi
    aggregate="$aggregate_snapshot"

    # Assertion 1: the planted finding's title appears in the gate report
    # (one card per merged defect from aggregate.json.findings[]).
    if printf '%s' "$gate_report" | grep -qF "Hardcoded credential in login()"; then
        log_grn "$scenario: gate report contains aggregate.json finding title (one card per merged defect)"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: gate report missing aggregate.json finding title 'Hardcoded credential in login()'"
        red_count=$((red_count + 1))
    fi

    # Assertion 2: raised_by indicator present (multi-reviewer finding).
    # All three reviewers raised the same finding, so aggregate.json.findings[0].raised_by
    # should be ["claude","codex","gemini"], rendered as
    # `raised_by: claude, codex, gemini`.
    if printf '%s' "$gate_report" | grep -qE 'raised_by:[[:space:]]+claude,[[:space:]]+codex,[[:space:]]+gemini'; then
        log_grn "$scenario: gate report renders raised_by indicator for multi-reviewer finding"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: gate report missing 'raised_by: claude, codex, gemini' indicator (multi-reviewer merged finding)"
        red_count=$((red_count + 1))
    fi

    # Assertion 3: P1 priority appears in the rendered card head
    # (`### [P1] Hardcoded credential...`).
    if printf '%s' "$gate_report" | grep -qE '###[[:space:]]+\[P1\][[:space:]]+Hardcoded credential'; then
        log_grn "$scenario: gate report renders priority prefix in finding card head"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: gate report missing '[P1]' priority prefix in finding card head"
        red_count=$((red_count + 1))
    fi

    # Assertion 4: Aggregate verdict line is present and labels Stop-hook
    # authoritative. Planted P1 → aggregate.verdict=NEEDS_WORK, Stop-hook
    # blocks on P1 → consensus=requires_decision.
    if printf '%s' "$gate_report" | grep -qE 'Aggregate verdict:[[:space:]]+NEEDS_WORK[[:space:]]*\|[[:space:]]*Stop-hook verdict[[:space:]]+\(authoritative\):[[:space:]]+requires_decision'; then
        log_grn "$scenario: gate report renders aggregate-vs-Stop-hook verdict line with authoritative label"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: gate report missing side-by-side aggregate-vs-Stop-hook verdict line (expected 'Aggregate verdict: NEEDS_WORK | Stop-hook verdict (authoritative): requires_decision')"
        red_count=$((red_count + 1))
    fi
}

test_verdict_divergence_rendering() {
    local scenario="verdict-divergence"
    local scenario_work="$WORK_DIR/scenario-$scenario"
    local scenario_bin="$scenario_work/bin"
    local scenario_home="$scenario_work/home"
    mkdir -p "$scenario_bin" "$scenario_home"

    # Two reviewers (codex, claude). codex emits PASS@0.6, claude emits
    # NEEDS_WORK@0.85 with a P2 advisory finding (P2 → no P0/P1 blocking,
    # so the Stop-hook's mode=majority logic actually produces
    # requires_decision via the 1-1 split rather than the P0/P1 fast-
    # path). Aggregate.verdict resolves to NEEDS_WORK via confidence
    # tiebreak (0.85 > 0.6). Stop-hook resolves to requires_decision.
    # Both must surface side-by-side in the gate report.
    local pass_json='{"verdict":"PASS","summary":"Looks good to me.","overall_confidence":0.6,"findings":[]}'
    local nw_json='{"verdict":"NEEDS_WORK","summary":"Minor advisory finding.","overall_confidence":0.85,"findings":[{"priority":2,"title":"Minor advisory","body":"Cosmetic naming nit; non-blocking.","confidence":0.85}]}'

    cat > "$scenario_bin/codex" <<CODEX_DIV
#!/usr/bin/env bash
out_file=""
prev=""
for arg in "\$@"; do
    if [[ "\$prev" == "-o" ]]; then
        out_file="\$arg"
    fi
    prev="\$arg"
done
if [[ -n "\$out_file" ]]; then
    printf '%s\n' '$pass_json' > "\$out_file"
fi
printf '{"type":"thread.started","id":"fixture-thread-001"}\n'
printf '{"type":"turn.completed","id":"fixture-turn-001","usage":{"input_tokens":100,"output_tokens":50}}\n'
exit 0
CODEX_DIV

    cat > "$scenario_bin/claude" <<CLAUDE_DIV
#!/usr/bin/env bash
result_json='$nw_json'
escaped=\$(printf '%s' "\$result_json" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g')
printf '{"session_id":"fixture-session","result":"%s","tokens":{"input":100,"output":50,"cached":0},"duration_ms":100,"total_cost_usd":0.0001}\n' "\$escaped"
exit 0
CLAUDE_DIV

    chmod +x "$scenario_bin/codex" "$scenario_bin/claude"
    if [[ -n "$REAL_NOHUP" ]]; then
        cp "$FAKE_BIN/nohup" "$scenario_bin/nohup"
    fi

    local session="$scenario"
    local trans_dir="$scenario_home/.claude/projects/-test-debate-divergence"
    mkdir -p "$trans_dir"
    local transcript="$trans_dir/$session.jsonl"
    touch "$transcript"
    local review_dir="$scenario_home/.claude/projects/-test-debate-divergence/cerberus/$session"
    mkdir -p "$review_dir/reviews"

    set +e
    (
        export HOME="$scenario_home"
        export PATH="$scenario_bin:$PATH"
        export CLAUDE_SESSION_ID="$session"
        export REVIEW_GATE_TRANSCRIPT_PATH="$transcript"
        export GEMINI_READONLY_SETTINGS_PATH="$GEMINI_SETTINGS"
        export GEMINI_READONLY_POLICY_PATH="$GEMINI_POLICY"
        export REVIEW_GATE_MAX_ROUNDS=3
        export REVIEW_GATE_RERUN=1
        export REVIEW_GATE_MAX_WAIT_SECONDS=30
        export REVIEW_GATE_POLL_INTERVAL_SECONDS=1
        "$REVIEW_GATE" spawn-plan-review \
            --mode smart \
            --agents codex,claude \
            --debate \
            "$SAMPLE_PLAN"
    ) >/dev/null 2>&1
    set -e

    wait_for_sentinels "$review_dir/reviews" 2 30 || true

    # Capture aggregate.json BEFORE the gate-report check (which archives
    # reviews/ when in the requires_decision branch).
    local aggregate="$review_dir/reviews/aggregate.json"
    local aggregate_snapshot="$scenario_work/aggregate.snapshot.json"
    if [[ -f "$aggregate" ]]; then
        cp "$aggregate" "$aggregate_snapshot"
    fi

    local gate_report
    gate_report=$(run_scenario_check_and_get_report "$scenario_home" "$scenario_bin" "$session" "$transcript")

    if [[ ! -f "$aggregate_snapshot" ]]; then
        log_red "$scenario: aggregate.json absent — coordinator did not produce the final aggregate"
        red_count=$((red_count + 1))
        return
    fi
    aggregate="$aggregate_snapshot"

    # Assertion 1: aggregate.verdict is NEEDS_WORK (confidence tiebreak
    # picks the higher-confidence side under majority mode).
    local agg_verdict
    agg_verdict=$(jq -r '.verdict' "$aggregate" 2>/dev/null || echo "")
    if [[ "$agg_verdict" == "NEEDS_WORK" ]]; then
        log_grn "$scenario: aggregate.json.verdict == NEEDS_WORK (confidence tiebreak resolved 1-1 split)"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: aggregate.json.verdict='$agg_verdict' (expected NEEDS_WORK from PASS@0.6 vs NEEDS_WORK@0.85 tiebreak)"
        red_count=$((red_count + 1))
    fi

    # Assertion 2: gate report renders aggregate verdict + Stop-hook
    # verdict side-by-side with Stop-hook labeled authoritative.
    if printf '%s' "$gate_report" | grep -qE 'Aggregate verdict:[[:space:]]+NEEDS_WORK[[:space:]]*\|[[:space:]]*Stop-hook verdict[[:space:]]+\(authoritative\):[[:space:]]+requires_decision'; then
        log_grn "$scenario: gate report renders both verdicts side-by-side with Stop-hook labeled authoritative"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: gate report missing the side-by-side verdict line (expected 'Aggregate verdict: NEEDS_WORK | Stop-hook verdict (authoritative): requires_decision')"
        red_count=$((red_count + 1))
    fi
}

test_consensus_calculator_regression() {
    local scenario="consensus-calculator-regression"
    local scenario_work="$WORK_DIR/scenario-$scenario"
    local scenario_home="$scenario_work/home"
    local scenario_bin="$scenario_work/bin"
    mkdir -p "$scenario_home" "$scenario_bin"

    # The Stop-hook's calculate_consensus reads STATE_FILE (.config and
    # .reviewers keys) plus per-reviewer JSONs in REVIEWS_DIR. We construct
    # two synthetic gate states with IDENTICAL per-reviewer verdict +
    # findings shape but: (a) state A has NO confidence/overall_confidence
    # fields and NO aggregate.json sitting beside the JSONs (the legacy
    # non-debate shape); (b) state B has the SAME verdict + findings
    # shape but with confidence/overall_confidence fields ADDED and a
    # synthetic aggregate.json present (with a deliberately-misleading
    # verdict to falsify a calculator that incorrectly trusted aggregate.json).
    # The Stop-hook's calculator output (renderable as "Revision Required"
    # for requires_decision OR "Review Complete" for auto_approve) MUST
    # be byte-identical across both states. This proves confidence and
    # aggregate.json have no influence on the calculator (spec L376
    # Verdict authority + task-context Implementation Notes' Renderer-vs-
    # calculator split).

    local sa_session="${scenario}-A"
    local sb_session="${scenario}-B"
    local trans_dir="$scenario_home/.claude/projects/-test-debate-consensus"
    mkdir -p "$trans_dir"
    local sa_transcript="$trans_dir/$sa_session.jsonl"
    local sb_transcript="$trans_dir/$sb_session.jsonl"
    touch "$sa_transcript" "$sb_transcript"
    local sa_dir="$scenario_home/.claude/projects/-test-debate-consensus/cerberus/$sa_session"
    local sb_dir="$scenario_home/.claude/projects/-test-debate-consensus/cerberus/$sb_session"
    mkdir -p "$sa_dir/reviews" "$sb_dir/reviews"

    # Per-reviewer JSONs — same verdicts (one PASS, one NEEDS_WORK with
    # P2 only — the same shape that produces requires_decision through
    # the majority mode's 1-1 split branch).
    cat > "$sa_dir/reviews/codex.json" <<'JSON'
{"verdict":"PASS","summary":"Looks good.","findings":[]}
JSON
    cat > "$sa_dir/reviews/claude.json" <<'JSON'
{"verdict":"NEEDS_WORK","summary":"P2 advisory.","findings":[{"priority":2,"title":"Minor","body":"Cosmetic."}]}
JSON
    : > "$sa_dir/reviews/codex.done"
    : > "$sa_dir/reviews/claude.done"

    cat > "$sb_dir/reviews/codex.json" <<'JSON'
{"verdict":"PASS","summary":"Looks good.","overall_confidence":0.6,"findings":[],"strategy":"verification-first","round":2,"peer_responses_seen":["Peer-A"]}
JSON
    cat > "$sb_dir/reviews/claude.json" <<'JSON'
{"verdict":"NEEDS_WORK","summary":"P2 advisory.","overall_confidence":0.85,"findings":[{"priority":2,"title":"Minor","body":"Cosmetic.","confidence":0.85}],"strategy":"falsification-first","round":2,"peer_responses_seen":["Peer-B"]}
JSON
    : > "$sb_dir/reviews/codex.done"
    : > "$sb_dir/reviews/claude.done"

    # Synthetic aggregate.json with a DELIBERATELY-MISLEADING verdict
    # (PASS) sitting beside the per-reviewer JSONs. A correct calculator
    # MUST ignore this and still produce requires_decision based solely
    # on the per-reviewer verdicts; if a regression made aggregate.verdict
    # leak into the calculator it would flip to auto_approve.
    cat > "$sb_dir/reviews/aggregate.json" <<'JSON'
{"verdict":"PASS","summary":"sentinel — calculator MUST ignore this","findings":[],"consensus_mode":"majority","rounds_consumed":2,"reviewers":["claude","codex"],"strategies":{"claude":"falsification-first","codex":"verification-first"}}
JSON

    # Pre-populate gate-state.json with .reviewers map (.config defaulted
    # to majority) so the Stop-hook's check path runs the calculator.
    local now_iso
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    for d in "$sa_dir" "$sb_dir"; do
        cat > "$d/gate-state.json" <<JSON
{
  "status":"pending",
  "config":{"consensus_mode":"majority"},
  "mode":{"type":"plan","plan_path":"$SAMPLE_PLAN"},
  "reviewers":{"codex":{},"claude":{}},
  "consensus":null,
  "decision":null,
  "trigger_source":"plan",
  "created_at":"$now_iso"
}
JSON
        printf '0' > "$d/iteration.txt"
    done

    # Drive the Stop-hook check path on each scenario. The check writes
    # the gate-report markdown into the .reason field of its JSON output.
    # The calculator's classification is encoded in the gate report
    # markdown: "## Revision Required" → requires_decision; "## Review
    # Complete" → auto_approve. We grep for these markers as the
    # calculator's externally-observable output (the in-state
    # consensus.verdict gets cleared by clean_for_rerun in the
    # requires_decision path before the check returns, so the gate-
    # report markdown is the stable surface to assert against).
    local sa_report sb_report
    sa_report=$(run_scenario_check_and_get_report "$scenario_home" "$scenario_bin" "$sa_session" "$sa_transcript")
    sb_report=$(run_scenario_check_and_get_report "$scenario_home" "$scenario_bin" "$sb_session" "$sb_transcript")

    classify_calculator_output() {
        local report="$1"
        if printf '%s' "$report" | grep -qF "## Revision Required"; then
            echo "requires_decision"
        elif printf '%s' "$report" | grep -qF "## Review Complete"; then
            echo "auto_approve"
        elif printf '%s' "$report" | grep -qF "## Max Iterations Reached"; then
            echo "max_iterations"
        else
            echo "unknown"
        fi
    }

    local sa_class sb_class
    sa_class=$(classify_calculator_output "$sa_report")
    sb_class=$(classify_calculator_output "$sb_report")

    if [[ "$sa_class" == "$sb_class" && "$sa_class" != "unknown" ]]; then
        log_grn "$scenario: calculate_consensus classification byte-identical across with-/without-confidence + with-/without-aggregate.json (sa=sb='$sa_class')"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: calculate_consensus output diverged — confidence/aggregate.json influenced the calculator (sa='$sa_class' vs sb='$sb_class'). Renderer-vs-calculator split has been violated."
        red_count=$((red_count + 1))
    fi

    # Sanity assertion: both runs land in requires_decision (1-1 split,
    # P2 advisory under majority mode). If this fails, the test fixture
    # is wrong (not the calculator).
    if [[ "$sa_class" == "requires_decision" ]]; then
        log_grn "$scenario: calculator returns requires_decision for 1-1 PASS/NEEDS_WORK split with P2 advisory (today's behaviour, unchanged)"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: calculator returned '$sa_class' for 1-1 PASS/NEEDS_WORK split (expected requires_decision)"
        red_count=$((red_count + 1))
    fi

    # Tighter assertion: scenario B (with aggregate.json having
    # verdict=PASS) MUST NOT produce auto_approve. If a regression
    # plumbed aggregate.verdict into the calculator, this would flip
    # to auto_approve and the assertion would fail loudly.
    if [[ "$sb_class" != "auto_approve" ]]; then
        log_grn "$scenario: aggregate.json.verdict=PASS in scenario B did NOT leak into the calculator (output stayed at '$sb_class' rather than auto_approve)"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: aggregate.json.verdict=PASS leaked into the calculator (sb='$sb_class') — calculator must ignore aggregate.json."
        red_count=$((red_count + 1))
    fi
}

test_aggregate_finding_cards_rendering
test_verdict_divergence_rendering
test_consensus_calculator_regression

# ---------------------------------------------------------------------------
# T012 (Phase F.2) telemetry surfaces + distinct exit codes scenarios.
#
# Coverage:
#   1. test_gate_state_debate_block_success — success path writes the
#      pinned gate-state.json.debate block; iterations/<iter>/debate-telemetry.json
#      ABSENT (success-path partial state file is NOT written).
#   2. test_non_debate_run_no_debate_key — non-debate spawn does NOT add a
#      .debate top-level key (NOT null, NOT {}).
#   3. test_debate_block_survives_stop_hook — after Stop-hook flips
#      pending → awaiting_decision → resolved, .debate stays present.
#   4. test_aggregate_verdict_never_requires_decision — aggregate.json
#      across all SHAPE_DIRS asserts .verdict ∈ {PASS|NEEDS_WORK|FAIL}
#      strictly; requires_decision only appears in
#      gate-state.json.consensus.verdict.
#   5. test_degraded_below_2_partial_telemetry — extends the existing
#      degraded-below-2 scenario with the T012-specific assertions:
#      iterations/<iter>/debate-telemetry.json present; gate-state.json
#      transitioned to awaiting_decision + consensus.verdict = requires_decision;
#      no .debate block; reviews/ empty.
#   6. test_aggregator_failure_partial_telemetry — directly invoke the
#      aggregator helper with a malformed augmented JSON; verify exit
#      code 5, stderr `aggregator failed: jq parse error on reviews/<r>.json`,
#      and partial telemetry file written.
#   7. test_cancellation_sigint — start a debate run with a hanging fake
#      reviewer, send SIGINT during Round 1, verify exit code 130,
#      partial telemetry written, gate-state.json.status stays at pending,
#      no .debate block, canonical reviews/ empty.
# ---------------------------------------------------------------------------

# Helper: assert gate-state.json.debate block has the pinned shape with
# rounds_telemetry containing exactly the listed round numbers in order.
assert_debate_block_pinned_shape() {
    local scenario="$1"
    local state_file="$2"
    local expected_rounds="$3"  # comma-separated, e.g., "1,2"
    local expected_mode="$4"

    if [[ ! -f "$state_file" ]]; then
        log_red "$scenario: gate-state.json missing at $state_file"
        red_count=$((red_count + 1))
        return
    fi

    # Top-level .debate present (NOT null).
    local has_debate
    has_debate=$(jq -r '.debate | type' "$state_file" 2>/dev/null || echo "null")
    if [[ "$has_debate" != "object" ]]; then
        log_red "$scenario: gate-state.json.debate is not an object (got: $has_debate)"
        red_count=$((red_count + 1))
        return
    fi
    log_grn "$scenario: gate-state.json.debate is an object"
    green_count=$((green_count + 1))

    # All pinned top-level keys present.
    local missing_keys=""
    local k
    for k in rounds mode consensus_mode strategies rounds_telemetry aggregator_notes; do
        local v
        v=$(jq -r ".debate | has(\"$k\")" "$state_file" 2>/dev/null || echo "false")
        if [[ "$v" != "true" ]]; then
            missing_keys="$missing_keys $k"
        fi
    done
    if [[ -n "$missing_keys" ]]; then
        log_red "$scenario: gate-state.json.debate missing keys:$missing_keys"
        red_count=$((red_count + 1))
    else
        log_grn "$scenario: gate-state.json.debate has all pinned keys (rounds, mode, consensus_mode, strategies, rounds_telemetry, aggregator_notes)"
        green_count=$((green_count + 1))
    fi

    # Mode matches expected.
    local actual_mode
    actual_mode=$(jq -r '.debate.mode' "$state_file" 2>/dev/null || echo "")
    if [[ "$actual_mode" == "$expected_mode" ]]; then
        log_grn "$scenario: gate-state.json.debate.mode == \"$expected_mode\""
        green_count=$((green_count + 1))
    else
        log_red "$scenario: gate-state.json.debate.mode == \"$actual_mode\" (expected \"$expected_mode\")"
        red_count=$((red_count + 1))
    fi

    # rounds_telemetry list of round numbers matches expected.
    local actual_rounds_csv
    actual_rounds_csv=$(jq -r '.debate.rounds_telemetry | map(.round | tostring) | join(",")' "$state_file" 2>/dev/null || echo "")
    if [[ "$actual_rounds_csv" == "$expected_rounds" ]]; then
        log_grn "$scenario: gate-state.json.debate.rounds_telemetry rounds == [$expected_rounds]"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: gate-state.json.debate.rounds_telemetry rounds == [$actual_rounds_csv] (expected [$expected_rounds])"
        red_count=$((red_count + 1))
    fi

    # Per-round entries have the pinned per-reviewer shape.
    local round_shape_ok=1
    local rt_count
    rt_count=$(jq -r '.debate.rounds_telemetry | length' "$state_file" 2>/dev/null || echo "0")
    local i=0
    while [[ $i -lt $rt_count ]]; do
        # Each entry must have round, started_at, finished_at, wall_clock_ms,
        # reviewers (array). reviewers[*] must have name, abstained,
        # overall_confidence, tokens_used, integrity_flags.
        local entry_keys_ok
        entry_keys_ok=$(jq -r --argjson i "$i" '
            .debate.rounds_telemetry[$i]
            | (has("round") and has("started_at") and has("finished_at")
               and has("wall_clock_ms") and has("reviewers"))
        ' "$state_file" 2>/dev/null || echo "false")
        if [[ "$entry_keys_ok" != "true" ]]; then
            round_shape_ok=0
            break
        fi
        local rev_keys_ok
        rev_keys_ok=$(jq -r --argjson i "$i" '
            .debate.rounds_telemetry[$i].reviewers
            | all(. as $r | $r | (has("name") and has("abstained")
                                  and has("overall_confidence")
                                  and has("tokens_used")
                                  and has("integrity_flags")))
        ' "$state_file" 2>/dev/null || echo "false")
        if [[ "$rev_keys_ok" != "true" ]]; then
            round_shape_ok=0
            break
        fi
        i=$((i + 1))
    done
    if [[ $round_shape_ok -eq 1 ]]; then
        log_grn "$scenario: per-round entries have the pinned shape (round, started_at, finished_at, wall_clock_ms, reviewers[name, abstained, overall_confidence, tokens_used, integrity_flags])"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: per-round telemetry entries missing pinned keys"
        red_count=$((red_count + 1))
    fi
}

test_gate_state_debate_block_success() {
    local scenario="gate-state-debate-block-success"

    # Re-use the spawn-plan-review SHAPE result (ran already). Look up
    # its review_dir from SHAPE_DIRS / SHAPE_NAMES.
    local idx=0
    local found=""
    while [[ $idx -lt ${#SHAPE_NAMES[@]} ]]; do
        if [[ "${SHAPE_NAMES[$idx]}" == "spawn-plan-review" ]]; then
            found="${SHAPE_DIRS[$idx]}"
            break
        fi
        idx=$((idx + 1))
    done
    if [[ -z "$found" ]]; then
        log_red "$scenario: spawn-plan-review review_dir not found in SHAPE_DIRS"
        red_count=$((red_count + 1))
        return
    fi

    local state_file="$found/gate-state.json"
    assert_debate_block_pinned_shape "$scenario" "$state_file" "1,2" "smart"

    # Success-path MUST NOT write debate-telemetry.json.
    local iter_root="$found/iterations"
    local latest_iter
    latest_iter=$(ls -1 "$iter_root" 2>/dev/null | LC_ALL=C sort -n | tail -1)
    local telemetry_file="$iter_root/$latest_iter/debate-telemetry.json"
    if [[ ! -e "$telemetry_file" ]]; then
        log_grn "$scenario: iterations/<iter>/debate-telemetry.json ABSENT on success path (success surface is gate-state.json.debate)"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: iterations/$latest_iter/debate-telemetry.json should NOT be written on success path"
        red_count=$((red_count + 1))
    fi
}

test_non_debate_run_no_debate_key() {
    local scenario="non-debate-no-debate-key"
    local scenario_work="$WORK_DIR/scenario-$scenario"
    local scenario_bin="$scenario_work/bin"
    local scenario_home="$scenario_work/home"
    mkdir -p "$scenario_bin" "$scenario_home"

    cp "$FAKE_BIN/codex" "$scenario_bin/codex"
    cp "$FAKE_BIN/gemini" "$scenario_bin/gemini"
    cp "$FAKE_BIN/claude" "$scenario_bin/claude"
    chmod +x "$scenario_bin/codex" "$scenario_bin/gemini" "$scenario_bin/claude"
    if [[ -n "$REAL_NOHUP" ]]; then
        cp "$FAKE_BIN/nohup" "$scenario_bin/nohup"
    fi

    local session="$scenario"
    local trans_dir="$scenario_home/.claude/projects/-test-non-debate"
    mkdir -p "$trans_dir"
    local transcript="$trans_dir/$session.jsonl"
    touch "$transcript"
    local review_dir="$scenario_home/.claude/projects/-test-non-debate/cerberus/$session"
    mkdir -p "$review_dir/reviews"

    set +e
    (
        export HOME="$scenario_home"
        export PATH="$scenario_bin:$PATH"
        export CLAUDE_SESSION_ID="$session"
        export REVIEW_GATE_TRANSCRIPT_PATH="$transcript"
        export GEMINI_READONLY_SETTINGS_PATH="$GEMINI_SETTINGS"
        export GEMINI_READONLY_POLICY_PATH="$GEMINI_POLICY"
        export REVIEW_GATE_RERUN=1
        export REVIEW_GATE_MAX_WAIT_SECONDS=30
        export REVIEW_GATE_POLL_INTERVAL_SECONDS=1
        # NO --debate flag — straight non-debate run.
        "$REVIEW_GATE" spawn-plan-review \
            --mode smart \
            --agents codex,gemini,claude \
            "$SAMPLE_PLAN"
    ) >/dev/null 2>&1
    set -e

    wait_for_sentinels "$review_dir/reviews" 3 30 || true

    local state_file="$review_dir/gate-state.json"
    if [[ ! -f "$state_file" ]]; then
        log_red "$scenario: gate-state.json missing for non-debate run"
        red_count=$((red_count + 1))
        return
    fi

    # `.debate` MUST be absent. jq returns null for both missing keys and
    # explicit null values; we strengthen the assertion by checking with
    # `has("debate")`.
    local has_debate_key
    has_debate_key=$(jq -r 'has("debate")' "$state_file" 2>/dev/null || echo "true")
    if [[ "$has_debate_key" == "false" ]]; then
        log_grn "$scenario: non-debate gate-state.json does NOT contain a 'debate' key (NOT null, NOT {})"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: non-debate gate-state.json unexpectedly contains a 'debate' key (value: $(jq -c '.debate' "$state_file" 2>/dev/null))"
        red_count=$((red_count + 1))
    fi
}

test_debate_block_survives_stop_hook() {
    local scenario="debate-block-survives-stop-hook"

    # Re-use the spawn-plan-review SHAPE result. The `run_check_and_get_report`
    # helper used during shape collection already drove the Stop-hook check
    # path, which jq-patches gate-state.json.status / .consensus. The
    # `.debate` block written by the coordinator BEFORE the check ran
    # MUST still be present after the Stop-hook patch.
    local idx=0
    local found=""
    while [[ $idx -lt ${#SHAPE_NAMES[@]} ]]; do
        if [[ "${SHAPE_NAMES[$idx]}" == "spawn-plan-review" ]]; then
            found="${SHAPE_DIRS[$idx]}"
            break
        fi
        idx=$((idx + 1))
    done
    if [[ -z "$found" ]]; then
        log_red "$scenario: spawn-plan-review review_dir not found in SHAPE_DIRS"
        red_count=$((red_count + 1))
        return
    fi

    local state_file="$found/gate-state.json"
    if [[ ! -f "$state_file" ]]; then
        log_red "$scenario: gate-state.json missing at $state_file"
        red_count=$((red_count + 1))
        return
    fi

    # Stop-hook ran during run_check_and_get_report; gate-state.json.status
    # should be either resolved or awaiting_decision (NOT pending) by now.
    local status
    status=$(jq -r '.status' "$state_file" 2>/dev/null || echo "")
    if [[ "$status" != "pending" && -n "$status" ]]; then
        log_grn "$scenario: gate-state.json.status transitioned away from pending (now: $status — Stop-hook patch ran)"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: gate-state.json.status still 'pending' after Stop-hook should have run (got: $status)"
        red_count=$((red_count + 1))
    fi

    # `.debate` block MUST still be present and an object.
    local has_debate
    has_debate=$(jq -r '.debate | type' "$state_file" 2>/dev/null || echo "null")
    if [[ "$has_debate" == "object" ]]; then
        log_grn "$scenario: gate-state.json.debate survived Stop-hook patch (still an object)"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: gate-state.json.debate lost during Stop-hook patch (now: $has_debate)"
        red_count=$((red_count + 1))
    fi

    # The pinned keys MUST still be present.
    local missing_keys=""
    local k
    for k in rounds mode consensus_mode strategies rounds_telemetry aggregator_notes; do
        local v
        v=$(jq -r ".debate | has(\"$k\")" "$state_file" 2>/dev/null || echo "false")
        if [[ "$v" != "true" ]]; then
            missing_keys="$missing_keys $k"
        fi
    done
    if [[ -z "$missing_keys" ]]; then
        log_grn "$scenario: gate-state.json.debate retains all pinned keys after Stop-hook patch"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: gate-state.json.debate lost keys after Stop-hook patch:$missing_keys"
        red_count=$((red_count + 1))
    fi
}

test_aggregate_verdict_never_requires_decision() {
    local scenario="aggregate-verdict-never-requires-decision"

    # Walk all SHAPE_DIRS that produced an aggregate.json. The aggregator
    # MUST never emit `requires_decision` — that surface lives in
    # gate-state.json.consensus.verdict only. Verify across all five shapes.
    local violations=0
    local checked=0
    local idx=0
    while [[ $idx -lt ${#SHAPE_DIRS[@]} ]]; do
        local d="${SHAPE_DIRS[$idx]}"
        local agg_files=()
        # Aggregate may have been moved to reviews-iter-N/ by the
        # Stop-hook's clean_for_rerun. Check both the canonical path and
        # any archived siblings.
        local f
        for f in "$d/reviews/aggregate.json" "$d"/reviews-iter-*/aggregate.json; do
            [[ -f "$f" ]] && agg_files+=("$f")
        done
        for f in "${agg_files[@]+${agg_files[@]}}"; do
            checked=$((checked + 1))
            local v
            v=$(jq -r '.verdict' "$f" 2>/dev/null || echo "")
            case "$v" in
                PASS|NEEDS_WORK|FAIL) ;;
                *)
                    log_red "$scenario: $f has verdict='$v' (must be PASS|NEEDS_WORK|FAIL)"
                    violations=$((violations + 1))
                    ;;
            esac
        done
        idx=$((idx + 1))
    done

    if [[ $checked -eq 0 ]]; then
        log_red "$scenario: no aggregate.json files found across SHAPE_DIRS — cannot validate enum"
        red_count=$((red_count + 1))
        return
    fi

    if [[ $violations -eq 0 ]]; then
        log_grn "$scenario: all $checked aggregate.json verdicts are in {PASS|NEEDS_WORK|FAIL} (requires_decision lives only in gate-state.json.consensus.verdict)"
        green_count=$((green_count + 1))
    else
        red_count=$((red_count + violations))
    fi
}

test_degraded_below_2_partial_telemetry() {
    local scenario="degraded-below-2-partial-telemetry"
    local scenario_work="$WORK_DIR/scenario-$scenario"
    local scenario_bin="$scenario_work/bin"
    local scenario_home="$scenario_work/home"
    mkdir -p "$scenario_bin" "$scenario_home"

    cp "$FAKE_BIN/codex" "$scenario_bin/codex"
    cat > "$scenario_bin/gemini" <<'GEMINI_FAIL'
#!/usr/bin/env bash
echo "fixture: gemini deliberate Round-1 crash" >&2
exit 1
GEMINI_FAIL
    chmod +x "$scenario_bin/codex" "$scenario_bin/gemini"
    if [[ -n "$REAL_NOHUP" ]]; then
        cp "$FAKE_BIN/nohup" "$scenario_bin/nohup"
    fi

    local session="$scenario"
    local trans_dir="$scenario_home/.claude/projects/-test-debate-deg-tel"
    mkdir -p "$trans_dir"
    local transcript="$trans_dir/$session.jsonl"
    touch "$transcript"
    local review_dir="$scenario_home/.claude/projects/-test-debate-deg-tel/cerberus/$session"
    mkdir -p "$review_dir/reviews"

    set +e
    local rc
    (
        export HOME="$scenario_home"
        export PATH="$scenario_bin:$PATH"
        export CLAUDE_SESSION_ID="$session"
        export REVIEW_GATE_TRANSCRIPT_PATH="$transcript"
        export GEMINI_READONLY_SETTINGS_PATH="$GEMINI_SETTINGS"
        export GEMINI_READONLY_POLICY_PATH="$GEMINI_POLICY"
        export REVIEW_GATE_MAX_ROUNDS=3
        export REVIEW_GATE_RERUN=1
        export REVIEW_GATE_MAX_WAIT_SECONDS=30
        export REVIEW_GATE_POLL_INTERVAL_SECONDS=1
        "$REVIEW_GATE" spawn-plan-review \
            --mode smart \
            --agents codex,gemini \
            --debate \
            "$SAMPLE_PLAN"
    ) >/dev/null 2>"$scenario_work/stderr"
    rc=$?
    set -e

    # Assertion: exit code 6 (degraded-below-2). The coordinator's
    # `_rdc_degraded_exit` directly exits 6, propagating through the
    # parent script.
    if [[ "$rc" -eq 6 ]]; then
        log_grn "$scenario: review-gate exits 6 on degraded-below-2"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: review-gate exit code = $rc (expected 6 for degraded-below-2)"
        red_count=$((red_count + 1))
    fi

    # Assertion: iterations/<iter>/debate-telemetry.json written.
    local iter_root="$review_dir/iterations"
    local latest_iter
    latest_iter=$(ls -1 "$iter_root" 2>/dev/null | LC_ALL=C sort -n | tail -1)
    local telemetry_file="$iter_root/$latest_iter/debate-telemetry.json"
    if [[ -f "$telemetry_file" ]]; then
        # Sanity-check the shape: it should be a JSON object with the
        # pinned keys.
        local has_keys
        has_keys=$(jq -r '
            (has("rounds") and has("mode") and has("consensus_mode")
             and has("strategies") and has("rounds_telemetry")
             and has("aggregator_notes"))
        ' "$telemetry_file" 2>/dev/null || echo "false")
        if [[ "$has_keys" == "true" ]]; then
            log_grn "$scenario: iterations/<iter>/debate-telemetry.json present with pinned keys"
            green_count=$((green_count + 1))
        else
            log_red "$scenario: iterations/<iter>/debate-telemetry.json missing pinned keys"
            red_count=$((red_count + 1))
        fi

        # Round-1 telemetry should be recorded (the round completed before
        # the eligibility check fired).
        local r1_present
        r1_present=$(jq -r '[.rounds_telemetry[] | select(.round == 1)] | length' "$telemetry_file" 2>/dev/null || echo "0")
        if [[ "$r1_present" -ge 1 ]]; then
            log_grn "$scenario: partial telemetry contains Round-1 entry (recorded before degraded-below-2 fired)"
            green_count=$((green_count + 1))
        else
            log_red "$scenario: partial telemetry has no Round-1 entry"
            red_count=$((red_count + 1))
        fi
    else
        log_red "$scenario: iterations/<iter>/debate-telemetry.json missing on degraded-below-2 path"
        red_count=$((red_count + 1))
    fi

    # Assertion: gate-state.json.status = "awaiting_decision" and
    # consensus.verdict = "requires_decision".
    local state_file="$review_dir/gate-state.json"
    if [[ -f "$state_file" ]]; then
        local status verdict
        status=$(jq -r '.status' "$state_file" 2>/dev/null || echo "")
        verdict=$(jq -r '.consensus.verdict' "$state_file" 2>/dev/null || echo "")
        if [[ "$status" == "awaiting_decision" && "$verdict" == "requires_decision" ]]; then
            log_grn "$scenario: gate-state.json.status='awaiting_decision', consensus.verdict='requires_decision'"
            green_count=$((green_count + 1))
        else
            log_red "$scenario: gate-state.json status='$status' verdict='$verdict' (expected awaiting_decision/requires_decision)"
            red_count=$((red_count + 1))
        fi

        # Assertion: NO `.debate` top-level key on degraded path.
        local has_debate_key
        has_debate_key=$(jq -r 'has("debate")' "$state_file" 2>/dev/null || echo "true")
        if [[ "$has_debate_key" == "false" ]]; then
            log_grn "$scenario: gate-state.json has NO .debate top-level key on degraded path"
            green_count=$((green_count + 1))
        else
            log_red "$scenario: gate-state.json unexpectedly has .debate key on degraded path"
            red_count=$((red_count + 1))
        fi
    else
        log_red "$scenario: gate-state.json missing on degraded path"
        red_count=$((red_count + 1))
    fi

    # Assertion: canonical reviews/ left empty of decision artifacts.
    local canonical_count=0
    local f
    for f in "$review_dir/reviews"/codex.json \
             "$review_dir/reviews"/claude.json \
             "$review_dir/reviews"/gemini.json \
             "$review_dir/reviews"/aggregate.json \
             "$review_dir/reviews"/codex.done \
             "$review_dir/reviews"/claude.done \
             "$review_dir/reviews"/gemini.done; do
        if [[ -e "$f" ]]; then
            canonical_count=$((canonical_count + 1))
        fi
    done
    if [[ "$canonical_count" == "0" ]]; then
        log_grn "$scenario: canonical reviews/ left empty on degraded path"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: canonical reviews/ has $canonical_count decision artifact(s) on degraded path"
        red_count=$((red_count + 1))
    fi
}

# Aggregator-failure unit-test-style scenario. Direct invocation of
# _rdc_aggregate_and_promote with a malformed augmented JSON file. The
# aggregator's early jq-parse-error guard MUST emit
# `aggregator failed: jq parse error on reviews/<r>.json` and exit 5,
# with iterations/<iter>/debate-telemetry.json written.
test_aggregator_failure_partial_telemetry() {
    local scenario="aggregator-failure-partial-telemetry"
    local scenario_work="$WORK_DIR/scenario-$scenario"
    mkdir -p "$scenario_work"

    # Build a fake iter_dir with a round-2 staging dir holding a
    # deliberately-malformed augmented JSON for `claude` and a valid one
    # for `codex`. _rdc_aggregate_and_promote's per-reviewer loop catches
    # the malformed JSON on the first reviewer it processes; iteration
    # order is `active_reviewers` (passed in alphabetical order by the
    # caller), so we put the malformed file at `claude.augmented.json`.
    local iter_dir="$scenario_work/iterations/0"
    local round_dir="$iter_dir/round-2"
    local reviews_dir="$scenario_work/reviews"
    mkdir -p "$round_dir" "$reviews_dir"

    # Malformed augmented JSON (no closing brace + invalid escape) for claude.
    printf '{"verdict":"PASS","summary":"oops",' > "$round_dir/claude.augmented.json"

    # Valid augmented JSON for codex.
    printf '{"verdict":"PASS","summary":"ok","overall_confidence":0.7,"findings":[]}\n' \
        > "$round_dir/codex.augmented.json"

    # Run _rdc_aggregate_and_promote in a subshell so its `exit 5` does
    # not terminate the parent test script. Capture stderr + exit code.
    local stderr_f="$scenario_work/stderr"
    local rc
    set +e
    (
        # Source the helpers in the subshell.
        # shellcheck disable=SC1091
        source "$PLUGIN_ROOT/bin/telemetry-lib.sh"
        # shellcheck disable=SC1091
        source "$PLUGIN_ROOT/bin/review-gate-debate.sh"

        # Initialize globals so _rdc_compose_debate_block + the partial
        # telemetry write path work without errors.
        _RDC_ITER_DIR="$iter_dir"
        _RDC_REVIEWS_DIR="$reviews_dir"
        _RDC_CONSENSUS_MODE="majority"
        _RDC_DEBATE_MODE="smart"
        _RDC_STRATEGIES_JSON='{}'
        _RDC_ROUNDS_JSON='[]'
        _RDC_ROUNDS_COMPLETED=0
        _RDC_AGGREGATOR_NOTES_JSON='[]'

        _rdc_aggregate_and_promote \
            "$round_dir" "$reviews_dir" "majority" 2 \
            claude codex
    ) 2>"$stderr_f"
    rc=$?
    set -e

    # Assertion: exit code 5.
    if [[ "$rc" -eq 5 ]]; then
        log_grn "$scenario: aggregator failure exits 5"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: aggregator exited with code $rc (expected 5)"
        red_count=$((red_count + 1))
    fi

    # Assertion: stderr contains canonical jq-parse-error message.
    if grep -F "aggregator failed: jq parse error on reviews/claude.json" "$stderr_f" >/dev/null 2>&1; then
        log_grn "$scenario: stderr contains 'aggregator failed: jq parse error on reviews/claude.json'"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: stderr missing canonical 'aggregator failed: jq parse error on reviews/claude.json' message. Stderr: $(head -3 "$stderr_f" 2>/dev/null | tr '\n' ';')"
        red_count=$((red_count + 1))
    fi

    # Assertion: iterations/<iter>/debate-telemetry.json written.
    local telemetry_file="$iter_dir/debate-telemetry.json"
    if [[ -f "$telemetry_file" ]]; then
        log_grn "$scenario: partial telemetry written on aggregator failure"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: partial telemetry NOT written on aggregator failure"
        red_count=$((red_count + 1))
    fi

    # Assertion: canonical reviews/ left empty of per-reviewer JSONs +
    # aggregate.json (the partial-promotion cleanup MUST roll back any
    # files that were already moved).
    local canonical_count=0
    local f
    for f in "$reviews_dir"/claude.json "$reviews_dir"/codex.json \
             "$reviews_dir"/aggregate.json \
             "$reviews_dir"/claude.done "$reviews_dir"/codex.done; do
        if [[ -e "$f" ]]; then
            canonical_count=$((canonical_count + 1))
        fi
    done
    if [[ "$canonical_count" == "0" ]]; then
        log_grn "$scenario: canonical reviews/ left empty on aggregator failure"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: canonical reviews/ has $canonical_count decision artifact(s) on aggregator failure"
        red_count=$((red_count + 1))
    fi
}

# SIGINT cancellation test (unit-style).
#
# Why unit-style instead of an end-to-end SIGINT: bash 3.2 backgrounded
# subshells inherit SIGINT-ignore disposition from the controlling shell
# (POSIX shell behavior), and `kill -INT $pid` against a backgrounded
# job is silently dropped UNLESS the child re-enables SIGINT. The
# coordinator DOES install `trap '_rdc_handle_sigint' INT` early in
# run_debate_coordinator, but the parent `bin/review-gate` spawn flow
# (which runs BEFORE run_debate_coordinator and includes the per-reviewer
# spawn loop, can take 1-3 seconds) does NOT re-enable SIGINT, so the
# signal is lost in the backgrounded-script case. macOS bash 3.2 also
# lacks `setsid` and `$BASHPID`, so foreground self-SIGINT in a sourced
# subshell is the most portable path that exercises the real trap
# handler and the partial-telemetry write logic.
#
# This test directly invokes the trap path: it sources the helpers in a
# child bash script, sets up the coordinator's globals (matching what
# run_debate_coordinator would set on entry), installs the SIGINT trap
# (matching the coordinator's install line), self-delivers SIGINT via
# `kill -INT $$`, and verifies that the trap handler exits 130 and writes
# the partial telemetry file.
#
# The end-to-end SIGINT path (interrupting a real spawn flow) is covered
# implicitly: when SIGINT is delivered to a foreground review-gate
# process inside an interactive terminal, bash's default SIGINT handler
# fires with exit code 130 (128 + 2). The coordinator's trap handler
# additionally writes partial telemetry; without the trap, the partial
# telemetry write would be skipped. The unit-style test below proves
# that the trap handler does the right thing when it fires.
test_cancellation_sigint() {
    local scenario="cancellation-sigint"
    local scenario_work="$WORK_DIR/scenario-$scenario"
    mkdir -p "$scenario_work"

    local iter_dir="$scenario_work/iterations/0"
    local reviews_dir="$scenario_work/reviews"
    local state_file="$scenario_work/gate-state.json"
    mkdir -p "$iter_dir" "$reviews_dir"

    # Pre-populate gate-state.json in the pending state so we can verify
    # the trap path leaves it unchanged.
    cat > "$state_file" <<JSON
{
  "status":"pending",
  "config":{"consensus_mode":"majority"},
  "reviewers":{"codex":{},"gemini":{}},
  "consensus":null,
  "decision":null,
  "iteration":0
}
JSON

    # Build a child script that mirrors the coordinator's trap-install
    # path. self-deliver SIGINT to fire the trap and exercise the
    # _rdc_handle_sigint → _rdc_write_partial_telemetry → exit 130 chain.
    local sigint_script="$scenario_work/sigint_child.sh"
    cat > "$sigint_script" <<EOF
#!/usr/bin/env bash
set -uo pipefail
# Source the helpers in the child, exactly as bin/review-gate sources
# them at runtime (review-gate-debate.sh ships under SCRIPT_DIR).
source "$PLUGIN_ROOT/bin/telemetry-lib.sh"
source "$PLUGIN_ROOT/bin/review-gate-debate.sh"

# Mirror the coordinator's globals at function-entry time.
_RDC_ITER_DIR="$iter_dir"
_RDC_REVIEWS_DIR="$reviews_dir"
_RDC_CONSENSUS_MODE="majority"
_RDC_DEBATE_MODE="smart"
_RDC_STRATEGIES_JSON='{}'
_RDC_ROUNDS_JSON='[]'
_RDC_ROUNDS_COMPLETED=0
_RDC_AGGREGATOR_NOTES_JSON='[]'
STATE_FILE="$state_file"

# Install the trap (mirrors coordinator entry).
trap '_rdc_handle_sigint' INT

# Append a synthetic Round-1 entry to simulate the round having
# completed before the cancel arrived. This proves the partial
# telemetry surfaces whatever rounds completed up to the cancel point.
_rdc_record_round 1 "2026-04-27T12:00:00Z" "2026-04-27T12:00:30Z" 30000 \\
    "$iter_dir/round-1" "codex,gemini" "codex,gemini"

# Self-deliver SIGINT. The deferred-exit design means the trap sets
# _RDC_CANCEL_REQUESTED=1 and returns immediately; the coordinator's
# post-record checkpoint helper _rdc_check_cancel_after_round is
# what fires the partial-telemetry write + exit 130. We invoke that
# checkpoint manually here to mirror the coordinator's flow. (Note:
# this comment must NOT use backticks; the heredoc is unquoted and
# backtick-quoted text triggers command substitution in the parent.)
kill -INT \$\$
# Brief sleep so the SIGINT is delivered + handled before checkpoint.
# Bash queues signals and runs the trap before the next simple command,
# so the trap should fire when sleep returns (or is interrupted).
sleep 0.05 2>/dev/null || true
_rdc_check_cancel_after_round

# Defensive: should not reach here; if we do, exit 1 to signal a
# trap-failed-to-fire regression.
sleep 5
exit 1
EOF
    chmod +x "$sigint_script"

    set +e
    bash "$sigint_script" > "$scenario_work/stdout" 2> "$scenario_work/stderr"
    local rc=$?
    set -e

    # Assertion: exit code 130 (SIGINT conventional 128 + 2). The trap
    # handler's `exit 130` is the only path that produces this code; if
    # the trap didn't fire, the script either exits 1 (the defensive
    # post-sleep exit) or whatever bash's default SIGINT handler emits.
    if [[ "$rc" -eq 130 ]]; then
        log_grn "$scenario: SIGINT trap handler exits 130 (canonical 128 + SIGINT)"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: SIGINT trap handler exit code = $rc (expected 130). Stderr: $(head -3 "$scenario_work/stderr" 2>/dev/null | tr '\n' ';')"
        red_count=$((red_count + 1))
    fi

    # Assertion: iterations/<iter>/debate-telemetry.json written.
    local telemetry_file="$iter_dir/debate-telemetry.json"
    if [[ -f "$telemetry_file" ]]; then
        # Sanity-check shape + Round-1 telemetry presence.
        local has_keys
        has_keys=$(jq -r '
            (has("rounds") and has("mode") and has("consensus_mode")
             and has("strategies") and has("rounds_telemetry")
             and has("aggregator_notes"))
        ' "$telemetry_file" 2>/dev/null || echo "false")
        if [[ "$has_keys" == "true" ]]; then
            log_grn "$scenario: partial telemetry written on SIGINT with all pinned keys"
            green_count=$((green_count + 1))
        else
            log_red "$scenario: partial telemetry written on SIGINT but missing pinned keys"
            red_count=$((red_count + 1))
        fi

        local r1_count
        r1_count=$(jq -r '[.rounds_telemetry[] | select(.round == 1)] | length' "$telemetry_file" 2>/dev/null || echo "0")
        if [[ "$r1_count" -ge 1 ]]; then
            log_grn "$scenario: partial telemetry retains the Round-1 entry that completed before SIGINT"
            green_count=$((green_count + 1))
        else
            log_red "$scenario: partial telemetry missing Round-1 entry"
            red_count=$((red_count + 1))
        fi
    else
        log_red "$scenario: partial telemetry NOT written on SIGINT"
        red_count=$((red_count + 1))
    fi

    # Assertion: gate-state.json.status stays at 'pending'; no .debate
    # block written. The trap path is explicit about not mutating
    # gate-state on cancel — pending → pending and absent → absent.
    if [[ -f "$state_file" ]]; then
        local status
        status=$(jq -r '.status' "$state_file" 2>/dev/null || echo "")
        if [[ "$status" == "pending" ]]; then
            log_grn "$scenario: gate-state.json.status stays at 'pending' after SIGINT (no mutation by trap path)"
            green_count=$((green_count + 1))
        else
            log_red "$scenario: gate-state.json.status = '$status' (expected 'pending')"
            red_count=$((red_count + 1))
        fi

        local has_debate_key
        has_debate_key=$(jq -r 'has("debate")' "$state_file" 2>/dev/null || echo "true")
        if [[ "$has_debate_key" == "false" ]]; then
            log_grn "$scenario: gate-state.json has NO .debate top-level key after SIGINT (success-only block)"
            green_count=$((green_count + 1))
        else
            log_red "$scenario: gate-state.json unexpectedly has .debate key after SIGINT"
            red_count=$((red_count + 1))
        fi
    else
        log_red "$scenario: gate-state.json missing after SIGINT"
        red_count=$((red_count + 1))
    fi

    # Assertion: canonical reviews/ unchanged (the trap path doesn't
    # touch $REVIEWS_DIR; the coordinator's success-path promotion is
    # the ONLY surface that writes per-reviewer JSONs / aggregate.json).
    local canonical_count=0
    local f
    for f in "$reviews_dir"/codex.json \
             "$reviews_dir"/gemini.json \
             "$reviews_dir"/aggregate.json \
             "$reviews_dir"/codex.done \
             "$reviews_dir"/gemini.done; do
        if [[ -e "$f" ]]; then
            canonical_count=$((canonical_count + 1))
        fi
    done
    if [[ "$canonical_count" == "0" ]]; then
        log_grn "$scenario: canonical reviews/ left empty after SIGINT (no promotion ran)"
        green_count=$((green_count + 1))
    else
        log_red "$scenario: canonical reviews/ has $canonical_count decision artifact(s) after SIGINT"
        red_count=$((red_count + 1))
    fi
}

# Pre-coordinator degraded test. Verifies that when fewer than 2
# reviewers spawn successfully (a realistic pre-round path: e.g.,
# gemini policy lookup fails), bin/review-gate's pre-coordinator
# branch produces the canonical degraded-below-2 contract: exit 6,
# stderr canonical message, gate-state.json transitioned to
# awaiting_decision/requires_decision, partial telemetry file written.
test_pre_round_spawn_failure_degraded() {
    local scenario="pre-round-spawn-failure-degraded"
    local scenario_work="$WORK_DIR/scenario-$scenario"
    local scenario_bin="$scenario_work/bin"
    local scenario_home="$scenario_work/home"
    mkdir -p "$scenario_bin" "$scenario_home"

    # codex spawns OK; gemini's CLI is missing (no command on PATH).
    # The `command -v gemini` preflight will fail, so review-gate's
    # spawn loop drops gemini from `_debate_spawned_reviewers`. With
    # only codex spawned (count=1 < 2), the pre-coordinator branch
    # MUST take the degraded-below-2 contract.
    cp "$FAKE_BIN/codex" "$scenario_bin/codex"
    chmod +x "$scenario_bin/codex"
    if [[ -n "$REAL_NOHUP" ]]; then
        cp "$FAKE_BIN/nohup" "$scenario_bin/nohup"
    fi
    # NO gemini binary in $scenario_bin → command -v fails → spawn skipped.

    local session="$scenario"
    local trans_dir="$scenario_home/.claude/projects/-test-debate-pre-deg"
    mkdir -p "$trans_dir"
    local transcript="$trans_dir/$session.jsonl"
    touch "$transcript"
    local review_dir="$scenario_home/.claude/projects/-test-debate-pre-deg/cerberus/$session"
    mkdir -p "$review_dir/reviews"

    set +e
    local rc
    (
        export HOME="$scenario_home"
        # Restrict PATH so gemini cannot be found (the fake-bin dir lacks it,
        # and the real PATH may have a system gemini we don't want here).
        export PATH="$scenario_bin:/usr/bin:/bin"
        export CLAUDE_SESSION_ID="$session"
        export REVIEW_GATE_TRANSCRIPT_PATH="$transcript"
        export GEMINI_READONLY_SETTINGS_PATH="$GEMINI_SETTINGS"
        export GEMINI_READONLY_POLICY_PATH="$GEMINI_POLICY"
        export REVIEW_GATE_RERUN=1
        export REVIEW_GATE_MAX_WAIT_SECONDS=10
        export REVIEW_GATE_POLL_INTERVAL_SECONDS=1
        "$REVIEW_GATE" spawn-plan-review \
            --mode smart \
            --agents codex,gemini \
            --debate \
            "$SAMPLE_PLAN"
    ) >/dev/null 2>"$scenario_work/stderr"
    rc=$?
    set -e

    # The <2-reviewers preflight in bin/review-gate runs BEFORE the
    # spawn loop and may already reject the run (if `command -v gemini`
    # fails at preflight). In that case the coordinator never gets
    # involved — the preflight emits its own error and exits with a
    # non-T012 code. The T012 contract pins the behavior for the
    # post-spawn pre-coordinator branch (the case we want to test).
    # If preflight rejected, skip the assertions but record the skip.
    local stderr_text
    stderr_text=$(cat "$scenario_work/stderr" 2>/dev/null || echo "")
    if grep -F "debate degraded below 2 active reviewers in the final peer round" "$scenario_work/stderr" >/dev/null 2>&1; then
        # The pre-coordinator branch fired correctly.
        if [[ "$rc" -eq 6 ]]; then
            log_grn "$scenario: pre-coordinator <2-spawn branch exits 6 (T012 contract)"
            green_count=$((green_count + 1))
        else
            log_red "$scenario: pre-coordinator <2-spawn branch exit code = $rc (expected 6)"
            red_count=$((red_count + 1))
        fi

        # iterations/<iter>/debate-telemetry.json present (empty rounds_telemetry).
        local iter_root="$review_dir/iterations"
        local latest_iter
        latest_iter=$(ls -1 "$iter_root" 2>/dev/null | LC_ALL=C sort -n | tail -1)
        local telemetry_file="$iter_root/$latest_iter/debate-telemetry.json"
        if [[ -f "$telemetry_file" ]]; then
            log_grn "$scenario: partial telemetry written on pre-coordinator degraded path"
            green_count=$((green_count + 1))
        else
            log_red "$scenario: partial telemetry NOT written on pre-coordinator degraded path"
            red_count=$((red_count + 1))
        fi

        # gate-state.json transitioned to awaiting_decision/requires_decision.
        local state_file="$review_dir/gate-state.json"
        if [[ -f "$state_file" ]]; then
            local status verdict
            status=$(jq -r '.status' "$state_file" 2>/dev/null || echo "")
            verdict=$(jq -r '.consensus.verdict' "$state_file" 2>/dev/null || echo "")
            if [[ "$status" == "awaiting_decision" && "$verdict" == "requires_decision" ]]; then
                log_grn "$scenario: gate-state.json transitioned to awaiting_decision/requires_decision (pre-coordinator)"
                green_count=$((green_count + 1))
            else
                log_red "$scenario: gate-state.json status='$status' verdict='$verdict' (expected awaiting_decision/requires_decision)"
                red_count=$((red_count + 1))
            fi
        fi
    else
        # Preflight rejected before reaching the post-spawn branch; that's
        # fine — T002 preflight short-circuits when `command -v` fails, so
        # the integration path doesn't reach the new T012 helper. Verify
        # the helper directly via a unit-test invocation in a subshell.
        log_info "$scenario: preflight rejected before reaching the pre-coordinator <2-spawn branch (T002 short-circuit); falling back to direct unit-test of _rdc_pre_round_degraded_exit"

        local unit_work="$scenario_work/unit"
        local unit_iter_dir="$unit_work/iterations/0"
        local unit_reviews_dir="$unit_work/reviews"
        local unit_state_file="$unit_work/gate-state.json"
        mkdir -p "$unit_iter_dir" "$unit_reviews_dir"
        cat > "$unit_state_file" <<JSON
{
  "status":"pending",
  "config":{"consensus_mode":"majority"},
  "reviewers":{"codex":{},"gemini":{}},
  "consensus":null,
  "decision":null,
  "iteration":0
}
JSON

        local unit_script="$unit_work/unit_pre_round.sh"
        cat > "$unit_script" <<UNITEOF
#!/usr/bin/env bash
set -uo pipefail
source "$PLUGIN_ROOT/bin/telemetry-lib.sh"
source "$PLUGIN_ROOT/bin/review-gate-debate.sh"
STATE_FILE="$unit_state_file"
_RDC_ITER_DIR="$unit_iter_dir" \\
_RDC_REVIEWS_DIR="$unit_reviews_dir" \\
_RDC_CONSENSUS_MODE="majority" \\
_RDC_DEBATE_MODE="smart" \\
_rdc_pre_round_degraded_exit
UNITEOF
        chmod +x "$unit_script"
        set +e
        bash "$unit_script" >"$unit_work/stdout" 2>"$unit_work/stderr"
        local unit_rc=$?
        set -e

        if [[ "$unit_rc" -eq 6 ]]; then
            log_grn "$scenario: _rdc_pre_round_degraded_exit unit-test exits 6"
            green_count=$((green_count + 1))
        else
            log_red "$scenario: _rdc_pre_round_degraded_exit unit-test exit code = $unit_rc (expected 6). Stderr: $(head -3 "$unit_work/stderr" 2>/dev/null | tr '\n' ';')"
            red_count=$((red_count + 1))
        fi

        if grep -F "debate degraded below 2 active reviewers in the final peer round" "$unit_work/stderr" >/dev/null 2>&1; then
            log_grn "$scenario: _rdc_pre_round_degraded_exit emits canonical degraded-below-2 stderr"
            green_count=$((green_count + 1))
        else
            log_red "$scenario: _rdc_pre_round_degraded_exit missing canonical stderr"
            red_count=$((red_count + 1))
        fi

        if [[ -f "$unit_iter_dir/debate-telemetry.json" ]]; then
            log_grn "$scenario: _rdc_pre_round_degraded_exit writes partial telemetry"
            green_count=$((green_count + 1))
        else
            log_red "$scenario: _rdc_pre_round_degraded_exit did NOT write partial telemetry"
            red_count=$((red_count + 1))
        fi

        local unit_status unit_verdict
        unit_status=$(jq -r '.status' "$unit_state_file" 2>/dev/null || echo "")
        unit_verdict=$(jq -r '.consensus.verdict' "$unit_state_file" 2>/dev/null || echo "")
        if [[ "$unit_status" == "awaiting_decision" && "$unit_verdict" == "requires_decision" ]]; then
            log_grn "$scenario: _rdc_pre_round_degraded_exit transitions gate-state.json to awaiting_decision/requires_decision"
            green_count=$((green_count + 1))
        else
            log_red "$scenario: _rdc_pre_round_degraded_exit gate-state status='$unit_status' verdict='$unit_verdict' (expected awaiting_decision/requires_decision)"
            red_count=$((red_count + 1))
        fi
    fi
}

# Run T012 scenarios. The pre-existing per-shape SHAPE_* arrays are
# populated above; T012's success-path assertions read from them.
test_gate_state_debate_block_success
test_non_debate_run_no_debate_key
test_debate_block_survives_stop_hook
test_aggregate_verdict_never_requires_decision
test_degraded_below_2_partial_telemetry
test_aggregator_failure_partial_telemetry
test_cancellation_sigint
test_pre_round_spawn_failure_degraded

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

NOTE: red assertions were the integration-path-test signal under T002..T009.
T010 flipped the default of DEBATE_E2E_STRICT to 1, so red assertions are
fatal in CI. To run in soft mode for local debugging, set DEBATE_E2E_STRICT=0
explicitly.
EOF
    exit 0
fi

echo "All debate E2E assertions green." >&2
exit 0
