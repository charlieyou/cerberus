---
name: architecture-review
disable-model-invocation: true
description: Architecture-focused review for high-leverage design improvements and refactors
argument-hint: '[--mode <fast|smart|max>] ["<focus area>"]'
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


# Architecture Review (Multi-Agent Generator)

Perform a **principal-engineer-level** architecture review using multiple AI models (Codex, Gemini, Claude if installed) in parallel to generate comprehensive analysis, then synthesize their findings into a single coherent review.

> **Downstream**: This output feeds directly into `/create-tasks` for ticket creation.

---

## Workflow

### 1. Spawn Generators

Use the Bash tool to spawn architecture review generators. **IMPORTANT**: Set the Bash timeout to 1800000ms (30 minutes) to match the generator's internal ceiling, regardless of mode.

The `cerberus generate` subcommand requires an output directory as the first argument, then accepts `--mode <level>` plus an optional focus string (either `--focus "<text>"` or a trailing free-text argument; use `--` to force focus when needed).

**CRITICAL**: The command MUST start with an executable, NOT a variable assignment. Variable assignments trigger permission prompts.

```bash
mkdir -p "${REVIEW_DIR:-/tmp}/architecture-drafts" && ${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/cerberus generate "${REVIEW_DIR:-/tmp}/architecture-drafts" --type architecture-review $ARGUMENTS
```

Examples:
```bash
# User: /architecture-review --mode fast
${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/cerberus generate "$OUTPUT_DIR" --type architecture-review --mode fast

# User: /architecture-review "focus on error handling"
${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/cerberus generate "$OUTPUT_DIR" --type architecture-review --focus "focus on error handling"

# User: /architecture-review --mode max "review the API layer"
${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/cerberus generate "$OUTPUT_DIR" --type architecture-review --mode max --focus "review the API layer"

# User: /architecture-review --mode fast focus on error handling
${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/cerberus generate "$OUTPUT_DIR" --type architecture-review --mode fast focus on error handling
```

Defaults to `--mode smart` if not specified.

The generator writes drafts to the output directory and returns their paths:
- `$OUTPUT_DIR/codex/draft.md`
- `$OUTPUT_DIR/gemini/draft.md`
- `$OUTPUT_DIR/claude/draft.md`

**IMPORTANT:** The tool result contains only file paths, not the full draft content. This preserves your context window.

### 3. Synthesize Drafts (SUBAGENT REQUIRED)

**You MUST use a subagent (Task tool) to synthesize drafts.** This preserves your main context for the review gate phase.

Use the Task tool with a prompt like:

```
Synthesize the following generator drafts into a single architecture review.

Draft files to read:
- $OUTPUT_DIR/codex/draft.md
- $OUTPUT_DIR/gemini/draft.md
- $OUTPUT_DIR/claude/draft.md

Synthesis rules:
1. Identify common findings across drafts - issues flagged by multiple models have higher confidence
2. Resolve conflicts using your judgment - when models disagree, investigate the code to determine which is correct
3. Deduplicate similar issues - merge overlapping findings into single well-documented issues
4. Calibrate severity - adjust severity levels based on aggregate evidence

Get the artifact path by running: ${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/cerberus artifact-path

Write the synthesized architecture review to that path.

REQUIRED FORMAT - the artifact MUST:
1. Start with: <!-- review-type: architecture-review -->
2. Include a Method block (3-6 bullets): tools run, entry points, key files, assumptions
3. List issues sorted by severity (Critical -> High -> Medium -> Low)
4. Each issue must have: Primary files, Category, Type, Confidence, Source, Context, Fix, Acceptance Criteria, Test Plan

Return the artifact path and a summary of key findings.
```

The subagent will:
1. Read each draft file
2. Get the artifact path from Cerberus
3. Synthesize into the final architecture review
4. Write the review file
5. Return the path and summary to you

**Do NOT read the draft files yourself** — this would blow out your context. Let the subagent handle synthesis.

### 4. Verify and Optionally Copy Artifact

The subagent wrote the artifact. Confirm it exists at the returned path.

Then ask the user: **"Architecture review written to `<artifact-path>`. Would you like to copy it somewhere else (e.g., `docs/`)? If so, provide the destination filename."**

If the user provides a path, copy the artifact there.

---

## Output Format

The subagent should follow this format when writing the artifact.

Start the artifact with the review-type marker (required for review gate):
```
<!-- review-type: architecture-review -->
```

Then include a short **Method** block (3-6 bullets) listing: tools run, entry points reviewed, key files scanned, and assumptions/unknowns.

Recommended bullet labels:
- Tools run:
- Entry points:
- Key files:
- Assumptions/unknowns:
- Generator models used:

Then produce a **single unified list** of issues, sorted by severity (Critical -> High -> Medium -> Low).

For each issue:

```
### [Severity] Short title

**Primary files**: `path/to/file.ts:lines` (list all files touched; approximate lines fine)
**Category**: Boundaries | Testability | Complexity | Duplication | Cohesion | Abstraction
**Type**: bug | task | chore (use task for refactors; chore for cleanup; bug if behavior is broken)
**Confidence**: High | Medium | Low
**Source**: [codex | gemini | both | synthesis] - which model(s) identified this
**Context**:
- What's wrong (1 sentence)
- Why it matters / who or what breaks (1-2 sentences)
**Fix**: Concrete action to resolve (1-3 sentences). Include tests here unless tests are the only change.
**Non-goals**: What's explicitly out of scope (1-2 bullets; recommended for Medium+ severity)
**Acceptance Criteria**: 1-3 bullets
**Test Plan**: 1-2 bullets
**Agent Notes**: Gotchas, edge cases, or constraints an implementer should know (optional)
**Dependencies**: Optional - list other issues that must complete first
```

Keep descriptions tight. If you need more than 3 sentences, you're over-explaining.

---

## No Issues Found

If no high-leverage issues are found, still provide the Method block and output:

```
### No High-Leverage Issues Found

The architecture review found no issues meeting the severity threshold. [Brief note about what was checked and any positive observations about the codebase structure.]
```

---

## Reference: Priority Order

When prioritizing issues:

1. **Boundary clarity & dependency direction** - modules should have crisp responsibilities and one-way dependencies
2. **Testability & change isolation** - changes should be easy to validate without heavy setup
3. **Complexity & duplication hotspots** - high cyclomatic complexity, copy/paste logic, tangled flows
4. **Size & cohesion** - oversized files/modules, "god classes", mixed concerns
5. **Abstraction fitness** - too much abstraction (YAGNI) or too little (leaky, repetitive)

## Reference: Severity Definitions

- **Critical**: Architecture causes production risk or data integrity issues (use sparingly)
- **High**: Architectural debt that blocks feature velocity or safe changes
- **Medium**: Design friction that slows changes but is not blocking
- **Low**: Improvement opportunity with limited ROI
