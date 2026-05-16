#ifndef MARIONETTE_BONE_H
#define MARIONETTE_BONE_H

#include <godot_cpp/classes/physical_bone3d.hpp>
#include <godot_cpp/classes/physics_direct_body_state3d.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

class MarionetteCore;

// Phase 5 Slice 2 — mechanical port of the GDScript marker class to C++.
// PhysicalBoneSimulator3D attaches this to the named skeleton bone; gizmos
// and (slice 3+) the SPD path look up anatomical metadata via `bone_entry`.
//
// Slice 3b — `_integrate_forces` becomes the live SPD loop for POWERED
// bones. KINEMATIC / UNPOWERED return immediately (custom_integrator stays
// off for those states so Jolt's default integrator runs gravity etc.).
//
// `bone_entry` is typed `Ref<Resource>` (not `Ref<BoneEntry>`) because
// BoneEntry is a GDScript Resource subclass with no C++ type. The
// PROPERTY_HINT_RESOURCE_TYPE("BoneEntry") in `_bind_methods` filters the
// inspector dropdown to that script-class.
class MarionetteBone : public PhysicalBone3D {
	GDCLASS(MarionetteBone, PhysicalBone3D)

public:
	// Mirrors BoneStateProfile.State (gdscript/resources/bone_state_profile.gd).
	// Kept as bare int values rather than a C++ enum so the GDScript wrapper
	// can pass BoneStateProfile.State.* through `set()` without a cast layer.
	enum State {
		STATE_KINEMATIC = 0,
		STATE_POWERED = 1,
		STATE_UNPOWERED = 2,
	};

	MarionetteBone() = default;
	~MarionetteBone();

	void set_bone_entry(const Ref<Resource> &p_entry);
	Ref<Resource> get_bone_entry() const;

	void set_current_state(int p_state);
	int get_current_state() const;

	// Slice 3b — solver-time cache populated from the BoneEntry by the
	// GDScript wrapper at build_ragdoll. Reading these every tick beats
	// reaching into a Resource via `get()`.
	void set_alpha(float p_alpha);
	float get_alpha() const;
	void set_damping_ratio(float p_ratio);
	float get_damping_ratio() const;
	void set_strength(float p_strength);
	float get_strength() const;
	void set_max_torque(float p_max);
	float get_max_torque() const;
	void set_mirror_abd(bool p_v);
	bool get_mirror_abd() const;
	void set_is_left_side(bool p_v);
	bool get_is_left_side() const;
	// Archetype is BALL / HINGE / etc. — only needed here so the sided-
	// medial-rotation flip can pick the same set of archetypes as
	// AnatomicalPose.bone_local_rotation. Stored as the underlying enum int.
	void set_archetype(int p_v);
	int get_archetype() const;
	void set_rest_anatomical_offset(const Vector3 &p_v);
	Vector3 get_rest_anatomical_offset() const;
	// Bone-local columns (flex, along-bone, abduction). Identity if not
	// provided. Equivalent to `entry.anatomical_basis_in_bone_local()`.
	void set_anatomical_basis(const Basis &p_v);
	Basis get_anatomical_basis() const;

	// MarionetteCore is found once at build-time (no scene-tree walks per
	// tick). Held as a raw Node * because Core is a sibling Node, not a
	// Ref-counted Object.
	void set_core(Object *p_core);
	Object *get_core() const;

	// Slice 5 (P5.5) — marks this bone as the ragdoll root (hip). The build
	// path identifies the root (no MarionetteBone parent in the simulator
	// hierarchy) and flips this flag; `_integrate_forces` consults it to
	// decide whether to apply `MarionetteCore::hip_upward_nudge`.
	void set_is_root(bool p_v);
	bool get_is_root() const;

	// Cached anatomical name (same as BoneProfile entry key). Differs from
	// the inherited `bone_name` StringName proxy in that it's pre-resolved
	// at build to handle BoneMap rename paths.
	void set_anatomical_name(const StringName &p_name);
	StringName get_anatomical_name() const;

	// Slice 3b test seam — bypasses _integrate_forces / state requirements
	// so unit tests can probe the SPD math path directly. Returns the world-
	// space torque the integrator WOULD apply for the given inputs.
	// Uses this bone's cached `strength` as the per-bone gain; for slice 4r
	// override tests, see `compute_spd_torque_for_test_ex` which lets the
	// caller inject an effective bone strength independently.
	Vector3 compute_spd_torque_for_test(
			const Quaternion &p_current_rel_parent,
			const Vector3 &p_anatomical_target,
			const Vector3 &p_omega_world,
			const Basis &p_parent_world_basis,
			float p_mass,
			float p_dt,
			float p_global_strength) const;

	// Slice 4r test seam — same path with an explicit `bone_strength` input.
	// This is what `_integrate_forces` calls under the hood, passing the
	// MarionetteCore-resolved effective strength (override > entry default).
	// Tests cover the override-take-precedence and limp-at-zero contracts.
	Vector3 compute_spd_torque_for_test_ex(
			const Quaternion &p_current_rel_parent,
			const Vector3 &p_anatomical_target,
			const Vector3 &p_omega_world,
			const Basis &p_parent_world_basis,
			float p_mass,
			float p_dt,
			float p_bone_strength,
			float p_global_strength) const;

	// Slice P10.7-min — tracking-error magnitude in radians. Same target-
	// composition path as the SPD torque (uses `compose_target_bone_local`
	// on the anatomical Vector3 input, then `SPDMath::error_quaternion` /
	// `quaternion_to_axis_angle` to get the rotation magnitude separating
	// current from target). Returned value is `|axis × angle|` in [0, π].
	// MarionetteCore::compute_body_strain calls this per registered bone
	// once per `_physics_process` frame; the spec-vs-physics conflict
	// "target is stored as anatomical angles, not a quaternion" is resolved
	// by routing through the existing private composer (same conversion
	// the SPD path uses, so strain reads what the controller is fighting).
	float compute_tracking_error_radians(
			const Quaternion &p_current_rel_parent,
			const Vector3 &p_anatomical_target) const;

	void _integrate_forces(PhysicsDirectBodyState3D *p_state) override;

protected:
	static void _bind_methods();

private:
	Ref<Resource> bone_entry;
	int current_state = STATE_POWERED;

	// SPD authoring/runtime data, cached from the BoneEntry.
	float alpha = 4.0f;
	float damping_ratio = 1.0f;
	float strength = 1.0f;
	float max_torque = 0.0f; // 0 disables the clamp.
	bool mirror_abd = false;
	bool is_left_side = false;
	int archetype = -1; // -1 sentinel = not configured.
	Vector3 rest_anatomical_offset;
	Basis anatomical_basis; // bone-local columns (flex, along, abd).

	// Cached pointers used per-tick.
	Object *core = nullptr; // MarionetteCore (sibling Node, not Ref-counted).
	StringName anatomical_name;

	// Slice 5 — set by build_ragdoll on the hip (the bone with no
	// MarionetteBone parent in the simulator hierarchy). `_integrate_forces`
	// applies `MarionetteCore::hip_upward_nudge` only on this bone.
	bool is_root = false;

	// Composes an anatomical (flex, twist, abd) Vector3 into a target
	// rotation expressed in the bone's local frame, matching
	// AnatomicalPose.bone_local_rotation (rest-offset subtraction +
	// side-mirror compensation + intrinsic flex→twist→abd composition).
	Quaternion compose_target_bone_local(const Vector3 &p_anatomical) const;

	// Reflects current_state into `custom_integrator`.
	void refresh_custom_integrator();
};

} // namespace godot

VARIANT_ENUM_CAST(MarionetteBone::State);

#endif // MARIONETTE_BONE_H
