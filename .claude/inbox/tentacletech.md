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

