#ifndef TENTACLETECH_TENTACLE_H
#define TENTACLETECH_TENTACLE_H

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include "../collision/environment_probe.h"
#include "../spline/catmull_spline.h"
#include "pbd_solver.h"

// Phase-2 Tentacle Node3D. Wraps a PBDSolver and drives it from
// _physics_process. Spec: docs/architecture/TentacleTech_Architecture.md §3,
// §15. Snapshot accessors per §15.2 forward to the solver and add the
// target/anchor state Dictionaries the debug overlay consumes.
//
// The base particle (index 0) is anchored to the node's global transform every
// physics tick before tick(); pinned via inv_mass = 0 inside the solver.
class Tentacle : public godot::Node3D {
	GDCLASS(Tentacle, godot::Node3D)

public:
	Tentacle();
	~Tentacle();

	void _ready() override;
	void _physics_process(double p_delta) override;
	void _notification(int p_what);

	// Configuration (re-initializes the chain when changed at runtime).
	void set_particle_count(int p_count);
	int get_particle_count() const;
	void set_segment_length(float p_length);
	float get_segment_length() const;

	// Re-create the chain with the current particle_count and segment_length.
	void rebuild_chain();

	// Solver tuning forwarded to PBDSolver — exposed on the node so the
	// inspector can edit them directly. Each setter snaps the underlying
	// solver state; no chain rebuild happens.
	void set_iteration_count(int p_iter);
	int get_iteration_count() const;
	void set_gravity(const godot::Vector3 &p_gravity);
	godot::Vector3 get_gravity() const;
	void set_damping(float p_damping);
	float get_damping() const;
	void set_distance_stiffness(float p_stiffness);
	float get_distance_stiffness() const;
	void set_bending_stiffness(float p_stiffness);
	float get_bending_stiffness() const;
	void set_asymmetry_recovery_rate(float p_rate);
	float get_asymmetry_recovery_rate() const;
	void set_base_angular_velocity_limit(float p_omega);
	float get_base_angular_velocity_limit() const;
	void set_rigid_base_count(int p_count);
	int get_rigid_base_count() const;

	// Target pull (soft, on the tip particle by default).
	void set_target(const godot::Vector3 &p_world_pos);
	void clear_target();
	void set_target_stiffness(float p_stiffness);
	float get_target_stiffness() const;
	void set_target_particle_index(int p_index);
	int get_target_particle_index() const;

	// Pose targets — distributed soft pull, one per indexed particle. Used
	// by behavior layer to write a full-body "muscular pose" each tick.
	// Three parallel arrays of equal length; behavior driver rebuilds them
	// per tick. Composes additively with the single tip target above.
	void set_pose_targets(const godot::PackedInt32Array &p_indices,
			const godot::PackedVector3Array &p_world_positions,
			const godot::PackedFloat32Array &p_stiffnesses);
	void clear_pose_targets();
	int get_pose_target_count() const;

	// Anchor — explicit override. By default, the tentacle anchors particle 0
	// to its own global_transform every physics tick. Calling
	// set_anchor_transform() with a fixed transform disables auto-tracking
	// until clear_anchor_override() is called.
	void set_anchor_transform(const godot::Transform3D &p_xform);
	void clear_anchor_override();

	// Direct solver access (so GDScript glue can tune iteration count, gravity,
	// etc., without re-binding every PBDSolver setter on Tentacle too).
	godot::Ref<PBDSolver> get_solver() const;

	// Slice 5C-A — external position-delta intake. Forwards to the solver's
	// Jacobi accumulator + apply pass so `Orifice` (or any other type-2 / 3
	// contact source) can push particles without snapping `prev_position` —
	// preserves the implicit Verlet velocity that `set_particle_position`
	// would zero. Calls are accumulated; `flush_external_position_deltas()`
	// averages and writes to position. Multiple deltas on the same particle
	// in one flush window compose by Jacobi average (Obi `AtomicDeltas`).
	void add_external_position_delta(int p_particle_index, const godot::Vector3 &p_delta);
	void flush_external_position_deltas();

	// Snapshot accessors per §15.2 ----------------------------------------

	godot::PackedVector3Array get_particle_positions() const;
	godot::PackedFloat32Array get_particle_inv_masses() const;
	godot::PackedFloat32Array get_segment_stretch_ratios() const;
	godot::Dictionary get_target_pull_state() const;
	godot::Dictionary get_anchor_state() const;

	// Phase-4 slice 4A — type-4 environment probe -------------------------
	//
	// Each tick (before the solver step) the Tentacle issues 3 raycasts in
	// the gravity direction from base / mid / tip particle positions and
	// hands the half-space contacts to the solver. These exports tune the
	// probe behavior; the snapshot accessor below feeds the gizmo overlay.

	void set_environment_probe_enabled(bool p_enabled);
	bool get_environment_probe_enabled() const;
	void set_environment_probe_distance(float p_distance);
	float get_environment_probe_distance() const;
	void set_environment_collision_layer_mask(int p_mask);
	int get_environment_collision_layer_mask() const;
	void set_particle_collision_radius(float p_radius);
	float get_particle_collision_radius() const;

	// Phase-4 slice 4B — §4.3 friction. `base_static_friction` is μ_s in the
	// "smooth tentacle vs dry skin" baseline of §4.4 (default 0.4); it is
	// modulated by `(1 - tentacle_lubricity)` before being handed to the
	// solver. `kinetic_friction_ratio` is μ_k / μ_s (default 0.8 per §4.3).
	// Surface tagging / per-contact composition lands in a later slice; for
	// now these are tentacle-global. Set lubricity to 1.0 to disable friction
	// entirely without touching the baseline coefficient.
	void set_base_static_friction(float p_value);
	float get_base_static_friction() const;
	void set_tentacle_lubricity(float p_value);
	float get_tentacle_lubricity() const;
	void set_kinetic_friction_ratio(float p_value);
	float get_kinetic_friction_ratio() const;
	// Slice 4C — distance-constraint stiffness during active contact (§4.3).
	// Default 0.5 lets the chain stretch over wrapped geometry instead of
	// fighting collision push-out, then snap back when contact ends.
	void set_contact_stiffness(float p_value);
	float get_contact_stiffness() const;
	// Slice 4M-pre.2 — multiplier on target-pull stiffness for in-contact
	// particles. Forwarded to the solver, where it applies uniformly to
	// both the singleton tip target and every distributed pose-target. The
	// behavior driver no longer needs to fetch the contact snapshot itself
	// to soften pose pulls — the solver handles it for both target paths,
	// so AI drivers writing tip targets via `set_target` get the same
	// correctness as drivers using pose targets.
	void set_target_softness_when_blocked(float p_value);
	float get_target_softness_when_blocked() const;
	// Slice 4M — Jacobi successive-over-relaxation factor for the
	// position-delta accumulator. 1.0 = strict average (Obi default for
	// parallel mode); higher values converge faster but can overshoot.
	// Forwarded to the solver.
	void set_sor_factor(float p_value);
	float get_sor_factor() const;
	// Slice 4M / 4P — depenetration velocity cap (m/s) for collision
	// projection. Higher values eject deeply-penetrated particles faster
	// but at greater visual snap.
	void set_max_depenetration(float p_value);
	float get_max_depenetration() const;
	// Slice 4P — sleep threshold (m/s). In-contact particles whose tick-rate
	// velocity falls below this threshold are snapped back to prev_position
	// at end of finalize(), killing residual jitter from un-converged
	// constraints. Default 0 = disabled. Recommended ~0.005 m/s for moods
	// that hang at rest; "active" moods leave it at 0 so legitimate slow
	// drift survives. Forwarded to the solver.
	void set_sleep_threshold(float p_value);
	float get_sleep_threshold() const;
	// Slice 4O — sub-step count floor. Every outer physics tick runs at
	// least this many substeps; on top, a displacement-driven heuristic
	// can bump the count higher when a singleton tip target would otherwise
	// drag a particle further than `0.5 × collision_radius` in one step
	// (the canonical "thrust frame tunneling" failure mode). Default 1
	// for backward compatibility with shipping moods; thrust-heavy moods
	// should set 2-4. Hard-capped at MAX_SUBSTEPS (4) to bound the cost.
	void set_substep_count(int p_count);
	int get_substep_count() const;
	// Read back the most recent outer tick's resolved sub-step count
	// (after both the floor and the displacement heuristic have been
	// applied). Useful for the gizmo overlay (color particles by sub-step
	// count to find scenes paying for sub-stepping unnecessarily) and for
	// the test suite to validate the heuristic actually fires.
	int get_last_substep_count() const;
	static constexpr int MAX_SUBSTEPS = 4;
	// Slice 4I — implicit-velocity damping for in-contact particles. 0.5
	// (default) halves the per-tick implicit velocity for any particle
	// flagged in_contact_this_tick at end-of-tick, which kills tick-rate
	// oscillation born of constraint conflict during contact (the iter
	// loop can't always converge when bending / pose / distance pull
	// inward and collision pushes out — each iter accumulates net drift).
	// Free particles unaffected; legitimate sliding (high tick-to-tick
	// velocity) decays slowly compared to sub-millimeter oscillation.
	// 0 = disabled, 1 = fully kill velocity for in-contact particles.
	void set_contact_velocity_damping(float p_value);
	float get_contact_velocity_damping() const;
	// Slice 4K — gravity supported by contact. Default true: in-contact
	// particles get only the contact-tangent component of gravity per tick
	// (the contact supports the normal component, like a brick on a floor
	// doesn't sink). Eliminates the per-tick "gravity-sinks-particle / iter-
	// pushes-out" cycle that seeded the iter-amplification jitter the
	// user saw in wedged configurations.
	void set_support_in_contact(bool p_value);
	bool get_support_in_contact() const;
	// Slice 4F — global multiplier on the type-1 friction reciprocal impulse
	// applied to dynamic bodies (RigidBody3D / PhysicalBone3D / etc.) via
	// PhysicsServer3D.body_apply_impulse. PBD friction in the kinetic regime
	// (fast tangential motion) cancels nearly the full per-particle motion
	// regardless of μ, which translates to a per-particle impulse roughly
	// equal to the particle's tangential momentum per tick — multiply by N
	// particles in contact and small bones (toes, fingers) get yeeted. The
	// default 0.1 makes the chain feel ~10× gentler on ragdolls; user can
	// dial up toward 1.0 for kinematic-feeling impact, or to 0.0 to fully
	// decouple the chain from dynamic-body reactions while keeping the
	// chain itself responsive to contact. Real fix is a physics-correct
	// `μ_k × N × dt` impulse cap; this scale knob is the pragmatic stopgap.
	void set_body_impulse_scale(float p_value);
	float get_body_impulse_scale() const;

	// Snapshot accessor (§15.2): returns one Dictionary per ray with keys
	// ray_origin, ray_direction, hit (bool), hit_point, hit_normal,
	// hit_object_id (int). Stale rays from the last tick are returned as
	// hit=false with whatever origin/direction they were last cast in. The
	// gizmo overlay reads this every frame.
	godot::Array get_environment_contacts_snapshot() const;

	// Slice 4N — this-tick-fresh per-particle contact flags. Written by
	// `_run_environment_probe()` after the probe runs and *before*
	// `solver->tick()` iterates, so the snapshot reflects the contact
	// manifold the iterate loop is about to see, not the previous tick's
	// result.
	//
	// Returns one byte per particle: 1 if the probe found any contact this
	// tick, 0 if the particle is free. PackedByteArray rather than bool[]
	// so it crosses the GDScript boundary without a per-element Variant box.
	//
	// Process-order requirement: behaviour drivers consuming this snapshot
	// must run their `_physics_process` *after* the Tentacle's. Godot's
	// default parent-first ordering gives this for free when the driver is
	// a child of the Tentacle (the bundled scenes already do this). If a
	// project ever inverts the order (driver above the tentacle in the
	// tree), the snapshot reads the previous tick's flags — same as the
	// solver-side `get_particle_in_contact_snapshot()`, no regression.
	godot::PackedByteArray get_in_contact_this_tick_snapshot() const;

	// Phase 3 — render plumbing -------------------------------------------
	//
	// Tentacle owns one MeshInstance3D child (created internally) and one
	// unique ShaderMaterial; the .gdshader is shared across instances.
	// The data textures below are allocated once per chain rebuild and
	// updated in place each physics tick (no per-frame allocation).

	enum MeshArcAxis {
		MESH_ARC_AXIS_X = 0,
		MESH_ARC_AXIS_Y = 1,
		MESH_ARC_AXIS_Z = 2, // §10.1 default
	};

	// `tentacle_mesh` accepts any Mesh subclass. When the assigned mesh is a
	// `TentacleMesh` (GDScript ArrayMesh subclass, §10.2), we duck-type-
	// detect the bake hooks (`get_baked_girth_texture`) and auto-pipe the
	// rest-girth texture into the shader uniform. For stock primitives the
	// 3a placeholder stays in place (or whatever the user explicitly set).
	void set_tentacle_mesh(const godot::Ref<godot::Mesh> &p_mesh);
	godot::Ref<godot::Mesh> get_tentacle_mesh() const;

	// Selects which mesh-local axis is the arc-length axis. §10.1 specifies
	// +Z; Godot's CylinderMesh is +Y-aligned and centered, so users wiring
	// up a stock CylinderMesh should set this to MESH_ARC_AXIS_Y and
	// mesh_arc_offset = height/2.
	void set_mesh_arc_axis(int p_axis);
	int get_mesh_arc_axis() const;

	// Sign multiplier on the chosen axis. -1 maps a mesh whose tip is at
	// negative-axis (TentacleMesh's intrinsic_axis_sign=-1 default per §10.1)
	// onto the shader's positive arc convention. The duck-type integration
	// auto-sets this from TentacleMesh; for stock primitives leave at +1.
	void set_mesh_arc_sign(int p_sign);
	int get_mesh_arc_sign() const;

	// Additive offset applied after sign multiplication. Use to convert a
	// centered mesh (e.g. Godot CylinderMesh, axis ∈ [-h/2, h/2]) to the
	// base-at-zero convention the shader expects (arc ∈ [0, h]).
	void set_mesh_arc_offset(float p_offset);
	float get_mesh_arc_offset() const;

	// Per-instance ShaderMaterial; null until _ready() if no shader resource
	// is loadable from disk. Sub-step B's procedural generator can also
	// create one and assign it via set_shader_material().
	godot::Ref<godot::ShaderMaterial> get_shader_material() const;
	void set_shader_material(const godot::Ref<godot::ShaderMaterial> &p_mat);

	// Spline data texture: RGBA32F, packed per §5.2 + SplineDataPacker layout.
	// Updated in place each physics tick via Image::set_data + ImageTexture::update.
	godot::Ref<godot::ImageTexture> get_spline_data_texture() const;
	int get_spline_data_texture_width() const;
	// Direct access to the source Image used to upload texture data.
	// Headless tests use this — ImageTexture::get_image() routes through the
	// renderer, which is a stub under --headless and returns dummy bytes.
	godot::Ref<godot::Image> get_spline_data_image() const;

	// Rest girth profile texture: RF (single-channel float). Phase 3a ships
	// a uniform 1.0 placeholder; the §5.4 GirthBaker output replaces it via
	// set_rest_girth_texture(). Setting null reverts to the placeholder.
	godot::Ref<godot::ImageTexture> get_rest_girth_texture() const;
	void set_rest_girth_texture(const godot::Ref<godot::ImageTexture> &p_tex);

	// Editor-gizmo accessors (§15.5). Both return data in *tentacle-local*
	// space (matching the spline data texture); gizmos are drawn relative to
	// the node's transform, so local space is what they want.
	godot::PackedVector3Array get_spline_samples(int p_count) const;
	// Each Dictionary has { position, tangent, normal, binormal } as Vector3.
	godot::Array get_spline_frames(int p_count) const;

	// Debug gizmo toggle — spawns an internal `TentacleDebugOverlay` child
	// that draws particle crosses, segment stretch, bending arcs, anchor,
	// and target-pull on top of the mesh (no_depth_test + max render
	// priority). Works in editor and at runtime. Setting false destroys
	// the overlay.
	void set_draw_gizmo(bool p_enabled);
	bool get_draw_gizmo() const;

	// Repacks the spline data texture from current solver state. Normally
	// invoked from _physics_process; exposed publicly so tests and editor
	// preview hooks can drive the update path without forcing a chain
	// rebuild. Alloc-free after the first call (per CLAUDE.md non-negotiables).
	void update_render_data();

	// Public per-tick driver — runs the full pipeline: anchor refresh (unless
	// override), environment probe, solver tick, render data update. The
	// engine calls this from `_physics_process`; headless tests call it
	// directly to exercise the same path with a deterministic step.
	void tick(float p_delta);

protected:
	static void _bind_methods();

private:
	godot::Ref<PBDSolver> solver;
	int particle_count = PBDSolver::DEFAULT_PARTICLE_COUNT;
	float segment_length = 0.1f;

	// When false, _physics_process refreshes the anchor to the node's global
	// transform each tick. When true, the user has set a fixed anchor and we
	// don't overwrite it.
	bool anchor_override = false;

	// Phase 3 render state ------------------------------------------------

	godot::Ref<godot::Mesh> tentacle_mesh;
	godot::MeshInstance3D *mesh_instance = nullptr; // internal child
	godot::Ref<godot::ShaderMaterial> shader_material;
	int mesh_arc_axis = MESH_ARC_AXIS_Z;
	int mesh_arc_sign = 1;
	float mesh_arc_offset = 0.0f;

	// Spline-driven render data. The CatmullSpline is rebuilt each tick from
	// the current particle positions in tentacle-local space; the resulting
	// segment weights, distance LUT, binormal LUT, and per-particle channels
	// are packed into spline_packed_buffer, then uploaded to spline_data_image
	// and propagated to spline_data_texture.
	godot::Ref<CatmullSpline> render_spline;
	godot::Ref<godot::Image> spline_data_image;
	godot::Ref<godot::ImageTexture> spline_data_texture;
	int spline_data_width = 0; // RGBA32F pixels (= ceil(packed/4))
	int spline_data_height = 1;

	godot::PackedVector3Array spline_points_buffer; // local-space copy of particles
	godot::PackedFloat32Array spline_packed_buffer;
	godot::PackedByteArray spline_byte_buffer;
	godot::PackedFloat32Array girth_channel_buffer;
	godot::PackedFloat32Array asym_x_channel_buffer;
	godot::PackedFloat32Array asym_y_channel_buffer;

	godot::Ref<godot::ImageTexture> rest_girth_texture;

	// Debug gizmo overlay — auto-spawned as an internal child when
	// draw_gizmo is true. Loads
	// `res://addons/tentacletech/scripts/debug/debug_gizmo_overlay.gd` via
	// ResourceLoader and assigns `tentacle = this`. Internal-mode keeps it
	// out of the .tscn file.
	bool draw_gizmo = false;
	godot::Node3D *debug_overlay = nullptr;

	// Type-4 environment probe state. The probe owns its reusable
	// PhysicsRayQueryParameters3D and a small fixed-size contact buffer; the
	// PackedVector3Array members below are scratch buffers handed to the
	// solver each tick to avoid allocating during _physics_process.
	tentacletech::EnvironmentProbe environment_probe;
	bool environment_probe_enabled = true;
	float environment_probe_distance = 1.0f;
	int environment_collision_layer_mask = 0xFFFFFFFF;
	float particle_collision_radius = 0.05f;
	float base_static_friction = 0.4f;
	float tentacle_lubricity = 0.0f;
	float kinetic_friction_ratio = 0.8f;
	float contact_stiffness = 0.5f;
	float target_softness_when_blocked = 0.3f;
	float sor_factor = PBDSolver::DEFAULT_SOR_FACTOR;
	float max_depenetration = PBDSolver::DEFAULT_MAX_DEPENETRATION;
	float sleep_threshold = 0.0f;
	float contact_velocity_damping = 0.5f;
	bool support_in_contact = true;
	float body_impulse_scale = 1.0f;
	int substep_count = 1;
	int last_substep_count = 1;
	godot::PackedVector3Array env_position_scratch;
	godot::PackedFloat32Array env_girth_scratch;
	// Slice 4M: per-slot scratch buffers handed to PBDSolver. The point and
	// normal arrays are sized to particle_count × MAX_CONTACTS_PER_PARTICLE;
	// the count array is one byte per particle (0..MAX_CONTACTS_PER_PARTICLE).
	// Reallocated only when the chain length changes.
	godot::PackedVector3Array env_contact_points_scratch;
	godot::PackedVector3Array env_contact_normals_scratch;
	godot::PackedByteArray env_contact_count_scratch;

	// Slice 4N — fresh-this-tick contact flags. Written by
	// `_run_environment_probe()` from `contact_count > 0` *before* the solver
	// iterates, so behaviour drivers consuming
	// `Tentacle::get_in_contact_this_tick_snapshot()` see this tick's contact
	// state instead of the previous tick's iterate-loop result. One byte per
	// particle: 1 if any contact was found, 0 if free. Falls back to
	// last-tick semantics if a project inverts the parent-child process
	// order (driver runs before its tentacle); same as the solver-side
	// snapshot in that case.
	godot::PackedByteArray _in_contact_this_tick_snapshot;

	void _run_environment_probe();
	// Slice 4E — apply equal-and-opposite friction impulses to dynamic
	// bodies the chain contacted this tick (§4.3 type-1 reciprocal). Run
	// after solver->tick() so friction_applied is final.
	void _apply_collision_reciprocals(float p_delta);

	void _allocate_render_resources();
	void _ensure_mesh_instance();
	void _spawn_debug_overlay();
	void _despawn_debug_overlay();
	void _refresh_mesh_instance();
	void _refresh_shader_material_bindings();
	void _update_spline_data_texture();
	// Used by the TentacleMesh duck-type integration (§10.2).
	void _pull_baked_girth_from_mesh();
	// If the assigned mesh exposes a `length` property (TentacleMesh does;
	// stock primitives don't), set segment_length so the chain spans exactly
	// that length when straight: segment_length = mesh.length / (n - 1).
	// No-op for meshes without a `length` property — segment_length stays
	// user-driven in that case.
	void _apply_mesh_length_to_segment_length();
	void _on_tentacle_mesh_changed();
};

VARIANT_ENUM_CAST(Tentacle::MeshArcAxis);

#endif // TENTACLETECH_TENTACLE_H
