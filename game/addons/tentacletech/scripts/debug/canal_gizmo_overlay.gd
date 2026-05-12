@tool
class_name CanalGizmoOverlay
extends Node3D

## Debug visualisation for a baked `Canal` node.
##
## Per `feedback_phase_slicing.md` ("pair spatial algorithms with a
## gizmo"), 5E ships the gizmo alongside the AutoBaker rather than
## deferring it. The overlay reads static baked state from
## `canal._spline`, `canal._rest_radius_per_cell`,
## `canal._centerline_rest_positions`, and (optionally) the canal
## interior verts of `mesh_instance` for bake-roundtrip validation.
##
## Palette (per `feedback_godot_gizmo_colors.md` — Godot's default
## Skeleton3D gizmo eats orange-yellow):
##   - Cyan polyline      : Catmull spline samples through CP bones
##   - Magenta dots       : centerline particle rest positions
##   - Green plus-marks   : per-cell rest-radius grid (s_k, θ_j)
##   - Blue line segments : sparse (1-in-10) vert → spline-projection
##                          validation lines for the per-vert bake
##
## Pulled-from-state pattern matches `debug_gizmo_overlay.gd`; the
## ImmediateMesh rebuilds once per dirty flag, not every frame, since
## baked state is static. Rebuilding every frame would cost ~1ms per
## canal for the 256-cell grid; gating on dirty keeps this near zero
## when the scene is idle.

@export var canal: Node3D
## Optional — when set, the overlay draws sparse bake-roundtrip
## validation lines from each canal-interior vert to its baked
## `(s, θ)` projection on the rest spline.
@export var mesh_instance: MeshInstance3D
@export var enabled: bool = true
@export var show_spline: bool = true
@export var show_centerline_rest: bool = true
@export var show_cell_grid: bool = true
@export var show_bake_validation: bool = false
@export var spline_sample_count: int = 64
@export var cell_marker_size: float = 0.005
@export var centerline_dot_size: float = 0.008
@export_range(1, 100, 1) var bake_validation_sample_every: int = 10

const _COLOR_SPLINE := Color(0.0, 1.0, 1.0)        # cyan
const _COLOR_CENTERLINE := Color(1.0, 0.0, 1.0)    # magenta
const _COLOR_CELLS := Color(0.0, 1.0, 0.4)         # green (slight cyan shift; avoids orange-yellow eats)
const _COLOR_BAKE := Color(0.3, 0.5, 1.0)          # blue

var _mesh_inst: MeshInstance3D
var _im: ImmediateMesh
var _mat: StandardMaterial3D
var _last_signature: int = 0  # hash of state we last rendered


func _ready() -> void:
	_mesh_inst = MeshInstance3D.new()
	_mesh_inst.name = "CanalGizmoMesh"
	add_child(_mesh_inst, false, Node.INTERNAL_MODE_FRONT)
	_im = ImmediateMesh.new()
	_mesh_inst.mesh = _im
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.vertex_color_use_as_albedo = true
	_mat.disable_receive_shadows = true
	_mat.disable_fog = true
	_mat.no_depth_test = true
	_mesh_inst.material_override = _mat


func _process(_delta: float) -> void:
	if not enabled or canal == null:
		visible = false
		return
	visible = true
	var sig := _state_signature()
	if sig != _last_signature:
		_last_signature = sig
		_rebuild()


# Cheap hash of the inputs that influence rendering. When this changes
# (canal reassigned, bake reran, mesh swapped) we rebuild; otherwise
# the cached ImmediateMesh stays up.
func _state_signature() -> int:
	var h := 0
	if canal != null:
		h ^= canal.get_instance_id()
		var spline = canal.call("get_baked_spline") if canal.has_method("get_baked_spline") else null
		if spline != null:
			h ^= spline.get_instance_id()
		var positions: PackedVector3Array = canal.call("get_baked_centerline_rest_positions") \
				if canal.has_method("get_baked_centerline_rest_positions") \
				else PackedVector3Array()
		h ^= positions.size() * 31
		var cells: PackedFloat32Array = canal.call("get_baked_rest_radius_per_cell") \
				if canal.has_method("get_baked_rest_radius_per_cell") \
				else PackedFloat32Array()
		h ^= cells.size() * 1031
	if mesh_instance != null:
		h ^= mesh_instance.get_instance_id()
	h ^= (1 if show_spline else 0)
	h ^= (2 if show_centerline_rest else 0)
	h ^= (4 if show_cell_grid else 0)
	h ^= (8 if show_bake_validation else 0)
	return h


func _rebuild() -> void:
	_im.clear_surfaces()
	if canal == null:
		return
	var spline: RefCounted = canal.call("get_baked_spline") if canal.has_method("get_baked_spline") else null
	if spline == null:
		return

	# Sample spline once; reused by all sub-layers.
	var samples: PackedVector3Array = PackedVector3Array()
	samples.resize(spline_sample_count)
	for i in spline_sample_count:
		var t := float(i) / float(spline_sample_count - 1)
		samples[i] = spline.evaluate_position(t)

	if show_spline:
		_draw_polyline(samples, _COLOR_SPLINE)

	if show_centerline_rest:
		var rest_positions: PackedVector3Array = canal.call("get_baked_centerline_rest_positions")
		for p in rest_positions:
			_draw_cross(p, centerline_dot_size, _COLOR_CENTERLINE)

	if show_cell_grid:
		_draw_cell_grid(spline)

	if show_bake_validation and mesh_instance != null:
		_draw_bake_validation(spline)


# ─── Primitives ────────────────────────────────────────────────────

func _draw_polyline(p_pts: PackedVector3Array, p_color: Color) -> void:
	if p_pts.size() < 2:
		return
	_im.surface_begin(Mesh.PRIMITIVE_LINES, _mat)
	for i in range(p_pts.size() - 1):
		_im.surface_set_color(p_color)
		_im.surface_add_vertex(p_pts[i])
		_im.surface_set_color(p_color)
		_im.surface_add_vertex(p_pts[i + 1])
	_im.surface_end()


func _draw_cross(p_center: Vector3, p_size: float, p_color: Color) -> void:
	_im.surface_begin(Mesh.PRIMITIVE_LINES, _mat)
	for axis in [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)]:
		_im.surface_set_color(p_color)
		_im.surface_add_vertex(p_center - axis * p_size)
		_im.surface_set_color(p_color)
		_im.surface_add_vertex(p_center + axis * p_size)
	_im.surface_end()


# Plus-mark (2D) oriented in the spline frame at the cell — pinned to
# the cell's rest-radius position so the grid reads as a tube of dots
# around the spline.
func _draw_cell_grid(p_spline: RefCounted) -> void:
	if canal == null:
		return
	var params: CanalParameters = canal.canal_parameters
	if params == null:
		return
	var rest_radius: PackedFloat32Array = canal.call("get_baked_rest_radius_per_cell")
	var axial: int = params.canal_axial_segments
	var sectors: int = params.canal_angular_sectors
	if rest_radius.size() != axial * sectors:
		return
	var arc: float = p_spline.get_arc_length()
	_im.surface_begin(Mesh.PRIMITIVE_LINES, _mat)
	for k in axial:
		var s_norm := float(k) / maxf(float(axial - 1), 1.0)
		var s := s_norm * arc
		var t: float = p_spline.distance_to_parameter(s)
		var origin: Vector3 = p_spline.evaluate_position(t)
		var frame: Dictionary = p_spline.evaluate_frame(t)
		var normal: Vector3 = (frame["normal"] as Vector3).normalized()
		var binormal: Vector3 = (frame["binormal"] as Vector3).normalized()
		for j in sectors:
			var theta := TAU * float(j) / float(sectors)
			var outward := normal * cos(theta) + binormal * sin(theta)
			var r: float = rest_radius[k * sectors + j]
			var p := origin + outward * r
			# 2D plus-mark in the local plane (normal/binormal axes).
			_im.surface_set_color(_COLOR_CELLS)
			_im.surface_add_vertex(p - normal * cell_marker_size)
			_im.surface_set_color(_COLOR_CELLS)
			_im.surface_add_vertex(p + normal * cell_marker_size)
			_im.surface_set_color(_COLOR_CELLS)
			_im.surface_add_vertex(p - binormal * cell_marker_size)
			_im.surface_set_color(_COLOR_CELLS)
			_im.surface_add_vertex(p + binormal * cell_marker_size)
	_im.surface_end()


# Sparse vert → projection-onto-spline lines. Validates step 10's
# bake math at-a-glance: if a vert's bake was correct, the line from
# the vert to its baked (s, θ, rest_radius) projection on the spline
# should be straight along the outward direction.
func _draw_bake_validation(p_spline: RefCounted) -> void:
	if mesh_instance == null or mesh_instance.mesh == null:
		return
	var mesh: Mesh = mesh_instance.mesh
	var xform: Transform3D = mesh_instance.global_transform
	var canal_id_plus_one: int = 1
	if canal.has_method("get_canal_id"):
		canal_id_plus_one = canal.get_canal_id() + 1
	var target: float = float(canal_id_plus_one)

	_im.surface_begin(Mesh.PRIMITIVE_LINES, _mat)
	for surface_idx in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(surface_idx)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var c0: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
		var c1: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM1]
		if c0.is_empty() or c1.is_empty():
			continue
		var fpv := c0.size() / verts.size() if verts.size() > 0 else 0
		var fpv1 := c1.size() / verts.size() if verts.size() > 0 else 0
		if fpv == 0 or fpv1 == 0:
			continue
		var step: int = max(1, bake_validation_sample_every)
		for v_idx in range(0, verts.size(), step):
			if absf(c0[v_idx * fpv] - target) > 0.5:
				continue
			# Reconstruct the projection from baked (s, θ, rest_r)
			var s: float = c1[v_idx * fpv1 + 0]
			var theta: float = c1[v_idx * fpv1 + 1]
			var rest_r: float = c1[v_idx * fpv1 + 2]
			var t: float = p_spline.distance_to_parameter(s)
			var origin: Vector3 = p_spline.evaluate_position(t)
			var frame: Dictionary = p_spline.evaluate_frame(t)
			var normal: Vector3 = (frame["normal"] as Vector3).normalized()
			var binormal: Vector3 = (frame["binormal"] as Vector3).normalized()
			var outward := normal * cos(theta) + binormal * sin(theta)
			var reconstructed := origin + outward * rest_r
			var vert_world: Vector3 = xform * verts[v_idx]
			_im.surface_set_color(_COLOR_BAKE)
			_im.surface_add_vertex(vert_world)
			_im.surface_set_color(_COLOR_BAKE)
			_im.surface_add_vertex(reconstructed)
	_im.surface_end()
