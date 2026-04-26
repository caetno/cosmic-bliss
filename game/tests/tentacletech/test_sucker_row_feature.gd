extends SceneTree

# SuckerRowFeature Phase-3b unit tests.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_sucker_row_feature.gd

const _TentacleMesh := preload("res://addons/tentacletech/scripts/procedural/tentacle_mesh.gd")
const _SuckerRowFeature := preload("res://addons/tentacletech/scripts/procedural/sucker_row_feature.gd")

const SuckerSide_ONE := 0
const SuckerSide_TWO := 1
const SuckerSide_ALL := 2
const SuckerSide_SPIRAL := 3

# Each sucker emits disc_segments × 3 ring verts + 1 center = 25 verts when
# disc_segments = 8. Tests below use disc_segments = 8 in _make_mesh_with_suckers.
const VERTS_PER_SUCKER := 25


func _init() -> void:
	var passed: int = 0
	var failed: int = 0

	for test_name in [
		"test_one_side_count",
		"test_two_side_two_bands",
		"test_seam_collision_errors",
		"test_uv1_within_unit_square",
	]:
		if call(test_name):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			push_error("[FAIL] %s" % test_name)
			failed += 1

	print("\n%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _make_mesh_with_suckers(p_count: int, p_side: int, p_seam: float = 0.0) -> Dictionary:
	var tm = _TentacleMesh.new()
	tm.length_segments = 8
	tm.radial_segments = 8
	tm.seam_offset = p_seam
	var feat = _SuckerRowFeature.new()
	feat.count = p_count
	feat.side = p_side
	feat.disc_segments = 8
	tm.features.append(feat)
	return tm.bake()


# OneSide with count=8 should produce 8 sucker patches in a single radial
# band. Each sucker contributes 25 verts (3 rings × 8 segs + 1 center).
# COLOR.r is 1.0 on every sucker vertex; 0 on body verts.
#
# Per-vertex angle isn't a stable test: rim verts wrap a wide angular span
# when the body radius is small (near the tip). Per-sucker centroid is
# stable — we average all 25 verts of each sucker and check the centroid's
# angular position.
func test_one_side_count() -> bool:
	var result: Dictionary = _make_mesh_with_suckers(8, SuckerSide_ONE, 0.0)
	if result["errors"].size() > 0:
		push_error("unexpected bake errors: %s" % str(result["errors"]))
		return false

	var mesh: ArrayMesh = result["mesh"]
	var arrays: Array = mesh.surface_get_arrays(0)
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]

	var sucker_verts: int = 0
	for c in colors:
		if c.r > 0.5:
			sucker_verts += 1
	var expected: int = VERTS_PER_SUCKER * 8
	if sucker_verts != expected:
		push_error("sucker vertex count %d != expected %d" % [sucker_verts, expected])
		return false

	var centroids: Array = _per_sucker_centroids(arrays, 8)
	if centroids.size() != 8:
		push_error("expected 8 sucker centroids, got %d" % centroids.size())
		return false
	# OneSide → all 8 centroids close to angle π.
	for i in centroids.size():
		var v: Vector3 = centroids[i]
		var ang: float = atan2(v.y, v.x)
		if absf(_wrap(ang - PI)) > deg_to_rad(10.0):
			push_error("sucker %d centroid angle %.1f° not near 180°" % [i, rad_to_deg(ang)])
			return false
	return true


# TwoSide produces two opposing bands at ±90° from the seam. Centroid
# angles split into two groups around +π/2 and -π/2.
func test_two_side_two_bands() -> bool:
	var result: Dictionary = _make_mesh_with_suckers(8, SuckerSide_TWO, 0.0)
	if result["errors"].size() > 0:
		push_error("unexpected bake errors: %s" % str(result["errors"]))
		return false
	var mesh: ArrayMesh = result["mesh"]
	var arrays: Array = mesh.surface_get_arrays(0)

	var centroids: Array = _per_sucker_centroids(arrays, 8)
	if centroids.size() != 8:
		push_error("expected 8 sucker centroids, got %d" % centroids.size())
		return false

	var positive_band: int = 0
	var negative_band: int = 0
	for v in centroids:
		var ang: float = atan2(v.y, v.x)
		var dpos: float = absf(_wrap(ang - PI * 0.5))
		var dneg: float = absf(_wrap(ang + PI * 0.5))
		if dpos < deg_to_rad(10.0):
			positive_band += 1
		elif dneg < deg_to_rad(10.0):
			negative_band += 1
	if positive_band != 4 or negative_band != 4:
		push_error("expected 4 centroids per band; got +%d / -%d" % [positive_band, negative_band])
		return false

	# Both bands should be far from the seam (= 0) — every centroid's angle
	# differs from 0 by more than 10°. (PI/2 - PI/2 in either direction.)
	for v in centroids:
		var ang: float = atan2(v.y, v.x)
		if absf(_wrap(ang)) < deg_to_rad(60.0):
			push_error("centroid landed near seam (angle=%.1f°)" % rad_to_deg(ang))
			return false
	return true


# A configuration where a sucker is forced onto the seam should populate
# bake errors. We do this with AllAround + count=1 + seam_offset placed at
# the natural sucker angle (0).
func test_seam_collision_errors() -> bool:
	var tm = _TentacleMesh.new()
	tm.length_segments = 8
	tm.radial_segments = 8
	tm.seam_offset = 0.0
	var feat = _SuckerRowFeature.new()
	feat.count = 1
	feat.side = SuckerSide_ALL  # AllAround sucker 0 sits at angle 0 == seam
	feat.disc_segments = 6
	tm.features.append(feat)
	var result: Dictionary = tm.bake()
	if result["errors"].size() == 0:
		push_error("expected seam-collision error, got none")
		return false
	# Error message should mention "seam".
	var found: bool = false
	for e in result["errors"]:
		if String(e).to_lower().contains("seam"):
			found = true
			break
	if not found:
		push_error("error message doesn't mention 'seam': %s" % str(result["errors"]))
		return false
	return true


# UV1 on cup vertices fits within the unit square ± epsilon.
func test_uv1_within_unit_square() -> bool:
	var result: Dictionary = _make_mesh_with_suckers(8, SuckerSide_ONE, 0.0)
	var mesh: ArrayMesh = result["mesh"]
	var arrays: Array = mesh.surface_get_arrays(0)
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var uv1: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	const EPS := 1e-3
	for i in colors.size():
		if colors[i].r <= 0.5:
			continue
		var u: Vector2 = uv1[i]
		if u.x < -EPS or u.x > 1.0 + EPS or u.y < -EPS or u.y > 1.0 + EPS:
			push_error("sucker vert %d has UV1 %s outside [0,1]²" % [i, u])
			return false
	return true


static func _wrap(p_a: float) -> float:
	return fposmod(p_a + PI, TAU) - PI


# Walk the sucker verts (COLOR.r > 0.5) in groups of VERTS_PER_SUCKER and
# return one centroid Vector3 per sucker. Sucker verts are appended after
# the body geometry; their order matches the feature's emission order.
static func _per_sucker_centroids(p_arrays: Array, p_count: int) -> Array:
	var verts: PackedVector3Array = p_arrays[Mesh.ARRAY_VERTEX]
	var colors: PackedColorArray = p_arrays[Mesh.ARRAY_COLOR]
	var sucker_indices: PackedInt32Array = PackedInt32Array()
	for i in colors.size():
		if colors[i].r > 0.5:
			sucker_indices.push_back(i)
	if sucker_indices.size() != VERTS_PER_SUCKER * p_count:
		return []
	var out: Array = []
	out.resize(p_count)
	for s in p_count:
		var sum := Vector3.ZERO
		for k in VERTS_PER_SUCKER:
			sum += verts[sucker_indices[s * VERTS_PER_SUCKER + k]]
		out[s] = sum / float(VERTS_PER_SUCKER)
	return out
