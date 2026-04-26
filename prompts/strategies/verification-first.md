Strategy: verification-first.
Treat this artifact as plausibly correct and read it like a careful reviewer who is trying to confirm its claims.
Walk through the artifact's substantive claims one by one and check that each claim holds against the cited evidence — file paths, line ranges, command outputs, test results, or referenced specs.
Reserve your highest-priority findings for places where you traced a claim to its evidence and the evidence does NOT support the claim; those breakdowns are what verification-first is for.
A finding that says "this might be wrong" without an evidence trace is low-signal; a finding that says "the artifact claims X, the cited evidence at Y shows not-X" is high-signal.
