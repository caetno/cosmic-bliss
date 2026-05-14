# BodyField — kinematic-only tet proxy for hero body fidelity (v1)

Read before every coding session. Defines project invariants and style. The phased roadmap lives in the three-doc stack: `docs/Cosmic_Bliss_Update_2026-05-12-02_flesh_deformer_integration.md` (extension placement, migration approach, slice plan), `docs/Cosmic_Bliss_Update_2026-05-13_body_field_v1_kinematic_only.md` (v1 scope reduction), and `docs/Cosmic_Bliss_Update_2026-05-14_body_field_optionality_and_dispatch.md` (hard-optional invariant + dispatch redesign + `.bin` v3). The architectural placement at project level lives in `docs/marionette/Marionette_plan.md` §18; the vendored prototype spec at `docs/body_field/flesh_deformer_v2_legacy.md` is **v1.5+ reference**, not v1.

---

## Project summary

BodyField is a Godot 4.6 extension that provides a kinematically-skinned tetrahedral proxy mesh as a higher-fidelity collision surface for the hero body. In v1 the proxy runs **parallel to the render mesh, not upstream of it** — render fidelity stays with the existing DQS + Direct Delta Mush + surface-field-offset stack (per `Cosmic_Bliss_Update_2026-05-11_hero_skinning_stack.md`); the tet proxy is invisible to the player and consumed only by TentacleTech contact dispatch.

**v1 = kinematic-only.** Tet vertices are skinned from bones at physics-tick rate using one compute pass (`kinematic_targets.glsl`). No XPBD predict/correct, no Stable Neo-Hookean, no LRA tethers, no SDF collision inside the substrate, no surface_transfer to render mesh, no compositor-effect delta. The remaining 8 prototype compute shaders stay on the shelf, ported only if v1.5 opens (see Status table below).

**v1 role**: high-fidelity contact surface for TentacleTech where capsules visibly fail (belly, glute, throat, breast, torso). Hands and feet stay on `BoneCollisionProfile` capsules — small bones with fine articulation are exactly where the proxy underperforms capsules; the proxy plays to the opposite strength.

**Hard invariant (project CLAUDE.md "Cross-extension rules"): BodyField is a fidelity upgrade, not a dependency.** No extension may require it. Every consumer must have a tested fallback path that runs when the hero scene has no `BodyField` node. The kasumi-without-body_field smoke test gates body_field-touching PRs. This invariant is load-bearing for the whole extension's design — every mechanism in this CLAUDE.md must preserve it.

**v1.5 (conditional, gated on B6 validation)**: port the remaining 7 sim shaders + `surface_transfer.glsl`. Opens only if soft regions need real compliance under contact load that v1 kinematic + Marionette §15 jiggle bones can't deliver.

**v2+ (B7–B10)**: multi-region tet partitioning, tissue-type classification, volumetric heat method, Reverie modulation API. Deferred.

Top-level node: `BodyField : Node3D`, placed under the hero scene alongside `Skeleton3D` + `MeshInstance3D` + `PhysicalBoneSimulator3D`.

---

## Architectural docs (read before implementation)

In reading order — the three update docs form a stack; read all three before touching code:

1. **`docs/Cosmic_Bliss_Update_2026-05-12-02_flesh_deformer_integration.md`** — extension placement (D1), migration approach (D2: port-and-extend), original v1 framing (now overridden by 05-13/05-14 on v1 scope and dispatch — kept as the v1.5+ reference for the full XPBD path).
2. **`docs/Cosmic_Bliss_Update_2026-05-13_body_field_v1_kinematic_only.md`** — v1 scope reduction. Kinematic-only; tet proxy parallel to render mesh; 8 of 9 prototype shaders deferred. Extremities mask at authoring time.
3. **`docs/Cosmic_Bliss_Update_2026-05-14_body_field_optionality_and_dispatch.md`** — hard-optional invariant; dispatch redesign (collision-layer partition + `BodyField::receive_external_impulse` + 4S.3 surface-tag material composition); `.bin` v3 layout; B6 kasumi-without-body_field acceptance gate.
4. **`docs/marionette/Marionette_plan.md` §18** — architecture-level placement. BodyField is the home for §17 surface field (sibling slice family) and §18 volumetric tets. Note: §18 prose may still describe XPBD v1 until the 05-14 apply pass lands; trust 05-13/05-14 over §18 in case of conflict.
5. **`docs/body_field/flesh_deformer_v2_legacy.md`** — vendored prototype spec. **Reference for v1.5+ only.** The 13-step implementation sequence, color-grouped XPBD solve, delta-application via CompositorEffect, `sim − kinematic_target` delta convention — all v1.5+ territory. Do not implement against this spec for v1. Frozen reference; do not edit.

Cross-references that matter:
- TentacleTech `docs/architecture/TentacleTech_Architecture.md` §4.2 — type-1 contact ("tentacle particle vs. outer body"). 05-14 §3.1 settles dispatch via collision-layer partition (`LAYER_BODY_PROXY | LAYER_BODY_CAPSULES_DETAIL | LAYER_BODY_CAPSULES_FULL`), not per-particle region enum. Pending apply pass on §4.2; trust 05-14 over §4.2 wording.
- TentacleTech `docs/architecture/TentacleTech_Architecture.md` §4.5 — body-body snapshot discipline ("once per substep, never per PBD iteration"). BodyField writes tet positions once per substep at substep boundary; consumers read at the boundary. Pending apply pass on §4.5; trust 05-14 §7.8 wording.
- TentacleTech `docs/architecture/TentacleTech_Architecture.md` §6.12 — canal interior pipeline. Canal interior verts (`CUSTOM0.r ≥ 1`) are excluded from the BodyField tet mesh at bake time. Authoring chain (B4) filters them out before piping to FloatTetwild.
- TentacleTech `docs/architecture/TentacleTech_Architecture.md` §10.5 — contact suppression during active EntryInteractions. When the tentacle particle's probe hit the proxy and the particle is inside an active EI, suppress the contact (same semantic as capsule suppression, dispatched per hit body).
- Marionette `docs/marionette/Marionette_plan.md` §15 — jiggle bones. In v1, jiggle stays on the render-mesh additive-offset path and does NOT feed BodyField. v1.5 may optionally route jiggle through `kinematic_targets`, but the render-mesh path stays live as the fallback.
- Marionette `docs/marionette/Marionette_plan.md` §17 — surface field; sibling slice family inside this extension, opens when its consumers need it. Pre-§17 manual-authoring paths remain live as the no-body_field fallback.
- Marionette `extensions/marionette/gdscript/resources/bone_collision_profile.gd` — capsule authoring resource. Body_field-present heroes set its active layer set to `DETAIL` (hands/feet only); body_field-absent heroes use `FULL` (entire skeleton). Coordinated at hero-init.

---

## Scope

### In-scope (v1)

- **One compute pass: `kinematic_targets.glsl`.** Reads bone transforms + per-tet-vert skin weights from the `.bin`, writes tet vertex positions in Godot world space. Runs once per substep at the substep boundary, never mid-PBD-iteration.
- **`.bin` v3 loader.** Carries tet mesh + tet skin indices + tet skin weights + (optional) per-face region material data. Version-gated; v2 rejected at load.
- **Tet skin weights bake.** Boundary tet verts inherit weights from the render-mesh body mesh (verts coincident with body mesh per the FloatTetwild input rule). Interior tet verts get closest-bone-distance LBS at bake time.
- **Collision-layer registration.** The tet proxy registers as a single body (e.g. `AnimatableBody3D`) on `LAYER_BODY_PROXY` at hero load. TentacleTech queries against `LAYER_BODY_PROXY | LAYER_BODY_CAPSULES_* | LAYER_WORLD` unconditionally; body_field's presence is observed by which layers are populated.
- **`BodyField::receive_external_impulse(world_point, impulse, ps)`** — public C++ method (when C++ lands) or GDScript method (until then) called by TentacleTech's reciprocal path when the hit body is tagged as a BodyField proxy. Looks up the nearest tet, samples the weighted bones, redistributes the impulse to per-bone Jolt bodies as `impulse * w_b`. The body_field-absent fallback is TentacleTech's existing direct-`body_apply_impulse` path on the capsule's RID — preserved.
- **Per-region material composition via 4S.3 `TentacleSurfaceTag`.** When per-region material data is authored in the `.bin`, body_field exposes it through the same tag mechanism TentacleTech uses for tentacle surface tags. Composition at contact time uses the existing TT path; no new TT-side composition logic.
- **Extremities mask at authoring time.** Hand and foot faces are excluded from the FloatTetwild input. The mask is authored in Blender (a per-face region tag, scheme to be defined at B4). TentacleTech then naturally contacts capsule bones at the extremities via `LAYER_BODY_CAPSULES_DETAIL`.
- **`BoneCollisionProfile` active-layer-set switching.** Coordinated with Marionette: profile-side flag selects `DETAIL` (body_field present) or `FULL` (body_field absent) at hero init.
- **Per-hero opt-in.** A hero with no `BodyField` node falls through to the existing capsule path bit-for-bit. The kasumi-without-body_field smoke test runs the TT Phase 5 acceptance suite without BodyField and asserts identical results to the pre-body_field baseline.
- **Debug gizmo** — tet wireframe + skin-vert ownership viz. Pull-style debug per the cross-extension debug rule; pre-allocated `ImmediateMesh` reused per frame (no per-frame allocation).

### Out-of-scope for v1 (gated as v1.5 conditional)

The 8 prototype compute shaders remain on the shelf, ready to port additively:

- `integrate.glsl`, `solve_volume.glsl`, `solve_kinematic_pin.glsl`, `solve_sdf_collision.glsl`, `solve_lra_tether.glsl`, `solve_elasticity.glsl`, `update_velocity.glsl` — full XPBD pipeline
- `surface_transfer.glsl` — barycentric transfer of tet positions to render mesh
- `BoneCollisionProfile → GPU SDF` converter — only consumed by `solve_sdf_collision.glsl`, so deferred with it
- Color-grouped XPBD solve, Stable Neo-Hookean elasticity, LRA tethers, kinematic-pin compliance tuning
- CompositorEffect-based delta application or texture-buffer vertex-shader delta path
- Per-vertex `render_influence` / `flesh_influence` painting (the consumer is `surface_transfer.glsl`, which is v1.5+)

These open only if B6 validation finds soft-region compliance under contact load (belly/glute/throat depression under tentacle pressure) is needed. v1.5 is purely additive over v1 *for runtime architecture* — TentacleTech still contacts the tet proxy; only the source of proxy-vertex positions changes from "pure skinning" to "skinning + simulated delta." Note: v1.5 *will* change render-mesh ownership — once `surface_transfer.glsl` runs, the tet proxy starts driving render. The render-mesh-parallel invariant is v1-only.

### Out-of-scope (v2+)

- Multi-material per-tet labels (Muscle/Fat/Gland/Skin) → v2+ slice B8
- Per-tet stiffness anisotropy from `∇(distance-to-bone)` → v2+ slice B8
- Volumetric heat method on tets → v2+ slice B9
- Fiber-axis fallback for midline tets → v2+ alongside B8
- Reverie-routed runtime modulation (belly inflation, region stiffness, fiber direction) → v2+ slice B10
- §17 surface field (cotan-Laplacian on body surface) — sibling slice family inside this same extension, opens separately when its consumers need it

### Explicitly NOT this extension's concern

- Active ragdoll solving (pose targets → bone motion) → Marionette
- Tentacle PBD physics, orifice rim, canal interior dynamics → TentacleTech
- GPU particles, fluid sim → Tenticles
- Reaction system, emotion states, facial expressions → Reverie
- Jolt-side ragdoll-internal physics (joint limits, bone-vs-bone constraints, ground contact) — unchanged; body_field does not touch Jolt's bone-shape consumption. In v1.5, when `solve_sdf_collision.glsl` lands, body_field reads `BoneCollisionProfile` via a new converter (D4 contract); in v1 it reads nothing from `BoneCollisionProfile`.
- Skinning of the render mesh — DQS + DDM + surface-field offsets per `Cosmic_Bliss_Update_2026-05-11_hero_skinning_stack.md`. v1 body_field does not touch the render mesh.

---

## C++ / GDScript split

**Pure-GDScript-for-now** per integration brief D2. The orchestrator + `.bin` loader start in GDScript; the `kinematic_targets.glsl` dispatch glue is GDScript driving `RenderingDevice`. Promotion to C++ happens only if profiling shows the dispatch loop or the impulse-re-routing path is hot — neither is expected to be hot in v1.

`BodyField::receive_external_impulse` is conceptually a C++ method (the path is called from TentacleTech's tick), but for v1 it lives in GDScript on the `BodyField` Node3D, called via the public method on the node. If profiling demands, lift to C++ in a coherent slice with the rest.

### Active layout

```
extensions/body_field/
├── CLAUDE.md
├── plugin.cfg                        — addon manifest, lifted to addon root on deploy
├── plugin.gd                         — EditorPlugin entry; minimal until editor surface earns it
├── gdscript/                         — flat-copied to game/addons/body_field/ at deploy time
│   ├── runtime/                      — BodyField node + orchestrator + .bin v3 loader + impulse re-routing
│   ├── resources/                    — Resource subclasses (BodyFieldProfile, etc., when authored)
│   └── debug/                        — gizmo overlays for tet wireframe + skin-vert ownership
├── shaders/                          — GLSL compute shaders (v1 = kinematic_targets.glsl only)
└── tests/                            — run_tests.gd harness; SceneTree pattern per TT 5E
```

### Deferred (until C++ surface earns its place)

- `extensions/body_field/body_field.gdextension` — manifest pointing at compiled `.so`
- `extensions/body_field/SConstruct` — godot-cpp-based build
- `extensions/body_field/src/` — C++ source

When C++ lands (only if profiling demands), these arrive as a coherent slice together. Until then: pure-GDScript addon, flat-copied to `game/addons/body_field/` by `tools/build.sh`.

**Rule of thumb**: if it runs inside the per-substep compute dispatch and touches per-particle / per-tet state, the shader handles it (GLSL). The CPU side is bake-time setup + per-substep uniform/buffer uploads + dispatch glue. Both stay GDScript until profiled-hot.

---

## Status

Authoritative slice plan: 05-13 §"Revised slice breakdown — `body_field` Phase B" + 05-14 §3 dispatch mechanisms. Per-slice history in `PHASE_LOG.md` once B1+ slices ship.

| Slice | State |
|---|---|
| B0 — Extension scaffolding | landed (plugin.cfg, plugin.gd, GDScript skeleton, tests harness) |
| B1 — `.bin` v3 loader + sanity gizmo | next; v3 layout per 05-14 §6 |
| B2 — `kinematic_targets.glsl` dispatch + tet skin weights bake | parallel-able after B1 |
| B3 — Collision-layer registration + `BodyField::receive_external_impulse` + 4S.3 surface-tag exposure | parallel-able after B1; coordinated with TT B5 |
| B4 — `.bin` authoring chain (Blender side, vendored to `tools/blender/body_field/`) + extremities mask + per-region material authoring | parallel-able after B1 |
| B5 — TentacleTech type-1 fork against layer-partitioned bodies | TT-side slice, coordinated; this extension provides `receive_external_impulse` and per-region tags |
| B6 — Validation pass + kasumi-without-body_field smoke test | blocked on B5; gates v1 close and decides whether v1.5 opens |
| B5.5 — XPBD compute pipeline port (7 sim shaders) | **conditional** on B6 finding soft-region compliance needed |
| B5.6 — `surface_transfer.glsl` + render-mesh integration | **conditional**; landing this changes the render-mesh-parallel invariant |
| B5.7 — XPBD tuning (pin compliance, NH stiffness, LRA tether length) | **conditional** |
| B3.5 — `BoneCollisionProfile → GPU SDF` converter | **conditional** with B5.5 (consumer is `solve_sdf_collision.glsl`) |
| B7 — Multi-region tet partitioning | v2+; gated on visible-quality bar moving |
| B8 — Tissue-type classification + per-tet anisotropy | v2+; depends on B9 |
| B9 — Volumetric heat method on tets | v2+ |
| B10 — Reverie modulation API | v2+ |

Always re-read the three-doc stack (05-12-02 → 05-13 → 05-14) before starting — this table can drift; the docs are the source of truth.

---

## Workflow

You are a sub-Claude scoped to this extension. The repo's top-level Claude (started in `../..` at the repo root) holds cross-cutting context — architecture, build system, doc consistency, contracts between extensions, integration with Marionette + TentacleTech + Tenticles.

- **Implementation lives here.** You do the GDScript / GLSL / Blender-side work in `extensions/body_field/`, `tools/blender/body_field/`, `game/tests/body_field/`.
- **Top-repo reviews and commits.** Sub-Claude does not commit. Hand off uncommitted; top-repo reviews the diff against the slice prompt's acceptance criteria and commits with a properly-framed message.
- **Cross-extension changes go through top-repo.** If a slice surfaces a need to touch `extensions/marionette/`, `extensions/tentacletech/`, or `extensions/tenticles/` — stop and surface. Don't unilaterally cross extension boundaries; the cross-cutting impact needs top-repo review.
- **The hard-optional invariant gates every slice.** If a slice you're working on would introduce a body_field-required code path in another extension, stop and surface. The kasumi-without-body_field smoke test must remain green after every body_field-touching change.

---

## Non-negotiable rules

Changes to these require explicit top-repo approval before writing code.

- **BodyField is a fidelity upgrade, not a dependency.** Every consumer must have a tested fallback path that runs with no `BodyField` node in the hero scene. The kasumi-without-body_field smoke test (B6 acceptance + per-PR gate) is the verification mechanism. If a slice you're implementing makes another extension require body_field, stop and surface — this is the top-level invariant.
- **Tet proxy runs parallel to the render mesh in v1.** Render mesh keeps its DQS + DDM + surface-field-offset stack from 05-11 entirely. The tet proxy is invisible to the player; its only consumer is TentacleTech contact dispatch. No `surface_transfer.glsl`, no compositor-effect delta, no driving of render-mesh verts. This invariant retires in v1.5 if/when surface_transfer ships.
- **Tet substrate covers the outer body only.** Canal interior verts (TT §6.12, `CUSTOM0.r ≥ 1`) are excluded at bake time. Authoring chain (B4) filters canal interior faces before piping the body mesh to FloatTetwild.
- **Extremities (hands + feet) are excluded from the tet proxy.** Per 05-13, hand/foot faces are masked out at authoring time. TentacleTech contacts capsule bones at the extremities via `LAYER_BODY_CAPSULES_DETAIL`. The mask is authored per-face in Blender (scheme defined at B4).
- **Friction reciprocal goes through `BodyField::receive_external_impulse`.** When the tet proxy receives an impulse from TentacleTech, body_field redistributes it to the skin-weighted bones at the contact point as `impulse * w_b` per influencing bone. Per-bone impulses go to the Jolt-side bone bodies via `body_apply_impulse`. Do **not** apply impulses directly to the tet body — that's a no-op for ragdoll motion and silently breaks §4.3 "tentacle drags hero" feel.
- **Tet positions snapshotted once per substep, never re-read during constraint iteration.** Body-body discipline (renamed from "ragdoll snapshot" in 05-14 §7.8). v1 has no iteration, so this is trivially satisfied for the writer; consumers (TentacleTech) read at the substep boundary. Dispatch ordering: body_field's kinematic-targets pass must run *before* TentacleTech's per-substep probe within the same physics tick. Coordinated through node ordering or explicit `_physics_process` priority.
- **Bone collider source of truth is `BoneCollisionProfile`.** v1 reads nothing from it; v1.5's SDF converter (B3.5) will read it as the single source of truth shared with Jolt. Don't pre-wire reads in v1 — they'd be dead until v1.5.
- **`.bin` files are version 3.** Magic 'FLSH', version uint32 = 3, little-endian. Layout per 05-14 §6: tet mesh + tet skin indices/weights + render-vert barycentric weights + (optional) per-face region material data. Coordinates already in Godot Y-up world space — no axis conversion at load. Reader rejects `version != 3`. v2 files require re-bake.
- **Per-hero opt-in is observed by node presence.** A hero with a `BodyField` node opts in; a hero without it falls through to the capsule path. Coordinated at hero-init with `BoneCollisionProfile`'s active layer set (`DETAIL` vs `FULL`).
- **Per-region material composition uses TentacleTech's existing 4S.3 `TentacleSurfaceTag` mechanism.** Body_field exposes tags through the same path TT uses for tentacle surface tags. No new TT-side composition logic.

The following non-negotiables apply **only to v1.5+** when the gated slices open — listed so they're visible while implementing v1, but do not pre-wire any of them:

- v1.5: Delta = sim − kinematic_target, NOT sim − rest. Load-bearing for v1.5 composition with bone-LBS. (See legacy prototype spec.)
- v1.5: Color-grouped XPBD solve. Tets partitioned into color groups at hero load.
- v1.5: Kinematic vertex = overwrite, not constrain. Bone-attached tet verts written directly from live bone transform each substep, before constraint solve. (v1 has no constraint solve, so the "before" is trivially satisfied; v1.5 preserves the ordering.)
- v1.5: Jiggle bone integration. Optionally route jiggle through `kinematic_targets.glsl` *in addition to* the render-mesh additive-offset path. The render-mesh path stays live in either case as the no-body_field fallback. Brief Q1 recommendation applies; do not double-count.

---

## What not to do

- **Do not generate Godot test scenes without explicit user confirmation.** Even with confirmation, keep them simple: node tree + scripts + a few `@export` numbers. No animation tracks, no `AnimationPlayer`/`AnimationTree` setups, no baked lighting, no multi-resource asset pipelines, no rigged characters beyond what's already in the kasumi hero scene. If anything beyond that seems necessary, ask before creating it.
- **Do not implement the XPBD pipeline in v1.** The 8 deferred shaders are gated behind B6 validation. Pre-porting them is dead code that complicates v1's narrow acceptance.
- **Do not wire `surface_transfer.glsl` in v1.** The tet proxy must not drive render mesh in v1. If you find a slice tempting you to, stop and surface.
- **Do not require body_field anywhere outside this extension.** No `preload("res://addons/body_field/...")` from another extension's code without a `has_node("BodyField")`-guarded fallback path.
- **Do not paint or author `render_influence` / `flesh_influence` in v1.** Its consumer (`surface_transfer.glsl`) doesn't run in v1. v1 .bin format reserves the slot but the artist doesn't paint it. The "only painting surface" claim from 05-12-02 is v1.5+ only.
- **Do not allocate `ArrayMesh` or `ShaderMaterial` per-frame.** Allocate once at hero load. Same rule applies to `ImmediateMesh` in debug gizmos — pre-allocate once, mutate per frame.
- **Do not use `MeshDataTool` in hot paths.**
- **Do not use Godot's `SoftBody3D`.** Forbidden by repo convention.
- **Do not break the once-per-substep snapshot discipline.** Even though v1's kinematic_targets pass is non-iterative, dispatch ordering relative to TentacleTech's per-substep probe must place body_field's write before TT's read.
- **Do not paint canal interior verts with anything destined for body_field.** They're routed through TT §6.12, not body_field.
- **Do not modify `~/desktop/flesh-deformer/`.** That's the prototype source, read-only reference. Only the spec doc was vendored.
- **Do not edit `docs/body_field/flesh_deformer_v2_legacy.md`** — frozen vendored reference. Edits go to a new design update doc.
- **Do not write Reverie modulation hooks before B10.** Pre-wiring creates dead-config that B10 has to honor (wrong) or rip out (wasted work).
- **Do not pre-wire C++ scaffolding ahead of profiling demand.** The `.gdextension` + SConstruct + `src/` directory earn their place when there's a concrete C++ surface to register, not before.
- **Do not couple body_field to Marionette's `body_rhythm_phase` or anything else on the shared clock.** Body_field has no rhythmic component in v1.

---

## Build

- One extension: `./tools/build.sh body_field`
- All: `./tools/build_all.sh`
- Output: `extensions/body_field/gdscript/` flat-copied to `game/addons/body_field/` (no `scripts/` subdir while there's no SConstruct).

Build commands run from repo root.

---

## Testing

- Tests live under `extensions/body_field/tests/` + `game/tests/body_field/` for scene-level integration.
- Run pattern: `godot --headless --quit-after 5 --script /abs/path/to/extensions/body_field/tests/run_tests.gd`.
- The harness pattern is SceneTree-based with `_process` one-shot (mirrors TentacleTech 5E's `test_5e_canal_infrastructure.gd`).
- **Per-slice acceptance criteria live in the slice prompt.** Hand-computed numeric tolerances are expected for math-heavy work.
- **B6 acceptance includes the kasumi-without-body_field regression test.** Run the TT Phase 5 acceptance scenario suite on kasumi twice (with `BodyField` node, without `BodyField` node) and assert run #2 is bit-for-bit equivalent to the pre-body_field baseline under deterministic seeded scenarios. This test gates merges, not just B6 close-out.
- Synthetic test fixtures (ArrayMesh built in GDScript with tet weights as test data) are the load-bearing surface until B4 lands real `.bin` v3 data.

---

## Commit conventions

- Per-slice prefix: `[B0]`, `[B1]`, ..., `[B10]`. Conditional slices: `[B5.5]`, `[B5.6]`, `[B5.7]`, `[B3.5]`.
- Type prefix: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`.
- Example: `[B2] feat: kinematic_targets dispatch + tet skin weights upload`.
- Top-repo Claude commits, not sub-Claude. The slice prompt's acceptance criteria are the commit's load-bearing claim.

---

## Red flags that should halt work and escalate

1. A slice introduces a body_field requirement in another extension (violates the hard-optional invariant).
2. The kasumi-without-body_field smoke test breaks.
3. Per-frame heap allocations (`Mesh.new()`, `Image.new()`, `Resource.new()` inside `_physics_process` or compute dispatch path).
4. Reading bone transforms from inside a constraint-solve callback (Jolt `_integrate_forces`, PBD inner loop). Snapshot at substep boundary instead.
5. A slice tempts you to wire `surface_transfer.glsl` or any of the deferred 7 sim shaders before B6 validation has opened v1.5.
6. A slice tempts you to drive the render mesh from tet positions in v1 (the parallel-paths invariant).
7. Authoring surface creep: a slice introduces a new per-tet, per-vertex, or per-region authoring requirement that the artist has to touch beyond what 05-13/05-14 specified (boundary inheritance + interior closest-bone + extremities mask + optional per-region material).
8. Cross-extension coupling that doesn't go through a public node accessor or shared Resource. `preload(...)` of internal headers from another extension's path is the forbidden pattern.
9. Editor-side work that should be a separate Tools menu or inspector plugin slipping into the runtime path.
10. C++ scaffolding (SConstruct, `.gdextension`, `src/`) landing without a concrete profiling-demand justification.
11. Canal-interior verts getting routed through body_field (they belong to TT §6.12).
12. A slice growing past its prompt's stated file count or scope. If the diff is ballooning, surface and stop.
13. Pre-wiring Reverie modulation channels, color-grouped solve, Stable Neo-Hookean elasticity, or the BoneCollisionProfile→SDF converter in v1.
14. Applying a TentacleTech impulse directly to the tet body's RID instead of routing through `BodyField::receive_external_impulse` (silently breaks §4.3 reciprocal routing).

Each indicates an architectural assumption is wrong and needs discussion.

---

## Quick reference

| Concept | Reference |
|---|---|
| v1 scope reduction (kinematic-only) | `docs/Cosmic_Bliss_Update_2026-05-13_body_field_v1_kinematic_only.md` |
| Hard-optional invariant + dispatch redesign + `.bin` v3 | `docs/Cosmic_Bliss_Update_2026-05-14_body_field_optionality_and_dispatch.md` |
| Original integration brief (placement, migration, v1.5+ reference) | `docs/Cosmic_Bliss_Update_2026-05-12-02_flesh_deformer_integration.md` |
| Architecture-level placement in the project | `docs/marionette/Marionette_plan.md` §18 |
| Prototype spec (v1.5+ reference, frozen) | `docs/body_field/flesh_deformer_v2_legacy.md` |
| `.bin` file format v3 | 05-14 §6 (`tet_skin_indices`, `tet_skin_weights`, optional per-region material slots) |
| Collision-layer partition | 05-14 §3.1 (`LAYER_BODY_PROXY` / `_CAPSULES_DETAIL` / `_CAPSULES_FULL`) |
| Impulse re-routing API | 05-14 §3.2 (`BodyField::receive_external_impulse(world_point, impulse, ps)`) |
| Per-region material composition via 4S.3 surface tags | 05-14 §3.3 |
| kasumi-without-body_field smoke test | 05-14 §5 |
| Apply-pass roadmap (Marionette + TT canonical doc edits) | 05-14 §7 |
| TentacleTech §4.2 / §4.5 / §10.5 (pending apply) | `docs/architecture/TentacleTech_Architecture.md` |
| TentacleTech §6.12 canal interior pipeline | `docs/architecture/TentacleTech_Architecture.md` §6.12 |
| Hero skinning stack (DQS + DDM + surface-field offsets) | `docs/Cosmic_Bliss_Update_2026-05-11_hero_skinning_stack.md` |
| Marionette §15 jiggle bones (pending apply) | `docs/marionette/Marionette_plan.md` §15 |
| Marionette §17 surface field sibling (pending apply) | `docs/marionette/Marionette_plan.md` §17 |
| `BoneCollisionProfile` (Marionette resource, shared SoT for v1.5+ SDFs) | `extensions/marionette/gdscript/resources/bone_collision_profile.gd` |
| Repo-root build script | `tools/build.sh` (read first 60 lines for layout rules) |
| Prototype source (read-only reference) | `~/desktop/flesh-deformer/` |
