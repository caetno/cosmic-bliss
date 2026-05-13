# Cosmic Bliss — Design Update 2026-05-11 — Hero skinning stack

> **Status: drafted 2026-05-11, awaiting review.** Locks the vertex-stage
> stack for the hero body shader that lands as part of `BodySurfaceField`
> §17.4. Captures four blocks in one custom spatial vertex shader: DQS
> skinning, Direct Delta Mush smoothing, surface-field secondary offset
> (additive for jiggle/soft, REPLACE-mix for orifice rim), with final
> VERTEX writeout.
>
> Amends `Cosmic_Bliss_Update_2026-05-07-02_body_surface_field.md` §17.4
> (shader integration) and notes the interaction with
> `Cosmic_Bliss_Update_2026-05-10_body_volumetric_tets.md` (tet
> substrate). Does not change the surface-field math, the attachment
> taxonomy, or the bake pipeline. Does fix the *runtime* shader stack
> the bake feeds.
>
> **Audience: top-level Claude (canonical record). Sub-Claude reads
> 05-07-02 + 05-10 + this brief as a unit until §17 merges them into the
> canonical architecture docs.**

---

## TL;DR

The hero body mesh runs through one custom spatial vertex shader with four
blocks, in this order:

```
vertex():
    raw       = DQS(VERTEX_rest, BONES, WEIGHTS, bone_transforms)
    smoothed  = Psi_v * raw                          // Direct Delta Mush (Le & Lewis 2019)
    secondary = sum_attachments(w_i * (p_i - p_rest_i))  // surface-field offset
    VERTEX    = mix(smoothed + secondary,             // ADDITIVE: jiggle, soft regions
                    REPLACE_blend(smoothed, particles),// REPLACE: orifice rim
                    replace_mask)
```

Four decisions land in this brief:

1. **DQS replaces LBS as the base skinning** for the hero body. Authored
   weights are calibrated against DQS from the start; no LBS→DQS swap mid-project.
2. **Direct Delta Mush** (precomputed per-vertex matrix Psi_v) replaces
   classical neighbour-pass DM. Single-pass vertex shader, no compute
   pre-pass, no two-pass render target plumbing.
3. **Surface-field secondary offsets compose after DM**, not before. DM
   smooths the LBS layer only; particle-driven deformation rides on top.
4. **All four blocks in one shader file.** No `SkeletonModifier3D`
   involvement for DQS or DM; those are vertex-stage decisions, not bone-stage.

`SkeletonModifier3D` remains the right home for everything that produces
a transform per bone: Marionette SPD targets, IK composition,
procedural breathing offsets, look-at constraints. It is **not** the
home for any of DQS, DM, jiggle particle drive, orifice rim drive, or
soft-region cluster drive — those are vertex-stage or particle-stage,
not bone-stage.

---

## Why SkeletonModifier3D is the wrong layer for DQS + DM

`SkeletonModifier3D` writes one transform per bone, then Godot's skinning
pass blends those transforms per vertex. DQS and DM both live downstream
of that blend:

- **DQS** replaces the per-vertex matrix blend with a per-vertex dual
  quaternion blend. The bone transforms going in are the same; the
  blending math differs. A skeleton modifier cannot reach the blending
  step — that is fixed by the renderer's skinning code (or by a custom
  vertex shader that overrides it).
- **DM** smooths *vertex positions* against a neighbourhood. There is no
  per-bone operation that produces it; the data domain is the mesh,
  not the skeleton.

Either you keep Godot's default LBS skinning (no DQS, no DM) or you
write a custom spatial vertex shader that takes over skinning entirely.
There is no third path via skeleton modifiers.

---

## The four blocks

### 1. DQS (Dual Quaternion Skinning)

**Replaces LBS for the hero body.** Solves the candy-wrapper twist
collapse at elbows / wrists / knees / shoulders / hips that LBS produces
on >90° twist. Cost is ~20% more vertex ALU than LBS; negligible at 5k
hero verts.

**Implementation.** In the custom `vertex()`:

1. Read `BONE_INDICES`, `BONE_WEIGHTS`.
2. For each of the (typically) 4 influences, fetch the bone's world
   transform from Godot's skeleton built-ins.
3. Convert each transform to a dual quaternion `(q_r, q_d)` where
   `q_r` is the rotation quaternion and `q_d = 0.5 * t * q_r` is the
   dual part encoding translation `t`.
4. Antipodality fix: if `dot(q_r_first, q_r_other) < 0`, negate the
   other's dual quaternion before accumulation.
5. Weighted sum across influences; normalise the resulting `q_r`;
   re-derive translation from `q_d`.
6. Apply to `VERTEX_rest` → `raw_skinned`.

**Weight authoring.** ARP weights are authored against LBS by default.
Painting / validating against DQS from the start is mandatory: DQS
preserves volume on twist, which can produce subtly different
deformation in regions where the LBS-painter compensated for collapse
by inflating weights. The discipline rule: **the authored weight is
the DQS weight. There is no LBS fallback path.**

This decision is intentionally binding. Mid-project LBS→DQS switches
have been a recurring source of "everything subtly looks wrong" in
other projects.

### 2. Direct Delta Mush (DDM, Le & Lewis 2019)

**Replaces classical Delta Mush** which would require neighbour
position reads at runtime — impossible in a single-pass vertex shader,
since vertex shaders cannot see other vertices' in-flight outputs.

**Bake-time computation.** For each vertex `v`, compute a `4×4` matrix
`Psi_v` that captures "how this vertex should smooth given its 1-ring
neighbourhood in rest pose." The math:

1. For each vertex `v` and each of its 1-ring neighbours `n_i`,
   compute the LBS-residual basis at rest.
2. Build a per-vertex covariance `C_v` from the rest-pose neighbour
   offsets weighted by a Gaussian over geodesic distance (k=10 typical
   iterations of cotan-smoothing implicitly captured).
3. `Psi_v = neighbour-average-operator + low-rank correction` per the
   2019 paper §4.

The cotan-Laplacian factorisation is **already prefactored for
§17.1 BodySurfaceField**; the DDM bake reuses it. No new heavy linear
solve.

**Runtime.** Single matrix-vector multiply per vertex per frame:

```
smoothed = Psi_v * raw_skinned
```

Stored as a CUSTOM vertex attribute — 12 floats per vertex (the matrix
is affine; the bottom row is `(0, 0, 0, 1)`), so 48 bytes/vert. For ~5k
hero verts that's 240 kB of vertex attribute storage. Comfortable.

**Visual quality.** Published comparisons put DDM at ~95% of classical
multi-iteration DM, with smoother behaviour around extreme poses
(less "wobble") because the smoothing is precomputed against rest
topology rather than re-applied to the deformed pose each frame.

**Cost.** One `mat4×vec4` per vertex (~28 ALU on modern GPUs). Vertex
attribute fetch is the dominant cost, not the math.

### 3. Surface-field secondary offset

**Unchanged from §17.4** of the 05-07-02 brief. After DM, each
attachment's per-vertex baked weight contributes a particle-position
delta:

**ADDITIVE mode** (jiggle, soft regions, soft nets, touch deformation):

```
secondary = sum over attachments a:
    w_v_a * (a.particle_world_pos - a.particle_rest_world_pos)
VERTEX = smoothed + secondary
```

**REPLACE mode** (orifice rim, normalised across attachments per vertex):

```
rim_pos = sum_a (w_v_a_to_particle_p * p.world_pos) / sum_a (w_v_a_to_particle_p)
VERTEX = mix(smoothed, rim_pos, replace_strength * field_weight)
```

The `replace_strength` × `field_weight` term gives the rim its tight
"opening that follows the rim particles" mix while the surrounding
skin stays on the DM-smoothed LBS layer.

### 4. Final VERTEX writeout

One write per vertex per frame. No further passes.

---

## Pipeline order rationale

**DQS → DM → secondary** (not DM → DQS, not secondary → DM):

- **DQS first** because DM operates on positions, and LBS/DQS
  determines what positions are produced. DM is a smoother on the
  skinning output, not an alternative skinning algorithm.
- **DM before secondary** because:
  - If DM ran after secondary, it would smear particle-driven detail
    (a rim particle's sharp deformation would be averaged into its
    surrounding skin neighbourhood — visually wrong: the rim should
    deform crisply).
  - If DM ran before secondary on the unsmoothed LBS, the smoothing
    target is the wrong domain.
  - Putting DM between skinning and secondary lets DM do its job
    (hide LBS artifacts) without interfering with particle dynamics.
- **Secondary last** because particle drive is the highest-frequency
  spatial detail and the most artistically important deformation
  channel; nothing should smooth or override it.

This is the standard "skin → smooth → cloth/secondary" ordering in
production VFX rigs; we adopt it directly.

---

## Net / cluster primitive — explicitly deferred

The 05-07-02 brief specifies `SurfaceOrificeRimAttachment` (1D loop),
`SurfaceJiggleAttachment` (1 particle), `SurfaceClusterAttachment`
(point cloud). User direction 2026-05-11 raises a fourth primitive
shape — a **net** (2D arrangement of particles) for general touch
deformation on regions like thighs.

**This brief does not specify the net primitive.** The surface-field
shader stack above is topology-agnostic: it consumes a list of
particle positions + per-vertex weights, irrespective of how the
particles are arranged or constrained internally. A future
`SurfaceNetAttachment` slots in at the same vertex-shader layer with
zero shader changes.

**What the net primitive needs spec'd before code lands:**

- Particle topology (regular grid? mesh-aligned? triangulated patch?
  edge-aligned to a UV island?).
- Internal XPBD constraints (distance only? distance + bend? volume?).
- Anchoring back to the host bone (per-particle spring-back to a
  rest position in host-bone frame, like rim loops? or sparser
  pinned-particles-at-boundary model?).
- Tentacle coupling (type-2 contact per net particle, like rim
  particles? or net-mesh-vs-tentacle collision pairs?).

Lands in a separate amendment after §17.3 (orifice rim) ships and
the cluster / jiggle paths are validated. The shader stack here is
forward-compatible.

---

## Performance budget

**Vertex stage, per frame, ~5k hero verts:**

| Block | Per-vertex cost | Aggregate |
|---|---|---|
| DQS (4 influences) | ~80 ALU + 4 bone fetches | well under 0.1 ms on integrated GPU |
| DDM (mat4×vec4 + 1 CUSTOM fetch) | ~28 ALU + 1 attribute fetch | negligible |
| Secondary offset (avg 4 attachments touch ea. vert) | ~16 ALU + 4 particle fetches | ~0.05 ms |
| REPLACE-mix (only for rim-adjacent verts) | ~16 ALU + 4 weighted fetches | negligible (sparse) |

**Storage:**

- `Psi_v` per vertex: 48 B × 5k = 240 kB
- Surface-field weights per vertex (sparse, ~8 slots avg): ~64 B × 5k = 320 kB
- Bone weights / indices: standard, ~32 B × 5k = 160 kB
- Particle position table (live, all attachments): a few hundred floats — fits in a small RGBA32F texture per the 4.6 SSBO restriction (§ARCH "Never").

Total per-hero static data: well under 1 MB.

**Bake-time:**

- Cotan-Laplacian factorisation (already on the §17.1 critical path).
- DDM `Psi_v` bake reuses the factorisation; one sparse linear solve
  per vertex worth of column extraction, batched. Order of seconds for
  a 5k-vert mesh.
- Surface-field weight bake per attachment: one heat-method
  back-substitution. Already specified in §17.1.

Bake-time fits comfortably in the editor-tool "run once per body mesh
variant" workflow.

---

## Interaction with the volumetric tet brief (2026-05-10)

The 05-10 brief moves the load-bearing primitive for *interior*
fields (distance-to-bone, sensitivity from contact) onto a tet mesh.
The *surface* Laplacian stays the right tool for surface-only fields,
including:

- Per-vertex surface-field weights consumed by this shader stack.
- Decal diffusion across the skin surface.
- Surface vector-θ baking.

DDM is a surface-mesh operation (1-ring neighbourhood on the skin
mesh). No tet involvement. The two bricks compose cleanly: tets drive
interior anisotropy and bone-distance-aware deformation upstream of
the skin; this shader runs the skin-vertex stage; surface-field
weights for soft-region clusters etc. are still derived from the
surface Laplacian per §17.1.

If body volumetric tets land later (per 05-10's Phase ordering), the
shader stack here is unaffected. If they ship first, the
ADDITIVE-mode secondary offsets for soft clusters become "tet-vertex
positions skinned to surface verts via the surface-field weights"
rather than "PBD particle positions" — same vertex shader code, same
data layout.

---

## Implementation slicing

Lands as part of §17.4 of the 05-07-02 brief. Recommended sub-slicing:

**§17.4a — DQS baseline.** Custom spatial shader replaces Godot's
default LBS with DQS. No DM, no surface field. Test: visual A/B
against default LBS on extreme twists (kasumi forearm twist 180°,
shoulder roll, hip rotation). Acceptance: no candy-wrapper at any
of those joints.

**§17.4b — DDM layer.** Bake `Psi_v` once per body mesh; shader reads
the CUSTOM attribute and applies. Test: visual smoothing at elbow,
knee, shoulder LBS-residual artifacts. Acceptance: no visible
faceting at the bake-time topology resolution.

**§17.4c — Surface-field secondary (ADDITIVE).** Land jiggle
attachment first (single particle), then soft-region cluster
(point cloud). Tests per §17.4 in the 05-07-02 brief.

**§17.4d — Surface-field secondary (REPLACE — orifice rim).**
Resolves the §17.2 BBW-vs-heat-method decision in code (whichever
wins, REPLACE-mode needs partition-of-unity per vertex). Tests per
§17.4 in the 05-07-02 brief.

**§17.4e — Net primitive.** Deferred to a separate amendment.

---

## Open questions

1. **§17.2 BBW vs heat-method-falloff.** Unresolved from 05-07-02.
   Recommended provisional choice: heat-method-falloff for ADDITIVE
   modes (fast, simple, sufficient); post-normalised heat-method or
   BBW for REPLACE-mode rim (partition-of-unity needed). Final pick
   in §17.4d.

2. **Bone-transform access in custom vertex shader.** Godot 4.6
   exposes skeleton bone transforms via built-ins (texture-fetch by
   bone index). Verify the exact uniform name and conversion path
   before coding §17.4a. Fallback: pass via a `RenderingDevice`
   uniform if the built-in path is awkward.

3. **DDM and morph targets.** If the body mesh has blendshape morph
   targets (it does — Visage face shapes), DDM's `Psi_v` is
   precomputed against the *neutral* rest pose. Morphs deform the
   rest topology slightly. Test whether DDM artifacts at extreme
   morph activation are visible; if so, bake `Psi_v` per morph and
   blend at runtime. Likely fine for body-region morphs (gentle);
   may need per-morph bake for face.

4. **Net primitive spec.** As above, deferred.

---

## Predecessor

This brief amends:

- `Cosmic_Bliss_Update_2026-05-07-02_body_surface_field.md` §17.4
  (shader integration), specifying the vertex-stage stack the bake
  feeds and confirming SkeletonModifier3D is not the host layer.

Does not amend:

- The surface-field math (§17.1).
- The BBW/heat-method choice (§17.2 — still open).
- The attachment taxonomy or bake pipeline.
- The interaction-physics layer (TentacleTech §6 unchanged).

When §17 lands in the canonical architecture doc, this brief's
content folds into the new §10.4 (hero authoring) and §17.4 (shader
integration) sections; this file remains as the changelog entry per
top-level CLAUDE.md conventions.
