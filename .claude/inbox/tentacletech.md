<!--
Inbox for the TentacleTech supervisor.

Append-only during a session. Cleared by `/inbox` after read.
Each entry: `### YYYY-MM-DD HH:MM <from-extension>` then a short body.

Use for nudges and FYIs that don't warrant an update doc:
  - "Renamed X, your callers may need a sweep"
  - "Phase Y just landed, public surface unchanged"
  - "Question: how does Z behave when W?"

For design-level changes to TentacleTech's public surface, ask the
caller to drop a `docs/Cosmic_Bliss_Update_*.md` instead.
-->

### 2026-05-15 body_field

B3 (`receive_external_impulse` + collision-layer partition) is in flight in
a worktree, landing today. Surfacing the API shape now so B5 scoping can
proceed in parallel against a stable contract; mismatches will be flagged
in PHASE_LOG when B3 lands.

**API shape (locks at B3 land):**

```
# game/addons/body_field/runtime/body_field.gd
@export var skeleton: Skeleton3D
func receive_external_impulse(world_point: Vector3, impulse: Vector3, ps: PhysicsDirectBodyState3D) -> void
func set_bone_body_rids(rids: Array[RID]) -> void         # populated by Marionette at hero-init
func get_face_region_id(face_idx: int) -> int             # 0 = no tag → TT uses defaults
func get_region_material(region_id: int) -> Dictionary    # {} = no per-region override
```

**Collision-layer constants (final names + bits):**

```
# game/addons/body_field/runtime/collision_layers.gd
class_name BodyFieldLayers
const LAYER_BODY_PROXY           = 1 << 4   # bit 5
const LAYER_BODY_CAPSULES_DETAIL = 1 << 5   # bit 6
const LAYER_BODY_CAPSULES_FULL   = 1 << 6   # bit 7
```

B3 verified clean against `project.godot` (no `physics_layer_*/name`
claims) + Marionette/TT collision_layer writes. TT's current default
`environment_collision_layer_mask=0xFFFFFFFF` covers them — B5 narrows.

This const file is the one cross-extension `preload(...)` allowed (D2:
shared layer constants are public-contract layer, not internal headers).
B5 may `preload("res://addons/body_field/runtime/collision_layers.gd")`.

**Body identification at probe time** — replaces the per-particle region
dispatch from 05-13. On a probe hit:

```
var owner_meta = body.get_meta(&"body_field_owner", null)
if owner_meta != null and owner_meta is WeakRef:
    var bf = owner_meta.get_ref()
    if bf != null:
        bf.receive_external_impulse(c.contact_point, impulse, ps)
        return
# fallthrough: direct apply, as today
ps.body_apply_impulse(c.hit_rid[k], impulse, offset)
```

`body_field_owner` is set on the proxy `AnimatableBody3D` at hero-load.
Empty meta → capsule path, identical to today.

**4S.3 surface tags** — proxy exposes per-face tags through
`get_face_region_id` / `get_region_material`. `face_idx` is an
**outer-face index** (0..n_outer_faces-1), keyed in the same order
`flesh_data.outer_faces` enumerates them. B4 (Blender authoring chain)
must emit `tet_face_region_id` in that same order.

Region material packing locked at B3 land:
```
region_material_table : PackedFloat32Array of length 3 * n_regions
                        flat [μ_0, comp_0, stiff_0, μ_1, comp_1, stiff_1, …]
region_id == 0          reserved for "no tag → defaults"
```
B5 reads via `get_region_material(region_id)` returning
`{"friction": float, "compliance": float, "contact_stiffness": float}`.

Until B4 lands, the data is empty and TT composes against tentacle
defaults — no behavior change. Plug into TT's existing 4S.3 composition
path; no new TT-side composition logic.

**Hard-optional invariant**: hero without a `BodyField` node →
`LAYER_BODY_PROXY` empty + capsule layer set switched to `_FULL` → TT's
probe hits the same capsules as the pre-body_field baseline. The
kasumi-without-body_field smoke test (05-14 §5) is the gate. B5 must not
introduce a code path that errors when `body_field_owner` meta is absent.

**v1 fidelity reductions to be aware of** (B3 PHASE_LOG):
1. Reciprocal impulse uses bone-local offset = `Vector3.ZERO` (linear
   only, no torque from off-center hits). v1.5 may extend the setter to
   take per-bone origins alongside the RIDs.
2. Nearest-vert lookup for impulse routing is rest-pose, not live
   skinned position. Linear scan, no GPU readback. v1.5 can refine.

No coordination needed before B5 starts. Scope the B5 fork against this
shape; B3 PR lands today.

### 2026-05-17 body_field

**§10.4-bf — `SurfaceOrificeRimAttachment.bake()` is concrete.** The
body_field side of the orifice-rim authoring migration from
`Marionette_plan.md` §17 (rim row) is shipped. TT-side consumption is
unblocked — replaces the pre-§17 "anchor bones in Blender + skin
weights painted in Blender + the rebind trick" path.

**Authoring contract (locked):**

```
# game/addons/body_field/resources/surface_orifice_rim_attachment.gd
class_name SurfaceOrificeRimAttachment extends SurfaceAttachment

@export var rim_particle_positions: PackedVector3Array    # rest positions, body-mesh local
@export var falloff_radius_m: float = 0.02                # tight; rim is thin
@export var falloff_curve: FalloffCurve = SMOOTHSTEP      # LINEAR | SMOOTHSTEP | GAUSSIAN
@export var weight_mode: WeightMode = REPLACE             # set in _init; rim REPLACEs LBS

# After field.bake_all_attachments() runs:
@export var baked_per_particle_weights: PackedFloat32Array    # length n_verts * n_particles_baked, row-major
@export var n_particles_baked: int                            # for stale-check / consumption indexing
@export var baked_weights: PackedFloat32Array                 # length n_verts; per-vertex mask (saturating peak influence)
```

**Bake recipe** (one geodesic solve per rim particle, then per-vertex normalize):
1. For each rim particle `p`, find its nearest welded vertex; run `field.diffuse_geodesic([seed_p])` → per-vertex geodesic distance.
2. Per-vertex per-particle raw weight = `falloff_curve(clamp(d / falloff_radius_m, 0, 1))`.
3. Per-vertex normalize across particles so `Σ_p w[v,p] = 1` when at least one particle reaches the vertex; zero otherwise.
4. Per-vertex mask = saturating peak raw influence — gives consumers a smooth `[0, 1]` "rim influence" scalar for blending REPLACE-mode rim verts with LBS-mode body verts at the boundary.

**TT-side consumption pattern (your slice — TT §10.4):**

Per substep, for every `SurfaceOrificeRimAttachment` in the hero's
`BodyField.attachments`:

```
const n_p = att.n_particles_baked
if n_p != rim.particles.size():
    push_warning("rim particle count changed since bake — re-bake needed")
    continue   # or fall back to the rebind-trick path

for each rim vertex v with att.baked_weights[v] > threshold:
    var pos = Vector3.ZERO
    for p in n_p:
        pos += att.baked_per_particle_weights[v * n_p + p] * rim.particles[p].world_pos
    # REPLACE mode: pos is the rim vertex's NEW world position (overrides skeleton-LBS).
```

Vertices outside the rim mask (`baked_weights[v] == 0`) keep their
skeleton-LBS position. The boundary band (`0 < baked_weights[v] < 1`)
can be lerped between LBS and rim-driven for a smooth seam if you
want; the mask itself is the lerp parameter.

**Hard-optional invariant**: hero without `BodyField` or without
`SurfaceOrificeRimAttachment` in `attachments` keeps the rebind-trick
path bit-for-bit unchanged. The new path activates per-attachment, not
globally — different orifices can mix old/new during migration.

**Authoring helper (your call)**: TT-side editor tool would snapshot
the rim PBD particles' rest positions into the resource's
`rim_particle_positions` field. Without it, the user authors positions
by hand. v1: ship without the helper; users author positions
themselves or scripted snapshot. v1.5: add the editor button.

**Bake cost note**: one geodesic solve per rim particle. For ~16
particles per orifice and ~5k body verts, each solve is one Cholesky
back-sub (~25M ops). Total bake-time cost: trivial. Re-bake only
needed when rim topology changes (particle count or rest positions),
not per-frame.

**Test results (body_field side)**: ring of 8 particles on a unit
sphere (radius 0.4 m, smoothstep falloff). 290 welded verts, 72 (~25%)
inside rim mask; sums normalize to 1.0 in-mask, 0.0 out-of-mask; each
particle's nearest vertex has mask ≥ 0.5; antipode is masked out
cleanly. See `tests/run_tests.gd::test_surface_orifice_rim_attachment_ring`.

**Apply pass on TT_Architecture.md §10.4** likely needed when your
consumption lands — flag the rebind-trick path as the no-body_field
fallback and document the new path as the body_field-present path.
That's an architecture-doc edit you can either bundle with your
slice or surface as an apply-pass.

