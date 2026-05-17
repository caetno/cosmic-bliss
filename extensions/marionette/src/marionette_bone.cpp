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


// Inverse of `compose_target_bone_local`. Given a parent-local relative
// quaternion (same quantity SPD compares against the forward composer's
// output), recover the anatomical (flex, medial rotation, abduction) Vector3.
//
// Math: forward composes `q = Q(ax, α') * Q(ay, β_signed) * Q(az, γ_signed)`
// where (ax, ay, az) are the columns of `anatomical_basis` and (α', β', γ')
// are the rest-offset-subtracted inputs (β/γ then sign-flipped per
// chirality). To invert:
//   1. Transform Q into the canonical basis: `M_canon = B^T · R(Q) · B`.
//      Since the forward composes around basis columns, `M_canon` is the
//      pure `Rx(α') Ry(β_signed) Rz(γ_signed)` intrinsic-XYZ Euler
//      composition. (See note in compose_target_bone_local.)
//   2. Decompose `M_canon` as intrinsic XYZ Euler:
//        β = asin(M[0][2])
//        α = atan2(-M[1][2], M[2][2])  (when cos β ≠ 0)
//        γ = atan2(-M[0][1], M[0][0])
//      Gimbal-lock fallback at |sin β| ≈ 1: set α = 0 and
//        γ = atan2(M[1][0], M[1][1]).
//   3. Undo chirality flip on β / γ (sided medial-rotation for BALL/CLAVICLE
//      right side; mirror_abd on γ).
//   4. Add `rest_anatomical_offset` back to land in canonical anatomy
//      (positive-flex / positive-medial / positive-abduction regardless of
//      side — `set_bone_target`'s convention).
//
// Round-trip: `decompose_to_anatomical(compose_target_bone_local(V)) == V`
// for any V inside ROM (no clamp inside the inverse — callers feeding
// out-of-ROM quaternions get whatever angles Euler decomposition produces).
Vector3 MarionetteBone::decompose_to_anatomical(const Quaternion &p_current_rel_parent) const {
	// Step 1: rotate the relative quaternion's matrix into the canonical
	// (ax→x, ay→y, az→z) frame. `anatomical_basis` columns are unit vectors
	// post-calibration (orthonormal); the transposed basis is its inverse.
	const Basis basis = anatomical_basis;
	const Basis basis_t = basis.transposed();
	const Basis r = Basis(p_current_rel_parent);
	const Basis m = basis_t * r * basis;

	// Step 2: intrinsic-XYZ Euler decomposition. Godot Basis indexing is
	// [row][col]: m[i][j] = M[i][j] in the math above. Watch for the float
	// clamp on the asin argument to defuse FP overshoot at ±1.
	float alpha = 0.0f;
	float beta = 0.0f;
	float gamma = 0.0f;
	const float m02 = CLAMP(m[0][2], -1.0f, 1.0f);
	beta = Math::asin(m02);
	if (Math::abs(m02) < 0.99999f) {
		alpha = Math::atan2(-m[1][2], m[2][2]);
		gamma = Math::atan2(-m[0][1], m[0][0]);
	} else {
		// Gimbal lock: β ≈ ±π/2. Set α = 0 and solve γ from the remaining
		// element. (Locked-axis convention — α gets folded into γ.)
		alpha = 0.0f;
		gamma = Math::atan2(m[1][0], m[1][1]);
	}

	// Step 3: undo chirality. Mirror in the same direction the forward path
	// flipped (negate β for sided med-rot, negate γ for mirror_abd).
	const bool is_sided_med_rot = (archetype == 0 /*BALL*/ || archetype == 5 /*CLAVICLE*/);
	if (is_sided_med_rot && !is_left_side) {
		beta = -beta;
	}
	if (mirror_abd) {
		gamma = -gamma;
	}

	// Step 4: re-add the rest offset to land in canonical anatomy.
	return Vector3(
			alpha + rest_anatomical_offset.x,
			beta + rest_anatomical_offset.y,
			gamma + rest_anatomical_offset.z);
}

// Live snapshot. Queries `get_global_transform()` on `this` + parent — safe
// OUTSIDE `_integrate_forces` (the snapshot-discipline rule covers only the
// integrator callback). Build the same parent-local relative quaternion the
// SPD path constructs, then defer to `decompose_to_anatomical`.
//
// Defensive early-return when the bone is not inside the tree: Godot logs an
// error from `get_global_transform()` in that case and returns identity. The
// `extends SceneTree` test harness hits this since `_init` runs before
// NOTIFICATION_ENTER_TREE fires (same constraint documented in the parent-
// basis snapshot tests). Returning `rest_anatomical_offset` directly skips
// the noisy error path and matches what the decomposition would produce from
// identity quaternion + canonical basis.
Vector3 MarionetteBone::current_anatomical_pose() const {
	MarionetteBone *self = const_cast<MarionetteBone *>(this);
	if (!self->is_inside_tree()) {
		return rest_anatomical_offset;
	}
	const Transform3D this_world = self->get_global_transform();
	Node3D *parent_node = self->get_parent_node_3d();
	Basis parent_world_basis = this_world.basis;
	if (parent_node != nullptr && parent_node->is_inside_tree()) {
		parent_world_basis = parent_node->get_global_transform().basis;
	}
	const Quaternion current_rel_parent =
			Quaternion(parent_world_basis.transposed() * this_world.basis);
	return decompose_to_anatomical(current_rel_parent);
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
void MarionetteBone::set_disable_builtin_springs(bool p_disable) {
	disable_builtin_springs = p_disable;
	if (p_disable && is_inside_tree()) {
		_apply_spring_disable();
	}
	// Note on toggling OFF: we don't re-enable springs to whatever they were
	// before (we never captured that state). Caller wanting joint springs
	// active needs to set `joint_constraints/<axis>/<linear|angular>_spring_enabled`
	// explicitly — same as the previous build_ragdoll editor path.
}

bool MarionetteBone::get_disable_builtin_springs() const {
	return disable_builtin_springs;
}

void MarionetteBone::_apply_spring_disable() {
	// `set(StringName, Variant)` silently no-ops for unknown property paths
	// (e.g., joint_type != 6DOF, or the joint isn't constructed yet) — safe
	// to call unconditionally. The joint's per-axis dynamic property surface
	// is documented at marionette.gd `_apply_joint_constraints`.
	static const char *AXES[] = {"x", "y", "z"};
	for (int i = 0; i < 3; ++i) {
		const String axis = AXES[i];
		set(StringName(String("joint_constraints/") + axis + "/angular_spring_enabled"), false);
		set(StringName(String("joint_constraints/") + axis + "/linear_spring_enabled"), false);
	}
}

void MarionetteBone::set_passive_tension(float p_tension) {
	passive_tension = p_tension < 0.0f ? 0.0f : p_tension;
}

float MarionetteBone::get_passive_tension() const {
	return passive_tension;
}

void MarionetteBone::_notification(int p_what) {
	// NOTIFICATION_READY fires AFTER PhysicalBone3D's own _ready, which is
	// where the 6DOF joint gets constructed. Re-applying the spring disable
	// here covers the deserialization order where the setter ran before the
	// joint existed (silent no-op then), plus any scenes saved without the
	// `disable_builtin_springs` property at all (uses class default = true).
	if (p_what == NOTIFICATION_READY && disable_builtin_springs) {
		_apply_spring_disable();
	}
}


void MarionetteBone::_integrate_forces(PhysicsDirectBodyState3D *p_state) {
	// Empty by design (2026-05-17). SPD torque, pin anchor force, and hip
	// nudge all USED to be applied here, but Jolt silently throttles
	// `PhysicsDirectBodyState3D::apply_*_impulse` calls made inside a
	// custom-integrator callback on PhysicalBone3D bodies (~2000× force
	// attenuation, observed empirically). All three were moved into
	// `MarionetteCore::apply_pin_anchors` / `apply_spd_torques`, which run
	// from `MarionetteCore::_physics_process` and call
	// `bone->apply_*_impulse(...)` on the node directly — the proven
	// working pattern (see `game/tests/marionette/ragdoll_physics_test.gd:899`).
	// `custom_integrator = true` is kept on POWERED bones so this callback
	// still fires (cheap, deterministic) in case a future composer wants
	// per-body state without a round-trip through MarionetteCore.
	(void)p_state;
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

	ClassDB::bind_method(D_METHOD("set_disable_builtin_springs", "disable"),
			&MarionetteBone::set_disable_builtin_springs);
	ClassDB::bind_method(D_METHOD("get_disable_builtin_springs"),
			&MarionetteBone::get_disable_builtin_springs);
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "disable_builtin_springs"),
			"set_disable_builtin_springs", "get_disable_builtin_springs");

	ClassDB::bind_method(D_METHOD("set_passive_tension", "tension"),
			&MarionetteBone::set_passive_tension);
	ClassDB::bind_method(D_METHOD("get_passive_tension"),
			&MarionetteBone::get_passive_tension);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "passive_tension"),
			"set_passive_tension", "get_passive_tension");

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

	ClassDB::bind_method(D_METHOD("current_anatomical_pose"),
			&MarionetteBone::current_anatomical_pose);
	ClassDB::bind_method(D_METHOD("decompose_to_anatomical", "current_rel_parent"),
			&MarionetteBone::decompose_to_anatomical);

	BIND_ENUM_CONSTANT(STATE_KINEMATIC);
	BIND_ENUM_CONSTANT(STATE_POWERED);
	BIND_ENUM_CONSTANT(STATE_UNPOWERED);
}

} // namespace godot
