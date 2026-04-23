#include "catmull_spline.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>

using namespace godot;

// -- SegmentWeights helpers --------------------------------------------------

Vector3 CatmullSpline::SegmentWeights::eval_position(float p_t) const {
	float t2 = p_t * p_t;
	float t3 = t2 * p_t;
	return Vector3(
			data[0] + data[1] * p_t + data[2] * t2 + data[3] * t3,
			data[4] + data[5] * p_t + data[6] * t2 + data[7] * t3,
			data[8] + data[9] * p_t + data[10] * t2 + data[11] * t3);
}

Vector3 CatmullSpline::SegmentWeights::eval_velocity(float p_t) const {
	float t2 = p_t * p_t;
	return Vector3(
			data[1] + 2.0f * data[2] * p_t + 3.0f * data[3] * t2,
			data[5] + 2.0f * data[6] * p_t + 3.0f * data[7] * t2,
			data[9] + 2.0f * data[10] * p_t + 3.0f * data[11] * t2);
}

Vector3 CatmullSpline::SegmentWeights::eval_acceleration(float p_t) const {
	return Vector3(
			2.0f * data[2] + 6.0f * data[3] * p_t,
			2.0f * data[6] + 6.0f * data[7] * p_t,
			2.0f * data[10] + 6.0f * data[11] * p_t);
}

// -- Static helpers ----------------------------------------------------------

float CatmullSpline::knot_interval(const Vector3 &p_a, const Vector3 &p_b) {
	// Centripetal parameterization: interval = |a - b|^alpha
	// = (|a-b|^2)^(0.5 * alpha) = (|a-b|^2)^0.25
	return Math::pow((p_a - p_b).length_squared(), 0.5f * CATMULL_ALPHA);
}

float CatmullSpline::remap(float p_value, float p_from1, float p_to1, float p_from2, float p_to2) {
	return (p_value - p_from1) / (p_to1 - p_from1) * (p_to2 - p_from2) + p_from2;
}

CatmullSpline::SegmentWeights CatmullSpline::compute_segment(
		const Vector3 &p_p0, const Vector3 &p_p1,
		const Vector3 &p_p2, const Vector3 &p_p3,
		float p_a, float p_d) {
	// Centripetal Catmull-Rom weight computation using only scalar arithmetic.
	// Computes the basis blending polynomials and multiplies with control point
	// coordinates in one pass — no Vector4 intermediaries.
	//
	// Each basis polynomial pkFact[j] (j=0..3 for const/linear/quad/cubic):
	//   blend_k(t) = pkFact[0] + pkFact[1]*t + pkFact[2]*t^2 + pkFact[3]*t^3
	//
	// Final weight data row for coordinate axis c:
	//   data[c*4 + j] = sum_k  point_k[c] * pkFact[j]

	float inv_neg_a_1ma = 1.0f / (-p_a * (1.0f - p_a));
	float inv_1ma = 1.0f / (1.0f - p_a);
	float inv_d = 1.0f / p_d;
	float inv_dm1_d = 1.0f / ((p_d - 1.0f) * p_d);

	// Basis polynomial coefficients for each control point.
	// f[k][j] = coefficient j of blend polynomial for control point k.
	float f[4][4];

	// p0Fact = (0, -1, 2, -1) * inv_neg_a_1ma
	f[0][0] = 0.0f;
	f[0][1] = -1.0f * inv_neg_a_1ma;
	f[0][2] = 2.0f * inv_neg_a_1ma;
	f[0][3] = -1.0f * inv_neg_a_1ma;

	// p1Fact = (-a, 2a+1, -a-2, 1) * inv_neg_a_1ma
	//        + (-a, 2a+1, -a-2, 1) * inv_1ma
	//        + (0,  d,   -d-1,  1) * inv_d
	f[1][0] = -p_a * inv_neg_a_1ma + -p_a * inv_1ma + 0.0f;
	f[1][1] = (2.0f * p_a + 1.0f) * inv_neg_a_1ma + (2.0f * p_a + 1.0f) * inv_1ma + p_d * inv_d;
	f[1][2] = (-p_a - 2.0f) * inv_neg_a_1ma + (-p_a - 2.0f) * inv_1ma + (-p_d - 1.0f) * inv_d;
	f[1][3] = 1.0f * inv_neg_a_1ma + 1.0f * inv_1ma + 1.0f * inv_d;

	// p2Fact = (0, -a,  a+1, -1) * inv_1ma
	//        + (0,  0,  d,   -1) * inv_d
	//        + (0,  0,  d,   -1) * inv_dm1_d
	f[2][0] = 0.0f;
	f[2][1] = -p_a * inv_1ma;
	f[2][2] = (p_a + 1.0f) * inv_1ma + p_d * inv_d + p_d * inv_dm1_d;
	f[2][3] = -1.0f * inv_1ma + -1.0f * inv_d + -1.0f * inv_dm1_d;

	// p3Fact = (0, 0, -1, 1) * inv_dm1_d
	f[3][0] = 0.0f;
	f[3][1] = 0.0f;
	f[3][2] = -1.0f * inv_dm1_d;
	f[3][3] = 1.0f * inv_dm1_d;

	// Extract point coordinates into a flat array for the inner loop.
	// pts[k][c]: coordinate c of control point k.
	float pts[4][3] = {
		{ p_p0.x, p_p0.y, p_p0.z },
		{ p_p1.x, p_p1.y, p_p1.z },
		{ p_p2.x, p_p2.y, p_p2.z },
		{ p_p3.x, p_p3.y, p_p3.z },
	};

	// Multiply: data[c*4 + j] = sum_k pts[k][c] * f[k][j]
	SegmentWeights sw;
	for (int c = 0; c < 3; c++) {
		for (int j = 0; j < 4; j++) {
			sw.data[c * 4 + j] =
					pts[0][c] * f[0][j] +
					pts[1][c] * f[1][j] +
					pts[2][c] * f[2][j] +
					pts[3][c] * f[3][j];
		}
	}
	// W row (zeros for GPU padding).
	sw.data[12] = 0.0f;
	sw.data[13] = 0.0f;
	sw.data[14] = 0.0f;
	sw.data[15] = 0.0f;

	return sw;
}

void CatmullSpline::get_segment_and_local_t(float p_t, int &r_segment, float &r_local_t) const {
	int count = (int)weights.size();
	r_segment = CLAMP((int)Math::floor(p_t * count), 0, count - 1);
	float offset = p_t - (float)r_segment / (float)count;
	r_local_t = offset * (float)count;
}

// -- Constructor / destructor ------------------------------------------------

CatmullSpline::CatmullSpline() {
}

CatmullSpline::~CatmullSpline() {
}

// -- Point setup -------------------------------------------------------------

void CatmullSpline::set_points(const PackedVector3Array &p_points) {
	_rebuild(p_points, false, Vector3());
}

void CatmullSpline::set_points_with_entry_tangent(const PackedVector3Array &p_points,
		const Vector3 &p_entry_tangent) {
	Vector3 t = p_entry_tangent;
	if (t.length_squared() < 1e-12f) {
		// Zero vector falls back to normal mirroring.
		_rebuild(p_points, false, Vector3());
		return;
	}
	_rebuild(p_points, true, t.normalized());
}

void CatmullSpline::_rebuild(const PackedVector3Array &p_points,
		bool p_use_entry_tangent,
		const Vector3 &p_entry_tangent) {
	weights.clear();
	distance_lut_dirty = true;
	binormal_lut_dirty = true;
	arc_length = 0.0f;

	int n = p_points.size();
	if (n < 2) {
		return;
	}

	weights.reserve(n - 1);

	for (int i = 0; i < n - 1; i++) {
		Vector3 p1 = p_points[i];
		Vector3 p2 = p_points[i + 1];

		// Virtual control point before the segment.
		Vector3 p0;
		float dist = 0.0f;
		if (i == 0) {
			if (p_use_entry_tangent) {
				// Override mirror so the Catmull-Rom tangent at t=0 aligns
				// with the caller-supplied entry tangent. Place the virtual
				// control point backward along entry_tangent at |p2-p1|.
				float d12 = (p2 - p1).length();
				p0 = p1 - p_entry_tangent * d12;
			} else {
				p0 = p1 + (p1 - p2); // mirror
			}
		} else {
			p0 = p_points[i - 1];
		}
		dist += knot_interval(p0, p1);
		float interval1 = dist;

		dist += knot_interval(p1, p2);
		float interval2 = dist;

		// Virtual control point after the segment.
		Vector3 p3;
		if (i >= n - 2) {
			p3 = p2 + (p2 - p1); // mirror
		} else {
			p3 = p_points[i + 2];
		}
		dist += knot_interval(p2, p3);

		// Remap knot parameters so that [p1, p2] maps to [0, 1].
		float a = remap(0.0f, interval1 / dist, interval2 / dist, 0.0f, 1.0f);
		float d = remap(1.0f, interval1 / dist, interval2 / dist, 0.0f, 1.0f);

		weights.push_back(compute_segment(p0, p1, p2, p3, a, d));
	}
}

int CatmullSpline::get_point_count() const {
	return weights.empty() ? 0 : (int)weights.size() + 1;
}

int CatmullSpline::get_segment_count() const {
	return (int)weights.size();
}

// -- Core evaluation ---------------------------------------------------------

Vector3 CatmullSpline::evaluate_position(double p_t) const {
	if (weights.empty()) {
		return Vector3();
	}
	int seg;
	float local_t;
	get_segment_and_local_t((float)p_t, seg, local_t);
	return weights[seg].eval_position(local_t);
}

Vector3 CatmullSpline::evaluate_tangent(double p_t) const {
	if (weights.empty()) {
		return Vector3();
	}
	int seg;
	float local_t;
	get_segment_and_local_t((float)p_t, seg, local_t);
	return weights[seg].eval_velocity(local_t);
}

Vector3 CatmullSpline::evaluate_acceleration(double p_t) const {
	if (weights.empty()) {
		return Vector3();
	}
	int seg;
	float local_t;
	get_segment_and_local_t((float)p_t, seg, local_t);
	return weights[seg].eval_acceleration(local_t);
}

// -- Arc-length parameterization ---------------------------------------------

double CatmullSpline::get_arc_length() {
	if (distance_lut_dirty) {
		build_distance_lut();
	}
	return (double)arc_length;
}

void CatmullSpline::build_distance_lut() {
	float dist = 0.0f;
	Vector3 last_pos = evaluate_position(0.0);
	distance_lut[0] = 0.0f;

	for (int i = 1; i < DISTANCE_LUT_COUNT; i++) {
		float t = (float)i / (float)(DISTANCE_LUT_COUNT - 1);
		Vector3 pos = evaluate_position((double)t);
		dist += last_pos.distance_to(pos);
		last_pos = pos;
		distance_lut[i] = dist;
	}

	distance_lut_dirty = false;
	arc_length = dist;
}

double CatmullSpline::distance_to_parameter(double p_distance) {
	if (distance_lut_dirty) {
		build_distance_lut();
	}

	float d = (float)p_distance;

	if (d > 0.0f && d < arc_length) {
		for (int i = 0; i < DISTANCE_LUT_COUNT - 1; i++) {
			if (d > distance_lut[i] && d < distance_lut[i + 1]) {
				return (double)remap(d,
						distance_lut[i], distance_lut[i + 1],
						(float)i / (float)(DISTANCE_LUT_COUNT - 1),
						(float)(i + 1) / (float)(DISTANCE_LUT_COUNT - 1));
			}
		}
	}

	// Fallback: linear approximation.
	if (arc_length > 0.0f) {
		return (double)(d / arc_length);
	}
	return 0.0;
}

double CatmullSpline::parameter_to_distance(double p_t) {
	if (distance_lut_dirty) {
		build_distance_lut();
	}

	float t = CLAMP((float)p_t, 0.0f, 1.0f);
	int index = CLAMP((int)Math::floor(t * (DISTANCE_LUT_COUNT - 1)), 0, DISTANCE_LUT_COUNT - 2);
	float offset = t - (float)index / (float)(DISTANCE_LUT_COUNT - 1);
	float lerp_t = offset * (float)(DISTANCE_LUT_COUNT - 1);
	return (double)Math::lerp(distance_lut[index], distance_lut[index + 1], lerp_t);
}

Vector3 CatmullSpline::evaluate_position_at_distance(double p_distance) {
	return evaluate_position(distance_to_parameter(p_distance));
}

Vector3 CatmullSpline::evaluate_tangent_at_distance(double p_distance) {
	return evaluate_tangent(distance_to_parameter(p_distance));
}

// -- Binormal / reference frame ----------------------------------------------

void CatmullSpline::build_binormal_lut() {
	if (weights.empty()) {
		binormal_lut_dirty = false;
		return;
	}

	// Parallel transport: propagate an initial binormal along the curve,
	// rotating it minimally at each sample to stay perpendicular to the tangent.
	Vector3 tangent = evaluate_tangent(0.0).normalized();

	// Choose an initial binormal perpendicular to the tangent.
	Vector3 binormal = tangent.cross(Vector3(0, 1, 0)).normalized();
	if (binormal.length_squared() < 1e-6f) {
		binormal = tangent.cross(Vector3(0, 0, -1)).normalized();
	}

	binormal_lut[0] = binormal;
	Vector3 last_tangent = tangent;
	Vector3 last_binormal = binormal;

	for (int i = 1; i < BINORMAL_LUT_COUNT; i++) {
		float t = (float)i / (float)(BINORMAL_LUT_COUNT - 1);
		tangent = evaluate_tangent((double)t).normalized();

		Vector3 axis = last_tangent.cross(tangent);
		if (axis.length_squared() < 1e-12f) {
			// Tangent didn't change direction — keep the previous binormal.
			binormal = last_binormal;
		} else {
			float dot = CLAMP(last_tangent.dot(tangent), -1.0f, 1.0f);
			float theta = Math::acos(dot);
			binormal = last_binormal.rotated(axis.normalized(), theta);
		}

		last_tangent = tangent;
		last_binormal = binormal;
		binormal_lut[i] = binormal;
	}

	binormal_lut_dirty = false;
}

Vector3 CatmullSpline::evaluate_binormal(double p_t) {
	if (binormal_lut_dirty) {
		build_binormal_lut();
	}

	float t = CLAMP((float)p_t, 0.0f, 1.0f);
	int index = CLAMP((int)Math::floor(t * (BINORMAL_LUT_COUNT - 1)), 0, BINORMAL_LUT_COUNT - 2);
	float offset = t - (float)index / (float)(BINORMAL_LUT_COUNT - 1);
	float lerp_t = offset * (float)(BINORMAL_LUT_COUNT - 1);
	return binormal_lut[index].lerp(binormal_lut[index + 1], lerp_t);
}

Transform3D CatmullSpline::get_reference_frame(double p_t) {
	Vector3 tangent = evaluate_tangent(p_t).normalized();
	Vector3 binormal = evaluate_binormal(p_t).normalized();
	Vector3 normal = tangent.cross(binormal);

	// Build a basis where:
	//   x = binormal, y = normal, z = tangent
	// Matches Unity's row-major layout then inverted.
	Basis b;
	b.set_column(0, binormal);
	b.set_column(1, normal);
	b.set_column(2, tangent);
	Vector3 origin = evaluate_position(p_t);
	return Transform3D(b, origin).affine_inverse();
}

// -- Closest point -----------------------------------------------------------

double CatmullSpline::get_closest_parameter(const Vector3 &p_position, int p_samples) const {
	if (weights.empty()) {
		return 0.0;
	}

	float best_t = 0.0f;
	float best_dist_sq = 1e30f;

	for (int i = 0; i <= p_samples; i++) {
		float t = (float)i / (float)p_samples;
		float d_sq = evaluate_position((double)t).distance_squared_to(p_position);
		if (d_sq < best_dist_sq) {
			best_dist_sq = d_sq;
			best_t = t;
		}
	}

	return (double)best_t;
}

// -- GPU data packing --------------------------------------------------------

int CatmullSpline::get_gpu_data_size() const {
	return GPU_DATA_FLOAT_COUNT;
}

PackedFloat32Array CatmullSpline::pack_gpu_data() {
	if (distance_lut_dirty) {
		build_distance_lut();
	}
	if (binormal_lut_dirty) {
		build_binormal_lut();
	}

	PackedFloat32Array arr;
	arr.resize(GPU_DATA_FLOAT_COUNT);
	float *ptr = arr.ptrw();
	pack_gpu_data_into(ptr);
	return arr;
}

void CatmullSpline::pack_gpu_data_into(float *p_buffer) {
	if (distance_lut_dirty) {
		build_distance_lut();
	}
	if (binormal_lut_dirty) {
		build_binormal_lut();
	}

	int offset = 0;

	// [0] pointCount (as float, reinterpreted as int on GPU).
	// Clamp to SUB_SPLINE_COUNT+1 so the shader never indexes past the
	// weight array even if the CPU spline has more segments.
	int clamped_points = (int)weights.size() + 1;
	if (clamped_points > SUB_SPLINE_COUNT + 1) {
		clamped_points = SUB_SPLINE_COUNT + 1;
	}
	p_buffer[offset++] = (float)clamped_points;

	// [1] arcLength.
	p_buffer[offset++] = arc_length;

	// [2..2+SUB_SPLINE_COUNT*16-1] weight matrices.
	int seg_count = (int)weights.size();
	for (int i = 0; i < SUB_SPLINE_COUNT; i++) {
		if (i < seg_count) {
			for (int j = 0; j < 16; j++) {
				p_buffer[offset++] = weights[i].data[j];
			}
		} else {
			for (int j = 0; j < 16; j++) {
				p_buffer[offset++] = 0.0f;
			}
		}
	}

	// distanceLUT.
	for (int i = 0; i < DISTANCE_LUT_COUNT; i++) {
		p_buffer[offset++] = distance_lut[i];
	}

	// binormalLUT (packed as 3 consecutive floats per entry).
	for (int i = 0; i < BINORMAL_LUT_COUNT; i++) {
		p_buffer[offset++] = binormal_lut[i].x;
		p_buffer[offset++] = binormal_lut[i].y;
		p_buffer[offset++] = binormal_lut[i].z;
	}
}

// -- GDExtension binding -----------------------------------------------------

void CatmullSpline::_bind_methods() {
	using namespace godot;

	ClassDB::bind_method(D_METHOD("set_points", "points"), &CatmullSpline::set_points);
	ClassDB::bind_method(D_METHOD("set_points_with_entry_tangent", "points", "entry_tangent"), &CatmullSpline::set_points_with_entry_tangent);
	ClassDB::bind_method(D_METHOD("get_point_count"), &CatmullSpline::get_point_count);
	ClassDB::bind_method(D_METHOD("get_segment_count"), &CatmullSpline::get_segment_count);

	ClassDB::bind_method(D_METHOD("evaluate_position", "t"), &CatmullSpline::evaluate_position);
	ClassDB::bind_method(D_METHOD("evaluate_tangent", "t"), &CatmullSpline::evaluate_tangent);
	ClassDB::bind_method(D_METHOD("evaluate_acceleration", "t"), &CatmullSpline::evaluate_acceleration);

	ClassDB::bind_method(D_METHOD("get_arc_length"), &CatmullSpline::get_arc_length);
	ClassDB::bind_method(D_METHOD("distance_to_parameter", "distance"), &CatmullSpline::distance_to_parameter);
	ClassDB::bind_method(D_METHOD("parameter_to_distance", "t"), &CatmullSpline::parameter_to_distance);

	ClassDB::bind_method(D_METHOD("evaluate_position_at_distance", "distance"), &CatmullSpline::evaluate_position_at_distance);
	ClassDB::bind_method(D_METHOD("evaluate_tangent_at_distance", "distance"), &CatmullSpline::evaluate_tangent_at_distance);

	ClassDB::bind_method(D_METHOD("evaluate_binormal", "t"), &CatmullSpline::evaluate_binormal);
	ClassDB::bind_method(D_METHOD("get_reference_frame", "t"), &CatmullSpline::get_reference_frame);

	ClassDB::bind_method(D_METHOD("get_closest_parameter", "position", "samples"), &CatmullSpline::get_closest_parameter, DEFVAL(32));

	ClassDB::bind_method(D_METHOD("build_distance_lut"), &CatmullSpline::build_distance_lut);
	ClassDB::bind_method(D_METHOD("build_binormal_lut"), &CatmullSpline::build_binormal_lut);

	ClassDB::bind_method(D_METHOD("pack_gpu_data"), &CatmullSpline::pack_gpu_data);
	ClassDB::bind_method(D_METHOD("get_gpu_data_size"), &CatmullSpline::get_gpu_data_size);

	BIND_CONSTANT(SUB_SPLINE_COUNT);
	BIND_CONSTANT(DISTANCE_LUT_COUNT);
	BIND_CONSTANT(BINORMAL_LUT_COUNT);
	BIND_CONSTANT(GPU_DATA_FLOAT_COUNT);
}
