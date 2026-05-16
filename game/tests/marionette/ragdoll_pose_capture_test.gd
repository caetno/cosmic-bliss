extends Node3D

# Ragdoll pose-capture test scene — slice 5 (PinAnchor) + slice 6 (body_strain)
# hand-validation harness. Built on the existing `kasumi.tscn` rig; does not
# touch any extension code.
#
# Input scheme (LMB / RMB / MMB):
#   - LMB-click  (cursor moves < _CLICK_PIXEL_THRESHOLD between press/release):
#       central impulse on the picked bone along the camera ray.
#   - LMB-hold-drag (cursor moves >= _CLICK_PIXEL_THRESHOLD before release):
#       SOFT pin (low weight). SPD keeps fighting toward whatever target the
#       bone already has, so the rig resists the drag — that is the
#       "pose-resistance" feel. Pin clears on release; SPD target untouched.
#   - RMB-drag: HARD pin (high weight). On release, snapshot the CURRENT
#       anatomical pose for every dynamic bone and write it via
#       `marionette.set_bone_target(name, anatomical)`; pin clears. Character
#       holds whatever pose it settled into at release.
#   - MMB-drag : orbit camera around hips.
#   - Wheel    : zoom.
#
# Pose-capture conversion path:
#   The inverse of `AnatomicalPose.bone_local_rotation()` (an intrinsic
#   X→Y→Z Euler in the anatomical-basis frame) is not exposed in GDScript
#   today. Per the slice brief: degraded fallback ships now. Pose capture
#   currently calls `set_bone_target(name, Vector3.ZERO)` for every bone,
#   which clears overrides back to the rest pose (still useful for testing
#   that pose-target overrides DO survive when set). True capture-from-current
#   awaits a `MarionetteBone::current_anatomical_pose()` binding — flagged in
#   the report.

const _CAMERA_TARGET_FALLBACK: Vector3 = Vector3(0.0, 1.0, 0.0)
const _ORBIT_DIST_DEFAULT: float = 3.0
const _ORBIT_DIST_MIN: float = 0.5
const _ORBIT_DIST_MAX: float = 12.0
const _ORBIT_SENSITIVITY: float = 0.005
const _ORBIT_PITCH_LIMIT: float = 1.4
const _ZOOM_FACTOR: float = 1.15

const _DEFAULT_GRAVITY_SCALE: float = 0.3
const _DEFAULT_GLOBAL_STRENGTH: float = 1.0
const _DEFAULT_IMPULSE_MAGNITUDE: float = 1.0
const _DEFAULT_PIN_WEIGHT: float = 80.0
const _DEFAULT_PIN_WEIGHT_HARD: float = 250.0

const _PICK_RAY_LENGTH: float = 200.0
const _CLICK_PIXEL_THRESHOLD: float = 8.0

const _STRAIN_REFRESH_INTERVAL: float = 0.1
const _STRAIN_TOP_N: int = 8

const _DROP_HEIGHT: float = 2.0

@export_node_path("Marionette") var marionette_path: NodePath = ^"Kasumi/Marionette"
@export_node_path("Camera3D") var camera_path: NodePath = ^"Camera3D"

var _marionette: Marionette
var _camera: Camera3D
var _simulator: PhysicalBoneSimulator3D
var _hips_bone: MarionetteBone

# Orbit camera state.
var _orbit_yaw: float = 0.0
var _orbit_pitch: float = 0.2
var _orbit_distance: float = _ORBIT_DIST_DEFAULT
var _orbiting: bool = false

# Live tuning state (slider-backed).
var _gravity_scale: float = _DEFAULT_GRAVITY_SCALE
var _global_strength: float = _DEFAULT_GLOBAL_STRENGTH
var _impulse_magnitude: float = _DEFAULT_IMPULSE_MAGNITUDE
var _pin_weight_soft: float = _DEFAULT_PIN_WEIGHT
var _pin_weight_hard: float = _DEFAULT_PIN_WEIGHT_HARD

# Input state machine.
var _lmb_state: Dictionary = {}   # { bone, press_pos, ray_t, pinned: bool }
var _rmb_state: Dictionary = {}   # { bone, ray_t, pinned: bool }
var _paused: bool = false

# Strain panel refresh accumulator.
var _strain_accum: float = 0.0
var _strain_rows: Array[HBoxContainer] = []
var _strain_empty_label: Label
var _strain_vbox: VBoxContainer

# Static UI handles.
var _global_strength_label: Label
var _gravity_label: Label
var _impulse_label: Label
var _pin_weight_label: Label
var _pin_count_label: Label
var _pause_button: Button
var _hover_label: Label


func _ready() -> void:
	_marionette = get_node_or_null(marionette_path) as Marionette
	_camera = get_node_or_null(camera_path) as Camera3D
	if _marionette == null:
		push_error("ragdoll_pose_capture_test: marionette_path %s did not resolve" % marionette_path)
		return
	if _camera == null:
		push_error("ragdoll_pose_capture_test: camera_path %s did not resolve" % camera_path)
		return
	_simulator = _find_simulator()
	if _simulator == null:
		push_error("ragdoll_pose_capture_test: no PhysicalBoneSimulator3D — build ragdoll in editor first")
		return
	_marionette.start_simulation()
	_hips_bone = _find_bone_by_name(&"Hips")
	_marionette.set_gravity_scale(_gravity_scale)
	_marionette.set_global_strength(_global_strength)
	_build_ui()
	_update_camera_transform()


func _process(delta: float) -> void:
	_update_camera_transform()
	_update_hover_label()
	_strain_accum += delta
	if _strain_accum >= _STRAIN_REFRESH_INTERVAL:
		_strain_accum = 0.0
		_refresh_strain_panel()
		_refresh_pin_count_label()


func _physics_process(_delta: float) -> void:
	# LMB-hold-drag: re-anchor the soft pin every tick to the cursor's
	# projected world position so the bone follows the cursor while SPD
	# pushes back toward its target.
	if not _lmb_state.is_empty() and _lmb_state.get("pinned", false):
		_update_pin_for_state(_lmb_state, _pin_weight_soft)
	# RMB-drag: re-anchor the hard pin every tick.
	if not _rmb_state.is_empty() and _rmb_state.get("pinned", false):
		_update_pin_for_state(_rmb_state, _pin_weight_hard)


# ---------- Input ----------

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_begin_lmb(mb.position)
				else:
					_end_lmb(mb.position)
			MOUSE_BUTTON_RIGHT:
				if mb.pressed:
					_begin_rmb(mb.position)
				else:
					_end_rmb()
			MOUSE_BUTTON_MIDDLE:
				_orbiting = mb.pressed
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					_orbit_distance = clampf(_orbit_distance / _ZOOM_FACTOR,
							_ORBIT_DIST_MIN, _ORBIT_DIST_MAX)
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_orbit_distance = clampf(_orbit_distance * _ZOOM_FACTOR,
							_ORBIT_DIST_MIN, _ORBIT_DIST_MAX)
	elif event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event
		if _orbiting:
			_orbit_yaw -= mm.relative.x * _ORBIT_SENSITIVITY
			_orbit_pitch = clampf(_orbit_pitch - mm.relative.y * _ORBIT_SENSITIVITY,
					-_ORBIT_PITCH_LIMIT, _ORBIT_PITCH_LIMIT)
		# Promote LMB to drag-pin once the cursor exceeds the click threshold.
		if not _lmb_state.is_empty() and not _lmb_state.get("pinned", false):
			var press_pos: Vector2 = _lmb_state["press_pos"]
			if (mm.position - press_pos).length() >= _CLICK_PIXEL_THRESHOLD:
				_promote_lmb_to_pin()


# ---------- LMB ----------

func _begin_lmb(screen_pos: Vector2) -> void:
	_lmb_state.clear()
	var hit: Dictionary = _raycast(screen_pos)
	if hit.is_empty():
		return
	var collider: Object = hit.get("collider")
	if not (collider is MarionetteBone):
		return
	var bone: MarionetteBone = collider
	var hit_world: Vector3 = hit["position"]
	var origin: Vector3 = _camera.project_ray_origin(screen_pos)
	var direction: Vector3 = _camera.project_ray_normal(screen_pos)
	var ray_t: float = (hit_world - origin).dot(direction)
	_lmb_state = {
		"bone": bone,
		"press_pos": screen_pos,
		"ray_t": ray_t,
		"pinned": false,
	}


func _promote_lmb_to_pin() -> void:
	if _lmb_state.is_empty():
		return
	var bone: MarionetteBone = _lmb_state.get("bone")
	if not is_instance_valid(bone):
		_lmb_state.clear()
		return
	_lmb_state["pinned"] = true
	# Anchor will be set inside _update_pin_for_state on the next tick.


func _end_lmb(release_pos: Vector2) -> void:
	if _lmb_state.is_empty():
		return
	var bone: MarionetteBone = _lmb_state.get("bone")
	var press_pos: Vector2 = _lmb_state["press_pos"]
	var pinned: bool = _lmb_state.get("pinned", false)
	if pinned:
		# Drag — clear the soft pin, leave SPD target alone.
		if is_instance_valid(bone):
			_marionette.remove_pin_anchor(_anatomical_name_for(bone))
	elif (release_pos - press_pos).length() < _CLICK_PIXEL_THRESHOLD \
			and is_instance_valid(bone):
		# Click — apply impulse along the camera ray.
		var direction: Vector3 = _camera.project_ray_normal(release_pos)
		bone.apply_central_impulse(direction * _impulse_magnitude)
	_lmb_state.clear()


# ---------- RMB ----------

func _begin_rmb(screen_pos: Vector2) -> void:
	_rmb_state.clear()
	var hit: Dictionary = _raycast(screen_pos)
	if hit.is_empty():
		return
	var collider: Object = hit.get("collider")
	if not (collider is MarionetteBone):
		return
	var bone: MarionetteBone = collider
	var hit_world: Vector3 = hit["position"]
	var origin: Vector3 = _camera.project_ray_origin(screen_pos)
	var direction: Vector3 = _camera.project_ray_normal(screen_pos)
	var ray_t: float = (hit_world - origin).dot(direction)
	_rmb_state = {
		"bone": bone,
		"ray_t": ray_t,
		"pinned": true,
	}


func _end_rmb() -> void:
	if _rmb_state.is_empty():
		return
	var bone: MarionetteBone = _rmb_state.get("bone")
	if is_instance_valid(bone):
		_marionette.remove_pin_anchor(_anatomical_name_for(bone))
	_capture_whole_body_pose()
	_rmb_state.clear()


# ---------- Pin update ----------

# Re-anchors a hard or soft pin to the cursor's current projected world
# position. Called from _physics_process every tick for any active pin.
func _update_pin_for_state(state: Dictionary, weight: float) -> void:
	var bone: MarionetteBone = state.get("bone")
	if not is_instance_valid(bone) or _camera == null:
		return
	var screen_pos: Vector2 = get_viewport().get_mouse_position()
	var origin: Vector3 = _camera.project_ray_origin(screen_pos)
	var direction: Vector3 = _camera.project_ray_normal(screen_pos)
	var ray_t: float = state["ray_t"]
	var target_world: Vector3 = origin + direction * ray_t
	_marionette.add_pin_anchor(_anatomical_name_for(bone), target_world, weight)


# ---------- Pose capture (DEGRADED — see header) ----------

# Whole-body pose capture. Per the slice brief: the inverse anatomical
# conversion (bone-local quaternion → flex/rot/abd) is not exposed in
# GDScript. Ship the degraded variant — `set_bone_target(Vector3.ZERO)`
# for every dynamic bone — so the user can confirm `set_bone_target`
# overrides ARE getting through (and supervisor decides whether to add
# the binding in a follow-up).
func _capture_whole_body_pose() -> void:
	if _marionette == null or _simulator == null:
		return
	for child: Node in _simulator.get_children():
		if not (child is MarionetteBone):
			continue
		var bone: MarionetteBone = child
		var name: StringName = _anatomical_name_for(bone)
		if name == StringName():
			continue
		# TODO(P10.next): replace with real capture via
		# MarionetteBone::current_anatomical_pose() once that binding exists.
		# Today: zero anatomical = "rest" target for the bone (matches the
		# convention in AnatomicalPose.bone_local_rotation where input is
		# already rest-offset-subtracted).
		_marionette.set_bone_target(name, Vector3.ZERO)


# ---------- Reset / drop ----------

func _reset_targets() -> void:
	if _marionette == null or _simulator == null:
		return
	for child: Node in _simulator.get_children():
		if not (child is MarionetteBone):
			continue
		var name: StringName = _anatomical_name_for(child as MarionetteBone)
		if name == StringName():
			continue
		_marionette.set_bone_target(name, Vector3.ZERO)
	_marionette.clear_pin_anchors()


func _drop_ragdoll() -> void:
	if _marionette == null:
		return
	_marionette.clear_pin_anchors()
	var skel: Skeleton3D = _marionette.resolve_skeleton()
	if skel == null:
		return
	var kasumi: Node3D = get_node_or_null(^"Kasumi") as Node3D
	if kasumi != null:
		var prior: Transform3D = kasumi.global_transform
		kasumi.global_position = Vector3(prior.origin.x, _DROP_HEIGHT, prior.origin.z)
	# Force one physics tick so the new transform propagates before
	# `physical_bones_start_simulation` rewires.
	var prior_scale: float = Engine.time_scale
	Engine.time_scale = 1.0
	await get_tree().physics_frame
	Engine.time_scale = prior_scale
	_marionette.start_simulation()


# ---------- Strain panel ----------

func _refresh_strain_panel() -> void:
	if _strain_vbox == null:
		return
	var dict: Dictionary = _marionette.get_body_strain() if _marionette != null else {}
	if dict.is_empty():
		_strain_empty_label.visible = true
		for row: HBoxContainer in _strain_rows:
			row.visible = false
		return
	_strain_empty_label.visible = false
	# Build sorted (descending) array of [name, value] pairs.
	var entries: Array = []
	for key: StringName in dict.keys():
		entries.append([key, float(dict[key])])
	entries.sort_custom(func(a, b): return float(a[1]) > float(b[1]))
	var count: int = mini(_STRAIN_TOP_N, entries.size())
	for i: int in range(_strain_rows.size()):
		var row: HBoxContainer = _strain_rows[i]
		if i >= count:
			row.visible = false
			continue
		row.visible = true
		var name_label: Label = row.get_child(0) as Label
		var value_label: Label = row.get_child(1) as Label
		name_label.text = String(entries[i][0])
		value_label.text = "%.3f" % float(entries[i][1])


func _refresh_pin_count_label() -> void:
	if _pin_count_label == null or _marionette == null:
		return
	_pin_count_label.text = "Active pins: %d" % _marionette.get_pin_anchor_count()


# ---------- Camera ----------

func _update_camera_transform() -> void:
	if _camera == null:
		return
	var target: Vector3 = _hips_bone.global_position if is_instance_valid(_hips_bone) \
			else _CAMERA_TARGET_FALLBACK
	var offset := Vector3(0.0, 0.0, _orbit_distance)
	offset = offset.rotated(Vector3.RIGHT, -_orbit_pitch)
	offset = offset.rotated(Vector3.UP, _orbit_yaw)
	_camera.global_position = target + offset
	_camera.look_at(target, Vector3.UP)


# ---------- Hover label ----------

func _update_hover_label() -> void:
	if _hover_label == null:
		return
	var screen_pos: Vector2 = get_viewport().get_mouse_position()
	var hit: Dictionary = _raycast(screen_pos)
	var collider: Object = hit.get("collider") if not hit.is_empty() else null
	if collider is MarionetteBone:
		var bone: MarionetteBone = collider
		_hover_label.text = String(_anatomical_name_for(bone))
		_hover_label.position = screen_pos + Vector2(12.0, -16.0)
		_hover_label.visible = true
	else:
		_hover_label.visible = false


# ---------- Helpers ----------

func _raycast(screen_pos: Vector2) -> Dictionary:
	if _camera == null:
		return {}
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var origin: Vector3 = _camera.project_ray_origin(screen_pos)
	var direction: Vector3 = _camera.project_ray_normal(screen_pos)
	var query := PhysicsRayQueryParameters3D.create(
			origin, origin + direction * _PICK_RAY_LENGTH)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	return space.intersect_ray(query)


func _find_simulator() -> PhysicalBoneSimulator3D:
	if _marionette == null:
		return null
	var skel: Skeleton3D = _marionette.resolve_skeleton()
	if skel == null:
		return null
	for child: Node in skel.get_children():
		if child is PhysicalBoneSimulator3D:
			return child
	return null


func _find_bone_by_name(target_name: StringName) -> MarionetteBone:
	if _simulator == null:
		return null
	for child: Node in _simulator.get_children():
		if child is MarionetteBone and StringName((child as MarionetteBone).bone_name) == target_name:
			return child
	return null


# Returns the bone's anatomical name (BoneProfile key), falling back to its
# scene-node name. `add_pin_anchor` / `set_bone_target` / strain dict all key
# on this name.
func _anatomical_name_for(bone: MarionetteBone) -> StringName:
	if bone == null:
		return StringName()
	# MarionetteBone exposes get_anatomical_name() (bound in C++); fall back
	# to the scene-node name in the unlikely case it's empty.
	var n: StringName = bone.get_anatomical_name()
	if n == StringName():
		n = StringName(bone.name)
	return n


# ---------- UI ----------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "UI"
	add_child(layer)

	var root_ctrl := Control.new()
	root_ctrl.anchor_right = 1.0
	root_ctrl.anchor_bottom = 1.0
	root_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root_ctrl)

	# Floating hover label (anywhere on screen).
	_hover_label = Label.new()
	_hover_label.add_theme_color_override(&"font_color", Color(1, 1, 0.6))
	_hover_label.add_theme_color_override(&"font_outline_color", Color(0, 0, 0))
	_hover_label.add_theme_constant_override(&"outline_size", 4)
	_hover_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hover_label.visible = false
	root_ctrl.add_child(_hover_label)

	var margin := MarginContainer.new()
	margin.anchor_bottom = 1.0
	margin.add_theme_constant_override(&"margin_left", 8)
	margin.add_theme_constant_override(&"margin_top", 8)
	margin.add_theme_constant_override(&"margin_right", 8)
	margin.add_theme_constant_override(&"margin_bottom", 8)
	margin.custom_minimum_size = Vector2(340.0, 0.0)
	margin.mouse_filter = Control.MOUSE_FILTER_PASS
	root_ctrl.add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_FILL
	scroll.size_flags_vertical = Control.SIZE_FILL
	margin.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override(&"separation", 6)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	_build_controls_panel(vbox)
	_build_pose_panel(vbox)
	_build_strength_panel(vbox)
	_build_gravity_panel(vbox)
	_build_impulse_panel(vbox)
	_build_pin_panel(vbox)
	_build_strain_panel(vbox)


func _make_panel(parent: Container, title: String) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(panel)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override(&"separation", 4)
	panel.add_child(inner)
	var header := Label.new()
	header.text = title
	header.add_theme_color_override(&"font_color", Color(0.95, 0.9, 0.6))
	inner.add_child(header)
	return inner


func _build_controls_panel(parent: Container) -> void:
	var inner: VBoxContainer = _make_panel(parent, "Controls")
	var hint := Label.new()
	hint.text = (
		"LMB click       impulse picked bone\n"
		+ "LMB hold-drag   soft pin (resists drag)\n"
		+ "RMB drag        hard pin + pose-capture on release\n"
		+ "MMB drag        orbit camera\n"
		+ "Mouse wheel     zoom"
	)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_child(hint)


func _build_pose_panel(parent: Container) -> void:
	var inner: VBoxContainer = _make_panel(parent, "Pose")
	var reset_btn := Button.new()
	reset_btn.text = "Reset targets (clear overrides)"
	reset_btn.pressed.connect(_reset_targets)
	inner.add_child(reset_btn)

	var drop_btn := Button.new()
	drop_btn.text = "Drop ragdoll (2 m, full gravity)"
	drop_btn.pressed.connect(_drop_ragdoll)
	inner.add_child(drop_btn)

	_pause_button = Button.new()
	_pause_button.text = "Pause"
	_pause_button.toggle_mode = true
	_pause_button.toggled.connect(_on_pause_toggled)
	inner.add_child(_pause_button)


func _on_pause_toggled(pressed: bool) -> void:
	_paused = pressed
	Engine.time_scale = 0.0 if pressed else 1.0
	_pause_button.text = "Resume" if pressed else "Pause"


func _build_strength_panel(parent: Container) -> void:
	var inner: VBoxContainer = _make_panel(parent, "Strength")
	_global_strength_label = Label.new()
	_global_strength_label.text = "Global strength: %.2f" % _global_strength
	inner.add_child(_global_strength_label)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 2.0
	slider.step = 0.01
	slider.value = _global_strength
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(_on_global_strength_changed)
	inner.add_child(slider)


func _on_global_strength_changed(v: float) -> void:
	_global_strength = v
	_global_strength_label.text = "Global strength: %.2f" % v
	if _marionette != null:
		_marionette.set_global_strength(v)


func _build_gravity_panel(parent: Container) -> void:
	var inner: VBoxContainer = _make_panel(parent, "Gravity")
	_gravity_label = Label.new()
	_gravity_label.text = "Gravity scale: %.2f" % _gravity_scale
	inner.add_child(_gravity_label)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.5
	slider.step = 0.01
	slider.value = _gravity_scale
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(_on_gravity_changed)
	inner.add_child(slider)


func _on_gravity_changed(v: float) -> void:
	_gravity_scale = v
	_gravity_label.text = "Gravity scale: %.2f" % v
	if _marionette != null:
		_marionette.set_gravity_scale(v)


func _build_impulse_panel(parent: Container) -> void:
	var inner: VBoxContainer = _make_panel(parent, "Impulse (LMB click)")
	_impulse_label = Label.new()
	_impulse_label.text = "Magnitude: %.2f N s" % _impulse_magnitude
	inner.add_child(_impulse_label)
	var slider := HSlider.new()
	slider.min_value = 0.1
	slider.max_value = 5.0
	slider.step = 0.05
	slider.value = _impulse_magnitude
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(_on_impulse_changed)
	inner.add_child(slider)


func _on_impulse_changed(v: float) -> void:
	_impulse_magnitude = v
	_impulse_label.text = "Magnitude: %.2f N s" % v


func _build_pin_panel(parent: Container) -> void:
	var inner: VBoxContainer = _make_panel(parent, "Pin weight")
	_pin_weight_label = Label.new()
	_pin_weight_label.text = "Hard (RMB): %.0f  /  Soft (LMB-hold): %.0f" \
			% [_pin_weight_hard, _pin_weight_soft]
	inner.add_child(_pin_weight_label)
	var slider := HSlider.new()
	slider.min_value = 1.0
	slider.max_value = 500.0
	slider.step = 1.0
	slider.value = _pin_weight_hard
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(_on_pin_hard_changed)
	inner.add_child(slider)

	var slider2 := HSlider.new()
	slider2.min_value = 1.0
	slider2.max_value = 500.0
	slider2.step = 1.0
	slider2.value = _pin_weight_soft
	slider2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider2.value_changed.connect(_on_pin_soft_changed)
	inner.add_child(slider2)

	var clear_btn := Button.new()
	clear_btn.text = "Clear all pins"
	clear_btn.pressed.connect(_on_clear_pins_pressed)
	inner.add_child(clear_btn)

	_pin_count_label = Label.new()
	_pin_count_label.text = "Active pins: 0"
	inner.add_child(_pin_count_label)


func _on_clear_pins_pressed() -> void:
	if _marionette != null:
		_marionette.clear_pin_anchors()


func _on_pin_hard_changed(v: float) -> void:
	_pin_weight_hard = v
	_pin_weight_label.text = "Hard (RMB): %.0f  /  Soft (LMB-hold): %.0f" \
			% [_pin_weight_hard, _pin_weight_soft]


func _on_pin_soft_changed(v: float) -> void:
	_pin_weight_soft = v
	_pin_weight_label.text = "Hard (RMB): %.0f  /  Soft (LMB-hold): %.0f" \
			% [_pin_weight_hard, _pin_weight_soft]


func _build_strain_panel(parent: Container) -> void:
	var inner: VBoxContainer = _make_panel(parent, "Body strain (top 8)")
	_strain_vbox = inner
	_strain_empty_label = Label.new()
	_strain_empty_label.text = "no strain data"
	_strain_empty_label.add_theme_color_override(&"font_color", Color(0.7, 0.7, 0.7))
	inner.add_child(_strain_empty_label)
	_strain_rows.clear()
	for i: int in range(_STRAIN_TOP_N):
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_lbl := Label.new()
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.text = ""
		row.add_child(name_lbl)
		var value_lbl := Label.new()
		value_lbl.add_theme_color_override(&"font_color", Color(0.7, 0.9, 1.0))
		value_lbl.text = ""
		row.add_child(value_lbl)
		row.visible = false
		inner.add_child(row)
		_strain_rows.append(row)
