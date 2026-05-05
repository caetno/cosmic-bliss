@tool
class_name RibsFeature
extends TentacleFeature
## §10.2 RibsFeature — circumferential grooves along the body. Vertex-kernel:
## scales the radial component of body vertices inward at each rib center.
## "V" profile gives a sharp triangular indent; "U" gives a smooth (Gaussian)
## indent. No new topology — the existing body radial_segments × axial rings
## carry the indent shape.
##
## §5.0 partition: silhouette-defining → mesh layer.

enum Profile { U = 0, V = 1 }

@export_range(0, 64, 1) var count: int = 8 :
	set(v):
		if count == v: return
		count = v
		emit_changed()
@export var spacing_curve: Curve = null :
	set(v):
		if spacing_curve == v: return
		spacing_curve = v
		emit_changed()
@export var profile: Profile = Profile.U :
	set(v):
		if profile == v: return
		profile = v
		emit_changed()
# Indent depth as a fraction of the local body radius (0.1 = 10% inward).
@export_range(0.0, 0.9, 0.001) var depth: float = 0.12 :
	set(v):
		if depth == v: return
		depth = v
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
# Axial half-width of one rib as a fraction of inter-rib spacing.
@export_range(0.05, 2.0, 0.01) var width_factor: float = 0.35 :
	set(v):
		if width_factor == v: return
		width_factor = v
		emit_changed()


func _apply(p_ctx: BakeContext) -> void:
	if not enabled or count <= 0 or depth <= 0.0:
		return
	var meta: Dictionary = (p_ctx.get_meta(&"tentacle_mesh_meta", {})
			if p_ctx.has_meta(&"tentacle_mesh_meta") else {})
	var length: float = meta.get("length", 0.4)
	if length <= 0.0:
		return

	var centers: PackedFloat32Array = _compute_centers()
	var span: float = maxf(t_end - t_start, 1e-4)
	var half_width: float = (span / float(count)) * width_factor
	if half_width <= 1e-5:
		return
	# Per-vertex inner loop runs in C++. Profile enum stays in lockstep
	# with the kernel's switch (0=U, 1=V).
	p_ctx.vertices = ProceduralKernels.displace_ribs(
			p_ctx.vertices, p_ctx.custom0, length,
			centers, half_width, depth, int(profile))


# Slice 5H — silhouette bake. Ribs are inward grooves at fixed axial
# positions, all θ. They REDUCE the body radius (negative amplitude).
# `depth` is interpreted as a fraction of a 1 cm reference baseline so
# a rib of `depth = 0.12` deposits ~1.2 mm INWARD perturbation at the
# groove axis.
func bake_silhouette_contribution(p_ctx: SilhouetteBakeContext) -> void:
	if not enabled or count <= 0 or depth <= 0.0:
		return
	var centers: PackedFloat32Array = _compute_centers()
	var span: float = maxf(t_end - t_start, 1e-4)
	var sigma_t: float = (span / float(count)) * width_factor
	if sigma_t <= 1e-5:
		return
	# Reference baseline 1 cm; depth is a fractional groove depth.
	var amplitude: float = -depth * 0.01
	for c in centers:
		p_ctx.add_axial_ring(c, sigma_t, amplitude)


func _compute_centers() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(count)
	if count == 1:
		out[0] = (t_start + t_end) * 0.5
		return out
	for i in count:
		var u: float = float(i) / float(count - 1)
		var s: float = spacing_curve.sample(u) if spacing_curve != null else u
		out[i] = lerpf(t_start, t_end, clampf(s, 0.0, 1.0))
	return out


func _max_indent(p_t: float, p_centers: PackedFloat32Array, p_half_width: float) -> float:
	var best: float = 0.0
	for c in p_centers:
		var d: float = absf(p_t - c)
		if d >= p_half_width and profile == Profile.V:
			continue
		if d > 3.0 * p_half_width:
			continue
		var v: float = 0.0
		match profile:
			Profile.V:
				v = 1.0 - (d / p_half_width)
			Profile.U:
				var x: float = d / p_half_width
				v = exp(-0.5 * x * x)
		if v > best:
			best = v
	return best
