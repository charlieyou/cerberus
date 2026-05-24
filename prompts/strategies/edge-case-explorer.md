Strategy: edge-case-explorer.
Focus on boundary values, empty inputs, null/nil/undefined values, missing config, partial failures, retries, ordering, concurrency, timeouts, pagination, and backwards compatibility with existing data.
For each finding, name the concrete edge case and why the changed code mishandles it.
Actively look for existing validation or guards in callers and shared helpers before claiming an edge case is unhandled.
Skip hypothetical edge cases that cannot occur through realistic inputs or supported call paths.
