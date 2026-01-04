---
description: Code health check via multi-model generator and Cerberus gate
argument-hint: [--mode <fast|smart|max>] ["<focus area>"]
---

# Code Health Check (AI-Generated Codebases)

This command runs a multi-model healthcheck where Codex, Gemini, and Claude (if installed) independently analyze the codebase, then you synthesize their findings into a single artifact.

### 1. Run Generators

Use the Bash tool to run the generator command. This spawns all available generators in parallel. **IMPORTANT**: Set the Bash timeout based on mode:
- `--mode fast`: 300000ms (5 minutes)
- `--mode smart`: 600000ms (10 minutes)
- `--mode max`: 900000ms (15 minutes)

The generator requires an output directory as the first argument, then accepts `--mode <level>` plus an optional focus string (either `--focus "<text>"` or a trailing free-text argument; use `--` to force focus when needed).

**CRITICAL**: The command MUST start with an executable, NOT a variable assignment. Variable assignments trigger permission prompts.

```bash
mkdir -p "${REVIEW_DIR:-/tmp}/healthcheck-drafts" && ${CLAUDE_PLUGIN_ROOT}/bin/generate "${REVIEW_DIR:-/tmp}/healthcheck-drafts" --type healthcheck $ARGUMENTS
```

Examples:
```bash
# User: /healthcheck --mode fast
${CLAUDE_PLUGIN_ROOT}/bin/generate "$OUTPUT_DIR" --type healthcheck --mode fast

# User: /healthcheck "focus on the API layer"
${CLAUDE_PLUGIN_ROOT}/bin/generate "$OUTPUT_DIR" --type healthcheck --focus "focus on the API layer"

# User: /healthcheck --mode max "review error handling"
${CLAUDE_PLUGIN_ROOT}/bin/generate "$OUTPUT_DIR" --type healthcheck --mode max --focus "review error handling"

# User: /healthcheck --mode fast focus on error handling
${CLAUDE_PLUGIN_ROOT}/bin/generate "$OUTPUT_DIR" --type healthcheck --mode fast focus on error handling
```

Defaults to `--mode smart` if not specified.

The generator writes drafts to the output directory and returns their paths:
- `$OUTPUT_DIR/codex.md`
- `$OUTPUT_DIR/gemini.md`
- `$OUTPUT_DIR/claude.md`

**IMPORTANT:** The tool result contains only file paths, not the full draft content. This preserves your context window.

### 2. Synthesize Drafts (SUBAGENT REQUIRED)

**You MUST use a subagent (Task tool) to synthesize drafts.** This preserves your main context for the review gate phase.

Use the Task tool with a prompt like:

```
Synthesize the following generator drafts into a single healthcheck artifact.

Draft files to read:
- $OUTPUT_DIR/codex.md
- $OUTPUT_DIR/gemini.md  
- $OUTPUT_DIR/claude.md

Synthesis rules:
1. Identify common findings - Issues flagged by multiple models are likely real
2. Resolve conflicts - When models disagree, use your judgment to pick the correct assessment
3. Deduplicate - Merge similar issues into single entries

You may ignore findings that:
- Flag intentional breaking changes as bugs (API simplification is often deliberate)
- Complain about removed options/parameters that had no functional difference
- Treat consolidation of redundant code paths as a problem

Get the artifact path by running: ${CLAUDE_PLUGIN_ROOT}/bin/review-gate artifact-path

Write the synthesized healthcheck to that path.

REQUIRED FORMAT - the artifact MUST:
1. Start with: <!-- review-type: healthcheck -->
2. Include a Method block (3-6 bullets) noting models used and approach
3. List issues sorted by severity (Critical -> High -> Medium -> Low)
4. Each issue must have: Primary files, Category, Type, Confidence, Context, Fix, Acceptance Criteria, Test Plan

Return the artifact path and a summary of key findings.
```

The subagent will:
1. Read each draft file
2. Get the artifact path from review-gate
3. Synthesize into the final healthcheck
4. Write the healthcheck file
5. Return the path and summary to you

**Do NOT read the draft files yourself** — this would blow out your context. Let the subagent handle synthesis.

### 3. Verify and Optionally Copy Artifact

The subagent wrote the healthcheck file. Confirm it exists at the returned path.

Then ask the user: **"Healthcheck written to `<artifact-path>`. Would you like to copy it somewhere else (e.g., `docs/`)? If so, provide the destination filename."**

If the user provides a path, copy the artifact there.

---

## Output Format

Start the artifact with the review-type marker (required for review gate):
```
<!-- review-type: healthcheck -->
```

Include a short **Method** block (3-6 bullets) noting that this was synthesized from multiple model analyses.

Then produce a **single unified list** of issues, sorted by severity (Critical first, then High, Medium, Low).

For each issue:

```
### [Severity] Short title

**Primary files**: `path/to/file.ts:lines`
**Category**: Correctness | Dead Code | AI Smell | Structure | Hygiene | Config Drift
**Type**: bug | task | chore
**Confidence**: High | Medium | Low
**Context**:
- What's wrong (1 sentence)
- Why it matters (1-2 sentences)
**Fix**: Concrete action to resolve (1-3 sentences)
**Acceptance Criteria**: 1-3 bullets
**Test Plan**: 1-2 bullets
```

---

## Severity Definitions

- **Critical**: Would cause data loss, security breach, or crash in production
- **High**: Will cause bugs under realistic conditions
- **Medium**: Correct but hard to maintain. Creates drag but doesn't break things
- **Low**: Style, naming, minor inconsistency

---

## Priority Order

When synthesizing, prioritize:

1. **Correctness & data integrity** - bugs, edge cases, unsafe behavior
2. **Delete & simplify** - dead code, unused abstractions
3. **Consistency & clarity** - same problem → same pattern
4. **Tests** - critical flows must be tested
5. **Performance** - only where there's a problem

---

> **Note**: The review gate stop hook will automatically evaluate your artifact once written.
