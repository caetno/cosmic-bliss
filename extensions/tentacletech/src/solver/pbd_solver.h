#ifndef TENTACLETECH_PBD_SOLVER_H
#define TENTACLETECH_PBD_SOLVER_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <vector>

#include "tentacle_particle.h"

// Phase-2 PBD core. Spec: docs/architecture/TentacleTech_Architecture.md §3.
//
// Holds the particle chain, rest lengths, and rest bending chords. tick(dt)
// runs predict → iterate × N → finalize per §3.2. The Phase-2 constraint set
// is distance, bending, target-pull, anchor; collision/friction/attachment land
// in Phase 4 and are not invoked here. Finalize implements §3.4: per-segment
// volume preservation → particle girth_scale, asymmetry decay+clamp, and a
// single neighbor-smoothing pass on girth_scale and asymmetry.
//
// All buffers are sized in initialize_chain(); tick() does not allocate.
class PBDSolver : public godot::RefCounted {
	GDCLASS(PBDSolver, godot::RefCounted)

public:
	static constexpr int DEFAULT_ITERATION_COUNT = 4;
	static constexpr int MAX_ITERATION_COUNT = 6;
	static constexpr int DEFAULT_PARTICLE_COUNT = 16;
	static constexpr float DEFAULT_DAMPING = 0.99f;
	static constexpr float DEFAULT_DISTANCE_STIFFNESS = 1.0f;
	static constexpr float DEFAULT_BENDING_STIFFNESS = 0.5f;
	static constexpr float DEFAULT_ASYMMETRY_RECOVERY_RATE = 3.0f;
	static constexpr float DEFAULT_TARGET_STIFFNESS = 0.2f;
	static constexpr float DEFAULT_BASE_ANGULAR_VELOCITY_LIMIT = 0.0f;
	static constexpr float ASYMMETRY_MAGNITUDE_CAP = 0.5f;
	// Slice 4M — Jacobi-with-atomic-deltas-and-SOR pattern (Obi
	// `AtomicDeltas.cginc::ApplyPositionDelta`). Constraints accumulate
	// per-particle position deltas + a touching-constraint count; one apply
	// pass per step divides by count and scales by SOR. SOR > 1 over-relaxes
	// and converges faster but can overshoot; default 1.0 is the safe baseline
	// Obi ships for parallel constraint solving.
	static constexpr float DEFAULT_SOR_FACTOR = 1.0f;
	// Slice 4M / 4P — depenetration velocity cap (m/s). Per-iter normal-lambda
	// growth is clamped so a deeply-penetrated particle (spawned inside a wall,
	// gravity-tunneled past collision-radius on a single tick) is ejected over
	// several ticks rather than in one explosive frame. Maps to Obi's
	// `maxDepenetration`. 1.0 m/s is gentle but resolves typical penetrations
	// in <10 ticks at 60 Hz.
	static constexpr float DEFAULT_MAX_DEPENETRATION = 1.0f;

	PBDSolver();
	~PBDSolver();

	// Lays out a straight chain of N particles spaced p_segment_length along
	// -Z (origin at i=0). All particles start unpinned (inv_mass=1) — caller
	// uses set_anchor() to pin the base. Resets all transient state.
	void initialize_chain(int p_particle_count, float p_segment_length);

	// Per-tick driver. p_dt is the physics step (typically 1/60). No allocs.
	void tick(float p_dt);

	int get_particle_count() const;
	int get_segment_count() const;

	// Configuration --------------------------------------------------------

	void set_iteration_count(int p_iter); // clamped to [1, MAX_ITERATION_COUNT]
	int get_iteration_count() const;

	void set_gravity(const godot::Vector3 &p_gravity);
	godot::Vector3 get_gravity() const;

	void set_damping(float p_damping);
	float get_damping() const;

	void set_distance_stiffness(float p_stiffness);
	float get_distance_stiffness() const;

	void set_bending_stiffness(float p_stiffness);
	float get_bending_stiffness() const;

	void set_asymmetry_recovery_rate(float p_rate);
	float get_asymmetry_recovery_rate() const;

	// Caps the angular speed (rad/sec) of the dynamic particle adjacent to
	// the anchor as it sweeps around the anchor over one tick. 0 disables.
	// Pose pulls and inertia from the rest of the chain can otherwise whip
	// the base around faster than the bending term alone resists.
	void set_base_angular_velocity_limit(float p_omega);
	float get_base_angular_velocity_limit() const;

	// Anchor (hard pin) ----------------------------------------------------

	void set_anchor(int p_particle_index, const godot::Transform3D &p_xform);
	void clear_anchor();
	bool has_anchor() const;
	int get_anchor_particle_index() const;
	godot::Transform3D get_anchor_transform() const;

	// Rigid base — pin the first N particles to the anchor transform so the
	// base segment(s) can't tilt under pose pulls or gravity. Count = 1 (the
	// default) matches the legacy single-particle anchor. Bumping to 2 fixes
	// the segment 0→1 orientation; 3 also locks 1→2, etc. Local offsets are
	// captured from the current particle positions (relative to anchor_xform)
	// at the time set_rigid_base_count is called, then re-applied each time
	// set_anchor receives a new transform.
	void set_rigid_base_count(int p_count);
	int get_rigid_base_count() const;

	// Target pull (soft) ---------------------------------------------------

	void set_target(int p_particle_index, const godot::Vector3 &p_world_pos, float p_stiffness);
	void clear_target();
	bool has_target() const;
	int get_target_particle_index() const;
	godot::Vector3 get_target_position() const;
	float get_target_stiffness() const;

	// Pose targets — distributed soft pull, one per indexed particle. Used
	// by behavior layer to write a full-body "muscular pose" each tick: the
	// chain is actively shaped by per-particle targets rather than dragged
	// from the tip. Composes additively with the single target-pull above.
	// Three parallel arrays of equal length; no Dictionary parsing per tick.
	void set_pose_targets(const godot::PackedInt32Array &p_indices,
			const godot::PackedVector3Array &p_world_positions,
			const godot::PackedFloat32Array &p_stiffnesses);
	void clear_pose_targets();
	int get_pose_target_count() const;
	godot::PackedInt32Array get_pose_target_indices() const;
	godot::PackedVector3Array get_pose_target_positions() const;
	godot::PackedFloat32Array get_pose_target_stiffnesses() const;

	// Per-particle accessors (single-element by-value) ---------------------

	godot::Vector3 get_particle_position(int p_index) const;
	void set_particle_position(int p_index, const godot::Vector3 &p_pos);
	float get_particle_inv_mass(int p_index) const;
	void set_particle_inv_mass(int p_index, float p_inv_mass);
	godot::Vector2 get_particle_asymmetry(int p_index) const;
	void set_particle_asymmetry(int p_index, const godot::Vector2 &p_asym);
	float get_particle_girth_scale(int p_index) const;

	// Snapshot accessors (PackedArray copies; never live pointers) ---------

	godot::PackedVector3Array get_particle_positions() const;
	godot::PackedFloat32Array get_particle_inv_masses() const;
	godot::PackedFloat32Array get_segment_stretch_ratios() const;
	godot::PackedFloat32Array get_particle_girth_scales() const;

	// Rest-state introspection ---------------------------------------------

	float get_rest_length(int p_segment_index) const;

	// In-place rest-length update — rescales every segment's rest length and
	// every triple's rest bending chord without touching particle positions.
	// Used when the Tentacle's segment_length changes at runtime: distance
	// constraints converge over a few iterations without the visible snap a
	// full rebuild_chain would cause.
	void set_uniform_rest_length(float p_length);

	// Type-4 collision (§4.2). Slice 4M: up to MAX_CONTACTS_PER_PARTICLE (= 2)
	// simultaneous contacts per particle so wedge configurations (chain
	// pinched between two solid colliders) get a stable manifold instead
	// of cycling through "nearest" contact tick-to-tick. The probe (in
	// `environment_probe.cpp`) calls `get_rest_info` repeatedly with a
	// growing exclude list and sorts the slots by penetration depth so
	// slot 0 is the deepest.
	//
	// Buffer sizes:
	//   p_points  / p_normals : N * MAX_CONTACTS_PER_PARTICLE (slot k for
	//                           particle i lives at index
	//                           i * MAX_CONTACTS_PER_PARTICLE + k).
	//   p_counts              : N bytes (0..MAX_CONTACTS_PER_PARTICLE).
	//
	// Spec divergence: §4.2 / §4.5 specify raycasts + ragdoll snapshot.
	// Per-particle sphere queries cover both at once (the physics server
	// already routes ragdoll-bone transforms to us during the query); slice
	// 4M extends the per-particle query to a manifold of up to 2 contacts.
	// See update docs 2026-05-02 and 2026-05-03.
	void set_environment_contacts_multi(
			const godot::PackedVector3Array &p_points,
			const godot::PackedVector3Array &p_normals,
			const godot::PackedByteArray &p_counts);
	void clear_environment_contacts();
	int get_environment_contact_count() const;

	// Slice 4M: tangential displacement actually canceled per *contact slot*
	// this tick, summed across iterations. Size = N * MAX_CONTACTS_PER_PARTICLE,
	// indexed as slot[i*MAX + k]. Each slot's friction is sized
	// proportional to that slot's per-iter penetration depth at friction-
	// application time, so the type-1 reciprocal pass routes each slot's
	// share to its own colliding body. Tentacle reads this when building
	// the §15.2 environment-contacts snapshot.
	godot::PackedVector3Array get_environment_friction_applied() const;

	// Per-tentacle base collision radius. Each particle's effective collision
	// radius for slice 4A is `collision_radius * particle.girth_scale`.
	// Asymmetry ellipse (§4.1) is deferred to a later slice.
	void set_collision_radius(float p_radius);
	float get_collision_radius() const;

	// §4.3 friction coefficients. `static` is the composed μ_s after §4.4
	// modulators are applied by the caller; `kinetic_ratio` is μ_k / μ_s
	// (typical 0.8 per spec). For slice 4B both are tentacle-global; later
	// slices replace this with per-contact composition once surface tagging
	// lands.
	void set_friction(float p_static, float p_kinetic_ratio);
	float get_static_friction() const;
	float get_kinetic_friction_ratio() const;

	// Slice 4C (§4.3): per-particle distance constraint stiffness during
	// active contact. Default 0.5 — the chain stretches temporarily over
	// wrapped geometry instead of fighting collision push-out, then springs
	// back when contact ends. Compounds across iterations: at 4 iterations,
	// 0.5 → ~0.94 effective per tick.
	void set_contact_stiffness(float p_stiffness);
	float get_contact_stiffness() const;

	// Slice 4M-pre.2 — multiplier on target-pull stiffness for in-contact
	// particles. Applied uniformly to BOTH the singleton tip target
	// (`set_target`) and every entry in the distributed pose-target list
	// inside the iterate loop. Below 1 lets the chain *give* to obstacles
	// instead of fighting them — addresses the "tentacle jitters between
	// legs" failure mode where pose / target pulls fight collision push-out
	// at full strength. Default 0.3 matches the prior behavior_driver value.
	//
	// Reads `particle.in_contact_this_tick`, which is set by the previous
	// iteration's collision pass (or the previous tick on iter 0). That's
	// stale by at most one iteration, which is accurate enough for stiffness
	// modulation — the cost of being wrong for one iter is at most one
	// reduced/raised pull on that particle, with no effect on convergence.
	void set_target_softness_when_blocked(float p_softness);
	float get_target_softness_when_blocked() const;

	// Slice 4M — Jacobi successive-over-relaxation factor for the position
	// delta accumulator. 1.0 = strict average (Obi default for parallel mode);
	// 1.5–2.0 over-relaxes and accelerates convergence at the risk of
	// overshoot. Per-mood tunable; leave at default unless a specific
	// scenario needs faster convergence and tolerates the overshoot.
	void set_sor_factor(float p_factor);
	float get_sor_factor() const;

	// Slice 4M / 4P — depenetration velocity cap (m/s). Per-iter normal lambda
	// growth is clamped to `max_depenetration × dt` so deep penetrations are
	// resolved over several ticks instead of one explosive ejection. Default
	// 1.0 m/s.
	void set_max_depenetration(float p_v);
	float get_max_depenetration() const;

	// Slice 4I — contact velocity damping. Lerp factor (0..1) applied at
	// end of finalize() to bleed implicit per-tick velocity from particles
	// flagged in_contact_this_tick. Addresses tick-rate jitter caused by
	// constraint conflict (bending wants chord-into-obstacle, collision
	// pushes out, etc.) which the iter loop cannot converge — each iter
	// adds net drift, sum becomes implicit velocity that carries forward.
	// 0 = disabled, 1 = fully kill velocity for in-contact particles,
	// 0.5 = halve per tick (visible oscillation fades in 4–5 ticks).
	void set_contact_velocity_damping(float p_damping);
	float get_contact_velocity_damping() const;

	// Slice 4K — gravity supported by contact. When true (default), in
	// predict() the gravity step `gravity × dt²` is projected onto the
	// contact tangent plane for particles whose probe reports an active
	// contact, instead of being added in full. Physical model: a brick on
	// a floor doesn't sink — the contact supports its weight. Per-tick
	// the in-contact particle no longer "gravity-bounces" against the
	// constraint, removing the seed of the iter-loop amplification that
	// is responsible for the tick-rate jitter the user sees in wedged
	// configurations. Tangent gravity (slope component) is preserved so
	// sliding still works.
	void set_support_in_contact(bool p_value);
	bool get_support_in_contact() const;

	// Snapshot (§15.2) of `in_contact_this_tick` flags. Byte per particle:
	// 1 = in contact, 0 = free. PackedByteArray rather than bool[] so it
	// crosses the GDScript boundary without a per-element Variant box.
	godot::PackedByteArray get_particle_in_contact_snapshot() const;

	// Slice 4M-XPBD — per-segment XPBD distance Lagrange multipliers. The
	// lambdas accumulate across iterations within a tick and reset in
	// predict() each tick (or per substep once 4O lands). Snapshot accessor
	// so tests can validate the reset is wired (steady chain settles to
	// bounded lambda magnitudes; a missing reset would diverge).
	godot::PackedFloat32Array get_distance_lambdas_snapshot() const;

protected:
	static void _bind_methods();

private:
	std::vector<TentacleParticle> particles;
	std::vector<float> rest_lengths;             // size N-1
	std::vector<float> rest_bending_chord_lengths; // size N-2

	// Pre-allocated buffers for the finalize smoothing pass (size N).
	std::vector<float> smooth_girth_buffer;
	std::vector<godot::Vector2> smooth_asym_buffer;

	// Slice 4M — Jacobi position-delta accumulator (Obi `AtomicDeltas.cginc`
	// adapted for single-threaded CPU). Each constraint step pushes
	// position deltas via add_position_delta(); after the step,
	// apply_position_deltas_all() divides each particle's accumulated delta
	// by its `position_delta_count` (with `sor_factor`) and writes to
	// position. Buffers sized N in initialize_chain; zeroed by apply.
	std::vector<godot::Vector3> position_delta_scratch;
	std::vector<int> position_delta_count;

	// Slice 4M-XPBD — per-segment XPBD distance constraint Lagrange
	// multipliers (Obi `DistanceConstraints.compute`). Size N-1; reset to 0
	// in predict() per tick (or per substep once 4O lands). Persisting
	// across iters within a tick is what makes XPBD position-correct under
	// repeated solves.
	std::vector<float> distance_lambdas;

	int iteration_count = DEFAULT_ITERATION_COUNT;
	godot::Vector3 gravity = godot::Vector3(0.0f, -9.8f, 0.0f);
	float damping = DEFAULT_DAMPING;
	float distance_stiffness = DEFAULT_DISTANCE_STIFFNESS;
	float bending_stiffness = DEFAULT_BENDING_STIFFNESS;
	float asymmetry_recovery_rate = DEFAULT_ASYMMETRY_RECOVERY_RATE;
	float base_angular_velocity_limit = DEFAULT_BASE_ANGULAR_VELOCITY_LIMIT;

	bool anchor_active = false;
	int anchor_particle_index = -1;
	godot::Transform3D anchor_xform;

	// Rigid base — particles [0, rigid_base_count) follow anchor_xform via
	// stored local offsets. Sized whenever set_rigid_base_count is called.
	int rigid_base_count = 1;
	std::vector<godot::Vector3> rigid_base_local_offsets;

	bool target_active = false;
	int target_particle_index = -1;
	godot::Vector3 target_position;
	float target_stiffness = DEFAULT_TARGET_STIFFNESS;

	// Type-4 environment contacts. Slice 4M: up to MAX_CONTACTS_PER_PARTICLE
	// slots per particle. Points/normals are flat N×MAX arrays — slot k for
	// particle i lives at index `i * MAX_CONTACTS_PER_PARTICLE + k`. The
	// per-particle `count` byte holds the number of valid slots
	// (0..MAX_CONTACTS_PER_PARTICLE). `friction_applied` matches the slot
	// layout so the type-1 reciprocal pass routes each slot's friction to
	// its own colliding body.
	//
	// `env_contact_normal_lambda` (slice 4M) and `env_contact_tangent_lambda`
	// (slice 4M) are per-slot Lagrange-multiplier accumulators (Obi
	// `ContactHandling.cginc::contact`). Persistent across iterations within
	// a tick (or substep once 4O lands); reset whenever
	// set_environment_contacts_multi() loads a fresh probe. Lambdas in
	// position-magnitude×inverse-mass units (m·kg in textbook PBD; here
	// inv_mass is dimensionless 0/1 so lambdas are effectively meters).
	godot::PackedVector3Array env_contact_points;
	godot::PackedVector3Array env_contact_normals;
	godot::PackedByteArray env_contact_count;
	godot::PackedVector3Array env_contact_friction_applied;
	std::vector<float> env_contact_normal_lambda;
	std::vector<godot::Vector3> env_contact_tangent_lambda;
	float collision_radius = 0.05f;
	float friction_static = 0.0f;
	float friction_kinetic_ratio = 0.8f;
	float contact_stiffness = 0.5f;
	float target_softness_when_blocked = 0.3f;
	float contact_velocity_damping = 0.5f;
	bool support_in_contact = true;
	float sor_factor = DEFAULT_SOR_FACTOR;
	float max_depenetration = DEFAULT_MAX_DEPENETRATION;

	// Pose targets are stored as parallel PackedArrays — same lifetime
	// model as the snapshot accessors (copy in / copy out). The behavior
	// layer rebuilds them each tick; the iteration loop reads them as a
	// flat list with no per-entry dictionary parsing.
	godot::PackedInt32Array pose_target_indices;
	godot::PackedVector3Array pose_target_positions;
	godot::PackedFloat32Array pose_target_stiffnesses;

	void predict(float p_dt);
	void iterate(float p_dt);
	void apply_base_angular_clamp(float p_dt);
	void finalize(float p_dt);

	// Slice 4M Jacobi accumulator helpers (Obi `AtomicDeltas.cginc`):
	// constraints push deltas; once-per-step apply divides by count and
	// scales by sor_factor. Inlined for clarity / call-site density.
	inline void add_position_delta(int p_idx, const godot::Vector3 &p_d) {
		position_delta_scratch[p_idx] += p_d;
		position_delta_count[p_idx] += 1;
	}
	inline void apply_position_deltas_all() {
		int n = (int)particles.size();
		for (int i = 0; i < n; i++) {
			int c = position_delta_count[i];
			if (c > 0) {
				particles[i].position +=
						position_delta_scratch[i] * (sor_factor / (float)c);
				position_delta_scratch[i] = godot::Vector3();
				position_delta_count[i] = 0;
			}
		}
	}
};

#endif // TENTACLETECH_PBD_SOLVER_H
