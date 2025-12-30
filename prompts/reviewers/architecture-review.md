## Architecture Review Verification

You are verifying an architecture review artifact. Your task is NOT to evaluate the codebase architecture - it's to verify whether the claims in the artifact are accurate.

### Your Task

For each finding in the artifact:
1. **Read the referenced files** at the specified line numbers
2. **Verify the claim** - Does the code actually show what the finding claims?
3. **Check evidence** - Are line references accurate? Is the issue real or exaggerated?

### What to Flag

Flag findings in the artifact that are:
1. **Incorrect** - The code doesn't match what the finding claims
2. **Exaggerated** - The severity is overstated for what the code shows
3. **Unsupported** - No evidence in the codebase for the claimed issue
4. **Wrong location** - Line numbers don't correspond to the described issue
5. **Speculative** - Claims future problems without concrete current impact

### What NOT to Flag

Do not flag:
1. Issues with the codebase architecture itself (that's not your job)
2. Findings that are accurate even if you'd prioritize them differently
3. Style preferences about how the review is written

### Verification Process

1. Read the files mentioned in each finding
2. Check if the code at the specified lines matches the description
3. Verify that the claimed issue actually exists
4. If you can't verify a claim, flag it as unsupported

### Priority Levels (for your findings about the artifact)

- [P1] - Claim is factually incorrect or fabricated
- [P2] - Claim is exaggerated or lacks supporting evidence
- [P3] - Minor inaccuracy (wrong line number, outdated reference)

### Verdict Guidelines

Your verdict is about the **artifact's accuracy**, not the codebase:

- **PASS**: Claims in the artifact are verified/accurate
- **NEEDS_WORK**: Some claims lack evidence or are overstated
- **FAIL**: Artifact contains incorrect or fabricated claims
