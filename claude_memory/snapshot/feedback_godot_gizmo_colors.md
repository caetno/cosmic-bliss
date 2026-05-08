---
name: Godot custom gizmos must avoid orange-yellow
description: Custom EditorNode3DGizmoPlugin colors must contrast with Godot's default Skeleton3D bone gizmo, which is orange-yellow
type: feedback
originSessionId: 8768f07d-d49b-448e-ae9c-61f4e9166246
---
When designing colors for a custom `EditorNode3DGizmoPlugin` that overlays a `Skeleton3D` (or any scene with one), avoid orange / yellow / warm-amber hues. Godot's default Skeleton3D bone gizmo paints orange-yellow lines from each bone's origin to its tail and to children, producing a dense fan that **completely eats** matching hues — even fully saturated ones, even with `on_top=true`.

**Why:** Verified in screenshot from `extensions/marionette/img/tripod_colors.png` — first attempt at "warm/cool" palette (muscle X = orange, Y = lime) painted lines that visually merged with the default skeleton fan and couldn't be told apart.

**How to apply:**
- Custom gizmo palette starting points: magenta / cyan / white for one tripod, pure R / G / B for another, pure yellow only as a flag color (e.g., the Marionette unmatched-bone marker).
- Don't try to make hierarchy out of saturation — fully saturate everything and use **size** to disambiguate layers (e.g., 0.4 m muscle frame vs 0.15 m per-bone tripod).
- 0.08 m or shorter for per-bone marks is too small on a dense humanoid (84 bones); the default skeleton fan drowns them. ~0.15 m is the floor for legibility at typical orbit-camera distances.
- `EditorNode3DGizmo.add_lines` has no thickness parameter in Godot 4.6 — line thickness is always 1 px. Faking thicker lines means stacking parallel offsets or switching to mesh draws; usually not worth it.
