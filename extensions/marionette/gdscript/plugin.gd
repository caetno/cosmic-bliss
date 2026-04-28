@tool
extends EditorPlugin

var _authoring_gizmo: MarionetteAuthoringGizmo
var _joint_limit_gizmo: MarionetteJointLimitGizmo
var _bone_profile_inspector: MarionetteBoneProfileInspector
var _bone_inspector: MarionetteBoneInspector


func _enter_tree() -> void:
	_authoring_gizmo = MarionetteAuthoringGizmo.new()
	add_node_3d_gizmo_plugin(_authoring_gizmo)
	_joint_limit_gizmo = MarionetteJointLimitGizmo.new()
	add_node_3d_gizmo_plugin(_joint_limit_gizmo)
	_bone_profile_inspector = MarionetteBoneProfileInspector.new()
	add_inspector_plugin(_bone_profile_inspector)
	_bone_inspector = MarionetteBoneInspector.new()
	add_inspector_plugin(_bone_inspector)


func _exit_tree() -> void:
	if _authoring_gizmo != null:
		remove_node_3d_gizmo_plugin(_authoring_gizmo)
		_authoring_gizmo = null
	if _joint_limit_gizmo != null:
		remove_node_3d_gizmo_plugin(_joint_limit_gizmo)
		_joint_limit_gizmo = null
	if _bone_profile_inspector != null:
		remove_inspector_plugin(_bone_profile_inspector)
		_bone_profile_inspector = null
	if _bone_inspector != null:
		remove_inspector_plugin(_bone_inspector)
		_bone_inspector = null
