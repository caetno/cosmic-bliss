@tool
class_name OrificeAuthoring
extends RefCounted

## Programmatic-authoring helpers for `Orifice` rim loops. Stand-in
## convenience until body_field's `RimRingPrimitive` editor gizmo
## ships (per `docs/Cosmic_Bliss_Update_2026-05-13_gizmo_primitive_authoring.md`
## §5 step (b), gated on body_field's `PrimitiveAuthoring` infra).
##
## Until then, an author has two paths:
##
##   (a) **Blender script** per §10.4 — `<Prefix>_Center` + `<Prefix>_Ring_i`
##       deform bones, skin weights painted. Hero is exported as GLB and
##       the rim is bone-skinned (no per-tick rim deformation visible on
##       the body mesh in the visual layer).
##   (b) **Programmatic** via this class. Call from a `_ready` script:
##       `OrificeAuthoring.add_circular_rim(orifice, Vector3.ZERO, 0.05, 8)`
##       The orifice gets an XPBD rim immediately; visual rim skin still
##       needs (a) bone painting OR body_field's N-source bake when it
##       ships.
##
## This file lives in `gdscript/orifice/` — the directory the §10.4
## doc predicted would exist for orifice authoring helpers.

## Add a circular rim loop to `p_orifice`. Positions are N points on a
## circle of `p_radius` in the XZ plane around `p_center`, in the
## orifice's Center frame. Returns the new loop's index (== 0 for the
## first loop) or -1 on failure.
##
## Defaults are tuned for typical anatomy (5C-A defaults preserved).
## Author can override `p_rest_stiffness` / `p_area_compliance` /
## `p_distance_compliance` per anatomy (lax vulva vs tight anus).
static func add_circular_rim(p_orifice: Node3D,
		p_center: Vector3 = Vector3.ZERO,
		p_radius: float = 0.05,
		p_n: int = 8,
		p_rest_stiffness: float = 0.5,
		p_area_compliance: float = 1e-4,
		p_distance_compliance: float = 1e-6) -> int:
	if p_orifice == null:
		push_error("OrificeAuthoring.add_circular_rim: orifice is null")
		return -1
	if not p_orifice.has_method("add_rim_loop"):
		push_error("OrificeAuthoring.add_circular_rim: target lacks add_rim_loop "
				+ "(tentacletech extension not loaded?)")
		return -1
	if p_n < 3:
		push_error("OrificeAuthoring.add_circular_rim: n must be ≥ 3, got %d" % p_n)
		return -1
	if p_radius <= 0.0:
		push_error("OrificeAuthoring.add_circular_rim: radius must be > 0, got %f" % p_radius)
		return -1

	var positions := PackedVector3Array()
	var stiffness := PackedFloat32Array()
	positions.resize(p_n)
	stiffness.resize(p_n)
	for i in p_n:
		var theta := TAU * float(i) / float(p_n)
		positions[i] = p_center + Vector3(p_radius * cos(theta), 0.0, p_radius * sin(theta))
		stiffness[i] = p_rest_stiffness

	var segment_rest_lengths := _compute_segment_rest_lengths(positions)
	var target_area := PI * p_radius * p_radius

	return p_orifice.call("add_rim_loop",
			positions, segment_rest_lengths, target_area,
			stiffness, p_area_compliance, p_distance_compliance)


## Add a rim loop with custom-authored positions (non-circular: slit,
## oval, asymmetric vulva). `p_positions` is in the orifice's Center
## frame; `p_target_area` is the polygon area of the rest loop (use
## `Geometry2D.triangulate_polygon` or pre-compute). Other args mirror
## `add_circular_rim`.
static func add_polygon_rim(p_orifice: Node3D,
		p_positions: PackedVector3Array,
		p_target_area: float,
		p_rest_stiffness: float = 0.5,
		p_area_compliance: float = 1e-4,
		p_distance_compliance: float = 1e-6) -> int:
	if p_orifice == null or not p_orifice.has_method("add_rim_loop"):
		push_error("OrificeAuthoring.add_polygon_rim: orifice null or lacks add_rim_loop")
		return -1
	if p_positions.size() < 3:
		push_error("OrificeAuthoring.add_polygon_rim: need ≥ 3 positions, got %d" % p_positions.size())
		return -1
	var stiffness := PackedFloat32Array()
	stiffness.resize(p_positions.size())
	stiffness.fill(p_rest_stiffness)
	var segment_rest_lengths := _compute_segment_rest_lengths(p_positions)
	return p_orifice.call("add_rim_loop",
			p_positions, segment_rest_lengths, p_target_area,
			stiffness, p_area_compliance, p_distance_compliance)


## Compute per-segment rest lengths for a closed loop of positions.
## Segment k runs (k, k+1) wrapping at size().
static func _compute_segment_rest_lengths(
		p_positions: PackedVector3Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var n := p_positions.size()
	out.resize(n)
	for i in n:
		var a: Vector3 = p_positions[i]
		var b: Vector3 = p_positions[(i + 1) % n]
		out[i] = (b - a).length()
	return out
