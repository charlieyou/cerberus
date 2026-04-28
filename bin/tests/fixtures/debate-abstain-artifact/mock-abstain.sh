#!/usr/bin/env bash
# mock-abstain.sh
#
# Reference mock reviewer CLI that always emits unparseable output,
# forcing Mode A abstain in the debate coordinator. Wire this into a
# manual smoke run by symlinking it as `codex`, `gemini`, or `claude`
# under a PATH-prepended fake-bin directory.
#
# Mode A abstain triggers (per spec R2 / Section 2):
#   - .failed sentinel
#   - .json missing/empty
#   - JSON unparseable
#   - missing findings/verdict
#
# This script picks the "JSON unparseable" trigger by emitting a single
# non-JSON sentinel string to stdout (and, when invoked with codex's
# `-o <out>`, writing the same to the out file). The coordinator's
# extract_json fallback fails, the reviewer is classified as Mode A
# abstain (terminal for the run), and the surviving reviewers see
# `(peer abstained)` in their Round-2 peer block.

set -e

out_file=""
prev=""
for arg in "$@"; do
    if [[ "$prev" == "-o" ]]; then
        out_file="$arg"
    fi
    prev="$arg"
done

unparseable='abstain: the model declines to review this artifact (mock-abstain.sh).'

if [[ -n "$out_file" ]]; then
    printf '%s\n' "$unparseable" > "$out_file"
fi
printf '%s\n' "$unparseable"
exit 0
