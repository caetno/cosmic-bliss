#ifndef TENTACLETECH_TENTACLE_H
#define TENTACLETECH_TENTACLE_H

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include "pbd_solver.h"

// Phase-2 Tentacle Node3D. Wraps a PBDSolver and drives it from
// _physics_process. Spec: docs/architecture/TentacleTech_Architecture.md §3,
// §15. Snapshot accessors per §15.2 forward to the solver and add the
// target/anchor state Dictionaries the debug overlay consumes.
//
// The base particle (index 0) is anchored to the node's global transform every
// physics tick before tick(); pinned via inv_mass = 0 inside the solver.
class Tentacle : public godot::Node3D {
	GDCLASS(Tentacle, godot::Node3D)

public:
	Tentacle();
	~Tentacle();

	void _ready() override;
	void _physics_process(double p_delta) override;
	void _notification(int p_what);

	// Configuration (re-initializes the chain when changed at runtime).
	void set_particle_count(int p_count);
	int get_particle_count() const;
	void set_segment_length(float p_length);
	float get_segment_length() const;

	// Re-create the chain with the current particle_count and segment_length.
	void rebuild_chain();

	// Solver tuning forwarded to PBDSolver — exposed on the node so the
	// inspector can edit them directly. Each setter snaps the underlying
	// solver state; no chain rebuild happens.
	void set_iteration_count(int p_iter);
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

	// Target pull (soft, on the tip particle by default).
	void set_target(const godot::Vector3 &p_world_pos);
	void clear_target();
	void set_target_stiffness(float p_stiffness);
	float get_target_stiffness() const;
	void set_target_particle_index(int p_index);
	int get_target_particle_index() const;

	// Anchor — explicit override. By default, the tentacle anchors particle 0
	// to its own global_transform every physics tick. Calling
	// set_anchor_transform() with a fixed transform disables auto-tracking
	// until clear_anchor_override() is called.
	void set_anchor_transform(const godot::Transform3D &p_xform);
	void clear_anchor_override();

	// Direct solver access (so GDScript glue can tune iteration count, gravity,
	// etc., without re-binding every PBDSolver setter on Tentacle too).
	godot::Ref<PBDSolver> get_solver() const;

	// Snapshot accessors per §15.2 ----------------------------------------

	godot::PackedVector3Array get_particle_positions() const;
	godot::PackedFloat32Array get_particle_inv_masses() const;
	godot::PackedFloat32Array get_segment_stretch_ratios() const;
	godot::Dictionary get_target_pull_state() const;
	godot::Dictionary get_anchor_state() const;

protected:
	static void _bind_methods();

private:
	godot::Ref<PBDSolver> solver;
	int particle_count = PBDSolver::DEFAULT_PARTICLE_COUNT;
	float segment_length = 0.1f;

	// When false, _physics_process refreshes the anchor to the node's global
	// transform each tick. When true, the user has set a fixed anchor and we
	// don't overwrite it.
	bool anchor_override = false;
};

#endif // TENTACLETECH_TENTACLE_H
