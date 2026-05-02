@tool
extends MeshInstance3D
## Environment-probe layer (Phase-4 slice 4A) — visualizes the 3 type-4
## raycasts the Tentacle issues per tick. Pulled from
## `Tentacle.get_environment_contacts_snapshot()` per frame, no push from C++.
##
## Drawn elements:
##   - Ray segment from origin to (hit_point if hit else origin + dir × max).
##     Magenta when hit, dimmed grey when miss.
##   - Hit-point marker (small magenta cross).
##   - Hit-normal stub (mint line, length = `normal_stub_length`) at hit_point.

const _Colors := preload("res://addons/tentacletech/scripts/debug/colors.gd")

const HIT_POINT_SIZE := 0.025
const NORMAL_STUB_LENGTH := 0.12
const MISS_RAY_LENGTH := 1.0
# Slice 4B — friction arrows are scaled up so the per-tick tangential
# correction (typically 1e-4..1e-3 m at 60 Hz) is visible at scene scale.
# Off by default; user can flip the toggle on the layer to inspect stick-slip.
const FRICTION_VECTOR_GAIN := 200.0
const FRICTION_VECTOR_MAX := 0.25

@export var draw_friction_vectors: bool = false

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

	# Snapshot positions are world-space — match the other layers' convention.
	top_level = true


func update_from(p_tentacle: Node3D) -> void:
	_imesh.clear_surfaces()
	if p_tentacle == null:
		return
	if not p_tentacle.has_method(&"get_environment_contacts_snapshot"):
		return
	var contacts: Array = p_tentacle.call(&"get_environment_contacts_snapshot")
	if contacts.is_empty():
		return

	_imesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for entry in contacts:
		if not (entry is Dictionary):
			continue
		var origin: Vector3 = entry.get("ray_origin", Vector3.ZERO)
		var direction: Vector3 = entry.get("ray_direction", Vector3.DOWN)
		var hit: bool = entry.get("hit", false)
		var hit_point: Vector3 = entry.get("hit_point", Vector3.ZERO)
		var hit_normal: Vector3 = entry.get("hit_normal", Vector3.UP)

		var ray_color: Color = _Colors.ENV_RAY_HIT if hit else _Colors.ENV_RAY_NO_HIT
		var ray_end: Vector3 = hit_point if hit else origin + direction * MISS_RAY_LENGTH

		_imesh.surface_set_color(ray_color); _imesh.surface_add_vertex(origin)
		_imesh.surface_set_color(ray_color); _imesh.surface_add_vertex(ray_end)

		if hit:
			_draw_hit_marker(hit_point, HIT_POINT_SIZE, _Colors.ENV_HIT_POINT)
			_imesh.surface_set_color(_Colors.ENV_HIT_NORMAL)
			_imesh.surface_add_vertex(hit_point)
			_imesh.surface_set_color(_Colors.ENV_HIT_NORMAL)
			_imesh.surface_add_vertex(hit_point + hit_normal * NORMAL_STUB_LENGTH)
			if draw_friction_vectors:
				var fa: Vector3 = entry.get("friction_applied", Vector3.ZERO)
				var fa_len: float = fa.length()
				if fa_len > 1e-7:
					var scaled_len: float = minf(fa_len * FRICTION_VECTOR_GAIN, FRICTION_VECTOR_MAX)
					var dir: Vector3 = fa / fa_len
					_imesh.surface_set_color(_Colors.ENV_FRICTION)
					_imesh.surface_add_vertex(hit_point)
					_imesh.surface_set_color(_Colors.ENV_FRICTION)
					_imesh.surface_add_vertex(hit_point + dir * scaled_len)
	_imesh.surface_end()


func _draw_hit_marker(p_center: Vector3, p_size: float, p_color: Color) -> void:
	var half: float = p_size * 0.5
	_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_center + Vector3(half, 0, 0))
	_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_center - Vector3(half, 0, 0))
	_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_center + Vector3(0, half, 0))
	_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_center - Vector3(0, half, 0))
	_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_center + Vector3(0, 0, half))
	_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_center - Vector3(0, 0, half))
