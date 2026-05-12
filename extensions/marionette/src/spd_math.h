#ifndef MARIONETTE_SPD_MATH_H
#define MARIONETTE_SPD_MATH_H

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

// Phase 5 P5.1 — static math helpers for the stable PD controller of
// Tan, Liu, Turk 2011 ("Stable Proportional-Derivative Controllers").
// All methods are frame-agnostic: the caller chooses world / body / joint
// space and is responsible for the matching conversion of `omega`.
class SPDMath : public Object {
	GDCLASS(SPDMath, Object)

public:
	static Quaternion error_quaternion(const Quaternion &p_current, const Quaternion &p_target);
	static Vector3 quaternion_to_axis_angle(const Quaternion &p_error);
	static Vector3 compute_torque(const Vector3 &p_error_axis_angle, const Vector3 &p_omega,
			float p_kp, float p_kd, float p_dt);

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // MARIONETTE_SPD_MATH_H
