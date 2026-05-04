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

func _get_particle_field(o: Node3D, loop: int, particle: int, field: String) -> Variant:
	var state: Array = o.get_rim_loop_state(loop)
	return state[particle][field]
