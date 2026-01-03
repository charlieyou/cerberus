---
description: Architecture-focused review for high-leverage design improvements and refactors
argument-hint: [--mode <fast|smart|max>] ["<focus area>"]
---

# Architecture Review (Multi-Agent Generator)

Perform a **principal-engineer-level** architecture review using multiple AI models (Codex, Gemini, Claude if installed) in parallel to generate comprehensive analysis, then synthesize their findings into a single coherent review.

> **Downstream**: This output feeds directly into `/bd-breakdown` for ticket creation.

---

## Workflow

### 1. Run Analysis Tools (Outside the Model)

Run any analysis tooling directly in Bash, then pass the outputs into the generator via `--analysis-file`. This keeps the model read-only while still benefiting from tool data.

Example (adjust paths/package names as needed):

```bash
ANALYSIS_TMP=$(mktemp)

{
  echo "## lizard"
  if command -v uvx >/dev/null 2>&1; then
    uvx lizard -C 15 -L 80 -w src | head -n 50
  else
    echo "uvx not available (install uv to run lizard)"
  fi
  echo ""
  echo "## grimp"
  if [[ -x "$HOME/.claude/skills/grimp-architecture/.venv/bin/python" ]]; then
    # Adjust PKG and PYTHONPATH for your project layout:
    # - Standard layout (mypackage/):     PKG=mypackage, PYTHONPATH=.
    # - src layout (src/mypackage/):      PKG=mypackage, PYTHONPATH=src
    # - Flat src layout (src/__init__.py): PKG=src, PYTHONPATH=.
    PKG="src"
    PYTHONPATH="." \
      $HOME/.claude/skills/grimp-architecture/.venv/bin/python \
      $HOME/.claude/skills/grimp-architecture/scripts/explore.py "$PKG" || true
  else
    echo "grimp not available"
  fi
} > "$ANALYSIS_TMP"
```

You can add more tools (e.g., jscpd) by appending sections to the same file.

### 2. Spawn Generators

Use the Bash tool to spawn architecture review generators. **IMPORTANT**: Set the Bash timeout based on mode:
- `--mode fast`: 300000ms (5 minutes)
- `--mode smart`: 600000ms (10 minutes)
- `--mode max`: 900000ms (15 minutes)

The generator requires an output directory as the first argument, then accepts `--mode <level>` plus an optional focus string (either `--focus "<text>"` or a trailing free-text argument; use `--` to force focus when needed).
If you skip the analysis step, omit `--analysis-file`.

```bash
${CLAUDE_PLUGIN_ROOT}/bin/generate "$([[ -n "${REVIEW_DIR:-}" ]] && echo "$REVIEW_DIR/architecture-drafts" || mktemp -d)" --type architecture-review --analysis-file "$ANALYSIS_TMP" $ARGUMENTS
```

Examples:
```bash
# User: /architecture-review --mode fast
${CLAUDE_PLUGIN_ROOT}/bin/generate "$OUTPUT_DIR" --type architecture-review --analysis-file "$ANALYSIS_TMP" --mode fast

# User: /architecture-review "focus on error handling"
${CLAUDE_PLUGIN_ROOT}/bin/generate "$OUTPUT_DIR" --type architecture-review --analysis-file "$ANALYSIS_TMP" --focus "focus on error handling"

# User: /architecture-review --mode max "review the API layer"
${CLAUDE_PLUGIN_ROOT}/bin/generate "$OUTPUT_DIR" --type architecture-review --analysis-file "$ANALYSIS_TMP" --mode max --focus "review the API layer"

# User: /architecture-review --mode fast focus on error handling
${CLAUDE_PLUGIN_ROOT}/bin/generate "$OUTPUT_DIR" --type architecture-review --analysis-file "$ANALYSIS_TMP" --mode fast focus on error handling
```

Defaults to `--mode smart` if not specified.

The generator writes drafts to the output directory and returns their paths:
- `$OUTPUT_DIR/codex.md`
- `$OUTPUT_DIR/gemini.md`
- `$OUTPUT_DIR/claude.md`

**IMPORTANT:** The tool result contains only file paths, not the full draft content. This preserves your context window.

### 3. Synthesize Drafts

The generator output contains drafts from multiple models. Synthesize them into a single coherent architecture review by:

1. **Identify common findings** across drafts - issues flagged by multiple models have higher confidence
2. **Resolve conflicts** using your judgment - when models disagree, investigate the code to determine which is correct
3. **Deduplicate similar issues** - merge overlapping findings into single well-documented issues
4. **Calibrate severity** - adjust severity levels based on aggregate evidence

### 4. Produce Final Review

Create a unified architecture review artifact following the output format below.

---

## Output Format

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

## Final Step

After completing the review, use the Bash tool to get the session-scoped artifact path:

```
${CLAUDE_PLUGIN_ROOT}/bin/review-gate artifact-path
```

Then use the Write tool to save this entire review output to that path (use the exact path returned):

```
Write the complete review above to <paste the path printed above>
```

This enables automatic Cerberus validation if configured.

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
