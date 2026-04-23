# Cosmic Bliss

Godot 4.6 game monorepo. C++ GDExtensions live under `extensions/`, the Godot
project lives in `game/`, and compiled extension output drops into
`game/addons/<name>/`.

See `CLAUDE.md` for top-level conventions and `Repo_Structure.md` for the full
directory layout.

## Build

```
./tools/build.sh <extension>     # one extension
./tools/build_all.sh             # everything
```

Pinned Godot version in `version.txt`. `godot-cpp/` submodule is pinned to the
matching branch.
