extends SceneTree

# TentacleBehavior driver tests.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_tentacle_behavior.gd

const _Behavior := preload("res://addons/tentacletech/scripts/behavior/behavior_driver.gd")


func _init() -> void:
	if not ClassDB.class_exists("Tentacle"):
		push_error("[FAIL] tentacletech extension not loaded")
		quit(2)
		return

	var passed: int = 0
	var failed: int = 0
	for test_name in [
		"test_writes_pose_targets_first_tick",
		"test_target_evolves_over_time",
		"test_amplitude_zero_produces_rest_pose",
		"test_attractor_pulls_tip_more_than_base",
		"test_disabled_does_not_write",
		"test_smooth_noise_bounded",
		"test_thrust_modulates_axial_extent",
	]:
		if call(test_name):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			push_error("[FAIL] %s" % test_name)
			failed += 1

	print("\n%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


# --- Scaffolding -----------------------------------------------------------

# Minimal Tentacle + TentacleBehavior tree under root. Behavior auto-resolves
# parent via `tentacle_path = ".."`. randomize_phase_on_ready disabled for
# determinism.
func _make_setup() -> Dictionary:
	var root := Node3D.new()
	get_root().add_child(root)
	var t: Object = ClassDB.instantiate("Tentacle")
	root.add_child(t as Node)
	t.particle_count = 12
	t.segment_length = 0.08
	t.rebuild_chain()
	# Disable gravity so pose-pull dynamics aren't fighting an external
	# force in the test — pose-target convergence is what we're checking.
	t.set_gravity(Vector3.ZERO)
	var b = _Behavior.new()
	(t as Node).add_child(b)
	b.randomize_phase_on_ready = false
	b.refresh_wiring()
	return {"root": root, "tentacle": t, "behavior": b}


func _teardown(p_setup: Dictionary) -> void:
	(p_setup["root"] as Node).queue_free()


# --- Tests -----------------------------------------------------------------

# One physics tick must populate pose targets — one per non-base particle.
func test_writes_pose_targets_first_tick() -> bool:
	var s := _make_setup()
	var t = s["tentacle"]
	var b = s["behavior"]
	b._physics_process(0.016)
	var got: int = t.get_pose_target_count()
	var expected: int = t.particle_count - 1
	_teardown(s)
	if got != expected:
		push_error("expected %d pose targets, got %d" % [expected, got])
		return false
	return true


# Targets must change between ticks — guards against _wave_phase not
# advancing or the synthesis being constant.
func test_target_evolves_over_time() -> bool:
	var s := _make_setup()
	var t = s["tentacle"]
	var b = s["behavior"]
	b._physics_process(0.016)
	var p1: Vector3 = t.get_solver().get_pose_target_positions()[5]
	for _i in 30:
		b._physics_process(0.016)
	var p2: Vector3 = t.get_solver().get_pose_target_positions()[5]
	_teardown(s)
	if p1.is_equal_approx(p2):
		push_error("pose target position did not change after 30 ticks: %s vs %s" % [p1, p2])
		return false
	return true


# At zero wave amplitude and zero thrust, every pose target must equal the
# rest pose along rest_direction (target_k = rest_dir * s_norm * length *
# rest_extent). Verifies the synthesis simplifies cleanly when knobs are
# zeroed.
func test_amplitude_zero_produces_rest_pose() -> bool:
	var s := _make_setup()
	var t = s["tentacle"]
	var b = s["behavior"]
	b.wave_amplitude_scale = 0.0
	b.thrust_amplitude = 0.0
	b._physics_process(0.016)
	var positions: PackedVector3Array = t.get_solver().get_pose_target_positions()
	var n: int = t.particle_count
	var chain_len: float = float(n) * t.segment_length
	var ok: bool = true
	for k in range(1, n):
		var s_norm: float = float(k) / float(n - 1)
		var expected: Vector3 = b.rest_direction.normalized() * (s_norm * chain_len * b.rest_extent)
		# Tentacle is at world origin so local == world.
		if not positions[k - 1].is_equal_approx(expected):
			ok = false
			break
	_teardown(s)
	if not ok:
		push_error("zero-amplitude pose did not match rest curve")
		return false
	return true


# Attractor with full bias must move the tip more than the base — the
# tip-weighted lerp is the architecture's "stay anchored at root, seek
# with the tip" rule.
func test_attractor_pulls_tip_more_than_base() -> bool:
	var s := _make_setup()
	var t = s["tentacle"]
	var b = s["behavior"]
	# Attractor sits well off the rest pose so the lerp produces a clear
	# difference between low-s and high-s particles.
	var attractor := Node3D.new()
	attractor.name = "Attr"
	(s["root"] as Node).add_child(attractor)
	attractor.global_position = Vector3(2.0, 1.0, 0.0)
	b.wave_amplitude_scale = 0.0
	b.thrust_amplitude = 0.0
	b.attractor_path = b.get_path_to(attractor)
	b.attractor_bias = 1.0
	b.refresh_wiring()
	b._physics_process(0.016)
	var positions: PackedVector3Array = t.get_solver().get_pose_target_positions()
	# First entry corresponds to particle 1 (near base), last to tip.
	var base_distance: float = positions[0].distance_to(attractor.global_position)
	var tip_distance: float = positions[positions.size() - 1].distance_to(attractor.global_position)
	_teardown(s)
	if tip_distance >= base_distance:
		push_error("tip should be closer to attractor than base; tip=%.3f base=%.3f"
				% [tip_distance, base_distance])
		return false
	return true


# Disabling the driver must leave pose targets empty — guards against
# stale targets persisting from a previous mode change.
func test_disabled_does_not_write() -> bool:
	var s := _make_setup()
	var t = s["tentacle"]
	var b = s["behavior"]
	b.enabled = false
	b._physics_process(0.016)
	var count: int = t.get_pose_target_count()
	_teardown(s)
	if count != 0:
		push_error("disabled behavior wrote %d pose targets" % count)
		return false
	return true


# DPG smooth-noise stays bounded in roughly [-1, +1]. Sum-of-three
# normalized by 3.
func test_smooth_noise_bounded() -> bool:
	for i in 200:
		var v: float = _Behavior._smooth_noise(float(i) * 0.137, float(i) * 0.93)
		if absf(v) > 1.05:
			push_error("smooth_noise out of bounds at i=%d: %f" % [i, v])
			return false
	return true


# Thrust frequency + amplitude must produce a visible axial swing in the
# tip pose target's projection on rest_direction. Verifies the thrust knob
# composes with the rest_extent multiplier as documented.
func test_thrust_modulates_axial_extent() -> bool:
	var s := _make_setup()
	var t = s["tentacle"]
	var b = s["behavior"]
	b.wave_amplitude_scale = 0.0
	b.thrust_frequency = 1.0
	b.thrust_amplitude = 0.2
	b.thrust_bias = 0.0
	b.rest_extent = 0.85

	var rest_dir: Vector3 = b.rest_direction.normalized()
	var min_proj := INF
	var max_proj := -INF
	# Sample axial extent across one full thrust cycle (1 Hz @ 60 fps).
	for _i in 60:
		b._physics_process(1.0 / 60.0)
		var positions: PackedVector3Array = t.get_solver().get_pose_target_positions()
		var tip: Vector3 = positions[positions.size() - 1]
		var proj: float = tip.dot(rest_dir)
		if proj < min_proj: min_proj = proj
		if proj > max_proj: max_proj = proj

	_teardown(s)
	# Expected swing ≈ 2 × thrust_amplitude × chain_length ≈ 2 × 0.2 × 0.96 = 0.384m.
	var swing: float = max_proj - min_proj
	if swing < 0.2:
		push_error("thrust swing %.3f m < expected ~0.38" % swing)
		return false
	return true
