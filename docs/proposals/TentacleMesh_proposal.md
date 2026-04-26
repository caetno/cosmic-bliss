# Proposal: TentacleMesh primitive

**Status:** ratified 2026-04-26 — promoted to `TentacleTech_Architecture.md` §5.0 + §10.2.
**Supersedes:** the modifier-tree sketch previously in `TentacleTech_Architecture.md` §10.2.

This file is preserved as historical context: *why* the modifier-tree was retired and *how* the §8 open questions were resolved. The architecture doc is the live source of truth — see §5.0 (layer responsibilities), §5.4 (runtime regen policy), §10.2 (TentacleMesh resource + feature catalog + bake contract).

---

## 1. Context

`TentacleTech_Architecture.md` §10.2 originally sketched a procedural generator built from a `TentacleMeshRoot` node with modifier children (Ripple / Knot / Taper / Twist / Flare). That sketch was functional but underspecified: no feature catalog beyond five basic deformers, no decision on geometry-vs-shader tradeoff, no UV / vertex-color contract for downstream shaders, no story for sucker rows or tip variants.

This proposal refined §10.2 into a concrete authoring resource. The point of the doc was to flush out disagreements, resolve §8's open questions, then promote the result.

## 2. Goal (revised at ratification)

A single `@tool`-driven authoring resource — `TentacleMesh` — that bakes at edit time into a static `ArrayMesh` consumed by the Phase-3 vertex-shader spline deform.

**Original draft said "no runtime regeneration."** Revised at ratification: runtime regeneration is *supported* (PrimitiveMesh-style auto-rebuild on property change works in Godot, observed via `CylinderMesh.radial_segments`) but *not relied upon for shipping gameplay*. Default workflow remains edit-time bake → `.tres`. Use cases for runtime mutation: dev tooling, livecoding, inspector dragging during authoring. Physics-driven motion is the spline shader's job, not mesh rebakes.

## 3. Architecture options

**Option A — Monolithic `PrimitiveMesh` subclass.** All features as enabled flags + property groups on one resource. Pro: one file, trivial serialization, minimal type proliferation. Con: property soup at 6+ features; adding a new feature edits a god class.

**Option B (recommended, ratified) — Base resource + `Array[TentacleFeature]`.** `TentacleMesh` owns profile / cross-section. Feature subclasses (`SuckerRowFeature`, `KnotFieldFeature`, `RibbonFeature`, `TipFeature`, …) each contribute verts / tris / masks into the bake. Pro: same modular pattern as DPGPenetrator modifiers; new feature = new subclass, no surgery. Con: more types; in-editor reordering matters because later features can mask earlier ones via vertex color.

Features are `Resource` subclasses (not `Node`-based) — array-of-resources is the canonical Godot pattern for serializable composition.

**Ratified addition:** feature ordering and vertex-color writeback are governed by an explicit rule. Features apply in array order; vertex-color writes are last-writer-wins per channel; a feature whose look depends on another's mask declares it via `_get_required_masks()`, and the bake validates ordering at edit time.

## 4. Base shape (both options shared this; ratified into Option B)

| Field | Notes |
|---|---|
| `length` | meters |
| `base_radius`, `tip_radius` | meters; range guidance 0.005–0.5 |
| `radius_curve : Curve` | overrides linear taper when set |
| `radial_segments`, `length_segments` | density |
| `cross_section` | Circular / Ellipse(a:b) / NGon(n) / Lobed(count, depth) |
| `twist_total` (rad) + optional `twist_curve` | |
| `seam_offset` | radial angle that owns the UV seam — placed dorsal, away from sucker rows |
| `intrinsic_axis` | ratified as `-Z` to match `Tentacle::initialize_chain` (see §6 Q3) |

## 5. Feature catalog (under Option B, ratified)

**Pushback that drove the partition rule:** fine surface detail (papillae, scales, micro-warts) is much cheaper as shader displacement / parallax masked by vertex color. Reserve actual geometry for silhouette-defining features only. Don't pay polygon cost for things you can't tell from the silhouette.

This pushback was promoted into the **partition rule** that now lives at `TentacleTech_Architecture.md` §5.0. Stated once: *"the mesh decides silhouette and authors masks; the fragment shader interprets masks; the vertex shader only deforms — never customizes."*

**Geometry features:** `SuckerRowFeature`, `KnotFieldFeature`, `RibsFeature`, `RibbonFeature`, `SpinesFeature`, `WartClusterFeature` (only when silhouette-meaningful).

**Mask-only features:** `PapillaeFeature`, `PhotophoreFeature` — fragment-shader rendering, but the mesh still authors the mask + per-vertex parameters. The mesh is the single source of truth for *where* every feature is; the shader decides *how it looks*.

Full property tables in architecture doc §10.2.

## 6. Tip & base (ratified)

`TipFeature` (one per mesh): `Pointed`, `Rounded`, `Bulb`, `Canal`, `Flare`, `Mouth`. `BaseFeature`: `Flush` / `Collar` / `Flange`.

Ratified addition for `Canal`: it's a `TipFeature` for Phase 3 — geometry contribution only, with a `CUSTOM0.y` canal-interior binary flag the fragment shader and §6 physics can both read. Interactive internal physics (ovipositor / storage chain) is owned by §6.7–6.9 and reads the flag at runtime; that's a Phase 8 concern, not a mesh authoring one.

## 7. Bake outputs (ratified, with one revision from draft)

The contract is the most important part of the proposal — without it the shader has nothing to mask off.

Draft channel assignment was promoted with one change: **`COLOR.a` was originally double-duty** (tip blend / canal interior flag), which forced shader code to disambiguate by sign or threshold. **Ratified split:** `COLOR.a` = tip blend (smooth gradient, 0 mid-body → 1 at tip apex), `CUSTOM0.y` = canal interior flag (binary). Cheap fix while the contract was still flexible. Final layout in architecture doc §10.2.

`CUSTOM0.x` carries feature ID (uint cast to float, `0` = body, `1+` = feature-specific) so the fragment shader can branch per-feature. `CUSTOM1`/`CUSTOM2` are reserved for future per-feature scalars; the bake header records which channels are in use.

## 8. Open questions — resolved

1. **Architecture: A or B?** → **B**. Property-array of `Resource` subclasses; not nodes.
2. **Canal: `TipFeature` or separate `Penetrable`?** → `TipFeature` for Phase 3 (geometry + flag). Interactive internal physics deferred to Phase 8 §6.7–6.9.
3. **Intrinsic axis?** → **`-Z`**. Matches `Tentacle::initialize_chain`. The DPG memory-note `forward = (0,1,0)` is from Unity-derived legacy; intentionally not carried over.
4. **Material slots?** → **Single material with shader branching** for Phase 3. Vertex masks + feature ID drive the branch. Multi-slot review deferred to Phase 9.
5. **Old §10.2 modifiers?** → **Retire and fold in.** Taper / Twist / Flare → base shape properties. Ripple → `RibsFeature`. Knot → `KnotFieldFeature`. No standalone `*Modifier` subclasses survive.

## 9. Non-goals (revised)

- ~~Runtime mesh regeneration. Bake is edit-time only.~~ **Revised:** runtime regeneration is supported but not relied on for shipping gameplay. (See §2.)
- Animating mesh-shape parameters at runtime as the path to motion. Spline deform handles motion; mesh shape is normally static post-bake. (Inspector dragging at edit time *does* rebake — that's the supported runtime path.)
- LOD generation — defer to Phase 9 polish.

## 10. Outcome

§3–§7 of this proposal (with the §8 resolutions and the §2 / §7 reconciliations) were promoted into `TentacleTech_Architecture.md` §10.2 on 2026-04-26. The partition rule (§5 pushback restated as an invariant) became `TentacleTech_Architecture.md` §5.0. The runtime-regen policy became §5.4 closing paragraph.

Phase-3 sub-step B implementation tasks for the next sub-Claude:
- Base shape generator (`TentacleMesh.gd` + bake pipeline)
- Bake-output contract + masks (channel writes, validators)
- One feature subclass end-to-end: **`SuckerRowFeature`** (highest-value test case — exercises geometry, UV1, vertex color, side-placement logic, seam validation)

Tip variants and remaining features land in subsequent batches.
