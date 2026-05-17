# body_field — phase log

Per-slice changelog. Durable rules live in `CLAUDE.md`; transient state and
decisions land here. Most recent slice at the bottom.

---

### B3 — Collision-layer registration + receive_external_impulse + surface-tag accessors

**Shipped files (new):**
- `extensions/body_field/gdscript/runtime/collision_layers.gd` — `BodyFieldLayers` constants module.
- `extensions/body_field/PHASE_LOG.md` — this file.

**Shipped files (modified):**
- `extensions/body_field/gdscript/runtime/flesh_data.gd` — outer-face extraction (`_extract_outer_faces`, `outer_faces`, `n_outer_faces`); optional v3-trailer slots `tet_face_region_id` + `region_material_table` (declared, not yet emitted by the v3 reader — B4 work).
- `extensions/body_field/gdscript/runtime/body_field.gd` — `_init_tet_proxy_body`, `_update_tet_proxy_shape_cpu`, `_pack_outer_faces_from_tet_pos`, `receive_external_impulse`, `set_bone_body_rids`, `_apply_impulse_to_bone` Callable hook, `get_face_region_id`, `get_region_material`. AnimatableBody3D + ConcavePolygonShape3D added as child on `_ready()` when both flesh_data and skeleton are present and `n_outer_faces > 0`. Pre-allocated `_proxy_faces_packed` / `_tet_pos_cpu` / `_bone_skin_xform`; no per-frame allocation.
- `extensions/body_field/tests/run_tests.gd` — 5 new tests: `test_outer_face_extraction`, `test_collision_layer_registration`, `test_receive_external_impulse_split`, `test_receive_external_impulse_empty_table_noop`, `test_surface_tag_defaults`.

**Decisions:**

1. **Layer bits 5 / 6 / 7 (1<<4, 1<<5, 1<<6)**. Verified clean at land time: no `physics_layer_*/name` entries in `game/project.godot`; no extension code writes those literal `collision_layer` values. Marionette `ragdoll_tuner.gd:213` uses `collision_layer = 1` (layer 1, unrelated). TentacleTech's default `environment_collision_layer_mask = 0xFFFFFFFF` covers our layers — B5 narrows it to `PROXY | DETAIL | FULL | WORLD`.

2. **CPU-side LBS for shape update, not GPU readback**. `dispatch_once()` runs the GPU kinematic-targets pass AND a parallel CPU bone-LBS pass to refresh `_tet_pos_cpu`. The shape is rebuilt (via `ConcavePolygonShape3D.set_faces`) each tick from `_proxy_faces_packed`. Rationale: on the global RD, `buffer_get_data` either returns stale data or forces a wait that costs more than the CPU pass it would replace. Nv is bounded ~10⁴ in v1; CPU pass measured cheap. v1.5 may revisit once the GPU pipeline has more consumers per substep that justify the readback. Both paths use the same skinning matrix construction (`sw * posed[b] * rest_inv[b]`), so any drift surfaces as a same-tick test fail, not a real-time bug.

3. **`receive_external_impulse` v1 simplifications** (call out so v1.5 knows what to refine):
   - **Nearest-vert lookup against rest-pose positions, not live skinned positions.** Linear scan O(Nv) — Nv bounded ~10⁴ in v1. Live-position lookup costs either a GPU readback or live CPU mirroring; rest-pose error is bounded by the bone-LBS displacement which is small near each bone's neighborhood (the typical contact case). Refinement path: v1.5 can use `_tet_pos_cpu` (already maintained) directly.
   - **Bone-local offset = `Vector3.ZERO`** instead of `world_point - bone_world_origin`. Drops torque contribution from off-center hits — purely linear impulse routing. Refinement: v1.5 wires bone origins (Marionette already exposes them via `PhysicalBoneSimulator3D`).
   - **Weight threshold `> 1e-4`** matches the typical normalize-after-quantize floor on FBX/Blender skin weights; below that the bone's contribution is below sensor noise.

4. **`region_material_table` packing schema (frozen at B3)**:
   ```
   region_material_table : PackedFloat32Array, length = 3 * n_regions
   indexed [region_id*3 + 0 = μ, +1 = compliance, +2 = contact_stiffness]
   tet_face_region_id    : PackedInt32Array, length = n_outer_faces
   region_id = 0 reserved for "no tag → default material" (returns {} from get_region_material)
   ```
   B4 authoring chain MUST write this layout when it lands; B5 TT-side composition MUST consume via `get_face_region_id` + `get_region_material`. v1 .bin reader does NOT yet write these fields (B4 work) — accessors return defaults until then.

5. **Outer-face orientation**: face normal points away from the opposing fourth tet vertex (`dot(cross(b-a, c-a), d-a) ≤ 0` after orientation). On the boundary of a convex region this matches "outward from the volume." Hashtable keyed by sorted-int-triple via `"%d_%d_%d"` String key (cheap for Nt up to ~10⁵; revisit if Nt growth demands int64 packing).

6. **Hard-optional preserved**: `_init_tet_proxy_body` early-returns when `flesh_data == null` or `n_outer_faces == 0`. No empty AnimatableBody3D pollutes the scene. `receive_external_impulse` is a silent no-op when `flesh_data == null`, `_bone_body_rids.is_empty()`, or all RIDs are invalid. `get_face_region_id` / `get_region_material` return 0 / `{}` when the optional v3 trailer is absent.

**Coordination follow-ups (recipients briefed via inbox):**
- **Marionette**: wire `set_bone_body_rids(Array[RID])` at hero-init by walking `PhysicalBoneSimulator3D`'s children and reading each `PhysicalBone3D.get_rid()` keyed by `bone_index`. Slots for bones without a PhysicalBone3D stay `RID()`. Also: switch `BoneCollisionProfile.active_layer_set` to `DETAIL` (hands/feet) when `BodyField` node present, `FULL` otherwise.
- **TentacleTech B5**: per-particle probe issues one `intersect_shape` call against `LAYER_BODY_PROXY | LAYER_BODY_CAPSULES_DETAIL | LAYER_BODY_CAPSULES_FULL | LAYER_WORLD`. On hit, check `body.has_meta(&"body_field_owner")`; if true, the reciprocal `body_apply_impulse` becomes `bf.receive_external_impulse(contact_world_point, impulse, ps)`. The proxy body's `collision_mask = 0` — TT probes hit us, we never probe.

**Build / test status:**
- `./tools/build.sh body_field` succeeds; `game/addons/body_field/runtime/collision_layers.gd` deployed.
- Test runner: `godot --headless --quit-after 15 --script extensions/body_field/tests/run_tests.gd` — could not execute in sandbox; supervisor reviews + runs.
- Static review: all GDScript exports type-clean (Array[RID], PackedVector3Array preallocation, etc.); no per-frame allocation in the `dispatch_once → _update_tet_proxy_shape_cpu` path beyond the unavoidable `set_faces` internal copy.

**Open questions / handoffs:**
- Marionette must set `_bone_body_rids` before TT first hits the proxy — i.e. before the first physics tick that includes a particle near the body. Hero-init is the canonical point. The all-empty-RIDs early-out in `receive_external_impulse` means a missed wire-up degrades gracefully (no impulse, no crash); B6 acceptance test catches the regression.
- The `tet_face_region_id` length convention: 1 entry per outer face, NOT per tet face. B4 authoring chain must emit in the same order as `_extract_outer_faces` produces. If ordering can't be guaranteed, B4 should sort both sides by sorted-vert-triple key — leave as a B4 decision.

**Next slices:**
- B4 — Blender authoring chain (vendored under `tools/blender/body_field/`). Writes v3 .bin including the optional region material trailer per the schema frozen here.
- TT B5 — type-1 fork against partitioned bodies. Reads `body_field_owner` meta; routes reciprocal via `receive_external_impulse`; consumes surface tags via `get_face_region_id` / `get_region_material`.

---

### §17.1 — BodySurfaceField core (cotan-Laplacian + Cholesky + sphere radial-falloff test)

Sibling slice family inside body_field per `docs/marionette/Marionette_plan.md` §17 (the B-series slices target §18 volumetric tets; §17 is the surface field). §17.1 ships infrastructure only — the three concrete attachment subclasses are stubs whose `bake()` lands at consumer migration time (§17.5 Marionette jiggle, TT §10.4 rim authoring, Marionette §16 soft regions).

**Shipped files (new):**
- `extensions/body_field/gdscript/runtime/cotan_laplacian.gd` — Crane-style cotan-Laplacian builder + lumped Voronoi mass + vertex weld helper + topology fingerprint.
- `extensions/body_field/gdscript/runtime/cholesky_solver.gd` — dense LLᵀ Cholesky factorization, forward/back-sub solve, and heat-method `(M + t·L) x = M·u0` diffuse step.
- `extensions/body_field/gdscript/runtime/body_surface_field.gd` — `BodySurfaceField` Node3D with lazy factor build, `bake_all_attachments` via inspector `trigger_bake` toggle, `diffuse`, and a `diffuse_geodesic` v1 placeholder.
- `extensions/body_field/gdscript/resources/body_surface_field_factor.gd` — cached factor resource (mass, heat_t, dense lower-triangular factor, fingerprint).
- `extensions/body_field/gdscript/resources/surface_attachment.gd` — base resource with `attachment_name`, `host_bone`, `weight_mode`, abstract `bake(field)`.
- `extensions/body_field/gdscript/resources/surface_jiggle_attachment.gd` — stub for §17.5.
- `extensions/body_field/gdscript/resources/surface_orifice_rim_attachment.gd` — stub for TT §10.4.
- `extensions/body_field/gdscript/resources/surface_soft_region_attachment.gd` — stub for Marionette §16.
- `extensions/body_field/gdscript/debug/body_surface_field_gizmo.gd` — pre-allocated `ImmediateMesh` heat-map of one attachment's baked weights. Cool→hot color ramp (dark blue → cyan → green → magenta) avoiding orange-yellow per project gizmo-color rule.

**Shipped files (modified):**
- `extensions/body_field/tests/run_tests.gd` — `test_surface_field_sphere_radial` (icosphere via `SphereMesh`; delta at vertex 0 diffused; asserts peak at seed, antipode < 10% of peak, all finite, sum > 0).

**Decisions:**

1. **Dense storage + dense LLᵀ Cholesky.** Sparse Cholesky in pure GDScript is significantly more code; for v1 consumers (test sphere n≈80, kasumi body mesh n≈5k) dense is acceptable. Memory: ~n² floats. The test sphere measures w[0]=0.286, w[antipode]=0.0005 (ratio 0.002) — clean radial falloff. v1.5+ may swap to sparse if a larger consumer mesh forces it; the `BodySurfaceFieldFactor` resource is the natural seam.

2. **Heat-method semantics: `(M + t·L) u = M·u0`.** Crane et al. §3.2's backward-Euler step. `L` stored as positive-semi-definite (`L[i,j] = -0.5·(cot α + cot β)` off-diagonal, row-sum positive). `M + t·L` is SPD on a well-formed mesh; Cholesky succeeds. Auto `t ≈ mean_edge_length²` when `heat_t` is unset.

3. **Defensive vertex weld in `_ensure_factor()`.** Godot's `SphereMesh` ships UV-seam + pole duplicates (104 raw verts → 74 unique on a 12×6 sphere). Without welding, duplicate verts have zero adjacency in the cotan-Laplacian, leading to zero mass, zero diagonal in `M + t·L`, and a non-SPD Cholesky failure. The weld pass (`CotanLaplacian.weld_coincident_vertices`, tol=1e-5) is idempotent on already-welded inputs and protects v1.5+ hero meshes from glTF importers that split verts on UV seams. Surfaced via `get_source_vertices()` / `get_source_indices()` so consumers (gizmo, tests) operate in the welded vertex space.

4. **`diffuse_geodesic` is a placeholder.** v1 returns 3D Euclidean distance from the nearest seed (chord length on a sphere, not great-circle distance, but monotonic in it). The concrete heat-method geodesic-distance pipeline (Crane et al. §3.3 — solve the heat equation, normalize the gradient, solve the Poisson equation) lands at §17.2+ when the first consumer (TT §10.4 rim authoring) needs precise geodesic falloff. v1 placeholder pushes a warning so consumers don't rely on it silently.

5. **Baker mechanism: `trigger_bake` toggle on the node.** Option A from the slice prompt (vs Option B's standalone EditorScript). Setting `trigger_bake = true` in the inspector runs `bake_all_attachments()` and resets the toggle. Simple, in-line, no extra EditorScript path. EditorScript can be added later if consumers want a FileSystem-context-menu entry.

6. **Three attachment subclasses ship as stubs.** Each subclass's `bake()` returns empty `PackedFloat32Array()` with a clear `push_warning` identifying the consumer-side slice that owns the concrete impl. The TYPES exist and are loadable — that's what §17.1 ships. §17.5 fills `SurfaceJiggleAttachment.bake()`; TT-side §10.4 fills `SurfaceOrificeRimAttachment.bake()`; Marionette §16 fills `SurfaceSoftRegionAttachment.bake()`.

7. **Sanity gizmo color ramp.** Cool→hot (dark blue → cyan → green → magenta), explicitly avoiding the orange-yellow band per the project gizmo-color rule (Godot's default Skeleton3D gizmo eats warm hues).

**Test results:**
- `test_surface_field_sphere_radial` PASSES: peak at seed, antipode ratio 0.002 (« 0.1 threshold), all finite, sum > 0.
- All 11 pre-existing tests still pass. `./tools/test_body_field.sh --refresh` is the canonical invocation (the `--editor --quit` refresh is mandatory after a new `class_name` lands — six new class names in this slice).

**Hard-optional preserved:**
- §17.1 lives inside body_field. No consumer migration is performed in this slice — every consumer (§17.5 jiggle, TT §10.4 rim, Marionette §16 soft regions) keeps its pre-§17 manual-authoring path live. The fallback path is the LACK of `SurfaceJiggleAttachment` / `SurfaceOrificeRimAttachment` / `SurfaceSoftRegionAttachment` in the hero scene — consumers test for their presence, not for `BodySurfaceField`'s presence directly.
- `BodySurfaceField` may exist on a hero without any attachments — `bake_all_attachments()` then iterates an empty list (no-op). And vice versa: attachments can sit unbaked (no-op) until their consumer's migration slice opens.

**Next slices (consumer-side, not body_field's responsibility):**
- §17.5 — Marionette jiggle attachment migration: fill `SurfaceJiggleAttachment.bake()`, migrate kasumi breast jiggle, add glute attachment (previously impossible without a Blender bone).
- TT §10.4 — orifice rim authoring migration: fill `SurfaceOrificeRimAttachment.bake()`, retire the "anchor bone in Blender" gotcha for new orifices.
- Marionette §16 — soft-region cluster geodesic blend: fill `SurfaceSoftRegionAttachment.bake()`, swap Euclidean SDF for geodesic-on-mesh derivation.
- §17.2 — concrete heat-method geodesic-distance pipeline (replacing the v1 Euclidean placeholder in `diffuse_geodesic`).
- Sparse Cholesky port if kasumi body mesh size pushes the dense factor's ~100 MB up to ~hundreds of MB.

---

### §17.2 — Heat-method geodesic distance (Crane et al. 2013 §3)

Replaces the §17.1 Euclidean placeholder in `BodySurfaceField.diffuse_geodesic` with the real Crane heat method: heat-diffuse a delta at the seed, take the unit gradient of the result (pointing away from the seed), solve a Poisson equation against its divergence, shift so the seed sits at distance 0. The result is per-vertex geodesic distance on the surface — what TT §10.4 and Marionette §16 actually need for falloff authoring.

**Shipped files (modified):**
- `extensions/body_field/gdscript/runtime/cotan_laplacian.gd` — `compute_face_gradients` (Crane §3 eq 5: piecewise-linear gradient `∇u|_T = Σ u_v · (N × edge_opposite_v) / 2A`) and `compute_vertex_divergence` (Crane §3 eq 4: cotan-weighted edge-vs-X dots summed over incident triangles).
- `extensions/body_field/gdscript/runtime/cholesky_solver.gd` — refactored into `factorize_spd(A, n)` (low-level in-place LL^T) + `factorize_heat(L, mass, t)` (`A = M + t·L`) + `factorize_poisson(L, mass, ε)` (`A = L + ε·M`). `factorize(...)` kept as a backwards-compat alias for §17.1 callers.
- `extensions/body_field/gdscript/resources/body_surface_field_factor.gd` — added `chol_poisson_kind`, `l_chol_poisson`, `poisson_epsilon`, plus `to_poisson_solver_dict` / `from_poisson_solver_dict` helpers. §17.1's `chol_kind`/`l_chol`/`heat_t` semantics unchanged.
- `extensions/body_field/gdscript/runtime/body_surface_field.gd` — `_ensure_factor` now builds BOTH factors (heat + Poisson) from the same cotan-Laplacian; new `poisson_epsilon` export (default 1e-4); `diffuse_geodesic` replaced with the heat-method recipe; cache-hit check now requires both factor kinds present.
- `extensions/body_field/tests/run_tests.gd` — new `test_surface_field_sphere_geodesic` (16×8 sphere; antipode geodesic distance must be in `[2.5, 4.0]` against the true value `π·radius = π·1 ≈ 3.14`).
- `tools/test_body_field.sh` — **removed**, folded into the unified `tools/test.sh body_field` runner that landed in `b52c533` (top-level commit).

**Decisions:**

1. **Heat-method timestep `t` and Poisson regulariser `ε`.** Inherited from §17.1's `heat_t = mean_edge_length²` (Crane §3.2 rule-of-thumb). New `poisson_epsilon = 1e-4` default — small enough that the post-solve shift (`φ -= min φ`) keeps within `O(ε)` of the true Poisson solution; large enough to dominate the cotan-Laplacian's constant-function null space numerically. Both are exposed as `@export` on `BodySurfaceField` for hero-specific overrides if needed.

2. **Sign convention.** Our `L` is positive-semi-definite (cotan-Laplacian stored as `L = D - W`, opposite of Crane's `L_C = W - D`). Crane writes the Poisson equation as `L_C φ = ∇·X` with his negative-semi-def `L_C`; in our convention this becomes `L φ = -∇·X`. The Poisson solve passes `-div(X)` as the RHS — load-bearing sign flip, called out in the `diffuse_geodesic` body comments to save the next maintainer the same derivation.

3. **Why dense Cholesky for the Poisson factor too.** Same n²-memory tradeoff as §17.1's heat factor. Building both factors in one `_ensure_factor` call costs a second `factorize_spd` pass on n*n floats — measured cheap for the test sphere (n≈100) and acceptable for kasumi-class meshes (n≈5k). Sparse is the v1.5+ refinement when a consumer's mesh size forces it.

4. **`diffuse_geodesic` is the consumer-facing API; the heat-method machinery is hidden.** Consumers (TT §10.4, Marionette §16) call `field.diffuse_geodesic([seed_idx])` and get back a per-vertex distance array. The choice of heat-method-vs-other-geodesic-algorithm is `BodySurfaceField`'s concern — consumers don't see it. Lets v1.5+ swap to a fast-marching method or exact polyhedral geodesics without a consumer API change.

5. **`diffuse_geodesic` cache-hit semantics tightened.** §17.1's cache check was `chol_kind != "none"`; §17.2 promotes it to `chol_kind != "none" AND chol_poisson_kind != "none"`. Old §17.1-built saved factors (if any) will refactor on first `_ensure_factor` call — Poisson factor wasn't there to load.

**Test results:**
- `test_surface_field_sphere_geodesic` PASSES: n=130 verts (16×8 sphere mesh), `phi[antipode] = 3.0956` against true value `π = 3.1416` — **1.5% error** on this coarse mesh. Antipode is the global max (monotonic structure preserved). Seed sits at 0 after shift.
- All 12 previous tests still pass.
- `./tools/test.sh body_field` is now the canonical invocation. `tools/test_body_field.sh` removed.

**Coordination:**
- **TT §10.4 (rim authoring migration)** — unblocked. `SurfaceOrificeRimAttachment.bake()` can now use `field.diffuse_geodesic([rim_centroid_vertex])` for the rim-vs-body weight falloff. Authoring contract: TT-side concrete impl picks the seed vertex from the rim mesh's centroid projection onto the body mesh.
- **Marionette §16 (soft-region geodesic blend)** — unblocked. `SurfaceSoftRegionAttachment.bake()` can compose `diffuse_geodesic([volume_primitive_center_vertex])` with the existing volume primitive to produce the cluster_blend field.
- **§17.5 (jiggle migration)** — still uses `diffuse` (one-step heat-kernel falloff is the natural jiggle falloff), not `diffuse_geodesic`. Unchanged by §17.2.

**Next:**
- Consumer-side migration slices open per the coordination notes above.
- §17.3 if a consumer wants extra-accurate geodesic distance — currently 1.5% error on the sphere is well within the precision any falloff authoring needs.

---

### §17.5 — SurfaceJiggleAttachment.bake() (first consumer migration)

First concrete `SurfaceAttachment` subclass — fills the §17.1 stub for `SurfaceJiggleAttachment` with real bake math. This is the body_field side of the Marionette `Marionette_plan.md` §15 amendment (2026-05-07-02) that retires Blender-authored jiggle bones in favour of Godot-side attachment resources.

**Shipped files (modified):**
- `extensions/body_field/gdscript/resources/surface_jiggle_attachment.gd` — concrete `bake()`. Resource exports: `seed_position: Vector3` (body-mesh local), `falloff_radius_m: float = 0.10`, `falloff_curve: FalloffCurve` (LINEAR / SMOOTHSTEP / GAUSSIAN, default SMOOTHSTEP). Bake: find nearest welded vertex to seed_position → `field.diffuse_geodesic([seed_idx])` → per-vertex `t = clamp(d/radius, 0, 1)` → shape by falloff curve. Output peak=1.0 at seed, zero past radius.
- `extensions/body_field/tests/run_tests.gd` — `test_surface_jiggle_attachment_falloff`: unit sphere with attachment at north pole, radius 0.5; asserts peak=1.0 at seed, zero at antipode (geodesic ≈ π = 6.3× radius), all finite/non-negative, zero past radius, monotonic with geodesic distance.

**Decisions:**

1. **Geodesic falloff via `diffuse_geodesic`, not heat-kernel directly.** The §17.2 heat-method geodesic distance is the natural input — its 1.5% accuracy on a 130-vert sphere is well within visible-quality for jiggle falloff. Heat-kernel diffusion would also work (and is even cheaper — one solve instead of three), but the falloff shape is then implicit in `heat_t` which couples to the field's other consumers. Geodesic + explicit `falloff_radius_m` gives the artist a tunable they can read off the body mesh in metres.

2. **Resource holds `seed_position: Vector3`, not a child Node3D's transform.** Keeps the §17.1 base class shape (SurfaceAttachment extends Resource) intact — no need to introduce a Node3D wrapper just for transform-based authoring. Authoring ergonomics: user reads the position off the body mesh viewport (temporary marker or scripted helper) and types it into the inspector. Future §17.6 may add a Node3D-driven placement helper if the read-off-viewport step proves clunky in practice; for now the Resource-only shape is simpler.

3. **Three falloff curves shipped: LINEAR / SMOOTHSTEP / GAUSSIAN.** Default SMOOTHSTEP because C¹ at both ends gives natural-looking jiggle envelopes. GAUSSIAN with k=4 gives `w(t=1) ≈ 0.018` — effectively zero at the radius, smooth interior. LINEAR for artists who want a hard-edged falloff.

4. **No physics in this slice.** The Marionette-side SPD particle + render-mesh additive offset stays in Marionette's lap. body_field ships only the bake (per-vertex weight); consumer reads `baked_weights` at runtime.

5. **`SurfaceAttachment.weight_mode = ADDITIVE` is correct for jiggle.** Inherited default; baked weights add to the host bone's existing skin weights via Marionette's existing render-mesh additive-offset path. REPLACE mode is for rim/cluster authoring (TT §10.4, Marionette §16).

**Test results:**
- `test_surface_jiggle_attachment_falloff` PASSES: n=130 verts, w[seed]=1.0, w[antipode]=0.0, monotonic in geodesic distance, zero past radius. 14/14 tests overall.

**Coordination:**
- **Marionette §15 amendment** — fully unblocked. Inbox brief dropped: consumption pattern (one translation-only SPD particle per attachment, anchored to host_bone, render-mesh additive offset = `baked_weights × particle_displacement`); migration plan for kasumi (breast L+R + glutes L+R + belly).
- **Kasumi hero scene migration** — Marionette + scene-edit territory. body_field ships ready; Marionette opens the slice. Requires user permission per the test-scene-edit rule.
- **Hard-optional preserved**: body_field-absent heroes (or body_field-present heroes with empty `attachments`) keep the Blender-skeleton jiggle path bit-for-bit.

**Next consumer slices (other extensions, not body_field's responsibility):**
- Marionette §15 amendment runtime — consume `SurfaceJiggleAttachment.baked_weights` in the render-mesh additive-offset path.
- TT §10.4 — `SurfaceOrificeRimAttachment.bake()` (rim authoring; body_field-side concrete impl analogous to this slice).
- Marionette §16 — `SurfaceSoftRegionAttachment.bake()` (soft-region geodesic blend).

---

### §10.4-bf — SurfaceOrificeRimAttachment.bake() (second consumer migration, body_field side)

Body_field side of the orifice-rim authoring migration. Fills the §17.1 stub for `SurfaceOrificeRimAttachment` with multi-seed geodesic bake math. Unblocks TT §10.4's runtime consumption (TT supervisor's slice).

**Shipped files (modified):**
- `extensions/body_field/gdscript/resources/surface_orifice_rim_attachment.gd` — concrete `bake()`. Resource exports: `rim_particle_positions: PackedVector3Array` (rest positions, body-mesh local), `falloff_radius_m: float = 0.02` (tight; rim is thin), `falloff_curve: FalloffCurve` (LINEAR / SMOOTHSTEP / GAUSSIAN, default SMOOTHSTEP). Output: `baked_per_particle_weights: PackedFloat32Array` (length `n_verts * n_particles_baked`, row-major), `n_particles_baked: int`, and `baked_weights` (inherited) repurposed as a per-vertex "rim influence" mask scalar. Bake: per-particle geodesic solve → per-vertex per-particle raw falloff → per-vertex normalize across particles → saturating peak as mask.
- `extensions/body_field/tests/run_tests.gd` — `test_surface_orifice_rim_attachment_ring`: 8-particle ring at latitude z=0.5 on a unit sphere, radius 0.4 m. Asserts in-mask sums = 1.0, out-of-mask sums = 0.0, each particle's nearest vert has mask ≥ 0.5, antipode is masked out, coverage fraction sane (~25%).

**Decisions:**

1. **Multi-seed bake = one geodesic solve per rim particle, then per-vertex normalize across particles.** Cholesky factor is shared (built once in §17.2), so each extra particle costs one back-sub (~O(n²) flops on a dense factor). For ~16 particles per orifice on a kasumi-class body (n≈5k), bake-time cost is ~400 M ops — sub-second; hero-load only.

2. **`weight_mode = REPLACE` set in `_init()`.** The pre-§17 path used the "rebind trick" where the skinning shader fully replaced anchor-bone transforms with rim-particle positions — i.e. the rim verts were driven entirely by particles, no skeleton-LBS contribution. REPLACE preserves that semantic. (Jiggle's `weight_mode = ADDITIVE` is correct for it; both inherit from the base default of ADDITIVE, but rim overrides in `_init`.)

3. **Per-vertex normalize across particles.** Without normalization, vertices near multiple particles double-count. With normalization (Σ_p w[v,p] = 1 inside the mask), the rim skins smoothly between particles — each vertex is a barycentric blend of the nearest particles. Standard rim-skinning convention.

4. **Mask = saturating peak raw influence, NOT post-normalize sum.** Post-normalize the in-mask sum is exactly 1.0, which carries no information about the strength of the rim's influence at that vertex. The pre-normalize peak raw weight is the natural "rim influence" scalar: 1 at the particle, falls toward 0 at the radius. Consumers can use it as a lerp parameter to blend REPLACE-mode rim verts with LBS-mode body verts at the boundary seam.

5. **`baked_per_particle_weights` packed as 1D `PackedFloat32Array` row-major.** Consumers index `[v * n_particles_baked + p]`. GPU-friendly for v1.5+ TT compute-shader consumption. The `n_particles_baked` field is a load-bearing companion — consumers MUST check it matches their current rim particle count or treat the bake as stale.

6. **Authoring contract: positions as Vector3 array, not NodePath to a TT rim.** Same boundary discipline as §17.5 — body_field doesn't know about TT internals. TT supervisor can ship an editor helper that snapshots rim particle rest positions into the resource; body_field stays self-contained.

**Test results:** 15/15 tests pass. Rim test: n=290 welded verts, 72 (24.8%) inside rim mask, each particle's nearest vertex has mask ≥ 0.5, antipode masked out cleanly.

**Coordination:**
- **TT §10.4** — fully unblocked. Inbox brief dropped (`.claude/inbox/tentacletech.md`, 2026-05-17 entry): authoring contract locked, consumption pattern documented (per-substep `pos = Σ_p w[v,p] × rim.particles[p].world_pos` for masked verts), `TT_Architecture.md` §10.4 apply-pass flagged.
- **Hard-optional invariant**: hero without `BodyField` or without `SurfaceOrificeRimAttachment` in `attachments` keeps the rebind-trick path bit-for-bit. Per-attachment activation — different orifices can mix old/new during migration.

**Marionette §15-amend is PARKED** (per user direction 2026-05-17): jiggle stays bone-based (breast existing path + glutes-via-future-bone-insertion); skin-jiggle via compute shader → spatial shader is the eventual track. Body_field's §17.5 (`SurfaceJiggleAttachment.bake()`) remains shipped and tested but has no current consumer.

**Next:**
- TT §10.4 — TT-side consumption (TT supervisor's slice).
- Marionette §16 — `SurfaceSoftRegionAttachment.bake()` (third concrete bake; soft-region geodesic blend; body_field side analogous to this slice).
- Skin-jiggle compute → spatial shader (the future track for Marionette §15-amend; out of body_field scope until designs converge).
