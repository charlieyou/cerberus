# TODO

* Architecture review tooling:
   - Run lizard/grimp (and future analyzers) outside the model in the command layer.
   - Inject tool outputs into the generator prompt instead of granting model shell access.
   - Decide on flags/config for opt-in tool runs and document expectations.

* Handle malformed reviewer output more robustly:
   - Gemini sometimes returns prose instead of JSON even with `-o json`, causing UNCLEAR verdict
   - Try extracting JSON from within prose responses (regex for `{...}` blocks)
   - Auto-retry reviewer on parse failure before marking as UNCLEAR
   - Distinguish "reviewer failed" from "reviewer returned unparseable output"

* plan generation mode

* spawns should not exit immediately

* code review flag to not fix the code, iterate on the review
