# Bug Report: Claude reviewer hangs ~30 min post-API and gate report masks valid verdicts behind a timeout marker

## Summary

During a multi-round plan review run on 2026-04-30 / 2026-05-01, the `claude` reviewer subprocess produced valid review JSON in every round but was killed at the per-reviewer 1800s timeout in rounds 2, 3, and 4. The `claude.failed` marker created by the timeout branch coexisted with a valid `claude.json` and the gate-state report rendered the reviewer as `ERROR | Reviewer process failed`, while the JSON file contained complete `verdict` values (two `NEEDS_WORK` and one `PASS`).

## Environment

- Repo: `/Users/cyou/code/cerberus`
- Branch: `main`
- Review session id: `3d2c009f-59a4-40c1-95cd-c57c49e4637a`
- Session directory: `/Users/cyou/.claude/projects/-Users-cyou-code-cerberus/cerberus/3d2c009f-59a4-40c1-95cd-c57c49e4637a`
- Reviewer config: `REVIEW_GATE_REVIEWER_TIMEOUT=1800` (default), set in `bin/review-gate-models.sh:800`
- Plan under review: `/Users/cyou/code/cerberus/docs/2026-04-30-port-shell-to-go-plan.md`

## Observed Symptoms

1. The user-visible review report in rounds 2–4 contained:
   ```
   | claude | ERROR | - | Reviewer process failed |
   ```
2. `claude.failed` marker files of size 0 bytes existed alongside non-empty `claude.json` files.
3. `claude.json` files in rounds 2–4 contained `is_error: false`, `subtype: "success"`, `stop_reason: "end_turn"`, `terminal_reason: "completed"`, and a complete `result` field with parseable `verdict`.

## Evidence

### File listing (claude.json + claude.failed across all rounds)

```
$ ls -la /Users/cyou/.claude/projects/-Users-cyou-code-cerberus/cerberus/3d2c009f-59a4-40c1-95cd-c57c49e4637a/reviews*/claude.{json,failed}

reviews-iter-0/claude.json     7716 bytes  May 1 00:03   (no .failed marker)
reviews-iter-1/claude.json     5935 bytes  May 1 00:50
reviews-iter-1/claude.failed      0 bytes  May 1 00:50
reviews-iter-2/claude.json     6190 bytes  May 1 01:30
reviews-iter-2/claude.failed      0 bytes  May 1 01:30
reviews/claude.json            2537 bytes  May 1 02:05
reviews/claude.failed             0 bytes  May 1 02:05
```

Round 1 (`reviews-iter-0`) has no `.failed` marker and was rendered correctly as `PASS`. Rounds 2–4 each have both a non-empty `claude.json` and an empty `claude.failed` marker.

### Per-round timing data (extracted from the `claude.json` envelope)

| Round | Path | total `duration_ms` | `duration_api_ms` | post-API idle | `is_error` | `stop_reason` | `terminal_reason` | parsed `verdict` |
|------:|------|--------------------:|------------------:|--------------:|-----------:|--------------:|------------------:|------------------|
| 1 | `reviews-iter-0/claude.json` | (no `.failed`) | — | — | false | end_turn | completed | PASS |
| 2 | `reviews-iter-1/claude.json` | 1,799,645 | 279,679 | 25.3 min | false | end_turn | completed | NEEDS_WORK |
| 3 | `reviews-iter-2/claude.json` | 1,799,709 | 254,998 | 25.7 min | false | end_turn | completed | NEEDS_WORK |
| 4 | `reviews/claude.json`        | 1,799,719 |  92,787 | 28.4 min | false | end_turn | completed | PASS |

Rounds 2, 3, 4 totals span 74 ms (1,799,645 → 1,799,719). The configured deadline is 1,800,000 ms.

### Cerberus log entries from round 1 (PASS path, no `.failed` marker)

`/Users/cyou/.claude/projects/-Users-cyou-code-cerberus/cerberus/3d2c009f-59a4-40c1-95cd-c57c49e4637a/cerberus.log`:

```
2026-05-01T00:03:43-04:00 review-gate: extract_json START reviewer=claude file=.../reviews/claude.json size=    7716
2026-05-01T00:03:43-04:00 review-gate: extract_json claude extracting from metadata wrapper
2026-05-01T00:03:43-04:00 review-gate: extract_json claude extracted len=6056
2026-05-01T00:03:43-04:00 review-gate: extract_json claude SUCCESS verdict=PASS
```

### Code paths

**Reviewer spawn + timeout wrapper** — `/Users/cyou/code/cerberus/bin/review-gate-models.sh:880-905`:

```
echo "Spawning claude reviewer (model: $claude_model)..." >&2
CLAUDE_ALLOWED_TOOLS="$CLAUDE_READONLY_ALLOWED_TOOLS" \
CLAUDE_DISALLOWED_TOOLS="$CLAUDE_READONLY_DISALLOWED_TOOLS" \
REVIEW_OUT="$output_file" \
REVIEW_DONE="$sentinel_file" \
REVIEW_FAIL="$failed_file" \
REVIEW_PROMPT="$prompt_file" \
REVIEW_MODEL="$claude_model" \
REVIEW_TIMEOUT="$reviewer_timeout" \
REVIEW_TIMEOUT_BIN="$reviewer_timeout_bin" \
spawn_detached_review_shell '
    timeout_prefix=()
    if [[ -n "${REVIEW_TIMEOUT_BIN:-}" && -n "${REVIEW_TIMEOUT:-}" ]]; then
        timeout_prefix=("$REVIEW_TIMEOUT_BIN" "$REVIEW_TIMEOUT")
    fi
    read -r -a claude_allowed_tools <<< "$CLAUDE_ALLOWED_TOOLS"
    read -r -a claude_disallowed_tools <<< "$CLAUDE_DISALLOWED_TOOLS"
    if "${timeout_prefix[@]}" claude -p --model "$REVIEW_MODEL" --output-format json \
        --allowedTools "${claude_allowed_tools[@]}" \
        --disallowedTools "${claude_disallowed_tools[@]}" \
        < "$REVIEW_PROMPT" > "$REVIEW_OUT" 2>&1; then
        touch "$REVIEW_DONE"
    else
        touch "$REVIEW_FAIL"
    fi
'
```

`/Users/cyou/code/cerberus/bin/review-gate-models.sh:800`:

```
local reviewer_timeout="${REVIEW_GATE_REVIEWER_TIMEOUT:-1800}"
```

**`.failed` marker reads in the gate-state rendering path** — these locations consume the `${reviewer}.failed` sentinel when classifying reviewer state:

- `/Users/cyou/code/cerberus/bin/review-gate:4205`
- `/Users/cyou/code/cerberus/bin/review-gate:4950`
- `/Users/cyou/code/cerberus/bin/review-gate:4983`
- `/Users/cyou/code/cerberus/bin/review-gate:5441` (comment: "using the .done/.failed sentinel files")
- `/Users/cyou/code/cerberus/bin/review-gate:5458`
- `/Users/cyou/code/cerberus/bin/review-gate-hook.sh:1009`
- `/Users/cyou/code/cerberus/bin/review-gate-hook.sh:1132`
- `/Users/cyou/code/cerberus/bin/review-gate-hook.sh:1398`
- `/Users/cyou/code/cerberus/bin/review-gate-hook.sh:1522`
- `/Users/cyou/code/cerberus/bin/review-gate-hook.sh:1601`
- `/Users/cyou/code/cerberus/bin/review-gate-hook.sh:1687`

### Excerpted content of `claude.json` (round 4, `reviews/claude.json`)

```
{"type":"result","subtype":"success","is_error":false,"api_error_status":null,
 "duration_ms":1799719,"duration_api_ms":92787,"num_turns":1,
 "result":"```json\n{\n  \"findings\": [...],\n  \"verdict\": \"PASS\",\n  ...}",
 "stop_reason":"end_turn",
 "session_id":"02e8db58-f8e1-4726-83b7-1addd392490e",
 "total_cost_usd":0.79030625,
 "terminal_reason":"completed",
 ...}
```

### Excerpted content of `claude.json` (round 2, `reviews-iter-1/claude.json`)

```
Looking at this plan in detail, I'll first verify the round-1 fixes are addressed:
**Round-1 fix verification:**
- ✅ P1 build-overwriting: ...
[verdict in this file: NEEDS_WORK]
```

### Excerpted content of `claude.json` (round 3, `reviews-iter-2/claude.json`)

```
Looking at the plan with ultrathink — first verifying prior findings:
**Prior P1/P2 status:**
1. Atomic install-binaries (codex/gemini round 2 P1): **Resolved** ...
[verdict in this file: NEEDS_WORK]
```

## Reproduction Conditions

- Plan-review session under `bin/review-gate spawn-plan-review --max-rounds 5`
- Reviewer model: claude opus
- Per-reviewer timeout: default 1800s
- Three consecutive rounds where `duration_api_ms` was 92,787–279,679 ms (1.5–4.6 min) and `duration_ms` reached 1,799,645–1,799,719 ms (≈30 min)
- Round 1 of the same session did not exhibit the symptom

## Factual Observations

1. The `timeout 1800 claude …` shell expression in `bin/review-gate-models.sh:897-904` exits non-zero when `timeout(1)` kills the wrapped process; the script then runs `touch "$REVIEW_FAIL"` (line 903) creating the empty `claude.failed` marker.
2. Across the three affected rounds, `claude.json` contains a structurally complete result envelope with `is_error: false` and a parseable `result` field; `bin/review-gate`'s `extract_json` path successfully parsed each into a verdict (round 1: PASS extraction logged in `cerberus.log`).
3. `duration_api_ms` (Anthropic API time as reported by the Claude CLI) ranged from 92.8s to 279.7s; the remaining 1,520–1,707 seconds elapsed between API completion and `timeout(1)` SIGTERM.
4. The arithmetic difference `1,800,000 - duration_ms` for rounds 2/3/4 is 355 / 291 / 281 ms.
5. The `claude.failed` marker takes precedence over the parsed verdict in the gate-state rendering: rendered output for the three affected rounds was `ERROR | Reviewer process failed` while the JSON contained complete reviewer findings (rounds 2 and 3: `NEEDS_WORK` with substantive findings text; round 4: `PASS` with one P3 finding).
6. The session's overall consensus was computed from the two reviewers (codex, gemini) whose `.done` markers were present; the claude verdicts were not incorporated into consensus in rounds 2, 3, or 4.

## Affected Files

| Path | Role |
|------|------|
| `/Users/cyou/code/cerberus/bin/review-gate-models.sh` | Reviewer spawn, timeout wrapper, `.failed` marker creation |
| `/Users/cyou/code/cerberus/bin/review-gate` | Gate-state rendering (multiple `.failed` reads) |
| `/Users/cyou/code/cerberus/bin/review-gate-hook.sh` | Stop-hook-side gate-state rendering |
| `/Users/cyou/.claude/projects/-Users-cyou-code-cerberus/cerberus/3d2c009f-59a4-40c1-95cd-c57c49e4637a/reviews-iter-1/claude.{json,failed}` | Round 2 evidence |
| `/Users/cyou/.claude/projects/-Users-cyou-code-cerberus/cerberus/3d2c009f-59a4-40c1-95cd-c57c49e4637a/reviews-iter-2/claude.{json,failed}` | Round 3 evidence |
| `/Users/cyou/.claude/projects/-Users-cyou-code-cerberus/cerberus/3d2c009f-59a4-40c1-95cd-c57c49e4637a/reviews/claude.{json,failed}` | Round 4 evidence |
| `/Users/cyou/.claude/projects/-Users-cyou-code-cerberus/cerberus/3d2c009f-59a4-40c1-95cd-c57c49e4637a/cerberus.log` | Per-round `extract_json claude SUCCESS verdict=…` log lines |

## Open Questions for Investigation

1. What process(es) inside the `claude -p --output-format json` invocation remain alive between API completion (`stop_reason=end_turn`) and SIGTERM at the deadline?
2. Why did round 1 of the same session exit cleanly while rounds 2, 3, 4 did not?
3. Should the gate-state rendering treat `${reviewer}.json` containing a parseable `verdict` as authoritative when `${reviewer}.failed` is also present (as occurs after a `timeout(1)` kill)?
4. Should `REVIEW_FAIL` be conditional on `claude.json` being unparseable rather than on the wrapped command's exit code alone?
