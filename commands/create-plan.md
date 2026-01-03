---
description: Interview the user to produce a technical implementation plan (design-focused), then run multi-model generator and plan review gate
argument-hint: [--mode <fast|smart|max>] [--from-spec <path/to/spec.md>] <feature or plan summary>
---

# Create Plan (Interview + Multi-Model Generator)

Turn a spec or vague feature idea into a **design-focused implementation plan** by combining codebase research (including file existence checks), a targeted implementation-focused interview, multi-model generation, and a plan review gate.

> **Note**: This command produces a **design plan** (architecture, constraints, approach). Task breakdown is handled separately by `/create-tasks`, which reads this plan and outputs to Beads issues (`--beads`) or TODO.md.

## Execution Contract (MANDATORY)

You **MUST** follow these phases in order. Skipping phases is **NOT ALLOWED**:

1. **Phase 0–1b**: Research codebase + verify file existence
2. **Phase 1c**: Write a skeleton plan with `[TBD]` placeholders to a file
3. **Phase 2**: Run an interview focused on filling `[TBD]` placeholders
4. **Phase 3**: Build context from skeleton + user answers
5. **Phase 4**: Call generators (writes drafts to files)
6. **Phase 5**: Use a **subagent** to synthesize drafts into final plan
7. **Phase 6**: Write the synthesized plan file
8. **Phase 7**: Run review gate

**Hard Rules:**
- You are **NOT ALLOWED** to produce a fully-filled plan before Phase 5
- You **MUST** output a skeleton with `[TBD]` markers in Phase 1c
- You **MUST** interview the user in Phase 2 before calling generators
- You **MUST** wait for user answers before proceeding to Phase 3
- Even if the user asks to "skip the interview" or "just generate the plan", you **MUST** still produce a skeleton and run at least one batch of questions
- At the start of each major phase (0–7), explicitly state which phase you are in and what you will do next

## Failure Modes to Avoid

❌ **Jumping from Phase 1 research directly to a fully-filled Implementation Plan** — This is disallowed. You must show a skeleton with `[TBD]` and interview the user first.

❌ **Skipping the interview phase** — Even if the spec seems complete, you must run at least one batch of Phase 2 questions to confirm assumptions.

❌ **Obeying user requests to skip phases** — If the user says "just generate the plan" or "skip the interview", politely explain you must follow the workflow and proceed with the skeleton + interview.

❌ **Outputting generator drafts inline** — Drafts are written to files; synthesis reads from those files.

❌ **Synthesizing in your main context** — Synthesis MUST use a subagent to preserve your context.

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
- In `max`, actively probe for edge cases, failure modes, and rollback scenarios even if user doesn't raise them

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
     - Goals, Non-Goals, Acceptance Criteria, Technical Design, Backwards Compatibility (including rollout/rollback), and Edge Cases.

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
- Write the skeleton plan to a file (e.g., `docs/YYYY-MM-DD-FEATURE-skeleton.md`)
- The skeleton MUST contain `[TBD]` placeholders — do NOT fill them in yet
- Present the skeleton and your first batch of interview questions to the user (this begins Phase 2)
- **STOP and wait for user answers** before continuing with further questions or moving to Phase 3
- Do NOT call generators or attempt to fully fill the plan yet

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

## Rollback Strategy
- [TBD: How to revert if deployment fails]
- [TBD: Feature flag strategy if applicable]

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

### Phase 2: Implementation-Focused Interviewing

**Prerequisites:** Phase 1c skeleton MUST exist before starting Phase 2.

**IMPORTANT: Use the `AskUserQuestion` tool for ALL interview questions.** Do NOT just print questions as text—the user cannot respond to printed text. Each question must be asked using the tool to get a response.

Ask questions in batches, prioritized by importance. Put critical questions first so the user can stop answering when there's enough detail. Only ask what you cannot infer from the spec and codebase.

**Phase 2 Rules:**
- You may only ask questions that directly correspond to existing `[TBD]` placeholders in the skeleton
- After each user answer, mentally note which `[TBD]` it resolves (you'll update the skeleton context in Phase 3)
- Continue interviewing until Technical Design, Testing Strategy, and Rollback sections have minimal TBDs
- Explicitly declare "Phase 2 complete" before proceeding to Phase 3

**Interview from the skeleton:** Frame questions around filling TBD placeholders. Example: "The Architecture section needs clarity on data flow—options: [A] sync via API, [B] event-driven, [C] you decide. Which?"

**Interview Principles**

1. **Propose, don't probe** — Offer concrete implementation options and tradeoffs.
2. **Reference evidence** — "I see feature flags in `config/features.ts`—should this be flag-gated?"
3. **Decide when delegated** — If they say "you decide," choose a safe approach and record it.
4. **Cover gaps, not ground** — Don't re-ask questions the spec or code already answers.
5. **Map to plan template** — Every answer should map to plan sections.

**Question Categories** (adapt order to context):

#### Starting Point & Scope
- Are we following a spec? Is it stable or are there known deviations?
- Is this plan for MVP only, or should it include follow-up work?
- What's explicitly excluded (Non-Goals)?

#### Code Areas & File-Level Targets
- Which parts of the codebase are in scope? (API only vs API + UI + jobs)
- Specific files/modules to avoid or refactor instead of extending?
- Ownership boundaries to respect?

#### Dependencies & Rollout Strategy
- Does this depend on other features, migrations, or infra work?
- Should risky changes be flag-gated? Where are flags defined?
- Rollout approach: flag-gated → canary → full, or "big bang"?

#### Data, Migrations & Backwards Compatibility
- Any schema or data shape changes?
- Dual-read/dual-write or versioned payloads needed?
- Compatibility with existing clients during rollout?

#### Testing & Verification Strategy
- What types of tests are required? (unit, integration, E2E)
- Critical flows to explicitly cover?
- Manual validation steps or environments required?

#### Implementation & Testing Constraints
- Any architectural constraints? (e.g., "extend module X, don't add new service")
- Areas to avoid touching?
- Required test coverage levels or quality gates?
- Performance/load testing requirements?
- Must-have regression coverage?

#### Operational Concerns
- What monitoring/observability signals matter? (metrics, logs, alerts)
- SLO/SLA or performance envelope to respect?

**Handling Common Responses**

| User says... | You should... |
|--------------|---------------|
| "You decide" | Choose safe, conventional pattern; record in Assumptions & Constraints |
| "I don't know" | Propose 2–3 concrete strategies with tradeoffs; ask them to choose |
| "Whatever's standard" | Use existing codebase patterns; say so explicitly |
| "Skip this" | Record under Non-Goals or Open Questions |
| Vague answer | Rephrase as concrete task or verification step; confirm |

### Phase 3: Build Plan Context

**Gate Check — You MUST NOT proceed to Phase 3 until:**
- [ ] A skeleton file exists from Phase 1c
- [ ] You have run at least one batch of Phase 2 interview questions
- [ ] You have collected user answers for the critical TBDs
- [ ] Any remaining unknowns are marked as Open Questions

Create a compact context block for generators, including the skeleton:

- **Plan skeleton** (with TBDs filled from interview, remaining gaps marked)
- **Implementation target summary** (1–2 paragraphs)
- **Starting artifacts**: Spec path + summary (if any)
- **Codebase findings**: Key files/modules, patterns, constraints, ownership
- **File existence table**: For each path: Exists / New / Ambiguous
- **User answers**: Structured bullets mapped to skeleton sections
- **Decisions made + rationale**
- **Remaining open questions**

**Context Checklist** — Ensure skeleton has:
- [ ] Clear target (spec/feature) + links/paths
- [ ] Scope (MVP vs follow-ups) and Non-Goals
- [ ] Technical Design (architecture, data model, interfaces)
- [ ] Verified file/module list (exists vs New vs ambiguous)
- [ ] Dependencies and rollout strategy
- [ ] Implementation constraints (architectural, areas to avoid)
- [ ] Testing & verification strategy (coverage, quality gates)
- [ ] Mapping from spec Acceptance Criteria to design approach
- [ ] Rollback strategy
- [ ] Risk/rollback expectations

### Phase 4: Run Multi-Model Generators

Spawn generators with the mode flag. The generate script enforces timeouts internally:
- `fast`: ~5 minutes
- `smart`: ~10 minutes
- `max`: ~15 minutes

The generator reads the prompt from stdin. Use a heredoc to pass the base prompt plus your Phase 3 context (skeleton + findings + answers):

```bash
${CLAUDE_PLUGIN_ROOT}/bin/generate "$OUTPUT_DIR/plan-drafts" --type create-plan --mode "${MODE:-smart}" <<PROMPT
$(cat "${CLAUDE_PLUGIN_ROOT}/prompts/generators/create-plan.md")

## Context

[Insert skeleton + findings + answers here]
PROMPT
```

The generate script will output paths to the draft files:
- `$OUTPUT_DIR/codex.md`
- `$OUTPUT_DIR/gemini.md`
- `$OUTPUT_DIR/claude.md`

**IMPORTANT:** The tool result contains only file paths, not the full draft content. This preserves your context window.

### Phase 5: Synthesize Drafts (SUBAGENT REQUIRED)

**You MUST use a subagent (Task tool) to synthesize drafts.** This preserves your main context for the review gate phase.

Use the Task tool with a prompt like:

```
Synthesize the following generator drafts into a single implementation plan.

Draft files to read:
- $OUTPUT_DIR/codex.md
- $OUTPUT_DIR/gemini.md  
- $OUTPUT_DIR/claude.md

Skeleton file: docs/YYYY-MM-DD-FEATURE-skeleton.md

Synthesis rules:
1. Use the skeleton as canonical structure — don't invent new sections
2. Identify common structure and tasks — higher confidence where drafts agree
3. Resolve conflicts using the spec and codebase patterns
4. Fill remaining [TBD] placeholders with synthesized content
5. Mark unresolved items as Open Questions
6. Respect file existence: label new files as "New: path/to/file"
7. Ensure all template sections are complete:
   - Context & Goals, Scope & Non-Goals, Assumptions & Constraints
   - Prerequisites, High-Level Approach, Technical Design (architecture/data/interfaces)
   - Risks/Edge Cases, Testing & Validation, Rollback Strategy, Open Questions

Write the synthesized plan to: docs/YYYY-MM-DD-FEATURE-plan.md

Return a summary of key decisions made during synthesis.
```

The subagent will:
1. Read each draft file
2. Read the skeleton
3. Synthesize into the final plan
4. Write the plan file
5. Return a summary to you

**Do NOT read the draft files yourself** — this would blow out your context. Let the subagent handle synthesis.

### Phase 6: Verify Plan File

The subagent wrote the plan file in Phase 5. Verify it exists and briefly confirm the structure is complete.

Default location:
```
docs/YYYY-MM-DD-FEATURE_NAME-plan.md
```

Alternative for session-based workflow:
```
~/.claude/plans/YYYY-MM-DD-FEATURE_NAME.md
```

### Phase 7: Review Gate (Iterative)

Spawn external reviewers:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-plan-review path/to/plan.md
```

**IMPORTANT: Use the `AskUserQuestion` tool for ALL clarifying questions during review.** Do NOT just print questions as text—the user cannot respond to printed text.

If reviewers find issues:
1. Fix the plan file
2. Re-run the review gate command
3. Iterate until all reviewers pass or mode's max rounds reached:
   - `fast`: 1 round max
   - `smart`: up to 2 rounds
   - `max`: up to 3 rounds

## Done

When the plan passes review:
- Summarize key design decisions, major risks, and rollout strategy
- Offer next step: **Run `/create-tasks`** to generate execution artifacts:
  - `--beads` → Create Beads issues with dependencies for multi-agent parallelization
  - (default) → Generate TODO.md checklist for simpler tracking
