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
        if [[ -n "${CERBERUS_AMP_STUB_STATUS_JSON:-}" ]]; then
            printf '%s\n' "${CERBERUS_AMP_STUB_STATUS_JSON}"
            exit 0
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
delete process.env.REVIEW_GATE_SESSION_KEY
process.env.CLAUDE_PLUGIN_ROOT = '/poison/claude-plugin-root'
process.env.CLAUDE_PROJECT_DIR = '/poison/claude-project-dir'
process.env.CLAUDE_SESSION_ID = 'poison-claude-session'
process.env.CLAUDE_TRANSCRIPT_PATH = '/poison/claude-transcript.jsonl'
process.env.REVIEW_GATE_SESSION_ID = 'poison-session-id'
process.env.REVIEW_GATE_TRANSCRIPT_PATH = '/poison/review-gate-transcript.jsonl'
process.env.REVIEW_GATE_REVIEWER_SUBPROCESS = '1'

const mod = await import(process.env.PLUGIN_FILE!)
const cerberus = mod.default
const executeCerberusCommand = mod.executeCerberusCommand as Function
const ensureAmpSession = mod.ensureAmpSession as Function
const mapAgentEndDecision = mod.mapAgentEndDecision as Function
const pollCerberusOnce = mod.pollCerberusOnce as Function
const startCerberusMonitor = mod.startCerberusMonitor as Function
const stopCerberusMonitor = mod.stopCerberusMonitor as Function
const markGateNotified = mod.markGateNotified as Function

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

// REVIEW_GATE_SESSION_KEY is the legacy alias for CERBERUS_RUN_KEY. It must
// (a) win as the runKey when no explicit CERBERUS_RUN_KEY is set, (b) act as
// a one-shot bypass that does NOT rebind the persisted active-session
// registry, and (c) still be stripped from the backend env handed to
// bin/review-gate.
const persistedRunKey = nextSession.runKey
const persistedRegistry = read(resolve(process.env.HOME!, '.cerberus', 'runtime', 'amp', expectedProjectKey, 'active-session.json'))
const aliasRunKey = 'legacy-alias-run-key'
process.env.REVIEW_GATE_SESSION_KEY = aliasRunKey
const aliasSession = ensureAmpSession({ status: 'done' }, {})
assert(aliasSession.runKey === aliasRunKey, 'REVIEW_GATE_SESSION_KEY should be honored as the legacy run key alias')
const registryAfterAlias = read(resolve(process.env.HOME!, '.cerberus', 'runtime', 'amp', expectedProjectKey, 'active-session.json'))
assert(registryAfterAlias === persistedRegistry, 'explicit run key override must not rebind the persisted active-session registry')

const explicitOverride = 'explicit-cerberus-override'
process.env.CERBERUS_RUN_KEY = explicitOverride
const explicitSession = ensureAmpSession({ status: 'done' }, { thread: { id: thread } })
assert(explicitSession.runKey === explicitOverride, 'CERBERUS_RUN_KEY override should win over thread id')
const registryAfterExplicit = read(resolve(process.env.HOME!, '.cerberus', 'runtime', 'amp', expectedProjectKey, 'active-session.json'))
assert(registryAfterExplicit === persistedRegistry, 'explicit CERBERUS_RUN_KEY must not rebind the persisted active-session registry')
delete process.env.CERBERUS_RUN_KEY
delete process.env.REVIEW_GATE_SESSION_KEY

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

executeCerberusCommand('review-code', { diff_mode: 'commit', commit: 'HEAD', focus: 'Amp adapter', exclude: [':(exclude,glob)dist/**'] }, event, ctx)
assert(read(resolve(process.env.TEST_CAPTURE_DIR!, 'argv.2')).trim() === 'spawn-code-review\n--focus\nAmp adapter\n--exclude\n:(exclude,glob)dist/**\n--commit\nHEAD', 'review-code commit argv mismatch')

executeCerberusCommand('ask', { question: 'Ship it?' }, event, ctx)
assert(read(resolve(process.env.TEST_CAPTURE_DIR!, 'argv.3')).trim() === 'spawn-ask\nShip it?', 'ask spawn argv mismatch')
assert(read(resolve(process.env.TEST_CAPTURE_DIR!, 'argv.4')).trim() === 'wait\n--json\n--finalize', 'ask wait argv mismatch')

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

// agent.end loop-guard fingerprint write must NOT persist an explicit
// CERBERUS_RUN_KEY / REVIEW_GATE_SESSION_KEY override into the registry.
const persistedBeforeOverride = read(resolve(process.env.HOME!, '.cerberus', 'runtime', 'amp', expectedProjectKey, 'active-session.json'))
process.env.CERBERUS_RUN_KEY = 'override-during-completion'
process.env.CERBERUS_AMP_STUB_COMPLETION_JSON = JSON.stringify({ decision: 'continue', userMessage: 'Override probe', fingerprint: 'fp-override' })
mapAgentEndDecision({ status: 'done' }, {})
const persistedAfterOverride = read(resolve(process.env.HOME!, '.cerberus', 'runtime', 'amp', expectedProjectKey, 'active-session.json'))
const beforeRunKey = JSON.parse(persistedBeforeOverride).run_key
const afterRunKey = JSON.parse(persistedAfterOverride).run_key
assert(beforeRunKey === afterRunKey, `loop-guard write must preserve persisted run key (${beforeRunKey} != ${afterRunKey})`)
assert(afterRunKey !== 'override-during-completion', 'explicit override must not rebind the active-session registry via agent.end')
delete process.env.CERBERUS_RUN_KEY

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

// pollCerberusOnce: when status reports reviewers still pending, do not
// notify and do not mark the poller as done.
const monitorThread = 'T-019de015-d2d1-70dc-ac7c-bf5ccc46dd80'
const monitorSession = ensureAmpSession({ status: 'done' }, { thread: { id: monitorThread } })
assert(monitorSession.runKey === monitorThread, 'monitor session run key should match thread id')

const pendingCalls: any[] = []
const pendingThread = { id: monitorThread, append: (msgs: any[]) => { pendingCalls.push(msgs); return Promise.resolve() } }
process.env.CERBERUS_AMP_STUB_STATUS_JSON = JSON.stringify({
  pending_reviewers: ['claude', 'codex'],
  reviewers: [{ name: 'claude', status: 'pending' }, { name: 'codex', status: 'pending' }],
  aggregated_findings: [],
  consensus_verdict: null,
  gate_status: 'pending',
  run_key: monitorSession.runKey,
})
const pendingResult = await pollCerberusOnce(monitorSession, pendingThread)
assert(pendingResult.done === false, 'pollCerberusOnce should not mark done while reviewers pending')
assert(pendingResult.notified === false, 'pollCerberusOnce should not notify while reviewers pending')
assert(pendingCalls.length === 0, 'thread.append must not be called while reviewers pending')

// pollCerberusOnce: when reviewers complete with findings, push a completion
// message into the captured thread and stop polling.
const completeCalls: any[] = []
const completeThread = { id: monitorThread, append: (msgs: any[]) => { completeCalls.push(msgs); return Promise.resolve() } }
process.env.CERBERUS_AMP_STUB_STATUS_JSON = JSON.stringify({
  pending_reviewers: [],
  reviewers: [
    { name: 'claude', status: 'complete', verdict: 'pass' },
    { name: 'codex', status: 'complete', verdict: 'FAIL' },
    { name: 'gemini', status: 'complete', verdict: 'pass' },
  ],
  aggregated_findings: [{ priority: 'P1', summary: 'X', verdict: 'FAIL', reviewer: 'codex' }],
  consensus_verdict: 'FAIL',
  gate_status: 'pending',
  run_key: monitorSession.runKey,
})
const completeResult = await pollCerberusOnce(monitorSession, completeThread)
assert(completeResult.done === true, 'pollCerberusOnce should mark done when reviewers complete')
assert(completeResult.notified === true, 'pollCerberusOnce should notify when reviewers complete')
assert(completeCalls.length === 1, `thread.append should be called once on completion (got ${completeCalls.length})`)
assert(completeCalls[0][0].type === 'user-message', 'append payload should be a user-message')
assert(completeCalls[0][0].content.includes('Cerberus reviewers complete'), 'completion message should mention reviewers complete')
assert(completeCalls[0][0].content.includes(monitorSession.runKey), 'completion message should include the run key')
assert(completeCalls[0][0].content.includes('verdict: fail'), 'completion message should normalize verdict to lowercase')
assert(completeCalls[0][0].content.includes('1 finding'), 'completion message should mention finding count')
assert(completeCalls[0][0].content.includes('Address the findings'), 'completion message should advise addressing findings')

// pollCerberusOnce dedupes notifications per monitor key — a second poll with
// the same key must not re-notify even if status still reports complete.
const dedupeCalls: any[] = []
const dedupeThread = { id: monitorThread, append: (msgs: any[]) => { dedupeCalls.push(msgs); return Promise.resolve() } }
const dedupeResult = await pollCerberusOnce(monitorSession, dedupeThread)
assert(dedupeResult.done === true, 'subsequent poll should still mark done')
assert(dedupeResult.notified === false, 'subsequent poll must not re-notify the same monitor key')
assert(dedupeCalls.length === 0, 'thread.append must not be called on a deduped poll')

// pollCerberusOnce ignores status responses whose run_key does not match the
// session's run key (defends against env/resolver bugs returning the wrong
// gate).
const wrongRunSession = ensureAmpSession({ status: 'done' }, { thread: { id: 'T-019de015-d2d1-70dc-ac7c-bf5ccc46dd81' } })
const wrongRunCalls: any[] = []
const wrongRunThread = { id: wrongRunSession.threadID, append: (msgs: any[]) => { wrongRunCalls.push(msgs); return Promise.resolve() } }
process.env.CERBERUS_AMP_STUB_STATUS_JSON = JSON.stringify({
  pending_reviewers: [],
  reviewers: [{ name: 'claude', status: 'complete', verdict: 'pass' }],
  aggregated_findings: [],
  consensus_verdict: 'pass',
  gate_status: 'pending',
  run_key: 'someone-elses-run-key',
})
const wrongRunResult = await pollCerberusOnce(wrongRunSession, wrongRunThread)
assert(wrongRunResult.notified === false, 'pollCerberusOnce must not notify on a mismatched run_key')
assert(wrongRunCalls.length === 0, 'thread.append must not fire on mismatched run_key')

// pollCerberusOnce treats async append rejection as a retry — must not mark
// the gate notified, so a later successful poll can still deliver.
const rejectingSession = ensureAmpSession({ status: 'done' }, { thread: { id: 'T-019de015-d2d1-70dc-ac7c-bf5ccc46dd82' } })
process.env.CERBERUS_AMP_STUB_STATUS_JSON = JSON.stringify({
  pending_reviewers: [],
  reviewers: [{ name: 'claude', status: 'complete', verdict: 'pass' }],
  aggregated_findings: [{ priority: 'P2', summary: 'Y' }],
  consensus_verdict: 'fail',
  gate_status: 'pending',
  run_key: rejectingSession.runKey,
})
let rejectAttempts = 0
const rejectingThread = {
  id: rejectingSession.threadID,
  append: () => { rejectAttempts++; return Promise.reject(new Error('stale thread')) },
}
const rejectResult = await pollCerberusOnce(rejectingSession, rejectingThread)
assert(rejectResult.done === false, 'rejected append should not mark done')
assert(rejectResult.notified === false, 'rejected append should not mark notified')
assert(rejectResult.retry === true, 'rejected append should request retry')
assert(rejectAttempts === 1, 'append should have been attempted once')

const recoveryCalls: any[] = []
const recoveryThread = {
  id: rejectingSession.threadID,
  append: (msgs: any[]) => { recoveryCalls.push(msgs); return Promise.resolve() },
}
const recoveryResult = await pollCerberusOnce(rejectingSession, recoveryThread)
assert(recoveryResult.done === true, 'subsequent poll after recovery should mark done')
assert(recoveryResult.notified === true, 'subsequent poll after recovery should notify')
assert(recoveryCalls.length === 1, 'recovery append should fire exactly once')

// Resolved gates with no findings stop polling silently (no notification).
const resolvedSession = ensureAmpSession({ status: 'done' }, { thread: { id: 'T-019de015-d2d1-70dc-ac7c-bf5ccc46dd83' } })
process.env.CERBERUS_AMP_STUB_STATUS_JSON = JSON.stringify({
  pending_reviewers: [],
  reviewers: [{ name: 'claude', status: 'complete', verdict: 'pass' }],
  aggregated_findings: [],
  consensus_verdict: 'pass',
  gate_status: 'resolved',
  run_key: resolvedSession.runKey,
})
const resolvedCalls: any[] = []
const resolvedThread = { id: resolvedSession.threadID, append: (msgs: any[]) => { resolvedCalls.push(msgs); return Promise.resolve() } }
const resolvedResult = await pollCerberusOnce(resolvedSession, resolvedThread)
assert(resolvedResult.done === true, 'resolved gate should mark done')
assert(resolvedResult.notified === false, 'resolved+pass gate should not notify')
assert(resolvedCalls.length === 0, 'resolved+pass gate should not append')

// startCerberusMonitor must refuse to start when the thread does not expose
// append (feature detection) or when the reviewer-subprocess guard is set.
const noAppendThread = { id: monitorThread } as any
assert(startCerberusMonitor(monitorSession, noAppendThread) === false, 'monitor must not start without thread.append')
assert(startCerberusMonitor(monitorSession, undefined) === false, 'monitor must not start without a thread')
process.env.CERBERUS_REVIEWER_SUBPROCESS = '1'
const guardedThread = { id: monitorThread, append: () => Promise.resolve() }
assert(startCerberusMonitor(monitorSession, guardedThread) === false, 'monitor must not start inside reviewer subprocess')
delete process.env.CERBERUS_REVIEWER_SUBPROCESS

// startCerberusMonitor with restart=true clears any prior dedupe and timer
// for the same monitor key (so back-to-back reviews get a fresh deadline).
delete process.env.CERBERUS_AMP_STUB_STATUS_JSON
const restartSession = ensureAmpSession({ status: 'done' }, { thread: { id: 'T-019de015-d2d1-70dc-ac7c-bf5ccc46dd84' } })
const restartThread = { id: restartSession.threadID, append: () => Promise.resolve() }
assert(startCerberusMonitor(restartSession, restartThread) === true, 'first start should succeed')
assert(startCerberusMonitor(restartSession, restartThread) === false, 'second start without restart should be deduped')
assert(startCerberusMonitor(restartSession, restartThread, { restart: true }) === true, 'restart=true should re-arm the monitor')
stopCerberusMonitor(restartSession)

// In-flight monitor tick must not reschedule itself after stop/restart wins
// the race. We simulate a long-running poll by pointing the stub at a status
// JSON that the runner can swap out, then call stopCerberusMonitor while a
// hypothetical poll is mid-flight (the test calls schedule paths directly via
// startCerberusMonitor + stop and asserts the map is clean).
const inflightSession = ensureAmpSession({ status: 'done' }, { thread: { id: 'T-019de015-d2d1-70dc-ac7c-bf5ccc46dd86' } })
const inflightThread = { id: inflightSession.threadID, append: () => Promise.resolve() }
assert(startCerberusMonitor(inflightSession, inflightThread) === true, 'inflight monitor should start')
stopCerberusMonitor(inflightSession)
// After stop, restart must succeed and the previous (now-stopped) state must
// not leak a second timer.
assert(startCerberusMonitor(inflightSession, inflightThread, { restart: true }) === true, 'restart after stop should succeed')
// Starting again without restart must dedupe against the new state, proving
// the new monitor is the one in MONITORS (not a stale stopped state).
assert(startCerberusMonitor(inflightSession, inflightThread) === false, 'second non-restart start should dedupe against fresh monitor')
stopCerberusMonitor(inflightSession)

// restart=true with a missing/append-less thread must still cancel the old
// monitor and clear NOTIFIED_KEYS for that key, even though it returns false.
const restartCleanupSession = ensureAmpSession({ status: 'done' }, { thread: { id: 'T-019de015-d2d1-70dc-ac7c-bf5ccc46dd8a' } })
const restartCleanupThread = { id: restartCleanupSession.threadID, append: () => Promise.resolve() }
assert(startCerberusMonitor(restartCleanupSession, restartCleanupThread) === true, 'cleanup precondition: monitor active')
markGateNotified(restartCleanupSession)
assert(startCerberusMonitor(restartCleanupSession, undefined, { restart: true }) === false, 'restart with no thread returns false')
// After restart with no thread, NOTIFIED_KEYS for the same key must be clear
// (so a future review with a real thread can notify) AND the previous
// timer/state must be cancelled.
assert(startCerberusMonitor(restartCleanupSession, restartCleanupThread) === true, 'subsequent start should succeed after restart cleanup')
stopCerberusMonitor(restartCleanupSession)

// pollCerberusOnce must respect the isCurrent guard and not poison
// NOTIFIED_KEYS when a stale tick's append resolves after a restart.
const stalePollSession = ensureAmpSession({ status: 'done' }, { thread: { id: 'T-019de015-d2d1-70dc-ac7c-bf5ccc46dd8b' } })
process.env.CERBERUS_AMP_STUB_STATUS_JSON = JSON.stringify({
  pending_reviewers: [],
  reviewers: [{ name: 'claude', status: 'complete', verdict: 'pass' }],
  aggregated_findings: [{ priority: 'P3', summary: 'Z' }],
  consensus_verdict: 'fail',
  gate_status: 'pending',
  run_key: stalePollSession.runKey,
})
let staleAppendCalls = 0
const stalePollThread = {
  id: stalePollSession.threadID,
  append: async () => { staleAppendCalls++; return undefined },
}
// First call: simulate the monitor having been restarted between the status
// fetch and the post-append commit by returning false from isCurrent().
const staleResult = await pollCerberusOnce(stalePollSession, stalePollThread, () => false)
assert(staleAppendCalls === 0, 'stale tick must short-circuit before append when isCurrent() is already false')
assert(staleResult.notified === false, 'stale tick must not report notified')
// Second call: isCurrent flips false ONLY after the append resolves; the
// post-append guard must prevent NOTIFIED_KEYS from being set.
let appendInProgress = true
const lateRotatingThread = {
  id: stalePollSession.threadID,
  append: async () => {
    staleAppendCalls++
    appendInProgress = false
    return undefined
  },
}
const lateResult = await pollCerberusOnce(stalePollSession, lateRotatingThread, () => appendInProgress)
assert(staleAppendCalls === 1, 'late-rotating tick should attempt the append exactly once')
assert(lateResult.notified === false, 'late-rotating tick must not report notified')
// And the dedupe key for this monitor key must NOT be set, so a fresh
// monitor can still deliver later.
const freshNotifyCalls: any[] = []
const freshThread = {
  id: stalePollSession.threadID,
  append: (msgs: any[]) => { freshNotifyCalls.push(msgs); return Promise.resolve() },
}
const freshResult = await pollCerberusOnce(stalePollSession, freshThread)
assert(freshResult.notified === true, 'fresh poll after stale append must still be able to notify')
assert(freshNotifyCalls.length === 1, 'fresh poll should append exactly once')

// agent.end sanity check: ignore decisions whose run_key does not match the
// session run key.
const wrongKeyThread = 'T-019de015-d2d1-70dc-ac7c-bf5ccc46dd87'
process.env.CERBERUS_AMP_STUB_COMPLETION_JSON = JSON.stringify({
  decision: 'continue',
  userMessage: 'Wrong run key',
  fingerprint: 'fp-wrong',
  run_key: 'someone-elses-run',
})
const wrongDecision = mapAgentEndDecision({ thread: { id: wrongKeyThread }, status: 'done' }, { thread: { id: wrongKeyThread } })
assert(wrongDecision === undefined, 'mapAgentEndDecision must drop continuations whose run_key does not match the session')

// New review-* should clear last_blocking_fingerprint so a fresh review can
// surface its own continuation in agent.end.
const fingerprintThread = 'T-019de015-d2d1-70dc-ac7c-bf5ccc46dd88'
process.env.CERBERUS_AMP_STUB_COMPLETION_JSON = JSON.stringify({
  decision: 'continue',
  userMessage: 'First continuation',
  fingerprint: 'fp-first',
  run_key: fingerprintThread,
})
const fingerprintFirst = mapAgentEndDecision({ thread: { id: fingerprintThread }, status: 'done' }, { thread: { id: fingerprintThread } })
assert(fingerprintFirst?.action === 'continue', 'first agent.end should surface continuation')
const fingerprintSession = ensureAmpSession({ thread: { id: fingerprintThread }, status: 'done' }, { thread: { id: fingerprintThread } })
const registryPath = resolve(process.env.HOME!, '.cerberus', 'runtime', 'amp', expectedProjectKey, 'active-session.json')
const registryAfterContinue = JSON.parse(read(registryPath))
assert(typeof registryAfterContinue.last_blocking_fingerprint === 'string' && registryAfterContinue.last_blocking_fingerprint.length > 0, 'agent.end must persist last_blocking_fingerprint')
// Now run a review-* command — the fingerprint must be cleared so the next
// agent.end (with the same fingerprint) is treated as a new blocker.
executeCerberusCommand('review-plan', { plan_path: '/tmp/refresh.md' }, { thread: { id: fingerprintThread }, status: 'done' }, { thread: { id: fingerprintThread } })
const registryAfterReview = JSON.parse(read(registryPath))
assert(registryAfterReview.last_blocking_fingerprint === undefined || registryAfterReview.last_blocking_fingerprint === '', 'review-* must clear last_blocking_fingerprint')
stopCerberusMonitor(fingerprintSession)

// extractThread should prefer an append-capable thread over a metadata-only
// thread when both are available.
const cachedThreadIDPrefer = 'T-019de015-d2d1-70dc-ac7c-bf5ccc46dd89'
const appendCapable = { id: cachedThreadIDPrefer, append: () => Promise.resolve() }
await events['agent.start']({ status: 'done', thread: appendCapable }, { thread: { id: cachedThreadIDPrefer } })
process.env.CERBERUS_RUN_KEY = cachedThreadIDPrefer
executeCerberusCommand('review-plan', { plan_path: '/tmp/prefer.md' }, { status: 'done', thread: appendCapable }, { thread: { id: cachedThreadIDPrefer } })
const preferSession = ensureAmpSession({ status: 'done' }, {})
delete process.env.CERBERUS_RUN_KEY
assert(startCerberusMonitor(preferSession, appendCapable) === false, 'append-capable thread should have been preferred and the monitor already started')
stopCerberusMonitor(preferSession)

// Thread cache: executeCerberusCommand must look up a cached thread when the
// tool execute ctx does not include one (real Amp tool ctx may omit thread).
const cachedThreadID = 'T-019de015-d2d1-70dc-ac7c-bf5ccc46dd85'
const cachedThread = { id: cachedThreadID, append: () => Promise.resolve() }
// Prime the cache via the agent.start lifecycle handler (the same path real
// Amp uses). This populates THREAD_CACHE keyed by thread.id.
await events['agent.start']({ status: 'done', thread: cachedThread }, { thread: cachedThread })
// Invoke a review-* command with NO thread in event/ctx, but force the
// session's runKey to match the cached thread id via CERBERUS_RUN_KEY so
// resolveThread's runKey-based cache lookup matches.
process.env.CERBERUS_RUN_KEY = cachedThreadID
executeCerberusCommand('review-plan', { plan_path: '/tmp/cached.md' }, { status: 'done' }, {})
// Reconstruct the same session and assert the monitor for that key is
// already active — i.e., resolveThread successfully fell back to the cache.
const cachedSession = ensureAmpSession({ status: 'done' }, {})
delete process.env.CERBERUS_RUN_KEY
assert(cachedSession.runKey === cachedThreadID, 'reconstructed session should inherit explicit run key override')
assert(startCerberusMonitor(cachedSession, cachedThread) === false, 'cached-thread monitor must already be active for this run key')
stopCerberusMonitor(cachedSession)
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
