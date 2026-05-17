# Godot engine docs — local clone

A shallow clone of the official Godot engine documentation is available locally
at `docs/godot-docs/` (not tracked — see `.gitignore`). Cloned from the
[`4.6` branch](https://github.com/godotengine/godot-docs/tree/4.6) to match the
engine version pinned in `version.txt`.

## Why local

- Avoids repeated `WebFetch` round-trips when answering Godot API / shader /
  scene-system questions.
- Lets `grep` / `find` work across the full doc tree.
- Pinned to the same Godot version as the project — no drift to `master` /
  unreleased features.

## Layout (top-level dirs)

- `classes/` — per-class API reference (RST), one file per class
  (e.g. `class_skeleton3d.rst`, `class_renderingdevice.rst`,
  `class_physicaldirectbodystate3d.rst`).
- `tutorials/` — concept guides (physics, shaders, GDExtension, etc.).
- `getting_started/` — onboarding flow.
- `engine_details/` — engine-internals deep dives.
- `_styleguides/` — RST style guide (not consumption material).

## Refreshing

The clone is a single-branch, depth-1 snapshot. To pick up new commits on the
`4.6` branch later:

```
git -C docs/godot-docs fetch --depth 1 origin 4.6
git -C docs/godot-docs reset --hard origin/4.6
```

(Re-cloning is also fine — the dir is gitignored, no project state lives in it.)

## Version

Branch: `4.6`. Cloned commit: `b10b7ed Merge pull request #11966 from
mhilbrunner/4.6-cherrypicks` (2026-05-17 snapshot). Re-fetch to get newer.
