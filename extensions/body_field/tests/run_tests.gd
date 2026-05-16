extends SceneTree

# B2 — body_field test harness. SceneTree + _process one-shot pattern
# (mirrors TentacleTech 5E).
#
# Run from repo root:
#   godot --headless --quit-after 10 \
#     --script /home/caetano/desktop/cosmic-bliss/extensions/body_field/tests/run_tests.gd

var _ran: bool = false


func _process(_d: float) -> bool:
	if not _ran:
		_ran = true
		_run()
	return false


func _run() -> void:
	var passed: int = 0
	var failed: int = 0
	for test_name in [
		"test_body_field_bridge",
		"test_flesh_data_round_trip",
		"test_flesh_data_bad_magic",
		"test_flesh_data_v2_rejected",
		"test_flesh_data_v3_weight_normalization",
		"test_kinematic_targets_lbs",
		# B3 — collision-layer registration + receive_external_impulse + surface tags.
		"test_outer_face_extraction",
		"test_collision_layer_registration",
		"test_receive_external_impulse_split",
		"test_receive_external_impulse_empty_table_noop",
		"test_surface_tag_defaults",
		# §17.1 — BodySurfaceField core (cotan-Laplacian + Cholesky + sphere test).
		"test_surface_field_sphere_radial",
		# §17.2 — real heat-method geodesic distance.
		"test_surface_field_sphere_geodesic",
	]:
		var result: bool = await call(test_name)
		if result:
			passed += 1
		else:
			failed += 1
	print("\n%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func test_body_field_bridge() -> bool:
	# B2 refactor: bridge marker is gone. Smoke-test that the deployed
	# script loads + instantiates as a Node3D (the v1 BodyField surface).
	# All real verification moves to test_kinematic_targets_lbs.
	const SCRIPT_PATH := "res://addons/body_field/runtime/body_field.gd"
	var script: GDScript = load(SCRIPT_PATH) as GDScript
	if script == null:
		print("[FAIL] test_body_field_bridge: failed to load %s" % SCRIPT_PATH)
		return false
	var bf: Node3D = script.new() as Node3D
	if bf == null:
		print("[FAIL] test_body_field_bridge: script.new() returned null or non-Node3D")
		return false
	bf.free()
	print("[PASS] test_body_field_bridge")
	return true


func test_flesh_data_round_trip() -> bool:
	# Build synthetic FleshData, serialize to user:// using the v3 binary
	# layout, load via FleshData.load_bin, and verify every field round-trips
	# (including the new tet_skin_indices / tet_skin_weights).
	const FleshDataScript := preload("res://addons/body_field/runtime/flesh_data.gd")

	var mesh_name := "synthetic_body"

	# 5 tet verts: 4 cube corners + 1 interior point (Godot Y-up).
	var tet_verts := PackedFloat32Array([
		0.0, 0.0, 0.0,
		1.0, 0.0, 0.0,
		0.0, 1.0, 0.0,
		0.0, 0.0, 1.0,
		0.25, 0.25, 0.25,
	])
	# 2 tets, each picks 4 of the 5 verts.
	var tet_cells := PackedInt32Array([
		0, 1, 2, 3,
		1, 2, 3, 4,
	])
	# 3 render verts. bary_uvw rows each ~sum to 1 (we treat (u,v,w,x)
	# where x = 1 - u - v - w as the implicit 4th weight; legacy format
	# stores only (u,v,w), so u+v+w ≤ 1.0 is the well-formedness check).
	var bary_tet_idx := PackedInt32Array([0, 1, 0])
	var bary_uvw := PackedFloat32Array([
		0.25, 0.25, 0.25,   # x = 0.25
		0.40, 0.30, 0.20,   # x = 0.10
		0.10, 0.60, 0.10,   # x = 0.20
	])
	var render_influence := PackedFloat32Array([0.0, 0.5, 1.0])

	# v3: per-tet-vert skin influences. 4 bones per vert, padded with
	# bone index 0 / weight 0. Each vert's 4 weights sum to exactly 1.0
	# so the round-trip assertion stays tight.
	#
	# Layout: slot s of vert i lives at index i*4 + s.
	# 5 verts × 4 slots = 20 entries.
	var tet_skin_indices := PackedInt32Array([
		3, 5, 0, 0,   # vert 0: 2 bones
		1, 2, 4, 0,   # vert 1: 3 bones
		6, 0, 0, 0,   # vert 2: 1 bone
		2, 7, 0, 0,   # vert 3: 2 bones
		1, 2, 3, 4,   # vert 4: 4 bones
	])
	var tet_skin_weights := PackedFloat32Array([
		0.7, 0.3, 0.0, 0.0,
		0.5, 0.3, 0.2, 0.0,
		1.0, 0.0, 0.0, 0.0,
		0.6, 0.4, 0.0, 0.0,
		0.25, 0.25, 0.25, 0.25,
	])

	# Sanity-check the barycentric rows.
	for r in range(3):
		var s := bary_uvw[r * 3 + 0] + bary_uvw[r * 3 + 1] + bary_uvw[r * 3 + 2]
		if s < 0.0 or s > 1.0 + 1e-5:
			print("[FAIL] test_flesh_data_round_trip: bary row %d sums to %f (must be in [0,1])" % [r, s])
			return false

	# Sanity-check the per-vert skin-weight normalization before serialize.
	# Real .bin output from B4 must satisfy this; this fixture must too so
	# the round-trip assertion below stays meaningful.
	for v in range(5):
		var ws := tet_skin_weights[v * 4 + 0] + tet_skin_weights[v * 4 + 1] \
			+ tet_skin_weights[v * 4 + 2] + tet_skin_weights[v * 4 + 3]
		if abs(ws - 1.0) > 1e-5:
			print("[FAIL] test_flesh_data_round_trip: vert %d skin weights sum to %f (expected 1.0)" % [v, ws])
			return false

	var path := "user://test_flesh_data_round_trip.bin"
	if not _write_v3_bin(path, mesh_name, 5, 2, 3,
			tet_verts, tet_cells, bary_tet_idx, bary_uvw, render_influence,
			tet_skin_indices, tet_skin_weights):
		print("[FAIL] test_flesh_data_round_trip: failed to write synthetic .bin")
		return false

	var loaded: Resource = FleshDataScript.load_bin(path)
	if loaded == null:
		print("[FAIL] test_flesh_data_round_trip: load_bin returned null")
		_rm(path)
		return false

	if loaded.mesh_name != mesh_name:
		print("[FAIL] test_flesh_data_round_trip: mesh_name %s != %s" % [loaded.mesh_name, mesh_name])
		_rm(path)
		return false
	if loaded.n_tet_verts != 5 or loaded.n_tet_cells != 2 or loaded.n_render_verts != 3:
		print("[FAIL] test_flesh_data_round_trip: counts mismatch Nv=%d Nt=%d Nr=%d" % [
			loaded.n_tet_verts, loaded.n_tet_cells, loaded.n_render_verts])
		_rm(path)
		return false
	if not _approx_f32(loaded.tet_verts, tet_verts):
		print("[FAIL] test_flesh_data_round_trip: tet_verts mismatch")
		_rm(path)
		return false
	if loaded.tet_cells != tet_cells:
		print("[FAIL] test_flesh_data_round_trip: tet_cells mismatch")
		_rm(path)
		return false
	if loaded.bary_tet_idx != bary_tet_idx:
		print("[FAIL] test_flesh_data_round_trip: bary_tet_idx mismatch")
		_rm(path)
		return false
	if not _approx_f32(loaded.bary_uvw, bary_uvw):
		print("[FAIL] test_flesh_data_round_trip: bary_uvw mismatch")
		_rm(path)
		return false
	if not _approx_f32(loaded.render_influence, render_influence):
		print("[FAIL] test_flesh_data_round_trip: render_influence mismatch")
		_rm(path)
		return false
	if loaded.tet_skin_indices != tet_skin_indices:
		print("[FAIL] test_flesh_data_round_trip: tet_skin_indices mismatch")
		_rm(path)
		return false
	if not _approx_f32(loaded.tet_skin_weights, tet_skin_weights):
		print("[FAIL] test_flesh_data_round_trip: tet_skin_weights mismatch")
		_rm(path)
		return false

	_rm(path)
	print("[PASS] test_flesh_data_round_trip")
	return true


func test_flesh_data_bad_magic() -> bool:
	# Write a file with wrong magic; load_bin must return null. FleshData
	# emits a `push_error` on bad magic — that error in the log is EXPECTED
	# and is the success signal here, not a regression.
	const FleshDataScript := preload("res://addons/body_field/runtime/flesh_data.gd")
	var path := "user://test_flesh_data_bad_magic.bin"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		print("[FAIL] test_flesh_data_bad_magic: cannot open temp file for write")
		return false
	# 'NOPE' instead of 'FLSH'.
	f.store_buffer(PackedByteArray([0x4E, 0x4F, 0x50, 0x45]))
	f.store_32(3)
	f.close()
	var loaded: Resource = FleshDataScript.load_bin(path)
	_rm(path)
	if loaded != null:
		print("[FAIL] test_flesh_data_bad_magic: load_bin should have returned null on bad magic")
		return false
	print("[PASS] test_flesh_data_bad_magic (expected push_error above)")
	return true


func test_flesh_data_v2_rejected() -> bool:
	# Per 05-14 §6: the v3 loader rejects v2 files outright. Write a
	# well-formed v2 header (magic 'FLSH' is VALID; only the version byte
	# is wrong) and assert load_bin returns null. FleshData emits a
	# `push_error` on the bad version — that error in the log is EXPECTED
	# and is the success signal here, not a regression.
	const FleshDataScript := preload("res://addons/body_field/runtime/flesh_data.gd")
	var path := "user://test_flesh_data_v2_rejected.bin"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		print("[FAIL] test_flesh_data_v2_rejected: cannot open temp file for write")
		return false
	# Magic 'FLSH' (valid), version=2 (rejected). We don't bother writing
	# the rest of the v2 body — the version check fires before reading it.
	f.store_buffer(PackedByteArray([0x46, 0x4C, 0x53, 0x48]))
	f.store_32(2)
	f.close()
	var loaded: Resource = FleshDataScript.load_bin(path)
	_rm(path)
	if loaded != null:
		print("[FAIL] test_flesh_data_v2_rejected: load_bin should have returned null on version=2")
		return false
	print("[PASS] test_flesh_data_v2_rejected (expected push_error above)")
	return true


func test_flesh_data_v3_weight_normalization() -> bool:
	# Re-load the round-trip fixture and assert every tet vert's 4 skin
	# weights sum to within 1e-5 of 1.0. This is the load-time invariant
	# the 05-14 §6 spec calls out as a B4 bake-time guarantee.
	const FleshDataScript := preload("res://addons/body_field/runtime/flesh_data.gd")

	# Re-use the same synthetic data as the round-trip test. Kept inline
	# (instead of a shared helper) so each test stays self-contained.
	var tet_verts := PackedFloat32Array([
		0.0, 0.0, 0.0,
		1.0, 0.0, 0.0,
		0.0, 1.0, 0.0,
		0.0, 0.0, 1.0,
		0.25, 0.25, 0.25,
	])
	var tet_cells := PackedInt32Array([
		0, 1, 2, 3,
		1, 2, 3, 4,
	])
	var bary_tet_idx := PackedInt32Array([0, 1, 0])
	var bary_uvw := PackedFloat32Array([
		0.25, 0.25, 0.25,
		0.40, 0.30, 0.20,
		0.10, 0.60, 0.10,
	])
	var render_influence := PackedFloat32Array([0.0, 0.5, 1.0])
	var tet_skin_indices := PackedInt32Array([
		3, 5, 0, 0,
		1, 2, 4, 0,
		6, 0, 0, 0,
		2, 7, 0, 0,
		1, 2, 3, 4,
	])
	var tet_skin_weights := PackedFloat32Array([
		0.7, 0.3, 0.0, 0.0,
		0.5, 0.3, 0.2, 0.0,
		1.0, 0.0, 0.0, 0.0,
		0.6, 0.4, 0.0, 0.0,
		0.25, 0.25, 0.25, 0.25,
	])

	var path := "user://test_flesh_data_v3_weight_normalization.bin"
	if not _write_v3_bin(path, "weight_norm_fixture", 5, 2, 3,
			tet_verts, tet_cells, bary_tet_idx, bary_uvw, render_influence,
			tet_skin_indices, tet_skin_weights):
		print("[FAIL] test_flesh_data_v3_weight_normalization: failed to write synthetic .bin")
		return false

	var loaded: Resource = FleshDataScript.load_bin(path)
	_rm(path)
	if loaded == null:
		print("[FAIL] test_flesh_data_v3_weight_normalization: load_bin returned null")
		return false

	if loaded.tet_skin_weights.size() != loaded.n_tet_verts * 4:
		print("[FAIL] test_flesh_data_v3_weight_normalization: tet_skin_weights.size()=%d != 4*Nv=%d" % [
			loaded.tet_skin_weights.size(), loaded.n_tet_verts * 4])
		return false

	var loaded_weights: PackedFloat32Array = loaded.tet_skin_weights
	for v in range(loaded.n_tet_verts):
		var ws: float = loaded_weights[v * 4 + 0] \
			+ loaded_weights[v * 4 + 1] \
			+ loaded_weights[v * 4 + 2] \
			+ loaded_weights[v * 4 + 3]
		if abs(ws - 1.0) > 1e-5:
			print("[FAIL] test_flesh_data_v3_weight_normalization: vert %d weights sum to %f (expected 1.0 ± 1e-5)" % [v, ws])
			return false

	print("[PASS] test_flesh_data_v3_weight_normalization")
	return true


# --- B2 LBS test --------------------------------------------------------

func test_kinematic_targets_lbs() -> bool:
	# B2 acceptance: kinematic_targets.glsl produces 4-bone weighted LBS
	# that matches a GDScript reference computation within 1e-4.
	#
	# We use a LOCAL RenderingDevice (create_local_rendering_device) here,
	# not the global one. Reasons:
	#   1. In `--headless`, the global RD's submit/sync timing is awkward
	#      (the test would need to wait for the engine to flush a frame).
	#   2. A local RD lets us call submit()/sync() explicitly right after
	#      compute_list_end(), then read back tet_pos deterministically
	#      via buffer_get_data().
	# The production code path stays on the global RD via
	# RenderingServer.get_rendering_device(); the test path injects a
	# local RD via _set_rendering_device_for_test().

	const BodyFieldScript := preload("res://addons/body_field/runtime/body_field.gd")
	const FleshDataScript := preload("res://addons/body_field/runtime/flesh_data.gd")

	# --- Build a synthetic Skeleton3D with 3 bones at non-trivial poses.
	# Rests are all identity at origin so `global_rest_inv = identity` and
	# the skinning matrix reduces to `sw * posed`. With sw = identity:
	# skinning[bone_b] == posed[bone_b], simplifying the GDScript-side
	# reference computation.
	var skel := Skeleton3D.new()
	skel.add_bone("b0")
	skel.add_bone("b1")
	skel.add_bone("b2")
	# Rests stay at the default identity Transform3D — leaving them so the
	# skinning-matrix simplification above holds.

	# Pose 0: identity. Pose 1: translate (1, 0, 0). Pose 2: rotate
	# 90° around Y. (Different transform shapes for coverage.)
	var pose0 := Transform3D.IDENTITY
	var pose1 := Transform3D(Basis.IDENTITY, Vector3(1.0, 0.0, 0.0))
	var pose2 := Transform3D(Basis(Vector3(0, 1, 0), PI / 2.0), Vector3.ZERO)

	# Build a tiny scene root so global_transform / global_pose are
	# well-defined and Skeleton3D processes its pose.
	var root := Node3D.new()
	get_root().add_child(root)
	root.add_child(skel)
	skel.set_bone_pose_position(0, pose0.origin)
	skel.set_bone_pose_rotation(0, pose0.basis.get_rotation_quaternion())
	skel.set_bone_pose_position(1, pose1.origin)
	skel.set_bone_pose_rotation(1, pose1.basis.get_rotation_quaternion())
	skel.set_bone_pose_position(2, pose2.origin)
	skel.set_bone_pose_rotation(2, pose2.basis.get_rotation_quaternion())

	# Skeleton3D updates its global pose lazily; force it.
	skel.force_update_all_bone_transforms()

	# --- Build synthetic FleshData with 4 tet verts.
	var flesh := FleshDataScript.new()
	flesh.mesh_name = "lbs_test"
	flesh.n_tet_verts = 4
	flesh.n_tet_cells = 0
	flesh.n_render_verts = 0
	# Rest positions chosen NOT at origin so translations are visible.
	flesh.tet_verts = PackedFloat32Array([
		0.5, 0.0, 0.0,       # vert 0
		0.0, 0.7, 0.0,       # vert 1
		0.3, 0.3, 0.3,       # vert 2
		1.0, 0.5, 0.2,       # vert 3
	])
	flesh.tet_cells = PackedInt32Array()
	flesh.bary_tet_idx = PackedInt32Array()
	flesh.bary_uvw = PackedFloat32Array()
	flesh.render_influence = PackedFloat32Array()
	# Vert 0: 1-bone bone 0 weight 1.0
	# Vert 1: 1-bone bone 1 weight 1.0
	# Vert 2: 2-bone bone 0 weight 0.5 + bone 1 weight 0.5
	# Vert 3: 2-bone bone 0 weight 0.3 + bone 2 weight 0.7
	flesh.tet_skin_indices = PackedInt32Array([
		0, 0, 0, 0,
		1, 0, 0, 0,
		0, 1, 0, 0,
		0, 2, 0, 0,
	])
	flesh.tet_skin_weights = PackedFloat32Array([
		1.0, 0.0, 0.0, 0.0,
		1.0, 0.0, 0.0, 0.0,
		0.5, 0.5, 0.0, 0.0,
		0.3, 0.7, 0.0, 0.0,
	])

	# --- Compute expected positions in GDScript, mirroring the shader.
	# Skinning matrix = sw * posed * rest_inv. rest = identity so
	# rest_inv = identity. sw = skel.global_transform; force-update above
	# means skel is in the scene tree but root is at identity, so
	# sw == identity. Skinning[b] == posed[b].
	var sw := skel.global_transform
	var skin: Array[Transform3D] = []
	for bi in range(skel.get_bone_count()):
		var posed := skel.get_bone_global_pose(bi)
		var rest_inv := skel.get_bone_global_rest(bi).affine_inverse()
		skin.append(sw * posed * rest_inv)

	var expected: PackedVector3Array = PackedVector3Array()
	expected.resize(flesh.n_tet_verts)
	for v in range(flesh.n_tet_verts):
		var rest_v := Vector3(
			flesh.tet_verts[v * 3 + 0],
			flesh.tet_verts[v * 3 + 1],
			flesh.tet_verts[v * 3 + 2])
		var sum := Vector3.ZERO
		for k in range(4):
			var b: int = flesh.tet_skin_indices[v * 4 + k]
			var w: float = flesh.tet_skin_weights[v * 4 + k]
			sum += w * (skin[b] * rest_v)
		expected[v] = sum

	# --- Create BodyField with local RD and dispatch once.
	var local_rd := RenderingServer.create_local_rendering_device()
	if local_rd == null:
		print("[FAIL] test_kinematic_targets_lbs: create_local_rendering_device returned null")
		root.queue_free()
		return false

	var bf: Node3D = BodyFieldScript.new()
	bf.flesh_data = flesh
	bf.skeleton = skel
	bf._set_rendering_device_for_test(local_rd)
	root.add_child(bf)
	# _ready runs synchronously when adding to tree, so _init_compute()
	# has been called.

	if not bf._compute_ready:
		print("[FAIL] test_kinematic_targets_lbs: _compute_ready is false after _ready()")
		root.queue_free()
		return false

	bf.dispatch_once()
	# Local RD: submit + sync explicitly to make the buffer readable.
	local_rd.submit()
	local_rd.sync()

	var tet_pos_rid: RID = bf.get_tet_positions_buffer_rid()
	if not tet_pos_rid.is_valid():
		print("[FAIL] test_kinematic_targets_lbs: invalid tet_pos buffer RID")
		root.queue_free()
		return false

	var bytes := local_rd.buffer_get_data(tet_pos_rid)
	var actual := bytes.to_float32_array()
	if actual.size() != flesh.n_tet_verts * 3:
		print("[FAIL] test_kinematic_targets_lbs: buffer size %d != %d" % [
			actual.size(), flesh.n_tet_verts * 3])
		root.queue_free()
		return false

	const TOL := 1e-4
	var ok := true
	for v in range(flesh.n_tet_verts):
		var got := Vector3(actual[v * 3 + 0], actual[v * 3 + 1], actual[v * 3 + 2])
		var exp: Vector3 = expected[v]
		if abs(got.x - exp.x) > TOL or abs(got.y - exp.y) > TOL or abs(got.z - exp.z) > TOL:
			print("[FAIL] test_kinematic_targets_lbs: vert %d expected %s got %s" % [v, exp, got])
			ok = false

	# Free BodyField (its _exit_tree() frees the GPU resources it owns on
	# the local RD) before we drop the local RD. Use free() not queue_free()
	# so teardown is synchronous and the RD cleanup ordering is deterministic.
	bf.get_parent().remove_child(bf)
	bf.free()
	root.queue_free()
	# Note: local_rd is owned by us. Godot frees it when the variable goes
	# out of scope at end of function. On some NVIDIA driver builds a stray
	# OpenGL teardown crash can happen at engine exit AFTER this test's
	# pass print; that's a driver-side issue, not a test failure.
	if not ok:
		return false
	print("[PASS] test_kinematic_targets_lbs")
	return true


# --- B3 tests -----------------------------------------------------------

func test_outer_face_extraction() -> bool:
	# Build a 2-tet mesh that shares one face. The shared face becomes
	# interior; all 6 other faces (3 per tet) are outer → 6 outer faces.
	#
	# Verts:
	#   0 (0,0,0)  1 (1,0,0)  2 (0,1,0)  3 (0,0,1)   — tet A
	#   4 (1,1,1)                                     — tet B's 4th vert
	# Tet A = (0,1,2,3)
	# Tet B = (1,2,3,4) — shares the face {1,2,3} with tet A.
	const FleshDataScript := preload("res://addons/body_field/runtime/flesh_data.gd")

	var d: Resource = FleshDataScript.new()
	d.n_tet_verts = 5
	d.n_tet_cells = 2
	d.n_render_verts = 0
	d.tet_verts = PackedFloat32Array([
		0.0, 0.0, 0.0,
		1.0, 0.0, 0.0,
		0.0, 1.0, 0.0,
		0.0, 0.0, 1.0,
		1.0, 1.0, 1.0,
	])
	d.tet_cells = PackedInt32Array([0, 1, 2, 3, 1, 2, 3, 4])

	d._extract_outer_faces()

	if d.n_outer_faces != 6:
		print("[FAIL] test_outer_face_extraction: n_outer_faces = %d (expected 6)" % d.n_outer_faces)
		return false
	if d.outer_faces.size() != 18:
		print("[FAIL] test_outer_face_extraction: outer_faces.size() = %d (expected 18)" % d.outer_faces.size())
		return false

	# Orientation check: every outer face's normal must point AWAY from
	# the centroid of the 5 vertices (loose proxy for "outward" — works
	# for this convex-ish hull).
	var centroid := Vector3.ZERO
	for v in range(5):
		centroid += Vector3(d.tet_verts[v * 3 + 0], d.tet_verts[v * 3 + 1], d.tet_verts[v * 3 + 2])
	centroid /= 5.0
	for fi in range(d.n_outer_faces):
		var a: int = d.outer_faces[fi * 3 + 0]
		var b: int = d.outer_faces[fi * 3 + 1]
		var c: int = d.outer_faces[fi * 3 + 2]
		var pa := Vector3(d.tet_verts[a * 3 + 0], d.tet_verts[a * 3 + 1], d.tet_verts[a * 3 + 2])
		var pb := Vector3(d.tet_verts[b * 3 + 0], d.tet_verts[b * 3 + 1], d.tet_verts[b * 3 + 2])
		var pc := Vector3(d.tet_verts[c * 3 + 0], d.tet_verts[c * 3 + 1], d.tet_verts[c * 3 + 2])
		var nrm: Vector3 = (pb - pa).cross(pc - pa)
		var face_centroid := (pa + pb + pc) / 3.0
		var outward := face_centroid - centroid
		if nrm.dot(outward) <= 0.0:
			print("[FAIL] test_outer_face_extraction: face %d (%d,%d,%d) not outward-oriented" % [fi, a, b, c])
			return false

	# Interior face {1,2,3} must NOT appear as an outer face.
	for fi in range(d.n_outer_faces):
		var a: int = d.outer_faces[fi * 3 + 0]
		var b: int = d.outer_faces[fi * 3 + 1]
		var c: int = d.outer_faces[fi * 3 + 2]
		var s := [a, b, c]
		s.sort()
		if s == [1, 2, 3]:
			print("[FAIL] test_outer_face_extraction: interior face {1,2,3} leaked as outer")
			return false

	print("[PASS] test_outer_face_extraction")
	return true


func test_collision_layer_registration() -> bool:
	# Synthetic BodyField + 2-tet mesh with shared face. _ready() should
	# add a TetProxyBody on LAYER_BODY_PROXY with a populated
	# ConcavePolygonShape3D + body_field_owner WeakRef meta.
	const BodyFieldScript := preload("res://addons/body_field/runtime/body_field.gd")
	const FleshDataScript := preload("res://addons/body_field/runtime/flesh_data.gd")
	const LayersScript := preload("res://addons/body_field/runtime/collision_layers.gd")

	var d: Resource = FleshDataScript.new()
	d.n_tet_verts = 5
	d.n_tet_cells = 2
	d.n_render_verts = 0
	d.tet_verts = PackedFloat32Array([
		0.0, 0.0, 0.0,
		1.0, 0.0, 0.0,
		0.0, 1.0, 0.0,
		0.0, 0.0, 1.0,
		1.0, 1.0, 1.0,
	])
	d.tet_cells = PackedInt32Array([0, 1, 2, 3, 1, 2, 3, 4])
	# 4-bone padded skin data (5 verts × 4 slots).
	d.tet_skin_indices = PackedInt32Array()
	d.tet_skin_indices.resize(20)
	d.tet_skin_weights = PackedFloat32Array()
	d.tet_skin_weights.resize(20)
	for v in range(5):
		# Vert v: bone 0 weight 1.0
		d.tet_skin_indices[v * 4 + 0] = 0
		d.tet_skin_weights[v * 4 + 0] = 1.0
	d._extract_outer_faces()

	var skel := Skeleton3D.new()
	skel.add_bone("b0")
	var root := Node3D.new()
	get_root().add_child(root)
	root.add_child(skel)

	# Inject a local RD so _init_compute() doesn't try the global path.
	var local_rd := RenderingServer.create_local_rendering_device()
	var bf: Node3D = BodyFieldScript.new()
	bf.flesh_data = d
	bf.skeleton = skel
	bf._set_rendering_device_for_test(local_rd)
	root.add_child(bf)

	# Find TetProxyBody.
	var proxy: Node = bf.get_node_or_null("TetProxyBody")
	if proxy == null:
		print("[FAIL] test_collision_layer_registration: TetProxyBody child missing")
		root.queue_free()
		return false
	if not (proxy is AnimatableBody3D):
		print("[FAIL] test_collision_layer_registration: TetProxyBody is not AnimatableBody3D")
		root.queue_free()
		return false
	var ab: AnimatableBody3D = proxy
	if ab.collision_layer != LayersScript.LAYER_BODY_PROXY:
		print("[FAIL] test_collision_layer_registration: collision_layer = %d (expected %d)" % [
			ab.collision_layer, LayersScript.LAYER_BODY_PROXY])
		root.queue_free()
		return false
	if ab.collision_mask != 0:
		print("[FAIL] test_collision_layer_registration: collision_mask = %d (expected 0)" % ab.collision_mask)
		root.queue_free()
		return false

	# CollisionShape3D child with non-null ConcavePolygonShape3D.
	var cs: CollisionShape3D = null
	for child in ab.get_children():
		if child is CollisionShape3D:
			cs = child
			break
	if cs == null:
		print("[FAIL] test_collision_layer_registration: TetProxyBody has no CollisionShape3D child")
		root.queue_free()
		return false
	if not (cs.shape is ConcavePolygonShape3D):
		print("[FAIL] test_collision_layer_registration: shape is not ConcavePolygonShape3D")
		root.queue_free()
		return false
	var shp: ConcavePolygonShape3D = cs.shape
	# 6 outer faces × 3 verts = 18 entries.
	if shp.get_faces().size() != 18:
		print("[FAIL] test_collision_layer_registration: shape.get_faces().size() = %d (expected 18)" % shp.get_faces().size())
		root.queue_free()
		return false

	# Meta check.
	if not ab.has_meta(&"body_field_owner"):
		print("[FAIL] test_collision_layer_registration: missing body_field_owner meta")
		root.queue_free()
		return false
	var wr = ab.get_meta(&"body_field_owner")
	if not (wr is WeakRef):
		print("[FAIL] test_collision_layer_registration: body_field_owner is not a WeakRef")
		root.queue_free()
		return false
	if wr.get_ref() != bf:
		print("[FAIL] test_collision_layer_registration: WeakRef does not point to BodyField")
		root.queue_free()
		return false

	# Teardown.
	bf.get_parent().remove_child(bf)
	bf.free()
	root.queue_free()
	print("[PASS] test_collision_layer_registration")
	return true


func test_receive_external_impulse_split() -> bool:
	# 1-tet mesh; nearest tet vert has weights (0.6, 0.4, 0, 0) on bones
	# (3, 7, 0, 0). Inject a recorder Callable; assert two records with
	# magnitudes 6.0 and 4.0 to the right RIDs.
	const BodyFieldScript := preload("res://addons/body_field/runtime/body_field.gd")
	const FleshDataScript := preload("res://addons/body_field/runtime/flesh_data.gd")

	var d: Resource = FleshDataScript.new()
	d.n_tet_verts = 4
	d.n_tet_cells = 1
	d.n_render_verts = 0
	# 4 tet verts forming one tet at the origin region. Vert 0 sits at
	# the world point we'll probe; vert 0's weights are the (3, 7)
	# 0.6/0.4 split — receive_external_impulse must pick vert 0.
	d.tet_verts = PackedFloat32Array([
		5.0, 0.0, 0.0,    # vert 0 — target
		0.0, 5.0, 0.0,    # vert 1 — far
		0.0, 0.0, 5.0,    # vert 2 — far
		-5.0, 0.0, 0.0,   # vert 3 — far
	])
	d.tet_cells = PackedInt32Array([0, 1, 2, 3])
	d.tet_skin_indices = PackedInt32Array([
		3, 7, 0, 0,   # vert 0 — the interesting one
		0, 0, 0, 0,   # vert 1
		0, 0, 0, 0,   # vert 2
		0, 0, 0, 0,   # vert 3
	])
	d.tet_skin_weights = PackedFloat32Array([
		0.6, 0.4, 0.0, 0.0,
		1.0, 0.0, 0.0, 0.0,
		1.0, 0.0, 0.0, 0.0,
		1.0, 0.0, 0.0, 0.0,
	])
	d._extract_outer_faces()

	# Bare BodyField — no skeleton, no _ready() side-effects we care about.
	# We test the public method surface, not _init_compute() (which would
	# need a Skeleton3D + RD). Setting flesh_data directly is the test path.
	var bf: Node3D = BodyFieldScript.new()
	bf.flesh_data = d

	# Two throwaway RIDs from PhysicsServer3D for bones 3 and 7. Other
	# slots stay invalid (RID()).
	var rid3 := PhysicsServer3D.body_create()
	var rid7 := PhysicsServer3D.body_create()
	var rids: Array[RID] = []
	rids.resize(8)
	for i in range(8):
		rids[i] = RID()
	rids[3] = rid3
	rids[7] = rid7
	bf.set_bone_body_rids(rids)

	# Recorder Callable. Capture calls in a list the test can inspect.
	var records: Array = []
	bf._apply_impulse_to_bone = func(rid: RID, imp: Vector3, pos: Vector3) -> void:
		records.append({"rid": rid, "imp": imp, "pos": pos})

	# World point right at vert 0.
	bf.receive_external_impulse(Vector3(5.0, 0.0, 0.0), Vector3(0.0, 10.0, 0.0), null)

	# Free the BodyField now we're done — bones live until we free them.
	bf.free()

	# Assertions: 2 records, magnitudes 6.0 and 4.0, RIDs match.
	var ok := true
	if records.size() != 2:
		print("[FAIL] test_receive_external_impulse_split: got %d records (expected 2)" % records.size())
		ok = false
	else:
		var got3: Dictionary = {}
		var got7: Dictionary = {}
		for r in records:
			if r.rid == rid3:
				got3 = r
			elif r.rid == rid7:
				got7 = r
		if got3.is_empty():
			print("[FAIL] test_receive_external_impulse_split: no record for rid3")
			ok = false
		elif abs(got3.imp.y - 6.0) > 1e-5 or abs(got3.imp.x) > 1e-5 or abs(got3.imp.z) > 1e-5:
			print("[FAIL] test_receive_external_impulse_split: rid3 impulse %s (expected (0,6,0))" % got3.imp)
			ok = false
		if got7.is_empty():
			print("[FAIL] test_receive_external_impulse_split: no record for rid7")
			ok = false
		elif abs(got7.imp.y - 4.0) > 1e-5 or abs(got7.imp.x) > 1e-5 or abs(got7.imp.z) > 1e-5:
			print("[FAIL] test_receive_external_impulse_split: rid7 impulse %s (expected (0,4,0))" % got7.imp)
			ok = false

	PhysicsServer3D.free_rid(rid3)
	PhysicsServer3D.free_rid(rid7)

	if not ok:
		return false
	print("[PASS] test_receive_external_impulse_split")
	return true


func test_receive_external_impulse_empty_table_noop() -> bool:
	# Same setup as above but no set_bone_body_rids() call. Recorder must
	# stay empty.
	const BodyFieldScript := preload("res://addons/body_field/runtime/body_field.gd")
	const FleshDataScript := preload("res://addons/body_field/runtime/flesh_data.gd")

	var d: Resource = FleshDataScript.new()
	d.n_tet_verts = 1
	d.n_tet_cells = 0
	d.n_render_verts = 0
	d.tet_verts = PackedFloat32Array([5.0, 0.0, 0.0])
	d.tet_cells = PackedInt32Array()
	d.tet_skin_indices = PackedInt32Array([3, 7, 0, 0])
	d.tet_skin_weights = PackedFloat32Array([0.6, 0.4, 0.0, 0.0])
	d._extract_outer_faces()

	var bf: Node3D = BodyFieldScript.new()
	bf.flesh_data = d

	var records: Array = []
	bf._apply_impulse_to_bone = func(rid: RID, imp: Vector3, pos: Vector3) -> void:
		records.append({"rid": rid, "imp": imp, "pos": pos})

	bf.receive_external_impulse(Vector3(5.0, 0.0, 0.0), Vector3(0.0, 10.0, 0.0), null)

	bf.free()

	if records.size() != 0:
		print("[FAIL] test_receive_external_impulse_empty_table_noop: got %d records (expected 0)" % records.size())
		return false
	print("[PASS] test_receive_external_impulse_empty_table_noop")
	return true


func test_surface_tag_defaults() -> bool:
	# Round-trip a v3 .bin (no v3 trailer) and assert the surface-tag
	# accessors return defaults: 0 for region id, {} for material.
	const BodyFieldScript := preload("res://addons/body_field/runtime/body_field.gd")
	const FleshDataScript := preload("res://addons/body_field/runtime/flesh_data.gd")

	# Minimal 1-tet payload, sufficient for the loader.
	var tet_verts := PackedFloat32Array([
		0.0, 0.0, 0.0,
		1.0, 0.0, 0.0,
		0.0, 1.0, 0.0,
		0.0, 0.0, 1.0,
	])
	var tet_cells := PackedInt32Array([0, 1, 2, 3])
	var bary_tet_idx := PackedInt32Array()
	var bary_uvw := PackedFloat32Array()
	var render_influence := PackedFloat32Array()
	var tet_skin_indices := PackedInt32Array()
	tet_skin_indices.resize(16)  # 4 verts × 4 slots, all 0
	var tet_skin_weights := PackedFloat32Array()
	tet_skin_weights.resize(16)
	for v in range(4):
		tet_skin_weights[v * 4 + 0] = 1.0  # bone 0, weight 1.0

	var path := "user://test_surface_tag_defaults.bin"
	if not _write_v3_bin(path, "surface_tag_default", 4, 1, 0,
			tet_verts, tet_cells, bary_tet_idx, bary_uvw, render_influence,
			tet_skin_indices, tet_skin_weights):
		print("[FAIL] test_surface_tag_defaults: failed to write .bin")
		return false
	var loaded: Resource = FleshDataScript.load_bin(path)
	_rm(path)
	if loaded == null:
		print("[FAIL] test_surface_tag_defaults: load_bin returned null")
		return false

	var bf: Node3D = BodyFieldScript.new()
	bf.flesh_data = loaded

	if bf.get_face_region_id(0) != 0:
		print("[FAIL] test_surface_tag_defaults: get_face_region_id(0) = %d (expected 0)" % bf.get_face_region_id(0))
		bf.free()
		return false
	var mat: Dictionary = bf.get_region_material(0)
	if not mat.is_empty():
		print("[FAIL] test_surface_tag_defaults: get_region_material(0) = %s (expected {})" % mat)
		bf.free()
		return false

	bf.free()
	print("[PASS] test_surface_tag_defaults")
	return true


# --- §17.1 — BodySurfaceField sphere radial-falloff -------------------

func test_surface_field_sphere_radial() -> bool:
	const BodySurfaceFieldScript := preload("res://addons/body_field/runtime/body_surface_field.gd")

	# --- Build sphere ArrayMesh.
	var sphere: SphereMesh = SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 12
	sphere.rings = 6
	var arrays: Array = sphere.surface_get_arrays(0)
	if arrays.is_empty():
		print("[FAIL] test_surface_field_sphere_radial: SphereMesh.surface_get_arrays returned empty")
		return false

	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var n: int = verts.size()
	if n < 8 or indices.size() < 12:
		print("[FAIL] test_surface_field_sphere_radial: degenerate sphere (n=%d, idx=%d)" % [n, indices.size()])
		return false

	# Wrap into a plain ArrayMesh (the consumer-facing source_mesh
	# shape — kasumi will pass an ArrayMesh of the body surface).
	var amesh: ArrayMesh = ArrayMesh.new()
	var a2: Array = []
	a2.resize(Mesh.ARRAY_MAX)
	a2[Mesh.ARRAY_VERTEX] = verts
	a2[Mesh.ARRAY_INDEX] = indices
	amesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a2)

	var field: Node3D = BodySurfaceFieldScript.new()
	field.source_mesh = amesh
	field._ensure_factor()
	if field.factor == null or field.factor.chol_kind == &"none":
		print("[FAIL] test_surface_field_sphere_radial: factor build returned none")
		field.free()
		return false
	if field.factor.chol_kind == &"stub":
		print("[FAIL] test_surface_field_sphere_radial: Cholesky returned stub (non-SPD?)")
		field.free()
		return false

	# Post-weld geometry — Godot's SphereMesh ships UV-seam + pole
	# duplicates that the field's _ensure_factor() welds. Work in the
	# welded vertex space from here on.
	var welded_verts: PackedVector3Array = field.get_source_vertices()
	var n_welded: int = welded_verts.size()
	if n_welded < 8:
		print("[FAIL] test_surface_field_sphere_radial: post-weld n=%d too small" % n_welded)
		field.free()
		return false

	# Seed at welded vertex 0; diffuse one heat step.
	var u0: PackedFloat32Array = PackedFloat32Array()
	u0.resize(n_welded)
	for i in range(n_welded):
		u0[i] = 0.0
	u0[0] = 1.0

	var weights: PackedFloat32Array = field.diffuse(u0)
	if weights.size() != n_welded:
		print("[FAIL] test_surface_field_sphere_radial: diffuse returned %d != %d" % [weights.size(), n_welded])
		field.free()
		return false

	# Antipode = farthest welded vertex from seed (3D distance).
	var antipode: int = -1
	var d_max: float = -1.0
	for i in range(n_welded):
		var d: float = welded_verts[0].distance_to(welded_verts[i])
		if d > d_max:
			d_max = d
			antipode = i
	if antipode < 0:
		print("[FAIL] test_surface_field_sphere_radial: failed to find antipode")
		field.free()
		return false

	# 1. All finite, non-negative within tolerance.
	for i in range(n_welded):
		if not is_finite(weights[i]):
			print("[FAIL] test_surface_field_sphere_radial: non-finite weight at %d (%f)" % [i, weights[i]])
			field.free()
			return false
		if weights[i] < -1.0e-6:
			print("[FAIL] test_surface_field_sphere_radial: significantly negative weight at %d (%f)" % [i, weights[i]])
			field.free()
			return false

	# 2. Peak at seed.
	var w_max: float = -INF
	var argmax: int = -1
	for i in range(n_welded):
		if weights[i] > w_max:
			w_max = weights[i]
			argmax = i
	if argmax != 0:
		print("[FAIL] test_surface_field_sphere_radial: peak at vert %d (w=%f), not seed 0 (w=%f)" % [argmax, w_max, weights[0]])
		field.free()
		return false

	# 3. Antipode is < 10% of peak.
	if weights[antipode] > 0.1 * weights[0]:
		print("[FAIL] test_surface_field_sphere_radial: antipode/peak ratio too high (w[0]=%f, w[antipode=%d]=%f, ratio=%f)" % [weights[0], antipode, weights[antipode], weights[antipode] / weights[0]])
		field.free()
		return false

	# 4. Sum positive.
	var sum: float = 0.0
	for i in range(n_welded):
		sum += weights[i]
	if sum <= 0.0 or not is_finite(sum):
		print("[FAIL] test_surface_field_sphere_radial: weight sum non-positive (%f)" % sum)
		field.free()
		return false

	print("[PASS] test_surface_field_sphere_radial (raw_n=%d, welded_n=%d, w[0]=%f, w[antipode]=%f, ratio=%f)" % [
		n, n_welded, weights[0], weights[antipode], weights[antipode] / weights[0]])
	field.free()
	return true


# --- §17.2 — heat-method geodesic distance ----------------------------

func test_surface_field_sphere_geodesic() -> bool:
	const BodySurfaceFieldScript := preload("res://addons/body_field/runtime/body_surface_field.gd")

	# Build a smoother sphere than §17.1's so the geodesic estimate is
	# closer to the true π·radius. 16 segments × 8 rings ≈ 130 verts
	# pre-weld, ≈ 100 post-weld; coarse-mesh heat-method error is
	# bounded ~5-15%, so we'll accept antipode distance > 2.5 (against
	# the true value π·1.0 = 3.14).
	var sphere: SphereMesh = SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	var arrays: Array = sphere.surface_get_arrays(0)
	if arrays.is_empty():
		print("[FAIL] test_surface_field_sphere_geodesic: empty surface arrays")
		return false

	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

	var amesh: ArrayMesh = ArrayMesh.new()
	var a2: Array = []
	a2.resize(Mesh.ARRAY_MAX)
	a2[Mesh.ARRAY_VERTEX] = verts
	a2[Mesh.ARRAY_INDEX] = indices
	amesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a2)

	var field: Node3D = BodySurfaceFieldScript.new()
	field.source_mesh = amesh
	field._ensure_factor()
	if field.factor == null:
		print("[FAIL] test_surface_field_sphere_geodesic: factor build returned null")
		field.free()
		return false
	if field.factor.chol_kind != &"dense_ll":
		print("[FAIL] test_surface_field_sphere_geodesic: heat factor kind = %s (expected dense_ll)" % field.factor.chol_kind)
		field.free()
		return false
	if field.factor.chol_poisson_kind != &"dense_ll":
		print("[FAIL] test_surface_field_sphere_geodesic: Poisson factor kind = %s (expected dense_ll)" % field.factor.chol_poisson_kind)
		field.free()
		return false

	var welded_verts: PackedVector3Array = field.get_source_vertices()
	var n: int = welded_verts.size()

	# Seed at welded vertex 0; the welded sphere's vert 0 is at the
	# "north pole" because SphereMesh emits pole verts first and they
	# all weld to the same position.
	var seeds: PackedInt32Array = PackedInt32Array([0])
	var phi: PackedFloat32Array = field.diffuse_geodesic(seeds)
	if phi.size() != n:
		print("[FAIL] test_surface_field_sphere_geodesic: phi size %d != n %d" % [phi.size(), n])
		field.free()
		return false

	# Antipode = farthest vert from seed by 3D distance (on a unit
	# sphere this is also the great-circle-farthest vert).
	var antipode: int = -1
	var d_max: float = -1.0
	for i in range(n):
		var d: float = welded_verts[0].distance_to(welded_verts[i])
		if d > d_max:
			d_max = d
			antipode = i
	if antipode < 0:
		print("[FAIL] test_surface_field_sphere_geodesic: failed to find antipode")
		field.free()
		return false

	# 1. All finite.
	for i in range(n):
		if not is_finite(phi[i]):
			print("[FAIL] test_surface_field_sphere_geodesic: non-finite phi[%d]=%f" % [i, phi[i]])
			field.free()
			return false

	# 2. Min is at the seed (after the shift), close to zero.
	if phi[0] > 1.0e-4:
		print("[FAIL] test_surface_field_sphere_geodesic: phi[0]=%f != 0 after shift" % phi[0])
		field.free()
		return false

	# 3. Antipode distance is close to π on a unit sphere. Coarse-mesh
	# heat-method error allows ~15%; require > 2.5 (true 3.14).
	if phi[antipode] < 2.5:
		print("[FAIL] test_surface_field_sphere_geodesic: phi[antipode=%d]=%f < 2.5 (expected ≈ π)" % [antipode, phi[antipode]])
		field.free()
		return false
	if phi[antipode] > 4.0:
		print("[FAIL] test_surface_field_sphere_geodesic: phi[antipode=%d]=%f > 4.0 (expected ≈ π)" % [antipode, phi[antipode]])
		field.free()
		return false

	# 4. Antipode is the max — monotonicity proxy. (Strict per-pair
	# monotonicity would also work but is sensitive to mesh layout;
	# checking the global max-at-antipode catches gross errors.)
	var max_idx: int = 0
	var max_val: float = phi[0]
	for i in range(n):
		if phi[i] > max_val:
			max_val = phi[i]
			max_idx = i
	if max_idx != antipode:
		# Tolerate near-tie: max within 5% of antipode.
		if phi[antipode] < 0.95 * max_val:
			print("[FAIL] test_surface_field_sphere_geodesic: max at vert %d (%f) not antipode %d (%f)" % [
				max_idx, max_val, antipode, phi[antipode]])
			field.free()
			return false

	print("[PASS] test_surface_field_sphere_geodesic (n=%d, phi[antipode=%d]=%f, true_pi=%f, max_at=%d, max=%f)" % [
		n, antipode, phi[antipode], PI, max_idx, max_val])
	field.free()
	return true


# --- Helpers ----------------------------------------------------------

# Serialize a FleshData payload to disk in the v3 format. Lives in the
# test (not on FleshData) — FleshData is read-only at runtime; the .bin
# writer belongs to the Blender authoring chain (slice B4).
func _write_v3_bin(
		path: String,
		mesh_name: String,
		nv: int, nt: int, nr: int,
		tet_verts: PackedFloat32Array,
		tet_cells: PackedInt32Array,
		bary_tet_idx: PackedInt32Array,
		bary_uvw: PackedFloat32Array,
		render_influence: PackedFloat32Array,
		tet_skin_indices: PackedInt32Array,
		tet_skin_weights: PackedFloat32Array) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	# Magic 'FLSH'.
	f.store_buffer(PackedByteArray([0x46, 0x4C, 0x53, 0x48]))
	f.store_32(3)  # version
	var name_bytes := mesh_name.to_utf8_buffer()
	f.store_32(name_bytes.size())
	f.store_buffer(name_bytes)
	f.store_32(nv)
	f.store_32(nt)
	f.store_32(nr)
	# PackedFloat32Array.to_byte_array() is little-endian on all Godot-
	# supported platforms — matches the format spec.
	f.store_buffer(tet_verts.to_byte_array())
	f.store_buffer(tet_cells.to_byte_array())
	f.store_buffer(bary_tet_idx.to_byte_array())
	f.store_buffer(bary_uvw.to_byte_array())
	f.store_buffer(render_influence.to_byte_array())
	f.store_buffer(tet_skin_indices.to_byte_array())
	f.store_buffer(tet_skin_weights.to_byte_array())
	f.close()
	return true


func _approx_f32(a: PackedFloat32Array, b: PackedFloat32Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if not is_equal_approx(a[i], b[i]):
			return false
	return true


func _rm(path: String) -> void:
	# user:// → globalize → DirAccess.remove_absolute().
	var abs := ProjectSettings.globalize_path(path)
	DirAccess.remove_absolute(abs)
