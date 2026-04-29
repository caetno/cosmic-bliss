extends SceneTree

# Phase-3 deferred geometry features (§10.2): KnotField, Ribs, Spines,
# Ribbon, WartCluster. Each test exercises one feature in isolation,
# verifying invariants the bake driver should enforce.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_geometry_features.gd

const _TentacleMesh := preload("res://addons/tentacletech/scripts/procedural/tentacle_mesh.gd")
const _BakeContextScript := preload("res://addons/tentacletech/scripts/procedural/bake_context.gd")
const _KnotField := preload("res://addons/tentacletech/scripts/procedural/knot_field_feature.gd")
const _Ribs := preload("res://addons/tentacletech/scripts/procedural/ribs_feature.gd")
const _Spines := preload("res://addons/tentacletech/scripts/procedural/spines_feature.gd")
const _Ribbon := preload("res://addons/tentacletech/scripts/procedural/ribbon_feature.gd")
const _WartCluster := preload("res://addons/tentacletech/scripts/procedural/wart_cluster_feature.gd")
const _Fin := preload("res://addons/tentacletech/scripts/procedural/fin_feature.gd")


func _init() -> void:
	var passed: int = 0
	var failed: int = 0

	for test_name in [
		"test_knot_field_increases_peak_radius",
		"test_knot_field_skips_non_body_features",
		"test_ribs_decreases_min_radius",
		"test_spines_adds_geometry",
		"test_ribbon_adds_geometry",
		"test_wart_cluster_displaces_body",
		"test_fin_displaces_body",
		"test_disabled_feature_is_noop",
		"test_deterministic_wart_cluster",
		"test_curve_point_edit_invalidates_bake",
		"test_feature_property_edit_invalidates_bake",
		"test_nested_curve_edit_invalidates_bake",
		"test_normals_recomputed_after_knot_displacement",
	]:
		if call(test_name):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			push_error("[FAIL] %s" % test_name)
			failed += 1

	print("\n%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


# Helper: bake and return (vertex_count, peak_radius_in_band).
func _bake_with_features(p_features: Array, p_setup_callable: Callable = Callable()) -> Dictionary:
	var tm = _TentacleMesh.new()
	tm.length = 0.4
	tm.base_radius = 0.04
	tm.tip_radius = 0.005
	tm.length_segments = 24
	tm.radial_segments = 16
	tm.tip_cap_rings = 0  # simpler vertex math for these tests
	if p_setup_callable.is_valid():
		p_setup_callable.call(tm)
	# `features` is typed Array[TentacleFeature]; convert untyped input.
	var typed: Array[TentacleFeature] = []
	for f in p_features:
		typed.append(f)
	tm.features = typed
	return tm.bake()


# A flat-radius bake (no features) gives a baseline peak_radius == base_radius.
# Adding a KnotField with multiplier 1.5 should push peak_radius up
# significantly above base_radius * 1.0 (roughly toward base_radius * 1.5).
func test_knot_field_increases_peak_radius() -> bool:
	var baseline: Dictionary = _bake_with_features([])
	var baseline_peak: float = baseline["peak_radius"]

	var knot = _KnotField.new()
	knot.count = 4
	knot.max_radius_multiplier = 1.5
	knot.t_start = 0.1
	knot.t_end = 0.9
	var withknot: Dictionary = _bake_with_features([knot])
	var knot_peak: float = withknot["peak_radius"]

	if knot_peak <= baseline_peak * 1.1:
		push_error("knot peak_radius %.4f did not exceed baseline %.4f * 1.1"
				% [knot_peak, baseline_peak])
		return false
	# Loose upper bound — Gaussian + discrete sampling won't reach exactly 1.5×.
	if knot_peak > baseline_peak * 1.6:
		push_error("knot peak_radius %.4f exceeded baseline %.4f * 1.6 (overshoot)"
				% [knot_peak, baseline_peak])
		return false
	return true


# Sucker geometry should not be perturbed by a KnotField — only body
# vertices get scaled. Verify by checking that sucker rim/cup vertices
# (FEATURE_ID > BODY) have the same positions before and after KnotField is
# added to the features array.
func test_knot_field_skips_non_body_features() -> bool:
	var SuckerRow := load("res://addons/tentacletech/scripts/procedural/sucker_row_feature.gd")
	var sucker = SuckerRow.new()
	sucker.count = 6
	sucker.side = 2  # ALL_AROUND

	var without_knot: Dictionary = _bake_with_features([sucker])
	var verts_a: PackedVector3Array = (without_knot["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var custom_a: PackedFloat32Array = (without_knot["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_CUSTOM0]

	# Re-bake with sucker + knot.
	var sucker2 = SuckerRow.new()
	sucker2.count = 6
	sucker2.side = 2
	var knot = _KnotField.new()
	knot.count = 4
	knot.max_radius_multiplier = 1.5
	var with_knot: Dictionary = _bake_with_features([sucker2, knot])
	var verts_b: PackedVector3Array = (with_knot["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var custom_b: PackedFloat32Array = (with_knot["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_CUSTOM0]

	if verts_a.size() != verts_b.size():
		push_error("sucker vertex count differs across bakes (%d vs %d)"
				% [verts_a.size(), verts_b.size()])
		return false

	# Compare only sucker (non-body) vertices: their positions must match.
	for i in verts_a.size():
		var fid_a: int = int(custom_a[i * 4])
		var fid_b: int = int(custom_b[i * 4])
		if fid_a != fid_b:
			push_error("feature ID mismatch at vertex %d (%d vs %d)" % [i, fid_a, fid_b])
			return false
		if fid_a == _BakeContextScript.FEATURE_ID_BODY:
			continue
		if not verts_a[i].is_equal_approx(verts_b[i]):
			push_error("non-body vertex %d (fid %d) moved: %s vs %s"
					% [i, fid_a, verts_a[i], verts_b[i]])
			return false
	return true


# RibsFeature scales radius inward at rib centers — the smallest body
# radius after baking should be visibly less than the un-ribbed baseline.
func test_ribs_decreases_min_radius() -> bool:
	var baseline: Dictionary = _bake_with_features([])
	var verts_a: PackedVector3Array = (baseline["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var min_a: float = INF
	for v in verts_a:
		# Skip apex (radius=0) — measure body rings only.
		var r: float = sqrt(v.x * v.x + v.y * v.y)
		if r > 1e-4 and r < min_a:
			min_a = r

	var ribs = _Ribs.new()
	ribs.count = 8
	ribs.depth = 0.3
	ribs.profile = 0  # U
	var withribs: Dictionary = _bake_with_features([ribs])
	var verts_b: PackedVector3Array = (withribs["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var min_b: float = INF
	for v in verts_b:
		var r: float = sqrt(v.x * v.x + v.y * v.y)
		if r > 1e-4 and r < min_b:
			min_b = r

	if min_b >= min_a * 0.9:
		push_error("ribs did not depress min_radius enough: %.5f vs baseline %.5f"
				% [min_b, min_a])
		return false
	return true


# Spines should add `count * (radial_segments + 1)` vertices to the mesh.
func test_spines_adds_geometry() -> bool:
	var baseline: Dictionary = _bake_with_features([])
	var v_baseline: int = (baseline["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()

	var spines = _Spines.new()
	spines.count = 8
	spines.radial_segments = 4
	var withspines: Dictionary = _bake_with_features([spines])
	var v_with: int = (withspines["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()

	var added: int = v_with - v_baseline
	var expected: int = spines.count * (spines.radial_segments + 1)
	if added != expected:
		push_error("spines added %d verts, expected %d" % [added, expected])
		return false
	return true


# Ribbon: each fin is (axial_segments + 1) × 2 vertices.
func test_ribbon_adds_geometry() -> bool:
	var baseline: Dictionary = _bake_with_features([])
	var v_baseline: int = (baseline["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()

	var ribbon = _Ribbon.new()
	ribbon.fin_count = 2
	ribbon.axial_segments = 12
	var withribbon: Dictionary = _bake_with_features([ribbon])
	var v_with: int = (withribbon["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()

	var added: int = v_with - v_baseline
	var expected: int = ribbon.fin_count * (ribbon.axial_segments + 1) * 2
	if added != expected:
		push_error("ribbon added %d verts, expected %d" % [added, expected])
		return false
	return true


# WartCluster is now a vertex-displacement feature: same vertex count as
# the baseline, but body vertices are pushed outward at wart anchors. We
# verify the peak radius increases (some vertex bumps past base_radius)
# while the topology stays unchanged.
func test_wart_cluster_displaces_body() -> bool:
	var setup_dense: Callable = func(tm):
		# Crank radial/length resolution so wart bumps catch enough vertices
		# to move the peak measurably.
		tm.radial_segments = 48
		tm.length_segments = 64
	var baseline: Dictionary = _bake_with_features([], setup_dense)
	var v_baseline: int = (baseline["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
	var peak_baseline: float = baseline["peak_radius"]

	var warts = _WartCluster.new()
	warts.density = 400.0
	warts.max_count = 64
	warts.size_min = 0.02
	warts.size_max = 0.03
	warts.height_factor = 1.0
	warts.seed = 12345
	var withwarts: Dictionary = _bake_with_features([warts], setup_dense)
	var v_with: int = (withwarts["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
	var peak_with: float = withwarts["peak_radius"]

	if v_with != v_baseline:
		push_error("wart cluster changed vertex count (%d → %d) — should be displacement-only"
				% [v_baseline, v_with])
		return false
	if peak_with <= peak_baseline * 1.05:
		push_error("wart cluster did not push body outward: peak %.4f → %.4f"
				% [peak_baseline, peak_with])
		return false
	return true


# FinFeature also displaces body vertices, forming axial ridges. Same
# topology-stable check + peak-radius assertion.
func test_fin_displaces_body() -> bool:
	var setup_dense: Callable = func(tm):
		tm.radial_segments = 48
		tm.length_segments = 32
	var baseline: Dictionary = _bake_with_features([], setup_dense)
	var v_baseline: int = (baseline["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
	var peak_baseline: float = baseline["peak_radius"]

	var fin = _Fin.new()
	fin.count = 2
	fin.max_height = 0.04
	fin.half_width = 0.4
	var withfins: Dictionary = _bake_with_features([fin], setup_dense)
	var v_with: int = (withfins["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
	var peak_with: float = withfins["peak_radius"]

	if v_with != v_baseline:
		push_error("fin feature changed vertex count (%d → %d) — should be displacement-only"
				% [v_baseline, v_with])
		return false
	if peak_with <= peak_baseline * 1.5:
		push_error("fin did not push body outward enough: peak %.4f → %.4f (expected ≳ 1.5×)"
				% [peak_baseline, peak_with])
		return false
	return true


# After a KnotField bumps body vertices outward, normals at bump-flank
# vertices should tilt toward the axial direction (no longer purely
# radial). Verify by sampling normal.z magnitudes — baseline body normals
# have z ≈ 0; post-knot body normals should have at least one with
# |z| > 0.05.
func test_normals_recomputed_after_knot_displacement() -> bool:
	# Filter to body-ring verts strictly inside the body band (z between
	# z_min + ε and z_max_body - ε, with a non-zero radial offset). That
	# excludes both the cap apex (radius ≈ 0) and the cap-axis vertices,
	# whose normals point along +Z by construction.
	var baseline: Dictionary = _bake_with_features([])
	var nbase: float = _max_body_ring_nz(baseline)

	var knot = _KnotField.new()
	knot.count = 5
	knot.max_radius_multiplier = 2.0
	knot.t_start = 0.1
	knot.t_end = 0.9
	var withknot: Dictionary = _bake_with_features([knot])
	var nknot: float = _max_body_ring_nz(withknot)

	# Baseline body rings have |n.z| ≈ 0 (purely radial). Knot bumps tilt
	# normals toward the axis on the bump flanks; expect a clear jump.
	if nknot <= nbase + 0.1:
		push_error("normals not recomputed on body rings: max |n.z| baseline=%.3f knot=%.3f"
				% [nbase, nknot])
		return false
	return true


func _max_body_ring_nz(p_bake: Dictionary) -> float:
	var arrays: Array = (p_bake["mesh"] as ArrayMesh).surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var rest: float = p_bake["rest_length"]
	var max_az: float = 0.0
	for i in verts.size():
		var v: Vector3 = verts[i]
		var t: float = absf(v.z) / rest
		# Skip cap zone (axial position past the body) and axial-line verts.
		if t < 0.05 or t > 0.95:
			continue
		var lat: float = sqrt(v.x * v.x + v.y * v.y)
		if lat < 1e-3:
			continue
		var az: float = absf(normals[i].z)
		if az > max_az:
			max_az = az
	return max_az


# Disabled features must not perturb geometry — vertex count and positions
# match the no-feature baseline.
func test_disabled_feature_is_noop() -> bool:
	var baseline: Dictionary = _bake_with_features([])
	var v_baseline: int = (baseline["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()

	var spines = _Spines.new()
	spines.count = 8
	spines.enabled = false
	var withspines: Dictionary = _bake_with_features([spines])
	var v_with: int = (withspines["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()

	if v_baseline != v_with:
		push_error("disabled spine feature changed vertex count: %d vs %d"
				% [v_baseline, v_with])
		return false
	return true


# Editing the points inside an assigned `radius_curve` (without reassigning
# the reference) must propagate through the curve's `changed` signal and
# trigger a re-bake. Pre-fix: curves only fired on reference replacement,
# so point drags went unnoticed until the next reload.
func test_curve_point_edit_invalidates_bake() -> bool:
	var tm = _TentacleMesh.new()
	tm.length = 0.4
	tm.base_radius = 0.04
	tm.tip_radius = 0.04   # uniform default radius (no implicit taper)
	tm.tip_cap_rings = 0
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 1.0))
	curve.add_point(Vector2(1.0, 1.0))   # flat: radius = 1.0 at all axial t
	tm.radius_curve = curve

	var verts_a: PackedVector3Array = (tm.bake()["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var max_a: float = 0.0
	for v in verts_a:
		var r: float = sqrt(v.x * v.x + v.y * v.y)
		if r > max_a: max_a = r

	# Edit a point IN PLACE — no reassignment of the curve reference.
	curve.set_point_value(1, 4.0)  # tip radius scale 4x

	var verts_b: PackedVector3Array = (tm.bake()["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var max_b: float = 0.0
	for v in verts_b:
		var r: float = sqrt(v.x * v.x + v.y * v.y)
		if r > max_b: max_b = r

	if max_b <= max_a * 1.5:
		push_error("curve point edit did not propagate: max_a=%.4f max_b=%.4f" % [max_a, max_b])
		return false
	return true


# Editing a value-type property on a feature emits the feature's `changed`
# signal (each setter calls emit_changed); TentacleMesh's subscription
# rebuilds the mesh on the next bake.
func test_feature_property_edit_invalidates_bake() -> bool:
	var knot = _KnotField.new()
	knot.count = 4
	knot.max_radius_multiplier = 1.5
	var typed: Array[TentacleFeature] = [knot]

	var tm = _TentacleMesh.new()
	tm.length = 0.4
	tm.base_radius = 0.04
	tm.tip_radius = 0.005
	tm.tip_cap_rings = 0
	tm.features = typed
	var peak_a: float = tm.bake()["peak_radius"]

	# Edit knot.max_radius_multiplier in place — must invalidate the cache.
	knot.max_radius_multiplier = 3.0
	var peak_b: float = tm.bake()["peak_radius"]

	if peak_b <= peak_a * 1.2:
		push_error("feature property edit did not propagate: peak_a=%.4f peak_b=%.4f"
				% [peak_a, peak_b])
		return false
	return true


# Editing a Curve nested inside a feature (e.g., KnotField.spacing_curve)
# fires the curve's `changed` signal, NOT the feature's. The recursive
# subscription walker must catch this — otherwise nested-curve point drags
# go silent.
func test_nested_curve_edit_invalidates_bake() -> bool:
	var ribbon = _Ribbon.new()
	ribbon.fin_count = 1
	ribbon.max_width = 0.05
	var width_curve := Curve.new()
	width_curve.add_point(Vector2(0.0, 1.0))
	width_curve.add_point(Vector2(1.0, 1.0))
	ribbon.width_curve = width_curve
	var typed: Array[TentacleFeature] = [ribbon]

	var tm = _TentacleMesh.new()
	tm.length = 0.4
	tm.base_radius = 0.04
	tm.tip_radius = 0.04
	tm.tip_cap_rings = 0
	tm.features = typed
	var verts_a: PackedVector3Array = (tm.bake()["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var max_a: float = 0.0
	for v in verts_a:
		var r: float = sqrt(v.x * v.x + v.y * v.y)
		if r > max_a: max_a = r

	# Collapse the width_curve in place: the fin should disappear, max
	# radius drops back to the body radius (0.04).
	width_curve.set_point_value(0, 0.0)
	width_curve.set_point_value(1, 0.0)
	var verts_b: PackedVector3Array = (tm.bake()["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var max_b: float = 0.0
	for v in verts_b:
		var r: float = sqrt(v.x * v.x + v.y * v.y)
		if r > max_b: max_b = r

	if max_a <= 0.04 + 1e-3:
		push_error("baseline ribbon did not extend past body radius (%.4f)" % max_a)
		return false
	if max_b > 0.04 + 1e-3:
		push_error("nested curve edit did not collapse fin: max_b=%.4f (expected ≈%.4f)"
				% [max_b, 0.04])
		return false
	return true


# Same seed → same wart positions across re-bakes.
func test_deterministic_wart_cluster() -> bool:
	var w1 = _WartCluster.new()
	w1.density = 200.0
	w1.max_count = 64
	w1.seed = 99
	var bake1: Dictionary = _bake_with_features([w1])
	var verts1: PackedVector3Array = (bake1["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]

	var w2 = _WartCluster.new()
	w2.density = 200.0
	w2.max_count = 64
	w2.seed = 99
	var bake2: Dictionary = _bake_with_features([w2])
	var verts2: PackedVector3Array = (bake2["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]

	if verts1.size() != verts2.size():
		push_error("non-deterministic vertex count across same-seed bakes: %d vs %d"
				% [verts1.size(), verts2.size()])
		return false
	for i in verts1.size():
		if not verts1[i].is_equal_approx(verts2[i]):
			push_error("non-deterministic vertex %d: %s vs %s"
					% [i, verts1[i], verts2[i]])
			return false
	return true
