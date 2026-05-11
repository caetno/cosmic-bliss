# Findings — Obi softbody particle generation, bone binding, and skinning (2026-05-10)

Companion to `findings_obi_synthesis.md`. That doc covered the Obi PBD solver
internals (constraints, contact handling, friction). This one covers the
**authoring story** — how Obi turns a mesh + skeleton + a few sliders into a
simulating softbody character — and how that maps onto our `BodySurfaceField`
+ volume-primitive plan for Cosmic Bliss tissue authoring.

Source paths (vendored under `pbd_research/Obi/`):
- Blueprint (offline build): `Scripts/Softbody/Blueprints/ObiSoftbodySurfaceBlueprint.cs`
- Actor (runtime): `Scripts/Softbody/Actors/ObiSoftbody.cs`
- Skinner (mesh deform + bone driving): `Scripts/Softbody/Rendering/ObiSoftbodySkinner.cs`
- Authoring UI: `Editor/Softbody/Blueprints/ObiSoftbodySurfaceBlueprintEditor.cs`
- Per-particle stiffness painting: `Editor/Softbody/Blueprints/Properties/ObiBlueprintDeformationResistance.cs`
- Skin-blend painting: `Editor/Softbody/Blueprints/Properties/ObiSoftbodyInfluenceChannel.cs`

---

## 0. Up-front correction

Obi does **not** have muscle/fat layers. Its three "layers" — `Bone`, `Volume`,
`Surface` — are spatial sampling tiers, not biological tissues. Tissue
stiffness variation in Obi is achieved by *painting* per-particle deformation
resistance on top of a uniform sampling. The voxel-sampling + skeleton-binding
machinery is what's directly relevant to our tet-mesh-authoring concern; the
"three layers" framing is a vocabulary hand-off, not a tissue model.

---

## 1. The "three layers" — what they actually are

`ObiSoftbodySurfaceBlueprint.ParticleType` is a flag enum:

```
None     = 0
Bone     = 1<<0   // particles sampled by walking the skeleton tree
Volume   = 1<<1   // particles sampled inside the mesh
Surface  = 1<<2   // particles sampled on the mesh boundary
All      = Bone | Volume | Surface
```

Tags are spatial roles, not material classes. There is no fat / muscle / skin
distinction at the **particle** level. Editor visualization tints them
(`ObiSoftbodySurfaceBlueprintEditor.cs:269`):
- Bone → reddish (0.8, 0.5, 0.5)
- Volume → pink (0.8, 0.7, 0.7)
- Surface → white

A single PBD/shape-matching solver simulates all three together. The "layering"
emerges from the **clustering rules** that connect them, not from per-particle
material parameters.

---

## 2. Authoring surface — what the user actually touches

The whole blueprint inspector (`ObiSoftbodySurfaceBlueprintEditor.cs:57–105`)
is **numeric sliders + dropdowns + one bone reference**. No painting required
to get a working softbody. Specifically:

- `inputMesh` — the skinned mesh to bind to.
- `scale`, `rotation` — TRS applied before sampling.
- `planeProjection` — None / YZ / XZ / XY (2D shapes; otherwise full 3D).
- **Surface sampling**: `mode` (None / Vertices / Voxels) + `resolution` (2..128).
- **Volume sampling**: `mode` (None / Voxels) + `resolution` (2..128).
- **Skeleton sampling**: `skeleton` GameObject + `rootBone` Transform + optional `boneRotation`.
- **Shape analysis**: `shapeResolution` (high-res voxel grid for SDF), `maxAnisotropy` (ellipsoid stretch limit, 1..5), `smoothing` (0..1, post-fit position lerp).

That is the entire required authoring step. Hit **Generate** and the blueprint
is built. **Painting is optional** and only exists on top of the
auto-generated particles, for polish (per-particle stiffness, mass, radius,
skin-blend influence — see §6).

This is the model worth stealing for our tet-mesh-authoring concern: *one mesh
+ numeric sliders + one bone reference; everything spatial is derived, not
authored.*

---

## 3. The pipeline (`ObiSoftbodySurfaceBlueprint.Initialize`)

The build order is fixed (`ObiSoftbodySurfaceBlueprint.cs:144–268`):

1. **Voxelize for shape analysis** at `shapeResolution` (high-res). Build a
   smooth signed-distance field via jump-flooding (`m_DistanceField`). Build a
   `VoxelPathFinder` that does geodesic pathfinding through voxels.
2. **Voxelize for surface sampling** at `surfaceResolution`. Boundary-thinned
   to a single layer.
3. **Voxelize for volume sampling** at `volumeResolution` (only if Volume mode
   != None).
4. **Surface particles**: one particle per boundary voxel center
   (`VoxelSampling`), then projected onto the mesh surface (`ProjectOnMesh`).
   Tagged `Surface`.
5. **Volume particles**: one particle per interior voxel center. Tagged
   `Volume`. (If surface sampling is off, also includes boundary voxels.)
6. **Skeleton particles** (`SkeletonSampling` at line 434): walk bone
   hierarchy breadth-first from `rootBone`. For each bone, place a particle at
   `bone.position`. Then for each child bone, walk the segment and insert
   intermediate particles spaced at one voxel size — so longer bones get more
   particles. Each gets `boneBindPose = bone.worldToLocalMatrix` (snapshot at
   build time). Tagged `Bone`.
7. **Map mesh vertices → particles** (`MapVerticesToParticles`): for each
   particle, find its nearest mesh vertex (used for normals); for each mesh
   vertex, store nearest particle index (`vertexToParticle[]`).
8. **Generate particles** (`GenerateParticles` at line 525): for each
   candidate position:
   - Gather neighborhood voxels in a `2 * voxelSize` box from the high-res
     shape voxelizer.
   - Run **anisotropic ellipsoid fit** (`ObiUtils.GetPointCloudAnisotropy`) —
     Yu/Turk-style PCA on the local SDF neighborhood, clamped by
     `maxAnisotropy`. Output: centroid, orientation quaternion, three
     principal radii.
   - SDF gradient gives the rest-normal; if the gradient is unreliable, fall
     back to mesh vertex normal.
   - Position = `lerp(rawPosition, fittedCentroid, smoothing)`.
   - Particles are intrinsically oriented ellipsoids — not spheres. Thin
     features (fingers, ears, tentacle tips) get elongated particles
     automatically.
9. **Build shape-matching clusters** — see §4.
10. **Build simplices** (deformable triangles) by mapping mesh triangles
    through `vertexToParticle`.
11. **Coloring + batching** of clusters for parallel constraint solving.
12. **Default skinmap**: call `ObiSkinMap.MapParticlesToVertices` with
    `radius = maxVertexParticleDistance * 1.5`, `falloff = 1`,
    `maxInfluences = 4`. This is the per-vertex weighted skin.

---

## 4. Cluster generation — this is where the "binding between layers" lives

Shape-matching clusters are the soft-body's only inter-particle constraint.
Two cluster builders run in sequence:

**`CreateClustersFromVoxels`** (line 650) — for each Surface or Volume
particle, gather neighboring particles in adjacent voxels (face / edge /
vertex neighborhoods), and accept them only if the **geodesic voxel-path
distance** ≤ `sqrt(3) * voxelSize * 1.5`. Uses `m_PathFinder` for the geodesic
check, which is critical: two limbs that touch in space but are geodesically
far through the body (e.g. arm against torso) do not get clustered together.
The allowed neighbor type is parametrized:
- Surface clusters: Surface ↔ Surface only.
- Volume clusters: Volume ↔ {Volume, Surface}.

So Volume particles can pull on Surface particles (skin follows flesh) but
Surface clusters don't include Volume centers as their first members.

**`CreateClustersFromSkeleton`** (line 682) — for each Bone particle, gather
all non-Bone particles within `voxelSize * 0.5` **Euclidean** distance into one
cluster. This is what physically binds bones to the surrounding flesh. The
cluster is anchored to the bone particle (which is kinematic — see §5), so the
cluster's rest shape is dragged with the bone.

A particle ends up in many clusters (one per voxel-neighborhood + one per
nearby bone). Shape matching runs per cluster every solver iteration and
projects member particles toward their rest configuration.

---

## 5. Bone-particle dynamics — kinematic, transform-driven

Bone particles do not simulate. Two pieces of code make this work:

**`ObiSoftbodySkinner.BindBoneParticles`** (line 72): on blueprint load, walk
both the skinned-mesh-renderer bone hierarchy and the blueprint's recorded
skeleton hierarchy in lock-step (matching by name), build a parallel list of
bones present in both. Then **set `invMass = invRotationalMass = 0`** for
every bone particle (line 150). Inverse mass zero in PBD = infinite mass =
immovable by constraints.

**`ObiSoftbodySkinner.Softbody_OnSimulate`** (line 158): every simulation
tick, for each bone particle, compute

```
deformMatrix = solver.worldToLocal * bone.localToWorld * bindPose * boneRotationFix
position     = deformMatrix * restPosition
orientation  = deformMatrix.rotation * restOrientation
```

and **overwrite** `solver.startPositions / endPositions / positions` (and
orientations) for that particle. So bone particles are not physics objects —
they are slaved to the renderer's bone transforms. The shape-matching clusters
around them then drag the flesh particles along during the constraint solve.

That's it. There is no joint, no spring, no constraint between bone-particle
and flesh-particle. **The cluster is the joint.**

---

## 6. Per-particle authoring overlays — where "fat vs muscle" *could* live

Painting tools available in the editor (registered in
`ObiSoftbodySurfaceBlueprintEditor.cs:135–143`):

- **Mass**, **Radius**, **FilterCategory**, **Color** — generic per-particle.
- **DeformationResistance** — written into the per-cluster
  `materialParameters[i*5]` (the shape-matching stiffness coefficient).
- **PlasticYield**, **PlasticCreep**, **PlasticRecovery**, **MaxDeformation**
  — plasticity tuning per cluster.

Per-vertex authoring at the actor level
(`ObiSoftbodySkinner.m_softbodyInfluences`):
- **Softbody influence** (paint per-vertex 0..1) — blends between full
  softbody deformation and the underlying linear-blend-skinned pose. This is
  what lets you keep the face rigid while the belly jiggles.

So Obi's "fat vs muscle" story, to the extent it has one, is: **uniform
particle field + brush-painted stiffness + brush-painted skin blend**. There
is no SDF-based or volume-based stiffness gradient. Anything resembling a
hard-bone-soft-fat gradient is achieved by:
1. Increasing skeleton bone count (more Bone particles → more rigid regions).
2. Painting `DeformationResistance` low on belly/cheeks, high on chest/back.
3. Painting `softbodyInfluence` low on forehead/jaw (= follows skinned bone,
   no sim).

---

## 7. Skinning — multi-particle weighted skin on the mesh

After particle generation, the default skinmap (`CreateDefaultSkinmap` at line
850) calls `ObiSkinMap.MapParticlesToVertices(mesh, blueprint, ..., radius,
falloff, maxInfluences=4, normalize=true)`. For each mesh vertex it stores up
to four (particle, weight) pairs. At render time the vertex is reconstructed
by transforming its bind-pose offset by each influencing particle's current
ellipsoid frame (centroid + orientation), weighted-summed.

`radius = maxVertexParticleDistance * 1.5` is auto-derived from the worst
vertex-to-particle gap during sampling — no manual radius authoring required.
There's also a separate fallback path: standard linear blend skinning to the
mesh's actual skeleton bones, blended in via `softbodyInfluence` per-vertex.

---

## 8. Mapping back to our tet-mesh-authoring concern

The reason this is interesting for our `BodySurfaceField` / soft-region work
isn't the soft-body sim itself — it's the **authoring story**:

| Obi authoring | Our equivalent |
|---|---|
| Drop a mesh, pick a root bone, set 3 resolution sliders | Drop ARP rig, set placement of region nodes in scene |
| Voxelize → SDF → ellipsoid-fit → place particles | Cotan-Laplacian on surface → derive per-vertex skinning weights from volume primitives |
| Walk skeleton, place bone particles | Direct: bones already exist as Skeleton3D bones |
| Cluster by geodesic-voxel-path distance | Cluster by surface geodesic (Laplacian smoothing) |
| Optional brush paint of DeformationResistance | Numeric slider on volume primitive (no painting) |

What Obi gets right that's worth borrowing:
- **Single asset, one-shot bake.** No side resources, no per-vertex painting
  required, no tet authoring. The blueprint is regenerable from inspector
  parameters.
- **Geodesic distance through the body interior** (their `VoxelPathFinder`) —
  prevents cross-body bleed without manual masking. Our `BodySurfaceField`
  plan to use a cotan Laplacian on the mesh achieves the same property on the
  surface; for interior we'd need either an SDF or stick with surface-only.
- **Bone particles are kinematic, dragged by transforms, not solved.** This is
  exactly the model we'd want for any TentacleTech soft-region / Marionette
  jiggle interface — flesh follows bone via cluster constraints, no joint
  authoring.
- **Anisotropic ellipsoidal particles auto-derived from local SDF.** Solves
  the thin-feature problem (lips, finger pads) without bumping global
  resolution. If we ever do volumetric sim, this is the right primitive.

What Obi *doesn't* solve and we'd still have to invent:
- Material classes (fat vs muscle vs gland). Obi only has stiffness as a
  scalar per cluster, painted manually. If we want region-typed tissue, the
  model is **volume primitives in scene → SDF → per-particle classification at
  bake time**. This matches our already-stated "no fiddly authoring" rule.
- Multi-region rest-volume preservation (different fat depots being
  incompressible separately). Obi has one global volume.

The crisp transferable insight: **Obi proves you can ship a production
soft-body authoring story with zero per-vertex painting required, by making
the bake a pure function of (mesh, rig, sliders).** The "Bone / Volume /
Surface" tagging is the right vocabulary, but the gap between Obi's three flat
sampling tiers and a usable fat/muscle distinction is exactly the gap a
`BodySurfaceField` + volume-primitive system is designed to close — and it can
close it without re-introducing per-vertex paint or tet meshes.
