extends SceneTree

# B1 — body_field test harness. SceneTree + _process one-shot pattern
# (mirrors TentacleTech 5E). The harness graduates to the Marionette
# internal-`_test_*`-function-list pattern when the test surface multiplies
# further in B2+.
#
# Run from repo root:
#   godot --headless --quit-after 5 \
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
	]:
		var result: bool = call(test_name)
		if result:
			passed += 1
		else:
			failed += 1
	print("\n%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func test_body_field_bridge() -> bool:
	# Pure-GDScript class_name registers in the global script class
	# cache but NOT in ClassDB (which only tracks engine-native + GDExtension
	# classes). Verify via load() against the deployed res:// path — this
	# bridges the full chain: build.sh deploy → res:// resolution →
	# script parse → instantiate → method call.
	const SCRIPT_PATH := "res://addons/body_field/runtime/body_field.gd"
	var script: GDScript = load(SCRIPT_PATH) as GDScript
	if script == null:
		print("[FAIL] test_body_field_bridge: failed to load %s" % SCRIPT_PATH)
		return false
	var bf: Node3D = script.new() as Node3D
	if bf == null:
		print("[FAIL] test_body_field_bridge: script.new() returned null or non-Node3D")
		return false
	if bf._bridge_test_marker() != "body_field ok":
		print("[FAIL] test_body_field_bridge: _bridge_test_marker() returned %s" % bf._bridge_test_marker())
		bf.free()
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
