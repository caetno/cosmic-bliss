#include "tentacle.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/script.hpp>
#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>

#include "../spline/spline_data_packer.h"

using namespace godot;

namespace {
// Channel order in the packed spline data, agreed with tentacle_lib.gdshaderinc.
constexpr int CHANNEL_GIRTH_SCALE = 0;
constexpr int CHANNEL_ASYM_X = 1;
constexpr int CHANNEL_ASYM_Y = 2;
constexpr int CHANNEL_COUNT = 3;
constexpr int REST_GIRTH_TEXTURE_WIDTH = 256;
const char *SHADER_RES_PATH = "res://addons/tentacletech/shaders/tentacle.gdshader";
const char *UNIFORM_SPLINE_DATA = "spline_data_texture";
const char *UNIFORM_SPLINE_DATA_WIDTH = "spline_data_width";
const char *UNIFORM_REST_GIRTH = "rest_girth_texture";
const char *UNIFORM_MESH_ARC_AXIS = "mesh_arc_axis";
const char *UNIFORM_MESH_ARC_SIGN = "mesh_arc_sign";
const char *UNIFORM_MESH_ARC_OFFSET = "mesh_arc_offset";
} // namespace

Tentacle::Tentacle() {
	solver.instantiate();
	solver->initialize_chain(particle_count, segment_length);
	solver->set_collision_radius(particle_collision_radius);
	solver->set_friction(base_static_friction * (1.0f - tentacle_lubricity),
			kinetic_friction_ratio);
	solver->set_contact_stiffness(contact_stiffness);
	render_spline.instantiate();
}

Tentacle::~Tentacle() {}

void Tentacle::_ready() {
	// Place the chain in the rest pose at the node's current transform. This
	// runs in the editor too so the overlay can render a static rest pose
	// while the scene is being authored.
	rebuild_chain();

	_ensure_mesh_instance();
	_allocate_render_resources();
	_refresh_mesh_instance();
	_refresh_shader_material_bindings();
	_update_spline_data_texture();

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
	tick((float)p_delta);
}

void Tentacle::tick(float p_delta) {
	if (solver.is_null()) {
		return;
	}
	if (!anchor_override) {
		solver->set_anchor(0, get_global_transform());
	}
	_run_environment_probe();
	solver->tick(p_delta);
	_update_spline_data_texture();
}

void Tentacle::_run_environment_probe() {
	if (solver.is_null()) {
		return;
	}
	if (!environment_probe_enabled) {
		environment_probe.clear();
		solver->clear_environment_contacts();
		return;
	}
	int n = solver->get_particle_count();
	if (n < 2) {
		environment_probe.clear();
		solver->clear_environment_contacts();
		return;
	}
	if (env_position_scratch.size() != n) {
		env_position_scratch.resize(n);
	}
	{
		Vector3 *dst = env_position_scratch.ptrw();
		for (int i = 0; i < n; i++) {
			dst[i] = solver->get_particle_position(i);
		}
	}

	Vector3 grav = solver->get_gravity();
	if (grav.length_squared() < 1e-8f) {
		grav = Vector3(0.0f, -1.0f, 0.0f);
	}

	environment_probe.probe(this, env_position_scratch, grav,
			environment_probe_distance,
			(uint32_t)environment_collision_layer_mask);

	const auto &contacts = environment_probe.get_contacts();
	int hit_count = 0;
	for (uint32_t i = 0; i < contacts.size(); i++) {
		if (contacts[i].hit) hit_count++;
	}
	if (env_contact_points_scratch.size() != hit_count) {
		env_contact_points_scratch.resize(hit_count);
	}
	if (env_contact_normals_scratch.size() != hit_count) {
		env_contact_normals_scratch.resize(hit_count);
	}
	if (hit_count > 0) {
		Vector3 *cp = env_contact_points_scratch.ptrw();
		Vector3 *cn = env_contact_normals_scratch.ptrw();
		int k = 0;
		for (uint32_t i = 0; i < contacts.size(); i++) {
			if (!contacts[i].hit) continue;
			cp[k] = contacts[i].hit_point;
			cn[k] = contacts[i].hit_normal;
			k++;
		}
	}
	solver->set_environment_contacts(env_contact_points_scratch,
			env_contact_normals_scratch);
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
	// Recompute segment_length from the assigned mesh's length BEFORE the
	// rebuild so the freshly-laid chain uses the right per-segment rest.
	_apply_mesh_length_to_segment_length();
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

void Tentacle::set_base_angular_velocity_limit(float p_omega) {
	if (solver.is_valid()) solver->set_base_angular_velocity_limit(p_omega);
}
float Tentacle::get_base_angular_velocity_limit() const {
	return solver.is_valid() ? solver->get_base_angular_velocity_limit() : PBDSolver::DEFAULT_BASE_ANGULAR_VELOCITY_LIMIT;
}

void Tentacle::set_rigid_base_count(int p_count) {
	if (solver.is_valid()) solver->set_rigid_base_count(p_count);
	// Re-issue the anchor so the newly-pinned particles snap to the
	// captured local offsets immediately, without waiting for the next
	// transform-changed notification.
	if (solver.is_valid() && solver->has_anchor()) {
		solver->set_anchor(solver->get_anchor_particle_index(), solver->get_anchor_transform());
	}
}
int Tentacle::get_rigid_base_count() const {
	return solver.is_valid() ? solver->get_rigid_base_count() : 1;
}

void Tentacle::rebuild_chain() {
	if (solver.is_null()) {
		solver.instantiate();
	}
	// `initialize_chain` resets `rigid_base_count` to 1 and discards the
	// captured offsets. Snapshot the authored value before the reset so we
	// can re-pin the right block after the chain is laid out in the new
	// anchor frame; otherwise scene-load clobbers the .tscn property and
	// only runtime edits stick.
	int desired_rigid = solver->get_rigid_base_count();
	solver->initialize_chain(particle_count, segment_length);
	// Lay the freshly-built chain along the node's current world frame so it
	// emerges from the node's -Z, not at world-origin.
	Transform3D xform = is_inside_tree() ? get_global_transform() : Transform3D();
	for (int i = 0; i < particle_count; i++) {
		Vector3 local(0.0f, 0.0f, -segment_length * (float)i);
		solver->set_particle_position(i, xform.xform(local));
	}
	solver->set_anchor(0, xform);
	if (desired_rigid > 1) {
		solver->set_rigid_base_count(desired_rigid);
	}
	anchor_override = false;

	// Particle count may have changed; resize the per-tick buffers and the
	// data texture to match the new chain. Safe to call before _ready (does
	// nothing if the texture isn't allocated yet) and re-runs from _ready.
	_allocate_render_resources();
	_update_spline_data_texture();
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

// -- Pose targets (multi-particle distributed pull) -------------------------

void Tentacle::set_pose_targets(const PackedInt32Array &p_indices,
		const PackedVector3Array &p_world_positions,
		const PackedFloat32Array &p_stiffnesses) {
	if (solver.is_null()) return;
	solver->set_pose_targets(p_indices, p_world_positions, p_stiffnesses);
}

void Tentacle::clear_pose_targets() {
	if (solver.is_null()) return;
	solver->clear_pose_targets();
}

int Tentacle::get_pose_target_count() const {
	if (solver.is_null()) return 0;
	return solver->get_pose_target_count();
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

// -- Environment probe ------------------------------------------------------

void Tentacle::set_environment_probe_enabled(bool p_enabled) {
	environment_probe_enabled = p_enabled;
	if (!p_enabled && solver.is_valid()) {
		solver->clear_environment_contacts();
	}
}
bool Tentacle::get_environment_probe_enabled() const { return environment_probe_enabled; }

void Tentacle::set_environment_probe_distance(float p_d) {
	if (p_d < 1e-4f) p_d = 1e-4f;
	environment_probe_distance = p_d;
}
float Tentacle::get_environment_probe_distance() const { return environment_probe_distance; }

void Tentacle::set_environment_collision_layer_mask(int p_mask) {
	environment_collision_layer_mask = p_mask;
}
int Tentacle::get_environment_collision_layer_mask() const { return environment_collision_layer_mask; }

void Tentacle::set_particle_collision_radius(float p_r) {
	if (p_r < 0.0f) p_r = 0.0f;
	particle_collision_radius = p_r;
	if (solver.is_valid()) {
		solver->set_collision_radius(p_r);
	}
}
float Tentacle::get_particle_collision_radius() const { return particle_collision_radius; }

void Tentacle::set_base_static_friction(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	base_static_friction = p_v;
	if (solver.is_valid()) {
		solver->set_friction(base_static_friction * (1.0f - tentacle_lubricity),
				kinetic_friction_ratio);
	}
}
float Tentacle::get_base_static_friction() const { return base_static_friction; }

void Tentacle::set_tentacle_lubricity(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	if (p_v > 1.0f) p_v = 1.0f;
	tentacle_lubricity = p_v;
	if (solver.is_valid()) {
		solver->set_friction(base_static_friction * (1.0f - tentacle_lubricity),
				kinetic_friction_ratio);
	}
}
float Tentacle::get_tentacle_lubricity() const { return tentacle_lubricity; }

void Tentacle::set_kinetic_friction_ratio(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	if (p_v > 1.0f) p_v = 1.0f;
	kinetic_friction_ratio = p_v;
	if (solver.is_valid()) {
		solver->set_friction(base_static_friction * (1.0f - tentacle_lubricity),
				kinetic_friction_ratio);
	}
}
float Tentacle::get_kinetic_friction_ratio() const { return kinetic_friction_ratio; }

void Tentacle::set_contact_stiffness(float p_v) {
	if (p_v < 0.0f) p_v = 0.0f;
	if (p_v > 1.0f) p_v = 1.0f;
	contact_stiffness = p_v;
	if (solver.is_valid()) {
		solver->set_contact_stiffness(p_v);
	}
}
float Tentacle::get_contact_stiffness() const { return contact_stiffness; }

Array Tentacle::get_environment_contacts_snapshot() const {
	Array out;
	const auto &contacts = environment_probe.get_contacts();
	int n = (int)contacts.size();
	out.resize(n);
	// Friction-applied buffer is sized the same as the solver's contact list,
	// which is rebuilt from `contacts` each tick — but only entries with
	// hit==true become solver contacts, so the buffer is shorter than `n`.
	// Walk the two in lock-step over hit entries to align indices.
	PackedVector3Array friction_applied;
	if (solver.is_valid()) {
		friction_applied = solver->get_environment_friction_applied();
	}
	int hit_cursor = 0;
	for (int i = 0; i < n; i++) {
		const tentacletech::EnvironmentContact &c = contacts[i];
		Dictionary d;
		d["ray_origin"] = c.ray_origin;
		d["ray_direction"] = c.ray_direction;
		d["hit"] = c.hit;
		d["hit_point"] = c.hit_point;
		d["hit_normal"] = c.hit_normal;
		d["hit_object_id"] = (int64_t)c.hit_object_id;
		Vector3 fa;
		if (c.hit && hit_cursor < friction_applied.size()) {
			fa = friction_applied[hit_cursor];
			hit_cursor++;
		}
		d["friction_applied"] = fa;
		out[i] = d;
	}
	return out;
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

// -- Render plumbing --------------------------------------------------------

void Tentacle::set_tentacle_mesh(const Ref<Mesh> &p_mesh) {
	// If we were tracking a previous TentacleMesh's `changed` signal, drop
	// the connection so re-bakes on stale resources don't kick us.
	if (tentacle_mesh.is_valid() && tentacle_mesh->is_connected("changed",
			callable_mp(this, &Tentacle::_on_tentacle_mesh_changed))) {
		tentacle_mesh->disconnect("changed",
				callable_mp(this, &Tentacle::_on_tentacle_mesh_changed));
	}

	tentacle_mesh = p_mesh;
	_refresh_mesh_instance();

	if (tentacle_mesh.is_null()) {
		return;
	}

	// Duck-type the new mesh: a `TentacleMesh` (GDScript ArrayMesh subclass,
	// §10.2) exposes `get_baked_girth_texture` and emits `changed` after
	// each rebuild. For stock primitives these hooks are absent; we leave
	// the rest-girth uniform alone so the placeholder / explicit setter
	// value persists.
	if (tentacle_mesh->has_method("get_baked_girth_texture")) {
		_pull_baked_girth_from_mesh();
		// Re-pull whenever the mesh re-bakes (inspector slider drag, etc.).
		if (!tentacle_mesh->is_connected("changed",
				callable_mp(this, &Tentacle::_on_tentacle_mesh_changed))) {
			tentacle_mesh->connect("changed",
					callable_mp(this, &Tentacle::_on_tentacle_mesh_changed));
		}
	}
	_apply_mesh_length_to_segment_length();
}
Ref<Mesh> Tentacle::get_tentacle_mesh() const { return tentacle_mesh; }

void Tentacle::_pull_baked_girth_from_mesh() {
	if (tentacle_mesh.is_null()) {
		return;
	}
	if (!tentacle_mesh->has_method("get_baked_girth_texture")) {
		return;
	}
	Variant raw = tentacle_mesh->call("get_baked_girth_texture");
	Ref<ImageTexture> tex = raw;
	if (tex.is_valid()) {
		set_rest_girth_texture(tex);
	}

	// TentacleMesh also reports its arc-axis convention. Without this, a mesh
	// whose tip is at -Z (intrinsic_axis_sign=-1, the §10.1 default) collapses
	// in the shader because tt_distance_to_parameter clamps negative arcs.
	if (tentacle_mesh->has_method("get_baked_arc_convention")) {
		Variant raw_conv = tentacle_mesh->call("get_baked_arc_convention");
		Dictionary conv = raw_conv;
		if (conv.has("axis")) {
			set_mesh_arc_axis((int)conv["axis"]);
		}
		if (conv.has("sign")) {
			set_mesh_arc_sign((int)conv["sign"]);
		}
		if (conv.has("offset")) {
			set_mesh_arc_offset((float)conv["offset"]);
		}
	}
}

void Tentacle::_on_tentacle_mesh_changed() {
	_pull_baked_girth_from_mesh();
	_apply_mesh_length_to_segment_length();
}

void Tentacle::_apply_mesh_length_to_segment_length() {
	if (tentacle_mesh.is_null()) {
		return;
	}
	if (particle_count < 2) {
		return;
	}
	// Prefer `get_baked_rest_length()` when the mesh exposes it: the bake's
	// rest length spans the *full* axial extent (body + tip cap + base
	// flange, etc.), which is what the shader's spline-arc parameterization
	// expects. Using only the body `length` here makes the chain shorter
	// than the mesh, so any vertex past z=length (the cap) clamps to the
	// spline tip and the dome collapses into a flat disc. Stock primitives
	// without the bake hook fall back to the `length` property; if neither
	// is present, leave segment_length untouched.
	float mesh_len = -1.0f;
	if (tentacle_mesh->has_method("get_baked_rest_length")) {
		Variant raw = tentacle_mesh->call("get_baked_rest_length");
		if (raw.get_type() == Variant::FLOAT || raw.get_type() == Variant::INT) {
			mesh_len = (float)raw;
		}
	}
	if (mesh_len <= 0.0f) {
		Variant raw_len = tentacle_mesh->get("length");
		Variant::Type t = raw_len.get_type();
		if (t != Variant::FLOAT && t != Variant::INT) {
			return;
		}
		mesh_len = (float)raw_len;
	}
	if (mesh_len <= 0.0f) {
		return;
	}
	float new_seg = mesh_len / (float)(particle_count - 1);
	set_segment_length(new_seg);
}

void Tentacle::set_mesh_arc_axis(int p_axis) {
	if (p_axis < 0) p_axis = 0;
	if (p_axis > 2) p_axis = 2;
	mesh_arc_axis = p_axis;
	if (shader_material.is_valid()) {
		shader_material->set_shader_parameter(UNIFORM_MESH_ARC_AXIS, mesh_arc_axis);
	}
}
int Tentacle::get_mesh_arc_axis() const { return mesh_arc_axis; }

void Tentacle::set_mesh_arc_sign(int p_sign) {
	// Clamp to ±1 — anything else is meaningless for the convention. Pass 0
	// through as +1 (no-op default).
	if (p_sign < 0) p_sign = -1;
	else p_sign = 1;
	mesh_arc_sign = p_sign;
	if (shader_material.is_valid()) {
		shader_material->set_shader_parameter(UNIFORM_MESH_ARC_SIGN, (float)mesh_arc_sign);
	}
}
int Tentacle::get_mesh_arc_sign() const { return mesh_arc_sign; }

void Tentacle::set_mesh_arc_offset(float p_offset) {
	mesh_arc_offset = p_offset;
	if (shader_material.is_valid()) {
		shader_material->set_shader_parameter(UNIFORM_MESH_ARC_OFFSET, mesh_arc_offset);
	}
}
float Tentacle::get_mesh_arc_offset() const { return mesh_arc_offset; }

Ref<ShaderMaterial> Tentacle::get_shader_material() const { return shader_material; }
void Tentacle::set_shader_material(const Ref<ShaderMaterial> &p_mat) {
	shader_material = p_mat;
	_refresh_mesh_instance();
	_refresh_shader_material_bindings();
}

Ref<ImageTexture> Tentacle::get_spline_data_texture() const { return spline_data_texture; }
int Tentacle::get_spline_data_texture_width() const { return spline_data_width; }
Ref<Image> Tentacle::get_spline_data_image() const { return spline_data_image; }
Ref<ImageTexture> Tentacle::get_rest_girth_texture() const { return rest_girth_texture; }

void Tentacle::set_rest_girth_texture(const Ref<ImageTexture> &p_tex) {
	rest_girth_texture = p_tex;
	if (shader_material.is_valid() && rest_girth_texture.is_valid()) {
		shader_material->set_shader_parameter(UNIFORM_REST_GIRTH, rest_girth_texture);
	}
}

PackedVector3Array Tentacle::get_spline_samples(int p_count) const {
	PackedVector3Array out;
	if (render_spline.is_null() || p_count < 2) {
		return out;
	}
	out.resize(p_count);
	Vector3 *ptr = out.ptrw();
	for (int i = 0; i < p_count; i++) {
		float t = (float)i / (float)(p_count - 1);
		ptr[i] = render_spline->evaluate_position(t);
	}
	return out;
}

Array Tentacle::get_spline_frames(int p_count) const {
	Array out;
	if (render_spline.is_null() || p_count < 2) {
		return out;
	}
	out.resize(p_count);
	for (int i = 0; i < p_count; i++) {
		float t = (float)i / (float)(p_count - 1);
		Vector3 pos = render_spline->evaluate_position(t);
		Vector3 tan, nrm, binormal;
		render_spline->evaluate_frame(t, tan, nrm, binormal);
		Dictionary d;
		d["position"] = pos;
		d["tangent"] = tan;
		d["normal"] = nrm;
		d["binormal"] = binormal;
		out[i] = d;
	}
	return out;
}

void Tentacle::update_render_data() {
	_update_spline_data_texture();
}

void Tentacle::set_draw_gizmo(bool p_enabled) {
	if (draw_gizmo == p_enabled) return;
	draw_gizmo = p_enabled;
	if (draw_gizmo) {
		_spawn_debug_overlay();
	} else {
		_despawn_debug_overlay();
	}
}

bool Tentacle::get_draw_gizmo() const { return draw_gizmo; }

void Tentacle::_spawn_debug_overlay() {
	if (debug_overlay != nullptr) return;
	const String path = "res://addons/tentacletech/scripts/debug/debug_gizmo_overlay.gd";
	ResourceLoader *rl = ResourceLoader::get_singleton();
	if (rl == nullptr || !rl->exists(path)) {
		return;
	}
	Ref<Script> script = rl->load(path);
	if (script.is_null()) {
		return;
	}
	Node3D *overlay = memnew(Node3D);
	overlay->set_script(script);
	overlay->set_name("DebugGizmoOverlay");
	overlay->set("tentacle", this);
	add_child(overlay, false, Node::INTERNAL_MODE_FRONT);
	debug_overlay = overlay;
}

void Tentacle::_despawn_debug_overlay() {
	if (debug_overlay == nullptr) return;
	remove_child(debug_overlay);
	debug_overlay->queue_free();
	debug_overlay = nullptr;
}

void Tentacle::_ensure_mesh_instance() {
	if (mesh_instance != nullptr) {
		return;
	}
	mesh_instance = memnew(MeshInstance3D);
	mesh_instance->set_name("TentacleMesh");
	// INTERNAL_MODE_FRONT keeps it out of the scene tree dock and out of the
	// .tscn file when @tool causes _ready() to fire at edit time.
	add_child(mesh_instance, false, Node::INTERNAL_MODE_FRONT);
}

void Tentacle::_refresh_mesh_instance() {
	if (mesh_instance == nullptr) {
		return;
	}
	mesh_instance->set_mesh(tentacle_mesh);
	if (shader_material.is_valid()) {
		mesh_instance->set_material_override(shader_material);
	}
}

void Tentacle::_refresh_shader_material_bindings() {
	if (shader_material.is_null()) {
		// Try to load the shared shader resource lazily — it may not exist
		// until sub-step A's shader files are deployed. Quietly skip if it
		// fails (renders as no-mesh + null material; data textures still
		// update in case external code wants to read them).
		ResourceLoader *rl = ResourceLoader::get_singleton();
		if (rl != nullptr && rl->exists(SHADER_RES_PATH)) {
			Ref<Shader> shader = rl->load(SHADER_RES_PATH);
			if (shader.is_valid()) {
				shader_material.instantiate();
				shader_material->set_shader(shader);
				if (mesh_instance != nullptr) {
					mesh_instance->set_material_override(shader_material);
				}
			}
		}
	}
	if (shader_material.is_null()) {
		return;
	}
	if (spline_data_texture.is_valid()) {
		shader_material->set_shader_parameter(UNIFORM_SPLINE_DATA, spline_data_texture);
	}
	shader_material->set_shader_parameter(UNIFORM_SPLINE_DATA_WIDTH, spline_data_width);
	if (rest_girth_texture.is_valid()) {
		shader_material->set_shader_parameter(UNIFORM_REST_GIRTH, rest_girth_texture);
	}
	shader_material->set_shader_parameter(UNIFORM_MESH_ARC_AXIS, mesh_arc_axis);
	shader_material->set_shader_parameter(UNIFORM_MESH_ARC_SIGN, (float)mesh_arc_sign);
	shader_material->set_shader_parameter(UNIFORM_MESH_ARC_OFFSET, mesh_arc_offset);
}

void Tentacle::_allocate_render_resources() {
	// Lay out the per-tick scratch buffers and the data texture sized for the
	// current chain. Called from _ready() and rebuild_chain(). After this,
	// _update_spline_data_texture() is alloc-free as long as particle_count
	// stays constant.

	if (render_spline.is_null()) {
		render_spline.instantiate();
	}

	// Pre-resize the local-space points buffer; an initial straight chain
	// gives the spline a valid first build for the placeholder data.
	if (spline_points_buffer.size() != particle_count) {
		spline_points_buffer.resize(particle_count);
	}
	for (int i = 0; i < particle_count; i++) {
		spline_points_buffer.set(i, Vector3(0.0f, 0.0f, -segment_length * (float)i));
	}
	render_spline->build_from_points(spline_points_buffer);

	// Resize per-channel buffers; channel layout is fixed by namespace
	// constants above.
	if (girth_channel_buffer.size() != particle_count) {
		girth_channel_buffer.resize(particle_count);
	}
	if (asym_x_channel_buffer.size() != particle_count) {
		asym_x_channel_buffer.resize(particle_count);
	}
	if (asym_y_channel_buffer.size() != particle_count) {
		asym_y_channel_buffer.resize(particle_count);
	}

	// Compute total packed float count and pre-resize the packed buffer.
	int segment_count = render_spline->get_segment_count();
	int dist_lut = render_spline->get_distance_lut_sample_count();
	int bn_lut = render_spline->get_binormal_lut_sample_count();
	int total = SplineDataPacker::compute_packed_size(
			segment_count, dist_lut, bn_lut, CHANNEL_COUNT, particle_count);
	if (spline_packed_buffer.size() != total) {
		spline_packed_buffer.resize(total);
	}

	// One RGBA32F pixel = 4 floats. Width = ceil(total / 4); height = 1.
	// Pad-zeroed so width * height * 4 ≥ total.
	int floats_per_pixel = 4;
	int pixels = (total + floats_per_pixel - 1) / floats_per_pixel;
	if (pixels < 1) pixels = 1;
	int padded_floats = pixels * floats_per_pixel;
	int padded_bytes = padded_floats * (int)sizeof(float);
	if (spline_byte_buffer.size() != padded_bytes) {
		spline_byte_buffer.resize(padded_bytes);
	}

	bool size_changed = (spline_data_width != pixels) || (spline_data_height != 1);
	spline_data_width = pixels;
	spline_data_height = 1;

	if (spline_data_image.is_null() || size_changed) {
		spline_data_image = Image::create_empty(spline_data_width, spline_data_height, false, Image::FORMAT_RGBAF);
	}
	if (spline_data_texture.is_null()) {
		spline_data_texture = ImageTexture::create_from_image(spline_data_image);
	} else if (size_changed) {
		// Texture must be resized: re-create from the new image.
		spline_data_texture->set_image(spline_data_image);
	}

	// Placeholder rest girth texture — uniform 1.0. Sub-step B replaces this
	// with the auto-bake output. Allocated once; we don't rebuild it on
	// chain rebuilds (the bake doesn't depend on particle_count).
	if (rest_girth_texture.is_null()) {
		PackedByteArray rg_bytes;
		rg_bytes.resize(REST_GIRTH_TEXTURE_WIDTH * (int)sizeof(float));
		float *rg_floats = (float *)rg_bytes.ptrw();
		for (int i = 0; i < REST_GIRTH_TEXTURE_WIDTH; i++) {
			rg_floats[i] = 1.0f;
		}
		Ref<Image> img = Image::create_from_data(REST_GIRTH_TEXTURE_WIDTH, 1, false, Image::FORMAT_RF, rg_bytes);
		rest_girth_texture = ImageTexture::create_from_image(img);
	}

	// Material binding may have been set up before resources existed; refresh.
	_refresh_shader_material_bindings();
}

void Tentacle::_update_spline_data_texture() {
	if (solver.is_null() || render_spline.is_null() || spline_data_image.is_null()) {
		return;
	}
	int n = solver->get_particle_count();
	if (n < 2 || spline_points_buffer.size() != n) {
		return;
	}

	// Pull world-space particle positions; transform into tentacle-local space
	// so the resulting spline sits in the same frame as the MeshInstance3D's
	// vertex shader. No allocation: we mutate the pre-resized buffer in place.
	Transform3D world_to_local = is_inside_tree() ? get_global_transform().affine_inverse() : Transform3D();
	for (int i = 0; i < n; i++) {
		Vector3 world_pos = solver->get_particle_position(i);
		spline_points_buffer.set(i, world_to_local.xform(world_pos));
	}
	render_spline->build_from_points(spline_points_buffer);

	// Per-particle channel data from the solver.
	for (int i = 0; i < n; i++) {
		girth_channel_buffer.set(i, solver->get_particle_girth_scale(i));
		Vector2 a = solver->get_particle_asymmetry(i);
		asym_x_channel_buffer.set(i, a.x);
		asym_y_channel_buffer.set(i, a.y);
	}

	// Pack into the pre-sized buffer. The Array allocation here is small (3
	// Variant entries) and falls under the Phase-2 1KB drift budget.
	Array channels;
	channels.push_back(girth_channel_buffer);
	channels.push_back(asym_x_channel_buffer);
	channels.push_back(asym_y_channel_buffer);
	SplineDataPacker::pack_into(render_spline, channels, spline_packed_buffer);

	// Copy floats → bytes into the pre-sized byte buffer. Pre-sized to the
	// texture's full pixel-aligned size; trailing bytes stay as previously
	// written (pad bytes are read by the shader only when sampling beyond
	// the meaningful data, which never happens in normal use).
	int total_floats = spline_packed_buffer.size();
	int byte_capacity = spline_byte_buffer.size();
	int copy_bytes = total_floats * (int)sizeof(float);
	if (copy_bytes > byte_capacity) {
		copy_bytes = byte_capacity;
	}
	const uint8_t *src = (const uint8_t *)spline_packed_buffer.ptr();
	uint8_t *dst = spline_byte_buffer.ptrw();
	for (int i = 0; i < copy_bytes; i++) {
		dst[i] = src[i];
	}

	// Replace the image's data and push to the texture. set_data() reuses the
	// Image instance (no Image realloc); ImageTexture::update() reuploads to
	// GPU without recreating the texture handle.
	spline_data_image->set_data(spline_data_width, spline_data_height, false,
			Image::FORMAT_RGBAF, spline_byte_buffer);
	spline_data_texture->update(spline_data_image);
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
	ClassDB::bind_method(D_METHOD("set_base_angular_velocity_limit", "omega"), &Tentacle::set_base_angular_velocity_limit);
	ClassDB::bind_method(D_METHOD("get_base_angular_velocity_limit"), &Tentacle::get_base_angular_velocity_limit);
	ClassDB::bind_method(D_METHOD("set_rigid_base_count", "count"), &Tentacle::set_rigid_base_count);
	ClassDB::bind_method(D_METHOD("get_rigid_base_count"), &Tentacle::get_rigid_base_count);
	ClassDB::bind_method(D_METHOD("set_draw_gizmo", "enabled"), &Tentacle::set_draw_gizmo);
	ClassDB::bind_method(D_METHOD("get_draw_gizmo"), &Tentacle::get_draw_gizmo);

	ClassDB::bind_method(D_METHOD("set_target", "world_pos"), &Tentacle::set_target);
	ClassDB::bind_method(D_METHOD("clear_target"), &Tentacle::clear_target);
	ClassDB::bind_method(D_METHOD("set_target_stiffness", "stiffness"), &Tentacle::set_target_stiffness);
	ClassDB::bind_method(D_METHOD("get_target_stiffness"), &Tentacle::get_target_stiffness);
	ClassDB::bind_method(D_METHOD("set_target_particle_index", "index"), &Tentacle::set_target_particle_index);
	ClassDB::bind_method(D_METHOD("get_target_particle_index"), &Tentacle::get_target_particle_index);

	ClassDB::bind_method(D_METHOD("set_pose_targets", "indices", "world_positions", "stiffnesses"), &Tentacle::set_pose_targets);
	ClassDB::bind_method(D_METHOD("clear_pose_targets"), &Tentacle::clear_pose_targets);
	ClassDB::bind_method(D_METHOD("get_pose_target_count"), &Tentacle::get_pose_target_count);

	ClassDB::bind_method(D_METHOD("set_anchor_transform", "xform"), &Tentacle::set_anchor_transform);
	ClassDB::bind_method(D_METHOD("clear_anchor_override"), &Tentacle::clear_anchor_override);

	ClassDB::bind_method(D_METHOD("get_solver"), &Tentacle::get_solver);

	ClassDB::bind_method(D_METHOD("get_particle_positions"), &Tentacle::get_particle_positions);
	ClassDB::bind_method(D_METHOD("get_particle_inv_masses"), &Tentacle::get_particle_inv_masses);
	ClassDB::bind_method(D_METHOD("get_segment_stretch_ratios"), &Tentacle::get_segment_stretch_ratios);
	ClassDB::bind_method(D_METHOD("get_target_pull_state"), &Tentacle::get_target_pull_state);
	ClassDB::bind_method(D_METHOD("get_anchor_state"), &Tentacle::get_anchor_state);

	ClassDB::bind_method(D_METHOD("set_environment_probe_enabled", "enabled"),
			&Tentacle::set_environment_probe_enabled);
	ClassDB::bind_method(D_METHOD("get_environment_probe_enabled"),
			&Tentacle::get_environment_probe_enabled);
	ClassDB::bind_method(D_METHOD("set_environment_probe_distance", "distance"),
			&Tentacle::set_environment_probe_distance);
	ClassDB::bind_method(D_METHOD("get_environment_probe_distance"),
			&Tentacle::get_environment_probe_distance);
	ClassDB::bind_method(D_METHOD("set_environment_collision_layer_mask", "mask"),
			&Tentacle::set_environment_collision_layer_mask);
	ClassDB::bind_method(D_METHOD("get_environment_collision_layer_mask"),
			&Tentacle::get_environment_collision_layer_mask);
	ClassDB::bind_method(D_METHOD("set_particle_collision_radius", "radius"),
			&Tentacle::set_particle_collision_radius);
	ClassDB::bind_method(D_METHOD("get_particle_collision_radius"),
			&Tentacle::get_particle_collision_radius);
	ClassDB::bind_method(D_METHOD("set_base_static_friction", "value"),
			&Tentacle::set_base_static_friction);
	ClassDB::bind_method(D_METHOD("get_base_static_friction"),
			&Tentacle::get_base_static_friction);
	ClassDB::bind_method(D_METHOD("set_tentacle_lubricity", "value"),
			&Tentacle::set_tentacle_lubricity);
	ClassDB::bind_method(D_METHOD("get_tentacle_lubricity"),
			&Tentacle::get_tentacle_lubricity);
	ClassDB::bind_method(D_METHOD("set_kinetic_friction_ratio", "value"),
			&Tentacle::set_kinetic_friction_ratio);
	ClassDB::bind_method(D_METHOD("get_kinetic_friction_ratio"),
			&Tentacle::get_kinetic_friction_ratio);
	ClassDB::bind_method(D_METHOD("set_contact_stiffness", "value"),
			&Tentacle::set_contact_stiffness);
	ClassDB::bind_method(D_METHOD("get_contact_stiffness"),
			&Tentacle::get_contact_stiffness);
	ClassDB::bind_method(D_METHOD("get_environment_contacts_snapshot"),
			&Tentacle::get_environment_contacts_snapshot);
	ClassDB::bind_method(D_METHOD("tick", "delta"), &Tentacle::tick);

	ClassDB::bind_method(D_METHOD("set_tentacle_mesh", "mesh"), &Tentacle::set_tentacle_mesh);
	ClassDB::bind_method(D_METHOD("get_tentacle_mesh"), &Tentacle::get_tentacle_mesh);
	ClassDB::bind_method(D_METHOD("_on_tentacle_mesh_changed"), &Tentacle::_on_tentacle_mesh_changed);
	ClassDB::bind_method(D_METHOD("set_shader_material", "material"), &Tentacle::set_shader_material);
	ClassDB::bind_method(D_METHOD("get_shader_material"), &Tentacle::get_shader_material);
	ClassDB::bind_method(D_METHOD("set_mesh_arc_axis", "axis"), &Tentacle::set_mesh_arc_axis);
	ClassDB::bind_method(D_METHOD("get_mesh_arc_axis"), &Tentacle::get_mesh_arc_axis);
	ClassDB::bind_method(D_METHOD("set_mesh_arc_sign", "sign"), &Tentacle::set_mesh_arc_sign);
	ClassDB::bind_method(D_METHOD("get_mesh_arc_sign"), &Tentacle::get_mesh_arc_sign);
	ClassDB::bind_method(D_METHOD("set_mesh_arc_offset", "offset"), &Tentacle::set_mesh_arc_offset);
	ClassDB::bind_method(D_METHOD("get_mesh_arc_offset"), &Tentacle::get_mesh_arc_offset);

	BIND_ENUM_CONSTANT(MESH_ARC_AXIS_X);
	BIND_ENUM_CONSTANT(MESH_ARC_AXIS_Y);
	BIND_ENUM_CONSTANT(MESH_ARC_AXIS_Z);
	ClassDB::bind_method(D_METHOD("get_spline_data_texture"), &Tentacle::get_spline_data_texture);
	ClassDB::bind_method(D_METHOD("get_spline_data_texture_width"), &Tentacle::get_spline_data_texture_width);
	ClassDB::bind_method(D_METHOD("get_spline_data_image"), &Tentacle::get_spline_data_image);
	ClassDB::bind_method(D_METHOD("get_rest_girth_texture"), &Tentacle::get_rest_girth_texture);
	ClassDB::bind_method(D_METHOD("set_rest_girth_texture", "tex"), &Tentacle::set_rest_girth_texture);
	ClassDB::bind_method(D_METHOD("get_spline_samples", "count"), &Tentacle::get_spline_samples);
	ClassDB::bind_method(D_METHOD("get_spline_frames", "count"), &Tentacle::get_spline_frames);
	ClassDB::bind_method(D_METHOD("update_render_data"), &Tentacle::update_render_data);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "particle_count", PROPERTY_HINT_RANGE, "2,48,1"),
			"set_particle_count", "get_particle_count");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "segment_length", PROPERTY_HINT_RANGE, "0.001,1.0,0.001,or_greater"),
			"set_segment_length", "get_segment_length");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "tentacle_mesh", PROPERTY_HINT_RESOURCE_TYPE, "Mesh"),
			"set_tentacle_mesh", "get_tentacle_mesh");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "shader_material", PROPERTY_HINT_RESOURCE_TYPE, "ShaderMaterial"),
			"set_shader_material", "get_shader_material");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mesh_arc_axis", PROPERTY_HINT_ENUM, "X,Y,Z"),
			"set_mesh_arc_axis", "get_mesh_arc_axis");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mesh_arc_sign", PROPERTY_HINT_ENUM, "Negative:-1,Positive:1"),
			"set_mesh_arc_sign", "get_mesh_arc_sign");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "mesh_arc_offset", PROPERTY_HINT_RANGE, "-10.0,10.0,0.001,or_lesser,or_greater"),
			"set_mesh_arc_offset", "get_mesh_arc_offset");

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
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "base_angular_velocity_limit", PROPERTY_HINT_RANGE, "0.0,20.0,0.01,or_greater"),
			"set_base_angular_velocity_limit", "get_base_angular_velocity_limit");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "rigid_base_count", PROPERTY_HINT_RANGE, "1,8,1,or_greater"),
			"set_rigid_base_count", "get_rigid_base_count");

	ADD_GROUP("Collision", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "environment_probe_enabled"),
			"set_environment_probe_enabled", "get_environment_probe_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "environment_probe_distance",
					 PROPERTY_HINT_RANGE, "0.01,20.0,0.01,or_greater"),
			"set_environment_probe_distance", "get_environment_probe_distance");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "environment_collision_layer_mask",
					 PROPERTY_HINT_LAYERS_3D_PHYSICS),
			"set_environment_collision_layer_mask", "get_environment_collision_layer_mask");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "particle_collision_radius",
					 PROPERTY_HINT_RANGE, "0.0,1.0,0.001,or_greater"),
			"set_particle_collision_radius", "get_particle_collision_radius");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "base_static_friction",
					 PROPERTY_HINT_RANGE, "0.0,4.0,0.01"),
			"set_base_static_friction", "get_base_static_friction");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "tentacle_lubricity",
					 PROPERTY_HINT_RANGE, "0.0,1.0,0.001"),
			"set_tentacle_lubricity", "get_tentacle_lubricity");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "kinetic_friction_ratio",
					 PROPERTY_HINT_RANGE, "0.0,1.0,0.001"),
			"set_kinetic_friction_ratio", "get_kinetic_friction_ratio");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "contact_stiffness",
					 PROPERTY_HINT_RANGE, "0.0,1.0,0.001"),
			"set_contact_stiffness", "get_contact_stiffness");

	ADD_GROUP("Debug", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "draw_gizmo"),
			"set_draw_gizmo", "get_draw_gizmo");
}
