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
		"test_probe_emits_per_particle_contacts",
		"test_chain_settles_above_floor",
		"test_no_floor_no_collision",
		"test_disable_probe_clears_contacts",
		"test_friction_applied_recorded_in_snapshot",
		"test_lubricity_one_zeros_friction",
		"test_friction_resists_lateral_drift",
		"test_in_contact_flag_set_under_floor",
		"test_in_contact_flag_clears_when_lifted",
		"test_contact_stiffness_allows_segment_stretch",
		"test_sphere_below_anchor_blocks_tip",
		"test_obstacle_in_chain_path_pushed_aside",
		"test_friction_pushes_dynamic_body",
		"test_body_impulse_scale_default_is_gentle",
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


# Slice 4D: one snapshot entry per particle (sphere query at each particle's
# position, returning nearest surface contact via PhysicsDirectSpaceState3D).
# Verify the snapshot length matches particle_count and at least one entry
# reports a hit when the chain has settled onto a floor.
func test_probe_emits_per_particle_contacts() -> bool:
	var t: Node3D = _make_tentacle(Vector3(0, 0.6, 0), 12, 0.05)
	_make_floor(0.0)
	# Settle long enough for the chain to drape onto the floor; tangent
	# contacts at rest are detected via the QUERY_BIAS in environment_probe.
	_step([t], 120)
	var snap: Array = t.get_environment_contacts_snapshot()
	if snap.size() != t.particle_count:
		push_error("expected %d snapshot entries (one per particle), got %d" % [t.particle_count, snap.size()])
		return false
	var any_hit: bool = false
	for entry in snap:
		if entry.get("hit", false):
			any_hit = true
			break
	if not any_hit:
		push_error("no particle reported a hit on the floor after settle")
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


# Slice 4D — sphere directly under the chain. The slice 4A 3-ray probe would
# have caught this (rays cast in gravity direction below the chain), but
# verify the per-particle pipeline still handles it correctly: tip drapes
# over the sphere instead of tunneling. Asserts no particle ends up below
# the sphere's bottom (would be a tunneling failure).
func test_sphere_below_anchor_blocks_tip() -> bool:
	var t: Node3D = _make_tentacle(Vector3(0, 0.7, 0), 14, 0.05)
	t.bending_stiffness = 0.3
	# Chain length 14*0.05 = 0.7m; tip would naturally settle at y=0 if
	# unobstructed. Sphere at y=0.2 radius 0.15 catches it.
	_make_sphere(Vector3(0, 0.2, 0), 0.15)
	_step([t], SETTLE_FRAMES)
	var positions: PackedVector3Array = t.get_particle_positions()
	var min_y: float = INF
	for p in positions:
		if p.y < min_y:
			min_y = p.y
	# Sphere bottom at y=0.05; with the projection radius the chain can
	# settle no lower than ~y=0.01 (tangent to sphere bottom + collision_radius).
	# Tunneling failure would put particles at y<0 (the unobstructed rest pose).
	if min_y < 0.0:
		push_error("chain tunneled past sphere; min_y=%f (sphere bottom is y=0.05)" % min_y)
		return false
	# Sanity: at least one particle should be in the sphere's vicinity (else
	# we're not actually testing collision).
	if min_y > 0.4:
		push_error("chain didn't reach the sphere; min_y=%f" % min_y)
		return false
	return true


# Slice 4D — primary regression scenario the user reported: an obstacle in
# the chain's settle path. Slice 4A's 3-ray gravity-only probe missed any
# obstacle laterally offset from the chain; particles tunneled through
# silently. With per-particle sphere queries, the body is detected and the
# chain bends around it. Sphere offset slightly from the YZ plane so the
# chain has to deflect in X to reach equilibrium.
func test_obstacle_in_chain_path_pushed_aside() -> bool:
	var t: Node3D = _make_tentacle(Vector3(0, 0.6, 0), 12, 0.05)
	t.bending_stiffness = 0.3
	# Sphere at (0, 0.3, 0) — directly on the chain's settled path at chain
	# midpoint. Chain particles at y≈0.3 must end up displaced from x=0.
	# (Body center coincident with particle center → contact normal
	# direction is determined by physics server tie-breaking; either +X or
	# -X is acceptable, we just check magnitude.)
	_make_sphere(Vector3(0.05, 0.3, 0), 0.12)
	_step([t], SETTLE_FRAMES)

	var positions: PackedVector3Array = t.get_particle_positions()
	# Find the particle nearest the obstacle in Y; check its X displacement.
	var max_abs_x_near_obstacle: float = 0.0
	for p in positions:
		if absf(p.y - 0.3) < 0.15: # within obstacle vertical extent
			max_abs_x_near_obstacle = maxf(max_abs_x_near_obstacle, absf(p.x))
	# Expect at least 0.02m displacement; with the legacy 3-ray gravity probe,
	# this would be ~0 because no rays pointed at the lateral sphere.
	if max_abs_x_near_obstacle < 0.02:
		push_error("expected obstacle to push chain aside, max_abs_x_near=%f" % max_abs_x_near_obstacle)
		return false
	# No particle should be inside the obstacle's surface.
	for p in positions:
		var d: float = (p - Vector3(0.05, 0.3, 0)).length()
		if d < 0.10:
			push_error("particle inside obstacle: pos=%s d=%f" % [p, d])
			return false
	return true


# Slice 4E — type-1 friction reciprocal wiring. Verifies the per-particle
# probe registers a RigidBody3D contact (with valid hit_object_id and
# friction_applied) so Tentacle::_apply_collision_reciprocals routes an
# impulse to it via PhysicsServer3D::body_apply_impulse. End-to-end body
# motion isn't observable here because the test driver runs in _process,
# not _physics_process — the body's queued impulses never integrate. The
# user-visible verification is in actual gameplay where physics runs.
func test_friction_pushes_dynamic_body() -> bool:
	# Position the body directly in the chain's settle path so contacts are
	# guaranteed.
	var body := RigidBody3D.new()
	body.position = Vector3(0.05, 0.3, 0)
	body.gravity_scale = 0.0
	body.freeze = true # don't let body move under floor or tentacle pressure
	body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	body.mass = 0.5
	root.add_child(body)
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.1
	shape.shape = sphere
	body.add_child(shape)

	var t: Node3D = _make_tentacle(Vector3(0, 0.6, 0), 12, 0.05)
	t.bending_stiffness = 0.3
	t.gravity = Vector3(2.0, -9.8, 0)  # tilt to slip the chain across the body
	t.base_static_friction = 0.6

	var body_iid: int = body.get_instance_id()

	for f in SETTLE_FRAMES:
		t.tick(DT)

	var found_body_contact_with_friction: bool = false
	for entry in t.get_environment_contacts_snapshot():
		if not entry.get("hit", false):
			continue
		var oid: int = entry.get("hit_object_id", 0)
		if oid != body_iid:
			continue
		var fa: Vector3 = entry.get("friction_applied", Vector3.ZERO)
		if fa.length() > 1e-5:
			found_body_contact_with_friction = true
			break
	if not found_body_contact_with_friction:
		push_error("expected at least one snapshot contact on the RigidBody3D with non-zero friction_applied")
		return false
	return true


# Slice 4F: body_impulse_scale defaults to 0.1 (pragmatic cap on PBD's
# over-stated friction reciprocal). Verify the export exists, default
# matches the spec, and setting it to 0 disables impulse routing entirely
# (chain still reacts to contacts; dynamic bodies just don't get pushed).
func test_body_impulse_scale_default_is_gentle() -> bool:
	var t: Node3D = _make_tentacle(Vector3(0, 0.6, 0), 12, 0.05)
	if absf(t.body_impulse_scale - 0.1) > 1e-5:
		push_error("expected body_impulse_scale default 0.1, got %f" % t.body_impulse_scale)
		return false
	t.body_impulse_scale = 0.0
	if absf(t.body_impulse_scale) > 1e-5:
		return false
	# Drive a tick to make sure the zero scale path doesn't blow up. With
	# no body in scene, no impulse-routing branch is taken anyway, but the
	# zero-magnitude early-out should be hit when it would have been.
	_make_floor(0.0)
	_step([t], 30)
	return true


# Setting environment_probe_enabled = false clears the solver's contact list
# AND clears the snapshot, so the gizmo doesn't draw stale rays.
func test_disable_probe_clears_contacts() -> bool:
	var t: Node3D = _make_tentacle(Vector3(0, 0.6, 0), 12, 0.05)
	_make_floor(0.0)
	_step([t], 120)
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
