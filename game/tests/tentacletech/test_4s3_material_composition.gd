extends SceneTree

const _TentacleCollisionMaterial = preload("res://addons/tentacletech/scripts/collision/tentacle_collision_material.gd")
const _TentacleSurfaceTag = preload("res://addons/tentacletech/scripts/collision/tentacle_surface_tag.gd")

# Slice 4S.3 — per-collider friction material composition (2026-05-12).
# Direct port of Obi `Resources/Compute/CollisionMaterial.cginc:33-90`
# restricted to friction.
#
# Three sub-tests:
#
# 1. Analytic combine sweep: for each of the 4 modes
#    (Average/Min/Multiply/Max), set up a known
#    (mu_s_body, mu_k_body, body_combine) triple and verify the resulting
#    (mu_s_composed, mu_k_composed) matches the cginc formula against a
#    hand-computed reference. Tentacle implicit is composed as
#    (mu_s_tentacle, mu_k_tentacle, AVERAGE=0). max(AVERAGE, body_combine)
#    = body_combine, so the body's mode picks the formula every time.
# 2. Behavioural side-by-side: two `StaticBody3D`s tagged slippery
#    (mu_s = 0.05) vs sticky (mu_s = 1.8), driven by an identical
#    tentacle dragged horizontally. Tangential drift differs in the
#    expected direction.
# 3. Fallback test: no-tag body (current behaviour) → solver's
#    `friction_applied` accumulator matches the pre-4S.3 per-tentacle
#    path bit-for-bit when the materials sibling is never called.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_4s3_material_composition.gd

const ANALYTIC_TOL := 1e-6


var _ran: bool = false


func _process(_d: float) -> bool:
	if not _ran:
		_ran = true
		_run()
	return false


func _run() -> void:
	if not ClassDB.class_exists("PBDSolver"):
		push_error("[FAIL] tentacletech extension not loaded (PBDSolver missing)")
		quit(2)
		return
	if not ClassDB.class_exists("Tentacle"):
		push_error("[FAIL] tentacletech extension not loaded (Tentacle missing)")
		quit(2)
		return

	var passed: int = 0
	var failed: int = 0

	for test_name in [
		"test_compose_average",
		"test_compose_min",
		"test_compose_multiply",
		"test_compose_max",
		"test_compose_body_mode_wins_against_average_tentacle",
		"test_behavioural_slippery_vs_sticky",
		"test_fallback_no_materials_preserves_per_tentacle_path",
	]:
		var result: Dictionary = call(test_name)
		if result.get("pass", false):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			print("[FAIL] %s: %s" % [test_name, result.get("message", "")])
			failed += 1

	print("\n4S.3 material composition: %d/%d passed" % [passed, passed + failed])
	if failed > 0:
		quit(2)
	else:
		quit(0)


# -------------------- analytic helpers --------------------

const AVERAGE := 0
const MIN := 1
const MULTIPLY := 2
const MAX_MODE := 3


# Hand-computed reference per cginc:39-64. Same formula picks both scalars.
func _ref(mode: int, a_s: float, a_k: float, b_s: float, b_k: float) -> Vector2:
	if mode == MIN:
		return Vector2(min(a_s, b_s), min(a_k, b_k))
	if mode == MULTIPLY:
		return Vector2(a_s * b_s, a_k * b_k)
	if mode == MAX_MODE:
		return Vector2(max(a_s, b_s), max(a_k, b_k))
	# AVERAGE / default
	return Vector2((a_s + b_s) * 0.5, (a_k + b_k) * 0.5)


# Drive the bound static. Tentacle implicit is (a_s, a_k, AVERAGE);
# body is (b_s, b_k, body_combine). max(AVERAGE, body_combine) picks
# body_combine so the body mode always wins.
func _compose(a_s: float, a_k: float, b_s: float, b_k: float, body_combine: int) -> Vector2:
	return PBDSolver.compose_friction_materials(
		a_s, a_k, AVERAGE,
		b_s, b_k, body_combine,
	)


func _close(got: Vector2, want: Vector2, tol: float) -> bool:
	return absf(got.x - want.x) <= tol and absf(got.y - want.y) <= tol


# -------------------- analytic tests --------------------

func test_compose_average() -> Dictionary:
	# AVERAGE: composed = (a + b) × 0.5 per cginc:43-45.
	var triples := [
		[0.4, 0.3, 0.6, 0.5],
		[0.0, 0.0, 1.0, 0.8],
		[1.5, 1.2, 0.1, 0.05],
	]
	var max_err := 0.0
	for t in triples:
		var got := _compose(t[0], t[1], t[2], t[3], AVERAGE)
		var want := _ref(AVERAGE, t[0], t[1], t[2], t[3])
		var err := maxf(absf(got.x - want.x), absf(got.y - want.y))
		max_err = maxf(max_err, err)
		if not _close(got, want, ANALYTIC_TOL):
			return {"pass": false, "message": "AVERAGE got %s want %s (triple %s)" % [got, want, t]}
	print("        AVERAGE worst |err| = %.10f" % max_err)
	return {"pass": true}


func test_compose_min() -> Dictionary:
	# MIN: composed = min(a, b) per cginc:49-51.
	var triples := [
		[0.4, 0.3, 0.6, 0.5],
		[1.0, 0.8, 0.2, 0.05],
		[0.0, 0.0, 0.5, 0.4],
	]
	var max_err := 0.0
	for t in triples:
		var got := _compose(t[0], t[1], t[2], t[3], MIN)
		var want := _ref(MIN, t[0], t[1], t[2], t[3])
		var err := maxf(absf(got.x - want.x), absf(got.y - want.y))
		max_err = maxf(max_err, err)
		if not _close(got, want, ANALYTIC_TOL):
			return {"pass": false, "message": "MIN got %s want %s (triple %s)" % [got, want, t]}
	print("        MIN worst |err| = %.10f" % max_err)
	return {"pass": true}


func test_compose_multiply() -> Dictionary:
	# MULTIPLY: composed = a × b per cginc:55-57.
	var triples := [
		[0.5, 0.4, 0.6, 0.5],
		[1.2, 1.0, 0.8, 0.6],
		[0.0, 0.0, 1.0, 1.0],
	]
	var max_err := 0.0
	for t in triples:
		var got := _compose(t[0], t[1], t[2], t[3], MULTIPLY)
		var want := _ref(MULTIPLY, t[0], t[1], t[2], t[3])
		var err := maxf(absf(got.x - want.x), absf(got.y - want.y))
		max_err = maxf(max_err, err)
		if not _close(got, want, ANALYTIC_TOL):
			return {"pass": false, "message": "MULTIPLY got %s want %s (triple %s)" % [got, want, t]}
	print("        MULTIPLY worst |err| = %.10f" % max_err)
	return {"pass": true}


func test_compose_max() -> Dictionary:
	# MAX: composed = max(a, b) per cginc:61-63.
	var triples := [
		[0.4, 0.3, 0.6, 0.5],
		[1.0, 0.8, 0.2, 0.05],
		[0.0, 0.0, 0.5, 0.4],
	]
	var max_err := 0.0
	for t in triples:
		var got := _compose(t[0], t[1], t[2], t[3], MAX_MODE)
		var want := _ref(MAX_MODE, t[0], t[1], t[2], t[3])
		var err := maxf(absf(got.x - want.x), absf(got.y - want.y))
		max_err = maxf(max_err, err)
		if not _close(got, want, ANALYTIC_TOL):
			return {"pass": false, "message": "MAX got %s want %s (triple %s)" % [got, want, t]}
	print("        MAX worst |err| = %.10f" % max_err)
	return {"pass": true}


func test_compose_body_mode_wins_against_average_tentacle() -> Dictionary:
	# Sanity check the rule that tentacle's implicit AVERAGE never
	# overrides a body's stronger mode. We hand-call the static with
	# tentacle = AVERAGE and body = MIN; verify the result equals
	# raw min(), not the average.
	var got := _compose(1.0, 0.8, 0.2, 0.1, MIN)
	# Per cginc:36, max(0, MIN=1) = MIN → result is min(...)
	var want := Vector2(0.2, 0.1)
	if not _close(got, want, ANALYTIC_TOL):
		return {"pass": false, "message": "expected MIN to win against AVERAGE, got %s want %s" % [got, want]}
	return {"pass": true}


# -------------------- behavioural + fallback --------------------

const DT := 1.0 / 60.0
const SETTLE_FRAMES := 240
const CHAIN_N := 12
const SEG_LEN := 0.05
const PART_R := 0.04
const ANCHOR_Y := 0.6


func _reset_root() -> void:
	for c in root.get_children():
		root.remove_child(c)
		c.free()


# Floor body matching test_collision_type4::_make_floor — 20×0.1×20 box
# at Y=0. Optionally attaches a TentacleSurfaceTag with given material.
func _make_floor_body(p_y: float, p_tag: bool, p_mu_s: float, p_mu_k: float, p_combine: int) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = Vector3(0, p_y, 0)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20, 0.1, 20)
	shape.shape = box
	body.add_child(shape)
	if p_tag:
		var mat: Resource = _TentacleCollisionMaterial.new()
		mat.set("static_friction", p_mu_s)
		mat.set("dynamic_friction", p_mu_k)
		mat.set("friction_combine", p_combine)
		var tag: Node = _TentacleSurfaceTag.new()
		tag.set("material", mat)
		body.add_child(tag)
	return body


# Anchor a chain over a floor body and let tilted gravity drag it
# tangentially. Pure gravity-driven friction interaction — no target
# pulls — matches test_collision_type4::test_friction_resists_lateral_drift.
# `support_in_contact = false` so the contact's normal_lambda accumulates
# (the friction cone is `μ × normal_lambda`; with support_in_contact the
# tangent-projected gravity step zeros normal_lambda → no cone).
func _drift_tentacle_under_tilted_gravity(p_floor: StaticBody3D, p_chain_x: float) -> Dictionary:
	var t: Node3D = ClassDB.instantiate("Tentacle")
	t.particle_count = CHAIN_N
	t.segment_length = SEG_LEN
	t.particle_collision_radius = PART_R
	t.position = Vector3(p_chain_x, ANCHOR_Y, 0.0)
	t.gravity = Vector3(2.0, -9.8, 0)
	t.environment_probe_distance = 5.0
	t.base_static_friction = 0.4
	t.kinetic_friction_ratio = 0.8
	t.tentacle_lubricity = 0.0
	t.support_in_contact = false
	t.bending_stiffness = 0.5
	root.add_child(t)
	root.add_child(p_floor)

	var tip_idx: int = CHAIN_N - 1
	for _i in SETTLE_FRAMES:
		t.tick(DT)

	var tip_end: Vector3 = t.to_global(t.get_solver().get_particle_position(tip_idx))
	return {
		"tip_end_x": tip_end.x,
		"drift_x": tip_end.x - p_chain_x,
	}


func test_behavioural_slippery_vs_sticky() -> Dictionary:
	# Two equivalent setups; combine modes selected to exaggerate the
	# composed-μ split:
	#   Slippery → mu_s = 0.0, combine = MIN (1).
	#              Composed = min(0.4, 0.0) = 0.0 → friction step's outer
	#              `μ_s > 0` gate is bypassed for tagged slots only when
	#              the per-slot path engages → slot's friction skipped
	#              (slot's μ_s <= 0 branch); chain slides freely.
	#   Sticky   → mu_s = 2.0, combine = MAX (3).
	#              Composed = max(0.4, 2.0) = 2.0 → huge static cone,
	#              chain stays pinned.
	# Tilted gravity 2.0 m/s² along +X provides the tangential drag.
	# Acceptance: slippery tip drifts further than sticky tip by ≥ 1 cm.
	# Pattern mirrors test_collision_type4::test_friction_resists_lateral_drift,
	# substituting per-collider tags + combine modes for the global
	# `tentacle_lubricity` knob.
	_reset_root()
	var floor_slippery := _make_floor_body(0.0, true, 0.0, 0.0, MIN)
	var slippery: Dictionary = _drift_tentacle_under_tilted_gravity(floor_slippery, 0.0)

	_reset_root()
	var floor_sticky := _make_floor_body(0.0, true, 2.0, 1.5, MAX_MODE)
	var sticky: Dictionary = _drift_tentacle_under_tilted_gravity(floor_sticky, 0.0)

	var slippery_drift: float = slippery["drift_x"]
	var sticky_drift: float = sticky["drift_x"]
	var delta: float = slippery_drift - sticky_drift
	print("    slippery tip x = %.6f m, sticky tip x = %.6f m, delta = %.6f m"
			% [slippery_drift, sticky_drift, delta])

	if delta < 0.01:
		return {"pass": false,
				"message": "expected slippery tip > sticky tip by ≥ 1 cm; slippery=%.6f m, sticky=%.6f m"
						% [slippery_drift, sticky_drift]}
	return {"pass": true}


func test_fallback_no_materials_preserves_per_tentacle_path() -> Dictionary:
	# Two parallel runs, same scene:
	#   Run A: no tag → solver takes per-tentacle fallback branch.
	#   Run B: tag with material values matching the tentacle implicit
	#          (mu_s = base × (1-lub), mu_k = mu_s × kinetic_ratio,
	#          combine = AVERAGE) → solver takes per-slot branch.
	# Both branches must produce numerically identical friction_applied
	# accumulator state (the fallback IS the per-tentacle path; the
	# per-slot path WITH matching values should arithmetically coincide).
	# Tolerance: 1e-5 absolute per slot.
	const BASE_MU_S := 0.5
	const KIN_RATIO := 0.8

	_reset_root()
	var floor_a := _make_floor_body(0.0, false, 0.0, 0.0, 0)
	var sample_a: PackedFloat32Array = _capture_friction_applied_after_drive(
			floor_a, BASE_MU_S, KIN_RATIO)

	_reset_root()
	var matching_mu_k := BASE_MU_S * KIN_RATIO
	var floor_b := _make_floor_body(0.0, true, BASE_MU_S, matching_mu_k, 0)  # combine = AVERAGE
	var sample_b: PackedFloat32Array = _capture_friction_applied_after_drive(
			floor_b, BASE_MU_S, KIN_RATIO)

	if sample_a.size() != sample_b.size():
		return {"pass": false,
				"message": "friction_applied snapshot size mismatch (A=%d, B=%d)"
						% [sample_a.size(), sample_b.size()]}

	var worst_err := 0.0
	var max_mag := 0.0
	for i in sample_a.size():
		var d := absf(sample_a[i] - sample_b[i])
		if d > worst_err:
			worst_err = d
		var m := absf(sample_a[i])
		if m > max_mag:
			max_mag = m
	print("    fallback vs tagged-with-tentacle-implicit: worst |Δ| = %.10f over %d floats; max |friction_applied| = %.6f"
			% [worst_err, sample_a.size(), max_mag])
	if max_mag < 1e-6:
		return {"pass": false,
				"message": "friction_applied accumulator is all-zero; bit-equivalence assertion vacuous"}
	if worst_err > 1e-5:
		return {"pass": false,
				"message": "expected fallback path bit-equivalent to per-slot path with matching μ; worst |Δ| = %f" % worst_err}
	return {"pass": true}


# Helper: settle under tilted gravity (forces tangential motion → the
# friction step accumulates non-zero `friction_applied` per slot).
# Returns the accumulator as a flat PackedFloat32Array for slot-level
# bit comparison between fallback and per-slot paths.
func _capture_friction_applied_after_drive(p_floor: StaticBody3D, p_mu_s: float, p_kin_ratio: float) -> PackedFloat32Array:
	var t: Node3D = ClassDB.instantiate("Tentacle")
	t.particle_count = CHAIN_N
	t.segment_length = SEG_LEN
	t.particle_collision_radius = PART_R
	t.position = Vector3(0.0, ANCHOR_Y, 0.0)
	t.gravity = Vector3(2.0, -9.8, 0)
	t.environment_probe_distance = 5.0
	t.base_static_friction = p_mu_s
	t.kinetic_friction_ratio = p_kin_ratio
	t.tentacle_lubricity = 0.0
	t.support_in_contact = false
	t.bending_stiffness = 0.5
	root.add_child(t)
	root.add_child(p_floor)

	for _i in SETTLE_FRAMES:
		t.tick(DT)

	# friction_applied is a PackedVector3Array of size N × MAX_CONTACTS;
	# flatten to floats for slot-level comparison.
	var solver: RefCounted = t.get_solver()
	var fa: PackedVector3Array = solver.get_environment_friction_applied()
	var out := PackedFloat32Array()
	out.resize(fa.size() * 3)
	for i in fa.size():
		out[i * 3 + 0] = fa[i].x
		out[i * 3 + 1] = fa[i].y
		out[i * 3 + 2] = fa[i].z
	return out
