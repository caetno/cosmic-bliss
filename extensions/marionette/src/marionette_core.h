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

protected:
	static void _bind_methods();

private:
	HashMap<StringName, Vector3> bone_targets;
};

} // namespace godot

#endif // MARIONETTE_CORE_H
