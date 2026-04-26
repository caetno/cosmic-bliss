extends SceneTree

# GirthBaker Phase-3b unit tests.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_girth_baker.gd

const _GirthBaker := preload("res://addons/tentacletech/scripts/procedural/girth_baker.gd")


func _init() -> void:
	var passed: int = 0
	var failed: int = 0

	for test_name in [
		"test_uniform_cylinder",
		"test_tapered_shape",
	]:
		if call(test_name):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			push_error("[FAIL] %s" % test_name)
			failed += 1

	print("\n%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


# Cylinder: radius 0.1, length 1.0, 16 rings × 12 segments along Z (axis 2).
# rest_length ≈ 1.0; girth values normalized to peak (= 0.1) → all ≈ 1.0.
func test_uniform_cylinder() -> bool:
	var positions := _make_cylinder(0.1, 1.0, 16, 12)
	var result: Dictionary = _GirthBaker.bake_from_mesh_data(positions, 2)

	var rest_length: float = result["rest_length"]
	if absf(rest_length - 1.0) > 0.01:
		push_error("rest_length %f differs from expected 1.0 by > 1%%" % rest_length)
		return false
	var peak: float = result["peak_radius"]
	if absf(peak - 0.1) > 0.002:
		push_error("peak_radius %f differs from expected 0.1 by > 2%%" % peak)
		return false

	# Texture values are normalized to peak — uniform cylinder → all ≈ 1.0
	# (the absolute girth at every Z is 0.1 == peak).
	var tex: ImageTexture = result["girth_texture"]
	var img: Image = tex.get_image()
	var bytes: PackedByteArray = img.get_data()
	var floats := bytes.to_float32_array()
	if floats.size() != 256:
		push_error("expected 256 girth bins, got %d" % floats.size())
		return false
	for i in floats.size():
		if absf(floats[i] - 1.0) > 0.02:
			push_error("girth bin %d = %f, expected ≈ 1.0" % [i, floats[i]])
			return false
	return true


# Taper: radius 0.1 at z=0 → 0.05 at z=-1.0. After normalization to peak
# (=0.1) the girth values should monotonically decrease (with some
# tolerance for resampling noise).
func test_tapered_shape() -> bool:
	var positions := _make_taper(0.1, 0.05, 1.0, 16, 12)
	var result: Dictionary = _GirthBaker.bake_from_mesh_data(positions, 2)

	var tex: ImageTexture = result["girth_texture"]
	var img: Image = tex.get_image()
	var bytes: PackedByteArray = img.get_data()
	var floats := bytes.to_float32_array()
	if floats.size() != 256:
		push_error("expected 256 girth bins, got %d" % floats.size())
		return false

	# We placed the cylinder at z ∈ [-1, 0] with radius 0.1 at z=0 (large) →
	# 0.05 at z=-1 (small). The baker normalizes values to [0,1]; bin index
	# corresponds to arc-axis position from min to max (z=-1 → bin 0,
	# z=0 → bin 255). So the texture should start near 0.5 (= 0.05 / 0.1)
	# and rise to 1.0.
	# Allow up to 5% noise on monotonicity (resampling can introduce small
	# wobble at ring boundaries).
	var prev: float = floats[0]
	var dips: int = 0
	for i in range(1, floats.size()):
		if floats[i] < prev - 0.05:
			dips += 1
		prev = floats[i]
	if dips > 3:
		push_error("expected near-monotonic girth, got %d dips" % dips)
		return false
	if floats[floats.size() - 1] < floats[0]:
		push_error("expected last bin >= first bin (taper top wider)")
		return false
	return true


# --- helpers --------------------------------------------------------------

static func _make_cylinder(p_radius: float, p_length: float,
		p_rings: int, p_segs: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	for ri in p_rings:
		var z: float = -p_length * (float(ri) / float(p_rings - 1))
		for si in p_segs:
			var theta: float = TAU * float(si) / float(p_segs)
			out.push_back(Vector3(p_radius * cos(theta), p_radius * sin(theta), z))
	return out


static func _make_taper(p_base_r: float, p_tip_r: float, p_length: float,
		p_rings: int, p_segs: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	for ri in p_rings:
		var t: float = float(ri) / float(p_rings - 1)
		var z: float = -p_length * t
		var r: float = lerpf(p_base_r, p_tip_r, t)
		for si in p_segs:
			var theta: float = TAU * float(si) / float(p_segs)
			out.push_back(Vector3(r * cos(theta), r * sin(theta), z))
	return out
