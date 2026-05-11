# TODO

## Priorities
* Rewrite in Go, native Codex support
* Support arbitrary model mixes w/ different prompts

## Other

* Add strict mode where only passes if no feedback at all

* add /constitution command (from Spec Kit)
  - Create/update project principles at `/memory/constitution.md`
  - Non-negotiable constraints that gate planning (e.g., "max 3 services", "no ORMs", "100% API test coverage")
  - MUST/SHOULD language, semantic versioning for changes
  - Constitution Check section in create-plan that blocks on violations
  - Propagate principle changes across templates
  - Prevents: agent creativity creep, architectural drift, forgotten constraints

Task review should use multi-models
* add /analyze command (from Spec Kit)
  - Read-only consistency audit across spec/plan/tasks before implementation
  - Detection passes: duplication, ambiguity, underspecification, constitution violations, coverage gaps, inconsistency
  - Severity levels: CRITICAL (constitution violations, zero coverage) → HIGH → MEDIUM → LOW
  - Output: findings table, coverage summary, metrics, next actions
  - Offers remediation suggestions but doesn't auto-apply
  - Prevents: implementing wrong thing, coverage gaps, artifact drift, terminology inconsistency

* create-spec: adaptive skeleton format
  - Minimal core: Overview, Goals, Non-Goals, Acceptance Criteria
  - Extensions auto-selected based on feature type (API → API Design; Data → Data Model/Migrations; UI → User Flows/States; etc.)
  - Categories: API/Interface, Data, UI/UX, Performance, Security, Integration, Ops/Infra, Migration, Testing, Compliance, Cost, Docs, Dependencies, Alternatives, Risks, Timeline
  - Interview asks which categories apply, then only shows relevant sections

* run import-lint in architecture review

## Spec/Plan Generation

* separate templates from orchestration - users can choose their own template to use
* Instruct to use subagents to save context for exploration


## All Reviews

* allow more rounds of review after max iter is hit

## Code Review

* dont pass a diff directly to the code review, agents should explore themselves?
* x2!

## Task gen + review

* add the spec/plan link into every issue

## Run Team

* Cursor-style continuous planning

* Or just next task ahead planning?

* Block dangerous commands in implementers
* Persist P2/P3 review issues
* Config-driven validation, more triggers
* File locking + enable parallel implementers

## v2.x Backlog

* **D8 - Strategy / mode rotation across rounds.** Keep v2.0 fixed to one strategy per reviewer for the whole run; revisit per-round rotation after GA. Source: [spec D8](docs/2026-05-08-rebuild-spec.md#L335), [plan out of scope](docs/2026-05-08-rebuild-plan.md#L43).
* **Q14 - K* / alpha-K telemetry.** Evaluate whether to compute effective-channel-count diagnostics as v2.x telemetry, not a v2.0 feature. Source: [spec Q14](docs/2026-05-08-rebuild-spec.md#L347), [plan Q14](docs/2026-05-08-rebuild-plan.md#L909).
* **Q15 - Debate sparsification.** Revisit CortexDebate / S2-MAD-style sparsified communication after the v2.0 parity surface ships. Source: [spec Q15](docs/2026-05-08-rebuild-spec.md#L348), [plan Q15](docs/2026-05-08-rebuild-plan.md#L910).
* **OQ-Plan-4 - Concurrent runs in the same project.** Add advisory-lock infrastructure if users regularly hit `gate-state.json` clobbering. Source: [plan OQ-Plan-4](docs/2026-05-08-rebuild-plan.md#L914).
* **OQ-Plan-5 - Anonymization sophistication.** Replace the heuristic free-text scrub with a more linguistically aware scrub if debate runs show sycophancy drift. Source: [plan OQ-Plan-5](docs/2026-05-08-rebuild-plan.md#L915).
* **OQ-Plan-6 - update-plugin replacement ergonomics.** Consider a `cerberus dev install` maintainer workflow if `make install` creates friction. Source: [plan OQ-Plan-6](docs/2026-05-08-rebuild-plan.md#L916).

## Debate

* Can specify multiple of one model, or arbitrary mix
