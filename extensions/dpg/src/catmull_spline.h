#ifndef DPG_CATMULL_SPLINE_H
#define DPG_CATMULL_SPLINE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <vector>

/// Centripetal Catmull-Rom spline with arc-length parameterization and
/// parallel-transport binormal frames. Precomputes polynomial weight matrices
/// per segment so that both CPU and GPU can evaluate position/tangent cheaply.
///
/// Ported from com.naelstrof.splines CatmullSpline.cs (Unity).
class CatmullSpline : public godot::RefCounted {
	GDCLASS(CatmullSpline, godot::RefCounted)

public:
	/// Maximum number of spline segments stored in the GPU data texture.
	static constexpr int SUB_SPLINE_COUNT = 8;
	/// Number of entries in the arc-length distance lookup table.
	static constexpr int DISTANCE_LUT_COUNT = 32;
	/// Number of entries in the parallel-transport binormal lookup table.
	static constexpr int BINORMAL_LUT_COUNT = 32;
	/// Total float count when packed for GPU: pointCount(1) + arcLength(1)
	/// + weights(SUB_SPLINE_COUNT*16) + distanceLUT + binormalLUT(count*3).
	static constexpr int GPU_DATA_FLOAT_COUNT = 2 + SUB_SPLINE_COUNT * 16 + DISTANCE_LUT_COUNT + BINORMAL_LUT_COUNT * 3;

	CatmullSpline();
	~CatmullSpline();

	/// Rebuild the spline from an ordered list of world-space control points.
	/// Requires at least 2 points. Invalidates distance and binormal LUTs.
	void set_points(const godot::PackedVector3Array &p_points);

	/// Rebuild like [method set_points], but override the leading virtual
	/// control point so the Catmull-Rom tangent at t=0 aligns with
	/// [code]p_entry_tangent[/code]. The virtual point is placed at
	/// [code]p_points[0] - entry_tangent * distance(p_points[0], p_points[1])[/code]
	/// instead of the default mirrored position
	/// [code]p_points[0] + (p_points[0] - p_points[1])[/code].
	///
	/// Used by the penetrator spline so its entry tangent respects the
	/// penetrator's forward axis rather than being arbitrarily chosen by the
	/// direction from [code]p_points[0][/code] (the penetrator root) to
	/// [code]p_points[1][/code] (the first orifice marker). Without this, the
	/// deformed mesh kinks at the base whenever pen_forward disagrees with
	/// that marker direction.
	///
	/// [code]p_entry_tangent[/code] need not be pre-normalized — this method
	/// normalizes it. A zero vector falls back to [method set_points] behaviour.
	void set_points_with_entry_tangent(const godot::PackedVector3Array &p_points,
			const godot::Vector3 &p_entry_tangent);
	/// Return the number of control points (segments + 1), or 0 if empty.
	int get_point_count() const;
	/// Return the number of piecewise cubic segments.
	int get_segment_count() const;

	/// Evaluate world-space position at parameter [code]t[/code] in [0, 1].
	godot::Vector3 evaluate_position(double p_t) const;
	/// Evaluate the first derivative (tangent) at parameter [code]t[/code].
	/// Not normalized — magnitude reflects parameterization speed.
	godot::Vector3 evaluate_tangent(double p_t) const;
	/// Evaluate the second derivative (acceleration) at parameter [code]t[/code].
	godot::Vector3 evaluate_acceleration(double p_t) const;

	/// Return total arc length in world units. Builds distance LUT on first call.
	double get_arc_length();
	/// Convert a world-space distance along the spline to a parameter in [0, 1].
	double distance_to_parameter(double p_distance);
	/// Convert a parameter in [0, 1] to cumulative arc-length distance.
	double parameter_to_distance(double p_t);

	/// Evaluate position at a given arc-length distance from the start.
	godot::Vector3 evaluate_position_at_distance(double p_distance);
	/// Evaluate tangent at a given arc-length distance from the start.
	godot::Vector3 evaluate_tangent_at_distance(double p_distance);

	/// Interpolate the parallel-transport binormal at parameter [code]t[/code].
	godot::Vector3 evaluate_binormal(double p_t);
	/// Build a rotation-minimizing reference frame (binormal, normal, tangent)
	/// at parameter [code]t[/code]. Returns the inverse transform.
	godot::Transform3D get_reference_frame(double p_t);

	/// Find the parameter [code]t[/code] of the closest point on the spline
	/// to [code]p_position[/code] using uniform sampling.
	double get_closest_parameter(const godot::Vector3 &p_position, int p_samples = 32) const;

	/// Recompute the arc-length distance lookup table from the current weights.
	void build_distance_lut();
	/// Recompute the parallel-transport binormal lookup table.
	void build_binormal_lut();

	/// Pack all spline data (weights, distance LUT, binormal LUT) into a
	/// PackedFloat32Array suitable for uploading to an RGBA32F data texture.
	godot::PackedFloat32Array pack_gpu_data();
	/// Pack GPU data directly into a caller-provided float buffer.
	/// Buffer must hold at least [constant GPU_DATA_FLOAT_COUNT] floats.
	void pack_gpu_data_into(float *p_buffer);
	/// Return the number of floats in the packed GPU representation.
	int get_gpu_data_size() const;

protected:
	static void _bind_methods();

private:
	static constexpr float CATMULL_ALPHA = 0.5f;

	// Precomputed polynomial coefficients for one spline segment.
	// data layout (row-major):
	//   [0..3]   x coefficients: const, linear, quadratic, cubic
	//   [4..7]   y coefficients
	//   [8..11]  z coefficients
	//   [12..15] w coefficients (zero, kept for GPU alignment)
	// Evaluation: pos.x = data[0] + data[1]*t + data[2]*t^2 + data[3]*t^3
	struct SegmentWeights {
		float data[16] = {};

		godot::Vector3 eval_position(float p_t) const;
		godot::Vector3 eval_velocity(float p_t) const;
		godot::Vector3 eval_acceleration(float p_t) const;
	};

	static float knot_interval(const godot::Vector3 &p_a, const godot::Vector3 &p_b);
	static float remap(float p_value, float p_from1, float p_to1, float p_from2, float p_to2);

	// Compute centripetal Catmull-Rom basis blending values and multiply with
	// control point coordinates in one pass using scalar float arithmetic.
	// Avoids routing through Vector4 operator chains entirely.
	static SegmentWeights compute_segment(
			const godot::Vector3 &p_p0, const godot::Vector3 &p_p1,
			const godot::Vector3 &p_p2, const godot::Vector3 &p_p3,
			float p_a, float p_d);

	void get_segment_and_local_t(float p_t, int &r_segment, float &r_local_t) const;

	// Shared rebuild path for set_points and set_points_with_entry_tangent.
	// When p_use_entry_tangent is true, the leading virtual control point is
	// placed at p_points[0] - p_entry_tangent * |p_points[1]-p_points[0]|
	// instead of the default mirrored reflection.
	void _rebuild(const godot::PackedVector3Array &p_points,
			bool p_use_entry_tangent,
			const godot::Vector3 &p_entry_tangent);

	std::vector<SegmentWeights> weights;
	float distance_lut[DISTANCE_LUT_COUNT] = {};
	godot::Vector3 binormal_lut[BINORMAL_LUT_COUNT] = {};
	float arc_length = 0.0f;
	bool distance_lut_dirty = true;
	bool binormal_lut_dirty = true;
};

#endif // DPG_CATMULL_SPLINE_H
