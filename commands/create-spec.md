---
description: Interview the user to produce a feature spec, then run multi-model generator and spec review gate
argument-hint: <feature description>
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

Document findings internally—these inform your questions and the final spec.

### Phase 2: Strategic Interviewing

Ask 2-4 questions at a time. Only ask what you cannot answer from the codebase.

**Question Categories** (cover all, but adapt order based on context):

#### Scope & Boundaries
- What's the MVP vs. nice-to-have?
- What's explicitly out of scope?
- Are there related features that should be excluded?

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

#### Edge Cases & Error Handling
- What happens when X fails?
- How should conflicts/race conditions be handled?
- What are the validation rules?
- Recovery and retry behavior?

#### Integration & Dependencies
- How does this interact with [existing system you found]?
- Does this affect [related feature you discovered]?
- Any migration or backwards compatibility concerns?

#### Testing & Validation
- How should this be tested?
- What constitutes "done"?
- Any specific acceptance criteria?

**Interview Guidelines**
- Propose concrete options with tradeoffs instead of open-ended prompts
- Reference code you found: "I see X in Y—should this follow the same approach?"
- If the user says "you decide," make a sensible choice and record it in Decisions Made

### Phase 3: Build Spec Context

Create a compact context block for generators:

- Feature summary (1-2 paragraphs)
- Codebase findings (key files, patterns, constraints)
- User answers (structured bullets)
- Decisions made + rationale
- Remaining open questions

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

Then spawn generators:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/generate --type create-spec --mode smart --prompt-file "$PROMPT_TMP"
```

Wait for the generator output containing all drafts.

Use `--mode fast|smart|max` to trade off speed vs depth.

### Phase 5: Synthesize Drafts

Synthesize the generator drafts into a single spec:

1. Identify common conclusions across drafts
2. Resolve conflicts by checking the codebase and user answers
3. Deduplicate overlapping sections
4. Produce a single coherent spec in the template format

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
