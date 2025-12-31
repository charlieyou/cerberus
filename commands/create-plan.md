---
description: Interview the user to produce an implementation plan, then run multi-model generator and plan review gate
argument-hint: [--mode <fast|smart|max>] [--from-spec <path/to/spec.md>] <feature or plan summary>
---

# Create Plan (Interview + Multi-Model Generator)

Turn a spec or vague feature idea into a concrete, executable implementation plan by combining codebase research (including file existence checks), a targeted implementation-focused interview, multi-model generation, and a plan review gate.

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
     - Goals, scope, Implementation Plan section (if present), and testing/rollback sections.

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
   - The spec (especially Implementation Plan / Technical Design sections).
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

### Phase 2: Implementation-Focused Interviewing

Ask 2–4 questions at a time. Only ask what you cannot infer from the spec and codebase.

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

Create a compact context block for generators:

- **Implementation target summary** (1–2 paragraphs)
- **Starting artifacts**: Spec path + summary (if any)
- **Codebase findings**: Key files/modules, patterns, constraints, ownership
- **File existence table**: For each path: Exists / New / Ambiguous
- **User answers**: Structured bullets mapped to plan sections
- **Decisions made + rationale**
- **Remaining open questions**

**Context Checklist**:
- [ ] Clear target (spec/feature) + links/paths
- [ ] Scope (MVP vs follow-ups) and Non-Goals
- [ ] Verified file/module list (exists vs New vs ambiguous)
- [ ] Dependencies and rollout strategy
- [ ] Testing & verification expectations
- [ ] Risk/rollback expectations

### Phase 4: Run Multi-Model Generators

Create a temporary prompt file:

```bash
PROMPT_TMP=$(mktemp /tmp/create-plan-prompt-XXXX.md)
cat "${CLAUDE_PLUGIN_ROOT}/prompts/generators/create-plan.md" > "$PROMPT_TMP"
cat >> "$PROMPT_TMP" <<'EOF'

## Context

[Paste the context you built in Phase 3]
EOF
```

Spawn generators with timeout based on mode:
- `--mode fast`: 300000ms (5 minutes)
- `--mode smart`: 600000ms (10 minutes)
- `--mode max`: 900000ms (15 minutes)

```bash
${CLAUDE_PLUGIN_ROOT}/bin/generate --type create-plan --prompt-file "$PROMPT_TMP" $ARGUMENTS
```

Defaults to `--mode smart` if not specified.

### Phase 5: Synthesize Drafts

Synthesize generator drafts into a single plan:

1. **Identify common structure and tasks** — Higher confidence where drafts agree
2. **Resolve conflicts** — Use codebase and user answers
3. **Enforce template completeness**:
   - Context & Goals
   - Scope & Non-Goals
   - Assumptions & Constraints
   - Prerequisites
   - High-Level Approach
   - Detailed Plan (with dependencies, verification, rollback per task)
   - Risks, Edge Cases & Breaking Changes
   - Testing & Validation
   - Plan-Level Rollback Strategy
   - Open Questions
4. **Respect file existence classification**:
   - Existing files: reference as-is
   - New files: label as **New: `path/to/file`**
5. **Make dependencies explicit** — Note task and external dependencies
6. **Attach verification & rollback to tasks**

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
3. Iterate until all reviewers pass (or max rounds reached)

## Done

When the plan passes review:
- Summarize key phases/tasks, major risks, and rollout strategy
- Offer to proceed with implementation
