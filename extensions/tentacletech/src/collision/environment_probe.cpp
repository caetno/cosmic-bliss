#include "environment_probe.h"

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/transform3d.hpp>

using namespace godot;

namespace tentacletech {

EnvironmentProbe::EnvironmentProbe() {}

void EnvironmentProbe::clear() {
	for (uint32_t i = 0; i < contacts.size(); i++) {
		contacts[i] = EnvironmentContact();
	}
}

void EnvironmentProbe::probe(Node3D *p_world_node,
		const PackedVector3Array &p_positions,
		const PackedFloat32Array &p_girth_scales,
		float p_radius_base,
		uint32_t p_collision_mask) {
	int n = p_positions.size();

	if ((int)contacts.size() != n) {
		contacts.resize(n);
	}
	clear();

	if (n == 0) {
		return;
	}
	if (p_world_node == nullptr || !p_world_node->is_inside_tree()) {
		return;
	}
	if (p_radius_base < 1e-5f) {
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

	if (sphere_shape.is_null()) {
		sphere_shape.instantiate();
	}
	if (shape_query.is_null()) {
		shape_query.instantiate();
		shape_query->set_collide_with_bodies(true);
		shape_query->set_collide_with_areas(false);
	}
	shape_query->set_shape(sphere_shape);
	shape_query->set_collision_mask(p_collision_mask);

	const Vector3 *src = p_positions.ptr();
	const float *gs = (p_girth_scales.size() == n) ? p_girth_scales.ptr() : nullptr;

	Transform3D xform; // identity rotation + per-particle origin

	for (int i = 0; i < n; i++) {
		EnvironmentContact &c = contacts[i];
		c.particle_index = i;
		c.query_origin = src[i];
		c.hit = false;
		c.hit_point = Vector3();
		c.hit_normal = Vector3();
		c.hit_object_id = 0;
		c.hit_linear_velocity = Vector3();

		float radius = p_radius_base * (gs ? gs[i] : 1.0f);
		if (radius < 1e-5f) {
			continue;
		}
		// Bias the query radius slightly larger than the projection radius so
		// tangent contacts (settled chain hovering exactly at the boundary)
		// are still detected. The PBD projection uses the unbiased radius via
		// the solver's `collision_radius`, so this bias only affects detection
		// — particles that are exactly at the surface get reported in-contact
		// (so contact_stiffness softening engages) but no spurious push-out
		// is applied (depth ≤ 0 in the solver pass).
		const float QUERY_BIAS = 1.05f;
		sphere_shape->set_radius(radius * QUERY_BIAS);
		xform.origin = src[i];
		shape_query->set_transform(xform);

		Dictionary result = space->get_rest_info(shape_query);
		if (result.is_empty()) {
			continue;
		}
		c.hit = true;
		c.hit_point = result["point"];
		c.hit_normal = result["normal"];
		// `collider_id` is the colliding body's instance ID. Cast through
		// int64 since Variant stores it that way and Godot's API exposes it
		// as a signed int.
		Variant cid = result["collider_id"];
		c.hit_object_id = (uint64_t)(int64_t)cid;
		if (result.has("rid")) {
			c.hit_rid = result["rid"];
		}
		if (result.has("linear_velocity")) {
			c.hit_linear_velocity = result["linear_velocity"];
		}
	}
}

} // namespace tentacletech
