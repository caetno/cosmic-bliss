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
	for (int i = 0; i < n; ++i) {
		if (inv_mass[i] <= 0.0f) {
			// Pinned by mass — leave at current (will be re-pinned to
			// anchor inside the iteration loop if endpoint).
			continue;
		}
		const Vector3 v_implicit = positions[i] - prev_positions[i];
		positions[i] = positions[i] + v_implicit * velocity_retain + gravity * dt2;
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
}
