# debate-abstain-artifact (vibes-check fixture)

This fixture is the second of the two **vibes-check fixtures** named in
the launch checklist. Manual inspection only — no automated assertion
in v1.

## Purpose

Exercises the terminal-abstention path under a controlled abstention.
One reviewer is configured to always abstain (e.g., via a mock CLI that
returns unparseable JSON, or a `.failed` sentinel from a deliberately
crashing wrapper). The surviving reviewers must:

- NOT fabricate phantom peer findings (the abstained slot surfaces as
  `(peer abstained)` in the Round-2 anonymized peer block — surviving
  reviewers must not invent a Round-1 verdict or findings for the
  abstained peer in their own Round-2 output).
- Either reference the abstain in their Round-2 reasoning, OR remain
  stable from Round 1 (i.e., no spurious confidence shifts driven by
  the absent peer's nonexistent Round-1 evidence).

## Files

- `plan.md` — the artifact under review (a tiny plan; the content does
  not matter, the test condition is the abstain behavior).
- `mock-abstain.sh` — a reference mock CLI script that always emits
  unparseable output (forcing Mode A abstain). Operators can wire this
  into a manual smoke run by setting `PATH` so the chosen reviewer's
  CLI resolves to this script.

## Manual inspection signal

After running `bin/review-gate spawn-plan-review --debate plan.md` with
the mock-abstain CLI on PATH for one reviewer:

1. Confirm the abstained reviewer surfaces as `(peer abstained)` in
   the surviving reviewers' Round-2 prompts.
2. Read the surviving reviewers' Round-2 outputs. Their reasoning must
   NOT cite peer evidence that does not exist (no fabricated quotes
   from the abstained peer; no claims about the abstained peer's
   verdict). Acceptable patterns include:
   - Round-2 output explicitly references the abstain ("the third
     reviewer abstained, so I am keeping my Round-1 position").
   - Round-2 output is materially identical to Round-1 (no shift
     driven by phantom peer evidence).

## Why no automated assertion

Detecting "phantom peer findings" automatically requires either a
strong NLI classifier or a per-finding cross-check that would itself
be flaky against real models. The vibes-check fixture is part of the
maintainer's release-gate eyeball, not the v1 CI surface.
