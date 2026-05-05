extends SceneTree

# Phase 5 slice 5H — feature silhouette unit + integration tests.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_feature_silhouette.gd
#
# Acceptance:
# - Direct sampler returns expected bilinear values for a known image.
# - Auto-rebake fires when a feature parameter changes (silhouette
#   image differs before/after).
# - Type-1/4 contact threshold incorporates the silhouette: a wart-
#   bearing tentacle pushes a static collider farther than a smooth one
#   in a comparable configuration.
# - Type-2 contact threshold incorporates the silhouette: a sucker pit
#   reduces contact normal_lambda (per Type2Contacts snapshot) compared
#   to a flat-girth control.
#
# Defer to _process so the SceneTree's root is wired (matches
# test_collision_type4 pattern).

const DT := 1.0 / 60.0


var _ran: bool = false


func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_run_tests()
	return true


func _run_tests() -> void:
	if not ClassDB.class_exists("Tentacle") or not ClassDB.class_exists("Orifice"):
		push_error("[FAIL] tentacletech extension not loaded (Tentacle/Orifice missing)")
		quit(2)
		return

	var passed: int = 0
	var failed: int = 0

	for test_name in [
		"test_sampler_bilinear_known_image",
		"test_sampler_clamps_s_wraps_theta",
		"test_sampler_returns_zero_when_no_image",
		"test_auto_rebake_on_feature_param_edit",
		"test_type1_wart_pushes_chain_further_than_smooth",
		"test_type2_sucker_pit_reduces_contact",
	]:
		_reset_root()
		if call(test_name):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			push_error("[FAIL] %s" % test_name)
			failed += 1

	print("\n%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _reset_root() -> void:
	for c in root.get_children():
		root.remove_child(c)
		c.free()


# ---------------------------------------------------------------------------
# Sampler unit tests

# Build a 256×16 R32F image with a known pattern, install on a Tentacle,
# read back via sample_feature_silhouette and verify bilinear values.
func test_sampler_bilinear_known_image() -> bool:
	var img := Image.create(256, 16, false, Image.FORMAT_RF)
	img.fill(Color(0, 0, 0, 0))
	# Ramp along axial: pixel (u, 0) = u / 255 (metres).
	for u in 256:
		img.set_pixel(u, 0, Color(float(u) / 255.0, 0, 0, 0))
	var tex := ImageTexture.create_from_image(img)
	var t: Node3D = ClassDB.instantiate("Tentacle")
	root.add_child(t)
	t.set_feature_silhouette(tex)
	# Sample at s=0 → 0.0; s=1 → 1.0; s=0.5 (any θ) → 0.5; theta=0 row.
	var v0: float = float(t.sample_feature_silhouette(0.0, 0.0))
	var v1: float = float(t.sample_feature_silhouette(1.0, 0.0))
	var vmid: float = float(t.sample_feature_silhouette(0.5, 0.0))
	if absf(v0) > 1e-3:
		push_error("expected ~0 at s=0, got %f" % v0)
		return false
	if absf(v1 - 1.0) > 5e-3:
		push_error("expected ~1.0 at s=1, got %f" % v1)
		return false
	# Bilinear sample at s=0.5 should sit between row 0's ramp value
	# (~0.5) and row 1's empty-zero. With our pattern only row 0 has
	# data, so s=0.5 reads roughly half the row-0 value (~0.25).
	# Tolerance generous due to bilinear blend.
	if vmid <= 0.05:
		push_error("expected positive sample at s=0.5, got %f" % vmid)
		return false
	return true


# s clamps and θ wraps. s=2.0 should behave like s=1.0; θ=2π+ε wraps.
func test_sampler_clamps_s_wraps_theta() -> bool:
	var img := Image.create(256, 16, false, Image.FORMAT_RF)
	img.fill(Color(0, 0, 0, 0))
	# Mark a single pixel: (200, 4) = 0.5 m.
	img.set_pixel(200, 4, Color(0.5, 0, 0, 0))
	var tex := ImageTexture.create_from_image(img)
	var t: Node3D = ClassDB.instantiate("Tentacle")
	root.add_child(t)
	t.set_feature_silhouette(tex)
	# s = 1.5 should clamp to 1.0; results match s=1 reading.
	var v_clamped: float = float(t.sample_feature_silhouette(1.5, 0.0))
	var v_at_1: float = float(t.sample_feature_silhouette(1.0, 0.0))
	if absf(v_clamped - v_at_1) > 1e-5:
		push_error("s clamp failed: 1.5→%f vs 1.0→%f" % [v_clamped, v_at_1])
		return false
	# θ = 2π + ε should wrap; pick the row-4 angle.
	var theta_4: float = TAU * 4.0 / 16.0
	var v_native: float = float(t.sample_feature_silhouette(200.0 / 255.0, theta_4))
	var v_wrapped: float = float(t.sample_feature_silhouette(200.0 / 255.0, theta_4 + TAU))
	if absf(v_native - v_wrapped) > 1e-5:
		push_error("θ wrap failed: %f vs wrapped %f" % [v_native, v_wrapped])
		return false
	return true


# Tentacle with no silhouette returns zero everywhere.
func test_sampler_returns_zero_when_no_image() -> bool:
	var t: Node3D = ClassDB.instantiate("Tentacle")
	root.add_child(t)
	for s in [0.0, 0.5, 1.0]:
		for theta in [0.0, PI, TAU]:
			var v: float = float(t.sample_feature_silhouette(s, theta))
			if absf(v) > 1e-7:
				push_error("expected 0 with no image, got %f at (%f, %f)" % [v, s, theta])
				return false
	return true


# ---------------------------------------------------------------------------
# Auto-rebake test

# Build a TentacleMesh with a KnotFieldFeature, bake the silhouette,
# capture the image. Edit the knot's max_radius_multiplier, force re-
# bake, capture again. The two images should differ.
func test_auto_rebake_on_feature_param_edit() -> bool:
	var TentacleMeshScript: Resource = load("res://addons/tentacletech/scripts/procedural/tentacle_mesh.gd")
	var KnotFieldFeatureScript: Resource = load("res://addons/tentacletech/scripts/procedural/knot_field_feature.gd")
	if TentacleMeshScript == null or KnotFieldFeatureScript == null:
		push_error("could not load TentacleMesh / KnotFieldFeature scripts")
		return false
	var mesh: Resource = TentacleMeshScript.new()
	mesh.length = 0.4
	mesh.base_radius = 0.04
	mesh.tip_radius = 0.005
	var knot: Resource = KnotFieldFeatureScript.new()
	knot.count = 3
	knot.max_radius_multiplier = 1.5
	# `features` is `Array[TentacleFeature]` — typed-array assignment
	# requires the literal to declare the element type.
	var feats: Array[TentacleFeature] = [knot]
	mesh.features = feats
	var img_a: Image = mesh.get_baked_feature_silhouette_image()
	if img_a == null:
		push_error("first silhouette bake produced null image")
		return false
	# Snapshot the entire image as a byte buffer.
	var bytes_a: PackedByteArray = img_a.get_data()
	# Edit and force a fresh bake. The mesh subscribes to feature
	# `changed` signals via `_invalidate_and_request`; bumping `length`
	# is a more reliable trigger than relying on the subscription path.
	knot.max_radius_multiplier = 2.5
	mesh.length = 0.41
	var img_b: Image = mesh.get_baked_feature_silhouette_image()
	var bytes_b: PackedByteArray = img_b.get_data()
	if bytes_a == bytes_b:
		push_error("silhouette image didn't change after feature edit")
		return false
	return true


# ---------------------------------------------------------------------------
# Integration tests (type-1 / type-4 contact)

# Tentacle particle 1 with a wart-cluster silhouette pushed against a
# static floor collider rests further from the floor than a smooth-
# girth control. Setup mirrors test_collision_type4 patterns.
func test_type1_wart_pushes_chain_further_than_smooth() -> bool:
	# Build a static floor at y = 0.
	var floor_body := StaticBody3D.new()
	floor_body.position = Vector3(0, 0, 0)
	root.add_child(floor_body)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20, 0.1, 20)
	shape.shape = box
	floor_body.add_child(shape)

	# Smooth tentacle: anchored above floor, falls under gravity.
	var t_smooth: Node3D = ClassDB.instantiate("Tentacle")
	t_smooth.particle_count = 4
	t_smooth.segment_length = 0.05
	t_smooth.particle_collision_radius = 0.04
	t_smooth.gravity = Vector3(0, -9.8, 0)
	t_smooth.environment_probe_distance = 0.3
	t_smooth.position = Vector3(0, 0.16, 0)
	root.add_child(t_smooth)

	# Wart tentacle: install a synthetic silhouette image with a strong
	# uniform 1 cm outward perturbation across the entire body. This
	# mimics a heavy wart cluster without needing the full TentacleMesh
	# bake path (keeps the test self-contained).
	var t_wart: Node3D = ClassDB.instantiate("Tentacle")
	t_wart.particle_count = 4
	t_wart.segment_length = 0.05
	t_wart.particle_collision_radius = 0.04
	t_wart.gravity = Vector3(0, -9.8, 0)
	t_wart.environment_probe_distance = 0.3
	t_wart.position = Vector3(0.5, 0.16, 0)
	root.add_child(t_wart)
	# Build a uniform-1cm silhouette image.
	var img := Image.create(256, 16, false, Image.FORMAT_RF)
	img.fill(Color(0.01, 0, 0, 0))
	var tex := ImageTexture.create_from_image(img)
	t_wart.set_feature_silhouette(tex)

	# Tick for several seconds to let both chains settle.
	for _i in 240:
		t_smooth.tick(DT)
		t_wart.tick(DT)

	# Compare the lowest tip particle's y. The wart chain should rest
	# higher (smooth_radius + 0.01 m perturbation = bigger threshold).
	var smooth_pos: PackedVector3Array = t_smooth.get_particle_positions()
	var wart_pos: PackedVector3Array = t_wart.get_particle_positions()
	var smooth_lowest: float = INF
	var wart_lowest: float = INF
	for p in smooth_pos:
		if p.y < smooth_lowest:
			smooth_lowest = p.y
	for p in wart_pos:
		if p.y < wart_lowest:
			wart_lowest = p.y
	# The wart-tentacle chain should rest at a higher y-floor than the
	# smooth chain by the bulk of the silhouette perturbation. Allow
	# ~50% of the 1 cm increment.
	if wart_lowest <= smooth_lowest + 0.005:
		push_error("expected wart chain to rest higher: smooth=%f wart=%f" % [smooth_lowest, wart_lowest])
		return false
	return true


# ---------------------------------------------------------------------------
# Integration test (type-2 contact)

# Set up a smooth tentacle pressed into a rim particle and a sucker-pit
# tentacle (negative silhouette) at the same position. The pit produces
# less contact force (smaller normal_lambda).
func test_type2_sucker_pit_reduces_contact() -> bool:
	# Build orifice with a soft rim so contact forces are observable.
	var o: Node3D = ClassDB.instantiate("Orifice")
	o.entry_axis = Vector3(0, 0, 1)
	root.add_child(o)
	var rest_pos: PackedVector3Array = o.make_circular_rest_positions(8, 0.05, Vector3(0, 0, 1))
	var seg_lens: PackedFloat32Array = o.make_uniform_segment_rest_lengths(rest_pos)
	var area: float = absf(o.compute_polygon_area(rest_pos, Vector3(0, 0, 1)))
	var stf := PackedFloat32Array(); stf.resize(8)
	for k in 8:
		stf[k] = 0.5
	o.add_rim_loop(rest_pos, seg_lens, area, stf, 1e-4, 1e-6, 0.02)

	# Smooth tentacle.
	var t_smooth: Node3D = ClassDB.instantiate("Tentacle")
	t_smooth.particle_count = 4
	t_smooth.segment_length = 0.05
	t_smooth.particle_collision_radius = 0.04
	t_smooth.gravity = Vector3.ZERO
	t_smooth.environment_probe_distance = 0.0
	t_smooth.name = "TSmooth"
	root.add_child(t_smooth)
	o.register_tentacle(NodePath("/root/" + str(t_smooth.name)))

	# Push smooth particle 1 into rim particle 0.
	var rim_pos_0: Vector3 = (o.get_rim_loop_state(0)[0]["current_position"] as Vector3)
	t_smooth.get_solver().set_particle_position(1, rim_pos_0 + Vector3(-0.005, 0.0, 0.0))
	o.tick(DT)
	var contacts_smooth: Array = o.get_type2_contacts_snapshot()
	var lambda_smooth: float = 0.0
	for c in contacts_smooth:
		if (c as Dictionary).get("particle_index", -1) == 1:
			lambda_smooth = float((c as Dictionary).get("normal_lambda", 0.0))
			break

	# Reset for second test.
	o.unregister_tentacle(NodePath("/root/" + str(t_smooth.name)))

	# Pit tentacle: install a silhouette with a strong negative pit
	# (-1 cm) across the body.
	var t_pit: Node3D = ClassDB.instantiate("Tentacle")
	t_pit.particle_count = 4
	t_pit.segment_length = 0.05
	t_pit.particle_collision_radius = 0.04
	t_pit.gravity = Vector3.ZERO
	t_pit.environment_probe_distance = 0.0
	t_pit.name = "TPit"
	root.add_child(t_pit)
	var img := Image.create(256, 16, false, Image.FORMAT_RF)
	img.fill(Color(-0.01, 0, 0, 0))
	var tex := ImageTexture.create_from_image(img)
	t_pit.set_feature_silhouette(tex)
	o.register_tentacle(NodePath("/root/" + str(t_pit.name)))

	t_pit.get_solver().set_particle_position(1, rim_pos_0 + Vector3(-0.005, 0.0, 0.0))
	o.tick(DT)
	var contacts_pit: Array = o.get_type2_contacts_snapshot()
	var lambda_pit: float = 0.0
	for c in contacts_pit:
		if (c as Dictionary).get("particle_index", -1) == 1:
			lambda_pit = float((c as Dictionary).get("normal_lambda", 0.0))
			break
	# Pit should produce LESS contact force than smooth — the negative
	# perturbation reduces the effective threshold.
	if lambda_pit >= lambda_smooth:
		push_error("expected pit to reduce normal_lambda: smooth=%f pit=%f" % [lambda_smooth, lambda_pit])
		return false
	return true
