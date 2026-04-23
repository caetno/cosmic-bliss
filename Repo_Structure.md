# Cosmic Bliss — Repo Structure (updated)

Current state of the monorepo after initial setup. Reflects the C++/GDScript split philosophy: **only math-heavy cores are GDExtension; everything else is GDScript for faster iteration.**

## Directory layout

```
cosmic-bliss/
├── .gitignore
├── CLAUDE.md                             # top-level conventions
├── README.md
├── version.txt                           # Godot version pinning
├── godot-cpp/                            # submodule (tracks master; 4.6 branch not yet published)
│
├── extensions/                           # GDExtension C++ code only
│   ├── tentacletech/                     # [NEW — to be created]
│   │   ├── CLAUDE.md
│   │   ├── SConstruct
│   │   ├── tentacletech.gdextension
│   │   ├── src/                          # C++ solver primitives
│   │   │   ├── spline/
│   │   │   ├── solver/
│   │   │   ├── collision/
│   │   │   ├── orifice/
│   │   │   └── register_types.{h,cpp}
│   │   ├── gdscript/                     # GDScript glue (deployed with addon)
│   │   │   ├── behavior/
│   │   │   ├── control/
│   │   │   ├── scenarios/
│   │   │   └── stimulus/
│   │   └── shaders/
│   │
│   ├── tenticles/                        # [EXISTS] GPU particle system, with CLAUDE.md
│   │
│   ├── marionette/                       # [EXISTS] Phase 1 in progress
│   │
│   ├── reverie/                          # [FUTURE] reaction + facial rig
│   │
│   ├── dpg/                              # [LEGACY, BROKEN] — salvage spline math only
│   │
│   └── shared/                           # cross-extension types
│       └── include/
│
├── game/                                 # Godot project
│   ├── project.godot
│   ├── addons/                           # build output lands here
│   │   ├── tentacletech/
│   │   │   ├── bin/                      # compiled .so/.dll
│   │   │   ├── scripts/                  # GDScript (copied from extensions/tentacletech/gdscript/)
│   │   │   ├── shaders/                  # shaders (copied)
│   │   │   └── tentacletech.gdextension
│   │   ├── tenticles/
│   │   ├── marionette/
│   │   └── reverie/
│   ├── scenes/                           # game scenes
│   ├── scripts/                          # game-specific glue (not part of any extension)
│   └── assets/
│
├── docs/
│   ├── architecture/                     # canonical design docs (TentacleTech, Reverie)
│   ├── tentacletech/
│   ├── tenticles/
│   ├── marionette/
│   ├── reverie/
│   ├── Camera_Input.md                   # game-layer: camera + input spec
│   ├── Appearance.md                     # game-layer: customization, dissolve shaders, decals
│   ├── Save_Persistence.md               # game-layer: save schema + migrations
│   ├── Gameplay_Loop.md                  # game-layer: loop decisions and deferrals
│   ├── Gameplay_Mechanics.md             # game-layer: skill surface, achievements, discovery, loadout
│   ├── Description.md                    # high-level project description
│   └── Cosmic_Bliss_Update_*.md          # dated design-update changelogs
│
└── tools/
    ├── build.sh                          # build one extension
    ├── build_all.sh                      # build everything
    └── test_scenes/                      # optional; user creates test scenes
```

## C++/GDScript split by extension

| Extension | C++ side | GDScript side |
|---|---|---|
| **TentacleTech** | PBD solver, collision, friction, spline math, orifice ring model, girth baking, spatial hash, GPU data texture packing, stimulus bus core | Tentacle behavior driver, noise layers, scenario presets, AI utility scorer, TentacleControl plumbing, procedural mesh generator, orifice setup helpers |
| **Tenticles** | Compute shader dispatch, particle buffer management, indirect draw, spatial hashing, density field | Emitter configuration, effect authoring, parameter curves |
| **Marionette** | *(none now — optional Phase 12: SPD math port if profiling proves need)* | Everything: SPD solver, bone pose evaluation, anatomical/joint-frame mapping, constraints, pose/cyclic/emotion resources, editor plugin |
| **Reverie** | Maybe state distribution math if profiling shows need | State/mindset model, stimulus consumption, expression selection, vocalization queue, modulation output — all GDScript |

Default to GDScript unless profiling shows a hot path. The compile-edit cycle is too valuable to give up on anything that isn't proven hot.

## Build output contract

Each extension builds by dropping its output into `game/addons/<n>/`:
- Compiled `.so`/`.dll` → `game/addons/<n>/bin/`
- GDScript files → `game/addons/<n>/scripts/` (copied from `extensions/<n>/gdscript/`)
- Shaders → `game/addons/<n>/shaders/` (copied from `extensions/<n>/shaders/`)
- `.gdextension` file → `game/addons/<n>/`

The build script handles copying. GDScript and shader changes don't require a rebuild — just re-run the build script or symlink the source folders into `game/addons/` during development for zero-copy iteration.

## What exists now vs what's pending

**Exists:**
- `extensions/tenticles/` with its CLAUDE.md
- `extensions/marionette/` with Phase 1 work
- `extensions/dpg/` (broken, keep for spline math reference)

**To create:**
- `extensions/tentacletech/` (this doc specifies its layout)
- `extensions/shared/include/` (empty for now, populated as shared types emerge)
- `extensions/reverie/` (future)
- Top-level `CLAUDE.md`, build scripts, `.gitignore`

**First implementation task (Claude Code):**
Scavenge `extensions/dpg/` for reusable spline math, then build generalized primitives in `extensions/tentacletech/src/spline/`. Details in `extensions/tentacletech/CLAUDE.md`.
