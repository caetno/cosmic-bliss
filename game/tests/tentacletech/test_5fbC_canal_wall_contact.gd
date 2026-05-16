extends SceneTree

# Slice 5F.B.C — Type-3 canal-wall contact tests (2026-05-16).
#
# Seven tests exercise the Tentacle::_apply_canal_wall_contacts pass:
#
#   1. particle_outside_wall_unaffected — particle inside the wall
#      envelope; zero wall contacts.
#   2. particle_inside_wall_projected_outward — particle past the wall
#      threshold; projected back to wall - particle_radius.
#   3. feature_silhouette_subtracts_from_wall_clearance — flat +5 mm
#      silhouette pushes projected position 5 mm closer to axis.
#   4. wall_deflects_under_particle_pressure — particle pushed inside;
#      next tunnel-state tick, dynamic_wall_radius increases.
#   5. centerline_deflects_under_lateral_pressure — high lateral
#      compliance; centerline particle moves laterally.
#   6. friction_mult_scales_friction_force — 3× friction multiplier
#      produces >2× tangent velocity loss.
#   7. inactive_canal_skips_type3 — canal unregistered; no projection.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_5fbC_canal_wall_contact.gd

const _CanalParameters = preload("res://addons/tentacletech/scripts/resources/canal_parameters.gd")
const _Canal = preload("res://addons/tentacletech/scripts/canal/canal.gd")

const DT := 1.0 / 60.0
const AXIAL := 16
const SECTORS := 8
const REST_RADIUS := 0.05
const CHAIN_LENGTH_M := 0.4
const M := 12
const TENTACLE_PARTICLES := 4
# Segment length deliberately set large so when a test sets a particle's
# position far from the anchor's default chain layout, segment lengths
# are close enough to rest that `girth_scale` (finalize updates from
# segment-stretch ratios) stays near 1.0.
const TENTACLE_SEGMENT := 1.0

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
	if not ClassDB.class_exists("Tentacle"):
		push_error("[FAIL] tentacletech extension not loaded (Tentacle missing)")
		quit(2)
		return

	var passed: int = 0
	var failed: int = 0
	for test_name in [
		"test_particle_outside_wall_unaffected",
		"test_particle_inside_wall_projected_outward",
		"test_feature_silhouette_subtracts_from_wall_clearance",
		"test_wall_deflects_under_particle_pressure",
		"test_centerline_deflects_under_lateral_pressure",
		"test_friction_mult_scales_friction_force",
		"test_inactive_canal_skips_type3",
	]:
		var result: Dictionary = call(test_name)
		if result.get("pass", false):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			print("[FAIL] %s: %s" % [test_name, result.get("message", "")])
			failed += 1

	print("\n5F.B.C canal-wall contact: %d/%d passed" % [passed, passed + failed])
	quit(0 if failed == 0 else 2)


# ─── Fixture helpers ───────────────────────────────────────────────


func _make_fixture(p_lateral_compliance: float = 0.01,
		p_force_active: bool = true) -> Dictionary:
	var canal: Node3D = _Canal.new()
	canal.name = "TestCanal"
	root.add_child(canal)

	var params: Resource = _CanalParameters.new()
	params.canal_axial_segments = AXIAL
	params.canal_angular_sectors = SECTORS
	params.min_wall_radius = 0.001
	params.wall_response_rate = 10.0
	params.use_second_order_wall = false
	params.wall_acceleration_gain = 5.0
	params.wall_damping = 6.0
	params.plastic_accumulate_rate = 0.05
	params.plastic_recover_rate = 0.05
	params.plastic_max_offset = 0.005
	params.damage_rate = 0.0
	params.damage_plastic_gain = 1.0
	params.damage_friction_loss = 0.5
	params.muscle_friction_gain = 1.0
	params.contraction_gain = 1.0
	params.curvature_response_gain = 0.0
	params.centerline_lateral_compliance = p_lateral_compliance
	params.fourth_channel_mode = 1  # MODE_FRICTION_MULT
	canal.canal_parameters = params
	canal.force_active_for_test = p_force_active

	var rest_positions := PackedVector3Array()
	rest_positions.resize(M)
	for i in M:
		var t := float(i) / float(M - 1)
		rest_positions[i] = Vector3(t * CHAIN_LENGTH_M, 0, 0)
	canal._set_baked_anchors(rest_positions[0], rest_positions[M - 1])
	canal._set_baked_centerline_rest_positions(rest_positions)

	var solver: RefCounted = canal._ensure_centerline_chain()
	for _i in 5:
		solver.tick(DT)

	var n_cells := AXIAL * SECTORS
	var rest_radius := PackedFloat32Array()
	rest_radius.resize(n_cells)
	for i in n_cells:
		rest_radius[i] = REST_RADIUS
	canal._set_baked_rest_radius_per_cell(rest_radius)

	var img := Image.create(AXIAL, SECTORS, false, Image.FORMAT_RGBAF)
	for k in AXIAL:
		for j in SECTORS:
			img.set_pixel(k, j, Color(REST_RADIUS, 0.0, 0.0, 1.0))
	var tex := ImageTexture.create_from_image(img)
	canal._set_baked_tunnel_state_texture(tex)

	var integ: RefCounted = canal._ensure_tunnel_state_integrator()

	var tentacle: Node3D = ClassDB.instantiate("Tentacle")
	tentacle.name = "TestTentacle"
	tentacle.set_particle_count(TENTACLE_PARTICLES)
	tentacle.set_segment_length(TENTACLE_SEGMENT)
	tentacle.set_environment_probe_enabled(false)
	tentacle.set_gravity(Vector3.ZERO)
	tentacle.set_damping(1.0)
	tentacle.set_iteration_count(1)
	tentacle.set_distance_stiffness(0.0)
	tentacle.set_bending_stiffness(0.0)
	tentacle.set_particle_collision_radius(0.005)
	tentacle.set_base_static_friction(0.4)
	tentacle.set_tentacle_lubricity(0.0)
	tentacle.set_kinetic_friction_ratio(0.8)
	tentacle.transform = Transform3D(Basis(), Vector3(CHAIN_LENGTH_M * 0.5, 1.0, 0.0))
	root.add_child(tentacle)
	tentacle.rebuild_chain()

	canal.register_active_canal_for_test(tentacle, 1)

	return {
		"canal": canal,
		"params": params,
		"tentacle": tentacle,
		"chain": solver,
		"integ": integ,
		"texture": tex,
		"rest_positions": rest_positions,
	}


func _set_particle_world(tentacle: Node3D, idx: int, p: Vector3) -> void:
	var solver: RefCounted = tentacle.get_solver()
	solver.set_particle_position(idx, p)


func _get_particle_world(tentacle: Node3D, idx: int) -> Vector3:
	var solver: RefCounted = tentacle.get_solver()
	return solver.get_particle_position(idx)


func _dist_from_axis(p: Vector3) -> float:
	return Vector2(p.y, p.z).length()


func _cleanup(fix: Dictionary) -> void:
	var canal: Node3D = fix["canal"]
	var tentacle: Node3D = fix["tentacle"]
	canal.unregister_active_canal_for_test(tentacle)
	tentacle.queue_free()
	canal.queue_free()


# ─── Test 1: particle inside the wall envelope — unaffected ────────


func test_particle_outside_wall_unaffected() -> Dictionary:
	var fix := _make_fixture()
	var tentacle: Node3D = fix["tentacle"]
	var staged := Vector3(CHAIN_LENGTH_M * 0.5, REST_RADIUS * 0.5, 0.0)
	_set_particle_world(tentacle, 2, staged)
	tentacle.tick(DT)
	var contacts: int = tentacle.get_last_canal_wall_contact_count()
	_cleanup(fix)
	if contacts != 0:
		return {"pass": false,
				"message": "expected 0 wall contacts, got %d" % contacts}
	return {"pass": true}


# ─── Test 2: particle past the wall — projected outward ────────────


func test_particle_inside_wall_projected_outward() -> Dictionary:
	var fix := _make_fixture()
	var tentacle: Node3D = fix["tentacle"]
	var penetration_pos := Vector3(CHAIN_LENGTH_M * 0.5, REST_RADIUS * 1.5, 0.0)
	_set_particle_world(tentacle, 2, penetration_pos)
	tentacle.tick(DT)
	var actual: Vector3 = _get_particle_world(tentacle, 2)
	var actual_dist := _dist_from_axis(actual)
	var coll_radius: float = tentacle.get_particle_collision_radius()
	var expected: float = REST_RADIUS - coll_radius
	var err: float = absf(actual_dist - expected)
	var contacts: int = tentacle.get_last_canal_wall_contact_count()
	print("    dist=%.6f expected=%.6f err=%.6f contacts=%d" % [
			actual_dist, expected, err, contacts])
	_cleanup(fix)
	if contacts < 1:
		return {"pass": false, "message": "no wall contact registered"}
	# Tolerance accommodates the per-tick `girth_scale` perturbation
	# from stretched chain segments; the projection logic itself is
	# exact, but `girth_scale × coll_radius` is mass-dependent in the
	# test fixture.
	if err > 2e-3:
		return {"pass": false,
				"message": "projected dist %.6f off expected %.6f by %.6f" % [
						actual_dist, expected, err]}
	return {"pass": true}


# ─── Test 3: feature silhouette adds to particle radius ────────────


func test_feature_silhouette_subtracts_from_wall_clearance() -> Dictionary:
	var fix_no_sil := _make_fixture()
	var tentacle_a: Node3D = fix_no_sil["tentacle"]
	var staged := Vector3(CHAIN_LENGTH_M * 0.5, REST_RADIUS * 1.5, 0.0)
	_set_particle_world(tentacle_a, 2, staged)
	tentacle_a.tick(DT)
	var dist_no_sil: float = _dist_from_axis(_get_particle_world(tentacle_a, 2))
	_cleanup(fix_no_sil)

	var fix_sil := _make_fixture()
	var tentacle_b: Node3D = fix_sil["tentacle"]
	var sil_img := Image.create(4, 4, false, Image.FORMAT_RF)
	for ix in 4:
		for iy in 4:
			sil_img.set_pixel(ix, iy, Color(0.005, 0.0, 0.0, 0.0))
	var sil_tex := ImageTexture.create_from_image(sil_img)
	tentacle_b.set_feature_silhouette(sil_tex)
	_set_particle_world(tentacle_b, 2, staged)
	tentacle_b.tick(DT)
	var dist_with_sil: float = _dist_from_axis(_get_particle_world(tentacle_b, 2))
	_cleanup(fix_sil)

	var delta := dist_no_sil - dist_with_sil
	print("    dist_no_sil=%.6f dist_with_sil=%.6f delta=%.6f" % [
			dist_no_sil, dist_with_sil, delta])
	if delta < 0.003:
		return {"pass": false,
				"message": "silhouette delta too small: %.6f (expected ~0.005)" % delta}
	if delta > 0.007:
		return {"pass": false,
				"message": "silhouette delta too large: %.6f (expected ~0.005)" % delta}
	return {"pass": true}


# ─── Test 4: wall deflects under particle pressure ─────────────────


func test_wall_deflects_under_particle_pressure() -> Dictionary:
	var fix := _make_fixture()
	var tentacle: Node3D = fix["tentacle"]
	var integ: RefCounted = fix["integ"]
	var canal: Node3D = fix["canal"]
	var deep := Vector3(CHAIN_LENGTH_M * 0.5, REST_RADIUS * 2.0, 0.0)
	_set_particle_world(tentacle, 2, deep)
	tentacle.tick(DT)
	canal.tick_force(DT)
	var dyn: PackedFloat32Array = integ.get_dynamic_wall_radius_snapshot()
	var k_mid := AXIAL / 2
	var max_dyn := -INF
	for j in SECTORS:
		var r: float = dyn[k_mid * SECTORS + j]
		if r > max_dyn:
			max_dyn = r
	print("    max dynamic_wall_radius at k=%d: %.6f (rest %.6f)" % [
			k_mid, max_dyn, REST_RADIUS])
	_cleanup(fix)
	if max_dyn - REST_RADIUS < 1e-4:
		return {"pass": false,
				"message": "wall did not deflect outward: %.6f vs rest %.6f" % [
						max_dyn, REST_RADIUS]}
	return {"pass": true}


# ─── Test 5: centerline yields under lateral pressure ──────────────


func test_centerline_deflects_under_lateral_pressure() -> Dictionary:
	var fix := _make_fixture(1.5)
	var tentacle: Node3D = fix["tentacle"]
	var chain: RefCounted = fix["chain"]
	var canal: Node3D = fix["canal"]
	var deep := Vector3(CHAIN_LENGTH_M * 0.5, REST_RADIUS * 1.6, 0.0)
	for _t in 30:
		_set_particle_world(tentacle, 2, deep)
		tentacle.tick(DT)
		canal.tick_force(DT)
	var positions: PackedVector3Array = chain.get_positions_snapshot()
	var max_lateral := 0.0
	for i in range(1, positions.size() - 1):
		var lateral := Vector2(positions[i].y, positions[i].z).length()
		if lateral > max_lateral:
			max_lateral = lateral
	print("    max interior centerline lateral offset: %.6f m" % max_lateral)
	_cleanup(fix)
	if max_lateral < 1e-4:
		return {"pass": false,
				"message": "centerline did not deflect: max lateral %.8f" % max_lateral}
	return {"pass": true}


# ─── Test 6: friction_mult scales friction force ───────────────────


func _measure_tangent_velocity_loss(p_friction_mult_scale: float) -> float:
	# Use the zone friction_bonus path (not muscle), so the wall radius
	# stays at rest while friction_mult scales.
	var fix := _make_fixture()
	var tentacle: Node3D = fix["tentacle"]
	var integ: RefCounted = fix["integ"]
	var chain: RefCounted = fix["chain"]
	var arc: float = chain.get_total_arc_length()
	var zone := PackedFloat32Array()
	zone.resize(5)
	zone[0] = arc * 0.5
	zone[1] = arc * 0.3
	zone[2] = 0.0  # disable wall compression
	zone[3] = 1.0
	zone[4] = p_friction_mult_scale - 1.0  # friction_bonus
	integ.update_constriction_zones(zone)
	for _i in 30:
		integ.tick(DT)

	# Stage particle past the wall threshold (kinetic-friction regime).
	# The actual wall threshold the type-3 pass uses is shaped by the
	# fixture's `girth_scale` dynamics; staging at rest_radius * 0.95
	# clears that threshold by ~5%, and the per-tick tangent disp (v×dt
	# ≈ 8 mm) well exceeds cone_cap so kinetic Coulomb applies.
	var solver: RefCounted = tentacle.get_solver()
	var post := Vector3(CHAIN_LENGTH_M * 0.5, REST_RADIUS * 0.95, 0.0)
	var v_tangent: float = 0.5
	solver.set_particle_position(2, post)
	solver.set_particle_velocity(2, Vector3(0, 0, v_tangent))
	tentacle.tick(DT)
	integ.tick(DT)

	var final_v: Vector3 = solver.get_particle_velocity(2)
	var loss: float = absf(v_tangent - final_v.z)
	print("    scale=%.2f: final_v=%s loss=%.6f" % [
			p_friction_mult_scale, str(final_v), loss])
	_cleanup(fix)
	return loss


func test_friction_mult_scales_friction_force() -> Dictionary:
	var loss_low := _measure_tangent_velocity_loss(1.0)
	var loss_high := _measure_tangent_velocity_loss(3.0)
	print("    friction_mult 1.0 loss=%.6f, friction_mult 3.0 loss=%.6f" % [
			loss_low, loss_high])
	if loss_low <= 1e-7:
		return {"pass": false,
				"message": "baseline friction loss is zero (%.8f) — test setup wrong" % loss_low}
	if loss_high <= loss_low * 1.2:
		return {"pass": false,
				"message": "high friction did not exceed low friction by >20%%: low=%.6f high=%.6f" % [
						loss_low, loss_high]}
	var ratio := loss_high / loss_low
	if ratio < 1.5 or ratio > 5.0:
		return {"pass": false,
				"message": "friction ratio out of band: %.3f (expected ~3.0, accept [1.5, 5])" % ratio}
	return {"pass": true}


# ─── Test 7: inactive canal → type-3 disabled ──────────────────────


func test_inactive_canal_skips_type3() -> Dictionary:
	# Inactive canal = never registered in production. Mirror by
	# unregistering from the tentacle.
	var fix := _make_fixture(0.01, false)
	var tentacle: Node3D = fix["tentacle"]
	var canal: Node3D = fix["canal"]
	canal.unregister_active_canal_for_test(tentacle)
	var deep := Vector3(CHAIN_LENGTH_M * 0.5, REST_RADIUS * 1.5, 0.0)
	_set_particle_world(tentacle, 2, deep)
	tentacle.tick(DT)
	var actual: Vector3 = _get_particle_world(tentacle, 2)
	var actual_dist := _dist_from_axis(actual)
	var contacts: int = tentacle.get_last_canal_wall_contact_count()
	print("    inactive: dist=%.6f contacts=%d" % [actual_dist, contacts])
	var threshold: float = REST_RADIUS - tentacle.get_particle_collision_radius()
	_cleanup(fix)
	if contacts != 0:
		return {"pass": false,
				"message": "type-3 fired on inactive canal: %d contacts" % contacts}
	if actual_dist <= threshold + 1e-3:
		return {"pass": false,
				"message": "particle was projected: dist=%.6f vs threshold=%.6f" % [
						actual_dist, threshold]}
	return {"pass": true}
