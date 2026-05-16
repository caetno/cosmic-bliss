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
