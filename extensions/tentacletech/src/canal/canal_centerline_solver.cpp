#include "canal/canal_centerline_solver.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

CanalCenterlineSolver::CanalCenterlineSolver() {}
CanalCenterlineSolver::~CanalCenterlineSolver() {}

void CanalCenterlineSolver::configure(
		const PackedVector3Array &p_rest_positions_world,
		const PackedFloat32Array &p_inv_mass_per_particle) {
	const int n = p_rest_positions_world.size();
	positions.clear();
	prev_positions.clear();
	inv_mass.clear();
	rest_segment_lengths.clear();
	if (n <= 0) {
		return;
	}
	positions.resize(n);
	prev_positions.resize(n);
	inv_mass.resize(n);
	external_lateral_perturbation.assign(n, Vector3(0.0f, 0.0f, 0.0f));
	const int im_count = p_inv_mass_per_particle.size();
	for (int i = 0; i < n; ++i) {
		positions[i] = p_rest_positions_world[i];
		prev_positions[i] = p_rest_positions_world[i];
		inv_mass[i] = (i < im_count) ? p_inv_mass_per_particle[i] : 1.0f;
	}
	// Anchor defaults to the rest endpoints so a caller that runs `tick`
	// before `set_anchors` doesn't snap the chain to (0,0,0).
	if (n >= 1) {
		proximal_anchor = positions[0];
		distal_anchor = positions[n - 1];
	}
	if (n >= 2) {
		rest_segment_lengths.resize(n - 1);
		for (int i = 0; i < n - 1; ++i) {
			rest_segment_lengths[i] = (positions[i + 1] - positions[i]).length();
		}
	}
}

void CanalCenterlineSolver::set_anchors(const Vector3 &p_proximal_world,
		const Vector3 &p_distal_world) {
	proximal_anchor = p_proximal_world;
	distal_anchor = p_distal_world;
}

void CanalCenterlineSolver::set_iterations(int p_n) {
	if (p_n < 1) {
		p_n = 1;
	}
	if (p_n > 32) {
		p_n = 32;
	}
	iterations = p_n;
}

void CanalCenterlineSolver::set_bending_stiffness(float p_k) {
	if (p_k < 0.0f) {
		p_k = 0.0f;
	}
	if (p_k > 1.0f) {
		p_k = 1.0f;
	}
	bending_stiffness = p_k;
}

void CanalCenterlineSolver::set_damping(float p_d) {
	if (p_d < 0.0f) {
		p_d = 0.0f;
	}
	if (p_d > 1.0f) {
		p_d = 1.0f;
	}
	damping = p_d;
}

void CanalCenterlineSolver::set_gravity_scale(float p_g) {
	gravity_scale = p_g;
}

void CanalCenterlineSolver::set_gravity_vector(const Vector3 &p_g) {
	gravity_vector = p_g;
}

void CanalCenterlineSolver::tick(float p_dt) {
	const int n = static_cast<int>(positions.size());
	if (n < 2) {
		return;
	}
	if (p_dt <= 0.0f) {
		return;
	}

	// Stash start-of-tick positions; used at the end to reconstruct
	// `prev_positions` so the next predict has a correctly-scaled
	// velocity. Symplectic Verlet: x_new = x + (x - x_prev)·(1-damp)
	//                                    + a·dt²; x_prev = x_start.
	std::vector<Vector3> start_positions = positions;

	const Vector3 gravity = gravity_vector * gravity_scale;
	const float dt2 = p_dt * p_dt;
	const float velocity_retain = 1.0f - damping;

	// ─── Predict ─────────────────────────────────────────────────────
	const bool have_lateral_push =
			static_cast<int>(external_lateral_perturbation.size()) == n;
	for (int i = 0; i < n; ++i) {
		if (inv_mass[i] <= 0.0f) {
			// Pinned by mass — leave at current (will be re-pinned to
			// anchor inside the iteration loop if endpoint).
			continue;
		}
		const Vector3 v_implicit = positions[i] - prev_positions[i];
		positions[i] = positions[i] + v_implicit * velocity_retain + gravity * dt2;
		// 5F.B.C — apply (and consume) the external lateral perturbation.
		if (have_lateral_push) {
			positions[i] = positions[i] + external_lateral_perturbation[i];
		}
	}
	if (have_lateral_push) {
		std::fill(external_lateral_perturbation.begin(),
				external_lateral_perturbation.end(), Vector3(0.0f, 0.0f, 0.0f));
	}

	// Anchor endpoints win even if inv_mass != 0 (defensive).
	positions[0] = proximal_anchor;
	positions[n - 1] = distal_anchor;

	// ─── Constraint iterations ──────────────────────────────────────
	for (int iter = 0; iter < iterations; ++iter) {
		// Re-pin anchors at the start of each iter — guarantees they
		// dominate distance + bending constraint corrections that
		// would otherwise drift the endpoints.
		positions[0] = proximal_anchor;
		positions[n - 1] = distal_anchor;

		// Distance constraint per adjacent pair, weighted by inv_mass.
		// Stiffness implicit (full correction); compliance is left to
		// per-iter divisor by iter count — common XPBD-stiff regime.
		for (int i = 0; i < n - 1; ++i) {
			const float rest = rest_segment_lengths[i];
			Vector3 d = positions[i + 1] - positions[i];
			const float len = d.length();
			if (len <= 1e-9f) {
				continue;
			}
			const float w_a = inv_mass[i];
			const float w_b = inv_mass[i + 1];
			const float w_sum = w_a + w_b;
			if (w_sum <= 0.0f) {
				continue;
			}
			const float delta = len - rest;
			const Vector3 corr = d * (delta / len);
			positions[i] += corr * (w_a / w_sum);
			positions[i + 1] -= corr * (w_b / w_sum);
		}

		// Bending constraint, three-point midpoint-pull (cheap-and-
		// stable; sufficient for the slice). For each interior triple
		// (a, b, c), the ideal middle position is the linear interp
		// from a→c at fraction L_ab / (L_ab + L_bc). Pull `b` toward
		// that target with `bending_stiffness`.
		//
		// This intentionally does NOT preserve segment lengths — the
		// distance constraint above does, and runs alongside this in
		// the same iter loop. The combined effect is a stable bend
		// that resists kinks without locking the chain rigid.
		for (int i = 1; i < n - 1; ++i) {
			if (inv_mass[i] <= 0.0f) {
				continue;
			}
			const Vector3 &a = positions[i - 1];
			const Vector3 &c = positions[i + 1];
			const float l_ab = rest_segment_lengths[i - 1];
			const float l_bc = rest_segment_lengths[i];
			const float l_total = l_ab + l_bc;
			if (l_total <= 1e-9f) {
				continue;
			}
			const float frac = l_ab / l_total;
			const Vector3 target = a + (c - a) * frac;
			positions[i] = positions[i] + (target - positions[i]) * bending_stiffness;
		}

		// Final re-pin in case distance/bending nudged the endpoints
		// (with w_a == 0 the distance step shouldn't move them, but
		// safety > theory).
		positions[0] = proximal_anchor;
		positions[n - 1] = distal_anchor;
	}

	// ─── Reconstruct prev for next tick (Verlet velocity carry) ─────
	// prev = position_at_start_of_tick. The implicit velocity for the
	// next predict is (new - prev) = total displacement this tick.
	for (int i = 0; i < n; ++i) {
		prev_positions[i] = start_positions[i];
	}
}

PackedVector3Array CanalCenterlineSolver::get_positions_snapshot() const {
	PackedVector3Array out;
	const int n = static_cast<int>(positions.size());
	out.resize(n);
	for (int i = 0; i < n; ++i) {
		out[i] = positions[i];
	}
	return out;
}

PackedVector3Array CanalCenterlineSolver::get_prev_positions_snapshot() const {
	PackedVector3Array out;
	const int n = static_cast<int>(prev_positions.size());
	out.resize(n);
	for (int i = 0; i < n; ++i) {
		out[i] = prev_positions[i];
	}
	return out;
}

int CanalCenterlineSolver::get_particle_count() const {
	return static_cast<int>(positions.size());
}

void CanalCenterlineSolver::set_particle_position(int p_index, const Vector3 &p_pos) {
	if (p_index < 0 || p_index >= static_cast<int>(positions.size())) {
		return;
	}
	positions[p_index] = p_pos;
	prev_positions[p_index] = p_pos;
}

// ─── 5F.B.B per-arc-length evaluators ─────────────────────────────────
//
// Helper: given `s`, find the bracketing segment index `i` such that
// `s ∈ [cum_len[i], cum_len[i+1]]`, plus the in-segment fraction.
// Returns segment index in `r_seg`, fraction in `r_frac`, total arc in
// `r_total`. `r_seg` is clamped to [0, n-2] so degenerate cases (n=1) are
// caught by the caller, not here.
static void _locate_segment(const std::vector<Vector3> &positions, float p_s,
		int &r_seg, float &r_frac, float &r_total) {
	r_seg = 0;
	r_frac = 0.0f;
	r_total = 0.0f;
	const int n = static_cast<int>(positions.size());
	if (n < 2) {
		return;
	}
	// Compute segment lengths inline; cheap (n-1 sqrt's) and avoids
	// dragging a per-tick cache field for a per-cell-call API. With M=12,
	// the per-canal cost is 11 sqrt per cell × 256 cells = ~3K sqrt per
	// tick per canal — negligible.
	std::vector<float> cum;
	cum.resize(n);
	cum[0] = 0.0f;
	for (int i = 0; i < n - 1; ++i) {
		cum[i + 1] = cum[i] + (positions[i + 1] - positions[i]).length();
	}
	r_total = cum[n - 1];
	if (r_total <= 1e-9f) {
		return;
	}
	const float s_clamped = std::max(0.0f, std::min(p_s, r_total));
	// Binary-search the segment. n is tiny (≤ 64); linear scan is fine and
	// avoids any std::upper_bound dance.
	int seg = 0;
	for (int i = 0; i < n - 1; ++i) {
		if (s_clamped <= cum[i + 1]) {
			seg = i;
			break;
		}
		seg = i; // clamp to last segment for s == total
	}
	const float seg_len = cum[seg + 1] - cum[seg];
	r_seg = seg;
	r_frac = (seg_len > 1e-9f) ? ((s_clamped - cum[seg]) / seg_len) : 0.0f;
}

float CanalCenterlineSolver::get_total_arc_length() const {
	const int n = static_cast<int>(positions.size());
	if (n < 2) {
		return 0.0f;
	}
	float total = 0.0f;
	for (int i = 0; i < n - 1; ++i) {
		total += (positions[i + 1] - positions[i]).length();
	}
	return total;
}

Vector3 CanalCenterlineSolver::evaluate_at(float p_s) const {
	const int n = static_cast<int>(positions.size());
	if (n == 0) {
		return Vector3();
	}
	if (n == 1) {
		return positions[0];
	}
	int seg = 0;
	float frac = 0.0f;
	float total = 0.0f;
	_locate_segment(positions, p_s, seg, frac, total);
	return positions[seg].lerp(positions[seg + 1], frac);
}

Basis CanalCenterlineSolver::basis_at(float p_s) const {
	const int n = static_cast<int>(positions.size());
	if (n < 2) {
		return Basis();
	}
	int seg = 0;
	float frac = 0.0f;
	float total = 0.0f;
	_locate_segment(positions, p_s, seg, frac, total);

	// Tangent: segment direction at `seg`.
	Vector3 tangent = positions[seg + 1] - positions[seg];
	const float tlen = tangent.length();
	if (tlen <= 1e-9f) {
		return Basis();
	}
	tangent /= tlen;

	// Parallel-transport the normal from segment 0 forward to `seg`. The
	// initial normal is chosen perpendicular to the segment-0 tangent;
	// the second axis (Y if |tangent.y| < 0.9, else Z) is the seed.
	Vector3 t0 = positions[1] - positions[0];
	const float t0_len = t0.length();
	if (t0_len <= 1e-9f) {
		return Basis();
	}
	t0 /= t0_len;
	Vector3 seed = (std::abs(t0.y) < 0.9f) ? Vector3(0.0f, 1.0f, 0.0f)
										   : Vector3(0.0f, 0.0f, 1.0f);
	Vector3 normal = (seed - t0 * seed.dot(t0)).normalized();

	for (int i = 0; i < seg; ++i) {
		const Vector3 ti = (positions[i + 1] - positions[i]).normalized();
		const Vector3 ti_next = (i + 2 < n)
				? (positions[i + 2] - positions[i + 1]).normalized()
				: ti;
		// Rotate `normal` by the rotation that maps `ti` → `ti_next`. This
		// is Rotation-Minimizing-Frame parallel transport along a polyline.
		const Vector3 axis = ti.cross(ti_next);
		const float sin_a = axis.length();
		if (sin_a > 1e-9f) {
			const float cos_a = ti.dot(ti_next);
			const float angle = std::atan2(sin_a, cos_a);
			normal = normal.rotated(axis / sin_a, angle);
		}
	}
	// Project normal perpendicular to the current segment tangent
	// (numerical hygiene; the analytic transport keeps them ⟂ but FP error
	// accumulates over a long chain).
	normal = (normal - tangent * normal.dot(tangent));
	const float nlen = normal.length();
	if (nlen <= 1e-9f) {
		// Fallback: rebuild from seed against current tangent.
		Vector3 seed2 = (std::abs(tangent.y) < 0.9f) ? Vector3(0.0f, 1.0f, 0.0f)
													 : Vector3(0.0f, 0.0f, 1.0f);
		normal = (seed2 - tangent * seed2.dot(tangent)).normalized();
	} else {
		normal /= nlen;
	}
	const Vector3 binormal = tangent.cross(normal).normalized();
	// Godot Basis(x, y, z) takes column vectors. Convention matches
	// `_project_onto_spline` in canal_auto_baker.gd:
	//   columns = (tangent, normal, binormal).
	return Basis(tangent, normal, binormal);
}

float CanalCenterlineSolver::curvature_at(float p_s) const {
	const int n = static_cast<int>(positions.size());
	if (n < 3) {
		return 0.0f;
	}
	int seg = 0;
	float frac = 0.0f;
	float total = 0.0f;
	_locate_segment(positions, p_s, seg, frac, total);
	// Pick the interior particle index closest to `s`: seg vs seg+1.
	int mid = (frac < 0.5f) ? seg : seg + 1;
	if (mid <= 0) {
		mid = 1;
	}
	if (mid >= n - 1) {
		mid = n - 2;
	}
	const Vector3 &a = positions[mid - 1];
	const Vector3 &b = positions[mid];
	const Vector3 &c = positions[mid + 1];
	// Discrete |d²r/ds²| estimate: |a - 2b + c| / h², with h = avg leg.
	const float h = 0.5f * ((b - a).length() + (c - b).length());
	if (h <= 1e-9f) {
		return 0.0f;
	}
	const Vector3 second = a - b * 2.0f + c;
	return second.length() / (h * h);
}

void CanalCenterlineSolver::add_external_lateral_perturbation(int p_particle_index,
		const Vector3 &p_delta_world) {
	const int n = static_cast<int>(positions.size());
	if (p_particle_index < 0 || p_particle_index >= n) return;
	if (static_cast<int>(external_lateral_perturbation.size()) != n) {
		external_lateral_perturbation.assign(n, Vector3(0.0f, 0.0f, 0.0f));
	}
	external_lateral_perturbation[p_particle_index] += p_delta_world;
}

Vector3 CanalCenterlineSolver::outward_at(float p_s, float p_theta) const {
	const Basis b = basis_at(p_s);
	const Vector3 normal = b.get_column(1);
	const Vector3 binormal = b.get_column(2);
	const Vector3 out = normal * std::cos(p_theta) + binormal * std::sin(p_theta);
	const float l = out.length();
	if (l < 1e-9f) return Vector3(1.0f, 0.0f, 0.0f);
	return out / l;
}

Vector3 CanalCenterlineSolver::bend_axis_at(float p_s) const {
	const int n = static_cast<int>(positions.size());
	if (n < 3) {
		return Vector3();
	}
	int seg = 0;
	float frac = 0.0f;
	float total = 0.0f;
	_locate_segment(positions, p_s, seg, frac, total);
	int mid = (frac < 0.5f) ? seg : seg + 1;
	if (mid <= 0) {
		mid = 1;
	}
	if (mid >= n - 1) {
		mid = n - 2;
	}
	const Vector3 &a = positions[mid - 1];
	const Vector3 &b = positions[mid];
	const Vector3 &c = positions[mid + 1];
	const Vector3 mid_ac = (a + c) * 0.5f;
	Vector3 axis = mid_ac - b;
	const float l = axis.length();
	if (l <= 1e-9f) {
		return Vector3();
	}
	return axis / l;
}

void CanalCenterlineSolver::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "rest_positions_world", "inv_mass_per_particle"),
			&CanalCenterlineSolver::configure);
	ClassDB::bind_method(D_METHOD("set_anchors", "proximal_world", "distal_world"),
			&CanalCenterlineSolver::set_anchors);
	ClassDB::bind_method(D_METHOD("set_iterations", "n"), &CanalCenterlineSolver::set_iterations);
	ClassDB::bind_method(D_METHOD("set_bending_stiffness", "k"),
			&CanalCenterlineSolver::set_bending_stiffness);
	ClassDB::bind_method(D_METHOD("set_damping", "d"), &CanalCenterlineSolver::set_damping);
	ClassDB::bind_method(D_METHOD("set_gravity_scale", "g"),
			&CanalCenterlineSolver::set_gravity_scale);
	ClassDB::bind_method(D_METHOD("set_gravity_vector", "g"),
			&CanalCenterlineSolver::set_gravity_vector);
	ClassDB::bind_method(D_METHOD("tick", "dt"), &CanalCenterlineSolver::tick);
	ClassDB::bind_method(D_METHOD("get_positions_snapshot"),
			&CanalCenterlineSolver::get_positions_snapshot);
	ClassDB::bind_method(D_METHOD("get_prev_positions_snapshot"),
			&CanalCenterlineSolver::get_prev_positions_snapshot);
	ClassDB::bind_method(D_METHOD("get_particle_count"),
			&CanalCenterlineSolver::get_particle_count);
	ClassDB::bind_method(D_METHOD("set_particle_position", "index", "pos"),
			&CanalCenterlineSolver::set_particle_position);
	ClassDB::bind_method(D_METHOD("evaluate_at", "s"), &CanalCenterlineSolver::evaluate_at);
	ClassDB::bind_method(D_METHOD("basis_at", "s"), &CanalCenterlineSolver::basis_at);
	ClassDB::bind_method(D_METHOD("curvature_at", "s"), &CanalCenterlineSolver::curvature_at);
	ClassDB::bind_method(D_METHOD("bend_axis_at", "s"), &CanalCenterlineSolver::bend_axis_at);
	ClassDB::bind_method(D_METHOD("get_total_arc_length"),
			&CanalCenterlineSolver::get_total_arc_length);

	// 5F.B.C — type-3 lateral pressure intake + outward sample.
	ClassDB::bind_method(D_METHOD("add_external_lateral_perturbation",
								  "particle_index", "delta_world"),
			&CanalCenterlineSolver::add_external_lateral_perturbation);
	ClassDB::bind_method(D_METHOD("outward_at", "s", "theta"),
			&CanalCenterlineSolver::outward_at);
}
