---
name: Marionette open spec questions
description: Forward-looking judgment calls on the humanoid BoneProfile that aren't decided in code yet — facing axis, Hips classification, proximal phalanx DOF, and the per-rig matcher-tolerance story
type: project
originSessionId: 6950a892-ac18-4d95-871c-bf2c4b19f2ae
---
Three classification choices in `archetype_defaults.gd` / the humanoid BoneProfile that the user has accepted as defaults but may want to change later, plus one runtime observation about how the matcher behaves on real rigs (it's the user-facing signal for "this rig needs calibration"). Phase-by-phase progress is now in `git log` — don't track it here.

## 1. Facing-axis flag on `BoneProfile`

Template `MarionetteHumanoidProfile` is built facing **-Z** (per `LeftEye` reference-pose y-column). If a user rig faces +Z, the muscle frame's `forward` ends up pointing toward the character's back, and `Marionette.build_ragdoll`'s `joint_rotation` baking inherits the inversion.

**Why:** Not yet observed in the wild — Kasumi happens to match. Pre-emptive flag would just be dead config.
**How to apply:** When a user reports inverted ragdoll bones or wrong-direction ROM on a non-Kasumi rig, the clean fix is a `facing_axis: SignedAxis.Axis = MINUS_Z` field on `BoneProfile`, flipped at solver-input time. Don't add it speculatively.

## 2. `Hips` archetype: ROOT vs SPINE_SEGMENT

Currently `Hips` is classified as `ROOT` together with `Root` (per plan §P2.5 "Root: hips/root"). User accepted implicitly.

**Why:** Most humanoid rigs have either a single `Hips` bone *or* a `Root` parent of `Hips` where `Root` is locomotion-only. In the latter case `Hips` does spine work and ROOT is wrong for it.
**How to apply:** If a rig surfaces where `Root` is the parent of `Hips` *and* `Hips` is meant to flex/rotate, reclassify `Hips` as `SPINE_SEGMENT` in `archetype_defaults.gd`. One-line change.

## 3. Proximal phalanx archetypes: Saddle vs Ball

MCP / MTP joints (proximal phalanges) are classified `Saddle` (2-DOF: flex + abduction). Plan §P2.5 wording is ambiguous — "finger/toe phalanges except proximal" are hinges, but didn't pin down what proximal *is*.

**Why:** Saddle covers the human MCP/MTP range adequately for a game; thumbs technically have a third DOF (opposition).
**How to apply:** If thumb/finger animation looks visibly stiff, switch `LeftThumbMetacarpal` / `RightThumbMetacarpal` (and possibly the others) to `Ball` in `archetype_defaults.gd`. One-line change per bone.

## 4. Per-rig matcher tolerance — yellow tripod = fallback in use

The matcher's ±31° threshold (cos ≈ 0.85) now switches between two valid baking paths, not pass/fail. Bones above threshold bake the signed permutation. Bones below set `BoneEntry.use_calculated_frame=true` and bake `calculated_anatomical_basis` directly into `joint_rotation` — the calculated-frame fallback. A-pose ARP rigs no longer need re-export to T-pose.

`tests/dryrun_kasumi_gizmo.gd` (one-off) reported 35/77 matched on the ARP-rigged Kasumi: lowest scores were thumb metacarpal ≈0.59 and lower arms ≈0.65. Pre-fallback those would have rendered with bad joint frames; post-fallback they bake the calculated target and just show as tilted (non-axis-aligned) joint tripods.

**Why:** Yellow tripods now mean "this bone uses the calculated-frame fallback," not "this bone is broken." Whole-rig yellow still indicates a wrong-facing rig, misconfigured BoneMap, or systematic bone-roll error worth fixing in Blender. Per-bone yellow on isolated joints is expected for non-T-pose rigs and isn't actionable.
**How to apply:** If a user asks "why are some bones yellow on my character", explain the fallback is in use and only worry if (a) the whole rig is yellow, or (b) the ROM arc visualization makes the gameplay-relevant calibration error visible (e.g. shoulder flex tilted by ≥30°). Fix path: re-roll bones in Blender, or regenerate a per-character `BoneProfile` against the live rig (the generator function takes `live_skeleton + bone_map`; the inspector button currently uses the template path only).
