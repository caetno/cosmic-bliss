@tool
class_name MarionetteBoneSliders
extends VBoxContainer

# P4 — anatomical sliders for one MarionetteBone, used by both the inspector
# (one widget per selected bone) and the muscle-test dock (many widgets).
#
# Compact 1-row-per-axis layout: [description+limits] [value] [colored
# slider]. Colors mirror MarionetteJointLimitGizmo so a slider's color
# matches the ROM arc it drives — flex red, medial rotation green,
# abduction blue. No per-bone reset button: dock supplies "Reset All to
# Rest"; callers (dock, tests) invoke `reset_to_rest()` directly.
#
# Lifecycle: snapshot rest pose in `_ready`, restore in `_exit_tree`. The
# editor frees custom inspector controls on selection change, which
# automatically restores rest. The dock relies on the same path when it
# clears its content for a new ragdoll.

const _ZERO_RANGE: float = 0.001
const _SLIDER_STEP_RAD: float = 0.001  # ≈ 0.06°

# Match MarionetteJointLimitGizmo._COL_FLEX/_COL_ROT/_COL_ABD — kept local
# (not imported) so this widget doesn't pull in the gizmo class for a UI
# concern. Update both if the convention changes.
const _COLOR_FLEX: Color = Color(1.0, 0.35, 0.35)
const _COLOR_ROT: Color = Color(0.4, 1.0, 0.4)
const _COLOR_ABD: Color = Color(0.4, 0.55, 1.0)

const _DESC_WIDTH: float = 116.0
const _VALUE_WIDTH: float = 38.0
const _SLIDER_MIN_WIDTH: float = 60.0


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
	add_theme_constant_override("separation", 1)


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
	_rest_pose = _skeleton.get_bone_pose_rotation(_bone_idx)
	_has_snapshot = true
	_build_ui()


func _exit_tree() -> void:
	_restore_rest()


func _build_ui() -> void:
	var entry: BoneEntry = _bone.bone_entry

	var header := Label.new()
	header.text = _bone.bone_name
	header.add_theme_color_override("font_color", Color(0.78, 0.78, 0.85))
	add_child(header)

	if _axis_active(entry.rom_min.x, entry.rom_max.x):
		_flex_slider = _add_axis_row("Flexion", entry.rom_min.x, entry.rom_max.x, _COLOR_FLEX)
	if _axis_active(entry.rom_min.y, entry.rom_max.y):
		_rot_slider = _add_axis_row("Med Rot", entry.rom_min.y, entry.rom_max.y, _COLOR_ROT)
	if _axis_active(entry.rom_min.z, entry.rom_max.z):
		_abd_slider = _add_axis_row("Abduction", entry.rom_min.z, entry.rom_max.z, _COLOR_ABD)

	if _flex_slider == null and _rot_slider == null and _abd_slider == null:
		_add_label("(all axes locked — Fixed/Root or zero ROM)")


func _axis_active(lo: float, hi: float) -> bool:
	return absf(hi - lo) > _ZERO_RANGE


func _add_label(text: String) -> void:
	var label := Label.new()
	label.text = text
	add_child(label)


# Single-row axis: [description with limits] [current value] [colored slider].
# Description+value sit on the left so they don't shift when the slider
# expands; value updates in-place as the slider moves.
func _add_axis_row(axis_name: String, lo: float, hi: float, color: Color) -> HSlider:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 4)
	add_child(row)

	var desc := Label.new()
	desc.text = "%s %.0f..%.0f°" % [axis_name, rad_to_deg(lo), rad_to_deg(hi)]
	desc.custom_minimum_size = Vector2(_DESC_WIDTH, 0)
	desc.tooltip_text = "%s — joint range %.1f° to %.1f°" % [axis_name, rad_to_deg(lo), rad_to_deg(hi)]
	row.add_child(desc)

	var value_label := Label.new()
	value_label.text = "0°"
	value_label.custom_minimum_size = Vector2(_VALUE_WIDTH, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value_label)

	var slider := HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	slider.step = _SLIDER_STEP_RAD
	slider.value = 0.0
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(_SLIDER_MIN_WIDTH, 0)
	slider.modulate = color
	slider.value_changed.connect(_on_slider_changed)
	row.add_child(slider)

	_value_labels[slider] = value_label
	return slider


func _on_slider_changed(_v: float) -> void:
	_apply_pose()


# Public reset entry point. Used by the dock's "Reset All to Rest" and by
# unit tests; replaces the old per-bone Reset button. Zeros every active
# slider, restores the snapshot rest pose, and re-snapshots so subsequent
# slider drags compose on top of a clean base.
func reset_to_rest() -> void:
	if _flex_slider != null:
		_flex_slider.set_value_no_signal(0.0)
	if _rot_slider != null:
		_rot_slider.set_value_no_signal(0.0)
	if _abd_slider != null:
		_abd_slider.set_value_no_signal(0.0)
	for slider: Object in _value_labels.keys():
		_value_labels[slider].text = "0°"
	_restore_rest()
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
		_value_labels[_flex_slider].text = "%.0f°" % rad_to_deg(flex_v)
	if _rot_slider != null:
		_value_labels[_rot_slider].text = "%.0f°" % rad_to_deg(rot_v)
	if _abd_slider != null:
		_value_labels[_abd_slider].text = "%.0f°" % rad_to_deg(abd_v)
	var anatomical: Quaternion = AnatomicalPose.bone_local_rotation(
			_bone.bone_entry, flex_v, rot_v, abd_v)
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
