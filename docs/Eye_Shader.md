# Eye Shader

Single-layer Godot 4.6 port of Unity HDRP's two-layer eye BSDF, tuned for the Cosmic Bliss hero. Source files at `game/assets/materials/eye/`.

---

## Scope

Faithful port of HDRP's `EyeUtils.hlsl` math (cornea refraction, pupil animation, iris-plane intersection, limbal rings, surface mask) onto Godot's standard PBR lighting. Adapted, not literal — HDRP's full pipeline (separate cornea-spec layer + caustic LUT + wavelength-dependent SSS via `ScleraDiffusionProfile` / `IrisDiffusionProfile`) doesn't translate cheaply into Godot's standard BSDF, so several HDRP features collapse into Godot equivalents or are dropped explicitly.

**The shader file is the source of truth for the math.** Header comments in `game/assets/materials/eye/eye.gdshader` document each function, parameter, and gotcha inline. This doc captures only the *cross-cutting* knowledge: architectural choices, calibration, design decisions, and the lessons that don't fit in shader comments.

---

## Files

| File | Role |
|---|---|
| `game/assets/materials/eye/eye.gdshader` | Single unified shader — iris + sclera + cornea regions in one pass. |
| `game/assets/materials/eye/eye_material.tres` | Shader material — current tuned parameters live here. |
| `game/assets/materials/eye/more_eyes.tscn` | Test scene with `Front` and `Side` `Camera3D` nodes user-placed for artifact-revealing angles. |
| `game/assets/materials/eye/iris_albedo.png` `iris_normal.png` `sclera_albedo.png` `sclera_normal.png` | Texture set for the current hero. PNGs gitignored per repo convention. |
| `game/assets/materials/eye/textures/` | Additional texture variants. |
| `game/dev/eye_screenshot.gd` | Headless render harness. Activates `Front` / `Side` cameras by name; reads `EYE_PUPIL_RADIUS`, `EYE_IRIS_RADIUS` env vars for ad-hoc parameter sweeps without touching the .tres. |
| `game/scenes/eye_test.tscn` + `eye_test_controller.gd` | Interactive test scene (slider + key controls for pupil dilation, mouse rotate). |

HDRP source reference (HLSL files + Iris02/Sclera_BC textures + `M_EyeSG 2.mat` / `M_EyeSG 3.mat`) lives under `blender/eyes/HDRP Eyes/`. That directory is **gitignored as part of the blender working folder** — copies of the HLSL you need to consult during a porting session must be kept locally.

---

## Architecture

### Single mesh, single shader

Godot's FBX importer merges the HumanEyeModel.fbx iris and sclera geometry into one `EyeShell` mesh (674 verts, single material slot). The same is true for the moreEyes.glb mesh. There is no geometric separation between iris and sclera at runtime — the shader does *position-based blending* using `iris_radius` to decide whether a fragment is iris or sclera.

This is intentional: per-fragment masking by mesh-local XY radius (`length(pos_os.xy) < iris_radius`) gives a clean iris-circle inside the cornea bulge regardless of how the original art was authored. Earlier port iterations attempted separate iris / sclera materials; they have been retired.

### HDRP two-layer BSDF — collapsed to single-layer

HDRP's `EvaluateBSDF` (Eye.hlsl line 393–441) layers a specular cornea (geometric normal, GGX, F_Schlick from IOR) over a diffuse iris/sclera (bumped normal, Lambert × wrappedPower(NdotL, π/12, 2)) and conserves energy via `diffuse *= (1 − F)`. An earlier port iteration tried a `material_overlay` two-pass implementation, but the calibration cost (both materials must agree on `eye_center_z` / `eye_radius` / `iris_radius`) was high and Godot's standard PBR + the careful single-layer choices below produces a comparable result.

**Current single-layer scheme:**

- `NORMAL` uses HDRP's *spec-normal* semantics: sclera-bumped outside the iris, flat inside. The iris-region cornea highlight stays smooth.
- Iris fiber relief is delivered by **height-AO darkening** on `ALBEDO`, not by NORMAL perturbation. (See "Why iris bumps don't go through NORMAL" below.)
- `SPECULAR` is wired to `cornea_ior` (~1.376) → F0 ≈ 2.5% via the standard `((n−1)/(n+1))²` formula. Godot's default `SPECULAR = 0.5` (F0 = 4%) was visibly too hot.
- `ROUGHNESS` smoothly lerps from cornea-glossy (inside iris) to sclera-matte across a *wider* `cornea_t` band than the iris/sclera albedo cut, so cornea gloss tapers naturally into matte sclera instead of cliff-falling at the hard albedo boundary.

### Mesh authoring convention

**Mesh origin must be at the iris plane (z = 0 in object space).** This matches HDRP's HumanEyeModel.fbx convention. Authoring with origin at the eye's geometric center makes the iris fall behind the cornea bulge and renders as a "hollow eye" (the same artifact discussed in the Unity HDRP forum thread "Problem with HDRP eye shader, eye looks hollow"). The fix is mesh-side, not shader-side.

The current test mesh `moreEyes.glb` already follows this convention. The legacy HumanEyeModel.fbx does *not* — its origin sits at the cornea apex, with the eye center at z ≈ −0.48. Earlier port iterations carried an `eye_center_z` uniform to translate before applying HDRP math; the current shader assumes the canonical convention and does not need it. If a future mesh has an off-center origin, fix the mesh.

---

## Calibration

The two mesh-specific values are **`iris_radius`** (mesh-local OS units) and the **iris/sclera texture pair**. Everything else has a per-shader default that's empirically validated across the meshes tried so far.

### `iris_radius` — mesh-specific

`iris_radius` is in **mesh object-space units, not normalized**. It varies by orders of magnitude across meshes depending on authoring scale.

| Mesh | `iris_radius` |
|---|---|
| HDRP HumanEyeModel.fbx | 0.22 |
| moreEyes.glb (current test) | ~0.005175 |

The slider's `hint_range` is intentionally permissive (0.0001 → 0.01 currently; widen if needed). Calibrate by eye against `debug_mode == 4` (surface mask: green = iris, red = sclera) until the green region matches the visible iris pattern in the texture.

There is **no shader-side auto-fit** for `iris_radius`. The cornea-bulge extent isn't readable from per-fragment data; HDRP doesn't auto-fit either. This is a per-mesh constant, calibrated once.

### Texture authoring conventions (must honor when sourcing new textures)

**Iris textures bake a bright outer fiber band, not a dark anatomical limbus.** HDRP's Iris02_BC / Iris03_BC, the supplied `eyeBrown_albedo`, and most other production iris textures bake golden / yellow fibers at `r_uv ≈ 0.93–1.0`. The dark limbus is *drawn by the shader*, not by the texture. If we sample at `r_uv = 1.0` (which `cornea_refraction` + circle clamp routinely lands on at oblique angles or with too-large `iris_radius`), the bright fiber band reads as a "white rim" around the iris.

The `iris_uv_max_r` parameter (default 0.92) crops the outer 8% of the iris UV so the shader never samples that band. The shader's own `limbus_ring` then draws the dark band, centered on `iris_radius`.

**Sclera textures have an "iris hole" gray spot + bright halo at the texture center.** Mesh UVs map the iris area to the texture center, expecting iris content to overlay it. Both HDRP's Sclera_BC and our `eyeSclera.png` follow this convention. With a narrow blend zone the halo can leak as a "white ring" near the iris/sclera boundary. The current mitigation is a *hard cut* at `iris_radius` for `surface_mask` (driving ALBEDO + SSS), which keeps the boundary sharp and prevents halo bleed.

### Sample calibration (current default in `eye_material.tres`)

```
iris_radius                       0.005175       # moreEyes.glb specific
iris_uv_max_r                     0.92           # HDRP texture convention
limbus_half_width_iris_units      0.15           # exponential 1−exp(−6t) ring
limbus_intensity                  0.431          # HDRP M_EyeSG2.mat
limbus_fade                       0.41           # HDRP M_EyeSG2.mat
cornea_outer_radius_iris_units    1.3            # cornea covers iris + 30% past
cornea_ior                        1.376          # HDRP M_EyeSG2.mat (water-like)
iris_apparent_depth               0.0            # HDRP demo default; >0 smears
iris_normal_strength              0.88           # HDRP M_EyeSG2.mat
sclera_normal_strength            0.1            # HDRP M_EyeSG2.mat
cornea_smoothness                 0.9            # higher than HDRP's 0.025 — see below
sclera_smoothness                 0.671          # tuned per mesh
sclera_sss_strength               0.0            # see "Why SSS is off"
iris_sss_strength                 0.0
iris_pom_depth                    0.05           # iris-fiber parallax in UV units
```

**`cornea_smoothness` 0.9 not 0.025**: HDRP's M_EyeSG2.mat sets it to 0.025, which sounds matte. HDRP relies on its separate cornea-spec layer + caustic LUT for the wet-eye look, so a low base smoothness is fine. A single-layer Godot port has nothing standing in for that layer — the diffuse+spec BSDF must carry the gloss alone. Empirically 0.7–0.9 is required for the eye to read as wet rather than chalky.

---

## Why specific decisions

### Why iris bumps don't go through `NORMAL`

Godot's environment reflection and IBL use `NORMAL` directly without going through the `light()` function. Bumping `NORMAL` with the iris fiber detail makes the cornea's mirror reflection look bumpy / slimy in any HDR-lit scene.

The shader instead derives an **AO term from the iris height map's gradient** and applies it as multiplicative ALBEDO darkening. Valleys (height < neighbors) darken; peaks pass through. Combined with parallax occlusion mapping (`iris_pom`), this gives convincing fiber relief without polluting the spec response. HDRP gets this for free via its two-normal model (`specularNormal` flat in iris, `diffuseNormal` bumped); single-layer Godot has to fake it.

### Why SSS is off by default

HDRP uses wavelength-dependent diffusion profiles (`ScleraDiffusionProfile` scatters red-dominant; `IrisDiffusionProfile` is more selective). Godot's screen-space SSS is a single isotropic blur — at any meaningful strength it blurs iris fibers and sclera vessels into mush. User direction during port: *"Leave SSS at 0.0 that blurrs the shit out of everything."* The uniforms exist (`iris_sss_strength`, `sclera_sss_strength`) for future tuning if a non-screen-space SSS path becomes available; default is 0.

### Why `iris_apparent_depth` defaults to 0

`iris_apparent_depth > 0` shifts the virtual iris plane behind z=0 to fake additional lens parallax. Anything > 0 introduces lateral iris-UV drift at oblique view angles that smears iris-edge fibers across the boundary — *"messes everything up"* in user testing. HDRP M_EyeSG2.mat (Vector1_76BF2124) also defaults to 0; raise only if a specific mesh genuinely needs exaggerated lens parallax.

### Why surface mask is a hard cut, not HDRP's `^8` blend

HDRP's `ScleraIrisBlend` raises `(osRadius − irisRadius) / 0.04` to the 8th power, giving a narrow but *smooth* iris/sclera transition. The Godot port uses a hard cut (`r_xy < iris_radius`) for `ALBEDO` and `SSS_STRENGTH` because user direction was explicit: *"the sclera needs a hard cut"*. The cornea / sclera *roughness* fade (`cornea_t`) is independently a wider smoothstep band so cornea gloss tapers naturally — the hard cut is on albedo and SSS only.

### Why a single `limbus_ring` instead of HDRP's two functions

HDRP has separate `IrisLimbalRing` (inside iris, fades inward) and `ScleraLimbalRing` (outside iris, fades outward). The Godot port collapses these into one function keyed on `abs(r_xy − iris_radius)` with `1 − exp(−6t)` exponential decay. The exponential shape concentrates the darkening at the boundary — most of the band is already at full brightness within ~1/3 of `half_width` — so the ring reads as a sharp anatomical line rather than a smeared gradient. User direction was explicit: *"exponential, fading over short distance."*

---

## Gotchas (cross-references to memory)

The port surfaced two reusable Godot lessons saved to user-memory:

- **`reference_godot_normal_map_breaks_lighting.md`** — Writing `NORMAL_MAP` (even the identity `vec3(0,0,1)`) in Godot 4.6 spatial fragment shaders corrupts the reconstructed world `NORMAL` on most fragments of curved meshes. The fix is **manual TBN reconstruction**:

  ```glsl
  NORMAL = normalize(TANGENT  * tangent_space_normal.x
                   + BINORMAL * tangent_space_normal.y
                   + NORMAL   * tangent_space_normal.z);
  ```

  The eye shader now does this directly (see fragment shader, near `ALBEDO = eye_color;`). Bisected against stock `SphereMesh` + `OmniLight`. `TANGENT` and `BINORMAL` are available in fragment when the mesh has tangents (FBX/GLB imports with `meshes/ensure_tangents=true` supply them).

- **`feedback_diagnostic_kill_suspect.md`** — When a visual artifact has multiple plausible causes (texture, shader math, lighting, geometry), zero out one candidate at a time before writing a fix. The "white ring" in the eye port turned out to be cornea spec catching the cornea-bulge curvature transition, *not* the texture's halo — but several iterations were burned on UV remap / luminance dampening / suppression-band fixes before the diagnostic ablation revealed the real cause.

- **`feedback_use_user_test_setup.md`** — The user placed `Front` / `Side` `Camera3D` nodes in `more_eyes.tscn` deliberately for artifact-revealing angles. Any harness or screenshot tooling must read those existing cameras by name (`inst.find_child("Side", true, false) as Camera3D`) rather than fabricating its own. Same applies to tuned shader_parameters in `.tres` — preserve them rather than reverting to "sensible defaults".

---

## Limitations

1. **No caustic LUT.** HDRP's caustic highlights use a 3D-texture LUT (`Caustic_LUT`) that doesn't translate to Godot's stock pipeline. Could be approximated procedurally if the visual loss is significant; not currently a priority.
2. **No wavelength-dependent SSS.** Godot SSS is isotropic; HDRP's `ScleraDiffusionProfile` (red-dominant) and `IrisDiffusionProfile` are dropped. SSS is off by default; the uniforms remain in case a non-screen-space SSS path lands.
3. **No automatic gaze IK.** `iris_offset` is a manual saccade control. A gaze IK driver belongs in Reverie (attention/gaze module) per `docs/architecture/Reverie_Planning.md` §2.6, not in the shader.
4. **No eyelid occlusion / blink.** Requires separate eyelid geometry; out of scope for this shader.
5. **`iris_radius` per-mesh calibration.** No shader-side auto-fit; every new mesh needs the calibration step in §"Calibration" above.

---

## Future work

- Procedural pupil tinting (heterochromia, character variation) by parameterizing `iris_tint`.
- Sclera redness modulation hookup to Reverie's emotional state writes (`flush_intensity`-equivalent for sclera).
- Per-character iris pattern variation via texture array (Reverie persona-driven).
- Optional cornea overlay reinstated if a specific shot needs HDRP-grade cornea highlight separation. The `eye.gdshader.bak2` archive in the eye/ folder preserves the two-layer attempt.

---

## References

- HDRP source (kept locally, gitignored): `blender/eyes/HDRP Eyes/references/Eye.hlsl`, `EyeUtils.hlsl`. The shader's function names mirror HDRP's (`get_iris_uv` ← `GetIrisUVLocation`, `cornea_refraction` ← `CorneaRefraction`, etc.) so cross-referencing is direct.
- HDRP material presets: `M_EyeSG 2.mat` / `M_EyeSG 3.mat` (Vector1_XXXXXXXX hashes; the cryptic→semantic mapping is documented inline in the shader uniforms with HDRP source-line references).
- Godot 4.6 spatial-shader docs for `NORMAL` / `NORMAL_MAP` / `TANGENT` / `BINORMAL` semantics.
- Memory entries: `project_eye_shader_state.md`, `reference_hdrp_eye_shader.md`, `reference_godot_normal_map_breaks_lighting.md`, `feedback_diagnostic_kill_suspect.md`, `feedback_use_user_test_setup.md`.
