---
name: BodySurfaceField — skinning unification opened 2026-05-07
description: Prefactored cotan-Laplacian on body mesh derives per-vertex skinning weights for soft-region / orifice-rim / jiggle attachments; vanilla ARP+toes Blender rig is target authoring shape; everything else placed as nodes in Godot
type: project
originSessionId: ccaf24fd-acfe-4024-b9b6-7c19b411e9a1
---
**Decision 2026-05-07-02:** opened `BodySurfaceField` as a shared infrastructure subsystem. Brief at `docs/Cosmic_Bliss_Update_2026-05-07-02_body_surface_field.md`.

**The unification.** Three previously-separate authoring surfaces collapse into one Godot-side workflow:
- TentacleTech orifice rim — was Blender skin-weight painting on `<Prefix>_Ring_i` deform bones (§6.1, §10.4); becomes `SurfaceOrificeRimAttachment` nodes in Godot
- Marionette jiggle bones — was Blender skeleton hierarchy at modeling time + skin weights painted (§15); becomes `SurfaceJiggleAttachment` nodes in Godot
- Marionette §16 soft regions — was volume-SDF blend; becomes surface-field blend (volume primitive remains as particle spawn scaffold only)

**Target authoring shape (user direction 2026-05-07).** Vanilla ARP rig with toes (Marionette Phase 1) in Blender. Body mesh + standard ARP skin weights. No orifice rim anchors. No jiggle bones. No soft-region helper bones. Everything region-shaped placed as Godot-side `SurfaceAttachment` subclass nodes with a `host_bone` reference + `falloff_radius` + numeric profile params. Surface field auto-derives the per-vertex skinning weight at hero-load bake.

**Mathematical primitive.** Crane et al. heat method (2013) with `(I − tL)` Cholesky-prefactored on the rest-pose cotan-Laplacian. For replace-mode (orifice rim) likely uses Bounded Biharmonic Weights (Jacobson 2011) for partition-of-unity. Decision lands in §17.2.

**Three blend modes:** ADDITIVE (jiggle, soft regions — particle offset on top of bone-LBS), REPLACE (orifice rim — particles fully drive verts), PARTIAL_REPLACE (transition zones).

**Bilateral mask** via existing ARP host-bone LBS weight is the cross-anatomy leak fix; combined with `falloff_radius` for tight peaks.

**Phase plan §17.1–§17.6.**
- §17.1 core (Laplacian, factor, attachment hierarchy, baker)
- §17.2 heat-method-falloff vs BBW decision
- §17.3 Marionette §16 amendment (volume-SDF blend → surface-field blend)
- §17.4 TentacleTech orifice rim amendment (Blender weight-painting retires)
- §17.5 Marionette jiggle amendment (Blender bone authoring retires)
- §17.6 appearance decal diffusion (geodesic, not blocking)

Runs in parallel with TentacleTech Phase 4.5 (no PBD-core interaction). **Blocks Marionette §16 past §16.1** — implementing the volume-SDF blend in §16.2+ is wasted work since it retires.

**Pending amendments flagged in canonical docs** (small notes added 2026-05-07-02; full amendments land when the brief is approved + each §17 slice runs):
- `docs/marionette/Marionette_plan.md` §16 jiggle bones header
- `docs/marionette/Marionette_plan.md` "Soft-tissue jiggle bone clusters" section header
- `docs/architecture/TentacleTech_Architecture.md` §10.4 hero authoring header

**Downstream consumers** that fall out of the same prefactored Laplacian for ~free:
- Decal accumulator (geodesic diffusion via `decal_t+1 = (I − ε L) decal_t`) — `docs/Appearance.md`
- Reverie sensitivity field (smooth per-vert sensitivity from contact source set)
- Vector heat method for canal-θ baking (canal interior model 5E/5F/5G)
- Procedural mesh fairing (cotan-Laplacian smoothing)

**Caveats.** Mesh topology must be locked at hero load (it already is). Mesh must be reasonably manifold (ARP exports are fine; baker errors visibly on bad triangles). Cotan-Laplacian on a deforming skinned mesh is approximate — bake against rest pose, accept geodesic approximation under stretch (this is the heat-method paper's option (a)).
