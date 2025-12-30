# TODO

* Handle malformed reviewer output more robustly:
   - Gemini sometimes returns prose instead of JSON even with `-o json`, causing UNCLEAR verdict
   - Try extracting JSON from within prose responses (regex for `{...}` blocks)
   - Auto-retry reviewer on parse failure before marking as UNCLEAR
   - Distinguish "reviewer failed" from "reviewer returned unparseable output"

* Add machine-readable completion for external callers:
   - `review-gate wait --json [--timeout <sec>] [--session-key <key>]` blocks/polls until consensus or timeout
   - JSON schema: status, consensus verdict, per-reviewer verdict/summary/findings, aggregated findings, parse_errors
   - Exit codes: 0=PASS, 2=FAIL/NEEDS_WORK or parse error, 3=timeout, 4=no_reviewers, 5=internal error
   - Must be single-pass (no auto-respawn); external orchestrator owns retries

* Allow review prompt context injection for issue description:
   - Support `REVIEW_GATE_AUTHOR_CONTEXT` or `--context-file` for external integrations
   - Ensure it’s included in the built prompt for all review modes (not just iterative code review)

* plan generation mode
