---
name: ask
disable-model-invocation: true
description: Ask the Cerberus model panel an arbitrary question
argument-hint: '[--debate] [--mode <fast|smart|max>] [--agents <list>] [--max-rounds <n>] [--consensus <majority|all|any>] [--context-file <path>] [--prompt-file <path> | -- <prompt>]'
---

## Host-Neutral Execution

Before running any Bash snippet in this skill, source the shared Cerberus skill environment helper. This keeps the same skill usable from Claude, Codex, or a generic shell by resolving `CERBERUS_ROOT`, `CERBERUS_HOST`, and the active run key when the host exposes one.

```bash
cerberus_root=""
cerberus_plugin_root='${CLAUDE_PLUGIN_ROOT}'
case "$cerberus_plugin_root" in
    '$'{CLAUDE_PLUGIN_ROOT}) cerberus_plugin_root="${CLAUDE_PLUGIN_ROOT:-}" ;;
esac
cerberus_skill_dir='${CLAUDE_SKILL_DIR}'
case "$cerberus_skill_dir" in
    '$'{CLAUDE_SKILL_DIR}) cerberus_skill_dir="${CLAUDE_SKILL_DIR:-}" ;;
esac

cerberus_candidates=("${CERBERUS_ROOT:-}" "$cerberus_plugin_root")
if [ -n "$cerberus_skill_dir" ]; then
    cerberus_candidates+=("$(cd -P "$cerberus_skill_dir/../.." 2>/dev/null && pwd || true)")
fi
cerberus_git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$cerberus_git_root" ]; then
    cerberus_candidates+=("$cerberus_git_root")
fi
for cerberus_candidate in "${cerberus_candidates[@]}"; do
    if [ -n "$cerberus_candidate" ] \
        && [[ "$cerberus_candidate" == /* ]] \
        && [ -r "$cerberus_candidate/bin/cerberus-skill-env" ] \
        && [ -x "$cerberus_candidate/bin/review-gate" ] \
        && [ -r "$cerberus_candidate/bin/review-gate-models.sh" ] \
        && [ -r "$cerberus_candidate/config/gemini-readonly-settings.json" ] \
        && [ -r "$cerberus_candidate/config/gemini-readonly-policy.toml" ]; then
        cerberus_root="$cerberus_candidate"
        break
    fi
done
if [ -z "$cerberus_root" ]; then
    echo "cerberus skill: cannot find Cerberus backend; set CERBERUS_ROOT to the checkout root" >&2
    exit 127
fi
export CERBERUS_ROOT="$cerberus_root"
# shellcheck source=/dev/null
. "$cerberus_root/bin/cerberus-skill-env" || exit $?
```

Use `${CERBERUS_ROOT}` when invoking Cerberus binaries below.


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
artifact_path=$(${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/review-gate artifact-path)
review_dir=$(dirname "$artifact_path")
result_file="$review_dir/ask-result.json"

${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/review-gate spawn-ask $ARGUMENTS
${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/review-gate wait --json --finalize --timeout 1800 --poll-interval 3 > "$result_file" || true

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
