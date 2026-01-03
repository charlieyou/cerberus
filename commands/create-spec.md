---
description: Interview the user to produce a feature spec, then run multi-model generator and spec review gate
argument-hint: [--mode <fast|smart|max>] <feature description>
---

# Create Spec (Interview + Multi-Model Generator)

Transform a vague feature idea into a complete, reviewable specification by combining codebase research, a targeted interview, multi-model generation, and a spec review gate.

## Spec Tiers (Progressive Disclosure)

Specs scale with complexity. Start minimal and expand as signals emerge.

| Tier | Use Case | What's Required |
|------|----------|-----------------|
| **S** | Bug fix, tiny tweak | Problem, change summary, scope boundary, UX impact, 2-5 acceptance bullets, validation method, open questions |
| **M** | Small feature, single flow | S + Goal, success criteria, non-goals, primary flow, key states, 3-7 requirements with MUST + verification examples, basic instrumentation |
| **L** | Multi-flow, high-risk project | M + Constraints, alternate flows, full Given/When/Then, edge cases per requirement, detailed instrumentation, launch checklist |

**Canonical field mapping:**
- **S only:** Change summary, Scope boundary, UX impact (yes/no), Acceptance bullets, Validation after release
- **M adds:** Goal, Success criteria, Non-goals, Primary flow, Key states, Requirements (R1/R2 with MUST + examples), Instrumentation (light)
- **L adds:** Constraints, Alternate flows, Edge cases per requirement, Full GWT verification, Launch checklist

### Complexity Signals (auto-detect tier)

Score these signals during the interview. Suggest tier upgrade if score exceeds threshold.

| Signal | Points |
|--------|--------|
| New user-facing flow or screen | +2 |
| Changes to data model / schema | +2 |
| Involves auth, security, payments, compliance | +2 |
| Impacts multiple user flows or personas | +2 |
| Integrates with external or multiple internal services | +1 |
| Needs new analytics or A/B experiment | +1 |
| Requires feature flags or data migration | +1 |
| Multiple teams or owners involved | +1 |

**Score → Tier:** 0-1 = S, 2-4 = M, 5+ = L

If detected tier differs from apparent scope, confirm with user:
> "This looks like it touches multiple flows and data models. Should we expand to a fuller spec? (yes/no)"

### Tier Disagreement Handling

**If user declines an upgrade:**
- Respect their choice, but record the override in Open Questions: "Tier kept at [S/M] despite complexity signals suggesting [M/L]. Signals: [list]. Risk: [potential gaps]."
- For S specs with score ≥2, still ask about backwards compatibility and basic error handling even if not filling full M template.

**If user requests a downgrade:**
- Confirm explicitly: "Downgrading to [tier] means we won't cover [list of omitted sections]. OK to proceed?"
- If confirmed, record in Open Questions: "Tier downgraded to [S/M] per user request. Omitted: [sections]."

**Reviewers and tier overrides:**
- Reviewers should respect the stated tier and not fail for missing higher-tier sections.
- If a reviewer believes the tier is dangerously low, they should flag it as a P1 recommendation to upgrade, not a spec failure.

## Mode Behavior

Modes control interview depth and review rigor (orthogonal to tier).

| Mode | Interview Depth | Review Rounds | Extras |
|------|-----------------|---------------|--------|
| fast | Until essentials filled (~60%) | 1 max | minimal |
| smart | Until ~80% filled | up to 2 | standard |
| max | Until ~95% filled + proactive probing | up to 3 | alternatives + risk analysis |

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

Document findings internally—these inform the skeleton and your questions.

### Phase 1b: Draft Spec Skeleton

Create a skeleton based on your research. Start with Tier S fields; expand as complexity signals emerge.

```markdown
# [Feature Name]

**Tier:** S / M / L (auto-detected, confirm with user)
**Owner:** [TBD or pre-fill from research]
**Target ship:** [TBD]
**Links:** [Figma, ticket, related docs]

## 1. Outcome & Scope

**Problem / context** *(S/M/L)*
[TBD: What's broken/missing today? Who is impacted?]

**Change summary** *(S only — omit for M/L)*
[TBD: What are we changing and why?]

**Goal** *(M/L)*
[TBD: "Enable <user> to <do X> so that <benefit>."]

**Success criteria** *(M/L)*
- [TBD: Metric + threshold + timeframe]

**Non-goals** *(M/L)*
- [TBD or inferred from research]

**Constraints** *(L only)*
- Compatibility: [TBD: Any existing clients/integrations affected?]
- [Other constraints: performance, security, environment]

**Scope boundary** *(S only — omit for M/L)*
[TBD: "Only affects X; does not change Y/Z."]

## 2. User Experience & Flows

**UX impact** *(S only)*
- User-visible? (yes/no): [TBD]
- If yes: [TBD: "When user does A, they now see B instead of C."]

**Primary flow** *(M/L)*
1. [TBD]
2. [TBD]
3. [TBD]

**Key states** *(M/L)*
- Empty state: [TBD]
- Loading state: [TBD]
- Success state: [TBD]
- Error state(s): [TBD]

**Alternate flows** *(L only)*
- [TBD: What if user cancels? Lacks permission? Partial completion?]

## 3. Requirements + Verification

*(Tier S: Use simple acceptance bullets)*
*(Tier M/L: Use numbered requirements with MUST statements)*

**Acceptance criteria** *(S)*
- [TBD: When user does X in situation Y, Z happens]
- [TBD: Also verify these still work: ...]

**R1 — [Short name]** *(M/L)*
- **Requirement:** The system MUST [TBD]
- **Verification:** *(M: example or single GWT; L: full GWT)*
  - Given [TBD], When [TBD], Then [TBD]
- **Edge cases:** *(L only)* [TBD]

**R2 — [Short name]** *(M/L)*
- **Requirement:** The system MUST [TBD]
- **Verification:**
  - Given [TBD], When [TBD], Then [TBD]
- **Edge cases:** *(L only)* [TBD]

## 4. Instrumentation & Release Checks

**Validation after release** *(S)*
- How to confirm this worked: [TBD: "Try scenario X in env Y"]
- Known risks / blast radius: [TBD]

**Instrumentation** *(M/L)*
- Events to track: [TBD: feature entry, completion, failure reasons]

**Launch checklist** *(L only)*
- [ ] All MUST requirements verifiable
- [ ] Key error states covered
- [ ] Metrics available to confirm success criteria
- [ ] Rollback condition defined

**Open questions** *(S/M/L)*
- [List unknowns from research]
```

**Skeleton rules:**
- Start with Tier S fields; add M/L fields as complexity signals accumulate
- Pre-fill anything you can confidently infer from research
- Mark unknowns explicitly as `[TBD]` or `[TBD: hint about what's needed]`
- When outputting final spec, omit sections marked for other tiers

### Phase 2: Strategic Interviewing

**IMPORTANT: Use the `AskUserQuestion` tool for ALL interview questions.** Do NOT just print questions as text—the user cannot respond to printed text. Each question must be asked using the tool to get a response.

Ask questions in batches, prioritized by importance. Put critical questions first so the user can stop answering when there's enough detail. Only ask what you cannot answer from the codebase.

**Interview from the skeleton:** Frame questions around filling TBD placeholders. Example: "The Acceptance Criteria section needs concrete conditions—what does 'done' look like for this feature?"

**Interview Principles**

1. **Be thorough, not brief** — Ask all relevant questions, even if it takes multiple rounds
2. **Propose, don't probe** — Offer concrete options with tradeoffs instead of open-ended questions
3. **Reference evidence** — "I see X in Y—should this follow the same approach?"
4. **Decide when delegated** — If user says "you decide," make a sensible choice and record it
5. **Cover gaps, not ground** — Skip questions the codebase already answers
6. **Map to template** — Every answer should fill a specific spec section
7. **Iterate until complete** — Don't stop after one batch; continue asking until all TBDs are addressed
8. **Handle halted interviews** — If the user stops responding or declines further questions, mark remaining TBDs as Open Questions with your best guess or "needs product decision"

**Progressive Question Coverage by Tier:**

**Tier S (always ask):**
- [ ] Problem: What's broken/missing?
- [ ] Change summary: What are we changing and why?
- [ ] Scope boundary: What does this affect? What's untouched?
- [ ] UX impact: Is this user-visible? If so, what changes?
- [ ] Acceptance: 2-5 bullets of "when X, then Y"
- [ ] Validation: How do we confirm this worked after release?

**Tier M (add if score 2-4):**
- [ ] Goal: One-sentence goal ("Enable <user> to <do X> so that <benefit>")
- [ ] Success criteria: Metric + threshold + timeframe
- [ ] Non-goals: What's explicitly out of scope?
- [ ] Constraints: Compatibility, performance, security?
- [ ] Primary flow: Happy path step-by-step
- [ ] Key states: Empty/loading/success/error
- [ ] Requirements: 3-7 MUST statements with examples

**Tier L (add if score 5+):**
- [ ] Alternate flows: Cancel, retry, permission denied, partial completion
- [ ] Edge cases: Per-requirement boundary conditions
- [ ] Instrumentation: Events/metrics to track
- [ ] Launch checklist: Rollback conditions, verification steps

**Tier upgrade prompt:** When signals accumulate, ask:
> "This is touching [signals]. Want to expand the spec to cover [additional fields]?"

**Question Categories** (adapt order based on context):

#### Outcome & Scope (Section 1)
- What problem are we solving? Who's impacted?
- What's the one-sentence goal?
- How will we measure success? (metric + threshold + timeframe)
- What's explicitly out of scope?
- Any constraints? (compatibility, performance, security, environment)

#### User Experience & Flows (Section 2)
- What's the primary workflow/happy path?
- What are the key states? (empty, loading, success, error)
- What alternate flows matter? (cancel, retry, permission denied)
- What feedback does the user need?

#### Requirements + Verification (Section 3)
- What MUST the system do? (help derive R1, R2, R3...)
- For each requirement: what's the Given/When/Then?
- What are the edge cases and boundaries?
- Any non-functional requirements? (performance, accessibility)

#### Instrumentation & Release (Section 4)
- What events/metrics do we need to track?
- How do we know this is working in production?
- What would trigger a rollback?

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
- Codebase findings (key files, patterns, constraints)
- User answers (structured bullets, mapped to skeleton sections)
- Decisions made + rationale
- Remaining open questions

**Context Checklist by Tier:**

**Tier S:**
- [ ] Problem / context
- [ ] Change summary
- [ ] Scope boundary
- [ ] UX impact (yes/no + description)
- [ ] Acceptance criteria (2-5 bullets)
- [ ] Validation method
- [ ] Open questions

**Tier M (add to S):**
- [ ] Goal (one-sentence)
- [ ] Success criteria (measurable)
- [ ] Non-goals
- [ ] Primary flow (numbered steps)
- [ ] Key states (empty/loading/success/error)
- [ ] Requirements (R1, R2... with MUST + verification examples)
- [ ] Instrumentation (basic events)

**Tier L (add to M):**
- [ ] Constraints (compatibility, performance, security)
- [ ] Alternate flows
- [ ] Edge cases per requirement
- [ ] Full Given/When/Then verification
- [ ] Detailed instrumentation
- [ ] Launch checklist

### Phase 4: Run Multi-Model Generators

Spawn generators with the mode flag. The generate script enforces timeouts internally:
- `fast`: ~5 minutes
- `smart`: ~10 minutes
- `max`: ~15 minutes

The generator automatically loads the base prompt from `prompts/generators/create-spec.md`. Pass your Phase 3 context (skeleton + findings + answers) via stdin:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/generate "$OUTPUT_DIR/spec-drafts" --type create-spec --mode "${MODE:-smart}" <<CONTEXT
## Context

[Insert skeleton + findings + answers here]
CONTEXT
```

The generator writes drafts to the output directory and returns their paths:
- `$OUTPUT_DIR/codex.md`
- `$OUTPUT_DIR/gemini.md`
- `$OUTPUT_DIR/claude.md`

**IMPORTANT:** The tool result contains only file paths, not the full draft content. This preserves your context window.

### Phase 5: Synthesize Drafts

Merge generator drafts into the 4-section structure:

1. Use the skeleton as the canonical structure—don't invent new sections
2. Identify common conclusions across drafts for each section
3. Resolve conflicts by checking the codebase and user answers
4. Fill remaining TBDs with synthesized content or mark as Open Questions
5. Include only sections required for the tier (see Canonical field mapping above)
6. **Tier-specific verification:**
   - Tier S: Simple acceptance bullets, no formal requirements
   - Tier M: Requirements with MUST + verification examples (GWT optional)
   - Tier L: Requirements with MUST + full Given/When/Then + edge cases per requirement
7. In `max` mode: include alternatives considered and risk analysis

### Phase 6: Write the Spec File

Ask the user where to save, or default to:

```
docs/YYYY-MM-DD-FEATURE_NAME-spec.md
```

Write the synthesized spec to the chosen path.

### Phase 7: Review Gate with Interactive Refinement

Spawn external reviewers to validate the spec:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-spec-review path/to/spec.md
```

**IMPORTANT: Use the `AskUserQuestion` tool for ALL clarifying questions during review.** Do NOT just print questions as text—the user cannot respond to printed text.

**Interactive Refinement Loop:**

When reviewers find issues, DO NOT just fix them silently. Instead:

1. **Present findings to the user** — Show reviewer feedback grouped by priority (P0/P1 first)
2. **Ask clarifying questions** — For each finding, ask the user:
   - "Reviewer flagged [issue]. How would you like to address this?"
   - "They suggest [X], but [Y] is also possible. Which approach?"
   - "This seems like a scope decision—should we include [Z] or mark it out-of-scope?"
3. **Propose solutions** — Offer 2-3 concrete options for resolving each issue
4. **Record decisions** — Add resolutions to the Decisions Made section
5. **Fix the spec** based on user input
6. **Re-run the review gate** — Continue until all reviewers pass or mode's max rounds reached

**Questions to ask during refinement:**

- "Reviewers noted [gap]. Can you clarify [specific detail]?"
- "There's disagreement about [X]. Which interpretation is correct?"
- "This edge case wasn't covered: [scenario]. What should happen?"
- "Reviewer thinks [section] is too vague to implement. Can you be more specific about [detail]?"

**Priority definitions** (use reviewer's assigned severity, or these guidelines):
- P0: Blocking/incorrect behavior — spec is fundamentally unclear or contradictory
- P1: Major clarity/coverage issues — will cause implementation failures
- P2: Should be clarified before implementation
- P3: Nits and minor improvements

**Do NOT:**
- Silently fix substantive issues (scope, behavior, design) without consulting the user
- Assume you know the right answer for ambiguous issues
- Skip asking about P2/P3 issues (they often reveal important context)

**OK to silently fix:** Typos, formatting, and purely mechanical issues the reviewers flagged.

**Handling unresolved disagreements:** If neither reviewers nor user can decide, record it as an Open Question or explicit tradeoff in Decisions Made, and ensure the spec clearly flags the ambiguity.

**After applying fixes:** Summarize changes back to the user in 2-3 bullets so they see how feedback was applied. If an issue changes behavior, update Acceptance Criteria and User Stories, not just Decisions Made.

**Round limits by mode:**
- `fast`: 1 round max (P0/P1 issues only; leave other feedback as future improvements)
- `smart`: up to 2 rounds (ask about P0-P2 issues)
- `max`: up to 3 rounds (ask about all issues, probe for additional concerns)

## Done

When the spec passes review, summarize the final spec and offer to proceed with implementation.
