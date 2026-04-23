# dpg — Salvage Reference

**Status: reference-only. Not a buildable extension.** This directory has been
trimmed to the spline math worth scavenging for `extensions/tentacletech/src/spline/`.
Everything else from the original Unity→Godot port (penetrator, penetrable,
girth data, procedural deform, blendshape, bone offset modifier, editor plugin,
shaders, build system) has been deleted.

The original DPG was a port of naelstrof's DynamicPenetrationForGames (Unity). It
went broken and is superseded by TentacleTech. Do not try to resurrect it.

## What remains

```
dpg/
├── CLAUDE.md                    (this file)
├── AUDIT.md                     (file-by-file port status — useful reference when porting catmull_spline across)
└── src/
    ├── catmull_spline.{h,cpp}   (centripetal Catmull-Rom, arc-length LUT, parallel-transport binormals, GPU packing)
    └── dpg_math.h               (small math helpers; worth 2 minutes to read before porting)
```

## How to use this

When implementing `CatmullSpline` for TentacleTech (see Phase 1 in
`docs/architecture/TentacleTech_Architecture.md` §5.1):

1. Read `src/catmull_spline.h` — the API surface maps almost 1:1 to the TentacleTech
   spec, minus the `set_points_with_entry_tangent` case which is DPG-specific.
2. Port the algorithms (centripetal parameterization, distance LUT, parallel-transport
   binormal LUT, GPU packing) into `extensions/tentacletech/src/spline/catmull_spline.{h,cpp}`.
3. **Do not copy verbatim.** Rename, drop DPG-specific concerns (entry tangent),
   match the TentacleTech API exactly as specified in `TentacleTech_Architecture.md` §5.1.
4. After port, delete this directory entirely.

## Unity → Godot coordinate system gotcha

Both are right-handed Y-up, but forward differs: Unity `+Z`, Godot `-Z`. If you
reference the original Unity source (`com.naelstrof.splines CatmullSpline.cs`),
check every axis-derived vector for a sign flip. The existing port in
`catmull_spline.cpp` already handles this correctly — use it as the reference
rather than the Unity source if in doubt.
