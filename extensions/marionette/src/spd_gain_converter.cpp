#include "spd_gain_converter.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>

namespace godot {

Vector2 SPDGainConverter::compute_gains(float p_alpha, float p_damping_ratio, float p_mass, float p_dt) {
	ERR_FAIL_COND_V_MSG(p_alpha <= 0.0f, Vector2(), "SPDGainConverter: alpha must be > 0");
	ERR_FAIL_COND_V_MSG(p_mass <= 0.0f, Vector2(), "SPDGainConverter: mass must be > 0");
	ERR_FAIL_COND_V_MSG(p_dt <= 0.0f, Vector2(), "SPDGainConverter: dt must be > 0");

	const float omega_n = 1.0f / (p_alpha * p_dt);
	const float kp = p_mass * omega_n * omega_n;
	const float kd = p_mass * 2.0f * p_damping_ratio * omega_n;
	return Vector2(kp, kd);
}

void SPDGainConverter::_bind_methods() {
	ClassDB::bind_static_method("SPDGainConverter",
			D_METHOD("compute_gains", "alpha", "damping_ratio", "mass", "dt"),
			&SPDGainConverter::compute_gains);
}

} // namespace godot
