#ifndef TENTACLETECH_TENTACLE_PARTICLE_H
#define TENTACLETECH_TENTACLE_PARTICLE_H

#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

// Per-particle state. Spec: docs/architecture/TentacleTech_Architecture.md §3.1.
//
// Pure POD — no methods, no virtuals. Solver and constraint code touch the
// fields directly.
//
// Slice 4S.1 (2026-05-05): `velocity` is now an explicit first-class state
// variable (symplectic Euler form, lifted from Obi `Solver.compute` +
// `Integration.cginc`). `prev_position` is still tracked for the friction
// step's per-tick tangent-motion read (`position - prev_position`); under
// Euler it represents "position at the start of this substep's predict()"
// so friction sees the substep-local Δx for cone projection. Damping +
// contact_velocity_damping + sleep_threshold migrated to velocity-decay
// forms in finalize(); see PBDSolver::predict / PBDSolver::finalize.
//
// `girth_scale` is updated post-solve from segment stretch (volume preservation,
// §3.4). `asymmetry` is updated by orifice ring pressure (§6.3) — its magnitude
// is clamped to 0.5 by the solver after the smoothing pass.
struct TentacleParticle {
	godot::Vector3 position;
	godot::Vector3 prev_position;
	godot::Vector3 velocity;   // Slice 4S.1 — explicit state (m/s)
	float inv_mass = 1.0f;     // 0 = pinned (base anchor), 1/m otherwise
	float girth_scale = 1.0f;  // radial scalar, 0.3..1.5 (1 = rest)
	godot::Vector2 asymmetry;  // directional squeeze in particle-local frame; |·| ≤ 0.5

	// Phase-4 slice 4C (§4.3): set inside the per-iteration collision pass when
	// this particle had a non-zero normal correction this tick; cleared at the
	// start of each tick by predict(). The distance-constraint projection uses
	// it to drop segment stiffness from `distance_stiffness` to a tunable
	// `contact_stiffness` so the chain can stretch temporarily over wrapped
	// geometry instead of fighting the collision push-out.
	bool in_contact_this_tick = false;
};

#endif // TENTACLETECH_TENTACLE_PARTICLE_H
