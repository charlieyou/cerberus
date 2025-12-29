---
description: Iterative spec review with external reviewers
argument-hint: <path/to/spec.md>
---

# Spec Review (Iterative)

Spawn external reviewers (Codex, Gemini) to evaluate a feature specification. Fix issues until all reviewers pass.

## Usage

Run the spawn command with the spec path:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-spec-review $ARGUMENTS
```

## How It Works

1. External reviewers (Codex, Gemini) evaluate the spec for:
   - Clarity of goals and scope definition
   - Technical feasibility and completeness
   - Edge case coverage and testability
   - Actionability for implementation

2. The Stop hook waits for reviewers and checks consensus:
   - If all reviewers PASS: You may proceed
   - If any reviewer finds issues: You must fix the spec and try again

3. Fix issues in the spec file based on reviewer feedback, then the review automatically re-runs.

## Review Criteria

Reviewers evaluate the spec for:

- **Clarity of Goals** - Is it clear what problem this solves?
- **Scope Definition** - Are boundaries explicit?
- **Technical Feasibility** - Are proposed components realistic?
- **Implementation Completeness** - Does it cover all necessary steps?
- **Edge Cases** - Are error paths addressed?
- **Testability** - Is there a clear testing strategy?
- **Actionability** - Could a developer implement without further clarification?

## Iteration Loop

The iterative review continues until:
- All reviewers agree the spec passes (unanimous PASS)
- Maximum iterations (5) are reached
- You manually resolve with `${CLAUDE_PLUGIN_ROOT}/bin/review-gate resolve proceed` or `${CLAUDE_PLUGIN_ROOT}/bin/review-gate resolve abort`
