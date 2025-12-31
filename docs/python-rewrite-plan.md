# Python Rewrite Plan for review-gate

## Overview

Replace ~3,500 lines of bash scripts with a Python CLI while maintaining the same interface and behavior.

## Project Structure

```
cerberus/
├── bin/
│   └── review-gate          # Thin shell wrapper: exec python -m cerberus.cli "$@"
├── src/
│   └── cerberus/
│       ├── __init__.py
│       ├── cli.py           # Click-based CLI entry point
│       ├── commands/
│       │   ├── __init__.py
│       │   ├── check.py     # Stop hook logic
│       │   ├── spawn.py     # Generic spawn
│       │   ├── spawn_code.py
│       │   ├── spawn_plan.py
│       │   ├── spawn_spec.py
│       │   ├── resolve.py
│       │   ├── wait.py
│       │   └── utils.py     # artifact-path, author-context
│       ├── core/
│       │   ├── __init__.py
│       │   ├── state.py     # GateState dataclass, load/save JSON
│       │   ├── session.py   # Session/path resolution
│       │   ├── config.py    # Mode resolution (fast/smart/max → models)
│       │   ├── artifact.py  # Frontmatter parsing
│       │   └── iteration.py # Iteration tracking and archiving
│       ├── reviewers/
│       │   ├── __init__.py
│       │   ├── base.py      # Reviewer ABC
│       │   ├── codex.py     # Codex spawning + JSON extraction
│       │   ├── gemini.py    # Gemini spawning + JSON extraction
│       │   ├── claude.py    # Claude spawning + JSON extraction
│       │   ├── extraction.py # Smart JSON extraction
│       │   └── poller.py    # Polling loop for completion
│       ├── consensus/
│       │   ├── __init__.py
│       │   ├── calculate.py # Verdict aggregation
│       │   └── formatting.py # Results table, revision instructions
│       └── prompts/
│           ├── __init__.py
│           ├── builder.py   # Template loading, substitution, context injection
│           └── revisions.py # Revision template resolution and formatting
├── pyproject.toml
└── prompts/                  # Keep existing .md templates (unchanged)
    ├── reviewers/
    └── revisions/
```

## Data Models

### GateState (core/state.py)

Full schema matching existing gate-state.json format:

```python
@dataclass
class ArtifactInfo:
    path: str
    sha256: str  # For artifact-change detection

@dataclass
class ModeConfig:
    type: str  # "artifact", "code-diff", "plan", "spec"
    diff_args: Optional[str] = None  # For code-review-iterative
    plan_path: Optional[str] = None  # For plan-review-iterative
    spec_path: Optional[str] = None  # For spec review

@dataclass
class GateConfig:
    max_rounds: Optional[int] = None
    intelligence_mode: Optional[str] = None  # fast/smart/max

@dataclass
class OwnerInfo:
    session_key: Optional[str] = None
    source: Optional[str] = None  # "env.REVIEW_GATE_SESSION_KEY", "input.session_id", etc.
    session_id: Optional[str] = None
    transcript_path: Optional[str] = None

@dataclass
class ConsensusInfo:
    verdict: str  # "auto_approve", "requires_decision", "no_reviewers"
    iteration: int

@dataclass
class DecisionInfo:
    action: str  # "proceed", "revise", "abort"
    decided_at: str  # ISO timestamp
    reason: Optional[str] = None  # e.g., "auto_proceed_max_iter"

@dataclass
class ReviewerState:
    output_file: str
    sentinel_file: str
    completed_at: Optional[str] = None
    result: Optional[dict] = None

@dataclass
class GateState:
    version: int
    status: Literal["pending", "awaiting_decision", "resolved"]
    trigger_source: str
    artifact: ArtifactInfo
    mode: ModeConfig
    config: Optional[GateConfig]  # None if empty, not {}
    owner: Optional[OwnerInfo]    # None if empty, not {}
    reviewers: dict[str, ReviewerState]
    consensus: Optional[ConsensusInfo]
    decision: Optional[DecisionInfo]
    created_at: str  # ISO8601 string (NOT datetime object) for JSON compatibility
    author_context: Optional[str]  # None when blank, not ""
```

Serialization must preserve null-vs-empty semantics for backwards compatibility.
All timestamps are ISO8601 strings, not datetime objects, to match existing JSON format.

### ReviewResult (reviewers/base.py)

```python
@dataclass
class Finding:
    title: str
    body: str
    priority: int  # 0-3
    file_path: Optional[str]
    line_start: Optional[int]
    line_end: Optional[int]

@dataclass
class ReviewResult:
    verdict: Literal["PASS", "FAIL", "NEEDS_WORK", "ERROR", "PENDING"]
    summary: str
    findings: list[Finding]
    confidence: Optional[float] = None
```

Note: `PENDING` verdict is used in `wait` output when a reviewer times out before completion.

## Stop Hook Behavior (check command)

The `check` command implements the stop hook and must preserve these behaviors:

### Input Protocol
Reads JSON from stdin with fields:
- `session_id` / `sessionId` - session identifier
- `transcript_path` / `transcriptPath` - path to transcript file
- `pending_tool_input.command` - command being executed (for allowlisting)

### Output Protocol
- **Block**: `{"decision": "block", "reason": "..."}` then exit 0
- **Allow**: exit 0 with no output (empty stdout)

### Deadlock Prevention
```python
def should_allowlist_command(input_data: dict) -> bool:
    """Allow resolve command to prevent blocking itself."""
    cmd = input_data.get("pending_tool_input", {}).get("command", "")
    return "review-gate resolve" in cmd
```
If allowlisted, immediately output_allow (exit 0, no output).

### Logging
```python
def setup_logging(review_dir: Path) -> Path:
    log_file = os.environ.get("REVIEW_GATE_LOG_FILE") or (review_dir / "cerberus.log")
    # Append mode, ISO timestamps
    return log_file
```

### Session Identification
Priority for session key:
1. `REVIEW_GATE_SESSION_KEY` env → source = "env.REVIEW_GATE_SESSION_KEY"
2. `session_id` from input → source = "input.session_id"
3. `transcript_path` from input → source = "input.transcript_path"

If no session_id can be determined, allow stop (exit 0).

### State Owner Backfill
When processing an existing state file, backfill missing owner fields:
```python
def ensure_state_owner(state: GateState, session_key: str, source: str,
                       session_id: str, transcript_path: str) -> bool:
    """Backfill owner fields if missing. Returns True if state was modified."""
    if state.owner and state.owner.session_key:
        return False  # Already has owner

    # Build owner info from available data
    owner = OwnerInfo(
        session_key=session_key or None,
        source=source or None,
        session_id=session_id or None,
        transcript_path=transcript_path or None,
    )
    # Only set if at least one field is present
    if any([owner.session_key, owner.source, owner.session_id, owner.transcript_path]):
        state.owner = owner
        return True
    return False
```

This is important for:
- `wait --session-key` lookup to find gates created before owner tracking
- Preventing cross-session blocking by identifying gate ownership

### State Flow

```
No state file + No artifact → Allow stop
No state file + Artifact exists → Spawn reviewers
State exists + status="resolved" → Check artifact change, allow if unchanged
State exists + status="pending"/"awaiting_decision" → Poll/check reviewers
State age > 30 min → Cleanup stale state, allow stop
```

### Artifact Change Detection
```python
def check_artifact_change(state: GateState, artifact_path: Path) -> bool:
    """Return True if artifact has changed since state was created."""
    if not artifact_path.exists():
        return False
    current_sha = compute_sha256(artifact_path)
    return current_sha != state.artifact.sha256
```

On resolved state with changed artifact:
1. `cleanup_stale_state()` - remove state file, iteration file, reviews dir
2. `reset_iteration()` - delete iteration.txt
3. `spawn_reviewers()` - start fresh review

### Stale State Cleanup
```python
def is_stale(state: GateState) -> bool:
    """State older than 30 minutes is stale."""
    created = parse_iso_timestamp(state.created_at)
    age_seconds = (datetime.now(timezone.utc) - created).total_seconds()
    return age_seconds > 1800
```

### Reviewer Polling Loop
```python
max_wait = int(os.environ.get("REVIEW_GATE_MAX_WAIT_SECONDS", 600))
poll_interval = int(os.environ.get("REVIEW_GATE_POLL_INTERVAL_SECONDS", 3))

start_time = time.time()
while True:
    completed, total, running = check_progress(state, reviews_dir)
    if completed >= total:
        break
    if max_wait > 0 and (time.time() - start_time) >= max_wait:
        output_block(f"Review gate: {completed}/{total} reviewers complete. Waiting for: {running}")
    time.sleep(poll_interval)
```

### Consensus and Decision Flow

After all reviewers complete:
1. Calculate consensus (all PASS = auto_approve, else requires_decision)
2. Update state to `status="awaiting_decision"`
3. Check iteration vs max_rounds

**All PASS (auto_approve):**
- Reset iteration
- Resolve gate with `action="proceed"`
- Collect informational items (P2/P3)
- Output block with summary prompt, then user may stop

**Not all PASS (requires_decision):**
- Check if `iteration >= max_rounds`
  - If yes: auto-resolve with `reason="auto_proceed_max_iter"`, collect P0/P1 issues
  - If no: increment iteration, clean for rerun, output revision instructions

### Max Iterations Auto-Proceed
```python
if current_iteration >= max_iterations:
    blocking_issues = collect_blocking_issues(state, reviews_dir)  # P0/P1 only
    resolve_gate(state, action="proceed", reason="auto_proceed_max_iter")
    output_block(format_max_iter_message(results, blocking_issues, max_iterations))
```

Recently auto-resolved gates (< 30 min with `reason="auto_proceed_max_iter"`) remain findable by `find_active_gate()` for manual override.

### Revision Request Flow
```python
# Not all PASS and under max iterations
issues = collect_issues(state, reviews_dir)  # All issues from non-PASS reviewers
clean_for_rerun()  # Archive reviews, delete state (but keep iteration.txt)
increment_iteration()
revision_instructions = format_revision_instructions(trigger_source, issues, mode_paths)
output_block(f"{results_table}\n\n---\n\n## Revision Required\n\n{revision_instructions}")
```

## CLI Surface

### spawn
```
review-gate spawn [options] [artifact-path]
  --agents <list>           Comma-separated: codex,gemini,claude
  --max-rounds <n>          Max iterations before manual resolution
  --mode <fast|smart|max>   Intelligence mode
  --context-file <path>     Author context file
  --type <type>             Review type override
  --session-id <id>         Session ID
  --transcript-path <path>  Transcript path
```

**Preflight: Check for existing active gate**
```python
def check_existing_gate(state_file: Path) -> None:
    """Refuse to spawn if non-stale active gate exists."""
    if not state_file.exists():
        return

    state = GateState.load(state_file)
    if state.status not in ("pending", "awaiting_decision"):
        return  # Resolved, OK to proceed

    # Check if stale (> 30 min old)
    created = parse_iso_timestamp(state.created_at)
    age_seconds = (datetime.now(timezone.utc) - created).total_seconds()
    if age_seconds >= 1800:
        print(f"Cleaning up stale gate (age: {int(age_seconds)}s)", file=sys.stderr)
        return  # Will be cleaned up, OK to proceed

    # Active non-stale gate exists
    raise ReviewGateError(
        f"Review gate already active (status: {state.status}, age: {int(age_seconds)}s)\n"
        f"Use review-gate resolve to complete the existing gate first."
    )
```

**No-reviewers auto-resolve**
If no reviewers can be spawned (all CLIs missing), auto-resolve to prevent blocking:
```python
if spawned_count == 0:
    state = GateState(
        # ... other fields ...
        status="resolved",
        consensus=ConsensusInfo(verdict="no_reviewers", iteration=0),
        decision=DecisionInfo(action="proceed", decided_at=now_iso(), reason="no_reviewers"),
        reviewers={},
    )
    state.save(state_file)
    print("No reviewers available; gate resolved as proceed", file=sys.stderr)
    return
```

### spawn-code-review
```
review-gate spawn-code-review [options]
  --agents, --max-rounds, --mode, --context-file (as above)
  --uncommitted             Review uncommitted changes (default)
  --base <branch>           Review changes from branch to HEAD
  --commit <sha...>         Review one or more commits (space or comma separated)
  <range>                   Review a commit range (e.g., main..feature)
```

### spawn-plan-review
```
review-gate spawn-plan-review [options] [plan-path]
  --agents, --max-rounds, --mode, --context-file, --session-id, --transcript-path
```
- If no plan-path provided: auto-select most recent `~/.claude/plans/*.md` (sorted by mtime)
- Error if no plans exist and no path provided

### spawn-spec-review
```
review-gate spawn-spec-review [options] <spec-path>
  --agents, --max-rounds, --mode, --context-file, --session-id, --transcript-path
```

### resolve
```
review-gate resolve [--reason <text>]
```
Note: `resolve` always resolves the gate as "proceed". The `revise` and `abort` actions were removed.

### wait
```
review-gate wait --json [--timeout <sec>] [--session-key <key>] [--session-id <id>] [--transcript-path <path>]
```

**Session resolution priority:**
1. If `--session-id` provided: use directly with `resolve_review_dir()`
2. If `--session-key` provided (without `--session-id`): scan all gate states to find match
3. Otherwise: derive session_id from transcript_path

**Session-key lookup algorithm:**
```python
def find_state_by_session_key(key: str) -> Optional[Path]:
    """Scan ~/.claude/projects/*/cerberus/*/gate-state.json for matching owner.session_key"""
    candidates = []
    for state_file in Path.home().glob(".claude/projects/*/cerberus/*/gate-state.json"):
        state = json.loads(state_file.read_text())
        if state.get("owner", {}).get("session_key") == key:
            # Get created_at timestamp, fallback to file mtime
            created = state.get("created_at", "")
            epoch = parse_iso_timestamp(created) if created else state_file.stat().st_mtime
            candidates.append((epoch, state_file))
    # Return most recent
    return max(candidates, key=lambda x: x[0])[1] if candidates else None
```

**Output JSON schema:**
```json
{
  "status": "complete|timeout|error|no_reviewers",
  "consensus_verdict": "PASS|FAIL|NEEDS_WORK|ERROR|null",
  "reviewers": {
    "<name>": {"verdict": "...", "summary": "...", "findings": [...]}
  },
  "aggregated_findings": [...],
  "parse_errors": [{"reviewer": "...", "error": "..."}]
}
```

Note: `consensus_verdict` is null on timeout (not PENDING). PENDING is only used per-reviewer.

**Timeout handling:** Individual reviewers not finished when timeout occurs get:
```json
{"verdict": "PENDING", "summary": "Timed out waiting for reviewer", "findings": []}
```
But top-level `consensus_verdict` is set to `null` on timeout, not PENDING.

Exit codes: 0=PASS, 2=FAIL/NEEDS_WORK/parse_errors, 3=timeout, 4=no_reviewers, 5=error

### artifact-path
```
review-gate artifact-path [--session-id <id>] [--transcript-path <path>]
```

### author-context
```
review-gate author-context [--session-id <id>] [--transcript-path <path>] [--clear] [text]
```
- Reads from stdin if no text argument and not a tty
- `--clear` removes stored context

## Reviewer Subprocess Semantics

### Spawning
Each reviewer spawns as a detached process:
```python
subprocess.Popen(
    cmd,
    stdout=open(output_file, 'w'),
    stderr=subprocess.STDOUT,
    start_new_session=True,
)
```

### Sentinel Files
- `$REVIEWS_DIR/<reviewer>.done` - created on successful completion
- `$REVIEWS_DIR/<reviewer>.failed` - created on process failure
- Poller checks for these files, not process exit

### Model-Specific CLI Invocations

**Codex:**
```bash
codex exec -m $MODEL -c model_reasoning_effort="$EFFORT" -s read-only --output-schema $SCHEMA - < $PROMPT
```
- Requires JSON schema file for structured output
- Reasoning effort varies by mode (medium/high/xhigh)

**Gemini:**
```bash
gemini -m $MODEL -o json < $PROMPT
```
- Output: first line is status, rest is JSON
- Parse with tail -n +2 then JSON decode

**Claude:**
```bash
claude -p --model $MODEL --output-format json < $PROMPT
```
- Output wrapped in metadata: extract `.result` field
- Result may have ```json fences to strip

### JSON Extraction
Each reviewer has specific extraction quirks handled in `reviewers/<name>.py`:
- Codex: Find last review-like JSON object (has verdict or structured_output wrapper)
- Gemini: Skip first line, unwrap `.response` field if present
- Claude: Extract `.result` from metadata, strip markdown fences

## Template Resolution

### Reviewer Templates

**For code/plan/spec reviews (spawn-code-review, spawn-plan-review, spawn-spec-review):**
Search order (first found wins):
1. `$PROJECT_ROOT/prompts/reviewers/<type>.md`
2. `$SCRIPT_DIR/../prompts/reviewers/<type>.md` (bundled)

Note: These specialized commands do NOT check user override path - they only check project-local and bundled.

**For generic spawn (build_prompt flow):**
Search order (first found wins):
1. `$PROJECT_ROOT/prompts/reviewers/<type>.md`
2. `$SCRIPT_DIR/../prompts/reviewers/<type>.md` (bundled)
3. `~/.claude/review-prompts/<type>.md` (user override - only in generic flow)

Type mapping:
- `code-review-iterative` → `code.md`
- `plan-review-iterative` → `plan.md`
- `spec` → `spec.md`

### Revision Templates
Location: `prompts/revisions/<type>.md`

Placeholders:
- `${ISSUES}` - formatted issues from reviewers
- `${DIFF_ARGS}` - diff mode for code reviews
- `${COMMIT_INSTRUCTIONS}` - generated based on diff mode
- `${PLAN_PATH}` - path for plan reviews
- `${SPEC_PATH}` - path for spec reviews

### Commit Instructions (code review)
Generated based on diff mode:
- `--uncommitted`: "Keep fixes uncommitted"
- `--base`, `--commit`, range: "Create NEW commit (no amend)"

## Iteration and Archiving

### Iteration Tracking (core/iteration.py)

File: `$REVIEW_DIR/iteration.txt` - contains current iteration count (0-indexed integer as string)

```python
def get_iteration(review_dir: Path) -> int:
    """Read current iteration from file, default 0."""
    iter_file = review_dir / "iteration.txt"
    if iter_file.exists():
        return int(iter_file.read_text().strip())
    return 0

def increment_iteration(review_dir: Path) -> int:
    """Increment and return new iteration count."""
    current = get_iteration(review_dir)
    new_iter = current + 1
    (review_dir / "iteration.txt").write_text(str(new_iter))
    return new_iter

def reset_iteration(review_dir: Path) -> None:
    """Remove iteration file (reset to 0)."""
    iter_file = review_dir / "iteration.txt"
    if iter_file.exists():
        iter_file.unlink()
```

Lifecycle:
- **Increment**: After each revision request (non-PASS consensus)
- **Reset**: On artifact change detection, or when gate resolves with all-PASS

### Review Archiving

Before spawning new reviewers, archive existing reviews:

```python
def archive_reviews(review_dir: Path, reviews_dir: Path, iteration: int) -> Optional[Path]:
    """Archive reviews directory to reviews-iter-N, return archive path or None."""
    if not reviews_dir.exists():
        return None

    # Check if any .json files exist
    if not any(reviews_dir.glob("*.json")):
        return None

    archive_name = f"reviews-iter-{iteration}"
    archive_path = review_dir / archive_name

    # Handle collision with timestamp suffix
    if archive_path.exists():
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        archive_name = f"reviews-iter-{iteration}-{timestamp}"
        archive_path = review_dir / archive_name

    reviews_dir.rename(archive_path)
    return archive_path
```

Called from:
- `spawn` command before creating fresh `$REVIEWS_DIR`
- `check` command's `clean_for_rerun()` before respawning after revision

### Previous Review Injection

On iterative reviews, prior round results are injected into the prompt before `## Output Format`:

```python
def get_previous_reviews(review_dir: Path) -> str:
    """Find most recent archive and format previous reviews for prompt injection."""
    # Find all review archives
    archives = []
    for archive_dir in review_dir.glob("reviews-iter-*"):
        if not archive_dir.is_dir():
            continue
        # Extract iteration number from name
        name = archive_dir.name
        match = re.match(r"reviews-iter-(\d+)", name)
        if match:
            iter_num = int(match.group(1))
            # For sorting ties, use full name (timestamp suffix sorts correctly)
            archives.append((iter_num, name, archive_dir))

    if not archives:
        return ""

    # Sort by iteration number, then by name (for timestamp tiebreaker)
    archives.sort(key=lambda x: (x[0], x[1]))
    latest_iter, _, latest_archive = archives[-1]

    # Format output
    lines = [
        f"## Previous Reviews (Iteration {latest_iter})",
        "",
        "You have access to the reviews from your previous iteration. "
        "Use these to understand what issues were raised and ensure they have been addressed.",
        "",
    ]

    for reviewer_file in latest_archive.glob("*.json"):
        reviewer_name = reviewer_file.stem
        # Skip non-review files
        if reviewer_name in ("review-schema", "review"):
            continue

        lines.append(f"### Previous Review: {reviewer_name}")
        lines.append("")

        try:
            result = extract_review_result(reviewer_file)
            lines.append(f"**Verdict:** {result.verdict}")
            if result.summary:
                lines.append(f"**Summary:** {result.summary}")
            if result.findings:
                lines.append("**Findings:**")
                for finding in result.findings:
                    lines.append(f"- {finding.title}")
        except Exception:
            lines.append("(Could not parse review output)")

        lines.append("")

    return "\n".join(lines)
```

Injection point: Before `## Output Format` section in prompt, or appended if section not found.

This is called from:
- `spawn` command's `build_prompt()` for generic reviews
- `spawn-code-review` via `code_review_previous_reviews()`
- `spawn-plan-review` and `spawn-spec-review` similarly

## Migration Phases

### Phase 1: Core Infrastructure
- Port `extract_last_json_object` to `reviewers/extraction.py`
- Implement full `core/state.py` with all fields and null-vs-empty semantics
- Implement `core/session.py` (get_project_hash, resolve_review_dir, find_active_gate)
- Implement `core/config.py` (mode resolution with all model/effort mappings)
- Implement `core/iteration.py` (iteration tracking, archiving)

### Phase 2: Reviewer Orchestration
- Implement `reviewers/base.py` with Reviewer ABC
- Implement Codex reviewer with schema generation, reasoning effort, extraction
- Implement Gemini reviewer with output format handling
- Implement Claude reviewer with metadata unwrapping
- Implement `reviewers/poller.py` with sentinel file checking

### Phase 3: Prompts and Formatting
- Implement `prompts/builder.py` with full search order
- Implement `prompts/revisions.py` with placeholder substitution
- Implement `consensus/calculate.py` with unanimous-pass logic
- Implement `consensus/formatting.py` (results table, issue collection, revision instructions)

### Phase 4: CLI Commands
- Set up Click CLI skeleton with all commands
- Port `check` command with full stop-hook behavior (deadlock prevention, artifact change detection, max-iter auto-proceed, polling)
- Port `spawn` with all flags (--type, --session-id, --transcript-path)
- Port `spawn-code-review` with all diff modes and base-sha tracking
- Port `spawn-plan-review` and `spawn-spec-review`
- Port `resolve` with --reason flag
- Port `wait` with full JSON schema and exit codes
- Port `artifact-path` and `author-context` (including stdin reading, --clear)

### Phase 5: Integration and Testing
- Update `bin/review-gate` to thin Python wrapper
- Test all commands against existing bash behavior
- Verify hook integration (block/allow output, exit codes)
- Test iteration flow end-to-end

### Phase 6: Cleanup
- Remove bash scripts
- Update documentation

## Dependencies

```toml
[project]
name = "cerberus"
version = "2.0.0"
requires-python = ">=3.10"
dependencies = [
    "click>=8.0",
]

[project.optional-dependencies]
dev = ["pytest", "pytest-asyncio"]

[project.scripts]
review-gate = "cerberus.cli:main"
```

## Environment Variables

Must honor all existing env vars:
- `REVIEW_GATE_SESSION_KEY` - session key override
- `REVIEW_GATE_SESSION_ID` - session ID override
- `REVIEW_GATE_TRANSCRIPT_PATH` - transcript path override
- `REVIEW_GATE_MAX_ROUNDS` - default max iterations
- `REVIEW_GATE_MAX_WAIT_SECONDS` - polling timeout (default 600)
- `REVIEW_GATE_POLL_INTERVAL_SECONDS` - poll interval (default 3)
- `REVIEW_GATE_LOG_FILE` - custom log file path
- `REVIEW_GATE_AUTHOR_CONTEXT` - author context override
- `REVIEW_GATE_BASE_SHA` - base SHA for iterative code reviews
- `REVIEW_GATE_DIFF_ARGS` - diff args for re-spawn
- `REVIEW_GATE_PROMPT_FILE` - prebuilt prompt file
- `REVIEW_TYPE` - review type override
- `CLAUDE_SESSION_ID`, `CLAUDE_TRANSCRIPT_PATH` - Claude session info
- `CLAUDE_PROJECT_DIR`, `CLAUDE_PLUGIN_ROOT` - plugin paths
- `CODEX_MODEL`, `GEMINI_MODEL`, `CLAUDE_MODEL` - model overrides
- `CODEX_REVIEW_REASONING_EFFORT`, `CODEX_GENERATE_REASONING_EFFORT` - effort overrides

## Backwards Compatibility

- CLI interface identical (same commands, same flags, same defaults)
- State file format (gate-state.json) byte-compatible where possible
- Hook integration unchanged (reads stdin JSON, outputs block/allow JSON)
- All environment variables honored with same semantics
- Template search order preserved
- Iteration/archive naming preserved
