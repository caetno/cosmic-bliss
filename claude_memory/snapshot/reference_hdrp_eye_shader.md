---
name: HDRP eye shader reference + texture conventions
description: Where the HDRP HLSL source lives and the non-obvious authoring conventions a Godot port has to honor
type: reference
originSessionId: 4205a866-d8cd-463a-9a93-303e1378853d
---
HDRP eye shader source files (verbatim copy from Unity HDRP package):
- `blender/eyes/HDRP Eyes/references/EyeUtils.hlsl` — math primitives: `GetIrisUVLocation`, `CirclePupilAnimation`, `CorneaRefraction`, `IrisLimbalRing`, `ScleraLimbalRing`, `ScleraIrisBlend`, `IrisOutOfBoundColorClamp`, `IrisOffset`. Directly portable to GLSL.
- `blender/eyes/HDRP Eyes/references/Eye.hlsl` — HDRP BSDF; uses TWO normals (`specularNormal` flat in iris, `diffuseNormal` sclera→iris-bumped).
- `blender/eyes/HDRP Eyes/M_EyeSG 2.mat` / `M_EyeSG 3.mat` — Unity material with cryptic `Vector1_XXXXXXXX` param names. The hash → semantic mapping is in `blender/eyes/HDRP Eyes/HDRP Eyes/CALIBRATION.md`.
- `Iris02_BC.tif`, `Iris03_BC.tif`, `Sclera_BC.tif`, `Sclera_N.tif`, `Iris_N.tif` — original texture authoring; useful to compare against the Godot-side equivalents under `game/assets/materials/eye/textures/`.

**Non-obvious conventions the port must honor:**

1. **HDRP iris textures bake a bright outer-fiber band, not a dark anatomical limbus.** `r_uv ≈ 0.93–1.0` reads as golden/yellow fibers; the dark limbus comes from the shader (`IrisLimbalRing`). When porting, crop iris_uv to ~0.92 (we have `iris_uv_max_r`) so the band doesn't surface as a "white rim" wherever cornea_refraction overshoots the unit circle (oblique angles, geometry past the cornea bulge, or a too-large iris_radius).

2. **HDRP sclera texture has an "iris hole" gray spot + bright halo at the texture center.** Mesh UV maps the iris area to the texture center, expecting iris content to overlay it. Both the supplied Sclera_BC.tif and our eyeSclera.png follow this convention. With a narrow blend zone the halo can leak as a "white ring" in the sclera near the iris; either widen the sclera limbal ring or use a hard cut.

3. **HDRP's `ScleraIrisBlend` uses ^8 over a NARROW band (~9% of irisRadius).** Easy to miscompute: `(osRadius - irisRadius) / (0.04)` — divisor 0.04 is TWICE the active half-width 0.02. EyeUtils.hlsl line 115 reads as a wider band than it actually is.

4. **HDRP iris_radius is hardcoded to fit `HumanEyeModel.fbx`** — the demo material sets it to 0.22. There's no auto-fit in HDRP either; different meshes need different values, calibrated by eye. This is a per-mesh constant, not per-shot tuning.

5. **HDRP's two-normal trick** — `specularNormal = lerp(scleraNormal, FLOAT3(0,0,1), surfaceMask)` keeps cornea spec smooth despite iris fiber relief. Godot has a single `NORMAL` output, so use HDRP's spec-normal semantics (sclera-bumped → flat in iris) and express iris fiber relief via height-AO darkening on iris_color rather than NORMAL perturbation.

6. **HDRP demo material `iris_apparent_depth = 0`** (Vector1_76BF2124 in M_EyeSG 2.mat). Anything > 0 introduces lateral iris-UV drift at oblique view angles that smears iris-edge fibers into the boundary. Default the port to 0 unless the mesh genuinely needs faked lens parallax.

7. **HDRP cornea_smoothness in M_EyeSG2.mat is 0.025** (Vector1_94E1614A). Sounds matte but HDRP relies on the separate cornea-spec layer + caustic LUT for the wet look. Single-layer ports need a higher value (0.7–0.9) to fake glossiness through the diffuse+spec BSDF.
