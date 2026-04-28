@tool
class_name MarionetteBoneProfileInspector
extends EditorInspectorPlugin

# P2.10 — adds a "Generate from Skeleton" button at the top of every
# BoneProfile inspector. Pressing it runs `BoneProfileGenerator.generate()`
# in place and emits `emit_changed()` so the editor marks the resource
# dirty. The user must Ctrl+S to persist; we deliberately don't auto-save.
#
# The button takes the template path (no live skeleton). The shipped default
# BoneProfile is template-derived (Marionette_plan P2.13); per-rig calibration
# uses the same generator with a Skeleton3D + BoneMap, but that flow lives on
# the Marionette node side, not the BoneProfile resource.


func _can_handle(object: Object) -> bool:
	return object is BoneProfile


func _parse_begin(object: Object) -> void:
	var bp: BoneProfile = object as BoneProfile
	if bp == null:
		return
	var button := Button.new()
	button.text = "Generate from Skeleton"
	button.tooltip_text = "Run muscle frame -> archetype -> solver -> matcher -> ROM defaults for every bone in the referenced SkeletonProfile. Replaces existing entries."
	button.pressed.connect(_on_pressed.bind(bp))
	add_custom_control(button)


func _on_pressed(bp: BoneProfile) -> void:
	if bp == null:
		push_warning("Marionette: BoneProfile is null")
		return
	if bp.skeleton_profile == null:
		push_warning("Marionette: assign a SkeletonProfile to bone_profile.skeleton_profile before generating")
		return
	var report: BoneProfileGenerator.GenerateReport = BoneProfileGenerator.generate(bp)
	if report.error != "":
		push_warning("Marionette: generate failed — %s" % report.error)
		return
	bp.emit_changed()
	var path: String = bp.resource_path if bp.resource_path != "" else "<unsaved>"
	print("[Marionette] %s: %d entries (matched=%d unmatched=%d skipped=%d)"
			% [path, report.generated, report.matched, report.unmatched, report.skipped])
	if report.unmatched > 0:
		print("[Marionette]   unmatched bones: %s" % [report.unmatched_bones])
	if report.skipped > 0:
		print("[Marionette]   skipped (no archetype / not in rest data): %s" % [report.skipped_bones])
