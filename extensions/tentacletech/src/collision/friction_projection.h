#ifndef TENTACLETECH_FRICTION_PROJECTION_H
#define TENTACLETECH_FRICTION_PROJECTION_H

#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include "../solver/tentacle_particle.h"

// Phase-4 slice 4B: unified PBD friction cone projection.
// Spec: docs/architecture/TentacleTech_Architecture.md §4.3.
//
// One header-only function so type-4 (slice 4B) and type-1 (slice 4D) share
// the cone math. The caller is responsible for:
//   - Already having performed the normal correction (caller knows `dn`,
//     the magnitude of normal projection it just applied).
//   - Routing reciprocals (type-1 → bone impulse, type-2 → host-bone pass);
//     this function only modifies the particle and reports `friction_applied`.

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
	// this self-zeroes inside the static cone (Δx_tangent collapses to 0 once
	// canceled and stays there until distance/bending reintroduce motion).
	godot::Vector3 dx = p.position - p.prev_position;
	godot::Vector3 dx_tangent = dx - n_unit * dx.dot(n_unit);
	float tangent_mag = dx_tangent.length();

	if (tangent_mag < 1e-8f || dn <= 0.0f) {
		out_friction_applied = godot::Vector3();
		return;
	}

	float static_cone = mu_s * dn;
	float kinetic_cone = mu_k * dn;

	if (tangent_mag < static_cone) {
		// Inside the static cone: cancel all tangential motion this tick.
		p.position -= dx_tangent;
		out_friction_applied = dx_tangent;
	} else {
		// Outside the static cone: cap tangential motion to the kinetic cone.
		float scale = 1.0f - (kinetic_cone / tangent_mag);
		if (scale < 0.0f) {
			scale = 0.0f;
		}
		godot::Vector3 delta = dx_tangent * scale;
		p.position -= delta;
		out_friction_applied = delta;
	}
}

} // namespace tentacletech

#endif // TENTACLETECH_FRICTION_PROJECTION_H
