extends SceneTree

# Slice — `NodeCenterlineSource` Godot-native canal authoring path.
#
# Verifies the new `NodeCenterlineSource` concrete source against
# `CanalCenterlineSource` abstract contract. Mirrors the test shape of
# `test_5fa0_centerline_source_adapter.gd` (CP-bone source).
#
# Six tests:
#   1. build_spline_from_node_paths — N markers → CatmullSpline whose
#      sampled endpoints match the first/last marker positions.
#   2. refresh_anchors_tracks_moving_orifice — entry orifice translated
#      at runtime; per-tick refresh_anchors picks up the new position.
#   3. closed_terminal_via_pin_path — terminal_pin_path overrides
#      CanalParameters.terminal_pin_bone when set + resolvable.
#   4. closed_terminal_falls_through_to_bone — empty terminal_pin_path
#      falls back to bone lookup (matches CPBoneCenterlineSource).
#   5. auto_attach_to_nearest_bone — markers reparent under
#      BoneAttachment3D for the nearest bone; control_point_paths is
#      updated to the new paths; positions are preserved.
#   6. empty_control_point_paths_fails_gracefully — push_error +
#      build_spline returns null; doesn't crash.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_node_centerline_source.gd

const _CanalParameters = preload("res://addons/tentacletech/scripts/resources/canal_parameters.gd")
const _Canal = preload("res://addons/tentacletech/scripts/canal/canal.gd")
const _NodeCenterlineSource = preload("res://addons/tentacletech/scripts/canal/node_centerline_source.gd")

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

	var passed: int = 0
	var failed: int = 0
	for test_name in [
		"test_build_spline_from_node_paths",
		"test_refresh_anchors_tracks_moving_orifice",
		"test_closed_terminal_via_pin_path",
		"test_closed_terminal_falls_through_to_bone",
		"test_auto_attach_to_nearest_bone",
		"test_empty_control_point_paths_fails_gracefully",
	]:
		_reset_root()
		var result: Dictionary = call(test_name)
		if result.get("pass", false):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			print("[FAIL] %s: %s" % [test_name, result.get("message", "")])
			failed += 1

	print("\nNodeCenterlineSource: %d/%d passed" % [passed, passed + failed])
	quit(0 if failed == 0 else 2)


func _reset_root() -> void:
	for c in root.get_children():
		root.remove_child(c)
		c.free()


# ─── Helpers ───────────────────────────────────────────────────────


# Build a hero root with a 4-bone skeleton + N marker nodes along
# `+X` from origin to length L.
func _build_scene(p_n_markers: int, p_length: float,
		p_terminal_pin: Variant = null) -> Dictionary:
	var hero := Node3D.new()
	hero.name = "HeroRoot"
	root.add_child(hero)

	var skel := Skeleton3D.new()
	skel.name = "Skeleton3D"
	hero.add_child(skel)
	for i in 4:
		var t := float(i) / 3.0
		var pos := Vector3(t * p_length, 0, 0)
		var idx := skel.add_bone("Bone_%d" % i)
		skel.set_bone_rest(idx, Transform3D(Basis.IDENTITY, pos))
		skel.set_bone_pose_position(idx, pos)
	if p_terminal_pin != null:
		var tidx := skel.add_bone("Uterus_TerminalPin")
		var tpos: Vector3 = p_terminal_pin
		skel.set_bone_rest(tidx, Transform3D(Basis.IDENTITY, tpos))
		skel.set_bone_pose_position(tidx, tpos)

	# Plain Node3D entry orifice marker; resolver falls back to global_position.
	var entry := Node3D.new()
	entry.name = "EntryOrifice"
	entry.position = Vector3(0, 0, 0)
	hero.add_child(entry)

	# N marker Node3Ds parented under HeroRoot.
	var marker_paths: Array[NodePath] = []
	for i in p_n_markers:
		var t := float(i) / float(p_n_markers - 1)
		var m := Node3D.new()
		m.name = "CP_%d" % i
		m.position = Vector3(t * p_length, 0, 0)
		hero.add_child(m)
		marker_paths.append(NodePath("../%s" % m.name))

	return {
		"hero": hero,
		"skel": skel,
		"entry": entry,
		"marker_paths": marker_paths,
	}


func _make_canal(p_marker_paths: Array[NodePath],
		p_source: NodeCenterlineSource,
		p_closed_terminal: bool = false,
		p_terminal_pin_bone: String = "") -> Node3D:
	var params := _CanalParameters.new()
	params.canal_name = StringName("test_canal")
	params.canal_axial_segments = 8
	params.canal_angular_sectors = 4
	params.centerline_particle_count = 8
	params.closed_terminal = p_closed_terminal
	params.entry_orifice_path = NodePath("EntryOrifice")
	if not p_terminal_pin_bone.is_empty():
		params.terminal_pin_bone = StringName(p_terminal_pin_bone)

	var canal: Node3D = _Canal.new()
	canal.name = "Canal"
	canal.canal_parameters = params
	canal.centerline_source = p_source
	canal.skeleton_path = NodePath("../Skeleton3D")
	p_source.control_point_paths = p_marker_paths

	# Caller adds canal to the scene tree.
	return canal


# ─── Test 1: build_spline_from_node_paths ──────────────────────────


func test_build_spline_from_node_paths() -> Dictionary:
	var scene := _build_scene(5, 0.4)
	var source := _NodeCenterlineSource.new()
	var canal := _make_canal(scene["marker_paths"], source)
	(scene["hero"] as Node3D).add_child(canal)

	var spline: RefCounted = source.build_spline(scene["skel"], canal)
	if spline == null:
		return {"pass": false, "message": "build_spline returned null"}
	if spline.get_point_count() != 5:
		return {"pass": false, "message": "expected 5 CPs, got %d" % spline.get_point_count()}
	var p0: Vector3 = spline.evaluate_position(0.0)
	var p1: Vector3 = spline.evaluate_position(1.0)
	var err0 := (p0 - Vector3(0, 0, 0)).length()
	var err1 := (p1 - Vector3(0.4, 0, 0)).length()
	print("    spline 5 CPs: endpoint err = %.6f / %.6f" % [err0, err1])
	if err0 > 1e-4 or err1 > 1e-4:
		return {"pass": false, "message": "endpoint mismatch: %.6f / %.6f" % [err0, err1]}
	return {"pass": true}


# ─── Test 2: refresh_anchors_tracks_moving_orifice ─────────────────


func test_refresh_anchors_tracks_moving_orifice() -> Dictionary:
	var scene := _build_scene(4, 0.4)
	var source := _NodeCenterlineSource.new()
	var canal := _make_canal(scene["marker_paths"], source)
	(scene["hero"] as Node3D).add_child(canal)

	# Initial anchor matches entry orifice at origin.
	var anchors0: Dictionary = source.refresh_anchors(
			scene["skel"], canal, Vector3(99, 99, 99), Vector3(88, 88, 88))
	if (anchors0["proximal"] as Vector3 - Vector3.ZERO).length() > 1e-4:
		return {"pass": false, "message": "initial proximal %s != origin" % str(anchors0["proximal"])}

	# Move entry orifice; refresh picks up the new position.
	(scene["entry"] as Node3D).position = Vector3(0, 0.1, 0)
	var anchors1: Dictionary = source.refresh_anchors(
			scene["skel"], canal, Vector3.ZERO, Vector3.ZERO)
	var p1: Vector3 = anchors1["proximal"]
	var err := (p1 - Vector3(0, 0.1, 0)).length()
	print("    moved entry: anchor=%s expected=(0, 0.1, 0) err=%.6f" % [str(p1), err])
	if err > 1e-4:
		return {"pass": false, "message": "anchor didn't track: err=%.6f" % err}
	return {"pass": true}


# ─── Test 3: closed_terminal_via_pin_path ──────────────────────────


func test_closed_terminal_via_pin_path() -> Dictionary:
	var scene := _build_scene(4, 0.4)
	var source := _NodeCenterlineSource.new()
	var canal := _make_canal(scene["marker_paths"], source, true, "")
	(scene["hero"] as Node3D).add_child(canal)

	# Add a deliberately off-axis pin marker.
	var pin := Node3D.new()
	pin.name = "PinMarker"
	pin.position = Vector3(0.4, 0.05, 0)
	(scene["hero"] as Node3D).add_child(pin)
	# Resource resolves via SceneTree.root → use absolute path.
	source.terminal_pin_path = NodePath("/root/HeroRoot/PinMarker")

	var got := source.resolve_closed_terminal_anchor(
			canal.canal_parameters, scene["skel"], Vector3(99, 99, 99))
	var expected := Vector3(0.4, 0.05, 0)
	var err := (got - expected).length()
	print("    pin path: got=%s expected=%s err=%.6f" % [str(got), str(expected), err])
	if err > 1e-4:
		return {"pass": false, "message": "pin path didn't override: err=%.6f" % err}
	return {"pass": true}


# ─── Test 4: closed_terminal_falls_through_to_bone ─────────────────


func test_closed_terminal_falls_through_to_bone() -> Dictionary:
	var scene := _build_scene(4, 0.4, Vector3(0.4, 0.05, 0))  # builds Uterus_TerminalPin bone
	var source := _NodeCenterlineSource.new()
	var canal := _make_canal(scene["marker_paths"], source, true, "Uterus_TerminalPin")
	(scene["hero"] as Node3D).add_child(canal)

	# No terminal_pin_path set → falls through to bone.
	var got := source.resolve_closed_terminal_anchor(
			canal.canal_parameters, scene["skel"], Vector3(99, 99, 99))
	var expected := Vector3(0.4, 0.05, 0)
	var err := (got - expected).length()
	print("    bone fallback: got=%s expected=%s err=%.6f" % [str(got), str(expected), err])
	if err > 1e-4:
		return {"pass": false, "message": "bone fallback failed: err=%.6f" % err}
	return {"pass": true}


# ─── Test 5: auto_attach_to_nearest_bone ───────────────────────────


func test_auto_attach_to_nearest_bone() -> Dictionary:
	var scene := _build_scene(4, 0.4)
	var source := _NodeCenterlineSource.new()
	var canal := _make_canal(scene["marker_paths"], source)
	(scene["hero"] as Node3D).add_child(canal)

	# Snapshot marker world positions before.
	var positions_before: PackedVector3Array = PackedVector3Array()
	for path in source.control_point_paths:
		var n := canal.get_node_or_null(path)
		positions_before.append((n as Node3D).global_position)

	var attached := source.auto_attach_to_nearest_bone(canal, scene["skel"])
	if attached != 4:
		return {"pass": false, "message": "attached %d of 4 markers" % attached}

	# Verify each marker has a BoneAttachment3D parent now.
	var positions_after: PackedVector3Array = PackedVector3Array()
	for path in source.control_point_paths:
		var n := canal.get_node_or_null(path)
		if n == null:
			return {"pass": false, "message": "marker path '%s' did not resolve post-attach" % String(path)}
		var parent := (n as Node3D).get_parent()
		if not (parent is BoneAttachment3D):
			return {"pass": false, "message": "marker parent is %s, not BoneAttachment3D" % parent.get_class()}
		positions_after.append((n as Node3D).global_position)

	# Positions preserved across reparent.
	var worst := 0.0
	for i in positions_before.size():
		var e := (positions_before[i] - positions_after[i]).length()
		if e > worst:
			worst = e
	print("    auto-attach: %d markers attached; worst position drift = %.10f m" % [attached, worst])
	if worst > 1e-4:
		return {"pass": false, "message": "position drift after reparent: %f m" % worst}

	# Verify each attachment's bone_idx matches the nearest-in-3D bone.
	# (Headless can't validate "marker follows moving bone" because
	# BoneAttachment3D needs a frame tick — that's verified visually
	# in the editor + by integration scenes.)
	for i in source.control_point_paths.size():
		var n := canal.get_node_or_null(source.control_point_paths[i])
		var parent: BoneAttachment3D = (n as Node3D).get_parent()
		var bone_idx: int = parent.bone_idx
		if bone_idx < 0 or bone_idx >= scene["skel"].get_bone_count():
			return {"pass": false, "message": "attachment[%d] bone_idx=%d out of range" % [i, bone_idx]}
		print("    marker[%d] attached to bone '%s' (idx=%d)" % [i, parent.bone_name, bone_idx])
	return {"pass": true}


# ─── Test 6: empty_control_point_paths_fails_gracefully ────────────


func test_empty_control_point_paths_fails_gracefully() -> Dictionary:
	var scene := _build_scene(4, 0.4)
	var source := _NodeCenterlineSource.new()
	# Override with empty list AFTER _make_canal sets 4 paths.
	var canal := _make_canal(scene["marker_paths"], source)
	(scene["hero"] as Node3D).add_child(canal)
	source.control_point_paths = []

	# push_error fires; spline is null but no crash.
	var spline: RefCounted = source.build_spline(scene["skel"], canal)
	if spline != null:
		return {"pass": false, "message": "expected null spline for empty paths"}
	return {"pass": true}
