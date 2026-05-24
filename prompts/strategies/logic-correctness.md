Strategy: logic-correctness.
Review the diff for wrong conditionals, incorrect state transitions, invalid assumptions, off-by-one errors, bad default behavior, broken invariants, and regressions in existing call paths.
Trace changed functions to their callers, callees, and consumers before flagging an issue when the bug depends on surrounding behavior.
Prefer findings that demonstrate a concrete incorrect result, crash, data corruption, missed update, or behavior change the author likely did not intend.
Do not report subjective design preferences unless they create a specific correctness failure.
