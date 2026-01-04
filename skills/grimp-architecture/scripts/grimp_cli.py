#!/usr/bin/env python3
"""Explore Python import graphs and enforce layered architecture using grimp."""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path
from typing import Iterable


def _setup_pythonpath(package: str) -> None:
    """Add current directory to sys.path if package is found there."""
    cwd = Path.cwd()
    top_level = package.split(".")[0]
    package_path = cwd / top_level
    if package_path.is_dir() and (package_path / "__init__.py").exists():
        cwd_str = str(cwd)
        if cwd_str not in sys.path:
            sys.path.insert(0, cwd_str)


def _require_grimp():
    try:
        import grimp  # type: ignore
    except ImportError:
        print("grimp is not installed. Install with: pip install grimp", file=sys.stderr)
        sys.exit(1)
    return grimp


def _parse_layer(value: str):
    parts = [part.strip() for part in value.split(",") if part.strip()]
    if not parts:
        raise argparse.ArgumentTypeError("Layer cannot be empty")
    if len(parts) == 1:
        return parts[0]
    return set(parts)


def _positive_int(value: str) -> int:
    ivalue = int(value)
    if ivalue < 0:
        raise argparse.ArgumentTypeError(f"must be non-negative: {value}")
    return ivalue


def _layer_to_list(layer) -> list[str]:
    if isinstance(layer, set):
        return sorted(layer)
    return [layer]


def _infer_packages_from_layers(layers: Iterable) -> list[str]:
    packages: set[str] = set()
    for layer in layers:
        for item in _layer_to_list(layer):
            packages.add(item.split(".")[0])
    return sorted(packages)


def _infer_packages_from_modules(importer: str, imported: str, packages: Iterable[str] | None) -> list[str]:
    if packages:
        return sorted(set(packages))
    inferred = {importer.split(".")[0], imported.split(".")[0]}
    return sorted(inferred)


def _is_internal(module: str, packages: Iterable[str]) -> bool:
    for pkg in packages:
        if module == pkg or module.startswith(pkg + "."):
            return True
    return False


def _sorted_modules(counter: Counter[str], top: int) -> list[tuple[str, int]]:
    return sorted(counter.items(), key=lambda item: (-item[1], item[0]))[:top]


def _format_route(route) -> str:
    heads = sorted(route.heads)
    tails = sorted(route.tails)
    middle = list(route.middle)
    head = heads[0] if heads else ""
    tail = tails[0] if tails else ""
    chain = [node for node in [head, *middle, tail] if node]
    if not chain:
        return "(no route)"
    suffix = f" (heads={len(heads)}, tails={len(tails)})"
    return " -> ".join(chain) + suffix


def _serialize_dependency(dep) -> dict:
    return {
        "importer": dep.importer,
        "imported": dep.imported,
        "routes": [
            {
                "heads": sorted(route.heads),
                "middle": list(route.middle),
                "tails": sorted(route.tails),
            }
            for route in dep.routes
        ],
    }


def _load_baseline(path: str) -> set[tuple[str, str]]:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        print(f"Baseline file not found: {path}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"Invalid JSON in baseline: {e}", file=sys.stderr)
        sys.exit(1)

    if isinstance(data, dict):
        data = data.get("illegal_dependencies", [])

    pairs: set[tuple[str, str]] = set()
    for item in data:
        if not isinstance(item, dict):
            continue
        importer = item.get("importer")
        imported = item.get("imported")
        if importer and imported:
            pairs.add((importer, imported))
    return pairs


# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------


def cmd_explore(args: argparse.Namespace) -> int:
    """Summarize structure, fan-in/out, and child packages."""
    for pkg in args.package:
        _setup_pythonpath(pkg)

    grimp = _require_grimp()
    try:
        graph = grimp.build_graph(
            *args.package,
            include_external_packages=args.include_external,
        )
    except (ValueError, ImportError, ModuleNotFoundError, SyntaxError) as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1

    packages = args.package
    internal_modules = [m for m in graph.modules if _is_internal(m, packages)]

    print("Grimp import graph summary")
    print(f"Packages: {', '.join(packages)}")
    print(f"Modules: {len(internal_modules)}")
    print(f"Total imports: {graph.count_imports()}")

    for pkg in packages:
        children = sorted(graph.find_children(pkg))
        print(f"\nChildren of {pkg} ({len(children)}):")
        for child in children[: args.max_children]:
            descendant_count = len(graph.find_descendants(child))
            print(f"  - {child} ({descendant_count} descendants)")
        if len(children) > args.max_children:
            print(f"  ... {len(children) - args.max_children} more")

    fan_out = Counter()
    fan_in = Counter()
    for module in internal_modules:
        fan_out[module] = len(graph.find_modules_directly_imported_by(module))
        fan_in[module] = len(graph.find_modules_that_directly_import(module))

    print("\nTop fan-out (imports many modules):")
    shown_out = False
    for module, count in _sorted_modules(fan_out, args.top):
        if count < args.min_out:
            continue
        print(f"  - {module}: {count}")
        shown_out = True
    if not shown_out:
        print("  (none over threshold)")

    print("\nTop fan-in (imported by many modules):")
    shown_in = False
    for module, count in _sorted_modules(fan_in, args.top):
        if count < args.min_in:
            continue
        print(f"  - {module}: {count}")
        shown_in = True
    if not shown_in:
        print("  (none over threshold)")

    return 0


def cmd_path(args: argparse.Namespace) -> int:
    """Find shortest import chain between modules/packages."""
    packages = _infer_packages_from_modules(args.importer, args.imported, args.package)
    for pkg in packages:
        _setup_pythonpath(pkg)

    grimp = _require_grimp()
    try:
        graph = grimp.build_graph(
            *packages,
            include_external_packages=args.include_external,
        )
    except (ValueError, ImportError, ModuleNotFoundError, SyntaxError) as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1

    chain = graph.find_shortest_chain(
        importer=args.importer,
        imported=args.imported,
        as_packages=args.as_packages,
    )

    if chain is None:
        print("No import chain found.")
        return 1

    print(" -> ".join(chain))
    return 0


def cmd_layers(args: argparse.Namespace) -> int:
    """Find illegal dependencies for an ordered layer list."""
    layers = args.layer
    packages = args.package or _infer_packages_from_layers(layers)
    for pkg in packages:
        _setup_pythonpath(pkg)

    grimp = _require_grimp()

    if len(layers) < 2:
        print("At least two layers are required.", file=sys.stderr)
        return 2

    try:
        graph = grimp.build_graph(
            *packages,
            include_external_packages=args.include_external,
        )
    except (ValueError, ImportError, ModuleNotFoundError, SyntaxError) as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1

    containers = set(args.container) if args.container else None
    illegal = graph.find_illegal_dependencies_for_layers(
        layers,
        containers=containers,
    )

    illegal_sorted = sorted(illegal, key=lambda dep: (dep.importer, dep.imported))

    if args.json:
        payload = {
            "packages": packages,
            "layers": [_layer_to_list(layer) for layer in layers],
            "containers": sorted(containers) if containers else [],
            "illegal_dependencies": [_serialize_dependency(dep) for dep in illegal_sorted],
        }
        print(json.dumps(payload, indent=2))
    else:
        if not illegal_sorted:
            print("No illegal dependencies found.")
            return 0

        print("Illegal dependencies:")
        for dep in illegal_sorted:
            print(f"- {dep.importer} -> {dep.imported}")
            for route in list(dep.routes)[: args.max_routes]:
                print(f"    {_format_route(route)}")

    return 2 if illegal_sorted else 0


def cmd_diff(args: argparse.Namespace) -> int:
    """Fail only on new layer violations compared to baseline."""
    layers = args.layer
    packages = args.package or _infer_packages_from_layers(layers)
    for pkg in packages:
        _setup_pythonpath(pkg)

    grimp = _require_grimp()

    if len(layers) < 2:
        print("At least two layers are required.", file=sys.stderr)
        return 2

    try:
        graph = grimp.build_graph(
            *packages,
            include_external_packages=args.include_external,
        )
    except (ValueError, ImportError, ModuleNotFoundError, SyntaxError) as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1

    containers = set(args.container) if args.container else None
    illegal = graph.find_illegal_dependencies_for_layers(
        layers,
        containers=containers,
    )

    current = {(dep.importer, dep.imported) for dep in illegal}
    baseline = _load_baseline(args.baseline)
    new = sorted(current - baseline)
    resolved = sorted(baseline - current)

    if not new:
        print("No new layer violations.")
        if resolved:
            print(f"Resolved violations: {len(resolved)}")
        return 0

    print(f"New violations: {len(new)}")
    for importer, imported in new[: args.max_show]:
        print(f"- {importer} -> {imported}")
    if len(new) > args.max_show:
        print(f"... {len(new) - args.max_show} more")

    return 2


# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="grimp",
        description="Explore Python import graphs and enforce layered architecture.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # explore
    p_explore = subparsers.add_parser("explore", help="Summarize structure, fan-in/out, and children.")
    p_explore.add_argument("package", nargs="+", help="Top-level package(s) to analyze")
    p_explore.add_argument("--include-external", action="store_true", help="Include external packages")
    p_explore.add_argument("--top", type=_positive_int, default=10, help="Entries in fan-in/out lists (default: 10)")
    p_explore.add_argument("--min-in", type=_positive_int, default=2, help="Minimum fan-in to display (default: 2)")
    p_explore.add_argument("--min-out", type=_positive_int, default=4, help="Minimum fan-out to display (default: 4)")
    p_explore.add_argument("--max-children", type=_positive_int, default=40, help="Max children per package (default: 40)")
    p_explore.set_defaults(func=cmd_explore)

    # path
    p_path = subparsers.add_parser("path", help="Find shortest import chain between modules.")
    p_path.add_argument("importer", help="Importing module/package")
    p_path.add_argument("imported", help="Imported module/package")
    p_path.add_argument("--package", action="append", help="Top-level package (repeatable)")
    p_path.add_argument("--include-external", action="store_true", help="Include external packages")
    p_path.add_argument("--as-packages", action="store_true", help="Treat as packages, not modules")
    p_path.set_defaults(func=cmd_path)

    # layers
    p_layers = subparsers.add_parser("layers", help="Find illegal dependencies for ordered layers.")
    p_layers.add_argument("--package", action="append", help="Top-level package (repeatable)")
    p_layers.add_argument("--layer", action="append", type=_parse_layer, required=True, help="Layer (high -> low), comma for siblings")
    p_layers.add_argument("--container", action="append", help="Container packages (repeatable)")
    p_layers.add_argument("--include-external", action="store_true", help="Include external packages")
    p_layers.add_argument("--max-routes", type=_positive_int, default=3, help="Max routes per dependency (default: 3)")
    p_layers.add_argument("--json", action="store_true", help="Emit JSON output")
    p_layers.set_defaults(func=cmd_layers)

    # diff
    p_diff = subparsers.add_parser("diff", help="Fail only on new violations vs baseline.")
    p_diff.add_argument("--baseline", required=True, help="Baseline JSON from 'layers --json'")
    p_diff.add_argument("--package", action="append", help="Top-level package (repeatable)")
    p_diff.add_argument("--layer", action="append", type=_parse_layer, required=True, help="Layer (high -> low), comma for siblings")
    p_diff.add_argument("--container", action="append", help="Container packages (repeatable)")
    p_diff.add_argument("--include-external", action="store_true", help="Include external packages")
    p_diff.add_argument("--max-show", type=_positive_int, default=25, help="Max new violations to show (default: 25)")
    p_diff.set_defaults(func=cmd_diff)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
