extends SceneTree

# Slice 4S.1 — symplectic Euler integration tests.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_symplectic_euler.gd
#
# Coverage:
#   1. Free-fall velocity invariance under N substeps. v_N = g·outer_dt
#      regardless of N ∈ {1, 2, 4, 8}. THIS is the symplectic Euler win.
#   2. Free-fall position trends toward the true ½·g·dt² as N→∞. At finite
#      N we get x = (N+1)/(2N) × g·dt² — NOT invariant, but converging.
#      Documented as a spec divergence: the slice prompt expected position
#      invariance under N substeps, which only velocity-Verlet provides.
#   3. Round-trip: set velocity = (1,0,0), no gravity, single tick: the
#      particle moves by (1,0,0) × dt, finalize recomputes velocity ≈ 1.0
#      from the position delta.
#   4. External `set_particle_position` zeroes the explicit velocity (so a
#      large external displacement doesn't synthesize a huge velocity at
#      end-of-finalize).

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
	var passed := 0
	var failed := 0
	for test_name in [
		"test_freefall_velocity_invariant_under_substeps",
		"test_freefall_position_converges_with_substeps",
		"test_explicit_velocity_round_trip",
		"test_set_particle_position_zeroes_velocity",
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


func _make_tentacle(p_substep: int) -> Node3D:
	var t: Node3D = ClassDB.instantiate("Tentacle")
	t.particle_count = 4
	t.segment_length = 0.05
	t.particle_collision_radius = 0.01
	t.position = Vector3.ZERO
	t.gravity = Vector3(0, -9.8, 0)
	t.environment_probe_distance = 0.0  # disable contact probe
	t.bending_stiffness = 0.0  # no chain coupling
	t.distance_stiffness = 0.0  # no distance constraint pull
	t.damping = 1.0  # no damping
	t.contact_velocity_damping = 0.0
	t.sleep_threshold = 0.0
	t.substep_count = p_substep
	t.target_velocity_max = 0.0  # disable rate limit (no targets in test anyway)
	root.add_child(t)
	return t


# 1. Free-fall velocity invariance: v after one outer dt should equal
# g·dt regardless of substep_count. This is the symplectic Euler property
# the brief flagged.
func test_freefall_velocity_invariant_under_substeps() -> bool:
	var expected_v: float = 9.8 * DT  # 0.1633 m/s
	var tolerance: float = 1e-4
	for sub in [1, 2, 4]:
		_reset_root()
		var t = _make_tentacle(sub)
		# Pin all but particle 1 so chain coupling can't affect the fall.
		# Use solver direct accessors to avoid Tentacle setter side effects.
		var solver = t.get_solver()
		for i in t.particle_count:
			solver.set_particle_inv_mass(i, 0.0)
		solver.set_particle_inv_mass(1, 1.0)
		# Reset position + force the chain to start at rest.
		solver.set_particle_position(1, Vector3.ZERO)
		# Run one outer tick.
		t.tick(DT)
		# Velocity snapshot.
		var v_arr: PackedVector3Array = solver.get_particle_velocities()
		var v: Vector3 = v_arr[1]
		# Expected: v ≈ (0, -9.8, 0) × DT magnitude (downward).
		var v_mag: float = -v.y
		if absf(v_mag - expected_v) > tolerance:
			push_error(("substep_count=%d: velocity %.6f, expected %.6f (tol %.6f) — "
					+ "symplectic Euler velocity invariance broken")
					% [sub, v_mag, expected_v, tolerance])
			return false
	return true


# 2. Position converges to true ½·g·dt² as substep count grows. At N=1
# we get g·dt² (over by 2×); at N→∞ we get ½·g·dt². Documents the spec
# divergence — position is NOT invariant across N, but it DOES converge
# toward the analytic solution.
func test_freefall_position_converges_with_substeps() -> bool:
	var true_position: float = 0.5 * 9.8 * DT * DT  # 1.36e-3 m
	var subs: Array = [1, 2, 4]
	var x_vals: PackedFloat64Array = PackedFloat64Array()
	x_vals.resize(subs.size())
	for k in subs.size():
		_reset_root()
		var t = _make_tentacle(subs[k])
		var solver = t.get_solver()
		for i in t.particle_count:
			solver.set_particle_inv_mass(i, 0.0)
		solver.set_particle_inv_mass(1, 1.0)
		solver.set_particle_position(1, Vector3.ZERO)
		t.tick(DT)
		var pos: Vector3 = solver.get_particle_position(1)
		x_vals[k] = -pos.y
	var fmt := "    [4S.1 free-fall position converges] true=%.6f  N=1: %.6f  N=2: %.6f  N=4: %.6f"
	print(fmt % [true_position, float(x_vals[0]), float(x_vals[1]),
			float(x_vals[2])])
	# Substepping should monotonically reduce the over-shoot toward the
	# true value (each higher N closer to truth than the previous).
	var prev_err: float = INF
	for k in subs.size():
		var err: float = absf(float(x_vals[k]) - true_position)
		if k > 0 and err > prev_err:
			var msg := "substep_count=%d position error %.6f > previous %.6f — expected monotonic convergence"
			push_error(msg % [int(subs[k]), err, prev_err])
			return false
		prev_err = err
	# Theoretical expectation: x_N = (N+1)/(2N) × g·dt² (4S.1 spec
	# divergence). N=1: g·dt² (2×true). N=4: 5/8·g·dt² (1.25×true).
	# Tolerance 1e-5 m absorbs float32 round-off across N substeps.
	for k in subs.size():
		var sub: int = int(subs[k])
		var expected: float = (float(sub + 1) / (2.0 * float(sub))) * 9.8 * DT * DT
		var err: float = absf(float(x_vals[k]) - expected)
		if err > 1e-5:
			var msg := "substep_count=%d position %.6f doesn't match symplectic Euler formula (N+1)/(2N)·g·dt² = %.6f (err %.6f)"
			push_error(msg % [sub, float(x_vals[k]), expected, err])
			return false
	return true


# 3. Round-trip: set particle's velocity directly (via solver test hook),
# disable gravity, run one tick. Particle should move by velocity × dt;
# finalize should recompute velocity ≈ original.
func test_explicit_velocity_round_trip() -> bool:
	_reset_root()
	var t = _make_tentacle(1)
	t.gravity = Vector3.ZERO  # no gravity → velocity preserved
	var solver = t.get_solver()
	for i in t.particle_count:
		solver.set_particle_inv_mass(i, 0.0)
	solver.set_particle_inv_mass(1, 1.0)
	solver.set_particle_position(1, Vector3.ZERO)
	# set_particle_position zeroed velocity. Need to inject velocity via
	# set_particle_velocity (added as part of 4S.1 plumbing for tests).
	if not solver.has_method("set_particle_velocity"):
		push_error("solver missing set_particle_velocity — required for 4S.1 round-trip test")
		return false
	solver.set_particle_velocity(1, Vector3(1.0, 0.0, 0.0))
	t.tick(DT)
	var pos: Vector3 = solver.get_particle_position(1)
	var v_arr: PackedVector3Array = solver.get_particle_velocities()
	var v: Vector3 = v_arr[1]
	# Expected: position += velocity × dt = (1·DT, 0, 0).
	if absf(pos.x - DT) > 1e-5:
		push_error("expected pos.x=%.6f, got %.6f" % [DT, pos.x])
		return false
	# Velocity should still be ≈ 1.0 (no gravity, no damping=1.0, no contacts).
	if absf(v.x - 1.0) > 1e-3:
		push_error("expected vel.x≈1.0 after no-gravity tick, got %.6f" % v.x)
		return false
	return true


# 4. External `set_particle_position` zeroes the velocity field so a
# large external displacement doesn't manifest as a huge synthesized
# velocity at end-of-finalize. Without this guard, an orifice "snap"
# would kick the chain on the next predict.
func test_set_particle_position_zeroes_velocity() -> bool:
	_reset_root()
	var t = _make_tentacle(1)
	t.gravity = Vector3.ZERO
	var solver = t.get_solver()
	for i in t.particle_count:
		solver.set_particle_inv_mass(i, 0.0)
	solver.set_particle_inv_mass(1, 1.0)
	# Establish a non-zero velocity by ticking with gravity, then snap.
	t.gravity = Vector3(0, -9.8, 0)
	for _i in 5:
		t.tick(DT)
	var v_arr_before: PackedVector3Array = solver.get_particle_velocities()
	if v_arr_before[1].y > -0.1:
		push_error("expected velocity to grow under 5 ticks of gravity, got %s" % str(v_arr_before[1]))
		return false
	# Now snap position via set_particle_position — should zero velocity.
	solver.set_particle_position(1, Vector3(5.0, 5.0, 5.0))
	var v_arr_after: PackedVector3Array = solver.get_particle_velocities()
	if v_arr_after[1].length() > 1e-6:
		push_error("set_particle_position should zero velocity, got %s" % str(v_arr_after[1]))
		return false
	return true
