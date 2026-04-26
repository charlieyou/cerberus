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
# Summary
# ---------------------------------------------------------------------------
echo "" >&2
echo "Byte-parity tests: $pass_count passed, $fail_count failed." >&2
if [[ $fail_count -gt 0 ]]; then
    exit 1
fi
exit 0
