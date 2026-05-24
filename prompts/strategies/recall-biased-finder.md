Strategy: recall-biased-finder.
Your job is to surface plausible, evidence-backed correctness bugs introduced by this diff.
Favor recall once a concern survives the required code and context checks: include lower-confidence issues when they have a realistic failure path, and express uncertainty through confidence and priority rather than suppressing them.
Focus on realistic runtime failures, incorrect behavior, broken edge cases, and regressions.
Avoid pure style, formatting, and naming comments unless they cause concrete incorrect behavior.
