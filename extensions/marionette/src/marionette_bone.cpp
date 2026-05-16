#include "marionette_bone.h"

#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/classes/physical_bone3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/variant.hpp>

#include "marionette_core.h"
#include "spd_gain_converter.h"
#include "spd_math.h"

namespace godot {

// Slice 5 — unregister from the core's bone set on destruction so a freed
// bone doesn't leave a dangling pointer in `registered_bones`. Scene teardown
// frees children in arbitrary order; the core sometimes outlives its bones.
MarionetteBone::~MarionetteBone() {
	MarionetteCore *core_ptr = Object::cast_to<MarionetteCore>(core);
	if (core_ptr != nullptr) {
		core_ptr->unregister_bone(this);
	}
}

void MarionetteBone::set_bone_entry(const Ref<Resource> &p_entry) {
	bone_entry = p_entry;
}

Ref<Resource> MarionetteBone::get_bone_entry() const {
	return bone_entry;
}

void MarionetteBone::set_current_state(int p_state) {
	current_state = p_state;
	refresh_custom_integrator();
}

int MarionetteBone::get_current_state() const {
	return current_state;
}

void MarionetteBone::set_alpha(float p_alpha) { alpha = p_alpha; }
float MarionetteBone::get_alpha() const { return alpha; }
void MarionetteBone::set_damping_ratio(float p_ratio) { damping_ratio = p_ratio; }
float MarionetteBone::get_damping_ratio() const { return damping_ratio; }
void MarionetteBone::set_strength(float p_strength) { strength = p_strength; }
float MarionetteBone::get_strength() const { return strength; }
void MarionetteBone::set_max_torque(float p_max) { max_torque = p_max; }
float MarionetteBone::get_max_torque() const { return max_torque; }
void MarionetteBone::set_mirror_abd(bool p_v) { mirror_abd = p_v; }
bool MarionetteBone::get_mirror_abd() const { return mirror_abd; }
void MarionetteBone::set_is_left_side(bool p_v) { is_left_side = p_v; }
bool MarionetteBone::get_is_left_side() const { return is_left_side; }
void MarionetteBone::set_archetype(int p_v) { archetype = p_v; }
int MarionetteBone::get_archetype() const { return archetype; }
void MarionetteBone::set_rest_anatomical_offset(const Vector3 &p_v) { rest_anatomical_offset = p_v; }
Vector3 MarionetteBone::get_rest_anatomical_offset() const { return rest_anatomical_offset; }
void MarionetteBone::set_anatomical_basis(const Basis &p_v) { anatomical_basis = p_v; }
Basis MarionetteBone::get_anatomical_basis() const { return anatomical_basis; }

void MarionetteBone::set_core(Object *p_core) {
	// Slice 5 — register / unregister with the core's bone set so
	// `MarionetteCore::set_gravity_scale` can propagate to every bone.
	// Unregister from the prior core first (handles re-wiring on rebuild).
	MarionetteCore *prev_core = Object::cast_to<MarionetteCore>(core);
	if (prev_core != nullptr) {
		prev_core->unregister_bone(this);
	}
	core = p_core;
	MarionetteCore *new_core = Object::cast_to<MarionetteCore>(core);
	if (new_core != nullptr) {
		new_core->register_bone(this);
		if (is_root) {
			new_core->set_root_bone(this);
		}
	}
}
Object *MarionetteBone::get_core() const { return core; }

void MarionetteBone::set_is_root(bool p_v) {
	is_root = p_v;
	// If the core is already wired up, register/un-register on the root
	// pointer side too. The bone set is unchanged.
	MarionetteCore *core_ptr = Object::cast_to<MarionetteCore>(core);
	if (core_ptr != nullptr) {
		if (is_root) {
			core_ptr->set_root_bone(this);
		} else if (core_ptr->get_root_bone_ptr() == this) {
			core_ptr->set_root_bone(nullptr);
		}
	}
}
bool MarionetteBone::get_is_root() const { return is_root; }

void MarionetteBone::set_anatomical_name(const StringName &p_name) { anatomical_name = p_name; }
StringName MarionetteBone::get_anatomical_name() const { return anatomical_name; }

void MarionetteBone::refresh_custom_integrator() {
	// Only POWERED bones need our SPD integrator. KINEMATIC follows the
	// skeleton (the simulator doesn't tick it dynamically); UNPOWERED wants
	// Jolt's default integrator (gravity + integration of velocity for the
	// limp-ragdoll path). Setting custom_integrator = true on those would
	// disable gravity and freeze the body, which is wrong.
	set_use_custom_integrator(current_state == STATE_POWERED);
}

// Mirrors AnatomicalPose.bone_local_rotation (anatomical_pose.gd). Inputs are
// canonical positive-flex / positive-medial-rotation / positive-abduction. The
// resulting Quaternion is a bone-local rotation: composing it with a parent's
// bone-local rest pose yields the desired joint pose. Side-mirror and
// rest-offset compensation match the GDScript reference exactly so slider /
// composer authoring stays consistent with the SPD path.
Quaternion MarionetteBone::compose_target_bone_local(const Vector3 &p_anatomical) const {
	float flex = p_anatomical.x - rest_anatomical_offset.x;
	float rot = p_anatomical.y - rest_anatomical_offset.y;
	float abd = p_anatomical.z - rest_anatomical_offset.z;

	// Sided medial-rotation flip for BALL (0) / CLAVICLE (5). Right side
	// inverts so +med_rot always produces anatomical medial rotation. See
	// anatomical_pose.gd:50-54 for the matching GDScript path.
	const bool is_sided_med_rot = (archetype == 0 /*BALL*/ || archetype == 5 /*CLAVICLE*/);
	if (is_sided_med_rot && !is_left_side) {
		rot = -rot;
	}
	if (mirror_abd) {
		abd = -abd;
	}

	const Vector3 ax = anatomical_basis.get_column(0).normalized();
	const Vector3 ay = anatomical_basis.get_column(1).normalized();
	const Vector3 az = anatomical_basis.get_column(2).normalized();

	Quaternion q;
	if (Math::abs(flex) > 0.0f) {
		q = q * Quaternion(ax, flex);
	}
	if (Math::abs(rot) > 0.0f) {
		q = q * Quaternion(ay, rot);
	}
	if (Math::abs(abd) > 0.0f) {
		q = q * Quaternion(az, abd);
	}
	return q;
}

// Test seam (slice 3b). Caller supplies every input directly so the SPD path
// runs without needing a PhysicsDirectBodyState3D / live scene tree.
//
// Coordinate spaces:
//   p_current_rel_parent : bone-local (this bone's rotation relative to its
//                          parent body, expressed in parent's frame).
//   p_anatomical_target  : canonical anatomical (flex, twist, abd).
//   p_omega_world        : world-space angular velocity (state->get_angular_velocity).
//   p_parent_world_basis : parent body's world basis (snapshotted once per tick).
//
// Returns the world-space torque to apply (state->apply_torque consumes
// world-space). The error axis-angle lives in parent-local frame (same frame
// as current/target), so the parent's world basis transforms it to world.
Vector3 MarionetteBone::compute_spd_torque_for_test(
		const Quaternion &p_current_rel_parent,
		const Vector3 &p_anatomical_target,
		const Vector3 &p_omega_world,
		const Basis &p_parent_world_basis,
		float p_mass,
		float p_dt,
		float p_global_strength) const {
	// Legacy seam — preserves slice 3b call sites. Uses cached `strength`
	// as the per-bone gain.
	return compute_spd_torque_for_test_ex(
			p_current_rel_parent, p_anatomical_target, p_omega_world,
			p_parent_world_basis, p_mass, p_dt, strength, p_global_strength);
}

// Slice 4r — explicit per-bone strength so callers (and unit tests for the
// override path) can drive the gain independently from the bone's cached
// entry default. `_integrate_forces` passes the MarionetteCore-resolved
// effective strength here.
Vector3 MarionetteBone::compute_spd_torque_for_test_ex(
		const Quaternion &p_current_rel_parent,
		const Vector3 &p_anatomical_target,
		const Vector3 &p_omega_world,
		const Basis &p_parent_world_basis,
		float p_mass,
		float p_dt,
		float p_bone_strength,
		float p_global_strength) const {
	const Quaternion target = compose_target_bone_local(p_anatomical_target);
	const Quaternion err_q = SPDMath::error_quaternion(p_current_rel_parent, target);
	const Vector3 err_axis_angle = SPDMath::quaternion_to_axis_angle(err_q);

	// Bring omega into parent-local frame so the damping term acts in the
	// same space as the proportional error. Without this, world-frame omega
	// would couple cross-axis on a rotated parent.
	const Vector3 omega_parent_local = p_parent_world_basis.transposed().xform(p_omega_world);

	const Vector2 gains = SPDGainConverter::compute_gains(alpha, damping_ratio, p_mass, p_dt);
	const float scale = p_bone_strength * p_global_strength;
	const float kp = gains.x * scale;
	const float kd = gains.y * scale;

	const Vector3 torque_parent_local =
			SPDMath::compute_torque(err_axis_angle, omega_parent_local, kp, kd, p_dt);

	Vector3 torque_world = p_parent_world_basis.xform(torque_parent_local);

	// Optional safety clamp (sentinel 0 disables). Keeps a stiff misconfigured
	// bone from launching Jolt into NaN-land before the user fixes the params.
	if (max_torque > 0.0f) {
		const float mag = torque_world.length();
		if (mag > max_torque) {
			torque_world *= (max_torque / mag);
		}
	}
	return torque_world;
}

// Slice P10.7-min — tracking-error magnitude in radians. Same target
// composition path as the SPD torque (compose_target_bone_local on the
// anatomical Vector3 then error_quaternion → axis-angle vector → length).
// Magnitude lives in [0, π] (error_quaternion collapses the antipodal
// pair to the half with w >= 0, so the returned axis-angle is the SHORT
// rotation magnitude — never wraps past π). Used by
// MarionetteCore::compute_body_strain.
float MarionetteBone::compute_tracking_error_radians(
		const Quaternion &p_current_rel_parent,
		const Vector3 &p_anatomical_target) const {
	const Quaternion target = compose_target_bone_local(p_anatomical_target);
	const Quaternion err_q = SPDMath::error_quaternion(p_current_rel_parent, target);
	const Vector3 err_axis_angle = SPDMath::quaternion_to_axis_angle(err_q);
	return err_axis_angle.length();
}


// Slice 3b — SPD torque path. Runs only for POWERED bones; KINEMATIC /
// UNPOWERED early-return so Jolt's default integrator (or the simulator's
// kinematic skeleton follower) takes over.
//
// The joint-spring path on PhysicalBone3D's internal 6DOF is RETIRED for
// POWERED bones in this slice (build path leaves spring_stiffness=0 on
// powered bones; see marionette.gd). Springs were never going to coexist
// cleanly with the SPD torque — they fight each other at the integrator
// level.
void MarionetteBone::_integrate_forces(PhysicsDirectBodyState3D *p_state) {
	if (current_state != STATE_POWERED) {
		return;
	}
	if (core == nullptr) {
		return; // No target cache wired up — leave body untouched.
	}

	// Snapshot once per tick (CLAUDE.md "Never" — no repeated global_transform
	// reads inside an integration step). `p_state->get_transform()` is the
	// body's authoritative world transform for this tick.
	const Transform3D this_world = p_state->get_transform();

	// Resolve the typed core pointer up front. We need it for both the
	// parent-basis snapshot lookup (Mar-I6) and the bone-target cache read
	// below; do the cast once. The raw `core` Object* was already null-checked
	// above, but a wrong-type assignment still produces a null cast — fall
	// back to identity-frame behavior in that edge case.
	MarionetteCore *core_ptr = Object::cast_to<MarionetteCore>(core);

	// Mar-I6 — parent basis sourced from MarionetteCore's per-frame snapshot
	// (taken in MarionetteCore::_physics_process before SPD substeps), not a
	// live `Node3D::get_global_transform()` read inside the integrator. The
	// live read introduced phantom damping coupling that scales with SPD
	// stiffness; the kasumi ragdoll-under-tension scenario sits exactly in
	// that regime. The fallback (this_world.basis) preserves the prior root /
	// orphan behavior — error_quaternion stays well-defined when no parent
	// Node3D exists, and later slices add the world-anchored hip tether so
	// the root case retires entirely. If the core cast failed (wrong-type
	// assignment), fall back to identity-frame behavior — same as the
	// pre-Mar-I6 code path's `parent_node == nullptr` branch.
	const Basis parent_world_basis = (core_ptr != nullptr)
			? core_ptr->get_parent_basis_snapshot(this, this_world.basis)
			: this_world.basis;

	// Current relative rotation, parent-local frame.
	const Quaternion current_rel_parent =
			Quaternion(parent_world_basis.transposed() * this_world.basis);

	// Read target from the C++ cache. ZERO sentinel → identity target.
	Vector3 anatomical_target;
	if (core_ptr != nullptr) {
		anatomical_target = core_ptr->get_bone_target(anatomical_name);
	}

	const float global_strength = (core_ptr != nullptr) ? core_ptr->get_global_strength() : 1.0f;
	// Slice 4r — consult MarionetteCore for a per-bone override; fall back to
	// the bone's own cached `strength` (which comes from the BoneEntry-derived
	// default set at build_ragdoll). `BoneEntry` doesn't carry a strength
	// field directly — the cached value on this bone IS the entry default.
	const float effective_bone_strength =
			(core_ptr != nullptr) ? core_ptr->get_bone_strength(anatomical_name, strength) : strength;
	const float dt = p_state->get_step();
	const float mass = get_mass();

	const Vector3 torque_world = compute_spd_torque_for_test_ex(
			current_rel_parent,
			anatomical_target,
			p_state->get_angular_velocity(),
			parent_world_basis,
			mass,
			dt,
			effective_bone_strength,
			global_strength);

	p_state->apply_torque(torque_world);

	// Slice 5 (P5.5) — hip upward nudge. Constant central force in world +Y,
	// attenuated by global_strength so a limp character isn't lifted by the
	// hip's drive force. Only fires on the bone flagged as the ragdoll root
	// (the hip — set by build_ragdoll). World-Y is fine here: gravity is also
	// world-Y, and this is a quick lever (not a rigorous foot-IK) to keep
	// the pelvis from sagging while the per-frame physics solver settles.
	if (is_root && core_ptr != nullptr) {
		const float nudge = core_ptr->get_hip_upward_nudge();
		if (nudge != 0.0f) {
			const float factor = core_ptr->get_global_strength_factor();
			if (factor > 0.0f) {
				p_state->apply_central_force(Vector3(0.0f, nudge * factor, 0.0f));
			}
		}
	}

	// Slice P10.2-min — pin anchor pull. Soft world-space spring:
	// `F = weight × (world_pos − bone_world_pos)`. The bone's authoritative
	// world position is `this_world.origin` (snapshotted at the top of this
	// callback — no extra `get_global_transform()` read, satisfying the
	// snapshot-discipline rule). `compute_pin_force` returns zero for bones
	// without a pin, so the unconditional apply is cheap (one HashMap miss
	// + a zero-magnitude force on Jolt). The pin coexists with SPD: SPD
	// continues to drive anatomical angle; the pin biases the bone's
	// translation toward `world_pos`. Soft target per Phase 10 commitment
	// #2 (composer feeds SPD as soft targets, not hard constraints).
	if (core_ptr != nullptr) {
		const Vector3 pin_force = core_ptr->compute_pin_force(anatomical_name, this_world.origin);
		if (pin_force != Vector3()) {
			p_state->apply_central_force(pin_force);
		}
	}
}

void MarionetteBone::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_bone_entry", "entry"), &MarionetteBone::set_bone_entry);
	ClassDB::bind_method(D_METHOD("get_bone_entry"), &MarionetteBone::get_bone_entry);
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "bone_entry",
						 PROPERTY_HINT_RESOURCE_TYPE, "BoneEntry"),
			"set_bone_entry", "get_bone_entry");

	ClassDB::bind_method(D_METHOD("set_current_state", "state"), &MarionetteBone::set_current_state);
	ClassDB::bind_method(D_METHOD("get_current_state"), &MarionetteBone::get_current_state);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "current_state",
						 PROPERTY_HINT_ENUM, "Kinematic,Powered,Unpowered"),
			"set_current_state", "get_current_state");

	ClassDB::bind_method(D_METHOD("set_alpha", "v"), &MarionetteBone::set_alpha);
	ClassDB::bind_method(D_METHOD("get_alpha"), &MarionetteBone::get_alpha);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "alpha"), "set_alpha", "get_alpha");

	ClassDB::bind_method(D_METHOD("set_damping_ratio", "v"), &MarionetteBone::set_damping_ratio);
	ClassDB::bind_method(D_METHOD("get_damping_ratio"), &MarionetteBone::get_damping_ratio);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "damping_ratio"), "set_damping_ratio", "get_damping_ratio");

	ClassDB::bind_method(D_METHOD("set_strength", "v"), &MarionetteBone::set_strength);
	ClassDB::bind_method(D_METHOD("get_strength"), &MarionetteBone::get_strength);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "strength"), "set_strength", "get_strength");

	ClassDB::bind_method(D_METHOD("set_max_torque", "v"), &MarionetteBone::set_max_torque);
	ClassDB::bind_method(D_METHOD("get_max_torque"), &MarionetteBone::get_max_torque);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_torque"), "set_max_torque", "get_max_torque");

	ClassDB::bind_method(D_METHOD("set_mirror_abd", "v"), &MarionetteBone::set_mirror_abd);
	ClassDB::bind_method(D_METHOD("get_mirror_abd"), &MarionetteBone::get_mirror_abd);
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "mirror_abd"), "set_mirror_abd", "get_mirror_abd");

	ClassDB::bind_method(D_METHOD("set_is_left_side", "v"), &MarionetteBone::set_is_left_side);
	ClassDB::bind_method(D_METHOD("get_is_left_side"), &MarionetteBone::get_is_left_side);
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "is_left_side"), "set_is_left_side", "get_is_left_side");

	ClassDB::bind_method(D_METHOD("set_archetype", "v"), &MarionetteBone::set_archetype);
	ClassDB::bind_method(D_METHOD("get_archetype"), &MarionetteBone::get_archetype);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "archetype"), "set_archetype", "get_archetype");

	ClassDB::bind_method(D_METHOD("set_rest_anatomical_offset", "v"), &MarionetteBone::set_rest_anatomical_offset);
	ClassDB::bind_method(D_METHOD("get_rest_anatomical_offset"), &MarionetteBone::get_rest_anatomical_offset);
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "rest_anatomical_offset"),
			"set_rest_anatomical_offset", "get_rest_anatomical_offset");

	ClassDB::bind_method(D_METHOD("set_anatomical_basis", "v"), &MarionetteBone::set_anatomical_basis);
	ClassDB::bind_method(D_METHOD("get_anatomical_basis"), &MarionetteBone::get_anatomical_basis);
	ADD_PROPERTY(PropertyInfo(Variant::BASIS, "anatomical_basis"),
			"set_anatomical_basis", "get_anatomical_basis");

	ClassDB::bind_method(D_METHOD("set_core", "core"), &MarionetteBone::set_core);
	ClassDB::bind_method(D_METHOD("get_core"), &MarionetteBone::get_core);

	ClassDB::bind_method(D_METHOD("set_is_root", "v"), &MarionetteBone::set_is_root);
	ClassDB::bind_method(D_METHOD("get_is_root"), &MarionetteBone::get_is_root);
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "is_root"),
			"set_is_root", "get_is_root");

	ClassDB::bind_method(D_METHOD("set_anatomical_name", "name"), &MarionetteBone::set_anatomical_name);
	ClassDB::bind_method(D_METHOD("get_anatomical_name"), &MarionetteBone::get_anatomical_name);
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "anatomical_name"),
			"set_anatomical_name", "get_anatomical_name");

	ClassDB::bind_method(D_METHOD("compute_spd_torque_for_test",
								"current_rel_parent", "anatomical_target", "omega_world",
								"parent_world_basis", "mass", "dt", "global_strength"),
			&MarionetteBone::compute_spd_torque_for_test);
	ClassDB::bind_method(D_METHOD("compute_spd_torque_for_test_ex",
								"current_rel_parent", "anatomical_target", "omega_world",
								"parent_world_basis", "mass", "dt", "bone_strength", "global_strength"),
			&MarionetteBone::compute_spd_torque_for_test_ex);

	ClassDB::bind_method(D_METHOD("compute_tracking_error_radians",
								"current_rel_parent", "anatomical_target"),
			&MarionetteBone::compute_tracking_error_radians);

	BIND_ENUM_CONSTANT(STATE_KINEMATIC);
	BIND_ENUM_CONSTANT(STATE_POWERED);
	BIND_ENUM_CONSTANT(STATE_UNPOWERED);
}

} // namespace godot
