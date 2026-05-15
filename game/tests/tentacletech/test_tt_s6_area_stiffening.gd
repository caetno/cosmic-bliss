extends SceneTree

# Slice TT-S6 — Retire `OrificeBusy` boolean reject; replace with
# area-stiffening force scaling against active EI count (§6.5).
#
# Verifies the new area-stiffening mechanism:
#   1. OrificeProfile.area_stiffening_per_ei default = 0.5
#   2. Loop.area_stiffening_per_ei default = 0.5
#   3. compute_effective_area_compliance(loop, dt, 0) == area_compliance × dt²
#   4. compute_effective_area_compliance(loop, dt, N) == (area_compliance × dt²) / (1 + k × N)
#   5. Setter clamps negative stiffening to 0
#   6. Stiffening accumulates monotonically with EI count
#
# Run:
#   godot --path game --headless --script res://tests/tentacletech/test_tt_s6_area_stiffening.gd

const _OrificeProfile = preload("res://addons/tentacletech/scripts/resources/orifice_profile.gd")

const DEFAULT_AREA_COMPLIANCE := 1e-4
const DEFAULT_STIFFENING := 0.5
const TEST_DT := 1.0 / 60.0

var _ran: bool = false


func _process(_d: float) -> bool:
	if not _ran:
		_ran = true
		_run()
	return false


func _run() -> void:
	if not ClassDB.class_exists("Orifice"):
		push_error("[FAIL] tentacletech extension not loaded (Orifice missing)")
		quit(2)
		return

	var passed: int = 0
	var failed: int = 0
	for test_name in [
		"test_profile_default_stiffening",
		"test_loop_default_stiffening",
		"test_effective_compliance_no_eis",
		"test_effective_compliance_scales_with_eis",
		"test_setter_clamps_negative",
		"test_monotonic_with_count",
		"test_per_loop_stiffening_independent",
	]:
		_reset_root()
		var result: Dictionary = call(test_name)
		if result.get("pass", false):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			print("[FAIL] %s: %s" % [test_name, result.get("message", "")])
			failed += 1

	print("\nTT-S6 area stiffening: %d/%d passed" % [passed, passed + failed])
	quit(0 if failed == 0 else 2)


func _reset_root() -> void:
	for c in root.get_children():
		root.remove_child(c)
		c.free()


# Helper: build an orifice with one rim loop of N=8 default-radius particles.
func _make_orifice() -> Node3D:
	var o: Node3D = ClassDB.instantiate("Orifice")
	o.name = "TestOrifice"
	root.add_child(o)
	var positions := PackedVector3Array()
	var seg_rest := PackedFloat32Array()
	var stiff_per_k := PackedFloat32Array()
	var n := 8
	var radius := 0.05
	for i in n:
		var theta := TAU * float(i) / float(n)
		positions.append(Vector3(radius * cos(theta), 0, radius * sin(theta)))
		stiff_per_k.append(0.5)
	# Compute segment rest lengths.
	for i in n:
		var a: Vector3 = positions[i]
		var b: Vector3 = positions[(i + 1) % n]
		seg_rest.append((b - a).length())
	var target_area := PI * radius * radius
	o.add_rim_loop(positions, seg_rest, target_area,
			stiff_per_k, DEFAULT_AREA_COMPLIANCE, 1e-6)
	return o


# ─── Tests ─────────────────────────────────────────────────────────


func test_profile_default_stiffening() -> Dictionary:
	var p := _OrificeProfile.new()
	if absf(p.area_stiffening_per_ei - DEFAULT_STIFFENING) > 1e-6:
		return {"pass": false, "message": "default area_stiffening_per_ei = %.6f (expected %.6f)"
				% [p.area_stiffening_per_ei, DEFAULT_STIFFENING]}
	return {"pass": true}


func test_loop_default_stiffening() -> Dictionary:
	var o := _make_orifice()
	var got: float = o.get_loop_area_stiffening_per_ei(0)
	if absf(got - DEFAULT_STIFFENING) > 1e-6:
		return {"pass": false, "message": "loop default stiffening = %.6f (expected %.6f)"
				% [got, DEFAULT_STIFFENING]}
	return {"pass": true}


func test_effective_compliance_no_eis() -> Dictionary:
	var o := _make_orifice()
	# N=0 → stiffening factor = 1 → compliance = area_compliance / dt²
	# (XPBD convention — `dt2_inv` in the C++ formula).
	var got: float = o.compute_effective_area_compliance(0, TEST_DT, 0)
	var expected: float = DEFAULT_AREA_COMPLIANCE / (TEST_DT * TEST_DT)
	if absf(got - expected) / expected > 1e-4:
		return {"pass": false,
				"message": "N=0 compliance = %.10e (expected %.10e)" % [got, expected]}
	print("    N=0: compliance = %.10e (expected %.10e)" % [got, expected])
	return {"pass": true}


func test_effective_compliance_scales_with_eis() -> Dictionary:
	var o := _make_orifice()
	# Verify formula at N=1, 2, 3, 4.
	var base: float = DEFAULT_AREA_COMPLIANCE / (TEST_DT * TEST_DT)
	var worst_err := 0.0
	for n in [1, 2, 3, 4]:
		var expected: float = base / (1.0 + DEFAULT_STIFFENING * float(n))
		var got: float = o.compute_effective_area_compliance(0, TEST_DT, n)
		var err := absf(got - expected) / expected
		if err > worst_err:
			worst_err = err
		print("    N=%d: compliance = %.10e (expected %.10e)" % [n, got, expected])
	if worst_err > 1e-4:
		return {"pass": false, "message": "worst relative err = %.6e" % worst_err}
	return {"pass": true}


func test_setter_clamps_negative() -> Dictionary:
	var o := _make_orifice()
	o.set_loop_area_stiffening_per_ei(0, -0.5)
	var got: float = o.get_loop_area_stiffening_per_ei(0)
	if got != 0.0:
		return {"pass": false, "message": "negative input not clamped: got %.6f" % got}
	return {"pass": true}


func test_monotonic_with_count() -> Dictionary:
	var o := _make_orifice()
	# Effective compliance must shrink strictly as count grows (stiffer).
	var prev: float = INF
	for n in range(0, 6):
		var c: float = o.compute_effective_area_compliance(0, TEST_DT, n)
		if c >= prev:
			return {"pass": false,
					"message": "non-monotonic at N=%d: %.10e >= prev %.10e" % [n, c, prev]}
		prev = c
	return {"pass": true}


func test_per_loop_stiffening_independent() -> Dictionary:
	var o := _make_orifice()
	# Add a second loop and verify stiffening lives per-loop.
	var positions2 := PackedVector3Array()
	var seg2 := PackedFloat32Array()
	var stiff2 := PackedFloat32Array()
	var n2 := 8
	var r2 := 0.03
	for i in n2:
		var theta := TAU * float(i) / float(n2)
		positions2.append(Vector3(r2 * cos(theta), 0.01, r2 * sin(theta)))
		stiff2.append(0.5)
	for i in n2:
		var a: Vector3 = positions2[i]
		var b: Vector3 = positions2[(i + 1) % n2]
		seg2.append((b - a).length())
	o.add_rim_loop(positions2, seg2, PI * r2 * r2,
			stiff2, DEFAULT_AREA_COMPLIANCE, 1e-6)

	o.set_loop_area_stiffening_per_ei(0, 0.2)
	o.set_loop_area_stiffening_per_ei(1, 1.0)
	if absf(o.get_loop_area_stiffening_per_ei(0) - 0.2) > 1e-6:
		return {"pass": false, "message": "loop 0 stiffening not 0.2"}
	if absf(o.get_loop_area_stiffening_per_ei(1) - 1.0) > 1e-6:
		return {"pass": false, "message": "loop 1 stiffening not 1.0"}
	# At N=2 EIs:
	#   loop 0: base / (1 + 0.2 × 2) = base / 1.4
	#   loop 1: base / (1 + 1.0 × 2) = base / 3.0
	var c0: float = o.compute_effective_area_compliance(0, TEST_DT, 2)
	var c1: float = o.compute_effective_area_compliance(1, TEST_DT, 2)
	var base: float = DEFAULT_AREA_COMPLIANCE / (TEST_DT * TEST_DT)
	var expected_0: float = base / 1.4
	var expected_1: float = base / 3.0
	print("    loop 0 (k=0.2) N=2: %.10e (expected %.10e)" % [c0, expected_0])
	print("    loop 1 (k=1.0) N=2: %.10e (expected %.10e)" % [c1, expected_1])
	if absf(c0 - expected_0) / expected_0 > 1e-4:
		return {"pass": false, "message": "loop 0 compliance off"}
	if absf(c1 - expected_1) / expected_1 > 1e-4:
		return {"pass": false, "message": "loop 1 compliance off"}
	return {"pass": true}
