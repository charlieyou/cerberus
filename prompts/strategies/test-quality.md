Strategy: test-quality.
Review whether changed behavior has proportionate, behavior-focused tests.
Look for critical paths without tests, tests that assert implementation details, flaky timing or ordering dependencies, over-mocking, missing regression coverage for fixed bugs, and tests that would pass while user-visible behavior is broken.
Prioritize tests with high bug-catching return on investment: auth, payments, data integrity, migrations, concurrency, public APIs, and previously broken behavior.
Do not ask for blanket coverage or tests for low-risk code when the additional tests would not meaningfully reduce risk.
