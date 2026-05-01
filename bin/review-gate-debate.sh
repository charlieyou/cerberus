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
#                                                   computes)
#                                     ask       → verbatim prompt content.
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
#     review_type ∈ {plan, spec, code, epic-verify, ask}
#     args:
#       plan|spec    → first arg is the user-passed file path
#       code         → first arg is the verbatim diff_args_str
#                      (e.g., "--uncommitted", "--base main",
#                       "--commit <sha>,<sha>", or a range like "main..feature")
#       epic-verify  → first arg is the file path OR raw-criteria string
#       ask          → first arg is the verbatim prompt content
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
        ask)
            if [[ -z "$arg" ]]; then
                echo "error: compute_artifact_id ask requires prompt content" >&2
                return 1
            fi
            printf '%s' "$arg"
            ;;
        *)
            echo "error: compute_artifact_id: unknown review_type '$review_type' (expected: plan, spec, code, epic-verify, ask)" >&2
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

# ---------------------------------------------------------------------------
# Internal helper: best-effort `rm -f` over the listed paths. Used by
# run_debate_coordinator's failure paths to clean up partially-staged temp
# files inside $reviews_dir before returning non-zero. The function is
# error-tolerant — a missing path or a permission failure is logged but does
# not propagate up the call stack (the caller is already in a failure path
# and the temp files have hidden `.staging.<pid>` names that will not be
# read by the Stop-hook).
_rdc_cleanup_temp_files() {
    local _f
    for _f in "$@"; do
        [[ -z "$_f" ]] && continue
        rm -f "$_f" 2>/dev/null || true
    done
}

# ---------------------------------------------------------------------------
# T007 — R1 anonymization helpers.
# ---------------------------------------------------------------------------
#
# These helpers implement the R1 anonymization pass:
#
#   1. DEBATE_DENYLIST_TERMS    — constant array of agent-identity tokens
#                                  scrubbed from rendered peer blocks.
#   2. debate_deny_list_scrub   — apply the canonical pinned POSIX ERE
#                                  iterative substitution loop to stdin.
#   3. debate_assign_peer_ids   — assign opaque per-run IDs (Peer-A ...).
#   4. debate_peer_order_seeded — deterministic per-recipient ordering
#                                  under `--debate-seed N` (D11 algorithm).
#   5. debate_peer_order_random — non-deterministic per-recipient ordering
#                                  for the production path (no seed).
#   6. debate_render_active_peer    — render the R1 active-peer skeleton
#                                      with deny-list redactions on
#                                      title/body.
#   7. debate_render_abstained_peer — render the R1 abstained-peer skeleton.
#
# Phase E scope (T007): provide the helpers and wire fixtures + tests. The
# Round-2 prompt construction that consumes `${PEER_BLOCK}` lives in T008.
# Bash 3.2 / BSD + GNU sed compatible throughout — no associative arrays,
# no GNU-only sed extensions, no `\<` / `\>` / `[[:<:]]` boundary forms.
#
# DEBATE_DENYLIST_TERMS — canonical v1 deny-list (spec R1).
#
# Configurable via shell variable: tests and downstream callers MAY reassign
# this array before invoking debate_deny_list_scrub to exercise edge cases.
# The default v1 contents cover the agent-identity tokens that v1 reviewers
# might emit (model brand names, vendor names, generic reviewer/agent
# placeholders). Extending the deny-list is a code-change + spec-note path,
# not a runtime-flag path, so additions land alongside the matching test
# fixtures.
DEBATE_DENYLIST_TERMS=(
    "Claude"
    "Codex"
    "Gemini"
    "GPT"
    "Anthropic"
    "OpenAI"
    "Google"
    "Reviewer 1"
    "Reviewer 2"
    "Reviewer 3"
    "Agent 1"
    "Agent 2"
    "Agent 3"
)

# _debate_denylist_alternation — emit the `term1|term2|...` alternation
# string used inside the canonical pinned regex form. Internal helper.
# v1 deny-list contains no regex metacharacters, so terms are inserted
# verbatim. Future deny-list additions that require regex escaping MUST
# update this helper to escape per-term.
_debate_denylist_alternation() {
    local first=1 term out=""
    for term in "${DEBATE_DENYLIST_TERMS[@]}"; do
        if [[ $first -eq 1 ]]; then
            out="$term"
            first=0
        else
            out="$out|$term"
        fi
    done
    printf '%s' "$out"
}

# debate_deny_list_scrub — apply the canonical R1 deny-list scrub to stdin.
#
# Pinned canonical form (spec R1 + plan Implementation Constraints L67-L68):
#
#   sed -E "s/(^|[^A-Za-z0-9_])(<term1>|<term2>|...)($|[^A-Za-z0-9_])/\1[REDACTED]\3/gi"
#
# applied iteratively in a do-while shell loop until the buffer is
# idempotent. The canonical pattern's negated character classes consume
# one boundary character on each side, so a single non-iterative pass
# over `Claude Codex` redacts only `Claude`: the first match consumes
# the shared space as its trailing boundary, leaving `Codex` with no
# preceding non-word character available for the next match in the same
# pass. Iterating until no further substitution occurs handles adjacent
# deny-list terms (`Claude Codex Gemini` redacts all three after at most
# two iterations) without resorting to BSD-only `:a; ...; ta` label form.
#
# Capture-group numbering: the alternation `(^|[^A-Za-z0-9_])(<terms>)($|[^A-Za-z0-9_])`
# captures the leading boundary as `\1`, the matched term as `\2`, and
# the trailing boundary as `\3`. The replacement re-emits `\1` and `\3`
# so the now-adjacent next-term boundary is preserved for the next pass.
#
# Reads stdin, writes scrubbed output to stdout. Trailing newlines in the
# input are preserved verbatim via a sentinel byte: command substitution
# strips trailing newlines, so we append `.` before each substitution and
# strip it via parameter expansion after. The sentinel `.` is a non-word
# character, so it serves as a valid trailing boundary for any deny-list
# term that happens to end the buffer without its own trailing
# whitespace — and that's the *correct* semantics under spec R1 because
# end-of-buffer is a word boundary equivalent to end-of-line.
#
# Bash 3.2 + BSD/GNU sed compatible. The `-E` (ERE) and `gi` flags are
# the portable subset accepted by both implementations. macOS BSD sed
# and Linux GNU sed both preserve the trailing-LF count of the input
# in their output (verified by direct test), so the sentinel-protected
# round trip yields byte-identical output bytes on both platforms.
debate_deny_list_scrub() {
    local cur next alt
    alt=$(_debate_denylist_alternation)
    # Sentinel-protected read: append `.` before command substitution
    # strips trailing newlines, then strip the sentinel.
    cur=$(cat; printf '.')
    cur="${cur%.}"
    while :; do
        next=$(printf '%s' "$cur" | sed -E "s/(^|[^A-Za-z0-9_])(${alt})(\$|[^A-Za-z0-9_])/\1[REDACTED]\3/gi"; printf '.')
        next="${next%.}"
        if [[ "$next" == "$cur" ]]; then
            break
        fi
        cur=$next
    done
    printf '%s' "$cur"
}

# debate_assign_peer_ids — assign opaque per-run peer IDs (Peer-A,
# Peer-B, ...) to canonical reviewer names.
#
# Args (positional): canonical reviewer names (e.g., claude codex gemini).
# Output (stdout): one line per reviewer in canonical alphabetical order,
#   format `<reviewer> Peer-<X>`, where `<X>` is `A`, `B`, `C`, ...
#
# The mapping is intentionally derivable from the (sorted) reviewer set
# alone, so callers can re-run this function in subsequent rounds and
# obtain the same mapping without persisting it. Stable across all rounds
# within one debate run; reset between runs (callers should pass the
# active set as of the *first* round so abstainers in later rounds keep
# their original opaque ID — the terminal-abstention rule means an
# abstainer in round k is presented as `(peer abstained)` in round k+1
# under the *same* opaque ID it had in round 1).
#
# v1 supports up to 3 active reviewers, so the 26-letter cap is purely
# defensive against fixture misuse. Empty reviewer list → empty output,
# exit 0.
debate_assign_peer_ids() {
    local -a sorted=()
    local r
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        sorted+=("$r")
    done < <(printf '%s\n' "$@" | LC_ALL=C sort)

    if [[ ${#sorted[@]} -eq 0 ]]; then
        return 0
    fi
    if [[ ${#sorted[@]} -gt 26 ]]; then
        echo "debate_assign_peer_ids: more than 26 reviewers passed (${#sorted[@]}); not supported in v1" >&2
        return 1
    fi

    local letters="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    local i=0
    while [[ $i -lt ${#sorted[@]} ]]; do
        printf '%s Peer-%s\n' "${sorted[i]}" "${letters:$i:1}"
        i=$((i + 1))
    done
}

# debate_peer_order_seeded — compute the deterministic per-recipient peer
# ordering under `--debate-seed N` per spec R1 / D11.
#
# Algorithm:
#   For each peer P in the recipient's peer set (excluding the recipient
#   itself), compute K(R, P) = sha256("<seed>:<R>:<P>") where:
#     <seed>  is the integer N rendered as its decimal string
#     <R>     is the recipient's canonical reviewer name (claude/codex/gemini)
#     <P>     is the peer's opaque per-run ID (Peer-A, Peer-B, ...)
#     `:`     is literal ASCII 0x3A
#   Sort peers ascending by K(R, P) rendered as the lowercase 64-char hex
#   digest, using lexicographic byte-order over the hex string. Tiebreak
#   (effectively unreachable with SHA-256) by peer-opaque-ID lex ascending.
#
# Args:
#   $1   seed (integer rendered as decimal string)
#   $2   recipient canonical reviewer name
#   $3+  peer opaque IDs to order
#
# Output (stdout): peer opaque IDs one per line, in computed order.
#
# Cross-platform byte-stable: SHA-256 is deterministic, sort uses
# `LC_ALL=C` byte-order; macOS BSD `shasum` and Linux GNU `sha256sum`
# emit identical digests for the same input.
debate_peer_order_seeded() {
    local seed="$1"; shift
    local recipient="$1"; shift
    if [[ $# -eq 0 ]]; then
        return 0
    fi
    local p key
    {
        for p in "$@"; do
            key=$(printf '%s' "${seed}:${recipient}:${p}" | _sha256_hex) || return 1
            # Tab separates key from peer-ID so awk -F'\t' can recover the
            # peer-ID after sort. SHA-256 hex digits never contain TAB, and
            # the peer-ID values (Peer-A, Peer-B, ...) never contain TAB,
            # so the separator is unambiguous.
            printf '%s\t%s\n' "$key" "$p"
        done
    } | LC_ALL=C sort | awk -F'\t' '{print $2}'
}

# debate_peer_order_random — compute a non-deterministic per-recipient
# peer ordering for the production path (no `--debate-seed`).
#
# Args: peer opaque IDs to shuffle.
# Output (stdout): peer opaque IDs one per line, in shuffled order.
#
# RNG source contract (spec R1 production-path shuffle):
#   - Prefer 4 bytes from `/dev/urandom` rendered as a uint32 decimal.
#   - Fall back to `$RANDOM * 32768 + $RANDOM` (Bash 3.2 builtin; 30-bit
#     entropy) when `/dev/urandom` is unreadable.
#   - MUST NOT cross-derive from any byte-parity-protected input
#     (artifact_id, reviewer canonical name, peer opaque ID, seed value,
#     etc.). The function takes peer-ID args only — it does not consult
#     the recipient name or any other contextual identifier — so the
#     output is governed purely by the RNG.
#
# Two production runs over the same artifact MUST produce different
# orderings with high probability (the test asserts this statistically
# across N=20+ runs).
debate_peer_order_random() {
    if [[ $# -eq 0 ]]; then
        return 0
    fi
    local p key
    {
        for p in "$@"; do
            # IMPORTANT: reset `key` at the top of each iteration. If we
            # leave the previous iteration's value in place, the
            # `[[ -z "${key:-}" ]]` guard short-circuits the $RANDOM
            # fallback on every subsequent peer when `/dev/urandom` is
            # unreadable, producing identical sort keys and a
            # non-shuffled (alphabetical) ordering. Resetting here
            # guarantees each peer's RNG draw is independent.
            key=""
            if [[ -r /dev/urandom ]]; then
                # `od -An -N4 -tu4` emits a uint32 decimal in [0, 2^32).
                # `tr -d ' \n'` strips od's leading-padding spaces and the
                # trailing newline, leaving a bare decimal digit run.
                key=$(od -An -N4 -tu4 < /dev/urandom 2>/dev/null | tr -d ' \n')
            fi
            if [[ -z "${key:-}" ]]; then
                # Fallback: combine two $RANDOM draws for ~30 bits of
                # entropy. Bash 3.2 $RANDOM is 15-bit unsigned.
                key=$(( ${RANDOM:-0} * 32768 + ${RANDOM:-0} ))
            fi
            printf '%s\t%s\n' "$key" "$p"
        done
    } | LC_ALL=C sort -k1,1n | awk -F'\t' '{print $2}'
}

# debate_render_active_peer — render the R1 active-peer skeleton for one
# peer, with deny-list redactions applied to titles and bodies.
#
# Args:
#   $1  peer opaque ID (e.g., "Peer-A")
#   $2  peer JSON (string), expected fields:
#         .verdict             — PASS | FAIL | NEEDS_WORK
#         .overall_confidence  — number in [0, 1]
#         .findings            — array of {title, body, ...}
#
# Output (stdout): the rendered active-peer skeleton text per spec R1:
#
#   **Peer-X**
#   Verdict: <V>
#   Overall confidence: <C>
#
#   Findings:
#   - **<title>**
#     <body>
#   - **<title>**
#     <body>
#
# When `findings` is empty: the entire `Findings:` block collapses to the
# single literal line `Findings: (none)` (no list items, no trailing blank
# line).
#
# Per-finding `confidence` and per-peer `summary` are excluded from the
# rendered shape; they remain in the underlying JSON for telemetry but
# are not exposed to the next-round reviewer.
debate_render_active_peer() {
    local peer_id="$1"
    local peer_json="$2"
    local verdict overall_conf findings_count i title body s_title s_body

    verdict=$(printf '%s' "$peer_json" | jq -r '.verdict // ""')
    overall_conf=$(printf '%s' "$peer_json" | jq -r '(.overall_confidence // 0.5) | tostring')
    findings_count=$(printf '%s' "$peer_json" | jq -r '(.findings // []) | length')

    printf '**%s**\n' "$peer_id"
    printf 'Verdict: %s\n' "$verdict"
    printf 'Overall confidence: %s\n' "$overall_conf"
    printf '\n'

    if [[ "$findings_count" == "0" ]]; then
        printf 'Findings: (none)\n'
        return 0
    fi

    printf 'Findings:\n'
    i=0
    while [[ $i -lt $findings_count ]]; do
        title=$(printf '%s' "$peer_json" | jq -r --argjson i "$i" '.findings[$i].title // ""')
        body=$(printf '%s' "$peer_json" | jq -r --argjson i "$i" '.findings[$i].body // ""')
        s_title=$(printf '%s' "$title" | debate_deny_list_scrub)
        # `- **<title>**` on its own line.
        printf -- '- **%s**\n' "$s_title"
        if [[ -n "$body" ]]; then
            s_body=$(printf '%s' "$body" | debate_deny_list_scrub)
            # Indent each body line two spaces. `printf '%s\n'` adds the
            # terminating LF; sed prepends `  ` to every line. A multi-line
            # body keeps the two-space indent on every continuation line.
            printf '%s\n' "$s_body" | sed 's/^/  /'
        fi
        i=$((i + 1))
    done
}

# debate_render_abstained_peer — render the R1 abstained-peer skeleton.
#
# Args:
#   $1  peer opaque ID
#
# Output (stdout): exactly two lines:
#   **Peer-X**
#   (peer abstained)
#
# The literal string `(peer abstained)` is the entire body of the peer's
# entry; no findings list, no verdict, no overall_confidence are rendered.
# The rendered string contains no model name, which is what makes R1's
# deny-list trivially apply over the placeholder.
debate_render_abstained_peer() {
    local peer_id="$1"
    printf '**%s**\n(peer abstained)\n' "$peer_id"
}

# debate_build_peer_blocks — Round-1 outputs → rendered per-recipient peer
# blocks; populates the values that bin/review-gate's `${PEER_BLOCK}`
# substitution (T004) consumes for the next-round prompt construction
# (T008 wires the actual Round-2 launch).
#
# Args:
#   $1  staging_dir   — per-round staging directory; peer-block files are
#                       written here as `peer-block.<recipient>.txt`.
#   $2  reviews_dir   — canonical reviews dir holding promoted Round-1
#                       per-reviewer JSONs (the input to peer rendering).
#   $3  debate_seed   — decimal seed string under `--debate-seed N`, or
#                       empty for the production-path shuffle.
#   $4+ active reviewers (canonical names; the function alphabetizes via
#       `debate_assign_peer_ids`).
#
# Side effects:
#   - Writes `$staging_dir/peer-block.<recipient>.txt` for each recipient,
#     containing the rendered anonymized peer block presented to that
#     recipient under the recipient's per-recipient peer ordering.
#   - Exports `PEER_BLOCK_<UPPER_RECIPIENT>` env vars holding the same
#     rendered text. T008 may consume either surface; files are the more
#     durable handoff because env-var values do not survive subshell
#     boundaries cleanly when the value contains LFs.
#
# Phase E.1 scope (T007): Round-1 output → active-peer skeleton only.
# Mode A abstain handling (Round-1 reviewer wrote `.failed` sentinel or
# the augmented JSON is missing) renders the abstained-peer skeleton via
# `debate_render_abstained_peer`. T008 extends Mode A handling for
# subsequent rounds (terminal-abstention rule across rounds).
#
# Returns 0 on success; non-zero if a per-reviewer JSON cannot be read or
# the renderer hard-errors. Failure is non-fatal at the call site (Phase D
# does not actually launch Round 2 yet); the caller logs the warning and
# proceeds.
debate_build_peer_blocks() {
    local staging_dir="$1"; shift
    local reviews_dir="$1"; shift
    local debate_seed="$1"; shift
    if [[ $# -lt 2 ]]; then
        # No peer block to render with fewer than 2 reviewers (the
        # <2-reviewers preflight upstream already hard-errors before we
        # get here; this is defensive).
        return 0
    fi
    local -a active=("$@")

    # 1. Assign opaque peer IDs (Peer-A, Peer-B, ...) in canonical
    #    alphabetical reviewer order. Stable across rounds within one
    #    debate run so the receiving reviewer sees the same Peer-X label
    #    for the same model in every round.
    local _bpb_peer_id_lines
    _bpb_peer_id_lines=$(debate_assign_peer_ids "${active[@]}") || return 1

    # Parallel arrays keyed by canonical reviewer name.
    local -a _bpb_revs=() _bpb_pids=()
    local _line _rev _pid
    while IFS= read -r _line; do
        [[ -z "$_line" ]] && continue
        # Format: `<reviewer> Peer-X` (single space).
        _rev="${_line%% *}"
        _pid="${_line##* }"
        _bpb_revs+=("$_rev")
        _bpb_pids+=("$_pid")
    done <<< "$_bpb_peer_id_lines"

    # 2. For each recipient, compute peer ordering + render peer entries.
    local recipient peer_id
    for recipient in "${active[@]}"; do
        # Find recipient's peer ID and the peer set (everyone else).
        local recipient_pid="" idx=0
        local -a peer_ids=()
        while [[ $idx -lt ${#_bpb_revs[@]} ]]; do
            if [[ "${_bpb_revs[$idx]}" == "$recipient" ]]; then
                recipient_pid="${_bpb_pids[$idx]}"
            else
                peer_ids+=("${_bpb_pids[$idx]}")
            fi
            idx=$((idx + 1))
        done

        if [[ ${#peer_ids[@]} -eq 0 ]]; then
            # Single-reviewer debate would've been rejected upstream; bail.
            continue
        fi

        # Compute per-recipient ordering (seeded vs. production).
        local ordered
        if [[ -n "$debate_seed" ]]; then
            ordered=$(debate_peer_order_seeded "$debate_seed" "$recipient" "${peer_ids[@]}") || return 1
        else
            ordered=$(debate_peer_order_random "${peer_ids[@]}") || return 1
        fi

        # Render each peer entry. Active vs. abstained is determined by
        # whether the augmented per-reviewer JSON is present at the
        # canonical $reviews_dir/<reviewer>.json location (presence ⇒
        # active; absence ⇒ abstained). Phase D promotes only active
        # reviewers, so the abstained branch is reached only via T008's
        # Mode A integration.
        local block="" rendered peer_id pj
        local peer_rev pp jdx
        while IFS= read -r peer_id; do
            [[ -z "$peer_id" ]] && continue
            # Map peer_id back to its canonical reviewer.
            peer_rev=""
            jdx=0
            while [[ $jdx -lt ${#_bpb_pids[@]} ]]; do
                if [[ "${_bpb_pids[$jdx]}" == "$peer_id" ]]; then
                    peer_rev="${_bpb_revs[$jdx]}"
                    break
                fi
                jdx=$((jdx + 1))
            done

            local peer_json_path="$reviews_dir/${peer_rev}.json"
            if [[ -s "$peer_json_path" ]]; then
                pj=$(cat "$peer_json_path")
                rendered=$(debate_render_active_peer "$peer_id" "$pj") || return 1
            else
                # Mode A abstain placeholder. T007 ships the renderer; T008
                # wires the upstream signal that decides which branch to
                # take. With Phase D's hard-error-on-failed-sentinel
                # contract, this branch is effectively unreachable in
                # Phase D but is correct under T008.
                rendered=$(debate_render_abstained_peer "$peer_id") || return 1
            fi

            if [[ -z "$block" ]]; then
                block="$rendered"
            else
                # Blank-line separator between peer entries: one LF closes
                # the previous entry's last content line, one blank LF
                # separates entries visually. Per spec R1 the inter-entry
                # glue is implementation-defined; the active/abstained
                # skeletons themselves are byte-pinned.
                block="${block}

${rendered}"
            fi
        done <<< "$ordered"

        # 3. Write to file + export env var. Both surfaces let T008 pick
        #    the most convenient handoff for its Round-2 prompt path.
        local recipient_upper
        recipient_upper=$(echo "$recipient" | tr '[:lower:]' '[:upper:]')
        printf '%s\n' "$block" > "$staging_dir/peer-block.${recipient}.txt"
        export "PEER_BLOCK_${recipient_upper}=$block"

        # 4. Persist the coordinator-populated ordered peer ID list (one ID
        #    per line) for this recipient. `_rdc_classify_round_outputs` reads
        #    this file when augmenting the reviewer's JSON so it can stamp the
        #    authoritative `peer_responses_seen` value — the coordinator's
        #    input contract — rather than relying on any reviewer self-report.
        #    Including abstained-peer slot IDs satisfies R9.5 / AC-R1.7: the
        #    array must reflect every slot the coordinator presented, not just
        #    the slots of active peers.
        printf '%s\n' "$ordered" > "$staging_dir/peer-ids.${recipient}.txt"
    done

    return 0
}

# ---------------------------------------------------------------------------
# T008 — Round 2 + terminal-abstention + Option B + degraded-below-2 helpers.
# ---------------------------------------------------------------------------

# _rdc_wait_round_sentinels — sync-wait for `.done`/`.failed` sentinels under
# a staging directory. Mirrors the polling pattern used elsewhere by the
# Stop-hook + Phase D round-1 wait loop.
#
# Args:
#   $1   staging_dir
#   $2   timeout_sec       integer; budget the wait abandons after.
#   $3   poll_interval     integer >=1; seconds between polls.
#   $@   (4+) reviewer canonical names — every name MUST eventually have a
#         `.done` or `.failed` file under $staging_dir for the wait to
#         return success.
#
# Returns 0 if every reviewer's sentinel appears before the timeout; 1 on
# timeout. Stderr remains silent on success; the caller decides how to
# surface a timeout (e.g., "timeout waiting for round-N sentinels").
_rdc_wait_round_sentinels() {
    local staging_dir="$1"; shift
    local timeout_sec="$1"; shift
    local poll_interval="$1"; shift
    local -a reviewers=("$@")

    if [[ ${#reviewers[@]} -eq 0 ]]; then
        return 0
    fi

    local start_time now elapsed r
    start_time=$(date +%s)
    while true; do
        local all_done="true"
        for r in "${reviewers[@]}"; do
            if [[ ! -f "$staging_dir/${r}.done" ]] && \
               [[ ! -f "$staging_dir/${r}.failed" ]]; then
                all_done="false"
                break
            fi
        done
        if [[ "$all_done" == "true" ]]; then
            return 0
        fi
        now=$(date +%s)
        elapsed=$(( now - start_time ))
        if [[ $elapsed -ge $timeout_sec ]]; then
            return 1
        fi
        # T012 cancellation: SIGINT does NOT short-circuit this wait
        # loop. The spec says cancel "lets in-flight reviewers complete
        # or hit per-reviewer timeout" — i.e., the in-flight round runs
        # to its natural end (all sentinels OR round-budget timeout)
        # before the cancel takes effect. Reviewers spawn detached
        # (`nohup`/`setsid`); SIGINT to the parent does NOT kill them.
        # Short-circuiting here would mark a reviewer that finishes
        # seconds later as abstained in partial telemetry, which would
        # contradict the actual on-disk reviewer output. The cancel
        # checkpoint after `_rdc_record_round` (`_rdc_check_cancel_after_round`)
        # exits 130 with telemetry that reflects the round's true
        # outcome.
        sleep "$poll_interval"
    done
}

# _rdc_classify_round_outputs — for each reviewer's per-round output under
# $staging_dir, determine Mode A (abstain) vs. parseable-and-active (Mode B
# confidence defaults applied transparently below).
#
# Mode A (abstain) triggers (per spec R2 / Section 2):
#   - `<reviewer>.failed` sentinel present
#   - `<reviewer>.json` missing or empty
#   - JSON unparseable (extract_json fails after repair fallback)
#   - Parseable JSON missing the `findings` field (the array itself absent —
#     `findings: []` is valid Mode B output and counts as active)
#   - Parseable JSON missing `verdict` (or with empty/non-string verdict)
#   - Verdict not in {PASS, FAIL, NEEDS_WORK}
#
# Mode B (parseable, active) handling:
#   - Missing `overall_confidence` → 0.5
#   - Per-finding `confidence` missing → 0.5
#   - Out-of-range values clamped to [0, 1]
#   - Reviewer remains active; findings count toward final aggregation.
#
# Side effects:
#   - For active reviewers, writes augmented JSON (Mode B defaults applied,
#     no other modifications) to `$staging_dir/<reviewer>.augmented.json`.
#     The augmented JSON is what the final aggregator reads when promoting
#     the per-reviewer JSON to $REVIEWS_DIR.
#   - For abstained reviewers, no augmented JSON is written.
#
# Output (stdout): one line per reviewer in input order:
#   `<reviewer> active`     — reviewer is non-abstained, augmented JSON staged.
#   `<reviewer> abstained`  — reviewer abstained for this round (Mode A).
#
# Returns 0 unconditionally; failure to classify a single reviewer is recorded
# as `abstained` rather than propagated as a function-level error (the
# coordinator decides whether the resulting active count satisfies the
# eligibility threshold).
_rdc_classify_round_outputs() {
    local staging_dir="$1"; shift
    local r out_file done_file failed_file parsed verdict augmented aug_path guard integrity

    for r in "$@"; do
        out_file="$staging_dir/${r}.json"
        done_file="$staging_dir/${r}.done"
        failed_file="$staging_dir/${r}.failed"
        parsed=""
        local parsed_failed_output="false"

        if [[ -f "$failed_file" && -s "$out_file" ]]; then
            if parsed=$(extract_valid_review_json_no_repair "$out_file" "$r" 2>/dev/null); then
                parsed_failed_output="true"
            fi
        fi

        if [[ -f "$failed_file" && "$parsed_failed_output" != "true" ]]; then
            printf '%s abstained\n' "$r"
            continue
        fi
        # Per-reviewer timeout detection (Mode A). A reviewer that never
        # wrote a `.done` (and is not in the `.failed` branch above) means
        # the wait-for-sentinels loop hit its budget while this reviewer
        # was still in flight. This also covers the corner case where the
        # reviewer's CLI wrote a complete `<reviewer>.json` and then hung
        # before its wrapper could `touch $REVIEW_DONE` — we MUST classify
        # that reviewer as Mode A timeout abstain rather than `active`,
        # otherwise a hung reviewer's stale Round-1 JSON would carry into
        # Round 2 / final aggregation. Distinct from the `.failed` branch
        # (which is Mode A crash) and from the missing-JSON branch below
        # (which catches reviewers that died before writing any output);
        # the existence of a `.done` sentinel is the canonical proof that
        # the spawn wrapper observed the reviewer's exit-zero condition.
        if [[ ! -f "$done_file" && "$parsed_failed_output" != "true" ]]; then
            echo "warning: Mode A timeout abstain for reviewer $r — no .done sentinel observed (spawn either hung or never completed)" >&2
            printf '%s abstained\n' "$r"
            continue
        fi
        if [[ ! -s "$out_file" ]]; then
            printf '%s abstained\n' "$r"
            continue
        fi
        if [[ "$parsed_failed_output" != "true" ]] && \
           ! parsed=$(extract_json "$out_file" "$r" 2>/dev/null); then
            printf '%s abstained\n' "$r"
            continue
        fi

        # Mode A boundary: missing findings array OR missing/empty verdict
        # OR verdict not in the allowed set ⇒ abstain entirely. `findings: []`
        # (empty array) IS valid Mode B output and falls through to the
        # active-augmentation step.
        guard=$(printf '%s' "$parsed" | jq -r '
            if (has("findings") and (.findings | type == "array"))
                and (has("verdict") and (.verdict | type == "string") and (.verdict != "")) then
                "ok"
            else
                "abstain"
            end' 2>/dev/null || echo "abstain")
        if [[ "$guard" != "ok" ]]; then
            printf '%s abstained\n' "$r"
            continue
        fi

        verdict=$(printf '%s' "$parsed" | jq -r '.verdict // ""' 2>/dev/null)
        case "$verdict" in
            PASS|FAIL|NEEDS_WORK) ;;
            *)
                printf '%s abstained\n' "$r"
                continue
                ;;
        esac

        # Mode B integrity check (per spec R2 alternate flow): emit a
        # stderr warning whenever the reviewer's parseable JSON is missing
        # or has out-of-range overall_confidence OR per-finding confidence,
        # so operators / fixture tests can audit Mode B activations. The
        # warning fires before the augmentation jq pass below applies the
        # 0.5 default + [0,1] clamp; the reviewer remains active either way.
        integrity=$(printf '%s' "$parsed" | jq -r '
            def numok: (type == "number") and (. >= 0) and (. <= 1);
            (if has("overall_confidence") then (.overall_confidence | numok) else false end) as $oc_ok
            | ((.findings // []) | all(if has("confidence") then (.confidence | numok) else false end)) as $f_ok
            | if $oc_ok and $f_ok then "ok" else "warn" end
        ' 2>/dev/null || echo "warn")
        if [[ "$integrity" != "ok" ]]; then
            echo "warning: Mode B confidence defaults applied for reviewer $r — overall_confidence and/or per-finding confidence missing or outside [0, 1]; defaulting to 0.5 / clamping to range. Reviewer remains active." >&2
            # Write a side file so the aggregator (which runs after this
            # process-substitution subshell exits) can pick up the clamp note
            # and append it to _RDC_AGGREGATOR_NOTES_JSON. The file contains
            # the canonical note string, one per line. Multiple Mode B
            # activations for the same reviewer in the same round append
            # additional lines, but in practice the integrity check fires once
            # per reviewer per round.
            printf 'reviewer %s clamped out-of-range confidence\n' "$r" \
                >> "${staging_dir}/${r}.clamp-note.txt" 2>/dev/null || true
        fi

        # Mode B confidence defaulting + clamping. Missing per-finding
        # `confidence` defaults to 0.5; missing `overall_confidence` defaults
        # to 0.5; values outside [0, 1] clamp at the boundary. Other fields
        # (priority, file_path, line ranges, title, body, etc.) pass through
        # unchanged so the augmented JSON remains a strict superset of the
        # parsed output for downstream consumers.
        augmented=$(printf '%s' "$parsed" | jq '
            (.overall_confidence
                | if (type == "number") then
                    if . < 0 then 0 elif . > 1 then 1 else . end
                  else 0.5 end) as $oc
            | (.findings | map(. + {
                confidence: (
                    .confidence
                    | if (type == "number") then
                        if . < 0 then 0 elif . > 1 then 1 else . end
                      else 0.5 end)
              })) as $f
            | .overall_confidence = $oc
            | .findings = $f
        ' 2>/dev/null)
        if [[ -z "$augmented" ]]; then
            printf '%s abstained\n' "$r"
            continue
        fi

        # Coordinator-populated peer_responses_seen: stamp the authoritative
        # value from `peer-ids.<reviewer>.txt` written by
        # `debate_build_peer_blocks` when this round's peer block was
        # constructed. This overrides any reviewer self-report, which is
        # required by spec R9 (the field is a coordinator input contract,
        # not a reviewer self-report claim).
        #
        # Round 1: no `peer-ids.<reviewer>.txt` exists (no peer block was
        # presented) → stamp `peer_responses_seen: []`.
        # Rounds 2/3: the file lists every opaque peer slot ID (including
        # abstained-peer slot IDs) that the coordinator placed in the
        # reviewer's anonymized peer block for this round.
        local _peer_ids_file="$staging_dir/peer-ids.${r}.txt"
        local _prs_json="[]"
        if [[ -s "$_peer_ids_file" ]]; then
            # Build a jq-compatible JSON array from the one-ID-per-line file.
            # Use jq's @json with --raw-input / --slurp so special characters
            # in ID strings are safely escaped (IDs are Peer-A/Peer-B/...
            # in practice, but this is defensive).
            _prs_json=$(grep -v '^$' "$_peer_ids_file" \
                | jq -R . | jq -s . 2>/dev/null || echo "[]")
            [[ -z "$_prs_json" ]] && _prs_json="[]"
        fi
        augmented=$(printf '%s' "$augmented" | jq \
            --argjson prs "$_prs_json" \
            '.peer_responses_seen = $prs' 2>/dev/null)
        if [[ -z "$augmented" ]]; then
            printf '%s abstained\n' "$r"
            continue
        fi

        aug_path="$staging_dir/${r}.augmented.json"
        if ! printf '%s\n' "$augmented" > "$aug_path"; then
            printf '%s abstained\n' "$r"
            continue
        fi
        printf '%s active\n' "$r"
    done
}

# _rdc_render_prior_round_self_block — render reviewer R's prior-round
# verdict + per-finding confidence + overall confidence as a clearly-labelled
# self-block for inclusion in the next-round prompt.
#
# Args:
#   $1  reviewer JSON (string) — typically the augmented-JSON form (Mode B
#       defaults applied) so the rendered self-block reflects the same
#       `confidence` values the aggregator will see.
#
# Output (stdout): markdown text. NOT scrubbed by R1's deny-list (this is
# R's own labelled output presented back to itself for self-comparison; the
# spec is explicit that the self-block is exempt from anonymization).
#
# Empty findings render as the single line `Findings: (none)` (mirrors the
# active-peer skeleton's empty-findings collapse rule for visual symmetry).
_rdc_render_prior_round_self_block() {
    local rj="$1"
    # Render the entire self-block via a single jq invocation. For reviews
    # with N findings the prior implementation did 3*N + 3 jq calls (one
    # per field per finding, plus three top-level field reads); collapsing
    # to one call eliminates fork+exec overhead and the per-jq JSON parse
    # cost. The jq program below mirrors the same shape:
    #
    #   Verdict: <verdict>
    #   Overall confidence: <overall_confidence — 0.5 default, clamped>
    #
    #   Findings: (none)             [empty findings collapse]
    # OR
    #   Findings:
    #   - **<title>** (confidence: <c>)
    #     <body>                    [body indented two spaces per line]
    #   ...
    #
    # Mode B confidence defaults (missing → 0.5, out-of-range → clamp to
    # [0, 1]) are applied both to overall_confidence and per-finding
    # confidence here. The body indentation uses jq's `split("\n")` +
    # `map("  " + .)` + `join("\n")` so multi-line bodies get the two-
    # space indent on every continuation line.
    printf '%s' "$rj" | jq -r '
        def numclamp:
            if (type == "number") then
                if . < 0 then 0 elif . > 1 then 1 else . end
            else 0.5 end;
        def render_body($b):
            ($b | split("\n") | map("  " + .) | join("\n"));

        (.verdict // "") as $verdict
        | (.overall_confidence | numclamp) as $oc
        | (.findings // []) as $findings
        |
        "Verdict: " + $verdict + "\n"
        + "Overall confidence: " + ($oc | tostring) + "\n"
        + "\n"
        + (if ($findings | length) == 0 then
              "Findings: (none)"
          else
              "Findings:\n"
              + (
                  $findings
                  | map(
                      "- **" + (.title // "") + "** (confidence: "
                      + ((.confidence | numclamp) | tostring) + ")"
                      + (if (.body // "") == "" then ""
                         else "\n" + render_body(.body // "")
                         end)
                  )
                  | join("\n")
              )
          end)
    ' 2>/dev/null
}

# _rdc_build_round2_prompt — build reviewer R's Round-2 prompt by inserting
# the Round-2 directive + R's prior-round-self block + R's per-recipient
# anonymized peer block immediately BEFORE the rendered Round-1 prompt's
# `## Output Format` section. The Round-1 prompt's intro/artifact/criteria
# (with strategy + confidence anchors already inlined per T004/T005) and
# the trailing `## Output Format` block are preserved verbatim; the new
# Round-2 sections sit between the criteria and the output-format
# instructions so the reviewer reads:
#
#   1. Intro + artifact + Round-1 criteria (with confidence anchors +
#      strategy directive — already substituted at Round-1 render time).
#   2. ## Round 2 of debate-mode review — the confidence-conditioned-update
#      directive.
#   3. ### Your Round 1 output: — R's own Round-1 verdict + findings (with
#      per-finding confidence) + overall_confidence rendered via
#      `_rdc_render_prior_round_self_block`. NOT scrubbed by R1's deny-list
#      per spec R2 (it's R's own labelled output back to itself).
#   4. ### Anonymized peer outputs: — the per-recipient anonymized peer
#      block built by `debate_build_peer_blocks` (T007), with deny-list
#      scrub + per-recipient ordering already applied.
#   5. ## Output Format — the existing JSON-only directive (unchanged from
#      Round 1; the reviewer's emit format is the same).
#
# Inserting BEFORE `## Output Format` (rather than appending at the end of
# the prompt) keeps the JSON-only output instructions as the last thing
# the reviewer sees — appending the new sections after `## Output Format`
# would push the output-format directive away from the bottom and risk
# degrading model adherence to the JSON-only contract.
#
# Args:
#   $1  reviewer            canonical reviewer name
#   $2  reviews_dir         canonical $REVIEWS_DIR (source of Round-1 prompt)
#   $3  round1_dir          iterations/<iter>/round-1/ (source of R's
#                           Round-1 augmented JSON)
#   $4  round2_dir          iterations/<iter>/round-2/ (target staging dir)
#
# The peer block is read from the `PEER_BLOCK_<UPPER>` env var that
# `debate_build_peer_blocks` exports per recipient.
#
# Returns 0 on success; non-zero (with stderr message) on any input-missing
# error so the coordinator can surface a hard failure rather than spawn a
# reviewer with a malformed Round-2 prompt.
_rdc_build_round2_prompt() {
    local reviewer="$1"
    local reviews_dir="$2"
    local round1_dir="$3"
    local round2_dir="$4"

    local round1_prompt="$reviews_dir/review.${reviewer}.prompt"
    # Prefer the augmented JSON (Mode B defaults applied) so the rendered
    # self-block reflects the same `confidence` values the aggregator sees;
    # fall back to the raw .json if augmentation didn't write one (defensive
    # — should not happen for an active reviewer).
    local self_json_path="$round1_dir/${reviewer}.augmented.json"
    if [[ ! -s "$self_json_path" ]]; then
        self_json_path="$round1_dir/${reviewer}.json"
    fi

    local upper peer_block_var peer_block
    upper=$(echo "$reviewer" | tr '[:lower:]' '[:upper:]')
    peer_block_var="PEER_BLOCK_${upper}"
    peer_block="${!peer_block_var:-}"

    if [[ ! -s "$round1_prompt" ]]; then
        echo "_rdc_build_round2_prompt: missing Round-1 prompt for $reviewer at $round1_prompt" >&2
        return 1
    fi
    if [[ ! -s "$self_json_path" ]]; then
        echo "_rdc_build_round2_prompt: missing Round-1 output for active reviewer $reviewer at $self_json_path" >&2
        return 1
    fi
    if [[ -z "$peer_block" ]]; then
        echo "_rdc_build_round2_prompt: missing peer block for $reviewer (env var $peer_block_var unset or empty)" >&2
        return 1
    fi

    local self_block
    self_block=$(_rdc_render_prior_round_self_block "$(cat "$self_json_path")") || {
        echo "_rdc_build_round2_prompt: failed to render prior-round-self block for $reviewer" >&2
        return 1
    }

    # Find the line number of the reviewer-prompt's `## Output Format`
    # header so we can split the Round-1 prompt into "before" and
    # "from-output-format-on" halves and inject the Round-2 sections in
    # between. `build_prompt` inlines the artifact body inside a fenced
    # markdown block earlier in the prompt, and an artifact body that
    # legitimately contains a `## Output Format` markdown line (e.g., a
    # diff that touches a markdown doc, a spec template that documents
    # output format) would collide with a naive first-match grep. The
    # reviewer-prompt's own `## Output Format` section is always the
    # LAST `## Output Format` line in the rendered prompt because
    # `build_prompt` emits it after every artifact-derived content (see
    # the heredoc structure in bin/review-gate's build_prompt). awk's
    # last-match pattern walks the file once and remembers the most
    # recent matching line number, which is portable across BSD/GNU and
    # cheap on Bash 3.2.
    local outfmt_line
    outfmt_line=$(awk '/^## Output Format/ { last=NR } END { if (last) print last }' "$round1_prompt")

    local out_path="$round2_dir/review.${reviewer}.prompt"
    if [[ -z "$outfmt_line" ]]; then
        # Defensive fallback: every reviewer template should have
        # `## Output Format`, but if it is missing we still produce a
        # valid Round-2 prompt by appending the new sections at the end.
        # Surface a warning so the missing-marker case is observable.
        echo "warning: _rdc_build_round2_prompt: '## Output Format' header not found in Round-1 prompt for $reviewer; appending Round-2 sections at the end (output-format adherence may degrade)" >&2
        {
            cat "$round1_prompt"
            printf '\n\n'
            printf '## Round 2 of debate-mode review\n\n'
            printf 'This is Round 2. Your Round 1 output and the anonymized peer outputs from your fellow reviewers are reproduced below. Use them to perform a confidence-conditioned update: lower-confidence prior findings yield more readily to high-confidence peer dissent; high-confidence prior findings resist sycophantic peer pressure. Review your prior position, weigh peer evidence, and emit a fresh JSON review for Round 2 in the same schema as Round 1 — including per-finding confidence and overall_confidence.\n\n'
            printf '### Your Round 1 output:\n\n'
            printf '%s\n' "$self_block"
            printf '\n'
            printf '### Anonymized peer outputs:\n\n'
            printf '%s\n' "$peer_block"
        } > "$out_path"
        return 0
    fi

    {
        # Lines 1..(outfmt_line - 1): everything before `## Output Format`.
        head -n $((outfmt_line - 1)) "$round1_prompt"
        # Round-2 sections (directive + self-block + peer block).
        printf '## Round 2 of debate-mode review\n\n'
        printf 'This is Round 2. Your Round 1 output and the anonymized peer outputs from your fellow reviewers are reproduced below. Use them to perform a confidence-conditioned update: lower-confidence prior findings yield more readily to high-confidence peer dissent; high-confidence prior findings resist sycophantic peer pressure. Review your prior position, weigh peer evidence, and emit a fresh JSON review for Round 2 in the same schema as Round 1 — including per-finding confidence and overall_confidence.\n\n'
        printf '### Your Round 1 output:\n\n'
        printf '%s\n' "$self_block"
        printf '\n'
        printf '### Anonymized peer outputs:\n\n'
        printf '%s\n' "$peer_block"
        printf '\n'
        # Lines (outfmt_line)..end: `## Output Format` and everything that
        # follows (the JSON-only directive).
        tail -n +"$outfmt_line" "$round1_prompt"
    } > "$out_path"
}

# _rdc_build_round3_prompt — build reviewer R's Round-3 prompt under
# `--mode max`. Mirrors `_rdc_build_round2_prompt` but with three pinned
# behavioral differences from spec R2 / Section 2:
#
#   1. The directive header is `## Round 3 of debate-mode review` and the
#      directive text references "Round 3" explicitly. The reviewer is
#      told this is the final peer round under --mode max.
#   2. The prior-round-self block contains R's Round-2 output ONLY — NOT a
#      concatenation of Rounds 1 and 2. Per spec R2: "the prior-round-self
#      block presented to reviewer R in Round N contains R's Round-(N-1)
#      output exclusively". The Round-1 output is preserved in
#      iterations/<iter>/round-1/ telemetry for inspection but is NOT
#      injected into the Round-3 prompt.
#   3. The anonymized peer block source is Round-2 outputs (not Round-1).
#      The coordinator's Round-3 launch path runs T007's
#      debate_build_peer_blocks over Round-2 augmented JSONs to populate
#      `PEER_BLOCK_<UPPER>` env vars before this builder runs; per-recipient
#      peer ordering is reshuffled per T007's seeded/production rules.
#
# Args:
#   $1  reviewer            canonical reviewer name
#   $2  reviews_dir         canonical $REVIEWS_DIR (source of Round-1 prompt;
#                           used as the prompt scaffold so anchor + strategy
#                           directive remain the same as Rounds 1 and 2)
#   $3  round2_dir          iterations/<iter>/round-2/ (source of R's
#                           Round-2 augmented JSON for the self block)
#   $4  round3_dir          iterations/<iter>/round-3/ (target staging dir)
#
# Returns 0 on success; non-zero (with stderr message) on any input-missing
# error so the coordinator can surface a hard failure rather than spawn a
# reviewer with a malformed Round-3 prompt.
_rdc_build_round3_prompt() {
    local reviewer="$1"
    local reviews_dir="$2"
    local round2_dir="$3"
    local round3_dir="$4"

    local round1_prompt="$reviews_dir/review.${reviewer}.prompt"
    # Prefer the Round-2 augmented JSON (Mode B defaults applied) so the
    # rendered self-block reflects the same `confidence` values the
    # aggregator sees; fall back to raw .json (defensive — should not
    # happen for an active reviewer).
    local self_json_path="$round2_dir/${reviewer}.augmented.json"
    if [[ ! -s "$self_json_path" ]]; then
        self_json_path="$round2_dir/${reviewer}.json"
    fi

    local upper peer_block_var peer_block
    upper=$(echo "$reviewer" | tr '[:lower:]' '[:upper:]')
    peer_block_var="PEER_BLOCK_${upper}"
    peer_block="${!peer_block_var:-}"

    if [[ ! -s "$round1_prompt" ]]; then
        echo "_rdc_build_round3_prompt: missing Round-1 prompt for $reviewer at $round1_prompt" >&2
        return 1
    fi
    if [[ ! -s "$self_json_path" ]]; then
        echo "_rdc_build_round3_prompt: missing Round-2 output for active reviewer $reviewer at $self_json_path" >&2
        return 1
    fi
    if [[ -z "$peer_block" ]]; then
        echo "_rdc_build_round3_prompt: missing peer block for $reviewer (env var $peer_block_var unset or empty)" >&2
        return 1
    fi

    local self_block
    self_block=$(_rdc_render_prior_round_self_block "$(cat "$self_json_path")") || {
        echo "_rdc_build_round3_prompt: failed to render prior-round-self block for $reviewer" >&2
        return 1
    }

    # Find the last `## Output Format` line in the Round-1 prompt (same
    # last-match rule as Round 2 — see _rdc_build_round2_prompt for the
    # rationale on artifact-bodies that legitimately contain markdown
    # headers). The Round-1 prompt is the scaffold for ALL subsequent
    # rounds because it carries the anchor + strategy directive bytes
    # already substituted by build_prompt at Round-1 render time, with no
    # prior-round content interleaved (using the Round-2 prompt as
    # scaffold would re-inject Round-1 content into the Round-3 prompt,
    # violating spec R2).
    local outfmt_line
    outfmt_line=$(awk '/^## Output Format/ { last=NR } END { if (last) print last }' "$round1_prompt")

    local out_path="$round3_dir/review.${reviewer}.prompt"
    if [[ -z "$outfmt_line" ]]; then
        echo "warning: _rdc_build_round3_prompt: '## Output Format' header not found in Round-1 prompt for $reviewer; appending Round-3 sections at the end (output-format adherence may degrade)" >&2
        {
            cat "$round1_prompt"
            printf '\n\n'
            printf '## Round 3 of debate-mode review\n\n'
            printf 'This is Round 3, the final peer round under --mode max. Your Round 2 output and the freshly-anonymized peer outputs from your fellow reviewers are reproduced below. Continue the confidence-conditioned-update protocol: lower-confidence prior findings yield more readily to high-confidence peer dissent; high-confidence prior findings resist sycophantic peer pressure. Review your Round-2 position, weigh peer evidence, and emit a fresh JSON review for Round 3 in the same schema as Round 2 — including per-finding confidence and overall_confidence.\n\n'
            printf '### Your Round 2 output:\n\n'
            printf '%s\n' "$self_block"
            printf '\n'
            printf '### Anonymized peer outputs:\n\n'
            printf '%s\n' "$peer_block"
        } > "$out_path"
        return 0
    fi

    {
        head -n $((outfmt_line - 1)) "$round1_prompt"
        printf '## Round 3 of debate-mode review\n\n'
        printf 'This is Round 3, the final peer round under --mode max. Your Round 2 output and the freshly-anonymized peer outputs from your fellow reviewers are reproduced below. Continue the confidence-conditioned-update protocol: lower-confidence prior findings yield more readily to high-confidence peer dissent; high-confidence prior findings resist sycophantic peer pressure. Review your Round-2 position, weigh peer evidence, and emit a fresh JSON review for Round 3 in the same schema as Round 2 — including per-finding confidence and overall_confidence.\n\n'
        printf '### Your Round 2 output:\n\n'
        printf '%s\n' "$self_block"
        printf '\n'
        printf '### Anonymized peer outputs:\n\n'
        printf '%s\n' "$peer_block"
        printf '\n'
        tail -n +"$outfmt_line" "$round1_prompt"
    } > "$out_path"
}

# _rdc_mark_state_degraded — write the canonical degraded-below-2 on-disk
# shape into $STATE_FILE per spec R6 / plan L202:
#
#   .reviewers = {}
#   .status = "awaiting_decision"
#   .consensus = {
#     verdict: "requires_decision",
#     iteration: <existing or 0>,
#     reason: "debate degraded below 2 active reviewers in the final peer round"
#   }
#   .decision = null
#
# The canonical $REVIEWS_DIR is left empty (the coordinator never promotes
# anything in the degraded path) and per-round staging under
# iterations/<iter>/round-N/ is preserved for inspection.
#
# This helper is best-effort: if $STATE_FILE is unset or jq fails to write
# the temp file, the helper returns silently rather than raising another
# error on top of the coordinator's already-fatal degraded-below-2 path.
# T012 will refine the failure-shape contract; the canonical fields above
# match the spec text and are stable across T012's expected revisions.
# _rdc_prune_state_reviewers — remove the named reviewers from the
# `gate-state.json.reviewers` map.
#
# Why this is needed (Stop-hook contract): `bin/review-gate spawn` writes
# every successfully-spawned reviewer into `state.reviewers` BEFORE the
# coordinator runs, with paths pointing into the canonical $REVIEWS_DIR.
# The Stop-hook (`bin/review-gate-hook.sh`) then iterates the state's
# reviewers map and waits for each reviewer's `<r>.done` / `<r>.failed`
# sentinel under $REVIEWS_DIR. Under the terminal-abstention rule
# (Round-1 abstainers are not invoked in Round 2) and final-round Option B
# (Round-2 abstainers are excluded from final aggregation), the
# coordinator NEVER promotes a sentinel for the abstained reviewer. Left
# as-is, the Stop-hook would block waiting for a sentinel that will never
# be written, timing out the entire iteration.
#
# Pruning the abstained reviewer from the state's reviewers map is the
# spec-aligned fix: the reviewer is excluded from the final-round set
# (per Section 2 step 7 + R6), and the Stop-hook's per-reviewer
# consensus calculator should not see them at all. Their earlier-round
# output remains in iterations/<iter>/round-N/ telemetry; this prune
# only affects the canonical decision surface.
#
# Args: reviewer canonical names to remove from `state.reviewers`. Empty
# arg list is a no-op (the function just returns 0).
#
# Best-effort: silently no-ops when STATE_FILE is unset / the file is
# missing / jq fails; the coordinator's overall failure path doesn't
# depend on state-file mutation succeeding.
_rdc_prune_state_reviewers() {
    local state_file="${STATE_FILE:-}"
    if [[ -z "$state_file" || ! -f "$state_file" ]]; then
        return 0
    fi
    if [[ $# -eq 0 ]]; then
        return 0
    fi

    # Build a JSON array of names to delete (jq's `--argjson` accepts
    # arbitrarily-shaped JSON; building via successive `+ [$n]` calls
    # avoids any embedded-quote escaping risk a flat string-concat would
    # carry).
    local removed_json='[]'
    local r
    for r in "$@"; do
        removed_json=$(printf '%s' "$removed_json" | jq --arg n "$r" '. + [$n]') || return 0
    done

    local state_tmp="$state_file.prune.tmp.$$"
    if jq --argjson remove "$removed_json" '
        .reviewers = (
            (.reviewers // {})
            | with_entries(select(.key as $k | ($remove | index($k)) | not))
        )
    ' "$state_file" > "$state_tmp" 2>/dev/null; then
        mv -f "$state_tmp" "$state_file"
    else
        rm -f "$state_tmp" 2>/dev/null || true
    fi
}

_rdc_mark_state_degraded() {
    local state_file="${STATE_FILE:-}"
    if [[ -z "$state_file" || ! -f "$state_file" ]]; then
        return 0
    fi
    local state_tmp="$state_file.degraded.tmp.$$"
    local now_ts reason
    now_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
    reason="debate degraded below 2 active reviewers in the final peer round"
    if jq --arg now "$now_ts" \
          --arg reason "$reason" \
       '.reviewers = {}
        | .status = "awaiting_decision"
        | .consensus = {
            verdict: "requires_decision",
            iteration: (.iteration // 0),
            reason: $reason
          }
        | .decision = null' \
       "$state_file" > "$state_tmp" 2>/dev/null; then
        mv -f "$state_tmp" "$state_file"
    else
        rm -f "$state_tmp" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# T012 — Phase F.2 telemetry helpers + distinct exit codes.
# ---------------------------------------------------------------------------
#
# Surfaces produced by these helpers:
#
#   1. gate-state.json.debate         — SUCCESS-path canonical block. Written
#                                        AFTER per-reviewer JSONs + aggregate.json
#                                        promote into $REVIEWS_DIR. jq patch
#                                        preserves existing top-level fields,
#                                        so the Stop-hook's subsequent
#                                        `.status` / `.consensus` mutations
#                                        leave `.debate` byte-stable (asserted
#                                        by test_debate_block_survives_stop_hook).
#
#   2. iterations/<iter>/debate-telemetry.json
#                                      — PARTIAL-STATE surface for the three
#                                        non-success paths (cancel / aggregator-
#                                        fail / degraded). Same JSON shape as
#                                        gate-state.json.debate, BUT the
#                                        `rounds_telemetry[]` is whatever rounds
#                                        actually completed before the failure.
#                                        Success-path runs MUST NOT write this
#                                        file (presence of debate-telemetry.json
#                                        unambiguously signals a non-success
#                                        debate run).
#
#   3. Distinct exit codes:
#        130 — SIGINT cancellation (conventional 128 + SIGINT)
#        5   — aggregator failure (jq parse error, OOM, unhandled shell error)
#        6   — degraded-below-2 (mid-debate or final-round)
#        2   — bare-spawn whitelist rejection (T002 implements this in
#              bin/review-gate; documented here for the four-codes contract)
#
# Globals set by `run_debate_coordinator` and consumed by the helpers. They
# are intentionally underscore-prefixed top-level shell variables (NOT
# `local`) so the SIGINT trap handler can read them from a parent shell
# context (Bash trap handlers run as if invoked from the trapping shell;
# function-locals are NOT visible to traps that fire mid-call).
#
#   _RDC_ITER_DIR              — iterations/<iter>/ root for the current run.
#   _RDC_REVIEWS_DIR           — canonical $REVIEWS_DIR.
#   _RDC_CONSENSUS_MODE        — majority|all|any (recorded in the block).
#   _RDC_DEBATE_MODE           — fast|smart|max (recorded in the block).
#   _RDC_STRATEGIES_JSON       — `{}` map keyed by reviewer canonical name.
#   _RDC_ROUNDS_JSON           — `[]` array of per-round telemetry entries.
#   _RDC_ROUNDS_COMPLETED      — count of rounds whose `.done`/.failed
#                                 sentinels were observed and classified.
#   _RDC_AGGREGATOR_NOTES_JSON — `[]` array of human-readable aggregator notes
#                                (near-duplicate merges, tiebreaks, Mode B
#                                 clamps). Populated during aggregation.
#
# Reset to fresh empties at the top of run_debate_coordinator so a second
# invocation in the same shell (e.g., test harness re-entering the
# coordinator under different inputs) does not see stale state.

# _rdc_now_iso — UTC ISO8601 timestamp with `Z` suffix.
_rdc_now_iso() {
    date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo ""
}

# _rdc_now_ms — current epoch in milliseconds (whole-second precision on
# systems lacking a millisecond-aware date(1) or python3).
_rdc_now_ms() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null && return 0
    fi
    # Fallback: whole-second precision multiplied to ms.
    local s
    s=$(date +%s 2>/dev/null || echo 0)
    printf '%d\n' "$(( s * 1000 ))"
}

# _rdc_append_aggregator_note — append one human-readable string to
# $_RDC_AGGREGATOR_NOTES_JSON. Consumers MUST NOT pattern-match against
# the exact wording (spec §4 line 355).
#
# Args:
#   $1  note string
_rdc_append_aggregator_note() {
    _RDC_AGGREGATOR_NOTES_JSON=$(printf '%s' "${_RDC_AGGREGATOR_NOTES_JSON:-[]}" \
        | jq --arg n "$1" '. + [$n]' 2>/dev/null) || true
}

# _rdc_record_round — append one entry to $_RDC_ROUNDS_JSON describing a
# completed round (round number, timestamps, wall-clock ms, per-reviewer
# entries). Reviewers in the round but not in the active list are recorded
# as `abstained: true` with `overall_confidence: null`. Active reviewers'
# `overall_confidence` is read from the round's augmented JSON.
#
# Args:
#   $1  round_num            integer (1, 2, or 3)
#   $2  started_iso          ISO8601 UTC start timestamp
#   $3  finished_iso         ISO8601 UTC end timestamp
#   $4  wall_clock_ms        integer (finished_ms - started_ms)
#   $5  round_dir            iterations/<iter>/round-N/ (source of augmented JSONs)
#   $6  all_reviewers_csv    comma-separated reviewer canonical names that
#                            were waited on for this round
#   $7  active_reviewers_csv comma-separated reviewer canonical names that
#                            classified as active (rest of $6 are abstained)
#
# Side effect: appends one entry to $_RDC_ROUNDS_JSON; increments
# $_RDC_ROUNDS_COMPLETED.
_rdc_record_round() {
    local round_num="$1"
    local started_iso="$2"
    local finished_iso="$3"
    local wall_ms="$4"
    local round_dir="$5"
    local all_csv="$6"
    local active_csv="$7"

    # Split CSV into arrays without using `set --` (which would clobber the
    # function's positional parameters). Use IFS-protected read into array.
    local -a all_arr=()
    local -a active_arr=()
    local _saved_ifs="$IFS"
    IFS=','
    # shellcheck disable=SC2206
    all_arr=( $all_csv )
    # shellcheck disable=SC2206
    active_arr=( $active_csv )
    IFS="$_saved_ifs"

    local reviewers_json='[]'
    local r
    for r in "${all_arr[@]+${all_arr[@]}}"; do
        [[ -z "$r" ]] && continue
        local abstained="true"
        local ar
        for ar in "${active_arr[@]+${active_arr[@]}}"; do
            if [[ "$ar" == "$r" ]]; then
                abstained="false"
                break
            fi
        done

        local oc_field='null'
        if [[ "$abstained" == "false" ]]; then
            local aug="$round_dir/${r}.augmented.json"
            if [[ -s "$aug" ]]; then
                # Use jq to read overall_confidence as a JSON value (number
                # or null). Fall back to null on any extraction error so we
                # never emit invalid JSON.
                oc_field=$(jq '.overall_confidence // null' "$aug" 2>/dev/null) || oc_field='null'
                if [[ -z "$oc_field" ]]; then oc_field='null'; fi
            fi
        fi

        local abstained_json="false"
        if [[ "$abstained" == "true" ]]; then abstained_json="true"; fi

        reviewers_json=$(printf '%s' "$reviewers_json" | jq -c \
            --arg name "$r" \
            --argjson abstained "$abstained_json" \
            --argjson oc "$oc_field" \
            '. + [{
                name: $name,
                abstained: $abstained,
                overall_confidence: $oc,
                tokens_used: null,
                integrity_flags: []
            }]') || return 0
    done

    local round_entry
    round_entry=$(jq -nc \
        --argjson rnd "$round_num" \
        --arg started "$started_iso" \
        --arg finished "$finished_iso" \
        --argjson wall "$wall_ms" \
        --argjson reviewers "$reviewers_json" \
        '{
            round: $rnd,
            started_at: $started,
            finished_at: $finished,
            wall_clock_ms: $wall,
            reviewers: $reviewers
        }') || return 0

    _RDC_ROUNDS_JSON=$(printf '%s' "$_RDC_ROUNDS_JSON" | jq -c --argjson e "$round_entry" '. + [$e]') || return 0
    _RDC_ROUNDS_COMPLETED=$(( ${_RDC_ROUNDS_COMPLETED:-0} + 1 ))
}

# _rdc_compose_debate_block — emit the full gate-state.json.debate / partial
# telemetry shape from the current global state. Single-source-of-truth for
# both the success-path debate block and the partial-telemetry file.
#
# The defensive empty-string guards on $_RDC_STRATEGIES_JSON / $_RDC_ROUNDS_JSON
# / $_RDC_AGGREGATOR_NOTES_JSON ARE intentional even though
# `run_debate_coordinator` initializes those globals on entry: this helper is
# also used by the `_rdc_pre_round_degraded_exit` external-caller surface
# (bin/review-gate's pre-coordinator <2-spawn branch), where the globals
# may be set by the caller's `<var>=<value> _rdc_pre_round_degraded_exit`
# inline-export form rather than at coordinator entry. The guards keep
# the helper safe under both surfaces.
_rdc_compose_debate_block() {
    local _strategies="${_RDC_STRATEGIES_JSON:-}"
    local _rounds="${_RDC_ROUNDS_JSON:-}"
    local _notes="${_RDC_AGGREGATOR_NOTES_JSON:-}"
    [[ -z "$_strategies" ]] && _strategies='{}'
    [[ -z "$_rounds" ]] && _rounds='[]'
    [[ -z "$_notes" ]] && _notes='[]'
    # _RDC_ROUNDS_COMPLETED, _RDC_DEBATE_MODE, and _RDC_CONSENSUS_MODE are
    # always initialized at coordinator entry (or by `_rdc_pre_round_degraded_exit`
    # callers via inline-export); inline numeric/string defaults stay
    # plain (no `:-` fallback) since the variables are guaranteed set.
    jq -nc \
        --argjson rounds "$_RDC_ROUNDS_COMPLETED" \
        --arg mode "$_RDC_DEBATE_MODE" \
        --arg consensus_mode "$_RDC_CONSENSUS_MODE" \
        --argjson strategies "$_strategies" \
        --argjson rounds_telemetry "$_rounds" \
        --argjson aggregator_notes "$_notes" \
        '{
            rounds: $rounds,
            mode: $mode,
            consensus_mode: $consensus_mode,
            strategies: $strategies,
            rounds_telemetry: $rounds_telemetry,
            aggregator_notes: $aggregator_notes
        }'
}

# _rdc_write_partial_telemetry — write the partial-state debate telemetry
# JSON to iterations/<iter>/debate-telemetry.json. Best-effort: failures
# are logged but never propagated (the caller's failure exit code MUST
# NOT be masked by a telemetry-write failure).
_rdc_write_partial_telemetry() {
    local iter_dir="${_RDC_ITER_DIR:-}"
    if [[ -z "$iter_dir" ]]; then
        return 0
    fi
    local block
    block=$(_rdc_compose_debate_block 2>/dev/null) || return 0
    if declare -F write_debate_telemetry >/dev/null 2>&1; then
        write_debate_telemetry "$iter_dir" "$block" 2>/dev/null || true
    else
        # Defensive fallback if telemetry-lib helper is not sourced
        # (should not happen — review-gate-lib.sh sources telemetry-lib.sh).
        mkdir -p "$iter_dir" 2>/dev/null || true
        local tmp="$iter_dir/debate-telemetry.json.tmp.$$"
        if printf '%s' "$block" > "$tmp" 2>/dev/null; then
            mv -f "$tmp" "$iter_dir/debate-telemetry.json" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
        fi
    fi
}

# _rdc_write_gate_state_debate_block — patch the gate-state.json file with
# the success-path debate block. Uses jq's `.debate = $block` patch syntax
# so the existing top-level fields (.status, .reviewers, .consensus,
# .iteration, .config, etc.) are preserved verbatim. The Stop-hook's
# subsequent .status / .consensus mutations are also jq-patch-based and
# preserve unspecified top-level fields, so the .debate key written here
# survives the Stop-hook's pending → awaiting_decision → resolved
# transitions (asserted by test_debate_block_survives_stop_hook).
#
# Best-effort: STATE_FILE missing or unset, jq failure, mv failure are all
# logged-and-ignored. The success-path return code is unaffected.
_rdc_write_gate_state_debate_block() {
    local state_file="${STATE_FILE:-}"
    if [[ -z "$state_file" || ! -f "$state_file" ]]; then
        return 0
    fi
    local block
    block=$(_rdc_compose_debate_block 2>/dev/null) || return 0
    local tmp="$state_file.debate.tmp.$$"
    if jq --argjson debate "$block" '.debate = $debate' "$state_file" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$state_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    else
        rm -f "$tmp" 2>/dev/null || true
    fi
}

# _rdc_aggregator_fail_exit — write the partial telemetry surface and exit 5.
# Caller is responsible for emitting the canonical
# `aggregator failed: <reason>` stderr message BEFORE invoking this helper.
_rdc_aggregator_fail_exit() {
    _rdc_write_partial_telemetry
    exit 5
}

# _rdc_degraded_exit — write the partial telemetry surface and exit 6.
# Caller is responsible for emitting the canonical
# `debate degraded below 2 active reviewers in the final peer round`
# stderr message AND calling _rdc_mark_state_degraded BEFORE invoking
# this helper. The state mutation is what flips
# gate-state.json.status to "awaiting_decision" and
# gate-state.json.consensus.verdict to "requires_decision"; this helper
# only writes the partial-state telemetry file and exits with the
# distinct return code.
_rdc_degraded_exit() {
    _rdc_write_partial_telemetry
    exit 6
}

# _rdc_handle_sigint — SIGINT trap handler.
#
# Per spec, on SIGINT the coordinator MUST "let in-flight reviewers
# complete or hit per-reviewer timeout, write whatever rounds completed
# as partial telemetry". The trap therefore does NOT short-circuit the
# in-flight wait loop: it sets a request flag and returns, allowing the
# round to run to its natural conclusion (all sentinels appear OR the
# per-reviewer round-budget timeout elapses). After the round
# classifies + records, `_rdc_check_cancel_after_round` (the post-record
# cancel checkpoint) sees the flag and triggers `_rdc_cancel_exit`,
# which writes the partial telemetry and exits 130.
#
# Why deferred + run-to-completion: reviewers spawn detached via
# `nohup`/`setsid`; SIGINT to the parent shell does NOT kill the
# child reviewer processes. A reviewer that's mid-LLM-call when SIGINT
# arrives may finish writing its `<reviewer>.json` and `.done` sentinel
# seconds later. Short-circuiting the wait would mark that reviewer
# abstained in partial telemetry while its actual output lands on
# disk — a contradiction that breaks the contract that
# `iterations/<iter>/debate-telemetry.json.rounds_telemetry[]`
# accurately reflects what actually happened in each round.
#
# Per spec, gate-state.json.status stays at `pending`, the canonical
# $REVIEWS_DIR is left empty (no per-reviewer JSONs / sentinels /
# aggregate.json have been promoted yet at this point — promotion is
# the last step of the success path), and NO .debate block is written.
_rdc_handle_sigint() {
    _RDC_CANCEL_REQUESTED=1
    # Best-effort stderr message. The signal arrival point is undefined
    # so the message may interleave with other stderr; that's accepted.
    echo "" >&2
    echo "debate SIGINT received; in-flight round will run to completion (or hit per-reviewer timeout) before writing partial telemetry and exiting 130." >&2
}

# _rdc_cancel_exit — write partial telemetry and exit 130. Called from the
# coordinator's checkpoint after each round's `_rdc_record_round` runs,
# whenever `_RDC_CANCEL_REQUESTED` is set.
_rdc_cancel_exit() {
    _rdc_write_partial_telemetry
    echo "" >&2
    echo "debate cancelled by SIGINT after round ${_RDC_ROUNDS_COMPLETED:-0}; partial telemetry written to ${_RDC_ITER_DIR:-?}/debate-telemetry.json" >&2
    exit 130
}

# _rdc_check_cancel_after_round — coordinator checkpoint helper. Invoked
# after each per-round `_rdc_record_round`; if SIGINT was received during
# the just-completed round (the trap set `_RDC_CANCEL_REQUESTED`),
# triggers the exit-130 path with the round's telemetry recorded.
_rdc_check_cancel_after_round() {
    if [[ "${_RDC_CANCEL_REQUESTED:-0}" == "1" ]]; then
        _rdc_cancel_exit
    fi
}

# _rdc_pre_round_degraded_exit — public-facing helper for the bin/review-gate
# pre-coordinator path. Before run_debate_coordinator runs, bin/review-gate
# may discover that fewer than 2 reviewers spawned successfully (a
# realistic degraded-before-round path: `command -v` passed preflight but
# the actual spawn_reviewer call failed for one reviewer, e.g., gemini
# read-only-policy lookup failed). Per spec R6 + the T012 distinct-exit-
# codes contract, this case MUST emit the canonical degraded-below-2
# stderr, transition gate-state.json to awaiting_decision/requires_decision,
# write iterations/<iter>/debate-telemetry.json, and exit 6.
#
# The caller is expected to inline-export the relevant globals on the
# function-call line OR set them as plain shell vars before invoking,
# e.g.:
#
#   _RDC_ITER_DIR="$staging_iter_dir" \
#   _RDC_REVIEWS_DIR="$REVIEWS_DIR" \
#   _RDC_CONSENSUS_MODE="$consensus_mode" \
#   _RDC_DEBATE_MODE="$mode" \
#   _rdc_pre_round_degraded_exit
#
# This helper writes the canonical degraded message, calls
# `_rdc_mark_state_degraded` (which transitions gate-state.json), writes
# partial telemetry, and exits 6.
_rdc_pre_round_degraded_exit() {
    # Default unset/empty globals to safe values. We CANNOT use the
    # `${var:=DEFAULT}` parameter-assign form for JSON literals like
    # `{}`/`[]` because the surrounding single quotes in the source
    # become part of the assigned value (Bash 3.2 does not strip them
    # from inside the `:=` default). Use plain `[[ -z ... ]]` guards.
    [[ -z "${_RDC_STRATEGIES_JSON:-}" ]] && _RDC_STRATEGIES_JSON='{}'
    [[ -z "${_RDC_ROUNDS_JSON:-}" ]] && _RDC_ROUNDS_JSON='[]'
    [[ -z "${_RDC_AGGREGATOR_NOTES_JSON:-}" ]] && _RDC_AGGREGATOR_NOTES_JSON='[]'
    [[ -z "${_RDC_ROUNDS_COMPLETED:-}" ]] && _RDC_ROUNDS_COMPLETED=0
    [[ -z "${_RDC_CONSENSUS_MODE:-}" ]] && _RDC_CONSENSUS_MODE="majority"
    [[ -z "${_RDC_DEBATE_MODE:-}" ]] && _RDC_DEBATE_MODE="smart"
    echo "" >&2
    echo "debate degraded below 2 active reviewers in the final peer round" >&2
    _rdc_mark_state_degraded
    _rdc_write_partial_telemetry
    exit 6
}

# ---------------------------------------------------------------------------
# run_debate_coordinator — synchronous in-process coordinator (T008 scope:
# Round 1 + Round 2 + terminal-abstention + Option B + degraded-below-2 +
# stub aggregator + atomic promotion).
# ---------------------------------------------------------------------------
#
# This function is the post-spawn finalize phase of the debate flow. By the
# time it is called, `bin/review-gate` has already:
#
#   - Run the debate preflights (R10 type whitelist, <2 reviewers hard-error)
#   - Run `assign_strategies` and exported per-reviewer
#     STRATEGY_DIRECTIVE_PATH_<REVIEWER> + STRATEGY_NAME_<REVIEWER> +
#     DEBATE_ARTIFACT_ID
#   - Emitted the debate-conditional `review-schema.json` (via
#     `_emit_review_schema "true"` from review-gate-models.sh)
#   - Rendered per-reviewer Round-1 prompts under --debate (T005 wires
#     per-reviewer STRATEGY_NAME_<REVIEWER> bytes into each reviewer's
#     prompt) into `$REVIEWS_DIR/review.<reviewer>.prompt`
#   - Detached each Round-1 reviewer via `spawn_reviewer` with the round-1
#     staging dir ($staging_dir below) as the output directory, NOT the
#     canonical $REVIEWS_DIR. Per-reviewer JSONs/sentinels currently land
#     in staging.
#
# This function then runs the multi-round loop:
#
#   1. Wait for Round-1 sentinels under $staging_dir.
#   2. Classify Round-1 outputs as Mode A (abstain) or Mode B (parseable +
#      active, with confidence defaults applied to the augmented JSON).
#   3. Eligibility check (mid-debate): if fewer than 2 active reviewers
#      remain after Round 1, hard-error with the canonical degraded-below-2
#      message + on-disk shape (return code 6). Round 2 is NOT launched.
#   4. Build per-recipient anonymized peer blocks via T007's
#      debate_build_peer_blocks (deny-list scrubbed; abstained Round-1
#      reviewers surface as `(peer abstained)` per spec R1).
#   5. For each active Round-1 reviewer R, append the Round-2 directive +
#      R's prior-round-self block (NOT scrubbed) + R's per-recipient peer
#      block (scrubbed) to R's Round-1 prompt; save as
#      iterations/<iter>/round-2/review.<reviewer>.prompt.
#   6. Spawn each active Round-1 reviewer for Round 2 via spawn_reviewer
#      with `output_dir = iterations/<iter>/round-2/`. Round-1 abstainers
#      are NOT re-invoked (terminal-abstention rule, spec Section 2 / R6).
#   7. Wait for Round-2 sentinels.
#   8. Classify Round-2 outputs (same Mode A / Mode B rules as Round 1).
#   9. Final-round Option B: a Round-2 abstainer is fully excluded from
#      the final aggregation. No per-reviewer JSON is written for them
#      into $REVIEWS_DIR; their Round-1 output is preserved in
#      iterations/<iter>/round-1/ telemetry only.
#  10. Final eligibility: if fewer than 2 active reviewers in the final
#      peer round, hard-error with degraded-below-2 (return code 6).
#  11. Stub aggregator over Round-2 outputs (active final-round reviewers
#      only): atomic promotion of per-reviewer augmented JSONs +
#      `<reviewer>.done` sentinels into $REVIEWS_DIR; aggregate.json with
#      rounds_consumed=2 written last. T009 replaces the stub aggregator
#      with the real confidence-weighted dedup + canonical merge order.
#
# Failure handling:
#
#   On any aggregator error (parse failure post-classify, jq crash during
#   promotion), $reviews_dir is left UNTOUCHED — no per-reviewer JSONs,
#   no .done sentinels, no aggregate.json. Any temp staging files under
#   $reviews_dir created during the partial promotion are removed. Staging
#   directories ($staging_dir + iterations/<iter>/round-2/) are preserved
#   for inspection.
#
#   Return codes:
#     0  — coordinator success; aggregate.json + per-reviewer JSONs
#          promoted to $REVIEWS_DIR.
#     6  — degraded-below-2 (mid-debate or final-round); state file
#          transitioned to awaiting_decision/requires_decision per
#          `_rdc_mark_state_degraded`.
#     1+ — other aggregator failure (timeout, jq crash, etc.). T012 will
#          pin the public exit codes for each failure mode.
#
# Args (positional):
#   $1  staging_dir     Round-1 staging directory (e.g.,
#                       $REVIEW_DIR/iterations/<iter>/round-1/) where
#                       Round-1 spawn_reviewer wrote per-reviewer outputs.
#   $2  reviews_dir     Canonical $REVIEWS_DIR (atomic-promotion target).
#   $3  consensus_mode  One of majority|all|any. Recorded in
#                       aggregate.json.consensus_mode for downstream
#                       surfaces (gate report, telemetry).
#   $4  timeout_sec     Max seconds to wait for sentinels per round.
#   $5  poll_interval   Seconds between polls (>=1).
#   $@  (6+)            Reviewer canonical names (initial Round-1 set).
run_debate_coordinator() {
    local round1_dir="${1:-}"
    local reviews_dir="${2:-}"
    local consensus_mode="${3:-majority}"
    local timeout_sec="${4:-1800}"
    local poll_interval="${5:-3}"
    if [[ $# -lt 6 ]]; then
        echo "run_debate_coordinator: missing reviewer arguments (need at least 1)" >&2
        return 1
    fi
    shift 5
    local -a _rdc_initial_reviewers=("$@")

    if [[ -z "$round1_dir" || ! -d "$round1_dir" ]]; then
        echo "run_debate_coordinator: round-1 staging directory missing or invalid: $round1_dir" >&2
        return 1
    fi
    if [[ -z "$reviews_dir" ]]; then
        echo "run_debate_coordinator: reviews directory unset" >&2
        return 1
    fi
    if [[ ! -d "$reviews_dir" ]]; then
        if ! mkdir -p "$reviews_dir"; then
            echo "run_debate_coordinator: cannot create reviews directory: $reviews_dir" >&2
            return 1
        fi
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo "run_debate_coordinator: jq not available" >&2
        return 1
    fi

    # Sanitize numeric args (defensive against caller passing empty strings).
    if ! [[ "$timeout_sec" =~ ^[0-9]+$ ]]; then
        timeout_sec=1800
    fi
    if ! [[ "$poll_interval" =~ ^[0-9]+$ ]] || [[ "$poll_interval" -lt 1 ]]; then
        poll_interval=3
    fi

    # iterations/<iter>/ — the parent of round-1 staging. Round 2 and beyond
    # land at sibling round-N directories under this same iteration root.
    local _rdc_iter_dir
    _rdc_iter_dir=$(dirname "$round1_dir")

    # Determine how many rounds to drive. T008 caps at 2 rounds always
    # (fast/smart all run 2 rounds); T010 lifts the cap to 3 under
    # `--mode max`. Mode is propagated via env var REVIEW_GATE_DEBATE_MODE
    # which `bin/review-gate` sets before invoking the coordinator. Any
    # value other than "max" (including unset) keeps the 2-round flow.
    local _rdc_max_rounds=2
    if [[ "${REVIEW_GATE_DEBATE_MODE:-}" == "max" ]]; then
        _rdc_max_rounds=3
    fi

    # ----------------------------------------------------------------------
    # T012 telemetry/exit-code state. Globals (NOT `local`) so the SIGINT
    # trap handler can read them — Bash function-locals are not visible to
    # traps that fire mid-call. Reset on every coordinator entry so a
    # second invocation in the same shell does not see stale state.
    # ----------------------------------------------------------------------
    _RDC_ITER_DIR="$_rdc_iter_dir"
    _RDC_REVIEWS_DIR="$reviews_dir"
    _RDC_CONSENSUS_MODE="$consensus_mode"
    _RDC_DEBATE_MODE="${REVIEW_GATE_DEBATE_MODE:-smart}"
    _RDC_STRATEGIES_JSON='{}'
    _RDC_ROUNDS_JSON='[]'
    _RDC_ROUNDS_COMPLETED=0
    _RDC_AGGREGATOR_NOTES_JSON='[]'
    _RDC_CANCEL_REQUESTED=0

    # Pre-populate _RDC_STRATEGIES_JSON from STRATEGY_NAME_<UPPER> env vars
    # for the initial reviewer set, so partial telemetry on early failure
    # (e.g., a degraded preflight before any round completed) still
    # surfaces the strategy assignment instead of an empty `{}`. When the
    # env var is unset, the aggregator (`_rdc_aggregate_and_promote`) and
    # bin/review-gate's render path both fall back to the v1 default
    # `verification-first`, so we record the same default here for
    # consistency between gate-state.json.debate.strategies and
    # aggregate.json.strategies.
    local _rdc_init_r _rdc_init_upper _rdc_init_var _rdc_init_val
    for _rdc_init_r in "${_rdc_initial_reviewers[@]}"; do
        _rdc_init_upper=$(echo "$_rdc_init_r" | tr '[:lower:]' '[:upper:]')
        _rdc_init_var="STRATEGY_NAME_${_rdc_init_upper}"
        _rdc_init_val="${!_rdc_init_var:-verification-first}"
        _RDC_STRATEGIES_JSON=$(printf '%s' "$_RDC_STRATEGIES_JSON" | jq -c \
            --arg n "$_rdc_init_r" --arg s "$_rdc_init_val" \
            '.[$n] = $s' 2>/dev/null) || _RDC_STRATEGIES_JSON='{}'
    done

    # Install the SIGINT trap. The handler sets a request flag (it does
    # NOT exit immediately) so the in-flight round can finish classifying
    # and recording before the coordinator exits 130. The trap is
    # uninstalled BEFORE the success-path debate-block write so a
    # post-success SIGINT cannot fire the trap and write a spurious
    # partial-telemetry file (race window between coordinator return and
    # bin/review-gate's wrap-up echos).
    trap '_rdc_handle_sigint' INT

    # ======================================================================
    # Round 1: wait for sentinels, classify outputs, terminal-abstention.
    #
    # Per spec D5: a per-reviewer timeout (no sentinel within the round
    # budget) is Mode A — that reviewer abstains for the round; the round
    # MUST continue if eligibility >=2 remains. The wait helper therefore
    # does NOT propagate timeout-as-coordinator-failure: it returns 0 on
    # timeout (after logging the elapsed budget for observability) and
    # `_rdc_classify_round_outputs` then handles the missing-sentinel /
    # empty-JSON cases as abstain entries via the existing Mode A
    # classification path. The eligibility check below catches the
    # genuine degraded-below-2 case.
    # ======================================================================
    # Round-1 timing. Round 1 is spawned by bin/review-gate BEFORE this
    # function runs, so coord-entry is the closest reasonable approximation
    # for `started_at`; `finished_at` is captured after classification.
    local _rdc_r1_started_iso _rdc_r1_started_ms
    _rdc_r1_started_iso=$(_rdc_now_iso)
    _rdc_r1_started_ms=$(_rdc_now_ms)

    if ! _rdc_wait_round_sentinels "$round1_dir" "$timeout_sec" "$poll_interval" "${_rdc_initial_reviewers[@]}"; then
        echo "warning: round-1 sentinel wait budget elapsed (${timeout_sec}s); reviewers without sentinels will be classified as Mode A abstain (terminal for the run)" >&2
    fi

    local -a _rdc_round1_active=()
    local -a _rdc_round1_abstained=()
    local _line _r _status
    while IFS= read -r _line; do
        [[ -z "$_line" ]] && continue
        _r="${_line%% *}"
        _status="${_line##* }"
        if [[ "$_status" == "active" ]]; then
            _rdc_round1_active+=("$_r")
        else
            _rdc_round1_abstained+=("$_r")
        fi
    done < <(_rdc_classify_round_outputs "$round1_dir" "${_rdc_initial_reviewers[@]}")

    # Prune Round-1 abstainers from gate-state.json's reviewers map: the
    # terminal-abstention rule says they will not be invoked in Round 2,
    # so no canonical $REVIEWS_DIR/<r>.done sentinel will ever appear for
    # them; without pruning, the Stop-hook would block waiting for one.
    # The prune is a no-op on empty input and best-effort if STATE_FILE
    # is unset / jq fails.
    if [[ ${#_rdc_round1_abstained[@]} -gt 0 ]]; then
        _rdc_prune_state_reviewers "${_rdc_round1_abstained[@]}"
    fi

    # Record Round-1 telemetry. Reviewers waited on for this round = the
    # full initial reviewer set (terminal-abstention pruning happens
    # downstream); active set = `_rdc_round1_active`. Recording happens
    # BEFORE the degraded-below-2 check so partial telemetry on an
    # immediately-degraded run still surfaces Round-1 entries.
    local _rdc_r1_finished_iso _rdc_r1_finished_ms _rdc_r1_wall_ms
    _rdc_r1_finished_iso=$(_rdc_now_iso)
    _rdc_r1_finished_ms=$(_rdc_now_ms)
    _rdc_r1_wall_ms=$(( _rdc_r1_finished_ms - _rdc_r1_started_ms ))
    if [[ $_rdc_r1_wall_ms -lt 0 ]]; then _rdc_r1_wall_ms=0; fi
    _rdc_record_round 1 \
        "$_rdc_r1_started_iso" "$_rdc_r1_finished_iso" "$_rdc_r1_wall_ms" \
        "$round1_dir" \
        "$(printf '%s,' "${_rdc_initial_reviewers[@]}" | sed 's/,$//')" \
        "$(printf '%s,' "${_rdc_round1_active[@]+${_rdc_round1_active[@]}}" | sed 's/,$//')"

    # Cancel checkpoint: if SIGINT arrived during Round 1's wait,
    # `_RDC_CANCEL_REQUESTED` is set. Round-1 telemetry has been recorded
    # above; now exit 130 with the partial-state file written.
    _rdc_check_cancel_after_round

    # ======================================================================
    # Mid-debate eligibility check (degraded-below-2 — pinned spec R6).
    # If fewer than 2 reviewers passed Round 1 (active set under the
    # terminal-abstention rule), Round 2 cannot launch and the run hard-
    # errors with the canonical degraded-below-2 message + on-disk shape.
    # The canonical $REVIEWS_DIR is left empty; partial Round-1 outputs
    # are preserved under iterations/<iter>/round-1/ for inspection.
    # ======================================================================
    if [[ ${#_rdc_round1_active[@]} -lt 2 ]]; then
        echo "debate degraded below 2 active reviewers in the final peer round" >&2
        echo "  Round-1 active: ${_rdc_round1_active[*]:-(none)}" >&2
        echo "  Round-1 abstained: " >&2
        local _r_check
        for _r_check in "${_rdc_initial_reviewers[@]}"; do
            local _is_active=0
            local _ar
            for _ar in ${_rdc_round1_active[@]+"${_rdc_round1_active[@]}"}; do
                if [[ "$_ar" == "$_r_check" ]]; then
                    _is_active=1
                    break
                fi
            done
            if [[ $_is_active -eq 0 ]]; then
                echo "    - $_r_check" >&2
            fi
        done
        _rdc_mark_state_degraded
        _rdc_degraded_exit
    fi

    # ======================================================================
    # Round 2: build per-recipient anonymized peer blocks + Round-2 prompts;
    # spawn only Round-1 active reviewers (terminal-abstention); wait,
    # classify.
    # ======================================================================
    local _rdc_round2_dir="$_rdc_iter_dir/round-2"
    mkdir -p "$_rdc_round2_dir"
    # Defensive cleanup: stale sentinels/JSONs from a prior re-spawn (e.g.,
    # under REVIEW_GATE_RERUN=1 in the same iteration directory) would
    # short-circuit the Round-2 wait loop before the freshly-spawned
    # reviewers wrote outputs.
    rm -f "$_rdc_round2_dir"/*.done \
          "$_rdc_round2_dir"/*.failed \
          "$_rdc_round2_dir"/*.json \
          "$_rdc_round2_dir"/*.jsonl 2>/dev/null || true

    # Build a clean source dir with only active Round-1 reviewers' augmented
    # JSONs (renamed to `<reviewer>.json` so debate_build_peer_blocks can
    # consume them via its existing per-reviewer file convention). This is
    # the simplest way to surface Round-1 abstainers as `(peer abstained)`:
    # the helper's missing-file branch triggers exactly when the per-reviewer
    # JSON is absent, so omitting abstained reviewers' JSONs from the
    # helper's source dir is sufficient.
    #
    # Why not pass `round1_dir` directly? Round-1 staging contains the raw
    # provider-wrapped reviewer outputs (codex JSONL, claude session JSON,
    # gemini JSON); a Round-1 reviewer that crashed has the raw stderr
    # dumped into `<reviewer>.json` which is non-empty but not parseable
    # as JSON. debate_build_peer_blocks's `[[ -s ... ]]` size-only check
    # would then fall into the active-peer rendering path on a malformed
    # JSON and silently emit a degraded skeleton instead of the
    # `(peer abstained)` placeholder. Using the augmented JSON dir
    # sidesteps both the wrapper-stripping question and the malformed-on-
    # crash question — the augmented JSON is parseable by construction
    # (otherwise the reviewer would have classified as abstained, hence
    # would not be in the active set whose JSONs we copy here).
    local _rdc_round1_clean="$_rdc_iter_dir/round-1-clean"
    mkdir -p "$_rdc_round1_clean"
    rm -f "$_rdc_round1_clean"/*.json 2>/dev/null || true
    local _r_active
    for _r_active in "${_rdc_round1_active[@]}"; do
        local _src="$round1_dir/${_r_active}.augmented.json"
        local _dst="$_rdc_round1_clean/${_r_active}.json"
        if ! cp "$_src" "$_dst" 2>/dev/null; then
            echo "aggregator failed: cannot stage augmented Round-1 JSON for $_r_active at $_dst" >&2
            _rdc_aggregator_fail_exit
        fi
    done

    # Build the anonymized peer block for each Round-2 recipient. Pass the
    # FULL initial reviewer set so Round-1 abstainers surface as
    # `(peer abstained)` per spec R1's terminal-abstention rule (their slot
    # appears in the rendered block; their content does not). Abstained
    # reviewers have no per-reviewer JSON in $_rdc_round1_clean, so the
    # helper's missing-JSON branch fires for them.
    if ! debate_build_peer_blocks \
            "$_rdc_round2_dir" "$_rdc_round1_clean" "${REVIEW_GATE_DEBATE_SEED:-}" \
            "${_rdc_initial_reviewers[@]}"; then
        echo "aggregator failed: debate_build_peer_blocks failed for round 2" >&2
        _rdc_aggregator_fail_exit
    fi

    # Build per-recipient Round-2 prompts (append-style: extends each
    # reviewer's Round-1 prompt with `Your Round 1 output:` + the per-
    # recipient anonymized peer block). Aborts hard on any input-missing
    # error so we never spawn a reviewer with a malformed prompt.
    local _rev
    for _rev in "${_rdc_round1_active[@]}"; do
        if ! _rdc_build_round2_prompt "$_rev" "$reviews_dir" "$round1_dir" "$_rdc_round2_dir"; then
            echo "aggregator failed: could not build Round-2 prompt for $_rev" >&2
            _rdc_aggregator_fail_exit
        fi
    done

    # Round-2 timing start (prompts built; reviewers about to spawn).
    local _rdc_r2_started_iso _rdc_r2_started_ms
    _rdc_r2_started_iso=$(_rdc_now_iso)
    _rdc_r2_started_ms=$(_rdc_now_ms)

    # Spawn Round-2 reviewers via spawn_reviewer with output_dir set to the
    # Round-2 staging dir so per-reviewer JSONs/sentinels land there
    # rather than in the canonical $REVIEWS_DIR (canonical-emptiness
    # invariant — Round 2 outputs only get promoted after final
    # aggregation succeeds).
    local _rdc_schema_file="$reviews_dir/review-schema.json"
    local -a _rdc_round2_spawned=()
    local -a _rdc_round2_spawn_failed=()
    for _rev in "${_rdc_round1_active[@]}"; do
        local _r2_prompt="$_rdc_round2_dir/review.${_rev}.prompt"
        if spawn_reviewer "$_rev" "$_rev" "$_r2_prompt" "$_rdc_schema_file" "$_rdc_round2_dir"; then
            _rdc_round2_spawned+=("$_rev")
        else
            echo "warning: spawn_reviewer failed for $_rev in round 2 (no Round-2 sentinel will appear; reviewer pruned from state and treated as abstained)" >&2
            _rdc_round2_spawn_failed+=("$_rev")
        fi
    done

    # Prune peer-round spawn-failed reviewers from gate-state.json's
    # reviewers map immediately. Without this prune the Stop-hook's wait
    # loop would block waiting for a sentinel that no detached process
    # will ever produce — `_rdc_classify_round_outputs` only iterates the
    # SPAWNED set, so spawn-failed reviewers never reach the round's
    # abstained list and never get pruned by the later post-classify
    # prune call.
    if [[ ${#_rdc_round2_spawn_failed[@]} -gt 0 ]]; then
        _rdc_prune_state_reviewers "${_rdc_round2_spawn_failed[@]}"
    fi

    # spawn_reviewer for every Round-1 active reviewer should have
    # succeeded (the Round-1 spawn already passed for the same reviewer);
    # a sudden runtime CLI failure here is rare but possible. Defensive
    # eligibility re-check: with fewer than 2 successful Round-2 spawns
    # the run is degraded.
    if [[ ${#_rdc_round2_spawned[@]} -lt 2 ]]; then
        echo "debate degraded below 2 active reviewers in the final peer round" >&2
        echo "  Round-2 spawn attempts succeeded for: ${_rdc_round2_spawned[*]:-(none)}" >&2
        if [[ ${#_rdc_round2_spawn_failed[@]} -gt 0 ]]; then
            echo "  Round-2 spawn attempts failed for: ${_rdc_round2_spawn_failed[*]+${_rdc_round2_spawn_failed[*]}}" >&2
        fi
        _rdc_mark_state_degraded
        _rdc_degraded_exit
    fi

    # Wait for Round-2 sentinels. Same budget-as-Mode-A semantics as the
    # Round-1 wait above: a reviewer that hangs past the round budget is
    # classified as Mode A abstain (terminal); the run continues if at
    # least 2 active final-round reviewers remain (Option B).
    if ! _rdc_wait_round_sentinels "$_rdc_round2_dir" "$timeout_sec" "$poll_interval" "${_rdc_round2_spawned[@]}"; then
        echo "warning: round-2 sentinel wait budget elapsed (${timeout_sec}s); reviewers without sentinels will be classified as Mode A abstain (Option B exclusion from final aggregation)" >&2
    fi

    # Classify Round-2 outputs. Reviewers with .failed sentinel, missing
    # output, unparseable JSON, or missing findings/verdict abstain (Mode
    # A). Active reviewers get an augmented JSON with confidence defaults
    # applied (Mode B).
    local -a _rdc_round2_active=()
    local -a _rdc_round2_abstained=()
    while IFS= read -r _line; do
        [[ -z "$_line" ]] && continue
        _r="${_line%% *}"
        _status="${_line##* }"
        if [[ "$_status" == "active" ]]; then
            _rdc_round2_active+=("$_r")
        else
            _rdc_round2_abstained+=("$_r")
        fi
    done < <(_rdc_classify_round_outputs "$_rdc_round2_dir" "${_rdc_round2_spawned[@]}")

    # Prune Round-2 abstainers from gate-state.json's reviewers map: under
    # final-round Option B they are excluded from the final aggregation
    # entirely (no per-reviewer JSON or sentinel promoted to $REVIEWS_DIR);
    # without pruning, the Stop-hook would block waiting for the absent
    # sentinel.
    if [[ ${#_rdc_round2_abstained[@]} -gt 0 ]]; then
        _rdc_prune_state_reviewers "${_rdc_round2_abstained[@]}"
    fi

    # Record Round-2 telemetry. Reviewers waited on for this round = the
    # set actually spawned (`_rdc_round2_spawned`); active set =
    # `_rdc_round2_active`. Recording happens BEFORE the final-round
    # eligibility check so partial telemetry on a Round-2-degraded run
    # captures the Round-2 entries.
    local _rdc_r2_finished_iso _rdc_r2_finished_ms _rdc_r2_wall_ms
    _rdc_r2_finished_iso=$(_rdc_now_iso)
    _rdc_r2_finished_ms=$(_rdc_now_ms)
    _rdc_r2_wall_ms=$(( _rdc_r2_finished_ms - _rdc_r2_started_ms ))
    if [[ $_rdc_r2_wall_ms -lt 0 ]]; then _rdc_r2_wall_ms=0; fi
    _rdc_record_round 2 \
        "$_rdc_r2_started_iso" "$_rdc_r2_finished_iso" "$_rdc_r2_wall_ms" \
        "$_rdc_round2_dir" \
        "$(printf '%s,' "${_rdc_round2_spawned[@]}" | sed 's/,$//')" \
        "$(printf '%s,' "${_rdc_round2_active[@]+${_rdc_round2_active[@]}}" | sed 's/,$//')"

    # Cancel checkpoint after Round 2.
    _rdc_check_cancel_after_round

    # ======================================================================
    # Final-round Option B exclusion (spec R6): a reviewer that abstains in
    # the final peer round is fully excluded from the final aggregation.
    # No per-reviewer JSON is written for them into $REVIEWS_DIR; their
    # earlier-round outputs live in iterations/<iter>/round-1/ telemetry
    # only. Their slot is absent from aggregate.json's reviewers[] and
    # their findings do not contribute.
    # ======================================================================
    if [[ ${#_rdc_round2_active[@]} -lt 2 ]]; then
        echo "debate degraded below 2 active reviewers in the final peer round" >&2
        echo "  Round-2 active: ${_rdc_round2_active[*]:-(none)}" >&2
        echo "  Round-2 abstained (Option B exclusion would apply if final-round count >=2): " >&2
        local _r_check
        for _r_check in "${_rdc_round2_spawned[@]}"; do
            local _is_active=0
            local _ar
            for _ar in ${_rdc_round2_active[@]+"${_rdc_round2_active[@]}"}; do
                if [[ "$_ar" == "$_r_check" ]]; then
                    _is_active=1
                    break
                fi
            done
            if [[ $_is_active -eq 0 ]]; then
                echo "    - $_r_check" >&2
            fi
        done
        _rdc_mark_state_degraded
        _rdc_degraded_exit
    fi

    # ======================================================================
    # Round 3 (only under `--mode max`). Spec R6 + Section 2: Round 3 is the
    # final peer round under max mode. Eligibility check: Round-2 active
    # count >= 2 (already enforced by the Final-round Option B check above).
    # That count is exactly the spec's "≥2 reviewers non-abstained across
    # Round 1 AND Round 2" — Round-1 abstainers were pruned from Round-2
    # spawn (terminal-abstention rule), and Round-2 abstainers are already
    # excluded from `_rdc_round2_active`. Hard-error on degraded-below-2
    # fires BEFORE any model invocation: spawn budget is preserved.
    #
    # Wiring map (per spec R2 / Section 2):
    #   - Round-2 outputs (in iterations/<iter>/round-2/) →
    #       T007 anonymization pass with reshuffled per-recipient
    #       ordering → PEER_BLOCK_<recipient> for Round 3
    #   - Reviewer R's Round-2 output → PRIOR_ROUND_SELF_BLOCK for Round 3
    #     (Round-1 output NOT injected — most recent prior round only)
    #   - Round 3 outputs → final aggregator → aggregate.json
    # ======================================================================
    local -a _rdc_final_active=()
    local _rdc_final_dir
    local _rdc_rounds_consumed
    if [[ $_rdc_max_rounds -ge 3 ]]; then
        local _rdc_round3_dir="$_rdc_iter_dir/round-3"
        mkdir -p "$_rdc_round3_dir"
        # Defensive cleanup: stale sentinels/JSONs from a prior re-spawn
        # in the same iteration directory would short-circuit the Round-3
        # wait loop. Mirrors the Round-2 cleanup above.
        rm -f "$_rdc_round3_dir"/*.done \
              "$_rdc_round3_dir"/*.failed \
              "$_rdc_round3_dir"/*.json \
              "$_rdc_round3_dir"/*.jsonl 2>/dev/null || true

        # Stage active Round-2 augmented JSONs as `<reviewer>.json` for
        # debate_build_peer_blocks's per-reviewer file convention. Same
        # rationale as the round-1-clean stage above (avoid wrapping +
        # Mode-A-on-crash ambiguity from the raw round-2 staging dir).
        local _rdc_round2_clean="$_rdc_iter_dir/round-2-clean"
        mkdir -p "$_rdc_round2_clean"
        rm -f "$_rdc_round2_clean"/*.json 2>/dev/null || true
        local _r_active2
        for _r_active2 in "${_rdc_round2_active[@]}"; do
            local _src2="$_rdc_round2_dir/${_r_active2}.augmented.json"
            local _dst2="$_rdc_round2_clean/${_r_active2}.json"
            if ! cp "$_src2" "$_dst2" 2>/dev/null; then
                echo "aggregator failed: cannot stage augmented Round-2 JSON for $_r_active2 at $_dst2" >&2
                _rdc_aggregator_fail_exit
            fi
        done

        # Build per-recipient anonymized peer blocks for Round 3 over the
        # FULL initial reviewer set so any Round-1 OR Round-2 abstainer's
        # slot surfaces as `(peer abstained)` in the Round-3 peer block
        # (per spec R1's terminal-abstention rule + the stable-Peer-X
        # contract: opaque peer IDs MUST be assigned over the same input
        # set in every round so a recipient sees the same Peer-X label
        # for the same model across all rounds). Abstained reviewers
        # have no augmented JSON in $_rdc_round2_clean (we only copied
        # Round-2-active augmented JSONs above), so the missing-JSON
        # branch in debate_build_peer_blocks fires for them and they
        # render as the abstain placeholder. Per-recipient ordering is
        # reshuffled per T007's seeded/production rules.
        if ! debate_build_peer_blocks \
                "$_rdc_round3_dir" "$_rdc_round2_clean" "${REVIEW_GATE_DEBATE_SEED:-}" \
                "${_rdc_initial_reviewers[@]}"; then
            echo "aggregator failed: debate_build_peer_blocks failed for round 3" >&2
            _rdc_aggregator_fail_exit
        fi

        # Build per-recipient Round-3 prompts (Round-2-output self block +
        # fresh peer block; same anchor + strategy directive as Rounds 1/2).
        local _rev3
        for _rev3 in "${_rdc_round2_active[@]}"; do
            if ! _rdc_build_round3_prompt "$_rev3" "$reviews_dir" "$_rdc_round2_dir" "$_rdc_round3_dir"; then
                echo "aggregator failed: could not build Round-3 prompt for $_rev3" >&2
                _rdc_aggregator_fail_exit
            fi
        done

        # Round-3 timing start (prompts built; reviewers about to spawn).
        local _rdc_r3_started_iso _rdc_r3_started_ms
        _rdc_r3_started_iso=$(_rdc_now_iso)
        _rdc_r3_started_ms=$(_rdc_now_ms)

        # Spawn Round-3 reviewers with output_dir = round-3 staging.
        local _rdc_schema_file3="$reviews_dir/review-schema.json"
        local -a _rdc_round3_spawned=()
        local -a _rdc_round3_spawn_failed=()
        for _rev3 in "${_rdc_round2_active[@]}"; do
            local _r3_prompt="$_rdc_round3_dir/review.${_rev3}.prompt"
            if spawn_reviewer "$_rev3" "$_rev3" "$_r3_prompt" "$_rdc_schema_file3" "$_rdc_round3_dir"; then
                _rdc_round3_spawned+=("$_rev3")
            else
                echo "warning: spawn_reviewer failed for $_rev3 in round 3 (no Round-3 sentinel will appear; reviewer pruned from state and treated as abstained)" >&2
                _rdc_round3_spawn_failed+=("$_rev3")
            fi
        done

        # Prune peer-round spawn-failed reviewers from gate-state.json's
        # reviewers map immediately. Without this prune the Stop-hook's
        # wait loop would block waiting for a sentinel that no detached
        # process will ever produce — `_rdc_classify_round_outputs` only
        # iterates the SPAWNED set, so spawn-failed reviewers never reach
        # the round's abstained list and never get pruned by the later
        # post-classify prune call.
        if [[ ${#_rdc_round3_spawn_failed[@]} -gt 0 ]]; then
            _rdc_prune_state_reviewers "${_rdc_round3_spawn_failed[@]}"
        fi

        if [[ ${#_rdc_round3_spawned[@]} -lt 2 ]]; then
            echo "debate degraded below 2 active reviewers in the final peer round" >&2
            echo "  Round-3 spawn attempts succeeded for: ${_rdc_round3_spawned[*]:-(none)}" >&2
            if [[ ${#_rdc_round3_spawn_failed[@]} -gt 0 ]]; then
                echo "  Round-3 spawn attempts failed for: ${_rdc_round3_spawn_failed[*]+${_rdc_round3_spawn_failed[*]}}" >&2
            fi
            _rdc_mark_state_degraded
            _rdc_degraded_exit
        fi

        # Wait for Round-3 sentinels. Same budget-as-Mode-A semantics as
        # earlier rounds: a reviewer that hangs past the round budget is
        # classified as Mode A abstain (Option B exclusion from final
        # aggregation).
        if ! _rdc_wait_round_sentinels "$_rdc_round3_dir" "$timeout_sec" "$poll_interval" "${_rdc_round3_spawned[@]}"; then
            echo "warning: round-3 sentinel wait budget elapsed (${timeout_sec}s); reviewers without sentinels will be classified as Mode A abstain (Option B exclusion from final aggregation)" >&2
        fi

        # Classify Round-3 outputs.
        local -a _rdc_round3_active=()
        local -a _rdc_round3_abstained=()
        while IFS= read -r _line; do
            [[ -z "$_line" ]] && continue
            _r="${_line%% *}"
            _status="${_line##* }"
            if [[ "$_status" == "active" ]]; then
                _rdc_round3_active+=("$_r")
            else
                _rdc_round3_abstained+=("$_r")
            fi
        done < <(_rdc_classify_round_outputs "$_rdc_round3_dir" "${_rdc_round3_spawned[@]}")

        if [[ ${#_rdc_round3_abstained[@]} -gt 0 ]]; then
            _rdc_prune_state_reviewers "${_rdc_round3_abstained[@]}"
        fi

        # Record Round-3 telemetry. Recording happens BEFORE the final-round
        # eligibility check so partial telemetry on a Round-3-degraded run
        # captures the Round-3 entries.
        local _rdc_r3_finished_iso _rdc_r3_finished_ms _rdc_r3_wall_ms
        _rdc_r3_finished_iso=$(_rdc_now_iso)
        _rdc_r3_finished_ms=$(_rdc_now_ms)
        _rdc_r3_wall_ms=$(( _rdc_r3_finished_ms - _rdc_r3_started_ms ))
        if [[ $_rdc_r3_wall_ms -lt 0 ]]; then _rdc_r3_wall_ms=0; fi
        _rdc_record_round 3 \
            "$_rdc_r3_started_iso" "$_rdc_r3_finished_iso" "$_rdc_r3_wall_ms" \
            "$_rdc_round3_dir" \
            "$(printf '%s,' "${_rdc_round3_spawned[@]}" | sed 's/,$//')" \
            "$(printf '%s,' "${_rdc_round3_active[@]+${_rdc_round3_active[@]}}" | sed 's/,$//')"

        # Cancel checkpoint after Round 3.
        _rdc_check_cancel_after_round

        # Final-round Option B (Round 3 is the final peer round under
        # --mode max): Round-3 abstainers are excluded entirely from the
        # final aggregation. If the active count drops below 2, the run
        # is degraded-below-2 in the final peer round.
        if [[ ${#_rdc_round3_active[@]} -lt 2 ]]; then
            echo "debate degraded below 2 active reviewers in the final peer round" >&2
            echo "  Round-3 active: ${_rdc_round3_active[*]:-(none)}" >&2
            echo "  Round-3 abstained (Option B exclusion): " >&2
            local _r_check3
            for _r_check3 in "${_rdc_round3_spawned[@]}"; do
                local _is_active3=0
                local _ar3
                for _ar3 in ${_rdc_round3_active[@]+"${_rdc_round3_active[@]}"}; do
                    if [[ "$_ar3" == "$_r_check3" ]]; then
                        _is_active3=1
                        break
                    fi
                done
                if [[ $_is_active3 -eq 0 ]]; then
                    echo "    - $_r_check3" >&2
                fi
            done
            _rdc_mark_state_degraded
            _rdc_degraded_exit
        fi

        _rdc_final_dir="$_rdc_round3_dir"
        _rdc_rounds_consumed=3
        _rdc_final_active=("${_rdc_round3_active[@]}")
    else
        _rdc_final_dir="$_rdc_round2_dir"
        _rdc_rounds_consumed=2
        _rdc_final_active=("${_rdc_round2_active[@]}")
    fi

    # ======================================================================
    # Final aggregation over the final-round outputs (active final-round
    # reviewers only — Option B). T009's confidence-weighted dedup +
    # canonical merge order pass runs inside _rdc_aggregate_and_promote.
    # On any aggregator failure, _rdc_aggregate_and_promote calls
    # _rdc_aggregator_fail_exit directly (writes partial telemetry, exits 5).
    # The function returns 0 only on full success.
    # ======================================================================
    if ! _rdc_aggregate_and_promote \
            "$_rdc_final_dir" "$reviews_dir" \
            "$consensus_mode" "$_rdc_rounds_consumed" \
            "${_rdc_final_active[@]}"; then
        # Defensive: _rdc_aggregate_and_promote should have already exited
        # via _rdc_aggregator_fail_exit. If it returned non-zero by some
        # other path, surface the exit anyway.
        echo "aggregator failed: _rdc_aggregate_and_promote returned non-zero" >&2
        _rdc_aggregator_fail_exit
    fi

    # ----------------------------------------------------------------------
    # Success path: uninstall the SIGINT trap so a SIGINT delivered during
    # the brief wrap-up window between debate-block-write and bin/review-gate's
    # post-coordinator echos cannot fire `_rdc_handle_sigint` and write a
    # spurious partial-telemetry file (which would contradict the
    # success-only contract for gate-state.json.debate). After the trap
    # is uninstalled, write the canonical debate block. The jq patch
    # preserves existing top-level fields, so the Stop-hook's subsequent
    # .status / .consensus mutations leave .debate byte-stable (asserted
    # by test_debate_block_survives_stop_hook). The success path MUST
    # NOT write iterations/<iter>/debate-telemetry.json — presence of
    # that file is the unambiguous signal of a non-success debate run.
    # ----------------------------------------------------------------------
    trap - INT
    _rdc_write_gate_state_debate_block

    return 0
}

# _rdc_aggregate_and_promote — stub aggregator + atomic promotion of the
# active final-round reviewers' augmented JSONs (and the cross-reviewer
# `aggregate.json`) into the canonical $REVIEWS_DIR.
#
# This helper expects each active reviewer to have an
# `<reviewer>.augmented.json` file under $final_dir (written by
# `_rdc_classify_round_outputs` during the final-round classification).
# Augmented JSONs already have Mode B confidence defaults applied, so the
# aggregator can read them verbatim.
#
# Side effects:
#   - On success: promotes per-reviewer JSONs to $reviews_dir/<r>.json (with
#     `.staging.<pid>` intermediate names so a partial promotion never
#     surfaces a half-written reviewer JSON to the Stop-hook), writes
#     `<r>.done` sentinels, then promotes aggregate.json last so a partial-
#     promotion failure leaves no aggregate.json behind.
#   - On any aggregator error: $reviews_dir is left UNTOUCHED. Temp staging
#     files inside $reviews_dir created during the partial promotion are
#     removed via `_rdc_cleanup_temp_files`. The function returns non-zero;
#     the per-round staging dirs are preserved for inspection.
#
# Args:
#   $1  final_dir          per-round staging dir holding augmented JSONs
#   $2  reviews_dir        canonical $REVIEWS_DIR (atomic-promotion target)
#   $3  consensus_mode     majority|all|any (recorded in aggregate.json)
#   $4  rounds_consumed    integer (1, 2, or 3) — final-round number
#   $@  (5+)               active final-round reviewer canonical names
_rdc_aggregate_and_promote() {
    local final_dir="$1"; shift
    local reviews_dir="$1"; shift
    local consensus_mode="$1"; shift
    local rounds_consumed="$1"; shift
    local -a active_reviewers=("$@")

    local -a _aap_promoted_temp_files=()
    local -a _aap_promoted_target_files=()
    local -a _aap_promoted_sentinels=()
    local _aap_strategies_json='{}'
    local _aap_candidates_json='[]'
    local _aap_verdicts_json='[]'
    local _aap_pid_suffix="$$"

    local _r _upper _strategy_var _strategy _aug_path _augmented _verdict _oc
    local _final_json _findings_with_reviewer
    for _r in "${active_reviewers[@]}"; do
        _upper=$(echo "$_r" | tr '[:lower:]' '[:upper:]')
        _strategy_var="STRATEGY_NAME_${_upper}"
        _strategy="${!_strategy_var:-verification-first}"
        _aap_strategies_json=$(printf '%s' "$_aap_strategies_json" | jq \
            --arg name "$_r" --arg strategy "$_strategy" \
            '.[$name] = $strategy') || {
            echo "aggregator failed: jq strategies bookkeeping for reviewer $_r" >&2
            _rdc_cleanup_temp_files ${_aap_promoted_temp_files[@]+"${_aap_promoted_temp_files[@]}"}
            _rdc_aggregator_fail_exit
        }

        _aug_path="$final_dir/${_r}.augmented.json"
        if [[ ! -s "$_aug_path" ]]; then
            echo "aggregator failed: missing augmented JSON for active reviewer $_r at $_aug_path" >&2
            _rdc_cleanup_temp_files ${_aap_promoted_temp_files[@]+"${_aap_promoted_temp_files[@]}"}
            _rdc_aggregator_fail_exit
        fi
        _augmented=$(cat "$_aug_path")

        # Collect any Mode B clamp notes written by _rdc_classify_round_outputs
        # (which ran in a process-substitution subshell and cannot mutate
        # _RDC_AGGREGATOR_NOTES_JSON directly). The side file contains one
        # note string per line; append each to the global notes array.
        local _clamp_note_file="$final_dir/${_r}.clamp-note.txt"
        if [[ -s "$_clamp_note_file" ]]; then
            local _clamp_line
            while IFS= read -r _clamp_line; do
                [[ -z "$_clamp_line" ]] && continue
                _rdc_append_aggregator_note "$_clamp_line"
            done < "$_clamp_note_file"
        fi

        # Detect malformed augmented JSON early and surface a canonical
        # `aggregator failed: jq parse error on reviews/<r>.json` message.
        # This is the primary aggregator-failure mode pinned in the spec
        # (Section 4 / D6) and is the failure shape exercised by the
        # T012 aggregator-failure test fixture.
        if ! printf '%s' "$_augmented" | jq -e . >/dev/null 2>&1; then
            echo "aggregator failed: jq parse error on reviews/${_r}.json" >&2
            _rdc_cleanup_temp_files ${_aap_promoted_temp_files[@]+"${_aap_promoted_temp_files[@]}"}
            _rdc_aggregator_fail_exit
        fi

        _verdict=$(printf '%s' "$_augmented" | jq -r '.verdict // ""' 2>/dev/null)
        case "$_verdict" in
            PASS|FAIL|NEEDS_WORK) ;;
            *)
                # Should be unreachable — _rdc_classify_round_outputs
                # already gates verdict to {PASS, FAIL, NEEDS_WORK}.
                echo "aggregator failed: invalid verdict '$_verdict' for reviewer $_r (post-classify)" >&2
                _rdc_cleanup_temp_files ${_aap_promoted_temp_files[@]+"${_aap_promoted_temp_files[@]}"}
                _rdc_aggregator_fail_exit
                ;;
        esac

        _oc=$(printf '%s' "$_augmented" | jq -r '.overall_confidence // 0.5' 2>/dev/null)

        # Stamp the per-reviewer JSON with the additive debate fields the
        # Stop-hook + downstream surfaces expect.  peer_responses_seen was
        # already injected by _rdc_classify_round_outputs from the
        # coordinator-written peer-ids.<reviewer>.txt file; the `.// []`
        # here is purely defensive (the augmented JSON always has the field
        # stamped by that path, so this fallback is never reached in
        # normal operation).
        _final_json=$(printf '%s' "$_augmented" | jq \
            --arg strategy "$_strategy" \
            --argjson rnd "$rounds_consumed" \
            '. + {
                strategy: $strategy,
                round: $rnd,
                peer_responses_seen: (.peer_responses_seen // [])
            }') || {
            echo "aggregator failed: jq stamp additive fields for $_r" >&2
            _rdc_cleanup_temp_files ${_aap_promoted_temp_files[@]+"${_aap_promoted_temp_files[@]}"}
            _rdc_aggregator_fail_exit
        }

        local _tmp_path="$reviews_dir/.${_r}.json.staging.$_aap_pid_suffix"
        local _target_path="$reviews_dir/${_r}.json"
        local _sentinel_path="$reviews_dir/${_r}.done"
        if ! printf '%s\n' "$_final_json" > "$_tmp_path"; then
            echo "aggregator failed: cannot stage augmented JSON for $_r at $_tmp_path" >&2
            _rdc_cleanup_temp_files ${_aap_promoted_temp_files[@]+"${_aap_promoted_temp_files[@]}"} "$_tmp_path"
            _rdc_aggregator_fail_exit
        fi

        _aap_promoted_temp_files+=("$_tmp_path")
        _aap_promoted_target_files+=("$_target_path")
        _aap_promoted_sentinels+=("$_sentinel_path")

        # Tag this reviewer's findings with `_reviewer` so the candidate
        # pool for the dedup pass can pre-sort by `(priority asc,
        # confidence desc, reviewer asc)` and pick a primary deterministically.
        # Per-reviewer JSONs themselves are NOT cross-reviewer-deduped — the
        # `_reviewer` tag is internal to the candidate pool only.
        _findings_with_reviewer=$(printf '%s' "$_final_json" | jq \
            --arg name "$_r" \
            '(.findings // []) | map(. + {_reviewer: $name})' 2>/dev/null) || _findings_with_reviewer='[]'
        _aap_candidates_json=$(jq -c --argjson new "$_findings_with_reviewer" '. + $new' <<< "$_aap_candidates_json") || {
            echo "aggregator failed: jq merge findings for $_r" >&2
            _rdc_cleanup_temp_files ${_aap_promoted_temp_files[@]+"${_aap_promoted_temp_files[@]}"}
            _rdc_aggregator_fail_exit
        }

        # Per-reviewer (verdict, overall_confidence) record for the
        # aggregate-verdict computation below. Kept as JSON to preserve
        # numeric `overall_confidence` through the pipeline.
        _aap_verdicts_json=$(printf '%s' "$_aap_verdicts_json" | jq \
            --arg r "$_r" \
            --arg v "$_verdict" \
            --argjson oc "$_oc" \
            '. + [{reviewer: $r, verdict: $v, overall_confidence: $oc}]') || {
            echo "aggregator failed: jq verdicts bookkeeping for $_r" >&2
            _rdc_cleanup_temp_files ${_aap_promoted_temp_files[@]+"${_aap_promoted_temp_files[@]}"}
            _rdc_aggregator_fail_exit
        }
    done

    # ----------------------------------------------------------------------
    # Aggregate verdict (R6, spec L245+L275-L279):
    #   (a) FAIL is blocking — any FAIL → aggregate.json.verdict = FAIL.
    #   (b) Otherwise: consensus mode determines PASS/NEEDS_WORK.
    #       majority — modal verdict wins; PASS/NEEDS_WORK tie broken by
    #         overall_confidence (sum-of-confidences per verdict so a 1-1
    #         split between two reviewers reduces to "higher single
    #         confidence wins").
    #       all      — any NEEDS_WORK → NEEDS_WORK; else PASS.
    #       any      — any PASS → PASS; else NEEDS_WORK.
    #   (c) `requires_decision` MUST NEVER appear here. The aggregate
    #       verdict's value space is strictly {PASS|NEEDS_WORK|FAIL}.
    # The Stop-hook's per-reviewer priority+consensus calculator (which
    # writes gate-state.json.consensus.verdict — including
    # `requires_decision` for P0/P1 priority gates) is a separate surface;
    # the aggregator never produces `requires_decision`.
    # ----------------------------------------------------------------------
    local _aap_agg_verdict
    if ! _aap_agg_verdict=$(printf '%s' "$_aap_verdicts_json" | jq -r --arg mode "$consensus_mode" '
        if length == 0 then "ERROR_EMPTY"
        elif any(.[]; .verdict == "FAIL") then "FAIL"
        elif $mode == "all" then
            (if any(.[]; .verdict == "NEEDS_WORK") then "NEEDS_WORK" else "PASS" end)
        elif $mode == "any" then
            (if any(.[]; .verdict == "PASS") then "PASS" else "NEEDS_WORK" end)
        else
            # majority: pick highest count; tiebreak by sum-of-confidence
            # desc; final tiebreak by verdict name asc for byte-determinism.
            (group_by(.verdict)
             | map({verdict: .[0].verdict,
                    count: length,
                    conf_sum: ([.[] | .overall_confidence] | add)})
             | sort_by([-(.count), -(.conf_sum), .verdict])
             | .[0].verdict)
        end
    '); then
        echo "aggregator failed: jq aggregate verdict computation" >&2
        _rdc_cleanup_temp_files ${_aap_promoted_temp_files[@]+"${_aap_promoted_temp_files[@]}"}
        _rdc_aggregator_fail_exit
    fi
    if [[ "$_aap_agg_verdict" == "ERROR_EMPTY" || -z "$_aap_agg_verdict" ]]; then
        echo "aggregator failed: no valid verdicts collected from final-round reviewers" >&2
        _rdc_cleanup_temp_files ${_aap_promoted_temp_files[@]+"${_aap_promoted_temp_files[@]}"}
        _rdc_aggregator_fail_exit
    fi
    # Defensive: enforce the pinned three-value enum. The aggregator MUST
    # never emit `requires_decision` (that surface lives in
    # gate-state.json.consensus.verdict, not aggregate.json.verdict).
    case "$_aap_agg_verdict" in
        PASS|NEEDS_WORK|FAIL) ;;
        *)
            echo "aggregator failed: invalid aggregate verdict '$_aap_agg_verdict' (must be one of PASS|NEEDS_WORK|FAIL)" >&2
            _rdc_cleanup_temp_files ${_aap_promoted_temp_files[@]+"${_aap_promoted_temp_files[@]}"}
            _rdc_aggregator_fail_exit
            ;;
    esac

    # Detect majority-mode confidence tiebreak: when the two leading
    # verdict groups have equal counts, the winner was chosen by
    # confidence sum rather than plurality. Emit a note so consumers
    # can see that a tiebreak resolved the verdict.
    if [[ "$consensus_mode" == "majority" ]]; then
        local _aap_tiebreak
        _aap_tiebreak=$(printf '%s' "$_aap_verdicts_json" | jq -r '
            if any(.[]; .verdict == "FAIL") then "no"
            else
                (group_by(.verdict)
                 | map({verdict: .[0].verdict, count: length})
                 | sort_by(-.count)
                 | if (length >= 2) and (.[0].count == .[1].count) then "yes"
                   else "no" end)
            end
        ' 2>/dev/null || echo "no")
        if [[ "$_aap_tiebreak" == "yes" ]]; then
            _rdc_append_aggregator_note "tiebreak by confidence"
        fi
    fi

    # ----------------------------------------------------------------------
    # Confidence-weighted dedup pass (R6, spec L247-L255):
    #
    #   Predicate (4 conditions, ALL must hold):
    #     1. A.priority == B.priority
    #     2. file_path non-null on both AND equal (case-sensitive).
    #     3. line_start non-null on both, line_end non-null on both,
    #        integer ranges overlap.
    #     4. lowercase(A.title) == lowercase(B.title) after stripping the
    #        leading [Px] tag (POSIX ERE: ^[[:space:]]*\[P[0-3]\][[:space:]]*)
    #        and trimming surrounding whitespace.
    #
    #   Canonical merge order:
    #     (1) Global pre-sort over all candidates by composite key
    #         (priority asc, confidence desc, reviewer canonical name asc).
    #         claude < codex < gemini under standard lex order.
    #     (2) Greedy fold: iterate sorted list. For each unmerged F, mark F
    #         as a new primary; scan subsequent unmerged candidates and
    #         merge any F'' that satisfies the predicate against F.
    #
    #   Merge rule:
    #     - F's body is the primary body (highest confidence by pre-sort;
    #       alphabetical reviewer-name tiebreak at equal confidence).
    #     - Each F'' body is appended under one "Also raised by another
    #       reviewer:" subsection of F's body, in fold-iteration order.
    #     - Merged finding inherits F's priority, title, file_path,
    #       line_start, line_end, confidence.
    #     - `raised_by` is the set union (deduplicated) of canonical
    #       reviewer names; present only on merged entries (≥2 reviewers).
    # ----------------------------------------------------------------------
    local _aap_findings_json
    if ! _aap_findings_json=$(printf '%s' "$_aap_candidates_json" | jq -c '
        def normalize_title:
          (. // "")
          | sub("^[[:space:]]*\\[P[0-3]\\][[:space:]]*"; "")
          | sub("^[[:space:]]+"; "")
          | sub("[[:space:]]+$"; "")
          | ascii_downcase;
        # Reviewer schema (bin/review-gate-models.sh) enforces integer
        # priority 0..3. Normalize both numeric `0..3` and string
        # `"P0".."P3"` to canonical string form so sort, dedup, and
        # summary counters all see the same shape regardless of which
        # form the reviewer emitted. Out-of-range / unparseable values
        # become null (excluded from P0..P3 counters; sorted to the
        # bottom via pri_idx 99).
        def to_pri_str:
          if . == null then null
          elif type == "number" then
            (if . == 0 then "P0"
             elif . == 1 then "P1"
             elif . == 2 then "P2"
             elif . == 3 then "P3"
             else null end)
          elif type == "string" then
            (if test("^P[0-3]$") then .
             else null end)
          else null end;
        def pri_idx:
          if . == "P0" then 0
          elif . == "P1" then 1
          elif . == "P2" then 2
          elif . == "P3" then 3
          else 99 end;
        # Cross-reviewer dedup predicate. Same-reviewer findings are
        # NEVER folded — the spec explicitly scopes the predicate to
        # findings from *different* reviewers ("Two findings A and B
        # from different reviewers MUST be considered duplicates if and
        # only if..."). Without the `_reviewer` inequality, a reviewer
        # that emits two same-title same-location findings would be
        # collapsed into a single primary with a `raised_by` length of
        # 1, violating the "≥2 reviewers" rule for `raised_by`.
        def is_dup(A; B):
          (A._reviewer != B._reviewer)
          and (A.priority == B.priority)
          and (A.file_path != null) and (B.file_path != null)
          and (A.file_path == B.file_path)
          and (A.line_start != null) and (A.line_end != null)
          and (B.line_start != null) and (B.line_end != null)
          and (A.line_start <= B.line_end) and (B.line_start <= A.line_end)
          and ((A.title | normalize_title) == (B.title | normalize_title));
        # Normalize priority on each candidate before sorting / merging /
        # output. The original priority is overwritten by its normalized
        # form so the resulting `aggregate.json.findings[*].priority` is
        # always the canonical string `"P0".."P3"` (matching the
        # aggregate.json shape example in spec L222). Per-reviewer JSONs
        # written to $REVIEWS_DIR are NOT mutated — they retain whatever
        # form the reviewer emitted, so the Stop-hook (which expects
        # numeric priority) keeps working unchanged.
        ([.[] | .priority = (.priority | to_pri_str)]) as $cands
        # (1) Global pre-sort. Stable composite key: priority asc,
        # confidence desc, reviewer canonical name asc.
        | ($cands | sort_by([(.priority | pri_idx),
                             -((.confidence // 0.5)),
                             ._reviewer])) as $sorted
        # (2) Greedy fold. Track primaries (in fold-iteration order) and a
        # set of merged-into-something indices. The state at the start of
        # iteration $i is read for the inner scan; new merges added during
        # $i become visible to subsequent $i values. This single-pass fold
        # is jq-iteration-order-independent because it operates only on the
        # pre-sorted list.
        | reduce range(0; ($sorted | length)) as $i (
            {primaries: [], merged: {}};
            if (.merged[($i|tostring)] // false) then .
            else
              . as $st
              | $sorted[$i] as $p
              | [ range($i+1; ($sorted | length)) as $j
                  | select((($st.merged[($j|tostring)] // false) | not)
                           and is_dup($p; $sorted[$j]))
                  | {idx: $j, finding: $sorted[$j]} ] as $ms
              | .primaries += [{primary: $p, merges: $ms}]
              | reduce $ms[] as $m (.; .merged[($m.idx|tostring)] = true)
            end
          )
        | .primaries
        | map(
            .primary as $p
            | .merges as $ms
            | if ($ms | length) == 0 then
                # Single-reviewer finding — `raised_by` is absent (per
                # spec: "absent on single-reviewer findings"). The
                # internal `_reviewer` tag is dropped from the output.
                {priority: $p.priority,
                 title: $p.title,
                 body: $p.body,
                 file_path: $p.file_path,
                 line_start: $p.line_start,
                 line_end: $p.line_end,
                 confidence: $p.confidence}
              else
                # Merged finding. Append the "Also raised by another reviewer:"
                # subsection containing each F-prime body in fold order.
                # The `raised_by` field is the deduplicated set union of
                # canonical reviewer names rendered in canonical
                # alphabetical order (jq `unique` sorts the array; the
                # spec describes raised_by as a set union and does not
                # pin the array ordering, so the alphabetical render
                # matches the alphabetical ordering already used for
                # aggregate.json reviewers list for visual consistency).
                # Because is_dup excludes same-reviewer pairs, the
                # union always contains at least 2 distinct reviewer
                # names when this branch fires (no risk of length-1
                # raised_by entries).
                {priority: $p.priority,
                 title: $p.title,
                 body: (
                   ($p.body // "")
                   + "\n\nAlso raised by another reviewer:\n\n"
                   + ([$ms[] | (.finding.body // "")] | join("\n\n"))
                 ),
                 file_path: $p.file_path,
                 line_start: $p.line_start,
                 line_end: $p.line_end,
                 confidence: $p.confidence,
                 raised_by: ([$p._reviewer] + [$ms[] | .finding._reviewer]
                             | unique)
                }
              end
          )
    '); then
        echo "aggregator failed: jq dedup pass" >&2
        _rdc_cleanup_temp_files ${_aap_promoted_temp_files[@]+"${_aap_promoted_temp_files[@]}"}
        _rdc_aggregator_fail_exit
    fi

    # Emit one aggregator note per merged (near-duplicate) finding — i.e.,
    # any finding whose `raised_by` array has length ≥ 2. The note format is:
    #   "near-duplicate merged: <priority> <title> (<reviewers joined by +>)"
    # Wording is intentionally human-readable; consumers MUST NOT pattern-match
    # on exact text (spec §4 line 355).
    local _aap_merge_notes
    _aap_merge_notes=$(printf '%s' "$_aap_findings_json" | jq -r '
        .[]
        | select((.raised_by // []) | length >= 2)
        | "near-duplicate merged: " + (.priority // "?") + " " + (.title // "") +
          " (" + ((.raised_by // []) | sort | join("+")) + ")"
    ' 2>/dev/null || true)
    if [[ -n "$_aap_merge_notes" ]]; then
        local _merge_note_line
        while IFS= read -r _merge_note_line; do
            [[ -z "$_merge_note_line" ]] && continue
            _rdc_append_aggregator_note "$_merge_note_line"
        done <<< "$_aap_merge_notes"
    fi

    # ----------------------------------------------------------------------
    # Active reviewers list (canonical alphabetical order). `strategies`
    # is already keyed by reviewer name; we trust the upstream call (only
    # active final-round reviewers in active_reviewers[]) to keep the
    # `strategies` map limited to the `reviewers[]` set per spec.
    # ----------------------------------------------------------------------
    local _aap_active_sorted
    _aap_active_sorted=$(printf '%s\n' "${active_reviewers[@]}" | LC_ALL=C sort)
    local _aap_active_json='[]'
    local _aap_r
    while IFS= read -r _aap_r; do
        [[ -z "$_aap_r" ]] && continue
        _aap_active_json=$(printf '%s' "$_aap_active_json" | jq --arg n "$_aap_r" '. + [$n]')
    done <<< "$_aap_active_sorted"

    # ----------------------------------------------------------------------
    # Deterministic summary template (spec R6 + plan L213-L240):
    #   "<verdict> from <N> active final-round reviewers (<csv>);
    #    <findings_count> unique findings (P0:<n0> P1:<n1> P2:<n2> P3:<n3>);
    #    avg overall_confidence <x.xx>."
    # avg confidence is the arithmetic mean of per-reviewer
    # overall_confidence rendered to two decimals.
    # ----------------------------------------------------------------------
    local _aap_csv
    _aap_csv=$(printf '%s' "$_aap_active_sorted" | awk 'BEGIN{first=1} NF>0 { if (first) {printf "%s", $0; first=0} else {printf ", %s", $0} }')

    local _aap_n="${#active_reviewers[@]}"
    local _aap_findings_count _aap_p0 _aap_p1 _aap_p2 _aap_p3
    _aap_findings_count=$(printf '%s' "$_aap_findings_json" | jq 'length' 2>/dev/null || echo "0")
    _aap_p0=$(printf '%s' "$_aap_findings_json" | jq '[.[] | select(.priority == "P0")] | length' 2>/dev/null || echo "0")
    _aap_p1=$(printf '%s' "$_aap_findings_json" | jq '[.[] | select(.priority == "P1")] | length' 2>/dev/null || echo "0")
    _aap_p2=$(printf '%s' "$_aap_findings_json" | jq '[.[] | select(.priority == "P2")] | length' 2>/dev/null || echo "0")
    _aap_p3=$(printf '%s' "$_aap_findings_json" | jq '[.[] | select(.priority == "P3")] | length' 2>/dev/null || echo "0")

    local _aap_avg_raw
    _aap_avg_raw=$(printf '%s' "$_aap_verdicts_json" | jq -r '
        if length == 0 then 0
        else (([.[] | .overall_confidence] | add) / length) end' 2>/dev/null)
    local _aap_avg_oc
    _aap_avg_oc=$(LC_ALL=C awk -v v="${_aap_avg_raw:-0}" 'BEGIN { printf "%.2f", v }')

    local _aap_summary
    _aap_summary=$(printf '%s from %d active final-round reviewers (%s); %d unique findings (P0:%d P1:%d P2:%d P3:%d); avg overall_confidence %s.' \
        "$_aap_agg_verdict" "$_aap_n" "$_aap_csv" \
        "$_aap_findings_count" "$_aap_p0" "$_aap_p1" "$_aap_p2" "$_aap_p3" \
        "$_aap_avg_oc")

    local _aap_aggregate_tmp="$reviews_dir/.aggregate.json.staging.$_aap_pid_suffix"
    if ! jq -n \
        --arg verdict "$_aap_agg_verdict" \
        --arg summary "$_aap_summary" \
        --argjson findings "$_aap_findings_json" \
        --arg consensus_mode "$consensus_mode" \
        --argjson rounds_consumed "$rounds_consumed" \
        --argjson reviewers "$_aap_active_json" \
        --argjson strategies "$_aap_strategies_json" \
        '{
            verdict: $verdict,
            summary: $summary,
            findings: $findings,
            consensus_mode: $consensus_mode,
            rounds_consumed: $rounds_consumed,
            reviewers: $reviewers,
            strategies: $strategies
        }' > "$_aap_aggregate_tmp"; then
        echo "aggregator failed: jq could not produce aggregate.json" >&2
        _rdc_cleanup_temp_files ${_aap_promoted_temp_files[@]+"${_aap_promoted_temp_files[@]}"} "$_aap_aggregate_tmp"
        _rdc_aggregator_fail_exit
    fi

    # Atomic promotion. Per-reviewer JSON via mv first, then sentinel last.
    # aggregate.json last of all so a per-reviewer promotion failure leaves
    # no aggregate.json behind.
    local _aap_i=0
    while [[ $_aap_i -lt ${#_aap_promoted_temp_files[@]} ]]; do
        if ! mv -f "${_aap_promoted_temp_files[$_aap_i]}" "${_aap_promoted_target_files[$_aap_i]}"; then
            echo "aggregator failed: cannot promote ${_aap_promoted_temp_files[$_aap_i]} -> ${_aap_promoted_target_files[$_aap_i]}" >&2
            local _aap_j=0
            while [[ $_aap_j -lt ${#_aap_promoted_target_files[@]} ]]; do
                rm -f "${_aap_promoted_target_files[$_aap_j]}" "${_aap_promoted_sentinels[$_aap_j]}" 2>/dev/null || true
                _aap_j=$((_aap_j + 1))
            done
            _rdc_cleanup_temp_files ${_aap_promoted_temp_files[@]+"${_aap_promoted_temp_files[@]}"} "$_aap_aggregate_tmp"
            _rdc_aggregator_fail_exit
        fi
        : > "${_aap_promoted_sentinels[$_aap_i]}"
        _aap_i=$((_aap_i + 1))
    done

    if ! mv -f "$_aap_aggregate_tmp" "$reviews_dir/aggregate.json"; then
        echo "aggregator failed: cannot promote aggregate.json into $reviews_dir" >&2
        local _aap_k=0
        while [[ $_aap_k -lt ${#_aap_promoted_target_files[@]} ]]; do
            rm -f "${_aap_promoted_target_files[$_aap_k]}" "${_aap_promoted_sentinels[$_aap_k]}" 2>/dev/null || true
            _aap_k=$((_aap_k + 1))
        done
        rm -f "$_aap_aggregate_tmp" 2>/dev/null || true
        _rdc_aggregator_fail_exit
    fi

    return 0
}
