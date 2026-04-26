extends SceneTree

# TentacleTech Phase-3a render plumbing tests.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_render.gd
#
# Acceptance per docs/architecture/TentacleTech_Architecture.md §5.2 + §13 +
# extensions/tentacletech/CLAUDE.md sub-step A spec.
#
# What this covers:
#   - Tentacle.get_spline_data_texture() returns an ImageTexture in FORMAT_RGBAF
#     after rebuild_chain.
#   - Header layout matches SplineDataPacker's contract (version, point_count,
#     segment_count, channel_count, dist_lut_size, bn_lut_size, arc_length).
#   - Width matches SplineDataPacker.compute_packed_size / 4.
#   - get_rest_girth_texture() returns an ImageTexture in FORMAT_RF.
#   - 1000-tick alloc-free path: static memory drift < 1 KB (Phase-2 budget).

const DT := 1.0 / 60.0


func _init() -> void:
	if not ClassDB.class_exists("Tentacle") or not ClassDB.class_exists("SplineDataPacker"):
		push_error("[FAIL] tentacletech extension not loaded")
		quit(2)
		return

	var passed: int = 0
	var failed: int = 0

	for test_name in [
		"test_spline_data_texture_present_and_format",
		"test_spline_data_header_values",
		"test_rest_girth_texture_present",
		"test_texture_update_alloc_free",
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

func _new_tentacle(particle_count: int = 16, segment_length: float = 0.1) -> Object:
	var t: Object = ClassDB.instantiate("Tentacle")
	t.set_particle_count(particle_count)
	t.set_segment_length(segment_length)
	# rebuild_chain is what allocates the render resources outside _ready.
	t.rebuild_chain()
	return t


func test_spline_data_texture_present_and_format() -> bool:
	var t: Object = _new_tentacle(16, 0.1)
	var tex: ImageTexture = t.get_spline_data_texture()
	if tex == null:
		push_error("get_spline_data_texture() returned null")
		return false
	var img: Image = tex.get_image()
	if img == null:
		push_error("texture.get_image() returned null")
		return false
	if img.get_format() != Image.FORMAT_RGBAF:
		push_error("expected FORMAT_RGBAF, got %d" % img.get_format())
		return false
	if img.get_height() != 1:
		push_error("expected height 1, got %d" % img.get_height())
		return false

	# Width should match ceil(packed_size / 4) for this configuration.
	# For 16 particles: segments=15, dist_lut=32, bn_lut=32, channels=3.
	var expected_packed: int = SplineDataPacker.compute_packed_size(15, 32, 32, 3, 16)
	var expected_width: int = (expected_packed + 3) / 4
	if t.get_spline_data_texture_width() != expected_width:
		push_error("width %d != expected %d (packed %d floats)" %
				[t.get_spline_data_texture_width(), expected_width, expected_packed])
		return false
	if img.get_width() != expected_width:
		push_error("image width %d != expected %d" % [img.get_width(), expected_width])
		return false
	return true


func test_spline_data_header_values() -> bool:
	var t: Object = _new_tentacle(16, 0.1)
	# Read the source Image directly. ImageTexture::get_image() routes through
	# the renderer, which is a stub under --headless and returns dummy bytes;
	# the source Image is the ground truth we set via Image::set_data.
	var img: Image = t.get_spline_data_image()
	if img == null:
		push_error("get_spline_data_image() returned null")
		return false
	var bytes: PackedByteArray = img.get_data()
	# Header is the first 8 floats = 32 bytes.
	var floats := bytes.to_float32_array()
	if floats.size() < 8:
		push_error("packed data has %d floats, header expects 8" % floats.size())
		return false

	var version: float = floats[0]
	var point_count: int = int(floats[1])
	var segment_count: int = int(floats[2])
	var channel_count: int = int(floats[3])
	var dist_lut_size: int = int(floats[4])
	var bn_lut_size: int = int(floats[5])
	var arc_length: float = floats[6]
	var reserved: float = floats[7]

	if not is_equal_approx(version, 1.0):
		push_error("version %f != 1.0" % version)
		return false
	if point_count != 16:
		push_error("point_count %d != 16" % point_count)
		return false
	if segment_count != 15:
		push_error("segment_count %d != 15" % segment_count)
		return false
	if channel_count != 3:
		push_error("channel_count %d != 3 (girth, asym.x, asym.y)" % channel_count)
		return false
	if dist_lut_size != 32:
		push_error("dist_lut_size %d != 32" % dist_lut_size)
		return false
	if bn_lut_size != 32:
		push_error("bn_lut_size %d != 32" % bn_lut_size)
		return false
	# Rest chain spans 0.1 m × 15 segments = 1.5 m. Centripetal Catmull-Rom
	# arc length on a straight chain matches the polyline length closely.
	if arc_length < 1.4 or arc_length > 1.6:
		push_error("arc_length %f outside expected ~1.5" % arc_length)
		return false
	if not is_equal_approx(reserved, 0.0):
		push_error("reserved %f != 0.0" % reserved)
		return false
	return true


func test_rest_girth_texture_present() -> bool:
	var t: Object = _new_tentacle(16, 0.1)
	var tex: ImageTexture = t.get_rest_girth_texture()
	if tex == null:
		push_error("get_rest_girth_texture() returned null")
		return false
	var img: Image = tex.get_image()
	if img == null:
		push_error("rest girth image is null")
		return false
	if img.get_format() != Image.FORMAT_RF:
		push_error("expected FORMAT_RF, got %d" % img.get_format())
		return false
	# Phase 3a placeholder: uniform 1.0 across all bins.
	var bytes: PackedByteArray = img.get_data()
	var floats := bytes.to_float32_array()
	if floats.size() < 1:
		push_error("rest girth has no data")
		return false
	for f in floats:
		if not is_equal_approx(f, 1.0):
			push_error("rest girth contains non-1.0 sample %f" % f)
			return false
	return true


# Memory drift over 1000 update_render_data() calls — the per-tick path that
# runs at 60 Hz from _physics_process. The first call after rebuild_chain()
# may allocate to size internal buffers; subsequent calls must reuse them.
func test_texture_update_alloc_free() -> bool:
	if not OS.has_method("get_static_memory_usage"):
		print("  (skipped — OS.get_static_memory_usage unavailable)")
		return true

	var t: Object = _new_tentacle(16, 0.1)

	# Warm-up: prime any caches and allocator quirks.
	for _i in 60:
		t.update_render_data()

	var before: int = OS.get_static_memory_usage()
	for _i in 1000:
		t.update_render_data()
	var after: int = OS.get_static_memory_usage()
	var delta: int = after - before
	if delta > 1024:
		push_error("static memory grew by %d bytes over 1000 updates (> 1 KB)" % delta)
		return false
	return true
