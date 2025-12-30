# TODO

* Handle malformed reviewer output more robustly:
   - Gemini sometimes returns prose instead of JSON even with `-o json`, causing UNCLEAR verdict
   - Try extracting JSON from within prose responses (regex for `{...}` blocks)
   - Auto-retry reviewer on parse failure before marking as UNCLEAR
   - Distinguish "reviewer failed" from "reviewer returned unparseable output"

* plan generation mode
