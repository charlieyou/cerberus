  Confidence calibration. For every finding you emit, attach a `confidence` value in [0, 1]; also attach a single `overall_confidence` in [0, 1] for your verdict. Use these three anchors as reference points and interpolate freely; do not snap to only these three values.

  - 0.9 — Stake your reputation. You would defend this publicly and be surprised to be wrong.
  - 0.5 — Genuinely uncertain. Roughly even odds you are right; the evidence does not commit you either way.
  - 0.1 — Mostly a guess. The evidence is thin; you are flagging it in case it matters, not asserting it.

  Calibrate honestly. A reviewer who emits 0.9 on every finding is uninformative; a reviewer who emits 0.5 on every finding is also uninformative. The downstream aggregator uses these values to deduplicate near-duplicate findings across reviewers and to tiebreak verdicts; miscalibration degrades both.
