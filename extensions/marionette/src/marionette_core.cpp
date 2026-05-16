#include "marionette_core.h"

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

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
	// Mar-I14 — body rhythm clock. Runs at the TOP of the physics callback
	// so any downstream consumer (cyclic evaluator, future composer) reads
	// the same phase the SPD substeps will see. Body of the integrator
	// lives in `step_body_rhythm_phase` so unit tests can drive it without
	// a live SceneTree.
	step_body_rhythm_phase(p_delta);

	// Mar-I6 — refresh the parent-basis cache BEFORE the SPD substeps run.
	// `MarionetteBone::_integrate_forces` reads from this cache instead of
	// live-querying `Node3D::get_global_transform()` (which inside the
	// integrator callback couples a phantom damping term to SPD stiffness).
	// Frame-level snapshot per the audit doc; per-substep granularity is a
	// follow-up if visible quality requires.
	snapshot_parent_bases();

	// Slice P10.2-min — dispatch hook. Runs AFTER the parent-basis snapshot
	// per the slice prompt's ordering constraint. No-op body in this slice;
	// the per-bone read happens inside MarionetteBone::_integrate_forces.
	// Future composer (P10.1) plugs world-pos → anatomical conversion here.
	apply_pin_anchors();

	// Slice P10.7-min — body_strain publisher. Reads the bone transforms
	// the SPD substeps wrote during the PRIOR physics tick (Godot orders
	// `_physics_process` BEFORE `_integrate_forces` — strain is one-tick-
	// lagged, fine for a stub publisher). Per-bone, populated into the
	// `body_strain_per_bone` HashMap; `get_body_strain` repackages as a
	// Dictionary for the GDScript wrapper.
	compute_body_strain();

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
	// Mar-I6 — drop any cached parent basis under this pointer so the entry
	// doesn't outlive the bone. Scene teardown frees children in arbitrary
	// order; without this erase a freed bone's pointer could linger as a
	// HashMap key until the next `snapshot_parent_bases` rebuild.
	parent_basis_snapshots.erase(p_bone);
	if (root_bone == p_bone) {
		root_bone = nullptr;
	}
}

void MarionetteCore::snapshot_parent_bases() {
	// Mar-I6 — rebuild every frame so dropped / re-parented bones can't keep
	// stale entries. Cheap: ~84 bones, one hash lookup + one Basis copy each.
	// `get_parent_node_3d()` walks the scene-tree parent chain to the first
	// Node3D ancestor (matching the live read this replaces, so the math
	// space is identical).
	parent_basis_snapshots.clear();
	for (MarionetteBone *bone : registered_bones) {
		if (bone == nullptr) {
			continue;
		}
		Node3D *parent_node = bone->get_parent_node_3d();
		if (parent_node == nullptr) {
			// Root / orphan case — leave the entry absent; readers fall back
			// to their caller-supplied basis (the bone's own world basis in
			// the SPD path).
			continue;
		}
		parent_basis_snapshots[bone] = parent_node->get_global_transform().basis;
	}
}

Basis MarionetteCore::get_parent_basis_snapshot(MarionetteBone *p_bone, const Basis &p_fallback) const {
	const HashMap<MarionetteBone *, Basis>::ConstIterator it = parent_basis_snapshots.find(p_bone);
	if (it == parent_basis_snapshots.end()) {
		return p_fallback;
	}
	return it->value;
}

void MarionetteCore::unregister_bone_bound(Object *p_bone) {
	MarionetteBone *bone_ptr = Object::cast_to<MarionetteBone>(p_bone);
	if (bone_ptr == nullptr) {
		return;
	}
	unregister_bone(bone_ptr);
}

Basis MarionetteCore::get_parent_basis_snapshot_bound(Object *p_bone, const Basis &p_fallback) const {
	MarionetteBone *bone_ptr = Object::cast_to<MarionetteBone>(p_bone);
	if (bone_ptr == nullptr) {
		return p_fallback;
	}
	return get_parent_basis_snapshot(bone_ptr, p_fallback);
}

bool MarionetteCore::has_parent_basis_snapshot(Object *p_bone) const {
	MarionetteBone *bone_ptr = Object::cast_to<MarionetteBone>(p_bone);
	if (bone_ptr == nullptr) {
		return false;
	}
	return parent_basis_snapshots.find(bone_ptr) != parent_basis_snapshots.end();
}

void MarionetteCore::set_parent_basis_snapshot_for_test(Object *p_bone, const Basis &p_basis) {
	MarionetteBone *bone_ptr = Object::cast_to<MarionetteBone>(p_bone);
	if (bone_ptr == nullptr) {
		return;
	}
	parent_basis_snapshots[bone_ptr] = p_basis;
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

void MarionetteCore::set_body_rhythm_frequency(float p_hz) {
	// Mar-I14 — clamp at the setter so the integrator hot path stays branch-
	// free. Negative frequency would run phase backward (pathological);
	// emit a one-line warning so misconfigured callers surface in logs.
	if (p_hz < 0.0f) {
		UtilityFunctions::push_warning(
				"MarionetteCore: body_rhythm_frequency clamped to 0 (got negative value)");
		p_hz = 0.0f;
	}
	body_rhythm_frequency = p_hz;
}

float MarionetteCore::get_body_rhythm_frequency() const {
	return body_rhythm_frequency;
}

double MarionetteCore::get_body_rhythm_phase() const {
	return body_rhythm_phase;
}

int64_t MarionetteCore::get_body_rhythm_cycle_index() const {
	return body_rhythm_cycle_index;
}

void MarionetteCore::step_body_rhythm_phase(double p_delta) {
	// Mar-I14 — INTEGRATED form (`phase += freq * TAU * dt`), never the
	// recomputed form (`phase = freq * t`). A frequency change therefore
	// does NOT snap the phase — TT's `RhythmSyncedProbe` lock and any
	// other external consumer stay continuous across arousal transitions.
	// `while` (not `if + fmod`) so cycle events don't drop at high freq ×
	// low fps (closes Mar-I7 code side). Negative delta is a no-op: the
	// setter clamps frequency at 0, the hot path stays branch-free, and
	// pathological inputs from callers (rewound time) leave the phase
	// alone instead of running backward.
	if (p_delta <= 0.0) {
		return;
	}
	body_rhythm_phase += static_cast<double>(body_rhythm_frequency) * Math_TAU * p_delta;
	while (body_rhythm_phase >= Math_TAU) {
		body_rhythm_phase -= Math_TAU;
		++body_rhythm_cycle_index;
		emit_signal("body_rhythm_cycle_completed", body_rhythm_cycle_index);
	}
}

void MarionetteCore::add_pin_anchor(const StringName &p_bone_name, const Vector3 &p_world_pos, float p_weight) {
	// Slice P10.2-min — one anchor per bone (re-add replaces). Negative
	// weight makes the spring repel rather than pull — pathological but
	// not catastrophic, so a warning instead of a clamp. Zero weight is
	// legal: same as `remove_pin_anchor` in effect, but the entry stays
	// resident so subsequent reads find it.
	if (p_weight < 0.0f) {
		UtilityFunctions::push_warning(
				"MarionetteCore::add_pin_anchor: negative weight produces repulsion (got ", p_weight, ")");
	}
	PinAnchor anchor;
	anchor.bone_name = p_bone_name;
	anchor.world_pos = p_world_pos;
	anchor.weight = p_weight;
	pin_anchors[p_bone_name] = anchor;
}

void MarionetteCore::remove_pin_anchor(const StringName &p_bone_name) {
	pin_anchors.erase(p_bone_name);
}

void MarionetteCore::clear_pin_anchors() {
	pin_anchors.clear();
}

int MarionetteCore::get_pin_anchor_count() const {
	return static_cast<int>(pin_anchors.size());
}

bool MarionetteCore::has_pin_anchor(const StringName &p_bone_name) const {
	return pin_anchors.find(p_bone_name) != pin_anchors.end();
}

Vector3 MarionetteCore::get_pin_anchor_world_pos(const StringName &p_bone_name) const {
	const HashMap<StringName, PinAnchor>::ConstIterator it = pin_anchors.find(p_bone_name);
	if (it == pin_anchors.end()) {
		return Vector3();
	}
	return it->value.world_pos;
}

float MarionetteCore::get_pin_anchor_weight(const StringName &p_bone_name) const {
	const HashMap<StringName, PinAnchor>::ConstIterator it = pin_anchors.find(p_bone_name);
	if (it == pin_anchors.end()) {
		return 0.0f;
	}
	return it->value.weight;
}

Vector3 MarionetteCore::compute_pin_force(const StringName &p_bone_name, const Vector3 &p_bone_world_pos) const {
	// Slice P10.2-min — pure derivation: `F = weight × (world_pos −
	// bone_world_pos)`. Spring in world space, soft target. Returns zero
	// when the bone has no pin so callers (the per-bone integrator) can
	// unconditionally apply the result.
	const HashMap<StringName, PinAnchor>::ConstIterator it = pin_anchors.find(p_bone_name);
	if (it == pin_anchors.end()) {
		return Vector3();
	}
	const PinAnchor &a = it->value;
	return (a.world_pos - p_bone_world_pos) * a.weight;
}

// Slice P10.7-min — pure-math derivation. Spec contract:
//   body_strain[bone] = clamp(|tracking_error| × strength, 0, 1)
// Both inputs come from elsewhere; this method just composes the clamp +
// scaling so tests can pin the math without spinning up the bone-walk path.
// `tracking_error_radians` is a magnitude (already abs from
// MarionetteBone::compute_tracking_error_radians, which returns the length
// of an axis-angle vector). Negative input is folded to abs defensively;
// negative effective strength produces a negative product → clamped to 0
// (limp-bone case has effective_strength == 0, so the product is 0).
float MarionetteCore::compute_strain_value(float p_tracking_error_radians, float p_effective_strength) const {
	const float err = Math::abs(p_tracking_error_radians);
	const float product = err * p_effective_strength;
	if (product <= 0.0f) {
		return 0.0f;
	}
	if (product >= 1.0f) {
		return 1.0f;
	}
	return product;
}

void MarionetteCore::set_strain_for_test(const StringName &p_bone_name, float p_strain) {
	body_strain_per_bone[p_bone_name] = p_strain;
}

void MarionetteCore::clear_body_strain() {
	body_strain_per_bone.clear();
}

void MarionetteCore::compute_body_strain() {
	// Rebuild every frame — bones can change state (POWERED ↔ KINEMATIC) at
	// runtime, and a state change must drop the corresponding strain entry
	// (KINEMATIC bones don't have meaningful strain). Same hygiene as
	// `snapshot_parent_bases`: cheap clear-and-rebuild beats incremental
	// invalidation.
	body_strain_per_bone.clear();
	for (MarionetteBone *bone : registered_bones) {
		if (bone == nullptr) {
			continue;
		}
		// Only POWERED bones have meaningful tracking error vs an SPD target.
		// KINEMATIC follows animation directly (zero by definition);
		// UNPOWERED has no SPD drive (also zero by definition). Skipping
		// keeps the dictionary tight — present keys mean "actively driven."
		if (bone->get_current_state() != MarionetteBone::STATE_POWERED) {
			continue;
		}
		const StringName name = bone->get_anatomical_name();
		if (name == StringName()) {
			// Build-time bug guard — a registered bone without an anatomical
			// name has no key to publish under. Skip silently; the strain
			// publisher is read-only so a missed entry is a soft failure.
			continue;
		}

		// Read the bone's world transform OUTSIDE `_integrate_forces` (we're
		// in `_physics_process`, which is the safe seam for
		// `get_global_transform()` per CLAUDE.md "Never" — the rule forbids
		// the call INSIDE the integrator callback, not in the per-tick
		// outer loop). The transform reflects whatever the previous
		// physics tick's SPD substeps wrote, which is exactly what strain
		// is supposed to measure.
		const Transform3D this_world = bone->get_global_transform();
		const Basis parent_world_basis = get_parent_basis_snapshot(bone, this_world.basis);
		const Quaternion current_rel_parent =
				Quaternion(parent_world_basis.transposed() * this_world.basis);

		const Vector3 anatomical_target = get_bone_target(name);
		const float tracking_error =
				bone->compute_tracking_error_radians(current_rel_parent, anatomical_target);

		const float bone_default_strength = bone->get_strength();
		const float bone_eff_strength = get_bone_strength(name, bone_default_strength);
		const float effective_strength = bone_eff_strength * effective_global_strength;

		body_strain_per_bone[name] = compute_strain_value(tracking_error, effective_strength);
	}
}

Dictionary MarionetteCore::get_body_strain() const {
	// Copy out as a Dictionary so the GDScript consumer doesn't pin the
	// internal HashMap's lifetime. Cheap (one entry per POWERED bone,
	// typically <80 entries). Repackage cost is paid only when Reverie /
	// gameplay actually reads — the per-frame `compute_body_strain` path
	// stays HashMap-internal.
	Dictionary out;
	for (HashMap<StringName, float>::ConstIterator it = body_strain_per_bone.begin();
			it != body_strain_per_bone.end(); ++it) {
		out[it->key] = it->value;
	}
	return out;
}

void MarionetteCore::apply_pin_anchors() {
	// Slice P10.2-min — intentional no-op. The per-bone read site is in
	// `MarionetteBone::_integrate_forces` (reads `compute_pin_force` once
	// per tick, applies as `apply_central_force`). This method exists as
	// the dispatch hook the spec ordering requires (between parent-basis
	// snapshot and SPD target dispatch). Full-composer slice (P10.1+)
	// plugs world-pos → anatomical conversion here so the per-bone path
	// only needs to read `bone_targets`.
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

	// Mar-I6 — surfaced for tests; production callers should not invoke
	// `snapshot_parent_bases` manually (it runs from `_physics_process`).
	// `get_parent_basis_snapshot` is called from C++ `_integrate_forces`,
	// but binding it lets unit tests assert the cache contents.
	ClassDB::bind_method(D_METHOD("snapshot_parent_bases"),
			&MarionetteCore::snapshot_parent_bases);
	ClassDB::bind_method(D_METHOD("get_parent_basis_snapshot", "bone", "fallback"),
			&MarionetteCore::get_parent_basis_snapshot_bound);
	ClassDB::bind_method(D_METHOD("has_parent_basis_snapshot", "bone"),
			&MarionetteCore::has_parent_basis_snapshot);
	ClassDB::bind_method(D_METHOD("unregister_bone", "bone"),
			&MarionetteCore::unregister_bone_bound);
	ClassDB::bind_method(D_METHOD("set_parent_basis_snapshot_for_test", "bone", "basis"),
			&MarionetteCore::set_parent_basis_snapshot_for_test);

	// Mar-I14 — body rhythm clock. Frequency is settable from anywhere
	// (Reverie writes once on arousal change; future composer writes the
	// slewed value once per tick); phase + cycle index are read-only.
	ClassDB::bind_method(D_METHOD("set_body_rhythm_frequency", "hz"),
			&MarionetteCore::set_body_rhythm_frequency);
	ClassDB::bind_method(D_METHOD("get_body_rhythm_frequency"),
			&MarionetteCore::get_body_rhythm_frequency);
	ClassDB::bind_method(D_METHOD("get_body_rhythm_phase"),
			&MarionetteCore::get_body_rhythm_phase);
	ClassDB::bind_method(D_METHOD("get_body_rhythm_cycle_index"),
			&MarionetteCore::get_body_rhythm_cycle_index);
	ClassDB::bind_method(D_METHOD("step_body_rhythm_phase", "delta"),
			&MarionetteCore::step_body_rhythm_phase);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "body_rhythm_frequency"),
			"set_body_rhythm_frequency", "get_body_rhythm_frequency");

	ADD_SIGNAL(MethodInfo("body_rhythm_cycle_completed",
			PropertyInfo(Variant::INT, "cycle_index")));

	// Slice P10.2-min — PinAnchor primitive. The GDScript wrapper
	// (Marionette.gd) forwards these through to its `_ensure_core()`
	// instance; the per-bone read site is `MarionetteBone::_integrate_forces`.
	ClassDB::bind_method(D_METHOD("add_pin_anchor", "bone_name", "world_pos", "weight"),
			&MarionetteCore::add_pin_anchor);
	ClassDB::bind_method(D_METHOD("remove_pin_anchor", "bone_name"),
			&MarionetteCore::remove_pin_anchor);
	ClassDB::bind_method(D_METHOD("clear_pin_anchors"), &MarionetteCore::clear_pin_anchors);
	ClassDB::bind_method(D_METHOD("get_pin_anchor_count"), &MarionetteCore::get_pin_anchor_count);
	ClassDB::bind_method(D_METHOD("has_pin_anchor", "bone_name"),
			&MarionetteCore::has_pin_anchor);
	ClassDB::bind_method(D_METHOD("get_pin_anchor_world_pos", "bone_name"),
			&MarionetteCore::get_pin_anchor_world_pos);
	ClassDB::bind_method(D_METHOD("get_pin_anchor_weight", "bone_name"),
			&MarionetteCore::get_pin_anchor_weight);
	ClassDB::bind_method(D_METHOD("compute_pin_force", "bone_name", "bone_world_pos"),
			&MarionetteCore::compute_pin_force);
	ClassDB::bind_method(D_METHOD("apply_pin_anchors"), &MarionetteCore::apply_pin_anchors);

	// Slice P10.7-min — body_strain publisher. Per-bone dictionary keyed
	// by anatomical name; values in [0, 1]. The two test seams
	// (`compute_strain_value` and `set_strain_for_test`) let unit tests
	// pin the clamp math + the publish-pipeline keys without a live
	// physics frame.
	ClassDB::bind_method(D_METHOD("compute_body_strain"),
			&MarionetteCore::compute_body_strain);
	ClassDB::bind_method(D_METHOD("get_body_strain"),
			&MarionetteCore::get_body_strain);
	ClassDB::bind_method(D_METHOD("compute_strain_value",
								"tracking_error_radians", "effective_strength"),
			&MarionetteCore::compute_strain_value);
	ClassDB::bind_method(D_METHOD("set_strain_for_test", "bone_name", "strain"),
			&MarionetteCore::set_strain_for_test);
	ClassDB::bind_method(D_METHOD("clear_body_strain"),
			&MarionetteCore::clear_body_strain);
}

} // namespace godot
