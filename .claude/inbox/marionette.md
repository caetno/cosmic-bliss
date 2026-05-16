<!--
Inbox for the Marionette supervisor.

Append-only during a session. Cleared by `/inbox` after read.
Each entry: `### YYYY-MM-DD HH:MM <from-extension>` then a short body.

Use for nudges and FYIs that don't warrant an update doc.
For design-level changes to Marionette's public surface, ask the
caller to drop a `docs/Cosmic_Bliss_Update_*.md` instead.
-->

### 2026-05-14 07:54 top-level
Cross-extension audit on 2026-05-14 surfaced 6 SHARP + 8 LATENT + 1 tension on Marionette plus four apply-pass items (05-14 §7.4–§7.7 in `Marionette_plan.md` §15/§16/§17/§18). Full inventory + recommended priorities in `docs/Cosmic_Bliss_Update_2026-05-14-02_cross_extension_audit_findings.md` (PR #10); P0 items are the `body_rhythm_phase` integrator-owner decision + publish (Mar-I14) and the four doc apply-pass edits.

### 2026-05-14 09:30 top-level
Named the next cross-extension testable scenario: *ragdoll with muscle tension that tries to hold a pose while constrained and being penetrated* (kasumi, three tension settings). Full readiness verdict + Marionette slice list in `docs/Cosmic_Bliss_Update_2026-05-14-03_ragdoll_under_tension_scenario.md` §3. Slice order (Marionette-side, in priority): (1) **Mar-I6 snapshot fix** at `marionette_bone.cpp:246` — gates everything else because it biases the high-tension regime that headlines the scenario; (2) **Mar-I5 snapshot fix** at `jiggle_bone.gd:66,71` (in-scope because kasumi has jiggle bones); (3) **`body_rhythm_phase` publisher** (Mar-I14, ride along — P0 anyway); (4) **apply-pass §7.4–§7.7** (one bundled doc PR); (5) **P10.2 `PinAnchor` minimum slice** — hard pin only, no IK soup; (6) **P10.7 `body_strain` publisher minimum slice** — stub scalar per region, see 05-14-03 §3 for the contract. Full P10 composer (Mar-I8/I9, P10.6 pump) and Phase 11 (`apply_hit`, `GrabTarget`) are out of scope here — Reverie-era work. Project CLAUDE.md "Never" bullet on snapshot discipline tightened in this PR; the bug fixes (1) and (2) close out the cross-cutting §4.1 code violations.

### 2026-05-15 body_field

B3 lands `BodyField::receive_external_impulse(world_point, impulse, ps)`
today. To route the impulse to bones, body_field needs each bone's
Jolt body RID. Marionette owns `PhysicalBoneSimulator3D` + per-bone
`PhysicalBone3D` nodes — wiring is a Marionette-side hero-init concern.

**Wiring contract** — at hero-init, after `Skeleton3D` +
`PhysicalBoneSimulator3D` are ready and bone bodies exist:

```
if hero.has_node("BodyField"):
    var bf = hero.get_node("BodyField")
    var bone_rids: Array[RID] = []
    bone_rids.resize(skeleton.get_bone_count())
    for bi in skeleton.get_bone_count():
        var pb = physical_bone_simulator.get_simulation_bone(bi)   # or whatever Marionette's accessor is
        bone_rids[bi] = pb.get_rid() if pb != null else RID()
    bf.set_bone_body_rids(bone_rids)
```

Setter signature locks at `Array[RID]` (RIDs cannot be reconstructed
from int64 ids in GDScript, so `PackedInt64Array` doesn't work).

Array indexing MUST match `Skeleton3D.get_bone_count()` indexing —
body_field's `tet_skin_indices` is keyed off the same. Invalid `RID()`
slots = "no Jolt body for this bone" → routing for that bone is a
silent no-op.

**Not urgent.** Empty / all-invalid RID table → silent no-op, equals
the pre-§3.2 baseline. B5 (TT side) can land without this; the B6
kasumi-with-body_field acceptance scenario will need it.

**v1 fidelity simplification**: body_field calls
`body_apply_impulse(rid, impulse, Vector3.ZERO)` — bone-local offset is
zero (linear only, no torque from off-center hits). If Marionette wants
to refine to a torque-producing variant in v1.5, extend the setter to
also pass `Array[Transform3D]` of bone origins so body_field can compute
the world-point-minus-bone-origin offset. Surface back if you want that
in v1; not blocking B5.

**Hard-optional invariant**: the `if hero.has_node("BodyField"):` guard
is the entire compliance — body_field absent → Marionette does nothing,
which is bit-for-bit equivalent to the pre-body_field baseline.

If the `PhysicalBoneSimulator3D` accessor for "give me the per-bone
PhysicalBone3D" looks different from `get_simulation_bone(bi)` above,
adjust and surface back.

### 2026-05-16 body_field

**§17.5 — `SurfaceJiggleAttachment` is consumable.** `bake()` is now
concrete; the resource produces per-vertex weights from a seed position
+ falloff radius via the §17.2 heat-method geodesic distance. This
unblocks the Marionette §15 amendment from `Marionette_plan.md` §15
(2026-05-07-02) — the migration from Blender skeleton jiggle bones to
Godot-side surface attachments.

**Authoring contract (locked):**

```
# game/addons/body_field/resources/surface_jiggle_attachment.gd
class_name SurfaceJiggleAttachment extends SurfaceAttachment

@export var seed_position: Vector3            # body-mesh local space
@export var host_bone: StringName             # inherited from base
@export var falloff_radius_m: float = 0.10    # geodesic, in metres
@export var falloff_curve: FalloffCurve = SMOOTHSTEP    # LINEAR | SMOOTHSTEP | GAUSSIAN
@export var weight_mode: WeightMode = ADDITIVE    # inherited; ADDITIVE for jiggle

# After field.bake_all_attachments() runs:
@export var baked_weights: PackedFloat32Array    # length = field.n_verts
```

User authors a `SurfaceJiggleAttachment` resource, adds it to a
`BodySurfaceField.attachments` slot, hits the `trigger_bake` inspector
toggle (or runs the baker EditorScript). Per-vertex weight is shaped by
a smoothstep (default) curve over normalized geodesic distance from the
seed — peak 1.0 at seed, zero past `falloff_radius_m`.

**Marionette-side consumption pattern (what §15-amendment needs to build):**

1. **One translation-only SPD particle per `SurfaceJiggleAttachment`.**
   Same translation-only SPD physics as the existing kasumi breast
   jiggle (per `feedback_marionette_jiggle_state` memory + §15 spec).
   No new physics, just relocated anchor.
2. **Particle anchored to `host_bone`'s pose.** Each substep, the
   particle's rest position = `skeleton.global_transform * skeleton.get_bone_global_pose(host_bone_idx) * attachment.seed_position_local`. (Or equivalent — Marionette already does this for the existing breast jiggle.)
3. **Per-vertex render-mesh additive offset.** At render-update time,
   for each vertex `i`: `vertex_offset[i] += baked_weights[i] * (particle_world_pos - particle_rest_pos)`. The render-mesh additive-offset path already exists for §15 jiggle (the path Marionette §15 amendment marks as STAYS LIVE as the no-body_field fallback).
4. **Discovery: walk `BodySurfaceField.attachments`.** When body_field
   is present and contains `SurfaceJiggleAttachment` resources, those
   become the canonical jiggle source. The Blender-skeleton jiggle
   path stays live for body_field-absent heroes (hard-optional
   invariant).

**Hard-optional preserved:** body_field-absent heroes use the existing
Blender-bone jiggle path bit-for-bit. body_field-present heroes with no
`SurfaceJiggleAttachment` resources also fall back to the Blender path
(empty `attachments` list — no per-vertex offset). Only when BOTH a
`BodyField` node AND `SurfaceJiggleAttachment` resources exist does the
new path activate. Marionette §15 amendment 2026-05-07-02 documents
this layering.

**Numerics:** the geodesic falloff is exact to ~1.5% on a coarse
130-vert sphere (§17.2 test). On kasumi's body mesh the error will be
similar or better — well within visible-quality threshold for jiggle.

**Migration (not blocking your work, but the value lands at kasumi-scene migration time):**

- Kasumi breast jiggle: replace skeleton-side bones with two
  `SurfaceJiggleAttachment` resources (L + R), seed positions read off
  the body mesh, host bone = `Chest` (or whichever bone Marionette §15
  uses today). The §15 acceptance test ("slap and detach, ≥ 0.6 s
  wobble") should pass identically because the physics is unchanged —
  only the weight derivation moves from Blender-paint to surface-field-
  bake.
- Glute jiggle: previously impossible because kasumi has no glute bones
  in Blender. Add two `SurfaceJiggleAttachment` resources, host bone =
  `Hips`, seed positions on the glutes.
- Belly jiggle: same pattern, host bone = `Spine`, one attachment.

Kasumi-scene migration requires editing the kasumi hero scene + Marionette
consumption code, both of which are Marionette's territory (body_field
ships only the bake math + resource definition). Body_field doesn't open
that slice; surfaces it as ready.

