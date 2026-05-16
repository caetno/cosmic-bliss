#ifndef TENTACLETECH_CANAL_REACTION_PASS_H
#define TENTACLETECH_CANAL_REACTION_PASS_H

#include "canal/canal_centerline_solver.h"
#include "canal/tunnel_state_integrator.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <vector>

// Slice §6.12.12 — Canal-interior reaction pass.
//
// Closes the third-law loop on canal-interior walls: tentacle pressure
// drives `TunnelStateIntegrator` wall displacement; this pass reads that
// displacement per cross-section, sums to a per-cross-section wall
// reaction, routes each cross-section's reaction to its CP bone's
// rigid-parent host bone, and dispatches one `body_apply_impulse` per
// contributing host bone at the load-weighted centroid of its
// contributing cross-sections.
//
// Composition:
//   * Reads `TunnelStateIntegrator::get_wall_displacement_snapshot()` —
//     per-cell `dynamic - rest`, indexed `k * sectors + j`.
//   * Reads `CanalCenterlineSolver::evaluate_at(s)` for the cross-
//     section's world position + `basis_at(s)` for `rest_outward_normal`
//     at angular sector j.
//   * Excludes the first `n_rim_exclusion` cross-sections (default 1)
//     to avoid double-counting with §6.3 rim closure.
//   * Skips cross-sections whose host-bone RID is empty (degenerate
//     authoring) without dispatching anything for them.
//
// Snapshots returned by-copy per the §15 architecture rule.
class CanalReactionPass : public godot::RefCounted {
	GDCLASS(CanalReactionPass, godot::RefCounted)

public:
	CanalReactionPass();
	~CanalReactionPass();

	// Authoring — called once at bake completion. `host_bone_rids` is
	// an Array of RID, sized `axial_segments`. Empty RIDs mark cross-
	// sections that have no resolvable PhysicalBone3D and are silently
	// skipped at tick time.
	void configure(int p_axial_segments, int p_angular_sectors,
			const godot::PackedFloat32Array &p_rest_radius_per_cell,
			const godot::Array &p_host_bone_rids,
			float p_wall_response_stiffness,
			int p_n_rim_exclusion);

	void set_centerline_solver(const godot::Ref<CanalCenterlineSolver> &p_solver);
	void set_tunnel_state_integrator(const godot::Ref<TunnelStateIntegrator> &p_integrator);
	void set_wall_response_stiffness(float p_k);
	void set_n_rim_exclusion(int p_n);

	// Per-tick driver. Reads wall displacement, sums per-cross-section
	// reaction, dispatches impulses via PhysicsServer3D. Returns the
	// number of bones that received an impulse this tick. dt clamped to
	// (0, 1] internally; dt <= 0 returns 0.
	int tick(float p_dt);

	// Snapshots (by-copy, §15). All sized to be useful for tests + gizmo.
	// `get_last_reaction_per_section_snapshot()` is sized `axial_segments`;
	// excluded sections + zero-reaction sections store Vector3(0).
	// `get_last_bone_impulse_snapshot()` + `get_last_application_points_snapshot()`
	// are sized to the number of unique bones that received an impulse
	// this tick and run in matching order.
	godot::PackedVector3Array get_last_reaction_per_section_snapshot() const;
	godot::PackedVector3Array get_last_bone_impulse_snapshot() const;
	godot::PackedVector3Array get_last_application_points_snapshot() const;

protected:
	static void _bind_methods();

private:
	int axial_segments = 0;
	int angular_sectors = 0;
	float wall_response_stiffness = 100.0f;
	int n_rim_exclusion = 1;

	std::vector<float> rest_radius;
	std::vector<godot::RID> host_bone_rids;

	godot::Ref<CanalCenterlineSolver> centerline_solver;
	godot::Ref<TunnelStateIntegrator> tunnel_state_integrator;

	// Per-tick snapshots (debug + tests).
	std::vector<godot::Vector3> last_reaction_per_section;
	std::vector<godot::Vector3> last_bone_impulses;
	std::vector<godot::Vector3> last_application_points;
};

#endif // TENTACLETECH_CANAL_REACTION_PASS_H
