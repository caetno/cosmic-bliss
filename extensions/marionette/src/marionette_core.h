#ifndef MARIONETTE_CORE_H
#define MARIONETTE_CORE_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

// Phase 2.0 scaffold: proves the GDScript -> C++ bridge.
// Phase 5 Slice 3a: per-bone anatomical target cache. `Marionette.gd`
// forwards `set_bone_target(...)` once per change; slice 3b's
// `MarionetteBone::_integrate_forces` reads from this cache (no per-tick
// GDScript dispatch). Real composer/SPD/IK populate this class in later
// phases.
class MarionetteCore : public Node {
	GDCLASS(MarionetteCore, Node)

public:
	MarionetteCore() = default;
	~MarionetteCore() = default;

	String hello() const;
	void tick(double p_delta);

	// Anatomical target cache. Components are (flex, along-bone-twist,
	// abduction) in canonical positive-flex / positive-medial / positive-
	// abduction convention; side flip happens at solver time. Absent bones
	// return Vector3() — the sentinel matches the SPD identity target.
	void set_bone_target(const StringName &p_bone_name, const Vector3 &p_anatomical);
	Vector3 get_bone_target(const StringName &p_bone_name) const;
	void clear_bone_targets();

	// Global strength multiplier. Per-bone SPD gain scales by
	// `core.get_bone_strength(name) * core.global_strength`. The global side
	// arrived in slice 3b; per-bone overrides land in slice 4r (P5.4).
	void set_global_strength(float p_strength);
	float get_global_strength() const;

	// Per-bone strength override (P5.4 slice 4r). When set, takes precedence
	// over the BoneEntry-derived default cached on `MarionetteBone::strength`.
	// Clearing reverts to the bone's cached default. Absent overrides return
	// p_default (the caller's cached entry default) — the SPD path passes its
	// `strength` field so the math seam stays mass-independent.
	void set_bone_strength(const StringName &p_bone_name, float p_value);
	void clear_bone_strength(const StringName &p_bone_name);
	float get_bone_strength(const StringName &p_bone_name, float p_default) const;
	bool has_bone_strength_override(const StringName &p_bone_name) const;

protected:
	static void _bind_methods();

private:
	HashMap<StringName, Vector3> bone_targets;
	HashMap<StringName, float> bone_strength_overrides;
	float global_strength = 1.0f;
};

} // namespace godot

#endif // MARIONETTE_CORE_H
