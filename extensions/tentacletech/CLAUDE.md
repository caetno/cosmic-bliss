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
- Per-particle state: position, prev_position, inv_mass, girth_scale, asymmetry (vec2)
- All 7 collision types with unified PBD friction cone projection
- Ragdoll snapshot (once per tick) with surface material tags
- Orifice system: 8-direction ring bones with spring-damper, EntryInteraction with persistent hysteretic state, bilateral compliance, multi-tentacle support (cap 3)
- Jaw orifice: hinge joint dynamics with muscular closure, hard anatomical limit, `jaw_relaxation` modulation
- Bulger system: uniform array (max 32), spring-damper per bulger, both internal (penetration) and external (contact) sources
- GPU spline-skinning vertex shader with 3-layer deformation stack (mesh detail × girth_scale × asymmetry)
- Auto-baked girth texture from mesh geometry (no manual Curve authoring)
- Stimulus Bus: events (ring buffer), continuous channels, modulation channels (bidirectional)
- Body area abstraction (20–30 regions per hero, not per-bone)
- Mechanical sound emission (physics-driven, not character voice)
- Fluid strand spawning on separation

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

## Phase 1 task: scavenge DPG for spline math

The broken DPG port at `../dpg/` contains the most salvageable code: Catmull-Rom spline math, arc-length LUT construction, parallel transport binormals, GPU data packing. Phase 1 is to extract and generalize this into `src/spline/`.

### Steps

1. **Read** the DPG spline code (`../dpg/src/catmull_spline.*` or equivalent) and any related GPU data packing code.
2. **Read** `TentacleTech_Architecture.md` §5 (Spline and mesh deformation) for the intended API and behavior.
3. **Identify** the reusable primitives in DPG:
   - Catmull-Rom evaluation at parameter t
   - Arc-length LUT construction + distance-to-parameter lookup
   - Parallel-transport binormal chain (not Frenet — parallel transport is critical for preventing twist)
   - GPU coefficient packing (polynomial form)
   - RGBA32F texture encoding
4. **Extract and generalize** into `src/spline/`:
   - `catmull_spline.{h,cpp}` — pure math class, control-point agnostic
     - `build_from_points(PackedVector3Array)`
     - `evaluate_position(float t)`, `evaluate_tangent(float t)`, `evaluate_frame(t, out_tan, out_norm, out_binorm)`
     - `get_arc_length()`, `parameter_to_distance(t)`, `distance_to_parameter(d)`
     - `build_distance_lut(int sample_count)`, `build_binormal_lut(int sample_count)`
   - `spline_data_packer.{h,cpp}` — standalone utility
     - `pack(spline, per_point_scalars_arrays, out_float_array)`
     - `create_texture(packed_data, width)` → `ImageTexture(FORMAT_RGBAF)`
     - Supports arbitrary per-point scalar channels (for girth_scale, asymmetry later)
5. **Do not** carry over DPG-specific type names or architecture. Use `CatmullSpline` and `SplineDataPacker` names. These are general-purpose primitives — TentacleTech uses them, future systems might too.
6. **Write the new classes fresh,** referencing DPG's math but not copy-pasting its architecture. DPG is broken; replicating its bugs is not the goal.
7. Expose to GDScript via standard GDExtension binding.

### Acceptance

- `CatmullSpline` constructs from `PackedVector3Array` in GDScript
- `evaluate_position(t)` over t=0..1 returns a smooth curve
- `get_arc_length()` returns within 0.1% of analytical arc length for a simple test curve (straight line, circle arc, helix)
- `distance_to_parameter(arc_length × 0.5)` returns the parameter that evaluates to a position at half the arc length
- `build_binormal_lut()` produces no twist on a planar S-curve (consecutive binormals differ only by rotation around tangent)
- `SplineDataPacker.pack()` round-trips losslessly: packed → float array → read back via `texelFetch` → originals within float32 precision
- User can create a test scene (user's responsibility, not yours) to draw the spline as a debug line strip and visually confirm smoothness

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

## What not to do

- Do not generate Godot test scenes. User creates these.
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

## Directory layout

```
extensions/tentacletech/
├── CLAUDE.md                  # this file
├── SConstruct
├── tentacletech.gdextension
├── src/                       # C++
│   ├── spline/                # Phase 1 — scavenge from dpg
│   │   ├── catmull_spline.{h,cpp}
│   │   └── spline_data_packer.{h,cpp}
│   ├── solver/                # Phase 2
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
│   └── procedural/
└── shaders/
    ├── tentacle.gdshader
    ├── tentacle_lib.gdshaderinc
    ├── hero_skin.gdshader
    └── girth_bake.glsl
```

Full phase plan is in `TentacleTech_Architecture.md` §13. Current focus: Phase 1.
