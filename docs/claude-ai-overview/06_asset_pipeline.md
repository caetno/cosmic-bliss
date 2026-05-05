# Asset Pipeline

## Modeling

**Blender** is the primary modeling tool. Export via glTF 2.0 (binary `.glb`) into Godot 4.6.

For Kasumi: a humanoid skeleton with the standard Marionette bone profile (`kasumi_humanoid_bone_profile.tres`). Non-human characters would need their own profile; none planned currently.

## Godot import

glTF imports populate a Skeleton3D + meshes + materials. After import:
- The Godot import dialog requires **clicking Reimport** to persist subresource assignments — they live in memory only until then. Easy to lose work to.
- The `bone_map/` property prefix is `bone_map/` (with underscore), not `bonemap/`. Wrong key is silently overwritten.

These are documented Godot gotchas; flagged in the user's auto-memory.

## Marionette authoring loop

1. Import skeletal mesh into Godot
2. Apply `BoneProfile` to the Skeleton3D
3. Run **Calibrate** — fits the profile against the current rig pose, refreshes per-bone masses
4. Apply `BoneCollisionProfile` — generates per-bone collision shapes
5. Mark non-cascade bones (jiggle bones — e.g., breast bones) in `non_cascade_bones` so automatic shape inference skips them; jiggle uses translation-only SPD instead
6. Adjust ROM defaults per joint where defaults don't fit (`rom_defaults.gd` carries per-bone-name defaults)

Calibrate is the user-facing one-click step that propagates rig-specific changes through Marionette's runtime state.

## Tentacle authoring

`TentacleMesh` is a **`PrimitiveMesh` subclass** — Godot draws and skins it like any primitive mesh, but the geometry is generated procedurally from a **base shape** (linear/curve taper, twist) plus a stack of **feature modifiers** added as child resources.

Base-shape parameters: total length, base radius, tip radius, taper curve, twist, seam offset, intrinsic axis, tip cap (rings, pointiness — replaces the legacy single-vertex apex).

Features are subclasses of `TentacleFeature`:
- **KnotFieldFeature** — vertex-kernel radius bumps, Gaussian / Sharp / Asymmetric profile
- **RibsFeature** — vertex-kernel inward grooves, U/V profile
- **WartClusterFeature** — small pyramid bumps seeded by `seed`, density-driven
- **SuckerRowFeature** — disc-cup geometry, OneSide/TwoSide/AllAround/Spiral distribution
- **SpinesFeature** — cones with pitched apex
- **RibbonFeature** — narrow fin strips with width curve + ruffle
- **FinFeature** — broader axial-aligned fins

Each feature contributes:
- **Geometry** (vertex-kernel for radius perturbations; new vertices for warts/spines/fins)
- **Silhouette** (slice 5H, 2026-05-05) — bake into a 2D R32F texture (256 axial × 16 angular) of outward radial perturbation in metres, sampled at contact time

The girth profile is **auto-baked** by `GirthBaker` from the base shape (`rest_girth_texture`, 256-bin R32F). Authoring never touches a `Curve` — the girth is whatever the base shape says it is.

`TentacleMesh` emits `changed` on any feature add/remove/edit, which auto-rebakes both `rest_girth_texture` and `feature_silhouette`.

## Canal authoring (in design)

Canals (vagina, anus, future stomach/uterus) author via:

- **Bone naming convention.** The skeleton has bones like `Vagina_CP_0`, `Vagina_CP_1`, ..., `Vagina_TerminalPin` — `_CP_*` for centerline points, `_TerminalPin` for the closed end. No JSON sidecar.
- **Sacs are canals with `closed_terminal = true`.** Same primitive; the terminal pin closes the topology and the centerline ends there.
- **Curved canals are supported** by curving the bone chain itself — the chain's bending stiffness controls how much it resists tentacle-induced deflection.
- **Per-vert bake** of `(s, θ, rest_radius, normal)` skips standard skin weights. The vertex shader reconstructs the deformed canal position from the centerline particle chain + the 2D `tunnel_state` texture; canal verts don't need GPU skinning at all.

This pipeline lets non-canal verts (skin, breast, hip surface) keep standard skinning while canal verts use the texture-driven path.

`AutoBaker` (extension-side) consumes the bone naming + the rig's pose to derive: spline centerline → per-cell rest_radius profile → per-vert (s, θ, rest_radius, normal) attributes.

## Procedural where possible

The principle: hand-author what's character-defining (skeleton, base mesh, mood preset numbers) and procedurally generate what's repetitive (girth, silhouette, canal interior baking, ring bone weight painting via the future ring weight auto-generator plugin).

The asset team is one person; procedural pipelines pay back fast.

## Where the pipeline could still grow

Ideas surfaced in past discussions; not committed:
- Editor gizmo markers for individual feature centres on tentacles
- Mask-only features (Papillae, Photophore — fragment-shader branch not wired yet, kept inside the GTX 970 budget)
- Tip variants beyond the rounded ellipsoid (Canal, Bulb, Mouth, Flare — extension point left in place; discriminated TipFeature library)
- BaseFeature beyond the current Flush
- LOD / multi-tentacle batching / mesh composition (Phase 9 polish)
- Proper normals at knot-bump peaks (currently radial-only — small lighting error at smooth-profile peaks)

These are good topics if you bring them up, but no decisions yet.
