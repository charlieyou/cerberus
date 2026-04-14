#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../review-gate-lib.sh"

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

assert_epoch() {
    local label="$1"
    local timestamp="$2"
    local expected="$3"
    local actual

    actual=$(iso8601_to_epoch "$timestamp")
    if [[ "$actual" != "$expected" ]]; then
        log_fail "$label expected $expected, got $actual"
    fi

    log_pass "$label"
}

log_test "parses UTC timestamps on macOS-compatible shells"
assert_epoch "UTC timestamp parsed" "2026-04-14T00:40:47Z" "1776127247"

log_test "parses offset timestamps without GNU date"
assert_epoch "offset timestamp parsed" "2026-04-13T20:40:58-04:00" "1776127258"
