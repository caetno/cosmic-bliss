@tool
class_name OrificeBuilder
extends Node3D

## Visual authoring wrapper for `Orifice`. The user drops one of these
## into the scene under the hero root, configures rim shape from the
## inspector, and sees the ring in the editor viewport via the
## `OrificeGizmoPlugin` (§15.5 — TentacleTech editor gizmos).
##
## At play-mode `_ready` the wrapper instantiates a child `Orifice` C++
## node, forwards properties (host bone, profile), and calls
## `OrificeAuthoring.add_circular_rim` / `add_polygon_rim` to build the
## XPBD rim. Canal subscribers see the inner Orifice via
## `get_orifice()` OR can subscribe to this wrapper directly — EI
## lifecycle signals are forwarded.
##
## This is a stand-in until body_field's `RimRingPrimitive` gizmo
## ships per `docs/Cosmic_Bliss_Update_2026-05-13_gizmo_primitive_authoring.md` §5(b).
## Once that lands, `OrificeBuilder` becomes a migration shim that
## reads the primitive resource instead of inline exports.

const _OrificeAuthoring := preload("res://addons/tentacletech/scripts/orifice/orifice_authoring.gd")

enum ShapeMode { CIRCLE, SLIT, POLYGON_CUSTOM }

# ─── Rim shape authoring ───────────────────────────────────────────

@export var shape_mode: ShapeMode = ShapeMode.CIRCLE :
	set(value):
		shape_mode = value
		update_gizmos()

## Circle / slit radius. For slit mode this is the LONG-axis half-extent.
@export_range(0.005, 0.5, 0.001, "or_greater") var rim_radius: float = 0.05 :
	set(value):
		rim_radius = value
		update_gizmos()

@export_range(3, 32, 1) var rim_particle_count: int = 8 :
	set(value):
		rim_particle_count = clampi(value, 3, 64)
		update_gizmos()

## Offset of the ring's center from the OrificeBuilder's own transform
## origin. In OrificeBuilder local frame.
@export var rim_center_offset: Vector3 = Vector3.ZERO :
	set(value):
		rim_center_offset = value
		update_gizmos()

## Normal of the rim plane in OrificeBuilder local frame. Particles are
## placed in the plane perpendicular to this. Default +Y matches the
## §6.1 convention "Z along the opening axis" if the builder is
## oriented with its local Z forward (Godot default).
@export var rim_axis: Vector3 = Vector3(0.0, 0.0, 1.0) :
	set(value):
		rim_axis = value.normalized() if value.length_squared() > 1e-8 else Vector3.FORWARD
		update_gizmos()

## SLIT mode only: short-axis / long-axis ratio. 1.0 == circle.
@export_range(0.1, 1.0, 0.05) var slit_aspect_ratio: float = 0.5 :
	set(value):
		slit_aspect_ratio = clampf(value, 0.05, 1.0)
		update_gizmos()

## POLYGON_CUSTOM mode only. Positions in OrificeBuilder local frame.
@export var custom_positions: PackedVector3Array = PackedVector3Array() :
	set(value):
		custom_positions = value
		update_gizmos()

# ─── Physics tuning (passed through to add_rim_loop) ────────────────

@export_group("Physics")
@export_range(0.0, 1.0, 0.01) var rest_stiffness: float = 0.5
@export_exp_easing var area_compliance: float = 1e-4
@export_exp_easing var distance_compliance: float = 1e-6
@export var orifice_profile: Resource = null

# ─── Host bone forwarding ──────────────────────────────────────────

@export_group("Host body")
@export var skeleton_path: NodePath
@export var bone_name: StringName

# ─── Editor preview opacity ────────────────────────────────────────

@export_group("Editor preview")
@export var preview_enabled: bool = true :
	set(value):
		preview_enabled = value
		update_gizmos()

# ─── Lifecycle signals (forwarded from inner Orifice) ──────────────

signal entry_interaction_started(tentacle_object_id: int, tentacle_idx: int)
signal entry_interaction_ended(tentacle_object_id: int)

# ─── Internal state ────────────────────────────────────────────────

var _orifice: Node3D = null  # the inner Orifice C++ node (Node3D)


# ─── Public accessors ──────────────────────────────────────────────


## Returns the inner `Orifice` C++ node, or null in editor mode (the
## inner node only exists at play-mode `_ready`).
func get_orifice() -> Node3D:
	return _orifice


## Computes the rim particle positions in OrificeBuilder local space.
## Used by both `_build_rim_at_ready` and the gizmo plugin's
## `_redraw`. Pure function — same inputs → same output.
func compute_rim_positions_local() -> PackedVector3Array:
	match shape_mode:
		ShapeMode.CIRCLE:
			return _circle_positions(rim_particle_count, rim_radius)
		ShapeMode.SLIT:
			return _ellipse_positions(rim_particle_count, rim_radius,
					rim_radius * slit_aspect_ratio)
		ShapeMode.POLYGON_CUSTOM:
			return custom_positions
		_:
			return PackedVector3Array()


## Estimated polygon area for the current shape. Used at rim-build
## time as the XPBD volume constraint's `target_enclosed_area`.
func compute_target_area() -> float:
	match shape_mode:
		ShapeMode.CIRCLE:
			return PI * rim_radius * rim_radius
		ShapeMode.SLIT:
			return PI * rim_radius * (rim_radius * slit_aspect_ratio)
		ShapeMode.POLYGON_CUSTOM:
			return _polygon_area(custom_positions)
		_:
			return 0.0


# ─── Play-mode rim build ───────────────────────────────────────────


func _ready() -> void:
	if Engine.is_editor_hint():
		# Editor mode: no inner Orifice, just gizmo preview.
		return
	_orifice = ClassDB.instantiate("Orifice")
	_orifice.name = "Orifice"
	add_child(_orifice)
	# Forward host-bone configuration.
	if not skeleton_path.is_empty() and _orifice.has_method("set_skeleton_path"):
		_orifice.call("set_skeleton_path", _orifice.get_path_to(get_node_or_null(skeleton_path)))
	if not bone_name.is_empty() and _orifice.has_method("set_bone_name"):
		_orifice.call("set_bone_name", bone_name)
	# Forward EI lifecycle signals so Canal subscribers can connect to
	# OrificeBuilder transparently (it quacks like an Orifice for the
	# Canal subscription path).
	if _orifice.has_signal("entry_interaction_started"):
		_orifice.entry_interaction_started.connect(
				func(tid, idx): entry_interaction_started.emit(tid, idx))
	if _orifice.has_signal("entry_interaction_ended"):
		_orifice.entry_interaction_ended.connect(
				func(tid): entry_interaction_ended.emit(tid))
	_build_rim_at_ready()


func _build_rim_at_ready() -> void:
	if _orifice == null:
		return
	match shape_mode:
		ShapeMode.CIRCLE:
			_OrificeAuthoring.add_circular_rim(_orifice, rim_center_offset,
					rim_radius, rim_particle_count,
					rest_stiffness, area_compliance, distance_compliance)
		ShapeMode.SLIT:
			var positions := _ellipse_positions(rim_particle_count, rim_radius,
					rim_radius * slit_aspect_ratio)
			# Apply center offset.
			for i in positions.size():
				positions[i] += rim_center_offset
			_OrificeAuthoring.add_polygon_rim(_orifice, positions,
					compute_target_area(),
					rest_stiffness, area_compliance, distance_compliance)
		ShapeMode.POLYGON_CUSTOM:
			if custom_positions.size() < 3:
				push_warning("OrificeBuilder: POLYGON_CUSTOM needs ≥ 3 positions; rim not built")
				return
			_OrificeAuthoring.add_polygon_rim(_orifice, custom_positions,
					compute_target_area(),
					rest_stiffness, area_compliance, distance_compliance)


# ─── Shape helpers ─────────────────────────────────────────────────


## Returns N points on a circle of radius `r`, in the plane
## perpendicular to `rim_axis`, centered at `rim_center_offset`.
func _circle_positions(p_n: int, p_r: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(p_n)
	var basis := _rim_plane_basis()
	for i in p_n:
		var theta := TAU * float(i) / float(p_n)
		out[i] = rim_center_offset \
				+ basis.x * (p_r * cos(theta)) \
				+ basis.y * (p_r * sin(theta))
	return out


func _ellipse_positions(p_n: int, p_a: float, p_b: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(p_n)
	var basis := _rim_plane_basis()
	for i in p_n:
		var theta := TAU * float(i) / float(p_n)
		out[i] = rim_center_offset \
				+ basis.x * (p_a * cos(theta)) \
				+ basis.y * (p_b * sin(theta))
	return out


## Returns the two orthonormal in-plane axes (x, y) perpendicular to
## `rim_axis`. The third (z) is `rim_axis` itself; not returned.
func _rim_plane_basis() -> Dictionary:
	var z := rim_axis.normalized()
	# Pick a stable reference axis; X if not parallel, else Z.
	var ref := Vector3.RIGHT if absf(z.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var x := ref.cross(z).normalized()
	var y := z.cross(x).normalized()
	return {"x": x, "y": y, "z": z}


## Signed-area shoelace on the XZ projection. Good enough for
## visualizing target area in the inspector; not used at runtime.
func _polygon_area(p_positions: PackedVector3Array) -> float:
	if p_positions.size() < 3:
		return 0.0
	var basis := _rim_plane_basis()
	var area := 0.0
	for i in p_positions.size():
		var a: Vector3 = p_positions[i] - rim_center_offset
		var b: Vector3 = p_positions[(i + 1) % p_positions.size()] - rim_center_offset
		var ax := a.dot(basis.x)
		var ay := a.dot(basis.y)
		var bx := b.dot(basis.x)
		var by := b.dot(basis.y)
		area += (ax * by - bx * ay) * 0.5
	return absf(area)
