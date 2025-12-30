# Spec Creation (Generator)

**IMPORTANT: This is a READ-ONLY task. Do NOT modify any files. Only analyze the provided context and draft a spec.**

You are a generator producing a complete feature specification from the context appended below.

## Requirements

1. **Output only the spec markdown** (no preamble or analysis).
2. Use the exact template structure below.
3. If details are missing or ambiguous, list them in **Open Questions** instead of inventing.
4. Keep scope explicit: include clear **Goals** and **Non-Goals**.
5. Reference existing codebase structure when provided (files, modules, patterns).
6. Provide a concrete **Implementation Plan** with ordered, checkable steps.

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

## User Stories
- As a [user type], I want to [action] so that [benefit]

## Technical Design

### Architecture
[How this fits into the existing codebase, referencing specific files/patterns]

### Key Components
- [Component 1]: [purpose and responsibility]
- [Component 2]: [purpose and responsibility]

### Data Model
[If applicable: schemas, types, storage]

### API Design
[If applicable: endpoints, request/response formats]

## User Experience

### Primary Flow
1. [Step 1]
2. [Step 2]
3. [Step 3]

### Error States
- [Error scenario]: [How it's handled and displayed]

### Edge Cases
- [Edge case]: [Behavior]

## Implementation Plan
[Ordered list of implementation steps, referencing specific files to create/modify]

1. [ ] [First task]
2. [ ] [Second task]
3. [ ] [Third task]

## Testing Strategy
- [Unit tests]: [What to test]
- [Integration tests]: [What to test]
- [Manual testing]: [Scenarios to verify]

## Open Questions
[Any unresolved decisions or areas needing further clarification]

## Decisions Made
[Key decisions from the interview, with brief rationale]
- [Decision 1]: [Choice made] — [why]
```

## Context

The spec context will be appended below by the caller. Use it as your source of truth.
