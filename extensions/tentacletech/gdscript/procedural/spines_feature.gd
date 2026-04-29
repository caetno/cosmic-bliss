@tool
class_name SpinesFeature
extends TentacleFeature
## §10.2 SpinesFeature — pointed spikes attached to the body surface.
## Topology-adding: each spine emits a cone (base ring + apex) anchored at
## a (axial_t, radial_angle) on the body, displaced outward along the
## surface normal with optional axial pitch toward the tip.
##
## §5.0 partition: silhouette-defining → mesh layer. Stuck-on patch (no
## topology surgery into the body); the visible silhouette is dominated by
## the cone, which renders correctly without merge.

enum Distribution { ALL_AROUND = 0, ONE_SIDE = 1, SPIRAL = 2 }

@export_range(0, 256, 1) var count: int = 12 :
	set(v):
		if count == v: return
		count = v
		emit_changed()
@export var distribution: Distribution = Distribution.SPIRAL :
	set(v):
		if distribution == v: return
		distribution = v
		emit_changed()
# Per-index axial position lerp [t_start..t_end]; null → uniform.
@export var position_curve: Curve = null :
	set(v):
		if position_curve == v: return
		position_curve = v
		emit_changed()
# Per-index length scale on `base_length`. Null → constant 1.
@export var length_curve: Curve = null :
	set(v):
		if length_curve == v: return
		length_curve = v
		emit_changed()
@export_range(0.001, 0.5, 0.001, "or_greater") var base_width: float = 0.012 :
	set(v):
		if base_width == v: return
		base_width = v
		emit_changed()
@export_range(0.001, 0.5, 0.001, "or_greater") var base_length: float = 0.05 :
	set(v):
		if base_length == v: return
		base_length = v
		emit_changed()
# Pitch of the spine away from pure-radial, in radians. 0 = perpendicular to
# body; positive = lean toward the tip.
@export_range(-1.5707, 1.5707, 0.001) var pitch: float = 0.4 :
	set(v):
		if pitch == v: return
		pitch = v
		emit_changed()
@export_range(0.0, 1.0, 0.001) var t_start: float = 0.1 :
	set(v):
		if t_start == v: return
		t_start = v
		emit_changed()
@export_range(0.0, 1.0, 0.001) var t_end: float = 0.9 :
	set(v):
		if t_end == v: return
		t_end = v
		emit_changed()
# Phyllotactic step in radians for SPIRAL distribution. ~111° default.
@export_range(0.0, 6.283185, 0.001) var spiral_step: float = 1.94 :
	set(v):
		if spiral_step == v: return
		spiral_step = v
		emit_changed()
@export_range(3, 16, 1) var radial_segments: int = 4 :
	set(v):
		if radial_segments == v: return
		radial_segments = v
		emit_changed()


func _get_required_masks() -> PackedStringArray:
	return PackedStringArray([BakeContext.CH_CUSTOM0_X])


func _apply(p_ctx: BakeContext) -> void:
	if not enabled or count <= 0:
		return
	if base_width <= 0.0 or base_length <= 0.0:
		return
	var meta: Dictionary = (p_ctx.get_meta(&"tentacle_mesh_meta", {})
			if p_ctx.has_meta(&"tentacle_mesh_meta") else {})
	var seam_offset: float = meta.get("seam_offset", 0.0)

	for i in count:
		var u: float = float(i) / float(maxi(count - 1, 1))
		var axial_t: float = lerpf(t_start, t_end,
				(position_curve.sample(u) if position_curve != null else u))
		axial_t = clampf(axial_t, 0.0, 1.0)
		var phi: float = _radial_angle_for_index(i, seam_offset)
		var len_scale: float = (length_curve.sample(axial_t)
				if length_curve != null else 1.0)
		_emit_spine(p_ctx, axial_t, phi, base_width, base_length * len_scale)


func _radial_angle_for_index(p_i: int, p_seam_offset: float) -> float:
	match distribution:
		Distribution.ONE_SIDE:
			return p_seam_offset + PI
		Distribution.ALL_AROUND:
			return TAU * float(p_i) / float(maxi(count, 1))
		Distribution.SPIRAL:
			return p_seam_offset + PI + spiral_step * float(p_i)
		_:
			return 0.0


func _emit_spine(p_ctx: BakeContext, p_axial_t: float, p_radial_angle: float,
		p_width: float, p_length: float) -> void:
	var surf: Dictionary = p_ctx.body_surface_at(p_axial_t, p_radial_angle)
	var center: Vector3 = surf["position"]
	var normal: Vector3 = surf["normal"]
	var right: Vector3 = surf["right"]
	var forward: Vector3 = surf["forward"]
	# Spine axis: blend of outward normal and forward (toward tip) by pitch.
	var spine_axis: Vector3 = (normal * cos(pitch) + forward * sin(pitch)).normalized()
	var apex_pos: Vector3 = center + spine_axis * p_length

	# Base ring lies in the plane (right, forward) tangent to body surface,
	# centered on the body surface point. Radius = p_width / 2.
	var base_radius: float = p_width * 0.5
	var base_ring := PackedInt32Array()
	base_ring.resize(radial_segments)
	for k in radial_segments:
		var theta: float = TAU * float(k) / float(radial_segments)
		var local_offset: Vector3 = (right * cos(theta) + forward * sin(theta)) * base_radius
		var pos: Vector3 = center + local_offset
		# Outward normal at base ring: blend of body normal + local cone slope.
		var slope: Vector3 = (apex_pos - pos).normalized()
		var n: Vector3 = (normal + slope * 0.5).normalized()
		var idx: int = p_ctx.add_vertex(pos, n,
				Vector2(0.5 + 0.5 * cos(theta), p_axial_t),
				Vector2(0.5 + 0.5 * cos(theta), 0.5 + 0.5 * sin(theta)),
				Color(0, 0, 0, 0),
				Color(BakeContext.FEATURE_ID_SPINE, 0, 0, 0))
		base_ring[k] = idx
	# Apex.
	var apex_idx: int = p_ctx.add_vertex(apex_pos, spine_axis,
			Vector2(0.5, p_axial_t),
			Vector2(0.5, 0.5),
			Color(0, 0, 0, 0),
			Color(BakeContext.FEATURE_ID_SPINE, 0, 0, 0))
	# Fan base → apex (winding so the outward face matches the cone slope).
	for k in radial_segments:
		var k_next: int = (k + 1) % radial_segments
		p_ctx.indices.push_back(base_ring[k])
		p_ctx.indices.push_back(base_ring[k_next])
		p_ctx.indices.push_back(apex_idx)

	p_ctx.mark_mask(BakeContext.CH_CUSTOM0_X, base_ring, BakeContext.FEATURE_ID_SPINE)
	p_ctx.mark_mask(BakeContext.CH_CUSTOM0_X, PackedInt32Array([apex_idx]),
			BakeContext.FEATURE_ID_SPINE)
