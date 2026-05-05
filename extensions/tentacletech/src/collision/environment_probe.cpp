#include "environment_probe.h"

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/variant/array.hpp>
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
		uint32_t p_collision_mask,
		float p_feature_radius_padding) {
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

	// Reused per-particle exclude list — RIDs of bodies already-found this
	// particle's slots. Cleared at the top of each particle loop. Out here
	// to avoid Array reallocation per particle (godot::Array grows by ref).
	Array exclude_list;

	for (int i = 0; i < n; i++) {
		EnvironmentContact &c = contacts[i];
		c.particle_index = i;
		c.query_origin = src[i];
		c.contact_count = 0;
		c.hit = false;
		for (int k = 0; k < MAX_CONTACTS_PER_PARTICLE; k++) {
			c.hit_point[k] = Vector3();
			c.hit_normal[k] = Vector3();
			c.hit_depth[k] = 0.0f;
			c.hit_object_id[k] = 0;
			c.hit_rid[k] = RID();
			c.hit_linear_velocity[k] = Vector3();
		}

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
		// Slice 5H — extend the query radius by a per-tentacle padding
		// representing the maximum outward feature silhouette
		// perturbation. This guarantees the broadphase finds contacts
		// the per-θ sampler in the contact step would consider valid;
		// without padding, a wart-bearing chain would slip past colliders
		// the smooth-girth probe radius alone wouldn't catch.
		float biased = radius * QUERY_BIAS + p_feature_radius_padding;
		sphere_shape->set_radius(biased);
		xform.origin = src[i];
		shape_query->set_transform(xform);

		// Slice 4M: iterate get_rest_info up to MAX_CONTACTS_PER_PARTICLE
		// times, excluding bodies already found so each pass returns the
		// next-best contact. Two passes suffice for the 2-contact wedge
		// case: pass 1 finds the closest body, pass 2 (with the first
		// excluded) finds the next-closest. Empty result terminates early.
		exclude_list.clear();
		for (int k = 0; k < MAX_CONTACTS_PER_PARTICLE; k++) {
			shape_query->set_exclude(exclude_list);
			Dictionary result = space->get_rest_info(shape_query);
			if (result.is_empty()) {
				break;
			}
			Vector3 hit_point = result["point"];
			Vector3 hit_normal = result["normal"];
			// PBD penetration depth: how far the unbiased sphere overlaps
			// the surface along its outward normal. The query used a
			// biased sphere; recompute against `radius` so the depth is
			// what the solver's projection step will see.
			float depth = radius - (src[i] - hit_point).dot(hit_normal);
			c.hit_point[k] = hit_point;
			c.hit_normal[k] = hit_normal;
			c.hit_depth[k] = depth;
			Variant cid = result["collider_id"];
			c.hit_object_id[k] = (uint64_t)(int64_t)cid;
			RID rid;
			if (result.has("rid")) {
				rid = result["rid"];
			}
			c.hit_rid[k] = rid;
			if (result.has("linear_velocity")) {
				c.hit_linear_velocity[k] = result["linear_velocity"];
			}
			c.contact_count++;
			// Add this body to the exclude list so the next get_rest_info
			// pass returns a different body. Empty RID is unusual but
			// guarded: append it anyway — the physics server treats it as
			// a no-op exclude.
			exclude_list.push_back(rid);
		}
		c.hit = (c.contact_count > 0);

		// Sort slots by depth descending (slot 0 deepest). For
		// MAX_CONTACTS_PER_PARTICLE = 2 this is a single compare-and-swap.
		// Downstream code relies on this ordering: the friction-bisector
		// fallback uses slot 0 as "deepest"; the snapshot dictionary
		// keys (legacy single-contact API) read slot 0 too.
		if (c.contact_count == 2 && c.hit_depth[0] < c.hit_depth[1]) {
			Vector3 tp = c.hit_point[0]; c.hit_point[0] = c.hit_point[1]; c.hit_point[1] = tp;
			Vector3 tn = c.hit_normal[0]; c.hit_normal[0] = c.hit_normal[1]; c.hit_normal[1] = tn;
			float td = c.hit_depth[0]; c.hit_depth[0] = c.hit_depth[1]; c.hit_depth[1] = td;
			uint64_t to = c.hit_object_id[0]; c.hit_object_id[0] = c.hit_object_id[1]; c.hit_object_id[1] = to;
			RID tr = c.hit_rid[0]; c.hit_rid[0] = c.hit_rid[1]; c.hit_rid[1] = tr;
			Vector3 tv = c.hit_linear_velocity[0]; c.hit_linear_velocity[0] = c.hit_linear_velocity[1]; c.hit_linear_velocity[1] = tv;
		}
	}
}

} // namespace tentacletech
