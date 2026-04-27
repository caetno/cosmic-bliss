@tool
extends EditorPlugin

var _authoring_gizmo: MarionetteAuthoringGizmo


func _enter_tree() -> void:
	_authoring_gizmo = MarionetteAuthoringGizmo.new()
	add_node_3d_gizmo_plugin(_authoring_gizmo)


func _exit_tree() -> void:
	if _authoring_gizmo != null:
		remove_node_3d_gizmo_plugin(_authoring_gizmo)
		_authoring_gizmo = null
