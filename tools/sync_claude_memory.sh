#!/usr/bin/env bash
# Sync Claude Code auto-memory into the repo snapshot at claude_memory/.
# See claude_memory/README.md for why this exists and the restore recipe.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${HOME}/.claude/projects/-home-caetano-desktop-cosmic-bliss/memory"
DST="${REPO_ROOT}/claude_memory"

if [[ ! -d "${SRC}" ]]; then
    echo "ERROR: live memory dir not found at ${SRC}" >&2
    exit 1
fi

mkdir -p "${DST}"

# Mirror SRC → DST/snapshot/. We use a subdirectory so the snapshot's own
# README.md (which lives at DST/README.md, outside the subdirectory) is not
# at risk from rsync --delete.
rsync -av --delete --include='*.md' --exclude='*' \
    "${SRC}/" "${DST}/snapshot/"

echo "Memory sync complete. Run 'git status claude_memory/' to see changes."
