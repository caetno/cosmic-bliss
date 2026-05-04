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
		"test_tip_rigid_zone_quiets_tip",
		"test_strike_share_zero_pins_tip_axially",
		"test_changing_thrust_frequency_does_not_jump",
		"test_zero_drift_coil_stays_planar",
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
#
# Behavior @exports must be set BEFORE `add_child(b)` triggers `_ready` so
# the `_smoothed_*` amplitude mirrors snap to the test-configured values.
# Setting them after `_ready` leaves the mirrors at class defaults and the
# subsequent smoothing across one tick can't bring them to the test target —
# this is what produced the 2 long-standing test failures (test_amplitude_
# zero and test_strike_share_zero) before 2026-05-04. Pass overrides via the
# `behavior_overrides` dict.
func _make_setup(behavior_overrides: Dictionary = {}) -> Dictionary:
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
	# Pre-`_ready` configuration: randomize_phase_on_ready off (otherwise
	# `_ready` seeds random phases), plus any test-supplied overrides so
	# the smoothing mirrors snap to the right values when `_ready` runs.
	b.randomize_phase_on_ready = false
	for key in behavior_overrides:
		b.set(key, behavior_overrides[key])
	(t as Node).add_child(b)
	# `--script` SceneTree quirk: `add_child` doesn't fire `_ready`
	# synchronously when the parent reports `is_inside_tree() == false`
	# (which happens in `_init`-mode tests even after `get_root().add_child`).
	# When the test passes overrides, call `_ready` manually so the
	# `_smoothed_*` mirrors snap to the @export values instead of
	# class defaults (0.0). Tests that pass no overrides historically
	# rely on the un-snapped behavior — `_smoothed_rest_extent` ramps
	# from 0.0 toward 0.92 across ticks and provides the "evolution"
	# that test_target_evolves_over_time and test_thrust_modulates_
	# axial_extent assert; calling `_ready` there would defeat them.
	if not behavior_overrides.is_empty():
		b._ready()
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
	var s := _make_setup({
		"wave_amplitude_scale": 0.0,
		"thrust_amplitude": 0.0,
		"coil_amplitude": 0.0,
	})
	var t = s["tentacle"]
	var b = s["behavior"]
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


# With `tip_rigid_length=0` (legacy uniform-scale path), thrust frequency
# + amplitude must produce a visible axial swing in the tip pose target's
# projection on rest_direction. Verifies the thrust knob composes with
# the rest_extent multiplier as documented.
func test_thrust_modulates_axial_extent() -> bool:
	var s := _make_setup()
	var t = s["tentacle"]
	var b = s["behavior"]
	b.wave_amplitude_scale = 0.0
	b.thrust_frequency = 1.0
	b.thrust_amplitude = 0.2
	b.thrust_bias = 0.0
	b.rest_extent = 0.85
	# Disable the tip-rigid zone for this assertion — the test is about
	# the thrust→axial-extent composition, not the body/tip split.
	b.tip_rigid_length = 0.0

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


# With a non-zero tip_rigid_length, the *tip* pose target should have far
# less lateral wave swing than a body particle — the rigid zone gates the
# wave amplitude to zero at the very tip.
func test_tip_rigid_zone_quiets_tip() -> bool:
	var s := _make_setup()
	var t = s["tentacle"]
	var b = s["behavior"]
	b.wave_amplitude_scale = 1.0
	b.thrust_amplitude = 0.0
	b.tip_rigid_length = 0.10  # ~10cm of chain length 0.96
	b.tip_strike_share = 1.0

	var rest_dir: Vector3 = b.rest_direction.normalized()
	var tip_lateral_max: float = 0.0
	var body_lateral_max: float = 0.0
	# Sample a few seconds across drift + wave evolution.
	for _i in 240:
		b._physics_process(1.0 / 60.0)
		var positions: PackedVector3Array = t.get_solver().get_pose_target_positions()
		var tip: Vector3 = positions[positions.size() - 1]
		# Mid-body sample: well outside the tip rigid zone.
		var body: Vector3 = positions[positions.size() / 2]
		var tip_lat: float = (tip - rest_dir * tip.dot(rest_dir)).length()
		var body_lat: float = (body - rest_dir * body.dot(rest_dir)).length()
		if tip_lat > tip_lateral_max: tip_lateral_max = tip_lat
		if body_lat > body_lateral_max: body_lateral_max = body_lat
	_teardown(s)
	# Tip lateral swing must be much smaller than body's. A pure rigid
	# zone at the very tip should produce ~zero lateral; allow some slack.
	if tip_lateral_max > 0.5 * body_lateral_max:
		push_error("tip lateral %.4f not muted vs body %.4f"
				% [tip_lateral_max, body_lateral_max])
		return false
	if body_lateral_max < 0.01:
		push_error("body lateral %.4f too small — wave not running"
				% body_lateral_max)
		return false
	return true


# With `tip_strike_share=0` and `tip_rigid_length>0`, the tip's axial
# projection should be near-constant across a thrust cycle even with
# strong amplitude. Body axial projection should still swing. This is
# the "tip balanced in place" extreme.
func test_strike_share_zero_pins_tip_axially() -> bool:
	# tip_strike_share only takes effect in the `has_lateral_release`
	# branch (coil_amplitude > 1e-4) per behavior_driver's body/tip split
	# logic — without a lateral-release path the body/tip factors collapse
	# to one shared `rest_extent + pulse` formula and tip_strike_share is
	# ignored. So we author a small coil to enable the split. Pre-`_ready`
	# overrides keep the smoothing mirrors snapped to these values.
	var s := _make_setup({
		"wave_amplitude_scale": 0.0,
		"thrust_frequency": 1.0,
		"thrust_amplitude": 0.2,
		"thrust_bias": 0.0,
		"rest_extent": 0.85,
		"tip_rigid_length": 0.10,
		"tip_strike_share": 0.0,
		"coil_amplitude": 0.05,
	})
	var t = s["tentacle"]
	var b = s["behavior"]

	var rest_dir: Vector3 = b.rest_direction.normalized()
	var tip_min := INF
	var tip_max := -INF
	var body_min := INF
	var body_max := -INF
	for _i in 60:
		b._physics_process(1.0 / 60.0)
		var positions: PackedVector3Array = t.get_solver().get_pose_target_positions()
		var tip: Vector3 = positions[positions.size() - 1]
		var body: Vector3 = positions[positions.size() / 2]
		var tip_p: float = tip.dot(rest_dir)
		var body_p: float = body.dot(rest_dir)
		if tip_p < tip_min: tip_min = tip_p
		if tip_p > tip_max: tip_max = tip_p
		if body_p < body_min: body_min = body_p
		if body_p > body_max: body_max = body_p
	_teardown(s)
	var tip_swing: float = tip_max - tip_min
	var body_swing: float = body_max - body_min
	# Body should swing meaningfully; tip swing should be far smaller.
	if body_swing < 0.05:
		push_error("body axial swing %.4f too small" % body_swing)
		return false
	if tip_swing > 0.05:
		push_error("tip not pinned: swing %.4f m" % tip_swing)
		return false
	return true


# Changing `thrust_frequency` mid-cycle must not cause a position jump.
# Pre-fix used `sin(_time * TAU * f)` which jumps by `_time * TAU * Δf`
# the moment f changes. Post-fix integrates the phase (`_thrust_phase_t
# += dt * TAU * f`), so f only changes the *rate*, not the value. Same
# fix applies to wave_noise_freq.
func test_changing_thrust_frequency_does_not_jump() -> bool:
	var s := _make_setup()
	var t = s["tentacle"]
	var b = s["behavior"]
	b.wave_amplitude_scale = 0.0
	b.coil_amplitude = 0.0
	b.tip_rigid_length = 0.0
	b.thrust_amplitude = 0.2
	b.thrust_frequency = 1.0
	b.rest_extent = 0.85
	# Run for a few seconds to let `_time` accumulate so a multiplied-
	# formulation jump would be large.
	for _i in 200:
		b._physics_process(1.0 / 60.0)
	var positions_before: PackedVector3Array = t.get_solver().get_pose_target_positions()
	var tip_before: Vector3 = positions_before[positions_before.size() - 1]
	# Bump the frequency mid-flight.
	b.thrust_frequency = 2.5
	# Compute pose targets again immediately, with `dt=0` so the
	# integrated phase advances by zero. If the implementation uses
	# `sin(t * f)` the tip will jump; if it uses `sin(integrated_phase)`
	# it won't.
	b._physics_process(0.0)
	var positions_after: PackedVector3Array = t.get_solver().get_pose_target_positions()
	var tip_after: Vector3 = positions_after[positions_after.size() - 1]
	_teardown(s)
	var jump: float = (tip_after - tip_before).length()
	if jump > 1e-4:
		push_error("thrust freq change caused tip jump %.6f m" % jump)
		return false
	return true


# With `wave_drift_speed=0` (locked perp plane) and `coil_amplitude>0`
# and a load-biased thrust, every body pose target must lie in the
# plane spanned by `rest_dir` and the fixed `perp1` axis — i.e. zero
# component along `perp2`. That's the S-curve thrust pose; non-zero
# drift rotates the same coil into a corkscrew.
func test_zero_drift_coil_stays_planar() -> bool:
	var s := _make_setup()
	var t = s["tentacle"]
	var b = s["behavior"]
	b.wave_amplitude_scale = 0.0
	b.wave_drift_speed = 0.0
	b.coil_amplitude = 0.2
	b.thrust_amplitude = 0.2
	b.thrust_frequency = 1.0
	b.thrust_bias = -1.0  # always loaded → always coiling
	b.tip_rigid_length = 0.08

	# With default rest_direction = (0,0,-1) and drift=0:
	#   helper = UP = (0,1,0)
	#   perp_base = (0,1,0) (UP is already perpendicular to rest_dir)
	#   perp1 = perp_base = (0,1,0)
	#   perp2 = rest_dir.cross(perp1) = (1,0,0)
	# Plane normal (perp2) is +X, so all pose targets must have ~zero
	# X component when tentacle is at world origin.

	var max_x: float = 0.0
	for _i in 90:
		b._physics_process(1.0 / 60.0)
		var positions: PackedVector3Array = t.get_solver().get_pose_target_positions()
		for p in positions:
			var ax: float = absf(p.x)
			if ax > max_x: max_x = ax
	_teardown(s)
	if max_x > 1e-4:
		push_error("coil leaked off-plane: max |x| = %.6f" % max_x)
		return false
	return true
