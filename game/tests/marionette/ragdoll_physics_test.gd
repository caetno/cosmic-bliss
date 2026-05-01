extends Node3D

# P5 Slice A — pure-ragdoll physics test scene (no SPD yet).
#
# What it tests: the 6DOF angular limits baked into each MarionetteBone at
# ragdoll build time. With physics enabled and no muscle torque, gravity +
# spring tethers + user impulses are the only inputs — so any pose the
# character settles into is the joint limits doing their job. If a knee
# bends backwards or an elbow hyperextends here, the limit is wrong (or
# the anatomical frame is).
#
# Spring tethers: configurable per region (Hips / Spine / Head / Hands / Feet).
# Each active region's bones are pulled toward their world position at
# tether-capture time by mass-scaled critically-damped springs in
# `_physics_process`. With reduced gravity (`_GRAVITY_SCALE`) this holds
# the character in a recognizable pose so individual joints can be
# exercised one at a time without the whole rig collapsing first.
# Toggling a region ON re-captures fresh anchors at the current bone
# positions — so you can pose the character by dragging, then re-tether
# to lock the new shape.
#
# The Spine region (Spine + Chest + UpperChest) exists because pure-ragdoll
# spines have no muscle stiffness — the back will fold in half on every
# drop, drowning out per-joint observations. Tethering the spine column
# lets you read other joints. Real fix is SPD (Phase 5.1+); the spine
# tether is a stopgap for pre-SPD test scenarios.
#
# Drop test: spawns the character at 5 m with a random orientation and
# untethered, then runs gravity. Useful for stress-testing joint limits
# under varied initial conditions — landing on the head, on one shoulder,
# spinning, etc. Floor-Slam preset is a manual subset (no random pose).
#
# Pose presets: a dropdown configures (active regions × gravity) in one
# step. Standing = full tether at low gravity; Hang = Hips-only at full
# gravity (character dangles); Floor-Slam = no tether, full gravity;
# Zero-G = no tether, no gravity (free-floating, drift only on push).
#
# Pause: implemented via `Engine.time_scale = 0`, so _process still runs
# (camera + UI keep working) and any per-tick force we apply multiplies to
# zero impulse. Step temporarily restores the chosen time scale, awaits one
# physics frame, then re-zeros.
#
# Force / impulse path: PhysicalBone3D extends PhysicsBody3D, which doesn't
# expose `apply_central_force` (that's a RigidBody3D method). Continuous
# forces are applied by integrating to per-tick impulses: `force * delta`
# fed into `apply_central_impulse`. Same body of physics, different API.
#
# Marionette.start_simulation() takes care of two pieces of unserializable
# state on every call: it regenerates capsule colliders for any
# MarionetteBone that's missing one, and re-applies pair-wise collision
# exclusions from the active CollisionExclusionProfile. So this scene
# doesn't need to do either explicitly — it just calls start_simulation
# and trusts the runtime self-heal.
#
# Input scheme:
#   Right mouse drag → orbit camera around the Hips bone.
#   Mouse wheel      → zoom in/out (clamped).
#   Left mouse drag  → grab a MarionetteBone at the click point and pull
#                      it toward the cursor (spring at the grab point —
#                      off-center grabs rotate the bone naturally). Depth
#                      is locked at click time, so the cursor sweeps a
#                      sphere around the camera.
#   F                → throw a projectile (sphere) from camera.
#   Space            → pause / resume.
#   . (period)       → step one physics frame (only while paused).
#   R                → reset everything (also via UI button).

const _ORBIT_DIST_MIN: float = 0.6
const _ORBIT_DIST_MAX: float = 12.0
const _ORBIT_DIST_DEFAULT: float = 3.0
const _ORBIT_PITCH_DEFAULT: float = 0.25
const _ORBIT_PITCH_LIMIT: float = 1.48  # ~85°
const _ORBIT_SENSITIVITY: float = 0.005  # rad per pixel
const _ZOOM_FACTOR: float = 1.15
const _PICK_RAY_LENGTH: float = 200.0
const _FALLBACK_TARGET: Vector3 = Vector3(0.0, 1.0, 0.0)

# Tether constants. Spring k = mass·ω², c = 2·ζ·mass·ω (critically damped).
const _TETHER_OMEGA: float = 8.0
const _TETHER_DAMPING_RATIO: float = 1.0

# Drag-manipulator spring (LMB held). Higher ω than tethers so the bone
# tracks the cursor responsively; same critical-damping convention.
const _DRAG_OMEGA: float = 14.0
const _DRAG_DAMPING_RATIO: float = 1.0

# Drop-test parameters. Character lifts to 5 m with a uniform-random
# orientation; gravity is forced to 1.0 so the fall reads naturally.
const _DROP_HEIGHT: float = 5.0
const _DROP_GRAVITY_SCALE: float = 1.0

# Default angular/linear damp applied to every dynamic MarionetteBone at
# scene start. Higher values bleed off motion energy faster (less rubbery
# wobble); lower values give more lively response. Damp mode is forced to
# REPLACE so the slider value is authoritative — without that, the project
# default (or Area3D damp) compounds on top.
const _DEFAULT_BONE_DAMP: float = 0.5

# Slider groups for live-tuning angular+linear damp on whole regions.
# Each group lights up a slider in the right-hand tuning panel; moving
# the slider rewrites damp on every bone whose MarionetteBoneRegion lands
# in the group's region set. The pure-ragdoll spine has no muscle stiffness
# so motion at the dist phalanges/lower limbs feels rubbery; this is the
# scrub knob for that.
const _DAMP_GROUP_ORDER: Array[StringName] = [
	&"fingers", &"toes", &"arms", &"legs", &"spine", &"head_neck"
]
const _DAMP_GROUP_LABELS: Dictionary[StringName, String] = {
	&"fingers": "Fingers", &"toes": "Toes", &"arms": "Arms",
	&"legs": "Legs", &"spine": "Spine", &"head_neck": "Head/Neck",
}
# Region IDs are int (MarionetteBoneRegion.Region enum). Built in _ready
# because the enum constants aren't const-foldable.
var _damp_group_regions: Dictionary[StringName, Array] = {}

# Region → bone names. Each region is a button in the UI; bones in active
# regions get spring-tethered to their world position at capture time.
# The Spine region is a stopgap for pre-SPD scenes where the spinal
# column has no muscle stiffness — without it the back folds completely
# on any drop.
const _REGION_BONES: Dictionary[StringName, Array] = {
	&"hips": [&"Hips"],
	&"spine": [&"Spine", &"Chest", &"UpperChest"],
	&"head": [&"Head"],
	&"hands": [&"LeftHand", &"RightHand"],
	&"feet": [&"LeftFoot", &"RightFoot"],
}
const _REGION_ORDER: Array[StringName] = [&"hips", &"spine", &"head", &"hands", &"feet"]
const _REGION_LABELS: Dictionary[StringName, String] = {
	&"hips": "Hips", &"spine": "Spine", &"head": "Head", &"hands": "Hands", &"feet": "Feet"
}

# Pose presets. Each: which regions are tethered + gravity scale.
const _PRESETS: Array[Dictionary] = [
	{"name": "Standing",   "regions": [&"hips", &"spine", &"head", &"hands", &"feet"], "gravity": 0.2},
	{"name": "Hang",       "regions": [&"hips"],                                        "gravity": 1.0},
	{"name": "Floor-Slam", "regions": [],                                               "gravity": 1.0},
	{"name": "Zero-G",     "regions": [],                                               "gravity": 0.0},
]
const _DEFAULT_PRESET_INDEX: int = 0

# Time-scale presets shown as a row of buttons. Labels are hand-written
# because GDScript's printf doesn't support %g — `"%g" % 0.25` errors out.
const _SPEEDS: Array[float] = [0.25, 0.5, 1.0, 2.0]
const _SPEED_LABELS: Array[String] = ["0.25×", "0.5×", "1×", "2×"]
const _DEFAULT_SPEED_INDEX: int = 2  # 1.0×

# Projectile: thrown sphere on F key.
const _PROJECTILE_SPEED: float = 12.0
const _PROJECTILE_RADIUS: float = 0.08
const _PROJECTILE_MASS: float = 0.5
const _PROJECTILE_LIFETIME: float = 8.0  # seconds before auto-cleanup
const _PROJECTILE_PARENT_NAME: StringName = &"_Projectiles"

@export_node_path("Marionette") var marionette_path: NodePath = ^"Kasumi/Marionette"
@export_node_path("Camera3D") var camera_path: NodePath = ^"Camera3D"

var _marionette: Marionette
var _camera: Camera3D
var _hips_bone: MarionetteBone
var _simulator: PhysicalBoneSimulator3D

var _orbit_yaw: float = 0.0
var _orbit_pitch: float = _ORBIT_PITCH_DEFAULT
var _orbit_distance: float = _ORBIT_DIST_DEFAULT
var _orbiting: bool = false

# Click-drag manipulator state. Empty when nothing is grabbed; otherwise:
#   bone:           MarionetteBone being dragged
#   local_offset:   grab point in the bone's local frame (for converting to
#                   world each frame as the bone moves/rotates)
#   ray_t:          parameter along the camera ray at click time, used to
#                   keep the cursor target at the original screen-depth
#   k, c:           spring stiffness / damping, mass-scaled
var _drag: Dictionary = {}

# Active spring tethers — list of dicts {bone, region, anchor, k, c}.
var _tethers: Array[Dictionary] = []

# Per-region tether ω multiplier — slider value [0..3]. 1.0 = use the
# constant _TETHER_OMEGA unchanged. _refresh_tethers reads this when
# computing k/c for each tether; _on_tether_omega_changed updates k/c on
# in-flight tethers in-place so the slider feels immediate (no anchor reset).
var _tether_omega_mul: Dictionary[StringName, float] = {}

# Drag-spring ω multiplier. Same convention as tether multipliers.
var _drag_omega_mul: float = 1.0

# Capsule-radius global multiplier — slider value tracks current scale,
# applied as a delta on each change so consecutive moves multiply
# correctly (in-place mutate; no rebuild). Capsule height is bumped along
# with radius so the shape stays valid (height >= 2·radius + epsilon).
var _capsule_radius_mul: float = 1.0

# Whether bone-bone (and bone-world) collisions are active. Defaults OFF
# so the ragdoll falls through itself and the floor without contact
# pushing it apart — useful baseline for joint-limit-only debugging. The
# Geometry-section checkbox flips it; _apply_bone_collisions_state walks
# every CollisionShape3D and sets `disabled` accordingly. Re-applied after
# Reset / Drop Test so the state survives sim restarts.
var _bone_collisions_enabled: bool = false

# Runtime capsule visualization. CollisionShape3D.visible is editor-only
# (it draws no mesh at runtime), so the toggle below spawns transparent
# MeshInstance3D children with each shape's geometry. Tracked by a
# special node name so they're easy to clear; regenerated when the radius
# slider changes since the meshes don't follow the shape.
const _DEBUG_MESH_NAME: StringName = &"_DebugMesh"
var _show_capsules: bool = false

# Per-group damping value (mirrors slider state). _apply_group_damp writes
# to bones; this dict just keeps the current target so a re-mount or sync
# doesn't lose the value.
var _group_damp: Dictionary[StringName, float] = {}

# Which regions are currently tethered. Driven by the per-region checkboxes
# and by preset selection. Tether refresh reads this dict.
var _active_regions: Dictionary[StringName, bool] = {}

# Current gravity scale (set by preset, applied to every dynamic bone).
var _gravity_scale: float = 0.2

# Pause / step / time-scale state.
var _paused: bool = false
var _selected_speed: float = 1.0

# Container Node3D for spawned projectiles, so reset can clear them in one shot.
var _projectile_root: Node3D

# UI handles we need to mutate after construction.
var _pause_button: Button
var _step_button: Button
var _tether_button: Button
var _floor_button: Button
var _region_checks: Dictionary[StringName, CheckBox] = {}
var _speed_buttons: Array[Button] = []
var _preset_dropdown: OptionButton
var _hovered_label: Label


func _ready() -> void:
	_marionette = get_node_or_null(marionette_path) as Marionette
	_camera = get_node_or_null(camera_path) as Camera3D
	if _marionette == null:
		push_error("ragdoll_physics_test: marionette_path %s did not resolve" % marionette_path)
		return
	if _camera == null:
		push_error("ragdoll_physics_test: camera_path %s did not resolve" % camera_path)
		return
	_simulator = _find_simulator()
	if _simulator == null:
		push_error("ragdoll_physics_test: no PhysicalBoneSimulator3D under skeleton — build the ragdoll in the editor first")
		return
	_hips_bone = _find_bone_by_name(&"Hips")

	_projectile_root = Node3D.new()
	_projectile_root.name = String(_PROJECTILE_PARENT_NAME)
	add_child(_projectile_root)

	_init_damp_groups()
	_init_tether_multipliers()
	_marionette.start_simulation()
	_initialize_bone_damping()
	_apply_bone_collisions_state()
	_apply_preset_by_index(_DEFAULT_PRESET_INDEX, false)
	_set_speed(_SPEEDS[_DEFAULT_SPEED_INDEX])
	_build_ui()
	_sync_ui_state()
	_update_camera_transform()


func _init_damp_groups() -> void:
	# Region IDs come from the MarionetteBoneRegion enum; build the dict
	# once now that the class is loaded.
	_damp_group_regions = {
		&"fingers":   [MarionetteBoneRegion.Region.LEFT_HAND, MarionetteBoneRegion.Region.RIGHT_HAND],
		&"toes":      [MarionetteBoneRegion.Region.LEFT_FOOT, MarionetteBoneRegion.Region.RIGHT_FOOT],
		&"arms":      [MarionetteBoneRegion.Region.LEFT_ARM, MarionetteBoneRegion.Region.RIGHT_ARM],
		&"legs":      [MarionetteBoneRegion.Region.LEFT_LEG, MarionetteBoneRegion.Region.RIGHT_LEG],
		&"spine":     [MarionetteBoneRegion.Region.SPINE],
		&"head_neck": [MarionetteBoneRegion.Region.HEAD_NECK],
	}
	for group: StringName in _DAMP_GROUP_ORDER:
		_group_damp[group] = _DEFAULT_BONE_DAMP


func _init_tether_multipliers() -> void:
	for region: StringName in _REGION_ORDER:
		_tether_omega_mul[region] = 1.0


# Sets damp_mode = REPLACE on every dynamic MarionetteBone and writes the
# default damp values per group, so the project default doesn't compound.
# Runs once at _ready and after every reset.
func _initialize_bone_damping() -> void:
	if _simulator == null:
		return
	for child: Node in _simulator.get_children():
		if not (child is MarionetteBone):
			continue
		var b: MarionetteBone = child
		# PhysicalBone3D has its own DampMode enum (separate from
		# RigidBody3D's, even though the underlying integer is the same).
		# Typed GDScript rejects cross-class assignments, so we use this
		# class's enum specifically.
		b.linear_damp_mode = PhysicalBone3D.DAMP_MODE_REPLACE
		b.angular_damp_mode = PhysicalBone3D.DAMP_MODE_REPLACE
		b.linear_damp = _DEFAULT_BONE_DAMP
		b.angular_damp = _DEFAULT_BONE_DAMP
	# Re-apply current group values (slider may have moved off the default).
	for group: StringName in _DAMP_GROUP_ORDER:
		_apply_group_damp(group, _group_damp.get(group, _DEFAULT_BONE_DAMP))


# Sets `disabled` on every bone CollisionShape3D from `_bone_collisions_enabled`.
# Idempotent. Called from _ready, _reset, _drop_test, and the toggle.
func _apply_bone_collisions_state() -> void:
	if _simulator == null:
		return
	for child: Node in _simulator.get_children():
		if not (child is MarionetteBone):
			continue
		for c: Node in (child as MarionetteBone).get_children():
			if c is CollisionShape3D:
				(c as CollisionShape3D).disabled = not _bone_collisions_enabled


func _on_bone_collisions_toggled(on: bool) -> void:
	_bone_collisions_enabled = on
	_apply_bone_collisions_state()


# Removes any existing debug meshes, then (if `_show_capsules`) spawns a
# transparent CapsuleMesh under each CollisionShape3D so you can see the
# colliders during play. CollisionShape3D.visible only draws the editor
# wireframe, not in-game — hence this duplicate-geometry approach.
func _refresh_debug_meshes() -> void:
	if _simulator == null:
		return
	for child: Node in _simulator.get_children():
		if not (child is MarionetteBone):
			continue
		for c: Node in (child as MarionetteBone).get_children():
			if not (c is CollisionShape3D):
				continue
			var existing: Node = (c as CollisionShape3D).get_node_or_null(NodePath(String(_DEBUG_MESH_NAME)))
			if existing != null:
				existing.queue_free()
	if not _show_capsules:
		return
	# Shared transparent material — CULL_DISABLED so we see both sides on
	# overlap, low alpha so the skin mesh is still readable underneath.
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(0.2, 0.95, 0.95, 0.35)
	for child: Node in _simulator.get_children():
		if not (child is MarionetteBone):
			continue
		for c: Node in (child as MarionetteBone).get_children():
			if not (c is CollisionShape3D):
				continue
			var cs: CollisionShape3D = c
			if cs.shape == null:
				continue
			var mi := MeshInstance3D.new()
			mi.name = String(_DEBUG_MESH_NAME)
			# CapsuleMesh keeps wireframe-readable shading; for non-capsule
			# shapes (sphere, box) fall back to the shape's debug mesh.
			if cs.shape is CapsuleShape3D:
				var caps_shape: CapsuleShape3D = cs.shape
				var caps_mesh := CapsuleMesh.new()
				caps_mesh.radius = caps_shape.radius
				caps_mesh.height = caps_shape.height
				mi.mesh = caps_mesh
			else:
				mi.mesh = cs.shape.get_debug_mesh()
			mi.material_override = mat
			cs.add_child(mi)


func _on_show_capsules_toggled(on: bool) -> void:
	_show_capsules = on
	_refresh_debug_meshes()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		match mb.button_index:
			MOUSE_BUTTON_RIGHT:
				_orbiting = mb.pressed
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_begin_drag(mb.position)
				else:
					_end_drag()
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					_orbit_distance = clampf(_orbit_distance / _ZOOM_FACTOR,
							_ORBIT_DIST_MIN, _ORBIT_DIST_MAX)
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_orbit_distance = clampf(_orbit_distance * _ZOOM_FACTOR,
							_ORBIT_DIST_MIN, _ORBIT_DIST_MAX)
	elif event is InputEventMouseMotion and _orbiting:
		var mm: InputEventMouseMotion = event
		_orbit_yaw -= mm.relative.x * _ORBIT_SENSITIVITY
		_orbit_pitch = clampf(_orbit_pitch - mm.relative.y * _ORBIT_SENSITIVITY,
				-_ORBIT_PITCH_LIMIT, _ORBIT_PITCH_LIMIT)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_R:
				_reset()
			KEY_SPACE:
				_toggle_pause()
			KEY_PERIOD:
				_step_one_frame()
			KEY_F:
				_throw_projectile()


func _physics_process(delta: float) -> void:
	# Spring tethers — mass-scaled critically-damped pull toward the anchor.
	# Computed and applied as per-tick impulses (force * delta) since
	# PhysicalBone3D doesn't expose apply_central_force. With Engine.time_scale=0,
	# delta is 0 and these calls become no-op — pause is implicit.
	for t: Dictionary in _tethers:
		var bone: MarionetteBone = t["bone"]
		if not is_instance_valid(bone):
			continue
		var displacement: Vector3 = (t["anchor"] as Vector3) - bone.global_position
		var force: Vector3 = displacement * float(t["k"]) - bone.linear_velocity * float(t["c"])
		bone.apply_central_impulse(force * delta)
	_apply_drag_force(delta)


# Click-drag manipulator: spring at the grab point pulled toward the
# cursor's projected world position. Force is applied via apply_impulse
# at the world-space offset from CoM, so off-center grabs produce torque
# (dragging a fingertip rotates the hand). Velocity at the grab point
# accounts for both linear and angular components, so damping correctly
# resists motion at the grabbed location, not just the bone center.
func _apply_drag_force(delta: float) -> void:
	if _drag.is_empty() or _camera == null:
		return
	var bone: MarionetteBone = _drag["bone"]
	if not is_instance_valid(bone):
		_drag.clear()
		return
	var local_offset: Vector3 = _drag["local_offset"]
	var ray_t: float = _drag["ray_t"]
	var k: float = _drag["k"]
	var c: float = _drag["c"]

	var screen_pos: Vector2 = get_viewport().get_mouse_position()
	var origin: Vector3 = _camera.project_ray_origin(screen_pos)
	var direction: Vector3 = _camera.project_ray_normal(screen_pos)
	var target_world: Vector3 = origin + direction * ray_t

	var grab_world: Vector3 = bone.to_global(local_offset)
	var offset_from_com: Vector3 = grab_world - bone.global_position
	var grab_velocity: Vector3 = bone.linear_velocity + bone.angular_velocity.cross(offset_from_com)
	var displacement: Vector3 = target_world - grab_world
	var force: Vector3 = displacement * k - grab_velocity * c
	bone.apply_impulse(force * delta, offset_from_com)


func _process(_delta: float) -> void:
	_update_camera_transform()
	_update_hovered_hud()


# ---------- Camera ----------

func _update_camera_transform() -> void:
	if _camera == null:
		return
	var target: Vector3 = _hips_bone.global_position if is_instance_valid(_hips_bone) \
			else _FALLBACK_TARGET
	# Negative pitch in the rotation so positive _orbit_pitch lifts the camera.
	var offset := Vector3(0.0, 0.0, _orbit_distance)
	offset = offset.rotated(Vector3.RIGHT, -_orbit_pitch)
	offset = offset.rotated(Vector3.UP, _orbit_yaw)
	_camera.global_position = target + offset
	_camera.look_at(target, Vector3.UP)


# ---------- Click-drag manipulator ----------

# Picks the bone under cursor, captures the exact hit point as a bone-local
# offset (so as the bone rotates, the spring still pulls the same physical
# spot), and stores the camera-ray distance to that point so the cursor
# target stays at the same screen-depth as the user drags.
func _begin_drag(screen_pos: Vector2) -> void:
	if _camera == null:
		return
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
	var local_offset: Vector3 = bone.to_local(hit_world)
	var mass: float = bone.mass
	var omega: float = _DRAG_OMEGA * _drag_omega_mul
	_drag = {
		"bone": bone,
		"local_offset": local_offset,
		"ray_t": ray_t,
		"k": mass * omega * omega,
		"c": 2.0 * _DRAG_DAMPING_RATIO * mass * omega,
	}


func _end_drag() -> void:
	_drag.clear()


# Ray-cast against physics bodies; returns the full intersect_ray dict.
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


func _pick_bone_at(screen_pos: Vector2) -> MarionetteBone:
	var hit: Dictionary = _raycast(screen_pos)
	if hit.is_empty():
		return null
	var collider: Object = hit.get("collider")
	if collider is MarionetteBone:
		return collider
	return null


# ---------- Reset ----------

func _reset() -> void:
	_end_drag()
	_clear_projectiles()
	if _marionette == null or _simulator == null:
		return
	# Snap the character back to the scene origin in case a Drop Test left
	# Kasumi at (0, 5, 0) or some random orientation. Reset is "go back to
	# the starting state" — that includes the rig's spawn transform.
	var kasumi: Node3D = get_node_or_null(^"Kasumi") as Node3D
	if kasumi != null:
		kasumi.transform = Transform3D.IDENTITY
	_marionette.stop_simulation()
	var skel: Skeleton3D = _marionette.resolve_skeleton()
	if skel != null:
		skel.reset_bone_poses()
	# One physics frame for the kinematic-follow to settle the bones onto the
	# rest pose before we restart simulation. Without it the bones would
	# resume physics from their last collapsed position.
	#
	# Reset honors the pause state by restoring time_scale temporarily so the
	# physics frame actually advances; otherwise Engine.time_scale=0 would
	# block the rest-pose snap from taking effect.
	var prior_scale: float = Engine.time_scale
	Engine.time_scale = 1.0
	await get_tree().physics_frame
	Engine.time_scale = prior_scale
	_marionette.start_simulation()
	_initialize_bone_damping()
	_apply_bone_collisions_state()
	_apply_preset_by_index(_DEFAULT_PRESET_INDEX)


# Lifts the character to `_DROP_HEIGHT` with a uniformly-random orientation,
# kills all tethers, and forces gravity to 1.0. Stress-tests the joint
# limits across a wide variety of landing configurations — the same drop
# from a different orientation produces a completely different collapse,
# so each press exercises a new chain of limits.
func _drop_test() -> void:
	_end_drag()
	_clear_projectiles()
	if _marionette == null or _simulator == null:
		return
	_marionette.stop_simulation()
	var skel: Skeleton3D = _marionette.resolve_skeleton()
	if skel != null:
		skel.reset_bone_poses()
	var kasumi: Node3D = get_node_or_null(^"Kasumi") as Node3D
	if kasumi != null:
		var rng_basis := Basis.from_euler(Vector3(
				randf_range(-PI, PI), randf_range(-PI, PI), randf_range(-PI, PI)))
		kasumi.global_transform = Transform3D(rng_basis, Vector3(0.0, _DROP_HEIGHT, 0.0))
	# Disable every tether so the fall is free.
	for region: StringName in _REGION_ORDER:
		_active_regions[region] = false
	_gravity_scale = _DROP_GRAVITY_SCALE
	# Same time-scale trick as _reset so the physics frame actually runs.
	var prior_scale: float = Engine.time_scale
	Engine.time_scale = 1.0
	await get_tree().physics_frame
	Engine.time_scale = prior_scale
	_marionette.start_simulation()
	_initialize_bone_damping()
	_apply_bone_collisions_state()
	_apply_gravity_scale()
	_refresh_tethers()
	_sync_ui_state()


# ---------- Tethers ----------

# Per-bone gravity_scale applied to every dynamic MarionetteBone.
func _apply_gravity_scale() -> void:
	if _simulator == null:
		return
	for child: Node in _simulator.get_children():
		if child is MarionetteBone:
			(child as MarionetteBone).gravity_scale = _gravity_scale


# Rebuilds `_tethers` from `_active_regions`, capturing fresh anchors at
# each tethered bone's current world position. Idempotent.
func _refresh_tethers() -> void:
	_tethers.clear()
	for region: StringName in _REGION_ORDER:
		if not _active_regions.get(region, false):
			continue
		var omega: float = _TETHER_OMEGA * _tether_omega_mul.get(region, 1.0)
		for bone_name: StringName in _REGION_BONES[region]:
			var bone: MarionetteBone = _find_bone_by_name(bone_name)
			if bone == null:
				continue
			var mass: float = bone.mass
			_tethers.append({
				"bone": bone,
				"region": region,
				"anchor": bone.global_position,
				"k": mass * omega * omega,
				"c": 2.0 * _TETHER_DAMPING_RATIO * mass * omega,
			})


func _on_region_toggled(region: StringName, on: bool) -> void:
	_active_regions[region] = on
	_refresh_tethers()


func _toggle_all_tethers() -> void:
	# If any region is on, turn all off. Otherwise restore the default preset.
	var any_on: bool = false
	for region: StringName in _REGION_ORDER:
		if _active_regions.get(region, false):
			any_on = true
			break
	if any_on:
		for region: StringName in _REGION_ORDER:
			_active_regions[region] = false
	else:
		for region: StringName in _PRESETS[_DEFAULT_PRESET_INDEX]["regions"]:
			_active_regions[region] = true
	_refresh_tethers()
	_sync_ui_state()


# Public button: re-capture all currently-active region anchors at the
# current bone positions. Useful after pushing the character into a new
# pose — gives you a one-click "lock the new shape" affordance without
# toggling each region off and on.
func _tether_to_current_pose() -> void:
	_refresh_tethers()


# ---------- Live tuning ----------

# Writes `value` into linear+angular damp on every bone whose region is
# in the named group. Damp mode is REPLACE (set in _initialize_bone_damping)
# so this is the authoritative damp value Jolt sees.
func _apply_group_damp(group: StringName, value: float) -> void:
	_group_damp[group] = value
	if _simulator == null:
		return
	var regions: Array = _damp_group_regions.get(group, [])
	if regions.is_empty():
		return
	for child: Node in _simulator.get_children():
		if not (child is MarionetteBone):
			continue
		var b: MarionetteBone = child
		var region: int = MarionetteBoneRegion.region_for(StringName(b.bone_name))
		if regions.has(region):
			b.linear_damp = value
			b.angular_damp = value


# Updates the tether ω multiplier for `region` and rewrites k/c on any
# in-flight tether for that region in-place — so dragging the slider while
# the character is held doesn't reset anchors mid-motion. Untethered
# regions store the multiplier for next _refresh_tethers.
func _on_tether_omega_changed(region: StringName, mul: float) -> void:
	_tether_omega_mul[region] = mul
	for t: Dictionary in _tethers:
		if t["region"] != region:
			continue
		var bone: MarionetteBone = t["bone"]
		if not is_instance_valid(bone):
			continue
		var omega: float = _TETHER_OMEGA * mul
		var mass: float = bone.mass
		t["k"] = mass * omega * omega
		t["c"] = 2.0 * _TETHER_DAMPING_RATIO * mass * omega


func _on_drag_omega_changed(mul: float) -> void:
	_drag_omega_mul = mul
	if _drag.is_empty():
		return
	var bone: MarionetteBone = _drag["bone"]
	if not is_instance_valid(bone):
		return
	var omega: float = _DRAG_OMEGA * mul
	var mass: float = bone.mass
	_drag["k"] = mass * omega * omega
	_drag["c"] = 2.0 * _DRAG_DAMPING_RATIO * mass * omega


# Live-rescales every existing bone capsule by `mul / _capsule_radius_mul`,
# updating the height to keep the capsule valid. Mutates the existing
# CapsuleShape3D in place — no rebuild, no resource swap. Cheap (~80
# bones) and the shape RID stays the same so Jolt doesn't re-cook.
# If runtime debug meshes are visible, regenerates them so they track the
# new radius (the CapsuleMesh used for visualization doesn't auto-bind to
# the CapsuleShape3D's values).
func _on_capsule_radius_changed(mul: float) -> void:
	if absf(mul - _capsule_radius_mul) < 1e-5 or _simulator == null:
		return
	var ratio: float = mul / _capsule_radius_mul
	_capsule_radius_mul = mul
	for child: Node in _simulator.get_children():
		if not (child is MarionetteBone):
			continue
		for c: Node in (child as MarionetteBone).get_children():
			if c is CollisionShape3D:
				var shape: Shape3D = (c as CollisionShape3D).shape
				if shape is CapsuleShape3D:
					var capsule: CapsuleShape3D = shape
					capsule.radius = max(capsule.radius * ratio, 0.001)
					capsule.height = max(capsule.height, 2.0 * capsule.radius + 0.001)
	if _show_capsules:
		_refresh_debug_meshes()


# ---------- Pause / step / speed ----------

func _toggle_pause() -> void:
	_paused = not _paused
	Engine.time_scale = 0.0 if _paused else _selected_speed
	_sync_ui_state()


func _step_one_frame() -> void:
	if not _paused:
		return
	# Briefly run at the chosen speed for one physics tick, then re-pause.
	Engine.time_scale = _selected_speed
	await get_tree().physics_frame
	Engine.time_scale = 0.0


func _set_speed(value: float) -> void:
	_selected_speed = value
	if not _paused:
		Engine.time_scale = value
	_sync_ui_state()


# ---------- Presets ----------

func _apply_preset_by_index(idx: int, refresh_anchors: bool = true) -> void:
	if idx < 0 or idx >= _PRESETS.size():
		return
	var preset: Dictionary = _PRESETS[idx]
	var regions: Array = preset["regions"]
	for region: StringName in _REGION_ORDER:
		_active_regions[region] = regions.has(region)
	_gravity_scale = float(preset["gravity"])
	_apply_gravity_scale()
	if refresh_anchors:
		_refresh_tethers()
	else:
		# First-time application during _ready, before bones may have moved.
		_refresh_tethers()
	_sync_ui_state()


# ---------- Floor ----------

func _toggle_floor() -> void:
	var floor: StaticBody3D = get_node_or_null(^"Floor") as StaticBody3D
	if floor == null:
		return
	# Toggle visibility AND collision via process_mode/disabled. The
	# CollisionShape3D's `disabled` property is the supported way to flip
	# collision on a static body without de-parenting.
	var shape: CollisionShape3D = floor.get_node_or_null(^"CollisionShape3D") as CollisionShape3D
	var mesh: MeshInstance3D = floor.get_node_or_null(^"MeshInstance3D") as MeshInstance3D
	var on: bool = shape == null or shape.disabled  # current state inverted = new state
	if shape != null:
		shape.disabled = not on
	if mesh != null:
		mesh.visible = on
	if _floor_button != null:
		_floor_button.text = "Floor: ON" if on else "Floor: OFF"


# ---------- Projectiles ----------

func _throw_projectile() -> void:
	if _camera == null or _projectile_root == null:
		return
	var body := RigidBody3D.new()
	body.mass = _PROJECTILE_MASS

	var shape := SphereShape3D.new()
	shape.radius = _PROJECTILE_RADIUS
	var collider := CollisionShape3D.new()
	collider.shape = shape
	body.add_child(collider)

	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = _PROJECTILE_RADIUS
	sphere_mesh.height = _PROJECTILE_RADIUS * 2.0
	var mesh := MeshInstance3D.new()
	mesh.mesh = sphere_mesh
	body.add_child(mesh)

	_projectile_root.add_child(body)
	# Spawn a hair in front of the camera so it doesn't intersect the near plane.
	body.global_position = _camera.global_position + (-_camera.global_transform.basis.z * 0.4)
	body.linear_velocity = -_camera.global_transform.basis.z * _PROJECTILE_SPEED

	# Auto-cleanup. Capture the body weakly via is_instance_valid so a manual
	# clear-projectiles or scene-tree change doesn't double-free.
	get_tree().create_timer(_PROJECTILE_LIFETIME).timeout.connect(func() -> void:
		if is_instance_valid(body):
			body.queue_free())


func _clear_projectiles() -> void:
	if _projectile_root == null:
		return
	for child: Node in _projectile_root.get_children():
		child.queue_free()


# ---------- Hovered-bone HUD ----------

# Updates the bottom-right HUD with whatever bone the cursor is over.
# Cheap (one ray cast per frame) and gives an instant readable answer to
# "what am I about to push?" + "what does its ROM look like?".
func _update_hovered_hud() -> void:
	if _hovered_label == null:
		return
	var bone: MarionetteBone = _pick_bone_at(get_viewport().get_mouse_position())
	if bone == null:
		_hovered_label.text = "(no bone under cursor)"
		return
	var lines: Array[String] = []
	lines.append(bone.bone_name)
	if bone.bone_entry != null:
		var entry: BoneEntry = bone.bone_entry
		lines.append("archetype: %s" % BoneArchetype.Type.keys()[entry.archetype])
		lines.append("mass: %.2f kg" % bone.mass)
		lines.append("ROM flex:  %5.0f° .. %5.0f°" %
				[rad_to_deg(entry.rom_min.x), rad_to_deg(entry.rom_max.x)])
		lines.append("ROM rot:   %5.0f° .. %5.0f°" %
				[rad_to_deg(entry.rom_min.y), rad_to_deg(entry.rom_max.y)])
		lines.append("ROM abd:   %5.0f° .. %5.0f°" %
				[rad_to_deg(entry.rom_min.z), rad_to_deg(entry.rom_max.z)])
	_hovered_label.text = "\n".join(lines)


# ---------- UI construction ----------

# Mounts the on-screen overlay. Two CanvasLayers: top-left for controls,
# bottom-right for the hovered-bone HUD. Plain controls, no theming.
func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	# Top-left control column.
	var col := VBoxContainer.new()
	col.position = Vector2(12, 12)
	col.add_theme_constant_override("separation", 4)
	layer.add_child(col)

	col.add_child(_build_row_actions())
	col.add_child(_build_row_tether())
	col.add_child(_build_row_regions())
	col.add_child(_build_row_speed())
	col.add_child(_build_row_preset())
	col.add_child(_build_hint_label())

	# Top-right tuning panel (sliders for damp + tether/drag spring scale).
	_build_tuning_panel()

	# Bottom-right HUD.
	var hud_layer := CanvasLayer.new()
	add_child(hud_layer)
	var hud_anchor := Control.new()
	hud_anchor.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	hud_anchor.offset_left = -260.0
	hud_anchor.offset_top = -160.0
	hud_anchor.offset_right = -12.0
	hud_anchor.offset_bottom = -12.0
	hud_layer.add_child(hud_anchor)
	_hovered_label = Label.new()
	_hovered_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hovered_label.text = "(no bone under cursor)"
	_hovered_label.add_theme_color_override("font_color", Color(0.92, 0.92, 0.95, 1.0))
	_hovered_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	_hovered_label.add_theme_constant_override("outline_size", 2)
	_hovered_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hovered_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	hud_anchor.add_child(_hovered_label)


func _build_row_actions() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var reset_btn := Button.new()
	reset_btn.text = "Reset"
	reset_btn.pressed.connect(_reset)
	row.add_child(reset_btn)

	_pause_button = Button.new()
	_pause_button.text = "Pause"
	_pause_button.pressed.connect(_toggle_pause)
	row.add_child(_pause_button)

	_step_button = Button.new()
	_step_button.text = "Step"
	_step_button.pressed.connect(_step_one_frame)
	_step_button.disabled = true  # only enabled while paused
	row.add_child(_step_button)

	var throw_btn := Button.new()
	throw_btn.text = "Throw (F)"
	throw_btn.pressed.connect(_throw_projectile)
	row.add_child(throw_btn)

	var drop_btn := Button.new()
	drop_btn.text = "Drop Test"
	drop_btn.tooltip_text = "Lift to %.1f m with a random orientation, untether, and fall under full gravity" % _DROP_HEIGHT
	drop_btn.pressed.connect(_drop_test)
	row.add_child(drop_btn)

	return row


func _build_row_tether() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	_tether_button = Button.new()
	_tether_button.text = "Untether"
	_tether_button.pressed.connect(_toggle_all_tethers)
	row.add_child(_tether_button)

	var here_btn := Button.new()
	here_btn.text = "Tether Here"
	here_btn.tooltip_text = "Re-capture anchors of currently-active regions at the live pose"
	here_btn.pressed.connect(_tether_to_current_pose)
	row.add_child(here_btn)

	_floor_button = Button.new()
	_floor_button.text = "Floor: ON"
	_floor_button.pressed.connect(_toggle_floor)
	row.add_child(_floor_button)

	return row


func _build_row_regions() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.add_child(_make_label("Tether:"))
	for region: StringName in _REGION_ORDER:
		var cb := CheckBox.new()
		cb.text = _REGION_LABELS[region]
		cb.toggled.connect(_on_region_toggled.bind(region))
		row.add_child(cb)
		_region_checks[region] = cb
	return row


func _build_row_speed() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.add_child(_make_label("Speed:"))
	_speed_buttons.clear()
	for i in range(_SPEEDS.size()):
		var btn := Button.new()
		btn.text = _SPEED_LABELS[i]
		btn.toggle_mode = true
		btn.pressed.connect(_set_speed.bind(_SPEEDS[i]))
		row.add_child(btn)
		_speed_buttons.append(btn)
	return row


func _build_row_preset() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.add_child(_make_label("Preset:"))
	_preset_dropdown = OptionButton.new()
	for i in range(_PRESETS.size()):
		_preset_dropdown.add_item(String(_PRESETS[i]["name"]), i)
	_preset_dropdown.item_selected.connect(_apply_preset_by_index)
	row.add_child(_preset_dropdown)
	return row


func _build_hint_label() -> Label:
	var hint := Label.new()
	hint.text = "RMB-drag: orbit · Wheel: zoom · LMB-drag: grab bone · F: throw · Space: pause · .: step · R: reset"
	hint.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9, 0.85))
	return hint


static func _make_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


# Builds the right-hand tuning panel: per-group damp sliders + per-region
# tether ω scale + drag ω scale. Each row reuses `_make_slider_row` for
# consistent layout (label / value / slider). The panel is pinned to the
# right edge with a fixed width; the bottom-right HUD is on a separate
# CanvasLayer so they don't fight for layout.
func _build_tuning_panel() -> void:
	const WIDTH: float = 280.0
	var layer := CanvasLayer.new()
	add_child(layer)
	var anchor := Control.new()
	anchor.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	anchor.offset_left = -WIDTH - 12.0
	anchor.offset_top = 12.0
	anchor.offset_right = -12.0
	anchor.offset_bottom = 12.0 + 580.0  # height; sized to the section count
	layer.add_child(anchor)

	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	col.add_theme_constant_override("separation", 2)
	anchor.add_child(col)

	col.add_child(_make_section_header("Damping (linear & angular)"))
	for group: StringName in _DAMP_GROUP_ORDER:
		var label_text: String = _DAMP_GROUP_LABELS[group]
		var on_change: Callable = func(v: float) -> void:
			_apply_group_damp(group, v)
		col.add_child(_make_slider_row(label_text, 0.0, 5.0, 0.05, _DEFAULT_BONE_DAMP, on_change))

	col.add_child(_make_spacer(8))
	col.add_child(_make_section_header("Tether spring ω×"))
	for region: StringName in _REGION_ORDER:
		var label_text: String = _REGION_LABELS[region]
		var on_change: Callable = func(v: float) -> void:
			_on_tether_omega_changed(region, v)
		col.add_child(_make_slider_row(label_text, 0.0, 3.0, 0.05, 1.0, on_change))

	col.add_child(_make_spacer(8))
	col.add_child(_make_section_header("Drag spring ω×"))
	col.add_child(_make_slider_row("Drag", 0.0, 3.0, 0.05, 1.0, _on_drag_omega_changed))

	col.add_child(_make_spacer(8))
	col.add_child(_make_section_header("Geometry"))
	col.add_child(_make_slider_row("Capsule R×", 0.2, 2.0, 0.05, 1.0, _on_capsule_radius_changed))
	var geo_row := HBoxContainer.new()
	geo_row.add_theme_constant_override("separation", 12)
	var collisions_cb := CheckBox.new()
	collisions_cb.text = "Bone collisions"
	collisions_cb.button_pressed = _bone_collisions_enabled
	collisions_cb.tooltip_text = "Enable bone-bone and bone-world contact. Default off — collisions are the main source of ragdoll explosion."
	collisions_cb.toggled.connect(_on_bone_collisions_toggled)
	geo_row.add_child(collisions_cb)
	var show_cb := CheckBox.new()
	show_cb.text = "Show capsules"
	show_cb.toggled.connect(_on_show_capsules_toggled)
	geo_row.add_child(show_cb)
	col.add_child(geo_row)


static func _make_section_header(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0, 1.0))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 2)
	return l


static func _make_spacer(height: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, height)
	return c


# Standard slider row: label (fixed) | value readout (fixed) | HSlider
# (fill). The `on_change` callback receives the raw slider value; the
# row updates its own value-readout label from value_changed.
static func _make_slider_row(label_text: String, min_v: float, max_v: float,
		step: float, default_v: float, on_change: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(78, 0)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", 2)
	row.add_child(label)

	var value_label := Label.new()
	value_label.text = "%.2f" % default_v
	value_label.custom_minimum_size = Vector2(38, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	value_label.add_theme_constant_override("outline_size", 2)
	row.add_child(value_label)

	var slider := HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = step
	slider.set_value_no_signal(default_v)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(120, 0)
	slider.value_changed.connect(func(v: float) -> void:
		value_label.text = "%.2f" % v
		on_change.call(v))
	row.add_child(slider)

	return row


# Pulls every visible UI control's state from the model. Called whenever
# anything that affects the UI changes (preset, region toggle, pause).
func _sync_ui_state() -> void:
	if _pause_button != null:
		_pause_button.text = "Resume" if _paused else "Pause"
	if _step_button != null:
		_step_button.disabled = not _paused
	if _tether_button != null:
		var any_on: bool = false
		for region: StringName in _REGION_ORDER:
			if _active_regions.get(region, false):
				any_on = true
				break
		_tether_button.text = "Untether" if any_on else "Re-tether"
	for region: StringName in _REGION_ORDER:
		var cb: CheckBox = _region_checks.get(region)
		if cb != null:
			cb.set_pressed_no_signal(_active_regions.get(region, false))
	# Speed buttons: highlight the currently selected one.
	for i in range(_speed_buttons.size()):
		var btn: Button = _speed_buttons[i]
		btn.set_pressed_no_signal(_SPEEDS[i] == _selected_speed)
	# Preset dropdown: select whichever preset matches active state, if any.
	if _preset_dropdown != null:
		var match_idx: int = _find_matching_preset_index()
		if match_idx >= 0 and _preset_dropdown.selected != match_idx:
			_preset_dropdown.select(match_idx)


# Returns the index of the preset whose (regions, gravity) match the live
# state, else -1. Lets the preset dropdown stay in sync when the user
# manually toggles regions to a configuration that happens to match a
# preset, instead of going stale on the previous selection.
func _find_matching_preset_index() -> int:
	for i in range(_PRESETS.size()):
		var preset: Dictionary = _PRESETS[i]
		if not is_equal_approx(_gravity_scale, float(preset["gravity"])):
			continue
		var regions: Array = preset["regions"]
		var match_all: bool = true
		for region: StringName in _REGION_ORDER:
			var should_be_on: bool = regions.has(region)
			if _active_regions.get(region, false) != should_be_on:
				match_all = false
				break
		if match_all:
			return i
	return -1


# ---------- Helpers ----------

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
