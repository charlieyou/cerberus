Please revise **${SPEC_PATH}** to address the following issues:

${ISSUES}

## Fixing Strategy (MANDATORY)

**YOU MUST use the Task tool to spawn sub-agents to fix issues.** Delegate each fix to a sub-agent. This preserves your context for self-review and ensures focused, high-quality fixes.

**For each finding (or tightly related cluster in the same section):**
1. Call the Task tool with the specific issue details
2. Wait for the sub-agent to complete and review its changes
3. Run sub-agents **sequentially** (one at a time) to avoid edit conflicts

**Parent responsibilities:** After each sub-agent completes, verify its changes address the issue. If conflicts arise or changes are incomplete, spawn a follow-up Task. You orchestrate; sub-agents execute.

**Task sub-agent format:**
```
Task(
  description="Fix [P1] Missing error handling in API section",
  prompt="Fix this spec review issue:

Spec file: ${SPEC_PATH}
Issue: [P1] Missing error handling in API section
Section: API Design > Error Responses
Problem: The spec doesn't define error response formats for validation failures.

Instructions:
1. Read the spec file to understand the current structure
2. Add error response definitions in the appropriate section
3. Make the smallest change necessary to address this issue
4. Report what you changed"
)
```

Now call the Task tool (not in a code block) using the structure above for each finding.

## Communicating with Reviewers

**When to use author-context:**
- Reviewers flagged a **false positive** (decision is intentional or already correct)
- A finding was **addressed this iteration** and you want to prevent re-flagging
- There are **non-obvious constraints** (scope, product decisions) justifying keeping something as-is
- You have **questions for reviewers** ("we considered A vs B; please confirm B is acceptable")

**Do NOT use author-context instead of fixing** clear, correct issues.

When you believe a previously flagged issue is now resolved, briefly note this in author-context. This gives reviewers a checklist to verify.

```bash
set +u; root="${CERBERUS_ROOT:-}"; [ -n "$root" ] || root="${CLAUDE_PLUGIN_ROOT}"; [ -n "$root" ] || root="${PLUGIN_ROOT:-}"; if [ -z "$root" ]; then skill_dir="${CLAUDE_SKILL_DIR}"; if [ -n "$skill_dir" ]; then root="$(cd "$skill_dir/../.." && pwd)"; fi; fi; bin="$root/bin/cerberus"; [ -n "$root" ] || { echo "cerberus: plugin root not set" >&2; exit 127; }; export CERBERUS_ROOT="$root"; claude_session="${CLAUDE_SESSION_ID}"; if [ "${CERBERUS_HOST:-}" = claude-code ]; then export CERBERUS_HOST=claude; fi; if [ -n "${CODEX_THREAD_ID:-}" ] && { [ -z "${CERBERUS_HOST:-}" ] || [ "${CERBERUS_HOST:-}" = codex ]; }; then export CERBERUS_HOST=codex CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$CODEX_THREAD_ID}"; elif [ -z "${CERBERUS_HOST:-}" ] && [ -n "$claude_session" ]; then export CERBERUS_HOST=claude CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$claude_session}"; fi; if ! make -q -C "$root" build >/dev/null 2>&1; then make -C "$root" build >&2 || exit $?; fi; "$bin" author-context 'Resolved: [what was fixed]. False Positives: [why X is intentional]. Questions: [any open items].'
```

Keep it to 1-2 paragraphs max. Update each iteration to reflect current state; do not keep outdated notes. Once all findings are resolved, clear with `author-context --clear`.

## Self-Review Before Stopping

After all sub-agents complete their fixes:
1. Review the changes made by each sub-agent
2. Verify the fixes address the original issues
3. Check for any obvious regressions or new issues introduced
4. Set author-context if there are false positives or clarifications for reviewers
5. Only then finalize and STOP

**After updating and self-reviewing, STOP immediately.** The stop hook will spawn the next review round.
