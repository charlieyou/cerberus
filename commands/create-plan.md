---
description: Interview the user to produce an implementation plan, then run multi-model generator and plan review gate
argument-hint: [--mode <fast|smart|max>] [--from-spec <path/to/spec.md>] <feature or plan summary>
---

# Create Plan (Interview + Multi-Model Generator)

Turn a spec or vague feature idea into a concrete, executable implementation plan by combining codebase research (including file existence checks), a targeted implementation-focused interview, multi-model generation, and a plan review gate.

## Mode Behavior

Modes control depth and rigor. Use soft budgets—exit early when quality is sufficient.

| Mode | Interview Depth | Review Rounds | Extras |
|------|-----------------|---------------|--------|
| fast | Until essentials filled (~60%) | 1 max | minimal |
| smart | Until ~80% filled | up to 2 | standard |
| max | Until ~95% filled + proactive probing | up to 3 | alternatives + detailed risk register |

**Soft budget rules:**
- Stop interviewing when skeleton is sufficiently filled and essentials (Prerequisites, Detailed Plan tasks, Testing strategy) are covered
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
[TBD: 1-2 paragraphs or ordered list]

## Detailed Plan

### Task 1: [TBD]
- **Goal**: [TBD]
- **Covers**: [Map to spec AC if available]
- **Depends on**: [TBD]
- **Changes**: [Pre-fill with verified files from Phase 1b]
- **Verification**: [TBD]
- **Rollback**: [TBD]

[Add more task skeletons as needed based on spec/research]

## Risks, Edge Cases & Breaking Changes
- [TBD or pre-fill from spec Edge Cases]

## Testing & Validation
- [TBD]

### Acceptance Criteria Coverage
| Spec AC | Covered By |
|---------|------------|
| [Pre-fill from spec if available] | [TBD] |

## Rollback Strategy (Plan-Level)
- [TBD]

## Open Questions
- [List unknowns from research]
```

**Skeleton rules:**
- Pre-fill from spec: Goals, Non-Goals, Acceptance Criteria, Edge Cases, Backwards Compatibility
- Embed file existence table from Phase 1b into task Changes sections
- Mark unknowns as `[TBD]` or `[TBD: hint]`
- The skeleton drives Phase 2 questions—every TBD is a potential question

### Phase 2: Implementation-Focused Interviewing

Ask questions in batches, prioritized by importance. Put critical questions first so the user can stop answering when there's enough detail. Only ask what you cannot infer from the spec and codebase.

**Interview from the skeleton:** Frame questions around filling TBD placeholders. Example: "Task 2 needs a rollback strategy—options: [A] feature flag disable, [B] revert migration, [C] you decide. Which?"

**Interview Principles**

1. **Propose, don't probe** — Offer concrete implementation options and tradeoffs.
2. **Reference evidence** — "I see feature flags in `config/features.ts`—should this be flag-gated?"
3. **Decide when delegated** — If they say "you decide," choose a safe approach and record it.
4. **Cover gaps, not ground** — Don't re-ask questions the spec or code already answers.
5. **Map to plan template** — Every answer should map to plan sections.

**Question Categories** (adapt order to context):

#### Starting Point & Scope
- Are we following a spec? Is it stable or are there known deviations?
- Is this plan for MVP only, or should it include follow-up tasks?
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
- [ ] Verified file/module list (exists vs New vs ambiguous)
- [ ] Dependencies and rollout strategy
- [ ] Implementation constraints (architectural, areas to avoid)
- [ ] Testing & verification expectations (coverage, quality gates)
- [ ] Mapping from spec Acceptance Criteria to planned tasks/tests
- [ ] Risk/rollback expectations

### Phase 4: Run Multi-Model Generators

Create a temporary prompt file:

```bash
PROMPT_TMP=$(mktemp /tmp/create-plan-prompt-XXXX.md)
cat "${CLAUDE_PLUGIN_ROOT}/prompts/generators/create-plan.md" > "$PROMPT_TMP"
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
${CLAUDE_PLUGIN_ROOT}/bin/generate --type create-plan --mode "$MODE" --prompt-file "$PROMPT_TMP"
```

### Phase 5: Synthesize Drafts

Merge generator drafts into the skeleton structure:

1. **Use the skeleton as canonical structure** — Don't invent new sections
2. **Identify common structure and tasks** — Higher confidence where drafts agree
3. **Resolve conflicts** — Use codebase, spec, and user answers
4. **Fill remaining TBDs** with synthesized content or mark as Open Questions
5. **Enforce template completeness**:
   - Context & Goals (with spec_path)
   - Scope & Non-Goals
   - Assumptions & Constraints (including Implementation and Testing Constraints)
   - Prerequisites
   - High-Level Approach
   - Detailed Plan (with Covers, dependencies, verification, rollback per task)
   - Risks, Edge Cases & Breaking Changes
   - Testing & Validation (with AC Coverage table)
   - Plan-Level Rollback Strategy
   - Open Questions
6. **Respect file existence classification**:
   - Existing files: reference as-is
   - New files: label as **New: `path/to/file`**
7. **Make dependencies explicit** — Note task and external dependencies
8. In `max` mode: include alternatives considered and detailed risk register

### Phase 6: Write the Plan File

Ask the user where to save, or default to:

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

If reviewers find issues:
1. Fix the plan file
2. Re-run the review gate command
3. Iterate until all reviewers pass or mode's max rounds reached:
   - `fast`: 1 round max
   - `smart`: up to 2 rounds
   - `max`: up to 3 rounds

## Done

When the plan passes review:
- Summarize key phases/tasks, major risks, and rollout strategy
- Offer to proceed with implementation
