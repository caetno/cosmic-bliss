# TentacleTech

PBD-based tentacle physics with orifice interaction, collision, friction, GPU-skinned mesh deformation, and a bidirectional stimulus bus for reaction-system integration.

## Architectural docs (read before implementation)

Located in `../../docs/architecture/`:

1. **`TentacleTech_Architecture.md`** — complete technical specification. Single source of truth. Read this first and refer back to it throughout. Covers PBD core, all 7 collision types with unified friction, orifice system (rim particle loops with XPBD constraints, multi-tentacle, multi-loop per orifice, bilateral compliance), jaw special case, bulger system with jiggle, stimulus bus, mechanical sound, authoring, file structure, phase plan, gotchas.
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
- Orifice system: closed-loop rim of N PBD particles per loop (multi-loop per orifice supported — outer/inner/jewelry/multi-sphincter), XPBD distance constraints around the loop, XPBD volume constraint on enclosed area, per-particle spring-back to authored rest position. Bilateral compliance is per-particle stiffness distribution. EntryInteraction with persistent hysteretic state, multi-tentacle support (cap 3). See `docs/Cosmic_Bliss_Update_2026-05-03_orifice_rim_model.md` for the model rationale.
- Jaw orifice: hinge joint dynamics with muscular closure, hard anatomical limit, `jaw_relaxation` modulation
- Bulger system: capsule uniform arrays (max 64; `bulgers_a[64]` + `bulgers_b[64]`), spring-damper per bulger, priority tiers (Storage / Internal / Transient), both internal (penetration) and external (contact) sources
- GPU spline-skinning vertex shader with 3-layer deformation stack (mesh detail × girth_scale × asymmetry)
- Auto-baked girth texture from mesh geometry (no manual Curve authoring)
- Stimulus Bus: events (ring buffer), continuous channels, modulation channels (bidirectional)
- Body area abstraction (20–30 regions per hero, not per-bone)
- Mechanical sound emission (physics-driven, not character voice)
- Fluid strand spawning on separation
- Storage chains, oviposition, birthing (§6.8–6.9)
- Transient `ContractionPulse` primitive with named pattern emitters (orgasm, gag reflex, pain expulsion, refusal spasm, knot engulf — §6.10), autonomous `appetite` — contributions land additively in the canal `muscle[s,θ]` field per §6.12.4
- `RhythmSyncedProbe` modifier on `Tentacle` — locks tip drive to `Marionette.body_rhythm_phase` (§6.11; see Marionette P7.10)
- **Canal interior model (§6.12, opened 2026-05-04):** 2D `tunnel_state` RGBA32F texture per canal (CPU-integrated, GPU-uploaded each tick, indexed by `(arc_length_sample, angular_sector)`) + centerline particle chain (M PBD particles, default 12, anchored at orifice Centers or `<Canal>_TerminalPin`). Per-cell channels: `dynamic_wall_radius`, `plastic_offset`, `damage`, configurable fourth slot (`wall_radial_velocity` for second-order ringing, or `friction_mult`). Hierarchical activation skips integration for inactive canals (no EI, no storage, no muscle modulation).
- **Constriction zones replace per-feature rim loops along canal axes.** A zone is pure data on `CanalParameters` (`arc_length_s`, `half_width`, `max_contraction`, `current_strength`, `friction_bonus`, `baked_at_rest`). Many zones cost essentially nothing.
- **Muscle activation field `muscle[s,θ]`** is the canonical Reverie modulation primitive for canal interior; legacy `peristalsis_*` channels are sugar that synthesizes a sinusoidal contribution.
- **Active muscular curl** (per-centerline-particle `muscular_curl_delta`) is the canonical Reverie modulation primitive for canal *bend*, independent of radial squeeze.
- **Canal interior verts (`CUSTOM0.r ≥ 1`) carry no skin weights.** Per-vert bake `(s, θ, rest_radius, rest_outward_normal)` in `CUSTOM1` + `CUSTOM2` replaces them; vertex shader routes via the simulation pipeline (deformed centerline + `tunnel_state` texture sample).
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

Authoritative phase plan: `TentacleTech_Architecture.md` §13. Per-slice history + current focus: `PHASE_LOG.md` — do not inline changelog content here.

| Phase | State |
|---|---|
| 1 — Spline primitives | done |
| 2 — PBD core | done |
| 3 — Mesh rendering | done |
| 4 — Collision | done — through 4S.3 (2026-05-12) |
| 5 — Orifice | done — 5A–5D + 5H (2026-05-04..05); 5E/5F/5G canal interior next gate |
| 6 — Stimulus bus | blocked |
| 7 / 7.5 — Bulgers + capsules + x-ray | blocked |
| 8 — Multi-tentacle, advanced | blocked |
| 9 — Polish | blocked |

Always re-read §13 before starting — this table can drift; the architecture doc is the source of truth.

## Workflow

You are a sub-Claude scoped to this extension. The repo's top-level Claude (started in `../..` at the repo root) holds cross-cutting context — architecture, build system, doc consistency, contracts between extensions.

- **Implementation lives here.** You do the C++/GDScript work in `extensions/tentacletech/`.
- **Reviews live up there.** When you finish a phase or a logical milestone, report back with: build artifact path, test pass count, files touched, any divergence from the spec. Do not self-grade — the user bounces up to the top-level Claude for review.
- **Build and run tests before declaring done.** `./tools/build.sh tentacletech` from repo root, then headless tests per the Testing section. Append a tail of test output and the resulting `.so` size to your final report. Do not skip.
- **Append to PHASE_LOG.md when declaring a phase or slice done.** Flip the matching row in the Status table at the top of this file to **done** (state column only — no Notes cell), and append a dated entry to `PHASE_LOG.md` with deliverables (class names, test file paths + pass counts), spec divergences, and deferred items. PHASE_LOG.md is the project's per-slice history — sub-Claude reads it when working on a phase or investigating regressions, not on every session start. Keep CLAUDE.md prose stable across phases.
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
- **Per-rim-particle quantities use `_per_loop_k[l][k]`** where `l` is loop index and `k` is rim particle index (canonical, established in §6.2 after the 2026-05-03 amendment). The `_per_dir[d]` and `_per_ring[r]` indexing schemes from earlier drafts are retired; do not reintroduce them. **This indexing applies only to orifice rim loops.** Canal interior quantities use `_per_cell_kj[k][j]` indexing on the 2D `tunnel_state` texture (k = axial cell, j = angular sector) and `_per_centerline[m]` for the centerline particle chain (§6.12).
- **Vertex shader displacement path splits at the canal_id boundary.** Body skin verts (`CUSTOM0.r == 0`) read the bulger uniform array via the §7.1 inner loop. Canal interior verts (`CUSTOM0.r ≥ 1`) read the canal's `tunnel_state` texture + deformed centerline via the §6.12.5 sampling block; no bulger loop. The texture already incorporates bulger contributions via CPU integration — a single texelFetch per canal vert. Do not loop bulgers on canal interior verts.
- **Axial-wedge math uses the normalized form** `-p × drds_outward / sqrt(1 + drds_outward²)` (= `-p × sin θ`), not `tan(local_taper)` and not the unnormalized `-p × drds_outward` linearization. The normalized form is bounded by `p` at near-vertical flanges; the others blow up at exactly the geometry that matters most. `drds_outward` is gradient w.r.t. distance traveled along `+entry_axis`, derived from intrinsic `dr/ds` by the sign of `dot(t_hat, entry_axis)` (§6.3).
- **Type-2 friction reciprocals do NOT route per-particle to a ragdoll bone.** They sum into `EI.tangential_friction_per_loop_k[l][k]` (§6.2) and the §6.3 reaction-on-host-bone pass routes them to `host_bone` per rim particle. Type-1 routing rule (§4.3) does not apply to type-2 contacts.
- **`ContractionPulse` is atomic.** No `count`, no `interval`. Repeating patterns are sugar at the emitter level — patterns queue lists of atomic pulses; the per-tick code never sees `count` or `interval` (§6.10).
- **`body_rhythm_phase` lives on `Marionette`** (P7.10), not on `Tentacle`. `RhythmSyncedProbe` reads it via the configured `marionette_path` and never integrates its own clock.
- **Type-1 / type-2 / type-4 contact threshold = `smooth_girth + sample_feature_silhouette(s, θ)`** (slice 5H, 2026-05-05). The 2D feature silhouette image (256 axial × 16 angular R32F) is the canonical source of feature-driven radial perturbation. Smooth girth is `collision_radius × girth_scale`; the silhouette is the additive layer for warts, knots, ribs (negative), suckers (broad-positive + narrow-negative), spines, fins. Type-3 (canal walls, slice 5F) wires the same sampler. Do NOT bypass the silhouette by writing to `rest_girth_texture` or `particle.girth_scale`; the smooth girth path is for volume preservation only.
- **Body collision-layer partition is unconditional; no per-particle dispatch table.** TT particles probe against `LAYER_BODY_PROXY | LAYER_BODY_CAPSULES_DETAIL | LAYER_BODY_CAPSULES_FULL | LAYER_WORLD` on every `get_rest_info`, regardless of region or `BodyField` presence. `body_field`'s tet body (when present) occupies `LAYER_BODY_PROXY`. `BoneCollisionProfile` capsules occupy `LAYER_BODY_CAPSULES_DETAIL` (hands and feet only) when a `BodyField` node is on the hero, or `LAYER_BODY_CAPSULES_FULL` (the entire skeleton, as today) when it is absent. The activation switch is one boolean at hero-init (`hero.has_node("BodyField")`); TT itself does not branch on it. body_field-absent heroes naturally fall through to the full-capsule path because `_PROXY` + `_DETAIL` are empty — bit-for-bit equivalent to the pre-body_field baseline. Reciprocal-impulse routing then keys on which layer produced the hit: `LAYER_BODY_PROXY` hits go through `BodyField::receive_external_impulse(contact_point, impulse)` for weighted skin-bone redistribution; `LAYER_BODY_CAPSULES_*` hits route directly via `PhysicsServer3D::body_apply_impulse` on the capsule's body RID. Canonical wording lives in `docs/architecture/TentacleTech_Architecture.md` §4.2 + `docs/Cosmic_Bliss_Update_2026-05-14_body_field_optionality_and_dispatch.md` §3.1. Do NOT introduce a per-particle / per-region dispatch table or a region enum at runtime; the 05-13 "two parallel paths" framing was retired in PR #9.

## What not to do

- Do not generate Godot test scenes without explicit user confirmation. Even with confirmation, keep them simple: node tree + scripts + a few `@export` numbers. No animation tracks, no `AnimationPlayer`/`AnimationTree` setups, no baked lighting, no multi-resource asset pipelines, no rigged characters. If anything beyond that seems necessary, ask before creating it. (Background: past failure mode was agents helpfully scaffolding out animation/resource setups the user then had to hand-clean.)
- Do not use `MeshDataTool` in hot paths.
- Do not use Godot's `SoftBody3D`.
- Do not use `MultiMesh` for tentacle instancing (each needs a unique deforming mesh).
- **Do not paint skin weights on canal interior verts (`CUSTOM0.r ≥ 1`).** The canal_id-tagged path is exclusive — these verts are simulation-driven (deformed centerline + `tunnel_state` texture sample), not bone-driven. The AutoBaker writes `(s, θ, rest_radius, normal)` into `CUSTOM1`/`CUSTOM2` at scene init; that replaces traditional skinning entirely. Painting weights silently breaks the routing.
- **Do not procedurally generate canal mesh geometry.** Canals are hand-modeled in Blender; static features (haustra, taeniae, valves, columns) are baked into the modeled mesh. The runtime starts from the modeled rest pose and deforms via §6.12 — it never reshapes the topology.
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
