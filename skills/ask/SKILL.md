---
name: ask
disable-model-invocation: true
description: Ask the Cerberus model panel an arbitrary question
argument-hint: '[--debate] [--mode <fast|smart|max>] [--agents <list>] [--max-rounds <n>] [--consensus <majority|all|any>] [--context-file <path>] [--prompt-file <path> | -- <prompt>]'
---

## Host-Neutral Execution

Before running any Bash snippet in this skill, run the shared Cerberus resolver below. It lazily builds and executes `bin/cerberus` from the configured plugin root.

```bash
# --- shared resolver (canonical body; identical across all callers) ---
root="${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}"
bin="$root/bin/cerberus"
[ -n "$root" ] || { echo "cerberus: plugin root not set" >&2; exit 127; }
export CERBERUS_ROOT="$root"
command -v make >/dev/null 2>&1 || { echo "cerberus: make not found on PATH; install make and retry." >&2; exit 127; }
if ! make -q -C "$root" build >/dev/null 2>&1; then
    command -v go >/dev/null 2>&1 || { echo "cerberus: Go >= 1.22 not found on PATH; install Go and retry." >&2; exit 127; }
    echo "cerberus: building... (this happens once after clone or upgrade)" >&2
    start=$(date +%s)
    make -C "$root" build >&2 || exit $?
    end=$(date +%s)
    echo "cerberus: build complete in $((end-start))s" >&2
fi
# --- shared resolver above; per-caller exec below (allowed to diverge) ---
exec "$bin" "$@"
```

Use `bin/cerberus` through the configured plugin root when invoking Cerberus commands below.


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
artifact_path=$(${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}/bin/cerberus artifact-path)
review_dir=$(dirname "$artifact_path")
result_file="$review_dir/ask-result.json"

${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}/bin/cerberus spawn-ask $ARGUMENTS
${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}/bin/cerberus wait --json --finalize --timeout 1800 --poll-interval 3 > "$result_file" || true

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
