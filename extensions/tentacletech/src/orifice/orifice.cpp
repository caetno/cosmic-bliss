#include "orifice.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/dictionary.hpp>

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

	for (size_t li = 0; li < rim_loops.size(); li++) {
		RimLoopState &loop = rim_loops[li];
		if ((int)loop.rim_particles.size() < 3) continue;
		_predict_loop(loop, p_dt);
		_iterate_loop(loop, p_dt);
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

void Orifice::_iterate_loop(RimLoopState &loop, float p_dt) {
	int n = (int)loop.rim_particles.size();
	if (n < 3) return;

	const float dt2_inv = 1.0f / (p_dt * p_dt + 1e-20f);
	const Vector3 n_hat = normalize_or_z(entry_axis);

	const float compliance_distance = loop.distance_compliance * dt2_inv;
	const float compliance_area = loop.area_compliance * dt2_inv;

	// Use the node's global_transform when wired into the tree; fall back
	// to identity otherwise. This keeps headless tests (--script mode,
	// where `is_inside_tree` can return false even after add_child) silent
	// without affecting in-game behavior. The Center frame in 5A is just
	// the orifice node's transform; once host-bone soft attachment lands
	// in 5B the lookup moves to the bone's global xform.
	const Transform3D xform = is_inside_tree() ? get_global_transform() : Transform3D();

	for (int iter = 0; iter < iteration_count; iter++) {
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

// -- Authoring API ---------------------------------------------------------

int Orifice::add_rim_loop(
		const PackedVector3Array &p_rest_positions_in_center_frame,
		const PackedFloat32Array &p_segment_rest_lengths,
		float p_target_enclosed_area,
		const PackedFloat32Array &p_rest_stiffness_per_k,
		float p_area_compliance,
		float p_distance_compliance) {
	int n = p_rest_positions_in_center_frame.size();
	if (n < 3) return -1;
	if (p_segment_rest_lengths.size() != n) return -1;
	if (p_rest_stiffness_per_k.size() != n) return -1;

	RimLoopState loop;
	loop.particle_count = n;
	loop.rim_particles.assign((size_t)n, RimParticle());
	loop.rim_segment_rest_lengths.assign((size_t)n, 0.0f);
	loop.rim_particle_rest_stiffness_per_k.assign((size_t)n, 0.0f);
	loop.target_enclosed_area = p_target_enclosed_area;
	loop.area_compliance = p_area_compliance;
	loop.distance_compliance = p_distance_compliance;
	loop.area_lambda = 0.0f;
	loop.position_delta_scratch.assign((size_t)n, Vector3());
	loop.position_delta_count.assign((size_t)n, 0);

	const Vector3 *rp = p_rest_positions_in_center_frame.ptr();
	const float *segs = p_segment_rest_lengths.ptr();
	const float *stf = p_rest_stiffness_per_k.ptr();
	// Use the node's global_transform when wired into the tree; fall back
	// to identity otherwise. This keeps headless tests (--script mode,
	// where `is_inside_tree` can return false even after add_child) silent
	// without affecting in-game behavior. The Center frame in 5A is just
	// the orifice node's transform; once host-bone soft attachment lands
	// in 5B the lookup moves to the bone's global xform.
	const Transform3D xform = is_inside_tree() ? get_global_transform() : Transform3D();
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
	// Use the node's global_transform when wired into the tree; fall back
	// to identity otherwise. This keeps headless tests (--script mode,
	// where `is_inside_tree` can return false even after add_child) silent
	// without affecting in-game behavior. The Center frame in 5A is just
	// the orifice node's transform; once host-bone soft attachment lands
	// in 5B the lookup moves to the bone's global xform.
	const Transform3D xform = is_inside_tree() ? get_global_transform() : Transform3D();
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
					"distance_compliance"),
			&Orifice::add_rim_loop);
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
}
