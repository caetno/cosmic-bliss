extends SceneTree

# Slice 5F.B.B — `tunnel_state` per-tick CPU integration tests (2026-05-15).
#
# Nine tests exercise the C++ `TunnelStateIntegrator`:
#
#   1. integrator_initialises_at_rest — 60 ticks with zero constriction,
#      no curvature; worst |dyn − rest| < 1e-5 m, plastic + damage flat.
#   2. constriction_zone_contracts_wall — one mid-canal zone at full
#      strength; cells inside settle below rest, cells far away stay at
#      rest. Falloff is smoothstep-shaped.
#   3. plastic_memory_accumulates_under_sustained_load — staged wall
#      perturbation held for many ticks; plastic_offset grows toward
#      plastic_max_offset (with the damage_plastic_gain expansion).
#   4. plastic_offset_recovers_when_load_removed — same setup; clearing
#      the perturbation triggers monotonic decay back toward 0.
#   5. damage_accumulates_when_overstretched — over-stretch a cell,
#      verify damage grows.
#   6. second_order_ringing_when_enabled — use_second_order_wall=true,
#      perturb wall, expect velocity-channel non-zero + wall overshoots.
#   7. first_order_no_overshoot — same perturbation, second-order off,
#      wall decays monotonically.
#   8. gpu_upload_matches_cpu_state — sample texture R-channel after a
#      tick, compare to snapshot.
#   9. friction_mult_responds_to_muscle_zones — friction_bonus + muscle
#      contribution show up on the fourth channel when in FRICTION_MULT.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_5fbB_tunnel_state.gd

const _CanalParameters = preload("res://addons/tentacletech/scripts/resources/canal_parameters.gd")
const _CanalConstrictionZone = preload("res://addons/tentacletech/scripts/resources/canal_constriction_zone.gd")
const _Canal = preload("res://addons/tentacletech/scripts/canal/canal.gd")

const DT := 1.0 / 60.0
const AXIAL := 16  # smaller than the 32 default; keeps test cheap
const SECTORS := 8
const REST_RADIUS := 0.05
const CHAIN_LENGTH_M := 0.4
const M := 12  # centerline particle count

var _ran: bool = false


func _process(_d: float) -> bool:
	if not _ran:
		_ran = true
		_run()
	return false


func _run() -> void:
	if not ClassDB.class_exists("TunnelStateIntegrator"):
		push_error("[FAIL] tentacletech extension not loaded (TunnelStateIntegrator missing)")
		quit(2)
		return
	if not ClassDB.class_exists("CanalCenterlineSolver"):
		push_error("[FAIL] tentacletech extension not loaded (CanalCenterlineSolver missing)")
		quit(2)
		return

	var passed: int = 0
	var failed: int = 0
	for test_name in [
		"test_integrator_initialises_at_rest",
		"test_constriction_zone_contracts_wall",
		"test_plastic_memory_accumulates_under_sustained_load",
		"test_plastic_offset_recovers_when_load_removed",
		"test_damage_accumulates_when_overstretched",
		"test_second_order_ringing_when_enabled",
		"test_first_order_no_overshoot",
		"test_gpu_upload_matches_cpu_state",
		"test_friction_mult_responds_to_muscle_zones",
	]:
		var result: Dictionary = call(test_name)
		if result.get("pass", false):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			print("[FAIL] %s: %s" % [test_name, result.get("message", "")])
			failed += 1

	print("\n5F.B.B tunnel_state integration: %d/%d passed" % [passed, passed + failed])
	quit(0 if failed == 0 else 2)


# ─── Fixture helpers ───────────────────────────────────────────────


# Build a fully-wired (centerline solver + integrator + texture) fixture
# at rest. Returns { "integrator": ..., "solver": ..., "texture": ...,
# "rest_radius": PackedFloat32Array }.
func _make_fixture(p_use_second_order: bool = false,
		p_fourth_mode: int = 0) -> Dictionary:
	# Straight chain along +X. Anchors at the two endpoints.
	var rest_positions := PackedVector3Array()
	rest_positions.resize(M)
	for i in M:
		var t := float(i) / float(M - 1)
		rest_positions[i] = Vector3(t * CHAIN_LENGTH_M, 0, 0)
	var inv_mass := PackedFloat32Array()
	inv_mass.resize(M)
	for i in M:
		inv_mass[i] = 0.0 if (i == 0 or i == M - 1) else 1.0

	var solver: RefCounted = ClassDB.instantiate("CanalCenterlineSolver")
	solver.configure(rest_positions, inv_mass)
	solver.set_anchors(rest_positions[0], rest_positions[M - 1])
	solver.set_iterations(8)
	solver.set_bending_stiffness(0.5)
	solver.set_damping(0.05)
	solver.set_gravity_scale(0.0)
	# Settle for a few ticks so basis_at + curvature_at are well-defined.
	for _i in 5:
		solver.tick(DT)

	var n_cells := AXIAL * SECTORS
	var rest_radius := PackedFloat32Array()
	rest_radius.resize(n_cells)
	for i in n_cells:
		rest_radius[i] = REST_RADIUS

	# Allocate a tunnel_state texture seeded at (rest, 0, 0, init).
	var img := Image.create(AXIAL, SECTORS, false, Image.FORMAT_RGBAF)
	var fourth_init := 1.0 if p_fourth_mode == 1 else 0.0
	for k in AXIAL:
		for j in SECTORS:
			img.set_pixel(k, j, Color(REST_RADIUS, 0.0, 0.0, fourth_init))
	var tex := ImageTexture.create_from_image(img)

	var integ: RefCounted = ClassDB.instantiate("TunnelStateIntegrator")
	# No constriction zones by default — tests opt in.
	integ.configure(AXIAL, SECTORS, rest_radius, tex, PackedFloat32Array())
	integ.set_centerline_solver(solver)
	integ.set_curvature_response_gain(0.0)
	integ.set_contraction_gain(1.0)
	integ.set_min_wall_radius(0.001)
	integ.set_wall_response_rate(10.0)
	integ.set_use_second_order_wall(p_use_second_order)
	integ.set_wall_acceleration_gain(5.0)
	integ.set_wall_damping(6.0)
	integ.set_plastic_params(0.05, 0.05, 0.005)
	integ.set_damage_params(0.001, 1.0, 0.5)
	integ.set_muscle_friction_gain(1.0)
	integ.set_fourth_channel_mode(p_fourth_mode)
	return {
		"integrator": integ,
		"solver": solver,
		"texture": tex,
		"rest_radius": rest_radius,
	}


# Flatten a single zone into the integrator's 5-float schema.
func _zone_pack(arc_s: float, half_w: float, max_contr: float,
		strength: float, friction_bonus: float = 0.0) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(5)
	out[0] = arc_s
	out[1] = half_w
	out[2] = max_contr
	out[3] = strength
	out[4] = friction_bonus
	return out


# ─── Test 1: at rest, the integrator holds rest values ─────────────


func test_integrator_initialises_at_rest() -> Dictionary:
	var fix := _make_fixture()
	var integ: RefCounted = fix["integrator"]
	for _i in 60:
		integ.tick(DT)
	var dyn: PackedFloat32Array = integ.get_dynamic_wall_radius_snapshot()
	var pla: PackedFloat32Array = integ.get_plastic_offset_snapshot()
	var dmg: PackedFloat32Array = integ.get_damage_snapshot()
	var worst_r := 0.0
	var worst_p := 0.0
	var worst_d := 0.0
	for i in dyn.size():
		var er := absf(dyn[i] - REST_RADIUS)
		if er > worst_r:
			worst_r = er
		if absf(pla[i]) > worst_p:
			worst_p = absf(pla[i])
		if absf(dmg[i]) > worst_d:
			worst_d = absf(dmg[i])
	print("    worst dyn=%.10f m, plastic=%.10f, damage=%.10f" % [worst_r, worst_p, worst_d])
	if worst_r > 1e-5:
		return {"pass": false, "message": "wall drift %.6f exceeds 1e-5" % worst_r}
	if worst_p > 1e-6:
		return {"pass": false, "message": "plastic drift %.6f exceeds 1e-6" % worst_p}
	if worst_d > 1e-6:
		return {"pass": false, "message": "damage drift %.6f exceeds 1e-6" % worst_d}
	return {"pass": true}


# ─── Test 2: constriction zone pulls wall in locally ───────────────


func test_constriction_zone_contracts_wall() -> Dictionary:
	var fix := _make_fixture()
	var integ: RefCounted = fix["integrator"]
	var solver: RefCounted = fix["solver"]
	var arc: float = solver.get_total_arc_length()
	# Single zone at mid-canal, half-width covers roughly 4 of 16 axial
	# cells (s_k spacing = arc / 15).
	var arc_mid := arc * 0.5
	var half_w := arc * 0.15
	var zone := _zone_pack(arc_mid, half_w, 1.0, 1.0)
	integ.update_constriction_zones(zone)
	for _i in 120:
		integ.tick(DT)
	var dyn: PackedFloat32Array = integ.get_dynamic_wall_radius_snapshot()
	# Pick the cell nearest mid-canal axially (any sector — angular
	# invariance in slice 5F.B.B because muscle field eval is stubbed).
	var mid_k := AXIAL / 2
	var mid_idx := mid_k * SECTORS + 0
	var mid_dyn: float = dyn[mid_idx]
	# Far-from-zone cell (axial cell 0).
	var far_idx := 0 * SECTORS + 0
	var far_dyn: float = dyn[far_idx]
	print("    mid-cell dyn=%.6f  far-cell dyn=%.6f (rest=%.6f)" % [mid_dyn, far_dyn, REST_RADIUS])
	if mid_dyn >= REST_RADIUS - 1e-4:
		return {"pass": false,
				"message": "mid cell should compress below rest; got %.6f vs rest %.6f" % [mid_dyn, REST_RADIUS]}
	if absf(far_dyn - REST_RADIUS) > 1e-3:
		return {"pass": false,
				"message": "far cell drifted from rest: %.6f vs %.6f" % [far_dyn, REST_RADIUS]}
	# Smoothstep falloff: cell halfway between mid and edge of zone should
	# compress LESS than mid cell but MORE than far cell.
	var halfway_s := arc_mid + half_w * 0.5
	# Convert that s back to k.
	var halfway_k := int(round(halfway_s / arc * float(AXIAL - 1)))
	halfway_k = clamp(halfway_k, 0, AXIAL - 1)
	var halfway_dyn: float = dyn[halfway_k * SECTORS + 0]
	if not (halfway_dyn > mid_dyn and halfway_dyn < REST_RADIUS):
		return {"pass": false,
				"message": "falloff shape wrong: mid=%.6f halfway=%.6f far=%.6f" % [
						mid_dyn, halfway_dyn, REST_RADIUS]}
	return {"pass": true}


# ─── Test 3: plastic accumulation under sustained over-stretch ─────


func test_plastic_memory_accumulates_under_sustained_load() -> Dictionary:
	var fix := _make_fixture()
	var integ: RefCounted = fix["integrator"]
	# Choose a single cell + perturb wall above rest each tick. Recover
	# rate must be zero for monotonic growth (defaults have recover=accum
	# which → net zero at the stretch=plastic equilibrium).
	integ.set_plastic_params(0.5, 0.0, 0.01)
	# Disable damage growth so the plastic cap stays at plastic_max_offset.
	integ.set_damage_params(0.0, 0.0, 0.0)
	var k := AXIAL / 2
	var j := 0
	var pre := []
	for tick in 200:
		# Force the dynamic wall radius high each tick (simulates a
		# tentacle keeping the wall stretched).
		integ.set_dynamic_wall_radius_for_test(k, j, REST_RADIUS + 0.02)
		integ.tick(DT)
		var p: PackedFloat32Array = integ.get_plastic_offset_snapshot()
		pre.append(p[k * SECTORS + j])
	# Monotonic non-decreasing.
	for i in range(1, pre.size()):
		if pre[i] < pre[i - 1] - 1e-7:
			return {"pass": false,
					"message": "plastic_offset went down at tick %d: %.8f → %.8f" % [
							i, pre[i - 1], pre[i]]}
	# Final value should be near plastic_max_offset (0.01).
	var final: float = pre[pre.size() - 1]
	print("    plastic_offset settled at %.6f (cap 0.01)" % final)
	if final < 0.005:
		return {"pass": false,
				"message": "plastic did not accumulate enough: %.6f" % final}
	if final > 0.011:
		return {"pass": false,
				"message": "plastic exceeded cap: %.6f > 0.01" % final}
	return {"pass": true}


# ─── Test 4: plastic recovery after load removed ───────────────────


func test_plastic_offset_recovers_when_load_removed() -> Dictionary:
	var fix := _make_fixture()
	var integ: RefCounted = fix["integrator"]
	integ.set_plastic_params(0.5, 0.0, 0.01)
	integ.set_damage_params(0.0, 0.0, 0.0)
	var k := AXIAL / 2
	var j := 0
	# Push the wall outward for 200 ticks so plastic_offset reaches its cap.
	for _t in 200:
		integ.set_dynamic_wall_radius_for_test(k, j, REST_RADIUS + 0.02)
		integ.tick(DT)
	var before: PackedFloat32Array = integ.get_plastic_offset_snapshot()
	var loaded: float = before[k * SECTORS + j]
	print("    plastic before recovery: %.6f" % loaded)
	if loaded < 1e-4:
		return {"pass": false,
				"message": "plastic never accumulated during load phase: %.6f" % loaded}
	# Now flip the recover rate up + accumulate to zero, let the wall
	# return to rest naturally. Plastic must decay.
	integ.set_plastic_params(0.0, 0.5, 0.01)
	for _t in 400:
		integ.tick(DT)
	var after: PackedFloat32Array = integ.get_plastic_offset_snapshot()
	var recovered: float = after[k * SECTORS + j]
	print("    plastic after recovery: %.6f (was %.6f)" % [recovered, loaded])
	if recovered >= loaded * 0.5:
		return {"pass": false,
				"message": "plastic did not decay: before=%.6f after=%.6f" % [loaded, recovered]}
	return {"pass": true}


# ─── Test 5: damage grows under over-stretch ───────────────────────


func test_damage_accumulates_when_overstretched() -> Dictionary:
	var fix := _make_fixture()
	var integ: RefCounted = fix["integrator"]
	# Inject a sustained zone strong enough that the *target* radius
	# exceeds rest — but constriction lowers, not raises, the target.
	# Damage is fed by `max(0, target - rest)`, so the only way to grow
	# damage is to inflate the wall via plastic or curvature_offset.
	# Easier path: bump damage_rate way up and stage plastic high via the
	# test setter feeding back into the target through `plastic_offset`.
	integ.set_plastic_params(1.0, 0.0, 0.02)
	integ.set_damage_params(1.0, 1.0, 0.5)
	var k := AXIAL / 2
	var j := 0
	for _t in 300:
		integ.set_dynamic_wall_radius_for_test(k, j, REST_RADIUS + 0.02)
		integ.tick(DT)
	var dmg: PackedFloat32Array = integ.get_damage_snapshot()
	var d: float = dmg[k * SECTORS + j]
	print("    damage at perturbed cell: %.6f" % d)
	if d <= 0.0:
		return {"pass": false, "message": "damage did not accumulate: %.6f" % d}
	# Untouched cell should stay near zero.
	var d_far: float = dmg[0]
	if d_far > 1e-4:
		return {"pass": false,
				"message": "damage leaked to untouched cell: %.6f" % d_far}
	return {"pass": true}


# ─── Test 6: second-order overshoots + velocity nonzero ────────────


func test_second_order_ringing_when_enabled() -> Dictionary:
	var fix := _make_fixture(true, 0)  # MODE_WALL_RADIAL_VELOCITY
	var integ: RefCounted = fix["integrator"]
	# Perturb a cell well above rest; with no constriction the target =
	# rest, so the wall should pull back toward rest, accelerate past it
	# (ringing), then damp.
	var k := AXIAL / 2
	var j := 0
	integ.set_dynamic_wall_radius_for_test(k, j, REST_RADIUS + 0.01)
	# Crank acceleration gain + lower damping so ringing is unmistakable.
	integ.set_wall_acceleration_gain(10.0)
	integ.set_wall_damping(2.0)
	var min_seen := INF
	var max_v := 0.0
	for _t in 120:
		integ.tick(DT)
		var dyn: PackedFloat32Array = integ.get_dynamic_wall_radius_snapshot()
		var fc: PackedFloat32Array = integ.get_fourth_channel_snapshot()
		var v: float = fc[k * SECTORS + j]
		if absf(v) > max_v:
			max_v = absf(v)
		var r: float = dyn[k * SECTORS + j]
		if r < min_seen:
			min_seen = r
	print("    second-order: max|v|=%.6f, min wall radius=%.6f (rest %.6f)" % [
			max_v, min_seen, REST_RADIUS])
	# Velocity channel must have been non-zero at some point.
	if max_v < 1e-4:
		return {"pass": false,
				"message": "wall_radial_velocity stayed at zero (max %.6f)" % max_v}
	# Overshoot: wall dipped below rest.
	if min_seen >= REST_RADIUS - 1e-5:
		return {"pass": false,
				"message": "no overshoot: min wall %.6f vs rest %.6f" % [min_seen, REST_RADIUS]}
	return {"pass": true}


# ─── Test 7: first-order monotonic decay, no overshoot ─────────────


func test_first_order_no_overshoot() -> Dictionary:
	var fix := _make_fixture(false, 1)  # FRICTION_MULT
	var integ: RefCounted = fix["integrator"]
	var k := AXIAL / 2
	var j := 0
	integ.set_dynamic_wall_radius_for_test(k, j, REST_RADIUS + 0.01)
	var prev := REST_RADIUS + 0.01
	for tick in 120:
		integ.tick(DT)
		var dyn: PackedFloat32Array = integ.get_dynamic_wall_radius_snapshot()
		var r: float = dyn[k * SECTORS + j]
		# Monotonic non-increasing toward rest from above.
		if r > prev + 1e-7:
			return {"pass": false,
					"message": "first-order overshoot: r grew %.8f → %.8f at tick %d" % [
							prev, r, tick]}
		prev = r
	print("    first-order final wall = %.6f (target = rest %.6f)" % [prev, REST_RADIUS])
	if absf(prev - REST_RADIUS) > 5e-4:
		return {"pass": false,
				"message": "first-order did not converge: %.6f vs %.6f" % [prev, REST_RADIUS]}
	return {"pass": true}


# ─── Test 8: GPU upload matches CPU scratch ────────────────────────


func test_gpu_upload_matches_cpu_state() -> Dictionary:
	var fix := _make_fixture()
	var integ: RefCounted = fix["integrator"]
	var tex: ImageTexture = fix["texture"]
	var solver: RefCounted = fix["solver"]
	# Drive a zone so cells have non-trivial values to compare.
	var arc: float = solver.get_total_arc_length()
	integ.update_constriction_zones(_zone_pack(arc * 0.5, arc * 0.2, 1.0, 1.0))
	for _t in 60:
		integ.tick(DT)
	var snapshot: PackedFloat32Array = integ.get_dynamic_wall_radius_snapshot()
	# Pull the texture's image and read each pixel's R-channel.
	var img: Image = tex.get_image()
	var worst := 0.0
	for k in AXIAL:
		for j in SECTORS:
			var col: Color = img.get_pixel(k, j)
			var snap: float = snapshot[k * SECTORS + j]
			var err := absf(col.r - snap)
			if err > worst:
				worst = err
	print("    worst CPU vs texture R-channel err: %.10f" % worst)
	if worst > 1e-5:
		return {"pass": false,
				"message": "GPU upload mismatch: %.6f" % worst}
	return {"pass": true}


# ─── Test 9: friction multiplier picks up zone bonus + muscle ──────


func test_friction_mult_responds_to_muscle_zones() -> Dictionary:
	var fix := _make_fixture(false, 1)  # MODE_FRICTION_MULT
	var integ: RefCounted = fix["integrator"]
	var solver: RefCounted = fix["solver"]
	var arc: float = solver.get_total_arc_length()
	# Zone at mid-canal: full muscle + friction_bonus = 0.5. Expected mid
	# cell friction_mult ≈ 1 + muscle*muscle_friction_gain + bonus
	#                    = 1 + 1.0 * 1.0 + 0.5 = 2.5.
	integ.update_constriction_zones(_zone_pack(arc * 0.5, arc * 0.2, 1.0, 1.0, 0.5))
	# Disable damage so it doesn't subtract from friction during the test.
	integ.set_damage_params(0.0, 1.0, 0.5)
	for _t in 60:
		integ.tick(DT)
	var fc: PackedFloat32Array = integ.get_fourth_channel_snapshot()
	var mid: float = fc[(AXIAL / 2) * SECTORS + 0]
	var far: float = fc[0]
	print("    friction_mult mid=%.4f, far=%.4f" % [mid, far])
	if mid < 2.0:
		return {"pass": false,
				"message": "mid friction_mult too low: %.4f (expected ~2.5)" % mid}
	if absf(far - 1.0) > 1e-3:
		return {"pass": false,
				"message": "far friction_mult drifted from 1.0: %.4f" % far}
	return {"pass": true}
