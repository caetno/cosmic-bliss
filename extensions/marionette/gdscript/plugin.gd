@tool
extends EditorPlugin

var _authoring_gizmo: MarionetteAuthoringGizmo
var _joint_limit_gizmo: MarionetteJointLimitGizmo
var _collider_gizmo: MarionetteColliderGizmo
var _bone_profile_inspector: MarionetteBoneProfileInspector
var _bone_inspector: MarionetteBoneInspector
var _marionette_inspector: MarionetteInspectorPlugin
var _muscle_dock: MarionetteMuscleTestDock


func _enter_tree() -> void:
	_authoring_gizmo = MarionetteAuthoringGizmo.new()
	add_node_3d_gizmo_plugin(_authoring_gizmo)
	_joint_limit_gizmo = MarionetteJointLimitGizmo.new()
	add_node_3d_gizmo_plugin(_joint_limit_gizmo)
	# View → Gizmos shows this as "Marionette Colliders" — toggle on to see
	# capsule wireframes without the 6DOF joint clutter that comes with
	# `show_physics_bones_in_editor`.
	_collider_gizmo = MarionetteColliderGizmo.new()
	add_node_3d_gizmo_plugin(_collider_gizmo)
	_bone_profile_inspector = MarionetteBoneProfileInspector.new()
	add_inspector_plugin(_bone_profile_inspector)
	_bone_inspector = MarionetteBoneInspector.new()
	add_inspector_plugin(_bone_inspector)
	_marionette_inspector = MarionetteInspectorPlugin.new()
	add_inspector_plugin(_marionette_inspector)
	# Mount alongside Inspector / Node (Signals, Groups) / History so the
	# muscle-test tab is one click away during authoring.
	_muscle_dock = MarionetteMuscleTestDock.new()
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _muscle_dock)


func _exit_tree() -> void:
	if _authoring_gizmo != null:
		remove_node_3d_gizmo_plugin(_authoring_gizmo)
		_authoring_gizmo = null
	if _joint_limit_gizmo != null:
		remove_node_3d_gizmo_plugin(_joint_limit_gizmo)
		_joint_limit_gizmo = null
	if _collider_gizmo != null:
		remove_node_3d_gizmo_plugin(_collider_gizmo)
		_collider_gizmo = null
	if _bone_profile_inspector != null:
		remove_inspector_plugin(_bone_profile_inspector)
		_bone_profile_inspector = null
	if _bone_inspector != null:
		remove_inspector_plugin(_bone_inspector)
		_bone_inspector = null
	if _marionette_inspector != null:
		remove_inspector_plugin(_marionette_inspector)
		_marionette_inspector = null
	if _muscle_dock != null:
		remove_control_from_docks(_muscle_dock)
		_muscle_dock.queue_free()
		_muscle_dock = null
