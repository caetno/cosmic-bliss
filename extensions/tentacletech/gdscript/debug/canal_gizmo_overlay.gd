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
## 5F.A — live PBD centerline chain. Draws magenta dots at each
## solver particle, segment-stretch colored bars between adjacent
## particles (green at rest length, red at 110% stretch), and cyan
## bending-residual vectors at interior particles. Falls back to
## rest positions when `canal.has_centerline_chain()` is false.
@export var show_centerline: bool = true
## 5F.B.B — per-cell wall displacement (dynamic_wall_radius − rest).
## Draws a dot at each cell's deformed-centerline world position + a
## short outward line whose length is proportional to the radial
## displacement (green for outward / red for inward). Falls back to a
## silent no-op when no integrator is attached.
@export var show_wall_displacement: bool = false
## 5F.B.C — type-3 canal-wall contact markers. Pulls per-substep
## contact log from `tentacle_for_wall_contacts.get_canal_wall_contacts_snapshot()`.
## Magenta cross at projected wall point; red line pre→post; cyan stub
## along contact normal. Silent no-op when tentacle is null.
@export var show_wall_contacts: bool = false
@export var tentacle_for_wall_contacts: Node3D
## §6.12.12 — canal-interior reaction pass markers. For each cross-
## section with non-zero reaction this frame, a magenta arrow at the
## cross-section's world position along the reaction vector. For each
## host bone that received an impulse, a cyan sphere at the load-
## weighted application point + a cyan arrow showing the impulse
## direction. Silent no-op when no reaction pass is attached.
@export var show_reaction_pass: bool = false
@export var spline_sample_count: int = 64
@export var cell_marker_size: float = 0.005
@export var centerline_dot_size: float = 0.008
@export var bending_residual_scale: float = 5.0
## Visual gain on `dynamic_wall_radius − rest_radius`. Real radial
## displacements at default tunables sit in the mm range; bumping
## this to ~30 makes the displacement bars readable at a glance.
@export var wall_displacement_scale: float = 30.0
@export_range(1, 100, 1) var bake_validation_sample_every: int = 10

const _COLOR_SPLINE := Color(0.0, 1.0, 1.0)        # cyan
const _COLOR_CENTERLINE := Color(1.0, 0.0, 1.0)    # magenta
const _COLOR_CELLS := Color(0.0, 1.0, 0.4)         # green (slight cyan shift; avoids orange-yellow eats)
const _COLOR_BAKE := Color(0.3, 0.5, 1.0)          # blue
const _COLOR_BEND_RESIDUAL := Color(0.2, 1.0, 1.0) # cyan-bias (avoids the orange-yellow band)
const _COLOR_STRETCH_REST := Color(0.0, 1.0, 0.4)  # green at rest length
const _COLOR_STRETCH_MAX := Color(1.0, 0.2, 0.2)   # red at ≥110% rest length
const _COLOR_WALL_OUTWARD := Color(0.0, 1.0, 0.4)  # green: dyn > rest
const _COLOR_WALL_INWARD := Color(1.0, 0.2, 0.2)   # red: dyn < rest
const _COLOR_WALL_CONTACT := Color(1.0, 0.0, 1.0)  # magenta: type-3 hit
const _COLOR_WALL_PUSH := Color(1.0, 0.2, 0.2)     # red: pre→post
const _COLOR_WALL_NORMAL := Color(0.2, 1.0, 1.0)   # cyan: contact normal
const _WALL_CONTACT_DOT_SIZE := 0.006
const _WALL_NORMAL_LENGTH := 0.03
const _COLOR_REACTION_SECTION := Color(1.0, 0.0, 1.0)   # magenta: per-section reaction
const _COLOR_REACTION_BONE := Color(0.2, 1.0, 1.0)      # cyan: per-bone impulse + application
const _REACTION_SECTION_SCALE := 50.0
const _REACTION_BONE_SCALE := 100.0
const _REACTION_APPLICATION_SIZE := 0.012

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
	# When a live PBD chain is present and the show_centerline toggle is
	# on, particles move continuously — the cached signature path would
	# leave the gizmo frozen. Force a per-frame rebuild for those cases.
	# Static-only renders still gate on the signature so an idle scene
	# pays nothing.
	var live_chain: bool = show_centerline and canal.has_method("has_centerline_chain") \
			and canal.has_centerline_chain()
	var live_walls: bool = show_wall_displacement and canal.has_method("has_tunnel_state_integrator") \
			and canal.has_tunnel_state_integrator()
	var live_contacts: bool = show_wall_contacts and tentacle_for_wall_contacts != null \
			and tentacle_for_wall_contacts.has_method("get_canal_wall_contacts_snapshot")
	var live_reaction: bool = show_reaction_pass and canal.has_method("has_reaction_pass") \
			and canal.has_reaction_pass()
	if live_chain or live_walls or live_contacts or live_reaction:
		_rebuild()
		return
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

	# 5F.A — live PBD chain (preferred when present). Otherwise fall
	# back to drawing the baked rest positions (5E behavior).
	var live_drawn := false
	if show_centerline and canal.has_method("has_centerline_chain") \
			and canal.has_centerline_chain():
		_draw_live_centerline()
		live_drawn = true

	if show_centerline_rest and not live_drawn:
		var rest_positions: PackedVector3Array = canal.call("get_baked_centerline_rest_positions")
		for p in rest_positions:
			_draw_cross(p, centerline_dot_size, _COLOR_CENTERLINE)

	if show_cell_grid:
		_draw_cell_grid(spline)

	if show_bake_validation and mesh_instance != null:
		_draw_bake_validation(spline)

	if show_wall_displacement and canal.has_method("has_tunnel_state_integrator") \
			and canal.has_tunnel_state_integrator():
		_draw_wall_displacement(spline)

	if show_wall_contacts and tentacle_for_wall_contacts != null \
			and tentacle_for_wall_contacts.has_method("get_canal_wall_contacts_snapshot"):
		_draw_wall_contacts()

	if show_reaction_pass and canal.has_method("has_reaction_pass") \
			and canal.has_reaction_pass():
		_draw_reaction_pass(spline)


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


# 5F.A — Live centerline chain visualisation:
#   * Magenta cross at each live particle position.
#   * Segment-stretch coloured bars between adjacent particles
#     (green at rest length, lerping to red at ≥110% rest).
#   * Cyan bending-residual vector at each interior particle,
#     pointing from current position toward the ideal midpoint
#     between neighbours, scaled by `bending_residual_scale` for
#     visibility (the actual residuals are typically sub-mm at rest).
func _draw_live_centerline() -> void:
	var positions: PackedVector3Array = canal.get_centerline_positions_snapshot()
	var rest_positions: PackedVector3Array = canal.call("get_baked_centerline_rest_positions")
	var n := positions.size()
	if n == 0:
		return

	# Magenta crosses at live particles.
	for p in positions:
		_draw_cross(p, centerline_dot_size, _COLOR_CENTERLINE)

	# Segment stretch bars. Rest segment length is reconstructed from
	# the baked rest positions; with M particles this is M-1 values.
	# Mismatched array lengths (re-bake mid-frame) fall back to
	# straight-line magenta.
	var have_rest := rest_positions.size() == n
	_im.surface_begin(Mesh.PRIMITIVE_LINES, _mat)
	for i in range(n - 1):
		var seg := positions[i + 1] - positions[i]
		var len := seg.length()
		var col := _COLOR_CENTERLINE
		if have_rest:
			var rest_seg: float = (rest_positions[i + 1] - rest_positions[i]).length()
			if rest_seg > 1e-9:
				# Map stretch ratio [1.0, 1.1] -> [green, red].
				var ratio: float = clampf((len / rest_seg - 1.0) / 0.1, 0.0, 1.0)
				col = _COLOR_STRETCH_REST.lerp(_COLOR_STRETCH_MAX, ratio)
		_im.surface_set_color(col)
		_im.surface_add_vertex(positions[i])
		_im.surface_set_color(col)
		_im.surface_add_vertex(positions[i + 1])
	_im.surface_end()

	# Bending residuals at interior particles. Direction = (target -
	# current) where target is the linear-interp midpoint between
	# neighbours at fraction L_ab/(L_ab+L_bc). Length scaled for
	# visibility.
	if n >= 3:
		_im.surface_begin(Mesh.PRIMITIVE_LINES, _mat)
		for i in range(1, n - 1):
			var a := positions[i - 1]
			var b := positions[i]
			var c := positions[i + 1]
			var frac := 0.5
			if have_rest:
				var l_ab: float = (rest_positions[i] - rest_positions[i - 1]).length()
				var l_bc: float = (rest_positions[i + 1] - rest_positions[i]).length()
				var total := l_ab + l_bc
				if total > 1e-9:
					frac = l_ab / total
			var target := a + (c - a) * frac
			var residual := (target - b) * bending_residual_scale
			_im.surface_set_color(_COLOR_BEND_RESIDUAL)
			_im.surface_add_vertex(b)
			_im.surface_set_color(_COLOR_BEND_RESIDUAL)
			_im.surface_add_vertex(b + residual)
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


# 5F.B.B — Per-cell wall displacement overlay. For each (k, j):
#   * Anchor point = cell's world position at REST radius along the
#     DEFORMED centerline (so the overlay tracks centerline bend).
#   * Outward line of length `(dyn − rest) × wall_displacement_scale`,
#     coloured green when positive (wall pushed outward) or red when
#     negative (wall contracted inward).
# Falls back to the rest-pose spline when no live centerline exists —
# rare in practice (the integrator and chain ship together) but keeps
# the path defensible if a future scene leaves the chain disabled.
func _draw_wall_displacement(p_spline: RefCounted) -> void:
	if canal == null:
		return
	var params: CanalParameters = canal.canal_parameters
	if params == null:
		return
	var rest_radius: PackedFloat32Array = canal.get_baked_rest_radius_per_cell()
	var dyn_radius: PackedFloat32Array = canal.get_dynamic_wall_radius_snapshot()
	var axial: int = params.canal_axial_segments
	var sectors: int = params.canal_angular_sectors
	if rest_radius.size() != axial * sectors:
		return
	if dyn_radius.size() != axial * sectors:
		return

	var have_live_chain: bool = canal.has_method("has_centerline_chain") \
			and canal.has_centerline_chain()
	var chain: RefCounted = canal.get_centerline_chain() if have_live_chain else null
	var total_arc: float = 0.0
	if chain != null:
		total_arc = chain.get_total_arc_length()
	var spline_arc: float = p_spline.get_arc_length()

	_im.surface_begin(Mesh.PRIMITIVE_LINES, _mat)
	for k in axial:
		var s_norm := float(k) / maxf(float(axial - 1), 1.0)
		var origin: Vector3
		var normal: Vector3
		var binormal: Vector3
		if chain != null and total_arc > 1e-9:
			var s := s_norm * total_arc
			origin = chain.evaluate_at(s)
			var b: Basis = chain.basis_at(s)
			# basis_at returns columns (tangent, normal, binormal) — match
			# _project_onto_spline / _draw_cell_grid convention. In GDScript
			# `Basis.get_column(i)` isn't bound; use `.x` `.y` `.z` instead
			# (see reference_godot_tentacletech_gotchas memory).
			normal = b.y.normalized()
			binormal = b.z.normalized()
		else:
			var s := s_norm * spline_arc
			var t: float = p_spline.distance_to_parameter(s)
			origin = p_spline.evaluate_position(t)
			var frame: Dictionary = p_spline.evaluate_frame(t)
			normal = (frame["normal"] as Vector3).normalized()
			binormal = (frame["binormal"] as Vector3).normalized()
		for j in sectors:
			var theta := TAU * float(j) / float(sectors)
			var outward := normal * cos(theta) + binormal * sin(theta)
			var rest_r: float = rest_radius[k * sectors + j]
			var dyn_r: float = dyn_radius[k * sectors + j]
			var anchor := origin + outward * rest_r
			var disp := (dyn_r - rest_r) * wall_displacement_scale
			var col := _COLOR_WALL_OUTWARD if disp >= 0.0 else _COLOR_WALL_INWARD
			_im.surface_set_color(col)
			_im.surface_add_vertex(anchor)
			_im.surface_set_color(col)
			_im.surface_add_vertex(anchor + outward * disp)
	_im.surface_end()


# 5F.B.C — Per-substep type-3 canal-wall contact markers.
#   * Magenta cross at the projected wall point.
#   * Red line from particle pre→post projection (depenetration vector).
#   * Cyan stub along the contact normal.
func _draw_wall_contacts() -> void:
	if tentacle_for_wall_contacts == null:
		return
	var contacts: Array = tentacle_for_wall_contacts.get_canal_wall_contacts_snapshot()
	if contacts.is_empty():
		return
	_im.surface_begin(Mesh.PRIMITIVE_LINES, _mat)
	for c in contacts:
		var pre: Vector3 = c.get("pre_projection_world_pos", Vector3.ZERO)
		var post: Vector3 = c.get("contact_world_pos", Vector3.ZERO)
		_im.surface_set_color(_COLOR_WALL_PUSH)
		_im.surface_add_vertex(pre)
		_im.surface_set_color(_COLOR_WALL_PUSH)
		_im.surface_add_vertex(post)
	_im.surface_end()
	for c in contacts:
		var post: Vector3 = c.get("contact_world_pos", Vector3.ZERO)
		_draw_cross(post, _WALL_CONTACT_DOT_SIZE, _COLOR_WALL_CONTACT)
	_im.surface_begin(Mesh.PRIMITIVE_LINES, _mat)
	for c in contacts:
		var post: Vector3 = c.get("contact_world_pos", Vector3.ZERO)
		var n: Vector3 = c.get("contact_normal", Vector3.UP)
		_im.surface_set_color(_COLOR_WALL_NORMAL)
		_im.surface_add_vertex(post)
		_im.surface_set_color(_COLOR_WALL_NORMAL)
		_im.surface_add_vertex(post + n * _WALL_NORMAL_LENGTH)
	_im.surface_end()


# §6.12.12 — Reaction-pass visualisation.
#   * Magenta arrow at each cross-section's deformed world position
#     pointing along the per-section reaction vector
#     (length = `reaction × _REACTION_SECTION_SCALE`). Skipped when the
#     reaction magnitude is below the dispatch epsilon.
#   * Cyan cross at each host-bone application point + a cyan arrow
#     pointing along the bone impulse direction
#     (length = `impulse × _REACTION_BONE_SCALE`).
func _draw_reaction_pass(p_spline: RefCounted) -> void:
	if canal == null:
		return
	var params: CanalParameters = canal.canal_parameters
	if params == null:
		return
	var reactions: PackedVector3Array = canal.get_last_reaction_per_section_snapshot()
	if reactions.is_empty():
		return
	var axial: int = params.canal_axial_segments
	if reactions.size() != axial:
		return

	var have_live_chain: bool = canal.has_method("has_centerline_chain") \
			and canal.has_centerline_chain()
	var chain: RefCounted = canal.get_centerline_chain() if have_live_chain else null
	var total_arc: float = 0.0
	if chain != null:
		total_arc = chain.get_total_arc_length()
	var spline_arc: float = p_spline.get_arc_length()

	_im.surface_begin(Mesh.PRIMITIVE_LINES, _mat)
	for k in axial:
		var r: Vector3 = reactions[k]
		if r.length() < 1e-6:
			continue
		var s_norm := float(k) / maxf(float(axial - 1), 1.0)
		var origin: Vector3
		if chain != null and total_arc > 1e-9:
			origin = chain.evaluate_at(s_norm * total_arc)
		else:
			var t: float = p_spline.distance_to_parameter(s_norm * spline_arc)
			origin = p_spline.evaluate_position(t)
		_im.surface_set_color(_COLOR_REACTION_SECTION)
		_im.surface_add_vertex(origin)
		_im.surface_set_color(_COLOR_REACTION_SECTION)
		_im.surface_add_vertex(origin + r * _REACTION_SECTION_SCALE)
	_im.surface_end()

	var impulses: PackedVector3Array = canal.get_last_bone_impulse_snapshot()
	var application_points: PackedVector3Array = canal.get_last_application_points_snapshot()
	var bone_count: int = mini(impulses.size(), application_points.size())
	for b in bone_count:
		_draw_cross(application_points[b], _REACTION_APPLICATION_SIZE, _COLOR_REACTION_BONE)
	_im.surface_begin(Mesh.PRIMITIVE_LINES, _mat)
	for b in bone_count:
		var imp: Vector3 = impulses[b]
		var ap: Vector3 = application_points[b]
		_im.surface_set_color(_COLOR_REACTION_BONE)
		_im.surface_add_vertex(ap)
		_im.surface_set_color(_COLOR_REACTION_BONE)
		_im.surface_add_vertex(ap + imp * _REACTION_BONE_SCALE)
	_im.surface_end()
