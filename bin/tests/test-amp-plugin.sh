#!/usr/bin/env bash
# Amp plugin adapter tests. Exercises the TypeScript plugin with a stubbed
# bin/review-gate backend so the shared backend remains authoritative.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_FILE="$REPO_ROOT/.amp/plugins/cerberus.ts"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR=""

log_test() { echo -e "${YELLOW}TEST:${NC} $1"; }
log_pass() { echo -e "${GREEN}PASS:${NC} $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
log_fail() { echo -e "${RED}FAIL:${NC} $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

if [[ ! -f "$PLUGIN_FILE" ]]; then
    echo "FATAL: Amp plugin not found at $PLUGIN_FILE" >&2
    exit 2
fi

if [[ "$(head -n 1 "$PLUGIN_FILE")" != "// @i-know-the-amp-plugin-api-is-wip-and-very-experimental-right-now" ]]; then
    echo "FATAL: Amp plugin missing required WIP API header as first line" >&2
    exit 2
fi

BUN_BIN="${BUN_BIN:-$(command -v bun 2>/dev/null || true)}"
if [[ -z "$BUN_BIN" ]]; then
    echo "SKIP: bun not found; Amp plugin runtime tests require Bun or Amp's bundled Bun" >&2
    exit 0
fi

TEST_DIR="$(mktemp -d -t cerberus-amp-plugin.XXXXXX)"
STUB="$TEST_DIR/review-gate-stub"
CAPTURE_DIR="$TEST_DIR/captures"
WORKSPACE="$TEST_DIR/workspace"
mkdir -p "$CAPTURE_DIR"
mkdir -p "$WORKSPACE"

cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
CAPTURE_DIR="${CERBERUS_AMP_CAPTURE_DIR:?}"
n="$(ls "$CAPTURE_DIR"/argv.* 2>/dev/null | wc -l | tr -d ' ')"
n=$((n + 1))
argv_file="$CAPTURE_DIR/argv.$n"
env_file="$CAPTURE_DIR/env.$n"
: > "$argv_file"
for arg in "$@"; do
    printf '%s\n' "$arg" >> "$argv_file"
done
{
    for v in CERBERUS_HOST CERBERUS_ROOT CERBERUS_STATE_ROOT CERBERUS_PROJECT_KEY CERBERUS_RUN_KEY AMP_THREAD_ID AMP_CURRENT_THREAD_ID CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR CLAUDE_SESSION_ID CLAUDE_TRANSCRIPT_PATH REVIEW_GATE_SESSION_KEY REVIEW_GATE_SESSION_ID REVIEW_GATE_TRANSCRIPT_PATH REVIEW_GATE_REVIEWER_SUBPROCESS; do
        if [[ -n "${!v+set}" ]]; then
            printf '%s=%s\n' "$v" "${!v}"
        else
            printf '%s=<unset>\n' "$v"
        fi
    done
} > "$env_file"

case "${1:-}" in
    status)
        if [[ "${CERBERUS_AMP_STUB_STATUS_NO_GATE:-}" == "1" ]]; then
            printf '{"status":"no_active_gate"}\n'
            exit 4
        fi
        printf 'stub backend: %s\n' "$*"
        ;;
    completion-check)
        if [[ "${CERBERUS_AMP_BREAK_REGISTRY_ON_COMPLETION:-}" == "1" ]]; then
            registry_parent="$HOME/.cerberus/runtime/amp/${CERBERUS_PROJECT_KEY:?}"
            rm -rf "$registry_parent"
            mkdir -p "$(dirname "$registry_parent")"
            : > "$registry_parent"
        fi
        completion_json="${CERBERUS_AMP_STUB_COMPLETION_JSON:-}"
        if [[ -z "$completion_json" ]]; then
            completion_json='{"decision":"allow","reason":"test"}'
        fi
        printf '%s\n' "$completion_json" > "$CAPTURE_DIR/completion.$n"
        printf '%s\n' "$completion_json"
        ;;
    *)
        printf 'stub backend: %s\n' "$*"
        ;;
esac
STUB
chmod +x "$STUB"

RUNNER="$TEST_DIR/run-amp-plugin-tests.ts"
cat > "$RUNNER" <<'TS'
import { mkdirSync, readFileSync } from 'node:fs'
import { resolve } from 'node:path'

function assert(condition: unknown, message: string): void {
  if (!condition) throw new Error(message)
}

function read(path: string): string {
  return readFileSync(path, 'utf8')
}

process.env.HOME = process.env.TEST_HOME!
process.env.CERBERUS_AMP_WORKSPACE = process.env.TEST_WORKSPACE!
process.env.CERBERUS_REVIEW_GATE_BIN = process.env.TEST_STUB!
process.env.CERBERUS_AMP_CAPTURE_DIR = process.env.TEST_CAPTURE_DIR!
process.env.CERBERUS_ROOT = process.env.TEST_CERBERUS_ROOT!
delete process.env.CERBERUS_RUN_KEY
delete process.env.CERBERUS_REVIEWER_SUBPROCESS
delete process.env.AMP_THREAD_ID
delete process.env.AMP_CURRENT_THREAD_ID
process.env.CLAUDE_PLUGIN_ROOT = '/poison/claude-plugin-root'
process.env.CLAUDE_PROJECT_DIR = '/poison/claude-project-dir'
process.env.CLAUDE_SESSION_ID = 'poison-claude-session'
process.env.CLAUDE_TRANSCRIPT_PATH = '/poison/claude-transcript.jsonl'
process.env.REVIEW_GATE_SESSION_KEY = 'poison-session-key'
process.env.REVIEW_GATE_SESSION_ID = 'poison-session-id'
process.env.REVIEW_GATE_TRANSCRIPT_PATH = '/poison/review-gate-transcript.jsonl'
process.env.REVIEW_GATE_REVIEWER_SUBPROCESS = '1'

const mod = await import(process.env.PLUGIN_FILE!)
const cerberus = mod.default
const executeCerberusCommand = mod.executeCerberusCommand as Function
const ensureAmpSession = mod.ensureAmpSession as Function
const mapAgentEndDecision = mod.mapAgentEndDecision as Function

const tools: string[] = []
const commands: string[] = []
const events: Record<string, Function> = {}
const amp = {
  registerTool(def: { name: string }) { tools.push(def.name); return {} },
  registerCommand(id: string) { commands.push(id); return {} },
  on(event: string, handler: Function) { events[event] = handler; return {} },
}
cerberus(amp)

for (const name of ['review-code', 'review-plan', 'review-spec', 'ask-panel', 'ask', 'status', 'clear-gate']) {
  assert(tools.includes(name), `missing registered tool ${name}`)
  assert(commands.includes(name), `missing registered command ${name}`)
}
for (const name of ['session.start', 'agent.start', 'agent.end']) {
  assert(typeof events[name] === 'function', `missing event handler ${name}`)
}

const fallbackSession = ensureAmpSession({ status: 'done' }, {})
assert(/^[a-f0-9-]{36}$/.test(fallbackSession.runKey), 'missing thread should fall back to a UUID run key')

const eventThread = 'T-019de015-d2d1-70dc-ac7c-bf5ccc46dd67'
const thread = 'T-019de015-d2d1-70dc-ac7c-bf5ccc46dd68'
const event = { thread: { id: eventThread }, status: 'done' }
const ctx = { thread: { id: thread } }
const session = ensureAmpSession(event, ctx)
assert(session.runKey === thread, 'valid thread id should replace a prior UUID fallback')
assert(session.threadID === thread, 'ctx thread id should win over event thread id')
const expectedProjectKey = process.env.TEST_WORKSPACE!.replace(/^\//, '-').replaceAll('/', '-')
assert(session.projectKey === expectedProjectKey, 'workspace project key mismatch')

const nextThread = 'T-019de015-d2d1-70dc-ac7c-bf5ccc46dd69'
const nextSession = ensureAmpSession({ status: 'done' }, { thread: { id: nextThread } })
assert(nextSession.runKey === nextThread, 'a later valid thread id should become the run key')

const output = executeCerberusCommand('review-plan', { plan_path: '/tmp/plan.md' }, event, ctx)
assert(output.includes(`Cerberus run key: ${thread}`), 'run key header missing from command output')
assert(read(resolve(process.env.TEST_CAPTURE_DIR!, 'argv.1')).trim() === 'spawn-plan-review\n/tmp/plan.md', 'review-plan argv mismatch')
const env = read(resolve(process.env.TEST_CAPTURE_DIR!, 'env.1'))
for (const expected of [
  'CERBERUS_HOST=amp',
  `CERBERUS_ROOT=${process.env.TEST_CERBERUS_ROOT!}`,
  `CERBERUS_RUN_KEY=${thread}`,
  `AMP_THREAD_ID=${thread}`,
  'CLAUDE_PLUGIN_ROOT=<unset>',
  'CLAUDE_PROJECT_DIR=<unset>',
  'CLAUDE_SESSION_ID=<unset>',
  'CLAUDE_TRANSCRIPT_PATH=<unset>',
  'REVIEW_GATE_SESSION_KEY=<unset>',
  'REVIEW_GATE_SESSION_ID=<unset>',
  'REVIEW_GATE_TRANSCRIPT_PATH=<unset>',
  'REVIEW_GATE_REVIEWER_SUBPROCESS=<unset>',
]) {
  assert(env.includes(expected), `missing backend env ${expected}`)
}

executeCerberusCommand('ask', { question: 'Ship it?' }, event, ctx)
assert(read(resolve(process.env.TEST_CAPTURE_DIR!, 'argv.2')).trim() === 'spawn-ask\nShip it?', 'ask spawn argv mismatch')
assert(read(resolve(process.env.TEST_CAPTURE_DIR!, 'argv.3')).trim() === 'wait\n--json\n--finalize', 'ask wait argv mismatch')

process.env.CERBERUS_AMP_STUB_STATUS_NO_GATE = '1'
const statusOutput = executeCerberusCommand('status', {}, event, ctx)
assert(statusOutput.includes('{"status":"no_active_gate"}'), 'status no-active-gate response should be returned')
delete process.env.CERBERUS_AMP_STUB_STATUS_NO_GATE

process.env.CERBERUS_AMP_STUB_COMPLETION_JSON = JSON.stringify({ decision: 'allow', reason: 'no_active_gate' })
assert(mapAgentEndDecision(event, ctx) === undefined, 'allow completion should not continue')

process.env.CERBERUS_AMP_STUB_COMPLETION_JSON = JSON.stringify({ decision: 'continue', userMessage: 'Fix Cerberus findings', fingerprint: 'fp-1' })
const first = mapAgentEndDecision(event, ctx)
assert(first?.action === 'continue' && first.userMessage === 'Fix Cerberus findings', 'continue completion should map to agent.end continue')
const second = mapAgentEndDecision(event, ctx)
assert(second === undefined, 'same fingerprint should not continue twice')

process.env.CERBERUS_AMP_STUB_COMPLETION_JSON = JSON.stringify({ decision: 'continue', userMessage: 'Do not loop', fingerprint: 'fp-2' })
process.env.CERBERUS_REVIEWER_SUBPROCESS = '1'
assert(mapAgentEndDecision(event, ctx) === undefined, 'reviewer subprocess should bypass enforcement')
delete process.env.CERBERUS_REVIEWER_SUBPROCESS
assert(mapAgentEndDecision({ ...event, status: 'cancelled' }, ctx) === undefined, 'cancelled turn should bypass enforcement')

const originalHome = process.env.HOME!
const originalWorkspace = process.env.CERBERUS_AMP_WORKSPACE!
const breakHome = resolve(process.env.TEST_DIR!, 'break-home')
const breakWorkspace = resolve(process.env.TEST_DIR!, 'break-workspace')
mkdirSync(breakWorkspace, { recursive: true })
process.env.HOME = breakHome
process.env.CERBERUS_AMP_WORKSPACE = breakWorkspace
process.env.CERBERUS_AMP_BREAK_REGISTRY_ON_COMPLETION = '1'
process.env.CERBERUS_AMP_STUB_COMPLETION_JSON = JSON.stringify({ decision: 'continue', userMessage: 'Fail open', fingerprint: 'fp-break' })
const breakThread = 'T-019de015-d2d1-70dc-ac7c-bf5ccc46dd70'
assert(mapAgentEndDecision({ thread: { id: breakThread }, status: 'done' }, { thread: { id: breakThread } }) === undefined, 'loop-guard write failure should fail open')
delete process.env.CERBERUS_AMP_BREAK_REGISTRY_ON_COMPLETION
process.env.HOME = originalHome
process.env.CERBERUS_AMP_WORKSPACE = originalWorkspace
TS

log_test "Amp plugin registers tools/commands, passes backend env, and maps agent.end decisions"
if TEST_HOME="$TEST_DIR/home" \
   TEST_WORKSPACE="$WORKSPACE" \
   TEST_STUB="$STUB" \
   TEST_CAPTURE_DIR="$CAPTURE_DIR" \
   TEST_CERBERUS_ROOT="$REPO_ROOT" \
   TEST_DIR="$TEST_DIR" \
   PLUGIN_FILE="$PLUGIN_FILE" \
   "$BUN_BIN" "$RUNNER" >"$TEST_DIR/stdout" 2>"$TEST_DIR/stderr"; then
    log_pass "Amp plugin runtime contract"
else
    log_fail "Amp plugin runtime contract; stdout=$(cat "$TEST_DIR/stdout"); stderr=$(cat "$TEST_DIR/stderr")"
fi

echo ""
echo "Amp plugin test summary:"
echo "  Passed: $TESTS_PASSED"
echo "  Failed: $TESTS_FAILED"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
