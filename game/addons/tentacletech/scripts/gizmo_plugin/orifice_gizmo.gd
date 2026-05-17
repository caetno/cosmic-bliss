@tool
extends EditorNode3DGizmoPlugin
## §15.5 Orifice gizmo — selection-time editor visualization + handles
## for `OrificeBuilder`.
##
## Draws the rim ring as line segments + particle dots; provides two
## drag handles:
##   * **Handle 0 (radius)** — slides in the rim plane to set
##     `OrificeBuilder.rim_radius`. Screen-ray intersected with the rim
##     plane; distance from `rim_center_offset` = new radius.
##   * **Handle 1 (axial offset)** — slides along `rim_axis` to set
##     `OrificeBuilder.rim_center_offset` along the axial direction.
##     Screen ray closest-point on axis line.
##
## Undo/redo wires through the parent `EditorPlugin`'s `get_undo_redo()`
## reference, passed at construction.
##
## Pull, never push — the C++ `Orifice` doesn't know this gizmo
## exists. The gizmo writes ONLY to the `OrificeBuilder` wrapper's
## inspector properties.

const _OrificeBuilderScript := preload("res://addons/tentacletech/scripts/orifice/orifice_builder.gd")

const MAT_RING := "orifice_ring"
const MAT_PARTICLE := "orifice_particle"
const MAT_AXIS := "orifice_axis"
const MAT_HANDLE := "orifice_handle"

const RING_COLOR := Color(0.9, 0.4, 0.9)         # magenta (CMY palette)
const PARTICLE_COLOR := Color(0.4, 0.9, 0.9)     # cyan
const AXIS_COLOR := Color(0.9, 0.9, 0.4) * Color(0.7, 0.7, 1.0)  # cool-shifted (avoid pure yellow)
const PARTICLE_DOT_SIZE := 0.01

const HANDLE_RADIUS_ID := 0
const HANDLE_AXIAL_ID := 1

const RADIUS_MIN := 0.005
const RADIUS_MAX := 1.0
const AXIAL_MIN := -1.0
const AXIAL_MAX := 1.0

var _undo_redo: EditorUndoRedoManager = null


func _init(p_undo_redo: EditorUndoRedoManager = null) -> void:
	_undo_redo = p_undo_redo
	create_material(MAT_RING, RING_COLOR)
	create_material(MAT_PARTICLE, PARTICLE_COLOR)
	create_material(MAT_AXIS, AXIS_COLOR)
	create_handle_material(MAT_HANDLE)


func _get_gizmo_name() -> String:
	return "OrificeBuilder"


func _has_gizmo(p_node: Node3D) -> bool:
	return p_node != null and p_node.get_script() == _OrificeBuilderScript


# ─── Redraw ────────────────────────────────────────────────────────


func _redraw(p_gizmo: EditorNode3DGizmo) -> void:
	p_gizmo.clear()
	var node: Node3D = p_gizmo.get_node_3d()
	if node == null:
		return
	if not node.has_method("compute_rim_positions_local"):
		return
	if not bool(node.get("preview_enabled")):
		return

	var positions: PackedVector3Array = node.call("compute_rim_positions_local")
	if positions.size() < 3:
		return

	_draw_ring(p_gizmo, positions)
	_draw_particles(p_gizmo, positions)
	_draw_axis(p_gizmo, node)
	_draw_handles(p_gizmo, node)


func _draw_ring(p_gizmo: EditorNode3DGizmo, p_positions: PackedVector3Array) -> void:
	var lines := PackedVector3Array()
	var n := p_positions.size()
	for i in n:
		lines.append(p_positions[i])
		lines.append(p_positions[(i + 1) % n])
	if not lines.is_empty():
		p_gizmo.add_lines(lines, get_material(MAT_RING, p_gizmo))


func _draw_particles(p_gizmo: EditorNode3DGizmo, p_positions: PackedVector3Array) -> void:
	# Three orthogonal crosses per particle — small dots in 3D.
	var lines := PackedVector3Array()
	var half := PARTICLE_DOT_SIZE * 0.5
	for p in p_positions:
		lines.append(p + Vector3(half, 0, 0)); lines.append(p - Vector3(half, 0, 0))
		lines.append(p + Vector3(0, half, 0)); lines.append(p - Vector3(0, half, 0))
		lines.append(p + Vector3(0, 0, half)); lines.append(p - Vector3(0, 0, half))
	if not lines.is_empty():
		p_gizmo.add_lines(lines, get_material(MAT_PARTICLE, p_gizmo))


func _draw_axis(p_gizmo: EditorNode3DGizmo, p_node: Node3D) -> void:
	# Short arrow along rim_axis, from center_offset outward by 1.5× radius.
	var center: Vector3 = p_node.get("rim_center_offset")
	var axis: Vector3 = (p_node.get("rim_axis") as Vector3).normalized()
	var radius: float = float(p_node.get("rim_radius"))
	var tip := center + axis * (radius * 1.5)
	var lines := PackedVector3Array([center, tip])
	# Cross at tip for visibility.
	var basis: Dictionary = _rim_plane_basis(axis)
	var x: Vector3 = basis["x"]
	var y: Vector3 = basis["y"]
	var cross_len := radius * 0.15
	lines.append(tip + x * cross_len); lines.append(tip - x * cross_len)
	lines.append(tip + y * cross_len); lines.append(tip - y * cross_len)
	p_gizmo.add_lines(lines, get_material(MAT_AXIS, p_gizmo))


func _draw_handles(p_gizmo: EditorNode3DGizmo, p_node: Node3D) -> void:
	var center: Vector3 = p_node.get("rim_center_offset")
	var axis: Vector3 = (p_node.get("rim_axis") as Vector3).normalized()
	var radius: float = float(p_node.get("rim_radius"))

	# Handle positions in node-local space (gizmo handles are local).
	var basis: Dictionary = _rim_plane_basis(axis)
	var radius_handle_pos: Vector3 = center + (basis["x"] as Vector3) * radius
	var axial_handle_pos: Vector3 = center + axis * (radius * 1.5)
	var handles := PackedVector3Array([radius_handle_pos, axial_handle_pos])
	var handle_ids := PackedInt32Array([HANDLE_RADIUS_ID, HANDLE_AXIAL_ID])
	p_gizmo.add_handles(handles, get_material(MAT_HANDLE, p_gizmo), handle_ids)


# ─── Handle interaction ────────────────────────────────────────────


func _get_handle_name(p_gizmo: EditorNode3DGizmo, p_id: int, _p_secondary: bool) -> String:
	match p_id:
		HANDLE_RADIUS_ID: return "Rim radius"
		HANDLE_AXIAL_ID: return "Center offset (axial)"
		_: return ""


func _get_handle_value(p_gizmo: EditorNode3DGizmo, p_id: int, _p_secondary: bool) -> Variant:
	var node: Node3D = p_gizmo.get_node_3d()
	if node == null:
		return null
	match p_id:
		HANDLE_RADIUS_ID:
			return float(node.get("rim_radius"))
		HANDLE_AXIAL_ID:
			# Axial offset = component of rim_center_offset along rim_axis.
			var center: Vector3 = node.get("rim_center_offset")
			var axis: Vector3 = (node.get("rim_axis") as Vector3).normalized()
			return center.dot(axis)
	return null


func _set_handle(p_gizmo: EditorNode3DGizmo, p_id: int, _p_secondary: bool,
		p_camera: Camera3D, p_screen_point: Vector2) -> void:
	var node: Node3D = p_gizmo.get_node_3d()
	if node == null:
		return

	# Build a ray from the camera through the screen point in world space.
	var ray_origin: Vector3 = p_camera.project_ray_origin(p_screen_point)
	var ray_dir: Vector3 = p_camera.project_ray_normal(p_screen_point)

	# Convert to node-local space for the math below.
	var node_xform: Transform3D = node.global_transform
	var inv: Transform3D = node_xform.affine_inverse()
	var local_origin: Vector3 = inv * ray_origin
	var local_dir: Vector3 = inv.basis * ray_dir
	if local_dir.length_squared() < 1e-12:
		return
	local_dir = local_dir.normalized()

	var center: Vector3 = node.get("rim_center_offset")
	var axis: Vector3 = (node.get("rim_axis") as Vector3).normalized()

	match p_id:
		HANDLE_RADIUS_ID:
			# Intersect ray with the rim plane (passes through `center`,
			# normal `axis`). Distance from center to hit = new radius.
			var hit := _ray_plane_intersect(local_origin, local_dir, center, axis)
			if hit == null:
				return
			var offset: Vector3 = (hit as Vector3) - center
			var new_radius: float = offset.length()
			new_radius = clampf(new_radius, RADIUS_MIN, RADIUS_MAX)
			node.set("rim_radius", new_radius)

		HANDLE_AXIAL_ID:
			# Closest point on the axis line (passing through current
			# `center` along `axis`) to the camera ray.
			var t := _ray_line_closest_t(local_origin, local_dir, center, axis)
			if is_nan(t):
				return
			# New axial offset = projection of (center_offset_along_axis + t) onto axis.
			# Simpler: compute the new center as center + axis × delta,
			# where delta = (t - current_axial_t).
			var current_axial: float = center.dot(axis)
			var new_axial: float = clampf(t, AXIAL_MIN, AXIAL_MAX)
			# Replace only the axial component; preserve perpendicular offset.
			var perp: Vector3 = center - axis * current_axial
			node.set("rim_center_offset", perp + axis * new_axial)


func _commit_handle(p_gizmo: EditorNode3DGizmo, p_id: int, _p_secondary: bool,
		p_restore: Variant, p_cancel: bool) -> void:
	var node: Node3D = p_gizmo.get_node_3d()
	if node == null:
		return

	if p_cancel:
		# Restore the previous value.
		match p_id:
			HANDLE_RADIUS_ID:
				node.set("rim_radius", float(p_restore))
			HANDLE_AXIAL_ID:
				var axis: Vector3 = (node.get("rim_axis") as Vector3).normalized()
				var center: Vector3 = node.get("rim_center_offset")
				var current_axial: float = center.dot(axis)
				var perp: Vector3 = center - axis * current_axial
				node.set("rim_center_offset", perp + axis * float(p_restore))
		return

	if _undo_redo == null:
		# No undo/redo manager — just leave the new value as-is.
		return

	match p_id:
		HANDLE_RADIUS_ID:
			var new_val := float(node.get("rim_radius"))
			_undo_redo.create_action("Set Rim Radius")
			_undo_redo.add_do_property(node, "rim_radius", new_val)
			_undo_redo.add_undo_property(node, "rim_radius", float(p_restore))
			_undo_redo.commit_action()
		HANDLE_AXIAL_ID:
			# We mutate rim_center_offset as a whole vector; restore the
			# full offset on undo. The `restore` Variant is the axial
			# scalar — reconstruct the perpendicular component the same
			# way `_set_handle` did.
			var axis: Vector3 = (node.get("rim_axis") as Vector3).normalized()
			var new_center: Vector3 = node.get("rim_center_offset")
			var new_axial: float = new_center.dot(axis)
			var perp: Vector3 = new_center - axis * new_axial
			var old_center: Vector3 = perp + axis * float(p_restore)
			_undo_redo.create_action("Set Rim Axial Offset")
			_undo_redo.add_do_property(node, "rim_center_offset", new_center)
			_undo_redo.add_undo_property(node, "rim_center_offset", old_center)
			_undo_redo.commit_action()


# ─── Math helpers ──────────────────────────────────────────────────


## Returns the intersection of a ray (origin, dir) with a plane
## (point, normal). Returns `null` if the ray is parallel to the plane
## or the hit is behind the origin.
static func _ray_plane_intersect(p_origin: Vector3, p_dir: Vector3,
		p_plane_pt: Vector3, p_plane_n: Vector3) -> Variant:
	var denom := p_plane_n.dot(p_dir)
	if absf(denom) < 1e-8:
		return null
	var t := p_plane_n.dot(p_plane_pt - p_origin) / denom
	if t < 0.0:
		return null
	return p_origin + p_dir * t


## Returns the parameter t along axis line (line_origin + axis * t)
## that's closest to the given ray. Returns NAN on degeneracy.
static func _ray_line_closest_t(p_ray_origin: Vector3, p_ray_dir: Vector3,
		p_line_origin: Vector3, p_line_dir: Vector3) -> float:
	# Closest-points-between-two-lines, returning t on the SECOND line.
	# Standard formula: see "shortest distance between two skew lines".
	var u := p_ray_dir.normalized()
	var v := p_line_dir.normalized()
	var w0 := p_ray_origin - p_line_origin
	var a := u.dot(u)
	var b := u.dot(v)
	var c := v.dot(v)
	var d := u.dot(w0)
	var e := v.dot(w0)
	var denom := a * c - b * b
	if denom < 1e-12:
		return NAN
	# var s := (b * e - c * d) / denom  # along the ray; unused
	var t := (a * e - b * d) / denom
	return t


static func _rim_plane_basis(p_axis: Vector3) -> Dictionary:
	var z := p_axis.normalized()
	var ref := Vector3.RIGHT if absf(z.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var x := ref.cross(z).normalized()
	var y := z.cross(x).normalized()
	return {"x": x, "y": y, "z": z}
