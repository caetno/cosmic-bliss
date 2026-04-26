#ifndef TENTACLETECH_TENTACLE_PARTICLE_H
#define TENTACLETECH_TENTACLE_PARTICLE_H

#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

// Per-particle state. Spec: docs/architecture/TentacleTech_Architecture.md §3.1.
//
// Pure POD — no methods, no virtuals. Solver and constraint code touch the
// fields directly. Velocity is implicit: (position - prev_position) / dt.
//
// `girth_scale` is updated post-solve from segment stretch (volume preservation,
// §3.4). `asymmetry` is updated by orifice ring pressure (§6.3) — its magnitude
// is clamped to 0.5 by the solver after the smoothing pass.
struct TentacleParticle {
	godot::Vector3 position;
	godot::Vector3 prev_position;
	float inv_mass = 1.0f;     // 0 = pinned (base anchor), 1/m otherwise
	float girth_scale = 1.0f;  // radial scalar, 0.3..1.5 (1 = rest)
	godot::Vector2 asymmetry;  // directional squeeze in particle-local frame; |·| ≤ 0.5
};

#endif // TENTACLETECH_TENTACLE_PARTICLE_H
