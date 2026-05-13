extends SceneTree

# Slice 5F.B.A — Per-tick anchor refresh through CanalCenterlineSource
# (2026-05-13).
#
# Verifies that moving the host skeleton at runtime propagates into the
# centerline chain via the per-tick `centerline_source.refresh_anchors()`
# call wired into `Canal.tick(dt)` / `tick_force(dt)`.
#
# Three tests:
#   1. anchors_follow_translated_skeleton — translate the hero root +0.2 m
#      over 30 ticks; assert both anchor fields + the chain's pinned
#      endpoints track the moving orifices within 1e-4 m.
#   2. anchors_follow_rotated_skeleton — rotate hero root 90° about +Y
#      over 60 ticks; anchors + endpoints follow the new orifice
#      positions.
#   3. static_skeleton_zero_drift — regression: no skeleton motion → no
#      anchor drift, no chain motion over 60 ticks.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_5fbA_anchor_refresh.gd

const _CanalParameters = preload("res://addons/tentacletech/scripts/resources/canal_parameters.gd")
const _Canal = preload("res://addons/tentacletech/scripts/canal/canal.gd")
const _CanalAutoBaker = preload("res://addons/tentacletech/scripts/canal/canal_auto_baker.gd")
const _CPBoneCenterlineSource = preload("res://addons/tentacletech/scripts/canal/cp_bone_centerline_source.gd")

# Synthetic config: straight-axis canal, 4 CP bones over 0.4 m, two
# "orifice" Node3D anchors (plain Node3D — the resolver falls back to
# global_position when the node doesn't implement get_center_frame_world).
const CANAL_LENGTH := 0.4
const N_CP_BONES := 4
const N_CENTERLINE_PARTICLES := 8

var _ran: bool = false


func _process(_d: float) -> bool:
	if not _ran:
		_ran = true
		_run()
	return false


func _run() -> void:
	if not ClassDB.class_exists("CatmullSpline"):
		push_error("[FAIL] tentacletech extension not loaded (CatmullSpline missing)")
		quit(2)
		return
	if not ClassDB.class_exists("CanalCenterlineSolver"):
		push_error("[FAIL] tentacletech extension not loaded (CanalCenterlineSolver missing)")
		quit(2)
		return

	var passed: int = 0
	var failed: int = 0
	for test_name in [
		"test_anchors_follow_translated_skeleton",
		"test_anchors_follow_rotated_skeleton",
		"test_static_skeleton_zero_drift",
	]:
		_reset_root()
		var result: Dictionary = call(test_name)
		if result.get("pass", false):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			print("[FAIL] %s: %s" % [test_name, result.get("message", "")])
			failed += 1

	print("\n5F.B.A anchor refresh: %d/%d passed" % [passed, passed + failed])
	quit(0 if failed == 0 else 2)


func _reset_root() -> void:
	for c in root.get_children():
		root.remove_child(c)
		c.free()


# ─── Synthetic scene builder ───────────────────────────────────────


# Builds: hero_root/{Skeleton3D, EntryOrifice, ExitOrifice, Canal}.
# All children parented under hero_root so translating/rotating it
# moves the whole rig together. Returns the hero_root Node3D so the
# test can transform it directly.
func _build_scene() -> Dictionary:
	var hero := Node3D.new()
	hero.name = "HeroRoot"
	root.add_child(hero)

	# Skeleton3D with CP bones along +X axis from origin.
	var skel := Skeleton3D.new()
	skel.name = "Skeleton3D"
	hero.add_child(skel)
	for i in N_CP_BONES:
		var t := float(i) / float(N_CP_BONES - 1)
		var pos := Vector3(t * CANAL_LENGTH, 0, 0)
		var bone_idx := skel.add_bone("Vag_CP_%d" % i)
		skel.set_bone_rest(bone_idx, Transform3D(Basis.IDENTITY, pos))
		skel.set_bone_pose_position(bone_idx, pos)

	# Two plain Node3D orifice stand-ins. The resolver checks for
	# get_center_frame_world() first then falls back to global_position;
	# we exercise the fallback path so this test doesn't require a real
	# Orifice node.
	var entry := Node3D.new()
	entry.name = "EntryOrifice"
	entry.position = Vector3(0, 0, 0)
	hero.add_child(entry)

	var exit := Node3D.new()
	exit.name = "ExitOrifice"
	exit.position = Vector3(CANAL_LENGTH, 0, 0)
	hero.add_child(exit)

	# Canal node with parameters + source.
	var params := _CanalParameters.new()
	params.canal_name = StringName("test_canal")
	params.spline_cp_bone_prefix = StringName("Vag_CP")
	params.canal_axial_segments = 8
	params.canal_angular_sectors = 4
	params.centerline_particle_count = N_CENTERLINE_PARTICLES
	params.closed_terminal = false
	params.entry_orifice_path = NodePath("EntryOrifice")
	params.exit_orifice_path = NodePath("ExitOrifice")

	var canal: Node3D = _Canal.new()
	canal.name = "Canal"
	canal.canal_parameters = params
	canal.centerline_source = _CPBoneCenterlineSource.new()
	canal.skeleton_path = NodePath("../Skeleton3D")
	# orifices_root_path defaults to get_parent() (= hero_root). No override needed.
	hero.add_child(canal)

	# Bake: builds spline, allocates centerline chain, sets initial
	# anchors from the bake-time orifice positions.
	var mesh_inst := MeshInstance3D.new()
	# Empty mesh — bake step 7 falls back to rest_radius_profile (or 0.05 m
	# default) when no canal_id-tagged triangles are present. Per-vert bake
	# step 10 is a no-op without verts. Both are fine for this test.
	mesh_inst.mesh = ArrayMesh.new()
	hero.add_child(mesh_inst)
	var ok := _CanalAutoBaker.bake(canal, mesh_inst, skel, 0, hero)
	if not ok:
		push_error("Canal bake failed in test setup")

	return {
		"hero": hero,
		"skel": skel,
		"entry": entry,
		"exit": exit,
		"canal": canal,
	}


# ─── Test 1: translated skeleton ───────────────────────────────────


func test_anchors_follow_translated_skeleton() -> Dictionary:
	var scene := _build_scene()
	var hero: Node3D = scene["hero"]
	var canal: Node3D = scene["canal"]
	var entry: Node3D = scene["entry"]
	var exit: Node3D = scene["exit"]

	# Confirm initial anchors == bake-time orifice positions.
	var p0: Vector3 = canal.get_proximal_anchor_world()
	var d0: Vector3 = canal.get_distal_anchor_world()
	if (p0 - entry.global_position).length() > 1e-4:
		return {"pass": false, "message": "initial proximal mismatch: %s vs %s" % [p0, entry.global_position]}
	if (d0 - exit.global_position).length() > 1e-4:
		return {"pass": false, "message": "initial distal mismatch: %s vs %s" % [d0, exit.global_position]}

	# Translate hero root +0.2 m along +Y in 10 steps; hold for 20 more.
	var translation := Vector3(0, 0.2, 0)
	var worst_anchor_err := 0.0
	var dt := 1.0 / 60.0
	for step in 30:
		if step < 10:
			hero.position += translation / 10.0
		canal.tick_force(dt)
		# Each tick, anchors should match the orifice nodes' current global positions.
		var p_now: Vector3 = canal.get_proximal_anchor_world()
		var d_now: Vector3 = canal.get_distal_anchor_world()
		var ep := (p_now - entry.global_position).length()
		var ed := (d_now - exit.global_position).length()
		var e := maxf(ep, ed)
		if e > worst_anchor_err:
			worst_anchor_err = e

	# After 30 ticks: anchors are pinned to translated orifice positions;
	# chain endpoint particles should match.
	var positions: PackedVector3Array = canal.get_centerline_positions_snapshot()
	var entry_now: Vector3 = entry.global_position
	var exit_now: Vector3 = exit.global_position
	var endpoint_err_prox := (positions[0] - entry_now).length()
	var endpoint_err_dist := (positions[positions.size() - 1] - exit_now).length()
	print("    translate: worst per-tick anchor err = %.6f m; endpoints final err prox=%.6f dist=%.6f"
			% [worst_anchor_err, endpoint_err_prox, endpoint_err_dist])
	if worst_anchor_err > 1e-4:
		return {"pass": false, "message": "anchor field tracking err %.6f > 1e-4" % worst_anchor_err}
	if endpoint_err_prox > 1e-4 or endpoint_err_dist > 1e-4:
		return {"pass": false,
				"message": "endpoint particle err prox=%.6f dist=%.6f > 1e-4"
				% [endpoint_err_prox, endpoint_err_dist]}
	return {"pass": true}


# ─── Test 2: rotated skeleton ──────────────────────────────────────


func test_anchors_follow_rotated_skeleton() -> Dictionary:
	var scene := _build_scene()
	var hero: Node3D = scene["hero"]
	var canal: Node3D = scene["canal"]
	var entry: Node3D = scene["entry"]
	var exit: Node3D = scene["exit"]

	# Rotate hero root 90° about +Y in 30 steps; hold 30 ticks more.
	var total_angle := PI * 0.5
	var step_angle := total_angle / 30.0
	var worst_anchor_err := 0.0
	var dt := 1.0 / 60.0
	for step in 60:
		if step < 30:
			hero.rotate_y(step_angle)
		canal.tick_force(dt)
		var p_now: Vector3 = canal.get_proximal_anchor_world()
		var d_now: Vector3 = canal.get_distal_anchor_world()
		var ep := (p_now - entry.global_position).length()
		var ed := (d_now - exit.global_position).length()
		var e := maxf(ep, ed)
		if e > worst_anchor_err:
			worst_anchor_err = e

	# Final state: chain endpoints pinned to rotated orifice positions.
	var positions: PackedVector3Array = canal.get_centerline_positions_snapshot()
	var endpoint_err_prox := (positions[0] - entry.global_position).length()
	var endpoint_err_dist := (positions[positions.size() - 1] - exit.global_position).length()
	# Sanity: the exit orifice should now be along +Z (90° rotation about +Y
	# sends +X to -Z in Godot's right-handed convention... actually +X → +Z
	# depending on sign convention. Just confirm it's not at the original +X.
	var exit_pos := exit.global_position
	var moved_off_x := absf(exit_pos.x) < CANAL_LENGTH * 0.5  # well off original axis
	print("    rotate: worst anchor err = %.6f m; endpoints final err prox=%.6f dist=%.6f; exit_now=%s (moved_off_x=%s)"
			% [worst_anchor_err, endpoint_err_prox, endpoint_err_dist, exit_pos, moved_off_x])
	if not moved_off_x:
		return {"pass": false, "message": "rotation didn't move exit orifice off +X: %s" % exit_pos}
	if worst_anchor_err > 1e-4:
		return {"pass": false, "message": "anchor field tracking err %.6f > 1e-4" % worst_anchor_err}
	if endpoint_err_prox > 1e-4 or endpoint_err_dist > 1e-4:
		return {"pass": false,
				"message": "endpoint particle err prox=%.6f dist=%.6f > 1e-4"
				% [endpoint_err_prox, endpoint_err_dist]}
	return {"pass": true}


# ─── Test 3: static skeleton, zero drift ───────────────────────────


func test_static_skeleton_zero_drift() -> Dictionary:
	var scene := _build_scene()
	var canal: Node3D = scene["canal"]
	# Snapshot the initial particle positions.
	var initial: PackedVector3Array = canal.get_centerline_positions_snapshot().duplicate()
	var dt := 1.0 / 60.0
	for _i in 60:
		canal.tick_force(dt)
	var final: PackedVector3Array = canal.get_centerline_positions_snapshot()
	var worst := 0.0
	for i in initial.size():
		var e := (initial[i] - final[i]).length()
		if e > worst:
			worst = e
	print("    static: worst particle drift after 60 ticks = %.10f m" % worst)
	if worst > 1e-5:
		return {"pass": false, "message": "drift %.6f > 1e-5" % worst}
	return {"pass": true}
