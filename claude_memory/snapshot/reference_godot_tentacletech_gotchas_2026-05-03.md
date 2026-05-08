---
name: TentacleTech debugging gotchas (2026-05-03 session)
description: Non-obvious Godot/GDExtension behaviors that cost multiple iterations — top_level snapshot, edit-time _ready timing, .so reload, AABB syntax, etc. Reference for the next time something "should work but doesn't".
type: reference
originSessionId: 64e240d3-2b26-432b-bed2-3e7a8339518f
---
A long debugging session on TentacleTech runtime/edit-time gizmo alignment surfaced several Godot behaviors that aren't well documented and cost real iteration time. Notes for future-you.

## `top_level = true` doesn't render in world space when set after tree entry

When `top_level = true` is set on a Node3D *after* it has already entered the tree under a transformed parent, Godot snapshots the node's current `global_transform` as its new local transform (so it stays put visually) — then continues rendering with that captured transform applied to all mesh data. The intent "render in world space ignoring parent" is **not automatic** in this case.

**Symptom:** mesh data containing world-space coordinates gets rotated/translated a second time during render, producing visually "wrong" positions (e.g. world-vertical particles ended up rendering as a horizontal row at anchor height).

**Fix options:**
- Set `top_level = true` *before* the node enters the tree (e.g. in constructor, not `_ready()`)
- Or after setting top_level, explicitly reset `transform = Transform3D()` to identity
- Or (simplest, most robust): **don't use top_level at all** — let the node inherit the parent's transform, then convert your world-space data to layer-local in the draw call (`var inv = global_transform.affine_inverse(); for p in points: draw(inv * p)`). The parent transform projects it back to world during render.

The third option is what TentacleTech's runtime overlay layers do (`particles_layer.gd`, `constraints_layer.gd`, `environment_layer.gd`).

**Diagnostic:** if you suspect this, print `self.top_level`, `self.global_position`, and `self.global_transform.basis.z` from the affected node. If `top_level=true` but `global_transform` matches the parent's, that's it.

## GDExtension `_ready` timing at edit time is unreliable

For C++ GDExtension classes (`Tentacle` here), `_ready()` fires at edit time, **but** the editor instantiates the scene multiple times during load (initial → preview → final). Each instantiation goes through property setters → `NOTIFICATION_ENTER_TREE` → `_ready()` independently. Some passes happen with `is_inside_tree() == false` (during property loading), some happen with the final transform, some happen with intermediate states.

**Symptom:** rebuild logic gated on `is_inside_tree()` runs multiple times with different transforms during a single scene load. The "final" rebuild may not be the one you expect — it can end up at identity transform if the sequence ends with a reset state.

**Robust workaround for edit-time visualization:** don't depend on the live solver state at edit time. Compute the rest-pose layout directly in node-local coordinates from the static configuration (e.g. `Vector3(0, 0, -segment_length * i)` for an i-th particle along the chain axis). Editor selection / gizmo plugins should pull from authored properties, not live runtime state.

## GDExtension `.so` does NOT hot-reload — full Godot restart required

Editing `.cpp` + rebuild + reloading the scene is **not enough**. Godot caches the loaded `.so` for the lifetime of the editor process. Without a full close-and-reopen, you're testing the previous binary. This costs minutes of confusion when "my fix did nothing."

GDScript files in `gdscript/` and the runtime overlay scripts under `addons/.../scripts/` *do* hot-reload (with caveats — see static var lazy-init memory). Only the C++ binary requires a restart.

## Editor in-memory scene state vs `.tscn` on disk can diverge

When the user does "Reset Transform" or any inspector edit, the change lives in the editor's in-memory copy of the scene **until they save**. Subsequent edits to the `.tscn` from outside the editor don't affect the in-memory copy — and if the user later saves, their in-memory state overwrites the disk edits.

**Symptom:** "I changed `transform = Transform3D(...)` in the .tscn, but Godot still shows identity" — because the editor was holding a reset version in memory.

**Robust workaround:** when fixing a value the user has touched in the inspector, give them inspector instructions ("set Position to (0, 0.7, 0), Rotation to (-90, 0, 0), then Ctrl+S") rather than editing the `.tscn` directly. That syncs editor state with disk.

## Procedural mesh `custom_aabb` is set in `_bake()` and overrides `.tscn` values

`PrimitiveMesh` subclasses (`TentacleMesh` here) often set `custom_aabb` inside their bake/generate function. The `.tscn`-saved value loads first, but `_bake()` runs on first access (`_create_mesh_array` etc.) and overwrites it. Manually editing custom_aabb in the .tscn gets reverted on next bake.

**Fix:** change the value in the bake function itself, or expose an `@export` toggle for "tight rest-pose AABB vs. worst-case sphere AABB."

## `AABB(position, size)`, NOT `AABB(min, max)`

Easy to confuse. The first Vector3 is the corner with the **smallest** coordinates; the second is the **extent** (size in each axis), not the opposite corner. Got this wrong twice in the same session.

```gd
# Asymmetric AABB centered laterally, one-sided in -Z (chain direction):
AABB(Vector3(-reach, -reach, -length - pad),
     Vector3(2.0 * reach, 2.0 * reach, length + 2.0 * pad))
# Local Z range: [-length-pad, +pad]
```

## Property setter ordering during scene load runs BEFORE the node enters the tree

`set_particle_count()`, `set_segment_length()`, etc. fire during `.tscn` property loading **before** `NOTIFICATION_ENTER_TREE`. At that point `is_inside_tree() == false` and `get_global_transform()` returns identity (or local-only). Any rebuild-on-setter logic must handle this — typically by deferring the actual world-space rebuild until after the node is in the tree.

The chain of "particle layout depends on world transform" is a common pattern that needs careful sequencing.

## `Basis.get_column()` exists in C++ but NOT in GDScript

In GDScript 4.6 you access columns as `basis.x` / `basis.y` / `basis.z` (these are the column vectors). Calling `basis.get_column(2)` raises a parse error. C++ godot-cpp has `get_column(i)` and the Godot docs list it for both, but the GDScript binding doesn't expose it as a method — only as the named accessors.

## ImmediateMesh `surface_end()` errors if no vertices were added

`surface_begin()` followed by `surface_end()` with zero `surface_add_vertex()` calls between them throws `Condition "vertices.is_empty()" is true.` Defer `surface_begin()` until you know you have at least one vertex to add.

## Watch for: scene-tree walks at edit time fire on detached "preview" instances

When debugging "why isn't my notification firing as expected at edit time," remember Godot may be running the same `_notification` on multiple instances of the same scene during load (live tree, preview tree, etc.). A single `print()` may produce many lines from instances you weren't aware existed. Track instance IDs (`get_instance_id()`) in diagnostic prints to disambiguate.
