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

**IMPORTANT: When you finish Phase 1b:**
- Write the skeleton spec to a file (e.g., `docs/YYYY-MM-DD-FEATURE-spec.md`) — this becomes the canonical doc
- The skeleton MUST contain `[TBD]` placeholders — fill them only after user answers in Phase 2
- Present the skeleton and your first batch of interview questions via `AskUserQuestion`

**PHASE 2 GATE**: After sending Interview Batch 1, end your turn immediately. Do not proceed to Phase 3+ until the user answers or issues a stop signal. This gate is mandatory.

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

**Decisions made** *(S/M/L)*
- [Record "you decide" / "whatever's standard" resolutions here]

**Open questions** *(S/M/L)*
- [List unknowns from research]
```

**Skeleton rules:**
- Start with Tier S fields; add M/L fields as complexity signals accumulate
- Pre-fill anything you can confidently infer from research
- Mark unknowns explicitly as `[TBD]` or `[TBD: hint about what's needed]`
- When outputting final spec, omit sections marked for other tiers

### Phase 2: Prioritized BFS Interview

**Load the interview engine:** Read `${CLAUDE_PLUGIN_ROOT}/prompts/interview-engine.md` for the full mechanism. Key principles below.

**IMPORTANT: Use the `AskUserQuestion` tool for ALL interview questions.** Put coverage + numbered questions + off-ramp in a single tool call. Plain text questions are not interactive.

#### Core Mechanism: Prioritized Breadth-First Search

Ask questions in order of **priority** (P0-P3) and **depth** (L0-L3), with **breadth across topics before depth in any single topic**.

| Priority | What | Examples |
|----------|------|----------|
| P0 | Blockers / correctness | Scope boundaries, acceptance criteria, backwards compatibility |
| P1 | Major design | Primary flow, testing strategy, success criteria |
| P2 | Edge cases | Alternate flows, failure modes, observability |
| P3 | Polish | Ergonomics, minor UX improvements |

| Depth | Scope | Examples |
|-------|-------|----------|
| L0 | Vision / outcome | What problem? Who? Definition of done? |
| L1 | Behavior / approach | Primary flow, key states, acceptance criteria shape |
| L2 | Decomposition | Requirement breakdown, GWT examples, test layers |
| L3 | Implementation details | Exact event schemas, precise error codes, rollout mechanics |

**Anti-deep-dive rule:** Don't ask L2 for Topic A until all P0 topics have L1 coverage.

#### Stop Signals (MUST HONOR IMMEDIATELY)

| Signal Type | Trigger Phrases | Action |
|-------------|-----------------|--------|
| **Global stop** | "enough detail", "that's enough", "stop here", "we're good", "ship it" | End interview, remaining TBDs → Open Questions |
| **Depth cap** | "keep it high-level", "stop at L1", "no deep dive", "details later" | Set max_depth, continue within cap |
| **Priority cap** | "skip P2/P3", "just blockers", "P0/P1 only" | Set max_priority, lower items → Open Questions |
| **Per-topic stop** | "enough about testing", "park observability", "skip auth" | Mark topic capped, continue others |
| **Per-question skip** | "skip this one", "next question" | Mark TBD as Open Question, no follow-ups |
| **Delegation** | "you decide", "whatever's standard" | Pick safe default, record in Decisions |
| **Uncertainty** | "I don't know" | Offer 2-3 options; if declined → Open Question |

#### Batch Presentation Format

Present questions with context and an **explicit off-ramp**:

```
**Interview Batch [N]** (Priority: P0, Depth: L0)

Current coverage: [P0 in progress at L0]

Questions (answer any, skip any):

1. [Topic: Scope] What's explicitly out of scope?
   - Options: [A] Exclude X and Y, [B] Exclude only X, [C] You decide
   
2. [Topic: Requirements] What MUST the system guarantee?
   - Evidence: Similar features use [pattern] — should we follow that?

3. [Topic: Verification] How will we validate this works?
   - Options: [A] Manual QA, [B] E2E tests, [C] Both

---
Reply using `1: <answer> 2: <answer>` format (skip numbers to leave as Open Questions).
Or say "enough detail" to stop, "keep it high-level" to cap depth.
```

#### After Each Batch

1. **Update skeleton immediately** — fill TBDs or mark as Open Questions
2. **Check for stop signals** in the response
3. **Ask one meta-question**: "Continue to L{k+1}, stop here, or drill deeper on a specific topic?"

#### Progressive Coverage by Tier

**Tier S (P0/L0-L1):**
- Problem/context, change summary, scope boundary
- UX impact, acceptance bullets, validation method

**Tier M (add P1/L1-L2):**
- Goal, success criteria, non-goals
- Primary flow, key states
- Requirements with MUST + examples

**Tier L (add P2/L2-L3):**
- Constraints, alternate flows
- Edge cases per requirement
- Full GWT, instrumentation, launch checklist

**Tier upgrade prompt:** When complexity signals accumulate:
> "This touches [signals]. Want to expand to Tier M/L for [additional coverage]?"

#### Handling Responses

| User says... | You should... |
|--------------|---------------|
| "You decide" | Pick safe default, record in Decisions, stop deeper |
| "I don't know" | Offer 2-3 options with tradeoffs |
| "Whatever's standard" | Use codebase conventions, record decision |
| "Skip this" | Record as Non-Goal or Open Question |
| Stop signal | End interview or cap depth immediately |

### Phase 3: Build Spec Context

Create a compact context block for generators:

- **Current spec file** (with TBDs filled from interview, remaining gaps marked)
- Feature summary (1-2 paragraphs)
- Codebase findings (key files, patterns, constraints)
- User answers (structured bullets, mapped to spec sections)
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

Create a temporary prompt file by concatenating the base prompt with your context:

**CRITICAL**: The command MUST start with an executable, NOT a variable assignment. Variable assignments trigger permission prompts.

```bash
mktemp /tmp/create-spec-prompt-XXXXXX.md
```

This creates a unique temp file like `/tmp/create-spec-prompt-abc123.md`. Set `PROMPT_TMP` to the output path, then populate it:

```bash
cat "${CLAUDE_PLUGIN_ROOT}/prompts/generators/create-spec.md" > "$PROMPT_TMP" && cat >> "$PROMPT_TMP" <<'EOF'

## Context

EOF
```

Now append the Phase 3 context (skeleton + findings + answers) to `$PROMPT_TMP`.

Spawn generators with the mode flag. The generate script enforces timeouts internally:
- `fast`: ~5 minutes
- `smart`: ~10 minutes
- `max`: ~15 minutes

**CRITICAL**: The command MUST start with an executable, NOT a variable assignment. Variable assignments trigger permission prompts.

```bash
mkdir -p "${REVIEW_DIR:-/tmp}/spec-drafts" && ${CLAUDE_PLUGIN_ROOT}/bin/generate "${REVIEW_DIR:-/tmp}/spec-drafts" --type create-spec --mode "${MODE:-smart}" --prompt-file "$PROMPT_TMP"
```

The generator writes drafts to the output directory and returns their paths:
- `$OUTPUT_DIR/codex/draft.md`
- `$OUTPUT_DIR/gemini/draft.md`
- `$OUTPUT_DIR/claude/draft.md`

**IMPORTANT:** The tool result contains only file paths, not the full draft content. This preserves your context window.

### Phase 5: Synthesize Drafts (SUBAGENT REQUIRED)

**You MUST use a subagent (Task tool) to synthesize drafts.** This preserves your main context for the review gate phase.

Use the Task tool with a prompt like:

```
Synthesize the following generator drafts into the spec file.

Draft files to read:
- $OUTPUT_DIR/codex/draft.md
- $OUTPUT_DIR/gemini/draft.md
- $OUTPUT_DIR/claude/draft.md

Spec file to update: docs/YYYY-MM-DD-FEATURE-spec.md
Tier: [S/M/L]

Synthesis rules:
1. Use the existing spec file as canonical structure — don't invent new sections
2. Identify common conclusions across drafts for each section
3. Resolve conflicts by checking the codebase and user answers
4. Fill remaining [TBD] placeholders with synthesized content or mark as Open Questions
5. Include only sections required for the tier (see tier requirements below)
6. Tier-specific verification:
   - Tier S: Simple acceptance bullets, no formal requirements
   - Tier M: Requirements with MUST + verification examples (GWT optional)
   - Tier L: Requirements with MUST + full Given/When/Then + edge cases per requirement
7. In max mode: include alternatives considered and risk analysis

Update the spec file in place with the synthesized content.

Return a summary of key decisions made during synthesis.
```

The subagent will:
1. Read each draft file
2. Read the existing spec file
3. Synthesize drafts into the spec
4. Update the spec file in place
5. Return a summary to you

**Delegate draft reading to the subagent** — reading drafts yourself would consume your context. The subagent reads drafts, synthesizes, and returns a summary.

### Phase 6: Verify Spec

The subagent updated the spec file in Phase 5. Confirm the [TBD] placeholders have been filled.

### Phase 7: Review Gate with Prioritized BFS Refinement

Spawn external reviewers on the spec file:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-spec-review docs/YYYY-MM-DD-FEATURE-spec.md
```

**IMPORTANT: Use the `AskUserQuestion` tool for ALL clarifying questions during review.** Put findings + options in a single tool call. Plain text questions are not interactive.

#### Prioritized BFS for Review Findings

Treat reviewer findings as a queue, just like interview questions. Process them in **priority-first, breadth-first order**:

1. **Group findings by priority** — P0 across all sections, then P1, then P2, etc.
2. **Address breadth before depth** — Surface all P0s before deep-diving into any; within a priority, ask L0 clarification questions first, then apply deeper rewrites (L1/L2)
3. **Ask user to resolve ambiguous ones** — Don't silently fix substantive issues

**Priority definitions:**
- **P0**: Blocking/incorrect — spec is fundamentally unclear or contradictory
- **P1**: Major clarity issues — will cause implementation failures
- **P2**: Should clarify before implementation
- **P3**: Nits and minor improvements

#### Batch Presentation Format for Findings

```
**Review Findings Batch [N]** (Priority: P0)

Reviewers found 2 P0 issues and 3 P1 issues. Let's address P0s first:

1. [Section: Scope] Unclear what happens when user cancels mid-flow
   - Options: [A] Rollback to last save, [B] Discard changes, [C] You decide

2. [Section: Requirements] R2 has no verification method
   - Options: [A] Add unit test, [B] Add E2E test, [C] Manual validation

---
Reply "enough detail" to stop drilling into fixes, or "skip P2/P3" to focus only on blockers.
```

#### Stop Signals for Review

| Signal | Action |
|--------|--------|
| "enough detail" / "that's good" | Stop asking about remaining issues, mark as Open Questions |
| "skip P2/P3" / "just fix blockers" | Only address P0/P1, leave rest as future improvements |
| "you decide" | Pick safe fix, record in Decisions Made |

#### Refinement Rules

**DO:**
- Present all findings of current priority before asking about any
- Offer 2-3 concrete options for resolving each ambiguous finding
- Record decisions in Decisions Made section
- After applying fixes, summarize changes in 2-3 bullets

**Always ask for user input on:**
- Substantive issues (scope, behavior, design) — present options before fixing
- Ambiguous issues — offer 2-3 concrete choices
- All findings at current priority level — address breadth before depth

**OK to silently fix:** Typos, formatting, and purely mechanical issues.

#### Round limits by mode:
- `fast`: 1 round (P0/P1 only; leave rest as future improvements)
- `smart`: up to 2 rounds (P0-P2)
- `max`: up to 3 rounds (all priorities, probe for additional concerns)

## Done

When the spec passes review, summarize the final spec and offer to proceed with implementation.
