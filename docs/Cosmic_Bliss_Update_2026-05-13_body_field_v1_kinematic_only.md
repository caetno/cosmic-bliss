## Cosmic Bliss — Design Update 2026-05-13 — `body_field` v1: kinematic-only proxy, parallel to render mesh

> **Status: drafted 2026-05-13, awaiting apply pass to
> `Cosmic_Bliss_Update_2026-05-12-02_flesh_deformer_integration.md`.**
> Amends the v1 scope, slice breakdown (D5/D7), and open question Q1
> of the 05-12-02 brief. Does not change extension placement (D1),
> migration approach (D2), TT contact-fork model (D3), or
> `BoneCollisionProfile`-as-source-of-truth (D4) — those decisions
> hold. Cross-references `Cosmic_Bliss_Update_2026-05-11_hero_skinning_stack.md`
> for why render-mesh fidelity is preserved.
>
> **Audience: top-level Claude (canonical record). Sub-Claude reading
> the 05-12-02 brief should read this as the v1-scope override until
> the apply pass folds these changes into the original brief.**

---

## TL;DR

1. **v1 ships kinematic-only.** Tet vertices are skinned from bones at
   physics-tick rate; no XPBD predict/correct, no Neo-Hookean, no LRA,
   no SDF collision inside the substrate. 1 compute pass instead of 9.

2. **Tet proxy runs parallel to the render mesh, not upstream of it.**
   The render mesh keeps its existing DQS + Delta Mush + surface-field
   offset stack (per 05-11). The tet proxy is a collision-only
   structure that TentacleTech contacts. `surface_transfer.glsl` is
   **out of v1** — there is no sim-driven deformation to carry to
   render.

3. **Render fidelity at extremities is preserved by DQS+DDM**, not by
   the tet proxy. Toe and finger articulation reaches the player
   through the existing skin shader unchanged. Tet resolution does not
   bottleneck visible quality.

4. **Extremities are masked out of the tet proxy.** Hands and feet
   keep contacting via the existing `BoneCollisionProfile` capsule
   path. The TT type-1 fork (D3) routes per-particle by body region:
   torso/limbs/head → proxy contact, hands/feet → capsule contact.
   This is the same authoring-time filter pattern as Q2 (excluding
   canal interior).

5. **B3 (BoneCollisionProfile → GPU SDF converter) and most of the
   prototype's compute pipeline defer to v1.5.** They only earn their
   keep when XPBD runs. The substrate, the `.bin` format, the
   authoring chain, and the kinematic-targets pass are forward-
   compatible with v1.5 by construction: v1.5 is purely additive over
   v1.

6. **v1.5 is conditional on validation.** B6 acceptance asks: does the
   kinematic-only proxy + Marionette §15 jiggle bones clear the
   visible-quality bar on kasumi belly/glute/throat? If yes, ship and
   defer XPBD indefinitely. If no, port the rest of the prototype's
   compute pipeline (8 shaders) and `surface_transfer.glsl` as v1.5 —
   the contact path doesn't change, only the source of proxy-vertex
   positions.

---

## What changed since the 05-12-02 brief

The 05-12-02 brief proposed porting the full GPU XPBD pipeline and
tuning it "kinematic-pin-dominant." The visible-softbody contribution
under that tuning was already small ("subtle but visible"). Two
observations push the design past that midpoint:

**(a) The XPBD machinery is doing limited visible work in v1 anyway.**
At kinematic-pin-dominant tuning, the tet sim is approximating the
identity function with controlled compliance. Most of the budget goes
to converging the kinematic pin constraint against bone motion.
Dropping the sim and writing positions directly is the limit case of
that tuning, and removes 8 shaders, the elasticity tuning surface, and
all coupling-pathology risk vs. the TT solver in one move.

**(b) `surface_transfer.glsl` is the load-bearing piece for visible
softbody, and v1 has no softbody to transfer.** If the prototype's
output path drove the render mesh in v1, render-mesh skinning quality
would collapse to tet resolution everywhere — toe articulation would
be bounded by the tet density at the foot, not by the authored bone
weights. That's a regression for the rest of the body in service of
softbody contribution that v1 explicitly de-prioritized. The fix is to
not wire it up in v1 at all. Per the 05-11 skinning-stack brief, the
tet's role in render was always *additive secondary offset*, never
primary — so dropping surface_transfer in v1 is consistent with that
architecture (the additive offset just contributes zero when sim is
off).

The original brief's "kinematic-pin-dominant" framing was the right
intuition. This amendment makes it structural rather than a tuning
state.

---

## v1 architecture (kinematic-only)

### Two parallel paths, one skeleton, no coupling

```
   skeleton (Marionette / SPD / IK / jiggle bones)
        │
        ├── render path (per 05-11):
        │   raw     = DQS(VERTEX_rest, BONES, WEIGHTS)
        │   smooth  = DDM(raw)
        │   final   = smooth + surface-field offsets (jiggle, soft, rim)
        │   ▼
        │   render mesh (what the player sees)
        │
        └── collision path (this brief):
            tet_pos[i] = LBS(bone_transforms, tet_skin_weights[i])
            ▼
            tet outer surface (what tentacle particles contact)
```

Two paths consume the same skeleton; they do not exchange data at
runtime. No surface_transfer; no compositing; no double-driving any
vertex. If the proxy surface and the render surface disagree by a few
millimeters at extremities, the disagreement is invisible because the
proxy is invisible — its only consumer is TT contact dispatch.

### Tet skin weights

Three sources, in increasing order of fidelity. v1 uses #1 + #2; #3 is
the v2+ slice B9 upgrade.

1. **Boundary tet verts** (those coincident with body-mesh verts per
   §18's boundary-coincidence rule) **inherit weights from the render
   mesh.** Same authored skin weights, same articulation quality where
   it matters for the proxy surface.
2. **Interior tet verts** get a cheap closest-bone-distance LBS at
   bake time. They never drive contact (only the outer surface does),
   so quality is moot in v1.
3. **(v2+ B9)** Volumetric heat method on the tet Laplacian gives
   anatomically-smooth per-tet weights. Marionette §18 amendment 1
   exact deliverable. Earned when interior tet motion starts driving
   visible deformation (i.e. when XPBD ships).

### Extremities mask

Hands and feet are excluded from the tet proxy at authoring time.
Pattern matches Q2 (canal-interior face filter): the Blender-side
authoring step (B4) reads a per-face region tag and excludes hand/foot
faces before piping the closed boundary mesh to FloatTetwild. The
exclusion is authored once per hero with a coarse region paint.

TentacleTech type-1 dispatch is then **per-particle, per-region**:

| Particle nearest-bone classification | Contact path |
|---|---|
| torso, limbs (above wrist / above ankle), head | tet proxy surface |
| hand bones (carpal + finger phalanges) | BoneCollisionProfile capsules |
| foot bones (tarsal + toe phalanges) | BoneCollisionProfile capsules |

The dispatch lookup is a flat per-bone enum, set at hero load. No
per-tick branching beyond a single integer compare.

Net effect: the proxy plays to its strength (soft middle: belly,
glute, breast, throat) and capsules retain their (already-narrow) win
condition (small bones with fine articulation). No region loses
fidelity vs. the current capsule-only baseline.

---

## Revised slice breakdown — `body_field` Phase B

### v1 (B0–B6)

| Slice | Status | Notes |
|---|---|---|
| **B0** Extension scaffolding | unchanged from 05-12-02 | |
| **B1** `.bin` loader port | unchanged | Loader is forward-compatible; `.bin` format unchanged for v1.5/v2 |
| **B2** Kinematic-targets pass only | **reduced** | Port `kinematic_targets.glsl` only. The remaining 8 prototype shaders (`integrate`, `solve_volume`, `solve_kinematic_pin`, `solve_sdf_collision`, `solve_lra_tether`, `solve_elasticity`, `update_velocity`, `surface_transfer`) stay on the shelf for v1.5. |
| **B3** BoneCollisionProfile → GPU SDF converter | **deferred to v1.5** | Only consumed by `solve_sdf_collision.glsl`. D4 (single source of truth for per-bone shapes) still holds as the long-term rule; the converter just isn't load-bearing until SDF collision runs. |
| **B4** `.bin` authoring chain port | unchanged in scope | Adds the extremities-mask filter (this brief). Tet skin weights are baked here from inherited render-mesh weights (boundary) + closest-bone LBS (interior). |
| **B5** TT type-1 fork against tet surface | unchanged in shape | Per-particle dispatch is per-region (this brief, not per-hero as 05-12-02 implied). Per-hero opt-in is still the wrapping toggle: a hero without `BodyField` falls through to the capsule path everywhere. |
| **B6** Validation pass | **expanded** | Acceptance now also asks: does kinematic-only + jiggle bones clear the visible-quality bar? Result determines whether v1.5 (XPBD port) opens. |

### v1.5 (conditional)

Opens only if B6 says soft regions need real compliance under contact
load (i.e., jiggle bones + kinematic proxy don't read as "soft enough"
on belly/glute/throat). Slices:

- **B5.5 — XPBD compute pipeline port.** Port the 7 sim shaders
  verbatim (`integrate`, `solve_volume`, `solve_kinematic_pin`,
  `solve_sdf_collision`, `solve_lra_tether`, `solve_elasticity`,
  `update_velocity`). B3 BoneCollisionProfile→SDF converter promotes
  out of "deferred" and lands here.
- **B5.6 — `surface_transfer.glsl` integration.** Wires tet-driven
  additive offsets into the 05-11 skinning stack's
  "ADDITIVE-mode secondary offsets" slot. The render-mesh shader is
  unchanged; only the data source for the soft-cluster offset block
  changes from "PBD particle positions" to "tet-vertex positions
  skinned to surface verts via surface-field weights," exactly as 05-11
  §interaction-with-volumetric-tets anticipated.
- **B5.7 — XPBD tuning.** pin compliance, Neo-Hookean stiffness, LRA
  tether length. Brief retains the original B6 acceptance bar verbatim
  for this slice.

### v2+ (deferred, unchanged)

B7 multi-region partitioning, B8 tissue-type classification + per-tet
anisotropy, B9 volumetric heat method on tets, B10 Reverie modulation
API. Unchanged from 05-12-02 §D7.

---

## Open questions — status delta from 05-12-02

| Q | Status |
|---|---|
| **Q1** Jiggle bone composition with tet sim | **resolved by construction.** Jiggle bones drive the render mesh via the existing 05-11 surface-field-offset block. They do not need to compose with the tet proxy at all in v1, because the proxy doesn't drive render. In v1.5, jiggle bones become kinematic targets in the tet sim per the original Q1 recommendation. |
| **Q2** Canal interior verts vs. tet mesh | **unchanged.** Canal-interior faces filtered out at authoring time. Same filter mechanism this brief reuses for the extremities mask. |
| **Q3** Tet sim + canal pipeline boundary at orifice rims | **deferred to v1.5.** No tet sim in v1 = no type-1-vs-canal double-count risk. Recommendation stands for v1.5. |
| **Q4** Multi-hero `.bin` ownership | **unchanged.** API shape decided at B1. |
| **Q5** Ragdoll snapshot discipline | **trivially satisfied in v1.** Single kinematic pass writes positions once per substep; no iteration. Invariant remains a hard rule in B0 CLAUDE.md for the v1.5 expansion. |

---

## v1 visible-quality bar — revised

- Tentacle contact reads cleanly against the proxy surface — no leaks,
  no tunneling, no per-frame popping at seams. **Unchanged.**
- **Hard regions** (head, ribcage, forearms) feel as rigid as the
  current capsule path. **Unchanged** — the proxy is rigid kinematic
  everywhere in v1, so this is automatic.
- **Soft regions** (belly, glute, throat) feel *no worse than the
  current capsule path on contact-load compliance* (i.e., no
  depression under tentacle pressure), and *visibly better on contact
  geometry* (the proxy follows the soft region's shape; capsules
  approximate it as a tube). Visible wobble comes from Marionette §15
  jiggle bones, routed through the render mesh's existing offset
  block, **not** through the proxy.
- **Hand / foot** contact is on capsules, exactly as today. No
  regression.
- **No regression** in TT Phase 5 acceptance scenarios on kasumi.
  **Unchanged.**

If B6 finds that "no depression under contact load" reads as too rigid
in soft regions, v1.5 opens. If it reads as fine, we keep the
simplification permanently and 8 shaders worth of code never get
ported.

---

## Knock-on effects — delta from 05-12-02

| Doc / file | What changes |
|---|---|
| `Cosmic_Bliss_Update_2026-05-12-02_flesh_deformer_integration.md` | This brief is the v1-scope override. Apply pass folds the changes into the original brief's TL;DR, v1 scope, D5/D7, and Q1. The original remains as design context for v1.5/v2; v1 reads this brief first. |
| `docs/marionette/Marionette_plan.md` §18 | Status stays ACTIVE. Add note: "v1 ships kinematic-only proxy in `body_field`; tet sim (XPBD + amendments 1–3) lands in v1.5+ conditional on visible-quality validation." Lands as a single-line amendment at the apply pass. |
| `docs/marionette/Marionette_plan.md` §15 (jiggle) | v1: jiggle stays on the existing render-mesh additive-offset path (per 05-11). No tet routing. v1.5: original 05-12-02 Q1 recommendation applies (jiggle becomes kinematic target inside tet sim). |
| `docs/architecture/TentacleTech_Architecture.md` §4.2 (collision types) | Type-1 rename ("tentacle particle vs. outer body") lands at B5 as before. Note that the proxy/capsule choice is per-region, per-particle, not whole-hero. |
| `docs/architecture/TentacleTech_Architecture.md` §10.5 (capsule suppression) | Suppression rule applies to whichever path the particle is currently on (proxy or capsule). Update at B5. |
| `extensions/body_field/CLAUDE.md` (authored at B0) | Codifies the two-paths invariant: tet proxy never drives render in v1; `surface_transfer.glsl` is v1.5 territory; render quality is owned by the 05-11 skinning stack. |
| `extensions/tentacletech/CLAUDE.md` | Per-region dispatch table (this brief) lands at B5. Same snapshot discipline as before. |
| `tools/blender/` or `blender_bliss` v0.3.0 | B4 adds the extremities-mask filter alongside the canal-interior filter. One more pre-FloatTetwild face exclusion pass. |

---

## Apply checklist for top-level Claude

1. ✅ Brief written (this doc).
2. **Apply pass — `Cosmic_Bliss_Update_2026-05-12-02_flesh_deformer_integration.md`.**
   Surface the v1-scope override at the top of the brief (status line +
   one-paragraph pointer). Do not delete the original v1 content — it
   remains as the v1.5/v2 reference. Update D5/D7 slice breakdown to
   reflect the B2/B3/B5/B6 changes. Mark Q1 resolved.
3. **Apply pass — `Marionette_plan.md` §18.** One-line addendum noting
   the v1 kinematic-only scope and v1.5 conditional gate.
4. **Prompt sub-Claude for B0** (when the body_field supervisor opens)
   — extension scaffolding as before, but with the kinematic-only
   invariant codified in the new extension's CLAUDE.md.
5. **Update memory** — `reference_flesh_deformer_prototype.md` gets a
   pointer to this brief; `project_body_field_state.md` reflects the
   reduced v1 slice count.

---

## Summary

v1 ships a kinematically-skinned tet proxy used by TentacleTech as a
collision-only surface, parallel to the render mesh. Render fidelity
is owned by the 05-11 skinning stack (DQS + DDM + surface-field
offsets); the proxy is invisible to the player. Extremities (hands,
feet) stay on capsules; the proxy covers torso/limbs/head where
capsules visibly fail. One compute pass (kinematic_targets); zero
tuning surface; no coupling-pathology risk vs. the TT solver. The
prototype's remaining 8 shaders + `surface_transfer` stay on the
shelf, conditionally opening as v1.5 if B6 validation finds soft
regions need real compliance under contact load. v2+ (B7–B10) deferred
unchanged. Marionette §18 stays ACTIVE; its three amendments move
into the v1.5+ slice family because they only matter once sim runs.
