#!/usr/bin/env bash
# Telemetry collection and aggregation for cerberus plugin.

# Source guard - prevent multiple inclusion
[[ -n "${_CERBERUS_TELEMETRY_LIB_SOURCED:-}" ]] && return 0
_CERBERUS_TELEMETRY_LIB_SOURCED=1

# Fallback log for library context when hook log isn't available.
if ! declare -f rg_log >/dev/null 2>&1; then
    rg_log() {
        if declare -F log >/dev/null 2>&1; then
            log "$1"
        else
            printf '%s\n' "$1" >&2
        fi
    }
fi

# ============================================================================
# VERSION DETECTION
# ============================================================================

# Extract plugin version from plugin.json using jq
get_plugin_version() {
    local plugin_json="${PLUGIN_ROOT:-.}/.claude-plugin/plugin.json"
    if [[ ! -f "$plugin_json" ]]; then
        plugin_json="${PLUGIN_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}/.claude-plugin/plugin.json"
    fi
    
    if [[ -f "$plugin_json" ]] && command -v jq >/dev/null 2>&1; then
        jq -r '.version // "unknown"' "$plugin_json" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# Check if a CLI supports JSON output flags
# Returns 0 if supported, 1 if not
detect_cli_json_support() {
    local cli="${1:-}"
    
    case "$cli" in
        claude)
            command -v claude >/dev/null 2>&1 && claude --help 2>&1 | grep -q -- '--output-format'
            ;;
        codex)
            command -v codex >/dev/null 2>&1 && codex --help 2>&1 | grep -qE -- '--json|JSONL'
            ;;
        gemini)
            command -v gemini >/dev/null 2>&1 && gemini --help 2>&1 | grep -q -- '-o json'
            ;;
        *)
            return 1
            ;;
    esac
}

# ============================================================================
# ATOMIC FILE OPERATIONS
# ============================================================================

# Atomic write: write to temp file then move
# Usage: atomic_write <file> <content>
# OR: printf 'content' | atomic_write <file>
atomic_write() {
    local file="$1"
    local content="${2:-}"
    local tmp_file="${file}.tmp.$$"
    local dir
    dir=$(dirname "$file")
    
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" 2>/dev/null || {
            rg_log "telemetry: atomic_write failed to create dir $dir"
            return 1
        }
    fi
    
    if [[ -n "$content" ]]; then
        printf '%s' "$content" > "$tmp_file" 2>/dev/null || {
            rm -f "$tmp_file" 2>/dev/null
            return 1
        }
    else
        cat > "$tmp_file" 2>/dev/null || {
            rm -f "$tmp_file" 2>/dev/null
            return 1
        }
    fi
    
    mv "$tmp_file" "$file" 2>/dev/null || {
        rm -f "$tmp_file" 2>/dev/null
        return 1
    }
    return 0
}

# Atomic JSON update with flock for shared files
# Usage: atomic_json_update <file> <jq_filter> [merge_json]
# If file doesn't exist, starts with empty object {}
atomic_json_update() {
    local file="$1"
    local jq_filter="$2"
    local merge_json="${3:-}"
    local lock_file="${file}.lock"
    local tmp_file="${file}.tmp.$$"
    local dir
    dir=$(dirname "$file")
    
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" 2>/dev/null || return 1
    fi
    
    # Use flock if available, otherwise proceed without locking
    local has_flock=false
    command -v flock >/dev/null 2>&1 && has_flock=true
    
    _do_update() {
        local current="{}"
        if [[ -f "$file" ]]; then
            current=$(jq -c '.' "$file" 2>/dev/null || echo "{}")
        fi
        
        local updated
        if [[ -n "$merge_json" ]]; then
            updated=$(printf '%s' "$current" | jq -c --argjson merge "$merge_json" "$jq_filter" 2>/dev/null)
        else
            updated=$(printf '%s' "$current" | jq -c "$jq_filter" 2>/dev/null)
        fi
        
        if [[ -z "$updated" || "$updated" == "null" ]]; then
            return 1
        fi
        
        printf '%s' "$updated" > "$tmp_file" && mv "$tmp_file" "$file"
    }
    
    if [[ "$has_flock" == "true" ]]; then
        (
            flock -w 5 200 || {
                rg_log "telemetry: atomic_json_update failed to acquire lock on $file"
                return 1
            }
            _do_update
        ) 200>"$lock_file"
        local rc=$?
        rm -f "$lock_file" 2>/dev/null
        return $rc
    else
        _do_update
    fi
}

# ============================================================================
# TELEMETRY EXTRACTION FUNCTIONS
# ============================================================================

# Extract telemetry from Claude JSON output (--output-format json)
# Input: raw JSON file path
# Output: normalized stats JSON to stdout
extract_claude_telemetry() {
    local raw_file="$1"
    
    if [[ ! -f "$raw_file" ]]; then
        rg_log "telemetry: extract_claude_telemetry file not found: $raw_file"
        return 1
    fi
    
    local raw
    raw=$(cat "$raw_file" 2>/dev/null) || return 1
    
    # Claude --output-format json gives: session_id, tokens (input/output/cached), 
    # duration_ms, duration_api_ms, total_cost_usd, modelUsage
    local extracted
    extracted=$(printf '%s' "$raw" | jq -c '
        {
            agent: "claude",
            model: (.model // .modelUsage // {} | keys[0] // "unknown"),
            session_id: (.session_id // null),
            tokens: {
                input: ((.tokens.input // .usage.input_tokens // 0) | tonumber),
                output: ((.tokens.output // .usage.output_tokens // 0) | tonumber),
                cached: ((.tokens.cached // .tokens.cache_read // .usage.cache_read_input_tokens // 0) | tonumber)
            },
            duration_ms: ((.duration_ms // .duration // 0) | tonumber),
            cost_usd: ((.total_cost_usd // .cost_usd // 0) | tonumber),
            tools: (
                if .toolUsage then
                    .toolUsage | to_entries | map({
                        key: .key,
                        value: {calls: (.value.count // .value.calls // 1), tokens: (.value.tokens // 0)}
                    }) | from_entries
                else {}
                end
            ),
            extracted_at: (now | todate)
        }
    ' 2>/dev/null)
    
    if [[ -z "$extracted" || "$extracted" == "null" ]]; then
        rg_log "telemetry: extract_claude_telemetry failed to parse JSON"
        _emit_empty_telemetry "claude"
        return 0
    fi
    
    printf '%s' "$extracted"
}

# Extract telemetry from Codex JSONL output (--json flag)
# Input: raw JSONL file path
# Output: normalized stats JSON to stdout
extract_codex_telemetry() {
    local raw_file="$1"
    
    if [[ ! -f "$raw_file" ]]; then
        rg_log "telemetry: extract_codex_telemetry file not found: $raw_file"
        return 1
    fi
    
    # Codex --json gives JSONL with thread_id, turn.completed.usage for tokens,
    # item.started/completed events for tool calls
    # Real format: {"type":"turn.completed","usage":{"input_tokens":N,"cached_input_tokens":N,"output_tokens":N}}
    # Tool calls in current CLI (0.122.x): item.completed with .item.type == "command_execution"
    # Older/MCP-style tool calls: .item.type == "function_call" or top-level .type == "tool_use"
    local extracted
    extracted=$(jq -s -c '
        # Collect all lines into array, extract relevant data
        . as $lines |

        # Find thread_id from any line that has it
        ($lines | map(select(.thread_id)) | .[0].thread_id // null) as $thread_id |

        # Find model from any line (new CLI does not emit it in JSONL; "unknown" is expected)
        ($lines | map(select(.model)) | .[0].model // "unknown") as $model |

        # Sum up tokens from turn.completed events or usage objects (handle both old and new formats)
        ($lines | map(select(.usage)) | map(.usage) | add // {}) as $usage |

        # Tool-call predicate: item-wrapped (new) or flat (legacy)
        def is_tool_call:
            (.item.type // "") as $it
            | ($it == "command_execution" or $it == "function_call")
              or .type == "tool_use";

        # Tool-call name: normalize shell executions to "shell"; keep explicit names otherwise
        def tool_call_name:
            if (.item.type // "") == "command_execution" then "shell"
            else (.item.name // .name // "unknown")
            end;

        # Count item.completed tool calls only (skip item.started to avoid double-counting)
        ($lines | map(select(
            (.type // "") != "item.started" and is_tool_call
        )) | length) as $tool_count |

        # Extract tool names and count them
        ($lines | map(
            select((.type // "") != "item.started" and is_tool_call) | tool_call_name
        ) | group_by(.) | map({key: .[0], value: {calls: length, tokens: 0}}) | from_entries) as $tools |
        
        {
            agent: "codex",
            model: $model,
            session_id: $thread_id,
            tokens: {
                input: (($usage.input_tokens // $usage.prompt_tokens // 0) | tonumber),
                output: (($usage.output_tokens // $usage.completion_tokens // 0) | tonumber),
                cached: (($usage.cached_input_tokens // $usage.cached_tokens // 0) | tonumber)
            },
            duration_ms: 0,
            cost_usd: (($usage.cost // 0) | tonumber),
            tools: $tools,
            extracted_at: (now | todate)
        }
    ' "$raw_file" 2>/dev/null)
    
    if [[ -z "$extracted" || "$extracted" == "null" ]]; then
        rg_log "telemetry: extract_codex_telemetry failed to parse JSONL"
        _emit_empty_telemetry "codex"
        return 0
    fi
    
    printf '%s' "$extracted"
}

# Extract telemetry from Gemini JSON output (-o json)
# Input: raw JSON file path
# Output: normalized stats JSON to stdout
extract_gemini_telemetry() {
    local raw_file="$1"
    
    if [[ ! -f "$raw_file" ]]; then
        rg_log "telemetry: extract_gemini_telemetry file not found: $raw_file"
        return 1
    fi
    
    local raw
    raw=$(cat "$raw_file" 2>/dev/null) || return 1
    
    # Gemini -o json gives: session_id, .stats.tools.byName for per-tool breakdown,
    # .stats.models.<model>.tokens for token usage (input, candidates for output)
    # Real format: .stats.models.{model}.tokens.{input,candidates,cached}, .stats.models.{model}.api.totalLatencyMs
    local extracted
    extracted=$(printf '%s' "$raw" | jq -c '
        # Extract model name from stats.models keys
        ((.stats.models // {}) | keys | .[0] // "unknown") as $model |
        
        # Get token stats from the model entry
        ((.stats.models // {})[$model] // {}) as $model_stats |
        
        {
            agent: "gemini",
            model: $model,
            session_id: (.session_id // .sessionId // null),
            tokens: {
                input: (($model_stats.tokens.input // $model_stats.inputTokens // .usage.input_tokens // 0) | tonumber),
                output: (($model_stats.tokens.candidates // $model_stats.tokens.output // $model_stats.outputTokens // .usage.output_tokens // 0) | tonumber),
                cached: (($model_stats.tokens.cached // $model_stats.cachedTokens // 0) | tonumber)
            },
            duration_ms: (($model_stats.api.totalLatencyMs // .totalLatencyMs // .stats.totalLatencyMs // .latency_ms // 0) | tonumber),
            cost_usd: ((.cost // .stats.cost // 0) | tonumber),
            tools: (
                if .stats.tools.byName then
                    .stats.tools.byName | to_entries | map({
                        key: .key,
                        value: {
                            calls: (.value.totalCalls // .value.count // .value.calls // 1),
                            tokens: (.value.tokens // 0)
                        }
                    }) | from_entries
                else {}
                end
            ),
            extracted_at: (now | todate)
        }
    ' 2>/dev/null)
    
    if [[ -z "$extracted" || "$extracted" == "null" ]]; then
        rg_log "telemetry: extract_gemini_telemetry failed to parse JSON"
        _emit_empty_telemetry "gemini"
        return 0
    fi
    
    printf '%s' "$extracted"
}

# Emit empty telemetry structure for failed extractions
_emit_empty_telemetry() {
    local agent="${1:-unknown}"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
    
    printf '%s' "{
        \"agent\": \"$agent\",
        \"model\": \"unknown\",
        \"session_id\": null,
        \"tokens\": {\"input\": 0, \"output\": 0, \"cached\": 0},
        \"duration_ms\": 0,
        \"cost_usd\": 0,
        \"tools\": {},
        \"extracted_at\": \"$ts\"
    }" | jq -c '.'
}

# ============================================================================
# ITERATION DIRECTORY HELPERS
# ============================================================================

# Initialize iteration directory structure
# Usage: init_iteration_dir <review_dir> <iteration_number>
# Creates: $REVIEW_DIR/iterations/$N/agents/{claude,codex,gemini}
init_iteration_dir() {
    local review_dir="$1"
    local iteration="${2:-0}"
    
    if [[ -z "$review_dir" ]]; then
        rg_log "telemetry: init_iteration_dir requires review_dir"
        return 1
    fi
    
    local iter_dir="$review_dir/iterations/$iteration"
    local agents_dir="$iter_dir/agents"
    
    # Fail silently in read-only mode to avoid triggering ERR traps
    if ! mkdir -p "$agents_dir/claude" "$agents_dir/codex" "$agents_dir/gemini" 2>/dev/null; then
        rg_log "telemetry: init_iteration_dir failed to create directories (read-only?)"
        return 1
    fi
    
    echo "$iter_dir"
}

# Write agent telemetry files to iteration directory
# Usage: write_agent_telemetry <iter_dir> <agent> <stats_json> [raw_json] [draft_md]
write_agent_telemetry() {
    local iter_dir="$1"
    local agent="$2"
    local stats_json="$3"
    local raw_json="${4:-}"
    local draft_md="${5:-}"
    
    if [[ -z "$iter_dir" || -z "$agent" ]]; then
        rg_log "telemetry: write_agent_telemetry requires iter_dir and agent"
        return 1
    fi
    
    local agent_dir="$iter_dir/agents/$agent"
    if [[ ! -d "$agent_dir" ]]; then
        mkdir -p "$agent_dir" 2>/dev/null || return 1
    fi
    
    # Write stats.json (required)
    if [[ -n "$stats_json" ]]; then
        atomic_write "$agent_dir/stats.json" "$stats_json" || {
            rg_log "telemetry: write_agent_telemetry failed to write stats.json for $agent"
        }
    fi
    
    # Write raw.json (optional)
    if [[ -n "$raw_json" ]]; then
        atomic_write "$agent_dir/raw.json" "$raw_json" || {
            rg_log "telemetry: write_agent_telemetry failed to write raw.json for $agent"
        }
    fi
    
    # Write draft.md (optional)
    if [[ -n "$draft_md" ]]; then
        atomic_write "$agent_dir/draft.md" "$draft_md" || {
            rg_log "telemetry: write_agent_telemetry failed to write draft.md for $agent"
        }
    fi
    
    return 0
}

# ============================================================================
# RUN TELEMETRY AGGREGATION
# ============================================================================

# Update run-telemetry.json with latest iteration stats
# Usage: update_run_telemetry <review_dir> <iteration> <agent> <stats_json>
update_run_telemetry() {
    local review_dir="$1"
    local iteration="$2"
    local agent="$3"
    local stats_json="$4"
    
    if [[ -z "$review_dir" || -z "$iteration" || -z "$agent" || -z "$stats_json" ]]; then
        rg_log "telemetry: update_run_telemetry requires review_dir, iteration, agent, stats_json"
        return 1
    fi
    
    local telemetry_file="$review_dir/run-telemetry.json"
    local plugin_version
    plugin_version=$(get_plugin_version)

    # Initialize if file doesn't exist
    if [[ ! -f "$telemetry_file" ]]; then
        local init_json
        init_json=$(jq -n -c \
            --arg version "$plugin_version" \
            '{
                plugin_version: $version,
                created_at: (now | todate),
                updated_at: (now | todate),
                iterations: {},
                totals: {
                    tokens: {input: 0, output: 0, cached: 0},
                    duration_ms: 0,
                    cost_usd: 0,
                    iterations: 0
                }
            }' 2>/dev/null)
        
        atomic_write "$telemetry_file" "$init_json" || return 1
    fi

    # Update telemetry with new agent stats
    local current updated
    current=$(cat "$telemetry_file" 2>/dev/null || echo '{}')
    updated=$(printf '%s' "$current" | jq -c \
        --arg version "$plugin_version" \
        --arg iter_str "$iteration" \
        --arg agent_name "$agent" \
        --argjson stats "$stats_json" \
        '
        .plugin_version = $version |
        .updated_at = (now | todate) |
        .iterations[$iter_str].agents[$agent_name] = $stats |
        # Safely aggregate totals using to_entries to handle missing intermediate nodes
        (.iterations // {} | to_entries | map(.value.agents // {} | to_entries | map(.value)) | flatten) as $all_agents |
        .totals.tokens.input = ([$all_agents[].tokens.input // 0] | add // 0) |
        .totals.tokens.output = ([$all_agents[].tokens.output // 0] | add // 0) |
        .totals.tokens.cached = ([$all_agents[].tokens.cached // 0] | add // 0) |
        .totals.duration_ms = ([$all_agents[].duration_ms // 0] | add // 0) |
        .totals.cost_usd = ([$all_agents[].cost_usd // 0] | add // 0) |
        .totals.iterations = (.iterations // {} | keys | length)
        ' 2>/dev/null)
    
    if [[ -n "$updated" && "$updated" != "null" ]]; then
        atomic_write "$telemetry_file" "$updated"
    else
        rg_log "telemetry: update_run_telemetry failed to update JSON"
        return 1
    fi
}

# Record resolution status in run telemetry
# Usage: resolve_run_telemetry <review_dir> <decision> <reason>
# Parameters:
#   review_dir - path to the review directory
#   decision   - the resolution decision (e.g., "approve", "reject", "force_approve")
#   reason     - the reason for resolution (e.g., "consensus_passed", "user_approved")
resolve_run_telemetry() {
    local review_dir="$1"
    local decision="$2"
    local reason="$3"

    if [[ -z "$review_dir" || -z "$decision" ]]; then
        rg_log "telemetry: resolve_run_telemetry requires review_dir and decision"
        return 1
    fi

    local telemetry_file="$review_dir/run-telemetry.json"
    local plugin_version
    plugin_version=$(get_plugin_version)

    # Initialize if file doesn't exist
    if [[ ! -f "$telemetry_file" ]]; then
        local init_json
        init_json=$(jq -n -c \
            --arg version "$plugin_version" \
            '{
                plugin_version: $version,
                created_at: (now | todate),
                updated_at: (now | todate),
                iterations: {},
                totals: {
                    tokens: {input: 0, output: 0, cached: 0},
                    duration_ms: 0,
                    cost_usd: 0,
                    iterations: 0
                }
            }' 2>/dev/null)

        atomic_write "$telemetry_file" "$init_json" || return 1
    fi

    # Update with resolution info
    local current updated
    current=$(cat "$telemetry_file" 2>/dev/null || echo '{}')
    updated=$(printf '%s' "$current" | jq -c \
        --arg version "$plugin_version" \
        --arg decision "$decision" \
        --arg reason "$reason" \
        '
        .plugin_version = $version |
        .updated_at = (now | todate) |
        .resolution = {
            decision: $decision,
            reason: $reason,
            resolved_at: (now | todate)
        }
        ' 2>/dev/null)

    if [[ -n "$updated" && "$updated" != "null" ]]; then
        atomic_write "$telemetry_file" "$updated"
    else
        rg_log "telemetry: resolve_run_telemetry failed to update JSON"
        return 1
    fi
}

# Get aggregated telemetry summary for a run
# Usage: get_run_telemetry_summary <review_dir>
get_run_telemetry_summary() {
    local review_dir="$1"
    local telemetry_file="$review_dir/run-telemetry.json"
    
    if [[ ! -f "$telemetry_file" ]]; then
        echo "{}"
        return 0
    fi
    
    jq -c '.totals // {}' "$telemetry_file" 2>/dev/null || echo "{}"
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Extract telemetry from JSON string (for inline use in tests)
# Usage: extract_telemetry_from_json <agent> <json_string>
extract_telemetry_from_json() {
    local agent="$1"
    local json_string="$2"
    
    local tmp_file
    tmp_file=$(mktemp)
    printf '%s' "$json_string" > "$tmp_file"
    
    local result
    case "$agent" in
        claude)
            result=$(extract_claude_telemetry "$tmp_file" 2>/dev/null) || result=""
            ;;
        gemini)
            result=$(extract_gemini_telemetry "$tmp_file" 2>/dev/null) || result=""
            ;;
        codex)
            # Single JSON line - try parsing as one-line JSONL
            result=$(extract_codex_telemetry "$tmp_file" 2>/dev/null) || result=""
            ;;
        *)
            result=""
            ;;
    esac
    
    rm -f "$tmp_file"
    
    if [[ -z "$result" || "$result" == "null" ]]; then
        echo "{}"
        return 1
    fi
    
    printf '%s' "$result"
}

# Extract telemetry from JSONL string (for codex inline use)
# Usage: extract_telemetry_from_jsonl <agent> <jsonl_string>
extract_telemetry_from_jsonl() {
    local agent="$1"
    local jsonl_string="$2"
    
    local tmp_file
    tmp_file=$(mktemp)
    printf '%s' "$jsonl_string" > "$tmp_file"
    
    local result
    result=$(extract_codex_telemetry "$tmp_file" 2>/dev/null) || result=""
    
    rm -f "$tmp_file"
    
    if [[ -z "$result" || "$result" == "null" ]]; then
        echo "{}"
        return 1
    fi
    
    printf '%s' "$result"
}

# Safe extraction wrapper - telemetry failures must not break review gate
# Usage: safe_extract_telemetry <agent> <raw_file>
# Agent can be exact (claude, codex, gemini) or prefixed (claude-fast, codex-1, etc.)
safe_extract_telemetry() {
    local agent="$1"
    local raw_file="$2"

    # Normalize agent name: extract base agent from prefixed names like "codex-1", "claude-fast"
    local base_agent="$agent"
    if [[ "$agent" == claude* ]]; then
        base_agent="claude"
    elif [[ "$agent" == codex* ]]; then
        base_agent="codex"
    elif [[ "$agent" == gemini* ]]; then
        base_agent="gemini"
    fi

    local result
    case "$base_agent" in
        claude)
            result=$(extract_claude_telemetry "$raw_file" 2>/dev/null) || result=""
            ;;
        codex)
            # New invocation writes the clean verdict JSON to foo.json and the
            # full JSONL transcript to foo.jsonl. Telemetry lives in the JSONL.
            local codex_source="$raw_file"
            if [[ "$raw_file" == *.json && -f "${raw_file%.json}.jsonl" ]]; then
                codex_source="${raw_file%.json}.jsonl"
            fi
            result=$(extract_codex_telemetry "$codex_source" 2>/dev/null) || result=""
            ;;
        gemini)
            result=$(extract_gemini_telemetry "$raw_file" 2>/dev/null) || result=""
            ;;
        *)
            result=""
            ;;
    esac

    if [[ -z "$result" || "$result" == "null" ]]; then
        _emit_empty_telemetry "$agent"
    else
        printf '%s' "$result"
    fi
}
