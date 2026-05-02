@tool
class_name MarionetteInspectorPlugin
extends EditorInspectorPlugin

# Slice 5: status pill at the top of the Marionette inspector. Shows
# whether build_ragdoll has been run and how many bones / jiggle bones
# are spawned. Updates by polling its own _process tick (cheap; only
# active while the inspector is open on a Marionette).
#
# Sectioned layout (Bind / Anatomy / Collision Shapes / Build / Tune &
# Test) lives on the Marionette node itself via @export_group — no work
# from this plugin is needed to render the headers. This file is just
# the status pill (and slice 7 will add the Tune & Test widget here).

func _can_handle(object: Object) -> bool:
	# Marionette gets the status pill (slice 5).
	# BoneCollisionProfile gets the non_cascade_bones picker (slice 5b).
	# Slice 7 will add Tune & Test handling for Marionette + JiggleProfile.
	return object is Marionette or object is BoneCollisionProfile


func _parse_begin(object: Object) -> void:
	var marionette: Marionette = object as Marionette
	if marionette == null:
		return
	var pill := MarionetteStatusPill.new()
	pill.marionette = marionette
	add_custom_control(pill)


# Replaces Godot's default Array editor on `BoneCollisionProfile.non_cascade_bones`
# with a bone-name dropdown (MarionetteBoneListProperty). Returns true to
# suppress the default editor; false to fall through.
func _parse_property(
		object: Object,
		_type: int,
		name: String,
		_hint_type: int,
		_hint_string: String,
		_usage_flags: int,
		_wide: bool) -> bool:
	if object is BoneCollisionProfile and name == "non_cascade_bones":
		var prop := MarionetteBoneListProperty.new()
		add_property_editor(name, prop)
		return true
	return false
