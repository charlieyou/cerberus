# Per-reviewer Debate Golden JSONs (AC-8)

These fixtures are the byte-equal golden references for the additive `--debate`
fields on per-reviewer JSONs (`reviews/<reviewer>.json`):

- `overall_confidence` (top-level)
- `findings[*].confidence`
- `strategy`
- `round`
- `peer_responses_seen`

They sit alongside the existing R1 / R3 / R6 fixtures in `bin/tests/fixtures/`
and are asserted byte-equal by `bin/tests/test-debate-per-reviewer-golden.sh`
so any future schema drift across reviewer providers (Claude / Codex / Gemini)
or across feature changes is caught at test time rather than at runtime.

## Files

| File                   | Provider | Round | Notes                                                                |
|------------------------|----------|-------|----------------------------------------------------------------------|
| `claude-round1.json`   | claude   | 1     | Cold round-1 output — `peer_responses_seen` is `[]`                  |
| `claude-round2.json`   | claude   | 2     | Verification-first round-2 output with two peer ids in the array      |
| `codex-round2.json`    | codex    | 2     | Falsification-first round-2 output with the same peer ids             |
| `gemini-round2.json`   | gemini   | 2     | Decompose round-2 output; PASS with empty findings                    |

## What the test asserts

- The on-disk bytes of each file are byte-equal to the in-test reference (the
  test reads the file once and re-reads it and asserts `cmp -s`). This pins the
  exact byte representation so any future formatter or template change is
  flagged.
- The structural shape conforms to the debate schema variant defined in
  `bin/review-gate-models.sh::_emit_review_schema "true"`: every additive field
  is present, `findings[*].confidence` is present when any finding is present,
  and there are no extraneous keys.

## Why a separate fixture directory rather than r6-dedup

The r6-dedup fixtures encode aggregator inputs (named `augmented[*]`) and the
expected `aggregate.json` output. They do NOT cover the on-disk shape of the
per-reviewer JSON the Stop-hook reads back from `reviews/<reviewer>.json`. The
spec's Launch checklist line at `docs/2026-04-25-debate-spec.md:419` calls out
golden JSONs for `peer_responses_seen` specifically, which is a per-reviewer
field that never appears in `aggregate.json`. Putting the fixtures here keeps
the per-reviewer surface separate from the aggregate surface.
