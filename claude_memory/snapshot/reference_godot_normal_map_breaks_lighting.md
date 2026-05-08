---
name: Godot 4.6 NORMAL_MAP write breaks lighting on curved meshes
description: Writing NORMAL_MAP in spatial fragment shaders produces junk world NORMAL on large regions of curved geometry; use manual TBN → NORMAL instead
type: reference
originSessionId: cab7ef84-cf74-48ef-8553-538b7b5fca6c
---
In Godot 4.6 spatial shaders, writing `NORMAL_MAP` in `fragment()` — even the identity value `vec3(0.0, 0.0, 1.0)` — corrupts the reconstructed world `NORMAL` on most fragments of curved meshes (verified on stock `SphereMesh`, debug_mode==5 / unlit-equivalent test). The result is a sharp crescent of correctly-lit pixels and the rest going black-NdotL. It looks like a shadow but no light position can fix it — the surface thinks it faces the wrong way.

Symptoms:
- "Shadow" persists when you put a spotlight at the camera.
- `unshaded` render_mode hides the bug (lighting bypassed → ALBEDO shows correctly across the whole mesh).
- Removing `NORMAL_MAP =` writes (or replacing with `NORMAL =`) restores correct lighting.

**Fix — manual TBN in fragment:**

```glsl
NORMAL = normalize(TANGENT  * tangent_space_normal.x
                 + BINORMAL * tangent_space_normal.y
                 + NORMAL   * tangent_space_normal.z);
```

`TANGENT` and `BINORMAL` are available in the fragment stage when the mesh has tangents. `SphereMesh` and FBX/GLB imports with `meshes/ensure_tangents=true` both supply them.

Why: the engine's TBN reconstruction for `NORMAL_MAP` produces degenerate output across curved hemispheres in 4.6 — exact root cause not investigated, may be a regression. Manual TBN bypasses the engine code path.

Bisect that proved it (eye.gdshader, plain SphereMesh, OmniLight at camera):
- `ALBEDO=1; NORMAL_MAP=(0,0,1); ROUGHNESS=1` → broken (crescent only)
- `ALBEDO=1; NORMAL=NORMAL; ROUGHNESS=1`     → full sphere lit
- `ALBEDO=1; ROUGHNESS=1` (no normal write)  → full sphere lit

Encountered: 2026-05-06 on HDRP eye shader port (`game/assets/materials/eye/eye.gdshader`).
