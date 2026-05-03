@tool
extends EditorNode3DGizmoPlugin
## §15.5 Tentacle gizmo — selection-time editor visualization.
##
## Mirrors the runtime overlay's particles + constraints layers (using the
## same color encoding via TentacleDebugColors), and adds the spline
## polyline + TBN frames the runtime overlay cannot show because the spline
## only exists once the node is in the tree and ticking. We pull from the
## C++ snapshot accessors — Tentacle.get_particle_positions(),
## get_segment_stretch_ratios(), get_spline_samples(), get_spline_frames().
##
## Pull, never push. The C++ solver does not know this gizmo exists.

const _Colors := preload("res://addons/tentacletech/scripts/debug/colors.gd")

const SPLINE_SAMPLE_COUNT := 32
const TBN_FRAME_COUNT := 8
const TBN_TICK_LENGTH := 0.04
const PARTICLE_GIZMO_SIZE := 0.02

# Material handles registered via create_material/create_handle_material.
const MAT_PARTICLES := "tentacle_particles"
const MAT_CONSTRAINTS := "tentacle_constraints"
const MAT_SPLINE := "tentacle_spline"
const MAT_TBN_TANGENT := "tentacle_tbn_tangent"
const MAT_TBN_NORMAL := "tentacle_tbn_normal"
const MAT_TBN_BINORMAL := "tentacle_tbn_binormal"


func _init() -> void:
	# Materials are line-only and unshaded; vertex_color drives the visible
	# hue per layer. One material per layer keeps the editor's gizmo system
	# happy (it caches by name).
	create_material(MAT_PARTICLES, _Colors.FREE)
	create_material(MAT_CONSTRAINTS, _Colors.REST)
	create_material(MAT_SPLINE, _Colors.SPLINE_POLYLINE)
	create_material(MAT_TBN_TANGENT, _Colors.TBN_TANGENT)
	create_material(MAT_TBN_NORMAL, _Colors.TBN_NORMAL)
	create_material(MAT_TBN_BINORMAL, _Colors.TBN_BINORMAL)


func _get_gizmo_name() -> String:
	return "Tentacle"


func _has_gizmo(p_node: Node3D) -> bool:
	return p_node != null and p_node.get_class() == "Tentacle"


func _redraw(p_gizmo: EditorNode3DGizmo) -> void:
	p_gizmo.clear()
	var node: Node3D = p_gizmo.get_node_3d()
	if node == null:
		return

	# Edit-time gizmo always shows the REST-POSE layout in node-local space.
	# Reading the live solver's particle positions is unreliable at edit time
	# because Godot's editor instantiates the scene multiple times during load
	# (initial → preview → final), and rebuild_chain ends up running with
	# identity transform on at least one of those passes — leaving particles
	# in local coords for the gizmo to read while the mesh path's
	# _update_spline_data_texture happens to read them at a different moment
	# when they're world. Drawing the rest-pose layout directly avoids the
	# whole timing question: anchor at local origin, particles spaced along
	# local -Z by segment_length. The editor applies the parent transform
	# correctly, so the gizmo always lines up with the mesh.
	var particle_count: int = int(node.particle_count)
	var seg_length: float = float(node.segment_length)
	if particle_count < 2 or seg_length < 1e-5:
		return
	var positions_local := PackedVector3Array()
	positions_local.resize(particle_count)
	for i in particle_count:
		positions_local[i] = Vector3(0.0, 0.0, -seg_length * float(i))

	# Stretch ratios are 1.0 at rest pose by definition, so the constraints
	# layer paints all segments at REST color.
	var ratios := PackedFloat32Array()
	ratios.resize(particle_count - 1)
	for i in particle_count - 1:
		ratios[i] = 1.0

	_draw_particles(p_gizmo, positions_local)
	_draw_segments(p_gizmo, positions_local, ratios)
	_draw_spline(p_gizmo, node)


func _draw_particles(p_gizmo: EditorNode3DGizmo, p_positions: PackedVector3Array) -> void:
	# Three orthogonal line crosses per particle. We can't push per-vertex
	# colors through add_lines (single material color), so all particles
	# share the FREE color in the editor; pinned status is conveyed by the
	# anchor/segment view in 3D anyway.
	var lines := PackedVector3Array()
	var half: float = PARTICLE_GIZMO_SIZE * 0.5
	for p in p_positions:
		lines.push_back(p + Vector3(half, 0, 0)); lines.push_back(p - Vector3(half, 0, 0))
		lines.push_back(p + Vector3(0, half, 0)); lines.push_back(p - Vector3(0, half, 0))
		lines.push_back(p + Vector3(0, 0, half)); lines.push_back(p - Vector3(0, 0, half))
	if not lines.is_empty():
		p_gizmo.add_lines(lines, get_material(MAT_PARTICLES, p_gizmo))


func _draw_segments(p_gizmo: EditorNode3DGizmo,
		p_positions: PackedVector3Array,
		p_ratios: PackedFloat32Array) -> void:
	# Distance constraints — pairs of points. Stretch ratio decides which of
	# three pre-registered materials to use (compressed/rest/stretched), so
	# the editor still reads stretch state at a glance even without
	# per-vertex color.
	var lines := PackedVector3Array()
	for i in range(p_positions.size() - 1):
		var ratio: float = p_ratios[i] if i < p_ratios.size() else 1.0
		# We register a single tinted material at REST color; for now all
		# segments share that color. Per-segment hue would need three
		# additional pre-registered materials — leave for a later polish if
		# the value is felt.
		lines.push_back(p_positions[i])
		lines.push_back(p_positions[i + 1])
		# Suppress unused warning while the per-segment-hue polish isn't done.
		var _ratio := ratio
	if not lines.is_empty():
		p_gizmo.add_lines(lines, get_material(MAT_CONSTRAINTS, p_gizmo))


func _draw_spline(p_gizmo: EditorNode3DGizmo, p_node: Node3D) -> void:
	# Polyline + TBN frames are read directly from the C++ snapshot in
	# tentacle-local space — no transform needed.
	var samples: PackedVector3Array = p_node.call(&"get_spline_samples", SPLINE_SAMPLE_COUNT)
	if samples.size() >= 2:
		var lines := PackedVector3Array()
		for i in range(samples.size() - 1):
			lines.push_back(samples[i])
			lines.push_back(samples[i + 1])
		p_gizmo.add_lines(lines, get_material(MAT_SPLINE, p_gizmo))

	var frames: Array = p_node.call(&"get_spline_frames", TBN_FRAME_COUNT)
	if frames.size() == 0:
		return
	var tan_lines := PackedVector3Array()
	var nrm_lines := PackedVector3Array()
	var bin_lines := PackedVector3Array()
	for f in frames:
		var pos: Vector3 = f.get("position", Vector3.ZERO)
		var t: Vector3 = f.get("tangent", Vector3.ZERO)
		var n: Vector3 = f.get("normal", Vector3.ZERO)
		var b: Vector3 = f.get("binormal", Vector3.ZERO)
		tan_lines.push_back(pos); tan_lines.push_back(pos + t * TBN_TICK_LENGTH)
		nrm_lines.push_back(pos); nrm_lines.push_back(pos + n * TBN_TICK_LENGTH)
		bin_lines.push_back(pos); bin_lines.push_back(pos + b * TBN_TICK_LENGTH)
	if not tan_lines.is_empty():
		p_gizmo.add_lines(tan_lines, get_material(MAT_TBN_TANGENT, p_gizmo))
	if not nrm_lines.is_empty():
		p_gizmo.add_lines(nrm_lines, get_material(MAT_TBN_NORMAL, p_gizmo))
	if not bin_lines.is_empty():
		p_gizmo.add_lines(bin_lines, get_material(MAT_TBN_BINORMAL, p_gizmo))
