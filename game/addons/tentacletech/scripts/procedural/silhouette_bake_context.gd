@tool
class_name SilhouetteBakeContext
extends RefCounted
## Slice 5H — feature silhouette bake context. Carried through the
## TentacleMesh feature pipeline alongside the mesh `BakeContext`, but
## scoped to the 2D radial-perturbation field that 5F (canal walls) +
## type-1/2/4 contact paths consume.
##
## The image is `axial_resolution × angular_resolution` R32F. Stored
## value at (s, theta) is OUTWARD radial perturbation in metres, ADDED
## to the smooth `girth_scale × base_radius` at contact threshold time
## by the PBDSolver / Orifice paths.
##
## Sampling convention:
## - U axis (image x = column): arc-length s ∈ [0, 1] along the rest
##   chain. `s = 0` is the base (anchor), `s = 1` is the tip.
## - V axis (image y = row): body-frame angular coordinate
##   θ ∈ [0, 2π) measured around the rest tangent. The body-frame
##   reference axis (θ = 0) is the parallel-transported X axis from
##   the chain's anchor frame (slice 5H spec divergence (b) in the
##   status row — this is the simplest stable choice; twist tracking
##   is a future-work item).
##
## Sub-Claude design note: features that anchor to "axial t in
## [0, 1]" can convert directly to image U via `image_u_from_axial_t`.
## Features that anchor to specific bones / arc-length values use the
## `arc_length_to_image_u` helper. Negative perturbations are legal
## (sucker pits, scars).

const AXIAL_RESOLUTION := 256
const ANGULAR_RESOLUTION := 16


# Total chain arc length in metres. Authored by `TentacleMesh.bake_feature_silhouette`
# from the `length` property. Required for axial-position-in-metres
# inputs (some features take spacing in metres).
var total_arc_length: float = 0.4

# The R32F target image. Constructed externally and passed in so the
# bake driver can re-use a cached image across rebakes.
var image: Image = null


static func make_image() -> Image:
	# Initialize to zero (no perturbation). FORMAT_RF = single-channel
	# float32 — matches the silhouette sampler's expectations.
	var img := Image.create(AXIAL_RESOLUTION, ANGULAR_RESOLUTION, false, Image.FORMAT_RF)
	img.fill(Color(0, 0, 0, 0))
	return img


# Axial t ∈ [0, 1] → image U (integer column index). Clamps to range.
func image_u_from_axial_t(p_t: float) -> int:
	var u: float = clampf(p_t, 0.0, 1.0)
	var col: int = int(round(u * float(AXIAL_RESOLUTION - 1)))
	return col


# Arc-length s in metres → image U. Same as `image_u_from_axial_t` but
# scales by `total_arc_length` first.
func arc_length_to_image_u(p_s: float) -> int:
	if total_arc_length <= 1e-6:
		return 0
	return image_u_from_axial_t(p_s / total_arc_length)


# Body-frame angle θ ∈ [0, 2π) → image V (integer row index). Wraps.
func image_v_from_theta(p_theta: float) -> int:
	var t: float = fmod(fmod(p_theta, TAU) + TAU, TAU)
	var row: int = int(round(t / TAU * float(ANGULAR_RESOLUTION))) % ANGULAR_RESOLUTION
	return row


# Add `p_amplitude` (metres) to image[u, v] without bounds-checking.
# Internal helper; callers should clamp/wrap before calling.
func _add(p_u: int, p_v: int, p_amplitude: float) -> void:
	if p_u < 0 or p_u >= AXIAL_RESOLUTION:
		return
	# V wraps.
	var v: int = ((p_v % ANGULAR_RESOLUTION) + ANGULAR_RESOLUTION) % ANGULAR_RESOLUTION
	var existing: float = image.get_pixel(p_u, v).r
	image.set_pixel(p_u, v, Color(existing + p_amplitude, 0, 0, 0))


# Add a 2D Gaussian bump centered at (s_axial_t, theta) in image space.
# `sigma_axial_t` is half-width along the s axis as a FRACTION of the
# total arc length (i.e. axial_t units). `sigma_theta` is half-width
# along the angular axis in radians. `amplitude` is the peak value in
# metres (positive = outward bump, negative = inward pit).
#
# The Gaussian is truncated at 3σ in both axes for compute economy.
# Wraps in θ so a bump near θ = 0 / θ = 2π splits cleanly.
func add_gaussian(p_axial_t: float, p_theta: float,
		p_sigma_axial_t: float, p_sigma_theta: float,
		p_amplitude: float) -> void:
	if absf(p_amplitude) < 1e-7:
		return
	var sigma_u: float = maxf(p_sigma_axial_t, 1e-4) * float(AXIAL_RESOLUTION)
	var sigma_v: float = maxf(p_sigma_theta / TAU, 1e-4) * float(ANGULAR_RESOLUTION)
	var center_u: float = clampf(p_axial_t, 0.0, 1.0) * float(AXIAL_RESOLUTION - 1)
	var theta_norm: float = fmod(fmod(p_theta, TAU) + TAU, TAU)
	var center_v: float = theta_norm / TAU * float(ANGULAR_RESOLUTION)
	# Cover ±3σ in pixel space.
	var u_lo: int = int(floor(center_u - 3.0 * sigma_u))
	var u_hi: int = int(ceil(center_u + 3.0 * sigma_u))
	u_lo = clampi(u_lo, 0, AXIAL_RESOLUTION - 1)
	u_hi = clampi(u_hi, 0, AXIAL_RESOLUTION - 1)
	var v_span: int = int(ceil(3.0 * sigma_v))
	for u in range(u_lo, u_hi + 1):
		var du: float = (float(u) - center_u) / sigma_u
		var u_factor: float = exp(-0.5 * du * du)
		for vv in range(-v_span, v_span + 1):
			var dv: float = float(vv) / sigma_v
			var v_factor: float = exp(-0.5 * dv * dv)
			var v_idx: int = int(round(center_v)) + vv
			_add(u, v_idx, p_amplitude * u_factor * v_factor)


# Add a band-pulse along the entire θ axis at axial t with σ in axial_t.
# Used by RibsFeature: the ridge spans every θ but pulses axially.
func add_axial_ring(p_axial_t: float, p_sigma_axial_t: float,
		p_amplitude: float) -> void:
	if absf(p_amplitude) < 1e-7:
		return
	var sigma_u: float = maxf(p_sigma_axial_t, 1e-4) * float(AXIAL_RESOLUTION)
	var center_u: float = clampf(p_axial_t, 0.0, 1.0) * float(AXIAL_RESOLUTION - 1)
	var u_lo: int = clampi(int(floor(center_u - 3.0 * sigma_u)), 0, AXIAL_RESOLUTION - 1)
	var u_hi: int = clampi(int(ceil(center_u + 3.0 * sigma_u)), 0, AXIAL_RESOLUTION - 1)
	for u in range(u_lo, u_hi + 1):
		var du: float = (float(u) - center_u) / sigma_u
		var u_factor: float = exp(-0.5 * du * du)
		var contribution: float = p_amplitude * u_factor
		for v in ANGULAR_RESOLUTION:
			_add(u, v, contribution)


# Add a band-pulse along an axial range at fixed θ ± σ_theta. Used by
# RibbonFeature (broad axial ridge across narrow θ band).
func add_axial_strip(p_axial_t_start: float, p_axial_t_end: float,
		p_theta: float, p_sigma_theta: float, p_amplitude: float) -> void:
	if absf(p_amplitude) < 1e-7:
		return
	var u_lo: int = image_u_from_axial_t(min(p_axial_t_start, p_axial_t_end))
	var u_hi: int = image_u_from_axial_t(max(p_axial_t_start, p_axial_t_end))
	var sigma_v: float = maxf(p_sigma_theta / TAU, 1e-4) * float(ANGULAR_RESOLUTION)
	var theta_norm: float = fmod(fmod(p_theta, TAU) + TAU, TAU)
	var center_v: float = theta_norm / TAU * float(ANGULAR_RESOLUTION)
	var v_span: int = int(ceil(3.0 * sigma_v))
	for u in range(u_lo, u_hi + 1):
		for vv in range(-v_span, v_span + 1):
			var dv: float = float(vv) / sigma_v
			var v_factor: float = exp(-0.5 * dv * dv)
			var v_idx: int = int(round(center_v)) + vv
			_add(u, v_idx, p_amplitude * v_factor)
