#ifndef TENTACLETECH_CATMULL_SPLINE_H
#define TENTACLETECH_CATMULL_SPLINE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <vector>

// Centripetal Catmull-Rom spline with arc-length parameterization and
// rotation-minimizing (parallel-transport) binormal frames.
//
// Pure math primitive — agnostic to TentacleTech, reusable. Spec: see
// docs/architecture/TentacleTech_Architecture.md §5.1.
class CatmullSpline : public godot::RefCounted {
	GDCLASS(CatmullSpline, godot::RefCounted)

public:
	static constexpr int DEFAULT_DISTANCE_LUT_SAMPLES = 32;
	static constexpr int DEFAULT_BINORMAL_LUT_SAMPLES = 32;
	// Per-segment polynomial coefs: 4 axes × 4 powers (axis 4 zero-padded for GPU).
	static constexpr int SEGMENT_FLOAT_COUNT = 16;

	CatmullSpline();
	~CatmullSpline();

	void build_from_points(const godot::PackedVector3Array &p_points);

	int get_point_count() const;
	int get_segment_count() const;

	godot::Vector3 evaluate_position(float p_t) const;
	// Non-normalized; magnitude reflects parameterization speed.
	godot::Vector3 evaluate_tangent(float p_t) const;
	// Returns an orthonormal frame at t. Tangent normalized; binormal is the
	// parallel-transport binormal interpolated from the LUT; normal = tangent × binormal.
	void evaluate_frame(float p_t,
			godot::Vector3 &r_tangent,
			godot::Vector3 &r_normal,
			godot::Vector3 &r_binormal) const;
	// GDScript-callable shim: Dictionary { "tangent": v, "normal": v, "binormal": v }.
	godot::Dictionary evaluate_frame_dict(float p_t) const;

	float get_arc_length() const;
	float parameter_to_distance(float p_t) const;
	float distance_to_parameter(float p_distance) const;

	// p_sample_count <= 0 uses the default. Both LUTs are also rebuilt
	// automatically by build_from_points with default sample counts.
	void build_distance_lut(int p_sample_count = DEFAULT_DISTANCE_LUT_SAMPLES);
	void build_binormal_lut(int p_sample_count = DEFAULT_BINORMAL_LUT_SAMPLES);

	// Accessors used by SplineDataPacker. Layout matches §5.2.
	godot::PackedFloat32Array get_segment_weights() const;
	godot::PackedFloat32Array get_distance_lut() const;
	godot::PackedVector3Array get_binormal_lut() const;
	int get_distance_lut_sample_count() const;
	int get_binormal_lut_sample_count() const;

protected:
	static void _bind_methods();

private:
	static constexpr float CATMULL_ALPHA = 0.5f;

	// Per-segment polynomial coefficients, layout SEGMENT_FLOAT_COUNT floats:
	//   [0..3]   x: const, linear, quad, cubic
	//   [4..7]   y
	//   [8..11]  z
	//   [12..15] w (zero — GPU padding)
	struct SegmentWeights {
		float data[SEGMENT_FLOAT_COUNT] = {};
		godot::Vector3 eval_position(float p_t) const;
		godot::Vector3 eval_velocity(float p_t) const;
	};

	static float knot_interval(const godot::Vector3 &p_a, const godot::Vector3 &p_b);
	static float remap(float p_value, float p_from1, float p_to1, float p_from2, float p_to2);
	static SegmentWeights compute_segment(
			const godot::Vector3 &p_p0, const godot::Vector3 &p_p1,
			const godot::Vector3 &p_p2, const godot::Vector3 &p_p3,
			float p_a, float p_d);

	void get_segment_and_local_t(float p_t, int &r_segment, float &r_local_t) const;

	std::vector<SegmentWeights> weights;
	std::vector<float> distance_lut;
	std::vector<godot::Vector3> binormal_lut;
	float arc_length = 0.0f;
};

#endif // TENTACLETECH_CATMULL_SPLINE_H
