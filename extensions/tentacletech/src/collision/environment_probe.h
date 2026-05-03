#ifndef TENTACLETECH_ENVIRONMENT_PROBE_H
#define TENTACLETECH_ENVIRONMENT_PROBE_H

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/physics_shape_query_parameters3d.hpp>
#include <godot_cpp/classes/sphere_shape3d.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/templates/local_vector.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/vector3.hpp>

// Phase-4 slice 4D: per-particle sphere collision probe.
//
// Replaces slice 4A's 3-ray gravity-only probe. Each particle now issues a
// PhysicsDirectSpaceState3D::get_rest_info query at its current position
// using a sphere shape sized to `collision_radius * girth_scale`. The query
// returns the nearest surface point/normal of any overlapping body — works
// uniformly for static bodies, moving rigid bodies, animatable bodies, and
// PhysicalBone3D (ragdoll) shapes.
//
// Slice 4M (2026-05-03): up to MAX_CONTACTS_PER_PARTICLE simultaneous
// contacts per particle. The probe iterates get_rest_info with a growing
// exclude list, picking up the next-closest body each pass; results are
// sorted by penetration depth so slot 0 is the deepest. The per-slot data
// (point/normal/rid/etc.) is held in fixed-size arrays inside
// EnvironmentContact. The single-contact API (`get_hit_point()` accessors
// returning slot 0) is preserved for the snapshot dictionary builder so
// the gizmo overlay and external GDScript callers keep working.
//
// Spec divergence: TentacleTech_Architecture.md §4.2 specifies "raycasts" as
// the type-4 collision primitive. Per-particle sphere queries are strictly
// more accurate (motion-aware, no tunneling at typical chain speeds, native
// support for moving / kinematic / ragdoll bodies) at modest extra cost
// (~12-30 queries/tentacle/tick × 1.3-1.5× for the 4M iteration). The §4.5
// ragdoll-snapshot path becomes unnecessary because get_rest_info already
// returns the colliding body — a PhysicalBone3D's transform is read by the
// physics server during the query and routed back to us as
// `point`/`normal`/`collider_id`. See
// docs/Cosmic_Bliss_Update_2026-05-02_phase4_per_particle_probe.md and
// docs/Cosmic_Bliss_Update_2026-05-03_phase4_wedge_robustness.md.

namespace tentacletech {

// Slice 4M: max simultaneous contacts retained per particle. Wedge cases
// (tentacle pinched between two solid colliders) need 2 contacts to prevent
// the cached "nearest" contact from flipping per-tick. Bumping past 4 starts
// to cost real per-particle memory and cache; raise only if Phase 5 orifice
// scenarios surface a need.
constexpr int MAX_CONTACTS_PER_PARTICLE = 2;

struct EnvironmentContact {
	int particle_index = -1;
	godot::Vector3 query_origin; // particle position at probe time
	int contact_count = 0;       // 0..MAX_CONTACTS_PER_PARTICLE
	bool hit = false;            // == (contact_count > 0); preserved for snapshot compat

	// Per-slot contact data. Slot 0 holds the deepest contact (largest
	// penetration depth at probe time); slot 1 the next-deepest. The probe
	// fills slots in sorted order — downstream code (snapshot dictionaries
	// keeping the legacy single-contact API, friction bisector fallback)
	// relies on this contract.
	godot::Vector3 hit_point[MAX_CONTACTS_PER_PARTICLE];
	godot::Vector3 hit_normal[MAX_CONTACTS_PER_PARTICLE];
	float hit_depth[MAX_CONTACTS_PER_PARTICLE] = {0.0f, 0.0f};
	uint64_t hit_object_id[MAX_CONTACTS_PER_PARTICLE] = {0, 0};
	godot::RID hit_rid[MAX_CONTACTS_PER_PARTICLE];
	godot::Vector3 hit_linear_velocity[MAX_CONTACTS_PER_PARTICLE];
};

class EnvironmentProbe {
public:
	EnvironmentProbe();

	// Issues one sphere shape query per particle in `p_positions`. The query
	// uses a sphere of radius `p_radius_base * p_girth_scales[i]` at the
	// particle's current position. Hit results are stored as one
	// EnvironmentContact per particle (size = p_positions.size()); particles
	// without an overlap have hit=false and zero point/normal.
	void probe(godot::Node3D *p_world_node,
			const godot::PackedVector3Array &p_positions,
			const godot::PackedFloat32Array &p_girth_scales,
			float p_radius_base,
			uint32_t p_collision_mask);

	void clear();

	int get_contact_count() const { return (int)contacts.size(); }
	const EnvironmentContact &get_contact(int i) const { return contacts[i]; }
	const godot::LocalVector<EnvironmentContact> &get_contacts() const { return contacts; }

private:
	godot::Ref<godot::PhysicsShapeQueryParameters3D> shape_query;
	godot::Ref<godot::SphereShape3D> sphere_shape;
	godot::LocalVector<EnvironmentContact> contacts;
};

} // namespace tentacletech

#endif // TENTACLETECH_ENVIRONMENT_PROBE_H
