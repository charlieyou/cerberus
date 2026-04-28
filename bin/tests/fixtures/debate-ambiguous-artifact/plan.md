# Plan: ambiguous notification subsystem

## Steps

1. Build a notification subsystem that "behaves reasonably" under
   adverse conditions.
2. Cover the common error cases.
3. Ship with reasonable default settings.

## Notes

- Performance must be "good enough" for typical workloads.
- Failure modes are out of scope for this iteration but should still be
  "handled gracefully" where possible.
- Ownership of the retry policy is "TBD"; the team will decide later
  whether retries are caller-driven or subsystem-driven.

## Open Questions

- What is the SLO for delivery latency?
- Is at-least-once or at-most-once delivery expected?
- Should the subsystem expose backpressure to callers?
