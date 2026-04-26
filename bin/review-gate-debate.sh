#!/usr/bin/env bash
# review-gate-debate.sh
#
# Phase C.3 (T005) coordinator helpers for `--debate` mode.
#
# This file provides three pure-shell helpers used by `bin/review-gate`:
#
#   1. _sha256_hex <input>       — emit the lowercase 64-character SHA-256 hex
#                                   digest for the bytes read from stdin or
#                                   for the literal argument when one is
#                                   given. Selects between `shasum -a 256`
#                                   (preferred, macOS default) and
#                                   `sha256sum` (Linux coreutils default) at
#                                   runtime via `command -v`. Hard-errors
#                                   when neither tool is available; never
#                                   silently falls back to a non-cryptographic
#                                   primitive (per spec R3 — silent fallback
#                                   would break the per-(artifact, reviewer)
#                                   determinism contract on systems where
#                                   neither tool is present).
#
#   2. compute_artifact_id <review_type> <args...>
#                                  — return the canonical `<artifact_id>`
#                                   string used as the SHA-256 hash input
#                                   alongside the reviewer canonical name.
#                                   The per-type definition is pinned in
#                                   spec R3:
#                                     plan/spec → realpath of file argument
#                                     code      → verbatim diff_args_str
#                                     epic-verify → realpath when arg is a
#                                                   regular file; otherwise
#                                                   verbatim raw-criteria
#                                                   string (matches the
#                                                   epic_context value the
#                                                   spawn flow already
#                                                   computes).
#
#   3. assign_strategies <artifact_id> <reviewer1> [reviewer2 ...]
#                                  — emit a NEWLINE-separated `<reviewer> <strategy>`
#                                   listing, one per input reviewer, in
#                                   canonical alphabetical iteration order.
#                                   The strategy assignment algorithm follows
#                                   spec R3:
#                                     - canonical alphabetical iteration
#                                     - SHA-256(`<artifact_id>:<reviewer>`)
#                                     - first 8 hex chars → uint → mod 3
#                                       maps to fixed array
#                                       [verification-first, falsification-first, decompose]
#                                     - collision walk: (idx+1)%3, (idx+2)%3
#                                       until a free slot is found
#                                     - N=3 always full permutation; N>3
#                                       wraps back to original preferred idx
#                                       once all three strategies are used
#                                       (the duplicate landing is deterministic).
#
# Determinism scope (D12). `<artifact_id>` is a real path, so determinism is
# per-machine and per-checkout-location. Two engineers reviewing the same
# logical artifact at different absolute paths get different strategy
# assignments — accepted v1 behavior.
#
# Bash 3.2 compatibility. No associative arrays, no `mapfile`/`readarray`,
# no `${var^^}` / `${var,,}`. Uses parallel arrays and canonical-order
# iteration via `sort`.

# ---------------------------------------------------------------------------
# Strategy table (fixed v1 order — index → name).
# ---------------------------------------------------------------------------
# DO NOT REORDER without updating the spec R3 array order. Index positions
# map directly to the SHA-256-derived `idx` and to fixture-recorded
# expectations.
DEBATE_STRATEGIES=(verification-first falsification-first decompose)

# ---------------------------------------------------------------------------
# _sha256_hex — emit the 64-char lowercase SHA-256 hex digest.
# ---------------------------------------------------------------------------
# Usage:
#   printf '%s' "<input bytes>" | _sha256_hex            # reads stdin
#
# Input: bytes are read from stdin; this function does NOT accept a literal
# argument form. Pipe the bytes-to-hash via the Bourne `|` operator.
#
# Output: a single line, exactly 64 lowercase hex chars + newline. Strips
# the trailing `  -` filename suffix and any other whitespace that the
# underlying tool may emit.
#
# Selection: `shasum -a 256` preferred (macOS default + most Linux distros);
# `sha256sum` fallback (Linux coreutils default; absent on stock macOS).
# Hard-error when neither is on PATH; never silently fall back to a
# non-cryptographic primitive (per spec R3).
_sha256_hex() {
    local digest_line=""
    if command -v shasum >/dev/null 2>&1; then
        digest_line=$(shasum -a 256)
    elif command -v sha256sum >/dev/null 2>&1; then
        digest_line=$(sha256sum)
    else
        echo "error: neither shasum nor sha256sum available; cannot compute strategy assignment" >&2
        return 1
    fi
    # First 64 hex chars of stdout regardless of which tool ran. Both tools
    # emit `<64-hex>  -\n` on stdin input; we slice the first 64 chars to
    # ignore the trailing `  -` and any whitespace.
    printf '%s' "${digest_line:0:64}"
    printf '\n'
}

# ---------------------------------------------------------------------------
# compute_artifact_id — canonical hash input per review type.
# ---------------------------------------------------------------------------
# Usage:
#   compute_artifact_id <review_type> <args...>
#     review_type ∈ {plan, spec, code, epic-verify}
#     args:
#       plan|spec    → first arg is the user-passed file path
#       code         → first arg is the verbatim diff_args_str
#                      (e.g., "--uncommitted", "--base main",
#                       "--commit <sha>,<sha>", or a range like "main..feature")
#       epic-verify  → first arg is the file path OR raw-criteria string
#
# Output (stdout): the canonical artifact_id string.
#
# Errors: dies if a required argument is missing or the file does not exist
# (for plan/spec where the path is mandatory).
compute_artifact_id() {
    local review_type="${1:-}"
    shift || true
    local arg="${1:-}"
    case "$review_type" in
        plan|spec)
            if [[ -z "$arg" ]]; then
                echo "error: compute_artifact_id $review_type requires a path argument" >&2
                return 1
            fi
            # realpath. macOS lacks GNU coreutils' `realpath` by default but
            # ships `python3` with `os.path.realpath`. Prefer `realpath` when
            # available; fall back to `python3 -c`.
            _resolve_realpath "$arg"
            ;;
        code)
            # Verbatim diff_args_str (no normalization). Empty is allowed in
            # principle (e.g., a future "code review of HEAD" mode); the
            # caller is responsible for passing the same string used in
            # `<!-- diff-args: ... -->` artifact frontmatter.
            printf '%s' "$arg"
            ;;
        epic-verify)
            if [[ -z "$arg" ]]; then
                echo "error: compute_artifact_id epic-verify requires a path or raw-criteria argument" >&2
                return 1
            fi
            # File argument → realpath. Raw criteria → verbatim string.
            # The decision is whether the argument resolves to a regular
            # file under the current working directory or as an absolute
            # path. The same call from a different working directory must
            # produce the same artifact_id when the file argument resolves
            # to the same realpath.
            if [[ -f "$arg" ]]; then
                _resolve_realpath "$arg"
            else
                printf '%s' "$arg"
            fi
            ;;
        *)
            echo "error: compute_artifact_id: unknown review_type '$review_type' (expected: plan, spec, code, epic-verify)" >&2
            return 1
            ;;
    esac
}

# Internal: portable realpath. Prefers `realpath` when available; falls back
# to `python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))"`.
_resolve_realpath() {
    local p="$1"
    if command -v realpath >/dev/null 2>&1; then
        # `--` terminates option processing so paths starting with a hyphen
        # (e.g., `-h`) are not interpreted as flags.
        realpath -- "$p"
        return $?
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$p"
        return $?
    fi
    # Last-ditch fallback: cd + pwd. Only works for directory arguments or
    # files that exist; matches `realpath -e` semantics roughly. We prefer
    # to error out so the caller knows the artifact_id is not stable. Use
    # `cd --` to terminate option processing so paths starting with a
    # hyphen (e.g., `-h`) cannot be misinterpreted as cd flags.
    if [[ -d "$p" ]]; then
        ( cd -- "$p" && pwd -P )
    elif [[ -f "$p" ]]; then
        local d b
        d=$(dirname -- "$p")
        b=$(basename -- "$p")
        ( cd -- "$d" && printf '%s/%s\n' "$(pwd -P)" "$b" )
    else
        echo "error: cannot resolve realpath for '$p' (neither realpath nor python3 available, and path does not exist)" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# assign_strategies — per-(artifact, reviewer) strategy assignment.
# ---------------------------------------------------------------------------
# Usage:
#   assign_strategies <artifact_id> <reviewer1> [reviewer2 ...]
#
# Output (stdout): one line per reviewer in canonical alphabetical order,
# format:  `<reviewer> <strategy>`  (single space separator).
#
# Errors: hard-errors via `_sha256_hex` if neither shasum nor sha256sum is
# available on PATH. Empty reviewer list returns success with no output
# (defensive: a zero-reviewer debate is rejected upstream by the
# <2 reviewers preflight, so this branch is mostly for fixture-test sanity).
#
# Bash 3.2: parallel arrays — `reviewers_sorted[i]` and `assigned_idx[i]`.
# `used_slots[k]` is "1" iff strategy index `k` is already taken; tested
# with a string-membership check (no associative arrays).
assign_strategies() {
    local artifact_id="${1:-}"
    shift || true

    if [[ $# -eq 0 ]]; then
        return 0
    fi

    # Canonical alphabetical iteration. Sort the reviewer arguments via
    # `printf` + `sort`. Bash 3.2-compatible.
    local -a reviewers_sorted=()
    local r
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        reviewers_sorted+=("$r")
    done < <(printf '%s\n' "$@" | LC_ALL=C sort)

    local n_strategies=${#DEBATE_STRATEGIES[@]}
    # `used_slots[k]` is "1" iff strategy index `k` is already taken; init to "0".
    local -a used_slots=()
    local k=0
    while [[ $k -lt $n_strategies ]]; do
        used_slots+=("0")
        k=$((k + 1))
    done

    local i=0
    while [[ $i -lt ${#reviewers_sorted[@]} ]]; do
        local reviewer="${reviewers_sorted[i]}"
        local pref_idx
        pref_idx=$(_compute_pref_idx "$artifact_id" "$reviewer") || return 1

        # Walk: pref, pref+1 mod n, pref+2 mod n. First free slot wins.
        # If after `n_strategies` walk steps no free slot is found (only
        # possible when N > n_strategies), wrap and accept the original
        # preferred index — duplicate assignment is deterministic.
        local final_idx="$pref_idx"
        local off=0
        while [[ $off -lt $n_strategies ]]; do
            local cand=$(( (pref_idx + off) % n_strategies ))
            if [[ "${used_slots[cand]}" == "0" ]]; then
                final_idx=$cand
                break
            fi
            off=$((off + 1))
        done

        used_slots[final_idx]="1"
        printf '%s %s\n' "$reviewer" "${DEBATE_STRATEGIES[final_idx]}"
        i=$((i + 1))
    done
}

# Internal: compute the preferred strategy index for a (artifact_id, reviewer)
# pair. Output is a single integer in [0, len(DEBATE_STRATEGIES)).
_compute_pref_idx() {
    local artifact_id="$1"
    local reviewer="$2"
    local digest
    digest=$(printf '%s' "${artifact_id}:${reviewer}" | _sha256_hex) || return 1
    # First 8 hex chars → uint32 → mod len(strategies). Bash arithmetic
    # handles 32-bit unsigned values fine in 64-bit signed math.
    local first8="${digest:0:8}"
    local n_strategies=${#DEBATE_STRATEGIES[@]}
    printf '%s\n' "$(( 0x${first8} % n_strategies ))"
}

# ---------------------------------------------------------------------------
# resolve_strategy_path — locate the strategy directive .md file.
# ---------------------------------------------------------------------------
# Usage:
#   resolve_strategy_path <strategy-name>
#
# Output: the absolute path to `prompts/strategies/<strategy>.md`, resolved
# with project-local override support (mirrors substitute_debate_placeholders
# in bin/review-gate).
#
# Errors: dies if the file is not found at any of the search locations.
resolve_strategy_path() {
    local strategy_name="$1"
    if [[ -z "$strategy_name" ]]; then
        echo "error: resolve_strategy_path requires a strategy name" >&2
        return 1
    fi
    local project_root
    project_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    local _path
    for _path in "$project_root/prompts/strategies/${strategy_name}.md" \
                 "${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../prompts/strategies/${strategy_name}.md"; do
        if [[ -f "$_path" ]]; then
            printf '%s\n' "$_path"
            return 0
        fi
    done
    echo "error: strategy directive file not found: prompts/strategies/${strategy_name}.md" >&2
    return 1
}
