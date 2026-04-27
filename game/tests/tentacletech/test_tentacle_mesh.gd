extends SceneTree

# TentacleMesh Phase-3b unit tests.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_tentacle_mesh.gd
#
# Acceptance: docs/architecture/TentacleTech_Architecture.md §10.2 +
# extensions/tentacletech/CLAUDE.md sub-step B spec.

const _TentacleMesh := preload("res://addons/tentacletech/scripts/procedural/tentacle_mesh.gd")
const _BakeContextScript := preload("res://addons/tentacletech/scripts/procedural/bake_context.gd")


func _init() -> void:
	var passed: int = 0
	var failed: int = 0

	for test_name in [
		"test_default_bake_vertex_count",
		"test_required_channels_present",
		"test_property_change_changes_mesh",
		"test_deterministic_bake",
		"test_aabb_envelope",
	]:
		if call(test_name):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			push_error("[FAIL] %s" % test_name)
			failed += 1

	print("\n%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func test_default_bake_vertex_count() -> bool:
	var tm = _TentacleMesh.new()
	tm.length_segments = 8
	tm.radial_segments = 12
	var result: Dictionary = tm.bake()
	var mesh: ArrayMesh = result["mesh"]
	if mesh == null:
		push_error("bake().mesh is null")
		return false

	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	# Expected: (length_segments + 1) rings × radial_segments + 1 apex.
	var expected: int = (tm.length_segments + 1) * tm.radial_segments + 1
	if verts.size() != expected:
		push_error("vertex count %d != expected %d" % [verts.size(), expected])
		return false
	return true


func test_required_channels_present() -> bool:
	var tm = _TentacleMesh.new()
	var result: Dictionary = tm.bake()
	var mesh: ArrayMesh = result["mesh"]
	var arrays: Array = mesh.surface_get_arrays(0)

	for ch in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TEX_UV,
			Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_COLOR, Mesh.ARRAY_INDEX]:
		if arrays[ch] == null:
			push_error("required mesh array index %d is null" % ch)
			return false
	# CUSTOM0 is via the format flags + ARRAY_CUSTOM0 — Godot exposes the
	# raw float buffer when the surface has it.
	if arrays[Mesh.ARRAY_CUSTOM0] == null:
		push_error("CUSTOM0 array is null — feature ID channel not authored")
		return false

	# Girth texture exists with the right format.
	var tex: ImageTexture = result["girth_texture"]
	if tex == null:
		push_error("girth_texture is null")
		return false
	var img: Image = tex.get_image()
	if img == null:
		push_error("girth image is null")
		return false
	if img.get_format() != Image.FORMAT_RF:
		push_error("girth image format != RF")
		return false
	if img.get_width() != 256 or img.get_height() != 1:
		push_error("girth image size %dx%d != 256x1" % [img.get_width(), img.get_height()])
		return false
	return true


func test_property_change_changes_mesh() -> bool:
	var tm = _TentacleMesh.new()
	tm.length_segments = 8
	tm.radial_segments = 8
	var v1: int = (tm.bake()["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()

	# Change a base-shape property. Second bake must reflect it.
	tm.length_segments = 16
	var v2: int = (tm.bake()["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()

	if v1 == v2:
		push_error("vertex count unchanged after length_segments doubled (%d → %d)" % [v1, v2])
		return false
	return true


# Two bakes with identical inputs produce identical position arrays
# (deterministic — no random seeds, no time-dependent values).
func test_deterministic_bake() -> bool:
	var tm = _TentacleMesh.new()
	tm.length_segments = 12
	tm.radial_segments = 14
	tm.seam_offset = 0.4
	tm.twist_total = 0.3

	var a: PackedVector3Array = (tm.bake()["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var b: PackedVector3Array = (tm.bake()["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	if a.size() != b.size():
		push_error("non-deterministic vertex count: %d vs %d" % [a.size(), b.size()])
		return false
	for i in a.size():
		if not a[i].is_equal_approx(b[i]):
			push_error("non-deterministic vertex %d: %s vs %s" % [i, a[i], b[i]])
			return false
	return true


# AABB matches the expected envelope (length × peak radius envelope, plus
# tip overrun for the apex point).
func test_aabb_envelope() -> bool:
	var tm = _TentacleMesh.new()
	tm.length = 0.6
	tm.base_radius = 0.05
	tm.tip_radius = 0.005
	tm.length_segments = 12
	tm.radial_segments = 12
	var result: Dictionary = tm.bake()
	var mesh: ArrayMesh = result["mesh"]
	# The mesh's get_aabb() returns custom_aabb (the worst-case spline-
	# deformed envelope used for frustum culling); verify rest-pose extents
	# directly from vertex positions instead.
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var z_min := INF
	var z_max := -INF
	var lat_max := -INF
	for v in verts:
		if v.z < z_min: z_min = v.z
		if v.z > z_max: z_max = v.z
		var lat: float = sqrt(v.x * v.x + v.y * v.y)
		if lat > lat_max: lat_max = lat

	# intrinsic_axis_sign = +1 (§10.1 default) → mesh extends from z=0 to
	# z≈length, with the apex slightly past length. Allow some slack.
	if z_min < -1e-3:
		push_error("rest-pose z_min=%f < 0 (expected ≈0)" % z_min)
		return false
	if z_max < tm.length * 0.99:
		push_error("rest-pose z_max %f < expected ~%f" % [z_max, tm.length])
		return false
	if lat_max < tm.base_radius * 0.95:
		push_error("rest-pose lateral max %f < expected ~%f" % [lat_max, tm.base_radius])
		return false
	return true
