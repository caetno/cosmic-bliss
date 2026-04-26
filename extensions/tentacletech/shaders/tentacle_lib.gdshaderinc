// TentacleTech shader library — spline + per-particle channel sampling.
//
// Spec: docs/architecture/TentacleTech_Architecture.md §5.2 + §5.3.
// Layout matches src/spline/spline_data_packer.cpp's pack() output.
//
// Texture (sampler2D, RGBA32F, width = spline_data_width, height = 1):
//   Header (8 floats, pixels [0..1]):
//     [0] version (= 1.0)
//     [1] point_count
//     [2] segment_count
//     [3] channel_count
//     [4] distance_lut_size
//     [5] binormal_lut_size
//     [6] arc_length
//     [7] reserved
//   Segment weights (segment_count × 16 floats):
//     For segment s, axis c (0=x,1=y,2=z), power p (0=const,1=lin,2=quad,3=cub):
//       float idx = HEADER + s*16 + c*4 + p
//   Distance LUT (distance_lut_size floats):
//   Binormal LUT (binormal_lut_size × 3 floats — interleaved x,y,z):
//   Channels (channel_count × point_count floats):
//     channel 0 = girth_scale
//     channel 1 = asymmetry.x
//     channel 2 = asymmetry.y

const int TT_HEADER_FLOAT_COUNT = 8;
const int TT_CHANNEL_GIRTH_SCALE = 0;
const int TT_CHANNEL_ASYM_X = 1;
const int TT_CHANNEL_ASYM_Y = 2;

// Fetch one packed float by linear index (treating the RGBA32F texture as a
// flat float array, row-major).
float tt_fetch_float(sampler2D tex, int width, int float_idx) {
	int pixel_idx = float_idx >> 2;       // / 4
	int comp = float_idx & 3;             // % 4
	ivec2 coord = ivec2(pixel_idx % width, pixel_idx / width);
	vec4 px = texelFetch(tex, coord, 0);
	if (comp == 0) return px.r;
	if (comp == 1) return px.g;
	if (comp == 2) return px.b;
	return px.a;
}

// Header accessors — the header occupies floats [0..7]. Returned as ints
// where appropriate (the packer writes them as floats; we round-trip safely
// because all values fit in a float exactly).

int tt_point_count(sampler2D tex, int width) {
	return int(tt_fetch_float(tex, width, 1));
}
int tt_segment_count(sampler2D tex, int width) {
	return int(tt_fetch_float(tex, width, 2));
}
int tt_channel_count(sampler2D tex, int width) {
	return int(tt_fetch_float(tex, width, 3));
}
int tt_dist_lut_size(sampler2D tex, int width) {
	return int(tt_fetch_float(tex, width, 4));
}
int tt_bn_lut_size(sampler2D tex, int width) {
	return int(tt_fetch_float(tex, width, 5));
}
float tt_arc_length(sampler2D tex, int width) {
	return tt_fetch_float(tex, width, 6);
}

// Offset of the segment-weights block inside the packed buffer.
int tt_segments_offset() { return TT_HEADER_FLOAT_COUNT; }
int tt_dist_lut_offset(int segment_count) {
	return TT_HEADER_FLOAT_COUNT + segment_count * 16;
}
int tt_bn_lut_offset(int segment_count, int dist_lut_size) {
	return tt_dist_lut_offset(segment_count) + dist_lut_size;
}
int tt_channels_offset(int segment_count, int dist_lut_size, int bn_lut_size) {
	return tt_bn_lut_offset(segment_count, dist_lut_size) + bn_lut_size * 3;
}

// distance_to_parameter via binary search through the distance LUT.
// LUT entries are arc-distance at sample points uniformly spaced in t∈[0,1].
float tt_distance_to_parameter(sampler2D tex, int width, float distance,
		int segment_count, int dist_lut_size) {
	float arc_len = tt_fetch_float(tex, width, 6);
	if (arc_len <= 0.0 || dist_lut_size < 2) return 0.0;
	if (distance <= 0.0) return 0.0;
	if (distance >= arc_len) return 1.0;

	int dist_offset = tt_dist_lut_offset(segment_count);

	int lo = 0;
	int hi = dist_lut_size - 1;
	for (int iter = 0; iter < 16; iter++) {
		if (lo + 1 >= hi) break;
		int mid = (lo + hi) >> 1;
		float d_mid = tt_fetch_float(tex, width, dist_offset + mid);
		if (d_mid <= distance) lo = mid;
		else hi = mid;
	}
	float d0 = tt_fetch_float(tex, width, dist_offset + lo);
	float d1 = tt_fetch_float(tex, width, dist_offset + hi);
	float t0 = float(lo) / float(dist_lut_size - 1);
	float t1 = float(hi) / float(dist_lut_size - 1);
	if (d1 - d0 < 1e-12) return t0;
	return t0 + (distance - d0) / (d1 - d0) * (t1 - t0);
}

// Evaluate the spline polynomial at parameter t∈[0,1]. Returns position in
// tentacle-local space (matches the C++ Tentacle::_update_spline_data_texture
// transform).
vec3 tt_evaluate_spline_position(sampler2D tex, int width, float t,
		int segment_count) {
	float t_clamped = clamp(t, 0.0, 1.0);
	float scaled = t_clamped * float(segment_count);
	int seg = int(floor(scaled));
	if (seg >= segment_count) seg = segment_count - 1;
	float lt = scaled - float(seg);
	float lt2 = lt * lt;
	float lt3 = lt2 * lt;

	int seg_off = tt_segments_offset() + seg * 16;
	// data[c*4 + p]: c = axis (0..2), p = power (0..3).
	vec3 pos;
	pos.x = tt_fetch_float(tex, width, seg_off + 0)
			+ tt_fetch_float(tex, width, seg_off + 1) * lt
			+ tt_fetch_float(tex, width, seg_off + 2) * lt2
			+ tt_fetch_float(tex, width, seg_off + 3) * lt3;
	pos.y = tt_fetch_float(tex, width, seg_off + 4)
			+ tt_fetch_float(tex, width, seg_off + 5) * lt
			+ tt_fetch_float(tex, width, seg_off + 6) * lt2
			+ tt_fetch_float(tex, width, seg_off + 7) * lt3;
	pos.z = tt_fetch_float(tex, width, seg_off + 8)
			+ tt_fetch_float(tex, width, seg_off + 9) * lt
			+ tt_fetch_float(tex, width, seg_off + 10) * lt2
			+ tt_fetch_float(tex, width, seg_off + 11) * lt3;
	return pos;
}

// Velocity (non-normalized tangent direction) at parameter t.
vec3 tt_evaluate_spline_velocity(sampler2D tex, int width, float t,
		int segment_count) {
	float t_clamped = clamp(t, 0.0, 1.0);
	float scaled = t_clamped * float(segment_count);
	int seg = int(floor(scaled));
	if (seg >= segment_count) seg = segment_count - 1;
	float lt = scaled - float(seg);
	float lt2 = lt * lt;

	int seg_off = tt_segments_offset() + seg * 16;
	vec3 v;
	v.x = tt_fetch_float(tex, width, seg_off + 1)
			+ 2.0 * tt_fetch_float(tex, width, seg_off + 2) * lt
			+ 3.0 * tt_fetch_float(tex, width, seg_off + 3) * lt2;
	v.y = tt_fetch_float(tex, width, seg_off + 5)
			+ 2.0 * tt_fetch_float(tex, width, seg_off + 6) * lt
			+ 3.0 * tt_fetch_float(tex, width, seg_off + 7) * lt2;
	v.z = tt_fetch_float(tex, width, seg_off + 9)
			+ 2.0 * tt_fetch_float(tex, width, seg_off + 10) * lt
			+ 3.0 * tt_fetch_float(tex, width, seg_off + 11) * lt2;
	return v;
}

// Sample the parallel-transport binormal LUT at parameter t. Linear blend
// between adjacent samples; the result is approximately unit-length for
// smooth splines but should be re-orthogonalized by the caller against the
// tangent.
vec3 tt_evaluate_spline_binormal(sampler2D tex, int width, float t,
		int segment_count, int dist_lut_size, int bn_lut_size) {
	if (bn_lut_size < 2) return vec3(0.0, 1.0, 0.0);
	float t_clamped = clamp(t, 0.0, 1.0);
	int last = bn_lut_size - 1;
	float scaled = t_clamped * float(last);
	int idx = int(floor(scaled));
	if (idx >= last) idx = last - 1;
	float lerp_t = scaled - float(idx);

	int bn_offset = tt_bn_lut_offset(segment_count, dist_lut_size);
	vec3 b0 = vec3(
			tt_fetch_float(tex, width, bn_offset + idx * 3 + 0),
			tt_fetch_float(tex, width, bn_offset + idx * 3 + 1),
			tt_fetch_float(tex, width, bn_offset + idx * 3 + 2));
	vec3 b1 = vec3(
			tt_fetch_float(tex, width, bn_offset + (idx + 1) * 3 + 0),
			tt_fetch_float(tex, width, bn_offset + (idx + 1) * 3 + 1),
			tt_fetch_float(tex, width, bn_offset + (idx + 1) * 3 + 2));
	return mix(b0, b1, lerp_t);
}

// Build an orthonormal frame (tangent, normal, binormal) at parameter t.
void tt_evaluate_spline_frame(sampler2D tex, int width, float t,
		int segment_count, int dist_lut_size, int bn_lut_size,
		out vec3 tangent, out vec3 normal, out vec3 binormal) {
	tangent = normalize(tt_evaluate_spline_velocity(tex, width, t, segment_count));
	binormal = tt_evaluate_spline_binormal(tex, width, t, segment_count, dist_lut_size, bn_lut_size);
	// Re-orthogonalize: project binormal off tangent, then re-derive normal.
	binormal = normalize(binormal - tangent * dot(binormal, tangent));
	normal = normalize(cross(tangent, binormal));
	binormal = normalize(cross(normal, tangent));
}

// Linear interpolation across a per-particle scalar channel (one float per
// point in [0..point_count-1]; t∈[0,1] selects between adjacent points).
float tt_interpolate_channel(sampler2D tex, int width, int channel_idx,
		float t, int point_count, int segment_count, int dist_lut_size,
		int bn_lut_size) {
	if (point_count < 1) return 0.0;
	if (point_count == 1) {
		int chan_offset = tt_channels_offset(segment_count, dist_lut_size, bn_lut_size)
				+ channel_idx * point_count;
		return tt_fetch_float(tex, width, chan_offset);
	}
	float t_clamped = clamp(t, 0.0, 1.0);
	float scaled = t_clamped * float(point_count - 1);
	int idx = int(floor(scaled));
	if (idx >= point_count - 1) idx = point_count - 2;
	float lerp_t = scaled - float(idx);

	int chan_offset = tt_channels_offset(segment_count, dist_lut_size, bn_lut_size)
			+ channel_idx * point_count;
	float v0 = tt_fetch_float(tex, width, chan_offset + idx);
	float v1 = tt_fetch_float(tex, width, chan_offset + idx + 1);
	return mix(v0, v1, lerp_t);
}

float tt_interpolate_particle_girth_scale(sampler2D tex, int width, float t,
		int point_count, int segment_count, int dist_lut_size, int bn_lut_size) {
	return tt_interpolate_channel(tex, width, TT_CHANNEL_GIRTH_SCALE, t,
			point_count, segment_count, dist_lut_size, bn_lut_size);
}

vec2 tt_interpolate_particle_asymmetry(sampler2D tex, int width, float t,
		int point_count, int segment_count, int dist_lut_size, int bn_lut_size) {
	float ax = tt_interpolate_channel(tex, width, TT_CHANNEL_ASYM_X, t,
			point_count, segment_count, dist_lut_size, bn_lut_size);
	float ay = tt_interpolate_channel(tex, width, TT_CHANNEL_ASYM_Y, t,
			point_count, segment_count, dist_lut_size, bn_lut_size);
	return vec2(ax, ay);
}

// Apply the §5.3 asymmetric squeeze to a lateral (x,y) offset. asym is the
// signed asymmetry vector; magnitude must be ≤ ~0.5 for stability (the C++
// solver clamps to ASYMMETRY_MAGNITUDE_CAP = 0.5).
vec2 tt_apply_asymmetry(vec2 lateral, vec2 asym) {
	float mag = length(asym);
	if (mag < 0.001) return lateral;
	vec2 axis = asym / mag;
	vec2 perp = vec2(-axis.y, axis.x);
	float along = dot(lateral, axis) * (1.0 - mag);
	float across = dot(lateral, perp) * (1.0 + mag * 0.5);
	return axis * along + perp * across;
}
