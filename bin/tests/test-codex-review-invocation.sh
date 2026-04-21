#!/usr/bin/env bash
# Integration test: codex review invocation (--output-schema --json -o)
#
# Exercises the exact flag combination used by review-gate-models.sh against
# the real codex CLI, and verifies:
#   1. The -o file contains a single clean JSON verdict matching the schema
#   2. The stdout JSONL transcript has thread.started + turn.completed events
#   3. extract_codex_telemetry parses usage from the JSONL
#   4. extract_json (reviewer=codex) reads the verdict from the .json file
#   5. safe_extract_telemetry auto-promotes from .json to sibling .jsonl
#
# Skips gracefully if the codex CLI is not installed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export PLUGIN_ROOT

source "$SCRIPT_DIR/../telemetry-lib.sh"
source "$SCRIPT_DIR/../review-gate-lib.sh"
source "$SCRIPT_DIR/../review-gate-models.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

TEST_DIR=""

log_test() { echo -e "${YELLOW}TEST:${NC} $1"; ((TESTS_RUN++)) || true; }
log_pass() { echo -e "${GREEN}PASS:${NC} $1"; ((TESTS_PASSED++)) || true; }
log_fail() { echo -e "${RED}FAIL:${NC} $1"; ((TESTS_FAILED++)) || true; }
log_skip() { echo -e "${CYAN}SKIP:${NC} $1"; ((TESTS_SKIPPED++)) || true; }
log_info() { echo -e "${CYAN}INFO:${NC} $1"; }

cleanup() {
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Model/reasoning tunables (caller can override).
CODEX_TEST_MODEL="${CODEX_TEST_MODEL:-gpt-5.4}"
CODEX_TEST_REASONING="${CODEX_TEST_REASONING:-low}"
# 5-minute hard cap — codex with reasoning can take ~30s even for trivial prompts.
CODEX_TEST_TIMEOUT="${CODEX_TEST_TIMEOUT:-300}"

check_prerequisites() {
    if ! command -v codex >/dev/null 2>&1; then
        log_skip "codex CLI not installed (set PATH or install codex-cli)"
        echo ""
        echo "========================================"
        echo "Results: $TESTS_PASSED passed, $TESTS_SKIPPED skipped, $TESTS_FAILED failed"
        exit 0
    fi
    log_info "codex: $(codex --version 2>/dev/null || echo unknown)"
    log_info "model: $CODEX_TEST_MODEL, reasoning: $CODEX_TEST_REASONING, timeout: ${CODEX_TEST_TIMEOUT}s"
}

setup_fixtures() {
    TEST_DIR=$(mktemp -d)
    REVIEWS_DIR="$TEST_DIR/reviews"
    mkdir -p "$REVIEWS_DIR"

    # Minimal schema matching what cerberus uses at runtime.
    cat > "$TEST_DIR/review-schema.json" <<'EOF'
{
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "verdict": { "type": "string", "enum": ["PASS", "FAIL", "NEEDS_WORK"] },
    "summary": { "type": "string" },
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "title":      { "type": "string" },
          "body":       { "type": "string" },
          "priority":   { "type": "integer", "minimum": 0, "maximum": 3 },
          "file_path":  { "type": ["string", "null"] },
          "line_start": { "type": ["integer", "null"] },
          "line_end":   { "type": ["integer", "null"] }
        },
        "required": ["title", "body", "priority", "file_path", "line_start", "line_end"]
      }
    }
  },
  "required": ["verdict", "summary", "findings"]
}
EOF

    # Prompt asks codex to return the trivial passing verdict in schema shape.
    cat > "$TEST_DIR/review.prompt" <<'EOF'
You are a code-review agent. There is no diff to inspect. Respond with the
trivial passing verdict matching the output schema: verdict PASS, summary
"no changes to review", findings empty. Do not call any tools.
EOF
}

run_codex() {
    local out_file="$REVIEWS_DIR/codex.json"
    local jsonl_file="$REVIEWS_DIR/codex.jsonl"

    # Exact invocation from bin/review-gate-models.sh (spawn_reviewer codex branch).
    # Run synchronously here — we want to verify the call, not the detach path.
    if ! timeout "$CODEX_TEST_TIMEOUT" codex exec \
            -m "$CODEX_TEST_MODEL" \
            -c "model_reasoning_effort=$CODEX_TEST_REASONING" \
            -s read-only \
            --skip-git-repo-check \
            --output-schema "$TEST_DIR/review-schema.json" \
            --json \
            -o "$out_file" \
            - < "$TEST_DIR/review.prompt" > "$jsonl_file" 2>&1; then
        log_fail "codex exec failed (exit $?) — jsonl head: $(head -5 "$jsonl_file" 2>/dev/null)"
        return 1
    fi
    return 0
}

test_output_files_present() {
    log_test "codex writes verdict to -o file and JSONL to stdout"

    if [[ ! -s "$REVIEWS_DIR/codex.json" ]]; then
        log_fail "codex.json is missing or empty"
        return
    fi
    if [[ ! -s "$REVIEWS_DIR/codex.jsonl" ]]; then
        log_fail "codex.jsonl is missing or empty"
        return
    fi

    local json_size jsonl_size
    json_size=$(wc -c < "$REVIEWS_DIR/codex.json")
    jsonl_size=$(wc -c < "$REVIEWS_DIR/codex.jsonl")
    log_info "codex.json=${json_size}B  codex.jsonl=${jsonl_size}B"

    # The verdict file should be dramatically smaller than the transcript.
    # With a trivial prompt, verdict is typically <200B while the banner alone
    # pushes the JSONL past 500B. If they're within 2x of each other something
    # is wrong (e.g., -o was ignored and the TUI was written to both).
    if (( json_size >= jsonl_size )); then
        log_fail "expected codex.json (${json_size}B) to be smaller than codex.jsonl (${jsonl_size}B)"
        return
    fi

    log_pass "both output files present; -o file is smaller than transcript"
}

test_verdict_json_is_pure_and_valid() {
    log_test "-o file is pure JSON matching the schema"

    local verdict
    if ! verdict=$(jq -c '.' "$REVIEWS_DIR/codex.json" 2>/dev/null); then
        log_fail "codex.json does not parse as JSON: $(head -c 200 "$REVIEWS_DIR/codex.json")"
        return
    fi

    local v
    v=$(jq -r '.verdict // empty' "$REVIEWS_DIR/codex.json" 2>/dev/null)
    if [[ -z "$v" ]]; then
        log_fail "verdict field missing: $verdict"
        return
    fi
    case "$v" in
        PASS|FAIL|NEEDS_WORK) ;;
        *) log_fail "unexpected verdict value: $v"; return ;;
    esac

    local findings_type
    findings_type=$(jq -r '.findings | type' "$REVIEWS_DIR/codex.json" 2>/dev/null)
    if [[ "$findings_type" != "array" ]]; then
        log_fail "findings is not an array (got: $findings_type)"
        return
    fi

    log_pass "verdict=$v, findings is an array"
}

test_jsonl_has_expected_events() {
    log_test "JSONL transcript contains thread.started and turn.completed"

    # Every line must parse.
    local bad=0 total=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        ((total++)) || true
        if ! jq -e . >/dev/null 2>&1 <<<"$line"; then
            ((bad++)) || true
        fi
    done < "$REVIEWS_DIR/codex.jsonl"

    if (( bad > 0 )); then
        log_fail "$bad/$total lines in codex.jsonl are not valid JSON"
        return
    fi
    if (( total == 0 )); then
        log_fail "codex.jsonl has no lines"
        return
    fi

    local has_thread has_turn
    has_thread=$(jq -s 'map(select(.type == "thread.started")) | length' "$REVIEWS_DIR/codex.jsonl")
    has_turn=$(jq -s 'map(select(.type == "turn.completed")) | length' "$REVIEWS_DIR/codex.jsonl")

    if (( has_thread == 0 )); then
        log_fail "no thread.started event in JSONL"
        return
    fi
    if (( has_turn == 0 )); then
        log_fail "no turn.completed event in JSONL"
        return
    fi

    log_pass "JSONL has $total valid events including thread.started and turn.completed"
}

test_extract_codex_telemetry_parses_jsonl() {
    log_test "extract_codex_telemetry extracts session + tokens from JSONL"

    local stats
    if ! stats=$(extract_codex_telemetry "$REVIEWS_DIR/codex.jsonl" 2>/dev/null); then
        log_fail "extract_codex_telemetry returned non-zero"
        return
    fi
    if [[ -z "$stats" ]]; then
        log_fail "extract_codex_telemetry returned empty"
        return
    fi

    local session_id input_tokens output_tokens
    session_id=$(jq -r '.session_id // empty' <<<"$stats")
    input_tokens=$(jq -r '.tokens.input // 0' <<<"$stats")
    output_tokens=$(jq -r '.tokens.output // 0' <<<"$stats")

    if [[ -z "$session_id" || "$session_id" == "null" ]]; then
        log_fail "session_id missing in telemetry: $stats"
        return
    fi
    if (( input_tokens == 0 && output_tokens == 0 )); then
        log_fail "both input+output tokens zero in telemetry: $stats"
        return
    fi

    log_pass "session=$session_id, input=$input_tokens, output=$output_tokens"
}

test_extract_json_reads_verdict() {
    log_test "extract_json reviewer=codex returns the verdict"

    local json
    if ! json=$(extract_json "$REVIEWS_DIR/codex.json" codex 2>/dev/null); then
        log_fail "extract_json returned non-zero"
        return
    fi

    local verdict
    verdict=$(jq -r '.verdict // empty' <<<"$json" 2>/dev/null)
    if [[ -z "$verdict" ]]; then
        log_fail "verdict missing from extract_json output: ${json:0:200}"
        return
    fi

    log_pass "extract_json produced verdict=$verdict"
}

test_safe_extract_telemetry_promotes_to_jsonl() {
    log_test "safe_extract_telemetry codex auto-promotes .json to sibling .jsonl"

    local stats
    stats=$(safe_extract_telemetry codex "$REVIEWS_DIR/codex.json" 2>/dev/null)
    if [[ -z "$stats" || "$stats" == "{}" ]]; then
        log_fail "safe_extract_telemetry returned empty/{}"
        return
    fi

    local session_id
    session_id=$(jq -r '.session_id // empty' <<<"$stats")
    if [[ -z "$session_id" || "$session_id" == "null" ]]; then
        log_fail "session_id not recovered when called with .json path: $stats"
        return
    fi

    log_pass "session_id=$session_id extracted from sibling .jsonl"
}

test_jsonl_fallback_recovers_verdict() {
    log_test "extract_json recovers verdict from JSONL when -o file is empty"

    # Simulate codex crashing after the agent_message was emitted but before
    # flushing the -o file: .json is empty, .jsonl has the full turn.
    local scratch="$TEST_DIR/crash"
    mkdir -p "$scratch"
    : > "$scratch/codex.json"
    cp "$REVIEWS_DIR/codex.jsonl" "$scratch/codex.jsonl"
    # review-schema.json is read from the same dir as the input file.
    cp "$TEST_DIR/review-schema.json" "$scratch/review-schema.json"

    local json
    if ! json=$(extract_json "$scratch/codex.json" codex 2>/dev/null); then
        log_fail "extract_json returned non-zero on empty .json + valid .jsonl"
        return
    fi

    local verdict
    verdict=$(jq -r '.verdict // empty' <<<"$json" 2>/dev/null)
    case "$verdict" in
        PASS|FAIL|NEEDS_WORK) ;;
        *)
            log_fail "extract_json returned event instead of verdict: ${json:0:200}"
            return
            ;;
    esac

    # Belt and suspenders: the value MUST NOT be a turn.completed envelope.
    local kind
    kind=$(jq -r '.type // empty' <<<"$json" 2>/dev/null)
    if [[ "$kind" == "turn.completed" || "$kind" == "item.completed" ]]; then
        log_fail "extract_json returned a JSONL event envelope: $json"
        return
    fi

    log_pass "verdict=$verdict recovered from JSONL agent_message"
}

main() {
    echo "========================================"
    echo "Codex Review Invocation Integration Test"
    echo "========================================"
    echo ""

    check_prerequisites
    setup_fixtures

    if ! run_codex; then
        echo ""
        echo "========================================"
        echo "Results: $TESTS_PASSED passed, $TESTS_SKIPPED skipped, $TESTS_FAILED failed"
        exit 1
    fi

    test_output_files_present
    test_verdict_json_is_pure_and_valid
    test_jsonl_has_expected_events
    test_extract_codex_telemetry_parses_jsonl
    test_extract_json_reads_verdict
    test_safe_extract_telemetry_promotes_to_jsonl
    test_jsonl_fallback_recovers_verdict

    echo ""
    echo "========================================"
    echo "Results: $TESTS_PASSED passed, $TESTS_SKIPPED skipped, $TESTS_FAILED failed (of $TESTS_RUN)"
    if (( TESTS_FAILED > 0 )); then
        echo -e "${RED}$TESTS_FAILED tests failed${NC}"
        exit 1
    fi
    echo -e "${GREEN}All executed tests passed${NC}"
}

main "$@"
