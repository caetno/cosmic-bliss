#ifndef TENTACLETECH_CANAL_CENTERLINE_SOLVER_H
#define TENTACLETECH_CANAL_CENTERLINE_SOLVER_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <vector>

// Slice 5F.A — Canal centerline PBD chain solver.
//
// A small position-based dynamics chain of M particles representing the
// centerline of a canal. Two endpoints are hard-pinned to anchor world
// positions (proximal + distal); interior particles are integrated via
// symplectic Verlet with distance + bending constraints.
//
// Scope is deliberately narrow:
//   * Predict (Verlet) → N iterations of (anchor pin, distance, bending)
//     → velocity reconstruction.
//   * No collision, no wall contact, no `tunnel_state` integration, no
//     `muscular_curl_delta` (5G), no per-tick anchor refresh through
//     `centerline_source` for moving host bones (5F.B).
//
// Reuses no machinery from `PBDSolver` — that solver is tentacle-shaped
// (girth, attachment surface, collision, friction). Re-implementing the
// small primitives inline keeps this dependency-free and matches the
// canal's much simpler constraint surface. If a future slice ever needs
// a shared base, the refactor lives there, not here.
//
// Public surface is bound for GDScript (`Canal` node owns the instance
// via `ClassDB.instantiate("CanalCenterlineSolver")`). Snapshot
// accessors return by copy per the §15 architecture rule.
class CanalCenterlineSolver : public godot::RefCounted {
	GDCLASS(CanalCenterlineSolver, godot::RefCounted)

public:
	CanalCenterlineSolver();
	~CanalCenterlineSolver();

	// Authoring — called from GDScript at bake completion. Initialises
	// positions + prev_positions to the rest pose, derives segment lengths
	// from adjacent point distances. Pinned endpoints are determined from
	// `inv_mass_per_particle` (0.0 → pinned). If `inv_mass_per_particle`
	// is shorter than `rest_positions_world`, the missing entries default
	// to 1.0 (movable).
	void configure(const godot::PackedVector3Array &p_rest_positions_world,
			const godot::PackedFloat32Array &p_inv_mass_per_particle);

	// Per-tick anchor positions. Stored verbatim; applied as a hard pin
	// at the start of each constraint iteration (positions[0] = proximal,
	// positions[M-1] = distal). Does nothing if M < 2.
	void set_anchors(const godot::Vector3 &p_proximal_world,
			const godot::Vector3 &p_distal_world);

	// Solver tunables. Clamped to safe ranges.
	void set_iterations(int p_n);
	void set_bending_stiffness(float p_k);
	void set_damping(float p_d);
	void set_gravity_scale(float p_g);
	void set_gravity_vector(const godot::Vector3 &p_g);

	// Per-tick driver. dt expected in [0, 0.1] s; values outside are
	// passed through but clamped values protect from div-by-zero
	// in the velocity reconstruction.
	void tick(float p_dt);

	// Snapshot accessors (by-copy, §15 architecture rule).
	godot::PackedVector3Array get_positions_snapshot() const;
	godot::PackedVector3Array get_prev_positions_snapshot() const;
	int get_particle_count() const;

	// Test-only setter for kink-recovery test (test 4). Pins or unpins
	// a particle without restructuring inv_mass. Out-of-range index is a
	// no-op so test errors surface as failing assertions, not crashes.
	void set_particle_position(int p_index, const godot::Vector3 &p_pos);

	// 5F.B.B per-arc-length evaluators — consumed by `TunnelStateIntegrator`.
	// All four methods operate on the CURRENT (deformed) particle positions,
	// not the rest pose. `s` is clamped to [0, total_arc].
	//
	// `total_arc` is computed lazily once per call from current segment
	// lengths; deformation under XPBD distance constraints keeps each segment
	// within a few percent of `rest_segment_lengths[i]`, but the deformed sum
	// is correct rather than approximate.
	//
	// `evaluate_at(s)` is Catmull-Rom-like piecewise linear interp between the
	// two particles bracketing `s`. Linear (not cubic) because the rim XPBD
	// + bending constraints already smooth the chain — over-fitting a cubic
	// adds wiggle without changing physical fidelity.
	//
	// `basis_at(s)` returns columns (tangent, normal, binormal). The normal
	// is parallel-transported from the first segment so the binormal
	// rotates smoothly along the chain. Outward at angle θ in the rest
	// convention = `cos(θ) × normal + sin(θ) × binormal`.
	//
	// `curvature_at(s)` returns `|d²r/ds²|` from a 3-point neighbour finite
	// difference. `bend_axis_at(s)` returns the unit vector pointing from
	// the middle particle toward the midpoint of its neighbours.
	godot::Vector3 evaluate_at(float p_s) const;
	godot::Basis basis_at(float p_s) const;
	float curvature_at(float p_s) const;
	godot::Vector3 bend_axis_at(float p_s) const;
	float get_total_arc_length() const;

protected:
	static void _bind_methods();

private:
	// Per-particle state.
	std::vector<godot::Vector3> positions;
	std::vector<godot::Vector3> prev_positions;
	std::vector<float> inv_mass;
	std::vector<float> rest_segment_lengths; // size M-1

	// Anchors (pinned each iteration regardless of inv_mass — solver
	// guarantees these win the integrator even if external code clears
	// inv_mass on the endpoints).
	godot::Vector3 proximal_anchor = godot::Vector3(0.0f, 0.0f, 0.0f);
	godot::Vector3 distal_anchor = godot::Vector3(0.0f, 0.0f, 0.0f);

	// Tunables.
	int iterations = 8;
	float bending_stiffness = 0.5f;
	float damping = 0.05f;
	float gravity_scale = 0.0f;
	godot::Vector3 gravity_vector = godot::Vector3(0.0f, -9.81f, 0.0f);
};

#endif // TENTACLETECH_CANAL_CENTERLINE_SOLVER_H
