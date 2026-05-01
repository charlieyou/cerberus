---
name: review-code
description: Spawn a multi-model code review (Codex + Gemini + Claude consensus) over the current diff.
arguments:
  - name: flags-and-focus
    required: false
    description: Optional flags ([--mode <fast|smart|max>] [--consensus <majority|all|any>] [--agents <list>] [--max-rounds <n>] [--uncommitted | --base <branch> | --commit <sha...> | <range>] [--exclude <pathspec>...]) followed by an optional free-text focus area.
---

# Cerberus — Review Code (Codex skill)

Multi-model code review that iterates until reviewer consensus is reached.
External reviewers (Codex, Gemini, Claude) evaluate the diff in parallel and
the gate resolves once the configured consensus mode passes.

This is the Codex-host wrapper around `bin/review-gate spawn-code-review`. It
sets `CERBERUS_HOST=codex` so the shared backend records the host and resolves
state under the Codex runtime tree, then hands off to the same reviewer
pipeline used by every other Cerberus host.

## Usage

```
review-code                            # Review uncommitted changes (default)
review-code --uncommitted              # Review uncommitted changes
review-code --base main                # Review changes from main to HEAD
review-code --commit abc123            # Review a single commit (net diff)
review-code main..feature              # Review a commit range
review-code --agents codex,gemini      # Only run selected reviewers
review-code --max-rounds 3             # Limit to 3 review iterations
review-code --max-rounds 0             # Disable auto-respawn (single round)
review-code --mode max                 # Use max intelligence mode
review-code --consensus any            # Pass if at least one reviewer approves
review-code "focus on error handling"  # Focus review on a specific area
```

`--commit` generates a single net diff by applying the listed commits onto
their merge-base, so non-contiguous commit lists are supported and intermediate
commits are not shown individually.

**Consensus modes:**
- `majority` (default): at least 2 reviewers PASS, or all valid reviewers PASS.
- `all`: all valid reviewers must PASS (errored reviewers are skipped).
- `any`: at least one reviewer PASS.

FAIL verdicts and P0/P1 findings always block regardless of consensus mode.

## Install

The bash block below uses a `<CERBERUS_INSTALL_ROOT>` placeholder. At install
time, either:

- Replace every `<CERBERUS_INSTALL_ROOT>` token in this file with the absolute
  path to your Cerberus checkout (the same substitution applied to
  `templates/codex-hooks.json`), OR
- Export `CERBERUS_ROOT=/abs/path/to/cerberus` in your shell profile so the
  fallback is never reached.

See `templates/codex-hooks.json` for the same install procedure.

## Run the Review

Invoke the shared backend with `CERBERUS_HOST=codex` exported. The Codex
`Stop` lifecycle hook (installed from `templates/codex-hooks.json`) handles
re-evaluation on the next stop boundary.

```bash
export CERBERUS_HOST=codex

# Bootstrap CERBERUS_RUN_KEY from the codex-session-init registry on disk.
# Codex doesn't expose a stable session-id env var; the SessionStart hook
# (bin/codex-session-init, wired via templates/codex-hooks.json) persists the
# run-key to ~/.cerberus/runtime/codex/<project-key>/active-session.json
# instead. User shells that invoke a skill mid-session don't normally inherit
# CERBERUS_RUN_KEY, so we re-read it from disk here. The bootstrap is a no-op
# when the env already has CERBERUS_RUN_KEY / REVIEW_GATE_SESSION_KEY /
# CLAUDE_SESSION_ID, so explicit overrides win.
if [ -z "${CERBERUS_RUN_KEY:-}" ] && [ -z "${REVIEW_GATE_SESSION_KEY:-}" ] \
   && [ -z "${CLAUDE_SESSION_ID:-}" ] && command -v jq >/dev/null 2>&1; then
    __cb_root="${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-<CERBERUS_INSTALL_ROOT>}}"
    if [ -r "$__cb_root/bin/review-gate-lib.sh" ]; then
        # shellcheck source=/dev/null
        . "$__cb_root/bin/review-gate-lib.sh" >/dev/null 2>&1 || :
        if type get_project_hash >/dev/null 2>&1; then
            __cb_pk="$(get_project_hash "" 2>/dev/null || true)"
            __cb_reg="$HOME/.cerberus/runtime/codex/$__cb_pk/active-session.json"
            if [ -n "$__cb_pk" ] && [ -r "$__cb_reg" ]; then
                __cb_rk="$(jq -r '.run_key // empty' "$__cb_reg" 2>/dev/null || true)"
                [ -n "$__cb_rk" ] && export CERBERUS_RUN_KEY="$__cb_rk"
                unset __cb_rk
            fi
            unset __cb_pk __cb_reg
        fi
    fi
    unset __cb_root
fi

"${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-<CERBERUS_INSTALL_ROOT>}}/bin/review-gate" spawn-code-review "$@"
```

After the spawn returns, **stop the turn**. Do not poll. The Codex `Stop` hook
will reattach to the run and either allow the stop (consensus reached) or
issue a continuation message describing reviewer findings to address.

## Review Criteria

Reviewers evaluate the diff for:

1. **Correctness** — does the code do what it intends? Logic errors?
2. **Security** — injection, auth bypass, data exposure, secrets in code?
3. **Error Handling** — failures handled gracefully? Edge cases covered?
4. **Performance** — obvious inefficiencies?
5. **Breaking Changes** — API changes that could break consumers?

## Iteration Loop

The iterative review continues until:

- Consensus is reached (per `--consensus`, default `majority`).
- Maximum iterations are reached (default 3, configurable via `--max-rounds`;
  set `0` to disable auto-respawn).
- The user clears the gate via the `clear-gate` skill.
