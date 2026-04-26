<!-- review-type: code -->
<!-- diff-args: --commit abc534fe77d5f80c45cfaa83b2b25bb38ff2b202 -->
<!-- max-rounds: 3 -->
<!-- agents: codex,gemini,claude -->
<!-- mode: smart -->

# Code Review (Iterative)

## Diff Mode
--commit abc534fe77d5f80c45cfaa83b2b25bb38ff2b202

## Changes

```diff
diff --git a/agents/implementer.md b/agents/implementer.md
new file mode 100644
index 0000000..22f4c9e
--- /dev/null
+++ b/agents/implementer.md
@@ -0,0 +1,72 @@
+---
+name: implementer
+description: Implement a single team task in the current working tree, then signal completion via TaskUpdate(status:"completed"). Completion is gated by automated review; address findings until review passes.
+tools: Read, Write, Edit, Bash, Grep, Glob, TaskGet, TaskUpdate, SendMessage
+model: sonnet
+---
+
+# Cerberus Implementer Teammate
+
+You are an agent-team teammate assigned exactly one Cerberus implementation task. You work in the shared current working tree on the current branch. Do not create worktrees, do not create branches, and do not push.
+
+## Required Workflow
+
+1. Read the assigned Claude task with `TaskGet`. Its subject is prefixed `[CERBERUS-IMPL/<team_hash>] T### — ...` and its metadata may include `cerberus_task_id`, `cerberus_team_hash`, `cerberus_files`, and `cerberus_depends`.
+2. Confirm your Cerberus task ID. Prefer `metadata.cerberus_task_id`; otherwise parse `T###` from the subject prefix. The lead also includes `CERBERUS_TASK_ID=T###` in your spawn prompt as redundant signal.
+3. Claim the task with `TaskUpdate(taskId: "<claude-task-id>", owner: "<your-name>", status: "in_progress")` unless the lead already claimed it for you.
+4. Implement only the assigned task scope. Follow repository guidance, task acceptance criteria, and the file list from the task `meta` block.
+5. Run the task's verification commands and any targeted checks needed for confidence.
+6. Commit your work on the current branch. The commit subject must start with `T###: <subject>`, and every commit you create for this task must include a real Git trailer line in its own trailer paragraph:
+
+   ```text
+   Cerberus-Task: T###
+   ```
+
+   Prefer `git commit --trailer Cerberus-Task=T###`. Do not put the trailer on the subject line; the hook uses Git's trailer parser and inline text is not parseable as a trailer.
+7. Immediately before attempting completion, write the completion-intent marker at the exact state directory path the lead provided in your spawn prompt. If the lead gives both an assignment and a literal command, run the literal command. It will look like this:
+
+   ```bash
+   CERBERUS_STATE_DIR="<state-dir-provided-by-lead>"
+   touch "<state-dir-provided-by-lead>/completion_intent"
+   ```
+
+8. Call `TaskUpdate(taskId: "<claude-task-id>", status: "completed")`. This fires the `TaskCompleted` hook, which runs Cerberus review.
+
+## Review Loop
+
+If review passes, `TaskUpdate(status:"completed")` succeeds. Go idle after a terse final summary.
+
+If review blocks completion, the hook exits 2 and its stderr is injected into your context. Read the findings carefully, fix the issues, create another commit with the same `Cerberus-Task: T###` trailer, touch `completion_intent` again, and retry `TaskUpdate(status:"completed")`.
+
+If the hook feedback says `INFRA-FAILURE`, do not retry. Send a message to the lead and go idle:
+
+```text
+STATUS: NEEDS_HUMAN T### — infra failure
+```
+
+If the hook feedback says review rounds are exhausted or tells you not to retry after a final reviewed round, do not retry `TaskUpdate(status:"completed")`. Leave the task `in_progress`, send a message to the lead, and go idle:
+
+```text
+STATUS: NEEDS_HUMAN T### — exhausted review rounds
+```
+
+## Hard Rules
+
+- Never run `git push`.
+- Never invoke `/cerberus:review-code`; the hook runs review automatically.
+- Never mark any task other than your assigned Claude task completed.
+- Never use `git add -A` or `git add .`.
+- Stage only files listed in your task's `meta.files`, plus intentional new files, deletions, renames, or moves that are clearly in the assigned task scope.
+- Do not modify history beyond your own commits unless the hook explicitly instructs you to amend or squash your own malformed task commits.
+- If you cannot complete the task, keep it `in_progress`, send `STATUS: NEEDS_HUMAN T### — <reason>` to the lead, and go idle.
+
+## Final Response Format
+
+Keep your final response brief:
+
+```markdown
+Implemented: <one sentence>
+Files: <paths>
+Tests: <commands and results>
+Commits: <short SHAs>
+```
diff --git a/bin/cerberus-task-completed-hook b/bin/cerberus-task-completed-hook
new file mode 100755
index 0000000..1d837a1
--- /dev/null
+++ b/bin/cerberus-task-completed-hook
@@ -0,0 +1,277 @@
+#!/usr/bin/env bash
+# cerberus-task-completed-hook
+#
+# Gates agent-team implementer task completion with Cerberus code review.
+# State lives under:
+#   ${TMPDIR:-/tmp}/cerberus-task-completed-hook/<team_hash>/<task_id>/
+#
+# The hook is registered globally for TaskCompleted, which has no matcher. It
+# exits 0 for every task whose subject is not prefixed with
+# [CERBERUS-IMPL/<team_hash>]. Failed task state is retained for debugging and
+# can be removed by deleting the run's <team_hash> directory.
+
+set -euo pipefail
+
+SOURCE="${BASH_SOURCE[0]}"
+while [ -L "$SOURCE" ]; do
+    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
+    SOURCE="$(readlink "$SOURCE")"
+    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
+done
+SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
+PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
+REVIEW_GATE="${PLUGIN_ROOT}/bin/review-gate"
+
+state_file=""
+state_dir=""
+task_id=""
+team_hash=""
+round="0"
+max_rounds="0"
+owned_task="0"
+
+json_get() {
+    local filter="$1"
+    printf '%s' "$hook_input" | jq -r "$filter" 2>/dev/null || printf ''
+}
+
+write_last_error() {
+    local message="$1"
+    if [[ -n "${state_dir:-}" ]]; then
+        mkdir -p "$state_dir" 2>/dev/null || true
+        printf '%s\n' "$message" > "${state_dir}/last_error" 2>/dev/null || true
+    fi
+}
+
+increment_round() {
+    local tmp
+    tmp="${state_file}.tmp.$$"
+    jq '.round = ((.round // 0) + 1)' "$state_file" > "$tmp"
+    mv "$tmp" "$state_file"
+}
+
+mark_exhausted_if_needed() {
+    local new_round
+    new_round="$(jq -r '.round // 0' "$state_file" 2>/dev/null || printf '0')"
+    if [[ "$new_round" =~ ^[0-9]+$ && "$max_rounds" =~ ^[0-9]+$ && "$new_round" -ge "$max_rounds" ]]; then
+        touch "${state_dir}/exhausted" 2>/dev/null || true
+    fi
+}
+
+block() {
+    printf '%s\n' "$1" >&2
+    exit 2
+}
+
+on_err() {
+    local rc line
+    rc=$?
+    line="${BASH_LINENO[0]:-unknown}"
+    if [[ "${owned_task:-0}" == "1" ]]; then
+        write_last_error "hook_internal_error: rc=${rc} line=${line}"
+        printf 'INFRA-FAILURE: Cerberus TaskCompleted hook crashed (rc=%s line=%s). Send NEEDS_HUMAN to lead and go idle.\n' "$rc" "$line" >&2
+        exit 2
+    fi
+    exit 0
+}
+
+trap on_err ERR
+
+hook_input="$(cat)"
+
+# This hook is global. If jq is unavailable or input is malformed, fail open
+# before ownership can be established so unrelated TaskLists are not affected.
+if ! command -v jq >/dev/null 2>&1; then
+    exit 0
+fi
+
+event_name="$(json_get '.hook_event_name // ""')"
+if [[ "$event_name" != "TaskCompleted" ]]; then
+    exit 0
+fi
+
+subject="$(json_get '.task_subject // .task_name // .subject // ""')"
+if [[ "$subject" != \[CERBERUS-IMPL/* ]]; then
+    exit 0
+fi
+owned_task="1"
+
+session_id="$(json_get '.session_id // ""')"
+transcript_path="$(json_get '.transcript_path // ""')"
+cwd="$(json_get '.cwd // ""')"
+
+if [[ -n "$cwd" && -d "$cwd" ]]; then
+    cd "$cwd"
+fi
+
+export CLAUDE_SESSION_ID="$session_id"
+export REVIEW_GATE_TRANSCRIPT_PATH="$transcript_path"
+
+team_hash="$(json_get '[.task_metadata.cerberus_team_hash?, .metadata.cerberus_team_hash?] | map(select(. != null and . != "")) | first // ""')"
+if [[ -z "$team_hash" ]]; then
+    team_hash="$(printf '%s' "$subject" | sed -n 's/^\[CERBERUS-IMPL\/\([^]]*\)\].*/\1/p')"
+fi
+
+task_id="$(json_get '[.task_metadata.cerberus_task_id?, .metadata.cerberus_task_id?] | map(select(. != null and . != "")) | first // ""')"
+if [[ -z "$task_id" ]]; then
+    task_id="$(printf '%s' "$subject" | sed -n 's/^\[CERBERUS-IMPL\/[^]]*\][[:space:]]*\(T[0-9][0-9]*\).*/\1/p')"
+fi
+if [[ -z "$task_id" ]]; then
+    task_id="$(json_get '[.. | objects | .cerberus_task_id? // empty] | map(select(. != "")) | first // ""')"
+fi
+
+state_root="${TMPDIR:-/tmp}/cerberus-task-completed-hook"
+if [[ -n "$team_hash" && -n "$task_id" ]]; then
+    state_dir="${state_root}/${team_hash}/${task_id}"
+    state_file="${state_dir}/state.json"
+else
+    state_dir="${state_root}/_unknown_$$"
+    mkdir -p "$state_dir" 2>/dev/null || true
+    printf 'state_unresolvable: subject prefix matched but team_hash/task_id could not be resolved. subject=%s\n' "$subject" > "${state_dir}/last_error" 2>/dev/null || true
+    block "INFRA-FAILURE: Cerberus task prefix matched but team/task state could not be resolved. Send NEEDS_HUMAN to lead and go idle."
+fi
+
+if [[ ! -f "$state_file" ]]; then
+    mkdir -p "$state_dir" 2>/dev/null || true
+    printf 'state_unresolvable: subject prefix matched but no state file found at %s\nsubject=%s\n' "$state_file" "$subject" > "${state_dir}/last_error" 2>/dev/null || true
+    block "INFRA-FAILURE: missing Cerberus state for ${task_id}. Send NEEDS_HUMAN to lead and go idle."
+fi
+
+# TaskCompleted can fire when a teammate finishes a turn with in-progress work.
+# Only an explicit implementer completion attempt writes this marker.
+if [[ ! -f "${state_dir}/completion_intent" ]]; then
+    exit 0
+fi
+rm -f "${state_dir}/completion_intent"
+
+if [[ -f "${state_dir}/reviewed_pass" ]]; then
+    exit 0
+fi
+
+round="$(jq -r '.round // 0' "$state_file" 2>/dev/null || printf '0')"
+max_rounds="$(jq -r '.max_rounds // 3' "$state_file" 2>/dev/null || printf '3')"
+baseline_sha="$(jq -r '.baseline_sha // ""' "$state_file" 2>/dev/null || printf '')"
+task_context_path="$(jq -r '.task_context_path // ""' "$state_file" 2>/dev/null || printf '')"
+
+if [[ ! "$round" =~ ^[0-9]+$ ]]; then
+    round="0"
+fi
+if [[ ! "$max_rounds" =~ ^[0-9]+$ || "$max_rounds" -lt 1 ]]; then
+    max_rounds="3"
+fi
+
+if [[ "$round" -ge "$max_rounds" ]]; then
+    touch "${state_dir}/exhausted"
+    block "Already exhausted (round=${round}, max=${max_rounds}). Do not retry TaskUpdate(status:'completed'). SendMessage NEEDS_HUMAN ${task_id} to the lead and go idle."
+fi
+
+if [[ -z "$baseline_sha" ]]; then
+    write_last_error "state_invalid: missing baseline_sha in ${state_file}"
+    block "INFRA-FAILURE: missing baseline_sha for ${task_id}. Send NEEDS_HUMAN to lead and go idle."
+fi
+if [[ -z "$task_context_path" || ! -f "$task_context_path" ]]; then
+    write_last_error "state_invalid: missing task_context_path '${task_context_path}' for ${task_id}"
+    block "INFRA-FAILURE: missing task context for ${task_id}. Send NEEDS_HUMAN to lead and go idle."
+fi
+if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
+    write_last_error "git_error: hook cwd is not inside a git worktree: ${cwd}"
+    block "INFRA-FAILURE: hook did not run inside a git worktree. Send NEEDS_HUMAN to lead and go idle."
+fi
+
+commit_range="${baseline_sha}..HEAD"
+if ! git rev-parse --verify "${baseline_sha}^{commit}" >/dev/null 2>&1; then
+    write_last_error "git_error: baseline commit not found: ${baseline_sha}"
+    block "INFRA-FAILURE: baseline commit ${baseline_sha} was not found. Send NEEDS_HUMAN to lead and go idle."
+fi
+
+commits_for_task="$(git log --pretty='%H %(trailers:key=Cerberus-Task,valueonly,separator=%x20)' "$commit_range" | awk -v t="$task_id" '$2 == t { print $1 }' || true)"
+if [[ -z "$commits_for_task" ]]; then
+    increment_round
+    mark_exhausted_if_needed
+    next_round=$((round + 1))
+    if [[ -f "${state_dir}/exhausted" ]]; then
+        block "No commits found tagged 'Cerberus-Task: ${task_id}' since baseline ${baseline_sha}. Round ${next_round} of ${max_rounds}; review rounds are now exhausted. Do not retry TaskUpdate(status:'completed'). SendMessage NEEDS_HUMAN ${task_id} to the lead and go idle."
+    fi
+    block "No commits found tagged 'Cerberus-Task: ${task_id}' since baseline ${baseline_sha}. Make at least one commit with the required trailer before retrying TaskUpdate(status:'completed'). Round ${next_round} of ${max_rounds}."
+fi
+
+untagged_in_range="$(git log --pretty='%H %(trailers:key=Cerberus-Task,valueonly,separator=%x20)' "$commit_range" | awk -v t="$task_id" 'NF == 1 || $2 != t { print $1 }' || true)"
+if [[ -n "$untagged_in_range" ]]; then
+    increment_round
+    mark_exhausted_if_needed
+    next_round=$((round + 1))
+    if [[ -f "${state_dir}/exhausted" ]]; then
+        block "Commits in ${commit_range} are missing the required Cerberus-Task: ${task_id} trailer or carry a different task trailer: ${untagged_in_range}. Round ${next_round} of ${max_rounds}; review rounds are now exhausted. Do not retry TaskUpdate(status:'completed'). SendMessage NEEDS_HUMAN ${task_id} to the lead and go idle."
+    fi
+    block "Commits in ${commit_range} are missing the required Cerberus-Task: ${task_id} trailer or carry a different task trailer: ${untagged_in_range}. Amend/squash so every commit in the range belongs to ${task_id}, then retry. Round ${next_round} of ${max_rounds}."
+fi
+
+if [[ ! -x "$REVIEW_GATE" ]]; then
+    write_last_error "spawn_failed: review-gate is not executable at ${REVIEW_GATE}"
+    block "INFRA-FAILURE: review-gate is not executable. Send NEEDS_HUMAN to lead and go idle."
+fi
+
+session_key="cerberus-impl-${team_hash}-${task_id}-round${round}"
+spawn_stdout="${state_dir}/spawn.stdout"
+spawn_stderr="${state_dir}/spawn.stderr"
+spawn_rc=0
+REVIEW_GATE_SESSION_KEY="$session_key" \
+    "$REVIEW_GATE" spawn-code-review \
+    --max-rounds 0 --consensus majority --mode fast \
+    --context-file "$task_context_path" \
+    "$commit_range" >"$spawn_stdout" 2>"$spawn_stderr" || spawn_rc=$?
+
+if [[ "$spawn_rc" -ne 0 ]]; then
+    {
+        printf 'spawn_failed: spawn-code-review exited %d\n' "$spawn_rc"
+        printf 'stderr:\n'
+        cat "$spawn_stderr" 2>/dev/null || true
+    } > "${state_dir}/last_error"
+    block "INFRA-FAILURE: spawn-code-review exited ${spawn_rc}. Send NEEDS_HUMAN to lead and go idle."
+fi
+
+wait_json=""
+wait_rc=0
+wait_json="$("$REVIEW_GATE" wait --json --finalize --timeout 1800 --poll-interval 3 --session-key "$session_key")" || wait_rc=$?
+printf '%s\n' "$wait_json" > "${state_dir}/wait.json"
+
+verdict="$(printf '%s' "$wait_json" | jq -r '.consensus_verdict // empty' 2>/dev/null || printf '')"
+wait_status="$(printf '%s' "$wait_json" | jq -r '.status // empty' 2>/dev/null || printf '')"
+has_blockers="$(printf '%s' "$wait_json" | jq -r '[.aggregated_findings[]? | select(((.priority // "") | tostring | test("^(0|1|P0|P1)$"; "i")) or ((.severity // "") | tostring | test("^(P0|P1|0|1)$"; "i")) or ((.title // .body // "") | tostring | test("\\[P[01]\\]"; "i")))] | length' 2>/dev/null || printf '0')"
+if [[ ! "$has_blockers" =~ ^[0-9]+$ ]]; then
+    has_blockers="0"
+fi
+
+if [[ "$verdict" == "PASS" || ( "$verdict" == "NEEDS_WORK" && "$has_blockers" -eq 0 ) ]]; then
+    increment_round
+    touch "${state_dir}/reviewed_pass"
+    exit 0
+fi
+
+if [[ "$verdict" == "FAIL" || ( "$verdict" == "NEEDS_WORK" && "$has_blockers" -gt 0 ) ]]; then
+    findings="$(printf '%s' "$wait_json" | jq -r '.aggregated_findings[]? | "- [" + ((.priority // .severity // "P?") | tostring) + "] " + ((.file_path // .file // .path // "") | tostring) + (if (.line_start // .line // null) then ":" + ((.line_start // .line) | tostring) else "" end) + " - " + ((.body // .message // .title // .summary // "") | tostring)' 2>/dev/null || true)"
+    increment_round
+    mark_exhausted_if_needed
+    {
+        printf 'CERBERUS REVIEW: BLOCKED on task %s (round %s of %s).\n' "$task_id" "$((round + 1))" "$max_rounds"
+        printf 'Verdict: %s\n' "$verdict"
+        printf 'Findings:\n'
+        if [[ -n "$findings" ]]; then
+            printf '%s\n' "$findings"
+        else
+            printf '- Review reported blocking findings but no structured findings were parsed. See %s/wait.json.\n' "$state_dir"
+        fi
+        if [[ "$round" -eq $((max_rounds - 1)) ]]; then
+            printf '\nTHIS IS YOUR FINAL REVIEWED ROUND.\n'
+            printf 'Review will not fire again on a retry. If your next attempt would still fail, you MUST instead SendMessage(STATUS: NEEDS_HUMAN %s) to the lead and go idle.\n' "$task_id"
+            printf 'Do NOT retry TaskUpdate(status:'"'"'completed'"'"') after a final-round failure.\n'
+        fi
+    } >&2
+    exit 2
+fi
+
+{
+    printf 'wait_failed: status=%s verdict=%s wait_rc=%s\n' "$wait_status" "$verdict" "$wait_rc"
+    printf 'raw_wait_json:\n%s\n' "$wait_json"
+} > "${state_dir}/last_error"
+block "INFRA-FAILURE: review-gate wait ended with status='${wait_status}' verdict='${verdict}' rc=${wait_rc}. Send NEEDS_HUMAN to lead and go idle."
diff --git a/bin/tests/test-cerberus-task-completed-hook.sh b/bin/tests/test-cerberus-task-completed-hook.sh
new file mode 100755
index 0000000..bcb3f13
--- /dev/null
+++ b/bin/tests/test-cerberus-task-completed-hook.sh
@@ -0,0 +1,232 @@
+#!/usr/bin/env bash
+
+set -euo pipefail
+
+SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
+HOOK="$SCRIPT_DIR/../cerberus-task-completed-hook"
+
+RED='\033[0;31m'
+GREEN='\033[0;32m'
+YELLOW='\033[1;33m'
+NC='\033[0m'
+
+TEST_DIR=""
+
+log_test() {
+    echo -e "${YELLOW}TEST:${NC} $1"
+}
+
+log_pass() {
+    echo -e "${GREEN}PASS:${NC} $1"
+}
+
+log_fail() {
+    echo -e "${RED}FAIL:${NC} $1"
+    exit 1
+}
+
+cleanup() {
+    if [[ -n "$TEST_DIR" ]]; then
+        rm -rf "$TEST_DIR"
+    fi
+}
+
+trap cleanup EXIT
+
+TEST_DIR=$(mktemp -d)
+TMP_ROOT="$TEST_DIR/tmp"
+mkdir -p "$TMP_ROOT"
+
+run_hook() {
+    local subject="$1"
+    local hook_cwd="${2:-$PWD}"
+    printf '{"hook_event_name":"TaskCompleted","task_subject":"%s","cwd":"%s","session_id":"test-session","transcript_path":"%s/transcript.jsonl"}' \
+        "$subject" "$hook_cwd" "$TEST_DIR" | TMPDIR="$TMP_ROOT" "$HOOK"
+}
+
+write_state() {
+    local max_rounds="${1:-3}"
+    local baseline_sha="${2:-$(git rev-parse HEAD)}"
+    local state_dir="$TMP_ROOT/cerberus-task-completed-hook/abc123/T001"
+    mkdir -p "$state_dir"
+    printf 'context\n' > "$state_dir/task-context.md"
+    jq -n \
+        --arg task_id T001 \
+        --arg claude_task_id task-1 \
+        --arg team_hash abc123 \
+        --arg baseline_sha "$baseline_sha" \
+        --arg task_state_dir "$state_dir" \
+        --arg task_context_path "$state_dir/task-context.md" \
+        --argjson max_rounds "$max_rounds" \
+        '{task_id:$task_id, claude_task_id:$claude_task_id, team_hash:$team_hash, baseline_sha:$baseline_sha, round:0, max_rounds:$max_rounds, task_state_dir:$task_state_dir, task_context_path:$task_context_path}' \
+        > "$state_dir/state.json"
+    printf '%s' "$state_dir"
+}
+
+make_review_repo() {
+    local repo="$1"
+    mkdir -p "$repo"
+    git -C "$repo" init -q
+    git -C "$repo" config user.email test@example.com
+    git -C "$repo" config user.name Test
+    git -C "$repo" commit --allow-empty -q -m init
+    git -C "$repo" rev-parse HEAD > "$repo/baseline"
+    printf 'hello\n' > "$repo/hello.txt"
+    git -C "$repo" add hello.txt
+    git -C "$repo" commit -q -m "T001: add hello" -m "Cerberus-Task: T001"
+}
+
+make_fake_review_gate() {
+    local plugin_root="$1"
+    mkdir -p "$plugin_root/bin"
+    cat > "$plugin_root/bin/review-gate" <<'FAKE_REVIEW_GATE'
+#!/usr/bin/env bash
+set -euo pipefail
+case "${1:-}" in
+  spawn-code-review)
+    exit 0
+    ;;
+  wait)
+    printf '%s\n' "${FAKE_WAIT_JSON}"
+    case "${FAKE_WAIT_RC:-0}" in
+      0) exit 0 ;;
+      *) exit "${FAKE_WAIT_RC}" ;;
+    esac
+    ;;
+  *)
+    echo "unexpected fake review-gate command: ${1:-}" >&2
+    exit 2
+    ;;
+esac
+FAKE_REVIEW_GATE
+    chmod +x "$plugin_root/bin/review-gate"
+}
+
+log_test "unrelated TaskCompleted events fail open"
+set +e
+output=$(run_hook "ordinary task" 2>&1)
+status=$?
+set -e
+if [[ "$status" -ne 0 || -n "$output" ]]; then
+    log_fail "expected unrelated task to exit 0 silently, got status=$status output=$output"
+fi
+log_pass "unrelated task ignored"
+
+log_test "prefixed task without state writes last_error and blocks"
+set +e
+output=$(run_hook "[CERBERUS-IMPL/abc123] T001 - test" 2>&1)
+status=$?
+set -e
+last_error="$TMP_ROOT/cerberus-task-completed-hook/abc123/T001/last_error"
+if [[ "$status" -ne 2 || ! -f "$last_error" || "$output" != *"INFRA-FAILURE: missing Cerberus state"* ]]; then
+    log_fail "expected missing state to exit 2 and write last_error, got status=$status output=$output"
+fi
+log_pass "missing state blocks completion"
+
+log_test "prefixed task with state but no completion_intent fails open"
+rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
+state_dir=$(write_state)
+set +e
+output=$(run_hook "[CERBERUS-IMPL/abc123] T001 - test" 2>&1)
+status=$?
+set -e
+round=$(jq -r '.round' "$state_dir/state.json")
+if [[ "$status" -ne 0 || "$round" != "0" || -n "$output" ]]; then
+    log_fail "expected no-intent event to exit 0 without state changes, status=$status round=$round output=$output"
+fi
+log_pass "no-intent event ignored"
+
+log_test "explicit completion without tagged commits blocks and increments round"
+touch "$state_dir/completion_intent"
+set +e
+output=$(run_hook "[CERBERUS-IMPL/abc123] T001 - test" 2>&1)
+status=$?
+set -e
+round=$(jq -r '.round' "$state_dir/state.json")
+if [[ "$status" -ne 2 || "$round" != "1" || "$output" != *"No commits found tagged 'Cerberus-Task: T001'"* ]]; then
+    log_fail "expected no-commit completion to block and increment round, status=$status round=$round output=$output"
+fi
+if [[ -e "$state_dir/completion_intent" ]]; then
+    log_fail "expected completion_intent to be consumed"
+fi
+log_pass "missing tagged commit blocks completion"
+
+log_test "final blocking attempt writes exhausted marker"
+rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
+state_dir=$(write_state 1)
+touch "$state_dir/completion_intent"
+set +e
+output=$(run_hook "[CERBERUS-IMPL/abc123] T001 - test" 2>&1)
+status=$?
+set -e
+round=$(jq -r '.round' "$state_dir/state.json")
+if [[ "$status" -ne 2 || "$round" != "1" || ! -f "$state_dir/exhausted" ]]; then
+    log_fail "expected final failed attempt to write exhausted, status=$status round=$round output=$output"
+fi
+log_pass "final failed attempt marks exhausted"
+
+log_test "PASS review writes reviewed_pass and increments round"
+rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
+repo="$TEST_DIR/pass-repo"
+make_review_repo "$repo"
+baseline=$(cat "$repo/baseline")
+state_dir=$(write_state 3 "$baseline")
+touch "$state_dir/completion_intent"
+fake_plugin="$TEST_DIR/fake-plugin-pass"
+make_fake_review_gate "$fake_plugin"
+set +e
+output=$(printf '{"hook_event_name":"TaskCompleted","task_subject":"%s","cwd":"%s","session_id":"test-session","transcript_path":"%s/transcript.jsonl"}' \
+    "[CERBERUS-IMPL/abc123] T001 - test" "$repo" "$TEST_DIR" \
+    | TMPDIR="$TMP_ROOT" CLAUDE_PLUGIN_ROOT="$fake_plugin" FAKE_WAIT_JSON='{"status":"complete","consensus_verdict":"PASS","aggregated_findings":[]}' "$HOOK" 2>&1)
+status=$?
+set -e
+round=$(jq -r '.round' "$state_dir/state.json")
+if [[ "$status" -ne 0 || "$round" != "1" || ! -f "$state_dir/reviewed_pass" ]]; then
+    log_fail "expected PASS review to allow completion, status=$status round=$round output=$output"
+fi
+log_pass "PASS review allows completion"
+
+log_test "PASS on final allowed round does not mark exhausted"
+rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
+repo="$TEST_DIR/final-pass-repo"
+make_review_repo "$repo"
+baseline=$(cat "$repo/baseline")
+state_dir=$(write_state 3 "$baseline")
+jq '.round = 2' "$state_dir/state.json" > "$state_dir/state.json.tmp"
+mv "$state_dir/state.json.tmp" "$state_dir/state.json"
+touch "$state_dir/completion_intent"
+fake_plugin="$TEST_DIR/fake-plugin-final-pass"
+make_fake_review_gate "$fake_plugin"
+set +e
+output=$(printf '{"hook_event_name":"TaskCompleted","task_subject":"%s","cwd":"%s","session_id":"test-session","transcript_path":"%s/transcript.jsonl"}' \
+    "[CERBERUS-IMPL/abc123] T001 - test" "$repo" "$TEST_DIR" \
+    | TMPDIR="$TMP_ROOT" CLAUDE_PLUGIN_ROOT="$fake_plugin" FAKE_WAIT_JSON='{"status":"complete","consensus_verdict":"PASS","aggregated_findings":[]}' "$HOOK" 2>&1)
+status=$?
+set -e
+round=$(jq -r '.round' "$state_dir/state.json")
+if [[ "$status" -ne 0 || "$round" != "3" || ! -f "$state_dir/reviewed_pass" || -f "$state_dir/exhausted" ]]; then
+    log_fail "expected final-round PASS to allow completion without exhausted, status=$status round=$round output=$output"
+fi
+log_pass "final-round PASS remains a success"
+
+log_test "blocking review formats findings and marks exhausted on final round"
+rm -rf "$TMP_ROOT/cerberus-task-completed-hook/abc123"
+repo="$TEST_DIR/fail-repo"
+make_review_repo "$repo"
+baseline=$(cat "$repo/baseline")
+state_dir=$(write_state 1 "$baseline")
+touch "$state_dir/completion_intent"
+fake_plugin="$TEST_DIR/fake-plugin-fail"
+make_fake_review_gate "$fake_plugin"
+wait_json='{"status":"complete","consensus_verdict":"NEEDS_WORK","aggregated_findings":[{"priority":"P1","file_path":"hello.txt","line_start":1,"body":"broken behavior"}]}'
+set +e
+output=$(printf '{"hook_event_name":"TaskCompleted","task_subject":"%s","cwd":"%s","session_id":"test-session","transcript_path":"%s/transcript.jsonl"}' \
+    "[CERBERUS-IMPL/abc123] T001 - test" "$repo" "$TEST_DIR" \
+    | TMPDIR="$TMP_ROOT" CLAUDE_PLUGIN_ROOT="$fake_plugin" FAKE_WAIT_JSON="$wait_json" FAKE_WAIT_RC=1 "$HOOK" 2>&1)
+status=$?
+set -e
+round=$(jq -r '.round' "$state_dir/state.json")
+if [[ "$status" -ne 2 || "$round" != "1" || ! -f "$state_dir/exhausted" || "$output" != *"hello.txt:1 - broken behavior"* ]]; then
+    log_fail "expected blocking review to fail with formatted finding and exhausted marker, status=$status round=$round output=$output"
+fi
+log_pass "blocking review fails with useful feedback"
diff --git a/commands/create-tasks.md b/commands/create-tasks.md
index e721373..1bfcc40 100644
--- a/commands/create-tasks.md
+++ b/commands/create-tasks.md
@@ -1,11 +1,11 @@
 ---
-description: Generate actionable tasks from a plan, outputting to Beads issues (--beads) or TODO.md
-argument-hint: [--beads] [--from-plan <path/to/plan.md>]
+description: Generate actionable tasks from a plan, outputting to Beads issues (--beads), agent-team tasks (--agent-team), or TODO.md
+argument-hint: [--beads | --agent-team] [--from-plan <path/to/plan.md>]
 ---
 
 # Create Tasks (Plan → Execution Artifacts)
 
-Convert a stable implementation plan into actionable, dependency-ordered tasks. Output to either **Beads issues** (with `--beads` flag) or a **TODO.md** file (default).
+Convert a stable implementation plan into actionable, dependency-ordered tasks. Output to **Beads issues** (with `--beads` flag), an **agent-team task file** (with `--agent-team` flag), or a **TODO.md** file (default).
 
 > **Upstream**: This command accepts output from `/create-plan`.
 > **Downstream**: Output is validated by `/review-tasks`.
@@ -24,6 +24,9 @@ Convert a stable implementation plan into actionable, dependency-ordered tasks.
 |------|--------|----------|
 | (default) | `TODO.md` in plan directory | Quick projects, no issue tracker |
 | `--beads` | Beads issues with dependencies | Multi-agent parallelization, tracked work |
+| `--agent-team` | `*-team-tasks.md` next to the plan | Autonomous implementer/reviewer team loop via `/cerberus:run-team` |
+
+`--beads` and `--agent-team` are mutually exclusive. If both are supplied, abort before generating output.
 
 ## Input
 
@@ -599,7 +602,30 @@ Use the **beads skill** to create issues. Follow these patterns:
    br ready
    ```
 
-#### If no `--beads` flag (default):
+#### If `--agent-team` flag is set:
+
+Generate a `*-team-tasks.md` file in the same directory as the plan, using the plan filename prefix so multiple plans do not collide. Examples:
+- `docs/auth-system-plan.md` → `docs/auth-system-team-tasks.md`
+- `~/.claude/plans/search-plan.md` → `~/.claude/plans/search-team-tasks.md`
+
+Use `templates/team-tasks-template.md` as the canonical schema. This format is intentionally Markdown with a YAML frontmatter block and a fenced `meta` block under each task heading so `/cerberus:run-team` can parse it cleanly.
+
+**Team task format requirements:**
+- Header frontmatter includes `plan`, `spec` (or `N/A`), and `generated`.
+- Each task heading is exactly `## T### — <subject>`.
+- The first fenced block immediately under each task heading is always ```meta.
+- The `meta` block includes `files`, `depends`, `acceptance`, and `plan_link`.
+- `depends` is always an explicit list, even when empty: `depends: []`.
+- The task body after the `meta` fence contains the full task spec from Phase 4, equivalent to the default TODO.md collapsible task detail content.
+
+**Parser contract:** Task bodies may contain additional fenced code blocks. The runner treats only the first fenced block immediately under the `## T###` heading as metadata; body parsing continues from after that first fence until the next `## ` heading at column 0 or EOF. Do not place narrative text between a task heading and its `meta` block.
+
+**Output path handling:**
+- If the target file already exists, ask whether to overwrite it before writing.
+- Include all source document links, sizing notes, dependencies, verification steps, and acceptance criteria from the validated Phase 4 task specs.
+- Report the output path and total task count in Phase 7.
+
+#### If neither `--beads` nor `--agent-team` is set (default):
 
 Generate `TODO.md` in the same directory as the plan.
 
@@ -622,7 +648,7 @@ Output summary:
 ```
 ## Tasks Generated
 
-**Output**: [TODO.md path] or [Beads epic ID]
+**Output**: [TODO.md path] or [team-tasks.md path] or [Beads epic ID]
 **Total Tasks**: N
 **Phases**: X
 **Parallelizable**: M tasks can run concurrently
diff --git a/commands/run-team.md b/commands/run-team.md
new file mode 100644
index 0000000..0e81542
--- /dev/null
+++ b/commands/run-team.md
@@ -0,0 +1,206 @@
+---
+description: Run an implementer/reviewer team against a team-tasks.md file
+argument-hint: [--from-tasks <path/to/team-tasks.md>] [--max-review-rounds <n>] [--skip-verify]
+---
+
+# Run Team
+
+Run a strictly serial agent-team implementation loop from a `*-team-tasks.md` file generated by `/cerberus:create-tasks --agent-team`. You are the team lead. Implementer teammates do the file edits and commits; the `TaskCompleted` hook runs Cerberus code review; you schedule tasks and classify outcomes.
+
+## Hard Lead Rules
+
+- The lead MUST NOT call `TaskUpdate(status: "completed")` on any task in this team's TaskList. Task completion is owned exclusively by implementer teammates.
+- The lead may call `TaskUpdate(owner: ...)` and `TaskUpdate(status: "deleted")` for cancellation, but must never move a task to `completed`.
+- The lead never edits repository files. The lead may write per-task state files under `${TMPDIR:-/tmp}/cerberus-task-completed-hook/<team_hash>/` via Bash.
+- The lead never invokes `/cerberus:review-code` directly. Code review fires automatically from the `TaskCompleted` hook.
+- Scheduling is strictly serial: run at most one implementer teammate at a time.
+
+## Phase 0: Preflight
+
+Abort with a clear error if any hard gate fails.
+
+1. **Agent teams enabled**. Verify either the shell env has `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` or `~/.claude/settings.json` has `.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS == "1"`. If not, abort:
+
+   ```text
+   Agent teams are disabled. Enable them by adding CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 to your shell env or to ~/.claude/settings.json (env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS), then restart Claude Code.
+   ```
+
+2. **Supported Claude Code version**. Run `claude --version` and compare semver-style against `2.1.32`. If older, abort:
+
+   ```text
+   Agent teams require Claude Code v2.1.32 or later (you have <detected_version>). Upgrade Claude Code, then retry.
+   ```
+
+3. **Clean tracked files**. Run `git status --porcelain --untracked-files=no`. It must be empty. If not, abort:
+
+   ```text
+   Working tree has uncommitted changes to tracked files. Commit, stash, or discard them before running /cerberus:run-team. Untracked files are OK and will be left alone.
+   ```
+
+4. **Default branch warning**. Detect the repo default branch and current branch. If they differ, warn but do not abort.
+
+5. **Review-gate keying available**. Confirm `${CLAUDE_PLUGIN_ROOT}/bin/review-gate` exists and that `spawn-code-review` supports `REVIEW_GATE_SESSION_KEY` while `wait` supports `--session-key`. If not, abort with the missing capability.
+
+## Phase 1: Load Team Tasks
+
+1. Resolve `--from-tasks`:
+   - If provided, use that path.
+   - Otherwise find the most recent `*-plan.md` in `docs/` or `~/.claude/plans/`, then look for a sibling file with the same prefix and `-team-tasks.md` suffix.
+   - Abort if zero or multiple candidates are found.
+2. Read YAML frontmatter and every `## T### — <subject>` section.
+3. For each task, parse the first fenced block immediately under the heading as `meta`; the body extends from after that fence until the next `## ` heading at column 0 or EOF.
+4. Build a dependency graph from `depends: [...]`; abort on unknown task IDs or cycles.
+5. Resolve `--max-review-rounds` as an integer greater than zero, default `3`.
+6. Resolve `--skip-verify`, default false.
+
+## Phase 2: Team Setup
+
+Compute a unique team hash from the tasks path, second-precision UTC timestamp, and four random bytes:
+
+```bash
+team_hash=$(printf '%s|%s|%s' "$tasks_path" "$(date -u +%Y%m%dT%H%M%SZ)" "$(head -c 4 /dev/urandom | xxd -p)" | shasum -a 256 | cut -c1-10)
+state_root="${TMPDIR:-/tmp}/cerberus-task-completed-hook/${team_hash}"
+if [ -e "$state_root" ] && [ -n "$(ls -A "$state_root" 2>/dev/null)" ]; then
+  echo "team_hash collision detected at $state_root; refusing to overwrite. Re-run /cerberus:run-team to get a fresh team_hash, or wipe the directory manually if you know it's safe." >&2
+  exit 2
+fi
+mkdir -p "$state_root"
+```
+
+Create the team:
+
+```text
+TeamCreate(team_name: "cerberus-impl-<team_hash>", description: "Run team for <feature>", agent_type: "team-lead")
+```
+
+If `TeamCreate` reports that the team already exists, abort:
+
+```text
+Team 'cerberus-impl-<team_hash>' already exists (likely from an interrupted prior run). Run TeamDelete on it from a Claude session and retry /cerberus:run-team.
+```
+
+For every Cerberus task, create one Claude TaskList task:
+
+```text
+TaskCreate(
+  subject: "[CERBERUS-IMPL/<team_hash>] T### — <subject>",
+  description: <full task spec body>,
+  metadata: {
+    cerberus_task_id: "T###",
+    cerberus_team_hash: "<team_hash>",
+    cerberus_files: [...],
+    cerberus_depends: [...]
+  }
+)
+```
+
+Remember the mapping from `T###` to the returned Claude task ID.
+
+## Phase 3: Serial Scheduling
+
+Maintain local state for each Cerberus task: `pending`, `running`, `passed`, `failed`, or `skipped`. Recompute the ready set after every success; choose the lowest task ID whose dependencies all passed.
+
+Before spawning an implementer for a ready task, write state exactly like this from the repo root:
+
+```bash
+task_id="T001"
+claude_task_id="<returned-task-id>"
+state_dir="${TMPDIR:-/tmp}/cerberus-task-completed-hook/${team_hash}/${task_id}"
+task_context_path="${state_dir}/task-context.md"
+baseline_sha=$(git rev-parse HEAD)
+mkdir -p "$state_dir"
+jq -n \
+  --arg task_id "$task_id" \
+  --arg claude_task_id "$claude_task_id" \
+  --arg team_hash "$team_hash" \
+  --arg baseline_sha "$baseline_sha" \
+  --arg task_state_dir "$state_dir" \
+  --arg task_context_path "$task_context_path" \
+  --argjson max_rounds "$max_review_rounds" \
+  '{task_id:$task_id, claude_task_id:$claude_task_id, team_hash:$team_hash, baseline_sha:$baseline_sha, round:0, max_rounds:$max_rounds, task_state_dir:$task_state_dir, task_context_path:$task_context_path}' \
+  > "${state_dir}/state.json"
+cat > "$task_context_path" <<'TASK_CONTEXT'
+<task heading, meta files/dependencies/acceptance, and full task body>
+TASK_CONTEXT
+git status --porcelain -z | tr '\0' '\n' | awk '/^\?\? / { print substr($0, 4) }' > "${state_dir}/untracked_baseline.txt"
+```
+
+Spawn a fresh teammate for the task:
+
+```text
+Agent({
+  team_name: "cerberus-impl-<team_hash>",
+  name: "impl-T###",
+  subagent_type: "implementer",
+  description: "T### implement <subject>",
+  prompt: "You are assigned CERBERUS_TASK_ID=T###. Claude task id: <claude_task_id>. State dir: <state_dir>. You may set CERBERUS_STATE_DIR='<state_dir>' for convenience, but immediately before TaskUpdate(status:'completed') you MUST run exactly: touch \"<state_dir>/completion_intent\". Claim the task with TaskUpdate(owner:'impl-T###', status:'in_progress'), implement only this task, commit with trailer Cerberus-Task: T###, and follow the implementer agent rules.\n\n<full task spec>"
+})
+```
+
+Wait for the teammate to go idle. On every `TeammateIdle`, inspect `TaskGet(<claude_task_id>)`, marker files in `state_dir`, and messages from the teammate.
+
+## Phase 4: Outcome Classification
+
+Classify the running task into exactly one category.
+
+- **success**: Claude task status is `completed`, no `exhausted`, no `last_error`, and `reviewed_pass` exists. Before finalizing success, run the post-task clean-tree gate below. If the gate passes, mark the Cerberus task passed, record commits in `baseline_sha..HEAD`, delete `state_dir`, and schedule the next ready task.
+- **needs-human**: teammate sent `STATUS: NEEDS_HUMAN T###` while the Claude task remains `in_progress`, or `exhausted` exists while the task remains `in_progress`. Mark failed, retain `state_dir`, stop scheduling.
+- **unverified-failure**: task status is `completed` but `reviewed_pass` is absent, or task status is `completed` while `exhausted` exists. Mark failed, retain `state_dir`, stop scheduling.
+- **infra-failure**: `last_error` exists. Mark failed, retain `state_dir`, include raw `last_error` in the final report, stop scheduling.
+- **abandoned**: teammate went idle with task still `in_progress` and no `exhausted`, no `last_error`, and no `STATUS: NEEDS_HUMAN` message. Mark failed, retain `state_dir`, stop scheduling.
+
+### Post-Task Clean-Tree Gate
+
+Run this only after a provisional `success` and before deleting `state_dir`.
+
+1. Tracked files must be clean:
+
+   ```bash
+   git status --porcelain --untracked-files=no
+   ```
+
+   If non-empty, downgrade to `unverified-failure` with reason `task left modified tracked files outside its commits`.
+
+2. No new untracked files may have appeared outside commits:
+
+   ```bash
+   git status --porcelain -z | tr '\0' '\n' | awk '/^\?\? / { print substr($0, 4) }' > "${state_dir}/untracked_current.txt"
+   comm -23 <(sort "${state_dir}/untracked_current.txt") <(sort "${state_dir}/untracked_baseline.txt")
+   ```
+
+   If any path is printed, downgrade to `unverified-failure` with reason `task left new untracked file(s) outside its commits`.
+
+On any non-success outcome, do not unblock dependents and do not schedule independent tasks. Failed task commits remain on the current branch; never run `git reset --hard` or destructive cleanup automatically.
+
+## Phase 5: Epic Verification
+
+If all Cerberus tasks passed, `--skip-verify` is not set, and the team-tasks frontmatter `plan` field resolves to a real file, run the existing epic verifier through `review-gate`:
+
+```bash
+VERIFY_KEY="cerberus-team-verify-${team_hash}"
+REVIEW_GATE_SESSION_KEY="$VERIFY_KEY" \
+  "${CLAUDE_PLUGIN_ROOT}/bin/review-gate" spawn-epic-verify \
+    --consensus majority --mode fast \
+    "<plan-or-spec-path>"
+
+verify_json=""
+verify_rc=0
+verify_json=$("${CLAUDE_PLUGIN_ROOT}/bin/review-gate" wait --json --finalize \
+  --session-key "$VERIFY_KEY") || verify_rc=$?
+verify_verdict=$(printf '%s' "$verify_json" | jq -r '.consensus_verdict // empty' 2>/dev/null || true)
+```
+
+Include the verdict and findings in the final report. If any task failed or `--skip-verify` is set, skip this phase and explain why.
+
+## Phase 6: Final Report
+
+Report:
+
+- Team name and `team_hash`.
+- Team tasks file path.
+- Table of tasks with `passed`, `failed`, or `skipped`, including commit ranges for passed tasks.
+- Failed task category: `needs-human`, `unverified-failure`, `infra-failure`, or `abandoned`.
+- For failures: baseline SHA, retained state directory, raw `last_error` if present, and manual recovery options such as `git reset --hard <baseline_sha>` or `git revert <commit_range>`.
+- Epic verification verdict and findings, or why it was skipped.
+- Retry note: rerunning `/cerberus:run-team` is safe after fixing the root cause because each invocation gets a fresh `team_hash`; stale state dirs remain only for debugging.
+- Cleanup note: successful task state dirs are deleted automatically; failed state dirs remain at `${TMPDIR:-/tmp}/cerberus-task-completed-hook/<team_hash>/<task_id>/`. Leave the team intact by default so the user can inspect it; tell the user they may run `TeamDelete` manually when done.
diff --git a/hooks/hooks.json b/hooks/hooks.json
index e007fd9..1b1320c 100644
--- a/hooks/hooks.json
+++ b/hooks/hooks.json
@@ -20,6 +20,17 @@
           }
         ]
       }
+    ],
+    "TaskCompleted": [
+      {
+        "hooks": [
+          {
+            "type": "command",
+            "command": "${CLAUDE_PLUGIN_ROOT}/bin/cerberus-task-completed-hook",
+            "timeout": 2100
+          }
+        ]
+      }
     ]
   }
 }
diff --git a/templates/team-tasks-template.md b/templates/team-tasks-template.md
new file mode 100644
index 0000000..833f02a
--- /dev/null
+++ b/templates/team-tasks-template.md
@@ -0,0 +1,136 @@
+<!--
+  Canonical team task schema for `/create-tasks --agent-team`.
+
+  Parser contract for `/cerberus:run-team`:
+  - Each task starts with a level-two heading at column 0: `## T### — <subject>`.
+  - The first fenced block immediately under that heading MUST be ```meta.
+  - No narrative text may appear between the heading and the meta block.
+  - The task body begins after the first meta fence closes and continues until
+    the next `## ` heading at column 0 or EOF.
+  - Task bodies may contain other fenced code blocks; the parser must treat only
+    the first fence under the heading as metadata.
+-->
+
+---
+plan: <path-to-plan>.md
+spec: <path-to-spec>.md # or N/A
+generated: <ISO timestamp>
+---
+
+# Team Tasks: <Feature>
+
+**Generated**: <ISO timestamp>
+**Plan**: [<path-to-plan>.md](<path-to-plan>.md)
+**Spec**: [<path-to-spec>.md](<path-to-spec>.md) or N/A
+
+## Overview
+
+<1-2 sentence summary from the plan's Context & Goals.>
+
+## Task Summary
+
+| Phase | Tasks | Dependencies |
+|-------|-------|--------------|
+| Setup | N | [] |
+| Foundation | N | [T001] |
+| US1: <Name> | N | [T00X] |
+
+---
+
+## T001 — <subject>
+```meta
+files: [path/a.py, path/b.py]
+depends: []
+acceptance: [AC1, AC2]
+plan_link: <plan>.md#L45-L67
+```
+
+### Source Documents
+
+- Plan: [<plan>.md#L45-L67](<plan>.md#L45-L67) — Section: <section title>
+- Spec: [<spec>.md#L12-L34](<spec>.md#L12-L34) — <story or AC label>, or N/A
+
+### Files
+
+- `path/a.py` (New|Exists)
+- `path/b.py` (New|Exists)
+
+### Depends
+
+- None
+
+### Goal
+
+<What this task accomplishes.>
+
+### Implementation Notes
+
+<Full task spec body from Phase 4, including sizing, source links, dependency rationale, TDD steps, and any file-overlap constraints.>
+
+### Verification
+
+- <Command or behavioral check>
+
+---
+
+## T002 — <subject>
+```meta
+files: [path/c.py]
+depends: [T001]
+acceptance: [AC3]
+plan_link: <plan>.md#L68-L90
+```
+
+### Source Documents
+
+- Plan: [<plan>.md#L68-L90](<plan>.md#L68-L90) — Section: <section title>
+
+### Files
+
+- `path/c.py` (New|Exists)
+
+### Depends
+
+- T001
+
+### Goal
+
+<What this task accomplishes.>
+
+### Implementation Notes
+
+<Full task spec body from Phase 4.>
+
+### Verification
+
+- <Command or behavioral check>
+
+---
+
+## Dependencies Graph
+
+```text
+T001 -> T002
+```
+
+## Acceptance Criteria Coverage
+
+| Acceptance Criterion | Primary Task | Verified |
+|----------------------|--------------|----------|
+| AC1: <description> | T001 | [ ] |
+| AC2: <description> | T001 | [ ] |
+| AC3: <description> | T002 | [ ] |
+
+## File Impact Summary
+
+| File | Status | Tasks |
+|------|--------|-------|
+| `path/a.py` | New | T001 |
+| `path/b.py` | Exists | T001 |
+| `path/c.py` | New | T002 |
+
+## Notes
+
+- Total tasks: N
+- Execution model: strictly serial in `/cerberus:run-team` initial cut
+- Each implementer commit must include a `Cerberus-Task: T###` trailer
```
