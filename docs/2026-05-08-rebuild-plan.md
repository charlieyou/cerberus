# Implementation Plan: Cerberus v2 — Go Core, First-Class Debate, Multi-Instance Roster, Native Codex

**Spec:** `docs/2026-05-08-rebuild-spec.md` (Tier L; v2.0.0 milestone; sole maintainer charlieyou)
**Mode:** max (autonomous; `--no-questions` ⇒ `--skip-interview` semantics)
**Status:** Phase 2 complete (autonomous fills applied); generator augmentation pass adds D29–D45, pressure-tested hook bootstrap, anonymization algorithm, and concurrency / failure-mode edge cases.

---

## Context & Goals

- v2 is a clean Go rewrite of the v1 Bash plugin (~17 KLOC across 14 scripts under `bin/`).
- Spec-binding stance: simplification mandate. Drop v1's fault-tolerance accretions; ship simplest implementation that delivers the same user-visible functionality. Rebuild fault tolerance incrementally as real failure modes emerge.
- Four user-stated goals (verbatim): real-language maintainability, first-class debate, multi-instance / intra-provider model rosters, native Codex plugin support.
- Spec ships 13 surviving skills (run-team REMOVED per D6/D9), `--debate` opt-in (D2), Stop-hook gating, dual-host plugin packaging at version `2.0.0`.

## Scope & Non-Goals

### In Scope
- Single Go binary `bin/cerberus` subsuming the v1 review-gate, debate, models, generate, hook, session-init, skill-env, and telemetry libraries (R1, D1).
- YAML roster engine at `./.cerberus/rosters.yaml` and `~/.cerberus/rosters.yaml` with multi-instance / multi-version slots; CLI `--roster <name>` and `--reviewer ...` overrides; `<provider>#<index>` instance IDs (R2, D4, D12).
- Unified single-pass and `--debate` paths sharing aggregation, anonymization, and gate-state I/O in one Go module (R3).
- Codex CLI as first-class host; 13 surviving skills cross-host parity; SessionStart / UserPromptSubmit / Stop hook handlers in Go (R4).
- Per-reviewer reasoning strategy and persona injection from on-disk Markdown (R5).
- CI matrix (Claude × Codex × generic) × (darwin × linux) with mocked reviewer CLIs (R6).
- `CERBERUS_*` env contract; `CLAUDE_PLUGIN_ROOT` honored as fallback for `CERBERUS_ROOT` only (R7, C2).
- JSON telemetry under `<state_root>/<project>/<run>/iterations/<N>/` keyed on `reviewer_id = <provider>#<index>` (R8).
- Anonymization for debate; deterministic peer-N IDs; Gemini read-only policy applied to every Gemini child (R9, C5, C6).
- Dual plugin packaging: `.claude-plugin/plugin.json` + `hooks/hooks.json`; `.codex-plugin/plugin.json` + `hooks/codex-hooks.json`. Both at `2.0.0` (R10).
- Lazy local build via `make build`; missing-Go produces a one-line stderr error and non-zero exit (D5, C1).
- Deletion of run-team surface (skill, hooks, helpers, agent, template) (D6, D9).

### Out of Scope (Non-Goals)
- New artifact types, providers, hosts, gate states, prompt content (per spec §1).
- v1 → v2 state migration; v2 → v1 state downgrade (D11; users on v1 stay on v1 until explicit `/plugin update`).
- Strategy / mode rotation across rounds (D8).
- K* / αK telemetry, sparsification (Q14, Q15 — v2.x candidates).
- Pre-built binary distribution, GitHub Releases tarballs, signing/notarization (D3 alt rejected).
- Web UI / dashboard.
- **Concurrency primitives** — advisory locks, atomic-rename guarantees, read-only-install fallback for lazy build, gate-state.json file locks for concurrent runs in the same project (R1 + D29 explicit defer).
- JSON output repair, mid-debate degradation, hook fail-open, `REVIEW_GATE_*` env aliases, byte-parity with v1 telemetry consumers (simplification mandate).
- New tests for v1 quirks that v2 no longer exhibits (e.g., `iso8601_to_epoch` triple fallback, BSD-vs-GNU `mktemp` parity).
- `create-tasks --agent-team` output (depends on removed run-team templates and hooks; D41).
- Strategy / mode rotation across rounds, K* / αK telemetry, debate sparsification.

## Assumptions & Constraints

### Implementation Constraints
- Go ≥ 1.22 toolchain on the user's machine for `make build` / `go install` (D3).
- No Cgo. Cross-compilable to darwin-{amd64,arm64} and linux-{amd64,arm64} via plain `go build` (C3, S5).
- `prompts/**/*.md`, `config/gemini-readonly-policy.toml`, and `config/gemini-readonly-settings.json` remain on disk and are read at runtime (C4, C5).
- Reviewer subprocesses still shell out to upstream `claude`, `codex`, `gemini` CLIs. No HTTP/SDK calls (spec Non-Goals).
- Zero `bin/*.sh` files in the v2 plugin tree. Skill SKILL.md inline shell snippets and the inline hook bootstrap `command` are the only permitted shell text outside `bin/cerberus` (S3, R6 verification).
- Binary size budget: ≤ 30 MB stripped on darwin-arm64 (R1 edge case). Any increase recorded as an explicit decision.

### Testing Constraints
- Every new exported package under `internal/` has a `*_test.go` with at least one happy-path and one failure-path case.
- Integration tests under `tests/integration/` cover host-neutral state resolution, debate rounds, anonymization, multi-instance roster spawning, and persona/strategy injection (R6).
- Mock reviewer CLIs at `tests/mocks/{claude,codex,gemini}` are tiny Go programs; they replay frozen JSON fixtures from `tests/fixtures/` keyed on `(prompt_hash, instance_id)` so two slots with the same prompt but different models can produce distinct outputs (D31).
- Zero-bash structural lint in CI (R6 verification): `bin/` is allowlisted to contain only the build artifact `bin/cerberus` (gitignored per D32, so effectively empty in the repo at GA). Any other tracked file under `bin/` — extensioned (`*.sh`, `*.bash`) or extensionless (e.g., v1's `bin/review-gate`, `bin/codex-stop-hook`, `bin/cerberus-skill-env`) — fails the lint. A second compound check rejects any file under `bin/` whose first line begins with `#!` followed by `sh`, `bash`, `dash`, `zsh`, or `env (sh|bash|dash|zsh)`. See "make lint enforces" in the CI Matrix section for the canonical wording.
- `grep -RIl 'task-completed-hook\|teammate-idle-hook' .` returns empty inside `skills/`, `hooks/`, `agents/`, `bin/` (R1 verification).
- A binary-size assertion runs in CI: `test "$(stat -c%s bin/cerberus 2>/dev/null || stat -f%z bin/cerberus)" -le $((30*1024*1024))` after `go build -ldflags="-s -w"` on darwin-arm64 (D35).
- Hook bootstrap end-to-end test boots a fresh worktree (no `bin/cerberus`), invokes the hook command directly via `sh -c "$COMMAND"`, asserts the binary builds and the hook runs.

### Decision Log

Spec-binding decisions (D1–D13) are restated as authoritative inputs from `docs/2026-05-08-rebuild-spec.md` §1. New autonomous decisions (D14+) made during this Phase 2 pass are listed below.

| Decision | Rationale | Evidence | Tradeoff / Risk / Follow-up |
|----------|-----------|----------|------------------------------|
| **D14 — Go module layout: `cmd/cerberus` + `internal/{cli,orchestrator,roster,reviewer,host,hook,state,telemetry,prompts,generate,anonymize,aggregate,config}`** | Idiomatic Go: `cmd/<bin>` for the entry point, `internal/` for non-exported packages. Separating `aggregate` and `anonymize` into their own packages makes R3's grep test ("no other Go package DEFINES additional `Aggregate*`/`Anonymize*` symbols or writes `gate-state.json` directly") trivial to satisfy. Imports from `internal/orchestrator` and `*_test.go` are explicitly allowed and required. | Standard layout for Go projects since modules; `cerberus` is a single-binary tool so `cmd/cerberus/main.go` is the only entry. R3 verification text. | More import boundaries vs a flatter layout; acceptable given each package is small. Risk: scope creep adds a new top-level package; rule of thumb — if a new concept fits inside an existing package, do not create a new one. |
| **D15 — Roster YAML schema finalized (closes D12)** | Spec leaves the concrete YAML field set to plan. The schema below mirrors the R2 "schema seed" and adds the smallest set of optional fields needed to satisfy R5 (`strategy`, `persona`, `mode`) and the merge rules (`--reviewer` append + `--replace-slot`). | Spec R2 schema seed; spec D4 file locations; spec R5 per-slot overrides. | Adding `defaults:` and per-roster overrides invites schema growth; rule — each new optional field requires a Decision-Log entry. Risk: YAML parser strictness disagreement; mitigated by `yaml.v3`'s strict-mode `KnownFields(true)` for slot-level keys (D19). |
| **D16 — Telemetry JSON schema (closes R8 "schema defined in plan")** | R8 binds `reviewer_id = <provider>#<index>` and a separate `instance_index` field. Beyond that the v1 telemetry contract is explicitly NOT a v2 binding constraint per simplification mandate. The schema below is the smallest set of fields covering spec §4 instrumentation events. | Spec R8; spec §4 instrumentation event list; per-reviewer row example in spec §4. | v1 telemetry consumers (if any external) break — accepted per simplification mandate. Risk: external dashboards or scripts depending on v1 keys; mitigated by v1 plugin marketplace pin (D11). |
| **D17 — Hook bootstrap inline command pattern** | Hooks fire independently of skill invocation, so the lazy-build trigger must be reachable from the hook entry without a `bin/*.sh` file (S3). Inlining `sh -c '...'` in the manifest's `command` field places the lazy-build text inside the host's hook manifest — not a tracked `bin/*.sh` file. | Spec R1 edge case ("Hook bootstrap"); v1 `hooks/hooks.json` and `hooks/codex-hooks.json` already use `command` strings. | Inline shell is harder to read than a script; mitigated by keeping the command tiny (1 line) and committing the canonical strings into the plan as the source of truth. Risk: shell quoting bugs; covered by an integration test that boots each hook end-to-end. |
| **D18 — CLI dispatch: stdlib `flag` + manual subcommand switch (not cobra/urfave)** | The subcommand surface is ~12 commands with simple flag sets. `cobra` adds ~50 transitive dependencies and ~1 MB to the binary; `urfave/cli` adds ~10–15. Stdlib `flag` plus a `switch` covers the surface in <100 LOC and keeps the binary tiny. | Spec simplification mandate ("ship simplest implementation"); R1 binary-size budget (≤ 30 MB stripped on darwin-arm64). | Less ergonomic for nested flags / shell completion vs cobra. Risk: ad-hoc flag handling drifts; mitigated by a single helper in `internal/cli/` that registers each subcommand uniformly. |
| **D19 — YAML library: `gopkg.in/yaml.v3`** | Most-used Go YAML library, MIT, no Cgo, supports YAML 1.2 and strict-mode `KnownFields`. Stable since 2019. | Common in the Go ecosystem (Kubernetes, Helm, etc.); zero non-stdlib dependencies. | Single point of dependency; mitigated by pinning a specific minor version in `go.mod`. Risk: parser edge cases with multi-document YAML; not used in v2 (single-doc roster files). |
| **D20 — Build / staleness detection: `find cmd internal go.mod go.sum -newer bin/cerberus -print -quit`** | Spec R1 lazy-build text says "missing or older than `cmd/`, `internal/`, or `go.{mod,sum}`". `find -newer ... -print -quit` returns the first match and exits, taking single-digit ms on a typical tree. | Spec R1 lazy-build paragraph; v2 simplification mandate ("simplest implementation"). | False positives if a tooling step `touch`es source without changing it; harmless (one extra build). False negatives only if mtime is rewound — out of scope. Risk: clock skew across mounted filesystems; not a concern for a single-machine plugin. |
| **D21 — Test layout: `internal/<pkg>/*_test.go` + `tests/{integration,mocks,fixtures}`; v1 `bin/tests/` deleted** | Standard Go conventions: unit tests beside production code; integration / cross-package tests live outside `internal/` to avoid import cycles and to stay independently runnable. | Standard Go test placement; spec S3 (zero `bin/*.sh`) precludes keeping bash tests under `bin/tests/`. | None — v1 bash tests are not portable to v2 anyway. Risk: regression coverage gap during port; mitigated by R6 launch-checklist smoke tests on real CLIs at GA. |
| **D22 — Mock reviewer CLI: tiny Go program replaying fixture JSON keyed on prompt hash** | A mock CLI must be host-CLI compatible (read prompt from stdin or `--prompt`, write JSON to stdout). The simplest contract is `sha256(prompt) → tests/fixtures/<sha>.json`. Missing fixtures fail loudly with the prompt printed to stderr so the developer can capture a real run and check it in. | Spec R6 mocked CLI requirement; simplification mandate ("surface errors loudly"). | New fixtures must be regenerated when prompts change; mitigated by a `make fixtures-refresh` Make target that runs real CLIs and writes outputs. Risk: drift between mock fixtures and real CLI output; mitigated by GA smoke tests on real CLIs. |
| **D23 — Phasing: A skeleton → B single-pass → C debate → D generate → E codex parity → F cleanup → G CI/tests → H docs** | Each phase delivers a working intermediate state. Single-pass before debate because debate reuses the single-pass aggregator (R3 unification). Codex parity comes after the Claude path is solid because the Codex hook contract is less mature and benefits from a stable baseline. Cleanup and CI come last because they enforce structural invariants (zero-bash, structural lint) that block earlier in-progress states. | Dependency analysis from spec R1–R10. | Linear phase order vs interleaved development; risk of long-lived branches. Mitigated by keeping v1 in production until v2 is GA (D11). Phases are NOT a release schedule — v2.0.0 ships as a single cutover. |
| **D24 — Q7 plan-phase default — context overflow: log warning + proceed; reviewer CLI handles its own truncation** | Spec already pins this as the plan-phase default in §3 R5 and §4 risk analysis. Plan reaffirms; no new investigation. | Spec R5 edge cases; spec §4 risk analysis. | Truncation happens silently inside upstream CLIs; we lose ability to enforce hard limits. Risk: deterministic truncation differs between providers; documented as a known v2.0 limitation, revisited if it produces user-visible regressions. |
| **D25 — Skill SKILL.md bootstrap stays as inline shell in the markdown body (not a `bin/*.sh` file)** | Every SKILL.md already has a host-neutral inline bootstrap that resolves `CERBERUS_ROOT`. Updating the snippet's content (drop refs to `bin/review-gate-models.sh` and `bin/review-gate`; require `bin/cerberus`) does not introduce a `bin/*.sh` file. | Existing SKILL.md structure; spec S3 lint scope ("`find bin -name '*.sh'`"). | Each SKILL.md duplicates the snippet; mitigated by a single canonical version maintained in `prompts/host-neutral-bootstrap.md` referenced from the plan-phase patch. Risk: bootstrap drift across skills; covered by a per-skill SKILL.md lint in CI. |
| **D26 — `bin/update-plugin` removed in v2** | The script is a maintainer convenience for syncing the working repo into a local plugin install. It is bash (S3 violation if kept) and never invoked in the plugin user flow. The same operation is `make install` or a manual `cp -r` documented in `CONTRIBUTING.md`. | `bin/update-plugin` content (85 LOC, syncs files); spec S3. | Maintainer ergonomics regress slightly. Mitigation: `make install` target replicates the workflow; revisit if it becomes painful. |
| **D27 — `cerberus-skill-env` shell helper REMOVED from `bin/`; resolution lives in skill SKILL.md inline + Go binary self-resolution** | Two consumers: skill SKILL.md (which already has its own inline resolution) and the Go binary (which resolves env in `internal/config/`). Keeping the bash helper duplicates this logic and violates S3. | `bin/cerberus-skill-env` content (159 LOC, env resolution); R7 env contract; D25. | Breaking change for any external integration script that sourced this file directly. Mitigation: documented in v2 migration notes per D11. |
| **D28 — `templates/codex-hooks.json` legacy file DELETED in v2** | Duplicate of `hooks/codex-hooks.json`; spec R10 explicitly notes "may be removed in v2". | Spec R10 edge case. | None. |
| **D29 — No concurrency primitives in v2.0 GA** | Two simultaneous `cerberus spawn-code-review` runs in the same project may clobber each other's `gate-state.json` and reviewer outputs. v1 didn't reliably solve this either; v2.0 GA explicitly defers. Surfaces a one-line stderr warning when `gate-state.json` already exists in `pending` state at spawn time. | Simplification mandate; spec §1 explicit defer of advisory locks/atomic-rename. | Risk: rare but real for users juggling parallel reviews in one repo. Mitigation: README documents single-active-run guidance; revisit if friction emerges. |
| **D30 — Anonymization algorithm: deterministic peer-N IDs + free-text scrub of provider names + roster-loaded model names** | Spec R9 + C6 require provider/model identifier scrubbing. Algorithm: walk reviewers in instance-ID lexicographic order, assign `peer_1..peer_N`; in each peer's free-text fields (`findings[].evidence`, `findings[].recommendation`, `summary`, etc.), case-insensitive replace provider names (`claude`/`codex`/`gemini`) and roster-loaded model names with `peer_<self>` (when self-referential) or `peer_<other>` (when referencing another reviewer) or `<peer>` (when ambiguous). Self-referential phrases ("as I, claude, said") get the same treatment. JSON-structural fields (verdict, confidence, round, instance_id) are NOT scrubbed because they don't reach the round-2 prompt. | Spec R9; C6 anonymization mandate; debate.md sycophancy/identity-leak guidance. | Risk: model names that are common substrings of unrelated text (e.g., `claude_handler` identifier in code) get false-replaced. Acceptable; reviewer prompts are constrained domain. Falsifiability test in `internal/anonymize/anonymize_test.go`. |
| **D31 — Mock CLI fixture key includes instance ID** | Two slots with identical prompts but different models (e.g., debate's anonymized round-2 prompt is identical for all peers) need to return distinct verdicts. Key = `sha256(prompt) + ':' + instance_id` ensures fixture lookup is unique per slot. | Plan testing strategy; debate edge case (round-2 prompts can be near-identical across peers). | Slight fixture proliferation; manageable under `make fixtures-refresh`. |
| **D32 — `bin/cerberus` is a build artifact and is `.gitignore`d** | The binary is generated by `make build` per D5; committing it bloats history and conflicts with cross-platform CI builds. v1 tracked the bash files because they were source; v2's source is `cmd/` + `internal/`. | D5 lazy build; D14 module layout. | Users of `git clone` must run `make build` (or trigger lazy build via skill/hook). README documents. |
| **D33 — Roster duplicate-slot warning** | The system permits duplicate `(provider, model, strategy)` tuples (assigning separate instance IDs per R2 merge rule). However, exact duplicates are usually typos. Roster loader emits a single stderr warning per duplicate at preflight; does not refuse. | R2 merge rule + simplification (loud-but-not-fatal warnings for likely-mistakes). | Risk: false positive when user intends two instances. Acceptable; warning is not fatal. |
| **D34 — Build duration logged to stderr when lazy build triggers** | First hook invocation after a clean clone runs `make build`, which can take 10–30 s. Without a status line, the user sees an unexplained pause. Lazy-build script prints `cerberus: building... (this happens once after clone or upgrade)` to stderr before invoking `make`, and prints `cerberus: build complete in <N>s` after. | UX best practice; matches simplification mandate (loud, no surprises). | Trivial extra stderr noise. None. |
| **D35 — CI binary-size assertion: 30 MB stripped on darwin-arm64; 35 MB elsewhere** | Spec R1 sets a 30 MB cap on darwin-arm64; other GOOS/GOARCH combos run slightly larger. Hard fail in CI prevents accidental dependency bloat. | R1 edge case; D18 stdlib-flag rationale. | Risk: legitimate growth (e.g., embedded prompts) blocks a release. Process: bump cap in a Decision-Log row, reviewed at PR time. |
| **D36 — CLI `--reviewer` grammar is `provider:model[:strategy]`; persona and per-slot mode are YAML-only in v2.0** | Avoids colon-escaping and path ambiguity in shell CLI flags. R2 requires inline reviewer override but only YAML must express persona/mode. | R2 spec text; CLI ergonomics. | Less inline expressiveness; users needing persona/mode create a roster file. Acceptable. |
| **D37 — Hook commands read hook payload from stdin and do not rely on `"$@"` forwarding through `sh -c`** | Host hooks typically pass event data on stdin; `sh -c` argument forwarding is brittle, especially when shell quoting nests inside JSON. Go hook subcommands read `os.Stdin` directly and parse it as the host event payload. | Current hook manifests are command strings; v1 hooks consume host payloads on stdin. | Must verify Claude/Codex hook payload contracts in integration tests. The bootstrap `command` string still includes `"$@"` for any positional args the host injects, but Go hook code does not depend on them. |
| **D38 — Internal Stop hook wait default is 1800 s; manifest timeout stays 2100 s** | Preserves v1's outer host budget while giving the Go hook a 5-minute cleanup/logging buffer before host hard-kills the process. Internal `MAX_WAIT_SECONDS` matches spec §2 default. | Spec §2 key-state table (MAX_WAIT_SECONDS=1800); v1 `hooks/hooks.json` and `hooks/codex-hooks.json` Stop entries (`"timeout": 2100`). | Long blocking window remains; documented and tested. |
| **D39 — Built-in default roster degrades on missing CLIs; YAML rosters (including a YAML roster named `default`) reject missing CLIs** | Keeps the no-flag existing-user flow forgiving when a host lacks one provider, while treating any user-authored roster file as explicit configuration that must be honored or rejected loudly. | Spec D13 default-roster degradation; spec D13 custom-roster rejection. | A user-defined roster named `default` is stricter than the built-in default; documented in README. |
| **D40 — No embedded prompt fallback in v2.0 GA** | Keeps the binary small and makes the on-disk editability of `prompts/**/*.md` obvious. C4 allows embedding but requires disk to win when present. Disk-required is simpler. | C4 spec text; D18/D19 minimal-deps stance. | Installations missing prompt files fail loudly; embedding can return in v2.x if read-only-install environments emerge. |
| **D41 — `create-tasks --agent-team` output is removed alongside run-team** | The agent-team output mode depends on removed `templates/team-tasks-template.md` and the removed `cerberus-task-completed-hook` / `agents/implementer.md` cascade. Beads, Linear, and TODO-style outputs survive. | D6/D9 removal cascade; current `templates/team-tasks-template.md` exists only for run-team. | Breaks users of that option; documented in README. |
| **D42 — Preserve `--agents claude,codex,gemini` as a compatibility shorthand, but prefer rosters** | Existing skill markdown and v1 CLI expose `--agents`. Low-cost compatibility reduces friction for users on the v1→v2 transition. Mutually exclusive with `--roster` and `--reviewer`. | Current skills and README reference `--agents`; v1 `bin/review-gate` help text. | Cannot express multi-version models; the flag preflight rejects when paired with `--roster`/`--reviewer`. Long-term, drop this in v2.x once users migrate. |
| **D43 — Preserve `--consensus majority|all|any`; centralize aggregation in `internal/aggregate`** | Existing review workflows expose consensus modes from v1. Keeping the flag preserves current behavior; centralizing the implementation in one package satisfies R3's "single source of truth" grep test. | v1 `bin/review-gate` help and skill examples use `--consensus`. | Adds branching inside `internal/aggregate`; tests cover each mode (`majority`, `all`, `any`) with happy/failure paths. |
| **D44 — Preserve raw per-reviewer JSON verdict shape (`PASS`/`FAIL`/`NEEDS_WORK`); normalize internally** | Spec says per-reviewer JSON schema does not change. Raw verdicts continue to use v1 strings; `internal/aggregate` maps to gate-state verdicts (`pass`/`fail`/`requires_decision`) consistently. | v1 reviewer prompts emit `PASS`/`FAIL`/`NEEDS_WORK`; spec preserves the per-reviewer JSON. | Internal code must map raw verdicts consistently into gate and telemetry schemas; covered by unit tests in `internal/aggregate`. |
| **D45 — Default panel is `[claude, codex, gemini]` when no roster file or flags are present** | Restates the spec's R2/D13 baseline. Built-in default uses one slot per provider with each provider's default model resolved from `internal/config` defaults. | Spec R2 default panel; D13 degradation rule. | Default models drift over time; bumping them is a Decision-Log row in a future minor. |
| **D46 — Reviewer prompt delivered via stdin (not argv) to avoid `E2BIG`** | The composed user prompt (artifact diff + author-context + debate peer broadcast) routinely exceeds OS argv limits; macOS `getconf ARG_MAX` is often ~256 KB, which a code-review diff can blow past. Embedding the prompt in argv via `claude ... -- <user>` causes `exec` to fail with `E2BIG`. Stdin keeps prompts unbounded by argv limits, matches the conventional contract for `claude` and `codex`, and is provider-neutral. System prompts stay on argv (small, infrequently multi-line); fall back to `--system-prompt-file`-style flag if a provider rejects multi-line argv strings. Any provider that does not accept the user prompt on stdin (Phase B verifies, especially gemini) falls back to a temporary `<state_root>/.../reviewers/<instance_id>/prompt-stdin.md` file passed via `--prompt-file`. | Finding 1 from review pass (P1, codex); macOS `getconf ARG_MAX`; v1 invocation embedded prompt on argv and would have hit this limit at scale; OQ-Plan-1 already tracks Phase B flag confirmation. | Tradeoff: slight extra plumbing in `internal/reviewer` to wire `cmd.Stdin`. Risk: a provider CLI that consumes stdin for a different purpose (e.g., conversation transcript) would need the file-fallback path; Phase B integration tests confirm per-provider behavior. Falsifiability: the 256 KB+ round-trip integration test under "Test Layers" fails immediately if a provider regresses to argv-only. |
| **D47 — When `rosters.yaml` exists but defines no `default` roster, preflight errors instead of falling back to the built-in default** | The built-in default `[claude, codex, gemini]` (D45) degrades silently on missing CLIs (D39). A YAML roster file is explicit user configuration; selecting a non-existent name from it is a misconfiguration, not an opportunity to silently substitute different semantics. Erroring forces the user to either pass `--roster <name>` to pick an existing roster, or to remove `rosters.yaml` if they want the built-in default. This preserves D39's distinction (built-in degrades; YAML rejects) at the file-presence level: a present file is treated as authoritative. | Finding 2 from review pass (P2, claude); D39 built-in-vs-YAML distinction; D45 built-in default identity; spec R2 schema seed treats roster files as authoritative. | Tradeoff: marginally less forgiving than option (a) (silent fall-back). Risk: a user upgrading from a roster-less setup who creates a stub `rosters.yaml` without a `default` entry hits the error on first run; mitigation — error message names both remediations explicitly. |

## Integration Analysis

### Existing Mechanisms Considered

| Existing Mechanism | Could Serve Feature? | Decision | Rationale |
|--------------------|---------------------|----------|-----------|
| `bin/review-gate` (6,199 LOC bash, subcommands: check/spawn/spawn-{code,plan,spec,epic-verify,ask}-review/resolve/wait/status/completion-check/artifact-path/author-context) | No (bash) | **Replace** with `cmd/cerberus` Go entry + `internal/cli/` subcommand dispatch | D1 mandates zero `bin/*.sh`; one binary subsumes the v1 surface. Subcommands preserved 1:1 plus `hook` and `generate`. |
| `bin/review-gate-debate.sh` (3,183 LOC bash) | No (bash + duplicates state machine) | **Replace** with `internal/orchestrator/` extension; debate as a feature flag on the same orchestrator | R3 requires unified module; eliminates 3,183-line duplication. |
| `bin/review-gate-models.sh` (1,047 LOC bash, one-of-each `{CLAUDE,CODEX,GEMINI}_MODEL_EFFECTIVE`) | No (cannot express multi-instance) | **Replace** with `internal/roster/` YAML loader + slot resolver + instance ID assigner | R2/S2 require multi-instance and multi-version expressiveness; v1 model resolution is structurally incompatible. |
| `bin/review-gate-hook.sh` (Stop hook poll) | No (bash) | **Replace** with `cerberus hook claude-stop` (and `cerberus hook codex-stop`) | D5 + R1 hook bootstrap. |
| `bin/codex-stop-hook` (Codex Stop) | No (bash) | **Replace** with `cerberus hook codex-stop` | R4 cross-host parity. |
| `bin/codex-session-init`, `bin/claude-session-init` | No (bash) | **Replace** with `cerberus hook {claude,codex}-session-start` and `cerberus hook codex-prompt-submit` | R4. |
| `bin/cerberus-skill-env` (159 LOC bash) | No (bash; resolves CERBERUS_ROOT/HOST/RUN_KEY) | **Replace**: skill SKILL.md inline bootstrap finds `bin/cerberus`; the binary self-resolves env (R7) | S3 zero-bash; D27. |
| `bin/telemetry-lib.sh` (759 LOC) | No (bash) | **Replace** with `internal/telemetry/` | R8. |
| `bin/generate` (783 LOC bash) | No (bash) | **Replace** with `cerberus generate` subcommand | Used by create-spec/create-plan skills; D23. |
| `bin/cerberus-task-completed-hook` (548 LOC) | N/A | **Delete** | D6/D9. |
| `bin/cerberus-teammate-idle-hook` (197 LOC) | N/A | **Delete** | D6/D9. |
| `bin/update-plugin` (85 LOC bash) | No (bash) | **Replace or remove** — see D26 | Out of plugin user flow; ergonomic helper for the maintainer. |
| `bin/tests/` (36 bash test files + fixtures) | No (bash) | **Replace** with Go `*_test.go` (unit) + `tests/integration/` + `tests/fixtures/` | S3; R6. |
| `prompts/**/*.md` (generators, reviewers, revisions, strategies, interview-engine.md) | Yes | **Keep** (read at runtime) | C4. |
| `config/gemini-readonly-policy.toml`, `config/gemini-readonly-settings.json` | Yes | **Keep** | C5. |
| `skills/<surviving>/SKILL.md` (×13) | Partial | **Update** bootstrap snippet to reach `bin/cerberus` directly; remove references to `bin/review-gate-models.sh` and `bin/review-gate` from required-file checks | R1, R3, R4. |
| `skills/run-team/`, `agents/implementer.md`, `templates/team-tasks-template.md` | N/A | **Delete** | D9. |
| `templates/tasks-template.md` | Yes | **Keep** | D9. |
| `templates/codex-hooks.json` (legacy duplicate) | No | **Delete** in v2 | R10 explicitly notes "may be removed"; D28. |
| `hooks/hooks.json` (Claude SessionStart, Stop, TaskCompleted, TeammateIdle) | Partial | **Update**: remove TaskCompleted/TeammateIdle entries; rewrite SessionStart and Stop to use inline `sh -c` lazy-build bootstrap calling `bin/cerberus hook ...` | D9, D5, D17, R1 hook bootstrap. |
| `hooks/codex-hooks.json` (Codex SessionStart, UserPromptSubmit, Stop) | Partial | **Update**: rewrite all three to inline `sh -c` lazy-build bootstrap calling `bin/cerberus hook ...` | D5, D17, R4. |
| `.claude-plugin/plugin.json` | Yes | **Update**: version → `2.0.0` | R10. |
| `.codex-plugin/plugin.json` | Yes | **Update**: version → `2.0.0` | R10. |
| `.claude-plugin/marketplace.json` | Yes | **Update**: version → `2.0.0`; pin v1 entry per D11 | R10, D11. |

### Integration Approach

Cerberus v2 is a clean Go rewrite, not an incremental port. The Go binary is the single integration point — every host-visible surface (skills, hooks, manifests) is updated to invoke `bin/cerberus`. Editable on-disk artifacts (prompts, configs, templates) are preserved because they are content, not behavior. Run-team surface is excised end-to-end (skill, hooks, helpers, agent, template) per D6/D9.

The only "extending vs new infrastructure" question is the skill-bootstrap shell snippets that already live inline inside SKILL.md files. These are KEPT as-is structurally but updated content-wise to remove references to v1 helper files (`bin/review-gate-models.sh`, `bin/review-gate`) and to call `bin/cerberus` directly. They are not `bin/*.sh` files and therefore satisfy S3 (D25). A single canonical snippet lives in `prompts/host-neutral-bootstrap.md` (new) and is mirrored into each surviving SKILL.md by a maintenance step in Phase F. CI drift detection compares each SKILL.md's bootstrap region against the canonical file.

The integration boundary becomes: host skill or hook → inline bootstrap (`sh -c '...'`) → `bin/cerberus <subcommand>` → internal Go packages → reviewer CLIs and filesystem state. Content artifacts remain editable on disk; behavior moves into Go.

## Prerequisites

- Go ≥ 1.22 on the maintainer's dev box and on CI runners.
- `make` available on PATH (universally available on macOS/Linux; Windows is out of scope per spec).
- Upstream `claude`, `codex`, `gemini` CLIs available locally for end-to-end smoke tests; mocks suffice for unit/integration CI.
- GitHub Actions (or equivalent) for the CI matrix (R6).
- Marketplace pin for v1.54.x retained alongside v2.0.0 (D11).
- v1 plugin remains usable until v2 is GA; users on v1 are unaffected by the rewrite branch.
- Maintainer accepts removal of `create-tasks --agent-team` along with the run-team cascade (D41).
- Agreement that no active v1 gate state needs migration; v2 docs instruct users to clear state if they upgrade mid-run.

## High-Level Approach

The rewrite proceeds in eight phases (D23). Each phase produces a usable intermediate state but only Phase H is GA. Phases may overlap in implementation but the dependency order below is binding:

- **A. Skeleton & scaffold.** `go.mod`, `cmd/cerberus`, `internal/{cli,config,host}`, `Makefile`, inline hook bootstrap. The plugin loads, `cerberus check` is a no-op stub. No user-visible behavior change yet — v1 path still active.
- **B. Single-pass review.** `internal/{state,roster,reviewer,prompts,orchestrator,aggregate,telemetry}` plus `cerberus spawn-code-review`, `wait`, `resolve`, `status`, `check`, `artifact-path`, `author-context`. Default panel `[claude, codex, gemini]` works on Claude host with Stop-hook gating. **Adds early Codex smoke test** (boot Codex hook end-to-end on a single Codex slot) so any host-contract surprises surface in Phase B rather than Phase E.
- **C. Debate.** Extend `internal/orchestrator` for multi-round; add `internal/anonymize` per D30; preflight refusal of 1-reviewer + `--debate` (D7), including the case where degraded panels reduce to one reviewer (D13).
- **D. Generate.** `cerberus generate` subcommand for create-spec / create-plan / architecture-review / healthcheck multi-model drafts.
- **E. Codex host parity.** `internal/hook` handlers for `codex-session-start`, `codex-prompt-submit`, `codex-stop`. All 13 surviving skills work on Codex.
- **F. Cleanup & removals.** Update 13 SKILL.md bootstraps; rewrite `hooks/{hooks,codex-hooks}.json`; delete run-team surface; bump plugin manifests to `2.0.0`; remove `templates/codex-hooks.json`; remove `bin/*.sh` files; add `bin/cerberus` to `.gitignore` (D32).
- **G. CI & tests.** Port test fixtures; write Go unit + integration tests; mock reviewer CLIs; structural lint (zero-bash, no-run-team-refs); cross-platform build matrix; binary-size assertion (D35).
- **H. Docs & GA.** Rewrite `README.md`, `docs/CODEX.md`; add `CONTRIBUTING.md` covering `make install` (D26); migration / rollback notes per D11; tag `v2.0.0` and publish.

The phases above are a logical ordering for the rewrite, not a release schedule. v2.0.0 ships as one cutover; users opt in via `/plugin update`.

## Technical Design

### Architecture

`cmd/cerberus/main.go` is a thin entry point that calls `internal/cli.Run(os.Args)`. `internal/cli` parses the leading subcommand, dispatches to a per-subcommand handler, and threads a `*config.Env` (resolved from `CERBERUS_*` env vars + flags) through every call. Spawn-* subcommands compose: `internal/host` resolves the host adapter; `internal/roster` loads and resolves the roster (file + CLI overrides); `internal/orchestrator` instantiates a Run, which fans out via `internal/reviewer` to one subprocess per slot, collects per-reviewer JSON, runs `internal/aggregate` for the verdict, and writes through `internal/state` (filesystem state tree) and `internal/telemetry` (event JSON). Debate is a method on the same orchestrator that loops the round runner with `internal/anonymize` interposed between rounds; it does NOT live in a separate package, satisfying R3's "one Go module" requirement.

Hook subcommands (`cerberus hook claude-stop`, `codex-stop`, `claude-session-start`, `codex-session-start`, `codex-prompt-submit`) live under `internal/hook/` and are invoked by `internal/cli` after the same `*config.Env` resolution. The Stop hook runs a poll loop against `gate-state.json.status` until `resolved` or `MAX_WAIT_SECONDS`. Session-start and prompt-submit hooks initialize per-session state (transcript path, run key) so the next subcommand sees a consistent environment. The hook surface is host-aware but state-tree shape is host-neutral; this is what makes Codex a peer host (R4) rather than an adapter.

### Module / Package Layout

```
cmd/cerberus/main.go                     # entry: parse args, dispatch via internal/cli
internal/cli/                            # subcommand registry + flag parsing (stdlib flag)
  ├── cli.go                             # Run(args)
  ├── spawn.go                           # legacy `cerberus spawn` compat shim; dispatches to spawn_code_review / spawn_plan_review / etc. (D42)
  ├── spawn_code_review.go
  ├── spawn_plan_review.go
  ├── spawn_spec_review.go
  ├── spawn_epic_verify.go
  ├── spawn_ask.go
  ├── wait.go
  ├── resolve.go
  ├── status.go
  ├── check.go
  ├── completion_check.go                # `cerberus completion-check`; thin wrapper around check.go's logic
  ├── artifact_path.go
  ├── author_context.go
  ├── generate.go                        # multi-model generator orchestration
  └── hook.go                            # hook entry: claude-stop, codex-stop, claude-session-start, codex-session-start, codex-prompt-submit
internal/config/                         # CERBERUS_* env resolution; defaults
internal/host/                           # host adapter (claude | codex | generic); state-root, project-key derivation
internal/roster/                         # YAML loader; slot resolver; instance ID assignment
internal/prompts/                        # on-disk strategy/persona/reviewer prompt assembly
internal/reviewer/                       # subprocess runner for {claude, codex, gemini}; stdout capture; JSON parsing
internal/orchestrator/                   # gate state machine; round runner (single + multi-round/debate); aggregation; emits telemetry
  ├── orchestrator.go
  ├── gate_state.go                      # gate-state.json reads/writes
  ├── round.go
  └── debate.go
internal/aggregate/                      # confidence-weighted vote; verdict computation (single source of truth, R3)
internal/anonymize/                      # peer-N ID assignment; provider/model identifier scrubbing (single source of truth, R3, R9)
internal/state/                          # filesystem layout: <state_root>/<project>/<run>/iterations/<N>/round-<R>/reviewers/<instance_id>/
internal/telemetry/                      # JSON event writer; per-iteration + run-level rollups
internal/hook/                           # poll loop, transcript reading, host-specific session-init logic
internal/generate/                       # multi-model draft generator (create-spec / create-plan / architecture-review / healthcheck)
Makefile                                 # build, install, test, lint, fixtures-refresh
go.mod, go.sum
.github/workflows/ci.yml                 # OS × host matrix; build-matrix; binary-size assertion (D35)
.gitignore                               # bin/cerberus and other build artifacts (D32)
prompts/host-neutral-bootstrap.md        # NEW: canonical SKILL.md bootstrap snippet (D25)
tests/
  ├── integration/                       # cross-package end-to-end Go tests
  ├── mocks/{claude,codex,gemini}/main.go  # mock reviewer CLIs (D22, D31)
  └── fixtures/                          # frozen JSON outputs by (sha8(prompt), instance_id)
```

Package boundaries are intentionally separate for `aggregate` and `anonymize` (rather than collapsed into `orchestrator/`) precisely so R3's grep verification is mechanical. The R3 invariant bans DUPLICATE implementations or DEFINITIONS outside the source-of-truth packages — `internal/aggregate` for verdict aggregation, `internal/anonymize` for peer-N IDs and provider/model scrubbing, `internal/state` for `gate-state.json` I/O. Imports of these packages from `internal/orchestrator` and from `*_test.go` files are explicitly ALLOWED and required (the orchestrator composes them; tests exercise them). Concretely, the R3 lint runs as: any `.go` file outside `internal/aggregate`, `internal/anonymize`, or `internal/state` that defines top-level symbols whose names match `Aggregate*`, `Anonymize*`, or that writes `gate-state.json` directly fails the lint. The version stamp (formerly `internal/build/`) is folded into `internal/config/`; no separate package needed.

### Core Data Types

```go
// internal/roster/types.go
type RosterSlot struct {
    Provider      string // claude | codex | gemini
    Model         string
    Strategy      string // empty, "none", or matches prompts/strategies/<name>.md
    PersonaPath   string // path resolved relative to roster file
    Mode          string // fast | smart | max
    InstanceID    string // <provider>#<index>; assigned post-merge/degradation
    InstanceIndex int    // 1-based per provider
}

// internal/orchestrator/gate_state.go
type GateState struct {
    SchemaVersion    int       `json:"schema_version"`
    RunKey           string    `json:"run_key"`
    Host             string    `json:"host"` // claude | codex | generic
    ProjectKey       string    `json:"project_key"`
    SessionID        string    `json:"session_id"`
    TranscriptPath   string    `json:"transcript_path"`
    Status           string    `json:"status"` // pending | resolved
    Verdict          *string   `json:"verdict"` // pass | fail | requires_decision | nil
    CurrentIteration int       `json:"current_iteration"`
    MaxRounds        int       `json:"max_rounds"`
    Debate           bool      `json:"debate"`
    RosterID         string    `json:"roster_id"`
    StartedAt        time.Time `json:"started_at"`
    EndedAt          *time.Time `json:"ended_at"`
}
```

### Roster YAML Schema (closes D12 / D15)

```yaml
version: 1                              # required; only "1" recognized in v2.0
defaults:                               # optional; panel-wide defaults
  mode: smart                           # fast | smart | max; falls back to invocation flag
  max_rounds: 3                         # used when --debate is set; ignored otherwise
rosters:                                # required; map of roster name → roster definition
  default:                              # roster name; pattern [a-z0-9_-]+ (preflight enforces)
    reviewers:                          # required; non-empty list
      - provider: claude                # required; one of: claude | codex | gemini
        model: claude-opus-4-7          # required; passed to provider CLI as --model (or equivalent)
      - provider: codex
        model: gpt-5.5
      - provider: gemini
        model: gemini-3.1-pro
  diverse-codex:
    reviewers:
      - provider: codex
        model: gpt-5.5
        strategy: verification-first    # optional; matches prompts/strategies/<name>.md or "none"
      - provider: codex
        model: gpt-5.4
        strategy: falsification-first
        persona: ./personas/security.md # optional; path resolved relative to roster file
        mode: max                       # optional; overrides defaults.mode + invocation flag for this slot
      - provider: codex
        model: gpt-5.3-codex
        strategy: decompose
      - provider: gemini
        model: gemini-3.1-pro
```

**Field rules.**
- `version` (required) — must equal `1`. Other values: preflight rejects.
- `defaults` (optional) — `mode` (fast/smart/max) and `max_rounds` (positive int). Unknown keys: preflight rejects.
- `rosters` (required) — map of `[a-z0-9_-]+` → roster object. At least one roster.
- Each roster object has `reviewers:` (required, non-empty list).
- Each reviewer entry: `provider` (required, enum), `model` (required, string). Optional: `strategy` (string or `none`), `persona` (path), `mode` (enum).
- Unknown keys at slot level: preflight rejects (uses `yaml.v3` `KnownFields(true)`).

**Resolution order.**
1. Roster selection. If `--roster <name>` is absent and a `rosters.yaml` file exists, look up the roster named `default` in that file; if absent in the file, preflight error per the rule below (D47). If no `rosters.yaml` file exists, use the built-in default `[claude, codex, gemini]` (per D45) which degrades on missing CLIs (D39). If `--roster <name>` is passed, it selects from the file (which must exist).
2. CLI append: `--reviewer <provider>:<model>:<strategy?>` appends new slots.
3. CLI replace: `--replace-slot <instance_id>` paired with `--reviewer ...` replaces a file-defined slot.
4. Instance ID assignment: walk the resolved list, assign `<provider>#<index>` where `<index>` is the 1-based occurrence of `<provider>` in the list.

**Path precedence.** `./.cerberus/rosters.yaml` (per-project) wins over `$XDG_CONFIG_HOME/cerberus/rosters.yaml` or `~/.cerberus/rosters.yaml` (per-user). v2 reads at most one file; the project file fully replaces the user file when present.

**Preflight failures (each emits the file path + roster name + slot index in the error).**
- Schema parse error or unknown top-level / slot-level keys (`yaml.v3` `KnownFields(true)`).
- Empty `reviewers` list.
- Unknown `provider`.
- Unknown `mode`.
- `strategy` references missing `prompts/strategies/<name>.md` (and is not `none`).
- `persona` references missing file.
- `--replace-slot <id>` references a non-existent slot.
- `--reviewer` paired with `--roster` and a YAML-only field needed (persona / per-slot mode); use the YAML roster path instead (D36).
- `--agents` paired with `--roster` or `--reviewer` (mutually exclusive per D42).
- `rosters.yaml` exists but defines no roster named `default` AND `--roster` was not passed → preflight error: `no roster named 'default' in <file>; pass --roster <name> to select an existing roster, or remove rosters.yaml to use the built-in default` (D47).
- Resulting panel is empty (default-roster degradation case is the only path that proceeds with a reduced panel; D39).
- 1-reviewer panel with `--debate` (per D7), including the degraded-default case.
- YAML roster references a CLI not available on PATH (custom rosters reject; D39).

**Preflight warnings (stderr, non-fatal).**
- Exact-duplicate slot tuple `(provider, model, strategy)` (D33).
- Default panel CLI missing — one warning per missing CLI (D13/D39).
- More than 10 instances of the same `(provider, model)` (likely typo or runaway) — does not refuse.
- Existing `gate-state.json` already in `pending` state at spawn time (D29 concurrency caveat).

### CLI Subcommands

```
cerberus spawn ...                        # generic spawn (legacy compat shim; prefers spawn-<artifact>)
cerberus spawn-code-review ...
cerberus spawn-plan-review ...
cerberus spawn-spec-review ...
cerberus spawn-epic-verify ...
cerberus spawn-ask ...
cerberus wait [--json] [--finalize]
cerberus resolve [--reason <text>]
cerberus status [--json]
cerberus check
cerberus completion-check
cerberus artifact-path
cerberus author-context [--clear] [text]
cerberus generate <output-dir> --type <create-plan|create-spec|healthcheck|architecture-review> [...]
cerberus hook claude-session-start
cerberus hook claude-stop
cerberus hook codex-session-start
cerberus hook codex-prompt-submit
cerberus hook codex-stop
```

Review-spawn flags include `--mode fast|smart|max`, `--max-rounds`, `--debate`, `--consensus majority|all|any` (D43), `--roster <name>`, repeatable `--reviewer provider:model[:strategy]` (D36), `--replace-slot <provider>#<index>`, and legacy `--agents claude,codex,gemini` (D42, mutually exclusive with `--roster` and `--reviewer`).

### Reviewer Subprocess Contract

For each resolved roster slot, `internal/reviewer.Spawn(ctx, slot, prompt)` runs:

1. **Compose system prompt.** `internal/prompts.Compose(slot)` reads, in order: persona file (if set), strategy file (if set and not `none`), reviewer prompt for the artifact type. Concatenates with `\n\n` separators.
2. **Compose user prompt.** Artifact diff / spec / plan content from the spawn-* subcommand caller, plus author-context (if set), plus debate peer broadcast (round ≥ 2 only).
3. **Build provider command.** Per-provider invocation. The composed user prompt is delivered via STDIN (NOT argv) to avoid `E2BIG` on macOS where `getconf ARG_MAX` is often ~256KB; code-review prompts (artifact diff + author-context + debate peer broadcast) routinely exceed that. Stdin is chosen uniformly for all three providers because it is the conventional contract for `claude` and `codex` and is the simplest provider-neutral path; if Phase B discovers any provider (notably gemini) that does not accept the user prompt on stdin, fall back to a temporary prompt file at `<state_root>/<project>/<run>/iterations/<N>/round-<R>/reviewers/<instance_id>/prompt-stdin.md` passed via a `--prompt-file` style flag for that provider only. Final flag set is confirmed in Phase B against the actual CLIs (already covered by OQ-Plan-1). System prompts continue to use `--append-system-prompt <text>`-style flags on argv (system prompts are typically smaller and rarely exceed argv limits); if a provider rejects multi-line system strings on argv, fall back to a `--system-prompt-file` style flag for that provider and document the fallback in a Decision-Log row. See D46 for the rationale.
   - **claude:** `claude --print --output-format json --append-system-prompt <system>` with the composed user prompt written to the child's stdin (matches v1 invocation, modified to deliver the user prompt via stdin instead of argv).
   - **codex:** `codex --json --model <model> --append-system-prompt <system>` with the composed user prompt written to the child's stdin.
   - **gemini:** `gemini --json --model <model> --append-system-prompt <system> --policy-file ${CERBERUS_ROOT}/config/gemini-readonly-policy.toml` with the composed user prompt written to the child's stdin (Phase B confirms; if the installed gemini CLI rejects stdin, fall back to `--prompt-file <state_root>/.../prompt-stdin.md`). C5 policy applies to every Gemini child.
4. **Run with timeout.** `exec.CommandContext` with the orchestrator's deadline; pipe the composed user prompt into the child via `cmd.Stdin` (or write a temporary `prompt-stdin.md` for any provider that rejects stdin per Phase B); capture stdout (canonical) and stderr (logged). Non-zero exit propagates as a reviewer failure (no retry; simplification mandate).
5. **Parse JSON.** Strict unmarshal into the per-reviewer schema (`findings[].confidence`, `overall_confidence`, `strategy`, `round`, `peer_responses_seen`, raw verdict in `PASS`/`FAIL`/`NEEDS_WORK` per D44). Schema parse errors propagate as reviewer failures. **Empty stdout is treated as a failure** (CLI killed mid-stream or returned no JSON); the prompt is written alongside `stderr.log` for post-mortem.
6. **Write per-reviewer outputs.** `internal/state.WriteReviewerOutput(runKey, iter, round, instanceID, json)` writes to `<state_root>/<project>/<run>/iterations/<N>/round-<R>/reviewers/<instance_id>/output.json` plus a per-reviewer telemetry row.
7. **Apply Gemini policy verification.** For Gemini slots, `internal/reviewer` asserts the `--policy-file` flag was passed; an integration test confirms the policy file is read by the Gemini CLI by attempting a write tool and checking it's blocked (R9 verification).

The exact provider CLI flag names are subject to validation against the upstream CLIs in Phase B; if a flag has been renamed, the plan-phase Decision Log adds a row pinning the actual flag and updating this section. The contract surface (compose, run, parse, write) is invariant. (See OQ-Plan-1.)

### Aggregation (`internal/aggregate`, D43 / D44)

`internal/aggregate.Compute(slots, outputs, mode)` is the single source of truth for verdict computation (R3 single-package invariant). Behavior:

- **Raw verdict normalization.** Each per-reviewer output's raw `verdict` (`PASS`/`FAIL`/`NEEDS_WORK`, D44) is mapped to one of `pass | fail | requires_decision` internally; the raw value is preserved in telemetry. Raw reviewer output `NEEDS_WORK` (or equivalents) is normalized to internal `requires_decision`; `gate-state.json.verdict` uses the same `requires_decision` token (matches the schema in `### State Tree Layout`).
- **Consensus modes (D43).**
  - `majority` (default) — strict majority of non-failing reviewers must report `pass`; ties resolve to `requires_decision`.
  - `all` — every reviewer must report `pass`; any other state fails the gate.
  - `any` — at least one reviewer reports `pass`; permissive mode for exploratory reviews.
- **Blocking findings.** Any reviewer with a finding marked `severity: blocking` prevents a `pass` regardless of consensus mode. Blocking severities are recorded in the iteration telemetry's `blockers[]` field.
- **Failed reviewer subprocesses.** A non-zero exit or schema-parse failure from any slot fails the gate (no fail-open; simplification mandate). The orchestrator exits non-zero; no defensive mid-run gate states are created.
- **Output.** Returns one resolved gate verdict (`pass | fail | requires_decision`). Failures during subprocess execution or JSON parsing exit non-zero.

### State Tree Layout

```
<state_root>/<project>/<run>/
├── gate-state.json                            # gate state machine (pending → resolved)
├── run-telemetry.json                         # roll-up across iterations
├── author-context.json                        # author-supplied context (optional)
└── iterations/
    └── <N>/                                   # 1-based iteration index
        ├── iteration-telemetry.json           # roll-up across rounds within this iteration
        └── round-<R>/                         # 1-based round index (single-pass: only round-1)
            ├── round-telemetry.json
            ├── peer-broadcast.json            # round ≥ 2 only; anonymized peer outputs
            └── reviewers/
                └── <provider>#<index>/        # e.g., codex#1, codex#2, gemini#1
                    ├── prompt.md              # system + user prompt as sent (audit)
                    ├── output.json            # canonical reviewer JSON
                    ├── stdout.log             # raw provider CLI stdout
                    ├── stderr.log
                    └── telemetry.json         # per-reviewer row (R8)
```

**`gate-state.json` schema (closes the v2 contract for spec §2 Key states).**
```json
{
  "schema_version": 1,
  "run_key": "<sha256-prefix>",
  "host": "claude | codex | generic",
  "project_key": "<sha256 of repo path>",
  "session_id": "<host-provided session id>",
  "transcript_path": "<absolute path or empty>",
  "status": "pending | resolved",
  "verdict": null | "pass" | "fail" | "requires_decision",
  "current_iteration": 1,
  "max_rounds": 3,
  "debate": false,
  "roster_id": "default",
  "started_at": "2026-05-08T13:00:00Z",
  "ended_at": null | "2026-05-08T13:14:00Z"
}
```

**State derivation rules.**
- `<state_root>` defaults to `~/.claude/projects/<project_key>/cerberus/` for Claude host; for Codex, the host adapter resolves an equivalent under `~/.codex/projects/<project_key>/cerberus/`. Generic host uses `${CERBERUS_STATE_ROOT}` (required if no host adapter).
- `<run>` is `<session_id>` for hosts that expose a stable session ID; for generic, the host adapter mints one from `${CERBERUS_RUN_KEY}`.
- `<project_key>` is `sha256(absolute repo path)[0:16]` for stability.
- The `gate-state.json` is the only file polled by the Stop hook. Round/reviewer outputs are append-only; Stop hook does NOT read them.

v1's gate-state schema (with `awaiting_decision`, `requires_decision`, `error` intermediate states for debate cancellation) is NOT carried forward in v2.0. Per the simplification mandate, v2 collapses to `pending → resolved` and surfaces failures as non-zero exits, not as state-machine states.

### Telemetry JSON Schema (closes R8 / D16)

**Per-reviewer row** (`iterations/<N>/round-<R>/reviewers/<id>/telemetry.json`):
```json
{
  "schema_version": 1,
  "reviewer_id": "codex#2",
  "instance_index": 2,
  "provider": "codex",
  "model": "gpt-5.4",
  "strategy": "falsification-first",
  "persona_name": null,
  "mode": "smart",
  "tokens": { "input": 1234, "output": 567 },
  "cost_usd": 0.123,
  "peer_id": "peer_2",
  "verdict": "fail",
  "overall_confidence": 0.75,
  "round": 1,
  "time_to_finish_ms": 45123,
  "started_at": "2026-05-08T13:00:00Z",
  "ended_at": "2026-05-08T13:00:45Z"
}
```

**Round telemetry** (`iterations/<N>/round-<R>/round-telemetry.json`):
```json
{
  "schema_version": 1,
  "round": 1,
  "reviewer_count": 4,
  "consensus_pct": 0.75,
  "abstentions": 0,
  "k_star_estimate": null,
  "started_at": "...",
  "ended_at": "..."
}
```

**Iteration telemetry** (`iterations/<N>/iteration-telemetry.json`):
```json
{
  "schema_version": 1,
  "iteration": 1,
  "rounds": 2,
  "verdict": "pass",
  "reviewer_summary": [
    { "reviewer_id": "codex#1", "verdict": "pass", "tokens": {"input": 1000, "output": 400}, "cost_usd": 0.10 }
  ],
  "started_at": "...",
  "ended_at": "..."
}
```

**Run telemetry** (`run-telemetry.json`):
```json
{
  "schema_version": 1,
  "run_key": "<sha256-prefix>",
  "host": "claude",
  "mode": "smart",
  "roster_id": "default",
  "debate": false,
  "iterations": 1,
  "total_rounds": 1,
  "total_tokens": { "input": 4000, "output": 1500 },
  "total_cost_usd": 0.45,
  "final_verdict": "pass",
  "started_at": "...",
  "ended_at": "..."
}
```

**Event log** (`event-log.jsonl`, append-only) — one event per line, mirroring spec §4 instrumentation event names verbatim (`cerberus.build.{started,completed,failed}`, `cerberus.roster.selected`, `cerberus.preflight.failed`, `cerberus.reviewer.{spawned,completed,failed}`, `cerberus.review.round_complete`, `cerberus.debate.{round_started,round_completed}`, `cerberus.review.resolved`, `cerberus.hook.{blocked,allowed}`). Each event is a `{event, timestamp, ...payload}` record.

### Anonymization Algorithm (D30)

Debate round R+1 receives an anonymized broadcast of round R's per-reviewer outputs. Algorithm:

1. **Build peer map** for round R: walk reviewers in instance-ID lexicographic order (e.g., `claude#1`, `codex#1`, `codex#2`, `gemini#1`); assign `peer_1..peer_N`. Map is deterministic and stable across rounds within a single iteration.
2. **For each peer's output**, copy the structural fields verbatim into a per-peer record: `verdict`, `overall_confidence`, `findings[].confidence`, `findings[].severity`. These are not scrubbed — they are signal, not identity.
3. **Free-text scrub** of `findings[].evidence`, `findings[].recommendation`, `summary`, and any other free-text reviewer output. The scrub runs as the following pseudocode pipeline (concrete Go in `internal/anonymize/scrub.go`). **Step ordering matters:** self-reference attribution runs FIRST so it can match provider words; only then are remaining provider/model words scrubbed to the generic `peer` / `peer-model` tokens. Reversing the order would replace `claude` with `peer` before the self-reference regex could attribute it to a specific `peer_<N>`.

   ```
   For each reviewer R with peer_id P:
     text = R.output.text
     # 1. Self-references FIRST: "I, claude, ..." or "as the codex reviewer" → use this peer's specific ID.
     #    The alternation `(I|my|as|as the)` matches greedily, so `as the` wins over `as` when both
     #    apply; the trailing `(?:the\s+)?` optional segment exists so inputs like `as claude` (no
     #    "the") still match via the `as` branch. A contrived input like `as the the gemini` will
     #    scrub to `as the peer_N` (drops one redundant "the") — documented as a harmless edge case
     #    pinned by a unit test in `internal/anonymize/anonymize_test.go`.
     text = regex_replace(text, r'(?i)\b(I|my|as|as the)[,\s]+(?:the\s+)?(?:claude|codex|gemini)\b', r'\1 ' + P)
     # 2. Provider words (anywhere remaining) → generic "peer".
     text = regex_replace(text, r'(?i)\b(claude|codex|gemini)\b', 'peer')
     # 3. Model identifiers → generic "peer-model".
     text = regex_replace(text, r'(?i)\b(claude-opus[a-z0-9.-]*|gpt-[0-9.a-z]+|gemini-[0-9.a-z-]+)\b', 'peer-model')
     # 4. Cross-references in peer broadcasts (round ≥ 2) are already written as "peer_N" by the
     #    orchestrator and need no further scrub here.
     return text
   ```

   The model-name regex above is a generic fallback covering common provider/model token patterns; the active-roster model strings are also added to the literal scrub list at runtime so concrete roster entries (`claude-opus-4-7`, `gpt-5.5`, `gemini-3.1-pro`) are guaranteed-replaced regardless of regex coverage.
4. **Stamp peer ID** on each scrubbed record: `peer_id = peer_<N>` where N comes from step 1.
5. **Write `peer-broadcast.json`** at `iterations/<N>/round-<R+1>/peer-broadcast.json` containing the array of scrubbed records, sorted by `peer_id` to ensure determinism.
6. **Round R+1 prompt construction** (`internal/prompts`): inject the broadcast under a fixed marker in the reviewer prompt template (e.g., `{{PEER_BROADCAST}}`); the marker substitutes the JSON-serialized array. Round R+1 also includes the reviewer's own prior response.

**Falsifiability tests** (in `internal/anonymize/anonymize_test.go`) — concrete input → expected output cases:
- Cross-reference: input `"Claude said X"` (peer broadcast prose, no self-reference connective) → output `"peer said X"` (no self-reference match in step 1; provider-name scrub in step 2).
- Self-reference with commas (Fix 1 pin): input `"I, codex, recommend Y"` for a reviewer with `peer_id = peer_2` → output `"I peer_2 recommend Y"` (step 1 fires first and attributes the provider word to this specific peer; step 2 must NOT subsequently turn it into the generic `peer`).
- Self-reference with article: input `"as the gemini reviewer, I think Z"` for a reviewer with `peer_id = peer_3` → output `"as the peer_3 reviewer, I think Z"` (step 1's alternation matches `as the` greedily before falling back to `as`).
- Self-reference simple: input `"As codex, my recommendation is Q"` for a reviewer with `peer_id = peer_1` → output `"As peer_1, my recommendation is Q"` (step 1 matches `As` via the `as` branch; the optional `(?:the\s+)?` segment is a no-op).
- Doubled-`the` edge case (Fix 2 pin): input `"as the the gemini reviewer"` for a reviewer with `peer_id = peer_4` → output `"as the peer_4 reviewer"` (one redundant `the` is consumed; documented as harmless).
- Determinism: output JSON-parses cleanly and round-trips structural fields; two slots with identical reviewer outputs but different instance IDs get distinct `peer_id`s.
- Accepted false positive: provider name in a non-AI context (e.g., `claude_handler` identifier in a code-review finding) IS scrubbed to `peer_handler` — accepted tradeoff per D30.

### Hook Bootstrap Inline Command Pattern (D17)

The canonical shell body is structured to (a) succeed when the binary is already present, (b) detect missing `make` and missing Go separately and report each loudly, (c) only check for Go when a rebuild is actually required, and (d) handle paths with spaces. It uses the same shape for Claude and Codex; only the root variable and hook subcommand differ.

**Canonical shell body** (substitute `${HOST_ROOT}` and `${HOOK_NAME}` per host):

```sh
root="${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}"
bin="$root/bin/cerberus"
[ -n "$root" ] || { echo "cerberus: plugin root not set" >&2; exit 127; }
command -v make >/dev/null 2>&1 || { echo "cerberus: make not found on PATH; install make and retry." >&2; exit 127; }
if ! make -q -C "$root" build >/dev/null 2>&1; then
  command -v go >/dev/null 2>&1 || { echo "cerberus: Go >= 1.22 not found on PATH; install Go and retry." >&2; exit 127; }
  echo "cerberus: building... (this happens once after clone or upgrade)" >&2
  start=$(date +%s)
  make -C "$root" build >&2 || exit $?
  end=$(date +%s)
  echo "cerberus: build complete in $((end-start))s" >&2
fi
exec "$bin" hook ${HOOK_NAME}
```

**Claude `hooks/hooks.json`** (TaskCompleted + TeammateIdle entries are removed per D9):
```json
{
  "hooks": {
    "SessionStart": [{"hooks": [{
      "type": "command",
      "command": "sh -c 'root=\"${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}\"; bin=\"$root/bin/cerberus\"; [ -n \"$root\" ] || { echo \"cerberus: plugin root not set\" >&2; exit 127; }; command -v make >/dev/null 2>&1 || { echo \"cerberus: make not found on PATH; install make and retry.\" >&2; exit 127; }; if ! make -q -C \"$root\" build >/dev/null 2>&1; then command -v go >/dev/null 2>&1 || { echo \"cerberus: Go >= 1.22 not found on PATH; install Go and retry.\" >&2; exit 127; }; echo \"cerberus: building... (this happens once after clone or upgrade)\" >&2; start=$(date +%s); make -C \"$root\" build >&2 || exit $?; end=$(date +%s); echo \"cerberus: build complete in $((end-start))s\" >&2; fi; exec \"$bin\" hook claude-session-start'"
    }]}],
    "Stop": [{"hooks": [{
      "type": "command",
      "command": "sh -c 'root=\"${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}\"; bin=\"$root/bin/cerberus\"; [ -n \"$root\" ] || { echo \"cerberus: plugin root not set\" >&2; exit 127; }; command -v make >/dev/null 2>&1 || { echo \"cerberus: make not found on PATH; install make and retry.\" >&2; exit 127; }; if ! make -q -C \"$root\" build >/dev/null 2>&1; then command -v go >/dev/null 2>&1 || { echo \"cerberus: Go >= 1.22 not found on PATH; install Go and retry.\" >&2; exit 127; }; echo \"cerberus: building... (this happens once after clone or upgrade)\" >&2; start=$(date +%s); make -C \"$root\" build >&2 || exit $?; end=$(date +%s); echo \"cerberus: build complete in $((end-start))s\" >&2; fi; exec \"$bin\" hook claude-stop'",
      "timeout": 2100
    }]}]
  }
}
```

**Codex `hooks/codex-hooks.json`** (substitutes `PLUGIN_ROOT` for `CLAUDE_PLUGIN_ROOT` in the root fallback chain):

```json
{
  "hooks": {
    "SessionStart": [{"hooks": [{
      "type": "command",
      "command": "sh -c 'root=\"${CERBERUS_ROOT:-${PLUGIN_ROOT:-}}\"; bin=\"$root/bin/cerberus\"; [ -n \"$root\" ] || { echo \"cerberus: plugin root not set\" >&2; exit 127; }; command -v make >/dev/null 2>&1 || { echo \"cerberus: make not found on PATH; install make and retry.\" >&2; exit 127; }; if ! make -q -C \"$root\" build >/dev/null 2>&1; then command -v go >/dev/null 2>&1 || { echo \"cerberus: Go >= 1.22 not found on PATH; install Go and retry.\" >&2; exit 127; }; echo \"cerberus: building... (this happens once after clone or upgrade)\" >&2; start=$(date +%s); make -C \"$root\" build >&2 || exit $?; end=$(date +%s); echo \"cerberus: build complete in $((end-start))s\" >&2; fi; exec \"$bin\" hook codex-session-start'"
    }]}],
    "UserPromptSubmit": [{"hooks": [{
      "type": "command",
      "command": "sh -c 'root=\"${CERBERUS_ROOT:-${PLUGIN_ROOT:-}}\"; bin=\"$root/bin/cerberus\"; [ -n \"$root\" ] || { echo \"cerberus: plugin root not set\" >&2; exit 127; }; command -v make >/dev/null 2>&1 || { echo \"cerberus: make not found on PATH; install make and retry.\" >&2; exit 127; }; if ! make -q -C \"$root\" build >/dev/null 2>&1; then command -v go >/dev/null 2>&1 || { echo \"cerberus: Go >= 1.22 not found on PATH; install Go and retry.\" >&2; exit 127; }; echo \"cerberus: building... (this happens once after clone or upgrade)\" >&2; start=$(date +%s); make -C \"$root\" build >&2 || exit $?; end=$(date +%s); echo \"cerberus: build complete in $((end-start))s\" >&2; fi; exec \"$bin\" hook codex-prompt-submit'"
    }]}],
    "Stop": [{"hooks": [{
      "type": "command",
      "command": "sh -c 'root=\"${CERBERUS_ROOT:-${PLUGIN_ROOT:-}}\"; bin=\"$root/bin/cerberus\"; [ -n \"$root\" ] || { echo \"cerberus: plugin root not set\" >&2; exit 127; }; command -v make >/dev/null 2>&1 || { echo \"cerberus: make not found on PATH; install make and retry.\" >&2; exit 127; }; if ! make -q -C \"$root\" build >/dev/null 2>&1; then command -v go >/dev/null 2>&1 || { echo \"cerberus: Go >= 1.22 not found on PATH; install Go and retry.\" >&2; exit 127; }; echo \"cerberus: building... (this happens once after clone or upgrade)\" >&2; start=$(date +%s); make -C \"$root\" build >&2 || exit $?; end=$(date +%s); echo \"cerberus: build complete in $((end-start))s\" >&2; fi; exec \"$bin\" hook codex-stop'",
      "timeout": 2100
    }]}]
  }
}
```

**Quoting and robustness analysis (pressure-tested).**
- The JSON value is a double-quoted string. The body is wrapped in `sh -c '...'` (single quotes) so all shell metacharacters inside survive the JSON parser. Escaped double quotes (`\"...\"`) inside the body wrap the variable expansions to handle paths with spaces.
- `make -q -C "$root" build` returns non-zero when the target is stale or missing; this delegates staleness detection to `Makefile` dependencies (D20) rather than reimplementing `find -newer` logic in shell. When the target is up-to-date, `make -q` is silent and fast.
- `make` and `go` are checked separately. The `make` check runs unconditionally because we use `make -q` for staleness; the `go` check only runs when a rebuild is actually needed (avoids spurious `go not found` errors when the binary already exists).
- Build duration is logged on stderr (D34); the build chatter from `make` itself is also redirected to stderr (`>&2`) so it doesn't pollute stdout that the host might parse as event data.
- Hook payload (host event JSON) is read from stdin by Go hook code (D37); `"$@"` is intentionally NOT forwarded because it's brittle through `sh -c`.
- Timeouts: Stop hooks keep v1's 2100 s budget (manifest `timeout`); the internal Go-side `MAX_WAIT_SECONDS` is 1800 s (D38), giving a 5-minute buffer for cleanup/logging before host hard-kill. SessionStart and UserPromptSubmit have no manifest timeout in v1; v2 preserves that.

**Concurrency caveat.** Two simultaneous hook invocations on a freshly cloned plugin both observe `make -q` reporting stale and both run `make build`. The second writer wins; the first invocation may fail once with `exec format error` or `text file busy`. Acceptable per D29 (no concurrency primitives in v2.0 GA); rare in practice; documented in README.

**Hook timeout vs build time.** Stop-hook timeout is 2100 s. `make build` on a clean clone takes ~10–30 s (depends on Go module cache). Hook callers should expect the first invocation to be ~30 s slower than steady state. Documented in `docs/CODEX.md` and the v2 README.

### Lazy Build Trigger (D5 / D20 / D34)

Two classes of callers: skill SKILL.md inline bootstraps and hook entries in `hooks/{hooks,codex-hooks}.json`. Both share an identical **shared resolver body** (env resolution, missing-make / missing-go checks, lazy build via `make -q`); they diverge ONLY at the final `exec` line because skill bootstraps forward `"$@"` to the binary while hook bootstraps invoke a fixed `hook <name>` subcommand with no `"$@"` (per D37, hook payload is read from stdin and positional forwarding through `sh -c` is brittle). The pseudocode below marks the split explicitly:

```sh
# --- shared resolver (canonical body; identical across all callers) ---
root="${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}"
bin="$root/bin/cerberus"
[ -n "$root" ] || { echo "cerberus: plugin root not set" >&2; exit 127; }
command -v make >/dev/null 2>&1 || { echo "cerberus: make not found on PATH; install make and retry." >&2; exit 127; }
if ! make -q -C "$root" build >/dev/null 2>&1; then
    command -v go >/dev/null 2>&1 || { echo "cerberus: Go >= 1.22 not found on PATH; install Go and retry." >&2; exit 127; }
    echo "cerberus: building... (this happens once after clone or upgrade)" >&2
    start=$(date +%s)
    make -C "$root" build >&2 || exit $?
    end=$(date +%s)
    echo "cerberus: build complete in $((end-start))s" >&2
fi
# --- shared resolver above; per-caller exec below (allowed to diverge) ---
exec "$bin" "$@"                          # skill SKILL.md form
# exec "$bin" hook claude-stop            # hook form (one of: claude-session-start | claude-stop |
                                          # codex-session-start | codex-prompt-submit | codex-stop);
                                          # no "$@" forwarded — hook payload is read from stdin (D37)
```

The canonical version of the **shared resolver body** lives at `prompts/host-neutral-bootstrap.md`. CI's drift detector compares ONLY the shared resolver body across callers; the per-caller exec line is allowed to diverge between skill bootstraps (`exec "$bin" "$@"`) and hook bootstraps (`exec "$bin" hook <name>` with no `"$@"`). The shared resolver is the single source of truth — any change there must update `prompts/host-neutral-bootstrap.md` and propagate to every SKILL.md and both `hooks/*.json` manifests in the same PR. This is a clarification of D17/D25; no new D-number.

**Notes.**
- `Makefile` owns staleness through target dependencies (D20). The `Makefile` `build` target depends on `cmd/`, `internal/**/*.go`, `go.mod`, `go.sum`. `make -q` exits non-zero when any dependency is newer than `bin/cerberus` or when the target is missing.
- `make -q` exit code 2 (Makefile parse error / missing target) is treated identically to exit code 1 (needs rebuild). A malformed Makefile thus triggers an actual `make build` that then fails loudly with the underlying parse error. Acceptable for v2.0 GA per simplification mandate; documented in README troubleshooting.
- No advisory locks, no atomic-rename, no read-only-install fallback in v2 GA (R1 explicit defer; D29; simplification mandate).
- Concurrent invocations during first build: two simultaneous `make build` runs may stomp on `bin/cerberus` mid-write. Risk: the second writer wins; first invocation may fail with "exec format error" / "text file busy" once. Acceptable in v2.0 GA per D29; revisit if real users report.

### File Impact Summary

| Path | Status | Description |
|------|--------|-------------|
| `cmd/cerberus/main.go` | **New** | Single binary entry. |
| `internal/cli/` (and submodules above) | **New** | Subcommand dispatch and registry. |
| `internal/orchestrator/` | **New** | Gate state machine, single + multi-round; debate as feature flag. |
| `internal/roster/` | **New** | YAML config loader + slot resolver. |
| `internal/reviewer/` | **New** | Provider subprocess runners. |
| `internal/aggregate/` | **New** | Confidence-weighted vote. |
| `internal/anonymize/` | **New** | Peer-N IDs + scrubbing. |
| `internal/state/` | **New** | Filesystem state tree. |
| `internal/telemetry/` | **New** | JSON event writer. |
| `internal/host/` | **New** | Host adapter (claude / codex / generic). |
| `internal/hook/` | **New** | Hook entry handlers. |
| `internal/prompts/` | **New** | Strategy/persona/reviewer prompt assembly from on-disk Markdown. |
| `internal/generate/` | **New** | Multi-model draft generator. |
| `internal/config/` | **New** | Env contract; defaults. |
| `Makefile` | **New** | `build`, `install`, `test`, `lint`, `fixtures-refresh` targets. |
| `go.mod`, `go.sum` | **New** | Module manifest. |
| `.github/workflows/ci.yml` | **New** | OS × host matrix; build matrix; binary-size assertion (D35). |
| `.gitignore` | Modify | Add `bin/cerberus` (D32) and other build artifacts. |
| `prompts/host-neutral-bootstrap.md` | **New** | Canonical SKILL.md bootstrap snippet (D25); lint sources of truth. |
| `CONTRIBUTING.md` | **New** | `make install` workflow (replaces `bin/update-plugin` per D26); fixture refresh; binary-size budget. |
| `tests/integration/` | **New** | Cross-package Go tests. |
| `tests/mocks/{claude,codex,gemini}/main.go` | **New** | Tiny Go programs replaying fixture JSON (D22, D31). |
| `tests/fixtures/` | **New** | Frozen JSON outputs by `(sha8(prompt), instance_id)`. |
| `bin/review-gate`, `bin/review-gate-debate.sh`, `bin/review-gate-models.sh`, `bin/review-gate-hook.sh`, `bin/review-gate-lib.sh`, `bin/codex-stop-hook`, `bin/codex-session-init`, `bin/claude-session-init`, `bin/cerberus-skill-env`, `bin/telemetry-lib.sh`, `bin/generate`, `bin/update-plugin` | **Delete** (after Phase F) | Subsumed by `bin/cerberus`. |
| `bin/cerberus-task-completed-hook`, `bin/cerberus-teammate-idle-hook` | **Delete** | D6/D9. |
| `bin/tests/` (36 files + fixtures) | **Delete** (replaced by `tests/`) | D21. |
| `bin/cerberus` | **New** (build artifact, gitignored) | Single Go binary; built locally via `make build` or lazy bootstrap (D32). |
| `skills/run-team/` | **Delete** | D9. |
| `agents/implementer.md` | **Delete** | D9. |
| `templates/team-tasks-template.md` | **Delete** | D9. |
| `templates/codex-hooks.json` | **Delete** | D28. |
| `templates/tasks-template.md` | Exists (kept) | D9. |
| `prompts/**/*.md` | Exists (kept) | C4. |
| `config/gemini-readonly-policy.toml`, `config/gemini-readonly-settings.json` | Exists (kept) | C5. |
| `skills/<13 surviving>/SKILL.md` | Modify | Bootstrap snippet updated to reach `bin/cerberus`; remove refs to `bin/review-gate*` helper files. |
| `hooks/hooks.json` | Modify | Remove TaskCompleted + TeammateIdle; rewrite SessionStart + Stop to inline `sh -c` lazy-build bootstrap. |
| `hooks/codex-hooks.json` | Modify | Rewrite all three (SessionStart, UserPromptSubmit, Stop) to inline `sh -c` lazy-build bootstrap. |
| `.claude-plugin/plugin.json` | Modify | Version → `2.0.0`. |
| `.codex-plugin/plugin.json` | Modify | Version → `2.0.0`. |
| `.claude-plugin/marketplace.json` | Modify | Version → `2.0.0`; pin v1 entry per D11. |
| `README.md`, `docs/CODEX.md` | Modify | v2 user-facing docs (roster config, dual-host install, lazy build, Codex first-class, rollback). README troubleshooting section also covers `make -q` exit-2 conflation (lazy-build behavior on a malformed Makefile, per Lazy Build Trigger Notes). |
| `TODO.md` | Modify | Move strategy/mode rotation, K*/αK telemetry, sparsification, and any v2.x candidates to backlog. |
| `docs/2026-05-08-rebuild-spec.md` | Exists (kept) | Source of truth for this plan. |
| `docs/debate.md` | Exists (kept) | Theoretical reference (DMAD, K*, αK, anonymization, sycophancy, sparsification). |

## Risks, Edge Cases & Breaking Changes

### Edge Cases & Failure Modes
- **Lazy build with no Go on PATH** — Single-line stderr error pointing at install docs; non-zero exit; no partial gate state created (R1, D5).
- **Lazy build with no `make` on PATH** — Single-line stderr error; non-zero exit. The `make` check runs before the `go` check because we use `make -q` for staleness detection (D20).
- **Default panel on partial-availability host** — Drop missing CLIs at preflight with one stderr warning per missing CLI; reduced panel proceeds. Zero-reviewer panel refuses. 1-reviewer + `--debate` refuses, including the case where degradation reduces the default panel to one reviewer (R4 edge case, D7, D13, D39).
- **Custom roster references unavailable CLI** — Preflight rejects (no silent degradation) (D13, D39).
- **Persona / strategy / reviewer prompt context overflow** — Log warning + proceed; reviewer CLI handles its own truncation (Q7 / D24).
- **Same `(provider, model, strategy)` triple twice in roster** — Resolved to distinct instance IDs (`#1`, `#2`); preflight emits a stderr warning (likely typo; D33). 10+ instances of same `(provider, model)` triggers a runaway-cap warning.
- **CLI `--reviewer` flag** — APPENDS by default; `--replace-slot <instance_id>` is the explicit replace (R2). Grammar is `provider:model[:strategy]`; persona/per-slot mode require YAML (D36).
- **`--agents` paired with `--roster` or `--reviewer`** — Mutually exclusive (D42); preflight rejects.
- **Roster file fails to parse / 0 reviewers / unknown provider / missing strategy or persona file / invalid mode / unknown YAML keys** — Preflight rejects with file path + slot index in error (R2 edge cases).
- **Mid-run roster change request** — Refused; roster is locked within a run, mutable on next iteration after fix-commit-triggered respawn (D10).
- **Reviewer subprocess crashes mid-round** — Error propagates; non-zero exit. v2 GA does NOT fail-open or invent an `error` gate state (spec §2 Key states).
- **Reviewer subprocess returns empty stdout** — Treated as failure (no JSON to parse); logged with the slot's `prompt.md` for post-mortem.
- **Reviewer JSON does not match schema** — Strict failure; full `stdout.log` archived for post-mortem; non-zero exit (no JSON repair per simplification mandate).
- **Hook fires before any skill invocation** — Inline `sh -c` in `hooks/{hooks,codex-hooks}.json` does its own lazy-build check independent of skill invocation (R1, D5).
- **`bin/cerberus` mtime older than source after a plugin upgrade** — `make -q` reports stale; lazy build triggers automatically; user's first invocation incurs build delay with stderr build message (R1, D20, D34).
- **Concurrent runs in same project** — Two simultaneous `cerberus spawn-code-review` invocations may clobber each other's `gate-state.json`. v2.0 GA does not lock; emits a stderr warning if `gate-state.json` exists in `pending` state at spawn time. README documents single-active-run guidance (D29).
- **Concurrent hook invocations on first build** — Two parallel `make build` runs may stomp on `bin/cerberus` mid-write; first invocation may fail once with `exec format error` / `text file busy`. Documented limitation; rare; acceptable per D29.
- **Anonymization false positives** — Provider name appearing in a non-AI context (e.g., the identifier `claude_handler` in a code review finding) gets scrubbed to `<peer>_handler`. Accepted tradeoff per D30; falsifiability test in `internal/anonymize`.
- **Hook timeout consumed by lazy build** — Stop hook timeout 2100 s; first invocation's `make build` consumes ~10–30 s. Internal Go-side `MAX_WAIT_SECONDS` is 1800 s (D38), giving a 5-minute buffer. Documented in CODEX.md.
- **Stop hook exceeds internal wait** — Go hook exits non-zero before host manifest timeout; host timeout remains a hard outer bound (D38).
- **Embedded prompts fallback** — v2.0 GA does NOT embed (D40); on-disk read is mandatory. Installations missing prompt files fail loudly. Embedding can return in v2.x.

### Breaking Changes & Compatibility
- `REVIEW_GATE_*` env aliases are dropped. Users with v1 CI integrations must rename to `CERBERUS_*` (C2, R7).
- Telemetry per-reviewer `reviewer_id` shape changes from `<provider>` (v1) to `<provider>#<index>` (v2). v1 telemetry consumers are NOT a binding constraint per simplification mandate (R8).
- `run-team` skill, `TaskCompleted`/`TeammateIdle` hook entries, `agents/implementer.md`, and `templates/team-tasks-template.md` are removed entirely. Any user automation depending on these breaks (D6, D9).
- `create-tasks --agent-team` is removed alongside run-team (D41); Beads, Linear, and TODO-style task generation survive.
- v1 → v2 state migration is unsupported. Users with active v1 gates clear state on upgrade (`rm -rf ~/.claude/projects/<hash>/cerberus/<run>` documented in README) (D11).
- v2 → v1 downgrade is unsupported. Recovery is `/plugin update --version 1.54.x` plus the same `rm -rf` (D11).
- Plugin manifest versions jump from 1.54.16 / 1.0.23 to 2.0.0 — semver major bump signals breaking changes (R10).
- `bin/review-gate` executable does NOT exist in v2. External integration scripts that invoke `bin/review-gate spawn-code-review` directly must update to `bin/cerberus spawn-code-review` (R3 edge case).
- `bin/cerberus-skill-env` is removed (D27); external scripts that sourced it break. Migration: invoke `bin/cerberus` directly.
- `bin/cerberus` is `.gitignore`d (D32); `git clone` consumers must run `make build` (or trigger lazy build via skill/hook).

### Risks
- **Implementation effort underestimate** — v1 is 17 KLOC bash; equivalent Go is plausibly 6–10 KLOC, but the spec mandates feature parity across 13 skills, two hosts, four hook types, debate, and a multi-instance roster. Mitigation: phase A–H ordering keeps the v1 path active until v2 is GA; v1 marketplace pin per D11; Codex smoke test pulled forward into Phase B (not E) so host-contract surprises surface early.
- **Codex host quirks** — Codex hook contract is less mature than Claude's; v1's `bin/codex-stop-hook` (958 LOC) plus `bin/codex-session-init` (224 LOC) reflect accumulated edge-case fixes. Mitigation: port behavior, not bash; integration tests on `CERBERUS_HOST=codex` block merge; Phase B early Codex smoke test.
- **Reviewer JSON parsing drift** — Upstream `claude`, `codex`, `gemini` CLI output formats may change. Mitigation: strict JSON schema validation at ingest; loud failure (non-zero exit), no silent repair; full `stdout.log` archived for post-mortem (simplification mandate).
- **Binary size budget breach** — 30 MB stripped on darwin-arm64 (D35). Adding a heavy dependency (e.g., cobra, full YAML toolchain, embedded prompts ≥ 10 MB) could blow it. Mitigation: D18 stdlib-flag + D19 yaml.v3 keep dependencies minimal; CI assertion fails build if exceeded.
- **Hook timeout misconfiguration** — Stop hook timeout is 2100 s in v1; Codex SessionStart and UserPromptSubmit have no manifest timeout. Mitigation: copy v1 manifest timeouts verbatim into the new manifests; internal Go-side `MAX_WAIT_SECONDS` is 1800 s (D38) for cleanup buffer; documented in plan-phase Decision Log.
- **Anonymization completeness** — Free-text scrub (D30) is a heuristic; sophisticated linguistic identity leaks (writing-style fingerprints, citation patterns) are not addressed in v2.0. Mitigation: documented as a known v2.0 limitation; revisit if real users observe sycophancy in debate runs (referenced in TODO.md as v2.x candidate).
- **Concurrent gate-state clobber** — Per D29. Mitigation: stderr warning at spawn time; README single-active-run guidance; revisit when real users hit it.
- **Provider CLI flag drift** — Adapters assume specific flag names (per Reviewer Subprocess Contract section); upstream renames break the build (OQ-Plan-1). Mitigation: Phase B implementation validates flags against installed CLIs; flag changes recorded in a Decision-Log row.

## Testing & Validation Strategy

### Test Layers
- **Unit (`internal/<pkg>/*_test.go`)** — One happy-path + one failure-path per exported function; fast (`make test` < 60 s on the maintainer's box).
  - `internal/roster`: project/user precedence, strict schema rejection, default degradation, custom roster rejection, duplicate slots, `--replace-slot`, instance ID assignment.
  - `internal/config` and `internal/host`: env fallback, host detection, state-root/project-key/run-key derivation.
  - `internal/prompts`: persona/strategy order, `strategy: none`, runtime disk reads.
  - `internal/reviewer`: provider command construction, Gemini policy flag, timeout/non-zero handling, raw JSON schema validation, empty-stdout failure path.
  - `internal/aggregate`: `majority`, `all`, `any`, blocking findings, raw verdict normalization (D44).
  - `internal/anonymize`: deterministic peer IDs and provider/model scrubbing; D30 falsifiability cases.
  - `internal/state` and `internal/telemetry`: schema versioning, expected paths, event JSONL append.
- **Integration (`tests/integration/`)** — Cross-package end-to-end flows: spawn → wait → resolve; debate round 1→2 anonymization (with falsifiability test fixtures from D30); multi-instance roster spawning (`codex#1`, `codex#2`, `codex#3` mixed strategies); persona/strategy injection; default panel degradation on partial-availability host; custom roster rejection on missing CLI; Gemini policy enforcement (write tool blocked); generator flows for create-plan, create-spec, healthcheck, architecture-review.
- **Reviewer prompt size round-trip (D46)** — A `tests/integration/reviewer_largeprompt_test.go` case composes a ≥ 256 KB user prompt and pipes it through the reviewer subprocess (mock CLI) on darwin and linux; asserts no `E2BIG` / `argument list too long`, the mock receives the full prompt on stdin, the prompt's sha256 round-trips intact, and the canonical reviewer output JSON parses. Runs in the OS × host CI matrix.
- **Hook bootstrap end-to-end** — A test case boots a fresh worktree (no `bin/cerberus`), invokes the hook command directly via `sh -c "$COMMAND"`, asserts the binary builds and the hook runs.
- **Smoke (manual at GA)** — All 13 surviving skills on Claude and Codex with real `claude`/`codex`/`gemini` CLIs; verify launch checklist items in spec §4. Custom roster with at least three Codex models, one Gemini, and two Claude slots. `--debate` on Codex with mixed-provider and same-provider multi-instance panels.
- **Structural lint (CI)** — Zero `bin/*.sh`; no `task-completed-hook` / `teammate-idle-hook` references; `bin/cerberus` binary builds without Cgo on darwin × linux × amd64 × arm64; binary size ≤ 30 MB stripped on darwin-arm64 (D35).
- **Regression** — Surviving skills no longer reference `bin/review-gate`, `bin/generate`, `bin/review-gate-models.sh`, `bin/cerberus-skill-env`, or `REVIEW_GATE_*`. Run-team references absent from `skills/`, `hooks/`, `agents/`, `templates/`, and docs except migration notes. `templates/tasks-template.md`, create-tasks, and review-tasks remain present.

### CI Matrix (R6)

GitHub Actions workflow at `.github/workflows/ci.yml`:

```yaml
name: ci
on: [push, pull_request]
jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest]
        host: [claude, codex, generic]
    runs-on: ${{ matrix.os }}
    env:
      CERBERUS_HOST: ${{ matrix.host }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with: { go-version: '1.22' }
      - run: make build
      - run: make test
      - run: make lint                 # structural lint: zero bash, no run-team refs
  build-matrix:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
        arch: [amd64, arm64]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with: { go-version: '1.22' }
      - run: GOOS=$([ "${{ matrix.os }}" = "macos-latest" ] && echo darwin || echo linux) GOARCH=${{ matrix.arch }} go build -ldflags="-s -w" -tags netgo -o bin/cerberus.${{ matrix.os }}.${{ matrix.arch }} ./cmd/cerberus
      - run: |
          # D35 binary-size assertion (30 MB cap on darwin-arm64; 35 MB elsewhere)
          SIZE=$(stat -c%s bin/cerberus.${{ matrix.os }}.${{ matrix.arch }} 2>/dev/null || stat -f%z bin/cerberus.${{ matrix.os }}.${{ matrix.arch }})
          CAP=$([ "${{ matrix.os }}-${{ matrix.arch }}" = "macos-latest-arm64" ] && echo $((30*1024*1024)) || echo $((35*1024*1024)))
          if [ "$SIZE" -gt "$CAP" ]; then echo "binary size $SIZE exceeds cap $CAP"; exit 1; fi
```

**`make lint` enforces:**
- **Zero-bash structural check (compound):** allowlist `bin/` to contain ONLY the build artifact `bin/cerberus`. Reject any other tracked file under `bin/` (extension or no extension — extensionless entrypoints like the v1 `bin/review-gate`, `bin/codex-stop-hook`, `bin/cerberus-skill-env` would otherwise slip past a `*.sh`-only filter). Reject any file under `bin/` whose first line begins with `#!` followed by `sh`, `bash`, `dash`, `zsh`, or `env (sh|bash|dash|zsh)`. The compound check fails if either condition trips, even when only one disagrees (e.g., a non-cerberus file under `bin/` that happens to be shebang-free).
- Note: `bin/cerberus` itself is gitignored per D32, so the tracked-files check effectively requires `bin/` to be empty in the repo at GA. The build artifact appears only after `make build` runs locally; CI's `make build` step produces it inside the build job, then the lint job runs against the pre-build tracked set.
- `grep -RIl 'task-completed-hook\|teammate-idle-hook' skills hooks agents bin` is empty.
- Each surviving SKILL.md references `bin/cerberus` (and not `bin/review-gate-models.sh` or `bin/review-gate`).
- Both plugin manifests advertise `2.0.0` at GA tag.
- `prompts/host-neutral-bootstrap.md` shared resolver body matches the resolver region embedded in each surviving SKILL.md and in each hook `command` string in `hooks/{hooks,codex-hooks}.json` (drift detector for D25; per-caller `exec` lines are allowed to diverge — skill bootstraps use `exec "$bin" "$@"`, hook bootstraps use `exec "$bin" hook <name>` per D37).

### Mock CLI Strategy (D22 / D31)

Each mock at `tests/mocks/{claude,codex,gemini}/main.go` follows the same shape:

```go
// tests/mocks/<provider>/main.go (sketch)
func main() {
    // Real provider CLIs receive the user prompt via stdin (D46); the mock matches.
    promptBytes, _ := io.ReadAll(os.Stdin)
    prompt := string(promptBytes)
    instanceID := os.Getenv("CERBERUS_MOCK_INSTANCE_ID")   // injected by test orchestrator
    sum := sha256.Sum256([]byte(prompt))
    key := hex.EncodeToString(sum[:8]) + ":" + instanceID  // D31: instance-aware keying
    fxPath := filepath.Join(os.Getenv("CERBERUS_FIXTURE_DIR"), key+".json")
    body, err := os.ReadFile(fxPath)
    if err != nil {
        // Loud failure surfaces missing fixtures; prompt is captured for the developer to check in.
        capPath := fxPath + ".prompt.txt"
        _ = os.WriteFile(capPath, []byte(prompt), 0644)
        fmt.Fprintf(os.Stderr, "mock-%s: no fixture for prompt+instance; wrote %s\n", provider, capPath)
        os.Exit(2)
    }
    os.Stdout.Write(body)
}
```

**Fixture lifecycle.**
- `tests/fixtures/<provider>/<sha8>:<instance_id>.json` — canned reviewer output JSON, checked into the repo.
- `make fixtures-refresh` runs the real `claude`/`codex`/`gemini` CLIs against a known set of test prompts and writes/overwrites fixtures. Manual operation; not part of CI.
- `make test` invokes Go tests with `CERBERUS_FIXTURE_DIR` pointing at `tests/fixtures/<provider>/`.

**Why prompt-hash + instance-ID keying.** Reviewer output is deterministic given identical input prompts (modulo provider noise) — for unit/integration tests the mock can replay a frozen output. When a real CLI is upgraded or the reviewer prompt template changes, the hash changes, the mock fails loudly with the prompt written to disk, and the developer regenerates. Adding `instance_id` to the key (D31) supports debate's near-identical round-2 prompts across peers: two slots with identical prompts but different model versions need to return distinct verdicts.

**Out of scope.** Mocking debate-round-2 peer broadcasts is handled by the orchestrator integration test (which provides a synthetic anonymized broadcast and asserts the round-2 prompt incorporates it correctly). The mocks themselves do not need debate-aware behavior.

### Acceptance Criteria Coverage

| Spec Item | Plan Coverage |
|-----------|---------------|
| **R1** (single Go binary, zero `bin/*.sh`, lazy build) | Phase A scaffold + Phase F cleanup; structural lint in CI; D5 / D17 / D20 / D34 implement the bootstrap; binary-size assertion (D35). |
| **R2** (multi-instance / multi-version roster) | Phase B `internal/roster/`; D15 finalized YAML schema; CLI `--roster`, `--reviewer` (D36), `--replace-slot`, `--agents` (D42); `--consensus` (D43). |
| **R3** (unified debate path) | Phase C; `internal/orchestrator/` extension; `internal/aggregate/`, `internal/anonymize/`, and `internal/state/` (for `gate-state.json` I/O) are single sources of truth. R3's grep test bans duplicate DEFINITIONS outside those packages, but explicitly allows imports from `internal/orchestrator` and `*_test.go` files. |
| **R4** (Codex first-class) | Phase E `internal/hook/`; 13 surviving skills cross-host parity; D13/D39 default-roster degradation; Phase B early Codex smoke. |
| **R5** (strategies + personas) | Phase B `internal/prompts/`; on-disk Markdown read at runtime. |
| **R6** (CI matrix) | Phase G `.github/workflows/ci.yml` + structural lint + mock CLIs (D22, D31) + binary-size assertion (D35). |
| **R7** (env contract) | Phase A `internal/config/`; `CLAUDE_PLUGIN_ROOT` fallback for `CERBERUS_ROOT`. |
| **R8** (telemetry) | Phase B `internal/telemetry/`; D16 finalized schema; per-reviewer rows keyed on `<provider>#<index>`. |
| **R9** (debate anonymization) | Phase C `internal/anonymize/`; D30 algorithm + falsifiability tests; Gemini policy applied to every Gemini child (C5). |
| **R10** (dual plugin packaging) | Phase F manifests bumped to `2.0.0`; both manifests audited for run-team absence and `bin/cerberus` reference. |
| **S1** (skill parity) | Phase E + Phase G smoke tests on Codex. |
| **S2** (roster expressiveness) | Phase B + R2 verification cases. |
| **S3** (zero bash) | Phase F + structural lint. |
| **S4** (debate consolidation) | Phase C + R3 grep verification. |
| **S5** (cross-platform builds) | Phase G CI build matrix + binary-size cap. |
| **S6** (editable prompts) | C4 enforcement: `internal/prompts/` reads from disk every time; D40 prohibits embedded fallback in v2.0 GA. |
| **D6/D9** (run-team removal) | Scope, File Impact Summary, regression lint, docs updates. |
| **D7** (1-reviewer debate refusal) | Preflight design + integration test, including degraded-default case (D39). |
| **D13** (default vs custom degradation) | Roster preflight design + host availability tests (D39 makes this distinction explicit). |

### Monitoring / Observability
- Inspect `event-log.jsonl` for run lifecycle: build/preflight/reviewer/debate/resolve/hook events.
- Inspect per-reviewer `telemetry.json` for token/cost/timing per slot.
- Inspect `iterations/<N>/round-<R>/round-telemetry.json` for round-level rollups.
- Inspect `run-telemetry.json` for run-level rollup.
- Confirm preflight failures emit `cerberus.preflight.failed` with file path + slot index.
- Confirm reviewer lifecycle emits `cerberus.reviewer.{spawned,completed,failed}` with `reviewer_id` and `instance_index`.
- Confirm hook block/allow events emit `cerberus.hook.{blocked,allowed}` for active and empty gates.

## Spec/Legacy Fidelity

The plan follows the spec's hard simplification mandate: v2 is a clean rewrite, not a byte-parity port. It preserves surviving user-visible review/generator/status workflows while intentionally removing v1's defensive fault-tolerance accretions and Claude-only team automation. No re-introduction of v1 fault-tolerance accretions. Decision Log records each autonomous decision with rationale, evidence, and risk/follow-up.

### Deviation Log

| Source | Deviation | Rationale | Approved? |
|--------|-----------|-----------|-----------|
| Legacy v1 behavior | No JSON repair, fail-open hooks, mid-debate degradation, state migration, env alias chains, or byte parity | Explicit hard simplification mandate for v2.0 | Yes — spec/context mandate |
| `docs/2026-05-08-rebuild-spec.md` D2 stale wording about byte parity (if any) | Plan does not preserve byte parity | Conflicts with the same spec's simplification mandate and current implementation target | Yes — simplification mandate controls |
| v1 `create-tasks --agent-team` behavior | Removed | Depends on removed run-team surface and `templates/team-tasks-template.md` | Yes — D6/D9/D41 cascade |

The plan adds detail (concrete YAML/JSON schemas, hook bootstrap strings, lazy-build pseudocode, anonymization algorithm, CI workflow shape, binary-size assertion) but does not deviate from any spec-binding decision. Spec D1–D13 are restated as inputs; plan-phase D14–D45 fill the spec's deferrals (D12 schema, R8 schema, R1 hook bootstrap, R9 anonymization, etc.) without changing scope.

## Open Questions

- **Q7** (carried from spec) — Persona/strategy + reviewer prompt context overflow. Plan-phase default per D24: log warning + proceed; reviewer CLI handles its own truncation. **Reaffirmed; not opening a separate plan-phase question.**
- **Q14** (carried from spec) — K* / αK telemetry. v2.x candidate. **Out of scope for v2.0 GA; tracked in TODO.md.**
- **Q15** (carried from spec) — Sparsification (CortexDebate / S²-MAD). v2.x candidate. **Out of scope for v2.0 GA; tracked in TODO.md.**
- **OQ-Plan-1 — Provider CLI flag drift.** The reviewer-subprocess section assumes specific flag names (`--print --output-format json --append-system-prompt` for Claude; `--json --model --append-system-prompt` for Codex; `--policy-file` for Gemini). If upstream CLIs have renamed any of these in the months since v1 was last updated, Phase B implementation discovers the actual flags and a Decision-Log row pins them. *Not a blocking question for plan approval.*
- **OQ-Plan-2 — Mock fixture freshness in CI.** If a reviewer prompt is edited in `prompts/reviewers/*.md`, every fixture keyed on the old prompt hash is stale. The plan-phase default is loud-fail (mock prints "no fixture for prompt") so the developer notices and runs `make fixtures-refresh`. If this becomes a frequent friction in practice, a `make fixtures-stale-check` could compute prompt hashes ahead of test runs and warn. *Defer to v2.x if friction emerges.*
- **OQ-Plan-3 — Codex hook payload/root contract.** Current repo evidence uses `PLUGIN_ROOT`; Phase E must validate stdin payload shape and root env behavior against the installed Codex CLI. If the contract differs, a Decision-Log row pins it. *Not a blocking question for plan approval.*
- **OQ-Plan-4 — Concurrent runs in the same project.** Per D29, v2.0 GA does not lock `gate-state.json`. If real users hit clobber regularly, add advisory-lock infrastructure in v2.x. *Defer.*
- **OQ-Plan-5 — Anonymization sophistication.** D30's free-text scrub is heuristic; identity leaks via writing style or citation patterns are not addressed. If debate runs show sycophancy drift in practice, revisit with a more linguistically aware scrub. *Defer to v2.x.*
- **OQ-Plan-6 — `bin/update-plugin` replacement ergonomics.** D26 routes maintainer workflow to `make install`. If this turns out to be friction, consider a `cerberus dev install` subcommand. *Defer.*

## Next Steps

After this plan is approved, run `/cerberus:create-tasks --from-plan docs/2026-05-08-rebuild-plan.md`:
- `--beads` → Beads issues with dependencies for the eight phases (A–H), suitable for multi-agent execution if desired.
- (default) → `TODO.md`-style checklist for tracking by the sole maintainer.
