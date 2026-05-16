#ifndef TENTACLETECH_TUNNEL_STATE_INTEGRATOR_H
#define TENTACLETECH_TUNNEL_STATE_INTEGRATOR_H

#include "canal/canal_centerline_solver.h"

#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include <vector>

// Slice 5F.B.B — per-tick CPU integration of a canal's `tunnel_state`
// RGBA32F texture per architecture §6.12.4 step 2.
//
// Owns four per-cell scratch arrays (size = axial × sectors):
//   * dynamic_wall_radius[k][j]      — first-order wall lag, R-channel
//   * plastic_offset[k][j]           — radial plastic memory, G-channel
//   * damage[k][j]                   — accumulated tissue damage,    B-channel
//   * fourth_channel[k][j]           — wall_radial_velocity OR friction_mult,
//                                      A-channel (mode-dependent)
//
// Each tick:
//   1. Evaluate per-cell muscle scalar from constriction zones (muscle field
//      eval stubbed = 0 — 5G concern).
//   2. Resolve cell world position via the centerline solver's deformed
//      `evaluate_at` + `basis_at`.
//   3. Compose target wall radius from rest + plastic_offset − muscle
//      compression + curvature asymmetry, clamped to `min_wall_radius`.
//   4. Integrate `dynamic_wall_radius` toward target with finite response
//      rate (and optional second-order ringing).
//   5. Accumulate plastic memory + damage; clamp.
//   6. Compute per-cell friction multiplier.
//   7. Upload to the bound `ImageTexture` (one `Image::set_pixel` per cell,
//      single `texture->update(image)` at the end).
//
// Out-of-scope for 5F.B.B (per the slice in-scope list):
//   * Bulger SDF (Phase 7).
//   * Bilateral lateral force on centerline (bulger-driven).
//   * Muscle field eval (5G).
//
// Snapshot accessors return by copy per the §15 architecture rule.
class TunnelStateIntegrator : public godot::RefCounted {
	GDCLASS(TunnelStateIntegrator, godot::RefCounted)

public:
	// Fourth-channel storage mode. Matches the prompt's enum exactly.
	// Note: `CanalParameters.fourth_channel_mode` has a third option
	// ("damage") which is meaningless here (damage already lives in the
	// B-channel); the canal glue maps that authored value to
	// MODE_WALL_RADIAL_VELOCITY before calling `set_fourth_channel_mode`.
	enum FourthChannelMode {
		MODE_WALL_RADIAL_VELOCITY = 0,
		MODE_FRICTION_MULT = 1,
	};

	TunnelStateIntegrator();
	~TunnelStateIntegrator();

	// Authoring — called once at bake completion and again on every re-bake.
	// `rest_radius_per_cell` is row-major `k * sectors + j`. The texture is
	// the live `ImageTexture` whose backing Image we mutate + re-upload each
	// tick. `constriction_zone_data` is a flat array of 5-tuples per zone:
	//   [arc_length_s, half_width, max_contraction, current_strength, friction_bonus]
	// matching the §6.12.3 + 6.12.4 schema. `current_strength` is refreshed
	// each tick via `update_constriction_zones`.
	void configure(int p_axial_segments, int p_angular_sectors,
			const godot::PackedFloat32Array &p_rest_radius_per_cell,
			const godot::Ref<godot::ImageTexture> &p_tunnel_state_texture,
			const godot::PackedFloat32Array &p_constriction_zone_data);

	// Refresh zone strengths only (cheap path — called every tick by the
	// canal glue so Reverie's per-tick zone modulation propagates without
	// reconfiguring the whole integrator).
	void update_constriction_zones(const godot::PackedFloat32Array &p_constriction_zone_data);

	void set_centerline_solver(const godot::Ref<CanalCenterlineSolver> &p_solver);

	// Per-canal tunables (default values match `CanalParameters` defaults
	// where applicable; safe-range clamps live inside the setters).
	void set_curvature_response_gain(float p_g);
	void set_contraction_gain(float p_g);
	void set_min_wall_radius(float p_r);
	void set_wall_response_rate(float p_r);
	void set_use_second_order_wall(bool p_enable);
	void set_wall_acceleration_gain(float p_g);
	void set_wall_damping(float p_d);
	void set_plastic_params(float p_accumulate_rate, float p_recover_rate, float p_max_offset);
	void set_damage_params(float p_rate, float p_plastic_gain, float p_friction_loss);
	void set_muscle_friction_gain(float p_g);
	void set_fourth_channel_mode(int p_mode);

	// Per-tick driver. Runs §6.12.4 step 2 over all cells, then uploads the
	// scratch into the bound `ImageTexture`.
	void tick(float p_dt);

	// Snapshot accessors (by-copy, §15). Indexed `k * sectors + j`. Each
	// returns a fresh PackedFloat32Array; no live pointer into scratch.
	godot::PackedFloat32Array get_dynamic_wall_radius_snapshot() const;
	godot::PackedFloat32Array get_plastic_offset_snapshot() const;
	godot::PackedFloat32Array get_damage_snapshot() const;
	godot::PackedFloat32Array get_fourth_channel_snapshot() const;
	int get_axial_segments() const;
	int get_angular_sectors() const;

	// Test-only setter. Mutates `dynamic_wall_radius[k][j]` directly so a
	// test can stage a perturbed wall radius and observe its decay or its
	// effect on plastic/damage accumulation. Out-of-range index = no-op.
	void set_dynamic_wall_radius_for_test(int p_k, int p_j, float p_r);

protected:
	static void _bind_methods();

private:
	// Per-cell scratch (row-major k*sectors+j).
	std::vector<float> dynamic_wall_radius;
	std::vector<float> plastic_offset;
	std::vector<float> damage;
	std::vector<float> fourth_channel;
	std::vector<float> rest_radius;
	// Zone data flattened: 5 floats per zone.
	std::vector<float> zones;

	// Resolution.
	int axial_segments = 0;
	int angular_sectors = 0;

	// Upload target. Held as Ref so the integrator keeps the texture alive
	// even if the owning Canal node is freed mid-tick (a rare edge case but
	// cheap to defend against).
	godot::Ref<godot::ImageTexture> tunnel_state_texture;
	godot::Ref<godot::Image> tunnel_state_image; // backing image, mutated in-place

	godot::Ref<CanalCenterlineSolver> centerline_solver;

	// Tunables (defaults match prompt's per-step defaults).
	float curvature_response_gain = 0.0f;
	float contraction_gain = 1.0f;
	float min_wall_radius = 0.001f;
	float wall_response_rate = 10.0f;
	bool use_second_order_wall = false;
	float wall_acceleration_gain = 5.0f;
	float wall_damping = 6.0f;
	float plastic_accumulate_rate = 0.05f;
	float plastic_recover_rate = 0.05f;
	float plastic_max_offset = 0.005f;
	float damage_rate = 0.001f;
	float damage_plastic_gain = 1.0f;
	float damage_friction_loss = 0.5f;
	float muscle_friction_gain = 1.0f;
	int fourth_channel_mode = MODE_WALL_RADIAL_VELOCITY;

	// Internal helper: per-cell muscle activation from zones (plus 5G
	// muscle-field eval, currently stubbed).
	float _eval_muscle(float s, int j) const;
	// Internal helper: per-cell zone friction bonus (separate from muscle
	// because the friction multiplier needs zone bonus even when the zone
	// has zero contraction).
	float _eval_zone_friction_bonus(float s, int j) const;
};

VARIANT_ENUM_CAST(TunnelStateIntegrator::FourthChannelMode);

#endif // TENTACLETECH_TUNNEL_STATE_INTEGRATOR_H
