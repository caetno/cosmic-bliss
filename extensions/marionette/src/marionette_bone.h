#ifndef MARIONETTE_BONE_H
#define MARIONETTE_BONE_H

#include <godot_cpp/classes/physical_bone3d.hpp>
#include <godot_cpp/classes/physics_direct_body_state3d.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/object.hpp>

namespace godot {

// Phase 5 Slice 2 — mechanical port of the GDScript marker class to C++.
// PhysicalBoneSimulator3D attaches this to the named skeleton bone; gizmos
// and (in Slice 3) the SPD path look up anatomical metadata via
// `bone_entry`. Slice 2 keeps `_integrate_forces` a no-op so the existing
// Jolt-driven, spring-stabilized behavior is bit-identical.
//
// `bone_entry` is typed `Ref<Resource>` (not `Ref<BoneEntry>`) because
// BoneEntry is a GDScript Resource subclass with no C++ type. The
// PROPERTY_HINT_RESOURCE_TYPE("BoneEntry") in `_bind_methods` filters the
// inspector dropdown to that script-class.
class MarionetteBone : public PhysicalBone3D {
	GDCLASS(MarionetteBone, PhysicalBone3D)

public:
	MarionetteBone() = default;
	~MarionetteBone() = default;

	void set_bone_entry(const Ref<Resource> &p_entry);
	Ref<Resource> get_bone_entry() const;

	void _integrate_forces(PhysicsDirectBodyState3D *p_state) override;

protected:
	static void _bind_methods();

private:
	Ref<Resource> bone_entry;
};

} // namespace godot

#endif // MARIONETTE_BONE_H
