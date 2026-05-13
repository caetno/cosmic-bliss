extends SceneTree

# Slice 5F.A — canal centerline PBD chain solver tests (2026-05-13).
#
# Five tests exercise the C++ `CanalCenterlineSolver` end-to-end:
#
#   1. chain_at_rest_holds_zero_drift — straight-axis 12-particle
#      chain with zero gravity holds rest for 60 ticks; worst drift
#      < 1e-5 m.
#   2. pinned_endpoints_track_anchor_motion — sweeping the distal
#      anchor pulls the chain along; distal endpoint matches anchor
#      after settle.
#   3. gravity_droop_then_recover — horizontal chain sags under
#      gravity_scale=1.0, recovers when gravity goes to 0.
#   4. bending_resists_kink — initialising with a laterally-displaced
#      interior particle, the chain pulls back toward straight under
#      bending stiffness.
#   5. tick_no_op_when_inactive — `Canal.tick(dt)` early-returns
#      while `is_inactive()` is true (5F.A default).
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_5fa_centerline_chain.gd

const _CanalParameters = preload("res://addons/tentacletech/scripts/resources/canal_parameters.gd")
const _Canal = preload("res://addons/tentacletech/scripts/canal/canal.gd")

const DT := 1.0 / 60.0
const M := 12  # default centerline particle count
const CHAIN_LENGTH_M := 0.4  # straight-axis chain, 0.4 m end-to-end

var _ran: bool = false


func _process(_d: float) -> bool:
	if not _ran:
		_ran = true
		_run()
	return false


func _run() -> void:
	if not ClassDB.class_exists("CanalCenterlineSolver"):
		push_error("[FAIL] tentacletech extension not loaded (CanalCenterlineSolver missing)")
		quit(2)
		return

	var passed: int = 0
	var failed: int = 0
	for test_name in [
		"test_chain_at_rest_holds_zero_drift",
		"test_pinned_endpoints_track_anchor_motion",
		"test_gravity_droop_then_recover",
		"test_bending_resists_kink",
		"test_tick_no_op_when_inactive",
	]:
		_reset_root()
		var result: Dictionary = call(test_name)
		if result.get("pass", false):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			print("[FAIL] %s: %s" % [test_name, result.get("message", "")])
			failed += 1

	print("\n5F.A centerline chain: %d/%d passed" % [passed, passed + failed])
	quit(0 if failed == 0 else 2)


func _reset_root() -> void:
	for c in root.get_children():
		root.remove_child(c)
		c.free()


# ─── Helpers ───────────────────────────────────────────────────────


func _straight_rest_positions(p_n: int, p_length: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(p_n)
	for i in p_n:
		var t := float(i) / float(p_n - 1)
		out[i] = Vector3(t * p_length, 0, 0)
	return out


# Endpoint inv_mass = 0 (pinned), interior inv_mass = 1.0. Mirrors the
# wiring `Canal._ensure_centerline_chain` lays down in production.
func _default_inv_mass(p_n: int) -> PackedFloat32Array:
	var im := PackedFloat32Array()
	im.resize(p_n)
	for i in p_n:
		im[i] = 0.0 if (i == 0 or i == p_n - 1) else 1.0
	return im


func _make_solver(p_rest: PackedVector3Array) -> RefCounted:
	var solver: RefCounted = ClassDB.instantiate("CanalCenterlineSolver")
	solver.configure(p_rest, _default_inv_mass(p_rest.size()))
	solver.set_anchors(p_rest[0], p_rest[p_rest.size() - 1])
	# Default tunables — same defaults the solver bakes in, made
	# explicit here so the test reads top-to-bottom.
	solver.set_iterations(8)
	solver.set_bending_stiffness(0.5)
	solver.set_damping(0.05)
	solver.set_gravity_scale(0.0)
	solver.set_gravity_vector(Vector3(0, -9.81, 0))
	return solver


# ─── Test 1: rest pose holds across 60 ticks ───────────────────────


func test_chain_at_rest_holds_zero_drift() -> Dictionary:
	var rest := _straight_rest_positions(M, CHAIN_LENGTH_M)
	var solver := _make_solver(rest)
	for _i in 60:
		solver.tick(DT)
	var positions: PackedVector3Array = solver.get_positions_snapshot()
	var worst := 0.0
	for i in M:
		var err := (positions[i] - rest[i]).length()
		if err > worst:
			worst = err
	print("    worst rest drift after 60 ticks: %.10f m" % worst)
	if worst > 1e-5:
		return {"pass": false,
				"message": "rest drift %.10f m exceeds 1e-5 m" % worst}
	return {"pass": true}


# ─── Test 2: distal anchor sweep ───────────────────────────────────


func test_pinned_endpoints_track_anchor_motion() -> Dictionary:
	var rest := _straight_rest_positions(M, CHAIN_LENGTH_M)
	var solver := _make_solver(rest)
	# Sweep distal anchor by +0.1 m along chain axis over 10 ticks,
	# then hold for 20 ticks to let the chain settle. Total length
	# grows from 0.4 m to 0.5 m.
	var step := 0.01
	for k in 10:
		var distal := Vector3(CHAIN_LENGTH_M + step * float(k + 1), 0, 0)
		solver.set_anchors(rest[0], distal)
		solver.tick(DT)
	# Hold and let it settle.
	var final_distal := Vector3(CHAIN_LENGTH_M + 0.1, 0, 0)
	for _i in 20:
		solver.set_anchors(rest[0], final_distal)
		solver.tick(DT)
	var positions: PackedVector3Array = solver.get_positions_snapshot()
	# Distal endpoint must match anchor exactly (it's pinned each iter).
	var distal_err := (positions[M - 1] - final_distal).length()
	# Interior particles should sit along the (slightly stretched)
	# straight line; some bending drift is expected.
	var worst_interior_lat := 0.0
	for i in range(1, M - 1):
		# Y/Z drift (lateral to the axis) is the failure mode to guard.
		var lat: float = sqrt(positions[i].y * positions[i].y
				+ positions[i].z * positions[i].z)
		if lat > worst_interior_lat:
			worst_interior_lat = lat
	print("    distal anchor err = %.10f m; worst interior lateral drift = %.6f m"
			% [distal_err, worst_interior_lat])
	if distal_err > 1e-4:
		return {"pass": false,
				"message": "distal anchor missed: err %.6f m" % distal_err}
	if worst_interior_lat > 5e-3:
		return {"pass": false,
				"message": "interior lateral drift too large: %.6f m" % worst_interior_lat}
	return {"pass": true}


# ─── Test 3: gravity droop + recovery ──────────────────────────────


func test_gravity_droop_then_recover() -> Dictionary:
	var rest := _straight_rest_positions(M, CHAIN_LENGTH_M)
	var solver := _make_solver(rest)
	solver.set_gravity_scale(1.0)
	for _i in 120:
		solver.tick(DT)
	var positions: PackedVector3Array = solver.get_positions_snapshot()
	var middle := positions[M / 2]
	var droop := -middle.y  # gravity is -Y; chain sags to negative Y
	print("    middle droop after 120 ticks @ g=1: %.6f m" % droop)
	if droop < 0.01:
		return {"pass": false,
				"message": "expected droop >= 0.01 m, got %.6f m" % droop}

	# Now turn gravity off and let it recover.
	solver.set_gravity_scale(0.0)
	for _i in 120:
		solver.tick(DT)
	positions = solver.get_positions_snapshot()
	var recover_worst := 0.0
	for i in M:
		var err := (positions[i] - rest[i]).length()
		if err > recover_worst:
			recover_worst = err
	print("    worst recovery drift after 120 ticks @ g=0: %.10f m" % recover_worst)
	if recover_worst > 1e-3:
		return {"pass": false,
				"message": "expected recovery within 1e-3 m, got %.6f m" % recover_worst}
	return {"pass": true}


# ─── Test 4: bending resists kink ──────────────────────────────────


func test_bending_resists_kink() -> Dictionary:
	var rest := _straight_rest_positions(M, CHAIN_LENGTH_M)
	var solver := _make_solver(rest)
	# Manually kink particle M/2 laterally by 5 cm.
	var kink_idx := M / 2
	var kink_amount := 0.05
	var kinked := rest[kink_idx] + Vector3(0, kink_amount, 0)
	solver.set_particle_position(kink_idx, kinked)
	# Run 60 ticks with anchors held; bending should pull it back.
	for _i in 60:
		solver.tick(DT)
	var positions: PackedVector3Array = solver.get_positions_snapshot()
	var final_lat: float = absf(positions[kink_idx].y)
	var ratio := final_lat / kink_amount
	print("    bend test: imposed 5 cm kink → final lateral %.6f m (ratio %.4f)"
			% [final_lat, ratio])
	if ratio > 0.5:
		return {"pass": false,
				"message": "bending failed to halve kink: ratio %.4f (expected < 0.5)" % ratio}
	return {"pass": true}


# ─── Test 5: inactive Canal.tick() is a no-op ──────────────────────


func test_tick_no_op_when_inactive() -> Dictionary:
	# Build a Canal node, set up a parameters resource, manually wire
	# the substrate (skipping the full AutoBaker — we only need the
	# centerline chain).
	var canal := _Canal.new()
	var params := _CanalParameters.new()
	params.canal_name = StringName("test_inactive")
	params.centerline_particle_count = M
	canal.canal_parameters = params
	root.add_child(canal)

	var rest := _straight_rest_positions(M, CHAIN_LENGTH_M)
	canal._set_baked_centerline_rest_positions(rest)
	canal._set_baked_anchors(rest[0], rest[M - 1])
	var solver := canal._ensure_centerline_chain()
	if solver == null:
		return {"pass": false, "message": "_ensure_centerline_chain returned null"}
	if not canal.has_centerline_chain():
		return {"pass": false, "message": "has_centerline_chain() false after ensure"}
	# Confirm is_inactive() is true (5F.A default behavior).
	if not canal.is_inactive():
		return {"pass": false,
				"message": "Canal.is_inactive() expected true in 5F.A default"}
	# Drive Canal.tick(); should early-return without running the solver.
	# Confirm positions don't change across 10 ticks.
	var before: PackedVector3Array = canal.get_centerline_positions_snapshot()
	for _i in 10:
		canal.tick(DT)
	var after: PackedVector3Array = canal.get_centerline_positions_snapshot()
	var worst := 0.0
	for i in before.size():
		var err := (before[i] - after[i]).length()
		if err > worst:
			worst = err
	print("    worst position delta across 10 inactive ticks: %.12f m" % worst)
	if worst > 1e-9:
		return {"pass": false,
				"message": "expected zero motion when inactive, got worst delta %.12f m" % worst}
	# Sanity: tick_force should actually drive the solver.
	canal.tick_force(DT)
	var after_force: PackedVector3Array = canal.get_centerline_positions_snapshot()
	# Still at rest (no gravity, anchors unchanged), so positions
	# remain the same — but the call path executed.
	var rest_drift := 0.0
	for i in after_force.size():
		var e := (after_force[i] - rest[i]).length()
		if e > rest_drift:
			rest_drift = e
	if rest_drift > 1e-5:
		return {"pass": false,
				"message": "tick_force at rest induced drift %.10f m" % rest_drift}
	return {"pass": true}
