#include "environment_probe.h"

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/variant/dictionary.hpp>

using namespace godot;

namespace tentacletech {

EnvironmentProbe::EnvironmentProbe() {
	contacts.resize(RAY_COUNT);
}

void EnvironmentProbe::clear() {
	for (uint32_t i = 0; i < contacts.size(); i++) {
		contacts[i] = EnvironmentContact();
	}
}

void EnvironmentProbe::probe(Node3D *p_world_node,
		const PackedVector3Array &p_positions,
		const Vector3 &p_gravity_unit,
		float p_max_distance,
		uint32_t p_collision_mask) {
	if ((int)contacts.size() != RAY_COUNT) {
		contacts.resize(RAY_COUNT);
	}
	clear();

	if (p_world_node == nullptr || !p_world_node->is_inside_tree()) {
		return;
	}
	int n = p_positions.size();
	if (n < 2) {
		return;
	}

	Ref<World3D> world = p_world_node->get_world_3d();
	if (world.is_null()) {
		return;
	}
	PhysicsDirectSpaceState3D *space = world->get_direct_space_state();
	if (space == nullptr) {
		return;
	}

	Vector3 dir = p_gravity_unit;
	float dlen2 = dir.length_squared();
	if (dlen2 < 1e-8f) {
		dir = Vector3(0.0f, -1.0f, 0.0f);
	} else {
		dir = dir / Math::sqrt(dlen2);
	}
	if (p_max_distance < 1e-4f) {
		p_max_distance = 1e-4f;
	}

	if (ray_query.is_null()) {
		ray_query.instantiate();
	}
	ray_query->set_collision_mask(p_collision_mask);
	ray_query->set_collide_with_bodies(true);
	ray_query->set_collide_with_areas(false);

	const int sample_indices[RAY_COUNT] = {
		0,
		n / 2,
		n - 1,
	};
	const Vector3 *src = p_positions.ptr();

	for (int i = 0; i < RAY_COUNT; i++) {
		EnvironmentContact &c = contacts[i];
		c.ray_origin = src[sample_indices[i]];
		c.ray_direction = dir;
		c.hit = false;
		c.hit_point = Vector3();
		c.hit_normal = Vector3();
		c.hit_object_id = 0;

		ray_query->set_from(c.ray_origin);
		ray_query->set_to(c.ray_origin + dir * p_max_distance);

		Dictionary result = space->intersect_ray(ray_query);
		if (result.is_empty()) {
			continue;
		}
		c.hit = true;
		c.hit_point = result["position"];
		c.hit_normal = result["normal"];
		Object *col = (Object *)result["collider"];
		c.hit_object_id = (col != nullptr) ? (uint64_t)col->get_instance_id() : 0;
	}
}

} // namespace tentacletech
