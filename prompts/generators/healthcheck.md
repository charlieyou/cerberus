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

## Output

Write your findings as free-form analysis. For each issue include:
- Priority tag [P0-P3] and short title
- File paths and line numbers
- Why the issue matters (1 paragraph max)
- Suggested fix (brief and concrete)

Be thorough but concise. Focus on issues that actually matter for code health. If there are no strong findings, output none.

## CRITICAL RULES

1. **DO NOT modify, create, or delete any files** - this is analysis only
2. **DO NOT attempt to fix issues** - only report them
3. **DO NOT install packages or run commands that change state**
4. You may only use read operations: list files, read files, search content
