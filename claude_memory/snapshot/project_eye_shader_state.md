---
name: HDRP Eye shader port state (2026-05-08)
description: Godot 4.6 port of HDRP eye shader at game/assets/materials/eye/eye.gdshader, key uniforms and non-obvious constraints
type: project
originSessionId: 4205a866-d8cd-463a-9a93-303e1378853d
---
Single-layer Godot port of HDRP's two-layer eye BSDF, tuned against `moreEyes.glb` (mesh-local iris_radius ≈ 0.005175). Mesh must be authored with origin at the iris plane (z=0) — same convention as HDRP's HumanEyeModel.fbx.

**Why:** HDRP's full pipeline (separate cornea spec layer + caustic LUT + wavelength SSS) doesn't translate cheaply into Godot's standard PBR; single-layer port reproduces the visual structure with adapted uniforms.

**How to apply:** Non-obvious knobs that took multiple iterations to land:

- `iris_radius` is mesh-local OS — calibrate per mesh, not universal. HDRP uses 0.22 for HumanEyeModel.fbx; moreEyes.glb wants ~0.005–0.007. The slider's `hint_range` is intentionally permissive (0.0001–0.5).
- `iris_uv_max_r` (default 0.92) — crops the texture's outer "limbus halo" band so it doesn't surface as a "white rim". The supplied iris textures (eyeBrown_albedo, HDRP's Iris02/Iris03) bake a brighter golden ring at `r_uv ≈ 0.93–1.0` instead of a dark anatomical limbus, so we crop and let the shader's `limbus_ring` draw the dark band.
- Single `limbus_ring` (not HDRP's two functions) keyed on `abs(r_xy - iris_radius)` with `1 - exp(-6t)` exponential decay — sharp ring centered on the boundary, not a smeared gradient. User explicitly wanted "exponential, fading over short distance".
- `surface_mask` is a HARD CUT at iris_radius (driving ALBEDO + SSS), not HDRP's ^8 narrow band. User asked for sharp boundary multiple times — "the sclera needs a hard cut".
- `cornea_t` is a wider smoothstep mask (drives ROUGHNESS and `sclera_normal_strength * (1 - cornea_t)`) — separates "cornea fade" from "iris/sclera albedo cut" so cornea gloss tapers smoothly while albedo stays sharp. `cornea_outer_radius_iris_units` sets band end (default 1.3).
- `iris_apparent_depth` defaults 0 — anything > 0 introduces lateral iris-UV drift at oblique angles that "messes everything up" (user phrase). HDRP M_EyeSG2.mat (Vector1_76BF2124) also defaults 0.
- `sclera_sss_strength` / `iris_sss_strength` default 0 — Godot's screen-space SSS blurs iris fibers and sclera vessels into mush. HDRP uses wavelength-dependent diffusion profiles that don't translate. User: "Leave SSS at 0.0 that blurrs the shit out of everything".
- NORMAL uses HDRP's spec-normal semantics (sclera-bumped → flat in iris). Iris fiber relief is via height-AO darkening on iris_color, NOT via NORMAL perturbation — Godot's env reflection uses NORMAL directly so bumping it makes the cornea spec look slimy.

**Hacks that were tried and rejected:**
- `cornea_outer_radius_iris_units`-based ROUGHNESS taper alone (didn't suppress the white ring on the cornea-bulge curvature transition).
- `cornea_ring_suppress_*` band — fought the wrong target; the ring was cornea spec catching curvature, not roughness cliff.
- Sclera UV radial remap — caused visible texture stretching; user flagged immediately.
- Sclera halo luminance cap — texture's halo wasn't actually the cause once the ring was diagnosed.

**Open issue:** No shader-side auto-fit for iris_radius. Cornea-bulge extent isn't readable from per-fragment data; would need a CPU-side mesh-AABB measurement at import time. User asked about this — confirmed it's not how HDRP works either.

**Test setup:** `game/assets/materials/eye/more_eyes.tscn` has user-placed `Front` and `Side` Camera3D nodes. `game/dev/eye_screenshot.gd` activates one by name and supports `EYE_PUPIL_RADIUS` / `EYE_IRIS_RADIUS` env overrides for ad-hoc test cases without editing the .tres.
