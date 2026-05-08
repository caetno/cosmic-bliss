---
name: EditorNode3DGizmoPlugin doesn't redraw smoothly during continuous input
description: Known Godot bug — gizmo redraws stutter/freeze during continuous editor input (mouse drags, slider drags). Skeleton3DEditor sidesteps it via custom ImmediateMesh; for now we coalesce a Node3D.visible flicker per frame as a partial fix
type: reference
originSessionId: cac23be2-e8d3-4bc0-9843-16d9ac1bd1c5
---
**Root cause:** [godotengine/godot#71979](https://github.com/godotengine/godot/issues/71979). `EditorNode3DGizmoPlugin._redraw` doesn't reliably get scheduled during continuous editor input. `Node3D.update_gizmos()` queues redraw via `MessageQueue::push_callable`, which the editor doesn't flush in time during fast slider/mouse events. Direct calls to `_redraw(gizmo)` populate the gizmo's mesh data correctly but don't trigger an editor viewport repaint, so the new geometry doesn't reach the screen.

**The only paths that actually drive a synchronous repaint:**
- View → Gizmos checkbox toggle — calls `_set_state` on the plugin which calls `EditorNode3DGizmo::redraw()` on every active gizmo.
- `Node3D.visible = !visible` propagation — `Node3D::_propagate_visibility_changed` calls `_update_gizmos()` synchronously (TOOLS_ENABLED branch) AND forces a viewport repaint.

**Proper fix (not yet implemented):** drop the `EditorNode3DGizmoPlugin` paradigm for any gizmo that needs to update during continuous input. Skeleton3DEditor's pattern (`editor/plugins/skeleton_3d_editor_plugin.cpp`): a child `MeshInstance3D` with an `ImmediateMesh`, populated directly from a `pose_updated` handler. Bypasses the gizmo plugin's lazy redraw scheduler entirely. The renderer auto-detects mesh changes and repaints.

**Current workaround in Marionette:** `MarionetteBoneSliders` coalesces multiple `value_changed` events per frame into a single deferred `Node3D.visible` flicker on the owning Marionette node. The `_request_gizmo_refresh` / `_do_gizmo_refresh` pair uses a pending-flag + `call_deferred` so refresh runs at most once per frame regardless of input rate. Without coalescing the flicker fires faster than frame rate (HSlider input events tick ~120Hz) and the editor stalls. Guard the flicker with `if node.visible:` so a hidden gizmo node doesn't get re-shown.

**Side mechanism kept for completeness:** `MarionetteAuthoringGizmo._instance` and `MarionetteJointLimitGizmo._instance` (set in `_init`) plus `static func redraw_for_node(node)` that iterates `get_current_gizmos()` and calls `_instance._redraw(gizmo)` directly. Useful for one-shot refreshes outside continuous input. Not used by the slider since the visibility flicker covers it.

**When to revisit:** if 1-flicker-per-frame is still laggy in practice, refactor to ImmediateMesh. Estimated effort: rewrite both gizmo plugins to add a child MeshInstance3D + ImmediateMesh on the Marionette and populate from connected pose_updated/skeleton_updated signals. Loses subgizmo selection / handle dragging support (we don't use those).
