Please revise the **code** to address the following issues:

${ISSUES}

## Fixing Strategy

Use the Task tool to spawn parallel sub-agents to fix each issue concurrently. For each finding listed above, launch a separate sub-agent with subagent_type="general-purpose" and a clear description of the specific issue to fix. This allows multiple fixes to happen in parallel for faster iteration.

Example (spawn one agent per issue, all in parallel):
```
Task(subagent_type="general-purpose", description="Fix [P1] issue title", prompt="Fix this issue: [full issue details]. Edit the relevant files to address the problem.")
```

## Communicating with Reviewers

**When to use author-context:**
- Reviewers flagged a **false positive** (behavior is intentional or already correct)
- A finding was **addressed this iteration** and you want to prevent re-flagging
- There are **non-obvious constraints** (performance, backwards compat, product decisions) justifying keeping something as-is
- You have **questions for reviewers** ("we considered A vs B; please confirm B is acceptable")

**Do NOT use author-context instead of fixing** clear, correct issues you can resolve in code.

### Author Context Format (use this exact structure)

Reviewers are trained to parse this format. Use the **exact finding title** in quotes so reviewers can match mechanically:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate author-context '
Resolved:
- "[P1] Fix typer.prompt err parameter": Added err=True to all prompt calls (lines 922, 941).

False Positives:
- "[P1] mala init exits 1 for non-dry-run": INTENTIONAL per issue scope.
  Evidence: Issue description says "Don'\''t implement file ops - that'\''s T003".
  The xfail tests are designed to fail until T003 implements file writing.

- "[P1] typer.prompt does not accept err parameter": typer.prompt DOES accept err=True.
  Evidence: `python -c "import inspect,typer; print(inspect.signature(typer.prompt))"`
  Output: `(text: str, ..., err: bool = False, ...)`

Questions:
- None
'
```

### Evidence That Reviewers Accept

Reviewers are instructed to accept disputes when you provide these evidence types (matching their "Evidence Hierarchy"):

| Evidence Type | Example |
|---------------|---------|
| **File:line references** | "Guard exists at runner.py:120-130" |
| **API verification** | "inspect.signature(typer.prompt) shows err parameter" |
| **Test output** | "test_init_flow passes and covers this path" |
| **Scope reference** | "Issue says 'T003 handles file ops'" |

Reviewers will REJECT vague disputes like:
- "This is intentional" (no evidence)
- "The code works" (no proof)
- "Already handled elsewhere" (no file:line)

### Updating Author Context

Keep it current each iteration. Do not keep outdated notes. Once all findings are resolved, clear with `author-context --clear`.

## Self-Review Before Stopping

After all sub-agents complete their fixes:
1. Review the changes made by each sub-agent
2. Verify the fixes address the original issues
3. Check for any obvious regressions or new issues introduced
4. Set author-context if there are false positives or clarifications for reviewers
5. Only then finalize and STOP

**Commit Policy (${DIFF_ARGS}):**
${COMMIT_INSTRUCTIONS}

**After fixing and self-reviewing, STOP immediately.** The stop hook will automatically re-run the external review.
