extends Node3D

# Anatomical-target XY pad. Square Control mapping cursor position to
# (flex, abd) anatomical angles in [-range_rad, +range_rad]; LMB-drag
# writes the target into MarionetteCore via `Marionette.set_bone_target`.
# Medial / lateral rotation (anatomical Y) is preserved from the bone's
# current pose — pad only owns the X/Z axes.
#
# Coordinate mapping (CLAUDE.md §2 anatomical frame):
#   pad-local +X  →  +flex  (anatomical.x +)
#   pad-local +Y  →  +abd   (anatomical.z +, displayed inverted because UI
#                            Y axis points down)
#
# When NOT being dragged, the dot live-tracks the bone's actual anatomical
# pose (so cross-chain motion from another pad or pin shows up here). On
# press, the pad emits `drag_started`; the test scene uses that to snapshot
# all bones and boost global_strength so OTHER joints lock in place while
# the dragged joint moves freely.
class JointPad extends Control:
	signal drag_started
	signal drag_ended

	var bone_name: StringName = &""
	var marionette = null
	var bone_ref: MarionetteBone = null
	var range_rad: float = PI / 2.0
	var target: Vector3 = Vector3.ZERO

	var _dragging: bool = false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		set_process(true)
		# Initialize dot to whatever pose the bone is currently in — at
		# scene-ready time that's the rest pose with `rest_anatomical_offset`
		# baked in, NOT identity Vector3.ZERO. Without this the dot starts
		# centered while the bone is actually offset, lying about state.
		if bone_ref != null:
			target = bone_ref.current_anatomical_pose()
			queue_redraw()

	func _process(_delta: float) -> void:
		# Live-sync the dot to the bone's actual pose when not being
		# dragged. During drag the dot follows the cursor (target) so the
		# user sees their intended target, even if SPD hasn't reached it.
		if _dragging or bone_ref == null:
			return
		var pose: Vector3 = bone_ref.current_anatomical_pose()
		if not target.is_equal_approx(pose):
			target = pose
			queue_redraw()

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mb: InputEventMouseButton = event
			if mb.button_index == MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_dragging = true
					drag_started.emit()
					_apply_from_local(mb.position)
				else:
					_dragging = false
					drag_ended.emit()
			elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
				# RMB on the pad zeros the target — quick reset for one joint.
				target = Vector3.ZERO
				if marionette != null:
					marionette.set_bone_target(bone_name, target)
				queue_redraw()
		elif event is InputEventMouseMotion:
			var mm: InputEventMouseMotion = event
			if _dragging and (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
				_apply_from_local(mm.position)

	func _apply_from_local(local: Vector2) -> void:
		var s: Vector2 = size
		var flex: float = clampf((local.x / s.x - 0.5) * 2.0 * range_rad,
				-range_rad, range_rad)
		var abd: float = clampf((0.5 - local.y / s.y) * 2.0 * range_rad,
				-range_rad, range_rad)
		# Preserve medial rotation (Y) from the bone's current pose — pad
		# only authors X and Z, so zeroing Y would silently nuke any twist
		# the user set elsewhere.
		var preserved_y: float = 0.0
		if bone_ref != null:
			preserved_y = bone_ref.current_anatomical_pose().y
		target = Vector3(flex, preserved_y, abd)
		if marionette != null:
			marionette.set_bone_target(bone_name, target)
		queue_redraw()

	func _draw() -> void:
		var s: Vector2 = size
		var rect := Rect2(Vector2.ZERO, s)
		draw_rect(rect, Color(0.10, 0.10, 0.13), true)
		# Axes (center cross).
		var c: Vector2 = s * 0.5
		draw_line(Vector2(c.x, 0.0), Vector2(c.x, s.y), Color(0.28, 0.28, 0.33), 1.0)
		draw_line(Vector2(0.0, c.y), Vector2(s.x, c.y), Color(0.28, 0.28, 0.33), 1.0)
		# Target dot.
		var dot := Vector2(
			(target.x / range_rad * 0.5 + 0.5) * s.x,
			(0.5 - target.z / range_rad * 0.5) * s.y,
		)
		var color: Color = Color(1.0, 0.5, 0.2) if _dragging else Color(1.0, 0.85, 0.25)
		draw_circle(dot, 5.0, color)
		# Border.
		draw_rect(rect, Color(0.45, 0.45, 0.5), false, 1.0)


# Ragdoll pose-capture test scene — redesigned 2026-05-16.
# Built on the existing `kasumi.tscn` rig; touches no extension code.
#
# Controls:
#   LMB drag      drag picked bone (anchor locked at pick depth)
#   Shift+wheel   adjust drag depth (push / pull along camera ray) while dragging
#   RMB drag      orbit camera around target
#   MMB drag      pan camera target along camera right / up
#   Wheel         zoom (orbit distance)
#   C             capture current whole-body pose into SPD targets
#   R             reset SPD targets to T-pose (zero anatomical)
#   X             clear all pins
#   F / Home      recenter camera on hips
#   Space         pause / resume
#
# Authoring flow:
#   1. Drag bones into position (LMB).
#   2. Press C while still holding to snapshot.
#   3. Release — SPD now holds the captured pose.
#
# Defaults: gravity scale 0.0 (zero-g, body floats), linear damping 8.0 per
# bone so the pin spring critically damps without the C++ side gaining a
# damping term. The pin force in `MarionetteBone::_integrate_forces` is a
# pure undamped spring (`F = w·(anchor − bone)`); without per-bone linear
# damping it ringed visibly at any usable weight, which read as "the pin
# doesn't track the cursor" — bone orbited the anchor instead of settling.

const _ORBIT_DIST_DEFAULT: float = 3.0
const _ORBIT_DIST_MIN: float = 0.5
const _ORBIT_DIST_MAX: float = 12.0
const _ORBIT_SENSITIVITY: float = 0.005
const _ORBIT_PITCH_LIMIT: float = 1.4
const _ZOOM_FACTOR: float = 1.15
const _PAN_SENSITIVITY: float = 0.0018
const _DEPTH_FACTOR: float = 1.12
const _DEPTH_MIN: float = 0.1
const _DEPTH_MAX: float = 50.0

const _DEFAULT_GRAVITY_SCALE: float = 0.0     # zero-g per user spec
# Strength 0 = limp ragdoll. SPD torque is `bone_strength · global_strength`,
# so at 0 the SPD path produces zero torque — bones don't fight the pin and
# the chain doesn't feed back into itself. Raise via the slider to engage
# SPD (which then holds whatever pose was last snapshotted via `C`).
const _DEFAULT_GLOBAL_STRENGTH: float = 0.0
const _DEFAULT_PIN_WEIGHT: float = 500.0

# Joints to expose in the 2D-pad authoring grid. Order = display order
# (left/right pairs adjacent). Bones not present in the simulator are
# skipped — non-humanoid skeletons fall through gracefully.
const _PAD_BONES: Array[StringName] = [
	&"Neck", &"Head",
	&"Spine", &"Chest",
	&"LeftUpperArm", &"RightUpperArm",
	&"LeftLowerArm", &"RightLowerArm",
	&"LeftHand", &"RightHand",
	&"LeftUpperLeg", &"RightUpperLeg",
	&"LeftLowerLeg", &"RightLowerLeg",
	&"LeftFoot", &"RightFoot",
]
const _PAD_RANGE_RAD: float = PI / 2.0   # ±90° on each axis
const _PAD_SIZE: Vector2 = Vector2(80.0, 80.0)

# Bounds the pin's effective leash. Cursor projection may land arbitrarily
# far from the bone; clamping to `_MAX_PULL_DISTANCE` keeps `F = w·d` from
# producing the wild slingshot accelerations that made dragging unusable.
const _MAX_PULL_DISTANCE: float = 0.5

const _PICK_RAY_LENGTH: float = 200.0

const _STRAIN_REFRESH_INTERVAL: float = 0.1
const _STRAIN_TOP_N: int = 8

const _DROP_HEIGHT: float = 2.0
const _DROP_GRAVITY_SCALE: float = 1.0

const _ANCHOR_COLOR: Color = Color(0.45, 1.0, 1.0)

@export_node_path("Marionette") var marionette_path: NodePath = ^"Kasumi/Marionette"
@export_node_path("Camera3D") var camera_path: NodePath = ^"Camera3D"

var _marionette: Marionette
var _camera: Camera3D
var _simulator: PhysicalBoneSimulator3D
var _hips_bone: MarionetteBone

# Orbit camera state. `_orbit_target` is held in world space and only moves
# from user action (pan / recenter) — no per-frame auto-follow, which would
# fight a panned camera.
var _orbit_target: Vector3 = Vector3(0.0, 1.0, 0.0)
var _orbit_yaw: float = 0.0
var _orbit_pitch: float = 0.2
var _orbit_distance: float = _ORBIT_DIST_DEFAULT
var _orbiting: bool = false
var _panning: bool = false

# Live tuning state (slider-backed).
var _gravity_scale: float = _DEFAULT_GRAVITY_SCALE
var _global_strength: float = _DEFAULT_GLOBAL_STRENGTH
var _pin_weight: float = _DEFAULT_PIN_WEIGHT

# Drag state.
var _drag_active: bool = false
var _drag_bone: MarionetteBone = null
var _drag_depth: float = 1.0
var _drag_anchor_world: Vector3 = Vector3.ZERO

# Pin history — append on `_end_drag` (for NEW pin), pop on
# `_remove_latest_pin`. Mirrors the order of distinct bones pinned.
var _pin_history: Array[StringName] = []

# Pad-drag isolation state. While a JointPad is being dragged, the test
# scene boosts `global_strength` so the SPD locks every non-dragged bone
# at its just-snapshotted pose; the dragged bone's target is overwritten
# each frame by the pad. On release, the user's pre-drag strength is
# restored (so opting back into limp mode survives the drag).
var _pad_drag_active: bool = false
var _pad_drag_saved_strength: float = 0.0
const _PAD_DRAG_ISOLATE_STRENGTH: float = 3.0

# Strain panel accumulator.
var _strain_accum: float = 0.0
var _strain_rows: Array[HBoxContainer] = []
var _strain_empty_label: Label
var _strain_vbox: VBoxContainer
var _paused: bool = false

# UI handles.
var _global_strength_label: Label
var _gravity_label: Label
var _pin_weight_label: Label
var _pin_count_label: Label
var _pause_button: Button
var _hover_label: Label
var _status_label: Label

# Anchor visualization (drag-time only).
var _anchor_marker: MeshInstance3D
var _anchor_line: MeshInstance3D
var _anchor_line_mesh: ImmediateMesh
var _anchor_line_material: StandardMaterial3D


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
	# Sleep-disable every bone. Jolt aggressively puts at-rest dynamic
	# bodies to sleep, and a sleeping body silently swallows
	# `apply_central_impulse` — drag pulls nothing. For a debug / authoring
	# scene we don't care about the sleep CPU savings.
	_disable_sleep_on_bones()
	# (Spring disable used to be applied as a runtime sweep here; that
	# logic now lives in `MarionetteBone::set_disable_builtin_springs` /
	# `_notification(NOTIFICATION_READY)`, default true. Verifying that
	# path is the point of this test cycle — if springs come back, the
	# property isn't applying when expected.)
	# Flip POWERED bones off custom_integrator so Jolt's engine integrator
	# applies `linear_damp` / `angular_damp` again. SPD and pin no longer
	# live in `_integrate_forces` (both moved to MarionetteCore), so the
	# original reason for `custom_integrator = true` (gate the integrator
	# callback) is moot — empty callback either way. With engine damping
	# back on, joint-constraint micro-noise that propagates through the
	# chain settles instead of pumping into a perpetual ringing loop at
	# `global_strength = 0` (where SPD's `kd` damping is also zero).
	# Engine damping audit (2026-05-17): dropped 4.0 → 1.0. Old value
	# pre-dated SPD providing its own inertia-correct `kd` term, and
	# stacked on top of SPD now over-damps active hold + suppresses
	# natural limp-arm swing at `strength = 0`. 1.0 ≈ Godot project
	# default, leaves room for SPD's damping to do most of the work.
	_enable_engine_damping_on_bones(1.0, 1.0)
	_seed_passive_tensions()
	if is_instance_valid(_hips_bone):
		_orbit_target = _hips_bone.global_position
	_build_anchor_viz()
	_build_ui()
	_set_status("Ready — LMB drag a bone, C captures, RMB orbit")
	_update_camera_transform()
	# Defer the SPD target snapshot until the simulator's first physics tick
	# finalizes bone positions. Jolt's joint constraint solver typically
	# shifts bones a hair from the skeleton's rest pose on the kinematic→
	# dynamic transition; snapshotting BEFORE that shift seeds targets that
	# don't match what `_integrate_forces` sees on tick 1, which gives SPD a
	# non-zero tracking error to chew on. One frame of latency here avoids
	# that whole class of seed-versus-settled mismatch.
	await get_tree().physics_frame
	_marionette.snapshot_pose_to_targets()


func _process(_delta: float) -> void:
	_update_camera_transform()
	_update_hover_label()
	_update_anchor_viz()
	_strain_accum += _delta
	if _strain_accum >= _STRAIN_REFRESH_INTERVAL:
		_strain_accum = 0.0
		_refresh_strain_panel()
		_refresh_pin_count_label()


func _physics_process(_delta: float) -> void:
	if _drag_active and is_instance_valid(_drag_bone):
		var cursor: Vector2 = get_viewport().get_mouse_position()
		var projected: Vector3 = _project_cursor_to_depth(cursor, _drag_depth)
		_drag_anchor_world = _clamp_anchor(_drag_bone.global_position, projected, _MAX_PULL_DISTANCE)
		var bone_name: StringName = _anatomical_name_for(_drag_bone)
		_marionette.add_pin_anchor(bone_name, _drag_anchor_world, _pin_weight)
		_dump_drag_diag(bone_name)


# Per-second diagnostic during drag. Prints whether the bone is POWERED
# (gate that decides whether `_integrate_forces` runs the pin code at
# all), whether the anchor reached the core's map, and what the bone's
# linear velocity / displacement-to-anchor look like — so we can tell
# whether the force is being applied but the bone is constrained, or
# whether the force isn't reaching at all.
var _diag_accum: float = 0.0
func _dump_drag_diag(bone_name: StringName) -> void:
	_diag_accum += get_physics_process_delta_time()
	if _diag_accum < 0.5:
		return
	_diag_accum = 0.0
	if not is_instance_valid(_drag_bone) or _marionette == null:
		return
	var b: PhysicalBone3D = _drag_bone
	var d: Vector3 = _drag_anchor_world - b.global_position
	print("[drag] %s  pins=%d  |v|=%.3f  |d|=%.3f  pos=%v  mass=%.2f  g_scale=%.2f"
			% [
				String(bone_name),
				_marionette.get_pin_anchor_count(),
				b.linear_velocity.length(),
				d.length(),
				b.global_position,
				b.mass,
				b.gravity_scale,
			])


# ---------- Input ----------
#
# Mouse-button PRESSES route through `_unhandled_input` so a click on a UI
# Button (which consumes the event in `_gui_input`) never bleeds through to
# trigger a 3D drag or camera orbit. Mouse-button RELEASES route through
# `_input` so the orbit / pan / drag flags always clear, even if the press
# happened in 3D and the release lands over a UI panel. Mouse motion is
# guarded by the flags themselves, so it's safe to handle in `_input`.
# Key events go through `_unhandled_input` so Space activates a focused
# Button via UI instead of also firing the hotkey (avoids double-toggle).

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if not mb.pressed:
			return  # releases handled in _input
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				_begin_drag(mb.position)
			MOUSE_BUTTON_RIGHT:
				# RMB during an in-progress LMB drag = cancel: clear the
				# pin without leaving a persistent anchor and without
				# capturing the pose. Otherwise (no active drag), RMB is
				# the camera orbit start.
				if _drag_active:
					_cancel_drag()
				else:
					_orbiting = true
			MOUSE_BUTTON_MIDDLE:
				_panning = true
			MOUSE_BUTTON_WHEEL_UP:
				_handle_wheel(mb.shift_pressed, true)
			MOUSE_BUTTON_WHEEL_DOWN:
				_handle_wheel(mb.shift_pressed, false)
	elif event is InputEventKey:
		var k: InputEventKey = event
		if not k.pressed or k.echo:
			return
		match k.keycode:
			KEY_C:
				_capture_pose()
			KEY_R:
				if k.shift_pressed:
					_reset_rig()
				else:
					_reset_targets()
			KEY_X:
				_on_clear_pins_pressed()
			KEY_Z:
				_remove_latest_pin()
			KEY_F, KEY_HOME:
				_recenter_on_hips()
			KEY_SPACE:
				# Drive the toggle through the button so its visual state
				# and the `toggled` signal stay in sync — calling
				# `_toggle_pause` directly would skip the button widget.
				if _pause_button != null:
					_pause_button.button_pressed = not _pause_button.button_pressed


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.pressed:
			return  # presses handled in _unhandled_input
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				_end_drag()
			MOUSE_BUTTON_RIGHT:
				_orbiting = false
			MOUSE_BUTTON_MIDDLE:
				_panning = false
	elif event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event
		if _orbiting:
			_orbit_yaw -= mm.relative.x * _ORBIT_SENSITIVITY
			_orbit_pitch = clampf(_orbit_pitch - mm.relative.y * _ORBIT_SENSITIVITY,
					-_ORBIT_PITCH_LIMIT, _ORBIT_PITCH_LIMIT)
		if _panning and _camera != null:
			var basis: Basis = _camera.global_transform.basis
			var step: float = _orbit_distance * _PAN_SENSITIVITY
			_orbit_target -= basis.x * mm.relative.x * step
			_orbit_target += basis.y * mm.relative.y * step


func _handle_wheel(shift_held: bool, up: bool) -> void:
	if shift_held and _drag_active:
		var factor: float = (1.0 / _DEPTH_FACTOR) if up else _DEPTH_FACTOR
		_drag_depth = clampf(_drag_depth * factor, _DEPTH_MIN, _DEPTH_MAX)
		return
	var zfactor: float = (1.0 / _ZOOM_FACTOR) if up else _ZOOM_FACTOR
	_orbit_distance = clampf(_orbit_distance * zfactor,
			_ORBIT_DIST_MIN, _ORBIT_DIST_MAX)


# ---------- Bone drag ----------

func _begin_drag(screen_pos: Vector2) -> void:
	_drag_active = false
	_drag_bone = null
	var hit: Dictionary = _raycast(screen_pos)
	if hit.is_empty():
		return
	var collider: Object = hit.get("collider")
	if not (collider is MarionetteBone):
		return
	_drag_bone = collider as MarionetteBone
	var bone_world: Vector3 = _drag_bone.global_position
	var origin: Vector3 = _camera.project_ray_origin(screen_pos)
	var direction: Vector3 = _camera.project_ray_normal(screen_pos)
	_drag_depth = clampf((bone_world - origin).dot(direction), _DEPTH_MIN, _DEPTH_MAX)
	_drag_anchor_world = bone_world
	_drag_active = true
	_set_status("Dragging %s — release to clear pin (press C to capture first)"
			% String(_anatomical_name_for(_drag_bone)))


func _end_drag() -> void:
	if not _drag_active:
		return
	_drag_active = false
	if is_instance_valid(_drag_bone):
		# Capture the pose first (SPD targets ← current world configuration,
		# while the pin still holds the bone at the dragged position — no
		# drift window between capture and SPD takeover).
		_capture_pose()
		# Re-anchor the pin AT the bone's current position (zeroing the
		# spring force) and leave it in `pin_anchors`. Persistent pins are
		# the multi-bone authoring affordance: drag bone A → release leaves
		# pin A at bone A's position → drag bone B → release leaves pin B
		# → both bones held by SPD + zero-force pins, count = 2. X clears
		# all when done. Subsequent drags of the same bone just overwrite
		# its pin (add_pin_anchor replaces by anatomical_name).
		var bone_name: StringName = _anatomical_name_for(_drag_bone)
		_marionette.add_pin_anchor(bone_name, _drag_bone.global_position, _pin_weight)
		# History tracking for the "Remove latest pin" button — append only
		# if this is a NEW pin; re-dragging an already-pinned bone just
		# updates its position, not its history entry.
		if not _pin_history.has(bone_name):
			_pin_history.append(bone_name)
		_set_status("Released %s — pose captured, pin held at drop location"
				% String(bone_name))
	_drag_bone = null


# RMB-while-LMB cancel path. Clears the pin (rather than re-anchoring it
# at the bone position) and skips the pose capture — exits as if the
# drag never happened. Pose state is unchanged.
func _cancel_drag() -> void:
	if not _drag_active:
		return
	_drag_active = false
	if is_instance_valid(_drag_bone):
		var bone_name: StringName = _anatomical_name_for(_drag_bone)
		_marionette.remove_pin_anchor(bone_name)
		_pin_history.erase(bone_name)
		_set_status("Drag canceled (RMB) — %s pin cleared, pose unchanged"
				% String(bone_name))
	_drag_bone = null


func _remove_latest_pin() -> void:
	if _pin_history.is_empty() or _marionette == null:
		_set_status("No pins to remove")
		return
	var name: StringName = _pin_history.pop_back()
	_marionette.remove_pin_anchor(name)
	_set_status("Removed pin: %s" % String(name))


# Cursor → world. Projects screen position onto the plane perpendicular to
# the camera ray at depth `depth` (set at drag-start to the bone's pick-time
# distance from camera, modulated by Shift+wheel).
func _project_cursor_to_depth(screen_pos: Vector2, depth: float) -> Vector3:
	var origin: Vector3 = _camera.project_ray_origin(screen_pos)
	var direction: Vector3 = _camera.project_ray_normal(screen_pos)
	return origin + direction * depth


# Caps anchor distance from bone to `max_dist`. Pin force is `weight ·
# (anchor − bone)`; without this cap, a cursor sitting on the far side of a
# panel could yank a 5 kg bone with hundreds of N. Caller keeps the anchor
# direction (cursor intent) but loses the magnitude.
func _clamp_anchor(bone_world: Vector3, raw_anchor: Vector3, max_dist: float) -> Vector3:
	var d: Vector3 = raw_anchor - bone_world
	var len: float = d.length()
	if len <= max_dist or len == 0.0:
		return raw_anchor
	return bone_world + d * (max_dist / len)


# ---------- Pose capture ----------

# Press C: snapshots EVERY POWERED bone's current anatomical pose into its
# SPD target slot via `MarionetteCore::snapshot_pose_to_targets`. Does NOT
# touch `global_strength` — engaging SPD is the user's explicit call
# via the slider. (Earlier versions auto-raised strength here; that
# always triggered the SPD-mass-vs-inertia jitter and was hard to undo.)
# Designed to be pressed while still LMB-dragging if you want the
# snapshot to include the dragged-to configuration; otherwise call after
# release works just as well since `_end_drag` snapshots automatically.
func _capture_pose() -> void:
	if _marionette == null:
		return
	_marionette.snapshot_pose_to_targets()
	_set_status("Captured whole-body pose into SPD targets")


# ---------- Reset / drop / recenter ----------

func _reset_targets() -> void:
	if _marionette == null or _simulator == null:
		return
	for child: Node in _simulator.get_children():
		if not (child is MarionetteBone):
			continue
		var bone_name: StringName = _anatomical_name_for(child as MarionetteBone)
		if bone_name == StringName():
			continue
		_marionette.set_bone_target(bone_name, Vector3.ZERO)
	_marionette.clear_pin_anchors()
	_set_status("Targets reset to anatomical zero (may diverge from rest)")


# Full rig reset: stops simulation (bones snap back to skeleton rest pose
# with zero velocities), starts again, then snapshots that rest pose into
# the SPD targets so the bones hold rest instead of driving to anatomical
# zero. This is the "I dragged the character into nonsense, get me back to
# the start" button.
func _reset_rig() -> void:
	if _marionette == null or _simulator == null:
		return
	_marionette.clear_pin_anchors()
	_pin_history.clear()
	_simulator.physical_bones_stop_simulation()
	# Let one physics frame run so Jolt finishes the kinematic snap-back
	# before we restart simulation — without this the restart can pick up
	# stale velocities from the dynamic frame just before stop.
	await get_tree().physics_frame
	_marionette.start_simulation()
	_disable_sleep_on_bones()
	# Engine damping audit (2026-05-17): dropped 4.0 → 1.0. Old value
	# pre-dated SPD providing its own inertia-correct `kd` term, and
	# stacked on top of SPD now over-damps active hold + suppresses
	# natural limp-arm swing at `strength = 0`. 1.0 ≈ Godot project
	# default, leaves room for SPD's damping to do most of the work.
	_enable_engine_damping_on_bones(1.0, 1.0)
	_seed_passive_tensions()
	_marionette.set_gravity_scale(_gravity_scale)
	_marionette.set_global_strength(_global_strength)
	# Same one-frame defer as `_ready` — the simulator's kinematic→dynamic
	# transition tends to shift bones a hair from the rest pose; snapshot
	# AFTER that settles so SPD's tracking error starts at zero.
	await get_tree().physics_frame
	_marionette.snapshot_pose_to_targets()
	_set_status("Rig reset — bones at rest pose, pins cleared, velocities zeroed")


func _drop_ragdoll() -> void:
	if _marionette == null:
		return
	_marionette.clear_pin_anchors()
	var kasumi: Node3D = get_node_or_null(^"Kasumi") as Node3D
	if kasumi != null:
		var prior: Transform3D = kasumi.global_transform
		kasumi.global_position = Vector3(prior.origin.x, _DROP_HEIGHT, prior.origin.z)
	var prior_scale: float = Engine.time_scale
	Engine.time_scale = 1.0
	await get_tree().physics_frame
	Engine.time_scale = prior_scale
	_gravity_scale = _DROP_GRAVITY_SCALE
	if _gravity_label != null:
		_gravity_label.text = _gravity_label_text()
	_marionette.set_gravity_scale(_DROP_GRAVITY_SCALE)
	_marionette.start_simulation()
	_disable_sleep_on_bones()
	# Engine damping audit (2026-05-17): dropped 4.0 → 1.0. Old value
	# pre-dated SPD providing its own inertia-correct `kd` term, and
	# stacked on top of SPD now over-damps active hold + suppresses
	# natural limp-arm swing at `strength = 0`. 1.0 ≈ Godot project
	# default, leaves room for SPD's damping to do most of the work.
	_enable_engine_damping_on_bones(1.0, 1.0)
	_seed_passive_tensions()
	# Re-seed targets to current pose so SPD doesn't fight the drop.
	await get_tree().physics_frame
	_marionette.snapshot_pose_to_targets()
	_set_status("Dropped from %.1f m (gravity %.2f)" % [_DROP_HEIGHT, _DROP_GRAVITY_SCALE])


func _recenter_on_hips() -> void:
	if not is_instance_valid(_hips_bone):
		return
	_orbit_target = _hips_bone.global_position
	_set_status("Camera recentered on hips")


# ---------- Sleep ----------

# PhysicalBone3D inherits PhysicsBody3D directly (not RigidBody3D), so it
# exposes `can_sleep` but NOT a writable `sleeping` property. Disabling
# `can_sleep` at startup prevents the bone from ever entering the sleep
# state, which is the only path to silently-dropped force application; no
# wake-on-drag helper is needed since they never sleep in the first place.
func _disable_sleep_on_bones() -> void:
	if _simulator == null:
		return
	for child: Node in _simulator.get_children():
		if child is PhysicalBone3D:
			(child as PhysicalBone3D).can_sleep = false


# Seeds non-zero `passive_tension` on bones where anatomical neutral pull
# is plausible — fingers, toes, shoulders. Tendons / ligaments give those
# joints a real restoring force at rest; without this, a limp arm flops
# around at strength=0 and dragging the forearm yanks the shoulder
# violently because nothing resists chain inertia. Values are intuitive
# guesses, tune from there.
func _seed_passive_tensions() -> void:
	if _simulator == null:
		return
	const FINGER_KEYWORDS: Array[String] = [
		"Thumb", "Index", "Middle", "Ring", "Little",
	]
	const FINGER_SUFFIXES: Array[String] = [
		"Metacarpal", "Proximal", "Intermediate", "Distal",
	]
	const SHOULDER_BONES: Array[String] = [
		"LeftUpperArm", "RightUpperArm",
	]
	const FINGER_TENSION: float = 0.5
	const TOE_TENSION: float = 0.3
	const SHOULDER_TENSION: float = 0.2
	for child: Node in _simulator.get_children():
		if not (child is MarionetteBone):
			continue
		var b: MarionetteBone = child
		var n: String = String(b.name)
		if SHOULDER_BONES.has(n):
			b.passive_tension = SHOULDER_TENSION
			continue
		var is_toe: bool = n.contains("Toe") or n.contains("BigToe")
		var is_finger: bool = false
		for kw: String in FINGER_KEYWORDS:
			if n.contains(kw):
				is_finger = true
				break
		if is_toe or is_finger:
			# Both share the same phalanx-style suffix set.
			for sfx: String in FINGER_SUFFIXES:
				if n.ends_with(sfx):
					b.passive_tension = TOE_TENSION if is_toe else FINGER_TENSION
					break


func _enable_engine_damping_on_bones(linear: float, angular: float) -> void:
	if _simulator == null:
		return
	for child: Node in _simulator.get_children():
		if not (child is PhysicalBone3D):
			continue
		var b: PhysicalBone3D = child
		b.set_use_custom_integrator(false)
		b.linear_damp_mode = PhysicalBone3D.DAMP_MODE_REPLACE
		b.linear_damp = linear
		b.angular_damp_mode = PhysicalBone3D.DAMP_MODE_REPLACE
		b.angular_damp = angular


# ---------- Camera ----------

func _update_camera_transform() -> void:
	if _camera == null:
		return
	var offset := Vector3(0.0, 0.0, _orbit_distance)
	offset = offset.rotated(Vector3.RIGHT, -_orbit_pitch)
	offset = offset.rotated(Vector3.UP, _orbit_yaw)
	_camera.global_position = _orbit_target + offset
	_camera.look_at(_orbit_target, Vector3.UP)


# ---------- Anchor visualization ----------

func _build_anchor_viz() -> void:
	_anchor_marker = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.025
	sphere.height = 0.05
	sphere.radial_segments = 12
	sphere.rings = 6
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _ANCHOR_COLOR
	mat.emission_enabled = true
	mat.emission = _ANCHOR_COLOR * 0.6
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	sphere.material = mat
	_anchor_marker.mesh = sphere
	_anchor_marker.visible = false
	add_child(_anchor_marker)

	_anchor_line_mesh = ImmediateMesh.new()
	_anchor_line_material = StandardMaterial3D.new()
	_anchor_line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_anchor_line_material.vertex_color_use_as_albedo = true
	_anchor_line_material.no_depth_test = true
	_anchor_line = MeshInstance3D.new()
	_anchor_line.mesh = _anchor_line_mesh
	_anchor_line.material_override = _anchor_line_material
	_anchor_line.visible = false
	add_child(_anchor_line)


func _update_anchor_viz() -> void:
	if _drag_active and is_instance_valid(_drag_bone):
		_anchor_marker.global_position = _drag_anchor_world
		_anchor_marker.visible = true
		_anchor_line.visible = true
		_anchor_line_mesh.clear_surfaces()
		_anchor_line_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
		_anchor_line_mesh.surface_set_color(_ANCHOR_COLOR)
		_anchor_line_mesh.surface_add_vertex(_drag_bone.global_position)
		_anchor_line_mesh.surface_set_color(_ANCHOR_COLOR)
		_anchor_line_mesh.surface_add_vertex(_drag_anchor_world)
		_anchor_line_mesh.surface_end()
	else:
		_anchor_marker.visible = false
		_anchor_line.visible = false
		_anchor_line_mesh.clear_surfaces()


# ---------- Hover label ----------

func _update_hover_label() -> void:
	if _hover_label == null:
		return
	if _drag_active:
		_hover_label.visible = false
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


func _anatomical_name_for(bone: MarionetteBone) -> StringName:
	if bone == null:
		return StringName()
	var n: StringName = bone.get_anatomical_name()
	if n == StringName():
		n = StringName(bone.name)
	return n


func _set_status(s: String) -> void:
	if _status_label != null:
		_status_label.text = s


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
	margin.custom_minimum_size = Vector2(360.0, 0.0)
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
	_build_actions_panel(vbox)
	_build_strength_panel(vbox)
	_build_gravity_panel(vbox)
	_build_pin_panel(vbox)
	_build_joint_pads_panel(vbox)
	_build_strain_panel(vbox)
	_build_status_panel(vbox)


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
		"LMB drag       drag bone (anchor at pick depth)\n"
		+ "RMB during LMB cancel drag (no pin persisted, no capture)\n"
		+ "Shift+wheel    adjust drag depth\n"
		+ "RMB drag       orbit camera (when not LMB-dragging)\n"
		+ "MMB drag       pan camera\n"
		+ "Wheel          zoom\n"
		+ "C              capture pose into SPD targets\n"
		+ "Z              remove latest pin\n"
		+ "X              clear all pins\n"
		+ "R              reset SPD targets to anatomical zero\n"
		+ "Shift+R        full rig reset (snap to rest pose)\n"
		+ "F / Home       recenter on hips\n"
		+ "Space          pause / resume"
	)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_child(hint)

	var flow := Label.new()
	flow.text = (
		"Workflow:\n"
		+ "  1. Drag bones (LMB) — each release leaves a persistent pin\n"
		+ "  2. Z removes the latest pin, X clears all\n"
		+ "  3. Joint pads (below) drive flex/abd targets directly —\n"
		+ "     raise Global strength to engage SPD and see the targets"
	)
	flow.add_theme_color_override(&"font_color", Color(0.75, 0.85, 0.95))
	flow.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_child(flow)


func _build_actions_panel(parent: Container) -> void:
	var inner: VBoxContainer = _make_panel(parent, "Actions")
	var capture_btn := Button.new()
	capture_btn.text = "Capture pose  (C)"
	capture_btn.pressed.connect(_capture_pose)
	inner.add_child(capture_btn)

	var reset_btn := Button.new()
	reset_btn.text = "Reset targets  (R)"
	reset_btn.pressed.connect(_reset_targets)
	inner.add_child(reset_btn)

	var reset_rig_btn := Button.new()
	reset_rig_btn.text = "Reset rig — snap to rest pose  (Shift+R)"
	reset_rig_btn.pressed.connect(_reset_rig)
	inner.add_child(reset_rig_btn)

	var recenter_btn := Button.new()
	recenter_btn.text = "Recenter camera on hips  (F)"
	recenter_btn.pressed.connect(_recenter_on_hips)
	inner.add_child(recenter_btn)

	var drop_btn := Button.new()
	drop_btn.text = "Drop ragdoll (%.1f m, gravity %.2f)" % [_DROP_HEIGHT, _DROP_GRAVITY_SCALE]
	drop_btn.pressed.connect(_drop_ragdoll)
	inner.add_child(drop_btn)

	_pause_button = Button.new()
	_pause_button.text = "Pause  (Space)"
	_pause_button.toggle_mode = true
	_pause_button.toggled.connect(_toggle_pause)
	inner.add_child(_pause_button)


func _toggle_pause(pressed: bool) -> void:
	_paused = pressed
	Engine.time_scale = 0.0 if pressed else 1.0
	if _pause_button != null:
		_pause_button.text = "Resume  (Space)" if pressed else "Pause  (Space)"


func _build_strength_panel(parent: Container) -> void:
	var inner: VBoxContainer = _make_panel(parent, "Global strength")
	_global_strength_label = Label.new()
	_global_strength_label.text = _strength_label_text()
	inner.add_child(_global_strength_label)
	var hint := Label.new()
	hint.text = ("0 = limp (pin + engine damping hold pose)\n"
			+ "1 = SPD actively holds captured pose / joint-pad targets")
	hint.add_theme_color_override(&"font_color", Color(0.7, 0.7, 0.7))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	inner.add_child(hint)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 2.0
	slider.step = 0.01
	slider.value = _global_strength
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(_on_global_strength_changed)
	inner.add_child(slider)


func _strength_label_text() -> String:
	if _global_strength <= 0.0:
		return "Strength: 0.00  (limp)"
	return "Strength: %.2f" % _global_strength


func _on_global_strength_changed(v: float) -> void:
	_global_strength = v
	_global_strength_label.text = _strength_label_text()
	if _marionette != null:
		_marionette.set_global_strength(v)


func _build_gravity_panel(parent: Container) -> void:
	var inner: VBoxContainer = _make_panel(parent, "Gravity")
	_gravity_label = Label.new()
	_gravity_label.text = _gravity_label_text()
	inner.add_child(_gravity_label)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.5
	slider.step = 0.01
	slider.value = _gravity_scale
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(_on_gravity_changed)
	inner.add_child(slider)


func _gravity_label_text() -> String:
	if _gravity_scale <= 0.0:
		return "Gravity scale: 0.00  (zero-g)"
	return "Gravity scale: %.2f" % _gravity_scale


func _on_gravity_changed(v: float) -> void:
	_gravity_scale = v
	_gravity_label.text = _gravity_label_text()
	if _marionette != null:
		_marionette.set_gravity_scale(v)


func _build_pin_panel(parent: Container) -> void:
	var inner: VBoxContainer = _make_panel(parent, "Pin weight")
	_pin_weight_label = Label.new()
	_pin_weight_label.text = "Pin weight: %.0f" % _pin_weight
	inner.add_child(_pin_weight_label)
	var slider := HSlider.new()
	slider.min_value = 1.0
	slider.max_value = 500.0
	slider.step = 1.0
	slider.value = _pin_weight
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(_on_pin_weight_changed)
	inner.add_child(slider)

	var remove_last_btn := Button.new()
	remove_last_btn.text = "Remove latest pin  (Z)"
	remove_last_btn.pressed.connect(_remove_latest_pin)
	inner.add_child(remove_last_btn)

	var clear_btn := Button.new()
	clear_btn.text = "Clear all pins  (X)"
	clear_btn.pressed.connect(_on_clear_pins_pressed)
	inner.add_child(clear_btn)

	_pin_count_label = Label.new()
	_pin_count_label.text = "Active pins: 0"
	inner.add_child(_pin_count_label)


func _on_pin_weight_changed(v: float) -> void:
	_pin_weight = v
	_pin_weight_label.text = "Pin weight: %.0f" % v


func _on_clear_pins_pressed() -> void:
	if _marionette != null:
		_marionette.clear_pin_anchors()
	_pin_history.clear()


func _build_joint_pads_panel(parent: Container) -> void:
	var inner: VBoxContainer = _make_panel(parent, "Joint targets (XY = flex / abd)")
	var hint := Label.new()
	hint.text = ("LMB drag inside pad = set target · RMB on pad = zero\n"
			+ "Visible effect needs Global strength > 0.")
	hint.add_theme_color_override(&"font_color", Color(0.7, 0.7, 0.7))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	inner.add_child(hint)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override(&"h_separation", 8)
	grid.add_theme_constant_override(&"v_separation", 6)
	inner.add_child(grid)

	# One cell per requested bone, in declared order. Missing bones (no
	# entry in the simulator) leave an empty cell so left/right pairs
	# stay aligned.
	var bones_by_name: Dictionary[StringName, MarionetteBone] = _index_bones_by_name()
	for bone_name: StringName in _PAD_BONES:
		var cell := VBoxContainer.new()
		cell.add_theme_constant_override(&"separation", 2)
		var label := Label.new()
		label.text = String(bone_name)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.add_theme_color_override(&"font_color", Color(0.85, 0.85, 0.9))
		cell.add_child(label)
		if bones_by_name.has(bone_name):
			var pad := JointPad.new()
			pad.bone_name = bone_name
			pad.marionette = _marionette
			pad.bone_ref = bones_by_name[bone_name]
			pad.range_rad = _PAD_RANGE_RAD
			pad.custom_minimum_size = _PAD_SIZE
			pad.drag_started.connect(_on_pad_drag_started.bind(bone_name))
			pad.drag_ended.connect(_on_pad_drag_ended.bind(bone_name))
			cell.add_child(pad)
		else:
			var missing := Label.new()
			missing.text = "(not in rig)"
			missing.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			missing.add_theme_color_override(&"font_color", Color(0.5, 0.5, 0.5))
			missing.custom_minimum_size = _PAD_SIZE
			cell.add_child(missing)
		grid.add_child(cell)


func _on_pad_drag_started(bone_name: StringName) -> void:
	# Re-entrant guard — only one pad can be the "isolate origin" at a time.
	# A second pad starting mid-drag would clobber the saved-strength
	# snapshot and the original drag would never restore properly.
	if _pad_drag_active or _marionette == null:
		return
	_pad_drag_active = true
	_pad_drag_saved_strength = _global_strength
	_marionette.snapshot_pose_to_targets()
	_marionette.set_global_strength(_PAD_DRAG_ISOLATE_STRENGTH)
	_set_status("Isolating %s — other joints locked at snapshot pose"
			% String(bone_name))


func _on_pad_drag_ended(bone_name: StringName) -> void:
	if not _pad_drag_active or _marionette == null:
		return
	_pad_drag_active = false
	_marionette.set_global_strength(_pad_drag_saved_strength)
	# Don't touch the slider widget — the saved value matches the user's
	# pre-drag strength which is what the slider already shows.
	_set_status("Released %s — strength restored to %.2f"
			% [String(bone_name), _pad_drag_saved_strength])


func _index_bones_by_name() -> Dictionary[StringName, MarionetteBone]:
	var out: Dictionary[StringName, MarionetteBone] = {}
	if _simulator == null:
		return out
	for child: Node in _simulator.get_children():
		if not (child is MarionetteBone):
			continue
		var b: MarionetteBone = child
		var key: StringName = b.get_anatomical_name()
		if key == StringName():
			key = StringName(b.name)
		out[key] = b
	return out


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


func _build_status_panel(parent: Container) -> void:
	var inner: VBoxContainer = _make_panel(parent, "Status")
	_status_label = Label.new()
	_status_label.text = "Ready"
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	inner.add_child(_status_label)
