# Spec Creation (Generator)

**IMPORTANT: This is a READ-ONLY task. Do NOT modify any files. Only analyze the provided context and draft a spec.**

You are a generator producing a complete feature specification from the context appended below.

## Requirements

1. **Output only the spec markdown** (no preamble or analysis).
2. Use the exact template structure below.
3. If details are missing or ambiguous, list them in **Open Questions** instead of inventing.
4. Keep scope explicit: include clear **Goals** and **Non-Goals**.
5. Reference existing codebase structure when provided (files, modules, patterns).
6. **Acceptance Criteria must be concrete and testable** - write them as "Given X, when Y, then Z" statements.
7. **No implementation details** - do NOT include code snippets, line numbers, function signatures, data models, or test code. Keep descriptions at the spec level.

## What NOT to Include (Implementation Details)

A spec defines **what** to build and **why**, not **how**. Leave these for the implementation plan:

- ❌ Code snippets or pseudo-code
- ❌ Exact line numbers or line ranges in files
- ❌ Step-by-step implementation instructions
- ❌ Specific function signatures or method names
- ❌ Data models, schemas, or type definitions
- ❌ Test code examples
- ❌ "Before/After" code comparisons

Instead, use high-level descriptions:
- ✅ "Add a new event to the MalaEventSink protocol"
- ❌ "Add `def on_validation_started(self, agent_id: str) -> None:` at line 399"

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

## Acceptance Criteria
[Concrete, testable conditions. Focus on observable behavior, not test implementation.]

- Given [precondition], when [action], then [expected result]
- [Performance/reliability/UX criteria where relevant]

## Technical Context

### Architecture
[High-level description of how this fits into the existing codebase. Reference patterns, modules, and concepts—not specific code changes.]

### Key Components
[List logical components or systems involved, with their purpose. No function names or signatures.]

- [Component 1]: [purpose and responsibility]
- [Component 2]: [purpose and responsibility]

### Integration Points
- [Existing system/service]: [how this feature interacts with it]
- [External dependency]: [usage and failure handling]

## User Experience

### Primary Flow
1. [Step 1]
2. [Step 2]
3. [Step 3]

### Error States
- [Error scenario]: [How it's handled]

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
