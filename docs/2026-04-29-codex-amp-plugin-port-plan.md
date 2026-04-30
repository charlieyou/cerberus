# Implementation Plan: Port Cerberus to Codex and Amp

> **Status:** Synthesized plan (revised 2026-04-29). Decisions baked in:
> `CERBERUS_RUN_KEY` is canonical; `REVIEW_GATE_SESSION_KEY` is a
> back-compat alias indefinitely. State layout is
> `~/.cerberus/projects/<project-key>/<run-key>/` for non-Claude hosts,
> with `"host"` recorded in `gate-state.json`. New `status --json`
> command (non-mutating, non-blocking). Codex `Stop` never waits by
> default; opt-in via `CERBERUS_CODEX_STOP_WAIT_SECONDS=N`. Codex install
> is two-step (`.codex-plugin/plugin.json` for skills + user-installed
> `templates/codex-hooks.json` for hooks). Amp run-key fallback: UUID
> persisted at `~/.cerberus/runtime/amp/<workspace-key>/active-session.json`.
> Amp lifecycle handlers OUT of v1. Resolver lives inline in
> `bin/review-gate-lib.sh`. `CERBERUS_HOST=generic` is first-class.
> Three sequential releases (Phase 0 backend → Codex → Amp).

## Context & Goals

- **Spec / starting artifact:** This plan is a refinement of an earlier
  draft at this same path plus `docs/2026-04-29-amp-plugin-port-plan.md`
  (Amp-only predecessor, superseded). No external spec file exists.
- **Current state:** Cerberus is a Claude Code plugin. The working review
  engine is shell-based and lives in `bin/review-gate` (4821 lines),
  `bin/generate` (739 lines), and the shared `bin/review-gate-*.sh`
  libraries. Session/state resolution hardcodes Claude's
  `~/.claude/projects/<hash>/cerberus/<session-id>` layout in
  `bin/review-gate-lib.sh:34-48` (`resolve_review_dir`) with project
  hashing in `bin/review-gate-lib.sh:17-31` (`get_project_hash`).
- **Target state:** Cerberus works in Claude Code, Codex, and Amp without
  forking the review engine. v1 keeps Claude byte-for-byte and adds
  host-neutral seams plus thin per-host adapters.
- **Primary strategy:** First add host-neutral seams in the shared shell
  backend; then add thin host adapters for Codex and Amp one at a time.
- **Implementation order:** Shared backend changes first (Phase 0), Codex
  second (Phase 1), Amp third (Phase 2).
- **MVP outcome:** Codex and Amp users can run code, plan, and spec
  reviews, ask the Cerberus panel questions, inspect status, and clear
  gates while existing Claude behavior remains unchanged.
- **Non-goal for v1:** Full parity for Claude-only agent-team flows
  (`TaskCompleted`, `TeammateIdle`, `/cerberus:run-team`).

## Scope & Non-Goals

### In Scope

- A host-neutral runtime contract (`CERBERUS_*` env vars) for the existing
  shell backend.
- State-root and run-key support that works without Claude session metadata.
- Preserve existing Claude Code plugin packaging, hooks, commands, and
  tests byte-for-byte.
- Add Codex plugin/skill packaging and Codex hook setup around the shared
  backend.
- Add an Amp TypeScript plugin adapter around the shared backend.
- A new `status --json` command (non-mutating, non-blocking) for fast
  lifecycle reads.
- `CERBERUS_HOST=generic` mode for CI and external orchestrators.
- Documentation: install, usage, limitations, and host-specific behavior
  for Codex and Amp.

### Out Of Scope

- Rewriting `bin/review-gate` or `bin/generate` in TypeScript or any
  other language.
- Replacing the Codex, Gemini, or Claude reviewer CLIs.
- Migrating existing Claude users from `~/.claude/projects` to
  `~/.cerberus` by default.
- Porting Claude agent-team automation (`/cerberus:run-team`,
  `cerberus-task-completed-hook`, `cerberus-teammate-idle-hook`) in v1.
- Adding a daemon, external queue, or long-lived service.
- Amp lifecycle handlers (`session.start`, `agent.start`, `agent.end`)
  in v1 — explicit commands only.
- Neutral plan/spec registry — non-Claude hosts require explicit paths
  in v1.

## Assumptions & Constraints

### Implementation Constraints

- **Additive only on Claude path.** No file renames, no Claude state
  relocation, no behavior changes for Claude users in v1. The shared
  resolver must keep the Claude branch byte-for-byte equivalent at the
  state-path level when no `CERBERUS_*` env is set.
- **Backend stays Bash + jq + python3.** No rewrite of `bin/review-gate`
  in any other language. Host adapters may be small TS/JS (Amp) or shell
  (Codex).
- **State-on-disk is authoritative.** All host adapters must reattach
  using disk state + run key; in-memory plugin state is a cache only.
- **Reviewer CLI invocation stays shared.** Only host identity, command
  UX, lifecycle plumbing, and output presentation differ between hosts.
- **Canonical run-key name is `CERBERUS_RUN_KEY`.** It is the documented
  primary in v1. `REVIEW_GATE_SESSION_KEY` remains a fully supported
  alias indefinitely (zero migration required for existing CI/external
  callers).
- **Alias precedence (single rule, applied uniformly):** at every
  read site, `CERBERUS_*` wins over the legacy alias when **both** are
  set and **non-empty**. Empty strings are treated as unset (matches the
  existing `${VAR:-}` Bash idiom). When `CERBERUS_RUN_KEY` and
  `REVIEW_GATE_SESSION_KEY` differ, the backend uses `CERBERUS_RUN_KEY`
  and emits a single warning to stderr via the existing `log()` helper.
- **Host-neutral resolver is inline in `bin/review-gate-lib.sh`.** The
  neutral branch is added directly to `resolve_review_dir` /
  `get_project_hash`, not split into a new helper file. Keeps cohesion
  with existing path logic and avoids cross-file sourcing churn. Creating
  `bin/review-gate-host.sh` or any equivalent helper is explicitly
  disallowed.
- **`CERBERUS_HOST=generic`** is a first-class supported mode for CI and
  external orchestrators. Phase 0 tests cover it as its own row in the
  state-resolution test matrix.
- **Centralized env reads.** Every read site that currently reads
  `${REVIEW_GATE_SESSION_KEY:-}` is replaced with a single helper
  (`__cerberus_resolve_run_key`) defined near the top of
  `bin/review-gate`. `${CLAUDE_PLUGIN_ROOT:-}` reads route through
  `__cerberus_resolve_root`. Mechanical search-and-replace gated by
  tests; deviations from the helper require an explicit comment
  justifying why.
- **Atomic-write reuse.** All new registry/state writes reuse the
  existing `tmp.$$` + `mv` idiom from `bin/review-gate-lib.sh:171-174`
  and `:357-362`. No new locking primitive.
- **No central feature flag.** Neutral behavior is opt-in through
  `CERBERUS_*` env vars. Codex lifecycle behavior is opt-in through
  hook template installation.
- **`CERBERUS_CODEX_STOP_WAIT_SECONDS=N`** is the only v1 wait knob for
  Codex `Stop`. Default is `0` (never wait).

### Testing Constraints

- All existing `bin/tests/*.sh` tests (~25 of them) must pass unchanged
  on the Claude path.
- New tests must use `HOME` overrides + temp dirs (the existing test
  pattern). No tests touch real `~/.claude/` or `~/.cerberus/`.
- **Coverage target for new code paths:** every new branch in
  `resolve_review_dir`, every new `CERBERUS_*` env handling site, the
  Codex `SessionStart`/`Stop` adapters, and the Amp shell helper each
  get at least one happy-path test and one failure-mode test.
- **"No regression" gate:** full Claude `bin/tests/*.sh` suite passes +
  manual smoke that an existing Claude review still spawns, waits,
  resolves, and clears successfully.
- **Concurrency tests required** for Phase 0 (two concurrent runs in
  same project resolve to distinct dirs with distinct run keys) and
  Phase 1 (registry atomic write under concurrent `SessionStart`
  invocations).

### Host Assumptions

- **Codex:** Has lifecycle hook JSON (`SessionStart`, `Stop`) but **no
  `CLAUDE_ENV_FILE` equivalent** for persisting env across invocations.
  Plugin packaging via `.codex-plugin/plugin.json` (skills only).
  Lifecycle hooks are installed via a separate `templates/codex-hooks.json`
  template that the user installs into their Codex config (two-step
  install). Plugin install root path is **not assumed stable** — hook
  templates document the expected substitution and Phase 1 includes a
  small spike to confirm or refute (OQ-2).
- **Amp:** TypeScript plugin under `.amp/plugins/`. Requires
  `PLUGINS=all amp`. Plugin code runs in Bun. Exposes
  `amp.registerCommand`, lifecycle events `session.start`,
  `agent.start`, `agent.end`, `tool.call`, `tool.result`, and
  `agent.end → { action: "continue", userMessage }` for soft continuation.
  Plugin API requires the experimental directive comment.
- **Amp run-key durability:** `ctx.thread.id` is the preferred run key
  when present and stable. If unavailable or unstable, the Amp shell
  helper generates a UUID per workspace and persists it at
  `~/.cerberus/runtime/amp/<workspace-key>/active-session.json` (mirrors
  the Codex registry shape).
- **Plan registry deferred:** non-Claude hosts require an **explicit
  plan or spec path** in v1 for `review-plan` / `review-spec`. A neutral
  plan registry is reconsidered in Phase 3 (OQ-4).
- **Failure-open principle for lifecycle adapters.** Adapter failures
  generally fail open for host lifecycle exits, with diagnostics, unless
  blocking findings are successfully read from Cerberus state. Users
  must never be unable to stop Codex due to a Cerberus bug.

## Integration Analysis

### Existing Mechanisms Considered

| Existing Mechanism | File / Lines | Decision | Rationale |
|---|---|---|---|
| `resolve_review_dir` | `bin/review-gate-lib.sh:34-48` | **Extend** | Add neutral branch upstream of Claude default; keep Claude default unchanged. |
| `get_project_hash` | `bin/review-gate-lib.sh:17-31` | **Extend** | Add `CERBERUS_PROJECT_KEY` override; keep transcript/git/cwd fallbacks. |
| `REVIEW_GATE_SESSION_KEY` | plumbed through `bin/review-gate`, hooks | **Promote** | Already a neutral seam; alias `CERBERUS_RUN_KEY` to it. Indefinite back-compat. |
| `CLAUDE_PLUGIN_ROOT` | `bin/review-gate:23`, `bin/generate:14`, all `commands/*.md` | **Extend** | Add `CERBERUS_ROOT` alias; keep `CLAUDE_PLUGIN_ROOT` as fallback. |
| `bin/review-gate` `spawn-*` env reads | sites: 723, 948, 1218–1219, 1239–1240, 1421, 1594–1595, 1630–1631, 1770, 1925–1926, 1960–1961, 2088, 2324–2325, 2361–2362, 2522, 2650–2651, 2688, 2697–2698, 2749, 2762, 2817–2820, 2955, 4194–4195 | **Extend** | Each handler reads session via env; widen to read neutral env first via centralized helper. |
| `wait --json` | `bin/review-gate:4293+` | **Keep + add `status --json`** | `wait` polls/finalizes and exits 4 when no reviewers; non-mutating fast read needs distinct command. |
| `find_active_gate` | `bin/review-gate-lib.sh` | **Extend carefully** | Useful for legacy fallback, but non-Claude adapters prefer registry or explicit run key. |
| Claude `Stop` hook (`bin/review-gate-hook.sh`) | 2164 lines | **Keep + new thin Codex adapter** | Tightly coupled to Claude hook JSON & continuation semantics. Out of v1 modification scope. |
| Claude `SessionStart` (`bin/claude-session-init`) | 25 lines | **Keep + new Codex adapter** | Uses Claude-only `CLAUDE_ENV_FILE`. Out of v1 modification scope. |
| Slash commands `commands/*.md` | 13 files | **Keep + add** | Markdown commands are Claude prompt files. Codex gets skills under `skills/cerberus/`; Amp gets TS commands. |
| Plugin manifest | `.claude-plugin/plugin.json` | **Keep + add** | Separate `.codex-plugin/plugin.json` for Codex. |
| `bin/generate` | 739 lines | **Extend** | Already mostly host-neutral; alias `CERBERUS_ROOT` → `CLAUDE_PLUGIN_ROOT` at single read site. |
| `bin/telemetry-lib.sh` | — | **Reuse unchanged** | Telemetry writes under the provided `review_dir`; new layout works automatically because `$REVIEW_DIR` is the resolver output. |
| Atomic-write pattern (`tmp.$$` + `mv`) | `bin/review-gate-lib.sh:171-174, 357-362` | **Reuse** | Same idiom for new Codex/Amp registry files. |
| Existing shell tests in `bin/tests/` | ~25 files | **Extend pattern** | Temp `HOME` and fixture-based shell tests match the new backend changes. |
| Agent-team hooks | `bin/cerberus-task-completed-hook`, `bin/cerberus-teammate-idle-hook` | **Defer** | Out of v1 scope (Phase 4 decision). |

### Integration Approach

The shared backend (`bin/review-gate*.sh`, `bin/generate`) gains a thin
host-neutral resolution layer that runs **upstream** of Claude's path
and falls **back** to the existing Claude branch when neutral inputs
are absent. Claude callers keep working with no env changes; new hosts
opt in by setting `CERBERUS_*` vars.

Codex and Amp adapters never call into the Claude `Stop`/`SessionStart`
adapters. They are independent thin wrappers that translate
host-specific JSON/event payloads into the same neutral env the shared
backend reads. This avoids a single shared lifecycle path that would
have to special-case three host shapes.

The atomic-write idiom already used for `iteration.json` and
`gate-state.json` (`*.tmp.$$` + `mv`) is reused verbatim for the new
registry files (`active-session.json`) — no new locking primitive.

## Prerequisites

- [ ] **OQ-1 spike (Phase 1):** confirm exact Codex skill manifest fields
      and required vs optional members. Block Phase 1 implementation
      until resolved (or documented as best-effort).
- [ ] **OQ-2 spike (Phase 1):** confirm whether Codex exposes a stable
      plugin-install path env var. If not, document manual hook-template
      edit step in `docs/CODEX.md`.
- [ ] **OQ-3 spike (Phase 2):** confirm Amp `ctx.thread.id` durability
      across both command handlers and lifecycle hooks. Architecture
      already designs for the no-durable-thread-id case; spike informs
      default-path behavior, not architecture.
- [ ] Reviewer CLIs (`codex`, `gemini`, `claude`, `jq`, `python3`) and
      `git` installed in CI and on smoke-test machines.
- [ ] **Bun (or the Amp CLI which bundles Bun)** installed on Phase 2 CI
      and smoke-test machines. Required for Phase 2 E2E test that drives
      `.amp/plugins/cerberus.ts` via Bun.
- [ ] Repo-trust requirements for Codex repo-local hooks documented in
      `docs/CODEX.md`.
- [ ] Phase 0 ships and is exercised on the Claude path before Phase 1
      begins (sequential release strategy).
- [ ] Confirm product acceptance for Codex `Stop` failing open on
      adapter/internal errors and only continuing when blocking findings
      are successfully read.
- [ ] Confirm v1 limitation that non-Claude `review-plan` and
      `review-spec` require explicit paths.

## High-Level Approach

```text
     Claude hooks      Codex hooks+skills      Amp plugin commands
          \                  |                          /
           \                 v                         /
            +--------> host adapter / env mapping <----+
                                |
                                v
                bin/review-gate / bin/generate (shared)
                                |
                                v
                Cerberus state on disk (host-aware paths)
```

Five phases, each independently shippable:

1. **Phase 0 — Shared backend neutralization** (mandatory; ships first).
2. **Phase 1 — Codex port** (forces hard portability without Claude
   env-file persistence).
3. **Phase 2 — Amp port** (TypeScript adapter over the same neutral
   backend).
4. **Phase 3 — Generator workflow ports** (`healthcheck`,
   `architecture-review`, `create-plan`, `create-spec`).
5. **Phase 4 — Team automation revisit** (decision-only; separate
   design doc before any code).

Phases 0–2 form the v1 cross-host release. Phases 3–4 ship later.

## Technical Design

### Architecture

**Layering:**

1. **Shared backend** — `bin/review-gate`, `bin/generate`,
   `bin/review-gate-*.sh`. Owns reviewer orchestration, consensus,
   debate, telemetry, and persisted review state. Becomes host-neutral
   in Phase 0.
2. **Host adapter layer** — translates host identity, lifecycle events,
   and command UX into shared-backend invocations.
   - Claude (unchanged): `bin/review-gate-hook.sh`,
     `bin/claude-session-init`.
   - Codex (new): `bin/codex-stop-hook`, `bin/codex-session-init`.
   - Amp (new): `.amp/plugins/cerberus.ts` + an internal shell-helper
     module inside that plugin.
3. **Packaging / install surface:** `.claude-plugin/`, `.codex-plugin/`,
   `.amp/plugins/`. Each host has its own packaging directory; none
   share files.

**Run identity model:**

| Concept | Meaning | Example sources |
|---|---|---|
| Host | Product running Cerberus | `claude`, `codex`, `amp`, `generic` |
| Project key | Stable workspace identifier | Project-root hash or host-provided workspace id |
| Host session id | Native conversation/session id | Claude session id, Codex session id, Amp thread id |
| Run key | Cerberus review identity | Defaults to host session/thread id when stable; falls back to persisted UUID |

### State Resolution Algorithm

The host-neutral resolver lives inline in `bin/review-gate-lib.sh`,
extending `resolve_review_dir` and `get_project_hash`. Pseudocode:

```text
resolve_review_dir(session_id, transcript_path):
  # Step 1: resolve effective run key.
  # Delegates to __cerberus_resolve_run_key (defined in bin/review-gate)
  # which owns the single source of truth for run-key precedence AND
  # the once-per-process alias-mismatch warning. Falls back to the
  # session_id positional if the helper returns empty.
  run_key = $(__cerberus_resolve_run_key)
  if run_key empty:
    run_key = session_id      # CLI positional, used by Claude path today
  # No additional warning emitted here: __cerberus_resolve_run_key
  # already emits one (guarded by __CERBERUS_ALIAS_WARNED).

  # Step 2: resolve effective host
  host = $CERBERUS_HOST
  if host empty:
    if any of (CLAUDE_SESSION_ID, CLAUDE_TRANSCRIPT_PATH,
               CLAUDE_PROJECT_DIR) is set:
      host = "claude"
    else:
      host = "generic"
  validate host in { "claude", "codex", "amp", "generic" }

  # Step 3: resolve state root
  if $CERBERUS_STATE_ROOT non-empty:
    state_root = $CERBERUS_STATE_ROOT
    require absolute path; reject "", "~", relative paths.
  elif host == "claude":
    state_root = "$HOME/.claude/projects"   # legacy
  else:
    state_root = "$HOME/.cerberus/projects" # neutral

  # Step 4: resolve project key
  project_key = first_nonempty(
    $CERBERUS_PROJECT_KEY,
    get_project_hash(transcript_path)        # existing fn, unchanged
  )
  validate project_key: reject "/", NUL, ".", "..".

  # Step 5: build path
  if host == "claude":
    base = "$state_root/$project_key/cerberus"   # legacy layout
  else:
    base = "$state_root/$project_key"            # neutral layout

  if run_key non-empty:
    return "$base/$run_key"
  else:
    return "$base"
```

**Byte-for-byte Claude equivalence:** when no `CERBERUS_*` is set, step
2 picks `claude`, step 3 picks `~/.claude/projects`, step 5 appends
`cerberus/<run-key>` — exactly the current
`~/.claude/projects/<hash>/cerberus/<session-id>/` path.

**`get_project_hash` extension:** prepend a single check for
`$CERBERUS_PROJECT_KEY`; if set and non-empty, echo it and return.
Otherwise existing logic (transcript-derived hash, then git top-level,
then cwd) runs unchanged.

**Validation rules:**

- `run_key`, `project_key`: reject `/`, NUL-equivalent shell input, `.`,
  `..` to avoid path traversal.
- `CERBERUS_STATE_ROOT`: must be a non-empty absolute path. Empty,
  relative, or literal `~` paths fail before any directory creation.

**Env precedence flowchart (canonical):**

```text
                run-key resolution
        +-------------------------------+
        | CERBERUS_RUN_KEY non-empty?   |
        +-------------------------------+
            yes  |              | no
                 v              v
    use CERBERUS_RUN_KEY    +-----------------------------+
    (warn if               | REVIEW_GATE_SESSION_KEY      |
     legacy alias differs) | non-empty?                   |
                           +-----------------------------+
                                yes |          | no
                                    v          v
                        use legacy alias   +-------------+
                                           | session_id  |
                                           | positional? |
                                           +-------------+
                                              yes |  | no
                                                  v  v
                                              use it  fail
                                                      "missing
                                                       run key"

                host resolution
        +-------------------------------+
        | CERBERUS_HOST set & valid?    |
        +-------------------------------+
            yes  |              | no
                 v              v
        use CERBERUS_HOST   +-------------------------+
                            | any CLAUDE_* env set?   |
                            +-------------------------+
                                yes |        | no
                                    v        v
                               "claude"   "generic"

                state-root resolution
        +-------------------------------+
        | CERBERUS_STATE_ROOT set?      |
        +-------------------------------+
            yes  |              | no
                 v              v
       validate absolute   +-------------------------+
       path; reject        | host == claude?         |
       empty/relative      +-------------------------+
                                yes |        | no
                                    v        v
                       ~/.claude/projects   ~/.cerberus/projects
```

### Data Model

**Disk state layout (Claude, unchanged):**

```text
~/.claude/projects/<project-hash>/cerberus/<session-id>/
  gate-state.json
  latest.md
  iteration.txt
  reviews/
  iterations/
  run-telemetry.json   # produced by telemetry-lib.sh
```

**Disk state layout (non-Claude hosts):**

```text
~/.cerberus/projects/<project-key>/<run-key>/
  gate-state.json   # contains "host": "codex" | "amp" | "generic"
  latest.md
  iteration.txt
  reviews/
  iterations/
  run-telemetry.json
```

`gate-state.json` records the originating host as a top-level field so
multiple hosts can share a project tree without colliding on run keys,
and tools can later filter by host. Existing fields are preserved; the
neutral additions are:

```json
{
  "host": "codex",
  "owner": {
    "host": "codex",
    "project_key": "<project-key>",
    "session_id": "<host-session-or-thread-id>",
    "run_key": "<run-key>",
    "session_key": "<run-key>",
    "transcript_path": "<optional>"
  }
}
```

`owner.session_key` remains for existing `wait --session-key`
compatibility. `owner.run_key` is the canonical new field.

**Telemetry note:** telemetry artifacts (`run-telemetry.json`,
`iterations/<n>/iteration.json`) are written relative to `$REVIEW_DIR`.
Because `$REVIEW_DIR` is the output of `resolve_review_dir`, telemetry
**automatically** follows the new layout. No `bin/telemetry-lib.sh`
changes required.

**Codex session registry:**

```text
~/.cerberus/runtime/codex/<workspace-key>/active-session.json
```

**Amp fallback session registry:**

```text
~/.cerberus/runtime/amp/<workspace-key>/active-session.json
```

**Registry schema (v1, both hosts):**

```json
{
  "schema_version": 1,
  "host": "codex",
  "workspace_root": "/abs/path",
  "project_key": "-Users-me-repo",
  "session_id": "<codex-session-id-or-amp-thread-id>",
  "run_key": "<run-key>",
  "transcript_path": "<optional path>",
  "last_seen": "2026-04-29T12:34:56Z"
}
```

The Amp variant additionally records `"amp_thread_id"` (or null when
unstable). The Codex variant records `"codex_session_id"` (alias for
`session_id`).

**Atomic-write algorithm (registries + new state writes):**

Identical to existing `bin/review-gate-lib.sh:171-174` pattern for
`iteration.json`:

1. `mkdir -p` the parent directory.
2. Generate the desired JSON content (validated via `jq` where possible).
3. Write to `<file>.tmp.$$` in the same directory (PID suffix avoids
   collision; subshells/background jobs get distinct PIDs).
4. Validate the temp file contains valid JSON via `jq empty` (or
   equivalent). On failure: remove temp, log to stderr, return non-zero.
5. `mv <file>.tmp.$$ <file>` — POSIX `rename(2)` is atomic on the same
   filesystem, which holds because both paths sit under the user's
   `$HOME`.
6. On any error path before the `mv`: remove the temp file.

Concurrent registry writes for the same workspace are last-writer-wins
by design; older runs remain accessible by explicit `--session-key` /
`CERBERUS_RUN_KEY`. Each writer's run state lives under its own
`<run-key>/` directory; the registry is only a discovery cache, not
authoritative state.

**Concurrency limitations (documented v1):**

- Multi-session-per-workspace: registry holds the **most recent**
  session.
- Two concurrent `SessionStart` writes for the same workspace race on
  the registry; last writer wins.
- `gate-state.json` write contention: existing single-writer assumption
  preserved (one `bin/review-gate` process owns a given run); cross-host
  concurrent writes to the **same** run key are not supported and would
  have been broken under Claude as well.

### API/Interface Design

**Host-neutral env contract (read by shared backend):**

| Variable | Purpose | Alias / fallback |
|---|---|---|
| `CERBERUS_HOST` | `claude` \| `codex` \| `amp` \| `generic` | defaults to `claude` if any `CLAUDE_*` is set, else `generic` |
| `CERBERUS_ROOT` | Plugin/repo root | `CLAUDE_PLUGIN_ROOT` |
| `CERBERUS_STATE_ROOT` | Override for state base directory | host default (`~/.claude/projects` for Claude, `~/.cerberus/projects` otherwise) |
| `CERBERUS_PROJECT_KEY` | Stable workspace key | computed via `get_project_hash` fallback |
| `CERBERUS_SESSION_ID` | Host session/thread id | `CLAUDE_SESSION_ID` |
| `CERBERUS_RUN_KEY` | Cerberus review identity (canonical) | `REVIEW_GATE_SESSION_KEY` (back-compat alias, indefinite) |
| `CERBERUS_TRANSCRIPT_PATH` | Optional host transcript path | `CLAUDE_TRANSCRIPT_PATH`, `REVIEW_GATE_TRANSCRIPT_PATH` |
| `CERBERUS_CODEX_STOP_WAIT_SECONDS` | Bounded Codex `Stop` wait knob | default `0` (never wait) |

**Alias precedence rule:** `CERBERUS_*` wins over the legacy alias when
both are non-empty. Empty strings treated as unset. Differing values
emit a single stderr warning via `log()` and use `CERBERUS_*`.

**Centralized helpers (top of `bin/review-gate`):**

```bash
__cerberus_resolve_run_key() {
  local cer="${CERBERUS_RUN_KEY:-}"
  local leg="${REVIEW_GATE_SESSION_KEY:-}"
  # Once-per-process guard: this helper is invoked inside command
  # substitution at many sites (~25). resolve_review_dir() in
  # review-gate-lib.sh also performs the same alias check. The guard
  # below de-duplicates the warning across all sites within one process.
  if [ -n "$cer" ] && [ -n "$leg" ] && [ "$cer" != "$leg" ] \
     && [ -z "${__CERBERUS_ALIAS_WARNED:-}" ]; then
    # IMPORTANT: write directly to stderr (not log()) because this
    # function is called via $(...) and any stdout output would corrupt
    # the returned run key.
    echo "warning: CERBERUS_RUN_KEY != REVIEW_GATE_SESSION_KEY; using CERBERUS_RUN_KEY" >&2
    export __CERBERUS_ALIAS_WARNED=1
  fi
  echo "${cer:-${leg:-}}"
}

__cerberus_resolve_root() {
  echo "${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"
}
```

Every `${REVIEW_GATE_SESSION_KEY:-}` read site listed in
[Existing Mechanisms Considered] is replaced with
`$(__cerberus_resolve_run_key)`. Every `${CLAUDE_PLUGIN_ROOT:-}` read
site (`bin/review-gate:23`, `bin/generate:14`) is replaced with
`$(__cerberus_resolve_root)`. Mechanical replacement gated by tests.

**Neutral env propagation surface:** every site that re-enters the
backend in a subprocess must propagate `CERBERUS_HOST`, `CERBERUS_ROOT`,
`CERBERUS_STATE_ROOT`, `CERBERUS_PROJECT_KEY`, `CERBERUS_SESSION_ID`,
`CERBERUS_RUN_KEY`, `CERBERUS_TRANSCRIPT_PATH`, plus legacy aliases.
Sites: `spawn-code-review`, `spawn-plan-review`, `spawn-spec-review`,
`spawn-epic-verify`, `spawn-ask`, generic `spawn`, `artifact-path`,
`author-context`, `resolve`, `wait`, new `status`.

**Backend command surface:**

| Command | Design |
|---|---|
| `spawn-code-review` | Accept neutral env; write neutral state when `CERBERUS_RUN_KEY` is present. |
| `spawn-plan-review` | Same; non-Claude hosts require explicit plan path in v1. |
| `spawn-spec-review` | Same; explicit spec path required. |
| `spawn-ask` | Accept neutral env; reuse existing panel/debate behavior. |
| `spawn-epic-verify` | Accept neutral env. |
| `wait --json [--session-key K] [--timeout N]` | Already accepts these flags. Extends `--session-key` lookup to neutral state roots while preserving Claude lookup. Behavior otherwise unchanged. Exit 4 when no reviewers. |
| `status --json [--session-key K]` | **NEW.** Non-mutating, non-blocking. **`--session-key` lookup uses the same neutral-roots search path as `wait --session-key`** (see "Run-key lookup parity" below). See schema below. |

**Run-key lookup parity (`wait` and `status`):** both commands resolve a
session key by calling `resolve_review_dir(session_id="", transcript_path)`
internally with `CERBERUS_RUN_KEY` set to the explicit `--session-key`
value if passed. This means a Codex/Amp adapter can choose either of two
equivalent invocation styles:

1. **Env-passing style (recommended for hooks):** export
   `CERBERUS_HOST`, `CERBERUS_PROJECT_KEY`, `CERBERUS_RUN_KEY`,
   `CERBERUS_STATE_ROOT` from the registry, then call
   `bin/review-gate status --json` (or `wait --json`) with no
   `--session-key`.
2. **Flag-passing style (recommended for CLI/CI):** pass
   `--session-key <run-key>`. The flag handler temporarily sets
   `CERBERUS_RUN_KEY` so `resolve_review_dir` resolves the same path.

Both styles search the same neutral-roots tree, in the same order, and
produce identical state paths. Phase 0 tests cover both styles for
`wait` and `status` (rows 14–15 in the state-resolution test matrix).
| `resolve --reason <text>` | Accept neutral env. |
| `artifact-path` | Print neutral `latest.md` when neutral env is present. |
| `author-context` | Read/write author context in resolved review directory. |

**`status --json` JSON output schema (canonical):**

`status --json` is a thin wrapper that reads `gate-state.json` +
`reviews/` and renders a JSON shape compatible with
`wait --json --timeout 0`. The contract:

- **Never** writes anything (no telemetry side-effect, no
  `iteration.json` rotation, no `gate-state.json` mutation).
- **Never** blocks (no polling loop, no sleeps).
- Reads only committed files; ignores `*.tmp.$$` files.

Exit codes (consistent with `wait --json` where applicable):

| Exit | Meaning |
|---|---|
| `0` | State successfully read. Body has `status` field set. |
| `2` | Internal error (e.g., resolver failure unrelated to missing state). |
| `4` | No active gate state exists for the resolved run key. Body: `{"status":"no_active_gate"}`. |

JSON shape (sample, gate pending):

```json
{
  "schema_version": 1,
  "host": "codex",
  "project_key": "-Users-me-repo",
  "run_key": "<run-key>",
  "review_dir": "/abs/path/to/<run-key>",
  "gate_status": "pending",
  "consensus_verdict": null,
  "reviewers": [
    { "name": "codex", "status": "pending" },
    { "name": "gemini", "status": "complete", "verdict": "pass" }
  ],
  "pending_reviewers": ["codex"],
  "aggregated_findings": [],
  "parse_errors": []
}
```

Field types:

- `schema_version` (int): always `1` in v1.
- `host` (string): `"claude"` | `"codex"` | `"amp"` | `"generic"`.
- `project_key`, `run_key` (string).
- `review_dir` (string): absolute path.
- `gate_status` (string): `"pending"` | `"awaiting_decision"` |
  `"resolved"` | `"unknown"`.
- `consensus_verdict` (string|null): `"pass"` | `"fail"` |
  `"needs_revision"` | null.
- `reviewers` (array of objects): `{name, status, verdict?}`.
- `pending_reviewers` (array of strings): names still pending.
- `aggregated_findings` (array of objects): findings from completed
  reviewers. Each object has the following **required** fields:
  - `reviewer` (string): `"codex"` | `"gemini"` | `"claude"`.
  - `priority` (string): `"P0"` | `"P1"` | `"P2"` | `"P3"` (uppercase,
    normalized from reviewer output).
  - `verdict` (string): the issuing reviewer's verdict —
    `"PASS"` | `"FAIL"` | `"NEEDS_REVISION"` | `"ERROR"` (uppercase).
  - `summary` (string): one-line description.
  Optional fields: `details` (string), `file_refs` (array of strings).
- `parse_errors` (array of strings): reviewer outputs that failed to
  parse.

**Blocking-finding predicate (canonical, used by Codex Stop matrix and
Amp `Cerberus: Status` UI):**

A finding is **blocking** iff:

```
finding.verdict == "FAIL"   OR   finding.priority IN { "P0", "P1" }
```

The Codex Stop matrix row 6 vs row 7 distinction is exactly:

- **Row 6 (continue):** `aggregated_findings` contains at least one
  blocking finding by the predicate above.
- **Row 7 (allow):** `aggregated_findings` is empty OR contains only
  non-blocking findings (P2/P3 with non-FAIL verdicts).

`bin/review-gate` is responsible for normalizing reviewer output into the
required-field shape; reviewers emitting partial findings (e.g., missing
`priority`) are recorded under `parse_errors` and treated as
**non-blocking** for predicate purposes (Codex Stop allows; user can
re-check via `Cerberus: Status` once parse-error is remediated).

Special bodies:

- No active gate (exit 4): `{"status":"no_active_gate"}`.
- Malformed `gate-state.json` (exit 0):
  `{"status":"unknown","error":"malformed_state"}` (failure-open for
  Codex `Stop`).

`pending_reviewers` differentiates pending vs `wait`'s timeout
semantics: `status` returns `"pending"` for unfinished reviewers, never
`"timeout"`.

### Codex Stop Decision Matrix

The Codex `Stop` adapter (`bin/codex-stop-hook`) reads `status --json
--session-key <run>` once, then maps the result to a Codex hook
response. The hook **always exits 0** and emits a single JSON blob to
stdout. Long operations (waits) sit between the initial `status` read
and a re-evaluation.

| # | Gate state (initial `status --json`) | `CERBERUS_CODEX_STOP_WAIT_SECONDS` | Action |
|---|---|---|---|
| 1 | `status --json` exits 4 (no active gate) | any | `{"action":"allow"}` |
| 2 | Registry file missing | any | `{"action":"allow"}` (no run to look up) |
| 3 | Registry present but `<run-key>/` missing | any | `{"action":"allow","note":"no review dir"}` |
| 4 | `gate_status == "pending"` | `0` (default) | `{"action":"allow","note":"reviewers still running; run Cerberus: Status to check"}` |
| 5 | `gate_status == "pending"` | `N > 0` | Run `wait --json --timeout N --session-key <run>`; on completion re-evaluate via row 6/7/8/9. On wait timeout: emit row 4 message. |
| 6 | `gate_status == "awaiting_decision"` AND blocking findings present (per blocking-finding predicate above: any finding with `verdict=="FAIL"` OR `priority` in `{"P0","P1"}`) | any | `{"action":"continue","userMessage":"<formatted findings summary>"}` |
| 7 | `gate_status == "awaiting_decision"` AND no blocking findings (empty `aggregated_findings`, or only P2/P3 non-FAIL findings, or only `parse_errors`) | any | `{"action":"allow"}` (rare; finalize via existing `wait` path before reaching here) |
| 8 | `gate_status == "resolved"` AND `consensus_verdict == "pass"` | any | `{"action":"allow"}` |
| 9 | `gate_status == "resolved"` AND `consensus_verdict == "fail"` (manual clear or otherwise) | any | `{"action":"continue","userMessage":"<reason>"}` |
| 10 | Malformed `gate-state.json` (exit 0, body has `error`) | any | `{"action":"allow","note":"cerberus state unreadable; allowing stop"}` |
| 11 | `status --json` exits non-zero, non-4 (internal error) | any | log to stderr, emit `{"action":"allow"}`, exit 0 |
| 12 | `jq` missing or backend not invokable | any | log to stderr, emit `{"action":"allow"}`, exit 0 |
| 13 | SIGINT/SIGTERM/SIGHUP received during execution | any | `trap` emits `{"action":"allow"}` to stdout, kills any child `wait`/`status` process, exits 0 |

**Failure-open principle:** the hook never blocks the user from stopping
due to a Cerberus failure. If state can't be read, allow. If a child
process hangs, the trap kills it and emits allow.

**Signal handling:** `bin/codex-stop-hook` installs
`trap '__cerberus_stop_safe_exit' INT TERM HUP` at startup.
`__cerberus_stop_safe_exit` does the minimum work necessary: kill the
backgrounded wait/status child (if any) via stored PID, emit
`{"action":"allow"}` to stdout, exit 0. No long-running operations
inside the trap.

**Codex skill surface:**

| Skill | Backend Call | Notes |
|---|---|---|
| `review-code` | `spawn-code-review` | `CERBERUS_HOST=codex`. |
| `review-plan` | `spawn-plan-review <plan-path>` | Explicit plan path required. |
| `review-spec` | `spawn-spec-review <spec-path>` | Explicit spec path required. |
| `ask-panel` | `spawn-ask` then `wait --json --finalize` where appropriate | Skill synthesizes from reviewer JSON. |
| `status` | `status --json` | Read-only. |
| `clear-gate` | `resolve --reason "manual clear from Codex"` | |

**Amp command surface (`.amp/plugins/cerberus.ts`):**

| Amp Command | Backend call |
|---|---|
| `Cerberus: Review Code` | `spawn-code-review` |
| `Cerberus: Review Plan <plan-path>` | `spawn-plan-review <plan-path>` |
| `Cerberus: Review Spec <spec-path>` | `spawn-spec-review <spec-path>` |
| `Cerberus: Ask Panel <question>` | `spawn-ask` + `wait --json --finalize` |
| `Cerberus: Status` | `status --json` |
| `Cerberus: Clear Gate` | `resolve --reason "manual clear from Amp"` |

The Amp shell helper inside `.amp/plugins/cerberus.ts` invokes
`bin/review-gate` with neutral env:

```text
CERBERUS_HOST=amp
CERBERUS_ROOT=<plugin root>
CERBERUS_STATE_ROOT=$HOME/.cerberus/projects   # neutral default
CERBERUS_PROJECT_KEY=<workspace-key>
CERBERUS_RUN_KEY=<thread-id-or-fallback-uuid>
CLAUDE_PLUGIN_ROOT=<plugin root>               # transient compat alias
```

### File Impact Summary

| Path | Status | Description |
|---|---|---|
| `bin/review-gate` | Exists | Add `__cerberus_resolve_run_key` and `__cerberus_resolve_root` helpers near top; replace ~25 call sites mechanically; widen env propagation; add `status --json` subcommand; extend `wait --session-key` to search neutral roots; record `host`/`owner` metadata. |
| `bin/review-gate-lib.sh` | Exists | Extend `resolve_review_dir` and `get_project_hash` per algorithm above. Inline only — no new file. |
| `bin/generate` | Exists | Alias `CERBERUS_ROOT` → `CLAUDE_PLUGIN_ROOT` at single read site (line 14). |
| `README.md` | Exists | Document new hosts at top-level (links to `docs/CODEX.md`, `docs/AMP.md`); document supported hosts, release phases, compatibility guarantees. |
| `bin/review-gate-hook.sh` | Exists, **unchanged** | Claude-only (2164 lines). |
| `bin/claude-session-init` | Exists, **unchanged** | Claude-only (25 lines). |
| `bin/cerberus-task-completed-hook` | Exists, **unchanged (deferred)** | Phase 4. |
| `bin/cerberus-teammate-idle-hook` | Exists, **unchanged (deferred)** | Phase 4. |
| `hooks/hooks.json` | Exists, **unchanged** | Claude packaging. |
| `.claude-plugin/plugin.json` | Exists, **unchanged** | Claude packaging. |
| `bin/review-gate-debate.sh` | Exists, **unchanged** | Backend module. |
| `bin/review-gate-models.sh` | Exists, **unchanged** | Backend module. |
| `bin/telemetry-lib.sh` | Exists, **unchanged** | Telemetry follows `$REVIEW_DIR` automatically. |
| `commands/*.md` | Exists, **unchanged** | Claude prompt files (13 files). |
| `gemini-readonly-policy.toml` | Exists, **review during Phase 0** | Confirm policy applies cleanly when Gemini reviewer is invoked from non-Claude hosts; document if any host-specific knobs needed. |
| `.codex-plugin/plugin.json` | **New** | Codex marketplace manifest (skills only). |
| `bin/codex-session-init` | **New** | `SessionStart` adapter; reads JSON from stdin, writes session registry atomically. |
| `bin/codex-stop-hook` | **New** | `Stop` adapter; implements the Codex Stop Decision Matrix; installs signal traps. |
| `skills/cerberus/review-code.md` | **New** | Codex skill: Review Code. |
| `skills/cerberus/review-plan.md` | **New** | Codex skill: Review Plan. |
| `skills/cerberus/review-spec.md` | **New** | Codex skill: Review Spec. |
| `skills/cerberus/ask.md` | **New** | Codex skill: Ask Panel. |
| `skills/cerberus/status.md` | **New** | Codex skill: Status. |
| `skills/cerberus/clear-gate.md` | **New** | Codex skill: Clear Gate. |
| `templates/codex-hooks.json` | **New** | User-installed lifecycle hook template (two-step install). |
| `.amp/plugins/cerberus.ts` | **New** | Amp plugin (commands + shell helper). Experimental directive comment required. |
| `.amp/in/` | Exists | Amp plugin input directory (already present; no changes). |
| `bin/tests/test-host-neutral-state.sh` | **New** | Phase 0: state-resolution decision matrix, alias precedence, validation. |
| `bin/tests/test-status-command.sh` | **New** | Phase 0: `status --json` contract; no-mutation invariant. |
| `bin/tests/test-codex-session-registry.sh` | **New** | Phase 1: registry write/read/atomicity, concurrent writes, refresh. |
| `bin/tests/test-codex-stop-hook.sh` | **New** | Phase 1: every row of the Stop matrix + signal handling. |
| `bin/tests/test-amp-shell-helper.sh` | **New** | Phase 2: env mapping correctness, fallback UUID generation, registry persistence. |
| `docs/CODEX.md` | **New** | User-facing install, hook setup, commands, limitations, troubleshooting. |
| `docs/AMP.md` | **New** | User-facing install, commands, limitations, troubleshooting. |

The host-neutral resolver lives **inline** in `bin/review-gate-lib.sh`,
extending `resolve_review_dir` and `get_project_hash` rather than adding
a new helper file.

## Implementation Phases

### Phase 0: Shared Backend Neutralization

**Purpose:** create the generic seams that both Codex and Amp use.

**Work:**

- Add `__cerberus_resolve_run_key` and `__cerberus_resolve_root`
  helpers near top of `bin/review-gate`.
- Mechanically replace ~25 `${REVIEW_GATE_SESSION_KEY:-}` reads at the
  enumerated line numbers, plus 2 `${CLAUDE_PLUGIN_ROOT:-}` reads, with
  the helpers.
- Extend `resolve_review_dir` and `get_project_hash` in
  `bin/review-gate-lib.sh` per the State Resolution Algorithm.
- Widen env propagation everywhere subprocesses re-enter the backend.
- Add new subcommand `status --json` in `bin/review-gate` (read-only
  wrapper over `gate-state.json` + `reviews/`).
- Extend `wait --session-key` AND `status --session-key` lookups to
  search neutral state roots in addition to Claude paths. Both share the
  same `resolve_review_dir` code path (run-key lookup parity contract).
- Record `host` and `owner` metadata in `gate-state.json` for non-Claude
  runs.
- Preserve Claude default state path, hook behavior, and tests
  byte-for-byte.

**Exit criteria (testable):**

- All existing Claude `bin/tests/*.sh` tests pass unchanged.
- A review can be spawned, waited on, inspected, and resolved using only
  neutral state variables and a run key (`CERBERUS_HOST=generic`, no
  `CLAUDE_*` env at all).
- A review runs without `CLAUDE_SESSION_ID`, `CLAUDE_TRANSCRIPT_PATH`,
  or any Claude transcript path.
- `artifact-path` and `author-context` work in both Claude legacy mode
  and neutral mode.
- `status --json` returns valid JSON for every gate state and never
  mutates state (verified by snapshot-equal invariant in tests).
- `wait --session-key` AND `status --session-key` both find neutral
  state when run-key is set (parity test in
  `test-host-neutral-state.sh`).
- Two concurrent `bin/review-gate spawn-code-review` invocations with
  distinct `CERBERUS_RUN_KEY` in the same project resolve to distinct
  directories.
- Empty/relative/missing `CERBERUS_STATE_ROOT` fails before creating
  directories.

### Phase 1: Codex Port

**Purpose:** add the first non-Claude host and prove lifecycle gating
outside Claude.

Codex comes before Amp because it forces the hard portability issue:
recovering session/run identity without Claude's env-file persistence.

**Work:**

- **Spike:** resolve OQ-1, OQ-2 before implementation begins.
- Add `.codex-plugin/plugin.json` declaring six skills.
- Author Tier 1 skill markdown under `skills/cerberus/` (six files:
  review-code, review-plan, review-spec, ask, status, clear-gate).
- Add `templates/codex-hooks.json` (user installs into Codex config).
- Implement `bin/codex-session-init`:
  - Read Codex `SessionStart` JSON from stdin.
  - Compute `project_key` from cwd or workspace root via existing
    `get_project_hash`.
  - Default `run_key` to Codex session id.
  - Atomic-write `~/.cerberus/runtime/codex/<workspace-key>/active-session.json`
    using the algorithm in [Data Model].
- Implement `bin/codex-stop-hook`:
  - Install signal traps (`trap '...' INT TERM HUP`) at startup.
  - Read Codex `Stop` JSON from stdin.
  - Look up active run via session registry.
  - Run `status --json --session-key <run-key>`.
  - Map result via the Codex Stop Decision Matrix.
  - On wait knob `N>0` and pending state: spawn
    `wait --json --timeout N --session-key <run>` as a child process,
    store PID for trap, re-evaluate on completion.
- Document repo-trust requirements for repo-local Codex hooks in
  `docs/CODEX.md`.

**Exit criteria (testable):**

- Codex `SessionStart` creates or refreshes the session registry
  atomically.
- Codex review skills can spawn reviewers and reattach to active state
  across `SessionStart`/`Stop` transitions.
- Codex `Stop` matrix behaves per spec for every row 1–13.
- `Clear Gate` resolves the intended run.
- Claude plugin behavior remains unchanged (full Claude suite passes).
- `gate-state.json` records `host: "codex"` for Codex-originated runs.

### Phase 2: Amp Port

**Purpose:** add Amp command-palette support over the same host-neutral
backend.

**Work:**

- **Spike:** resolve OQ-3.
- Add `.amp/plugins/cerberus.ts` with the experimental directive comment.
- Register six command-palette commands (Review Code, Review Plan,
  Review Spec, Ask Panel, Status, Clear Gate).
- Implement TypeScript shell helper invoking `bin/review-gate` with
  neutral env (mapping above).
- Use Amp `ctx.thread.id` as default run key when stable.
- If thread id not durable: generate workspace-scoped UUID; persist at
  `~/.cerberus/runtime/amp/<workspace-key>/active-session.json`. Surface
  run key in command output for explicit pass-through.
- Treat plugin memory as cache only; disk state is authoritative.
- **Lifecycle handlers (`session.start`, `agent.start`, `agent.end`)
  out of v1 scope.** Explicit commands only.

**Exit criteria (testable):**

- Amp commands register under `PLUGINS=all amp`.
- Amp can start code, plan, and spec reviews through the shared backend.
- Amp can reattach to status after plugin reload or CLI restart.
- Amp `Ask Panel` returns a synthesized in-thread answer.
- Amp `Clear Gate` resolves the intended run.
- Run key surfaced in command stdout for user pass-through.
- Claude and Codex behavior remain unchanged.

### Phase 3: Generator Workflow Ports

**Purpose:** broaden host parity after review workflows are stable.

**Work:**

- Port `healthcheck` and `architecture-review` first (generator-driven,
  less interactive).
- Port `create-plan` and `create-spec` after generator wrapping is
  stable.
- Keep prompt assets in `prompts/`; reuse `bin/generate`.
- Replace Claude slash-command assumptions with host-native command/skill
  instructions.
- **Decide:** OQ-4 (neutral plan registry vs explicit-only).

**Exit criteria:**

- Codex and Amp can run generator workflows without Claude slash-command
  semantics.
- Generated artifacts feed the same review gate.
- Host-specific limitations documented.

### Phase 4: Revisit Team Automation

**Purpose:** make an explicit decision about Claude-specific agent-team
workflows.

Deferred workflows: `/cerberus:run-team`, `agents/implementer.md`,
`bin/cerberus-task-completed-hook`, `bin/cerberus-teammate-idle-hook`.

Decision options: keep Claude-only / build separate external
orchestrator / port if Codex or Amp exposes equivalent task primitives.

**Exit criteria:**

- Separate design doc exists before any implementation.
- No half-ported team workflow advertised as supported.

## Risks, Edge Cases & Breaking Changes

### Edge Cases & Failure Modes

| Edge case / failure | Expected behavior |
|---|---|
| Concurrent runs in same workspace, distinct run keys | Each writes to its own `<run-key>/` dir; no contention. Registry holds latest `SessionStart`'s run key; older run still resolvable by explicit `--session-key`. |
| Concurrent `SessionStart` writes to same registry file | POSIX rename atomicity: last writer wins. State under each `<run-key>/` is unaffected. Logged via existing `log()` for forensics. |
| Concurrent `tmp.$$` collisions | `$$` is the writer's PID; in `&` background jobs PID differs; in subshells PID differs. Existing pattern is safe. |
| Run-key collision between hosts (unlikely) | `gate-state.json.host` field disambiguates; users see `host: amp` vs `host: codex` in `status --json` output. Spawn into existing dir with mismatched `host` fails with clear collision message rather than overwrite. |
| Run-key collision with same host | Last writer wins on registry; second spawn either reuses existing run dir (refresh) or fails depending on the existing `gate-state.json` status. |
| Alias precedence: both `CERBERUS_RUN_KEY` and `REVIEW_GATE_SESSION_KEY` set, different values | `CERBERUS_RUN_KEY` wins; **single** warning emitted to stderr by `__cerberus_resolve_run_key`, guarded by `__CERBERUS_ALIAS_WARNED` once-per-process sentinel so the ~25 call sites and the inline `resolve_review_dir` check do not duplicate the warning. Tested in Phase 0. |
| Both `CERBERUS_RUN_KEY` and `REVIEW_GATE_SESSION_KEY` set, identical values | No-op; identical behavior. |
| Empty `CERBERUS_STATE_ROOT` (set but empty string) | Treated as unset (`${VAR:-}` idiom); resolver falls back to host-default. Tested in Phase 0. |
| Relative or literal-`~` `CERBERUS_STATE_ROOT` | Fails before any directory creation with diagnostic. |
| Empty `CERBERUS_RUN_KEY` AND empty `REVIEW_GATE_SESSION_KEY` AND empty session_id arg | `resolve_review_dir` returns project-base path with no run subdir (existing behavior); spawn commands fail with "missing run key" message. |
| Malformed `gate-state.json` | `status --json` returns `{"status":"unknown","error":"malformed_state"}` with exit 0; Codex Stop allows. Tested in Phase 1. |
| Registry file missing on Codex `Stop` | Hook treats as "no active gate" → allow. |
| Registry file present but `gate-state.json` missing under `<run-key>/` | `status --json` returns `{"status":"no_active_gate"}` (exit 4); Codex Stop allows. |
| `gate-state.json` write contention from same-run multiple writers | Existing single-writer assumption preserved (one `bin/review-gate` per run); not a new risk. |
| Atomic-write contention on `gate-state.json` updates | Continue using existing `*.tmp.$$` + `mv` idiom. New writers (registry, etc.) follow the same pattern. POSIX `rename(2)` atomicity holds within a single filesystem. |
| Codex `Stop` triggered while reviewer subprocess writing `reviews/<reviewer>.json` | `status --json` reads files atomically per-file; a reviewer mid-write may be missed and counted as still-pending — same race characteristics as existing `wait --json --timeout 0`. Codex Stop emits "still running" message rather than blocking. |
| `CERBERUS_CODEX_STOP_WAIT_SECONDS=N` exceeded mid-review | `wait` exits with current state; matrix re-evaluates with possibly-still-pending state → emits "still running" message; user can re-invoke `Cerberus: Status`. |
| Telemetry directory creation fails (disk full) | Existing `init_iteration_dir` already tolerates this with warning; same on neutral path because path is `$REVIEW_DIR`-relative. |
| Telemetry under new layout | `run-telemetry.json` already records iterations/tokens/cost; works automatically on neutral path because it's `$REVIEW_DIR`-relative. No `bin/telemetry-lib.sh` changes. |
| SIGTERM / SIGINT / SIGHUP to `bin/codex-stop-hook` mid-execution | `trap` emits `{"action":"allow"}` JSON to stdout, kills child wait/status, exits 0. No partial JSON to Codex. |
| User runs `Cerberus: Clear Gate` while reviewers still spawning | Existing `resolve` writes `gate-state.json` with status=resolved; in-flight reviewers' results are archived to `reviews-iter-<n>/` (existing behavior at `bin/review-gate-lib.sh:113-124`). |
| Amp `ctx.thread.id` flips mid-session (unstable) | Shell helper detects via comparison with persisted `amp_thread_id`; logs warning; uses persisted UUID for continuity. |
| Codex install root path env var unstable across versions | Hook template uses placeholder substitution; `docs/CODEX.md` documents manual edit. OQ-2 spike confirms. |
| User has both `CLAUDE_PLUGIN_ROOT` and `CERBERUS_ROOT` set to different paths | `CERBERUS_ROOT` wins; `bin/generate` and skills load from `CERBERUS_ROOT`. Documented in `docs/CODEX.md`. |
| `~/.cerberus/` doesn't exist on first non-Claude run | Created lazily via `mkdir -p` in `init_iteration_dir` (existing pattern); same on neutral path. |
| Project key collision: two repos hash identically | Vanishingly unlikely (path-based hash); not a v1 concern. Override via `CERBERUS_PROJECT_KEY` available. |
| Missing `jq` | Backend returns structured error JSON where possible; adapters fail open for lifecycle hooks (Codex Stop matrix row 12). |
| Missing reviewer CLI (`codex`, `gemini`, `claude`) | Existing reviewer failure paths surface parse/reviewer errors through `status` and `wait`. |
| Plan/spec path missing in Codex/Amp | Command fails before spawning reviewers and explains explicit paths are required in v1. |
| Amp plugin reload mid-review | Command state reattaches through disk state and fallback registry, not plugin memory. |
| `gemini-readonly-policy.toml` interaction with non-Claude hosts | Phase 0 verifies policy applies when Gemini reviewer is invoked from `CERBERUS_HOST=codex` or `CERBERUS_HOST=amp`. If host-specific behavior is needed, document in `docs/CODEX.md` / `docs/AMP.md`. |
| Host API drift (Codex/Amp plugin APIs change) | Adapter details isolated; backend behavior remains stable. |

### Breaking Changes & Compatibility

- **Claude users:** zero changes required. All existing env vars, paths,
  commands, hooks, and tests continue to work byte-for-byte.
- **Existing CLI scripts/integrations** using `REVIEW_GATE_SESSION_KEY`,
  `REVIEW_GATE_TRANSCRIPT_PATH`, `CLAUDE_PLUGIN_ROOT` keep working as
  aliases. No migration window.

**Potential breaking changes & mitigations:**

| Potential Break | Mitigation |
|---|---|
| New resolver logic accidentally alters Claude path selection. | Keep Claude branch byte-for-byte equivalent at the state-path level when neutral env is absent; explicit tests for legacy resolution. |
| `CERBERUS_RUN_KEY` precedence surprises callers setting both old and new env vars differently. | Warn on alias mismatch; document precedence in env contract. |
| Expanding `wait --session-key` search to neutral roots exposes collisions if duplicate session keys exist. | Record `host`, `project_key`, `run_key` in neutral state for collision detection; collision message rather than silent overwrite. |
| Codex `Stop` continuation shape depends on final Codex hook response schema. | OQ-1 spike clarifies; failure-open default mitigates worst case. |
| User has somehow set `CERBERUS_HOST=codex` in shell profile and runs Claude. | Documented as non-risk because the env var did not exist before this change. |
| Claude users running with experimental `CERBERUS_*` set. | All `CERBERUS_*` reads route through alias logic; if Claude env still set, Claude path resolution wins for state when no `CERBERUS_HOST`/`CERBERUS_RUN_KEY` is set. |

**Sequential release strategy:** each phase ships independently;
rollback is `git revert` of one phase. Phase 0 ships behind no flag
because it's strictly additive; the regression suite (Claude tests) is
the gate. `CERBERUS_HOST=generic` mode in CI exercises the neutral path
before any host adapter is shipped.

## Testing & Validation Strategy

Tests follow the existing `bin/tests/*.sh` pattern: bash scripts using
`HOME` overrides + temp directories. No new test framework.

### Phase 0 — Shared Backend Tests

**`bin/tests/test-host-neutral-state.sh`** (state-resolution decision
matrix):

1. **Legacy Claude path:** no `CERBERUS_*` env, full Claude env →
   `~/.claude/projects/<hash>/cerberus/<sid>` (byte-for-byte).
2. **Generic neutral:** `CERBERUS_HOST=generic` + project + run keys →
   `~/.cerberus/projects/<key>/<run>`.
3. **Codex neutral:** `CERBERUS_HOST=codex` + project + run keys →
   `~/.cerberus/projects/<key>/<run>`.
4. **Amp neutral:** `CERBERUS_HOST=amp` + project + run keys →
   `~/.cerberus/projects/<key>/<run>`.
5. **Custom state root:** `CERBERUS_STATE_ROOT=/tmp/x` →
   `/tmp/x/<key>/<run>`.
6. **Host auto-detect from CLAUDE_*:** no `CERBERUS_HOST`, but
   `CLAUDE_SESSION_ID` set → host = `claude`.
7. **Host auto-detect default:** no `CERBERUS_HOST`, no `CLAUDE_*` →
   host = `generic`.
8. **Run-key alias precedence:** `CERBERUS_RUN_KEY` overrides
   `REVIEW_GATE_SESSION_KEY` when both set; **exactly one** warning
   emitted to stderr per process (guarded by `__CERBERUS_ALIAS_WARNED`).
   Test asserts both that a warning fires AND that a second invocation
   in the same process does not duplicate it.
9. **Alias-only legacy:** only `REVIEW_GATE_SESSION_KEY` set → still
   works as run key.
10. **Empty-string env vars:** treated as unset (`${VAR:-}` idiom).
11. **Concurrent runs:** two distinct run keys in same project resolve
    to distinct dirs (background jobs).
12. **Missing run key in `generic` mode:** exit non-zero with
    diagnostic.
13. **Invalid state root:** empty string, relative path, literal `~`
    fail safely before mkdir.
14. **Path-traversal rejection:** run-key or project-key containing
    `/`, `.`, `..` rejected.
15. **`wait`/`status --session-key` find neutral state (parity):** spawn
    under `CERBERUS_RUN_KEY=k`, then BOTH `wait --session-key k` AND
    `status --session-key k` succeed without
    Claude env.

**`bin/tests/test-status-command.sh`** (`status --json` contract):

1. **No active gate:** exit 4 + `{"status":"no_active_gate"}`.
2. **Pending:** `gate_status: "pending"`, `pending_reviewers` populated.
3. **Awaiting decision with findings:** `aggregated_findings` array
   populated, `consensus_verdict: "fail"` when blocking.
4. **Resolved pass:** `gate_status: "resolved"`,
   `consensus_verdict: "pass"`.
5. **Resolved fail:** `gate_status: "resolved"`,
   `consensus_verdict: "fail"`.
6. **Malformed `gate-state.json`:** exit 0 +
   `{"status":"unknown","error":"malformed_state"}`.
7. **No-mutation invariant:** snapshot `$REVIEW_DIR` (file list +
   per-file checksums) before and after `status --json`; assert
   byte-for-byte equal.
8. **No-blocking invariant:** time `status --json` against a still-pending
   gate; assert returns in <1s (no polling loop).
9. **Schema fields:** every returned JSON contains
   `schema_version`, `host`, `project_key`, `run_key`, `review_dir`.

### Phase 1 — Codex Tests

**`bin/tests/test-codex-session-registry.sh`**:

1. **Fresh `SessionStart`** writes registry with all required fields.
2. **Second `SessionStart`** updates `last_seen`, preserves `run_key`
   when same Codex session id.
3. **Concurrent writes** (background jobs, distinct PIDs): both
   `tmp.$$` files exist transiently; final state is one valid JSON
   (last writer wins).
4. **Registry directory missing:** `mkdir -p` succeeds.
5. **Malformed existing registry:** overwritten cleanly.
6. **Atomic write validation:** kill writer between temp creation and
   `mv` → no `active-session.json` exists; only orphan tmp file.
7. **Schema correctness:** written JSON validates against the registry
   schema (v1 fields).

**`bin/tests/test-codex-stop-hook.sh`** (every row of the Decision
Matrix + signal handling):

1. **Row 1:** no registry → `{"action":"allow"}`.
2. **Row 2:** registry → no run dir → `{"action":"allow"}`.
3. **Row 4:** pending, `CERBERUS_CODEX_STOP_WAIT_SECONDS=0` →
   `{"action":"allow","note":"..."}`.
4. **Row 5a:** pending, wait knob N=2, reviewers don't finish → fall
   through to allow with "still running" note.
5. **Row 5b:** pending, wait knob N=2, reviewers finish during wait →
   re-evaluate → emit row 6/7/8/9 result.
6. **Row 6:** awaiting decision, blocking findings →
   `{"action":"continue", "userMessage":"..."}` containing findings
   summary.
7. **Row 8:** resolved pass → `{"action":"allow"}`.
8. **Row 9:** resolved fail → `{"action":"continue", ...}`.
9. **Row 10:** malformed `gate-state.json` →
   `{"action":"allow","note":"cerberus state unreadable; allowing stop"}`.
10. **Row 11:** `status --json` exits 2 → `{"action":"allow"}`,
    diagnostic logged.
11. **Row 12:** `jq` missing on PATH → `{"action":"allow"}`.
12. **Row 13a:** SIGTERM mid-execution → `{"action":"allow"}` emitted,
    exit 0.
13. **Row 13b:** SIGINT during child wait → child killed via stored PID,
    `{"action":"allow"}` emitted.
14. **Row 13c:** SIGHUP during child wait → same as 13b.
15. **Stdin parse failure:** invalid Codex JSON on stdin →
    `{"action":"allow"}`, diagnostic.

### Phase 2 — Amp Tests

**`bin/tests/test-amp-shell-helper.sh`**:

1. **Thread id present:** `ctx.thread.id` used as run key.
2. **Thread id absent:** UUID generated, persisted at
   `~/.cerberus/runtime/amp/<workspace-key>/active-session.json`.
3. **Second invocation:** reads persisted UUID; same run key returned.
4. **Env mapping completeness:** spawned `bin/review-gate` invocation
   includes all required `CERBERUS_*` vars (`CERBERUS_HOST=amp`,
   `CERBERUS_ROOT`, `CERBERUS_PROJECT_KEY`, `CERBERUS_RUN_KEY`).
5. **`CLAUDE_PLUGIN_ROOT` compat alias:** still passed during migration.
6. **Run key surfaced in stdout:** command output contains run key for
   user pass-through.
7. **Missing backend:** clear diagnostic surfaced.
8. **Missing reviewer CLI:** error from backend surfaced cleanly.
9. **Thread id flips mid-session:** helper detects mismatch with
   persisted value, logs warning, uses persisted UUID for continuity.

### Integration / End-to-End Tests

- Existing `bin/tests/*.sh` Claude regression suite passes unchanged.
- **Phase 0 E2E:** spawn-code-review → wait → status --json → resolve
  using only neutral env (no `CLAUDE_*`).
- **Phase 1 E2E:** scripted Codex `SessionStart` JSON →
  `bin/codex-session-init` → spawn-code-review (skill simulation) →
  `bin/codex-stop-hook` reads state → expected JSON.
- **Phase 2 E2E:** Bun-driven invocation of `.amp/plugins/cerberus.ts`
  shell helper from a fixture; verify env propagation and disk state.
- Existing debate and telemetry tests continue to pass when neutral
  state is not enabled.

### Regression Tests

- Full Claude `bin/tests/*.sh` suite (~25 tests).
- Manual smoke: clone main; create review under Claude → resolve →
  confirm state under `~/.claude/projects/<hash>/cerberus/<sid>` exists
  with same shape as before.
- Existing `REVIEW_GATE_SESSION_KEY`, `REVIEW_GATE_TRANSCRIPT_PATH`,
  `CLAUDE_PLUGIN_ROOT` integrations remain valid.

### Manual Verification

- Start code review from Claude, Codex, and Amp in same repo, distinct
  run keys; verify three independent state dirs.
- Start plan review from Codex with explicit `<plan-path>`; verify
  `gate-state.json.host == "codex"`.
- Ask Cerberus panel from Codex and Amp.
- `Cerberus: Clear Gate` from Codex; verify
  `gate-state.json.status == "resolved"`.
- Trigger Codex `Stop` with pending reviewers and
  `CERBERUS_CODEX_STOP_WAIT_SECONDS=0` and `=10`; observe both
  behaviors.
- Reload Amp plugin mid-review; reissue `Cerberus: Status` and verify
  reattach.
- Send SIGTERM to `bin/codex-stop-hook` mid-wait; verify safe-allow
  output.

### Monitoring / Observability

- Existing `log()` emits to stderr at every adapter boundary (matches
  existing `bin/review-gate-lib.sh:5-7` pattern). Surfaces in CI logs.
- `gate-state.json.host` field enables post-hoc filtering by host in
  any external monitoring.
- `run-telemetry.json` already records iterations/tokens/cost; works
  automatically on neutral path because it's `$REVIEW_DIR`-relative.
- New log events: alias mismatch warning, invalid state root, registry
  write failures, Stop fail-open events, run-key collisions.
- Document troubleshooting commands using `status --json` and explicit
  `--session-key`.

### Acceptance Criteria Coverage

| Acceptance Criterion (observable) | Covered By |
|---|---|
| Existing Claude `bin/tests/*.sh` suite passes after Phase 0 | Phase 0 regression run; "No regression" gate. |
| `bin/review-gate spawn-code-review` followed by `wait`, `status --json`, `resolve` succeeds with only `CERBERUS_*` env (no `CLAUDE_*`) | `test-host-neutral-state.sh` row 2; Phase 0 E2E. |
| Non-Claude state at `~/.cerberus/projects/<project-key>/<run-key>/` with `host` recorded | Data Model; Phase 0 + Phase 1 E2E + manual smoke. |
| `CERBERUS_RUN_KEY` canonical; `REVIEW_GATE_SESSION_KEY` supported | `test-host-neutral-state.sh` rows 8–9. |
| `bin/review-gate status --json` never modifies any file under `$REVIEW_DIR` | `test-status-command.sh` no-mutation invariant. |
| Codex `SessionStart` persists run identity for skills and Stop | Codex registry schema; `test-codex-session-registry.sh`; Phase 1 E2E. |
| Codex `Stop` never waits by default; bounded wait only on opt-in | `test-codex-stop-hook.sh` rows 3–5. |
| Codex `Stop` continues on blocking findings; allows otherwise | `test-codex-stop-hook.sh` rows 1, 2, 6, 7, 8. |
| Amp explicit commands work via shared backend | `test-amp-shell-helper.sh`; Phase 2 E2E. |
| Amp reattaches after plugin reload | Manual smoke; `test-amp-shell-helper.sh` row 3. |
| Generator workflows / agent-team automation NOT advertised cross-host in v1 | Scope & Non-Goals; OQ-4/OQ-5; docs updates. |
| Two concurrent runs in same workspace remain isolated | `test-host-neutral-state.sh` row 11; `test-codex-session-registry.sh` row 3. |

## Spec/Legacy Fidelity

This plan is a refinement of the earlier draft at this same path
(`docs/2026-04-29-codex-amp-plugin-port-plan.md`) and synthesizes
agreement from three independent generator drafts (Codex, Gemini,
Claude). Substantive resolved decisions:

### Deviation Log

| Source | Deviation | Rationale | Approved? |
|---|---|---|---|
| Skeleton `wait --json --timeout 0` decision marked `[TBD]` | Resolved as: add new `status --json` command (non-mutating, non-blocking, exit-4-on-empty). | Cleaner contract for Codex `Stop` and Amp `Status`; avoids `wait`'s polling/finalize semantics. | Yes |
| Skeleton named adapter binaries `[TBD]` | Resolved as `bin/codex-session-init` and `bin/codex-stop-hook`. | Matches existing `bin/claude-session-init` naming convention. | Yes |
| Skeleton "Pass criterion for no regression" `[TBD]` | Resolved as: full `bin/tests/*.sh` pass + manual smoke that an existing Claude review still spawns/waits/resolves/clears. | User-confirmed. | Yes |
| Skeleton hint that Stop hook might wait | Codified as **never wait by default**; bounded opt-in via `CERBERUS_CODEX_STOP_WAIT_SECONDS=N`, default `0`. | Avoids trapped-user UX. | Yes |
| Skeleton omitted explicit failure-open principle for Codex Stop | Added: any Cerberus-side failure → `{"action":"allow"}`. | Defensive default; users must never be unable to stop Codex due to a Cerberus bug. | New — design decision |
| Skeleton omitted explicit alias-precedence rule | Added: `CERBERUS_*` wins over legacy alias when both set non-empty; empty treated as unset; warning emitted on mismatch. | Disambiguation needed for testing and back-compat documentation. | New — design decision |
| Skeleton omitted signal-handling spec for Codex Stop | Added: `trap INT TERM HUP` emitting safe-allow JSON; child wait/status killed via stored PID. | Avoids partial JSON to Codex stdin under cancel. | New — design decision |
| Skeleton enumerated spawn-* sites informally | Added: explicit list of ~25 line numbers + helper-function refactor to centralize reads. | Reduces drift risk during mechanical replacement. | New — design decision |
| Skeleton omitted state-root validation | Added: reject empty/relative/literal-`~` paths before mkdir. | Avoids creating `./projects` or `~/projects` literals. | New — design decision |
| Skeleton omitted path-traversal validation | Added: reject `/`, NUL, `.`, `..` in run-key and project-key. | Prevents path traversal under user-supplied keys. | New — design decision |
| Skeleton omitted `gemini-readonly-policy.toml` cross-host check | Added Phase 0 review item to confirm policy applies cleanly from non-Claude hosts. **Phase 0 resolution (T005): verified clean — no changes needed.** Policy is tool-name based and contains no host-specific paths or `${CLAUDE_*}` references; both `--policy` and the system-settings file load from `$PLUGIN_ROOT/config/...`, which is resolved through `__cerberus_resolve_root` (CERBERUS_ROOT → CLAUDE_PLUGIN_ROOT alias). `bin/tests/test-review-gate-gemini-policy.sh` now asserts `--policy`, `--admin-policy`, settings path, and absence of deprecated/unsupported flags under `CERBERUS_HOST=generic`/`codex`/`amp`; an explanatory comment block was added to `config/gemini-readonly-policy.toml`. | Prevents surprise reviewer behavior change under `CERBERUS_HOST=codex`/`amp`. | New — design decision |

## Open Questions

Carried into implementation as Open Questions; flagged for resolution
during phase spikes:

- **OQ-1 (Phase 1 spike):** Codex skill manifest fields — exact schema,
  required vs optional fields, and slash-command/skill semantics
  (Tier-1 workflows: review-code, review-plan, review-spec, ask,
  status, clear-gate). Blocks Phase 1 implementation.
- **OQ-2 (Phase 1 spike):** Whether Codex exposes a stable plugin-install
  path env var. If not, document the manual hook-template edit step in
  `docs/CODEX.md`.
- **OQ-3 (Phase 2 spike):** Whether Amp `ctx.thread.id` is durable in
  both command handlers and lifecycle events. The plan already designs
  for the no-durable-thread-id case, so this spike informs default-path
  behavior, not architecture.
- **OQ-4 (Phase 3):** Whether to introduce a neutral plan registry
  (`~/.cerberus/projects/<key>/plans/latest.txt`) to give Codex/Amp
  parity with Claude's "review-plan with no arg" UX.
- **OQ-5 (Phase 4):** Final decision on team automation:
  Claude-only forever, build external orchestrator, or port to Amp/Codex
  task primitives. Requires separate design doc.

## Release Strategy

Three sequential releases, each independently shippable and revertable:

| Release | Scope | Validation |
|---|---|---|
| Cerberus vX (Phase 0) | Shared backend host neutralization. New `status --json` command. New `CERBERUS_*` env contract with full back-compat. | Existing Claude `bin/tests/*.sh` + new neutral-state + `status` tests. No host adapter changes. |
| Cerberus vX+1 (Phase 1) | Codex port: `.codex-plugin/plugin.json`, skills, `templates/codex-hooks.json`, `bin/codex-session-init`, `bin/codex-stop-hook`, `docs/CODEX.md`. | Phase 0 tests + Codex tests + manual Codex smoke checks. |
| Cerberus vX+2 (Phase 2) | Amp port: `.amp/plugins/cerberus.ts` + `docs/AMP.md`. | Phase 0/1 tests + Amp tests + manual Amp smoke checks. |

Phase 3 (generator workflow ports) and Phase 4 (team automation
revisit) ship in subsequent releases as scope and external host
maturity allow.

## Next Steps

After this plan is approved, run `/cerberus:create-tasks` to generate:

- `--beads` → Beads issues with dependencies for multi-agent execution
- (default) → TODO.md checklist for simpler tracking
