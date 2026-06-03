# TODO: Multi-Agent Debate for Cerberus Reviews

**Generated**: 2026-04-25
**Plan**: [`docs/2026-04-25-debate-plan.md`](2026-04-25-debate-plan.md)
**Spec**: [`docs/2026-04-25-debate-spec.md`](2026-04-25-debate-spec.md)
**Output mode**: TODO.md (Beads CLI not available locally; fallback per `/cerberus:create-tasks` workflow). Convert to Beads later via `br create` once installed.

## Task Summary

| Phase | Tasks | Parallel | Notes |
|---|---|---|---|
| Setup (Phase A) | T001–T002 | 0 | Pre-feature golden capture is a hard gate — must land BEFORE any prompt or `bin/review-gate` edit |
| Foundation (Phase B) | T003–T006 | T004 ∥ T005 | Flag plumbing, preflight, `spawn_reviewer` output-dir param. Non-debate path stays byte-stable |
| US1 — Strategy + Confidence (Phase C) | T007–T011 | T007 ∥ T009 | Strategy assets + template placeholders + bin/review-gate emission glue |
| US2 — Coordinator + Round 1 (Phase D) | T012–T015 | none | Synchronous coordinator + Round 1 path lights up |
| US3 — Anonymization + Full Debate (Phase E) | T016–T022 | none (serialized on `bin/review-gate-debate.sh`) | Anonymization, Round 2/3, dedup aggregator, verdict |
| Polish (Phase F) | T023–T028 | T023 ∥ T024 ∥ T026 | Gate report, telemetry, exit codes, docs, E2E smoke, launch checklist |
| **Total** | **28** | | One epic suggested at top (E001) |

## Conventions

- **Type**: `task` (Beads). Manual checklist items are still `task`-typed.
- **Subsystems**: `review-gate` (`bin/review-gate`, `bin/review-gate-models.sh`, `bin/review-gate-debate.sh`), `hook` (`bin/review-gate-hook.sh`), `telemetry` (`bin/telemetry-lib.sh`, iteration helpers), `prompts` (`prompts/strategies`, `prompts/reviewers`), `tests` (`bin/tests`), `docs` (`README.md`, in-binary `--help` text).
- **`[integration-path-test]`** marks the per-feature task whose verification exercises `bin/review-gate spawn` end-to-end against canned reviewer outputs.
- **`[system-wiring]`** marks the task that wires the new debate path into the existing `spawn` flow (conditional source + flag → coordinator decision + schema variant emission).
- **`[P]`** in titles = parallelizable with peers in the same phase.

---

## Phase A — Pre-feature Golden Capture (HARD GATE)

> Phase A MUST land BEFORE any prompt or `bin/review-gate` edit. The R9 byte-parity tests depend on these fixtures; capturing them after debate code lands defeats the purpose.

### - [ ] **T001** Capture pre-feature golden fixtures

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P1
**Story**: Phase A (foundation)
**Parallel**:
**Primary Files**: `bin/tests/capture-pre-debate-baseline.sh` (New), `bin/tests/fixtures/pre-debate-baseline/` (New, populated by script)
**Subsystems**: tests
**Dependencies**:

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L128-L134](2026-04-25-debate-plan.md#L128-L134) — Section: Prerequisites (Step 0 launch-checklist gate)
- Plan: [docs/2026-04-25-debate-plan.md#L140](2026-04-25-debate-plan.md#L140) — Section: High-Level Approach, Phase A
- Plan: [docs/2026-04-25-debate-plan.md#L262](2026-04-25-debate-plan.md#L262) — Section: File Impact Summary (`bin/tests/capture-pre-debate-baseline.sh`)
- Plan: [docs/2026-04-25-debate-plan.md#L386-L387](2026-04-25-debate-plan.md#L386-L387) — Section: Resolved Design Decisions D9–D10
- Spec: [docs/2026-04-25-debate-spec.md#L425](2026-04-25-debate-spec.md#L425) — Section 4 launch checklist (canonical anchor file)

**Goal**: Capture pre-feature CLI/JSON/prompt artifacts for all five invocation shapes against the current plugin version, so post-feature non-debate runs can be `cmp`-asserted byte-identical.

**Context**: R9 byte-parity is the headline guarantee. Without a frozen pre-feature snapshot, "byte-parity" cannot be verified. Per D10, the capture script reads existing `$REVIEWS_DIR/<reviewer>.prompt` files (already persisted by `bin/review-gate-models.sh:670-742`) — no production-code change to the prompt builder is required.

**Scope**:
- In: New script `bin/tests/capture-pre-debate-baseline.sh`. New fixture directory `bin/tests/fixtures/pre-debate-baseline/` populated by the script. README inside fixture dir documenting the captured `--mode` (recommended: `smart`).
- Out: Post-feature edits to `bin/review-gate` or prompts (those land in Phase B+). New env vars in production binary (D10 says no).

**Changes**:
- `bin/tests/capture-pre-debate-baseline.sh` — New — runs each of the 5 invocation shapes (`spawn`, `spawn-code-review`, `spawn-plan-review`, `spawn-spec-review`, `spawn-epic-verify`) against canned reviewer outputs (existing test pattern). Copies CLI stdout/stderr, per-reviewer `reviews/<reviewer>.json`, `review-schema.json`, `gate-state.json` post-Stop-hook, rendered reviewer prompts (`<reviewer>.prompt`), `iteration.txt`, gate-report markdown, and optional author-context state into versioned subdirectories of `bin/tests/fixtures/pre-debate-baseline/`.
- `bin/tests/fixtures/pre-debate-baseline/` — New — captured artifacts + a `README.md` documenting which `--mode` was used and how to re-run capture.

**Acceptance Criteria**:
1. Script populates fixture dir with all 8 artifacts × 5 invocation shapes against the current plugin version, deterministically (re-running produces byte-identical output).
2. Fixture directory `README.md` records the `--mode` choice, plugin version SHA, capture date, and the exact canned reviewer-output JSONs used.
3. The captured fixtures are ready to be consumed by T002 (byte-parity test) without further manipulation.

**Verification**:
- Run the script twice; `diff -r` between the two outputs must be empty.
- Manually inspect a captured `<reviewer>.prompt` and verify it matches what `bin/review-gate` would render today.

**Notes for Agent**:
- Use the existing temp-HOME + mock-state + canned-reviewer-output test pattern (see `bin/tests/test-review-gate-spawn-no-setsid.sh` for shape).
- Do NOT add a new env-var hook to the prompt builder — D10 explicitly forbids it.
- Pin the plugin version SHA in the fixture README so re-baselining is traceable.
- Capture machinery is test-time only (D9) — does not ship with the production binary past Step 0.

</details>

### - [ ] **T002** [integration-path-test] Byte-parity regression test scaffold

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P1
**Story**: Phase A (foundation)
**Parallel**:
**Primary Files**: `bin/tests/test-debate-byte-parity.sh` (New)
**Subsystems**: tests
**Dependencies**: T001

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L266](2026-04-25-debate-plan.md#L266) — Section: File Impact Summary (`bin/tests/test-debate-byte-parity.sh`)
- Plan: [docs/2026-04-25-debate-plan.md#L295](2026-04-25-debate-plan.md#L295) — Section: Risks (byte-parity regression mitigation)
- Plan: [docs/2026-04-25-debate-plan.md#L334](2026-04-25-debate-plan.md#L334) — Section: AC Coverage (byte-parity for valid non-debate invocations)
- Spec: [docs/2026-04-25-debate-spec.md#L287-L302](2026-04-25-debate-spec.md#L287-L302) — Section: R9 Backwards-compatible CLI surface

**Goal**: Stand up the R9 byte-parity test suite that `cmp`-asserts each captured pre-debate-baseline artifact byte-identical to a fresh post-Phase-A run. Initially passes trivially (no debate code has landed); becomes the regression net for Phases B–F.

**Context**: This is the integration-path-test for Phase A. It runs `bin/review-gate spawn[-*-review]` end-to-end against the same canned reviewer-output fixtures used in T001 and asserts byte-equality of every captured artifact.

**Scope**:
- In: One new test script `bin/tests/test-debate-byte-parity.sh` that drives all 5 invocation shapes and compares against `bin/tests/fixtures/pre-debate-baseline/`.
- Out: Schema-variant testing (Phase D, T013 + T011); Phase B preflight tests (T006).

**Changes**:
- `bin/tests/test-debate-byte-parity.sh` — New — for each of 5 invocation shapes: run `bin/review-gate spawn[-*-review]` against canned reviewer outputs in a temp HOME; `cmp` each post-run artifact (CLI stdout/stderr, `reviews/<reviewer>.json`, `review-schema.json`, `gate-state.json`, rendered prompts, `iteration.txt`, gate-report markdown) against the corresponding fixture under `pre-debate-baseline/`. Emit one `FAIL: <artifact> diverged` line per mismatch and exit non-zero.

**Acceptance Criteria**:
1. Test passes on the current branch before any debate-related edit lands (trivially because the captured fixtures match a fresh re-run).
2. Test fails with a clear diff line if any byte of any captured artifact diverges.
3. Test runs in under 60 seconds locally (uses canned reviewer outputs, not real model calls).

**Verification**:
- Invoke `bash bin/tests/test-debate-byte-parity.sh` against current `main` — must exit 0.
- Mutate one captured fixture (e.g., add a trailing newline to a `<reviewer>.prompt`) and re-run — test must exit non-zero with diff naming the divergent artifact.

**Notes for Agent**:
- Use `cmp -s` (silent) for the byte comparison; emit human-readable diffs only on failure.
- Skip mutable timestamp fields by either filtering them in fixtures (e.g., `iso8601 -> __TIMESTAMP__` substitution) or by `jq`-projecting non-timestamp fields. Document the policy in the test header.
- This test is the [integration-path-test] for Phase A — it exercises `bin/review-gate spawn` end-to-end through the existing detached-spawn path.

</details>

---

## Phase B — Plumbing (flag, preflight, output-dir param)

> All Phase B work preserves byte-parity for non-debate invocations. Run T002 after each Phase B change.

### - [ ] **T003** Flag parsing for `--debate` and `--debate-seed N`

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P1
**Story**: Phase B (US1 plumbing)
**Parallel**:
**Primary Files**: `bin/review-gate` (Exists, modify)
**Subsystems**: review-gate
**Dependencies**: T002

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L96](2026-04-25-debate-plan.md#L96) — Section: Integration Analysis (flag-parsing block lines 2128-2202)
- Plan: [docs/2026-04-25-debate-plan.md#L142](2026-04-25-debate-plan.md#L142) — Section: High-Level Approach, Phase B
- Plan: [docs/2026-04-25-debate-plan.md#L243-L249](2026-04-25-debate-plan.md#L243-L249) — Section: API/Interface Design (CLI surface)
- Plan: [docs/2026-04-25-debate-plan.md#L279](2026-04-25-debate-plan.md#L279) — Section: File Impact Summary (`bin/review-gate`)
- Spec: [docs/2026-04-25-debate-spec.md#L287-L302](2026-04-25-debate-spec.md#L287-L302) — Section: R9 Backwards-compatible CLI surface

**Goal**: Add `--debate` (boolean) and hidden `--debate-seed N` (integer) flag parsing to bare `spawn` and the four named subcommands (`spawn-code-review`, `spawn-plan-review`, `spawn-spec-review`, `spawn-epic-verify`). Both flags are accepted but inert — parsed into shell variables, no behavior change yet.

**Context**: This is the first edit to `bin/review-gate` and the start of the Phase B byte-parity-preserving work. Subsequent Phase B tasks (T004 preflight, T011 emission glue) extend the same `case` blocks and depend on this task.

**Scope**:
- In: Two new flags accepted on bare `spawn` and 4 named subcommands. Hidden `--debate-seed N` parses but is otherwise no-op when `--debate` is absent. Variables exposed to downstream code paths: `DEBATE` (`""` or `"1"`), `DEBATE_SEED` (`""` or decimal-string).
- Out: Help text (T011), preflight gates (T004), schema variant (T011), coordinator wiring (T011/T012).

**Changes**:
- `bin/review-gate` (lines ~2128-2202 in `spawn`, plus the four named subcommand wrappers) — Exists — add `--debate` and `--debate-seed N` cases to each `case` block; populate `DEBATE` and `DEBATE_SEED` shell variables; pass them through any recursion / sub-call boundaries unchanged.

**Acceptance Criteria**:
1. `bin/review-gate spawn --debate --type code [valid args]` exits 0 (the flag is accepted; falls through to existing detached spawn path because no preflight or coordinator wiring exists yet).
2. `bin/review-gate spawn --debate-seed 42 --type code [valid args]` exits 0 (no-op when `--debate` absent — accepted and ignored).
3. **Byte-parity**: T002 (byte-parity regression test) still passes — invocations that do NOT pass `--debate` produce byte-identical artifacts to the pre-debate-baseline.

**Verification**:
- Invoke `bin/review-gate spawn --debate --type code [valid args]` and `bin/review-gate spawn-code-review --debate [args]`; assert exit 0.
- Run `bash bin/tests/test-debate-byte-parity.sh` — must still pass.
- **Negative case**: `bin/review-gate spawn --debate-seed not-a-number` should reject (exit non-zero) with a clear stderr message naming the bad value.
- **Negative case**: `bin/review-gate spawn --debate-seed -1` rejected (D11: non-negative integers only).

**Notes for Agent**:
- Bash 3.2 compatibility — no associative arrays, no `${var,,}` lowercasing.
- The `--debate-seed` flag is HIDDEN — must not appear in `--help` output (T011 owns help text). Document this in the case-block comment.
- Per D11, seed value space is "any non-negative integer rendered as decimal string". No 32-bit constraint.

</details>

### - [ ] **T004** [P] Preflight gates (whitelist + `<2 reviewers` hard error)

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P1
**Story**: Phase B
**Parallel**: [P] (different code section than T005; sequential with T003 on `bin/review-gate`)
**Primary Files**: `bin/review-gate` (Exists, modify)
**Subsystems**: review-gate
**Dependencies**: T003

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L142](2026-04-25-debate-plan.md#L142) — Section: High-Level Approach, Phase B (whitelist + <2 reviewer preflight)
- Plan: [docs/2026-04-25-debate-plan.md#L196-L211](2026-04-25-debate-plan.md#L196-L211) — Section: Architecture (pinned exit codes + degraded-below-2 on-disk shape)
- Plan: [docs/2026-04-25-debate-plan.md#L376-L380](2026-04-25-debate-plan.md#L376-L380) — Section: D6 (reserved exit codes)
- Spec: [docs/2026-04-25-debate-spec.md#L48](2026-04-25-debate-spec.md#L48) — Section: Bare-spawn debate whitelist
- Spec: [docs/2026-04-25-debate-spec.md#L303-L313](2026-04-25-debate-spec.md#L303-L313) — Section: R10 Per-review-type applicability
- Spec: [docs/2026-04-25-debate-spec.md#L121](2026-04-25-debate-spec.md#L121) — Section: Section 2 alternate flow (bare spawn whitelist rejection)

**Goal**: Reject `--debate` at preflight when (a) bare `spawn` is invoked with `--type` outside `{code, plan, spec, epic-verify}` (R10 whitelist), or (b) the resolved reviewer set has fewer than 2 reviewers. Both rejections happen BEFORE any model is invoked.

**Context**: D6 reserves exit code `2` for whitelist rejection (existing preflight error pattern) and exit code `6` for degraded-below-2 (new). Whitelist rejection MUST stderr-name the rejected `--type` and the four allowed values per R10.

**Scope**:
- In: Two preflight checks in `bin/review-gate` after flag parsing (T003) and after agent resolution.
- Out: Mid-debate degraded-below-2 eligibility check (Phase E, T020); manual launch-checklist coverage (T028).

**Changes**:
- `bin/review-gate` (preflight section, after flag parsing and agent resolution) — Exists — add (1) `if [[ -n "$DEBATE" ]] && [[ <bare-spawn> ]] && [[ "$REVIEW_TYPE" not in whitelist ]]; then echo to stderr; exit 2; fi`; (2) `if [[ -n "$DEBATE" ]] && [[ ${#AGENT_LIST[@]} -lt 2 ]]; then write gate-state.awaiting_decision + consensus.requires_decision per D6; exit 6; fi`. Also assert these gates fire BEFORE any reviewer template is rendered or any model invoked.

**Acceptance Criteria**:
1. `bin/review-gate spawn --debate --type create-tasks [args]` exits 2 with stderr naming `create-tasks` and the four allowed types `code, plan, spec, epic-verify`.
2. `bin/review-gate spawn-code-review --debate --agents codex [args]` (only one reviewer) exits 6 with stderr `debate degraded below 2 active reviewers in the final peer round` (or the analogous preflight variant), and `gate-state.json.status="awaiting_decision"` with `consensus.verdict="requires_decision"` per D6.
3. **Byte-parity**: invocations without `--debate` produce byte-identical artifacts to baseline (T002 passes).

**Verification**:
- Add tests to `bin/tests/test-debate-preflight.sh` (created in T006) covering whitelist positive cases (`code`, `plan`, `spec`, `epic-verify`) and negative cases (`create-tasks`, `manual`, `auto`).
- **Negative case**: `--debate` with bare `spawn --type epic-verify` (whitelisted) but `--agents claude` (only one) → exit 6, on-disk shape per D6.
- **Negative case**: `--debate` with bare `spawn --type manual` and 3 reviewers → exit 2 (whitelist fires before <2 check; whitelist is more specific).

**Notes for Agent**:
- The four named `spawn-*-review` subcommands always carry a whitelisted `--type` implicitly — they should NOT trigger the whitelist rejection.
- The on-disk shape for exit 6 (D6) writes `gate-state.json.status="awaiting_decision"` AND `gate-state.json.consensus={"verdict":"requires_decision","reason":"...","iteration":<n>}`. This is distinct from cancellation/aggregator-failure (those leave `status="pending"`). Get this right — see Plan L202 and L379.
- The canonical `$REVIEWS_DIR` MUST be left empty in the exit-6 case.

</details>

### - [ ] **T005** [P] `spawn_reviewer` optional output-directory parameter

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P1
**Story**: Phase B
**Parallel**: [P] (different file: `bin/review-gate-models.sh`)
**Primary Files**: `bin/review-gate-models.sh` (Exists, modify)
**Subsystems**: review-gate
**Dependencies**: T003

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L101](2026-04-25-debate-plan.md#L101) — Section: Integration Analysis (spawn_reviewer reuse)
- Plan: [docs/2026-04-25-debate-plan.md#L280](2026-04-25-debate-plan.md#L280) — Section: File Impact Summary (`bin/review-gate-models.sh` Phase B deliverable)
- Plan: [docs/2026-04-25-debate-plan.md#L370-L374](2026-04-25-debate-plan.md#L370-L374) — Section: D4 (synchronous launch + per-round staging)
- Spec: [docs/2026-04-25-debate-spec.md#L373-L374](2026-04-25-debate-spec.md#L373-L374) — Section 4 (per-round staging dir referenced by terminal-abstention semantics; consumed by Option B)

**Goal**: Add an optional output-directory parameter to `spawn_reviewer` (today's signature in `bin/review-gate-models.sh:620-745` writes outputs into `$REVIEWS_DIR` directly). Default — no override — keeps every byte of the non-debate path identical to today. Override redirects `<reviewer>.json`, `<reviewer>.done`, `<reviewer>.failed` and the rendered `<reviewer>.prompt` into the supplied directory.

**Context**: D4 mandates per-round staging directories under `iterations/<iter>/round-N/` for the debate path so the canonical `$REVIEWS_DIR` is left empty until after aggregation succeeds. The coordinator (T012) calls `spawn_reviewer` with this override; non-debate callers continue to pass nothing.

**Scope**:
- In: New optional positional or named parameter on `spawn_reviewer`. Default behavior byte-identical to today.
- Out: Coordinator wiring (T012); telemetry path additions (T024).

**Changes**:
- `bin/review-gate-models.sh:620-745` — Exists — add an optional `output_dir` parameter (recommended: 7th positional arg defaulting to empty / `$REVIEWS_DIR`). When set, route `<reviewer>.json`, `<reviewer>.done`, `<reviewer>.failed`, `<reviewer>.prompt`, plus any other per-call sentinels/temp files into `<output_dir>/` instead of `$REVIEWS_DIR/`. When unset (default), behavior MUST be byte-identical to today.

**Acceptance Criteria**:
1. `spawn_reviewer` called without override writes outputs into `$REVIEWS_DIR/` exactly as today.
2. `spawn_reviewer` called with `output_dir=/tmp/foo` writes outputs into `/tmp/foo/` and writes nothing into `$REVIEWS_DIR/`.
3. **Byte-parity** regression: T002 still passes (default-path byte-identical).

**Verification**:
- Add a unit test in `bin/tests/test-debate-byte-parity.sh` (or a new helper test) that drives `spawn_reviewer` with no override and `cmp`s outputs against a captured baseline.
- Add a unit test that drives `spawn_reviewer` with an override and asserts canonical `$REVIEWS_DIR` is untouched.
- **Negative case**: `spawn_reviewer` called with a non-existent override directory should fail-fast with a clear error, not silently fall back to `$REVIEWS_DIR`.

**Notes for Agent**:
- Bash 3.2 compatibility — use positional arg with default `=${7:-}`, not Bash-4 `${var:-}` inside an associative array.
- The `<reviewer>.prompt` file is what `bin/review-gate-models.sh:670-742` reads via `< "$REVIEW_PROMPT"`; the override must redirect both the write side and the read side consistently.
- Keep the parameter ordering compatible with existing call sites — Phase B should not require touching every existing `spawn_reviewer` invocation.

</details>

### - [ ] **T006** [integration-path-test] Phase B byte-parity + preflight tests

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P1
**Story**: Phase B
**Parallel**:
**Primary Files**: `bin/tests/test-debate-preflight.sh` (New)
**Subsystems**: tests
**Dependencies**: T003, T004, T005

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L267](2026-04-25-debate-plan.md#L267) — Section: File Impact Summary (`bin/tests/test-debate-preflight.sh`)
- Plan: [docs/2026-04-25-debate-plan.md#L336-L338](2026-04-25-debate-plan.md#L336-L338) — Section: AC Coverage (whitelist + <2 reviewers + help-output coverage)
- Plan: [docs/2026-04-25-debate-plan.md#L354](2026-04-25-debate-plan.md#L354) — Section: AC Coverage (help-output asserts --debate documented, --debate-seed hidden)
- Spec: [docs/2026-04-25-debate-spec.md#L303-L313](2026-04-25-debate-spec.md#L303-L313) — Section: R10 Per-review-type applicability

**Goal**: Land `bin/tests/test-debate-preflight.sh` covering R10 whitelist rejection, the `<2 reviewers` hard error, `--debate-seed N` no-op behavior under `--debate` absent, and (forward-looking) help-output coverage stub. Re-run T002 byte-parity after Phase B to confirm regressions clean.

**Context**: This is the [integration-path-test] for Phase B. It drives `bin/review-gate spawn[-*-review]` end-to-end at the preflight surface and asserts both the negative (rejection) and positive (acceptance) paths.

**Scope**:
- In: New test script. Re-run of T002 byte-parity test (no script change, just confirmation).
- Out: Help-output assertions (extended in T011 / T026 once `--help` text is finalized).

**Changes**:
- `bin/tests/test-debate-preflight.sh` — New — covers (a) R10 whitelist: each non-judging type rejected with exit 2; each judging type accepted; (b) `<2 reviewers + --debate` exit 6 with on-disk shape per D6; (c) `--debate-seed N` no-op when `--debate` absent (T002 byte-parity asserts the artifact bytes).

**Acceptance Criteria**:
1. Whitelist tests: `bin/review-gate spawn --debate --type X` for `X ∈ {create-tasks, manual, auto}` each exit 2 with stderr naming `X` and the four allowed types.
2. `<2 reviewers` tests: each named subcommand with `--debate --agents <single>` exits 6 with on-disk shape per D6.
3. **Byte-parity preservation**: `--debate-seed` no-op (`bin/review-gate spawn --debate-seed 42 --type code [args]` produces byte-identical artifacts to the same invocation without `--debate-seed`, asserted via inline `cmp`); T002 byte-parity regression test still passes after Phase B's edits.

**Verification**:
- Run the test suite locally; all cases pass.
- Mutate one preflight check (e.g., remove the whitelist alphabetical sort in the error message) and confirm the test catches it.

**Notes for Agent**:
- Parameterize test cases via a Bash array of `(type, expected_exit_code, expected_stderr_substring)` tuples; iterate.
- Keep test cases independent — each runs in its own temp HOME.
- Cross-platform note: BSD/GNU `grep -E` consistency; tests run on both macOS CI and Linux CI.

</details>

---

## Phase C — Strategy + Confidence Assets

### - [ ] **T007** [P] Strategy directive + confidence anchor markdown files

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P2
**Story**: Phase C (US1 strategy)
**Parallel**: [P] (independent of `bin/review-gate` chain)
**Primary Files**: `prompts/strategies/confidence-anchors.md` (New), `prompts/strategies/verification-first.md` (New), `prompts/strategies/falsification-first.md` (New), `prompts/strategies/decompose.md` (New)
**Subsystems**: prompts
**Dependencies**: T002

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L257-L260](2026-04-25-debate-plan.md#L257-L260) — Section: File Impact Summary (4 new strategy files)
- Plan: [docs/2026-04-25-debate-plan.md#L381-L384](2026-04-25-debate-plan.md#L381-L384) — Section: D7 (strategy directive prose intents)
- Spec: [docs/2026-04-25-debate-spec.md#L174-L198](2026-04-25-debate-spec.md#L174-L198) — Section: R2 Calibrated confidence elicitation (canonical anchor block reproduced verbatim)
- Spec: [docs/2026-04-25-debate-spec.md#L199-L211](2026-04-25-debate-spec.md#L199-L211) — Section: R3 Strategy diversity
- Spec: [docs/2026-04-25-debate-spec.md#L370](2026-04-25-debate-spec.md#L370) — Section 4 (strategy-directive asset location)

**Goal**: Land the four canonical asset files: `confidence-anchors.md` (byte-identical to R2 fenced literal in spec L179-L198) and three strategy directives (`verification-first.md`, `falsification-first.md`, `decompose.md`) following the D7 prose intents.

**Scope**:
- In: 4 new files under `prompts/strategies/`.
- Out: Reviewer template placeholder injection (T008); substitution logic (T011).

**Changes**:
- `prompts/strategies/confidence-anchors.md` — New — contents byte-identical to the spec's R2 fenced literal (lines L179-L198 of the spec, exclusive of the fence markers themselves). LF line endings only, no trailing whitespace, no leading or trailing blank line.
- `prompts/strategies/verification-first.md` — New — directive per D7: "treat the artifact as plausibly correct, walk through its claims and verify each holds with cited evidence, reserve highest-priority findings for breakdowns where the evidence does NOT hold."
- `prompts/strategies/falsification-first.md` — New — directive per D7: "treat the artifact as plausibly wrong, find concrete counterexamples, reserve highest-priority findings for cases demonstrable with evidence — adversarial-without-evidence is uninformative."
- `prompts/strategies/decompose.md` — New — directive per D7: "decompose the artifact into constituent parts (sections / subsystems / requirements), judge each on its own merits, surface findings at the granularity of the part rather than the artifact level."

**Acceptance Criteria**:
1. `prompts/strategies/confidence-anchors.md` is byte-identical to the canonical anchor block (verifiable by `cmp` against an extract of the spec's fenced literal).
2. The three strategy directive files exist with prose anchored on the D7 intents (~3-5 sentences each).
3. All four files use LF line endings, no trailing whitespace, no UTF-8 BOM.

**Verification**:
- `cmp prompts/strategies/confidence-anchors.md <(awk 'NR>=180 && NR<=198' docs/2026-04-25-debate-spec.md)` (or equivalent) — must succeed.
- T010 (R2/R3/R10 fixture tests) consumes these files; passing T010 is downstream verification.

**Notes for Agent**:
- The `confidence-anchors.md` BYTES are pinned by R2 (spec L174-L198). Do NOT reword. The launch checklist (spec L425) explicitly verifies byte-identicality.
- Strategy directives ARE implementation-discretion under D7 — anchor the intent, but the exact wording is yours. Aim for ~3-5 sentences. Avoid adversarial-without-evidence phrasing in `falsification-first.md` (mitigation per Plan L301).

</details>

### - [ ] **T008** Inject placeholders into reviewer templates

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P2
**Story**: Phase C
**Parallel**:
**Primary Files**: `prompts/reviewers/code.md` (Exists, modify), `prompts/reviewers/plan.md` (Exists, modify), `prompts/reviewers/spec.md` (Exists, modify), `prompts/reviewers/epic-verify.md` (Exists, modify)
**Subsystems**: prompts
**Dependencies**: T007

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L284-L287](2026-04-25-debate-plan.md#L284-L287) — Section: File Impact Summary (4 reviewer templates)
- Plan: [docs/2026-04-25-debate-plan.md#L367-L368](2026-04-25-debate-plan.md#L367-L368) — Section: D2 (placement convention, line consumption)
- Spec: [docs/2026-04-25-debate-spec.md#L370](2026-04-25-debate-spec.md#L370) — Section 4 (strategy-directive asset location)

**Goal**: Inject two new placeholders — `${CONFIDENCE_ANCHORS}` and `${STRATEGY_DIRECTIVE}` — into each of the four reviewer templates. Each placeholder occupies its own line including the trailing newline (per D2). Substitution logic lands in T011.

**Context**: D2 pins the placement convention so that `--debate` absent + line-consuming substitution = byte-identical to today's templates. The placeholder must be on its own line including trailing LF.

**Scope**:
- In: 4 template files modified at consistent placeholder locations. No bytes ADDED to the rendered template under `--debate` absent (line-consumption is verified in T011).
- Out: Substitution logic (T011); R2 byte-equality verification (T010).

**Changes** (mechanical sweep; same 2-line addition per file):
- `prompts/reviewers/code.md` — Exists — insert `${CONFIDENCE_ANCHORS}\n` and `${STRATEGY_DIRECTIVE}\n` placeholders on their own lines at agreed-upon locations (e.g., after the role/role-frame section, before the artifact body).
- `prompts/reviewers/plan.md` — Exists — same placement.
- `prompts/reviewers/spec.md` — Exists — same placement.
- `prompts/reviewers/epic-verify.md` — Exists — same placement.

**Acceptance Criteria**:
1. All four templates contain both placeholders on their own line at consistent (cross-template) offsets — verified by a `grep` or `awk` line-number check.
2. The placeholder lines include the trailing newline byte (LF) so D2's line-consumption substitution can byte-erase the placeholder + its newline together.
3. **Byte-parity (deferred to T011)**: T002 byte-parity will assert that under `--debate` absent + T011's substitution, the rendered prompt is byte-identical to a template that never had the placeholder.

**Verification**:
- `awk` script verifies each template has both placeholders at consistent line offsets (e.g., placeholder lines are 5-10 lines apart).
- T002 byte-parity test continues to pass (this task alone does not change rendered bytes — substitution logic in T011 is what consumes the line).

**Notes for Agent**:
- This is a **mechanical sweep** — same 2-line change in 4 files. Stay within 1 subsystem.
- Place `${CONFIDENCE_ANCHORS}` BEFORE `${STRATEGY_DIRECTIVE}` so prompts read "calibration block then strategy directive."
- Do NOT add a leading or trailing blank line around the placeholders — they must be line-consumed cleanly under `--debate` absent.

</details>

### - [ ] **T009** [P] Strategy assignment skeleton in `bin/review-gate-debate.sh`

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P1
**Story**: Phase C
**Parallel**: [P] (new file, no overlap with `bin/review-gate` chain yet)
**Primary Files**: `bin/review-gate-debate.sh` (New, partial)
**Subsystems**: review-gate
**Dependencies**: T002

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L66](2026-04-25-debate-plan.md#L66) — Section: Implementation Constraints (`shasum -a 256` preferred, `sha256sum` fallback, hard-error if neither)
- Plan: [docs/2026-04-25-debate-plan.md#L144](2026-04-25-debate-plan.md#L144) — Section: High-Level Approach, Phase C
- Plan: [docs/2026-04-25-debate-plan.md#L235-L240](2026-04-25-debate-plan.md#L235-L240) — Section: Data Model (per-type `<artifact_id>`)
- Plan: [docs/2026-04-25-debate-plan.md#L261](2026-04-25-debate-plan.md#L261) — Section: File Impact Summary (`bin/review-gate-debate.sh`)
- Plan: [docs/2026-04-25-debate-plan.md#L366](2026-04-25-debate-plan.md#L366) — Section: D1 (code layout)
- Plan: [docs/2026-04-25-debate-plan.md#L389](2026-04-25-debate-plan.md#L389) — Section: D12 (per-machine determinism)
- Spec: [docs/2026-04-25-debate-spec.md#L72](2026-04-25-debate-spec.md#L72) — Section 2 step 4 (strategy assignment algorithm)
- Spec: [docs/2026-04-25-debate-spec.md#L199-L211](2026-04-25-debate-spec.md#L199-L211) — Section: R3 Strategy diversity

**Goal**: Stand up `bin/review-gate-debate.sh` and implement the per-`(artifact_id, reviewer)` SHA-256 strategy assignment with collision walk in canonical alphabetical reviewer order (`claude` < `codex` < `gemini`).

**Context**: D1 establishes the new file. The strategy assignment is the first non-trivial debate primitive; subsequent tasks (T011 for substitution, T012 for coordinator) consume `assigned_strategy` per reviewer. R3's pinned algorithm: `shasum -a 256` over `<artifact_id>:<reviewer>` → first 8 hex chars → base-16 → mod 3 → index into `[verification-first, falsification-first, decompose]`; collision walk forward `(idx+1)%3, (idx+2)%3`.

**Scope**:
- In: New file `bin/review-gate-debate.sh` containing helpers `compute_artifact_id`, `compute_strategy_assignment`, `__hash_sha256`. Hard-error if neither `shasum` nor `sha256sum` is on `$PATH`.
- Out: Coordinator function `run_debate_coordinator` (T012); anonymization (T017); aggregator (T020).

**Changes**:
- `bin/review-gate-debate.sh` — New — define `__hash_sha256 "$input" → 64-hex-char output` (prefer `shasum -a 256`, fallback `sha256sum`, hard-error if neither found); define `compute_artifact_id` switching on `REVIEW_TYPE` per Plan L235-L240 (`plan`/`spec` → realpath; `code` → `diff_args_str`; `epic-verify` → realpath of epic file or verbatim raw-criteria); define `compute_strategy_assignment` that takes the canonical reviewer list and emits an associative-flat array `STRATEGY[<reviewer>]=<strategy>`.

**Acceptance Criteria**:
1. **Hash primitive**: `__hash_sha256 "test"` outputs 64 lowercase hex chars on both macOS (BSD `shasum`) and Linux (GNU `sha256sum`); hard-error with stderr `neither shasum nor sha256sum found on PATH; SHA-256 hash primitive required for strategy assignment` if neither found.
2. **Determinism**: `compute_strategy_assignment` produces the same `STRATEGY{}` for the same `<artifact_id>` + same reviewer set across reruns.
3. **Collision walk**: when two reviewers' preferred indices collide, the canonical-alphabetical-second reviewer walks forward — verified by T010 fixtures covering N=2 distinct, N=3 full permutation, N=4 wrap, no-collision swap, collision-driven shift.

**Verification**:
- Manually invoke `compute_strategy_assignment` with a fixture artifact_id; assert outputs match expected by replaying the SHA-256-mod-3 calculation by hand.
- T010 (R3 fixture tests) provides full coverage; passing T010 is downstream verification.
- **Negative case**: Mock `command -v shasum` and `command -v sha256sum` to both return false; assert hard-error.

**Notes for Agent**:
- Bash 3.2 — no associative arrays. Use parallel arrays (`STRATEGY_KEYS=(claude codex gemini); STRATEGY_VALS=(verification-first falsification-first decompose)`) or environment-variable convention `STRATEGY_<reviewer>=<strategy>`.
- Per D12, `<artifact_id>` for `plan`/`spec`/`epic-verify` is `realpath`. Document the per-machine determinism caveat in a header comment so future readers don't expect cross-machine reproducibility for the strategy hash.
- The first 8 hex chars must be parsed as base-16 → integer. Bash `$((16#$hex))` works. Verify no leading-zero gotcha.

</details>

### - [ ] **T010** [integration-path-test] R2/R3/R10 fixture tests

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P1
**Story**: Phase C
**Parallel**:
**Primary Files**: `bin/tests/test-debate-strategy.sh` (New), `bin/tests/fixtures/r3-strategy-assignment/` (New)
**Subsystems**: tests
**Dependencies**: T007, T008, T009

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L264](2026-04-25-debate-plan.md#L264) — Section: File Impact Summary (`bin/tests/test-debate-strategy.sh`)
- Plan: [docs/2026-04-25-debate-plan.md#L271](2026-04-25-debate-plan.md#L271) — Section: File Impact Summary (`r3-strategy-assignment/`)
- Plan: [docs/2026-04-25-debate-plan.md#L342-L344](2026-04-25-debate-plan.md#L342-L344) — Section: AC Coverage (R2 anchor byte-equality, R3 strategy stability, R3 collision walk)
- Spec: [docs/2026-04-25-debate-spec.md#L174-L198](2026-04-25-debate-spec.md#L174-L198) — Section: R2 Calibrated confidence (canonical anchor block)
- Spec: [docs/2026-04-25-debate-spec.md#L199-L211](2026-04-25-debate-spec.md#L199-L211) — Section: R3 Strategy diversity

**Goal**: R3 fixture tests covering: per-(artifact, reviewer) stability across reruns; full N=3 permutation; distinct-strategy N=2; N=4 collision wrap; no-collision swap; collision-driven shift. Plus R10 anchor-block byte-equality across all four reviewer templates (verifies T007's anchor file + T008's placeholder injection produce a byte-equal anchor region in each rendered template under `--debate`).

**Context**: This is the [integration-path-test] for Phase C — invokes `bin/review-gate spawn --debate` against fixture artifacts and asserts the rendered prompt contains both the strategy directive (per assigned strategy) and the canonical anchor block byte-for-byte.

**Scope**:
- In: New test script + fixture directory.
- Out: R6 dedup tests (T022); R1 anonymization tests (T022).

**Changes**:
- `bin/tests/test-debate-strategy.sh` — New — Phase 1 cases (R3 unit): drive `compute_strategy_assignment` with fixture `<artifact_id>` + reviewer-set tuples; assert against expected outputs in `r3-strategy-assignment/`. Phase 2 cases (R10 anchor): for each of 4 reviewer templates, render the prompt under `--debate` against a fixture artifact; `cmp` the extracted anchor block region against `prompts/strategies/confidence-anchors.md`.
- `bin/tests/fixtures/r3-strategy-assignment/` — New — JSON pairs `(artifact_id, reviewer_set) → expected STRATEGY{}` covering: N=2 distinct, N=3 full permutation, N=4 collision wrap, no-collision swap (swap one reviewer, others unchanged), collision-driven shift (swap one reviewer triggers a collision walk that lands on a previously-unchanged reviewer).

**Acceptance Criteria**:
1. **R3 strategy assignment**: stability (same artifact + same reviewer set → same `STRATEGY{}` across 10 reruns) AND collision walk (fixture cases for N=2/3/4/swap/shift all produce expected outputs).
2. **R10 anchor byte-equality**: for each of 4 reviewer templates, the rendered anchor block region (under `--debate`) is byte-identical to `prompts/strategies/confidence-anchors.md`.
3. **Test mechanics**: exits 0 on success, non-zero with a clear diff line on any mismatch.

**Verification**:
- Run the test locally; all cases pass.
- Mutate `prompts/strategies/confidence-anchors.md` (add a trailing space); confirm the test catches it.
- **Negative case**: rotate the alphabetical reviewer order in `compute_strategy_assignment` (e.g., from `claude < codex < gemini` to `gemini < codex < claude`) and confirm the collision-walk fixture cases fail.

**Notes for Agent**:
- Compute expected outputs by hand or via a one-shot Python/jq script that replays the SHA-256-mod-3-walk algorithm; check the script + expected outputs into the fixture dir.
- The rendered-prompt extraction for the R10 byte-equality check must use the same template-substitution logic as `bin/review-gate` (T011) — easiest path is to invoke `bin/review-gate` end-to-end and extract the anchor region from the captured `<reviewer>.prompt` file.
- Cross-platform: tests must run on both macOS and Linux. Use `cmp -s` for byte comparison (locale-independent).

</details>

### - [ ] **T011** [system-wiring] `bin/review-gate` debate-conditional emission (substitution + source + schema variant)

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P0
**Story**: Phase C / Phase D bridge (US1+US2)
**Parallel**:
**Primary Files**: `bin/review-gate` (Exists, modify), `bin/review-gate-models.sh` (Exists, modify)
**Subsystems**: review-gate
**Dependencies**: T004, T005, T007, T008, T009

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L70-L79](2026-04-25-debate-plan.md#L70-L79) — Section: Implementation Constraints (schema byte-parity, template placeholder whitespace)
- Plan: [docs/2026-04-25-debate-plan.md#L99-L100](2026-04-25-debate-plan.md#L99-L100) — Section: Integration Analysis (schema heredoc + `default_review_schema()` + `repair_review_output()`)
- Plan: [docs/2026-04-25-debate-plan.md#L116-L122](2026-04-25-debate-plan.md#L116-L122) — Section: Integration Approach steps 4-5
- Plan: [docs/2026-04-25-debate-plan.md#L367-L369](2026-04-25-debate-plan.md#L367-L369) — Section: D2 (placeholder substitution + line consumption) and D3 (schema variant emission)
- Plan: [docs/2026-04-25-debate-plan.md#L279-L280](2026-04-25-debate-plan.md#L279-L280) — Section: File Impact Summary (`bin/review-gate` + `bin/review-gate-models.sh`)
- Spec: [docs/2026-04-25-debate-spec.md#L287-L302](2026-04-25-debate-spec.md#L287-L302) — Section: R9 Backwards-compatible CLI surface

**Goal**: Wire three debate-conditional emissions into `bin/review-gate` in one batched edit so the dependency chain on this file is minimized: (1) prompt-builder substitutes `${CONFIDENCE_ANCHORS}` and `${STRATEGY_DIRECTIVE}` (file contents under `--debate`; empty + line-consumed under `--debate` absent); (2) after preflight, conditional `if [[ -n "$DEBATE" ]]; then source bin/review-gate-debate.sh; run_debate_coordinator "$@"; exit; fi`; (3) schema heredoc + `default_review_schema()` + `repair_review_output()` gain a debate-conditional `if/else` branch.

**Context**: This task ties multiple debate-conditional emissions into one batched edit so we don't re-touch `bin/review-gate` on every Phase D change. D2 and D3 are the contract. Phase C (T007/T008) must be done first because the substitution logic refers to the placeholder names. T012 (coordinator function body) implements `run_debate_coordinator`, which this task only invokes.

**Scope**:
- In: 3 debate-conditional emissions in `bin/review-gate` + 1 schema-variant branch in `bin/review-gate-models.sh`.
- Out: `run_debate_coordinator` body (T012); per-reviewer JSON additive fields (T015).

**Wiring Map**:
- `--debate` flag → preflight → (`source bin/review-gate-debate.sh && run_debate_coordinator`) | (existing detached `spawn_reviewer` path)
- `prompts/strategies/confidence-anchors.md` → `${CONFIDENCE_ANCHORS}` placeholder substitution → rendered `<reviewer>.prompt`
- `prompts/strategies/<assigned-strategy>.md` → `${STRATEGY_DIRECTIVE}` placeholder substitution → rendered `<reviewer>.prompt`
- `--debate` flag → schema heredoc selector → `review-schema.json` (variant or pre-feature byte-identical) → reviewer CLI (`--output-schema` or repair prompt)

**Changes**:
- `bin/review-gate` (prompt-builder section, near where `${ISSUES}` / `${CONTEXT}` / `${DIFF_ARGS}` are substituted) — Exists — substitute `${CONFIDENCE_ANCHORS}` with `cat prompts/strategies/confidence-anchors.md` when `--debate` set, empty when absent; substitute `${STRATEGY_DIRECTIVE}` with `cat prompts/strategies/<STRATEGY[$reviewer]>.md` when `--debate` set, empty when absent. Both substitutions MUST consume the placeholder line including its trailing newline under `--debate` absent (D2's line-consumption invariant).
- `bin/review-gate` (after preflight, before existing detached `spawn_reviewer` invocation) — Exists — add `if [[ -n "$DEBATE" ]]; then source "$(dirname "$0")/review-gate-debate.sh"; run_debate_coordinator "$@"; exit $?; fi`.
- `bin/review-gate` schema heredoc (lines ~2623-2656) — Exists — wrap heredoc in `if [[ -n "$DEBATE" ]]; then <emit debate variant>; else <emit non-debate variant byte-identical to today>; fi`. Debate variant adds `overall_confidence`, `strategy`, `round`, `peer_responses_seen` at top level (all optional) and `confidence` inside `findings[*]` (optional). `additionalProperties: false` retained on both objects in both variants.
- `bin/review-gate-models.sh` `default_review_schema()` (lines 117-150) — Exists — same debate-conditional `if/else` branch with non-debate byte-identical to today.
- `bin/review-gate-models.sh` `repair_review_output()` (lines 152-250) — Exists — pick the same conditional variant for the embedded repair-prompt schema.

**Acceptance Criteria**:
1. **Substitution + line-consumption**: Under `--debate` absent, T002 byte-parity test passes (rendered `<reviewer>.prompt` files byte-identical to pre-debate-baseline). Under `--debate`, the rendered `<reviewer>.prompt` contains both the canonical anchor block (byte-identical to `prompts/strategies/confidence-anchors.md` per T010) and the assigned strategy directive.
2. **Coordinator dispatch**: Under `--debate` (with `run_debate_coordinator` available, even as a stub), `bin/review-gate spawn --debate` dispatches to the coordinator; under `--debate` absent, falls through to the existing detached path.
3. **Schema variant byte-parity**: Under `--debate` absent, `review-schema.json` AND `default_review_schema()` output AND repair-prompt embedded schema are byte-identical to pre-debate-baseline. Under `--debate`, the schema admits the new optional fields with `additionalProperties: false` retained.

**Verification**:
- T002 byte-parity test passes with `--debate` absent.
- Add to T010: assert that under `--debate`, the rendered `<reviewer>.prompt` for each of the 4 templates contains the anchor block byte-identical to `prompts/strategies/confidence-anchors.md`.
- Add to T013 (schema-variant test, not yet split out — covered here): under `--debate`, validate a JSON with extra `overall_confidence`/`strategy`/`round`/`peer_responses_seen` fields against the emitted schema; under `--debate` absent, assert byte-identical schema bytes vs. baseline.
- **Merge/precedence**: Verify `--debate` set overrides nothing in `--mode`; both compose orthogonally (T028 E2E covers this).

**Notes for Agent**:
- Bash 3.2 — no `${var^^}` etc. Use `[[ "$var" == "1" ]]` style.
- The line-consumption invariant (D2) is the trickiest part. Test by rendering a template containing only the placeholder + literal text, with `--debate` unset, and `cmp` against a template that never had the placeholder. Both must be byte-identical including LF count.
- Schema heredoc has TWO emission sites — the inline heredoc in `bin/review-gate:2623-2656` AND `default_review_schema()` in `bin/review-gate-models.sh:117-150`. Both must gain the conditional branch. Repair-prompt schema (`repair_review_output`) follows the same branch.
- Source `bin/review-gate-debate.sh` only when `--debate` is set (lazy load) — avoids parsing cost on the hot non-debate path.
- This is the [system-wiring] task per the plan — keep the wiring map up to date in the task notes.

</details>

---

## Phase D — Coordinator + Round 1 Only

### - [ ] **T012** [integration-path-test] Coordinator skeleton + Round 1 launch + sync sentinel polling

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P0
**Story**: Phase D (US2)
**Parallel**:
**Primary Files**: `bin/review-gate-debate.sh` (Exists, modify), `bin/tests/test-debate-end-to-end.sh` (New, partial)
**Subsystems**: review-gate, tests
**Dependencies**: T011

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L146](2026-04-25-debate-plan.md#L146) — Section: High-Level Approach, Phase D
- Plan: [docs/2026-04-25-debate-plan.md#L160-L211](2026-04-25-debate-plan.md#L160-L211) — Section: Architecture (top-level control flow + failure paths)
- Plan: [docs/2026-04-25-debate-plan.md#L370-L375](2026-04-25-debate-plan.md#L370-L375) — Section: D4 (synchronous reviewer launch + per-round staging)
- Plan: [docs/2026-04-25-debate-plan.md#L268](2026-04-25-debate-plan.md#L268) — Section: File Impact Summary (`bin/tests/test-debate-end-to-end.sh`)
- Spec: [docs/2026-04-25-debate-spec.md#L60-L122](2026-04-25-debate-spec.md#L60-L122) — Section 2: User Experience & Flows (coordinator step-by-step)

**Goal**: Stand up `run_debate_coordinator` body in `bin/review-gate-debate.sh`. Launch Round 1 reviewers via `spawn_reviewer` with `output_dir=$ITERATIONS_DIR/round-1/` (T005's new param). Block in-process until all sentinels (`<reviewer>.done` / `<reviewer>.failed`) appear. Lazy stub for aggregation + atomic promote (next tasks add real content).

**Context**: This is the [integration-path-test] for Phase D. The skeleton's E2E test invokes `bin/review-gate spawn --debate` against canned reviewer outputs and asserts the coordinator runs Round 1 to completion and produces per-reviewer JSONs in the canonical `$REVIEWS_DIR` (via the stub aggregator's atomic promote in T014).

**Scope**:
- In: `run_debate_coordinator` function with strategy assignment, schema emission (delegates to T011's already-wired branch), eligibility check, Round 1 launch into staging dir, sync sentinel polling, stub aggregator, atomic promote of final-round JSONs to `$REVIEWS_DIR`.
- Out: Round 1 prompt build details (T013); real aggregator (T014/T020); anonymization + Round 2 (Phase E).

**Wiring Map**:
- coordinator → `compute_strategy_assignment` (T009) → `STRATEGY{}`
- coordinator → emits debate-variant `review-schema.json` (via T011's branch)
- coordinator → eligibility check (≥2 reviewers; else exit 6 per D6)
- coordinator → for each reviewer: build prompt (T013) → `spawn_reviewer "$REVIEWER" ... output_dir="$ITERATIONS_DIR/round-1/"` (T005)
- coordinator → poll `$ITERATIONS_DIR/round-1/<reviewer>.{done,failed}` sentinels until all reviewers settled or per-round timeout (D5)
- coordinator → stub aggregator (T014) → atomic promote → `$REVIEWS_DIR/<reviewer>.json` + `<reviewer>.done` + `aggregate.json`

**Changes**:
- `bin/review-gate-debate.sh` — Exists — add `run_debate_coordinator` function. Source `bin/review-gate-models.sh` to get `spawn_reviewer`. Use existing `bin/review-gate:3088-3120` sentinel-polling pattern (poll-and-sleep with `REVIEW_GATE_POLL_INTERVAL_SECONDS`). On per-round timeout, mark reviewer `abstained=true` for the round per Mode A.
- `bin/tests/test-debate-end-to-end.sh` — New (partial) — at least one Phase D smoke: invoke `bin/review-gate spawn-code-review --debate` against canned reviewer outputs; assert exit 0, `$REVIEWS_DIR/<reviewer>.json` populated, `aggregate.json` exists.

**Acceptance Criteria**:
1. Round 1 launches all reviewers in parallel, waits for all sentinels, atomically promotes outputs to `$REVIEWS_DIR`.
2. On `--debate-seed N` (no-op for Phase D since Round 2 doesn't exist yet), the coordinator accepts and ignores the seed.
3. **Failure path**: SIGINT mid-coordinator leaves `$REVIEWS_DIR` empty + `gate-state.json.status="pending"` (per D6); per-round staging at `$ITERATIONS_DIR/round-1/` is preserved.

**Verification**:
- E2E smoke in `bin/tests/test-debate-end-to-end.sh`: `bin/review-gate spawn-code-review --debate` → exit 0 → `$REVIEWS_DIR` has per-reviewer JSONs + `aggregate.json`.
- **Cancellation**: `kill -INT $coordinator_pid` mid-Round-1; after exit, `$REVIEWS_DIR` empty + `gate-state.json.status="pending"`; staging dir preserved.
- T002 byte-parity test still passes with `--debate` absent.

**Notes for Agent**:
- Bash 3.2 — sentinel polling uses `[ -e "$f.done" ] || [ -e "$f.failed" ]`. No `mapfile`/readarray.
- The atomic promote step: write per-reviewer JSONs to a temp path, then `mv` into `$REVIEWS_DIR`. Per D4, write `<reviewer>.done` sentinel only AFTER the JSON is in place.
- Per D5, per-reviewer timeout is the existing polling-loop budget per round. A reviewer that hits this budget is Mode A `abstained=true` (terminal-abstention rule applies).

</details>

### - [ ] **T013** Round 1 prompt build + eligibility check + Mode A/B abstention

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P1
**Story**: Phase D
**Parallel**:
**Primary Files**: `bin/review-gate-debate.sh` (Exists, modify)
**Subsystems**: review-gate
**Dependencies**: T012

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L168-L189](2026-04-25-debate-plan.md#L168-L189) — Section: Architecture (coordinator pseudocode steps 1-5)
- Plan: [docs/2026-04-25-debate-plan.md#L375](2026-04-25-debate-plan.md#L375) — Section: D5 (per-reviewer timeout)
- Spec: [docs/2026-04-25-debate-spec.md#L374](2026-04-25-debate-spec.md#L374) — Section 4 (Mode A vs Mode B boundary, terminal-abstention rule)

**Goal**: Implement Round 1 prompt construction, eligibility check (≥2 reviewers), Mode A (crash/timeout/unparseable JSON → `abstained=true`) and Mode B (parseable JSON with missing/out-of-range confidence → `0.5` default + clamp + integrity warning).

**Context**: Round 1 has no peer block (no prior round) and no prior-round-self block. Round 1 prompt is the reviewer template + substituted anchor + substituted strategy directive + the artifact body. Mode A/B distinction is critical: missing `findings`/`verdict` is Mode A (not Mode B); only confidence fields are Mode B's domain.

**Scope**:
- In: Round 1 prompt assembly via existing template substitution (T011); per-reviewer post-processing for Mode A/B; eligibility re-check (≥2 reviewers passed Round 1).
- Out: Round 2/3 peer-block construction (T019); aggregator (T015 stub, T020 real).

**Changes**:
- `bin/review-gate-debate.sh` `run_debate_coordinator` — Exists — round 1 loop: for each reviewer, render prompt (no peer block, no self-block), launch via `spawn_reviewer`. After all sentinels resolve, parse each `<reviewer>.json`: if Mode A (crash/timeout/unparseable), mark `abstained=true`; if Mode B (parseable but confidence missing), default `overall_confidence=0.5`, default per-finding `confidence=0.5`, clamp out-of-range to `[0,1]`, log integrity warning. After processing: re-check ≥2 active (non-abstained) reviewers; if not, exit 6 (degraded-below-2 mid-debate per Plan L211).

**Acceptance Criteria**:
1. Mode A boundary: crash, timeout, unparseable JSON, OR parseable-but-missing-`findings`/-`verdict` → `abstained=true`.
2. Mode B boundary: parseable JSON with `findings` + `verdict` present but `overall_confidence` or per-finding `confidence` missing/out-of-range → defaults applied, NOT abstained.
3. Eligibility re-check after Round 1: <2 active reviewers → exit 6 per D6.

**Verification**:
- Add fixture-based test: 3 canned reviewer outputs (one Mode A crash, one Mode B missing confidence, one normal) → coordinator processes correctly.
- **Negative**: 3 reviewers, 2 Mode A (crashes) → exit 6.
- **Merge/precedence**: out-of-range `overall_confidence=1.5` clamped to `1.0`; integrity warning emitted to stderr.

**Notes for Agent**:
- Mode A vs Mode B boundary is pinned at spec L374. Get it right.
- The `findings: []` empty array IS Mode B (means "I saw no defects"). Missing `findings` (the array itself absent) is Mode A.
- Integrity warning format: write to stderr, do NOT abstain.

</details>

### - [ ] **T014** Stub aggregator + atomic promote + `aggregate.json` skeleton

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P1
**Story**: Phase D
**Parallel**:
**Primary Files**: `bin/review-gate-debate.sh` (Exists, modify)
**Subsystems**: review-gate
**Dependencies**: T013

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L146](2026-04-25-debate-plan.md#L146) — Section: High-Level Approach, Phase D (stub aggregator, no dedup)
- Plan: [docs/2026-04-25-debate-plan.md#L186-L189](2026-04-25-debate-plan.md#L186-L189) — Section: Architecture (atomic promote + write order)
- Plan: [docs/2026-04-25-debate-plan.md#L213-L223](2026-04-25-debate-plan.md#L213-L223) — Section: Data Model (`aggregate.json` shape + summary template)
- Plan: [docs/2026-04-25-debate-plan.md#L371-L373](2026-04-25-debate-plan.md#L371-L373) — Section: D4 (atomic promotion after aggregation)
- Spec: [docs/2026-04-25-debate-spec.md#L212-L286](2026-04-25-debate-spec.md#L212-L286) — Section: R6 Confidence-weighted aggregation (canonical aggregate.json shape consumed by stub)

**Goal**: Implement stub aggregator that produces single-round `aggregate.json` (no dedup, no cross-reviewer merge — those land in T020). Atomic promote final-round per-reviewer JSONs from staging to canonical `$REVIEWS_DIR`. Write `aggregate.json` last.

**Context**: This is the "Phase D shippable shippable state": the coordinator runs end-to-end, produces an `aggregate.json` (with the canonical pinned shape but trivially-aggregated findings — pass-through, no dedup), and the Stop-hook sees populated `reviews/`. Phase E (T020) replaces the aggregator with the real confidence-weighted dedup logic.

**Scope**:
- In: Pure-shell + jq stub aggregator. Atomic promote step. `aggregate.json` with pinned top-level keys (`verdict`, `summary`, `findings`, `consensus_mode`, `rounds_consumed`, `reviewers`, `strategies`).
- Out: Dedup predicate (T020); confidence tiebreak / FAIL-blocking (T021); `raised_by` set union (T020).

**Changes**:
- `bin/review-gate-debate.sh` `run_debate_coordinator` — Exists — after eligibility re-check, run stub aggregator: `aggregate.findings = jq -s '[.[].findings[]]' <per-reviewer>.json` (concat — no merge yet). Compute simple verdict: `FAIL` if any reviewer FAIL; `NEEDS_WORK` if any non-FAIL reviewer NEEDS_WORK; else `PASS`. Write `aggregate.json` with the canonical shape from Plan L215. Then atomically promote per-reviewer JSONs: `mv <staging>/<reviewer>.json $REVIEWS_DIR/<reviewer>.json; touch $REVIEWS_DIR/<reviewer>.done`. Then write `$REVIEWS_DIR/aggregate.json`.

**Acceptance Criteria**:
1. After Round 1 completes, `$REVIEWS_DIR/<reviewer>.json` exist for all active reviewers + `<reviewer>.done` sentinels + `aggregate.json` with all 7 pinned top-level keys.
2. `aggregate.findings` is the concat (not dedup'd) of per-reviewer findings — pass-through is acceptable for Phase D stub.
3. **Atomicity**: aggregator failure leaves `$REVIEWS_DIR` empty (per D6 / Plan L378).

**Verification**:
- T012 E2E smoke produces `aggregate.json` with all 7 keys.
- **Failure path**: mock `jq` to return error code; assert `$REVIEWS_DIR` empty afterward, exit 5, stderr `aggregator failed: <reason>`.

**Notes for Agent**:
- Per Plan L186, the write order is: aggregator runs → atomic promote per-reviewer JSONs → write `aggregate.json` → write `gate-state.json.debate` block (T024). Get the order right.
- The stub aggregator's `findings` are intentionally a flat concat — Phase E (T020) replaces it. Document this in a comment so future readers don't think it's the final shape.

</details>

### - [ ] **T015** Per-reviewer JSON additive fields under `--debate`

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P1
**Story**: Phase D
**Parallel**:
**Primary Files**: `bin/review-gate-debate.sh` (Exists, modify)
**Subsystems**: review-gate
**Dependencies**: T011, T014

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L21](2026-04-25-debate-plan.md#L21) — Section: Scope (additive optional fields)
- Plan: [docs/2026-04-25-debate-plan.md#L225](2026-04-25-debate-plan.md#L225) — Section: Data Model (per-reviewer JSON additive fields)
- Spec: [docs/2026-04-25-debate-spec.md#L287-L302](2026-04-25-debate-spec.md#L287-L302) — Section: R9 Backwards-compatible CLI surface

**Goal**: When `--debate` is set, each per-reviewer `<reviewer>.json` (after atomic promote to `$REVIEWS_DIR/`) includes the additive optional fields: `overall_confidence` (in `[0,1]`, default `0.5`), `findings[*].confidence` (same), `strategy` (one of three), `round` (integer 1..N), `peer_responses_seen` (array of opaque IDs the coordinator presented — empty in Round 1, includes abstained-peer slot IDs in Round 2/3).

**Context**: The schema variant (T011) admits these fields; this task ensures the coordinator actually populates them. `peer_responses_seen` is coordinator-populated, not parsed back from the reviewer (per Plan L225).

**Scope**:
- In: Coordinator-side post-processing of each Round 1 `<reviewer>.json` to inject `strategy=<assigned>`, `round=1`, `peer_responses_seen=[]`. Parse `overall_confidence` and `findings[*].confidence` from reviewer output (with Mode B defaults from T013).
- Out: `peer_responses_seen` for Rounds 2/3 (T019).

**Changes**:
- `bin/review-gate-debate.sh` `run_debate_coordinator` — Exists — after each Round 1 reviewer completes (and Mode A/B post-processing in T013): mutate the staging `<reviewer>.json` via jq to inject `strategy`, `round=1`, `peer_responses_seen=[]`. Confidence fields already populated by T013's Mode B handling.

**Acceptance Criteria**:
1. Each `$REVIEWS_DIR/<reviewer>.json` under `--debate` includes all 5 additive fields with correct values.
2. Under `--debate` absent, no additive fields are present (per-reviewer JSON byte-identical to baseline — T002 verifies).
3. Schema variant validation: `<reviewer>.json` validates against the debate-variant schema emitted by T011.

**Verification**:
- T028 (E2E smoke) verifies all 5 fields appear under `--debate`.
- T002 byte-parity verifies absence of fields under `--debate` absent.
- Add to T010 a check that `findings[*].confidence` defaults to `0.5` when reviewer omits it.

**Notes for Agent**:
- Use `jq` for the field injection: `jq '. + {strategy: $s, round: 1, peer_responses_seen: []}' <input.json> | sponge` — no Bash string-concat into JSON.
- `peer_responses_seen` reflects what the coordinator presented, NOT what the reviewer self-reports. T019 will add peer-slot IDs (including abstained slots) for Rounds 2/3.

</details>

---

## Phase E — Anonymization + Round 2 + Dedup Aggregator + Round 3

### - [ ] **T016** [integration-path-test] Anonymization + Round 2 skeleton + failing tests

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P0
**Story**: Phase E (US3)
**Parallel**:
**Primary Files**: `bin/review-gate-debate.sh` (Exists, modify), `bin/tests/test-debate-anonymization.sh` (New, scaffold), `bin/tests/fixtures/debate-bad-artifact/` (New)
**Subsystems**: review-gate, tests
**Dependencies**: T015

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L148](2026-04-25-debate-plan.md#L148) — Section: High-Level Approach, Phase E
- Plan: [docs/2026-04-25-debate-plan.md#L320](2026-04-25-debate-plan.md#L320) — Section: Falsifiable acceptance test
- Plan: [docs/2026-04-25-debate-plan.md#L273](2026-04-25-debate-plan.md#L273) — Section: File Impact Summary (`debate-bad-artifact/`)
- Spec: [docs/2026-04-25-debate-spec.md#L19](2026-04-25-debate-spec.md#L19) — Section: Falsifiable acceptance signal (two-clause)
- Spec: [docs/2026-04-25-debate-spec.md#L126-L173](2026-04-25-debate-spec.md#L126-L173) — Section: R1 Anonymized peer broadcast

**Goal**: Stand up the anonymization pass + Round 2 launch skeleton in `run_debate_coordinator`, plus the failing falsifiable-acceptance fixture. Initially fails (anonymization not yet implemented in T017; aggregator dedup not yet in T020). This is the [integration-path-test] for Phase E.

**Scope**:
- In: Round 2 control flow in coordinator (gated on `[[ $ROUND -lt $TOTAL_ROUNDS ]]`); skeleton for `run_anonymization_pass()`; fixture directory `debate-bad-artifact/` with planted P1 + `defect-location.json`.
- Out: Anonymization implementation (T017); Round 2 prompt body (T019); dedup aggregator (T020).

**Changes**:
- `bin/review-gate-debate.sh` `run_debate_coordinator` — Exists — after Round 1: `if (( ROUND < TOTAL_ROUNDS )); then run_anonymization_pass; build_round2_prompts; launch_round2; wait; fi`. `run_anonymization_pass` is a stub initially (returns input unchanged).
- `bin/tests/test-debate-anonymization.sh` — New scaffold — falsifiable-acceptance test invoking `bin/review-gate spawn-spec-review --debate` against `debate-bad-artifact/`; asserts both clauses (Round 1 P1 at planted location + final `aggregate.json` retains it with `confidence ≥ 0.7`, exact `file_path`, line-range overlap).
- `bin/tests/fixtures/debate-bad-artifact/` — New — a planted-defect spec + `defect-location.json` with `file_path`, `line_start`, `line_end`.

**Acceptance Criteria**:
1. Round 2 is launched when `TOTAL_ROUNDS=2` (fast/smart) or `TOTAL_ROUNDS=3` (max), in addition to Round 1.
2. Falsifiable-acceptance test compiles and is wired (initially **expected to fail** — anonymization isn't implemented; subsequent tasks make it pass).
3. `defect-location.json` schema documented in fixture README.

**Verification**:
- Run T016's test → expected FAIL (anonymization not yet wired).
- After T017 + T020 + T021 land, the same test → expected PASS.

**Notes for Agent**:
- Per the plan L320 / spec L19, the test is **two-clause**:
  - Clause 1 (existence): Round 1 must contain a P1 finding F at the planted `file_path` with overlapping line range.
  - Clause 2 (retention): final `aggregate.json` must retain F' with `priority="P1"`, `confidence ≥ 0.7`, exact `file_path` match, line-range overlap. Title NOT required to match.
- The fixture must be tunable so Clause 1 reliably fires — pick a defect that any of the three reviewers would catch cold.

</details>

### - [ ] **T017** Anonymization implementation (POSIX-ERE deny-list iterative scrub + per-recipient ordering shuffle)

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P0
**Story**: Phase E
**Parallel**:
**Primary Files**: `bin/review-gate-debate.sh` (Exists, modify), `bin/tests/fixtures/r1-anonymization/` (New)
**Subsystems**: review-gate, tests
**Dependencies**: T016

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L67-L68](2026-04-25-debate-plan.md#L67-L68) — Section: Implementation Constraints (POSIX ERE deny-list, iterative substitution)
- Plan: [docs/2026-04-25-debate-plan.md#L77-L78](2026-04-25-debate-plan.md#L77-L78) — Section: Implementation Constraints (production-path shuffle source)
- Plan: [docs/2026-04-25-debate-plan.md#L270](2026-04-25-debate-plan.md#L270) — Section: File Impact Summary (`r1-anonymization/`)
- Plan: [docs/2026-04-25-debate-plan.md#L388](2026-04-25-debate-plan.md#L388) — Section: D11 (`--debate-seed N` non-determinism)
- Spec: [docs/2026-04-25-debate-spec.md#L126-L173](2026-04-25-debate-spec.md#L126-L173) — Section: R1 Anonymized peer broadcast (regex flavor, canonical loop, seeded algorithm)

**Goal**: Implement `run_anonymization_pass`: (a) deny-list scrub via canonical POSIX ERE word-boundary form `(^|[^A-Za-z0-9_])<term>($|[^A-Za-z0-9_])` with iterative substitution loop (do-while until idempotent); (b) per-recipient peer ordering shuffle — under `--debate-seed N` use the spec's pinned SHA-256 algorithm (sort by `sha256("<seed>:<R-canonical-name>:<P-opaque-ID>")`), else use `$RANDOM` / `/dev/urandom` per recipient (must NOT cross-derive from seed input).

**Context**: R1's deny list is `{Claude, Codex, Gemini, GPT, Anthropic, OpenAI, Google, Reviewer 1..3, Agent 1..3}`. Iterative substitution is required because adjacent terms separated by one boundary char would leave the second unredacted in a single pass (`Claude Codex` → `[REDACTED] Codex` first pass, `[REDACTED] [REDACTED]` second pass).

**Scope**:
- In: `run_anonymization_pass` body in `bin/review-gate-debate.sh` covering scrub + shuffle. R1 fixture data covering deny-list cases + counter-examples + `Claude Codex Gemini` adjacent triple.
- Out: Round 2 prompt construction (T019).

**Changes**:
- `bin/review-gate-debate.sh` — Exists — implement `__anon_scrub` using the canonical pinned do-while loop: `cur=$input; while :; do next=$(printf '%s' "$cur" | sed -E "s/(^|[^A-Za-z0-9_])(Claude|Codex|Gemini|GPT|Anthropic|OpenAI|Google|Reviewer 1|...)($|[^A-Za-z0-9_])/\1[REDACTED]\3/gi"); [ "$next" = "$cur" ] && break; cur=$next; done`. Implement `__anon_shuffle_for_recipient`: under `--debate-seed N`, sort by `sha256("$N:$R:$P_id")` ascending; else use `$RANDOM` per (R, P) pair (no cross-derivation from seed input; non-deterministic).
- `bin/tests/fixtures/r1-anonymization/` — New — input/expected pairs for: each deny-list term case-insensitive whole-word; counter-examples (`claudication`, `gptcache`, `geminids`, `agent13`); adjacent terms `Claude Codex` and `Claude Codex Gemini`; macOS-vs-Linux byte-identical output under same seed.

**Acceptance Criteria**:
1. **Deny-list iterative scrub**: each of the 13 deny-list terms case-insensitive whole-word matches and gets `[REDACTED]`; counter-examples (e.g., `claudication`, `gptcache`) don't match; `Claude Codex Gemini` adjacent triple → all three redacted in final output (idempotent loop converges).
2. **Per-recipient shuffle**: under `--debate-seed N`, two recipients see different orderings when N ≥ 3 peers AND same seed + same recipient + same peer-set produces the same ordering across runs; under no seed, two consecutive runs produce different orderings (production-path non-determinism per Plan L78).
3. **Cross-platform**: macOS BSD `sed -E` and Linux GNU `sed -E` produce byte-identical output for the same input + same deny-list under the canonical loop form.

**Verification**:
- R1 fixture tests in `bin/tests/test-debate-anonymization.sh` (scaffold from T016).
- **Negative**: a single non-iterative pass (mock the loop to break after iter 1) should leave `Codex` in `Claude Codex` unredacted — assert this is caught.
- **Cross-platform**: tests run in CI on both macOS and Linux.

**Notes for Agent**:
- Bash 3.2 + portable `sed -E`. The canonical pinned loop form is the do-while shell loop, NOT the BSD-label form `:a; ...; ta`.
- The deny-list alternation has an extra capture group; trailing boundary is `\3` not `\2`. Get this right.
- Per D11 + Plan L78: production shuffle source MUST NOT cross-derive from the seed input — even when `--debate-seed N` IS provided, the production-path shuffle bytes must remain non-deterministic per recipient. The seeded path is ONLY for fixture replay tests.

</details>

### - [ ] **T018** Round 2/3 prompt construction (anonymized peer block + prior-round-self block)

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P0
**Story**: Phase E
**Parallel**: (sequential with T017 by file overlap on `bin/review-gate-debate.sh`)
**Primary Files**: `bin/review-gate-debate.sh` (Exists, modify)
**Subsystems**: review-gate
**Dependencies**: T017

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L55](2026-04-25-debate-plan.md#L55) — Section: Assumptions (stateless reviewer CLIs)
- Plan: [docs/2026-04-25-debate-plan.md#L251](2026-04-25-debate-plan.md#L251) — Section: API/Interface Design (Round-2 self-block placement; Round 3 most-recent-prior-round only)
- Spec: [docs/2026-04-25-debate-spec.md#L126-L173](2026-04-25-debate-spec.md#L126-L173) — Section: R1 (active-peer skeleton, abstained-peer skeleton, per-finding confidence excluded)
- Spec: [docs/2026-04-25-debate-spec.md#L89-L90](2026-04-25-debate-spec.md#L89-L90) — Section 2 (Round 2/3 launch + abstained slots surfaced as `(peer abstained)`)

**Goal**: Implement `build_round_n_prompts` for Round 2 (and Round 3 under `--mode max`). Each round-N prompt to active reviewer R contains: (a) reviewer template + substituted anchor + substituted strategy directive (already wired by T011); (b) clearly-marked prior-round-self block (R's own most-recent-prior-round verdict + findings + `overall_confidence`); (c) anonymized peer block per R1 active-peer / abstained-peer skeletons.

**Context**: Reviewer CLIs are stateless one-shot invocations (Plan L55) — every round must include the prior-round-self block in the rendered prompt. Round 3 self-block contains ONLY Round 2 (most recent prior round; not concatenated Rounds 1+2) per spec Section 2 / Plan L251.

**Scope**:
- In: Round 2/3 prompt builder; consumes `STRATEGY{}`, prior-round outputs, `peer_responses_seen` per recipient.
- Out: Final-round dedup aggregator (T020); terminal-abstention check (T022).

**Changes**:
- `bin/review-gate-debate.sh` — Exists — implement `build_round_n_prompt` taking `(reviewer, round, prior_outputs)`. Construct prior-round-self block from R's most-recent-prior-round JSON (Round 1 for Round 2; Round 2 for Round 3). Construct anonymized peer block: for each peer P (every reviewer that participated in any prior round 1..k under terminal-abstention), render either the active-peer skeleton (R1 L127-L139 — `**Peer-X**\nVerdict: <V>\nOverall confidence: <C>\n\nFindings:\n- **<title>**\n  <body>\n...`) or the abstained-peer skeleton (`**Peer-X**\n(peer abstained)`). Per-finding `confidence` and per-peer `summary` MUST NOT appear in the rendered peer block. Peer ordering per recipient via T017's `__anon_shuffle_for_recipient`. Update `peer_responses_seen` per receiving reviewer to include all presented peer IDs (active + abstained).

**Acceptance Criteria**:
1. **Peer-block skeletons**: active-peer entries rendered byte-for-byte per R1 active-peer skeleton (empty `findings=[]` collapses to `Findings: (none)` per spec L169); abstained-peer entries rendered byte-for-byte per `**Peer-X**\n(peer abstained)` (literal LF, no findings list).
2. **Field exclusion**: per-finding `confidence` and per-peer `summary` ABSENT from rendered peer block (spec L152); both fields still present in underlying `<reviewer>.json`.
3. **Round-N self-block + peer accounting**: Round 3 prior-round-self block contains only the reviewer's Round 2 output (NOT Rounds 1+2 concatenated); `peer_responses_seen` for receiving reviewer includes all presented peer slots (active + abstained per the terminal-abstention rule).

**Verification**:
- T016's falsifiable-acceptance fixture begins to pass Clause 1 (Round 1 P1 retained — Round 2 still needs aggregator from T020).
- Add per-reviewer prompt-snapshot tests under `r1-anonymization/`: render Round 2 prompt for `claude` against canned Round 1 outputs from `codex` + `gemini`, assert byte-identical output to fixture.
- **Negative**: assert per-finding `confidence` is NOT in the rendered peer block but IS in the underlying `<reviewer>.json`.

**Notes for Agent**:
- Spec L141-L148 pins the abstained-peer skeleton (two-line block). No JSON shape for abstained peer.
- LF-only line endings, no trailing whitespace, two-space body indent on multi-line finding bodies.
- `peer_responses_seen` reflects what the coordinator presented, NOT what the reviewer self-reports. Coordinator-populated only.

</details>

### - [ ] **T019** Confidence-weighted dedup aggregator (predicate + canonical merge order + `raised_by`)

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P0
**Story**: Phase E
**Parallel**: (sequential after T018 by file overlap on `bin/review-gate-debate.sh`)
**Primary Files**: `bin/review-gate-debate.sh` (Exists, modify), `bin/tests/test-debate-aggregation.sh` (New), `bin/tests/fixtures/r6-dedup/` (New)
**Subsystems**: review-gate, tests
**Dependencies**: T016, T018

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L23](2026-04-25-debate-plan.md#L23) — Section: Scope (aggregator semantics)
- Plan: [docs/2026-04-25-debate-plan.md#L65](2026-04-25-debate-plan.md#L65) — Section: Implementation Constraints (pure shell + jq)
- Plan: [docs/2026-04-25-debate-plan.md#L265](2026-04-25-debate-plan.md#L265) — Section: File Impact Summary (`bin/tests/test-debate-aggregation.sh`, `r6-dedup/`)
- Spec: [docs/2026-04-25-debate-spec.md#L377](2026-04-25-debate-spec.md#L377) — Section 4 (R6 dedup predicate + canonical merge order)
- Spec: [docs/2026-04-25-debate-spec.md#L212-L286](2026-04-25-debate-spec.md#L212-L286) — Section: R6 Confidence-weighted aggregation

**Goal**: Replace T014's stub aggregator with the real confidence-weighted dedup aggregator. Predicate: priority equality + non-null + exact-match `file_path` + non-null line ranges with integer overlap + case-folded title equality after `[Px]` strip. Canonical merge order: global pre-sort by `(priority asc, confidence desc, reviewer canonical-name asc)` then greedy fold. Merged entries gain `raised_by` set union.

**Scope**:
- In: `__aggregate_findings` function (pure shell + jq). R6 fixture pairs covering 8+ predicate cases, canonical merge order under non-transitive overlap, `[Px]` strip behaviors.
- Out: Verdict logic (T021); degraded-below-2 mid-debate (T021); terminal-abstention pruning (T022).

**Changes**:
- `bin/review-gate-debate.sh` — Exists — implement `__aggregate_findings` consuming all final-round per-reviewer JSONs: jq `[.findings[]]`-flatten with reviewer label injected; pre-sort by composite key `[priority_int, -confidence, reviewer_name]` with `sort_by`; reduce/greedy-fold marking each not-yet-merged F as primary and merging matches into it; emit deduplicated array with `raised_by` set union recorded on merged entries.
- `bin/tests/test-debate-aggregation.sh` — New — drives `__aggregate_findings` against fixture pairs in `r6-dedup/`.
- `bin/tests/fixtures/r6-dedup/` — New — input/output pairs for: same-file+overlap+title+priority → merged; non-overlap → not merged; different title → not merged; different file_path → not merged; null `line_start`/`line_end` → not merged; different priority → not merged; equal-confidence merge → alphabetical reviewer-name wins primary; non-transitive overlap (A overlaps B, B overlaps C, A does not overlap C); `[Px]` strip behaviors (`[P0]`..`[P3]`, `[P12]`, `[Pending]`, `[P4]`, `[p1]`, `[P1][P2]`, no-strip cases).

**Acceptance Criteria**:
1. **Dedup predicate**: 8+ GWT cases pass — false-merge prevented; legitimate merges happen.
2. **Canonical merge order**: non-transitive overlap test produces deterministic output (A absorbs B, C surfaces as own primary); equal-confidence merge → alphabetical reviewer wins primary (`claude` < `codex` < `gemini`).
3. **`raised_by` field**: merged entries record reviewer-name set union; non-merged entries do NOT include `raised_by` (optional, only on merged).

**Verification**:
- Run `bin/tests/test-debate-aggregation.sh` — all R6 fixture cases pass.
- **Negative**: swap pre-sort key order (e.g., `(reviewer asc, priority asc, confidence desc)`) and assert non-transitive overlap test fails.

**Notes for Agent**:
- Pure shell + jq per Plan L65. No LLM call, no fuzzy similarity.
- jq `sort_by([.priority, -.confidence, .reviewer])` for the pre-sort. `reduce` for the fold.
- `[Px]` strip: regex `^\[P[0-9]+\]\s*` (allow multi-digit per `[P12]` test). Strip + trim before case-folded equality check.
- Document non-transitive merge example in a header comment so future readers don't reorder the sort key.

</details>

### - [ ] **T020** Verdict logic + jq summary template + degraded-below-2 mid-debate

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P0
**Story**: Phase E
**Parallel**:
**Primary Files**: `bin/review-gate-debate.sh` (Exists, modify)
**Subsystems**: review-gate
**Dependencies**: T019

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L23](2026-04-25-debate-plan.md#L23) — Section: Scope (FAIL-blocking + PASS/NEEDS_WORK confidence tiebreak + `requires_decision`)
- Plan: [docs/2026-04-25-debate-plan.md#L194](2026-04-25-debate-plan.md#L194) — Section: Architecture (Verdict-authority split)
- Plan: [docs/2026-04-25-debate-plan.md#L211](2026-04-25-debate-plan.md#L211) — Section: Architecture (degraded-below-2 mid-debate eligibility)
- Plan: [docs/2026-04-25-debate-plan.md#L217-L223](2026-04-25-debate-plan.md#L217-L223) — Section: Data Model (summary template)
- Spec: [docs/2026-04-25-debate-spec.md#L212-L286](2026-04-25-debate-spec.md#L212-L286) — Section: R6 (verdict tiebreaks, `requires_decision` semantics)

**Goal**: Compute `aggregate.verdict` (FAIL-blocking on any P0/P1 from any active final-round reviewer; PASS/NEEDS_WORK confidence-weighted tiebreak otherwise). Emit deterministic `summary` via the pinned jq template. Implement mid-debate degraded-below-2 eligibility check (run BEFORE launching each round; if <2 active reviewers, exit 6 per D6 with `awaiting_decision` + `consensus.verdict=requires_decision`).

**Context**: The verdict-authority split (Plan L194) is intentional: Stop-hook over per-reviewer JSONs is the gate-decision authority; `aggregate.verdict` is presentation-only. Any P0/P1 finding forces `aggregate.verdict=FAIL` AND forces the Stop-hook's consensus to `requires_decision`. The string `requires_decision` MUST NEVER appear as a value of `aggregate.verdict` (Plan L23).

**Scope**:
- In: Verdict computation; jq summary template; mid-debate eligibility check at the start of each round.
- Out: Terminal-abstention rule (T022); gate-state.json.debate writing (T024).

**Changes**:
- `bin/review-gate-debate.sh` — Exists — `compute_aggregate_verdict`: scan dedup'd findings for any P0/P1 → FAIL; else compute majority verdict with confidence-weighted tiebreak per R6. `compute_aggregate_summary`: pinned jq template — `<verdict> from <N> active final-round reviewers (<reviewer-name-csv>); <findings_count> unique findings (P0:<n0> P1:<n1> P2:<n2> P3:<n3>); avg overall_confidence <x.xx>.` with reviewer-name-csv = canonical-alphabetical join `, `, avg rendered to 2dp. Mid-debate eligibility: at the start of each round-N launch (Round 2 + Round 3 under max), count non-abstained reviewers across all prior rounds 1..k-1; if <2, exit 6 per D6 (write `gate-state.json` per Plan L379 — `awaiting_decision` + `consensus.verdict=requires_decision` + `reason=debate degraded below 2 active reviewers in the final peer round`).

**Acceptance Criteria**:
1. **Verdict computation**: any P0/P1 finding from any active final-round reviewer → `aggregate.verdict=FAIL` (Stop-hook consensus then forced to `requires_decision` via existing P0/P1 logic); PASS/NEEDS_WORK confidence-tiebreak on 2-reviewer 1-1 split → confidence-weighted side wins `aggregate.verdict` (Stop-hook value over per-reviewer JSONs controls outer-loop iteration regardless).
2. **Summary template**: deterministic; renders byte-stable across jq versions (uses only `\(...)` interpolation + standard arithmetic); reviewer-name CSV canonical alphabetical; avg `overall_confidence` rendered to 2dp.
3. **Mid-debate degraded-below-2**: 3 reviewers, 2 distinct abstentions across Rounds 1+2 under `--mode max` → no Round 3 launched, exit 6 with `awaiting_decision` + `consensus.verdict=requires_decision` per D6.

**Verification**:
- T019's `test-debate-aggregation.sh` extended with verdict-tiebreak fixtures per consensus mode.
- T028 E2E: a 3-reviewer fixture where 1 raises P1 and 2 raise PASS → `aggregate.verdict=FAIL`, Stop-hook consensus `requires_decision`.
- **Mid-debate degraded**: 3 reviewers, 2 Mode A in Round 1 → Round 2 not launched, exit 6.
- **String hygiene**: assert `aggregate.verdict` value is one of `{PASS, NEEDS_WORK, FAIL}` only — `requires_decision` MUST NEVER appear there.

**Notes for Agent**:
- The P0/P1 check happens on the dedup'd findings array (not raw per-reviewer findings). Any single P0/P1 → FAIL. Confidence is NOT used to suppress P0/P1 (Plan L74).
- Reviewer-name CSV is canonical alphabetical (`claude, codex, gemini`), not iteration order.
- `avg overall_confidence` = arithmetic mean of active-final-round reviewers' `overall_confidence`, rendered to 2dp via `printf '%.2f'` or jq `tostring | .[:4]` equivalent — verify cross-jq-version stability.

</details>

### - [ ] **T021** Terminal-abstention rule + final-round Option B exclusion

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P0
**Story**: Phase E
**Parallel**:
**Primary Files**: `bin/review-gate-debate.sh` (Exists, modify)
**Subsystems**: review-gate
**Dependencies**: T018, T020

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L25](2026-04-25-debate-plan.md#L25) — Section: Scope (terminal-abstention rule)
- Plan: [docs/2026-04-25-debate-plan.md#L24](2026-04-25-debate-plan.md#L24) — Section: Scope (Final-round Option B exclusion)
- Spec: [docs/2026-04-25-debate-spec.md#L374](2026-04-25-debate-spec.md#L374) — Section 4 (terminal-abstention rule + Final-round Option B)

**Goal**: Implement the terminal-abstention rule (a reviewer that abstains in round k is NOT invoked in subsequent rounds k+1, k+2, ...) and Final-round Option B (a reviewer that abstains in the final peer round is fully excluded from final aggregation — no per-reviewer JSON written, not in `aggregate.json`, not seen by Stop-hook).

**Context**: Terminal-abstention composes with the degraded-below-2 trigger from T020. Under terminal-abstention: 2 reviewers + 1 Round-1 abstention → no Round 2 launch (degraded mid-debate); 3 reviewers + 2 distinct abstentions in Rounds 1+2 under `--mode max` → no Round 3 launch.

**Scope**:
- In: Per-round eligibility check that excludes terminally-abstained reviewers from the launch list. Final-round post-processing that excludes Mode-A-final-round outputs from `aggregate.json` and from the per-reviewer JSON write set.
- Out: Earlier-round Mode A handling (T013 already covers Round 1 Mode A).

**Changes**:
- `bin/review-gate-debate.sh` `run_debate_coordinator` — Exists — track `ABSTAINED_REVIEWERS` array across rounds. At launch-time of round N: filter eligible reviewers = active list - `ABSTAINED_REVIEWERS`. After each round completes, append any new abstainers (from this round) to `ABSTAINED_REVIEWERS`. Post-final-round: when atomically promoting per-reviewer JSONs to `$REVIEWS_DIR`, EXCLUDE any reviewer that abstained in the final peer round (Round 2 fast/smart, Round 3 max). Their earlier-round outputs stay in telemetry only — never carried forward into canonical outputs.

**Acceptance Criteria**:
1. **Terminal-abstention**: reviewer abstains Round 1 → NOT invoked in Round 2 (or Round 3 under max); surfaces to active peers as `(peer abstained)` per T018.
2. **Final-round Option B**: reviewer abstains in final peer round → no `<reviewer>.json` written to `$REVIEWS_DIR`; no entry in `aggregate.json.reviewers[]`; not seen by Stop-hook.
3. **Composition**: earlier-round abstainer's outputs (e.g., a Round-1 output that exists when Round 2 abstained) are NEVER carried forward into canonical outputs (Plan L24 — Option A rejected); terminal-abstention composes cleanly with degraded-below-2 mid-debate check (T020).

**Verification**:
- Add fixture in `r6-dedup/`: 3 reviewers, claude abstains Round 1 → Round 2 launches with codex + gemini only. Anonymized peer block presented to codex + gemini still surfaces claude as `**Peer-X**\n(peer abstained)`.
- Add fixture: 3 reviewers, claude abstains Round 2 (final round under fast/smart) → only codex + gemini in `$REVIEWS_DIR`; `aggregate.json.reviewers=["codex","gemini"]`; no claude.json in canonical outputs.
- **Negative**: claude's Round-1 output exists in staging but is NOT carried forward to canonical (Option A rejected).

**Notes for Agent**:
- Rationale per spec L374: a Round-1 crash/timeout is a strong signal the reviewer is unhealthy for this run; retrying risks duplicating the failure mode and wasting tokens.
- Final-round Option B chosen over Option A because Option A would mix rounds inside `aggregate.json` and contradict R6's "consumes the final peer round" framing.

</details>

### - [ ] **T022** R1 + R6 + falsifiable-acceptance + vibes-check fixture tests

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P1
**Story**: Phase E
**Parallel**:
**Primary Files**: `bin/tests/test-debate-anonymization.sh` (Exists, extend), `bin/tests/test-debate-aggregation.sh` (Exists, extend), `bin/tests/fixtures/debate-ambiguous-artifact/` (New), `bin/tests/fixtures/debate-abstain-artifact/` (New)
**Subsystems**: tests
**Dependencies**: T017, T019, T020, T021

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L274-L275](2026-04-25-debate-plan.md#L274-L275) — Section: File Impact Summary (vibes-check fixtures)
- Plan: [docs/2026-04-25-debate-plan.md#L321](2026-04-25-debate-plan.md#L321) — Section: Vibes-check fixtures
- Plan: [docs/2026-04-25-debate-plan.md#L344-L351](2026-04-25-debate-plan.md#L344-L351) — Section: AC Coverage (R6 dedup, canonical merge order, [Px] strip, verdict tiebreaks, Option B, terminal-abstention, degraded-below-2)
- Spec: [docs/2026-04-25-debate-spec.md#L150-L172](2026-04-25-debate-spec.md#L150-L172) — Section: R1 Verification GWT cases

**Goal**: Complete the R1 + R6 + falsifiable + vibes-check fixture coverage so all of Phase E's primitives are end-to-end tested.

**Scope**:
- In: Extended test scripts; vibes-check fixture directories with planted-disagreement artifacts.
- Out: Phase F UX tests (T026); E2E smoke (T027).

**Changes**:
- `bin/tests/test-debate-anonymization.sh` — Exists — extend with R1 GWT cases from spec L150-L172: deny-list scrub on 13 terms case-insensitive whole-word; counter-examples; adjacent-term iteration `Claude Codex`/`Claude Codex Gemini`; per-recipient ordering shuffle (N≥3); abstained-peer skeleton render; active-peer skeleton render with empty `findings=[]` collapsing to `Findings: (none)`; per-finding `confidence` and per-peer `summary` excluded from rendered peer block.
- `bin/tests/test-debate-aggregation.sh` — Exists — extend with: verdict tiebreaks per consensus mode; Option B exclusion; terminal-abstention; degraded-below-2 mid-debate; falsifiable-acceptance two-clause assertion (consumes T016's `debate-bad-artifact/`).
- `bin/tests/fixtures/debate-ambiguous-artifact/` — New — vibes-check fixture: artifact where reviewers historically disagree; manual inspection asserts Round 2 differs from Round 1 for ≥1 reviewer.
- `bin/tests/fixtures/debate-abstain-artifact/` — New — vibes-check fixture: one reviewer set to always abstain; manual inspection asserts surviving reviewers reference abstain in reasoning OR remain stable; no phantom peer findings.

**Acceptance Criteria**:
1. **R1 GWT cases**: all pass on both macOS and Linux; vibes-check fixtures (`debate-ambiguous-artifact/`, `debate-abstain-artifact/`) include `README.md` documenting the manual inspection criterion.
2. **R6 GWT + behaviors**: canonical-merge-order + verdict-tiebreak + Option B + terminal-abstention + degraded-below-2 cases pass.
3. **Falsifiable-acceptance two-clause test PASSES** (was expected-fail in T016 by design — Clause 1 existence + Clause 2 retention both green).

**Verification**:
- Full Phase E test suite passes: `bash bin/tests/test-debate-anonymization.sh && bash bin/tests/test-debate-aggregation.sh`.
- T016's falsifiable-acceptance test now PASSES (Clause 1 + Clause 2 both green).
- Cross-platform: tests run on both macOS CI and Linux CI.

**Notes for Agent**:
- The falsifiable test must assert BOTH clauses (existence in Round 1 AND retention in final aggregate); a single ∀-quantified statement is vacuously satisfied if no Round-1 P1 exists at the planted location.
- Vibes-check fixtures are manual-inspection only — document the criterion in the fixture README; don't assert programmatically.

</details>

---

## Phase F — UX, Telemetry, Docs, Launch

### - [ ] **T023** [P] Gate report renderer extensions (Strategy column + debate indicator + `aggregate.json` cards)

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P2
**Story**: Phase F
**Parallel**: [P] (different file from T024/T025/T026)
**Primary Files**: `bin/review-gate-hook.sh` (Exists, modify)
**Subsystems**: hook
**Dependencies**: T020

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L28](2026-04-25-debate-plan.md#L28) — Section: Scope (gate report extensions)
- Plan: [docs/2026-04-25-debate-plan.md#L150](2026-04-25-debate-plan.md#L150) — Section: High-Level Approach, Phase F (Strategy column + debate indicator)
- Plan: [docs/2026-04-25-debate-plan.md#L281](2026-04-25-debate-plan.md#L281) — Section: File Impact Summary (`bin/review-gate-hook.sh` renderer)
- Plan: [docs/2026-04-25-debate-plan.md#L359](2026-04-25-debate-plan.md#L359) — Section: AC Coverage (Strategy column rightmost + debate indicator)
- Spec: [docs/2026-04-25-debate-spec.md#L287-L302](2026-04-25-debate-spec.md#L287-L302) — Section: R9 Backwards-compatible CLI surface (renderer changes preserve gate-report stability under non-debate)

**Goal**: When `aggregate.json` exists in `$REVIEWS_DIR`, the gate report renderer adds (a) a "Debate: round N/N" indicator near the top; (b) a Strategy column appended rightmost in the per-reviewer table; (c) one card per defect rendered from `aggregate.json` (replacing the per-reviewer concat under `--debate`).

**Context**: Per Plan L104, the consensus calculator (the gate-decision authority) is unchanged. Only the rendering layer changes. Risk per Plan L298: undocumented external markdown-parsers of the gate report will break — documented as non-supported breakage path; recommended migration is `wait --json` (shape unchanged).

**Scope**:
- In: Renderer changes in `bin/review-gate-hook.sh` (the existing gate-report rendering function — separate from the consensus calculator). New layout when `aggregate.json` is present.
- Out: Consensus calculator changes (none — Plan L104).

**Changes**:
- `bin/review-gate-hook.sh` (gate-report renderer, NOT the consensus calculator at lines 924-1080) — Exists — when `$REVIEWS_DIR/aggregate.json` exists: prepend "Debate: round $rounds_consumed/$total_rounds" indicator. Per-reviewer table: append Strategy column rightmost (sourced from `aggregate.strategies{<reviewer>}`). Findings section: render one card per `aggregate.findings[*]` entry with priority + title + body + `raised_by` (when present).

**Acceptance Criteria**:
1. When `aggregate.json` is present, gate-report markdown contains "Debate: round N/N" indicator and Strategy column rightmost.
2. When absent, renderer is byte-identical to today (T002 byte-parity passes).
3. Per-defect cards source from `aggregate.findings[]`, not from per-reviewer concat.

**Verification**:
- Snapshot test: render gate-report against a known `aggregate.json` fixture; assert byte-equal to checked-in expected output.
- T002 byte-parity test passes (absence of `aggregate.json` → today's renderer).

**Notes for Agent**:
- This is presentation-only; consensus calculator code (lines 924-1080) MUST NOT be touched.
- The Strategy column displays one of `verification-first`, `falsification-first`, `decompose` — keep the names short to fit the column width.
- Document the markdown-parser breakage risk in a header comment (Plan L298).

</details>

### - [ ] **T024** [P] `gate-state.json.debate` block + `iterations/<iter>/debate-telemetry.json`

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P2
**Story**: Phase F
**Parallel**: [P] (file: `bin/review-gate-debate.sh`; sequence with T021/T020 by file overlap, but parallel with T023/T026)
**Primary Files**: `bin/review-gate-debate.sh` (Exists, modify), `bin/telemetry-lib.sh` (Exists, modify)
**Subsystems**: review-gate, telemetry
**Dependencies**: T021

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L27](2026-04-25-debate-plan.md#L27) — Section: Scope (gate-state.debate + per-iteration telemetry)
- Plan: [docs/2026-04-25-debate-plan.md#L227-L233](2026-04-25-debate-plan.md#L227-L233) — Section: Data Model (debate block + telemetry shapes)
- Plan: [docs/2026-04-25-debate-plan.md#L283](2026-04-25-debate-plan.md#L283) — Section: File Impact Summary (`bin/telemetry-lib.sh`)
- Spec: [docs/2026-04-25-debate-spec.md#L314-L453](2026-04-25-debate-spec.md#L314-L453) — Section 4: Instrumentation & Release Checks

**Goal**: On the success path, the coordinator writes the additive `gate-state.json.debate` block (pinned shape per Plan L227) BEFORE returning control to the Stop-hook. On the non-success path (SIGINT cancellation, aggregator failure, degraded-below-2), the coordinator writes `iterations/<iter>/debate-telemetry.json` with whatever partial state it collected.

**Context**: Per Plan L229, the Stop-hook updates `gate-state.json` via jq patch syntax which preserves unspecified top-level fields, so the additive `debate` block survives `pending → awaiting_decision → resolved` transitions without explicit Stop-hook code change.

**Scope**:
- In: Two writers (success-path + non-success-path).
- Out: Distinct exit codes for non-success paths (T025 — uses these telemetry writes).

**Changes**:
- `bin/review-gate-debate.sh` `run_debate_coordinator` — Exists — on success path (after `aggregate.json` write but before exit): jq-patch `gate-state.json` to add `.debate = {rounds, mode, consensus_mode, strategies, rounds_telemetry, aggregator_notes}`. On non-success path (trap SIGINT, aggregator failure, degraded-below-2): write `$ITERATIONS_DIR/debate-telemetry.json` with the same shape but possibly truncated `rounds_telemetry`.
- `bin/telemetry-lib.sh` — Exists — add a small helper `write_debate_telemetry "$path" "$json"` if convenient (or inline if minimal).

**Acceptance Criteria**:
1. Success path: `gate-state.json` ends with the `debate` block populated; `iterations/<iter>/debate-telemetry.json` does NOT exist.
2. Cancel/agg-fail/degraded paths: `gate-state.json.debate` ABSENT (no `"debate": null`, no `"debate": {}`); `iterations/<iter>/debate-telemetry.json` populated with whatever partial state was collected.
3. Stop-hook transitions (`pending → awaiting_decision → resolved`) preserve the `debate` block (verified by T028).

**Verification**:
- Success-path E2E (T028) ends with `gate-state.json.debate` populated post-Stop-hook.
- SIGINT mid-coordinator + aggregator-fail + degraded-below-2 each produce `iterations/<iter>/debate-telemetry.json` with non-empty content.
- **Negative**: `gate-state.json.debate` MUST be absent on non-success paths (no `null` placeholder).

**Notes for Agent**:
- Use `jq '. + {debate: $d}' --argjson d "$debate_json"` for the success-path write — preserves existing fields.
- The Stop-hook's jq-patch convention (e.g., `.status = $status`) preserves unspecified fields; verify by reading current Stop-hook code.
- Pinned shape per Plan L227: `{rounds, mode, consensus_mode, strategies{}, rounds_telemetry[], aggregator_notes[]}`.

</details>

### - [ ] **T025** Distinct exit codes (130 / 5 / 6 / 2) + on-disk-shape correctness

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P1
**Story**: Phase F
**Parallel**:
**Primary Files**: `bin/review-gate-debate.sh` (Exists, modify), `bin/tests/test-debate-end-to-end.sh` (Exists, extend)
**Subsystems**: review-gate, tests
**Dependencies**: T024

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L196-L211](2026-04-25-debate-plan.md#L196-L211) — Section: Architecture (pinned exit codes + on-disk shapes)
- Plan: [docs/2026-04-25-debate-plan.md#L376-L380](2026-04-25-debate-plan.md#L376-L380) — Section: D6
- Plan: [docs/2026-04-25-debate-plan.md#L358](2026-04-25-debate-plan.md#L358) — Section: AC Coverage (distinct exit codes + stderr messages)
- Spec: [docs/2026-04-25-debate-spec.md#L303-L313](2026-04-25-debate-spec.md#L303-L313) — Section: R10 Per-review-type applicability (whitelist exit 2)
- Spec: [docs/2026-04-25-debate-spec.md#L374](2026-04-25-debate-spec.md#L374) — Section 4 (degraded-below-2 → `requires_decision` shape)

**Goal**: Wire the four reserved exit codes + on-disk shape semantics into `run_debate_coordinator`: SIGINT cancellation = 130 (status `pending`, `$REVIEWS_DIR` empty); aggregator failure = 5 (same); degraded-below-2 (preflight or mid-debate) = 6 (status `awaiting_decision`, `consensus.verdict=requires_decision`, `$REVIEWS_DIR` empty); bare-spawn whitelist rejection = 2 (existing pattern).

**Context**: Per Plan L207-L209, degraded-below-2 lands in `awaiting_decision` (a deterministic feature outcome — "I cannot judge" requires a human decision). Cancellation/agg-fail stay `pending` (abnormal exit, no judgment produced; existing 30-min active-gate guard governs).

**Scope**:
- In: SIGINT trap; aggregator-failure handler; degraded-below-2 paths (preflight in T004 already handles preflight; this task adds mid-debate); whitelist rejection error message format.
- Out: Stop-hook changes (none — calculator unchanged per Plan L104).

**Changes**:
- `bin/review-gate-debate.sh` `run_debate_coordinator` — Exists — `trap '__handle_sigint' INT TERM`; `__handle_sigint` writes nothing to `$REVIEWS_DIR`, leaves `gate-state.json.status="pending"`, exits 130. On aggregator failure (`compute_aggregate_findings` returns non-zero or jq parse error): leave `$REVIEWS_DIR` empty, stderr `aggregator failed: <reason>`, exit 5. Degraded-below-2 (mid-debate, after T020's check): write `gate-state.json` per D6 (`status="awaiting_decision"`, `consensus={verdict:"requires_decision",...}`), leave `$REVIEWS_DIR` empty, stderr `debate degraded below 2 active reviewers in the final peer round`, exit 6. Whitelist rejection (T004) already exit 2; format stderr as `--debate not supported for --type <X>; allowed types: code, plan, spec, epic-verify`.
- `bin/tests/test-debate-end-to-end.sh` — Exists — add per-failure-mode test: assert exit code + stderr + on-disk shape.

**Acceptance Criteria**:
1. **Cancellation paths (status `pending`)**: SIGINT mid-Round-1 → exit 130, `$REVIEWS_DIR` empty, `gate-state.json.status="pending"`, staging dir preserved; whitelist rejection → exit 2 with stderr naming the rejected type and the four allowed types.
2. **Aggregator failure**: jq parse error → exit 5, `$REVIEWS_DIR` empty, `gate-state.json.status="pending"`, stderr `aggregator failed: <reason>`.
3. **Degraded-below-2 mid-debate (status `awaiting_decision`)**: exit 6, `$REVIEWS_DIR` empty, `gate-state.json.status="awaiting_decision"`, `consensus.verdict="requires_decision"`, telemetry under `iterations/<iter>/debate-telemetry.json` populated.

**Verification**:
- Per-failure-mode tests in `bin/tests/test-debate-end-to-end.sh` pass.
- Recovery: after exit 130 / 5, `bin/review-gate spawn --debate ...` with `REVIEW_GATE_RERUN=1` works as today (reuses existing 30-min active-gate guard at lines 2273-2303).
- Recovery: after exit 6, `bin/review-gate resolve --reason "..."` works as for any `awaiting_decision` gate.

**Notes for Agent**:
- Exit 130 = 128 + SIGINT signal number (existing convention; not a "new" code).
- Per Plan L209, degraded vs cancel/agg-fail are intentionally distinct on-disk shapes — degraded is a deterministic feature outcome ("I cannot judge"); cancel/agg-fail are abnormal exits where no judgment was produced.
- Bash 3.2 — trap handlers can't use Bash-4 features. Use `trap '...' INT TERM`.

</details>

### - [ ] **T026** [P] README + final `--help` documentation (Debate mode section)

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P2
**Story**: Phase F
**Parallel**: [P] (different files from T023/T024/T025)
**Primary Files**: `README.md` (Exists, modify), `bin/review-gate` (Exists, modify — final `--help` text only)
**Subsystems**: docs, review-gate
**Dependencies**: T025

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L30](2026-04-25-debate-plan.md#L30) — Section: Scope (README + --help updates)
- Plan: [docs/2026-04-25-debate-plan.md#L246-L247](2026-04-25-debate-plan.md#L246-L247) — Section: API/Interface Design (--debate-seed hidden)
- Plan: [docs/2026-04-25-debate-plan.md#L290](2026-04-25-debate-plan.md#L290) — Section: File Impact Summary (README.md)
- Plan: [docs/2026-04-25-debate-plan.md#L297](2026-04-25-debate-plan.md#L297) — Section: Risks (token + wall-clock cost bands documented)
- Spec: [docs/2026-04-25-debate-spec.md#L287-L302](2026-04-25-debate-spec.md#L287-L302) — Section: R9 Backwards-compatible CLI surface (`--debate-seed` hidden from help; `--debate` documented)

**Goal**: Land the README "Debate mode" section and finalize `bin/review-gate --help` text so they cover: flag (`--debate`), round shape (2 fast/smart, 3 max), per-mode token cost band (~2x non-debate, 3x under max), per-mode wall-clock latency band, `<2 reviewers + --debate` hard error, byte-parity guarantee, and the `requires_decision` outcome under degraded-below-2.

**Context**: `--debate-seed N` is HIDDEN — must NOT appear in `--help` or README (Plan L246-L247). T010 already asserts this in the help-output test.

**Scope**:
- In: README new "Debate mode" section; `bin/review-gate` `--help` text additions.
- Out: Slash-command wrapper docs (Plan L290 — wrappers shell out via `$ARGUMENTS`; v1 doesn't validate at wrapper layer).

**Changes**:
- `README.md` — Exists — new "## Debate mode" section covering: opt-in flag, round shape per mode, token + wall-clock cost band, hard errors (`<2 reviewers`, whitelist rejection on bare `spawn --debate --type X` for non-judging X), byte-parity guarantee, the `requires_decision` outcome on degraded-below-2.
- `bin/review-gate` `--help` text — Exists — document `--debate` (boolean opt-in). Do NOT document `--debate-seed N`.

**Acceptance Criteria**:
1. `bin/review-gate --help` lists `--debate` with a one-line description; does NOT mention `--debate-seed`.
2. README "Debate mode" section exists and covers all 6 documentation items above.
3. T010 / T006's help-output test passes (asserts `--debate-seed` is NOT in help output).

**Verification**:
- Run `bin/review-gate --help` and `bin/review-gate spawn --help`; manually inspect.
- Run `bash bin/tests/test-debate-preflight.sh` (which includes the help-output test from T006).

**Notes for Agent**:
- Per Plan L297, the cost band is roughly 2x non-debate (3x under `--mode max`). Document as a band, not a precise number.
- Per Plan L298, an undocumented external markdown-parser of the gate report will break with the new Strategy column / debate indicator. Briefly note this in the README ("recommended migration: `wait --json`, whose shape is unchanged") so external integrators have a path forward.

</details>

### - [ ] **T027** [integration-path-test] End-to-end smoke tests per review type

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P1
**Story**: Phase F
**Parallel**:
**Primary Files**: `bin/tests/test-debate-end-to-end.sh` (Exists, finalize)
**Subsystems**: tests
**Dependencies**: T023, T024, T025, T021

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L33](2026-04-25-debate-plan.md#L33) — Section: Scope (E2E smoke tests)
- Plan: [docs/2026-04-25-debate-plan.md#L268](2026-04-25-debate-plan.md#L268) — Section: File Impact Summary (`bin/tests/test-debate-end-to-end.sh`)
- Plan: [docs/2026-04-25-debate-plan.md#L319](2026-04-25-debate-plan.md#L319) — Section: Testing Strategy (E2E smoke tests)
- Spec: [docs/2026-04-25-debate-spec.md#L19](2026-04-25-debate-spec.md#L19) — Section: Falsifiable acceptance signal (two-clause launch gate exercised by E2E)
- Spec: [docs/2026-04-25-debate-spec.md#L303-L313](2026-04-25-debate-spec.md#L303-L313) — Section: R10 Per-review-type applicability (one smoke per review type)

**Goal**: Finalize `bin/tests/test-debate-end-to-end.sh` with one smoke per review type (`code`, `plan`, `spec`, `epic-verify`) under `--debate` and one without. Each smoke asserts: exit 0, debate indicator + Strategy column in gate-report markdown, `aggregate.json` keys present, `gate-state.json.debate` block populated post-Stop-hook.

**Context**: This is the [integration-path-test] for Phase F. It's the most comprehensive end-to-end coverage — it exercises every layer (flag parsing → preflight → coordinator → reviewers → anonymization → aggregator → atomic promote → Stop-hook → gate-report rendering).

**Scope**:
- In: 8 smokes total (4 review types × 2 modes: with `--debate`, without).
- Out: Manual launch checklist (T028).

**Changes**:
- `bin/tests/test-debate-end-to-end.sh` — Exists — finalize: for each review type × debate-mode, drive `bin/review-gate spawn-<type>-review [--debate]` against canned reviewer outputs; assert exit code + presence of `aggregate.json` (under `--debate`) + presence of "Debate: round N/N" + Strategy column + `gate-state.json.debate` (under `--debate`); under `--debate` absent, assert byte-parity vs. `pre-debate-baseline/` (T002 already covers this; cross-reference).

**Acceptance Criteria**:
1. All 8 smokes pass.
2. **Config override test**: `--debate` flag flows through from CLI → preflight → coordinator → per-reviewer JSON additive fields (verified by inspecting `<reviewer>.json` for `strategy` field).
3. R10 generator-slash-command test: `/cerberus:create-spec --debate` either silently ignores or fails downstream at `bin/generate` (both acceptable v1 per Plan L355).

**Verification**:
- `bash bin/tests/test-debate-end-to-end.sh` exits 0.
- Mutate `aggregate.json.verdict` → `requires_decision` (illegal value) and assert E2E smoke catches it.

**Notes for Agent**:
- Use canned reviewer outputs (existing test pattern); do NOT call real model APIs.
- Each smoke runs in its own temp HOME so they don't interfere.
- Per Plan L355, `--debate` on generator slash commands is acceptable v1 if it silently ignores OR fails downstream — assert one of these two outcomes.

</details>

### - [ ] **T028** Manual launch checklist (Gemini jailbreak surface, calibration, vibes review)

<details><summary>Task spec</summary>

**Type**: task
**Priority**: P1
**Story**: Phase F
**Parallel**:
**Primary Files**: `docs/2026-04-25-debate-plan.md` (Exists, append launch-record section as needed)
**Subsystems**: docs (manual gate)
**Dependencies**: T026, T027

**Source Documents**:
- Plan: [docs/2026-04-25-debate-plan.md#L150](2026-04-25-debate-plan.md#L150) — Section: High-Level Approach, Phase F (manual smoke checks)
- Plan: [docs/2026-04-25-debate-plan.md#L300](2026-04-25-debate-plan.md#L300) — Section: Risks (Gemini read-only policy under peer broadcasts)
- Plan: [docs/2026-04-25-debate-plan.md#L322](2026-04-25-debate-plan.md#L322) — Section: Testing & Validation Strategy (Manual smoke checks)
- Plan: [docs/2026-04-25-debate-plan.md#L361](2026-04-25-debate-plan.md#L361) — Section: AC Coverage (Vibes acceptance signals)
- Spec: [docs/2026-04-25-debate-spec.md#L314-L453](2026-04-25-debate-spec.md#L314-L453) — Section 4: Instrumentation & Release Checks (the launch checklist)

**Goal**: Execute the Section 4 launch checklist before flagging `--debate` for general use: (a) Gemini jailbreak surface manual smoke; (b) confidence-update behavior on representative artifact (Round 2 confidence diverges from Round 1 for ≥1 reviewer); (c) calibration check (anchors influence behavior — overconfident reviewer cited as evidence of anchor non-effect would be a flag); (d) per-mode token + runtime cost band sampled on a real artifact; (e) maintainer vibes review on three real artifacts.

**Context**: This is the maintainer-gates GA launch. Task is to RECORD outcomes (in a launch-record section appended to the plan or in a separate `docs/2026-04-25-debate-launch-record.md` if preferred) so future iterations can audit.

**Scope**:
- In: Manual execution + recording of 5 checks. No code changes.
- Out: Anything code-related (lands in earlier tasks).

**Changes**:
- `docs/2026-04-25-debate-plan.md` (or `docs/2026-04-25-debate-launch-record.md`) — Exists/New — append "Launch Record" section: (a) Gemini jailbreak surface check — what was tested, outcome; (b) confidence-update behavior — sample artifact + observation; (c) calibration check — sample artifact + verdict on whether anchors influenced behavior; (d) cost band — measured tokens + wall-clock for one fast/smart/max run; (e) vibes review — three real artifacts + maintainer's go/no-go per artifact.

**Acceptance Criteria**:
1. **Section 4 launch checklist**: all 5 manual checks executed and recorded; Gemini read-only policy enforced unchanged on every Gemini call (no jailbreak observed).
2. **Confidence-update behavior**: at least one fixture-or-real artifact shows Round 2 `overall_confidence` diverging from Round 1 for ≥1 reviewer (debate actually updates confidence).
3. **Maintainer GA gate**: maintainer go on at least 2 of 3 vibes-review artifacts before flagging `--debate` for general use; record signed off in launch record.

**Verification**:
- The launch record exists with all 5 sections populated.
- The maintainer signs off on the GA flag (separate process, but the record is the artifact).

**Notes for Agent**:
- This task is NOT auto-executable — it requires a human in the loop.
- Per Plan L300, the Gemini read-only policy is enforced unchanged on every Gemini call regardless of debate state. Manual jailbreak smoke verifies no new surface is opened by debate prompts.
- Vibes-review artifacts: pick three real reviews of varying complexity (e.g., a small PR, a multi-file refactor, a contentious design doc).

</details>

---

## Dependencies Graph

```
PHASE A (gate)
T001 ── T002 [integration-path-test]

PHASE B (plumbing)
T002 ──────► T003 ──► T004 ──► T006 [integration-path-test]
                  │       └──► T005 ──┘
                  └──► T005 ───────────┘

PHASE C (strategy + confidence)
T002 ──► T007 ──► T008 ──┐
T002 ──► T009 ───────────┤
                          ├──► T011 [system-wiring]
T004, T005 ───────────────┘
T007, T008, T009 ────────────► T010 [integration-path-test]

PHASE D (coordinator + Round 1)
T011 ──► T012 [integration-path-test]
       └────► T015 (depends on T011 schema variant)
T012 ──► T013 ──► T014 ──► T015

PHASE E (anonymization + full debate) — serialized on bin/review-gate-debate.sh
T015 ──► T016 [integration-path-test]
T016 ──► T017 ──► T018 ──► T019 ──► T020 ──► T021 ──► T022
                                 (T021 also explicitly deps T018 + T020)
                                 (T022 also explicitly deps T017, T019, T020, T021)

PHASE F (UX + telemetry + docs + launch)
T020 ──► T023
T021 ──► T024
T024 ──► T025
T025 ──► T026
T021, T023, T024, T025 ──► T027 [integration-path-test]
T026, T027 ──► T028 (manual gate)
```

## AC Coverage Map

(See plan L331-L360 for the full table; this map shows owning task per AC.)

| Spec AC | Owning Task | Verification |
|---|---|---|
| Byte-parity for valid non-debate invocations (R9) | T002, T011 | T002 byte-parity suite + T011 schema variant non-debate branch |
| Falsifiable two-clause launch gate | T022 (asserted), T016 (fixture scaffold) | `debate-bad-artifact/` + assertion in `test-debate-aggregation.sh` |
| `<2 reviewers + --debate` hard error | T004 (preflight), T020 (mid-debate) | `test-debate-preflight.sh` + `test-debate-end-to-end.sh` |
| Bare-spawn whitelist rejection (R10) | T004 | `test-debate-preflight.sh` |
| Anonymization deny-list (R1) | T017 | `test-debate-anonymization.sh` + R1 fixtures |
| Anonymization adjacent-term iteration (R1) | T017 | `Claude Codex Gemini` fixture |
| Per-recipient peer ordering shuffle (R1) | T017 | Fixture asserting orderings differ |
| `--debate-seed N` byte-stable replay | T017 | macOS+Linux fixture byte-equality |
| Calibration anchor byte-equality across templates (R2/R10) | T010, T011 | `cmp` against `confidence-anchors.md` |
| Per-(artifact, reviewer) strategy stability (R3) | T009, T010 | R3 fixture stability test |
| Strategy collision walk + N=2/3/4 cases (R3) | T009, T010 | R3 fixture set |
| Dedup predicate (R6) | T019 | R6 GWT fixtures |
| Canonical merge order under non-transitive overlap (R6) | T019 | Non-transitive overlap fixture |
| `[Px]` strip behaviors (R6) | T019 | `[Px]` fixture set |
| Verdict tiebreaks under each consensus mode (R6) | T020 | Per-consensus-mode fixture |
| Final-round Option B exclusion (R6) | T021 | 3-reviewer-with-final-round-abstain fixture |
| Terminal-abstention rule | T021 | Abstain-Round-1-not-invoked-Round-2 fixture |
| Degraded-below-2 mid-debate | T020 | Mid-debate eligibility fixture |
| Schema variant for Codex `--output-schema` (R9) | T011 | Schema-variant test |
| Repair-prompt schema follows variant (R9) | T011 | `repair_review_output()` test |
| Help output documents `--debate` (R9) | T026 | T006/T010 help-output assertion |
| `--debate` on generator slash commands does NOT crash badly (R10) | T027 | E2E test |
| `gate-state.json.debate` block on success-only | T024 | E2E + telemetry test |
| `iterations/<iter>/debate-telemetry.json` on partial state | T024 | Per-failure-mode test |
| Distinct exit codes (130 / 5 / 6 / 2) | T025 | Per-failure-mode test |
| Gate report Strategy column rightmost + debate indicator | T023 | Snapshot test |
| Vibes acceptance signals (ambiguous, abstain) | T022 (fixtures), T028 (manual) | Manual inspection on `debate-ambiguous-artifact/` and `debate-abstain-artifact/` |

## Sizing Verification

| Task | Files | Subsystems | ACs | Mechanical? | Status |
|---|---|---|---|---|---|
| T001 | 1 + fixtures | 1 | 3 | Yes (capture sweep) | OK |
| T002 | 1 | 1 | 3 | No | OK |
| T003 | 1 | 1 | 3 | No | OK |
| T004 | 1 | 1 | 3 | No | OK |
| T005 | 1 | 1 | 3 | No | OK |
| T006 | 1 | 1 | 3 | No | OK (consolidated AC3+AC4 into "byte-parity preservation") |
| T007 | 4 | 1 | 3 | Yes | OK |
| T008 | 4 | 1 | 3 | Yes | OK |
| T009 | 1 | 1 | 3 | No | OK (consolidated hash + hard-error into AC1) |
| T010 | 1 + fixtures | 1 | 3 | No | OK (consolidated R3 stability + collision walk into AC1; rolled test mechanics into AC3) |
| T011 | 2 | 1 | 3 | No | OK |
| T012 | 2 | 2 (review-gate, tests) | 3 | No | OK |
| T013 | 1 | 1 | 3 | No | OK |
| T014 | 1 | 1 | 3 | No | OK |
| T015 | 1 | 1 | 3 | No | OK |
| T016 | 3 | 2 (review-gate, tests) | 3 | No | OK |
| T017 | 2 | 2 (review-gate, tests) | 3 | No | OK (consolidated deny-list + iterative; consolidated seeded shuffle + production non-determinism) |
| T018 | 1 | 1 | 3 | No | OK (consolidated active+abstained skeletons; consolidated Round-3 self-block + peer_responses_seen) |
| T019 | 3 | 2 | 3 | No | OK (consolidated canonical merge order + equal-confidence tiebreak) |
| T020 | 1 | 1 | 3 | No | OK (consolidated FAIL-blocking + tiebreak into verdict computation AC) |
| T021 | 1 | 1 | 3 | No | OK (consolidated earlier-round-not-carried-forward + degraded-below-2 composition) |
| T022 | 4 + fixtures | 1 | 3 | No | OK (consolidated R1 GWT + vibes-check fixtures README into AC1) |
| T023 | 1 | 1 | 3 | No | OK |
| T024 | 2 | 2 | 3 | No | OK |
| T025 | 2 | 2 | 3 | No | OK (consolidated SIGINT + whitelist into "cancellation paths") |
| T026 | 2 | 2 | 3 | No | OK |
| T027 | 1 | 1 | 3 | No | OK |
| T028 | 1 | 1 | 3 | No | OK (consolidated execution + Gemini policy into AC1) |

**Sizing summary**: All 28 tasks within hard limits (≤12 files, ≤3 subsystems, ≤3 ACs). Eleven tasks were consolidated from 4-5 ACs to 3 ACs by grouping tightly-coupled invariants under single AC labels with semicolon-delimited sub-clauses; no AC content was lost.

## Coverage Artifacts

### Requirements Snapshot

| Type | Source | Text (paraphrased; full text in plan/spec) |
|---|---|---|
| Objective | Plan | Add opt-in `--debate` flag to `bin/review-gate spawn` + 4 named subcommands; preserve byte-for-byte parity for valid non-debate invocations |
| Obligation | Plan L7, L20, L67-L79 | MUST be byte-for-byte equivalent for valid non-debate invocations; MUST be Bash 3.2 compatible; MUST use POSIX ERE deny-list with iterative substitution |
| Obligation | Plan L23, L70 | MUST never set `aggregate.json.verdict` to `requires_decision` (3-value enum); MUST emit byte-identical schema bytes to pre-feature under `--debate` absent |
| Obligation | Plan L76-L78 | MUST hard-error if neither `shasum` nor `sha256sum` found; production shuffle MUST NOT cross-derive from seed input |
| Obligation | Spec R1 L126-L173 | MUST anonymize peer block via canonical POSIX ERE; MUST iterate until idempotent |
| Obligation | Spec R3 L199-L211 | MUST compute strategy via SHA-256 + collision walk in canonical alphabetical order |
| Obligation | Spec R6 L212-L286 | MUST FAIL-block on any P0/P1; MUST set `consensus.verdict=requires_decision` on FAIL-block |
| Obligation | Spec R9 L287-L302 | MUST be backwards-compatible CLI surface; MUST hide `--debate-seed N` from help |
| Obligation | Spec R10 L303-L313 | MUST reject `--debate` on bare `spawn` for non-judging `--type` |
| AC | Plan L334-L360 | (See AC Coverage Map above — all 25 ACs mapped to owning tasks) |

### Consistency Audit

| Item | Spec | Plan | Status | Notes |
|---|---|---|---|---|
| R1 anonymization regex flavor | POSIX ERE, canonical word-boundary | Same | Match | Plan L67 quotes spec verbatim |
| R2 anchor block bytes | Pinned literal in spec L179-L198 | Pinned to `prompts/strategies/confidence-anchors.md` byte-identical | Match | T007 verifies via `cmp` |
| R3 hash primitive | `shasum -a 256` preferred, `sha256sum` fallback | Same; hard-error if neither | Match | Plan L66 quotes spec |
| R3 `<artifact_id>` | per-type definition | Same | Match | Plan L235-L240 enumerates per-type |
| R6 dedup predicate | 4-clause AND | Same | Match | Plan L23 inherits |
| R6 canonical merge order | Pre-sort + greedy fold | Same | Match | T019 implements |
| R6 verdict authority | Stop-hook = single source of truth; `aggregate.verdict` presentation only | Same; intentional split-brain documented | Match | Plan L194 + L308 |
| R9 byte-parity exceptions | Help, version, newly-rejected-flag-combo errors | Same | Match | Plan L247 inherits |
| R9 hidden `--debate-seed` | Hidden from help; production must NOT cross-derive from seed | Same | Match | Plan L77, L246 |
| R10 whitelist | `code, plan, spec, epic-verify` | Same | Match | T004 enforces |
| Final-round abstain handling | Option B (excluded from final aggregation) | Same | Match | Plan L24 |
| Terminal-abstention rule | Pinned uniformly across spec | Same | Match | Plan L25, T021 |
| Round 3 prior-round-self block | Most recent prior round only (Round 2) | Same | Match | Plan L251 |
| Degraded-below-2 on-disk shape | `awaiting_decision` + `consensus.verdict=requires_decision` | Same | Match | Plan L202, L379 |
| Per-machine determinism scope | (Implicit in spec R3 via realpath) | Explicit per D12 | Match (plan adds clarification, no deviation) | Plan L389 |

### Deviation Log

| Source | Deviation | Rationale | Approved? |
|---|---|---|---|
| (none) | None — plan inherits all spec requirements verbatim. The plan adds clarifying documentation (D12 per-machine determinism scope; D6 reserved exit codes; D2 line-consumption invariant; D4 per-round staging dir) that do not contradict the spec. | — | — |

### Obligation Coverage

| Plan/Spec Clause | Task(s) | Verification |
|---|---|---|
| MUST byte-parity for valid non-debate invocations (Plan L7) | T002, T011 | `cmp` over `pre-debate-baseline/` |
| MUST be Bash 3.2 compatible (Plan L64) | All Bash tasks | Test runs in macOS Bash 3.2 |
| MUST POSIX ERE deny-list w/ canonical word-boundary (Plan L67) | T017 | `test-debate-anonymization.sh` BSD/GNU fixtures |
| MUST iterative substitution loop until idempotent (Plan L68) | T017 | `Claude Codex Gemini` fixture |
| MUST `shasum -a 256` preferred / `sha256sum` fallback / hard-error (Plan L66) | T009 | Hash primitive negative test |
| MUST NEVER set `aggregate.json.verdict` to `requires_decision` (Plan L23) | T020 | Hygiene test on verdict value |
| MUST be opt-in (default off) (Plan L7) | T003 | Default behavior test |
| MUST reject `--debate` for non-judging `--type` (Spec R10) | T004 | `test-debate-preflight.sh` whitelist case |
| MUST hard-error on `<2 reviewers + --debate` (Plan L26, Spec R6) | T004 (preflight), T020 (mid-debate) | Per-failure-mode test |
| MUST per-(artifact, reviewer) SHA-256 + collision walk (Spec R3) | T009 | R3 fixture set |
| MUST anonymize peer block (Spec R1) | T017 | R1 fixture set |
| MUST shuffle peer order per recipient (Spec R1) | T017 | Per-recipient ordering fixture |
| MUST dedup with 4-clause predicate (Spec R6) | T019 | R6 GWT fixtures |
| MUST FAIL-block on any P0/P1 (Spec R6) | T020 | P0/P1 fixture |
| MUST exclude final-round abstainers from aggregation (Spec R6) | T021 | Option B fixture |
| MUST not invoke abstained reviewer in subsequent rounds (Spec R1, R6) | T021 | Terminal-abstention fixture |
| MUST emit byte-identical schema under `--debate` absent (Plan L70) | T011 | Schema-variant byte-parity |
| MUST NOT document `--debate-seed N` in help (Plan L246) | T026 | Help-output test in T006/T010 |
| MUST production shuffle NOT cross-derive from seed input (Plan L78) | T017 | Same-seed-different-runs fixture (production path) |
| MUST `gate-state.json.debate` absent on non-success paths (Plan L227) | T024 | Per-failure-mode telemetry test |

### System Wiring Coverage

| Flow | Wiring Task(s) | Verification |
|---|---|---|
| `--debate` flag → preflight → coordinator decision (or existing path) | T004 (preflight), T011 [system-wiring] (conditional source + dispatch) | T011 + T012 [integration-path-test] |
| `prompts/strategies/<file>.md` → `${PLACEHOLDER}` substitution → rendered prompt → reviewer CLI | T008 (placeholder injection), T011 [system-wiring] (substitution logic) | T010 anchor byte-equality |
| `aggregate.json` → gate report renderer → Strategy column + debate indicator | T023 | Snapshot test |
| Round 1 outputs → anonymization → Round 2 prompt → Round 2 outputs → aggregator → atomic promote → `$REVIEWS_DIR/aggregate.json` + `gate-state.json.debate` | T012, T017, T018, T019, T020, T021, T024 | T027 E2E smoke |
| Per-round staging at `iterations/<iter>/round-N/` → atomic promote on success / preserve on failure | T012, T021 | T025 per-failure-mode on-disk-shape test |

### Propagation Map

| Input/Field/Signal | Origin | Transport | Consumption | Verification |
|---|---|---|---|---|
| `--debate` flag | CLI | `DEBATE` shell var → preflight → conditional source → coordinator | `run_debate_coordinator` decision branch | T012, T027 |
| `--debate-seed N` | CLI | `DEBATE_SEED` shell var → coordinator | Anonymization shuffle (T017) | T017 byte-stable replay fixture |
| `<artifact_id>` | review-type switch on input file | `compute_artifact_id` → `compute_strategy_assignment` | Strategy hash (T009) | T010 R3 stability |
| `STRATEGY{<reviewer>}` | `compute_strategy_assignment` | Coordinator → prompt builder | `${STRATEGY_DIRECTIVE}` substitution (T011) | T010 |
| `overall_confidence`, `findings[*].confidence` | Reviewer JSON | Coordinator post-processing (T013, T015) | Aggregator confidence-tiebreak (T020) | T020 verdict tiebreak fixture |
| `peer_responses_seen` | Coordinator-populated | Per-reviewer JSON additive field | Telemetry only (not parsed back) | T015, T018 |
| `aggregate.json.findings` | Aggregator dedup (T019) | `$REVIEWS_DIR/aggregate.json` | Gate report renderer (T023) | T027 E2E |
| `gate-state.json.debate` | Coordinator success-path write (T024) | `gate-state.json` survives Stop-hook jq-patch | Inspection only | T027 post-Stop-hook check |
| `iterations/<iter>/debate-telemetry.json` | Coordinator non-success-path write (T024) | Per-iteration telemetry dir | Inspection only | T025 per-failure-mode test |
| Exit codes 130/5/6/2 | Coordinator handlers (T025) | Process exit | CI / external tooling | T025 per-failure-mode test |

## Validation Summary (Phase 5 gates)

| Check | Status |
|---|---|
| Obligation coverage | ✅ All 20+ MUST/SHALL clauses mapped to tasks + verification |
| File overlap dependencies | ✅ All same-file overlaps serialized (e.g., T003→T004→T011 on `bin/review-gate`; T012→T013→T014→T015→T016→T021 on `bin/review-gate-debate.sh`) |
| AC coverage | ✅ All 25 spec ACs mapped to owning task |
| No orphan ACs | ✅ Each AC has exactly one primary owner |
| Consistency audit | ✅ No deviations |
| Requirement freeze | ✅ Tasks inherit plan requirements verbatim |
| Dependencies complete | ✅ Conservative when uncertain |
| One outcome per task | ✅ Every task has a single verifiable done state |
| Sizing: hard limits | ✅ All tasks within 12 files / 3 subsystems / 3 ACs |
| Sizing: ACs | ✅ All 28 tasks at ≤3 ACs (11 tasks consolidated from 4-5 to 3 by grouping tightly-coupled invariants) |
| No vague tasks | ✅ Every task has concrete files + verification |
| Startup vs runtime | ✅ Schema emission (startup) and runtime aggregation are distinct tasks |
| Negative-case coverage | ✅ Each preflight + aggregator path has explicit negative cases |
| Merge/precedence semantics | ✅ Confidence-tiebreak + canonical merge order have explicit fixtures |
| End-to-end wiring | ✅ Wiring map covers `--debate` flow + strategy directive flow + aggregate.json flow |
| System wiring coverage | ✅ T011 [system-wiring] tagged |
| Adapter/bridge coverage | ✅ `spawn_reviewer` output-dir param + schema variant + repair-prompt schema all covered |
| Config override test | ✅ T027 verifies `--debate` flow CLI → JSON additive fields |
| Template lifecycle | ✅ Strategy assets created (T007), placeholder injected (T008), substitution wired (T011), used in prompts (T012+) |
| Missing referenced artifacts | ✅ All plan-referenced files verified to exist or marked `New` with prereq task |
| Integration path test | ✅ Each phase has exactly one [integration-path-test] (T002, T006, T010, T012, T016, T027) |
| Source document links | ✅ Every task has Plan + Spec links with line numbers |

## Next Steps

After this TODO is reviewed:

1. **If using Beads later**: install Beads and run `br create` for each task per the [Beads create-tasks workflow](../commands/create-tasks.md). Suggested epic: `Epic: Multi-Agent Debate (--debate flag)`. Set parent on every task. Add dependencies per the graph above.
2. **Otherwise**: work through tasks in dependency order, starting with T001. Phase A (T001 + T002) is a hard gate — it MUST land before any prompt or `bin/review-gate` edit.
3. **Run `/cerberus:review-tasks docs/2026-04-25-debate-TODO.md`** for an external pass on this task graph (catches any missed obligations or ordering issues).
