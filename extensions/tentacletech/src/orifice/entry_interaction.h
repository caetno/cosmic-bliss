#ifndef TENTACLETECH_ENTRY_INTERACTION_H
#define TENTACLETECH_ENTRY_INTERACTION_H

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <vector>

class Tentacle;

// Phase-5 slice 5C-B (per-tick geometric refresh + lifecycle) and 5C-C
// (force routing — the slots populated below stay zero in 5C-B).
//
// Spec: docs/architecture/TentacleTech_Architecture.md §6.2 (amended
// 2026-05-03 to use `_per_loop_k[l][k]` indexing). Slices 5A + 5B + 5C-A
// landed the rim primitive, host-bone soft attachment, and bilateral
// type-2 contact respectively. 5C-B sits between the contact half (5C-A)
// and the friction + reaction-on-host-bone closure (5C-C).
//
// Lifecycle:
//   - On first tick where the tentacle's chain crosses the orifice's
//     entry plane on the cavity-interior side, an EI is created with
//     persistent slots zeroed.
//   - Every subsequent tick refreshes the per-tick geometric fields
//     and bumps `prev_penetration_depth` for the next axial_velocity.
//   - When the tentacle disengages (no crossing, or unregistered), the
//     EI's `active` flag is cleared and `retirement_timer` accumulates;
//     the EI is purged once the timer exceeds `grace_period`.
//   - Persistent state (grip_engagement, ejection_velocity, damage,
//     in_stick_phase) survives the active→inactive→active cycle as long
//     as the EI hasn't been purged. Reason-for-existing of the EI as a
//     persistent object: hysteretic state must NOT reset on momentary
//     disengagement.
struct EntryInteraction {
	// -- Identity ---------------------------------------------------------
	// Index into the Orifice's `_tentacles_resolved` cache + the same
	// index into `tentacle_paths`. The pointer is cached for direct
	// access during geometric refresh; rebuilt by the resolver each tick
	// so a freed Tentacle can't dangle.
	int tentacle_idx = -1;
	Tentacle *tentacle = nullptr;

	// -- Per-tick geometric (recomputed each refresh) ---------------------
	// All in WORLD space unless suffixed `_in_orifice`.
	float arc_length_at_entry = 0.0f;
	godot::Vector3 entry_point;
	godot::Vector3 entry_axis;
	godot::Vector3 center_offset_in_orifice;
	float approach_angle_cos = 0.0f;
	float tentacle_girth_here = 1.0f;
	godot::Vector2 tentacle_asymmetry_here;
	float penetration_depth = 0.0f;
	float axial_velocity = 0.0f;
	godot::PackedInt32Array particles_in_tunnel;

	// -- Persistent (hysteretic — initialized in 5C-B, driven in 5C-C) ----
	float grip_engagement = 0.0f;
	bool in_stick_phase = false;
	// Per-tentacle one-shot ejection (§6.10 RefusalSpasm / PainExpulsion).
	// Slot reserved here; the §6.10 emitter writes into it, and the
	// per-tick application path that consumes it is itself a later slice.
	float ejection_velocity = 0.0f;
	float ejection_decay = 12.0f; // 1/s

	// Per-rim-particle accumulated state. Outer index = loop, inner = k.
	// Resized to `orifice.rim_loops[l].particle_count` per loop on EI
	// creation AND on every refresh tick (defensive — cheap O(N)). All
	// entries stay zero in 5C-B; 5C-C populates them from the type-2
	// projection.
	std::vector<std::vector<float>> orifice_radius_per_loop_k;
	std::vector<std::vector<float>> orifice_radius_velocity_per_loop_k;
	std::vector<std::vector<float>> damage_accumulated_per_loop_k;
	std::vector<std::vector<float>> radial_pressure_per_loop_k;
	std::vector<std::vector<float>> tangential_friction_per_loop_k;

	// Per-tick force/impulse aggregates (5C-C scope; zero in 5C-B).
	float axial_friction_force = 0.0f;
	godot::Vector3 reaction_on_ragdoll;

	// -- Lifecycle --------------------------------------------------------
	// `active` is set true when the tentacle is currently crossing the
	// entry plane on the cavity-interior side. When the tentacle
	// disengages, `active` flips to false and `retirement_timer`
	// accumulates the elapsed dt; the EI is purged once the timer
	// exceeds the orifice's `entry_interaction_grace_period`.
	bool active = true;
	float retirement_timer = 0.0f;

	// -- Last-tick scratch ------------------------------------------------
	// Drives `axial_velocity = (penetration_depth − prev_penetration_depth) / dt`.
	// Initialized to the EI's first-frame `penetration_depth` so velocity
	// reads zero on the creation tick instead of a spike from 0 → depth.
	float prev_penetration_depth = 0.0f;
	bool first_refresh_done = false;
};

#endif // TENTACLETECH_ENTRY_INTERACTION_H
