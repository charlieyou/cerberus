#!/usr/bin/env bash
# capture-pre-debate-baseline.sh
#
# One-shot capture of pre-feature golden fixtures for all 5 invocation shapes.
# Run ONCE, BEFORE any --debate / prompt-template or bin/review-gate edits land.
#
# Output: bin/tests/fixtures/pre-debate-baseline/
#
# Usage:
#   bin/tests/capture-pre-debate-baseline.sh [--overwrite]
#
# Flags:
#   --overwrite   Overwrite existing fixtures (default: abort if fixtures exist)
#
# What this script does:
#   For each of the 5 invocation shapes, it:
#     1. Runs the spawn command against canned (offline) fake reviewer CLIs
#     2. Waits for all fake reviewers to complete
#     3. Runs the stop-hook check to get gate-state.json in final state
#     4. Copies all captured artifacts to bin/tests/fixtures/pre-debate-baseline/
#
# Captured per shape:
#   reviews/review.prompt      - rendered reviewer prompt (shared by all reviewers)
#   reviews/review-schema.json - structured-output schema for codex
#   reviews/<reviewer>.json    - canned PASS verdict from each reviewer
#   gate-state.json            - after stop-hook resolution (status: resolved)
#   iteration.txt              - iteration counter (written by stop-hook on resolve)
#   spawn-stdout.txt           - stdout from spawn command
#   spawn-stderr.txt           - stderr from spawn command
#   gate-report.md             - stop-hook gate report markdown
#   latest.md                  - artifact file (for reference)
#
# R9 byte-parity tests (T002 onward) assert post-feature non-debate runs match these
# fixtures byte-for-byte.  Do NOT regenerate after any prompt-template edit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REVIEW_GATE="$PLUGIN_ROOT/bin/review-gate"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/pre-debate-baseline"

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { printf "${CYAN}INFO:${NC}  %s\n" "$1" >&2; }
log_ok()    { printf "${GREEN}OK:${NC}    %s\n" "$1" >&2; }
log_warn()  { printf "${YELLOW}WARN:${NC}  %s\n" "$1" >&2; }
log_error() { printf "${RED}ERROR:${NC} %s\n" "$1" >&2; }
log_step()  { printf "${YELLOW}STEP:${NC}  %s\n" "$1" >&2; }

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
OVERWRITE=false
for arg in "$@"; do
    case "$arg" in
        --overwrite) OVERWRITE=true ;;
        *) log_error "Unknown argument: $arg"; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
    log_error "jq is required but not found in PATH"
    exit 2
fi

if [[ ! -x "$REVIEW_GATE" ]]; then
    log_error "review-gate not found or not executable: $REVIEW_GATE"
    exit 2
fi

if [[ ! -f "$PLUGIN_ROOT/config/gemini-readonly-settings.json" ]]; then
    log_error "Missing: $PLUGIN_ROOT/config/gemini-readonly-settings.json"
    exit 2
fi

if [[ ! -f "$PLUGIN_ROOT/config/gemini-readonly-policy.toml" ]]; then
    log_error "Missing: $PLUGIN_ROOT/config/gemini-readonly-policy.toml"
    exit 2
fi

# Verify we are inside a git repo (needed by spawn-code-review)
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    log_error "Must be run from inside a git repository"
    exit 2
fi

# Pin a specific pre-fixture commit for the spawn-code-review shape.
# Using a pinned SHA instead of HEAD avoids a circular problem: if HEAD is the
# T001 fixture-capture commit itself, git show HEAD embeds the old fixture
# files (with machine-specific temp-dir paths) in the diff, which then
# propagates into the captured review.prompt.  The pinned commit (c4443c5
# "Increase review gate stop hook timeout") has a small, clean 3-file diff
# with no machine-specific content.  Its SHA is immutable and will survive
# all future T002-T013 commits.
CODE_REVIEW_COMMIT="c4443c54796a362876c8a1b9e9a1603e0ffeb008"

if ! git cat-file -e "${CODE_REVIEW_COMMIT}^{commit}" 2>/dev/null; then
    log_error "Pinned code-review commit not found: $CODE_REVIEW_COMMIT"
    log_error "This repo must contain the commit 'Increase review gate stop hook timeout'."
    exit 2
fi

# Check fixture dir
if [[ -d "$FIXTURE_DIR" ]] && [[ "$(ls -A "$FIXTURE_DIR" 2>/dev/null)" != "" ]]; then
    if [[ "$OVERWRITE" != "true" ]]; then
        log_warn "Fixtures already exist at: $FIXTURE_DIR"
        log_warn "Use --overwrite to regenerate (only valid before any prompt-template edit)."
        exit 1
    fi
    log_warn "Overwriting existing fixtures at: $FIXTURE_DIR"
    rm -rf "$FIXTURE_DIR"
fi

mkdir -p "$FIXTURE_DIR"

# ---------------------------------------------------------------------------
# Temporary environment setup
# ---------------------------------------------------------------------------
WORK_DIR="$(mktemp -d -t capture-pre-debate.XXXXXX)"
# On macOS, mktemp returns /var/folders/... but realpath resolves symlinks to
# /private/var/folders/... (canonical form).  We must normalize both so that
# sed replacements in fixture files don't leave '/private<CAPTURE_WORKDIR>'
# artifacts.  If realpath is unavailable or produces the same path, this is a
# no-op (canonical == WORK_DIR).
WORK_DIR_CANONICAL="$(realpath "$WORK_DIR" 2>/dev/null || echo "$WORK_DIR")"
trap 'rm -rf "$WORK_DIR"' EXIT

FAKE_HOME="$WORK_DIR/home"
FAKE_BIN="$WORK_DIR/bin"
mkdir -p "$FAKE_HOME" "$FAKE_BIN"

# Transcript dir (determines project hash for review dir paths).
# Parent dir name starts with '-' so get_project_hash uses it directly.
TRANSCRIPT_DIR="$FAKE_HOME/.claude/projects/-capture-pre-debate-baseline"
mkdir -p "$TRANSCRIPT_DIR"

BASH_BIN="${BASH:-/bin/bash}"

# Gemini settings/policy: use real ones from plugin config
GEMINI_SETTINGS="$PLUGIN_ROOT/config/gemini-readonly-settings.json"
GEMINI_POLICY="$PLUGIN_ROOT/config/gemini-readonly-policy.toml"

# ---------------------------------------------------------------------------
# Fake reviewer CLIs
# ---------------------------------------------------------------------------
# These produce deterministic PASS verdicts without network calls.
# Placed first in PATH so they shadow any real codex/gemini/claude.

# -- fake codex ---------------------------------------------------------------
# Real codex: codex exec ... --json -o $REVIEW_OUT ... < $REVIEW_PROMPT > $REVIEW_JSONL
# Fake codex parses the -o <file> argument, writes verdict JSON there, and
# writes minimal JSONL events to stdout (which becomes $REVIEW_JSONL).
cat > "$FAKE_BIN/codex" <<'CODEX_SCRIPT'
#!/usr/bin/env bash
# Parse -o <output_file> from argv
out_file=""
prev=""
for arg in "$@"; do
    if [[ "$prev" == "-o" ]]; then
        out_file="$arg"
    fi
    prev="$arg"
done
# Write canned verdict to the -o output file
if [[ -n "$out_file" ]]; then
    printf '{"verdict":"PASS","summary":"Canned fixture: all criteria met.","findings":[]}\n' \
        > "$out_file"
fi
# Write minimal JSONL transcript to stdout (for $REVIEW_JSONL)
printf '{"type":"thread.started","id":"fixture-thread-001"}\n'
printf '{"type":"turn.completed","id":"fixture-turn-001","usage":{"input_tokens":100,"output_tokens":50}}\n'
exit 0
CODEX_SCRIPT

# -- fake gemini --------------------------------------------------------------
# Real gemini: gemini ... -o json < $REVIEW_PROMPT > $REVIEW_OUT
# Fake gemini writes PASS JSON to stdout (shell wrapper redirects to $REVIEW_OUT).
cat > "$FAKE_BIN/gemini" <<'GEMINI_SCRIPT'
#!/usr/bin/env bash
printf '{"verdict":"PASS","summary":"Canned fixture: all criteria met.","findings":[]}\n'
exit 0
GEMINI_SCRIPT

# -- fake claude --------------------------------------------------------------
# Real claude: claude -p --output-format json ... < $REVIEW_PROMPT > $REVIEW_OUT
# Claude --output-format json wraps the response in {"session_id":...,"result":"..."}.
# extract_json for claude reads the .result field and parses it as JSON.
cat > "$FAKE_BIN/claude" <<'CLAUDE_SCRIPT'
#!/usr/bin/env bash
result_json='{"verdict":"PASS","summary":"Canned fixture: all criteria met.","findings":[]}'
# Escape the JSON string for embedding in the outer JSON .result field
escaped=$(printf '%s' "$result_json" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"session_id":"fixture-session","result":"%s","tokens":{"input":100,"output":50,"cached":0},"duration_ms":100,"total_cost_usd":0.0001}\n' \
    "$escaped"
exit 0
CLAUDE_SCRIPT

chmod +x "$FAKE_BIN/codex" "$FAKE_BIN/gemini" "$FAKE_BIN/claude"

# Provide a thin nohup wrapper so the real nohup is still used (needed for
# spawn_detached_review_shell to work correctly).
REAL_NOHUP="$(command -v nohup 2>/dev/null || true)"
if [[ -n "$REAL_NOHUP" ]]; then
    cat > "$FAKE_BIN/nohup" <<NOHUP_SCRIPT
#!$BASH_BIN
exec "$REAL_NOHUP" "\$@"
NOHUP_SCRIPT
    chmod +x "$FAKE_BIN/nohup"
fi

# ---------------------------------------------------------------------------
# Shared helper: wait for reviewer sentinels (done/failed) to appear
# ---------------------------------------------------------------------------
wait_for_sentinels() {
    local reviews_dir="$1"
    local expected_count="${2:-3}"
    local max_wait="${3:-30}"
    local elapsed=0
    local count

    while [[ $elapsed -lt $max_wait ]]; do
        count=0
        for f in "$reviews_dir"/*.done "$reviews_dir"/*.failed; do
            [[ -f "$f" ]] && ((count++)) || true
        done
        if [[ $count -ge $expected_count ]]; then
            return 0
        fi
        sleep 1
        ((elapsed++)) || true
    done
    log_warn "wait_for_sentinels: timeout after ${max_wait}s (found $count / $expected_count)"
    ls -la "$reviews_dir" >&2 2>/dev/null || true
    return 1
}

# ---------------------------------------------------------------------------
# Shared helper: run the stop-hook check and return gate-report markdown
# ---------------------------------------------------------------------------
# IMPORTANT: Use 'export' inside the subshell so that HOME, PATH, and other
# env vars are set for the piped 'review-gate check' process (not just for
# the leading 'printf').
run_check_and_get_report() {
    local session_id="$1"
    local transcript_path="$2"
    local fake_home="$3"

    local check_input
    check_input=$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$session_id" "$transcript_path")

    local check_out
    check_out=$(
        export HOME="$fake_home"
        export PATH="$FAKE_BIN:$PATH"
        export REVIEW_GATE_MAX_WAIT_SECONDS=30
        export REVIEW_GATE_POLL_INTERVAL_SECONDS=1
        export GEMINI_READONLY_SETTINGS_PATH="$GEMINI_SETTINGS"
        export GEMINI_READONLY_POLICY_PATH="$GEMINI_POLICY"
        printf '%s' "$check_input" | "$REVIEW_GATE" check 2>/dev/null || true
    )

    # The check always outputs:
    #   {"decision":"block","reason":"...gate report markdown..."}
    # or on auto-approve:
    #   {"decision":"block","reason":"## Review Results\n..."}
    # Extract the gate report from the payload field.
    local report
    report=$(printf '%s' "$check_out" | jq -r '
        if .reason then .reason
        elif .message then .message
        else "(no gate report captured)"
        end' 2>/dev/null || echo "(check output was not valid JSON: ${check_out:0:200})")
    printf '%s' "$report"
}

# ---------------------------------------------------------------------------
# Shared helper: normalize machine-specific paths in a file
# ---------------------------------------------------------------------------
# Replaces WORK_DIR (the mktemp path that changes every run) and PLUGIN_ROOT
# (the user's local repo path) with stable placeholders so fixtures are
# reproducible across machines and re-runs.
#
# Substitutions:
#   $WORK_DIR    -> <CAPTURE_WORKDIR>   (temp dir for fake CLIs and sessions)
#   $PLUGIN_ROOT -> <PLUGIN_ROOT>       (local repo path)
normalize_fixture_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    # Only process text files (skip binary files)
    if file "$file" 2>/dev/null | grep -q "binary"; then
        return 0
    fi
    local tmp
    tmp=$(mktemp -t normalize.XXXXXX)
    # Use | as sed delimiter so paths with / are safe.
    # Apply canonical (realpath) substitution FIRST so that on macOS the
    # /private/var/... resolved form is replaced before the shorter /var/...
    # symlink form; otherwise we would leave '/private<CAPTURE_WORKDIR>' behind.
    sed -e "s|${WORK_DIR_CANONICAL}|<CAPTURE_WORKDIR>|g" \
        -e "s|${WORK_DIR}|<CAPTURE_WORKDIR>|g" \
        -e "s|${PLUGIN_ROOT}|<PLUGIN_ROOT>|g" \
        "$file" > "$tmp"
    mv "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# Shared helper: copy captured artifacts to fixture sub-directory
# ---------------------------------------------------------------------------
copy_to_fixture() {
    local shape_dir="$1"
    local review_dir="$2"
    local spawn_stdout="$3"
    local spawn_stderr="$4"
    local gate_report="$5"

    mkdir -p "$shape_dir/reviews"

    # Prompt (shared for all reviewers under current plugin version)
    if [[ -f "$review_dir/reviews/review.prompt" ]]; then
        cp "$review_dir/reviews/review.prompt" "$shape_dir/reviews/review.prompt"
        normalize_fixture_file "$shape_dir/reviews/review.prompt"
    fi

    # Schema (no paths embedded; normalization is a no-op but applied for consistency)
    if [[ -f "$review_dir/reviews/review-schema.json" ]]; then
        cp "$review_dir/reviews/review-schema.json" "$shape_dir/reviews/review-schema.json"
        normalize_fixture_file "$shape_dir/reviews/review-schema.json"
    fi

    # Per-reviewer verdict JSONs
    for reviewer in codex gemini claude; do
        if [[ -f "$review_dir/reviews/$reviewer.json" ]]; then
            cp "$review_dir/reviews/$reviewer.json" "$shape_dir/reviews/$reviewer.json"
            normalize_fixture_file "$shape_dir/reviews/$reviewer.json"
        fi
    done

    # Gate state (post stop-hook resolution, should be status: resolved)
    if [[ -f "$review_dir/gate-state.json" ]]; then
        cp "$review_dir/gate-state.json" "$shape_dir/gate-state.json"
        normalize_fixture_file "$shape_dir/gate-state.json"
    fi

    # Iteration counter (written by reset_iteration inside check on auto-approve)
    [[ -f "$review_dir/iteration.txt" ]] && \
        cp "$review_dir/iteration.txt" "$shape_dir/iteration.txt"

    # Artifact (latest.md)
    if [[ -f "$review_dir/latest.md" ]]; then
        cp "$review_dir/latest.md" "$shape_dir/latest.md"
        normalize_fixture_file "$shape_dir/latest.md"
    fi

    # Spawn CLI output
    cp "$spawn_stdout" "$shape_dir/spawn-stdout.txt"
    normalize_fixture_file "$shape_dir/spawn-stdout.txt"
    cp "$spawn_stderr" "$shape_dir/spawn-stderr.txt"
    normalize_fixture_file "$shape_dir/spawn-stderr.txt"

    # Gate report markdown
    # Normalize the gate_report string before writing (it may contain paths).
    # Apply canonical form first (macOS: /private/var/... before /var/...).
    local normalized_report
    normalized_report=$(printf '%s' "$gate_report" | \
        sed -e "s|${WORK_DIR_CANONICAL}|<CAPTURE_WORKDIR>|g" \
            -e "s|${WORK_DIR}|<CAPTURE_WORKDIR>|g" \
            -e "s|${PLUGIN_ROOT}|<PLUGIN_ROOT>|g")
    printf '%s\n' "$normalized_report" > "$shape_dir/gate-report.md"
}

# ---------------------------------------------------------------------------
# Helper: assert a captured file is non-empty (verification)
# ---------------------------------------------------------------------------
VERIFY_FAILURES=0
assert_nonempty() {
    local file="$1"
    local label="$2"
    if [[ ! -s "$file" ]]; then
        log_warn "  EMPTY/MISSING: $label ($file)"
        ((VERIFY_FAILURES++)) || true
        return 1
    fi
    log_ok "  non-empty: $label"
    return 0
}

# ===========================================================================
# SHAPE 1: spawn-code-review --mode smart --commit <HEAD>
# ===========================================================================
log_step "Shape 1/5: spawn-code-review --mode smart --commit $CODE_REVIEW_COMMIT"

SHAPE1_SESSION="baseline-code-review"
SHAPE1_TRANSCRIPT="$TRANSCRIPT_DIR/${SHAPE1_SESSION}.jsonl"
touch "$SHAPE1_TRANSCRIPT"

SHAPE1_REVIEW_DIR="$FAKE_HOME/.claude/projects/-capture-pre-debate-baseline/cerberus/$SHAPE1_SESSION"
mkdir -p "$SHAPE1_REVIEW_DIR"

SHAPE1_STDOUT="$WORK_DIR/shape1-stdout.txt"
SHAPE1_STDERR="$WORK_DIR/shape1-stderr.txt"

set +e
(
    export HOME="$FAKE_HOME"
    export PATH="$FAKE_BIN:$PATH"
    export CLAUDE_SESSION_ID="$SHAPE1_SESSION"
    export REVIEW_GATE_TRANSCRIPT_PATH="$SHAPE1_TRANSCRIPT"
    export GEMINI_READONLY_SETTINGS_PATH="$GEMINI_SETTINGS"
    export GEMINI_READONLY_POLICY_PATH="$GEMINI_POLICY"
    export REVIEW_GATE_MAX_ROUNDS=3
    "$REVIEW_GATE" spawn-code-review \
        --mode smart \
        --agents codex,gemini,claude \
        --commit "$CODE_REVIEW_COMMIT"
) >"$SHAPE1_STDOUT" 2>"$SHAPE1_STDERR"
SHAPE1_SPAWN_RC=$?
set -e

if [[ $SHAPE1_SPAWN_RC -ne 0 ]]; then
    log_warn "spawn-code-review exited $SHAPE1_SPAWN_RC (stderr follows):"
    cat "$SHAPE1_STDERR" >&2
fi

log_info "Waiting for fake reviewers (code)..."
if ! wait_for_sentinels "$SHAPE1_REVIEW_DIR/reviews" 3 30; then
    log_error "Timed out waiting for code-review sentinels"
    exit 1
fi

log_info "Running stop-hook check (code)..."
SHAPE1_REPORT="$(run_check_and_get_report \
    "$SHAPE1_SESSION" "$SHAPE1_TRANSCRIPT" "$FAKE_HOME")"

copy_to_fixture "$FIXTURE_DIR/spawn-code-review" "$SHAPE1_REVIEW_DIR" \
    "$SHAPE1_STDOUT" "$SHAPE1_STDERR" "$SHAPE1_REPORT"
log_ok "Shape 1 captured -> $FIXTURE_DIR/spawn-code-review/"

# ===========================================================================
# SHAPE 2: spawn-plan-review --mode smart <plan-file>
# ===========================================================================
log_step "Shape 2/5: spawn-plan-review --mode smart"

SHAPE2_SESSION="baseline-plan-review"
SHAPE2_TRANSCRIPT="$TRANSCRIPT_DIR/${SHAPE2_SESSION}.jsonl"
touch "$SHAPE2_TRANSCRIPT"

SHAPE2_REVIEW_DIR="$FAKE_HOME/.claude/projects/-capture-pre-debate-baseline/cerberus/$SHAPE2_SESSION"
mkdir -p "$SHAPE2_REVIEW_DIR"

# Minimal representative plan document
SHAPE2_PLAN="$WORK_DIR/sample-plan.md"
cat > "$SHAPE2_PLAN" <<'PLAN'
# Feature Plan: Pre-Debate Baseline Fixture Capture

## Goal

Add baseline golden fixture capture to support R9 byte-parity tests for
the pre-debate feature branch.

## Steps

1. Create capture script at bin/tests/capture-pre-debate-baseline.sh
2. Create sample input documents for each invocation shape
3. Run each invocation shape with canned reviewer outputs
4. Capture prompt, schema, gate-state, and gate-report artifacts
5. Commit fixtures to bin/tests/fixtures/pre-debate-baseline/

## Success Criteria

- All 5 invocation shapes produce non-empty fixture captures
- Prompts match what the current plugin version would produce interactively
- gate-state.json shows status: "resolved" after stop-hook runs
PLAN

SHAPE2_STDOUT="$WORK_DIR/shape2-stdout.txt"
SHAPE2_STDERR="$WORK_DIR/shape2-stderr.txt"

set +e
(
    export HOME="$FAKE_HOME"
    export PATH="$FAKE_BIN:$PATH"
    export CLAUDE_SESSION_ID="$SHAPE2_SESSION"
    export REVIEW_GATE_TRANSCRIPT_PATH="$SHAPE2_TRANSCRIPT"
    export GEMINI_READONLY_SETTINGS_PATH="$GEMINI_SETTINGS"
    export GEMINI_READONLY_POLICY_PATH="$GEMINI_POLICY"
    export REVIEW_GATE_MAX_ROUNDS=3
    "$REVIEW_GATE" spawn-plan-review \
        --mode smart \
        --agents codex,gemini,claude \
        "$SHAPE2_PLAN"
) >"$SHAPE2_STDOUT" 2>"$SHAPE2_STDERR"
SHAPE2_SPAWN_RC=$?
set -e

if [[ $SHAPE2_SPAWN_RC -ne 0 ]]; then
    log_warn "spawn-plan-review exited $SHAPE2_SPAWN_RC (stderr follows):"
    cat "$SHAPE2_STDERR" >&2
fi

log_info "Waiting for fake reviewers (plan)..."
if ! wait_for_sentinels "$SHAPE2_REVIEW_DIR/reviews" 3 30; then
    log_error "Timed out waiting for plan-review sentinels"
    exit 1
fi

log_info "Running stop-hook check (plan)..."
SHAPE2_REPORT="$(run_check_and_get_report \
    "$SHAPE2_SESSION" "$SHAPE2_TRANSCRIPT" "$FAKE_HOME")"

copy_to_fixture "$FIXTURE_DIR/spawn-plan-review" "$SHAPE2_REVIEW_DIR" \
    "$SHAPE2_STDOUT" "$SHAPE2_STDERR" "$SHAPE2_REPORT"
log_ok "Shape 2 captured -> $FIXTURE_DIR/spawn-plan-review/"

# ===========================================================================
# SHAPE 3: spawn-spec-review --mode smart <spec-file>
# ===========================================================================
log_step "Shape 3/5: spawn-spec-review --mode smart"

SHAPE3_SESSION="baseline-spec-review"
SHAPE3_TRANSCRIPT="$TRANSCRIPT_DIR/${SHAPE3_SESSION}.jsonl"
touch "$SHAPE3_TRANSCRIPT"

SHAPE3_REVIEW_DIR="$FAKE_HOME/.claude/projects/-capture-pre-debate-baseline/cerberus/$SHAPE3_SESSION"
mkdir -p "$SHAPE3_REVIEW_DIR"

# Minimal representative spec document
SHAPE3_SPEC="$WORK_DIR/sample-spec.md"
cat > "$SHAPE3_SPEC" <<'SPEC'
# Feature Specification: Pre-Debate Baseline Fixtures

## Overview

Capture pre-feature golden fixtures for all five review-gate invocation shapes
before any debate-mode prompt-template changes land.

## Requirements

### R0 — Fixture Capture

The capture script MUST run synchronously and produce deterministic output
by substituting all three reviewer CLIs with canned offline counterparts.

### R1 — Prompt Fidelity

The rendered prompt captured for each shape MUST be byte-identical to what
the plugin would produce when invoked interactively with the same arguments.

### R2 — Schema Stability

The review-schema.json MUST be captured verbatim; no structural change is
permitted to the pre-debate schema.

## Acceptance Criteria

- AC-StepZero: All 5 shapes produce non-empty captures.
- AC-PromptFidelity: Captured prompts match interactive invocation.
- AC-SchemaStability: Schema is identical to interactive invocation schema.
SPEC

SHAPE3_STDOUT="$WORK_DIR/shape3-stdout.txt"
SHAPE3_STDERR="$WORK_DIR/shape3-stderr.txt"

set +e
(
    export HOME="$FAKE_HOME"
    export PATH="$FAKE_BIN:$PATH"
    export CLAUDE_SESSION_ID="$SHAPE3_SESSION"
    export REVIEW_GATE_TRANSCRIPT_PATH="$SHAPE3_TRANSCRIPT"
    export GEMINI_READONLY_SETTINGS_PATH="$GEMINI_SETTINGS"
    export GEMINI_READONLY_POLICY_PATH="$GEMINI_POLICY"
    export REVIEW_GATE_MAX_ROUNDS=3
    "$REVIEW_GATE" spawn-spec-review \
        --mode smart \
        --agents codex,gemini,claude \
        "$SHAPE3_SPEC"
) >"$SHAPE3_STDOUT" 2>"$SHAPE3_STDERR"
SHAPE3_SPAWN_RC=$?
set -e

if [[ $SHAPE3_SPAWN_RC -ne 0 ]]; then
    log_warn "spawn-spec-review exited $SHAPE3_SPAWN_RC (stderr follows):"
    cat "$SHAPE3_STDERR" >&2
fi

log_info "Waiting for fake reviewers (spec)..."
if ! wait_for_sentinels "$SHAPE3_REVIEW_DIR/reviews" 3 30; then
    log_error "Timed out waiting for spec-review sentinels"
    exit 1
fi

log_info "Running stop-hook check (spec)..."
SHAPE3_REPORT="$(run_check_and_get_report \
    "$SHAPE3_SESSION" "$SHAPE3_TRANSCRIPT" "$FAKE_HOME")"

copy_to_fixture "$FIXTURE_DIR/spawn-spec-review" "$SHAPE3_REVIEW_DIR" \
    "$SHAPE3_STDOUT" "$SHAPE3_STDERR" "$SHAPE3_REPORT"
log_ok "Shape 3 captured -> $FIXTURE_DIR/spawn-spec-review/"

# ===========================================================================
# SHAPE 4: spawn-epic-verify --mode smart <epic-file>
# ===========================================================================
log_step "Shape 4/5: spawn-epic-verify --mode smart"

SHAPE4_SESSION="baseline-epic-verify"
SHAPE4_TRANSCRIPT="$TRANSCRIPT_DIR/${SHAPE4_SESSION}.jsonl"
touch "$SHAPE4_TRANSCRIPT"

SHAPE4_REVIEW_DIR="$FAKE_HOME/.claude/projects/-capture-pre-debate-baseline/cerberus/$SHAPE4_SESSION"
mkdir -p "$SHAPE4_REVIEW_DIR"

# Minimal representative epic / acceptance criteria file
SHAPE4_EPIC="$WORK_DIR/sample-epic.md"
cat > "$SHAPE4_EPIC" <<'EPIC'
# Epic: Review Gate Debate Mode

## Acceptance Criteria

1. The project contains a bin/review-gate script that is executable.
2. The bin/review-gate script accepts a `spawn` subcommand.
3. The bin/review-gate script accepts `spawn-code-review`, `spawn-plan-review`,
   `spawn-spec-review`, and `spawn-epic-verify` as named subcommands.
4. Each named subcommand accepts `--mode <fast|smart|max>`.
5. The bin/review-gate script writes a review prompt to
   `<review-dir>/reviews/review.prompt` during spawn.
6. The structured-output schema is written to
   `<review-dir>/reviews/review-schema.json` during spawn.
EPIC

SHAPE4_STDOUT="$WORK_DIR/shape4-stdout.txt"
SHAPE4_STDERR="$WORK_DIR/shape4-stderr.txt"

set +e
(
    export HOME="$FAKE_HOME"
    export PATH="$FAKE_BIN:$PATH"
    export CLAUDE_SESSION_ID="$SHAPE4_SESSION"
    export REVIEW_GATE_TRANSCRIPT_PATH="$SHAPE4_TRANSCRIPT"
    export GEMINI_READONLY_SETTINGS_PATH="$GEMINI_SETTINGS"
    export GEMINI_READONLY_POLICY_PATH="$GEMINI_POLICY"
    export REVIEW_GATE_MAX_ROUNDS=3
    "$REVIEW_GATE" spawn-epic-verify \
        --mode smart \
        --agents codex,gemini,claude \
        "$SHAPE4_EPIC"
) >"$SHAPE4_STDOUT" 2>"$SHAPE4_STDERR"
SHAPE4_SPAWN_RC=$?
set -e

if [[ $SHAPE4_SPAWN_RC -ne 0 ]]; then
    log_warn "spawn-epic-verify exited $SHAPE4_SPAWN_RC (stderr follows):"
    cat "$SHAPE4_STDERR" >&2
fi

log_info "Waiting for fake reviewers (epic)..."
if ! wait_for_sentinels "$SHAPE4_REVIEW_DIR/reviews" 3 30; then
    log_error "Timed out waiting for epic-verify sentinels"
    exit 1
fi

log_info "Running stop-hook check (epic)..."
SHAPE4_REPORT="$(run_check_and_get_report \
    "$SHAPE4_SESSION" "$SHAPE4_TRANSCRIPT" "$FAKE_HOME")"

copy_to_fixture "$FIXTURE_DIR/spawn-epic-verify" "$SHAPE4_REVIEW_DIR" \
    "$SHAPE4_STDOUT" "$SHAPE4_STDERR" "$SHAPE4_REPORT"
log_ok "Shape 4 captured -> $FIXTURE_DIR/spawn-epic-verify/"

# ===========================================================================
# SHAPE 5: bare spawn --type code --mode smart <artifact>
# ===========================================================================
# This exercises the raw 'spawn' subcommand path (no named subcommand wrapper),
# passing --type code so the stop-hook uses the code revision template.
# The artifact is a pre-built latest.md placed directly in the review dir.
log_step "Shape 5/5: spawn --type code --mode smart (bare spawn)"

SHAPE5_SESSION="baseline-spawn-bare"
SHAPE5_TRANSCRIPT="$TRANSCRIPT_DIR/${SHAPE5_SESSION}.jsonl"
touch "$SHAPE5_TRANSCRIPT"

SHAPE5_REVIEW_DIR="$FAKE_HOME/.claude/projects/-capture-pre-debate-baseline/cerberus/$SHAPE5_SESSION"
mkdir -p "$SHAPE5_REVIEW_DIR"

# Create a minimal code-review artifact in the review dir.
# This simulates the artifact that spawn-code-review would have written,
# and demonstrates the code path where spawn is called directly with
# an existing latest.md artifact.
SHAPE5_ARTIFACT="$SHAPE5_REVIEW_DIR/latest.md"
cat > "$SHAPE5_ARTIFACT" <<'ARTIFACT'
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
ARTIFACT

SHAPE5_STDOUT="$WORK_DIR/shape5-stdout.txt"
SHAPE5_STDERR="$WORK_DIR/shape5-stderr.txt"

set +e
(
    export HOME="$FAKE_HOME"
    export PATH="$FAKE_BIN:$PATH"
    export CLAUDE_SESSION_ID="$SHAPE5_SESSION"
    export REVIEW_GATE_TRANSCRIPT_PATH="$SHAPE5_TRANSCRIPT"
    export GEMINI_READONLY_SETTINGS_PATH="$GEMINI_SETTINGS"
    export GEMINI_READONLY_POLICY_PATH="$GEMINI_POLICY"
    export REVIEW_GATE_MAX_ROUNDS=3
    "$REVIEW_GATE" spawn \
        --type code \
        --mode smart \
        --agents codex,gemini,claude \
        "$SHAPE5_ARTIFACT"
) >"$SHAPE5_STDOUT" 2>"$SHAPE5_STDERR"
SHAPE5_SPAWN_RC=$?
set -e

if [[ $SHAPE5_SPAWN_RC -ne 0 ]]; then
    log_warn "spawn (bare) exited $SHAPE5_SPAWN_RC (stderr follows):"
    cat "$SHAPE5_STDERR" >&2
fi

log_info "Waiting for fake reviewers (bare)..."
if ! wait_for_sentinels "$SHAPE5_REVIEW_DIR/reviews" 3 30; then
    log_error "Timed out waiting for bare-spawn sentinels"
    exit 1
fi

log_info "Running stop-hook check (bare)..."
SHAPE5_REPORT="$(run_check_and_get_report \
    "$SHAPE5_SESSION" "$SHAPE5_TRANSCRIPT" "$FAKE_HOME")"

copy_to_fixture "$FIXTURE_DIR/spawn-bare" "$SHAPE5_REVIEW_DIR" \
    "$SHAPE5_STDOUT" "$SHAPE5_STDERR" "$SHAPE5_REPORT"
log_ok "Shape 5 captured -> $FIXTURE_DIR/spawn-bare/"

# ===========================================================================
# Verification: assert all expected files are non-empty
# ===========================================================================
log_step "Verifying captured fixtures..."

for shape in spawn-code-review spawn-plan-review spawn-spec-review spawn-epic-verify spawn-bare; do
    log_info "Checking $shape/"
    shape_dir="$FIXTURE_DIR/$shape"
    for f in \
        "reviews/review.prompt" \
        "reviews/review-schema.json" \
        "reviews/codex.json" \
        "reviews/gemini.json" \
        "reviews/claude.json" \
        "gate-state.json" \
        "spawn-stderr.txt" \
        "gate-report.md"
    do
        assert_nonempty "$shape_dir/$f" "$shape/$f"
    done

    # spawn-stdout.txt may legitimately be empty; just check it exists
    if [[ ! -f "$shape_dir/spawn-stdout.txt" ]]; then
        log_warn "  MISSING: $shape/spawn-stdout.txt"
        ((VERIFY_FAILURES++)) || true
    fi

    # gate-state.json should have status: resolved after stop-hook
    if [[ -f "$shape_dir/gate-state.json" ]]; then
        local_status=$(jq -r '.status // "missing"' "$shape_dir/gate-state.json" 2>/dev/null || echo "parse-error")
        if [[ "$local_status" != "resolved" ]]; then
            log_warn "  gate-state.json status='$local_status' (expected 'resolved') in $shape"
            ((VERIFY_FAILURES++)) || true
        else
            log_ok "  gate-state.json status=resolved in $shape"
        fi
    fi

    # iteration.txt: written by reset_iteration on auto-approve; may be "0\n"
    if [[ -f "$shape_dir/iteration.txt" ]]; then
        log_ok "  iteration.txt present in $shape"
    else
        log_warn "  iteration.txt missing in $shape (stop-hook may not have run)"
        ((VERIFY_FAILURES++)) || true
    fi
done

# ===========================================================================
# Summary
# ===========================================================================
echo "" >&2
if [[ $VERIFY_FAILURES -gt 0 ]]; then
    log_warn "Verification completed with $VERIFY_FAILURES issue(s)."
    log_warn "Some fixtures may be incomplete.  Review warnings above."
else
    log_ok "All fixture files verified."
fi

printf "${GREEN}Capture complete.${NC}\n" >&2
printf "Fixture directory: %s\n" "$FIXTURE_DIR" >&2
printf "Shapes captured:\n" >&2
for shape in spawn-code-review spawn-plan-review spawn-spec-review spawn-epic-verify spawn-bare; do
    file_count=$(find "$FIXTURE_DIR/$shape" -type f 2>/dev/null | wc -l | tr -d ' ' || echo 0)
    printf "  %-25s  (%s files)\n" "$shape" "$file_count" >&2
done
echo "" >&2
printf "${YELLOW}IMPORTANT:${NC} These fixtures are immutable pre-feature baselines.\n" >&2
printf "Do NOT re-run after any prompt-template or bin/review-gate edit.\n" >&2

if [[ $VERIFY_FAILURES -gt 0 ]]; then
    exit 1
fi
exit 0
