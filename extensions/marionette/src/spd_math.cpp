#include "spd_math.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>

#include <cmath>

namespace godot {

// Shortest-arc error: rotation R such that R * current = target, in the
// same frame as both inputs (world-frame composition convention). The
// w<0 negation collapses the antipodal pair to the half with positive
// scalar, so `quaternion_to_axis_angle` returns the shorter rotation.
Quaternion SPDMath::error_quaternion(const Quaternion &p_current, const Quaternion &p_target) {
	Quaternion err = p_target * p_current.inverse();
	if (err.w < 0.0f) {
		err = Quaternion(-err.x, -err.y, -err.z, -err.w);
	}
	return err;
}

// axis * angle in radians. Identity (or near-identity) returns ZERO so
// downstream SPD torque is exactly zero at the target.
Vector3 SPDMath::quaternion_to_axis_angle(const Quaternion &p_error) {
	const double w = CLAMP(static_cast<double>(p_error.w), -1.0, 1.0);
	const double vx = p_error.x;
	const double vy = p_error.y;
	const double vz = p_error.z;
	const double v_len = std::sqrt(vx * vx + vy * vy + vz * vz);
	if (v_len < 1e-8) {
		return Vector3();
	}
	const double angle = 2.0 * std::atan2(v_len, w);
	const double scale = angle / v_len;
	return Vector3(
			static_cast<real_t>(vx * scale),
			static_cast<real_t>(vy * scale),
			static_cast<real_t>(vz * scale));
}

// Tan/Liu/Turk 2011 §2.2:
//   kp_stable = kp / (1 + kd*dt)
//   kd_stable = (kp*dt + kd) / (1 + kd*dt)
//   τ = kp_stable * error - kd_stable * omega
Vector3 SPDMath::compute_torque(const Vector3 &p_error_axis_angle, const Vector3 &p_omega,
		float p_kp, float p_kd, float p_dt) {
	const float denom = 1.0f + p_kd * p_dt;
	const float kp_stable = p_kp / denom;
	const float kd_stable = (p_kp * p_dt + p_kd) / denom;
	return p_error_axis_angle * kp_stable - p_omega * kd_stable;
}

void SPDMath::_bind_methods() {
	ClassDB::bind_static_method("SPDMath",
			D_METHOD("error_quaternion", "current", "target"),
			&SPDMath::error_quaternion);
	ClassDB::bind_static_method("SPDMath",
			D_METHOD("quaternion_to_axis_angle", "error"),
			&SPDMath::quaternion_to_axis_angle);
	ClassDB::bind_static_method("SPDMath",
			D_METHOD("compute_torque", "error_axis_angle", "omega", "kp", "kd", "dt"),
			&SPDMath::compute_torque);
}

} // namespace godot
