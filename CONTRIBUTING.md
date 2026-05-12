# Contributing

Cerberus v2 is maintained as a Go plugin for Claude Code and Codex. Keep
changes narrow, prefer the existing package boundaries, and run the same make
targets that CI uses before tagging or publishing a release.

## Local Setup

Prerequisites:

- Go 1.22 or newer.
- The `claude`, `codex`, and `gemini` CLIs for real reviewer smoke checks.
- A clean plugin checkout when cutting a release tag.

Build and test the local tree:

```bash
make build
make test
make lint
```

## Maintainer Install Workflow

`make install` is the v2 maintainer workflow that replaces the old
`bin/update-plugin` convenience script from v1. The target installs the
`cerberus` command from `./cmd/cerberus` with the local Go toolchain:

```bash
make install
```

Use this after changing Go source, hooks, prompts, skills, or manifests and
before running manual host smoke tests. For plugin-store testing, install or
update the plugin through the host plugin manager and then run `make install`
from the same checkout so the host invokes the current binary.

Do not commit `bin/cerberus`; it is a local build artifact and is ignored.

## Fixture Refresh

Mock reviewer fixtures live under `tests/fixtures/` and are replayed by the
Go mock CLIs in `tests/mocks/`. When prompt text, roster behavior, or reviewer
JSON shape changes, refresh fixtures intentionally:

```bash
make fixtures-refresh
```

The refresh target runs the real reviewer CLIs against the known prompt set
and writes the fixture JSON that the mocks will later replay. Review the diff
carefully; fixture churn is expected only when prompt inputs or reviewer output
contracts changed.

CI uses mock fixtures and does not call the real reviewer CLIs. Missing mock
fixtures fail loudly, which usually means the prompt hash changed and the
fixture set needs a deliberate refresh.

## Binary-Size Budget

The CI build matrix enforces the D35 release budget after building with
`-ldflags="-s -w"`:

| Target | Maximum stripped binary size |
| --- | ---: |
| `darwin/arm64` | 30 MB |
| all other matrix targets | 35 MB |

If a legitimate feature needs more space, update the cap through a reviewed
Decision-Log row before changing the CI assertion.

## Contribution Guidelines

- Keep runtime code in Go; v2 must not reintroduce `bin/*.sh` runtime files.
- Prefer focused packages under `internal/` and add tests beside the behavior
  being changed.
- Preserve the dual-host contract: Claude Code and Codex must both load the
  same surviving skill surface.
- Keep Gemini invocations under the read-only policy file.
- Do not restore `run-team`, `TaskCompleted`, `TeammateIdle`, or the removed
  team-automation templates.
- Update `README.md`, `docs/CODEX.md`, and this file when a maintainer or
  user workflow changes.

## Launch Checklist Walkthrough

This walkthrough consolidates the spec section 4 GA checklist. Each item is
green via its upstream verification task or the local file listed here; this
document does not replace those underlying checks.

| Checklist item | Status | Upstream verification |
| --- | --- | --- |
| R1-R10 all verifiable | Green | Beads `cerberus-yd7.6` (T606), `cerberus-b31.2` (T702), `cerberus-b31.3` (T703), `cerberus-b31.4` (T704), `cerberus-ndk.1` (T801), `cerberus-ndk.2` (T802), and `cerberus-ndk.4` (T804) are closed as done. |
| Zero `bin/*.sh` files in the v2 plugin tree | Green | T606 cleanup invariants, backed by `tests/integration/cleanup_invariants_test.go` and `make lint`. |
| CI matrix for Claude, Codex, and generic hosts on darwin and linux | Green | T703 CI matrix, backed by `.github/workflows/ci.yml`. |
| Codex smoke test: all 13 surviving skills runnable | Green | `tests/integration/codex_skill_smoke_test.go` verifies the Codex manifest, hooks path, and surviving skill set. |
| Multi-instance roster smokes (`codex` x3 models; `claude` x2 strategies) | Green | T702 integration suite, backed by `tests/integration/debate_multi_instance_test.go`. |
| Debate smoke covers mixed-provider and same-provider multi-instance panels | Green | T702 integration suite, backed by `tests/integration/debate_multi_instance_test.go` and `tests/integration/debate_gemini_policy_test.go`. |
| One reviewer plus `--debate` refuses at preflight | Green | T702 integration suite, backed by `internal/cli/spawn_code_review_test.go`, `internal/roster/degradation_test.go`, and `tests/integration/codex_default_roster_degradation_test.go`. |
| Gemini read-only policy verified in single-pass and debate panels | Green | T702 integration suite, backed by `internal/reviewer/reviewer_test.go`, `internal/generate/subprocess_test.go`, `tests/integration/debate_gemini_policy_test.go`, and `tests/integration/debate_multi_instance_test.go`. |
| Rollback path documented per D11 | Green | T801 README rewrite and T802 CODEX rewrite document the v1.54.x pin, `/plugin update --version 1.54.x`, and clearing v2 state. |
| `README.md` and `docs/CODEX.md` rewritten for v2 | Green | T801 and T802 are closed as done. |
| Plugin manifests advertise `2.0.0` | Green | T804 manifest gate. |
| Run-team files and hook entries absent; task-generation files remain | Green | T606 cleanup invariants and `tests/integration/run_team_absence_test.go`; `skills/create-tasks`, `skills/review-tasks`, and `templates/tasks-template.md` remain. |

The v2.0.0 tag should be created only after this checklist remains green on
the verified commit. The annotated tag must reference the rebuild spec, the
rebuild plan, and this walkthrough.
