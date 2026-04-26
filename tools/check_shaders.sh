#!/usr/bin/env bash
# Headless shader-parse check. Loads each shader file via ResourceLoader and
# fails fast on any parse error. Use this without standing up a test scene —
# spatial shader parse errors only surface at load time anyway.
#
# Usage:
#   ./tools/check_shaders.sh
#
# Exits non-zero if any shader fails to load.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GAME_DIR="$REPO_ROOT/game"

if ! command -v godot >/dev/null 2>&1; then
    echo "error: 'godot' not in PATH" >&2
    exit 2
fi

godot --path "$GAME_DIR" --headless --quit-after 1 \
    --script res://tests/tentacletech/_load_shaders.gd
