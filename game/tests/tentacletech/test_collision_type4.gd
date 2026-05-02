extends SceneTree

# Phase-4 slice 4A — type-4 environment collision tests.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_collision_type4.gd
#
# Acceptance per docs/architecture/TentacleTech_Architecture.md §4.2 and the
# Phase-4 slice plan in docs/Cosmic_Bliss_Update_2026-05-01_phase4_collision.md.
#
# These tests build a tiny scene tree (Tentacle + StaticBody3D floor / sphere)
# in code, step physics for N frames, and assert the chain has settled above
# the surface. Headless physics works in --headless; the renderer is stubbed.

const DT := 1.0 / 60.0
const SETTLE_FRAMES := 240


var _ran: bool = false

# `_init()` and `_initialize()` run before SceneTree::initialize() finishes
# wiring up `root`, so nodes added there report `is_inside_tree() == false`.
# Defer the test body to the first `_process` tick where the tree is live.
func _process(_delta: float) -> bool:
	if _ran:
		return true # signal quit
	_ran = true
	_run_tests()
	return true

func _run_tests() -> void:
	if not ClassDB.class_exists("Tentacle"):
		push_error("[FAIL] tentacletech extension not loaded (Tentacle missing)")
		quit(2)
		return

	var passed: int = 0
	var failed: int = 0

	for test_name in [
		"test_probe_emits_three_contacts",
		"test_chain_settles_above_floor",
		"test_no_floor_no_collision",
		"test_disable_probe_clears_contacts",
		"test_friction_applied_recorded_in_snapshot",
		"test_lubricity_one_zeros_friction",
		"test_friction_resists_lateral_drift",
		"test_in_contact_flag_set_under_floor",
		"test_in_contact_flag_clears_when_lifted",
		"test_contact_stiffness_allows_segment_stretch",
	]:
		_reset_root()
		if call(test_name):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			push_error("[FAIL] %s" % test_name)
			failed += 1

	print("\n%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


# ---------------------------------------------------------------------------

func _reset_root() -> void:
	# Each test rebuilds from a clean root so colliders don't leak between cases.
	# `free()` (not `queue_free()`) — we never reach an idle frame inside
	# _init(), so deferred deletes would let the bodies persist across tests.
	for c in root.get_children():
		root.remove_child(c)
		c.free()


func _make_tentacle(p_pos: Vector3, p_n: int = 12, p_seg: float = 0.1) -> Node3D:
	var t: Node3D = ClassDB.instantiate("Tentacle")
	t.particle_count = p_n
	t.segment_length = p_seg
	t.position = p_pos
	t.gravity = Vector3(0, -9.8, 0)
	t.environment_probe_distance = 5.0
	t.particle_collision_radius = 0.04
	root.add_child(t)
	return t


func _make_floor(p_y: float = 0.0, p_size: Vector3 = Vector3(20, 0.1, 20)) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = Vector3(0, p_y, 0)
	root.add_child(body)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = p_size
	shape.shape = box
	body.add_child(shape)
	return body


func _make_sphere(p_pos: Vector3, p_radius: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = p_pos
	root.add_child(body)
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = p_radius
	shape.shape = sphere
	body.add_child(shape)
	return body


func _step(p_tentacles: Array, p_frames: int) -> void:
	# Tentacle.tick(dt) runs the same pipeline _physics_process does at
	# runtime: anchor refresh, environment probe (raycasts the physics
	# space the StaticBody3D is registered in), solver tick, render update.
	for _i in p_frames:
		for t in p_tentacles:
			t.tick(DT)


# Three rays go out per tick regardless of whether they hit; the snapshot
# always returns 3 entries. Verify count + that at least one hits the floor
# directly below the tentacle.
func test_probe_emits_three_contacts() -> bool:
	var t: Node3D = _make_tentacle(Vector3(0, 0.6, 0), 8, 0.05)
	_make_floor(0.0)
	_step([t], 2)
	var snap: Array = t.get_environment_contacts_snapshot()
	if snap.size() != 3:
		push_error("expected 3 ray entries, got %d" % snap.size())
		return false
	var any_hit: bool = false
	for entry in snap:
		if entry.get("hit", false):
			any_hit = true
			break
	if not any_hit:
		push_error("no rays hit the floor")
		return false
	return true


# After SETTLE_FRAMES of physics, every particle in a 12-particle chain
# dropped above a y=0 floor sits at y >= -ε (ε accounts for the radius
# projection convention: particles can overlap the surface plane by up to
# `radius` because we test centerline y, not y-radius).
func test_chain_settles_above_floor() -> bool:
	var t: Node3D = _make_tentacle(Vector3(0, 0.6, 0), 12, 0.05)
	t.bending_stiffness = 0.5
	_make_floor(0.0)
	_step([t], SETTLE_FRAMES)

	var positions: PackedVector3Array = t.get_particle_positions()
	# Tolerance: particle_collision_radius * girth_scale (~1) + small slack.
	var min_y: float = -t.particle_collision_radius - 0.005
	var min_observed: float = INF
	for p in positions:
		if p.y < min_observed:
			min_observed = p.y
		if p.y < min_y:
			push_error("particle below floor: y=%f, tolerance=%f" % [p.y, min_y])
			return false
	# Sanity: at least one particle should be near the floor (otherwise the
	# tentacle was never in contact and we'd be testing a no-op).
	if min_observed > 0.1:
		push_error("no particles came close to floor (min y=%f)" % min_observed)
		return false
	return true


# Without a collider in the scene, every ray reports hit=false and the
# tentacle hangs unobstructed below its anchor.
func test_no_floor_no_collision() -> bool:
	var t: Node3D = _make_tentacle(Vector3(0, 1.0, 0), 8, 0.05)
	_step([t], 60)
	var snap: Array = t.get_environment_contacts_snapshot()
	for entry in snap:
		if entry.get("hit", false):
			push_error("unexpected hit with no colliders in scene")
			return false
	# Tip should be pulled below the anchor by gravity.
	var positions: PackedVector3Array = t.get_particle_positions()
	if positions[positions.size() - 1].y >= 1.0:
		push_error("tip not falling under gravity (y=%f)" % positions[positions.size() - 1].y)
		return false
	return true


# Phase-4 slice 4B — §4.3 friction. After settle on the floor, at least one
# hit contact should report nonzero `friction_applied`: the chain has been
# resisting tangential motion against the floor under gravity and bending.
func test_friction_applied_recorded_in_snapshot() -> bool:
	var t: Node3D = _make_tentacle(Vector3(0, 0.6, 0), 12, 0.05)
	t.bending_stiffness = 0.5
	# Tilt gravity so there's tangential motion to resist.
	t.gravity = Vector3(1.5, -9.8, 0)
	_make_floor(0.0)
	_step([t], SETTLE_FRAMES)
	var snap: Array = t.get_environment_contacts_snapshot()
	var max_fric: float = 0.0
	for entry in snap:
		if not entry.get("hit", false):
			continue
		var fa: Vector3 = entry.get("friction_applied", Vector3.ZERO)
		if fa.length() > max_fric:
			max_fric = fa.length()
	if max_fric < 1e-5:
		push_error("expected nonzero friction_applied somewhere in snapshot, got %f" % max_fric)
		return false
	return true


# Slice 4B — lubricity=1.0 zeroes the friction coefficient handed to the solver,
# so no tangential cancellation happens regardless of contact. The friction-
# applied buffer stays at zero.
func test_lubricity_one_zeros_friction() -> bool:
	var t: Node3D = _make_tentacle(Vector3(0, 0.6, 0), 12, 0.05)
	t.bending_stiffness = 0.5
	t.gravity = Vector3(1.5, -9.8, 0)
	t.tentacle_lubricity = 1.0
	_make_floor(0.0)
	_step([t], SETTLE_FRAMES)
	var snap: Array = t.get_environment_contacts_snapshot()
	for entry in snap:
		if not entry.get("hit", false):
			continue
		var fa: Vector3 = entry.get("friction_applied", Vector3.ZERO)
		if fa.length() > 1e-5:
			push_error("lubricity=1.0 still applied friction: %f" % fa.length())
			return false
	return true


# Slice 4B — behavior check. Two tentacles dropped on the same floor under the
# same tilted gravity, identical except for `tentacle_lubricity`. The slick one
# (lubricity=1.0) should drift further along +X than the high-friction one
# because nothing resists tangential motion at the floor contacts.
func test_friction_resists_lateral_drift() -> bool:
	var t_friction: Node3D = _make_tentacle(Vector3(0.0, 0.6, 0), 12, 0.05)
	t_friction.bending_stiffness = 0.5
	t_friction.gravity = Vector3(2.0, -9.8, 0)
	t_friction.tentacle_lubricity = 0.0  # default

	var t_slick: Node3D = _make_tentacle(Vector3(2.0, 0.6, 0), 12, 0.05)
	t_slick.bending_stiffness = 0.5
	t_slick.gravity = Vector3(2.0, -9.8, 0)
	t_slick.tentacle_lubricity = 1.0

	_make_floor(0.0)
	_step([t_friction, t_slick], SETTLE_FRAMES)

	var n: int = t_friction.particle_count
	var tip_dx_friction: float = t_friction.get_particle_positions()[n - 1].x - 0.0
	var tip_dx_slick: float = t_slick.get_particle_positions()[n - 1].x - 2.0

	# Slick tip should drift visibly further than the friction tip.
	if tip_dx_slick - tip_dx_friction < 0.01:
		push_error("expected slick tip to drift further; slick_dx=%f friction_dx=%f" % [tip_dx_slick, tip_dx_friction])
		return false
	return true


# Slice 4C — at least one particle in the lower portion of a settled chain
# reports `in_contact_this_tick = 1` after the chain has draped onto the
# floor. The flag is what `contact_stiffness` selection keys off in the
# distance constraint loop.
func test_in_contact_flag_set_under_floor() -> bool:
	var t: Node3D = _make_tentacle(Vector3(0, 0.6, 0), 12, 0.05)
	t.bending_stiffness = 0.5
	_make_floor(0.0)
	_step([t], SETTLE_FRAMES)
	var solver = t.get_solver()
	var flags: PackedByteArray = solver.get_particle_in_contact_snapshot()
	if flags.size() != t.particle_count:
		push_error("flag array size %d != particle_count %d" % [flags.size(), t.particle_count])
		return false
	var any_in_contact: bool = false
	for b in flags:
		if b != 0:
			any_in_contact = true
			break
	if not any_in_contact:
		push_error("no particle reports in_contact_this_tick=1 after settle")
		return false
	return true


# Slice 4C — the flag is per-tick, cleared in predict() at the start of
# every step. With the chain hanging in air (no collider), no particle
# should report in-contact regardless of motion.
func test_in_contact_flag_clears_when_lifted() -> bool:
	var t: Node3D = _make_tentacle(Vector3(0, 1.0, 0), 8, 0.05)
	# No floor — pure pendulum.
	_step([t], 60)
	var solver = t.get_solver()
	var flags: PackedByteArray = solver.get_particle_in_contact_snapshot()
	for b in flags:
		if b != 0:
			push_error("particle flagged in-contact with no collider in scene")
			return false
	return true


# Slice 4C — direct measurement of what contact_stiffness controls: when a
# segment has at least one endpoint in contact, its distance constraint
# stiffness drops from `distance_stiffness` (1.0) to `contact_stiffness`
# (0.05 here for a clear signal), so the segment is allowed to stretch
# under gravity load instead of fighting collision push-out at rigid
# stiffness. Compare two tentacles, identical except for contact_stiffness;
# soft chain reports a larger max segment-stretch deviation from rest length.
func test_contact_stiffness_allows_segment_stretch() -> bool:
	var t_soft: Node3D = _make_tentacle(Vector3(0.0, 0.6, 0.0), 12, 0.05)
	t_soft.bending_stiffness = 0.5
	t_soft.contact_stiffness = 0.05  # very soft

	var t_rigid: Node3D = _make_tentacle(Vector3(2.0, 0.6, 0.0), 12, 0.05)
	t_rigid.bending_stiffness = 0.5
	t_rigid.contact_stiffness = 1.0  # rigid (matches base distance stiffness)

	_make_floor(0.0)
	_step([t_soft, t_rigid], SETTLE_FRAMES)

	var soft_max_stretch: float = 0.0
	for s in t_soft.get_segment_stretch_ratios():
		soft_max_stretch = maxf(soft_max_stretch, absf(s - 1.0))
	var rigid_max_stretch: float = 0.0
	for s in t_rigid.get_segment_stretch_ratios():
		rigid_max_stretch = maxf(rigid_max_stretch, absf(s - 1.0))

	if soft_max_stretch <= rigid_max_stretch + 0.005:
		push_error("expected soft chain segments to stretch more than rigid; soft_max=%f rigid_max=%f" % [soft_max_stretch, rigid_max_stretch])
		return false
	return true


# Setting environment_probe_enabled = false clears the solver's contact list
# AND clears the snapshot, so the gizmo doesn't draw stale rays.
func test_disable_probe_clears_contacts() -> bool:
	var t: Node3D = _make_tentacle(Vector3(0, 0.6, 0), 8, 0.05)
	_make_floor(0.0)
	_step([t], 5)
	var hit_before: int = 0
	for entry in t.get_environment_contacts_snapshot():
		if entry.get("hit", false):
			hit_before += 1
	if hit_before == 0:
		push_error("setup invariant: expected at least one hit before disabling")
		return false

	t.environment_probe_enabled = false
	_step([t], 2)
	var solver = t.get_solver()
	if solver.get_environment_contact_count() != 0:
		push_error("solver still holds %d contacts after disable" % solver.get_environment_contact_count())
		return false
	return true
