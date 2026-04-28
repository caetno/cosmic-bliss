@tool
class_name GirthBaker
extends RefCounted
## Auto-baked girth profile per §5.4 of TentacleTech_Architecture.md.
##
## Walks the mesh vertices, groups by quantized arc-axis coordinate, takes the
## max radial extent per group, then resamples evenly to 256 bins. Output is
## an RF (single-channel float) ImageTexture sized 256×1 plus the rest_length
## scalar. The values written to the texture are *normalized to [0,1]* against
## the peak radial extent — the consumer multiplies by the peak (or by the
## tentacle's nominal base_radius) when it needs absolute girth.
##
## §5.0 partition note: this is mesh-derived data. The mesh defines the
## silhouette (knots, ribs, bulbs); GirthBaker just samples what the mesh
## already authored. Physics and rendering both consume the same bake, which
## is what keeps EntryInteraction compression consistent with what's drawn.

const RESAMPLED_BINS := 256
const RAW_BINS := 128 # quantization step before resampling


## Bake from a flat positions array. p_axis selects which mesh-local axis is
## the arc direction (0=X, 1=Y, 2=Z; default Z per §10.1).
##
## Returns a Dictionary:
##   "girth_texture" — ImageTexture, FORMAT_RF, 256×1, values in [0,1]
##   "girth_samples" — PackedFloat32Array, the 256 normalized samples
##                     written into the texture; exposed so headless
##                     consumers (mass distribution, tests) can read the
##                     curve without round-tripping through the renderer
##                     (ImageTexture.get_image() returns dummy bytes
##                     under --headless)
##   "rest_length"   — float, max - min along arc axis
##   "peak_radius"   — float, the max radial extent before normalization
##   "min_radius"    — float, the min radial extent observed
static func bake_from_mesh_data(p_positions: PackedVector3Array, p_axis: int = 2) -> Dictionary:
	var result := {
		"girth_texture": null,
		"girth_samples": PackedFloat32Array(),
		"rest_length": 0.0,
		"peak_radius": 0.0,
		"min_radius": 0.0,
	}
	var n: int = p_positions.size()
	if n < 2:
		# Degenerate input — return a uniform 1.0 placeholder so consumers
		# don't fall back to undefined behavior.
		result["girth_texture"] = _make_uniform_texture(1.0)
		result["girth_samples"] = _make_uniform_samples(1.0)
		return result

	var axis_idx: int = clampi(p_axis, 0, 2)

	# Pass 1: arc-axis range.
	var arc_min := INF
	var arc_max := -INF
	for i in n:
		var v := p_positions[i]
		var a: float = _axis_value(v, axis_idx)
		if a < arc_min: arc_min = a
		if a > arc_max: arc_max = a
	var rest_length: float = arc_max - arc_min
	if rest_length < 1e-6:
		result["girth_texture"] = _make_uniform_texture(1.0)
		result["girth_samples"] = _make_uniform_samples(1.0)
		return result

	# Pass 2: bucket by quantized arc, track max radial extent per bucket.
	# We use RAW_BINS coarse buckets first because the mesh's vertex rings
	# are not perfectly aligned to 256-bin spacing; resampling those into
	# 256 final bins via linear interp is cleaner than direct bucketing.
	var raw_max := PackedFloat32Array()
	raw_max.resize(RAW_BINS)
	for i in RAW_BINS:
		raw_max[i] = -1.0

	for i in n:
		var v := p_positions[i]
		var a: float = _axis_value(v, axis_idx)
		var t: float = (a - arc_min) / rest_length
		t = clampf(t, 0.0, 1.0)
		var bin: int = clampi(int(t * float(RAW_BINS - 1)), 0, RAW_BINS - 1)
		var radial: float = _radial_extent(v, axis_idx)
		if radial > raw_max[bin]:
			raw_max[bin] = radial

	# Fill empty bins (no vertices fell into them) by interpolating from
	# nearest non-empty neighbors. A pure cylinder with rings every k bins
	# leaves intermediate bins empty; we want to interpolate, not zero them.
	var first_filled: int = -1
	var last_filled: int = -1
	for i in RAW_BINS:
		if raw_max[i] >= 0.0:
			if first_filled < 0:
				first_filled = i
			last_filled = i
	if first_filled < 0:
		# No usable data — should be impossible with n >= 2 unless all
		# vertices are degenerate. Bail to placeholder.
		result["girth_texture"] = _make_uniform_texture(1.0)
		result["girth_samples"] = _make_uniform_samples(1.0)
		return result

	# Extend the first/last filled values to the array ends.
	for i in range(first_filled):
		raw_max[i] = raw_max[first_filled]
	for i in range(last_filled + 1, RAW_BINS):
		raw_max[i] = raw_max[last_filled]
	# Interpolate any internal gaps.
	var i_search: int = first_filled
	while i_search < last_filled:
		if raw_max[i_search + 1] >= 0.0:
			i_search += 1
			continue
		# Find next filled bin.
		var j: int = i_search + 1
		while j <= last_filled and raw_max[j] < 0.0:
			j += 1
		var v0: float = raw_max[i_search]
		var v1: float = raw_max[j]
		var span: int = j - i_search
		for k in range(1, span):
			var t: float = float(k) / float(span)
			raw_max[i_search + k] = lerpf(v0, v1, t)
		i_search = j

	# Track peak / min radius from the filled values for the consumer.
	var peak: float = 0.0
	var min_r: float = INF
	for i in RAW_BINS:
		if raw_max[i] > peak: peak = raw_max[i]
		if raw_max[i] < min_r: min_r = raw_max[i]
	if peak <= 0.0:
		result["girth_texture"] = _make_uniform_texture(1.0)
		result["girth_samples"] = _make_uniform_samples(1.0)
		return result

	# Resample to RESAMPLED_BINS via linear interpolation along the raw
	# array. Normalize against the peak so the texture is in [0,1].
	var bytes := PackedByteArray()
	bytes.resize(RESAMPLED_BINS * 4) # one float32 per bin
	# Build a typed view: write floats in order, then encode as bytes.
	var floats := PackedFloat32Array()
	floats.resize(RESAMPLED_BINS)
	for i in RESAMPLED_BINS:
		var t: float = float(i) / float(RESAMPLED_BINS - 1)
		var raw_pos: float = t * float(RAW_BINS - 1)
		var lo: int = clampi(int(raw_pos), 0, RAW_BINS - 1)
		var hi: int = clampi(lo + 1, 0, RAW_BINS - 1)
		var f: float = raw_pos - float(lo)
		var v: float = lerpf(raw_max[lo], raw_max[hi], f)
		floats[i] = clampf(v / peak, 0.0, 1.0)

	# Reinterpret floats array as bytes — Godot's PackedByteArray exposes
	# encode_float for this.
	for i in RESAMPLED_BINS:
		bytes.encode_float(i * 4, floats[i])

	var img := Image.create_from_data(RESAMPLED_BINS, 1, false, Image.FORMAT_RF, bytes)
	result["girth_texture"] = ImageTexture.create_from_image(img)
	result["girth_samples"] = floats
	result["rest_length"] = rest_length
	result["peak_radius"] = peak
	result["min_radius"] = min_r
	return result


static func _axis_value(p_v: Vector3, p_axis: int) -> float:
	match p_axis:
		0: return p_v.x
		1: return p_v.y
		_: return p_v.z


static func _radial_extent(p_v: Vector3, p_arc_axis: int) -> float:
	# Distance from arc axis = sqrt of the sum of squared lateral components.
	match p_arc_axis:
		0: return sqrt(p_v.y * p_v.y + p_v.z * p_v.z)
		1: return sqrt(p_v.x * p_v.x + p_v.z * p_v.z)
		_: return sqrt(p_v.x * p_v.x + p_v.y * p_v.y)


static func _make_uniform_texture(p_value: float) -> ImageTexture:
	var bytes := PackedByteArray()
	bytes.resize(RESAMPLED_BINS * 4)
	for i in RESAMPLED_BINS:
		bytes.encode_float(i * 4, p_value)
	var img := Image.create_from_data(RESAMPLED_BINS, 1, false, Image.FORMAT_RF, bytes)
	return ImageTexture.create_from_image(img)


static func _make_uniform_samples(p_value: float) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(RESAMPLED_BINS)
	for i in RESAMPLED_BINS:
		s[i] = p_value
	return s
