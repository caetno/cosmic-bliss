#ifndef TENTACLETECH_PBD_SOLVER_H
#define TENTACLETECH_PBD_SOLVER_H

#include <godot_cpp/classes/ref_counted.hpp>
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

	// Type-4 collision (§4.2). The Tentacle issues raycasts before tick() and
	// hands the hits in as half-space planes; the solver projects particles
	// out of any plane they're within `collision_radius * girth_scale` of,
	// after distance constraints, every iteration. Slice 4A: normal-only
	// projection. Friction (§4.3) lands in slice 4B.
	//
	// `p_points` and `p_normals` must be the same length; one entry per
	// active contact. Setting empty arrays disables environment collision
	// for the next tick. Buffers are copied; the solver does not retain
	// references to caller-owned storage.
	void set_environment_contacts(const godot::PackedVector3Array &p_points,
			const godot::PackedVector3Array &p_normals);
	void clear_environment_contacts();
	int get_environment_contact_count() const;

	// Per-tentacle base collision radius. Each particle's effective collision
	// radius for slice 4A is `collision_radius * particle.girth_scale`.
	// Asymmetry ellipse (§4.1) is deferred to a later slice.
	void set_collision_radius(float p_radius);
	float get_collision_radius() const;

protected:
	static void _bind_methods();

private:
	std::vector<TentacleParticle> particles;
	std::vector<float> rest_lengths;             // size N-1
	std::vector<float> rest_bending_chord_lengths; // size N-2

	// Pre-allocated buffers for the finalize smoothing pass (size N).
	std::vector<float> smooth_girth_buffer;
	std::vector<godot::Vector2> smooth_asym_buffer;

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

	// Type-4 environment contacts as half-space planes. Same lifetime model
	// as pose_targets: Tentacle rebuilds them each tick, solver reads from
	// the flat list during iteration. Slice 4A: normal projection only.
	godot::PackedVector3Array env_contact_points;
	godot::PackedVector3Array env_contact_normals;
	float collision_radius = 0.05f;

	// Pose targets are stored as parallel PackedArrays — same lifetime
	// model as the snapshot accessors (copy in / copy out). The behavior
	// layer rebuilds them each tick; the iteration loop reads them as a
	// flat list with no per-entry dictionary parsing.
	godot::PackedInt32Array pose_target_indices;
	godot::PackedVector3Array pose_target_positions;
	godot::PackedFloat32Array pose_target_stiffnesses;

	void predict(float p_dt);
	void iterate();
	void apply_base_angular_clamp(float p_dt);
	void finalize(float p_dt);
};

#endif // TENTACLETECH_PBD_SOLVER_H
