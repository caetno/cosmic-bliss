@tool
class_name MarionetteBoneInspector
extends EditorInspectorPlugin

# P4 minimal — when a MarionetteBone is selected, inject a MuscleTest
# section (sliders for the bone's anatomical DOFs) at the top of the
# inspector. The sliders write directly to Skeleton3D.set_bone_pose_rotation
# without physics — just the anatomical → bone-local rotation math.
#
# Inspector lifecycle: Godot frees custom controls when the selected node
# changes, so MarionetteBoneSliders._exit_tree() restores the rest pose
# automatically. No explicit deselection callback needed.


func _can_handle(object: Object) -> bool:
	return object is MarionetteBone


func _parse_begin(object: Object) -> void:
	var bone: MarionetteBone = object as MarionetteBone
	if bone == null:
		return
	var widget := MarionetteBoneSliders.new(bone)
	add_custom_control(widget)
