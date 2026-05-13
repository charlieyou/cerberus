#!/usr/bin/env sh
set -eu

usage() {
    cat <<'EOF'
Usage: scripts/update-plugins.sh [--ref REF] [--claude] [--codex]

Refresh local Cerberus plugin installs from a committed git ref.

Defaults:
  --ref HEAD
  update both Claude Code and Codex plugin caches

Examples:
  scripts/update-plugins.sh
  scripts/update-plugins.sh --ref rebuild
  scripts/update-plugins.sh --claude
EOF
}

ref=HEAD
update_claude=0
update_codex=0
explicit_host=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --ref)
            [ "$#" -ge 2 ] || { echo "update-plugins: --ref requires a value" >&2; exit 2; }
            ref=$2
            shift 2
            ;;
        --claude)
            update_claude=1
            explicit_host=1
            shift
            ;;
        --codex)
            update_codex=1
            explicit_host=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "update-plugins: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ "$explicit_host" -eq 0 ]; then
    update_claude=1
    update_codex=1
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
commit=$(git -C "$repo_root" rev-parse --verify "$ref^{commit}")

stage=$(mktemp -d "${TMPDIR:-/tmp}/cerberus-plugin.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM

git -C "$repo_root" archive "$commit" | tar -x -C "$stage"
make -C "$stage" build >/dev/null

install_one() {
    dest=$1
    parent=$(dirname -- "$dest")
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/cerberus-install.XXXXXX")

    cp -R "$stage/." "$tmp/"
    mkdir -p "$parent"
    rm -rf "$dest"
    mv "$tmp" "$dest"
    echo "updated $dest from $commit"
}

if [ "$update_claude" -eq 1 ]; then
    install_one "$HOME/.claude/plugins/cache/cerberus/cerberus/2.0.10"
fi

if [ "$update_codex" -eq 1 ]; then
    install_one "$HOME/.codex/plugins/cache/cerberus/cerberus/2.0.10"
fi
