extends SceneTree

# Slice 4S.2 — body-local-frame contact persistence (Cosmic_Bliss
# 2026-05-06). Three sub-tests cover the core mechanism:
#
# 1. Faceted convex hull: persistence ON reduces tick-to-tick hit_point
#    variance vs persistence OFF. The pre-4S.2 churn (340 hit_point
#    shifts in 240 ticks at lub=1.0 per the round-4 diagnostic) comes
#    from `get_rest_info` returning slightly different face-nearest
#    points each tick as the chain slides tangentially across a
#    faceted hull. The cached body-local point is invariant to that
#    face-jump.
# 2. Cache invalidates on body teleport: the cached body_xform.origin
#    delta exceeding `2.0 × collision_radius × jump_threshold_factor`
#    flips the cache slot to invalid. The fresh probe owns the slot
#    the tick after.
# 3. Cache invalidates on body destroyed mid-tick: a body that gets
#    queue_free'd between ticks must cleanly invalidate any cache
#    slots that referenced it; no crash.
#
# 4Q-regression's existing 4S.1 sub=4 arm + the relaxed 4T bound
# already validate that 4S.2 doesn't regress active-probing stick-slip.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_4s2_contact_persistence.gd

const DT := 1.0 / 60.0
const SETTLE_FRAMES := 60
const MEASURE_FRAMES := 240
const CHAIN_PARTICLES := 12
const SEGMENT_LEN := 0.05
const PARTICLE_RADIUS := 0.04
const ANCHOR_Y := 0.6


var _ran: bool = false


func _process(_d: float) -> bool:
	if not _ran:
		_ran = true
		_run()
	return false


func _run() -> void:
	if not ClassDB.class_exists("Tentacle"):
		push_error("[FAIL] tentacletech extension not loaded")
		quit(2)
		return

	var passed: int = 0
	var failed: int = 0

	for test_name in [
		"test_cache_reduces_hit_point_churn_on_faceted_hull",
		"test_cache_miss_on_body_teleport",
		"test_cache_invalidates_on_rid_disappear",
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


func _reset_root() -> void:
	for c in root.get_children():
		root.remove_child(c)
		c.free()


func test_cache_reduces_hit_point_churn_on_faceted_hull() -> bool:
	# Persistence-ON vs persistence-OFF on a faceted convex hull. The
	# probe's `get_rest_info` returns slightly different face-nearest
	# points each tick as the chain slides; cache replaces with the
	# body-local→world transformed cached point (invariant to face-jump
	# on a static body). Acceptance: churn ON ≤ churn OFF × 0.6 (40%
	# reduction). Loose bound so probe-stochasticity doesn't false-fail.
	var churn_off: float = _measure_hit_point_churn(false)
	var churn_on: float = _measure_hit_point_churn(true)
	print("    churn OFF=%.6f m, ON=%.6f m, ratio=%.3f"
			% [churn_off, churn_on, churn_on / max(churn_off, 1e-9)])
	if churn_off < 1e-6:
		push_error("hit_point churn baseline too low — probe didn't churn; cannot assert cache effect")
		return false
	if churn_on > churn_off * 0.6:
		push_error("persistence ON churn=%f > 0.6 × OFF=%f — cache not stabilising hit_point"
				% [churn_on, churn_off])
		return false
	return true


func _measure_hit_point_churn(p_persist: bool) -> float:
	_reset_root()
	# Faceted box hull (8 corner verts) — get_rest_info returns the
	# closest face vertex, which jumps between faces as the chain slides
	# tangentially. Static body so the cache hit path triggers cleanly.
	var body := StaticBody3D.new()
	body.position = Vector3(0.0, 0.3, 0.0)
	root.add_child(body)
	var shape := CollisionShape3D.new()
	var hull := ConvexPolygonShape3D.new()
	hull.points = PackedVector3Array([
		Vector3(-0.1, -0.1, -0.1), Vector3( 0.1, -0.1, -0.1),
		Vector3( 0.1,  0.1, -0.1), Vector3(-0.1,  0.1, -0.1),
		Vector3(-0.1, -0.1,  0.1), Vector3( 0.1, -0.1,  0.1),
		Vector3( 0.1,  0.1,  0.1), Vector3(-0.1,  0.1,  0.1),
	])
	shape.shape = hull
	body.add_child(shape)

	var t: Node3D = ClassDB.instantiate("Tentacle")
	t.particle_count = CHAIN_PARTICLES
	t.segment_length = SEGMENT_LEN
	t.particle_collision_radius = PARTICLE_RADIUS
	t.position = Vector3(0.0, ANCHOR_Y, 0.0)
	t.gravity = Vector3(0, -9.8, 0)
	t.contact_persistence_enabled = p_persist
	root.add_child(t)

	for _i in SETTLE_FRAMES:
		t.tick(DT)

	# Take MEASURE_FRAMES of contact snapshots; sum the tick-to-tick L2
	# distance for slot-0 hit_point across in-contact particles.
	var prev_points: Dictionary = {}
	var total_churn: float = 0.0
	for _i in MEASURE_FRAMES:
		t.tick(DT)
		var contacts: Array = t.get_environment_contacts_snapshot()
		for entry in contacts:
			if not entry.has("hit") or not entry.hit:
				continue
			var pid: int = entry.get("particle_index", -1)
			var hp: Vector3 = entry.get("hit_point", Vector3())
			if prev_points.has(pid):
				total_churn += (hp - prev_points[pid] as Vector3).length()
			prev_points[pid] = hp
	return total_churn


func test_cache_miss_on_body_teleport() -> bool:
	# Settle on an AnimatableBody3D, then teleport the body more than
	# `2.0 × collision_radius × jump_threshold_factor` (=0.08m at
	# defaults). The cache must invalidate all slots referencing the
	# teleported body. Verified via
	# Tentacle.get_persistence_invalidation_count_snapshot().
	var body := AnimatableBody3D.new()
	body.position = Vector3(0.0, 0.3, 0.0)
	body.sync_to_physics = false
	root.add_child(body)
	var shape := CollisionShape3D.new()
	var hull := ConvexPolygonShape3D.new()
	hull.points = PackedVector3Array([
		Vector3(-0.1, -0.1, -0.1), Vector3( 0.1, -0.1, -0.1),
		Vector3( 0.1,  0.1, -0.1), Vector3(-0.1,  0.1, -0.1),
		Vector3(-0.1, -0.1,  0.1), Vector3( 0.1, -0.1,  0.1),
		Vector3( 0.1,  0.1,  0.1), Vector3(-0.1,  0.1,  0.1),
	])
	shape.shape = hull
	body.add_child(shape)

	var t: Node3D = ClassDB.instantiate("Tentacle")
	t.particle_count = CHAIN_PARTICLES
	t.segment_length = SEGMENT_LEN
	t.particle_collision_radius = PARTICLE_RADIUS
	t.position = Vector3(0.0, ANCHOR_Y, 0.0)
	t.gravity = Vector3(0, -9.8, 0)
	t.contact_persistence_enabled = true
	root.add_child(t)

	for _i in SETTLE_FRAMES:
		t.tick(DT)
	# Confirm at least one particle ended up in contact (so the cache
	# has something to invalidate).
	var contacts_pre: PackedByteArray = t.get_in_contact_this_tick_snapshot()
	var contact_count_pre: int = 0
	for b in contacts_pre:
		if b > 0:
			contact_count_pre += 1
	if contact_count_pre == 0:
		push_error("test setup: no particles in contact after settle")
		return false

	# Teleport the body laterally by 1 m — well above the jump threshold.
	body.position = Vector3(1.0, 0.3, 0.0)
	# One more tick to fire _validate_and_reseed_persistence with the
	# teleported body transform.
	t.tick(DT)
	var inv_counts: PackedInt32Array = t.get_persistence_invalidation_count_snapshot()
	var total_invs: int = 0
	for c in inv_counts:
		total_invs += c
	print("    contact_count_pre=%d, total_invs=%d" % [contact_count_pre, total_invs])
	if total_invs < 1:
		push_error("expected ≥ 1 cache invalidation after body teleport; got %d" % total_invs)
		return false
	return true


func test_cache_invalidates_on_rid_disappear() -> bool:
	# Spawn a StaticBody3D, settle, then queue_free it. The next tick
	# must not crash and must invalidate cached slots referencing the
	# dead body (ObjectDB::get_instance returns null → cache slot flips
	# to invalid).
	var body := StaticBody3D.new()
	body.position = Vector3(0.0, 0.3, 0.0)
	root.add_child(body)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.2, 0.2, 0.2)
	shape.shape = box
	body.add_child(shape)

	var t: Node3D = ClassDB.instantiate("Tentacle")
	t.particle_count = CHAIN_PARTICLES
	t.segment_length = SEGMENT_LEN
	t.particle_collision_radius = PARTICLE_RADIUS
	t.position = Vector3(0.0, ANCHOR_Y, 0.0)
	t.gravity = Vector3(0, -9.8, 0)
	t.contact_persistence_enabled = true
	root.add_child(t)

	for _i in SETTLE_FRAMES:
		t.tick(DT)
	# Verify at least one cache slot was populated.
	var contacts_pre: PackedByteArray = t.get_in_contact_this_tick_snapshot()
	var contact_count_pre: int = 0
	for b in contacts_pre:
		if b > 0:
			contact_count_pre += 1
	if contact_count_pre == 0:
		push_error("test setup: no particles in contact after settle")
		return false

	# Free the body. queue_free flips the instance to "pending free" — the
	# next ObjectDB::get_instance call returns null. _validate_and_reseed_persistence
	# at outer-tick start sees null and invalidates the cache.
	body.queue_free()
	await physics_frame

	# One more tick. Must not crash and must invalidate.
	t.tick(DT)
	var inv_counts: PackedInt32Array = t.get_persistence_invalidation_count_snapshot()
	var total_invs: int = 0
	for c in inv_counts:
		total_invs += c
	print("    contact_count_pre=%d, total_invs=%d" % [contact_count_pre, total_invs])
	if total_invs < 1:
		push_error("expected ≥ 1 cache invalidation after queue_free; got %d" % total_invs)
		return false
	# Sanity — chain should also have no contact this tick (body gone).
	var contacts_post: PackedByteArray = t.get_in_contact_this_tick_snapshot()
	var contact_count_post: int = 0
	for b in contacts_post:
		if b > 0:
			contact_count_post += 1
	if contact_count_post > 0:
		push_error("expected no contact after body destroyed; got %d in contact" % contact_count_post)
		return false
	return true
