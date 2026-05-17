extends SceneTree

# Slice — `OrificeBuilder` @tool wrapper + `OrificeGizmoPlugin`.
#
# Tests the data-side of the visual authoring path. The gizmo-plugin's
# handle interactivity is editor-GUI behaviour that can only be
# verified visually; this file covers everything else:
#
#   1. Default-config builder constructs a circular rim at _ready.
#   2. Slit mode produces an ellipse with the right aspect.
#   3. Polygon mode passes custom positions through to add_polygon_rim.
#   4. compute_rim_positions_local matches the inspector params.
#   5. compute_target_area matches the analytic circle / slit area.
#   6. EI lifecycle signals on the inner Orifice forward to the builder.
#   7. preview_enabled = false short-circuits compute_rim_positions
#      (no — preview_enabled gates the gizmo plugin draw, not the
#      compute helper; instead, verify the gizmo plugin can be
#      instantiated cleanly).
#   8. Builder with no orifice_profile / no skeleton_path still builds
#      a rim (forwarding is optional).
#
# Run:
#   godot --path game --headless --script res://tests/tentacletech/test_orifice_builder.gd

const _OrificeBuilderScript := preload("res://addons/tentacletech/scripts/orifice/orifice_builder.gd")
const _OrificeGizmoScript := preload("res://addons/tentacletech/scripts/gizmo_plugin/orifice_gizmo.gd")

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
		"test_default_circle_builds_at_ready",
		"test_slit_mode_produces_ellipse",
		"test_polygon_custom_passes_through",
		"test_compute_rim_positions_matches_params",
		"test_compute_target_area_circle",
		"test_compute_target_area_slit",
		"test_ei_signals_forward_to_builder",
		"test_gizmo_plugin_instantiates_cleanly",
	]:
		_reset_root()
		var result: Dictionary = call(test_name)
		if result.get("pass", false):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			print("[FAIL] %s: %s" % [test_name, result.get("message", "")])
			failed += 1

	print("\nOrificeBuilder + gizmo plugin: %d/%d passed" % [passed, passed + failed])
	quit(0 if failed == 0 else 2)


func _reset_root() -> void:
	for c in root.get_children():
		root.remove_child(c)
		c.free()


func _new_builder() -> Node3D:
	var b: Node3D = _OrificeBuilderScript.new()
	b.name = "OrificeBuilder"
	root.add_child(b)
	return b


# ─── Tests ─────────────────────────────────────────────────────────


func test_default_circle_builds_at_ready() -> Dictionary:
	var b := _new_builder()
	# Default shape_mode = CIRCLE, particles = 8, radius = 0.05.
	# _ready ran when add_child was called.
	var orifice = b.get_orifice()
	if orifice == null:
		return {"pass": false, "message": "inner Orifice is null after _ready"}
	if orifice.get_rim_loop_count() != 1:
		return {"pass": false, "message": "rim_loop_count = %d" % orifice.get_rim_loop_count()}
	var loop_state: Array = orifice.get_rim_loop_state(0)
	if loop_state.size() != 8:
		return {"pass": false, "message": "particle count = %d, expected 8" % loop_state.size()}
	return {"pass": true}


func test_slit_mode_produces_ellipse() -> Dictionary:
	var b := _new_builder()
	b.shape_mode = _OrificeBuilderScript.ShapeMode.SLIT
	b.rim_radius = 0.08
	b.slit_aspect_ratio = 0.4
	b.rim_particle_count = 16
	# Force a rebuild by triggering _ready again — but _ready already
	# ran. For test simplicity, just verify compute_rim_positions_local
	# produces the right shape regardless of whether the inner orifice
	# was rebuilt.
	var positions: PackedVector3Array = b.compute_rim_positions_local()
	if positions.size() != 16:
		return {"pass": false, "message": "expected 16 positions, got %d" % positions.size()}
	# theta=0 → along x with magnitude a = 0.08
	# theta=π/2 → along y with magnitude b = 0.08 × 0.4 = 0.032
	var a_axis: Vector3 = positions[0]  # θ=0
	var b_axis: Vector3 = positions[4]  # θ=π/2 (n=16 → 4 = π/2)
	var a_mag := a_axis.length()
	var b_mag := b_axis.length()
	print("    slit a=%.4f b=%.4f (expected 0.08 / 0.032)" % [a_mag, b_mag])
	if absf(a_mag - 0.08) > 1e-4 or absf(b_mag - 0.032) > 1e-4:
		return {"pass": false, "message": "ellipse axes off: a=%.4f b=%.4f" % [a_mag, b_mag]}
	return {"pass": true}


func test_polygon_custom_passes_through() -> Dictionary:
	var b := _new_builder()
	b.shape_mode = _OrificeBuilderScript.ShapeMode.POLYGON_CUSTOM
	# Triangle of arbitrary shape.
	var custom := PackedVector3Array([
			Vector3(0.05, 0, 0),
			Vector3(-0.025, 0, 0.0433),
			Vector3(-0.025, 0, -0.0433),
	])
	b.custom_positions = custom
	var positions: PackedVector3Array = b.compute_rim_positions_local()
	if positions.size() != 3:
		return {"pass": false, "message": "expected 3 positions, got %d" % positions.size()}
	for i in 3:
		if (positions[i] - custom[i]).length() > 1e-5:
			return {"pass": false, "message": "position %d mismatch" % i}
	return {"pass": true}


func test_compute_rim_positions_matches_params() -> Dictionary:
	var b := _new_builder()
	b.shape_mode = _OrificeBuilderScript.ShapeMode.CIRCLE
	b.rim_radius = 0.07
	b.rim_particle_count = 12
	b.rim_center_offset = Vector3(0, 0.02, 0)
	var positions: PackedVector3Array = b.compute_rim_positions_local()
	if positions.size() != 12:
		return {"pass": false, "message": "size %d" % positions.size()}
	# Each position should be at distance 0.07 from the center offset.
	var worst := 0.0
	var center: Vector3 = b.rim_center_offset
	for i in positions.size():
		var p: Vector3 = positions[i]
		var d: float = (p - center).length()
		worst = maxf(worst, absf(d - 0.07))
	print("    circle worst |r - 0.07| = %.6e m" % worst)
	if worst > 1e-5:
		return {"pass": false, "message": "radius off: worst err %.6e" % worst}
	return {"pass": true}


func test_compute_target_area_circle() -> Dictionary:
	var b := _new_builder()
	b.rim_radius = 0.06
	b.shape_mode = _OrificeBuilderScript.ShapeMode.CIRCLE
	var area: float = b.compute_target_area()
	var expected: float = PI * 0.06 * 0.06
	if absf(area - expected) / expected > 1e-4:
		return {"pass": false, "message": "area %.6f != %.6f" % [area, expected]}
	return {"pass": true}


func test_compute_target_area_slit() -> Dictionary:
	var b := _new_builder()
	b.rim_radius = 0.08
	b.slit_aspect_ratio = 0.5
	b.shape_mode = _OrificeBuilderScript.ShapeMode.SLIT
	var area: float = b.compute_target_area()
	var expected: float = PI * 0.08 * (0.08 * 0.5)
	if absf(area - expected) / expected > 1e-4:
		return {"pass": false, "message": "area %.6f != %.6f" % [area, expected]}
	return {"pass": true}


func test_ei_signals_forward_to_builder() -> Dictionary:
	var b := _new_builder()
	var orifice = b.get_orifice()
	if orifice == null:
		return {"pass": false, "message": "no inner orifice"}
	# Capture forwarded signals.
	var captured: Array = []
	b.entry_interaction_started.connect(func(tid, idx): captured.append([tid, idx]))
	# Emit on the INNER orifice and verify the wrapper re-fires.
	orifice.emit_signal("entry_interaction_started", 99, 3)
	if captured.size() != 1:
		return {"pass": false, "message": "expected 1 forwarded signal, got %d" % captured.size()}
	if captured[0][0] != 99 or captured[0][1] != 3:
		return {"pass": false, "message": "payload wrong: %s" % str(captured[0])}
	return {"pass": true}


func test_gizmo_plugin_instantiates_cleanly() -> Dictionary:
	# `EditorNode3DGizmoPlugin` is editor-only and cannot be
	# constructed in headless. The script preloaded successfully (the
	# `const _OrificeGizmoScript := preload(...)` at the top of this
	# file would fail at parse time on any syntax / load error). Math
	# helpers are static — exercise them to confirm the script is
	# functional, not just syntactically valid.
	var script: GDScript = _OrificeGizmoScript
	if script == null:
		return {"pass": false, "message": "script preload failed"}
	# Exercise the static math helpers (no editor context needed).
	var hit: Variant = script.call("_ray_plane_intersect",
			Vector3(0, 5, 0), Vector3(0, -1, 0),
			Vector3.ZERO, Vector3.UP)
	if hit == null:
		return {"pass": false, "message": "_ray_plane_intersect returned null"}
	var hit_vec: Vector3 = hit
	if (hit_vec - Vector3.ZERO).length() > 1e-5:
		return {"pass": false, "message": "ray-plane hit wrong: %s" % str(hit_vec)}
	# Closest-t along axis: ray straight down 5m above origin, axis = +X
	# through origin → closest point on axis is (0, 0, 0) → t = 0.
	var t: float = script.call("_ray_line_closest_t",
			Vector3(0, 5, 0), Vector3(0, -1, 0),
			Vector3.ZERO, Vector3.RIGHT)
	if is_nan(t) or absf(t) > 1e-5:
		return {"pass": false, "message": "ray-line closest_t wrong: %f" % t}
	return {"pass": true}
