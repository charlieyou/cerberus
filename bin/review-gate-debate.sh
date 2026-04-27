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

        # Verdict — required for the stub aggregator's "most severe wins"
        # rollup. Invalid verdict is an aggregator error in Phase D.
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

    return 0
}
