extends SceneTree

# TentacleMood resource + TentacleBehavior.mood pipeline tests.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_tentacle_mood.gd
#
# Covers slice 2 of the param-cleanup work: the resource exists and is
# instantiable, assigning a mood copies its values onto the driver's
# @exports, modifying the resource re-applies via the `changed` signal,
# clearing the mood leaves last-applied values intact, and the four
# bundled preset .tres files load without error.

const _Behavior := preload("res://addons/tentacletech/scripts/behavior/behavior_driver.gd")
const _Mood := preload("res://addons/tentacletech/scripts/behavior/tentacle_mood.gd")

const PRESET_PATHS := [
	"res://addons/tentacletech/scripts/presets/moods/idle.tres",
	"res://addons/tentacletech/scripts/presets/moods/curious.tres",
	"res://addons/tentacletech/scripts/presets/moods/probing.tres",
	"res://addons/tentacletech/scripts/presets/moods/caressing.tres",
]


func _init() -> void:
	if not ClassDB.class_exists("Tentacle"):
		push_error("[FAIL] tentacletech extension not loaded")
		quit(2)
		return

	var passed: int = 0
	var failed: int = 0
	for test_name in [
		"test_mood_resource_instantiates",
		"test_assigning_mood_copies_values",
		"test_clearing_mood_keeps_last_values",
		"test_mood_changed_signal_reapplies",
		"test_swap_mood_overwrites_previous",
		"test_preset_files_load",
	]:
		if call(test_name):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			push_error("[FAIL] %s" % test_name)
			failed += 1

	print("\n%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _make_driver() -> Node:
	# Bare driver; no Tentacle parent needed because none of these tests
	# actually tick the driver — they exercise the mood-apply path only.
	var d := _Behavior.new()
	return d


func test_mood_resource_instantiates() -> bool:
	var m: Resource = _Mood.new()
	if m == null:
		push_error("Mood.new() returned null")
		return false
	if not m is Resource:
		push_error("Mood is not a Resource")
		return false
	return true


func test_assigning_mood_copies_values() -> bool:
	var d: Node = _make_driver()
	var m: Resource = _Mood.new()
	# Distinct values for every export so any single mis-wire is caught.
	m.wave_amplitude_scale = 0.42
	m.wave_temporal_freq = 3.7
	m.wave_drift_speed = -1.1
	m.wave_noise_freq = 2.3
	m.wave_spatial_phase = 1.4
	m.thrust_frequency = 2.5
	m.thrust_amplitude = 0.18
	m.thrust_bias = -0.4
	m.thrust_strike_sharpness = 2.2
	m.coil_amplitude = 0.07
	m.rest_extent = 1.05
	m.pose_stiffness = 0.33
	m.attractor_bias = 0.55
	m.amplitude_smoothing_rate = 12.0
	m.thrust_phase_edge_smoothing = 0.25
	m.time_scale = 0.5

	d.mood = m

	if not _approx(d.wave_amplitude_scale, 0.42): return false
	if not _approx(d.wave_temporal_freq, 3.7): return false
	if not _approx(d.wave_drift_speed, -1.1): return false
	if not _approx(d.wave_noise_freq, 2.3): return false
	if not _approx(d.wave_spatial_phase, 1.4): return false
	if not _approx(d.thrust_frequency, 2.5): return false
	if not _approx(d.thrust_amplitude, 0.18): return false
	if not _approx(d.thrust_bias, -0.4): return false
	if not _approx(d.thrust_strike_sharpness, 2.2): return false
	if not _approx(d.coil_amplitude, 0.07): return false
	if not _approx(d.rest_extent, 1.05): return false
	if not _approx(d.pose_stiffness, 0.33): return false
	if not _approx(d.attractor_bias, 0.55): return false
	if not _approx(d.amplitude_smoothing_rate, 12.0): return false
	if not _approx(d.thrust_phase_edge_smoothing, 0.25): return false
	if not _approx(d.time_scale, 0.5): return false
	return true


func test_clearing_mood_keeps_last_values() -> bool:
	var d: Node = _make_driver()
	var m: Resource = _Mood.new()
	m.wave_amplitude_scale = 0.99
	m.rest_extent = 1.10
	d.mood = m
	# Sanity — values applied.
	if not _approx(d.wave_amplitude_scale, 0.99): return false
	# Clear the mood; the driver should keep what was applied.
	d.mood = null
	if not _approx(d.wave_amplitude_scale, 0.99):
		push_error("clearing mood changed wave_amplitude_scale")
		return false
	if not _approx(d.rest_extent, 1.10):
		push_error("clearing mood changed rest_extent")
		return false
	return true


func test_mood_changed_signal_reapplies() -> bool:
	var d: Node = _make_driver()
	var m: Resource = _Mood.new()
	m.wave_amplitude_scale = 0.20
	d.mood = m
	if not _approx(d.wave_amplitude_scale, 0.20): return false
	# Mutate the resource and emit `changed` — driver should re-pull.
	m.wave_amplitude_scale = 0.85
	m.emit_changed()
	if not _approx(d.wave_amplitude_scale, 0.85):
		push_error("driver didn't reapply on resource changed signal")
		return false
	return true


func test_swap_mood_overwrites_previous() -> bool:
	var d: Node = _make_driver()
	var a: Resource = _Mood.new()
	a.wave_amplitude_scale = 0.3
	a.thrust_frequency = 0.0
	var b: Resource = _Mood.new()
	b.wave_amplitude_scale = 0.9
	b.thrust_frequency = 2.0

	d.mood = a
	if not _approx(d.wave_amplitude_scale, 0.3): return false
	d.mood = b
	if not _approx(d.wave_amplitude_scale, 0.9):
		push_error("swap to second mood didn't overwrite wave amp")
		return false
	if not _approx(d.thrust_frequency, 2.0):
		push_error("swap to second mood didn't overwrite thrust freq")
		return false
	# And the first mood's `changed` signal should no longer reach the driver.
	# Inline comparison (not _approx) so we don't emit a spurious "expected"
	# error when the values intentionally differ.
	a.wave_amplitude_scale = 99.0
	a.emit_changed()
	if absf(d.wave_amplitude_scale - 99.0) < 1e-5:
		push_error("driver still listening to old mood after swap")
		return false
	return true


func test_preset_files_load() -> bool:
	for path in PRESET_PATHS:
		var r: Resource = load(path)
		if r == null:
			push_error("failed to load preset: %s" % path)
			return false
		if not (r is _Mood):
			push_error("preset is not a TentacleMood: %s" % path)
			return false
	return true


func _approx(a: float, b: float, tol: float = 1e-5) -> bool:
	if absf(a - b) > tol:
		push_error("expected %f, got %f" % [b, a])
		return false
	return true
