# debate-bad-artifact (falsifiable-acceptance launch-gate fixture)

This fixture supports the v1 launch gate for `--debate`: the falsifiable-
acceptance two-clause assertion in
`bin/tests/test-debate-end-to-end.sh::test_falsifiable_acceptance_two_clause`.

## Files

- `service.py` — a small Python module containing one **planted P1
  defect** (a hardcoded credential in `login()` at lines 12-18).
- `defect-location.json` — a stable record of the planted defect's exact
  `file_path`, `line_start`, `line_end`. The integration test reads this
  file to know where to look in the reviewer JSONs and the final
  `aggregate.json`.
- `plan.md` — a tiny plan document used as the `spawn-plan-review`
  artifact for the falsifiable-acceptance scenario. The plan deliberately
  references `service.py` so the fake reviewers have an excuse to flag
  the planted defect.

## Two-clause assertion (anti-vacuous)

The two-clause form is deliberately not a single ∀-quantified statement
that could be vacuously satisfied if no Round-1 P1 ever raises at the
planted location:

- **Clause 1 (existence in Round 1):** at least one reviewer's Round-1
  output contains a P1 finding F with `F.file_path` equal to the planted
  file_path and `F.line_start`/`F.line_end` overlapping the planted
  range. Prevents vacuous pass when no reviewer raises the defect cold.
- **Clause 2 (retention in final-round aggregate):**
  `aggregate.json.findings[]` contains a finding F' with `F'.priority ==
  "P1"`, `F'.confidence >= 0.7`, `F'.file_path` matching, and
  `F'.line_start`/`F'.line_end` overlapping the planted range. Closes
  the no-op-Round-2 loophole — a Round 2 that drops the planted P1 and
  emits any unrelated P1 elsewhere with confidence ≥ 0.7 must NOT pass.

If Clause 1 ever fails on a real model run, tune the fixture or the
reviewer prompts/strategies until at least one reviewer raises the
planted defect cold. The integration test under
`test-debate-end-to-end.sh` runs against canned fake CLIs that emit the
planted finding deterministically; a real-model run is part of the
manual launch-checklist verification.
