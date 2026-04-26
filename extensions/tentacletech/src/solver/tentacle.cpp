#include "tentacle.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/class_db.hpp>

using namespace godot;

Tentacle::Tentacle() {
	solver.instantiate();
	solver->initialize_chain(particle_count, segment_length);
}

Tentacle::~Tentacle() {}

void Tentacle::_ready() {
	// Place the chain in the rest pose at the node's current transform. This
	// runs in the editor too so the overlay can render a static rest pose
	// while the scene is being authored.
	rebuild_chain();

	if (Engine::get_singleton()->is_editor_hint()) {
		// Editor: no physics, but track transform changes so moving the node
		// in the viewport keeps the chain attached visually.
		set_physics_process(false);
		set_notify_transform(true);
		return;
	}
	set_physics_process(true);
}

void Tentacle::_physics_process(double p_delta) {
	if (Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	if (solver.is_null()) {
		return;
	}
	if (!anchor_override) {
		solver->set_anchor(0, get_global_transform());
	}
	solver->tick((float)p_delta);
}

void Tentacle::_notification(int p_what) {
	// Editor-only: when the user moves the node in the viewport, snap the
	// chain to the new rest pose. Runtime uses _physics_process for this.
	if (p_what == NOTIFICATION_TRANSFORM_CHANGED &&
			Engine::get_singleton()->is_editor_hint() &&
			is_inside_tree()) {
		rebuild_chain();
	}
}

// -- Configuration ----------------------------------------------------------

void Tentacle::set_particle_count(int p_count) {
	if (p_count < 2) p_count = 2;
	if (p_count == particle_count) return;
	particle_count = p_count;
	rebuild_chain();
}
int Tentacle::get_particle_count() const { return particle_count; }

void Tentacle::set_segment_length(float p_l) {
	if (p_l < 1e-4f) p_l = 1e-4f;
	if (Math::is_equal_approx(p_l, segment_length)) return;
	segment_length = p_l;
	if (solver.is_null()) {
		return;
	}
	// In editor or before the node is in the tree: snap to the new rest pose
	// so the static visual reflects the change immediately. At runtime: just
	// update the rest lengths in place — the distance constraints converge
	// over a few iterations without a visible reset.
	if (!is_inside_tree() || Engine::get_singleton()->is_editor_hint()) {
		rebuild_chain();
	} else {
		solver->set_uniform_rest_length(segment_length);
	}
}
float Tentacle::get_segment_length() const { return segment_length; }

// Solver-tuning passthroughs --------------------------------------------------

void Tentacle::set_iteration_count(int p_i) {
	if (solver.is_valid()) solver->set_iteration_count(p_i);
}
int Tentacle::get_iteration_count() const {
	return solver.is_valid() ? solver->get_iteration_count() : PBDSolver::DEFAULT_ITERATION_COUNT;
}

void Tentacle::set_gravity(const Vector3 &p_g) {
	if (solver.is_valid()) solver->set_gravity(p_g);
}
Vector3 Tentacle::get_gravity() const {
	return solver.is_valid() ? solver->get_gravity() : Vector3(0.0f, -9.8f, 0.0f);
}

void Tentacle::set_damping(float p_d) {
	if (solver.is_valid()) solver->set_damping(p_d);
}
float Tentacle::get_damping() const {
	return solver.is_valid() ? solver->get_damping() : PBDSolver::DEFAULT_DAMPING;
}

void Tentacle::set_distance_stiffness(float p_s) {
	if (solver.is_valid()) solver->set_distance_stiffness(p_s);
}
float Tentacle::get_distance_stiffness() const {
	return solver.is_valid() ? solver->get_distance_stiffness() : PBDSolver::DEFAULT_DISTANCE_STIFFNESS;
}

void Tentacle::set_bending_stiffness(float p_s) {
	if (solver.is_valid()) solver->set_bending_stiffness(p_s);
}
float Tentacle::get_bending_stiffness() const {
	return solver.is_valid() ? solver->get_bending_stiffness() : PBDSolver::DEFAULT_BENDING_STIFFNESS;
}

void Tentacle::set_asymmetry_recovery_rate(float p_r) {
	if (solver.is_valid()) solver->set_asymmetry_recovery_rate(p_r);
}
float Tentacle::get_asymmetry_recovery_rate() const {
	return solver.is_valid() ? solver->get_asymmetry_recovery_rate() : PBDSolver::DEFAULT_ASYMMETRY_RECOVERY_RATE;
}

void Tentacle::rebuild_chain() {
	if (solver.is_null()) {
		solver.instantiate();
	}
	solver->initialize_chain(particle_count, segment_length);
	// Lay the freshly-built chain along the node's current world frame so it
	// emerges from the node's -Z, not at world-origin.
	Transform3D xform = is_inside_tree() ? get_global_transform() : Transform3D();
	for (int i = 0; i < particle_count; i++) {
		Vector3 local(0.0f, 0.0f, -segment_length * (float)i);
		solver->set_particle_position(i, xform.xform(local));
	}
	solver->set_anchor(0, xform);
	anchor_override = false;
}

// -- Target pull ------------------------------------------------------------

void Tentacle::set_target(const Vector3 &p_pos) {
	if (solver.is_null()) return;
	int idx = solver->has_target() ? solver->get_target_particle_index()
									: solver->get_particle_count() - 1;
	float stiff = solver->has_target() ? solver->get_target_stiffness()
									   : PBDSolver::DEFAULT_TARGET_STIFFNESS;
	solver->set_target(idx, p_pos, stiff);
}

void Tentacle::clear_target() {
	if (solver.is_null()) return;
	solver->clear_target();
}

void Tentacle::set_target_stiffness(float p_s) {
	if (solver.is_null() || !solver->has_target()) {
		// No active target → nothing to update. Caller must set_target() first.
		return;
	}
	solver->set_target(solver->get_target_particle_index(),
			solver->get_target_position(), p_s);
}
float Tentacle::get_target_stiffness() const {
	if (solver.is_null() || !solver->has_target()) {
		return PBDSolver::DEFAULT_TARGET_STIFFNESS;
	}
	return solver->get_target_stiffness();
}

void Tentacle::set_target_particle_index(int p_idx) {
	if (solver.is_null() || !solver->has_target()) return;
	solver->set_target(p_idx, solver->get_target_position(), solver->get_target_stiffness());
}
int Tentacle::get_target_particle_index() const {
	if (solver.is_null() || !solver->has_target()) return -1;
	return solver->get_target_particle_index();
}

// -- Anchor override --------------------------------------------------------

void Tentacle::set_anchor_transform(const Transform3D &p_x) {
	if (solver.is_null()) return;
	solver->set_anchor(0, p_x);
	anchor_override = true;
}

void Tentacle::clear_anchor_override() {
	anchor_override = false;
}

// -- Solver access ----------------------------------------------------------

Ref<PBDSolver> Tentacle::get_solver() const { return solver; }

// -- Snapshots --------------------------------------------------------------

PackedVector3Array Tentacle::get_particle_positions() const {
	if (solver.is_null()) return PackedVector3Array();
	return solver->get_particle_positions();
}

PackedFloat32Array Tentacle::get_particle_inv_masses() const {
	if (solver.is_null()) return PackedFloat32Array();
	return solver->get_particle_inv_masses();
}

PackedFloat32Array Tentacle::get_segment_stretch_ratios() const {
	if (solver.is_null()) return PackedFloat32Array();
	return solver->get_segment_stretch_ratios();
}

Dictionary Tentacle::get_target_pull_state() const {
	Dictionary d;
	if (solver.is_null() || !solver->has_target()) {
		d["active"] = false;
		d["target"] = Vector3();
		d["particle_index"] = -1;
		d["force_dir"] = Vector3();
		return d;
	}
	int idx = solver->get_target_particle_index();
	Vector3 target = solver->get_target_position();
	Vector3 from = solver->get_particle_position(idx);
	Vector3 dir = target - from;
	float len = dir.length();
	if (len > 1e-6f) {
		dir = dir / len;
	} else {
		dir = Vector3();
	}
	d["active"] = true;
	d["target"] = target;
	d["particle_index"] = idx;
	d["force_dir"] = dir;
	return d;
}

Dictionary Tentacle::get_anchor_state() const {
	Dictionary d;
	if (solver.is_null() || !solver->has_anchor()) {
		d["particle_index"] = -1;
		d["world_xform"] = Transform3D();
		return d;
	}
	d["particle_index"] = solver->get_anchor_particle_index();
	d["world_xform"] = solver->get_anchor_transform();
	return d;
}

// -- Binding ----------------------------------------------------------------

void Tentacle::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_particle_count", "count"), &Tentacle::set_particle_count);
	ClassDB::bind_method(D_METHOD("get_particle_count"), &Tentacle::get_particle_count);
	ClassDB::bind_method(D_METHOD("set_segment_length", "length"), &Tentacle::set_segment_length);
	ClassDB::bind_method(D_METHOD("get_segment_length"), &Tentacle::get_segment_length);
	ClassDB::bind_method(D_METHOD("rebuild_chain"), &Tentacle::rebuild_chain);

	ClassDB::bind_method(D_METHOD("set_iteration_count", "iter"), &Tentacle::set_iteration_count);
	ClassDB::bind_method(D_METHOD("get_iteration_count"), &Tentacle::get_iteration_count);
	ClassDB::bind_method(D_METHOD("set_gravity", "gravity"), &Tentacle::set_gravity);
	ClassDB::bind_method(D_METHOD("get_gravity"), &Tentacle::get_gravity);
	ClassDB::bind_method(D_METHOD("set_damping", "damping"), &Tentacle::set_damping);
	ClassDB::bind_method(D_METHOD("get_damping"), &Tentacle::get_damping);
	ClassDB::bind_method(D_METHOD("set_distance_stiffness", "stiffness"), &Tentacle::set_distance_stiffness);
	ClassDB::bind_method(D_METHOD("get_distance_stiffness"), &Tentacle::get_distance_stiffness);
	ClassDB::bind_method(D_METHOD("set_bending_stiffness", "stiffness"), &Tentacle::set_bending_stiffness);
	ClassDB::bind_method(D_METHOD("get_bending_stiffness"), &Tentacle::get_bending_stiffness);
	ClassDB::bind_method(D_METHOD("set_asymmetry_recovery_rate", "rate"), &Tentacle::set_asymmetry_recovery_rate);
	ClassDB::bind_method(D_METHOD("get_asymmetry_recovery_rate"), &Tentacle::get_asymmetry_recovery_rate);

	ClassDB::bind_method(D_METHOD("set_target", "world_pos"), &Tentacle::set_target);
	ClassDB::bind_method(D_METHOD("clear_target"), &Tentacle::clear_target);
	ClassDB::bind_method(D_METHOD("set_target_stiffness", "stiffness"), &Tentacle::set_target_stiffness);
	ClassDB::bind_method(D_METHOD("get_target_stiffness"), &Tentacle::get_target_stiffness);
	ClassDB::bind_method(D_METHOD("set_target_particle_index", "index"), &Tentacle::set_target_particle_index);
	ClassDB::bind_method(D_METHOD("get_target_particle_index"), &Tentacle::get_target_particle_index);

	ClassDB::bind_method(D_METHOD("set_anchor_transform", "xform"), &Tentacle::set_anchor_transform);
	ClassDB::bind_method(D_METHOD("clear_anchor_override"), &Tentacle::clear_anchor_override);

	ClassDB::bind_method(D_METHOD("get_solver"), &Tentacle::get_solver);

	ClassDB::bind_method(D_METHOD("get_particle_positions"), &Tentacle::get_particle_positions);
	ClassDB::bind_method(D_METHOD("get_particle_inv_masses"), &Tentacle::get_particle_inv_masses);
	ClassDB::bind_method(D_METHOD("get_segment_stretch_ratios"), &Tentacle::get_segment_stretch_ratios);
	ClassDB::bind_method(D_METHOD("get_target_pull_state"), &Tentacle::get_target_pull_state);
	ClassDB::bind_method(D_METHOD("get_anchor_state"), &Tentacle::get_anchor_state);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "particle_count", PROPERTY_HINT_RANGE, "2,48,1"),
			"set_particle_count", "get_particle_count");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "segment_length", PROPERTY_HINT_RANGE, "0.001,1.0,0.001,or_greater"),
			"set_segment_length", "get_segment_length");

	ADD_GROUP("Solver", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "iteration_count", PROPERTY_HINT_RANGE, "1,6,1"),
			"set_iteration_count", "get_iteration_count");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "gravity"),
			"set_gravity", "get_gravity");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "damping", PROPERTY_HINT_RANGE, "0.0,1.0,0.001"),
			"set_damping", "get_damping");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "distance_stiffness", PROPERTY_HINT_RANGE, "0.0,1.0,0.001"),
			"set_distance_stiffness", "get_distance_stiffness");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "bending_stiffness", PROPERTY_HINT_RANGE, "0.0,1.0,0.001"),
			"set_bending_stiffness", "get_bending_stiffness");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "asymmetry_recovery_rate", PROPERTY_HINT_RANGE, "0.0,10.0,0.01,or_greater"),
			"set_asymmetry_recovery_rate", "get_asymmetry_recovery_rate");
}
