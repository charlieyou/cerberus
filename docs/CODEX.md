# Cerberus on Codex CLI

> **Status:** Phase 1 in progress. This document is the user-facing
> install / usage guide for running Cerberus under OpenAI's Codex CLI.
> The user-facing sections (Install, Configure Hooks, Commands,
> Limitations, Troubleshooting) are scaffolded here and will be filled
> in by **T011** once Phase 1 implementation lands. Until then, the
> only authoritative section is **Phase 1 Spike Findings** below, which
> resolves the two open questions that gate Phase 1 implementation
> (`.codex-plugin/plugin.json` schema, plugin-install path env var).

## Phase 1 Spike Findings

These findings are the resolutions of **OQ-1** (Codex skill manifest
fields) and **OQ-2** (stable Codex plugin-install path env var) from
`docs/2026-04-29-codex-amp-plugin-port-plan.md`, recorded **2026-04-30**.

> **Source disclosure.** No public, versioned schema for
> `.codex-plugin/plugin.json` is published in the OpenAI Codex CLI
> documentation that the spike author had access to as of 2026-04-30.
> The findings below are therefore **best-effort**, derived from the
> following inputs, in order of confidence:
>
> 1. The plan's host assumptions (plan §Host Assumptions L143-L171)
>    which already pre-commit to `"skills only"` packaging via
>    `.codex-plugin/plugin.json` and a separate user-installed
>    `templates/codex-hooks.json` lifecycle template.
> 2. The shape of the existing `.claude-plugin/plugin.json` (the
>    sibling host's manifest) as a credible cross-host reference.
> 3. Conventional plugin-manifest fields shared by other CLI plugin
>    ecosystems (npm, VS Code extensions, Claude Code) which converge
>    on the same minimum metadata set.
>
> Per task **T006** acceptance criteria and plan §Prerequisites
> (L215-L218): "Block Phase 1 implementation until resolved (or
> documented as best-effort)." This spike documents a best-effort
> answer; **`T007` MUST flag the manifest as best-effort** in an inline
> comment and use `version: "1.0.0"`. If a future Codex CLI release
> publishes an authoritative schema that contradicts the assumptions
> below, T007's manifest is updated and `docs/CODEX.md` is amended in
> the same patch.

### OQ-1 — `.codex-plugin/plugin.json` schema (best-effort)

**Resolution:** Use the schema below for T007. It mirrors the
`.claude-plugin/plugin.json` shape and adds an explicit `skills`
declaration array since Codex packaging is **skills-only** per plan
§Host Assumptions.

#### Required top-level fields

| Field | Type | Notes |
|---|---|---|
| `name` | string | Plugin identifier; must equal `"cerberus"` to match the directory layout (`skills/cerberus/*.md`). |
| `version` | string | SemVer. T007 ships `"1.0.0"` to signal "first Codex packaging" independent of the Claude plugin version. |
| `description` | string | One-line description; mirrors `.claude-plugin/plugin.json`. |
| `skills` | array | List of skill descriptors. See **Skill descriptor shape** below. Six entries: `review-code`, `review-plan`, `review-spec`, `ask`, `status`, `clear-gate`. |

#### Optional top-level fields (recommended for parity with the Claude manifest)

| Field | Type | Notes |
|---|---|---|
| `author` | object | `{ "name": "<author>" }`. Same as Claude manifest. |
| `repository` | string | URL. Same as Claude manifest. |
| `license` | string | SPDX id (e.g. `"MIT"`). |
| `keywords` | array of strings | Discoverability tags (e.g. `["code-review", "multi-model", "quality-gate"]`). |
| `homepage` | string | Documentation landing page URL. |

#### Skill descriptor shape

Each entry in `skills[]` is an object:

| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | string | required | The user-facing skill name; matches the markdown filename without `.md` (e.g. `"review-code"` → `skills/cerberus/review-code.md`). |
| `path` | string | required | Plugin-relative path to the skill markdown (e.g. `"skills/cerberus/review-code.md"`). |
| `description` | string | required | One-line summary for skill listings / autocomplete. |
| `arguments` | array of objects | optional | Used for skills that accept positional arguments (`review-plan`, `review-spec`, `ask`). Each entry: `{ "name": "<arg>", "required": <bool>, "description": "<text>" }`. T007 may omit this if Codex's actual schema rejects unknown fields; T010 re-evaluates when authoring final skill markdown. |

#### Slash-command vs skill semantics for the six Tier-1 workflows

Codex packaging is **skills-only**: there is no separate slash-command
declaration in `.codex-plugin/plugin.json`. All six Tier-1 workflows
ship as Codex skills under `skills/cerberus/`. The user invokes them
through Codex's skill-invocation UX (the exact verb — `/skill`, `@`-mention,
or skill picker — is host-dependent and not part of the manifest
contract).

| Workflow | Skill file | Backend invocation | Argument shape |
|---|---|---|---|
| Code review | `skills/cerberus/review-code.md` | `bin/review-gate spawn-code-review [flags]` | Optional flags: `--mode`, `--focus`, `--base`, `--exclude`. Mirrors `commands/review-code.md`. |
| Plan review | `skills/cerberus/review-plan.md` | `bin/review-gate spawn-plan-review <plan-path> [flags]` | **Path required (v1).** Non-Claude hosts have no plan registry per plan §Out Of Scope. |
| Spec review | `skills/cerberus/review-spec.md` | `bin/review-gate spawn-spec-review <spec-path> [flags]` | **Path required (v1).** Same rationale as Plan review. |
| Ask panel | `skills/cerberus/ask.md` | `bin/review-gate spawn-ask <question>` then `wait --json --finalize` | Free-text question; skill synthesizes the panel answer from the wait output. |
| Status | `skills/cerberus/status.md` | `bin/review-gate status --json` | None. Read-only; never mutates state (see plan §Phase 0 exit criteria). |
| Clear gate | `skills/cerberus/clear-gate.md` | `bin/review-gate resolve --reason "manual clear from Codex"` | None. Operator escape hatch. |

#### Sample manifest (verbatim seed for T007)

```json
{
  "name": "cerberus",
  "version": "1.0.0",
  "description": "Three-headed guardian of code quality. Multi-model consensus review with Codex, Gemini, and Claude.",
  "author": {
    "name": "charlieyou"
  },
  "repository": "https://github.com/charlieyou/cerberus",
  "license": "MIT",
  "keywords": ["code-review", "plan-review", "multi-model", "quality-gate", "cerberus"],
  "skills": [
    {
      "name": "review-code",
      "path": "skills/cerberus/review-code.md",
      "description": "Spawn a multi-model code review (Codex + Gemini + Claude consensus)."
    },
    {
      "name": "review-plan",
      "path": "skills/cerberus/review-plan.md",
      "description": "Spawn a multi-model plan review. Requires an explicit plan path."
    },
    {
      "name": "review-spec",
      "path": "skills/cerberus/review-spec.md",
      "description": "Spawn a multi-model spec review. Requires an explicit spec path."
    },
    {
      "name": "ask",
      "path": "skills/cerberus/ask.md",
      "description": "Ask the Cerberus panel an open-ended question."
    },
    {
      "name": "status",
      "path": "skills/cerberus/status.md",
      "description": "Show current review-gate status (read-only)."
    },
    {
      "name": "clear-gate",
      "path": "skills/cerberus/clear-gate.md",
      "description": "Manually clear the active review gate."
    }
  ]
}
```

> **T007 implementer note.** Add an inline comment at the top of
> `.codex-plugin/plugin.json` (in a leading line of the file's commit
> message and as a sibling `README` if Codex's parser is strict-JSON
> and rejects comments) noting: *"Schema is best-effort per
> docs/CODEX.md §Phase 1 Spike Findings; revisit when Codex publishes
> an authoritative manifest schema."*

### OQ-2 — Stable plugin-install path env var

**Resolution:** **No** stable, documented Codex-provided env var
equivalent to Claude's `CLAUDE_PLUGIN_ROOT` is known as of 2026-04-30.

**Fallback approach (adopted):** `templates/codex-hooks.json` ships
with a documented placeholder string that the user manually edits
during install. The placeholder is:

```text
<CERBERUS_INSTALL_ROOT>
```

It appears in every `command:` field in the hook template that needs
to invoke a Cerberus binary. The user replaces it with the absolute
path to their Cerberus install root (the directory containing
`bin/`, `skills/`, `.codex-plugin/`, etc.) when installing the hook
template into Codex's hooks config.

**Rationale.**

- Plan §Risks (L1033) already calls this case out: *"Codex install root
  path env var unstable across versions | Hook template uses
  placeholder substitution; `docs/CODEX.md` documents manual edit."*
  This spike confirms the assumed risk is real and selects the
  fallback the plan pre-described.
- The shared backend already accepts `CERBERUS_ROOT` as an explicit
  override (plan §API/Interface Design L549). Users who prefer to set
  `CERBERUS_ROOT` in their shell profile rather than substitute the
  placeholder may do so; the hook template documents both paths.
- If a future Codex release ships a stable env var (e.g.
  `CODEX_PLUGIN_ROOT`), `templates/codex-hooks.json` is updated to
  default to `${CODEX_PLUGIN_ROOT}` with the manual-edit step
  documented as a fallback. The shared backend already routes through
  `__cerberus_resolve_root` which picks `CERBERUS_ROOT` first, so
  callers who set `CERBERUS_ROOT` in env continue to work either way.

**Install-time UX (preview, finalized in T010 + T011).**

The two-step Codex install becomes:

1. Codex marketplace install / clone of the plugin populates
   `.codex-plugin/`, `skills/cerberus/`, `bin/`, etc. into a
   user-known location (the **install root**).
2. User opens `templates/codex-hooks.json`, replaces every
   `<CERBERUS_INSTALL_ROOT>` token with the absolute install-root path,
   and copies the resulting JSON into Codex's hooks configuration
   (typically `~/.codex/hooks.json` or platform equivalent — the
   exact target path is documented in T011's "Configure Hooks"
   section).

The Cerberus backend itself is unaffected by the placeholder choice;
it continues to read `CERBERUS_ROOT` (with `CLAUDE_PLUGIN_ROOT`
fallback) via `__cerberus_resolve_root`. The placeholder lives **only**
in the hook template, not in any backend code path.

### Implications for downstream tasks

- **T007** authors `.codex-plugin/plugin.json` per the OQ-1 sample
  above. Marks the manifest as **best-effort** in a sibling
  `README` or commit message. Uses `version: "1.0.0"`.
- **T010** authors `templates/codex-hooks.json` using the
  `<CERBERUS_INSTALL_ROOT>` placeholder per OQ-2. Documents the
  manual-edit step in `docs/CODEX.md` (which T011 finalizes).
- **T011** finalizes the user-facing sections of this document
  (Install, Configure Hooks, Commands, Limitations, Troubleshooting).
  At that point the spike-findings section MAY be moved to an
  appendix, but it MUST remain readable so future contributors can
  audit the best-effort decisions.

---

## Install

> **TODO (T011):** Walk-through of installing the Cerberus Codex
> plugin from the marketplace (or by clone), including prerequisites
> (`bin/review-gate` runtime: `bash`, `jq`, `python3`; reviewer CLIs:
> `codex`, `gemini`, `claude`).

## Configure Hooks

> **TODO (T011):** Step-by-step walk-through of installing
> `templates/codex-hooks.json` into Codex's hooks configuration,
> including the `<CERBERUS_INSTALL_ROOT>` substitution from OQ-2 above.

## Commands (Skills)

> **TODO (T011):** User-facing reference for the six Tier-1 skills
> (`review-code`, `review-plan`, `review-spec`, `ask`, `status`,
> `clear-gate`), including invocation syntax, arguments, and example
> workflows. The skill-to-backend mapping table in OQ-1 above is the
> authoritative source.

## Limitations (v1)

> **TODO (T011):** Document the v1 limitations, drawn from the plan:
>
> - Plan/spec review requires an **explicit path** (no plan/spec
>   registry on Codex in v1; plan §Out Of Scope).
> - Codex `Stop` **never waits by default**; opt-in bounded wait via
>   `CERBERUS_CODEX_STOP_WAIT_SECONDS=N` (plan §API).
> - Codex agent-team automation (`/cerberus:run-team`,
>   `cerberus-task-completed-hook`, `cerberus-teammate-idle-hook`) is
>   **out of scope** for v1.
> - Failure-open principle for the `Stop` adapter (plan §Host
>   Assumptions L167-L170).

## Troubleshooting

> **TODO (T011):** Common issues and remediation, including:
>
> - `<CERBERUS_INSTALL_ROOT>` placeholder not substituted in hook
>   template (OQ-2 fallback).
> - Conflicting `CERBERUS_ROOT` and `CLAUDE_PLUGIN_ROOT` in shell
>   profile (resolution: `CERBERUS_ROOT` wins; plan §Risks L1034).
> - Reviewer CLIs missing or `jq` not installed.
> - Stale `active-session.json` in
>   `~/.cerberus/runtime/codex/<workspace-key>/`.
