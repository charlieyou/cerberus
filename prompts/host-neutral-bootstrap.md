# --- shared resolver (canonical body; identical across all callers) ---
root="${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}"
bin="$root/bin/cerberus"
[ -n "$root" ] || { echo "cerberus: plugin root not set" >&2; exit 127; }
export CERBERUS_ROOT="$root"
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

Skill SKILL.md form:

```sh
exec "$bin" "$@"
```

Hook form:

```sh
exec "$bin" hook <name>
```
