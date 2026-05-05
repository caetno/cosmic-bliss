#include "pbd_solver.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>

#include "constraints.h"
#include "../collision/environment_probe.h" // MAX_CONTACTS_PER_PARTICLE

namespace {
constexpr int MAX_CONTACTS = tentacletech::MAX_CONTACTS_PER_PARTICLE;

// Slice 4M-XPBD — public 0..1 stiffness knob mapped to physical XPBD
// compliance. Log-spaced so stiffness=1 reads near-rigid (compliance 1e-9)
// and stiffness=0 reads very soft (compliance 1e-3). Compliance 0 is
// equivalent to infinite stiffness — XPBD then reduces to plain PBD without
// lambda damping. We avoid exact 0 to keep the formulas stable.
inline float stiffness_to_compliance(float s) {
	if (s < 0.0f) s = 0.0f;
	if (s > 1.0f) s = 1.0f;
	float log_compliance = -9.0f + 6.0f * (1.0f - s);
	return godot::Math::pow(10.0f, log_compliance);
}
}

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

	// Slice 4M Jacobi accumulator buffers — sized once here; per-step apply
	// zeroes them as deltas drain.
	position_delta_scratch.assign((size_t)p_n, Vector3());
	position_delta_count.assign((size_t)p_n, 0);

	// Slice 4M-XPBD distance lambdas — one per segment, reset per tick.
	distance_lambdas.assign((size_t)(p_n - 1), 0.0f);

	// Slice 4M per-slot contact lambdas. Sized to N×MAX_CONTACTS so
	// set_environment_contacts_multi can write them in lockstep with
	// env_contact_points/normals/etc. Reset each time fresh probe data lands.
	int slot_total = p_n * MAX_CONTACTS;
	env_contact_normal_lambda.assign((size_t)slot_total, 0.0f);
	env_contact_tangent_lambda.assign((size_t)slot_total, Vector3());
	env_contact_rid.assign((size_t)slot_total, 0);

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
	env_contact_count.clear();
	env_contact_friction_applied.clear();
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
	iterate(p_dt);
	apply_base_angular_clamp(p_dt);
	finalize(p_dt);
}

void PBDSolver::predict(float p_dt) {
	float dt2 = p_dt * p_dt;
	int n = (int)particles.size();
	// Slice 4M-XPBD — distance constraint Lagrange multipliers reset each
	// tick (per-substep once 4O lands). Forgetting this reset = compounding
	// across ticks → diverging oscillation; `test_distance_xpbd_does_not_
	// explode_without_lambda_reset` is the canary that catches it.
	if ((int)distance_lambdas.size() != n - 1) {
		distance_lambdas.assign((size_t)(n - 1), 0.0f);
	} else {
		for (int i = 0; i < n - 1; i++) {
			distance_lambdas[i] = 0.0f;
		}
	}
	// Slice 4K: gravity-support preconditions. Probe runs before solver.tick(),
	// so env_contact_count / env_contact_normals reflect THIS tick's contacts
	// already. Slice 4M: with multi-contact, project gravity onto the
	// tangent plane of the deepest contact (slot 0). Two-contact wedge:
	// the bisector argument applies to friction, but for gravity support
	// the deepest contact carries the load and the second contact's
	// projection in iterate step 3 will absorb the residual normal
	// component if needed.
	bool have_contact_data = (env_contact_count.size() == n &&
			env_contact_normals.size() == n * MAX_CONTACTS);
	const uint8_t *cnt = have_contact_data ? env_contact_count.ptr() : nullptr;
	const Vector3 *cn_arr = have_contact_data ? env_contact_normals.ptr() : nullptr;
	for (int i = 0; i < n; i++) {
		TentacleParticle &p = particles[i];
		// Slice 4C: clear the per-tick contact flag here so the iteration
		// loop can set it as collisions are projected. Step 2's
		// 4Q-fix taper has its own probe-count-based gate (slice 4R) so
		// it doesn't depend on iter step 3 having run yet.
		p.in_contact_this_tick = false;
		if (p.inv_mass <= 0.0f) {
			// Pinned: prev_position tracks position so velocity stays zero.
			p.prev_position = p.position;
			continue;
		}
		Vector3 temp_prev = p.prev_position;
		p.prev_position = p.position;
		Vector3 velocity = (p.position - temp_prev) * damping;
		Vector3 gravity_step = gravity * dt2;
		if (support_in_contact && have_contact_data && cnt[i] != 0) {
			// In contact: project gravity onto the deepest contact's tangent
			// plane. The contact supports the normal-direction gravity
			// component; only tangent component (slope-driven sliding)
			// acts on the particle. Eliminates the per-tick "gravity sinks
			// particle into surface, iter loop pushes back out" cycle
			// which seeds the tick-rate jitter the user reported (slice
			// 4K). Slot 0 is the deepest contact (slice 4M.2 ordering).
			Vector3 cn = cn_arr[i * MAX_CONTACTS + 0];
			if (cn.length_squared() > 1e-10f) {
				gravity_step -= cn * gravity_step.dot(cn);
			}
		}
		p.position += velocity + gravity_step;
	}
}

void PBDSolver::iterate(float p_dt) {
	int n = (int)particles.size();
	bool have_contacts = (env_contact_count.size() == n &&
			env_contact_points.size() == n * MAX_CONTACTS &&
			env_contact_normals.size() == n * MAX_CONTACTS);

	// Slice 4M — Jacobi-with-atomic-deltas-and-SOR + per-contact persistent
	// lambda accumulators. Each constraint step accumulates per-particle
	// position deltas via add_position_delta; once-per-step apply averages
	// the deltas (sor_factor / count) and writes to position. Within a step,
	// multiple constraints touching the same particle (most importantly: 2+
	// collision contacts on a wedged particle) compose by Jacobi average
	// rather than Gauss-Seidel "last writer wins" — that's the structural
	// fix for the wedge-flicker the cluster targets.
	//
	// Per-segment XPBD distance lambdas (`distance_lambdas`, reset in
	// predict()) accumulate across iters within the tick — this is what
	// makes XPBD position-correct under repeated solves and removes the
	// "stiffness × N_iters compounds" artifact of plain PBD distance.
	//
	// Per-contact normal/tangent lambdas (`env_contact_normal_lambda`,
	// `env_contact_tangent_lambda`, reset by set_environment_contacts_multi)
	// scale friction cones with the contact's actually-accumulated normal
	// impulse, replacing slice 4L's `iter_dn_buffer` per-particle scratch.

	const float compliance_distance_base = stiffness_to_compliance(distance_stiffness);
	const float compliance_distance_contact = stiffness_to_compliance(contact_stiffness);
	// XPBD compliance term scales as α/dt² (Macklin 2016).
	const float dt2_inv = 1.0f / (p_dt * p_dt + 1e-20f);
	const float max_dlambda_norm = max_depenetration * p_dt;

	int total_slots = n * MAX_CONTACTS;
	Vector3 *cf_out = (env_contact_friction_applied.size() == total_slots)
			? env_contact_friction_applied.ptrw()
			: nullptr;
	float *nlambda_arr = ((int)env_contact_normal_lambda.size() == total_slots)
			? env_contact_normal_lambda.data()
			: nullptr;
	Vector3 *tlambda_arr = ((int)env_contact_tangent_lambda.size() == total_slots)
			? env_contact_tangent_lambda.data()
			: nullptr;

	for (int iter = 0; iter < iteration_count; iter++) {
		// 1. Bending — chord-length form. Each constraint mutates two
		// particles (a, c). Particles touched by both bending(i-2,i-1,i)
		// and bending(i,i+1,i+2) get their two corrections averaged via
		// Jacobi+SOR.
		for (int i = 0; i + 2 < n; i++) {
			TentacleParticle &p_a = particles[i];
			TentacleParticle &p_c = particles[i + 2];
			float w_sum = p_a.inv_mass + p_c.inv_mass;
			if (w_sum <= 0.0f) continue;
			Vector3 d = p_c.position - p_a.position;
			float dist = d.length();
			if (dist < 1e-8f) continue;
			float diff = dist - rest_bending_chord_lengths[i];
			Vector3 dir = d / dist;
			Vector3 corr = dir * (bending_stiffness * diff / w_sum);
			if (p_a.inv_mass > 0.0f) {
				add_position_delta(i, corr * p_a.inv_mass);
			}
			if (p_c.inv_mass > 0.0f) {
				add_position_delta(i + 2, -corr * p_c.inv_mass);
			}
		}
		apply_position_deltas_all();

		// 2. Soft target-pulls — singleton tip target + distributed pose
		// targets. Lerp-style (soft-by-construction); each call adds a
		// delta = (target - position) × stiffness. Slice 4M-pre.2 softening
		// for in-contact particles applies to both paths.
		//
		// Slice 4Q-fix — tension-aware taper. For each in-contact particle,
		// look up the dominant contact slot (max normal_lambda) and compute
		// the per-slot tension fraction `t = |tangent_lambda| / (mu_s ×
		// normal_lambda)`. When t exceeds `tension_taper_threshold` (default
		// 0.8), the target stiffness is further multiplied by `(1 - over)`
		// where `over = (t - threshold) / (1 - threshold)`, ramping from 1
		// at threshold to 0 at saturation. Composes multiplicatively with
		// `target_softness_when_blocked`. Iter 0 sees zero tangent_lambda
		// (reset in set_environment_contacts_multi) so no taper applies on
		// the first pass; subsequent iters read the previous iter's friction
		// step output and back off the target if friction is at its limit.
		// This extinguishes the 4Q stick-slip cycle by capping how much
		// elastic tension the chain can build into a static-cone-bounded
		// contact.
		const float mu_s_taper = friction_static;
		const float taper_thr = tension_taper_threshold;
		auto compute_tension_taper = [&](int p_particle_idx) -> float {
			// Picks the dominant slot (max normal_lambda) for the particle
			// and forwards to the static formula helper. Returns 1.0
			// when no contact / no friction → safe to call unconditionally.
			if (nlambda_arr == nullptr || tlambda_arr == nullptr) return 1.0f;
			int base = p_particle_idx * MAX_CONTACTS;
			float dom_lambda = 0.0f;
			int dom_slot = -1;
			for (int k = 0; k < MAX_CONTACTS; k++) {
				float ln = nlambda_arr[base + k];
				if (ln > dom_lambda) {
					dom_lambda = ln;
					dom_slot = k;
				}
			}
			if (dom_slot < 0) return 1.0f;
			float tlam_mag = tlambda_arr[base + dom_slot].length();
			return compute_tension_taper_factor(taper_thr, mu_s_taper,
					dom_lambda, tlam_mag);
		};

		if (target_active && target_particle_index >= 0 && target_particle_index < n) {
			TentacleParticle &pp = particles[target_particle_index];
			if (pp.inv_mass > 0.0f) {
				float ts = target_stiffness;
				// Slice 4M-pre.2: existing in-contact softening (gated on
				// the iter-side flag). Slice 4Q-fix taper: applied
				// unconditionally (returns 1.0 when not in a meaningful
				// contact, so it's a no-op for non-contact particles).
				// This preserves the previous "iter 0 cold target push,
				// iter 1+ softened" cycle that 4Q-fix was tuned around.
				if (pp.in_contact_this_tick) {
					ts *= target_softness_when_blocked;
				}
				ts *= compute_tension_taper(target_particle_index);
				if (ts > 0.0f) {
					Vector3 d = (target_position - pp.position) * ts;
					add_position_delta(target_particle_index, d);
				}
			}
		}
		{
			int pose_n = pose_target_indices.size();
			const int *pose_idx = pose_target_indices.ptr();
			const Vector3 *pose_pos = pose_target_positions.ptr();
			const float *pose_stf = pose_target_stiffnesses.ptr();
			for (int k = 0; k < pose_n; k++) {
				int idx = pose_idx[k];
				if (idx < 0 || idx >= n) continue;
				TentacleParticle &pp = particles[idx];
				if (pp.inv_mass <= 0.0f) continue;
				float ps = pose_stf[k];
				if (pp.in_contact_this_tick) {
					ps *= target_softness_when_blocked;
				}
				ps *= compute_tension_taper(idx);
				if (ps <= 0.0f) continue;
				Vector3 d = (pose_pos[k] - pp.position) * ps;
				add_position_delta(idx, d);
			}
		}
		apply_position_deltas_all();

		// 3. Type-4 environment collision — per-contact XPBD penetration
		// constraint with persistent normal_lambda accumulator. Pattern
		// from `pbd_research/Obi/Resources/Compute/ContactHandling.cginc::
		// SolvePenetration` + `ColliderCollisionConstraints.compute::Project`.
		//
		// `dist` is the signed gap between the particle surface and the
		// contact plane. dist < 0 means penetrating. dlambda is computed
		// to push the particle to dist=0 (with the depenetration cap
		// limiting per-iter velocity). new_lambda is clamped to ≥ 0 so
		// contacts only push, never pull.
		//
		// Multi-contact wedge: each slot writes its own delta. The Jacobi
		// apply averages the two corrections — for opposed normals the
		// average is small (correctly: PBD has nothing to push against
		// a pinch); for diverging normals the bisector emerges naturally.
		// No special-case bisector heuristic, no per-particle dn budget.
		if (have_contacts && nlambda_arr != nullptr) {
			const uint8_t *cnt = env_contact_count.ptr();
			const Vector3 *cp = env_contact_points.ptr();
			const Vector3 *cn = env_contact_normals.ptr();
			for (int i = 0; i < n; i++) {
				int kn = cnt[i];
				if (kn == 0) continue;
				TentacleParticle &p = particles[i];
				if (p.inv_mass <= 0.0f) continue;
				float smooth_radius = collision_radius * p.girth_scale;
				if (smooth_radius < 1e-5f) continue;
				p.in_contact_this_tick = true;
				int base = i * MAX_CONTACTS;
				for (int k = 0; k < kn; k++) {
					int slot = base + k;
					Vector3 cn_k = cn[slot];
					if (cn_k.length_squared() < 1e-10f) continue;
					// Slice 5H — per-contact effective radius. The smooth
					// `girth_scale × collision_radius` is augmented by a
					// silhouette sample at (s, θ) where the contact normal
					// hits the body. Sampler is a function pointer; null →
					// behaves as 5G baseline.
					float radius = smooth_radius;
					if (feature_silhouette_fn != nullptr) {
						float perturbation = feature_silhouette_fn(
								feature_silhouette_user, i, cp[slot]);
						radius += perturbation;
						if (radius < 1e-5f) radius = 1e-5f;
					}
					// Signed distance from the particle surface to contact
					// plane. < 0 → penetrating.
					float dist = (p.position - cp[slot]).dot(cn_k) - radius;
					float normal_mass = p.inv_mass; // collider treated as ∞ mass
					if (normal_mass <= 0.0f) continue;
					// Cap projection magnitude per iter to maxDepenetration·dt
					// so deeply-penetrated particles eject over multiple
					// ticks rather than one explosive frame.
					float max_proj = -dist - max_dlambda_norm;
					if (max_proj < 0.0f) max_proj = 0.0f;
					float dlambda = -(dist + max_proj) / normal_mass;
					float new_lambda = nlambda_arr[slot] + dlambda;
					if (new_lambda < 0.0f) new_lambda = 0.0f; // contacts only push
					float lambda_change = new_lambda - nlambda_arr[slot];
					nlambda_arr[slot] = new_lambda;
					if (lambda_change > 1e-8f || lambda_change < -1e-8f) {
						add_position_delta(i, cn_k * (lambda_change * p.inv_mass));
					}
				}
			}
			apply_position_deltas_all();
		}

		// 4. Distance constraints — Slice 4M-XPBD canonical compliance form
		// (`pbd_research/Obi/Resources/Compute/DistanceConstraints.compute`).
		// Per-segment lambda accumulates across iters; compliance is
		// stiffness_to_compliance(public_stiffness)/dt². When either
		// endpoint is in active contact the segment uses
		// `contact_stiffness` instead — same XPBD form, larger compliance,
		// so wrapped geometry stretches over the surface instead of
		// fighting the contact normal projection. The slice 4M-pre.3
		// "wedge factor" is gone — XPBD's lambda damping already handles
		// the both-endpoints-wedged case without a special-case knob.
		for (int i = 0; i + 1 < n; i++) {
			TentacleParticle &p_a = particles[i];
			TentacleParticle &p_b = particles[i + 1];
			float w_sum = p_a.inv_mass + p_b.inv_mass;
			if (w_sum <= 0.0f) continue;
			// Public knob stiffness=0 means "disable this constraint" —
			// preserves the PBD semantics test_volume_preservation relies on.
			// Without this early exit, stiffness=0 maps to compliance 1e-3
			// which still applies a small correction per iter.
			float effective_stiffness = (p_a.in_contact_this_tick || p_b.in_contact_this_tick)
					? contact_stiffness
					: distance_stiffness;
			if (effective_stiffness <= 0.0f) continue;
			Vector3 d = p_a.position - p_b.position;
			float dist = d.length();
			if (dist < 1e-8f) continue;
			float constraint = dist - rest_lengths[i];
			float compliance = (p_a.in_contact_this_tick || p_b.in_contact_this_tick)
					? compliance_distance_contact
					: compliance_distance_base;
			compliance *= dt2_inv;
			float &lambda = distance_lambdas[i];
			float dlambda = (-constraint - compliance * lambda) /
					(w_sum + compliance + 1e-8f);
			lambda += dlambda;
			Vector3 delta = (d / dist) * dlambda;
			if (p_a.inv_mass > 0.0f) {
				add_position_delta(i, delta * p_a.inv_mass);
			}
			if (p_b.inv_mass > 0.0f) {
				add_position_delta(i + 1, -delta * p_b.inv_mass);
			}
		}
		apply_position_deltas_all();

		// 5. Friction (§4.3) — per-contact lambda-bounded cone. Cone scales
		// with that contact's accumulated normal_lambda (Obi
		// `ContactHandling.cginc::SolveFriction` adapted to a 1D cone). The
		// per-iter tangent motion is `dx_tangent = (position − prev_position)
		// projected onto the contact tangent plane`; static cone fully
		// cancels it, kinetic cone caps the cancellation at μ_k × λ_n.
		// Multi-contact: each slot runs its own friction projection. The
		// Jacobi+SOR apply averages the slots' position deltas (a particle
		// rubbing against two surfaces gets the sum-of-frictions in
		// reciprocal-impulse space but only the average in position space).
		// `friction_applied` per-slot accumulates across iters for the
		// type-1 reciprocal pass in Tentacle::_apply_collision_reciprocals.
		if (have_contacts && friction_static > 0.0f && nlambda_arr != nullptr &&
				tlambda_arr != nullptr && cf_out != nullptr) {
			const uint8_t *cnt = env_contact_count.ptr();
			const Vector3 *cn = env_contact_normals.ptr();
			float mu_s = friction_static;
			float mu_k = friction_static * friction_kinetic_ratio;
			for (int i = 0; i < n; i++) {
				int kn = cnt[i];
				if (kn == 0) continue;
				TentacleParticle &p = particles[i];
				if (p.inv_mass <= 0.0f) continue;
				int base = i * MAX_CONTACTS;
				Vector3 dx = p.position - p.prev_position;
				for (int k = 0; k < kn; k++) {
					int slot = base + k;
					float lam_n = nlambda_arr[slot];
					if (lam_n <= 0.0f) continue; // contact not pressing
					Vector3 cn_k = cn[slot];
					if (cn_k.length_squared() < 1e-10f) continue;
					Vector3 dx_tan = dx - cn_k * dx.dot(cn_k);
					float tan_mag = dx_tan.length();
					if (tan_mag < 1e-8f) continue;
					Vector3 dx_tan_dir = dx_tan / tan_mag;
					float static_cone = mu_s * lam_n;
					float kinetic_cone = mu_k * lam_n;
					// `tan_mag × mass` (m·kg) compared against cone (m·kg).
					// inv_mass = 0/1 in our codebase, so divide-by-inv_mass
					// is just identity — the formula reduces to
					// "if tan_mag <= static_cone, fully cancel; else clamp at
					// kinetic_cone" in length units.
					float inv_m = (p.inv_mass > 1e-8f) ? p.inv_mass : 1e-8f;
					float tan_mag_kgm = tan_mag / inv_m;
					float lambda_t_delta;
					if (tan_mag_kgm <= static_cone) {
						lambda_t_delta = -tan_mag_kgm; // full static-cone cancel
					} else {
						lambda_t_delta = -kinetic_cone; // kinetic cap
					}
					Vector3 friction_delta = dx_tan_dir * (lambda_t_delta * p.inv_mass);
					add_position_delta(i, friction_delta);
					tlambda_arr[slot] += dx_tan_dir * lambda_t_delta;
					cf_out[slot] -= friction_delta;
				}
			}
			apply_position_deltas_all();
		}

		// 6. Anchor last — direct write so it overrides any earlier
		// violation. Anchors are not lambda-form constraints; no Jacobi
		// average makes sense for a hard pin.
		if (anchor_active && anchor_particle_index >= 0 && anchor_particle_index < n) {
			tentacletech::constraints::project_anchor(
					particles[anchor_particle_index], anchor_xform);
		}
	}

	// No end-of-tick cleanup pass — under per-contact lambda accumulation,
	// the iter loop converges within itself; residual penetration the
	// previous slice 4J pass swept away no longer materializes. (4J +
	// `iter_dn_buffer` were both patches for the missing lambda model,
	// subsumed by 4M.)
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

	// Slice 4I — contact velocity damping (§4.3 footnote, addresses tick-rate
	// jitter from constraint conflict during contact). PBD's iterate loop
	// can fail to converge when bending / pose / distance pull a contacting
	// particle in directions collision must reverse — each iter introduces
	// non-zero net displacement, summed across iter_count this becomes
	// implicit per-tick velocity that carries forward via Verlet
	// integration in next predict(). Lerp prev_position toward position for
	// in-contact particles to bleed off that residual velocity at tick end.
	// 0 = disabled, 1 = fully kill velocity. 0.5 default halves it per
	// tick, killing visible oscillation in 4–5 ticks while leaving
	// legitimate sliding (high tick-to-tick velocity, decays slowly) intact.
	if (contact_velocity_damping > 1e-5f) {
		float t = contact_velocity_damping;
		if (t > 1.0f) t = 1.0f;
		for (int i = 0; i < n; i++) {
			TentacleParticle &p = particles[i];
			if (!p.in_contact_this_tick) continue;
			if (p.inv_mass <= 0.0f) continue;
			p.prev_position = p.prev_position.lerp(p.position, t);
		}
	}

	// Slice 4P — sleep threshold. In-contact particles whose tick-rate
	// velocity falls below `sleep_threshold` (m/s) have their position
	// snapped to prev_position, killing residual implicit velocity from
	// un-converged constraints. Default 0 = disabled. Pattern from
	// `pbd_research/Obi/Resources/Compute/Solver.compute:204-217`. Free
	// (out-of-contact) particles never sleep so a tentacle hanging in air
	// keeps integrating gravity normally; only settled-against-surface
	// particles get clamped. The check uses `(Δx)² ≤ (threshold·dt)²` so
	// the comparison is a single multiply per particle.
	if (sleep_threshold > 0.0f) {
		float thr_dx = sleep_threshold * p_dt;
		float thr_dx2 = thr_dx * thr_dx;
		for (int i = 0; i < n; i++) {
			TentacleParticle &p = particles[i];
			if (!p.in_contact_this_tick) continue;
			if (p.inv_mass <= 0.0f) continue;
			Vector3 v = p.position - p.prev_position;
			if (v.length_squared() <= thr_dx2) {
				p.position = p.prev_position;
			}
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
	// Slice 4T — clear arms the cold-start bypass for the next set_target.
	_target_warm = false;
	prev_target_position = Vector3();
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
	// Slice 4T — fingerprint check on the pose-target indices array. If the
	// new indices match the previous call element-wise (same particles same
	// order), keep the parallel `_pose_target_warm` + `prev_pose_target_positions`
	// flags so warm-running clamping continues. If indices changed, rebuild
	// the parallel arrays from scratch (all cold).
	bool indices_match = ((int)_pose_target_warm.size() == n
			&& pose_target_indices.size() == n);
	if (indices_match) {
		const int *cur_idx = pose_target_indices.ptr();
		const int *new_idx = p_indices.ptr();
		for (int i = 0; i < n; i++) {
			if (cur_idx[i] != new_idx[i]) {
				indices_match = false;
				break;
			}
		}
	}
	pose_target_indices.resize(n);
	pose_target_positions.resize(n);
	pose_target_stiffnesses.resize(n);
	if (!indices_match) {
		_pose_target_warm.assign((size_t)n, false);
		prev_pose_target_positions.resize(n);
		Vector3 *prev_ptr = prev_pose_target_positions.ptrw();
		for (int i = 0; i < n; i++) {
			prev_ptr[i] = Vector3();
		}
	} else {
		// Indices preserved; arrays may have been resized above to the same
		// length, so the parallel buffers stay correct.
		if ((int)_pose_target_warm.size() != n) _pose_target_warm.resize((size_t)n, false);
		if (prev_pose_target_positions.size() != n) prev_pose_target_positions.resize(n);
	}
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
	// Slice 4T — clear arms the cold-start bypass.
	_pose_target_warm.clear();
	prev_pose_target_positions.clear();
}

int PBDSolver::get_pose_target_count() const {
	return pose_target_indices.size();
}

PackedInt32Array PBDSolver::get_pose_target_indices() const { return pose_target_indices; }
PackedVector3Array PBDSolver::get_pose_target_positions() const { return pose_target_positions; }
PackedFloat32Array PBDSolver::get_pose_target_stiffnesses() const { return pose_target_stiffnesses; }

// Slice 4T — pose-target rate limiting -------------------------------------

void PBDSolver::set_target_velocity_max(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	target_velocity_max = p_v;
}
float PBDSolver::get_target_velocity_max() const { return target_velocity_max; }

Vector3 PBDSolver::get_target_position_clamped() const { return prev_target_position; }

PackedVector3Array PBDSolver::get_pose_target_positions_clamped() const {
	return prev_pose_target_positions;
}

void PBDSolver::apply_target_rate_limit(float p_dt) {
	// Slice 4T — clamp target movement velocity. Runs ONCE per outer
	// Tentacle::tick (NOT per substep — substeps are for physics
	// integration, not input smoothing). After clamping, the substep loop
	// inside Tentacle::tick reads the mutated target_position / pose_target_positions
	// for all of its substeps.
	//
	// Cold-start bypass: first set_target after clear_target leaves the
	// warm flag false. The first call here arms it (warm = true) and sets
	// prev_target_position = target_position without modifying target_position.
	// The chain settles to its initial pose immediately on the first frame.
	//
	// Warm-running: subsequent calls compute delta = target - prev_target;
	// if it exceeds max_step, scale to max_step magnitude and rewrite
	// target_position. Updates prev_target_position to the (possibly
	// clamped) value for the next tick's delta basis.
	//
	// Disabled (target_velocity_max == 0): pass-through, no clamp, but
	// still update prev_target_position so re-enabling later starts from
	// the current target.
	if (p_dt <= 0.0f) return;
	float max_step = target_velocity_max * p_dt;
	// Singleton tip target.
	if (target_active && target_particle_index >= 0) {
		if (!_target_warm) {
			prev_target_position = target_position;
			_target_warm = true;
		} else if (target_velocity_max > 0.0f) {
			Vector3 delta = target_position - prev_target_position;
			float dist = delta.length();
			if (dist > max_step && dist > 1e-9f) {
				delta = delta * (max_step / dist);
				target_position = prev_target_position + delta;
			}
			prev_target_position = target_position;
		} else {
			// Disabled — track current target for re-enable continuity.
			prev_target_position = target_position;
		}
	}
	// Distributed pose targets. Parallel `_pose_target_warm` flags + prev
	// positions sized at set_pose_targets time. Length mismatch is a
	// defensive bail-out (no-op for that tick, will fix itself at the next
	// `set_pose_targets`).
	int n = pose_target_positions.size();
	if (n > 0 && (int)_pose_target_warm.size() == n
			&& prev_pose_target_positions.size() == n) {
		Vector3 *pos_ptr = pose_target_positions.ptrw();
		Vector3 *prev_ptr = prev_pose_target_positions.ptrw();
		for (int i = 0; i < n; i++) {
			if (!_pose_target_warm[i]) {
				prev_ptr[i] = pos_ptr[i];
				_pose_target_warm[i] = true;
			} else if (target_velocity_max > 0.0f) {
				Vector3 delta = pos_ptr[i] - prev_ptr[i];
				float dist = delta.length();
				if (dist > max_step && dist > 1e-9f) {
					delta = delta * (max_step / dist);
					pos_ptr[i] = prev_ptr[i] + delta;
				}
				prev_ptr[i] = pos_ptr[i];
			} else {
				prev_ptr[i] = pos_ptr[i];
			}
		}
	}
}

// -- Per-particle accessors -------------------------------------------------

Vector3 PBDSolver::get_particle_position(int i) const {
	if (i < 0 || i >= (int)particles.size()) return Vector3();
	return particles[i].position;
}

Vector3 PBDSolver::get_particle_prev_position(int i) const {
	if (i < 0 || i >= (int)particles.size()) return Vector3();
	return particles[i].prev_position;
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

void PBDSolver::set_environment_contacts_multi(
		const PackedVector3Array &p_points,
		const PackedVector3Array &p_normals,
		const PackedByteArray &p_counts,
		const PackedInt64Array &p_rids) {
	int np = p_points.size();
	int nn = p_normals.size();
	int nc = p_counts.size();
	int nr = p_rids.size();
	int n = (int)particles.size();
	int slot_total = n * MAX_CONTACTS;
	if (np != slot_total || nn != slot_total || nc != n || nr != slot_total) {
		// Mismatched lengths — clear and bail out rather than reading past
		// caller-owned arrays. The Tentacle is responsible for sizing these
		// (points/normals/rids at N×MAX_CONTACTS_PER_PARTICLE, counts at N).
		clear_environment_contacts();
		return;
	}
	env_contact_points.resize(slot_total);
	env_contact_normals.resize(slot_total);
	env_contact_count.resize(n);
	env_contact_friction_applied.resize(slot_total);
	if ((int)env_contact_normal_lambda.size() != slot_total) {
		env_contact_normal_lambda.assign((size_t)slot_total, 0.0f);
	}
	if ((int)env_contact_tangent_lambda.size() != slot_total) {
		env_contact_tangent_lambda.assign((size_t)slot_total, Vector3());
	}
	if ((int)env_contact_rid.size() != slot_total) {
		env_contact_rid.assign((size_t)slot_total, 0);
	}
	if (n == 0) {
		return;
	}
	const Vector3 *src_p = p_points.ptr();
	const Vector3 *src_n = p_normals.ptr();
	const uint8_t *src_c = p_counts.ptr();
	const int64_t *src_r = p_rids.ptr();
	Vector3 *dst_p = env_contact_points.ptrw();
	Vector3 *dst_n = env_contact_normals.ptrw();
	uint8_t *dst_c = env_contact_count.ptrw();
	for (int i = 0; i < n; i++) {
		dst_c[i] = src_c[i];
		int base = i * MAX_CONTACTS;
		// Slice 4R — per-particle warm-start. For each new slot k, search
		// the OLD per-particle slots (0..MAX_CONTACTS-1) for a matching
		// RID. If found, copy normal_lambda + tangent_lambda from the
		// matching old slot. If not found, zero. friction_applied is
		// NOT warm-started here — it's reset once per outer tick by
		// Tentacle::tick via reset_friction_applied().
		//
		// Snapshot OLD lambdas + RIDs into per-particle stack arrays
		// before touching the destination — slot indices may differ
		// between tick N and tick N+1 (the probe doesn't guarantee a
		// stable slot ordering), so the cache makes the search O(M²)
		// per particle (M = MAX_CONTACTS = 2 → 4 comparisons; trivial).
		int64_t old_rids[MAX_CONTACTS];
		float old_nlam[MAX_CONTACTS];
		Vector3 old_tlam[MAX_CONTACTS];
		bool claimed[MAX_CONTACTS];
		for (int k = 0; k < MAX_CONTACTS; k++) {
			old_rids[k] = env_contact_rid[base + k];
			old_nlam[k] = env_contact_normal_lambda[base + k];
			old_tlam[k] = env_contact_tangent_lambda[base + k];
			claimed[k] = false;
		}

		for (int k = 0; k < MAX_CONTACTS; k++) {
			dst_p[base + k] = src_p[base + k];
			Vector3 nrm = src_n[base + k];
			float l2 = nrm.length_squared();
			if (l2 > 1e-10f) {
				nrm = nrm / Math::sqrt(l2);
			} else {
				nrm = Vector3();
			}
			dst_n[base + k] = nrm;
			int64_t new_rid = src_r[base + k];
			env_contact_rid[base + k] = new_rid;
			// Match against old slots. RID 0 is reserved (inactive /
			// unknown) — never match it; new inactive slots stay zero.
			float warm_nlam = 0.0f;
			Vector3 warm_tlam;
			if (new_rid != 0) {
				for (int j = 0; j < MAX_CONTACTS; j++) {
					if (claimed[j]) continue;
					if (old_rids[j] == 0) continue;
					if (old_rids[j] == new_rid) {
						warm_nlam = old_nlam[j];
						warm_tlam = old_tlam[j];
						claimed[j] = true;
						break;
					}
				}
			}
			env_contact_normal_lambda[base + k] = warm_nlam;
			env_contact_tangent_lambda[base + k] = warm_tlam;
		}
	}
}

void PBDSolver::clear_environment_contacts() {
	env_contact_points.clear();
	env_contact_normals.clear();
	env_contact_count.clear();
	env_contact_friction_applied.clear();
	for (size_t i = 0; i < env_contact_normal_lambda.size(); i++) {
		env_contact_normal_lambda[i] = 0.0f;
	}
	for (size_t i = 0; i < env_contact_tangent_lambda.size(); i++) {
		env_contact_tangent_lambda[i] = Vector3();
	}
	for (size_t i = 0; i < env_contact_rid.size(); i++) {
		env_contact_rid[i] = 0;
	}
}

void PBDSolver::reset_environment_contact_lambdas() {
	for (size_t i = 0; i < env_contact_normal_lambda.size(); i++) {
		env_contact_normal_lambda[i] = 0.0f;
	}
	for (size_t i = 0; i < env_contact_tangent_lambda.size(); i++) {
		env_contact_tangent_lambda[i] = Vector3();
	}
}

void PBDSolver::reset_friction_applied() {
	// Slice 4O — zero the per-slot friction accumulator at the start of an
	// outer physics tick. Substeps then accumulate into it; one reciprocal
	// impulse per body is applied at end of frame from the sum.
	int n = env_contact_friction_applied.size();
	if (n == 0) return;
	Vector3 *dst = env_contact_friction_applied.ptrw();
	for (int i = 0; i < n; i++) {
		dst[i] = Vector3();
	}
}

void PBDSolver::add_external_position_delta(int p_index, const Vector3 &p_delta) {
	int n = (int)particles.size();
	if (p_index < 0 || p_index >= n) return;
	add_position_delta(p_index, p_delta);
}

void PBDSolver::apply_external_position_deltas() {
	apply_position_deltas_all();
}

// Slice 5H — feature silhouette sampler registration. Function-pointer
// hook, not a Godot Callable, so the contact iter doesn't pay Variant
// boxing per call. The owning Tentacle installs itself as user-data.
void PBDSolver::set_feature_silhouette_sampler(FeatureSilhouetteSampler p_fn, void *p_user) {
	feature_silhouette_fn = p_fn;
	feature_silhouette_user = p_user;
}

void PBDSolver::clear_feature_silhouette_sampler() {
	feature_silhouette_fn = nullptr;
	feature_silhouette_user = nullptr;
}

int PBDSolver::get_environment_contact_count() const {
	int total = 0;
	int n = env_contact_count.size();
	const uint8_t *src = env_contact_count.ptr();
	for (int i = 0; i < n; i++) {
		total += (int)src[i];
	}
	return total;
}

PackedVector3Array PBDSolver::get_environment_friction_applied() const {
	return env_contact_friction_applied;
}

PackedFloat32Array PBDSolver::get_environment_normal_lambdas_snapshot() const {
	// Slice 4Q diagnostic — read-only snapshot of the per-slot
	// `normal_lambda` accumulator (size N × MAX_CONTACTS, slot[i*MAX+k]).
	// Reset whenever fresh probe data lands; persists across iters
	// within a tick (per Obi `ContactHandling.cginc`). The diagnostic
	// uses this to detect channel-(iv) lambda oscillation: an unstable
	// contact representation manifests as the lambda for the same slot
	// flipping magnitude tick-to-tick at a settled particle.
	PackedFloat32Array out;
	int n = (int)env_contact_normal_lambda.size();
	if (n == 0) return out;
	out.resize(n);
	float *dst = out.ptrw();
	for (int i = 0; i < n; i++) dst[i] = env_contact_normal_lambda[i];
	return out;
}

float PBDSolver::compute_tension_taper_factor(float p_threshold, float p_mu_s,
		float p_normal_lambda, float p_tangent_lambda_mag) {
	// Slice 4Q-fix — tension-aware target softening factor. Returns a
	// stiffness multiplier in [0, 1].
	//   threshold ≥ 1.0 → taper disabled (returns 1.0 always).
	//   mu_s ≤ 0       → no friction cone to compare against (returns 1.0).
	//   normal_lambda ≤ ~0 → contact not pressing, no static cone (returns 1.0).
	//   tlam / static_cone ≤ threshold → not yet saturating (returns 1.0).
	//   otherwise: linear ramp from 1.0 at threshold to 0.0 at saturation.
	if (p_threshold >= 1.0f) return 1.0f;
	if (p_mu_s <= 0.0f) return 1.0f;
	float static_cone = p_mu_s * p_normal_lambda;
	if (static_cone <= 1e-7f) return 1.0f;
	float t_frac = p_tangent_lambda_mag / static_cone;
	if (t_frac <= p_threshold) return 1.0f;
	float over = (t_frac - p_threshold) / (1.0f - p_threshold);
	float scale = 1.0f - over;
	if (scale < 0.0f) scale = 0.0f;
	return scale;
}

PackedVector3Array PBDSolver::get_environment_tangent_lambdas_snapshot() const {
	// Slice 4Q round-4 diagnostic — per-slot tangent_lambda accumulator.
	// Stick-slip detection: under static friction the tangent motion is
	// fully canceled and accumulates into tangent_lambda; magnitude
	// grows. When the kinetic cone is breached the iteration switches to
	// kinetic-cone clamping and tangent_lambda saturates / drops. A clean
	// stick-slip cycle reads as monotone growth of |tangent_lambda|
	// punctuated by sharp drops.
	PackedVector3Array out;
	int n = (int)env_contact_tangent_lambda.size();
	if (n == 0) return out;
	out.resize(n);
	Vector3 *dst = out.ptrw();
	for (int i = 0; i < n; i++) dst[i] = env_contact_tangent_lambda[i];
	return out;
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

void PBDSolver::set_contact_stiffness(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	if (p_v > 1.0f) p_v = 1.0f;
	contact_stiffness = p_v;
}
float PBDSolver::get_contact_stiffness() const { return contact_stiffness; }

void PBDSolver::set_target_softness_when_blocked(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	if (p_v > 1.0f) p_v = 1.0f;
	target_softness_when_blocked = p_v;
}
float PBDSolver::get_target_softness_when_blocked() const {
	return target_softness_when_blocked;
}

void PBDSolver::set_tension_taper_threshold(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	if (p_v > 1.0f) p_v = 1.0f;
	tension_taper_threshold = p_v;
}
float PBDSolver::get_tension_taper_threshold() const {
	return tension_taper_threshold;
}

void PBDSolver::set_sor_factor(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	if (p_v > 4.0f) p_v = 4.0f; // soft upper bound; > 2 is exotic
	sor_factor = p_v;
}
float PBDSolver::get_sor_factor() const { return sor_factor; }

void PBDSolver::set_max_depenetration(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	max_depenetration = p_v;
}
float PBDSolver::get_max_depenetration() const { return max_depenetration; }

void PBDSolver::set_sleep_threshold(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	sleep_threshold = p_v;
}
float PBDSolver::get_sleep_threshold() const { return sleep_threshold; }

void PBDSolver::set_contact_velocity_damping(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	if (p_v > 1.0f) p_v = 1.0f;
	contact_velocity_damping = p_v;
}
float PBDSolver::get_contact_velocity_damping() const { return contact_velocity_damping; }

void PBDSolver::set_support_in_contact(bool p_v) { support_in_contact = p_v; }
bool PBDSolver::get_support_in_contact() const { return support_in_contact; }

PackedFloat32Array PBDSolver::get_distance_lambdas_snapshot() const {
	int n = (int)distance_lambdas.size();
	PackedFloat32Array out;
	out.resize(n);
	float *dst = out.ptrw();
	for (int i = 0; i < n; i++) {
		dst[i] = distance_lambdas[i];
	}
	return out;
}

PackedByteArray PBDSolver::get_particle_in_contact_snapshot() const {
	int n = (int)particles.size();
	PackedByteArray out;
	out.resize(n);
	uint8_t *dst = out.ptrw();
	for (int i = 0; i < n; i++) {
		dst[i] = particles[i].in_contact_this_tick ? 1 : 0;
	}
	return out;
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
	ClassDB::bind_method(D_METHOD("get_particle_prev_position", "index"), &PBDSolver::get_particle_prev_position);
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

	ClassDB::bind_method(D_METHOD("set_environment_contacts_multi", "points", "normals", "counts", "rids"),
			&PBDSolver::set_environment_contacts_multi);
	ClassDB::bind_method(D_METHOD("clear_environment_contacts"), &PBDSolver::clear_environment_contacts);
	ClassDB::bind_method(D_METHOD("reset_environment_contact_lambdas"),
			&PBDSolver::reset_environment_contact_lambdas);
	ClassDB::bind_method(D_METHOD("get_environment_contact_count"), &PBDSolver::get_environment_contact_count);
	ClassDB::bind_method(D_METHOD("get_environment_friction_applied"),
			&PBDSolver::get_environment_friction_applied);
	ClassDB::bind_method(D_METHOD("get_environment_normal_lambdas_snapshot"),
			&PBDSolver::get_environment_normal_lambdas_snapshot);
	ClassDB::bind_method(D_METHOD("get_environment_tangent_lambdas_snapshot"),
			&PBDSolver::get_environment_tangent_lambdas_snapshot);
	ClassDB::bind_static_method("PBDSolver",
			D_METHOD("compute_tension_taper_factor",
					"threshold", "mu_s", "normal_lambda", "tangent_lambda_mag"),
			&PBDSolver::compute_tension_taper_factor);
	ClassDB::bind_method(D_METHOD("set_collision_radius", "radius"), &PBDSolver::set_collision_radius);
	ClassDB::bind_method(D_METHOD("get_collision_radius"), &PBDSolver::get_collision_radius);
	ClassDB::bind_method(D_METHOD("set_friction", "static_coeff", "kinetic_ratio"),
			&PBDSolver::set_friction);
	ClassDB::bind_method(D_METHOD("get_static_friction"), &PBDSolver::get_static_friction);
	ClassDB::bind_method(D_METHOD("get_kinetic_friction_ratio"),
			&PBDSolver::get_kinetic_friction_ratio);
	ClassDB::bind_method(D_METHOD("set_contact_stiffness", "stiffness"),
			&PBDSolver::set_contact_stiffness);
	ClassDB::bind_method(D_METHOD("get_contact_stiffness"),
			&PBDSolver::get_contact_stiffness);
	ClassDB::bind_method(D_METHOD("set_target_softness_when_blocked", "softness"),
			&PBDSolver::set_target_softness_when_blocked);
	ClassDB::bind_method(D_METHOD("get_target_softness_when_blocked"),
			&PBDSolver::get_target_softness_when_blocked);
	ClassDB::bind_method(D_METHOD("set_target_velocity_max", "value"),
			&PBDSolver::set_target_velocity_max);
	ClassDB::bind_method(D_METHOD("get_target_velocity_max"),
			&PBDSolver::get_target_velocity_max);
	ClassDB::bind_method(D_METHOD("apply_target_rate_limit", "dt"),
			&PBDSolver::apply_target_rate_limit);
	ClassDB::bind_method(D_METHOD("get_target_position_clamped"),
			&PBDSolver::get_target_position_clamped);
	ClassDB::bind_method(D_METHOD("get_pose_target_positions_clamped"),
			&PBDSolver::get_pose_target_positions_clamped);
	ClassDB::bind_method(D_METHOD("set_tension_taper_threshold", "threshold"),
			&PBDSolver::set_tension_taper_threshold);
	ClassDB::bind_method(D_METHOD("get_tension_taper_threshold"),
			&PBDSolver::get_tension_taper_threshold);
	ClassDB::bind_method(D_METHOD("set_sor_factor", "factor"),
			&PBDSolver::set_sor_factor);
	ClassDB::bind_method(D_METHOD("get_sor_factor"), &PBDSolver::get_sor_factor);
	ClassDB::bind_method(D_METHOD("set_max_depenetration", "value"),
			&PBDSolver::set_max_depenetration);
	ClassDB::bind_method(D_METHOD("get_max_depenetration"),
			&PBDSolver::get_max_depenetration);
	ClassDB::bind_method(D_METHOD("set_sleep_threshold", "value"),
			&PBDSolver::set_sleep_threshold);
	ClassDB::bind_method(D_METHOD("get_sleep_threshold"),
			&PBDSolver::get_sleep_threshold);
	ClassDB::bind_method(D_METHOD("reset_friction_applied"),
			&PBDSolver::reset_friction_applied);
	ClassDB::bind_method(D_METHOD("add_external_position_delta", "particle_index", "delta"),
			&PBDSolver::add_external_position_delta);
	ClassDB::bind_method(D_METHOD("apply_external_position_deltas"),
			&PBDSolver::apply_external_position_deltas);
	ClassDB::bind_method(D_METHOD("set_contact_velocity_damping", "damping"),
			&PBDSolver::set_contact_velocity_damping);
	ClassDB::bind_method(D_METHOD("get_contact_velocity_damping"),
			&PBDSolver::get_contact_velocity_damping);
	ClassDB::bind_method(D_METHOD("set_support_in_contact", "value"),
			&PBDSolver::set_support_in_contact);
	ClassDB::bind_method(D_METHOD("get_support_in_contact"),
			&PBDSolver::get_support_in_contact);
	ClassDB::bind_method(D_METHOD("get_particle_in_contact_snapshot"),
			&PBDSolver::get_particle_in_contact_snapshot);
	ClassDB::bind_method(D_METHOD("get_distance_lambdas_snapshot"),
			&PBDSolver::get_distance_lambdas_snapshot);

	BIND_CONSTANT(DEFAULT_ITERATION_COUNT);
	BIND_CONSTANT(MAX_ITERATION_COUNT);
	BIND_CONSTANT(DEFAULT_PARTICLE_COUNT);
}
