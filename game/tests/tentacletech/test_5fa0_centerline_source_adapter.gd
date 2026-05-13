extends SceneTree

# Slice 5F.A.0 — Centerline source adapter regression (2026-05-13).
#
# Verifies the 5E centerline-rest-position pipeline lifts cleanly
# behind the new `CanalCenterlineSource` abstract. Three tests:
#
#   1. cp_bone_source_build_spline_matches_static — the concrete
#      `CPBoneCenterlineSource.build_spline()` returns a spline whose
#      sampled positions match the legacy direct call to
#      `CanalAutoBaker.build_spline_from_cp_bones()`.
#   2. cp_bone_source_closed_terminal_resolves_pin — the source's
#      `resolve_closed_terminal_anchor()` recovers a TerminalPin bone
#      position (regression of 5E test 6, now via the adapter API).
#   3. bake_with_explicit_source_matches_default — full
#      `CanalAutoBaker.bake()` with `centerline_source = null` (5E
#      back-compat default) produces byte-identical substrate to
#      `centerline_source = CPBoneCenterlineSource.new()` (the same
#      data path, explicit).
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_5fa0_centerline_source_adapter.gd

const _CanalParameters = preload("res://addons/tentacletech/scripts/resources/canal_parameters.gd")
const _Canal = preload("res://addons/tentacletech/scripts/canal/canal.gd")
const _CanalAutoBaker = preload("res://addons/tentacletech/scripts/canal/canal_auto_baker.gd")
const _CanalCenterlineSource = preload("res://addons/tentacletech/scripts/canal/centerline_source.gd")
const _CPBoneCenterlineSource = preload("res://addons/tentacletech/scripts/canal/cp_bone_centerline_source.gd")

const CANAL_RADIUS_M := 0.05
const MESH_AXIAL := 12
const MESH_ANGULAR := 16

const TEST_AXIAL := 8
const TEST_SECTORS := 4

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
		"test_cp_bone_source_build_spline_matches_static",
		"test_cp_bone_source_closed_terminal_resolves_pin",
		"test_bake_with_explicit_source_matches_default",
	]:
		_reset_root()
		var result: Dictionary = call(test_name)
		if result.get("pass", false):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			print("[FAIL] %s: %s" % [test_name, result.get("message", "")])
			failed += 1

	print("\n5F.A.0 centerline source adapter: %d/%d passed" % [passed, passed + failed])
	quit(0 if failed == 0 else 2)


func _reset_root() -> void:
	for c in root.get_children():
		root.remove_child(c)
		c.free()


# ─── Helpers (mirrors of 5E fixtures) ──────────────────────────────


func _straight_axis_cp(p_n: int, p_length: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(p_n)
	for i in p_n:
		var t := float(i) / float(p_n - 1)
		out[i] = Vector3(t * p_length, 0, 0)
	return out


func _build_canal_skeleton(p_cp_positions: PackedVector3Array,
		p_terminal_pin_pos: Variant = null) -> Skeleton3D:
	var skel := Skeleton3D.new()
	skel.name = "Skeleton3D"
	root.add_child(skel)
	for i in p_cp_positions.size():
		var bone_idx := skel.add_bone("Vag_CP_%d" % i)
		var pose := Transform3D(Basis.IDENTITY, p_cp_positions[i])
		skel.set_bone_rest(bone_idx, pose)
		skel.set_bone_pose_position(bone_idx, p_cp_positions[i])
	if p_terminal_pin_pos != null:
		var ti := skel.add_bone("Uterus_TerminalPin")
		var tpos: Vector3 = p_terminal_pin_pos
		skel.set_bone_rest(ti, Transform3D(Basis.IDENTITY, tpos))
		skel.set_bone_pose_position(ti, tpos)
	return skel


func _make_params(p_closed: bool = false,
		p_terminal_pin_bone: String = "") -> CanalParameters:
	var p := _CanalParameters.new()
	p.canal_name = StringName("test_canal")
	p.spline_cp_bone_prefix = StringName("Vag_CP")
	p.canal_axial_segments = TEST_AXIAL
	p.canal_angular_sectors = TEST_SECTORS
	p.centerline_particle_count = 8
	p.closed_terminal = p_closed
	if not p_terminal_pin_bone.is_empty():
		p.terminal_pin_bone = StringName(p_terminal_pin_bone)
	return p


# Make a Canal node with the given source assigned.
func _make_canal(p_params: CanalParameters,
		p_source: CanalCenterlineSource) -> Node3D:
	var canal: Node3D = _Canal.new()
	canal.canal_parameters = p_params
	canal.centerline_source = p_source
	root.add_child(canal)
	return canal


# Tube mesh (cylindrical, radius CANAL_RADIUS_M) around the spline,
# tagged with canal_id+1 on every vert. Same construction as the 5E
# fixture but inlined to keep this test file self-contained.
func _build_tube_mesh(p_spline: RefCounted, p_canal_id: int) -> MeshInstance3D:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var c0 := PackedFloat32Array()
	var c1 := PackedFloat32Array()
	var c2 := PackedFloat32Array()
	var indices := PackedInt32Array()
	verts.resize(MESH_AXIAL * MESH_ANGULAR)
	normals.resize(MESH_AXIAL * MESH_ANGULAR)
	c0.resize(MESH_AXIAL * MESH_ANGULAR * 4)
	c1.resize(MESH_AXIAL * MESH_ANGULAR * 4)
	c2.resize(MESH_AXIAL * MESH_ANGULAR * 4)
	for i in MESH_AXIAL:
		var t := float(i) / float(MESH_AXIAL - 1)
		var origin: Vector3 = p_spline.evaluate_position(t)
		var frame: Dictionary = p_spline.evaluate_frame(t)
		var n_axis: Vector3 = (frame["normal"] as Vector3).normalized()
		var b_axis: Vector3 = (frame["binormal"] as Vector3).normalized()
		for j in MESH_ANGULAR:
			var theta := TAU * float(j) / float(MESH_ANGULAR)
			var outward := n_axis * cos(theta) + b_axis * sin(theta)
			var v_idx := i * MESH_ANGULAR + j
			verts[v_idx] = origin + outward * CANAL_RADIUS_M
			normals[v_idx] = outward
			c0[v_idx * 4 + 0] = float(p_canal_id + 1)
	for i in MESH_AXIAL - 1:
		for j in MESH_ANGULAR:
			var j2 := (j + 1) % MESH_ANGULAR
			var a := i * MESH_ANGULAR + j
			var b := i * MESH_ANGULAR + j2
			var cc := (i + 1) * MESH_ANGULAR + j
			var d := (i + 1) * MESH_ANGULAR + j2
			indices.append(a); indices.append(cc); indices.append(b)
			indices.append(b); indices.append(cc); indices.append(d)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	arrays[Mesh.ARRAY_CUSTOM0] = c0
	arrays[Mesh.ARRAY_CUSTOM1] = c1
	arrays[Mesh.ARRAY_CUSTOM2] = c2
	var fmt := Mesh.ARRAY_FORMAT_CUSTOM0 \
			| Mesh.ARRAY_FORMAT_CUSTOM1 \
			| Mesh.ARRAY_FORMAT_CUSTOM2 \
			| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
			| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT) \
			| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT)
	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, fmt)
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = array_mesh
	root.add_child(mesh_inst)
	return mesh_inst


# ─── Test 1: source.build_spline matches the legacy static call ────


func test_cp_bone_source_build_spline_matches_static() -> Dictionary:
	var cps := _straight_axis_cp(5, 0.4)
	var skel := _build_canal_skeleton(cps)
	var params := _make_params()
	var canal := _make_canal(params, null)

	var legacy: RefCounted = _CanalAutoBaker.build_spline_from_cp_bones(skel, "Vag_CP")
	var source: CanalCenterlineSource = _CPBoneCenterlineSource.new()
	var via_adapter: RefCounted = source.build_spline(skel, canal)

	if legacy == null or via_adapter == null:
		return {"pass": false, "message": "one of the splines is null (legacy=%s, adapter=%s)"
				% [legacy, via_adapter]}
	if legacy.get_point_count() != via_adapter.get_point_count():
		return {"pass": false,
				"message": "CP count mismatch: legacy=%d adapter=%d"
				% [legacy.get_point_count(), via_adapter.get_point_count()]}
	# Compare sampled positions at 32 t-points; arc lengths should match.
	var worst := 0.0
	for i in 32:
		var t := float(i) / 31.0
		var pa: Vector3 = legacy.evaluate_position(t)
		var pb: Vector3 = via_adapter.evaluate_position(t)
		var e := (pa - pb).length()
		if e > worst:
			worst = e
	var arc_err := absf(legacy.get_arc_length() - via_adapter.get_arc_length())
	print("    spline equality: worst pos |err| = %.10f m, arc_len |err| = %.10f m"
			% [worst, arc_err])
	if worst > 1e-6 or arc_err > 1e-6:
		return {"pass": false,
				"message": "spline output diverges: pos=%.10f arc=%.10f" % [worst, arc_err]}
	return {"pass": true}


# ─── Test 2: closed-terminal anchor resolution via the source ──────


func test_cp_bone_source_closed_terminal_resolves_pin() -> Dictionary:
	var cps := _straight_axis_cp(4, 0.4)
	var pin_pos := Vector3(0.4, 0.1, 0.0)
	var skel := _build_canal_skeleton(cps, pin_pos)
	var params := _make_params(true, "Uterus_TerminalPin")
	var source: CanalCenterlineSource = _CPBoneCenterlineSource.new()
	# Fallback would be spline endpoint; pass a deliberately wrong value
	# so we can confirm the resolver overrides it.
	var fallback := Vector3(999, 999, 999)
	var got := source.resolve_closed_terminal_anchor(params, skel, fallback)
	var err := (got - pin_pos).length()
	print("    closed terminal anchor: got=%s expected=%s err=%.10f m"
			% [got, pin_pos, err])
	if err > 1e-6:
		return {"pass": false,
				"message": "anchor missed pin: got=%s expected=%s" % [got, pin_pos]}
	return {"pass": true}


# ─── Test 3: bake() default vs explicit source produce same output ──


func test_bake_with_explicit_source_matches_default() -> Dictionary:
	var cps := _straight_axis_cp(5, 0.4)
	var skel := _build_canal_skeleton(cps)
	var params_default := _make_params()
	var canal_default := _make_canal(params_default, null)
	# Build the spline first so the mesh fixture is identical between runs.
	var pre_spline: RefCounted = _CanalAutoBaker.build_spline_from_cp_bones(skel, "Vag_CP")
	var mesh_default := _build_tube_mesh(pre_spline, 0)
	var ok_default := _CanalAutoBaker.bake(canal_default, mesh_default, skel, 0, null)
	if not ok_default:
		return {"pass": false, "message": "default-source bake failed"}

	# Second canal under a fresh skeleton + fresh mesh, with explicit source.
	# Skeleton + mesh must be rebuilt because bake() mutates the mesh (step 10
	# rewrites surface arrays via clear_surfaces).
	var skel2 := _build_canal_skeleton(cps)
	var params_explicit := _make_params()
	var canal_explicit := _make_canal(params_explicit, _CPBoneCenterlineSource.new())
	var pre_spline2: RefCounted = _CanalAutoBaker.build_spline_from_cp_bones(skel2, "Vag_CP")
	var mesh_explicit := _build_tube_mesh(pre_spline2, 0)
	var ok_explicit := _CanalAutoBaker.bake(canal_explicit, mesh_explicit, skel2, 0, null)
	if not ok_explicit:
		return {"pass": false, "message": "explicit-source bake failed"}

	# Centerline rest positions identical.
	var a: PackedVector3Array = canal_default.get_baked_centerline_rest_positions()
	var b: PackedVector3Array = canal_explicit.get_baked_centerline_rest_positions()
	if a.size() != b.size():
		return {"pass": false, "message": "centerline size mismatch: %d vs %d" % [a.size(), b.size()]}
	var worst_cl := 0.0
	for i in a.size():
		var e := (a[i] - b[i]).length()
		if e > worst_cl:
			worst_cl = e
	# Anchors identical.
	var prox_a: Vector3 = canal_default.get_proximal_anchor_world()
	var prox_b: Vector3 = canal_explicit.get_proximal_anchor_world()
	var prox_err := (prox_a - prox_b).length()
	var dist_a: Vector3 = canal_default.get_distal_anchor_world()
	var dist_b: Vector3 = canal_explicit.get_distal_anchor_world()
	var dist_err := (dist_a - dist_b).length()
	# Per-cell rest-radius identical.
	var ra: PackedFloat32Array = canal_default.get_baked_rest_radius_per_cell()
	var rb: PackedFloat32Array = canal_explicit.get_baked_rest_radius_per_cell()
	if ra.size() != rb.size():
		return {"pass": false, "message": "rest_radius size mismatch"}
	var worst_rr := 0.0
	for i in ra.size():
		var e := absf(ra[i] - rb[i])
		if e > worst_rr:
			worst_rr = e
	print("    bake equality: centerline worst |err| = %.10f m, prox err = %.10f, dist err = %.10f, rest_r worst |err| = %.10f"
			% [worst_cl, prox_err, dist_err, worst_rr])
	if worst_cl > 1e-6 or prox_err > 1e-6 or dist_err > 1e-6 or worst_rr > 1e-6:
		return {"pass": false,
				"message": "bake output diverges: cl=%.10f prox=%.10f dist=%.10f rr=%.10f"
				% [worst_cl, prox_err, dist_err, worst_rr]}
	return {"pass": true}
