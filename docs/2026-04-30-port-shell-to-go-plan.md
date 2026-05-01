# Implementation Plan: Port Cerberus Shell Scripts to Go

## Context & Goals

- **Spec**: N/A — derived from user description ("port all the shell scripts to Go"); legacy contract surface is `README.md`, `hooks/hooks.json`, `templates/codex-hooks.json`, `docs/CODEX.md`, and `docs/AMP.md`.
- **Mode**: `max` (max-depth interview already completed; full risk register; hard cutover per phase; byte-parity gates).
- Replace ~33,400 LOC of bash (8 production binaries, 5 shared libs in `bin/*.sh`, 32 test files in `bin/tests/`, the Amp Toolbox dispatcher `.amp/toolbox/cerberus.sh`) with a single Go module that produces N per-binary executables and preserves the existing CLI surface, hook contracts, on-disk schemas, and host-neutral env contract byte-for-byte.
- Audience: Cerberus maintainers and the four supported hosts (Claude Code, Codex CLI, Amp, generic). The improvement is a smaller runtime prerequisite set (drop `jq`, `python3`, `setsid`, `gtimeout`, `flock(1)`, `sha256sum`, `realpath`, `stat`), saner concurrency and process-group handling, faster cold start, and a single test/coverage story.

## Scope & Non-Goals

### In Scope
- Port the seven in-scope bash binaries in `bin/` (`review-gate`, `generate`, `cerberus-task-completed-hook`, `cerberus-teammate-idle-hook`, `claude-session-init`, `codex-session-init`, `codex-stop-hook`) plus the Amp Toolbox dispatcher `.amp/toolbox/cerberus.sh` to Go, each landed at the **exact same install path** the hooks/templates/skills already reference.
- Port the five shared libs (`review-gate-lib.sh`, `review-gate-models.sh`, `review-gate-debate.sh`, `review-gate-hook.sh`, `telemetry-lib.sh`) into Go internal packages and **delete the bash sources** at the end of Phase 4.
- Replace `jq`, `python3`, `setsid`, `gtimeout`, `sha256sum`, `realpath`, `stat`, `flock(1)` invocations with Go-stdlib or vetted-third-party equivalents (`encoding/json`, `regexp`, `crypto/sha256`, `filepath.EvalSymlinks`, `os.Stat`, `github.com/gofrs/flock`, `context.WithTimeout`, `syscall.Setsid`).
- Maintain the host-neutral env contract (`CERBERUS_*` with full `CLAUDE_*` / `REVIEW_GATE_*` aliasing and the dedup'd alias-divergence warning) byte-for-byte per `README.md` lines 478–491.
- Keep the external-surface bash test corpus (~17,700 LOC across 32 files) executable as the acceptance harness through Phase 3; port internal-helper tests to Go immediately as their helpers move to `internal/`.
- Add a GitHub Actions CI workflow in Phase 0 (the repo currently has no `.github/`) running `go test ./...` plus the existing bash acceptance suite on Linux + macOS, Go 1.25.
- Add a 24-cell golden fixture matrix `{fast,smart,max} × {single,debate} × {code,plan,spec,ask}` captured in Phase 0 from unmodified bash production and diffed in every subsequent phase.

### Out of Scope (Non-Goals)
- **`bin/update-plugin` (85 LOC) stays bash.** Not on any host hot path; revisit in a follow-up. Edited once in Phase 0 to invoke `make install-binaries` after pull (which writes only inside the gitignored `dist/` and never to git-tracked files).
- Changing any user-visible CLI surface: subcommand names, flags, exit codes, stdout/stderr semantics, slash-command mapping, prompt text, or the `gate-state.json` schema.
- Replacing the reviewer CLIs (`claude`, `codex`, `gemini`) with native API clients — they remain shelled out.
- Removing legacy env aliases (`CLAUDE_PLUGIN_ROOT`, `REVIEW_GATE_SESSION_KEY`, `CLAUDE_SESSION_ID`, `CLAUDE_TRANSCRIPT_PATH`, `REVIEW_GATE_TRANSCRIPT_PATH`). The README guarantees indefinite back-compat.
- Migrating prompts under `prompts/` away from runtime-loaded markdown.
- Distributing as a single static binary that bypasses the existing `${CLAUDE_PLUGIN_ROOT}/bin/...` install layout — every binary keeps its current path.
- A `<name>.bash` fallback or `CERBERUS_RUNTIME=bash` env switch. Rollout is **hard cutover per phase, revert via `git revert`** (decided).
- Pre-built per-OS-arch artifacts (e.g. via `goreleaser`). Distribution is source + `go build` at install time. Reconsidered as follow-up if marketplace ergonomics demand it.
- Windows support (not currently supported; not added).
- Behavioral redesigns of the debate coordinator, telemetry shape, or hook payloads. This is a **rewrite under the same contract**.
- Automating every Codex/Amp manual smoke check in MVP; full automation is follow-up.

## Assumptions & Constraints

- The Cerberus marketplace install (`/plugin install cerberus`, `README.md` lines 56–94) ships the repo verbatim. Whatever lives at `bin/<name>` must be a working executable on the user's machine after install. The hook templates reference these paths literally (`hooks/hooks.json`, `templates/codex-hooks.json`).
- Distribution model = **source + `make install-binaries` at install time, with build output in gitignored `dist/` and committed shims at `bin/<name>`**. A Go 1.25 toolchain becomes a user prerequisite; the README installation section will be updated and a `Makefile` drives the build (per-cmd compile into `dist.new/<name>` at the repo root, atomically renamed to `dist/`). `bin/update-plugin` runs `make install-binaries` after pulling and never modifies git-tracked files.
- Reviewers (`claude`, `codex`, `gemini`) launch as detached background subprocesses today via `setsid` so the parent stop-hook can exit while reviewers continue (`bin/review-gate-models.sh`, `bin/review-gate-debate.sh`). Go must replicate this lifecycle via `os/exec` + `syscall.SysProcAttr{Setsid: true}` on **both Linux and Darwin** (Go's `syscall` calls `setsid(2)` directly on macOS — no `setsid` binary needed), plus `Process.Release()`, and **must not** group-kill on parent exit.
- Concurrent state mutation uses `flock(1)` (`bin/telemetry-lib.sh:65–105`) plus atomic-rename for `gate-state.json`. Go must take the **same byte-range advisory lock on the same file path** so cross-runtime locking holds during phase rollouts where some binaries are still bash. `github.com/gofrs/flock` wraps `flock(2)` (BSD/Darwin) and `fcntl(F_SETLK)` (Linux) compatibly with `flock(1)` provided both sides lock the same path. Go never holds a state lock while invoking the bash debate bridge.
- Targets: macOS (arm64 + x86_64) and Linux (x86_64 + arm64). Min Go version = 1.25 (matches maintainer's local toolchain `go1.25.6 darwin/arm64`).
- The Amp Toolbox protocol (`docs/AMP.md`) cares about executability + stdin/stdout JSON, not filename extension. The Go replacement for `.amp/toolbox/cerberus.sh` keeps the `.sh` filename despite being a Mach-O / ELF binary; documented in a Go-side header comment and in `docs/AMP.md`.
- macOS bash 3.2 quirks (associative-array workarounds in `review-gate-models.sh`, `$$`-keyed warning marker file in `__cerberus_resolve_run_key`, BSD `mktemp` constraints) become irrelevant in Go but the **observable behavior** (single warning per process, identical paths, identical env precedence, identical telemetry serialization) must be preserved.
- Phase 1 + Phase 2 retain the bash debate coordinator. Go `review-gate` `--debate` runs `bash bin/review-gate-debate-bridge.sh` (a small Phase-0 wrapper that sources the debate library and calls its top-level entry function `run_debate_coordinator "$@"` — the library itself only defines functions and is not directly exec'able) as a child process via `cmd.Run()` (Supervise pattern: Go stays the parent, forwards signals to the child's pgid, propagates the bash exit code) with the full `CERBERUS_*` + `REVIEW_GATE_*` + `CLAUDE_*` env exported. State exchange flows through `gate-state.json`, which both sides lock via the same file path.
- All major decisions resolved in the user interview (see Decision Log). No CLI surface changes, schema changes, or env-var renames are permitted.
- Tests must assert observable behavior and invariants, not proxy metrics such as number of files touched or number of tests added.

### Implementation Constraints
- **Layout**: one Go module at the repo root (`go.mod`, module path `github.com/charlieyou/cerberus`). One independent binary per existing in-scope script, built via `go build` per cmd into `dist.new/<name>` (a sibling of `dist/` at the repo root) and atomically swapped into `dist/<name>`. Canonical executable paths (`bin/<name>`, `.amp/toolbox/cerberus.sh`) are committed bash shims that `exec` the corresponding `dist/<name>`; the binary names under `dist/` match the canonical filenames exactly. No multicall + symlinks (process names in `ps`/`top` stay clear; argv[0] dispatch quirks avoided).
- **No CLI changes**: every existing subcommand keeps its name, flag set, exit codes (review-gate exit codes 0–4 in `README.md` lines 458–464; debate codes 5, 6-preflight, 6-mid-debate, 130 at lines 304–321).
- **No schema changes**: `gate-state.json` keys, ordering, and shape exactly match the bash output. Go uses explicit `json:"name"` tags, a deterministic field order, and a custom `MarshalJSON` (or `internal/jsonutil.MarshalOrdered`) where stdlib map ordering would diverge; goldens gate this.
- **Avoid touching**: `prompts/`, `commands/`, `skills/`, `hooks/hooks.json`, `templates/codex-hooks.json`, `docs/CODEX.md` substantive content (only prereq tables in README change, in Phase 4).
- **Pattern to follow**: per-package `internal/<domain>/` with table-driven tests; thin `cmd/<name>/main.go` that wires flags → internal packages.
- **Pattern to avoid**: introducing a Go web of init() side-effects, package-global state outside `internal/cerberusenv`, or any runtime-dispatched plugin loader. Avoid third-party CLI frameworks; use stdlib `flag` + manual subcommand dispatch so help/error text and parse behavior can be controlled for byte parity.
- **Module dependencies (allowlist)**: `github.com/gofrs/flock` (production), `github.com/stretchr/testify` (test-only), `github.com/google/go-cmp` (test-only). All other behavior in stdlib. New deps require a Decision Log entry.
- **Hook timeouts** cap end-to-end binary runtime: TaskCompleted = 2100s (`hooks/hooks.json` line 30), TeammateIdle = 10s (line 41). Go binaries set `context.WithTimeout` slightly under these budgets.

### Testing Constraints
- **Behavioral test checklist (load-bearing release gate).** The following ten test classes must pass before any phase ships. Coverage percentage is a CI signal only, not a release gate — it can be gamed by tests that assert nothing. The behavioral checklist below is the load-bearing gate.
  1. **Env precedence tests** — `internal/cerberusenv` has table-driven tests for each variable (`CERBERUS_RUN_KEY` / `REVIEW_GATE_SESSION_KEY`, `CERBERUS_ROOT` / `CLAUDE_PLUGIN_ROOT`, `CERBERUS_SESSION_ID` / `CLAUDE_SESSION_ID`, `CERBERUS_TRANSCRIPT_PATH` / `CLAUDE_TRANSCRIPT_PATH` / `REVIEW_GATE_TRANSCRIPT_PATH`) covering: canonical-only, alias-only, both-equal, both-disagree (must emit ONE warning), both-empty.
  2. **State machine transitions** — `internal/state` has tests for every documented gate-state.json status transition: `pending` → `awaiting_decision` (debate degraded), `pending` → `resolved` (consensus PASS), `pending` → `resolved` (manual `bin/review-gate resolve`), `pending` → `resolved` with `consensus.verdict=ERROR` (defensive fallback per README:317–321), and the active-gate guard treating `resolved` as not-active.
  3. **Reviewer argv goldens** — `internal/reviewers` has goldens for the exact `claude`/`codex`/`gemini` command line assembled per `--mode` (fast/smart/max), per artifact type (code/plan/spec/ask/epic-verify), per debate vs single, per agent selection. Argv is captured as a slice and diffed against `bin/tests/fixtures/golden/argv/<reviewer>/<mode>/<type>.json`.
  4. **Telemetry extractor parity** — `internal/telemetry` extractors run against the 26 JSON fixtures in `bin/tests/fixtures/` (plus debate sub-fixtures) and produce byte-equal output to the bash extractors.
  5. **Lock interop test** — `internal/state` and `internal/telemetry` exercise N-writer flock contention with one bash holder and one Go holder on the same FD path; assert that `gate-state.json` updates are serialized and never produce torn writes.
  6. **JSON canonicalization** — `internal/jsonutil` has tests proving `Canonicalize` produces byte-identical output for input that differs only in whitespace, key order, and trailing newline.
  7. **24-cell golden parity** — for each cell of {fast,smart,max} × {single,debate} × {code,plan,spec,ask}, the captured-from-bash golden equals the produced-by-Go output after the canonicalization layer is applied to both.
  8. **Hook fixture replay** — `cmd/cerberus-task-completed-hook`, `cmd/codex-stop-hook`, `cmd/cerberus-teammate-idle-hook` are run against the JSON fixtures in `bin/tests/fixtures/` (`claude-output*.json`, `codex-output.jsonl`) and produce byte-equal stdout/stderr/exit-code to bash.
  9. **Existing bash acceptance suite** — every `bin/tests/test-*.sh` that exercises external surface continues to pass against the Go binaries. Specifically: `test-debate-byte-parity.sh` (1018 LOC) is the release gate for Phase 3.
  10. **Procgroup detach + supervise tests** — `internal/procgroup` has two tests: (a) **Detach**: launches a subprocess via `Detach()` that records its own session id and process group, exits parent, asserts subprocess survives and remains in its own session; (b) **Supervise**: launches a subprocess via `Supervise()`, asserts it lives in its own pgid (`pgid == pid`) under the Go parent's session, sends SIGTERM to the parent's signal handler and asserts the forwarder delivers it to the child's pgid, then asserts Go propagates the child's exit code.
- `go test -cover` runs in CI and the percentage is printed in workflow output as supporting evidence; it is **not** a release gate. Coverage percentage is gameable (tests that assert nothing inflate it without proving anything); the behavioral checklist above is the load-bearing gate.
- Every existing `bin/tests/test-*.sh` that exercises a binary's external surface (CLI args, stdout/stderr, `gate-state.json` contents, on-disk artifacts) **must continue to pass byte-for-byte** against the Go binary.
- `bin/tests/test-debate-byte-parity.sh` (1018 LOC) is the toughest existing parity gate and must pass at the end of Phase 3.
- Internal-helper bash tests (`test-bash3-agent-parsing.sh`, `test-content-extraction.sh`, `test-iso8601-to-epoch.sh`) get Go equivalents immediately; bash versions retire **only when** their target source file is deleted in Phase 4.
- Golden-fixture matrix: 24 cells (`{fast,smart,max} × {single,debate} × {code,plan,spec,ask}`) captured in Phase 0 from unmodified bash; every phase asserts byte-equality on the cells in its scope.
- Performance budget: each Go binary's cold-start latency must be ≤ bash equivalent + 10ms. Tracked via a new `bench/` driver. Warning-only initially.
- Cross-runtime concurrency tests: a Go test that opens `flock` on a temp `gate-state.json` while a `flock(1)` shell child holds it, verifying mutual exclusion. Run on both Linux and macOS.

### Decision Log
| Decision | Rationale | Evidence | Tradeoff / Risk / Follow-up |
|----------|-----------|----------|-----------------------------|
| **Module path = `github.com/charlieyou/cerberus`** | Matches the marketplace install (`/plugin marketplace add charlieyou/cerberus`, `README.md` line 56) | User answered Phase 2 batch 1 | Locks the canonical import; rename later requires module-path migration |
| **Binary layout = N per-cmd builds via single `go build ./cmd/...`** | User delegated ("you decide"); chose option that keeps process names clear in `ps`/`top` and avoids argv[0] dispatch surprises on macOS | Autonomous decision (Phase 2 batch 2) | Larger install (~8 binaries × small overhead); same source tree as multicall; build cost ≈ same |
| **Drop `jq` entirely; port to `encoding/json`** | User answered Phase 2 batch 1 | "Port everything to encoding/json (drop jq dep)" | Translation effort across hundreds of `jq` invocations; risk of subtle behavior drift on complex filters; mitigated by golden fixtures + per-package unit tests on the JSON shapes |
| **Distribution = source + `go build` at install time** | User answered Phase 2 batch 2 | Existing zero-build install becomes a build step; users gain a Go toolchain prerequisite | Add a `Makefile` and/or post-install script; document in README installation section |
| **Test policy = keep external-surface bash tests, port internal-helper tests immediately** | User answered Phase 2 batch 2 | Strong parity guarantee preserved while internal helpers (which no longer exist in Go) get equivalent Go-native coverage | Bash test corpus stays as acceptance harness through all phases; retire only when its target is deleted |
| **CI = GitHub Actions added in Phase 0** | User answered Phase 2 batch 2 | New `.github/workflows/test.yml` runs `go test ./...` and the bash acceptance suite | Increases Phase 0 scope; required for confident hard-cutover rollout |
| **Rollout = hard cutover per phase, revert via `git revert`** | User answered Phase 2 batch 1 | Removes the `<name>.bash` fallback complexity entirely | Loss of per-binary fallback knob; depends on the marketplace install supporting downgrade by version pin or `git revert`; mitigated by phase-by-phase release tags |
| **Min Go version = 1.25** | User answered Phase 2 batch 3 | Matches the maintainer's local toolchain (`go version go1.25.6 darwin/arm64`) | Tightest user prerequisite; documented in README install section |
| **Amp adapter = Go binary at the same path (`.amp/toolbox/cerberus.sh`)** | User answered Phase 2 batch 3 | Amp Toolbox protocol cares about executability + stdin/stdout JSON, not file extension (`docs/AMP.md`) | Filename keeps `.sh` extension on disk despite being a binary; document this surprise in `docs/AMP.md` |
| **Phase order = core first, debate later; `update-plugin` deferred (bash)** | User answered Phase 2 batch 3 | Surfaces the hardest unknowns (state, locking, env contract, reviewer-subprocess lifecycle) early in Phase 1; defers the 3174-LOC debate coordinator to its own focused Phase 3 | Phase 1 ships before debate parity is proven; mitigated by the bash debate bridge below |
| **Bash debate bridge = Go `review-gate` execs `bash bin/review-gate-debate-bridge.sh` (Phase-0 wrapper that sources the libs and calls `run_debate_coordinator`) with the full env exported** | User answered Phase 2 batch 4 (entrypoint refined per round-2 plan review P2 — the library has no top-level invocation, so Go execs the wrapper, not the library) | Cleanest layering during the transition; state exchange through `gate-state.json` already byte-stable | Adds one `bash` invocation in the `--debate` path until Phase 3; verify env vars (`CERBERUS_*`, `REVIEW_GATE_*`) are inherited correctly; the wrapper file itself is deleted in Phase 3 when `internal/debate` lands |
| **File locking = `github.com/gofrs/flock`** | User answered Phase 2 batch 4 | Mature wrapper around `fcntl` (Linux) / `flock` (BSD); tested interop with bash `flock(1)` on the FDs both sides obtain | Adds one third-party dep; alternative `golang.org/x/sys/unix.Flock` is a fallback if interop turns out lacking |
| **Replace `python3` + `setsid` + `gtimeout` in Go (drop from prerequisites)** | User answered Phase 2 batch 4 | Go provides `encoding/json`, `regexp`, `crypto/sha256`, `syscall.Setsid`, `context.WithTimeout` natively | Reduces the README prereq table; need to re-implement the python3 callsites carefully (some do JSON repair) — covered by golden tests |
| **Golden fixture matrix = full {fast,smart,max} × {single,debate} × {code,plan,spec,ask} = 24 runs** | User answered Phase 2 batch 4 | Strongest parity guarantee; captures every documented mode | ~24 fixture sets to maintain; one-time capture in Phase 0; refresh discipline needed when intentional behavior changes are made |
| **`bin/update-plugin` left as bash, out of scope** | User answered Phase 2 batch 3 | 85-LOC utility, not on any host hot path | Ports remain incomplete in this work; revisit in a follow-up |
| **Distribution mechanic = `dist/` + committed shims at `bin/<name>`** | Compiled Go binaries land in gitignored `dist/<name>`; permanent 3-line bash shims at `bin/<name>` (committed once in Phase 0, stable across all phases) `exec` the dist artifact. Shims are never overwritten by `make install-binaries`; only `dist/` is replaced (atomically, via the sibling staging directory `dist.new/` at the repo root). Resolves four interlocking findings: (1) `bin/update-plugin` `git pull` no longer aborts on a dirty tree because compiled artifacts never overwrite tracked files; (2) source-only distribution gets a single concrete mechanism (committed shims + documented `make install-binaries`); (3) the shim-vs-direct-binary contradiction in OQ-A is resolved (shim always wins, dist always holds the artifact); (4) the `.gitignore` pattern `/dist*/` keeps generated binaries (`dist/`, `dist.new/`, `dist.old/`) out of `git status` and safe from `git clean -fd`. | Phase 0 establishes the invariant; phases 1–4 only delete bash production scripts and grow the `dist/` artifact set | Tradeoff: every binary invocation pays one extra `exec` (~sub-millisecond on macOS/Linux, well within the cold-start budget). Mitigation for shim/dist drift listed in Risks. |

## Integration Analysis

### Existing Mechanisms Considered

| Existing Mechanism | Could Serve Feature? | Decision | Rationale |
|--------------------|----------------------|----------|-----------|
| `hooks/hooks.json` + `templates/codex-hooks.json` (host hook registration) | Yes | **Extend (no schema change)** | Hook entries call `${CLAUDE_PLUGIN_ROOT}/bin/<name>` / `<CERBERUS_INSTALL_ROOT>/bin/<name>`. As long as those paths resolve to a working executable, zero hook config changes are needed across hosts. |
| `bin/review-gate-lib.sh` `__cerberus_resolve_*` env helpers | Yes | **Port to Go package (`internal/cerberusenv`)** | Centralizes the legacy alias logic the README guarantees. Port preserving precedence order and the once-per-process warning (`sync.Once`). |
| `bin/telemetry-lib.sh` (`atomic_write`, `atomic_json_update`, `init_iteration_dir`, telemetry extractors per agent) | Yes | **Port to Go packages (`internal/telemetry`, `internal/state`)** | Already a logical module boundary; clean Go translation. |
| `bin/review-gate-models.sh` (Codex/Gemini/Claude reviewer subprocess wrappers, `--mode {fast,smart,max}` model selection, `setsid` detach) | Yes | **Port to Go package (`internal/reviewers`)** | Argv assembly is data-driven; lives in `internal/reviewers` with model tables under `internal/reviewers/models.go`. |
| `bin/review-gate-hook.sh` (Claude `Stop` check loop) | Yes | **Port into `cmd/review-gate` `check` subcommand** | The check loop is part of `review-gate`'s subcommand surface; collapse the lib into the binary. |
| `bin/review-gate-debate.sh` debate coordinator | Yes | **Bridge in Phase 1–2; port to Go package (`internal/debate`) in Phase 3** | The 3174-LOC coordinator has well-defined states (preflight, round loop, abstain, degraded, cancel) that map to a Go state machine. Bridge via Go-parented bash child (`cmd.Run()`, Supervise pattern) until Phase 3. |
| Existing CLI subcommand routing in `bin/review-gate` | Yes | **Port using stdlib `flag` + manual subcommand dispatch** | Avoids a third-party CLI lib; matches existing dispatch style. Mirror subcommand names + flags 1:1. |
| `.amp/toolbox/cerberus.sh` Amp Toolbox dispatcher | Yes | **Replace with Go binary at the same path** | Toolbox protocol is documented (`docs/AMP.md`); reuses `internal/host` adapter glue. |
| `bin/tests/*.sh` test harness | Partial | **Extend (acceptance) + port (internal helpers) + add Go tests** | External-surface tests stay as the acceptance harness; internal-sourcing tests get Go equivalents. |
| `bin/update-plugin` | Partial | **Keep bash; add post-update rebuild call in Phase 0** | Updater remains out of Go port but must rebuild binaries after pulling source. |

### Integration Approach

The implementation extends the current plugin layout instead of introducing a new launcher, service, or state backend. Go source lives under `cmd/` and `internal/`; build output lands at the same executable paths that hooks and host adapters already call.

- **Single Go module** rooted at the repo (`go.mod`, module path `github.com/charlieyou/cerberus`).
- **Layout**: `cmd/<name>/main.go` for each in-scope binary (one per existing `bin/<name>` and one for `cmd/cerberus-amp-toolbox` whose built artifact lands in `dist/` and is invoked via the shim at `.amp/toolbox/cerberus.sh`). `internal/<domain>/` packages for shared logic. `Makefile` runs `go build -o dist.new/<name> ./cmd/<name>` per cmd into the repo-root sibling staging dir `dist.new/`, then atomically swaps it into place (`mv dist dist.old && mv dist.new dist && rm -rf dist.old`); the committed `bin/<name>` shims are never touched by the build.
- **Hook contract preservation**: hooks call the same `bin/<name>` paths; we only swap out the binary content. No edits to `hooks/hooks.json`, `templates/codex-hooks.json`, or any `commands/*.md`/`skills/*/SKILL.md`.
- **Reviewer subprocess contract**: `os/exec.Cmd` with `SysProcAttr.Setsid = true` on **both Linux and Darwin** (Go's `syscall` calls `setsid(2)` directly on macOS — no `setsid` binary needed), plus `Process.Release()` so parent exit doesn't reap. No `Cancel`/`WaitDelay` set on long-running reviewer commands. (This is the **Detach** pattern; the Phase 1–2 bridged bash debate coordinator uses the separate **Supervise** pattern with `Setpgid` instead — see `internal/procgroup` below.)
- **State file byte-compat**: `internal/state` reads/writes `gate-state.json` via a struct with explicit `json` tags and a custom `MarshalJSON` (delegating to `internal/jsonutil.MarshalOrdered`) to preserve key order. Goldens gate any drift.
- **Phase 1 bash debate bridge**: when `review-gate --debate` is invoked, Go assembles the env (export all `CERBERUS_*`, `REVIEW_GATE_*`, `CLAUDE_*`, plus `PATH`, `HOME`, `TMPDIR`, `LANG`, and reviewer API key vars) and runs `bash <CERBERUS_ROOT>/bin/review-gate-debate-bridge.sh "$@"` as a **child process via `cmd.Run()`** with passthrough stdio and a `signal.Notify` forwarder (the **Supervise** pattern — Go stays the parent so `defer`-driven cleanup of locks and marker files runs normally). The bridge wrapper sources `review-gate-lib.sh`, `telemetry-lib.sh`, `review-gate-models.sh`, and `review-gate-debate.sh` and invokes `run_debate_coordinator "$@"`; it exists because the debate library only defines functions and has no top-level invocation. State remains in `gate-state.json`; both sides lock via the same path through `github.com/gofrs/flock` (Go) and `flock(1)` (bash). Go releases its own `gate-state.json` lock before invoking the bridge.

## Prerequisites

- [ ] Initialize `go.mod` at repo root: `go mod init github.com/charlieyou/cerberus` (Go 1.25).
- [ ] **Establish the `dist/` + permanent-shim invariant in Phase 0** (load-bearing prereq for every later phase):
  - Add `/dist*/` to `.gitignore` (single pattern covers `dist/`, the `dist.new/` staging sibling, and the transient `dist.old/` swap directory).
  - Commit eight permanent bash shim scripts that are stable across all phases — they never change after Phase 0 lands them. Locations: `bin/review-gate`, `bin/generate`, `bin/cerberus-task-completed-hook`, `bin/cerberus-teammate-idle-hook`, `bin/claude-session-init`, `bin/codex-session-init`, `bin/codex-stop-hook` (the seven `bin/<name>` shims), and `.amp/toolbox/cerberus.sh` (the Amp shim). The two templates differ because the Amp shim lives one directory deeper than the `bin/<name>` shims **and** dispatches to a dist artifact whose filename is not the same as the shim filename:

    **Template A — generic `bin/<name>` shim (used for the seven `bin/<name>` paths):**

    ```bash
    #!/usr/bin/env bash
    # cerberus-shim v1 — DO NOT EDIT; replaced only by /plugin update.
    target="$(dirname "${BASH_SOURCE[0]}")/../dist/$(basename "$0")"
    if [ ! -x "$target" ]; then
      echo "cerberus: missing or non-executable $target — run 'make install-binaries' (see README)" >&2
      exit 127
    fi
    exec "$target" "$@"
    ```

    Resolves to `<repo>/dist/<name>` because `bin/../dist` = `<repo>/dist`, and `basename "$0"` = `<name>`.

    **Template B — Amp-specific shim (used ONLY at `.amp/toolbox/cerberus.sh`):**

    ```bash
    #!/usr/bin/env bash
    # cerberus-shim v1 (Amp)
    target="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/dist/cerberus-amp-toolbox"
    if [ ! -x "$target" ]; then
      echo "cerberus: missing or non-executable $target — run 'make install-binaries' (see README)" >&2
      exit 127
    fi
    exec "$target" "$@"
    ```

    Two reasons Template A would not work here:
    1. `.amp/toolbox/../dist/...` resolves to `.amp/dist/...`, not the repo-root `dist/`. The Amp shim lives two directories deep, so it must walk up two levels (`../..`) and use `cd -- ... && pwd` to deterministically resolve the repo root regardless of the caller's CWD or symlinks.
    2. The Amp dist artifact is named `dist/cerberus-amp-toolbox` (per the Makefile's `GO_CMDS` list), not `dist/cerberus.sh`. `basename "$0"` would yield `cerberus.sh`, which does not exist under `dist/`. The artifact name is therefore hard-coded in the Amp shim, eliminating any `$0`-vs-artifact-filename mismatch.

    The explicit pre-`exec` check in both templates is required because `exec`'s default failure message ("No such file or directory") is non-actionable. The `cerberus-shim v1` prefix is the sentinel `update-plugin` greps for (`grep -q '^# cerberus-shim v1' bin/<name>` and `grep -q '^# cerberus-shim v1' .amp/toolbox/cerberus.sh` — the parenthetical `(Amp)` suffix on the Amp shim does not affect the prefix match) to detect direct-binary substitution (see Risks).

    **Compat-wrapper behavior in Phases 0–2.** In Phases 0–2, `dist/cerberus-amp-toolbox` is an Amp-specific bash compat-wrapper (generated by `make install-binaries`, not committed) that delegates to `.amp/toolbox/cerberus.sh.bash-prod`. In Phase 3, it is replaced by the Go binary built from `cmd/cerberus-amp-toolbox/main.go`. The Amp shim at `.amp/toolbox/cerberus.sh` itself is unchanged across all phases — it always execs `<repo-root>/dist/cerberus-amp-toolbox`, regardless of whether that artifact is a compat-wrapper or a real Go binary. See **Distribution mechanic** for the wrapper template and the Makefile rules.
  - Move the existing bash production scripts to `bin/<name>.bash-prod` in the same Phase 0 commit so the shim and the legacy bash logic coexist. Each `bin/<name>.bash-prod` stays git-tracked until the phase that ports its target (Phase 1 deletes `bin/review-gate.bash-prod`; Phase 2 deletes the six lifecycle/generator scripts; Phase 3 deletes the Amp dispatcher's `.bash-prod` form when `cmd/cerberus-amp-toolbox` lands; the bash debate library is still sourced by `bin/review-gate-debate-bridge.sh` until Phase 4 deletes both). The shared libs (`bin/review-gate-lib.sh`, `bin/review-gate-models.sh`, `bin/review-gate-hook.sh`, `bin/review-gate-debate.sh`, `bin/telemetry-lib.sh`) keep their `.sh` names unchanged through Phase 4 because they are sourced, not exec'd. **There is no `bin/review-gate-debate.sh.bash-prod`** — the debate library is never renamed; only **production binaries** were renamed to `.bash-prod`.
  - Commit `bin/review-gate-debate-bridge.sh` (new in Phase 0, ~12 LOC) — a small bash dispatcher that the Phase 1+2 Go `review-gate --debate` execs. The library `bin/review-gate-debate.sh` only defines functions and has no top-level invocation, so executing it directly returns immediately without running anything. The bridge sources the four bash libs that the legacy bash `review-gate` sources and then calls the top-level entry function `run_debate_coordinator "$@"`. Contents:

    ```bash
    #!/usr/bin/env bash
    # Phase 1+2 bridge target: Go review-gate execs this script which sources
    # the existing review-gate-debate.sh library and invokes its top-level
    # entry function (run_debate_coordinator) with the passed args. Deleted in
    # Phase 3 when internal/debate replaces this entry surface.
    set -euo pipefail
    SCRIPT_DIR="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    # Source the same libs the bash production review-gate sources before
    # invoking the debate coordinator (review-gate-lib.sh, telemetry-lib.sh,
    # review-gate-models.sh, review-gate-debate.sh).
    source "$SCRIPT_DIR/review-gate-lib.sh"
    source "$SCRIPT_DIR/telemetry-lib.sh"
    source "$SCRIPT_DIR/review-gate-models.sh"
    source "$SCRIPT_DIR/review-gate-debate.sh"
    run_debate_coordinator "$@"
    ```

    This wrapper is committed (not auto-generated) so the Phase 1 Go bridge has a stable, exec'able target on day one. Phase 3 deletes this bridge once `internal/debate.Run(ctx, ...)` is called directly; the underlying bash debate library `bin/review-gate-debate.sh` (and the other shared libs) are deleted in Phase 4 along with the rest of the bash production code.
- [ ] Add `Makefile` with targets `build`, `test`, `bench`, `golden-capture`, `golden-diff`, `install-binaries` (the last builds every Go cmd to `dist.new/<name>` (a sibling of `dist/` at the repo root) and atomically swaps `dist.new` → `dist` via the `mv dist dist.old && mv dist.new dist && rm -rf dist.old` sequence; never touches the `bin/<name>` shims).
- [ ] Add GitHub Actions CI workflow (`.github/workflows/test.yml`): matrix `{ubuntu-latest, macos-latest} × {go: 1.25.x}`. Steps: checkout → setup-go (with cache) → `make build` → `go test ./... -race -cover` → `bash bin/tests/run-all.sh` → `make golden-diff` → `make bench` (warning-only initially).
- [ ] Capture the **24-cell golden fixture matrix** from unmodified bash production into `bin/tests/fixtures/golden/{mode}/{path}/{kind}/`. Each cell stores: stdout, stderr, exit code, final `gate-state.json`, `iteration-N/` tree, per-reviewer telemetry. Driver: `bin/tests/capture-goldens.sh` (new, ~150 LOC). Reviewer outputs are stubbed via the existing fixture-replay mechanism in `bin/tests/fixtures/` so capture is deterministic.
- [ ] Pin third-party deps: `github.com/gofrs/flock@latest` (audit), `github.com/stretchr/testify@latest` (tests), `github.com/google/go-cmp@latest` (tests). Run `go mod tidy`; commit `go.sum`.
- [ ] Confirm reviewer CLIs (`claude`, `codex`, `gemini`) are installed on CI runners or stub them via the existing fixture-replay mechanism in `bin/tests/fixtures/`.
- [ ] Document new install flow in README (Go 1.25 prereq, `make build` step, drop `jq`/`python3`/`setsid`/`gtimeout`/`flock(1)` from prereq table at the end of Phase 4).
- [ ] Edit `bin/update-plugin` (still bash) in Phase 0 to run `make install-binaries` after a successful pull. The pull now never aborts on a dirty tree because the build only writes inside the gitignored `dist*/` siblings (`dist/`, `dist.new/`, `dist.old/`); the `dist.new/` → `dist/` swap keeps the cutover atomic. Before invoking the build, the script greps each canonical shim for the `cerberus-shim v1` sentinel comment and aborts with a clear message if any shim has been replaced (see Risks > Shim/dist drift).
- [ ] **`bin/update-plugin` rebuild-failure UX (Phase 0).** `git pull` deletes ported `bin/<name>.bash-prod` files; if the post-pull `make install-binaries` fails (missing Go 1.25 toolchain, transient build error), the atomic swap does not happen — but for any binary newly ported in this pull, the existing `dist/<name>` is the prior phase's compat-wrapper that delegates to a now-deleted `.bash-prod`, leaving canonical shims pointing at a wrapper whose target is gone. Required handling: (1) **Pre-pull guard.** Before `git pull`, run `command -v go >/dev/null && go version | grep -q 'go1.25'`; if Go 1.25 is missing, abort BEFORE pull with stderr message `cerberus: Go 1.25 toolchain not found in PATH; refusing to pull because the post-pull rebuild would fail and leave the plugin in a broken state. Install Go 1.25 (see README) and re-run.` (2) **Capture the rebuild exit code.** Replace the unchecked `make install-binaries` invocation with `make install-binaries; rebuild_rc=$?`. (3) **Post-pull rebuild-rc check.** If `$rebuild_rc != 0`, print to stderr the exact text:
  ```
  cerberus: post-pull rebuild failed (exit $rebuild_rc).
  The plugin is in a broken state until 'make install-binaries' succeeds.
  Most common causes: missing Go 1.25 toolchain, dirty working tree, network failure.
  To recover: cd <CERBERUS_ROOT> && make install-binaries
  ```
  and exit `update-plugin` with the same non-zero `rebuild_rc` so callers/CI surface the failure.
- [ ] Confirm install-time build mechanism for Claude `/plugin install` and Codex two-step install (see OQ-A in Open Questions). Blocks the Phase 1 hard cutover.
- [ ] Manual smoke environments available for Claude, Codex, Amp, and generic host paths.
- [ ] Phase 0 captures golden fixtures before replacing any production script.
- [ ] Rollback path agreed: revert phase commit or pin previous release tag, with no runtime fallback knob.

## High-Level Approach

Single Go module, multi-cmd builds, **four sequential hard-cutover phases** after a non-cutover foundation phase. Each phase is a standalone tagged release; rollback = `git revert` of the phase commit + version pin to the prior tag. No `<name>.bash` fallback. No `CERBERUS_RUNTIME` env knob.

1. **Phase 0 — Foundations** (no user-visible change). Land `go.mod`, `Makefile`, GitHub Actions CI workflow, leaf packages (`internal/cerberusenv`, `internal/jsonutil`, `internal/procgroup`, `internal/state` skeleton, `internal/telemetry` skeleton). Add `/dist*/` to `.gitignore` (covers `dist/`, `dist.new/`, `dist.old/`). Commit the eight permanent `bin/<name>` and `.amp/toolbox/cerberus.sh` shims (seven generic + one Amp-specific — see Prerequisites for the two templates) and the new `bin/review-gate-debate-bridge.sh` wrapper that the Go bridge will exec, and rename the bash production scripts to `bin/<name>.bash-prod` so the shim can take the canonical path; the renamed `.bash-prod` files are git-tracked until each phase deletes them. (The Amp dispatcher's `.bash-prod` form is **kept** through Phase 2 so the Phase 0 Amp compat-wrapper can delegate to it; it is deleted in Phase 3 when `cmd/cerberus-amp-toolbox/main.go` lands. This corrects the earlier "delete in Phase 0" framing — without `.amp/toolbox/cerberus.sh.bash-prod` on disk, the Amp compat-wrapper has no bash logic to delegate to during Phases 0–2.) **`make install-binaries` produces a working `dist/<name>` for every binary in `GO_CMDS` from Phase 0 onward**: for any binary that does NOT yet have a `cmd/<name>/main.go`, the build emits a tiny **bash compat-wrapper** at `dist/<name>` that delegates to the corresponding `bin/<name>.bash-prod` (or `.amp/toolbox/cerberus.sh.bash-prod` for the Amp dispatcher) so the shim invariant holds end-to-end on day one. As each phase lands a Go `cmd/<name>/main.go`, the compat-wrapper at `dist/<name>` is replaced by a real Go binary at the next `make install-binaries`. The two compat-wrapper templates (one generic, one Amp-specific) mirror the two shim templates — see Prerequisites and Distribution mechanic. Generic compat-wrapper body (4 lines):

    ```bash
    #!/usr/bin/env bash
    # cerberus dist compat-wrapper v1
    # Generated by make install-binaries during Phase 0–N for binaries not yet ported to Go.
    # Replaced by a real Go binary when cmd/<name>/main.go lands.
    exec "$(dirname -- "$0")/../bin/$(basename -- "$0").bash-prod" "$@"
    ```

    Path resolution: from `dist/<name>`, `../bin/<name>.bash-prod` is the legacy script. The Amp wrapper at `dist/cerberus-amp-toolbox` needs a different relative path because `.amp/toolbox/cerberus.sh.bash-prod` is two directories deeper than `dist/`; the Amp compat-wrapper resolves the repo root via `cd -- "$(dirname -- "$0")/.." && pwd` and then references `<repo-root>/.amp/toolbox/cerberus.sh.bash-prod`. Capture the 24-cell golden matrix from unmodified bash by running the `.bash-prod` files directly (the compat-wrappers also work but are an unnecessary indirection during capture). Edit `bin/update-plugin` to invoke `make install-binaries` after pull, with rebuild-failure UX wired in: a **pre-pull guard** aborts BEFORE `git pull` if Go 1.25 is missing (stderr message names Go 1.25 and refuses to pull because the post-pull rebuild would leave the plugin broken); the rebuild call captures `rebuild_rc=$?` and on non-zero prints an explicit recovery message naming `<CERBERUS_ROOT>` and `make install-binaries`, then exits with the same `rebuild_rc` so callers/CI surface the failure. This guards against the "newly-ported `.bash-prod` deleted by `git pull`, rebuild then fails, canonical shim points at compat-wrapper whose target is gone" hazard — see Prerequisites > update-plugin entry for the exact stderr text and Risks > Update-plugin rebuild-failure UX. **No Go ports yet ship to users; every `dist/<name>` is a compat-wrapper that delegates to the existing bash production logic.**
2. **Phase 1 — Core `review-gate` (no debate)**. Land `cmd/review-gate/main.go` so `make install-binaries` produces `dist/review-gate`; delete `bin/review-gate.bash-prod` from git. The committed `bin/review-gate` shim is unchanged. The Go binary handles all subcommands except the `--debate` path. The `--debate` path runs `bash bin/review-gate-debate-bridge.sh` (the small Phase-0 wrapper that sources the bash libs and calls `run_debate_coordinator`) as a **child process under Go via `cmd.Run()`** (Supervise pattern — Go stays the parent, forwards signals to the bash pgid, and propagates the child's exit code) with the full env exported. `bin/review-gate-lib.sh`, `bin/review-gate-models.sh`, `bin/review-gate-hook.sh`, `bin/review-gate-debate.sh`, and `bin/telemetry-lib.sh` remain on disk (sourced by the bridge wrapper); their logic is duplicated into Go packages, not yet deleted. **Release-gate**: 12 non-debate cells of the golden matrix byte-equal + every external-surface bash test green + state/lock interop tests + manual Claude `Stop` smoke. After this phase ships, `dist/review-gate` is no longer a compat-wrapper but a real Go binary (assert via `grep -L 'cerberus dist compat-wrapper v1' dist/review-gate` and the precedence-assert CI step described in Risks).
3. **Phase 2 — Lifecycle hooks + generator**. Land `cmd/<name>/main.go` for `cerberus-task-completed-hook` (558 → Go), `cerberus-teammate-idle-hook` (198), `claude-session-init` (25), `codex-session-init` (196), `codex-stop-hook` (598), `generate` (768); `make install-binaries` produces `dist/<name>` for each. Delete the matching six `bin/<name>.bash-prod` files from git. Shims unchanged. All consume `internal/state` + `internal/telemetry` + `internal/cerberusenv`. Telemetry-lib internals continue to be ported as needed; by end of Phase 2, `internal/telemetry` is the single source of truth and the generator no longer sources `telemetry-lib.sh`. **Release-gate**: full hook integration smoke (Claude Stop, Codex Stop, Codex SessionStart) + bash test corpus + manual host smoke. After this phase ships, the six newly-ported `dist/<name>` artifacts are no longer compat-wrappers but real Go binaries (assert via grep against the `cerberus dist compat-wrapper v1` sentinel as in Phase 1).
4. **Phase 3 — Debate coordinator + Amp adapter**. Port `bin/review-gate-debate.sh` (3174 LOC) to `internal/debate`. Wire `review-gate --debate` to call `internal/debate.Run(ctx, ...)` directly; remove the bash bridge. Delete `bin/review-gate-debate-bridge.sh` since `internal/debate.Run(ctx, ...)` is called directly. Land `cmd/cerberus-amp-toolbox/main.go` so `make install-binaries` produces `dist/cerberus-amp-toolbox` (the committed `.amp/toolbox/cerberus.sh` shim execs it); delete `.amp/toolbox/cerberus.sh.bash-prod` from git. **Release-gate**: full 24-cell golden matrix + `test-debate-byte-parity.sh` (1018 LOC) byte equality + `test-debate-end-to-end.sh` + `test-debate-anonymization.sh` + `test-debate-aggregation.sh` + Amp toolbox JSON-stdio smoke + manual Amp smoke. After this phase ships, `dist/cerberus-amp-toolbox` is no longer a compat-wrapper but a real Go binary, and the precedence-assert CI step (see Risks) verifies that NO `dist/<name>` matches the `cerberus dist compat-wrapper v1` sentinel.
5. **Phase 4 — Cleanup**. Delete the now-orphan bash libraries (`review-gate-lib.sh`, `review-gate-models.sh`, `review-gate-hook.sh`, `review-gate-debate.sh`, `telemetry-lib.sh`). Retire bash test files whose targets are gone. Refresh `README.md` prereq table (drop `jq`, `python3`, `setsid`, `gtimeout`, `flock(1)`; add Go 1.25). Tag the final release. Confirm no runtime path still sources deleted shell libraries.

Each phase ends with: (a) every preserved bash test green, (b) new Go unit tests passing for the per-phase subset of the behavioral checklist (e.g., Phase 0 covers env precedence, state transitions, JSON canonicalization, lock interop; Phase 1 adds reviewer argv goldens, the 12 non-debate golden cells, and both the procgroup detach test (reviewer subprocesses) and the procgroup supervise test (bridged bash debate coordinator); Phase 2 adds hook fixture replay and telemetry extractor parity; Phase 3 adds the remaining 12 debate golden cells and `test-debate-byte-parity.sh`), (c) manual smoke per affected host (documented in `docs/CODEX.md` / `docs/AMP.md`), (d) a tagged release with a one-line revert path. `go test -cover` runs and reports a percentage in CI output, but the behavioral checklist — not the percentage — is the gate.

## Technical Design

### Architecture

```
repo-root/
├── go.mod                                  (NEW, Phase 0)
├── go.sum                                  (NEW, Phase 0)
├── Makefile                                (NEW, Phase 0)
├── .gitignore                              (MODIFY, Phase 0: add /dist*/ — covers dist/, dist.new/, dist.old/)
├── .github/workflows/test.yml              (NEW, Phase 0)
├── cmd/
│   ├── review-gate/main.go                 (NEW, Phase 1)
│   ├── generate/main.go                    (NEW, Phase 2)
│   ├── cerberus-task-completed-hook/main.go(NEW, Phase 2)
│   ├── cerberus-teammate-idle-hook/main.go (NEW, Phase 2)
│   ├── claude-session-init/main.go         (NEW, Phase 2)
│   ├── codex-session-init/main.go          (NEW, Phase 2)
│   ├── codex-stop-hook/main.go             (NEW, Phase 2)
│   └── cerberus-amp-toolbox/main.go        (NEW, Phase 3) → built to dist/cerberus-amp-toolbox; Amp shim at .amp/toolbox/cerberus.sh execs it
├── internal/
│   ├── cerberusenv/   (Phase 0) host-neutral env contract + alias resolution
│   ├── jsonutil/      (Phase 0) jq replacements (sorted-key marshal, paths(), repair)
│   ├── procgroup/     (Phase 0) Detach() (Setsid, reviewer subprocesses) + Supervise() (Setpgid, bridged bash debate coordinator)
│   ├── state/         (Phase 0 skeleton, Phase 1 complete) gate-state.json + flock
│   ├── telemetry/     (Phase 0 skeleton, Phase 2 complete) extractors + iteration dir lifecycle
│   ├── reviewers/     (Phase 1) Codex/Gemini/Claude argv assembly + invocation
│   ├── prompts/       (Phase 1) template loading from prompts/*.md
│   ├── host/          (Phase 1) claude/codex/amp/generic adapter glue
│   ├── hooks/         (Phase 2) hook stdin/stdout adapters
│   ├── generator/     (Phase 2) generator orchestration
│   ├── debate/        (Phase 3) round loop, anonymization, aggregation, exit codes
│   └── ampbridge/     (Phase 3) TOOLBOX_ACTION dispatch for the Amp toolbox binary
├── dist/                                   (NEW, Phase 0; gitignored — generated build output)
│   ├── review-gate                         (Go binary; produced Phase 1)
│   ├── generate                            (Go binary; produced Phase 2)
│   ├── cerberus-task-completed-hook        (Go binary; produced Phase 2)
│   ├── cerberus-teammate-idle-hook         (Go binary; produced Phase 2)
│   ├── claude-session-init                 (Go binary; produced Phase 2)
│   ├── codex-session-init                  (Go binary; produced Phase 2)
│   ├── codex-stop-hook                     (Go binary; produced Phase 2)
│   └── cerberus-amp-toolbox                (Go binary; produced Phase 3)
├── dist.new/                               (transient sibling of dist/ at repo root; atomically swapped → dist/ on success; gitignored)
├── dist.old/                               (transient previous-dist holder during swap; removed at end of install-binaries; gitignored)
├── .amp/toolbox/
│   └── cerberus.sh                         (NEW shim Phase 0; committed; execs dist/cerberus-amp-toolbox once it exists)
└── bin/
    ├── review-gate                         (NEW shim Phase 0; committed; stable across all phases)
    ├── generate                            (NEW shim Phase 0; committed; stable across all phases)
    ├── cerberus-task-completed-hook        (NEW shim Phase 0; committed; stable across all phases)
    ├── cerberus-teammate-idle-hook         (NEW shim Phase 0; committed; stable across all phases)
    ├── claude-session-init                 (NEW shim Phase 0; committed; stable across all phases)
    ├── codex-session-init                  (NEW shim Phase 0; committed; stable across all phases)
    ├── codex-stop-hook                     (NEW shim Phase 0; committed; stable across all phases)
    ├── review-gate.bash-prod               (RENAME Phase 0; DELETE Phase 1 — legacy bash production)
    ├── generate.bash-prod                  (RENAME Phase 0; DELETE Phase 2)
    ├── cerberus-task-completed-hook.bash-prod (RENAME Phase 0; DELETE Phase 2)
    ├── cerberus-teammate-idle-hook.bash-prod  (RENAME Phase 0; DELETE Phase 2)
    ├── claude-session-init.bash-prod       (RENAME Phase 0; DELETE Phase 2)
    ├── codex-session-init.bash-prod        (RENAME Phase 0; DELETE Phase 2)
    ├── codex-stop-hook.bash-prod           (RENAME Phase 0; DELETE Phase 2)
    ├── update-plugin                       (KEEP bash; minor edit Phase 0)
    ├── review-gate-lib.sh                  (DELETE Phase 4)
    ├── review-gate-models.sh               (DELETE Phase 4)
    ├── review-gate-hook.sh                 (DELETE Phase 4)
    ├── review-gate-debate.sh               (DELETE Phase 4 — sourced via the bridge wrapper through Phase 2)
    ├── review-gate-debate-bridge.sh        (NEW Phase 0; DELETE Phase 3 — small wrapper that sources the libs and calls run_debate_coordinator)
    └── telemetry-lib.sh                    (DELETE Phase 4)
```

Across all phases the invariant holds: `bin/<name>` is a tiny committed bash shim, `dist/<name>` is the gitignored Go build artifact, and `make install-binaries` only ever writes inside `dist/`. The eight canonical executable paths (seven `bin/<name>` shims + `.amp/toolbox/cerberus.sh` shim) must keep working; `bin/update-plugin` remains bash.

#### Package responsibilities + key signatures

**`internal/cerberusenv`** — ports `__cerberus_resolve_*` from `bin/review-gate-lib.sh`. Preserves alias precedence (canonical `CERBERUS_*` wins over legacy aliases when both are non-empty) and emits a single stderr warning per process via `sync.Once`.

```go
package cerberusenv

type Host string

const (
    HostClaude  Host = "claude"
    HostCodex   Host = "codex"
    HostAmp     Host = "amp"
    HostGeneric Host = "generic"
)

type Env struct {
    Host           Host
    Root           string // CERBERUS_ROOT (alias: CLAUDE_PLUGIN_ROOT)
    StateRoot      string // CERBERUS_STATE_ROOT (or host default)
    ProjectKey     string // CERBERUS_PROJECT_KEY (or computed via ProjectHash)
    SessionID      string // CERBERUS_SESSION_ID (alias: CLAUDE_SESSION_ID)
    RunKey         string // CERBERUS_RUN_KEY (alias: REVIEW_GATE_SESSION_KEY)
    TranscriptPath string // CERBERUS_TRANSCRIPT_PATH (aliases: CLAUDE_TRANSCRIPT_PATH, REVIEW_GATE_TRANSCRIPT_PATH)
    ProjectDir     string
}

type ResolveOptions struct {
    Lookup        func(string) (string, bool)
    WorkingDir    string
    Stderr        io.Writer
    TranscriptArg string
    SessionArg    string
}

// Resolve walks the precedence chain documented in README:478–491.
// Emits a single stderr warning per process if a canonical and an alias
// disagree (sync.Once gate).
func Resolve(opts ResolveOptions) (Env, error)

func ResolveRunKey(lookup func(string) (string, bool), stderr io.Writer) string
func ResolveRoot(lookup func(string) (string, bool), cwd string) (string, error)
func ResolveSessionID(lookup func(string) (string, bool)) string
func ResolveTranscriptPath(lookup func(string) (string, bool)) string

// ProjectHash mirrors get_project_hash(): SHA256 of EvalSymlinks(cwd or root)
// truncated to 12 hex chars.
func ProjectHash(projectRoot, transcriptPath string) string

// ExportNeutralEnv (a.k.a. ExportForSubprocess) returns the os.Environ()-shaped
// slice with both canonical CERBERUS_* and legacy aliases set, for handing to
// bash bridges or reviewer subprocesses.
func ExportNeutralEnv(base []string, env Env) []string
```

**`internal/state`** — ports `gate-state.json` I/O, atomic writes, locking. Uses `${file}.lock`, a 5-second lock timeout (matching bash), temp-file write `${file}.tmp.<pid>`, and atomic rename.

```go
package state

type Store struct {
    Env    cerberusenv.Env
    Clock  Clock
    Locker Locker
}

type Gate struct {
    SchemaVersion int                    `json:"schema_version"`
    Status        string                 `json:"status"` // "pending" | "approved" | "rejected" | "abstained" | ...
    Consensus     Consensus              `json:"consensus"`
    Decision      Decision               `json:"decision"`
    IterationN    int                    `json:"iteration_n"`
    Reviewers     map[string]ReviewerOut `json:"reviewers"`
    // ... all keys present in current bash output, in current key order
}

type Iteration struct {
    Number int
    Dir    string
}

func NewStore(env cerberusenv.Env, opts StoreOptions) (*Store, error)
func (s *Store) ReviewDir() (string, error)
func (s *Store) ResolveReviewDir(sessionID, transcriptPath string) (string, error)
func (s *Store) FindActiveGate(ctx context.Context) (*GateRef, error)
func (s *Store) LoadGate(ctx context.Context, path string) (*Gate, error)
func (s *Store) SaveGate(ctx context.Context, path string, state *Gate) error
func (s *Store) UpdateGate(ctx context.Context, path string, fn func(*Gate) error) error
func (s *Store) ArchiveReviews(ctx context.Context, reviewDir string) error
func (s *Store) LoadIteration(ctx context.Context, reviewDir string) (int, error)
func (s *Store) SaveIteration(ctx context.Context, reviewDir string, iter int) error
func (s *Store) IterationDir(reviewDir string, iter int) string

// AtomicWrite mirrors atomic_write in bin/telemetry-lib.sh: tmp file + rename.
func AtomicWrite(path string, data []byte, perm fs.FileMode) error

// WithFileLock acquires an advisory lock at `lockPath` via gofrs/flock and
// runs fn. Compatible with flock(1) callers in bash. 5s timeout default.
func WithFileLock(ctx context.Context, lockPath string, timeout time.Duration, fn func() error) error
```

**`internal/jsonutil`** — `jq` replacement helpers + ordered marshaling + golden-fixture canonicalization.

```go
package jsonutil

type OrderedObject struct {
    Keys   []string
    Values map[string]json.RawMessage
}

// MarshalStable marshals v with a fixed key order matching the bash output.
// Used by Gate.MarshalJSON and the per-reviewer telemetry writers.
func MarshalStable(v any) ([]byte, error)
func MarshalCompactStable(v any) ([]byte, error)
func UnmarshalObject(data []byte) (OrderedObject, error)
func PatchObject(data []byte, patch func(*OrderedObject) error) ([]byte, error)

// PathsScalars implements `paths(scalars) as $p | $p | join(".")` over
// a parsed map[string]any tree.
func PathsScalars(v any) []string

// Repair applies the same lenient parse the python3 callsite did
// (strip BOM, recover from trailing commas in known callsites).
func Repair(in []byte) ([]byte, error)

// CanonicalOpts configures Canonicalize. The default value masks every
// known nondeterministic field for golden-fixture diffing; callers may
// extend it for callsite-specific masks. The mask list lives in
// internal/jsonutil/canonical.go and is reviewed at every Decision Log
// update — see "Golden fixture normalization" below.
type CanonicalOpts struct {
    TimestampPaths []string // dotted/JSON-pointer patterns → "<TIMESTAMP>"
    PIDPaths       []string // → "<PID>"
    IDPaths        []string // → "<ID>" (random/UUID-shaped only)
    PathPrefixes   []string // ephemeral filesystem prefixes → "<TMP>"
    DurationPaths  []string // *_ms / *_seconds / latency_ms → "<MS>"
}

// Canonicalize is the single normalization function applied identically
// to bash-captured goldens and Go-produced output before byte comparison.
// Same code path on both sides means there is one place to change
// normalization rules. See "Golden fixture normalization" in
// Testing & Validation Strategy.
func Canonicalize(b []byte, opts CanonicalOpts) []byte
```

**`internal/telemetry`** — ports `extract_*_telemetry` + iteration dir lifecycle from `bin/telemetry-lib.sh:161–354`.

```go
package telemetry

type Agent string

const (
    AgentClaude Agent = "claude"
    AgentCodex  Agent = "codex"
    AgentGemini Agent = "gemini"
)

type AgentTelemetry struct {
    Agent     Agent
    DurationS int
    InputTok  int
    OutputTok int
    Verdict   string
    Stats     json.RawMessage
    Raw       json.RawMessage
    Draft     string
    // … exact field set captured from current bash output via goldens
}

func InitIterationDir(ctx context.Context, store *state.Store, reviewDir string, iter int) (string, error)
func ExtractClaude(data []byte) (*AgentTelemetry, error)            // claude-output*.json
func ExtractCodexJSONL(data []byte) (*AgentTelemetry, error)        // codex-output.jsonl
func ExtractGemini(data []byte) (*AgentTelemetry, error)            // gemini stdout
func ExtractFromJSON(agent Agent, data []byte) (*AgentTelemetry, error)
func ExtractFromJSONL(agent Agent, data []byte) (*AgentTelemetry, error)
func WriteAgentTelemetry(ctx context.Context, iterDir string, t *AgentTelemetry) error
func UpdateRunTelemetry(ctx context.Context, store *state.Store, reviewDir string, patch RunPatch) error
func UpdateRunTelemetryOnResolve(ctx context.Context, store *state.Store, reviewDir string, decision Decision) error
func SummaryForOutput(ctx context.Context, reviewDir string) (*Summary, error)
```

**`internal/procgroup`** — two distinct patterns for managing subprocess process groups, plus reaper-safe helpers. Unix build tags for Linux/macOS.

There are two patterns, used in different places:

- **Detach** (used for **reviewer subprocesses** launched by Go: `claude`, `codex`, `gemini`). The subprocess must survive parent exit so the stop-hook can return while reviewers continue running. Implementation: `SysProcAttr{Setsid: true}` on **both Linux and Darwin** (Go's `syscall` calls `setsid(2)` directly on macOS — no `setsid` binary needed), plus `Process.Release()` after `Start`. Symmetric across platforms. Matches the bash `setsid` semantics being replaced. Go does **not** signal-forward to detached children.
- **Supervise** (used for the **bridged bash debate coordinator** in Phases 1+2). The bash child shares Go's lifetime; Go is the parent and forwards signals (SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGUSR1) to the child's process group. Implementation: `SysProcAttr{Setpgid: true}` (gives the child a stable pgid equal to its pid); `signal.Notify` goroutine forwards via `syscall.Kill(-cmd.Process.Pid, sig)`; Go waits with `cmd.Wait()` and propagates the child's exit code via `cmd.ProcessState.ExitCode()`.

```go
package procgroup

type Process struct {
    Cmd  *exec.Cmd
    PGID int
}

// Detach configures *exec.Cmd so the child survives parent exit.
// Both Linux and Darwin: SysProcAttr.Setsid = true (symmetric, matches bash `setsid` semantics).
// After Start, caller invokes Cmd.Process.Release().
// Used for reviewer subprocesses (claude/codex/gemini).
func Detach(cmd *exec.Cmd)

// Supervise configures *exec.Cmd so the child runs in a new process group under
// Go's lifetime, allowing signal forwarding to the child's pgid.
// Both Linux and Darwin: SysProcAttr.Setpgid = true (Pgid = 0 → child becomes its
// own pgid leader). Caller pairs this with a signal.Notify forwarder that calls
// syscall.Kill(-cmd.Process.Pid, sig). Used for the bridged bash debate coordinator
// during Phases 1+2.
func Supervise(cmd *exec.Cmd)

func StartDetached(ctx context.Context, cmd *exec.Cmd) (*Process, error)
func StartSupervised(ctx context.Context, cmd *exec.Cmd) (*Process, error)
func StartWithTimeout(ctx context.Context, cmd *exec.Cmd, timeout time.Duration) (*Process, error)
func SignalGroup(pid int, sig os.Signal) error
func KillGroup(pid int) error
func Wait(ctx context.Context, p *Process) error
```

**`internal/reviewers`** — ports `bin/review-gate-models.sh`. Reviewer CLIs remain external subprocesses; argv assembly is golden-tested.

```go
package reviewers

type Mode string       // "fast" | "smart" | "max"
type ReviewType string // "code" | "plan" | "spec" | "ask"
type ReviewerName string

type Request struct {
    Reviewer       ReviewerName
    Mode           Mode
    Type           ReviewType
    PromptPath     string
    OutputPath     string
    SchemaPath     string
    WorkingDir     string
    Env            cerberusenv.Env
    ExtraEnv       []string
    Timeout        time.Duration
    Detached       bool
    StructuredJSON bool
}

type Result struct {
    Reviewer   ReviewerName
    ExitCode   int
    OutputPath string
    Telemetry  *telemetry.AgentTelemetry
}

type Runner interface {
    Available(ctx context.Context, name ReviewerName) bool
    Command(ctx context.Context, req Request) (*exec.Cmd, error)
    Spawn(ctx context.Context, req Request) (*procgroup.Process, error)
    Run(ctx context.Context, req Request) (*Result, error)
}

func ModeConfig(mode Mode) ModeSettings
func BuildClaudeCommand(req Request) (*exec.Cmd, error)
func BuildCodexCommand(req Request) (*exec.Cmd, error)
func BuildGeminiCommand(req Request) (*exec.Cmd, error)
```

**`internal/debate`** (Phase 3) — ports `bin/review-gate-debate.sh`. Preserves preflight, round loop, anonymized peer broadcasts, abstain/degraded/cancel exits, final-round exclusion behavior, and canonical exit codes.

```go
package debate

const (
    ExitAggregatorFailure = 5  // exit 5 — aggregator-failure abstain
    ExitDegraded          = 6  // exit 6 — degraded (preflight or mid-debate)
    ExitCanceled          = 130
)

type Coordinator struct {
    Store     *state.Store
    Reviewers reviewers.Runner
    Telemetry *telemetry.Service
    Prompts   *prompts.Renderer
    Clock     Clock
    Logger    Logger
}

type Request struct {
    ReviewType reviewers.ReviewType
    Mode       reviewers.Mode
    Agents     []reviewers.ReviewerName
    ReviewDir  string
    MaxRounds  int
    Args       []string
}

func (c *Coordinator) Run(ctx context.Context, req Request) int
func (c *Coordinator) Preflight(ctx context.Context, req Request) error
func (c *Coordinator) RunRound(ctx context.Context, req Request, round int) (*RoundResult, error)
func (c *Coordinator) Aggregate(ctx context.Context, req Request, final *RoundResult) (*Aggregate, error)
func (c *Coordinator) MarkDegraded(ctx context.Context, reviewDir string) error
func (c *Coordinator) Cancel(ctx context.Context, reviewDir string) int
```

**`internal/hooks`** (Phase 2) — hook stdin/stdout adapters. Preserve stdin fixtures, stdout/stderr discipline, timeout budgets.

```go
package hooks

func HandleClaudeSessionInit(ctx context.Context, stdin io.Reader, stdout, stderr io.Writer, env cerberusenv.Env) int
func HandleCodexSessionInit(ctx context.Context, stdin io.Reader, stdout, stderr io.Writer, env cerberusenv.Env) int
func HandleCodexStop(ctx context.Context, stdin io.Reader, stdout, stderr io.Writer, env cerberusenv.Env) int
func HandleTaskCompleted(ctx context.Context, stdin io.Reader, stdout, stderr io.Writer, env cerberusenv.Env) int
func HandleTeammateIdle(ctx context.Context, stdin io.Reader, stdout, stderr io.Writer, env cerberusenv.Env) int
```

**`internal/generator`** (Phase 2) — generator orchestration.

```go
package generator

type Action string

const (
    ActionHealthcheck        Action = "healthcheck"
    ActionArchitectureReview Action = "architecture-review"
    ActionCreateSpec         Action = "create-spec"
    ActionCreatePlan         Action = "create-plan"
)

type Request struct {
    Action Action
    Mode   reviewers.Mode
    Args   []string
    Env    cerberusenv.Env
}

func Run(ctx context.Context, req Request, stdout, stderr io.Writer) int
```

**`internal/prompts`** — runtime prompt loader. Prompt file contents are read from existing `prompts/` markdown and not rewritten.

```go
package prompts

type Renderer struct {
    Root string
}

func (r *Renderer) Load(path string) (string, error)
func (r *Renderer) RenderReviewPrompt(reviewType reviewers.ReviewType, data PromptData) (string, error)
func (r *Renderer) RenderDebatePrompt(reviewType reviewers.ReviewType, data DebatePromptData) (string, error)
```

**`internal/ampbridge`** (Phase 3) — `TOOLBOX_ACTION` dispatch.

```go
package ampbridge

type Request struct { /* shape from .amp/toolbox/cerberus.sh stdin */ }
type Response struct { /* shape from .amp/toolbox/cerberus.sh stdout */ }

func Dispatch(action string, req Request) (Response, error)
// action ∈ {"review-code", "review-plan", "review-spec", "ask-panel", "status", "clear-gate"}
```

#### `cmd/<name>/main.go` wiring (canonical pattern)

Each `cmd/<name>/main.go` is a thin entrypoint:

```go
func main() {
    ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
    defer cancel()

    env, err := cerberusenv.Resolve(cerberusenv.ResolveOptions{
        Lookup:     os.LookupEnv,
        WorkingDir: mustWd(),
        Stderr:     os.Stderr,
    })
    if err != nil { fatal(err) }

    // Subcommand dispatch via stdlib flag + manual switch (review-gate)
    // OR direct hook handler invocation (hooks) OR generator.Run (generate).
    code := dispatch(ctx, env, os.Args[1:], os.Stdin, os.Stdout, os.Stderr)
    os.Exit(code)
}
```

#### Phase 1 cutover plan (the load-bearing one)

1. Build `cmd/review-gate` so `go build -o dist.new/review-gate ./cmd/review-gate` (followed by the atomic `dist.new/` → `dist/` swap in `make install-binaries`) produces `dist/review-gate`. The committed `bin/review-gate` shim then routes invocations to it; no git-tracked files change.
2. The Go binary's `main()`:
   - Calls `cerberusenv.Resolve()`.
   - Dispatches subcommands (`check`, `spawn`, `spawn-code-review`, `spawn-plan-review`, `spawn-spec-review`, `spawn-epic-verify`, `spawn-ask`, `wait`, `resolve`, `artifact-path`, `author-context`, `status`) via stdlib `flag` + manual switch.
   - Each subcommand goes through `state.WithFileLock(env.GateStatePath()+".lock", 5*time.Second, …)` for any read-modify-write of `gate-state.json`.
3. The `--debate` flag (allowed on `spawn`/`spawn-*-review`) triggers the **bash debate bridge**. The Go process **remains the parent** of the bash debate coordinator (the **Supervise** pattern); it does NOT replace itself with `syscall.Exec`. Concretely:
   - Go assembles env via `cerberusenv.ExportNeutralEnv()` plus `PATH`, `HOME`, `TMPDIR`, `LANG`, plus reviewer API key vars (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY` if present in parent env).
   - Go releases its own `gate-state.json` lock first.
   - Bridge invocation:
     ```go
     cmd := exec.CommandContext(ctx, "bash",
         filepath.Join(cerberusRoot, "bin/review-gate-debate-bridge.sh"))
     cmd.Args = append(cmd.Args, passThroughArgs...)
     cmd.Stdin  = os.Stdin
     cmd.Stdout = os.Stdout
     cmd.Stderr = os.Stderr
     cmd.Env    = append(os.Environ(), exportedNeutralEnvVars...) // CERBERUS_ROOT, CERBERUS_RUN_KEY, CERBERUS_SESSION_ID, CERBERUS_TRANSCRIPT_PATH, CERBERUS_HOST, REVIEW_GATE_* aliases, CLAUDE_* aliases, plus PATH/HOME/TMPDIR/LANG and any present reviewer API keys
     cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} // stable pgid for forwarding
     if err := cmd.Start(); err != nil { /* fatal */ }

     // Forward signals to the child's process group so bash receives them in pgid form.
     sigCh := make(chan os.Signal, 1)
     signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGQUIT, syscall.SIGUSR1)
     go func() {
         for s := range sigCh {
             _ = syscall.Kill(-cmd.Process.Pid, s.(syscall.Signal))
         }
     }()

     err := cmd.Wait()
     signal.Stop(sigCh); close(sigCh)
     // Exit-code propagation: forward bash's exit code verbatim.
     if err != nil {
         var ee *exec.ExitError
         if errors.As(err, &ee) { os.Exit(cmd.ProcessState.ExitCode()) }
         /* else fatal */
     }
     ```
   - Go `defer`s run normally (lock release, marker-file cleanup) because the Go process is never replaced.
   - **Observable change vs the prior all-bash world**: `ps`/`pgrep` reports a Go parent with a bash child during the bridge phases instead of a single bash process. This is recorded in the **Deviation Log** as approved, with rationale "preserves Go-side cleanup invariants and signal handling."
4. The `bin/review-gate-debate-bridge.sh` wrapper sources `bin/review-gate-lib.sh`, `bin/telemetry-lib.sh`, `bin/review-gate-models.sh`, and `bin/review-gate-debate.sh`, then invokes `run_debate_coordinator "$@"` (the legacy library only defines functions; the wrapper is what makes the entry point exec'able). Both bash and Go lock `gate-state.json` via the same path; `gofrs/flock` and `flock(1)` interop on the same advisory lock.
5. Hard cutover: at Phase 1 release, the legacy `bin/review-gate.bash-prod` (5767 LOC, renamed in Phase 0) is **deleted from git tracking**. The committed shim at `bin/review-gate` is unchanged; the cutover happens entirely inside `dist/` (which now holds `dist/review-gate` as a Go binary). Rollback = `git revert` of the phase commit (which restores `bin/review-gate.bash-prod` and removes the `cmd/review-gate/` source) + `git tag` pin; the shim path is stable so hooks keep resolving.
6. Release gate: 12 non-debate golden cells byte-equal; every external-surface bash test in `bin/tests/` green; cross-runtime flock interop test green on Linux + macOS; manual smoke on Claude `Stop` hook against a real workspace.

#### CI design

`.github/workflows/test.yml` (new):
- Triggers: `push` to any branch, `pull_request`, `workflow_dispatch`.
- Matrix: `os: [ubuntu-latest, macos-latest]`, `go: ['1.25.x']`.
- Steps:
  1. `actions/checkout@v4`
  2. `actions/setup-go@v5` (with cache for modules + build cache)
  3. Install transitional test dependencies only while needed: `jq` and GNU coreutils/timeout for bash tests that still target the bash bridge or legacy scripts.
  4. Install reviewer-CLI stubs (test-only; reuse existing `bin/tests/fixtures/` replay shims).
  5. `make build` (or `make install-binaries`) → builds per cmd into `dist.new/<name>` (sibling of `dist/` at the repo root) and atomically swaps `dist.new/` → `dist/`. Verifies `test -x` for every canonical shim (`bin/<name>`, `.amp/toolbox/cerberus.sh`) **and** for every `dist/<name>` artifact.
  6. `go test ./... -race -cover -coverprofile=coverage.out` → all tests must pass (race detector clean). The coverage percentage is **printed to CI output as supporting evidence only** — there is no minimum-percentage gate, because line coverage is gameable (a test that calls a function but asserts nothing still counts). The behavioral checklist in **Testing Constraints** is the load-bearing gate; the per-phase release gate runs the relevant subset of the ten test classes (env precedence, state transitions, reviewer argv goldens, telemetry extractor parity, lock interop, JSON canonicalization, 24-cell golden parity, hook fixture replay, bash acceptance suite, procgroup detach + supervise).
  7. `bash bin/tests/run-all.sh` → external-surface bash tests against the built binaries.
  8. `make golden-diff` → diff captured 24-cell goldens against the current Go-built run for cells in scope of the current phase.
  9. (warning-only initially) `make bench` → cold-start latency report.
- Phase 0 CI may run against bash binaries plus Go package tests. Later phases run after `make install-binaries`.
- Build cost target: 8 binaries × ~10s cold ≈ 80s build + ~60s test + ~120s bash suite = ~5 minutes per matrix cell. Tolerable. Mitigation: shared `go build ./cmd/...` invocation reuses the build cache.
- Artifact upload: golden diff output uploaded on failure for forensic review.

#### Distribution mechanic

Compiled Go binaries live in the gitignored `dist/` directory; canonical `bin/<name>` and `.amp/toolbox/cerberus.sh` paths are permanent committed bash shims that `exec` into `dist/`. This invariant is established in Phase 0 and unchanged through Phase 4. `make install-binaries` only ever writes inside `dist/`; the shims are never overwritten by a build.

Build target (`Makefile`):

```makefile
GO ?= go
GOFLAGS ?= -trimpath
GO_CMDS := review-gate generate \
           cerberus-task-completed-hook cerberus-teammate-idle-hook \
           claude-session-init codex-session-init codex-stop-hook \
           cerberus-amp-toolbox

# `$(shell find ...)` instead of `$(wildcard internal/**/*.go)` — macOS ships GNU Make 3.81,
# which does NOT support `**` globstar in `$(wildcard ...)`. Using find guarantees recursive
# discovery on every supported Make version so partial dist.new/ from an aborted run cannot let
# a later install-binaries skip a rebuild after nested internal/ sources changed.
GO_SOURCES := $(shell find internal -type f -name '*.go')

.PHONY: install-binaries build test bench golden-capture golden-diff install-compat-wrappers

# Per-cmd Go-build pattern rule — staging path is dist.new/<name> (a sibling of dist/ at the
# repo root, NOT a child of it). This rule has prerequisites; Make's pattern-rule precedence
# prefers it over the prerequisite-less compat-wrapper rule below whenever cmd/<name>/main.go
# exists, so Phase 1+ ports automatically take over from the Phase 0–N compat-wrappers.
dist.new/%: cmd/%/main.go $(GO_SOURCES)
	@mkdir -p dist.new
	$(GO) build $(GOFLAGS) -o $@ ./cmd/$*

# Compat-wrapper rule — fires when cmd/<name>/main.go does NOT exist yet (Phase 0–N transitional
# state). Generates a 4-line bash wrapper at dist/<name> that delegates to the legacy bash
# production script at bin/<name>.bash-prod. The cerberus-amp-toolbox cmd needs a different
# relative path because .amp/toolbox/cerberus.sh.bash-prod is two levels deeper than dist/, so
# we branch on $* in the recipe. This single recipe (rather than two pattern rules) makes the
# branch explicit and avoids any reliance on Make 3.81 vs 4.x pattern-rule precedence edge cases
# beyond the Go-build-rule-vs-this-rule split itself.
dist.new/%:
	@mkdir -p dist.new
	@if [ "$*" = "cerberus-amp-toolbox" ]; then \
	  printf '%s\n' \
	    '#!/usr/bin/env bash' \
	    '# cerberus dist compat-wrapper v1 (Amp)' \
	    '# Generated by make install-binaries during Phase 0–2 for the Amp dispatcher; replaced by a real Go binary in Phase 3.' \
	    'exec "$$(cd -- "$$(dirname -- "$$0")/.." && pwd)/.amp/toolbox/cerberus.sh.bash-prod" "$$@"' \
	    > $@; \
	else \
	  printf '%s\n' \
	    '#!/usr/bin/env bash' \
	    '# cerberus dist compat-wrapper v1' \
	    '# Generated by make install-binaries during Phase 0–N for binaries not yet ported to Go.' \
	    '# Replaced by a real Go binary when cmd/<name>/main.go lands.' \
	    'exec "$$(dirname -- "$$0")/../bin/$$(basename -- "$$0").bash-prod" "$$@"' \
	    > $@; \
	fi
	@chmod +x $@

# Build every cmd into dist.new/, then atomically swap dist.new → dist via dist.old.
# Staging is a SIBLING of dist/, not a child, so `mv dist dist.old` does not relocate the staging tree.
install-binaries: $(addprefix dist.new/,$(GO_CMDS))
	@rm -rf dist.old
	@set -e; \
	if [ -d dist ]; then \
	  trap 'if [ -d dist.old ] && [ ! -d dist ]; then mv dist.old dist; fi' EXIT; \
	  mv dist dist.old; \
	fi; \
	mv dist.new dist; \
	trap - EXIT; \
	rm -rf dist.old
	@for c in $(GO_CMDS); do test -x dist/$$c || { echo "missing dist/$$c" >&2; exit 1; }; done
```

Notes on the pattern:
- Each cmd is built **separately** to its own staged path so a single broken `cmd/<name>` does not corrupt the on-disk `dist/` for the others.
- Staging directory `dist.new/` is a **sibling** of `dist/` at the repo root, not a child. This is load-bearing: if staging lived inside `dist/` (e.g. `dist/.staging/`), the `mv dist dist.old` step would relocate the staging tree along with the rest of `dist/` and the next `mv dist.new dist` would fail.
- The atomic `mv dist.new dist` replaces the binaries in one rename, so an interrupted build never leaves a half-populated `dist/`. `dist.old/` is removed on success and is the rollback target on failure (the build leaves the previous `dist/` undisturbed and prints a loud error).
- **Atomic swap with EXIT trap.** If `mv dist.new dist` fails or the recipe is interrupted between the two `mv`s, an EXIT trap restores `dist.old → dist` so canonical shims keep resolving to the prior build. The unrecoverable window is one `rename(2)` call (`mv dist.new dist`); on POSIX rename is atomic on the same filesystem, so partial state at that line is not possible.
- The committed shims at `bin/<name>` and `.amp/toolbox/cerberus.sh` are **not** mentioned by `install-binaries`; the build cannot dirty the working tree, and `bin/update-plugin`'s `git pull` will never abort with "local changes would be overwritten by merge".
- **`GO_SOURCES := $(shell find internal -type f -name '*.go')`** is the cross-version-portable replacement for `$(wildcard internal/**/*.go)`. macOS ships GNU Make 3.81, which does not honor `**` globstar in `$(wildcard ...)`; without `find`, partial `dist.new/` from an aborted run could let a follow-up `make install-binaries` skip a rebuild even though nested `internal/` dependencies changed.
- **Pattern-rule precedence (Go-build rule vs compat-wrapper rule)** is load-bearing during Phases 0–N. The Go-build rule has a real prerequisite (`cmd/%/main.go`); the compat-wrapper rule has none. GNU Make documents that an explicit-prerequisite pattern rule is preferred over a prerequisite-less one when both could match, so the compat-wrapper fires only when `cmd/<name>/main.go` does not exist. This is verified by the CI assertion described in Risks > "Pattern-rule precedence assumption".
- **`.PHONY` declarations** for `install-binaries`, `build`, `test`, `bench`, `golden-capture`, `golden-diff`, and `install-compat-wrappers` ensure these targets always run regardless of whether a same-named file or directory exists in the repo root.

Shim contents (committed once in Phase 0). Two distinct templates are used — see Prerequisites for the full side-by-side spec; the bodies are repeated here for cross-reference.

**Template A — generic shim, applied verbatim at the seven `bin/<name>` paths:**

```bash
#!/usr/bin/env bash
# cerberus-shim v1 — DO NOT EDIT; replaced only by /plugin update.
target="$(dirname "${BASH_SOURCE[0]}")/../dist/$(basename "$0")"
if [ ! -x "$target" ]; then
  echo "cerberus: missing or non-executable $target — run 'make install-binaries' (see README)" >&2
  exit 127
fi
exec "$target" "$@"
```

**Template B — Amp shim, applied ONLY at `.amp/toolbox/cerberus.sh`:**

```bash
#!/usr/bin/env bash
# cerberus-shim v1 (Amp)
target="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/dist/cerberus-amp-toolbox"
if [ ! -x "$target" ]; then
  echo "cerberus: missing or non-executable $target — run 'make install-binaries' (see README)" >&2
  exit 127
fi
exec "$target" "$@"
```

The Amp shim cannot reuse Template A: (1) `.amp/toolbox/../dist/...` resolves to `.amp/dist/...` rather than the repo-root `dist/`, so the shim must walk up two levels (`../..`) and use `cd -- ... && pwd` to canonicalize the repo root; (2) the dist artifact is named `dist/cerberus-amp-toolbox`, not `dist/cerberus.sh`, so the artifact path is hard-coded rather than derived from `basename "$0"`. The cmd's build target keeps its `cerberus-amp-toolbox` name in `GO_CMDS` (Makefile above) and `docs/AMP.md` notes that the shim filename keeps `.sh` while the dist artifact does not.

Behavior on a fresh install before the first build: the shim's `[ ! -x "$target" ]` check fires, the user sees a one-line stderr message pointing to `make install-binaries`, and the shim exits 127. This is more actionable than `exec`'s default "No such file or directory" message.

A user installing via `/plugin install cerberus`:
1. The marketplace clone places the repo at `${CLAUDE_PLUGIN_ROOT}` (or `<CERBERUS_INSTALL_ROOT>` on Codex). The committed shims are present; `dist/` does not yet exist.
2. The user runs `make install-binaries` once (documented as a post-install step in README). See OQ-A — recommendation is to ship this as a one-step `make install-binaries` after `/plugin install cerberus` in the README install section.
3. `bin/update-plugin` (still bash) runs `git pull` and then `make install-binaries`. The pull is safe because the build never overwrites tracked files. The build is staged into the sibling directory `dist.new/` (at the repo root, NOT inside `dist/`) and atomically swapped into place; if the rebuild fails, the previous `dist/` remains in place untouched and a loud error is printed (no silent regression). Pull-then-build-then-swap is the chosen ordering — see OQ-B.
4. **`bin/update-plugin` never touches the `bin/<name>` shims.** It modifies only `dist/`. The shims are stable across all phases and across all updates.
4. A fresh `/plugin install` produces working binaries by running `make install-binaries` as a documented step. Pre-built per-OS-arch binaries are explicitly **out of scope** (decided: source distribution); follow-up may add `goreleaser` if marketplace install ergonomics demand it.

### Data Model

- **`gate-state.json`**: schema preserved verbatim. `internal/state.Gate` struct uses explicit `json:"name"` tags matching every existing key. Serialization uses `jsonutil.MarshalStable` (called from a custom `MarshalJSON`) to enforce the same key order bash currently emits via `jq`. Goldens diff this.
- **`iteration-N/` directories**: same on-disk layout (`reviewers/<agent>/draft.md`, `reviewers/<agent>/telemetry.json`, `reviewers/<agent>/raw.{json,jsonl,txt}`, `report.md`).
- **Per-reviewer telemetry JSON**: shape produced by `extract_*_telemetry` in `bin/telemetry-lib.sh:161–354`. `internal/telemetry.AgentTelemetry` is the Go side; table-driven tests against the 26 JSON fixtures in `bin/tests/fixtures/` (including `claude-output*.json`, `codex-output.jsonl`, `gemini-output*.txt`).
- **Hook stdin payloads**: shapes from existing fixtures (`claude-output*.json`, `codex-output.jsonl`). Go decoders use the same `json:"…"` tags; goldens for hook stdout diff each phase.
- **Debate artifacts**: `aggregate.json`, per-round outputs, anonymized peer blocks, partial debate telemetry, and `gate-state.json.debate` remain schema-compatible.
- **Iteration state**: `load_iteration`, `save_iteration`, and `get_iteration_dir` behavior moves to `internal/state`.
- **Host/session registry artifacts** created by Codex session init remain path- and schema-compatible with current tests.
- **No new persisted state backend** is introduced.

### API/Interface Design

- **CLI surface (unchanged)**: every existing subcommand keeps its name, flag set, exit codes. `bin/review-gate` preserves all subcommands: `check`, `spawn`, `spawn-code-review`, `spawn-plan-review`, `spawn-spec-review`, `spawn-epic-verify`, `spawn-ask`, `wait`, `resolve`, `artifact-path`, `author-context`, `status`. Flags include `--mode {fast,smart,max}`, `--debate`, `--agents`, `--max-rounds`, `--consensus`, `--context-file`, `--type`, `--session-id`, transcript/run-key options. Exit codes documented in `bin/review-gate:1–11`, `README.md:304–321` (debate codes 5, 6-preflight, 6-mid-debate, 130), and `README.md:458–464` (review-gate codes 0–4).
- **`bin/generate`**: preserves existing actions for healthcheck, architecture review, create-spec, create-plan.
- **Hook contract**: stdin/stdout JSON shape unchanged for Stop / TaskCompleted / TeammateIdle / SessionStart hooks across all four hosts. Test fixtures in `bin/tests/fixtures/claude-output*.json` and `codex-output.jsonl` define the input shape.
- **Amp adapter**: preserves `TOOLBOX_ACTION`, JSON stdin, JSON stdout, and six commands: `review-code`, `review-plan`, `review-spec`, `ask-panel`, `status`, `clear-gate`.
- **Env contract**: `CERBERUS_*` + legacy aliases per `README.md:478–491`. The "single warning per process when alias and canonical disagree" semantics (currently a `$$`-keyed marker file in `__cerberus_resolve_run_key`) become a `sync.Once` per process in `internal/cerberusenv`. Goldens cover the warning text.
- **External reviewer contracts**: remain CLI-based. Go does not introduce API keys, SDK clients, or new network calls.
- **Library surface (Go)**: all packages are `internal/`. No `pkg/` exposure planned for this port. External tooling that wants to read `gate-state.json` does so as JSON; the schema is the contract.

### File Impact Summary

| Path | Status | Description |
|------|--------|-------------|
| `go.mod` | **New** (Phase 0) | Module manifest, `github.com/charlieyou/cerberus`, Go 1.25 |
| `go.sum` | **New** (Phase 0) | Module checksums |
| `Makefile` | **New** (Phase 0) | Per-cmd build rules into `dist.new/<name>` (sibling of `dist/` at repo root) + atomic swap to `dist/`; targets `build`, `test`, `bench`, `golden-capture`, `golden-diff`, `install-binaries` |
| `.gitignore` | **Modify** (Phase 0) | Add `/dist*/` (single pattern covers `dist/`, `dist.new/`, and the transient `dist.old/` swap directory) |
| `dist/` | **New** (Phase 0; gitignored) | Generated Go build output directory; never touched by `git` operations or by the `bin/<name>` shims |
| `.github/workflows/test.yml` | **New** (Phase 0) | CI: Linux + macOS, Go 1.25, build + Go tests + bash acceptance + golden diff |
| `cmd/review-gate/main.go` | **New** (Phase 1) | Subcommand dispatcher; bridges to `bash bin/review-gate-debate-bridge.sh` until Phase 3 |
| `cmd/generate/main.go` | **New** (Phase 2) | Multi-model generator |
| `cmd/cerberus-task-completed-hook/main.go` | **New** (Phase 2) | TaskCompleted hook |
| `cmd/cerberus-teammate-idle-hook/main.go` | **New** (Phase 2) | TeammateIdle hook |
| `cmd/claude-session-init/main.go` | **New** (Phase 2) | Claude SessionStart |
| `cmd/codex-session-init/main.go` | **New** (Phase 2) | Codex SessionStart |
| `cmd/codex-stop-hook/main.go` | **New** (Phase 2) | Codex Stop hook |
| `cmd/cerberus-amp-toolbox/main.go` | **New** (Phase 3) | Build artifact lands at `.amp/toolbox/cerberus.sh` |
| `internal/cerberusenv/*.go` | **New** (Phase 0) | Env contract + alias resolution + `sync.Once` warning |
| `internal/jsonutil/*.go` | **New** (Phase 0) | Ordered marshal, paths(), repair |
| `internal/procgroup/*.go` | **New** (Phase 0) | `Detach()` (Setsid, reviewer subprocesses, both Linux + Darwin) + `Supervise()` (Setpgid, bridged bash debate coordinator) helpers (Unix build tags) |
| `internal/state/*.go` | **New** (Phase 0 skel → Phase 1 complete) | gate-state.json + flock + atomic write |
| `internal/telemetry/*.go` | **New** (Phase 0 skel → Phase 2 complete) | Extractors + iteration lifecycle |
| `internal/reviewers/*.go` | **New** (Phase 1) | Argv assembly + invocation |
| `internal/prompts/*.go` | **New** (Phase 1) | Markdown template loader |
| `internal/host/*.go` | **New** (Phase 1) | Per-host adapter glue |
| `internal/hooks/*.go` | **New** (Phase 2) | Hook stdin/stdout adapters |
| `internal/generator/*.go` | **New** (Phase 2) | Generator orchestration |
| `internal/debate/*.go` | **New** (Phase 3) | Round loop + anonymization + aggregation |
| `internal/ampbridge/*.go` | **New** (Phase 3) | TOOLBOX_ACTION dispatch |
| `internal/*/*_test.go` | **New** (each phase) | Go unit tests, table-driven |
| `bin/tests/fixtures/golden/` | **New** (Phase 0) | 24-cell golden matrix |
| `bin/tests/capture-goldens.sh` | **New** (Phase 0) | Capture driver |
| `bin/tests/run-all.sh` | **New** (Phase 0) | Stable CI runner for existing bash acceptance tests |
| `bin/review-gate` (shim) | **New** (Phase 0) | 3-line bash shim, committed to git, stable across all phases; execs `dist/review-gate` |
| `bin/generate` (shim) | **New** (Phase 0) | 3-line bash shim, committed to git, stable across all phases; execs `dist/generate` |
| `bin/cerberus-task-completed-hook` (shim) | **New** (Phase 0) | 3-line bash shim, committed to git, stable across all phases; execs `dist/cerberus-task-completed-hook` |
| `bin/cerberus-teammate-idle-hook` (shim) | **New** (Phase 0) | 3-line bash shim, committed to git, stable across all phases; execs `dist/cerberus-teammate-idle-hook` |
| `bin/claude-session-init` (shim) | **New** (Phase 0) | 3-line bash shim, committed to git, stable across all phases; execs `dist/claude-session-init` |
| `bin/codex-session-init` (shim) | **New** (Phase 0) | 3-line bash shim, committed to git, stable across all phases; execs `dist/codex-session-init` |
| `bin/codex-stop-hook` (shim) | **New** (Phase 0) | 3-line bash shim, committed to git, stable across all phases; execs `dist/codex-stop-hook` |
| `.amp/toolbox/cerberus.sh` (shim) | **New** (Phase 0) | Amp-specific shim contents (see Prerequisites > Template B); resolves the repo root via `cd -- "$(dirname ...)/../.." && pwd` (two levels up, not one) and hard-codes `dist/cerberus-amp-toolbox` (NOT derived from `basename "$0"`). Committed to git, stable across all phases; execs `dist/cerberus-amp-toolbox` (Phase 3 onward); shim itself replaces the existing 564-LOC dispatcher in Phase 0. Do NOT apply Template A here. |
| `bin/review-gate.bash-prod` | **Rename in Phase 0; Delete in Phase 1** | The legacy 5767-LOC bash production script, moved aside so the shim can take the canonical path while bash logic remains git-tracked |
| `bin/generate.bash-prod` | **Rename in Phase 0; Delete in Phase 2** | Legacy 768-LOC bash, kept until ported |
| `bin/cerberus-task-completed-hook.bash-prod` | **Rename in Phase 0; Delete in Phase 2** | Legacy 558-LOC bash, kept until ported |
| `bin/cerberus-teammate-idle-hook.bash-prod` | **Rename in Phase 0; Delete in Phase 2** | Legacy 198-LOC bash, kept until ported |
| `bin/claude-session-init.bash-prod` | **Rename in Phase 0; Delete in Phase 2** | Legacy 25-LOC bash, kept until ported |
| `bin/codex-session-init.bash-prod` | **Rename in Phase 0; Delete in Phase 2** | Legacy 196-LOC bash, kept until ported |
| `bin/codex-stop-hook.bash-prod` | **Rename in Phase 0; Delete in Phase 2** | Legacy 598-LOC bash, kept until ported |
| `bin/update-plugin` | Exists → **Edit (Phase 0, minor); out of scope: stays bash** | Adds `make install-binaries` after pull; modifies only `dist/`, never the `bin/<name>` shims; otherwise unchanged |
| `bin/review-gate-lib.sh` | Exists → **Delete (Phase 4)** | Logic in `internal/state` + `internal/cerberusenv` |
| `bin/review-gate-models.sh` | Exists → **Delete (Phase 4)** | Logic in `internal/reviewers` |
| `bin/review-gate-hook.sh` | Exists → **Delete (Phase 4)** | Logic in `cmd/review-gate` `check` subcommand |
| `bin/review-gate-debate.sh` | Exists → **Delete (Phase 4)** | Defines functions only (no top-level `main` invocation); sourced by `bin/review-gate-debate-bridge.sh` through Phase 2; logic ports to `internal/debate` in Phase 3 |
| `bin/review-gate-debate-bridge.sh` | **New (Phase 0)** | Bash bridge wrapper sourced by the bash debate libs and invoked by Go `review-gate --debate` during Phases 1–2; deleted in Phase 3 when `internal/debate` is wired in. Contents: `set -euo pipefail`; resolves `SCRIPT_DIR`; sources `review-gate-lib.sh`, `telemetry-lib.sh`, `review-gate-models.sh`, `review-gate-debate.sh`; calls `run_debate_coordinator "$@"`. |
| `bin/telemetry-lib.sh` | Exists → **Delete (Phase 4)** | Logic in `internal/telemetry` |
| `dist/cerberus-amp-toolbox` (or `dist/cerberus.sh`) | **New** (Phase 3, gitignored) | Go build artifact for the Amp Toolbox; the committed shim at `.amp/toolbox/cerberus.sh` execs this binary; filename of the shim keeps `.sh` per the existing decision |
| `dist/<name>` compat-wrapper | **Transient, generated by `make install-binaries`, never committed (Phase 0–N)** | 4-line bash wrapper that delegates to `bin/<name>.bash-prod` (or `.amp/toolbox/cerberus.sh.bash-prod` for the Amp dispatcher); generated by the prerequisite-less `dist.new/%` rule when `cmd/<name>/main.go` does not yet exist; replaced by a real Go binary when `cmd/<name>/main.go` lands. Detection sentinel: line 2 reads `# cerberus dist compat-wrapper v1` (or `# cerberus dist compat-wrapper v1 (Amp)` for the Amp variant). |
| `bin/tests/test-*.sh` (external surface) | Exists → **Preserve** | Acceptance harness through Phase 3 |
| `bin/tests/test-bash3-agent-parsing.sh`, `test-content-extraction.sh`, `test-iso8601-to-epoch.sh` (internal helpers) | Exists → **Delete (Phase 4)** | Replaced by Go unit tests in matching package |
| `bin/tests/fixtures/*` | Exists | Preserved + extended by `golden/` |
| `hooks/hooks.json` | Exists | **No change** |
| `templates/codex-hooks.json` | Exists | **No change** |
| `commands/*.md`, `skills/*/SKILL.md` | Exists | **No change** |
| `prompts/*.md` | Exists | **No change** |
| `README.md` | Exists → **Edit (Phase 4)** | Prereq table: drop `jq`/`python3`/`setsid`/`gtimeout`/`flock(1)`; add Go 1.25 |
| `docs/AMP.md` | Exists → **Edit (Phase 3)** | Document the `.sh` filename on a binary |
| `docs/CODEX.md` | Exists | **No substantive change** (smoke section may grow) |

## Risks, Edge Cases & Breaking Changes

### Edge Cases & Failure Modes

- **Cross-runtime `flock` interop during Phase 1–2.** Go (`gofrs/flock`) and bash (`flock(1)`) must lock the same advisory range on the same path. Linux uses `fcntl(F_SETLK)`; Darwin uses `flock(2)`. Risk: a path-mismatch bug (e.g. realpath vs symlink path) silently breaks mutual exclusion. **Mitigation**: a Go integration test that spawns `flock(1) /path/to/gate-state.json sleep 5 &` from the Go test, then asserts `flock.Lock()` blocks until the bash child exits. Run on both Linux and macOS in CI. Path normalization centralized in `internal/state`.
- **Lock deadlock at debate bridge.** Go must release locks before invoking the bash debate coordinator; bash coordinator acquires locks around its own mutations. **Mitigation**: a single architectural rule enforced via `state.WithFileLock` scoping; integration test that runs `review-gate --debate` end-to-end and asserts no lock is held across the `exec`.
- **Reviewer subprocess detach on macOS.** macOS doesn't ship a `setsid` binary; bash currently degrades. Go calls `syscall.SysProcAttr{Setsid: true}` on **both Linux and Darwin** (Go's `syscall` invokes `setsid(2)` directly on macOS — no `setsid` binary needed; symmetric across platforms; matches bash `setsid` semantics; child detaches into its own session and survives parent exit + controlling-terminal SIGHUP). **Risk**: any test asserting the literal `setsid` invocation breaks; reviewer subprocesses might receive interrupt signals meant for the parent. **Mitigation**: search bash tests for `setsid` literals (`bin/tests/test-debate-end-to-end.sh`, `test-debate-byte-parity.sh`) and adjust assertions to inspect process-group state via `ps -o pgid`. Phase 0 integration test on macOS verifies reviewer survives parent SIGHUP.
- **JSON key ordering and run-to-run nondeterminism across `encoding/json`.** Stdlib `json.Marshal` does **NOT** preserve struct/map key order matching `jq` output: it sorts map keys alphabetically and emits struct fields in declaration order, which may not match the order bash + `jq` currently emits. Separately, the bash output contains timestamps (`date -u +%FT%TZ`), PIDs (the `$$`-keyed marker path, reviewer subprocesses), random IDs, and `${TMPDIR}` paths that vary run-to-run. **Risk**: `gate-state.json` byte diff that breaks every golden test, either from key reordering or from clock/PID/UUID drift. **Mitigation**: every persisted struct (`Gate`, `AgentTelemetry`, etc.) implements `MarshalJSON` via `internal/jsonutil.MarshalStable` with an explicit key order matching the captured golden output; nondeterministic values are masked by the **Golden fixture normalization** layer (`internal/jsonutil.Canonicalize`) applied identically to both sides — see Testing & Validation Strategy. Alternative considered (and ready as a fallback) is `tidwall/sjson` for surgical patching, or an `OrderedObject` ordered-map type in `internal/jsonutil`. Avoid `map[string]any` for persisted state — always use typed structs.
- **`jq` filter parity.** ~hundreds of `jq` invocations across bash. Most are simple selectors (`.foo.bar`, `.[] | select(...)`) and port cleanly. A few use `paths(scalars)`, conditional updates, recursive descent. **Mitigation**: `internal/jsonutil` ports the specific operators bash uses; per-call decision documented in code comments referencing the original bash line; goldens catch drift. (See OQ-B.)
- **`python3` JSON-repair callsites.** `bin/review-gate-lib.sh` and `bin/telemetry-lib.sh` shell to `python3 -c '…'` for lenient parse. **Mitigation**: identify callsites in Phase 0; reimplement in `internal/jsonutil.Repair` with the same input/output shape; test against captured malformed inputs.
- **iso8601 parse parity.** `iso8601_to_epoch` (`bin/review-gate-lib.sh:175–212`) shells to `gdate`/`date -u`. Go's `time.Parse(time.RFC3339, …)` accepts the standard subset; **risk**: bash accepts a more lenient set (no `T`, missing `Z`). **Mitigation**: port `test-iso8601-to-epoch.sh` (44 LOC) to Go and extend with edge cases; if Go strictness diverges, fall back to a regex-driven parser in `internal/jsonutil`.
- **CI build cost on every PR.** 8 binaries × ~10s cold ≈ 80s. With macOS being slower, expect ~120s. **Mitigation**: `actions/setup-go@v5` cache for modules + build cache; build all binaries in a single `go build ./cmd/...` invocation that shares the build cache.
- **Bash debate bridge env-var leakage.** During Phase 1–2 the Go binary execs bash; if any `CERBERUS_*` or `REVIEW_GATE_*` var fails to export, debate behavior diverges silently. Conversely, if reviewer API key vars (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`) leak unexpectedly into bash subprocess, behavior may differ. **Mitigation**: `cerberusenv.ExportNeutralEnv` is the single source of truth; a Phase 1 integration test execs `bash -c 'env | grep -E "^(CERBERUS|REVIEW_GATE|CLAUDE)_"'` from Go and asserts the expected set. Audit which API keys bash currently inherits and pass through deliberately. (See OQ-D.)
- **Marketplace install build-step UX.** Source-distribution requires the user to run `make install-binaries` post-install (or for the host's plugin protocol to provide an install hook in a future iteration). **Risk**: fresh installs land with executable shims that point at a missing `dist/<name>`. **Mitigation**: the committed `bin/<name>` shim explicitly checks `[ ! -x "$target" ]` and prints a one-line stderr message naming `make install-binaries` before exiting 127, so a fresh-install failure mode is loud and self-explanatory rather than silent or cryptic. CI verifies `test -x` both for every canonical shim and for every produced `dist/<name>`. See OQ-A (resolved).
- **Stop-hook stdout/stderr discipline.** Hooks must not leak chatter to the host's stop-hook channel. Bash uses `>&2`, `2>/dev/null`, etc. **Mitigation**: a single `internal/host.Logger` that defaults to `io.Discard` for non-error messages and writes structured JSON to stderr only when `CERBERUS_DEBUG=1`.
- **Process leak under SIGINT.** Bash installs ERR/EXIT traps to clean marker files (`bin/review-gate:201, 3090, 4659`). **Mitigation**: Go uses `defer os.Remove(markerPath)` plus a signal handler that `select`-receives `SIGINT`/`SIGTERM` and runs cleanup before exit.
- **Debate fewer-than-two-reviewers behavior**: preflight and mid-debate degraded paths must preserve exit code `6` and exact state transitions.
- **Debate cancellation**: SIGINT must preserve exit `130`, partial telemetry behavior, and pending state semantics.
- **Aggregator failure**: malformed repaired JSON must preserve exit `5`, empty `reviews/`, and pending state behavior.
- **Hook timeout behavior**: TaskCompleted keeps 2100s budget; TeammateIdle keeps 10s budget; Codex Stop wait knob semantics remain unchanged.
- **Cleanup phase races with in-flight reviewers.** Phase 4 deletes bash libs; if a long-running debate child started under bash is still alive when libs are deleted, it might `source` a missing file on retry. **Mitigation**: Phase 4 ships only after Phase 3 has been live for a full release cycle and the bash debate coordinator is no longer invoked.
- **`gtimeout` exit-code mapping**: `context.DeadlineExceeded` must map to exit `124` if any test asserts that specific code.
- **Shim/dist drift.** If a user (or an out-of-band install script) copies a Go binary directly to `bin/<name>`, overwriting the shim, that user ends up with a stale binary that `update-plugin` cannot refresh — the build writes to `dist/<name>` but the canonical path now points at a frozen artifact. The shim's `cerberus-shim v1` sentinel comment in line 2 is the detection hook: `bin/update-plugin` runs `grep -q '^# cerberus-shim v1' bin/<name>` for each canonical shim before invoking the build, and refuses to proceed (with a loud error pointing the user at `git restore bin/<name>` and `make install-binaries`) if any shim has been replaced by a binary or by an edited script. Same check covers `.amp/toolbox/cerberus.sh`.
- **Update-plugin rebuild-failure UX.** `git pull` deletes ported `.bash-prod` files; rebuild failure post-pull leaves canonical shims pointing at compat-wrappers that delegate to deleted bash scripts. Mitigation: pre-pull Go-toolchain guard + post-pull rebuild-rc check with explicit recovery message; documented in Prerequisites > update-plugin.
- **Pattern-rule precedence assumption (Go-build rule vs compat-wrapper rule).** The Distribution mechanic Makefile uses two `dist.new/%` pattern rules: a Go-build rule with prerequisites (`cmd/%/main.go $(GO_SOURCES)`) and a prerequisite-less compat-wrapper rule. GNU Make's documented precedence prefers the rule with prerequisites when its prerequisites exist; the compat-wrapper rule is meant to fire only when `cmd/<name>/main.go` does NOT exist. **Risk**: Make 3.81 (macOS default) precedence behavior could differ from GNU Make 4.x in some edge case, causing the compat-wrapper rule to fire even when a Go `cmd/<name>` is present — silently masking a Go-side build failure with a stale bash-delegating wrapper. **Mitigation**: a CI assertion that runs `make install-binaries` after Phase 1+ ships, then greps each `dist/<name>` for the magic string `cerberus dist compat-wrapper v1` and asserts NONE match for binaries whose phase has shipped (i.e. all such artifacts are real Go binaries). The assertion is incremental: in Phase 1 it covers `dist/review-gate`; in Phase 2 it covers the six lifecycle/generator binaries; in Phase 3 it covers `dist/cerberus-amp-toolbox` and effectively the entire `GO_CMDS` list. If precedence ever inverts, this assertion fails loudly at CI time rather than silently shipping the wrong artifact.

### Breaking Changes & Compatibility

- **None intended for end users.** CLI surface, hook config, env contract, and on-disk artifacts are byte-stable.
- **Implicit packaging change**: shipping source + `go build` adds a Go 1.25 toolchain prereq. README updated in Phase 4. Users on a host without Go fail at `make install-binaries` with a clear error rather than at runtime.
- **Implicit dependency change**: install tooling that does not run `make install-binaries` will produce fresh installs where the committed shims at canonical paths are present and executable but the underlying `dist/<name>` artifacts are missing; the shim then exits 127 with a one-line stderr message pointing at `make install-binaries` rather than producing a confusing failure. Phase 0 packaging prerequisite blocks hard cutover until install-time build is confirmed.
- **Byte-level JSON changes** could break strict consumers of `gate-state.json` or telemetry — golden fixtures are the gate.
- **Removing bash debate files too early** would break `--debate` during transition — Phase 4 timing is the gate.
- **Mitigations**: hard cutover per phase enables `git revert` rollback. Each phase is an independently tagged release; downgrade = pin the prior tag. No `<name>.bash` fallback (decided). CI and local build target verify every canonical path is executable. Golden fixtures compare stdout/stderr, state, telemetry, prompt/schema artifacts, and reports. Phase 1/2 retain bash debate bridge.

## Testing & Validation Strategy

- **Phase 0 — Capture goldens.** `bin/tests/capture-goldens.sh` runs the unmodified bash production across 24 cells and stores stdout/stderr/exit/`gate-state.json`/iteration tree per cell under `bin/tests/fixtures/golden/{mode}/{path}/{kind}/`. Reviewer outputs are stubbed via the existing fixture-replay so capture is deterministic. Both the captured bash output and the Go-produced output are passed through `internal/jsonutil.Canonicalize` (see **Golden fixture normalization** below) before byte comparison so timestamps, PIDs, ephemeral paths, and random IDs do not produce noise.

#### Golden fixture normalization

Strict byte-equality across runs requires deterministic substitution of values that vary run-to-run (`date -u +%FT%TZ` timestamps, the `$$`-keyed warning marker file path, reviewer subprocess PIDs, temp-file paths under `${TMPDIR}`, random run/session/iteration IDs). The plan handles this with a single canonicalization layer applied identically to both sides:

- **Single canonicalization function.** `internal/jsonutil.Canonicalize(b []byte, opts CanonicalOpts) []byte` is applied **identically to the bash-captured golden and the Go-produced output** before byte comparison. Same code path on both sides means there is exactly one place to change normalization rules; drift between "what the golden was masked with" and "what the new run is masked with" is structurally impossible.
- **Field masks** with concrete JSON pointer / dotted-path patterns (maintained in `internal/jsonutil/canonical.go`):
  - `*.created_at`, `*.updated_at`, `*.resolved_at`, `*.iteration_*.started_at`, `*.iteration_*.ended_at` → replaced with literal `"<TIMESTAMP>"`.
  - `*.pid`, `*.coordinator_pid`, `*.reviewers.*.pid` → `<PID>`.
  - `*.run_id`, `*.session_id`, `*.iteration_id` → `<ID>` if random/UUID-shaped; preserved verbatim if they are deterministic from inputs (so input-derived identity is still tested).
  - Ephemeral paths under `${TMPDIR}/cerberus-*` and `dist.new/*` → path component replaced with `<TMP>`.
  - Any timing field (`elapsed_ms`, `wall_clock_seconds`, `latency_ms`) → `<MS>`.
- **Filesystem-side normalization.** Lines in stop-hook stdout/stderr or markdown gate report that contain an ISO-8601 timestamp, a PID, or a `${TMPDIR}` path are run through a sed-style allowlist (same patterns as the JSON masks) that replaces those tokens with the same placeholders. This keeps non-JSON artifacts under the same canonicalization contract.
- **Capture-time normalization is a separate helper.** `bin/tests/golden/normalize.sh` (or equivalent) wraps a real bash production run and writes the normalized output to `bin/tests/fixtures/golden/<cell>/canonical.json`. The Go test loads the same file and runs the same `Canonicalize` over its own output; the diff is byte-strict.
- **Drift detection.** When a golden legitimately needs updating (intentional behavior change), the dev runs `make refresh-goldens`, which re-runs bash production through the normalizer. The diff that lands in the PR is the **only** place the team approves new bash output as canonical — the normalization layer is **never** tweaked to silence a real diff.
- **Anti-pattern call-out.** Adding a new field mask to silence a diff requires a separate justification in the PR description **and** a new entry in the Decision Log. Masks are append-only and adversarially reviewed; a mask is acceptable only when the underlying value is genuinely nondeterministic and not part of the contract under test.
- **Per-package Go unit tests.** Table-driven; each package below must satisfy the relevant entries of the behavioral checklist in **Testing Constraints** (env precedence, state transitions, reviewer argv goldens, telemetry extractor parity, lock interop, JSON canonicalization, hook fixture replay, procgroup detach). `go test -cover` runs and the percentage is reported in CI as supporting evidence only — not a gate, because it can be gamed by tests that assert nothing.
  - `internal/cerberusenv`: env precedence, empty-as-unset behavior, host detection, alias conflict warning once per process, unsafe key rejection.
  - `internal/state`: review dir resolution, project hash fallback, gate load/save, active gate lookup, iteration save/load, atomic write, malformed JSON handling, N-writer flock contention.
  - `internal/telemetry`: Claude/Codex/Gemini extraction against existing `bin/tests/fixtures/*.json` and `codex-output.jsonl`.
  - `internal/reviewers`: command rendering for all reviewers and modes using fake CLIs; timeout and detach setup.
  - `internal/procgroup`: process-group creation on Linux/macOS, signal group handling where safe in CI; **Detach** (reviewer subprocess: Setsid on both platforms, survives-parent-exit integration test) and **Supervise** (bridged bash coordinator: Setpgid, `signal.Notify` forwarder delivers signals to child's pgid, exit-code propagation) integration tests.
  - `internal/debate`: preflight, abstain modes, degraded exits, anonymization, aggregation, dedup, cancellation, and exit codes.
  - `internal/hooks`: fixture-driven stdin/stdout/stderr/exit behavior for Claude, Codex, TaskCompleted, and TeammateIdle.
  - `internal/jsonutil`: stable key ordering and patch behavior for golden objects.
  - Run via `go test ./... -race -cover` in CI.
- **Acceptance via existing bash suite.** Every `bin/tests/test-*.sh` exercising external surface continues to run via `bin/tests/run-all.sh` in CI. Internal-helper tests (`test-bash3-agent-parsing.sh`, `test-content-extraction.sh`, `test-iso8601-to-epoch.sh`) get Go equivalents and the bash versions retire **only when** their target source is deleted in Phase 4.
- **Per-phase golden diff.** Each phase release-gate runs `make golden-diff` to byte-compare its in-scope cells against the captured Phase-0 baseline. Diffs fail the gate.
- **Phase 3 parity gate.** `test-debate-byte-parity.sh` (1018 LOC) is the toughest existing parity test; runs the Go debate coordinator and asserts byte-stable output. Cannot ship Phase 3 until green. Companion: `test-debate-end-to-end.sh`, `test-debate-anonymization.sh`, `test-debate-aggregation.sh`, `test-debate-per-reviewer-golden.sh`.
- **Hook integration tests.** `test-codex-stop-hook.sh`, `test-codex-session-registry.sh`, `test-cerberus-task-completed-hook.sh`, `test-review-gate-hook-timeout-budget.sh`, `test-host-neutral-state.sh` gate Phase 2.
- **Amp tests.** Preserve `test-amp-shell-helper.sh`; gate Phase 3.
- **Manual smoke per phase**, documented in `docs/CODEX.md` / `docs/AMP.md`:
  - Phase 1: Claude `Stop` hook on a real workspace; `wait --json` against a live debate (still bash via bridge).
  - Phase 2: Codex `Stop` hook + Codex SessionStart; TaskCompleted hook on an Amp team run.
  - Phase 3: Amp Toolbox round-trip (`/cerberus:review-code`, `/cerberus:status`, `/cerberus:clear-gate`).
  - Phase 4: full re-run of the matrix against the cleaned-up tree.
- **Cross-runtime concurrency tests.** Go `internal/state` test that spawns `flock(1)` against the same path and verifies mutual exclusion on Linux + macOS.
- **Performance bench.** `bench/` driver runs each binary's `--help` 100× cold and reports p50/p95. Warning-only initially; hard budget (`bash + 10ms`) enforced once baselines are stable.
- **Reviewer-CLI flag drift detection.** A unit test in `internal/reviewers` that asserts the rendered argv string for each `(agent, mode)` matches a checked-in golden. Catches accidental flag drift early.
- **Regression Tests.** Non-debate golden fixtures must stay byte-identical before and after debate port. Existing status, wait, resolve, artifact-path, author-context, and active-gate behavior must remain stable. Missing reviewer behavior remains warning/skip, with hard error only for debate fewer-than-two cases. Existing legacy env aliases continue working.
- **Monitoring / Observability.** Preserve existing log destinations and stderr diagnostics. Preserve telemetry summary output and per-reviewer telemetry files. During rollout, inspect lock acquisition failures, malformed JSON repair failures, reviewer timeout counts, and hook timeout exits. CI artifact upload includes golden diff output on failure.

### Acceptance Criteria Coverage

| AC | Approach |
|----|----------|
| AC #1: Same install paths (`bin/<name>`, `.amp/toolbox/cerberus.sh`) executable on all four hosts | Committed bash shims at the canonical paths exec into `dist/<name>`; `make install-binaries` produces the dist artifacts; CI verifies executable bit on both the shim and the dist binary, and runs hooks; manual host smoke per phase |
| AC #2 — `gate-state.json` and on-disk artifacts byte-identical **after `internal/jsonutil.Canonicalize` normalization is applied identically to bash-captured golden and Go-produced output**. Gated by 24-cell golden diff. Field-mask list maintained in `internal/jsonutil/canonical.go` and reviewed at every Decision Log update. | 24-cell golden diff per phase, with both sides canonicalized via `internal/jsonutil.Canonicalize` (timestamps, PIDs, ephemeral paths, random IDs, durations); per-package JSON ordering tests via `internal/jsonutil.MarshalStable`; ordered struct definitions; new field masks require Decision Log entry per the **Golden fixture normalization** anti-pattern rule |
| AC #3: `CERBERUS_*` env contract and legacy aliases preserved | Port `__cerberus_resolve_*` verbatim into `internal/cerberusenv`; alias-divergence warning gated by `sync.Once`; `cerberusenv` unit tests; `test-host-neutral-state.sh` |
| AC #4: All existing bash external-surface tests pass | `bin/tests/run-all.sh` is part of every per-phase release gate |
| AC #5: Each phase independently shippable and revertable | Tagged releases; `git revert` of phase commit + version pin for downgrade; no `<name>.bash` fallback needed |
| AC #6: Reviewer subprocess lifecycle preserved (detach, parent-exit-survival, ERR-trap cleanup) | `internal/procgroup` + signal handler tests; integration test that kills the parent and asserts the reviewer survives; fake-CLI argv goldens |
| AC #7: Debate coordinator byte-parity (canonical exit codes 5, 6 preflight, 6 mid-debate, 130) | `test-debate-byte-parity.sh` is the Phase 3 release-gate; `internal/debate` table-driven tests |
| AC #8: Cross-runtime `flock` interop holds during Phases 1–2 | Linux + macOS integration test pitting `gofrs/flock` against `flock(1)` |
| AC #9: Cold-start latency ≤ bash + 10ms | `bench/` driver + p95 budget |
| AC #10: Hooks stdin/stdout/exit semantics unchanged on all four hosts | Hook fixtures from `bin/tests/fixtures/` drive Go unit tests in `internal/hooks`; per-phase manual smoke |
| AC #11: Amp Toolbox actions read `TOOLBOX_ACTION` and JSON stdin and emit expected JSON stdout | `cmd/cerberus-amp-toolbox` + `internal/ampbridge`; `test-amp-shell-helper.sh`; manual Amp smoke |
| AC #12: Source distribution + Go 1.25 build/install produces binaries reachable via canonical shim paths, and `update-plugin` rebuilds them without dirtying the working tree | `Makefile` per-cmd build into `dist.new/<name>` (sibling of `dist/` at repo root) + atomic swap to `dist/`; committed `bin/<name>` shims exec the dist artifact; `bin/update-plugin` rebuild call writes only inside `dist*/` siblings; CI build verification |
| AC #13: Phase 4 cleanup leaves no runtime path sourcing deleted bash libraries | Phase 4 grep/CI check (`! grep -RIn 'review-gate-lib\\.sh\\|review-gate-models\\.sh\\|review-gate-debate\\.sh\\|review-gate-hook\\.sh\\|telemetry-lib\\.sh' bin/ .amp/`); external-surface tests after deletion |
| AC #14: Behavioral test checklist passes on every per-phase release gate (not coverage percentage) | The 10-class behavioral checklist in **Testing Constraints** is the load-bearing gate: (1) env precedence in `internal/cerberusenv`; (2) state machine transitions in `internal/state`; (3) reviewer argv goldens in `internal/reviewers`; (4) telemetry extractor parity in `internal/telemetry`; (5) cross-runtime flock interop test; (6) JSON canonicalization in `internal/jsonutil`; (7) 24-cell golden parity matrix; (8) hook fixture replay against `bin/tests/fixtures/`; (9) existing bash acceptance suite (`bin/tests/run-all.sh`, including `test-debate-byte-parity.sh`); (10) procgroup detach + supervise tests in `internal/procgroup`. `go test -cover` runs as supporting CI evidence only — no minimum-percentage gate, because line coverage is gameable. |

## Spec/Legacy Fidelity

No prior spec exists. The legacy artifacts that define the contract are:
- The bash code itself.
- `README.md` lines 9–565 (CLI surface, exit codes, env contract, install paths, host compatibility table).
- `hooks/hooks.json` and `templates/codex-hooks.json` (hook registration).
- `docs/CODEX.md` and `docs/AMP.md` (host adapter behavior).
- The 32-file bash test corpus and its 26-fixture set.

Each phase ends by re-reading these and asserting the Go binary still satisfies them. The plan preserves the legacy contract by keeping all public paths, env names, schemas, hooks, subcommands, flags, exit codes, timeout semantics, state layouts, and host adapter protocols unchanged. Internal implementation changes from bash to Go are not treated as contract deviations unless they change observable behavior.

### Deviation Log

| Source | Deviation | Rationale | Approved? |
|--------|-----------|-----------|-----------|
| `bin/review-gate-debate.sh` `setsid …` | Go uses `syscall.SysProcAttr{Setsid: true}` directly on **both Linux and Darwin** (Detach pattern in `internal/procgroup`); no `setsid` binary dep | Improved portability on stock macOS; symmetric across platforms; matches bash `setsid` semantics; `setsid` becomes a non-prereq | Yes (decided in Phase 2 batch 4; symmetry refined per Phase 1 plan-review P3) |
| Bash sole-process model on `--debate` | Phases 1–2 run with a Go parent and a bash debate-coordinator child (Supervise pattern: `cmd.Run()` + `Setpgid` + `signal.Notify` forwarder). `ps`/`pgrep` reports two processes during the bridge phases instead of one. Removed in Phase 3 when `internal/debate` lands. | Preserves Go-side cleanup invariants (`defer` runs, locks and marker files released) and gives Go a single signal-forwarding seam for SIGINT/SIGTERM/SIGHUP/SIGQUIT/SIGUSR1; `syscall.Exec` was rejected because it skips `defer`s and forfeits cleanup on signal | Yes (per Phase 1 plan-review P3 finding) |
| `bin/telemetry-lib.sh` `flock` | Go uses `github.com/gofrs/flock`; `flock(1)` becomes a non-prereq | Same `flock(2)` / `fcntl(F_SETLK)` semantics; idiomatic in Go | Yes (decided in Phase 2 batch 4) |
| `bin/*-lib.sh` `python3 -c '...'` JSON repair | Go reimplements in `internal/jsonutil.Repair`; `python3` becomes a non-prereq | One fewer host prereq; behavior captured by goldens | Yes (decided in Phase 2 batch 4) |
| `jq` filters | Most ported to `encoding/json` + `internal/jsonutil`; `jq` becomes a non-prereq | One fewer host prereq; goldens catch drift | Yes (decided in Phase 2 batch 1) |
| `gtimeout` / `timeout` | Replaced by `context.WithTimeout`; deadline → exit 124 mapping preserved | Stdlib idiom | Yes (decided in Phase 2 batch 4) |
| `bin/tests/test-bash3-agent-parsing.sh`, `test-content-extraction.sh`, `test-iso8601-to-epoch.sh` | Replaced by Go unit tests in matching package; bash versions deleted in Phase 4 | Internal helpers no longer exist; tests would test nothing | Yes (decided in Phase 2 batch 2) |
| `.amp/toolbox/cerberus.sh` filename | Filename keeps `.sh` extension on a binary | Toolbox protocol cares about executability + JSON stdio, not filename; documented in `docs/AMP.md` and Go header | Yes (decided in Phase 2 batch 3) |

## Open Questions

All P0/P1/P2 product/architecture decisions resolved (see Decision Log). Remaining items are scoped to implementation detail and resolvable during Phase 0/1 execution:

- **OQ-A — Marketplace install build-step UX.** *Resolved: `dist/` + permanent shims at `bin/<name>`* (see Decision Log row "Distribution mechanic" and Technical Design > Distribution mechanic). Compiled Go binaries land in gitignored `dist/<name>`; committed 3-line bash shims at `bin/<name>` and `.amp/toolbox/cerberus.sh` `exec` the dist artifact (or print a one-line stderr error pointing to `make install-binaries` if the artifact is missing). This replaces the previously-proposed `bin/build-on-demand` lazy-build wrapper, which is **removed** because it conflicts with the build-target-writes-to-canonical-path invariant elsewhere in the plan. The remaining concrete prereq is whether the marketplace install runs `make install-binaries` automatically or requires the user to run it; **recommend documenting in the README install section as a one-step `make install-binaries` after `/plugin install cerberus`**, with a follow-up to wire a host-provided post-install hook if/when the plugin protocol gains one.
- **OQ-B — `bin/update-plugin` interaction with the build step on rebuild failure.** Since `update-plugin` stays bash and pulls plugin updates, it must trigger a rebuild after pulling. *Proposed resolution*: pull-then-build-then-swap ordering. Build into a staging directory; if every binary compiles successfully, atomically replace canonical paths. If rebuild fails, leave previous binaries in place and print a loud error to stderr — no silent regression, no automatic rollback of the source pull (the user can `git reset` if needed). The single-line `make install-binaries` invocation lands in `bin/update-plugin` in Phase 0.
- **OQ-C — Reviewer-CLI argv exact-match.** `claude`/`codex`/`gemini` argv strings assembled by Go must match bash byte-for-byte (whitespace, `--` separator placement, quoted-arg policy). *Proposed resolution*: Phase 0 task captures per-`(agent, mode)` argv goldens from bash and checks them in; Go unit test in `internal/reviewers` asserts identity. Covered by golden tests.
- **OQ-D — Phase 1 bash bridge env audit.** Confirm the exact env-var set the bash debate coordinator currently relies on (`CERBERUS_*`, `REVIEW_GATE_*`, `CLAUDE_*`, plus possibly `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `PATH`, `HOME`, `TMPDIR`, `LANG`). *Proposed resolution*: Phase 1 task inserts `env | sort > /tmp/cerberus-debate-env-snapshot.txt` at the top of `bin/review-gate-debate.sh` (in a feature branch) on a real run, snapshots the set, then bakes the union into `cerberusenv.ExportNeutralEnv`. An integration test asserts the exact set passes through.
- **OQ-E — Codex/Amp host adapter regression coverage automation.** The existing manual smoke checks in `docs/CODEX.md` and `docs/AMP.md` are not automated. Phase 2/3 release gates remain manual smoke runs. *Proposed resolution*: keep manual in MVP; file a follow-up issue to automate them post-port using the same fixture-replay mechanism.
- **OQ-F — Pre-built binary distribution as a future option.** This plan distributes source-only. If marketplace install ergonomics demand it later, a follow-up could add `goreleaser` per OS-arch artifacts. Not a blocker.
- **OQ-G — `internal/jsonutil.PathsScalars` filter coverage.** Some `jq` filters need careful translation. *Proposed resolution*: Phase 0 inventory of all `jq` invocations; categorize as simple / `PathsScalars` / `Repair` / other. If "other" remains, decide per-call whether to keep shelling to `jq` (single deviation) or implement.
- **OQ-H — README documentation policy.** May `README.md` be updated to document the Go 1.25 build prerequisite, or must README remain byte-for-byte unchanged? *Proposed resolution*: README **may** be edited in Phase 4 to update the prereq table (drop `jq`/`python3`/`setsid`/`gtimeout`/`flock(1)`; add Go 1.25). Behavior contracts (env table at lines 478–491, exit code tables at 304–321 / 458–464, install-path references) remain unchanged.

## Next Steps

After this plan is approved, run `/cerberus:create-tasks` to generate execution artifacts:
- `--beads` → Create Beads issues with dependencies for multi-agent parallelization across phases.
- (default) → Generate `TODO.md` checklist for simpler tracking.
