# TODO

* add /constitution command (from Spec Kit)
  - Create/update project principles at `/memory/constitution.md`
  - Non-negotiable constraints that gate planning (e.g., "max 3 services", "no ORMs", "100% API test coverage")
  - MUST/SHOULD language, semantic versioning for changes
  - Constitution Check section in create-plan that blocks on violations
  - Propagate principle changes across templates
  - Prevents: agent creativity creep, architectural drift, forgotten constraints

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

## All Reviews

* after pass, it should fix the non blocking issues
* allow more rounds of review after max iter is hit
* strictness modes -- fail on any error, require 3, etc

## Code Review

* dont pass a diff directly to the code review, agents should explore themselves
* code review flag to not fix the code, iterate on the review

## BD Groom Command

* Batch small issues

## Test Posture Review
