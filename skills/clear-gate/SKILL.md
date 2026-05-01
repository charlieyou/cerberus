---
name: clear-gate
disable-model-invocation: true
description: Clear the review gate and allow the session to stop
---

## Host-Neutral Execution

Before running any Bash snippet in this skill, source the shared Cerberus skill environment helper. This keeps the same skill usable from Claude, Codex, Amp, or a generic shell by resolving `CERBERUS_ROOT`, `CERBERUS_HOST`, and the active run key when the host exposes one.

```bash
cerberus_root="${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"
if [ -z "$cerberus_root" ] && [ -n "${CLAUDE_SKILL_DIR:-}" ]; then
    cerberus_root="$(cd "$CLAUDE_SKILL_DIR/../.." && pwd)"
fi
if [ -z "$cerberus_root" ] || [ ! -r "$cerberus_root/bin/cerberus-skill-env" ]; then
    echo "cerberus skill: cannot find Cerberus backend; set CERBERUS_ROOT to the checkout root" >&2
    exit 127
fi
# shellcheck source=/dev/null
. "$cerberus_root/bin/cerberus-skill-env"
```

Use `${CERBERUS_ROOT}` when invoking Cerberus binaries below.


Run:

```bash
${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}/bin/review-gate resolve --reason "manual clear"
```

This resolves the active review gate, allowing you to stop the session without completing the review cycle.
