extends SceneTree

# Tests for the multi-particle pose-target API on Tentacle / PBDSolver.
#
# Phase-3.5 — distributed soft-pull along the chain. The behavior driver
# writes one target per non-base particle each tick to drive a "muscular
# pose" curve; this test asserts the underlying mechanism works in
# isolation, separate from the wiggle/wipe/thrust composition layer.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_pose_targets.gd


func _init() -> void:
	if not ClassDB.class_exists("Tentacle"):
		push_error("[FAIL] tentacletech extension not loaded")
		quit(2)
		return

	var passed: int = 0
	var failed: int = 0
	for test_name in [
		"test_set_pose_targets_count",
		"test_pose_targets_pull_chain",
		"test_clear_pose_targets",
		"test_pose_targets_compose_with_tip_pull",
		"test_pose_targets_per_particle_stiffness",
	]:
		if call(test_name):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			push_error("[FAIL] %s" % test_name)
			failed += 1

	print("\n%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _make_tentacle(p_count: int = 12, p_seg: float = 0.08) -> Object:
	var t: Object = ClassDB.instantiate("Tentacle")
	t.particle_count = p_count
	t.segment_length = p_seg
	t.rebuild_chain()
	# Disable gravity so pose-target dynamics aren't fighting an external
	# force — the pose pull alone determines convergence.
	t.set_gravity(Vector3.ZERO)
	# Pin base, leave the rest free.
	return t


# Pose targets are accepted via three parallel arrays and reported back.
func test_set_pose_targets_count() -> bool:
	var t = _make_tentacle()
	var indices := PackedInt32Array([2, 5, 9])
	var positions := PackedVector3Array([Vector3(0.1, 0, -0.2), Vector3(0.2, 0, -0.4), Vector3(0.3, 0, -0.6)])
	var stiffs := PackedFloat32Array([0.2, 0.2, 0.2])
	t.set_pose_targets(indices, positions, stiffs)
	var n: int = t.get_pose_target_count()
	if n != 3:
		push_error("expected 3 pose targets, got %d" % n)
		return false
	return true


# With pose targets writing per-particle world positions and gravity off,
# 60 ticks should pull each non-base particle visibly toward its target.
# Convergence isn't full (soft pull, distance constraints fight it), but
# residual error must shrink from initial.
func test_pose_targets_pull_chain() -> bool:
	var t = _make_tentacle(12, 0.08)
	# Build a curved pose: each particle target is offset in +X by k * 0.04.
	var n: int = t.particle_count
	var indices := PackedInt32Array()
	var positions := PackedVector3Array()
	var stiffs := PackedFloat32Array()
	for i in range(1, n):
		indices.push_back(i)
		# Original chain extends along -Z. Target curls into +X with
		# increasing arc-length. Z stays the rest position so distance
		# constraints don't have to fight too hard.
		positions.push_back(Vector3(float(i) * 0.04, 0.0, -float(i) * 0.08))
		stiffs.push_back(0.3)
	t.set_pose_targets(indices, positions, stiffs)

	# Initial residual: sum of |target - position| across non-base particles.
	var initial_residual: float = _residual(t, indices, positions)
	# Run a handful of ticks.
	for _i in 60:
		t.get_solver().tick(1.0 / 60.0)
	var final_residual: float = _residual(t, indices, positions)

	if final_residual >= initial_residual * 0.7:
		push_error("pose pull did not converge: %.4f → %.4f (expected <70%% of initial)"
				% [initial_residual, final_residual])
		return false
	return true


# clear_pose_targets() empties the list; a subsequent tick must not pull.
func test_clear_pose_targets() -> bool:
	var t = _make_tentacle()
	var idx := PackedInt32Array([3])
	var pos := PackedVector3Array([Vector3(1.0, 0, 0)])
	var stf := PackedFloat32Array([0.3])
	t.set_pose_targets(idx, pos, stf)
	t.clear_pose_targets()
	if t.get_pose_target_count() != 0:
		push_error("clear_pose_targets did not empty the list")
		return false
	# Verify a tick after clear doesn't move the chain (gravity off).
	var before: Vector3 = t.get_particle_positions()[3]
	for _i in 10:
		t.get_solver().tick(1.0 / 60.0)
	var after: Vector3 = t.get_particle_positions()[3]
	if not before.is_equal_approx(after):
		push_error("particle moved after clear_pose_targets: %s → %s" % [before, after])
		return false
	return true


# Tip pull and pose targets must compose additively without one canceling
# the other. With both active and pulling toward different positions, the
# tip particle (which has both) ends up between them — closer to whichever
# stiffness is higher.
func test_pose_targets_compose_with_tip_pull() -> bool:
	var t = _make_tentacle(8, 0.1)
	# Pose target on tip pulls in +X; tip-pull pulls in -X. Equal stiffness
	# → the tip should land near the rest position (forces cancel) or at
	# least not snap fully to either.
	var tip_idx: int = t.particle_count - 1
	var pose_pos := Vector3(0.5, 0.0, 0.0)
	var tip_pos := Vector3(-0.5, 0.0, 0.0)
	t.set_target(pose_pos)  # activate tip pull at default stiffness
	t.set_target_stiffness(0.2)
	t.set_target(tip_pos)
	t.set_pose_targets(
		PackedInt32Array([tip_idx]),
		PackedVector3Array([pose_pos]),
		PackedFloat32Array([0.2])
	)
	for _i in 30:
		t.get_solver().tick(1.0 / 60.0)
	var tip: Vector3 = t.get_particle_positions()[tip_idx]
	# Should not fully snap to either ±0.5; both forces are competing.
	if absf(tip.x) > 0.45:
		push_error("tip snapped to one extreme (%.3f); pose+tip should compose" % tip.x)
		return false
	return true


# Per-particle stiffness: one target at full stiffness should converge
# tighter than a parallel target at low stiffness. Verifies the
# pose_target_stiffnesses array is read per-entry, not flattened.
func test_pose_targets_per_particle_stiffness() -> bool:
	var t = _make_tentacle(12, 0.08)
	var stiff_idx: int = 4
	var soft_idx: int = 8
	var stiff_target := Vector3(0.1, 0, -0.32)
	var soft_target := Vector3(0.1, 0, -0.64)
	t.set_pose_targets(
		PackedInt32Array([stiff_idx, soft_idx]),
		PackedVector3Array([stiff_target, soft_target]),
		PackedFloat32Array([0.6, 0.05])
	)
	for _i in 60:
		t.get_solver().tick(1.0 / 60.0)
	var positions: PackedVector3Array = t.get_particle_positions()
	var stiff_err: float = (positions[stiff_idx] - stiff_target).length()
	var soft_err: float = (positions[soft_idx] - soft_target).length()
	# Stiff converges tighter than soft by at least 1.5×. The threshold
	# is moderate because pose-pulls now run *before* the distance
	# constraint each iteration (so high `bending_stiffness` /
	# `distance_stiffness` settings remain visible), which damps the
	# raw stiffness ratio. Pre-reorder this gap was 3-4×.
	if stiff_err * 1.5 > soft_err:
		push_error("stiffness gradient not respected: stiff_err=%.4f vs soft_err=%.4f"
				% [stiff_err, soft_err])
		return false
	return true


# --- helpers ---------------------------------------------------------------

static func _residual(p_t: Object, p_indices: PackedInt32Array,
		p_positions: PackedVector3Array) -> float:
	var positions: PackedVector3Array = p_t.get_particle_positions()
	var sum: float = 0.0
	for k in p_indices.size():
		var idx: int = p_indices[k]
		sum += (positions[idx] - p_positions[k]).length()
	return sum
