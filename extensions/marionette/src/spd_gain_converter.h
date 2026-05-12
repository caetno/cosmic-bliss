#ifndef MARIONETTE_SPD_GAIN_CONVERTER_H
#define MARIONETTE_SPD_GAIN_CONVERTER_H

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/vector2.hpp>

namespace godot {

// Phase 5 P5.2 — mass-portable SPD gain derivation.
//   omega_n = 1 / (alpha * dt)     // alpha = time constant in timestep units
//   kp      = mass * omega_n^2
//   kd      = mass * 2 * damping_ratio * omega_n
// Returns Vector2(kp, kd). Multi-out via Vector2 (not Dictionary or
// reference args) keeps the bind path simple.
class SPDGainConverter : public Object {
	GDCLASS(SPDGainConverter, Object)

public:
	static Vector2 compute_gains(float p_alpha, float p_damping_ratio, float p_mass, float p_dt);

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // MARIONETTE_SPD_GAIN_CONVERTER_H
