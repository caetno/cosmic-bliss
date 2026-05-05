extends SceneTree

# Slice 4T — pose-target rate limiting. Source-side complement to the
# 4Q-fix tension taper.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_target_rate_limit.gd
#
# Coverage:
#   1. Default + setter clamp (negative → 0; large stays).
#   2. Cold-start bypass: first set_target after clear_target must NOT
#      clamp on the first tick.
#   3. Warm-running clamp: a set_target whose delta exceeds
#      target_velocity_max × dt must be capped to that magnitude.
#   4. Disabled (target_velocity_max = 0): large jumps pass through.
#   5. Cold-start re-arm: clear_target → set_target re-arms the bypass.
#   6. Pose-target indices change → cold-start re-arm for all entries.
#   7. Pose-target indices preserved → warm-running clamp continues.
#   8. Behavioural step-function: large target jump with low velocity
#      cap must move the chain forward gradually, not all-at-once.

const DT := 1.0 / 60.0


var _ran: bool = false


func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_run_tests()
	return true


func _run_tests() -> void:
	if not ClassDB.class_exists("Tentacle"):
		push_error("[FAIL] tentacletech extension not loaded")
		quit(2)
		return

	var passed: int = 0
	var failed: int = 0

	for test_name in [
		"test_default_and_clamp",
		"test_cold_start_bypass",
		"test_warm_running_clamp",
		"test_disabled_passes_large_jumps",
		"test_clear_re_arms_cold_start",
		"test_pose_target_indices_change_re_arms",
		"test_pose_target_indices_preserved_warm_clamp",
		"test_step_function_chain_advances_gradually",
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


func _make_tentacle(p_pos: Vector3, p_n: int = 4, p_seg: float = 0.05) -> Node3D:
	var t: Node3D = ClassDB.instantiate("Tentacle")
	t.particle_count = p_n
	t.segment_length = p_seg
	t.position = p_pos
	t.gravity = Vector3.ZERO  # tests target dynamics in isolation
	t.environment_probe_distance = 0.0  # disable contact probe
	t.particle_collision_radius = 0.04
	root.add_child(t)
	return t


# 1. Default value + setter clamp behaviour.
func test_default_and_clamp() -> bool:
	var t: Node3D = _make_tentacle(Vector3.ZERO)
	if absf(t.target_velocity_max - 5.0) > 1e-5:
		push_error("expected default target_velocity_max=5.0, got %f" %
				t.target_velocity_max)
		return false
	# Negative clamps to 0.
	t.target_velocity_max = -3.0
	if t.target_velocity_max != 0.0:
		push_error("expected clamp to 0.0, got %f" % t.target_velocity_max)
		return false
	# Large allowed (or_greater hint).
	t.target_velocity_max = 100.0
	if absf(t.target_velocity_max - 100.0) > 1e-5:
		push_error("expected 100.0, got %f" % t.target_velocity_max)
		return false
	# Setter forwards to solver.
	var solver = t.get_solver()
	if absf(solver.get_target_velocity_max() - 100.0) > 1e-5:
		push_error("Tentacle.target_velocity_max not forwarded to solver: %f" %
				solver.get_target_velocity_max())
		return false
	return true


# 2. Cold-start bypass — first set_target after clear_target sets the
# clamp basis but does NOT clamp the first tick. Effective target after
# the first apply_target_rate_limit equals the driver-supplied target.
func test_cold_start_bypass() -> bool:
	var t: Node3D = _make_tentacle(Vector3.ZERO)
	t.target_velocity_max = 1.0  # cap = 1.0 × DT = 0.0167 m
	var solver = t.get_solver()
	# Far jump on cold start — would normally clamp to ~0.0167 m, but
	# cold-start bypass means the full target survives this tick.
	solver.set_target(t.particle_count - 1, Vector3(2.0, 0.0, 0.0), 0.5)
	# Pull rate limit explicitly (Tentacle.tick would do this internally
	# but we want to inspect post-clamp state without driving the full
	# pipeline).
	solver.apply_target_rate_limit(DT)
	var clamped: Vector3 = solver.get_target_position_clamped()
	if (clamped - Vector3(2.0, 0.0, 0.0)).length() > 1e-5:
		push_error("cold-start should preserve target, got %s" % str(clamped))
		return false
	# Solver-side `get_target_position()` (the actual pull target) also
	# unchanged on cold start.
	var pull: Vector3 = solver.get_target_position()
	if (pull - Vector3(2.0, 0.0, 0.0)).length() > 1e-5:
		push_error("cold-start should preserve pull target, got %s" % str(pull))
		return false
	return true


# 3. Warm-running clamp — second set_target whose delta exceeds
# `target_velocity_max × dt` is capped to that magnitude.
func test_warm_running_clamp() -> bool:
	var t: Node3D = _make_tentacle(Vector3.ZERO)
	t.target_velocity_max = 1.0  # cap = 0.0167 m / tick
	var solver = t.get_solver()
	# Cold-start at origin.
	solver.set_target(t.particle_count - 1, Vector3.ZERO, 0.5)
	solver.apply_target_rate_limit(DT)
	# Warm-up run: now move target FAR. Delta = 2.0 m, cap = 0.0167 m.
	solver.set_target(t.particle_count - 1, Vector3(2.0, 0.0, 0.0), 0.5)
	solver.apply_target_rate_limit(DT)
	var clamped: Vector3 = solver.get_target_position_clamped()
	# Effective target should be cap-distance from origin, not 2.0 m.
	if absf(clamped.x - (1.0 * DT)) > 1e-4:
		push_error("warm clamp expected x=%.4f, got %s" % [1.0 * DT, str(clamped)])
		return false
	# Solver's internal target_position is mutated (not just snapshot).
	var pull: Vector3 = solver.get_target_position()
	if absf(pull.x - (1.0 * DT)) > 1e-4:
		push_error("solver pull target should be clamped: got %s" % str(pull))
		return false
	# Second tick — cap advances by another DT × 1.0 m.
	solver.set_target(t.particle_count - 1, Vector3(2.0, 0.0, 0.0), 0.5)
	solver.apply_target_rate_limit(DT)
	clamped = solver.get_target_position_clamped()
	if absf(clamped.x - (2.0 * DT)) > 1e-4:
		push_error("warm clamp tick 2 expected x=%.4f, got %s" % [2.0 * DT, str(clamped)])
		return false
	return true


# 4. Disabled — target_velocity_max = 0 lets large jumps pass through.
func test_disabled_passes_large_jumps() -> bool:
	var t: Node3D = _make_tentacle(Vector3.ZERO)
	t.target_velocity_max = 0.0
	var solver = t.get_solver()
	solver.set_target(t.particle_count - 1, Vector3.ZERO, 0.5)
	solver.apply_target_rate_limit(DT)
	# Large warm-running jump should NOT clamp.
	solver.set_target(t.particle_count - 1, Vector3(2.0, 0.0, 0.0), 0.5)
	solver.apply_target_rate_limit(DT)
	var clamped: Vector3 = solver.get_target_position_clamped()
	if (clamped - Vector3(2.0, 0.0, 0.0)).length() > 1e-5:
		push_error("disabled should pass-through, got %s" % str(clamped))
		return false
	return true


# 5. clear_target re-arms the cold-start bypass.
func test_clear_re_arms_cold_start() -> bool:
	var t: Node3D = _make_tentacle(Vector3.ZERO)
	t.target_velocity_max = 1.0
	var solver = t.get_solver()
	# Establish warm state at origin.
	solver.set_target(t.particle_count - 1, Vector3.ZERO, 0.5)
	solver.apply_target_rate_limit(DT)
	# Clear, then set far target — cold-start bypass should engage AGAIN,
	# not clamp.
	solver.clear_target()
	solver.set_target(t.particle_count - 1, Vector3(2.0, 0.0, 0.0), 0.5)
	solver.apply_target_rate_limit(DT)
	var clamped: Vector3 = solver.get_target_position_clamped()
	if (clamped - Vector3(2.0, 0.0, 0.0)).length() > 1e-5:
		push_error("clear should re-arm cold-start, got %s" % str(clamped))
		return false
	return true


# 6. Pose-target indices change → all entries cold-start.
func test_pose_target_indices_change_re_arms() -> bool:
	var t: Node3D = _make_tentacle(Vector3.ZERO, 4)
	t.target_velocity_max = 1.0
	var solver = t.get_solver()
	# Initial pose targets at indices [1, 2, 3] at origin.
	var i_a: PackedInt32Array = PackedInt32Array([1, 2, 3])
	var p_a: PackedVector3Array = PackedVector3Array(
			[Vector3.ZERO, Vector3.ZERO, Vector3.ZERO])
	var s_a: PackedFloat32Array = PackedFloat32Array([0.5, 0.5, 0.5])
	solver.set_pose_targets(i_a, p_a, s_a)
	solver.apply_target_rate_limit(DT)
	# Now change INDICES to [2, 3, 4] (different particles) at far positions.
	# Cold-start should re-arm for all entries → no clamp first tick.
	var i_b: PackedInt32Array = PackedInt32Array([2, 3, 4 - 1])
	# Actually we have 4 particles (indices 0..3), so use [0, 1, 2].
	i_b = PackedInt32Array([0, 1, 2])
	var p_b: PackedVector3Array = PackedVector3Array(
			[Vector3(2, 0, 0), Vector3(2, 0, 0), Vector3(2, 0, 0)])
	solver.set_pose_targets(i_b, p_b, s_a)
	solver.apply_target_rate_limit(DT)
	var clamped: PackedVector3Array = solver.get_pose_target_positions_clamped()
	if clamped.size() != 3:
		push_error("expected 3 clamped pose entries, got %d" % clamped.size())
		return false
	for i in 3:
		if (clamped[i] - Vector3(2, 0, 0)).length() > 1e-5:
			push_error("indices changed → cold-start expected, got entry[%d]=%s" %
					[i, str(clamped[i])])
			return false
	return true


# 7. Pose-target indices preserved → warm clamp continues.
func test_pose_target_indices_preserved_warm_clamp() -> bool:
	var t: Node3D = _make_tentacle(Vector3.ZERO, 4)
	t.target_velocity_max = 1.0
	var solver = t.get_solver()
	var idx: PackedInt32Array = PackedInt32Array([1, 2, 3])
	# Cold-start at origin.
	var p0: PackedVector3Array = PackedVector3Array(
			[Vector3.ZERO, Vector3.ZERO, Vector3.ZERO])
	var stf: PackedFloat32Array = PackedFloat32Array([0.5, 0.5, 0.5])
	solver.set_pose_targets(idx, p0, stf)
	solver.apply_target_rate_limit(DT)
	# Same indices, far positions → warm clamp.
	var p1: PackedVector3Array = PackedVector3Array(
			[Vector3(2, 0, 0), Vector3(2, 0, 0), Vector3(2, 0, 0)])
	solver.set_pose_targets(idx, p1, stf)
	solver.apply_target_rate_limit(DT)
	var clamped: PackedVector3Array = solver.get_pose_target_positions_clamped()
	for i in 3:
		if absf(clamped[i].x - (1.0 * DT)) > 1e-4:
			push_error("warm pose clamp entry[%d] expected x=%.4f, got %s" %
					[i, 1.0 * DT, str(clamped[i])])
			return false
	return true


# 8. Behavioural test: chain with low velocity cap should advance forward
# gradually under a step-function target jump, NOT whip across in one tick.
func test_step_function_chain_advances_gradually() -> bool:
	var t: Node3D = _make_tentacle(Vector3.ZERO, 4, 0.05)
	t.target_velocity_max = 0.5  # cap = 0.0083 m / tick
	var solver = t.get_solver()
	# Cold-start at origin (matches anchor); use solver-side 3-arg API
	# (Tentacle::set_target only takes a position, not stiffness).
	solver.set_target(t.particle_count - 1, Vector3.ZERO, 0.5)
	for _i in 30:
		t.tick(DT)  # let chain settle at origin (warm-running clamp engages
		            # internally via Tentacle::tick → apply_target_rate_limit;
		            # since target hasn't moved, no clamp applies)
	# Snap target far away. With cap=0.5 m/s, advance should be ~0.0083 m/tick.
	solver.set_target(t.particle_count - 1, Vector3(1.0, 0.0, 0.0), 0.5)
	# After 1 tick (warm-running), effective target should be 0.0083 m forward.
	t.tick(DT)
	var clamped: Vector3 = solver.get_target_position_clamped()
	if absf(clamped.x - (0.5 * DT)) > 1e-4:
		push_error("first warm tick target expected x=%.4f, got %s" %
				[0.5 * DT, str(clamped)])
		return false
	# After 60 more ticks, target has advanced at most 0.5 m × ~1s = 0.5 m
	# (cap × ticks × DT).
	for _i in 60:
		solver.set_target(t.particle_count - 1, Vector3(1.0, 0.0, 0.0), 0.5)
		t.tick(DT)
	clamped = solver.get_target_position_clamped()
	# Should be very close to 61 × 0.0083 = 0.508 m, bounded above by 1.0 m.
	if clamped.x > 1.0 + 1e-4:
		push_error("over 1.0 after 61 ticks: %s" % str(clamped))
		return false
	if clamped.x < 0.45:
		push_error("under-advanced after 61 ticks: %s" % str(clamped))
		return false
	# Disabled (cap=0): same step-function lets the target snap fully in
	# one tick. Reset and re-test.
	for c in root.get_children():
		root.remove_child(c)
		c.free()
	var t2: Node3D = _make_tentacle(Vector3.ZERO, 4, 0.05)
	t2.target_velocity_max = 0.0
	var solver2 = t2.get_solver()
	solver2.set_target(t2.particle_count - 1, Vector3.ZERO, 0.5)
	for _i in 30:
		t2.tick(DT)
	solver2.set_target(t2.particle_count - 1, Vector3(1.0, 0.0, 0.0), 0.5)
	t2.tick(DT)
	var c2: Vector3 = solver2.get_target_position_clamped()
	if (c2 - Vector3(1.0, 0.0, 0.0)).length() > 1e-5:
		push_error("disabled should snap target fully, got %s" % str(c2))
		return false
	return true
