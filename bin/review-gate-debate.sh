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
    done

    return 0
}

# ---------------------------------------------------------------------------
# run_debate_coordinator — synchronous in-process coordinator (Phase D scope:
# Round 1 only, stub aggregator, atomic promotion).
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
#   - Rendered per-reviewer prompts under --debate (T005 wires per-reviewer
#     STRATEGY_NAME_<REVIEWER> bytes into each reviewer's prompt)
#   - Detached each reviewer via `spawn_reviewer` with the staging dir
#     ($staging_dir below) as the output directory, NOT the canonical
#     $REVIEWS_DIR. Per-reviewer JSONs/sentinels currently land in staging.
#
# This function then:
#
#   1. Polls for `<reviewer>.done`/`<reviewer>.failed` sentinels under
#      $staging_dir (mirrors the Stop-hook's polling pattern at
#      bin/review-gate-hook.sh ~810-830).
#   2. Phase D stub aggregator: parses each reviewer's JSON via the existing
#      `extract_json` (which handles codex/claude/gemini wrappers + repair
#      fallback), augments with per-reviewer additive fields
#      (overall_confidence, strategy, round=1, peer_responses_seen=[]), and
#      computes a single-round verdict via "most severe wins" semantics.
#      T009 replaces this stub with the real confidence-weighted dedup.
#   3. Atomic promotion: writes each augmented per-reviewer JSON to a temp
#      path inside $reviews_dir, then `mv`s into the final
#      $reviews_dir/<reviewer>.json position, then writes the
#      $reviews_dir/<reviewer>.done sentinel. Stop-hook polls for the
#      sentinel before reading the JSON, so writing the JSON BEFORE the
#      sentinel avoids the half-written-JSON race.
#   4. Writes $reviews_dir/aggregate.json after every per-reviewer JSON has
#      been promoted. The Phase D stub shape:
#        verdict, summary (placeholder; T009 replaces),
#        findings[] (simple union with raised_by per-reviewer attribution),
#        consensus_mode, rounds_consumed=1, reviewers[] (active set),
#        strategies{}.
#
# Failure handling:
#
#   On any aggregator error (parse failure, .failed sentinel, missing
#   output, jq crash), $reviews_dir is left UNTOUCHED — no per-reviewer
#   JSONs, no .done sentinels, no aggregate.json. Any temp staging files
#   under $reviews_dir created during the partial promotion are removed.
#   The function returns non-zero. Staging ($staging_dir) is preserved
#   for inspection. T012 will pin the exact exit codes (5 for aggregator
#   failure, 130 for SIGINT, 6 for degraded-below-2); for now any
#   non-zero return is surfaced to the caller.
#
# Args (positional):
#   $1  staging_dir     Per-round staging directory (e.g.,
#                       $REVIEW_DIR/iterations/<iter>/round-1/) where
#                       spawn_reviewer wrote per-reviewer outputs.
#   $2  reviews_dir     Canonical $REVIEWS_DIR (atomic-promotion target).
#   $3  consensus_mode  One of majority|all|any. Recorded in
#                       aggregate.json.consensus_mode for downstream
#                       surfaces (gate report, telemetry).
#   $4  timeout_sec     Max seconds to wait for all sentinels before
#                       erroring out (REVIEW_GATE_MAX_WAIT_SECONDS default
#                       is 1800 in `wait`; we use the same default here so
#                       the synchronous coordinator's wait budget mirrors
#                       the Stop-hook's existing budget).
#   $5  poll_interval   Seconds between polls (>=1).
#   $@  (6+)            Reviewer canonical names (active set).
#
# Returns 0 on success; non-zero on any aggregator error.
run_debate_coordinator() {
    local staging_dir="${1:-}"
    local reviews_dir="${2:-}"
    local consensus_mode="${3:-majority}"
    local timeout_sec="${4:-1800}"
    local poll_interval="${5:-3}"
    if [[ $# -lt 6 ]]; then
        echo "run_debate_coordinator: missing reviewer arguments (need at least 1)" >&2
        return 1
    fi
    shift 5
    local -a _rdc_reviewers=("$@")

    if [[ -z "$staging_dir" || ! -d "$staging_dir" ]]; then
        echo "run_debate_coordinator: staging directory missing or invalid: $staging_dir" >&2
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

    # ----------------------------------------------------------------------
    # Phase D step 4: sync-wait for all reviewer sentinels in $staging_dir.
    # Mirrors the polling pattern at bin/review-gate-hook.sh:810-830 — wait
    # until every reviewer has either a .done or .failed sentinel under
    # $staging_dir, OR the timeout budget elapses.
    # ----------------------------------------------------------------------
    local _rdc_start_time _rdc_now _rdc_elapsed _rdc_reviewer
    _rdc_start_time=$(date +%s)
    while true; do
        local _rdc_all_done="true"
        for _rdc_reviewer in "${_rdc_reviewers[@]}"; do
            if [[ ! -f "$staging_dir/${_rdc_reviewer}.done" ]] && \
               [[ ! -f "$staging_dir/${_rdc_reviewer}.failed" ]]; then
                _rdc_all_done="false"
                break
            fi
        done
        if [[ "$_rdc_all_done" == "true" ]]; then
            break
        fi
        _rdc_now=$(date +%s)
        _rdc_elapsed=$(( _rdc_now - _rdc_start_time ))
        if [[ $_rdc_elapsed -ge $timeout_sec ]]; then
            echo "aggregator failed: timeout waiting for round-1 reviewer sentinels under $staging_dir (elapsed ${_rdc_elapsed}s, budget ${timeout_sec}s)" >&2
            return 1
        fi
        sleep "$poll_interval"
    done

    # ----------------------------------------------------------------------
    # Phase D step 5+7: stub aggregator. Parse each reviewer's JSON,
    # augment with debate additive fields, collect verdicts and findings.
    # On any reviewer-level failure (failed sentinel, missing output,
    # parse error, invalid verdict), abort BEFORE writing anything to
    # $reviews_dir so the canonical state stays empty per the failure
    # contract.
    # ----------------------------------------------------------------------
    local -a _rdc_promoted_temp_files=()
    local -a _rdc_promoted_target_files=()
    local -a _rdc_promoted_sentinels=()
    local -a _rdc_active_reviewers=()
    local _rdc_has_fail=0 _rdc_has_needs=0 _rdc_has_pass=0
    local _rdc_all_findings='[]'
    local _rdc_strategies_json='{}'
    local _rdc_pid_suffix="$$"

    for _rdc_reviewer in "${_rdc_reviewers[@]}"; do
        # Per-reviewer strategy from the assign_strategies pass that
        # bin/review-gate already ran before spawn. STRATEGY_NAME_<UPPER>
        # was exported from there; default to verification-first as a
        # defensive last resort (assign_strategies always exports a name
        # under valid invocations, but bare-spawn fixtures may invoke
        # this function directly with a synthetic env).
        local _rdc_upper
        _rdc_upper=$(echo "$_rdc_reviewer" | tr '[:lower:]' '[:upper:]')
        local _rdc_strategy_var="STRATEGY_NAME_${_rdc_upper}"
        local _rdc_strategy="${!_rdc_strategy_var:-verification-first}"
        _rdc_strategies_json=$(printf '%s' "$_rdc_strategies_json" | jq \
            --arg name "$_rdc_reviewer" --arg strategy "$_rdc_strategy" \
            '.[$name] = $strategy') || {
            echo "aggregator failed: jq strategies bookkeeping for reviewer $_rdc_reviewer" >&2
            _rdc_cleanup_temp_files ${_rdc_promoted_temp_files[@]+"${_rdc_promoted_temp_files[@]}"}
            return 1
        }

        local _rdc_out_file="$staging_dir/${_rdc_reviewer}.json"
        local _rdc_failed_file="$staging_dir/${_rdc_reviewer}.failed"

        # Phase D stub: any .failed sentinel is a hard error. T008 will
        # introduce Mode A abstain handling (terminal-abstention rule) and
        # the degraded-below-2 mid-debate gate; for Phase D we surface
        # the failure as an aggregator error so it is not silently
        # swallowed.
        if [[ -f "$_rdc_failed_file" ]]; then
            echo "aggregator failed: reviewer $_rdc_reviewer wrote .failed sentinel under $staging_dir (T008 will wire Mode A abstention; Phase D treats this as a hard aggregator error)" >&2
            _rdc_cleanup_temp_files ${_rdc_promoted_temp_files[@]+"${_rdc_promoted_temp_files[@]}"}
            return 1
        fi

        if [[ ! -s "$_rdc_out_file" ]]; then
            echo "aggregator failed: reviewer $_rdc_reviewer output missing or empty: $_rdc_out_file" >&2
            _rdc_cleanup_temp_files ${_rdc_promoted_temp_files[@]+"${_rdc_promoted_temp_files[@]}"}
            return 1
        fi

        # Parse + unwrap via the shared extract_json helper (handles
        # codex/claude/gemini provider wrappers and the existing repair
        # fallback). extract_json is defined in review-gate-models.sh,
        # which bin/review-gate sources before sourcing this file.
        local _rdc_parsed
        if ! _rdc_parsed=$(extract_json "$_rdc_out_file" "$_rdc_reviewer" 2>/dev/null); then
            echo "aggregator failed: cannot parse reviewer $_rdc_reviewer output ($_rdc_out_file)" >&2
            _rdc_cleanup_temp_files ${_rdc_promoted_temp_files[@]+"${_rdc_promoted_temp_files[@]}"}
            return 1
        fi

        # Verdict + findings — both REQUIRED per spec for the reviewer to
        # have produced output at all (Mode A boundary distinguishes
        # "didn't answer" from "had nothing to say"). Mode B confidence
        # fallback applies ONLY to overall_confidence / per-finding
        # confidence; absent `findings` (the field itself missing from
        # the parsed JSON) or absent `verdict` is Mode A territory and
        # MUST surface as an aggregator error in Phase D rather than be
        # silently treated as `findings: []` / default verdict. Note that
        # `findings: []` (empty array — reviewer saw no defects) IS
        # valid; only the field's complete absence triggers this path.
        # Claude/Gemini outputs are not schema-enforced by Codex's
        # --output-schema, so this guard catches truncated or malformed
        # reviewer outputs that would otherwise slip into aggregate.json.
        # T008 will replace this with the real Mode A abstention path
        # (terminal-abstention, abstained-peer surfacing).
        local _rdc_findings_present
        _rdc_findings_present=$(printf '%s' "$_rdc_parsed" | jq -r '
            if has("findings") and (.findings | type == "array") then "yes" else "no" end' 2>/dev/null || echo "no")
        if [[ "$_rdc_findings_present" != "yes" ]]; then
            echo "aggregator failed: reviewer $_rdc_reviewer output missing or non-array .findings (Mode A boundary; Phase D treats absent findings as a hard aggregator error)" >&2
            _rdc_cleanup_temp_files ${_rdc_promoted_temp_files[@]+"${_rdc_promoted_temp_files[@]}"}
            return 1
        fi

        # Verdict — required for the stub aggregator's "most severe wins"
        # rollup. Invalid (or absent / empty-string) verdict is an
        # aggregator error in Phase D.
        local _rdc_verdict
        _rdc_verdict=$(printf '%s' "$_rdc_parsed" | jq -r '.verdict // ""' 2>/dev/null || echo "")
        case "$_rdc_verdict" in
            PASS) _rdc_has_pass=$((_rdc_has_pass + 1)) ;;
            FAIL) _rdc_has_fail=$((_rdc_has_fail + 1)) ;;
            NEEDS_WORK) _rdc_has_needs=$((_rdc_has_needs + 1)) ;;
            *)
                echo "aggregator failed: invalid verdict '$_rdc_verdict' for reviewer $_rdc_reviewer" >&2
                _rdc_cleanup_temp_files ${_rdc_promoted_temp_files[@]+"${_rdc_promoted_temp_files[@]}"}
                return 1
                ;;
        esac

        # overall_confidence: default 0.5 under Mode B (parseable JSON,
        # missing/out-of-range confidence); clamp to [0,1]. T008+ extends
        # this with per-finding confidence handling.
        local _rdc_overall_conf
        _rdc_overall_conf=$(printf '%s' "$_rdc_parsed" | jq -r '
            (.overall_confidence // 0.5)
            | if (type != "number") then 0.5
              elif . < 0 then 0
              elif . > 1 then 1
              else .
              end' 2>/dev/null || echo "0.5")

        # Augment with per-reviewer additive fields (overall_confidence,
        # strategy, round=1, peer_responses_seen=[]). Phase D: peer block
        # is empty in Round 1 (no prior round → no peers presented).
        local _rdc_augmented
        _rdc_augmented=$(printf '%s' "$_rdc_parsed" | jq \
            --arg strategy "$_rdc_strategy" \
            --argjson conf "$_rdc_overall_conf" \
            '. + {
                overall_confidence: $conf,
                strategy: $strategy,
                round: 1,
                peer_responses_seen: []
            }') || {
            echo "aggregator failed: jq augment for reviewer $_rdc_reviewer" >&2
            _rdc_cleanup_temp_files ${_rdc_promoted_temp_files[@]+"${_rdc_promoted_temp_files[@]}"}
            return 1
        }

        # Stage the promoted JSON to a hidden temp inside $reviews_dir.
        # Using a `.staging.<pid>` suffix so a partial promotion never
        # leaves a JSON the Stop-hook would mistakenly read (the Stop-hook
        # globs on `$REVIEWS_DIR/<reviewer>.json`).
        local _rdc_tmp_path="$reviews_dir/.${_rdc_reviewer}.json.staging.$_rdc_pid_suffix"
        local _rdc_target_path="$reviews_dir/${_rdc_reviewer}.json"
        local _rdc_sentinel_path="$reviews_dir/${_rdc_reviewer}.done"

        if ! printf '%s\n' "$_rdc_augmented" > "$_rdc_tmp_path"; then
            echo "aggregator failed: cannot stage augmented JSON for $_rdc_reviewer at $_rdc_tmp_path" >&2
            _rdc_cleanup_temp_files ${_rdc_promoted_temp_files[@]+"${_rdc_promoted_temp_files[@]}"} "$_rdc_tmp_path"
            return 1
        fi

        _rdc_promoted_temp_files+=("$_rdc_tmp_path")
        _rdc_promoted_target_files+=("$_rdc_target_path")
        _rdc_promoted_sentinels+=("$_rdc_sentinel_path")
        _rdc_active_reviewers+=("$_rdc_reviewer")

        # Append findings (simple union per Phase D scope; T009 replaces
        # with confidence-weighted dedup + canonical merge order). Each
        # finding gets a `raised_by` array pinning the source reviewer so
        # downstream surfaces (gate report, T009 dedup, telemetry) can
        # attribute findings.
        local _rdc_rev_findings
        _rdc_rev_findings=$(printf '%s' "$_rdc_augmented" | jq \
            --arg name "$_rdc_reviewer" \
            '(.findings // []) | map(. + {raised_by: [$name]})' 2>/dev/null) || _rdc_rev_findings='[]'
        _rdc_all_findings=$(jq -c --argjson new "$_rdc_rev_findings" '. + $new' <<< "$_rdc_all_findings") || {
            echo "aggregator failed: jq merge findings for $_rdc_reviewer" >&2
            _rdc_cleanup_temp_files ${_rdc_promoted_temp_files[@]+"${_rdc_promoted_temp_files[@]}"}
            return 1
        }
    done

    # ----------------------------------------------------------------------
    # Stub aggregate verdict — "most severe wins" matches today's
    # `wait_for_consensus`/`review_gate_wait` rollup at
    # bin/review-gate:3855-3895 so the Phase D shape is internally
    # consistent. T009 replaces with the real confidence-weighted
    # tiebreak path.
    # ----------------------------------------------------------------------
    local _rdc_agg_verdict=""
    if [[ $_rdc_has_fail -gt 0 ]]; then
        _rdc_agg_verdict="FAIL"
    elif [[ $_rdc_has_needs -gt 0 ]]; then
        _rdc_agg_verdict="NEEDS_WORK"
    elif [[ $_rdc_has_pass -gt 0 ]]; then
        _rdc_agg_verdict="PASS"
    else
        echo "aggregator failed: no valid verdicts collected from round-1 reviewers" >&2
        _rdc_cleanup_temp_files ${_rdc_promoted_temp_files[@]+"${_rdc_promoted_temp_files[@]}"}
        return 1
    fi

    # Active reviewers list (canonical alphabetical order). The
    # aggregate.json shape pins reviewers[] as the set of reviewers active
    # in the final round; for Phase D that is just the Round-1 set.
    local _rdc_active_sorted
    _rdc_active_sorted=$(printf '%s\n' "${_rdc_active_reviewers[@]}" | LC_ALL=C sort)
    local _rdc_active_json='[]'
    local _rdc_r
    while IFS= read -r _rdc_r; do
        [[ -z "$_rdc_r" ]] && continue
        _rdc_active_json=$(printf '%s' "$_rdc_active_json" | jq --arg n "$_rdc_r" '. + [$n]')
    done <<< "$_rdc_active_sorted"

    local _rdc_aggregate_tmp="$reviews_dir/.aggregate.json.staging.$_rdc_pid_suffix"
    if ! jq -n \
        --arg verdict "$_rdc_agg_verdict" \
        --argjson findings "$_rdc_all_findings" \
        --arg consensus_mode "$consensus_mode" \
        --argjson reviewers "$_rdc_active_json" \
        --argjson strategies "$_rdc_strategies_json" \
        '{
            verdict: $verdict,
            summary: "Phase D stub aggregate (single-round, no dedup; T009 replaces with confidence-weighted dedup and the canonical jq summary template).",
            findings: $findings,
            consensus_mode: $consensus_mode,
            rounds_consumed: 1,
            reviewers: $reviewers,
            strategies: $strategies
        }' > "$_rdc_aggregate_tmp"; then
        echo "aggregator failed: jq could not produce aggregate.json" >&2
        _rdc_cleanup_temp_files ${_rdc_promoted_temp_files[@]+"${_rdc_promoted_temp_files[@]}"} "$_rdc_aggregate_tmp"
        return 1
    fi

    # ----------------------------------------------------------------------
    # Phase D step 6: atomic promotion. mv each reviewer temp into the
    # canonical target, then write the .done sentinel (sentinel last so a
    # Stop-hook poll never reads a half-written reviewer JSON). aggregate
    # last so a partial-promotion failure leaves no aggregate.json.
    # ----------------------------------------------------------------------
    local _rdc_i=0
    while [[ $_rdc_i -lt ${#_rdc_promoted_temp_files[@]} ]]; do
        if ! mv -f "${_rdc_promoted_temp_files[$_rdc_i]}" "${_rdc_promoted_target_files[$_rdc_i]}"; then
            echo "aggregator failed: cannot promote ${_rdc_promoted_temp_files[$_rdc_i]} -> ${_rdc_promoted_target_files[$_rdc_i]}" >&2
            # Best-effort cleanup: remove any sentinels/JSONs we already
            # promoted so $reviews_dir does not surface a half-promoted
            # state to the Stop-hook.
            local _rdc_j=0
            while [[ $_rdc_j -lt ${#_rdc_promoted_target_files[@]} ]]; do
                rm -f "${_rdc_promoted_target_files[$_rdc_j]}" "${_rdc_promoted_sentinels[$_rdc_j]}" 2>/dev/null || true
                _rdc_j=$((_rdc_j + 1))
            done
            _rdc_cleanup_temp_files ${_rdc_promoted_temp_files[@]+"${_rdc_promoted_temp_files[@]}"} "$_rdc_aggregate_tmp"
            return 1
        fi
        # Sentinel last (empty file; Stop-hook only checks existence).
        : > "${_rdc_promoted_sentinels[$_rdc_i]}"
        _rdc_i=$((_rdc_i + 1))
    done

    if ! mv -f "$_rdc_aggregate_tmp" "$reviews_dir/aggregate.json"; then
        echo "aggregator failed: cannot promote aggregate.json into $reviews_dir" >&2
        # Roll back per-reviewer promotions to keep $reviews_dir clean.
        local _rdc_k=0
        while [[ $_rdc_k -lt ${#_rdc_promoted_target_files[@]} ]]; do
            rm -f "${_rdc_promoted_target_files[$_rdc_k]}" "${_rdc_promoted_sentinels[$_rdc_k]}" 2>/dev/null || true
            _rdc_k=$((_rdc_k + 1))
        done
        rm -f "$_rdc_aggregate_tmp" 2>/dev/null || true
        return 1
    fi

    # ----------------------------------------------------------------------
    # T007 R1 anonymization: build per-recipient peer blocks from the
    # promoted Round-1 JSONs. Populates `PEER_BLOCK_<UPPER>` env vars and
    # writes `peer-block.<recipient>.txt` files into $staging_dir for the
    # T008 Round-2 launcher to consume.
    #
    # Seed comes from REVIEW_GATE_DEBATE_SEED (set by bin/review-gate when
    # `--debate-seed N` is passed) so this function's caller signature does
    # not need to be widened. Empty seed → production-path shuffle per
    # spec R1.
    #
    # Failure here is non-fatal in Phase D: Round 2 is not launched yet,
    # so a missing peer block has no observable downstream effect. T008
    # will harden this into a hard failure once it actually consumes the
    # peer block. The warning is logged so the failure surfaces in the
    # spawn output.
    # ----------------------------------------------------------------------
    if ! debate_build_peer_blocks \
            "$staging_dir" "$reviews_dir" "${REVIEW_GATE_DEBATE_SEED:-}" \
            "${_rdc_active_reviewers[@]}"; then
        echo "warning: debate_build_peer_blocks failed (T007 anonymization). Round-2 (T008) will need to recover." >&2
    fi

    return 0
}
