extends SceneTree

# Phase 6 — Stimulus Bus minimum slice unit tests.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_p6_stimulus_bus.gd
#
# Spec: docs/architecture/TentacleTech_Architecture.md §8.
# Scenario slice: docs/Cosmic_Bliss_Update_2026-05-14-03_ragdoll_under_tension_scenario.md §4 slice 7.
#
# Covers the bus seam (ring buffer + continuous channels) and verifies
# that PenetrationStart + RingTransitStart fire at EI creation and
# grip_engagement publishes to the continuous channel.

const DT := 1.0 / 60.0
const ENTRY_AXIS := Vector3(0.0, 0.0, 1.0)


var _ran: bool = false


func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_run_tests()
	return true


func _run_tests() -> void:
	if not ClassDB.class_exists("StimulusBus"):
		push_error("[FAIL] tentacletech extension not loaded (StimulusBus missing)")
		quit(2)
		return
	if not ClassDB.class_exists("Orifice") or not ClassDB.class_exists("Tentacle"):
		push_error("[FAIL] tentacletech Orifice/Tentacle missing")
		quit(2)
		return

	var passed: int = 0
	var failed: int = 0

	for test_name in [
		"test_bus_starts_empty",
		"test_emit_pushes_event_to_ring_buffer",
		"test_ring_buffer_wraps_at_capacity",
		"test_time_window_filters_events",
		"test_type_filter_returns_only_matching_type",
		"test_orifice_state_field_set_get_roundtrips",
		"test_penetration_start_fires_at_ei_creation",
		"test_grip_engaged_continuous_channel_updates",
		"test_bus_clear_resets_state",
	]:
		if call(test_name):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			push_error("[FAIL] %s" % test_name)
			failed += 1

	print("\nPhase 6 stimulus bus minimum: %d/%d passed" % [passed, passed + failed])
	quit(0 if failed == 0 else 2)


# --- Helpers -----------------------------------------------------------

func _make_bus() -> Object:
	# Create a fresh bus and install as singleton so the orifice's
	# emit calls find it. Tests are sequential, so the previous test's
	# bus uninstall (via clear + new install) leaves the singleton in
	# the desired state at each test's start.
	var bus: Object = ClassDB.instantiate("StimulusBus")
	bus.install_as_singleton()
	return bus


func _teardown_bus(bus: Object) -> void:
	if bus == null:
		return
	bus.uninstall_as_singleton()


func _make_orifice() -> Node3D:
	var o: Node3D = ClassDB.instantiate("Orifice")
	o.entry_axis = ENTRY_AXIS
	o.name = "TestOrifice%d" % (Time.get_ticks_usec())
	get_root().add_child(o)
	var p_n: int = 8
	var rest_pos: PackedVector3Array = o.make_circular_rest_positions(p_n, 0.05, ENTRY_AXIS)
	var seg_lens: PackedFloat32Array = o.make_uniform_segment_rest_lengths(rest_pos)
	var area: float = absf(o.compute_polygon_area(rest_pos, ENTRY_AXIS))
	var stf := PackedFloat32Array()
	stf.resize(p_n)
	for i in p_n:
		stf[i] = 0.5
	o.add_rim_loop(rest_pos, seg_lens, area, stf, 1e-4, 1e-6, 0.02)
	return o


func _make_tentacle_for_ei(p_anchor: Vector3) -> Node3D:
	var t: Node3D = ClassDB.instantiate("Tentacle")
	t.particle_count = 4
	t.segment_length = 0.05
	t.particle_collision_radius = 0.04
	t.gravity = Vector3.ZERO
	t.environment_probe_distance = 0.0
	t.position = p_anchor
	t.name = "TestTentacleP6_%d" % (Time.get_ticks_usec())
	get_root().add_child(t)
	var sol: Object = t.get_solver()
	for i in 4:
		sol.set_particle_position(i, p_anchor + ENTRY_AXIS * (0.05 * float(i)))
	return t


# --- Tests -------------------------------------------------------------

func test_bus_starts_empty() -> bool:
	var bus: Object = _make_bus()
	var ok := true
	if int(bus.get_event_count()) != 0:
		push_error("expected 0 events on fresh bus, got %d" % int(bus.get_event_count()))
		ok = false
	var ev: Array = bus.get_recent_events(10.0, -1)
	if not ev.is_empty():
		push_error("expected empty recent events on fresh bus, got %d" % ev.size())
		ok = false
	if int(bus.get_capacity()) != 256:
		push_error("expected capacity 256, got %d" % int(bus.get_capacity()))
		ok = false
	_teardown_bus(bus)
	return ok


func test_emit_pushes_event_to_ring_buffer() -> bool:
	var bus: Object = _make_bus()
	var pen_type: int = ClassDB.class_get_integer_constant("StimulusBus", "EVENT_PenetrationStart")
	var extra := {"orifice_id": 12345, "tentacle_id": 6789, "depth_normalized": 0.42}
	bus.emit(pen_type, 1.0, 0.0, Vector3(1, 2, 3), 0, 6789, 12345, extra)
	var ok := true
	if int(bus.get_event_count()) != 1:
		push_error("expected event_count == 1, got %d" % int(bus.get_event_count()))
		ok = false
	var evs: Array = bus.get_recent_events(10.0, -1)
	if evs.size() != 1:
		push_error("expected 1 recent event, got %d" % evs.size())
		ok = false
	else:
		var e: Dictionary = evs[0]
		if int(e.get("type", -1)) != pen_type:
			push_error("wrong type: %d" % int(e.get("type", -1)))
			ok = false
		if (e.get("world_position", Vector3.ZERO) as Vector3).distance_to(Vector3(1, 2, 3)) > 1e-5:
			push_error("wrong world_position: %s" % str(e.get("world_position", Vector3.ZERO)))
			ok = false
		var ex: Dictionary = e.get("extra", {})
		if float(ex.get("depth_normalized", -1.0)) != 0.42:
			push_error("extra not roundtripped: %s" % str(ex))
			ok = false
	_teardown_bus(bus)
	return ok


func test_ring_buffer_wraps_at_capacity() -> bool:
	var bus: Object = _make_bus()
	var pen_type: int = ClassDB.class_get_integer_constant("StimulusBus", "EVENT_PenetrationStart")
	for i in 300:
		bus.emit(pen_type, float(i), 0.0, Vector3.ZERO, 0, 0, 0, {"i": i})
	var ok := true
	if int(bus.get_event_count()) != 256:
		push_error("expected event_count clamped to 256, got %d" % int(bus.get_event_count()))
		ok = false
	# Oldest events should have been overwritten — the 256 surviving events
	# are i = 44..299. Sample by magnitude.
	var evs: Array = bus.get_recent_events(1000.0, -1)
	if evs.size() != 256:
		push_error("expected 256 recent events, got %d" % evs.size())
		ok = false
	else:
		var first: Dictionary = evs[0]
		var last: Dictionary = evs[255]
		if int(first.get("magnitude", -1)) < 30:
			push_error("oldest surviving event too old: magnitude=%d" % int(first.get("magnitude", -1)))
			ok = false
		if int(last.get("magnitude", -1)) != 299:
			push_error("newest surviving event wrong: magnitude=%d" % int(last.get("magnitude", -1)))
			ok = false
	_teardown_bus(bus)
	return ok


func test_time_window_filters_events() -> bool:
	var bus: Object = _make_bus()
	var pen_type: int = ClassDB.class_get_integer_constant("StimulusBus", "EVENT_PenetrationStart")
	bus.emit(pen_type, 1.0, 0.0, Vector3.ZERO, 0, 0, 0, {})
	# Advance the bus clock past the time window. The first event's
	# timestamp is now ~5s behind 'now'.
	bus.test_advance_clock(5.0)
	bus.emit(pen_type, 2.0, 0.0, Vector3.ZERO, 0, 0, 0, {})
	var ok := true
	var recent: Array = bus.get_recent_events(2.0, -1)
	if recent.size() != 1:
		push_error("expected 1 recent event within 2s window, got %d" % recent.size())
		ok = false
	elif float((recent[0] as Dictionary).get("magnitude", -1.0)) != 2.0:
		push_error("expected newest (magnitude=2) event, got %f" %
				float((recent[0] as Dictionary).get("magnitude", -1.0)))
		ok = false
	# Wide window catches both.
	var all_ev: Array = bus.get_recent_events(100.0, -1)
	if all_ev.size() != 2:
		push_error("expected both events in wide window, got %d" % all_ev.size())
		ok = false
	_teardown_bus(bus)
	return ok


func test_type_filter_returns_only_matching_type() -> bool:
	var bus: Object = _make_bus()
	var pen_type: int = ClassDB.class_get_integer_constant("StimulusBus", "EVENT_PenetrationStart")
	var grip_break_type: int = ClassDB.class_get_integer_constant("StimulusBus", "EVENT_GripBroke")
	for i in 3:
		bus.emit(pen_type, float(i), 0.0, Vector3.ZERO, 0, 0, 0, {})
	for i in 2:
		bus.emit(grip_break_type, float(i + 10), 0.0, Vector3.ZERO, 0, 0, 0, {})
	var ok := true
	var pen_only: Array = bus.get_recent_events(100.0, pen_type)
	if pen_only.size() != 3:
		push_error("expected 3 PenetrationStart, got %d" % pen_only.size())
		ok = false
	var grip_only: Array = bus.get_recent_events(100.0, grip_break_type)
	if grip_only.size() != 2:
		push_error("expected 2 GripBroke, got %d" % grip_only.size())
		ok = false
	var all_ev: Array = bus.get_recent_events(100.0, -1)
	if all_ev.size() != 5:
		push_error("expected 5 total, got %d" % all_ev.size())
		ok = false
	_teardown_bus(bus)
	return ok


func test_orifice_state_field_set_get_roundtrips() -> bool:
	var bus: Object = _make_bus()
	var oid: int = 4242
	bus.set_orifice_state_field(oid, &"grip_engagement", 0.7)
	bus.set_orifice_state_field(oid, &"damage_rate", 0.15)
	var ok := true
	var v: float = bus.get_orifice_state_field(oid, &"grip_engagement")
	if absf(v - 0.7) > 1e-6:
		push_error("grip_engagement roundtrip: got %f" % v)
		ok = false
	var snap: Dictionary = bus.get_orifice_state_snapshot(oid)
	if absf(float(snap.get("grip_engagement", -1.0)) - 0.7) > 1e-6:
		push_error("snapshot missing grip_engagement: %s" % str(snap))
		ok = false
	if absf(float(snap.get("damage_rate", -1.0)) - 0.15) > 1e-6:
		push_error("snapshot missing damage_rate: %s" % str(snap))
		ok = false
	# Unknown orifice returns empty + 0.0 — not an error.
	var missing: Dictionary = bus.get_orifice_state_snapshot(9999999)
	if not missing.is_empty():
		push_error("unknown orifice should snapshot empty, got %s" % str(missing))
		ok = false
	if bus.get_orifice_state_field(9999999, &"grip_engagement") != 0.0:
		push_error("unknown orifice/field should return 0.0")
		ok = false
	_teardown_bus(bus)
	return ok


func test_penetration_start_fires_at_ei_creation() -> bool:
	var bus: Object = _make_bus()
	var o: Node3D = _make_orifice()
	# Anchor outside the entry plane on -Z; chain pushes through to +Z.
	var t: Node3D = _make_tentacle_for_ei(Vector3(0.0, 0.0, -0.05))
	o.register_tentacle(NodePath("/root/" + str(t.name)))
	o.tick(DT)

	var ok := true
	var pen_type: int = ClassDB.class_get_integer_constant("StimulusBus", "EVENT_PenetrationStart")
	var ring_type: int = ClassDB.class_get_integer_constant("StimulusBus", "EVENT_RingTransitStart")
	var pen_evs: Array = bus.get_recent_events(10.0, pen_type)
	if pen_evs.size() != 1:
		push_error("expected exactly 1 PenetrationStart at EI creation, got %d" % pen_evs.size())
		ok = false
	else:
		var e: Dictionary = pen_evs[0]
		var extra: Dictionary = e.get("extra", {})
		if int(extra.get("orifice_id", -1)) != int(o.get_instance_id()):
			push_error("PenetrationStart orifice_id mismatch: %d vs %d" %
					[int(extra.get("orifice_id", -1)), int(o.get_instance_id())])
			ok = false
		if int(extra.get("tentacle_id", -1)) != int(t.get_instance_id()):
			push_error("PenetrationStart tentacle_id mismatch: %d vs %d" %
					[int(extra.get("tentacle_id", -1)), int(t.get_instance_id())])
			ok = false
	var ring_evs: Array = bus.get_recent_events(10.0, ring_type)
	if ring_evs.size() != 1:
		push_error("expected RingTransitStart stub at EI creation, got %d" % ring_evs.size())
		ok = false

	# Second tick: EI still active (no new EI created) — no new
	# PenetrationStart should fire.
	o.tick(DT)
	pen_evs = bus.get_recent_events(10.0, pen_type)
	if pen_evs.size() != 1:
		push_error("PenetrationStart fired a second time on subsequent tick: %d" % pen_evs.size())
		ok = false

	o.queue_free()
	t.queue_free()
	_teardown_bus(bus)
	return ok


func test_grip_engaged_continuous_channel_updates() -> bool:
	var bus: Object = _make_bus()
	var o: Node3D = _make_orifice()
	var t: Node3D = _make_tentacle_for_ei(Vector3(0.0, 0.0, -0.05))
	o.register_tentacle(NodePath("/root/" + str(t.name)))

	# Tick a few times to let grip ramp under stationarity.
	for i in 30:
		o.tick(DT)

	var ok := true
	var oid: int = int(o.get_instance_id())
	var snap: Dictionary = bus.get_orifice_state_snapshot(oid)
	if snap.is_empty():
		push_error("orifice_state snapshot empty after ticks (expected continuous publish)")
		ok = false
	# active_tentacle_count should be 1 once an EI exists.
	if int(snap.get("active_tentacle_count", -1)) != 1:
		push_error("active_tentacle_count expected 1, got %d" %
				int(snap.get("active_tentacle_count", -1)))
		ok = false
	# grip_engagement should be > 0 after stationary ticks (the
	# tentacle's particle 0 is anchored, no axial drift → grip ramps).
	# Bus field set monotonically; we just check the seam carries data.
	var grip: float = bus.get_orifice_state_field(oid, &"grip_engagement")
	if grip <= 0.0:
		push_error("expected grip_engagement > 0 after stationary ticks, got %f" % grip)
		ok = false

	o.queue_free()
	t.queue_free()
	_teardown_bus(bus)
	return ok


func test_bus_clear_resets_state() -> bool:
	var bus: Object = _make_bus()
	var pen_type: int = ClassDB.class_get_integer_constant("StimulusBus", "EVENT_PenetrationStart")
	for i in 5:
		bus.emit(pen_type, float(i), 0.0, Vector3.ZERO, 0, 0, 0, {})
	bus.set_orifice_state_field(7777, &"grip_engagement", 0.5)
	if int(bus.get_event_count()) != 5:
		push_error("pre-clear expected 5 events, got %d" % int(bus.get_event_count()))
		_teardown_bus(bus)
		return false
	bus.clear()
	var ok := true
	if int(bus.get_event_count()) != 0:
		push_error("post-clear expected 0 events, got %d" % int(bus.get_event_count()))
		ok = false
	if not bus.get_orifice_state_snapshot(7777).is_empty():
		push_error("post-clear orifice_state should be empty")
		ok = false
	_teardown_bus(bus)
	return ok
