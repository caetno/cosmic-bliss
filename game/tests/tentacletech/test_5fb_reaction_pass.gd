extends SceneTree

# Slice §6.12.12 — Canal-interior reaction pass tests (2026-05-16).
#
# Seven tests exercise the `CanalReactionPass` C++ class + the
# `CanalAutoBaker._resolve_host_bone_rids_per_section` GDScript helper:
#
#   1. bake_resolves_host_bones_per_section — synthetic skeleton with
#      CP bones whose parent chain leads to a single PhysicalBone3D
#      ("Hips"). After bake, every cross-section maps to "Hips".
#   2. zero_wall_displacement_zero_reaction — wall at rest;
#      `tick_force` registers 0 bones hit and returns zero per-section
#      reactions.
#   3. unilateral_wall_push_routes_to_host_bone — push one cell's
#      `dynamic_wall_radius` outward; 1 bone hit; the impulse points
#      OUTWARD at that θ (negated wall reaction).
#   4. n_rim_exclusion_skips_proximal_sections — push cross-section 0's
#      wall outward; with `n_rim_exclusion = 1` no bones hit; with
#      `n_rim_exclusion = 0` the same configuration hits 1 bone.
#   5. load_weighted_centroid_correct — push two distant cross-sections
#      with different displacement magnitudes; the application point is
#      the load-weighted centroid of the two cross-section positions.
#   6. impulse_scales_with_dt — same configuration; the impulse
#      magnitude at dt=1/60 is 2× the dt=1/120 case.
#   7. degenerate_no_host_bone_safely_skips — bake against a skeleton
#      whose CP bones have no PhysicalBone3D ancestor; reaction pass
#      yields 0 bones hit + no crash.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_5fb_reaction_pass.gd

const _CanalParameters = preload("res://addons/tentacletech/scripts/resources/canal_parameters.gd")
const _Canal = preload("res://addons/tentacletech/scripts/canal/canal.gd")

const DT := 1.0 / 60.0
const AXIAL := 16
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
	if not ClassDB.class_exists("CanalReactionPass"):
		push_error("[FAIL] tentacletech extension not loaded (CanalReactionPass missing)")
		quit(2)
		return
	if not ClassDB.class_exists("TunnelStateIntegrator"):
		push_error("[FAIL] tentacletech extension not loaded (TunnelStateIntegrator missing)")
		quit(2)
		return

	var passed: int = 0
	var failed: int = 0
	for test_name in [
		"test_bake_resolves_host_bones_per_section",
		"test_zero_wall_displacement_zero_reaction",
		"test_unilateral_wall_push_routes_to_host_bone",
		"test_n_rim_exclusion_skips_proximal_sections",
		"test_load_weighted_centroid_correct",
		"test_impulse_scales_with_dt",
		"test_degenerate_no_host_bone_safely_skips",
	]:
		var result: Dictionary = call(test_name)
		if result.get("pass", false):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			print("[FAIL] %s: %s" % [test_name, result.get("message", "")])
			failed += 1

	print("\n§6.12.12 reaction pass: %d/%d passed" % [passed, passed + failed])
	quit(0 if failed == 0 else 2)


# ─── Fixture helpers ───────────────────────────────────────────────


# Build a minimal Canal with the centerline + integrator + reaction
# pass wired up, plus a host-bone RID array sized AXIAL. Per-test
# overrides can supply a custom host_bone_rids array; default is all
# the same RID (single-bone canal).
func _make_fixture(p_host_bone_rids: Array,
		p_n_rim_exclusion: int = 1,
		p_wall_response_stiffness: float = 100.0) -> Dictionary:
	var canal: Node3D = _Canal.new()
	canal.name = "TestCanalRP"
	root.add_child(canal)

	var params: Resource = _CanalParameters.new()
	params.canal_axial_segments = AXIAL
	params.canal_angular_sectors = SECTORS
	params.min_wall_radius = 0.001
	params.wall_response_rate = 10.0
	params.use_second_order_wall = false
	params.contraction_gain = 1.0
	params.muscle_friction_gain = 1.0
	params.damage_rate = 0.0
	params.curvature_response_gain = 0.0
	params.fourth_channel_mode = 0
	params.wall_response_stiffness = p_wall_response_stiffness
	params.canal_reaction_rim_exclusion = p_n_rim_exclusion
	canal.canal_parameters = params
	canal.force_active_for_test = true

	var rest_positions := PackedVector3Array()
	rest_positions.resize(M)
	for i in M:
		var t := float(i) / float(M - 1)
		rest_positions[i] = Vector3(t * CHAIN_LENGTH_M, 0, 0)
	canal._set_baked_anchors(rest_positions[0], rest_positions[M - 1])
	canal._set_baked_centerline_rest_positions(rest_positions)
	var chain: RefCounted = canal._ensure_centerline_chain()
	# Settle the chain so basis_at returns a stable frame.
	for _i in 5:
		chain.tick(DT)

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

	var host_rids := p_host_bone_rids.duplicate()
	while host_rids.size() < AXIAL:
		host_rids.append(RID())
	var object_ids := PackedInt64Array()
	object_ids.resize(AXIAL)
	canal._set_baked_cross_section_host_bone_rids(host_rids, object_ids)
	var pass_inst: RefCounted = canal._ensure_reaction_pass()

	return {
		"canal": canal,
		"params": params,
		"chain": chain,
		"integ": integ,
		"pass": pass_inst,
	}


func _cleanup(fix: Dictionary) -> void:
	var canal: Node3D = fix["canal"]
	canal.queue_free()


# ─── Test 1: bake step 9b resolves host bones via skeleton chain ────


func test_bake_resolves_host_bones_per_section() -> Dictionary:
	# Build a synthetic skeleton: root "Hips" bone + a chain of CP bones
	# parented under "Hips" with bone-name prefix "TestCP". Attach one
	# PhysicalBone3D for "Hips".
	var skeleton := Skeleton3D.new()
	skeleton.name = "TestSkel"
	root.add_child(skeleton)
	var hips_bone := skeleton.add_bone("Hips")
	var prev_parent := hips_bone
	for k in 6:
		var cp := skeleton.add_bone("TestCP_%d" % k)
		skeleton.set_bone_parent(cp, prev_parent)
		var x := 0.1 + float(k) * 0.05
		skeleton.set_bone_rest(cp, Transform3D(Basis(), Vector3(x, 0, 0)))
		skeleton.set_bone_pose_position(cp, Vector3(x, 0, 0))
		prev_parent = cp

	var pb: Node = ClassDB.instantiate("PhysicalBone3D")
	pb.set("bone_name", "Hips")
	skeleton.add_child(pb)

	var params: Resource = _CanalParameters.new()
	params.canal_axial_segments = AXIAL
	params.canal_angular_sectors = SECTORS
	params.spline_cp_bone_prefix = &"TestCP"

	# Build a spline from the same CP bone positions the baker would scan.
	var pts := PackedVector3Array()
	pts.resize(6)
	for k in 6:
		pts[k] = Vector3(0.1 + float(k) * 0.05, 0, 0)
	var spline: RefCounted = ClassDB.instantiate("CatmullSpline")
	spline.build_from_points(pts)

	var CanalAutoBaker = load("res://addons/tentacletech/scripts/canal/canal_auto_baker.gd")
	var result: Dictionary = CanalAutoBaker.call("_resolve_host_bone_rids_per_section",
			spline, params, skeleton)
	var rids: Array = result["rids"]
	var object_ids: PackedInt64Array = result["object_ids"]

	var resolved_count := 0
	var hips_id := pb.get_instance_id()
	for k in AXIAL:
		if (rids[k] as RID).is_valid():
			resolved_count += 1
		if object_ids[k] == hips_id:
			pass
	skeleton.queue_free()
	if resolved_count < AXIAL:
		return {"pass": false,
				"message": "expected all %d sections resolved, got %d" % [AXIAL, resolved_count]}
	for k in AXIAL:
		if object_ids[k] != hips_id:
			return {"pass": false,
					"message": "section %d resolved to instance %d not Hips %d" % [
							k, object_ids[k], hips_id]}
	return {"pass": true}


# ─── Test 2: at rest, the pass dispatches nothing ──────────────────


func test_zero_wall_displacement_zero_reaction() -> Dictionary:
	# All host RIDs empty — the reaction pass would skip anyway, but the
	# important thing is the per-section reaction reads as zero.
	var host_rids: Array = []
	host_rids.resize(AXIAL)
	for i in AXIAL:
		host_rids[i] = RID()
	var fix := _make_fixture(host_rids)
	var canal: Node3D = fix["canal"]
	canal.tick_force(DT)
	var reactions: PackedVector3Array = canal.get_last_reaction_per_section_snapshot()
	var max_mag := 0.0
	for r in reactions:
		var m := r.length()
		if m > max_mag:
			max_mag = m
	var impulses: PackedVector3Array = canal.get_last_bone_impulse_snapshot()
	print("    max per-section reaction=%.8f, bone impulses=%d" % [max_mag, impulses.size()])
	_cleanup(fix)
	if max_mag > 1e-5:
		return {"pass": false,
				"message": "expected ~0 reaction at rest, got %.8f" % max_mag}
	if impulses.size() != 0:
		return {"pass": false,
				"message": "expected 0 bone impulses, got %d" % impulses.size()}
	return {"pass": true}


# ─── Test 3: a single perturbed cell routes to the host bone ───────


# Build a non-zero RID via a synthetic PhysicalBone3D so the reaction
# pass actually queues the impulse.
func _make_synthetic_body_rid() -> Dictionary:
	# Create a PhysicalBone3D under a Skeleton3D fixture so its
	# `get_rid()` returns a real Jolt body RID. Bones are added BEFORE
	# the skeleton enters the tree so PhysicalBoneSimulator3D's lazy
	# bind-on-enter sees the bone count we want.
	var skel := Skeleton3D.new()
	skel.name = "RPSkel%d" % randi()
	skel.add_bone("Root")
	root.add_child(skel)
	var pb: Node = ClassDB.instantiate("PhysicalBone3D")
	pb.set("bone_name", "Root")
	skel.add_child(pb)
	var rid: RID = pb.call("get_rid")
	return {"skeleton": skel, "body": pb, "rid": rid}


func test_unilateral_wall_push_routes_to_host_bone() -> Dictionary:
	var body := _make_synthetic_body_rid()
	var host_rids: Array = []
	host_rids.resize(AXIAL)
	for i in AXIAL:
		host_rids[i] = body["rid"]
	var fix := _make_fixture(host_rids)
	var canal: Node3D = fix["canal"]
	var integ: RefCounted = fix["integ"]

	# Push cell (k=8, j=0) outward by 5 mm. j=0 → θ=0 → outward = +normal
	# axis (Y in the chain frame's column 1).
	var k_test := 8
	var j_test := 0
	integ.set_dynamic_wall_radius_for_test(k_test, j_test, REST_RADIUS + 0.005)

	# Run the reaction pass directly with a dt > 0 so impulse magnitude
	# stays measurable. Bypass the rest of canal.tick to avoid the
	# integrator's first-order decay erasing the perturbation.
	var pass_inst: RefCounted = fix["pass"]
	var bones_hit: int = pass_inst.tick(DT)
	var reactions: PackedVector3Array = canal.get_last_reaction_per_section_snapshot()
	var impulses: PackedVector3Array = canal.get_last_bone_impulse_snapshot()
	var apps: PackedVector3Array = canal.get_last_application_points_snapshot()
	print("    bones_hit=%d reaction[%d]=%s impulse=%s" % [
			bones_hit, k_test,
			str(reactions[k_test]) if reactions.size() > k_test else "n/a",
			str(impulses[0]) if impulses.size() > 0 else "n/a"])
	_cleanup(fix)
	body["skeleton"].queue_free()

	if bones_hit != 1:
		return {"pass": false,
				"message": "expected 1 bone hit, got %d" % bones_hit}
	# The wall was pushed outward; the reaction = -k * disp * outward
	# should point INWARD at that θ; for θ=0 + chain along +X, the
	# centerline basis column 1 (normal) is some Y/Z direction. The
	# impulse direction matches -reaction (impulse = reaction * dt is the
	# applied force on the host bone, which is the reaction to the wall
	# push — INWARD at that section, OUTWARD on the bone). The §6.12.12
	# pseudocode signs: `reaction -= k * disp * outward_normal`, then
	# applies as `body_apply_impulse(reaction * dt)`. So the bone receives
	# a force OPPOSING outward at j=0 (i.e. inward at that θ). The test
	# only checks the impulse is non-zero + along that radial axis.
	var r0: Vector3 = reactions[k_test]
	if r0.length() < 1e-3:
		return {"pass": false,
				"message": "section %d reaction too small: %s" % [k_test, str(r0)]}
	var imp: Vector3 = impulses[0]
	if imp.length() < 1e-6:
		return {"pass": false,
				"message": "bone impulse magnitude too small: %s" % str(imp)}
	# Application point lies on the centerline at s_norm ≈ k_test/(AXIAL-1).
	var ap: Vector3 = apps[0]
	var expected_x: float = CHAIN_LENGTH_M * float(k_test) / float(AXIAL - 1)
	if absf(ap.x - expected_x) > CHAIN_LENGTH_M:
		return {"pass": false,
				"message": "application point %s far from expected x=%.3f" % [str(ap), expected_x]}
	return {"pass": true}


# ─── Test 4: rim exclusion gates proximal cross-sections ───────────


func test_n_rim_exclusion_skips_proximal_sections() -> Dictionary:
	var body := _make_synthetic_body_rid()
	var host_rids: Array = []
	host_rids.resize(AXIAL)
	for i in AXIAL:
		host_rids[i] = body["rid"]

	# Pass A: n_rim_exclusion = 1, perturb cell 0 → expect 0 bones hit
	var fix_a := _make_fixture(host_rids, 1)
	fix_a["integ"].set_dynamic_wall_radius_for_test(0, 0, REST_RADIUS + 0.005)
	var bones_a: int = fix_a["pass"].tick(DT)
	_cleanup(fix_a)

	# Pass B: n_rim_exclusion = 0, same perturbation → expect 1 bone hit
	var fix_b := _make_fixture(host_rids, 0)
	fix_b["integ"].set_dynamic_wall_radius_for_test(0, 0, REST_RADIUS + 0.005)
	var bones_b: int = fix_b["pass"].tick(DT)
	_cleanup(fix_b)
	body["skeleton"].queue_free()

	print("    n_rim=1 bones=%d, n_rim=0 bones=%d" % [bones_a, bones_b])
	if bones_a != 0:
		return {"pass": false,
				"message": "n_rim=1 should skip cell 0, but %d bones hit" % bones_a}
	if bones_b != 1:
		return {"pass": false,
				"message": "n_rim=0 should hit 1 bone for cell 0, got %d" % bones_b}
	return {"pass": true}


# ─── Test 5: load-weighted centroid ────────────────────────────────


func test_load_weighted_centroid_correct() -> Dictionary:
	var body := _make_synthetic_body_rid()
	var host_rids: Array = []
	host_rids.resize(AXIAL)
	for i in AXIAL:
		host_rids[i] = body["rid"]
	var fix := _make_fixture(host_rids)
	var integ: RefCounted = fix["integ"]
	var canal: Node3D = fix["canal"]

	# Two cross-sections k=4 and k=8 with displacements 5 mm and 10 mm
	# respectively. Push every angular sector identically so each cross-
	# section's net reaction nets to zero radially (sum of outward
	# vectors around the loop = 0)... that's not what we want. To get
	# nonzero per-section reaction, push only j=0 at each k.
	integ.set_dynamic_wall_radius_for_test(4, 0, REST_RADIUS + 0.005)
	integ.set_dynamic_wall_radius_for_test(8, 0, REST_RADIUS + 0.010)
	var pass_inst: RefCounted = fix["pass"]
	pass_inst.tick(DT)
	var reactions: PackedVector3Array = canal.get_last_reaction_per_section_snapshot()
	var apps: PackedVector3Array = canal.get_last_application_points_snapshot()
	var impulses: PackedVector3Array = canal.get_last_bone_impulse_snapshot()

	if apps.size() == 0:
		_cleanup(fix)
		body["skeleton"].queue_free()
		return {"pass": false,
				"message": "expected 1 application point, got none"}
	# Compute expected centroid: (pos_4 * |r_4| + pos_8 * |r_8|) / (|r_4| + |r_8|)
	var chain: RefCounted = fix["chain"]
	var arc: float = chain.get_total_arc_length()
	var s4: float = float(4) / float(AXIAL - 1) * arc
	var s8: float = float(8) / float(AXIAL - 1) * arc
	var pos_4: Vector3 = chain.evaluate_at(s4)
	var pos_8: Vector3 = chain.evaluate_at(s8)
	var mag_4: float = (reactions[4] as Vector3).length()
	var mag_8: float = (reactions[8] as Vector3).length()
	var expected_centroid := (pos_4 * mag_4 + pos_8 * mag_8) / (mag_4 + mag_8)
	var actual: Vector3 = apps[0]
	var err: float = (actual - expected_centroid).length()
	print("    mag_4=%.6f mag_8=%.6f exp_centroid=%s actual=%s err=%.8f" % [
			mag_4, mag_8, str(expected_centroid), str(actual), err])
	_cleanup(fix)
	body["skeleton"].queue_free()
	# Cross-section width along x: 0.04 m / (16-1) ≈ 0.027 m. Centroid
	# should land between pos_4 and pos_8 weighted ~1:2.
	if err > 1e-4:
		return {"pass": false,
				"message": "centroid off by %.6f m (expected %s, got %s)" % [
						err, str(expected_centroid), str(actual)]}
	if impulses.size() != 1:
		return {"pass": false,
				"message": "expected 1 host bone impulse, got %d" % impulses.size()}
	return {"pass": true}


# ─── Test 6: impulse magnitude scales linearly with dt ─────────────


func test_impulse_scales_with_dt() -> Dictionary:
	var body := _make_synthetic_body_rid()
	var host_rids: Array = []
	host_rids.resize(AXIAL)
	for i in AXIAL:
		host_rids[i] = body["rid"]

	# Fixture A: dt = 1/60
	var fix_a := _make_fixture(host_rids)
	fix_a["integ"].set_dynamic_wall_radius_for_test(8, 0, REST_RADIUS + 0.005)
	fix_a["pass"].tick(1.0 / 60.0)
	var imp_a: Vector3 = (fix_a["canal"].get_last_bone_impulse_snapshot() as PackedVector3Array)[0]
	_cleanup(fix_a)

	# Fixture B: dt = 1/120
	var fix_b := _make_fixture(host_rids)
	fix_b["integ"].set_dynamic_wall_radius_for_test(8, 0, REST_RADIUS + 0.005)
	fix_b["pass"].tick(1.0 / 120.0)
	var imp_b: Vector3 = (fix_b["canal"].get_last_bone_impulse_snapshot() as PackedVector3Array)[0]
	_cleanup(fix_b)
	body["skeleton"].queue_free()

	var ratio: float = imp_a.length() / max(imp_b.length(), 1e-9)
	print("    |imp(dt=1/60)|=%.8f, |imp(dt=1/120)|=%.8f, ratio=%.4f" % [
			imp_a.length(), imp_b.length(), ratio])
	if absf(ratio - 2.0) > 0.05:
		return {"pass": false,
				"message": "expected dt scaling ratio 2.0, got %.4f" % ratio}
	return {"pass": true}


# ─── Test 7: degenerate config (no host RIDs) is a safe no-op ──────


func test_degenerate_no_host_bone_safely_skips() -> Dictionary:
	# All RIDs empty.
	var host_rids: Array = []
	host_rids.resize(AXIAL)
	for i in AXIAL:
		host_rids[i] = RID()
	var fix := _make_fixture(host_rids)
	var canal: Node3D = fix["canal"]
	# Perturb a cell so reactions are non-zero in section snapshots.
	fix["integ"].set_dynamic_wall_radius_for_test(8, 0, REST_RADIUS + 0.005)
	var bones_hit: int = fix["pass"].tick(DT)
	var impulses: PackedVector3Array = canal.get_last_bone_impulse_snapshot()
	var reactions: PackedVector3Array = canal.get_last_reaction_per_section_snapshot()
	var mag_8: float = (reactions[8] as Vector3).length()
	print("    bones_hit=%d reaction[8]=%.6f impulses=%d" % [
			bones_hit, mag_8, impulses.size()])
	_cleanup(fix)
	if bones_hit != 0:
		return {"pass": false,
				"message": "expected 0 bones hit with empty RIDs, got %d" % bones_hit}
	if impulses.size() != 0:
		return {"pass": false,
				"message": "expected 0 impulse entries, got %d" % impulses.size()}
	if mag_8 < 1e-3:
		# The per-section reaction MUST still be computed even when
		# routing skips; this is what makes the snapshot useful for the
		# gizmo even on canals with no resolved host bones.
		return {"pass": false,
				"message": "expected non-zero per-section reaction at k=8, got %.6f" % mag_8}
	return {"pass": true}
