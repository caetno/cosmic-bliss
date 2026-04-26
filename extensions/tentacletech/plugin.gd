@tool
extends EditorPlugin
## TentacleTech editor plugin (§15.5).
##
## Registers per-physics-class EditorNode3DGizmoPlugins so selecting a
## Tentacle in the viewport draws its particles, segments, spline polyline,
## and TBN frames. The runtime DebugGizmoOverlay (§15.1–4) covers
## simulation; this plugin covers authoring.
##
## The user enables the plugin via Project Settings → Plugins. We never
## edit `game/project.godot` automatically — that's a user action.

const _TentacleGizmoScript := preload("res://addons/tentacletech/scripts/gizmo_plugin/tentacle_gizmo.gd")

var _tentacle_gizmo_plugin: EditorNode3DGizmoPlugin


func _enter_tree() -> void:
	_tentacle_gizmo_plugin = _TentacleGizmoScript.new()
	add_node_3d_gizmo_plugin(_tentacle_gizmo_plugin)


func _exit_tree() -> void:
	if _tentacle_gizmo_plugin != null:
		remove_node_3d_gizmo_plugin(_tentacle_gizmo_plugin)
		_tentacle_gizmo_plugin = null
