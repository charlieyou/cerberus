#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_test() {
    echo -e "${YELLOW}TEST:${NC} $1"
}

log_pass() {
    echo -e "${GREEN}PASS:${NC} $1"
}

log_fail() {
    echo -e "${RED}FAIL:${NC} $1"
    exit 1
}

log_test "hook wait budget fits within Claude Stop hook timeout"

hook_timeout=$(jq -r '.hooks.Stop[0].hooks[0].timeout // empty' "$REPO_ROOT/hooks/hooks.json")
if [[ -z "$hook_timeout" || ! "$hook_timeout" =~ ^[0-9]+$ ]]; then
    log_fail "could not read numeric Stop hook timeout from hooks/hooks.json"
fi

default_wait=$(sed -n 's/.*MAX_WAIT_SECONDS="${REVIEW_GATE_MAX_WAIT_SECONDS:-\([0-9][0-9]*\)}".*/\1/p' "$REPO_ROOT/bin/review-gate-hook.sh" | head -1)
if [[ -z "$default_wait" || ! "$default_wait" =~ ^[0-9]+$ ]]; then
    log_fail "could not read numeric default MAX_WAIT_SECONDS from review-gate-hook.sh"
fi

slack=$((hook_timeout - default_wait))
if [[ "$slack" -lt 30 ]]; then
    log_fail "default MAX_WAIT_SECONDS ($default_wait) must leave at least 30s before Stop hook timeout ($hook_timeout)"
fi

log_pass "default MAX_WAIT_SECONDS leaves ${slack}s before Stop hook timeout"
