#include "pbd_solver.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>

#include "constraints.h"

using namespace godot;

PBDSolver::PBDSolver() {}
PBDSolver::~PBDSolver() {}

// -- Setup ------------------------------------------------------------------

void PBDSolver::initialize_chain(int p_n, float p_segment_length) {
	if (p_n < 2) {
		p_n = 2;
	}
	if (p_segment_length < 1e-6f) {
		p_segment_length = 1e-6f;
	}

	particles.assign((size_t)p_n, TentacleParticle());
	rest_lengths.assign((size_t)(p_n - 1), p_segment_length);
	// Straight chain: chord between particles i and i+2 = 2 × segment_length.
	rest_bending_chord_lengths.assign((size_t)(p_n - 2), 2.0f * p_segment_length);
	smooth_girth_buffer.assign((size_t)p_n, 1.0f);
	smooth_asym_buffer.assign((size_t)p_n, Vector2());

	for (int i = 0; i < p_n; i++) {
		Vector3 pos(0.0f, 0.0f, -p_segment_length * (float)i);
		particles[i].position = pos;
		particles[i].prev_position = pos;
		particles[i].inv_mass = 1.0f;
		particles[i].girth_scale = 1.0f;
		particles[i].asymmetry = Vector2();
	}

	anchor_active = false;
	anchor_particle_index = -1;
	anchor_xform = Transform3D();
	target_active = false;
	target_particle_index = -1;
	target_position = Vector3();
}

int PBDSolver::get_particle_count() const {
	return (int)particles.size();
}

int PBDSolver::get_segment_count() const {
	return (int)rest_lengths.size();
}

// -- Tick -------------------------------------------------------------------

void PBDSolver::tick(float p_dt) {
	if (particles.size() < 2 || p_dt <= 0.0f) {
		return;
	}
	predict(p_dt);
	iterate();
	finalize(p_dt);
}

void PBDSolver::predict(float p_dt) {
	float dt2 = p_dt * p_dt;
	int n = (int)particles.size();
	for (int i = 0; i < n; i++) {
		TentacleParticle &p = particles[i];
		if (p.inv_mass <= 0.0f) {
			// Pinned: prev_position tracks position so velocity stays zero.
			p.prev_position = p.position;
			continue;
		}
		Vector3 temp_prev = p.prev_position;
		p.prev_position = p.position;
		Vector3 velocity = (p.position - temp_prev) * damping;
		p.position += velocity + gravity * dt2;
	}
}

void PBDSolver::iterate() {
	int n = (int)particles.size();
	for (int iter = 0; iter < iteration_count; iter++) {
		// 1. Distance constraints (segment length).
		for (int i = 0; i + 1 < n; i++) {
			tentacletech::constraints::project_distance(
					particles[i], particles[i + 1],
					rest_lengths[i], distance_stiffness);
		}
		// 2. Bending (chord-length form, stable for low stiffness).
		for (int i = 0; i + 2 < n; i++) {
			tentacletech::constraints::project_bending(
					particles[i], particles[i + 1], particles[i + 2],
					rest_bending_chord_lengths[i], bending_stiffness);
		}
		// 3. Target-pull (soft) — single-particle, AI / behavior intent.
		if (target_active && target_particle_index >= 0 && target_particle_index < n) {
			tentacletech::constraints::project_target_pull(
					particles[target_particle_index], target_position, target_stiffness);
		}
		// 3.5. Pose targets — distributed multi-particle pull, used by the
		// behavior layer to write a full-body muscular pose. Composes
		// additively with the single target-pull above; the iteration loop
		// reconciles the two via the same projection operator so a curl
		// pose and a tip target don't fight each other in unexpected ways.
		{
			int pose_n = pose_target_indices.size();
			const int *pose_idx = pose_target_indices.ptr();
			const Vector3 *pose_pos = pose_target_positions.ptr();
			const float *pose_stf = pose_target_stiffnesses.ptr();
			for (int k = 0; k < pose_n; k++) {
				int idx = pose_idx[k];
				if (idx < 0 || idx >= n) continue;
				tentacletech::constraints::project_target_pull(
						particles[idx], pose_pos[k], pose_stf[k]);
			}
		}
		// 4. Collision normals — Phase 4.
		// 5. Friction tangential — Phase 4.
		// 6. Anchor last so it overrides any earlier violation.
		if (anchor_active && anchor_particle_index >= 0 && anchor_particle_index < n) {
			tentacletech::constraints::project_anchor(
					particles[anchor_particle_index], anchor_xform);
		}
	}
}

void PBDSolver::finalize(float p_dt) {
	int n = (int)particles.size();
	if (n < 2) {
		return;
	}

	// Per-segment volume preservation → particle girth_scale (§3.4).
	// Each particle averages the girth_scale of its neighbouring segments;
	// endpoints take their single neighbour's value.
	for (int i = 0; i < n; i++) {
		float scale_left = 1.0f;
		float scale_right = 1.0f;
		bool has_left = i > 0;
		bool has_right = i < n - 1;
		if (has_left) {
			float len = (particles[i].position - particles[i - 1].position).length();
			float rest = rest_lengths[i - 1];
			float ratio = (rest > 1e-8f) ? (len / rest) : 1.0f;
			if (ratio < 1e-4f) {
				ratio = 1e-4f;
			}
			scale_left = Math::sqrt(1.0f / ratio);
		}
		if (has_right) {
			float len = (particles[i + 1].position - particles[i].position).length();
			float rest = rest_lengths[i];
			float ratio = (rest > 1e-8f) ? (len / rest) : 1.0f;
			if (ratio < 1e-4f) {
				ratio = 1e-4f;
			}
			scale_right = Math::sqrt(1.0f / ratio);
		}
		if (has_left && has_right) {
			particles[i].girth_scale = 0.5f * (scale_left + scale_right);
		} else if (has_left) {
			particles[i].girth_scale = scale_left;
		} else {
			particles[i].girth_scale = scale_right;
		}
	}

	// Asymmetry decay + per-particle clamp (§3.4 Phase-2 subset: no orifice
	// pressure contribution yet).
	float decay = 1.0f - asymmetry_recovery_rate * p_dt;
	if (decay < 0.0f) {
		decay = 0.0f;
	}
	for (int i = 0; i < n; i++) {
		Vector2 a = particles[i].asymmetry * decay;
		float mag = a.length();
		if (mag > ASYMMETRY_MAGNITUDE_CAP) {
			a = a / mag * ASYMMETRY_MAGNITUDE_CAP;
		}
		particles[i].asymmetry = a;
	}

	// One-pass neighbour smoothing on both girth_scale and asymmetry. Read all
	// current values into the pre-allocated buffers first so that updated
	// neighbours don't bleed across the pass.
	for (int i = 0; i < n; i++) {
		smooth_girth_buffer[i] = particles[i].girth_scale;
		smooth_asym_buffer[i] = particles[i].asymmetry;
	}
	for (int i = 1; i < n - 1; i++) {
		particles[i].girth_scale =
				0.5f * smooth_girth_buffer[i] +
				0.25f * (smooth_girth_buffer[i - 1] + smooth_girth_buffer[i + 1]);
		particles[i].asymmetry =
				smooth_asym_buffer[i] * 0.5f +
				(smooth_asym_buffer[i - 1] + smooth_asym_buffer[i + 1]) * 0.25f;
	}

	// Re-clamp asymmetry magnitude after smoothing to guarantee the cap.
	for (int i = 0; i < n; i++) {
		float mag = particles[i].asymmetry.length();
		if (mag > ASYMMETRY_MAGNITUDE_CAP) {
			particles[i].asymmetry = particles[i].asymmetry / mag * ASYMMETRY_MAGNITUDE_CAP;
		}
	}
}

// -- Configuration ----------------------------------------------------------

void PBDSolver::set_iteration_count(int p_iter) {
	if (p_iter < 1) p_iter = 1;
	if (p_iter > MAX_ITERATION_COUNT) p_iter = MAX_ITERATION_COUNT;
	iteration_count = p_iter;
}
int PBDSolver::get_iteration_count() const { return iteration_count; }

void PBDSolver::set_gravity(const Vector3 &p_g) { gravity = p_g; }
Vector3 PBDSolver::get_gravity() const { return gravity; }

void PBDSolver::set_damping(float p_d) {
	if (p_d < 0.0f) p_d = 0.0f;
	if (p_d > 1.0f) p_d = 1.0f;
	damping = p_d;
}
float PBDSolver::get_damping() const { return damping; }

void PBDSolver::set_distance_stiffness(float p_s) {
	if (p_s < 0.0f) p_s = 0.0f;
	if (p_s > 1.0f) p_s = 1.0f;
	distance_stiffness = p_s;
}
float PBDSolver::get_distance_stiffness() const { return distance_stiffness; }

void PBDSolver::set_bending_stiffness(float p_s) {
	if (p_s < 0.0f) p_s = 0.0f;
	if (p_s > 1.0f) p_s = 1.0f;
	bending_stiffness = p_s;
}
float PBDSolver::get_bending_stiffness() const { return bending_stiffness; }

void PBDSolver::set_asymmetry_recovery_rate(float p_r) {
	if (p_r < 0.0f) p_r = 0.0f;
	asymmetry_recovery_rate = p_r;
}
float PBDSolver::get_asymmetry_recovery_rate() const { return asymmetry_recovery_rate; }

// -- Anchor -----------------------------------------------------------------

void PBDSolver::set_anchor(int p_idx, const Transform3D &p_xform) {
	int n = (int)particles.size();
	if (p_idx < 0 || p_idx >= n) {
		return;
	}
	if (anchor_active && anchor_particle_index != p_idx &&
			anchor_particle_index >= 0 && anchor_particle_index < n) {
		// Restore previous anchor's mobility.
		particles[anchor_particle_index].inv_mass = 1.0f;
	}
	anchor_active = true;
	anchor_particle_index = p_idx;
	anchor_xform = p_xform;
	particles[p_idx].inv_mass = 0.0f;
	particles[p_idx].position = p_xform.origin;
	particles[p_idx].prev_position = p_xform.origin;
}

void PBDSolver::clear_anchor() {
	int n = (int)particles.size();
	if (anchor_active && anchor_particle_index >= 0 && anchor_particle_index < n) {
		particles[anchor_particle_index].inv_mass = 1.0f;
	}
	anchor_active = false;
	anchor_particle_index = -1;
	anchor_xform = Transform3D();
}

bool PBDSolver::has_anchor() const { return anchor_active; }
int PBDSolver::get_anchor_particle_index() const { return anchor_particle_index; }
Transform3D PBDSolver::get_anchor_transform() const { return anchor_xform; }

// -- Target pull ------------------------------------------------------------

void PBDSolver::set_target(int p_idx, const Vector3 &p_pos, float p_stiff) {
	int n = (int)particles.size();
	if (p_idx < 0 || p_idx >= n) {
		return;
	}
	if (p_stiff < 0.0f) p_stiff = 0.0f;
	if (p_stiff > 1.0f) p_stiff = 1.0f;
	target_active = true;
	target_particle_index = p_idx;
	target_position = p_pos;
	target_stiffness = p_stiff;
}

void PBDSolver::clear_target() {
	target_active = false;
	target_particle_index = -1;
	target_position = Vector3();
}

bool PBDSolver::has_target() const { return target_active; }
int PBDSolver::get_target_particle_index() const { return target_particle_index; }
Vector3 PBDSolver::get_target_position() const { return target_position; }
float PBDSolver::get_target_stiffness() const { return target_stiffness; }

// -- Pose targets -----------------------------------------------------------

void PBDSolver::set_pose_targets(const PackedInt32Array &p_indices,
		const PackedVector3Array &p_world_positions,
		const PackedFloat32Array &p_stiffnesses) {
	int n_idx = p_indices.size();
	int n_pos = p_world_positions.size();
	int n_stf = p_stiffnesses.size();
	int n = (n_idx < n_pos ? n_idx : n_pos);
	if (n_stf < n) n = n_stf;
	pose_target_indices.resize(n);
	pose_target_positions.resize(n);
	pose_target_stiffnesses.resize(n);
	int *idx_ptr = pose_target_indices.ptrw();
	Vector3 *pos_ptr = pose_target_positions.ptrw();
	float *stf_ptr = pose_target_stiffnesses.ptrw();
	const int *src_idx = p_indices.ptr();
	const Vector3 *src_pos = p_world_positions.ptr();
	const float *src_stf = p_stiffnesses.ptr();
	for (int i = 0; i < n; i++) {
		idx_ptr[i] = src_idx[i];
		pos_ptr[i] = src_pos[i];
		float s = src_stf[i];
		if (s < 0.0f) s = 0.0f;
		if (s > 1.0f) s = 1.0f;
		stf_ptr[i] = s;
	}
}

void PBDSolver::clear_pose_targets() {
	pose_target_indices.clear();
	pose_target_positions.clear();
	pose_target_stiffnesses.clear();
}

int PBDSolver::get_pose_target_count() const {
	return pose_target_indices.size();
}

PackedInt32Array PBDSolver::get_pose_target_indices() const { return pose_target_indices; }
PackedVector3Array PBDSolver::get_pose_target_positions() const { return pose_target_positions; }
PackedFloat32Array PBDSolver::get_pose_target_stiffnesses() const { return pose_target_stiffnesses; }

// -- Per-particle accessors -------------------------------------------------

Vector3 PBDSolver::get_particle_position(int i) const {
	if (i < 0 || i >= (int)particles.size()) return Vector3();
	return particles[i].position;
}

void PBDSolver::set_particle_position(int i, const Vector3 &p) {
	if (i < 0 || i >= (int)particles.size()) return;
	particles[i].position = p;
	particles[i].prev_position = p;
}

float PBDSolver::get_particle_inv_mass(int i) const {
	if (i < 0 || i >= (int)particles.size()) return 0.0f;
	return particles[i].inv_mass;
}

void PBDSolver::set_particle_inv_mass(int i, float w) {
	if (i < 0 || i >= (int)particles.size()) return;
	if (w < 0.0f) w = 0.0f;
	particles[i].inv_mass = w;
}

Vector2 PBDSolver::get_particle_asymmetry(int i) const {
	if (i < 0 || i >= (int)particles.size()) return Vector2();
	return particles[i].asymmetry;
}

void PBDSolver::set_particle_asymmetry(int i, const Vector2 &a) {
	if (i < 0 || i >= (int)particles.size()) return;
	particles[i].asymmetry = a;
}

float PBDSolver::get_particle_girth_scale(int i) const {
	if (i < 0 || i >= (int)particles.size()) return 1.0f;
	return particles[i].girth_scale;
}

// -- Snapshot accessors -----------------------------------------------------

PackedVector3Array PBDSolver::get_particle_positions() const {
	PackedVector3Array out;
	int n = (int)particles.size();
	out.resize(n);
	Vector3 *ptr = out.ptrw();
	for (int i = 0; i < n; i++) {
		ptr[i] = particles[i].position;
	}
	return out;
}

PackedFloat32Array PBDSolver::get_particle_inv_masses() const {
	PackedFloat32Array out;
	int n = (int)particles.size();
	out.resize(n);
	float *ptr = out.ptrw();
	for (int i = 0; i < n; i++) {
		ptr[i] = particles[i].inv_mass;
	}
	return out;
}

PackedFloat32Array PBDSolver::get_segment_stretch_ratios() const {
	PackedFloat32Array out;
	int seg = (int)rest_lengths.size();
	out.resize(seg);
	float *ptr = out.ptrw();
	for (int i = 0; i < seg; i++) {
		float len = (particles[i + 1].position - particles[i].position).length();
		float rest = rest_lengths[i];
		ptr[i] = (rest > 1e-8f) ? (len / rest) : 1.0f;
	}
	return out;
}

PackedFloat32Array PBDSolver::get_particle_girth_scales() const {
	PackedFloat32Array out;
	int n = (int)particles.size();
	out.resize(n);
	float *ptr = out.ptrw();
	for (int i = 0; i < n; i++) {
		ptr[i] = particles[i].girth_scale;
	}
	return out;
}

float PBDSolver::get_rest_length(int i) const {
	if (i < 0 || i >= (int)rest_lengths.size()) return 0.0f;
	return rest_lengths[i];
}

void PBDSolver::set_uniform_rest_length(float p_length) {
	if (p_length < 1e-6f) p_length = 1e-6f;
	int seg = (int)rest_lengths.size();
	for (int i = 0; i < seg; i++) {
		rest_lengths[i] = p_length;
	}
	int bend = (int)rest_bending_chord_lengths.size();
	for (int i = 0; i < bend; i++) {
		rest_bending_chord_lengths[i] = 2.0f * p_length;
	}
}

// -- Binding ----------------------------------------------------------------

void PBDSolver::_bind_methods() {
	ClassDB::bind_method(D_METHOD("initialize_chain", "particle_count", "segment_length"),
			&PBDSolver::initialize_chain);
	ClassDB::bind_method(D_METHOD("tick", "dt"), &PBDSolver::tick);
	ClassDB::bind_method(D_METHOD("get_particle_count"), &PBDSolver::get_particle_count);
	ClassDB::bind_method(D_METHOD("get_segment_count"), &PBDSolver::get_segment_count);

	ClassDB::bind_method(D_METHOD("set_iteration_count", "iter"), &PBDSolver::set_iteration_count);
	ClassDB::bind_method(D_METHOD("get_iteration_count"), &PBDSolver::get_iteration_count);
	ClassDB::bind_method(D_METHOD("set_gravity", "gravity"), &PBDSolver::set_gravity);
	ClassDB::bind_method(D_METHOD("get_gravity"), &PBDSolver::get_gravity);
	ClassDB::bind_method(D_METHOD("set_damping", "damping"), &PBDSolver::set_damping);
	ClassDB::bind_method(D_METHOD("get_damping"), &PBDSolver::get_damping);
	ClassDB::bind_method(D_METHOD("set_distance_stiffness", "stiffness"), &PBDSolver::set_distance_stiffness);
	ClassDB::bind_method(D_METHOD("get_distance_stiffness"), &PBDSolver::get_distance_stiffness);
	ClassDB::bind_method(D_METHOD("set_bending_stiffness", "stiffness"), &PBDSolver::set_bending_stiffness);
	ClassDB::bind_method(D_METHOD("get_bending_stiffness"), &PBDSolver::get_bending_stiffness);
	ClassDB::bind_method(D_METHOD("set_asymmetry_recovery_rate", "rate"), &PBDSolver::set_asymmetry_recovery_rate);
	ClassDB::bind_method(D_METHOD("get_asymmetry_recovery_rate"), &PBDSolver::get_asymmetry_recovery_rate);

	ClassDB::bind_method(D_METHOD("set_anchor", "particle_index", "world_xform"), &PBDSolver::set_anchor);
	ClassDB::bind_method(D_METHOD("clear_anchor"), &PBDSolver::clear_anchor);
	ClassDB::bind_method(D_METHOD("has_anchor"), &PBDSolver::has_anchor);
	ClassDB::bind_method(D_METHOD("get_anchor_particle_index"), &PBDSolver::get_anchor_particle_index);
	ClassDB::bind_method(D_METHOD("get_anchor_transform"), &PBDSolver::get_anchor_transform);

	ClassDB::bind_method(D_METHOD("set_target", "particle_index", "world_pos", "stiffness"), &PBDSolver::set_target);
	ClassDB::bind_method(D_METHOD("clear_target"), &PBDSolver::clear_target);
	ClassDB::bind_method(D_METHOD("has_target"), &PBDSolver::has_target);
	ClassDB::bind_method(D_METHOD("get_target_particle_index"), &PBDSolver::get_target_particle_index);
	ClassDB::bind_method(D_METHOD("get_target_position"), &PBDSolver::get_target_position);
	ClassDB::bind_method(D_METHOD("get_target_stiffness"), &PBDSolver::get_target_stiffness);

	ClassDB::bind_method(D_METHOD("set_pose_targets", "indices", "world_positions", "stiffnesses"), &PBDSolver::set_pose_targets);
	ClassDB::bind_method(D_METHOD("clear_pose_targets"), &PBDSolver::clear_pose_targets);
	ClassDB::bind_method(D_METHOD("get_pose_target_count"), &PBDSolver::get_pose_target_count);
	ClassDB::bind_method(D_METHOD("get_pose_target_indices"), &PBDSolver::get_pose_target_indices);
	ClassDB::bind_method(D_METHOD("get_pose_target_positions"), &PBDSolver::get_pose_target_positions);
	ClassDB::bind_method(D_METHOD("get_pose_target_stiffnesses"), &PBDSolver::get_pose_target_stiffnesses);

	ClassDB::bind_method(D_METHOD("get_particle_position", "index"), &PBDSolver::get_particle_position);
	ClassDB::bind_method(D_METHOD("set_particle_position", "index", "position"), &PBDSolver::set_particle_position);
	ClassDB::bind_method(D_METHOD("get_particle_inv_mass", "index"), &PBDSolver::get_particle_inv_mass);
	ClassDB::bind_method(D_METHOD("set_particle_inv_mass", "index", "inv_mass"), &PBDSolver::set_particle_inv_mass);
	ClassDB::bind_method(D_METHOD("get_particle_asymmetry", "index"), &PBDSolver::get_particle_asymmetry);
	ClassDB::bind_method(D_METHOD("set_particle_asymmetry", "index", "asymmetry"), &PBDSolver::set_particle_asymmetry);
	ClassDB::bind_method(D_METHOD("get_particle_girth_scale", "index"), &PBDSolver::get_particle_girth_scale);

	ClassDB::bind_method(D_METHOD("get_particle_positions"), &PBDSolver::get_particle_positions);
	ClassDB::bind_method(D_METHOD("get_particle_inv_masses"), &PBDSolver::get_particle_inv_masses);
	ClassDB::bind_method(D_METHOD("get_segment_stretch_ratios"), &PBDSolver::get_segment_stretch_ratios);
	ClassDB::bind_method(D_METHOD("get_particle_girth_scales"), &PBDSolver::get_particle_girth_scales);

	ClassDB::bind_method(D_METHOD("get_rest_length", "segment_index"), &PBDSolver::get_rest_length);
	ClassDB::bind_method(D_METHOD("set_uniform_rest_length", "length"), &PBDSolver::set_uniform_rest_length);

	BIND_CONSTANT(DEFAULT_ITERATION_COUNT);
	BIND_CONSTANT(MAX_ITERATION_COUNT);
	BIND_CONSTANT(DEFAULT_PARTICLE_COUNT);
}
