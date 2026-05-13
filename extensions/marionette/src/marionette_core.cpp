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

void MarionetteCore::_ready() {
	// Enable per-tick callback so `step_strength_ramps` runs without the
	// GDScript wrapper needing to forward every delta.
	set_physics_process(true);
}

void MarionetteCore::_physics_process(double p_delta) {
	// Slice 6 — march effective strengths toward requested at
	// 1.0 / strength_ramp_duration per second on increases; drops are
	// already snapped at set-time.
	step_strength_ramps(static_cast<float>(p_delta));
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
	// Slice 6 — drops are instantaneous (limp-on-shock contract). Increases
	// wait for `step_strength_ramps` to catch effective up. Equal values
	// no-op (idempotent set from inspectors).
	const float prior_requested = global_strength;
	global_strength = p_strength;
	if (p_strength <= effective_global_strength) {
		effective_global_strength = p_strength; // Instant drop.
	}
	(void)prior_requested;
}

float MarionetteCore::get_global_strength() const {
	// Slice 6 — the SPD path reads EFFECTIVE, which lags requested when
	// ramping up. `get_requested_global_strength` exposes the dialed value
	// for tooling that wants to show both.
	return effective_global_strength;
}

float MarionetteCore::get_requested_global_strength() const {
	return global_strength;
}

void MarionetteCore::set_bone_strength(const StringName &p_bone_name, float p_value) {
	bone_strength_overrides[p_bone_name] = p_value;
	// Seed effective on first set, then handle the limp-instant contract:
	// drops snap to value, increases wait for ramp.
	HashMap<StringName, float>::Iterator eff_it = bone_strength_effective.find(p_bone_name);
	if (eff_it == bone_strength_effective.end()) {
		// First-time override. Start effective at the requested value if
		// transitioning DOWN from the prior caller-default (we don't know
		// the prior default value, so the conservative choice is to seed
		// equal — the ramp simply runs from current to itself, no visible
		// change. The first user-driven INCREASE seeds the ramp baseline
		// at the previous effective value, captured below on second call.).
		bone_strength_effective[p_bone_name] = p_value;
	} else if (p_value <= eff_it->value) {
		eff_it->value = p_value; // Instant drop.
	}
	// Increase case: leave effective alone — `step_strength_ramps` will
	// march it up over `strength_ramp_duration`.
}

void MarionetteCore::clear_bone_strength(const StringName &p_bone_name) {
	bone_strength_overrides.erase(p_bone_name);
	bone_strength_effective.erase(p_bone_name);
}

float MarionetteCore::get_bone_strength(const StringName &p_bone_name, float p_default) const {
	const HashMap<StringName, float>::ConstIterator it = bone_strength_effective.find(p_bone_name);
	if (it == bone_strength_effective.end()) {
		return p_default;
	}
	return it->value;
}

float MarionetteCore::get_requested_bone_strength(const StringName &p_bone_name, float p_default) const {
	const HashMap<StringName, float>::ConstIterator it = bone_strength_overrides.find(p_bone_name);
	if (it == bone_strength_overrides.end()) {
		return p_default;
	}
	return it->value;
}

bool MarionetteCore::has_bone_strength_override(const StringName &p_bone_name) const {
	return bone_strength_overrides.find(p_bone_name) != bone_strength_overrides.end();
}

void MarionetteCore::set_strength_ramp_duration(float p_seconds) {
	strength_ramp_duration = p_seconds;
}

float MarionetteCore::get_strength_ramp_duration() const {
	return strength_ramp_duration;
}

void MarionetteCore::step_strength_ramps(float p_delta) {
	// Rate of climb in strength-units / second. 0 / negative duration = snap.
	if (p_delta <= 0.0f) {
		return;
	}
	const bool snap = strength_ramp_duration <= 0.0f;
	const float step = snap ? 1e9f : p_delta / strength_ramp_duration;

	// Global ramp.
	if (effective_global_strength < global_strength) {
		effective_global_strength = Math::min(global_strength, effective_global_strength + step);
	}
	// Per-bone ramps. Decreases are already handled at set-time (snap).
	for (HashMap<StringName, float>::Iterator it = bone_strength_overrides.begin();
			it != bone_strength_overrides.end(); ++it) {
		const StringName &name = it->key;
		const float requested = it->value;
		HashMap<StringName, float>::Iterator eff_it = bone_strength_effective.find(name);
		if (eff_it == bone_strength_effective.end()) {
			// Should never happen — set_bone_strength always seeds. Defensive.
			bone_strength_effective[name] = requested;
			continue;
		}
		if (eff_it->value < requested) {
			eff_it->value = Math::min(requested, eff_it->value + step);
		}
	}
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
	// Slice 6 — read effective (post-ramp) so the hip nudge tracks what the
	// SPD path actually sees. A character ramping up from limp gets the
	// nudge smoothly enabled in lock-step with the rest of the muscle drive.
	const float gs = effective_global_strength;
	if (hip_nudge_strength_threshold <= 0.0f) {
		// Threshold of zero: factor is 1 whenever effective > 0, else 0.
		// Avoids divide-by-zero in the linear ramp branch below.
		return gs > 0.0f ? 1.0f : 0.0f;
	}
	if (gs >= hip_nudge_strength_threshold) {
		return 1.0f;
	}
	if (gs <= 0.0f) {
		return 0.0f;
	}
	// Linear ramp from (0, 0) to (threshold, 1). Caps at both ends.
	return gs / hip_nudge_strength_threshold;
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

	ClassDB::bind_method(D_METHOD("set_strength_ramp_duration", "seconds"),
			&MarionetteCore::set_strength_ramp_duration);
	ClassDB::bind_method(D_METHOD("get_strength_ramp_duration"),
			&MarionetteCore::get_strength_ramp_duration);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "strength_ramp_duration"),
			"set_strength_ramp_duration", "get_strength_ramp_duration");

	ClassDB::bind_method(D_METHOD("get_requested_bone_strength", "bone_name", "default_value"),
			&MarionetteCore::get_requested_bone_strength);
	ClassDB::bind_method(D_METHOD("get_requested_global_strength"),
			&MarionetteCore::get_requested_global_strength);
	ClassDB::bind_method(D_METHOD("step_strength_ramps", "delta"),
			&MarionetteCore::step_strength_ramps);
}

} // namespace godot
