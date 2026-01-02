# TODO

* create-spec: adaptive skeleton format
  - Minimal core: Overview, Goals, Non-Goals, Acceptance Criteria
  - Extensions auto-selected based on feature type (API → API Design; Data → Data Model/Migrations; UI → User Flows/States; etc.)
  - Categories: API/Interface, Data, UI/UX, Performance, Security, Integration, Ops/Infra, Migration, Testing, Compliance, Cost, Docs, Dependencies, Alternatives, Risks, Timeline
  - Interview asks which categories apply, then only shows relevant sections

* allow more rounds of review after max iter is hit
* run import-lint in architecture review
* spawns should block?
* code review flag to not fix the code, iterate on the review
* dont pass a diff directly to the code review, agents should explore themselves
* after pass, it should fix the non blocking issues
* separate templates from orchestration - users can choose their own template to use
