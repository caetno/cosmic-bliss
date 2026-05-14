# Cosmic Bliss — Top-level Conventions

Monorepo containing a Godot 4.6 game (Cosmic Bliss) and its supporting GDExtensions.

## Systems

| Name | Role | Language mix |
|---|---|---|
| **Cosmic Bliss** | The game | GDScript, resources, scenes |
| **TentacleTech** | PBD tentacle physics, orifices, collision, stimulus bus | C++ core (PBD hot path) + GDScript glue |
| **Tenticles** | GPU particle system (NGP-style) | C++ core (RenderingDevice-driven, no GDScript hot path possible) |
| **Marionette** | Active ragdoll solver (SPD), cost-weighted IK composer | C++ core (SPD, composer, IK, strain, engagement) + GDScript glue (resources, authoring-time solvers, gizmos, editor tooling) |
| **Reverie** | Reaction system, state / mindset, attention. Publishes dimensional state + vocal-intent events; consumed by Sonance and Visage. | GDScript (future) |
| **Sonance** | Audio synthesis. Voice (sample-bank-with-modulation by default; per-region procedural modules as stretch graduations) + physics-driven non-vocal sound (modal contact, Dahl friction, Minnaert bubble, reed-tube). Subscribes to Reverie state + TentacleTech bus events. | C++ core (audio thread DSP, sample modulation, motor-state publishing) + GDScript glue (sample tagger, breath-bed editor, episode-arc editor, vocal profiles) |
| **Visage** | Facial expression, eye gaze, lip sync. Authors blendshape weights + bone-target jaw/lip-ring offsets to Marionette's IK composer and TentacleTech's rim rest-position offsets (peer-author pattern). Subscribes to Reverie emotional state + Sonance's path-agnostic motor channel. | C++ core (gaze IK, viseme math) + GDScript glue (face puppet editor, posture pattern resources) |
| **dpg** | Legacy DPG port (broken) — kept as reference for spline math salvage | Being phased out |

## Repository layout

- `extensions/<n>/` — GDExtensions, each independently buildable
- `game/` — Godot project; compiled extensions drop into `game/addons/<n>/`
- `docs/architecture/` — canonical design docs. **Read before structural changes.**
- `tools/` — build and utility scripts
- `godot-cpp/` — submodule; tracks `master` (4.6 branch not yet published)

## C++/GDScript split philosophy

There is no global default. Pick the language that fits the layer:

**C++** for the subsystem's solver / hot path / low-level core. Reach for C++ when any of these hold:
- Runs at physics-tick rate (60+ Hz) with nontrivial per-tick cost
- Math-heavy inner loops — PBD iterations, collision projection, SPD, spline evaluation, constraint solves, SDF queries
- Directly drives `RenderingDevice` or other low-level APIs
- **Lives inside a subsystem whose solver / math core is already C++.** Splitting a single subsystem across languages costs cross-boundary plumbing (GDScript→C++ marshalling, parallel data structures, two debug surfaces) that easily outweighs the per-tick cost savings of GDScript. If TentacleTech's PBD solver is C++, a new PBD chain inside TentacleTech is also C++ even when the per-tick load is light. Pick one side of the boundary per subsystem and stay there.

**GDScript** for everything that wraps, configures, or reacts to the core: AI, behavior, scenarios, control plumbing, stimulus consumption, reactions, editor tooling, mesh generation, configuration resources, authoring-time solvers, gizmos. These are not hot, they iterate often, and the compile-edit cycle of C++ would dominate.

The compile-edit cycle is a real cost — don't push GDScript-shaped work into C++. But don't fragment a coherent subsystem across two languages to dodge that cost either; the seam is worse than the rebuild.

## Cross-extension rules

- Extensions do not `#include` each other's internal headers
- Shared types go in `extensions/shared/include/`
- Communication between extensions uses:
  1. Signals / resources / nodes in the scene tree
  2. The **Stimulus Bus** (TentacleTech autoload) for physics state, events, and modulation
  3. The **`Marionette.body_rhythm_phase` shared clock** for body↔tentacle rhythm coupling (Reverie writes `body_rhythm_frequency`; TentacleTech `RhythmSyncedProbe` reads `body_rhythm_phase`). Phase is integrated, never recomputed. See `docs/marionette/Marionette_plan.md` P7.10 and `docs/architecture/TentacleTech_Architecture.md` §6.11.
  4. GDScript interfaces; never C++ coupling
- **Tenticles does not subscribe to the Stimulus Bus.** User-level GDScript glue reads the bus and writes Tenticles' public params; Tenticles stays self-contained per its scope boundary.
- **`body_field` is a fidelity upgrade, not a dependency.** No extension may require `body_field` for correct function. Every body_field consumer must have a tested fallback path that runs when the hero scene has no `BodyField` node — i.e. TentacleTech contact falls back to `BoneCollisionProfile` capsules, Marionette §15 jiggle stays on the render-mesh additive-offset path, Marionette §17 consumers keep their pre-§17 manual-authoring path, Reverie modulation channels that target body_field-only fields are no-ops. The kasumi-without-body_field smoke test gates body_field-touching PRs. See `docs/Cosmic_Bliss_Update_2026-05-14_body_field_optionality_and_dispatch.md`.

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
- **`docs/Eye_Shader.md`** — single-layer Godot port of HDRP eye shader. Cross-cutting decisions, calibration steps, gotchas (NORMAL_MAP corruption fix, iris-bumps-not-via-NORMAL, SSS off, hard-cut surface mask). Source files at `game/assets/materials/eye/`.

These three architecture docs supersede all prior design documents. If older fragmented docs (main plan, interaction detail, collision-and-friction, authoring/girth/multi, scenarios-and-AI-model, narrative scenarios, stimulus bus, reaction-to-physics-feedback) are found, they are obsolete and should be ignored or deleted.

Design updates that amend the canonical docs live in `docs/Cosmic_Bliss_Update_*.md`. Once applied to the target files, they remain as changelog.

## Working style

- **Plan before large changes.** Read relevant architecture docs first.
- **Short answers for short questions.** Don't pad responses.
- **Flag bad patterns when noticed,** even if not asked. Coordinate space bugs, per-frame material allocation, MeshDataTool in hot paths, etc.
- **Soft physics over scripted levers.** If a behavior can't be expressed via stiffness, friction, grip, damage thresholds, or modulation channels, the fix is the physics — not a boolean reject or an angle gate. Stopgap levers, when they must exist, are flagged as such and retire when the underlying geometry / stiffness model catches up. Boolean rejects in particular get used everywhere a designer doesn't want to tune the physics; do not introduce them. (Established in `TentacleTech_Architecture.md §1`; cross-cutting because the same temptation will appear in Reverie reaction profiles and Marionette overlay logic.)
- **Test scenes need explicit confirmation, and stay simple.** A *simple* test scene is a small node tree plus scripts plus minimal `@export` properties — nothing else. **Do not** add animation tracks, `AnimationPlayer`/`AnimationTree` setups, baked lighting, multi-resource asset pipelines, custom `Resource` files authored on the side, or rigged characters. If anything beyond "node tree + scripts + a few exported numbers" seems necessary, ask first. Past failure mode: an agent helpfully built out animation/resource scaffolding the user didn't want and then hand-cleanup was painful — so the bar is low-effort scenes only, after the user OKs them.
- **Do not write GDScript as C++ string literals** or vice versa. If a feature crosses the boundary, think about which side it belongs on.

## Never

- MeshDataTool in hot paths
- Per-frame `ShaderMaterial` allocation
- Per-frame `ArrayMesh` rebuilds
- Godot's `SoftBody3D` for anything in this project
- SSBOs in spatial shaders (4.6 still doesn't support this — use RGBA32F data textures)
- Querying `Node3D::get_global_transform()` from inside an `_integrate_forces` callback or PBD iteration loop — snapshot once per substep at the substep boundary
- Generating Godot test scenes without explicit permission, OR scenes containing animation tracks, baked lighting, custom Resource files, or rigged characters even with permission (those still require a separate explicit ask)
