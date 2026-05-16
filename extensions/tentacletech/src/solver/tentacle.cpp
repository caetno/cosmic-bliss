#include "tentacle.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/physics_server3d.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/script.hpp>
#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object_id.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include "../orifice/orifice.h"
#include "../spline/spline_data_packer.h"

using namespace godot;

namespace {
// Channel order in the packed spline data, agreed with tentacle_lib.gdshaderinc.
constexpr int CHANNEL_GIRTH_SCALE = 0;
constexpr int CHANNEL_ASYM_X = 1;
constexpr int CHANNEL_ASYM_Y = 2;
constexpr int CHANNEL_COUNT = 3;
constexpr int REST_GIRTH_TEXTURE_WIDTH = 256;
const char *SHADER_RES_PATH = "res://addons/tentacletech/shaders/tentacle.gdshader";
const char *UNIFORM_SPLINE_DATA = "spline_data_texture";
const char *UNIFORM_SPLINE_DATA_WIDTH = "spline_data_width";
const char *UNIFORM_REST_GIRTH = "rest_girth_texture";
const char *UNIFORM_MESH_ARC_AXIS = "mesh_arc_axis";
const char *UNIFORM_MESH_ARC_SIGN = "mesh_arc_sign";
const char *UNIFORM_MESH_ARC_OFFSET = "mesh_arc_offset";
} // namespace

// Slice 5H — function-pointer thunk for the PBDSolver feature-silhouette
// sampler hook. Lets the contact iter sample (s, θ) without paying
// Variant boxing or virtual-call overhead.
static float _silhouette_thunk(void *p_user, int p_particle_idx,
		const Vector3 &p_contact_world_pos) {
	Tentacle *t = static_cast<Tentacle *>(p_user);
	if (t == nullptr) return 0.0f;
	return t->sample_feature_silhouette_at_contact(p_particle_idx, p_contact_world_pos);
}

Tentacle::Tentacle() {
	solver.instantiate();
	solver->initialize_chain(particle_count, segment_length);
	solver->set_collision_radius(particle_collision_radius);
	solver->set_friction(base_static_friction * (1.0f - tentacle_lubricity),
			kinetic_friction_ratio);
	solver->set_contact_stiffness(contact_stiffness);
	solver->set_target_softness_when_blocked(target_softness_when_blocked);
	solver->set_tension_taper_threshold(tension_taper_threshold);
	solver->set_target_velocity_max(target_velocity_max);
	solver->set_sor_factor(sor_factor);
	solver->set_max_depenetration(max_depenetration);
	solver->set_sleep_threshold(sleep_threshold);
	solver->set_contact_velocity_damping(contact_velocity_damping);
	solver->set_support_in_contact(support_in_contact);
	// Slice 5H — wire up the silhouette sampler. The sampler is a no-op
	// when no feature_silhouette image has been set (returns 0).
	solver->set_feature_silhouette_sampler(&_silhouette_thunk, this);
	render_spline.instantiate();
}

Tentacle::~Tentacle() {
	// Defensive: clear the sampler hook so a destructed Tentacle can't
	// be sampled. Solver dies with us so this is mostly informational.
	if (solver.is_valid()) {
		solver->clear_feature_silhouette_sampler();
	}
}

void Tentacle::_ready() {
	// Place the chain in the rest pose at the node's current transform. This
	// runs in the editor too so the overlay can render a static rest pose
	// while the scene is being authored.
	rebuild_chain();

	_ensure_mesh_instance();
	_allocate_render_resources();
	_refresh_mesh_instance();
	_refresh_shader_material_bindings();
	_update_spline_data_texture();

	if (Engine::get_singleton()->is_editor_hint()) {
		// Editor: no physics, but track transform changes so moving the node
		// in the viewport keeps the chain attached visually.
		set_physics_process(false);
		set_notify_transform(true);
		return;
	}
	set_physics_process(true);
}

void Tentacle::_physics_process(double p_delta) {
	if (Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	tick((float)p_delta);
}

void Tentacle::tick(float p_delta) {
	if (solver.is_null()) {
		return;
	}
	// Slice 4M-pre.1 — dt clamp. First-frame hiccups (scene load, alt-tab,
	// long stalls) can deliver dt > 50 ms, which spikes the Verlet gravity
	// step (gravity × dt²) and target-pull catch-up enough to teleport
	// through whatever is in front of the chain. Floor stays small so tests
	// that explicitly tick at sub-millisecond steps still run; ceiling caps
	// at 1/40 s (25 ms ≈ 40 Hz) — anything slower than that, the integrator
	// can't be trusted to keep collisions consistent.
	if (p_delta < 1e-4f) {
		return;
	}
	if (p_delta > 1.0f / 40.0f) {
		p_delta = 1.0f / 40.0f;
	}

	// Anchor refresh runs once per outer tick — global_transform doesn't
	// change within a physics frame, so calling set_anchor inside the
	// substep loop would be pure waste. Pinned particles keep prev=position
	// each predict() call, so velocity stays zero across substeps.
	if (!anchor_override) {
		solver->set_anchor(0, get_global_transform());
	}

	// Slice 5H — refresh per-particle arc-length + body-frame X axis
	// once per outer tick. Cheap O(N) walk; consumed by
	// `sample_feature_silhouette_at_contact` from the type-1 / 2 / 4
	// contact paths.
	_refresh_silhouette_frame_data();

	// Slice 4O — sub-step count: max(user floor, displacement heuristic),
	// capped at MAX_SUBSTEPS. The displacement heuristic predicts the
	// worst-case per-tick particle displacement (gravity × dt² + singleton
	// target snap) and bumps the substep count when a single tick would
	// otherwise move a particle further than `0.5 × collision_radius` —
	// the canonical thrust-frame tunneling threshold. Pose-target driven
	// thrust is NOT in the heuristic by spec design (would be conservative
	// to add but would also bump substep count for every behavior frame);
	// thrust-heavy moods set the floor manually instead.
	float radius = solver->get_collision_radius();
	float gravity_disp = solver->get_gravity().length() * p_delta * p_delta;
	float max_disp = gravity_disp;
	if (solver->has_target()) {
		int ti = solver->get_target_particle_index();
		int n_particles = solver->get_particle_count();
		if (ti >= 0 && ti < n_particles) {
			Vector3 from = solver->get_particle_position(ti);
			float d = (solver->get_target_position() - from).length();
			float target_disp = d * solver->get_target_stiffness();
			if (target_disp > max_disp) max_disp = target_disp;
		}
	}
	int sub_steps = substep_count;
	if (sub_steps < 1) sub_steps = 1;
	if (radius > 1e-5f && max_disp > 0.5f * radius) {
		int auto_steps = (int)Math::ceil(max_disp / (0.5f * radius));
		if (auto_steps > sub_steps) sub_steps = auto_steps;
	}
	if (sub_steps > MAX_SUBSTEPS) sub_steps = MAX_SUBSTEPS;
	last_substep_count = sub_steps;

	// Slice 4O — friction reciprocal accumulator: reset once at outer tick
	// start, then the substep loop accumulates across substeps. The
	// reciprocal pass after the loop reads the summed value and applies one
	// impulse per body per outer tick. set_environment_contacts_multi no
	// longer clobbers friction_applied between substeps (slice 4O change).
	// Spec divergence: when a chain particle's contact body changes between
	// substeps (rare — substep motion is sub-radius), the accumulated friction
	// gets routed to the LAST substep's body. For stable manifolds (the
	// common case) this matches the single-step result exactly.
	solver->reset_friction_applied();
	// Slice 4R — clear contact lambdas at outer-tick boundary. Substep loop
	// (below) calls set_environment_contacts_multi per substep; the RID-keyed
	// warm-start there preserves λ across substeps for stable RIDs (Obi 4×1
	// convergence). 4S.2 re-seeds persisted lambdas AFTER this reset fires;
	// the reset's "post-call all live lambdas == 0" invariant is preserved
	// verbatim — the re-seed is the explicit override mechanism.
	solver->reset_environment_contact_lambdas();
	// Slice 4S.3 — outer-tick boundary: clear the per-tick body→material
	// lookup cache + clear solver-side material buffers so the
	// per-tentacle fallback engages by default for this tick. Substeps
	// re-populate the cache + buffers lazily as tagged bodies appear.
	_material_cache_this_tick.clear();
	solver->clear_environment_contact_materials();
	// Slice 4S.2 — body-local-frame contact persistence: re-inject persisted
	// (RID, normal_lambda, tangent_lambda) for cache slots whose body is
	// still alive and hasn't teleported. Runs ONCE per outer tick. Composes
	// with 4R by addition (post-reset write), not by mutating the reset
	// path. See PersistedContactSlot + Cosmic_Bliss_Update note.
	_validate_and_reseed_persistence();
	// Slice 4T — pose-target rate limit. Runs ONCE per outer tick, before
	// the substep loop below, against the OUTER `p_delta`. Mutates the
	// solver's `target_position` / `pose_target_positions` in-place so the
	// substep loop sees the clamped values throughout. Cold-started targets
	// (first tick after `clear_target` / `clear_pose_targets`) bypass the
	// clamp; warm-running targets (subsequent ticks) get capped at
	// `target_velocity_max × p_delta`.
	solver->apply_target_rate_limit(p_delta);

	float sub_dt = p_delta / (float)sub_steps;
	for (int s = 0; s < sub_steps; s++) {
		_run_environment_probe();
		solver->tick(sub_dt);
	}

	// Slice 4S.2 — snapshot live contact state back into body-local-frame
	// persistence buffer for next tick's reseed. Applies the end-of-tick
	// cone clamp on tangent_lambda. Runs AFTER the last substep.
	_snapshot_persistence_post_tick();

	// Reciprocal impulse (§4.3 type-1) uses the OUTER tick dt — `m × Δx / dt`
	// is "impulse per frame the user sees." Per-substep friction_applied
	// values accumulated above sum to the full-frame Δx the no-substep case
	// would have produced, so dividing by p_delta yields the correct
	// per-frame impulse magnitude regardless of sub_steps.
	_apply_collision_reciprocals(p_delta);
	_update_spline_data_texture();
}

void Tentacle::_apply_collision_reciprocals(float p_delta) {
	// Slice 4E (§4.3 type-1 reciprocal): for each per-particle contact whose
	// collider is a moving body (RigidBody3D, AnimatableBody3D in
	// sync_to_physics mode, PhysicalBone3D), apply an equal impulse at the
	// contact point in the friction direction. Heavy tentacle dragging on a
	// PhysicalBone3D pulls the bone (and the skin attached to it) along the
	// drag direction. Static bodies receive the impulse but the physics
	// server treats it as a no-op.
	//
	// Slice 4M.5: per-contact friction. The solver writes one
	// friction_applied vector per slot (size = particle_count *
	// MAX_CONTACTS_PER_PARTICLE), so each body receives an impulse
	// proportional to the friction work attributed to its specific
	// contact. Bodies attached to two different chain particles (or one
	// particle's two contacts on different bodies) are handled cleanly
	// regardless of which is static and which is dynamic.
	if (solver.is_null() || p_delta <= 0.0f) {
		return;
	}
	const auto &contacts = environment_probe.get_contacts();
	if (contacts.size() == 0) {
		return;
	}
	PackedVector3Array friction_applied = solver->get_environment_friction_applied();
	int expected = (int)contacts.size() * tentacletech::MAX_CONTACTS_PER_PARTICLE;
	if (friction_applied.size() != expected) {
		return;
	}
	PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
	if (ps == nullptr) {
		return;
	}
	for (uint32_t i = 0; i < contacts.size(); i++) {
		const auto &c = contacts[i];
		if (c.contact_count == 0) continue;

		float inv_mass = solver->get_particle_inv_mass(c.particle_index);
		if (inv_mass <= 0.0f) continue;
		float eff_mass = 1.0f / inv_mass;

		// Slice TT-S3 (§10.5) — suppressed slots have no scratch-array
		// entry (the scratch-build loop in `_run_environment_probe` slides
		// unsuppressed slots forward), so we walk EnvironmentContact in
		// the original order, skip suppressed slots, and re-derive the
		// scratch-array `slot` index from the running unsuppressed count.
		// `friction_applied` is indexed by scratch position, not by
		// EnvironmentContact position.
		int compact_k = 0;
		for (int k = 0; k < c.contact_count; k++) {
			if (c.hit_suppressed[k]) continue;
			if (c.hit_object_id[k] == 0) {
				compact_k++; // still consumed a scratch slot (zeroed RID)
				continue;
			}
			int slot = (int)i * tentacletech::MAX_CONTACTS_PER_PARTICLE + compact_k;
			compact_k++;
			Vector3 fa = friction_applied[slot];
			if (fa.length_squared() < 1e-10f) continue;

			// Effective particle mass mapped through the spec's
			// J = m × Δx / dt. Scaled by `body_impulse_scale` (slice 4F).
			Vector3 impulse = fa * (eff_mass * body_impulse_scale / p_delta);
			if (impulse.length_squared() < 1e-12f) continue;

			// Offset = contact point - body global origin. Need the body
			// Node3D to read its origin. ObjectDB::get_instance returns
			// the typed Object pointer if the ID is still alive.
			Object *obj = ObjectDB::get_instance(ObjectID((uint64_t)c.hit_object_id[k]));
			Node3D *body_node = Object::cast_to<Node3D>(obj);
			Vector3 offset = c.hit_point[k];
			if (body_node != nullptr) {
				offset = c.hit_point[k] - body_node->get_global_position();
			}
			ps->body_apply_impulse(c.hit_rid[k], impulse, offset);
		}
	}
}


void Tentacle::_run_environment_probe() {
	if (solver.is_null()) {
		return;
	}
	if (!environment_probe_enabled) {
		environment_probe.clear();
		solver->clear_environment_contacts();
		_in_contact_this_tick_snapshot.clear();
		return;
	}
	int n = solver->get_particle_count();
	if (n < 2) {
		environment_probe.clear();
		solver->clear_environment_contacts();
		_in_contact_this_tick_snapshot.clear();
		return;
	}
	if (env_position_scratch.size() != n) {
		env_position_scratch.resize(n);
	}
	if (env_girth_scratch.size() != n) {
		env_girth_scratch.resize(n);
	}
	{
		Vector3 *pos_dst = env_position_scratch.ptrw();
		float *girth_dst = env_girth_scratch.ptrw();
		for (int i = 0; i < n; i++) {
			pos_dst[i] = solver->get_particle_position(i);
			girth_dst[i] = solver->get_particle_girth_scale(i);
		}
	}

	environment_probe.probe(this, env_position_scratch, env_girth_scratch,
			particle_collision_radius,
			(uint32_t)environment_collision_layer_mask,
			feature_silhouette_max_outward);

	// Slice 4S.2 — override world hit_point/hit_normal in EnvironmentContact
	// with body-local→world cached values, BEFORE the scratch arrays are
	// built from EnvironmentContact below. Stability win: contact point
	// doesn't flip per-face as the chain slides tangentially across a
	// faceted convex hull. Cache misses drop their entry here; valid
	// entries survive into the scratch-array build and reach the solver.
	_apply_contact_persistence_to_probe_results();

	// Slice TT-S3 (§10.5) — filter type-1 contacts whose hit body belongs
	// to an orifice this tentacle has an active EI with. Runs BEFORE the
	// scratch arrays below so suppressed slots never reach the solver's
	// contact step (their `hit_depth` is zeroed; the `hit_suppressed` flag
	// is preserved for the gizmo). NO-OP when `_active_ei_orifices` is
	// empty — bulk of frames pay only the empty-vector check.
	_apply_contact_suppression();

	// Slice 4M: probe returns up to MAX_CONTACTS_PER_PARTICLE contacts per
	// particle. Pack into 2N flat arrays for the solver, plus an N-byte
	// count array (replaces slice 4D's `active` flag — count == 0 is
	// equivalent to active == 0).
	int slot_count = n * tentacletech::MAX_CONTACTS_PER_PARTICLE;
	if (env_contact_points_scratch.size() != slot_count) {
		env_contact_points_scratch.resize(slot_count);
	}
	if (env_contact_normals_scratch.size() != slot_count) {
		env_contact_normals_scratch.resize(slot_count);
	}
	if (env_contact_count_scratch.size() != n) {
		env_contact_count_scratch.resize(n);
	}
	if (env_contact_rids_scratch.size() != slot_count) {
		env_contact_rids_scratch.resize(slot_count);
	}
	const auto &contacts = environment_probe.get_contacts();
	{
		Vector3 *cp = env_contact_points_scratch.ptrw();
		Vector3 *cn = env_contact_normals_scratch.ptrw();
		uint8_t *cc = env_contact_count_scratch.ptrw();
		int64_t *cr = env_contact_rids_scratch.ptrw();
		for (int i = 0; i < n; i++) {
			int base = i * tentacletech::MAX_CONTACTS_PER_PARTICLE;
			if (i < (int)contacts.size()) {
				const tentacletech::EnvironmentContact &c = contacts[i];
				// Slice TT-S3 (§10.5) — slide unsuppressed slots forward
				// so the solver sees a compact (count, points, normals,
				// rids) tuple with no holes. Suppressed slots have already
				// had their `hit_depth` zeroed and their `hit_suppressed`
				// flag set in `_apply_contact_suppression`; here we
				// translate that into the scratch-array layout the solver
				// reads. The `hit_suppressed` flag stays available on the
				// EnvironmentContact for the gizmo overlay regardless.
				int out_k = 0;
				for (int k = 0; k < c.contact_count; k++) {
					if (c.hit_suppressed[k]) continue;
					cp[base + out_k] = c.hit_point[k];
					cn[base + out_k] = c.hit_normal[k];
					cr[base + out_k] = (int64_t)c.hit_rid[k].get_id();
					out_k++;
				}
				cc[i] = (uint8_t)out_k;
				for (int k = out_k; k < tentacletech::MAX_CONTACTS_PER_PARTICLE; k++) {
					cp[base + k] = Vector3();
					cn[base + k] = Vector3();
					cr[base + k] = 0;
				}
			} else {
				cc[i] = 0;
				for (int k = 0; k < tentacletech::MAX_CONTACTS_PER_PARTICLE; k++) {
					cp[base + k] = Vector3();
					cn[base + k] = Vector3();
					cr[base + k] = 0;
				}
			}
		}
	}
	solver->set_environment_contacts_multi(env_contact_points_scratch,
			env_contact_normals_scratch, env_contact_count_scratch,
			env_contact_rids_scratch);

	// Slice 4S.3 — populate per-slot composed friction from this tick's
	// contact manifold. When at least one body has a `TentacleSurfaceTag`
	// child, forward the materials buffers to the solver; otherwise leave
	// them cleared and the friction step takes the per-tentacle fallback
	// (bit-for-bit equivalent to pre-4S.3 numerics).
	if (_populate_material_slots_from_probe()) {
		solver->set_environment_contact_materials(
				env_contact_static_frictions_scratch,
				env_contact_kinetic_frictions_scratch);
	} else {
		// No tagged bodies in this substep — make sure any per-slot
		// values from an earlier substep (within the same outer tick)
		// don't leak through. Safe regardless of whether the previous
		// substep saw a tag.
		solver->clear_environment_contact_materials();
	}

	// Slice 4N — write the fresh-this-tick snapshot now (after the probe,
	// before solver->tick). Behaviour drivers running their
	// _physics_process AFTER the tentacle's pick up THIS tick's contacts;
	// drivers running before fall back to last-tick semantics — same as
	// the solver-side accessor.
	if (_in_contact_this_tick_snapshot.size() != n) {
		_in_contact_this_tick_snapshot.resize(n);
	}
	{
		const uint8_t *src = env_contact_count_scratch.ptr();
		uint8_t *dst = _in_contact_this_tick_snapshot.ptrw();
		for (int i = 0; i < n; i++) {
			dst[i] = (src[i] > 0) ? 1 : 0;
		}
	}
}

void Tentacle::_apply_contact_persistence_to_probe_results() {
	// Slice 4S.2 — runs inside _run_environment_probe AFTER probe.probe()
	// populates EnvironmentContact slots but BEFORE the scratch arrays are
	// written from those contacts. Mutates the EnvironmentContact array
	// in-place: for each (particle, probe_slot) whose hit_rid matches a
	// valid cached slot AND whose particle is within hysteresis of the
	// body-local→world cached point, REPLACE hit_point/hit_normal with
	// the cached body-local→world values. For cached slots whose body
	// doesn't appear in this tick's probe results for the same particle,
	// drop the cache slot (next reseed will see valid=false and not
	// inject lambdas — slot starts cold).
	if (!contact_persistence_enabled) return;
	if (solver.is_null()) return;
	auto &contacts = environment_probe.get_contacts_mut();
	int n = (int)contacts.size();
	if (n == 0) return;
	if ((int)persistence_buffer.size() <
			n * tentacletech::MAX_CONTACTS_PER_PARTICLE) {
		// Buffer not yet sized (rebuild_chain not called) — skip.
		return;
	}
	float radius_base = particle_collision_radius;
	float hysteresis_radius = radius_base * 0.5f *
			contact_persistence_radius_factor;
	float hysteresis_radius_sq = hysteresis_radius * hysteresis_radius;

	for (int i = 0; i < n; i++) {
		auto &c = contacts[i];
		int base = i * tentacletech::MAX_CONTACTS_PER_PARTICLE;
		// Track which probe slots we've matched a cache entry to (so two
		// cached slots can't both claim the same probe slot).
		bool probe_slot_claimed[tentacletech::MAX_CONTACTS_PER_PARTICLE] = {};
		for (int ck = 0; ck < tentacletech::MAX_CONTACTS_PER_PARTICLE; ck++) {
			PersistedContactSlot &cached = persistence_buffer[base + ck];
			if (!cached.valid) continue;
			// Resolve cached body.
			Object *body_obj = ObjectDB::get_instance(
					ObjectID((uint64_t)cached.body_object_id));
			if (body_obj == nullptr) {
				cached.valid = false;
				continue;
			}
			Node3D *body_node = Object::cast_to<Node3D>(body_obj);
			if (body_node == nullptr) {
				cached.valid = false;
				continue;
			}
			Transform3D body_xform = body_node->get_global_transform();
			Vector3 cached_world_point = body_xform.xform(cached.body_local_point);
			Vector3 cached_world_normal = body_xform.basis.xform(cached.body_local_normal);
			float l2 = cached_world_normal.length_squared();
			if (l2 > 1e-10f) {
				cached_world_normal /= Math::sqrt(l2);
			}
			// Find a probe slot referencing the same body.
			int matched_pk = -1;
			for (int pk = 0; pk < c.contact_count; pk++) {
				if (probe_slot_claimed[pk]) continue;
				if (c.hit_object_id[pk] == cached.body_object_id) {
					matched_pk = pk;
					break;
				}
			}
			if (matched_pk < 0) {
				// Cached body not in this tick's probe results for this
				// particle — drop. (The brief's "perf win" path of
				// inserting cached body into an empty slot without probe
				// confirmation is deferred; per Phase Log spec divergence
				// (d) we keep probe firing for every slot this slice.)
				cached.valid = false;
				continue;
			}
			// Hysteresis check: probe's new world hit_point must be close
			// to the cached body-local→world point. Measures how far the
			// contact has slid along the body's surface since cache
			// capture. If the slide exceeds `hysteresis_radius`, the cache
			// is no longer a good stand-in for the current contact —
			// drop and let the fresh probe own the slot. This is the
			// pre-fix-2026-05-06 mistake corrected: previously the check
			// compared particle position to surface contact point, which
			// is always ≈ collision_radius and produced no useful signal.
			float dsq = (c.hit_point[matched_pk] - cached_world_point).length_squared();
			if (dsq > hysteresis_radius_sq) {
				cached.valid = false;
				continue;
			}
			probe_slot_claimed[matched_pk] = true;
			c.hit_point[matched_pk] = cached_world_point;
			c.hit_normal[matched_pk] = cached_world_normal;
			c.hit_object_id[matched_pk] = cached.body_object_id;
			c.hit_rid[matched_pk] = cached.body_rid;
		}
	}
}

// Slice 4S.3 — resolve a body's `TentacleSurfaceTag`, memoising the result
// in `_material_cache_this_tick` for the remainder of this outer tick.
// On cache miss, walks `body->find_children("*", "TentacleSurfaceTag",
// true, false)` and reads the tag's `material` @export. WARN_PRINT fires
// when find returns >1 match — one tag per body is the 4S.3 constraint;
// the first match is taken.
const Tentacle::CachedSurfaceMaterial *Tentacle::_resolve_surface_material_for_body(
		uint64_t p_body_object_id, Object *p_body_obj) {
	if (p_body_object_id == 0 || p_body_obj == nullptr) {
		return nullptr;
	}
	for (size_t i = 0; i < _material_cache_this_tick.size(); i++) {
		if (_material_cache_this_tick[i].body_object_id == p_body_object_id) {
			return &_material_cache_this_tick[i];
		}
	}
	CachedSurfaceMaterial entry;
	entry.body_object_id = p_body_object_id;
	Node *body_node = Object::cast_to<Node>(p_body_obj);
	if (body_node != nullptr) {
		TypedArray<Node> matches = body_node->find_children(
				String("*"), String("TentacleSurfaceTag"), true, false);
		if (matches.size() > 1) {
			WARN_PRINT(vformat(
					"TentacleSurfaceTag: %d matches on body '%s'; "
					"only one tag per body is supported in 4S.3 — using first.",
					matches.size(), body_node->get_name()));
		}
		if (matches.size() > 0) {
			Node *tag = Object::cast_to<Node>(matches[0]);
			if (tag != nullptr) {
				Variant mat_v = tag->get(StringName("material"));
				if (mat_v.get_type() == Variant::OBJECT) {
					Object *mat_obj = (Object *)mat_v;
					if (mat_obj != nullptr) {
						Variant s = mat_obj->get(StringName("static_friction"));
						Variant d = mat_obj->get(StringName("dynamic_friction"));
						Variant fc = mat_obj->get(StringName("friction_combine"));
						entry.has_material = true;
						entry.static_friction = (float)s;
						entry.dynamic_friction = (float)d;
						entry.friction_combine = (int)fc;
					}
				}
			}
		}
	}
	_material_cache_this_tick.push_back(entry);
	return &_material_cache_this_tick.back();
}

// Slice 4S.3 — fill `env_contact_*_frictions_scratch` from this tick's
// contact manifold. Walks each particle's per-slot contacts; for each
// body that has a `TentacleSurfaceTag` child, composes
// (tentacle_implicit, body_material) via `PBDSolver::compose_friction_materials`
// and writes the per-slot μ_s / μ_k. Returns true iff at least one slot
// resolved to a tagged body — when false, the caller leaves
// `set_environment_contact_materials` uninvoked so the solver's
// friction step takes the per-tentacle fallback (bit-for-bit equivalent
// to the pre-4S.3 path).
//
// Tentacle implicit material is `(friction_static, friction_static ×
// kinetic_ratio, AVERAGE = 0)`. `friction_static` is already the
// post-lubricity value (slice 4B: `set_friction(base × (1 − lub), …)`),
// so per-slot composition naturally inherits the tentacle's current
// modulator state.
bool Tentacle::_populate_material_slots_from_probe() {
	if (solver.is_null()) return false;
	int n = solver->get_particle_count();
	int slot_count = n * tentacletech::MAX_CONTACTS_PER_PARTICLE;
	if (slot_count <= 0) return false;
	const auto &contacts = environment_probe.get_contacts();
	if (contacts.size() == 0) return false;

	float tentacle_mu_s = solver->get_static_friction();
	float tentacle_mu_k = tentacle_mu_s * solver->get_kinetic_friction_ratio();
	const int TENTACLE_COMBINE = 0; // AVERAGE — see TentacleCollisionMaterial doc.

	if (env_contact_static_frictions_scratch.size() != slot_count) {
		env_contact_static_frictions_scratch.resize(slot_count);
	}
	if (env_contact_kinetic_frictions_scratch.size() != slot_count) {
		env_contact_kinetic_frictions_scratch.resize(slot_count);
	}
	float *mu_s_dst = env_contact_static_frictions_scratch.ptrw();
	float *mu_k_dst = env_contact_kinetic_frictions_scratch.ptrw();
	// Pre-fill with tentacle-implicit values so unused slots and no-tag
	// bodies all read consistent fallback μ. (The solver-side fallback
	// branch reads per-tentacle scalars from `friction_static` instead;
	// per-slot defaults are written here for parity when ANY tag exists,
	// so the friction step doesn't see a per-slot mu of 0 = "skip" for
	// no-tag bodies.)
	for (int s = 0; s < slot_count; s++) {
		mu_s_dst[s] = tentacle_mu_s;
		mu_k_dst[s] = tentacle_mu_k;
	}

	bool any_tag = false;
	int contact_n = (int)contacts.size();
	for (int i = 0; i < n && i < contact_n; i++) {
		const tentacletech::EnvironmentContact &c = contacts[i];
		if (c.contact_count == 0) continue;
		int base = i * tentacletech::MAX_CONTACTS_PER_PARTICLE;
		for (int k = 0; k < c.contact_count; k++) {
			uint64_t body_oid = c.hit_object_id[k];
			if (body_oid == 0) continue;
			Object *body_obj = ObjectDB::get_instance(ObjectID(body_oid));
			if (body_obj == nullptr) continue;
			const CachedSurfaceMaterial *mat =
					_resolve_surface_material_for_body(body_oid, body_obj);
			if (mat == nullptr || !mat->has_material) continue;
			Vector2 composed = PBDSolver::compose_friction_materials(
					tentacle_mu_s, tentacle_mu_k, TENTACLE_COMBINE,
					mat->static_friction, mat->dynamic_friction, mat->friction_combine);
			mu_s_dst[base + k] = composed.x;
			mu_k_dst[base + k] = composed.y;
			any_tag = true;
		}
	}
	return any_tag;
}

void Tentacle::_validate_and_reseed_persistence() {
	// Slice 4S.2 — outer-tick boundary, after solver->reset_friction_applied()
	// and solver->reset_environment_contact_lambdas() have fired. For each
	// cached slot: confirm body still alive, transform hasn't jumped past
	// threshold. Valid slots survive into _apply_contact_persistence_to_probe_results
	// (which runs per-substep) and override the probe's world contact point
	// with the body-local→world transformed cached value.
	//
	// LAMBDA PERSISTENCE INTENTIONALLY DROPPED — see spec divergence (a) in
	// the 4S.2 PHASE_LOG entry: warm-starting lambdas across outer ticks
	// recreates the taper-feedback oscillation that 4R reverted the substep
	// flip for (warm tlam at the cone boundary → tlam/cone at saturation
	// from iter 0 → taper kills target pull → cone collapses → contacts
	// lost → chain slams in). The 4S.2 stability win is the CONTACT POINT
	// stability (kills per-face hit_point churn on faceted hulls); lambdas
	// continue to reset every outer tick per the 4R invariant.
	if (solver.is_null()) return;
	int n = solver->get_particle_count();
	int expected = n * tentacletech::MAX_CONTACTS_PER_PARTICLE;
	if ((int)persistence_buffer.size() != expected) {
		persistence_buffer.assign((size_t)expected, PersistedContactSlot());
	}
	if (persistence_invalidation_count_snapshot.size() != n) {
		persistence_invalidation_count_snapshot.resize(n);
	}
	// Zero the invalidation counter at outer-tick start; only this tick's
	// invalidations populate it.
	for (int i = 0; i < n; i++) {
		persistence_invalidation_count_snapshot.set(i, 0);
	}
	if (!contact_persistence_enabled) {
		// Cleared so a toggle-off run doesn't leave stale cached state
		// influencing the next toggle-on run.
		for (size_t i = 0; i < persistence_buffer.size(); i++) {
			persistence_buffer[i] = PersistedContactSlot();
		}
		return;
	}
	float radius_base = particle_collision_radius;
	float jump_threshold = radius_base * 2.0f *
			contact_persistence_jump_threshold_factor;
	float jump_threshold_sq = jump_threshold * jump_threshold;

	for (int i = 0; i < n; i++) {
		int base = i * tentacletech::MAX_CONTACTS_PER_PARTICLE;
		int invalidations_this_particle = 0;
		for (int k = 0; k < tentacletech::MAX_CONTACTS_PER_PARTICLE; k++) {
			PersistedContactSlot &cached = persistence_buffer[base + k];
			if (!cached.valid) continue;
			Object *body_obj = ObjectDB::get_instance(
					ObjectID((uint64_t)cached.body_object_id));
			if (body_obj == nullptr) {
				cached.valid = false;
				invalidations_this_particle++;
				continue;
			}
			Node3D *body_node = Object::cast_to<Node3D>(body_obj);
			if (body_node == nullptr) {
				cached.valid = false;
				invalidations_this_particle++;
				continue;
			}
			Transform3D current_xform = body_node->get_global_transform();
			Vector3 origin_delta = current_xform.origin - cached.cached_body_xform.origin;
			if (origin_delta.length_squared() > jump_threshold_sq) {
				// Body teleported — invalidate; let the fresh probe own
				// this slot.
				cached.valid = false;
				invalidations_this_particle++;
				continue;
			}
			// Survived all checks — slot stays valid; the per-substep
			// _apply_contact_persistence_to_probe_results step will use
			// it to override world contact point/normal.
		}
		if (invalidations_this_particle > 0) {
			persistence_invalidation_count_snapshot.set(i,
					persistence_invalidation_count_snapshot[i]
							+ invalidations_this_particle);
		}
	}
}

void Tentacle::_snapshot_persistence_post_tick() {
	// Slice 4S.2 — runs ONCE per outer tick after the last substep's
	// solver->tick(sub_dt) completes. Reads the live last-substep
	// EnvironmentContact array (post any _apply_contact_persistence_to_probe_results
	// overrides) and stores world contact point/normal in body-local frame
	// so next tick's reseed can re-apply them via _apply_contact_persistence_to_probe_results.
	// Lambdas are NOT persisted (see _validate_and_reseed_persistence
	// rationale — would recreate the 4R taper-feedback oscillation).
	if (!contact_persistence_enabled) return;
	if (solver.is_null()) return;
	int n = solver->get_particle_count();
	int expected = n * tentacletech::MAX_CONTACTS_PER_PARTICLE;
	if ((int)persistence_buffer.size() != expected) return;
	const auto &contacts = environment_probe.get_contacts();
	int contact_count_n = (int)contacts.size();

	for (int i = 0; i < n; i++) {
		int base = i * tentacletech::MAX_CONTACTS_PER_PARTICLE;
		const tentacletech::EnvironmentContact *c =
				(i < contact_count_n) ? &contacts[i] : nullptr;
		int active_count = (c != nullptr) ? c->contact_count : 0;

		for (int k = 0; k < tentacletech::MAX_CONTACTS_PER_PARTICLE; k++) {
			int slot = base + k;
			PersistedContactSlot &cached = persistence_buffer[slot];
			if (k >= active_count || c == nullptr) {
				// Slot inactive this tick — clear cache.
				cached.valid = false;
				continue;
			}
			Vector3 world_point = c->hit_point[k];
			Vector3 world_normal = c->hit_normal[k];
			uint64_t body_oid = c->hit_object_id[k];
			godot::RID body_rid = c->hit_rid[k];
			if (body_oid == 0) {
				cached.valid = false;
				continue;
			}
			Object *body_obj = ObjectDB::get_instance(ObjectID(body_oid));
			Node3D *body_node = (body_obj != nullptr)
					? Object::cast_to<Node3D>(body_obj) : nullptr;
			if (body_node == nullptr) {
				cached.valid = false;
				continue;
			}
			Transform3D body_xform = body_node->get_global_transform();
			Transform3D body_inv = body_xform.affine_inverse();
			cached.valid = true;
			cached.body_local_point = body_inv.xform(world_point);
			cached.body_local_normal = body_inv.basis.xform(world_normal);
			cached.cached_body_xform = body_xform;
			cached.body_rid = body_rid;
			cached.body_object_id = body_oid;
			// Lambdas not persisted across outer ticks (spec divergence
			// (a)); these fields stay at default 0.
			cached.persisted_normal_lambda = 0.0f;
			cached.persisted_tangent_lambda = Vector3();
		}
	}
}

void Tentacle::_notification(int p_what) {
	// Editor-only: rebuild the chain at every plausible moment so the static
	// rest-pose visual reflects the current node transform. GDExtension's
	// _ready timing at edit time isn't fully reliable (the child overlay's
	// _ready can fire before the parent's get_global_transform() resolves
	// to the cascaded value), so we also rebuild on ENTER_TREE and on every
	// transform change. Runtime uses tick()/set_anchor() each physics step
	// instead, so these notifications are explicitly editor-gated.
	if (!Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	switch (p_what) {
		case NOTIFICATION_ENTER_TREE:
			set_notify_transform(true);
			rebuild_chain();
			break;
		case NOTIFICATION_TRANSFORM_CHANGED:
			if (is_inside_tree()) {
				rebuild_chain();
			}
			break;
		default:
			break;
	}
}

// -- Configuration ----------------------------------------------------------

void Tentacle::set_particle_count(int p_count) {
	if (p_count < 2) p_count = 2;
	if (p_count == particle_count) return;
	particle_count = p_count;
	// Recompute segment_length from the assigned mesh's length BEFORE the
	// rebuild so the freshly-laid chain uses the right per-segment rest.
	_apply_mesh_length_to_segment_length();
	rebuild_chain();
}
int Tentacle::get_particle_count() const { return particle_count; }

void Tentacle::set_segment_length(float p_l) {
	if (p_l < 1e-4f) p_l = 1e-4f;
	if (Math::is_equal_approx(p_l, segment_length)) return;
	segment_length = p_l;
	if (solver.is_null()) {
		return;
	}
	// In editor or before the node is in the tree: snap to the new rest pose
	// so the static visual reflects the change immediately. At runtime: just
	// update the rest lengths in place — the distance constraints converge
	// over a few iterations without a visible reset.
	if (!is_inside_tree() || Engine::get_singleton()->is_editor_hint()) {
		rebuild_chain();
	} else {
		solver->set_uniform_rest_length(segment_length);
	}
}
float Tentacle::get_segment_length() const { return segment_length; }

// Solver-tuning passthroughs --------------------------------------------------

void Tentacle::set_iteration_count(int p_i) {
	if (solver.is_valid()) solver->set_iteration_count(p_i);
}
int Tentacle::get_iteration_count() const {
	return solver.is_valid() ? solver->get_iteration_count() : PBDSolver::DEFAULT_ITERATION_COUNT;
}

void Tentacle::set_gravity(const Vector3 &p_g) {
	if (solver.is_valid()) solver->set_gravity(p_g);
}
Vector3 Tentacle::get_gravity() const {
	return solver.is_valid() ? solver->get_gravity() : Vector3(0.0f, -9.8f, 0.0f);
}

void Tentacle::set_damping(float p_d) {
	if (solver.is_valid()) solver->set_damping(p_d);
}
float Tentacle::get_damping() const {
	return solver.is_valid() ? solver->get_damping() : PBDSolver::DEFAULT_DAMPING;
}

void Tentacle::set_distance_stiffness(float p_s) {
	if (solver.is_valid()) solver->set_distance_stiffness(p_s);
}
float Tentacle::get_distance_stiffness() const {
	return solver.is_valid() ? solver->get_distance_stiffness() : PBDSolver::DEFAULT_DISTANCE_STIFFNESS;
}

void Tentacle::set_bending_stiffness(float p_s) {
	if (solver.is_valid()) solver->set_bending_stiffness(p_s);
}
float Tentacle::get_bending_stiffness() const {
	return solver.is_valid() ? solver->get_bending_stiffness() : PBDSolver::DEFAULT_BENDING_STIFFNESS;
}

void Tentacle::set_asymmetry_recovery_rate(float p_r) {
	if (solver.is_valid()) solver->set_asymmetry_recovery_rate(p_r);
}
float Tentacle::get_asymmetry_recovery_rate() const {
	return solver.is_valid() ? solver->get_asymmetry_recovery_rate() : PBDSolver::DEFAULT_ASYMMETRY_RECOVERY_RATE;
}

void Tentacle::set_base_angular_velocity_limit(float p_omega) {
	if (solver.is_valid()) solver->set_base_angular_velocity_limit(p_omega);
}
float Tentacle::get_base_angular_velocity_limit() const {
	return solver.is_valid() ? solver->get_base_angular_velocity_limit() : PBDSolver::DEFAULT_BASE_ANGULAR_VELOCITY_LIMIT;
}

void Tentacle::set_rigid_base_count(int p_count) {
	if (solver.is_valid()) solver->set_rigid_base_count(p_count);
	// Re-issue the anchor so the newly-pinned particles snap to the
	// captured local offsets immediately, without waiting for the next
	// transform-changed notification.
	if (solver.is_valid() && solver->has_anchor()) {
		solver->set_anchor(solver->get_anchor_particle_index(), solver->get_anchor_transform());
	}
}
int Tentacle::get_rigid_base_count() const {
	return solver.is_valid() ? solver->get_rigid_base_count() : 1;
}

void Tentacle::rebuild_chain() {
	if (solver.is_null()) {
		solver.instantiate();
	}
	// `initialize_chain` resets `rigid_base_count` to 1 and discards the
	// captured offsets. Snapshot the authored value before the reset so we
	// can re-pin the right block after the chain is laid out in the new
	// anchor frame; otherwise scene-load clobbers the .tscn property and
	// only runtime edits stick.
	int desired_rigid = solver->get_rigid_base_count();
	solver->initialize_chain(particle_count, segment_length);
	// Lay the freshly-built chain along the node's current world frame so it
	// emerges from the node's -Z, not at world-origin.
	Transform3D xform = is_inside_tree() ? get_global_transform() : Transform3D();
	for (int i = 0; i < particle_count; i++) {
		Vector3 local(0.0f, 0.0f, -segment_length * (float)i);
		solver->set_particle_position(i, xform.xform(local));
	}
	solver->set_anchor(0, xform);
	if (desired_rigid > 1) {
		solver->set_rigid_base_count(desired_rigid);
	}
	anchor_override = false;

	// Slice 4S.2 — resize persistence buffer + per-particle invalidation
	// counter. Cache content is discarded on rebuild (chain has changed
	// shape; old body-local points no longer correspond to particles
	// anywhere reasonable). `valid=false` default-initializes via the
	// struct's defaults.
	persistence_buffer.assign(
			(size_t)(particle_count * tentacletech::MAX_CONTACTS_PER_PARTICLE),
			PersistedContactSlot());
	persistence_invalidation_count_snapshot.resize(particle_count);
	for (int i = 0; i < particle_count; i++) {
		persistence_invalidation_count_snapshot.set(i, 0);
	}

	// Particle count may have changed; resize the per-tick buffers and the
	// data texture to match the new chain. Safe to call before _ready (does
	// nothing if the texture isn't allocated yet) and re-runs from _ready.
	_allocate_render_resources();
	_update_spline_data_texture();
}

// -- Target pull ------------------------------------------------------------

void Tentacle::set_target(const Vector3 &p_pos) {
	if (solver.is_null()) return;
	int idx = solver->has_target() ? solver->get_target_particle_index()
									: solver->get_particle_count() - 1;
	float stiff = solver->has_target() ? solver->get_target_stiffness()
									   : PBDSolver::DEFAULT_TARGET_STIFFNESS;
	solver->set_target(idx, p_pos, stiff);
}

void Tentacle::clear_target() {
	if (solver.is_null()) return;
	solver->clear_target();
}

void Tentacle::set_target_stiffness(float p_s) {
	if (solver.is_null() || !solver->has_target()) {
		// No active target → nothing to update. Caller must set_target() first.
		return;
	}
	solver->set_target(solver->get_target_particle_index(),
			solver->get_target_position(), p_s);
}
float Tentacle::get_target_stiffness() const {
	if (solver.is_null() || !solver->has_target()) {
		return PBDSolver::DEFAULT_TARGET_STIFFNESS;
	}
	return solver->get_target_stiffness();
}

void Tentacle::set_target_particle_index(int p_idx) {
	if (solver.is_null() || !solver->has_target()) return;
	solver->set_target(p_idx, solver->get_target_position(), solver->get_target_stiffness());
}
int Tentacle::get_target_particle_index() const {
	if (solver.is_null() || !solver->has_target()) return -1;
	return solver->get_target_particle_index();
}

// -- Pose targets (multi-particle distributed pull) -------------------------

void Tentacle::set_pose_targets(const PackedInt32Array &p_indices,
		const PackedVector3Array &p_world_positions,
		const PackedFloat32Array &p_stiffnesses) {
	if (solver.is_null()) return;
	solver->set_pose_targets(p_indices, p_world_positions, p_stiffnesses);
}

void Tentacle::clear_pose_targets() {
	if (solver.is_null()) return;
	solver->clear_pose_targets();
}

int Tentacle::get_pose_target_count() const {
	if (solver.is_null()) return 0;
	return solver->get_pose_target_count();
}

// -- Anchor override --------------------------------------------------------

void Tentacle::set_anchor_transform(const Transform3D &p_x) {
	if (solver.is_null()) return;
	solver->set_anchor(0, p_x);
	anchor_override = true;
}

void Tentacle::clear_anchor_override() {
	anchor_override = false;
}

// -- Solver access ----------------------------------------------------------

Ref<PBDSolver> Tentacle::get_solver() const { return solver; }

// Slice 5C-A — external position-delta intake. Routes through the chain
// solver's Jacobi accumulator + apply pass so type-2 (and later type-3,
// type-5+) contact sources can push particles without zeroing the
// implicit Verlet velocity that `set_particle_position` would.
void Tentacle::add_external_position_delta(int p_particle_index, const Vector3 &p_delta) {
	if (solver.is_null()) return;
	solver->add_external_position_delta(p_particle_index, p_delta);
}

void Tentacle::flush_external_position_deltas() {
	if (solver.is_null()) return;
	solver->apply_external_position_deltas();
}

// -- Slice TT-S3 (§10.5) active-EI orifice registry -----------------------

void Tentacle::register_active_ei_orifice(Orifice *p_orifice) {
	if (p_orifice == nullptr) return;
	for (size_t i = 0; i < _active_ei_orifices.size(); i++) {
		if (_active_ei_orifices[i] == p_orifice) return; // idempotent
	}
	_active_ei_orifices.push_back(p_orifice);
}

void Tentacle::unregister_active_ei_orifice(Orifice *p_orifice) {
	if (p_orifice == nullptr) return;
	for (size_t i = 0; i < _active_ei_orifices.size(); i++) {
		if (_active_ei_orifices[i] == p_orifice) {
			// Swap-pop: order doesn't matter for the filter pass.
			_active_ei_orifices[i] = _active_ei_orifices.back();
			_active_ei_orifices.pop_back();
			return;
		}
	}
}

int Tentacle::get_active_ei_orifice_count() const {
	return (int)_active_ei_orifices.size();
}

void Tentacle::_apply_contact_suppression() {
	// Slice TT-S3 (§10.5) — for every EnvironmentContact slot whose
	// `hit_object_id` is in the suppression set of ANY orifice this
	// tentacle has an active EI with, mark the slot suppressed and zero
	// its `hit_depth`. The slot's `contact_count` is intentionally left
	// alone — the solver projects on depth (and depth == 0 → no push),
	// and the gizmo overlay needs to see the slot as "present but
	// suppressed" to render the cyan X marker.
	//
	// Capsule path only: the slot's `hit_object_id` is treated as a
	// capsule body. Proxy-path dispatch (body_field tet body) is
	// orthogonal and gated on body_field B5; the proxy filter would
	// live alongside this loop once it lands.
	if (_active_ei_orifices.empty()) return;
	auto &contacts = environment_probe.get_contacts_mut();
	int n = (int)contacts.size();
	if (n == 0) return;

	for (int i = 0; i < n; i++) {
		auto &c = contacts[i];
		if (c.contact_count == 0) continue;
		for (int k = 0; k < c.contact_count; k++) {
			uint64_t oid = c.hit_object_id[k];
			if (oid == 0) continue;
			// Walk the (small) active-EI orifice set; first match wins.
			for (size_t o = 0; o < _active_ei_orifices.size(); o++) {
				Orifice *orf = _active_ei_orifices[o];
				if (orf == nullptr) continue;
				if (orf->is_object_id_suppressed(oid)) {
					c.hit_suppressed[k] = true;
					c.hit_depth[k] = 0.0f;
					break;
				}
			}
			// TODO §10.5 proxy path: when body_field B5 ships, dispatch
			// here on `oid == <proxy tet body RID>` → look up the
			// dominant skin-weighted bone of the contact face via
			// `BodyField::get_face_dominant_bone(hit_point)` and check
			// it against the orifice's suppressed-bone set (string or
			// ID-resolved). For now the capsule path above covers every
			// body in the scene since the proxy body isn't constructed.
		}
	}
}

// Slice 5C-C — chain-arc-length sampling helpers. `s` walks the chain
// rest-length array to find the containing segment, then interpolates.
// Both helpers clamp into the valid range so callers don't have to
// guard against overshoot — the §6.3 wedge math still works on a clamped
// sample, just with zero gradient at the tip.
float Tentacle::get_total_chain_arc_length() const {
	if (solver.is_null()) return 0.0f;
	int seg_count = solver->get_segment_count();
	float total = 0.0f;
	for (int i = 0; i < seg_count; i++) {
		total += solver->get_rest_length(i);
	}
	return total;
}

float Tentacle::get_signed_girth_gradient_at_arc_length(float p_s) const {
	if (solver.is_null()) return 0.0f;
	int seg_count = solver->get_segment_count();
	if (seg_count <= 0) return 0.0f;
	float arc = 0.0f;
	for (int i = 0; i < seg_count; i++) {
		float seg_len = solver->get_rest_length(i);
		if (p_s <= arc + seg_len || i == seg_count - 1) {
			if (seg_len < 1e-8f) return 0.0f;
			float r_a = particle_collision_radius * solver->get_particle_girth_scale(i);
			float r_b = particle_collision_radius * solver->get_particle_girth_scale(i + 1);
			return (r_b - r_a) / seg_len;
		}
		arc += seg_len;
	}
	return 0.0f;
}

Vector3 Tentacle::get_tangent_at_arc_length(float p_s) const {
	if (solver.is_null()) return Vector3(0.0f, 0.0f, 1.0f);
	int seg_count = solver->get_segment_count();
	if (seg_count <= 0) return Vector3(0.0f, 0.0f, 1.0f);
	float arc = 0.0f;
	for (int i = 0; i < seg_count; i++) {
		float seg_len = solver->get_rest_length(i);
		if (p_s <= arc + seg_len || i == seg_count - 1) {
			Vector3 a = solver->get_particle_position(i);
			Vector3 b = solver->get_particle_position(i + 1);
			Vector3 d = b - a;
			float dl = d.length();
			if (dl < 1e-8f) return Vector3(0.0f, 0.0f, 1.0f);
			return d / dl;
		}
		arc += seg_len;
	}
	return Vector3(0.0f, 0.0f, 1.0f);
}

// -- Snapshots --------------------------------------------------------------

PackedVector3Array Tentacle::get_particle_positions() const {
	if (solver.is_null()) return PackedVector3Array();
	return solver->get_particle_positions();
}

PackedFloat32Array Tentacle::get_particle_inv_masses() const {
	if (solver.is_null()) return PackedFloat32Array();
	return solver->get_particle_inv_masses();
}

PackedFloat32Array Tentacle::get_segment_stretch_ratios() const {
	if (solver.is_null()) return PackedFloat32Array();
	return solver->get_segment_stretch_ratios();
}

Dictionary Tentacle::get_target_pull_state() const {
	Dictionary d;
	if (solver.is_null() || !solver->has_target()) {
		d["active"] = false;
		d["target"] = Vector3();
		d["particle_index"] = -1;
		d["force_dir"] = Vector3();
		return d;
	}
	int idx = solver->get_target_particle_index();
	Vector3 target = solver->get_target_position();
	Vector3 from = solver->get_particle_position(idx);
	Vector3 dir = target - from;
	float len = dir.length();
	if (len > 1e-6f) {
		dir = dir / len;
	} else {
		dir = Vector3();
	}
	d["active"] = true;
	d["target"] = target;
	d["particle_index"] = idx;
	d["force_dir"] = dir;
	return d;
}

// -- Environment probe ------------------------------------------------------

void Tentacle::set_environment_probe_enabled(bool p_enabled) {
	environment_probe_enabled = p_enabled;
	if (!p_enabled && solver.is_valid()) {
		solver->clear_environment_contacts();
	}
}
bool Tentacle::get_environment_probe_enabled() const { return environment_probe_enabled; }

void Tentacle::set_environment_probe_distance(float p_d) {
	if (p_d < 1e-4f) p_d = 1e-4f;
	environment_probe_distance = p_d;
}
float Tentacle::get_environment_probe_distance() const { return environment_probe_distance; }

void Tentacle::set_environment_collision_layer_mask(int p_mask) {
	environment_collision_layer_mask = p_mask;
}
int Tentacle::get_environment_collision_layer_mask() const { return environment_collision_layer_mask; }

void Tentacle::set_particle_collision_radius(float p_r) {
	if (p_r < 0.0f) p_r = 0.0f;
	particle_collision_radius = p_r;
	if (solver.is_valid()) {
		solver->set_collision_radius(p_r);
	}
}
float Tentacle::get_particle_collision_radius() const { return particle_collision_radius; }

void Tentacle::set_base_static_friction(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	base_static_friction = p_v;
	if (solver.is_valid()) {
		solver->set_friction(base_static_friction * (1.0f - tentacle_lubricity),
				kinetic_friction_ratio);
	}
}
float Tentacle::get_base_static_friction() const { return base_static_friction; }

void Tentacle::set_tentacle_lubricity(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	if (p_v > 1.0f) p_v = 1.0f;
	tentacle_lubricity = p_v;
	if (solver.is_valid()) {
		solver->set_friction(base_static_friction * (1.0f - tentacle_lubricity),
				kinetic_friction_ratio);
	}
}
float Tentacle::get_tentacle_lubricity() const { return tentacle_lubricity; }

void Tentacle::set_kinetic_friction_ratio(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	if (p_v > 1.0f) p_v = 1.0f;
	kinetic_friction_ratio = p_v;
	if (solver.is_valid()) {
		solver->set_friction(base_static_friction * (1.0f - tentacle_lubricity),
				kinetic_friction_ratio);
	}
}
float Tentacle::get_kinetic_friction_ratio() const { return kinetic_friction_ratio; }

void Tentacle::set_contact_stiffness(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	if (p_v > 1.0f) p_v = 1.0f;
	contact_stiffness = p_v;
	if (solver.is_valid()) {
		solver->set_contact_stiffness(p_v);
	}
}
float Tentacle::get_contact_stiffness() const { return contact_stiffness; }

void Tentacle::set_target_softness_when_blocked(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	if (p_v > 1.0f) p_v = 1.0f;
	target_softness_when_blocked = p_v;
	if (solver.is_valid()) {
		solver->set_target_softness_when_blocked(p_v);
	}
}
float Tentacle::get_target_softness_when_blocked() const {
	return target_softness_when_blocked;
}

void Tentacle::set_tension_taper_threshold(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	if (p_v > 1.0f) p_v = 1.0f;
	tension_taper_threshold = p_v;
	if (solver.is_valid()) {
		solver->set_tension_taper_threshold(p_v);
	}
}
float Tentacle::get_tension_taper_threshold() const {
	return tension_taper_threshold;
}

void Tentacle::set_target_velocity_max(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	target_velocity_max = p_v;
	if (solver.is_valid()) {
		solver->set_target_velocity_max(p_v);
	}
}
float Tentacle::get_target_velocity_max() const {
	return target_velocity_max;
}

void Tentacle::set_contact_persistence_enabled(bool p_enabled) {
	contact_persistence_enabled = p_enabled;
}
bool Tentacle::get_contact_persistence_enabled() const {
	return contact_persistence_enabled;
}

void Tentacle::set_contact_persistence_radius_factor(float p_factor) {
	if (p_factor < 0.0f) p_factor = 0.0f;
	contact_persistence_radius_factor = p_factor;
}
float Tentacle::get_contact_persistence_radius_factor() const {
	return contact_persistence_radius_factor;
}

void Tentacle::set_contact_persistence_jump_threshold_factor(float p_factor) {
	if (p_factor < 0.0f) p_factor = 0.0f;
	contact_persistence_jump_threshold_factor = p_factor;
}
float Tentacle::get_contact_persistence_jump_threshold_factor() const {
	return contact_persistence_jump_threshold_factor;
}

PackedInt32Array Tentacle::get_persistence_invalidation_count_snapshot() const {
	return persistence_invalidation_count_snapshot;
}

void Tentacle::set_sor_factor(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	if (p_v > 4.0f) p_v = 4.0f;
	sor_factor = p_v;
	if (solver.is_valid()) {
		solver->set_sor_factor(p_v);
	}
}
float Tentacle::get_sor_factor() const { return sor_factor; }

void Tentacle::set_max_depenetration(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	max_depenetration = p_v;
	if (solver.is_valid()) {
		solver->set_max_depenetration(p_v);
	}
}
float Tentacle::get_max_depenetration() const { return max_depenetration; }

void Tentacle::set_sleep_threshold(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	sleep_threshold = p_v;
	if (solver.is_valid()) {
		solver->set_sleep_threshold(p_v);
	}
}
float Tentacle::get_sleep_threshold() const { return sleep_threshold; }

void Tentacle::set_substep_count(int p_count) {
	if (p_count < 1) p_count = 1;
	if (p_count > MAX_SUBSTEPS) p_count = MAX_SUBSTEPS;
	substep_count = p_count;
}
int Tentacle::get_substep_count() const { return substep_count; }

int Tentacle::get_last_substep_count() const { return last_substep_count; }

void Tentacle::set_contact_velocity_damping(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	if (p_v > 1.0f) p_v = 1.0f;
	contact_velocity_damping = p_v;
	if (solver.is_valid()) {
		solver->set_contact_velocity_damping(p_v);
	}
}
float Tentacle::get_contact_velocity_damping() const { return contact_velocity_damping; }

void Tentacle::set_support_in_contact(bool p_v) {
	support_in_contact = p_v;
	if (solver.is_valid()) {
		solver->set_support_in_contact(p_v);
	}
}
bool Tentacle::get_support_in_contact() const { return support_in_contact; }

void Tentacle::set_body_impulse_scale(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	body_impulse_scale = p_v;
}
float Tentacle::get_body_impulse_scale() const { return body_impulse_scale; }

Array Tentacle::get_environment_contacts_snapshot() const {
	// Slice 4D: one entry per particle. `hit=false` entries are valid (the
	// gizmo skips them), kept so the snapshot index lines up with particle
	// index for downstream consumers.
	//
	// Slice 4M: each entry now exposes a per-slot view via `contacts` (an
	// Array of dictionaries) and `contact_count`. The legacy flat
	// `hit_point`/`hit_normal`/`hit_object_id`/`hit_linear_velocity`/
	// `friction_applied` keys keep mirroring slot 0 (the deepest contact),
	// so the gizmo overlay and tests written against the slice-4D
	// dictionary format keep working unchanged.
	Array out;
	const auto &contacts = environment_probe.get_contacts();
	int n = (int)contacts.size();
	out.resize(n);
	PackedVector3Array friction_applied;
	if (solver.is_valid()) {
		friction_applied = solver->get_environment_friction_applied();
	}
	int expected_friction = n * tentacletech::MAX_CONTACTS_PER_PARTICLE;
	bool friction_per_slot = (friction_applied.size() == expected_friction);
	for (int i = 0; i < n; i++) {
		const tentacletech::EnvironmentContact &c = contacts[i];
		Dictionary d;
		d["particle_index"] = c.particle_index;
		d["query_origin"] = c.query_origin;
		d["hit"] = c.hit;
		d["contact_count"] = c.contact_count;
		// Legacy flat keys mirror slot 0.
		d["hit_point"] = c.hit_point[0];
		d["hit_normal"] = c.hit_normal[0];
		d["hit_object_id"] = (int64_t)c.hit_object_id[0];
		d["hit_linear_velocity"] = c.hit_linear_velocity[0];
		Vector3 fa0;
		int base = i * tentacletech::MAX_CONTACTS_PER_PARTICLE;
		if (c.hit && friction_per_slot) {
			fa0 = friction_applied[base + 0];
		}
		d["friction_applied"] = fa0;

		// New per-slot view: `contacts[k]` for each populated slot.
		Array per_slot;
		per_slot.resize(c.contact_count);
		for (int k = 0; k < c.contact_count; k++) {
			Dictionary slot;
			slot["hit_point"] = c.hit_point[k];
			slot["hit_normal"] = c.hit_normal[k];
			slot["hit_depth"] = c.hit_depth[k];
			slot["hit_object_id"] = (int64_t)c.hit_object_id[k];
			slot["hit_linear_velocity"] = c.hit_linear_velocity[k];
			// Slice TT-S3 (§10.5) — suppressed slot flag for gizmo overlays
			// + tests. Suppressed slots have `hit_depth == 0` already
			// (zeroed by `_apply_contact_suppression`); the flag exists
			// so consumers can distinguish "no penetration" from
			// "penetration was suppressed by §10.5".
			slot["hit_suppressed"] = c.hit_suppressed[k];
			Vector3 fa;
			if (friction_per_slot) {
				fa = friction_applied[base + k];
			}
			slot["friction_applied"] = fa;
			per_slot[k] = slot;
		}
		d["contacts"] = per_slot;

		out[i] = d;
	}
	return out;
}

PackedByteArray Tentacle::get_in_contact_this_tick_snapshot() const {
	// Slice 4N — return the snapshot populated by `_run_environment_probe()`
	// for THIS tick. By-copy so the caller can't mutate solver state. If the
	// probe hasn't run yet (pre-_ready, or environment_probe_enabled toggled
	// off this tick), the snapshot is empty.
	return _in_contact_this_tick_snapshot;
}

Dictionary Tentacle::get_anchor_state() const {
	Dictionary d;
	if (solver.is_null() || !solver->has_anchor()) {
		d["particle_index"] = -1;
		d["world_xform"] = Transform3D();
		return d;
	}
	d["particle_index"] = solver->get_anchor_particle_index();
	d["world_xform"] = solver->get_anchor_transform();
	return d;
}

// -- Render plumbing --------------------------------------------------------

void Tentacle::set_tentacle_mesh(const Ref<Mesh> &p_mesh) {
	// If we were tracking a previous TentacleMesh's `changed` signal, drop
	// the connection so re-bakes on stale resources don't kick us.
	if (tentacle_mesh.is_valid() && tentacle_mesh->is_connected("changed",
			callable_mp(this, &Tentacle::_on_tentacle_mesh_changed))) {
		tentacle_mesh->disconnect("changed",
				callable_mp(this, &Tentacle::_on_tentacle_mesh_changed));
	}

	tentacle_mesh = p_mesh;
	_refresh_mesh_instance();

	if (tentacle_mesh.is_null()) {
		return;
	}

	// Duck-type the new mesh: a `TentacleMesh` (GDScript ArrayMesh subclass,
	// §10.2) exposes `get_baked_girth_texture` and emits `changed` after
	// each rebuild. For stock primitives these hooks are absent; we leave
	// the rest-girth uniform alone so the placeholder / explicit setter
	// value persists.
	if (tentacle_mesh->has_method("get_baked_girth_texture")) {
		_pull_baked_girth_from_mesh();
		// Re-pull whenever the mesh re-bakes (inspector slider drag, etc.).
		if (!tentacle_mesh->is_connected("changed",
				callable_mp(this, &Tentacle::_on_tentacle_mesh_changed))) {
			tentacle_mesh->connect("changed",
					callable_mp(this, &Tentacle::_on_tentacle_mesh_changed));
		}
	}
	_apply_mesh_length_to_segment_length();
}
Ref<Mesh> Tentacle::get_tentacle_mesh() const { return tentacle_mesh; }

void Tentacle::_pull_baked_girth_from_mesh() {
	if (tentacle_mesh.is_null()) {
		return;
	}
	if (!tentacle_mesh->has_method("get_baked_girth_texture")) {
		return;
	}
	Variant raw = tentacle_mesh->call("get_baked_girth_texture");
	Ref<ImageTexture> tex = raw;
	if (tex.is_valid()) {
		set_rest_girth_texture(tex);
	}

	// Slice 5H — pull the 2D feature silhouette texture if the mesh
	// exposes it. New TentacleMesh resources (post-5H) provide
	// `get_baked_feature_silhouette`; older / non-TentacleMesh meshes
	// don't and fall through to the silhouette being empty (zero
	// perturbation — backward-compat).
	if (tentacle_mesh->has_method("get_baked_feature_silhouette")) {
		Variant raw_sil = tentacle_mesh->call("get_baked_feature_silhouette");
		Ref<ImageTexture> sil = raw_sil;
		if (sil.is_valid()) {
			set_feature_silhouette(sil);
		}
	}

	// TentacleMesh also reports its arc-axis convention. Without this, a mesh
	// whose tip is at -Z (intrinsic_axis_sign=-1, the §10.1 default) collapses
	// in the shader because tt_distance_to_parameter clamps negative arcs.
	if (tentacle_mesh->has_method("get_baked_arc_convention")) {
		Variant raw_conv = tentacle_mesh->call("get_baked_arc_convention");
		Dictionary conv = raw_conv;
		if (conv.has("axis")) {
			set_mesh_arc_axis((int)conv["axis"]);
		}
		if (conv.has("sign")) {
			set_mesh_arc_sign((int)conv["sign"]);
		}
		if (conv.has("offset")) {
			set_mesh_arc_offset((float)conv["offset"]);
		}
	}
}

void Tentacle::_on_tentacle_mesh_changed() {
	_pull_baked_girth_from_mesh();
	_apply_mesh_length_to_segment_length();
}

void Tentacle::_apply_mesh_length_to_segment_length() {
	if (tentacle_mesh.is_null()) {
		return;
	}
	if (particle_count < 2) {
		return;
	}
	// Prefer `get_baked_rest_length()` when the mesh exposes it: the bake's
	// rest length spans the *full* axial extent (body + tip cap + base
	// flange, etc.), which is what the shader's spline-arc parameterization
	// expects. Using only the body `length` here makes the chain shorter
	// than the mesh, so any vertex past z=length (the cap) clamps to the
	// spline tip and the dome collapses into a flat disc. Stock primitives
	// without the bake hook fall back to the `length` property; if neither
	// is present, leave segment_length untouched.
	float mesh_len = -1.0f;
	if (tentacle_mesh->has_method("get_baked_rest_length")) {
		Variant raw = tentacle_mesh->call("get_baked_rest_length");
		if (raw.get_type() == Variant::FLOAT || raw.get_type() == Variant::INT) {
			mesh_len = (float)raw;
		}
	}
	if (mesh_len <= 0.0f) {
		Variant raw_len = tentacle_mesh->get("length");
		Variant::Type t = raw_len.get_type();
		if (t != Variant::FLOAT && t != Variant::INT) {
			return;
		}
		mesh_len = (float)raw_len;
	}
	if (mesh_len <= 0.0f) {
		return;
	}
	float new_seg = mesh_len / (float)(particle_count - 1);
	set_segment_length(new_seg);
}

void Tentacle::set_mesh_arc_axis(int p_axis) {
	if (p_axis < 0) p_axis = 0;
	if (p_axis > 2) p_axis = 2;
	mesh_arc_axis = p_axis;
	if (shader_material.is_valid()) {
		shader_material->set_shader_parameter(UNIFORM_MESH_ARC_AXIS, mesh_arc_axis);
	}
}
int Tentacle::get_mesh_arc_axis() const { return mesh_arc_axis; }

void Tentacle::set_mesh_arc_sign(int p_sign) {
	// Clamp to ±1 — anything else is meaningless for the convention. Pass 0
	// through as +1 (no-op default).
	if (p_sign < 0) p_sign = -1;
	else p_sign = 1;
	mesh_arc_sign = p_sign;
	if (shader_material.is_valid()) {
		shader_material->set_shader_parameter(UNIFORM_MESH_ARC_SIGN, (float)mesh_arc_sign);
	}
}
int Tentacle::get_mesh_arc_sign() const { return mesh_arc_sign; }

void Tentacle::set_mesh_arc_offset(float p_offset) {
	mesh_arc_offset = p_offset;
	if (shader_material.is_valid()) {
		shader_material->set_shader_parameter(UNIFORM_MESH_ARC_OFFSET, mesh_arc_offset);
	}
}
float Tentacle::get_mesh_arc_offset() const { return mesh_arc_offset; }

Ref<ShaderMaterial> Tentacle::get_shader_material() const { return shader_material; }
void Tentacle::set_shader_material(const Ref<ShaderMaterial> &p_mat) {
	shader_material = p_mat;
	_refresh_mesh_instance();
	_refresh_shader_material_bindings();
}

Ref<ImageTexture> Tentacle::get_spline_data_texture() const { return spline_data_texture; }
int Tentacle::get_spline_data_texture_width() const { return spline_data_width; }
Ref<Image> Tentacle::get_spline_data_image() const { return spline_data_image; }
Ref<ImageTexture> Tentacle::get_rest_girth_texture() const { return rest_girth_texture; }

void Tentacle::set_rest_girth_texture(const Ref<ImageTexture> &p_tex) {
	rest_girth_texture = p_tex;
	if (shader_material.is_valid() && rest_girth_texture.is_valid()) {
		shader_material->set_shader_parameter(UNIFORM_REST_GIRTH, rest_girth_texture);
	}
}

// -- Slice 5H feature silhouette ------------------------------------------

Ref<ImageTexture> Tentacle::get_feature_silhouette() const {
	return feature_silhouette_texture;
}

void Tentacle::set_feature_silhouette(const Ref<ImageTexture> &p_tex) {
	feature_silhouette_texture = p_tex;
	feature_silhouette_max_outward = 0.0f;
	if (p_tex.is_valid()) {
		feature_silhouette_image = p_tex->get_image();
		if (feature_silhouette_image.is_valid()) {
			feature_silhouette_axial_resolution = feature_silhouette_image->get_width();
			feature_silhouette_angular_resolution = feature_silhouette_image->get_height();
			// Slice 5H — scan once for the max OUTWARD (positive)
			// perturbation. Used to extend the broadphase probe radius
			// so contacts the contact-step sampler would accept aren't
			// missed. Inward (negative) values don't extend the probe;
			// they only reduce the contact threshold at sample time.
			int W = feature_silhouette_axial_resolution;
			int H = feature_silhouette_angular_resolution;
			float max_v = 0.0f;
			for (int u = 0; u < W; u++) {
				for (int v = 0; v < H; v++) {
					float pv = feature_silhouette_image->get_pixel(u, v).r;
					if (pv > max_v) max_v = pv;
				}
			}
			feature_silhouette_max_outward = max_v;
		} else {
			feature_silhouette_axial_resolution = 0;
			feature_silhouette_angular_resolution = 0;
		}
	} else {
		feature_silhouette_image = Ref<Image>();
		feature_silhouette_axial_resolution = 0;
		feature_silhouette_angular_resolution = 0;
	}
}

float Tentacle::sample_feature_silhouette(float p_s, float p_theta) const {
	if (feature_silhouette_image.is_null()) return 0.0f;
	int W = feature_silhouette_axial_resolution;
	int H = feature_silhouette_angular_resolution;
	if (W <= 0 || H <= 0) return 0.0f;
	// s clamps; θ wraps (mod 2π).
	float s = p_s;
	if (s < 0.0f) s = 0.0f;
	if (s > 1.0f) s = 1.0f;
	float two_pi = (float)Math_TAU;
	float theta = Math::fmod(Math::fmod(p_theta, two_pi) + two_pi, two_pi);
	float u = s * (float)(W - 1);
	float v = theta / two_pi * (float)H;
	int u0 = (int)Math::floor(u);
	int u1 = u0 + 1;
	if (u1 > W - 1) u1 = W - 1;
	int v0 = (int)Math::floor(v);
	int v1 = (v0 + 1) % H;
	v0 = ((v0 % H) + H) % H;
	float fu = u - (float)u0;
	float fv = v - Math::floor(v);
	float a = feature_silhouette_image->get_pixel(u0, v0).r;
	float b = feature_silhouette_image->get_pixel(u1, v0).r;
	float c = feature_silhouette_image->get_pixel(u0, v1).r;
	float d = feature_silhouette_image->get_pixel(u1, v1).r;
	float top = a + (b - a) * fu;
	float bot = c + (d - c) * fu;
	return top + (bot - top) * fv;
}

float Tentacle::sample_feature_silhouette_at_contact(int p_particle_idx,
		const Vector3 &p_contact_world_pos) const {
	if (feature_silhouette_image.is_null()) return 0.0f;
	if (solver.is_null()) return 0.0f;
	int n = solver->get_particle_count();
	if (p_particle_idx < 0 || p_particle_idx >= n) return 0.0f;
	if (particle_arc_length_normalized.size() != n) return 0.0f;
	if (particle_body_frame_x.size() != n) return 0.0f;

	float s = particle_arc_length_normalized[p_particle_idx];
	Vector3 frame_x = particle_body_frame_x[p_particle_idx];
	if (frame_x.length_squared() < 1e-10f) return 0.0f;
	// Tangent estimate at the particle.
	Vector3 tangent;
	if (p_particle_idx + 1 < n) {
		tangent = solver->get_particle_position(p_particle_idx + 1) -
				solver->get_particle_position(p_particle_idx);
	} else if (p_particle_idx > 0) {
		tangent = solver->get_particle_position(p_particle_idx) -
				solver->get_particle_position(p_particle_idx - 1);
	}
	float tl = tangent.length();
	if (tl < 1e-8f) return 0.0f;
	tangent /= tl;
	Vector3 frame_y = tangent.cross(frame_x).normalized();
	if (frame_y.length_squared() < 1e-10f) return 0.0f;
	Vector3 contact_dir = p_contact_world_pos - solver->get_particle_position(p_particle_idx);
	// Project to plane perpendicular to tangent so θ is purely radial.
	Vector3 contact_perp = contact_dir - tangent * contact_dir.dot(tangent);
	float perp_len = contact_perp.length();
	if (perp_len < 1e-8f) return 0.0f;
	float cx = contact_perp.dot(frame_x);
	float cy = contact_perp.dot(frame_y);
	float theta = Math::atan2(cy, cx);
	return sample_feature_silhouette(s, theta);
}

void Tentacle::_refresh_silhouette_frame_data() {
	if (solver.is_null()) return;
	int n = solver->get_particle_count();
	if (n < 2) return;
	if (particle_arc_length_normalized.size() != n) {
		particle_arc_length_normalized.resize(n);
	}
	if (particle_body_frame_x.size() != n) {
		particle_body_frame_x.resize(n);
	}
	float *arc_ptr = particle_arc_length_normalized.ptrw();
	Vector3 *fx_ptr = particle_body_frame_x.ptrw();
	// Total arc length from rest_lengths (stable across the tick).
	int seg_count = solver->get_segment_count();
	float total = 0.0f;
	for (int i = 0; i < seg_count; i++) total += solver->get_rest_length(i);
	float total_inv = (total > 1e-6f) ? (1.0f / total) : 0.0f;
	float cum = 0.0f;
	arc_ptr[0] = 0.0f;
	for (int i = 1; i <= seg_count && i < n; i++) {
		cum += solver->get_rest_length(i - 1);
		arc_ptr[i] = cum * total_inv;
	}
	if (n > seg_count) arc_ptr[n - 1] = 1.0f;

	// Body-frame X via parallel transport from particle 0. Anchor's
	// basis x axis as the seed reference; falls back to a stable world
	// reference when the anchor's basis is degenerate or not set.
	Vector3 ref_x;
	if (anchor_override) {
		// Honour the explicit anchor. Use the X column of its basis.
		// `anchor_override` only signals "manual override"; the actual
		// transform sits in the solver's anchor state.
	}
	Transform3D anchor_xform = solver->get_anchor_transform();
	ref_x = anchor_xform.basis.get_column(0);
	if (ref_x.length_squared() < 1e-10f) ref_x = Vector3(1.0f, 0.0f, 0.0f);
	// Tangent at particle 0 from segment 0.
	Vector3 t0 = solver->get_particle_position(1) - solver->get_particle_position(0);
	float t0l = t0.length();
	if (t0l < 1e-8f) t0 = Vector3(0.0f, 0.0f, 1.0f);
	else t0 /= t0l;
	// Project ref_x perpendicular to tangent; renormalize.
	Vector3 fx0 = ref_x - t0 * ref_x.dot(t0);
	if (fx0.length_squared() < 1e-10f) {
		// Fall back to world Y projected.
		Vector3 alt = Vector3(0.0f, 1.0f, 0.0f);
		fx0 = alt - t0 * alt.dot(t0);
		if (fx0.length_squared() < 1e-10f) {
			alt = Vector3(0.0f, 0.0f, 1.0f);
			fx0 = alt - t0 * alt.dot(t0);
		}
	}
	fx0.normalize();
	fx_ptr[0] = fx0;
	// Parallel transport along chain segments.
	Vector3 prev_t = t0;
	Vector3 prev_x = fx0;
	for (int i = 1; i < n; i++) {
		Vector3 ti;
		if (i + 1 < n) {
			ti = solver->get_particle_position(i + 1) - solver->get_particle_position(i);
		} else {
			ti = solver->get_particle_position(i) - solver->get_particle_position(i - 1);
		}
		float til = ti.length();
		if (til < 1e-8f) {
			fx_ptr[i] = prev_x;
			continue;
		}
		ti /= til;
		// Rotate prev_x by the rotation that takes prev_t → ti
		// (rotation-minimizing frame). Done via Rodrigues.
		Vector3 axis = prev_t.cross(ti);
		float axis_len = axis.length();
		Vector3 fxi;
		if (axis_len < 1e-7f) {
			// Tangents are (anti-)collinear; keep prev_x.
			fxi = prev_x;
		} else {
			axis /= axis_len;
			float cos_a = Math::clamp(prev_t.dot(ti), -1.0f, 1.0f);
			float angle = Math::acos(cos_a);
			fxi = prev_x.rotated(axis, angle);
		}
		// Re-orthogonalize against ti.
		fxi = fxi - ti * fxi.dot(ti);
		float fxil = fxi.length();
		if (fxil < 1e-10f) fxi = prev_x;
		else fxi /= fxil;
		fx_ptr[i] = fxi;
		prev_t = ti;
		prev_x = fxi;
	}
}

PackedVector3Array Tentacle::get_spline_samples(int p_count) const {
	PackedVector3Array out;
	if (render_spline.is_null() || p_count < 2) {
		return out;
	}
	out.resize(p_count);
	Vector3 *ptr = out.ptrw();
	for (int i = 0; i < p_count; i++) {
		float t = (float)i / (float)(p_count - 1);
		ptr[i] = render_spline->evaluate_position(t);
	}
	return out;
}

Array Tentacle::get_spline_frames(int p_count) const {
	Array out;
	if (render_spline.is_null() || p_count < 2) {
		return out;
	}
	out.resize(p_count);
	for (int i = 0; i < p_count; i++) {
		float t = (float)i / (float)(p_count - 1);
		Vector3 pos = render_spline->evaluate_position(t);
		Vector3 tan, nrm, binormal;
		render_spline->evaluate_frame(t, tan, nrm, binormal);
		Dictionary d;
		d["position"] = pos;
		d["tangent"] = tan;
		d["normal"] = nrm;
		d["binormal"] = binormal;
		out[i] = d;
	}
	return out;
}

void Tentacle::update_render_data() {
	_update_spline_data_texture();
}

void Tentacle::set_draw_gizmo(bool p_enabled) {
	if (draw_gizmo == p_enabled) return;
	draw_gizmo = p_enabled;
	if (draw_gizmo) {
		_spawn_debug_overlay();
	} else {
		_despawn_debug_overlay();
	}
}

bool Tentacle::get_draw_gizmo() const { return draw_gizmo; }

void Tentacle::_spawn_debug_overlay() {
	if (debug_overlay != nullptr) return;
	// Edit-time visualization is owned by the EditorNode3DGizmoPlugin
	// (`gdscript/gizmo_plugin/tentacle_gizmo.gd`), which converts world→local
	// correctly. The runtime overlay (top_level world-space mesh) duplicates
	// the editor gizmo when both run, so it is gated to runtime only. At
	// runtime the editor plugin doesn't render, so the overlay takes over —
	// it also covers the env-contact / friction layers that the editor
	// gizmo doesn't draw.
	if (Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	const String path = "res://addons/tentacletech/scripts/debug/debug_gizmo_overlay.gd";
	ResourceLoader *rl = ResourceLoader::get_singleton();
	if (rl == nullptr || !rl->exists(path)) {
		return;
	}
	Ref<Script> script = rl->load(path);
	if (script.is_null()) {
		return;
	}
	Node3D *overlay = memnew(Node3D);
	overlay->set_script(script);
	overlay->set_name("DebugGizmoOverlay");
	overlay->set("tentacle", this);
	add_child(overlay, false, Node::INTERNAL_MODE_FRONT);
	debug_overlay = overlay;
}

void Tentacle::_despawn_debug_overlay() {
	if (debug_overlay == nullptr) return;
	remove_child(debug_overlay);
	debug_overlay->queue_free();
	debug_overlay = nullptr;
}

void Tentacle::_ensure_mesh_instance() {
	if (mesh_instance != nullptr) {
		return;
	}
	mesh_instance = memnew(MeshInstance3D);
	mesh_instance->set_name("TentacleMesh");
	// INTERNAL_MODE_FRONT keeps it out of the scene tree dock and out of the
	// .tscn file when @tool causes _ready() to fire at edit time.
	add_child(mesh_instance, false, Node::INTERNAL_MODE_FRONT);
}

void Tentacle::_refresh_mesh_instance() {
	if (mesh_instance == nullptr) {
		return;
	}
	mesh_instance->set_mesh(tentacle_mesh);
	if (shader_material.is_valid()) {
		mesh_instance->set_material_override(shader_material);
	}
}

void Tentacle::_refresh_shader_material_bindings() {
	if (shader_material.is_null()) {
		// Try to load the shared shader resource lazily — it may not exist
		// until sub-step A's shader files are deployed. Quietly skip if it
		// fails (renders as no-mesh + null material; data textures still
		// update in case external code wants to read them).
		ResourceLoader *rl = ResourceLoader::get_singleton();
		if (rl != nullptr && rl->exists(SHADER_RES_PATH)) {
			Ref<Shader> shader = rl->load(SHADER_RES_PATH);
			if (shader.is_valid()) {
				shader_material.instantiate();
				shader_material->set_shader(shader);
				if (mesh_instance != nullptr) {
					mesh_instance->set_material_override(shader_material);
				}
			}
		}
	}
	if (shader_material.is_null()) {
		return;
	}
	if (spline_data_texture.is_valid()) {
		shader_material->set_shader_parameter(UNIFORM_SPLINE_DATA, spline_data_texture);
	}
	shader_material->set_shader_parameter(UNIFORM_SPLINE_DATA_WIDTH, spline_data_width);
	if (rest_girth_texture.is_valid()) {
		shader_material->set_shader_parameter(UNIFORM_REST_GIRTH, rest_girth_texture);
	}
	shader_material->set_shader_parameter(UNIFORM_MESH_ARC_AXIS, mesh_arc_axis);
	shader_material->set_shader_parameter(UNIFORM_MESH_ARC_SIGN, (float)mesh_arc_sign);
	shader_material->set_shader_parameter(UNIFORM_MESH_ARC_OFFSET, mesh_arc_offset);
}

void Tentacle::_allocate_render_resources() {
	// Lay out the per-tick scratch buffers and the data texture sized for the
	// current chain. Called from _ready() and rebuild_chain(). After this,
	// _update_spline_data_texture() is alloc-free as long as particle_count
	// stays constant.

	if (render_spline.is_null()) {
		render_spline.instantiate();
	}

	// Pre-resize the local-space points buffer; an initial straight chain
	// gives the spline a valid first build for the placeholder data.
	if (spline_points_buffer.size() != particle_count) {
		spline_points_buffer.resize(particle_count);
	}
	for (int i = 0; i < particle_count; i++) {
		spline_points_buffer.set(i, Vector3(0.0f, 0.0f, -segment_length * (float)i));
	}
	render_spline->build_from_points(spline_points_buffer);

	// Resize per-channel buffers; channel layout is fixed by namespace
	// constants above.
	if (girth_channel_buffer.size() != particle_count) {
		girth_channel_buffer.resize(particle_count);
	}
	if (asym_x_channel_buffer.size() != particle_count) {
		asym_x_channel_buffer.resize(particle_count);
	}
	if (asym_y_channel_buffer.size() != particle_count) {
		asym_y_channel_buffer.resize(particle_count);
	}

	// Compute total packed float count and pre-resize the packed buffer.
	int segment_count = render_spline->get_segment_count();
	int dist_lut = render_spline->get_distance_lut_sample_count();
	int bn_lut = render_spline->get_binormal_lut_sample_count();
	int total = SplineDataPacker::compute_packed_size(
			segment_count, dist_lut, bn_lut, CHANNEL_COUNT, particle_count);
	if (spline_packed_buffer.size() != total) {
		spline_packed_buffer.resize(total);
	}

	// One RGBA32F pixel = 4 floats. Width = ceil(total / 4); height = 1.
	// Pad-zeroed so width * height * 4 ≥ total.
	int floats_per_pixel = 4;
	int pixels = (total + floats_per_pixel - 1) / floats_per_pixel;
	if (pixels < 1) pixels = 1;
	int padded_floats = pixels * floats_per_pixel;
	int padded_bytes = padded_floats * (int)sizeof(float);
	if (spline_byte_buffer.size() != padded_bytes) {
		spline_byte_buffer.resize(padded_bytes);
	}

	bool size_changed = (spline_data_width != pixels) || (spline_data_height != 1);
	spline_data_width = pixels;
	spline_data_height = 1;

	if (spline_data_image.is_null() || size_changed) {
		spline_data_image = Image::create_empty(spline_data_width, spline_data_height, false, Image::FORMAT_RGBAF);
	}
	if (spline_data_texture.is_null()) {
		spline_data_texture = ImageTexture::create_from_image(spline_data_image);
	} else if (size_changed) {
		// Texture must be resized: re-create from the new image.
		spline_data_texture->set_image(spline_data_image);
	}

	// Placeholder rest girth texture — uniform 1.0. Sub-step B replaces this
	// with the auto-bake output. Allocated once; we don't rebuild it on
	// chain rebuilds (the bake doesn't depend on particle_count).
	if (rest_girth_texture.is_null()) {
		PackedByteArray rg_bytes;
		rg_bytes.resize(REST_GIRTH_TEXTURE_WIDTH * (int)sizeof(float));
		float *rg_floats = (float *)rg_bytes.ptrw();
		for (int i = 0; i < REST_GIRTH_TEXTURE_WIDTH; i++) {
			rg_floats[i] = 1.0f;
		}
		Ref<Image> img = Image::create_from_data(REST_GIRTH_TEXTURE_WIDTH, 1, false, Image::FORMAT_RF, rg_bytes);
		rest_girth_texture = ImageTexture::create_from_image(img);
	}

	// Material binding may have been set up before resources existed; refresh.
	_refresh_shader_material_bindings();
}

void Tentacle::_update_spline_data_texture() {
	if (solver.is_null() || render_spline.is_null() || spline_data_image.is_null()) {
		return;
	}
	int n = solver->get_particle_count();
	if (n < 2 || spline_points_buffer.size() != n) {
		return;
	}

	// Pull world-space particle positions; transform into tentacle-local space
	// so the resulting spline sits in the same frame as the MeshInstance3D's
	// vertex shader. No allocation: we mutate the pre-resized buffer in place.
	Transform3D world_to_local = is_inside_tree() ? get_global_transform().affine_inverse() : Transform3D();
	for (int i = 0; i < n; i++) {
		Vector3 world_pos = solver->get_particle_position(i);
		spline_points_buffer.set(i, world_to_local.xform(world_pos));
	}
	render_spline->build_from_points(spline_points_buffer);

	// Per-particle channel data from the solver.
	for (int i = 0; i < n; i++) {
		girth_channel_buffer.set(i, solver->get_particle_girth_scale(i));
		Vector2 a = solver->get_particle_asymmetry(i);
		asym_x_channel_buffer.set(i, a.x);
		asym_y_channel_buffer.set(i, a.y);
	}

	// Pack into the pre-sized buffer. The Array allocation here is small (3
	// Variant entries) and falls under the Phase-2 1KB drift budget.
	Array channels;
	channels.push_back(girth_channel_buffer);
	channels.push_back(asym_x_channel_buffer);
	channels.push_back(asym_y_channel_buffer);
	SplineDataPacker::pack_into(render_spline, channels, spline_packed_buffer);

	// Copy floats → bytes into the pre-sized byte buffer. Pre-sized to the
	// texture's full pixel-aligned size; trailing bytes stay as previously
	// written (pad bytes are read by the shader only when sampling beyond
	// the meaningful data, which never happens in normal use).
	int total_floats = spline_packed_buffer.size();
	int byte_capacity = spline_byte_buffer.size();
	int copy_bytes = total_floats * (int)sizeof(float);
	if (copy_bytes > byte_capacity) {
		copy_bytes = byte_capacity;
	}
	const uint8_t *src = (const uint8_t *)spline_packed_buffer.ptr();
	uint8_t *dst = spline_byte_buffer.ptrw();
	for (int i = 0; i < copy_bytes; i++) {
		dst[i] = src[i];
	}

	// Replace the image's data and push to the texture. set_data() reuses the
	// Image instance (no Image realloc); ImageTexture::update() reuploads to
	// GPU without recreating the texture handle.
	spline_data_image->set_data(spline_data_width, spline_data_height, false,
			Image::FORMAT_RGBAF, spline_byte_buffer);
	spline_data_texture->update(spline_data_image);
}

// -- Binding ----------------------------------------------------------------

void Tentacle::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_particle_count", "count"), &Tentacle::set_particle_count);
	ClassDB::bind_method(D_METHOD("get_particle_count"), &Tentacle::get_particle_count);
	ClassDB::bind_method(D_METHOD("set_segment_length", "length"), &Tentacle::set_segment_length);
	ClassDB::bind_method(D_METHOD("get_segment_length"), &Tentacle::get_segment_length);
	ClassDB::bind_method(D_METHOD("rebuild_chain"), &Tentacle::rebuild_chain);

	ClassDB::bind_method(D_METHOD("set_iteration_count", "iter"), &Tentacle::set_iteration_count);
	ClassDB::bind_method(D_METHOD("get_iteration_count"), &Tentacle::get_iteration_count);
	ClassDB::bind_method(D_METHOD("set_gravity", "gravity"), &Tentacle::set_gravity);
	ClassDB::bind_method(D_METHOD("get_gravity"), &Tentacle::get_gravity);
	ClassDB::bind_method(D_METHOD("set_damping", "damping"), &Tentacle::set_damping);
	ClassDB::bind_method(D_METHOD("get_damping"), &Tentacle::get_damping);
	ClassDB::bind_method(D_METHOD("set_distance_stiffness", "stiffness"), &Tentacle::set_distance_stiffness);
	ClassDB::bind_method(D_METHOD("get_distance_stiffness"), &Tentacle::get_distance_stiffness);
	ClassDB::bind_method(D_METHOD("set_bending_stiffness", "stiffness"), &Tentacle::set_bending_stiffness);
	ClassDB::bind_method(D_METHOD("get_bending_stiffness"), &Tentacle::get_bending_stiffness);
	ClassDB::bind_method(D_METHOD("set_asymmetry_recovery_rate", "rate"), &Tentacle::set_asymmetry_recovery_rate);
	ClassDB::bind_method(D_METHOD("get_asymmetry_recovery_rate"), &Tentacle::get_asymmetry_recovery_rate);
	ClassDB::bind_method(D_METHOD("set_base_angular_velocity_limit", "omega"), &Tentacle::set_base_angular_velocity_limit);
	ClassDB::bind_method(D_METHOD("get_base_angular_velocity_limit"), &Tentacle::get_base_angular_velocity_limit);
	ClassDB::bind_method(D_METHOD("set_rigid_base_count", "count"), &Tentacle::set_rigid_base_count);
	ClassDB::bind_method(D_METHOD("get_rigid_base_count"), &Tentacle::get_rigid_base_count);
	ClassDB::bind_method(D_METHOD("set_draw_gizmo", "enabled"), &Tentacle::set_draw_gizmo);
	ClassDB::bind_method(D_METHOD("get_draw_gizmo"), &Tentacle::get_draw_gizmo);

	ClassDB::bind_method(D_METHOD("set_target", "world_pos"), &Tentacle::set_target);
	ClassDB::bind_method(D_METHOD("clear_target"), &Tentacle::clear_target);
	ClassDB::bind_method(D_METHOD("set_target_stiffness", "stiffness"), &Tentacle::set_target_stiffness);
	ClassDB::bind_method(D_METHOD("get_target_stiffness"), &Tentacle::get_target_stiffness);
	ClassDB::bind_method(D_METHOD("set_target_particle_index", "index"), &Tentacle::set_target_particle_index);
	ClassDB::bind_method(D_METHOD("get_target_particle_index"), &Tentacle::get_target_particle_index);

	ClassDB::bind_method(D_METHOD("set_pose_targets", "indices", "world_positions", "stiffnesses"), &Tentacle::set_pose_targets);
	ClassDB::bind_method(D_METHOD("clear_pose_targets"), &Tentacle::clear_pose_targets);
	ClassDB::bind_method(D_METHOD("get_pose_target_count"), &Tentacle::get_pose_target_count);

	ClassDB::bind_method(D_METHOD("set_anchor_transform", "xform"), &Tentacle::set_anchor_transform);
	ClassDB::bind_method(D_METHOD("clear_anchor_override"), &Tentacle::clear_anchor_override);

	ClassDB::bind_method(D_METHOD("get_solver"), &Tentacle::get_solver);
	ClassDB::bind_method(D_METHOD("add_external_position_delta", "particle_index", "delta"),
			&Tentacle::add_external_position_delta);
	ClassDB::bind_method(D_METHOD("flush_external_position_deltas"),
			&Tentacle::flush_external_position_deltas);

	// Slice TT-S3 (§10.5) — active-EI orifice registry. Bound for tests
	// + tooling; the runtime path is Orifice → Tentacle in C++ directly,
	// no GDScript intermediary.
	ClassDB::bind_method(D_METHOD("register_active_ei_orifice", "orifice"),
			&Tentacle::register_active_ei_orifice);
	ClassDB::bind_method(D_METHOD("unregister_active_ei_orifice", "orifice"),
			&Tentacle::unregister_active_ei_orifice);
	ClassDB::bind_method(D_METHOD("get_active_ei_orifice_count"),
			&Tentacle::get_active_ei_orifice_count);
	ClassDB::bind_method(D_METHOD("get_signed_girth_gradient_at_arc_length", "s"),
			&Tentacle::get_signed_girth_gradient_at_arc_length);
	ClassDB::bind_method(D_METHOD("get_tangent_at_arc_length", "s"),
			&Tentacle::get_tangent_at_arc_length);
	ClassDB::bind_method(D_METHOD("get_total_chain_arc_length"),
			&Tentacle::get_total_chain_arc_length);

	ClassDB::bind_method(D_METHOD("get_particle_positions"), &Tentacle::get_particle_positions);
	ClassDB::bind_method(D_METHOD("get_particle_inv_masses"), &Tentacle::get_particle_inv_masses);
	ClassDB::bind_method(D_METHOD("get_segment_stretch_ratios"), &Tentacle::get_segment_stretch_ratios);
	ClassDB::bind_method(D_METHOD("get_target_pull_state"), &Tentacle::get_target_pull_state);
	ClassDB::bind_method(D_METHOD("get_anchor_state"), &Tentacle::get_anchor_state);

	ClassDB::bind_method(D_METHOD("set_environment_probe_enabled", "enabled"),
			&Tentacle::set_environment_probe_enabled);
	ClassDB::bind_method(D_METHOD("get_environment_probe_enabled"),
			&Tentacle::get_environment_probe_enabled);
	ClassDB::bind_method(D_METHOD("set_environment_probe_distance", "distance"),
			&Tentacle::set_environment_probe_distance);
	ClassDB::bind_method(D_METHOD("get_environment_probe_distance"),
			&Tentacle::get_environment_probe_distance);
	ClassDB::bind_method(D_METHOD("set_environment_collision_layer_mask", "mask"),
			&Tentacle::set_environment_collision_layer_mask);
	ClassDB::bind_method(D_METHOD("get_environment_collision_layer_mask"),
			&Tentacle::get_environment_collision_layer_mask);
	ClassDB::bind_method(D_METHOD("set_particle_collision_radius", "radius"),
			&Tentacle::set_particle_collision_radius);
	ClassDB::bind_method(D_METHOD("get_particle_collision_radius"),
			&Tentacle::get_particle_collision_radius);
	ClassDB::bind_method(D_METHOD("set_base_static_friction", "value"),
			&Tentacle::set_base_static_friction);
	ClassDB::bind_method(D_METHOD("get_base_static_friction"),
			&Tentacle::get_base_static_friction);
	ClassDB::bind_method(D_METHOD("set_tentacle_lubricity", "value"),
			&Tentacle::set_tentacle_lubricity);
	ClassDB::bind_method(D_METHOD("get_tentacle_lubricity"),
			&Tentacle::get_tentacle_lubricity);
	ClassDB::bind_method(D_METHOD("set_kinetic_friction_ratio", "value"),
			&Tentacle::set_kinetic_friction_ratio);
	ClassDB::bind_method(D_METHOD("get_kinetic_friction_ratio"),
			&Tentacle::get_kinetic_friction_ratio);
	ClassDB::bind_method(D_METHOD("set_contact_stiffness", "value"),
			&Tentacle::set_contact_stiffness);
	ClassDB::bind_method(D_METHOD("get_contact_stiffness"),
			&Tentacle::get_contact_stiffness);
	ClassDB::bind_method(D_METHOD("set_target_softness_when_blocked", "value"),
			&Tentacle::set_target_softness_when_blocked);
	ClassDB::bind_method(D_METHOD("get_target_softness_when_blocked"),
			&Tentacle::get_target_softness_when_blocked);
	ClassDB::bind_method(D_METHOD("set_tension_taper_threshold", "value"),
			&Tentacle::set_tension_taper_threshold);
	ClassDB::bind_method(D_METHOD("get_tension_taper_threshold"),
			&Tentacle::get_tension_taper_threshold);
	ClassDB::bind_method(D_METHOD("set_target_velocity_max", "value"),
			&Tentacle::set_target_velocity_max);
	ClassDB::bind_method(D_METHOD("get_target_velocity_max"),
			&Tentacle::get_target_velocity_max);
	ClassDB::bind_method(D_METHOD("set_sor_factor", "value"),
			&Tentacle::set_sor_factor);
	ClassDB::bind_method(D_METHOD("get_sor_factor"),
			&Tentacle::get_sor_factor);
	ClassDB::bind_method(D_METHOD("set_max_depenetration", "value"),
			&Tentacle::set_max_depenetration);
	ClassDB::bind_method(D_METHOD("get_max_depenetration"),
			&Tentacle::get_max_depenetration);
	ClassDB::bind_method(D_METHOD("set_sleep_threshold", "value"),
			&Tentacle::set_sleep_threshold);
	ClassDB::bind_method(D_METHOD("get_sleep_threshold"),
			&Tentacle::get_sleep_threshold);
	ClassDB::bind_method(D_METHOD("set_substep_count", "count"),
			&Tentacle::set_substep_count);
	ClassDB::bind_method(D_METHOD("get_substep_count"),
			&Tentacle::get_substep_count);
	ClassDB::bind_method(D_METHOD("get_last_substep_count"),
			&Tentacle::get_last_substep_count);
	ClassDB::bind_method(D_METHOD("set_contact_velocity_damping", "value"),
			&Tentacle::set_contact_velocity_damping);
	ClassDB::bind_method(D_METHOD("get_contact_velocity_damping"),
			&Tentacle::get_contact_velocity_damping);
	ClassDB::bind_method(D_METHOD("set_support_in_contact", "value"),
			&Tentacle::set_support_in_contact);
	ClassDB::bind_method(D_METHOD("get_support_in_contact"),
			&Tentacle::get_support_in_contact);
	ClassDB::bind_method(D_METHOD("set_body_impulse_scale", "value"),
			&Tentacle::set_body_impulse_scale);
	ClassDB::bind_method(D_METHOD("get_body_impulse_scale"),
			&Tentacle::get_body_impulse_scale);
	ClassDB::bind_method(D_METHOD("get_environment_contacts_snapshot"),
			&Tentacle::get_environment_contacts_snapshot);
	ClassDB::bind_method(D_METHOD("get_in_contact_this_tick_snapshot"),
			&Tentacle::get_in_contact_this_tick_snapshot);
	ClassDB::bind_method(D_METHOD("set_contact_persistence_enabled", "enabled"),
			&Tentacle::set_contact_persistence_enabled);
	ClassDB::bind_method(D_METHOD("get_contact_persistence_enabled"),
			&Tentacle::get_contact_persistence_enabled);
	ClassDB::bind_method(D_METHOD("set_contact_persistence_radius_factor", "factor"),
			&Tentacle::set_contact_persistence_radius_factor);
	ClassDB::bind_method(D_METHOD("get_contact_persistence_radius_factor"),
			&Tentacle::get_contact_persistence_radius_factor);
	ClassDB::bind_method(D_METHOD("set_contact_persistence_jump_threshold_factor", "factor"),
			&Tentacle::set_contact_persistence_jump_threshold_factor);
	ClassDB::bind_method(D_METHOD("get_contact_persistence_jump_threshold_factor"),
			&Tentacle::get_contact_persistence_jump_threshold_factor);
	ClassDB::bind_method(D_METHOD("get_persistence_invalidation_count_snapshot"),
			&Tentacle::get_persistence_invalidation_count_snapshot);
	ClassDB::bind_method(D_METHOD("tick", "delta"), &Tentacle::tick);

	ClassDB::bind_method(D_METHOD("set_tentacle_mesh", "mesh"), &Tentacle::set_tentacle_mesh);
	ClassDB::bind_method(D_METHOD("get_tentacle_mesh"), &Tentacle::get_tentacle_mesh);
	ClassDB::bind_method(D_METHOD("_on_tentacle_mesh_changed"), &Tentacle::_on_tentacle_mesh_changed);
	ClassDB::bind_method(D_METHOD("set_shader_material", "material"), &Tentacle::set_shader_material);
	ClassDB::bind_method(D_METHOD("get_shader_material"), &Tentacle::get_shader_material);
	ClassDB::bind_method(D_METHOD("set_mesh_arc_axis", "axis"), &Tentacle::set_mesh_arc_axis);
	ClassDB::bind_method(D_METHOD("get_mesh_arc_axis"), &Tentacle::get_mesh_arc_axis);
	ClassDB::bind_method(D_METHOD("set_mesh_arc_sign", "sign"), &Tentacle::set_mesh_arc_sign);
	ClassDB::bind_method(D_METHOD("get_mesh_arc_sign"), &Tentacle::get_mesh_arc_sign);
	ClassDB::bind_method(D_METHOD("set_mesh_arc_offset", "offset"), &Tentacle::set_mesh_arc_offset);
	ClassDB::bind_method(D_METHOD("get_mesh_arc_offset"), &Tentacle::get_mesh_arc_offset);

	BIND_ENUM_CONSTANT(MESH_ARC_AXIS_X);
	BIND_ENUM_CONSTANT(MESH_ARC_AXIS_Y);
	BIND_ENUM_CONSTANT(MESH_ARC_AXIS_Z);
	ClassDB::bind_method(D_METHOD("get_spline_data_texture"), &Tentacle::get_spline_data_texture);
	ClassDB::bind_method(D_METHOD("get_spline_data_texture_width"), &Tentacle::get_spline_data_texture_width);
	ClassDB::bind_method(D_METHOD("get_spline_data_image"), &Tentacle::get_spline_data_image);
	ClassDB::bind_method(D_METHOD("get_rest_girth_texture"), &Tentacle::get_rest_girth_texture);
	ClassDB::bind_method(D_METHOD("set_rest_girth_texture", "tex"), &Tentacle::set_rest_girth_texture);
	ClassDB::bind_method(D_METHOD("get_feature_silhouette"), &Tentacle::get_feature_silhouette);
	ClassDB::bind_method(D_METHOD("set_feature_silhouette", "tex"), &Tentacle::set_feature_silhouette);
	ClassDB::bind_method(D_METHOD("sample_feature_silhouette", "s", "theta"),
			&Tentacle::sample_feature_silhouette);
	ClassDB::bind_method(D_METHOD("sample_feature_silhouette_at_contact", "particle_idx", "contact_world_pos"),
			&Tentacle::sample_feature_silhouette_at_contact);
	ClassDB::bind_method(D_METHOD("get_spline_samples", "count"), &Tentacle::get_spline_samples);
	ClassDB::bind_method(D_METHOD("get_spline_frames", "count"), &Tentacle::get_spline_frames);
	ClassDB::bind_method(D_METHOD("update_render_data"), &Tentacle::update_render_data);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "particle_count", PROPERTY_HINT_RANGE, "2,48,1"),
			"set_particle_count", "get_particle_count");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "segment_length", PROPERTY_HINT_RANGE, "0.001,1.0,0.001,or_greater"),
			"set_segment_length", "get_segment_length");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "tentacle_mesh", PROPERTY_HINT_RESOURCE_TYPE, "Mesh"),
			"set_tentacle_mesh", "get_tentacle_mesh");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "shader_material", PROPERTY_HINT_RESOURCE_TYPE, "ShaderMaterial"),
			"set_shader_material", "get_shader_material");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mesh_arc_axis", PROPERTY_HINT_ENUM, "X,Y,Z"),
			"set_mesh_arc_axis", "get_mesh_arc_axis");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mesh_arc_sign", PROPERTY_HINT_ENUM, "Negative:-1,Positive:1"),
			"set_mesh_arc_sign", "get_mesh_arc_sign");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "mesh_arc_offset", PROPERTY_HINT_RANGE, "-10.0,10.0,0.001,or_lesser,or_greater"),
			"set_mesh_arc_offset", "get_mesh_arc_offset");

	ADD_GROUP("Solver", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "iteration_count", PROPERTY_HINT_RANGE, "1,6,1"),
			"set_iteration_count", "get_iteration_count");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "gravity"),
			"set_gravity", "get_gravity");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "damping", PROPERTY_HINT_RANGE, "0.0,1.0,0.001"),
			"set_damping", "get_damping");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "distance_stiffness", PROPERTY_HINT_RANGE, "0.0,1.0,0.001"),
			"set_distance_stiffness", "get_distance_stiffness");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "bending_stiffness", PROPERTY_HINT_RANGE, "0.0,1.0,0.001"),
			"set_bending_stiffness", "get_bending_stiffness");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "asymmetry_recovery_rate", PROPERTY_HINT_RANGE, "0.0,10.0,0.01,or_greater"),
			"set_asymmetry_recovery_rate", "get_asymmetry_recovery_rate");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "base_angular_velocity_limit", PROPERTY_HINT_RANGE, "0.0,20.0,0.01,or_greater"),
			"set_base_angular_velocity_limit", "get_base_angular_velocity_limit");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "rigid_base_count", PROPERTY_HINT_RANGE, "1,8,1,or_greater"),
			"set_rigid_base_count", "get_rigid_base_count");

	ADD_GROUP("Collision", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "environment_probe_enabled"),
			"set_environment_probe_enabled", "get_environment_probe_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "environment_probe_distance",
					 PROPERTY_HINT_RANGE, "0.01,20.0,0.01,or_greater"),
			"set_environment_probe_distance", "get_environment_probe_distance");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "environment_collision_layer_mask",
					 PROPERTY_HINT_LAYERS_3D_PHYSICS),
			"set_environment_collision_layer_mask", "get_environment_collision_layer_mask");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "particle_collision_radius",
					 PROPERTY_HINT_RANGE, "0.0,1.0,0.001,or_greater"),
			"set_particle_collision_radius", "get_particle_collision_radius");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "base_static_friction",
					 PROPERTY_HINT_RANGE, "0.0,4.0,0.01"),
			"set_base_static_friction", "get_base_static_friction");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "tentacle_lubricity",
					 PROPERTY_HINT_RANGE, "0.0,1.0,0.001"),
			"set_tentacle_lubricity", "get_tentacle_lubricity");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "kinetic_friction_ratio",
					 PROPERTY_HINT_RANGE, "0.0,1.0,0.001"),
			"set_kinetic_friction_ratio", "get_kinetic_friction_ratio");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "contact_stiffness",
					 PROPERTY_HINT_RANGE, "0.0,1.0,0.001"),
			"set_contact_stiffness", "get_contact_stiffness");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "target_softness_when_blocked",
					 PROPERTY_HINT_RANGE, "0.0,1.0,0.001"),
			"set_target_softness_when_blocked", "get_target_softness_when_blocked");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "tension_taper_threshold",
					 PROPERTY_HINT_RANGE, "0.0,1.0,0.001"),
			"set_tension_taper_threshold", "get_tension_taper_threshold");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "target_velocity_max",
					 PROPERTY_HINT_RANGE, "0.0,20.0,0.1,or_greater"),
			"set_target_velocity_max", "get_target_velocity_max");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "sor_factor",
					 PROPERTY_HINT_RANGE, "0.0,4.0,0.05"),
			"set_sor_factor", "get_sor_factor");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_depenetration",
					 PROPERTY_HINT_RANGE, "0.0,10.0,0.05"),
			"set_max_depenetration", "get_max_depenetration");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "sleep_threshold",
					 PROPERTY_HINT_RANGE, "0.0,1.0,0.0001"),
			"set_sleep_threshold", "get_sleep_threshold");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "substep_count",
					 PROPERTY_HINT_RANGE, "1,4,1"),
			"set_substep_count", "get_substep_count");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "contact_velocity_damping",
					 PROPERTY_HINT_RANGE, "0.0,1.0,0.001"),
			"set_contact_velocity_damping", "get_contact_velocity_damping");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "support_in_contact"),
			"set_support_in_contact", "get_support_in_contact");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "body_impulse_scale",
					 PROPERTY_HINT_RANGE, "0.0,2.0,0.001,or_greater"),
			"set_body_impulse_scale", "get_body_impulse_scale");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "contact_persistence_enabled"),
			"set_contact_persistence_enabled", "get_contact_persistence_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "contact_persistence_radius_factor",
					 PROPERTY_HINT_RANGE, "0.0,8.0,0.01,or_greater"),
			"set_contact_persistence_radius_factor",
			"get_contact_persistence_radius_factor");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "contact_persistence_jump_threshold_factor",
					 PROPERTY_HINT_RANGE, "0.0,8.0,0.01,or_greater"),
			"set_contact_persistence_jump_threshold_factor",
			"get_contact_persistence_jump_threshold_factor");

	ADD_GROUP("Debug", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "draw_gizmo"),
			"set_draw_gizmo", "get_draw_gizmo");
}
