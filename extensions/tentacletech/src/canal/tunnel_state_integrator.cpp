#include "canal/tunnel_state_integrator.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

// Helper: smoothstep falloff identical to GLSL's: returns 1 at d=0,
// 0 at d=half_width; cubic Hermite in between.
static inline float _smoothstep_falloff(float d, float half_width) {
	if (d >= half_width || half_width <= 1e-9f) {
		return 0.0f;
	}
	const float x = 1.0f - (d / half_width);
	return x * x * (3.0f - 2.0f * x);
}

TunnelStateIntegrator::TunnelStateIntegrator() {}
TunnelStateIntegrator::~TunnelStateIntegrator() {}

void TunnelStateIntegrator::configure(int p_axial_segments, int p_angular_sectors,
		const PackedFloat32Array &p_rest_radius_per_cell,
		const Ref<ImageTexture> &p_tunnel_state_texture,
		const PackedFloat32Array &p_constriction_zone_data) {
	axial_segments = std::max(2, p_axial_segments);
	angular_sectors = std::max(2, p_angular_sectors);
	const int n_cells = axial_segments * angular_sectors;

	rest_radius.assign(n_cells, 0.0f);
	const int rr_count = p_rest_radius_per_cell.size();
	for (int i = 0; i < n_cells; ++i) {
		rest_radius[i] = (i < rr_count) ? p_rest_radius_per_cell[i] : 0.05f;
	}

	// Initialise scratch fields to "at rest": wall_radius = rest, plastic =
	// damage = 0, fourth-channel = 0 (velocity) or 1 (friction_mult).
	dynamic_wall_radius = rest_radius; // copy
	plastic_offset.assign(n_cells, 0.0f);
	damage.assign(n_cells, 0.0f);
	const float fourth_init = (fourth_channel_mode == MODE_FRICTION_MULT) ? 1.0f : 0.0f;
	fourth_channel.assign(n_cells, fourth_init);

	tunnel_state_texture = p_tunnel_state_texture;
	if (tunnel_state_texture.is_valid()) {
		// Pull the backing image off the texture; we mutate it in place and
		// re-upload via `texture->update(image)` each tick. Godot's
		// ImageTexture::get_image() returns a fresh copy in recent 4.x;
		// stash the result so we don't pay the copy each tick.
		tunnel_state_image = tunnel_state_texture->get_image();
	}

	update_constriction_zones(p_constriction_zone_data);
}

void TunnelStateIntegrator::update_constriction_zones(
		const PackedFloat32Array &p_constriction_zone_data) {
	const int n = p_constriction_zone_data.size();
	zones.assign(n, 0.0f);
	for (int i = 0; i < n; ++i) {
		zones[i] = p_constriction_zone_data[i];
	}
}

void TunnelStateIntegrator::set_centerline_solver(const Ref<CanalCenterlineSolver> &p_solver) {
	centerline_solver = p_solver;
}

void TunnelStateIntegrator::set_curvature_response_gain(float p_g) {
	curvature_response_gain = std::max(0.0f, p_g);
}
void TunnelStateIntegrator::set_contraction_gain(float p_g) {
	contraction_gain = std::max(0.0f, p_g);
}
void TunnelStateIntegrator::set_min_wall_radius(float p_r) {
	min_wall_radius = std::max(0.0f, p_r);
}
void TunnelStateIntegrator::set_wall_response_rate(float p_r) {
	wall_response_rate = std::max(0.1f, p_r);
}
void TunnelStateIntegrator::set_use_second_order_wall(bool p_enable) {
	use_second_order_wall = p_enable;
}
void TunnelStateIntegrator::set_wall_acceleration_gain(float p_g) {
	wall_acceleration_gain = std::max(0.0f, p_g);
}
void TunnelStateIntegrator::set_wall_damping(float p_d) {
	wall_damping = std::max(0.0f, p_d);
}
void TunnelStateIntegrator::set_plastic_params(float p_accumulate_rate,
		float p_recover_rate, float p_max_offset) {
	plastic_accumulate_rate = std::max(0.0f, p_accumulate_rate);
	plastic_recover_rate = std::max(0.0f, p_recover_rate);
	plastic_max_offset = std::max(0.0f, p_max_offset);
}
void TunnelStateIntegrator::set_damage_params(float p_rate, float p_plastic_gain,
		float p_friction_loss) {
	damage_rate = std::max(0.0f, p_rate);
	damage_plastic_gain = std::max(0.0f, p_plastic_gain);
	damage_friction_loss = std::max(0.0f, p_friction_loss);
}
void TunnelStateIntegrator::set_muscle_friction_gain(float p_g) {
	muscle_friction_gain = std::max(0.0f, p_g);
}
void TunnelStateIntegrator::set_fourth_channel_mode(int p_mode) {
	// Unknown values clamp to wall_radial_velocity. CanalParameters'
	// authored enum can carry a "damage" option that is meaningless here;
	// the glue should remap before calling, but defensive clamping closes
	// the loop without crashing the tick.
	if (p_mode == MODE_FRICTION_MULT) {
		fourth_channel_mode = MODE_FRICTION_MULT;
	} else {
		fourth_channel_mode = MODE_WALL_RADIAL_VELOCITY;
	}
}

float TunnelStateIntegrator::_eval_muscle(float p_s, int p_j) const {
	// TODO 5G: muscle field eval (Reverie-writable `muscle[s,θ]`). Slice
	// 5F.B.B stubs this to 0 per the prompt; the constriction-zone
	// contribution below is the only active muscle source until 5G.
	float muscle = 0.0f;
	const int zone_count = static_cast<int>(zones.size()) / 5;
	for (int z = 0; z < zone_count; ++z) {
		const float arc_s = zones[z * 5 + 0];
		const float half_w = zones[z * 5 + 1];
		const float max_contr = zones[z * 5 + 2];
		const float strength = zones[z * 5 + 3];
		// friction_bonus (zones[z*5 + 4]) handled in `_eval_zone_friction_bonus`.
		const float d = std::abs(p_s - arc_s);
		if (d < half_w) {
			const float falloff = _smoothstep_falloff(d, half_w);
			muscle += strength * max_contr * falloff;
		}
	}
	(void)p_j; // angular variation arrives with 5G's muscle field
	return muscle;
}

float TunnelStateIntegrator::_eval_zone_friction_bonus(float p_s, int p_j) const {
	float bonus = 0.0f;
	const int zone_count = static_cast<int>(zones.size()) / 5;
	for (int z = 0; z < zone_count; ++z) {
		const float arc_s = zones[z * 5 + 0];
		const float half_w = zones[z * 5 + 1];
		const float strength = zones[z * 5 + 3];
		const float friction_bonus = zones[z * 5 + 4];
		const float d = std::abs(p_s - arc_s);
		if (d < half_w) {
			const float falloff = _smoothstep_falloff(d, half_w);
			bonus += friction_bonus * strength * falloff;
		}
	}
	(void)p_j;
	return bonus;
}

void TunnelStateIntegrator::tick(float p_dt) {
	if (p_dt <= 0.0f) {
		return;
	}
	if (axial_segments < 2 || angular_sectors < 2) {
		return;
	}
	const int n_cells = axial_segments * angular_sectors;
	if (static_cast<int>(dynamic_wall_radius.size()) != n_cells) {
		return;
	}

	// Total arc length along the DEFORMED centerline. Used to map cell k →
	// `s_k` for muscle + zone eval (matches the texture coord convention
	// `s_norm = k / (axial - 1)`).
	float total_arc = 0.0f;
	if (centerline_solver.is_valid()) {
		total_arc = centerline_solver->get_total_arc_length();
	}

	// First-order rate clamp per §6.12.10: rate * dt < 1.
	const float max_rate = (1.0f / p_dt) - 1e-3f;
	const float rate = std::min(std::max(wall_response_rate, 1.0f), max_rate);

	for (int k = 0; k < axial_segments; ++k) {
		const float s_norm = static_cast<float>(k) / std::max(1.0f, static_cast<float>(axial_segments - 1));
		const float s = s_norm * total_arc;

		// 2b. Centerline state at `s`. `outward(θ)` derived below per cell.
		Vector3 center_pos = Vector3();
		Basis center_basis;
		float curvature_kj = 0.0f;
		Vector3 bend_axis = Vector3();
		if (centerline_solver.is_valid()) {
			center_pos = centerline_solver->evaluate_at(s);
			center_basis = centerline_solver->basis_at(s);
			curvature_kj = centerline_solver->curvature_at(s);
			bend_axis = centerline_solver->bend_axis_at(s);
		}

		for (int j = 0; j < angular_sectors; ++j) {
			const int idx = k * angular_sectors + j;
			const float theta = (float)(2.0 * Math_PI) * static_cast<float>(j) / static_cast<float>(angular_sectors);
			const float cos_t = std::cos(theta);
			const float sin_t = std::sin(theta);

			// 2a. Muscle activation (zones only; 5G adds the field eval).
			const float muscle = _eval_muscle(s, j);

			// 2b. Cell world position uses deformed centerline. Computed
			// but not used downstream by this slice (bulger SDF is the
			// consumer, deferred to Phase 7). Kept inline for symmetry
			// with the §6.12.4 pseudocode + as a quiet anchor for the
			// Phase-7 wire-up.
			const Vector3 outward = center_basis.get_column(1) * cos_t
					+ center_basis.get_column(2) * sin_t;
			const Vector3 cell_world_pos = center_pos + outward * dynamic_wall_radius[idx];
			(void)cell_world_pos; // TODO Phase 7: bulger SDF

			// 2c. Bulger SDF contribution. Phase 7 blocked.
			const float bulger_target = 0.0f; // TODO Phase 7: bulger SDF

			// 2d. Centerline curvature → wall asymmetry. `inside_factor` is
			// −dot(outward, bend_axis) so cells on the inside of the bend
			// (outward opposes bend_axis) get a positive offset that
			// inflates the wall, while cells on the outside get a
			// negative offset that pulls the wall in toward the
			// centerline. Multiplied by `curvature_response_gain` (off by
			// default).
			float curvature_offset = 0.0f;
			if (curvature_response_gain > 0.0f && bend_axis.length_squared() > 1e-12f) {
				const float inside_factor = -outward.dot(bend_axis);
				curvature_offset = curvature_kj * inside_factor * curvature_response_gain;
			}

			// 2e. Target wall radius.
			const float rest = rest_radius[idx];
			const float plastic = plastic_offset[idx];
			const float compress = rest * muscle * contraction_gain * 0.5f;
			float target = rest + plastic - compress;
			if (bulger_target > target) {
				target = bulger_target;
			}
			if (target < min_wall_radius) {
				target = min_wall_radius;
			}
			target += curvature_offset;

			// 2f. Bilateral split — bulger-driven; skipped in 5F.B.B.

			// 2g. Integrate dynamic_wall_radius (first-order spring).
			const float delta = (target - dynamic_wall_radius[idx]) * rate * p_dt;
			dynamic_wall_radius[idx] += delta;

			// 2h. Optional second-order ringing.
			if (use_second_order_wall) {
				// `wall_radial_velocity` lives in the fourth channel slot
				// when `fourth_channel_mode == MODE_WALL_RADIAL_VELOCITY`;
				// when in FRICTION_MULT mode we use a transient local var
				// (no ringing storage — the canal is first-order in that
				// case, but we still honour the gain so a designer who
				// flips the flag without flipping the channel mode gets
				// a one-tick burst rather than silent zero).
				float v = (fourth_channel_mode == MODE_WALL_RADIAL_VELOCITY)
						? fourth_channel[idx]
						: 0.0f;
				v += delta * wall_acceleration_gain;
				v *= (1.0f - wall_damping * p_dt);
				dynamic_wall_radius[idx] += v * p_dt;
				if (fourth_channel_mode == MODE_WALL_RADIAL_VELOCITY) {
					fourth_channel[idx] = v;
				}
			}

			// 2i. Plastic memory accumulation + recovery (radial).
			const float stretch = std::max(0.0f, dynamic_wall_radius[idx] - rest);
			const float gain = std::max(0.0f, stretch - plastic_offset[idx])
					* plastic_accumulate_rate * p_dt;
			plastic_offset[idx] += gain;
			plastic_offset[idx] -= plastic_offset[idx] * plastic_recover_rate * p_dt;
			if (plastic_offset[idx] < 0.0f) {
				plastic_offset[idx] = 0.0f;
			}
			if (plastic_offset[idx] > plastic_max_offset) {
				plastic_offset[idx] = plastic_max_offset;
			}

			// 2j. Damage accumulation. Pressure estimate uses the *target*
			// over rest (matches spec line 1363). Larger damage raises the
			// per-cell plastic cap.
			const float pressure_estimate = std::max(0.0f, target - rest);
			damage[idx] += pressure_estimate * p_dt * damage_rate;
			if (damage[idx] < 0.0f) {
				damage[idx] = 0.0f;
			}
			const float plastic_max_local = plastic_max_offset
					* (1.0f + damage[idx] * damage_plastic_gain);
			if (plastic_offset[idx] > plastic_max_local) {
				plastic_offset[idx] = plastic_max_local;
			}

			// 2k. Friction multiplier (per-cell μ scaling). Composed even
			// when stored elsewhere — the fourth-channel write below picks
			// the source per mode.
			const float friction_bonus = _eval_zone_friction_bonus(s, j);
			float friction_mult = 1.0f
					+ muscle * muscle_friction_gain
					+ friction_bonus
					- damage[idx] * damage_friction_loss;
			if (friction_mult < 0.0f) {
				friction_mult = 0.0f;
			}
			if (fourth_channel_mode == MODE_FRICTION_MULT) {
				fourth_channel[idx] = friction_mult;
			}
			// (In MODE_WALL_RADIAL_VELOCITY the velocity write happened
			// inline above. Friction mult is recomputed every tick from
			// muscle + damage, so the canonical store is implicit — Type-3
			// contact queries will recompute it from the texture if
			// needed.)
		}
	}

	// ─── GPU upload ─────────────────────────────────────────────────
	if (tunnel_state_image.is_valid() && tunnel_state_texture.is_valid()) {
		for (int k = 0; k < axial_segments; ++k) {
			for (int j = 0; j < angular_sectors; ++j) {
				const int idx = k * angular_sectors + j;
				tunnel_state_image->set_pixel(k, j, Color(
						dynamic_wall_radius[idx],
						plastic_offset[idx],
						damage[idx],
						fourth_channel[idx]));
			}
		}
		tunnel_state_texture->update(tunnel_state_image);
	}
}

PackedFloat32Array TunnelStateIntegrator::get_dynamic_wall_radius_snapshot() const {
	PackedFloat32Array out;
	const int n = static_cast<int>(dynamic_wall_radius.size());
	out.resize(n);
	for (int i = 0; i < n; ++i) {
		out[i] = dynamic_wall_radius[i];
	}
	return out;
}

PackedFloat32Array TunnelStateIntegrator::get_plastic_offset_snapshot() const {
	PackedFloat32Array out;
	const int n = static_cast<int>(plastic_offset.size());
	out.resize(n);
	for (int i = 0; i < n; ++i) {
		out[i] = plastic_offset[i];
	}
	return out;
}

PackedFloat32Array TunnelStateIntegrator::get_damage_snapshot() const {
	PackedFloat32Array out;
	const int n = static_cast<int>(damage.size());
	out.resize(n);
	for (int i = 0; i < n; ++i) {
		out[i] = damage[i];
	}
	return out;
}

PackedFloat32Array TunnelStateIntegrator::get_fourth_channel_snapshot() const {
	PackedFloat32Array out;
	const int n = static_cast<int>(fourth_channel.size());
	out.resize(n);
	for (int i = 0; i < n; ++i) {
		out[i] = fourth_channel[i];
	}
	return out;
}

int TunnelStateIntegrator::get_axial_segments() const { return axial_segments; }
int TunnelStateIntegrator::get_angular_sectors() const { return angular_sectors; }

void TunnelStateIntegrator::set_dynamic_wall_radius_for_test(int p_k, int p_j, float p_r) {
	if (p_k < 0 || p_k >= axial_segments) {
		return;
	}
	if (p_j < 0 || p_j >= angular_sectors) {
		return;
	}
	dynamic_wall_radius[p_k * angular_sectors + p_j] = p_r;
}

void TunnelStateIntegrator::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "axial_segments", "angular_sectors",
								  "rest_radius_per_cell", "tunnel_state_texture",
								  "constriction_zone_data"),
			&TunnelStateIntegrator::configure);
	ClassDB::bind_method(D_METHOD("update_constriction_zones", "constriction_zone_data"),
			&TunnelStateIntegrator::update_constriction_zones);
	ClassDB::bind_method(D_METHOD("set_centerline_solver", "solver"),
			&TunnelStateIntegrator::set_centerline_solver);
	ClassDB::bind_method(D_METHOD("set_curvature_response_gain", "g"),
			&TunnelStateIntegrator::set_curvature_response_gain);
	ClassDB::bind_method(D_METHOD("set_contraction_gain", "g"),
			&TunnelStateIntegrator::set_contraction_gain);
	ClassDB::bind_method(D_METHOD("set_min_wall_radius", "r"),
			&TunnelStateIntegrator::set_min_wall_radius);
	ClassDB::bind_method(D_METHOD("set_wall_response_rate", "r"),
			&TunnelStateIntegrator::set_wall_response_rate);
	ClassDB::bind_method(D_METHOD("set_use_second_order_wall", "enable"),
			&TunnelStateIntegrator::set_use_second_order_wall);
	ClassDB::bind_method(D_METHOD("set_wall_acceleration_gain", "g"),
			&TunnelStateIntegrator::set_wall_acceleration_gain);
	ClassDB::bind_method(D_METHOD("set_wall_damping", "d"),
			&TunnelStateIntegrator::set_wall_damping);
	ClassDB::bind_method(D_METHOD("set_plastic_params", "accumulate_rate", "recover_rate", "max_offset"),
			&TunnelStateIntegrator::set_plastic_params);
	ClassDB::bind_method(D_METHOD("set_damage_params", "rate", "plastic_gain", "friction_loss"),
			&TunnelStateIntegrator::set_damage_params);
	ClassDB::bind_method(D_METHOD("set_muscle_friction_gain", "g"),
			&TunnelStateIntegrator::set_muscle_friction_gain);
	ClassDB::bind_method(D_METHOD("set_fourth_channel_mode", "mode"),
			&TunnelStateIntegrator::set_fourth_channel_mode);
	ClassDB::bind_method(D_METHOD("tick", "dt"), &TunnelStateIntegrator::tick);
	ClassDB::bind_method(D_METHOD("get_dynamic_wall_radius_snapshot"),
			&TunnelStateIntegrator::get_dynamic_wall_radius_snapshot);
	ClassDB::bind_method(D_METHOD("get_plastic_offset_snapshot"),
			&TunnelStateIntegrator::get_plastic_offset_snapshot);
	ClassDB::bind_method(D_METHOD("get_damage_snapshot"),
			&TunnelStateIntegrator::get_damage_snapshot);
	ClassDB::bind_method(D_METHOD("get_fourth_channel_snapshot"),
			&TunnelStateIntegrator::get_fourth_channel_snapshot);
	ClassDB::bind_method(D_METHOD("get_axial_segments"),
			&TunnelStateIntegrator::get_axial_segments);
	ClassDB::bind_method(D_METHOD("get_angular_sectors"),
			&TunnelStateIntegrator::get_angular_sectors);
	ClassDB::bind_method(D_METHOD("set_dynamic_wall_radius_for_test", "k", "j", "r"),
			&TunnelStateIntegrator::set_dynamic_wall_radius_for_test);

	BIND_ENUM_CONSTANT(MODE_WALL_RADIAL_VELOCITY);
	BIND_ENUM_CONSTANT(MODE_FRICTION_MULT);
}
