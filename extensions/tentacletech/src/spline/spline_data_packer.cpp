#include "spline_data_packer.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>

using namespace godot;

SplineDataPacker::SplineDataPacker() {}
SplineDataPacker::~SplineDataPacker() {}

int SplineDataPacker::compute_packed_size(
		int p_segment_count,
		int p_distance_lut_size,
		int p_binormal_lut_size,
		int p_channel_count,
		int p_point_count) {
	return HEADER_FLOAT_COUNT
			+ p_segment_count * CatmullSpline::SEGMENT_FLOAT_COUNT
			+ p_distance_lut_size
			+ p_binormal_lut_size * 3
			+ p_channel_count * p_point_count;
}

PackedFloat32Array SplineDataPacker::pack(
		const Ref<CatmullSpline> &p_spline,
		const Array &p_per_point_scalars) {
	PackedFloat32Array out;
	pack_into(p_spline, p_per_point_scalars, out);
	return out;
}

void SplineDataPacker::pack_into(
		const Ref<CatmullSpline> &p_spline,
		const Array &p_per_point_scalars,
		PackedFloat32Array &r_out) {
	if (p_spline.is_null()) {
		r_out.resize(0);
		return;
	}

	int point_count = p_spline->get_point_count();
	int segment_count = p_spline->get_segment_count();
	int dist_lut_size = p_spline->get_distance_lut_sample_count();
	int bn_lut_size = p_spline->get_binormal_lut_sample_count();
	int channel_count = p_per_point_scalars.size();

	int total = compute_packed_size(
			segment_count, dist_lut_size, bn_lut_size, channel_count, point_count);
	if (r_out.size() != total) {
		r_out.resize(total);
	}
	float *ptr = r_out.ptrw();
	int offset = 0;

	// Header.
	ptr[offset++] = PACKER_VERSION;
	ptr[offset++] = (float)point_count;
	ptr[offset++] = (float)segment_count;
	ptr[offset++] = (float)channel_count;
	ptr[offset++] = (float)dist_lut_size;
	ptr[offset++] = (float)bn_lut_size;
	ptr[offset++] = p_spline->get_arc_length();
	ptr[offset++] = 0.0f;

	// Segment weights.
	PackedFloat32Array weights = p_spline->get_segment_weights();
	const float *w_ptr = weights.ptr();
	int w_n = weights.size();
	for (int i = 0; i < w_n; i++) {
		ptr[offset++] = w_ptr[i];
	}

	// Distance LUT.
	PackedFloat32Array dist = p_spline->get_distance_lut();
	const float *d_ptr = dist.ptr();
	for (int i = 0; i < dist_lut_size; i++) {
		ptr[offset++] = d_ptr[i];
	}

	// Binormal LUT (3 floats per entry).
	PackedVector3Array bn = p_spline->get_binormal_lut();
	const Vector3 *b_ptr = bn.ptr();
	for (int i = 0; i < bn_lut_size; i++) {
		ptr[offset++] = b_ptr[i].x;
		ptr[offset++] = b_ptr[i].y;
		ptr[offset++] = b_ptr[i].z;
	}

	// Per-point scalar channels. Each entry is a PackedFloat32Array of
	// length point_count; mismatched sizes are zero-padded or truncated.
	for (int c = 0; c < channel_count; c++) {
		PackedFloat32Array chan = p_per_point_scalars[c];
		const float *cp = chan.ptr();
		int chan_n = chan.size();
		for (int i = 0; i < point_count; i++) {
			ptr[offset++] = (i < chan_n) ? cp[i] : 0.0f;
		}
	}
}

Ref<ImageTexture> SplineDataPacker::create_texture(
		const PackedFloat32Array &p_packed,
		int p_width) {
	int width = MAX(p_width, 1);
	int floats_per_row = width * 4;
	int n = p_packed.size();
	int height = (n + floats_per_row - 1) / floats_per_row;
	if (height < 1) {
		height = 1;
	}

	int padded = floats_per_row * height;
	PackedFloat32Array padded_data;
	padded_data.resize(padded);
	float *dst = padded_data.ptrw();
	const float *src = p_packed.ptr();
	for (int i = 0; i < n; i++) {
		dst[i] = src[i];
	}
	for (int i = n; i < padded; i++) {
		dst[i] = 0.0f;
	}

	PackedByteArray bytes;
	bytes.resize(padded * sizeof(float));
	uint8_t *bdst = bytes.ptrw();
	const uint8_t *fsrc = (const uint8_t *)dst;
	for (int i = 0; i < padded * (int)sizeof(float); i++) {
		bdst[i] = fsrc[i];
	}

	Ref<Image> img = Image::create_from_data(width, height, false, Image::FORMAT_RGBAF, bytes);
	return ImageTexture::create_from_image(img);
}

void SplineDataPacker::_bind_methods() {
	ClassDB::bind_static_method("SplineDataPacker", D_METHOD("pack", "spline", "per_point_scalars"), &SplineDataPacker::pack);
	ClassDB::bind_static_method("SplineDataPacker", D_METHOD("create_texture", "packed", "width"), &SplineDataPacker::create_texture);
	ClassDB::bind_static_method("SplineDataPacker", D_METHOD("compute_packed_size", "segment_count", "distance_lut_size", "binormal_lut_size", "channel_count", "point_count"), &SplineDataPacker::compute_packed_size);

	BIND_CONSTANT(HEADER_FLOAT_COUNT);
}
