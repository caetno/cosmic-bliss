extends SceneTree

# Authoring-pass slice (2026-05-17) — verifies the four authoring-gap
# closures from the kasumi-ready discussion:
#   (2) Orifice EI lifecycle signals + Canal subscription
#   (3) Canal.is_inactive() flips on EI count
#   (5) OrificeAuthoring.add_circular_rim convenience
# Item (4) `StimulusBus` autoload registration is cross-cutting; it's
# inboxed to top-level for the project.godot edit.
#
# Run:
#   godot --path game --headless --script res://tests/tentacletech/test_authoring_pass.gd

const _CanalParameters = preload("res://addons/tentacletech/scripts/resources/canal_parameters.gd")
const _Canal = preload("res://addons/tentacletech/scripts/canal/canal.gd")
const _OrificeAuthoring = preload("res://addons/tentacletech/scripts/orifice/orifice_authoring.gd")

var _ran: bool = false


func _process(_d: float) -> bool:
	if not _ran:
		_ran = true
		_run()
	return false


func _run() -> void:
	if not ClassDB.class_exists("Orifice"):
		push_error("[FAIL] tentacletech extension not loaded")
		quit(2)
		return

	var passed: int = 0
	var failed: int = 0
	for test_name in [
		"test_orifice_exposes_ei_lifecycle_signals",
		"test_add_circular_rim_builds_n_rim_particles",
		"test_add_circular_rim_target_area_matches_circle",
		"test_add_circular_rim_rejects_bad_args",
		"test_add_polygon_rim_passes_through",
		"test_canal_is_inactive_default",
		"test_canal_subscribes_to_entry_orifice_at_ready",
		"test_canal_subscription_idempotent",
	]:
		_reset_root()
		var result: Dictionary = call(test_name)
		if result.get("pass", false):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			print("[FAIL] %s: %s" % [test_name, result.get("message", "")])
			failed += 1

	print("\nAuthoring-pass slice: %d/%d passed" % [passed, passed + failed])
	quit(0 if failed == 0 else 2)


func _reset_root() -> void:
	for c in root.get_children():
		root.remove_child(c)
		c.free()


func _new_orifice() -> Node3D:
	var o: Node3D = ClassDB.instantiate("Orifice")
	o.name = "TestOrifice"
	root.add_child(o)
	return o


# ─── Test 1: Orifice exposes signals ───────────────────────────────


func test_orifice_exposes_ei_lifecycle_signals() -> Dictionary:
	var o := _new_orifice()
	if not o.has_signal("entry_interaction_started"):
		return {"pass": false, "message": "Orifice missing entry_interaction_started signal"}
	if not o.has_signal("entry_interaction_ended"):
		return {"pass": false, "message": "Orifice missing entry_interaction_ended signal"}
	# Manually emit (no real EI machinery in this test — just verify
	# the signal exists and can be connected to).
	var captured := []
	var handler := func(tid, idx): captured.append([tid, idx])
	o.entry_interaction_started.connect(handler)
	o.emit_signal("entry_interaction_started", 42, 7)
	if captured.size() != 1:
		return {"pass": false, "message": "signal not received"}
	if captured[0][0] != 42 or captured[0][1] != 7:
		return {"pass": false, "message": "signal payload wrong: %s" % str(captured[0])}
	return {"pass": true}


# ─── Tests 2-5: OrificeAuthoring ───────────────────────────────────


func test_add_circular_rim_builds_n_rim_particles() -> Dictionary:
	var o := _new_orifice()
	var loop_idx: int = _OrificeAuthoring.add_circular_rim(o, Vector3.ZERO, 0.05, 8)
	if loop_idx != 0:
		return {"pass": false, "message": "expected loop_idx 0, got %d" % loop_idx}
	if o.get_rim_loop_count() != 1:
		return {"pass": false, "message": "rim_loop_count = %d" % o.get_rim_loop_count()}
	if o.get_rim_loop_state(0).size() != 8:
		return {"pass": false, "message": "particle_count = %d, expected 8" % o.get_rim_loop_state(0).size()}
	return {"pass": true}


func test_add_circular_rim_target_area_matches_circle() -> Dictionary:
	var o := _new_orifice()
	var r := 0.05
	var n := 16
	_OrificeAuthoring.add_circular_rim(o, Vector3.ZERO, r, n)
	var got_area: float = o.get_loop_target_enclosed_area(0)
	var expected_area: float = PI * r * r
	var err := absf(got_area - expected_area) / expected_area
	print("    target_area: got=%f expected=%f rel_err=%f" % [got_area, expected_area, err])
	if err > 1e-4:
		return {"pass": false, "message": "target_area off: rel_err=%f" % err}
	return {"pass": true}


func test_add_circular_rim_rejects_bad_args() -> Dictionary:
	var o := _new_orifice()
	# Too few particles.
	if _OrificeAuthoring.add_circular_rim(o, Vector3.ZERO, 0.05, 2) != -1:
		return {"pass": false, "message": "expected -1 for n=2"}
	# Non-positive radius.
	if _OrificeAuthoring.add_circular_rim(o, Vector3.ZERO, 0.0, 8) != -1:
		return {"pass": false, "message": "expected -1 for radius=0"}
	# Null orifice.
	if _OrificeAuthoring.add_circular_rim(null, Vector3.ZERO, 0.05, 8) != -1:
		return {"pass": false, "message": "expected -1 for null orifice"}
	return {"pass": true}


func test_add_polygon_rim_passes_through() -> Dictionary:
	var o := _new_orifice()
	# Triangle for simplicity — 3 verts, area = 0.5 × 0.04 × 0.04 = 8e-4.
	var positions := PackedVector3Array([
			Vector3(0, 0, 0),
			Vector3(0.04, 0, 0),
			Vector3(0, 0, 0.04),
	])
	var loop_idx: int = _OrificeAuthoring.add_polygon_rim(o, positions, 8e-4, 0.5, 1e-4, 1e-6)
	if loop_idx != 0:
		return {"pass": false, "message": "polygon rim loop_idx = %d" % loop_idx}
	if o.get_rim_loop_state(0).size() != 3:
		return {"pass": false, "message": "particle_count = %d, expected 3" % o.get_rim_loop_state(0).size()}
	return {"pass": true}


# ─── Tests 6-8: Canal subscription + is_inactive ───────────────────


# Build hero root with Skeleton3D + Orifice + Canal.
func _build_hero_with_canal() -> Dictionary:
	var hero := Node3D.new()
	hero.name = "Hero"
	root.add_child(hero)

	var skel := Skeleton3D.new()
	skel.name = "Skeleton3D"
	hero.add_child(skel)
	for i in 3:
		var idx := skel.add_bone("Vag_CP_%d" % i)
		var pos := Vector3(float(i) * 0.1, 0, 0)
		skel.set_bone_rest(idx, Transform3D(Basis.IDENTITY, pos))
		skel.set_bone_pose_position(idx, pos)

	var orifice: Node3D = ClassDB.instantiate("Orifice")
	orifice.name = "VaginaEntry"
	hero.add_child(orifice)

	var params := _CanalParameters.new()
	params.canal_name = StringName("vag")
	params.spline_cp_bone_prefix = StringName("Vag_CP")
	params.canal_axial_segments = 8
	params.canal_angular_sectors = 4
	params.centerline_particle_count = 8
	params.closed_terminal = false
	params.entry_orifice_path = NodePath("VaginaEntry")

	var canal: Node3D = _Canal.new()
	canal.name = "Canal"
	canal.canal_parameters = params
	canal.skeleton_path = NodePath("../Skeleton3D")
	hero.add_child(canal)  # triggers _ready, which subscribes

	return {"hero": hero, "skel": skel, "orifice": orifice, "canal": canal}


func test_canal_is_inactive_default() -> Dictionary:
	var scene := _build_hero_with_canal()
	# No EIs yet → inactive.
	if not scene["canal"].is_inactive():
		return {"pass": false, "message": "Canal active despite zero EIs"}
	# Force override still works.
	(scene["canal"] as Node3D).force_active_for_test = true
	if scene["canal"].is_inactive():
		return {"pass": false, "message": "force_active_for_test didn't override"}
	return {"pass": true}


func test_canal_subscribes_to_entry_orifice_at_ready() -> Dictionary:
	var scene := _build_hero_with_canal()
	var orifice = scene["orifice"]
	var canal = scene["canal"]
	# Simulate an EI start on the orifice (no real tentacle needed —
	# just emit the signal and verify Canal updates its bookkeeping).
	# Use a dummy ObjectID; Canal will try to instance_from_id and skip
	# if it's not a real Node — that's fine, the signal still fires.
	# To exercise the full path we need a real Node so instance_from_id
	# returns something.
	var dummy_tentacle := Node3D.new()
	dummy_tentacle.name = "DummyTentacle"
	(scene["hero"] as Node3D).add_child(dummy_tentacle)
	var t_oid := dummy_tentacle.get_instance_id()

	# DummyTentacle has no `register_active_canal` method — so the
	# canal's _on_ei_started will silently skip the register call but
	# still update _active_ei_counts. Verify is_inactive flips on / off.
	if not canal.is_inactive():
		return {"pass": false, "message": "pre-emit: canal already active"}
	orifice.emit_signal("entry_interaction_started", int(t_oid), 0)
	if canal.is_inactive():
		return {"pass": false, "message": "post-start: canal still inactive"}
	orifice.emit_signal("entry_interaction_ended", int(t_oid))
	if not canal.is_inactive():
		return {"pass": false, "message": "post-end: canal still active"}
	return {"pass": true}


func test_canal_subscription_idempotent() -> Dictionary:
	var scene := _build_hero_with_canal()
	var orifice = scene["orifice"]
	var canal = scene["canal"]
	# Emit start twice for the same tentacle ID; only the 0→1 transition
	# should register; emit end twice; only the 1→0 transition should
	# unregister. Verify by counting via the dictionary.
	var t_oid := 12345
	orifice.emit_signal("entry_interaction_started", t_oid, 0)
	orifice.emit_signal("entry_interaction_started", t_oid, 1)  # nested EI from same tentacle
	if canal.is_inactive():
		return {"pass": false, "message": "after 2× start: canal inactive"}
	orifice.emit_signal("entry_interaction_ended", t_oid)
	if canal.is_inactive():
		return {"pass": false, "message": "after 1× end (count was 2): canal already inactive"}
	orifice.emit_signal("entry_interaction_ended", t_oid)
	if not canal.is_inactive():
		return {"pass": false, "message": "after 2× end: canal still active"}
	# Spurious extra end should not crash.
	orifice.emit_signal("entry_interaction_ended", t_oid)
	return {"pass": true}
