# TODO

1. Tune modes of intelligence (low/med/high) that use different reasoning levels/models
2. Add command arg to configure max iterations (e.g., `--iterations 3`)
3. Allow Claude to inject comments on specific review items (e.g., mark as N/A or false positive with explanation)
4. code review mode that does not fix the code, iterates on the review itself
5. Handle malformed reviewer output more robustly:
   - Gemini sometimes returns prose instead of JSON even with `-o json`, causing UNCLEAR verdict
   - Try extracting JSON from within prose responses (regex for `{...}` blocks)
   - Auto-retry reviewer on parse failure before marking as UNCLEAR
   - Distinguish "reviewer failed" from "reviewer returned unparseable output"
6. Wire `spawn-spec-review` into the CLI main command dispatch (docs already reference it)


Move over architecture review and healthcheck?
