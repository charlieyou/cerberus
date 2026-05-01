#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local path="$1"
    local expected="$2"

    grep -Fq "$expected" "$ROOT_DIR/$path" || fail "expected $path to contain: $expected"
}

assert_not_contains() {
    local path="$1"
    local unexpected="$2"

    if grep -Fq "$unexpected" "$ROOT_DIR/$path"; then
        fail "expected $path not to contain: $unexpected"
    fi
}

assert_contains "agents/implementer.md" "Do not claim the task, set \`owner\`, or mark it \`in_progress\`."
assert_contains "agents/implementer.md" "task-assignment-style message"
assert_contains "agents/implementer.md" "Never claim, set \`owner\`, or mark \`in_progress\` on a Cerberus TaskList task."
assert_not_contains "agents/implementer.md" "Claim the task with \`TaskUpdate(taskId: \"<claude-task-id>\", owner: \"<your-name>\", status: \"in_progress\")\`"
assert_not_contains "agents/implementer.md" "keep it \`in_progress\`"

assert_contains "skills/run-team/SKILL.md" "cerberus_assigned_teammate: \"impl-T###\""
assert_contains "skills/run-team/SKILL.md" "Do not pass an owner and do not immediately call \`TaskUpdate(status: \"in_progress\")\`."
assert_contains "skills/run-team/SKILL.md" "If the Claude task is not \`completed\`"
assert_not_contains "skills/run-team/SKILL.md" "claim the synthetic task"
assert_not_contains "skills/run-team/SKILL.md" "if you have already claimed or started T###"
assert_contains "skills/run-team/SKILL.md" "STATUS: READY_FOR_COMPLETION T### — commits <short-shas>"
assert_contains "skills/run-team/SKILL.md" 'task_commits.txt'
assert_contains "skills/run-team/SKILL.md" "PROCEED_TO_COMPLETE T###"
assert_not_contains "skills/run-team/SKILL.md" "claim Claude task"
assert_not_contains "skills/run-team/SKILL.md" "Claim the task:"
assert_not_contains "skills/run-team/SKILL.md" "Immediately before calling \`TaskUpdate(taskId: \"<claude-task-id>\", status: \"completed\")\`"
assert_not_contains "skills/run-team/SKILL.md" "fixes, retries TaskUpdate"
assert_not_contains "skills/run-team/SKILL.md" "before retrying TaskUpdate(status:'completed')"
assert_not_contains "skills/run-team/SKILL.md" "amend / interactive-rebase / squash"
assert_not_contains "skills/run-team/SKILL.md" "leave the task in \`in_progress\`"
assert_not_contains "skills/run-team/SKILL.md" "task stays \`in_progress\`"

printf 'PASS: run-team agent protocol docs avoid TaskList self-claim assignment\n'
