# Code Health Check Analysis

**IMPORTANT: This is a READ-ONLY review. Do NOT modify any files. Only analyze and report findings.**

Perform a thorough code health analysis of this codebase. Focus on finding real issues that matter.

## Guidelines for Flagging Issues

1. The issue meaningfully impacts code quality, correctness, or maintainability.
2. The issue is discrete and actionable (not a general concern).
3. You must provide evidence - specific file paths and line numbers.
4. The fix should be straightforward; don't flag issues requiring major refactors.
5. Don't flag style preferences unless they obscure meaning.
6. The issue should be worth fixing now, not "someday".
7. Only cite issues you can point to in code you actually inspected.
8. Do not rely on unstated assumptions; if you're not confident, skip it.
9. Keep line ranges as tight as possible (avoid ranges over 5-10 lines).
10. Use one issue per distinct problem.
11. If there is no issue a maintainer would definitely fix, prefer no findings.

## Comment Guidelines

1. Be clear about what the issue is and why it matters.
2. Communicate severity appropriately - don't overstate.
3. Keep descriptions brief (1 paragraph max per issue).
4. Include specific file paths and line references.
5. Suggest concrete fixes.
6. Maintain a matter-of-fact, helpful tone.
7. If you include code, quote 3 lines or fewer.
8. Call out the concrete scenario that makes the issue matter.

## Traversal Strategy

1. **Start at entry points**: `main.py`, `index.ts`, `app.py`, route definitions, exported modules
2. **Follow the dependency graph** from entry points to understand what's actually used
3. **Find hotspots**: large files (>400 lines), utils/helpers directories, files with TODO/FIXME comments
4. **Trace reachability**: code not reachable from entry points = dead code candidate
5. **Trace value flow**: For config/options, follow them from parsing to where they affect behavior. If a value is captured but never influences a branch or output, it's semantic dead code.

## Categories to Analyze

### Dead Code & Redundancy
- Unused functions, classes, variables, imports, modules
- Placeholder implementations (`return null`, `// TODO: implement`)
- Multiple implementations of the same thing (logging, HTTP clients, config loading)

### AI-Specific Smells
- Hallucinated or misused APIs (methods that don't exist, wrong parameter order)
- Partial implementations (only happy path, missing error handling)
- Redundant abstraction layers (thin wrappers, over-parameterized helpers)

### Structural Issues
- Large files mixing unrelated concerns
- Oversized functions (>50 lines, deeply nested)
- Misplaced code (domain logic in utils, feature code in common)

### Correctness & Robustness
- Critical paths without tests
- Missing error handling, swallowed exceptions
- Type/contract mismatches between layers

### Hygiene
- Debug cruft (console.log, print, debugger)
- Stale TODOs
- Build artifacts in source control

### Behavioral Inconsistencies
- Same operation implemented differently across functions (e.g., different fallback chains)
- Similar commands with inconsistent parameter handling
- Environment variable usage that differs between related code paths

### Semantic Redundancy
- Values that are set but never branched on
- Parameters/options that have no functional difference
- Switch cases that all do the same thing
- Enums/constants that aren't distinguished in behavior

### API Symmetry
- Related commands should have consistent behavior
- If function A falls back to X, similar function B should too
- Trace a value from input to where it affects output - if it doesn't, flag it

### Cross-File Consistency
- Same pattern should be used everywhere; if 9/10 functions handle errors one way and 1 does it differently, flag the outlier
- Near-identical code blocks that should be extracted into a shared function (copy-paste detection)

### Test Coverage Gaps
- Public functions with no test that calls them
- Critical code paths that lack any test coverage

### Configuration Drift
- Hardcoded values that should match config
- Config values that don't match reality (docs say X, code does Y)
- Multiple sources of truth for the same setting

### Error Message Quality
- Errors that don't include enough context to debug (e.g., "Failed" vs "Failed to connect to X: timeout after 30s")
- Swallowed errors that log nothing

### Boundary Validation
- Public APIs that don't validate inputs
- Internal functions that unnecessarily validate (validation should happen at boundaries, not everywhere)

### Naming vs Behavior Mismatch
- Function named `getX` that also sets state
- `isValid` that throws instead of returning false
- `create` that sometimes returns existing object

### Implicit Dependencies
- Code that assumes environment variables exist without checking
- Code that assumes files/directories exist without checking
- Hidden coupling to global state

## Priority Levels

- [P0] - Critical. Broken functionality or security issue.
- [P1] - Urgent. Should fix soon.
- [P2] - Normal. Fix when convenient.
- [P3] - Low. Nice to clean up.

## What to Ignore

- Minor style inconsistencies
- Personal preferences about naming
- "Could be better" without concrete improvement
- Issues requiring significant refactoring effort
- Pre-existing issues not worth prioritizing now

## Breaking Changes

Breaking changes to external APIs should only be flagged as P0/P1 if:
- There is a caller in the same codebase that would break
- The change is clearly unintentional (e.g., typo, copy-paste error)

Otherwise, treat intentional API simplification as informational (P2/P3). The author may be deliberately removing unused options or consolidating behavior.

## Output

Output your findings as JSON for easier synthesis:

```json
{
  "findings": [
    {
      "priority": "P1",
      "title": "Short descriptive title",
      "category": "Behavioral Inconsistencies",
      "files": ["path/to/file.ts:42-45"],
      "description": "What's wrong and why it matters (1 paragraph max)",
      "fix": "Concrete suggested fix"
    }
  ],
  "summary": "Brief overall assessment (1-2 sentences)"
}
```

If there are no strong findings, output `{"findings": [], "summary": "No significant issues found."}`.

Be thorough but concise. Focus on issues that actually matter for code health.

## CRITICAL RULES

1. **DO NOT modify, create, or delete any files** - this is analysis only
2. **DO NOT attempt to fix issues** - only report them
3. **DO NOT install packages or run commands that change state**
4. You may only use read operations: list files, read files, search content
