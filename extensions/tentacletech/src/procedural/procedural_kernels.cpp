#include "procedural_kernels.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <algorithm>
#include <cmath>
#include <vector>

using namespace godot;

namespace {

constexpr int FEATURE_ID_BODY = 0;
// Number of axial bins for the wart spatial index. Sized so that with
// ~256 warts spanning the full body, each bin holds ~50 warts on
// average — enough to amortize the inner loop without ballooning the
// per-bake setup cost.
constexpr int N_AXIAL_BINS = 32;
constexpr float PI_F = 3.14159265358979323846f;
constexpr float TAU_F = 6.28318530717958647692f;

inline float wrap_pi(float x) {
	while (x > PI_F) x -= TAU_F;
	while (x < -PI_F) x += TAU_F;
	return x;
}

inline bool is_body(const float *p_custom0, int p_idx) {
	return int(p_custom0[p_idx * 4]) == FEATURE_ID_BODY;
}

} // namespace

void ProceduralKernels::_bind_methods() {
	ClassDB::bind_static_method("ProceduralKernels",
			D_METHOD("displace_warts", "verts", "custom0", "length",
					"centers_t", "centers_phi", "sigma", "height"),
			&ProceduralKernels::displace_warts);
	ClassDB::bind_static_method("ProceduralKernels",
			D_METHOD("displace_knots", "verts", "custom0", "length",
					"centers_t", "sigma", "max_radius_multiplier", "profile_idx"),
			&ProceduralKernels::displace_knots);
	ClassDB::bind_static_method("ProceduralKernels",
			D_METHOD("displace_ribs", "verts", "custom0", "length",
					"centers_t", "half_width", "depth", "profile_idx"),
			&ProceduralKernels::displace_ribs);
	ClassDB::bind_static_method("ProceduralKernels",
			D_METHOD("displace_fins", "verts", "custom0", "length",
					"fin_phis", "max_height", "axial_height_samples",
					"half_width", "t_start", "t_end", "twist_per_length"),
			&ProceduralKernels::displace_fins);
}

PackedVector3Array ProceduralKernels::displace_warts(
		PackedVector3Array p_verts,
		const PackedFloat32Array &p_custom0,
		float p_length,
		const PackedFloat32Array &p_centers_t,
		const PackedFloat32Array &p_centers_phi,
		const PackedFloat32Array &p_sigma,
		const PackedFloat32Array &p_height) {
	int n = p_centers_t.size();
	if (n == 0 || p_length <= 0.0f) {
		return p_verts;
	}

	// Per-wart constants used in the inner loop. Pulled out of the
	// per-vertex hot path so the per-iter cost is a few flops + one
	// `std::exp`.
	std::vector<float> sigma_3(n);
	std::vector<float> sigma_3_sq(n);
	std::vector<float> inv_2_sigma_sq(n);
	for (int i = 0; i < n; i++) {
		float s = p_sigma[i];
		if (s < 1e-6f) {
			s = 1e-6f;
		}
		sigma_3[i] = 3.0f * s;
		sigma_3_sq[i] = sigma_3[i] * sigma_3[i];
		inv_2_sigma_sq[i] = 1.0f / (2.0f * s * s);
	}

	// Axial bins: each wart sits in every bin its 3σ axial footprint
	// touches. The per-vertex lookup then iterates only those warts whose
	// reach overlaps the vertex's axial slot.
	std::vector<std::vector<int>> bins(N_AXIAL_BINS);
	for (auto &b : bins) {
		b.reserve(16);
	}
	for (int i = 0; i < n; i++) {
		float t_lo = p_centers_t[i] - sigma_3[i] / p_length;
		float t_hi = p_centers_t[i] + sigma_3[i] / p_length;
		int b_lo = std::clamp(int(t_lo * N_AXIAL_BINS), 0, N_AXIAL_BINS - 1);
		int b_hi = std::clamp(int(t_hi * N_AXIAL_BINS), 0, N_AXIAL_BINS - 1);
		for (int b = b_lo; b <= b_hi; b++) {
			bins[b].push_back(i);
		}
	}

	int n_verts = p_verts.size();
	Vector3 *verts_w = p_verts.ptrw();
	const float *custom_r = p_custom0.ptr();
	const float *centers_t_r = p_centers_t.ptr();
	const float *centers_phi_r = p_centers_phi.ptr();
	const float *height_r = p_height.ptr();

	for (int vi = 0; vi < n_verts; vi++) {
		if (!is_body(custom_r, vi)) {
			continue;
		}
		Vector3 v = verts_w[vi];
		float t_v = std::abs(v.z) / p_length;
		if (t_v > 1.0f) {
			continue;
		}
		float r2_lat = v.x * v.x + v.y * v.y;
		if (r2_lat < 1e-12f) {
			continue;
		}
		float r_v = std::sqrt(r2_lat);
		float phi_v = std::atan2(v.y, v.x);

		int bin_idx = std::clamp(int(t_v * N_AXIAL_BINS), 0, N_AXIAL_BINS - 1);
		const std::vector<int> &bin = bins[bin_idx];

		float disp_total = 0.0f;
		for (int wi : bin) {
			float d_axial = (t_v - centers_t_r[wi]) * p_length;
			if (std::abs(d_axial) > sigma_3[wi]) {
				continue;
			}
			float d_phi = wrap_pi(phi_v - centers_phi_r[wi]);
			float d_arc = d_phi * r_v;
			float d2 = d_axial * d_axial + d_arc * d_arc;
			if (d2 > sigma_3_sq[wi]) {
				continue;
			}
			disp_total += height_r[wi] * std::exp(-d2 * inv_2_sigma_sq[wi]);
		}

		if (disp_total > 0.0f) {
			float inv_r = 1.0f / r_v;
			verts_w[vi] = Vector3(
					v.x + v.x * inv_r * disp_total,
					v.y + v.y * inv_r * disp_total,
					v.z);
		}
	}
	return p_verts;
}

PackedVector3Array ProceduralKernels::displace_knots(
		PackedVector3Array p_verts,
		const PackedFloat32Array &p_custom0,
		float p_length,
		const PackedFloat32Array &p_centers_t,
		float p_sigma,
		float p_max_radius_multiplier,
		int p_profile_idx) {
	int n = p_centers_t.size();
	if (n == 0 || p_length <= 0.0f || p_sigma < 1e-5f) {
		return p_verts;
	}
	if (std::abs(p_max_radius_multiplier - 1.0f) < 1e-4f) {
		return p_verts;
	}

	int n_verts = p_verts.size();
	Vector3 *verts_w = p_verts.ptrw();
	const float *custom_r = p_custom0.ptr();
	const float *centers_t_r = p_centers_t.ptr();
	float sigma_3 = 3.0f * p_sigma;
	float inv_sigma = 1.0f / p_sigma;

	for (int vi = 0; vi < n_verts; vi++) {
		if (!is_body(custom_r, vi)) {
			continue;
		}
		Vector3 v = verts_w[vi];
		float t = std::abs(v.z) / p_length;
		if (t > 1.0f) {
			t = 1.0f;
		}

		float best = 0.0f;
		for (int ci = 0; ci < n; ci++) {
			float c = centers_t_r[ci];
			float d = std::abs(t - c);
			if (d > sigma_3) {
				continue;
			}
			float x = d * inv_sigma;
			float val = 0.0f;
			switch (p_profile_idx) {
				case 1: // Sharp
					val = std::max(0.0f, 1.0f - x);
					break;
				case 2: { // Asymmetric — slow rise base-side, sharp fall tip-side
					float signed_x = (t - c) * inv_sigma;
					val = (signed_x < 0.0f
									? std::exp(-0.5f * signed_x * signed_x * 4.0f)
									: std::max(0.0f, 1.0f - signed_x));
					break;
				}
				default: // Gaussian
					val = std::exp(-0.5f * x * x);
					break;
			}
			if (val > best) {
				best = val;
			}
		}
		if (best > 0.0f) {
			float scale = 1.0f + (p_max_radius_multiplier - 1.0f) * best;
			verts_w[vi] = Vector3(v.x * scale, v.y * scale, v.z);
		}
	}
	return p_verts;
}

PackedVector3Array ProceduralKernels::displace_ribs(
		PackedVector3Array p_verts,
		const PackedFloat32Array &p_custom0,
		float p_length,
		const PackedFloat32Array &p_centers_t,
		float p_half_width,
		float p_depth,
		int p_profile_idx) {
	int n = p_centers_t.size();
	if (n == 0 || p_length <= 0.0f || p_depth <= 0.0f || p_half_width < 1e-5f) {
		return p_verts;
	}

	int n_verts = p_verts.size();
	Vector3 *verts_w = p_verts.ptrw();
	const float *custom_r = p_custom0.ptr();
	const float *centers_t_r = p_centers_t.ptr();
	float inv_half = 1.0f / p_half_width;
	float reach = (p_profile_idx == 1) ? p_half_width : 3.0f * p_half_width;

	for (int vi = 0; vi < n_verts; vi++) {
		if (!is_body(custom_r, vi)) {
			continue;
		}
		Vector3 v = verts_w[vi];
		float t = std::abs(v.z) / p_length;
		if (t > 1.0f) {
			t = 1.0f;
		}

		float best = 0.0f;
		for (int ci = 0; ci < n; ci++) {
			float d = std::abs(t - centers_t_r[ci]);
			if (d >= reach) {
				continue;
			}
			float val = 0.0f;
			if (p_profile_idx == 1) { // V
				val = 1.0f - d * inv_half;
			} else { // U
				float x = d * inv_half;
				val = std::exp(-0.5f * x * x);
			}
			if (val > best) {
				best = val;
			}
		}
		if (best > 0.0f) {
			float scale = std::max(1.0f - p_depth * best, 1e-3f);
			verts_w[vi] = Vector3(v.x * scale, v.y * scale, v.z);
		}
	}
	return p_verts;
}

PackedVector3Array ProceduralKernels::displace_fins(
		PackedVector3Array p_verts,
		const PackedFloat32Array &p_custom0,
		float p_length,
		const PackedFloat32Array &p_fin_phis,
		float p_max_height,
		const PackedFloat32Array &p_axial_height_samples,
		float p_half_width,
		float p_t_start,
		float p_t_end,
		float p_twist_per_length) {
	int count = p_fin_phis.size();
	int n_samples = p_axial_height_samples.size();
	if (count == 0 || p_max_height <= 0.0f || p_half_width <= 0.0f) {
		return p_verts;
	}
	if (p_t_end <= p_t_start || n_samples < 2) {
		return p_verts;
	}

	int n_verts = p_verts.size();
	Vector3 *verts_w = p_verts.ptrw();
	const float *custom_r = p_custom0.ptr();
	const float *fin_phis_r = p_fin_phis.ptr();
	const float *samples_r = p_axial_height_samples.ptr();
	float span = p_t_end - p_t_start;
	float inv_half = 1.0f / p_half_width;

	for (int vi = 0; vi < n_verts; vi++) {
		if (!is_body(custom_r, vi)) {
			continue;
		}
		Vector3 v = verts_w[vi];
		float t_v = std::abs(v.z) / p_length;
		if (t_v < p_t_start || t_v > p_t_end) {
			continue;
		}
		float r2_lat = v.x * v.x + v.y * v.y;
		if (r2_lat < 1e-12f) {
			continue;
		}
		float r_v = std::sqrt(r2_lat);
		float phi_v = std::atan2(v.y, v.x);

		// Sample axial height taper (linear interp between samples).
		float u = (t_v - p_t_start) / span;
		float fs = u * float(n_samples - 1);
		int s0 = std::clamp(int(fs), 0, n_samples - 1);
		int s1 = std::min(s0 + 1, n_samples - 1);
		float frac = fs - float(s0);
		float taper = samples_r[s0] * (1.0f - frac) + samples_r[s1] * frac;
		float h = p_max_height * taper;
		if (h <= 0.0f) {
			continue;
		}

		float twist_offset = p_twist_per_length * t_v * p_length;
		float disp_total = 0.0f;
		for (int fi = 0; fi < count; fi++) {
			float d_phi = wrap_pi(phi_v - (fin_phis_r[fi] + twist_offset));
			float ad = std::abs(d_phi);
			if (ad >= p_half_width) {
				continue;
			}
			float profile = 0.5f + 0.5f * std::cos(PI_F * ad * inv_half);
			disp_total += h * profile;
		}

		if (disp_total > 0.0f) {
			float inv_r = 1.0f / r_v;
			verts_w[vi] = Vector3(
					v.x + v.x * inv_r * disp_total,
					v.y + v.y * inv_r * disp_total,
					v.z);
		}
	}
	return p_verts;
}
