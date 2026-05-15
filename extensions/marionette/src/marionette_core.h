#ifndef MARIONETTE_CORE_H
#define MARIONETTE_CORE_H

#include <cstdint>

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/templates/hash_set.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

class MarionetteBone;

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

	// Slice 6 — drives `step_strength_ramps` once per physics tick. Lives on
	// the core (not the GDScript wrapper) so the ramp keeps pace with the
	// physics step even if no MarionetteBone is currently registered.
	void _ready() override;
	void _physics_process(double p_delta) override;

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

	// Slice 6 (P5.6) — strength ramp on transitions. Going LIMP is
	// instantaneous (post-orgasm / surrender / shock); RE-ENGAGEMENT ramps
	// to avoid a snap-to-pose pop. The ramp runs in `step_strength_ramps`,
	// driven by `_physics_process` on the GDScript wrapper side and also
	// invokable directly for unit tests.
	void set_strength_ramp_duration(float p_seconds);
	float get_strength_ramp_duration() const;

	// Returns the REQUESTED (un-ramped) target — useful for inspectors that
	// want to show "user dialed in X, effective is currently Y". Caller-side
	// default semantics match `get_bone_strength`: no override → p_default.
	float get_requested_bone_strength(const StringName &p_bone_name, float p_default) const;
	float get_requested_global_strength() const;

	// Steps `effective` toward `requested` for the global slot and every
	// override. Increase: rate = 1 / ramp_duration (clamped at requested).
	// Decrease: instantaneous (snap-to-requested). `ramp_duration <= 0`
	// snaps both ways (no smoothing). Idempotent at equilibrium.
	void step_strength_ramps(float p_delta);

	// Slice 5 (P5.5). `gravity_scale` propagates to every registered
	// MarionetteBone (RigidBody3D property); 0.0 = zero-g, 1.0 = world
	// gravity. `hip_upward_nudge` is a constant central force in world +Y
	// applied at the hip while `global_strength` is above
	// `hip_nudge_strength_threshold` (smooth-faded below). Both default to
	// 1.0 / 0.0 / 0.5 so existing builds behave the same.
	void set_gravity_scale(float p_value);
	float get_gravity_scale() const;
	void set_hip_upward_nudge(float p_value);
	float get_hip_upward_nudge() const;
	void set_hip_nudge_strength_threshold(float p_value);
	float get_hip_nudge_strength_threshold() const;

	// Smooth fade of `global_strength` against `hip_nudge_strength_threshold`.
	// Returns 1.0 when global_strength >= threshold, linear ramp down to 0.0
	// at global_strength = 0. Pure scalar — no per-tick state. Used by the
	// root bone's _integrate_forces to attenuate the upward nudge at low
	// global strength so a limp character isn't lifted by the hip force.
	float get_global_strength_factor() const;

	// Bone registry (slice 5). MarionetteBone registers itself when its
	// `set_core` is called and unregisters on destruction. Used by
	// `set_gravity_scale` to push the value out to RigidBody3D.
	void register_bone(MarionetteBone *p_bone);
	void unregister_bone(MarionetteBone *p_bone);

	// Mar-I6 — parent-basis snapshot. `_integrate_forces` callbacks must not
	// query `Node3D::get_global_transform()` (per the project "Never" list);
	// the live read introduced phantom damping coupling that scaled with SPD
	// stiffness, biasing exactly the high-tension regime targeted by the
	// kasumi ragdoll-under-tension scenario. `snapshot_parent_bases()` runs
	// once per physics frame (in `_physics_process`, before
	// `step_strength_ramps`); the SPD path reads cached values via
	// `get_parent_basis_snapshot`. Root / orphan bones absent from the map →
	// caller's fallback (typically the bone's own world basis).
	void snapshot_parent_bases();
	Basis get_parent_basis_snapshot(MarionetteBone *p_bone, const Basis &p_fallback) const;

	// Test seam — bindable variant for unit tests. Takes Object* (binds
	// cleanly through GDScript) and casts internally. Production callers
	// should use the typed overload above.
	Basis get_parent_basis_snapshot_bound(Object *p_bone, const Basis &p_fallback) const;
	bool has_parent_basis_snapshot(Object *p_bone) const;
	void unregister_bone_bound(Object *p_bone);

	// Mar-I6 test seam — directly populate the snapshot for a registered
	// bone, bypassing the Node3D parent-chain walk. Script-context SceneTree
	// (gdscript `extends SceneTree`) doesn't fire NOTIFICATION_ENTER_TREE
	// before `_init` returns, so `get_global_transform()` on a freshly
	// add_child'd Node3D reads stale identity. This seam lets cache-contract
	// tests (returns-cached, isolation-from-mutation, unregister-clears) run
	// without needing a live physics frame. The integration with the real
	// `get_global_transform()` is exercised by the in-engine ragdoll demo.
	void set_parent_basis_snapshot_for_test(Object *p_bone, const Basis &p_basis);

	// Slice 5 — `is_root` cached on the bone, but the core also needs the
	// pointer for diagnostics / future hip-anchored tether work. Setting null
	// clears the cache (e.g., teardown). `get_root_bone` returns Object* so
	// the binding system can expose it to GDScript.
	void set_root_bone(MarionetteBone *p_bone);
	MarionetteBone *get_root_bone_ptr() const;
	Object *get_root_bone() const;

	// Mar-I14 — body rhythm shared clock. Phase is INTEGRATED (`phase +=
	// freq * TAU * dt`), never recomputed (`phase = freq * t`), so a
	// frequency change doesn't snap the phase — critical for the
	// TentacleTech `RhythmSyncedProbe` lock and any external consumer.
	// Owner of the integrator per 05-14-02 §4.2: `MarionetteCore`,
	// `_physics_process` — single source of truth. Future composer reads
	// the same fields; it does not duplicate or migrate the integrator.
	// Phase storage is `double` deliberately — float at 0.4 Hz accumulates
	// visible drift over long sessions.
	void set_body_rhythm_frequency(float p_hz);
	float get_body_rhythm_frequency() const;
	double get_body_rhythm_phase() const;
	int64_t get_body_rhythm_cycle_index() const;

	// Test seam — runs ONE integration step at `p_delta`. Production code
	// reaches this path via `_physics_process`; tests need a deterministic
	// callable that doesn't depend on a live SceneTree (run_tests.gd
	// instantiates MarionetteCore as a bare Object). Idempotent / pure
	// function of (frequency, current phase, delta).
	void step_body_rhythm_phase(double p_delta);

protected:
	static void _bind_methods();

private:
	HashMap<StringName, Vector3> bone_targets;
	// `bone_strength_overrides` is the REQUESTED value (slice 4r semantics).
	// `bone_strength_effective` mirrors what the SPD path actually sees,
	// catching up to requested via `step_strength_ramps` (slice 6). When a
	// new override is set during a ramp-up its starting effective value
	// seeds from the caller-supplied default; subsequent set_ calls keep
	// the existing effective value so a slider drag doesn't snap.
	HashMap<StringName, float> bone_strength_overrides;
	HashMap<StringName, float> bone_strength_effective;
	float global_strength = 1.0f;          // REQUESTED.
	float effective_global_strength = 1.0f; // What the SPD path reads.

	HashSet<MarionetteBone *> registered_bones;
	MarionetteBone *root_bone = nullptr;

	// Mar-I6 — populated once per physics frame in `snapshot_parent_bases`.
	// Absent entries (root / orphan / cast-failure) → caller's fallback in
	// `get_parent_basis_snapshot`. Cleared per-bone on `unregister_bone` to
	// avoid dangling pointers after teardown.
	HashMap<MarionetteBone *, Basis> parent_basis_snapshots;

	float gravity_scale = 1.0f;
	float hip_upward_nudge = 0.0f; // Newtons, world +Y.
	float hip_nudge_strength_threshold = 0.5f;
	float strength_ramp_duration = 0.5f; // Seconds for 0 → 1 increase.

	// Mar-I14 — rhythm clock state. `body_rhythm_phase` kept in `[0, TAU)`
	// after wrap; `body_rhythm_cycle_index` is monotonic across the
	// session lifetime. Negative frequency clamped at the setter, so the
	// integrator hot path can assume non-negative input.
	float body_rhythm_frequency = 0.4f; // Hz.
	double body_rhythm_phase = 0.0;     // Radians, [0, TAU).
	int64_t body_rhythm_cycle_index = 0;
};

} // namespace godot

#endif // MARIONETTE_CORE_H
