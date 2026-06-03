# Implementation Plan: Multi-Agent Debate for Cerberus Reviews

## Context & Goals

- **Spec**: `docs/2026-04-25-debate-spec.md` (Tier L, complexity 8). Six core requirements: R1 (anonymized peer broadcast), R2 (calibrated confidence + anchors), R3 (strategy diversity), R6 (confidence-weighted aggregation that respects priority gate), R9 (backwards-compatible CLI surface), R10 (per-review-type applicability). Deferred to v2: R4 sparsification, R5 adaptive early exit, R7 diagnostics (K\*, disagreement-rate), R8 adversarial robustness, RedDebate cross-session memory.
- Add an **opt-in** `--debate` flag to `bin/review-gate spawn` and the four `spawn-*-review` named subcommands that injects an anonymized, confidence-tagged peer round between heterogeneous strategy-diverse reviewers.
- Preserve **byte-for-byte parity** for valid non-debate invocations (the only allowed deltas are `--help` text, `--version`, and error messages for newly-rejected flag combinations introduced by this feature).
- Land everything inside the existing `bin/review-gate` plumbing — no new binary, no new env vars, no new SDK dependencies.
- **Audience**: Cerberus maintainers and downstream operators using the review pipeline; debate is an opt-in escalation for high-stakes reviews where cross-model evidence is worth the ~2× wall-clock cost.

## Scope & Non-Goals

- **In Scope**
  - `--debate` flag plumbing through bare `spawn` (whitelisted to `--type ∈ {code, plan, spec, epic-verify}`) and the four `spawn-*-review` named subcommands.
  - Hidden `--debate-seed N` flag for fixture-test-only replay determinism (no-op when `--debate` absent).
  - Per-`(artifact_id, reviewer)` SHA-256 strategy assignment with collision walk in canonical order (`claude` < `codex` < `gemini`).
  - Confidence calibration block (canonical fenced literal) shared by all four reviewer templates via a single asset at `prompts/strategies/confidence-anchors.md`.
  - Strategy directive assets at `prompts/strategies/{verification-first,falsification-first,decompose}.md`.
  - In-process synchronous coordinator inside `spawn` that runs Round 1 → anonymization → Round 2 (→ Round 3 under `--mode max`) → aggregator → only then writes per-reviewer JSONs and `aggregate.json` into `reviews/`.
  - Anonymization pass: deny-list scrub via canonical POSIX-ERE pattern with iterative substitution; per-recipient peer ordering shuffle (deterministic under `--debate-seed`, non-deterministic otherwise).
  - Per-reviewer review JSONs gain additive optional fields under `--debate`: `overall_confidence`, `findings[*].confidence`, `strategy`, `round`, `peer_responses_seen`. Schema artifact gains a debate-conditional variant (non-debate bytes byte-identical to today).
  - `aggregate.json` with `verdict`, `summary`, `findings[]` (deduplicated, with `raised_by` set union on merged entries), `consensus_mode`, `rounds_consumed`, `reviewers[]`, `strategies{}`.
  - Aggregator semantics: dedup predicate (priority + exact `file_path` + line-range overlap + case-folded title equality after `[Px]` strip); canonical merge order via global pre-sort by `(priority asc, confidence desc, reviewer asc)` then greedy fold; PASS/NEEDS_WORK confidence tiebreak; FAIL is blocking. Any P0/P1 finding from any active final-round reviewer forces `aggregate.json.verdict = FAIL` (the blocking presentation value within the pinned enum) and forces the Stop-hook's per-reviewer consensus calculator to set `gate-state.json.consensus.verdict = "requires_decision"`. The string `requires_decision` MUST NEVER appear as a value of `aggregate.json.verdict`; that field's value space is the pinned enum {PASS|NEEDS_WORK|FAIL} only. The two surfaces are distinct: `aggregate.json.verdict` is the cross-reviewer presentation verdict (3-value enum); `gate-state.json.consensus.verdict` is the consensus calculator's output (which can include `requires_decision`).
  - Final-round abstain → Option B (exclude from final aggregation, no per-reviewer JSON written).
  - Terminal-abstention rule: a reviewer that abstains in round k is not invoked in subsequent rounds.
  - Degraded-below-2 hard error (preflight + mid-debate eligibility checks).
  - `gate-state.json.debate` block (success-path only); per-iteration `iterations/<iter>/debate-telemetry.json` for cancelled/failed/degraded paths.
  - Gate report extensions: "Debate: round N/N" indicator, `Strategy` column appended rightmost, `aggregate.json`-sourced one-card-per-defect rendering.
  - Cancellation / aggregator-failure exit codes distinct from timeout/SIGINT/per-reviewer errors.
  - README + `--help` updates documenting the flag, the round shape, the `<2 reviewers` hard error, the per-mode token cost band, and the per-mode wall-clock latency band.
  - Pre-feature golden fixtures captured to `bin/tests/fixtures/pre-debate-baseline/` BEFORE any code change lands (Step 0 of the launch checklist).
  - Fixture-based tests for R1 (deny-list, cross-platform BSD/GNU grep), R3 (strategy assignment determinism + collision shifts), R6 (dedup predicate GWT cases), and R9 (byte-parity + schema variant + golden additive-field JSONs).
  - End-to-end smoke tests: one per review type with `--debate`, one per review type without; preflight rejection tests; help-output tests.
  - Falsifiable acceptance fixture (`bin/tests/fixtures/debate-bad-artifact/`) asserting the two-clause launch gate.
  - Vibes-check fixtures (`debate-ambiguous-artifact/`, `debate-abstain-artifact/`).

- **Out of Scope (Non-Goals)**
  - Replacing the existing parallel review pipeline. `--debate` absent must remain byte-for-byte equivalent for valid invocations.
  - The other 5 primitives from `docs/debate.md` (sparsification, adaptive early exit, K\*/αK/disagreement diagnostics, Free-MAD adversarial robustness, RedDebate cross-session memory).
  - General-purpose MAS framework outside Cerberus.
  - New reviewer providers beyond Codex / Gemini / Claude.
  - Model fine-tuning. All primitives are prompt- and orchestration-level.
  - Generator commands (`create-spec`, `create-plan`, `create-tasks`) — they go through `bin/generate`, not `bin/review-gate spawn`. v1 does not wire debate into them; wrapper-level rejection in slash-command markdown is a v2 polish item.
  - Stylometric flattening of peer outputs.
  - JSON-shape normalization of peer outputs in the anonymization pass.
  - Per-agent confidence prior rescaling / Bayesian recalibration.
  - New environment variables, including any `REVIEW_DEBATE_DISABLED` kill-switch.
  - Mid-debate resume; partial-state replay across iterations.
  - Quantitative success metrics (sycophancy diagnostic, K\* ratio, disagreement-rate plateau).
  - Sparsified peer broadcast / S²-MAD-style routing.
  - Adaptive round budget (rounds are fixed by mode: 2 under fast/smart, 3 under max).

## Assumptions & Constraints

- Reviewer CLIs (Codex, Gemini, Claude) are stateless one-shot invocations; each round therefore must include a distinct prior-round-self block in the rendered prompt for the reviewer to see its own Round-1 verdict / findings / confidence.
- Existing reviewer providers (Codex, Gemini, Claude) and their CLI invocation contracts in `bin/review-gate-models.sh:620-745` continue to be the only providers in v1.
- Existing modes (`fast` / `smart` / `max`) compose orthogonally with `--debate`: mode picks underlying models + reasoning effort; debate adds rounds (2 under fast/smart, 3 under max).
- Stop-hook at `bin/review-gate-hook.sh:924-1080` remains the single source of gate pass/fail authority. `aggregate.json.verdict` is presentation/context only.
- The active-gate guard at `bin/review-gate:2273-2303` and the existing `REVIEW_GATE_RERUN=1` re-spawn affordance govern recovery from a debate run that crashes mid-flight.
- No tier-2 features (sparsification, adaptive rounds, etc.) are required to ship v1; spec explicitly defers them.

### Implementation Constraints (from spec)

- **Bash 3.2 compatible** (macOS shell). No associative arrays, no Bash-4-isms.
- **Pure shell + jq** for the aggregator. No LLM call, no fuzzy similarity, no embedding model.
- **`shasum -a 256` preferred, `sha256sum` fallback**, hard-error if neither — no silent fallback to non-cryptographic hash.
- **POSIX ERE deny-list** under `grep -oiE` / `sed -E`. Use canonical `(^|[^A-Za-z0-9_])<term>($|[^A-Za-z0-9_])` boundary form (BSD-only `[[:<:]]` and GNU-only `\<`/`\b` are forbidden).
- **Iterative substitution loop** for adjacent deny-list terms (single-pass would leave `Codex` in `Claude Codex` unredacted).
- **Synchronous in-process coordinator** under `--debate` — Round k+1 cannot start until all of Round k completes; replaces the existing detached fire-and-forget reviewer invocations for the debate path.
- **Existing detached pipeline preserved unchanged** for non-debate invocations (R9 byte-parity).
- **Schema artifact byte-parity**: `$REVIEWS_DIR/review-schema.json` written under non-debate must be byte-identical to pre-feature; under `--debate`, a debate-conditional variant must admit `overall_confidence`, `strategy`, `round`, `peer_responses_seen` at the top level and `confidence` inside `findings[*]`, all optional, with `additionalProperties: false` retained on both objects.
- **Repair-prompt schema** must follow the same conditional selection so repaired Codex output validates against the same schema as the primary call.
- **Stop-hook is decision authority**: per-reviewer priority-then-consensus calculator running over per-reviewer final-round JSONs is the single source of gate pass/fail. `aggregate.json.verdict` is presentation/context only.
- **Confidence is used in exactly two places**: cross-reviewer near-duplicate finding merge in `aggregate.json` and PASS/NEEDS_WORK tiebreak in `aggregate.json`. Never to suppress P0/P1.
- **Gemini read-only policy** (`config/gemini-readonly-policy.toml`) enforced unchanged on every Gemini call regardless of debate state.
- **No new environment variables** in production. The Step-0 capture script reads the prompt files `bin/review-gate` already persists in `$REVIEWS_DIR` (consumed by reviewer CLIs via `< "$REVIEW_PROMPT"`); no env-var hook in the prompt builder is required for Step 0.
- **`--debate-seed N`** must NOT change any byte-parity-protected output when `--debate` is absent.
- **Production-path shuffle (no seed)** MUST use a non-deterministic source per recipient (`$RANDOM` / `/dev/urandom`); MUST NOT cross-derive from the seed input.
- **Template placeholder whitespace** — `${CONFIDENCE_ANCHORS}` and `${STRATEGY_DIRECTIVE}` placeholders each occupy their own line including the trailing newline; under `--debate` absent, the substitution consumes the entire placeholder line so the rendered prompt is byte-identical to a template that never had the placeholder (see D2).

### Testing Constraints

- Pre-feature golden fixtures (Step 0) captured to `bin/tests/fixtures/pre-debate-baseline/` BEFORE any prompt-template or `bin/review-gate` edit lands.
- R1 deny-list test runs on both macOS (BSD grep) and Linux (GNU grep) — either CI matrix or checked-in pre-captured per-platform scrubs asserted byte-equal.
- R6 dedup predicate has full GWT coverage of {merged, non-overlapping ranges, different titles, different file_path, null location, different priority, equal-confidence tiebreak, `[Px]` strip behaviors}.
- Golden additive-field JSONs checked in to catch reviewer-provider schema drift.
- Falsifiable acceptance fixture is two-clause: Round-1 P1 must exist at the planted `(file_path, line_range)`; final `aggregate.json` must retain the same defect at the same location with `confidence ≥ 0.7` and exact-`file_path` + line-range-overlap match.
- `--debate-seed` produces byte-stable peer ordering on both macOS and Linux.

## Integration Analysis

### Existing Mechanisms Considered

| Existing Mechanism | Could Serve Feature? | Decision | Rationale |
|---|---|---|---|
| `bin/review-gate spawn` flag-parsing block (lines 2128-2202) | Yes | **Extend** | Add `--debate` and hidden `--debate-seed N` to the same `case` in spawn + each named subcommand wrapper |
| Reviewer prompt rendering (per-type `spawn-*-review` builders, lines 800-2110) | Yes | **Extend** | Inject conditional confidence-anchor block, strategy directive, prior-round-self block, anonymized peer block when `--debate` is set |
| `prompts/reviewers/<type>.md` templates | Yes | **Extend** | Reference `prompts/strategies/confidence-anchors.md` and `prompts/strategies/<strategy>.md` (sourced via single shared asset) |
| Schema emission heredoc (lines 2623-2656) + `default_review_schema()` (`bin/review-gate-models.sh:117-150`) | Yes | **Extend with debate-conditional branch** | Same code path emits one of two variants based on `--debate` flag; non-debate branch byte-identical to today |
| `repair_review_output()` (`bin/review-gate-models.sh:152-250`) | Yes | **Extend** | Embed the debate variant when repair runs under `--debate`; pre-feature schema otherwise |
| `spawn_reviewer()` / `spawn_detached_review_shell()` (`bin/review-gate-models.sh:620-745`) | Yes for non-debate path; **No for debate path** | **Extend (debate path adds a synchronous variant)** | Today's path is detached fire-and-forget; debate needs synchronous wait-for-completion of the whole round before launching the next. Add a new `spawn_reviewer_sync()` (or similar) inside the same module; non-debate continues to use `spawn_reviewer` unchanged |
| `gate-state.json` shape (lines 2658-2731) | Yes | **Extend additively** | New optional `debate` block written only on success path of `--debate` runs; no existing field renamed or repositioned |
| `iterations/<iter>/` telemetry directory (`bin/telemetry-lib.sh:372-391`) | Yes | **Extend** | Add `iterations/<iter>/debate-telemetry.json` for partial state on cancel / aggregator-fail / degraded-below-2; per-round raw outputs land here too |
| Stop-hook consensus calculator (`bin/review-gate-hook.sh:924-1080`) | Yes — **unchanged** | **Reuse as-is** | The Stop-hook reads the per-reviewer JSONs in `reviews/`, which the coordinator writes only after aggregation. The Stop-hook does not need to know debate ran. The gate report rendering layer (separate from the calculator) is what gains the Strategy column and the debate indicator |
| Active-gate guard / `REVIEW_GATE_RERUN=1` (lines 2273-2303) | Yes — **unchanged** | **Reuse as-is** | Cancel / aggregator-fail leaves gate at `status="pending"`, identical to today's "spawn started but reviewers never wrote sentinels" shape; the existing 30-min guard governs re-spawn |
| `bin/review-gate wait --json` (lines 2896-3363) | Yes — **unchanged** | **Reuse as-is** | Wait polls `<reviewer>.done`/`<reviewer>.failed` sentinels; coordinator writes them only after aggregation succeeds. Cancelled/failed runs leave wait timing out exactly as today |
| `bin/review-gate-lib.sh` iteration helpers | Yes | **Reuse** | `load_iteration` / `save_iteration` / archive-reviews logic untouched; debate is per-iteration |
| `resolve_intelligence_mode()` (`bin/review-gate-models.sh:43-83`) | Yes — **unchanged** | **Reuse as-is** | Debate inherits `--mode`; mode picks underlying models, debate adds rounds. They compose orthogonally |
| `commands/review-*.md` slash-command wrappers | Yes | **Extend** (pass-through) | The wrappers shell out to `bin/review-gate spawn-*-review $ARGUMENTS`; `--debate` flows through `$ARGUMENTS` and the subcommand handles it. No wrapper-level validation in v1 (R10) |
| `commands/create-*.md` | No | **Leave unchanged** | These call `bin/generate`, not `bin/review-gate spawn`. v1 explicitly does not wire debate into generators (R10 v2 polish) |
| `config/gemini-readonly-policy.toml` | Yes — **unchanged** | **Reuse as-is** | Policy is enforced on every Gemini call regardless of debate state; the manual Gemini-jailbreak smoke test (Launch checklist) verifies no new surface is opened by debate prompts |
| `bin/tests/test-review-gate-*.sh` test pattern | Yes | **Extend** | New tests follow the same temp-HOME + mock-state + mock-reviewer-outputs pattern; debate fixtures sit alongside existing ones under `bin/tests/fixtures/` |

### Integration Approach

The plan extends `bin/review-gate` rather than building a parallel debate runner. Concretely:

1. **Flag plumbing** is added to the existing `case` blocks in `spawn` and the four named subcommands; `--debate` and `--debate-seed N` become two new flags alongside the existing `--mode` / `--max-rounds` / `--consensus` / `--agents` family.
2. **The debate code path forks early in `spawn`**: after flag parsing, agent resolution, and preflight, an `if [[ -n "$DEBATE" ]]; then run_debate_coordinator; else <existing detached spawn path>; fi` decision is made. Existing non-debate code is touched only insofar as it shares helpers (e.g., schema emission) — and those helpers gain a debate-conditional branch with the non-debate branch byte-identical to today.
3. **The synchronous coordinator** is implemented in a new file `bin/review-gate-debate.sh` that's sourced by `bin/review-gate` only when `--debate` is set. It owns: strategy assignment, per-round prompt construction, synchronous reviewer launch + sentinel polling, anonymization, and aggregation. It writes the per-reviewer final-round JSONs and `aggregate.json` into `reviews/` only after the aggregator completes successfully (Section 2 step 7 of the spec). This mirrors the existing module split (`bin/review-gate-models.sh`, `bin/review-gate-lib.sh`, `bin/telemetry-lib.sh`) and keeps `bin/review-gate` from growing past 4000 lines.
4. **Schema variant selection** is a debate-conditional branch inside the same code path that today writes `review-schema.json`. Non-debate runs MUST emit byte-identical bytes to pre-feature; debate runs emit the variant that adds the new optional fields. The repair path picks the matching variant via the same conditional.
5. **Strategy assets** live under `prompts/strategies/` next to `confidence-anchors.md`. Each reviewer template `prompts/reviewers/<type>.md` includes two new placeholders — `${CONFIDENCE_ANCHORS}` and `${STRATEGY_DIRECTIVE}` — that `bin/review-gate` substitutes at prompt-build time using the same shell variable substitution pattern already used for `${ISSUES}` / `${CONTEXT}` / `${DIFF_ARGS}`. When `--debate` is absent, both placeholders are substituted with the empty string and the rendered template is byte-identical to today's. When `--debate` is set, the placeholders are replaced with the literal contents of `prompts/strategies/confidence-anchors.md` and `prompts/strategies/<assigned-strategy>.md` respectively. R10's byte-equality verification reduces to "every reviewer template inserts the same file at the same placeholder location."
6. **Anonymization, dedup, and aggregation** are pure shell + jq; no LLM call, no fuzzy similarity. The implementation lives inside the coordinator file.
7. **Stop-hook and `wait --json` are unchanged.** Coordinator failure / cancellation produces the same on-disk shape as a pre-feature crashed spawn (state `pending`, no sentinels) so existing recovery paths apply unchanged.
8. **Tests follow the existing harness pattern** under `bin/tests/`. New fixture directories under `bin/tests/fixtures/` hold pre-feature baselines, debate goldens, R1/R3/R6 GWT fixtures, and the falsifiable-acceptance + vibes-check artifacts.

## Prerequisites

- [ ] **Step 0 (Launch checklist gate):** Capture pre-feature golden fixtures to `bin/tests/fixtures/pre-debate-baseline/` against the current plugin version BEFORE any prompt-template or `bin/review-gate` edit lands. The R9 byte-parity tests depend on these.
  - For each of the 5 invocation shapes (4 named `spawn-*-review` + bare `spawn`): CLI stdout/stderr, per-reviewer `reviews/<reviewer>.json`, `review-schema.json`, `gate-state.json` post-Stop-hook, rendered reviewer prompts, `iteration.txt`, gate-report markdown, optional author-context state.
  - Pin a single representative `--mode` (recommended: `smart`) and document that choice in the fixture directory's README.
- [ ] CI matrix or per-platform pre-captured outputs for the R1 deny-list test (macOS BSD grep + Linux GNU grep).
- [ ] No external service approvals needed (no new SDK or service dependency).
- [ ] No new env vars to coordinate with operators (rollout is "drop the flag" or revert plugin version).

## High-Level Approach

The implementation lands in **five sequenced phases**, each leaving the system in a shippable state. The non-debate code path stays byte-stable from Phase 0 onward; debate functionality lights up incrementally.

**Phase A (Step 0 — Pre-feature golden capture).** Capture and check in `bin/tests/fixtures/pre-debate-baseline/` against the current plugin version. Add the byte-parity test that asserts post-feature non-debate runs match these fixtures (initially trivially passing because no debate code has landed). This phase is the prerequisite gate for everything that follows; it CANNOT be done after prompt or `bin/review-gate` edits land.

**Phase B (Plumbing — flag, preflight, no behavior change).** Add `--debate` and hidden `--debate-seed N` flag parsing to bare `spawn` and the four named subcommands. Add the bare-spawn whitelist preflight (R10): rejection layer at `bin/review-gate` for any `--type` outside `{code, plan, spec, epic-verify}`. Add the `<2 reviewers + --debate` hard-error preflight. Wire `--debate-seed N` to a no-op pass-through (it doesn't yet seed anything, but it's accepted on the CLI). At the end of this phase, `--debate` accepted with ≥2 reviewers falls through to a stub that just runs the existing non-debate path; `--debate-seed N` is no-op when `--debate` absent. R9 byte-parity tests pass.

**Phase C (Strategy + confidence assets).** Land the three strategy directive files under `prompts/strategies/` plus the canonical calibration anchor block at `prompts/strategies/confidence-anchors.md`. Implement the per-`(artifact_id, reviewer)` SHA-256 strategy assignment (with collision walk in canonical alphabetical order). Wire the assignment + the per-type `<artifact_id>` definitions into the coordinator stub's preflight phase. Update reviewer templates to conditionally pull in the anchor block + strategy directive when `--debate` is set. Land R3 strategy fixture tests + R2 anchor-byte-equality test.

**Phase D (Coordinator + Round 1 only).** Stand up the synchronous coordinator: it launches Round 1 reviewers in parallel (using the existing detached spawn helpers) but **waits in-process for all `.done`/`.failed` sentinels before proceeding**, instead of returning to the Stop-hook. After Round 1 completes, the coordinator runs a stub aggregator that produces a single-round `aggregate.json` (no dedup, no cross-reviewer merge — Phase E adds those). Per-reviewer JSONs at this phase are promoted from staging to `reviews/` carrying `overall_confidence`, `strategy`, `round=1`, `peer_responses_seen=[]`. Stop-hook sees them as today. Schema variant selection lights up here. The actual confidence-weighted dedup aggregator with canonical merge order arrives in Phase E.

**Phase E (Anonymization + Round 2 + dedup aggregator + Round 3 under --mode max).** Light up the actual debate primitive: the anonymization pass, the Round 2 prompt construction (anonymized peer block + prior-round-self block), the Round 2 launch, the confidence-weighted dedup aggregator (canonical merge order via global pre-sort + greedy fold), `aggregate.json` enriched with `raised_by`, the FAIL-blocking + PASS/NEEDS_WORK confidence tiebreak. `--mode max` adds the second peer round (Round 3). Terminal-abstention rule + final-round Option B exclusion are wired here. R1 deny-list tests, R6 dedup tests, the falsifiable-acceptance fixture, and the vibes-check fixtures all run green.

**Phase F (UX + docs + telemetry surfaces).** Gate report extensions (Strategy column, debate indicator, `aggregate.json`-sourced finding cards). `gate-state.json.debate` block on success path; `iterations/<iter>/debate-telemetry.json` for non-success paths. Distinct exit codes for aggregator failure vs SIGINT vs timeout. README + `--help` updates. Manual smoke checks on real artifacts (Gemini jailbreak surface, confidence-update behavior, token+wall-clock cost bands). Maintainer vibes review on three real artifacts before flagging for general use.

Phases B and C are independent after A; D depends on B+C; E depends on D; F depends on E.

## Technical Design

### Architecture

**Top-level control flow under `--debate` (replaces the today's detached fire-and-forget):**

```
bin/review-gate spawn[-*-review] --debate [--debate-seed N] ...
   │
   ├─ flag parsing  (existing case + new --debate / --debate-seed cases)
   ├─ preflight     (existing + new: bare-spawn type whitelist, <2 reviewers hard-error)
   ├─ if --debate:  source bin/review-gate-debate.sh ; run_debate_coordinator
   └─ else:         existing detached spawn_reviewer path  ← unchanged

run_debate_coordinator():
   1. compute strategy assignment  (per-(artifact_id, reviewer) SHA-256 + canonical-order collision walk)
   2. emit debate-conditional review-schema.json
   3. for round in 1..N:                                  # N=2 fast/smart, 3 max
        eligibility_check()                                # <2 non-abstained → hard error before launch
        staging_dir=iterations/<iter>/round-N/             # coordinator overrides REVIEWS_DIR for this round
        for reviewer in eligible_reviewers:
            build prompt:
                - reviewer template (conditional: confidence anchors + strategy directive + own-prior-round block + peer block)
                - peer block from round-1 (or absent in round 1)
            launch reviewer via spawn_reviewer with output dir = staging_dir (sync wait, per-reviewer timeout)
        collect outputs from staging_dir; mark abstained (Mode A) or clamp confidence (Mode B)
        if round < N:
            run_anonymization_pass(outputs)               # in-process deny-list + per-recipient ordering
   4. aggregate(final_round_outputs)
        - dedup predicate + canonical-merge-order fold → aggregate.findings[]
        - verdict: FAIL-blocking + consensus-mode + PASS/NEEDS_WORK confidence tiebreak
        - deterministic jq-templated summary (see Data Model)
   5. atomically promote final-round per-reviewer JSONs from staging_dir into the canonical $REVIEWS_DIR (with .done sentinels)
   6. write $REVIEWS_DIR/aggregate.json
   7. write gate-state.json.debate block
   8. (return; Stop-hook then sees populated reviews/ and runs as today)
```

**Failure paths** are split into two on-disk shapes. SIGINT cancellation and aggregator failure both leave the canonical `$REVIEWS_DIR` empty + `gate-state.json.status="pending"` — identical to today's "spawn started, reviewers never wrote sentinels" case, so existing recovery (re-spawn under `REVIEW_GATE_RERUN=1` or `bin/review-gate resolve`) works unchanged. Per-round staged outputs (the per-reviewer JSONs and sentinels that `spawn_reviewer` wrote into `iterations/<iter>/round-N/` while the round was in flight) are preserved for inspection but never promoted into `$REVIEWS_DIR`. The degraded-below-2 hard error transitions the gate into `awaiting_decision` with `consensus.verdict = "requires_decision"` per spec R6 (see the on-disk-shape detail below).

**Verdict-authority split (intentional).** The Stop-hook's existing per-reviewer priority-then-consensus calculator over the canonical `reviews/` per-reviewer JSONs is the **single source of truth for gate pass/fail**. The aggregator's `aggregate.json.verdict` (which can apply a PASS/NEEDS_WORK confidence tiebreak on a 2-reviewer split) is a **presentation/context surface only** — it is rendered in the gate report alongside the Stop-hook verdict, but it does not gate iteration or decision flow. On the rare case where the two diverge (only possible on a 2-reviewer 1-1 PASS/NEEDS_WORK split where confidence picks the lower-vote-count side), the gate report displays both verdicts side-by-side and the Stop-hook's value is the one that controls the outer-loop iteration. This is intentional per spec Section 2 step 9 and Decisions Made: there is **one decision authority** (Stop-hook over per-reviewer JSONs) and **one cross-reviewer presentation surface** (`aggregate.json`); confidence influences the latter only. No Stop-hook change is required for v1; aligning the Stop-hook with the aggregator's tiebreak is a v2 question if telemetry shows the split confuses operators.

**Pinned exit codes (distinct from existing `wait --json` codes 0/1/2/3/4):**

- **SIGINT cancellation:** exit `130` (the conventional 128 + SIGINT signal number; existing convention, no new code reserved). On-disk shape: `reviews/` empty, `gate-state.json.status="pending"`.
- **Aggregator failure:** exit `5` (new, reserved). Stderr emits `aggregator failed: <reason>` (e.g., `aggregator failed: jq parse error on reviews/codex.json`). On-disk shape: `reviews/` empty, `gate-state.json.status="pending"`.
- **Degraded-below-2 (preflight or mid-debate eligibility check):** exit `6` (new, reserved). Stderr emits `debate degraded below 2 active reviewers in the final peer round` or the analogous preflight variant. On-disk shape: see "Degraded-below-2 on-disk shape" below.

**Degraded-below-2 on-disk shape.** The coordinator writes `gate-state.json.status = "awaiting_decision"` (the same status the Stop-hook would write on a non-PASS consensus) and `gate-state.json.consensus = {"verdict": "requires_decision", "reason": "debate degraded below 2 active reviewers in the final peer round", "iteration": <current-iter>}` to align with the existing consensus-output convention. The canonical `$REVIEWS_DIR` is left empty (no per-reviewer JSONs, no `aggregate.json`, no sentinels). Partial-round outputs are preserved under `iterations/<iter>/round-N/` for inspection. Recovery is the same as for any `awaiting_decision` gate — the user resolves via `bin/review-gate resolve --reason "..."` or re-spawns under `REVIEW_GATE_RERUN=1`.

**Cancellation / aggregator-failure on-disk shape.** `status` stays at `"pending"` (the value `spawn` wrote on entry; the coordinator does NOT transition it). `consensus` and `decision` remain null. Recovery: re-spawn under `REVIEW_GATE_RERUN=1` or `bin/review-gate resolve` first.

The two paths are distinct because:

- Degraded-below-2 is a deterministic feature outcome (the run produced a valid "I cannot judge" answer); the gate should land in `awaiting_decision` so a human is prompted to decide.
- Cancellation / aggregator-failure are abnormal exits where no judgment was produced; the gate stays `pending` so the existing 30-min active-gate guard governs and re-spawn / resolve is the recovery path.
- **Bare-spawn whitelist rejection (`--debate` with non-judging `--type`):** exit `2` (existing preflight error code). Stderr names the rejected `--type` and the four allowed values. No model invocation.
- **Per-reviewer timeout under debate:** the coordinator times out a per-round wait at the same per-reviewer wall-clock budget today's polling loop already enforces (`REVIEW_GATE_POLL_INTERVAL_SECONDS` × an internal max-iter bound; falls out of reusing the existing sentinel-poll pattern). A reviewer that hits this budget is treated as Mode A — `abstained=true` for the round, terminal for the run. The coordinator continues to the next round if eligibility ≥ 2; otherwise degraded-below-2 fires.

### Data Model

**`aggregate.json` (new artifact, debate runs only):** Pinned canonical shape from spec R6 / Decisions Made. Top-level keys: `verdict` (PASS|NEEDS_WORK|FAIL), `summary` (deterministic jq-rendered template — see below), `findings[]` (deduplicated; merged entries gain `raised_by` set union), `consensus_mode` (majority|all|any), `rounds_consumed` (2 or 3), `reviewers[]` (canonical names of active final-round reviewers only), `strategies{}` (per-reviewer R3 assignment).

**`summary` template (deterministic, jq-renderable).** The `summary` string is generated by jq from the aggregated state with no LLM involvement. The pinned template is:

`<verdict> from <N> active final-round reviewers (<reviewer-name-csv>); <findings_count> unique findings (P0:<n0> P1:<n1> P2:<n2> P3:<n3>); avg overall_confidence <x.xx>.`

Example: `NEEDS_WORK from 2 active final-round reviewers (claude, codex); 5 unique findings (P0:0 P1:1 P2:3 P3:1); avg overall_confidence 0.78.`

`<reviewer-name-csv>` is the canonical-alphabetical-order reviewer names joined by `, ` (e.g., `claude, codex`). `avg overall_confidence` is the arithmetic mean of the active-final-round reviewers' `overall_confidence` values, rendered to two decimal places. The template is byte-stable across jq versions because it uses only `\(...)` interpolation and standard arithmetic.

**Per-reviewer review JSON additive fields under `--debate`:** `overall_confidence`, `findings[*].confidence` (both in `[0,1]`, default `0.5` under Mode B if absent, clamped if out-of-range), `strategy` (one of `verification-first` | `falsification-first` | `decompose`), `round` (integer 1..N), `peer_responses_seen` (array of opaque per-run IDs the coordinator presented in the rendered peer block — includes abstained-peer slot IDs; coordinator-populated, not parsed back from the reviewer).

**`gate-state.json.debate` block (success-path-only, additive):** Pinned shape from spec Section 4. `rounds`, `mode`, `consensus_mode`, `strategies{}`, `rounds_telemetry[]` (one entry per round actually executed and reaching aggregation; reviewers absent from later rounds means they abstained earlier under terminal-abstention rule), `aggregator_notes[]`. Absent in non-debate runs (no `"debate": null`, no `"debate": {}`).

The coordinator writes `gate-state.json.debate` BEFORE returning control to the Stop-hook. The existing Stop-hook updates `gate-state.json` via `jq` patch syntax (e.g., `.status = $status | .consensus = $cons`), which preserves unspecified top-level fields. Therefore the additive `debate` block survives the Stop-hook's `pending → awaiting_decision → resolved` transitions without explicit Stop-hook code change. The R9 byte-parity tests assert this by reading `gate-state.json.debate` after Stop-hook completion in the success path.

**`iterations/<iter>/debate-telemetry.json` (non-success-path partial state):** Same shape as `gate-state.json.debate` block but may have `rounds_telemetry` of length < N (whatever the coordinator collected before the SIGINT / aggregator-fail / degraded-below-2). Inspection-only; not consumed by Stop-hook, aggregator, or any next-iteration decision surface.

**Opaque per-run peer IDs:** `Peer-A`, `Peer-B`, `Peer-C` — assigned at coordinator start, stable across rounds within one debate run, reset between runs. The mapping `<canonical reviewer name> → <Peer-X>` is stored only in coordinator-internal state; it does not surface in any byte-parity-protected artifact.

**Per-type `<artifact_id>` (R3 hash input):**

- `plan` → `realpath` of plan file.
- `spec` → `realpath` of spec file.
- `code` → verbatim `diff_args_str`.
- `epic-verify` → `realpath` of epic file or verbatim raw-criteria string.

### API/Interface Design

- **CLI surface (R9):** Two new flags accepted on bare `spawn` and all four `spawn-*-review` subcommands.
  - `--debate` (boolean, opt-in). Default off.
  - `--debate-seed N` (integer, hidden — not in `--help` / not in README). Used only by fixture tests for byte-stable peer-ordering replay. No-op when `--debate` absent.
- **Byte-parity exception list (the only allowed deltas for valid invocations under `--debate` absent):** `--help` / usage output (must document `--debate`; MUST NOT document `--debate-seed`, which is hidden); `--version` output if it shifts as part of the release; error messages emitted for newly-rejected flag combinations.
- **`wait --json` shape:** unchanged in v1. Debate fields stay in per-reviewer JSONs and `aggregate.json` only.
- **No new env vars.**
- **Stop-hook behavior:** unchanged. Reads `reviews/<reviewer>.json`, runs priority-then-consensus, transitions `gate-state.json.status` from `pending` → `awaiting_decision` → `resolved`.
- **Round-2 self-block placement:** Round 2 prompts include a clearly-marked "your prior round" self-block (the reviewer's own Round-1 verdict + findings + confidence) distinct from the anonymized peer block, since reviewer CLIs are stateless one-shot invocations. Under `--mode max`, the Round 3 prior-round-self block contains the reviewer's Round 2 output only (most recent prior round; not a concatenation of Rounds 1 and 2), per spec Section 2.

### File Impact Summary

**New files:**

- `prompts/strategies/confidence-anchors.md` — **New (create)**. Canonical fenced literal from spec R2, byte-identical.
- `prompts/strategies/verification-first.md` — **New (create)**. Short directive ("verify the artifact's claims hold; cite the evidence").
- `prompts/strategies/falsification-first.md` — **New (create)**. Short directive ("try to falsify the artifact / find concrete counterexamples").
- `prompts/strategies/decompose.md` — **New (create)**. Short directive ("decompose the artifact into parts and judge each").
- `bin/review-gate-debate.sh` — **New (create)**. Synchronous coordinator + anonymization + aggregator.
- `bin/tests/capture-pre-debate-baseline.sh` — **New (create)**. One-shot script that runs each of the five invocation shapes (4 named subcommands + bare `spawn`) against canned reviewer outputs and copies the resulting `reviews/`, `gate-state.json`, rendered prompts, `iteration.txt`, and gate-report markdown into `bin/tests/fixtures/pre-debate-baseline/`. Lives under `bin/tests/` rather than as a flag on `bin/review-gate` so capture machinery doesn't ship with the production binary past Step 0. The script reads the prompt files `bin/review-gate` already persists under `$REVIEWS_DIR/<reviewer>.prompt` (passed to each reviewer CLI via `< "$REVIEW_PROMPT"` in `bin/review-gate-models.sh:670-742`); it does NOT depend on any new env-var hook in the prompt builder.
- `bin/tests/test-debate-anonymization.sh` — **New (create)**. R1 deny-list + ordering tests.
- `bin/tests/test-debate-strategy.sh` — **New (create)**. R3 assignment determinism, full-permutation N=3, distinct-N=2, N=4 collision wrap, no-collision swap, collision-driven shift.
- `bin/tests/test-debate-aggregation.sh` — **New (create)**. R6 dedup predicate GWT cases + canonical merge order + verdict tiebreaks + Option B exclusion.
- `bin/tests/test-debate-byte-parity.sh` — **New (create)**. R9 byte-parity over `bin/tests/fixtures/pre-debate-baseline/` + schema variant + golden additive-field JSONs.
- `bin/tests/test-debate-preflight.sh` — **New (create)**. Whitelist rejection + `<2 reviewers` hard error + help-output coverage.
- `bin/tests/test-debate-end-to-end.sh` — **New (create)**. One smoke per review type with `--debate` (assert debate indicator + Strategy column + `aggregate.json`).
- `bin/tests/fixtures/pre-debate-baseline/` — **New (create)**. CLI stdout/stderr, per-reviewer JSONs, schema, gate-state, prompts, iteration.txt, gate-report markdown for each of 5 invocation shapes.
- `bin/tests/fixtures/r1-anonymization/` — **New (create)**. Deny-list inputs + expected scrubbed outputs (per-platform if needed).
- `bin/tests/fixtures/r3-strategy-assignment/` — **New (create)**. `(artifact_id, reviewer-set) → expected strategy assignment` pairs covering N=2, N=3, N=4, no-collision swap, collision-driven shift.
- `bin/tests/fixtures/r6-dedup/` — **New (create)**. GWT input/output pairs for the 8+ predicate cases.
- `bin/tests/fixtures/debate-bad-artifact/` — **New (create)**. Falsifiable-acceptance test artifact + `defect-location.json` recording planted P1's `file_path` + `line_start`/`line_end`.
- `bin/tests/fixtures/debate-ambiguous-artifact/` — **New (create)**. Vibes-check fixture (reviewers historically disagree).
- `bin/tests/fixtures/debate-abstain-artifact/` — **New (create)**. Vibes-check fixture (one reviewer set to always abstain).

**Modified files:**

- `bin/review-gate` — **Exists (modify)**. Flag parsing in `spawn` (lines 2128-2202) and each named subcommand wrapper. Preflight whitelist (R10). Schema-emission heredoc gains debate-conditional branch (lines 2623-2656). Conditional source of `bin/review-gate-debate.sh` and conditional `run_debate_coordinator` invocation in `spawn` after preflight. Help-output text updated.
- `bin/review-gate-models.sh` — **Exists (modify)**. `default_review_schema()` (lines 117-150) gains a debate-conditional `if/else` branch (the non-debate branch byte-identical to today's heredoc; the debate branch adds the new optional fields). `repair_review_output()` (lines 152-250) follows the same conditional selection. The existing `spawn_reviewer` is reused for the debate path (the coordinator polls `.done`/`.failed` sentinels on the existing detached invocation rather than introducing a new synchronous helper). **Phase B deliverable:** `spawn_reviewer` gains an optional output-directory parameter (small additive change) so the coordinator can route per-round per-reviewer JSONs and sentinels into `iterations/<iter>/round-N/` instead of the canonical `$REVIEWS_DIR`. The default behavior (no output-dir override) is byte-identical to today, asserted by a regression test on the non-debate path. No per-reviewer invocation contract changes.
- `bin/review-gate-hook.sh` — **Exists (modify)**. Gate-report renderer (separate from consensus calculator) gains the Strategy column + debate indicator + `aggregate.json`-sourced one-card-per-defect rendering when `aggregate.json` exists in `reviews/`. Consensus calculator unchanged.
- `bin/review-gate-lib.sh` — **Exists (likely modify, small)**. Iteration helpers may need a no-op extension for the debate-telemetry path under `iterations/<iter>/`. Otherwise unchanged.
- `bin/telemetry-lib.sh` — **Exists (modify)**. May add helper to write `iterations/<iter>/debate-telemetry.json` for non-success paths.
- `prompts/reviewers/code.md` — **Exists (modify)**. Conditionally include the calibration anchor block + strategy directive + prior-round-self block placeholder + anonymized peer block placeholder when `--debate` is set; otherwise byte-identical to today.
- `prompts/reviewers/plan.md` — **Exists (modify)**. Same conditional include pattern.
- `prompts/reviewers/spec.md` — **Exists (modify)**. Same conditional include pattern.
- `prompts/reviewers/epic-verify.md` — **Exists (modify)**. Same conditional include pattern.
- `prompts/revisions/{code,plan,spec,epic-verify}.md` — **Exists (no change required)**. Revision prompts MUST not inherit debate transcript state (R10 edge case). Confirm via test that they're untouched under `--debate`.
- `commands/review-{code,plan,spec}.md`, `commands/verify-epic.md` — **Exists (no behavior change)**. Slash-command wrappers shell out via `$ARGUMENTS`; `--debate` already flows through. v1 deliberately does not validate at the wrapper layer.
- `commands/create-{spec,plan,tasks}.md` — **Exists (no change)**. These call `bin/generate`, not `bin/review-gate spawn`. v1 defers wrapper-level rejection; `--debate` either silently ignored or fails downstream.
- `README.md` — **Exists (modify)**. New "Debate mode" section: flag, round shape, per-mode token cost band, per-mode wall-clock latency band, `<2 reviewers` hard error, byte-parity guarantee.

## Risks, Edge Cases & Breaking Changes

- **Risk: byte-parity regression in non-debate runs.** Mitigation: Step 0 captures pre-feature fixtures BEFORE any code change; the byte-parity test suite asserts `cmp`-equality on every captured artifact. Schema heredoc and `default_review_schema()` are the highest-risk surfaces — the debate-conditional branches must keep the non-debate path byte-identical, with a fixture-asserted check.
- **Risk: token cost ≈ 2× non-debate (3× under `max`).** Manual maintainer check; `<2 reviewers` hard error keeps cost floor honest; fixed (non-adaptive) round budget keeps ceiling honest. README documents the band.
- **Risk: wall-clock latency ≈ 2× non-debate (3× under `max`).** Round 2 cannot start until Round 1 completes; debate adds at least one full reviewer round to the critical path. CI jobs sized for single-pass review will time out under `--debate`. Mitigation: README + `--help` document the band; users sizing CI must account for it. No timeout reshape in v1.
- **Risk: undocumented external markdown-parser of the gate report.** Anyone outside the repo regex-parsing the gate report markdown table will see the new Strategy column and the debate indicator line. Mitigation: documented as non-supported breakage path; recommended migration is `wait --json`, whose shape is unchanged.
- **Risk: stylistic leakage despite anonymization.** Strict deny-list cannot defeat voice/prose-style fingerprinting. Maintainer accepted this — Round 2 still captures the cross-model-evidence win even if reviewers occasionally guess identity.
- **Risk: Gemini read-only policy under peer broadcasts (laundering surface).** Peer block could in principle relay text that coaxes Gemini toward write tools. Mitigation: read-only policy enforced unchanged on every Gemini call; manual jailbreak smoke check on the launch checklist.
- **Risk: strategy directive accidentally degrading a reviewer.** "Falsify the artifact" could push into adversarial-without-evidence mode. Mitigation: directive text anchored ("try to falsify" paired with "and present concrete counterexamples"); directive sits inside the always-on prompt template that enforces priority semantics; gate report exposes assignment so a degraded reviewer is visible to the maintainer.
- **Risk: confidence inflation across the board** (every reviewer emits 0.9). Accepted in v1; anchor language is advisory, not enforced.
- **Risk: low cross-reviewer dedup hit rate from strict exact-title matching.** Different LLMs paraphrase. Accepted as a v1 tradeoff for determinism + Bash-3.2/jq feasibility + testability. Conservative by design — the priority + file_path + line-overlap constraints prevent false-merges, which is the unacceptable failure mode.
- **Risk: cross-platform regression on R1 deny-list (BSD vs GNU grep word-boundary semantics).** Mitigation: pinned canonical `(^|[^A-Za-z0-9_])<term>($|[^A-Za-z0-9_])` POSIX-ERE form; CI / fixture coverage on both platforms.
- **Risk: cross-platform regression on R3 hash primitive (`shasum` vs `sha256sum`).** Mitigation: hard-error if neither found; both produce identical 64-hex output; runtime selection via `command -v`.
- **Risk: implementer picks a non-portable shuffle primitive (`awk srand`, raw `$RANDOM`) instead of the spec's pinned SHA-256-keyed algorithm — caught at fixture rebake time.**
- **Risk: tier disagreement** (someone argues this is M not L). Recorded with explicit complexity score 8.
- **Risk (intentional split-brain, rare and bounded): Stop-hook verdict vs `aggregate.json.verdict` divergence.** The Stop-hook is the single source of pass/fail authority over per-reviewer JSONs; `aggregate.json.verdict` is presentation-only. The two can diverge only on a 2-reviewer 1-1 PASS/NEEDS_WORK split where the aggregator's confidence tiebreak picks the lower-vote-count side. On divergence the gate report shows both side-by-side; the Stop-hook value controls outer-loop iteration. Aligning the two is a v2 question if telemetry shows the split confuses operators. See the Verdict-authority split paragraph in Architecture.
- **Risk (accepted v1 limitation): strategy assignment is per-machine, not cross-machine.** Because `<artifact_id>` is `realpath`, two engineers on different machines / checkout locations reviewing the same logical artifact will get different strategy assignments. The determinism contract pins per-rerun-on-same-machine reproducibility only; cross-machine fixture-test replay goes through `--debate-seed N` (peer ordering), not the strategy hash. See D12.

**Backwards compatibility:** Every existing CI invocation that does not pass `--debate` and is a valid invocation MUST behave byte-for-byte identically to the prior version. The only allowed deltas are the explicit byte-parity exceptions (help, version, newly-rejected-flag-combo error messages).

## Testing & Validation Strategy

**Test types:**

- **Unit / fixture tests** (extend existing `bin/tests/` harness): R1 deny-list, R3 strategy assignment, R6 dedup predicate + canonical merge order, R9 byte-parity + schema variant + golden additive-field JSONs, R9 hidden flag no-op, R10 preflight whitelist, R10 anchor-byte-equality across the four reviewer templates.
- **Integration / coordinator tests** (new): synchronous round driver wait-for-all-reviewers semantics; abstention propagation across rounds; degraded-below-2 mid-debate eligibility check; cancellation / aggregator-failure → empty `reviews/` + `pending` `gate-state.json`; distinct exit codes per failure mode.
- **End-to-end smoke tests** (new): one per review type with `--debate` against a controlled fixture, assert debate indicator + Strategy column + `aggregate.json` keys; one per review type without `--debate`, assert byte-parity against `pre-debate-baseline/`.
- **Falsifiable acceptance test** (new): the two-clause launch gate. Clause 1 — Round 1 must contain at least one P1 finding F at the planted defect's `file_path` with overlapping line range; Clause 2 — `aggregate.json` of the final peer round must retain F' with `priority=P1`, `confidence ≥ 0.7`, exact `file_path` match, and non-null line-range overlap (title NOT required to match).
- **Vibes-check fixtures** (new, manual inspection): ambiguous artifact (Round 2 differs from Round 1 for ≥1 reviewer); peer-abstained artifact (surviving reviewers reference abstain in reasoning OR remain stable, no phantom peer findings).
- **Manual smoke checks** (Launch checklist): Gemini jailbreak surface; confidence-update behavior on representative artifact; calibration check (anchors influence behavior); per-mode token + runtime cost band; maintainer vibes review on three real artifacts before flagging for general use.

**Coverage requirements:** Every requirement in the spec's R1/R2/R3/R6/R9/R10 has at least one Given-When-Then test asserted in a fixture. Pre-feature golden fixtures are immutable post-Step-0.

**Manual validation steps:** see Launch checklist (spec Section 4) — items reproduced as gating criteria below.

**Monitoring / observability after launch:** `gate-state.json.debate.rounds_telemetry` (success path: per-round token counts, reviewer outcomes, strategy assignment); `iterations/<iter>/debate-telemetry.json` (partial-state path); gate report Strategy column + debate indicator make assignment visible to humans.

### Acceptance Criteria Coverage

| Spec AC | Approach |
|---|---|
| Byte-parity for valid non-debate invocations (R9) | Step 0 fixtures + R9 byte-parity test suite + schema-artifact fixture |
| Falsifiable two-clause launch gate (Success criteria) | `bin/tests/fixtures/debate-bad-artifact/` + `defect-location.json` + assertion test |
| `<2 reviewers + --debate` hard error | Preflight test in `test-debate-preflight.sh` |
| Bare-spawn whitelist rejection (R10) | Preflight test asserting non-zero exit + clear error for `--type ∈ {create-tasks, manual, auto}`; positive-case test for `--type ∈ {code, plan, spec, epic-verify}` |
| Anonymization deny-list (R1) | `test-debate-anonymization.sh` + R1 fixtures (BSD + GNU grep) |
| Anonymization adjacent-term iteration (R1) | Specific fixture: `Claude Codex Gemini` → all three redacted |
| Per-recipient peer ordering shuffle (R1) | Fixture asserts orderings differ across recipients under same seed (with N≥3 peers) |
| `--debate-seed N` byte-stable replay (R1/R9) | Fixture captures peer block under seed and asserts byte-equality across runs/platforms |
| Calibration anchor byte-equality across templates (R2/R10) | `cmp` check that the rendered anchor block region is byte-identical to `prompts/strategies/confidence-anchors.md` and across all four reviewer templates |
| Per-(artifact, reviewer) strategy stability (R3) | Fixture: same `<artifact_id>` + same reviewer → same strategy across reruns / sessions |
| Strategy collision walk + N=2/3/4 cases (R3) | Fixture set covering distinct strategies at N=2, full permutation at N=3, collision wrap at N=4, no-collision swap, collision-driven shift |
| Dedup predicate (R6) | GWT fixtures: same-file+overlap+title+priority → merged; non-overlap → not merged; different title → not merged; different file → not merged; null location → not merged; different priority → not merged; equal-confidence merge → alphabetical reviewer wins primary |
| Canonical merge order under non-transitive overlap (R6) | Fixture exercising A overlaps B, B overlaps C, A does not overlap C |
| `[Px]` strip behaviors (R6) | Fixture covering `[P0]..[P3]`, `[P12]`, `[Pending]`, `[P4]`, `[p1]`, `[P1][P2]`, no-strip cases |
| Verdict tiebreaks under each consensus mode (R6) | Fixture per consensus mode covering FAIL-blocking, PASS/NEEDS_WORK confidence tiebreak, P0/P1 always blocking |
| Final-round Option B exclusion (R6) | Fixture: 3 reviewers, one abstains in final round → only 2 per-reviewer JSONs written; `aggregate.json` reflects 2 reviewers |
| Terminal-abstention rule (R1/R6/Decisions) | Fixture: reviewer abstains in Round 1 → not invoked in Round 2; surfaces as `(peer abstained)` to active peers |
| Degraded-below-2 mid-debate (R6/Section 2) | Fixture: 2 reviewers, 1 abstains in Round 1 → no Round 2 launched, hard error |
| Schema variant for Codex `--output-schema` (R9) | Fixture: under `--debate`, schema admits new optional fields; under non-debate, byte-identical to pre-feature snapshot |
| Repair-prompt schema follows the variant (R9) | Test invokes `repair_review_output()` with debate flag both ways and asserts the embedded schema |
| Help output documents `--debate` (R9) | Help-output check in `test-debate-preflight.sh` (also asserts `--debate-seed` is NOT documented) |
| `--debate` on generator slash commands does NOT crash badly (R10) | Test invokes `/cerberus:create-spec --debate` and asserts either silent ignore or downstream fail at `bin/generate` (both acceptable v1) |
| `gate-state.json.debate` block on success-only (Section 4) | Fixture: success path → block present; cancel/agg-fail/degraded → block absent |
| `iterations/<iter>/debate-telemetry.json` on partial state | Fixture: SIGINT mid-coordinator + aggregator-fail + degraded-below-2 each leave a populated, inspectable telemetry file |
| Distinct exit codes (130 / 5 / 6 / 2) | Per-failure-mode test asserts exit code + stderr message |
| Gate report Strategy column rightmost + debate indicator | Snapshot test on rendered gate-report markdown |
| Vibes acceptance signals (ambiguous, abstain) | Manual inspection on `debate-ambiguous-artifact/` and `debate-abstain-artifact/` fixtures |

## Resolved Design Decisions

The following implementation choices are not directly pinned by the spec but were resolved during planning. Recorded here so future iterations don't re-derive them.

- **D1. Code layout** — new file `bin/review-gate-debate.sh`, sourced by `bin/review-gate` only when `--debate` is set. Mirrors the existing `bin/review-gate-models.sh` / `bin/review-gate-lib.sh` / `bin/telemetry-lib.sh` module split.
- **D2. Template include mechanism** — two new shell-substitutable placeholders in each reviewer template: `${CONFIDENCE_ANCHORS}` and `${STRATEGY_DIRECTIVE}`. `bin/review-gate` substitutes both with the literal contents of the corresponding `prompts/strategies/<file>.md` when `--debate` is set, or with the empty string when it isn't. R10 byte-equality verification on the rendered anchor block region reduces to a `cmp` check.
  - **Placement convention:** each placeholder is placed on its own line in the template, with the placeholder line including its own trailing newline. Under `--debate` absent, the placeholder substitutes to the empty string AND the entire placeholder line (including the trailing newline) is consumed via the substitution itself, so the rendered template under `--debate` absent is byte-identical to a template that never had the placeholder. The R9 byte-parity fixture asserts this directly.
- **D3. Schema variant emission** — both schema-emission code paths (the inline heredoc in `bin/review-gate` lines ~2623-2656 and the `default_review_schema()` helper in `bin/review-gate-models.sh:117-150`) gain a debate-conditional `if/else` branch. The non-debate branch is byte-identical to today's heredoc and asserted by a fixture. The debate branch adds the new optional fields with `additionalProperties: false` retained on both objects. The `repair_review_output()` repair-prompt schema follows the same conditional.
- **D4. Synchronous reviewer launch + per-round staging directory** — reuse the existing detached `spawn_reviewer` helper. The coordinator polls `<reviewer>.done`/`<reviewer>.failed` sentinels exactly the way the Stop-hook does today (`bin/review-gate:3088-3120`). Zero new helper, zero macOS-vs-Linux portability surface, zero risk of changing the per-reviewer invocation contract. Per-reviewer timeout falls out of the existing polling-loop budget.
  - **Per-round staging directory.** The coordinator MUST NOT let `spawn_reviewer` write its outputs (`<reviewer>.json`, `<reviewer>.done`, `<reviewer>.failed`) directly into the canonical `$REVIEWS_DIR` while a debate run is in flight, because the spec invariant (Section 2 step 7) is that the coordinator writes per-reviewer review JSONs into `reviews/` only after aggregation succeeds, and the failure-path contract requires `reviews/` to be empty on aggregator failure / SIGINT. To honor both, the coordinator passes a per-round staging directory — `iterations/<iter>/round-N/` under the existing per-iteration telemetry path, where N is 1, 2, or 3 — as the output target for `spawn_reviewer` invocations under `--debate`. Concretely: the coordinator overrides `REVIEWS_DIR` (or the corresponding per-call output-dir parameter) to `iterations/<iter>/round-N/` before calling `spawn_reviewer` for each round, so each round's per-reviewer JSONs and `<reviewer>.done` / `<reviewer>.failed` sentinels land under that staging path, NOT under the canonical `$REVIEWS_DIR`.
  - **Atomic promotion after aggregation.** After the aggregator completes successfully, the coordinator atomically promotes (copies, then verifies) the final-round per-reviewer JSONs and writes the `<reviewer>.done` sentinels into the canonical `$REVIEWS_DIR`. `aggregate.json` is then written alongside.
  - **Failure paths preserve canonical emptiness.** On SIGINT cancellation, aggregator failure, or degraded-below-2, the canonical `$REVIEWS_DIR` is left untouched (empty) — staging-directory state is preserved under `iterations/<iter>/round-N/` for inspection but is NOT consumed by the Stop-hook, `wait`, or any next-iteration decision surface.
  - **Helper signature.** The current `spawn_reviewer` signature in `bin/review-gate-models.sh:620-745` does not accept an output-directory parameter (it writes to `$REVIEWS_DIR` directly). Phase B adds an optional output-directory parameter to `spawn_reviewer` as a small additive change — non-debate callers continue to pass nothing and continue to write to `$REVIEWS_DIR` (byte-parity-preserved); the coordinator passes the per-round staging path. A regression test asserts non-debate behavior is unchanged.
- **D5. Per-reviewer timeout under debate** — same as today's polling-loop budget per round. Each round gets its own fresh budget; the terminal-abstention rule means we don't accumulate budget across rounds. A reviewer that times out in round k is Mode A (`abstained=true`) for the run.
- **D6. Reserved exit codes and on-disk gate state:**
  - SIGINT cancellation: `130` (conventional 128 + signal). On-disk: `gate-state.json.status="pending"` (unchanged from spawn entry); canonical `$REVIEWS_DIR` empty.
  - Aggregator failure: `5` (new, reserved). Stderr: `aggregator failed: <reason>`. On-disk: `gate-state.json.status="pending"` (unchanged from spawn entry); canonical `$REVIEWS_DIR` empty.
  - Degraded-below-2 (preflight or mid-debate): `6` (new, reserved). On-disk: `gate-state.json.status="awaiting_decision"` and `gate-state.json.consensus = {"verdict": "requires_decision", "reason": "debate degraded below 2 active reviewers in the final peer round", "iteration": <current-iter>}`. The canonical `$REVIEWS_DIR` is left empty; partial outputs preserved under `iterations/<iter>/round-N/`. NOTE: `requires_decision` is the consensus-calculator output value, NOT the `gate-state.json.status` value — the existing state-model alphabet (`pending` / `awaiting_decision` / `resolved`) is preserved.
  - Bare-spawn whitelist rejection: `2` (existing preflight error pattern).
- **D7. Strategy directive prose** — three short markdown files under `prompts/strategies/`, each ~3-5 sentences, anchored as below. The exact wording is implementation work but the intent is fixed:
  - `verification-first.md`: instructs the reviewer to treat the artifact as plausibly correct, walk through its claims and verify each holds with cited evidence, and reserve highest-priority findings for breakdowns where the evidence does NOT hold.
  - `falsification-first.md`: instructs the reviewer to treat the artifact as plausibly wrong, try to find concrete counterexamples that show its claims fail, and reserve highest-priority findings for cases demonstrable with evidence — adversarial-without-evidence is uninformative.
  - `decompose.md`: instructs the reviewer to decompose the artifact into its constituent parts (sections / subsystems / requirements), judge each on its own merits, and surface findings at the granularity of the part rather than at the artifact level.
- **D8. Test fixture layout** — single directory `bin/tests/fixtures/pre-debate-baseline/` (no separate `r9-byte-parity/`). The R9 byte-parity tests read directly from `pre-debate-baseline/`. Matches the spec's explicit naming.
- **D9. Pre-feature golden capture** — one-shot script `bin/tests/capture-pre-debate-baseline.sh` rather than a `--capture-golden` mode on `bin/review-gate`. Capture machinery is test-time only; doesn't ship with the production binary past Step 0.
- **D10. Pre-feature prompt capture mechanism** — the Step-0 capture script (`bin/tests/capture-pre-debate-baseline.sh`) reads the rendered prompt files that `bin/review-gate` already persists under `$REVIEWS_DIR/<reviewer>.prompt` (the path passed to the reviewer CLI via `< "$REVIEW_PROMPT"` in `bin/review-gate-models.sh:670-742`). No production-code change to the prompt builder is required for Step 0. A future debate-time prompt-dump env var (e.g., `REVIEW_GATE_DUMP_PROMPT_PATH`) is OPTIONAL and out of v1 scope — it would only be needed if Phase E test fixtures want to capture per-round-per-reviewer prompts for snapshot testing of the Round-2 anonymization, and that capture mechanism can land alongside Phase E without touching Step 0.
- **D11. `--debate-seed N` value space** — any non-negative integer; rendered as decimal string for the R1 algorithm. No 32-bit constraint (SHA-256 doesn't care). Implementations that consume the seed via `$RANDOM` for the production-path shuffle MUST NOT cross-derive from the seed input — they MUST use a non-deterministic source per recipient when the seed flag is absent. The cross-platform byte-stable shuffle algorithm is pinned in spec R1 edge cases ("Seeded peer-ordering algorithm") — SHA-256 over `<seed>:<R-canonical-name>:<P-opaque-ID>` sorted ascending by lowercase 64-char hex digest with peer-opaque-ID lex tiebreak. The plan does not redefine the algorithm; it commits to implementing the spec's pinned form. Production-path shuffle (no seed) uses `$RANDOM` or `/dev/urandom` per recipient and MUST NOT cross-derive from the seed input.
- **D12. Strategy-assignment determinism scope.** Per spec R3, `<artifact_id>` is the `realpath` of the source artifact (or the verbatim `diff_args_str` for code-review). Determinism therefore holds **per-machine and per-checkout-location**: the same artifact at the same absolute path on the same machine yields the same strategy assignment across reruns and across distinct review sessions. Two engineers reviewing the same logical artifact at different absolute paths (e.g., `/Users/alice/repo/...` vs `/home/bob/workspace/...`) will see different strategy assignments — this is acceptable v1 behavior because the per-rerun-on-same-machine guarantee is what the determinism contract pins, and cross-machine reproducibility for fixture tests goes through the orthogonal `--debate-seed N` mechanism (which seeds peer ordering) rather than through the strategy hash.

## Open Questions

None remaining at plan time. All P0/P1/P2/P3 implementation choices were resolved (see Resolved Design Decisions above). v2 polish items (wrapper-level rejection of `--debate` on generator slash commands; per-agent confidence prior rescaling; sparsified peer broadcast; adaptive early exit; K\*/disagreement-rate diagnostics; cross-session safety memory; fuzzier title matching for the dedup predicate) are deferred per spec Decisions Made.

## Next Steps

After this plan is approved, run `/cerberus:create-tasks` to generate execution artifacts:

- `--beads` → Create Beads issues with dependencies for multi-agent parallelization.
- (default) → Generate TODO.md checklist for simpler tracking.
