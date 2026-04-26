extends SceneTree

# End-to-end Phase-3b test: a TentacleMesh bake plumbed into a Tentacle.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_render_with_tentacle_mesh.gd
#
# Verifies that after Tentacle.set_rest_girth_texture() is called with the
# bake's girth texture, get_rest_girth_texture() returns the bake output —
# *not* the 3a uniform-1.0 placeholder.

const _TentacleMesh := preload("res://addons/tentacletech/scripts/procedural/tentacle_mesh.gd")


func _init() -> void:
	if not ClassDB.class_exists("Tentacle"):
		push_error("[FAIL] tentacletech extension not loaded")
		quit(2)
		return

	var passed: int = 0
	var failed: int = 0
	for test_name in [
		"test_tentacle_mesh_assignable",
		"test_rest_girth_texture_replaced_by_bake",
	]:
		if call(test_name):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			push_error("[FAIL] %s" % test_name)
			failed += 1

	print("\n%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func test_tentacle_mesh_assignable() -> bool:
	var tm = _TentacleMesh.new()
	tm.length = 0.4
	tm.length_segments = 12
	tm.radial_segments = 12
	var result: Dictionary = tm.bake()
	var mesh: ArrayMesh = result["mesh"]

	var t: Object = ClassDB.instantiate("Tentacle")
	t.set_tentacle_mesh(mesh)
	var got: ArrayMesh = t.get_tentacle_mesh()
	if got != mesh:
		push_error("Tentacle.tentacle_mesh did not retain the assigned ArrayMesh")
		return false
	return true


# Bake a *non-uniform* mesh (taper from base_radius to tip_radius), pass
# the bake's girth_texture into Tentacle.set_rest_girth_texture, and verify
# the texture data is no longer the all-ones placeholder.
func test_rest_girth_texture_replaced_by_bake() -> bool:
	var tm = _TentacleMesh.new()
	tm.length = 0.4
	tm.base_radius = 0.05
	tm.tip_radius = 0.005
	tm.length_segments = 16
	tm.radial_segments = 12
	var result: Dictionary = tm.bake()
	var girth_tex: ImageTexture = result["girth_texture"]
	if girth_tex == null:
		push_error("bake did not produce a girth_texture")
		return false

	var t: Object = ClassDB.instantiate("Tentacle")
	t.rebuild_chain() # alloc the placeholder
	# Confirm placeholder is uniform 1.0 first (guard against future
	# regressions where the placeholder content changes).
	var placeholder: ImageTexture = t.get_rest_girth_texture()
	var ph_floats: PackedFloat32Array = placeholder.get_image().get_data().to_float32_array()
	for v in ph_floats:
		if absf(v - 1.0) > 1e-3:
			push_error("placeholder no longer uniform 1.0")
			return false

	# Now install the bake's texture.
	t.set_rest_girth_texture(girth_tex)
	var post: ImageTexture = t.get_rest_girth_texture()
	if post != girth_tex:
		push_error("set_rest_girth_texture did not propagate to getter")
		return false

	# Confirm the texture's contents differ from the uniform placeholder —
	# tapered meshes give variation. Tolerance: at least one bin > 5% off
	# from 1.0 means the bake replaced the placeholder.
	var post_floats: PackedFloat32Array = post.get_image().get_data().to_float32_array()
	if post_floats.size() != 256:
		push_error("post girth size %d != 256" % post_floats.size())
		return false
	var has_variation: bool = false
	for v in post_floats:
		if absf(v - 1.0) > 0.05:
			has_variation = true
			break
	if not has_variation:
		push_error("post-bake girth texture is still uniform; expected taper variation")
		return false
	return true
