---
name: PhysicalBone3D 6DOF angular_limit unit quirk under Jolt
description: joint_constraints/<axis>/angular_limit_lower|upper consumes the stored number AS DEGREES on the Jolt path despite the radians_as_degrees property hint
type: reference
originSessionId: 71fa7771-052e-4ccd-9081-32007dd3d98d
---
In Godot 4.6 with the Jolt physics backend, the `PhysicalBone3D.joint_constraints/<axis>/angular_limit_lower|upper` properties have the property hint `radians_as_degrees`, which means the inspector displays in degrees and converts on input — implying stored radians.

But on the Jolt path (Godot 4.6.2 + Jolt 4.6 backend), the stored number is consumed AS DEGREES, not radians. Empirically verified by writing `2.6` (intending radians ≈ 149°) and observing a 2.6° limit (rigid rig).

**How to apply:** When writing these properties from script, write the value in **degrees**. If the source is radians (e.g., `BoneEntry.rom_min/max` are radians), pass through `rad_to_deg()` first. Reads return degrees. Do not assume the hint reflects the runtime contract here.

Live workaround in `game/tests/marionette/ragdoll_physics_test.gd::_apply_authored_rom` and `::_loosen_joint_limits` (both write degrees). **Runtime path fixed 2026-05-02**: `Marionette._apply_joint_constraints` now calls `rad_to_deg()` on writes and applies the HINGE X-flip below. The test scene's `_apply_authored_rom` is now redundant (overwrites with the same values) but harmless; left for diagnostics.

Do not blanket-apply this for GodotPhysics3D — only verified for Jolt. If switching backends, retest.

**Second quirk on the same code path: X axis sign is mirrored on HINGE archetypes.** Empirically:

- HINGE bones (elbow, knee, finger/toe phalanges) — limits read mirrored without a flip. Authored elbow `(-20°, +120°)` produced motion `(-120°, +20°)` (bone hyperextends, can't curl). Compensating with swap-and-negate `(lower, upper) → (-upper, -lower)` fixes it.
- SADDLE (foot, wrist), BALL (shoulder, hip), SPINE_SEGMENT, CLAVICLE — limits read correctly without the flip. Verified by SADDLE foot's asymmetric `(-15°, +40°)` ROM acting *flipped* when the X-flip was applied universally.

Suspected mechanism: only HINGE produces a non-zero `rest_anatomical_offset.x` (`bone_profile_generator.gd::_compute_rest_offset`); the carrying-angle offset combined with Jolt's X-axis decomposition mirrors the limit. Other archetypes have `rest_offset.x = 0` and dodge the interaction.

Conditional flip in `_apply_authored_rom`: `if i == 0 and entry.archetype == BoneArchetype.Type.HINGE`. Y/Z are not flipped — most bones lock those (HINGE) or carry symmetric ROMs (BALL rot/abd, spine), so a flip would be invisible. If a deliberately asymmetric Y/Z reads mirrored later, extend the conditional.

**Third quirk on the same code path: angular-spring property name asymmetry.** The angular *limit* properties are `joint_constraints/<axis>/angular_limit_{enabled,lower,upper,softness}` (with `_limit_`), but the angular *spring* properties are `joint_constraints/<axis>/angular_spring_{enabled,stiffness,damping}` (without `_limit_`). Same pattern for linear: `linear_limit_*` vs `linear_spring_*`. Verified empirically via `get_property_list()` on Godot 4.6.2 + Jolt 4.6 backend. Writing the wrong property name silently no-ops; readback returns nil. Caught while wiring slice 3 — initial code wrote `angular_limit_spring_*` which doesn't exist.
