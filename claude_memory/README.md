# Claude Memory Snapshot (auto-memory backup)

Snapshot of the Claude Code auto-memory state for this project. Mirrored from the local Claude install so the memory survives a fresh-machine recovery alongside the rest of the repo.

## Why this exists

Claude Code's auto-memory lives **outside** the project tree, at:

```
~/.claude/projects/<hashed-project-path>/memory/
```

For this repo specifically:

```
~/.claude/projects/-home-caetano-desktop-cosmic-bliss/memory/
```

If the local machine is wiped, that directory is gone — and with it every `feedback_*.md`, `project_*.md`, `reference_*.md` that previous Claude sessions accumulated. Periodically copying those files into the repo as a tracked snapshot lets a fresh checkout restore the memory state.

## Layout

```
claude_memory/
├── README.md               # this file
└── snapshot/               # mirror of the live auto-memory dir
    ├── MEMORY.md           # the index loaded into every Claude conversation
    ├── feedback_*.md       # behavior corrections / confirmations from past sessions
    ├── project_*.md        # project state (active phase, open questions, decisions)
    └── reference_*.md      # reusable Godot / Unity / engine gotchas and tooling notes
```

The naming convention and frontmatter format inside `snapshot/` matches the live auto-memory directory exactly — files in `snapshot/` ARE snapshots of files in the live one. The README sits *outside* `snapshot/` so the sync script's `--delete` semantics never wipe it.

## How to update the snapshot

Run from the repo root:

```bash
./tools/sync_claude_memory.sh
```

That script copies the live auto-memory directory into `claude_memory/snapshot/` with `--delete` semantics, so additions, edits, and *deletions* in live memory all flow into the snapshot.

Run it before committing if memory was edited during the session. The next commit picks up the changes.

## How to restore on a new machine

After cloning the repo:

```bash
mkdir -p ~/.claude/projects/-home-caetano-desktop-cosmic-bliss/memory
cp claude_memory/snapshot/*.md ~/.claude/projects/-home-caetano-desktop-cosmic-bliss/memory/
```

The hashed-path directory under `~/.claude/projects/` is generated from the project's absolute path. If the project is checked out to a different absolute path on the new machine, the hash differs and the directory name will differ. Locate the new directory under `~/.claude/projects/` and copy in there.

The simplest reliable recipe: clone to the same absolute path the original session used (`/home/<user>/desktop/cosmic-bliss/` here), then the hash matches by construction.

## What this is not

- **Not the live memory.** The live one at `~/.claude/projects/.../memory/` is what Claude reads/writes during sessions. This is a periodic backup.
- **Not auto-synced.** A session that only edits live memory does not update the snapshot. The user (or a pre-commit hook, if added) must run the sync script.
- **Not the project's CLAUDE.md / instruction files.** Those live in the repo's working tree (`/CLAUDE.md`, `extensions/*/CLAUDE.md`) and are tracked normally. Memory is a different artifact — point-in-time observations from past sessions, not project-wide instructions.
