#include "orifice.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/node.hpp>
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

	_collect_type2_contacts();

	for (int iter = 0; iter < iteration_count; iter++) {
		for (size_t li = 0; li < rim_loops.size(); li++) {
			RimLoopState &loop = rim_loops[li];
			if ((int)loop.rim_particles.size() < 3) continue;
			_iterate_loop_one_pass(loop, p_dt);
		}
		_iterate_type2_contacts(p_dt);
	}

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
		float dlambda = (-constraint - compliance_distance * lambda) /
				(w_sum + compliance_distance + 1e-8f);
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
	for (int k = 0; k < n; k++) {
		RimParticle &p_k = loop.rim_particles[k];
		if (p_k.inv_mass <= 0.0f) continue;
		Vector3 rest_world = xform.xform(p_k.rest_position_in_center_frame);
		Vector3 d = p_k.position - rest_world;
		float dist = d.length();
		if (dist < 1e-8f) continue;
		float compliance_spring = stiffness_to_compliance(
				loop.rim_particle_rest_stiffness_per_k[k]) *
				dt2_inv;
		float &lambda = p_k.spring_lambda;
		float dlambda = (-dist - compliance_spring * lambda) /
				(p_k.inv_mass + compliance_spring + 1e-8f);
		lambda += dlambda;
		Vector3 delta = (d / dist) * (dlambda * p_k.inv_mass);
		_add_delta(loop, k, delta);
	}
	_apply_deltas_all(loop);
}

void Orifice::_finalize_loop(RimLoopState & /*loop*/, float /*p_dt*/) {
	// No-op for 5A. Slot for the §6.4 "pull-out jiggle" damping (already
	// emerges from the XPBD constraint balance + global solver damping)
	// and the §6.10 ContractionPulse rest-position deltas (later slice).
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
		loop.rim_particles[k].rest_position_in_center_frame = rp[k];
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
	for (int k = 0; k < n; k++) {
		const RimParticle &p = loop.rim_particles[k];
		Vector3 rest_world = xform.xform(p.rest_position_in_center_frame);
		Vector3 velocity = p.position - p.prev_position; // tick-rate Δ; caller divides by dt if desired
		Dictionary d;
		d["rest_position"] = rest_world;
		d["current_position"] = p.position;
		d["current_velocity"] = velocity;
		d["spring_lambda"] = p.spring_lambda;
		d["distance_lambda"] = p.distance_lambda_to_next;
		d["neighbour_rest_distance"] = loop.rim_segment_rest_lengths[k];
		d["inv_mass"] = p.inv_mass;
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
			float t_radius = t_radius_base * t_girth;
			for (size_t li = 0; li < rim_loops.size(); li++) {
				RimLoopState &loop = rim_loops[li];
				int rn = (int)loop.rim_particles.size();
				for (int rk = 0; rk < rn; rk++) {
					float r_radius = loop.rim_contact_radius_per_k[rk];
					float radii_sum = t_radius + r_radius;
					if (radii_sum <= 1e-6f) continue;
					Vector3 r_pos = loop.rim_particles[rk].position;
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
}
