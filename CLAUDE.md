# Cosmic Bliss — Top-level Conventions

Monorepo containing a Godot 4.6 game (Cosmic Bliss) and its supporting GDExtensions.

## Systems

| Name | Role | Language mix |
|---|---|---|
| **Cosmic Bliss** | The game | GDScript, resources, scenes |
| **TentacleTech** | PBD tentacle physics, orifices, collision, stimulus bus | C++ core (PBD hot path) + GDScript glue |
| **Tenticles** | GPU particle system (NGP-style) | C++ core (RenderingDevice-driven, no GDScript hot path possible) |
| **Marionette** | Active ragdoll solver (SPD) | GDScript (SPD hot-path C++ port held in reserve — triggered only by profiling evidence at realistic character count) |
| **Reverie** | Reaction system, facial rig, state/mindset, expressions | GDScript (future) |
| **dpg** | Legacy DPG port (broken) — kept as reference for spline math salvage | Being phased out |

## Repository layout

- `extensions/<n>/` — GDExtensions, each independently buildable
- `game/` — Godot project; compiled extensions drop into `game/addons/<n>/`
- `docs/architecture/` — canonical design docs. **Read before structural changes.**
- `tools/` — build and utility scripts
- `godot-cpp/` — submodule; tracks `master` (4.6 branch not yet published)

## C++/GDScript split philosophy

**Default to GDScript.** Move code to C++ only when:
- It runs at physics-tick rate (60+ Hz) with nontrivial per-tick cost, or
- It involves math-heavy inner loops (PBD iterations, collision projection, spline evaluation), or
- It directly interacts with `RenderingDevice` or other low-level APIs

Everything else — AI, behavior, scenarios, control plumbing, stimulus consumption, reactions, editor tooling, mesh generation, configuration resources — stays in GDScript. The compile-edit cycle is a real cost; keep the C++ surface small.

## Cross-extension rules

- Extensions do not `#include` each other's internal headers
- Shared types go in `extensions/shared/include/`
- Communication between extensions uses:
  1. Signals / resources / nodes in the scene tree
  2. The **Stimulus Bus** (TentacleTech autoload) for physics state, events, and modulation
  3. GDScript interfaces; never C++ coupling

## Build

- One extension: `./tools/build.sh <n>`
- All: `./tools/build_all.sh`
- Output: compiled `.so` into `game/addons/<n>/bin/`, GDScript and shaders copied alongside

During GDScript iteration, symlink `extensions/<n>/gdscript/` → `game/addons/<n>/scripts/` to avoid rebuild for .gd changes.

## Godot version

- **4.6**. godot-cpp submodule tracks `master` — godot-cpp has not published a `4.6` branch yet, so master is the closest-to-4.6 surface available.
- `version.txt` at repo root records expected version.
- The submodule is pinned to a specific commit (the gitlink); **do not run `git submodule update --remote`** without intent — master moves and can silently break the build.
- When godot-cpp publishes a `4.6` branch, switch with `git submodule set-branch -b 4.6 godot-cpp && cd godot-cpp && git fetch && git checkout 4.6 && git pull`, then commit the new gitlink.
- On engine upgrade: bump `version.txt`, update godot-cpp branch, rebuild all extensions.

## Canonical documentation

Three docs in `docs/architecture/`, in reading order for TentacleTech work:

1. **`TentacleTech_Architecture.md`** — complete technical specification. Single source of truth.
2. **`TentacleTech_Scenarios.md`** — AI model + narrative scenarios (acceptance tests).
3. **`Reverie_Planning.md`** — forward-looking notes for the future reaction extension. Not for implementation yet, but defines the bus interface contract.

Per-extension plans live alongside the architecture docs: `docs/tenticles/Tenticles_design.md`, `docs/marionette/Marionette_plan.md`.

Game-layer design docs live in `docs/` (not owned by any extension):

- **`docs/Camera_Input.md`** — third-person orbit camera, controller-first input scheme, player-as-disembodied-observer.
- **`docs/Appearance.md`** — hero customization, dissolve-shader clothing, decal accumulator. Game-layer `Appearance` system; no cloth physics.
- **`docs/Save_Persistence.md`** — single-save-per-profile schema, versioned with migrations. Persists mindset + appearance + currency + unlocks + stats.
- **`docs/Gameplay_Loop.md`** — committed gameplay decisions (persistent mindset, no fail state, single-type currency, roguelite under consideration). Loop design deliberately deferred until the four extensions stabilize.
- **`docs/Gameplay_Mechanics.md`** — skill surface on top of physics (grip-break timing, rib resonance, wedge reading, overwhelm management, pain-pleasure edge), hidden-phenomenon achievements, sensitivity-map discovery, tentacle loadout.

These three architecture docs supersede all prior design documents. If older fragmented docs (main plan, interaction detail, collision-and-friction, authoring/girth/multi, scenarios-and-AI-model, narrative scenarios, stimulus bus, reaction-to-physics-feedback) are found, they are obsolete and should be ignored or deleted.

Design updates that amend the canonical docs live in `docs/Cosmic_Bliss_Update_*.md`. Once applied to the target files, they remain as changelog.

## Working style

- **Plan before large changes.** Read relevant architecture docs first.
- **Short answers for short questions.** Don't pad responses.
- **Flag bad patterns when noticed,** even if not asked. Coordinate space bugs, per-frame material allocation, MeshDataTool in hot paths, etc.
- **Test scenes need explicit confirmation, and stay simple.** A *simple* test scene is a small node tree plus scripts plus minimal `@export` properties — nothing else. **Do not** add animation tracks, `AnimationPlayer`/`AnimationTree` setups, baked lighting, multi-resource asset pipelines, custom `Resource` files authored on the side, or rigged characters. If anything beyond "node tree + scripts + a few exported numbers" seems necessary, ask first. Past failure mode: an agent helpfully built out animation/resource scaffolding the user didn't want and then hand-cleanup was painful — so the bar is low-effort scenes only, after the user OKs them.
- **Do not write GDScript as C++ string literals** or vice versa. If a feature crosses the boundary, think about which side it belongs on.

## Never

- MeshDataTool in hot paths
- Per-frame `ShaderMaterial` allocation
- Per-frame `ArrayMesh` rebuilds
- Godot's `SoftBody3D` for anything in this project
- SSBOs in spatial shaders (4.6 still doesn't support this — use RGBA32F data textures)
- Querying `PhysicalBone3D.global_transform` during PBD iterations (snapshot once per tick)
- Generating Godot test scenes without explicit permission, OR scenes containing animation tracks, baked lighting, custom Resource files, or rigged characters even with permission (those still require a separate explicit ask)
