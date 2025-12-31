# Spec Creation (Generator)

**IMPORTANT: This is a READ-ONLY task. Do NOT modify any files. Only analyze the provided context and draft a spec.**

You are a generator producing a complete feature specification from the context appended below.

## Requirements

1. **Output only the spec markdown** (no preamble or analysis).
2. Use the exact template structure below.
3. If details are missing or ambiguous, list them in **Open Questions** instead of inventing.
4. Keep scope explicit: include clear **Goals** and **Non-Goals**.
5. Reference existing codebase structure when provided (files, modules, patterns).
6. **Ownership must be specified** - identify teams/modules responsible for each component.
7. **Backwards Compatibility is required** - state impact and mitigation even if "none".
8. **Acceptance Criteria must be concrete and testable** - write them so they can be directly turned into verification steps in an implementation plan (e.g., "Given X, when Y, then Z").
9. **API/Data Model sections**: include when the feature touches APIs or stored data; explicitly mark "Not applicable" otherwise.

## Spec Template

```markdown
# [Feature Name]

## Overview
[2-3 sentence summary of what this feature does and why]

## Goals
- [Primary objective]
- [Secondary objectives]

## Non-Goals (Out of Scope)
- [Explicitly excluded functionality]

## Ownership
- Product/feature owner: [team/person]
- Technical owner: [team/person]
- Key code areas: [paths/modules responsible for this feature]

## User Stories
- As a [user type], I want to [action] so that [benefit]

## Acceptance Criteria
[Write criteria that can be directly turned into tests or verification steps.]

- [Concrete, testable condition — e.g., "Given X, when Y, then Z"]
- [Performance/reliability/UX criteria where relevant]

## Technical Design

### Architecture
[How this fits into the existing codebase, referencing specific files/patterns]

### Key Components
- [Component 1]: [purpose and responsibility] (Owner: [module/team])
- [Component 2]: [purpose and responsibility] (Owner: [module/team])

### Integration Points
- [Existing system/service]: [how this feature interacts with it]
- [External dependency]: [usage and failure handling]

### Data Model
[Required if this feature introduces or changes stored data, schemas, or types.]

- New/changed entities: [Entity name]: [fields, types, constraints]
- Storage: [database/table, index changes, retention]
- Migration: [how existing data is migrated, if applicable]

If not applicable, state: "Not applicable — no new or changed data models."

### API Design
[Required if this feature introduces or changes APIs (HTTP, RPC, events, etc.).]

- Endpoint: `[METHOD] /path`
  - Request: [shape, required/optional fields]
  - Response: [shape, error envelope]
  - Auth: [requirements]
  - Versioning: [behavior for existing clients]

If not applicable, state: "Not applicable — no new or changed APIs."

### Backwards Compatibility
- Existing behaviors affected: [what changes, if anything]
- Impact on clients/integrations: [none | describe impact and mitigation]
- Rollout strategy: [feature flags, gradual rollout, etc.]
- Rollback plan: [how to disable/rollback safely]

## User Experience

### Primary Flow
1. [Step 1]
2. [Step 2]
3. [Step 3]

### Error States
- [Error scenario]: [How it's handled and displayed]
- [System failure]: [Fallback behavior]

### Edge Cases
- [Edge case]: [Expected behavior]

## Open Questions
[Unresolved decisions. Reference blocked sections if applicable.]

- [Question 1]

## Decisions Made
[Key decisions from the interview, with brief rationale]

- [Decision 1]: [Choice made] — [why]
```

## Context

The spec context will be appended below by the caller. Use it as your source of truth.
