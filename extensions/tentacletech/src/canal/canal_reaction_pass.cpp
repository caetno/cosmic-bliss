#include "canal/canal_reaction_pass.h"

#include <godot_cpp/classes/physics_server3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/basis.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

namespace {
// Same epsilon scale used by the orifice rim-closure pass: an unsigned
// per-section reaction below this magnitude doesn't get routed (avoids
// thrashing host bones with floating-point dust at rest).
constexpr float MIN_REACTION_LENGTH = 1e-6f;
} // namespace

CanalReactionPass::CanalReactionPass() {}
CanalReactionPass::~CanalReactionPass() {}

void CanalReactionPass::configure(int p_axial_segments, int p_angular_sectors,
		const PackedFloat32Array &p_rest_radius_per_cell,
		const Array &p_host_bone_rids,
		float p_wall_response_stiffness,
		int p_n_rim_exclusion) {
	axial_segments = std::max(2, p_axial_segments);
	angular_sectors = std::max(2, p_angular_sectors);
	const int n_cells = axial_segments * angular_sectors;

	rest_radius.assign(n_cells, 0.0f);
	const int rr = p_rest_radius_per_cell.size();
	for (int i = 0; i < n_cells; ++i) {
		rest_radius[i] = (i < rr) ? p_rest_radius_per_cell[i] : 0.05f;
	}

	host_bone_rids.assign(axial_segments, RID());
	const int rid_count = p_host_bone_rids.size();
	for (int i = 0; i < axial_segments; ++i) {
		if (i < rid_count) {
			Variant v = p_host_bone_rids[i];
			if (v.get_type() == Variant::RID) {
				host_bone_rids[i] = v;
			}
		}
	}

	wall_response_stiffness = std::max(0.0f, p_wall_response_stiffness);
	if (p_n_rim_exclusion < 0) {
		n_rim_exclusion = 0;
	} else {
		n_rim_exclusion = p_n_rim_exclusion;
	}

	last_reaction_per_section.assign(axial_segments, Vector3());
	last_bone_impulses.clear();
	last_application_points.clear();
}

void CanalReactionPass::set_centerline_solver(const Ref<CanalCenterlineSolver> &p_solver) {
	centerline_solver = p_solver;
}

void CanalReactionPass::set_tunnel_state_integrator(const Ref<TunnelStateIntegrator> &p_integrator) {
	tunnel_state_integrator = p_integrator;
}

void CanalReactionPass::set_wall_response_stiffness(float p_k) {
	wall_response_stiffness = std::max(0.0f, p_k);
}

void CanalReactionPass::set_n_rim_exclusion(int p_n) {
	n_rim_exclusion = std::max(0, p_n);
}

int CanalReactionPass::tick(float p_dt) {
	// Always clear the per-tick snapshots so a test calling tick(0) or
	// running on a partially-configured pass sees zeros, not stale state.
	for (int i = 0; i < (int)last_reaction_per_section.size(); ++i) {
		last_reaction_per_section[i] = Vector3();
	}
	last_bone_impulses.clear();
	last_application_points.clear();

	if (p_dt <= 0.0f) return 0;
	if (axial_segments < 2 || angular_sectors < 2) return 0;
	if (wall_response_stiffness <= 0.0f) return 0;
	if (tunnel_state_integrator.is_null() || centerline_solver.is_null()) return 0;

	PackedFloat32Array displacement = tunnel_state_integrator->get_wall_displacement_snapshot();
	const int expected_cells = axial_segments * angular_sectors;
	if (displacement.size() != expected_cells) return 0;

	// Per-cross-section world position + outward normal. Centerline arc
	// uses the DEFORMED chain (matches §6.12.4's k -> s mapping). If the
	// chain has degenerated to zero length (test edge case), fall back to
	// integer-spaced sampling so basis_at still returns a sensible frame.
	const float total_arc = centerline_solver->get_total_arc_length();

	// Collect per-host-bone accumulators. RIDs aren't trivially hashable
	// in godot-cpp, so a linear scan over a small vector keeps the path
	// allocation-free. Typical canal: 1-3 unique host bones per tick.
	std::vector<RID> bone_rids_hit;
	std::vector<Vector3> bone_impulses;
	std::vector<Vector3> bone_application_origins; // load-weighted sum
	std::vector<float> bone_application_weights;
	bone_rids_hit.reserve(4);
	bone_impulses.reserve(4);
	bone_application_origins.reserve(4);
	bone_application_weights.reserve(4);

	const float two_pi = static_cast<float>(2.0 * Math_PI);

	for (int k = n_rim_exclusion; k < axial_segments; ++k) {
		const float s_norm = static_cast<float>(k)
				/ std::max(1.0f, static_cast<float>(axial_segments - 1));
		const float s = s_norm * total_arc;
		const Vector3 cross_section_pos = centerline_solver->evaluate_at(s);
		const Basis basis = centerline_solver->basis_at(s);
		const Vector3 normal = basis.get_column(1);
		const Vector3 binormal = basis.get_column(2);

		Vector3 reaction = Vector3();
		for (int j = 0; j < angular_sectors; ++j) {
			const float theta = two_pi * static_cast<float>(j)
					/ static_cast<float>(angular_sectors);
			const Vector3 outward = normal * std::cos(theta) + binormal * std::sin(theta);
			const float disp = displacement[k * angular_sectors + j];
			reaction -= outward * (wall_response_stiffness * disp);
		}
		last_reaction_per_section[k] = reaction;
		const float mag = reaction.length();
		if (mag < MIN_REACTION_LENGTH) continue;

		if (k >= (int)host_bone_rids.size()) continue;
		const RID bone_rid = host_bone_rids[k];
		if (!bone_rid.is_valid()) continue;

		// Find or allocate the bucket for this bone.
		int bucket = -1;
		for (int b = 0; b < (int)bone_rids_hit.size(); ++b) {
			if (bone_rids_hit[b] == bone_rid) {
				bucket = b;
				break;
			}
		}
		if (bucket < 0) {
			bucket = (int)bone_rids_hit.size();
			bone_rids_hit.push_back(bone_rid);
			bone_impulses.push_back(Vector3());
			bone_application_origins.push_back(Vector3());
			bone_application_weights.push_back(0.0f);
		}
		bone_impulses[bucket] += reaction * p_dt;
		bone_application_origins[bucket] += cross_section_pos * mag;
		bone_application_weights[bucket] += mag;
	}

	if (bone_rids_hit.empty()) return 0;

	PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
	last_bone_impulses.reserve(bone_rids_hit.size());
	last_application_points.reserve(bone_rids_hit.size());
	for (int b = 0; b < (int)bone_rids_hit.size(); ++b) {
		const float w = bone_application_weights[b];
		if (w <= 0.0f) continue;
		const Vector3 application_point = bone_application_origins[b] / w;
		last_bone_impulses.push_back(bone_impulses[b]);
		last_application_points.push_back(application_point);
		if (ps != nullptr) {
			// Mirrors Orifice's reaction-on-host-bone dispatch
			// (orifice.cpp:1892). The §6.12.12 pseudocode passes the
			// world-space application_point; PhysicsServer3D resolves the
			// offset to body frame internally.
			ps->body_apply_impulse(bone_rids_hit[b], bone_impulses[b], application_point);
		}
	}
	return (int)last_bone_impulses.size();
}

PackedVector3Array CanalReactionPass::get_last_reaction_per_section_snapshot() const {
	PackedVector3Array out;
	const int n = (int)last_reaction_per_section.size();
	out.resize(n);
	for (int i = 0; i < n; ++i) {
		out[i] = last_reaction_per_section[i];
	}
	return out;
}

PackedVector3Array CanalReactionPass::get_last_bone_impulse_snapshot() const {
	PackedVector3Array out;
	const int n = (int)last_bone_impulses.size();
	out.resize(n);
	for (int i = 0; i < n; ++i) {
		out[i] = last_bone_impulses[i];
	}
	return out;
}

PackedVector3Array CanalReactionPass::get_last_application_points_snapshot() const {
	PackedVector3Array out;
	const int n = (int)last_application_points.size();
	out.resize(n);
	for (int i = 0; i < n; ++i) {
		out[i] = last_application_points[i];
	}
	return out;
}

void CanalReactionPass::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "axial_segments", "angular_sectors",
								  "rest_radius_per_cell", "host_bone_rids",
								  "wall_response_stiffness", "n_rim_exclusion"),
			&CanalReactionPass::configure);
	ClassDB::bind_method(D_METHOD("set_centerline_solver", "solver"),
			&CanalReactionPass::set_centerline_solver);
	ClassDB::bind_method(D_METHOD("set_tunnel_state_integrator", "integrator"),
			&CanalReactionPass::set_tunnel_state_integrator);
	ClassDB::bind_method(D_METHOD("set_wall_response_stiffness", "k"),
			&CanalReactionPass::set_wall_response_stiffness);
	ClassDB::bind_method(D_METHOD("set_n_rim_exclusion", "n"),
			&CanalReactionPass::set_n_rim_exclusion);
	ClassDB::bind_method(D_METHOD("tick", "dt"), &CanalReactionPass::tick);
	ClassDB::bind_method(D_METHOD("get_last_reaction_per_section_snapshot"),
			&CanalReactionPass::get_last_reaction_per_section_snapshot);
	ClassDB::bind_method(D_METHOD("get_last_bone_impulse_snapshot"),
			&CanalReactionPass::get_last_bone_impulse_snapshot);
	ClassDB::bind_method(D_METHOD("get_last_application_points_snapshot"),
			&CanalReactionPass::get_last_application_points_snapshot);
}
