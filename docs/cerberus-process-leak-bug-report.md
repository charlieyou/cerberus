# Bug Report: Cerberus Review Gate Spawns Recursive Stop-Hook Process Chain

## Summary

Cerberus created hundreds of long-lived `review-gate check` processes under a single implementer process group. The process chain appears to be caused by reviewer `claude -p` subprocesses running their own Stop hooks without the reviewer-subprocess marker environment, causing each reviewer Stop hook to enforce the parent gate and spawn another reviewer cycle.

## Impact

- Observed 396 processes in process group `96220` at the time of investigation.
- Observed 314 processes whose command contained `cerberus`.
- The chain was still growing, with fresh `review-gate check` children appearing while the investigation was running.
- This can exhaust process table slots, CPU, memory, file descriptors, and Claude/Cerberus reviewer budget.

## Environment

- Date observed: `2026-05-01T18:47:57Z`
- Repo: `/Users/charlieyou/code/cerberus`
- Cached plugin versions involved: `1.54.1` and `1.54.2`
- Main process group: `96220`
- Parent Cerberus agent process:
  - `96220 ... --agent-id impl-T023@cerberus-impl-7b38b74583 --agent-type cerberus:implementer --model opus`

## Evidence

The process tree showed a nested chain under the same process group:

```text
2346  96220 bash .../cerberus/1.54.1/bin/cerberus-task-completed-hook
2958   2346 bash .../cerberus/1.54.1/bin/review-gate wait --json --finalize --timeout 1800 --poll-interval 3 --session-key cerberus-impl-7b38b74583-T023-round5
10073  2958 bash .../cerberus/1.54.1/bin/review-gate wait --json --finalize --timeout 1800 --poll-interval 3 --session-key cerberus-impl-7b38b74583-T023-round5
10094 10073 bash .../cerberus/1.54.1/bin/review-gate wait --json --finalize --timeout 1800 --poll-interval 3 --session-key cerberus-impl-7b38b74583-T023-round5
10166 10098 bash .../cerberus/1.54.2/bin/review-gate check
10312 10166 bash .../cerberus/1.54.2/bin/review-gate check
```

Later samples showed repeated reviewer launches followed by more Stop-hook checks:

```text
27305 27279 bash .../cerberus/1.54.2/bin/review-gate check
27310 27305 claude -p --model haiku --output-format json --allowedTools Read Glob Grep LS --disallowedTools Bash Edit Write WebFetch WebSearch
27623 27310 bash .../cerberus/1.54.2/bin/review-gate check
27694 27623 bash .../cerberus/1.54.2/bin/review-gate check
27699 27694 bash .../cerberus/1.54.2/bin/review-gate check
27725 27699 bash .../cerberus/1.54.2/bin/review-gate check
27730 27725 claude -p --model haiku --output-format json --allowedTools Read Glob Grep LS --disallowedTools Bash Edit Write WebFetch WebSearch
```

The active reviewer `claude -p` process environment did not include the intended reviewer-subprocess markers:

```text
CERBERUS_RUN_KEY=cerberus-impl-7b38b74583-T023-round5
CLAUDE_SESSION_ID=30e5ed47-aef5-47a9-a59a-01081d8ae089
REVIEW_GATE_TRANSCRIPT_PATH=/Users/charlieyou/.claude/projects/-Users-charlieyou-code-rwa-rwa-db--claude-worktrees-shadow-write-infra/30e5ed47-aef5-47a9-a59a-01081d8ae089.jsonl
```

Notably absent:

```text
CERBERUS_REVIEWER_SUBPROCESS=1
REVIEW_GATE_REVIEWER_SUBPROCESS=1
```

This absence matters because `bin/review-gate-hook.sh` only fails open for reviewer subprocesses when one of those marker variables is truthy:

```bash
if _reviewer_subprocess_marker_truthy "${CERBERUS_REVIEWER_SUBPROCESS:-}" || \
   _reviewer_subprocess_marker_truthy "${REVIEW_GATE_REVIEWER_SUBPROCESS:-}"; then
    log "review-gate: reviewer subprocess Stop hook; allowing"
    output_allow
fi
```

`bin/review-gate-models.sh` intends to mark detached reviewer shells before running the reviewer CLI:

```bash
script='
export CERBERUS_REVIEWER_SUBPROCESS=1
export REVIEW_GATE_REVIEWER_SUBPROCESS=1
unset CERBERUS_RUN_KEY REVIEW_GATE_SESSION_KEY REVIEW_GATE_SESSION_SOURCE
unset CERBERUS_SESSION_ID CLAUDE_SESSION_ID REVIEW_GATE_SESSION_ID
unset CERBERUS_TRANSCRIPT_PATH CLAUDE_TRANSCRIPT_PATH REVIEW_GATE_TRANSCRIPT_PATH
'"$script"
```

But the live `claude -p` reviewer process still had the parent `CERBERUS_RUN_KEY`/session env and lacked the markers, which means the marker/scrubbing did not reach the actual reviewer process or did not reach the Stop hook environment created by the Claude CLI.

## Likely Root Cause

Reviewer subprocesses are not reliably isolated from the parent Cerberus gate environment. When a reviewer Claude process finishes or attempts to stop, its Stop hook invokes `review-gate check`; because the marker env is absent and the parent gate identity remains present, the hook treats the reviewer as a normal parent session, blocks on the parent gate, and can re-spawn reviewers. Each re-spawned reviewer repeats the same behavior, producing a recursive process chain.

## Expected Behavior

- Reviewer CLI processes should never enforce the parent review gate from their own Stop hooks.
- Reviewer Stop hooks should immediately allow when running inside reviewer subprocesses.
- Parent gate identity variables should be scrubbed from reviewer process environments.
- A single review cycle should not create an unbounded chain of `review-gate check` and `claude -p` processes.

## Suggested Fix Areas

- Verify why `spawn_detached_review_shell` marker exports and unsets are not present on the live `claude -p` reviewer process.
- Prefer passing marker/scrubbed env directly on the reviewer CLI command invocation, not only via a generated `bash -c` prefix.
- Add a hard recursion guard in `review_gate_check`, such as allowing immediately when the parent process chain already contains `review-gate check` or when the hook is invoked from a non-interactive reviewer CLI command.
- Add a regression test that simulates a reviewer Claude Stop hook with inherited parent gate identity and asserts it fails open rather than spawning reviewers.

## Immediate Mitigation Taken

The affected Cerberus process groups were terminated after this report was written.
