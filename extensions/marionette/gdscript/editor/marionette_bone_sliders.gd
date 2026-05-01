@tool
class_name MarionetteBoneSliders
extends VBoxContainer

# P4 — anatomical sliders for one MarionetteBone, used by both the inspector
# (one widget per selected bone) and the muscle-test dock (many widgets).
#
# Two-row-per-axis layout:
#   Row 1: anatomical pair label  "Extension -55° ↔ 55° Flexion"
#   Row 2: [current value] [colored slider]
# Colors mirror MarionetteJointLimitGizmo so a slider's color matches the
# ROM arc it drives — flex red, medial rotation green, abduction blue.
# No per-bone reset button: dock supplies "Reset All to Rest"; callers
# (dock, tests) invoke `reset_to_rest()` directly.
#
# Macro offset: the muscle-test dock's macro section pushes a per-bone
# Vector3 anatomical offset via `set_macro_offset()`. The offset composes
# additively with the per-axis sliders before the rotation is applied.
# This lets one Unity-style "Open ↔ Close" slider drive every bone while
# the per-bone sliders still adjust on top.
#
# Reference rotation: `_rest_rotation` is taken from `Skeleton3D.get_bone_rest`,
# never from `get_bone_pose_rotation`. This is deliberate — `bone_rest` is
# the canonical T-pose stored in the skeleton resource, while `bone_pose`
# is the live runtime rotation that may already be modified (e.g., a scene
# saved while mid-drag). Anchoring on `bone_rest` means "Reset All" always
# returns to the canonical pose, and on widget mount we actively restore
# the pose to rest so re-opening such a scene also returns to T-pose.
#
# Lifecycle: read bone_rest in `_ready` and restore the pose to rest then;
# restore again in `_exit_tree` so the modified pose never leaks past the
# dock's lifetime within a session.

const _ZERO_RANGE: float = 0.001
const _SLIDER_STEP_RAD: float = 0.001  # ≈ 0.06°

# Match MarionetteJointLimitGizmo._COL_FLEX/_COL_ROT/_COL_ABD — kept local
# (not imported) so this widget doesn't pull in the gizmo class for a UI
# concern. Update both if the convention changes.
const _COLOR_FLEX: Color = Color(1.0, 0.35, 0.35)
const _COLOR_ROT: Color = Color(0.4, 1.0, 0.4)
const _COLOR_ABD: Color = Color(0.4, 0.55, 1.0)

const _VALUE_WIDTH: float = 38.0
const _SLIDER_MIN_WIDTH: float = 60.0

# Anatomical pair labels per axis component, sign-aligned with project
# convention (+X = flexion, +Y = medial rotation, +Z = abduction). The
# negative-pole label is shown on the slider's left, positive on the right.
const _AXIS_NEG_LABEL: Array[String] = ["Extension", "Lateral Rot", "Adduction"]
const _AXIS_POS_LABEL: Array[String] = ["Flexion", "Medial Rot", "Abduction"]


var _bone: MarionetteBone
var _skeleton: Skeleton3D
# Cached ancestor Marionette so _apply_pose can poke it to redraw its gizmos
# after a slider change. We can't rely on Skeleton3D.pose_updated alone — in
# @tool mode it doesn't always reach the editor's gizmo-redraw scheduler in
# the same frame the user dragged a slider, so the ROM arcs lag behind the
# pose. Direct call is one method invocation per drag step, no allocations.
var _marionette: Marionette
var _bone_idx: int = -1
# Canonical rest rotation, read from Skeleton3D.bone_rest at mount time.
# Independent of any prior pose modifications saved to the scene.
var _rest_rotation: Quaternion = Quaternion.IDENTITY
var _has_snapshot: bool = false
var _flex_slider: HSlider
var _rot_slider: HSlider
var _abd_slider: HSlider
var _value_labels: Dictionary[Object, Label] = {}

# Aggregated macro contribution in anatomical (flex, medial_rot, abduction)
# radians. Set by the dock's macro slider section; zero when not driven.
var _macro_offset: Vector3 = Vector3.ZERO

# Gizmo refresh deferral now lives on the Marionette node (see
# Marionette.request_gizmo_refresh) so the deferred call survives this
# widget being freed — _exit_tree's _restore_rest still needs the gizmo to
# follow the bone back to rest after the dock tears the widget down.


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
	_marionette = _resolve_marionette(_bone)
	_bone_idx = _skeleton.find_bone(_bone.bone_name)
	if _bone_idx < 0:
		_add_label("(bone '%s' missing from skeleton)" % _bone.bone_name)
		return
	if _bone.bone_entry == null:
		_add_label("(bone has no BoneEntry — regenerate the BoneProfile)")
		return
	_rest_rotation = _skeleton.get_bone_rest(_bone_idx).basis.get_rotation_quaternion()
	_has_snapshot = true
	# Active reset on mount: if the scene was saved with a modified pose
	# (e.g., editor closed mid-drag in a previous session), this returns
	# the bone to its canonical T-pose immediately.
	_restore_rest()
	_build_ui()
	_log_axis_diagnostic()


# Prints, once per widget mount, what world-space axes each slider will
# rotate the bone around. Use this when the gizmo and the visible motion
# disagree: the printed axes are exactly what `set_bone_pose_rotation`
# produces, so they're ground truth for "what the slider does." Compare
# them against what the joint-limit gizmo's red/green/blue arrows point at
# in the viewport — if they don't match, the bug is in the gizmo's basis
# composition; if they do match, the rotation is doing exactly what the
# gizmo claims and the disagreement is in your reading of the gizmo.
#
# `bone_global_pose_at_rest` = parent's *live* global * bone's REST local.
# That's the frame the bone would have if the slider were back at zero —
# the same frame `set_bone_pose_rotation(idx, _rest_rotation)` lands on,
# and the same frame the slider's rotation axis is anchored in.
func _log_axis_diagnostic() -> void:
	if _bone == null or _bone.bone_entry == null:
		return
	var bone_rest_local: Transform3D = _skeleton.get_bone_rest(_bone_idx)
	var parent_idx: int = _skeleton.get_bone_parent(_bone_idx)
	var parent_global: Transform3D = Transform3D.IDENTITY
	if parent_idx >= 0:
		parent_global = _skeleton.get_bone_global_pose(parent_idx)
	var bone_world_at_rest: Transform3D = parent_global * bone_rest_local
	var ab: Basis = _bone.bone_entry.anatomical_basis_in_bone_local()
	var flex_world: Vector3 = (bone_world_at_rest.basis * ab.x).normalized()
	var rot_world: Vector3 = (bone_world_at_rest.basis * ab.y).normalized()
	var abd_world: Vector3 = (bone_world_at_rest.basis * ab.z).normalized()
	print("[Marionette/sliders] %s: flex(red)=%s  rot(green)=%s  abd(blue)=%s  use_calc=%s" %
			[_bone.bone_name, flex_world, rot_world, abd_world,
			_bone.bone_entry.use_calculated_frame])


func _exit_tree() -> void:
	_restore_rest()


func _build_ui() -> void:
	var entry: BoneEntry = _bone.bone_entry

	var header := Label.new()
	header.text = _bone.bone_name
	header.add_theme_color_override("font_color", Color(0.78, 0.78, 0.85))
	add_child(header)

	if _axis_active(entry.rom_min.x, entry.rom_max.x):
		_flex_slider = _add_axis_row(0, entry.rom_min.x, entry.rom_max.x, _COLOR_FLEX)
	if _axis_active(entry.rom_min.y, entry.rom_max.y):
		_rot_slider = _add_axis_row(1, entry.rom_min.y, entry.rom_max.y, _COLOR_ROT)
	if _axis_active(entry.rom_min.z, entry.rom_max.z):
		_abd_slider = _add_axis_row(2, entry.rom_min.z, entry.rom_max.z, _COLOR_ABD)

	if _flex_slider == null and _rot_slider == null and _abd_slider == null:
		_add_label("(all axes locked — Fixed/Root or zero ROM)")


func _axis_active(lo: float, hi: float) -> bool:
	return absf(hi - lo) > _ZERO_RANGE


func _add_label(text: String) -> void:
	var label := Label.new()
	label.text = text
	add_child(label)


# Two-row axis: [paired anatomical label] / [current value][colored slider].
# Label format: "Extension -55° ↔ 55° Flexion" — pair words sign-aligned with
# project convention. Value updates in-place as the slider moves.
func _add_axis_row(axis_idx: int, lo: float, hi: float, color: Color) -> HSlider:
	var neg_label: String = _AXIS_NEG_LABEL[axis_idx]
	var pos_label: String = _AXIS_POS_LABEL[axis_idx]
	var lo_deg: float = rad_to_deg(lo)
	var hi_deg: float = rad_to_deg(hi)

	var desc := Label.new()
	desc.text = "%s %.0f° ↔ %.0f° %s" % [neg_label, lo_deg, hi_deg, pos_label]
	desc.tooltip_text = desc.text
	add_child(desc)

	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 4)
	add_child(row)

	var value_label := Label.new()
	value_label.text = "0°"
	value_label.custom_minimum_size = Vector2(_VALUE_WIDTH, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value_label)

	var slider := HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	slider.step = _SLIDER_STEP_RAD
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(_SLIDER_MIN_WIDTH, 0)
	slider.modulate = color
	# Slider value is in canonical anatomy. The rest pose corresponds to
	# `rest_anatomical_offset` (zero on T-pose rigs; non-zero on A-pose for
	# bones whose rest deviates from canonical) — set the initial value with
	# no_signal so the value_changed connect below doesn't fire `_apply_pose`
	# while `_flex_slider`/`_rot_slider`/`_abd_slider` members are still
	# unassigned (they're bound in `_build_ui` *after* `_add_axis_row` returns).
	# That mid-init pose application would briefly drive the bone to canonical
	# zero before the user touched anything.
	var initial: float = _bone.bone_entry.rest_anatomical_offset[axis_idx]
	slider.set_value_no_signal(initial)
	value_label.text = "%.0f°" % rad_to_deg(initial)
	slider.value_changed.connect(_on_slider_changed)
	row.add_child(slider)

	_value_labels[slider] = value_label
	return slider


func _on_slider_changed(_v: float) -> void:
	_apply_pose()


# Public reset entry point. Used by the dock's "Reset All to Rest" and by
# unit tests; replaces the old per-bone Reset button. Zeros every active
# slider, clears the macro offset, and restores the canonical bone rest.
# `_rest_rotation` is anchored on `Skeleton3D.bone_rest` (set in `_ready`)
# so this is idempotent — repeat calls always return to T-pose, regardless
# of intervening pose modifications.
func reset_to_rest() -> void:
	# Slider value is in canonical anatomy; rest pose corresponds to
	# `rest_anatomical_offset` (often zero, but not on A-pose rigs). Reset to
	# the per-axis offset so the slider readout matches the bone's actual
	# at-rest configuration, not canonical zero.
	var rest_offset: Vector3 = _bone.bone_entry.rest_anatomical_offset
	if _flex_slider != null:
		_flex_slider.set_value_no_signal(rest_offset.x)
		_value_labels[_flex_slider].text = "%.0f°" % rad_to_deg(rest_offset.x)
	if _rot_slider != null:
		_rot_slider.set_value_no_signal(rest_offset.y)
		_value_labels[_rot_slider].text = "%.0f°" % rad_to_deg(rest_offset.y)
	if _abd_slider != null:
		_abd_slider.set_value_no_signal(rest_offset.z)
		_value_labels[_abd_slider].text = "%.0f°" % rad_to_deg(rest_offset.z)
	_macro_offset = Vector3.ZERO
	_restore_rest()


# Pushes a macro-driven anatomical offset (radians) to compose with the
# per-axis sliders. Called by the dock's macro section. Triggers an
# immediate pose re-apply so dragging the macro slider is responsive.
func set_macro_offset(offset: Vector3) -> void:
	if _macro_offset == offset:
		return
	_macro_offset = offset
	_apply_pose()


func _apply_pose() -> void:
	if not _has_snapshot or _skeleton == null or _bone_idx < 0:
		return
	# `_bone` can be a stale pointer when Build Ragdoll runs while this widget
	# is still mounted: the previous MarionetteBone gets freed but our typed
	# reference doesn't auto-null. Bail rather than crash on bone_entry access.
	if not is_instance_valid(_bone):
		_has_snapshot = false
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
	var combined_flex: float = flex_v + _macro_offset.x
	var combined_rot: float = rot_v + _macro_offset.y
	var combined_abd: float = abd_v + _macro_offset.z
	var anatomical: Quaternion = AnatomicalPose.bone_local_rotation(
			_bone.bone_entry, combined_flex, combined_rot, combined_abd)
	_skeleton.set_bone_pose_rotation(_bone_idx, _rest_rotation * anatomical)
	_request_gizmo_refresh()


# Routes refresh requests through the active Marionette. Coalescing happens
# there (one pending flag per Marionette, deferred via call_deferred), so 80
# bone widgets driven by a single macro slider produce one flicker per frame.
func _request_gizmo_refresh() -> void:
	if not is_instance_valid(_marionette):
		_marionette = _resolve_marionette(_bone)
	if not is_instance_valid(_marionette):
		return
	_marionette.request_gizmo_refresh()


func _restore_rest() -> void:
	if not _has_snapshot:
		return
	if _skeleton == null or _bone_idx < 0:
		return
	if not is_instance_valid(_skeleton):
		return
	_skeleton.set_bone_pose_rotation(_bone_idx, _rest_rotation)
	# Same refresh path as _apply_pose so gizmos also snap back to rest. The
	# Marionette owns the deferred flicker, so this works even when the dock
	# is in the middle of tearing this widget out (we're about to be freed,
	# but the Marionette persists and runs the deferred call next frame).
	_request_gizmo_refresh()


# Walks up the parent chain to find the enclosing Skeleton3D. Returns null
# if the bone is detached or in a non-skeleton scene.
static func _resolve_skeleton(bone: Node) -> Skeleton3D:
	var n: Node = bone.get_parent()
	while n != null:
		if n is Skeleton3D:
			return n
		n = n.get_parent()
	return null


# Finds the owning Marionette for `bone`. Two layouts are common:
#   1. Marionette is an ancestor of Skeleton3D — e.g., Marionette/Skeleton3D.
#      Parent-chain walk wins.
#   2. Marionette is a sibling of the imported character (Marionette node next
#      to a Kasumi glb whose Skeleton3D it references via the `skeleton`
#      NodePath). Parent walk never sees it; we fall back to scanning the
#      edited scene for any Marionette whose `resolve_skeleton()` matches.
# Returns null only when the bone really has no owning Marionette (raw test
# rigs).
static func _resolve_marionette(bone: Node) -> Marionette:
	var n: Node = bone.get_parent()
	while n != null:
		if n is Marionette:
			return n
		n = n.get_parent()
	# Sibling layout: search the edited scene by skeleton match.
	var skel: Skeleton3D = _resolve_skeleton(bone)
	if skel == null or not bone.is_inside_tree():
		return null
	var scene_root: Node = bone.get_tree().edited_scene_root
	if scene_root == null:
		# Fall back to the running scene root (covers running-scene cases).
		scene_root = bone.get_tree().current_scene
	if scene_root == null:
		return null
	return _find_marionette_for_skeleton(scene_root, skel)


static func _find_marionette_for_skeleton(node: Node, skel: Skeleton3D) -> Marionette:
	if node is Marionette and (node as Marionette).resolve_skeleton() == skel:
		return node
	for child: Node in node.get_children():
		var found: Marionette = _find_marionette_for_skeleton(child, skel)
		if found != null:
			return found
	return null
