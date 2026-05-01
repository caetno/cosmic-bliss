#ifndef TENTACLETECH_ENVIRONMENT_PROBE_H
#define TENTACLETECH_ENVIRONMENT_PROBE_H

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/physics_ray_query_parameters3d.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/templates/local_vector.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

// Phase-4 slice 4A: cheap raycast probe for type-4 (particle vs environment)
// collision per docs/architecture/TentacleTech_Architecture.md §4.2.
//
// One instance lives on each Tentacle. probe() runs three rays per tick
// before the PBD iteration loop and stores the hits as half-space planes
// the solver can project particles out of. The reusable
// PhysicsRayQueryParameters3D ref is allocated lazily on the first probe()
// call; subsequent calls only mutate from/to/mask, so the per-tick path
// is allocation-free.
//
// Slice 4A pattern: rays are cast from base, midpoint, and tip particles in
// the gravity direction. Spec calls for "gravity-down + 2 lateral
// perpendiculars to the chain mid-tangent"; this simpler all-gravity layout
// gives a sharper "drape on the floor below" signal which is the only thing
// 4A needs to demonstrate. Lateral steering follows once the behavior driver
// can express it.

namespace tentacletech {

struct EnvironmentContact {
	godot::Vector3 ray_origin;
	godot::Vector3 ray_direction; // unit vector
	bool hit = false;
	godot::Vector3 hit_point;
	godot::Vector3 hit_normal;
	uint64_t hit_object_id = 0; // collider's get_instance_id(); 0 if no hit
};

class EnvironmentProbe {
public:
	static constexpr int RAY_COUNT = 3;

	EnvironmentProbe();

	// Casts RAY_COUNT rays in `p_gravity_unit` from base / mid / tip particle
	// positions. Skipped (contacts cleared) if the world's space state isn't
	// available (headless without physics, node not in tree, etc.).
	void probe(godot::Node3D *p_world_node,
			const godot::PackedVector3Array &p_particle_positions,
			const godot::Vector3 &p_gravity_unit,
			float p_max_distance,
			uint32_t p_collision_mask);

	void clear();

	int get_contact_count() const { return (int)contacts.size(); }
	const EnvironmentContact &get_contact(int i) const { return contacts[i]; }
	const godot::LocalVector<EnvironmentContact> &get_contacts() const { return contacts; }

private:
	godot::Ref<godot::PhysicsRayQueryParameters3D> ray_query;
	godot::LocalVector<EnvironmentContact> contacts;
};

} // namespace tentacletech

#endif // TENTACLETECH_ENVIRONMENT_PROBE_H
