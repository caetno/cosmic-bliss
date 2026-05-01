# TentacleTech

PBD-based tentacle physics with orifice interaction, collision, friction, GPU-skinned mesh deformation, and a bidirectional stimulus bus for reaction-system integration.

## Architectural docs (read before implementation)

Located in `../../docs/architecture/`:

1. **`TentacleTech_Architecture.md`** — complete technical specification. Single source of truth. Read this first and refer back to it throughout. Covers PBD core, all 7 collision types with unified friction, orifice system (spring-damper ring bones, multi-tentacle, bilateral compliance), jaw special case, bulger system with jiggle, stimulus bus, mechanical sound, authoring, file structure, phase plan, gotchas.
2. **`TentacleTech_Scenarios.md`** — AI control model + 10 narrative scenarios that double as acceptance tests. Reference for behavior and validation.
3. **`Reverie_Planning.md`** — forward-looking only. Relevant for understanding what bus interface Reverie will need, so our emission format doesn't lock them out. Not for implementation.

If you find older design docs (fragmented main plan, interaction detail, collision-and-friction, etc.), they are obsolete. Use only the three above.

## Scope

### In-scope
- PBD particle solver: distance, bending, target-pull, anchor, collision, friction, attachment
- Spline math: CatmullSpline with arc-length LUT, parallel-transport binormals, GPU data packing
- Snapshot accessors and debug gizmo overlay (§15) — landed alongside the physics they describe, not deferred
- Per-particle state: position, prev_position, inv_mass, girth_scale, asymmetry (vec2)
- All 7 collision types with unified PBD friction cone projection
- Ragdoll snapshot (once per tick) with surface material tags
- Orifice system: 8-direction ring bones with spring-damper, EntryInteraction with persistent hysteretic state, bilateral compliance, multi-tentacle support (cap 3)
- Jaw orifice: hinge joint dynamics with muscular closure, hard anatomical limit, `jaw_relaxation` modulation
- Bulger system: capsule uniform arrays (max 64; `bulgers_a[64]` + `bulgers_b[64]`), spring-damper per bulger, priority tiers (Storage / Internal / Transient), both internal (penetration) and external (contact) sources
- GPU spline-skinning vertex shader with 3-layer deformation stack (mesh detail × girth_scale × asymmetry)
- Auto-baked girth texture from mesh geometry (no manual Curve authoring)
- Stimulus Bus: events (ring buffer), continuous channels, modulation channels (bidirectional)
- Body area abstraction (20–30 regions per hero, not per-bone)
- Mechanical sound emission (physics-driven, not character voice)
- Fluid strand spawning on separation
- Storage chains, oviposition, birthing (§6.8–6.9)
- Transient `ContractionPulse` primitive with named pattern emitters (orgasm, gag reflex, pain expulsion, refusal spasm, knot engulf — §6.10), autonomous `appetite`
- `RhythmSyncedProbe` modifier on `Tentacle` — locks tip drive to `Marionette.body_rhythm_phase` (§6.11; see Marionette P7.10)
- Reaction-on-host-bone closure (§6.3) — radial + axial-wedge + type-2 friction reciprocal applied to the orifice's `host_bone`; closes the third-law loop on the rim side and is what makes suspension physically realized
- `TentacleMesh` as a `PrimitiveMesh` subclass + modifier model with `Ring` / `Vertex` / `Mask` kernels (§10.2a / §10.2b)

### Out-of-scope
- Reaction system, emotion states, facial expressions → Reverie
- Active ragdoll solving (pose targets → bone motion) → Marionette
- GPU particles → Tenticles
- Procedural tentacle mesh generation runtime → lives in `gdscript/procedural/`, not C++
- High-level AI scenario decisions → GDScript (utility scorer)
- Game-specific scenario presets → `game/scripts/`
- Character voice / dialogue / vocalization → Reverie queues, audio system plays

## C++ / GDScript split

### C++ (`src/`)
- `spline/` — CatmullSpline, SplineDataPacker (generic, reusable)
- `solver/` — PBDSolver, constraints, TentacleParticle
- `collision/` — ragdoll snapshot, friction projection, spatial hash, surface materials
- `orifice/` — EntryInteraction, Orifice, JawOrifice, tunnel projector
- `bulger/` — BulgerSystem with spring-damper state
- `stimulus_bus/` — events, continuous channels, modulation state
- `register_types.{h,cpp}` — GDExtension registration

### GDScript (`gdscript/`, deployed to `game/addons/tentacletech/scripts/`)
- `behavior/` — noise layers, behavior driver, thrust trajectory
- `control/` — TentacleControl, player controller, utility scorer AI
- `scenarios/` — ScenarioPreset resources, scenario library
- `stimulus/` — mechanical sound emitter, fluid strand
- `orifice/` — setup helpers, ring weight auto-generator plugin
- `procedural/` — CSG-like tentacle mesh generator with modifier children

**Rule of thumb:** if it runs inside the 60 Hz physics tick and touches particles or constraints, it's C++. Everything else is GDScript.

## Status

Authoritative phase plan: `TentacleTech_Architecture.md` §13. State at last update:

| Phase | State | Notes |
|---|---|---|
| 1 — Spline primitives | **done** | `CatmullSpline` + `SplineDataPacker` registered, 7/7 tests pass at `game/tests/tentacletech/test_spline.gd` |
| 2 — PBD core | **done** | `TentacleParticle`, `PBDSolver`, `Tentacle` Node3D registered. 7/7 tests at `game/tests/tentacletech/test_solver.gd`. Phase-2 snapshot accessors per §15.2. Debug overlay at `gdscript/debug/` with `particles_layer.gd` + `constraints_layer.gd`. **Tracked simplification:** bending constraint is chord-only between (i, i+2); spec form (3-particle angle) deferred to Phase 9 polish. **No `dt` clamp** in `tick()` — first-frame hiccup can spike gravity, address before shipping |
| 3 — Mesh rendering | **done** | 3a: `tentacle.gdshader` + `tentacle_lib.gdshaderinc` (§5.3); per-tick `RGBA32F` spline data texture (alloc-free) on `Tentacle`; per-instance `ShaderMaterial` + auto-discovered `MeshInstance3D`; `mesh_arc_axis` + `mesh_arc_offset` properties to accept Y-up centered primitives. 3b: `TentacleMesh : Resource` (`gdscript/procedural/tentacle_mesh.gd`) with base-shape generator (linear/curve taper, twist, seam_offset, intrinsic axis −Z); `BakeContext` + `TentacleFeature` abstract base + `SuckerRowFeature` end-to-end (OneSide/TwoSide/AllAround/Spiral; rim+cup geometry; `COLOR.r` mask + `UV1` disc-space + `CUSTOM0.x` feature ID; ±5° seam validation); `GirthBaker` static utility producing 256-bin `FORMAT_RF` `ImageTexture` + `rest_length` per §5.4; full §10.2 channel layout (UV0/UV1/COLOR.rgba/CUSTOM0); shared `gdscript/debug/colors.gd` consumed by both runtime layers and the editor gizmo; `EditorPlugin` (`plugin.cfg` + `plugin.gd` + `gdscript/gizmo_plugin/tentacle_gizmo.gd`) drawing particles + segments + spline polyline + TBN frames on selection. New C++ accessors `Tentacle.set_rest_girth_texture`, `get_spline_samples(n)`, `get_spline_frames(n)`. **3c (rounded tip + geometry features, 2026-04-29):** `tip_cap_rings` + `tip_pointiness` give an ellipsoidal hemisphere cap (replaces the single-vertex apex; cap_rings=0 reverts to legacy point). `Tentacle::_apply_mesh_length_to_segment_length` now prefers `get_baked_rest_length()` so cap vertices map past the body's spline domain instead of clamping to the tip. `rebuild_chain` snapshots+re-applies `rigid_base_count` so the .tscn property survives `_ready()`. New geometry features: **KnotFieldFeature** (vertex-kernel radius bumps, Gaussian/Sharp/Asymmetric profile), **RibsFeature** (vertex-kernel inward grooves, U/V profile), **SpinesFeature** (cones with pitched apex, ALL_AROUND/ONE_SIDE/SPIRAL distribution), **RibbonFeature** (1/2/4 fin strips with width_curve + ruffle), **WartClusterFeature** (5-vert pyramids seeded by density + clustering exponent). Vertex-kernel features filter on `FEATURE_ID_BODY` so they don't perturb other features' geometry. New `BakeContext.body_surface_at(t, world_phi)` helper (rotationally symmetric — does not add seam/twist). New feature IDs: SPINE=3, RIBBON=4, WART=5. **Tests:** test_spline 7/7 + test_solver 7/7 + test_render 4/4 + test_tentacle_mesh 5/5 + test_sucker_row_feature 4/4 + test_girth_baker 2/2 + test_render_with_tentacle_mesh 4/4 + test_geometry_features 8/8 = 41/41. **§5.0 partition tag for new features:** all silhouette-defining → mesh layer. **Deferred:** mask-only features (Papillae, Photophore — fragment-shader branch not wired); tip variants beyond rounded ellipsoid (Canal, Bulb, Mouth, Flare — extension point left in place); discriminated TipFeature library; BaseFeature beyond Flush; LOD / multi-tentacle batching / mesh composition (Phase 9 polish); proper normals at knot-bump peaks (currently radial-only — small lighting error at smooth-profile peaks); editor gizmo markers for feature centers. |
| 4 — Collision | **slice 4A done** | Type-4 environment raycasts (3/tick from base/mid/tip in gravity dir) + normal-only PBD projection scaled by `particle_collision_radius * girth_scale`. Files: `src/collision/environment_probe.{h,cpp}`, `gdscript/debug/gizmo_layers/environment_layer.gd`. New solver API: `set_environment_contacts/clear_environment_contacts/set_collision_radius`. New Tentacle exports: `environment_probe_enabled`, `environment_probe_distance`, `environment_collision_layer_mask`, `particle_collision_radius`. New public `Tentacle.tick(dt)` so headless tests drive the same path as `_physics_process`. Snapshot accessor `get_environment_contacts_snapshot()`. Plan doc: `docs/Cosmic_Bliss_Update_2026-05-01_phase4_collision.md`. **Tests:** test_collision_type4 4/4 (probe emits 3 contacts, chain settles above floor, no-collider hangs free, disable clears solver state). Test scene: `game/tests/tentacletech/scenes/test_collision_type4.tscn`. **Deferred (slices 4B+):** §4.3 friction (cone projection on tangential displacement), §4.3 soft `contact_stiffness` for distance constraints, §4.4 modulator stack (rib / grip / barbed / adhesion). Type-1 ragdoll capsules + §4.5 ownership amendment + §4.6 wetness deferred to a future phase pending Marionette active ragdoll. Pre-existing 2 failures in `test_tentacle_behavior` are unrelated. |
| 5 — Orifice | blocked | |
| 6 — Stimulus bus | blocked | |
| 7 / 7.5 — Bulgers + capsules + x-ray | blocked | |
| 8 — Multi-tentacle, advanced | blocked | |
| 9 — Polish | blocked | |

Always re-read §13 before starting — this table can drift; the architecture doc is the source of truth.

## Workflow

You are a sub-Claude scoped to this extension. The repo's top-level Claude (started in `../..` at the repo root) holds cross-cutting context — architecture, build system, doc consistency, contracts between extensions.

- **Implementation lives here.** You do the C++/GDScript work in `extensions/tentacletech/`.
- **Reviews live up there.** When you finish a phase or a logical milestone, report back with: build artifact path, test pass count, files touched, any divergence from the spec. Do not self-grade — the user bounces up to the top-level Claude for review.
- **Build and run tests before declaring done.** `./tools/build.sh tentacletech` from repo root, then headless tests per the Testing section. Append a tail of test output and the resulting `.so` size to your final report. Do not skip.
- **Update the Status table at the top of this file before declaring a phase done.** Flip the row's state to **done**, replace the Notes cell with a one-line summary of key deliverables (class names, test file path + pass count, any deferred items). The table is the project's per-phase log — every future sub-Claude reads it on session start, so it must reflect reality. If you defer something, say so explicitly (`Notes: ... ; deferred: <thing>, see §X`).
- **Spec divergences require explicit flagging.** If you find a reason to diverge from the architecture doc, flag it in your report so the top-level review can update §X — do not silently change behavior.
- **Don't commit.** The user runs `git commit` at milestone boundaries after the top-level review approves. Leave changes uncommitted unless explicitly asked.
- **Don't touch other extensions.** No edits to `extensions/marionette/`, `extensions/tenticles/`, `extensions/dpg/`. If a change there is needed, raise it in the report; the top-level handles it.

## Snapshot accessors and debug gizmos

§15 of the architecture doc is non-negotiable: every phase that lands physics state also lands the snapshot accessors that gizmos and tests both consume. Naming convention: `Tentacle.get_*_snapshot()` returns by-copy; never live pointers into solver state. The debug overlay in `gdscript/debug/` reads accessors per-frame and rebuilds an `ImmediateMesh`. **Pull, never push** — the C++ solver does not know the overlay exists. No `if (debug)` in `tick()`.

## Non-negotiable rules

- **Ragdoll snapshot once per tick,** not per iteration. Reading `PhysicalBone3D.global_transform` during PBD iterations destroys performance.
- **Position-based friction** inside PBD iterations, not impulse-based between ticks.
- **No per-frame ArrayMesh rebuilds.** Ever.
- **No per-frame ShaderMaterial allocation.** Create once per tentacle instance, update uniforms.
- **Unique `ShaderMaterial` per tentacle instance;** shared `.gdshader` file.
- **Data textures (RGBA32F)** for spline data. SSBOs unavailable in spatial shaders in Godot 4.6.
- **godot-cpp at `../../godot-cpp/`**, pre-compiled. Do not rebuild.
- **Girth is auto-baked from mesh geometry,** never manually authored as a Curve.
- **Orifice holds a list of EntryInteractions,** not a single one (multi-tentacle).
- **Ring bones use spring-damper dynamics,** not direct position assignment.
- **Bulgers have spring-damper state** for both position and radius.
- **Stimulus bus is bidirectional.** Physics writes events + continuous state; Reverie writes modulation.
- **Soft physics over scripted levers** (§1 design principle, added 2026-04-27). No `accept_penetration` boolean, no `min_approach_angle_cos` gate, no per-pattern event types. If a behavior can't be expressed via stiffness, friction, grip, damage, or a modulation channel, the fix is the physics — not a hard reject. Boolean rejects in particular get used everywhere a designer doesn't want to tune the physics; do not introduce them.
- **Per-direction quantities use `_per_dir[d]`** (canonical, established in §6.2). The `_per_ring[r]` aliases used in earlier drafts are retired; do not reintroduce them.
- **Axial-wedge math uses the normalized form** `-p × drds_outward / sqrt(1 + drds_outward²)` (= `-p × sin θ`), not `tan(local_taper)` and not the unnormalized `-p × drds_outward` linearization. The normalized form is bounded by `p` at near-vertical flanges; the others blow up at exactly the geometry that matters most. `drds_outward` is gradient w.r.t. distance traveled along `+entry_axis`, derived from intrinsic `dr/ds` by the sign of `dot(t_hat, entry_axis)` (§6.3).
- **Type-2 friction reciprocals do NOT route per-particle to a ragdoll bone.** They sum into `EI.tangential_friction_per_dir[d]` (§6.2) and the §6.3 reaction-on-host-bone pass routes them to `host_bone`. Type-1 routing rule (§4.3) does not apply to type-2 contacts.
- **`ContractionPulse` is atomic.** No `count`, no `interval`. Repeating patterns are sugar at the emitter level — patterns queue lists of atomic pulses; the per-tick code never sees `count` or `interval` (§6.10).
- **`body_rhythm_phase` lives on `Marionette`** (P7.10), not on `Tentacle`. `RhythmSyncedProbe` reads it via the configured `marionette_path` and never integrates its own clock.

## What not to do

- Do not generate Godot test scenes without explicit user confirmation. Even with confirmation, keep them simple: node tree + scripts + a few `@export` numbers. No animation tracks, no `AnimationPlayer`/`AnimationTree` setups, no baked lighting, no multi-resource asset pipelines, no rigged characters. If anything beyond that seems necessary, ask before creating it. (Background: past failure mode was agents helpfully scaffolding out animation/resource setups the user then had to hand-clean.)
- Do not use `MeshDataTool` in hot paths.
- Do not use Godot's `SoftBody3D`.
- Do not use `MultiMesh` for tentacle instancing (each needs a unique deforming mesh).
- Do not try to share data structures with DPG; that code is broken and being phased out.
- Do not carry over DPG's `Penetrator`/`Penetrable` naming. TentacleTech uses `Tentacle`/`Orifice`/`EntryInteraction`.
- Do not write GDScript-equivalent features in C++ unless profiling shows a need.
- Do not implement Reverie (reaction system) functionality here — stop at the modulation channel interface.

## Build

```
cd extensions/tentacletech
scons -j$(nproc) target=template_debug
```

Output: `../../game/addons/tentacletech/bin/libtentacletech.<platform>.<target>.<arch>.<ext>`

GDScript files in `gdscript/` and shaders in `shaders/` are copied to `../../game/addons/tentacletech/scripts/` and `../../game/addons/tentacletech/shaders/` by the top-level build script.

## Testing

Headless tests live in `../../game/tests/tentacletech/`, invoked with:

```
godot --path ../../game --headless --script res://tests/tentacletech/test_<name>.gd
```

Pattern: `extends SceneTree`, run assertions in `_init()`, `quit(0)` on pass / `quit(2)` on fail. No gdUnit4 dependency.

**Gotcha: GDScript parse-time class lookup.** When invoked via `--script`, the GDScript parser resolves identifiers before GDExtension classes are registered (registration runs at `MODULE_INITIALIZATION_LEVEL_SCENE`). `CatmullSpline.new()` fails at parse time even though `ClassDB.class_exists("CatmullSpline")` returns true at runtime. Tests must instantiate via `ClassDB.instantiate("CatmullSpline")`. Static methods bound with `bind_static_method` are callable through these instances. Won't bite normal in-project usage where scripts load via scenes/preload.

## Directory layout

```
extensions/tentacletech/
├── CLAUDE.md                  # this file
├── SConstruct
├── tentacletech.gdextension
├── plugin.cfg                 # added Phase 3 — registers as EditorPlugin (§15.5)
├── plugin.gd                  # registers per-class EditorNode3DGizmoPlugins
├── src/                       # C++
│   ├── spline/                # Phase 1 ✓
│   │   ├── catmull_spline.{h,cpp}
│   │   └── spline_data_packer.{h,cpp}
│   ├── solver/                # Phase 2 ✓
│   ├── collision/             # Phase 4
│   ├── orifice/               # Phase 5
│   ├── bulger/                # Phase 7
│   ├── stimulus_bus/          # Phase 6
│   └── register_types.{h,cpp}
├── gdscript/                  # copied to game/addons/
│   ├── behavior/
│   ├── control/
│   ├── scenarios/
│   ├── stimulus/
│   ├── orifice/
│   ├── debug/                 # §15.1–4 runtime overlay — grows with each phase
│   ├── gizmo_plugin/          # §15.5 editor gizmos — added Phase 3
│   └── procedural/
└── shaders/
    ├── tentacle.gdshader
    ├── tentacle_lib.gdshaderinc
    ├── hero_skin.gdshader
    └── girth_bake.glsl
```

Full phase plan is in `TentacleTech_Architecture.md` §13. Current focus: Phase 3 (mesh rendering).
