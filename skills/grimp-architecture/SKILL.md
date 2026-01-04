---
name: grimp-architecture
description: Explore Python import graphs and enforce layered architecture using grimp.
---

# Grimp Architecture Exploration

Use this skill when the user wants to explore Python module boundaries, investigate dependency flow, or enforce layered architecture with grimp.

## Setup

Create the venv and install grimp (requires Python 3.12):

```bash
uv venv ~/.agents/skills/grimp-architecture/.venv --python 3.12
uv pip install grimp --python ~/.agents/skills/grimp-architecture/.venv/bin/python
```

## Quick Start

```bash
# Shorthand
GRIMP=~/.agents/skills/grimp-architecture/.venv/bin/python\ ~/.agents/skills/grimp-architecture/scripts/grimp_cli.py
```

1. **Explore the graph** (fan-in/out, top-level structure):
   ```bash
   $GRIMP explore mypackage
   ```
2. **Trace a boundary leak** (shortest import chain):
   ```bash
   $GRIMP path mypackage.validation mypackage.orchestrator
   ```
3. **Optional layer check** (ordered high -> low):
   ```bash
   $GRIMP layers --layer mypackage.api --layer mypackage.domain --layer mypackage.infra
   ```
4. **Incremental enforcement** (baseline + diff):
   ```bash
   $GRIMP layers --layer mypackage.api --layer mypackage.domain --layer mypackage.infra --json > .grimp-baseline.json
   $GRIMP diff --baseline .grimp-baseline.json --layer mypackage.api --layer mypackage.domain --layer mypackage.infra
   ```

## Commands

- `explore <package> [--top N]`: summarize structure, fan-in/out, and child packages.
- `path <importer> <imported>`: shortest import chain between modules/packages.
- `layers --layer ...`: find illegal dependencies for an ordered layer list.
- `diff --baseline ... --layer ...`: fail only on *new* layer violations.

All commands accept `--include-external` to include external packages in the graph.

## Guidance

- **Explore first**: run `explore` before defining layers so you understand how the code is organized.
- **Use path tracing** to confirm suspicious dependencies before reporting them.
- **Layer checks are optional** unless the repo already defines layers or the review clearly proposes them.
- **Baseline + diff** is the safest way to enforce architecture incrementally in large codebases.

## Packaging Expectations

Grimp needs the project to be importable by package name (not file paths).

- Use a normal package layout with `__init__.py` files.
- **Run from the project root** — scripts auto-detect packages in the current directory.
- For `src/` layouts, set `PYTHONPATH=src` or install the project.
- Editable installs are fine for local exploration.

Sanity check:
```bash
python -c "import mypackage; print(mypackage.__file__)"
```

Common options:
```bash
uv sync
uv pip install -e .
PYTHONPATH=src $GRIMP explore mypackage  # for src/ layouts
```

## Notes

- **Python 3.12 is required** - grimp has compatibility issues with Python 3.14+.
- The skill venv at `~/.agents/skills/grimp-architecture/.venv` has grimp pre-installed.
- For advanced grimp features (closed layers, non-independent siblings, containers), use a custom Python snippet.
