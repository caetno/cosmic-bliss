# Cosmic Bliss — Design Update 2026-05-10 — Body volumetric tet substrate

> **Status: applied 2026-05-11 to `docs/marionette/Marionette_plan.md` §18 (STRETCH).** Tet substrate is *not load-bearing for the immediate roadmap* — §17 surface-only covers the current visible-deformation budget (rim authoring, jiggle authoring, soft-region surface offset; bulger system unchanged on the TT side). §18 opens only when the surface-offset path starts looking too uniform-rigid under penetrating contact. Brief retained as changelog; full implementation notes preserved here for when §18 promotes from stretch to active. Amends `Cosmic_Bliss_Update_2026-05-07-02_body_surface_field.md` after the Obi
> softbody source review (see `docs/pbd_research/findings_obi_softbody_authoring.md`).
> Three changes to the `BodySurfaceField` plan, all reducing to "use a tet
> mesh as the geometric substrate, not just the surface mesh."

---

## TL;DR

Three amendments, each independent, all in the same direction:

1. **Volumetric heat method on tets** for any body-interior scalar
   (distance-to-bone, sensitivity-from-contact-source, decal-bleed if we ever
   want it volumetric). Replaces "cotan-Laplacian on the surface" as the
   load-bearing primitive for *interior* fields. The surface Laplacian stays
   as the right tool for surface-only fields (decal diffusion across skin,
   surface vector-θ).

2. **Kinematic vertex = overwrite, not constrain** is the runtime contract
   for the tet solver. Bone-driven tet vertices have their position written
   directly from the live bone transform every tick; per-tet constraints
   (co-rotational FEM, shape-matching, whichever we land on) carry the
   coupling to the simulated tet vertices. **No joints between kinematic and
   simulated tet vertices.**

3. **Per-tet anisotropy direction from the bone-weight field gradient.**
   Muscle tets get a stiffness anisotropy axis = `∇(distance-to-bone)`
   (computed via the volumetric heat method in amendment 1). Muscle resists
   stretch along the bone-pull direction; fat tets stay isotropic.

The changes preserve the no-fiddly-authoring rule: the user still authors
ARP+toes in Blender plus volume primitives + numeric sliders in Godot.
Tetrahedralisation is a bake-time step, never authored.

---

## 1. Volumetric heat method on tets

**Current brief (surface-only).** §70 of the 05-07-02 brief uses a discrete
cotan-Laplacian on the rest-pose body *surface* mesh. Caveat 3 (§352) calls
out that the surface Laplacian is approximate under deformation, and §1's
table acknowledges that "for interior we'd need either an SDF or stick with
surface-only."

**Amendment.** For any field whose semantically-correct domain is the body
interior, build a **volumetric Laplacian on a tet mesh of the body interior**
and use the volumetric heat method (Crane, Weischedel, Wardetzky 2013 —
the same paper, Sec. 3.2 explicitly covers tetrahedral domains). The
volumetric Laplacian is the standard FEM cotan-equivalent on tets:

```
L_ij = (1/6) * Σ over tets containing edge (i,j) :  cot(dihedral_ij)
M_ii = (1/4) * Σ over tets containing vertex i :   tet_volume
factor = cholesky(M − t * L)
```

Cholesky-prefactored once at hero load. Same back-substitution pattern as the
surface case. Marginal extra code over the surface implementation (the cotan
operator generalizes; the assembly loop iterates over tets instead of
triangles).

**What goes volumetric:**

- **Distance-to-bone** — the load-bearing one. Used for tet classification
  (muscle vs fat thresholds), for the anisotropy gradient (amendment 3),
  potentially for soft-region falloff weights when the geodesic-on-surface
  shoulder visibly wraps around a limb instead of penetrating into it.
- **Sensitivity-from-contact-source** — Reverie consumes a per-region
  sensitivity scalar; if the contact source is a deep penetration the
  volumetric solve respects that the inside-of-canal sensitivity should reach
  surrounding tissue through the body interior, not around the external
  surface.

**What stays on the surface:**

- **Decal diffusion** (oil, sweat, bruises). Skin-only by definition. Surface
  Laplacian is the right operator. No change from the 05-07-02 brief.
- **Surface vector-θ** for canal axis registration. Surface phenomenon, lives
  on the boundary, surface Laplacian + connection-Laplacian (vector heat
  method) is correct.
- **Per-vertex skinning weights for replace-mode rim and additive jiggle**
  remain surface fields — they paint vertex weights on the body mesh, not on
  tet interior nodes.

**Where the tet mesh comes from.** Bake-time tetrahedralisation of the body
interior using the closed body surface mesh as the boundary. TetGen-style
constrained Delaunay tetrahedralisation, Eigen + libigl have well-trodden
wrappers. Resolution is a single numeric slider (target tet count or target
edge length); the user never sees individual tets. The body surface mesh
remains the rendering primitive — tets are interior-only, not skinned to the
mesh directly. Tet vertices on the body boundary coincide with body mesh
vertices.

**Cost.** A 5k-vertex body surface produces ~30–60k interior tets at sensible
density. Cholesky factor of 30–60k SPD matrix is ~50–200 MB and a few
seconds of bake on CPU; well within hero-load budget. **Not** in any
per-frame path.

**Architectural note.** The 05-07-02 brief's `BodySurfaceField` autoload /
component grows a sibling `BodyVolumetricField` (or absorbs both into one
`BodyField` with surface and volumetric factors as separate members).
Probably the latter — both factor against the same hero, both bake at the
same time, both are owned by the same lifetime. Resolve at §17.1
implementation.

---

## 2. Kinematic vertex = overwrite, not constrain (runtime rule)

**Lifted directly from Obi.** See `docs/pbd_research/findings_obi_softbody_authoring.md`
§5 — Obi's bone-particle pattern is `invMass = 0` plus a per-tick position
overwrite from `bone.localToWorld * bindPose * restPosition`. **No joint, no
spring, no constraint between bone-particle and flesh-particle.** The
shape-matching cluster *is* the joint.

The 05-07-02 brief is silent on this for the tet case (because it didn't
have a tet case). This amendment makes it explicit:

**Rule.** A tet vertex bound to a bone is **kinematic**. Each simulation
tick, before any constraint solve:

```
for each kinematic tet vertex v with host bone b:
    v.position = solver.worldToLocal * b.localToWorld * v.bindPose * v.restPosition
    v.velocity = (v.position - v.position_prev) / dt   # FEM-style: derived, not solved
    v.inv_mass = 0
```

Per-tet constraints (co-rotational FEM strain, shape-matching, distance,
volume — whichever set we land on at §17 implementation time) treat
kinematic vertices as fixed boundary conditions in the standard way: they
contribute their position to the constraint's rest-shape match but absorb
zero correction. The constraint pushes the *simulated* vertices to satisfy
the per-tet rest pose; the kinematic vertices drag the rest pose with them.

**Specifically forbidden:**

- No spring constraint between a kinematic tet vertex and a simulated tet
  vertex. The tet element's elastic constraint already does this implicitly
  via the rest shape; an extra spring is double-coupling.
- No joint authoring between bone and tet. Binding is purely
  classification: "which bone owns this tet vertex" is a bake-time decision
  derived from `argmax(bone_weight_per_vertex)` (the same ARP weight the
  body mesh uses), not a per-vertex authoring step.
- No "ramped" kinematic pinning where the position is partially overwritten
  and partially solved. Kinematic = fully overwritten. The transition zone
  between kinematic and simulated tets is handled by *which tets get
  classified as kinematic*, not by per-vertex blending.

**Authoring contract.** The user picks a numeric threshold (e.g. "tets with
distance-to-bone < 2 cm are kinematic / muscle / fat" — exact thresholds
land at implementation). Tets are classified at bake time. The set of
kinematic tet vertices is the boundary between bone-attached tets and free
tets. The user does not pick individual tets.

This rule is short but load-bearing: every tet-system architecture review
should be able to point at it as the single answer to "how does the tet
solver couple to the bone rig."

---

## 3. Per-tet anisotropy from the bone-weight field gradient

**Motivation.** Real muscle resists stretch along the direction it pulls
(fiber direction); fat is roughly isotropic. We don't want to author fiber
directions per tet (that's the kind of fiddly authoring rule we've already
ruled out). We do want muscle tets to behave anisotropically.

**Amendment.** During bake, after the volumetric heat method gives us a
per-tet `distance_to_nearest_bone` scalar field (amendment 1), compute
**`fiber_axis = normalize(∇(distance_to_nearest_bone))` per tet**. This is
the direction of steepest ascent away from the bone — equivalently, the
direction muscle would pull the tet *toward* the bone. Use it as the
stiffness anisotropy axis for muscle tets.

**Material model (sketch).** Whichever per-tet elastic constraint we land on
(co-rotational linear FEM, neo-Hookean, anisotropic shape-matching), the
muscle tet's stiffness becomes:

```
K_muscle = K_iso * I + K_aniso * outer(fiber_axis, fiber_axis)
```

`K_iso` and `K_aniso` are scalars from the muscle profile (numeric sliders;
no painting). Fat tets get `K_aniso = 0` and reduce to isotropic
shape-matching. The exact constraint form is an implementation choice for
§17; what's nailed down here is *how the anisotropy axis is derived* —
gradient of the bone-weight field, computed at bake time, stored per tet,
never re-derived at runtime.

**Tet classification — the only authoring step the user sees.** A tet is
classified into a tissue type by:

1. Volume primitives placed in Godot (the same `volume_shape` /
   `volume_extents` already in `SurfaceSoftRegionAttachment` per the
   05-07-02 brief) carry a `tissue_type` enum: Muscle / Fat / Gland / Skin.
2. At bake time, every tet is point-tested against every volume primitive;
   the classification with highest priority (or geodesic SDF closest, TBD at
   implementation) wins.
3. Tets not enclosed by any classifier volume default to Fat (inert
   isotropic).

This is consistent with the no-fiddly-authoring rule: the user places volume
primitives + sets a `tissue_type` dropdown + tunes numeric stiffness
sliders. No per-tet anything.

**Failure mode and fallback.** Where `∇(distance_to_nearest_bone)` is
near-zero (a tet equidistant from two bones — e.g. mid-belly between left
and right ribs), the gradient direction is unstable. Fallback rule: if
`|∇d| < ε`, flag the tet as locally isotropic (treat as fat for that tet's
constraint, regardless of `tissue_type`). The visible bake artifact (a thin
band of "isotropic muscle" along the body midline) is acceptable; the
alternative (random fiber direction) is worse.

---

## What this does not change

- **Authoring contract** stays at "ARP+toes in Blender; volume primitives +
  numeric sliders in Godot." Tetrahedralisation, classification, anisotropy
  derivation, kinematic boundary detection are all bake-time.
- **Surface skinning path** stays — the body mesh is still rendered via
  bone-LBS plus surface-attachment offsets per the 05-07-02 brief. The tet
  solve drives the rest *position* of the surface vertices that participate
  in tet boundaries; non-boundary surface deformation is still LBS +
  attachment offset. (Practically: surface mesh vertices at the body
  boundary are tet vertices, so they inherit tet-solve positions
  automatically.)
- **Decal diffusion** stays surface (surface-only phenomenon).
- **Vector-θ baking** stays surface (canal axis is a surface-tangent field).
- **Phase plan** §17.1–§17.6 from the 05-07-02 brief stands; this amendment
  inserts a `§17.0` (tet substrate) before §17.1 (cotan-Laplacian core), and
  expands §17.3 (Marionette §16 amendment) to use the tet solve for
  soft-region cluster constraints.

---

## Implementation notes (for §17.0 when it opens)

- Tetrahedralisation library: libigl's `igl::copyleft::tetgen::tetrahedralize`
  is the natural choice; pure-C++, MPL2-licensed, builds cleanly into the
  GDExtension. Alternative: ftetwild for robust tetrahedralisation of
  imperfect meshes, but heavier dependency.
- Volumetric Laplacian assembly: ~50 lines of C++ given a tet-index buffer;
  trivial against Eigen sparse matrices.
- Cholesky: `Eigen::SimplicialLLT<SparseMatrix<float>>`. Rest of the heat
  method is the same back-substitute-and-normalize pattern as surface.
- Kinematic-overwrite step: write position before constraint loop, do not
  touch in the constraint loop. Mirror Obi's pattern in
  `ObiSoftbodySkinner.Softbody_OnSimulate`.
- Anisotropy storage: per-tet 3-vector for `fiber_axis`, two scalars for
  `K_iso` / `K_aniso`. Fits in 5 floats per tet; for 50k tets that's 1 MB
  static data, no per-frame upload.

---

## Open questions

**Q1.** Volume primitive `tissue_type` enum — what does the initial set
look like? Probably `Muscle`, `Fat`, `Gland`, `Skin`, `Inert`. Fits the
soft-region story; opens neatly to expansion (e.g. `MucousMembrane` for
canal interior) without restructuring.

**Q2.** Per-tet constraint formulation — co-rotational linear FEM (Müller
2002) or shape-matching tet clusters (the Obi-style approach extended to
tets)? Co-rotational FEM is more physically correct and the
anisotropic-stiffness extension is well-trodden. Shape-matching tets are
simpler and integrate uniformly with the existing PBD solver. Bench at
§17.0 implementation.

**Q3.** Where does the tet solve run? Hot enough to be C++ (per-tick, per-tet
constraint projection). Lives in `BodySurfaceField` extension's C++ core, or
absorbed into TentacleTech's PBD solver. Probably the former — the body
solve is a sibling of, not part of, tentacle PBD; coupling is via shared
particle positions on body-surface verts that orifice rims also touch.

**Q4.** Fiber-axis fallback — accept the midline isotropic-muscle band, or
derive a secondary axis (e.g. the bone-pair-bisector direction)? Visual
bench at implementation; midline band is small and may be invisible.

---

## Summary

Three amendments to the body-field plan: (1) use the volumetric heat method
on tets for body-interior scalars; (2) kinematic tet vertices are overwritten
each tick, not coupled by joints — per-tet constraints carry the coupling;
(3) muscle-tet stiffness anisotropy axis = `∇(distance-to-bone)`, derived at
bake time from the volumetric scalar field. None of the three break the
no-fiddly-authoring rule: tet generation, classification, anisotropy
derivation, and kinematic boundary detection all happen at bake time, driven
by the same volume-primitive + numeric-slider authoring surface already in
the 05-07-02 brief.
