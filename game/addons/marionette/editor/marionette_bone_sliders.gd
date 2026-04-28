@tool
class_name MarionetteBoneSliders
extends VBoxContainer

# P4 minimal — anatomical sliders for one MarionetteBone, injected into the
# inspector. Drag a slider → bone's pose rotation updates via
# Skeleton3D.set_bone_pose_rotation; releasing/leaving restores the rest
# pose snapshot (no editor interaction ever leaves the scene non-default,
# CLAUDE.md test policy adjacent).
#
# Sliders presented per archetype DOF: any axis whose ROM range is wider
# than _ZERO_RANGE shows a slider, others are skipped. Hinge bones get one
# slider, Saddle two, Ball three, Fixed/Root none.
#
# Skeleton resolution walks up parents from the MarionetteBone to find the
# enclosing Skeleton3D. Works for the standard layout
# Skeleton3D > PhysicalBoneSimulator3D > MarionetteBone but also tolerates
# arbitrary nesting (in case the user reparents).

const _ZERO_RANGE: float = 0.001
const _SLIDER_STEP_RAD: float = 0.001  # ≈ 0.06°, smooth enough for visual sweep


var _bone: MarionetteBone
var _skeleton: Skeleton3D
var _bone_idx: int = -1
var _rest_pose: Quaternion = Quaternion.IDENTITY
var _has_snapshot: bool = false
var _flex_slider: HSlider
var _rot_slider: HSlider
var _abd_slider: HSlider
var _value_labels: Dictionary[Object, Label] = {}


func _init(bone: MarionetteBone) -> void:
	_bone = bone


func _ready() -> void:
	if _bone == null:
		_add_label("(no MarionetteBone)")
		return
	_skeleton = _resolve_skeleton(_bone)
	if _skeleton == null:
		_add_label("(no Skeleton3D ancestor — build the ragdoll first)")
		return
	_bone_idx = _skeleton.find_bone(_bone.bone_name)
	if _bone_idx < 0:
		_add_label("(bone '%s' missing from skeleton)" % _bone.bone_name)
		return
	if _bone.bone_entry == null:
		_add_label("(bone has no BoneEntry — regenerate the BoneProfile)")
		return
	# Snapshot eagerly so even if a single slider drag is the user's only
	# action, _exit_tree restoration has something to write back.
	_rest_pose = _skeleton.get_bone_pose_rotation(_bone_idx)
	_has_snapshot = true
	_build_ui()


func _exit_tree() -> void:
	# Editor inspector frees its custom controls when the selected node
	# changes — that's our cue to restore. Also covers scene close, plugin
	# disable, etc. Idempotent: no-op if we never snapshotted.
	_restore_rest()


func _build_ui() -> void:
	var entry: BoneEntry = _bone.bone_entry
	var header := Label.new()
	header.text = "Muscle Test — %s" % _bone.bone_name
	add_child(header)

	if _axis_active(entry.rom_min.x, entry.rom_max.x):
		_flex_slider = _add_axis_slider("Flexion", entry.rom_min.x, entry.rom_max.x)
	if _axis_active(entry.rom_min.y, entry.rom_max.y):
		_rot_slider = _add_axis_slider("Medial Rotation", entry.rom_min.y, entry.rom_max.y)
	if _axis_active(entry.rom_min.z, entry.rom_max.z):
		_abd_slider = _add_axis_slider("Abduction", entry.rom_min.z, entry.rom_max.z)

	if _flex_slider == null and _rot_slider == null and _abd_slider == null:
		_add_label("(all axes locked — Fixed/Root or zero ROM)")
		return

	var reset_btn := Button.new()
	reset_btn.text = "Reset to Rest"
	reset_btn.pressed.connect(_on_reset_pressed)
	add_child(reset_btn)


func _axis_active(lo: float, hi: float) -> bool:
	return absf(hi - lo) > _ZERO_RANGE


func _add_label(text: String) -> void:
	var label := Label.new()
	label.text = text
	add_child(label)


func _add_axis_slider(label_text: String, lo: float, hi: float) -> HSlider:
	var label := Label.new()
	label.text = "%s (%.1f° to %.1f°)" % [label_text, rad_to_deg(lo), rad_to_deg(hi)]
	add_child(label)

	var slider := HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	slider.step = _SLIDER_STEP_RAD
	slider.value = 0.0
	slider.custom_minimum_size = Vector2(120, 0)
	slider.value_changed.connect(_on_slider_changed)
	add_child(slider)

	var value_label := Label.new()
	value_label.text = "0.0°"
	add_child(value_label)
	_value_labels[slider] = value_label

	return slider


func _on_slider_changed(_v: float) -> void:
	_apply_pose()


func _on_reset_pressed() -> void:
	if _flex_slider != null:
		_flex_slider.set_value_no_signal(0.0)
	if _rot_slider != null:
		_rot_slider.set_value_no_signal(0.0)
	if _abd_slider != null:
		_abd_slider.set_value_no_signal(0.0)
	for slider: Object in _value_labels.keys():
		_value_labels[slider].text = "0.0°"
	_restore_rest()
	# Re-snapshot so subsequent slider drags still have a base to compose on.
	if _skeleton != null and _bone_idx >= 0:
		_rest_pose = _skeleton.get_bone_pose_rotation(_bone_idx)
		_has_snapshot = true


func _apply_pose() -> void:
	if not _has_snapshot or _skeleton == null or _bone_idx < 0:
		return
	var flex_v: float = _flex_slider.value if _flex_slider != null else 0.0
	var rot_v: float = _rot_slider.value if _rot_slider != null else 0.0
	var abd_v: float = _abd_slider.value if _abd_slider != null else 0.0
	if _flex_slider != null:
		_value_labels[_flex_slider].text = "%.1f°" % rad_to_deg(flex_v)
	if _rot_slider != null:
		_value_labels[_rot_slider].text = "%.1f°" % rad_to_deg(rot_v)
	if _abd_slider != null:
		_value_labels[_abd_slider].text = "%.1f°" % rad_to_deg(abd_v)
	var anatomical: Quaternion = AnatomicalPose.bone_local_rotation(
			_bone.bone_entry, flex_v, rot_v, abd_v)
	# Compose anatomical rotation onto the rest pose (post-multiply: the
	# anatomical Quaternion is in the bone's local frame; it stacks after
	# whatever rest rotation the bone already had).
	_skeleton.set_bone_pose_rotation(_bone_idx, _rest_pose * anatomical)


func _restore_rest() -> void:
	if not _has_snapshot:
		return
	if _skeleton == null or _bone_idx < 0:
		return
	if not is_instance_valid(_skeleton):
		return
	_skeleton.set_bone_pose_rotation(_bone_idx, _rest_pose)


# Walks up the parent chain to find the enclosing Skeleton3D. Returns null
# if the bone is detached or in a non-skeleton scene.
static func _resolve_skeleton(bone: Node) -> Skeleton3D:
	var n: Node = bone.get_parent()
	while n != null:
		if n is Skeleton3D:
			return n
		n = n.get_parent()
	return null
