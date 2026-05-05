#include "orifice.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/physics_server3d.hpp>
#include <godot_cpp/classes/scene_tree.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/classes/window.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include "../solver/tentacle.h"

using namespace godot;

namespace {

// Slice 4M-XPBD log-mapping reused for the rim's spring-back constraint.
// stiffness=1 → very low compliance (~1e-9, near-rigid spring); stiffness=0
// → 1e-3 (very soft). Same curve as PBDSolver's `stiffness_to_compliance`
// to keep authoring intuition consistent across the chain and the rim.
inline float stiffness_to_compliance(float s) {
	if (s < 0.0f) s = 0.0f;
	if (s > 1.0f) s = 1.0f;
	float log_compliance = -9.0f + 6.0f * (1.0f - s);
	return Math::pow(10.0f, log_compliance);
}

// Pick a unit normal for the loop's "perpendicular plane". The volume
// constraint computes the polygon's signed area projected onto this plane.
// Caller passes the orifice entry_axis; we normalize and fall back to +Z
// if the user left it zero.
inline Vector3 normalize_or_z(const Vector3 &p_axis) {
	float l2 = p_axis.length_squared();
	if (l2 < 1e-10f) {
		return Vector3(0.0f, 0.0f, 1.0f);
	}
	return p_axis / Math::sqrt(l2);
}

// Signed polygon area in 3D, projected onto the plane with normal n_hat.
// A = 0.5 × Σ (p_k × p_{k+1}) · n_hat. The two cross-product terms with
// the centroid cancel in a closed loop, so we don't need to subtract the
// centroid first — but we project onto the n_hat plane implicitly because
// only the n_hat-aligned component of the cross matters.
inline float signed_polygon_area(
		const RimLoopState &loop, const Vector3 &n_hat) {
	int n = (int)loop.rim_particles.size();
	if (n < 3) return 0.0f;
	double a = 0.0;
	for (int k = 0; k < n; k++) {
		const Vector3 &p_k = loop.rim_particles[k].position;
		const Vector3 &p_n = loop.rim_particles[(k + 1) % n].position;
		Vector3 c = p_k.cross(p_n);
		a += c.dot(n_hat);
	}
	return 0.5f * (float)a;
}

// Same formula but on a PackedVector3Array (used by the static helper
// `compute_polygon_area`). Centroid term cancels out for a closed loop.
inline float signed_polygon_area_packed(
		const PackedVector3Array &p_positions, const Vector3 &n_hat) {
	int n = p_positions.size();
	if (n < 3) return 0.0f;
	const Vector3 *pp = p_positions.ptr();
	double a = 0.0;
	for (int k = 0; k < n; k++) {
		const Vector3 &p_k = pp[k];
		const Vector3 &p_n = pp[(k + 1) % n];
		a += p_k.cross(p_n).dot(n_hat);
	}
	return 0.5f * (float)a;
}

} // namespace

Orifice::Orifice() {}
Orifice::~Orifice() {}

void Orifice::_ready() {
	if (Engine::get_singleton()->is_editor_hint()) {
		set_physics_process(false);
		return;
	}
	set_physics_process(true);
}

void Orifice::_physics_process(double p_delta) {
	if (Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	tick((float)p_delta);
}

// -- Tick driver -----------------------------------------------------------

void Orifice::tick(float p_dt) {
	if (p_dt < 1e-4f) return;
	if (p_dt > 1.0f / 40.0f) p_dt = 1.0f / 40.0f;

	// Slice 5B — refresh the Center frame from the host bone ONCE per
	// tick before any per-loop work runs. Reading bone transforms inside
	// the iterate loop would force a skeleton recompute per call (same
	// gotcha as §4.5's once-per-tick ragdoll snapshot). The resolver +
	// `_center_frame_cached` cover both paths: bone-driven when the host
	// bone is active, else the orifice node's own `global_transform`
	// (or identity if not in tree). `get_center_frame_world()` reads
	// from the cache, so subsequent rim-particle rest-world projections
	// don't re-resolve.
	_resolve_host_bone_lazy();
	_refresh_center_frame_cache();

	// Slice 5C-A — predict per loop first so all rim particles have
	// post-Verlet positions before the cross-loop contact pass collects
	// pairs. Then run iter_count passes interleaving per-loop constraints
	// with the type-2 contact pass; finalize at the end.
	for (size_t li = 0; li < rim_loops.size(); li++) {
		RimLoopState &loop = rim_loops[li];
		if ((int)loop.rim_particles.size() < 3) continue;
		_predict_loop(loop, p_dt);
	}

	// Slice 5C-B — refresh EntryInteraction lifecycle BEFORE contact
	// collection so 5C-C / later slices can gate contact handling by EI
	// presence. In 5C-B itself contact collection still walks every
	// registered tentacle; the EI list is consumed by the snapshot
	// accessor + gizmo only.
	_resolve_tentacles_lazy();
	_update_entry_interactions(p_dt);

	_collect_type2_contacts();

	for (int iter = 0; iter < iteration_count; iter++) {
		for (size_t li = 0; li < rim_loops.size(); li++) {
			RimLoopState &loop = rim_loops[li];
			if ((int)loop.rim_particles.size() < 3) continue;
			_iterate_loop_one_pass(loop, p_dt);
		}
		_iterate_type2_contacts(p_dt);
		// Slice 5C-C — friction projection runs AFTER the normal-contact
		// step in the same iter pass. Cone size scales with the
		// just-updated `normal_lambda`, so the friction step never
		// over-cancels in a free-falling iter. Same Jacobi+SOR
		// flush at the end (rim deltas + tentacle deltas).
		_iterate_type2_friction(p_dt);
	}

	// Slice 5C-C — populate EI per-loop_k arrays (radial pressure +
	// tangential friction) from the settled contact lambdas, ramp
	// grip_engagement / accumulate damage / flip in_stick_phase, then
	// apply the §6.3 reaction-on-host-bone closure. All three steps
	// run after the iter loop so they read post-converged contact
	// state.
	_populate_entry_interaction_pressures(p_dt);
	_apply_reaction_on_host_bone(p_dt);

	for (size_t li = 0; li < rim_loops.size(); li++) {
		RimLoopState &loop = rim_loops[li];
		if ((int)loop.rim_particles.size() < 3) continue;
		_finalize_loop(loop, p_dt);
	}
}

// -- Per-loop stages -------------------------------------------------------

void Orifice::_predict_loop(RimLoopState &loop, float p_dt) {
	float dt2 = p_dt * p_dt;
	int n = (int)loop.rim_particles.size();

	// XPBD lambda accumulators reset per tick — same canary discipline
	// as PBDSolver::predict (slice 4M-XPBD). Forgetting these resets is
	// a divergence cliff; tests in test_orifice.gd verify the reset is
	// wired by removing it and asserting the lambdas blow up.
	loop.area_lambda = 0.0f;
	for (int i = 0; i < n; i++) {
		loop.rim_particles[i].distance_lambda_to_next = 0.0f;
		loop.rim_particles[i].spring_lambda = 0.0f;
	}

	for (int i = 0; i < n; i++) {
		RimParticle &p = loop.rim_particles[i];
		if (p.inv_mass <= 0.0f) {
			p.prev_position = p.position;
			continue;
		}
		Vector3 temp_prev = p.prev_position;
		p.prev_position = p.position;
		Vector3 velocity = (p.position - temp_prev) * damping;
		p.position += velocity + gravity * dt2;
	}
}

void Orifice::_iterate_loop_one_pass(RimLoopState &loop, float p_dt) {
	// Slice 5C-A — extracted from the previous iter-count-internal
	// `_iterate_loop` so the outer `tick()` can interleave per-loop
	// constraint passes with the cross-loop type-2 contact pass. Each
	// call runs ONE iteration's worth of distance + volume + spring-back
	// for this loop. Apply pass is per-step (Jacobi), so multiple
	// constraints touching the same particle compose by SOR average.
	int n = (int)loop.rim_particles.size();
	if (n < 3) return;

	const float dt2_inv = 1.0f / (p_dt * p_dt + 1e-20f);
	const Vector3 n_hat = normalize_or_z(entry_axis);

	const float compliance_distance = loop.distance_compliance * dt2_inv;
	// Slice 5D §4P-A — separate compliance for the stretch branch when
	// `distance_anisotropic` is true. With default ratio 1e-6 vs 1e-3
	// (~1000×), the rim is near-rigid in compression and visibly
	// compliant in stretch. When the flag is false (jewelry / rigid
	// rim), this value is unused and the step falls back to the
	// symmetric 5A behaviour.
	const float compliance_distance_stretch = loop.distance_stretch_compliance * dt2_inv;
	const float compliance_area = loop.area_compliance * dt2_inv;

	// Slice 5B — Center frame is bone-driven when host bone is active,
	// else falls back to the orifice node's own transform (which itself
	// falls back to identity in `--script` mode where `is_inside_tree`
	// returns false even after `add_child`). Either way `get_center_
	// frame_world()` returns the right thing for the rim's rest-world
	// projection — no warnings, no special-casing in callers.
	const Transform3D xform = get_center_frame_world();

	// 1. Closed-loop XPBD distance constraints around the rim.
	// Per-segment lambda accumulates across iters (canonical XPBD
	// per Obi `DistanceConstraints.compute`); reset in predict()
	// each tick. lambda lives on rim_particles[k] as
	// `distance_lambda_to_next` for the segment (k, k+1).
	for (int k = 0; k < n; k++) {
		int k1 = (k + 1) % n;
		RimParticle &p_a = loop.rim_particles[k];
		RimParticle &p_b = loop.rim_particles[k1];
		float w_sum = p_a.inv_mass + p_b.inv_mass;
		if (w_sum <= 0.0f) continue;
		Vector3 d = p_a.position - p_b.position;
		float dist = d.length();
		if (dist < 1e-8f) continue;
		float rest_len = loop.rim_segment_rest_lengths[k];
		float constraint = dist - rest_len;
		float &lambda = p_a.distance_lambda_to_next;
		// Slice 5D §4P-A — anisotropic compliance: stiff in compression
		// (constraint < 0), compliant in stretch (constraint > 0).
		// Falls back to the symmetric `distance_compliance` when the
		// flag is off (jewelry / rigid rim).
		float compliance_eff = compliance_distance;
		if (loop.distance_anisotropic && constraint > 0.0f) {
			compliance_eff = compliance_distance_stretch;
		}
		float dlambda = (-constraint - compliance_eff * lambda) /
				(w_sum + compliance_eff + 1e-8f);
		lambda += dlambda;
		Vector3 delta = (d / dist) * dlambda;
		if (p_a.inv_mass > 0.0f) {
			_add_delta(loop, k, delta * p_a.inv_mass);
		}
		if (p_b.inv_mass > 0.0f) {
			_add_delta(loop, k1, -delta * p_b.inv_mass);
		}
	}
	_apply_deltas_all(loop);

	// 2. XPBD volume (signed polygon area) constraint, projected
	// onto the plane perpendicular to entry_axis. Adapted from Obi
	// `VolumeConstraints.compute`: the 3D triangle-fan-from-origin
	// volume gradient `cross(p_b, p_c)` reduces in 2D to
	// `0.5 × n_hat × (p_{k-1} - p_{k+1})` for the planar shoelace
	// area. One scalar lambda per loop; per-particle position
	// deltas distributed by the gradient at each rim particle.
	double sum_w_grad2 = 0.0;
	std::vector<Vector3> gradients(n, Vector3());
	for (int k = 0; k < n; k++) {
		RimParticle &p_k = loop.rim_particles[k];
		if (p_k.inv_mass <= 0.0f) continue;
		const Vector3 &p_prev = loop.rim_particles[(k + n - 1) % n].position;
		const Vector3 &p_next = loop.rim_particles[(k + 1) % n].position;
		Vector3 g = n_hat.cross(p_prev - p_next) * 0.5f;
		gradients[k] = g;
		sum_w_grad2 += (double)p_k.inv_mass * (double)g.length_squared();
	}
	float current_area = signed_polygon_area(loop, n_hat);
	float area_constraint = current_area - loop.target_enclosed_area;
	float denom = (float)sum_w_grad2 + compliance_area + 1e-12f;
	float dlambda_area =
			(-area_constraint - compliance_area * loop.area_lambda) / denom;
	loop.area_lambda += dlambda_area;
	for (int k = 0; k < n; k++) {
		RimParticle &p_k = loop.rim_particles[k];
		if (p_k.inv_mass <= 0.0f) continue;
		Vector3 delta = gradients[k] * (dlambda_area * p_k.inv_mass);
		_add_delta(loop, k, delta);
	}
	_apply_deltas_all(loop);

	// 3. Per-particle XPBD spring-back to authored rest position
	// in Center frame. Bilateral compliance is the per-particle
	// stiffness distribution (front-vs-back, etc.). Scalar
	// distance constraint with target distance = 0; degenerate at
	// dist→0 (already at rest) so we early-out there.
	//
	// Slice 5D §4P-C — `rest = neutral + plastic_offset`; offset is
	// updated in `_finalize_loop` after the iter loop, so within iter
	// it's read-only here.
	// Slice 5D §4P-B — strain-stiffening J-curve: effective compliance
	// shrinks as displacement magnitude grows past
	// `j_curve_characteristic_length`. alpha=beta=0 → linear regime
	// (5A baseline).
	const float j_alpha = loop.j_curve_alpha;
	const float j_beta = loop.j_curve_beta;
	const float j_char_len_inv = (loop.j_curve_characteristic_length > 1e-6f)
			? (1.0f / loop.j_curve_characteristic_length)
			: 0.0f;
	for (int k = 0; k < n; k++) {
		RimParticle &p_k = loop.rim_particles[k];
		if (p_k.inv_mass <= 0.0f) continue;
		Vector3 rest_local = p_k.neutral_rest_position_in_center_frame + p_k.plastic_offset;
		Vector3 rest_world = xform.xform(rest_local);
		Vector3 d = p_k.position - rest_world;
		float dist = d.length();
		if (dist < 1e-8f) continue;
		float base_compliance = stiffness_to_compliance(
				loop.rim_particle_rest_stiffness_per_k[k]);
		float strain = dist * j_char_len_inv;
		float strain_sq = strain * strain;
		float strain_quad = strain_sq * strain_sq;
		float j_factor = 1.0f + j_alpha * strain_sq + j_beta * strain_quad;
		// j_factor ≥ 1, so effective compliance ≤ base. With alpha=0
		// + beta=0 (default), j_factor = 1.0 → unchanged.
		float compliance_spring = (base_compliance / j_factor) * dt2_inv;
		float &lambda = p_k.spring_lambda;
		float dlambda = (-dist - compliance_spring * lambda) /
				(p_k.inv_mass + compliance_spring + 1e-8f);
		lambda += dlambda;
		Vector3 delta = (d / dist) * (dlambda * p_k.inv_mass);
		_add_delta(loop, k, delta);
	}
	_apply_deltas_all(loop);
}

void Orifice::_finalize_loop(RimLoopState &loop, float p_dt) {
	// Slice 5D §4P-C — orifice memory. Per particle, lerp `plastic_offset`
	// toward the current Center-frame displacement at `accumulate_rate`,
	// then decay it toward zero at `recover_rate`, then clamp to
	// `plastic_max_offset`. The two rates compete: writes vs decay.
	// Defaults are equal (memory-neutral): no net drift on a stationary
	// orifice; visible memory only when load is sustained for seconds.
	int n = (int)loop.rim_particles.size();
	if (n < 1) return;
	if (loop.plastic_accumulate_rate <= 0.0f && loop.plastic_recover_rate <= 0.0f) {
		// Both rates disabled — preserve `plastic_offset` as-is (allows
		// authoring scripts to drive offsets manually if needed).
		return;
	}
	const Transform3D xform = get_center_frame_world();
	const Transform3D xform_inv = xform.affine_inverse();
	const float acc_lerp = Math::clamp(loop.plastic_accumulate_rate * p_dt, 0.0f, 1.0f);
	const float decay = 1.0f - Math::clamp(loop.plastic_recover_rate * p_dt, 0.0f, 1.0f);
	const float max_off = loop.plastic_max_offset;
	const float max_off_sq = max_off * max_off;
	for (int k = 0; k < n; k++) {
		RimParticle &p = loop.rim_particles[k];
		Vector3 pos_local = xform_inv.xform(p.position);
		Vector3 current_off = pos_local - p.neutral_rest_position_in_center_frame;
		// Step 1 — lerp plastic_offset toward current displacement.
		p.plastic_offset = p.plastic_offset.lerp(current_off, acc_lerp);
		// Step 2 — decay toward zero (concurrent recovery; the two
		// rates compete to determine net memory).
		p.plastic_offset *= decay;
		// Step 3 — magnitude clamp.
		float len_sq = p.plastic_offset.length_squared();
		if (len_sq > max_off_sq && max_off > 0.0f) {
			float scale = max_off / Math::sqrt(len_sq);
			p.plastic_offset *= scale;
		}
		// Refresh the cached rest_position_in_center_frame for snapshot
		// consumers (gizmo, spring-back step on the NEXT tick reads
		// `neutral + plastic_offset` directly so this assignment is
		// for surface-area / debug introspection only).
		p.rest_position_in_center_frame = p.neutral_rest_position_in_center_frame + p.plastic_offset;
	}
}

// -- Configuration ---------------------------------------------------------

void Orifice::set_iteration_count(int p_iter) {
	if (p_iter < 1) p_iter = 1;
	if (p_iter > MAX_ITERATION_COUNT) p_iter = MAX_ITERATION_COUNT;
	iteration_count = p_iter;
}
int Orifice::get_iteration_count() const { return iteration_count; }
void Orifice::set_sor_factor(float p_factor) { sor_factor = p_factor; }
float Orifice::get_sor_factor() const { return sor_factor; }
void Orifice::set_damping(float p_damping) { damping = p_damping; }
float Orifice::get_damping() const { return damping; }
void Orifice::set_gravity(const Vector3 &p_gravity) { gravity = p_gravity; }
Vector3 Orifice::get_gravity() const { return gravity; }
void Orifice::set_entry_axis(const Vector3 &p_axis) { entry_axis = p_axis; }
Vector3 Orifice::get_entry_axis() const { return entry_axis; }

// -- Host bone (slice 5B) --------------------------------------------------

void Orifice::set_skeleton_path(const NodePath &p_path) {
	if (skeleton_path == p_path) return;
	skeleton_path = p_path;
	_host_bone_dirty = true;
}

NodePath Orifice::get_skeleton_path() const { return skeleton_path; }

void Orifice::set_bone_name(const StringName &p_name) {
	if (bone_name == p_name) return;
	bone_name = p_name;
	_host_bone_dirty = true;
}

StringName Orifice::get_bone_name() const { return bone_name; }

void Orifice::set_host_bone_offset(const Transform3D &p_offset) {
	host_bone_offset = p_offset;
}

Transform3D Orifice::get_host_bone_offset() const { return host_bone_offset; }

bool Orifice::set_host_bone(const NodePath &p_skeleton_path, const StringName &p_bone_name) {
	skeleton_path = p_skeleton_path;
	bone_name = p_bone_name;
	_host_bone_dirty = true;
	_resolve_host_bone_lazy();
	_refresh_center_frame_cache();
	return _host_bone_active;
}

void Orifice::_resolve_host_bone_lazy() const {
	// The dirty flag is a "config might have changed" hint; we ALSO
	// re-validate the cached skeleton pointer against the current tree
	// state on every call so a freed Skeleton3D doesn't dangle. NodePath
	// resolution + find_bone are both fast (a few hundred ns) so the
	// once-per-tick cost is negligible.
	if (skeleton_path.is_empty() || bone_name == StringName()) {
		_skeleton_cached = nullptr;
		_bone_index_cached = -1;
		_host_bone_active = false;
		_host_bone_dirty = false;
		return;
	}
	// `--script` SceneTrees can report `is_inside_tree() == false` even
	// after `add_child`. Both `Node::get_node_or_null` and `get_path_to`
	// fail in that state (Godot guards them behind `data.tree != nullptr`
	// or "active scene tree"). Try `get_node_or_null` first (covers normal
	// runtime use), then fall back to a manual recursive walk from the
	// SceneTree root that doesn't depend on the caller node being marked
	// in-tree (covers `--script` headless tests).
	Node *node = nullptr;
	if (is_inside_tree()) {
		node = get_node_or_null(skeleton_path);
	}
	if (node == nullptr) {
		SceneTree *tree = get_tree();
		Window *root = (tree != nullptr) ? tree->get_root() : nullptr;
		if (root != nullptr) {
			// `skeleton_path` is typically `/root/Foo/Bar` (absolute) or
			// `Foo/Bar` (relative-to-root). Strip a leading "/root/"
			// prefix if present, then walk children by name.
			String path_str = String(skeleton_path);
			const String root_prefix = "/root/";
			if (path_str.begins_with(root_prefix)) {
				path_str = path_str.substr(root_prefix.length());
			}
			Node *cursor = root;
			PackedStringArray segments = path_str.split("/", false);
			for (int i = 0; i < segments.size() && cursor != nullptr; i++) {
				const String &seg = segments[i];
				Node *next = nullptr;
				int child_count = cursor->get_child_count();
				for (int c = 0; c < child_count; c++) {
					Node *child = cursor->get_child(c);
					if (child != nullptr && String(child->get_name()) == seg) {
						next = child;
						break;
					}
				}
				cursor = next;
			}
			node = cursor;
		}
	}
	Skeleton3D *skel = Object::cast_to<Skeleton3D>(node);
	if (skel == nullptr) {
		_skeleton_cached = nullptr;
		_bone_index_cached = -1;
		_host_bone_active = false;
		_host_bone_dirty = false;
		return;
	}
	// Re-look-up the bone if the skeleton pointer changed OR we were
	// dirty (config changed) OR the cached index is now out of range
	// (skeleton bone list mutated).
	if (_host_bone_dirty || skel != _skeleton_cached || _bone_index_cached < 0 ||
			_bone_index_cached >= skel->get_bone_count()) {
		int idx = skel->find_bone(bone_name);
		_skeleton_cached = skel;
		_bone_index_cached = idx;
		_host_bone_active = (idx >= 0);
		_host_bone_dirty = false;
		return;
	}
	_skeleton_cached = skel;
	_host_bone_active = true;
}

void Orifice::_refresh_center_frame_cache() {
	// Already-resolved? Just compose. Resolver is cheap; we leave the
	// call to `tick()`'s caller so this helper is purely "compose the
	// final frame from current resolver output".
	if (_host_bone_active) {
		_center_frame_cached = _read_host_bone_world_transform() * host_bone_offset;
		return;
	}
	// No host bone — fall back to the orifice node's own transform.
	// When in tree we use the global transform (correct under any
	// nesting). In `--script` mode the SceneTree often reports
	// `is_inside_tree() == false` even after `add_child`, so we use
	// the node's local transform instead — equivalent to the global
	// one when the orifice is parented directly under the SceneTree
	// root, which is the headless-test layout.
	if (is_inside_tree()) {
		_center_frame_cached = get_global_transform();
	} else {
		_center_frame_cached = get_transform();
	}
}

Transform3D Orifice::get_center_frame_world() const {
	// Returns the cache populated by the most recent `tick()` /
	// `add_rim_loop` / `set_host_bone`. Callers that need a fresh
	// frame after authoring changes (skeleton path, bone name, offset)
	// without ticking should call `tick(0)` — actually the dt floor
	// rejects that, so use a small dt. In practice only tests hit this
	// edge case, and they always tick at least once before reading.
	return _center_frame_cached;
}

Transform3D Orifice::_read_host_bone_world_transform() const {
	if (!_host_bone_active || _skeleton_cached == nullptr || _bone_index_cached < 0) {
		return Transform3D();
	}
	return _skeleton_cached->get_global_transform() *
			_skeleton_cached->get_bone_global_pose(_bone_index_cached);
}

Dictionary Orifice::get_host_bone_state() const {
	_resolve_host_bone_lazy();
	Dictionary d;
	d["has_host_bone"] = _host_bone_active;
	d["skeleton_path"] = skeleton_path;
	d["bone_name"] = bone_name;
	d["bone_index"] = _bone_index_cached;
	d["current_world_transform"] = _read_host_bone_world_transform();
	return d;
}

// -- Authoring API ---------------------------------------------------------

int Orifice::add_rim_loop(
		const PackedVector3Array &p_rest_positions_in_center_frame,
		const PackedFloat32Array &p_segment_rest_lengths,
		float p_target_enclosed_area,
		const PackedFloat32Array &p_rest_stiffness_per_k,
		float p_area_compliance,
		float p_distance_compliance,
		float p_default_contact_radius) {
	int n = p_rest_positions_in_center_frame.size();
	if (n < 3) return -1;
	if (p_segment_rest_lengths.size() != n) return -1;
	if (p_rest_stiffness_per_k.size() != n) return -1;

	float contact_radius = p_default_contact_radius > 0.0f
			? p_default_contact_radius
			: 0.02f;

	RimLoopState loop;
	loop.particle_count = n;
	loop.rim_particles.assign((size_t)n, RimParticle());
	loop.rim_segment_rest_lengths.assign((size_t)n, 0.0f);
	loop.rim_particle_rest_stiffness_per_k.assign((size_t)n, 0.0f);
	loop.rim_contact_radius_per_k.assign((size_t)n, contact_radius);
	loop.target_enclosed_area = p_target_enclosed_area;
	loop.area_compliance = p_area_compliance;
	loop.distance_compliance = p_distance_compliance;
	loop.area_lambda = 0.0f;
	loop.position_delta_scratch.assign((size_t)n, Vector3());
	loop.position_delta_count.assign((size_t)n, 0);

	const Vector3 *rp = p_rest_positions_in_center_frame.ptr();
	const float *segs = p_segment_rest_lengths.ptr();
	const float *stf = p_rest_stiffness_per_k.ptr();
	// Slice 5B — Center frame is bone-driven when host bone is active,
	// else falls back to the orifice node's own transform (which itself
	// falls back to identity in `--script` mode where `is_inside_tree`
	// returns false even after `add_child`). Refresh the cache before
	// reading so authoring before the first tick still picks up the
	// host bone configured via `set_host_bone`.
	_resolve_host_bone_lazy();
	_refresh_center_frame_cache();
	const Transform3D xform = get_center_frame_world();
	for (int k = 0; k < n; k++) {
		// Slice 5D §4P-C — `neutral` is the immutable authored anchor;
		// `rest_position` starts identical (plastic_offset = 0) and
		// drifts at runtime under `_finalize_loop`'s plastic update.
		loop.rim_particles[k].neutral_rest_position_in_center_frame = rp[k];
		loop.rim_particles[k].rest_position_in_center_frame = rp[k];
		loop.rim_particles[k].plastic_offset = Vector3();
		Vector3 world = xform.xform(rp[k]);
		loop.rim_particles[k].position = world;
		loop.rim_particles[k].prev_position = world;
		loop.rim_particles[k].inv_mass = 1.0f;
		loop.rim_particles[k].distance_lambda_to_next = 0.0f;
		loop.rim_particles[k].spring_lambda = 0.0f;
		loop.rim_segment_rest_lengths[k] = segs[k];
		loop.rim_particle_rest_stiffness_per_k[k] = stf[k];
	}

	rim_loops.push_back(std::move(loop));
	return (int)rim_loops.size() - 1;
}

void Orifice::clear_rim_loops() { rim_loops.clear(); }

// -- Static helpers --------------------------------------------------------

PackedVector3Array Orifice::make_circular_rest_positions(
		int p_n, float p_radius, const Vector3 &p_entry_axis) {
	PackedVector3Array out;
	if (p_n < 3 || p_radius <= 0.0f) {
		return out;
	}
	Vector3 n_hat = normalize_or_z(p_entry_axis);
	// Construct an orthonormal basis (u, v, n_hat) using a stable
	// cross-product fallback. u is then "rim X axis", v is "rim Y axis"
	// in the plane perpendicular to n_hat.
	Vector3 ref(1.0f, 0.0f, 0.0f);
	if (Math::abs(ref.dot(n_hat)) > 0.9f) {
		ref = Vector3(0.0f, 1.0f, 0.0f);
	}
	Vector3 u = ref - n_hat * ref.dot(n_hat);
	float u_len = u.length();
	if (u_len < 1e-6f) {
		return out;
	}
	u = u / u_len;
	Vector3 v = n_hat.cross(u);
	out.resize(p_n);
	Vector3 *dst = out.ptrw();
	for (int k = 0; k < p_n; k++) {
		float theta = (float)k * (Math_TAU / (float)p_n);
		float c = Math::cos(theta);
		float s = Math::sin(theta);
		dst[k] = u * (p_radius * c) + v * (p_radius * s);
	}
	return out;
}

PackedFloat32Array Orifice::make_uniform_segment_rest_lengths(
		const PackedVector3Array &p_rest_positions) {
	PackedFloat32Array out;
	int n = p_rest_positions.size();
	if (n < 3) return out;
	out.resize(n);
	const Vector3 *src = p_rest_positions.ptr();
	float *dst = out.ptrw();
	for (int k = 0; k < n; k++) {
		const Vector3 &p_k = src[k];
		const Vector3 &p_n1 = src[(k + 1) % n];
		dst[k] = (p_n1 - p_k).length();
	}
	return out;
}

float Orifice::compute_polygon_area(
		const PackedVector3Array &p_positions, const Vector3 &p_entry_axis) {
	Vector3 n_hat = normalize_or_z(p_entry_axis);
	return signed_polygon_area_packed(p_positions, n_hat);
}

// -- Snapshot accessors (§15.2) -------------------------------------------

int Orifice::get_rim_loop_count() const {
	return (int)rim_loops.size();
}

Array Orifice::get_rim_loop_state(int p_loop_index) const {
	Array out;
	if (p_loop_index < 0 || p_loop_index >= (int)rim_loops.size()) {
		return out;
	}
	const RimLoopState &loop = rim_loops[p_loop_index];
	int n = (int)loop.rim_particles.size();
	// Slice 5B — Center frame is bone-driven when host bone is active,
	// else falls back to the orifice node's own transform (which itself
	// falls back to identity in `--script` mode where `is_inside_tree`
	// returns false even after `add_child`). Either way `get_center_
	// frame_world()` returns the right thing for the rim's rest-world
	// projection — no warnings, no special-casing in callers.
	const Transform3D xform = get_center_frame_world();
	// Slice 5D — pre-computed J-curve scratch (per-loop, not per-
	// particle, so we hoist out of the inner loop).
	const float j_alpha = loop.j_curve_alpha;
	const float j_beta = loop.j_curve_beta;
	const float j_char_len_inv = (loop.j_curve_characteristic_length > 1e-6f)
			? (1.0f / loop.j_curve_characteristic_length)
			: 0.0f;
	for (int k = 0; k < n; k++) {
		const RimParticle &p = loop.rim_particles[k];
		Vector3 rest_local = p.neutral_rest_position_in_center_frame + p.plastic_offset;
		Vector3 rest_world = xform.xform(rest_local);
		Vector3 velocity = p.position - p.prev_position; // tick-rate Δ; caller divides by dt if desired
		// Slice 5D §4P-B / §4P-C — derived snapshot fields.
		Vector3 displacement = p.position - rest_world;
		float strain = displacement.length() * j_char_len_inv;
		float strain_sq = strain * strain;
		float j_factor = 1.0f + j_alpha * strain_sq + j_beta * strain_sq * strain_sq;
		float base_compliance = stiffness_to_compliance(
				loop.rim_particle_rest_stiffness_per_k[k]);
		float effective_compliance = base_compliance / j_factor;
		Dictionary d;
		d["rest_position"] = rest_world;
		d["current_position"] = p.position;
		d["current_velocity"] = velocity;
		d["spring_lambda"] = p.spring_lambda;
		d["distance_lambda"] = p.distance_lambda_to_next;
		d["neighbour_rest_distance"] = loop.rim_segment_rest_lengths[k];
		d["inv_mass"] = p.inv_mass;
		// Slice 5D §15.2 extensions.
		d["plastic_offset"] = p.plastic_offset;
		d["neutral_rest_position"] = xform.xform(p.neutral_rest_position_in_center_frame);
		d["current_strain"] = strain;
		d["effective_compliance"] = effective_compliance;
		d["distance_anisotropic_mode"] = loop.distance_anisotropic;
		out.push_back(d);
	}
	return out;
}

float Orifice::get_loop_area_lambda(int p_loop_index) const {
	if (p_loop_index < 0 || p_loop_index >= (int)rim_loops.size()) return 0.0f;
	return rim_loops[p_loop_index].area_lambda;
}

float Orifice::get_loop_target_enclosed_area(int p_loop_index) const {
	if (p_loop_index < 0 || p_loop_index >= (int)rim_loops.size()) return 0.0f;
	return rim_loops[p_loop_index].target_enclosed_area;
}

float Orifice::get_loop_current_enclosed_area(int p_loop_index) const {
	if (p_loop_index < 0 || p_loop_index >= (int)rim_loops.size()) return 0.0f;
	const RimLoopState &loop = rim_loops[p_loop_index];
	return signed_polygon_area(loop, normalize_or_z(entry_axis));
}

void Orifice::set_particle_position(
		int p_loop_index, int p_particle_index, const Vector3 &p_world_pos) {
	if (p_loop_index < 0 || p_loop_index >= (int)rim_loops.size()) return;
	RimLoopState &loop = rim_loops[p_loop_index];
	if (p_particle_index < 0 || p_particle_index >= (int)loop.rim_particles.size()) return;
	RimParticle &p = loop.rim_particles[p_particle_index];
	p.position = p_world_pos;
	p.prev_position = p_world_pos;
}

Vector3 Orifice::get_particle_position(int p_loop_index, int p_particle_index) const {
	if (p_loop_index < 0 || p_loop_index >= (int)rim_loops.size()) return Vector3();
	const RimLoopState &loop = rim_loops[p_loop_index];
	if (p_particle_index < 0 || p_particle_index >= (int)loop.rim_particles.size()) return Vector3();
	return loop.rim_particles[p_particle_index].position;
}

void Orifice::set_particle_inv_mass(
		int p_loop_index, int p_particle_index, float p_inv_mass) {
	if (p_loop_index < 0 || p_loop_index >= (int)rim_loops.size()) return;
	RimLoopState &loop = rim_loops[p_loop_index];
	if (p_particle_index < 0 || p_particle_index >= (int)loop.rim_particles.size()) return;
	loop.rim_particles[p_particle_index].inv_mass = p_inv_mass;
}

void Orifice::set_loop_target_enclosed_area(int p_loop_index, float p_target) {
	if (p_loop_index < 0 || p_loop_index >= (int)rim_loops.size()) return;
	rim_loops[p_loop_index].target_enclosed_area = p_target;
}

void Orifice::set_rim_contact_radius(int p_loop_index, int p_particle_index, float p_radius) {
	if (p_loop_index < 0 || p_loop_index >= (int)rim_loops.size()) return;
	RimLoopState &loop = rim_loops[p_loop_index];
	if (p_particle_index < 0 || p_particle_index >= (int)loop.rim_contact_radius_per_k.size()) return;
	loop.rim_contact_radius_per_k[p_particle_index] = p_radius < 0.0f ? 0.0f : p_radius;
}

float Orifice::get_rim_contact_radius(int p_loop_index, int p_particle_index) const {
	if (p_loop_index < 0 || p_loop_index >= (int)rim_loops.size()) return 0.0f;
	const RimLoopState &loop = rim_loops[p_loop_index];
	if (p_particle_index < 0 || p_particle_index >= (int)loop.rim_contact_radius_per_k.size()) return 0.0f;
	return loop.rim_contact_radius_per_k[p_particle_index];
}

// -- Slice 5D per-loop realism tunables -----------------------------------

#define ORIFICE_LOOP_GETSET(setter, getter, field, def_invalid)                  \
	void Orifice::setter(int p_loop_index, decltype(RimLoopState::field) p_v) {  \
		if (p_loop_index < 0 || p_loop_index >= (int)rim_loops.size()) return;   \
		rim_loops[p_loop_index].field = p_v;                                     \
	}                                                                             \
	decltype(RimLoopState::field) Orifice::getter(int p_loop_index) const {       \
		if (p_loop_index < 0 || p_loop_index >= (int)rim_loops.size()) return def_invalid; \
		return rim_loops[p_loop_index].field;                                    \
	}

// 4P-A
ORIFICE_LOOP_GETSET(set_loop_distance_anisotropic, get_loop_distance_anisotropic,
		distance_anisotropic, false)
ORIFICE_LOOP_GETSET(set_loop_distance_stretch_compliance, get_loop_distance_stretch_compliance,
		distance_stretch_compliance, 0.0f)

// 4P-B
ORIFICE_LOOP_GETSET(set_loop_j_curve_alpha, get_loop_j_curve_alpha,
		j_curve_alpha, 0.0f)
ORIFICE_LOOP_GETSET(set_loop_j_curve_beta, get_loop_j_curve_beta,
		j_curve_beta, 0.0f)
ORIFICE_LOOP_GETSET(set_loop_j_curve_characteristic_length, get_loop_j_curve_characteristic_length,
		j_curve_characteristic_length, 0.0f)

// 4P-C
ORIFICE_LOOP_GETSET(set_loop_plastic_accumulate_rate, get_loop_plastic_accumulate_rate,
		plastic_accumulate_rate, 0.0f)
ORIFICE_LOOP_GETSET(set_loop_plastic_recover_rate, get_loop_plastic_recover_rate,
		plastic_recover_rate, 0.0f)
ORIFICE_LOOP_GETSET(set_loop_plastic_max_offset, get_loop_plastic_max_offset,
		plastic_max_offset, 0.0f)

#undef ORIFICE_LOOP_GETSET

// -- Tentacle registration (slice 5C-A) ------------------------------------

void Orifice::set_tentacle_paths(const TypedArray<NodePath> &p_paths) {
	tentacle_paths = p_paths;
	_tentacles_dirty = true;
}

TypedArray<NodePath> Orifice::get_tentacle_paths() const { return tentacle_paths; }

bool Orifice::register_tentacle(const NodePath &p_path) {
	for (int i = 0; i < tentacle_paths.size(); i++) {
		if ((NodePath)tentacle_paths[i] == p_path) {
			return false; // already registered
		}
	}
	tentacle_paths.push_back(p_path);
	_tentacles_dirty = true;
	return true;
}

bool Orifice::unregister_tentacle(const NodePath &p_path) {
	for (int i = 0; i < tentacle_paths.size(); i++) {
		if ((NodePath)tentacle_paths[i] == p_path) {
			tentacle_paths.remove_at(i);
			_tentacles_dirty = true;
			return true;
		}
	}
	return false;
}

int Orifice::get_registered_tentacle_count() const {
	return tentacle_paths.size();
}

int Orifice::get_resolved_tentacle_count() const {
	_resolve_tentacles_lazy();
	int count = 0;
	for (size_t i = 0; i < _tentacles_resolved.size(); i++) {
		if (_tentacles_resolved[i] != nullptr) count++;
	}
	return count;
}

NodePath Orifice::get_tentacle_path(int p_index) const {
	if (p_index < 0 || p_index >= tentacle_paths.size()) return NodePath();
	return tentacle_paths[p_index];
}

Tentacle *Orifice::_resolve_node_to_tentacle(const NodePath &p_path) const {
	if (p_path.is_empty()) return nullptr;
	// Same dual-path resolver as 5B's host-bone lookup: prefer
	// `get_node_or_null` when in tree, else walk children of the
	// SceneTree root manually (covers `--script` headless-test mode
	// where `is_inside_tree()` returns false).
	Node *node = nullptr;
	if (is_inside_tree()) {
		node = get_node_or_null(p_path);
	}
	if (node == nullptr) {
		SceneTree *tree = get_tree();
		Window *root = (tree != nullptr) ? tree->get_root() : nullptr;
		if (root != nullptr) {
			String path_str = String(p_path);
			const String root_prefix = "/root/";
			if (path_str.begins_with(root_prefix)) {
				path_str = path_str.substr(root_prefix.length());
			}
			Node *cursor = root;
			PackedStringArray segments = path_str.split("/", false);
			for (int i = 0; i < segments.size() && cursor != nullptr; i++) {
				const String &seg = segments[i];
				Node *next = nullptr;
				int child_count = cursor->get_child_count();
				for (int c = 0; c < child_count; c++) {
					Node *child = cursor->get_child(c);
					if (child != nullptr && String(child->get_name()) == seg) {
						next = child;
						break;
					}
				}
				cursor = next;
			}
			node = cursor;
		}
	}
	return Object::cast_to<Tentacle>(node);
}

void Orifice::_resolve_tentacles_lazy() const {
	int desired = tentacle_paths.size();
	if (!_tentacles_dirty && (int)_tentacles_resolved.size() == desired) {
		// Quick re-validate — if any cached pointer's current re-resolve
		// produces a different value (path moved, node freed), mark dirty
		// and rebuild. Cheap when stable.
		bool stale = false;
		for (int i = 0; i < desired; i++) {
			Tentacle *fresh = _resolve_node_to_tentacle(tentacle_paths[i]);
			if (fresh != _tentacles_resolved[i]) {
				stale = true;
				break;
			}
		}
		if (!stale) return;
	}
	_tentacles_resolved.assign((size_t)desired, nullptr);
	for (int i = 0; i < desired; i++) {
		_tentacles_resolved[i] = _resolve_node_to_tentacle(tentacle_paths[i]);
	}
	_tentacles_dirty = false;
}

// -- Type-2 contact collection (slice 5C-A) --------------------------------

void Orifice::_collect_type2_contacts() {
	_type2_contacts.clear();
	if (rim_loops.empty()) return;
	_resolve_tentacles_lazy();
	if (_tentacles_resolved.empty()) return;

	for (size_t ti = 0; ti < _tentacles_resolved.size(); ti++) {
		Tentacle *t = _tentacles_resolved[ti];
		if (t == nullptr) continue;
		Ref<PBDSolver> sol = t->get_solver();
		if (sol.is_null()) continue;
		float t_radius_base = sol->get_collision_radius();
		int t_n = sol->get_particle_count();
		for (int pi = 0; pi < t_n; pi++) {
			Vector3 t_pos = sol->get_particle_position(pi);
			float t_girth = sol->get_particle_girth_scale(pi);
			float t_smooth_radius = t_radius_base * t_girth;
			for (size_t li = 0; li < rim_loops.size(); li++) {
				RimLoopState &loop = rim_loops[li];
				int rn = (int)loop.rim_particles.size();
				for (int rk = 0; rk < rn; rk++) {
					float r_radius = loop.rim_contact_radius_per_k[rk];
					Vector3 r_pos = loop.rim_particles[rk].position;
					// Slice 5H — sample the tentacle's feature silhouette
					// at the rim particle's position (the contact will
					// land here if it materializes). The silhouette adds
					// outward (positive) or inward (negative) perturbation
					// to the smooth tentacle radius. Sample BEFORE the
					// distance check so feature bumps trigger contacts
					// that the smooth threshold would have missed.
					float feature_perturbation = t->sample_feature_silhouette_at_contact(pi, r_pos);
					float t_radius = t_smooth_radius + feature_perturbation;
					if (t_radius < 1e-5f) t_radius = 1e-5f;
					float radii_sum = t_radius + r_radius;
					if (radii_sum <= 1e-6f) continue;
					Vector3 d = r_pos - t_pos;
					float dist_sq = d.length_squared();
					float thresh_sq = radii_sum * radii_sum;
					if (dist_sq >= thresh_sq) continue;
					float dist = Math::sqrt(dist_sq);
					Vector3 normal;
					if (dist < 1e-8f) {
						// Coincident — pick a stable separation axis. The
						// rim's outward direction in the Center frame is a
						// reasonable default (rim is "thicker" outward).
						normal = (loop.rim_particles[rk].rest_position_in_center_frame).normalized();
						if (normal.length_squared() < 1e-10f) {
							normal = Vector3(0.0f, 1.0f, 0.0f);
						}
					} else {
						normal = d / dist;
					}
					Type2Contact c;
					c.tentacle_idx = (int)ti;
					c.particle_idx = pi;
					c.loop_idx = (int)li;
					c.rim_particle_idx = rk;
					c.normal = normal;
					c.radii_sum = radii_sum;
					c.normal_lambda = 0.0f;
					// Slice 5C-C — fresh per-tick friction accumulators.
					c.tangent_lambda = Vector3();
					c.friction_applied = Vector3();
					_type2_contacts.push_back(c);
				}
			}
		}
	}
}

// -- Type-2 contact iteration (slice 5C-A) ---------------------------------

void Orifice::_iterate_type2_contacts(float /*p_dt*/) {
	if (_type2_contacts.empty()) return;
	// Bilateral XPBD penetration projection without compliance — collisions
	// are hard equality constraints (Obi `ParticleCollisionConstraints.compute`).
	// `dlambda = -(dist) / w_sum`, `lambda = max(λ + Δλ, 0)`, position deltas
	// use `lambda_change × inv_mass` along the cached `normal`. Lambda
	// persists across iters within a tick so subsequent iters can refine
	// without overshoot; reset per tick by `_collect_type2_contacts`.
	for (size_t i = 0; i < _type2_contacts.size(); i++) {
		Type2Contact &c = _type2_contacts[i];
		Tentacle *t = (c.tentacle_idx >= 0 && c.tentacle_idx < (int)_tentacles_resolved.size())
				? _tentacles_resolved[c.tentacle_idx]
				: nullptr;
		if (t == nullptr) continue;
		Ref<PBDSolver> sol = t->get_solver();
		if (sol.is_null()) continue;
		if (c.loop_idx < 0 || c.loop_idx >= (int)rim_loops.size()) continue;
		RimLoopState &loop = rim_loops[c.loop_idx];
		if (c.rim_particle_idx < 0 || c.rim_particle_idx >= (int)loop.rim_particles.size()) continue;
		RimParticle &rp = loop.rim_particles[c.rim_particle_idx];

		Vector3 t_pos = sol->get_particle_position(c.particle_idx);
		float w_t = sol->get_particle_inv_mass(c.particle_idx);
		float w_r = rp.inv_mass;
		float w_sum = w_t + w_r;
		if (w_sum <= 0.0f) continue;

		// Re-evaluate distance along the contact normal using current
		// positions (allows lambda to refine across iters as the rest of
		// the system pushes back). Signed distance: positive means the
		// particles are separated past `radii_sum` (no contact); negative
		// means penetrating.
		Vector3 delta_world = rp.position - t_pos;
		float dist_along_normal = delta_world.dot(c.normal);
		float signed_gap = dist_along_normal - c.radii_sum;
		// `dlambda = -signed_gap / w_sum`. New lambda clamped ≥ 0 so
		// contacts only push (matches Obi `SolvePenetration`). The
		// per-iter lambda CHANGE drives the position deltas.
		float dlambda = -signed_gap / w_sum;
		float new_lambda = c.normal_lambda + dlambda;
		if (new_lambda < 0.0f) new_lambda = 0.0f;
		float lambda_change = new_lambda - c.normal_lambda;
		c.normal_lambda = new_lambda;
		if (lambda_change <= 1e-9f) continue;
		// Tentacle pushed in `-normal × Δλ × w_t` (away from rim);
		// rim pushed in `+normal × Δλ × w_r` (away from tentacle).
		if (w_t > 0.0f) {
			Vector3 t_delta = c.normal * (-lambda_change * w_t);
			t->add_external_position_delta(c.particle_idx, t_delta);
		}
		if (w_r > 0.0f) {
			Vector3 r_delta = c.normal * (lambda_change * w_r);
			_add_delta(loop, c.rim_particle_idx, r_delta);
		}
	}
	// Flush both sides. Rim deltas applied per loop; tentacle deltas
	// flushed via the chain solver's accumulator. Multiple contacts on
	// the same particle compose by Jacobi average inside each apply.
	for (size_t li = 0; li < rim_loops.size(); li++) {
		_apply_deltas_all(rim_loops[li]);
	}
	for (size_t ti = 0; ti < _tentacles_resolved.size(); ti++) {
		Tentacle *t = _tentacles_resolved[ti];
		if (t != nullptr) t->flush_external_position_deltas();
	}
}

// -- Type-2 friction iteration (slice 5C-C) -------------------------------

void Orifice::_iterate_type2_friction(float /*p_dt*/) {
	if (_type2_contacts.empty()) return;
	// Bilateral lambda-bounded friction cone (Obi
	// `ContactHandling.cginc::SolveFriction` adapted to bilateral mass
	// split). Cone size scales with the contact's already-accumulated
	// `normal_lambda`; per-iter tangent motion below the static cone
	// is fully canceled, motion above is capped at the kinetic cone.
	// `tangent_lambda` accumulates the canceled motion across iters
	// within a tick (reset per-tick by `_collect_type2_contacts`).
	//
	// Friction-coefficient composition for 5C-C is the simplest form
	// that matches the chain solver: `mu_s = base_static_friction ×
	// (1 - tentacle_lubricity)`. The full §4.4 modulator stack (rib,
	// anisotropy, adhesion) is deferred.
	for (size_t i = 0; i < _type2_contacts.size(); i++) {
		Type2Contact &c = _type2_contacts[i];
		if (c.normal_lambda <= 0.0f) continue;
		Tentacle *t = (c.tentacle_idx >= 0 && c.tentacle_idx < (int)_tentacles_resolved.size())
				? _tentacles_resolved[c.tentacle_idx]
				: nullptr;
		if (t == nullptr) continue;
		Ref<PBDSolver> sol = t->get_solver();
		if (sol.is_null()) continue;
		if (c.loop_idx < 0 || c.loop_idx >= (int)rim_loops.size()) continue;
		RimLoopState &loop = rim_loops[c.loop_idx];
		if (c.rim_particle_idx < 0 || c.rim_particle_idx >= (int)loop.rim_particles.size()) continue;
		RimParticle &rp = loop.rim_particles[c.rim_particle_idx];

		float w_t = sol->get_particle_inv_mass(c.particle_idx);
		float w_r = rp.inv_mass;
		float w_sum = w_t + w_r;
		if (w_sum <= 0.0f) continue;

		// Tangential relative slip: tentacle's per-tick displacement
		// minus the rim's, projected onto the tangent plane (orthogonal
		// to the contact normal). This is the slip the friction cone
		// is meant to cancel — NOT the current separation. Slice 5C-C
		// added `PBDSolver::get_particle_prev_position` so we can read
		// the tentacle's pre-tick position directly instead of using
		// the rim's prev_position as a proxy (which conflated current
		// separation with slip and over-amplified the rim deltas).
		Vector3 t_pos = sol->get_particle_position(c.particle_idx);
		Vector3 t_prev = sol->get_particle_prev_position(c.particle_idx);
		Vector3 tentacle_motion = t_pos - t_prev;
		Vector3 rim_motion = rp.position - rp.prev_position;
		Vector3 dx_t = tentacle_motion - rim_motion;
		Vector3 dx_tan = dx_t - c.normal * dx_t.dot(c.normal);
		float tan_mag = dx_tan.length();
		if (tan_mag < 1e-8f) continue;
		Vector3 dx_tan_dir = dx_tan / tan_mag;

		// Friction coefficients (per-tentacle). Composition
		// `mu_s = base × (1 - lubricity)` matches the chain solver's
		// existing form so authoring intuition carries over.
		float mu_s = sol->get_static_friction(); // already composed by caller
		float mu_k = mu_s * sol->get_kinetic_friction_ratio();
		float static_cone = mu_s * c.normal_lambda;  // m·kg
		float kinetic_cone = mu_k * c.normal_lambda; // m·kg

		// Lambda-bounded cancellation. `tan_mag_kgm = tan_mag / w_sum`
		// converts position-space slip to lambda-space (m·kg) so the
		// cone comparison units match.
		float tan_mag_kgm = tan_mag / w_sum;
		float lambda_t_delta;
		if (tan_mag_kgm <= static_cone) {
			lambda_t_delta = -tan_mag_kgm; // full static cancel
		} else {
			lambda_t_delta = -kinetic_cone; // kinetic cap
		}

		// Bilateral position deltas: each side moves `Δλ × w` along
		// the tangent direction toward (or against) closing the slip.
		// Tentacle moves with the slip-cancel direction (its motion is
		// what we're canceling); rim moves opposite.
		Vector3 friction_delta = dx_tan_dir * lambda_t_delta;
		if (w_t > 0.0f) {
			Vector3 t_delta = friction_delta * w_t;
			t->add_external_position_delta(c.particle_idx, t_delta);
		}
		if (w_r > 0.0f) {
			Vector3 r_delta = -friction_delta * w_r;
			_add_delta(loop, c.rim_particle_idx, r_delta);
		}
		c.tangent_lambda += dx_tan_dir * lambda_t_delta;
		// Aggregate friction the rim received from this contact (sum
		// of `−r_delta` across iters; equivalent to the friction force
		// vector times effective mass / dt). Used by the EI population
		// step + §6.3 reaction-on-host-bone.
		c.friction_applied -= friction_delta * w_t;
	}
	// Same Jacobi+SOR flush as the normal-contact step.
	for (size_t li = 0; li < rim_loops.size(); li++) {
		_apply_deltas_all(rim_loops[li]);
	}
	for (size_t ti = 0; ti < _tentacles_resolved.size(); ti++) {
		Tentacle *t = _tentacles_resolved[ti];
		if (t != nullptr) t->flush_external_position_deltas();
	}
}

// -- EntryInteraction lifecycle + geometric refresh (slice 5C-B) ----------

void Orifice::set_entry_interaction_grace_period(float p_seconds) {
	if (p_seconds < 0.0f) p_seconds = 0.0f;
	entry_interaction_grace_period = p_seconds;
}

float Orifice::get_entry_interaction_grace_period() const {
	return entry_interaction_grace_period;
}

int Orifice::get_entry_interaction_count() const {
	return (int)_entry_interactions.size();
}

void Orifice::_resize_per_loop_k_arrays(EntryInteraction &p_ei) const {
	int loop_count = (int)rim_loops.size();
	p_ei.orifice_radius_per_loop_k.resize(loop_count);
	p_ei.orifice_radius_velocity_per_loop_k.resize(loop_count);
	p_ei.damage_accumulated_per_loop_k.resize(loop_count);
	p_ei.radial_pressure_per_loop_k.resize(loop_count);
	p_ei.tangential_friction_per_loop_k.resize(loop_count);
	for (int l = 0; l < loop_count; l++) {
		int n = (int)rim_loops[l].rim_particles.size();
		// Per-tick arrays: `assign` (zero out — re-populated each tick
		// by `_populate_entry_interaction_pressures`).
		p_ei.orifice_radius_per_loop_k[l].assign((size_t)n, 0.0f);
		p_ei.orifice_radius_velocity_per_loop_k[l].assign((size_t)n, 0.0f);
		p_ei.radial_pressure_per_loop_k[l].assign((size_t)n, 0.0f);
		p_ei.tangential_friction_per_loop_k[l].assign((size_t)n, 0.0f);
		// Slice 5C-C — `damage_accumulated_per_loop_k` accumulates across
		// ticks. Use `resize` (preserves existing entries on growth /
		// truncates on shrink) instead of `assign` so damage state
		// survives the per-tick refresh. If the loop's particle count
		// CHANGES (rare authoring-time edit), the partial state past the
		// new size is dropped.
		p_ei.damage_accumulated_per_loop_k[l].resize((size_t)n, 0.0f);
	}
}

bool Orifice::_tentacle_crosses_entry_plane(
		Tentacle *p_tentacle,
		int &out_seg_idx,
		float &out_t,
		std::vector<float> &out_signed_distances) const {
	out_seg_idx = -1;
	out_t = 0.0f;
	out_signed_distances.clear();
	if (p_tentacle == nullptr) return false;
	Ref<PBDSolver> sol = p_tentacle->get_solver();
	if (sol.is_null()) return false;
	int n = sol->get_particle_count();
	if (n < 2) return false;

	// Entry plane: passes through the orifice Center (origin in the
	// cached Center frame) with normal = entry_axis transformed to
	// world via the Center frame basis. Signed distance > 0 = outward
	// from cavity (per §6.1 local frame convention); < 0 = inward.
	const Transform3D xform = _center_frame_cached;
	Vector3 plane_origin = xform.origin;
	Vector3 axis_local = entry_axis;
	if (axis_local.length_squared() < 1e-10f) {
		axis_local = Vector3(0.0f, 0.0f, 1.0f);
	}
	Vector3 plane_normal = xform.basis.xform(axis_local).normalized();

	// Sign convention: signed_distance > 0 means the particle is on the
	// cavity-INTERIOR side (along +entry_axis from the orifice Center);
	// signed_distance ≤ 0 is on the cavity-EXTERIOR side. This matches
	// the test prompt's "anchor outside (negative half-space), chain
	// crossing into +entry_axis" framing — entering the orifice means
	// pushing in the +entry_axis direction.
	out_signed_distances.resize((size_t)n);
	bool any_inside = false;
	for (int i = 0; i < n; i++) {
		Vector3 p = sol->get_particle_position(i);
		float sd = (p - plane_origin).dot(plane_normal);
		out_signed_distances[i] = sd;
		if (sd > 0.0f) any_inside = true;
	}
	if (!any_inside) return false;

	// Walk segments looking for the FIRST crossing (first segment whose
	// endpoints have opposite signs OR exactly one endpoint at zero).
	// "First" is defined as lowest particle index — the deepest insertion
	// crossing (anchor side first) is what defines `arc_length_at_entry`.
	for (int i = 0; i + 1 < n; i++) {
		float sa = out_signed_distances[i];
		float sb = out_signed_distances[i + 1];
		// One endpoint must be on the interior side (sd > 0) and the
		// other on the exterior side (sd <= 0). `sd == 0` is treated as
		// exterior to give `particles_in_tunnel` the same boundary
		// semantics ("on the plane" = not yet in tunnel).
		bool a_in = (sa > 0.0f);
		bool b_in = (sb > 0.0f);
		if (a_in != b_in) {
			out_seg_idx = i;
			float denom = sa - sb;
			if (Math::abs(denom) < 1e-8f) {
				out_t = 0.5f;
			} else {
				out_t = sa / denom;
			}
			if (out_t < 0.0f) out_t = 0.0f;
			if (out_t > 1.0f) out_t = 1.0f;
			return true;
		}
	}
	// All-inside chain (no crossing but `any_inside` true). Treat as
	// "anchor-side already inside" — uncommon for an authored setup but
	// guarded against.
	return false;
}

void Orifice::_refresh_entry_interaction_geometry(
		EntryInteraction &p_ei,
		int p_seg_idx,
		float p_t,
		const std::vector<float> &p_signed_distances,
		float p_dt) {
	Tentacle *t = p_ei.tentacle;
	if (t == nullptr) return;
	Ref<PBDSolver> sol = t->get_solver();
	if (sol.is_null()) return;
	int n = sol->get_particle_count();
	if (n < 2 || p_seg_idx < 0 || p_seg_idx + 1 >= n) return;

	const Transform3D xform = _center_frame_cached;
	Vector3 plane_origin = xform.origin;
	Vector3 axis_local = entry_axis;
	if (axis_local.length_squared() < 1e-10f) {
		axis_local = Vector3(0.0f, 0.0f, 1.0f);
	}
	Vector3 plane_normal = xform.basis.xform(axis_local).normalized();

	Vector3 p_a = sol->get_particle_position(p_seg_idx);
	Vector3 p_b = sol->get_particle_position(p_seg_idx + 1);
	Vector3 entry_point = p_a + (p_b - p_a) * p_t;

	// arc_length_at_entry: sum rest-segment lengths up to the crossing,
	// plus the interpolated fraction × that segment's rest length.
	float arc = 0.0f;
	for (int i = 0; i < p_seg_idx; i++) {
		arc += sol->get_rest_length(i);
	}
	arc += sol->get_rest_length(p_seg_idx) * p_t;
	p_ei.arc_length_at_entry = arc;
	p_ei.entry_point = entry_point;
	p_ei.entry_axis = plane_normal;
	// `center_offset_in_orifice` is the entry point relative to the
	// orifice Center, expressed in Center-frame coordinates so multi-
	// tentacle aggregation later (§6.5) can compare offsets without
	// reapplying the Center transform.
	p_ei.center_offset_in_orifice = xform.affine_inverse().xform(entry_point);

	// Tangent at entry — segment direction. dot with `entry_axis` gives
	// the cosine of the approach angle. A tentacle threading inward has
	// tangent · entry_axis < 0 (anchor side outward, tip side inward).
	Vector3 seg = (p_b - p_a);
	if (seg.length_squared() > 1e-12f) {
		Vector3 tangent = seg.normalized();
		p_ei.approach_angle_cos = tangent.dot(plane_normal);
	} else {
		p_ei.approach_angle_cos = 0.0f;
	}

	float girth_a = sol->get_particle_girth_scale(p_seg_idx);
	float girth_b = sol->get_particle_girth_scale(p_seg_idx + 1);
	p_ei.tentacle_girth_here = girth_a + (girth_b - girth_a) * p_t;
	Vector2 asym_a = sol->get_particle_asymmetry(p_seg_idx);
	Vector2 asym_b = sol->get_particle_asymmetry(p_seg_idx + 1);
	p_ei.tentacle_asymmetry_here = asym_a + (asym_b - asym_a) * p_t;

	// penetration_depth: arc length on the cavity-interior side
	// (signed_distance > 0 per the new convention). Crossing segment
	// contributes its partial fraction on the interior side; subsequent
	// segments contribute their full rest length while both endpoints
	// stay inside; once the chain crosses back out, stop.
	float depth = 0.0f;
	int seg_count = sol->get_segment_count();
	bool inside_side_a = (p_signed_distances[p_seg_idx] > 0.0f);
	if (inside_side_a) {
		// Anchor side of the crossing segment is inside.
		depth += sol->get_rest_length(p_seg_idx) * p_t;
	} else {
		// Tip side of the crossing segment is inside (typical for the
		// canonical "anchor outside, tip pushed inward" geometry).
		depth += sol->get_rest_length(p_seg_idx) * (1.0f - p_t);
	}
	int dir = inside_side_a ? -1 : 1;
	int j = p_seg_idx + (dir > 0 ? 1 : 0);
	int j_end = (dir > 0) ? n : -1;
	for (j += dir; j != j_end; j += dir) {
		if (j < 0 || j >= n) break;
		if (p_signed_distances[j] <= 0.0f) break;
		int seg = (dir > 0) ? j - 1 : j;
		if (seg < 0 || seg >= seg_count) break;
		depth += sol->get_rest_length(seg);
	}
	p_ei.penetration_depth = depth;

	// axial_velocity = d(penetration_depth)/dt. First refresh: report 0
	// instead of (depth - 0)/dt to avoid a creation-tick spike.
	if (p_ei.first_refresh_done) {
		p_ei.axial_velocity = (depth - p_ei.prev_penetration_depth) / p_dt;
	} else {
		p_ei.axial_velocity = 0.0f;
		p_ei.first_refresh_done = true;
	}
	p_ei.prev_penetration_depth = depth;

	// particles_in_tunnel: indices with signed_distance > 0 (cavity-
	// interior side per the implementation convention — see
	// `_tentacle_crosses_entry_plane`).
	p_ei.particles_in_tunnel.clear();
	for (int i = 0; i < n; i++) {
		if (p_signed_distances[i] > 0.0f) {
			p_ei.particles_in_tunnel.push_back(i);
		}
	}

	// Defensive resize of per-loop_k arrays — `add_rim_loop` /
	// `clear_rim_loops` between ticks would otherwise leave the EI's
	// buffers misaligned. Cheap O(N×L); 5C-C reads these during the
	// reaction-on-host-bone pass.
	_resize_per_loop_k_arrays(p_ei);
}

void Orifice::_update_entry_interactions(float p_dt) {
	// First, mark every existing EI as inactive-pending. We re-flag
	// `active = true` below for tentacles still engaging. After the
	// loop, EIs that didn't get re-flagged accumulate
	// `retirement_timer` and get purged once it exceeds the grace
	// period.
	for (size_t i = 0; i < _entry_interactions.size(); i++) {
		_entry_interactions[i].active = false;
	}

	int t_count = (int)_tentacles_resolved.size();
	for (int t_idx = 0; t_idx < t_count; t_idx++) {
		Tentacle *t = _tentacles_resolved[t_idx];
		if (t == nullptr) continue;

		int seg_idx = -1;
		float t_param = 0.0f;
		std::vector<float> signed_distances;
		bool engaged = _tentacle_crosses_entry_plane(t, seg_idx, t_param, signed_distances);
		if (!engaged) continue;

		// Find existing EI by tentacle_idx; create new if absent.
		EntryInteraction *ei = nullptr;
		for (size_t i = 0; i < _entry_interactions.size(); i++) {
			if (_entry_interactions[i].tentacle_idx == t_idx) {
				ei = &_entry_interactions[i];
				break;
			}
		}
		if (ei == nullptr) {
			EntryInteraction fresh;
			fresh.tentacle_idx = t_idx;
			fresh.tentacle = t;
			fresh.active = true;
			fresh.retirement_timer = 0.0f;
			_resize_per_loop_k_arrays(fresh);
			_entry_interactions.push_back(fresh);
			ei = &_entry_interactions.back();
		} else {
			// Refresh the cached pointer — `_resolve_tentacles_lazy`
			// could have re-resolved to a different Tentacle instance.
			ei->tentacle = t;
			ei->active = true;
			ei->retirement_timer = 0.0f;
		}
		_refresh_entry_interaction_geometry(*ei, seg_idx, t_param, signed_distances, p_dt);
	}

	// Sweep: accumulate retirement timer on inactive EIs; purge once
	// past the grace period. EIs whose tentacle_idx now points outside
	// the resolved list (path freed / unregistered) get fast-purged by
	// pre-setting their timer past the grace period.
	for (size_t i = 0; i < _entry_interactions.size(); i++) {
		EntryInteraction &ei = _entry_interactions[i];
		if (!ei.active) {
			bool tentacle_gone = (ei.tentacle_idx < 0 ||
					ei.tentacle_idx >= t_count ||
					_tentacles_resolved[ei.tentacle_idx] == nullptr);
			if (tentacle_gone) {
				ei.retirement_timer = entry_interaction_grace_period + 1.0f;
				ei.tentacle = nullptr;
			} else {
				ei.retirement_timer += p_dt;
			}
		}
	}
	for (auto it = _entry_interactions.begin(); it != _entry_interactions.end();) {
		if (!it->active && it->retirement_timer > entry_interaction_grace_period) {
			it = _entry_interactions.erase(it);
		} else {
			++it;
		}
	}
}

// -- EI per-loop_k populating + grip + damage (slice 5C-C) ----------------

void Orifice::_populate_entry_interaction_pressures(float p_dt) {
	// Zero the per-tick arrays first (radial pressure + tangential
	// friction are per-tick; damage accumulates across ticks).
	for (size_t i = 0; i < _entry_interactions.size(); i++) {
		EntryInteraction &ei = _entry_interactions[i];
		for (size_t l = 0; l < ei.radial_pressure_per_loop_k.size(); l++) {
			std::vector<float> &arr = ei.radial_pressure_per_loop_k[l];
			for (size_t k = 0; k < arr.size(); k++) arr[k] = 0.0f;
		}
		for (size_t l = 0; l < ei.tangential_friction_per_loop_k.size(); l++) {
			std::vector<float> &arr = ei.tangential_friction_per_loop_k[l];
			for (size_t k = 0; k < arr.size(); k++) arr[k] = 0.0f;
		}
		ei.reaction_on_ragdoll = Vector3();
		ei.axial_friction_force = 0.0f;
	}

	// Walk type-2 contacts; route each contact's normal_lambda +
	// friction magnitude into the matching EI's per-loop_k slots.
	for (size_t i = 0; i < _type2_contacts.size(); i++) {
		const Type2Contact &c = _type2_contacts[i];
		EntryInteraction *ei = nullptr;
		for (size_t e = 0; e < _entry_interactions.size(); e++) {
			if (_entry_interactions[e].tentacle_idx == c.tentacle_idx &&
					_entry_interactions[e].active) {
				ei = &_entry_interactions[e];
				break;
			}
		}
		if (ei == nullptr) continue;
		if (c.loop_idx < 0 || c.loop_idx >= (int)ei->radial_pressure_per_loop_k.size()) continue;
		std::vector<float> &press_arr = ei->radial_pressure_per_loop_k[c.loop_idx];
		std::vector<float> &fric_arr = ei->tangential_friction_per_loop_k[c.loop_idx];
		if (c.rim_particle_idx < 0 || c.rim_particle_idx >= (int)press_arr.size()) continue;
		press_arr[c.rim_particle_idx] += c.normal_lambda;
		fric_arr[c.rim_particle_idx] += c.friction_applied.length();
	}

	// Damage accumulation: each rim particle's pressure × dt × rate
	// builds toward `damage_failure_threshold`. Damage degrades grip
	// gradient via §6.3 smoothstep — stored on the EI for the snapshot.
	for (size_t i = 0; i < _entry_interactions.size(); i++) {
		EntryInteraction &ei = _entry_interactions[i];
		if (!ei.active) continue;
		for (size_t l = 0; l < ei.radial_pressure_per_loop_k.size(); l++) {
			const std::vector<float> &press_arr = ei.radial_pressure_per_loop_k[l];
			std::vector<float> &dmg_arr = ei.damage_accumulated_per_loop_k[l];
			for (size_t k = 0; k < press_arr.size() && k < dmg_arr.size(); k++) {
				dmg_arr[k] += press_arr[k] * p_dt * damage_rate;
			}
		}
	}

	// Grip engagement ramp + in_stick_phase flip.
	for (size_t i = 0; i < _entry_interactions.size(); i++) {
		EntryInteraction &ei = _entry_interactions[i];
		if (!ei.active) {
			// Don't touch grip_engagement on disengaged EIs — hysteretic
			// state survives the inactive→active cycle.
			continue;
		}
		bool stationary = Math::abs(ei.axial_velocity) <= grip_stationarity_threshold;
		float ramp_per_tick = (grip_onset_time > 1e-6f) ? (p_dt / grip_onset_time) : 1.0f;
		if (stationary) {
			ei.grip_engagement += ramp_per_tick;
			if (ei.grip_engagement > 1.0f) ei.grip_engagement = 1.0f;
		} else {
			// Decay toward zero when the tentacle is actively moving
			// axially. Same time-constant for symmetry — drivers can
			// extend with separate onset/release knobs in a later
			// slice if needed.
			ei.grip_engagement -= ramp_per_tick;
			if (ei.grip_engagement < 0.0f) ei.grip_engagement = 0.0f;
		}

		// in_stick_phase flips true when grip is high AND every contact
		// for this EI is inside the static cone (tan_mag_kgm <=
		// static_cone). Flips false if any contact entered the kinetic
		// regime this tick. Hysteresis tuning is deferred.
		if (ei.grip_engagement > 0.5f) {
			bool all_static = true;
			bool any_contact = false;
			Tentacle *t = ei.tentacle;
			Ref<PBDSolver> sol = (t != nullptr) ? t->get_solver() : Ref<PBDSolver>();
			float mu_s = (sol.is_valid()) ? sol->get_static_friction() : 0.0f;
			for (size_t ci = 0; ci < _type2_contacts.size(); ci++) {
				const Type2Contact &c = _type2_contacts[ci];
				if (c.tentacle_idx != ei.tentacle_idx) continue;
				if (c.normal_lambda <= 0.0f) continue;
				any_contact = true;
				float static_cone = mu_s * c.normal_lambda;
				float applied_mag = c.tangent_lambda.length();
				// If the canceled tangent magnitude reached the kinetic
				// cap (i.e., applied = kinetic_cone < dx_tan), then we
				// were in the kinetic regime — break stick.
				if (applied_mag > static_cone + 1e-7f) {
					all_static = false;
					break;
				}
			}
			ei.in_stick_phase = (any_contact && all_static);
		} else {
			ei.in_stick_phase = false;
		}
	}
}

// -- §6.3 reaction-on-host-bone (slice 5C-C) ------------------------------

Object *Orifice::_resolve_path_to_physical_bone(const NodePath &p_path) const {
	if (p_path.is_empty()) return nullptr;
	Node *node = nullptr;
	if (is_inside_tree()) {
		node = get_node_or_null(p_path);
	}
	if (node == nullptr) {
		SceneTree *tree = get_tree();
		Window *root = (tree != nullptr) ? tree->get_root() : nullptr;
		if (root != nullptr) {
			String path_str = String(p_path);
			const String root_prefix = "/root/";
			if (path_str.begins_with(root_prefix)) {
				path_str = path_str.substr(root_prefix.length());
			}
			Node *cursor = root;
			PackedStringArray segments = path_str.split("/", false);
			for (int i = 0; i < segments.size() && cursor != nullptr; i++) {
				const String &seg = segments[i];
				Node *next = nullptr;
				int child_count = cursor->get_child_count();
				for (int c = 0; c < child_count; c++) {
					Node *child = cursor->get_child(c);
					if (child != nullptr && String(child->get_name()) == seg) {
						next = child;
						break;
					}
				}
				cursor = next;
			}
			node = cursor;
		}
	}
	// Cast via class name lookup — `PhysicalBone3D` is in
	// `godot_cpp/classes/`, but we accept any Node3D-derived collider
	// here so test scaffolding can use a simpler stand-in (e.g.
	// `RigidBody3D`) when wiring up. The runtime check uses
	// `is_class("PhysicalBone3D")` AND `is_class("RigidBody3D")` since
	// `PhysicalBone3D extends PhysicsBody3D` (NOT RigidBody3D in 4.x).
	// We resolve to the broader `CollisionObject3D` interface via
	// duck-typing on `get_rid`.
	if (node == nullptr) return nullptr;
	if (node->has_method("get_rid")) {
		return node;
	}
	return nullptr;
}

void Orifice::_resolve_host_body_lazy() const {
	_host_body_cached = nullptr;
	_host_body_rid = RID();
	_host_body_active = false;

	// Explicit override path takes precedence.
	if (!host_physical_bone_path.is_empty()) {
		Object *obj = _resolve_path_to_physical_bone(host_physical_bone_path);
		if (obj != nullptr) {
			_host_body_cached = obj;
			Variant rid_v = obj->call("get_rid");
			if (rid_v.get_type() == Variant::RID) {
				_host_body_rid = rid_v;
				_host_body_active = true;
			}
		}
		_host_body_dirty = false;
		return;
	}

	// Auto-resolve: walk skeleton children for a PhysicalBone3D whose
	// `get_bone_id() == _bone_index_cached`. The 5B host-bone resolver
	// has already populated `_skeleton_cached` + `_bone_index_cached`.
	if (_skeleton_cached == nullptr || _bone_index_cached < 0) {
		_host_body_dirty = false;
		return;
	}
	int child_count = _skeleton_cached->get_child_count();
	for (int c = 0; c < child_count; c++) {
		Node *child = _skeleton_cached->get_child(c);
		if (child == nullptr) continue;
		if (!child->is_class("PhysicalBone3D")) continue;
		Variant bone_id_v = child->call("get_bone_id");
		if (bone_id_v.get_type() != Variant::INT) continue;
		if ((int)bone_id_v != _bone_index_cached) continue;
		if (!child->has_method("get_rid")) continue;
		Variant rid_v = child->call("get_rid");
		if (rid_v.get_type() != Variant::RID) continue;
		_host_body_cached = child;
		_host_body_rid = rid_v;
		_host_body_active = true;
		break;
	}
	_host_body_dirty = false;
}

void Orifice::_apply_reaction_on_host_bone(float p_dt) {
	_resolve_host_body_lazy();
	if (!_host_body_active) return;
	if (_entry_interactions.empty()) return;

	// Center origin in world space — needed for `dir_outward`. Pull
	// from the cached Center frame so we get the bone-driven origin
	// when host bone is active.
	const Transform3D xform = _center_frame_cached;
	Vector3 center_pos = xform.origin;
	Vector3 entry_axis_world = xform.basis.xform(entry_axis).normalized();
	if (entry_axis_world.length_squared() < 1e-10f) {
		entry_axis_world = Vector3(0.0f, 0.0f, 1.0f);
	}

	// Resolve host body world origin once (per-tick) for the
	// `body_apply_impulse` offset. Use the cached Object's
	// `global_transform` if it exposes it; else fall back to (0,0,0).
	Vector3 body_origin;
	if (_host_body_cached != nullptr && _host_body_cached->has_method("get_global_transform")) {
		Variant xf_v = _host_body_cached->call("get_global_transform");
		if (xf_v.get_type() == Variant::TRANSFORM3D) {
			body_origin = ((Transform3D)xf_v).origin;
		}
	}

	PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
	if (ps == nullptr) return;

	for (size_t i = 0; i < _entry_interactions.size(); i++) {
		EntryInteraction &ei = _entry_interactions[i];
		if (!ei.active) continue;
		Tentacle *t = ei.tentacle;
		if (t == nullptr) continue;

		for (size_t l = 0; l < ei.radial_pressure_per_loop_k.size(); l++) {
			if ((int)l >= (int)rim_loops.size()) break;
			const RimLoopState &loop = rim_loops[l];
			const std::vector<float> &press_arr = ei.radial_pressure_per_loop_k[l];
			const std::vector<float> &fric_arr = ei.tangential_friction_per_loop_k[l];
			for (size_t k = 0; k < press_arr.size(); k++) {
				float p = press_arr[k];
				if (p <= 0.0f) continue;
				if ((int)k >= (int)loop.rim_particles.size()) break;
				Vector3 contact_pos = loop.rim_particles[k].position;

				// Outward direction — projected to perp-to-entry-axis
				// plane so it's purely radial in the rim plane.
				Vector3 from_center = contact_pos - center_pos;
				Vector3 dir_outward = from_center -
						entry_axis_world * from_center.dot(entry_axis_world);
				float dl = dir_outward.length();
				if (dl < 1e-8f) continue;
				dir_outward /= dl;

				// Wedge math (§6.3 normalized form). `s_intrinsic` is
				// the chain-arc-length at this rim particle; the
				// per-particle offset along axis (`r_offset_along_axis_at_k`)
				// is approximated as 0 here since 5C-A's contact
				// collection is per-tentacle-particle (not yet
				// distributed-along-arc-length). 5C-C accepts this
				// simplification and flags it.
				float s_intrinsic = ei.arc_length_at_entry;
				float drds_intrinsic = t->get_signed_girth_gradient_at_arc_length(s_intrinsic);
				Vector3 t_hat = t->get_tangent_at_arc_length(s_intrinsic);
				float sign_proj = (t_hat.dot(entry_axis_world) >= 0.0f) ? 1.0f : -1.0f;
				float drds_outward = drds_intrinsic * sign_proj;
				float norm = Math::sqrt(1.0f + drds_outward * drds_outward);
				float axial_hold = -p * drds_outward / norm;

				Vector3 radial_force = -dir_outward * p;
				Vector3 axial_force = entry_axis_world * axial_hold;
				float fric_mag = (k < fric_arr.size()) ? fric_arr[k] : 0.0f;
				Vector3 friction_force = -t_hat * fric_mag;

				Vector3 total = radial_force + axial_force + friction_force;
				ps->body_apply_impulse(_host_body_rid, total * p_dt,
						contact_pos - body_origin);
				ei.reaction_on_ragdoll += total;
				ei.axial_friction_force += fric_mag;
			}
		}
	}
}

Array Orifice::get_entry_interactions_snapshot() const {
	Array out;
	for (size_t i = 0; i < _entry_interactions.size(); i++) {
		const EntryInteraction &ei = _entry_interactions[i];
		Dictionary d;
		NodePath path;
		if (ei.tentacle_idx >= 0 && ei.tentacle_idx < tentacle_paths.size()) {
			path = tentacle_paths[ei.tentacle_idx];
		}
		d["tentacle_index"] = ei.tentacle_idx;
		d["tentacle_path"] = path;
		d["active"] = ei.active;
		d["retirement_timer"] = ei.retirement_timer;
		d["arc_length_at_entry"] = ei.arc_length_at_entry;
		d["entry_point"] = ei.entry_point;
		d["entry_axis"] = ei.entry_axis;
		d["center_offset_in_orifice"] = ei.center_offset_in_orifice;
		d["approach_angle_cos"] = ei.approach_angle_cos;
		d["tentacle_girth_here"] = ei.tentacle_girth_here;
		d["tentacle_asymmetry_here"] = ei.tentacle_asymmetry_here;
		d["penetration_depth"] = ei.penetration_depth;
		d["axial_velocity"] = ei.axial_velocity;
		d["particles_in_tunnel"] = ei.particles_in_tunnel;
		d["grip_engagement"] = ei.grip_engagement;
		d["in_stick_phase"] = ei.in_stick_phase;
		d["ejection_velocity"] = ei.ejection_velocity;

		// Slice 5C-C — per-loop_k arrays as nested Arrays (Array of
		// PackedFloat32Array, one per loop). Same shape for all four
		// metrics so callers iterate uniformly.
		Array radial_press;
		Array tang_fric;
		Array damage;
		for (size_t l = 0; l < ei.radial_pressure_per_loop_k.size(); l++) {
			const std::vector<float> &press = ei.radial_pressure_per_loop_k[l];
			PackedFloat32Array pf;
			pf.resize((int)press.size());
			float *dst = pf.ptrw();
			for (size_t k = 0; k < press.size(); k++) dst[k] = press[k];
			radial_press.push_back(pf);

			const std::vector<float> &fric = ei.tangential_friction_per_loop_k[l];
			PackedFloat32Array ff;
			ff.resize((int)fric.size());
			float *dst2 = ff.ptrw();
			for (size_t k = 0; k < fric.size(); k++) dst2[k] = fric[k];
			tang_fric.push_back(ff);

			const std::vector<float> &dmg = ei.damage_accumulated_per_loop_k[l];
			PackedFloat32Array df;
			df.resize((int)dmg.size());
			float *dst3 = df.ptrw();
			for (size_t k = 0; k < dmg.size(); k++) dst3[k] = dmg[k];
			damage.push_back(df);
		}
		d["radial_pressure_per_loop_k"] = radial_press;
		d["tangential_friction_per_loop_k"] = tang_fric;
		d["damage_accumulated_per_loop_k"] = damage;
		d["reaction_on_ragdoll"] = ei.reaction_on_ragdoll;
		d["axial_friction_force"] = ei.axial_friction_force;
		out.push_back(d);
	}
	return out;
}

// -- Type-2 friction snapshot (slice 5C-C) --------------------------------

Array Orifice::get_type2_friction_snapshot() const {
	Array out;
	for (size_t i = 0; i < _type2_contacts.size(); i++) {
		const Type2Contact &c = _type2_contacts[i];
		Dictionary d;
		NodePath path;
		if (c.tentacle_idx >= 0 && c.tentacle_idx < tentacle_paths.size()) {
			path = tentacle_paths[c.tentacle_idx];
		}
		d["tentacle_path"] = path;
		d["tentacle_index"] = c.tentacle_idx;
		d["particle_index"] = c.particle_idx;
		d["loop_index"] = c.loop_idx;
		d["rim_particle_index"] = c.rim_particle_idx;
		d["normal_lambda"] = c.normal_lambda;
		d["tangent_lambda"] = c.tangent_lambda;
		d["friction_applied"] = c.friction_applied;
		// Was the friction at this contact in the static cone (true) or
		// kinetic regime (false) this tick? Same comparison the EI's
		// `in_stick_phase` aggregator uses.
		bool in_static = false;
		Tentacle *t = (c.tentacle_idx >= 0 && c.tentacle_idx < (int)_tentacles_resolved.size())
				? _tentacles_resolved[c.tentacle_idx]
				: nullptr;
		if (t != nullptr) {
			Ref<PBDSolver> sol = t->get_solver();
			if (sol.is_valid() && c.normal_lambda > 0.0f) {
				float mu_s = sol->get_static_friction();
				float static_cone = mu_s * c.normal_lambda;
				in_static = (c.tangent_lambda.length() <= static_cone + 1e-7f);
			}
		}
		d["in_static_cone"] = in_static;
		out.push_back(d);
	}
	return out;
}

// -- Host body snapshot (slice 5C-C) --------------------------------------

Dictionary Orifice::get_host_body_state() const {
	_resolve_host_body_lazy();
	Dictionary d;
	d["has_host_body"] = _host_body_active;
	d["body_path"] = host_physical_bone_path;
	d["bone_index"] = _bone_index_cached;
	Vector3 origin;
	if (_host_body_active && _host_body_cached != nullptr &&
			_host_body_cached->has_method("get_global_transform")) {
		Variant xf_v = _host_body_cached->call("get_global_transform");
		if (xf_v.get_type() == Variant::TRANSFORM3D) {
			origin = ((Transform3D)xf_v).origin;
		}
	}
	d["current_world_position"] = origin;
	return d;
}

// -- Slice 5C-C tunable setters/getters -----------------------------------

void Orifice::set_grip_onset_time(float p_seconds) {
	if (p_seconds < 0.0f) p_seconds = 0.0f;
	grip_onset_time = p_seconds;
}
float Orifice::get_grip_onset_time() const { return grip_onset_time; }
void Orifice::set_grip_stationarity_threshold(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	grip_stationarity_threshold = p_v;
}
float Orifice::get_grip_stationarity_threshold() const { return grip_stationarity_threshold; }
void Orifice::set_damage_rate(float p_rate) {
	if (p_rate < 0.0f) p_rate = 0.0f;
	damage_rate = p_rate;
}
float Orifice::get_damage_rate() const { return damage_rate; }
void Orifice::set_damage_failure_threshold(float p_threshold) {
	if (p_threshold < 1e-6f) p_threshold = 1e-6f;
	damage_failure_threshold = p_threshold;
}
float Orifice::get_damage_failure_threshold() const { return damage_failure_threshold; }
void Orifice::set_host_physical_bone_path(const NodePath &p_path) {
	host_physical_bone_path = p_path;
	_host_body_dirty = true;
}
NodePath Orifice::get_host_physical_bone_path() const { return host_physical_bone_path; }

// -- Type-2 contact snapshot (slice 5C-A) ---------------------------------

Array Orifice::get_type2_contacts_snapshot() const {
	Array out;
	for (size_t i = 0; i < _type2_contacts.size(); i++) {
		const Type2Contact &c = _type2_contacts[i];
		Dictionary d;
		NodePath path;
		if (c.tentacle_idx >= 0 && c.tentacle_idx < tentacle_paths.size()) {
			path = tentacle_paths[c.tentacle_idx];
		}
		d["tentacle_path"] = path;
		d["tentacle_index"] = c.tentacle_idx;
		d["particle_index"] = c.particle_idx;
		d["loop_index"] = c.loop_idx;
		d["rim_particle_index"] = c.rim_particle_idx;
		d["normal"] = c.normal;
		d["radii_sum"] = c.radii_sum;
		d["normal_lambda"] = c.normal_lambda;
		// Re-evaluate signed gap from live positions for the snapshot —
		// the cached `radii_sum` plus the live separation gives callers
		// (gizmo, tests) what they need without exposing solver internals.
		float gap = 0.0f;
		if (c.loop_idx >= 0 && c.loop_idx < (int)rim_loops.size()) {
			const RimLoopState &loop = rim_loops[c.loop_idx];
			if (c.rim_particle_idx >= 0 && c.rim_particle_idx < (int)loop.rim_particles.size()) {
				Vector3 r_pos = loop.rim_particles[c.rim_particle_idx].position;
				if (c.tentacle_idx >= 0 && c.tentacle_idx < (int)_tentacles_resolved.size()) {
					Tentacle *t = _tentacles_resolved[c.tentacle_idx];
					if (t != nullptr) {
						Ref<PBDSolver> sol = t->get_solver();
						if (sol.is_valid()) {
							Vector3 t_pos = sol->get_particle_position(c.particle_idx);
							gap = (r_pos - t_pos).dot(c.normal) - c.radii_sum;
						}
					}
				}
			}
		}
		d["distance"] = gap;
		out.push_back(d);
	}
	return out;
}

// -- Bindings --------------------------------------------------------------

void Orifice::_bind_methods() {
	using namespace godot;

	ClassDB::bind_method(D_METHOD("tick", "dt"), &Orifice::tick);

	ClassDB::bind_method(D_METHOD("set_iteration_count", "iter"), &Orifice::set_iteration_count);
	ClassDB::bind_method(D_METHOD("get_iteration_count"), &Orifice::get_iteration_count);
	ClassDB::bind_method(D_METHOD("set_sor_factor", "factor"), &Orifice::set_sor_factor);
	ClassDB::bind_method(D_METHOD("get_sor_factor"), &Orifice::get_sor_factor);
	ClassDB::bind_method(D_METHOD("set_damping", "damping"), &Orifice::set_damping);
	ClassDB::bind_method(D_METHOD("get_damping"), &Orifice::get_damping);
	ClassDB::bind_method(D_METHOD("set_gravity", "gravity"), &Orifice::set_gravity);
	ClassDB::bind_method(D_METHOD("get_gravity"), &Orifice::get_gravity);
	ClassDB::bind_method(D_METHOD("set_entry_axis", "axis"), &Orifice::set_entry_axis);
	ClassDB::bind_method(D_METHOD("get_entry_axis"), &Orifice::get_entry_axis);

	ClassDB::bind_method(
			D_METHOD("add_rim_loop",
					"rest_positions_in_center_frame",
					"segment_rest_lengths",
					"target_enclosed_area",
					"rest_stiffness_per_k",
					"area_compliance",
					"distance_compliance",
					"default_contact_radius"),
			&Orifice::add_rim_loop, DEFVAL(0.02f));
	ClassDB::bind_method(D_METHOD("clear_rim_loops"), &Orifice::clear_rim_loops);

	ClassDB::bind_static_method("Orifice",
			D_METHOD("make_circular_rest_positions", "n", "radius", "entry_axis"),
			&Orifice::make_circular_rest_positions);
	ClassDB::bind_static_method("Orifice",
			D_METHOD("make_uniform_segment_rest_lengths", "rest_positions"),
			&Orifice::make_uniform_segment_rest_lengths);
	ClassDB::bind_static_method("Orifice",
			D_METHOD("compute_polygon_area", "positions", "entry_axis"),
			&Orifice::compute_polygon_area);

	ClassDB::bind_method(D_METHOD("get_rim_loop_count"), &Orifice::get_rim_loop_count);
	ClassDB::bind_method(D_METHOD("get_rim_loop_state", "loop_index"), &Orifice::get_rim_loop_state);
	ClassDB::bind_method(D_METHOD("get_loop_area_lambda", "loop_index"), &Orifice::get_loop_area_lambda);
	ClassDB::bind_method(D_METHOD("get_loop_target_enclosed_area", "loop_index"), &Orifice::get_loop_target_enclosed_area);
	ClassDB::bind_method(D_METHOD("get_loop_current_enclosed_area", "loop_index"), &Orifice::get_loop_current_enclosed_area);
	ClassDB::bind_method(D_METHOD("set_particle_position", "loop_index", "particle_index", "world_pos"), &Orifice::set_particle_position);
	ClassDB::bind_method(D_METHOD("get_particle_position", "loop_index", "particle_index"), &Orifice::get_particle_position);
	ClassDB::bind_method(D_METHOD("set_particle_inv_mass", "loop_index", "particle_index", "inv_mass"), &Orifice::set_particle_inv_mass);
	ClassDB::bind_method(D_METHOD("set_loop_target_enclosed_area", "loop_index", "target"), &Orifice::set_loop_target_enclosed_area);

	// Slice 5B — host bone soft attachment.
	ClassDB::bind_method(D_METHOD("set_skeleton_path", "path"), &Orifice::set_skeleton_path);
	ClassDB::bind_method(D_METHOD("get_skeleton_path"), &Orifice::get_skeleton_path);
	ClassDB::bind_method(D_METHOD("set_bone_name", "name"), &Orifice::set_bone_name);
	ClassDB::bind_method(D_METHOD("get_bone_name"), &Orifice::get_bone_name);
	ClassDB::bind_method(D_METHOD("set_host_bone_offset", "offset"), &Orifice::set_host_bone_offset);
	ClassDB::bind_method(D_METHOD("get_host_bone_offset"), &Orifice::get_host_bone_offset);
	ClassDB::bind_method(D_METHOD("set_host_bone", "skeleton_path", "bone_name"), &Orifice::set_host_bone);
	ClassDB::bind_method(D_METHOD("get_host_bone_state"), &Orifice::get_host_bone_state);
	ClassDB::bind_method(D_METHOD("get_center_frame_world"), &Orifice::get_center_frame_world);

	// Slice 5C-A — type-2 contact wiring.
	ClassDB::bind_method(D_METHOD("set_tentacle_paths", "paths"), &Orifice::set_tentacle_paths);
	ClassDB::bind_method(D_METHOD("get_tentacle_paths"), &Orifice::get_tentacle_paths);
	ClassDB::bind_method(D_METHOD("register_tentacle", "path"), &Orifice::register_tentacle);
	ClassDB::bind_method(D_METHOD("unregister_tentacle", "path"), &Orifice::unregister_tentacle);
	ClassDB::bind_method(D_METHOD("get_registered_tentacle_count"), &Orifice::get_registered_tentacle_count);
	ClassDB::bind_method(D_METHOD("get_resolved_tentacle_count"), &Orifice::get_resolved_tentacle_count);
	ClassDB::bind_method(D_METHOD("get_tentacle_path", "index"), &Orifice::get_tentacle_path);
	ClassDB::bind_method(D_METHOD("get_type2_contacts_snapshot"), &Orifice::get_type2_contacts_snapshot);
	ClassDB::bind_method(D_METHOD("set_rim_contact_radius", "loop_index", "particle_index", "radius"), &Orifice::set_rim_contact_radius);
	ClassDB::bind_method(D_METHOD("get_rim_contact_radius", "loop_index", "particle_index"), &Orifice::get_rim_contact_radius);

	// Slice 5D — per-loop realism tunables (4P-A / 4P-B / 4P-C).
	ClassDB::bind_method(D_METHOD("set_loop_distance_anisotropic", "loop_index", "value"),
			&Orifice::set_loop_distance_anisotropic);
	ClassDB::bind_method(D_METHOD("get_loop_distance_anisotropic", "loop_index"),
			&Orifice::get_loop_distance_anisotropic);
	ClassDB::bind_method(D_METHOD("set_loop_distance_stretch_compliance", "loop_index", "value"),
			&Orifice::set_loop_distance_stretch_compliance);
	ClassDB::bind_method(D_METHOD("get_loop_distance_stretch_compliance", "loop_index"),
			&Orifice::get_loop_distance_stretch_compliance);
	ClassDB::bind_method(D_METHOD("set_loop_j_curve_alpha", "loop_index", "value"),
			&Orifice::set_loop_j_curve_alpha);
	ClassDB::bind_method(D_METHOD("get_loop_j_curve_alpha", "loop_index"),
			&Orifice::get_loop_j_curve_alpha);
	ClassDB::bind_method(D_METHOD("set_loop_j_curve_beta", "loop_index", "value"),
			&Orifice::set_loop_j_curve_beta);
	ClassDB::bind_method(D_METHOD("get_loop_j_curve_beta", "loop_index"),
			&Orifice::get_loop_j_curve_beta);
	ClassDB::bind_method(D_METHOD("set_loop_j_curve_characteristic_length", "loop_index", "value"),
			&Orifice::set_loop_j_curve_characteristic_length);
	ClassDB::bind_method(D_METHOD("get_loop_j_curve_characteristic_length", "loop_index"),
			&Orifice::get_loop_j_curve_characteristic_length);
	ClassDB::bind_method(D_METHOD("set_loop_plastic_accumulate_rate", "loop_index", "value"),
			&Orifice::set_loop_plastic_accumulate_rate);
	ClassDB::bind_method(D_METHOD("get_loop_plastic_accumulate_rate", "loop_index"),
			&Orifice::get_loop_plastic_accumulate_rate);
	ClassDB::bind_method(D_METHOD("set_loop_plastic_recover_rate", "loop_index", "value"),
			&Orifice::set_loop_plastic_recover_rate);
	ClassDB::bind_method(D_METHOD("get_loop_plastic_recover_rate", "loop_index"),
			&Orifice::get_loop_plastic_recover_rate);
	ClassDB::bind_method(D_METHOD("set_loop_plastic_max_offset", "loop_index", "value"),
			&Orifice::set_loop_plastic_max_offset);
	ClassDB::bind_method(D_METHOD("get_loop_plastic_max_offset", "loop_index"),
			&Orifice::get_loop_plastic_max_offset);

	// Slice 5C-B — EntryInteraction lifecycle.
	ClassDB::bind_method(D_METHOD("set_entry_interaction_grace_period", "seconds"), &Orifice::set_entry_interaction_grace_period);
	ClassDB::bind_method(D_METHOD("get_entry_interaction_grace_period"), &Orifice::get_entry_interaction_grace_period);
	ClassDB::bind_method(D_METHOD("get_entry_interaction_count"), &Orifice::get_entry_interaction_count);
	ClassDB::bind_method(D_METHOD("get_entry_interactions_snapshot"), &Orifice::get_entry_interactions_snapshot);

	// Slice 5C-C — friction + reaction-on-host-bone tunables + snapshots.
	ClassDB::bind_method(D_METHOD("set_grip_onset_time", "seconds"), &Orifice::set_grip_onset_time);
	ClassDB::bind_method(D_METHOD("get_grip_onset_time"), &Orifice::get_grip_onset_time);
	ClassDB::bind_method(D_METHOD("set_grip_stationarity_threshold", "m_per_s"), &Orifice::set_grip_stationarity_threshold);
	ClassDB::bind_method(D_METHOD("get_grip_stationarity_threshold"), &Orifice::get_grip_stationarity_threshold);
	ClassDB::bind_method(D_METHOD("set_damage_rate", "rate"), &Orifice::set_damage_rate);
	ClassDB::bind_method(D_METHOD("get_damage_rate"), &Orifice::get_damage_rate);
	ClassDB::bind_method(D_METHOD("set_damage_failure_threshold", "threshold"), &Orifice::set_damage_failure_threshold);
	ClassDB::bind_method(D_METHOD("get_damage_failure_threshold"), &Orifice::get_damage_failure_threshold);
	ClassDB::bind_method(D_METHOD("set_host_physical_bone_path", "path"), &Orifice::set_host_physical_bone_path);
	ClassDB::bind_method(D_METHOD("get_host_physical_bone_path"), &Orifice::get_host_physical_bone_path);
	ClassDB::bind_method(D_METHOD("get_host_body_state"), &Orifice::get_host_body_state);
	ClassDB::bind_method(D_METHOD("get_type2_friction_snapshot"), &Orifice::get_type2_friction_snapshot);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "iteration_count",
						 PROPERTY_HINT_RANGE, "1,8,1"),
			"set_iteration_count", "get_iteration_count");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "sor_factor",
						 PROPERTY_HINT_RANGE, "0.5,2.0,0.01"),
			"set_sor_factor", "get_sor_factor");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "damping",
						 PROPERTY_HINT_RANGE, "0.0,1.0,0.001"),
			"set_damping", "get_damping");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "gravity"),
			"set_gravity", "get_gravity");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "entry_axis"),
			"set_entry_axis", "get_entry_axis");

	ADD_GROUP("Host Bone", "");
	ADD_PROPERTY(PropertyInfo(Variant::NODE_PATH, "skeleton_path",
						 PROPERTY_HINT_NODE_PATH_VALID_TYPES, "Skeleton3D"),
			"set_skeleton_path", "get_skeleton_path");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "bone_name"),
			"set_bone_name", "get_bone_name");
	ADD_PROPERTY(PropertyInfo(Variant::TRANSFORM3D, "host_bone_offset"),
			"set_host_bone_offset", "get_host_bone_offset");

	ADD_GROUP("Type-2 Contact", "");
	// Typed array of NodePath. Tentacle resolution is checked at tick
	// time (paths that don't resolve to a `Tentacle` are skipped silently
	// — same fall-back discipline as the host-bone resolver).
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "tentacle_paths"),
			"set_tentacle_paths", "get_tentacle_paths");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "entry_interaction_grace_period",
						 PROPERTY_HINT_RANGE, "0.0,5.0,0.05,suffix:s"),
			"set_entry_interaction_grace_period", "get_entry_interaction_grace_period");

	ADD_GROUP("Grip + Damage", "");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "grip_onset_time",
						 PROPERTY_HINT_RANGE, "0.0,5.0,0.05,suffix:s"),
			"set_grip_onset_time", "get_grip_onset_time");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "grip_stationarity_threshold",
						 PROPERTY_HINT_RANGE, "0.0,2.0,0.01,suffix:m/s"),
			"set_grip_stationarity_threshold", "get_grip_stationarity_threshold");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "damage_rate",
						 PROPERTY_HINT_RANGE, "0.0,10.0,0.01"),
			"set_damage_rate", "get_damage_rate");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "damage_failure_threshold",
						 PROPERTY_HINT_RANGE, "0.001,100.0,0.01"),
			"set_damage_failure_threshold", "get_damage_failure_threshold");

	ADD_GROUP("Host Body", "");
	ADD_PROPERTY(PropertyInfo(Variant::NODE_PATH, "host_physical_bone_path",
						 PROPERTY_HINT_NODE_PATH_VALID_TYPES, "PhysicalBone3D"),
			"set_host_physical_bone_path", "get_host_physical_bone_path");
}
