#ifndef TENTACLETECH_FRICTION_PROJECTION_H
#define TENTACLETECH_FRICTION_PROJECTION_H

#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include "../solver/tentacle_particle.h"

// Phase-4 slice 4B+4G: unified PBD friction cone projection.
// Spec: docs/architecture/TentacleTech_Architecture.md §4.3 +
//       docs/Cosmic_Bliss_Update_2026-05-02_phase4_friction_correction.md
//
// One header-only function so type-4 (slice 4B) and type-1 (slice 4E) share
// the cone math. The caller is responsible for:
//   - Already having performed the normal correction (caller knows `dn`,
//     the magnitude of normal projection it just applied).
//   - Routing reciprocals (type-1 → bone impulse, type-2 → host-bone pass);
//     this function only modifies the particle and reports `friction_applied`.
//
// Slice 4G correction: the original spec form
//     scale = 1 − kinetic_cone / tangent_mag
//     cancel = tangent_mag × scale
// cancels (tangent_mag − kinetic_cone) of motion — i.e. *most* of the
// tangent motion when kinetic_cone is small relative to tangent_mag, which
// is the typical kinetic regime. That over-frictions the chain by ~10–20×
// in the kinetic regime AND over-states the type-1 reciprocal impulse by
// the same factor (J = friction_applied × m / dt). Replaced with the
// physics-correct cap:
//     cancel = min(tangent_mag, kinetic_cone)
// which limits friction to the impulse μ × N × dt where N is the implied
// normal force (m × dn / dt²). Same arithmetic cost — different operand.

namespace tentacletech {

// Projects tangential displacement of `p` against the friction cone defined
// by (mu_s, mu_k) at the contact whose outward normal is `n_unit` and whose
// just-applied normal correction had magnitude `dn` (positive).
//
// Mutates `p.position` in-place. Writes the displacement actually canceled
// into `out_friction_applied` (zero if no friction was applied this call).
inline void project_friction(TentacleParticle &p,
		const godot::Vector3 &n_unit,
		float dn,
		float mu_s,
		float mu_k,
		godot::Vector3 &out_friction_applied) {
	// `prev_position` is the start-of-tick reference (set by predict()), not
	// the last iteration's position — so the cancellation we compute here is
	// against the cumulative tangential motion of this tick. Across iterations
	// this naturally tapers as iter 1 already canceled what it could.
	godot::Vector3 dx = p.position - p.prev_position;
	godot::Vector3 dx_tangent = dx - n_unit * dx.dot(n_unit);
	float tangent_mag = dx_tangent.length();

	if (tangent_mag < 1e-8f || dn <= 0.0f) {
		out_friction_applied = godot::Vector3();
		return;
	}

	float static_cone = mu_s * dn;
	float kinetic_cone = mu_k * dn;

	if (tangent_mag <= static_cone) {
		// Inside the static cone: friction can fully oppose the motion.
		p.position -= dx_tangent;
		out_friction_applied = dx_tangent;
	} else {
		// Outside the static cone: friction caps at the kinetic cone — it
		// can cancel up to `kinetic_cone` of motion this iteration. Particle
		// continues with (tangent_mag − kinetic_cone) of tangential motion.
		// The body reciprocal in slice 4E reads `friction_applied` and
		// applies impulse = friction_applied × m / dt = μ_k × m × dn / dt
		// = μ_k × N × dt — physically correct kinetic friction impulse.
		godot::Vector3 dx_tangent_dir = dx_tangent / tangent_mag;
		godot::Vector3 cancel = dx_tangent_dir * kinetic_cone;
		p.position -= cancel;
		out_friction_applied = cancel;
	}
}

} // namespace tentacletech

#endif // TENTACLETECH_FRICTION_PROJECTION_H
