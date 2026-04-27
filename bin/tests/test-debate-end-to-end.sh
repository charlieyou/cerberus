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
# Pending-only log: assertions that are documented as a downstream task's
# scope (T011 wires gate-report rendering). Logged in yellow but do NOT
# count toward red_count, so STRICT mode does not fail on them.
log_pending() { echo -e "${YELLOW}PENDING (T011):${NC} $1" >&2; }

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
    # T011 (Phase F.1) wires the gate-report Strategy column. Per T010's
    # task spec, this assertion's pass/fail is "for T011 to verify", so
    # T010 reports it as PENDING (not RED) until T011 lands.
    if printf '%s' "$report" | grep -qE 'Strategy'; then
        log_grn "$shape: gate report contains Strategy column header"
        green_count=$((green_count + 1))
    else
        log_pending "$shape: gate report Strategy column not yet rendered (T011 owns Phase F.1)"
    fi
}

assert_debate_round_indicator() {
    local shape="$1"
    local report="$2"
    # T011/T012 (Phase F.1/F.2) wire the gate-report Debate-round
    # indicator. Same PENDING treatment as the Strategy column above.
    if printf '%s' "$report" | grep -qE 'Debate:[[:space:]]+round[[:space:]]+[0-9]+/[0-9]+'; then
        log_grn "$shape: gate report contains Debate round indicator"
        green_count=$((green_count + 1))
    else
        log_pending "$shape: gate report Debate-round indicator not yet rendered (T011/T012 own Phase F.1/F.2)"
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
