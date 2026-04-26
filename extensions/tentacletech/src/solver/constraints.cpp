#include "constraints.h"

#include <godot_cpp/core/math.hpp>

using namespace godot;

namespace tentacletech {
namespace constraints {

void project_distance(
		TentacleParticle &p_a,
		TentacleParticle &p_b,
		float p_rest_length,
		float p_stiffness) {
	// PBD distance: positions move along the line, weighted by inverse mass.
	// Σw == 0 → both pinned → nothing to do.
	float w_sum = p_a.inv_mass + p_b.inv_mass;
	if (w_sum <= 0.0f) {
		return;
	}
	Vector3 delta = p_b.position - p_a.position;
	float dist = delta.length();
	if (dist < 1e-8f) {
		return;
	}
	float diff = dist - p_rest_length;
	Vector3 dir = delta / dist;
	Vector3 correction = dir * (p_stiffness * diff / w_sum);
	p_a.position += correction * p_a.inv_mass;
	p_b.position -= correction * p_b.inv_mass;
}

void project_bending(
		TentacleParticle &p_a,
		TentacleParticle &p_b,
		TentacleParticle &p_c,
		float p_rest_chord_length,
		float p_stiffness) {
	// Simple chord-length bending: the longer the (a-c) chord vs rest, the
	// straighter the elbow is. Stiffness in [0, 1].
	float w_sum = p_a.inv_mass + p_c.inv_mass;
	if (w_sum <= 0.0f) {
		return;
	}
	Vector3 delta = p_c.position - p_a.position;
	float dist = delta.length();
	if (dist < 1e-8f) {
		return;
	}
	float diff = dist - p_rest_chord_length;
	Vector3 dir = delta / dist;
	Vector3 correction = dir * (p_stiffness * diff / w_sum);
	p_a.position += correction * p_a.inv_mass;
	p_c.position -= correction * p_c.inv_mass;
	(void)p_b; // middle particle not moved by this formulation
}

void project_target_pull(
		TentacleParticle &p_particle,
		const Vector3 &p_target,
		float p_stiffness) {
	if (p_stiffness <= 0.0f || p_particle.inv_mass <= 0.0f) {
		return;
	}
	Vector3 delta = p_target - p_particle.position;
	p_particle.position += delta * p_stiffness;
}

void project_anchor(
		TentacleParticle &p_particle,
		const Transform3D &p_world_xform) {
	p_particle.position = p_world_xform.origin;
	p_particle.prev_position = p_particle.position;
}

} // namespace constraints
} // namespace tentacletech
