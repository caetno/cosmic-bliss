#include "pbd_solver.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>

#include "constraints.h"
#include "../collision/friction_projection.h"

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

	rigid_base_count = 1;
	rigid_base_local_offsets.assign(1, Vector3());

	env_contact_points.clear();
	env_contact_normals.clear();
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
	apply_base_angular_clamp(p_dt);
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
		// 1. Bending first (chord-length form, stable for low stiffness).
		// High bending_stiffness pushes the chain back toward its rest
		// curvature each iteration, so the pose-pulls below have to fight
		// the bending term — which is what makes `bending_stiffness`
		// visibly affect chain rigidity even when a behavior driver is
		// writing pose targets every tick.
		for (int i = 0; i + 2 < n; i++) {
			tentacletech::constraints::project_bending(
					particles[i], particles[i + 1], particles[i + 2],
					rest_bending_chord_lengths[i], bending_stiffness);
		}
		// 2. Soft target-pulls — both the single AI/behavior tip target and
		// the distributed multi-particle pose targets. Applied after
		// bending so they have the last word on shape (modulated by their
		// own stiffness), and before distance below so they can't violate
		// segment-length integrity.
		if (target_active && target_particle_index >= 0 && target_particle_index < n) {
			tentacletech::constraints::project_target_pull(
					particles[target_particle_index], target_position, target_stiffness);
		}
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
		// 3. Distance constraints (segment length). Hard physics — runs
		// last among shape constraints so segments never end up stretched
		// or compressed by pose pulls.
		for (int i = 0; i + 1 < n; i++) {
			tentacletech::constraints::project_distance(
					particles[i], particles[i + 1],
					rest_lengths[i], distance_stiffness);
		}
		// 4. Type-4 environment collision: half-space projection per §4.2,
		// then unified §4.3 friction cone projection on the same particle in
		// the same iteration. Slice 4B layers friction on top of slice 4A's
		// normal-only correction. Type-1 reciprocal routing lands in 4D.
		{
			int contact_n = env_contact_points.size();
			if (contact_n > 0 && contact_n == env_contact_normals.size()) {
				const Vector3 *cp = env_contact_points.ptr();
				const Vector3 *cn = env_contact_normals.ptr();
				Vector3 *cf = (env_contact_friction_applied.size() == contact_n)
						? env_contact_friction_applied.ptrw()
						: nullptr;
				float mu_s = friction_static;
				float mu_k = friction_static * friction_kinetic_ratio;
				for (int i = 0; i < n; i++) {
					TentacleParticle &p = particles[i];
					if (p.inv_mass <= 0.0f) continue;
					float radius = collision_radius * p.girth_scale;
					if (radius < 1e-5f) continue;
					for (int c = 0; c < contact_n; c++) {
						float depth = radius - (p.position - cp[c]).dot(cn[c]);
						if (depth > 0.0f) {
							p.position += cn[c] * depth;
							if (mu_s > 0.0f) {
								Vector3 friction_applied;
								tentacletech::project_friction(p, cn[c], depth,
										mu_s, mu_k, friction_applied);
								if (cf != nullptr) {
									cf[c] += friction_applied;
								}
							}
						}
					}
				}
			}
		}
		// 6. Anchor last so it overrides any earlier violation.
		if (anchor_active && anchor_particle_index >= 0 && anchor_particle_index < n) {
			tentacletech::constraints::project_anchor(
					particles[anchor_particle_index], anchor_xform);
		}
	}
}

void PBDSolver::apply_base_angular_clamp(float p_dt) {
	if (base_angular_velocity_limit <= 0.0f) {
		return;
	}
	if (!anchor_active) {
		return;
	}
	int n = (int)particles.size();
	int anchor_idx = anchor_particle_index;
	if (anchor_idx < 0 || anchor_idx >= n) {
		return;
	}
	int neighbor_idx = anchor_idx + 1;
	if (neighbor_idx >= n) {
		neighbor_idx = anchor_idx - 1;
	}
	if (neighbor_idx < 0 || neighbor_idx >= n) {
		return;
	}
	TentacleParticle &np = particles[neighbor_idx];
	if (np.inv_mass <= 0.0f) {
		return;
	}
	Vector3 anchor_pos = particles[anchor_idx].position;
	Vector3 old_offset = np.prev_position - anchor_pos;
	Vector3 new_offset = np.position - anchor_pos;
	float old_len = old_offset.length();
	float new_len = new_offset.length();
	if (old_len < 1e-6f || new_len < 1e-6f) {
		return;
	}
	Vector3 old_dir = old_offset / old_len;
	Vector3 new_dir = new_offset / new_len;
	float cos_angle = old_dir.dot(new_dir);
	if (cos_angle > 1.0f) cos_angle = 1.0f;
	if (cos_angle < -1.0f) cos_angle = -1.0f;
	float angle = Math::acos(cos_angle);
	float max_angle = base_angular_velocity_limit * p_dt;
	if (angle <= max_angle) {
		return;
	}
	Vector3 axis = old_dir.cross(new_dir);
	float axis_len = axis.length();
	if (axis_len < 1e-6f) {
		// Old and new are (anti-)collinear; rotation axis is undefined. Snap
		// the radial extent only — leaves the direction unchanged.
		return;
	}
	axis = axis / axis_len;
	Vector3 clamped_dir = old_dir.rotated(axis, max_angle);
	np.position = anchor_pos + clamped_dir * new_len;
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

void PBDSolver::set_base_angular_velocity_limit(float p_omega) {
	if (p_omega < 0.0f) p_omega = 0.0f;
	base_angular_velocity_limit = p_omega;
}
float PBDSolver::get_base_angular_velocity_limit() const { return base_angular_velocity_limit; }

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

	// Apply the rigid-base block: every particle in [0, rigid_base_count)
	// snaps to the anchor's frame via its stored local offset and stays
	// pinned (inv_mass = 0). The primary anchor particle was just placed at
	// the transform origin above; the other rigid particles ride along.
	int rigid_n = rigid_base_count;
	if (rigid_n > n) rigid_n = n;
	if (rigid_n > (int)rigid_base_local_offsets.size()) {
		rigid_n = (int)rigid_base_local_offsets.size();
	}
	for (int k = 0; k < rigid_n; k++) {
		if (k == p_idx) continue;
		Vector3 world = p_xform.xform(rigid_base_local_offsets[k]);
		particles[k].inv_mass = 0.0f;
		particles[k].position = world;
		particles[k].prev_position = world;
	}
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

void PBDSolver::set_rigid_base_count(int p_count) {
	int n = (int)particles.size();
	if (p_count < 1) p_count = 1;
	if (p_count > n) p_count = n;
	int old_count = rigid_base_count;

	// Capture local offsets for the new rigid range relative to the current
	// anchor frame (or world, if no anchor is set yet — same effect since
	// the scene-construction path lays particles in the anchor's frame).
	Transform3D inv = anchor_active ? anchor_xform.affine_inverse() : Transform3D();
	rigid_base_local_offsets.assign((size_t)p_count, Vector3());
	for (int k = 0; k < p_count; k++) {
		rigid_base_local_offsets[k] = inv.xform(particles[k].position);
		particles[k].inv_mass = 0.0f;
	}
	// Restore mobility for particles that are no longer rigid.
	for (int k = p_count; k < old_count && k < n; k++) {
		// Skip the primary anchor — it has its own pin lifecycle.
		if (anchor_active && k == anchor_particle_index) continue;
		particles[k].inv_mass = 1.0f;
	}
	rigid_base_count = p_count;
}

int PBDSolver::get_rigid_base_count() const { return rigid_base_count; }

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
	// Rigid base block stays pinned regardless of external writes — the
	// behavior layer's mass_from_girth pass would otherwise unpin them.
	if (i < rigid_base_count) return;
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

// -- Environment collision --------------------------------------------------

void PBDSolver::set_environment_contacts(const PackedVector3Array &p_points,
		const PackedVector3Array &p_normals) {
	int np = p_points.size();
	int nn = p_normals.size();
	int n = np < nn ? np : nn;
	env_contact_points.resize(n);
	env_contact_normals.resize(n);
	env_contact_friction_applied.resize(n);
	// Friction accumulator zeroed each tick when contacts are written.
	if (n > 0) {
		Vector3 *dst_f = env_contact_friction_applied.ptrw();
		for (int i = 0; i < n; i++) {
			dst_f[i] = Vector3();
		}
	}
	if (n == 0) {
		return;
	}
	const Vector3 *src_p = p_points.ptr();
	const Vector3 *src_n = p_normals.ptr();
	Vector3 *dst_p = env_contact_points.ptrw();
	Vector3 *dst_n = env_contact_normals.ptrw();
	for (int i = 0; i < n; i++) {
		dst_p[i] = src_p[i];
		// Defensive normalization — a degenerate (zero) normal would otherwise
		// turn `(p - cp) · n` into 0 and the projection would push every
		// particle out by `radius` along the zero vector (no-op) every iter.
		// Cheap to fix at write time, keeps the iteration loop branch-free.
		Vector3 nrm = src_n[i];
		float l2 = nrm.length_squared();
		if (l2 > 1e-10f) {
			nrm = nrm / Math::sqrt(l2);
		} else {
			nrm = Vector3();
		}
		dst_n[i] = nrm;
	}
}

void PBDSolver::clear_environment_contacts() {
	env_contact_points.clear();
	env_contact_normals.clear();
	env_contact_friction_applied.clear();
}

int PBDSolver::get_environment_contact_count() const {
	return env_contact_points.size();
}

PackedVector3Array PBDSolver::get_environment_friction_applied() const {
	return env_contact_friction_applied;
}

void PBDSolver::set_collision_radius(float p_radius) {
	if (p_radius < 0.0f) p_radius = 0.0f;
	collision_radius = p_radius;
}

float PBDSolver::get_collision_radius() const { return collision_radius; }

void PBDSolver::set_friction(float p_static, float p_kinetic_ratio) {
	if (p_static < 0.0f) p_static = 0.0f;
	if (p_kinetic_ratio < 0.0f) p_kinetic_ratio = 0.0f;
	if (p_kinetic_ratio > 1.0f) p_kinetic_ratio = 1.0f;
	friction_static = p_static;
	friction_kinetic_ratio = p_kinetic_ratio;
}

float PBDSolver::get_static_friction() const { return friction_static; }
float PBDSolver::get_kinetic_friction_ratio() const { return friction_kinetic_ratio; }

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
	ClassDB::bind_method(D_METHOD("set_base_angular_velocity_limit", "omega"), &PBDSolver::set_base_angular_velocity_limit);
	ClassDB::bind_method(D_METHOD("get_base_angular_velocity_limit"), &PBDSolver::get_base_angular_velocity_limit);

	ClassDB::bind_method(D_METHOD("set_anchor", "particle_index", "world_xform"), &PBDSolver::set_anchor);
	ClassDB::bind_method(D_METHOD("clear_anchor"), &PBDSolver::clear_anchor);
	ClassDB::bind_method(D_METHOD("has_anchor"), &PBDSolver::has_anchor);
	ClassDB::bind_method(D_METHOD("get_anchor_particle_index"), &PBDSolver::get_anchor_particle_index);
	ClassDB::bind_method(D_METHOD("get_anchor_transform"), &PBDSolver::get_anchor_transform);

	ClassDB::bind_method(D_METHOD("set_rigid_base_count", "count"), &PBDSolver::set_rigid_base_count);
	ClassDB::bind_method(D_METHOD("get_rigid_base_count"), &PBDSolver::get_rigid_base_count);

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

	ClassDB::bind_method(D_METHOD("set_environment_contacts", "points", "normals"),
			&PBDSolver::set_environment_contacts);
	ClassDB::bind_method(D_METHOD("clear_environment_contacts"), &PBDSolver::clear_environment_contacts);
	ClassDB::bind_method(D_METHOD("get_environment_contact_count"), &PBDSolver::get_environment_contact_count);
	ClassDB::bind_method(D_METHOD("get_environment_friction_applied"),
			&PBDSolver::get_environment_friction_applied);
	ClassDB::bind_method(D_METHOD("set_collision_radius", "radius"), &PBDSolver::set_collision_radius);
	ClassDB::bind_method(D_METHOD("get_collision_radius"), &PBDSolver::get_collision_radius);
	ClassDB::bind_method(D_METHOD("set_friction", "static_coeff", "kinetic_ratio"),
			&PBDSolver::set_friction);
	ClassDB::bind_method(D_METHOD("get_static_friction"), &PBDSolver::get_static_friction);
	ClassDB::bind_method(D_METHOD("get_kinetic_friction_ratio"),
			&PBDSolver::get_kinetic_friction_ratio);

	BIND_CONSTANT(DEFAULT_ITERATION_COUNT);
	BIND_CONSTANT(MAX_ITERATION_COUNT);
	BIND_CONSTANT(DEFAULT_PARTICLE_COUNT);
}
