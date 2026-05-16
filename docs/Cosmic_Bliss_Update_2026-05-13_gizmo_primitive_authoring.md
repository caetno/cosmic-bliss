# Cosmic Bliss Update — 2026-05-13 — Gizmo-driven primitive authoring (orifice rim, canal centerline, jiggle / soft region)

**Originating supervisor:** top-level
**Status:** proposed

---

## What changes

A unified Godot-side gizmo authoring system replaces three currently-separate Blender authoring steps:

1. **Orifice rim** — was Blender vertex-loop selection → `<Prefix>_RimAnchor_*` deform bones + skin weights (TT §6.1, §10.4, §10.6). Becomes a **closed-bezier "ring" gizmo** on the `Orifice` Godot node, with 4+ control points and bezier handles. N rim particles are sampled arc-length-regular along the curve.

2. **Canal centerline** — was `<Canal>_CP_*` non-deforming bones placed along the anatomical axis (TT §6.12, §10.6 step 11). Becomes an **open Catmull-Rom "tube" gizmo** on a separate `Canal` Godot node, with 4–14 control points and a per-CP `host_bone` slot. M centerline particles are sampled uniformly along the curve.

3. **Jiggle / soft region** — was a single Node3D position + isotropic scalar `falloff_radius` (Marionette §17 `SurfaceJiggleAttachment` / `SurfaceSoftRegionAttachment` per `Cosmic_Bliss_Update_2026-05-07-02_body_surface_field.md`). Becomes a **closed-bezier "outline" gizmo** that expresses anisotropic region shape on the body surface.

All three share a single editor plugin / primitive resource family in `body_field`. Per-particle rest positions sampled from the gizmo curves become **N heat sources** for the `BodySurfaceField` bake (replacing §17's single-source point bake), producing geometrically correct band-shaped or region-shaped per-vertex weight fields on the body mesh.

Two collider representations are derived from the same particle positions each tick:
- **Capsule chain** between adjacent particles → tentacle particle vs. swept capsule collision (refines TT §4.2 type-2).
- **Optional SDF** (per-particle sphere smooth-min union) → body_field tet substrate collisions, Tenticles fluid queries.

Per-ring/per-canal `@export bool sdf_collider`. Default capsules on, SDF off unless a consumer that needs SDF is on the hero.

A **`Net` primitive** (2D grid of particles on a closed region, with stretch+shear+bend constraints) is architecturally reserved for future membrane / hymen / surface-cover use cases. Not implemented in this amendment.

## Affected extensions / systems

- **TentacleTech**:
  - `Orifice` becomes a Node3D with `host_bone: NodePath`, `rim_loops: Array[RimRingPrimitive]`, `orifice_profile: OrificeProfile`. World transform is driven by `Skeleton3D.get_bone_global_pose(host_bone)` (orifice node lives under hero root, not parented under the bone).
  - New `Canal` Node3D, sibling to `Orifice` under the hero root. Carries `centerline: CanalCenterlinePrimitive`, `entry_orifice_path: NodePath`, `exit_orifice_path: NodePath` (or `closed_terminal = true` + `terminal_pin_offset`), `centerline_particle_count: int = 12`, `radius_profile: Curve`.
  - Per-tick centerline rest refresh (§6.12) reads from the sampled CP world positions (each control point's transform = host_bone_world × ctrl_local_offset) instead of from `<Canal>_CP_*` bone transforms.
  - Type-2 collision (§4.2) formalized as particle vs. swept capsule chain between adjacent rim particles. Capsule radius = per-ring `@export` "rim thickness."
  - Retires: §6.1 / §10.4 Blender rim-anchor authoring; §6.12 / §10.6 step 11 `<Canal>_CP_*` bone authoring; §10.6 step 12 `<Canal>_TerminalPin` bone (becomes a `terminal_pin_offset: Vector3` in the Canal local frame). Existing kasumi rim anchors / CP bones become no-op at next re-export.

- **body_field**:
  - Hosts the shared editor plugin (`BodyFieldGizmoPlugin`) — toolbar button to enter primitive edit mode when a node carrying a primitive resource is selected; renders ring / tube / outline; drags control points and tangent handles.
  - Hosts the shared primitive resource family: `PrimitiveAuthoring` (abstract base) → `RimRingPrimitive` (closed bezier with anchors+handles, default 4 anchors), `CanalCenterlinePrimitive` (open Catmull-Rom, 4–14 control points, per-CP `host_bone`), `RegionOutlinePrimitive` (closed bezier on/near surface), `NetPrimitive` (deferred).
  - Hosts the **arc-length-regular sampler** producing particle rest positions in primitive-local space.
  - Bake change: §17 `BodySurfaceFieldBaker` now accepts **N heat sources per attachment** (one per sampled particle rest position) instead of a single delta at the attachment center. Same Cholesky factor, N back-substitutes (or one solve with N RHS columns). Sum + normalize → ring / tube / region weight field.
  - SDF collider path: smooth-min sphere union over the same particle positions, evaluated on demand by body_field tet collision queries and (future) Tenticles fluid queries.

- **Marionette**:
  - §15 jiggle: `SurfaceJiggleAttachment.falloff_radius` retired; replaced by `region_outline: RegionOutlinePrimitive`. SPD physics unchanged. Glute / breast / jowls authored as closed-bezier outlines on the surface; the virtual particle hangs at the outline centroid.
  - §16 soft regions: same swap — `volume_shape` enum + extents retired in favor of `region_outline: RegionOutlinePrimitive` for boundary shape, plus `cluster_particle_count: int` for interior sampling density. Cluster particle positions sampled inside the outlined region by Poisson disk.
  - §17 `SurfaceOrificeRimAttachment` is **merged into TT's `Orifice` node**. No separate Marionette-side attachment node for rim. The orifice owns its primitive; body_field bakes the per-vertex weights against the orifice's rim particle rest positions.
  - §17 single-source bake retired in favor of N-source bake (above).

- **Appearance / decals, Reverie sensitivity**: no action. The `(I − ε L)` decal diffusion (§17.6) and `SurfaceSensitivityProbe` slot are unaffected — they don't use the new primitives.

- **Tenticles**: no immediate action. The SDF collider path is built but not yet consumed; integrates when Tenticles fluids opens collision against the body.

## Rationale

**Three convergent forcing functions.**

1. **§17 underspecified the geometric shape of attachments.** It treated every attachment as a single Node3D point + scalar `falloff_radius`. A point + radius is a *disc* on the surface, not a ring — and rim loops are explicitly irregular per §6.1 ("rarely circular — jaw, vulva, sphincter are all irregular"). The current §17 bake plants one heat source at the projected node position → produces a disc-shaped weight field, which is the wrong shape for a rim. The original Blender-vertex-loop path was geometrically faithful (walked the actual edge loop arc-length-regular); the §17 amendment lost that fidelity when it collapsed the attachment to a point. This amendment restores the geometry.

2. **Soft physics over scripted levers (root CLAUDE.md).** A bezier-circle gizmo with handles lets the author express orifice shape *as physics rest geometry*, not as a downstream parameter. Slits, ovals, asymmetric vulvae, jaw openings — all expressible through the same primitive. No special-case `enum OrificeShape { Round, Slit, Star }` switch.

3. **Authoring contract consistency.** §17 already retired Blender skin-weight painting for rims, jiggle, and soft regions. But §6.12 canal authoring still required Blender `<Canal>_CP_*` bones (and §10.6 step 12 `<Canal>_TerminalPin`). Two parallel authoring stories — gizmo-in-Godot for rims, bones-in-Blender for canals — would be inconsistent. Bringing canal authoring into the same gizmo system completes the unification the 2026-05-07-02 amendment started.

**Why split Canal from Orifice as separate nodes.**

- Two-ended canals (vagina ↔ cervix, esophagus → stomach with cardia + pylorus) cannot cleanly belong to either of their two orifices. Splitting matches §6.12's existing data model where `Canal` references orifices via NodePath.
- Cervix participates in two canals (vaginal canal entering it, uterine cavity exiting from it). Asymmetric ownership is fragile.
- Closed-terminal sacs (uterus, bladder) — one orifice + one canal + a terminal pin. The Canal-as-its-own-node schema (`entry_orifice` + optional `exit_orifice` + optional `closed_terminal`) captures this cleanly; merging would force a "closed terminal pin" slot onto every orifice.
- Per-CP `host_bone` is a canal-only concern (each CP can ride a different spine bone for canals that tilt into the lumbar). Adding per-control-point host_bone to Orifice would be dead weight 95% of the time.

**Why N heat sources, not 1.**

A single delta at the orifice center diffuses into a disc-shaped field. N deltas at the N rim particle rest positions diffuse into a band-shaped field — radial falloff inward and outward from the rim curve, geodesically. Same Cholesky factor, marginal extra solve cost. This is the geometric content §17 was missing.

**Why capsules + optional SDF, not one or the other.**

- Capsules between adjacent rim particles give TentacleTech a cheap, exact swept-segment collider for the type-2 path.
- SDF (smooth-min sphere union) gives body_field's tet substrate and (future) Tenticles fluids a continuously-deformable signed-distance field — necessary for tet collision projection and SPH-style boundary handling, but overkill for tentacle PBD.

Both derive from the same N particle positions each tick. No duplicated state.

## Migration plan

### 1. `body_field`: primitive authoring infrastructure

- `PrimitiveAuthoring : Resource` (abstract base): `control_points: Array[Transform3D]`, `particle_count: int`, `closed: bool`, `capsule_collider: bool = true`, `sdf_collider: bool = false`, `sdf_smoothness: float = 0.02`, baked-out `particle_rest_positions: PackedVector3Array` (in primitive-local space).
- `RimRingPrimitive : PrimitiveAuthoring`: closed bezier; `control_points` are anchors with bezier `tangent_in`/`tangent_out` per anchor; default 4 anchors; arc-length-regular sampler.
- `CanalCenterlinePrimitive : PrimitiveAuthoring`: open Catmull-Rom through control points; `host_bones: Array[NodePath]` (one per control point, blank = auto-assign nearest skeleton bone at bake); `radius_profile: Curve` (rest radius along arc length).
- `RegionOutlinePrimitive : PrimitiveAuthoring`: closed bezier on or near the body surface; mesh-projected at bake; samples boundary particles (and optionally interior Poisson particles for soft-region clusters).
- `BodyFieldGizmoPlugin : EditorNode3DGizmoPlugin`: detects nodes carrying a `PrimitiveAuthoring` slot; toolbar button toggles edit mode; renders curves + control points + tangent handles; drags update the resource; per-shape rendering (closed/open, axial-direction arrow through the ring).
- Bake change: `BodySurfaceFieldBaker` accepts N heat sources per attachment, runs N back-substitutes against the prefactored `(M − tL)`, sums and normalizes. REPLACE mode uses BBW for partition-of-unity if heat-method sum-of-weights misbehaves on overlapping particles (decision per §17.2).

### 2. TentacleTech: Orifice + Canal nodes

- `Orifice extends Node3D`: `host_bone: NodePath`, `rim_loops: Array[RimRingPrimitive]`, `orifice_profile: OrificeProfile`. World transform driven from `Skeleton3D.get_bone_global_pose(host_bone)` each tick. Rim particle rest positions in Center frame = `rim_loops[l].particle_rest_positions[k]` (post-sampling).
- `Canal extends Node3D`: `centerline: CanalCenterlinePrimitive`, `entry_orifice_path: NodePath`, `exit_orifice_path: NodePath`, `closed_terminal: bool`, `terminal_pin_offset: Vector3`, `canal_parameters: CanalParameters`. Centerline particle rest pose at each tick = piecewise from each CP's `host_bone_world × ctrl_local_offset`, interpolated by the Catmull-Rom basis.
- §4.2 type-2 collision: rewritten as particle vs. swept-capsule-chain between adjacent rim particles. Capsule radius = `RimRingPrimitive.capsule_radius` (default ~2 mm).
- §6.12 centerline tick: `Refresh rest positions` step (1) now reads from the canal's per-CP host_bone transforms via the Catmull-Rom basis, not from `<Canal>_CP_*` bone scans.

### 3. Marionette: jiggle + soft region

- `SurfaceJiggleAttachment.falloff_radius` retired. New: `region_outline: RegionOutlinePrimitive`. Virtual SPD particle anchored at the outline centroid; bake produces region-shaped per-vertex weights.
- `SurfaceSoftRegionAttachment.volume_shape` / `volume_extents` retired. New: `region_outline: RegionOutlinePrimitive` + `cluster_particle_count: int`. Cluster particles sampled inside the outline by Poisson disk. Volume-SDF blend retired; replaced by surface-field weights.
- `SurfaceOrificeRimAttachment` deleted. Replaced by `TentacleTech.Orifice` carrying its own `RimRingPrimitive`. body_field bakes weights directly against the orifice's rim particles.

### 4. Doc edits when applied

- TT §6.1 — replace "Rim anchors authored in Blender along this rim loop" with "Rim particle rest positions sampled arc-length-regular from `RimRingPrimitive` bezier curve on the `Orifice` node." Keep §6.1's frame convention, multi-loop semantics, arc-length-regular requirement. Drop `<Prefix>_RimAnchor_*` bone naming references.
- TT §6.12 — replace "CP bones" / "`<Canal>_CP_*`" references with "control points on `CanalCenterlinePrimitive`." Keep Catmull-Rom centerline, per-CP host_bone (now a NodePath on the primitive), terminal pin (now a Vector3 offset on `Canal`).
- TT §4.2 type-2 — formalize as particle vs. swept capsule chain; specify `capsule_radius` parameter source.
- TT §10.4 / §10.6 — collapse rim authoring + canal authoring sections to "place `Orifice` and `Canal` nodes under the hero root; configure via the body_field gizmo." Remove Blender authoring script references for these two systems. The ARP+toes rig export stays.
- Marionette §15 / §16 / §17 — swap the `falloff_radius` / volume-SDF / single-point attachment models for the new primitive resources. Update authoring contract section in §17 to describe the multi-primitive gizmo plugin.
- `body_field` design doc — add a new section describing `PrimitiveAuthoring` + `BodyFieldGizmoPlugin` + N-source bake.
- Update repo memory entry `project_body_surface_field.md` once §17 is amended in the plan.

### 5. Ordering

- (a) `body_field` primitive infrastructure (resources + gizmo plugin + bake change) — independent, can land in parallel with TT/Marionette.
- (b) TT Orifice node refactor (rim primitive + capsule chain type-2) — gated on (a).
- (c) TT Canal node refactor (centerline primitive + per-CP host_bone) — gated on (a).
- (d) Marionette jiggle + soft region migration — gated on (a); independent of (b)(c).
- (e) Kasumi migration: existing rim anchors / CP bones in the GLB become no-op; re-export drops them. Not load-bearing for ship.

Tentacletech-supervisor was about to scaffold an `OrificeAuthoring` helper + `test_orifice_visual.tscn` for visual eval of Phase 5. **Hold that work.** The "synthetic circle in code" path is what this amendment replaces; visual eval should wait for (b) so it exercises the real authoring path.

## Open questions

- **Q1.** BBW vs. heat-method-falloff for REPLACE-mode rim weights with N overlapping heat sources. §17.2 already flagged this as a benchmark decision; the N-source change makes it more pointed — overlapping heat sources need either post-normalization or BBW's partition-of-unity. Bench on a real hero before §17.2 closes.
- **Q2.** Default capsule radius for rim particles ("rim thickness"). Anatomy varies (a tongue rim ≠ a urethral rim ≠ a vulval rim). Probably a per-`OrificeProfile` field rather than a per-ring primitive field. Decide at implementation.
- **Q3.** Per-CP `host_bone` auto-assignment heuristic for canals. "Nearest skeleton bone in 3D" is the obvious default but can pick the wrong bone for control points near branching anatomy (e.g. near the pelvic floor). Consider weighted-by-skin-LBS instead. Author override is always available; the heuristic only needs to be right enough that authors rarely touch it.
- **Q4.** Net primitive design. Deferred until first concrete use case (hymen? clothing membrane? surface webbing for grappling tentacles?). Architectural slot reserved; particle layout + constraint set unspecified.
- **Q5.** Does the gizmo plugin need to support **mesh-snap** mode for the rim ring (control points constrained to the body surface), or is "free in 3D + project at bake" sufficient? Mesh-snap is more authoring effort to implement and may not be worth it given the bake-time projection already produces correct surface positions. Probably skip.
- **Q6.** Per-CP host_bone storage when the user adds a control point in the middle of an authored canal. Inherit nearest neighbor's host_bone? Re-run auto-assign for that one CP? Choose at implementation; first behavior is simpler.

## Acceptance

Applied when:

- TT supervisor confirms `Orifice` node + `Canal` node land with the new primitive resources, type-2 collision uses the capsule chain, §6.1 / §6.12 / §4.2 / §10.4 / §10.6 are updated to drop the Blender authoring references.
- `body_field` supervisor confirms `PrimitiveAuthoring` resources, `BodyFieldGizmoPlugin`, N-source bake, and SDF collider path are shipped. §17 in `docs/marionette/Marionette_plan.md` is amended to describe the multi-primitive authoring.
- Marionette supervisor confirms §15 jiggle + §16 soft region attachments are migrated to `RegionOutlinePrimitive`, `SurfaceOrificeRimAttachment` is deleted, and the §17 doc reflects the new structure.
- Kasumi is reauthored: existing `<Prefix>_RimAnchor_*` and `<Canal>_CP_*` bones become no-op (left as zero-weight or stripped at next re-export); new `Orifice` / `Canal` / jiggle nodes placed under the hero root; bake runs; visual deformation matches or improves on the previous baseline.
- The "no fiddly authoring" repo memory entry is reaffirmed by the result — authoring surface is gizmo dragging + numeric sliders + bone picks; no Blender script for rim/canal/jiggle; no per-vertex paint.

Doc remains as changelog after edits land in the canonical docs (per root CLAUDE.md convention).
