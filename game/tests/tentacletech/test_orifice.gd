extends SceneTree

# Phase-5 slice 5A — Orifice rim primitive unit tests.
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

const DT := 1.0 / 60.0
const ENTRY_AXIS := Vector3(0.0, 0.0, 1.0)


func _init() -> void:
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

func _get_particle_field(o: Node3D, loop: int, particle: int, field: String) -> Variant:
	var state: Array = o.get_rim_loop_state(loop)
	return state[particle][field]
