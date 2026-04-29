@tool
class_name WartClusterFeature
extends TentacleFeature
## §10.2 WartClusterFeature — silhouette-meaningful warts as 3D Gaussian
## bumps that emerge from the body mesh. Vertex-kernel only: each wart is a
## (axial_t, radial_angle) anchor with a hemispherical Gaussian profile;
## body vertices within reach are displaced outward along their local
## radial direction by the summed profile. No new geometry, no extra
## triangles.
##
## §5.0 partition: silhouette-defining → mesh layer.
##
## Resolution caveat: visible warts need body mesh density at the wart
## scale. With default `radial_segments=16` and `base_radius=0.04`, each
## angular segment spans ~1.6 cm of arc. Warts smaller than ~2 cm may miss
## vertices entirely. Either increase body density (`radial_segments` /
## `length_segments`) or keep wart sizes ≳ one segment width.

# Approximate target density per square meter of body surface. Actual count
# is `density × surface_area_in_band`, capped by `max_count`.
@export_range(0.0, 5000.0, 1.0, "or_greater") var density: float = 200.0 :
	set(v):
		if density == v: return
		density = v
		emit_changed()
@export_range(0.0, 0.2, 0.001) var size_min: float = 0.012 :
	set(v):
		if size_min == v: return
		size_min = v
		emit_changed()
@export_range(0.0, 0.2, 0.001) var size_max: float = 0.024 :
	set(v):
		if size_max == v: return
		size_max = v
		emit_changed()
# Bump height as a fraction of size (= base diameter). 0.5 = hemispherical;
# >0.5 = elongated/pointier; <0.5 = squashed.
@export_range(0.05, 4.0, 0.01) var height_factor: float = 0.5 :
	set(v):
		if height_factor == v: return
		height_factor = v
		emit_changed()
# Widens the bump's falloff without changing its height. Internally scales
# the Gaussian's σ by `(1 + smoothing)`: 0 = original tight bump (steeper,
# can spike on low-res bodies), 1 (default) = ~2× wider falloff (more body
# vertices share the gradient, gentler dome), higher = very wide / soft
# bumps that may visibly overlap if density is high. The bump's diameter
# in `size_min/size_max` is unchanged — `smoothing` only controls how
# gradually it tapers, not its peak height.
@export_range(0.0, 4.0, 0.01) var smoothing: float = 1.0 :
	set(v):
		if smoothing == v: return
		smoothing = v
		emit_changed()
@export_range(0, 4096, 1) var max_count: int = 256 :
	set(v):
		if max_count == v: return
		max_count = v
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
# >0 biases warts toward each other (clusters); =0 uniform; <0 regularized.
@export_range(-2.0, 4.0, 0.05) var clustering_exponent: float = 0.0 :
	set(v):
		if clustering_exponent == v: return
		clustering_exponent = v
		emit_changed()
@export var seed: int = 1 :
	set(v):
		if seed == v: return
		seed = v
		emit_changed()


func _apply(p_ctx: BakeContext) -> void:
	if not enabled or density <= 0.0 or size_max <= 0.0:
		return
	var size_lo: float = minf(size_min, size_max)
	var size_hi: float = maxf(size_min, size_max)
	var meta: Dictionary = (p_ctx.get_meta(&"tentacle_mesh_meta", {})
			if p_ctx.has_meta(&"tentacle_mesh_meta") else {})
	var length: float = meta.get("length", 0.4)
	var base_radius: float = meta.get("base_radius", 0.04)
	var tip_radius: float = meta.get("tip_radius", 0.005)
	if length <= 0.0:
		return

	# Approximate body surface area in [t_start, t_end] (truncated cone
	# slant). Good enough for density targeting.
	var avg_radius: float = (base_radius + tip_radius) * 0.5
	var span: float = maxf(t_end - t_start, 0.0)
	var surface_area: float = TAU * avg_radius * length * span
	var n: int = int(round(density * surface_area))
	n = clampi(n, 0, max_count)
	if n <= 0:
		return

	# Generate wart anchors deterministically (same seed → same warts).
	var rng := RandomNumberGenerator.new()
	rng.seed = max(1, seed)
	var centers_t := PackedFloat32Array()
	var centers_phi := PackedFloat32Array()
	var sigma := PackedFloat32Array()    # radius of bump (= half base diameter)
	var height := PackedFloat32Array()
	centers_t.resize(n); centers_phi.resize(n)
	sigma.resize(n); height.resize(n)
	for i in n:
		var t: float = lerpf(t_start, t_end, rng.randf())
		var phi: float = rng.randf() * TAU
		if clustering_exponent > 0.0 and i > 0:
			var anchor_idx: int = rng.randi_range(0, i - 1)
			t = lerpf(centers_t[anchor_idx], t,
					pow(rng.randf(), clustering_exponent + 1.0))
			phi = lerpf(centers_phi[anchor_idx], phi,
					pow(rng.randf(), clustering_exponent + 1.0))
		var s: float = lerpf(size_lo, size_hi, rng.randf())
		centers_t[i] = t
		centers_phi[i] = phi
		# `smoothing` widens the Gaussian falloff without changing the
		# peak height — bigger σ pulls more body vertices into the bump
		# so the gradient is gentler.
		sigma[i] = s * 0.5 * (1.0 + smoothing)
		height[i] = s * height_factor

	# Hand off the per-vertex inner loop to the C++ kernel. Pure 3D
	# Gaussian summed across warts within reach, plus axial spatial-
	# binning. Anchor generation (RNG / Curve sampling / smoothing→σ
	# scaling) all stays in GDScript.
	p_ctx.vertices = ProceduralKernels.displace_warts(
			p_ctx.vertices, p_ctx.custom0, length,
			centers_t, centers_phi, sigma, height)
