#include "marionette_core.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>

#include "marionette_bone.h"

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

void MarionetteCore::set_global_strength(float p_strength) {
	global_strength = p_strength;
}

float MarionetteCore::get_global_strength() const {
	return global_strength;
}

void MarionetteCore::set_bone_strength(const StringName &p_bone_name, float p_value) {
	bone_strength_overrides[p_bone_name] = p_value;
}

void MarionetteCore::clear_bone_strength(const StringName &p_bone_name) {
	bone_strength_overrides.erase(p_bone_name);
}

float MarionetteCore::get_bone_strength(const StringName &p_bone_name, float p_default) const {
	const HashMap<StringName, float>::ConstIterator it = bone_strength_overrides.find(p_bone_name);
	if (it == bone_strength_overrides.end()) {
		return p_default;
	}
	return it->value;
}

bool MarionetteCore::has_bone_strength_override(const StringName &p_bone_name) const {
	return bone_strength_overrides.find(p_bone_name) != bone_strength_overrides.end();
}

void MarionetteCore::set_gravity_scale(float p_value) {
	gravity_scale = p_value;
	// Push to every registered RigidBody3D. Cheap (84 bones, one property
	// write each); called rarely (gameplay state change, not per-tick).
	for (MarionetteBone *bone : registered_bones) {
		if (bone != nullptr) {
			bone->set_gravity_scale(p_value);
		}
	}
}

float MarionetteCore::get_gravity_scale() const {
	return gravity_scale;
}

void MarionetteCore::set_hip_upward_nudge(float p_value) {
	hip_upward_nudge = p_value;
}

float MarionetteCore::get_hip_upward_nudge() const {
	return hip_upward_nudge;
}

void MarionetteCore::set_hip_nudge_strength_threshold(float p_value) {
	hip_nudge_strength_threshold = p_value;
}

float MarionetteCore::get_hip_nudge_strength_threshold() const {
	return hip_nudge_strength_threshold;
}

float MarionetteCore::get_global_strength_factor() const {
	if (hip_nudge_strength_threshold <= 0.0f) {
		// Threshold of zero: factor is 1 whenever global_strength > 0,
		// else 0. Avoids divide-by-zero in the linear ramp branch below.
		return global_strength > 0.0f ? 1.0f : 0.0f;
	}
	if (global_strength >= hip_nudge_strength_threshold) {
		return 1.0f;
	}
	if (global_strength <= 0.0f) {
		return 0.0f;
	}
	// Linear ramp from (0, 0) to (threshold, 1). Caps at both ends.
	return global_strength / hip_nudge_strength_threshold;
}

void MarionetteCore::register_bone(MarionetteBone *p_bone) {
	if (p_bone == nullptr) {
		return;
	}
	registered_bones.insert(p_bone);
	// Apply current gravity_scale immediately so newly-built bones don't
	// stay at the engine default 1.0 when the user has dialed it down.
	p_bone->set_gravity_scale(gravity_scale);
}

void MarionetteCore::unregister_bone(MarionetteBone *p_bone) {
	registered_bones.erase(p_bone);
	if (root_bone == p_bone) {
		root_bone = nullptr;
	}
}

void MarionetteCore::set_root_bone(MarionetteBone *p_bone) {
	root_bone = p_bone;
}

MarionetteBone *MarionetteCore::get_root_bone_ptr() const {
	return root_bone;
}

Object *MarionetteCore::get_root_bone() const {
	// Returns Object* (bindable) instead of MarionetteBone* (not). GDScript
	// callers receive null if the build path hasn't flagged a root yet.
	return root_bone;
}

void MarionetteCore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("hello"), &MarionetteCore::hello);
	ClassDB::bind_method(D_METHOD("tick", "delta"), &MarionetteCore::tick);
	ClassDB::bind_method(D_METHOD("set_bone_target", "bone_name", "anatomical"),
			&MarionetteCore::set_bone_target);
	ClassDB::bind_method(D_METHOD("get_bone_target", "bone_name"),
			&MarionetteCore::get_bone_target);
	ClassDB::bind_method(D_METHOD("clear_bone_targets"), &MarionetteCore::clear_bone_targets);
	ClassDB::bind_method(D_METHOD("set_global_strength", "strength"),
			&MarionetteCore::set_global_strength);
	ClassDB::bind_method(D_METHOD("get_global_strength"),
			&MarionetteCore::get_global_strength);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "global_strength"),
			"set_global_strength", "get_global_strength");

	ClassDB::bind_method(D_METHOD("set_bone_strength", "bone_name", "value"),
			&MarionetteCore::set_bone_strength);
	ClassDB::bind_method(D_METHOD("clear_bone_strength", "bone_name"),
			&MarionetteCore::clear_bone_strength);
	ClassDB::bind_method(D_METHOD("get_bone_strength", "bone_name", "default_value"),
			&MarionetteCore::get_bone_strength);
	ClassDB::bind_method(D_METHOD("has_bone_strength_override", "bone_name"),
			&MarionetteCore::has_bone_strength_override);

	ClassDB::bind_method(D_METHOD("set_gravity_scale", "value"),
			&MarionetteCore::set_gravity_scale);
	ClassDB::bind_method(D_METHOD("get_gravity_scale"),
			&MarionetteCore::get_gravity_scale);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "gravity_scale"),
			"set_gravity_scale", "get_gravity_scale");

	ClassDB::bind_method(D_METHOD("set_hip_upward_nudge", "value"),
			&MarionetteCore::set_hip_upward_nudge);
	ClassDB::bind_method(D_METHOD("get_hip_upward_nudge"),
			&MarionetteCore::get_hip_upward_nudge);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "hip_upward_nudge"),
			"set_hip_upward_nudge", "get_hip_upward_nudge");

	ClassDB::bind_method(D_METHOD("set_hip_nudge_strength_threshold", "value"),
			&MarionetteCore::set_hip_nudge_strength_threshold);
	ClassDB::bind_method(D_METHOD("get_hip_nudge_strength_threshold"),
			&MarionetteCore::get_hip_nudge_strength_threshold);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "hip_nudge_strength_threshold"),
			"set_hip_nudge_strength_threshold", "get_hip_nudge_strength_threshold");

	ClassDB::bind_method(D_METHOD("get_global_strength_factor"),
			&MarionetteCore::get_global_strength_factor);

	ClassDB::bind_method(D_METHOD("get_root_bone"), &MarionetteCore::get_root_bone);
}

} // namespace godot
