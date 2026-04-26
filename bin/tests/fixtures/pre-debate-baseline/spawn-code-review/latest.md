<!-- review-type: code -->
<!-- diff-args: --commit c4443c54796a362876c8a1b9e9a1603e0ffeb008 -->
<!-- max-rounds: 3 -->
<!-- agents: codex,gemini,claude -->
<!-- mode: smart -->

# Code Review (Iterative)

## Diff Mode
--commit c4443c54796a362876c8a1b9e9a1603e0ffeb008

## Changes

```diff
diff --git a/.claude-plugin/plugin.json b/.claude-plugin/plugin.json
index a902f02..58854e3 100644
--- a/.claude-plugin/plugin.json
+++ b/.claude-plugin/plugin.json
@@ -1,6 +1,6 @@
 {
   "name": "cerberus",
-  "version": "1.50.4",
+  "version": "1.50.5",
   "description": "Three-headed guardian of code quality. Multi-model consensus review with Codex, Gemini, and Claude.",
   "author": {
     "name": "charlieyou"
diff --git a/bin/tests/test-review-gate-hook-timeout-budget.sh b/bin/tests/test-review-gate-hook-timeout-budget.sh
new file mode 100755
index 0000000..4bbfd89
--- /dev/null
+++ b/bin/tests/test-review-gate-hook-timeout-budget.sh
@@ -0,0 +1,43 @@
+#!/usr/bin/env bash
+
+set -euo pipefail
+
+SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
+REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
+
+RED='\033[0;31m'
+GREEN='\033[0;32m'
+YELLOW='\033[1;33m'
+NC='\033[0m'
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
+log_test "hook wait budget fits within Claude Stop hook timeout"
+
+hook_timeout=$(jq -r '.hooks.Stop[0].hooks[0].timeout // empty' "$REPO_ROOT/hooks/hooks.json")
+if [[ -z "$hook_timeout" || ! "$hook_timeout" =~ ^[0-9]+$ ]]; then
+    log_fail "could not read numeric Stop hook timeout from hooks/hooks.json"
+fi
+
+default_wait=$(sed -n 's/.*MAX_WAIT_SECONDS="${REVIEW_GATE_MAX_WAIT_SECONDS:-\([0-9][0-9]*\)}".*/\1/p' "$REPO_ROOT/bin/review-gate-hook.sh" | head -1)
+if [[ -z "$default_wait" || ! "$default_wait" =~ ^[0-9]+$ ]]; then
+    log_fail "could not read numeric default MAX_WAIT_SECONDS from review-gate-hook.sh"
+fi
+
+slack=$((hook_timeout - default_wait))
+if [[ "$slack" -lt 30 ]]; then
+    log_fail "default MAX_WAIT_SECONDS ($default_wait) must leave at least 30s before Stop hook timeout ($hook_timeout)"
+fi
+
+log_pass "default MAX_WAIT_SECONDS leaves ${slack}s before Stop hook timeout"
diff --git a/hooks/hooks.json b/hooks/hooks.json
index b1036ca..e007fd9 100644
--- a/hooks/hooks.json
+++ b/hooks/hooks.json
@@ -16,7 +16,7 @@
           {
             "type": "command",
             "command": "${CLAUDE_PLUGIN_ROOT}/bin/review-gate check",
-            "timeout": 1200
+            "timeout": 2100
           }
         ]
       }
```
