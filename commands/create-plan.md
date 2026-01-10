---
description: Interview the user to produce a technical implementation plan (design-focused), then run multi-model generator and plan review gate
argument-hint: [--mode <fast|smart|max>] [--from-spec <path/to/spec.md>] <feature or plan summary>
---

# Create Plan (Interview + Multi-Model Generator)

Turn a spec or vague feature idea into a **design-focused implementation plan** by combining codebase research (including file existence checks), a targeted implementation-focused interview, multi-model generation, and a plan review gate.

> **Note**: This command produces a **design plan** (architecture, constraints, approach). Task breakdown is handled separately by `/create-tasks`, which reads this plan and outputs to Beads issues (`--beads`) or TODO.md.

## Execution Contract (MANDATORY)

You **MUST** follow these phases in order. Skipping phases is **NOT ALLOWED**:

1. **Phase 0–1b**: Research codebase + integration point analysis + verify file existence
2. **Phase 1c**: Write initial plan with `[TBD]` placeholders to a file (this becomes the canonical doc)
3. **Phase 2**: Run an interview focused on filling `[TBD]` placeholders
4. **Phase 3**: Build context from plan file + user answers
5. **Phase 4**: Call generators (writes drafts to files)
6. **Phase 5**: Use a **subagent** to synthesize drafts into the plan file
7. **Phase 6**: Verify plan file is complete
8. **Phase 7**: Run review gate

**Hard Rules:**
- You are **NOT ALLOWED** to produce a fully-filled plan before Phase 5
- You **MUST** output an initial plan with `[TBD]` markers in Phase 1c
- You **MUST** interview the user in Phase 2 before calling generators
- You **MUST** wait for user answers before proceeding to Phase 3
- Even if the user asks to "skip the interview" or "just generate the plan", you **MUST** still produce an initial plan with `[TBD]` and run at least one batch of questions
- At the start of each major phase (0–7), explicitly state which phase you are in and what you will do next

## Success Criteria (Mandatory)

✅ **Produce skeleton with `[TBD]` placeholders in Phase 1c** — The initial plan file must contain unfilled placeholders, not completed content.

✅ **Run at least one interview batch in Phase 2** — Use `AskUserQuestion` to confirm assumptions, even if the spec seems complete.

✅ **Follow the workflow even when user asks to skip** — If user says "just generate the plan", explain the workflow and proceed with skeleton + interview.

✅ **Write generator drafts to files** — Call the generate script which writes drafts to disk; pass file paths to the synthesis subagent.

✅ **Delegate synthesis to a subagent** — Use the Task tool for synthesis to preserve your main context for the review gate.

## Mode Behavior

Modes control depth and rigor. Use soft budgets—exit early when quality is sufficient.

| Mode | Interview Depth | Review Rounds | Extras |
|------|-----------------|---------------|--------|
| fast | Until essentials filled (~60%) | 1 max | minimal |
| smart | Until ~80% filled | up to 2 | standard |
| max | Until ~95% filled + proactive probing | up to 3 | alternatives + detailed risk register |

**Soft budget rules:**
- Stop interviewing when skeleton is sufficiently filled and essentials (Prerequisites, Technical Design, Testing strategy) are covered
- In `fast`, prioritize speed over completeness—mark unknowns as Open Questions
- In `max`, actively probe for edge cases and failure modes even if user doesn't raise them

## Input

The user provides either:

- A **feature or implementation summary**, e.g.:
  - "implement backend + UI for batch exports"
  - "execute the auth spec in docs/2025-01-10-auth-spec.md"
- Optionally, a **spec path** via `--from-spec path/to/spec.md`

## Workflow

### Phase 0: Choose Starting Point

Before deep research, establish what you're planning against:

1. **Detect a spec (if any)**:
   - If `--from-spec` is provided, use that path.
   - Otherwise, ask: "Is there an existing spec for this? If so, what's the path?"
   - If there's no spec, treat the user's description as the spec summary.

2. **Ingest starting artifacts**:
   - If a spec is available, skim:
     - Goals, Non-Goals, Acceptance Criteria, Technical Design, Backwards Compatibility, and Edge Cases.

Document:
- `spec_path` (if any)
- A 3–5 bullet summary of what already exists vs what must be created.

### Phase 1: Codebase Research (Implementation-Focused)

Before asking implementation questions, understand how and where the work will land:

1. **Identify relevant areas**:
   - Search for related files, modules, routes, or services.
   - Prefer entry points and public APIs that will be touched.

2. **Note existing patterns**:
   - Naming conventions, feature-flag patterns, config handling.
   - Testing patterns, error handling, and logging conventions.

3. **Find integration points & constraints**:
   - Existing APIs, data models, queues, background jobs, feature flags, permissions.

4. **Capture key files/modules**:
   - Build a list of concrete paths likely to be touched or extended.
   - Include relevant test files and config/infra files.

5. **Ownership hints**:
   - Infer which modules/areas "own" the behavior you're changing.

### Phase 1a: Integration Point Analysis (CRITICAL)

**Goal: Identify existing infrastructure to extend BEFORE proposing new components.**

This phase prevents the common failure mode of proposing parallel/duplicate systems when the codebase already has mechanisms that should be extended.

**If a spec exists**: Honor any integration constraints from the spec (e.g., "Must reuse existing auth pipeline"). If the plan needs to deviate from spec constraints, explicitly call out the tradeoff and risk.

1. **Identify existing mechanisms** that could serve this feature:
   - Config systems, plugin architectures, registry patterns
   - Existing abstractions that handle similar concerns
   - Hook points, event systems, middleware chains
   - Factory patterns, strategy patterns, or extension points

2. **For each existing mechanism, evaluate**:
   - Can this feature be implemented by extending/hooking into it?
   - What would need to change in the existing system?
   - What are the tradeoffs vs building something new?

3. **Build an Integration Decision Table**:
   ```
   | Existing Mechanism | Could Serve Feature? | Extend vs New | Rationale |
   |--------------------|---------------------|---------------|-----------|
   | src/config/loader.ts | Yes | Extend | Already handles all component config |
   | src/plugins/registry.ts | Partial | Extend + Add | Has plugin loading, needs config hooks |
   | N/A - no existing auth middleware | No | New | Nothing exists for this concern |
   ```

4. **Default to extension**: If an existing mechanism can serve the feature with reasonable modifications, the plan MUST propose extending it rather than creating a parallel system. Creating new infrastructure requires explicit justification:
   - Existing mechanism is fundamentally incompatible (explain why)
   - Extending would require breaking changes with high blast radius
   - Existing mechanism is deprecated or scheduled for removal

5. **Red flags to catch yourself**:
   - "Create a new config system for X" when a config system exists
   - "Add a new registry for Y" when registries already exist
   - "Build a new middleware chain" when middleware chains exist
   - Any "new" that duplicates existing patterns

### Phase 1b: File & Module Existence Verification

Plans must not hallucinate existing files. Explicitly verify file existence:

1. **Collect candidate paths** from:
   - The spec (especially Technical Design, Backwards Compatibility, and Edge Cases sections).
   - Your codebase research.
   - User-provided lists of "places we need to touch".

2. **Check each candidate path**:
   - **Exists**: file/module is present in the repo.
   - **New**: not found – must be labeled as **New** in the plan.
   - **Ambiguous**: conceptual reference with no single obvious file.

3. **Build a verification table** for context:
   ```
   - src/auth/middleware.ts — Exists
   - src/auth/session_rotation.ts — New (to be created)
   - tests/auth/session_rotation.test.ts — New (test file to add)
   ```

### Phase 1c: Draft Plan Skeleton

Create a skeleton of the plan with placeholders based on research and spec. This drives targeted interviewing.

**IMPORTANT: When you finish Phase 1c:**
- Write the skeleton plan to a file (e.g., `docs/YYYY-MM-DD-FEATURE-plan.md`) — this becomes the canonical doc
- The skeleton MUST contain `[TBD]` placeholders — fill them only after user answers in Phase 2
- Present the skeleton and your first batch of interview questions via `AskUserQuestion`

**PHASE 2 GATE**: After sending Interview Batch 1, end your turn immediately. Do not proceed to Phase 3+ until the user answers or issues a stop signal. This gate is mandatory.

```markdown
# Implementation Plan: [Short Name]

## Context & Goals
- **Spec**: [spec_path or "N/A — derived from user description"]
- [TBD: 1-3 bullets summarizing the feature]

## Scope & Non-Goals
- **In Scope**
  - [Pre-fill from spec if available, else TBD]
- **Out of Scope (Non-Goals)**
  - [Pre-fill from spec if available, else TBD]

## Assumptions & Constraints
- [TBD or pre-fill from research]

### Implementation Constraints
- [TBD: architectural constraints]

### Testing Constraints
- [TBD: coverage requirements]

## Integration Analysis

### Existing Mechanisms Considered
[Pre-fill from Phase 1a Integration Decision Table]

| Existing Mechanism | Could Serve Feature? | Decision | Rationale |
|--------------------|---------------------|----------|-----------|
| [path/to/mechanism] | Yes/Partial/No | Extend/New | [Why] |

### Integration Approach
[TBD: How this feature hooks into existing infrastructure. If creating new infrastructure, justify why existing mechanisms are insufficient.]

## Prerequisites
- [ ] [TBD: access, approvals, infra]

## High-Level Approach
[TBD: 1-2 paragraphs describing the technical approach, phases, and key decisions]

## Technical Design

### Architecture
[TBD: How components fit together, data flow, key boundaries]

### Data Model
[TBD: Entities, relationships, state transitions — or "N/A" if not applicable]

### API/Interface Design
[TBD: Key interfaces, contracts, protocols — or "N/A" if not applicable]

### File Impact Summary
[Pre-fill from Phase 1b verification table]
```
- src/auth/middleware.ts — Exists (modify)
- src/auth/session.ts — New (create)
- tests/auth/session.test.ts — New (create)
```

## Risks, Edge Cases & Breaking Changes
- [TBD or pre-fill from spec Edge Cases]
- Backwards compatibility concerns: [TBD]

## Testing & Validation Strategy
- [TBD: Types of tests needed (unit, integration, e2e)]
- [TBD: Coverage requirements]
- [TBD: Manual validation steps]

### Acceptance Criteria Coverage
| Spec AC | Approach |
|---------|----------|
| [Pre-fill from spec if available] | [How this plan addresses it] |

## Open Questions
- [List unknowns from research]

## Next Steps
After this plan is approved, run `/create-tasks` to generate:
- `--beads` → Beads issues with dependencies for multi-agent execution
- (default) → TODO.md checklist for simpler tracking
```

**Skeleton rules:**
- Pre-fill from spec: Goals, Non-Goals, Acceptance Criteria, Edge Cases, Backwards Compatibility
- Embed file existence table from Phase 1b into File Impact Summary
- Mark unknowns as `[TBD]` or `[TBD: hint]`
- The skeleton drives Phase 2 questions—every TBD is a potential question

### Phase 2: Prioritized BFS Interview

**Prerequisites:** Phase 1c skeleton MUST exist before starting Phase 2.

**Load the interview engine:** Read `${CLAUDE_PLUGIN_ROOT}/prompts/interview-engine.md` for the full mechanism. Key principles below.

**IMPORTANT: Use the `AskUserQuestion` tool for ALL interview questions.** Put coverage + numbered questions + off-ramp in a single tool call. Plain text questions are not interactive.

#### Core Mechanism: Prioritized Breadth-First Search

Ask questions in order of **priority** (P0-P3) and **depth** (L0-L3), with **breadth across topics before depth in any single topic**.

| Priority | What | Examples |
|----------|------|----------|
| P0 | Blockers / correctness | Scope, backwards compatibility, data loss, testing baseline |
| P1 | Major design | Architecture, API contracts, ownership, rollout strategy |
| P2 | Edge cases | Failure modes, migrations, observability |
| P3 | Polish | Optimizations, refactors, minor improvements |

| Depth | Scope | Examples |
|-------|-------|----------|
| L0 | Vision / outcome | What spec? What MVP? What's excluded? |
| L1 | Architecture | Boundaries, data flow, API direction, test strategy |
| L2 | Components | File targets, endpoints, modules, test layers |
| L3 | Implementation | Exact files, schemas, algorithms, test cases |

**Anti-deep-dive rule:** Don't ask L2 for Topic A until all P0 topics have L1 coverage.

#### Stop Signals (MUST HONOR IMMEDIATELY)

| Signal Type | Trigger Phrases | Action |
|-------------|-----------------|--------|
| **Global stop** | "enough detail", "that's enough", "stop here", "we're good", "ship it" | End interview, remaining TBDs → Open Questions |
| **Depth cap** | "keep it high-level", "stop at L1", "no deep dive", "details later" | Set max_depth, continue within cap |
| **Priority cap** | "skip P2/P3", "just blockers", "P0/P1 only" | Set max_priority, lower items → Open Questions |
| **Per-topic stop** | "enough about testing", "park observability", "skip migrations" | Mark topic capped, continue others |
| **Per-question skip** | "skip this one", "next question" | Mark TBD as Open Question, no follow-ups |
| **Delegation** | "you decide", "whatever's standard" | Pick safe default, record in Assumptions & Constraints |
| **Uncertainty** | "I don't know" | Offer 2-3 options; if declined → Open Question |

#### Batch Presentation Format

Present questions with context and an **explicit off-ramp**:

```
**Interview Batch [N]** (Priority: P0, Depth: L1)

Current coverage: [P0 complete through L0, now at L1]

Questions (answer any, skip any):

1. [Topic: Architecture] How should data flow between components?
   - Options: [A] Sync via API, [B] Event-driven, [C] You decide
   - Evidence: I see pub/sub in `services/events/` — should we use that?
   
2. [Topic: Testing] What test types are required?
   - Options: [A] Unit only, [B] Unit + integration, [C] Full pyramid

3. [Topic: Compatibility] Are there existing clients to maintain?
   - Evidence: Found API v2 consumers in `clients/`

---
Reply using `1: <answer> 2: <answer>` format (skip numbers to leave as Open Questions).
Or say "enough detail" to stop, "keep it high-level" to cap depth.
```

#### After Each Batch

1. **Update skeleton immediately** — fill TBDs or mark as Open Questions
2. **Check for stop signals** in the response
3. **Ask one meta-question**: "Continue to L{k+1}, stop here, or drill deeper on a specific topic?"

**Phase 2 Rules:**
- You may only ask questions that correspond to existing `[TBD]` placeholders in the skeleton
- Continue interviewing until Technical Design and Testing Strategy sections have minimal TBDs
- Explicitly declare "Phase 2 complete" before proceeding to Phase 3

#### Topic Coverage for Plans

**P0/L0-L1 (always cover):**
- Scope: spec reference, MVP vs follow-ups, non-goals
- Architecture: high-level approach, boundaries, ownership
- Compatibility: backwards compatibility, breaking changes
- Testing: strategy, coverage requirements

**P1/L1-L2 (cover in smart/max modes):**
- Data: schema changes, migrations
- API: interface contracts, versioning
- Implementation: file targets, dependencies
- Rollout: feature flags, monitoring

**P2/L2-L3 (cover in max mode):**
- Failure modes, edge cases
- Operational concerns (metrics, alerts)
- Performance envelopes

#### Handling Responses

| User says... | You should... |
|--------------|---------------|
| "You decide" | Choose safe, conventional pattern; record in Assumptions & Constraints |
| "I don't know" | Propose 2–3 concrete strategies with tradeoffs |
| "Whatever's standard" | Use existing codebase patterns; say so explicitly |
| "Skip this" | Record under Non-Goals or Open Questions |
| Stop signal | End interview or cap depth immediately |

### Phase 3: Build Plan Context

**Gate Check — You MUST NOT proceed to Phase 3 until:**
- [ ] A plan file exists from Phase 1c
- [ ] You have run at least one batch of Phase 2 interview questions
- [ ] You have collected user answers for the critical TBDs
- [ ] Any remaining unknowns are marked as Open Questions

Create a compact context block for generators:

- **Current plan file** (with TBDs filled from interview, remaining gaps marked)
- **Implementation target summary** (1–2 paragraphs)
- **Starting artifacts**: Spec path + summary (if any)
- **Codebase findings**: Key files/modules, patterns, constraints, ownership
- **File existence table**: For each path: Exists / New / Ambiguous
- **User answers**: Structured bullets mapped to plan sections
- **Decisions made + rationale**
- **Remaining open questions**

**Context Checklist** — Ensure plan file has:
- [ ] Clear target (spec/feature) + links/paths
- [ ] Scope (MVP vs follow-ups) and Non-Goals
- [ ] Technical Design (architecture, data model, interfaces)
- [ ] Verified file/module list (exists vs New vs ambiguous)
- [ ] Dependencies
- [ ] Implementation constraints (architectural, areas to avoid)
- [ ] Testing & verification strategy (coverage, quality gates)
- [ ] Mapping from spec Acceptance Criteria to design approach

### Phase 4: Run Multi-Model Generators

Create a temporary prompt file:

**CRITICAL**: The command MUST start with an executable, NOT a variable assignment. Variable assignments trigger permission prompts.

```bash
mktemp /tmp/create-plan-prompt-XXXXXX.md
```

This creates a unique temp file like `/tmp/create-plan-prompt-abc123.md`. Set `PROMPT_TMP` to the output path, then populate it:

```bash
cat "${CLAUDE_PLUGIN_ROOT}/prompts/generators/create-plan.md" > "$PROMPT_TMP" && cat >> "$PROMPT_TMP" <<'EOF'

## Context

EOF
```

Now append the Phase 3 context (skeleton + findings + answers) to `$PROMPT_TMP`.

Spawn generators with the mode flag. The generate script requires an output directory as the first argument and writes drafts to files, returning their paths:
- `fast`: ~5 minutes
- `smart`: ~10 minutes
- `max`: ~15 minutes

**CRITICAL**: The command MUST start with an executable, NOT a variable assignment. Variable assignments trigger permission prompts.

```bash
mkdir -p "${REVIEW_DIR:-/tmp}/plan-drafts" && ${CLAUDE_PLUGIN_ROOT}/bin/generate "${REVIEW_DIR:-/tmp}/plan-drafts" --type create-plan --mode "${MODE:-smart}" --prompt-file "$PROMPT_TMP"
```

The generate script will output paths to the draft files:
- `$OUTPUT_DIR/codex/draft.md`
- `$OUTPUT_DIR/gemini/draft.md`
- `$OUTPUT_DIR/claude/draft.md`

**IMPORTANT:** The tool result contains only file paths, not the full draft content. This preserves your context window.

### Phase 5: Synthesize Drafts (SUBAGENT REQUIRED)

**You MUST use a subagent (Task tool) to synthesize drafts.** This preserves your main context for the review gate phase.

Use the Task tool with a prompt like:

```
Synthesize the following generator drafts into the plan file.

Draft files to read:
- $OUTPUT_DIR/codex/draft.md
- $OUTPUT_DIR/gemini/draft.md
- $OUTPUT_DIR/claude/draft.md

Plan file to update: docs/YYYY-MM-DD-FEATURE-plan.md

Synthesis rules:
1. Use the existing plan file as canonical structure — don't invent new sections
2. Identify common structure and tasks — higher confidence where drafts agree
3. Resolve conflicts using the spec and codebase patterns
4. Fill remaining [TBD] placeholders with synthesized content
5. Mark unresolved items as Open Questions
6. Respect file existence: label new files as "New: path/to/file"
7. Ensure all template sections are complete:
   - Context & Goals, Scope & Non-Goals, Assumptions & Constraints
   - Prerequisites, High-Level Approach, Technical Design (architecture/data/interfaces)
   - Risks/Edge Cases, Testing & Validation, Open Questions

Update the plan file in place with the synthesized content.

Return a summary of key decisions made during synthesis.
```

The subagent will:
1. Read each draft file
2. Read the existing plan file
3. Synthesize drafts into the plan
4. Update the plan file in place
5. Return a summary to you

**Delegate draft reading to the subagent** — reading drafts yourself would consume your context. The subagent reads drafts, synthesizes, and returns a summary.

### Phase 6: Verify Plan

The subagent updated the plan file in Phase 5. Confirm the [TBD] placeholders have been filled.

### Phase 7: Review Gate with Prioritized BFS Refinement

Spawn external reviewers on the plan file:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-plan-review docs/YYYY-MM-DD-FEATURE-plan.md
```

**CRITICAL: After running the spawn command, STOP IMMEDIATELY. Do NOT poll, sleep, wait, or run any further commands.** The Stop hook will automatically wait for reviewers and present their findings when you stop. Any attempt to manually check reviewer status will fail.

**IMPORTANT: Use the `AskUserQuestion` tool for ALL clarifying questions during review.** Put findings + options in a single tool call. Plain text questions are not interactive.

#### Prioritized BFS for Review Findings

Treat reviewer findings as a queue. Process in **priority-first, breadth-first order**:

1. **Group findings by priority** — P0 across all sections, then P1, then P2, etc.
2. **Address breadth before depth** — Surface all P0s before deep-diving into any; within a priority, ask L0 clarification questions first, then apply deeper rewrites (L1/L2)
3. **Ask user to resolve ambiguous ones** — Don't silently fix substantive design decisions

**Priority definitions:**
- **P0**: Blocking — plan is unclear, contradictory, or missing critical info
- **P1**: Major issues — will cause implementation failures
- **P2**: Should clarify before implementation
- **P3**: Nits and improvements

#### Batch Presentation Format for Findings

```
**Review Findings Batch [N]** (Priority: P0)

Reviewers found 2 P0 issues and 4 P1 issues. Addressing P0s first:

1. [Section: Architecture] Unclear ownership boundary between services
   - Options: [A] Service A owns, [B] Service B owns, [C] Shared ownership

2. [Section: Testing] No verification for backwards compatibility
   - Options: [A] Add integration tests, [B] Manual verification, [C] Skip (accept risk)

---
Reply "enough detail" to stop, or "skip P2/P3" to focus only on blockers.
```

#### Stop Signals for Review

| Signal | Action |
|--------|--------|
| "enough detail" / "that's good" | Stop asking, mark remaining as Open Questions |
| "skip P2/P3" / "just fix blockers" | Only address P0/P1 |
| "you decide" | Pick safe fix, record in Assumptions & Constraints |

#### Refinement Rules

**DO:**
- Present all findings of current priority before asking about any
- Offer 2-3 concrete options for resolving each ambiguous finding
- Record decisions in Assumptions & Constraints section
- After applying fixes, summarize changes in 2-3 bullets

**Always ask for user input on:**
- Substantive issues (architecture, ownership, design) — present options before fixing
- Ambiguous issues — offer 2-3 concrete choices
- All findings at current priority level — address breadth before depth

**OK to silently fix:** Typos, formatting, and purely mechanical issues.

#### Round limits by mode:
- `fast`: 1 round (P0/P1 only)
- `smart`: up to 2 rounds (P0-P2)
- `max`: up to 3 rounds (all priorities)

## Done

When the plan passes review:
- Summarize key design decisions and major risks
- Offer next step: **Run `/create-tasks`** to generate execution artifacts:
  - `--beads` → Create Beads issues with dependencies for multi-agent parallelization
  - (default) → Generate TODO.md checklist for simpler tracking
