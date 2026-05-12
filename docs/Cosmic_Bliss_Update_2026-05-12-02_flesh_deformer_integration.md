# Cosmic Bliss — Design Update 2026-05-12-02 — Flesh-deformer integration (`body_field` extension)

> **Status: applied 2026-05-12 to `docs/marionette/Marionette_plan.md`
> §18 in commit `94cc0f4`** (STRETCH → ACTIVE, retitle to "Volumetric
> tet substrate", cross-references from §15 / §16 / §17 to `body_field`
> extension, three §18 amendments reframed as v2+ slices B7–B10).
> Brief retained as the v1 design record; sub-Claudes can read this
> for "what's in v1 and why," Marionette_plan.md §18 for the
> architecture-level placement.
>
> A working GPU XPBD volumetric tet deformer prototype exists at
> `~/desktop/flesh-deformer/` (full inventory in
> `reference_flesh_deformer_prototype.md` memory). Marionette §18
> already specs against the same primitives. This brief proposes
> porting the prototype into cosmic-bliss as a new top-level extension
> with a deliberately conservative v1 role: **high-fidelity collision
> surface for particle-based systems** (TentacleTech now, Tenticles
> fluids later).
>
> **Audience: top-level Claude (canonical record). Sub-Claude reads
> Marionette §18 + the new `extensions/body_field/CLAUDE.md` once the
> apply pass lands.**

---

## TL;DR

1. **New top-level extension `extensions/body_field/`** owning volumetric
   tet substrate (§18) and, later, surface field (§17). Single extension,
   two slice families — they share the body mesh source, the hero-load
   bake step, and (eventually) the cotan-Laplacian factorization
   machinery.

2. **v1 role: replace BoneCollisionProfile's outer-body-collider role
   for particle-based systems.** Tentacle particles contact a deformed
   tet surface instead of bone capsules. Hero capsules / convex hulls
   stay live in Jolt for ragdoll-internal physics; the deformer's bone
   SDFs (read from the same `BoneCollisionProfile`) drive tet-vs-bone
   collision inside the solver.

3. **Tet sim tuned kinematic-pin-dominant.** The solver runs, but pin
   compliance is high enough that the surface tracks bones tightly.
   Visible softbody contribution stays small. Marionette §15 jiggle
   bones keep providing the post-contact wobble (now routed through the
   tet sim as additional kinematic targets, not added on top).

4. **Marionette §18 promotes from STRETCH to ACTIVE.** The three §18
   amendments (volumetric heat method on tets, kinematic vertex =
   overwrite, per-tet anisotropy from `∇(distance-to-bone)`) move from
   "stretch goal" to "v2+ slices in `body_field`." Items 2 and 3 are
   already shipped in the prototype; item 1 is the bake-time extension
   v2 adds.

5. **No reimplementation.** Port the 9 compute shaders + 1743-LOC
   orchestrator + `.bin` loader essentially verbatim. Adapt for
   cosmic-bliss conventions (plugin.cfg / gdextension manifest /
   build.sh chain / repo-side authoring tooling). The substrate is
   built; cost is integration, not invention.

6. **Hard constraint already met.** TT 4Q stabilized via 4Q-fix (shipped
   in commit ad30080 before 4S close-out cluster); Phase 4 fully closed
   through 4S.3 (commit `f051493`). Coupling pathology that would have
   blocked tentacle-vs-tet-surface contact integration is settled. v1
   scaffolding work can begin immediately; B5 contact integration runs
   after scaffolding lands.

---

## Why now

| Problem | Status |
|---|---|
| **Capsule/hull colliders miss soft regions.** Tentacles slide through gaps that shouldn't exist (belly fold, throat hollow, glute crease). | Recurring visual failure on kasumi acceptance scenarios; no current path to fix without changing collision representation. |
| **Future fluid sim inherits the same surface.** Tenticles (currently blocked at Phase 4.5) will need contact against the same hero surface. Better to fix once than twice. | Forward-looking; not blocking today but compounds if v1 ships only for tentacles. Solved by the type-1 fork being geometry-source-agnostic. |
| **Marionette §18 is currently spec'd against a hypothetical implementation.** The prototype matches the primitives §18 specs against. | Already in `reference_flesh_deformer_prototype.md`. Risk: spec drift between Marionette plan and what the prototype actually does. |
| **The substrate is built.** GPU XPBD on tets with kinematic targets + SDF collisions + Neo-Hookean elasticity + LRA tethers + barycentric surface transfer all already run on a Godot 4.6 RenderingDevice. | Cost is integration, not invention. Wrap-and-bridge fork would be cheaper short-term but creates maintenance debt. |

The proposal that triggered this brief framed the v1 win as "high-fidelity
collision surface for particle-based systems." That framing is right.
Visible softbody / belly inflation / region stiffness modulation are
explicitly out of scope for v1 to keep the slice tight and the
acceptance bar narrow.

---

## Where the prototype lives

Canonical reference: `reference_flesh_deformer_prototype.md` (memory).
Three locations on disk:

- **Active Godot project**: `~/desktop/flesh-deformer/` (Godot 4.6 era,
  modified 2026-04-28)
- **Backup**: `~/desktop/flesh-deformer-backup/`
- **Blender authoring side**: `~/desktop/blender-addon-tetmesh/` —
  ships the FloatTetwild binary for tetrahedralisation, the addon
  Python that generates the `.bin` file the Godot side loads, and a
  test mesh roundtrip (`testmesh.obj` → `testmesh.obj_.msh`)
- **Spec doc**: `~/desktop/flesh-deformer/flesh_deformer_godot_v2.md`
  (44 KB; full system overview, references, scope)
- **Test data**: `~/desktop/flesh-deformer/Ch36_flesh.bin` (730 KB
  precomputed tet + skin barycentrics for the Mannequin character that
  ships with the project)

Compute pipeline at `flesh_deformer/shaders/` — 9 GLSL passes, ~547
LOC total:

| Stage | File | Role |
|---|---|---|
| Targets | `kinematic_targets.glsl` | Per-tick bone-driven kinematic vertex positions |
| Predict | `integrate.glsl` | XPBD predict step |
| Constraint | `solve_volume.glsl` | Per-tet volume preservation |
| Constraint | `solve_kinematic_pin.glsl` | Pin simulated verts to kinematic targets |
| Constraint | `solve_sdf_collision.glsl` | Tet-vs-bone-SDF collision projection |
| Constraint | `solve_lra_tether.glsl` | Long-Range Attachment tethers |
| Constraint | `solve_elasticity.glsl` | Stable Neo-Hookean per-tet (Smith 2018) |
| Finalize | `update_velocity.glsl` | XPBD velocity update from position deltas |
| Render | `surface_transfer.glsl` | Tet positions → render-mesh verts via precomputed barycentric weights |

Load-bearing references baked into the design (preserved verbatim in
the brief's reference table):

- **XPBD**: Macklin, Müller, Chentanez 2016 —
  https://matthias-research.github.io/pages/publications/XPBD.pdf
- **Stable Neo-Hookean**: Smith, Goes, Kim 2018 (Pixar) —
  https://graphics.pixar.com/library/StableElasticity/paper.pdf
- **IQ analytic SDF primitives**: Quilez —
  https://iquilezles.org/articles/distfunctions/

---

## v1 scope — high-fidelity collision surface only

### What v1 does

- **Tet mesh deforms.** GPU XPBD runs at physics tick rate. Kinematic
  targets driven by bone poses + Marionette §15 jiggle bones (the latter
  routed through the same `kinematic_targets.glsl` path, not added on
  top — see Open Question 1).
- **Surface mesh deforms** via `surface_transfer.glsl` reading
  precomputed barycentric weights from the per-hero `.bin` file.
- **TentacleTech contacts against the deformed surface** (B5 type-1
  fork, per-hero opt-in).
- **Bone SDF collision** keeps simulated tet verts from intersecting
  bones, using a converter from `BoneCollisionProfile` to the
  deformer's GPU SDF buffer (decision 4).

### What v1 does NOT do

| Out of scope | Where it lands |
|---|---|
| Multi-material per-tet labels (muscle / fat / skin) | v2 slice B8 |
| Per-tet stiffness anisotropy from `∇(distance-to-bone)` | v2 slice B8 + B9 (gradient from B9's volumetric heat solve) |
| Reverie-routed runtime modulation (belly inflation, region stiffness) | v2 slice B10 |
| Marionette §18 amendment 1 (volumetric heat method for body-interior scalars) | v2 slice B9 |
| Marionette §18 amendment 3 (fiber-axis fallback) | v2 slice B8 |
| Visible softbody jiggle as the primary visual signal | Out of scope by design — Marionette §15 jiggle bones still own post-contact wobble; v1's tet sim is kinematic-pin-dominant so wobble contribution is marginal |
| Multi-hero `.bin` swap at runtime | v1.5 (loader API accepts path at load time; "just call load() per hero" is the v1.5 upgrade) |
| `body_surface_field` (§17 cotan-Laplacian on body surface) | Sibling slice family inside the same `body_field` extension; opens when §15/§16/§17 consumers actually need it |

### v1 visible-quality bar

- Tentacle contact reads cleanly against the surface — no leaks, no
  tunneling, no per-frame popping at seams.
- **Hard regions** (head, ribcage, forearms) feel as rigid as the
  current capsule path. The high pin compliance + Neo-Hookean stiffness
  combine to lock surface tightly to bones in heavily-skinned regions.
- **Soft regions** (belly, glute, throat) show modest surface
  compliance under contact load — a tentacle pressing on the belly
  produces visible local depression that recovers when the tentacle
  pulls away. Amplitude is small; the v1 budget is "visible but
  subtle," not "obvious softbody bounce."
- **No regression** in TT Phase 5 acceptance scenarios on kasumi.

---

## Architecture decisions

### D1. Extension placement: own top-level extension

**`extensions/body_field/`** as a top-level extension, parallel to
TentacleTech, Marionette, Tenticles.

Reasons:
- Consumed by TentacleTech (contact target now) and Tenticles (fluid
  contact later). Neither owns it.
- Marionette drives the kinematic targets but doesn't read deformations
  back.
- Cross-extension rule in repo CLAUDE.md: "Communication via signals /
  resources / nodes / Stimulus Bus / shared clock, never `#include`s."
  Top-level extension fits cleanly via a public `BodyField` node
  accessor publishing tet surface positions.

The name **`body_field`** reserves namespace for both §17 surface field
and §18 volumetric tets as siblings inside one extension. Don't split
into `body_surface_field` + `body_volumetric_field` separate extensions
— they will share the body mesh source, the hero-load bake step, and
(eventually) the cotan-Laplacian factorization machinery.

### D2. Migration approach: port-and-extend

**Port.** Lift compute shaders verbatim; adapt orchestrator for
cosmic-bliss conventions; integrate authoring chain.

What "port" means concretely:
- Compute shaders → `extensions/body_field/shaders/*.glsl`,
  essentially verbatim. Validate `RenderingDevice` API surface vs
  cosmic-bliss's 4.6 build.
- Orchestrator (`flesh_deformer.gd`, 1743 LOC) → `gdscript/runtime/`.
  Initially pure GDScript; promote per-tick dispatch loop to C++ only
  if profiling shows it's hot.
- `flesh_data.gd` `.bin` loader → `gdscript/runtime/`. One-shot at
  hero load, never per-tick — stays GDScript permanently.
- `bone_sdf_primitive.gd` / `bone_sdf_convex.gd` →
  `gdscript/collision/`, repurposed as **converters from
  `BoneCollisionProfile`** to the GPU SDF buffer (see D4), not
  standalone authoring resources.

**Wrap-and-bridge rejected.** Standalone flesh-deformer + cosmic-bliss
interop layer creates maintenance debt: two project trees, two build
chains, two test pipelines, two characters' worth of tuning. The
prototype was developed against the Mannequin character — integrating
as a separate project would never get cosmic-bliss-character-specific
tuning the game actually needs.

**Sample-and-rewrite rejected.** Three weeks of re-deriving what's
already working.

### D3. TentacleTech contact integration: type 1 fork, per-hero opt-in

**Rename TT type 1 from "tentacle particle vs. ragdoll capsule" to
"tentacle particle vs. outer body".** Impl swaps per-hero between
(a) capsule-based (current path) and (b) tet-surface-based (new path).

Not a new contact type — same conceptual contact (tentacle vs. hero
body), different geometry source.

Reasons:
- Friction reciprocal routing (§4.3 type-1) works against either: surface
  verts have a primary skin-weighted bone, so the reciprocal still
  routes to a bone.
- Acceptance-scenario migration is hero-by-hero, not scene-wide.
  Kasumi opts in for `body_field`; older test heroes stay on the
  capsule path until manually flipped.
- BoneCollisionProfile retires as the outer-body collision source
  per-hero, exactly when that hero opts in. Stays for jiggle bone
  harvest (Marionette §15 `non_cascade_bones`) and Jolt-side ragdoll-
  internal physics — neither of which `body_field` touches.

Type 8 ("tentacle particle vs. body tet surface") was considered and
rejected — it would mean two parallel contact paths forever. The
consolidation goal is incompatible with permanent forking.

### D4. BoneCollisionProfile + deformer SDFs: share source of truth

**Share.** Single converter `BoneCollisionProfile → GPU SDF buffer`
runs at hero-bake time. The prototype's `bone_sdf_primitive.gd` and
`bone_sdf_convex.gd` become readers, not authoring resources.

This eliminates the duplicated-authoring tax: one shape source per
bone, consumed by:
- **Jolt** (ragdoll-internal physics: joint limits, bone-vs-bone
  constraints, ground contact via Marionette `build_ragdoll`)
- **`body_field` deformer** (tet-vs-bone collision projection in
  `solve_sdf_collision.glsl`)
- Any future system that needs per-bone shapes

Updating a bone's capsule once propagates everywhere.

### D5. Sequencing

**Parallelizable now, no further gates:**
- B0 extension scaffolding
- B1 `.bin` loader port
- B2 GPU XPBD pipeline port
- B3 BoneCollisionProfile → GPU SDF converter
- B4 `.bin` authoring chain port

These run alongside TentacleTech 5F (canal interior dynamics, in-flight)
and Marionette Slice 3 (SPD `_integrate_forces` population). 5F adds
type-3 contact (canal wall), doesn't gate type-1 fork. Slice 3 doesn't
touch contact at all.

**Strictly after scaffolding lands**: B5 TentacleTech type-1 fork.
Validation gate before flipping default: TT Phase 5 acceptance
scenarios green on kasumi with `body_field` enabled.

**Hard constraint** ("tentacle contact integration cannot land before
TentacleTech 4Q stabilizes") **is already met.** 4Q-fix shipped pre-4R;
Phase 4 fully closed through 4S.3 as of commit `f051493` (2026-05-12).
The coupling pathology that would have been inherited by tentacle-vs-
tet-surface contact under unstable stick-slip is settled.

### D6. Marionette §18 amendment timing

**Apply pass NOW, before any code lands.** Pattern matches prior 5E
canal interior apply pass (`bab13d4`) — one doc commit, then code
starts referencing the amended canonical record.

Specifically:
- Drop this brief into `docs/`.
- Apply pass to `docs/marionette/Marionette_plan.md` §18:
  - Status flip: **STRETCH → ACTIVE**
  - Retitle: "Volumetric tet substrate (`body_field` extension)"
  - Implementation home pointer: link to `body_field` slice plan
  - The three §18 amendments stay queued but move from "stretch goal
    deferred" to "v2+ slices B7–B10 in `body_field`"
- Cross-link §15 jiggle, §16 soft-region, §17 surface field with notes
  on `body_field` consumption shape.

### D7. Slice breakdown — `body_field` Phase B

Per-extension phase numbering, like TentacleTech (phases 1–9), Marionette
(phases 0–15), Tenticles (its own). `body_field` gets Phase B for
"body field" — single letter for brevity, no clash with other extensions.

#### v1 slices (B0–B6)

- **B0 — Extension scaffolding.** `plugin.cfg` + `body_field.gdextension`
  manifest + `gdscript/` + `shaders/` + tests harness. SConstruct
  deferred until C++ surface needed. Build → loads in Godot → empty
  class registered. Mirror Marionette Phase 2.0 pattern.
- **B1 — `flesh_data.gd` + `.bin` loader port.** Hero scene loads tet
  mesh + per-surface-vert barycentric weights. No simulation yet.
  Sanity gizmo: tet wireframe + skin-vert ownership viz. Tests:
  synthetic `.bin` round-trip.
- **B2 — GPU XPBD pipeline port.** RenderingDevice setup, all 9 compute
  shaders, per-tick dispatch. Kinematic-pin-dominant tuning. Test
  scene: kasumi-style mesh, free fall under gravity, verify surface
  tracks bones with marginal wobble. Non-negotiable invariant: tet
  surface positions are snapshotted once per substep boundary, never
  re-read during PBD iteration (mirrors TT §4.5 ragdoll snapshot rule).
- **B3 — BoneCollisionProfile → GPU SDF converter** (D4). Single
  source of truth for per-bone shapes. `solve_sdf_collision.glsl`
  unchanged; converter reshapes `BoneCollisionProfile` entries into
  the GPU buffer the shader already expects.
- **B4 — `.bin` authoring chain port.** Lift
  `~/desktop/blender-addon-tetmesh/flesh_deformer_addon` Python into
  cosmic-bliss tooling. Probably as `blender_bliss` v0.3.0 (canonical
  Blender-side home), adding a new "Body Field" section alongside the
  existing canal-authoring section. FloatTetwild binary lives in
  `tools/bin/` (vendored) or referenced via env var.
- **B5 — TentacleTech type-1 fork** (D3). Per-hero opt-in via a
  `BodyField` node on the hero scene. Friction reciprocal routes to
  surface-vert primary bone. **Acceptance**: TT Phase 5 acceptance
  scenarios green on kasumi-with-`body_field`; slap/rub fidelity in
  soft regions visibly improves vs the capsule path; hard regions feel
  equivalent.
- **B6 — Validation pass + tuning.** Slap/rub scenarios on belly,
  glute, throat on kasumi. Document tuning surface (kinematic_pin
  compliance, elasticity stiffness, LRA tether length). Close v1.

#### v2+ slices (B7–B10, deferred)

Open when the visible-quality bar moves past what v1's kinematic-pin-
dominant tuning produces.

- **B7 — Multi-region tet partitioning.** Soft regions co-exist with
  different stiffness on one tet mesh. Volume primitives + numeric
  stiffness sliders per region — the no-fiddly-authoring rule from
  `feedback_no_fiddly_authoring.md` applies.
- **B8 — Tissue-type classification** from volume primitives +
  tissue-type dropdowns. Implements §18 amendment 3 (per-tet anisotropy
  axis). Requires bone-weight gradient bake from B9.
- **B9 — Volumetric heat method on tets** for body-interior scalars
  (§18 amendment 1: distance-to-bone for tet classification,
  deep-contact sensitivity for Reverie). Cholesky-prefactor on the tet
  Laplacian, same back-substitution pattern as §17 surface case but on
  tet domain.
- **B10 — Reverie modulation API.** Belly inflation, region stiffness
  modulation, fiber direction modulation. Wires Reverie's per-region
  state writes into `body_field`'s runtime tunables.

---

## Open architectural questions

These don't block v1 scaffolding but need resolution before B2 / B5
land. Surface during B2 / B5 prompt drafting.

### Q1. Jiggle bone composition with tet sim

Marionette §15 jiggle bones drive translation-only SPD on a child bone
whose skin weights deform body surface verts. If those surface verts
are now ALSO tet vertices, the jiggle bone's deformation must coexist
with the tet sim.

**Recommended path**: jiggle bone is just another kinematic target.
`kinematic_targets.glsl` reads jiggle bone poses alongside skeletal
bone poses, so the tet vertex follows the jiggle bone exactly. Tet
sim's elasticity + volume preservation then deform surrounding tissue
around the jiggle-driven anchor.

**Alternative** (rejected): jiggle bone applies an additive offset on
top of tet-deformed position. Double-counts deformation; produces
artifacts when both systems try to move the same vert.

Confirm B2 prompt routes jiggle bones through `kinematic_targets.glsl`.

### Q2. Canal interior verts vs. tet mesh

Canal interior verts (`CUSTOM0.r ≥ 1` per TT §6.12) don't have bone
skin weights and are routed through the canal pipeline.

**Recommended path**: FloatTetwild input is **outer body surface only**.
Canal interior invaginations aren't tet-meshed. Canal verts route
through the canal pipeline cleanly. No double-counting.

**Alternative** (rejected): tet mesh covers everything, canal verts
tagged "skip kinematic/tet sim." Extra bookkeeping, no clear benefit.

The Blender-side authoring chain (B4) must filter out canal interior
faces before piping to FloatTetwild. Implementation: read `CUSTOM0` on
the mesh before export, exclude any face all of whose verts have
`CUSTOM0.r ≥ 1`.

### Q3. Tet sim + canal pipeline boundary at orifice rims

A tentacle entering the vagina contacts type-2 (rim particles, TT §6.4),
traverses the canal (type-3, §6.12.6), and may also contact surrounding
belly tissue (type-1 outer body tet surface, post-B5). The three
pipelines must NOT double-count the same physical contact.

**Recommended rule**: type-1 tet surface contacts are **suppressed for
tentacle particles currently in an active `EntryInteraction`**. Matches
the §10.5 capsule-suppression-during-interactions pattern. Documented
in B5 spec.

When the tentacle is partially in (some particles inside the
canal, some outside), only the outside particles see type-1 contact.
The transition is handled per-particle, same as §10.5.

### Q4. Multi-hero `.bin` ownership

Each hero needs its own `.bin`. v1 assumes single hero. Multi-hero is a
v1.5 concern, but the `.bin` loader API should accept the path at load
time (not a hardcoded global) so multi-hero is a "just call load() per
hero" upgrade later.

Decision deferred to B1 implementation; surface the API shape in the B1
prompt.

### Q5. Ragdoll snapshot discipline

Tet surface positions need the same "snapshot once per substep, never
re-read during PBD iteration" rule as the existing §4.5 ragdoll
snapshot. The deformer's compute pipeline runs once per substep,
produces surface positions, and TT consumes them at substep boundary —
this is consistent with the discipline.

**State as a non-negotiable invariant in B2.** Same class of constraint
as the existing snapshot rule. Worth flagging in
`extensions/body_field/CLAUDE.md` (when authored at B0) as a hard
invariant.

---

## What this brief does not do

- **Does not commit to v2+ timing.** B7–B10 open when the visible-quality
  bar moves past what v1's kinematic-pin-dominant tuning produces. No
  promised date.
- **Does not amend `Marionette_plan.md` directly.** The apply pass
  (decision D6) is a separate commit that lands after this brief.
- **Does not specify the `body_field` extension's CLAUDE.md content.**
  That ships as part of the B0 slice; the brief provides the scope and
  invariants the CLAUDE.md will codify.
- **Does not commit to the Stable Neo-Hookean parameter choices** the
  prototype ships with. Tuning is B6's job; the brief specifies that
  tuning must end at "soft regions visibly compliant, hard regions
  rigid, no regression in TT acceptance scenarios."
- **Does not retire BoneCollisionProfile.** It loses one role
  (outer-body collider for tentacle contact, per-hero opt-in) and
  retains two roles (Jolt-side ragdoll shape source, jiggle bone
  harvest via `non_cascade_bones`).

---

## Knock-on effects elsewhere

| Doc / file | What changes |
|---|---|
| `docs/marionette/Marionette_plan.md` §18 | Status STRETCH → ACTIVE. Retitle to "Volumetric tet substrate (`body_field` extension)". Implementation home pointer. The three §18 amendments stay queued as v2+ slices. |
| `docs/marionette/Marionette_plan.md` §15 (jiggle) | Note: jiggle bone integration with `body_field` follows Q1 above — jiggle bones become kinematic targets in the tet sim, not additive offsets. Pre-`body_field` and non-`body_field` heroes keep the current standalone jiggle path. |
| `docs/marionette/Marionette_plan.md` §16 (soft-region) | Note: soft-region cluster particles compose with `body_field` tet substrate when present — clusters can either ride on top of tet-deformed surface verts (additive blend) or absorb into the tet sim itself as additional tet sub-clusters (v2+). v1 doesn't take a position; clusters are independent of `body_field` in v1. |
| `docs/marionette/Marionette_plan.md` §17 (BodySurfaceField) | Note: §17 surface field will live in the same `body_field` extension as §18 volumetric tets, when its consumers (rim authoring, jiggle attachment authoring per §15/§16/§17.5) actually need it. Same extension, sibling slice family. |
| `docs/architecture/TentacleTech_Architecture.md` §4.2 (collision types) | §4.2 type 1 renamed "tentacle particle vs. outer body" with two impl paths (capsule-based / tet-surface-based, per-hero opt-in). The rename lands in B5; canonical-doc edit is part of that slice's PR. |
| `docs/architecture/TentacleTech_Architecture.md` §10.5 (capsule suppression) | Note: when a hero opts in for `body_field`, type-1 contact uses tet surface and "capsule suppression" terminology becomes "tet surface region suppression at active EntryInteractions" — same semantic, different geometry. Update at B5. |
| `extensions/tentacletech/CLAUDE.md` | Adds: `body_field` integration is per-hero opt-in via a `BodyField` node on the hero scene; type-1 contact path forks at solver init based on opt-in state. Same once-per-substep snapshot discipline as the existing ragdoll snapshot. Lands at B5. |
| `extensions/marionette/CLAUDE.md` §15 | Adds: jiggle bones route through `body_field`'s kinematic targets when the hero opts in. Lands at B2 (when the routing first works). |
| `tools/blender/` or `blender_bliss` v0.3.0 | Body field authoring section: load mesh, run FloatTetwild, generate per-surface-vert barycentric weights, export `.bin`. Lands at B4. |
| `docs/pbd_research/findings_obi_synthesis.md` | Note: cosmic-bliss's volumetric tet path follows Macklin XPBD + Smith Neo-Hookean, not Obi-derived. Lands at B2 docs review. |

---

## Apply checklist for top-level Claude

1. ✅ Brief written (this doc).
2. **Apply pass — `Marionette_plan.md` §18.** Status flip, retitle,
   implementation home pointer, v2+ slice plan references B7–B10. Single
   commit alongside cross-references in §15/§16/§17.
3. **Prompt sub-Claude for B0** — extension scaffolding only. Small,
   tight slice. Mirror Marionette Phase 2.0 / 5E prompt shape.
4. **Update memory** — `reference_flesh_deformer_prototype.md` gets a
   pointer to this brief; new `project_body_field_state.md` memory
   tracks the slice progression as B0+ land.

---

## Summary

Port the working GPU XPBD volumetric tet deformer prototype at
`~/desktop/flesh-deformer/` into cosmic-bliss as a new top-level
extension `extensions/body_field/`. v1 ships a high-fidelity collision
surface for particle-based systems (TentacleTech now, Tenticles later),
retiring `BoneCollisionProfile`'s outer-body-collider role per-hero
opt-in. Tet sim is kinematic-pin-dominant — substrate runs, visible
softbody contribution stays small, Marionette §15 jiggle bones still
own the post-contact wobble (now routed through the tet sim as
kinematic targets, not added on top). Marionette §18 promotes from
STRETCH to ACTIVE; its three amendments (volumetric heat method,
kinematic vertex = overwrite, per-tet anisotropy) become v2+ slices
B7–B10 in `body_field`. v1 = B0–B6, parallelizable with TT 5F + Marionette
Slice 3 except for B5 which lands after scaffolding. Hard constraint on
TT 4Q stability is already met. The substrate is built; cost is
integration, not invention.
