extends SceneTree

# PBD solver Phase-2 unit tests.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_solver.gd
#
# Acceptance per docs/architecture/TentacleTech_Architecture.md §3 + §13.
#
# Note on class lookup: when invoked via --script, the GDScript parser resolves
# identifiers before GDExtension classes are registered. We instantiate via
# ClassDB.

const DT := 1.0 / 60.0


func _init() -> void:
	if not ClassDB.class_exists("PBDSolver") or not ClassDB.class_exists("Tentacle"):
		push_error("[FAIL] tentacletech extension not loaded (PBDSolver/Tentacle missing)")
		quit(2)
		return

	var passed: int = 0
	var failed: int = 0

	for test_name in [
		"test_stability_under_gravity",
		"test_distance_constraint_convergence",
		"test_anchor_hardness",
		"test_target_pull_moves_tip",
		"test_volume_preservation",
		"test_asymmetry_decay_and_cap",
		"test_no_allocations_in_tick",
	]:
		if call(test_name):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			push_error("[FAIL] %s" % test_name)
			failed += 1

	print("\n%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


# ---------------------------------------------------------------------------

func _new_solver() -> Object:
	return ClassDB.instantiate("PBDSolver")


# Anchored 16-particle chain falling under gravity; after 240 ticks no NaN/Inf,
# all positions bounded ±100m, tip oscillates around a hanging equilibrium.
func test_stability_under_gravity() -> bool:
	var s: Object = _new_solver()
	s.initialize_chain(16, 0.1)
	s.set_gravity(Vector3(0, -9.8, 0))
	s.set_anchor(0, Transform3D())  # anchor at world origin

	for _i in 240:
		s.tick(DT)

	var n: int = s.get_particle_count()
	for i in n:
		var p: Vector3 = s.get_particle_position(i)
		if not _is_finite_v3(p):
			push_error("non-finite position at particle %d: %s" % [i, p])
			return false
		if absf(p.x) > 100.0 or absf(p.y) > 100.0 or absf(p.z) > 100.0:
			push_error("particle %d out of bounds: %s" % [i, p])
			return false

	# Tip should hang below the anchor; rest length × (n-1) = 1.5 m chain,
	# so a hanging chain reaches ~1.5 m below at most. Just sanity-check the
	# direction.
	var tip: Vector3 = s.get_particle_position(n - 1)
	if tip.y >= 0.0:
		push_error("tip not hanging below anchor (y=%f)" % tip.y)
		return false
	return true


# One segment stretched to 2× rest at start. After 4 iterations of one tick,
# max stretch error < 5%. After 60 ticks, < 0.1%.
func test_distance_constraint_convergence() -> bool:
	var s: Object = _new_solver()
	s.initialize_chain(8, 0.1)
	s.set_gravity(Vector3.ZERO)
	s.set_iteration_count(4)
	s.set_distance_stiffness(1.0)
	s.set_anchor(0, Transform3D())  # anchor base only

	# Manually displace particle 1 to stretch segment[0] to 2× rest.
	var rest: float = s.get_rest_length(0)
	var anchor: Vector3 = s.get_particle_position(0)
	s.set_particle_position(1, anchor + Vector3(0, 0, -2.0 * rest))

	s.tick(DT)
	var ratios: PackedFloat32Array = s.get_segment_stretch_ratios()
	var err_after_one: float = 0.0
	for r in ratios:
		err_after_one = max(err_after_one, absf(r - 1.0))
	if err_after_one > 0.05:
		push_error("after 1 tick max stretch error %f > 5%%" % err_after_one)
		return false

	for _i in 59:
		s.tick(DT)
	ratios = s.get_segment_stretch_ratios()
	var err_after_60: float = 0.0
	for r in ratios:
		err_after_60 = max(err_after_60, absf(r - 1.0))
	if err_after_60 > 0.001:
		push_error("after 60 ticks max stretch error %f > 0.1%%" % err_after_60)
		return false
	return true


# Apply gravity for 240 ticks; anchored particle's world position never
# deviates from configured origin by > 1e-5.
func test_anchor_hardness() -> bool:
	var s: Object = _new_solver()
	s.initialize_chain(16, 0.1)
	s.set_gravity(Vector3(0, -9.8, 0))
	var x := Transform3D(Basis(), Vector3(2.5, 1.0, -3.0))
	s.set_anchor(0, x)

	for _i in 240:
		s.tick(DT)
		var pos: Vector3 = s.get_particle_position(0)
		var dev: float = pos.distance_to(x.origin)
		if dev > 1e-5:
			push_error("anchor drift %e at t=%d" % [dev, _i])
			return false
	return true


# Anchor at origin, target at (3, 0, 0), tip-pull stiffness 0.2; tick 240
# frames; tip x ends within 30% of 3.0.
func test_target_pull_moves_tip() -> bool:
	var s: Object = _new_solver()
	s.initialize_chain(16, 0.1)
	s.set_gravity(Vector3.ZERO)
	s.set_anchor(0, Transform3D())
	var tip_idx: int = s.get_particle_count() - 1
	s.set_target(tip_idx, Vector3(3.0, 0.0, 0.0), 0.2)

	for _i in 240:
		s.tick(DT)

	var tip: Vector3 = s.get_particle_position(tip_idx)
	# 30% of 3.0 → tip.x in [2.1, 3.0]. Damped oscillation may push slightly
	# past 3.0, so allow up to 3.9 on the upside and warn if beyond.
	if tip.x < 2.1 or tip.x > 3.9:
		push_error("tip x=%f, expected ~[2.1, 3.0]" % tip.x)
		return false
	return true


# 2-particle chain, rest length 1.0, both ends pinned. Squeeze to 0.5 →
# girth_scale ≥ 1.4. Stretch to 2.0 → girth_scale ≤ 0.71. Tolerance ±2%.
func test_volume_preservation() -> bool:
	# Squeeze case.
	var s: Object = _new_solver()
	s.initialize_chain(2, 1.0)
	s.set_gravity(Vector3.ZERO)
	s.set_iteration_count(1)
	s.set_distance_stiffness(0.0)  # Don't let distance projection undo our setup.
	# Pin both ends.
	s.set_particle_inv_mass(0, 0.0)
	s.set_particle_inv_mass(1, 0.0)
	s.set_particle_position(0, Vector3.ZERO)
	s.set_particle_position(1, Vector3(0.5, 0, 0))  # length 0.5, ratio 0.5

	s.tick(DT)
	var girth0: float = s.get_particle_girth_scale(0)
	var girth1: float = s.get_particle_girth_scale(1)
	# Expected √2 ≈ 1.4142. Tolerance ±2% → ≥ 1.386.
	if girth0 < 1.4 or girth1 < 1.4:
		push_error("squeeze girth_scale %f / %f < 1.4" % [girth0, girth1])
		return false

	# Stretch case.
	var s2: Object = _new_solver()
	s2.initialize_chain(2, 1.0)
	s2.set_gravity(Vector3.ZERO)
	s2.set_iteration_count(1)
	s2.set_distance_stiffness(0.0)
	s2.set_particle_inv_mass(0, 0.0)
	s2.set_particle_inv_mass(1, 0.0)
	s2.set_particle_position(0, Vector3.ZERO)
	s2.set_particle_position(1, Vector3(2.0, 0, 0))  # length 2.0, ratio 2.0

	s2.tick(DT)
	var g0: float = s2.get_particle_girth_scale(0)
	var g1: float = s2.get_particle_girth_scale(1)
	# Expected 1/√2 ≈ 0.7071. Tolerance ±2% → ≤ 0.7213.
	if g0 > 0.71 or g1 > 0.71:
		# Allow 2% slack: 0.7071 × 1.02 ≈ 0.7213
		if g0 > 0.7213 or g1 > 0.7213:
			push_error("stretch girth_scale %f / %f > 0.71+2%%" % [g0, g1])
			return false
	return true


# Asymmetry decay: set asymmetry = (0.4, 0); after 60 ticks magnitude < 0.05.
# Cap test: set asymmetry = (1.0, 0); after one tick magnitude ≤ 0.5.
func test_asymmetry_decay_and_cap() -> bool:
	# Decay test.
	var s: Object = _new_solver()
	s.initialize_chain(8, 0.1)
	s.set_gravity(Vector3.ZERO)
	s.set_anchor(0, Transform3D())
	s.set_particle_asymmetry(4, Vector2(0.4, 0.0))

	for _i in 60:
		s.tick(DT)
	var asym: Vector2 = s.get_particle_asymmetry(4)
	if asym.length() > 0.05:
		push_error("asymmetry magnitude %f after 60 ticks > 0.05" % asym.length())
		return false

	# Cap test — apply on every particle so smoothing can't dilute it.
	var s2: Object = _new_solver()
	s2.initialize_chain(8, 0.1)
	s2.set_gravity(Vector3.ZERO)
	s2.set_anchor(0, Transform3D())
	# Disable decay so the only thing keeping magnitude ≤ 0.5 is the clamp.
	s2.set_asymmetry_recovery_rate(0.0)
	for i in s2.get_particle_count():
		s2.set_particle_asymmetry(i, Vector2(1.0, 0.0))
	s2.tick(DT)
	for i in s2.get_particle_count():
		var a: Vector2 = s2.get_particle_asymmetry(i)
		# Tiny float slack on the cap.
		if a.length() > 0.5 + 1e-4:
			push_error("particle %d asymmetry magnitude %f > cap 0.5" % [i, a.length()])
			return false
	return true


# Smoke test: 1000 ticks of a 16-particle chain change static memory by < 1 KB.
# The platform allocator may move the baseline a little even without solver
# allocations, so we use a generous 1 KB threshold and skip on platforms where
# OS.get_static_memory_usage() is unavailable.
func test_no_allocations_in_tick() -> bool:
	if not OS.has_method("get_static_memory_usage"):
		print("  (skipped — OS.get_static_memory_usage unavailable)")
		return true

	var s: Object = _new_solver()
	s.initialize_chain(16, 0.1)
	s.set_gravity(Vector3(0, -9.8, 0))
	s.set_anchor(0, Transform3D())
	var tip_idx: int = s.get_particle_count() - 1
	s.set_target(tip_idx, Vector3(1, 1, 0), 0.1)
	# Warm-up: prime any caches and allocator quirks.
	for _i in 60:
		s.tick(DT)

	var before: int = OS.get_static_memory_usage()
	for _i in 1000:
		s.tick(DT)
	var after: int = OS.get_static_memory_usage()
	var delta: int = after - before
	if delta > 1024:
		push_error("static memory grew by %d bytes over 1000 ticks (> 1 KB)" % delta)
		return false
	return true


# ---------------------------------------------------------------------------

func _is_finite_v3(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)
