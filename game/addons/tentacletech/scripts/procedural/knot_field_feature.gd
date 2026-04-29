@tool
class_name KnotFieldFeature
extends TentacleFeature
## §10.2 KnotFieldFeature — radial bumps along the body axis (no extra
## topology). Vertex-kernel: each existing body vertex gets its radial
## component scaled by `1 + (max_radius_multiplier - 1) * profile(distance)`,
## where profile is sampled from the nearest knot center.
##
## §5.0 partition: silhouette-defining → mesh layer; modulates body radius
## without introducing new geometry. The girth bake (final vertex z-extent
## scan) picks up the bumps automatically.

enum Profile { GAUSSIAN = 0, SHARP = 1, ASYMMETRIC = 2 }

@export_range(0, 64, 1) var count: int = 5 :
	set(v):
		if count == v: return
		count = v
		emit_changed()
@export var spacing_curve: Curve = null :
	set(v):
		if spacing_curve == v: return
		spacing_curve = v
		emit_changed()
@export var profile: Profile = Profile.GAUSSIAN :
	set(v):
		if profile == v: return
		profile = v
		emit_changed()
@export_range(0.5, 8.0, 0.01, "or_greater") var max_radius_multiplier: float = 1.4 :
	set(v):
		if max_radius_multiplier == v: return
		max_radius_multiplier = v
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
# Half-width of the bump as a fraction of the inter-knot spacing. 0.5 = bumps
# meet halfway between centers; smaller = sharper isolated bumps.
@export_range(0.05, 2.0, 0.01) var sigma_factor: float = 0.45 :
	set(v):
		if sigma_factor == v: return
		sigma_factor = v
		emit_changed()


func _apply(p_ctx: BakeContext) -> void:
	if not enabled or count <= 0:
		return
	if absf(max_radius_multiplier - 1.0) < 1e-4:
		return
	var meta: Dictionary = (p_ctx.get_meta(&"tentacle_mesh_meta", {})
			if p_ctx.has_meta(&"tentacle_mesh_meta") else {})
	var length: float = meta.get("length", 0.4)
	if length <= 0.0:
		return

	var centers: PackedFloat32Array = _compute_centers()
	var span: float = maxf(t_end - t_start, 1e-4)
	var sigma: float = (span / float(count)) * sigma_factor
	if sigma <= 1e-5:
		return
	# Per-vertex inner loop runs in C++. Profile enum stays in lockstep
	# with the kernel's switch (0=Gaussian, 1=Sharp, 2=Asymmetric).
	p_ctx.vertices = ProceduralKernels.displace_knots(
			p_ctx.vertices, p_ctx.custom0, length,
			centers, sigma, max_radius_multiplier, int(profile))


func _compute_centers() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(count)
	if count == 1:
		out[0] = (t_start + t_end) * 0.5
		return out
	for i in count:
		var u: float = float(i) / float(count - 1)
		# spacing_curve remaps the uniform [0,1] distribution. If null, uniform.
		var s: float = spacing_curve.sample(u) if spacing_curve != null else u
		out[i] = lerpf(t_start, t_end, clampf(s, 0.0, 1.0))
	return out


# Maximum bump influence at axial position `t` across all centers. Uses the
# selected profile shape; centers more than ~3σ away contribute zero.
func _max_influence(p_t: float, p_centers: PackedFloat32Array, p_sigma: float) -> float:
	var best: float = 0.0
	for c in p_centers:
		var d: float = absf(p_t - c)
		if d > 3.0 * p_sigma:
			continue
		var x: float = d / p_sigma
		var v: float = 0.0
		match profile:
			Profile.GAUSSIAN:
				v = exp(-0.5 * x * x)
			Profile.SHARP:
				v = maxf(0.0, 1.0 - x)
			Profile.ASYMMETRIC:
				# Slow rise toward the tip side, sharp fall on the base side.
				var signed: float = (p_t - c) / p_sigma
				v = (exp(-0.5 * signed * signed * 4.0)
						if signed < 0.0
						else maxf(0.0, 1.0 - signed))
		if v > best:
			best = v
	return best
