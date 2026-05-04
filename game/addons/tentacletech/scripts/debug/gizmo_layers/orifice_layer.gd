@tool
extends MeshInstance3D
## Orifice rim layer (Phase 5 slice 5A) — one ImmediateMesh rebuilt per
## _process from `Orifice.get_rim_loop_state(loop_index)` snapshots. Pulls,
## never pushes — the C++ Orifice does not know this overlay exists.
##
## Per loop:
##  - Rim particle current positions as small 3-axis crosses (white).
##  - Closed-loop segments between consecutive rim particles (cyan).
##  - Per-particle authored rest position as a small mint-green dot
##    drawn behind the current cross — deformation reads as the gap
##    between current and rest.
##
## Multi-loop: every loop draws in the same colors. Visual disambiguation
## (per-loop hue, etc.) is reserved for Phase 5 slice 5C / Phase 8.

const _Colors := preload("res://addons/tentacletech/scripts/debug/colors.gd")

const RIM_PARTICLE_SIZE := 0.012
const REST_MARKER_SIZE := 0.006
const HOST_BONE_MARKER_SIZE := 0.018

# Bright cyan — distinct from particle layer's white crosses and the
# constraint layer's rest-color (also white). Picks up "this segment is
# the orifice rim, not a tentacle chain segment" at a glance.
const RIM_SEGMENT_COLOR := Color(0.4, 0.95, 1.0, 0.9)
# Mint that stays distinct from the particle layer's red-pinned and the
# rim segment cyan; matches Reverie's "neutral rest" palette.
const REST_MARKER_COLOR := Color(0.55, 1.0, 0.8, 0.7)
# Red-purple for the host bone marker — distinct from the rim cyan, the
# rest mint, and Godot's default skeleton orange-yellow. Tells the user
# at a glance "this is where the orifice's Center frame is anchored on
# the ragdoll".
const HOST_BONE_COLOR := Color(0.95, 0.35, 0.85, 0.95)

var _imesh: ImmediateMesh
var _material: StandardMaterial3D


func _ready() -> void:
	_imesh = ImmediateMesh.new()
	mesh = _imesh

	_material = StandardMaterial3D.new()
	_material.vertex_color_use_as_albedo = true
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.no_depth_test = true
	_material.disable_receive_shadows = true
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.render_priority = RenderingServer.MATERIAL_RENDER_PRIORITY_MAX
	material_override = _material


# Pull from a single Orifice snapshot. Caller is expected to call this
# once per _process when the layer is visible.
func update_from(p_orifice: Node3D) -> void:
	_imesh.clear_surfaces()
	if p_orifice == null:
		return
	var loop_count: int = int(p_orifice.call(&"get_rim_loop_count"))
	if loop_count <= 0:
		return

	# Convert world-space snapshot positions to layer-local — same pattern
	# as particles_layer.gd. The layer inherits its parent's transform and
	# Godot re-projects to world during render; doing the math here keeps
	# cross-arm sizes constant in world space regardless of any parent
	# scaling.
	var inv: Transform3D = global_transform.affine_inverse()
	_imesh.surface_begin(Mesh.PRIMITIVE_LINES)

	for li in loop_count:
		var state: Array = p_orifice.call(&"get_rim_loop_state", li)
		var n: int = state.size()
		if n < 2:
			continue
		# Pre-project all positions for the loop.
		var current_local: PackedVector3Array = PackedVector3Array()
		var rest_local: PackedVector3Array = PackedVector3Array()
		current_local.resize(n)
		rest_local.resize(n)
		for k in n:
			var d: Dictionary = state[k]
			current_local[k] = inv * (d["current_position"] as Vector3)
			rest_local[k] = inv * (d["rest_position"] as Vector3)

		# Closed-loop rim segments.
		for k in n:
			var k1: int = (k + 1) % n
			_imesh.surface_set_color(RIM_SEGMENT_COLOR)
			_imesh.surface_add_vertex(current_local[k])
			_imesh.surface_set_color(RIM_SEGMENT_COLOR)
			_imesh.surface_add_vertex(current_local[k1])

		# Per-particle current position cross (color reflects pinned/free).
		for k in n:
			var d: Dictionary = state[k]
			var inv_mass: float = d.get("inv_mass", 1.0)
			var c: Color = _Colors.particle_color(inv_mass)
			_draw_cross(current_local[k], RIM_PARTICLE_SIZE, c)

		# Rest position as a small mint dot — deformation reads as the
		# offset between rest and current.
		for k in n:
			_draw_cross(rest_local[k], REST_MARKER_SIZE, REST_MARKER_COLOR)

	# Slice 5B — host bone marker. Drawn once for the orifice (not per
	# loop) at the bone's resolved world position. Helps debug "is the
	# orifice tracking the right bone".
	var host_state: Dictionary = p_orifice.call(&"get_host_bone_state")
	if host_state.get("has_host_bone", false):
		var bone_xform: Transform3D = host_state.get("current_world_transform", Transform3D())
		var bone_world: Vector3 = bone_xform.origin
		_draw_cross(inv * bone_world, HOST_BONE_MARKER_SIZE, HOST_BONE_COLOR)

	_imesh.surface_end()


func _draw_cross(p_pos: Vector3, p_size: float, p_color: Color) -> void:
	var h: float = p_size * 0.5
	_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_pos + Vector3(h, 0, 0))
	_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_pos - Vector3(h, 0, 0))
	_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_pos + Vector3(0, h, 0))
	_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_pos - Vector3(0, h, 0))
	_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_pos + Vector3(0, 0, h))
	_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_pos - Vector3(0, 0, h))
