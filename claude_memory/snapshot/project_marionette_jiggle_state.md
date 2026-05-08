---
name: Marionette jiggle state (2026-05-02)
description: Soft-region jiggle bones — what the kasumi/ARP rig has and doesn't have, what's wired up
type: project
originSessionId: 6267d5c9-453d-4646-b2fb-29978a6317c4
---
CLAUDE.md §15 jiggle-bone system has a first cut as of 2026-05-02:

- `BoneCollisionProfile.non_cascade_bones` lists soft-region bones to harvest into their own hull (skip the cascade-up).
- `JiggleBone` extends `MarionetteBone`. Spawned by `Marionette.build_ragdoll` for every entry in `non_cascade_bones`. Joint locks all 3 angular axes, ±5 cm linear budget.
- Translation-only SPD in `JiggleBone._integrate_forces`: spring back to host_pose × rest_local with mass-portable kp/kd (reach 0.3 s, ζ 0.7 by default).
- `custom_integrator=true` so no built-in gravity; spring is the only force.

**Why:** First soft-region bones in the project. Brought in incrementally because the rest of Marionette's SPD (Phase 5 per CLAUDE.md) still hasn't landed.

**How to apply:** When adding a new hero, populate `BoneCollisionProfile.non_cascade_bones` with that hero's breast/glute/jowl bones. They must already exist in the skeleton (Blender-authored, skin-weighted) — the runtime can't synthesize bones the rig doesn't expose.

**Kasumi rig specifically:**
- Has 4 breast bones: `c_breast_01.l/r`, `c_breast_02.l/r` — all parented to UpperChest, all carry significant skin weight (270 / 121 weight totals on upper / lower halves). ✓ Wired up.
- **Has NO dedicated butt / glute bones.** Butt vertices are skinned to UpperLeg + Hips and are absorbed into those hulls (collision-only). Butt jiggle would require Blender-side authoring of `c_glute_01.l/r` (or equivalent) on the source hero, then adding them to `non_cascade_bones`. Don't try to synthesize butt bones at runtime.
- `Anus_Center` exists in the skeleton (Hips child) but carries no significant skin weight. Not a jiggle host.

**Mass note:** `_estimate_jiggle_mass` uses hull AABB volume × 1000 kg/m³ (water density). For kasumi this lands at 1.88–2.49 kg per breast bone, total ~8.7 kg of breast mass — high, because AABB overestimates hull volume. SPD math is mass-portable so the *feel* is correct regardless, but if specific tuning is wanted, override `JiggleBone.stiffness/damping` directly in the inspector.
