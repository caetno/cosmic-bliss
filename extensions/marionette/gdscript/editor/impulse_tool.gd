@tool
class_name MarionetteImpulseTool
extends RefCounted

# Apply-Impulse viewport tool for Ragdoll Test mode (P5.8 / slice 8d).
#
# State machine: idle → pressed (click on a MarionetteBone) → released.
# Click raycasts the editor viewport against the simulator's bone
# colliders; release applies a world-space impulse on the hit bone scaled
# by the drag length, capped at the milestone target of 500 N·s.
#
# Drag-line render path: a child MeshInstance3D under the Marionette node
# holds an ImmediateMesh; we rebuild it every frame the tool is active.
# Per CLAUDE.md "Never" list, ImmediateMesh is the right primitive
# (ArrayMesh would be a per-frame rebuild trap). The visibility coalesce
# per `reference_godot_tool_gizmo_redraw.md` happens via a single _dirty
# flag — the plugin's input forwarder calls `update_drag_visual()` at most
# once per input event.
#
# Color is cyan (no orange-yellow per `feedback_godot_gizmo_colors.md`).
#
# Activation: the dock flips `active` on Ragdoll-Test entry/exit. The
# editor plugin's `_forward_3d_gui_input` routes mouse events here only
# when `active` is true.

const DRAG_VISUAL_NAME: StringName = &"_RagdollTestDragLine"
const DRAG_COLOR: Color = Color(0.25, 0.95, 1.0, 1.0)
const IMPULSE_PER_PIXEL: float = 2.0       # N·s per pixel of drag (tunable)
const IMPULSE_MAX: float = 500.0           # P5 milestone target cap
const RAYCAST_LENGTH: float = 1000.0        # editor cam → far-clip equiv

var active: bool = false

# Current Marionette being targeted. Set by the plugin (which proxies the
# dock's _active_marionette) at mode-entry time. Null when inactive.
var marionette: Marionette

# Drag state.
var _pressed: bool = false
var _hit_bone: MarionetteBone
var _hit_world_pos: Vector3 = Vector3.ZERO
var _press_screen_pos: Vector2 = Vector2.ZERO
var _drag_screen_pos: Vector2 = Vector2.ZERO
var _drag_visual: MeshInstance3D
var _drag_mesh: ImmediateMesh


# Plugin entry — feed editor 3D viewport input events here. Returns true
# when the tool consumed the event (so the editor doesn't process it as
# selection, etc.). Mouse drag/release are consumed only when a bone was
# pressed; otherwise events pass through.
func handle_input(camera: Camera3D, event: InputEvent) -> bool:
	if not active or marionette == null or camera == null:
		return false
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return false
		if mb.pressed:
			return _on_press(camera, mb.position)
		else:
			return _on_release(camera, mb.position)
	if event is InputEventMouseMotion and _pressed:
		_drag_screen_pos = (event as InputEventMouseMotion).position
		_update_drag_visual(camera)
		return true
	return false


func _on_press(camera: Camera3D, screen_pos: Vector2) -> bool:
	var hit: Dictionary = _raycast_bones(camera, screen_pos)
	if hit.is_empty():
		return false
	_pressed = true
	_hit_bone = hit.bone
	_hit_world_pos = hit.position
	_press_screen_pos = screen_pos
	_drag_screen_pos = screen_pos
	_ensure_drag_visual()
	_update_drag_visual(camera)
	return true


func _on_release(camera: Camera3D, screen_pos: Vector2) -> bool:
	if not _pressed:
		return false
	_drag_screen_pos = screen_pos
	var impulse: Vector3 = compute_impulse(camera)
	if is_instance_valid(_hit_bone):
		_hit_bone.apply_impulse(impulse, _hit_world_pos - _hit_bone.global_transform.origin)
	_pressed = false
	_hit_bone = null
	_release_drag_visual()
	return true


# Pure math seam — exposed for tests. Maps the press→release screen-delta
# into a world-space impulse vector via the camera's basis. Magnitude
# scales linearly with pixel-distance, clamped to IMPULSE_MAX.
func compute_impulse(camera: Camera3D) -> Vector3:
	var delta: Vector2 = _drag_screen_pos - _press_screen_pos
	# Screen-Y is positive-down; world drag-up should produce a world-up
	# impulse. The camera basis already encodes screen-space orientation
	# (basis.x = right, basis.y = up). Pixel delta × IMPULSE_PER_PIXEL.
	var world: Vector3 = (
			camera.global_transform.basis.x * delta.x
			+ camera.global_transform.basis.y * (-delta.y))
	world *= IMPULSE_PER_PIXEL
	if world.length() > IMPULSE_MAX:
		world = world.normalized() * IMPULSE_MAX
	return world


# Test-only seam — drive the tool's internal state without a real viewport.
# Call order: prepare_for_test(...) → compute_impulse(camera).
func prepare_for_test(press: Vector2, release: Vector2) -> void:
	_press_screen_pos = press
	_drag_screen_pos = release


# --- viewport raycast (uses the editor camera's project_ray_origin/normal) ---

func _raycast_bones(camera: Camera3D, screen_pos: Vector2) -> Dictionary:
	if marionette == null:
		return {}
	var sim: PhysicalBoneSimulator3D = _find_simulator(marionette)
	if sim == null:
		return {}
	var space_state: PhysicsDirectSpaceState3D = sim.get_world_3d().direct_space_state
	if space_state == null:
		return {}
	var origin: Vector3 = camera.project_ray_origin(screen_pos)
	var dir: Vector3 = camera.project_ray_normal(screen_pos)
	var end: Vector3 = origin + dir * RAYCAST_LENGTH
	var params := PhysicsRayQueryParameters3D.create(origin, end)
	# Restrict to MarionetteBone colliders by collecting their RIDs. Without
	# this filter, terrain / scenery interferes. Both MarionetteBone and
	# JiggleBone are RigidBody3Ds, so `collider` is a CollisionObject3D and
	# we check is-a MarionetteBone after the hit.
	var result: Dictionary = space_state.intersect_ray(params)
	if result.is_empty():
		return {}
	var hit_node: Object = result.get("collider")
	if hit_node is MarionetteBone:
		return {"bone": hit_node as MarionetteBone, "position": result.get("position") as Vector3}
	return {}


static func _find_simulator(m: Marionette) -> PhysicalBoneSimulator3D:
	var skel: Skeleton3D = m.resolve_skeleton()
	if skel == null:
		return null
	for child: Node in skel.get_children():
		if child is PhysicalBoneSimulator3D:
			return child
	return null


# --- drag-line render ---

func _ensure_drag_visual() -> void:
	if marionette == null:
		return
	if _drag_visual != null and is_instance_valid(_drag_visual):
		return
	_drag_mesh = ImmediateMesh.new()
	_drag_visual = MeshInstance3D.new()
	_drag_visual.name = String(DRAG_VISUAL_NAME)
	_drag_visual.mesh = _drag_mesh
	_drag_visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_drag_visual.set_meta(&"_marionette_editor_only", true)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = DRAG_COLOR
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	mat.no_depth_test = true
	_drag_visual.material_override = mat
	marionette.add_child(_drag_visual)


func _release_drag_visual() -> void:
	if _drag_visual != null and is_instance_valid(_drag_visual):
		_drag_visual.queue_free()
	_drag_visual = null
	_drag_mesh = null


func _update_drag_visual(camera: Camera3D) -> void:
	if _drag_mesh == null or not _pressed:
		return
	# Project the current screen position onto a plane through the hit
	# point parallel to the camera's view plane. This gives a smooth
	# follow without depending on per-frame raycasts.
	var origin: Vector3 = camera.project_ray_origin(_drag_screen_pos)
	var dir: Vector3 = camera.project_ray_normal(_drag_screen_pos)
	var plane := Plane(camera.global_transform.basis.z, _hit_world_pos)
	var intersect: Variant = plane.intersects_ray(origin, dir)
	if intersect == null:
		return
	var end: Vector3 = intersect
	_drag_mesh.clear_surfaces()
	# Strictly paired surface_begin/end per reference_godot_tentacletech_gotchas
	# (ImmediateMesh empty-surface error).
	_drag_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	_drag_mesh.surface_add_vertex(_hit_world_pos)
	_drag_mesh.surface_add_vertex(end)
	_drag_mesh.surface_end()
