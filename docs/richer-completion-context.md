# Richer Completion Context for Review Gate

## Overview

Enhance the review gate stop hook to provide Claude with richer context when reviews complete, whether by unanimous PASS or by reaching max iterations. On PASS, surface P2/P3 informational findings for user awareness. On max iterations, auto-resolve to proceed after presenting remaining issues, avoiding manual intervention.

## Goals

- When all reviewers PASS, include P2/P3 findings from all reviewers in an "Informational Items" section so Claude can summarize them for the user
- When max iterations is reached without consensus, present remaining P0/P1 issues to Claude, auto-resolve to proceed, and allow Claude to stop
- Track auto-resolved max-iteration cases distinctly in gate-state.json as `auto_proceed_max_iter` for audit purposes
- Apply consistent behavior across all review types (code, plan, spec)

## Non-Goals (Out of Scope)

- Changing the PASS/FAIL/NEEDS_WORK verdict logic
- Modifying how reviewers generate or prioritize findings
- Adding iteration history or "what was fixed" summaries
- Providing recommendations on whether to proceed or abort (just surface the issues)
- Changes to the "unblock-then-reprompt" flow for revision cycles (separate feature)

## User Stories

- As a developer, I want to see P2/P3 suggestions even when reviews pass, so I'm aware of improvement opportunities without having to dig through reviewer outputs
- As a developer, I want max-iteration reviews to auto-resolve and stop, so I'm not blocked waiting for manual intervention when the review gate times out
- As a system auditor, I want to distinguish auto-resolved max-iteration cases from explicit user decisions, so I can track review gate behavior accurately

## Technical Design

### Architecture

This feature modifies the stop hook logic in `bin/review-gate-hook.sh`. The main changes are:
1. New function `collect_informational_findings()` to gather P2/P3 findings from all reviewers
2. Modified PASS block to include informational findings in the prompt
3. Modified max-iterations block to auto-resolve with `auto_proceed_max_iter` reason
4. Updated state file schema to support new decision reason

### Key Components

- **`collect_informational_findings()`**: New function in `review-gate-hook.sh` that extracts P2/P3 findings from all reviewer outputs, regardless of verdict. Returns formatted markdown section.

- **Modified `auto_approve` block (line ~869-886)**: Currently prompts Claude with basic "All reviewers agree (PASS)" message. Will add informational findings section before allowing stop.

- **Modified max-iterations block (line ~889-907)**: Currently blocks with manual resolve instructions. Will auto-resolve to proceed and prompt Claude with remaining issues summary, then allow stop.

- **gate-state.json schema**: Add `auto_proceed_max_iter` as valid decision reason alongside existing `proceed`, `revise`, `abort`.

### Data Model

State file decision object extended:
```json
{
  "decision": {
    "action": "proceed",
    "decided_at": "2025-12-30T12:00:00Z",
    "reason": "auto_proceed_max_iter"  // New: distinguishes from manual "proceed"
  }
}
```

### API Design

No CLI API changes. Internal function signature:

```bash
collect_informational_findings() -> string  # Returns markdown section or empty
```

## User Experience

### Primary Flow (PASS with P2/P3)

1. All reviewers return PASS verdict
2. Stop hook collects P2/P3 findings from all reviewers
3. Hook prompts Claude with:
   ```
   ## Review Results
   [verdict table]

   ---

   ## Review Complete

   **All reviewers agree (PASS).**

   ## Informational Items (P2/P3)

   The following non-blocking items were noted for your awareness:

   ### codex
   - [P2] Consider extracting helper function
   - [P3] Variable naming could be clearer

   ### gemini
   - [P2] Add error handling for edge case

   Please summarize the review outcome, mentioning any informational items the user should be aware of.
   ```
4. Claude summarizes for user, then stops

### Primary Flow (Max Iterations Reached)

1. Review reaches max iterations without consensus
2. Stop hook collects remaining P0/P1 issues from non-PASS reviewers
3. Hook auto-resolves gate with `reason: "auto_proceed_max_iter"`
4. Hook prompts Claude with:
   ```
   ## Review Results
   [verdict table]

   ---

   ## Max Iterations Reached

   **Max iterations (3) reached without consensus.** The gate has been auto-resolved to proceed.

   ### Remaining Issues (P0/P1)

   #### codex (FAIL)
   Summary: Missing error handling for null case
   Findings:
   - [P1] Handle null return from API call

   #### gemini (NEEDS_WORK)
   Summary: Security concern with input validation
   Findings:
   - [P1] Validate user input before SQL query

   Please summarize the review outcome, noting that max iterations was reached and listing the unresolved issues.
   ```
5. Claude summarizes for user, then stops (gate already resolved)

### Error States

- **No P2/P3 findings on PASS**: Informational section is omitted; behavior matches current flow
- **No reviewers completed**: Current behavior (auto-resolve with `no_reviewers` reason) unchanged
- **Parse errors in reviewer output**: Findings skipped for that reviewer; logged but not surfaced

### Edge Cases

- **All PASS but some have P2/P3**: Include P2/P3 from all PASS reviewers
- **Mixed verdicts on max iterations**: Include P0/P1 from non-PASS reviewers only (PASS reviewers already approved)
- **Reviewer returned UNCLEAR**: Skip that reviewer's findings; note in logs

## Implementation Plan

1. [x] Add `collect_informational_findings()` function to `bin/review-gate-hook.sh`
   - Extract P2/P3 findings from all reviewers
   - Format as markdown section with reviewer headings
   - Return empty string if no P2/P3 findings

2. [x] Modify PASS block (~line 869-886) to include informational findings
   - Call `collect_informational_findings()`
   - Append to `SUMMARY_PROMPT` if non-empty
   - Update prompt text to mention informational items

3. [x] Modify max-iterations block (~line 889-907) to auto-resolve
   - Auto-resolve gate with `reason: "auto_proceed_max_iter"` before prompting
   - Change from `output_block` to `output_block` with prompt that allows stop on next hook run
   - Actually: need to resolve first, THEN prompt (use `output_block` but gate is resolved)

4. [x] Update `review_gate_resolve()` to accept reason parameter
   - Add optional `--reason` flag or use env var
   - Write reason to state file

5. [ ] Test PASS flow with P2/P3 findings
   - Verify informational section appears
   - Verify Claude can stop after prompting

6. [ ] Test max-iterations flow
   - Verify auto-resolve happens
   - Verify remaining issues are surfaced
   - Verify `auto_proceed_max_iter` is recorded

7. [x] Update documentation (README.md) to describe new behavior

## Testing Strategy

- **Unit tests**:
  - `collect_informational_findings()` with various reviewer outputs (all PASS, mixed, no P2/P3)
  - Decision reason persisted correctly in state file

- **Integration tests**:
  - End-to-end PASS flow with P2/P3 reviewers
  - End-to-end max-iterations flow with auto-resolve

- **Manual testing**:
  - Run `/cerberus:review-code` with changes that produce P2/P3
  - Trigger max iterations by having persistent P1 issue
  - Verify Claude receives and summarizes context correctly

## Open Questions

None - all key decisions made during scoping interview.

## Decisions Made

- **P2/P3 on PASS**: Include as "Informational Items" section with per-reviewer breakdown - for developer awareness
- **Max iterations behavior**: Auto-resolve to proceed after prompting Claude with remaining issues - reduces friction
- **Decision reason tracking**: Use `auto_proceed_max_iter` to distinguish from manual proceed - for audit trail
- **Scope**: Apply to all review types (code, plan, spec) - for consistency
- **P2/P3 source**: Collect from all reviewers regardless of verdict - ensures nothing is missed
