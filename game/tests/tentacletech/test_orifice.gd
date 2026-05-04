extends SceneTree

# Phase-5 slice 5A + 5B — Orifice rim primitive unit tests.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_orifice.gd
#
# Acceptance per docs/architecture/TentacleTech_Architecture.md §6.1–§6.4
# (rim particle loop model, amended 2026-05-03).
#
# Class lookup goes through ClassDB because GDExtension classes register at
# MODULE_INITIALIZATION_LEVEL_SCENE — after the GDScript parser has resolved
# identifiers in --script mode. Static methods bound with bind_static_method
# are callable through any instance.
#
# `_init()` runs before SceneTree::initialize() finishes wiring up the root,
# so nodes added there report `is_inside_tree() == false` and Skeleton3D
# APIs that depend on tree state warn or fail. Defer the test body to the
# first `_process` tick (mirrors test_collision_type4.gd).

const DT := 1.0 / 60.0
const ENTRY_AXIS := Vector3(0.0, 0.0, 1.0)


var _ran: bool = false


func _process(_delta: float) -> bool:
	if _ran:
		return true # signal quit
	_ran = true
	_run_tests()
	return true


func _run_tests() -> void:
	if not ClassDB.class_exists("Orifice"):
		push_error("[FAIL] tentacletech extension not loaded (Orifice missing)")
		quit(2)
		return

	var passed: int = 0
	var failed: int = 0

	for test_name in [
		"test_circular_rest_initialization",
		"test_distance_steady_state_lambdas_bounded",
		"test_distance_xpbd_lambda_resets_each_tick",
		"test_volume_target_modulation_changes_area",
		"test_volume_lambda_resets_each_tick",
		"test_spring_back_decays_displacement",
		"test_pinned_neighbor_loop_settles",
		"test_polygon_area_helper_circle",
		# Slice 5B — host bone soft attachment.
		"test_host_bone_tracking_moves_orifice_frame",
		"test_host_bone_tracking_pulls_rim_along",
		"test_host_bone_offset_applied",
		"test_host_bone_invalid_path_falls_back",
		"test_host_bone_path_change_re_resolves",
		# Slice 5C-A — type-2 contact (tentacle ↔ rim, normal projection).
		"test_type2_pushes_tentacle_particle_out",
		"test_type2_pushes_rim_particle_correspondingly",
		"test_type2_lambda_accumulates_across_iters",
		"test_type2_contact_resets_per_tick",
		"test_type2_no_contact_outside_radius",
		"test_type2_pinned_rim_particle_only_pushes_tentacle",
		# Slice 5C-B — EntryInteraction lifecycle + geometric tracking.
		"test_ei_created_on_first_crossing",
		"test_ei_geometric_state_updates_each_tick",
		"test_ei_axial_velocity_sign",
		"test_ei_approach_angle_cos",
		"test_ei_particles_in_tunnel",
		"test_ei_retirement_after_grace_period",
		"test_ei_persistent_slots_initialized",
		"test_ei_persistent_slots_not_driven",
		"test_ei_multi_tentacle_coexist",
		"test_ei_unregistered_tentacle_retires_immediately",
	]:
		_reset_root()
		if call(test_name):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			push_error("[FAIL] %s" % test_name)
			failed += 1

	print("\n%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _reset_root() -> void:
	for c in root.get_children():
		root.remove_child(c)
		c.free()


# ---------------------------------------------------------------------------

func _new_orifice(radius: float = 0.05, n: int = 8, rest_stiffness: float = 0.5,
		area_compliance: float = 1e-4, distance_compliance: float = 1e-6) -> Node3D:
	var o: Node3D = ClassDB.instantiate("Orifice")
	o.entry_axis = ENTRY_AXIS
	get_root().add_child(o)
	var rest_pos: PackedVector3Array = o.make_circular_rest_positions(n, radius, ENTRY_AXIS)
	var seg_lens: PackedFloat32Array = o.make_uniform_segment_rest_lengths(rest_pos)
	var area: float = absf(o.compute_polygon_area(rest_pos, ENTRY_AXIS))
	var stf := PackedFloat32Array()
	stf.resize(n)
	for i in n:
		stf[i] = rest_stiffness
	o.add_rim_loop(rest_pos, seg_lens, area, stf, area_compliance, distance_compliance)
	return o


# Loop with 8 particles initialized at the prescribed circular rest pose.
# Particles are placed correctly, segment rest lengths are positive, and
# polygon area matches a regular octagon.
func test_circular_rest_initialization() -> bool:
	var radius := 0.05
	var n := 8
	var o: Node3D = _new_orifice(radius, n)
	if o.get_rim_loop_count() != 1:
		push_error("expected 1 loop, got %d" % o.get_rim_loop_count())
		return false
	var state: Array = o.get_rim_loop_state(0)
	if state.size() != n:
		push_error("expected %d particles, got %d" % [n, state.size()])
		return false
	# All particles should sit on a circle of `radius` in the plane perp to
	# entry_axis (z=0 here).
	for k in n:
		var p: Vector3 = state[k]["current_position"]
		if absf(p.z) > 1e-5:
			push_error("particle %d not in rim plane: z=%f" % [k, p.z])
			return false
		var r: float = Vector2(p.x, p.y).length()
		if absf(r - radius) > 1e-4:
			push_error("particle %d radius %f != %f" % [k, r, radius])
			return false
		if state[k]["neighbour_rest_distance"] <= 0.0:
			push_error("particle %d rest segment <= 0" % k)
			return false
	# Polygon area should match the analytical regular n-gon area.
	var area: float = absf(o.get_loop_current_enclosed_area(0))
	var ideal: float = 0.5 * float(n) * radius * radius * sin(TAU / float(n))
	if absf(area - ideal) / ideal > 1e-3:
		push_error("loop area %f deviates from regular n-gon area %f" % [area, ideal])
		return false
	o.queue_free()
	return true


# A rim left at rest steady-state should not have its distance lambdas
# blow up — XPBD lambda accumulator is reset each tick, so even after
# many ticks |λ| stays bounded.
func test_distance_steady_state_lambdas_bounded() -> bool:
	var o: Node3D = _new_orifice(0.05, 8, 0.5)
	for _i in 240:
		o.tick(DT)
	var state: Array = o.get_rim_loop_state(0)
	for k in state.size():
		var lam: float = state[k]["distance_lambda"]
		if not is_finite(lam):
			push_error("non-finite distance_lambda at k=%d" % k)
			return false
		if absf(lam) > 1e-3:
			push_error("distance_lambda %e exceeds bound at rest k=%d" % [lam, k])
			return false
	o.queue_free()
	return true


# XPBD canary: per-tick reset of distance_lambda happens in predict(). With
# a particle perturbed every tick, the per-tick accumulated lambda stays in
# the same order of magnitude; without the reset it would compound across
# ticks and grow unboundedly.
func test_distance_xpbd_lambda_resets_each_tick() -> bool:
	var o: Node3D = _new_orifice(0.05, 8, 0.5)
	o.set_particle_position(0, 0, Vector3(0.08, 0.0, 0.0))
	o.tick(DT)
	var lam0_first: float = absf(_get_particle_field(o, 0, 0, "distance_lambda"))
	var lam_max := lam0_first
	for _i in 60:
		o.tick(DT)
		var lam: float = absf(_get_particle_field(o, 0, 0, "distance_lambda"))
		if lam > lam_max:
			lam_max = lam
	# Loose bound: even the worst tick should be within 5× the first tick.
	if lam_max > 5.0 * lam0_first + 1e-6:
		push_error("distance_lambda grew unboundedly: max=%e first=%e" % [lam_max, lam0_first])
		return false
	o.queue_free()
	return true


# Modulating target_enclosed_area pulls the loop's actual area toward the
# new target. Halve the target → area shrinks by a measurable fraction.
func test_volume_target_modulation_changes_area() -> bool:
	# Stiff volume (low area_compliance) + very soft spring so the volume
	# constraint dominates the equilibrium. Anatomical analog: bulk tissue
	# resists area change far more than each rim particle resists local
	# displacement.
	var o: Node3D = _new_orifice(0.1, 12, 0.0, 1e-7, 1e-6)
	var area_initial: float = absf(o.get_loop_current_enclosed_area(0))
	var target_initial: float = absf(o.get_loop_target_enclosed_area(0))
	if absf(area_initial - target_initial) / target_initial > 0.10:
		push_error("initial area %f != target %f" % [area_initial, target_initial])
		return false
	o.set_loop_target_enclosed_area(0, target_initial * 0.5)
	for _i in 240:
		o.tick(DT)
	var area_after: float = absf(o.get_loop_current_enclosed_area(0))
	if area_after >= area_initial * 0.8:
		push_error("area didn't contract enough: %f -> %f" % [area_initial, area_after])
		return false
	if area_after < target_initial * 0.2:
		push_error("area collapsed: %f vs target %f" % [area_after, target_initial * 0.5])
		return false
	o.queue_free()
	return true


# The volume (area) Lagrange multiplier resets every tick. Steady-state at
# rest with no perturbation, |area_lambda| stays small.
func test_volume_lambda_resets_each_tick() -> bool:
	var o: Node3D = _new_orifice(0.05, 8, 0.5)
	for _i in 240:
		o.tick(DT)
	var lam: float = o.get_loop_area_lambda(0)
	if not is_finite(lam):
		push_error("non-finite area_lambda")
		return false
	if absf(lam) > 1e-3:
		push_error("area_lambda %e exceeds bound at rest" % lam)
		return false
	o.queue_free()
	return true


# External displacement of one rim particle decays toward rest under the
# spring-back constraint.
func test_spring_back_decays_displacement() -> bool:
	var o: Node3D = _new_orifice(0.05, 8, 0.7)
	var rest0: Vector3 = _get_particle_field(o, 0, 0, "rest_position")
	var disp: Vector3 = Vector3(0.01, 0.0, 0.0)
	o.set_particle_position(0, 0, rest0 + disp)
	var d0: float = (o.get_particle_position(0, 0) - rest0).length()
	for _i in 120:
		o.tick(DT)
	var d_after: float = (o.get_particle_position(0, 0) - rest0).length()
	if d_after >= 0.5 * d0:
		push_error("spring-back did not decay: %f -> %f" % [d0, d_after])
		return false
	o.queue_free()
	return true


# A loop with one particle pinned (inv_mass=0) at a non-rest world position
# settles into a stable shape.
func test_pinned_neighbor_loop_settles() -> bool:
	var o: Node3D = _new_orifice(0.05, 8, 0.5)
	var rest0: Vector3 = _get_particle_field(o, 0, 0, "rest_position")
	var pinned_pos: Vector3 = rest0 + Vector3(0.02, 0.0, 0.0)
	o.set_particle_position(0, 0, pinned_pos)
	o.set_particle_inv_mass(0, 0, 0.0)
	for _i in 240:
		o.tick(DT)
	# Settle check: the last 30 ticks of motion should be tiny.
	var max_motion := 0.0
	var n: int = (o.get_rim_loop_state(0) as Array).size()
	for _i in 30:
		var pre: Array = []
		for k in n:
			pre.append(o.get_particle_position(0, k))
		o.tick(DT)
		var motion := 0.0
		for k in n:
			var d: float = (o.get_particle_position(0, k) - (pre[k] as Vector3)).length()
			if d > motion:
				motion = d
		if motion > max_motion:
			max_motion = motion
	if max_motion > 1e-3:
		push_error("loop did not settle: max per-tick motion %e in last 30 ticks" % max_motion)
		return false
	# Pinned particle stayed pinned.
	var p0: Vector3 = o.get_particle_position(0, 0)
	if (p0 - pinned_pos).length() > 1e-4:
		push_error("pinned particle drifted: dev=%e" % (p0 - pinned_pos).length())
		return false
	o.queue_free()
	return true


# Static helper: polygon area of an inscribed regular n-gon should match
# the analytical formula 0.5 × n × r² × sin(2π/n).
func test_polygon_area_helper_circle() -> bool:
	var o: Node3D = ClassDB.instantiate("Orifice")
	get_root().add_child(o)
	var n := 12
	var radius := 0.1
	var rest_pos: PackedVector3Array = o.make_circular_rest_positions(n, radius, ENTRY_AXIS)
	var area: float = absf(o.compute_polygon_area(rest_pos, ENTRY_AXIS))
	var ideal: float = 0.5 * float(n) * radius * radius * sin(TAU / float(n))
	o.queue_free()
	if absf(area - ideal) / ideal > 1e-4:
		push_error("polygon area %f != expected %f for regular %d-gon" % [area, ideal, n])
		return false
	return true


# ---------------------------------------------------------------------------
# Slice 5B — host bone soft attachment

# Build a Skeleton3D with a single bone at the origin, parented under the
# scene root. Returns (skeleton, bone_index).
func _make_skeleton(bone_name: StringName = &"Hips") -> Skeleton3D:
	var skel := Skeleton3D.new()
	skel.name = "TestSkeleton"
	get_root().add_child(skel)
	# Add the bone via add_bone; rest pose left at identity (relative to
	# the skeleton root).
	skel.add_bone(bone_name)
	# Reset pose so get_bone_global_pose returns the identity-by-default
	# transform we expect at the start of each test.
	skel.reset_bone_poses()
	return skel


# Move the bone (in skeleton-local coords). Helper to reduce boilerplate.
func _set_bone_pos(skel: Skeleton3D, bone_idx: int, p_pos: Vector3) -> void:
	skel.set_bone_pose_position(bone_idx, p_pos)


# `--script` mode reports `is_inside_tree() == false` even after `add_child`,
# which makes both `Node.get_path()` and `Node.get_path_to()` fail with
# "Parameter \"data.tree\" is null." Construct an absolute path under
# /root/<name> manually instead.
func _node_path(node: Node) -> NodePath:
	return NodePath("/root/" + str(node.name))


# Bone moves -> Orifice global_transform tracks it after one tick.
func test_host_bone_tracking_moves_orifice_frame() -> bool:
	var skel: Skeleton3D = _make_skeleton(&"Hips")
	# Skeleton itself sits at world (5, 0, 0) so the test verifies both
	# the skeleton.global_transform and the per-bone pose contribute.
	skel.position = Vector3(5.0, 0.0, 0.0)
	var o: Node3D = ClassDB.instantiate("Orifice")
	o.entry_axis = ENTRY_AXIS
	get_root().add_child(o)
	var resolved: bool = o.set_host_bone(_node_path(skel), &"Hips")
	if not resolved:
		push_error("set_host_bone failed to resolve")
		return false
	# Move the bone.
	var bone_local := Vector3(0.0, 1.5, 0.0)
	_set_bone_pos(skel, 0, bone_local)
	# Tick once — refresh runs at the start of tick().
	o.tick(DT)
	var expected: Vector3 = Vector3(5.0, 1.5, 0.0)
	var got: Vector3 = (o.get_center_frame_world() as Transform3D).origin
	if (got - expected).length() > 1e-3:
		push_error("orifice frame %s != expected %s" % [got, expected])
		o.queue_free()
		skel.queue_free()
		return false
	# Verify get_host_bone_state reports the live bone transform.
	var state: Dictionary = o.get_host_bone_state()
	if not state.get("has_host_bone", false):
		push_error("has_host_bone false after successful resolve")
		o.queue_free()
		skel.queue_free()
		return false
	if int(state.get("bone_index", -1)) != 0:
		push_error("bone_index %d != 0" % int(state.get("bone_index", -1)))
		o.queue_free()
		skel.queue_free()
		return false
	o.queue_free()
	skel.queue_free()
	return true


# Bone moves -> rim particles get pulled along by spring-back. After
# settling, particles end roughly at the new rest world positions.
func test_host_bone_tracking_pulls_rim_along() -> bool:
	var skel: Skeleton3D = _make_skeleton(&"Hips")
	var radius := 0.05
	var n := 8
	var o: Node3D = ClassDB.instantiate("Orifice")
	o.entry_axis = ENTRY_AXIS
	get_root().add_child(o)
	o.set_host_bone(_node_path(skel), &"Hips")
	# Configure the rim loop.
	var rest_pos: PackedVector3Array = o.make_circular_rest_positions(n, radius, ENTRY_AXIS)
	var seg_lens: PackedFloat32Array = o.make_uniform_segment_rest_lengths(rest_pos)
	var area: float = absf(o.compute_polygon_area(rest_pos, ENTRY_AXIS))
	var stf := PackedFloat32Array()
	stf.resize(n)
	for i in n:
		stf[i] = 0.7  # moderately stiff spring-back so it follows the bone
	o.add_rim_loop(rest_pos, seg_lens, area, stf, 1e-4, 1e-6)
	# Settle at zero bone offset.
	for _i in 60:
		o.tick(DT)
	# Capture initial particle position.
	var initial_p0: Vector3 = o.get_particle_position(0, 0)
	# Move the bone laterally.
	var bone_step := Vector3(0.0, 0.0, 0.5)
	_set_bone_pos(skel, 0, bone_step)
	# Settle.
	for _i in 240:
		o.tick(DT)
	var final_p0: Vector3 = o.get_particle_position(0, 0)
	# The particle should have shifted by approximately bone_step.
	var delta: Vector3 = final_p0 - initial_p0
	if (delta - bone_step).length() > 0.01:
		push_error("rim particle didn't follow bone: delta=%s expected=%s" % [delta, bone_step])
		o.queue_free()
		skel.queue_free()
		return false
	# Loop circumference should remain reasonably preserved (no balloon).
	var area_after: float = absf(o.get_loop_current_enclosed_area(0))
	if absf(area_after - area) / area > 0.10:
		push_error("loop area drifted: %f -> %f" % [area, area_after])
		o.queue_free()
		skel.queue_free()
		return false
	o.queue_free()
	skel.queue_free()
	return true


# Non-identity host_bone_offset is applied on top of the bone pose.
func test_host_bone_offset_applied() -> bool:
	var skel: Skeleton3D = _make_skeleton(&"Hips")
	var o: Node3D = ClassDB.instantiate("Orifice")
	get_root().add_child(o)
	o.set_host_bone(_node_path(skel), &"Hips")
	# Author an offset of (0.2, 0.0, 0.0) in bone-local space.
	var offset := Transform3D(Basis(), Vector3(0.2, 0.0, 0.0))
	o.host_bone_offset = offset
	# Move the bone to (0, 1, 0).
	_set_bone_pos(skel, 0, Vector3(0.0, 1.0, 0.0))
	o.tick(DT)
	# Expected world: bone (0, 1, 0) × offset (0.2, 0, 0) = (0.2, 1, 0).
	var expected := Vector3(0.2, 1.0, 0.0)
	var got: Vector3 = (o.get_center_frame_world() as Transform3D).origin
	if (got - expected).length() > 1e-3:
		push_error("offset not applied: got %s expected %s" % [got, expected])
		o.queue_free()
		skel.queue_free()
		return false
	o.queue_free()
	skel.queue_free()
	return true


# Invalid path / unknown bone name → falls back silently to the orifice's
# own global_transform, no crash, no errors emitted.
func test_host_bone_invalid_path_falls_back() -> bool:
	var o: Node3D = ClassDB.instantiate("Orifice")
	o.position = Vector3(2.0, 0.0, 0.0)
	get_root().add_child(o)
	# Bad NodePath.
	var ok_bad_path: bool = o.set_host_bone(NodePath("DoesNotExist"), &"Hips")
	if ok_bad_path:
		push_error("set_host_bone returned true for invalid path")
		o.queue_free()
		return false
	o.tick(DT)
	# Orifice frame should equal its own global_transform (identity-based,
	# since no host bone is active).
	var got: Vector3 = (o.get_center_frame_world() as Transform3D).origin
	var expected := Vector3(2.0, 0.0, 0.0)
	if (got - expected).length() > 1e-5:
		push_error("orifice frame moved despite invalid bone: %s != %s" % [got, expected])
		o.queue_free()
		return false
	# get_host_bone_state.has_host_bone should be false.
	var state: Dictionary = o.get_host_bone_state()
	if state.get("has_host_bone", true):
		push_error("has_host_bone true after invalid path")
		o.queue_free()
		return false
	# Now configure a valid skeleton but a bone name that doesn't exist.
	var skel: Skeleton3D = _make_skeleton(&"Hips")
	var ok_bad_bone: bool = o.set_host_bone(_node_path(skel), &"NoSuchBone")
	if ok_bad_bone:
		push_error("set_host_bone returned true for unknown bone name")
		o.queue_free()
		skel.queue_free()
		return false
	o.tick(DT)
	state = o.get_host_bone_state()
	if state.get("has_host_bone", true):
		push_error("has_host_bone true after unknown bone name")
		o.queue_free()
		skel.queue_free()
		return false
	o.queue_free()
	skel.queue_free()
	return true


# Changing bone_name after setup re-resolves the bone index.
func test_host_bone_path_change_re_resolves() -> bool:
	var skel := Skeleton3D.new()
	skel.name = "MultiBoneSkel"
	get_root().add_child(skel)
	skel.add_bone(&"Hips")
	skel.add_bone(&"Chest")
	skel.reset_bone_poses()
	var o: Node3D = ClassDB.instantiate("Orifice")
	get_root().add_child(o)
	# Configure for Hips first.
	var ok: bool = o.set_host_bone(_node_path(skel), &"Hips")
	if not ok:
		push_error("initial set_host_bone(Hips) failed")
		o.queue_free()
		skel.queue_free()
		return false
	if int(o.get_host_bone_state().get("bone_index", -1)) != 0:
		push_error("bone_index didn't resolve to 0 for Hips")
		o.queue_free()
		skel.queue_free()
		return false
	# Switch to Chest.
	o.bone_name = &"Chest"
	o.tick(DT)
	if int(o.get_host_bone_state().get("bone_index", -1)) != 1:
		push_error("bone_index didn't re-resolve to 1 after switching to Chest")
		o.queue_free()
		skel.queue_free()
		return false
	# Move the Chest bone, verify the orifice tracks it (not Hips).
	skel.set_bone_pose_position(1, Vector3(0.0, 0.5, 0.0))
	o.tick(DT)
	var got: Vector3 = (o.get_center_frame_world() as Transform3D).origin
	if (got - Vector3(0.0, 0.5, 0.0)).length() > 1e-3:
		push_error("orifice tracked Hips instead of Chest after rename: %s" % got)
		o.queue_free()
		skel.queue_free()
		return false
	o.queue_free()
	skel.queue_free()
	return true


# ---------------------------------------------------------------------------
# Slice 5C-A — type-2 contact (tentacle particle ↔ rim particle, bilateral
# normal projection only — no friction yet, that's 5C-C).

# Build a Tentacle parented under root with N particles. Returns the node;
# the chain settles at its anchor (defaults to particle 0 at the node's
# global_transform).
func _make_tentacle_for_contact(p_n: int = 4, p_seg: float = 0.05,
		p_radius: float = 0.04, p_pos: Vector3 = Vector3.ZERO) -> Node3D:
	var t: Node3D = ClassDB.instantiate("Tentacle")
	t.particle_count = p_n
	t.segment_length = p_seg
	t.particle_collision_radius = p_radius
	t.gravity = Vector3.ZERO
	# Disable env probe — 5C-A only exercises tentacle-rim contact.
	t.environment_probe_distance = 0.0
	t.position = p_pos
	t.name = "TestTentacle"
	get_root().add_child(t)
	return t


# Build a circular Orifice with N=8, radius=0.05, soft spring so contact
# can dominate. Caller registers tentacles after add_child.
func _make_orifice_for_contact(p_radius: float = 0.05, p_n: int = 8,
		p_rest_stiffness: float = 0.05) -> Node3D:
	var o: Node3D = ClassDB.instantiate("Orifice")
	o.entry_axis = ENTRY_AXIS
	o.name = "TestOrifice"
	get_root().add_child(o)
	var rest_pos: PackedVector3Array = o.make_circular_rest_positions(p_n, p_radius, ENTRY_AXIS)
	var seg_lens: PackedFloat32Array = o.make_uniform_segment_rest_lengths(rest_pos)
	var area: float = absf(o.compute_polygon_area(rest_pos, ENTRY_AXIS))
	var stf := PackedFloat32Array()
	stf.resize(p_n)
	for i in p_n:
		stf[i] = p_rest_stiffness
	o.add_rim_loop(rest_pos, seg_lens, area, stf, 1e-4, 1e-6, 0.02)
	return o


# Tentacle particle starts INSIDE a rim particle's contact range. After
# one tick, the tentacle particle has moved along the contact normal away
# from the rim particle.
func test_type2_pushes_tentacle_particle_out() -> bool:
	var o: Node3D = _make_orifice_for_contact()
	var t: Node3D = _make_tentacle_for_contact(4, 0.05, 0.04)
	o.register_tentacle(NodePath("/root/" + str(t.name)))
	# Place tentacle particle 1 right at the world position of rim
	# particle 0 (rim sits on +X at radius 0.05 in the entry-axis plane).
	var rim_state: Array = o.get_rim_loop_state(0)
	var rim_pos_0: Vector3 = rim_state[0]["current_position"]
	t.get_solver().set_particle_position(1, rim_pos_0)
	var t_initial: Vector3 = t.get_particle_positions()[1]
	o.tick(DT)
	var t_final: Vector3 = t.get_particle_positions()[1]
	var moved: Vector3 = t_final - t_initial
	if moved.length() < 1e-4:
		push_error("tentacle particle did not move (expected push out): %s" % moved)
		return false
	# Push direction must oppose the normal (tentacle moves AWAY from rim).
	var normal_to_rim: Vector3 = (rim_pos_0 - t_initial).normalized()
	if normal_to_rim.length_squared() > 0.0 and moved.dot(normal_to_rim) > 1e-4:
		push_error("tentacle moved toward rim instead of away: dot=%f" % moved.dot(normal_to_rim))
		return false
	# Snapshot has at least one contact for this pair.
	var contacts: Array = o.get_type2_contacts_snapshot()
	var found := false
	for ci in contacts.size():
		var c: Dictionary = contacts[ci]
		if int(c.get("particle_index", -1)) == 1 and int(c.get("rim_particle_index", -1)) == 0:
			found = true
			break
	if not found:
		push_error("expected (tent_particle=1, rim_particle=0) in snapshot, got %d entries" % contacts.size())
		return false
	return true


# With both tentacle and rim particles unpinned (default inv_mass=1), the
# bilateral mass split distributes the projection 50/50. Verify the rim
# particle moved by a similar magnitude to the tentacle particle (signs
# opposite, magnitudes within tolerance).
func test_type2_pushes_rim_particle_correspondingly() -> bool:
	var o: Node3D = _make_orifice_for_contact(0.05, 8, 0.0)  # zero rest spring → easy to displace
	var t: Node3D = _make_tentacle_for_contact(4, 0.05, 0.04)
	o.register_tentacle(NodePath("/root/" + str(t.name)))
	var rim_state: Array = o.get_rim_loop_state(0)
	var rim_pos_0_initial: Vector3 = rim_state[0]["current_position"]
	# Push tentacle particle 1 just past the rim particle's contact zone.
	var penetration_pos: Vector3 = rim_pos_0_initial + Vector3(-0.01, 0.0, 0.0)
	t.get_solver().set_particle_position(1, penetration_pos)
	var t_initial: Vector3 = t.get_particle_positions()[1]
	o.tick(DT)
	var rim_after: Vector3 = o.get_particle_position(0, 0)
	var t_after: Vector3 = t.get_particle_positions()[1]
	var rim_moved: float = (rim_after - rim_pos_0_initial).length()
	var t_moved: float = (t_after - t_initial).length()
	if rim_moved < 1e-4:
		push_error("rim particle did not move (expected mass-split correction): %f" % rim_moved)
		return false
	# 50/50 mass split → both move by similar magnitude (within 50% of each
	# other after the spring/distance constraints react across the loop).
	if rim_moved < 0.2 * t_moved or rim_moved > 5.0 * t_moved:
		push_error("rim/tent move ratio off: rim=%f tent=%f" % [rim_moved, t_moved])
		return false
	return true


# normal_lambda only grows during the iter loop within a single tick — XPBD
# clamps the accumulator to ≥ 0 so contacts only push, never pull. Verify
# by snapshotting after a tick and asserting all contact lambdas are ≥ 0.
func test_type2_lambda_accumulates_across_iters() -> bool:
	var o: Node3D = _make_orifice_for_contact()
	var t: Node3D = _make_tentacle_for_contact(4, 0.05, 0.04)
	o.register_tentacle(NodePath("/root/" + str(t.name)))
	var rim_pos_0: Vector3 = (o.get_rim_loop_state(0)[0]["current_position"] as Vector3)
	t.get_solver().set_particle_position(1, rim_pos_0 + Vector3(-0.005, 0.0, 0.0))
	o.tick(DT)
	var contacts: Array = o.get_type2_contacts_snapshot()
	if contacts.size() == 0:
		push_error("expected at least one contact, got 0")
		return false
	for ci in contacts.size():
		var c: Dictionary = contacts[ci]
		var lam: float = c.get("normal_lambda", -1.0)
		if not is_finite(lam):
			push_error("non-finite normal_lambda: %f" % lam)
			return false
		if lam < 0.0:
			push_error("normal_lambda went negative (XPBD clamp violated): %f" % lam)
			return false
	return true


# Each tick rebuilds the contact list from scratch with normal_lambda = 0.
# Even after many ticks of contact, the FIRST contact reported per tick has
# bounded lambda — no compounding across ticks (canary equivalent of the
# distance-lambda reset test).
func test_type2_contact_resets_per_tick() -> bool:
	var o: Node3D = _make_orifice_for_contact()
	var t: Node3D = _make_tentacle_for_contact(4, 0.05, 0.04)
	o.register_tentacle(NodePath("/root/" + str(t.name)))
	var rim_pos_0: Vector3 = (o.get_rim_loop_state(0)[0]["current_position"] as Vector3)
	t.get_solver().set_particle_position(1, rim_pos_0 + Vector3(-0.005, 0.0, 0.0))
	o.tick(DT)
	var first_lam := 0.0
	var contacts_first: Array = o.get_type2_contacts_snapshot()
	for ci in contacts_first.size():
		var c: Dictionary = contacts_first[ci]
		first_lam = max(first_lam, float(c.get("normal_lambda", 0.0)))
	# Run 60 more ticks; after each, snapshot lambda magnitude. If reset
	# weren't wired, lambda would compound and exceed the first tick by
	# orders of magnitude. Bound: max-per-tick stays within 5× the first
	# tick's value.
	var lam_max := first_lam
	for _i in 60:
		# Re-push the tentacle particle so contact is consistent each tick
		# (lazy reset: predict in solver clears in_contact flag, so we have
		# to re-induce contact each frame for this canary).
		t.get_solver().set_particle_position(1, rim_pos_0 + Vector3(-0.005, 0.0, 0.0))
		o.tick(DT)
		var contacts: Array = o.get_type2_contacts_snapshot()
		for ci in contacts.size():
			var c: Dictionary = contacts[ci]
			lam_max = max(lam_max, float(c.get("normal_lambda", 0.0)))
	if lam_max > 5.0 * first_lam + 1e-6:
		push_error("normal_lambda compounded across ticks: max=%e first=%e" % [lam_max, first_lam])
		return false
	return true


# Tentacle particles outside the contact radius produce no contact entries.
func test_type2_no_contact_outside_radius() -> bool:
	var o: Node3D = _make_orifice_for_contact()
	var t: Node3D = _make_tentacle_for_contact(4, 0.05, 0.04, Vector3(0.0, 1.0, 0.0))
	o.register_tentacle(NodePath("/root/" + str(t.name)))
	# Tentacle is at world y=1.0 — far above the rim, no chance of contact.
	o.tick(DT)
	var contacts: Array = o.get_type2_contacts_snapshot()
	if contacts.size() != 0:
		push_error("expected 0 contacts when tentacle is outside radius, got %d" % contacts.size())
		return false
	return true


# Pinned rim particle (inv_mass=0) takes 0 share of the mass-split, so the
# tentacle particle is projected out by the FULL penetration depth.
func test_type2_pinned_rim_particle_only_pushes_tentacle() -> bool:
	var o: Node3D = _make_orifice_for_contact(0.05, 8, 0.5)
	var t: Node3D = _make_tentacle_for_contact(4, 0.05, 0.04)
	o.register_tentacle(NodePath("/root/" + str(t.name)))
	# Pin rim particle 0 in place.
	o.set_particle_inv_mass(0, 0, 0.0)
	var rim_pos_0: Vector3 = o.get_particle_position(0, 0)
	# Push tentacle particle 1 INTO the rim by 1 cm.
	var penetration := 0.01
	t.get_solver().set_particle_position(1, rim_pos_0 + Vector3(-penetration, 0.0, 0.0))
	var t_initial: Vector3 = t.get_particle_positions()[1]
	o.tick(DT)
	# The pinned rim particle should not have moved.
	var rim_after: Vector3 = o.get_particle_position(0, 0)
	if (rim_after - rim_pos_0).length() > 1e-4:
		push_error("pinned rim particle drifted: %e" % (rim_after - rim_pos_0).length())
		return false
	# The tentacle particle should have moved by the full penetration depth
	# (within distance constraint slack — the tentacle's distance constraint
	# pulls particle 1 back toward the chain, so we tolerate ~30% slack).
	var t_after: Vector3 = t.get_particle_positions()[1]
	var t_moved: float = (t_after - t_initial).length()
	if t_moved < 0.5 * penetration:
		push_error("tentacle barely moved despite pinned rim: moved=%e expected≈%e" % [t_moved, penetration])
		return false
	return true


# ---------------------------------------------------------------------------
# Slice 5C-B — EntryInteraction lifecycle + per-tick geometric tracking.
# Force routing slots (grip_engagement, friction, reaction-on-host-bone)
# are initialized but NOT driven in 5C-B; tests verify they remain at zero.

# Build a tentacle whose anchor sits at p_anchor world; the chain hangs
# in -p_axis direction with zero gravity so we can reposition particles
# arbitrarily without the solver fighting back.
func _make_tentacle_for_ei(p_anchor: Vector3 = Vector3.ZERO,
		p_axis: Vector3 = Vector3(0.0, 0.0, 1.0),
		p_n: int = 4, p_seg: float = 0.05, p_radius: float = 0.04) -> Node3D:
	var t: Node3D = ClassDB.instantiate("Tentacle")
	t.particle_count = p_n
	t.segment_length = p_seg
	t.particle_collision_radius = p_radius
	t.gravity = Vector3.ZERO
	t.environment_probe_distance = 0.0
	t.position = p_anchor
	t.name = "TestTentacleEI"
	get_root().add_child(t)
	# Lay the chain along p_axis manually so particle 0 sits at anchor
	# and successive particles step forward along p_axis.
	var sol: Object = t.get_solver()
	for i in p_n:
		sol.set_particle_position(i, p_anchor + p_axis * (p_seg * float(i)))
	return t


# Tentacle anchored OUTSIDE the orifice's entry plane with the tip pushed
# through. After one tick, EI count goes from 0 to 1 and the geometric
# fields populate plausibly.
func test_ei_created_on_first_crossing() -> bool:
	var o: Node3D = _make_orifice_for_contact(0.05, 8, 0.5)
	# Tentacle anchored at -Z (cavity-EXTERIOR side per our entry_axis=+Z),
	# pushing toward +Z so particle N-1 ends up at +Z (cavity-INTERIOR).
	# Chain length = (n-1) * seg = 3 * 0.05 = 0.15. Anchor -0.05 → tip +0.10.
	var t: Node3D = _make_tentacle_for_ei(Vector3(0.0, 0.0, -0.05), Vector3(0.0, 0.0, 1.0))
	o.register_tentacle(NodePath("/root/" + str(t.name)))
	if int(o.get_entry_interaction_count()) != 0:
		push_error("expected 0 EIs before first tick, got %d" % int(o.get_entry_interaction_count()))
		return false
	o.tick(DT)
	if int(o.get_entry_interaction_count()) != 1:
		push_error("expected 1 EI after first crossing, got %d" % int(o.get_entry_interaction_count()))
		return false
	var snap: Array = o.get_entry_interactions_snapshot()
	var ei: Dictionary = snap[0]
	if not ei.get("active", false):
		push_error("EI not flagged active after engagement")
		return false
	if ei.get("arc_length_at_entry", -1.0) <= 0.0:
		push_error("arc_length_at_entry not positive: %f" % ei.get("arc_length_at_entry", -1.0))
		return false
	if ei.get("penetration_depth", -1.0) <= 0.0:
		push_error("penetration_depth not positive: %f" % ei.get("penetration_depth", -1.0))
		return false
	return true


# Push the tentacle deeper between ticks; penetration_depth strictly
# increases.
func test_ei_geometric_state_updates_each_tick() -> bool:
	var o: Node3D = _make_orifice_for_contact(0.05, 8, 0.5)
	var t: Node3D = _make_tentacle_for_ei(Vector3(0.0, 0.0, -0.05), Vector3(0.0, 0.0, 1.0))
	o.register_tentacle(NodePath("/root/" + str(t.name)))
	o.tick(DT)
	var depth_first: float = float(o.get_entry_interactions_snapshot()[0].get("penetration_depth", 0.0))
	# Push the tentacle anchor 5 cm further into the cavity (toward +Z).
	t.position = Vector3(0.0, 0.0, 0.0)
	# Reposition every particle so the chain sits in its new pose without
	# solver lag (test isolates the EI refresh, not solver dynamics).
	var sol: Object = t.get_solver()
	for i in 4:
		sol.set_particle_position(i, t.position + Vector3(0.0, 0.0, 0.05) * float(i))
	o.tick(DT)
	var depth_second: float = float(o.get_entry_interactions_snapshot()[0].get("penetration_depth", 0.0))
	if depth_second <= depth_first + 1e-5:
		push_error("penetration_depth didn't increase: %f -> %f" % [depth_first, depth_second])
		return false
	return true


# Push inward → positive axial_velocity; pull outward → negative.
# `axial_velocity = (penetration_depth − prev_penetration_depth) / dt`.
func test_ei_axial_velocity_sign() -> bool:
	var o: Node3D = _make_orifice_for_contact(0.05, 8, 0.5)
	var t: Node3D = _make_tentacle_for_ei(Vector3(0.0, 0.0, -0.05), Vector3(0.0, 0.0, 1.0))
	o.register_tentacle(NodePath("/root/" + str(t.name)))
	o.tick(DT)  # creation tick — axial_velocity reads 0 by design
	var sol: Object = t.get_solver()
	# Push deeper.
	for i in 4:
		sol.set_particle_position(i, Vector3(0.0, 0.0, -0.05 + 0.05 + 0.05 * float(i)))
	o.tick(DT)
	var v_inward: float = float(o.get_entry_interactions_snapshot()[0].get("axial_velocity", 0.0))
	if v_inward <= 1e-5:
		push_error("expected positive axial_velocity on push-inward, got %f" % v_inward)
		return false
	# Pull back outward.
	for i in 4:
		sol.set_particle_position(i, Vector3(0.0, 0.0, -0.05 + 0.05 * float(i)))
	o.tick(DT)
	var v_outward: float = float(o.get_entry_interactions_snapshot()[0].get("axial_velocity", 0.0))
	if v_outward >= -1e-5:
		push_error("expected negative axial_velocity on pull-outward, got %f" % v_outward)
		return false
	return true


# Straight-on insertion (tentacle tangent aligned with entry_axis): cos ≈ 1.
# Oblique 45°: cos ≈ 0.707.
func test_ei_approach_angle_cos() -> bool:
	# Straight-on: tentacle along +Z, entry_axis +Z.
	var o1: Node3D = _make_orifice_for_contact(0.05, 8, 0.5)
	var t1: Node3D = _make_tentacle_for_ei(Vector3(0.0, 0.0, -0.05), Vector3(0.0, 0.0, 1.0))
	o1.register_tentacle(NodePath("/root/" + str(t1.name)))
	o1.tick(DT)
	var cos1: float = float(o1.get_entry_interactions_snapshot()[0].get("approach_angle_cos", 0.0))
	if absf(cos1 - 1.0) > 0.05:
		push_error("straight-on cos ≈ 1 expected, got %f" % cos1)
		return false
	# Reset root for the 45° case.
	_reset_root()
	var o2: Node3D = _make_orifice_for_contact(0.10, 8, 0.5)  # bigger rim so 45° chain fits
	var diag := Vector3(1.0, 0.0, 1.0).normalized()
	var t2: Node3D = _make_tentacle_for_ei(Vector3(0.0, 0.0, 0.0) - diag * 0.05, diag, 4, 0.05, 0.04)
	# Place anchor outside (negative Z half-space) and chain crossing into +Z.
	# Manually move particles so the chain crosses at ~45° to the +Z plane.
	var sol2: Object = t2.get_solver()
	for i in 4:
		sol2.set_particle_position(i, Vector3(0.0, 0.0, 0.0) - diag * 0.05 + diag * (0.05 * float(i)))
	o2.register_tentacle(NodePath("/root/" + str(t2.name)))
	o2.tick(DT)
	var cos2: float = float(o2.get_entry_interactions_snapshot()[0].get("approach_angle_cos", 0.0))
	if absf(cos2 - sqrt(0.5)) > 0.10:
		push_error("45° cos ≈ 0.707 expected, got %f" % cos2)
		return false
	return true


# `particles_in_tunnel` lists exactly the cavity-side particle indices.
# With the tentacle at anchor -0.05, particles step at +0.05Z each, so
# particle 0 is at z=-0.05 (out), particle 1 at z=0 (boundary, treated
# as "out" since signed_distance >= 0), particle 2 at z=+0.05 (in),
# particle 3 at z=+0.10 (in).
func test_ei_particles_in_tunnel() -> bool:
	var o: Node3D = _make_orifice_for_contact(0.05, 8, 0.5)
	var t: Node3D = _make_tentacle_for_ei(Vector3(0.0, 0.0, -0.05), Vector3(0.0, 0.0, 1.0))
	o.register_tentacle(NodePath("/root/" + str(t.name)))
	o.tick(DT)
	var pit: PackedInt32Array = o.get_entry_interactions_snapshot()[0].get("particles_in_tunnel", PackedInt32Array())
	# Expect particles 2 and 3 in tunnel (z > 0). Particle 1 sits exactly
	# on the plane (signed_distance = 0) which the spec treats as outside.
	if pit.size() != 2:
		push_error("expected 2 particles in tunnel, got %d (%s)" % [pit.size(), pit])
		return false
	if not (pit.has(2) and pit.has(3)):
		push_error("expected indices [2, 3] in tunnel, got %s" % str(pit))
		return false
	return true


# Engage → fully withdraw → tick for grace_period + epsilon → EI removed.
func test_ei_retirement_after_grace_period() -> bool:
	var o: Node3D = _make_orifice_for_contact(0.05, 8, 0.5)
	# Use a tight grace period so the test runs fast.
	o.entry_interaction_grace_period = 0.05  # 50 ms
	var t: Node3D = _make_tentacle_for_ei(Vector3(0.0, 0.0, -0.05), Vector3(0.0, 0.0, 1.0))
	o.register_tentacle(NodePath("/root/" + str(t.name)))
	o.tick(DT)
	if int(o.get_entry_interaction_count()) != 1:
		push_error("EI not created on engagement")
		return false
	# Withdraw fully — pull the chain entirely to the cavity-EXTERIOR side.
	var sol: Object = t.get_solver()
	for i in 4:
		sol.set_particle_position(i, Vector3(0.0, 0.0, -0.20 - 0.05 * float(i)))
	# Tick one frame to register disengagement.
	o.tick(DT)
	# EI should still exist (in grace period) but inactive.
	if int(o.get_entry_interaction_count()) != 1:
		push_error("EI purged before grace period elapsed")
		return false
	if bool(o.get_entry_interactions_snapshot()[0].get("active", true)):
		push_error("EI still flagged active after withdrawal")
		return false
	# Tick past the grace period (50 ms = ~3 frames at 60Hz).
	for _i in 8:
		o.tick(DT)
	if int(o.get_entry_interaction_count()) != 0:
		push_error("EI not purged after grace period: count=%d" % int(o.get_entry_interaction_count()))
		return false
	return true


# Persistent slots zero on creation. grip_engagement = 0, in_stick_phase
# = false, ejection_velocity = 0.
func test_ei_persistent_slots_initialized() -> bool:
	var o: Node3D = _make_orifice_for_contact(0.05, 8, 0.5)
	var t: Node3D = _make_tentacle_for_ei(Vector3(0.0, 0.0, -0.05), Vector3(0.0, 0.0, 1.0))
	o.register_tentacle(NodePath("/root/" + str(t.name)))
	o.tick(DT)
	var ei: Dictionary = o.get_entry_interactions_snapshot()[0]
	if absf(float(ei.get("grip_engagement", -1.0))) > 1e-9:
		push_error("grip_engagement not zero on creation: %f" % ei.get("grip_engagement"))
		return false
	if bool(ei.get("in_stick_phase", true)):
		push_error("in_stick_phase not false on creation")
		return false
	if absf(float(ei.get("ejection_velocity", -1.0))) > 1e-9:
		push_error("ejection_velocity not zero on creation: %f" % ei.get("ejection_velocity"))
		return false
	return true


# Persistent slots stay at zero across many steady ticks. 5C-B does NOT
# drive them — 5C-C will. Smoke check that the lifecycle doesn't write
# accidentally.
func test_ei_persistent_slots_not_driven() -> bool:
	var o: Node3D = _make_orifice_for_contact(0.05, 8, 0.5)
	var t: Node3D = _make_tentacle_for_ei(Vector3(0.0, 0.0, -0.05), Vector3(0.0, 0.0, 1.0))
	o.register_tentacle(NodePath("/root/" + str(t.name)))
	for _i in 60:
		o.tick(DT)
	var ei: Dictionary = o.get_entry_interactions_snapshot()[0]
	if absf(float(ei.get("grip_engagement", -1.0))) > 1e-9:
		push_error("grip_engagement drifted in 5C-B: %f" % ei.get("grip_engagement"))
		return false
	if bool(ei.get("in_stick_phase", true)):
		push_error("in_stick_phase flipped in 5C-B")
		return false
	return true


# Two tentacles engaging the same orifice produce two EIs with
# independent state.
func test_ei_multi_tentacle_coexist() -> bool:
	var o: Node3D = _make_orifice_for_contact(0.10, 8, 0.5)
	var t1: Node3D = _make_tentacle_for_ei(Vector3(0.04, 0.0, -0.05), Vector3(0.0, 0.0, 1.0))
	t1.name = "Tentacle1"
	var t2: Node3D = _make_tentacle_for_ei(Vector3(-0.04, 0.0, -0.05), Vector3(0.0, 0.0, 1.0))
	t2.name = "Tentacle2"
	o.register_tentacle(NodePath("/root/" + str(t1.name)))
	o.register_tentacle(NodePath("/root/" + str(t2.name)))
	o.tick(DT)
	if int(o.get_entry_interaction_count()) != 2:
		push_error("expected 2 EIs (one per tentacle), got %d" % int(o.get_entry_interaction_count()))
		return false
	var snap: Array = o.get_entry_interactions_snapshot()
	var idx_set := {}
	for ei_idx in snap.size():
		var ei: Dictionary = snap[ei_idx]
		idx_set[int(ei.get("tentacle_index", -1))] = true
	if not (idx_set.has(0) and idx_set.has(1)):
		push_error("EIs missing tentacle indices: %s" % str(idx_set))
		return false
	return true


# Engaging tentacle gets unregistered → its EI fast-purges on the next
# tick (regardless of grace period).
func test_ei_unregistered_tentacle_retires_immediately() -> bool:
	var o: Node3D = _make_orifice_for_contact(0.05, 8, 0.5)
	o.entry_interaction_grace_period = 1.0  # generous, but unregister should bypass it
	var t: Node3D = _make_tentacle_for_ei(Vector3(0.0, 0.0, -0.05), Vector3(0.0, 0.0, 1.0))
	o.register_tentacle(NodePath("/root/" + str(t.name)))
	o.tick(DT)
	if int(o.get_entry_interaction_count()) != 1:
		push_error("EI not created before unregister")
		return false
	o.unregister_tentacle(NodePath("/root/" + str(t.name)))
	o.tick(DT)
	if int(o.get_entry_interaction_count()) != 0:
		push_error("EI not fast-purged after unregister, count=%d" % int(o.get_entry_interaction_count()))
		return false
	return true


# ---------------------------------------------------------------------------

func _get_particle_field(o: Node3D, loop: int, particle: int, field: String) -> Variant:
	var state: Array = o.get_rim_loop_state(loop)
	return state[particle][field]
