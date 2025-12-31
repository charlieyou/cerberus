---
description: Interview the user to produce a feature spec, then run multi-model generator and spec review gate
argument-hint: [--mode <fast|smart|max>] <feature description>
---

# Create Spec (Interview + Multi-Model Generator)

Transform a vague feature idea into a complete, reviewable specification by combining codebase research, a targeted interview, multi-model generation, and a spec review gate.

## Mode Behavior

Modes control depth and rigor. Use soft budgets—exit early when quality is sufficient.

| Mode | Interview Depth | Review Rounds | Extras |
|------|-----------------|---------------|--------|
| fast | Until essentials filled (~60%) | 1 max | minimal |
| smart | Until ~80% filled | up to 2 | standard |
| max | Until ~95% filled + proactive probing | up to 3 | alternatives + risk analysis |

**Soft budget rules:**
- Stop interviewing when skeleton is sufficiently filled and essentials (Ownership, Acceptance Criteria, Backwards Compatibility) are covered
- In `fast`, prioritize speed over completeness—mark unknowns as Open Questions
- In `max`, actively probe for edge cases, alternatives, and risks even if user doesn't raise them

## Input

The user provides a brief feature description inline, e.g.:
- "add user authentication"
- "batch export functionality"
- "undo/redo for the editor"

## Workflow

### Phase 1: Codebase Research

Before asking any questions, understand the existing codebase:

1. Identify relevant areas (search for related files, modules, routes, or services)
2. Note existing conventions (naming, patterns, testing, error handling)
3. Find integration points and constraints
4. Capture key files you will reference in the spec
5. Identify existing ownership patterns (who owns related modules?)

Document findings internally—these inform the skeleton and your questions.

### Phase 1b: Draft Spec Skeleton

Create a skeleton of the spec with placeholders based on your research. This drives targeted interviewing.

```markdown
# [Feature Name]

## Overview
[TBD: 2-3 sentence summary]

## Goals
- [TBD: Primary objective]

## Non-Goals (Out of Scope)
- [TBD or inferred from research]

## Ownership
- Product/feature owner: [TBD]
- Technical owner: [TBD]
- Key code areas: [Pre-fill from research if known]

## User Stories
- [TBD]

## Acceptance Criteria
- [TBD: Concrete conditions]

## Technical Design

### Architecture
[Pre-fill with relevant files/patterns found in research, mark gaps as TBD]

### Key Components
- [TBD or pre-fill from research]

### Integration Points
- [Pre-fill known integrations from research]

### Data Model
[TBD or "Not applicable"]

### API Design
[TBD or "Not applicable"]

### Backwards Compatibility
- Existing behaviors affected: [TBD]
- Impact on clients/integrations: [TBD]
- Rollout strategy: [TBD]
- Rollback plan: [TBD]

## User Experience

### Primary Flow
[TBD]

### Error States
[TBD]

### Edge Cases
[TBD]

## Open Questions
- [List unknowns from research]

## Decisions Made
- [Record any obvious decisions from codebase conventions]
```

**Skeleton rules:**
- Pre-fill anything you can confidently infer from research
- Mark unknowns explicitly as `[TBD]` or `[TBD: hint about what's needed]`
- The skeleton drives Phase 2 questions—every TBD is a potential question

### Phase 2: Strategic Interviewing

Ask questions in batches, prioritized by importance. Put critical questions first so the user can stop answering when there's enough detail. Only ask what you cannot answer from the codebase.

**Interview from the skeleton:** Frame questions around filling TBD placeholders. Example: "The Acceptance Criteria section needs performance thresholds—here are options: [A] 200ms p99 latency, [B] best-effort, [C] you decide. Which?"

**Interview Principles**

1. **Propose, don't probe** — Offer concrete options with tradeoffs instead of open-ended questions
2. **Reference evidence** — "I see X in Y—should this follow the same approach?"
3. **Decide when delegated** — If user says "you decide," make a sensible choice and record it
4. **Cover gaps, not ground** — Skip questions the codebase already answers
5. **Map to template** — Every answer should fill a specific spec section

**Question Categories** (adapt order based on context):

#### Scope & Ownership
- What's the MVP vs. nice-to-have?
- What's explicitly out of scope?
- Who owns this feature? (team/person for product and technical decisions)
- Which existing modules will this live in or extend?

#### Acceptance Criteria
- What are the concrete conditions for "done"? (Given X, when Y, then Z)
- Are there performance thresholds? (latency, throughput, error rates)
- What would a failed acceptance look like?

#### User Experience
- Who uses this and in what context?
- What's the primary workflow/happy path?
- What feedback does the user need? (loading states, confirmations, errors)
- Are there accessibility requirements?

#### Technical Implementation
- Preferences on specific libraries, patterns, or approaches?
- Performance requirements or constraints?
- Data storage/persistence needs?
- API design preferences (if applicable)?

#### Backwards Compatibility & Rollout
- Are there existing clients/integrations that depend on affected code?
- What's the rollout strategy? (feature flag, gradual, big bang)
- What's the rollback plan if something goes wrong?
- Any data migrations required?

#### Edge Cases & Error Handling
- What happens when X fails?
- How should conflicts/race conditions be handled?
- What are the validation rules?
- Recovery and retry behavior?

#### Integration & Dependencies
- How does this interact with [existing system you found]?
- Does this affect [related feature you discovered]?
- Any external services or third-party APIs involved?

**Handling Common Responses**

| User says... | You should... |
|--------------|---------------|
| "You decide" | Make a reasonable choice, record in Decisions Made |
| "I don't know" | Propose 2-3 options with tradeoffs, ask them to pick |
| "Whatever's standard" | Check codebase conventions, propose the standard approach |
| "Skip this" | Record as explicit Non-Goal or Open Question |
| Vague answer | Rephrase as concrete acceptance criterion, confirm |

### Phase 3: Build Spec Context

Create a compact context block for generators, including the skeleton:

- **Spec skeleton** (with TBDs filled from interview, remaining gaps marked)
- Feature summary (1-2 paragraphs)
- Codebase findings (key files, patterns, constraints, ownership)
- User answers (structured bullets, mapped to skeleton sections)
- Decisions made + rationale
- Remaining open questions

**Context Checklist** — Ensure skeleton has:
- [ ] Ownership (product, technical, code areas)
- [ ] Acceptance criteria (concrete, testable)
- [ ] Backwards compatibility stance
- [ ] API/Data model needs (or explicit "not applicable")
- [ ] Integration points

### Phase 4: Run Multi-Model Generators

Create a temporary prompt file by concatenating the base prompt with your context:

```bash
PROMPT_TMP=$(mktemp /tmp/create-spec-prompt-XXXX.md)
cat "${CLAUDE_PLUGIN_ROOT}/prompts/generators/create-spec.md" > "$PROMPT_TMP"
cat >> "$PROMPT_TMP" <<'EOF'

## Context

EOF
```

Now append the Phase 3 context (skeleton + findings + answers) to `$PROMPT_TMP`.

Spawn generators with the mode flag. The generate script enforces timeouts internally:
- `fast`: ~5 minutes
- `smart`: ~10 minutes
- `max`: ~15 minutes

```bash
# MODE is extracted from --mode argument, defaults to smart
MODE="${MODE:-smart}"
${CLAUDE_PLUGIN_ROOT}/bin/generate --type create-spec --mode "$MODE" --prompt-file "$PROMPT_TMP"
```

Wait for the generator output containing all drafts.

### Phase 5: Synthesize Drafts

Merge generator drafts into the skeleton structure:

1. Use the skeleton as the canonical structure—don't invent new sections
2. Identify common conclusions across drafts for each skeleton section
3. Resolve conflicts by checking the codebase and user answers
4. Fill remaining TBDs with synthesized content or mark as Open Questions
5. Ensure all required sections are present (Ownership, Acceptance Criteria, Backwards Compatibility)
6. Mark API/Data Model as "Not applicable" if not needed (don't leave empty)
7. In `max` mode: include alternatives considered and risk analysis

### Phase 6: Write the Spec File

Ask the user where to save, or default to:

```
docs/YYYY-MM-DD-FEATURE_NAME-spec.md
```

Write the synthesized spec to the chosen path.

### Phase 7: Review Gate (Iterative)

Spawn external reviewers to validate the spec:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-spec-review path/to/spec.md
```

If reviewers find issues:
1. Fix the spec
2. Re-run the review gate command
3. Iterate until all reviewers pass or mode's max rounds reached:
   - `fast`: 1 round max
   - `smart`: up to 2 rounds
   - `max`: up to 3 rounds

## Done

When the spec passes review, summarize the final spec and offer to proceed with implementation.
