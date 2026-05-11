Please handle the following unmet acceptance criteria according to the mode instructions below:

${ISSUES}

## Mode Selection (read first)

Default to **Fix Mode** unless the user explicitly asked for report-only behavior (for example: "findings only", "report only", "do not fix", "no fixes", "don't use the gate", or "write a markdown doc").

### Report-Only Mode (no fixes, no gate)

Use this mode only when the user explicitly requests it.

In Report-Only Mode:
1. Do **not** edit implementation code, tests, plans, specs, or generated artifacts.
2. Do **not** spawn implementation sub-agents.
3. Do **not** use or clear any Cerberus gate workflow unless the user separately and explicitly asks you to clear an active gate.
4. Write the findings only to a Markdown document. Use a user-specified path if one was provided; otherwise write `epic-verification-findings.md` at the repository root.
5. The Markdown document must contain:
   - Title and short summary
   - One section per finding/unmet criterion
   - Priority, affected file/line if present, acceptance criterion, evidence, and suggested fix
   - A final "No fixes made" note
6. Final response: report the Markdown path, state that no fixes were made, and state that the review gate was not used or cleared.

After writing the Markdown report, stop. Do not continue into Fix Mode.

## Fixing Strategy (MANDATORY)

**Fix Mode is the default. In Fix Mode, YOU MUST use the Task tool to spawn sub-agents to implement fixes.** Do not implement fixes directly in the parent agent except to resolve a small merge conflict or blocker created by a sub-agent. Delegate every unmet criterion (or a tightly related cluster in the same code area) to a sub-agent so implementation work is isolated, reviewable, and committed by the sub-agent that made it.

**For each unmet criterion (or tightly related cluster in the same area):**
1. Call the Task tool with the specific criterion details, evidence, and expected behavior
2. Instruct the sub-agent to make the smallest correct code/test/doc changes needed for that criterion
3. Instruct the sub-agent to verify its own changes with the narrowest useful check
4. Instruct the sub-agent to create a git commit containing only its own changes before it returns
5. Wait for the sub-agent to complete, then review its diff and commit
6. Run sub-agents **sequentially** (one at a time) to avoid edit conflicts

**Parent responsibilities:** After each sub-agent completes, verify its changes satisfy the criterion and that it created a commit. If conflicts arise, changes are incomplete, verification is missing, or no commit was created, spawn a follow-up Task to finish or commit the work. You orchestrate; sub-agents execute and commit.

**Sub-agent commit policy (MANDATORY):**
- Each implementation sub-agent MUST run `git status` before editing so it can avoid unrelated user/agent changes.
- Each implementation sub-agent MUST stage only the files it changed for its assigned criterion.
- Each implementation sub-agent MUST create a new git commit before returning. Do not amend, rebase, reset, or stash unrelated work.
- Commit message format: `Fix epic verification: <short criterion/finding summary>`.
- Each implementation sub-agent MUST report the commit SHA, files changed, verification run, and any remaining risks.
- If a sub-agent cannot commit because of a real blocker, it must leave a precise blocker report. The parent must not silently proceed as if the work is committed.

**Task sub-agent format:**
```
Task(
  description="Implement AC: User receives error message on invalid input",
  prompt="Implement this acceptance criterion:

Criterion: User receives error message on invalid input
Epic: User Registration Flow
Current behavior: Form silently fails on invalid email format
Expected: Display 'Please enter a valid email address' error message

Instructions:
1. Find the registration form validation code
2. Add email validation with appropriate error message
3. Verify the fix works for the expected scenarios
4. Run git status before and after your changes
5. Stage only the files you changed for this criterion
6. Create a new git commit with message: Fix epic verification: invalid input error message
7. Report the commit SHA, files changed, verification run, and any remaining risks"
)
```

Now call the Task tool (not in a code block) using the structure above for each unmet criterion.

## Communicating with Reviewers

**When to use author-context:**
- Reviewers flagged a **false positive** (decision is intentional or already correct)
- A finding was **addressed this iteration** and you want to prevent re-flagging
- There are **non-obvious constraints** (scope, product decisions) justifying keeping something as-is
- You have **questions for reviewers** ("we considered A vs B; please confirm B is acceptable")

**Do NOT use author-context instead of implementing** clear, correct issues.

When you believe a previously flagged issue is now resolved, briefly note this in author-context. This gives reviewers a checklist to verify.

```bash
set +u; root="${CERBERUS_ROOT:-}"; [ -n "$root" ] || root="${CLAUDE_PLUGIN_ROOT}"; [ -n "$root" ] || root="${PLUGIN_ROOT:-}"; if [ -z "$root" ]; then skill_dir="${CLAUDE_SKILL_DIR}"; if [ -n "$skill_dir" ]; then root="$(cd "$skill_dir/../.." && pwd)"; fi; fi; bin="$root/bin/cerberus"; [ -n "$root" ] || { echo "cerberus: plugin root not set" >&2; exit 127; }; export CERBERUS_ROOT="$root"; claude_session="${CLAUDE_SESSION_ID}"; if [ "${CERBERUS_HOST:-}" = claude-code ]; then export CERBERUS_HOST=claude; fi; if [ -n "${CODEX_THREAD_ID:-}" ] && { [ -z "${CERBERUS_HOST:-}" ] || [ "${CERBERUS_HOST:-}" = codex ]; }; then export CERBERUS_HOST=codex CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$CODEX_THREAD_ID}"; elif [ -z "${CERBERUS_HOST:-}" ] && [ -n "$claude_session" ]; then export CERBERUS_HOST=claude CERBERUS_SESSION_ID="${CERBERUS_SESSION_ID:-$claude_session}"; fi; if ! make -q -C "$root" build >/dev/null 2>&1; then make -C "$root" build >&2 || exit $?; fi; "$bin" author-context 'Resolved: [what was fixed]. False Positives: [why X is intentional]. Questions: [any open items].'
```

Keep it to 1-2 paragraphs max. Update each iteration to reflect current state; do not keep outdated notes. Once all findings are resolved, clear with `author-context --clear`.

## Self-Review Before Stopping

After all sub-agents complete their fixes:
1. Review the changes made by each sub-agent
2. Confirm every sub-agent produced a commit SHA and that each commit contains only the intended changes
3. Verify the fixes address the original issues
4. Check for any obvious regressions or new issues introduced
5. Set author-context if there are false positives or clarifications for reviewers
6. Only then finalize and STOP

**After fixing, confirming commits, and self-reviewing, STOP immediately.** The stop hook will automatically re-run epic verification.
