#ifndef TENTACLETECH_ORIFICE_H
#define TENTACLETECH_ORIFICE_H

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <vector>

class Tentacle;

// Phase-5 slice 5A primitive. Spec:
// docs/architecture/TentacleTech_Architecture.md §6.1–§6.4 (rim particle
// loop model, amended 2026-05-03 per
// docs/Cosmic_Bliss_Update_2026-05-03_orifice_rim_model.md). This slice
// implements the rim primitive in isolation:
//   - one or more closed-loop rims of N PBD particles each;
//   - per-loop XPBD constraint set: distance around the loop +
//     volume on the enclosed polygon area (Obi
//     `VolumeConstraints.compute` reduced from a 3D triangle fan to a
//     2D shoelace) + per-particle spring-back to authored rest position
//     in Center frame.
//
// Out of scope for 5A (later slices):
//   - EntryInteraction, tentacle-to-rim contact (5B/5C);
//   - host-bone soft attachment (5B);
//   - type-2/3 collision (5C);
//   - reaction-on-host-bone routing per §6.3 (5C);
//   - inter-loop coupling (data structure ready; later authoring slice);
//   - multi-tentacle, jaw, peristalsis, realism sub-slices (later
//     phases / sub-slices).
//
// Pattern: solver runs Jacobi-with-atomic-deltas-and-SOR with per-
// constraint persistent lambda accumulators reset in predict() each
// tick — exactly the foundation Phase 4 settled on for the chain
// solver (`PBDSolver`). The rim primitive does not share buffers with
// the chain solver; it owns its own per-loop accumulators.

struct RimParticle {
	godot::Vector3 position;
	godot::Vector3 prev_position;
	float inv_mass = 1.0f;
	// Authored offset from the orifice Center bone. In 5A (no host bone
	// soft attachment yet), Center frame == orifice node global_transform
	// at construction time; rest-world is recomputed each tick.
	godot::Vector3 rest_position_in_center_frame;
	// XPBD lambda accumulators — reset in predict() each tick, persist
	// across iters within a tick. Snapshot accessor surfaces both for
	// the §15.2 dictionary.
	float distance_lambda_to_next = 0.0f; // for the segment (k, k+1)
	float spring_lambda = 0.0f;           // for the per-particle spring-back
};

struct RimLoopState {
	int particle_count = 0;
	std::vector<RimParticle> rim_particles;
	std::vector<float> rim_segment_rest_lengths; // size N (closed loop)

	// Volume constraint target (signed polygon area, projected to plane
	// perp to entry_axis). Active contraction (§6.10) modulates this in
	// later slices; in 5A the value is authored once.
	float target_enclosed_area = 0.0f;

	// Per-particle stiffness of the spring-back to authored rest. Bilateral
	// compliance is this distribution (front-of-mouth tighter than back, etc.).
	std::vector<float> rim_particle_rest_stiffness_per_k; // size N

	// Slice 5C-A — per-rim-particle contact radius. Sums with the
	// tentacle particle's `collision_radius × girth_scale` to produce
	// the type-2 contact threshold. Default 0.02 m authored at
	// `add_rim_loop` time; per-particle so anatomy with thicker /
	// thinner rim flesh can be authored.
	std::vector<float> rim_contact_radius_per_k; // size N

	// Per-loop tunables (§6.4).
	float area_compliance = 1e-4f;     // low → near-incompressible
	float distance_compliance = 1e-6f; // low → taut circumference

	// XPBD volume Lagrange multiplier (one per loop, scalar). Reset in
	// predict() each tick; persists across iters within the tick.
	float area_lambda = 0.0f;

	// Per-loop Jacobi position-delta accumulator (Obi `AtomicDeltas.cginc`
	// pattern). Sized N in `add_rim_loop`; `apply` divides by count and
	// scales by sor_factor.
	std::vector<godot::Vector3> position_delta_scratch;
	std::vector<int> position_delta_count;
};

// Slice 5C-A — type-2 contact (tentacle particle ↔ rim particle).
// Persistent across iters within a tick; rebuilt every tick. Holds the
// XPBD `normal_lambda` accumulator that scales each contact's response
// across iters and is the future input to the §6.3 reaction-on-host-bone
// pass (5C-C scope).
struct Type2Contact {
	int tentacle_idx = -1;
	int particle_idx = -1;
	int loop_idx = -1;
	int rim_particle_idx = -1;
	// Cached contact geometry from the start-of-tick collection pass.
	// `normal` points from tentacle particle toward rim particle (the
	// rim is pushed in `+normal`, the tentacle in `-normal`); `radii_sum`
	// is `tentacle.collision_radius × girth_scale + rim_contact_radius_per_k`.
	godot::Vector3 normal;
	float radii_sum = 0.0f;
	// XPBD lambda accumulator. Persists across iters within a tick;
	// reset to 0 in `_collect_type2_contacts`. Clamped to ≥ 0 (contacts
	// only push, never pull) per Obi `ParticleCollisionConstraints.compute`.
	float normal_lambda = 0.0f;
};

class Orifice : public godot::Node3D {
	GDCLASS(Orifice, godot::Node3D)

public:
	static constexpr int DEFAULT_ITERATION_COUNT = 4;
	static constexpr int MAX_ITERATION_COUNT = 8;
	static constexpr float DEFAULT_SOR_FACTOR = 1.0f;
	static constexpr float DEFAULT_DAMPING = 0.99f;

	Orifice();
	~Orifice();

	void _ready() override;
	void _physics_process(double p_delta) override;

	// Per-tick driver. Runs predict → iterate × N → finalize for every
	// rim loop in turn. Each loop has its own constraint accumulators;
	// loops are independent at the dynamics level (inter-loop coupling
	// constraints are out-of-scope for 5A).
	void tick(float p_dt);

	// Configuration --------------------------------------------------------

	void set_iteration_count(int p_iter);
	int get_iteration_count() const;
	void set_sor_factor(float p_factor);
	float get_sor_factor() const;
	void set_damping(float p_damping);
	float get_damping() const;
	void set_gravity(const godot::Vector3 &p_gravity);
	godot::Vector3 get_gravity() const;
	// Outward axis of the orifice opening. Used by the volume constraint
	// to pick the plane in which the polygon area is measured. Need not
	// be exactly perpendicular to the rim — the projection is robust as
	// long as it's not parallel to the rim plane. Default +Z.
	void set_entry_axis(const godot::Vector3 &p_axis);
	godot::Vector3 get_entry_axis() const;

	// Host bone soft attachment (slice 5B). The orifice's Center frame
	// inherits the bone's `global_transform * get_bone_global_pose(idx)`
	// at the start of each `tick()`, optionally with an authored
	// `host_bone_offset` so the orifice can sit slightly off the bone
	// origin without re-rigging. When unset (skeleton_path empty or
	// bone_name empty or resolution fails), the orifice falls back to
	// its own `global_transform` (slice 5A behavior — no warnings).
	//
	// The bone transform is read ONCE at tick start. Per-iteration calls
	// to `get_bone_global_pose` would force a skeleton recompute and
	// kill performance, so the iterate loop reads the cached node
	// global_transform instead. Same discipline as the §4 ragdoll
	// snapshot non-negotiable.
	void set_skeleton_path(const godot::NodePath &p_path);
	godot::NodePath get_skeleton_path() const;
	void set_bone_name(const godot::StringName &p_name);
	godot::StringName get_bone_name() const;
	void set_host_bone_offset(const godot::Transform3D &p_offset);
	godot::Transform3D get_host_bone_offset() const;
	// Convenience setter — paths-and-name in one call. Equivalent to
	// `set_skeleton_path` then `set_bone_name`. Returns true if the
	// resolution succeeded (the cached pointer + bone index are valid),
	// false if the skeleton can't be located or the bone doesn't exist
	// (the orifice falls back to its own transform either way).
	bool set_host_bone(const godot::NodePath &p_skeleton_path, const godot::StringName &p_bone_name);

	// Snapshot of the host bone state for the gizmo overlay + tests.
	//   { has_host_bone: bool, skeleton_path, bone_name, bone_index,
	//     current_world_transform: Transform3D }
	// `current_world_transform` is the bone's resolved world transform
	// (skeleton.global_transform × get_bone_global_pose(idx)) WITHOUT
	// `host_bone_offset` applied — the offset is what positions the
	// orifice's Center frame relative to that. `bone_index` is -1 when
	// unresolved.
	godot::Dictionary get_host_bone_state() const;

	// Resolved Center frame in world space for the current tick. Equals
	// `bone.global_transform × get_bone_global_pose × host_bone_offset`
	// when the host bone is active, else falls back to the orifice's
	// own `global_transform` (or identity if not in tree). This is the
	// frame the rim particle rest positions are projected through into
	// world space; expose it so tests + gizmos don't have to fight
	// Godot's `global_transform` getter (which fails outside the tree
	// in `--script` mode).
	godot::Transform3D get_center_frame_world() const;

	// Tentacle registration (slice 5C-A) — contacts are checked against
	// every registered tentacle each tick. `register_tentacle` /
	// `unregister_tentacle` are imperative API; the @export
	// `tentacle_paths` array is the authoring-time path list, kept in
	// sync by both routes.
	void set_tentacle_paths(const godot::TypedArray<godot::NodePath> &p_paths);
	godot::TypedArray<godot::NodePath> get_tentacle_paths() const;
	bool register_tentacle(const godot::NodePath &p_path);
	bool unregister_tentacle(const godot::NodePath &p_path);
	int get_registered_tentacle_count() const;
	int get_resolved_tentacle_count() const;
	godot::NodePath get_tentacle_path(int p_index) const;

	// Per-tick fresh snapshot (slice 5C-A) of the active type-2 contact
	// list. Each entry: { tentacle_path, particle_index, loop_index,
	// rim_particle_index, normal, distance, normal_lambda }. `distance`
	// is signed (negative means penetrating; XPBD pushes lambda toward
	// the value that drives this to zero across iters).
	godot::Array get_type2_contacts_snapshot() const;

	// Authoring API --------------------------------------------------------

	// Append a new rim loop. Returns the loop index, or -1 on invalid
	// input. `p_rest_positions_in_center_frame` and
	// `p_rest_stiffness_per_k` length determines N; `p_segment_rest_lengths`
	// must be the same size (closed loop, segment k connects particle k to
	// (k+1) mod N). `p_target_enclosed_area` should be the polygon area
	// computed from the rest positions (utility `compute_polygon_area`
	// available statically). `p_default_contact_radius` is the per-rim-
	// particle contact radius applied uniformly to every particle; pass
	// 0 (or negative) to use the slice 5C-A default of 0.02 m.
	int add_rim_loop(
			const godot::PackedVector3Array &p_rest_positions_in_center_frame,
			const godot::PackedFloat32Array &p_segment_rest_lengths,
			float p_target_enclosed_area,
			const godot::PackedFloat32Array &p_rest_stiffness_per_k,
			float p_area_compliance,
			float p_distance_compliance,
			float p_default_contact_radius = 0.02f);

	// Per-particle authoring of the contact radius, after `add_rim_loop`.
	// Negative values are clamped to 0 (no contact at that particle).
	void set_rim_contact_radius(int p_loop_index, int p_particle_index, float p_radius);
	float get_rim_contact_radius(int p_loop_index, int p_particle_index) const;

	// Remove all rim loops; resets internal buffers. Does not affect
	// orifice config (gravity, iteration_count, etc.).
	void clear_rim_loops();

	// Static helpers used by tests / authoring scripts to build a uniform
	// circular rest pose. `radius` is meters; `entry_axis` is the rim
	// normal; rest positions are placed in the plane perpendicular to
	// entry_axis at distance `radius` from origin, equispaced angularly.
	static godot::PackedVector3Array make_circular_rest_positions(
			int p_n, float p_radius, const godot::Vector3 &p_entry_axis);
	static godot::PackedFloat32Array make_uniform_segment_rest_lengths(
			const godot::PackedVector3Array &p_rest_positions);
	static float compute_polygon_area(
			const godot::PackedVector3Array &p_positions,
			const godot::Vector3 &p_entry_axis);

	// Snapshot accessors (§15.2) ------------------------------------------

	int get_rim_loop_count() const;

	// Per-rim-particle Dictionary list:
	//   { rest_position, current_position, current_velocity,
	//     spring_lambda, distance_lambda, neighbour_rest_distance }
	// `rest_position` is in world frame (projected through the orifice
	// node's global_transform, which doubles as the Center frame in 5A).
	godot::Array get_rim_loop_state(int p_loop_index) const;

	// Per-loop scalar lambda for the volume (area) constraint. Useful as
	// a divergence canary in tests (steady-state with no perturbation
	// should leave area_lambda small after a few ticks).
	float get_loop_area_lambda(int p_loop_index) const;
	float get_loop_target_enclosed_area(int p_loop_index) const;
	float get_loop_current_enclosed_area(int p_loop_index) const;

	// Per-particle authoring access — used by tests to perturb a rim
	// particle (set position) or read its position back without going
	// through the snapshot list per call.
	void set_particle_position(
			int p_loop_index, int p_particle_index, const godot::Vector3 &p_world_pos);
	godot::Vector3 get_particle_position(int p_loop_index, int p_particle_index) const;
	// Authoring-time override for one rim particle's mass so tests can
	// pin a particle (inv_mass = 0) and study how the rest of the loop
	// settles around it.
	void set_particle_inv_mass(int p_loop_index, int p_particle_index, float p_inv_mass);

	// Modulation channel for §6.10 ContractionPulse / §6.7 peristalsis
	// (full plumbing in later slices). 5A exposes the setter so tests
	// can validate the volume constraint pulls the loop toward the new
	// target.
	void set_loop_target_enclosed_area(int p_loop_index, float p_target);

protected:
	static void _bind_methods();

private:
	// Solver config.
	int iteration_count = DEFAULT_ITERATION_COUNT;
	float sor_factor = DEFAULT_SOR_FACTOR;
	float damping = DEFAULT_DAMPING;
	godot::Vector3 gravity = godot::Vector3(0.0f, 0.0f, 0.0f);
	godot::Vector3 entry_axis = godot::Vector3(0.0f, 0.0f, 1.0f);

	// Host bone soft attachment (slice 5B). `_skeleton_cached` and
	// `_bone_index_cached` are resolved lazily inside
	// `_resolve_host_bone_lazy()`; `_host_bone_dirty` triggers a re-
	// resolve on the next refresh after any of `skeleton_path`,
	// `bone_name`, or the scene tree topology might have changed.
	// `_host_bone_active` is the result of the last resolve — true only
	// if both the skeleton pointer is non-null AND the bone index is
	// >= 0. Falls back to the orifice node's own global_transform
	// otherwise (silently — no warnings, matching slice 5A behavior).
	godot::NodePath skeleton_path;
	godot::StringName bone_name;
	godot::Transform3D host_bone_offset;
	mutable godot::Skeleton3D *_skeleton_cached = nullptr;
	mutable int _bone_index_cached = -1;
	mutable bool _host_bone_active = false;
	mutable bool _host_bone_dirty = true;
	// Once-per-tick resolved Center frame in world space. Refreshed at
	// the start of `tick()` and read by every rim particle's rest-world
	// projection inside the iterate loop. Stays at identity until the
	// first `tick()` runs.
	godot::Transform3D _center_frame_cached;

	// Resolves `skeleton_path` + `bone_name` to a cached pointer + bone
	// index. Cheap when not dirty (single bool check). Const so const
	// snapshot accessors can call it; the cache is `mutable`.
	void _resolve_host_bone_lazy() const;
	// Reads the bone's resolved world transform from the cached
	// skeleton/bone (must follow `_resolve_host_bone_lazy()`). Returns
	// `Transform3D()` if the cache says the host bone is inactive.
	godot::Transform3D _read_host_bone_world_transform() const;
	// Refreshes `_center_frame_cached` from the active state — bone-
	// driven when host bone is active, else the orifice's own
	// `global_transform` (with `is_inside_tree` guard so `--script`
	// SceneTrees don't print warnings). Called once per `tick()`.
	void _refresh_center_frame_cache();

	std::vector<RimLoopState> rim_loops;

	// Slice 5C-A — registered tentacles for type-2 contact + cached
	// resolved pointers. `tentacle_paths` is authored; `_tentacles_resolved`
	// is rebuilt lazily from the paths each tick (cheap re-validate, same
	// pattern as 5B's host-bone resolver).
	godot::TypedArray<godot::NodePath> tentacle_paths;
	mutable std::vector<Tentacle *> _tentacles_resolved;
	mutable bool _tentacles_dirty = true;

	// Slice 5C-A — fresh-this-tick contact list. Built in
	// `_collect_type2_contacts` from the registered tentacles + every
	// rim loop, brute-force N×M; the iterate step reads it back to drive
	// XPBD bilateral projection.
	std::vector<Type2Contact> _type2_contacts;

	// Tick stages — per-loop.
	void _predict_loop(RimLoopState &loop, float p_dt);
	// Slice 5C-A — single-iteration body extracted from the previous
	// `_iterate_loop`. The new outer `tick()` runs `iteration_count`
	// passes, interleaving per-loop constraint passes with the cross-
	// loop type-2 contact pass.
	void _iterate_loop_one_pass(RimLoopState &loop, float p_dt);
	void _finalize_loop(RimLoopState &loop, float p_dt);

	// Slice 5C-A — type-2 contact infrastructure.
	void _resolve_tentacles_lazy() const;
	Tentacle *_resolve_node_to_tentacle(const godot::NodePath &p_path) const;
	void _collect_type2_contacts();
	void _iterate_type2_contacts(float p_dt);

	// Jacobi delta helpers, scoped per loop (each loop owns its own
	// scratch buffers — no cross-loop interference).
	inline void _add_delta(RimLoopState &loop, int p_k, const godot::Vector3 &p_d) {
		loop.position_delta_scratch[p_k] += p_d;
		loop.position_delta_count[p_k] += 1;
	}
	inline void _apply_deltas_all(RimLoopState &loop) {
		int n = (int)loop.rim_particles.size();
		for (int i = 0; i < n; i++) {
			int c = loop.position_delta_count[i];
			if (c > 0) {
				loop.rim_particles[i].position +=
						loop.position_delta_scratch[i] * (sor_factor / (float)c);
				loop.position_delta_scratch[i] = godot::Vector3();
				loop.position_delta_count[i] = 0;
			}
		}
	}
};

#endif // TENTACLETECH_ORIFICE_H
