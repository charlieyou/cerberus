---
description: Verify epic acceptance criteria against the codebase with multi-model consensus
argument-hint: <epic-file> [--mode <fast|smart|max>] [--consensus <majority|all|any>] [--agents <list>] [--max-rounds <n>]
---

# Epic Verification (Iterative)

Multi-model verification that checks whether the codebase satisfies an epic's acceptance criteria. External reviewers (Codex, Gemini, Claude) explore the repository using their tools to verify each criterion is implemented, and you fix the code until consensus passes.

## Usage

```
/cerberus:verify-epic docs/specs/my-epic.md                    # Verify epic criteria against codebase
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
3. **Reviewers Explore**: Codex, Gemini, and Claude use their tools to explore the codebase and verify each criterion
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

# User: /verify-epic specs/feature.md --agents codex,gemini
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-epic-verify specs/feature.md --agents codex,gemini

# User: /verify-epic specs/refactor.md --consensus all
${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-epic-verify specs/refactor.md --consensus all
```

## Verification Criteria

Reviewers explore the codebase and verify each acceptance criterion by:

1. **Searching for implementations** - Use grep/glob to find relevant code
2. **Tracing to code** - Can the criterion be traced to specific files/functions?
3. **Checking correctness** - Does the implementation match the specification?
4. **Gathering evidence** - Is there concrete proof (code paths, test coverage)?
5. **Validating completeness** - Are all aspects of the criterion addressed?

Non-code criteria (tests, linting, CI, docs) are explicitly out of scope unless stated in the epic.

## Revision Cycle

When reviewers find unmet criteria:

1. The stop hook presents unmet criteria from each reviewer
2. Fix the code to satisfy the criteria
3. Verification automatically re-runs (configurable via --max-rounds)

## Completion

- **Consensus passes**: Auto-resolves and allows stop
- **Max iterations reached**: Falls back to manual decision

## Manual Override

If needed after max iterations:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/review-gate resolve  # Resolve the current gate
```
