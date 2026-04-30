---
name: ask
description: Ask the Cerberus model panel an open-ended question and synthesize the answer in-thread.
arguments:
  - name: question-and-flags
    required: false
    description: Optional flags ([--debate] [--mode <fast|smart|max>] [--agents <list>] [--max-rounds <n>] [--consensus <majority|all|any>] [--context-file <path>] [--prompt-file <path>]) followed by the prompt text after `--`. Use `--prompt-file` for long prompts.
---

# Cerberus — Ask Panel (Codex skill)

Send any prompt to the Cerberus reviewer panel and synthesize the answer
back into the current Codex thread. Use `--debate` to route the prompt
through the multi-round debater process before synthesis.

This skill is the Codex-host wrapper around `bin/review-gate spawn-ask`. It
sets `CERBERUS_HOST=codex` so the backend records the host and resolves
state under the Codex runtime tree.

Unlike `review-code`, this skill **does not stop the turn after spawning**.
It waits for the panel to finish (`wait --json --finalize`), saves the
machine-readable result, and returns it for in-thread synthesis.

## Usage

```
ask "Should we ship this plan?"
ask --debate "Compare the two migration options and recommend one"
ask --mode max --debate --prompt-file /tmp/question.md
ask -- --prompt text that starts with a dash
```

## Run the Panel

Invoke the shared backend with `CERBERUS_HOST=codex` exported, wait for the
panel to finish, and save the JSON result alongside the reviewer artifacts.
Use a long timeout (30 minutes) because debate flows can be slow.

```bash
export CERBERUS_HOST=codex

# Bootstrap CERBERUS_RUN_KEY from the codex-session-init registry on disk.
# Codex doesn't expose a stable session-id env var; the SessionStart hook
# (bin/codex-session-init, wired via templates/codex-hooks.json) persists
# the run-key to ~/.cerberus/runtime/codex/<project-key>/active-session.json
# instead. User shells that invoke a skill mid-session don't normally
# inherit CERBERUS_RUN_KEY, so we re-read it from disk here. The bootstrap
# is a no-op when the env already has CERBERUS_RUN_KEY /
# REVIEW_GATE_SESSION_KEY / CLAUDE_SESSION_ID, so explicit overrides win.
if [ -z "${CERBERUS_RUN_KEY:-}" ] && [ -z "${REVIEW_GATE_SESSION_KEY:-}" ] \
   && [ -z "${CLAUDE_SESSION_ID:-}" ] && command -v jq >/dev/null 2>&1; then
    __cb_root="${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-.}}"
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

review_gate="${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-.}}/bin/review-gate"

# artifact-path is a read-only query; require it to succeed before we
# start spawning, otherwise we have no review_dir to anchor results.
if ! artifact_path="$("$review_gate" artifact-path)" || [ -z "$artifact_path" ]; then
    echo "ask: review-gate artifact-path failed; cannot resolve review dir" >&2
    exit 1
fi
review_dir="$(dirname "$artifact_path")"
result_file="$review_dir/ask-result.json"

# Fail fast on spawn-ask failure (e.g. --prompt-file pointing at a missing
# file, missing prompt). Without this, the block would silently fall through
# to `wait ... || true` and emit ASK_RESULT pointing at a no-active-gate /
# stale gate-state.json, which the synthesis step would then misread as a
# valid panel response.
if ! "$review_gate" spawn-ask "$@"; then
    rc=$?
    echo "ask: spawn-ask failed with exit $rc; not waiting on a panel that was not started" >&2
    exit "$rc"
fi

# `wait` may exit non-zero on legitimate finalize states (timeout, blocking
# findings); we still want to report ASK_RESULT in those cases so the
# synthesis step sees the partial data. Capture but tolerate.
"$review_gate" wait --json --finalize --timeout 1800 --poll-interval 3 \
    > "$result_file" || true

printf 'ASK_RESULT=%s\nREVIEW_DIR=%s\n' "$result_file" "$review_dir"
```

## Synthesize the Answer

After the bash block completes, read the saved `ASK_RESULT` JSON and the
reviewer files under `REVIEW_DIR/reviews/`.

Synthesis order:

1. Treat each reviewer JSON `summary` as that reviewer's direct answer.
2. If `aggregate.json` exists, use it to understand the final debate round,
   strategies, and merged caveats.
3. Include disagreements only when they materially affect the answer.
4. Keep the final response focused on the user's question, not on Cerberus
   mechanics.

This skill is meant to return the synthesized answer in the current
conversation; do not stop immediately after spawning.
