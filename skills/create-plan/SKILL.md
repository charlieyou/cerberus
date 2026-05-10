---
name: create-plan
disable-model-invocation: true
description: Produce a technical implementation plan (design-focused), optionally interviewing the user, then run multi-model generator and plan review gate
argument-hint: '[--mode <fast|smart|max>] [--max-rounds <N>] [--from-spec <path/to/spec.md>] [--skip-interview] <feature or plan summary>'
---

## Host-Neutral Execution

Before running any Bash snippet in this skill, run the shared Cerberus resolver below. It lazily builds and executes `bin/cerberus` from the configured plugin root.

```bash
# --- shared resolver (canonical body; identical across all callers) ---
root="${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}"
bin="$root/bin/cerberus"
[ -n "$root" ] || { echo "cerberus: plugin root not set" >&2; exit 127; }
export CERBERUS_ROOT="$root"
command -v make >/dev/null 2>&1 || { echo "cerberus: make not found on PATH; install make and retry." >&2; exit 127; }
if ! make -q -C "$root" build >/dev/null 2>&1; then
    command -v go >/dev/null 2>&1 || { echo "cerberus: Go >= 1.22 not found on PATH; install Go and retry." >&2; exit 127; }
    echo "cerberus: building... (this happens once after clone or upgrade)" >&2
    start=$(date +%s)
    make -C "$root" build >&2 || exit $?
    end=$(date +%s)
    echo "cerberus: build complete in $((end-start))s" >&2
fi
# --- shared resolver above; per-caller exec below (allowed to diverge) ---
exec "$bin" "$@"
```

Use `bin/cerberus` through the configured plugin root when invoking Cerberus commands below.


# Create Plan (Interview/Autonomous + Multi-Model Generator)

Turn a spec or vague feature idea into a **design-focused implementation plan** by combining codebase research (including file existence checks), either a targeted implementation-focused interview or an autonomous decision pass, multi-model generation, and a plan review gate.

> **Note**: This command produces a **design plan** (architecture, constraints, approach). Task breakdown is handled separately by `/create-tasks`, which reads this plan and outputs to Beads issues (`--beads`) or TODO.md.

## Execution Contract (MANDATORY)

You **MUST** follow these phases in order. Skipping phases is **NOT ALLOWED**, except that `--skip-interview` replaces the interactive interview portion of Phase 2 with an autonomous decision pass:

1. **Phase 0–1b**: Research codebase + integration point analysis + verify file existence
2. **Phase 1c**: Write initial plan with `[TBD]` placeholders to a file (this becomes the canonical doc)
3. **Phase 2**: Run an interview focused on filling `[TBD]` placeholders, or if `--skip-interview` is set, make and document autonomous decisions for those placeholders
4. **Phase 3**: Build context from plan file + user answers or autonomous decisions
5. **Phase 4**: Call generators (writes drafts to files)
6. **Phase 5**: Use a **subagent** to synthesize drafts into the plan file
7. **Phase 6**: Verify plan file is complete
8. **Phase 7**: Run review gate

**Hard Rules:**
- You are **NOT ALLOWED** to produce the final synthesized plan before Phase 5; Phase 2 may only fill skeleton placeholders with user answers or documented autonomous decisions for generator context
- You **MUST** output an initial plan with `[TBD]` markers in Phase 1c
- You **MUST** interview the user in Phase 2 before calling generators unless `--skip-interview` is set
- You **MUST** wait for user answers before proceeding to Phase 3 unless `--skip-interview` is set
- If `--skip-interview` is set, you **MUST NOT** ask plan-generation clarifying questions; instead, make safe decisions from the spec, codebase evidence, and existing project patterns, then document every decision and rationale in the plan
- If the user asks to "skip the interview" or "just generate the plan" without passing `--skip-interview`, explain the workflow and proceed with skeleton + interview
- At the start of each major phase (0–7), explicitly state which phase you are in and what you will do next

## Success Criteria (Mandatory)

✅ **Produce skeleton with `[TBD]` placeholders in Phase 1c** — The initial plan file must contain unfilled placeholders, not completed content.

✅ **Run at least one interview batch in Phase 2 unless `--skip-interview` is set** — Use `AskUserQuestion` to confirm assumptions, even if the spec seems complete.

✅ **Honor `--skip-interview` explicitly** — Do not ask clarifying questions; fill placeholders through documented autonomous decisions and mark unsafe/product-owned decisions as Open Questions.

✅ **Follow the workflow when user asks to skip without the flag** — If user says "just generate the plan" but did not pass `--skip-interview`, explain the workflow and proceed with skeleton + interview.

✅ **Write generator drafts to files** — Call `cerberus generate`, which writes drafts to disk; pass file paths to the synthesis subagent.

✅ **Delegate synthesis to a subagent** — Use the Task tool for synthesis to preserve your main context for the review gate.

## Mode Behavior

Modes control depth and rigor. Use soft budgets—exit early when quality is sufficient.

| Mode | Interview Depth | Review Rounds | Extras |
|------|-----------------|---------------|--------|
| fast | Until essentials filled (~60%) | up to 2 | minimal |
| smart | Until ~80% filled | up to 3 | standard |
| max | Until ~95% filled + proactive probing | up to 5 | alternatives + detailed risk register |

With `--skip-interview`, apply the same depth targets to the autonomous decision pass instead of asking questions.

**Override:** `--max-rounds <N>` sets the review round cap explicitly, overriding the mode default. Accepts any integer ≥ 0 (0 skips the review refinement loop entirely after the initial gate run).

**Soft budget rules:**
- Stop interviewing or deciding when skeleton is sufficiently filled and essentials (Prerequisites, Technical Design, Testing strategy) are covered
- In `fast`, prioritize speed over completeness—mark unknowns as Open Questions
- In `max`, actively probe for edge cases and failure modes even if user doesn't raise them

## Input

The user provides either:

- A **feature or implementation summary**, e.g.:
  - "implement backend + UI for batch exports"
  - "execute the auth spec in docs/2025-01-10-auth-spec.md"
- Optionally, a **spec path** via `--from-spec path/to/spec.md`
- Optionally, `--skip-interview` to skip user questions and have the command make and document its own implementation decisions

## Argument Handling

Before Phase 0, parse command arguments:

- `SKIP_INTERVIEW=true` only when the explicit `--skip-interview` flag is present.
- Otherwise leave `SKIP_INTERVIEW` unset or set it to `false`; command examples must check `[[ "${SKIP_INTERVIEW:-false}" == "true" ]]` before forwarding the flag.
- Remove `--skip-interview` from the feature summary before writing the plan.
- If `--skip-interview` is not present, free-text phrases like "skip the interview" or "just generate it" are not enough to enter autonomous mode; follow the normal interview workflow.
- If `--from-spec` is not provided and `--skip-interview` is set, treat the remaining feature summary as the starting artifact instead of asking whether a spec exists.

## Workflow

### Phase 0: Choose Starting Point

Before deep research, establish what you're planning against:

1. **Detect a spec (if any)**:
   - If `--from-spec` is provided, use that path.
   - Otherwise, if `--skip-interview` is set, do not ask; record `spec_path` as N/A and use the user's feature summary as the starting artifact.
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
- The skeleton MUST contain `[TBD]` placeholders — fill them only during Phase 2 from user answers or documented autonomous decisions
- If `--skip-interview` is not set, present the skeleton and your first batch of interview questions via `AskUserQuestion`
- If `--skip-interview` is set, do not present interview questions; immediately proceed to the Phase 2 autonomous decision pass

**PHASE 2 GATE**: If `--skip-interview` is not set, after sending Interview Batch 1, end your turn immediately. Do not proceed to Phase 3+ until the user answers or issues a stop signal. This gate is mandatory for interactive mode.

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

### Decision Log
| Decision | Rationale | Evidence | Tradeoff / Risk / Follow-up |
|----------|-----------|----------|------------------------------|
| [TBD: decisions made during interview or autonomous mode] | [TBD] | [TBD] | [TBD] |

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

| Path | Status | Description |
|------|--------|-------------|
| `src/auth/middleware.ts` | Exists | Modify existing middleware |
| `src/auth/session.ts` | **New** | Create session helper |
| `tests/auth/session.test.ts` | **New** | Add tests |

## Risks, Edge Cases & Breaking Changes

### Edge Cases & Failure Modes
- [TBD or pre-fill from spec Edge Cases]

### Breaking Changes & Compatibility
- **Potential Breaking Changes**: [TBD]
- **Mitigations**: [TBD]

## Testing & Validation Strategy
- [TBD: Types of tests needed (unit, integration, e2e)]
- [TBD: Coverage requirements]
- [TBD: Manual validation steps]

### Acceptance Criteria Coverage
| Spec AC | Approach |
|---------|----------|
| [Pre-fill from spec if available] | [How this plan addresses it] |

## Spec/Legacy Fidelity
[If a spec/legacy doc exists, confirm the plan matches it. Any deviations must be explicit.]

### Deviation Log
| Source | Deviation | Rationale | Approved? |
|--------|-----------|-----------|-----------|
| None | — | — | — |

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

### Phase 2: Prioritized BFS Interview or Autonomous Decision Pass

**Prerequisites:** Phase 1c skeleton MUST exist before starting Phase 2.

#### Autonomous Decision Pass (`--skip-interview`)

If `SKIP_INTERVIEW=true`, replace the interactive interview with this pass:

1. **Do not use `AskUserQuestion` for plan-generation clarification.** The flag is the user's explicit delegation signal.
2. **Fill each `[TBD]` from evidence where possible** using the spec, codebase research, integration table, verified file list, and established project patterns.
3. **Choose safe defaults** for ambiguous implementation details: extend existing mechanisms, keep changes reversible, prefer feature flags for risky behavior, and use the repository's normal test layers.
4. **Document every autonomous decision** in `### Decision Log` with rationale, evidence, tradeoff, and risk/follow-up. Also mirror durable assumptions in `## Assumptions & Constraints`.
5. **Do not hide uncertainty.** If a decision is product-owned, irreversible, security-sensitive, or unsafe to guess, leave it in `## Open Questions` and design the plan so implementation can pause at that boundary.
6. **Declare Phase 2 complete** once the skeleton has no unexplained `[TBD]` placeholders except intentionally retained Open Questions.

Treat these as unsafe unknowns unless directly specified by the spec or strongly established by codebase patterns:

- Product scope or UX behavior that changes user-visible semantics.
- Irreversible data migrations or destructive operations.
- Security, privacy, permission, compliance, or data-retention choices.
- External API contracts or backwards-incompatible behavior.
- Cost, performance, or SLO commitments.
- Ownership or operational responsibility across teams/services.

For unsafe unknowns, do not ask the user in skip-interview mode and do not silently choose. List the item in Open Questions and design the implementation so work can pause before the unsafe boundary.

After this pass, proceed directly to Phase 3 in the same turn.

#### Interactive Interview (default)

If `SKIP_INTERVIEW=false`, run the interview below.

**Load the interview engine:** Read `${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}/prompts/interview-engine.md` for the full mechanism. Key principles below.

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
- [ ] Either you have run at least one batch of Phase 2 interview questions, or `--skip-interview` is set and the autonomous decision pass is complete
- [ ] Either you have collected user answers for the critical TBDs, or you have documented autonomous decisions/open questions for them
- [ ] Any remaining unknowns are marked as Open Questions

Create a compact context block for generators:

- **Current plan file** (with TBDs filled from interview or autonomous decisions, remaining gaps marked)
- **Implementation target summary** (1–2 paragraphs)
- **Starting artifacts**: Spec path + summary (if any)
- **Codebase findings**: Key files/modules, patterns, constraints, ownership
- **File existence table**: For each path: Exists / New / Ambiguous
- **User answers or autonomous decisions**: Structured bullets mapped to plan sections
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
- [ ] Decision Log with rationale/evidence for major decisions, especially autonomous ones
- [ ] Mapping from spec Acceptance Criteria to design approach

### Phase 4: Run Multi-Model Generators

Create and remember a temporary prompt file:

**CRITICAL**: The command MUST start with an executable, NOT a variable assignment. Variable assignments trigger permission prompts.

```bash
export PROMPT_TMP="$(mktemp "${TMPDIR:-/tmp}/create-plan-prompt-XXXXXX")" && test -f "$PROMPT_TMP" && printf 'PROMPT_TMP=%s\n' "$PROMPT_TMP"
```

This creates a unique temp file like `/tmp/create-plan-prompt-abc123`. Do **not** use a top-level `PROMPT_TMP=$(mktemp ...)` assignment, and do **not** add a suffix like `.md`; BSD/macOS `mktemp` only replaces trailing `X` characters.

Record the printed `PROMPT_TMP=...` value. Bash variables may not persist across separate tool calls; if you run a later command in a new shell, either substitute the printed path directly or start the command with `export PROMPT_TMP='<printed-path>' && ...`.

Then populate the file:

```bash
cat "${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}/prompts/generators/create-plan.md" > "$PROMPT_TMP" && cat >> "$PROMPT_TMP" <<'EOF'

## Context

EOF
```

Now append the Phase 3 context (skeleton + findings + user answers or autonomous decisions) to `$PROMPT_TMP`.

Spawn generators with the mode flag. The `cerberus generate` subcommand requires an output directory as the first argument and writes drafts to files, returning their paths:
- `fast`: ~5 minutes
- `smart`: ~10 minutes
- `max`: ~15 minutes

If `--skip-interview` was passed to this command, add `--skip-interview` to the `cerberus generate` invocation so the model drafts also make and document autonomous decisions instead of asking clarifying questions.

**CRITICAL**: The command MUST start with an executable, NOT a variable assignment. Variable assignments trigger permission prompts.

```bash
export OUTPUT_PARENT="${REVIEW_DIR:-${TMPDIR:-/tmp}}" && mkdir -p "$OUTPUT_PARENT" && export OUTPUT_DIR="$(mktemp -d "$OUTPUT_PARENT/create-plan-drafts-XXXXXX")" && test -d "$OUTPUT_DIR" && printf 'OUTPUT_DIR=%s\n' "$OUTPUT_DIR" && if [[ "${SKIP_INTERVIEW:-false}" == "true" ]]; then root="${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}"; bin="$root/bin/cerberus"; [ -n "$root" ] || { echo "cerberus: plugin root not set" >&2; exit 127; }; export CERBERUS_ROOT="$root"; if ! make -q -C "$root" build >/dev/null 2>&1; then make -C "$root" build >&2 || exit $?; fi; "$bin" generate "$OUTPUT_DIR" --type create-plan --mode "${MODE:-smart}" --prompt-file "$PROMPT_TMP" --skip-interview; else root="${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}"; bin="$root/bin/cerberus"; [ -n "$root" ] || { echo "cerberus: plugin root not set" >&2; exit 127; }; export CERBERUS_ROOT="$root"; if ! make -q -C "$root" build >/dev/null 2>&1; then make -C "$root" build >&2 || exit $?; fi; "$bin" generate "$OUTPUT_DIR" --type create-plan --mode "${MODE:-smart}" --prompt-file "$PROMPT_TMP"; fi
```

Record the printed `OUTPUT_DIR=...` value and the exact draft paths printed by `cerberus generate`. Do not pass literal `$OUTPUT_DIR/...` paths to a subagent unless you have replaced `$OUTPUT_DIR` with the actual printed directory. The expected draft paths are:
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
[Paste the actual draft paths printed by `cerberus generate`; include only existing `draft.md` files from successful generators.]
- /actual/output/dir/codex/draft.md
- /actual/output/dir/gemini/draft.md
- /actual/output/dir/claude/draft.md

Plan file to update: docs/YYYY-MM-DD-FEATURE-plan.md

Synthesis rules:
1. Use the existing plan file as the canonical structure. Preserve its section order, but add any missing required sections from the create-plan template rather than dropping generator content.
2. Identify common structure and tasks — higher confidence where drafts agree
3. Resolve conflicts using the spec and codebase patterns
4. Fill remaining [TBD] placeholders with synthesized content
5. Mark unresolved items as Open Questions
6. Respect file existence: label new files as "New: path/to/file"
7. Preserve and complete the Decision Log; if `--skip-interview` was used, include every autonomous decision with rationale, evidence, tradeoff, and risk/follow-up
8. Ensure all template sections are complete:
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

If `--skip-interview` was used, also confirm `### Decision Log` documents the autonomous decisions, their rationale, supporting evidence, tradeoffs, and risk/follow-up.

### Phase 7: Review Gate with Prioritized BFS Refinement

Spawn external reviewers on the plan file. Pass `--max-rounds` so the daemon's auto-respawn limit matches the command-level cap:

- If `--max-rounds <N>` was passed to this command, forward that N.
- Otherwise forward the mode default: `fast=2`, `smart=3`, `max=5`.

```bash
root="${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}"; bin="$root/bin/cerberus"; [ -n "$root" ] || { echo "cerberus: plugin root not set" >&2; exit 127; }; export CERBERUS_ROOT="$root"; if ! make -q -C "$root" build >/dev/null 2>&1; then make -C "$root" build >&2 || exit $?; fi; "$bin" spawn-plan-review --max-rounds "$MAX_ROUNDS" docs/YYYY-MM-DD-FEATURE-plan.md
```

**CRITICAL: After running the spawn command, STOP IMMEDIATELY. Do NOT poll, sleep, wait, or run any further commands.** The Stop hook will automatically wait for reviewers and present their findings when you stop. Any attempt to manually check reviewer status will fail.

`--skip-interview` only skips Phase 0 spec-path questioning and the Phase 2 implementation interview. It does not skip the review gate.

During review refinement in skip-interview mode:
- Silently fix mechanical issues.
- For safe, conventional design fixes, apply the same autonomous-decision rules and record the decision in the Decision Log.
- For unsafe/product-owned reviewer findings, mark them as Open Questions or approval-required risks.
- Only use `AskUserQuestion` if the review gate cannot proceed without a human decision.

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
- `fast`: up to 2 rounds (P0/P1 only)
- `smart`: up to 3 rounds (P0-P2)
- `max`: up to 5 rounds (all priorities)

If `--max-rounds <N>` was passed, use N instead of the mode default. Priority scope still follows the mode (fast=P0/P1, smart=P0–P2, max=all). `--max-rounds 0` skips refinement entirely — record any reviewer findings as Open Questions and exit.

## Done

When the plan passes review:
- Summarize key design decisions and major risks
- Offer next step: **Run `/create-tasks`** to generate execution artifacts:
  - `--beads` → Create Beads issues with dependencies for multi-agent parallelization
  - (default) → Generate TODO.md checklist for simpler tracking
