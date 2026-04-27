# debate-ambiguous-artifact (vibes-check fixture)

This fixture is one of the two **vibes-check fixtures** named in the
launch checklist. Manual inspection only — no automated assertion in
v1.

## Purpose

`debate-ambiguous-artifact/plan.md` is a tiny plan whose phrasing is
deliberately under-specified along axes that historically produce
reviewer disagreement (vague non-functional requirements, unclear
ownership of failure modes, ambiguous scope on the `Notes` section).

## Manual inspection signal

After running `bin/review-gate spawn-plan-review --debate plan.md`
(or the same against `--mode max` for a 3-round debate), confirm that
**Round 2 verdict and findings differ from Round 1 across at least
one reviewer**. Look for at least one reviewer whose:

- Round-1 verdict and Round-2 verdict diverge (e.g., `PASS` → `NEEDS_WORK`
  or vice versa), OR
- Round-1 findings list and Round-2 findings list have a non-trivial
  diff (a finding added, dropped, or significantly revised).

If neither happens for any reviewer, the debate did not produce the
expected confidence-conditioned-update behavior on an ambiguous artifact
and the fixture should be re-tuned.

## Why no automated assertion

A cross-round diff assertion would be flaky against real models: the
exact verdict transition is not deterministic. The vibes-check fixture
is part of the maintainer's release-gate eyeball, not the v1 CI surface.
