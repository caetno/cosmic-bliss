#ifndef TENTACLETECH_CONSTRAINTS_H
#define TENTACLETECH_CONSTRAINTS_H

#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include "tentacle_particle.h"

// Pure projection functions per §3.3 (Phase-2 subset: distance, bending,
// target-pull, anchor). Collision/friction/attachment land in Phase 4.
//
// All projection math operates on particle position arrays directly. No force
// accumulation, no allocation, no class state.
namespace tentacletech {
namespace constraints {

// Distance between particles a and b → rest_length, weighted by inverse mass.
// Stiffness scales the correction (1.0 = full, 0.0 = ignore).
void project_distance(
		TentacleParticle &p_a,
		TentacleParticle &p_b,
		float p_rest_length,
		float p_stiffness);

// Bending around the middle particle b. Targets the angle between (a→b) and
// (b→c) toward the rest angle. Implementation: distance constraint between a
// and c with rest equal to the chord length of the rest triangle, scaled by
// stiffness — a common simple bending formulation that's stable for small
// stiffness values.
void project_bending(
		TentacleParticle &p_a,
		TentacleParticle &p_b,
		TentacleParticle &p_c,
		float p_rest_chord_length,
		float p_stiffness);

// Soft pull of particle p toward target world position. Stiffness in [0, 1] —
// fraction of the gap closed per iteration. Pinned particles (inv_mass = 0) are
// not moved. No-op if stiffness ≤ 0.
void project_target_pull(
		TentacleParticle &p_particle,
		const godot::Vector3 &p_target,
		float p_stiffness);

// Hard pin of a particle to a world transform's origin. Always applied last so
// that earlier projections cannot violate the anchor. Sets prev_position to
// match position so the implicit velocity is zero across the anchor.
void project_anchor(
		TentacleParticle &p_particle,
		const godot::Transform3D &p_world_xform);

} // namespace constraints
} // namespace tentacletech

#endif // TENTACLETECH_CONSTRAINTS_H
