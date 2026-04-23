#!/usr/bin/env bash
# Build every extension in extensions/ (skips shared/ and dpg/).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO_ROOT/tools/build.sh"

SKIP=("shared" "dpg")

for dir in "$REPO_ROOT/extensions"/*/; do
    name="$(basename "$dir")"
    skip=false
    for s in "${SKIP[@]}"; do
        if [[ "$name" == "$s" ]]; then skip=true; break; fi
    done
    $skip && { echo "skip: $name"; continue; }
    "$BUILD" "$name" "$@"
done
