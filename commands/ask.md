---
description: Ask the Cerberus model panel an arbitrary question
argument-hint: [--debate] [--mode <fast|smart|max>] [--agents <list>] [--max-rounds <n>] [--consensus <majority|all|any>] [--context-file <path>] [--prompt-file <path> | -- <prompt>]
---

# Ask

Send any prompt to the Cerberus reviewer panel. Use `--debate` to route the prompt through the multi-round debater process before synthesizing the answer.

## Usage

```
/cerberus:ask "Should we ship this plan?"
/cerberus:ask --debate "Compare the two migration options and recommend one"
/cerberus:ask --mode max --debate --prompt-file /tmp/question.md
/cerberus:ask -- --prompt text that starts with a dash
```

The CLI accepts `--agents`, `--mode`, `--max-rounds`, `--consensus`, `--context-file`, `--prompt-file`, `--debate`, plus arbitrary prompt text after `--`.

## Run the Panel

Use the Bash tool to run `spawn-ask`, wait for completion, and save the machine-readable result. Set the Bash timeout to 1800000ms (30 minutes).

```bash
artifact_path=$(${CLAUDE_PLUGIN_ROOT}/bin/review-gate artifact-path)
review_dir=$(dirname "$artifact_path")
result_file="$review_dir/ask-result.json"

${CLAUDE_PLUGIN_ROOT}/bin/review-gate spawn-ask $ARGUMENTS
${CLAUDE_PLUGIN_ROOT}/bin/review-gate wait --json --finalize --timeout 1800 --poll-interval 3 > "$result_file" || true

printf 'ASK_RESULT=%s\nREVIEW_DIR=%s\n' "$result_file" "$review_dir"
```

## Synthesize the Answer

After the Bash command completes, read the saved `ASK_RESULT` JSON and the reviewer files under `REVIEW_DIR/reviews/`.

Use this synthesis order:

1. Treat each reviewer JSON `summary` as that reviewer's direct answer.
2. If `aggregate.json` exists, use it to understand the final debate round, strategies, and merged caveats.
3. Include disagreements only when they materially affect the answer.
4. Keep the final response focused on the user's question, not on Cerberus mechanics.

Do not stop immediately after spawning; this command is meant to return the synthesized answer in the current conversation.
