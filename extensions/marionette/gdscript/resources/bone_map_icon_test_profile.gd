@tool
class_name MarionetteBoneMapIconTest
extends SkeletonProfile


const TEX_BODY := preload("res://addons/marionette/textures/bone_map_test/group_body.svg")
const TEX_FACE := preload("res://addons/marionette/textures/bone_map_test/group_face.svg")
const TEX_LEFT_HAND := preload("res://addons/marionette/textures/bone_map_test/group_left_hand.svg")
const TEX_RIGHT_HAND := preload("res://addons/marionette/textures/bone_map_test/group_right_hand.svg")
const TEX_LEFT_FOOT := preload("res://addons/marionette/textures/bone_map_test/group_left_foot.svg")
const TEX_RIGHT_FOOT := preload("res://addons/marionette/textures/bone_map_test/group_right_foot.svg")


func _init() -> void:
	group_size = 6
	set_group_name(0, &"Body")
	set_texture(0, TEX_BODY)
	set_group_name(1, &"Face")
	set_texture(1, TEX_FACE)
	set_group_name(2, &"LeftHand")
	set_texture(2, TEX_LEFT_HAND)
	set_group_name(3, &"RightHand")
	set_texture(3, TEX_RIGHT_HAND)
	set_group_name(4, &"LeftFoot")
	set_texture(4, TEX_LEFT_FOOT)
	set_group_name(5, &"RightFoot")
	set_texture(5, TEX_RIGHT_FOOT)

	bone_size = 6
	_set_bone(0, &"TestBody", &"Body", Vector2(128, 128))
	_set_bone(1, &"TestFace", &"Face", Vector2(128, 128))
	_set_bone(2, &"TestLeftHand", &"LeftHand", Vector2(128, 128))
	_set_bone(3, &"TestRightHand", &"RightHand", Vector2(128, 128))
	_set_bone(4, &"TestLeftFoot", &"LeftFoot", Vector2(128, 128))
	_set_bone(5, &"TestRightFoot", &"RightFoot", Vector2(128, 128))


func _set_bone(idx: int, bone_name: StringName, group: StringName, handle: Vector2) -> void:
	set_bone_name(idx, bone_name)
	set_group(idx, group)
	set_handle_offset(idx, handle)
