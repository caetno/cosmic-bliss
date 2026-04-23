# DPG-Godot Implementation Audit

Comparison of the Godot port against the Unity reference source
(`~/Projects/dpg-unity-ref/`) and the porting plan (`PLAN.md`).

**Audit date**: 2026-04-16
**Implemented phases**: 1 (math foundation), 2 (core data pipeline), 3 (node system — partial)
**Remaining phases**: 4 (deformation + listeners), 5 (editor tooling)

---

## 1. File-by-file status (PLAN.md §3 + §9)

### Core simulation layer

| Plan file | Status | Notes |
|---|---|---|
| `catmull_spline.h/cpp` | **[DONE]** | Full feature parity with Unity `CatmullSpline.cs`. Centripetal parameterization, distance LUT, binormal LUT, GPU data packing, closest-point search all implemented. Constants (SUB_SPLINE_COUNT=8, LUT_COUNT=32) match Unity. |
| `dpg_jiggle_settings.h/cpp` | **[DONE]** | All 5 properties match Unity `JiggleTreeInputParameters`: gravity_multiplier, friction, angle_elasticity, length_elasticity, elasticity_soften. |
| `dpg_jiggle_chain.h/cpp` | **[DONE]** | Verlet integration with gravity, friction, angle elasticity (with soften dead-zone), and length elasticity constraints. Matches Unity `JiggleRig` core loop. |
| `dpg_penetrator_data.h` | **[DONE]** | Plain struct with mesh_instance, root, forward/right/up, girth_data, length. Simplified vs Unity (no RendererSubMeshMask, no rootPositionOffset). |
| `dpg_girth_data.h/cpp` | **[PARTIAL]** | CPU barycentric triangle sampling implemented. Missing features listed below. |
| `dpg_penetrator.h/cpp` | **[PARTIAL]** | Core material pipeline works. Missing features listed below. |
| `dpg_jiggle_deform.h/cpp` | **[PARTIAL]** | Physics chain simulation works. Missing features listed below. |
| `dpg_penetrable.h/cpp` | **[DONE]** | Abstract base with signals (penetrated/unpenetrated), virtual set/clear_penetrator, GDScript wrappers. |
| `dpg_penetrable_basic.h/cpp` | **[PARTIAL]** | Path marker resolution, spline building, penetrator registration, signal emission all work. Missing features listed below. |
| `register_types.h/cpp` | **[DONE]** | All 8 classes registered. DPGPenetrable registered as abstract. |

### Rendering layer

| Plan file | Status | Notes |
|---|---|---|
| `penetrator.gdshader` | **[DONE]** | Spatial shader with vertex deformation via `to_catmull_rom_space()`, PBR fragment with albedo/metallic/roughness/normal_map. `uniform bool curve_skinning_enabled` toggle. |
| `penetration_lib.gdshaderinc` | **[PARTIAL]** | Core deformation ported: distance LUT lookup, spline eval, binormal interpolation, angle correction, Rodrigues rotation. Missing: truncation/spherize, clipping. |
| `girth_unwrap.glsl` | **[TODO]** | Plan calls for a GLSL compute shader. Current implementation uses CPU-side barycentric sampling in DPGGirthData instead. |
| `PenetratorRenderers` integration | **[DONE]** | Merged into DPGPenetrator — unique ShaderMaterial per instance, per-frame uniform updates. This matches the plan's recommendation. |
| `RendererSubMeshMask` → `dpg_submesh_mask.h/cpp` | **[TODO]** | Not implemented. Multi-surface mesh masking not available. |

### Spline dependency

| Plan file | Status | Notes |
|---|---|---|
| `catmull_spline.h/cpp` | **[DONE]** | See core simulation layer above. |

### Jiggle physics dependency

| Plan file | Status | Notes |
|---|---|---|
| `dpg_jiggle_settings.h/cpp` | **[DONE]** | See core simulation layer above. |
| `dpg_jiggle_chain.h/cpp` | **[DONE]** | See core simulation layer above. |

---

## 2. Per-class feature gap analysis

### DPGGirthData — [PARTIAL]

Implemented:
- CPU barycentric triangle sampling into FORMAT_RF texture
- Cylindrical UV projection (forward distance, angle)
- Max-girth tracking per texel
- `sample_girth(u, v)` for CPU-side queries

Missing vs Unity `GirthData` + `GirthFrame`:
- **No GPU rasterization** — Unity uses `GirthUnwrapRaw.shader` + CommandBuffer to rasterize the mesh into girth space. Our CPU fallback works but is lower quality and slower for dense meshes.
- **No blendshape support** — Unity bakes a `GirthFrame` per blendshape and composites them at runtime with additive/subtractive blits. We only bake the base mesh.
- **No detail map generation** — Unity produces a `detailMap` (Texture2D) encoding per-texel deviation from the average girth curve. Used by `PenetrableProcedural` for fine deformation.
- **No knot force curve** — Unity builds an `AnimationCurve localGirthRadiusCurve` from the readback and computes its piecewise derivative for knot force. We have no CPU girth curve.
- **No world offset curves** — Unity computes `localXOffsetCurve` / `localYOffsetCurve` for off-center mesh geometry. We assume axis-centered meshes.
- **No girthScaleFactor** — Unity tracks the max girth radius for scale normalization in the shader. We don't expose this.
- **No SkinnedMeshRenderer bone masking** — Unity filters vertices by bone weight to the penetrator root. We use all vertices.

### DPGPenetrator — [PARTIAL]

Implemented:
- ShaderMaterial creation from `penetrator.gdshader`
- Auto-length from mesh AABB
- Data texture packing + per-frame upload
- Orientation uniforms (forward/right/up in world space)
- Girth baking at `_ready()`
- External spline input from penetrable
- Debug gizmo (spline curve + frame vectors + orientation axes)
- Target penetrable connection at `_ready()`

Missing vs Unity `Penetrator` + `PenetratorRenderers`:
- **No squash-and-stretch** — Unity has `PenetratorSquashStretch` class with fixed-timestep Verlet simulation for length elasticity. The `squashAndStretch` factor scales `penetratorLength` dynamically.
- **No `_PenetratorOffsetLength` / `_PenetratorStartWorld`** — Unity sends `baseDistanceAlongSpline` and the spline position at that distance as shader uniforms. These are used for the penetrator-prepend-points system.
- **No `_DistanceToHole`** — Unity sends the distance from spline start to the hole opening, used for clipping.
- **No `_TruncateLength` / `_GirthRadius`** — Unity sends truncation point and girth at truncation for spherize effect.
- **No `_StartClip` / `_EndClip`** — Unity sends clipping range distances for visibility clipping.
- **No `_DPGBlend`** — Unity has a per-renderer blend factor (0 or 1) for enabling/disabling deformation.
- **No multiple renderer support** — Unity's `PenetratorRenderers` manages a list of renderers with per-renderer `MaterialPropertyBlock`. We support only one MeshInstance3D.
- **No `auto_penetrate`** — Plan §9 mentions proximity-based detection, not implemented.
- **No `GetSpline()` public accessor** — Unity exposes `cachedSpline` for external queries.
- **No `TryGetTip()` / `TryGetPenetrableHoleDistanceAlongSpline()`** — Unity utility methods not ported.
- **No `PenetrationArgs` struct** — Unity passes a rich struct through the penetration pipeline. We use a Dictionary in the signal.
- **No `LerpPoints()` static helper** — Unity lerps between jiggle points and penetrable points for smooth insertion.

### DPGJiggleDeform — [PARTIAL]

Implemented:
- Chain initialization from penetrator length
- Per-frame simulation with DPGJiggleSettings
- Override `_build_spline_points()` to return simulated points
- Proper process priority ordering (200)

Missing vs Unity `PenetratorJiggleDeform`:
- **No curvature properties** — Unity has `leftRightCurvature`, `upDownCurvature`, `baseUpDownCurvatureOffset`, `baseLeftRightCurvatureOffset` for static pose bending.
- **No `SetPoseFromCurvature()`** — Unity configures the jiggle chain rest pose from curvature angles.
- **No `linkedPenetrable`** — Unity has a direct serialized reference to the target penetrable, with auto-insertion logic.
- **No squash-and-stretch integration** — Unity's `PenetratorSquashStretch` drives `squashAndStretch` based on insertion state.
- **No `penetratorLengthFriction` / `penetratorLengthElasticity`** — Unity tuning for length spring.
- **No `knotForce` property** — Unity scales the girth-derivative force by a configurable multiplier.
- **No `GetPenetrableSplineInfo()`** — Unity computes insertion depth, lerp factor, and penetration args.
- **No `isAnimatedJigglePhysics`** — Unity flag for runtime jiggle parameter updates.
- **No jiggle prefab system** — Unity instantiates a Transform hierarchy for the jiggle chain. We use a flat point array.

### DPGPenetrableBasic — [PARTIAL]

Implemented:
- Path marker resolution (Array of NodePath → global positions)
- Spline building with penetrator root prepended
- `set_penetrator()` / `clear_penetrator()` with signal emission
- Properties: hole_start_t, friction, should_truncate, truncate_t, should_clip

Missing vs Unity `PenetrableBasic`:
- **No `ClippingRange` struct** — Unity has `startNormalizedDistance`, `endNormalizedDistance`, `allowAllTheWayThrough`. We have a bool `should_clip` but no range values.
- **No `KnotForceSampleLocation` array** — Unity samples girth derivative at configurable points along the path for force feedback.
- **No `GetPenetrationResult()` override** — Unity's `PenetrableBasic` computes a rich `PenetrationResult` (knotForce, penetrableFriction, holeStartDepth, tipIsInside, truncation, clippingRange). Our signal only sends a stub Dictionary.
- **No `GetHole()` method** — Unity exposes hole position + normal for external queries.
- **No gizmo drawing** — Unity draws colored spheres at clipping/truncation/hole-start/knot-force positions.
- **Properties stored but not used** — `should_truncate`, `truncate_t`, `should_clip`, `friction` are exposed but never read by the rendering pipeline or passed to the shader.

### penetration_lib.gdshaderinc — [PARTIAL]

Implemented:
- `read_spline_float()` / `read_spline_vec3()` — data texture access
- `distance_to_param()` — distance LUT lookup with linear scan
- `get_segment_local_t()` — segment/local-t decomposition
- `eval_segment_position()` / `eval_segment_tangent()` — polynomial evaluation
- `sample_binormal()` — binormal LUT interpolation
- `rotate_around_axis()` — Rodrigues rotation (matches Unity's `RotateAroundAxisPenetration`)
- `to_catmull_rom_space()` — core vertex/normal deformation

Missing vs Unity `Penetration.cginc`:
- **No `_DPG_TRUNCATE_SPHERIZE` logic** — Unity spherizes vertices past the truncation point using girth radius. Not implemented in shader.
- **No `_DPG_CURVE_SKINNING` compile-time toggle** — We use `uniform bool curve_skinning_enabled` (plan recommendation), which is correct, but the truncate keyword is missing.
- **No clipping logic** — Unity uses `_StartClip` / `_EndClip` to discard or scale vertices. Not in our shader.
- **No `GetDeformationFromPenetrators_float()`** — The penetrable-side deformation function that pushes orifice vertices outward based on girth maps. This is the `PenetrableProcedural` shader path.
- **No `PenetratorData` struct on GPU** — Unity sends per-penetrator render data for the penetrable deformation path. Not applicable until PenetrableProcedural is implemented.
- **No tangent output** — Unity transforms `worldTangent` (float4 with bitangent sign). We only transform position and normal.

---

## 3. Phase 4 — Not yet implemented

| Plan file | Status | Unity equivalent |
|---|---|---|
| `dpg_procedural_deform.h/cpp` | **[TODO]** | `PenetrableProcedural.cs` — runtime ArrayMesh vertex manipulation for orifice bulging. Uses UV2 baked distances + per-penetrator girth maps. |
| `dpg_simple_blendshape.h/cpp` | **[TODO]** | Not in Unity package (plan §7 lists as custom listener). Drives `MeshInstance3D.set_blend_shape_value()` based on girth at a sample point. |
| `dpg_push_pull_blendshape.h/cpp` | **[TODO]** | Not in Unity package (plan §7). Three blendshapes + offset correction bone. |
| `dpg_lengthwise_blendshape.h/cpp` | **[TODO]** | Not in Unity package (plan §7). Blendshape driven by penetration depth. |
| `dpg_clip_listener.h/cpp` | **[TODO]** | Not in Unity package (plan §7). Reports clipping range back to penetrator. |
| `dpg_submesh_mask.h/cpp` | **[TODO]** | `RendererSubMeshMask.cs` — bitmask for multi-surface mesh selection. |

---

## 4. Phase 5 — Not yet implemented

| Plan file | Status | Unity equivalent |
|---|---|---|
| `dpg_editor_plugin.h/cpp` | **[TODO]** | `PenetratorInspector` + `PenetrableProceduralEditor` custom inspectors. |
| Inspector "Bake Girth" button | **[TODO]** | Unity triggers bake from `PenetratorDataPropertyDrawer`. |
| Inspector "Bake Mesh" button | **[TODO]** | Unity triggers UV2 bake from `PenetrableProceduralEditor`. |
| Editor gizmos (spheres for clip/truncate/hole/knot points) | **[TODO]** | Unity draws in `OnDrawGizmosSelected()`. |

---

## 5. Unity features NOT in the plan

These exist in the Unity reference but are not mentioned in PLAN.md:

| Feature | Unity file | Description |
|---|---|---|
| **PenetrationManager** | `PenetrationManager.cs` | Singleton coordinator with explicit read/write phases in LateUpdate. Guarantees all penetrators read, then all write, in deterministic order. Plan §12 mentions it as a possibility but doesn't include it in the file map. |
| **PenetratorSquashStretch** | `PenetratorJiggleDeform.cs` (inner class) | Fixed-timestep (0.02s) Verlet simulation for length elasticity, driven by insertion velocity + knot force. Separate from jiggle physics. |
| **Spline point lerping** | `Penetrator.LerpPoints()` | Arc-length-aware interpolation between jiggle and penetrable point sets during insertion. Prevents snapping. |
| **PenetratorAudioSlide** | `Assets/PenetratorAudioSlide.cs` | Audio listener that plays sliding sounds based on penetration velocity. |
| **PenetratorAudioTrigger** | `Assets/PenetratorAudioTrigger.cs` | Audio listener that plays trigger sounds on penetration/unpenetration events. |
| **GirthFrame blendshape delta system** | `GirthFrame.cs` | Bakes per-blendshape girth deltas and composites them at runtime. |
| **Additive/Subtractive blit shaders** | `AdditiveBlit.shader`, `SubtractiveBlit.shader` | Used for blendshape girth compositing on GPU. |
| **PenetrableShader** | `Assets/PenetrableShader.shader` | Separate shader for the penetrable-side orifice deformation (not the penetrator shader). |
| **Bounds generation** | `CatmullSpline.GenerateBounds()` | Per-segment AABB computation for fast closest-point broad-phase. |
| **GetClosestTimeFromPositionFast** | `CatmullSpline.cs` | Bounds-accelerated closest-point search. We only have brute-force sampling. |
| **GetLengthFromSubsection** | `CatmullSpline.cs` | Arc-length of a specific sub-range of the spline. Used extensively by PenetratorJiggleDeform. |
| **CatmullSplineData struct** | `CatmullSplineData.cs` | GPU-side struct matching the StructuredBuffer layout. Our equivalent is the data texture packing. |
| **PenetrableBasic.GetHole()** | `PenetrableBasic.cs` | Returns hole world position + normal. Useful for alignment/audio. |

---

## 6. Architectural drifts from the plan

### Intentional / acceptable drifts

1. **Girth baking method**: Plan recommends compute shader (`girth_unwrap.glsl`). Implementation uses CPU barycentric sampling. This is functionally correct and simpler, though lower quality for complex meshes. Plan §8 lists this as "Option A" (compute) vs "Option B" (SubViewport) — we chose an unlisted Option C (CPU).

2. **No `dpg_types.h`**: Plan §14 lists a `dpg_types.h` for PenetrationResult, ClippingRange, Truncation structs. Instead, we use a Dictionary for the signal payload. This is simpler but less type-safe and doesn't support the full Unity `PenetrationResult`.

3. **Jiggle chain architecture**: Plan maps Unity's `JiggleRig` (Transform hierarchy) to a flat point-array Verlet chain. This is a deliberate simplification — no Transform-based jiggle prefab needed. Acceptable but means no per-point rotation data.

### Concerning drifts

1. **Missing prepend-point system**: Unity's `PenetratorData.GetSpline()` prepends two base points (one behind the root, one at the root) and appends a tail point. Our `DPGPenetrableBasic._process()` only prepends the penetrator origin. This means the spline lacks the behind-root control point, which affects curvature near the base.

2. **No `baseDistanceAlongSpline`**: Unity tracks where the "actual" penetrator starts along the full spline (after the prepended base points). This offset is sent to the shader as `_PenetratorOffsetLength`. Our shader receives no offset — it assumes the spline starts at the penetrator root. This could cause incorrect deformation if the spline construction changes.

3. **Properties declared but not plumbed**: `should_truncate`, `truncate_t`, `should_clip`, and `friction` on DPGPenetrableBasic are exposed to the inspector but never affect rendering. The shader has no truncation or clipping uniforms. This will confuse users who configure these properties expecting visual results.

---

## 7. Summary

| Phase | Status | Completion |
|---|---|---|
| Phase 1 — Math foundation | **Complete** | CatmullSpline, JiggleChain, JiggleSettings all done |
| Phase 2 — Core data pipeline | **Mostly complete** | Shader lib + main shader done. Girth bake is CPU-only (no compute shader). |
| Phase 3 — Node system | **Partial** | Core nodes work (penetrator ↔ penetrable connection, material pipeline, physics). Missing: squash-stretch, curvature, clipping, truncation shader path, rich PenetrationResult. |
| Phase 4 — Deformation + listeners | **Not started** | 0/5 classes implemented |
| Phase 5 — Editor tooling | **Not started** | 0/3 items implemented |

---

## 8. Knot force status (Part 1 audit for `feature_knot_and_constrictions.md`)

**Audit date**: 2026-04-18

### Where the pipeline lives

| Stage | Code | Behavior |
|---|---|---|
| Per-sample radial derivative | `DPGGirthData::get_knot_force(world_dist, world_length)` (`src/dpg_girth_data.cpp:188`) | Central-difference on the max-across-angle radius column of the baked girth image. Returns radius-per-world-length signed value. |
| Sample point authoring | `DPGPenetrableBasic.knot_force_sample_points` (PackedFloat32Array) | User-authored normalized body-arc T values. |
| Aggregation + spring-damper | `DPGProceduralDeform::_process()` (`src/dpg_procedural_deform.cpp:239–278`) | Sums per-sample derivatives, scales by `knot_force_strength * 7.0`, feeds into `SquashStretchSim::tick()`. Fixed 50 Hz integrator ported from Unity `PenetratorSquashStretch`. |
| Output | `DPGProceduralDeform` → `penetrator.set_squash_stretch(...)` + shader `squash_stretch` uniform | Drives lengthwise squash/stretch on the penetrator mesh and the orifice deform shader. |

### What works
- Sample-point iteration and girth-texture sampling are correct. World distance on pen = `world_distance + sample_t * marker_arc`, which keeps per-frame position-on-the-pen stable as the orifice slides.
- `get_knot_force` uses max-across-angle per column — the geometrically correct interpretation of the "knot" radius.
- Spring-damper integration (`SquashStretchSim::tick`) is a faithful port of Unity's `PenetratorSquashStretch` (fixed 0.02 s tick, same velocity-lerp + knot-impulse + elastic return curve).
- `hole_start_depth` is computed correctly on the marker spline at engagement time.

### What is broken / missing

1. **`penetrated` signal dict is a one-shot snapshot**
   - `DPGPenetrableBasic::set_penetrator()` (`src/dpg_penetrable_basic.cpp:459–477`) emits the signal exactly once, with `knot_force = 0.0f` hardcoded and `tip_is_inside = false` hardcoded.
   - No per-frame re-emission, so consumers that read the dict never see live values.
   - `DPGBlendshape` / `DPGSimpleBlendshape` currently only read `hole_start_depth` and `spline` from this dict — they happen to work because those are frozen at engagement. Anything needing live knot force / tip state has no path to receive it.

2. **`tip_is_inside` is not implemented**
   - Always `false`. Would need a per-frame check of the penetrator's active spline against the body-arc range.

3. **`hole_start_depth` is not re-computed when markers move**
   - Frozen at engagement time. If path markers animate, the listeners' reference becomes stale.

4. **Live knot force is not exposed outside `DPGProceduralDeform`**
   - The only public consumer of the summed knot force is the squash-stretch sim. Other listeners (e.g. constriction points in Part 2) cannot read per-frame knot contributions without reproducing the computation.

5. **"Path diameter at T" is not tracked**
   - The penetrable has no notion of an orifice diameter along the spline. Part 2 introduces this via `DPGConstrictionPoint.size`, but nothing exists today.

### What needs to be built before Part 2

- Move the per-frame knot-force aggregation (or at least the per-sample girth reads) into `DPGPenetrableBasic::_process()` so the penetrable owns the computation and can publish it in a result dict.
- Re-emit `penetrated` each frame with live values, **or** add a new `Dictionary get_live_result()` accessor that listeners poll at priority < 500. The re-emit path matches the Unity "event per frame" model; the accessor path is cheaper and matches the existing `DPGBlendshape` / `DPGSimpleBlendshape` priority-0 polling pattern.
- Populate `tip_is_inside` by comparing the penetrator's tip arc position to `body_start_dist + hole_start_t * body_arc`.
- Update `hole_start_depth` each frame on the marker spline.
- Add aggregation slots to the result dict that Part 2's constriction points can contribute to (`constriction_forces`, `total_resistance_force`, `total_friction_force`, and a `knot_force` that sums both girth-derivative and constriction-resistance contributions, as the spec requires).

### Temporary instrumentation

Added a per-60-frame debug print in `DPGProceduralDeform::_process()` (`src/dpg_procedural_deform.cpp`, guarded by `_audit_frame_count`). Logs each `sample_t`, pen-girth max at that T, per-sample `get_knot_force` result, and the aggregated scaled knot force + current squash_stretch. Verifies reactivity when the penetrator's girth changes via blendshape/scale. **Remove once Part 1 is signed off.**
