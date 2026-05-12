# BodyField — GPU XPBD volumetric tet substrate for hero body deformation

Read before every coding session. Defines project invariants and style. The phased roadmap lives in `docs/Cosmic_Bliss_Update_2026-05-12-02_flesh_deformer_integration.md` (the integration brief); the architectural placement lives in `docs/marionette/Marionette_plan.md` §18; the full implementation spec is the vendored prototype doc at `docs/body_field/flesh_deformer_v2_legacy.md`.

---

## Project summary

BodyField is a Godot 4.6 extension that simulates flesh deformation on skinned characters using GPU-resident XPBD on a tetrahedral proxy mesh. Bone colliders drive kinematic classification. Free tet vertices simulate elastic flesh under Stable Neo-Hookean elasticity + volume preservation + bone-SDF collision + LRA tethers. Surface deformation transfers to the render mesh as `sim − kinematic_target` deltas via precomputed barycentric weights, composing cleanly with Godot's bone-LBS skinning.

**v1 role**: high-fidelity collision surface for particle-based systems (TentacleTech now, Tenticles fluids later). Substrate runs kinematic-pin-dominant — visible softbody contribution stays small; Marionette §15 jiggle bones still own post-contact wobble, integrated as additional kinematic targets feeding the compute pass (NOT additive on top of tet-deformed positions).

**v2+ extensions** deferred to slices B7–B10: multi-region tet partitioning, tissue-type classification (Muscle/Fat/Gland/Skin/Inert), per-tet stiffness anisotropy from `∇(distance-to-bone)`, volumetric heat method, Reverie modulation API.

Top-level node: `BodyField : Node3D`, placed under the hero scene alongside `Skeleton3D` + `MeshInstance3D` + `PhysicalBoneSimulator3D`.

---

## Architectural docs (read before implementation)

In reading order:

1. **`docs/Cosmic_Bliss_Update_2026-05-12-02_flesh_deformer_integration.md`** (integration brief, commit `3228f8e`) — v1 scope, seven architecture decisions D1–D7, slice plan B0–B6 + B7–B10, five open questions Q1–Q5. The primary reading for "what's in v1 and why."
2. **`docs/marionette/Marionette_plan.md` §18** (commit `94cc0f4`) — canonical architecture-level placement. Where BodyField sits in the project. Sibling slice family to §17 surface field inside the same extension. The primary reading for "what is body_field and where does it sit."
3. **`docs/body_field/flesh_deformer_v2_legacy.md`** (vendored prototype spec, commit `43fb435`) — full implementation spec from the working prototype at `~/desktop/flesh-deformer/`. 13-step implementation sequence (step 0 = delta-application prototype, flagged as highest-risk integration point). Frozen reference; do not edit.

Cross-references that matter:
- TentacleTech `docs/architecture/TentacleTech_Architecture.md` §6.12 — canal interior pipeline; canal interior verts (`CUSTOM0.r ≥ 1`) are excluded from the BodyField tet mesh at bake time (brief Q2).
- TentacleTech `docs/architecture/TentacleTech_Architecture.md` §4.2 type 1 — contact integration target; B5 forks this to "tentacle particle vs. outer body" with per-hero opt-in for BodyField surface vs. bone capsule.
- Marionette `docs/marionette/Marionette_plan.md` §15 — jiggle bones; integrate as additional kinematic targets when BodyField is active (brief Q1).
- Marionette `docs/marionette/Marionette_plan.md` §17 — surface field sibling slice family inside this same extension.

---

## Scope

### In-scope

- GPU XPBD on a tetrahedral proxy mesh of the body interior (Macklin et al. 2016)
- Per-tet Stable Neo-Hookean elasticity (Smith 2018)
- Volume preservation + kinematic pin + bone-SDF collision + LRA tether constraints
- Per-vertex kinematic classification + BFS-depth rigidity, computed at hero load from bone SDFs (no per-tet authoring)
- Bone collider SDFs (sphere / capsule / box analytic primitives per IQ; convex hull half-space intersection) read from `BoneCollisionProfile` via a hero-load converter
- `.bin` file format v2 (magic 'FLSH', Godot Y-up coords, no axis conversion at load)
- Per-render-vert `flesh_influence` painted in Blender as the artist's only painting surface, baked into the `.bin`
- Surface transfer via precomputed barycentric weights, delivering `sim − kinematic_target` deltas to the render mesh
- Delta application via CompositorEffect (preferred) or texture-buffer-in-vertex-shader
- Color-grouped XPBD constraint solve (greedy graph coloring at hero load; tets in a color group solve in parallel without write conflicts)
- Per-hero opt-in via a `BodyField` Node3D on the hero scene
- TentacleTech contact integration as a per-hero opt-in fork of type-1 (B5 slice)

### Out-of-scope (v1)

- Multi-material per-tet labels (Muscle/Fat/Gland/Skin) → v2+ slice B8
- Per-tet stiffness anisotropy from `∇(distance-to-bone)` → v2+ slice B8 (depends on B9)
- Volumetric heat method on tets for body-interior scalars (distance-to-bone, deep-contact sensitivity) → v2+ slice B9
- Fiber-axis fallback for midline tets → v2+ alongside B8
- Reverie-routed runtime modulation (belly inflation, region stiffness) → v2+ slice B10
- Visible softbody jiggle as the primary visual signal — v1 keeps this small; Marionette §15 jiggle bones own post-contact wobble
- Multi-hero runtime `.bin` swap → v1.5 (loader API accepts path; v1.5 is just "call load() per hero")
- §17 surface field (cotan-Laplacian on body surface) — sibling slice family inside this same extension, opens separately when its consumers need it

### Explicitly NOT this extension's concern

- Active ragdoll solving (pose targets → bone motion) → Marionette
- Tentacle PBD physics, orifice rim, canal interior dynamics → TentacleTech
- GPU particles, fluid sim → Tenticles
- Reaction system, emotion states, facial expressions → Reverie
- Jolt-side ragdoll-internal physics (joint limits, bone-vs-bone constraints, ground contact) — unchanged; BodyField sources bone SDFs from the same `BoneCollisionProfile` that Jolt uses but does not replace Jolt

---

## C++ / GDScript split

**Pure-GDScript-for-now** per integration brief D2. The orchestrator + `.bin` loader + bone SDF converter start in GDScript; promotion of the per-tick compute dispatch loop to C++ happens only if profiling shows it's hot. The 9 compute shaders are GLSL, driven via Godot's `RenderingDevice`.

### Active layout

```
extensions/body_field/
├── CLAUDE.md
├── plugin.cfg                        — addon manifest, lifted to addon root on deploy
├── plugin.gd                         — EditorPlugin entry; minimal until editor surface earns it
├── gdscript/                         — flat-copied to game/addons/body_field/ at deploy time
│   ├── runtime/                      — BodyField node + orchestrator + .bin loader
│   ├── resources/                    — Resource subclasses (BodyFieldProfile, etc., when authored)
│   ├── collision/                    — BoneCollisionProfile → GPU SDF buffer converter
│   └── debug/                        — gizmo overlays for tet wireframe + skin-vert ownership
├── shaders/                          — GLSL compute shaders, RenderingDevice-driven
└── tests/                            — run_tests.gd harness; SceneTree pattern per TT 5E
```

### Deferred (until C++ surface earns its place)

- `extensions/body_field/body_field.gdextension` — manifest pointing at compiled `.so`
- `extensions/body_field/SConstruct` — godot-cpp-based build
- `extensions/body_field/src/` — C++ source

When C++ lands (B2 if profiling demands, possibly never), these arrive as a coherent slice together. Until then: pure-GDScript addon, flat-copied to `game/addons/body_field/` by `tools/build.sh`.

**Rule of thumb**: if it runs inside the per-tick compute dispatch and touches per-particle / per-tet state, the shader handles it (GLSL). The CPU side is bake-time setup + per-tick uniform/buffer uploads + dispatch glue. Both stay GDScript until profiled-hot.

---

## Status

Authoritative slice plan: integration brief §"Slice breakdown — `body_field` Phase B" (3228f8e). Per-slice history will land in `PHASE_LOG.md` once B1+ slices ship.

| Slice | State |
|---|---|
| B0 — Extension scaffolding | not yet shipped |
| B1 — `.bin` loader + sanity gizmo | blocked on B0 |
| B2 — GPU XPBD pipeline port | blocked on B1 |
| B3 — `BoneCollisionProfile` → GPU SDF converter | parallel-able after B0 |
| B4 — `.bin` authoring chain (Blender side) | parallel-able after B0 |
| B5 — TentacleTech type-1 fork | blocked on B2 + B3; gated on TT Phase 5 acceptance |
| B6 — Validation pass + tuning | blocked on B5 |
| B7 — Multi-region tet partitioning | v2+; gated on visible-quality bar moving |
| B8 — Tissue-type classification + per-tet anisotropy | v2+; depends on B9 |
| B9 — Volumetric heat method on tets | v2+ |
| B10 — Reverie modulation API | v2+ |

Always re-read the integration brief before starting — this table can drift; the brief is the source of truth.

---

## Workflow

You are a sub-Claude scoped to this extension. The repo's top-level Claude (started in `../..` at the repo root) holds cross-cutting context — architecture, build system, doc consistency, contracts between extensions, integration with Marionette + TentacleTech + Tenticles.

- **Implementation lives here.** You do the GDScript / GLSL / Blender-side work in `extensions/body_field/`, `tools/blender/`, `game/tests/body_field/`.
- **Top-repo reviews and commits.** Sub-Claude does not commit. Hand off uncommitted; top-repo reviews the diff against the slice prompt's acceptance criteria and commits with a properly-framed message.
- **Cross-extension changes go through top-repo.** If a slice surfaces a need to touch `extensions/marionette/`, `extensions/tentacletech/`, or `extensions/tenticles/` — stop and surface. Don't unilaterally cross extension boundaries; the cross-cutting impact needs top-repo review.
- **Brief Q1–Q5 + B-slice gate rules apply.** Q1 (jiggle composition with tet sim), Q2 (canal interior verts vs tet mesh), Q3 (orifice rim contact dedup), Q4 (multi-hero `.bin` ownership), Q5 (ragdoll snapshot discipline) — flagged for B2/B5 resolution. If your slice touches any of these, follow the brief's documented recommendation; if you find yourself wanting to deviate, surface and stop.

---

## Non-negotiable rules

Changes to these require explicit top-repo approval before writing code.

- **Tet substrate covers the outer body only.** Canal interior verts (TT §6.12, `CUSTOM0.r ≥ 1`) are excluded at bake time. They route through TentacleTech's canal pipeline, not through BodyField. Authoring chain (B4) filters canal interior faces before piping the body mesh to FloatTetwild.
- **Bone collider source of truth is `BoneCollisionProfile`.** A single converter at hero load reshapes its entries into the GPU SDF buffer the `solve_sdf_collision.glsl` shader expects. The prototype's standalone `bone_sdf_primitive.gd` / `bone_sdf_convex.gd` files become readers from `BoneCollisionProfile`, not standalone authoring resources.
- **Delta = sim − kinematic_target, NOT sim − rest.** This is load-bearing for clean composition with Godot's bone-LBS skinning. Render mesh receives `bone-LBS + delta × render_influence`. Float-path divergence between the XPBD bone-multiply path and Godot's internal LBS is the failure mode the convention exists to prevent.
- **Tet surface positions snapshotted once per substep, never re-read during constraint iteration.** Same discipline as TentacleTech's §4.5 ragdoll snapshot rule. The deformer's compute pipeline runs once per substep, produces surface positions, and consumers (TT type-1 fork from B5) read them at substep boundary.
- **Jiggle bone integration is via kinematic_targets, not additive offsets.** Marionette §15 jiggle bones feed `kinematic_targets.glsl` as additional kinematic target sources. Adding their offsets on top of tet-deformed positions double-counts deformation and produces artifacts. Per brief Q1.
- **Canal interior contact suppression at active EntryInteractions.** When a tentacle particle is currently inside an active TT `EntryInteraction`, type-1 outer-body contact (against the tet surface, when BodyField is opted in) is suppressed for that particle. Matches the §10.5 capsule-suppression-during-interactions pattern. Per brief Q3.
- **Kinematic vertex = overwrite, not constrain.** Bone-attached tet vertices have their positions written directly from the live bone transform each substep, before any constraint solve. No spring constraints between kinematic and simulated tet vertices; no joint authoring between bone and tet. Per the prototype's `kinematic_targets.glsl` shader. Per Marionette §18 amendment 2 (active in v1 substrate; the prototype already implements this).
- **Color-grouped XPBD solve.** Tets partitioned into color groups via greedy graph coloring at hero load; tets in a group solve in parallel without write conflicts. Don't break this invariant — it's what makes the per-tick solve viable on the GPU.
- **`render_influence` is the artist's only painting surface.** Painted per render vert in Blender as `flesh_influence`, baked into the `.bin`. Controls "how much jiggle reaches the surface" per vertex. No other per-vertex authoring — the rest is derived from volume primitives + numeric sliders + tissue-type dropdowns (the latter at B8+).
- **`.bin` files are version 2 and Godot-space.** Magic 'FLSH', version uint32 = 2, little-endian. Coordinates already in Godot Y-up world space — no axis conversion at load.
- **Hero opt-in is per-hero, not scene-wide.** Per integration brief D3. Heroes without BodyField fall back to the existing capsule-based TT type-1 contact path. BoneCollisionProfile stays live for non-opted-in heroes.

---

## What not to do

- Do not generate Godot test scenes without explicit user confirmation. Even with confirmation, keep them simple: node tree + scripts + a few `@export` numbers. No animation tracks, no `AnimationPlayer`/`AnimationTree` setups, no baked lighting, no multi-resource asset pipelines, no rigged characters beyond what's already in the kasumi hero scene. If anything beyond that seems necessary, ask before creating it.
- Do not use `MeshDataTool` in hot paths.
- Do not use Godot's `SoftBody3D`. Forbidden by repo convention.
- Do not allocate `ArrayMesh` or `ShaderMaterial` per-frame. Allocate once at hero load.
- Do not break the once-per-substep snapshot discipline (see non-negotiables above).
- Do not paint canal interior verts with `flesh_influence` — they're routed through TT §6.12, not BodyField. Painting them silently breaks the routing.
- Do not modify `~/desktop/flesh-deformer/` — that's the prototype source, read-only reference. Only the spec doc was vendored.
- Do not edit `docs/body_field/flesh_deformer_v2_legacy.md` — it's a frozen vendored reference. Edits go to a new design update doc if the design needs to evolve.
- Do not write Reverie modulation hooks before B10. Belly inflation / region stiffness / fiber direction modulation are v2+ slices; pre-wiring them in v1 creates dead-config that B10 has to either honor (wrong) or rip out (wasted work).
- Do not pre-wire C++ scaffolding ahead of profiling demand. The `.gdextension` + SConstruct + `src/` directory earn their place when there's a concrete C++ surface to register, not before.

---

## Build

- One extension: `./tools/build.sh body_field`
- All: `./tools/build_all.sh`
- Output: `extensions/body_field/gdscript/` flat-copied to `game/addons/body_field/` (no `scripts/` subdir, since no SConstruct exists). When C++ lands (if ever), build.sh's mixed-mode path migrates the deploy to a `scripts/` subdir automatically.

Build commands run from repo root.

---

## Testing

- Tests live under `extensions/body_field/tests/` + `game/tests/body_field/` for scene-level integration.
- Run pattern: `godot --headless --quit-after 5 --script /abs/path/to/extensions/body_field/tests/run_tests.gd`.
- The harness pattern is SceneTree-based with `_process` one-shot (mirrors TentacleTech 5E's `test_5e_canal_infrastructure.gd`). Single-test scaffolds for B0; the harness can graduate to the Marionette-style internal-`_test_*`-function-list pattern when the test surface multiplies in B1+.
- Per-slice acceptance criteria live in the slice prompt. Hand-computed numeric tolerances are expected for math-heavy work (mirrors Marionette SPD math slice).
- Synthetic test fixtures (ArrayMesh built in GDScript with CUSTOM0/1/2 attributes) are the load-bearing test surface until the `.bin` authoring chain (B4) lands real test data.

---

## Commit conventions

- Per-slice prefix: `[B0]`, `[B1]`, ..., `[B10]`.
- Type prefix: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`.
- Example: `[B2] feat: GPU XPBD pipeline port — kinematic_targets + integrate + elasticity`.
- Top-repo Claude commits, not sub-Claude. The slice prompt's acceptance criteria are the commit's load-bearing claim.

---

## Red flags that should halt work and escalate

1. Per-frame heap allocations (`Mesh.new()`, `Image.new()`, `Resource.new()` inside `_physics_process` or compute dispatch path).
2. Reading bone transforms during the per-tick constraint iteration (must be snapshotted once at substep boundary).
3. Authoring surface creep: a slice introduces a new per-tet, per-vertex, or per-region authoring requirement that the artist has to touch beyond volume primitives + numeric sliders + `flesh_influence` painting.
4. Cross-extension coupling that doesn't go through a public node accessor or shared Resource (`#include`-equivalent in GDScript = `preload(...)` of internal headers from another extension's path).
5. Editor-side work that should be a separate Tools menu or inspector plugin slipping into the runtime path.
6. C++ scaffolding (SConstruct, `.gdextension`, `src/`) landing without a concrete profiling-demand justification.
7. Canal-interior verts getting tagged with `flesh_influence` or routed through BodyField (they belong to TT §6.12).
8. Jiggle bone integration as additive offset on top of tet-deformed positions instead of as a kinematic target source (brief Q1 invariant).
9. A slice growing past its prompt's stated file count or scope. If the diff is ballooning, surface and stop.

Each indicates an architectural assumption is wrong and needs discussion.

---

## Quick reference

| Concept | Reference |
|---|---|
| Integration brief (v1 scope, decisions, slice plan) | `docs/Cosmic_Bliss_Update_2026-05-12-02_flesh_deformer_integration.md` |
| Architecture-level placement in the project | `docs/marionette/Marionette_plan.md` §18 |
| Full implementation spec (vendored prototype) | `docs/body_field/flesh_deformer_v2_legacy.md` |
| `.bin` file format v2 | legacy spec §".bin File Format", line ~87 |
| 13-step implementation sequence | legacy spec §"Implementation Sequence", line ~1153 |
| Step 0 = delta-application prototype (HIGHEST-RISK) | legacy spec §"Implementation Sequence" step 0; B5 prerequisite |
| Color-grouped XPBD solve | legacy spec §"Build color groups", line ~778 |
| Delta = sim − kinematic_target rationale | legacy spec §"Delta = sim − kinematic target", line ~126 |
| GPU collider struct (112 bytes, std430-safe) | legacy spec §"GPU Collider Struct", line ~152 |
| Kinematic classification at-load algorithm | legacy spec §"Kinematic Classification", line ~644 |
| BFS depth-based rigidity algorithm | legacy spec §"Depth-based rigidity", line ~702 |
| TentacleTech §6.12 canal interior pipeline | `docs/architecture/TentacleTech_Architecture.md` §6.12 |
| TentacleTech §4.2 contact types + §4.5 ragdoll snapshot rule | `docs/architecture/TentacleTech_Architecture.md` §4.2, §4.5 |
| Marionette §15 jiggle bones | `docs/marionette/Marionette_plan.md` §15 |
| Marionette §17 surface field sibling | `docs/marionette/Marionette_plan.md` §17 |
| `BoneCollisionProfile` (Marionette resource, shared SoT) | `extensions/marionette/gdscript/resources/bone_collision_profile.gd` |
| Repo-root build script | `tools/build.sh` (read first 60 lines for layout rules) |
| Prototype source (read-only reference) | `~/desktop/flesh-deformer/` |
