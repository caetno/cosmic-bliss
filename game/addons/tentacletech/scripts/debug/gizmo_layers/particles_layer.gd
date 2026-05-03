@tool
extends MeshInstance3D
## Particles layer — one ImmediateMesh rebuilt per _process from the Tentacle's
## particle snapshot. Each particle is drawn as a 3-axis cross gizmo (3 line
## segments). Color = lerp(red, white, inv_mass): red = pinned, white = free.
##
## A single StandardMaterial3D with vertex_color_use_as_albedo = true and
## SHADING_MODE_UNSHADED encodes color in vertices. No per-line materials.

const _Colors := preload("res://addons/tentacletech/scripts/debug/colors.gd")

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
	# top_level was previously set here to render in world space, but Godot
	# doesn't fully detach the global basis when a top_level node is added
	# beneath a rotated parent — the layer ends up inheriting the Tentacle's
	# rotation as its own, which then re-applies to every vertex during
	# rendering. The robust pattern is to leave the layer parented (so its
	# global_transform tracks the Tentacle's) and convert world particle
	# positions to layer-local in update_from, which the parent transform
	# then projects back to world.


func update_from(p_tentacle: Node3D, p_size: float) -> void:
	_imesh.clear_surfaces()
	if p_tentacle == null:
		return

	var positions: PackedVector3Array = p_tentacle.call(&"get_particle_positions")
	var inv_masses: PackedFloat32Array = p_tentacle.call(&"get_particle_inv_masses")
	var n: int = positions.size()
	if n == 0:
		return

	# Convert world-space particle positions to layer-local space. The layer
	# inherits the Tentacle's transform, so its global_transform projects
	# layer-local back to world during render — net effect: crosses appear
	# at the world particle positions. Cross arms are kept in layer-local
	# axes (constant size) by NOT rotating them.
	var inv: Transform3D = global_transform.affine_inverse()

	_imesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var half: float = p_size * 0.5
	for i in n:
		var p: Vector3 = inv * positions[i]
		var w: float = inv_masses[i] if i < inv_masses.size() else 1.0
		var c: Color = _Colors.particle_color(w)
		_imesh.surface_set_color(c)

		_imesh.surface_set_color(c); _imesh.surface_add_vertex(p + Vector3(half, 0, 0))
		_imesh.surface_set_color(c); _imesh.surface_add_vertex(p - Vector3(half, 0, 0))

		_imesh.surface_set_color(c); _imesh.surface_add_vertex(p + Vector3(0, half, 0))
		_imesh.surface_set_color(c); _imesh.surface_add_vertex(p - Vector3(0, half, 0))

		_imesh.surface_set_color(c); _imesh.surface_add_vertex(p + Vector3(0, 0, half))
		_imesh.surface_set_color(c); _imesh.surface_add_vertex(p - Vector3(0, 0, half))
	_imesh.surface_end()
