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
	var arch_btn := Button.new()
	arch_btn.text = "Generate from Skeleton"
	arch_btn.tooltip_text = "Muscle frame -> per-archetype solver -> matcher -> ROM defaults. Replaces existing entries."
	arch_btn.pressed.connect(_on_pressed.bind(bp, BoneProfileGenerator.Method.ARCHETYPE))
	add_custom_control(arch_btn)


func _on_pressed(bp: BoneProfile, method: BoneProfileGenerator.Method) -> void:
	if bp == null:
		push_warning("Marionette: BoneProfile is null")
		return
	if bp.skeleton_profile == null:
		push_warning("Marionette: assign a SkeletonProfile to bone_profile.skeleton_profile before generating")
		return
	var path: String = bp.resource_path if bp.resource_path != "" else "<unsaved>"
	var method_label: String = "archetype" if method == BoneProfileGenerator.Method.ARCHETYPE else "t-pose"
	print("[Marionette] generating %s (template path, method=%s) — per-bone log:" % [path, method_label])
	var report: BoneProfileGenerator.GenerateReport = BoneProfileGenerator.generate_with_method(
			bp, method, null, null, true)
	if report.error != "":
		push_warning("Marionette: generate failed — %s" % report.error)
		return
	bp.emit_changed()
	if report.unmatched > 0:
		print("[Marionette]   fallback bones (calculated frame baked): %s" % [report.unmatched_bones])
	if report.skipped > 0:
		print("[Marionette]   skipped (no archetype / not in rest data): %s" % [report.skipped_bones])
