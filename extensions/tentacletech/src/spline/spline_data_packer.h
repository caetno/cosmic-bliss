#ifndef TENTACLETECH_SPLINE_DATA_PACKER_H
#define TENTACLETECH_SPLINE_DATA_PACKER_H

#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include "catmull_spline.h"

// Generic packer per §5.2: a CatmullSpline plus N per-point scalar arrays
// (e.g. girth_scale[1], asymmetry[2]) → flat RGBA32F-ready PackedFloat32Array.
//
// Pure utility — no TentacleTech-specific channel layout. Caller decides which
// channels to pack and in what order; the header records channel_count so the
// shader can reproduce the layout via texelFetch.
//
// Float layout:
//   [0..7]  header
//     [0] version (= 1.0)
//     [1] point_count
//     [2] segment_count
//     [3] channel_count
//     [4] distance_lut_size
//     [5] binormal_lut_size
//     [6] arc_length
//     [7] reserved
//   [next] segment_count × 16 floats — segment polynomial weights
//   [next] distance_lut_size floats — distance LUT
//   [next] binormal_lut_size × 3 floats — binormal LUT
//   [next] channel_count × point_count floats — per-point scalar channels
class SplineDataPacker : public godot::RefCounted {
	GDCLASS(SplineDataPacker, godot::RefCounted)

public:
	static constexpr int HEADER_FLOAT_COUNT = 8;
	static constexpr float PACKER_VERSION = 1.0f;

	SplineDataPacker();
	~SplineDataPacker();

	// p_per_point_scalars is an Array of PackedFloat32Array, each sized to
	// p_spline.get_point_count(). Mismatched sizes are zero-padded/truncated
	// to the spline's point count.
	static godot::PackedFloat32Array pack(
			const godot::Ref<CatmullSpline> &p_spline,
			const godot::Array &p_per_point_scalars);

	// Creates an RGBA32F ImageTexture from packed data. Width is in pixels (1
	// pixel = 4 floats); height = ceil(packed.size / (4 * width)). The packed
	// array is zero-padded to a multiple of (4 × width) floats before upload.
	static godot::Ref<godot::ImageTexture> create_texture(
			const godot::PackedFloat32Array &p_packed,
			int p_width);

	// Total floats produced by pack() given the inputs. Useful for sizing GPU
	// buffers without actually performing the pack.
	static int compute_packed_size(
			int p_segment_count,
			int p_distance_lut_size,
			int p_binormal_lut_size,
			int p_channel_count,
			int p_point_count);

protected:
	static void _bind_methods();
};

#endif // TENTACLETECH_SPLINE_DATA_PACKER_H
