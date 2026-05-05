@tool
class_name FinFeature
extends TentacleFeature
## §10.2 FinFeature — 3D fin ridges that emerge from the body mesh by
## radially displacing body vertices in narrow azimuthal bands. Unlike
## `RibbonFeature` (flat strips stuck onto the body), a fin here is a true
## 3D protrusion of the body itself: the cross-section is an ellipsoidal
## bump (axially smooth, circumferentially feathered) so twist is visible
## as the ridge winds around the body.
##
## §5.0 partition: silhouette-defining → mesh layer.
##
## Resolution caveat: the ridge cross-section is sampled by the body's
## radial_segments. Narrow fins on a low-radial-segments body appear as a
## single bumped column; widen the fin or increase radial_segments for a
## smoother profile.

# Number of fins, distributed evenly around the body. For irregular
# layouts use multiple FinFeature resources.
@export_range(1, 16, 1) var count: int = 2 :
	set(v):
		if count == v: return
		count = v
		emit_changed()
# Rotation of the first fin from +X (radians). Offsets the whole set.
@export_range(-3.14159, 3.14159, 0.001) var radial_offset: float = 0.0 :
	set(v):
		if radial_offset == v: return
		radial_offset = v
		emit_changed()
# Peak height of the ridge at its midline, in world units.
@export_range(0.0, 0.5, 0.001, "or_greater") var max_height: float = 0.04 :
	set(v):
		if max_height == v: return
		max_height = v
		emit_changed()
# Height profile along the fin's axial range. Null → smooth taper from 0
# at the ends to 1 in the middle (`_default_height_taper`).
@export var height_curve: Curve = null :
	set(v):
		if height_curve == v: return
		height_curve = v
		emit_changed()
# Half-width of the ridge in radians. The cross-section profile is a
# raised cosine: full height at the centerline, zero at ±half_width.
@export_range(0.01, 1.5707, 0.001) var half_width: float = 0.25 :
	set(v):
		if half_width == v: return
		half_width = v
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
# Radians per axial unit length: how much the ridge winds around the body
# along its run. 0 = straight fin parallel to the axis; non-zero = spiral.
@export_range(-12.566, 12.566, 0.01) var twist_per_length: float = 0.0 :
	set(v):
		if twist_per_length == v: return
		twist_per_length = v
		emit_changed()


func _apply(p_ctx: BakeContext) -> void:
	if not enabled or count <= 0 or max_height <= 0.0:
		return
	if half_width <= 0.0 or t_end <= t_start:
		return
	var meta: Dictionary = (p_ctx.get_meta(&"tentacle_mesh_meta", {})
			if p_ctx.has_meta(&"tentacle_mesh_meta") else {})
	var length: float = meta.get("length", 0.4)
	if length <= 0.0:
		return

	# Precompute base azimuths for each fin.
	var fin_phis := PackedFloat32Array()
	fin_phis.resize(count)
	for i in count:
		fin_phis[i] = radial_offset + TAU * float(i) / float(count)

	# Pre-sample axial height taper into a fixed-width buffer so the C++
	# kernel doesn't need a Curve reference. 64 samples is overkill for
	# the smooth defaults but keeps Curve.sample() out of the hot path.
	const SAMPLES: int = 64
	var height_samples := PackedFloat32Array()
	height_samples.resize(SAMPLES)
	for i in SAMPLES:
		var u: float = float(i) / float(SAMPLES - 1)
		height_samples[i] = (height_curve.sample(u)
				if height_curve != null else _default_height_taper(u))

	p_ctx.vertices = ProceduralKernels.displace_fins(
			p_ctx.vertices, p_ctx.custom0, length,
			fin_phis, max_height, height_samples,
			half_width, t_start, t_end, twist_per_length)


# Default height envelope: smoothstep ramp at each end so the ridge fades
# in/out, full height across the middle. Matches the RibbonFeature default
# for visual consistency.
func _default_height_taper(p_u: float) -> float:
	var fade: float = 0.15
	if p_u < fade:
		return smoothstep(0.0, fade, p_u)
	if p_u > 1.0 - fade:
		return smoothstep(1.0, 1.0 - fade, p_u)
	return 1.0


# Slice 5H — silhouette bake. Same axial-strip pattern as Ribbon: a thin
# θ band per fin, sampled at axial increments and stamped as Gaussians.
# `twist_per_length` rotates φ along arc-length t (radians per unit t).
func bake_silhouette_contribution(p_ctx: SilhouetteBakeContext) -> void:
	if not enabled or count <= 0 or max_height <= 0.0:
		return
	if t_end <= t_start:
		return
	var sigma_theta: float = half_width
	const SAMPLES := 16
	for f in count:
		var phi: float = radial_offset + TAU * float(f) / float(count)
		for i in SAMPLES:
			var u: float = float(i) / float(SAMPLES - 1)
			var t: float = lerpf(t_start, t_end, u)
			var hsamp: float = (height_curve.sample(u)
					if height_curve != null else _default_height_taper(u))
			var amplitude: float = max_height * hsamp
			var sigma_t: float = (t_end - t_start) / float(SAMPLES) * 0.6
			var twisted_phi: float = phi + twist_per_length * t
			p_ctx.add_gaussian(t, twisted_phi, sigma_t, sigma_theta, amplitude)
