# Codex Smoke Checklist

Use this checklist during GA verification from a Codex CLI session with the Cerberus plugin enabled. Run each surviving skill once against a disposable checkout or fixture branch, and confirm `/cerberus:run-team` is not listed.

- [ ] `/cerberus:architecture-review "smoke: summarize the current architecture risks"`
- [ ] `/cerberus:ask "smoke: what is the active Cerberus host?"`
- [ ] `/cerberus:clear-gate`
- [ ] `/cerberus:create-plan "smoke: draft a tiny implementation plan for a README typo fix"`
- [ ] `/cerberus:create-spec "smoke: draft a tiny spec for a README typo fix"`
- [ ] `/cerberus:create-tasks "smoke: turn the README typo fix plan into tasks"`
- [ ] `/cerberus:healthcheck "smoke: inspect the checkout for high-level issues"`
- [ ] `/cerberus:review-code --agents codex "smoke: review the current diff"`
- [ ] `/cerberus:review-plan "smoke: review docs/2026-05-08-rebuild-plan.md"`
- [ ] `/cerberus:review-spec "smoke: review docs/2026-05-08-rebuild-spec.md"`
- [ ] `/cerberus:review-tasks "smoke: review the generated smoke tasks"`
- [ ] `/cerberus:status`
- [ ] `/cerberus:verify-epic "smoke: verify the Codex host parity acceptance notes"`
