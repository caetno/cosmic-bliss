#include "catmull_spline.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>

#include <cmath>

using namespace godot;

// -- SegmentWeights ---------------------------------------------------------

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

// -- Static helpers ---------------------------------------------------------

float CatmullSpline::knot_interval(const Vector3 &p_a, const Vector3 &p_b) {
	// Centripetal: interval = |a-b|^alpha = (|a-b|^2)^(alpha/2). alpha=0.5 → ^0.25.
	return Math::pow((p_a - p_b).length_squared(), 0.5f * CATMULL_ALPHA);
}

float CatmullSpline::remap(float p_value, float p_from1, float p_to1, float p_from2, float p_to2) {
	return (p_value - p_from1) / (p_to1 - p_from1) * (p_to2 - p_from2) + p_from2;
}

CatmullSpline::SegmentWeights CatmullSpline::compute_segment(
		const Vector3 &p_p0, const Vector3 &p_p1,
		const Vector3 &p_p2, const Vector3 &p_p3,
		float p_a, float p_d) {
	// Centripetal Catmull-Rom basis weights, scalar-only.
	// Each control point k contributes a blend polynomial:
	//   blend_k(t) = f[k][0] + f[k][1]*t + f[k][2]*t^2 + f[k][3]*t^3
	// The output segment data row for axis c is:
	//   data[c*4 + j] = sum_k point_k[c] * f[k][j]
	float inv_neg_a_1ma = 1.0f / (-p_a * (1.0f - p_a));
	float inv_1ma = 1.0f / (1.0f - p_a);
	float inv_d = 1.0f / p_d;
	float inv_dm1_d = 1.0f / ((p_d - 1.0f) * p_d);

	float f[4][4];

	f[0][0] = 0.0f;
	f[0][1] = -1.0f * inv_neg_a_1ma;
	f[0][2] = 2.0f * inv_neg_a_1ma;
	f[0][3] = -1.0f * inv_neg_a_1ma;

	f[1][0] = -p_a * inv_neg_a_1ma + -p_a * inv_1ma + 0.0f;
	f[1][1] = (2.0f * p_a + 1.0f) * inv_neg_a_1ma + (2.0f * p_a + 1.0f) * inv_1ma + p_d * inv_d;
	f[1][2] = (-p_a - 2.0f) * inv_neg_a_1ma + (-p_a - 2.0f) * inv_1ma + (-p_d - 1.0f) * inv_d;
	f[1][3] = 1.0f * inv_neg_a_1ma + 1.0f * inv_1ma + 1.0f * inv_d;

	f[2][0] = 0.0f;
	f[2][1] = -p_a * inv_1ma;
	f[2][2] = (p_a + 1.0f) * inv_1ma + p_d * inv_d + p_d * inv_dm1_d;
	f[2][3] = -1.0f * inv_1ma + -1.0f * inv_d + -1.0f * inv_dm1_d;

	f[3][0] = 0.0f;
	f[3][1] = 0.0f;
	f[3][2] = -1.0f * inv_dm1_d;
	f[3][3] = 1.0f * inv_dm1_d;

	float pts[4][3] = {
		{ p_p0.x, p_p0.y, p_p0.z },
		{ p_p1.x, p_p1.y, p_p1.z },
		{ p_p2.x, p_p2.y, p_p2.z },
		{ p_p3.x, p_p3.y, p_p3.z },
	};

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
	for (int j = 0; j < 4; j++) {
		sw.data[12 + j] = 0.0f;
	}
	return sw;
}

void CatmullSpline::get_segment_and_local_t(float p_t, int &r_segment, float &r_local_t) const {
	int count = (int)weights.size();
	r_segment = CLAMP((int)Math::floor(p_t * count), 0, count - 1);
	float offset = p_t - (float)r_segment / (float)count;
	r_local_t = offset * (float)count;
}

// -- Lifecycle --------------------------------------------------------------

CatmullSpline::CatmullSpline() {}
CatmullSpline::~CatmullSpline() {}

// -- Build ------------------------------------------------------------------

void CatmullSpline::build_from_points(const PackedVector3Array &p_points) {
	weights.clear();
	distance_lut.clear();
	binormal_lut.clear();
	arc_length = 0.0f;

	int n = p_points.size();
	if (n < 2) {
		return;
	}

	weights.reserve(n - 1);

	for (int i = 0; i < n - 1; i++) {
		Vector3 p1 = p_points[i];
		Vector3 p2 = p_points[i + 1];

		// Mirror virtual control points at the endpoints.
		Vector3 p0 = (i == 0) ? p1 + (p1 - p2) : p_points[i - 1];
		Vector3 p3 = (i >= n - 2) ? p2 + (p2 - p1) : p_points[i + 2];

		float dist = 0.0f;
		dist += knot_interval(p0, p1);
		float interval1 = dist;
		dist += knot_interval(p1, p2);
		float interval2 = dist;
		dist += knot_interval(p2, p3);

		// Remap so [p1, p2] spans [0, 1] in the segment's local parameter.
		float a = remap(0.0f, interval1 / dist, interval2 / dist, 0.0f, 1.0f);
		float d = remap(1.0f, interval1 / dist, interval2 / dist, 0.0f, 1.0f);

		weights.push_back(compute_segment(p0, p1, p2, p3, a, d));
	}

	build_distance_lut(DEFAULT_DISTANCE_LUT_SAMPLES);
	build_binormal_lut(DEFAULT_BINORMAL_LUT_SAMPLES);
}

int CatmullSpline::get_point_count() const {
	return weights.empty() ? 0 : (int)weights.size() + 1;
}

int CatmullSpline::get_segment_count() const {
	return (int)weights.size();
}

// -- Evaluation -------------------------------------------------------------

Vector3 CatmullSpline::evaluate_position(float p_t) const {
	if (weights.empty()) {
		return Vector3();
	}
	int seg;
	float local_t;
	get_segment_and_local_t(p_t, seg, local_t);
	return weights[seg].eval_position(local_t);
}

Vector3 CatmullSpline::evaluate_tangent(float p_t) const {
	if (weights.empty()) {
		return Vector3();
	}
	int seg;
	float local_t;
	get_segment_and_local_t(p_t, seg, local_t);
	return weights[seg].eval_velocity(local_t);
}

void CatmullSpline::evaluate_frame(float p_t,
		Vector3 &r_tangent,
		Vector3 &r_normal,
		Vector3 &r_binormal) const {
	r_tangent = evaluate_tangent(p_t).normalized();

	if (binormal_lut.empty()) {
		// No transport data — fall back to an arbitrary perpendicular pair.
		r_binormal = r_tangent.cross(Vector3(0, 1, 0));
		if (r_binormal.length_squared() < 1e-6f) {
			r_binormal = r_tangent.cross(Vector3(0, 0, 1));
		}
		r_binormal.normalize();
	} else {
		float t = CLAMP(p_t, 0.0f, 1.0f);
		int last = (int)binormal_lut.size() - 1;
		int index = CLAMP((int)Math::floor(t * (float)last), 0, last - 1);
		float lerp_t = t * (float)last - (float)index;
		r_binormal = binormal_lut[index].lerp(binormal_lut[index + 1], lerp_t).normalized();
	}

	r_normal = r_tangent.cross(r_binormal).normalized();
	// Re-orthogonalize binormal to guarantee an orthonormal triple even if the
	// transported binormal drifted slightly off the tangent's perpendicular plane.
	r_binormal = r_normal.cross(r_tangent).normalized();
}

Dictionary CatmullSpline::evaluate_frame_dict(float p_t) const {
	Vector3 t, n, b;
	evaluate_frame(p_t, t, n, b);
	Dictionary d;
	d["tangent"] = t;
	d["normal"] = n;
	d["binormal"] = b;
	return d;
}

// -- Arc length / LUT -------------------------------------------------------

float CatmullSpline::get_arc_length() const {
	return arc_length;
}

void CatmullSpline::build_distance_lut(int p_sample_count) {
	if (weights.empty()) {
		distance_lut.clear();
		arc_length = 0.0f;
		return;
	}
	int n = (p_sample_count <= 1) ? DEFAULT_DISTANCE_LUT_SAMPLES : p_sample_count;
	distance_lut.assign(n, 0.0f);

	float dist = 0.0f;
	Vector3 last_pos = evaluate_position(0.0f);
	for (int i = 1; i < n; i++) {
		float t = (float)i / (float)(n - 1);
		Vector3 pos = evaluate_position(t);
		dist += last_pos.distance_to(pos);
		last_pos = pos;
		distance_lut[i] = dist;
	}
	arc_length = dist;
}

void CatmullSpline::build_binormal_lut(int p_sample_count) {
	if (weights.empty()) {
		binormal_lut.clear();
		return;
	}
	int n = (p_sample_count <= 1) ? DEFAULT_BINORMAL_LUT_SAMPLES : p_sample_count;
	binormal_lut.assign(n, Vector3());

	// Parallel transport: pick an initial perpendicular binormal, then rotate
	// it minimally to track tangent changes between samples. Avoids the Frenet
	// flip at inflection points.
	Vector3 tangent = evaluate_tangent(0.0f).normalized();
	Vector3 binormal = tangent.cross(Vector3(0, 1, 0));
	if (binormal.length_squared() < 1e-6f) {
		binormal = tangent.cross(Vector3(0, 0, 1));
	}
	binormal.normalize();

	binormal_lut[0] = binormal;
	Vector3 last_tangent = tangent;
	Vector3 last_binormal = binormal;

	for (int i = 1; i < n; i++) {
		float t = (float)i / (float)(n - 1);
		tangent = evaluate_tangent(t).normalized();

		Vector3 axis = last_tangent.cross(tangent);
		if (axis.length_squared() < 1e-12f) {
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
}

float CatmullSpline::parameter_to_distance(float p_t) const {
	if (distance_lut.size() < 2) {
		return 0.0f;
	}
	float t = CLAMP(p_t, 0.0f, 1.0f);
	int last = (int)distance_lut.size() - 1;
	int index = CLAMP((int)Math::floor(t * (float)last), 0, last - 1);
	float lerp_t = t * (float)last - (float)index;
	return Math::lerp(distance_lut[index], distance_lut[index + 1], lerp_t);
}

float CatmullSpline::distance_to_parameter(float p_distance) const {
	int n = (int)distance_lut.size();
	if (n < 2 || arc_length <= 0.0f) {
		return 0.0f;
	}
	if (p_distance <= 0.0f) {
		return 0.0f;
	}
	if (p_distance >= arc_length) {
		return 1.0f;
	}
	// Binary search the (monotonic non-decreasing) distance LUT.
	int lo = 0;
	int hi = n - 1;
	while (lo + 1 < hi) {
		int mid = (lo + hi) >> 1;
		if (distance_lut[mid] <= p_distance) {
			lo = mid;
		} else {
			hi = mid;
		}
	}
	float d0 = distance_lut[lo];
	float d1 = distance_lut[hi];
	float t0 = (float)lo / (float)(n - 1);
	float t1 = (float)hi / (float)(n - 1);
	if (d1 - d0 < 1e-12f) {
		return t0;
	}
	return remap(p_distance, d0, d1, t0, t1);
}

// -- Accessors for the data packer -----------------------------------------

PackedFloat32Array CatmullSpline::get_segment_weights() const {
	PackedFloat32Array out;
	int seg = (int)weights.size();
	out.resize(seg * SEGMENT_FLOAT_COUNT);
	float *ptr = out.ptrw();
	for (int i = 0; i < seg; i++) {
		for (int j = 0; j < SEGMENT_FLOAT_COUNT; j++) {
			ptr[i * SEGMENT_FLOAT_COUNT + j] = weights[i].data[j];
		}
	}
	return out;
}

PackedFloat32Array CatmullSpline::get_distance_lut() const {
	PackedFloat32Array out;
	int n = (int)distance_lut.size();
	out.resize(n);
	float *ptr = out.ptrw();
	for (int i = 0; i < n; i++) {
		ptr[i] = distance_lut[i];
	}
	return out;
}

PackedVector3Array CatmullSpline::get_binormal_lut() const {
	PackedVector3Array out;
	int n = (int)binormal_lut.size();
	out.resize(n);
	Vector3 *ptr = out.ptrw();
	for (int i = 0; i < n; i++) {
		ptr[i] = binormal_lut[i];
	}
	return out;
}

int CatmullSpline::get_distance_lut_sample_count() const {
	return (int)distance_lut.size();
}

int CatmullSpline::get_binormal_lut_sample_count() const {
	return (int)binormal_lut.size();
}

// -- Binding ----------------------------------------------------------------

void CatmullSpline::_bind_methods() {
	ClassDB::bind_method(D_METHOD("build_from_points", "points"), &CatmullSpline::build_from_points);
	ClassDB::bind_method(D_METHOD("get_point_count"), &CatmullSpline::get_point_count);
	ClassDB::bind_method(D_METHOD("get_segment_count"), &CatmullSpline::get_segment_count);

	ClassDB::bind_method(D_METHOD("evaluate_position", "t"), &CatmullSpline::evaluate_position);
	ClassDB::bind_method(D_METHOD("evaluate_tangent", "t"), &CatmullSpline::evaluate_tangent);

	// evaluate_frame uses out-params; GDScript gets the Dictionary shim.
	ClassDB::bind_method(D_METHOD("evaluate_frame", "t"), &CatmullSpline::evaluate_frame_dict);

	ClassDB::bind_method(D_METHOD("get_arc_length"), &CatmullSpline::get_arc_length);
	ClassDB::bind_method(D_METHOD("parameter_to_distance", "t"), &CatmullSpline::parameter_to_distance);
	ClassDB::bind_method(D_METHOD("distance_to_parameter", "distance"), &CatmullSpline::distance_to_parameter);

	ClassDB::bind_method(D_METHOD("build_distance_lut", "sample_count"), &CatmullSpline::build_distance_lut, DEFVAL(DEFAULT_DISTANCE_LUT_SAMPLES));
	ClassDB::bind_method(D_METHOD("build_binormal_lut", "sample_count"), &CatmullSpline::build_binormal_lut, DEFVAL(DEFAULT_BINORMAL_LUT_SAMPLES));

	ClassDB::bind_method(D_METHOD("get_segment_weights"), &CatmullSpline::get_segment_weights);
	ClassDB::bind_method(D_METHOD("get_distance_lut"), &CatmullSpline::get_distance_lut);
	ClassDB::bind_method(D_METHOD("get_binormal_lut"), &CatmullSpline::get_binormal_lut);
	ClassDB::bind_method(D_METHOD("get_distance_lut_sample_count"), &CatmullSpline::get_distance_lut_sample_count);
	ClassDB::bind_method(D_METHOD("get_binormal_lut_sample_count"), &CatmullSpline::get_binormal_lut_sample_count);

	BIND_CONSTANT(DEFAULT_DISTANCE_LUT_SAMPLES);
	BIND_CONSTANT(DEFAULT_BINORMAL_LUT_SAMPLES);
	BIND_CONSTANT(SEGMENT_FLOAT_COUNT);
}
