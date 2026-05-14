# Cosmic Bliss — Design Update 2026-05-14 — body_field optionality + dispatch redesign

> **Status: drafted 2026-05-14.** Codifies `body_field` as a hard-optional
> fidelity extension at top-level project CLAUDE.md (new bullet under
> "Cross-extension rules"), and replaces the per-region dispatch design
> from `Cosmic_Bliss_Update_2026-05-13_body_field_v1_kinematic_only.md`
> with one that is actually implementable against TentacleTech's
> existing probe architecture and that preserves the no-body_field
> path bit-for-bit. Amends `Cosmic_Bliss_Update_2026-05-12-02_flesh_deformer_integration.md`
> (D3) and `Cosmic_Bliss_Update_2026-05-13_body_field_v1_kinematic_only.md`
> (§"Two parallel paths" + §"Extremities mask" dispatch claims). Read
> the three docs as a stack: 05-12-02 (placement + migration model),
> 05-13 (v1 scope reduction), 05-14 (this brief — optionality invariant
> + dispatch correction).
>
> **Audience: top-level Claude (canonical record). Sub-Claude opening
> the `body_field` supervisor must read 05-12-02 → 05-13 → 05-14 → the
> extension CLAUDE.md (which the apply pass will rewrite against this
> stack) before touching code.**

---

## TL;DR

1. **`body_field` is a fidelity upgrade. Hard invariant.** No extension
   may require it. Every consumer must have a tested fallback path that
   runs when the hero scene has no `BodyField` node. Codified in
   project CLAUDE.md under "Cross-extension rules" as a new bullet.
   Promotes the "per-hero opt-in" language from 05-13 to a top-level
   structural rule.

2. **05-13's "per-particle, per-region dispatch" was unimplementable
   against current TT.** Two specific holes: (a) TT can't classify a
   particle by nearest-bone region *before* the probe runs — the probe
   returns which body was hit, so any region keying is post-hoc; (b)
   friction reciprocal against a single tet-body RID doesn't route to
   bones (the §4.3 "tentacle drags hero" feel silently breaks).

3. **Replacement: three orthogonal mechanisms, each naturally
   fallback-clean.**
   - **Collision-layer partition** — proxy on layer X, capsule bones on
     layer Y, TT queries against `X | Y`. body_field-absent → layer X
     empty → capsule-only path, identical to today.
   - **body_field-side impulse re-routing** — when the tet body
     receives an impulse, body_field redistributes it to the
     skin-weighted bones at the hit point. New C++ method on
     `BodyField`. body_field-absent → no proxy body exists → TT's
     existing capsule path applies impulses directly to bones as today.
   - **Per-region material composition via existing 4S.3
     `TentacleSurfaceTag`** — proxy carries a per-region tag (μ,
     compliance, contact stiffness); TT composes at contact time using
     the same composition path it already uses for tentacle-surface
     tags. body_field-absent → no proxy tag → tentacle's authored
     default μ applies, identical to today.

4. **New B6 acceptance criterion: kasumi-without-body_field smoke
   test** must produce identical behavior to the pre-body_field
   baseline (modulo intentional changes from concurrent briefs).
   Becomes a gate test for any body_field-touching PR.

5. **Apply pass expanded.** Marionette §15/§16/§17/§18 prose must
   phrase body_field references as "when present, X; when absent, Y."
   TentacleTech §4.2/§4.5/§10.5 must reflect the new dispatch
   mechanism and the layer-partition fallback. Body_field supervisor
   CLAUDE.md gets a complete rewrite against the merged 05-12-02 +
   05-13 + 05-14 stack.

---

## 1. The hard invariant

**Project CLAUDE.md edit (this brief lands it):**

> `body_field` is a fidelity upgrade, not a dependency. No extension
> may require `body_field` for correct function. Every body_field
> consumer must have a tested fallback path that runs when the hero
> scene has no `BodyField` node — i.e. TentacleTech contact falls back
> to `BoneCollisionProfile` capsules, Marionette §15 jiggle stays on
> the render-mesh additive-offset path, Marionette §17 consumers keep
> their pre-§17 manual-authoring path, Reverie modulation channels
> that target body_field-only fields are no-ops. The
> kasumi-without-body_field smoke test gates body_field-touching PRs.

**Why this is a stronger statement than "per-hero opt-in":**

"Opt-in" frames body_field as a binary configuration choice on a
per-hero basis but leaves open the possibility that other extensions
grow features whose existence assumes body_field is present somewhere
in the project. The hard invariant closes that loophole: no extension
may evolve in a direction that *only* works because body_field exists.
If a feature genuinely needs the substrate (e.g. tet-driven softbody
deformation in v1.5), it ships as an *additional* mode on top of an
existing standalone path, never as a replacement.

The cost is one extra path per consumer. The benefit is that
body_field can be removed, reverted, swapped, or simply skipped per
hero (or per project, or per platform — body_field is GPU-heavy and a
low-end target may want to skip it entirely) without cascading
breakage.

---

## 2. Why 05-13's per-region dispatch was wrong

The flaw is best surfaced from `extensions/tentacletech/src/collision/environment_probe.h:53-70`
and `extensions/tentacletech/src/solver/tentacle.cpp:289-419`. TT
issues one sphere `get_rest_info` per particle. The probe **returns**
`hit_object_id` / `hit_rid` of whatever it overlaps. There is no
pre-probe step where TT decides "this particle is near a hand bone, so
query capsule layer; that particle is near torso, so query proxy
layer." 05-13's claim that dispatch is "a flat per-bone enum, set at
hero load. No per-tick branching beyond a single integer compare" was
true *after* the hit body is known, but the brief implied it as the
gating mechanism *before* the query — which is not how TT's probe
works.

Concretely impossible paths from 05-13:

- **Two parallel probes (proxy on mask X, capsules on Y).** Godot's
  `PhysicsDirectSpaceState3D::collide_shape` mask is per-query, not
  per-position. Issuing two queries per particle doubles probe cost
  and creates a "which result wins" ordering problem.
- **Post-probe filter that re-issues on miss.** Pathological worst
  case: every particle's first probe misses, every particle re-probes
  → 2× cost. Worse, the re-probe semantic is unclear when the first
  hit was on the "wrong" layer (proxy hit for a wrist particle, do we
  re-probe against capsule and discard the proxy hit?).
- **Authoring-time per-particle layer partition.** Particles drift
  along the chain — a particle near the wrist this tick is near the
  elbow next tick. Static partition fights this; dynamic re-partition
  per tick is exactly the per-region dispatch we were trying to avoid.

And the friction reciprocal:
`extensions/tentacletech/src/solver/tentacle.cpp:255-285` calls
`ps->body_apply_impulse(c.hit_rid[k], impulse, offset)` against
whichever RID the probe returned. When that RID is the tet body's
single `StaticBody3D` / `AnimatableBody3D`, the impulse goes to a body
that has no Marionette bone underneath it as a direct child. The
§4.3-promised "tentacle drags hero's bone" effect silently
disappears. 05-12-02 §D3 asserted "surface verts have a primary
skin-weighted bone, so the reciprocal still routes to a bone" but
specified no mechanism by which the impulse on the tet body's RID
reaches that bone.

---

## 3. The replacement: three orthogonal mechanisms

Each holds independently. Combined they reproduce 05-13's intent
(proxy where soft regions matter, capsules where articulation matters,
per-region material on the proxy) without the implementability
problems.

### 3.1 Collision-layer partition

Layer assignments authored once per hero:

| Body | Collision layer | Mask seen by TT particle |
|---|---|---|
| Tet proxy (body_field, when present) | `LAYER_BODY_PROXY` | yes |
| Capsule bones (hands, feet) authored by `BoneCollisionProfile` | `LAYER_BODY_CAPSULES_DETAIL` | yes |
| Capsule bones (torso, limbs, head) when body_field is **absent** | `LAYER_BODY_CAPSULES_FULL` | yes |
| Floor / world | `LAYER_WORLD` | yes (already today) |

The hero's `BoneCollisionProfile` writes capsules into either
`_DETAIL` or `_FULL` depending on whether a `BodyField` node is in
the scene. The switch is one boolean at hero-init time:

```
if hero.has_node("BodyField"):
    profile.activate_layer_set(DETAIL)   # hands/feet only
else:
    profile.activate_layer_set(FULL)     # entire skeleton, as today
```

TT's per-particle probe queries against
`LAYER_BODY_PROXY | LAYER_BODY_CAPSULES_DETAIL | LAYER_BODY_CAPSULES_FULL | LAYER_WORLD`
unconditionally. Whatever's present on the relevant layers gets hit.
No per-particle dispatch table; no region enum at runtime; no
pre-probe classification.

**Fallback behavior**: body_field absent → `LAYER_BODY_PROXY` empty,
`_DETAIL` empty, `_FULL` populated → TT's probe hits the same
capsules it does today. Bit-for-bit identical.

**Edge case — extremities mask.** Per 05-13, hands/feet are excluded
from the tet proxy at authoring time, so when body_field is present
TT contacts capsules at the extremities and the proxy elsewhere. The
layer partition handles this naturally — extremities live on
`_DETAIL`, proxy lives on `_PROXY`, both visible to TT.

### 3.2 body_field-side impulse re-routing

When TT applies an impulse to the tet body's RID, body_field
intercepts the impulse at the contact point and redistributes it to
the skin-weighted bones at that point. New C++ method on `BodyField`:

```cpp
// BodyField.cpp
void BodyField::receive_external_impulse(
    Vector3 world_point,         // contact location
    Vector3 impulse,              // J in world space
    PhysicsDirectBodyState3D *ps  // for body_apply_impulse on the bones
);
```

Implementation: at hero-load time, body_field builds a per-tet
*bone-weight* lookup (the same closest-bone-LBS bake that 05-13 §"tet
skin weights" specifies for kinematic positioning — reused, not
re-derived). At impulse time, body_field finds the nearest tet,
samples the weighted bones, and issues N `body_apply_impulse` calls to
the per-bone Jolt bodies (which still exist — Jolt's ragdoll-internal
physics path is independent of TT contact and continues to consume
`BoneCollisionProfile` per the unchanged D4 long-term rule). Per-bone
impulse magnitude = `impulse * w_b`, applied at the same world point.

**Integration point with TT**: TT's existing
`ps->body_apply_impulse(c.hit_rid[k], ...)` call site
(`tentacle.cpp:255-285`) gains a per-tag check — if the hit body's
metadata names a `BodyField` node, route through
`receive_external_impulse`; otherwise direct-apply as today. The
metadata is set at hero-init when body_field registers its tet body's
RID with a per-body tag (existing mechanism, no new API).

**Fallback behavior**: body_field absent → no tet body exists → TT's
existing `body_apply_impulse` direct-call applies. Bit-for-bit
identical to today.

### 3.3 Per-region material composition via 4S.3 TentacleSurfaceTag

The 4S.3 surface tag mechanism
(`extensions/tentacletech/gdscript/collision/tentacle_surface_tag.gd`)
already supports per-surface μ / compliance / contact stiffness
composition with the tentacle's authored defaults. The tet proxy
becomes one consumer of this mechanism: at hero-load body_field
populates per-tet-face tags from the authored per-region data (belly
= soft μ + low stiffness, glute = medium, etc.). TT's contact
composition reads them at the same point it reads tentacle surface
tags today, with the same composition rules.

**Authoring**: per-region material data is authored in Blender on the
tet input mesh as a vertex color channel or custom data layer; the
authoring chain (B4) bakes it into the `.bin` (v3 — see §6 below).

**Fallback behavior**: body_field absent → no proxy tag → TT
composes against tentacle's authored default μ, identical to today.
On heroes with body_field but no per-region tag authored, the tags
default to "neutral" which composes to tentacle's default → identical
to today.

**Side effect — fixes audit's S5.** The 4Q-fix tension taper in
`pbd_solver.cpp:276` reads a single per-tentacle `friction_static`,
which the audit flagged as wrong when contact μ varies across the
chain. Moving μ composition to 4S.3 puts the composed μ in the same
data path as the taper's input. The taper then naturally consumes
the composed μ.

---

## 4. Per-consumer fallback table

The hard invariant requires every body_field consumer to have a
tested fallback. Inventory:

| Consumer | body_field-present path | body_field-absent path |
|---|---|---|
| TT type-1 contact geometry | Tet proxy via `LAYER_BODY_PROXY` (§3.1) | `BoneCollisionProfile` full-skeleton capsules via `LAYER_BODY_CAPSULES_FULL` |
| TT friction reciprocal | `BodyField::receive_external_impulse` weighted bone routing (§3.2) | Direct `body_apply_impulse` on hit capsule's bone (current path) |
| TT per-region μ / stiffness | 4S.3 surface tags on proxy faces (§3.3) | Tentacle authored defaults (current) |
| Marionette §15 jiggle (v1) | Render-mesh additive-offset path (no body_field touch) | Identical |
| Marionette §15 jiggle (v1.5+) | Optional `kinematic_targets` integration | Render-mesh additive-offset path preserved |
| Marionette §16 soft regions | Optional composition with tet sim (v2+ B7) | Standalone cluster solver |
| Marionette §17 BodySurfaceField | Lives in body_field, runs as v1.5+ slice family | Pre-§17 manual-authoring path (the §15 "authoring gotcha (mandatory)" stays live) |
| Marionette §18 amendments (volumetric heat, anisotropy) | v2+ B7-B10 slices | Unavailable; consumers degrade gracefully |
| Reverie belly inflation | Writes to body_field runtime tunable | No-op write |
| Reverie per-region stiffness modulation | Writes to body_field runtime tunable | No-op write |
| Reverie deep-contact sensitivity (volumetric solve) | v2+ B9 | Surface-Laplacian approximation on render mesh OR unavailable, depending on consumer |
| TentacleTech `RhythmSyncedProbe` reading `body_rhythm_phase` | Reads from Marionette (orthogonal to body_field) | Identical (orthogonal) |
| Sonance / Visage Marionette state consumption | Reads Marionette state (orthogonal to body_field) | Identical (orthogonal) |

The last three rows are listed only to confirm orthogonality:
body_field absence does not affect them at all.

---

## 5. New B6 acceptance criterion: kasumi-without-body_field smoke test

In addition to the existing B6 v1 visible-quality bar (per 05-13 §"v1
visible-quality bar — revised"), B6 must include a regression test:

**Test:** run the TT Phase 5 acceptance scenario suite on kasumi
twice:

1. With a `BodyField` node in the hero scene.
2. With the `BodyField` node removed (and `BoneCollisionProfile`
   layer set switched to `_FULL`).

**Acceptance:** run #2 produces behavior bit-for-bit equivalent to
the pre-body_field baseline (commit `cbe22b0` or whichever ships
05-13). Deterministic seeded scenarios; deltas allowed only where
intentionally introduced by concurrent 05-xx briefs.

**Why:** the hard invariant is testable only if there's a CI-runnable
proof that body_field's presence is genuinely additive. Without this
test the invariant erodes through normal feature work.

**Gating rule:** body_field-touching PRs must pass both runs. This
test gates merges, not just B6 close-out.

---

## 6. `.bin` format → v3

The audit surfaced two `.bin`-format issues this brief settles:

1. **v2 has no slot for `tet_skin_indices` / `tet_skin_weights`**,
   which v1 kinematic-only requires per 05-13 §"tet skin weights."
2. **§3.2 impulse re-routing** also needs the tet-vert bone-weight
   bake, same data, so this is one extension not two.

**v3 layout** adds two arrays alongside the existing v2 fields:

```
PackedInt32Array  tet_skin_indices   # 4*Nt  (4 bone indices per tet vert, padded)
PackedFloat32Array tet_skin_weights  # 4*Nt  (normalized weights, sum to 1.0)
```

Plus a per-region material slot if §3.3 authoring lands at B4:

```
PackedByte32Array  tet_face_region_id  # Nf   (region id per tet outer face)
                                       # 0 = no tag (default), >0 = lookup into per-region material table
PackedFloat32Array region_material_table  # variable, packed per-region records
```

**Version-bump rule.** Reader rejects loads where `version != 3`.
Authoring chain (Blender side, B4) writes version 3. No silent
compatibility with v2 — the audit flagged silent version drift as a
SHARP risk; bumping unambiguously closes that hole.

**Vendoring rule.** The Blender-side authoring chain
(`~/desktop/blender-addon-tetmesh/` per 05-12-02) ships into the
repo at `tools/blender/body_field/` as part of B4. Writer and reader
live in lockstep in one tree. Eliminates the "writer at desktop, reader
in repo" drift risk.

---

## 7. Apply pass — what the apply pass must do

This brief adds to and supersedes the 05-13 apply checklist. Full
apply pass, in order:

### 7.1 Top-level CLAUDE.md

✅ Done in this commit. New "Cross-extension rules" bullet:
"`body_field` is a fidelity upgrade, not a dependency..."

### 7.2 `Cosmic_Bliss_Update_2026-05-13_body_field_v1_kinematic_only.md`

Add status banner at top: "Superseded in §"Two parallel paths" and
§"Extremities mask" dispatch claims by
`Cosmic_Bliss_Update_2026-05-14_body_field_optionality_and_dispatch.md`.
Per-particle-per-region dispatch as described in this brief was not
implementable; replaced with collision-layer partition + body_field-
side impulse re-routing + 4S.3 material composition. v1 scope
(kinematic-only, no XPBD, render-mesh parallel) is unchanged."

### 7.3 `Cosmic_Bliss_Update_2026-05-12-02_flesh_deformer_integration.md`

Add status banner at top noting both 05-13 (v1 scope reduction) and
05-14 (optionality invariant + dispatch correction) supersede it for
v1 reading.

### 7.4 `docs/marionette/Marionette_plan.md` §18

- Status STRETCH → ACTIVE (already landed per 05-12-02 §D6).
- Retitle to "Volumetric tet substrate (`body_field` extension)"
  (audit's I3 — never landed).
- Rewrite lines 1561-1567 to describe v1-kinematic-only, not XPBD v1
  (audit's I1).
- All references to body_field-driven features phrased as "when a
  `BodyField` node is present, ...; when absent, ...".

### 7.5 `docs/marionette/Marionette_plan.md` §15

- Line 1168: change "feed body_field's kinematic_targets compute
  pass" to "in v1, jiggle bones stay on the render-mesh
  additive-offset path. In v1.5+, when `body_field` is present, jiggle
  poses may *additionally* drive body_field's kinematic_targets
  compute pass; the render-mesh path remains live in either case."
- Line 1195: the "authoring gotcha (mandatory)" stays live as the
  no-body_field authoring path. Update line 1166 accordingly — the
  gotcha does **not** retire post-§17.5; it persists as the fallback.
  (Audit's I20 resolves toward keeping the gotcha.)

### 7.6 `docs/marionette/Marionette_plan.md` §16

Add note: "Soft-region cluster particles compose with `body_field`
tet substrate when present (v2+ B7 slice). Standalone cluster solver
is the no-body_field path and the default for v1."

### 7.7 `docs/marionette/Marionette_plan.md` §17

- Line 1532, 1549 (Q17.3): mark **Resolved**. Extension home is
  `body_field` per 05-12-02 §D7.
- Add fallback note: "Consumers of §17 surface field (rim authoring,
  jiggle attachment authoring, soft-region cluster authoring) keep
  their pre-§17 manual-authoring path live as the no-body_field
  fallback."

### 7.8 `docs/architecture/TentacleTech_Architecture.md`

- §4.2 type-1: rename row to "tentacle particle vs. outer body
  (proxy or capsule per collision-layer partition)." Document the
  layer scheme from §3.1. (Audit's S2.)
- §4.5: retitle from "ragdoll snapshot" to "body-body snapshot
  discipline." Update content: "snapshot once per *substep* (not per
  PBD iteration); the per-substep mechanism is `get_rest_info` for
  body identification + body-local cache. When body_field is present,
  the tet proxy obeys the same per-substep discipline; body_field's
  kinematic-targets compute pass runs at the substep boundary, not
  mid-PBD." (Audit's S4 + L6.)
- §10.5: rewrite from "capsule suppression during EI" to "contact
  suppression during EI. When the hero uses the capsule path, suppress
  per-bone capsules; when the hero uses body_field, suppress the
  per-region tet faces near the EI rim. Same semantic, dispatched by
  which path the particle's probe hit."

### 7.9 `extensions/body_field/CLAUDE.md`

Full rewrite against the merged 05-12-02 + 05-13 + 05-14 stack.
Current contents describe XPBD v1 (audit's body_field BLOCKER 2).
The rewrite:

- v1 = kinematic-only, single compute pass (`kinematic_targets.glsl`),
  no surface_transfer, no SDF collision, no Neo-Hookean, no LRA.
- v1.5 = conditional XPBD per B6 gate.
- Tet proxy runs parallel to render mesh, never upstream of it in v1.
- Hard invariant: body_field-absent path is bit-for-bit equivalent to
  pre-body_field baseline.
- `BodyField::receive_external_impulse` is the v1 contract for TT
  reciprocal routing.
- `.bin` format v3 (this brief).
- 4S.3 surface tag consumption is the per-region material mechanism.
- Snapshot discipline: write tet positions once per substep, never
  mid-PBD; coordinated with TT's substep boundary via dispatch
  ordering.

### 7.10 `extensions/tentacletech/CLAUDE.md`

Per-region dispatch table from 05-13 §"Knock-on effects" is
**revised** to: "TT particles probe against
`LAYER_BODY_PROXY | LAYER_BODY_CAPSULES_DETAIL | LAYER_BODY_CAPSULES_FULL | LAYER_WORLD`
unconditionally. body_field's tet body, when present, occupies
`_PROXY`. `BoneCollisionProfile`'s capsules populate `_DETAIL` (hands/
feet only) when body_field is present, or `_FULL` (full skeleton)
when body_field is absent. No per-particle dispatch table." Land
this at B5.

---

## 8. Knock-on effects

Beyond the apply pass items in §7, three new files / sections are
touched:

| File | What changes |
|---|---|
| `/home/user/cosmic-bliss/CLAUDE.md` | New "Cross-extension rules" bullet (this commit). |
| `tools/blender/body_field/` (lands at B4) | Vendored Blender authoring chain (per §6 vendoring rule). Replaces the off-repo `~/desktop/blender-addon-tetmesh/` path. |
| TT test suite | Add `test_kasumi_without_body_field.gd` (kasumi smoke test per §5). Existing Phase 5 acceptance scenarios run with `BodyField` removed from the hero scene. |
| `BoneCollisionProfile` resource | Gains `active_layer_set: enum { FULL, DETAIL }` (or equivalent), set at hero-init based on body_field presence. Marionette-side change; coordinated with B5. |
| `extensions/body_field/src/body_field.cpp` (new in B0+) | Adds `receive_external_impulse(...)` C++ method. Gated on B0 scaffolding (which has landed per audit). |

---

## 9. Apply checklist for top-level Claude

1. ✅ Brief written (this doc).
2. ✅ Top-level CLAUDE.md updated (this commit).
3. **Open PR** carrying 05-13 + 05-14 + CLAUDE.md edit as a single
   reviewable design package.
4. **Run apply pass** items 7.2 — 7.10 as a follow-up commit (or as
   a series of follow-up PRs, one per consumer). The body_field
   supervisor CLAUDE.md rewrite (7.9) is highest priority because
   sub-Claudes reading it today reach the wrong v1.
5. **B4 vendoring** of the Blender authoring chain. Move
   `~/desktop/blender-addon-tetmesh/` into `tools/blender/body_field/`.
   Audit a delta for spec drift before committing the move.
6. **B5 prompt** for sub-Claude must use this brief's §3 mechanisms,
   not 05-13's per-region dispatch.

---

## Summary

`body_field` is a fidelity upgrade with a hard invariant: no system
may require it. Every consumer has a tested fallback. Codified in
project CLAUDE.md. 05-13's per-particle per-region dispatch — which
the audit found was not implementable against TT's probe architecture
and silently broke friction reciprocal routing — is replaced with
collision-layer partition + body_field-side impulse re-routing +
existing 4S.3 surface-tag material composition. All three mechanisms
are naturally fallback-clean: body_field absent → empty layer, no
proxy body, no surface tag → bit-for-bit equivalent to the
pre-body_field baseline. `.bin` bumps to v3 to carry the tet skin
weights v1 kinematic-only needs (the v2 omission was a real v1
blocker). B6 acceptance gains a kasumi-without-body_field regression
test that gates body_field-touching PRs. Apply pass walks Marionette
§15/§16/§17/§18 and TentacleTech §4.2/§4.5/§10.5 to phrase body_field
references as "when present, X; when absent, Y." Body_field supervisor
CLAUDE.md gets a complete rewrite — its current contents describe a
v1 that doesn't exist.
