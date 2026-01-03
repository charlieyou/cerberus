---
description: Code health check via multi-model generator and Cerberus gate
argument-hint: [--mode <fast|smart|max>] ["<focus area>"]
---

# Code Health Check (AI-Generated Codebases)

This command runs a multi-model healthcheck where Codex, Gemini, and Claude (if installed) independently analyze the codebase, then you synthesize their findings into a single artifact.

## Step 1: Run Generators

Use the Bash tool to run the generator command. This spawns all available generators in parallel. **IMPORTANT**: Set the Bash timeout based on mode:
- `--mode fast`: 300000ms (5 minutes)
- `--mode smart`: 600000ms (10 minutes)
- `--mode max`: 900000ms (15 minutes)

The generator requires an output directory as the first argument, then accepts `--mode <level>` plus an optional focus string (either `--focus "<text>"` or a trailing free-text argument; use `--` to force focus when needed).

```bash
OUTPUT_DIR=$([[ -n "${REVIEW_DIR:-}" ]] && echo "$REVIEW_DIR/healthcheck-drafts" || mktemp -d)
${CLAUDE_PLUGIN_ROOT}/bin/generate "$OUTPUT_DIR" --type=healthcheck $ARGUMENTS
```

Examples:
```bash
# User: /healthcheck --mode fast
${CLAUDE_PLUGIN_ROOT}/bin/generate "$OUTPUT_DIR" --type=healthcheck --mode fast

# User: /healthcheck "focus on the API layer"
${CLAUDE_PLUGIN_ROOT}/bin/generate "$OUTPUT_DIR" --type=healthcheck --focus "focus on the API layer"

# User: /healthcheck --mode max "review error handling"
${CLAUDE_PLUGIN_ROOT}/bin/generate "$OUTPUT_DIR" --type=healthcheck --mode max --focus "review error handling"

# User: /healthcheck --mode fast focus on error handling
${CLAUDE_PLUGIN_ROOT}/bin/generate "$OUTPUT_DIR" --type=healthcheck --mode fast focus on error handling
```

Defaults to `--mode smart` if not specified.

The generator writes drafts to the output directory and returns their paths:
- `$OUTPUT_DIR/codex.md`
- `$OUTPUT_DIR/gemini.md`
- `$OUTPUT_DIR/claude.md`

**IMPORTANT:** The tool result contains only file paths, not the full draft content. This preserves your context window.

## Step 2: Synthesize the Drafts

After receiving the generator output, synthesize the drafts into a single coherent healthcheck artifact:

1. **Identify common findings** - Issues flagged by both models are likely real
2. **Resolve conflicts** - When models disagree, use your judgment to pick the correct assessment
3. **Deduplicate** - Merge similar issues into single entries
4. **Structure the output** - Follow the format below

**You may ignore reviewer feedback that:**
- Flags intentional breaking changes as bugs (API simplification is often deliberate)
- Complains about removed options/parameters that had no functional difference
- Treats consolidation of redundant code paths as a problem

## Step 3: Write the Artifact

Get the artifact path:
```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate artifact-path
```

Then write the synthesized healthcheck to that path.

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
