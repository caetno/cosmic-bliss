#include "marionette_core.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

String MarionetteCore::hello() const {
	return String("marionette_core ok");
}

void MarionetteCore::tick(double p_delta) {
	(void)p_delta;
}

void MarionetteCore::set_bone_target(const StringName &p_bone_name, const Vector3 &p_anatomical) {
	bone_targets[p_bone_name] = p_anatomical;
}

Vector3 MarionetteCore::get_bone_target(const StringName &p_bone_name) const {
	const HashMap<StringName, Vector3>::ConstIterator it = bone_targets.find(p_bone_name);
	if (it == bone_targets.end()) {
		return Vector3();
	}
	return it->value;
}

void MarionetteCore::clear_bone_targets() {
	bone_targets.clear();
}

void MarionetteCore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("hello"), &MarionetteCore::hello);
	ClassDB::bind_method(D_METHOD("tick", "delta"), &MarionetteCore::tick);
	ClassDB::bind_method(D_METHOD("set_bone_target", "bone_name", "anatomical"),
			&MarionetteCore::set_bone_target);
	ClassDB::bind_method(D_METHOD("get_bone_target", "bone_name"),
			&MarionetteCore::get_bone_target);
	ClassDB::bind_method(D_METHOD("clear_bone_targets"), &MarionetteCore::clear_bone_targets);
}

} // namespace godot
