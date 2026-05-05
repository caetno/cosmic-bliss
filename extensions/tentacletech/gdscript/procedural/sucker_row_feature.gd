@tool
class_name SuckerRowFeature
extends TentacleFeature
## §10.2 SuckerRowFeature — silhouette-defining sucker geometry.
##
## §5.0 partition tag: **silhouette-defining → mesh layer.** This feature
## emits geometry (rim + cup) and authors the masks the fragment shader
## uses to render wet-rim sheen + cup interior shading. It does not depend
## on any other feature's masks.
##
## The geometry is a "stuck-on" patch: the body cylinder is left untouched;
## each sucker contributes a small dish (cup floor → cup rim → raised rim)
## that sits on the body surface at the chosen (axial_t, radial_angle).
## Topology surgery to merge into the body is deferred to Phase 9 polish —
## the visual silhouette is dominated by the raised rim, which renders
## correctly without merge.

enum SuckerSide {
	ONE_SIDE = 0,   # all suckers radiate from one angle (opposite the seam)
	TWO_SIDE = 1,   # two bands at ±90° from the seam, alternating per sucker
	ALL_AROUND = 2, # equally spaced around the body
	SPIRAL = 3,     # phyllotactic spiral
}

@export var count: int = 8 :
	set(v):
		if count == v: return
		count = v
		emit_changed()
@export var position_curve: Curve = null :
	set(v):
		if position_curve == v: return
		position_curve = v
		emit_changed()
@export var size_curve: Curve = null :
	set(v):
		if size_curve == v: return
		size_curve = v
		emit_changed()
@export var side: SuckerSide = SuckerSide.ONE_SIDE :
	set(v):
		if side == v: return
		side = v
		emit_changed()
@export_range(0.0, 0.5, 0.001) var rim_height: float = 0.005 :
	set(v):
		if rim_height == v: return
		rim_height = v
		emit_changed()
@export_range(0.0, 0.5, 0.001) var cup_depth: float = 0.008 :
	set(v):
		if cup_depth == v: return
		cup_depth = v
		emit_changed()
@export_range(0.0, 0.2, 0.001) var double_row_offset: float = 0.0 :
	set(v):
		if double_row_offset == v: return
		double_row_offset = v
		emit_changed()
@export_range(0.001, 0.2, 0.001) var base_size: float = 0.018 :
	set(v):
		if base_size == v: return
		base_size = v
		emit_changed()
@export_range(0.001, 0.5, 0.001) var rim_outer_factor: float = 1.35 :
	set(v):
		if rim_outer_factor == v: return
		rim_outer_factor = v
		emit_changed()
@export var disc_segments: int = 10 :
	set(v):
		if disc_segments == v: return
		disc_segments = v
		emit_changed()
@export_range(0.0, 6.283185, 0.001) var spiral_step: float = 1.94 :
	set(v):
		if spiral_step == v: return
		spiral_step = v
		emit_changed()

const SEAM_TOLERANCE_RAD := deg_to_rad(5.0)


func _get_required_masks() -> PackedStringArray:
	# COLOR.r = sucker mask, UV1 = disc-local space, CUSTOM0.x = feature ID.
	return PackedStringArray([
		BakeContext.CH_COLOR_R,
		BakeContext.CH_UV1,
		BakeContext.CH_CUSTOM0_X,
	])


func _apply(p_ctx: BakeContext) -> void:
	if not enabled:
		return
	if count <= 0:
		return

	# Read base-shape parameters from the context's header_meta — TentacleMesh
	# pushes these in before features run.
	var meta: Dictionary = p_ctx.get_meta(&"tentacle_mesh_meta", {}) if p_ctx.has_meta(&"tentacle_mesh_meta") else {}
	var length: float = meta.get("length", 0.4)
	var base_radius: float = meta.get("base_radius", 0.04)
	var tip_radius: float = meta.get("tip_radius", 0.005)
	var radius_curve: Curve = meta.get("radius_curve", null)
	var seam_offset: float = meta.get("seam_offset", 0.0)
	var intrinsic_axis_sign: float = meta.get("intrinsic_axis_sign", 1.0)

	for i in count:
		var t_normalized: float = float(i) / float(maxi(count - 1, 1))
		var axial_t: float = position_curve.sample(t_normalized) if position_curve != null else t_normalized
		axial_t = clampf(axial_t, 0.0, 1.0)

		var size_scale: float = size_curve.sample(axial_t) if size_curve != null else 1.0
		var cup_radius: float = base_size * size_scale
		if cup_radius <= 1e-5:
			continue

		var radial_angle: float = _radial_angle_for_index(i, seam_offset)

		# Seam validation per §10.2 authoring rule. wrap_diff handles the
		# 2π wrap so a sucker at θ=0 with seam at θ=2π still resolves to
		# Δ=0.
		var seam_delta: float = absf(_wrap_signed(radial_angle - seam_offset))
		if seam_delta < SEAM_TOLERANCE_RAD:
			p_ctx.errors.push_back(
				"SuckerRowFeature: sucker %d at angle %.3f° lands within ±5° of seam (%.3f°); skipped"
					% [i, rad_to_deg(radial_angle), rad_to_deg(seam_offset)])
			continue

		_emit_sucker(p_ctx, axial_t, radial_angle, cup_radius, length,
				base_radius, tip_radius, radius_curve, intrinsic_axis_sign)


# Compute the radial angle for sucker i based on the side enum.
func _radial_angle_for_index(p_i: int, p_seam_offset: float) -> float:
	match side:
		SuckerSide.ONE_SIDE:
			# Opposite the seam.
			return p_seam_offset + PI
		SuckerSide.TWO_SIDE:
			# Two bands ±90° from seam, alternating per sucker.
			return p_seam_offset + (PI * 0.5 if p_i % 2 == 0 else -PI * 0.5)
		SuckerSide.ALL_AROUND:
			return TAU * float(p_i) / float(count)
		SuckerSide.SPIRAL:
			# Phyllotactic — accumulating spiral_step per sucker, starting
			# opposite the seam so the spiral originates dorsally.
			return p_seam_offset + PI + spiral_step * float(p_i)
		_:
			return 0.0


# Emit one sucker patch into the bake context. Returns nothing; mutates ctx.
func _emit_sucker(p_ctx: BakeContext, p_axial_t: float, p_radial_angle: float,
		p_cup_radius: float, p_length: float, p_base_radius: float,
		p_tip_radius: float, p_radius_curve: Curve,
		p_intrinsic_axis_sign: float) -> void:
	# Spine point in tentacle-local space. intrinsic_axis_sign = +1 for the
	# canonical §10.1 +Z layout; sign=-1 supported for Blender-imported
	# meshes that author along -Z.
	var spine_pos := Vector3(0, 0, p_intrinsic_axis_sign * p_length * p_axial_t)
	var body_radius: float = (p_radius_curve.sample(p_axial_t)
			if p_radius_curve != null
			else lerpf(p_base_radius, p_tip_radius, p_axial_t))
	var surface_normal := Vector3(cos(p_radial_angle), sin(p_radial_angle), 0)
	var surface_pos: Vector3 = spine_pos + surface_normal * body_radius

	# Tangent basis on the body surface at this point.
	#   right        — circumferential, in the +θ direction
	#   forward_arc  — along the spine, in the direction of increasing axial_t
	# Both are unit vectors and orthogonal to surface_normal.
	var right := Vector3(-sin(p_radial_angle), cos(p_radial_angle), 0)
	var forward_arc := Vector3(0, 0, p_intrinsic_axis_sign)

	# Rings:
	#   floor_ring  — recessed cup floor at radius cup_radius * 0.4
	#   cup_ring    — at the body surface, full cup_radius
	#   rim_ring    — raised rim above surface, slightly larger radius
	var floor_radius: float = p_cup_radius * 0.4
	var rim_radius: float = p_cup_radius * rim_outer_factor

	var floor_indices := _emit_disc_ring(p_ctx, surface_pos, surface_normal,
			right, forward_arc, floor_radius, -surface_normal * cup_depth,
			BakeContext.FEATURE_ID_SUCKER_CUP)
	var cup_indices := _emit_disc_ring(p_ctx, surface_pos, surface_normal,
			right, forward_arc, p_cup_radius, Vector3.ZERO,
			BakeContext.FEATURE_ID_SUCKER_CUP)
	var rim_indices := _emit_disc_ring(p_ctx, surface_pos, surface_normal,
			right, forward_arc, rim_radius, surface_normal * rim_height,
			BakeContext.FEATURE_ID_SUCKER_RIM)

	# Center vertex of the cup floor — apex of a triangle fan into floor_ring.
	# Recessed by an extra 30% of cup_depth so the cup has a clear concavity.
	var center_pos: Vector3 = surface_pos - surface_normal * cup_depth * 1.3
	var center_idx: int = p_ctx.add_vertex(
			center_pos,
			-surface_normal,
			Vector2(0.5, p_axial_t),
			Vector2(0.5, 0.5),
			Color(1.0, 0.0, 0.0, 0.0),
			Color(BakeContext.FEATURE_ID_SUCKER_CUP, 0.0, 0.0, 0.0))

	# Connect rings — fan center→floor, strip floor→cup, strip cup→rim.
	for k in floor_indices.size():
		var k_next: int = (k + 1) % floor_indices.size()
		p_ctx.indices.push_back(center_idx)
		p_ctx.indices.push_back(floor_indices[k])
		p_ctx.indices.push_back(floor_indices[k_next])

	p_ctx.connect_rings(floor_indices, cup_indices)
	p_ctx.connect_rings(cup_indices, rim_indices)

	# Mask writes (last-writer-wins per channel per §10.2 — recorded in
	# channels_written for the bake header).
	p_ctx.mark_mask(BakeContext.CH_COLOR_R, floor_indices, 1.0)
	p_ctx.mark_mask(BakeContext.CH_COLOR_R, cup_indices, 1.0)
	p_ctx.mark_mask(BakeContext.CH_COLOR_R, rim_indices, 1.0)
	p_ctx.mark_mask(BakeContext.CH_COLOR_R, PackedInt32Array([center_idx]), 1.0)
	p_ctx.mark_mask(BakeContext.CH_CUSTOM0_X, floor_indices, BakeContext.FEATURE_ID_SUCKER_CUP)
	p_ctx.mark_mask(BakeContext.CH_CUSTOM0_X, cup_indices, BakeContext.FEATURE_ID_SUCKER_CUP)
	p_ctx.mark_mask(BakeContext.CH_CUSTOM0_X, rim_indices, BakeContext.FEATURE_ID_SUCKER_RIM)
	p_ctx.mark_mask(BakeContext.CH_CUSTOM0_X, PackedInt32Array([center_idx]), BakeContext.FEATURE_ID_SUCKER_CUP)


# Emit one ring of `disc_segments` vertices around the surface point in the
# (right, forward_arc) plane, offset by p_height_offset. UV1 is set to the
# disc-local coordinates: (0.5, 0.5) at center, on a unit-diameter disc.
# Returns the indices of the new vertices.
func _emit_disc_ring(p_ctx: BakeContext, p_center: Vector3,
		p_outward_normal: Vector3, p_right: Vector3, p_forward: Vector3,
		p_radius: float, p_height_offset: Vector3,
		p_feature_id: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(disc_segments)
	for i in disc_segments:
		var phi: float = TAU * float(i) / float(disc_segments)
		var local_offset: Vector3 = (p_right * cos(phi) + p_forward * sin(phi)) * p_radius
		var pos: Vector3 = p_center + local_offset + p_height_offset
		# UV1: unit-diameter disc centered at (0.5, 0.5). Edge of cup_radius
		# disc → (0.5 + cos*0.5, 0.5 + sin*0.5).
		var uv1 := Vector2(0.5 + 0.5 * cos(phi), 0.5 + 0.5 * sin(phi))
		# UV0: keep approximate body unwrap. U from radial angle, V from axial_t.
		var uv0 := Vector2(0.0, 0.0)
		# Outward normal blends toward spine-radial; for raised rim points
		# normal points outward; for recessed floor points it tips toward
		# the surface tangent. Cheap approximation: keep surface_normal.
		var idx: int = p_ctx.add_vertex(pos, p_outward_normal, uv0, uv1,
				Color(1.0, 0.0, 0.0, 0.0),
				Color(p_feature_id, 0.0, 0.0, 0.0))
		out[i] = idx
	return out


# Wrap a signed angle into (-π, π]. Used by the seam-validation check.
static func _wrap_signed(p_angle: float) -> float:
	var a: float = fposmod(p_angle + PI, TAU) - PI
	return a


# Slice 5H — silhouette bake. Each sucker is a concentric pair: outer
# rim positive (raised), inner cup negative (depressed). Approximated
# as a positive Gaussian at the sucker center plus a deeper negative
# Gaussian with a smaller σ stacked on top — net signature is "rim up,
# pit down" at the contact-threshold scale. Since we deposit two
# Gaussians at the same (t, θ) the net peak is `rim_height − cup_depth`.
func bake_silhouette_contribution(p_ctx: SilhouetteBakeContext) -> void:
	if not enabled or count <= 0:
		return
	var length: float = p_ctx.total_arc_length
	if length <= 0.0:
		return
	# Reference baseline 1 cm — see KnotFieldFeature note.
	var avg_radius: float = 0.01
	var seam_offset: float = 0.0  # default; sucker honors seam in mesh path, but for silhouette we don't have access to it
	for i in count:
		var t_normalized: float = float(i) / float(maxi(count - 1, 1))
		var axial_t: float = position_curve.sample(t_normalized) if position_curve != null else t_normalized
		axial_t = clampf(axial_t, 0.0, 1.0)
		var size_scale: float = size_curve.sample(axial_t) if size_curve != null else 1.0
		var cup_radius: float = base_size * size_scale
		if cup_radius <= 1e-5:
			continue
		var radial_angle: float = _radial_angle_for_index(i, seam_offset)
		var sigma_t: float = (cup_radius * rim_outer_factor) / maxf(length, 1e-4)
		var sigma_theta_outer: float = (cup_radius * rim_outer_factor) / maxf(avg_radius, 1e-4)
		var sigma_theta_inner: float = cup_radius / maxf(avg_radius, 1e-4)
		# Outer rim: positive, broader Gaussian.
		p_ctx.add_gaussian(axial_t, radial_angle, sigma_t, sigma_theta_outer, rim_height)
		# Inner pit: negative, narrower Gaussian (digs deeper into the
		# rim signature — the SUM gives a "raised ring with sunken
		# centre" silhouette).
		p_ctx.add_gaussian(axial_t, radial_angle, sigma_t * 0.6, sigma_theta_inner, -cup_depth)
