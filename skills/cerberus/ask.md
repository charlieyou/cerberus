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
review_gate="${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-.}}/bin/review-gate"
artifact_path="$("$review_gate" artifact-path)"
review_dir="$(dirname "$artifact_path")"
result_file="$review_dir/ask-result.json"

"$review_gate" spawn-ask "$@"
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
