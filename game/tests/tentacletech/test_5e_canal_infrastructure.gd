extends SceneTree

# Slice 5E — Canal infrastructure (2026-05-12).
#
# Verifies the static substrate landed by CanalAutoBaker against
# synthetic test canals built entirely in GDScript:
#   * Skeleton3D with CP bones along a known curve
#   * ArrayMesh tube with CUSTOM0/CUSTOM1/CUSTOM2 attributes
#   * Canal node + CanalParameters resource
#
# No GLB import dependency — production-time end-to-end via real
# kasumi GLB is deferred (blender_bliss tooling not in repo).
#
# Seven sub-tests:
# 1. spline_from_cp_bones — 6 CP bones along quarter-circle, spline
#    has 6 control points sorted by suffix, endpoints match.
# 2. per_cell_rest_radius_cylinder — straight cylinder canal, every
#    cell records radius ≈ 0.05 m ± tessellation error.
# 3. per_cell_rest_radius_oval — oval cross-section (axes 0.07 ×
#    0.05), four cardinal sectors match the expected axis lengths.
# 4. tunnel_state_texture — RGBAF, dimensions match (axial × sectors),
#    R-channel == rest_radius, GBA == (0, 0, 1.0).
# 5. centerline_chain — M particles spaced uniformly in arc length,
#    proximal/distal anchors resolved as expected.
# 6. closed_terminal_canal — TerminalPin bone wins distal anchor.
# 7. per_vert_bake_roundtrip — reconstruction error < 1e-4 m per vert.
# 8. inactive_canal_skips_tick — Canal.tick(dt) early-returns.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_5e_canal_infrastructure.gd

const _CanalParameters = preload("res://addons/tentacletech/scripts/resources/canal_parameters.gd")
const _CanalConstrictionZone = preload("res://addons/tentacletech/scripts/resources/canal_constriction_zone.gd")
const _Canal = preload("res://addons/tentacletech/scripts/canal/canal.gd")
const _CanalAutoBaker = preload("res://addons/tentacletech/scripts/canal/canal_auto_baker.gd")
const _CanalGizmoOverlay = preload("res://addons/tentacletech/scripts/debug/canal_gizmo_overlay.gd")

# Cylinder canal: tube of radius CANAL_RADIUS_M around a straight
# axis. Step 7 should recover this radius at every cell.
const CANAL_RADIUS_M := 0.05
const CYLINDER_AXIAL_SEGMENTS := 12  # mesh-side
const CYLINDER_ANGULAR_SECTORS := 16  # mesh-side, finer than canal grid

# Canal grid (5E test resolution): cheap so per-cell raycasts run fast.
const TEST_AXIAL := 8
const TEST_SECTORS := 4

# Tolerance for tessellation noise. With 16 mesh-side angular sectors
# the per-cell ray hits a flat face; the nearest-face distance can be
# slightly less than the analytic radius. Loose enough to absorb that
# without false-failing.
const RADIUS_TOLERANCE := 0.005


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
		"test_spline_from_cp_bones",
		"test_per_cell_rest_radius_cylinder",
		"test_per_cell_rest_radius_oval",
		"test_tunnel_state_texture_allocation",
		"test_centerline_chain_allocation",
		"test_closed_terminal_canal",
		"test_per_vert_bake_roundtrip",
		"test_inactive_canal_skips_tick",
	]:
		_reset_root()
		var result: Dictionary = call(test_name)
		if result.get("pass", false):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			print("[FAIL] %s: %s" % [test_name, result.get("message", "")])
			failed += 1

	print("\n5E canal infrastructure: %d/%d passed" % [passed, passed + failed])
	quit(0 if failed == 0 else 2)


func _reset_root() -> void:
	for c in root.get_children():
		root.remove_child(c)
		c.free()


# ─── Synthetic skeleton / mesh helpers ─────────────────────────────

# Build a skeleton with N CP bones at the given world positions
# (under a "Vag_CP" prefix). Also adds an optional terminal-pin bone.
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


# CP bones along a straight axis from (0,0,0) to (length, 0, 0) at
# N evenly-spaced positions.
func _straight_axis_cp(p_n: int, p_length: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(p_n)
	for i in p_n:
		var t := float(i) / float(p_n - 1)
		out[i] = Vector3(t * p_length, 0, 0)
	return out


# Quarter-circle CP bones in the XZ plane, radius `p_radius`.
func _quarter_circle_cp(p_n: int, p_radius: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(p_n)
	for i in p_n:
		var theta := (PI * 0.5) * float(i) / float(p_n - 1)
		out[i] = Vector3(p_radius * cos(theta), 0.0, p_radius * sin(theta))
	return out


# Build a synthetic tube-shaped canal interior mesh wrapping a spline.
# The tube is centered on the spline; vertices live at
# `spline.evaluate(t) + outward(t, θ) * radius_fn(θ)`.
#
# Returns the MeshInstance3D containing the ArrayMesh with CUSTOM0
# set to canal_id+1 on every vert and CUSTOM1/CUSTOM2 zeroed (ready
# for the baker to write).
func _build_tube_mesh(
		p_spline: RefCounted,
		p_canal_id: int,
		p_axial: int,
		p_angular: int,
		p_radius_fn: Callable) -> MeshInstance3D:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var c0 := PackedFloat32Array()
	var c1 := PackedFloat32Array()
	var c2 := PackedFloat32Array()
	var indices := PackedInt32Array()

	verts.resize(p_axial * p_angular)
	normals.resize(p_axial * p_angular)
	c0.resize(p_axial * p_angular * 4)
	c1.resize(p_axial * p_angular * 4)
	c2.resize(p_axial * p_angular * 4)

	for i in p_axial:
		var t := float(i) / float(p_axial - 1)
		var origin: Vector3 = p_spline.evaluate_position(t)
		var frame: Dictionary = p_spline.evaluate_frame(t)
		var normal_axis: Vector3 = (frame["normal"] as Vector3).normalized()
		var binormal_axis: Vector3 = (frame["binormal"] as Vector3).normalized()
		for j in p_angular:
			var theta := TAU * float(j) / float(p_angular)
			var r: float = p_radius_fn.call(theta)
			var outward := normal_axis * cos(theta) + binormal_axis * sin(theta)
			var v_idx := i * p_angular + j
			verts[v_idx] = origin + outward * r
			normals[v_idx] = outward
			c0[v_idx * 4 + 0] = float(p_canal_id + 1)
			# CUSTOM1/CUSTOM2 zeroed; baker writes them.

	# Triangulate: two tris per quad along the tube.
	for i in p_axial - 1:
		for j in p_angular:
			var j2 := (j + 1) % p_angular
			var a := i * p_angular + j
			var b := i * p_angular + j2
			var cc := (i + 1) * p_angular + j
			var d := (i + 1) * p_angular + j2
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

	# Format flags: RGBA-Float CUSTOM channels.
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


# Default circular-radius callable for _build_tube_mesh.
func _circular_radius_fn(_theta: float) -> float:
	return CANAL_RADIUS_M


# Oval cross-section: axes 0.07 (along normal) × 0.05 (along binormal).
# r(θ) = a*b / sqrt((b cos θ)² + (a sin θ)²). a = 0.07 along normal,
# b = 0.05 along binormal.
func _oval_radius_fn(p_theta: float) -> float:
	var a := 0.07
	var b := 0.05
	var co := cos(p_theta)
	var si := sin(p_theta)
	return (a * b) / sqrt(b * b * co * co + a * a * si * si)


# Default CanalParameters for tests. Inline-authored, not loaded from
# .tres — Curve resources need extra setup we don't want in tests.
func _make_default_params(p_prefix: String = "Vag_CP",
		p_closed: bool = false,
		p_terminal_pin_bone: String = "") -> CanalParameters:
	var p := _CanalParameters.new()
	p.canal_name = StringName("test_canal")
	p.spline_cp_bone_prefix = StringName(p_prefix)
	p.canal_axial_segments = TEST_AXIAL
	p.canal_angular_sectors = TEST_SECTORS
	p.centerline_particle_count = 8
	p.closed_terminal = p_closed
	if not p_terminal_pin_bone.is_empty():
		p.terminal_pin_bone = StringName(p_terminal_pin_bone)
	return p


# ─── Test 1: spline_from_cp_bones ──────────────────────────────────

func test_spline_from_cp_bones() -> Dictionary:
	var cps := _quarter_circle_cp(6, 0.5)
	var skel := _build_canal_skeleton(cps)
	var spline := _CanalAutoBaker.build_spline_from_cp_bones(skel, "Vag_CP")
	if spline == null:
		return {"pass": false, "message": "spline build returned null"}
	if spline.get_point_count() != 6:
		return {"pass": false, "message": "expected 6 CPs, got %d" % spline.get_point_count()}
	# Endpoint round-trip.
	var p0: Vector3 = spline.evaluate_position(0.0)
	var p1: Vector3 = spline.evaluate_position(1.0)
	var err0 := (p0 - cps[0]).length()
	var err1 := (p1 - cps[5]).length()
	if err0 > 1e-4 or err1 > 1e-4:
		return {"pass": false,
				"message": "endpoint mismatch: err0=%.6f err1=%.6f" % [err0, err1]}
	# Arc length should be close to true quarter-circle length 0.5 × π/2 ≈ 0.785
	var true_arc := 0.5 * PI * 0.5
	var spline_arc: float = spline.get_arc_length()
	var arc_err_ratio := absf(spline_arc - true_arc) / true_arc
	if arc_err_ratio > 0.05:
		return {"pass": false,
				"message": "arc length off by >5%%: got %.4f, true %.4f" % [spline_arc, true_arc]}
	print("    spline: 6 CPs, endpoint err = %.6f / %.6f, arc length %.4f m (true ~%.4f)"
			% [err0, err1, spline_arc, true_arc])
	return {"pass": true}


# ─── Test 2: per_cell_rest_radius_cylinder ─────────────────────────

func test_per_cell_rest_radius_cylinder() -> Dictionary:
	var cps := _straight_axis_cp(4, 0.4)
	var skel := _build_canal_skeleton(cps)
	var spline := _CanalAutoBaker.build_spline_from_cp_bones(skel, "Vag_CP")
	var mesh_inst := _build_tube_mesh(
			spline, 0,
			CYLINDER_AXIAL_SEGMENTS, CYLINDER_ANGULAR_SECTORS,
			Callable(self, "_circular_radius_fn"))
	var params := _make_default_params()
	var rest_radius := _CanalAutoBaker.compute_per_cell_rest_radius(
			spline, params, mesh_inst, 0)
	if rest_radius.size() != TEST_AXIAL * TEST_SECTORS:
		return {"pass": false,
				"message": "expected %d cells, got %d" % [TEST_AXIAL * TEST_SECTORS, rest_radius.size()]}
	var worst_err := 0.0
	var nan_count := 0
	for r in rest_radius:
		if is_nan(r):
			nan_count += 1
			continue
		var e := absf(r - CANAL_RADIUS_M)
		if e > worst_err:
			worst_err = e
	print("    cylinder per-cell radius: worst |err| = %.6f m (tol %.6f), NaNs = %d"
			% [worst_err, RADIUS_TOLERANCE, nan_count])
	if nan_count > 0:
		return {"pass": false, "message": "NaN cells: %d" % nan_count}
	if worst_err > RADIUS_TOLERANCE:
		return {"pass": false,
				"message": "worst |err| %.6f > tolerance %.6f" % [worst_err, RADIUS_TOLERANCE]}
	return {"pass": true}


# ─── Test 3: per_cell_rest_radius_oval ─────────────────────────────

func test_per_cell_rest_radius_oval() -> Dictionary:
	var cps := _straight_axis_cp(4, 0.4)
	var skel := _build_canal_skeleton(cps)
	var spline := _CanalAutoBaker.build_spline_from_cp_bones(skel, "Vag_CP")
	# Higher mesh-side angular tessellation to keep flat-face error low
	# on the oval cross-section.
	var mesh_inst := _build_tube_mesh(
			spline, 0,
			CYLINDER_AXIAL_SEGMENTS, 32,
			Callable(self, "_oval_radius_fn"))
	var params := _make_default_params()
	params.canal_angular_sectors = 4  # sample θ ∈ {0, π/2, π, 3π/2}
	var rest_radius := _CanalAutoBaker.compute_per_cell_rest_radius(
			spline, params, mesh_inst, 0)
	# Cells at θ_j=0 (j=0) and θ_j=π (j=2) → along normal axis → r=0.07
	# Cells at θ_j=π/2 (j=1) and θ_j=3π/2 (j=3) → along binormal axis → r=0.05
	# We check an interior axial cell (k=4 of 8) to avoid endpoint-frame stretch.
	var k := 4
	var sectors := 4
	var r_normal := rest_radius[k * sectors + 0]
	var r_binormal := rest_radius[k * sectors + 1]
	var r_normal_opp := rest_radius[k * sectors + 2]
	var r_binormal_opp := rest_radius[k * sectors + 3]
	print("    oval cell k=%d: θ=0 r=%.4f, θ=π/2 r=%.4f, θ=π r=%.4f, θ=3π/2 r=%.4f"
			% [k, r_normal, r_binormal, r_normal_opp, r_binormal_opp])
	# Loose bounds (5 mm) to absorb tessellation discretisation.
	if absf(r_normal - 0.07) > 0.005 or absf(r_normal_opp - 0.07) > 0.005:
		return {"pass": false, "message": "normal-axis radii off: %.4f, %.4f (expected ~0.07)"
				% [r_normal, r_normal_opp]}
	if absf(r_binormal - 0.05) > 0.005 or absf(r_binormal_opp - 0.05) > 0.005:
		return {"pass": false, "message": "binormal-axis radii off: %.4f, %.4f (expected ~0.05)"
				% [r_binormal, r_binormal_opp]}
	return {"pass": true}


# ─── Test 4: tunnel_state_texture_allocation ───────────────────────

func test_tunnel_state_texture_allocation() -> Dictionary:
	var params := _make_default_params()
	var rest_radius := PackedFloat32Array()
	rest_radius.resize(TEST_AXIAL * TEST_SECTORS)
	for i in rest_radius.size():
		rest_radius[i] = 0.04 + 0.01 * float(i) / float(rest_radius.size() - 1)
	var tex := _CanalAutoBaker.allocate_tunnel_state_texture(params, rest_radius)
	if tex == null:
		return {"pass": false, "message": "texture is null"}
	var img := tex.get_image()
	if img.get_format() != Image.FORMAT_RGBAF:
		return {"pass": false, "message": "wrong format: got %d, want %d (RGBAF)"
				% [img.get_format(), Image.FORMAT_RGBAF]}
	if img.get_width() != TEST_AXIAL or img.get_height() != TEST_SECTORS:
		return {"pass": false, "message": "wrong size: got %dx%d, want %dx%d"
				% [img.get_width(), img.get_height(), TEST_AXIAL, TEST_SECTORS]}
	# Sample each cell; verify R = rest_radius, GBA = (0, 0, 1).
	var worst := 0.0
	for k in TEST_AXIAL:
		for j in TEST_SECTORS:
			var px := img.get_pixel(k, j)
			var expected_r: float = rest_radius[k * TEST_SECTORS + j]
			var e := absf(px.r - expected_r)
			if e > worst:
				worst = e
			if absf(px.g) > 1e-6 or absf(px.b) > 1e-6 or absf(px.a - 1.0) > 1e-6:
				return {"pass": false,
						"message": "cell (%d,%d) GBA wrong: (%f, %f, %f)" % [k, j, px.g, px.b, px.a]}
	print("    tunnel_state texture: format=RGBAF size=%dx%d, worst R |err| = %.10f"
			% [TEST_AXIAL, TEST_SECTORS, worst])
	if worst > 1e-6:
		return {"pass": false, "message": "R-channel mismatch worst |err| = %.10f" % worst}
	return {"pass": true}


# ─── Test 5: centerline_chain_allocation ───────────────────────────

func test_centerline_chain_allocation() -> Dictionary:
	var cps := _straight_axis_cp(4, 0.4)
	var skel := _build_canal_skeleton(cps)
	var spline := _CanalAutoBaker.build_spline_from_cp_bones(skel, "Vag_CP")
	var params := _make_default_params()
	params.centerline_particle_count = 12
	var chain := _CanalAutoBaker.allocate_centerline_chain(spline, params, skel, null)
	var positions: PackedVector3Array = chain["positions"]
	if positions.size() != 12:
		return {"pass": false, "message": "expected 12 particles, got %d" % positions.size()}
	# Monotonic arc-length increase + uniform spacing along the straight axis.
	var arc: float = spline.get_arc_length()
	var expected_spacing := arc / 11.0
	var worst_spacing_err := 0.0
	for i in range(1, positions.size()):
		var spacing := (positions[i] - positions[i - 1]).length()
		var e := absf(spacing - expected_spacing)
		if e > worst_spacing_err:
			worst_spacing_err = e
	print("    centerline: 12 particles, expected spacing %.6f m, worst err %.6f"
			% [expected_spacing, worst_spacing_err])
	if worst_spacing_err > 1e-3:
		return {"pass": false, "message": "spacing variance too large: %.6f" % worst_spacing_err}
	# Proximal/distal anchors fall back to spline endpoints when no orifices set.
	var proximal: Vector3 = chain["proximal"]
	var distal: Vector3 = chain["distal"]
	if (proximal - positions[0]).length() > 1e-4:
		return {"pass": false, "message": "proximal anchor != spline start"}
	# Default (open canal, no exit orifice path) — distal also falls back.
	if (distal - positions[11]).length() > 1e-4:
		return {"pass": false, "message": "distal anchor != spline end (fallback expected)"}
	return {"pass": true}


# ─── Test 6: closed_terminal_canal ─────────────────────────────────

func test_closed_terminal_canal() -> Dictionary:
	var cps := _straight_axis_cp(4, 0.4)
	# TerminalPin lives ABOVE the spline endpoint (deliberately off-axis)
	# so we can confirm the baker picks the bone, not the spline end.
	var pin_pos := Vector3(0.4, 0.1, 0.0)
	var skel := _build_canal_skeleton(cps, pin_pos)
	var spline := _CanalAutoBaker.build_spline_from_cp_bones(skel, "Vag_CP")
	var params := _make_default_params("Vag_CP", true, "Uterus_TerminalPin")
	params.centerline_particle_count = 8
	var chain := _CanalAutoBaker.allocate_centerline_chain(spline, params, skel, null)
	var distal: Vector3 = chain["distal"]
	var err := (distal - pin_pos).length()
	print("    closed terminal: distal = %s, pin = %s, err = %.6f m" % [distal, pin_pos, err])
	if err > 1e-4:
		return {"pass": false, "message": "distal anchor missed TerminalPin: err %.6f m" % err}
	return {"pass": true}


# ─── Test 7: per_vert_bake_roundtrip ───────────────────────────────

func test_per_vert_bake_roundtrip() -> Dictionary:
	var cps := _straight_axis_cp(4, 0.4)
	var skel := _build_canal_skeleton(cps)
	var spline := _CanalAutoBaker.build_spline_from_cp_bones(skel, "Vag_CP")
	# Use a coarse mesh for the bake — fewer verts to reason about.
	var axial_m := 8
	var angular_m := 12
	var mesh_inst := _build_tube_mesh(spline, 0, axial_m, angular_m,
			Callable(self, "_circular_radius_fn"))
	# Capture original world-space vert positions before bake.
	var orig_arrays: Array = mesh_inst.mesh.surface_get_arrays(0)
	var orig_verts: PackedVector3Array = orig_arrays[Mesh.ARRAY_VERTEX].duplicate()
	# Run step 10.
	var baked := _CanalAutoBaker.bake_canal_interior_verts(mesh_inst, 0, spline)
	if baked != axial_m * angular_m:
		return {"pass": false,
				"message": "expected %d verts baked, got %d" % [axial_m * angular_m, baked]}
	# Re-read arrays after bake (add_surface_from_arrays rebuilt the surface).
	var post_arrays: Array = mesh_inst.mesh.surface_get_arrays(0)
	var c1: PackedFloat32Array = post_arrays[Mesh.ARRAY_CUSTOM1]
	var c2: PackedFloat32Array = post_arrays[Mesh.ARRAY_CUSTOM2]
	var fpv1 := c1.size() / orig_verts.size()
	if fpv1 < 3:
		return {"pass": false, "message": "CUSTOM1 floats/vert %d < 3" % fpv1}
	# Reconstruct each vert from baked (s, θ, rest_radius) and compare.
	var worst_err := 0.0
	for v_idx in orig_verts.size():
		var s: float = c1[v_idx * fpv1 + 0]
		var theta: float = c1[v_idx * fpv1 + 1]
		var rest_r: float = c1[v_idx * fpv1 + 2]
		var t: float = spline.distance_to_parameter(s)
		var origin: Vector3 = spline.evaluate_position(t)
		var frame: Dictionary = spline.evaluate_frame(t)
		var normal: Vector3 = (frame["normal"] as Vector3).normalized()
		var binormal: Vector3 = (frame["binormal"] as Vector3).normalized()
		var outward := normal * cos(theta) + binormal * sin(theta)
		var reconstructed: Vector3 = origin + outward * rest_r
		# `_build_tube_mesh` puts verts at root frame, mesh global xform is
		# identity → world == local.
		var e := (reconstructed - orig_verts[v_idx]).length()
		if e > worst_err:
			worst_err = e
	print("    per-vert bake roundtrip: worst |err| = %.8f m (tol 1.0e-4)" % worst_err)
	if worst_err > 1e-4:
		return {"pass": false, "message": "round-trip error %.8f m > 1e-4 m" % worst_err}
	return {"pass": true}


# ─── Test 8: inactive_canal_skips_tick ─────────────────────────────

func test_inactive_canal_skips_tick() -> Dictionary:
	var canal: Node3D = _Canal.new()
	canal.canal_parameters = _make_default_params()
	root.add_child(canal)
	if not canal.is_inactive():
		return {"pass": false, "message": "5E placeholder should always return true; got false"}
	# tick() must be a no-op. We have no direct observable here, but
	# we can confirm the call completes without error.
	canal.tick(1.0 / 60.0)
	return {"pass": true}
