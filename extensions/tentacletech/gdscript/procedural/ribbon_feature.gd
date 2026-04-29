@tool
class_name RibbonFeature
extends TentacleFeature
## §10.2 RibbonFeature — fin strips along the body. Each fin is a quad-strip
## of length `axial_segments` running [t_start..t_end] at fixed circumferential
## angles. The strip extends radially outward from body surface; the outer
## edge can be ruffled with a sine perturbation (`ruffle_frequency` cycles
## along the strip, `ruffle_amplitude` peak displacement).
##
## §5.0 partition: silhouette-defining → mesh layer. Stuck-on patch (no
## topology surgery into the body); the strip's inner edge sits flush with
## the body surface and is rendered double-sided implicitly via the §5.3
## shader's normal handling.

# 1, 2, or 4 fins distributed evenly. Higher values are rejected to keep the
# silhouette readable; for irregular layouts use multiple RibbonFeature nodes.
@export_range(1, 4, 1) var fin_count: int = 2 :
	set(v):
		if fin_count == v: return
		fin_count = v
		emit_changed()
# Rotation of the first fin relative to the seam (radians).
@export_range(-3.14159, 3.14159, 0.001) var radial_offset: float = 0.0 :
	set(v):
		if radial_offset == v: return
		radial_offset = v
		emit_changed()
@export var width_curve: Curve = null :
	set(v):
		if width_curve == v: return
		width_curve = v
		emit_changed()
@export_range(0.001, 1.0, 0.001, "or_greater") var max_width: float = 0.06 :
	set(v):
		if max_width == v: return
		max_width = v
		emit_changed()
@export_range(0.0, 32.0, 0.1) var ruffle_frequency: float = 0.0 :
	set(v):
		if ruffle_frequency == v: return
		ruffle_frequency = v
		emit_changed()
@export_range(0.0, 0.2, 0.001) var ruffle_amplitude: float = 0.01 :
	set(v):
		if ruffle_amplitude == v: return
		ruffle_amplitude = v
		emit_changed()
@export_range(0.0, 1.0, 0.001) var t_start: float = 0.05 :
	set(v):
		if t_start == v: return
		t_start = v
		emit_changed()
@export_range(0.0, 1.0, 0.001) var t_end: float = 0.95 :
	set(v):
		if t_end == v: return
		t_end = v
		emit_changed()
@export_range(2, 128, 1) var axial_segments: int = 24 :
	set(v):
		if axial_segments == v: return
		axial_segments = v
		emit_changed()


func _get_required_masks() -> PackedStringArray:
	return PackedStringArray([
		BakeContext.CH_CUSTOM0_X,
		BakeContext.CH_COLOR_B,
	])


func _apply(p_ctx: BakeContext) -> void:
	if not enabled or fin_count <= 0 or max_width <= 0.0:
		return
	if t_end <= t_start:
		return
	var meta: Dictionary = (p_ctx.get_meta(&"tentacle_mesh_meta", {})
			if p_ctx.has_meta(&"tentacle_mesh_meta") else {})
	var seam_offset: float = meta.get("seam_offset", 0.0)
	var allowed: PackedInt32Array = PackedInt32Array([1, 2, 4])
	if not allowed.has(fin_count):
		p_ctx.errors.push_back(
			"RibbonFeature: fin_count must be 1, 2, or 4 (got %d)" % fin_count)
		return

	for f in fin_count:
		var phi: float = seam_offset + radial_offset + TAU * float(f) / float(fin_count)
		_emit_fin(p_ctx, phi)


func _emit_fin(p_ctx: BakeContext, p_phi: float) -> void:
	var inner := PackedInt32Array()
	var outer := PackedInt32Array()
	inner.resize(axial_segments + 1)
	outer.resize(axial_segments + 1)
	for i in axial_segments + 1:
		var u: float = float(i) / float(axial_segments)
		var t: float = lerpf(t_start, t_end, u)
		var surf: Dictionary = p_ctx.body_surface_at(t, p_phi)
		var inner_pos: Vector3 = surf["position"]
		var normal: Vector3 = surf["normal"]
		var width_scale: float = (width_curve.sample(u)
				if width_curve != null else _width_taper(u))
		var w: float = max_width * width_scale
		var ruffle: float = ruffle_amplitude * sin(TAU * ruffle_frequency * u)
		# Outer edge: out along surface normal, with optional axial ruffle on
		# the surface tangent (forward) so the fin gains a wavy silhouette.
		var outer_pos: Vector3 = inner_pos + normal * w + surf["forward"] * ruffle
		# Both edges share the same fin normal (perpendicular to the strip
		# plane = body's circumferential `right`). The shader's normal-flip
		# handles the back face.
		var fin_normal: Vector3 = surf["right"]
		var inner_idx: int = p_ctx.add_vertex(inner_pos, fin_normal,
				Vector2(0.0, t), Vector2(0.0, u), Color(0, 0, 1.0, 0),
				Color(BakeContext.FEATURE_ID_RIBBON, 0, 0, 0))
		var outer_idx: int = p_ctx.add_vertex(outer_pos, fin_normal,
				Vector2(1.0, t), Vector2(1.0, u), Color(0, 0, 1.0, 0),
				Color(BakeContext.FEATURE_ID_RIBBON, 0, 0, 0))
		inner[i] = inner_idx
		outer[i] = outer_idx

	# Quad-strip between inner[0..N] and outer[0..N]. Wind so the front face
	# points along the +right axis at the strip's midline; the back face is
	# implicit via shader handling.
	for i in axial_segments:
		var i0: int = inner[i]
		var i1: int = inner[i + 1]
		var o0: int = outer[i]
		var o1: int = outer[i + 1]
		p_ctx.indices.push_back(i0)
		p_ctx.indices.push_back(o0)
		p_ctx.indices.push_back(i1)
		p_ctx.indices.push_back(o0)
		p_ctx.indices.push_back(o1)
		p_ctx.indices.push_back(i1)

	p_ctx.mark_mask(BakeContext.CH_COLOR_B, inner, 1.0)
	p_ctx.mark_mask(BakeContext.CH_COLOR_B, outer, 1.0)
	p_ctx.mark_mask(BakeContext.CH_CUSTOM0_X, inner, BakeContext.FEATURE_ID_RIBBON)
	p_ctx.mark_mask(BakeContext.CH_CUSTOM0_X, outer, BakeContext.FEATURE_ID_RIBBON)


# Default width taper: full width across the middle, easing to zero at the
# ends so the fin feathers in/out smoothly. Used when `width_curve` is null.
func _width_taper(p_u: float) -> float:
	var fade: float = 0.15
	if p_u < fade:
		return smoothstep(0.0, fade, p_u)
	if p_u > 1.0 - fade:
		return smoothstep(1.0, 1.0 - fade, p_u)
	return 1.0
