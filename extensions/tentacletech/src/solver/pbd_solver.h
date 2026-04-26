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

	// Anchor (hard pin) ----------------------------------------------------

	void set_anchor(int p_particle_index, const godot::Transform3D &p_xform);
	void clear_anchor();
	bool has_anchor() const;
	int get_anchor_particle_index() const;
	godot::Transform3D get_anchor_transform() const;

	// Target pull (soft) ---------------------------------------------------

	void set_target(int p_particle_index, const godot::Vector3 &p_world_pos, float p_stiffness);
	void clear_target();
	bool has_target() const;
	int get_target_particle_index() const;
	godot::Vector3 get_target_position() const;
	float get_target_stiffness() const;

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

	bool anchor_active = false;
	int anchor_particle_index = -1;
	godot::Transform3D anchor_xform;

	bool target_active = false;
	int target_particle_index = -1;
	godot::Vector3 target_position;
	float target_stiffness = DEFAULT_TARGET_STIFFNESS;

	void predict(float p_dt);
	void iterate();
	void finalize(float p_dt);
};

#endif // TENTACLETECH_PBD_SOLVER_H
