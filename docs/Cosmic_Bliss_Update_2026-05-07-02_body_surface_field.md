# Cosmic Bliss — Design Update 2026-05-07-02 — Body Surface Field

> **Status: applied 2026-05-11 to `docs/marionette/Marionette_plan.md` §17 as the canonical write-up.** Brief retained as changelog. Sub-Claude reads §17 in the plan as the source of truth. Cross-extension banners in TentacleTech §10.4 and Marionette §15 / §16 forward-reference §17. Opens a new cross-cutting system, `BodySurfaceField`, that prefactors the body
> mesh's cotan-Laplacian once at hero load and exposes geodesic-aware
> scalar / vector / weight fields as cheap back-substitutions. The
> system has multiple consumers — appearance decal diffusion and Reverie
> sensitivity are downstream, but the **load-bearing application is
> particle-driven skinning weight derivation**: the user direction
> 2026-05-07 is to author a *vanilla ARP rig with toes* in Blender and
> place all soft-region / orifice rim / jiggle attachments in Godot as
> nodes, with the surface field deriving per-vertex skinning weights
> automatically.
>
> This brief retroactively amends the Marionette §16 soft-region
> spec (drafted earlier today in
> `Cosmic_Bliss_Update_2026-05-07_procedural_audio_and_soft_regions.md`)
> and the TentacleTech §6.1 / §10.4 orifice-rim authoring spec. Both
> amendments reduce authoring surface; neither changes the runtime
> physics behavior.

**Audience: top-level Claude (canonical record). Sub-Claude reads the
architecture / plan docs once these edits are applied.**

---

## TL;DR

A Cholesky-prefactored cotan-Laplacian on the body mesh becomes the substrate for several otherwise-separate problems:

1. **Skinning weight derivation for particle-driven deformation.** Place an attachment node in Godot, pick a host bone, set a falloff. The surface field bakes a smooth per-vertex weight field on the body mesh — geodesic-on-surface, automatically respecting topology (left-thigh node doesn't leak to right thigh). That weight drives a *secondary offset* on top of the bone-LBS skinning.

2. **Geodesic decal diffusion.** Splatted decals (oil, sweat, fluid residue) diffuse over the body surface across ticks via the same prefactored Laplacian — one back-substitution per channel per second is enough. Decals stop wrapping through gaps (under-arm to side, etc.).

3. **Reverie sensitivity field.** Per-region sensitivity becomes "where is the tentacle touching → smooth scalar across the whole body" in one solve. Reverie no longer hand-paints region masks.

4. **Vector-θ baking** (vector heat method). Globally consistent canal `θ` axis registered to anatomical landmarks rather than locally parallel-transported only.

5. **Procedural mesh fairing** (cotan-Laplacian smoothing falls out for free).

Item 1 is the load-bearing one for this brief — it consolidates three currently-separate authoring surfaces (orifice rim Blender weight-painting, jiggle bone Blender authoring, Marionette §16 volume-SDF blend) into a single Godot-side "place node, pick bone" workflow on a vanilla ARP+toes rig. Items 2–5 fall out of the same prefactored infrastructure at near-zero marginal cost.

---

## Why now — the skinning unification

Three systems currently each have their own authoring path for "bone-driven body region with particle-driven secondary deformation":

| System | Currently authored as |
|---|---|
| **Orifice rim** (TentacleTech §6.1, §10.4) | Rim anchor bones in Blender + skin weights painted to anchor names + skinning shader reads live rim particle world positions |
| **Jiggle bones** (Marionette §15) | Jiggle bones in Blender skeleton hierarchy at modeling time + skin weights painted in Blender |
| **Soft-region clusters** (Marionette §16, drafted today) | Volume primitive in Godot + auto-derived `cluster_blend` from volume SDF + nearest-K particle weights |

All three are "place a thing on the body, particles deform that region of the body mesh." The first two require Blender skin-weight painting per region; the third uses an SDF-in-3D blend that approximates geodesic-on-mesh distance with Euclidean distance. Both are structural compromises:

- **Blender weight painting per region** forces every rim, every jiggle bone, every region to be authored at modeling time. Adding a new soft region (left inner thigh next to right inner thigh) requires re-export. The repo memory entry "Jiggle bones must be in the skeleton hierarchy at *modeling time*" captures this exactly.
- **Volume-SDF blend in Euclidean 3D** can wrap through gaps (a capsule on the inner thigh leaks to the front of the thigh through 3D proximity), is not aware of topology (left-side capsule that touches the right side of the body through 3D proximity bleeds to the wrong side), and the boundary is C1 in 3D distance but not C1 along the surface.

The surface-field replaces both with a **single mechanism**: a smooth weight field on the body mesh, geodesic-on-surface, derived once per attachment at bake time, no Blender authoring required.

User direction 2026-05-07: target authoring shape is *vanilla ARP rig with toes* (per Marionette Phase 1) in Blender. Everything region-shaped — soft regions, orifice rim attachments, jiggle attachments, breast / thigh / butt deformation — placed as nodes in Godot with a host-bone reference. The surface field does the per-vertex skinning derivation.

This is a unification, not a feature.

---

## What the surface field is

### The mathematical primitive

A discrete cotan-Laplacian `L` on the body mesh (rest pose) plus its mass matrix `M`. Reference: Crane et al. *The Heat Method for Distance Computation* (2013); Crane CMU 15-458 *Discrete Differential Geometry* notes for the foundational operators.

For each attachment node, "place a heat source at the node's mesh-projected position; let it diffuse for time `t`; normalize." This is one back-substitution against a Cholesky-prefactored `(I − tL)`. The result is a smooth scalar field on every body vertex, falling off geodesically from the source. The diffusion time `t` controls falloff radius — small `t` gives a tight peak, large `t` gives a broad shoulder.

For applications that need a true skinning *weight* (partition-of-unity, locally supported, smooth-everywhere), the more rigorous primitive is **Bounded Biharmonic Weights** (Jacobson, Baran, Popović, Sorkine 2011): solve a constrained quadratic program against the bilaplacian `L M⁻¹ L`. Both primitives use the same prefactored Cholesky; they differ in which linear system is back-substituted.

The implementation choice between heat-method falloff and BBW is a tuning decision that lands during §17.3 below. Heat-method falloff is simpler and probably sufficient for the additive-offset use case; BBW is the principled choice if "sum of weights at each vertex equals 1" matters (e.g., the orifice-rim replace-mode case below).

### The prefactored Laplacian

Built once at hero load, reused for every attachment and every diffusion query:

```
L : sparse SPD matrix, V × V where V = body vertex count (~5k for kasumi)
M : sparse diagonal mass matrix
factor = cholesky(M − t*L)              // for heat method
factor_bb = cholesky(L * M⁻¹ * L)        // for BBW (one factor per use case)
```

For a 5k-vert body the factor is a few MB and builds in under a second on CPU. **The factor is permanent for the lifetime of the hero** — body topology is locked from Blender export and does not change at runtime.

### The vector-field variant (deferred but architectural slot)

The same factorization plus a connection-Laplacian gives the vector heat method (Sharp, Soliman, Crane 2019). Reserved for later — not needed by the skinning unification — but the brief flags it because the same infrastructure supports it for free when canal-θ baking or Reverie tangent-field work needs it.

---

## SurfaceAttachment node hierarchy

```
SurfaceAttachment : Node3D                  # abstract base
├── host_bone: NodePath                     # bone the attachment moves with rigidly
├── falloff_radius: float                   # geodesic radius on the body mesh, in metres
├── blend_mode: enum {ADDITIVE, REPLACE, PARTIAL_REPLACE}
├── bilateral_mask: bool = true             # mask field by host_bone LBS weight (recommended)
├── (baked) mesh_projected_position: Vector3
├── (baked) per_vertex_weight: PackedFloat32Array        # sparse, only verts within falloff
└── (baked) per_vertex_index: PackedInt32Array           # which vertices the weights belong to

# Concrete subclasses

SurfaceSoftRegionAttachment : SurfaceAttachment
├── volume_shape: enum {Sphere, Capsule, Ellipsoid}      # particle spawn scaffold (was the SDF blend in §16)
├── volume_extents: Vector3
├── soft_region_profile: SoftRegionProfile
└── blend_mode = ADDITIVE

SurfaceOrificeRimAttachment : SurfaceAttachment
├── rim_loop_count: int                                  # 1 (default) | 2 (decorated rim) | etc.
├── particles_per_loop: int = 16
├── orifice_profile: OrificeProfile
└── blend_mode = REPLACE                                 # rim particles fully drive rim verts

SurfaceJiggleAttachment : SurfaceAttachment
├── jiggle_profile: JiggleProfile
└── blend_mode = ADDITIVE                                # jiggle is offset on top of bone-LBS

# Future consumers also subclass SurfaceAttachment:
#   SurfaceSensitivityProbe : SurfaceAttachment          # Reverie-side; reads bus, writes sensitivity field
#   SurfaceDecalSource : SurfaceAttachment               # appearance-side; one-shot decal splat
```

### Three blend modes

The mode determines how the per-vertex weight composes with bone-LBS:

**ADDITIVE** (jiggle, soft regions). The body vertex is bone-LBS-skinned as normal; the field weight modulates a *secondary offset* contributed by the attachment's particles:

```glsl
// vertex shader sketch
vec3 lbs_pos = standard_lbs(VERTEX, BONES, WEIGHTS);
vec3 secondary_offset = vec3(0);
for (each attachment a in additive set) {
    if (a.field_weight > 0)
        secondary_offset += a.field_weight * (a.particle_pos - a.particle_rest);
}
VERTEX = lbs_pos + secondary_offset;
```

The bone still drives the rigid-body pose of the region; the particles add local deformation on top. This is the natural model for jiggle (bone's parent bone moves the region, jiggle particle adds offset) and for soft regions (host bone drives rest, cluster particles add deformation under tentacle contact).

**REPLACE** (orifice rim). The rim particles wholly drive the rim vertices; bone-LBS is unused for those verts:

```glsl
vec3 rim_pos = vec3(0);
float rim_total = 0;
for (each rim particle p in attachment) {
    rim_pos += a.weight_to_p * p.world_pos;
    rim_total += a.weight_to_p;
}
VERTEX = rim_pos / rim_total;
```

For replace-mode the weights need to be partition-of-unity per vertex — that's where BBW is more principled than heat-method falloff. Or we accept a per-vertex normalization pass after the back-substitutions.

**PARTIAL_REPLACE** (transition zones). A scalar `replace_strength ∈ [0, 1]` lerp between LBS and particle-driven:

```glsl
VERTEX = mix(lbs_pos, rim_pos / rim_total, a.replace_strength * a.field_weight);
```

For verts on the rim's geodesic shoulder where some bone-LBS contribution still feels natural.

### Bilateral domain mask

A node placed on the left thigh shouldn't influence the right thigh, but if the body mesh is connected (it is — mucosa is part of the same continuous surface per §10) the geodesic field can reach across via the pelvis perineum. Two mask options, in order of preference:

1. **`bilateral_mask = true`** (default): multiply the field weight by the attachment's host-bone LBS weight per vertex. A node attached to UpperLeg.L gets zero contribution to verts that have zero LBS weight to UpperLeg.L. This uses the *existing ARP skinning weights* as a domain mask; no extra authoring.
2. **`falloff_radius`**: hard-cap the geodesic distance. Verts beyond radius `R` get zero weight regardless. Good for tight peaks (small jiggle attachments).

In practice both apply: the falloff_radius bounds storage and computation cost; the bilateral mask cleans up cross-anatomy leakage that the falloff didn't catch.

---

## Bake pipeline

A `BodySurfaceFieldBaker` editor tool runs once per hero. Reads the body mesh + the set of `SurfaceAttachment` children. Writes baked weights back into the attachments (and a side resource for the prefactored Laplacian, kept on the hero's `BodySurfaceField` autoload-singleton-or-component).

```
1. Read body mesh from MeshInstance3D / SkinnedMeshInstance3D
2. Build cotan-Laplacian L and mass matrix M
3. Cholesky factor (M − t*L) for heat-method use case
4. (Optionally) Cholesky factor (L M⁻¹ L) for BBW use case
5. For each SurfaceAttachment a:
     a.mesh_projected_position = closest_point_on_mesh(a.global_position)
     source = delta function at the projection's barycentric position
     field = back_substitute(factor, source)
     if a.bilateral_mask:
         field *= host_bone_lbs_weight_per_vert
     field = clamp_to_radius(field, a.falloff_radius)
     field = normalize(field)
     // sparse store: only verts where field > epsilon
     a.per_vertex_index, a.per_vertex_weight = sparsify(field)
6. Serialize back to attachment resources
```

Bake time on a 5k-vert body with 30 attachments is seconds. No per-frame cost.

The Laplacian factor is itself baked into a side resource (`BodySurfaceFieldFactor`) so the bake doesn't need to rerun on small attachment-only edits — only on body mesh topology changes.

---

## Runtime

Per frame, the body shader reads the attachments' per-vertex baked weights and the attachments' per-frame particle positions:

```
particle positions arrive via RGBA32F data texture
    (same pattern as TentacleTech centerline / canal — no SSBOs)
per-vertex weights live in CUSTOM vertex attributes
    (sparse: 4-8 attachment slots per vertex, indexed)
shader sums the contributions per the blend mode
```

Per-frame texture upload is `total_particles × 16 bytes`; for 30 attachments × 16 particles each that's 8 kB / frame. Trivial.

No per-frame heat-method solve. The surface field is *static structural data*, baked once and consumed forever.

---

## Architectural unification — what changes per system

### Marionette §16 (soft-region clusters) — amended

The §16 spec drafted earlier today already had the right shape (volume primitive + numeric profile + auto-derived blend); the amendment is **swapping the volume-SDF blend for the surface-field blend**. The volume primitive remains, but its role narrows from *both spawning particles and defining vertex blend* to *only spawning particles*. The visual mesh blend comes from the surface field.

Diff:

```
SoftRegionVolume        # was: defines particle lattice AND vertex blend via SDF
                        # now: defines particle lattice ONLY

SoftRegionAttachment    # NEW; subclass of SurfaceAttachment
                        # owns the host_bone reference
                        # owns the falloff_radius / bilateral mask
                        # owns the per-vertex baked field
                        # carries SoftRegionProfile + SoftRegionVolume as children

cluster_blend           # was: smoothstep on volume SDF distance
                        # now: surface-field weight from SurfaceAttachment bake

per-vertex authoring    # was: nearest-K cluster particle indices baked from SDF
                        # now: same nearest-K, but K particles selected by
                        # surface-field weight + cluster particle proximity
```

Authoring contract is unchanged for the artist — still "host bone + volume primitive + numeric profile." The volume gizmo still drives particle placement. Only the *blend math* changes, and the user never touches the blend math.

Boundary smoothness improves: the blend is geodesic-on-mesh-surface (smooth across folds, doesn't wrap around limbs) instead of Euclidean-in-3D-space.

### TentacleTech orifice rim authoring — amended

This is the bigger reduction. Currently per `TentacleTech_Architecture.md` §10.4:

> Rim anchors are bones in the Blender hierarchy. Mesh skin weights are painted from the rim verts to the anchor names. The skinning shader at runtime ignores those bone transforms and reads live rim-particle world positions instead.

The Blender skin-weight painting is a real authoring tax — every orifice loop is a custom paint pass. The amendment retires it:

```
Before                                         After
─────────────────────────────────────          ─────────────────────────────────────
Rim anchor bones in Blender hierarchy          Vanilla ARP+toes only in Blender
Skin weights painted in Blender                No rim weight painting
Anchor bone names matter (binding)             No anchor bones; nodes in Godot
Skinning shader reads particle pos by name     Skinning shader reads particle pos by index from baked field
```

Authoring becomes: in Godot, place a `SurfaceOrificeRimAttachment` at the orifice center, set host_bone to the attached body bone (e.g. JawLower for the mouth), set rim_loop_count and particles_per_loop. The bake derives the per-vertex skinning weight in REPLACE mode. The rim particles' positions are skinned into the body mesh directly via the surface-field weights.

This **does not** change the rim's runtime physics (rim particles still owned by the `Orifice` C++ class with the existing closed-loop XPBD constraints). Only the visual-mesh skinning step changes.

Compatibility note: existing kasumi orifice authoring already has rim anchors in the Blender hierarchy. After this lands, those anchors become redundant; they can be left in the hierarchy as no-op bones (zero-weight) or stripped at re-export. Not load-bearing for ship.

### Marionette jiggle bones — amended

The §15 jiggle-bone section's most painful gotcha:

> Jiggle bones must be in the skeleton hierarchy at *modeling time*. Skin weights are painted to them in Blender during the same pass that paints to body bones. Adding a jiggle bone at runtime does not retroactively skin existing geometry to it.

The amendment retires this entirely. A jiggle "bone" becomes:

```
SurfaceJiggleAttachment           # placed in Godot scene
├── host_bone: NodePath            # parent bone (e.g. Pelvis for a glute)
├── falloff_radius: 0.10           # geodesic radius
├── jiggle_profile: JiggleProfile  # k, d, mass
└── (runtime) virtual_particle: position + velocity
```

The "virtual particle" runs the existing translation-only SPD (later rotational SPD per the §15 v2 plan) toward `host_bone.transform * rest_local_offset`. The body mesh deforms via the baked surface-field weight, additively on top of bone-LBS.

What's removed: the requirement to author the jiggle bone in the Blender skeleton; the requirement to paint skin weights to it in Blender; the requirement that the bone exist at modeling time. What's kept: same SPD math, same JiggleProfile, same authoring-via-numeric-parameters approach. The "where does the bone go" question is now "where do you place the Godot node" — gizmo-edited.

This collapses Marionette §15's "Authoring gotcha (mandatory)" entirely. Adding a glute jiggle to kasumi (who has none authored in Blender) becomes "drop a node in the scene, pick Hip.L as host_bone." No re-export.

### Decal accumulator — geodesic diffusion

Per `docs/Appearance.md`, decals splat into a body-UV-space accumulator and fade by per-channel timer. With the surface field available, decals can also *diffuse* across the body surface tick-by-tick:

```
decal_t+1 = (I − ε L) * decal_t
```

One back-substitution per channel per second is enough. Different `ε` per channel — oil spreads slowly, sweat fast, bruises don't spread but fade. Decals stop wrapping through gaps because the diffusion is geodesic-on-surface.

This is not a new system; it's a one-line addition to the existing decal accumulator. Land when convenient.

### Reverie sensitivity field — future consumer

Reverie's per-region sensitivity is currently implicit (mapped to body areas via §3 / §8.3 area abstraction). With the surface field, a `SurfaceSensitivityProbe` at the contact point produces a smooth per-vertex sensitivity scalar in one solve. Reverie reads it via the bus, decays over time, accumulates from multiple sources by max() or sum.

Land when Reverie's sensitivity work opens. Nothing this brief commits to.

---

## Authoring contract

The user-facing authoring story across all systems collapses to:

1. **Blender:** vanilla ARP rig with toes (per Marionette Phase 1). Body mesh + body skin weights against ARP bones. No orifice rim anchors. No jiggle bones. No soft-region helper bones. Export.

2. **Godot:** under the hero scene, place attachment nodes:
   - `SurfaceOrificeRimAttachment` at each anatomical opening (mouth, anus, vagina, cervix). Pick host_bone, rim_loop_count.
   - `SurfaceJiggleAttachment` for each soft tissue region wanting wobble (breast L/R, glute L/R, jowls, abdomen). Pick host_bone, set radius.
   - `SurfaceSoftRegionAttachment` for each soft region wanting cluster deformation (inner thigh L/R, breast L/R, glute L/R). Pick host_bone, drag a volume primitive, set numeric params.

3. **Run the bake.** Editor tool runs the surface-field bake on hero load (once); produces all per-vertex weights automatically.

4. **Tune.** All parameters are numeric `@export` sliders. No painting, no Resource files authored on the side, no Blender round-trip.

This is the authoring contract that "no fiddly artistic aspects" wants.

---

## Caveats and honest limitations

**1. Mesh topology must be locked at hero load.** The cotan-Laplacian factor is built once and reused. Topology changes (adding / removing verts at runtime) invalidate the factor. The body mesh is already static at runtime per existing rules; this is consistent.

**2. The mesh must be reasonably manifold.** Cotan-Laplacian breaks down on non-manifold edges or near-degenerate triangles. ARP exports are usually fine; flag for the bake-time tool to error visibly on bad triangles rather than producing silently-wrong weights.

**3. The cotan-Laplacian on a *deforming* skinned mesh is approximate.** We bake the factor against the rest pose. Geodesic distances are exact at rest and approximate under stretch. For body surface fields (decal diffusion, sensitivity, jiggle / soft-region skinning) this is the right trade — the alternative (refactor periodically) is expensive and the rest-pose approximation degrades gracefully under typical body deformation. Heat-method papers explicitly cover this case (option (a) — bake once, accept approximation).

**4. Bilateral leakage.** Connected mesh topology can leak field across anatomy (left → right across pelvis perineum). Resolved by `bilateral_mask = true` (multiply by host-bone LBS weight) which uses the existing ARP weights as a domain mask. Both bilateral mask and `falloff_radius` apply by default.

**5. REPLACE-mode partition-of-unity.** Heat-method falloff weights don't naturally sum to 1 across overlapping attachments. For replace-mode (orifice rim) we either (a) post-normalize per vertex, or (b) use Bounded Biharmonic Weights (Jacobson 2011) which solves for partition-of-unity by construction. Both are post-bake math; the choice lands during §17.3.

**6. Per-vertex storage.** Naively 4–8 attachment slots per vertex × (index + weight) = 32–64 bytes per vertex × ~5k verts = 160–320 kB per hero. Stored sparse, the actual cost is far smaller because most attachments touch <500 verts. Easy fit in CUSTOM vertex attributes.

**7. Bake-time build cost on slow hardware.** Cholesky factor of a 5k-vert SPD matrix is sub-second on any current CPU. On low-end target hardware (Steam Deck, mobile Vulkan) it may be a couple of seconds — acceptable as a hero-load one-shot, not acceptable per-frame, which we're not doing.

**8. Heat method numerics — t parameter.** The diffusion time `t` controls falloff scale and is *the* tuning knob. Crane suggests `t = h²` where `h` is mean edge length. Per-attachment `falloff_radius` translates to a per-attachment `t` at bake time, no runtime tuning.

---

## Phase placement — `Body Surface Field` as Phase TT-7 / Marionette-§17

The system spans TentacleTech (orifice rim authoring is owned by TT) and Marionette (jiggle + soft regions are owned by Marionette) and the appearance system (decal diffusion). It is most cleanly placed as a **shared subsystem with two adoption phases** — first the infrastructure, then per-consumer migration.

### Slice §17.1 — `BodySurfaceField` core (infrastructure-only)

Extension home: probably a new top-level extension `extensions/body_surface_field/` since it's cross-cutting (TT, Marionette, appearance all consume it). Alternative: live in the `extensions/shared/` headers per the cross-extension rule. Choose at implementation time.

Deliverables:
- Cotan-Laplacian / mass-matrix builders (sparse, CPU)
- Cholesky factorization + back-substitution (Eigen would be the obvious dependency; otherwise a hand-rolled SimplicialLLT)
- `BodySurfaceFieldFactor` resource (serialized factor)
- `SurfaceAttachment` base node + the three concrete subclasses with empty bake hooks
- `BodySurfaceFieldBaker` editor tool

Acceptance: a single test attachment on a sphere mesh produces a smooth radial field with the expected falloff. Self-contained; no consumer migration.

### Slice §17.2 — Heat-method-falloff vs Bounded-Biharmonic-Weights (decision)

Bench both on a real hero mesh. Pick one for additive-mode (probably heat-method falloff — simpler, sufficient) and one for replace-mode (probably BBW — partition-of-unity by construction). Document the choice.

### Slice §17.3 — Marionette §16 amendment: SurfaceSoftRegionAttachment

Migrate the soft-region cluster spec to use surface-field blend instead of volume-SDF blend. Run the §16.5 end-to-end acceptance (kasumi inner thigh + breast) under the new blend; validate boundary smoothness improves.

### Slice §17.4 — TentacleTech orifice rim authoring amendment

Replace Blender rim anchor weight-painting with `SurfaceOrificeRimAttachment` Godot-side authoring. Migrate kasumi's existing orifices. Run Phase 5 acceptance scenarios; verify rim deformation matches the previous (Blender-painted) baseline within visual tolerance.

### Slice §17.5 — Marionette jiggle amendment: SurfaceJiggleAttachment

Migrate the breast jiggle on kasumi from Blender-bone-with-skin-weights to Godot `SurfaceJiggleAttachment`. Verify the §15 acceptance ("slap and detach, ≥ 0.6 s wobble") still passes. Author glute jiggle on kasumi (impossible before because she has no glute bones in Blender).

### Slice §17.6 — Appearance decal diffusion (appearance-side, not blocking)

Add `(I − ε L)` diffusion step to the decal accumulator's per-tick update. One channel at a time; tune `ε` per channel.

### Phase ordering

`§17.1–§17.2` are infrastructure. They can land in parallel with TentacleTech Phase 4.5 (Oriented Particles) — no interaction with the PBD core. They block:

- Marionette §16 from progressing past §16.1 (resource schema). The §17.3 amendment must land before §16.2–§16.6 to avoid implementing the volume-SDF blend that's about to be retired.
- Beneficially blocks but does not require: TT Phase 5 orifice rim authoring (§17.4 simplifies the authoring pipeline before the Phase 5 acceptance scenarios are exercised). Phase 5 *can* land first with the existing Blender authoring; §17.4 then migrates kasumi. Either order works; if §17 is open before Phase 5 needs to run, prefer doing §17.4 first.

The full §17 is **independent of TentacleTech Phase 4.5**. They can run in parallel.

---

## What this brief does not do

- Does not commit to vector heat method (Sharp/Soliman/Crane 2019). Same factorization infrastructure supports it; opens later when canal-θ baking or Reverie tangent-field work needs it.
- Does not commit to a specific Reverie sensitivity field schema. The `SurfaceSensitivityProbe` slot exists; Reverie consumes it when its own work opens.
- Does not change the runtime physics for any system. Only the *authoring* and *visual mesh skinning* paths change.
- Does not introduce per-frame heat-method solves. All field math is bake-time.

---

## Open questions

**Q1.** Heat-method falloff vs BBW — choose one as default for additive mode? Bench result will decide. Likely heat-method for simplicity.

**Q2.** Sparse vs dense per-vertex weight storage. Probably sparse (4–8 slots per vertex, indexed). Implement at §17.1; benchmark vs dense.

**Q3.** Does the `BodySurfaceField` live as a new top-level extension, or in `extensions/shared/`? Probably new extension with C++ core (Cholesky math is hot in batch but cold per-frame; even GDScript with Eigen bindings would work for the bake step; runtime is just CUSTOMx attribute reads in the shader). Decide at §17.1 implementation.

**Q4.** Compatibility migration for kasumi's existing orifice rim Blender skin weights. Strip at re-export, or leave as no-op zero-weights? Probably strip at re-export when next regenerating, but not load-bearing.

**Q5.** Bilateral mask — should it use the host bone's LBS weight directly, or use `host_bone_weight + neighbors_weight` to allow influence to bleed naturally to anatomically adjacent bones? Probably direct host_bone weight first; revisit if attachment results look too narrow.

---

## Summary

Open `BodySurfaceField` as a new shared infrastructure subsystem. Prefactor the body mesh's cotan-Laplacian once at hero load. Use it to derive smooth, geodesic, per-vertex weight fields from `SurfaceAttachment` nodes placed in Godot. Three concrete attachment types unify previously-separate authoring: orifice rim, jiggle bone, soft region. The user authors a vanilla ARP+toes rig in Blender; everything else is Godot-side node placement plus numeric parameters. Decal diffusion, Reverie sensitivity, and (later) vector-θ baking are downstream consumers of the same prefactored Laplacian. Six slices §17.1–§17.6, runs in parallel with TentacleTech Phase 4.5.
