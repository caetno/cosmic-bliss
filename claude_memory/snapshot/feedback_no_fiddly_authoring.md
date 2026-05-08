---
name: No fiddly artistic authoring for body/tissue systems
description: For soft-tissue / region / mask features, authoring must stay primitive-volume + numeric sliders — no per-vertex painting, no tet meshing, no side-authored Resource files
type: feedback
originSessionId: ccaf24fd-acfe-4024-b9b6-7c19b411e9a1
---
For body-tissue / soft-region / mask-region systems, the authoring contract must stay extremely lightweight. Acceptable inputs: bone reference, primitive volume (sphere/capsule/ellipsoid) edited via gizmo, a handful of `@export` numbers on a profile resource. Unacceptable inputs: per-vertex paint masks, tet-mesh authoring, hand-tuned Resource sidecars per region, per-vertex weights, per-rim feature-by-feature mark-up.

**Why:** stated 2026-05-07 in the procedural-audio + soft-region update — "the hardest part would be mixing softbody and un-simulated body regions, the authoring must be easy and should not involve fiddly artistic aspects." Reinforces an existing pattern (test scenes stay simple; reject side-authored Resource files even with permission).

**How to apply:** when designing new tissue/region/mask features, auto-derive boundary blends from the volume SDF + existing skin weights. C1 smoothstep across the volume boundary, never a discrete partition. Tet meshes are the canonical anti-pattern; particle-cluster + shape-matching (Obi softbody architecture) is the model. Reference: `docs/Cosmic_Bliss_Update_2026-05-07_procedural_audio_and_soft_regions.md` "Authoring constraint" section.
