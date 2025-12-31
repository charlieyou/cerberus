---
description: Interview the user to produce a feature spec, then run multi-model generator and spec review gate
argument-hint: [--mode <fast|smart|max>] <feature description>
---

# Create Spec (Interview + Multi-Model Generator)

Transform a vague feature idea into a complete, reviewable specification by combining codebase research, a targeted interview, multi-model generation, and a spec review gate.

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

Document findings internally—these inform your questions and the final spec.

### Phase 2: Strategic Interviewing

Ask 2-4 questions at a time. Only ask what you cannot answer from the codebase.

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

#### Testing & Validation
- How should this be tested? (unit, integration, manual)
- Which acceptance criteria need automated coverage?
- Any regression risks to guard against?

**Handling Common Responses**

| User says... | You should... |
|--------------|---------------|
| "You decide" | Make a reasonable choice, record in Decisions Made |
| "I don't know" | Propose 2-3 options with tradeoffs, ask them to pick |
| "Whatever's standard" | Check codebase conventions, propose the standard approach |
| "Skip this" | Record as explicit Non-Goal or Open Question |
| Vague answer | Rephrase as concrete acceptance criterion, confirm |

### Phase 3: Build Spec Context

Create a compact context block for generators:

- Feature summary (1-2 paragraphs)
- Codebase findings (key files, patterns, constraints, ownership)
- User answers (structured bullets, mapped to spec sections)
- Decisions made + rationale
- Remaining open questions

**Context Checklist** — Ensure you have enough to fill:
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

[Paste the context you built in Phase 3]
EOF
```

Then spawn generators. **IMPORTANT**: Set the Bash timeout based on mode:
- `--mode fast`: 300000ms (5 minutes)
- `--mode smart`: 600000ms (10 minutes)
- `--mode max`: 900000ms (15 minutes)

```bash
${CLAUDE_PLUGIN_ROOT}/bin/generate --type create-spec --prompt-file "$PROMPT_TMP" $ARGUMENTS
```

Defaults to `--mode smart` if not specified.

Wait for the generator output containing all drafts.

### Phase 5: Synthesize Drafts

Synthesize the generator drafts into a single spec:

1. Identify common conclusions across drafts
2. Resolve conflicts by checking the codebase and user answers
3. Deduplicate overlapping sections
4. Ensure all required sections are present (Ownership, Acceptance Criteria, Backwards Compatibility)
5. Mark API/Data Model as "Not applicable" if not needed (don't leave empty)
6. Produce a single coherent spec in the template format

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
3. Iterate until all reviewers pass (or max rounds reached)

## Done

When the spec passes review, summarize the final spec and offer to proceed with implementation.
