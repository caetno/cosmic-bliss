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
| 4 — Collision | **4A→4L + 4M-pre + 4M + 4M-XPBD + 4N done (2026-05-03); 4O / 4P (sleep half) pending — see `docs/Cosmic_Bliss_Update_2026-05-03_phase4_wedge_robustness.md`** | **4A (2026-05-01):** Type-4 environment raycasts (3/tick gravity-dir), normal-only PBD projection. Files: `src/collision/environment_probe.{h,cpp}`, `gdscript/debug/gizmo_layers/environment_layer.gd`. **4B (2026-05-02):** §4.3 friction cone via `src/collision/friction_projection.h`; `set_friction(static, kinetic_ratio)`, per-contact `friction_applied`, Tentacle exports `base_static_friction`/`tentacle_lubricity`/`kinetic_friction_ratio`. **4C (2026-05-02):** Soft `contact_stiffness` (default 0.5) for distance segments where either endpoint flagged `in_contact_this_tick`; iteration order changed (collision before distance). Particle flag cleared in predict(), set in collision pass. New `get_particle_in_contact_snapshot()` + Tentacle export. **4D (2026-05-02):** **Replaced** the 3-ray gravity probe with per-particle `PhysicsDirectSpaceState3D::get_rest_info` sphere queries — handles arbitrary motion, all body kinds (StaticBody3D, RigidBody3D, AnimatableBody3D, PhysicalBone3D) uniformly. Probe now allocates one EnvironmentContact per particle. QUERY_BIAS=1.05 detects tangent contacts so settled chains keep `in_contact_this_tick` flagged. New API `set_environment_contacts_per_particle(points, normals, active)`. Snapshot now has one entry per particle with `particle_index`/`query_origin`/`hit`/`hit_point`/`hit_normal`/`hit_object_id`/`hit_linear_velocity`/`friction_applied`. **Spec divergence (flagged in `environment_probe.h`):** §4.2/§4.5 specify raycasts + ragdoll snapshot; per-particle queries unify type-1 + type-4 at modest cost (~12-30 queries/tentacle/tick), making the §4.5 ownership amendment unnecessary. **4E (2026-05-02):** §4.3 type-1 reciprocal — after solver tick, `Tentacle::_apply_collision_reciprocals` walks per-particle contacts and applies `friction_applied × eff_mass / dt` impulse to the colliding body via `PhysicsServer3D::body_apply_impulse(rid, impulse, hit_point - body_origin)`. Works uniformly for RigidBody3D, AnimatableBody3D, and PhysicalBone3D — heavy chain dragging across a ragdoll bone pulls the bone in the drag direction. Plan doc: `docs/Cosmic_Bliss_Update_2026-05-01_phase4_collision.md`. **4F (2026-05-02):** Collision polish + first slice of moodable solver params. New `body_impulse_scale` @export on Tentacle (then-default 0.1 — see 4G); new `pose_softness_when_blocked` on TentacleMood + TentacleBehavior (default 0.3) — driver fetches `get_particle_in_contact_snapshot()` and softens pose-target stiffness for in-contact particles so the chain *gives* to constraints instead of fighting them (fixes "tentacle jitters between legs"). TentacleMood now also owns `bending_stiffness`, `damping`, `contact_stiffness` — driver forwards them to its Tentacle reference. Re-tuned the four bundled presets. **4G (2026-05-02):** Physics-correct friction projection. **Spec divergence flagged in `docs/Cosmic_Bliss_Update_2026-05-02_phase4_friction_correction.md`** — the §4.3 spec form `cancel = tangent_mag × (1 − kinetic_cone/tangent_mag)` over-cancels by 10–20× in the kinetic regime; corrected to `cancel = (Δx_tangent / tangent_mag) × kinetic_cone` so the type-1 reciprocal impulse evaluates to the physically correct `μ_k × N × dt`. `body_impulse_scale` default flipped from 0.1 (pragmatic cap) to 1.0 (full spec impulse). **4I–4K (2026-05-02):** Targeted jitter mitigations layered after user reports of stick-slip oscillation between solid colliders — `contact_velocity_damping` (4I, end-of-finalize lerp of prev_position toward position), `final collision cleanup pass` (4J, end-of-iterate normal pushout), `support_in_contact` gravity tangent projection (4K). Each addressed a real seed but did not fully resolve the wedged-chain case. **4L (2026-05-02):** Iter-loop reorder — split collision step into normal-only depenetration (records `dn` per particle into `iter_dn_buffer`) early, friction projection deferred to AFTER distance constraints. `iter_dn_buffer` resets per tick (in `predict()`), max-accumulates across iters so tangent contacts (depth≤0 this iter but penetrated earlier) still have friction-cone ammo. Decouples jitter amplitude from `iter_count`: regression test `test_jitter_does_not_scale_with_iter_count` verifies max tick-to-tick |Δpos| at iter_count=4 is ≤1.5× the iter_count=1 metric (post-4L: 0.90×; pre-4L: multi-x). Bug fix: `environment_layer.gd` no longer calls `surface_end()` on an empty surface (defer `surface_begin` until first vertex). **Tests:** test_collision_type4 18/18, test_tentacle_mood 7/7. **4M-pre done (2026-05-03, `docs/Cosmic_Bliss_Update_2026-05-03_phase4_wedge_robustness.md`):** dt clamp at top of `Tentacle::tick` (floor 1e-4, ceil 1/40 s — caps Verlet gravity step on first-frame hiccups); `target_softness_when_blocked` (default 0.3) on PBDSolver — applied uniformly to both the singleton-tip target path AND every distributed pose-target entry inside iterate step 2 when `in_contact_this_tick` set, so AI drivers writing tip targets via `Tentacle::set_target` get the same softening as drivers using pose targets; corresponding Tentacle passthrough + export; `BehaviorDriver` no longer fetches `get_particle_in_contact_snapshot()` itself (deleted the per-particle blocked-stiffness compute) — instead forwards `pose_softness_when_blocked` to `Tentacle.target_softness_when_blocked` from `_apply_mood`/`_ready`/`refresh_wiring`/the @export setter; `wedge_distance_stiffness_factor` (default 0.3) on PBDSolver — three-way distance stiffness in iterate step 4 (free → `distance_stiffness`; one-endpoint-in-contact → `contact_stiffness`; both-endpoints-in-contact → `contact_stiffness × wedge_distance_stiffness_factor`); Tentacle passthrough + export; `TentacleMood` gains the `wedge_distance_stiffness_factor` field, forwarded by `_apply_mood`. Spec divergence flagged: the singleton-target test landed as a wiring assertion + smoke check rather than the specced "tip stops at wall + radius" form — `predict()` clears `in_contact_this_tick` every tick so iter 0 always pulls at full strength regardless of softening, and steady-state position is dominated by the cleanup pass + friction freeze, making the soft-vs-stiff difference invisible in headless. The wedge-stretch test (4M-pre.3) is the strong behavioral validator in the cluster (observed soft 0.136 vs rigid 0.0975 max stretch ratio). **Tests:** test_collision_type4 21/21, test_tentacle_mood 7/7. **Pending close-out cluster (RESHAPED 2026-05-03 after Obi 7.x solver source review at `docs/pbd_research/Obi/`; full synthesis at `docs/pbd_research/findings_obi_synthesis.md` — read before starting 4M):** **4M** — multi-contact probe (`intersect_shape` up to 2 contacts) **+ Jacobi-with-atomic-deltas-and-SOR pattern + per-contact persistent normal/tangent lambda accumulators** (lifted from Obi `ContactHandling.cginc` + `AtomicDeltas.cginc` + `ColliderCollisionConstraints.compute`). Replaces the originally-drafted "bisector friction normal" approach. Removes `iter_dn_buffer` (4L) and the 4J cleanup pass entirely — both were patching the lack of lambda accumulation, both subsumed. Per-contact `friction_applied` for the reciprocal pass. **4M-XPBD** (new) — distance constraint migrates to canonical XPBD compliance form (`pbd_research/Obi/Resources/Compute/DistanceConstraints.compute`, ~70 lines). Existing `set_distance_stiffness(0..1)` API preserved; internally translated to compliance via a `stiffness_to_compliance` log-mapping. Re-tune mood presets after landing (existing `distance_stiffness=1.0` will read slightly softer). Bundled with 4M because both need the same per-constraint lambda buffer. **4N** — fresh-this-tick contact snapshot accessor on Tentacle. **4O** — sub-stepping promoted from Phase 9 §13 item 38; canonical convergence default per Obi (`substeps=4, iters=1` rather than `substeps=1, iters=4`). After landing, flip default substeps from 1 → 2. **4P** (new) — sleep threshold + max depenetration cap (Obi `Solver.compute:204-217` + `SolverParameters.cginc`). Two cheap one-liners. **Phase 5 stays blocked until 4O lands** — orifice rim is a multi-contact wedge geometry; starting Phase 5 on the pre-Jacobi single-contact path would compound the bug. **Phase 4.5 placeholder narrowed:** XPBD compliance + per-contact lambda warm-starting *moved into the cluster* — no longer Phase 4.5. Per-tick friction budget moot (each contact's `normal_lambda` IS the friction budget). Still in 4.5: per-collider material composition (Obi-style Average/Min/Multiply/Max combine modes); CCD against capsules (only if 4O insufficient for thrust). **Still deferred (separate work):** §4.4 modulator stack; §4.6 wetness propagation; type-2/3/5/6/7 collision (Phase 5 orifice). Pre-existing 2 failures in `test_tentacle_behavior` unrelated. **4M + 4M-XPBD done (2026-05-03):** Iter loop rewritten in Jacobi-with-atomic-deltas-and-SOR form (`PBDSolver::add_position_delta` + `apply_position_deltas_all`, sized to N in `initialize_chain`, default `sor_factor=1.0`; Obi `AtomicDeltas.cginc`). Per-contact persistent `normal_lambda` + `tangent_lambda` accumulators on PBDSolver (parallel arrays at N×MAX_CONTACTS); reset per tick by `set_environment_contacts_multi`. Collision step (iter 3) replaced with Obi `ContactHandling.cginc::SolvePenetration` form — `dlambda = -(dist + max_proj)/inv_mass`, `new_lambda = max(λ + dlambda, 0)`, position delta `cn × λ_change × inv_mass`; depenetration cap (`max_depenetration`, default 1.0 m/s) via `max_proj`. Friction step (iter 5) per-slot lambda-bounded cone: `cone = mu × normal_lambda` (m·kg), per-iter tangent motion against prev_position fully cancels in static cone, capped at `kinetic_cone` in kinetic regime; per-slot `friction_applied` accumulates for the type-1 reciprocal pass. Distance constraint (iter 4) migrated to canonical XPBD (`DistanceConstraints.compute`): per-segment `distance_lambdas` reset in `predict()`, `compliance = stiffness_to_compliance(s) / dt²` log-mapping (s=1→1e-9, s=0→1e-3); s=0 special-cased to "skip constraint" so the existing `set_distance_stiffness(0)` semantics test_volume_preservation depends on still hold. **Removed:** `iter_dn_buffer` (4L), end-of-iter cleanup pass (4J), bisector-friction normal heuristic, `wedge_distance_stiffness_factor` (4M-pre.3) on PBDSolver/Tentacle/TentacleMood/BehaviorDriver — all subsumed. New `Tentacle::sor_factor` + `max_depenetration` exports, `PBDSolver::set_sor_factor` / `set_max_depenetration` / `get_distance_lambdas_snapshot`. **Tests:** test_collision_type4 24/24 (added `test_distance_xpbd_steady_state_lambdas_bounded`, `test_distance_xpbd_lambda_resets_each_tick`; removed `test_two_sided_wedge_softens_distance` per spec; relaxed `test_contact_velocity_damping_suppresses_jitter` and `test_jitter_does_not_scale_with_iter_count` to XPBD-bounded; rewrote `test_sphere_below_anchor_blocks_tip` and `test_obstacle_in_chain_path_pushed_aside` for tighter XPBD-converged geometry; relaxed `test_contact_stiffness_allows_segment_stretch` to a wiring smoke check since under XPBD the contact_stiffness knob is convergence-rate, not steady-state stretch). test_solver 7/7, test_tentacle_mood 7/7, test_pose_targets 5/5, test_render 4/4, test_render_with_tentacle_mesh 4/4, test_tentacle_mesh 5/5, test_sucker_row_feature 4/4, test_girth_baker 2/2, test_geometry_features 13/13, test_mass_from_girth 5/5, test_spline 7/7. test_tentacle_behavior 9/11 (2 pre-existing failures unrelated, `is_inside_tree()` test scaffolding issue). **Spec divergences flagged:** (a) friction cone uses scalar lambda along current dx_tan_dir (not Obi's tangent/bitangent pyramid); spec acceptable for 1D chain. (b) friction reciprocal evaluates `friction_applied × eff_mass / dt` as before — Jacobi position delta averaging halves position correction at multi-contact slots while `friction_applied` accumulates full per-slot, so a particle rubbing against two surfaces produces 2× total reciprocal impulse on the bodies (correctly: each surface receives its own friction reaction). (c) `friction_projection.h::project_friction` is now unused in the solver; left in tree, will retire in follow-up. .so size 1.88 MB. **4N done (2026-05-03):** New `Tentacle::get_in_contact_this_tick_snapshot()` accessor returns a `PackedByteArray` (one byte per particle: 1 if probe found any contact this tick, 0 if free). Populated at the end of `_run_environment_probe()` from `env_contact_count_scratch[i] > 0`, *before* `solver->tick()` iterates. Cleared on the early-out paths (probe disabled, n < 2). Behaviour-driver class docstring updated with the process-order requirement (driver `_physics_process` must run after the tentacle's; default parent-first ordering when the driver is a child of the tentacle gives this for free; falls back to last-tick semantics if inverted, no regression). **Driver switch from spec text was already moot in our codebase**: 4M-pre.2 moved the contact-driven softening into the solver itself (`target_softness_when_blocked` applied uniformly to singleton + pose targets inside iterate), so `behavior_driver.gd` no longer fetches a contact snapshot. The new accessor is published for the gizmo overlay, custom AI drivers, and future Phase 5 orifice consumers that want this-tick-fresh manifold data without going through the iter-stale solver flag. **Spec divergence:** the probe-side flag fires for any particle within range (including pinned ones); the solver-side `get_particle_in_contact_snapshot()` is gated on `inv_mass > 0` (iterate skips pinned particles). Test `test_in_contact_snapshot_is_fresh_this_tick` excludes pinned particles from the cross-check. **Tests:** test_collision_type4 25/25, others unchanged. |
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
- **Per-rim-particle quantities use `_per_loop_k[l][k]`** where `l` is loop index and `k` is rim particle index (canonical, established in §6.2 after the 2026-05-03 amendment). The `_per_dir[d]` and `_per_ring[r]` indexing schemes from earlier drafts are retired; do not reintroduce them.
- **Axial-wedge math uses the normalized form** `-p × drds_outward / sqrt(1 + drds_outward²)` (= `-p × sin θ`), not `tan(local_taper)` and not the unnormalized `-p × drds_outward` linearization. The normalized form is bounded by `p` at near-vertical flanges; the others blow up at exactly the geometry that matters most. `drds_outward` is gradient w.r.t. distance traveled along `+entry_axis`, derived from intrinsic `dr/ds` by the sign of `dot(t_hat, entry_axis)` (§6.3).
- **Type-2 friction reciprocals do NOT route per-particle to a ragdoll bone.** They sum into `EI.tangential_friction_per_loop_k[l][k]` (§6.2) and the §6.3 reaction-on-host-bone pass routes them to `host_bone` per rim particle. Type-1 routing rule (§4.3) does not apply to type-2 contacts.
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

Full phase plan is in `TentacleTech_Architecture.md` §13. Current focus: Phase 4 close-out (slices 4O + 4P sleep-threshold half per `../../docs/Cosmic_Bliss_Update_2026-05-03_phase4_wedge_robustness.md` — 4M, 4M-XPBD, 4N landed 2026-05-03; 4P max_depenetration half landed with 4M).
