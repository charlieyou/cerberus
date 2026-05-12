Please revise the **code** to address the following issues:

${ISSUES}

## Fixing Strategy (MANDATORY)

**YOU MUST use the Task tool to spawn sub-agents to fix issues.** Delegate each fix to a sub-agent. This preserves your context for self-review and ensures focused, high-quality fixes.

**For each finding (or tightly related cluster in the same file/function):**
1. Call the Task tool with the specific issue details
2. Wait for the sub-agent to complete and review its changes
3. Run sub-agents **sequentially** (one at a time) to avoid edit conflicts

**Parent responsibilities:** After each sub-agent completes, verify its changes address the issue. If conflicts arise or changes are incomplete, spawn a follow-up Task. You orchestrate; sub-agents execute.

**Task sub-agent format:**
```
Task(
  description="Fix [P1] Missing null check in process_user",
  prompt="Fix this code review issue:

Issue: [P1] Missing null check in process_user
File: src/handlers/user.py lines 45-50
Problem: user.profile accessed without null check causes AttributeError when profile is None.

Instructions:
1. Read the file to understand the context
2. Add appropriate null handling
3. Verify the fix doesn't break existing behavior
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
set +u; if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${PLUGIN_ROOT:-}" ]; then host=codex; elif [ -n "${CLAUDE_SESSION_ID}" ] || [ -n "${CLAUDE_PLUGIN_ROOT}" ] || [ -n "${CLAUDE_SKILL_DIR}" ]; then host=claude; else host="${CERBERUS_HOST:-}"; if [ "$host" = claude-code ]; then host=claude; fi; fi; root="${CERBERUS_ROOT:-}"; if [ -z "$root" ] && [ "$host" = codex ]; then root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then cache_home="${HOME:-}"; [ -n "$cache_home" ] || cache_home="${USERPROFILE:-}"; if [ -n "$cache_home" ]; then cache_file="$cache_home/.codex/cerberus/sessions/$CODEX_THREAD_ID/plugin-root"; if [ -r "$cache_file" ]; then IFS= read -r root < "$cache_file" || true; fi; fi; fi; if [ -z "$root" ] && [ "$host" != codex ]; then root="${CLAUDE_PLUGIN_ROOT}"; [ -n "$root" ] || root="${PLUGIN_ROOT:-}"; fi; if [ -z "$root" ] && [ "$host" != codex ]; then skill_dir="${CLAUDE_SKILL_DIR}"; if [ -n "$skill_dir" ]; then root="$(cd "$skill_dir/../.." && pwd)"; fi; fi; [ -n "$root" ] || { echo "cerberus: plugin root not set; set CERBERUS_ROOT and retry" >&2; exit 127; }; bin="$root/bin/cerberus"; export CERBERUS_ROOT="$root"; claude_session="${CLAUDE_SESSION_ID}"; if [ "$host" = claude ]; then export CERBERUS_HOST=claude; elif [ "$host" = codex ]; then export CERBERUS_HOST=codex; fi; if [ "$host" = codex ] && [ -n "${CODEX_THREAD_ID:-}" ]; then export CERBERUS_HOST=codex CERBERUS_SESSION_ID="$CODEX_THREAD_ID"; elif [ "$host" = claude ] && [ -n "$claude_session" ]; then export CERBERUS_HOST=claude CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$claude_session}"; fi; command -v make >/dev/null 2>&1 || { echo "cerberus: make not found on PATH; install make and retry." >&2; exit 127; }; if ! make -q -C "$root" build >/dev/null 2>&1; then command -v go >/dev/null 2>&1 || { echo "cerberus: Go >= 1.22 not found on PATH; install Go and retry." >&2; exit 127; }; echo "cerberus: building... (this happens once after clone or upgrade)" >&2; start=$(date +%s); make -C "$root" build >&2 || exit $?; end=$(date +%s); echo "cerberus: build complete in $((end-start))s" >&2; fi; "$bin" author-context 'Resolved: [what was fixed]. False Positives: [why X is intentional]. Questions: [any open items].'
```

Keep it to 1-2 paragraphs max. Update each iteration to reflect current state; do not keep outdated notes. Once all findings are resolved, clear with `author-context --clear`.

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
