---
description: Verify epic acceptance criteria against code changes with multi-model consensus
argument-hint: <epic-file> [--commit <sha...> | --base <branch> | <range>] [--mode <fast|smart|max>] [--consensus <majority|all|any>] [--agents <list>] [--max-rounds <n>]
---

# Epic Verification (Iterative)

Multi-model verification that checks whether code changes satisfy an epic's acceptance criteria. External reviewers (Codex, Gemini, Claude) analyze the repository and commits, and you fix the code until consensus passes.

## Usage

```
/cerberus:verify-epic docs/specs/my-epic.md                    # Verify against uncommitted changes
/cerberus:verify-epic docs/specs/my-epic.md --base main        # Verify changes from main to HEAD
/cerberus:verify-epic docs/specs/my-epic.md --commit abc123    # Verify specific commits
/cerberus:verify-epic docs/specs/my-epic.md main..feature      # Verify a commit range
/cerberus:verify-epic docs/specs/my-epic.md --agents codex,gemini  # Only run selected reviewers
/cerberus:verify-epic docs/specs/my-epic.md --max-rounds 3     # Limit to 3 verification iterations
/cerberus:verify-epic docs/specs/my-epic.md --mode max         # Use max intelligence mode
/cerberus:verify-epic docs/specs/my-epic.md --consensus all    # Require unanimous approval
```

## Input Requirements

The epic file should contain acceptance criteria. The command will extract criteria from:
- A `## Acceptance Criteria` section (preferred)
- A `### Acceptance Criteria` section
- If neither found, uses the full file content

Referenced spec files (e.g., `specs/feature.md` mentioned in the epic) will be automatically loaded and provided to reviewers.

## How It Works

1. **Parse Epic**: Extract acceptance criteria from the epic file
2. **Spawn Verification**: Run the spawn command to start verification
3. **Reviewers Verify**: Codex, Gemini, and Claude analyze the code against criteria in parallel
4. **Fix Issues**: If reviewers find unmet criteria, fix the code
5. **Re-verify**: Verification automatically re-runs after changes (unless `--max-rounds 0`)
6. **Pass**: When consensus is reached, the gate resolves

## Run the Verification

Use the Bash tool to spawn the epic verification:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-epic-verify "$EPIC_FILE" $ARGUMENTS
```

Pass all remaining `$ARGUMENTS` directly. The CLI accepts:
- `--agents <list>` - comma-separated: codex, gemini, claude
- `--max-rounds <n>` - iteration limit (default: 3, use 0 to disable)
- `--mode <fast|smart|max>` - intelligence level
- `--consensus <majority|all|any>` - approval threshold
- Diff selectors: `--uncommitted`, `--base <branch>`, `--commit <sha...>`, or `<range>`

**Consensus modes:**
- `majority` (default): At least 2 reviewers PASS, or all valid reviewers PASS
- `all`: All valid reviewers must PASS (errored reviewers are skipped)
- `any`: At least one reviewer PASS

Note: FAIL verdicts and P0/P1 findings always block regardless of consensus mode.

**IMPORTANT: After running the spawn command, STOP IMMEDIATELY.** Do not poll, wait, or run any further commands. The Stop hook will automatically check for reviewer consensus when you stop.

Examples:
```bash
# User: /verify-epic specs/auth-epic.md --mode fast
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-epic-verify specs/auth-epic.md --mode fast

# User: /verify-epic specs/feature.md --base main
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-epic-verify specs/feature.md --base main

# User: /verify-epic specs/refactor.md --commit abc123 def456
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-epic-verify specs/refactor.md --commit abc123 def456

# User: /verify-epic specs/feature.md main..feature
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-epic-verify specs/feature.md main..feature
```

## Verification Criteria

Reviewers verify each acceptance criterion by:

1. **Tracing to code** - Can the criterion be traced to specific files/functions?
2. **Checking correctness** - Does the implementation match the specification?
3. **Gathering evidence** - Is there concrete proof (code paths, test coverage)?
4. **Validating completeness** - Are all aspects of the criterion addressed?

Non-code criteria (tests, linting, CI, docs) are explicitly out of scope.

## Revision Cycle

When reviewers find unmet criteria:

1. The stop hook presents unmet criteria from each reviewer
2. Fix the code to satisfy the criteria
3. Verification automatically re-runs (configurable via --max-rounds)

**Commit Policy:** The stop hook will tell you whether to keep changes uncommitted or create a new commit, based on the diff mode used.

## Completion

- **Consensus passes**: Auto-resolves and allows stop
- **Max iterations reached**: Falls back to manual decision

## Manual Override

If needed after max iterations:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate resolve  # Resolve the current gate
```
