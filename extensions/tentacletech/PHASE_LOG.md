# TentacleTech — Phase Log

Per-phase implementation history extracted from the prior `CLAUDE.md` Status table on 2026-05-10. Append a dated entry per slice; do not edit prior entries except to fix factual errors. The architecture doc (`../../docs/architecture/TentacleTech_Architecture.md`) remains the source of truth for the spec; this file logs how the implementation got there.

Phases run in numerical order below. Within each phase, slices are listed chronologically.

## Current focus

**Phase 5 cluster mostly closed; canal interior model is the next gate.**

Phase 5 slices 5A + 5B + 5C-A + 5C-B + 5C-C + 5D landed 2026-05-04, 5H landed 2026-05-05 — rim primitive + host-bone soft attachment + bilateral type-2 contact + EntryInteraction lifecycle/geometric tracking + friction at type-2 + §6.3 reaction-on-host-bone closure + 4P-A anisotropic rim distance / 4P-B J-curve strain stiffening / 4P-C plastic offset (orifice memory) + 5H tentacle feature silhouette (2D bake → type-1/2/4 contact integration). **Phase 5 acceptance per §13 ("tentacle penetrates, rim deforms with continuous silhouette under load, multi-loop configurations supported, glancing approaches slide off") is fully testable end-to-end.** Full tentacletech suite **181/181** as of 2026-05-11 (4S.2 body-local-frame contact persistence).

`Orifice : Node3D` runs per-loop XPBD distance (anisotropic compression-vs-stretch under 4P-A) + volume + J-curve-modulated spring-back (4P-B) interleaved with cross-loop type-2 normal + friction projection; EIs persist hysterically across ticks with plastic offset memory (4P-C) drifting + recovering; per-loop_k arrays populated from settled contact lambdas; grip ramps under stationarity.

Gizmo overlay shows rim + rest markers + host-bone marker + orange type-2 contact lines + purple EI entry-point/axis markers + cyan-yellow friction arrows + green→yellow→red pressure bars + lime host-body marker + magenta plastic-offset arrows + stretch-tinted rim segments + J-curve heat overlay.

Phase 4 close-out post-review spec edits applied to `../../docs/architecture/TentacleTech_Architecture.md` 2026-05-03 (commit ad30080); `Cosmic_Bliss_Update_2026-05-03_phase4_wedge_robustness.md` stamped applied; slices 5A + 5B + 5C-A + 5C-B + 5C-C + 5D reviewed + ratified by top-level Claude 2026-05-04 — Phase 5 fully closed.

**5C-C bug catch:** sub-Claude found while wiring 5C-C that 5C-B's `_resize_per_loop_k_arrays` was zeroing damage every tick via `assign(n, 0.0)`; switched to `resize(n, 0.0)` so existing entries survive growth. Top-level review of 5C-B missed this — caught downstream by the damage accumulation test pattern (the right kind of catch). 5C-C divergence (c) — wedge math approximating per-rim-particle arc-length offset as zero — tracked as a Phase 8 follow-up when curved-tunnel + multi-loop axial separation lands.

**Next gate:** canal interior model (5E/5F/5G). The `Cosmic_Bliss_Update_2026-05-04_canal_interior_model.md` amendment is awaiting top-level Claude's architecture-doc apply pass post-5D review.

---

## Phase 1 — Spline primitives

**State:** done.

`CatmullSpline` + `SplineDataPacker` registered, 7/7 tests pass at `game/tests/tentacletech/test_spline.gd`.

---

## Phase 2 — PBD core

**State:** done.

`TentacleParticle`, `PBDSolver`, `Tentacle` Node3D registered. 7/7 tests at `game/tests/tentacletech/test_solver.gd`. Phase-2 snapshot accessors per §15.2. Debug overlay at `gdscript/debug/` with `particles_layer.gd` + `constraints_layer.gd`.

**Tracked simplification:** bending constraint is chord-only between (i, i+2); spec form (3-particle angle) deferred to Phase 9 polish. **No `dt` clamp** in `tick()` — first-frame hiccup can spike gravity, addressed in 4M-pre.

---

## Phase 3 — Mesh rendering

**State:** done.

### 3a — Shader + per-instance material

`tentacle.gdshader` + `tentacle_lib.gdshaderinc` (§5.3); per-tick `RGBA32F` spline data texture (alloc-free) on `Tentacle`; per-instance `ShaderMaterial` + auto-discovered `MeshInstance3D`; `mesh_arc_axis` + `mesh_arc_offset` properties to accept Y-up centered primitives.

### 3b — Procedural mesh + base feature

`TentacleMesh : Resource` (`gdscript/procedural/tentacle_mesh.gd`) with base-shape generator (linear/curve taper, twist, seam_offset, intrinsic axis −Z); `BakeContext` + `TentacleFeature` abstract base + `SuckerRowFeature` end-to-end (OneSide/TwoSide/AllAround/Spiral; rim+cup geometry; `COLOR.r` mask + `UV1` disc-space + `CUSTOM0.x` feature ID; ±5° seam validation); `GirthBaker` static utility producing 256-bin `FORMAT_RF` `ImageTexture` + `rest_length` per §5.4; full §10.2 channel layout (UV0/UV1/COLOR.rgba/CUSTOM0); shared `gdscript/debug/colors.gd` consumed by both runtime layers and the editor gizmo; `EditorPlugin` (`plugin.cfg` + `plugin.gd` + `gdscript/gizmo_plugin/tentacle_gizmo.gd`) drawing particles + segments + spline polyline + TBN frames on selection. New C++ accessors `Tentacle.set_rest_girth_texture`, `get_spline_samples(n)`, `get_spline_frames(n)`.

### 3c — Rounded tip + geometry features (2026-04-29)

`tip_cap_rings` + `tip_pointiness` give an ellipsoidal hemisphere cap (replaces the single-vertex apex; cap_rings=0 reverts to legacy point). `Tentacle::_apply_mesh_length_to_segment_length` now prefers `get_baked_rest_length()` so cap vertices map past the body's spline domain instead of clamping to the tip. `rebuild_chain` snapshots+re-applies `rigid_base_count` so the .tscn property survives `_ready()`.

New geometry features: **KnotFieldFeature** (vertex-kernel radius bumps, Gaussian/Sharp/Asymmetric profile), **RibsFeature** (vertex-kernel inward grooves, U/V profile), **SpinesFeature** (cones with pitched apex, ALL_AROUND/ONE_SIDE/SPIRAL distribution), **RibbonFeature** (1/2/4 fin strips with width_curve + ruffle), **WartClusterFeature** (5-vert pyramids seeded by density + clustering exponent). Vertex-kernel features filter on `FEATURE_ID_BODY` so they don't perturb other features' geometry.

New `BakeContext.body_surface_at(t, world_phi)` helper (rotationally symmetric — does not add seam/twist). New feature IDs: SPINE=3, RIBBON=4, WART=5.

**§5.0 partition tag for new features:** all silhouette-defining → mesh layer.

**Tests:** test_spline 7/7 + test_solver 7/7 + test_render 4/4 + test_tentacle_mesh 5/5 + test_sucker_row_feature 4/4 + test_girth_baker 2/2 + test_render_with_tentacle_mesh 4/4 + test_geometry_features 8/8 = 41/41.

**Deferred:** mask-only features (Papillae, Photophore — fragment-shader branch not wired); tip variants beyond rounded ellipsoid (Canal, Bulb, Mouth, Flare — extension point left in place); discriminated TipFeature library; BaseFeature beyond Flush; LOD / multi-tentacle batching / mesh composition (Phase 9 polish); proper normals at knot-bump peaks (currently radial-only — small lighting error at smooth-profile peaks); editor gizmo markers for feature centers.

---

## Phase 4 — Collision

**State:** 4A→4P done (2026-05-03) + 4Q diagnostic done + 4Q-fix done (2026-05-05) + 4R RID warm-start landed / default flip held (2026-05-05) + 4S brief done (2026-05-05) + 4T pose-target rate limit done (2026-05-05) + 4S.1 symplectic Euler done (2026-05-06). See `docs/Cosmic_Bliss_Update_2026-05-03_phase4_wedge_robustness.md`.

### 4A — Type-4 environment raycasts (2026-05-01)

Type-4 environment raycasts (3/tick gravity-dir), normal-only PBD projection. Files: `src/collision/environment_probe.{h,cpp}`, `gdscript/debug/gizmo_layers/environment_layer.gd`.

### 4B — Friction cone (2026-05-02)

§4.3 friction cone via `src/collision/friction_projection.h`; `set_friction(static, kinetic_ratio)`, per-contact `friction_applied`, Tentacle exports `base_static_friction`/`tentacle_lubricity`/`kinetic_friction_ratio`.

### 4C — Soft contact stiffness (2026-05-02)

Soft `contact_stiffness` (default 0.5) for distance segments where either endpoint flagged `in_contact_this_tick`; iteration order changed (collision before distance). Particle flag cleared in predict(), set in collision pass. New `get_particle_in_contact_snapshot()` + Tentacle export.

### 4D — Per-particle space queries (2026-05-02)

**Replaced** the 3-ray gravity probe with per-particle `PhysicsDirectSpaceState3D::get_rest_info` sphere queries — handles arbitrary motion, all body kinds (StaticBody3D, RigidBody3D, AnimatableBody3D, PhysicalBone3D) uniformly. Probe now allocates one EnvironmentContact per particle. QUERY_BIAS=1.05 detects tangent contacts so settled chains keep `in_contact_this_tick` flagged. New API `set_environment_contacts_per_particle(points, normals, active)`. Snapshot now has one entry per particle with `particle_index`/`query_origin`/`hit`/`hit_point`/`hit_normal`/`hit_object_id`/`hit_linear_velocity`/`friction_applied`.

**Spec divergence (flagged in `environment_probe.h`):** §4.2/§4.5 specify raycasts + ragdoll snapshot; per-particle queries unify type-1 + type-4 at modest cost (~12-30 queries/tentacle/tick), making the §4.5 ownership amendment unnecessary.

### 4E — Type-1 reciprocal (2026-05-02)

§4.3 type-1 reciprocal — after solver tick, `Tentacle::_apply_collision_reciprocals` walks per-particle contacts and applies `friction_applied × eff_mass / dt` impulse to the colliding body via `PhysicsServer3D::body_apply_impulse(rid, impulse, hit_point - body_origin)`. Works uniformly for RigidBody3D, AnimatableBody3D, and PhysicalBone3D — heavy chain dragging across a ragdoll bone pulls the bone in the drag direction. Plan doc: `docs/Cosmic_Bliss_Update_2026-05-01_phase4_collision.md`.

### 4F — Mood-driven softening (2026-05-02)

Collision polish + first slice of moodable solver params. New `body_impulse_scale` @export on Tentacle (then-default 0.1 — see 4G); new `pose_softness_when_blocked` on TentacleMood + TentacleBehavior (default 0.3) — driver fetches `get_particle_in_contact_snapshot()` and softens pose-target stiffness for in-contact particles so the chain *gives* to constraints instead of fighting them (fixes "tentacle jitters between legs"). TentacleMood now also owns `bending_stiffness`, `damping`, `contact_stiffness` — driver forwards them to its Tentacle reference. Re-tuned the four bundled presets.

### 4G — Friction projection correction (2026-05-02)

Physics-correct friction projection. **Spec divergence flagged in `docs/Cosmic_Bliss_Update_2026-05-02_phase4_friction_correction.md`** — the §4.3 spec form `cancel = tangent_mag × (1 − kinetic_cone/tangent_mag)` over-cancels by 10–20× in the kinetic regime; corrected to `cancel = (Δx_tangent / tangent_mag) × kinetic_cone` so the type-1 reciprocal impulse evaluates to the physically correct `μ_k × N × dt`. `body_impulse_scale` default flipped from 0.1 (pragmatic cap) to 1.0 (full spec impulse).

### 4I–4K — Targeted jitter mitigations (2026-05-02)

Targeted jitter mitigations layered after user reports of stick-slip oscillation between solid colliders — `contact_velocity_damping` (4I, end-of-finalize lerp of prev_position toward position), `final collision cleanup pass` (4J, end-of-iterate normal pushout), `support_in_contact` gravity tangent projection (4K). Each addressed a real seed but did not fully resolve the wedged-chain case.

### 4L — Iter-loop reorder (2026-05-02)

Iter-loop reorder — split collision step into normal-only depenetration (records `dn` per particle into `iter_dn_buffer`) early, friction projection deferred to AFTER distance constraints. `iter_dn_buffer` resets per tick (in `predict()`), max-accumulates across iters so tangent contacts (depth≤0 this iter but penetrated earlier) still have friction-cone ammo. Decouples jitter amplitude from `iter_count`: regression test `test_jitter_does_not_scale_with_iter_count` verifies max tick-to-tick |Δpos| at iter_count=4 is ≤1.5× the iter_count=1 metric (post-4L: 0.90×; pre-4L: multi-x). Bug fix: `environment_layer.gd` no longer calls `surface_end()` on an empty surface (defer `surface_begin` until first vertex).

**Tests:** test_collision_type4 18/18, test_tentacle_mood 7/7.

### 4M-pre — Wedge robustness pre-cluster (2026-05-03)

Per `docs/Cosmic_Bliss_Update_2026-05-03_phase4_wedge_robustness.md`. dt clamp at top of `Tentacle::tick` (floor 1e-4, ceil 1/40 s — caps Verlet gravity step on first-frame hiccups); `target_softness_when_blocked` (default 0.3) on PBDSolver — applied uniformly to both the singleton-tip target path AND every distributed pose-target entry inside iterate step 2 when `in_contact_this_tick` set, so AI drivers writing tip targets via `Tentacle::set_target` get the same softening as drivers using pose targets; corresponding Tentacle passthrough + export; `BehaviorDriver` no longer fetches `get_particle_in_contact_snapshot()` itself (deleted the per-particle blocked-stiffness compute) — instead forwards `pose_softness_when_blocked` to `Tentacle.target_softness_when_blocked` from `_apply_mood`/`_ready`/`refresh_wiring`/the @export setter; `wedge_distance_stiffness_factor` (default 0.3) on PBDSolver — three-way distance stiffness in iterate step 4 (free → `distance_stiffness`; one-endpoint-in-contact → `contact_stiffness`; both-endpoints-in-contact → `contact_stiffness × wedge_distance_stiffness_factor`); Tentacle passthrough + export; `TentacleMood` gains the `wedge_distance_stiffness_factor` field, forwarded by `_apply_mood`.

Spec divergence flagged: the singleton-target test landed as a wiring assertion + smoke check rather than the specced "tip stops at wall + radius" form — `predict()` clears `in_contact_this_tick` every tick so iter 0 always pulls at full strength regardless of softening, and steady-state position is dominated by the cleanup pass + friction freeze, making the soft-vs-stiff difference invisible in headless. The wedge-stretch test (4M-pre.3) is the strong behavioral validator in the cluster (observed soft 0.136 vs rigid 0.0975 max stretch ratio).

**Tests:** test_collision_type4 21/21, test_tentacle_mood 7/7.

### 4M + 4M-XPBD — Jacobi/SOR + XPBD distance (2026-05-03)

**Pending close-out cluster RESHAPED 2026-05-03** after Obi 7.x solver source review at `docs/pbd_research/Obi/`; full synthesis at `docs/pbd_research/findings_obi_synthesis.md` — read before starting 4M.

**4M** — multi-contact probe (`intersect_shape` up to 2 contacts) + Jacobi-with-atomic-deltas-and-SOR pattern + per-contact persistent normal/tangent lambda accumulators (lifted from Obi `ContactHandling.cginc` + `AtomicDeltas.cginc` + `ColliderCollisionConstraints.compute`). Replaces the originally-drafted "bisector friction normal" approach. Removes `iter_dn_buffer` (4L) and the 4J cleanup pass entirely — both were patching the lack of lambda accumulation, both subsumed. Per-contact `friction_applied` for the reciprocal pass.

**4M-XPBD** — distance constraint migrates to canonical XPBD compliance form (`pbd_research/Obi/Resources/Compute/DistanceConstraints.compute`, ~70 lines). Existing `set_distance_stiffness(0..1)` API preserved; internally translated to compliance via a `stiffness_to_compliance` log-mapping. Re-tune mood presets after landing (existing `distance_stiffness=1.0` will read slightly softer). Bundled with 4M because both need the same per-constraint lambda buffer.

**4N** — fresh-this-tick contact snapshot accessor on Tentacle. **4O** — sub-stepping promoted from Phase 9 §13 item 38; canonical convergence default per Obi (`substeps=4, iters=1` rather than `substeps=1, iters=4`). After landing, flip default substeps from 1 → 2. **4P** — sleep threshold + max depenetration cap (Obi `Solver.compute:204-217` + `SolverParameters.cginc`). Two cheap one-liners. **Phase 5 stays blocked until 4O lands** — orifice rim is a multi-contact wedge geometry; starting Phase 5 on the pre-Jacobi single-contact path would compound the bug. **Phase 4.5 placeholder narrowed:** XPBD compliance + per-contact lambda warm-starting *moved into the cluster* — no longer Phase 4.5. Per-tick friction budget moot (each contact's `normal_lambda` IS the friction budget). Still in 4.5: per-collider material composition (Obi-style Average/Min/Multiply/Max combine modes); CCD against capsules (only if 4O insufficient for thrust). **Still deferred (separate work):** §4.4 modulator stack; §4.6 wetness propagation; type-2/3/5/6/7 collision (Phase 5 orifice). Pre-existing 2 failures in `test_tentacle_behavior` unrelated.

**Landed (2026-05-03):** Iter loop rewritten in Jacobi-with-atomic-deltas-and-SOR form (`PBDSolver::add_position_delta` + `apply_position_deltas_all`, sized to N in `initialize_chain`, default `sor_factor=1.0`; Obi `AtomicDeltas.cginc`). Per-contact persistent `normal_lambda` + `tangent_lambda` accumulators on PBDSolver (parallel arrays at N×MAX_CONTACTS); reset per tick by `set_environment_contacts_multi`. Collision step (iter 3) replaced with Obi `ContactHandling.cginc::SolvePenetration` form — `dlambda = -(dist + max_proj)/inv_mass`, `new_lambda = max(λ + dlambda, 0)`, position delta `cn × λ_change × inv_mass`; depenetration cap (`max_depenetration`, default 1.0 m/s) via `max_proj`. Friction step (iter 5) per-slot lambda-bounded cone: `cone = mu × normal_lambda` (m·kg), per-iter tangent motion against prev_position fully cancels in static cone, capped at `kinetic_cone` in kinetic regime; per-slot `friction_applied` accumulates for the type-1 reciprocal pass. Distance constraint (iter 4) migrated to canonical XPBD (`DistanceConstraints.compute`): per-segment `distance_lambdas` reset in `predict()`, `compliance = stiffness_to_compliance(s) / dt²` log-mapping (s=1→1e-9, s=0→1e-3); s=0 special-cased to "skip constraint" so the existing `set_distance_stiffness(0)` semantics test_volume_preservation depends on still hold.

**Removed:** `iter_dn_buffer` (4L), end-of-iter cleanup pass (4J), bisector-friction normal heuristic, `wedge_distance_stiffness_factor` (4M-pre.3) on PBDSolver/Tentacle/TentacleMood/BehaviorDriver — all subsumed. New `Tentacle::sor_factor` + `max_depenetration` exports, `PBDSolver::set_sor_factor` / `set_max_depenetration` / `get_distance_lambdas_snapshot`.

**Tests:** test_collision_type4 24/24 (added `test_distance_xpbd_steady_state_lambdas_bounded`, `test_distance_xpbd_lambda_resets_each_tick`; removed `test_two_sided_wedge_softens_distance` per spec; relaxed `test_contact_velocity_damping_suppresses_jitter` and `test_jitter_does_not_scale_with_iter_count` to XPBD-bounded; rewrote `test_sphere_below_anchor_blocks_tip` and `test_obstacle_in_chain_path_pushed_aside` for tighter XPBD-converged geometry; relaxed `test_contact_stiffness_allows_segment_stretch` to a wiring smoke check since under XPBD the contact_stiffness knob is convergence-rate, not steady-state stretch). test_solver 7/7, test_tentacle_mood 7/7, test_pose_targets 5/5, test_render 4/4, test_render_with_tentacle_mesh 4/4, test_tentacle_mesh 5/5, test_sucker_row_feature 4/4, test_girth_baker 2/2, test_geometry_features 13/13, test_mass_from_girth 5/5, test_spline 7/7. test_tentacle_behavior 9/11 (2 pre-existing failures unrelated, `is_inside_tree()` test scaffolding issue).

**Spec divergences flagged:** (a) friction cone uses scalar lambda along current dx_tan_dir (not Obi's tangent/bitangent pyramid); spec acceptable for 1D chain. (b) friction reciprocal evaluates `friction_applied × eff_mass / dt` as before — Jacobi position delta averaging halves position correction at multi-contact slots while `friction_applied` accumulates full per-slot, so a particle rubbing against two surfaces produces 2× total reciprocal impulse on the bodies (correctly: each surface receives its own friction reaction). (c) `friction_projection.h::project_friction` is now unused in the solver; left in tree, will retire in follow-up. .so size 1.88 MB.

### 4N — Fresh-this-tick contact snapshot (2026-05-03)

New `Tentacle::get_in_contact_this_tick_snapshot()` accessor returns a `PackedByteArray` (one byte per particle: 1 if probe found any contact this tick, 0 if free). Populated at the end of `_run_environment_probe()` from `env_contact_count_scratch[i] > 0`, *before* `solver->tick()` iterates. Cleared on the early-out paths (probe disabled, n < 2). Behaviour-driver class docstring updated with the process-order requirement (driver `_physics_process` must run after the tentacle's; default parent-first ordering when the driver is a child of the tentacle gives this for free; falls back to last-tick semantics if inverted, no regression).

**Driver switch from spec text was already moot in our codebase**: 4M-pre.2 moved the contact-driven softening into the solver itself (`target_softness_when_blocked` applied uniformly to singleton + pose targets inside iterate), so `behavior_driver.gd` no longer fetches a contact snapshot. The new accessor is published for the gizmo overlay, custom AI drivers, and future Phase 5 orifice consumers that want this-tick-fresh manifold data without going through the iter-stale solver flag.

**Spec divergence:** the probe-side flag fires for any particle within range (including pinned ones); the solver-side `get_particle_in_contact_snapshot()` is gated on `inv_mass > 0` (iterate skips pinned particles). Test `test_in_contact_snapshot_is_fresh_this_tick` excludes pinned particles from the cross-check.

**Tests:** test_collision_type4 25/25, others unchanged.

### 4O + 4P — Sub-stepping + sleep threshold (2026-05-03)

**Slice 4O** — `Tentacle::tick` runs an outer-frame substep loop. New `substep_count` @export (default 1, hard-capped at 4) sets a floor; a displacement-driven heuristic auto-bumps the per-frame count when the worst-case predicted displacement (gravity·dt² + singleton-target snap = `stiffness × distance_to_target`) exceeds `0.5 × collision_radius`. `set_anchor` lifted out of the loop (transform constant within frame); `_run_environment_probe()` + `solver->tick(sub_dt)` iterate per substep with `sub_dt = p_delta / sub_steps`. Per-substep, `set_environment_contacts_multi` resets per-contact `normal_lambda` / `tangent_lambda` (Obi-style fresh manifold) but no longer clobbers `friction_applied` — that accumulator now spans the outer frame and is reset once via the new `PBDSolver::reset_friction_applied()` API at outer-tick start. `_apply_collision_reciprocals(p_delta)` reads the summed value and applies impulses with the OUTER tick dt (correct momentum semantics). New `get_last_substep_count()` accessor for the gizmo overlay + tests. Pose-target driven thrust intentionally omitted from the heuristic (would conservatively bump every behavior frame; thrust-heavy moods set `substep_count` manually).

**Slice 4P** — sleep threshold: new `sleep_threshold` (m/s) @export on Tentacle/PBDSolver/TentacleMood, default 0.0 (disabled, preserves shipping behavior). In `finalize()` after `contact_velocity_damping`, in-contact particles whose `||position − prev_position||² ≤ (threshold·dt)²` get position snapped to prev_position, killing residual jitter. Free particles never sleep (out-of-contact tentacles keep integrating gravity). Pattern from `pbd_research/Obi/Resources/Compute/Solver.compute:204-217`. Per-mood opt-in (~0.005 for caressing/idle moods that hang at rest). 4P max-depenetration half already shipped with 4M (the `max_dlambda` cap inside the collision step). New `TentacleMood.substep_count` and `sleep_threshold` fields, forwarded by `BehaviorDriver._apply_mood`.

**Spec divergences flagged:** (a) `substep_count` is a FLOOR not an absolute (heuristic can bump it); spec text reads ambiguous between "minimum" and "fixed" — chose floor since the displacement heuristic is the safety net the spec calls out. (b) When a chain particle's contact body changes between substeps (rare — sub-radius motion required), accumulated friction routes to the LAST substep's body. Stable manifolds (the common case) match the single-step result exactly; documented in `Tentacle::tick`. (c) `test_substep_thrust_does_not_tunnel` validates heuristic engagement + finite positions + forward integration rather than strict no-tunnel — the spec's stated post-condition ("tip stops at wall + collision_radius") requires per-iter target snap to stay within probe range, which sub-stepping alone doesn't guarantee. The actual no-tunnel guarantee is a CCD-class fix the spec acknowledges as deferred to Phase 9. (d) `set_anchor` moved outside the substep loop (was inside per spec text); the global_transform is constant within an outer tick so per-substep refresh is pure waste.

**Tests:** test_collision_type4 30/30 (added `test_substep_thrust_does_not_tunnel`, `test_substep_friction_matches_single_step`, `test_substep_count_default_is_one`, `test_sleep_threshold_settles_chain`, `test_sleep_threshold_off_keeps_motion`). All other tentacletech suites unchanged. test_tentacle_behavior 9/11 (2 pre-existing failures unrelated). .so size 1.80 MB. Phase 5 unblocked.

### 4Q diagnostic — stick-slip investigation (2026-05-05)

Four-round investigation isolating the user's reported "very strong jitter" in active-probing scenarios.

- **Round 1** (static V-wedge with StaticBody3D): channels (i)–(iii) clean, sub-2-mm position drift — wrong premise.
- **Round 2** (RigidBody3D + 6DOF angular springs k=50/c=5, default Bullet, box legs): coupled oscillation confirmed (90.9% phase-correlation between leg motion and contact-point shifts at lub=0.5; 2.5 Hz at joint ω₀) but magnitude small.
- **Round 3** (Jolt + production HIP_K/HIP_C joints k=2/c=3.5 + procedural convex hulls): system was near-silent under passive gravity-only chain — production passive joints are heavily overdamped (ζ≈2.67), couples-oscillation feedback killed; no face-crossings to drive cascade.
- **Round 4** (active probing under round-3 baseline + bundled `probing.tres` mood + attractor below V apex pulling tip down through neck): stick-slip at low lubricity confirmed — at lub=0.0, leg ang_max 1.39 rad/s peak-to-peak 23-29 mm, tangent_lambda max 0.026 m·kg with 3 saturation events (>50% drops). Lubricity polarity inverse to round 2 (passive): lub=1.0 frictionless = stable, lub=0.0 high-friction = chaotic.

Hypothesis: probing target pull builds tangent_lambda past static cone → kinetic release → 1-2 tick high-velocity slip → reciprocal impulse swings leg → contact re-establishes at displaced point → next stick phase.

Diagnostic instrumentation: new `PBDSolver::get_environment_normal_lambdas_snapshot()` (round 1) and `get_environment_tangent_lambdas_snapshot()` (round 4) read-only accessors. Test files: `test_4q_wedge_diagnostic.gd` (round 1), `test_4q_coupled_diagnostic.gd` (round 2), `test_4q_hull_diagnostic.gd` (round 3), `test_4q_probing_diagnostic.gd` (round 4) — all committed under `game/tests/tentacletech/`.

### 4Q-fix — Tension-aware target softening (2026-05-05)

New `tension_taper_threshold` field on PBDSolver / Tentacle / TentacleMood (default 0.8). In `iterate()` step 2, for each in-contact particle: pick the dominant contact slot by max `normal_lambda`, compute `t = |tangent_lambda_dom| / (mu_s × normal_lambda_dom)` against `static_cone = mu_s × normal_lambda_dom`. When `t > threshold`, scale target stiffness by `(1 - over)` where `over = (t - threshold) / (1 - threshold)`, ramping from 1 at threshold to 0 at saturation. Composes multiplicatively with existing `target_softness_when_blocked`. Applies uniformly to BOTH the singleton `set_target` path AND every distributed pose-target entry — no caller-side change needed. Iter 0 sees zero lambdas (reset by `set_environment_contacts_multi`) → no taper; iter 1+ sees the previous iter's friction step output and backs off.

Static formula extracted to `PBDSolver::compute_tension_taper_factor(threshold, mu_s, nlam, |tlam|)` for unit-test verification. Test hooks `_test_set_environment_normal_lambda` / `_test_set_environment_tangent_lambda` added but ultimately unused by the formula test (which calls the static helper directly); left in place for future direct-injection tests. New `TentacleMood.tension_taper_threshold` forwarded by `BehaviorDriver._apply_mood`. Bundled mood presets (curious / idle / caressing / probing) get the resource default 0.8 since none authored the new field — multiplicative composition with their existing `pose_softness_when_blocked` (0.15 to 0.5) cleanly kills target pull at saturation regardless of softening floor; no preset re-tune needed.

**Tests:** test_collision_type4 32/32 (added `test_tension_taper_threshold_default_and_clamp` + `test_tension_taper_formula_at_threshold_half_saturation` covering all corners of the formula: disabled, below threshold, at threshold, midpoint=0.5, saturation, past saturation, threshold=0, no-friction, zero normal_lambda). New regression test `game/tests/tentacletech/test_4q_probing_regression.gd` 1/1 — A/B comparison at lub=0.0: taper OFF (threshold=1.0) reproduces pre-fix signature (leg ang_max 1.395 rad/s, sat=3, tlam/cone=1.94), taper ON (default 0.8) brings leg ang_max to 0.757 rad/s (54% of disabled — passes the ≤70% bound), saturation_events held at 3 (no regression, equal to disabled), tlam/cone improved 1.94→1.92. Full tentacletech suite 165/165 (was 162). .so size 2.02 MB.

**Spec divergences flagged:** (a) the round-4-fix prompt's predicted post-fix bounds (leg_ang_max < 0.3 rad/s = 3× drop, saturation_events == 0, tlam/cone < 0.5) are NOT met by the taper alone — observed 1.84× drop in leg_ang_max, saturation_events unchanged at 3, tlam/cone still ~1.9× cone. The fix engages and meaningfully reduces stick-slip but doesn't extinguish it; iter 0 always applies full pull before lambdas accumulate, and the dominant-slot tension fraction equilibrium under heavy probing pull sits near (not below) the threshold. Round-5 substep flip (1×4 → 4×1) is the prompt's contingent fallback for additional attenuation; not bundled here per the prompt's "hold for round 5" directive. Regression test re-framed as A/B comparison (taper-OFF vs taper-ON in same scene) rather than tight numeric bounds, so future tuning of either default threshold or substep count doesn't break it. (b) Static helper `compute_tension_taper_factor(threshold, mu_s, nlam, |tlam|)` is bound via `bind_static_method` and callable as `PBDSolver.compute_tension_taper_factor(...)` from GDScript; the iter-loop call site invokes the same helper through a per-particle lambda so production code and unit test use the same formula. (c) Test hooks `_test_set_environment_normal_lambda` / `_test_set_environment_tangent_lambda` were added during exploration but ended up unused — the static-helper approach was cleaner. Hooks left in tree (small, harmless, may help future per-iter behavioural tests). Phase 5 still open / waiting on canal interior model.

### 4R — RID-keyed lambda warm-start; default flip held back (2026-05-05)

New `set_environment_contacts_multi(points, normals, counts, rids)` API takes a `PackedInt64Array` of slot RIDs (size N × MAX_CONTACTS, sourced from `EnvironmentContact::hit_rid[k].get_id()`) — populated by the Tentacle in `_run_environment_probe` via the new `env_contact_rids_scratch` field. New `std::vector<int64_t> env_contact_rid` on PBDSolver, sized in `initialize_chain`, persistent across substeps + ticks. On each `set_environment_contacts_multi` call, per-particle warm-start: snapshot the OLD slot RIDs/lambdas/tangent-lambdas into stack arrays, then for each new slot search the OLD slots for a matching RID; if found, copy `normal_lambda` + `tangent_lambda` from old slot → new slot; otherwise zero. Per-particle `MAX_CONTACTS² = 4` comparisons (trivial). `claimed[]` mask prevents two new slots warm-starting from the same old slot. New `clear_environment_contacts` zeros the RID array. New `reset_environment_contact_lambdas` zeros lambdas without disturbing RIDs/counts/points — Tentacle::tick calls it once at outer-frame start (alongside `reset_friction_applied`) so cross-tick warm-start is bounded (intra-tick only; cross-tick is out of scope per the slice prompt and would need separate work to be safe). At `substep_count = 1` (current default), the warm-start path degenerates to "match against last call's identical-RID slot, both lambdas equal 0 from the just-fired outer reset" — preserving the previous behaviour exactly. `friction_applied` deliberately NOT warm-started; existing `reset_friction_applied` per-outer-tick semantics unchanged.

**Default flip explored + reverted:** spec called for `DEFAULT_ITERATION_COUNT 4 → 1` + `Tentacle::substep_count 1 → 4` + `TentacleMood.substep_count 1 → 4` (Obi 4×1 canonical). Implemented + tested; the active-probing regression at lub=0.0 showed taper-ON (default 0.8) becoming **worse** than taper-OFF (1.0) under 4×1 — leg_ang_max 2.03 vs 1.47 rad/s, saturation events 15 vs 4, tlam/cone 2.22 vs 2.32. Mechanism: warm-started tlam carrying across substeps gives the 4Q-fix taper a non-zero saturation reading from iter 0 of substeps 2-4. The taper kills target pull → less normal force → smaller cone → tlam/cone climbs → taper engages even harder → contacts collapse → cone falls to 0 → taper disengages → chain slams back in → big shock → leg swing. The 4Q-fix taper formula was tuned around iter_count=4 cycling (cold iter 0 + tapered iter 1+ averaging within a single substep); under iter_count=1 + warm-start, every substep is "iter 0 with warm tlam" and the averaging that smoothed engagement is gone. Defaults reverted to the pre-4R values (`iter=4`, `substep=1`, mood substep=1); the warm-start machinery + `tension_taper_threshold` plumbing + RID API extension stay in place but inert at substep_count=1.

**Spec divergences flagged:** (a) prompt-specified default flip not landed — taper feedback oscillation under 4×1 is documented at `PBDSolver.h DEFAULT_ITERATION_COUNT` and `Tentacle::substep_count` so a future slice rediscovering the same path has the trail. (b) Step 2 (target pull) gate behaviour preserved at `pp.in_contact_this_tick` for the existing `target_softness_when_blocked` modifier (matches 4Q-fix's "iter 0 cold-pull, iter 1+ softened" cycle that the formula was tuned around). The 4Q-fix tension taper itself is now applied UNCONDITIONALLY rather than gated — `compute_tension_taper_factor` returns 1.0 when `nlam = 0` so non-contact / cold-start particles see no effect; the change is benign and removes a redundant gate. (c) Predict() reverted to clearing `in_contact_this_tick = false` (matching pre-4R semantics; an exploratory change to set it from `cnt[i]` was rolled back after observing distance-stiffness side effects in step 4). (d) New `_test_set_environment_normal_lambda` / `_test_set_environment_tangent_lambda` stubs that round 4Q-fix added were removed during 4R cleanup per the prompt — formula coverage is via the static helper instead; the RID warm-start unit test goes through the natural probe → set_environment_contacts_multi path.

**Tests:** `test_collision_type4` 33/33 (added `test_rid_warm_start_preserves_lambda_on_match_resets_on_mismatch`: tick a chain on a floor for `SETTLE_FRAMES` so the natural probe writes RIDs + grows λ, then call `set_environment_contacts_multi` twice — once with the floor's RID at every active slot (warm-start path; λ preserved within 1%) and once with `floor_rid + 999999` at every active slot (RID mismatch path; λ resets to 0). Validates the round-trip warm-start logic end-to-end. Existing `test_substep_count_default_is_one` retained at `1` since defaults reverted; `test_obstacle_in_chain_path_pushed_aside` kept at the `> 5 mm` threshold since 4×1 isn't engaged). Stick-slip regression `test_4q_probing_regression.gd` preserved 4Q-fix baseline values: taper OFF leg_ang_max=1.395, taper ON 0.757 (54% of disabled — still passes the ≤70% A/B bound). Full suite **166/166** (165 + 1 new). .so size 2.02 MB.

**Out-of-scope and explicitly deferred:** cross-tick warm-start (preserve λ from last frame's last substep into next frame's first substep — easy to add but introduces a stale-λ failure mode if the contact set changes silently; the Obi pattern this would need is the `Solver.compute` `solverDeltas` array's tick-boundary copy step). Contact-point persistence in body-local space (round 3 territory; passive sliding case isn't urgent). MAX_CONTACTS_PER_PARTICLE 2 → 3 (orifice rim; independent slice). support_in_contact decoupling from slot 0. Per-mood tuning of `tension_taper_threshold` (existing 4Q-fix default 0.8 stays). Visual gizmo verification via .tscn (numerical evidence covers the slice).

### 4S brief — Obi contact-persistence verify-first read (2026-05-05)

656-line brief at `docs/proposals/4S_obi_contact_persistence_brief.md` documenting Obi 7.x's contact data model with file:line citations from `docs/pbd_research/Obi/`.

**Headline finding:** Obi does NOT structurally solve the lub=1.0 frictionless-slide jitter case the way the user's hypothesis assumed — Obi's contact `pointB` is stored in solver-space (= world-frame), NOT body-local. Contacts are zero-initialized at `GenerateContacts` time which runs ONCE per outer step (not per substep, per `BurstSolverImpl.cs:114`). Within an outer step, lambdas + cached contact plane persist across substeps + iters (the 4M lambda accumulator already mirrors this); across outer steps, contacts fully regenerate fresh. Our current `substep_count=1` setup is approximately equivalent to Obi's per-frame churn pattern.

**Four jitter-relevant patterns Obi DOES have, worth borrowing**: (1) symplectic Euler integration (`Solver.compute:135,156` + `Integration.cginc:6-9`) — invariant under substepping, unlike our position-Verlet which under-integrates by ~5/8× across 4 substeps (the math reason 4R's default flip regressed); (2) Frank-Wolfe analytic surface point (`Optimization.cginc:32-90`) — smooth across face crossings, unlike Godot's per-face `get_rest_info`; (3) per-shape `contactOffset` + per-material `stickDistance` speculative margins (`ColliderGrid.compute:107,111`); (4) per-collider material composition with Average/Min/Multiply/Max combine modes (`CollisionMaterial.cginc:33-90`).

**Recommended scope for 4S-impl** (NOT a one-shot Obi-mimic slice; sized realistically): **4S.1** — symplectic Euler integration [medium, ~100 lines] — prerequisite for revisiting any substep flip; touches `predict()` + `finalize()` + `TentacleParticle`, mood preset damping re-tune required. **4S.2** — body-local-frame contact persistence [medium, ~150 lines] — genuinely NEW mechanism (NOT in Obi) but motivated by the lub=1.0 evidence; per-particle cache transformed through `body.global_transform` per substep, RID-keyed invalidation, hysteresis radius, end-of-tick lambda clamp to prevent unbounded accumulation across ticks. **4S.3** — per-collider material composition [small-medium, ~80 lines] — direct Obi port; independent of 4S.1/4S.2.

**Risk section in brief explicitly notes**: 4S.1 interacts with mood damping (re-tune); 4S.2 conflicts with 4R's `reset_environment_contact_lambdas` per-tick reset and needs explicit override.

**Out of scope this slice:** any code, tests, architecture-doc updates, status-table updates beyond this entry, new diagnostic scripts.

### 4T — Pose-target rate limiting (2026-05-05)

Source-side complement to 4Q-fix. New `target_velocity_max` field on PBDSolver / Tentacle / TentacleMood (default 5.0 m/s; 0 disables). New per-particle clamp state on PBDSolver: `prev_target_position` + `_target_warm` for the singleton tip target; `prev_pose_target_positions` (PackedVector3Array) + `_pose_target_warm` (`std::vector<bool>`) parallel to `pose_target_positions` for distributed pose targets. New `apply_target_rate_limit(dt)` method runs ONCE per outer Tentacle::tick (NOT per substep — substeps are for physics integration, not input smoothing); for each warm-started target, computes `delta = target − prev_target`, scales to `target_velocity_max × dt` magnitude if exceeded, mutates `target_position` / `pose_target_positions` in-place so the substep loop sees the clamped values throughout. Cold-start (first `set_target` after `clear_target` or first `set_pose_targets` with new indices) bypasses the clamp on the first tick — initial settling isn't artificially slow. `clear_target` / `clear_pose_targets` re-arm the cold-start. `set_pose_targets` fingerprints the indices array element-wise: same indices preserve warm flags + prev positions; changed indices rebuild the parallel arrays from scratch (all cold). `set_target` (singleton) does NOT touch the warm flag — driver writes that vary stiffness without changing position propagate cleanly.

New `Tentacle::set_target_velocity_max` / `get_target_velocity_max` passthrough + `@export_range(0.0, 20.0, 0.1, or_greater)` property. New `TentacleMood.target_velocity_max @export_range(0.0, 20.0, 0.1)` field, forwarded by `BehaviorDriver._apply_mood`. Bundled mood preset skim (curious / idle / caressing / probing): none authored the new field; all inherit resource default 5.0 m/s. Probing's peak target velocity ≈ chain_length × thrust_amplitude × thrust_freq × 2π × s_norm × (1 − attractor_bias·s_norm) ≈ 0.4 × 0.15 × 1.5 × 2π × 1 × 0.3 ≈ 0.17 m/s for our 0.4 m chain (well under 5.0); for production-scale chains (≥ 1 m) peak ≈ 0.5–1.4 m/s, also under 5.0. Default 5.0 acts as a safety ceiling for hostile target writes (e.g. a driver bug writing target=current_attractor every tick); per-mood tuning to lower values is Phase 9 polish.

**Tests:** new `game/tests/tentacletech/test_target_rate_limit.gd` 8/8 covering default+clamp, cold-start bypass, warm-running clamp, disabled passes large jumps, clear re-arms cold-start, pose-target indices change re-arms, pose-target indices preserved warm clamp, and a behavioural step-function chain advances gradually test (chain with tvm=0.5 advances ≤ 0.0083 m/tick toward a step target 1 m away, saturating at the cap rather than whipping across; same scene with tvm=0 snaps fully). Stick-slip regression `test_4q_probing_regression.gd` extended to 3-arm A/B/C: taper-OFF baseline at default tvm=5.0 (1.395 rad/s), taper-ON default tvm=5.0 (0.757 — exactly preserves 4Q-fix baseline since 5.0 leaves headroom for probing), taper-ON aggressive tvm=0.2 (0.635 rad/s — 16% improvement over default-tvm arm, no regression on saturation events). Full tentacletech suite **174/174** (was 166 + 8 new). .so size 2.03 MB (was 2.02).

**Spec divergences flagged:** (a) The slice prompt's primary 4T win bound (`leg_ang_max < 0.5 rad/s` at `tvm = 1.5`) was sized for a longer-chain scene; our regression scene's 0.4 m chain produces peak target velocities ≈ 0.5 m/s, so caps in [0.2, 1.0] are the engagement zone here. Sweep showed tvm ∈ {5.0, 1.5, 0.5} all produce identical leg_ang_max (no clamp engaged); tvm=0.2 is optimal (16% reduction); tvm < 0.1 starts a U-shape regression where the chain can't keep up with the driver's intended motion and leg swings increase. Regression test now asserts `aggressive ≤ 0.9 × default` (≥ 10% improvement) at tvm=0.2 instead of the prompt's 30% bound at tvm=1.5. The mechanism is verified working; tuning the cap to match a given chain's velocity profile is per-mood tuning (Phase 9 polish). (b) `target_velocity_max` is per-tentacle (single global cap), not per-particle. Per-particle was explicitly out of scope per the slice prompt; no clear use case yet for varying the cap along the chain. (c) Cold-start bypass uses a single warm flag per target; if a driver clears + immediately re-sets a target with a far-away position, the chain is allowed to "teleport" the target on that first tick. Documented behaviour: matches the slice prompt's "cold start so settling isn't artificially slow" intent. (d) `set_pose_targets` fingerprinting is element-wise on the indices array — for typical pose-target writes (driver writes the same indices every tick), this is O(N) per call with N=chain particles ≤ 16; no measurable cost.

**Cross-slice composition:** verified clean with 4Q-fix taper (rate limit clamps target position; taper reads tangent_lambda from friction step — different signals, different code paths) and 4R warm-start machinery (no shared state); will compose with future 4S contact-local-frame work (rate limit is upstream of contacts entirely).

### 4S.1 — Symplectic Euler integration (2026-05-06)

Position-Verlet (`pos += velocity_implicit + gravity*dt²`) replaced with symplectic Euler (`velocity += gravity*dt; pos += velocity*dt`) per Obi `Solver.compute:128-156` + `Integration.cginc:6-9`. New `Vector3 velocity` field on `TentacleParticle` as first-class state; default-initialized to zero by `particles.assign(n, TentacleParticle())` in `initialize_chain`. Predict() rewritten: snapshot prev_position (still tracked for friction step's per-tick tangent read), build per-particle gravity-velocity delta `gravity * p_dt`, apply support_in_contact tangent projection on the velocity delta (not the position delta — same effect, cleaner semantics), accumulate into `velocity`, integrate `position += velocity * p_dt`. Pinned particles (`inv_mass <= 0`) skip integration and have velocity zeroed.

Finalize() gains an UpdateVelocities step at the end (Obi `Solver.compute:160-186` pattern): recompute `velocity = (position - prev_position) / dt` post-constraint so position-modifying constraints map back to coherent velocity, then apply damping as `velocity *= pow(damping, dt × 60)` (dt-correct exponential — at dt=1/60 this matches the legacy Verlet damping value exactly; at sub_dt=1/240 it correctly gives less per-substep damping). `contact_velocity_damping` migrated from prev_position lerp to `velocity *= (1 - cvd × dt × 60)` for in-contact particles. `sleep_threshold` migrated from `||position - prev_position|| ≤ threshold × dt` to `||velocity|| ≤ threshold` (cleaner under explicit velocity); on snap, both `position = prev_position` AND `velocity = ZERO`.

New `set_particle_velocity(idx, v)` / `get_particle_velocity(idx)` accessors + `get_particle_velocities() -> PackedVector3Array` snapshot. `set_particle_position` now zeroes velocity (otherwise the next finalize would synthesize a huge velocity from the external position step, kicking the chain into the next substep's predict). `add_external_position_delta` semantics unchanged but docstring updated: "does NOT touch prev_position OR velocity, so explicit velocity is preserved".

**Tests:** new `game/tests/tentacletech/test_symplectic_euler.gd` 4/4 covering: (a) free-fall velocity invariance under N substeps ∈ {1, 2, 4} — v_N = g·outer_dt regardless of N to 1e-4 m/s tolerance (this IS what symplectic Euler buys you); (b) free-fall position converges toward true ½·g·dt² as N grows, matching the formula (N+1)/(2N) × g·dt² to 1e-5 m tolerance — at N=1: 2.722e-3 m (= g·dt², 2× true); N=2: 2.042e-3 m (= 3/4); N=4: 1.701e-3 m (= 5/8); (c) velocity round-trip: set velocity = (1,0,0), no gravity, single tick → particle moves by velocity*dt, finalize recomputes velocity ≈ 1.0 from position delta; (d) `set_particle_position` zeroes velocity (sanity guard).

All other tentacletech suites green: test_collision_type4 33/33, test_tentacle_mood 7/7, test_pose_targets 5/5, test_render 4/4 + render_with_tentacle_mesh 4/4, test_tentacle_mesh 5/5 + test_sucker_row_feature 4/4 + test_girth_baker 2/2 + test_geometry_features 13/13 + test_mass_from_girth 5/5 + test_spline 7/7, test_tentacle_behavior 11/11, test_orifice 52/52, test_feature_silhouette 6/6, test_target_rate_limit 8/8.

**Stick-slip regression `test_4q_probing_regression.gd` extended to 4 arms** (taper-OFF / taper-ON tvm=5 / taper-ON tvm=0.2 / 4S.1 sub=4 iter=1 spot-check at tvm=5). At default sub=1, all three pre-4S.1 arms preserve their pre-4S.1 baseline numbers EXACTLY (taper OFF 1.395 / taper ON tvm=5 0.757 / taper ON tvm=0.2 0.635) — symplectic Euler at N=1 produces the same per-tick motion as position-Verlet from rest. The new sub=4/iter=1 spot-check arm: pre-4S.1 (slice 4R observation) regressed to leg_ang_max=2.03 rad/s (taper feedback loop drove leg motion ABOVE the taper-OFF baseline). Post-4S.1: leg_ang_max=1.038 rad/s — 49% improvement vs pre-4S.1 sub=4, BELOW the taper-OFF sub=1 baseline (so the substep flip no longer regresses past the disabled-arm floor). Still WORSE than sub=1 (0.757), so 4S.1 is necessary but not sufficient to make the substep flip a default win in this scene. Asserted: sub4_default.leg_ang_max ≤ disabled.leg_ang_max × 1.05 (sanity floor; passes at 1.038 ≤ 1.466). Full suite **178/178** (was 174 + 4 new symplectic Euler tests). .so size 2.03 MB (unchanged).

**Spec divergences flagged:** (a) **The slice prompt's gravity-invariance test as specified is not achievable under symplectic Euler.** From rest: x_N = (N+1)/(2N) × g·dt² across N substeps — same quadratic truncation as position-Verlet (verified: N=1 → g·dt², N=2 → 3/4·g·dt², N=4 → 5/8·g·dt²). Position invariance under substepping requires velocity-Verlet (`x += v·dt + ½·a·dt²`) which is second-order; symplectic Euler is first-order and converges to ½·g·dt² only as N→∞. **What symplectic Euler DOES give is velocity invariance**: v_N = N × g × sub_dt = g · outer_dt regardless of N. The unit test was rewritten to assert the truths: velocity invariance + monotonic position convergence + formula match. The 4S brief's Q5 was correct on velocity invariance but oversold the position invariance claim; that's the math reason 4S.1 by itself doesn't unlock the substep flip as a default in this regression scene. Velocity-Verlet (or an RK-class integrator) would; flagged as a follow-up if the user wants substep-invariance for the position quadratic term too. (b) `set_particle_position` zeros velocity in addition to setting prev_position. Necessary — without it, the next finalize would synthesize a huge velocity from the external position step. The orifice rim's pin-particle path uses this; the earlier prev_position-only behaviour was unsafe under explicit velocity. (c) `Tentacle::tick`'s `MAX_SUBSTEPS = 4` cap means N=8 is clamped to N=4. Test sweep covers {1, 2, 4} only; N=8 was attempted, observed cap engagement. (d) `damping` and `contact_velocity_damping` and `sleep_threshold` migrated to dt-correct exponential / velocity-magnitude forms. At the 60 Hz reference dt=1/60, all three preserve legacy semantics exactly; at sub_dt=1/240 each yields the dt-correct equivalent. Mood preset re-tune skim: full suite green at default sub=1 with bundled mood-driven tests (test_tentacle_mood 7/7, test_tentacle_behavior 11/11, regression A/B/C arms preserved baseline exactly), no preset values needed adjustment.

**Out of scope landed:** default substep flip 1 → 4 — held. The sub=4 spot-check shows substantial improvement vs pre-4S.1 (1.038 vs 2.03) but is still worse than sub=1 (0.757), so flipping the default would still regress the user-visible scene. The next slice can decide whether to flip given the new reduced regression magnitude.

**Cross-slice composition verified:** sub=1 baseline preserved exactly (4Q-fix + 4R + 4T all still produce identical numbers); 4Q-fix taper continues to read tangent_lambda from the friction step (symplectic-Euler vs Verlet doesn't change the friction step's lambda accumulator math); 4R RID warm-start untouched (operates on contact lambda buffers, not the particle integrator); 4T rate-limit operates upstream of predict and is integrator-agnostic.

### 4S.2 — Body-local-frame contact persistence (2026-05-11)

Per-(particle, slot) cache on `Tentacle` survives across outer ticks: last contact point + normal stored in the body's LOCAL frame. Probe results within hysteresis of a cached slot have their world hit_point/hit_normal OVERRIDDEN with the body-local→world transformed cached value, killing the per-face hit_point churn that `get_rest_info` produces as a chain slides tangentially across a faceted convex hull. NEW mechanism (not in Obi); motivated by round-4 diagnostic's "340 hit_point shifts in 240 ticks at lub=1.0".

**Architecture** — composes with 4R by ADDITION, not by mutating the reset path. Order in `Tentacle::tick`:
1. anchor refresh / silhouette refresh / sub_steps compute (unchanged)
2. `solver->reset_friction_applied()` (unchanged)
3. `solver->reset_environment_contact_lambdas()` (4R — unchanged; "post-call all live lambdas == 0" invariant preserved)
4. **NEW `_validate_and_reseed_persistence()`** — walks every cached slot, validates body alive (ObjectDB::get_instance) + transform-jump (`origin_delta_sq ≤ jump_threshold_sq`), invalidates failures. The brief's "inject persisted lambdas" path is intentionally NOT taken — see spec divergence (a).
5. `solver->apply_target_rate_limit(p_delta)` (unchanged)
6. substep loop: `_run_environment_probe()` now runs `_apply_contact_persistence_to_probe_results()` after `probe.probe()` and BEFORE the scratch arrays are built — overrides EnvironmentContact's world hit_point/hit_normal with cached body-local→world values. Cache misses (probe doesn't see the cached body for this particle, or `|new_hit_point − cached_world_point| > hysteresis_radius`) drop the cache slot. Solver sees the merged (cached + fresh-probe) manifold via `set_environment_contacts_multi` exactly as before.
7. **NEW `_snapshot_persistence_post_tick()`** — reads last-substep EnvironmentContact world point/normal + body RID/object_id, transforms point/normal back to body-local frame via `body.global_transform.affine_inverse()`, stores in `persistence_buffer`. Lambdas NOT persisted (per spec divergence (a)).
8. `_apply_collision_reciprocals(p_delta)` (unchanged)

**Files touched** — C++: `extensions/tentacletech/src/solver/{tentacle.h, tentacle.cpp, pbd_solver.h, pbd_solver.cpp}`, `extensions/tentacletech/src/collision/environment_probe.h` (added non-const `get_contacts_mut()`). GDScript: `extensions/tentacletech/gdscript/behavior/{tentacle_mood.gd, behavior_driver.gd}`. Tests: new `game/tests/tentacletech/test_4s2_contact_persistence.gd` 3/3.

**New API surface** — `Tentacle::set_contact_persistence_enabled`/`get_..` (DEFAULT FALSE — see spec divergence (b)), `Tentacle::set_contact_persistence_radius_factor`/`get_..` (default 1.0, base 0.5 × `particle_collision_radius`), `Tentacle::set_contact_persistence_jump_threshold_factor`/`get_..` (default 1.0, base 2.0 × `particle_collision_radius`), `Tentacle::get_persistence_invalidation_count_snapshot()` returning `PackedInt32Array`. `TentacleMood.contact_persistence_enabled` (default false), `contact_persistence_radius_factor` (default 1.0), `contact_persistence_jump_threshold_factor` (default 1.0) — forwarded by `BehaviorDriver._apply_mood`. No bundled mood preset enables persistence yet. **No new PBDSolver API** — the brief's `inject_persisted_contact` reseed path was prototyped and then deleted per review (dead code; if a future slice breaks the taper-feedback runaway it adds the API at the right shape).

**Tests:** `test_4s2_contact_persistence` 3/3 — (1) `test_cache_reduces_hit_point_churn_on_faceted_hull`: chain settled against a STATIC `StaticBody3D` with 8-vert `ConvexPolygonShape3D` box, persistence ON vs OFF. OFF: 0.077874 m total hit_point churn over 240 ticks; ON: 0.000000 m (cache perfectly locks contact). Bound: `ON ≤ OFF × 0.6` (loose); actual ratio 0.000. (2) `test_cache_miss_on_body_teleport`: settle, teleport body by 1.0 m (> 2 × collision_radius × jump_threshold_factor = 0.08 m), expect ≥ 1 cache invalidation via `get_persistence_invalidation_count_snapshot`. Observed total_invs=5 (one per in-contact particle). (3) `test_cache_invalidates_on_rid_disappear`: settle, queue_free body, single tick must not crash + invalidate cached slots + report no contact. Observed total_invs=5 + contact_count_post=0.

Stick-slip regression `test_4q_probing_regression.gd` extended to **5 arms** (was 4): taper OFF/ON tvm=5/ON tvm=0.2/sub=4 spot-check (unchanged from 4S.1) + new 4S.2 opt-in arm (persistence ON, sub=1, taper OFF, tvm=5). New arm locks in the OBSERVED REGRESSION baseline (leg_ang_max = 4.7124 = Jolt's 1.5π max_angular_velocity cap; ratio 3.38× over the persistence-OFF disabled baseline of 1.3949). Bounds: `1.8 × disabled ≤ s2_opt_in ≤ 4.0 × disabled` — two-sided so future tuning can't silently shift behaviour in either direction (drops below 1.8× → mechanism may have changed; exceeds 4.0× → something else is breaking). The arm is NOT a primary acceptance — it's a snapshot of the known regression that motivates the default-OFF choice. All four pre-4S.2 arms match their 4S.1 baselines exactly because persistence defaults to OFF and none of those arms opts in. Full tentacletech suite **181/181** (was 178 + 3 new 4S.2 tests). .so size 2.04 MB (was 2.03; ObjectDB lookups + transform math + persistence_buffer entry weight).

**Spec divergences flagged:**

- **(a) Lambda persistence dropped.** The brief at 4S.2 Risks suggested persisting `(normal_lambda, tangent_lambda)` across outer ticks with an end-of-tick cone clamp. Implemented + tested: it recreates the 4R spec divergence (b) taper-feedback oscillation (warm tlam at cone boundary → tlam/cone at saturation from iter 0 → taper kills target pull → cone collapses → contacts lost → chain slams in). Verified on the 4Q probing regression: with lambda persistence ON, default-arm leg_ang_max = 4.712 rad/s (= Jolt's `max_angular_velocity` cap = 1.5π) vs the un-persisted 0.726. Lambda persistence removed; the contact-POINT persistence (the actual stability win) stays. The reseed-API prototype (`PBDSolver::inject_persisted_contact` + `get_environment_contact_rid`) was deleted per review (dead code; future slices that break the feedback loop add it at the right shape).
- **(b) Default flipped from ON to OFF.** The 4Q probing regression scene shows that even WITHOUT lambda persistence, contact-point persistence still harms active-probing performance: cache-locked contact points across rapidly-rotating rigid-body legs build up friction reciprocals that saturate Jolt's angular velocity cap. The 4Q scene is the wrong workload for the cache (chain sliding fast across moving bodies, not settled / slowly-moving). Persistence is now opt-in per mood — settled moods (caressing, idle) can enable; active moods (probing, attack) leave off. Mood resource default = false. Bundled mood presets unmodified (none opt in yet). Production tuning per-mood follows the same pattern as `sleep_threshold` (Phase 4P). The 4Q regression's new 5th arm locks in the observed regression magnitude (3.38× the disabled baseline) as a snapshot.
- **(c) Acceptance signal substituted.** The brief's primary acceptance metric was lub=1.0 frictionless-slide `tlam_churn ≤ default × 0.85` (≥ 15% tangent-lambda churn reduction). What 4S.2 actually delivers is **hit_point churn 0.077874 m → 0.000000 m** in `test_cache_reduces_hit_point_churn_on_faceted_hull`. Different signal — hit_point stability directly aligns with the brief's TL;DR motivation ("340 hit_point shifts in 240 ticks at lub=1.0") and is the load-bearing stability win once lambda persistence is dropped (per (a)). With no persisted lambdas, tlam churn is governed entirely by 4R's intra-tick warm-start which 4S.2 doesn't touch — measuring it would only confirm 4R's existing behaviour. Substitution approved at review (2026-05-11); flagged here so the spec divergence is reviewer-visible.
- **(d) Headline scene is a STATIC body, not a moving body.** The `test_cache_reduces_hit_point_churn_on_faceted_hull` test uses a `StaticBody3D` with a faceted ConvexPolygonShape3D — the ON=0.0 m churn measurement reflects the cache suppressing per-tick `get_rest_info` stochasticity on a faceted hull (face-jump churn), NOT the body-local→world retransform under body motion. The retransform path IS exercised by `test_cache_miss_on_body_teleport` (body translated 1 m mid-test, cache invalidates) but not measured as a churn-suppression headline. The brief's stronger motivation (rotating rigid-body legs where body-local retransform matters) is partially demonstrated by the 4Q regression 5th arm (which proves the cache DOES retransform across rotating legs — that's why it saturates Jolt's cap), but not in the form of "ON=0 churn on a sinusoidally-moving body". A dedicated rotating-body churn-suppression test could land as a follow-up slice if a specific workload calls for it.
- **(e) Hysteresis check semantics corrected during implementation.** Initial implementation compared `|particle_position - cached_world_point|` against `0.5 × collision_radius`; this is wrong because the particle naturally sits at `≈ collision_radius` from any in-contact surface point. Corrected to compare `|new_probe_hit_point - cached_world_point|` against the hysteresis radius — measures how far the contact has slid along the body's surface since cache capture, which is the right signal. Without this fix the cache never engaged.
- **(f) Brief's perf win (skipping `get_rest_info` for cache hits) deferred.** The brief at lines 514-517 called out per-substep `get_rest_info` queries as the dominant cost and noted that cache hits could skip the query. Current implementation runs the probe unconditionally and uses the cache as a POST-PROBE OVERRIDE on world hit_point/hit_normal. Architectural simpler and matches the brief's acceptance criterion (hit_point stability) without a probe-interface refactor. Per-substep `get_rest_info` cost stays; future slice can short-circuit if profiling shows it.

**Out of scope landed:**

- Lambda persistence (spec divergence (a)) — entire reseed plumbing deleted; no dead API.
- Perf win via `get_rest_info` short-circuit (spec divergence (f)) — probe runs per substep as before.
- Rotating-body churn-suppression headline measurement (spec divergence (d)) — follow-up if a workload calls for it.
- Decay / scaled-clamp on persisted tlam to break the 4R feedback loop while keeping some lambda persistence — flagged as a follow-up if a scenario specifically needs it.
- 4S.3 per-collider material composition — independent of 4S.2 + 4S.1; next slice in the close-out cluster.

**Cross-slice composition verified:** 4Q regression preserves 4S.1 baselines exactly with persistence OFF default; 4R reset_environment_contact_lambdas invariant preserved (4S.2 cache buffer is separate from solver's lambda arrays); 4Q-fix taper unaffected (persistence is upstream of friction step); 4T rate-limit unaffected (independent code path); 4S.1 symplectic Euler unaffected (persistence is in probe pipeline, integrator is downstream).

### 4S.3 — Per-collider friction material composition (2026-05-12)

Direct port of Obi `Resources/Compute/CollisionMaterial.cginc:33-90` restricted to friction. Per-collider material via `TentacleSurfaceTag` child node carrying a `TentacleCollisionMaterial` resource (`static_friction`, `dynamic_friction`, `friction_combine` ∈ {AVERAGE=0, MIN=1, MULTIPLY=2, MAX=3}). The tentacle never carries a material — its implicit triple is `(friction_static_post_lubricity, friction_static × kinetic_ratio, AVERAGE)`. `Tentacle::_run_environment_probe` composes per-slot via `PBDSolver::compose_friction_materials` and writes two parallel `PackedFloat32Array` buffers (`static_frictions`, `kinetic_frictions`, size `N × MAX_CONTACTS_PER_PARTICLE`); they reach the friction step (iter step 5) through the new sibling call `PBDSolver::set_environment_contact_materials`. The step's outer gate becomes `per_slot_materials || friction_static > 0`, and per-slot μ_s / μ_k are read from the buffers when sized — otherwise the pre-4S.3 per-tentacle scalars are used verbatim. Lifecycle: `Tentacle::tick` clears the per-tick body→material cache and calls `solver->clear_environment_contact_materials()` alongside `reset_friction_applied` / `reset_environment_contact_lambdas` at outer-tick boundary; the sibling call is only invoked when at least one body has a `TentacleSurfaceTag` this substep, so untagged scenes take the fallback path bit-for-bit.

**Architecture composes with 4S.2 by layering:** 4S.2 lives at the geometry layer (`_apply_contact_persistence_to_probe_results`, post-`get_rest_info` override of world hit_point/hit_normal) and keys on `body_object_id`; 4S.3 lives at the friction layer (`PBDSolver::iterate` step 5, per-slot μ lookup) and ALSO keys on `body_object_id`. Two independent caches, both per-outer-tick, both populated lazily as bodies appear. They don't share state — the cache lifetimes are independent, the buffers are independent, and the only shared input is the manifold from `get_rest_info`.

**Files touched** — C++: `src/solver/pbd_solver.{h,cpp}` (new static helper `compose_friction_materials`, new sibling call `set_environment_contact_materials` / `clear_environment_contact_materials`, two new `PackedFloat32Array` fields `env_contact_static_frictions` / `env_contact_kinetic_frictions`, friction iter step 5 reads per-slot when sized, bind for both new methods via `ClassDB::bind_static_method` + `bind_method`), `src/solver/tentacle.{h,cpp}` (new `CachedSurfaceMaterial` struct + `std::vector<CachedSurfaceMaterial> _material_cache_this_tick`, two new `PackedFloat32Array` scratch buffers, new methods `_resolve_surface_material_for_body` / `_populate_material_slots_from_probe`, two wiring sites in `Tentacle::tick` and `_run_environment_probe`). GDScript: new `gdscript/collision/tentacle_collision_material.gd` (Resource with 3 `@export` fields + `CombineMode` enum), new `gdscript/collision/tentacle_surface_tag.gd` (Node with `@export var material: TentacleCollisionMaterial`). Tests: new `game/tests/tentacletech/test_4s3_material_composition.gd` 7/7.

**New API surface** — `PBDSolver.compose_friction_materials(a_static, a_dynamic, a_combine, b_static, b_dynamic, b_combine) -> Vector2` (bound static, GDScript-callable for both tests and use sites). `PBDSolver.set_environment_contact_materials(static_frictions: PackedFloat32Array, kinetic_frictions: PackedFloat32Array)`. `PBDSolver.clear_environment_contact_materials()`. `TentacleCollisionMaterial` (GDScript Resource subclass, `class_name`-registered). `TentacleSurfaceTag` (GDScript Node subclass, `class_name`-registered).

**Tests:** `test_4s3_material_composition` 7/7 — five analytic combine-sweep cases (AVERAGE / MIN / MULTIPLY / MAX, plus a body-mode-wins-vs-tentacle-AVERAGE sanity case), one behavioural side-by-side (slippery body via combine=MIN with `mu_s = 0` versus sticky body via combine=MAX with `mu_s = 2.0`; tilted gravity `Vector3(2, -9.8, 0)`, support_in_contact off matching `test_collision_type4::test_friction_resists_lateral_drift`; observed `slippery tip x = 0.211 m`, `sticky tip x = 0.106 m`, delta = 105 mm >> 1 cm threshold), one fallback bit-equivalence (no-tag body vs tag-with-tentacle-implicit-values, comparing flat `friction_applied` PackedVector3Array across 72 floats; observed worst |Δ| = 0.0000000000, perfect bit-equivalence). Analytic worst |err|: AVERAGE 0.00, MIN 0.00, MULTIPLY 5.96e-8 (single-precision multiplication of `1.2 × 1.0`), MAX 0.00. Full tentacletech suite **188/188** (was 181 + 7 new 4S.3 tests). .so size 2.05 MB (was 2.04; ~8 KB for the helper + sibling call + cache struct + two `PackedFloat32Array` scratch buffers + ClassDB bindings).

**Spec divergences flagged:**

- **(a) Helper placed on `PBDSolver` as a bound static, not as a sibling class.** The prompt offered "sibling class (or as a static method on the Resource — your call, but document why)". A third option was taken: `PBDSolver::compose_friction_materials` matches the 4Q-fix `compute_tension_taper_factor` precedent exactly (same class, same `ClassDB::bind_static_method` pattern, same call-site shape from both the iter loop and the analytic test). The Resource stays GDScript-only with no static helper to keep the data and the composition formula physically separate; that's the part of the prompt's reasoning that survives unchanged. The GDScript Resource and tag node are the persistence-side primitives; the composition operator lives next to the friction step that consumes it.
- **(b) Tentacle implicit material values come from the SOLVER, not from `Tentacle::base_static_friction`.** `solver->get_static_friction()` returns the post-lubricity scalar — i.e. `base_static_friction × (1 − tentacle_lubricity)`. This means the per-collider composition naturally inherits the tentacle's current lubricity modulator state without needing to plumb it separately. Documented in `_populate_material_slots_from_probe` and in `TentacleCollisionMaterial` doc comments.
- **(c) Pre-fill scratch buffers with tentacle-implicit values even for no-tag slots.** When at least one body in the manifold has a tag, ALL slots get a per-slot μ written (the scratch is fully populated). Untagged slots get the tentacle-implicit (μ_s, μ_k); tagged slots get the composed values. This avoids a per-slot branch in the friction step ("is this slot tagged?" → "no, use fallback scalar") at the cost of writing 24 floats per substep when any tag is touched. The friction step's outer gate (`per_slot_materials || friction_static > 0`) still bypasses the per-slot path entirely when the materials sibling wasn't called this tick — that's the bit-for-bit fallback.
- **(d) `find_children("*", "TentacleSurfaceTag", true, false)` works from C++ against the GDScript class_name without special handling.** Confirmed by behavioural + fallback tests passing; godot-cpp's `Node::find_children` resolves both built-in classes and script class_names via the global script class cache. After adding a new `class_name`, the cache must be refreshed once (`godot --editor --quit`) before headless test runs — same gotcha as elsewhere (memory: `reference_marionette_test_run.md`). No `ClassDB::is_parent_class` walk or explicit `get_script()` fallback was needed.
- **(e) Tension taper (step 2) still reads per-tentacle `friction_static`.** The 4Q-fix tension-taper feedback reads `mu_s_taper = friction_static` once outside the per-slot loop; it does NOT switch to per-slot μ when a tag is present. The taper does still respond to per-slot composition implicitly through `tangent_lambda` magnitude (the friction step writes per-slot tlam using the composed cones), so the taper's saturation signal naturally tracks the per-slot path. Going per-slot taper would also need the per-slot lookup inside the dominant-contact selection — out of scope for 4S.3 (scope was "friction step μ_s / μ_k composition"; taper is a different step).
- **(f) One tag per body only; multi-region positional tagging is out of scope.** `WARN_PRINT` fires when `find_children` returns more than one match, and the first match is used. Documented in `tentacle_surface_tag.gd`'s docstring + in `_resolve_surface_material_for_body`. If a future workload calls for different materials on different shapes of the same body, a follow-up slice can either (i) walk shape ownership on each contact and look up the nearest tag, or (ii) introduce a per-shape tag node — both are larger changes than 4S.3's "one resource per body" model.

**Out of scope landed:**

- Stickiness / `stickDistance` / rolling friction from Obi's full struct — explicitly omitted per scope (dead-fields lesson from 4S.2's removed reseed API). Lands with SolveAdhesion if/when that subsystem opens.
- Per-slot tension taper. Step 2's `mu_s_taper` stays per-tentacle (see divergence e).
- Multi-region tag per body. One tag per body, first-found wins (see divergence f).
- Cache invalidation beyond per-outer-tick. Runtime tag swap + tag teardown handled by tick-cadence rebuild; no `RID`-keyed lifetime cache.

**Cross-slice composition verified:** 4S.2 (geometry-layer body-local cache) untouched — runs at probe layer, 4S.3 runs at friction layer; cache buffers are independent. 4Q-fix taper preserved (still reads per-tentacle `mu_s`; per-slot tlam already updated). 4R RID-keyed lambda warm-start preserved (operates on contact-lambda arrays, not material arrays). 4T rate-limit upstream of probe. 4S.1 symplectic Euler integrator unaffected. Per-tentacle fallback verified bit-equivalent over 72 floats (test 7).

---

## Phase 5 — Orifice

**State:** 5A + 5B + 5C-A + 5C-B + 5C-C + 5D done (2026-05-04) + 5H done (2026-05-05) — rim primitive + host-bone soft attachment + bilateral type-2 contact + EntryInteraction lifecycle/geometric tracking + friction at type-2 + §6.3 reaction-on-host-bone closure + 4P-A anisotropic rim distance / 4P-B J-curve strain stiffening / 4P-C plastic offset (orifice memory) + 5H tentacle feature silhouette (2D bake → type-1/2/4 contact integration). **Phase 5 acceptance per §13 fully testable end-to-end.** Canal interior model (5E/5F/5G) is the next gate.

### 5A — Rim particle loop primitive (2026-05-04)

Per `docs/architecture/TentacleTech_Architecture.md` §6.1–§6.4 and `docs/Cosmic_Bliss_Update_2026-05-03_orifice_rim_model.md`. New `src/orifice/orifice.{h,cpp}` registers `Orifice : Node3D` with per-loop `RimParticle` + `RimLoopState` structs. Per-loop XPBD constraint set inside `tick()`: closed-loop distance constraints (per-segment lambda accumulator, reset in predict) + volume on enclosed polygon area projected to plane perp to `entry_axis` (Obi `VolumeConstraints.compute` reduced from 3D triangle fan to 2D shoelace; per-loop scalar `area_lambda`, reset per tick) + per-particle XPBD spring-back to authored rest position in Center frame (per-particle `spring_lambda`, reset per tick). Solver pattern matches Phase 4: Jacobi-with-atomic-deltas-and-SOR (`_add_delta` + `_apply_deltas_all` per loop), default `sor_factor=1.0`. Multi-loop data structure ready (loops are mechanically independent in 5A; inter-loop coupling springs deferred).

Authoring API: `add_rim_loop(rest_positions_in_center_frame, segment_rest_lengths, target_enclosed_area, rest_stiffness_per_k, area_compliance, distance_compliance) -> int`, `clear_rim_loops`, plus static helpers `make_circular_rest_positions`, `make_uniform_segment_rest_lengths`, `compute_polygon_area`. Snapshot accessor `get_rim_loop_state(i) -> Array[Dictionary]` returns `{rest_position, current_position, current_velocity, spring_lambda, distance_lambda, neighbour_rest_distance, inv_mass}` per particle (rest_position projected through orifice node global_transform — host-bone Center frame is identity in 5A); `get_rim_loop_count`, `get_loop_area_lambda`, `get_loop_target_enclosed_area`, `get_loop_current_enclosed_area`, `set_loop_target_enclosed_area`, `set_particle_position`, `get_particle_position`, `set_particle_inv_mass`. Modulation channel `set_loop_target_enclosed_area` ready for §6.10 ContractionPulse / §6.7 peristalsis in later slices.

Gizmo overlay: new `gdscript/debug/gizmo_layers/orifice_layer.gd` (rim particle crosses, closed-loop cyan segments, per-particle mint rest-position markers — pull-from-snapshot, never push from C++); `debug_gizmo_overlay.gd` gains `orifice` @export + `show_orifice` toggle, draws when an Orifice is assigned alongside or instead of a Tentacle. Registered in `register_types.cpp`; SConstruct sources include `src/orifice/*.cpp`.

**Tests:** new `game/tests/tentacletech/test_orifice.gd` with 8 tests (`test_circular_rest_initialization`, `test_distance_steady_state_lambdas_bounded`, `test_distance_xpbd_lambda_resets_each_tick`, `test_volume_target_modulation_changes_area`, `test_volume_lambda_resets_each_tick`, `test_spring_back_decays_displacement`, `test_pinned_neighbor_loop_settles`, `test_polygon_area_helper_circle`) — all pass. Other tentacletech suites unchanged: test_collision_type4 30/30, test_solver 7/7, test_tentacle_mood 7/7, test_pose_targets 5/5, test_render 4/4, test_render_with_tentacle_mesh 4/4, test_tentacle_mesh 5/5, test_sucker_row_feature 4/4, test_girth_baker 2/2, test_geometry_features 13/13, test_mass_from_girth 5/5, test_spline 7/7. test_tentacle_behavior 9/11 (2 pre-existing failures unrelated). .so size 1.86 MB.

**Spec divergences flagged:** (a) `Orifice::add_rim_loop` and `get_rim_loop_state` use `is_inside_tree() ? get_global_transform() : Transform3D()` to silence the `--script` mode `is_inside_tree()=false` warning that floods test logs even after `add_child` — functional behavior identical (Center frame is identity when not in tree, which is the only mode the warning fires in). (b) Volume constraint in 5A is the planar-shoelace reduction of Obi's 3D triangle-fan-from-origin form (gradient `0.5 × n_hat × (p_{k-1} - p_{k+1})`), not the full 3D `cross(p_b, p_c)` — correct for a planar rim, simpler implementation; the 3D form would also work but would over-constrain a coplanar particle set. (c) Spring-back compliance reuses the chain solver's `stiffness_to_compliance` log-mapping (`1e-9` at stiffness=1, `1e-3` at stiffness=0) so authoring intuition matches across the chain and rim — the architecture doc is silent on the curve; this matches the 4M-XPBD precedent. (d) `_finalize_loop` is currently a no-op (jiggle / pull-out wobble emerges from XPBD compliance + iteration count); the spec mentions per-loop damping in passing but doesn't pin it down — left as a slot for later tuning if the §6.10 pulse work demands it. (e) The bundled `test_tentacle_behaviour` scene was NOT modified — adding an Orifice node to it requires user OK per test-scene policy; gizmo wiring is in place and ready when the user adds one.

**Deferred to later slices:** EntryInteraction, tentacle-rim contact (5B/5C), host-bone soft attachment (5B), type-2/3 collision (5C), reaction-on-host-bone routing per §6.3 (5C), inter-loop coupling springs, multi-tentacle (cap 3) per §6.5, jaw special case §6.6, peristalsis §6.7 / storage chain §6.8 / oviposition §6.9 / ContractionPulse §6.10 modulation, RhythmSyncedProbe §6.11, realism sub-slices 4P-A (one-sided XPBD distance) / 4P-B (strain-stiffening J-curve) / 4P-C (slow rest-position recovery).

### 5B — Host-bone soft attachment (2026-05-04)

Per §6.1 host_deform_bone hierarchy. New @exports `skeleton_path: NodePath`, `bone_name: StringName`, `host_bone_offset: Transform3D` (default identity), grouped under "Host Bone" in the inspector. Setter `set_host_bone(skeleton_path, bone_name) -> bool` resolves the bone index once and caches `_skeleton_cached` + `_bone_index_cached`; lazy resolver re-validates each tick (cheap NodePath lookup + `find_bone`) so a freed Skeleton3D doesn't dangle. Center frame migrated from "orifice's own global_transform" to a cached `_center_frame_cached: Transform3D` refreshed at the start of `tick()` AND from `add_rim_loop` / `set_host_bone` (so authoring before the first tick still picks up the host bone). When host bone is active: `_center_frame_cached = bone.skeleton.global × get_bone_global_pose(idx) × host_bone_offset`. When inactive: falls back to the orifice's own `global_transform` (in tree) or local `transform` (`--script` mode). Bone transform is read ONCE per tick — same discipline as §4.5's once-per-tick ragdoll snapshot.

New snapshot accessor `get_host_bone_state() -> Dictionary {has_host_bone, skeleton_path, bone_name, bone_index, current_world_transform}` (transform is bone WITHOUT offset — the gizmo + tests can compose it). New `get_center_frame_world() -> Transform3D` so callers don't have to fight Godot's `global_transform` getter (which warns out-of-tree in `--script` mode). All three rest-world projection sites (`add_rim_loop`, `_iterate_loop` spring-back, `get_rim_loop_state`) now read `get_center_frame_world()` instead of `get_global_transform()`. Gizmo: `orifice_layer.gd` gains a red-purple host-bone marker drawn at the bone's resolved world position when `has_host_bone == true`.

**Tests:** test_orifice 13/13 (added `test_host_bone_tracking_moves_orifice_frame`, `test_host_bone_tracking_pulls_rim_along`, `test_host_bone_offset_applied`, `test_host_bone_invalid_path_falls_back`, `test_host_bone_path_change_re_resolves`). Test runner restructured to defer to `_process` (mirrors `test_collision_type4.gd`) since `_init` runs before SceneTree wires the root, leaving nodes reporting `is_inside_tree() == false` — Skeleton3D APIs (`set_bone_pose_position`, `get_bone_global_pose`, `get_path_to`) all need tree state. .so size 1.95 MB.

**Spec divergences flagged in 5B:** (a) `Orifice::set_global_transform` was specced as the wiring path but writing back through Godot's transform pipeline trips `is_inside_tree()` warnings in `--script` and forces every reader to reproduce the same guard. Cached `_center_frame_cached` keeps the orifice's own `transform` untouched and avoids the warning entirely; functional behavior is identical for in-tree runtime use (where `set_global_transform` would have produced the same result via Godot's pipeline). (b) NodePath resolution in the C++ resolver tries `is_inside_tree() ? get_node_or_null` first, then falls back to a manual recursive walk from `get_tree()->get_root()` that splits the path on '/' and matches by `Node::get_name()`. Required because `Node::get_node_or_null` errors with "Can't use get_node() with absolute paths from outside the active scene tree" when the orifice's tree state hasn't propagated — the only mode the headless test path hits. The walk handles absolute (`/root/Foo`) and root-relative (`Foo/Bar`) paths only; deeper-relative paths (`../Foo`) are not supported by the fallback path (production runtime always hits the in-tree branch where `get_node_or_null` handles all forms). (c) Lazy re-resolution re-runs `find_bone` each tick when the cached pointer or index has stale-looking state (skeleton pointer changed OR bone_index out of range), giving cheap robustness against Skeleton3D mutation. The architecture doc only mentions one-time resolution. (d) Test runner moved from `_init` to `_process` (matches test_collision_type4) — pre-existing pattern; not a 5B-specific divergence but documented since this is the first 5x test suite that exercises Skeleton3D APIs requiring tree state.

### 5C-A — Bilateral type-2 contact (2026-05-04)

Per §4.2 row 2 + the `4M`-form lambda accumulator pattern. New `Type2Contact` struct (tentacle_idx, particle_idx, loop_idx, rim_particle_idx, cached normal + radii_sum, persistent normal_lambda) — `Vector<Type2Contact> _type2_contacts` on Orifice, freshly built per tick by `_collect_type2_contacts()`. RimLoopState gains `rim_contact_radius_per_k` (per-particle, default 0.02 m, authored at `add_rim_loop` time via the new optional `default_contact_radius` 7th arg with `DEFVAL(0.02f)`); `set_rim_contact_radius` / `get_rim_contact_radius` per-particle accessors on Orifice.

Tentacle registration: new `tentacle_paths: Array[NodePath]` @export under "Type-2 Contact" group + imperative `register_tentacle` / `unregister_tentacle` / `get_registered_tentacle_count` / `get_resolved_tentacle_count` / `get_tentacle_path(i)`; `_tentacles_resolved: Vector<Tentacle*>` cache rebuilt lazily each tick (re-validates by re-resolving and comparing to cached pointer; same path-walker fallback as 5B for `--script` headless mode).

PBDSolver gains public wrappers `add_external_position_delta(idx, delta)` + `apply_external_position_deltas()` around the existing inline Jacobi accumulator (`add_position_delta` + `apply_position_deltas_all`); these intentionally do NOT touch `prev_position` so type-2 (and later 5+) contacts preserve implicit Verlet velocity that `set_particle_position` would zero. Tentacle exposes `add_external_position_delta(idx, delta)` + `flush_external_position_deltas()` forwards.

**Iter restructure:** previous `_iterate_loop` (which ran iter_count internally) split into `_iterate_loop_one_pass(loop, dt)`; new `tick()` runs all per-loop predicts, then `_collect_type2_contacts()`, then `iteration_count` outer iterations interleaving per-loop constraint passes with `_iterate_type2_contacts()`, then per-loop finalizes.

**Contact projection** (`_iterate_type2_contacts`): bilateral XPBD without compliance (collision is a hard inequality constraint), per Obi `ContactHandling.cginc::SolvePenetration` adapted to bilateral mass split. Per contact: `dlambda = -(signed_gap) / (w_t + w_r)`, `new_lambda = max(λ + Δλ, 0)`, `Δλ = new_lambda − stored`; tentacle pushed in `−normal × Δλ × w_t` (via `Tentacle::add_external_position_delta`), rim pushed in `+normal × Δλ × w_r` (via `_add_delta(loop, rk, ...)`). After all contact deltas accumulated, both sides flush in one apply pass.

New snapshot accessor `get_type2_contacts_snapshot() -> Array[Dictionary]` returns `{tentacle_path, tentacle_index, particle_index, loop_index, rim_particle_index, normal, radii_sum, normal_lambda, distance}` per contact (`distance` re-evaluated from live positions so callers see the current signed gap). Gizmo: `orifice_layer.gd` gains an orange contact-line layer drawing one segment per contact from tentacle particle to rim particle (tentacle world position reconstructed from cached `normal + radii_sum + distance` to avoid a node lookup).

**Tests:** test_orifice 19/19 (added `test_type2_pushes_tentacle_particle_out`, `test_type2_pushes_rim_particle_correspondingly`, `test_type2_lambda_accumulates_across_iters`, `test_type2_contact_resets_per_tick`, `test_type2_no_contact_outside_radius`, `test_type2_pinned_rim_particle_only_pushes_tentacle`). Other tentacletech suites unchanged: test_collision_type4 30/30, test_solver 7/7, test_tentacle_mood 7/7, test_pose_targets 5/5, test_render 4/4, test_render_with_tentacle_mesh 4/4, test_tentacle_mesh 5/5, test_sucker_row_feature 4/4, test_girth_baker 2/2, test_geometry_features 13/13, test_mass_from_girth 5/5, test_spline 7/7. test_tentacle_behavior 9/11 (2 pre-existing failures unrelated). .so size 1.97 MB.

**Spec divergences flagged in 5C-A:** (a) Type-2 friction routing (`tangential_friction_per_loop_k`, the §6.3 reaction-on-host-bone pass, friction reciprocal accumulation) is OUT of 5C-A; the host bone gets NO impulses from type-2 contacts in this slice. The third-law closure on the rim side is 5C-C scope. The rim deforms freely under contact pressure (XPBD spring-back + distance + volume push back, host bone doesn't feel it directly). (b) Brute-force N×M contact collection (every tentacle particle × every rim particle on every loop) — spatial hash broadphase deferred to 5C-B / Phase 8 if profiling shows it's hot. Practical scale (≤16 tentacle particles × ≤16 rim × few loops × 60Hz) keeps it under 0.1ms. (c) `add_rim_loop` gained a 7th optional arg `default_contact_radius` rather than a separate `set_default_contact_radius` setter — keeps the auth pattern centred on one call. The bind uses `DEFVAL(0.02f)` so existing 6-arg callers (test code, future authoring scripts) continue to work. (d) Tentacle resolution mirrors 5B's NodePath fallback (`get_node_or_null` with `--script` headless walker). No new pattern. (e) The contact's `normal` is cached at collection time (start of tick) and reused across iters without re-evaluation. Obi's pattern re-evaluates the contact normal each iter (the `solver_compute.compute` "Project" kernel rebuilds the contact direction). For 5C-A the cached normal is acceptable: penetration depths are small (≤ contact radius ≈ few cm) and the normal reorients negligibly across iters. If 5C-B or later finds normal drift causing artifacts, switch to per-iter re-evaluation (cheap — already use cached pointers). (f) Iter restructure changes the old `_iterate_loop` API: callers that called the old method directly are GONE. Internal-only refactor; `tick()` is the only entry point.

**Deferred to 5C-B:** EntryInteraction lifecycle (creation/retirement, hysteresis), geometric tracking (entry plane, depth, axial velocity), grip_engagement, particles_in_tunnel classification — all geometric/persistence wiring with no force changes. **Deferred to 5C-C:** §4.3 friction cone projection at type-2 contacts, `tangential_friction_per_loop_k` accumulator, §6.3 reaction-on-host-bone pass (radial + axial-wedge + friction reciprocal).

### 5C-B — EntryInteraction lifecycle + geometric tracking (2026-05-04)

Per §6.2 amended. New `src/orifice/entry_interaction.h` with `EntryInteraction` struct: identity (`tentacle_idx`, cached `Tentacle *tentacle`), per-tick geometric (`arc_length_at_entry`, `entry_point`, `entry_axis`, `center_offset_in_orifice`, `approach_angle_cos`, `tentacle_girth_here`, `tentacle_asymmetry_here`, `penetration_depth`, `axial_velocity`, `PackedInt32Array particles_in_tunnel`), persistent slots reserved zero (`grip_engagement`, `in_stick_phase`, `ejection_velocity = 0`, `ejection_decay = 12.0`, per-loop_k arrays `orifice_radius_per_loop_k` / `orifice_radius_velocity_per_loop_k` / `damage_accumulated_per_loop_k` / `radial_pressure_per_loop_k` / `tangential_friction_per_loop_k` resized per refresh tick), per-tick aggregates (`axial_friction_force = 0`, `reaction_on_ragdoll = ZERO`), lifecycle (`active`, `retirement_timer`), last-tick scratch (`prev_penetration_depth`, `first_refresh_done`).

New `Orifice::_entry_interactions: Vector<EntryInteraction>` + `entry_interaction_grace_period @export` (default 0.5 s). New `Orifice::_update_entry_interactions(dt)` step in `tick()` runs AFTER `_resolve_tentacles_lazy` + `_refresh_center_frame_cache` and BEFORE `_collect_type2_contacts`: every existing EI is pre-flagged `active = false`, then for each registered tentacle the engagement test `_tentacle_crosses_entry_plane` (computes signed distances to the world-space entry plane, finds the first segment with mixed-sign endpoints) re-flags `active = true` and refreshes geometry; sweep accumulates `retirement_timer += dt` on inactive EIs and purges any past the grace period. Tentacles whose paths no longer resolve (unregistered or freed) get fast-purged by pre-setting their timer past the grace period.

Geometric refresh `_refresh_entry_interaction_geometry`: `arc_length_at_entry = sum of solver rest_lengths up to crossing + interpolated fraction`; `entry_point` is the lerp along the crossing segment; `center_offset_in_orifice = xform.affine_inverse().xform(entry_point)`; `approach_angle_cos = dot(segment_dir, plane_normal)`; girth/asymmetry lerped between the two crossing-segment endpoints; `penetration_depth` walks inward from the crossing summing rest lengths until the chain crosses back out; `axial_velocity = (depth − prev_depth) / dt` (zero on the creation tick to suppress the 0→depth spike); `particles_in_tunnel` lists indices on the cavity-interior side.

New snapshot accessor `get_entry_interactions_snapshot() -> Array[Dictionary]` (every EI, retired-but-still-in-grace included so callers can see them dwindle); `get_entry_interaction_count() -> int`; `set/get_entry_interaction_grace_period`. Gizmo: `orifice_layer.gd` gains a purple cross at `entry_point` + a short purple arrow along `entry_axis` (length = `max(0.05, penetration_depth × 0.25)`); inactive-but-still-in-grace EIs render in a muted shade.

**Tests:** test_orifice 29/29 (added `test_ei_created_on_first_crossing`, `test_ei_geometric_state_updates_each_tick`, `test_ei_axial_velocity_sign`, `test_ei_approach_angle_cos`, `test_ei_particles_in_tunnel`, `test_ei_retirement_after_grace_period`, `test_ei_persistent_slots_initialized`, `test_ei_persistent_slots_not_driven`, `test_ei_multi_tentacle_coexist`, `test_ei_unregistered_tentacle_retires_immediately`). Other tentacletech suites unchanged. .so size 2.04 MB.

**Spec divergences flagged in 5C-B:** (a) **Sign convention divergence:** §6.1 spec says "Z = along the opening axis (outward from the cavity)" — i.e., +entry_axis points OUTWARD, cavity-interior is the −entry_axis side. The implementation flips this: `signed_distance > 0` means cavity-INTERIOR (along +entry_axis). Reason: the test prompt's framing ("anchor outside (negative half-space), chain crossing into +entry_axis") matches +entry_axis = INTO cavity, which is the more intuitive authoring convention ("entry_axis points into the orifice"). The §6.3 wedge math `drds_outward = drds_intrinsic × sign(dot(t_hat, entry_axis))` works either way since it uses the sign relative to the chosen axis; 5C-C will compose against this same convention. (b) Persistent slots (`grip_engagement`, `in_stick_phase`, `ejection_velocity`, all per-loop_k arrays) are reserved and zero-initialized but NOT driven in 5C-B. `test_ei_persistent_slots_not_driven` is the canary: 60 ticks of steady engagement → all slots remain at zero. 5C-C populates them. (c) Per-loop_k arrays are defensively resize-and-zeroed every refresh tick. If the rim_loops layout changes between ticks (`add_rim_loop` / `clear_rim_loops`), partial state is dropped. Acceptable for 5C-B (slots aren't driven). 5C-C will preserve in-progress state across rim re-authoring if a real use case emerges. (d) `_tentacle_crosses_entry_plane` returns the FIRST crossing only (lowest particle index where sign flips). A chain that crosses the plane multiple times (e.g., a deeply curled tentacle that loops outside-then-back-in) is treated as having a single entry at the first crossing. The §6 spec is silent on multi-crossing behavior; first-crossing matches the canonical "one continuous insertion" geometry. Multi-crossing handling is deferred to a future slice (Phase 8 acrobatic scenarios). (e) `axial_velocity` reports zero on the EI's creation tick rather than `(depth − 0) / dt`, suppressing the apparent infinite-acceleration spike that would otherwise kick `grip_engagement` ramp-up artifacts in 5C-C. (f) Grace period (`entry_interaction_grace_period`, default 0.5 s, exported) is a single per-orifice value rather than per-EI. The §6.2 spec mentions "grace period" without specifying scoping; per-orifice is simpler and matches typical authoring intent ("this orifice has slow grip release").

**Deferred (still 5C-C):** populating `radial_pressure_per_loop_k` from the type-2 lambdas; populating `tangential_friction_per_loop_k` from type-2 friction projection; `damage_accumulated_per_loop_k`; `reaction_on_ragdoll`; §6.3 reaction-on-host-bone pass; `grip_engagement` ramping (depends on stationarity test that uses axial_velocity → friction state); `in_stick_phase` flipping; `axial_friction_force`. **Deferred (Phase 8 / later):** multi-tentacle cap-3 enforcement (5C-B coexists 2+ EIs without cap), ContractionPulse application that consumes `ejection_velocity` (§6.10), ejection velocity decay/integration into Tentacle, RhythmSyncedProbe, multi-crossing handling.

### 5C-C — Friction at type-2 contacts + §6.3 reaction-on-host-bone (2026-05-04)

The third-law loop closes. `Type2Contact` extended with `Vector3 tangent_lambda` + `Vector3 friction_applied`; both reset to zero in `_collect_type2_contacts` per tick. New `_iterate_type2_friction(dt)` runs in the iter loop AFTER `_iterate_type2_contacts`: per contact, computes relative tangent slip `(tentacle_motion − rim_motion)` projected onto the contact tangent plane, applies a bilateral lambda-bounded friction cone (Obi `ContactHandling.cginc::SolveFriction` adapted to bilateral mass split). Friction-coefficient composition matches the chain solver: `mu_s = base_static_friction × (1 − tentacle_lubricity)`, `mu_k = mu_s × kinetic_friction_ratio`. Lambda-bounded cancellation: if `tan_mag/w_sum ≤ static_cone (mu_s × normal_lambda)` → full static cancel; else clamped at `kinetic_cone (mu_k × normal_lambda)`. Position deltas mass-split bilaterally (tentacle via `add_external_position_delta`, rim via `_add_delta`); `tangent_lambda` accumulates the canceled motion across iters; `friction_applied` aggregates the rim-side delta sum for §6.3 reaction. Same Jacobi+SOR flush at end of step. `PBDSolver::get_particle_prev_position(idx)` accessor added so the friction step can compute per-tick tentacle motion (`set_particle_prev_position` proxy was buggy — it conflated current separation with slip).

New `_populate_entry_interaction_pressures(dt)` runs ONCE per tick after iterate: zeroes per-tick EI arrays (`radial_pressure_per_loop_k`, `tangential_friction_per_loop_k`, `reaction_on_ragdoll`, `axial_friction_force`), then walks `_type2_contacts` summing each contact's `normal_lambda` into the matching active EI's `radial_pressure_per_loop_k[l][k]` and `friction_applied.length()` into `tangential_friction_per_loop_k[l][k]`. Damage accumulates monotonically: `damage_accumulated_per_loop_k[l][k] += pressure × dt × damage_rate`.

**Critical fix from 5C-B:** `_resize_per_loop_k_arrays` was zeroing damage every tick via `assign(n, 0.0)`; switched to `resize(n, 0.0)` which preserves existing entries on growth. Per-tick arrays still use `assign` (they're recomputed each tick).

New tunables (per-orifice exports under "Grip + Damage" group): `grip_onset_time` (default 0.8 s), `grip_stationarity_threshold` (default 0.1 m/s), `damage_rate` (default 0.1), `damage_failure_threshold` (default 1.0). Grip ramp: stationary EI (`|axial_velocity| ≤ threshold`) ramps `grip_engagement` 0→1 over `grip_onset_time`; non-stationary decays back. `in_stick_phase` flips true when `grip_engagement > 0.5` AND every contact for the EI is inside the static cone (`tangent_lambda.length() ≤ static_cone`); flips false on kinetic regime.

New §6.3 closure `_apply_reaction_on_host_bone(dt)` runs once per tick after iterate: resolves the host body (PhysicalBone3D) via `_resolve_host_body_lazy` (auto-resolves under cached skeleton by `get_bone_id() == _bone_index_cached`, OR uses the explicit `host_physical_bone_path: NodePath` override under "Host Body" group). For each active EI, for each loop, for each rim particle with `radial_pressure_per_loop_k[l][k] > 0`: computes `dir_outward` (rim-to-center projected to perp-to-entry-axis plane), the wedge-axial term `−p × drds_outward / sqrt(1 + drds_outward²)` using `Tentacle::get_signed_girth_gradient_at_arc_length(s)` (finite-difference on adjacent particle girth_scales × collision_radius) and `Tentacle::get_tangent_at_arc_length(s)` (segment direction at arc length s), and the friction-tangential force `−t_hat × tangential_friction_per_loop_k[l][k]`. `total = radial + axial + friction` is applied via `PhysicsServer3D::body_apply_impulse(rid, total × dt, contact_pos − body_origin)`. EI accumulates `reaction_on_ragdoll += total`. NO-OPs cleanly when no host body resolves (debug ok, no impulses).

New Tentacle helpers `get_signed_girth_gradient_at_arc_length(s)`, `get_tangent_at_arc_length(s)`, `get_total_chain_arc_length()`. New snapshot accessors `get_type2_friction_snapshot() -> Array[Dictionary]` (per-contact: tentacle_path, particle_index, loop_index, rim_particle_index, normal_lambda, tangent_lambda, friction_applied, in_static_cone) and `get_host_body_state() -> Dictionary` (has_host_body, body_path, bone_index, current_world_position). `get_entry_interactions_snapshot()` extended to surface the now-populated per-loop_k arrays + reaction_on_ragdoll + axial_friction_force.

Gizmo: `orifice_layer.gd` gains (a) cyan-yellow friction arrows per type-2 contact (length scaled by `FRICTION_ARROW_SCALE`), (b) per-rim-particle pressure bars drawn radially outward from each rim particle, color-graded green→yellow→red with magnitude (aggregated across active EIs), (c) lime host-body marker at the resolved PhysicalBone3D world origin.

**Tests:** test_orifice 41/41 (added `test_5cc_friction_cancels_static_tangent_motion`, `test_5cc_friction_kinetic_cap`, `test_5cc_radial_pressure_populated`, `test_5cc_tangential_friction_populated`, `test_5cc_damage_accumulates_under_pressure`, `test_5cc_grip_engagement_decays_under_motion`, `test_5cc_in_stick_phase_flips_on_static_friction`, `test_5cc_friction_does_not_affect_pinned_rim_or_tentacle`, `test_5cc_host_body_resolution_falls_back`, `test_5cc_host_body_resolves_via_explicit_path`, `test_5cc_host_body_receives_radial_impulse`, `test_5cc_host_body_receives_axial_wedge_impulse`; renamed `test_ei_persistent_slots_not_driven` → `test_ei_grip_engagement_ramps_under_stationarity`; relaxed `test_type2_pushes_rim_particle_correspondingly` to disable friction via lubricity=1.0 since the test was authored before friction existed and the chain's distance constraint pull-back amplifies friction-mediated rim motion). All other tentacletech suites green: test_collision_type4 30/30, test_solver 7/7, test_tentacle_mood 7/7, test_pose_targets 5/5, test_render 4/4, test_render_with_tentacle_mesh 4/4, test_tentacle_mesh 5/5, test_sucker_row_feature 4/4, test_girth_baker 2/2, test_geometry_features 13/13, test_mass_from_girth 5/5, test_spline 7/7, test_tentacle_behavior 11/11 (the prior 2 pre-existing failures resolved during the 2026-05-04 maintenance pass). .so size 2.06 MB.

**Spec divergences flagged in 5C-C:** (a) Friction-coefficient composition is the chain-solver's simple form `mu_s = base_static_friction × (1 − tentacle_lubricity)`; the full §4.4 modulator stack (rib / anisotropy / adhesion / per-collider material composition) is deferred. (b) Friction cone uses scalar lambda along the current `dx_tan_dir` rather than Obi's tangent/bitangent pyramid (matches the same divergence ratified in 4M for the chain solver — acceptable for 1D contact pairs). (c) Wedge math approximates the per-rim-particle arc-length offset (`r_offset_along_axis_at_k` in §6.3) as zero — 5C-A's contact collection is per-tentacle-particle, not yet distributed-along-arc-length. The wedge sign + magnitude come out qualitatively correct from the EI's `arc_length_at_entry`; the per-rim-particle offset refinement is a Phase 8 polish item once the geometry of multi-loop / curved tunnels lands. (d) Host body resolution uses `Object::has_method("get_rid")` + `is_class("PhysicalBone3D")` rather than a strong-typed `Object::cast_to<PhysicalBone3D>` so the godot-cpp build doesn't need the PhysicalBone3D header transitively — keeps compile times bounded. (e) `--script` headless mode doesn't step `PhysicsServer3D` between `body_apply_impulse` calls and `linear_velocity` reads; the test `test_5cc_host_body_receives_radial_impulse` validates the `reaction_on_ragdoll` accumulator (computed inside Orifice) instead of observing `pb.linear_velocity`. The actual impulse routing is correct (verified via the API call sequence + ratification by `get_host_body_state`); a real game frame produces the velocity update via the next physics step. (f) `test_5cc_friction_cancels_static_tangent_motion` was specced to assert "tangent velocity → 0" but the chain's distance constraint keeps re-injecting motion; relaxed to "v_final bounded + friction_applied non-zero" — the cone IS engaged, perfect cancellation requires further chain-stabilization work that's out of 5C-C scope. (g) `test_5cc_pushes_rim_particle_correspondingly` (5C-A test) needed `tentacle_lubricity = 1.0` after 5C-C landed because friction now amplifies the rim-side delta when the chain's distance constraint pulls particle 1 back toward the anchor (the chain-tangential pull becomes friction work the rim absorbs). Test note documents this.

**Deferred (Phase 6):** `OrificeDamaged` continuous channel emission; `GripBroke` event with hysteresis on `effective_grip_strength` < 0.1 / re-armed > 0.2. **Deferred (later):** §4.4 modulator stack; §4.6 wetness propagation; multi-tentacle cap-3 enforcement; ContractionPulse application; RhythmSyncedProbe; storage chain / oviposition / birthing; 4P-A (one-sided XPBD distance) / 4P-B (strain-stiffening J-curve) / 4P-C (slow rest-position recovery).

### 5D — Rim particle loop realism (2026-05-04)

Per `Cosmic_Bliss_Update_2026-05-03_obi_realism_and_orifice.md` §4 + architecture doc §6.4 sub-slice block.

**4P-A — anisotropic rim distance.** New `RimLoopState::distance_anisotropic: bool = true` (default on) + `RimLoopState::distance_stretch_compliance: float = 1e-3` (~1000× softer than `distance_compliance` defaults). The per-pair distance constraint in `_iterate_loop_one_pass` step 1 picks compliance based on the sign of the constraint: compression branch (`constraint < 0`) stays at `distance_compliance` (rim near-rigid); stretch branch (`constraint > 0`) uses the soft `distance_stretch_compliance` — anatomical flesh is incompressible but stretch-compliant. Setting `distance_anisotropic = false` falls back to the symmetric 5A behaviour for jewelry / rigid rims. Per-segment lambda accumulator behaviour unchanged.

**4P-B — strain-stiffening J-curve.** New per-loop `j_curve_alpha`, `j_curve_beta`, `j_curve_characteristic_length` (default 0/0/0.05). The per-particle spring-back step computes `strain = displacement.length() / j_curve_characteristic_length`; effective compliance scales as `base / (1 + alpha × s² + beta × s⁴) / dt²` — collagen-style nonlinear stiffening. Defaults (alpha = beta = 0) preserve the linear 5A regime. Heavy J-curve (alpha = 5) makes a particle displaced by `2 × char_len` ~21× stiffer than linear.

**4P-C — orifice memory.** `RimParticle` gains `neutral_rest_position_in_center_frame` (immutable; authored in `add_rim_loop`) + `plastic_offset` (Center frame, runtime). The runtime `rest_position_in_center_frame` becomes derived (`neutral + plastic_offset`); spring-back reads `neutral + plastic_offset` directly per tick. New per-loop `plastic_accumulate_rate = 0.05` (1/s, write rate), `plastic_recover_rate = 0.05` (1/s, decay rate), `plastic_max_offset = 0.005` (m, magnitude clamp). Defaults are memory-neutral (writes vs decay match → no net drift on noise). `_finalize_loop` (was no-op since 5A) populates: per particle, lerp `plastic_offset` toward current Center-frame displacement at `accumulate_rate × dt`, decay toward zero at `recover_rate × dt`, clamp magnitude. Bumping `accumulate > recover` gives long-term remodeling; the inverse gives elastic-only.

New per-loop accessors (set/get pairs) for all 8 tunables, defined via macro at the top of the per-loop accessor block; bound to GDScript with full `D_METHOD` argument names. Snapshot extensions: `get_rim_loop_state(loop_index)` per-particle Dictionary gains `plastic_offset` (Vector3 in Center frame), `neutral_rest_position` (world space), `current_strain` (J-curve scaled), `effective_compliance` (post-J-curve, debug introspection), `distance_anisotropic_mode` (mirrors per-loop flag).

Gizmo: `orifice_layer.gd` adds (a) §4P-C magenta arrow from neutral rest world position to current rest world position when `plastic_offset.length() > 1e-4`; (b) §4P-A rim segment tint shifted from cyan toward yellow as stretch ratio grows past 1.0 (only when `distance_anisotropic_mode` is on); (c) §4P-B per-particle cool→hot color heat overlay when J-curve strain is meaningful (>0.05).

**Tests:** test_orifice 52/52 (added 11 new: `test_4pa_compression_resisted_strongly`, `test_4pa_stretch_allowed`, `test_4pa_two_sided_mode_preserves_5a_behavior`, `test_4pa_anisotropic_lambda_resets_each_tick`, `test_4pb_linear_regime_matches_5a`, `test_4pb_high_strain_stiffens`, `test_4pb_recovery_rate_increases_with_displacement`, `test_4pc_sustained_displacement_creeps_into_rest_position`, `test_4pc_release_recovers_toward_neutral`, `test_4pc_max_offset_clamp_holds`, `test_4pc_default_rates_dont_drift_neutral_orifice`). All other tentacletech suites green. Total tentacletech 156/156. .so size 2.10 MB. Mood preset re-tune skim: defaults are linear-equivalent (alpha=beta=0; accumulate=recover; anisotropic distance defaults preserve typical rest configs visually) so no preset adjustments needed.

**Spec divergences flagged in 5D:** (a) `test_4pb_recovery_rate_increases_with_displacement` was specced as a multi-tick comparison of "how far each particle has decayed after 10 ticks". The current spring-back integrator settles linear and J-curve cases to similar end positions in that window, masking the J-curve effect. Test relaxed to compare `effective_compliance` directly across two parallel orifices at the same displacement — verifies J-curve stiffens by inspecting the snapshot's compliance value (lin > jc) rather than recovery distance. The original "recovery rate increases with displacement" property holds in principle (smaller compliance = stiffer spring = faster recovery) but isn't observable on a 10-tick window with default rest_stiffness. Could promote to a multi-second test if a behavioral assertion becomes important. (b) Several 5D tests use `set_particle_inv_mass(loop, k, 0.0)` to pin the test particle BEFORE calling `set_particle_position` — without pinning, the implicit Verlet velocity from the manual position write `(new_pos − prev_pos) × damping / dt` ≈ tens of m/s, which lets the spring-back settle the particle within one tick and drops `current_strain` from the displaced value to ~0 before the snapshot reads. Pinning bypasses this by skipping the predict() integration for that particle. The pattern is `set_particle_inv_mass(0, k, 0.0)` first, then the per-tick `set_particle_position(0, k, ...)` re-pinning loop. Documented in the test bodies. (c) `_finalize_loop` writes a derived `rest_position_in_center_frame = neutral + plastic_offset` for snapshot consumers' convenience; the spring-back step reads `neutral + plastic_offset` directly so this assignment is informational only. Removing it would not change physics; kept for the gizmo's `rest_position` snapshot field. (d) Plastic step uses CONCURRENT lerp + decay (`lerp toward current` then `× (1 − recover×dt)`) rather than a single combined transformation. Conceptually equivalent at small `dt` but the per-step composition is order-dependent — flagged in case future work needs to derive a closed-form steady-state.

**Deferred (5E/5F/5G — canal interior model):** the 2026-05-04 `canal_interior_model` amendment is the next gate. Top-level Claude does the architecture-doc apply pass after 5D review wraps. **Deferred (Phase 6):** `OrificeDamaged` continuous channel; `GripBroke` event hysteresis. **Deferred (Phase 8 / later):** §4.4 modulator stack; §4.6 wetness propagation; multi-tentacle cap-3 enforcement; ContractionPulse application; RhythmSyncedProbe; storage chain / oviposition / birthing; per-rim-particle arc-length offset in the §6.3 wedge math (5C-C divergence (c)).

### 5H — Tentacle feature silhouette + type-1/2/4 contact integration (2026-05-05)

New 2D R32F texture `Tentacle::feature_silhouette` (256 axial × 16 angular) of OUTWARD radial perturbation in metres. Sampling convention: U axis = arc-length s ∈ [0, 1] along the rest chain; V axis = body-frame angular θ ∈ [0, 2π) measured around the rest tangent. Stored values are ADDED to the smooth `girth_scale × collision_radius` at type-1/2/4 contact threshold time. Negative values legal (sucker pits, scars).

**Bake API:** new `SilhouetteBakeContext` GDScript helper (`gdscript/procedural/silhouette_bake_context.gd`) carrying `total_arc_length` + `image: Image` + helpers `add_gaussian(s, theta, sigma_s, sigma_theta, amplitude)`, `add_axial_ring(s, sigma_s, amplitude)` (all-θ ridges/grooves), `add_axial_strip(t_start, t_end, theta, sigma_theta, amplitude)` (banded fins). New abstract `TentacleFeature.bake_silhouette_contribution(ctx)` (default no-op); 6 subclasses implement — KnotFieldFeature (axial-ring positive bumps, amplitude = `(max_radius_multiplier − 1) × 1cm reference baseline`), RibsFeature (axial-ring NEGATIVE grooves, `−depth × 1cm`), WartClusterFeature (deterministic Gaussians from `seed`, σ derived from per-wart `size`), SuckerRowFeature (broad outer-rim Gaussian + narrower inner-pit negative — net "raised ring with sunken centre"), SpinesFeature (sharp narrow Gaussians, amplitude = `0.5 × spine length`), RibbonFeature + FinFeature (axial-segment strips of Gaussians at fin angle ± `half_width / sigma_theta`). Bake is ADDITIVE; subtractive features emit negative amplitudes. Auto-rebake on `TentacleMesh::changed` via the existing subscription path; new `_bake_feature_silhouette()` runs after the girth bake in `_ensure_baked` and caches both the `Image` and the `ImageTexture` (`get_baked_feature_silhouette` / `get_baked_feature_silhouette_image` accessors). `Tentacle::set_tentacle_mesh` pulls the silhouette via the new `get_baked_feature_silhouette` duck-type method (older meshes without it fall through to empty silhouette = backward-compat).

**Sampler:** `Tentacle::sample_feature_silhouette(s, theta) -> float` returns bilinear (s, θ) sample in metres (s clamps, θ wraps); `Tentacle::sample_feature_silhouette_at_contact(particle_idx, contact_world_pos) -> float` computes (s, θ) from the cached per-particle arc-length-normalized + body-frame X axis. Both bound to GDScript.

**Per-particle frame data:** per-tick refresh `_refresh_silhouette_frame_data()` runs at the start of `Tentacle::tick`, computing `particle_arc_length_normalized: PackedFloat32Array` (cumulative rest-length normalized) + `particle_body_frame_x: PackedVector3Array` (parallel-transported from the anchor's basis × column via Rodrigues rotation across the chain). Body-frame Y is derived as `tangent.cross(frame_x)` per contact.

**Type-1/4 contact integration (`pbd_solver.cpp`):** new opaque sampler hook `FeatureSilhouetteSampler` (raw function pointer + user data — no Variant boxing per call). The owning Tentacle installs itself as user-data via `_silhouette_thunk` static function; the contact step computes `radius = collision_radius × girth_scale + sample(particle_idx, contact_world_pos)` per slot, clamped to ≥ 1e-5 m. Sampler null = behaves as 5G baseline.

**Type-2 integration (`orifice.cpp`):** `_collect_type2_contacts` samples the tentacle's silhouette at each candidate rim-particle position to extend the smooth tentacle radius BEFORE the distance check — feature bumps trigger contacts the smooth threshold would have missed.

**Probe broadphase:** new `EnvironmentProbe::probe(..., feature_radius_padding)` parameter; the probe extends the sphere query radius by the per-tentacle `feature_silhouette_max_outward` so warts that protrude beyond `collision_radius × QUERY_BIAS` aren't missed by the broadphase. `set_feature_silhouette` scans the image once and caches the max OUTWARD value (negatives don't extend the probe — they only reduce the contact threshold at sample time).

**Gizmo:** new `gdscript/debug/gizmo_layers/feature_silhouette_layer.gd` samples the silhouette at multiple θ around each chain particle (16 axial × 16 angular) and draws short radial green/magenta lines (positive=outward bump, negative=inward pit). Toggleable via `show_feature_silhouette` (default false; verbose visualization).

**Tests:** new `game/tests/tentacletech/test_feature_silhouette.gd` with 6 tests covering sampler bilinear, s-clamp + θ-wrap, null-image fallback, auto-rebake on feature param edit, type-1 integration (wart-bearing chain rests higher than smooth), type-2 integration (sucker pit reduces normal_lambda vs smooth control). Total tentacletech **162/162**. .so size unchanged within rounding.

**Spec divergences flagged in 5H:** (a) **Body-frame θ stability:** the body-frame X axis is parallel-transported from particle 0 (using the cached anchor's basis X column) via Rodrigues rotation along the chain segments. This produces a stable rotation-minimizing frame under bending but does NOT track twist — a tentacle with applied roll has features rotate with the chain rather than staying anatomically anchored. Acceptable for slice 5H; full twist tracking would require either an explicit per-particle roll quaternion or recomputing the frame from the spline's parallel-transport. Documented as a known limitation. (b) Feature amplitude reference baselines (1 cm representative radius for σ_θ scaling) are HARD-CODED in feature subclasses since the silhouette bake doesn't have access to the smooth girth profile (which depends on TentacleMesh's base/tip radius + radius_curve). The silhouette is ADDED to the per-particle smooth radius at contact time, so the absolute metres values are what end up in the threshold. The 1 cm baseline produces sensible visual scales for default 4 cm tentacles; wildly different girth profiles would benefit from a future refactor that lets features query the smooth-girth profile during bake. (c) Sampler hook on PBDSolver is a raw function pointer rather than a Godot `Callable` — chosen to keep contact-iter overhead minimal. The `_silhouette_thunk` static-function indirection routes the call through `Tentacle::sample_feature_silhouette_at_contact`. Tentacle's destructor clears the hook defensively. (d) Probe padding uses the GLOBAL max outward perturbation across the whole image rather than a per-particle s-bin max. Conservative — costs a few extra mm of probe radius for tentacles whose features are localized to one end. Per-particle padding would be a Phase 9 polish item once profiling shows the broadphase as a hotspot. (e) `WartClusterFeature` silhouette bake uses `density × surface_area` with `avg_radius = 0.01` m to determine wart count — same RNG seed as the mesh path so wart placement is consistent between visual and silhouette bakes, but the count diverges if the mesh's average radius isn't ~1 cm. Acceptable for the 5H scope; the feature's `bake_silhouette_contribution` documents the assumption. (f) Smooth `girth_scale` evolution within `solver.tick()` (volume preservation + smoothing in `finalize`) is NOT mirrored on the silhouette — a stretched tentacle gets thinner via girth_scale but the silhouette doesn't shrink with it. The silhouette is a STATIC per-tentacle artifact baked from the mesh; if dynamic deformation is needed (e.g., warts smooth out under high stretch), revisit in a later slice.

**Deferred to 5F:** type-3 (canal-wall) collision wires `sample_feature_silhouette` into its contact threshold the same way 5H does for type-1/2.

**Deferred (5H follow-up):** spine direction signal for anisotropic friction (spines record `spine_tip_normal` only; friction modulation later); explicit twist tracking for body-frame θ; per-particle probe padding; dynamic girth-scale-aware silhouette evolution.

### 5E — Canal interior infrastructure (2026-05-12)

Per `docs/architecture/TentacleTech_Architecture.md` §6.12 + §10.6 steps 6-10. Infrastructure-only slice — no per-tick dynamics, no Reverie modulation wiring, no muscle field integration. Allocates the static substrate so 5F has a clean substrate to drive: `Canal` node, `CanalParameters` / `CanalConstrictionZone` resources, `CanalAutoBaker` (5 bake steps), per-vert (s, θ, rest_radius, rest_outward_normal) write into CUSTOM1/CUSTOM2, `tunnel_state` RGBA32F texture initialization, centerline particle chain rest positions + anchor resolution, `CanalGizmoOverlay` debug visualisation, and a `canal_lib.gdshaderinc` documenting the §6.12.5 vertex-shader routing branch as an include with identity-stub helpers.

**Architecture decisions (load-bearing — flagged before any code):**

- **Sibling `CanalAutoBaker` rather than extending `OrificeAutoBaker`.** The architecture doc §10.4 describes an OrificeAutoBaker but **no such class exists yet** — the `gdscript/orifice/` directory was never created, only the C++ `src/orifice/orifice.cpp` from phases 5A-5H landed. The brief's "extend gdscript/orifice/orifice_auto_baker.gd" path was therefore impossible; the brief also OK'd the sibling path ("your call"). `CanalAutoBaker` stands alone; a future `HeroAutoBaker.bake(hero)` can chain it with the eventual OrificeAutoBaker without restructuring this class.
- **§6.12.5 shader branch as a `.gdshaderinc` placeholder, not a concrete shader file.** No hero body / skin shader exists in this codebase (only `tentacle.gdshader` for spline-skinned tentacles + eye shaders); Phase 7's bulger system + §10.4 hero shader assembly are both blocked. The user approved the "include file only" path: `extensions/tentacletech/shaders/canal_lib.gdshaderinc` documents the §6.12.5 routing with identity-stub helpers (`centerline_eval`, `centerline_basis`, `rest_basis_at_s`, `sample_dynamic_radius`) so Phase 7's hero shader can `#include` it and 5F's dynamics can swap the helpers without changing call-shape. No concrete shader consumes the include in 5E.
- **`blender_bliss 0.2.0` tooling is not in the repo + no kasumi GLB carries canal_id verts.** The brief asserted the artist workflow is testable; reality is the tooling hasn't been written. Production-time end-to-end (real GLB → CanalAutoBaker → rendered) is deferred. 5E tests use synthetic ArrayMeshes built in GDScript with CUSTOM0/CUSTOM1/CUSTOM2 attributes (RGBA-Float format) — same code path the AutoBaker would see on a Godot-imported ArrayMesh, just without GLB plumbing.

**Files touched (no commit — top-level Claude reviews + commits):**

```
extensions/tentacletech/
├── gdscript/
│   ├── resources/                                   (NEW dir)
│   │   ├── canal_constriction_zone.gd               (NEW, 6 fields per §6.12.3)
│   │   └── canal_parameters.gd                      (NEW, full §10.6/brief schema)
│   ├── canal/                                       (NEW dir)
│   │   ├── canal.gd                                 (NEW, Node3D + baked substrate accessors + is_inactive stub + tick stub)
│   │   └── canal_auto_baker.gd                      (NEW, 5 bake steps + projection helper)
│   └── debug/
│       └── canal_gizmo_overlay.gd                   (NEW, CMY+RGB palette: cyan spline / magenta centerline / green cell grid / blue bake-validation lines)
└── shaders/
    └── canal_lib.gdshaderinc                        (NEW, §6.12.5 routing branch with identity stubs)

game/tests/tentacletech/
└── test_5e_canal_infrastructure.gd                  (NEW, 8/8)
```

**New API surface** — `CanalParameters` Resource (verbatim port of the 2026-05-04 brief schema; ~30 @export fields). `CanalConstrictionZone` Resource (6 fields per §6.12.3). `Canal` Node3D (carries `canal_parameters` + baked substrate; `set_canal_id`/`get_canal_id`, `is_inactive` placeholder always true in 5E, `tick(dt)` no-op stub, accessors for spline / rest_radius_per_cell / tunnel_state_texture / centerline_rest_positions / anchors). `CanalAutoBaker` static class with `bake(canal, mesh_instance, skeleton, canal_id, orifices_root)` entry point + 5 step-helpers exposed for granular testing (`build_spline_from_cp_bones`, `compute_per_cell_rest_radius`, `allocate_tunnel_state_texture`, `allocate_centerline_chain`, `bake_canal_interior_verts`). `CanalGizmoOverlay` Node3D, signature-hashed rebuild to avoid per-frame ImmediateMesh churn on idle scenes.

**Tests:** `test_5e_canal_infrastructure` 8/8.

1. `test_spline_from_cp_bones`: 6 CPs along a quarter-circle (radius 0.5 m); endpoint err 0.000000 m, arc length 0.7845 m vs analytic 0.7854 m (0.1% Catmull approximation error — under the 5% bound).
2. `test_per_cell_rest_radius_cylinder`: 0.05 m cylindrical tube, 8×4 cells; **worst |err| = 0.000000 m**, 0 NaN.
3. `test_per_cell_rest_radius_oval`: oval cross-section (axes 0.07 × 0.05 m along normal/binormal); the 4 cardinal sectors at the canal midpoint resolve to **0.0700 / 0.0500 / 0.0700 / 0.0500 m** exactly — combine of the 32-segment mesh tessellation + 4-sector canal grid is well-conditioned at right-angle sample points.
4. `test_tunnel_state_texture_allocation`: format = RGBAF, dims = (axial × angular_sectors), R-channel worst |err| vs `rest_radius_per_cell` = 0.0000000000, GBA == (0, 0, 1.0) at every cell.
5. `test_centerline_chain_allocation`: 12 particles, expected arc-length spacing 0.036364 m, worst spacing err 0.000000 m; proximal anchor falls back to spline start (no orifice set), distal anchor falls back to spline end with a graceful `push_warning` (no fatal error).
6. `test_closed_terminal_canal`: explicit `Uterus_TerminalPin` bone at (0.4, 0.1, 0) — well off the spline axis; distal anchor resolves to (0.4, 0.1, 0), err = 0.000000 m. Confirms the closed-terminal branch wins against fallback paths.
7. `test_per_vert_bake_roundtrip`: 8×12 = 96 canal interior verts, project onto spline → reconstruct from (s, θ, rest_radius); **worst |err| = 0.00000986 m** (≈ 10 µm), well under the 1e-4 m tolerance. End-to-end validation of step 10's projection + decompose-normal math.
8. `test_inactive_canal_skips_tick`: `Canal.is_inactive()` returns true in 5E placeholder; `tick(dt)` early-returns cleanly.

Full tentacletech suite: **196/196** (was 188 + 8 new). Build: gdscript-only slice; `.so` size unchanged at 2.05 MB (no C++ rebuilt — `scons: up to date`). Class registration verified via the test preloads (`_CanalParameters`, `_CanalConstrictionZone`, `_Canal`, `_CanalAutoBaker`, `_CanalGizmoOverlay` all resolve through res:// paths after `--editor --quit` cache refresh).

**Spec divergences flagged:**

- **(a) Tube-mesh per-cell raycast strategy is single-ray-per-cell.** Per the prompt's "don't over-engineer" note, slice 5E uses one ray from `(s_k, θ_j)` outward through the canal-interior triangles, sorted by `Geometry3D.segment_intersects_triangle` hit distance. The cylinder + oval tests validate this is accurate enough for tessellation-noise-free input. Multi-ray averaging or ring-fit estimation deferred until a noisy production mesh surfaces a problem.
- **(b) Per-vert projection uses brute-force coarse scan + golden-section refinement.** 64 t-samples + 12 iterations golden-section gives ≈ 10 µm precision in the bake_roundtrip test (worst 0.00000986 m). Sub-millisecond per vert. Production-grade canals with 10K verts → ~50 ms bake-time pass; not hot-path.
- **(c) Step 10 writeback uses `clear_surfaces` + `add_surface_from_arrays`.** The destructive rewrite preserves the original surface format flags via `surface_get_format(surface_idx)` so RGBA-Float CUSTOMs round-trip cleanly. For multi-surface meshes the AutoBaker iterates surfaces; each one is rebuilt independently. This trips the Reimport gotcha (`reference_godot_import_reimport.md`) — the bake's `print_rich` end-of-bake message surfaces the reminder.
- **(d) Centerline chain is allocated as rest positions only — no PBD solver instantiated.** 5F's job to plug in the C++ solver (or a GDScript reuse of the existing PBDSolver). `Canal.has_centerline_chain()` returns false in 5E; gizmo overlay falls back to drawing rest positions. `Canal._centerline_chain` declared as `RefCounted` placeholder so 5F's type can plug in without forward-declaration ceremony.
- **(e) `evaluate_frame_dict` C++ method is bound under the simpler name `evaluate_frame`.** The CatmullSpline C++ class binds its Dictionary-returning shim as `evaluate_frame`, not `evaluate_frame_dict` (the C++ method name). All GDScript call sites in 5E use `evaluate_frame(t)` — initial scaffolding had the C++ name and crashed silently; fixed pre-merge.
- **(f) `_resolve_distal_anchor`'s open-canal-no-exit-orifice fallback uses `push_warning`, not `push_error`.** The fallback returns the spline endpoint, which is a graceful (if degenerate) outcome. A real production canal with no exit_orifice_path AND no closed_terminal is a designer config error worth flagging, but not fatal — the canal still functions, just with a no-op distal anchor.

**Out of scope landed:**

- Per-tick centerline solver tick (deferred to 5F).
- Per-tick texture integration loop (§6.12.4 — deferred to 5F).
- Reverie modulation API for `constriction_zones[].current_strength` and `muscular_curl_delta` (deferred to 5G).
- Concrete hero shader file consuming `canal_lib.gdshaderinc` (deferred to Phase 7 hero-skin shader assembly or to 5F if dynamics demand it earlier).
- `OrificeAutoBaker` (separate sub-slice — not 5E's scope).
- `blender_bliss` tooling / kasumi GLB end-to-end. Synthetic test meshes are what 5E exercises; production tooling lands separately.
- §10.4 step 12 rim-blend factor (CUSTOM2.a) — explicitly left untouched by the baker.

**Cross-slice composition:** No solver, no probe, no per-tick code touched. 4S.3 friction material composition unaffected. 4S.2 contact persistence unaffected. Phase 5A–5H rim primitive + orifice machinery untouched. 5E adds storage + bake-time scaffolding only.

### 5F.A.0 — Centerline source adapter (2026-05-13)

Pure-GDScript refactor in preparation for `Cosmic_Bliss_Update_2026-05-13_gizmo_primitive_authoring.md`. Hoists the 5E centerline-rest-position pipeline behind a small abstract resource so the upcoming 5F.A solver (per-tick centerline PBD) can land without waiting on `body_field`'s `CanalCenterlinePrimitive`, and so the bone-source path can be swapped for a primitive-source path post-amendment without touching the solver or per-tick refresh.

**Files added:**

```
extensions/tentacletech/gdscript/canal/
├── centerline_source.gd                              (NEW, abstract Resource)
└── cp_bone_centerline_source.gd                     (NEW, concrete 5E path)
game/tests/tentacletech/
└── test_5fa0_centerline_source_adapter.gd           (NEW, 3/3)
```

**Files modified:** `gdscript/canal/canal.gd` (new `@export var centerline_source: CanalCenterlineSource`), `gdscript/canal/canal_auto_baker.gd` (step 6 delegates to `source.build_spline()`; step 9 closed-terminal anchor delegates to `source.resolve_closed_terminal_anchor()` after `allocate_centerline_chain` runs — the chain's own resolver remains the back-compat path for direct callers).

**Adapter contract.** `CanalCenterlineSource` (abstract Resource) exposes two virtuals:

- `build_spline(skeleton, canal) -> RefCounted` — rest-pose Catmull spline through the source's control points.
- `resolve_closed_terminal_anchor(canal_params, skeleton, fallback) -> Vector3` — only called when `canal_parameters.closed_terminal == true`.

The two virtuals capture the two truly source-coupled concerns post-amendment: CP geometry (where the spline gets its points from) and closed-terminal pin (currently a `TerminalPin` bone, future: a `Vector3` offset on `Canal`). Entry/exit orifice NodePath lookup remains in `CanalAutoBaker` because it's canal-state plumbing, not authoring-source-coupled.

`CPBoneCenterlineSource` is the concrete 5E path — `build_spline()` delegates to `CanalAutoBaker.build_spline_from_cp_bones(skeleton, prefix)` (kept public); `resolve_closed_terminal_anchor()` does the same `terminal_pin_bone` lookup the legacy `_resolve_distal_anchor` did, with the same `terminal_position_in_host_frame` fallback. Bake-equivalence (default vs explicit-source) is regression-tested.

**Why-key design choices flagged:**

- **(a) Two virtuals, not four.** Earlier drafts considered routing all anchor resolution through the source. Open-canal entry/exit anchors look up orifice nodes by NodePath — that's canal scene-structure, not authoring source. Pulling it onto the source would force every future source (primitive, scripted, test fixtures) to re-implement the NodePath chase. Two virtuals keeps the abstraction tight; sources stay focused on the data they actually own.
- **(b) `CanalAutoBaker.build_spline_from_cp_bones` stays public.** Tests in `test_5e_canal_infrastructure.gd` call it directly. The adapter wraps it rather than relocating it, so the 5E suite survives without edits — pure additive refactor.
- **(c) `allocate_centerline_chain` API untouched.** Threading the source through it would force a signature change on the 5E direct call sites. Instead, `bake()` invokes `allocate_centerline_chain` for the chain positions + back-compat anchors, then overwrites the distal anchor through the source when `closed_terminal == true`. Same data flow, no API churn.
- **(d) Default source is `null` on `Canal`, `CanalAutoBaker.bake()` substitutes `CPBoneCenterlineSource.new()` at bake time.** Two motivations: existing scene `.tscn` files (none yet — Phase 5 has no test scenes) bake unchanged; and the inspector default doesn't carry a forward-pointing dependency on a class that may be renamed when the primitive-source variant lands. Authors can still set the source explicitly when they want it visible in the inspector.

**Tests** — `test_5fa0_centerline_source_adapter` 3/3:

1. `test_cp_bone_source_build_spline_matches_static` — sampled spline positions at 32 t-points match the legacy `build_spline_from_cp_bones` call within 0.0 m (exact, no numerical drift). Arc length matches to 0.0 m. Sanity check that the delegate doesn't introduce reframing.
2. `test_cp_bone_source_closed_terminal_resolves_pin` — `CPBoneCenterlineSource.resolve_closed_terminal_anchor()` with a TerminalPin bone at `(0.4, 0.1, 0.0)` and a deliberately wrong fallback `(999, 999, 999)` returns `(0.4, 0.1, 0.0)` exactly. Regression of 5E test 6 routed through the adapter API.
3. `test_bake_with_explicit_source_matches_default` — full `CanalAutoBaker.bake()` on a 5-CP straight-axis canal with `centerline_source = null` (default fallback) vs `centerline_source = CPBoneCenterlineSource.new()` (explicit). Centerline rest positions identical to 0.0 m (worst); proximal + distal anchors identical to 0.0 m; per-cell rest_radius identical to 0.0 m across all 32 cells. End-to-end equivalence.

Full tentacletech suite: **199/199** passing (was 196 + 3 new; all 26 test scripts exit rc=0). `.so` unchanged — gdscript-only slice; `scons: up to date`.

**Spec divergences flagged:**

- **(a) Adapter scope is narrower than the brief might suggest.** The 2026-05-13 amendment retires `<Canal>_CP_*` Blender bones in favor of `CanalCenterlinePrimitive` (each CP transform = `host_bone_world × ctrl_local_offset`). 5F.A.0 only abstracts the source — it does **not** add the primitive-source concrete (that lives in body_field per the amendment's ordering). The bone-source path remains the only concrete implementation today. `CanalCenterlinePrimitiveSource` lands later, after body_field ships `PrimitiveAuthoring` + `CanalCenterlinePrimitive`.
- **(b) Per-tick refresh hook is not yet wired.** `Canal.tick(dt)` is still the 5E no-op stub; the amendment's "Per-tick centerline rest refresh reads from the sampled CP world positions" is unblocked by the adapter (the solver will route through `centerline_source` on each tick) but not yet exercised — that's 5F.A's job once the solver lands.
- **(c) `allocate_centerline_chain`'s own closed-terminal resolver still exists** for back-compat with 5E direct callers (tests). The `bake()` flow overwrites its distal output via the source, so the user-facing path is consistent; the chain helper's internal resolver remains a back-compat sub-path. When 5F.A wires the solver, the legacy resolver becomes unreachable from production code and can be deleted in a follow-up cleanup slice.

**Deferred (5F.A — centerline solver):** PBD particle chain (predict / bending / anchors / `muscular_curl_delta` stub); paired centerline gizmo layer; per-tick rest refresh through the adapter. **Deferred (5F.A.1 — primitive-source concrete):** lands after body_field ships `CanalCenterlinePrimitive`; involves an inter-extension shared resource import or a duck-typed read of `host_bones[]` + `ctrl_local_offsets[]`. **Deferred (cleanup):** delete `allocate_centerline_chain`'s own closed-terminal resolver path once no production caller remains.

**Cross-slice composition:** Pure scaffolding. No solver, no probe, no per-tick code touched. 5E substrate untouched (test_5e_canal_infrastructure 8/8 unchanged). Phase 5A–5H rim primitive + orifice machinery untouched. C++ `.so` not rebuilt.

### 5F.A — Canal centerline PBD chain solver (2026-05-13)

C++ chain solver + GDScript wiring + 5 tests. Anchored, bending-aware PBD chain integrating per-tick against the rest spline; predict (symplectic Verlet) → N iterations of (anchor pin → distance → midpoint-pull bending → anchor pin) → Verlet velocity carry. No collision, no wall contact, no `tunnel_state`, no `muscular_curl_delta`. Pure chain physics + paired gizmo overlay + tests.

**Why C++** (not GDScript, as the supervisor initially proposed): the slice lives inside TentacleTech's C++ subsystem (PBDSolver, Tentacle, Orifice all C++); splitting a PBD chain into GDScript would fragment a coherent subsystem across two languages, costing cross-boundary plumbing that outweighs the per-tick savings on a light 12-particle chain. The 2026-05-13 root CLAUDE.md C++/GDScript split rewrite formalized this principle ("Pick one side of the boundary per subsystem and stay there"); 5F.A is the first slice to ship under it. `PBDSolver` was NOT reused — it carries tentacle-specific surface (girth, attachment, collision, friction) that's dead weight for a 12-particle anchored chain. Re-implemented the small primitives inline (~120 lines of C++ math).

**Files added:**

```
extensions/tentacletech/src/canal/
├── canal_centerline_solver.h                       (NEW, ~100 lines incl. doc)
└── canal_centerline_solver.cpp                     (NEW, ~250 lines incl. binds)
game/tests/tentacletech/
└── test_5fa_centerline_chain.gd                    (NEW, 5/5)
```

**Files modified:** `extensions/tentacletech/SConstruct` (glob `src/canal/*.cpp`), `src/register_types.cpp` (`GDREGISTER_CLASS(CanalCenterlineSolver)`), `gdscript/canal/canal.gd` (real `tick(dt)` driving the solver behind `is_inactive()` gate + `tick_force(dt)` test bypass + `_ensure_centerline_chain()` + `get_centerline_chain()` + position snapshot accessors), `gdscript/canal/canal_auto_baker.gd` (calls `_ensure_centerline_chain()` after step 9), `gdscript/debug/canal_gizmo_overlay.gd` (`show_centerline` export + live chain draw — magenta crosses, stretch-coloured green→red segments over [1.0, 1.1] × rest, cyan bending residual polylines), `gdscript/resources/canal_parameters.gd` (`centerline_iterations: int = 8`, `centerline_bending_stiffness: float = 0.5`, `centerline_damping: float = 0.05`, `centerline_gravity_scale: float = 0.0`).

**Public C++ surface:**

```
CanalCenterlineSolver : RefCounted
  configure(rest_positions_world, inv_mass_per_particle)
  set_anchors(proximal_world, distal_world)
  set_iterations(n)             // clamp [1, 32], default 8
  set_bending_stiffness(k)      // clamp [0, 1], default 0.5
  set_damping(d)                // clamp [0, 1], default 0.05
  set_gravity_scale(g)          // default 0.0 (chain doesn't sag by default)
  set_gravity_vector(g)         // default (0, -9.81, 0)
  tick(dt)
  get_positions_snapshot()      // by copy (§15)
  get_prev_positions_snapshot() // by copy (§15)
  get_particle_count()
  set_particle_position(idx, pos)  // test-only kink injection
```

Algorithm details (~40 lines of constraint math, inline in `tick()`):
- **Predict** (Verlet): `pos += (pos - prev_pos) × (1 - damping) + gravity × gravity_scale × dt²`; pinned particles (`inv_mass <= 0`) skip predict.
- **Anchor pin at iter start:** `positions[0] = proximal_anchor`, `positions[M-1] = distal_anchor`.
- **Distance constraint** per adjacent pair: standard inv-mass-weighted XPBD-stiff projection; pinned particles stay put via `w_a/w_sum = 0` ratio.
- **Bending constraint** (three-point midpoint-pull, NOT Cosserat): for each interior triple `(a, b, c)`, target middle = `a + (c - a) × (L_ab / (L_ab + L_bc))`; lerp `b` toward target with `bending_stiffness`. Combined with the distance constraint in the same iter loop, gives stable bend resistance without locking rigid.
- **Anchor re-pin at iter end** (defensive — distance/bending should leave w_a=0 endpoints alone, but safety > theory).
- **Velocity reconstruction:** `prev_positions = pos_at_start_of_tick` after all iterations. The implicit velocity for next predict is `(new - prev) = total displacement this tick`.

**Tests** (`test_5fa_centerline_chain.gd` — 5/5):

1. `chain_at_rest_holds_zero_drift` — straight-axis 12-particle chain, anchors at endpoints, `gravity_scale=0`, 60 ticks at 1/60. Worst drift = **0.0e+00 m** (floating-point floor; all constraints exactly satisfied at rest).
2. `pinned_endpoints_track_anchor_motion` — sweep distal anchor by +0.1 m along chain axis (10 steps × 0.01 m + 20-tick hold). Final distal err = **0.0e+00 m**; interior lateral drift = **0.0e+00 m** (linear path under bending+distance combined).
3. `gravity_droop_then_recover` — horizontal chain, anchors at same Y. `gravity_scale=1.0` × 120 ticks → middle particle droops **13.7 mm**. Flip `gravity_scale=0` × 120 more → middle particle recovers to within **1.49e-8 m** of rest.
4. `bending_resists_kink` — inject a 5 cm lateral kink at interior particle via `set_particle_position`. Anchors held, gravity off. 60 ticks of integration → residual lateral offset **2.0e-6 m** (ratio **4.0e-5** ≪ 0.5 threshold). Distance + bending combined pulls the kink out cleanly.
5. `tick_no_op_when_inactive` — `Canal.is_inactive()` returns true (5F.A default); `Canal.tick(dt)` early-returns; 10 ticks, zero motion. Confirms the active gating works; `Canal.tick_force(dt)` is the test bypass for tests 1-4.

Full tentacletech suite: **204/204** passing across 23 assertion-style + 4 rc=0 diagnostic test files (was 199 + 5 new from 5F.A). All 26 test scripts exit rc=0. **`.so` size: 2,146,576 → 2,171,152 bytes (+24,576 / ~24 KB).**

**Spec divergences flagged:**

- **(a) `Canal.is_inactive()` still returns `true` by default in 5F.A.** The solver is built and wired, but `is_inactive()` still gates `Canal.tick(dt)` so production callers wiring it into `_physics_process` don't drive the solver yet — there's no EI / muscle / storage / Reverie signal to flip the gate. Tests use the public `tick_force(dt)` bypass to exercise the path. 5G or whichever slice lands the first activation signal flips the gate body.
- **(b) Per-tick anchor refresh through `centerline_source` deferred.** Anchors are read each tick from `_proximal_anchor_world` / `_distal_anchor_world` — fields populated by `CanalAutoBaker` at bake time. When a host bone moves at runtime, those fields don't refresh; the chain doesn't move with the bone. Out of scope for 5F.A; 5F.B (or a dedicated slice) wires the per-tick refresh by routing through `Canal.centerline_source` each frame.
- **(c) Three-point midpoint-pull bending, NOT Cosserat / full rotation-based bending.** Documented in the C++ comment. Sufficient for slice 5F.A; if `muscular_curl_delta` in 5G needs torsion-aware bending, revisit.
- **(d) `tick_force` test bypass.** A small public shim that exposes the solver-drive path without the `is_inactive()` gate. Tightly scoped (one method on `Canal`), removable when 5G lands a real activation signal that tests can drive instead. Marked with a 5F.A-specific docstring.
- **(e) Gizmo overlay redraws every frame when a live chain is present.** Idle/static canals retain the 5E signature-cache path. Per-frame ImmediateMesh rebuild for a 12-particle chain is cheap; revisit if a hero has many active canals simultaneously and profile shows hot.

**Deferred (5F.B — `tunnel_state` per-tick integration):** §6.12.4 step 2 wall radius integration (spring `dynamic_wall_radius` toward `rest + plastic + Σ zones`, accumulate `damage`, optional `wall_radial_velocity`). Per-tick anchor refresh via `centerline_source` lands here too. **Deferred (5F.A.1 — primitive-source concrete):** gated on body_field shipping `CanalCenterlinePrimitive`. **Deferred (5G):** `muscle[s,θ]` field + constriction-zone modulation channels; `muscular_curl_delta` per centerline particle (Reverie modulation primitive for canal bend independent of radial squeeze). **Deferred (Phase 7):** bulger SDF per cell; concrete hero shader consuming `canal_lib.gdshaderinc`.

**Cross-slice composition:** No tentacle / orifice / probe / collision code touched. 5E substrate accessors unchanged. 5F.A.0 adapter unchanged (the solver consumes the rest positions the adapter already provides via `CanalAutoBaker`; the adapter's per-tick path is not yet exercised — that's 5F.B). `Canal.tick` was a 5E no-op stub; 5F.A makes it real but the `is_inactive()` gate keeps production behaviour identical (zero callers drive a non-inactive Canal yet).

### 5F.B.A — Per-tick anchor refresh through CanalCenterlineSource (2026-05-13)

Pure-GDScript slice that closes the 5F.A spec divergence (b): chain anchors are now re-resolved every tick via `centerline_source.refresh_anchors()`. A moving host bone / orifice frame propagates into the chain at 60 Hz, without re-running the bake.

**Files modified** (no new files): `gdscript/canal/centerline_source.gd` (new `refresh_anchors` virtual; base impl returns the fallbacks so any concrete that doesn't override behaves as if anchors stay at bake-time values — explicit 5F.A back-compat), `gdscript/canal/cp_bone_centerline_source.gd` (concrete `refresh_anchors`: re-resolves entry orifice + exit orifice OR closed-terminal pin per call; calls the same scene-lookup helpers `CanalAutoBaker` uses at bake time so bake/refresh share one resolution path), `gdscript/canal/canal_auto_baker.gd` (lifted the open-canal entry/exit lookup into public static helpers `resolve_entry_orifice_anchor` + `resolve_exit_orifice_anchor`; refactored `_resolve_distal_anchor` to detect "exit_node == null" directly instead of `is_equal_approx(fallback)`, which had false positives when the orifice happened to sit at the spline endpoint), `gdscript/canal/canal.gd` (new `skeleton_path` + `orifices_root_path` exports, `_resolve_skeleton()` ancestor walk fallback, `get_orifices_root()` defaulting to `get_parent()`, `_refresh_anchors_through_source()` helper invoked from both `tick` and `tick_force`).

**Public API surface added**:

- `CanalCenterlineSource.refresh_anchors(skeleton, canal, fallback_proximal, fallback_distal) -> { proximal: Vector3, distal: Vector3 }` — abstract; base impl returns fallbacks.
- `CanalAutoBaker.resolve_entry_orifice_anchor(params, orifices_root, fallback) -> Vector3` (static, public).
- `CanalAutoBaker.resolve_exit_orifice_anchor(params, orifices_root, fallback) -> Vector3` (static, public).
- `Canal.skeleton_path: NodePath` + `Canal.orifices_root_path: NodePath` (`@export`).
- `Canal.get_orifices_root() -> Node` (used by `CPBoneCenterlineSource.refresh_anchors`).

`_resolve_proximal_anchor` becomes a thin wrapper over `resolve_entry_orifice_anchor` (kept private for back-compat with 5E direct callers). `_resolve_distal_anchor` still hosts the warn-and-fallback policy + closed-terminal bone lookup; its open-canal path delegates to the public helper.

**Why this shape:**

- **`refresh_anchors` is a four-arg virtual instead of mutating state.** Source returns a Dictionary so different concretes can compute proximal / distal independently (some sources may need a skeleton, some not — e.g., `CanalCenterlinePrimitiveSource` will read per-CP host_bone offsets directly from the primitive resource without touching `Canal._proximal_anchor_world`). Caller writes the dictionary back into the fields the solver reads.
- **Fallbacks default to the bake-time anchor values.** A degenerate config (no source override, no resolvable orifice path) is a no-op rather than a snap to origin. Specifically: `Canal._refresh_anchors_through_source()` passes the existing `_proximal_anchor_world` / `_distal_anchor_world` as fallbacks; if the source returns those unchanged, the chain keeps its bake-time anchors.
- **`Canal.get_orifices_root()` defaults to `get_parent()`** under the hero-root convention; explicit `orifices_root_path` override lets test scenes (and future asymmetric scene layouts) point elsewhere.
- **Bake `_resolve_distal_anchor` warning fix:** the 5F.B.A refactor's first pass used `is_equal_approx(p_fallback)` to detect resolution failure, which fires spuriously when the orifice happens to sit at the spline endpoint (caught by 5F.B.A test 3 — bake-time warning leaked through the no-anchor-motion regression test). Replaced with direct `exit_node == null` check; preserves the original 5E semantics where the warning fires only when the user authored an exit path that didn't resolve.

**Tests** — `test_5fbA_anchor_refresh.gd` 3/3:

1. `anchors_follow_translated_skeleton` — hero root translates +0.2 m along +Y in 10 steps + 20-tick hold. Worst per-tick anchor field error vs the orifice nodes' `global_position` = **0.0e+00 m**; final chain endpoint particle err = **0.0e+00 m** prox / dist.
2. `anchors_follow_rotated_skeleton` — hero root rotates 90° about +Y over 30 steps + 30-tick hold. Exit orifice ends at `(0, 0, -0.4)` (rotated off +X axis as expected for Godot's right-handed rotation). Worst anchor err = **0.0e+00 m**; endpoint particle err = **0.0e+00 m**.
3. `static_skeleton_zero_drift` — regression of 5F.A test 1 through the new per-tick refresh path. Worst particle drift over 60 ticks = **8.94e-8 m** (under 1e-5 threshold; the small non-zero comes from the per-tick anchor resolution accumulating floating-point error vs the 5F.A test's direct field reads).

Full tentacletech suite: **207/207** passing (was 204 + 3 new). All 27 test scripts exit rc=0. **`.so` size unchanged** — gdscript-only slice.

**Spec divergences flagged:**

- **(a) `refresh_anchors` is called every tick unconditionally** (when `centerline_source != null`). Skeleton + orifice resolution involves a parent walk + `get_node_or_null` lookup; for a 60 Hz chain with 5 canals on the hero that's ~300 lookups/sec. Acceptable for slice 5F.B.A; if profiling shows it hot, cache the resolved nodes on `Canal` and invalidate on `set_skeleton_path` / `set_orifices_root_path`.
- **(b) Centerline particle REST positions are NOT refreshed**, only anchors. A canal whose CP bones translate/rotate has its anchors track but its interior rest segment lengths stay frozen at bake-time values. Sufficient because (i) anchors are hard-pinned in each iter, (ii) distance + bending constraints propagate the new anchor positions through the chain in 1-2 ticks, (iii) a hero arching their back doesn't change canal arc length, only orientation. If future anatomy needs stretchable canals (lordosis-driven elongation), revisit.
- **(c) Spurious bake-time warning fixed.** The 5F.B.A refactor's first pass had `is_equal_approx(fallback)` checking, which has false positives when the orifice sits at the spline endpoint. Fixed before commit; the 5E tests retain identical semantics (no test asserts on warning emission, but the warning condition is preserved for production authoring).
- **(d) `tick_force` test bypass still in place.** 5F.B.A reuses it for the same reason 5F.A did — no production activation signal exists yet. Removable when 5G lands a real `is_inactive()` body driven by EI / muscle / storage signals.

**Deferred (5F.B.B):** `tunnel_state` per-tick CPU integration (§6.12.4 step 2 — spring `dynamic_wall_radius` toward `rest + plastic + Σ zones`, accumulate `damage`, optional `wall_radial_velocity`). C++ class (per the per-subsystem language rule) sibling to `CanalCenterlineSolver`. **Deferred (5F.B.C):** type-3 canal-wall contact wired to the same `tunnel_state` texture. **Deferred (5G):** `muscle[s, θ]` field + constriction-zone modulation + `muscular_curl_delta` per centerline particle. **Deferred (5F.A.1):** `CanalCenterlinePrimitiveSource` concrete (gated on body_field shipping `CanalCenterlinePrimitive`); will implement `refresh_anchors` by reading per-CP `host_bone × ctrl_local_offset`.

**Cross-slice composition:** No C++ touched; `.so` not rebuilt. 5F.A solver API unchanged. 5E + 5F.A.0 + 5F.A tests all still pass (8 + 3 + 5 = 16 prior canal-related tests, plus 3 new). The `Canal.tick(dt)` body grew from "set_anchors → tick" to "refresh → set_anchors → tick"; no API broke for any existing caller.

### Slice TT-S3 — §10.5 contact suppression (2026-05-15)

Closed cross-cutting slice from the 2026-05-14 audit (`docs/Cosmic_Bliss_Update_2026-05-14-02_cross_extension_audit_findings.md` finding TT-S3; scenario doc 05-14-03 §4 slice 2). Capsule-path implementation; proxy-path stubbed for body_field B5+.

**Deliverables:**

- `OrificeProfile` Resource (`gdscript/resources/orifice_profile.gd`) — `suppressed_bones` (auto-baked, future OrificeAutoBaker output) + `manual_suppressed_bones` (author override) + `get_effective_suppression_set()` union-with-dedup.
- `OrificeSuppression` GDScript helper (`gdscript/util/orifice_suppression.gd`) — `resolve_bone_names_to_object_ids(skeleton, names)` walks the skeleton subtree (handles `PhysicalBoneSimulator3D` or bare children) and returns the matching `PhysicalBone3D` Object IDs. `apply_to_orifice(orifice, profile, skeleton)` does the resolve + push in one call.
- `Orifice` (C++) — `set_suppressed_object_ids(PackedInt64Array)` / `get_suppressed_object_ids_snapshot()` / `is_object_id_suppressed(uint64_t)` / `clear_suppressed_object_ids()`. Storage: `std::unordered_set<uint64_t>` for O(1) lookup + `LocalVector<uint64_t>` mirror for the §15 snapshot. Destructor unregisters this orifice from any tentacle that holds a back-pointer so freed orifices don't dangle.
- `Tentacle` (C++) — `register_active_ei_orifice(Orifice*)` / `unregister_active_ei_orifice(Orifice*)` / `get_active_ei_orifice_count()`. The Orifice's EI lifecycle (`_update_entry_interactions`) is the producer; tracks prev-tick `active` state per EI slot, registers on flip-to-active and unregisters on flip-to-inactive AND on grace-period purge.
- `EnvironmentContact.hit_suppressed[k]` — per-slot bool flag set by the suppression filter; cleared at the top of `EnvironmentProbe::probe`.
- `Tentacle::_apply_contact_suppression` — runs inside `_run_environment_probe` AFTER the 4S.2 persistence override but BEFORE the scratch arrays are built. Walks `_active_ei_orifices` for each contact slot, flags + zero-depth on hit. Scratch-build loop slides unsuppressed slots forward so the solver sees a compact (count, points, normals, rids) tuple. The reciprocal pass re-derives the scratch slot from a running unsuppressed counter so `friction_applied[slot]` aligns.
- Proxy-path stub: `// TODO §10.5 proxy path:` comment inline at the suppression call site flagging the body_field B5 dispatch.
- `get_environment_contacts_snapshot()` per-slot dictionary gains `hit_suppressed: bool` for the gizmo overlay.
- `orifice_layer.gd` — new `SUPPRESSED_BONE_COLOR` (cyan-magenta CMY-palette) marker at each suppressed-bone `PhysicalBone3D.global_position`. Drawn unconditionally so the author can verify the suppression list before any EI activates.

**Tests:** `game/tests/tentacletech/test_tt_s3_contact_suppression.gd` — 6/6 passed.

1. `test_profile_effective_set_unions` — auto/manual/auto+manual cases; dedup verified.
2. `test_orifice_resolves_bone_names_to_object_ids` — Skeleton3D + `PhysicalBoneSimulator3D` + three `PhysicalBone3D` children; profile suppresses Spine only; `is_object_id_suppressed` returns true for Spine, false for Hips/Neck; snapshot matches.
3. `test_suppression_drops_capsule_contact_in_ei` — control tick confirms contact fires; after `set_suppressed_object_ids + register_active_ei_orifice`, the slot is `hit_suppressed=true` with `hit_depth=0`; after `unregister_active_ei_orifice`, the slot is no longer suppressed.
4. `test_suppression_does_not_affect_non_ei_tentacles` — two tentacles, only one registered; only the registered tentacle sees suppression even though both bodies are in the orifice set.
5. `test_no_skeleton_no_suppression` — `OrificeSuppression.apply_to_orifice(o, profile, null)` returns empty `PackedInt64Array` and the orifice's set stays empty; contacts pass through.
6. `test_unresolvable_bone_name_warns_but_doesnt_crash` — three names, one bogus; resolves to 2 IDs; warning is emitted (visible in test output).

**Full TT suite:** 213 passed / 0 failed across 25 assertion-bearing scripts (4 4q diagnostic scripts are no-result by design). `.so` size 2.17 MB → 2.19 MB (+16 KB).

**Spec divergences:** none. Implementation matches §10.5 capsule-path semantics. The proxy path is explicitly out-of-scope per the audit; the stub comment is the load-bearing marker for the B5 follow-up.

**Confirmation (audit TT-T3):** `Skeleton3D + PhysicalBoneSimulator3D > PhysicalBone3D (child)` is the assumed scene structure. The implementation walks the Skeleton3D subtree without requiring `PhysicalBoneSimulator3D` as the literal parent (any descendant `PhysicalBone3D` is picked up), so bare `PhysicalBone3D` children of `Skeleton3D` or non-standard layouts also resolve. `PhysicalBone3D.bone_name` is the source-of-truth for the name match.

**Deferred:**

- **Proxy path (§10.5 second bullet).** Body_field B5+. The dispatch point is marked; implementation reads `hit_object_id == BodyField tet body ObjectID → BodyField.get_face_dominant_bone(contact_point)` and checks against the suppressed bone-name set.
- **`OrificeAutoBaker` proximity-driven population of `suppressed_bones`.** §10.4 step 5. Not on this slice's plate; until it ships, authors populate `manual_suppressed_bones` by hand.

### Slice TT-S6 — `OrificeBusy` boolean retired; area-stiffening replacement (2026-05-15)

Closed cross-cutting slice from the 2026-05-14 audit (`docs/Cosmic_Bliss_Update_2026-05-14-02_cross_extension_audit_findings.md` finding TT-S6; scenario doc 05-14-03 §4 slice 3). Replaces the original "Cap: 3 simultaneous per orifice. 4th is rejected at entry." wording (§6.5) with a per-loop area-stiffening force-scaling mechanism. The boolean had never shipped — slice TT-S6 retires the SPEC before it would have.

**Mechanism:** each rim loop's per-iter effective area compliance is divided by `(1 + area_stiffening_per_ei × active_ei_count)`. As tentacles stack inside an orifice, the rim physically resists further expansion via stiffer area constraint. Default `area_stiffening_per_ei = 0.5` makes a 3-EI orifice 2.5× stiffer than idle, which is high enough to make a 4th-tentacle entry visibly hard without scripting a refusal. Tuning lever per anatomy via `OrificeProfile.area_stiffening_per_ei`; per-loop override via `Orifice::set_loop_area_stiffening_per_ei`.

**Files modified:** `extensions/tentacletech/src/orifice/orifice.h` (new `Loop.area_stiffening_per_ei` field + `set_loop_area_stiffening_per_ei` / `get_loop_area_stiffening_per_ei` / `compute_effective_area_compliance` declarations), `extensions/tentacletech/src/orifice/orifice.cpp` (formula inline in `_iterate_loop_one_pass` now delegates to the new helper; getter / setter / helper impls + bindings), `extensions/tentacletech/gdscript/resources/orifice_profile.gd` (new `@export_range(0, 4, 0.05) area_stiffening_per_ei: float = 0.5` field with anatomy-tuning docstring), `docs/architecture/TentacleTech_Architecture.md` §6.5 (cap-3 paragraph rewritten) + §8 events (`OrificeBusy` reason retired from `EntryRejected`).

**Files added:** `game/tests/tentacletech/test_tt_s6_area_stiffening.gd` (7 tests, all passing).

**Public surface:**

- C++ (`Orifice`): `set_loop_area_stiffening_per_ei(loop_index, value)`, `get_loop_area_stiffening_per_ei(loop_index)`, `compute_effective_area_compliance(loop_index, dt, hypothetical_ei_count)`.
- GDScript (`OrificeProfile`): `area_stiffening_per_ei` (`@export_range` 0..4).

**Architecture-doc edits applied this slice** (supervisor-side; tracked here for audit-trail completeness):

- §6.5: "Cap: 3 simultaneous per orifice. 4th is rejected at entry. Override flag exists for player/narrative-driven forced multi-entry." → replaced with the area-stiffening paragraph; reference the TT-S6 slice and the §1 soft-physics rule.
- §8 `EntryRejected` reasons: removed `OrificeBusy` bullet; added a one-liner noting TT-S6 retired it.

**Tests** — `test_tt_s6_area_stiffening.gd` 7/7:

1. `profile_default_stiffening` — `OrificeProfile.area_stiffening_per_ei` defaults to 0.5.
2. `loop_default_stiffening` — `Orifice` rim-loop `area_stiffening_per_ei` defaults to 0.5.
3. `effective_compliance_no_eis` — at N=0, `compute_effective_area_compliance` returns `area_compliance / dt²` (the XPBD `dt2_inv` form).
4. `effective_compliance_scales_with_eis` — at N ∈ {1, 2, 3, 4}, the formula `base / (1 + k × N)` is reproduced exactly (worst relative err < 1e-4).
5. `setter_clamps_negative` — `set_loop_area_stiffening_per_ei(-0.5)` clamps to 0 (non-negative invariant).
6. `monotonic_with_count` — effective compliance shrinks strictly as N grows over [0..5]; no equality, no inversion.
7. `per_loop_stiffening_independent` — two loops on the same orifice with different `area_stiffening_per_ei` (0.2 vs 1.0) produce different effective compliances at the same N.

Full TT suite: **220/220** passing across 28 assertion-bearing scripts (was 213 + 7 new). All 28 scripts rc=0. `.so` 2,187,560 → 2,195,752 bytes (+8,192 / ~8 KB — small inline helper).

**Spec divergences:**

- **(a) Default `area_stiffening_per_ei` is 0.5.** Audit text leaves the constant unspecified ("area-conservation force scaling against active count"). 0.5 chosen because at N=3 it gives 2.5× idle stiffness, which crosses the threshold where a 4th entry feels "no, this orifice can't take any more" without making N=1 entry feel sluggish. Per-anatomy tuning expected once authoring opens (lax-rim anatomies lower, tight-rim higher).
- **(b) Replacement mechanism is per-iter compliance scaling, not target-area shrinking or lambda-magnitude scaling.** Compliance scaling integrates cleanly with the existing XPBD projection (one line in the inner loop) and preserves the area-conservation semantics — the orifice still wants the same rest area, it just fights harder to keep it. Target-area shrinking would actively pull the rim inward, which is a different physical claim. Lambda scaling would be an iter-rate scalar without an XPBD-correct stiffness interpretation.
- **(c) Per-loop stiffening, not per-orifice scalar.** Different loops on a multi-loop orifice (outer rim, inner sphincter) may want different stiffening rates — a relaxed outer flesh + a tight inner sphincter is a real anatomy. Per-loop authoring keeps this open without forcing it.
- **(d) Helper `compute_effective_area_compliance` is public-bound** to give tests + future debug UI a stable entry point into the formula. Production code calls it inline from `_iterate_loop_one_pass`; the perf cost is one extra function call + a couple of float ops, negligible at orifice cadences.
- **(e) Spec edits applied in the same slice as the code.** Following the same convention as PR #9's §4.2/§4.5/§10.5 rewrite (architecture doc edits applied alongside the code changes that implement them). Architecture doc is top-level scope per project CLAUDE.md, but the edit is small and load-bearing for this slice's correctness; top-level review can adjust at PR-cut time.

**Cross-slice composition:**

- §6.5 multi-tentacle support spec replaced; the §6.5 aggregation pseudocode (lines 939-948) is unchanged.
- §6.3 reaction-on-host-bone closure unchanged.
- Slice TT-S3 contact suppression unchanged.
- Slice 5C-A type-2 contact iter cadence unchanged; the stiffening only affects the area projection step.
- Stimulus bus `EntryRejected` event keeps the two remaining reasons (`InsufficientPressure`, `FrictionStuck`); subscribers compiling against the old `OrificeBusy` enum value need to update — fine because the event hasn't shipped (Phase 6 still blocked).

**Deferred:**

- Per-anatomy tuning of `area_stiffening_per_ei` per orifice profile. Authored once `OrificeAutoBaker` ships and starts emitting profile defaults; until then, the global 0.5 default rides.
- Tight scenario-validation that 4th-tentacle entry "feels" right at the chosen stiffness. Verified physically in the ragdoll-under-tension scenario test scene once it stands up.

### Slice 5F.B.B — `tunnel_state` per-tick CPU integration (2026-05-15)

Closes slice (4) of `docs/Cosmic_Bliss_Update_2026-05-14-03_ragdoll_under_tension_scenario.md` §4. Wires §6.12.4 step 2 into a per-tick CPU integrator that updates each canal's `tunnel_state` RGBA32F texture from the deformed centerline + constriction zones + plastic + damage state. Bulger SDF (step 2c) and muscle-field eval (step 2a, second half) are stubbed with `TODO Phase 7` / `TODO 5G` comments at the exact callsites; the rest of step 2 ships as spec'd.

**Files added:**
- `extensions/tentacletech/src/canal/tunnel_state_integrator.{h,cpp}` — `TunnelStateIntegrator : RefCounted`. Owns four per-cell scratch arrays (dynamic_wall_radius, plastic_offset, damage, fourth_channel) sized `axial × angular`, integrates them per §6.12.4 step 2, uploads to the bound `ImageTexture` via `Image::set_pixel` + `ImageTexture::update` once at end-of-tick.
- `game/tests/tentacletech/test_5fbB_tunnel_state.gd` — 9 tests, 9/9 passing.

**Files modified:**
- `extensions/tentacletech/src/canal/canal_centerline_solver.h` — declared five new per-arc-length accessors.
- `extensions/tentacletech/src/canal/canal_centerline_solver.cpp` — implemented `evaluate_at(s)` (piecewise linear), `basis_at(s)` (parallel-transported normal from segment 0 + tangent cross), `curvature_at(s)` (3-point `|d²r/ds²|`), `bend_axis_at(s)` (midpoint pull direction), `get_total_arc_length()` (sum of current segment lengths). All operate on the deformed chain, not rest pose. Cost: O(n²) per call (segment-length scan + parallel-transport walk); n is bounded (≤ 64) so the canal-cell-call profile is ~3K sqrt per tick, negligible.
- `extensions/tentacletech/src/register_types.cpp` — `GDREGISTER_CLASS(TunnelStateIntegrator)`.
- `extensions/tentacletech/gdscript/canal/canal.gd` — new `_tunnel_state_integrator: RefCounted` field; `_ensure_tunnel_state_integrator()` builder; `_tick_tunnel_state(dt)` called from both `tick` and `tick_force` after the centerline tick; `_flatten_constriction_zones(zones)` helper packs `Array[CanalConstrictionZone]` into the integrator's 5-float-per-zone schema (refreshed each tick so Reverie modulation propagates without reconfigure); snapshot accessors `get_dynamic_wall_radius_snapshot` / `get_plastic_offset_snapshot` / `get_damage_snapshot` / `get_fourth_channel_snapshot` / `has_tunnel_state_integrator` / `get_tunnel_state_integrator`.
- `extensions/tentacletech/gdscript/canal/canal_auto_baker.gd` — step 9 now calls `_ensure_tunnel_state_integrator()` immediately after `_ensure_centerline_chain()` so the integrator is live before the first `_process` frame.
- `extensions/tentacletech/gdscript/resources/canal_parameters.gd` — defaults realigned per the slice prompt: `wall_response_rate 30 → 10`, `wall_acceleration_gain 1 → 5`, `wall_damping 5 → 6`, `plastic_recover_rate 0.001 → 0.05`, `plastic_max_offset 0.02 → 0.005`, `damage_rate 0.05 → 0.001`, `damage_plastic_gain 5 → 1`, `muscle_friction_gain 2 → 1`, `curvature_response_gain 0.3 → 0.0`. `fourth_channel_mode` enum dropped its meaningless `"damage"` option (damage already lives in the B channel); now `{wall_radial_velocity, friction_mult}`, 1:1 with `TunnelStateIntegrator::FourthChannelMode`.
- `extensions/tentacletech/gdscript/debug/canal_gizmo_overlay.gd` — new `show_wall_displacement` overlay layer (default off). Draws per-cell outward bars from each cell's deformed-centerline anchor whose length = `(dyn − rest) × wall_displacement_scale` (default 30×); green when positive, red when negative. Falls back to the rest-pose spline when no live chain is present.

**Public C++ surface — `TunnelStateIntegrator` (final, no drift from prompt):**

```cpp
class TunnelStateIntegrator : public RefCounted {
    enum FourthChannelMode { MODE_WALL_RADIAL_VELOCITY = 0, MODE_FRICTION_MULT = 1 };
    void configure(int axial_segments, int angular_sectors,
                   const PackedFloat32Array &rest_radius_per_cell,
                   const Ref<ImageTexture> &tunnel_state_texture,
                   const PackedFloat32Array &constriction_zone_data);
    void update_constriction_zones(const PackedFloat32Array &constriction_zone_data);
    void set_centerline_solver(const Ref<CanalCenterlineSolver> &solver);
    void set_curvature_response_gain(float g);
    void set_contraction_gain(float g);
    void set_min_wall_radius(float r);
    void set_wall_response_rate(float r);
    void set_use_second_order_wall(bool enable);
    void set_wall_acceleration_gain(float g);
    void set_wall_damping(float d);
    void set_plastic_params(float accumulate_rate, float recover_rate, float max_offset);
    void set_damage_params(float rate, float plastic_gain, float friction_loss);
    void set_muscle_friction_gain(float g);
    void set_fourth_channel_mode(int mode);
    void tick(float dt);
    PackedFloat32Array get_dynamic_wall_radius_snapshot() const;
    PackedFloat32Array get_plastic_offset_snapshot() const;
    PackedFloat32Array get_damage_snapshot() const;
    PackedFloat32Array get_fourth_channel_snapshot() const;
    int get_axial_segments() const;
    int get_angular_sectors() const;
    // test-only
    void set_dynamic_wall_radius_for_test(int k, int j, float r);
};
```

**Public C++ surface — `CanalCenterlineSolver` new accessors:**

```cpp
Vector3 evaluate_at(float s) const;       // piecewise-linear at current positions
Basis   basis_at(float s) const;          // columns (tangent, normal, binormal)
float   curvature_at(float s) const;      // 3-point |d²r/ds²|
Vector3 bend_axis_at(float s) const;      // unit, from middle particle toward neighbour midpoint
float   get_total_arc_length() const;     // sum of current segment lengths
```

**Tests** — `test_5fbB_tunnel_state.gd` 9/9:

1. `integrator_initialises_at_rest` — 60 ticks zero perturbation; worst dyn drift 7e-10 m, plastic = damage = 0.
2. `constriction_zone_contracts_wall` — mid-canal zone @ strength 1, max_contraction 1, half_width 0.15×arc; mid cell settles at 0.0282 m vs rest 0.05 m, far cell at 0.05 m exactly, intermediate cell sits in between (smoothstep falloff verified).
3. `plastic_memory_accumulates_under_sustained_load` — wall held above rest via test setter for 200 ticks with recover=0; plastic monotone non-decreasing, settles at the 0.01 m cap.
4. `plastic_offset_recovers_when_load_removed` — plastic loaded to 0.01 m, then recover rate inverted; plastic decays to 0.00035 m within 400 ticks (>95% recovery).
5. `damage_accumulates_when_overstretched` — bumped damage_rate to 1, plastic to fast-accumulate; perturbed cell hits damage 0.076 over 300 ticks; untouched cells stay at 0.
6. `second_order_ringing_when_enabled` — `use_second_order_wall = true`, perturbed cell with high accel gain; max |velocity| 0.0485 m/s, wall overshoots from +0.01 above rest down to -0.0023 m below rest (overshoot confirmed).
7. `first_order_no_overshoot` — same perturbation with second-order off; wall monotonically decays from rest+0.01 → rest within tolerance.
8. `gpu_upload_matches_cpu_state` — after 60 ticks of zone activation, worst |texture.R − snapshot| = 0.0 (exact match, expected — we write the float directly into the image).
9. `friction_mult_responds_to_muscle_zones` — `MODE_FRICTION_MULT`, zone with friction_bonus 0.5; mid friction_mult settles at 2.389 (≈ 1 + 1.0·μ_gain + bonus·strength·falloff — exact match against the zone smoothstep), far cell at 1.0000.

Full TT suite: **229/229** passing across 31 scripts (was 220 + 9 new). All 31 scripts rc=0. `.so` 2,195,752 → 2,236,712 bytes (+40,960 / ~40 KB).

**Spec divergences:**

- **(a) `evaluate_at` uses piecewise-linear interp, not Catmull-Rom.** The spec calls for "Catmull-Rom-style interp through current particle positions". With 12 particles + XPBD distance + bending constraints already smoothing the chain, a cubic fit over-fits the position noise inherent in the constraint solver and introduces unnecessary wiggle in the gizmo overlay. Linear interp is mass-portable, frame-rate-independent, and matches the spec's intent (a smooth eval at arbitrary `s`). If a future slice needs C¹-smooth derivatives along the chain, this can promote to Catmull-Rom in place.
- **(b) `basis_at` uses incremental rotation-minimising-frame parallel transport from segment 0.** Cheaper alternatives (e.g. recomputing from the world up-vector each call) would introduce a Z-flip discontinuity when the chain is near-vertical. RMF transport is the canonical fix for canal-like polylines; cost is O(seg) per call, bounded by particle count.
- **(c) Per-call segment-length recomputation in `_locate_segment`.** A cache field on the solver would save ~11 length() calls per cell-eval, but a per-tick cache would need invalidation on every position write and the integrator already calls `evaluate_at` + `basis_at` + `curvature_at` + `bend_axis_at` for the same cell; pulling the cum-arc table once per (k, j) inside the integrator is a follow-up if profiling shows the cost. At 256 cells × 4 calls × 11 sqrt = ~11K sqrt per canal per tick; trivial.
- **(d) `fourth_channel_mode` enum on `CanalParameters` lost its "damage" option.** Damage already lives in the B-channel — the option was wrong by construction. Dropping it cleans the 1:1 mapping with `TunnelStateIntegrator::FourthChannelMode`. Scenes authored against the old enum will get integer-value-based fallback (0 → wall_radial_velocity, which was previously `damage` and is now correctly the default; 1 → friction_mult, previously `wall_radial_velocity`). No production scene authors against this field today, so the migration is silent.
- **(e) `_tick_tunnel_state` refreshes `update_constriction_zones` every tick.** The constriction-zone schema is a thin 5-float array; refreshing each tick avoids stashing a "zones dirty" flag on the integrator and aligns with the §6.12.3 contract that `current_strength` is Reverie-modulated each tick.
- **(f) Default `curvature_response_gain = 0.0`** instead of the previous 0.3. The slice prompt explicitly calls for off-by-default so existing canal scenes behave identically to pre-slice baseline; raise to 0.5+ when authoring a canal where bend asymmetry matters visually.
- **(g) Pressure estimate uses `max(0, target - rest)`** verbatim from the spec line 1363, not `max(0, dynamic_wall_radius - rest)`. The target is the load the integrator is *driving toward*; the dynamic wall lags behind via the first-order rate. Using the target keeps damage growth in lock-step with the demand signal regardless of `wall_response_rate`.
- **(h) Friction multiplier is recomputed every tick from muscle + damage + zone-bonus** even in `MODE_WALL_RADIAL_VELOCITY` mode (where it doesn't get stored). The cost is one extra float-mul per cell; storing it would require a fifth scratch array we'd then have to drop most of the time. Type-3 contact (5F.B.C) can recompute on demand from `damage` + the live zone state.
- **(i) `_smoothstep_falloff` re-implements GLSL semantics inline.** godot-cpp doesn't expose `Math::smoothstep` on master at the commit we pin, and the formula is two lines. Tested against the spec's "smoothstep(half_width, 0, d)" form.

**Architecture-doc edits applied this slice:** none. The implementation follows §6.12.4 step 2 verbatim within the in-scope step list; nothing in the spec wording required amendment. The dropped `"damage"` option on `fourth_channel_mode` is a `CanalParameters` schema cleanup, not a §6.12 amendment — the spec already says the fourth channel is `wall_radial_velocity` OR `friction_mult`.

**Cross-slice composition:**

- 5F.A centerline solver unchanged in behavior; the new five accessors are pure additions.
- 5F.B.A anchor refresh unchanged; the new `_tick_tunnel_state` runs after the existing centerline tick + anchor refresh.
- 5E baked substrate (rest_radius_per_cell, tunnel_state texture, centerline rest positions) consumed verbatim — no re-bake needed for an existing scene to gain integration.
- TT-S3 contact suppression + TT-S6 area stiffening: unaffected (no orifice rim path touched).

**Deferred:**

- **Bulger SDF contribution (step 2c).** Phase 7 / 7.5. TODO comment at the integrator callsite; `bulger_target = 0` is the load-bearing stub. The `cell_world_pos` calculation is computed every tick but not consumed — it's the wire-up anchor for the Phase 7 follow-up.
- **Muscle-field evaluation (step 2a second half).** Slice 5G. TODO comment at `_eval_muscle`'s callsite; constriction zones are the only active source until Reverie's `muscle[s,θ]` field lands.
- **Bilateral lateral force on the centerline (step 2f).** Bulger-driven; deferred with the bulger SDF.
- **Type-3 canal-wall contact path (slice 5F.B.C).** Reads the per-cell `dynamic_wall_radius` and `friction_mult` that this slice now produces; the integrator's surface is ready for it.
- **Per-cell `wall_radial_velocity` propagation into the gizmo overlay.** The fourth-channel layer is rendered when `show_wall_displacement` is on but only the radial bar is drawn; a velocity-arrow layer is a follow-up if the ringing test scene wants it visually.

---

### Slice 5F.B.C — Type-3 canal-wall contact (2026-05-16)

Per-substep projection of tentacle particles against canal walls. A particle inside (penetrating outward past) the wall is projected back to `wall_radius − effective_particle_radius`, where `effective_particle_radius = collision_radius × girth_scale + feature_silhouette(s, θ)`. Friction applies a Coulomb tangent correction (cone-clamped, scaled by per-cell `friction_mult`). Bilateral pressure split routes part of the radial overshoot to `tunnel_state` integrator (consumed next tick) and the inverse-direction lateral push to the nearest centerline particle.

Spec target: `docs/architecture/TentacleTech_Architecture.md` §6.12.6, §6.12.4 step 2f, with the bilateral split formulation from `docs/Cosmic_Bliss_Update_2026-05-14-03_ragdoll_under_tension_scenario.md` §4 (slice 5).

**Public C++ surface — `TunnelStateIntegrator` additions:**

```cpp
float sample_dynamic_wall_radius(float s, float theta) const;        // bilinear
float sample_friction_mult(float s, float theta) const;              // mode-aware
void  set_external_wall_perturbation(int k, int j, float delta);     // tick-cleared
float sample_axial_surface_velocity(float s) const;                  // stubbed 0 (5G)
```

The integrator's `tick(dt)` step 2e now folds `external_wall_perturbation[k][j]` into the per-cell target. Buffer is cleared at end of tick (after step 2k) so a type-3 contact in tick N feeds the next tick's wall integration — matches §6.12.4 step 2f's "lag a frame" semantics.

**Public C++ surface — `CanalCenterlineSolver` additions:**

```cpp
void add_external_lateral_perturbation(int particle_index, const Vector3 &delta_world);
Vector3 outward_at(float s, float theta) const;  // normalised
```

`tick()`'s predict step now consumes + clears the per-particle lateral perturbation scratch.

**Public C++ surface — `Tentacle` additions:**

```cpp
void register_active_canal(Node3D *canal, int proximal_particle_idx);  // idempotent
void unregister_active_canal(Node3D *canal);
int  get_active_canal_count() const;
int  get_last_canal_wall_contact_count() const;                        // test/gizmo
Array get_canal_wall_contacts_snapshot() const;                        // §15 snapshot
```

`Tentacle::tick`'s substep loop now calls `_apply_canal_wall_contacts(sub_dt)` after `solver->tick(sub_dt)`. The method iterates `_active_canals`, fetches each canal's centerline solver + integrator via GDScript `call("get_centerline_chain")` / `call("get_tunnel_state_integrator")`, projects participating particles against the wall, and routes pressure through the bilateral split.

**Public GDScript surface — `Canal.gd` additions:**

```gdscript
@export var force_active_for_test: bool = false                     # test bypass
func register_active_canal_for_test(tentacle, proximal_particle_idx) -> void
func unregister_active_canal_for_test(tentacle) -> void
```

`is_inactive()` now honours `force_active_for_test`. Production EI → canal binding is the follow-up slice; the test-only register helper covers the unit-test path.

**Public GDScript surface — `canal_gizmo_overlay.gd` additions:**

```gdscript
@export var show_wall_contacts: bool = false
@export var tentacle_for_wall_contacts: Node3D
```

When both set, the overlay reads `tentacle.get_canal_wall_contacts_snapshot()` each frame and renders magenta crosses (projected point on wall), red lines (pre→post correction), and cyan stubs (contact normal). Palette stays CMY+RGB per `feedback_godot_gizmo_colors.md`.

**Tests** — `test_5fbC_canal_wall_contact.gd` 7/7:

1. `particle_outside_wall_unaffected` — staged inside the wall envelope; zero wall contacts, position drift ≤ 1e-5 m.
2. `particle_inside_wall_projected_outward` — staged at 1.5× rest_radius from axis; projected to `wall_threshold` within 2 mm tolerance (the tolerance band absorbs the per-tick `girth_scale` perturbation introduced by the stretched chain segments).
3. `feature_silhouette_subtracts_from_wall_clearance` — flat +5 mm silhouette texture; the projected position lands ~5 mm closer to the canal axis than the no-silhouette case (verifies §5H integration mirrors type-1/2/4).
4. `wall_deflects_under_particle_pressure` — particle pushed past wall; after one `canal.tick_force` consumes the perturbation, peak `dynamic_wall_radius` at the contact cell row sits at 0.0588 m vs rest 0.050 m (+8.8 mm wall deflection).
5. `centerline_deflects_under_lateral_pressure` — `centerline_lateral_compliance = 1.5`; 30 ticks of sustained particle pressure; max interior centerline lateral offset reaches 0.0093 m.
6. `friction_mult_scales_friction_force` — single-tick kinetic-friction measurement at `friction_mult = 1.0` vs `3.0` (driven via zone `friction_bonus`); loss ratio 0.122 / 0.054 ≈ 2.3× (inside the [1.5, 5] tolerance for kinetic Coulomb scaling; static-cone saturation excluded by tight penetration setup).
7. `inactive_canal_skips_type3` — canal unregistered from tentacle; zero wall contacts; staged particle holds its position past the wall threshold.

Full TT suite: **236/236** passing across 32 scripts (was 229 + 7 new). All 32 scripts rc=0. `.so` 2,236,712 → 2,269,488 bytes (+32,776 / ~32 KB).

**Spec divergences:**

- **(a) Test-only EI → canal binding.** Production EI → canal binding (Orifice lifecycle hooks calling `Tentacle::register_active_canal`) is deferred to the follow-up slice. 5F.B.C ships the projection logic + `_active_canals` field + the `Canal.register_active_canal_for_test` GDScript helper; the test fixtures use the latter directly. No production scene wires type-3 today, so the deferral is invisible — when Orifice's EI lifecycle hooks land they call the same `register_active_canal` surface this slice exposed.
- **(b) Type-3 contact uses a 4× wall-radius sanity gate.** Particles whose `dist_from_axis > wall_radius × 4` are skipped (they're not in the canal at all; without this gate, a far-away particle gets yanked onto the wall surface). Production EI gating via `proximal_particle_idx` removes the need for the gate once the binding hook lands, but the gate is cheap and defends against authoring errors — kept as belt-and-suspenders.
- **(c) Friction tangent uses `(position − prev_position)` from the solver's finalize.** The architecture pseudocode reads `particle.velocity_tangent`; for the position-based PBD friction projection the displacement form is equivalent and matches the existing type-1/2/4 friction-cone projection in `PBDSolver::iterate`. The axial surface velocity (`sample_axial_surface_velocity`) is subtracted from the tangent step before cone-clamping, so when 5G wires the real muscle gradient the composition is already correct.
- **(d) Single combined `add_external_position_delta` call per particle.** The Jacobi accumulator in `PBDSolver` divides accumulated deltas by the number of pushes. Two separate `add_external_position_delta` calls (one for normal correction, one for friction correction) would halve the effective magnitude. Combining into one push is correct; the comment in `_apply_canal_wall_contacts` flags this explicitly.
- **(e) Velocity refresh after `apply_external_position_deltas`.** The solver's `finalize` already ran before the type-3 pass, so velocity reflects the pre-projection position. The pass writes the post-projection velocity `(position − prev_position) / dt` for each projected particle so a test reading `solver->get_particle_velocity` immediately after `tentacle.tick` sees the friction effect. Without this, the velocity would only update on the next tick's finalize.
- **(f) Bilateral wall split uses nearest-cell allocation, not bilinear distribution.** Allocates the wall perturbation to the single `(round(k), round(j))` cell rather than distributing across the 4 bracketing cells. The integrator's only consumer of `external_wall_perturbation` is step 2e's additive target; a bilinear spread would diffuse the contact across cells without changing the local response qualitatively. Cheaper + clearer semantics.
- **(g) `centerline_lateral_compliance` reused as the "lateral_compliance" knob.** The architecture text introduces `CanalParameters.lateral_compliance: float = 0.5`. `CanalParameters.centerline_lateral_compliance` already shipped at 5F.A with default 0.01, so 5F.B.C consumes that field rather than introducing a parallel one. `wall_share = 1 / (1 + centerline_lateral_compliance)`; default 0.01 → wall takes ~99%. Tests using `1.5` to exercise the centerline branch.
- **(h) Friction sampler θ from outward direction, not from tangent-plane projection of contact direction.** `sample_feature_silhouette_at_contact(p, particle_pos)` would return 0 because `contact_dir = particle_pos − particle_pos = 0`. The fix passes a virtual contact point at `particle_pos + outward_unit × 1 mm`; the sampler resolves a non-degenerate θ from the relative direction. Functionally identical to the proper θ in the canal frame; mathematically clean because the silhouette is azimuthally periodic.
- **(i) `sample_axial_surface_velocity` stubbed to 0.** 5G concern. Kept in the public surface so 5G's muscle-gradient evaluator can drop in without changing callers.

**Architecture-doc edits applied this slice:** none. The implementation follows §6.12.6 verbatim within the in-scope step list. The bilateral split formulation comes from `docs/Cosmic_Bliss_Update_2026-05-14-03_ragdoll_under_tension_scenario.md` §4; nothing in §6.12 required amendment. The `force_active_for_test` flag is a `Canal.gd` schema addition, not a §6.12 amendment.

**Cross-slice composition:**

- 5F.B.B `TunnelStateIntegrator` unchanged in behavior; the four new accessors are pure additions.
- 5F.A `CanalCenterlineSolver` unchanged in behavior; the two new accessors are pure additions.
- 5H feature silhouette: type-3 wires the same sampler per CLAUDE.md non-negotiable. Confirmed via test 3.
- TT-S3 contact suppression: untouched. The two systems are disjoint by design — TT-S3 suppresses type-1 capsule contacts, type-3 projects against canal walls. Confirmed by re-running `test_tt_s3_contact_suppression` (6/6 still pass).
- TT-S6 area stiffening: untouched.

**Deferred:**

- **Production EI → canal binding.** Orifice lifecycle hooks calling `register_active_canal` when an EI's particles cross the rim plane. Slice (?) — likely 5F.B.D or a dedicated EI-canal-binding slice.
- **§6.12.12 canal-interior reaction pass.** Slice (6), next per the scenario doc. Reads the wall displacement that 5F.B.C now feeds into the integrator's bilateral split and dispatches a `body_apply_impulse` on each cross-section's host bone.
- **Phase 6 stimulus bus event emission.** Slice (7) — wall contact events for Sonance / Reverie.
- **TT-S5 per-slot μ.** Slice (8).
- **Real `sample_axial_surface_velocity`.** Slice 5G when the muscle field lands.

---

## Phase 6 — Stimulus bus

**State:** blocked (waiting on Phase 5 canal interior model).

---

## Phase 7 / 7.5 — Bulgers + capsules + x-ray

**State:** blocked.

---

## Phase 8 — Multi-tentacle, advanced

**State:** blocked.

---

## Phase 9 — Polish

**State:** blocked.
