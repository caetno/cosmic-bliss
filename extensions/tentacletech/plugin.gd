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
const _OrificeGizmoScript := preload("res://addons/tentacletech/scripts/gizmo_plugin/orifice_gizmo.gd")

var _tentacle_gizmo_plugin: EditorNode3DGizmoPlugin
var _orifice_gizmo_plugin: EditorNode3DGizmoPlugin


func _enter_tree() -> void:
	_tentacle_gizmo_plugin = _TentacleGizmoScript.new()
	add_node_3d_gizmo_plugin(_tentacle_gizmo_plugin)
	# §15.5 OrificeBuilder gizmo (2026-05-17 visual-authoring slice).
	# Constructor takes the EditorUndoRedoManager so handle drags
	# participate in the normal Ctrl-Z stack.
	_orifice_gizmo_plugin = _OrificeGizmoScript.new(get_undo_redo())
	add_node_3d_gizmo_plugin(_orifice_gizmo_plugin)


func _exit_tree() -> void:
	if _tentacle_gizmo_plugin != null:
		remove_node_3d_gizmo_plugin(_tentacle_gizmo_plugin)
		_tentacle_gizmo_plugin = null
	if _orifice_gizmo_plugin != null:
		remove_node_3d_gizmo_plugin(_orifice_gizmo_plugin)
		_orifice_gizmo_plugin = null
