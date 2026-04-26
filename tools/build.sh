#!/usr/bin/env bash
# Build a single extension and deploy to game/addons/<name>/.
#
# Usage: ./tools/build.sh <extension-name> [scons args...]
#
# Deployment layout (per Repo_Structure.md):
#   Compiled .so/.dll  -> game/addons/<name>/bin/
#   Shaders            -> game/addons/<name>/shaders/  (from extensions/<name>/shaders/)
#   .gdextension file  -> game/addons/<name>/
#   plugin.cfg         -> game/addons/<name>/           (pure-GDScript addons)
#
# GDScript deployment depends on whether the extension has C++ (SConstruct):
#   C++ + GDScript: gdscript/  -> game/addons/<name>/scripts/
#   Pure GDScript:  gdscript/  -> game/addons/<name>/
# The flat-copy case keeps res:// paths like "res://addons/<name>/resources/..."
# working without rewriting resource files.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <extension-name> [scons args...]" >&2
    exit 2
fi

NAME="$1"
shift || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT_DIR="$REPO_ROOT/extensions/$NAME"
ADDON_DIR="$REPO_ROOT/game/addons/$NAME"

if [[ ! -d "$EXT_DIR" ]]; then
    echo "error: $EXT_DIR does not exist" >&2
    exit 1
fi

mkdir -p "$ADDON_DIR/bin" "$ADDON_DIR/shaders"

# Compile C++ if SConstruct exists.
HAS_CPP=false
if [[ -f "$EXT_DIR/SConstruct" ]]; then
    HAS_CPP=true
    (cd "$EXT_DIR" && scons "$@")
fi

# Addon manifest: .gdextension for C++, plugin.cfg for pure-GDScript or mixed
# C++/EditorPlugin addons. plugin.cfg references plugin.gd as a sibling, so
# both are copied to the addon root.
if [[ -f "$EXT_DIR/$NAME.gdextension" ]]; then
    cp "$EXT_DIR/$NAME.gdextension" "$ADDON_DIR/"
fi
if [[ -f "$EXT_DIR/plugin.cfg" ]]; then
    cp "$EXT_DIR/plugin.cfg" "$ADDON_DIR/"
fi
if [[ -f "$EXT_DIR/plugin.gd" ]]; then
    cp "$EXT_DIR/plugin.gd" "$ADDON_DIR/"
fi

# GDScript: scripts/ subdir for mixed addons, flat for pure-GDScript.
if [[ -d "$EXT_DIR/gdscript" ]]; then
    if $HAS_CPP; then
        mkdir -p "$ADDON_DIR/scripts"
        rsync -a --delete "$EXT_DIR/gdscript/" "$ADDON_DIR/scripts/"
    else
        rsync -a "$EXT_DIR/gdscript/" "$ADDON_DIR/"
    fi
fi

if [[ -d "$EXT_DIR/shaders" ]]; then
    rsync -a --delete "$EXT_DIR/shaders/" "$ADDON_DIR/shaders/"
fi

echo "built: $NAME -> $ADDON_DIR"
