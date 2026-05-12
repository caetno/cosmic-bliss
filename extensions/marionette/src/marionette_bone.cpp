#include "marionette_bone.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void MarionetteBone::set_bone_entry(const Ref<Resource> &p_entry) {
	bone_entry = p_entry;
}

Ref<Resource> MarionetteBone::get_bone_entry() const {
	return bone_entry;
}

// Slice 2 stub. Slice 3 populates this with the SPD path
// (Tan/Liu/Turk via SPDMath::compute_torque). Until then `custom_integrator`
// stays at PhysicalBone3D's default (false) so Jolt's built-in integrator
// + the GDScript-side `_apply_joint_constraints` spring path run unchanged.
void MarionetteBone::_integrate_forces(PhysicsDirectBodyState3D *p_state) {
	(void)p_state;
}

void MarionetteBone::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_bone_entry", "entry"), &MarionetteBone::set_bone_entry);
	ClassDB::bind_method(D_METHOD("get_bone_entry"), &MarionetteBone::get_bone_entry);

	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "bone_entry",
						 PROPERTY_HINT_RESOURCE_TYPE, "BoneEntry"),
			"set_bone_entry", "get_bone_entry");
}

} // namespace godot
