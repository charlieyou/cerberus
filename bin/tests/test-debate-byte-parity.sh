#!/usr/bin/env bash
# test-debate-byte-parity.sh
#
# T002 Phase B R9 byte-parity scaffold:
#
#   1. For each of the 5 invocation shapes, re-running the existing capture
#      machinery against post-feature `bin/review-gate` MUST produce
#      artifacts that are `cmp`-equal to the committed
#      `bin/tests/fixtures/pre-debate-baseline/` golden fixtures. The
#      assertion covers all artifact kinds the fixture directory holds:
#      CLI stdout/stderr, per-reviewer JSONs, schema, gate-state, prompts,
#      iteration.txt, gate-report markdown, and latest.md.
#   2. `--debate-seed N` passed without `--debate` MUST not change any
#      byte-parity-protected output (R9). We exercise this with the bare-spawn
#      shape: run twice, once with `--debate-seed 7` and once without; assert
#      `review.prompt` and `review-schema.json` are byte-identical.
#
# Strategy: this test invokes the existing
# `bin/tests/capture-pre-debate-baseline.sh` script with `--overwrite`. That
# script overwrites the canonical fixture directory with freshly-captured
# post-feature artifacts. We back up the committed fixtures to a temp
# directory FIRST, run the capture (which overwrites in place), `cmp` the new
# captures against the backup, then restore the committed fixtures from the
# backup (regardless of cmp outcome) via an EXIT trap.
#
# Subsequent tasks extend this file:
#   - T004 adds an anchor-cmp (R2/R10 byte-equality of the calibration anchor
#     block across the four reviewer templates).
#   - T006 adds debate-conditional schema variant assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REVIEW_GATE="$PLUGIN_ROOT/bin/review-gate"
CAPTURE_SCRIPT="$SCRIPT_DIR/capture-pre-debate-baseline.sh"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/pre-debate-baseline"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_test() { echo -e "${YELLOW}TEST:${NC} $1" >&2; }
log_pass() { echo -e "${GREEN}PASS:${NC} $1" >&2; }
log_fail() { echo -e "${RED}FAIL:${NC} $1" >&2; }
log_info() { echo -e "INFO: $1" >&2; }

if ! command -v jq >/dev/null 2>&1; then
    log_info "jq not available; skipping byte-parity tests"
    exit 0
fi

if [[ ! -d "$FIXTURE_DIR" ]] || [[ -z "$(ls -A "$FIXTURE_DIR" 2>/dev/null)" ]]; then
    log_info "Pre-debate baseline fixtures not present at $FIXTURE_DIR; skipping byte-parity tests"
    exit 0
fi

if [[ ! -x "$CAPTURE_SCRIPT" ]]; then
    log_info "Capture script $CAPTURE_SCRIPT not executable; skipping byte-parity tests"
    exit 0
fi

# The capture script needs all three reviewer CLIs to be SHADOWED via fake
# CLIs in the temp $PATH it constructs. It runs against the live `bin/review-gate`,
# so it requires that the host can run setsid/nohup. On hosts where one of
# these is missing (e.g., minimal CI) we skip rather than fail.
for required in jq git nohup; do
    if ! command -v "$required" >/dev/null 2>&1; then
        log_info "$required not available; skipping byte-parity tests"
        exit 0
    fi
done

# The capture script requires a specific pinned commit to exist in this repo.
# If we are in a worktree where that commit is unreachable, skip rather than
# fail (this can happen in shallow clones or detached worktrees).
PINNED_COMMIT="c4443c54796a362876c8a1b9e9a1603e0ffeb008"
if ! git -C "$PLUGIN_ROOT" cat-file -e "${PINNED_COMMIT}^{commit}" 2>/dev/null; then
    log_info "Pinned baseline commit $PINNED_COMMIT not reachable; skipping byte-parity tests"
    exit 0
fi

# ---------------------------------------------------------------------------
# Backup committed fixtures to a temp directory.
# ---------------------------------------------------------------------------
BACKUP_DIR="$(mktemp -d -t pre-debate-fixtures-backup.XXXXXX)"
log_info "Backing up committed fixtures to $BACKUP_DIR"
cp -R "$FIXTURE_DIR/." "$BACKUP_DIR/"

restore_fixtures() {
    # Restore committed fixtures from the backup, no matter how this test
    # exits. This is critical because the capture script overwrites
    # $FIXTURE_DIR in place.
    if [[ -n "${BACKUP_DIR:-}" && -d "$BACKUP_DIR" ]]; then
        rm -rf "$FIXTURE_DIR"
        mkdir -p "$FIXTURE_DIR"
        cp -R "$BACKUP_DIR/." "$FIXTURE_DIR/"
        rm -rf "$BACKUP_DIR"
    fi
}

trap 'restore_fixtures' EXIT INT TERM

# ---------------------------------------------------------------------------
# Run capture-pre-debate-baseline.sh --overwrite.
# This overwrites $FIXTURE_DIR with post-feature non-debate captures. The
# capture script runs all 5 invocation shapes against fake offline reviewers,
# so the output is reproducible and machine-independent (modulo the path /
# timestamp normalization the script applies internally).
# ---------------------------------------------------------------------------
log_info "Running capture-pre-debate-baseline.sh --overwrite (writes to $FIXTURE_DIR)"
CAPTURE_LOG="$(mktemp -t capture-rerun.XXXXXX)"
if ! bash "$CAPTURE_SCRIPT" --overwrite >"$CAPTURE_LOG" 2>&1; then
    log_fail "capture-pre-debate-baseline.sh --overwrite failed; see $CAPTURE_LOG"
    cat "$CAPTURE_LOG" >&2
    rm -f "$CAPTURE_LOG"
    exit 1
fi
rm -f "$CAPTURE_LOG"

# ---------------------------------------------------------------------------
# cmp every committed artifact against the freshly-captured equivalent.
# The capture script normalizes WORK_DIR, PLUGIN_ROOT, timestamps, and SHAs,
# so byte-equality is the right assertion: any drift indicates the post-feature
# code path has changed something unintentionally for non-debate runs.
# ---------------------------------------------------------------------------
SHAPES=(spawn-code-review spawn-plan-review spawn-spec-review spawn-epic-verify spawn-bare)
ARTIFACTS=(
    "reviews/review.prompt"
    "reviews/review-schema.json"
    "reviews/codex.json"
    "reviews/gemini.json"
    "reviews/claude.json"
    "gate-state.json"
    "iteration.txt"
    "latest.md"
    "spawn-stdout.txt"
    "spawn-stderr.txt"
    "gate-report.md"
)

pass_count=0
fail_count=0

for shape in "${SHAPES[@]}"; do
    for relpath in "${ARTIFACTS[@]}"; do
        committed="$BACKUP_DIR/$shape/$relpath"
        captured="$FIXTURE_DIR/$shape/$relpath"

        if [[ ! -f "$committed" ]]; then
            # The committed fixture for this artifact does not exist (some
            # shapes legitimately omit some artifacts; e.g., spawn-bare
            # captures latest.md from the artifact-only path). Skip without
            # logging a pass or fail.
            continue
        fi

        log_test "byte-parity: $shape/$relpath"
        if [[ ! -f "$captured" ]]; then
            log_fail "$shape/$relpath: post-feature capture missing"
            fail_count=$((fail_count + 1))
            continue
        fi

        if cmp -s "$committed" "$captured"; then
            log_pass "$shape/$relpath byte-identical"
            pass_count=$((pass_count + 1))
        else
            log_fail "$shape/$relpath: byte-parity violated"
            diff -u "$committed" "$captured" 2>/dev/null | head -80 >&2 || true
            fail_count=$((fail_count + 1))
        fi
    done
done

# ---------------------------------------------------------------------------
# --debate-seed no-op assertion.
# Run a minimal bare-spawn capture twice — once without --debate-seed, once
# with --debate-seed 7 — and assert that review.prompt and review-schema.json
# are byte-identical. These are the most likely artifacts to drift if a stray
# --debate-seed code path leaked into the non-debate prompt or schema build.
#
# We re-use the SAME fake-CLI / fake-HOME machinery as the capture script,
# but run it inline against a temp output directory so we don't have to
# trample $FIXTURE_DIR a second time. The implementation here is deliberately
# minimal — full coverage is the responsibility of the capture-script-driven
# 5-shape sweep above.
# ---------------------------------------------------------------------------
DEBATE_SEED_WORK="$(mktemp -d -t debate-seed-noop.XXXXXX)"
DEBATE_SEED_FAKE_HOME="$DEBATE_SEED_WORK/home"
DEBATE_SEED_FAKE_BIN="$DEBATE_SEED_WORK/bin"
mkdir -p "$DEBATE_SEED_FAKE_HOME" "$DEBATE_SEED_FAKE_BIN"

# Fake reviewer CLIs (canned offline). These mirror the capture script's
# fakes: deterministic PASS verdicts, no network. Real `nohup` is used.
cat > "$DEBATE_SEED_FAKE_BIN/codex" <<'CODEX'
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

cat > "$DEBATE_SEED_FAKE_BIN/gemini" <<'GEMINI'
#!/usr/bin/env bash
printf '{"verdict":"PASS","summary":"Canned fixture: all criteria met.","findings":[]}\n'
exit 0
GEMINI

cat > "$DEBATE_SEED_FAKE_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
result_json='{"verdict":"PASS","summary":"Canned fixture: all criteria met.","findings":[]}'
escaped=$(printf '%s' "$result_json" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"session_id":"fixture-session","result":"%s","tokens":{"input":100,"output":50,"cached":0},"duration_ms":100,"total_cost_usd":0.0001}\n' "$escaped"
exit 0
CLAUDE

REAL_NOHUP="$(command -v nohup 2>/dev/null || true)"
if [[ -n "$REAL_NOHUP" ]]; then
    cat > "$DEBATE_SEED_FAKE_BIN/nohup" <<NOHUP_WRAPPER
#!/usr/bin/env bash
exec "$REAL_NOHUP" "\$@"
NOHUP_WRAPPER
    chmod +x "$DEBATE_SEED_FAKE_BIN/nohup"
fi
chmod +x "$DEBATE_SEED_FAKE_BIN/codex" \
         "$DEBATE_SEED_FAKE_BIN/gemini" \
         "$DEBATE_SEED_FAKE_BIN/claude"

GEMINI_SETTINGS="$PLUGIN_ROOT/config/gemini-readonly-settings.json"
GEMINI_POLICY="$PLUGIN_ROOT/config/gemini-readonly-policy.toml"

# Run a single bare-spawn shape and write the rendered review.prompt and
# review-schema.json into $1. Returns 0 on success.
#
# Uses a FIXED session id so review.prompt's embedded artifact-path is the
# same across runs. The second invocation must set REVIEW_GATE_RERUN=1 to
# bypass the active-gate guard.
run_one_seed_shape() {
    local out_dir="$1"
    shift
    local extra_args=("$@")

    local session="seed-noop-fixed"
    local trans_dir="$DEBATE_SEED_FAKE_HOME/.claude/projects/-debate-seed-noop"
    mkdir -p "$trans_dir"
    local transcript="$trans_dir/$session.jsonl"
    touch "$transcript"

    local review_dir="$DEBATE_SEED_FAKE_HOME/.claude/projects/-debate-seed-noop/cerberus/$session"
    # Wipe per-run state (the previous invocation's reviews/, gate-state,
    # and iteration counter) so the second run sees a clean slate. We
    # explicitly preserve the directory itself.
    rm -rf "$review_dir/reviews" "$review_dir/reviews-iter-"* \
           "$review_dir/gate-state.json" "$review_dir/iteration.txt"
    mkdir -p "$review_dir"

    local artifact="$review_dir/latest.md"
    cat > "$artifact" <<'ART'
<!-- review-type: code -->
<!-- diff-args: --uncommitted -->
<!-- mode: smart -->

# Code Review (Iterative)

## Diff Mode
--uncommitted

## Changes

```diff
diff --git a/bin/tests/fixtures/pre-debate-baseline/.gitkeep b/bin/tests/fixtures/pre-debate-baseline/.gitkeep
new file mode 100644
index 0000000..e69de29
--- /dev/null
+++ b/bin/tests/fixtures/pre-debate-baseline/.gitkeep
```
ART

    local stdout_file="$DEBATE_SEED_WORK/${session}.stdout"
    local stderr_file="$DEBATE_SEED_WORK/${session}.stderr"
    local spawn_args=(
        spawn
        --type code
        --mode smart
        --agents codex,gemini,claude
    )
    if [[ ${#extra_args[@]} -gt 0 ]]; then
        spawn_args+=("${extra_args[@]}")
    fi
    spawn_args+=("$artifact")

    set +e
    (
        export HOME="$DEBATE_SEED_FAKE_HOME"
        export PATH="$DEBATE_SEED_FAKE_BIN:$PATH"
        export CLAUDE_SESSION_ID="$session"
        export REVIEW_GATE_TRANSCRIPT_PATH="$transcript"
        export GEMINI_READONLY_SETTINGS_PATH="$GEMINI_SETTINGS"
        export GEMINI_READONLY_POLICY_PATH="$GEMINI_POLICY"
        export REVIEW_GATE_MAX_ROUNDS=3
        export REVIEW_GATE_RERUN=1
        "$REVIEW_GATE" "${spawn_args[@]}"
    ) >"$stdout_file" 2>"$stderr_file"
    local rc=$?
    set -e

    if [[ $rc -ne 0 ]]; then
        log_info "spawn exited $rc; stderr follows:"
        cat "$stderr_file" >&2
        return 1
    fi

    # Wait briefly for the spawn to finish writing the prompt + schema files
    # (the detached reviewer processes write later, but those artifacts are
    # synchronous before the spawn's own exit).
    if [[ ! -f "$review_dir/reviews/review.prompt" ]]; then
        log_info "review.prompt missing after spawn"
        return 1
    fi
    if [[ ! -f "$review_dir/reviews/review-schema.json" ]]; then
        log_info "review-schema.json missing after spawn"
        return 1
    fi

    mkdir -p "$out_dir"
    cp "$review_dir/reviews/review.prompt" "$out_dir/review.prompt"
    cp "$review_dir/reviews/review-schema.json" "$out_dir/review-schema.json"
    return 0
}

DEBATE_SEED_RUN_A="$DEBATE_SEED_WORK/run-a"
DEBATE_SEED_RUN_B="$DEBATE_SEED_WORK/run-b"

log_info "running --debate-seed no-op pair (run A: no --debate-seed)"
if ! run_one_seed_shape "$DEBATE_SEED_RUN_A"; then
    log_fail "--debate-seed run A (no flag) failed to produce expected artifacts"
    fail_count=$((fail_count + 1))
fi

log_info "running --debate-seed no-op pair (run B: --debate-seed 7)"
if ! run_one_seed_shape "$DEBATE_SEED_RUN_B" --debate-seed 7; then
    log_fail "--debate-seed run B (--debate-seed 7) failed to produce expected artifacts"
    fail_count=$((fail_count + 1))
fi

if [[ -f "$DEBATE_SEED_RUN_A/review.prompt" && -f "$DEBATE_SEED_RUN_B/review.prompt" ]]; then
    log_test "byte-parity: --debate-seed 7 (no --debate) does not change review.prompt"
    if cmp -s "$DEBATE_SEED_RUN_A/review.prompt" "$DEBATE_SEED_RUN_B/review.prompt"; then
        log_pass "--debate-seed 7 review.prompt byte-identical to no-flag run"
        pass_count=$((pass_count + 1))
    else
        log_fail "--debate-seed 7 perturbed review.prompt"
        diff -u "$DEBATE_SEED_RUN_A/review.prompt" "$DEBATE_SEED_RUN_B/review.prompt" | head -60 >&2 || true
        fail_count=$((fail_count + 1))
    fi
fi

if [[ -f "$DEBATE_SEED_RUN_A/review-schema.json" && -f "$DEBATE_SEED_RUN_B/review-schema.json" ]]; then
    log_test "byte-parity: --debate-seed 7 (no --debate) does not change review-schema.json"
    if cmp -s "$DEBATE_SEED_RUN_A/review-schema.json" "$DEBATE_SEED_RUN_B/review-schema.json"; then
        log_pass "--debate-seed 7 review-schema.json byte-identical to no-flag run"
        pass_count=$((pass_count + 1))
    else
        log_fail "--debate-seed 7 perturbed review-schema.json"
        diff -u "$DEBATE_SEED_RUN_A/review-schema.json" "$DEBATE_SEED_RUN_B/review-schema.json" | head -60 >&2 || true
        fail_count=$((fail_count + 1))
    fi
fi

rm -rf "$DEBATE_SEED_WORK"

# ---------------------------------------------------------------------------
# T004 R2/R10 anchor + strategy byte-equality assertions.
#
# Renders each of the four reviewer templates under --debate via the
# bare-spawn path (which goes through build_prompt → resolve_template and
# then through the substitute_debate_placeholders pipe). Asserts that the
# rendered prompt contains the canonical anchor bytes
# (prompts/strategies/confidence-anchors.md) and the canonical strategy
# directive bytes (prompts/strategies/verification-first.md, the T004
# pre-T005-assignment default) as contiguous byte substrings.
#
# Cross-template byte-equality follows transitively: every template's render
# embeds the same source-file bytes, so the extracted region is byte-equal
# across all four templates by transitivity to the source.
# ---------------------------------------------------------------------------
ANCHORS_PATH="$PLUGIN_ROOT/prompts/strategies/confidence-anchors.md"
STRATEGY_PATH="$PLUGIN_ROOT/prompts/strategies/verification-first.md"

if [[ ! -f "$ANCHORS_PATH" ]] || [[ ! -f "$STRATEGY_PATH" ]]; then
    log_info "Strategy asset files missing under $PLUGIN_ROOT/prompts/strategies/; skipping R2/R10 anchor byte-equality tests"
else
    DEBATE_RENDER_WORK="$(mktemp -d -t debate-render.XXXXXX)"
    DEBATE_RENDER_FAKE_HOME="$DEBATE_RENDER_WORK/home"
    DEBATE_RENDER_FAKE_BIN="$DEBATE_RENDER_WORK/bin"
    mkdir -p "$DEBATE_RENDER_FAKE_HOME" "$DEBATE_RENDER_FAKE_BIN"

    # Fake reviewer CLIs so the --debate preflight (>=2 available reviewers)
    # passes without requiring real codex/gemini/claude on the host.
    cat > "$DEBATE_RENDER_FAKE_BIN/codex" <<'CODEX_DEBATE'
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
CODEX_DEBATE

    cat > "$DEBATE_RENDER_FAKE_BIN/gemini" <<'GEMINI_DEBATE'
#!/usr/bin/env bash
printf '{"verdict":"PASS","summary":"Canned fixture: all criteria met.","findings":[]}\n'
exit 0
GEMINI_DEBATE

    cat > "$DEBATE_RENDER_FAKE_BIN/claude" <<'CLAUDE_DEBATE'
#!/usr/bin/env bash
result_json='{"verdict":"PASS","summary":"Canned fixture: all criteria met.","findings":[]}'
escaped=$(printf '%s' "$result_json" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"session_id":"fixture-session","result":"%s","tokens":{"input":100,"output":50,"cached":0},"duration_ms":100,"total_cost_usd":0.0001}\n' "$escaped"
exit 0
CLAUDE_DEBATE

    REAL_NOHUP_DEBATE="$(command -v nohup 2>/dev/null || true)"
    if [[ -n "$REAL_NOHUP_DEBATE" ]]; then
        cat > "$DEBATE_RENDER_FAKE_BIN/nohup" <<NOHUP_DEBATE
#!/usr/bin/env bash
exec "$REAL_NOHUP_DEBATE" "\$@"
NOHUP_DEBATE
        chmod +x "$DEBATE_RENDER_FAKE_BIN/nohup"
    fi
    chmod +x "$DEBATE_RENDER_FAKE_BIN/codex" \
             "$DEBATE_RENDER_FAKE_BIN/gemini" \
             "$DEBATE_RENDER_FAKE_BIN/claude"

    GEMINI_SETTINGS_DEBATE="$PLUGIN_ROOT/config/gemini-readonly-settings.json"
    GEMINI_POLICY_DEBATE="$PLUGIN_ROOT/config/gemini-readonly-policy.toml"

    # Returns 0 if the bytes of $2 appear as a contiguous substring in $1.
    #
    # Reads both files in one shot via awk's RS="\0" (whole-file slurp,
    # since neither file contains NUL bytes) so the haystack and needle
    # are each a single record. This avoids the O(N^2) line-by-line
    # concatenation pattern and keeps the substring check O(N+M) on
    # awk implementations that use Boyer-Moore-style index() (mawk, gawk).
    file_contains_bytes_of() {
        local haystack_file="$1"
        local needle_file="$2"
        awk -v RS='\0' -v needle_file="$needle_file" '
            BEGIN {
                if ((getline needle < needle_file) <= 0) needle = ""
                close(needle_file)
            }
            {
                if (index($0, needle) > 0) { found = 1; exit }
            }
            END { exit (found ? 0 : 1) }
        ' "$haystack_file"
    }

    # Renders one reviewer template under --debate via bare-spawn. The bare
    # spawn path goes through build_prompt → resolve_template, which embeds
    # the literal template content (including the four T004 placeholders)
    # into the wrapper prompt. The substitute_debate_placeholders pipe in
    # bin/review-gate replaces the placeholders with canonical anchor +
    # strategy bytes. The rendered prompt is copied to $out_dir/review.prompt.
    render_under_debate() {
        local review_type="$1"
        local out_dir="$2"

        local session="debate-render-$review_type"
        local trans_dir="$DEBATE_RENDER_FAKE_HOME/.claude/projects/-debate-render"
        mkdir -p "$trans_dir"
        local transcript="$trans_dir/$session.jsonl"
        touch "$transcript"

        local review_dir="$DEBATE_RENDER_FAKE_HOME/.claude/projects/-debate-render/cerberus/$session"
        rm -rf "$review_dir"
        mkdir -p "$review_dir"

        local artifact="$review_dir/latest.md"
        printf 'Minimal artifact for T004 R2/R10 byte-equality test (--debate render of type %s).\n' "$review_type" > "$artifact"

        local stdout_file="$DEBATE_RENDER_WORK/${session}.stdout"
        local stderr_file="$DEBATE_RENDER_WORK/${session}.stderr"

        set +e
        (
            export HOME="$DEBATE_RENDER_FAKE_HOME"
            export PATH="$DEBATE_RENDER_FAKE_BIN:$PATH"
            export CLAUDE_SESSION_ID="$session"
            export REVIEW_GATE_TRANSCRIPT_PATH="$transcript"
            export GEMINI_READONLY_SETTINGS_PATH="$GEMINI_SETTINGS_DEBATE"
            export GEMINI_READONLY_POLICY_PATH="$GEMINI_POLICY_DEBATE"
            export REVIEW_GATE_MAX_ROUNDS=3
            "$REVIEW_GATE" spawn \
                --type "$review_type" \
                --debate \
                --mode smart \
                --agents codex,gemini,claude \
                "$artifact"
        ) >"$stdout_file" 2>"$stderr_file"
        local rc=$?
        set -e

        if [[ $rc -ne 0 ]]; then
            log_info "spawn under --debate exited $rc for type=$review_type; stderr follows:"
            cat "$stderr_file" >&2
            return 1
        fi

        if [[ ! -f "$review_dir/reviews/review.prompt" ]]; then
            log_info "review.prompt missing after --debate spawn for type=$review_type"
            return 1
        fi

        mkdir -p "$out_dir"
        cp "$review_dir/reviews/review.prompt" "$out_dir/review.prompt"
        return 0
    }

    for type in code plan spec epic-verify; do
        render_dir="$DEBATE_RENDER_WORK/render-$type"
        mkdir -p "$render_dir"
        if ! render_under_debate "$type" "$render_dir"; then
            log_fail "R2/R10 render-under-debate failed for type=$type"
            fail_count=$((fail_count + 2))
            continue
        fi

        rendered="$render_dir/review.prompt"

        log_test "R2 anchor byte-equality: $type rendered prompt contains canonical confidence-anchors.md bytes"
        if file_contains_bytes_of "$rendered" "$ANCHORS_PATH"; then
            log_pass "$type rendered prompt contains canonical anchor block bytes (R2)"
            pass_count=$((pass_count + 1))
        else
            log_fail "$type rendered prompt does NOT contain canonical anchor block bytes (R2)"
            fail_count=$((fail_count + 1))
        fi

        log_test "R10 strategy byte-equality: $type rendered prompt contains canonical verification-first.md bytes"
        if file_contains_bytes_of "$rendered" "$STRATEGY_PATH"; then
            log_pass "$type rendered prompt contains canonical strategy directive bytes (R10)"
            pass_count=$((pass_count + 1))
        else
            log_fail "$type rendered prompt does NOT contain canonical strategy directive bytes (R10)"
            fail_count=$((fail_count + 1))
        fi
    done

    # -----------------------------------------------------------------------
    # Regression guard: artifact bytes that happen to look like the four
    # debate-mode placeholders MUST NOT be stripped or rewritten by the
    # substitution. The substitute_debate_placeholders pass runs against
    # the TEMPLATE only, before artifact content is merged in, so a diff
    # (or any artifact text) containing literal `${CONFIDENCE_ANCHORS}` etc.
    # round-trips intact.
    # -----------------------------------------------------------------------
    log_test "Finding-1 regression: artifact bytes resembling placeholders survive --debate render"

    REGRESSION_SESSION="debate-render-regression"
    REGRESSION_REVIEW_DIR="$DEBATE_RENDER_FAKE_HOME/.claude/projects/-debate-render/cerberus/$REGRESSION_SESSION"
    rm -rf "$REGRESSION_REVIEW_DIR"
    mkdir -p "$REGRESSION_REVIEW_DIR"
    REGRESSION_TRANS="$DEBATE_RENDER_FAKE_HOME/.claude/projects/-debate-render/$REGRESSION_SESSION.jsonl"
    touch "$REGRESSION_TRANS"

    REGRESSION_ARTIFACT="$REGRESSION_REVIEW_DIR/latest.md"
    cat > "$REGRESSION_ARTIFACT" <<'REGRESSION_ART'
This artifact intentionally contains all four debate placeholder lines as
literal artifact bytes. The substitute_debate_placeholders pass must NOT
touch any of these lines, because it runs on the template alone.
${CONFIDENCE_ANCHORS}
${STRATEGY_DIRECTIVE}
${PEER_BLOCK}
${PRIOR_ROUND_SELF_BLOCK}
End of artifact body.
REGRESSION_ART

    REGRESSION_STDOUT="$DEBATE_RENDER_WORK/${REGRESSION_SESSION}.stdout"
    REGRESSION_STDERR="$DEBATE_RENDER_WORK/${REGRESSION_SESSION}.stderr"
    set +e
    (
        export HOME="$DEBATE_RENDER_FAKE_HOME"
        export PATH="$DEBATE_RENDER_FAKE_BIN:$PATH"
        export CLAUDE_SESSION_ID="$REGRESSION_SESSION"
        export REVIEW_GATE_TRANSCRIPT_PATH="$REGRESSION_TRANS"
        export GEMINI_READONLY_SETTINGS_PATH="$GEMINI_SETTINGS_DEBATE"
        export GEMINI_READONLY_POLICY_PATH="$GEMINI_POLICY_DEBATE"
        export REVIEW_GATE_MAX_ROUNDS=3
        "$REVIEW_GATE" spawn \
            --type code \
            --debate \
            --mode smart \
            --agents codex,gemini,claude \
            "$REGRESSION_ARTIFACT"
    ) >"$REGRESSION_STDOUT" 2>"$REGRESSION_STDERR"
    REGRESSION_RC=$?
    set -e

    REGRESSION_PROMPT="$REGRESSION_REVIEW_DIR/reviews/review.prompt"
    if [[ $REGRESSION_RC -ne 0 || ! -f "$REGRESSION_PROMPT" ]]; then
        log_fail "regression spawn failed (rc=$REGRESSION_RC); cannot validate finding-1 fix"
        cat "$REGRESSION_STDERR" >&2 2>/dev/null || true
        fail_count=$((fail_count + 1))
    else
        regression_ok=1
        for placeholder in 'CONFIDENCE_ANCHORS' 'STRATEGY_DIRECTIVE' 'PEER_BLOCK' 'PRIOR_ROUND_SELF_BLOCK'; do
            if ! grep -F "\${$placeholder}" "$REGRESSION_PROMPT" >/dev/null; then
                log_fail "Finding-1 regression: artifact's literal \${$placeholder} line was stripped"
                regression_ok=0
            fi
        done
        if [[ $regression_ok -eq 1 ]]; then
            log_pass "all four artifact placeholder-looking lines survive --debate render"
            pass_count=$((pass_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    fi

    rm -rf "$DEBATE_RENDER_WORK"
fi

# ---------------------------------------------------------------------------
# T006 R9 schema-variant assertions
#
# The schema bytes written to `$REVIEWS_DIR/review-schema.json` (and the
# fallback bytes returned by `default_review_schema()` for the repair path)
# MUST be byte-identical to the pre-feature schema when --debate is absent
# (covered by the byte-parity sweep above) AND MUST add the additive debate
# fields (overall_confidence, strategy, round, peer_responses_seen at the top
# level; confidence inside findings[*]) when --debate is set, while retaining
# `additionalProperties: false` on both objects.
#
# These assertions are unit-style on the helper functions in
# bin/review-gate-models.sh; the runtime end-to-end flow is covered separately
# by bin/tests/test-debate-end-to-end.sh.
# ---------------------------------------------------------------------------
echo "" >&2

SCHEMA_TEST_TMP="$(mktemp -d -t debate-schema-variant.XXXXXX)"
schema_cleanup() { rm -rf "$SCHEMA_TEST_TMP"; }
trap 'restore_fixtures; schema_cleanup' EXIT INT TERM

# Source review-gate-models.sh into a subshell so default_review_schema /
# _emit_review_schema are callable in the test. The library defines a
# `die()` shim if needed; we do not invoke any code path that requires it.
RG_MODELS_LIB="$PLUGIN_ROOT/bin/review-gate-models.sh"

if [[ ! -f "$RG_MODELS_LIB" ]]; then
    log_info "review-gate-models.sh missing; skipping R9 schema-variant assertions"
else
    # Capture the canonical pre-feature schema bytes from a committed fixture
    # (the spawn-bare shape's review-schema.json is the canonical reference).
    BASELINE_SCHEMA="$BACKUP_DIR/spawn-bare/reviews/review-schema.json"

    if [[ ! -f "$BASELINE_SCHEMA" ]]; then
        log_info "Pre-feature schema baseline missing under $BACKUP_DIR; skipping R9 schema-variant assertions"
    else
        log_test "R9 schema variant: default_review_schema() with no arg / no env emits pre-feature bytes"
        non_debate_emit_a="$SCHEMA_TEST_TMP/non-debate-default.json"
        (
            unset REVIEW_GATE_DEBATE
            # shellcheck disable=SC1090
            source "$RG_MODELS_LIB"
            default_review_schema
        ) > "$non_debate_emit_a"
        if cmp -s "$BASELINE_SCHEMA" "$non_debate_emit_a"; then
            log_pass "default_review_schema() with no arg/env is byte-identical to baseline"
            pass_count=$((pass_count + 1))
        else
            log_fail "default_review_schema() with no arg/env drifted from baseline"
            diff -u "$BASELINE_SCHEMA" "$non_debate_emit_a" 2>/dev/null | head -40 >&2 || true
            fail_count=$((fail_count + 1))
        fi

        log_test 'R9 schema variant: _emit_review_schema "false" is byte-identical to baseline'
        non_debate_emit_b="$SCHEMA_TEST_TMP/non-debate-explicit.json"
        (
            # shellcheck disable=SC1090
            source "$RG_MODELS_LIB"
            _emit_review_schema "false"
        ) > "$non_debate_emit_b"
        if cmp -s "$BASELINE_SCHEMA" "$non_debate_emit_b"; then
            log_pass '_emit_review_schema "false" byte-identical to baseline'
            pass_count=$((pass_count + 1))
        else
            log_fail '_emit_review_schema "false" drifted from baseline'
            diff -u "$BASELINE_SCHEMA" "$non_debate_emit_b" 2>/dev/null | head -40 >&2 || true
            fail_count=$((fail_count + 1))
        fi

        log_test "R9 schema variant: REVIEW_GATE_DEBATE env override emits pre-feature bytes when set to 0"
        non_debate_emit_c="$SCHEMA_TEST_TMP/non-debate-env-zero.json"
        (
            export REVIEW_GATE_DEBATE=0
            # shellcheck disable=SC1090
            source "$RG_MODELS_LIB"
            default_review_schema
        ) > "$non_debate_emit_c"
        if cmp -s "$BASELINE_SCHEMA" "$non_debate_emit_c"; then
            log_pass "default_review_schema() with REVIEW_GATE_DEBATE=0 is byte-identical to baseline"
            pass_count=$((pass_count + 1))
        else
            log_fail "default_review_schema() with REVIEW_GATE_DEBATE=0 drifted from baseline"
            fail_count=$((fail_count + 1))
        fi

        log_test 'R9 schema variant: _emit_review_schema "true" admits the additive debate fields'
        debate_emit="$SCHEMA_TEST_TMP/debate-explicit.json"
        (
            # shellcheck disable=SC1090
            source "$RG_MODELS_LIB"
            _emit_review_schema "true"
        ) > "$debate_emit"
        if jq -e . "$debate_emit" >/dev/null 2>&1; then
            debate_ok=1
            # additionalProperties: false retained at top level + findings.items.
            top_addl=$(jq -r '.additionalProperties' "$debate_emit")
            findings_addl=$(jq -r '.properties.findings.items.additionalProperties' "$debate_emit")
            if [[ "$top_addl" != "false" ]]; then
                log_fail "debate variant top-level additionalProperties != false (got: $top_addl)"
                debate_ok=0
            fi
            if [[ "$findings_addl" != "false" ]]; then
                log_fail "debate variant findings[*] additionalProperties != false (got: $findings_addl)"
                debate_ok=0
            fi
            # Top-level additive fields present (as optional, NOT required).
            for f in overall_confidence strategy round peer_responses_seen; do
                present=$(jq --arg n "$f" 'if .properties[$n] then "yes" else "no" end' "$debate_emit")
                if [[ "$present" != '"yes"' ]]; then
                    log_fail "debate variant missing top-level optional property: $f"
                    debate_ok=0
                fi
                in_required=$(jq --arg n "$f" '(.required // []) | index($n) | if . == null then "no" else "yes" end' "$debate_emit")
                if [[ "$in_required" != '"no"' ]]; then
                    log_fail "debate variant: $f appears in required[] but should be optional"
                    debate_ok=0
                fi
            done
            # findings[*].confidence present as optional.
            f_conf=$(jq 'if .properties.findings.items.properties.confidence then "yes" else "no" end' "$debate_emit")
            if [[ "$f_conf" != '"yes"' ]]; then
                log_fail "debate variant missing findings[*].confidence optional property"
                debate_ok=0
            fi
            f_conf_required=$(jq '(.properties.findings.items.required // []) | index("confidence") | if . == null then "no" else "yes" end' "$debate_emit")
            if [[ "$f_conf_required" != '"no"' ]]; then
                log_fail "debate variant: findings[*].confidence appears in required[] but should be optional"
                debate_ok=0
            fi
            # The three pre-feature required top-level keys are still required.
            for f in verdict summary findings; do
                in_required=$(jq --arg n "$f" '(.required // []) | index($n) | if . == null then "no" else "yes" end' "$debate_emit")
                if [[ "$in_required" != '"yes"' ]]; then
                    log_fail "debate variant: pre-feature required key '$f' is no longer required"
                    debate_ok=0
                fi
            done
            if [[ $debate_ok -eq 1 ]]; then
                log_pass "debate variant has additive fields as optional, additionalProperties:false retained"
                pass_count=$((pass_count + 1))
            else
                fail_count=$((fail_count + 1))
            fi
        else
            log_fail "debate variant is not valid JSON"
            cat "$debate_emit" >&2
            fail_count=$((fail_count + 1))
        fi

        log_test "R9 schema variant: REVIEW_GATE_DEBATE=1 env causes default_review_schema() to emit debate variant"
        debate_emit_env="$SCHEMA_TEST_TMP/debate-env.json"
        (
            export REVIEW_GATE_DEBATE=1
            # shellcheck disable=SC1090
            source "$RG_MODELS_LIB"
            default_review_schema
        ) > "$debate_emit_env"
        # The two debate-variant emissions must be byte-identical.
        if cmp -s "$debate_emit" "$debate_emit_env"; then
            log_pass "REVIEW_GATE_DEBATE=1 emits the same debate variant as explicit arg"
            pass_count=$((pass_count + 1))
        else
            log_fail "REVIEW_GATE_DEBATE=1 emission diverges from explicit \"true\" arg"
            diff -u "$debate_emit" "$debate_emit_env" 2>/dev/null | head -40 >&2 || true
            fail_count=$((fail_count + 1))
        fi

        log_test "R9 schema variant: debate variant is NOT byte-identical to baseline"
        if cmp -s "$BASELINE_SCHEMA" "$debate_emit"; then
            log_fail "debate variant matched baseline; expected divergence (additive fields should differ)"
            fail_count=$((fail_count + 1))
        else
            log_pass "debate variant correctly differs from baseline"
            pass_count=$((pass_count + 1))
        fi

        # Repair-prompt schema selection: the schema_text fed into the repair
        # prompt builder MUST match the conditional. We exercise the source
        # of truth (default_review_schema) the same way repair_review_output
        # does when no schema_file is on disk.
        log_test "R9 schema variant: repair-path fallback under REVIEW_GATE_DEBATE=1 picks debate variant"
        repair_under_debate="$SCHEMA_TEST_TMP/repair-debate.json"
        (
            export REVIEW_GATE_DEBATE=1
            # shellcheck disable=SC1090
            source "$RG_MODELS_LIB"
            # Mirrors repair_review_output's exact fallback: schema_text=$(default_review_schema)
            default_review_schema
        ) > "$repair_under_debate"
        if cmp -s "$repair_under_debate" "$debate_emit"; then
            log_pass "repair-path fallback emits debate variant under REVIEW_GATE_DEBATE=1"
            pass_count=$((pass_count + 1))
        else
            log_fail "repair-path fallback diverges from debate variant under REVIEW_GATE_DEBATE=1"
            fail_count=$((fail_count + 1))
        fi

        log_test "R9 schema variant: repair-path fallback under no debate env picks pre-feature schema"
        repair_no_debate="$SCHEMA_TEST_TMP/repair-no-debate.json"
        (
            unset REVIEW_GATE_DEBATE
            # shellcheck disable=SC1090
            source "$RG_MODELS_LIB"
            default_review_schema
        ) > "$repair_no_debate"
        if cmp -s "$repair_no_debate" "$BASELINE_SCHEMA"; then
            log_pass "repair-path fallback emits pre-feature schema bytes when no debate env"
            pass_count=$((pass_count + 1))
        else
            log_fail "repair-path fallback drifted from pre-feature baseline when no debate env"
            fail_count=$((fail_count + 1))
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "" >&2
echo "Byte-parity tests: $pass_count passed, $fail_count failed." >&2
if [[ $fail_count -gt 0 ]]; then
    exit 1
fi
exit 0
