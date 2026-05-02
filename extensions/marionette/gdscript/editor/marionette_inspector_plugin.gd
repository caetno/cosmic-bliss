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
	return object is Marionette


func _parse_begin(object: Object) -> void:
	var marionette: Marionette = object as Marionette
	if marionette == null:
		return
	var pill := MarionetteStatusPill.new()
	pill.marionette = marionette
	add_custom_control(pill)
