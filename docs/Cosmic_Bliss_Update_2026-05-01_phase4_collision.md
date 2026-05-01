# Cosmic Bliss — Design Update 2026-05-01 — Phase 4 collision slice plan (Type-4 only) + §4.5 ownership amendment (deferred)

**Audience: Repo organizer Claude (Claude Code session).**

This doc covers two changes for TentacleTech Phase 4:

1. **Phase 4 sliced into Type-4-only landings.** Three slices (4A → 4B → 4C). Tentacles collide with any `PhysicsBody3D` in the world via raycasts — a bare `StaticBody3D` is sufficient. **Type-1 ragdoll capsules are explicitly out of Phase 4** and deferred until Marionette's active ragdoll is online (probably during Phase 5 orifice work, or whenever the hero genuinely needs to respond to tentacle pressure).
2. **§4.5 ownership amendment (proposal, not for application yet)** — When Type-1 does land, Marionette should serve the ragdoll snapshot; TentacleTech keeps a fallback. Captured here so it's not forgotten, but **not to be applied now**.

The TentacleTech sub-Claude will not touch Marionette files. When the §4.5 amendment is later applied (with Type-1 work), it will require a one-line note in `docs/marionette/Marionette_plan.md` from the top-level Claude.

---

## Part 1 — §4.5 ownership amendment (DEFERRED — captured for later)

> **Status:** Proposal only. Do not apply this amendment now. It lands together with Type-1 ragdoll capsules, in a future phase, once Marionette's active ragdoll is a thing tentacles need to push back against. Captured here so the design isn't re-derived from scratch later.

### Current text (TentacleTech_Architecture.md §4.5)

> Before the PBD iteration loop, for each `PhysicalBone3D` in the hero's skeleton, build `ragdoll_snapshot[]` of `{a, b, radius, bone_ref, surface_material}`.

Implicitly assigns the work to TentacleTech.

### Problem

Marionette is the active-ragdoll solver; it already computes world-space bone transforms during its SPD step. Having TentacleTech re-read `PhysicalBone3D.global_transform` after the fact:

- Repeats Marionette's work, and
- Triggers a physics-server sync read on every bone, which §4.5 itself flags as the thing to avoid.

The **once-per-tick** rule was about not reading inside the iteration loop. But "once" can still cost more than necessary if Marionette has the data on hand.

### Proposed amendment

Replace §4.5 with the following structure (verbatim spec text to be drafted at apply time):

1. **Shared snapshot type** — `extensions/shared/include/ragdoll_snapshot.h` defines a header-only POD `RagdollSnapshot`:
   ```cpp
   struct RagdollCapsule {
       Vector3 a, b;            // world space
       float   radius;
       uint32_t bone_id;        // skeleton-local index; -1 if none
       uint32_t surface_material_id;
       ObjectID bone_ref;       // optional, for impulse routing
   };
   struct RagdollSnapshot {
       LocalVector<RagdollCapsule> capsules;
       uint64_t tick_id;        // for staleness assertions
   };
   ```
   No `#include`s into either extension's internals; both sides depend only on this header. The shared header lives in `extensions/shared/include/`, which the cross-extension rule already authorizes.

2. **Producer (Marionette, when present).** Marionette publishes the snapshot at end-of-solve into a `RagdollSnapshotProvider` Node (or onto the `Marionette` node itself; producer-side decision). One write per physics tick. Tick ordering is enforced by physics-process priority on the producer node — Marionette must run before any TentacleTech consumer.

3. **Consumer (TentacleTech).** `Tentacle` exposes a `snapshot_source: NodePath` `@export` (or equivalent C++-side property). Resolved once at `_ready()` to a typed pointer. At start-of-tick TentacleTech copies the snapshot ref (cheap; `LocalVector` data is reused tick-to-tick, not reallocated). PBD iterations read from this ref.

4. **Fallback when no producer.** If `snapshot_source` is empty or resolves to nothing, `Tentacle` builds the snapshot itself from a configured `Skeleton3D`/`PhysicalBoneSimulator3D` by walking its `PhysicalBone3D` children once. This preserves standalone test scenes and decouples TentacleTech's release from Marionette's. **Same path the spec describes today; just relegated to fallback.**

5. **Surface material** is owned by the producer side. Marionette assigns `surface_material_id` per bone from a body-area lookup (Marionette already has body areas as part of the hero authoring); fallback path uses a default `Skin` material when no per-bone material is configured. This is a one-line lookup, not a new system.

6. **Impulse routing back to bones (§4.3 type-1 reciprocal).** Unchanged — TentacleTech calls `bone.apply_impulse_at_position` via the `bone_ref` ObjectID in the snapshot entry. No reverse channel needed; PhysicsServer3D handles it. The friction reciprocal is still TentacleTech's write, just like today.

7. **Tick-order failure mode.** If TentacleTech reads a snapshot whose `tick_id` does not match the current tick (i.e., Marionette failed to publish this tick), TentacleTech logs a warning once per N seconds and uses the stale snapshot. No crash, no silent skip. This catches process-priority misconfigurations early.

### What does NOT change

- **§4.3 friction projection** — same code, same per-particle reads against capsules.
- **§4.5's central rule** — never query `PhysicalBone3D.global_transform` inside the PBD iteration loop. Still holds; the snapshot is built before the loop, regardless of which side builds it.
- **Standalone TentacleTech test scenes** — keep working, via the fallback path.

### One-line note required in `docs/marionette/Marionette_plan.md`

Add to the relevant Marionette phase (likely P3 ragdoll creation or P5 active-ragdoll integration; top-level Claude to choose): *"Publishes a `RagdollSnapshot` per the shared `extensions/shared/include/ragdoll_snapshot.h` contract at end-of-solve. Required for TentacleTech §4 type-1 collision; see `Cosmic_Bliss_Update_2026-05-01_phase4_collision.md`."*

---

## Part 2 — Phase 4 slice plan (Type-4 only)

Phase 4 lands Type-4 environment collision and the §4.3 friction model. **No Type-1 ragdoll-capsule code, no shared snapshot header, no Marionette dependency.** Raycasts hit any `PhysicsBody3D` in the world via the physics server, so authoring a test scene is "drop in a `StaticBody3D` with whatever `CollisionShape3D` you want" — exactly the bar set in this design conversation.

Type-1 ragdoll capsules + the §4.5 amendment land later, in their own update doc, when there's a real ragdoll the tentacles need to push.

### Slice 4A — Type-4 raycasts, normal-only projection

**Smallest possible "collision works."**

Code:
- `src/collision/environment_probe.{h,cpp}` — issues 3 raycasts per tentacle per tick via `PhysicsDirectSpaceState3D::intersect_ray`. Initial direction pattern: gravity-down + 2 lateral perpendiculars to the chain mid-tangent. Steering deferred to behavior driver.
- `Tentacle::tick()` — after Verlet integration, before constraint iterations, runs the 3 rays from the chain centroid. Hit results stored as `LocalVector<EnvironmentContact>` with `{point, normal, surface_material_id, particle_id_nearest}`.
- During PBD iterations: for each particle whose effective radius reaches a hit point (cheap distance test; the 3 rays approximate, they don't enumerate), project the particle out of the surface along the hit normal. **Normal correction only — no friction yet.**

Snapshot accessor (per §15.2):
- `Tentacle.get_environment_contacts_snapshot() -> Array[Dictionary]` returning `[{ray_origin, ray_dir, hit_point, hit_normal, surface_material_id}]`.

Gizmo additions (per §15.3, runtime overlay + editor):
- 3 ray segments drawn (origin → hit, or origin → max distance if no hit).
- Hit point markers with a short normal-direction tick.

Acceptance:
- Chain dropped on a `StaticBody3D` floor settles on the surface, not through it.
- Chain dropped onto a `StaticBody3D` sphere drapes around it (rough — final draping behavior comes after slice 4C).
- Tests at `game/tests/tentacletech/test_collision_type4.gd`: hit detection sanity, projection-out direction sanity, no allocation in tick (3 rays use a reusable `PhysicsRayQueryParameters3D`).

**Test scene** (requires explicit user OK before creation): single `Tentacle` + `StaticBody3D` floor + `StaticBody3D` sphere. No animation, no lighting bake, no Resource pipeline. Per CLAUDE.md test-scene rules.

### Slice 4B — Unified §4.3 friction on Type-4 contacts

Adds the friction cone projection from §4.3 on top of the normal correction landed in 4A. Type-1 reciprocal routing is **not yet implemented** — slice 4D — but the `friction_applied` value is computed and stored.

Code:
- Friction projection block factored into a header `src/collision/friction_projection.h` so it's literally shared between Type-4 (this slice) and Type-1 (slice 4D). One source of truth for the cone math.
- `μ_s` composition (§4.4) lands minimal: `base_friction_pair(surface_smooth, surface_dry)` + `(1 - lubricity) × (1 - wetness)`. Rib/grip/anisotropy/adhesion modulators deferred to slice 4F or later phases.

Snapshot accessor:
- Extend `get_environment_contacts_snapshot()` entries with `friction_applied: Vector3` (the displacement actually canceled this tick).

Gizmo additions:
- Optional friction-vector arrow at each hit point (off by default; toggled via debug overlay setting).

Acceptance:
- Tentacle tip dragged along a sphere by behavior input shows stick-slip when crossing onto a higher-μ surface (set up via two `StaticBody3D`s with different surface tags).
- A horizontally-pinned tentacle resting on a floor doesn't drift sideways under gravity-only input — static friction holds it.
- Tests: stick-slip sanity (tangential motion vanishes when below static cone, scaled when above).

### Slice 4C — Soft distance stiffness during contact

Per §4.3: `contact_stiffness` (default 0.5) replaces base distance stiffness on any segment with at least one in-contact endpoint this tick. Lets the chain temporarily stretch over wrapped geometry rather than rigidly forcing collision push-out against rigid distance constraints (which produces jitter).

Code:
- `TentacleParticle::in_contact_this_tick: bool` — set by collision pass, cleared at start-of-tick.
- Distance constraint iteration reads it on both endpoints, picks `contact_stiffness` vs. `base_stiffness`.
- New `@export` on `Tentacle`: `contact_stiffness: float = 0.5`.

Snapshot accessor:
- Add `in_contact_this_tick: bool` to the per-particle snapshot already exposed in Phase 2.

Gizmo additions:
- Particles in contact rendered in a distinct color via the existing `gdscript/debug/particles_layer.gd`.

Acceptance:
- Chain dropped on a sphere wraps further around than it does without soft stiffness (visible difference at default settings).
- Removing the sphere lets the chain spring back to rest length within one settle.
- No new test file required; visual + a simple "rest length restored within K ticks after contact ends" assertion added to `test_collision_type4.gd`.

---

## What's deferred

- **Type-1 ragdoll capsules** — entirely deferred. Lands when Marionette's active ragdoll is real and the §4.5 amendment in Part 1 is applied.
- **§4.6 wetness accumulation from external friction** — small, but it sits on type-1 contacts with body-area-tagged surfaces. Lands with Type-1 work.
- **Type-2 / Type-3 / Type-6 / Type-7 collision** — depend on the orifice system (Phase 5) and attachment system (Phase 8), per §13.
- **Type-5 particle-vs-particle (spatial hash)** — only required *inside orifices* per §4.2. Lands with Phase 5.
- **Behavior-driven ray steering** — slice 4A uses a fixed gravity+lateral pattern. Smarter steering (toward orifice candidates, hero limbs of interest) lands when the AI scorer and orifice system are online.
- **Full §4.4 modulator stack** — rib modulation, grip engagement, barbed asymmetry, adhesion bonus. Each is one or two lines; they can land opportunistically as the surface authoring catches up. Slice 4B locks in the *composition order* and the empty hooks; the math beyond `(1 - lubricity)(1 - wetness)` follows.
- **Length-redistribution / "S-curve elastic budget"** — explicitly deferred per §4.3.

---

## Apply / not-apply checklist for top-level Claude

When applying this update:

1. **Part 1 (§4.5 amendment) — DO NOT APPLY YET.** Captured for later. When Type-1 ragdoll capsules are scheduled, a follow-up update doc references this one and applies §4.5 + the `Marionette_plan.md` one-liner + the shared header at that point.
2. **Status table in `extensions/tentacletech/CLAUDE.md`** — Phase 4 row stays as `next` until a slice lands, then flips to `in progress: 4A done` etc. Add a footnote that Phase 4 ships Type-4 only; Type-1 is its own future phase.
3. **Defer to TentacleTech sub-Claude:** Part 2's slices 4A–4C, in order, with build + tests run per CLAUDE.md before each slice's "done" report.
