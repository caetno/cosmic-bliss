extends SceneTree

# Spline Phase 1 unit tests.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_spline.gd
#
# Acceptance: arc-length math within 0.1 % of analytical reference on curves
# that the Catmull-Rom basis can represent exactly (collinear control polygons),
# plus loose tolerances for LUT round-trip and binormal smoothness, and a
# byte-for-byte SplineDataPacker round-trip.
#
# Note on class lookup: when invoked via --script, the GDScript parser resolves
# identifiers before GDExtension classes are registered. We instantiate via
# ClassDB and call static methods through instances (works because
# bind_static_method registers them on the class).

const TIGHT: float = 0.001    # 0.1 % — analytical-reference acceptance
const LOOSE: float = 0.02     # 2 %   — LUT-discretisation tolerance


func _init() -> void:
	if not ClassDB.class_exists("CatmullSpline") or not ClassDB.class_exists("SplineDataPacker"):
		push_error("[FAIL] tentacletech extension not loaded")
		quit(2)
		return

	var passed: int = 0
	var failed: int = 0

	for test_name in [
		"test_straight_line_arc_length",
		"test_helix_arc_length",
		"test_distance_lut_round_trip",
		"test_parallel_transport_planar_curve",
		"test_evaluate_frame_orthonormal",
		"test_packer_round_trip",
		"test_packer_size_matches",
	]:
		if call(test_name):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			push_error("[FAIL] %s" % test_name)
			failed += 1

	print("\n%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


# ---------------------------------------------------------------------------

func _new_spline() -> Object:
	return ClassDB.instantiate("CatmullSpline")


func _packer() -> Object:
	# A throwaway instance is enough to dispatch the bound static methods.
	return ClassDB.instantiate("SplineDataPacker")


func _approx(a: float, b: float, rel: float) -> bool:
	var denom: float = max(absf(b), 1.0)
	return absf(a - b) / denom <= rel


# Straight line: 4 collinear points spaced 1 apart. Catmull-Rom reproduces a
# line exactly; arc length must match 3.0 to ~float precision.
func test_straight_line_arc_length() -> bool:
	var s: Object = _new_spline()
	s.build_from_points(PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(2, 0, 0), Vector3(3, 0, 0)
	]))
	var arc: float = s.get_arc_length()
	if not _approx(arc, 3.0, TIGHT):
		push_error("arc_length=%f, expected ~3.0" % arc)
		return false
	var pos: Vector3 = s.evaluate_position(0.5)
	if absf(pos.y) > 1e-4 or absf(pos.z) > 1e-4:
		push_error("midpoint off-axis: %s" % pos)
		return false
	if not _approx(pos.x, 1.5, TIGHT):
		push_error("midpoint x=%f, expected 1.5" % pos.x)
		return false
	return true


# Helix sampled at 33 control points over one turn. Analytical arc length is
# 2π√2; centripetal Catmull-Rom over a dense regular sampling stays inside
# 0.5 %.
func test_helix_arc_length() -> bool:
	var n: int = 33
	var pts := PackedVector3Array()
	pts.resize(n)
	for i in n:
		var t: float = float(i) / float(n - 1)
		var theta: float = TAU * t
		pts[i] = Vector3(cos(theta), TAU * t, sin(theta))
	var s: Object = _new_spline()
	s.build_from_points(pts)
	s.build_distance_lut(256)
	var arc: float = s.get_arc_length()
	var expected: float = TAU * sqrt(2.0)
	if not _approx(arc, expected, 0.005):
		push_error("helix arc=%f, expected %f" % [arc, expected])
		return false
	return true


# distance_to_parameter ∘ parameter_to_distance ≈ identity within LUT tol.
func test_distance_lut_round_trip() -> bool:
	var s: Object = _new_spline()
	s.build_from_points(PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0.5, 0), Vector3(2, -0.3, 0.7),
		Vector3(3, 0.2, 0.4), Vector3(4, 0, 1)
	]))
	s.build_distance_lut(128)
	for i in 9:
		var t: float = float(i) / 8.0
		var d: float = s.parameter_to_distance(t)
		var t2: float = s.distance_to_parameter(d)
		if absf(t2 - t) > LOOSE:
			push_error("round-trip t=%f -> d=%f -> t=%f (delta %f)" % [t, d, t2, t2 - t])
			return false
	return true


# Planar S-curve in XZ plane: the rotation-minimizing transported binormal
# must stay in the XZ plane (y≈0) and the normal must stay along ±Y. A Frenet
# frame would flip the normal at inflection points; parallel transport does
# not — so we additionally require the normal sign not to flip.
func test_parallel_transport_planar_curve() -> bool:
	var pts := PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 1), Vector3(2, 0, -1),
		Vector3(3, 0, 1), Vector3(4, 0, 0)
	])
	var s: Object = _new_spline()
	s.build_from_points(pts)
	s.build_binormal_lut(64)
	var prev_normal_y_sign: float = 0.0
	for i in 32:
		var t: float = float(i) / 31.0
		var f: Dictionary = s.evaluate_frame(t)
		var b: Vector3 = f["binormal"]
		var n: Vector3 = f["normal"]
		if absf(b.y) > 0.05:
			push_error("binormal at t=%f drifts off-plane: %s" % [t, b])
			return false
		if absf(n.y) < 0.95:
			push_error("normal at t=%f not aligned with Y: %s" % [t, n])
			return false
		var y_sign: float = signf(n.y)
		if prev_normal_y_sign != 0.0 and y_sign != prev_normal_y_sign:
			push_error("normal flipped sign at t=%f (parallel transport should not flip)" % t)
			return false
		prev_normal_y_sign = y_sign
	return true


# evaluate_frame must return three orthonormal vectors.
func test_evaluate_frame_orthonormal() -> bool:
	var s: Object = _new_spline()
	s.build_from_points(PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0.4, 0.2), Vector3(2, -0.1, 0.5),
		Vector3(3, 0.3, -0.2), Vector3(4, 0, 0)
	]))
	for i in 17:
		var t: float = float(i) / 16.0
		var f: Dictionary = s.evaluate_frame(t)
		var tg: Vector3 = f["tangent"]
		var n: Vector3 = f["normal"]
		var b: Vector3 = f["binormal"]
		if absf(tg.length() - 1.0) > 1e-3 or absf(n.length() - 1.0) > 1e-3 or absf(b.length() - 1.0) > 1e-3:
			push_error("frame not unit at t=%f: |t|=%f |n|=%f |b|=%f" % [t, tg.length(), n.length(), b.length()])
			return false
		if absf(tg.dot(n)) > 1e-3 or absf(tg.dot(b)) > 1e-3 or absf(n.dot(b)) > 1e-3:
			push_error("frame not orthogonal at t=%f" % t)
			return false
	return true


# SplineDataPacker round-trip: pack and read all sections back from the float
# array per the documented layout.
func test_packer_round_trip() -> bool:
	var pts := PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0.5, 0.2), Vector3(2, -0.3, 0.7),
		Vector3(3, 0.2, 0.4), Vector3(4, 0, 1)
	])
	var s: Object = _new_spline()
	s.build_from_points(pts)

	var girth := PackedFloat32Array([1.0, 1.1, 1.2, 1.0, 0.8])
	var asym_x := PackedFloat32Array([0.0, 0.05, 0.1, 0.05, 0.0])
	var asym_y := PackedFloat32Array([0.0, -0.02, 0.0, 0.02, 0.0])

	var packer: Object = _packer()
	var packed: PackedFloat32Array = packer.pack(s, [girth, asym_x, asym_y])

	# Header.
	if packed[0] != 1.0:
		push_error("version = %f" % packed[0]); return false
	var pcount: int = int(packed[1])
	var seg: int = int(packed[2])
	var chans: int = int(packed[3])
	var dlut: int = int(packed[4])
	var blut: int = int(packed[5])
	if pcount != s.get_point_count() or seg != s.get_segment_count() or chans != 3 \
			or dlut != s.get_distance_lut_sample_count() or blut != s.get_binormal_lut_sample_count():
		push_error("header mismatch: pcount=%d seg=%d chans=%d dlut=%d blut=%d" % [pcount, seg, chans, dlut, blut])
		return false
	if absf(packed[6] - s.get_arc_length()) > 1e-5:
		push_error("arc_length mismatch: %f vs %f" % [packed[6], s.get_arc_length()])
		return false

	var off: int = 8
	var weights: PackedFloat32Array = s.get_segment_weights()
	for i in weights.size():
		if absf(packed[off + i] - weights[i]) > 1e-5:
			push_error("weight[%d] mismatch" % i); return false
	off += weights.size()

	var dist: PackedFloat32Array = s.get_distance_lut()
	for i in dlut:
		if absf(packed[off + i] - dist[i]) > 1e-5:
			push_error("dist[%d] mismatch" % i); return false
	off += dlut

	var bn: PackedVector3Array = s.get_binormal_lut()
	for i in blut:
		if absf(packed[off + i * 3] - bn[i].x) > 1e-5 \
				or absf(packed[off + i * 3 + 1] - bn[i].y) > 1e-5 \
				or absf(packed[off + i * 3 + 2] - bn[i].z) > 1e-5:
			push_error("binormal[%d] mismatch" % i); return false
	off += blut * 3

	var channels := [girth, asym_x, asym_y]
	for c in 3:
		var arr: PackedFloat32Array = channels[c]
		for i in pcount:
			var expected: float = arr[i] if i < arr.size() else 0.0
			if absf(packed[off + i] - expected) > 1e-5:
				push_error("channel[%d][%d] mismatch" % [c, i]); return false
		off += pcount

	if off != packed.size():
		push_error("trailing data: off=%d size=%d" % [off, packed.size()])
		return false
	return true


# compute_packed_size matches the actual pack() output length.
func test_packer_size_matches() -> bool:
	var s: Object = _new_spline()
	s.build_from_points(PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(2, 0.5, 0), Vector3(3, 0, 0)
	]))
	var ch := PackedFloat32Array([1.0, 1.1, 1.0, 0.9])
	var packer: Object = _packer()
	var packed: PackedFloat32Array = packer.pack(s, [ch])
	var expected: int = packer.compute_packed_size(
			s.get_segment_count(),
			s.get_distance_lut_sample_count(),
			s.get_binormal_lut_sample_count(),
			1,
			s.get_point_count())
	if packed.size() != expected:
		push_error("packed size %d != computed %d" % [packed.size(), expected])
		return false
	return true
