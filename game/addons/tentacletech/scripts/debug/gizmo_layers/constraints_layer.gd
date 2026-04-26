@tool
extends MeshInstance3D
## Constraints layer — distance constraints (segment lines colored by stretch),
## bending arcs at every triple (subtle cyan), target-pull arrow ending at a
## small target marker, and a wireframe sphere at the anchor particle.
##
## Distance-constraint stretch ratio → color:
##   ≤ 0.95 → blue   (compressed)
##   ≈ 1.00 → white  (rest)
##   ≥ 1.05 → red    (stretched)
## Bending arcs are drawn at every middle particle of a triple in a fixed cyan
## tint; their *visible curvature* is the angle constraint's current state.

const COMPRESSED := Color(0.2, 0.4, 1.0)
const REST := Color(1.0, 1.0, 1.0)
const STRETCHED := Color(1.0, 0.2, 0.2)
const TARGET_COLOR := Color(0.4, 1.0, 0.4)
const ANCHOR_COLOR := Color(1.0, 1.0, 0.2)
const BENDING_COLOR := Color(0.4, 0.85, 1.0, 0.6)

const COMPRESSED_RATIO := 0.95
const STRETCHED_RATIO := 1.05
const ANCHOR_GIZMO_SIZE := 0.04
const ARROW_HEAD_FRACTION := 0.18
const ARROW_HEAD_PERP_FRACTION := 0.45
const TARGET_MARKER_SIZE := 0.025
const BENDING_ARC_RADIUS_FRACTION := 0.18  # of segment length
const BENDING_ARC_SEGMENTS := 8
const SPHERE_CIRCLE_SEGMENTS := 12

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
	# Lines with vertex alpha need transparency mode; alpha=0.6 on bending arcs
	# only takes effect with this enabled.
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material_override = _material

	top_level = true


func update_from(p_tentacle: Node3D, p_show_bending: bool = true) -> void:
	_imesh.clear_surfaces()
	if p_tentacle == null:
		return

	var positions: PackedVector3Array = p_tentacle.call(&"get_particle_positions")
	var ratios: PackedFloat32Array = p_tentacle.call(&"get_segment_stretch_ratios")
	var n: int = positions.size()
	if n < 2:
		return

	# Estimate segment length for sizing the bending arc — use the rest of the
	# first segment if available, otherwise the current.
	var sl: float = (positions[1] - positions[0]).length()
	if ratios.size() > 0 and ratios[0] > 1e-4:
		sl /= ratios[0]
	var bend_radius: float = sl * BENDING_ARC_RADIUS_FRACTION

	_imesh.surface_begin(Mesh.PRIMITIVE_LINES)

	# Distance constraints.
	for i in n - 1:
		var ratio: float = ratios[i] if i < ratios.size() else 1.0
		var c: Color = _stretch_color(ratio)
		_imesh.surface_set_color(c); _imesh.surface_add_vertex(positions[i])
		_imesh.surface_set_color(c); _imesh.surface_add_vertex(positions[i + 1])

	# Bending arcs (subtle) — visualize the angle constraint between every
	# triple. Curvature visibly relaxes when bending_stiffness is reduced.
	if p_show_bending and bend_radius > 1e-5:
		for i in range(1, n - 1):
			_draw_bending_arc(positions[i - 1], positions[i], positions[i + 1],
					bend_radius, BENDING_COLOR)

	# Target-pull arrow + small marker at the target.
	var pull_state: Dictionary = p_tentacle.call(&"get_target_pull_state")
	if pull_state.get("active", false):
		var pidx: int = pull_state.get("particle_index", -1)
		if pidx >= 0 and pidx < n:
			var from: Vector3 = positions[pidx]
			var to: Vector3 = pull_state.get("target", from)
			_draw_arrow(from, to, TARGET_COLOR)
			_draw_cross(to, TARGET_MARKER_SIZE, TARGET_COLOR)

	# Anchor sphere at the pinned particle.
	var anchor_state: Dictionary = p_tentacle.call(&"get_anchor_state")
	var anchor_idx: int = anchor_state.get("particle_index", -1)
	if anchor_idx >= 0 and anchor_idx < n:
		_draw_sphere(positions[anchor_idx], ANCHOR_GIZMO_SIZE, ANCHOR_COLOR)

	_imesh.surface_end()


func _stretch_color(p_ratio: float) -> Color:
	if p_ratio <= COMPRESSED_RATIO:
		return COMPRESSED
	if p_ratio >= STRETCHED_RATIO:
		return STRETCHED
	if p_ratio < 1.0:
		var t: float = (p_ratio - COMPRESSED_RATIO) / (1.0 - COMPRESSED_RATIO)
		return COMPRESSED.lerp(REST, t)
	var t2: float = (p_ratio - 1.0) / (STRETCHED_RATIO - 1.0)
	return REST.lerp(STRETCHED, t2)


func _draw_arrow(p_from: Vector3, p_to: Vector3, p_color: Color) -> void:
	_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_from)
	_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_to)
	var dir: Vector3 = p_to - p_from
	var dir_len: float = dir.length()
	if dir_len < 1e-4:
		return
	var dir_n: Vector3 = dir / dir_len
	var head_len: float = dir_len * ARROW_HEAD_FRACTION
	var perp: Vector3 = dir_n.cross(Vector3.UP)
	if perp.length_squared() < 1e-6:
		perp = dir_n.cross(Vector3.RIGHT)
	perp = perp.normalized() * head_len * ARROW_HEAD_PERP_FRACTION
	var back: Vector3 = p_to - dir_n * head_len
	_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_to)
	_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(back + perp)
	_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_to)
	_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(back - perp)


func _draw_cross(p_center: Vector3, p_half_extent: float, p_color: Color) -> void:
	for axis in [Vector3.RIGHT, Vector3.UP, Vector3.FORWARD]:
		_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_center + axis * p_half_extent)
		_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_center - axis * p_half_extent)


func _draw_sphere(p_center: Vector3, p_radius: float, p_color: Color) -> void:
	# Three orthogonal great circles — XY, XZ, YZ planes.
	var step: float = TAU / SPHERE_CIRCLE_SEGMENTS
	for i in SPHERE_CIRCLE_SEGMENTS:
		var a: float = i * step
		var b: float = (i + 1) * step
		# XY
		_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_center + Vector3(cos(a), sin(a), 0) * p_radius)
		_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_center + Vector3(cos(b), sin(b), 0) * p_radius)
		# XZ
		_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_center + Vector3(cos(a), 0, sin(a)) * p_radius)
		_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_center + Vector3(cos(b), 0, sin(b)) * p_radius)
		# YZ
		_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_center + Vector3(0, cos(a), sin(a)) * p_radius)
		_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_center + Vector3(0, cos(b), sin(b)) * p_radius)


func _draw_bending_arc(p_a: Vector3, p_b: Vector3, p_c: Vector3,
		p_radius: float, p_color: Color) -> void:
	# Arc from direction (a - b) to direction (c - b), centered at b, in the
	# plane defined by the triple. Skip near-collinear triples (arc would be
	# imperceptible anyway).
	var v1: Vector3 = p_a - p_b
	var v2: Vector3 = p_c - p_b
	var l1: float = v1.length()
	var l2: float = v2.length()
	if l1 < 1e-5 or l2 < 1e-5:
		return
	v1 /= l1
	v2 /= l2
	var dot: float = clampf(v1.dot(v2), -1.0, 1.0)
	# Skip nearly-straight (chain at rest pose, bend angle ≈ 180°) — the arc is
	# a line, redundant with the distance segments.
	if dot < -0.999:
		return
	for i in BENDING_ARC_SEGMENTS:
		var t1: float = float(i) / float(BENDING_ARC_SEGMENTS)
		var t2: float = float(i + 1) / float(BENDING_ARC_SEGMENTS)
		var p1: Vector3 = p_b + v1.slerp(v2, t1) * p_radius
		var p2: Vector3 = p_b + v1.slerp(v2, t2) * p_radius
		_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p1)
		_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p2)
