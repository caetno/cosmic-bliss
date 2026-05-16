@tool
class_name BodySurfaceFieldGizmo
extends Node3D

## Pull-style debug viz for `BodySurfaceField`. Renders a heat-map of
## one attachment's baked weights as a colored point cloud on the body
## surface mesh. Pre-allocated `ImmediateMesh` reused per refresh — no
## per-frame allocation.
##
## Color ramp: dark blue (weight=0) → cyan → green → magenta (weight=1).
## Avoids orange-yellow per project gizmo-color rule (Godot's default
## Skeleton3D gizmo eats warm hues).

const _POINT_SIZE: float = 0.012

var _mi: MeshInstance3D = null
var _imesh: ImmediateMesh = null
var _mat: StandardMaterial3D = null
var _field: BodySurfaceField = null
var _attachment_index: int = 0


func _ready() -> void:
	_mi = MeshInstance3D.new()
	_imesh = ImmediateMesh.new()
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.vertex_color_use_as_albedo = true
	_mat.use_point_size = true
	_mat.point_size = 6.0
	_mi.mesh = _imesh
	_mi.material_override = _mat
	add_child(_mi)
	_rebuild()


func set_field(f: BodySurfaceField, attachment_index: int) -> void:
	_field = f
	_attachment_index = attachment_index
	if _imesh != null:
		_rebuild()


func _rebuild() -> void:
	if _imesh == null:
		return
	_imesh.clear_surfaces()
	if _field == null:
		return
	if _attachment_index < 0 or _attachment_index >= _field.attachments.size():
		return
	var att: SurfaceAttachment = _field.attachments[_attachment_index]
	if att == null:
		return
	var verts: PackedVector3Array = _field.get_source_vertices()
	if verts.is_empty():
		return
	var w: PackedFloat32Array = att.baked_weights
	# Determine ramp bounds.
	var w_max: float = 1.0e-9
	if w.size() == verts.size():
		for i in range(w.size()):
			if w[i] > w_max:
				w_max = w[i]
	_imesh.surface_begin(Mesh.PRIMITIVE_POINTS)
	for vi in range(verts.size()):
		var t: float = 0.0
		if w.size() == verts.size():
			t = clampf(w[vi] / w_max, 0.0, 1.0)
		_imesh.surface_set_color(_color_ramp(t))
		_imesh.surface_add_vertex(verts[vi])
	_imesh.surface_end()


func _color_ramp(t: float) -> Color:
	# Cool→hot ramp avoiding orange-yellow: dark blue → cyan → green → magenta.
	if t < 0.333:
		var k: float = t / 0.333
		return Color(0.0, 0.2 + 0.6 * k, 0.6 + 0.4 * k)
	elif t < 0.666:
		var k2: float = (t - 0.333) / 0.333
		return Color(0.0, 0.8 + 0.2 * k2, 1.0 - 0.7 * k2)
	else:
		var k3: float = (t - 0.666) / 0.334
		return Color(0.0 + 0.95 * k3, 1.0 - 0.8 * k3, 0.3 + 0.55 * k3)
