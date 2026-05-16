extends SceneTree

# Slice TT-S3 — §10.5 contact-suppression tests.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_tt_s3_contact_suppression.gd
#
# Acceptance per docs/architecture/TentacleTech_Architecture.md §10.5 and
# docs/Cosmic_Bliss_Update_2026-05-14-03_ragdoll_under_tension_scenario.md
# §4 slice (2).
#
# Scope: capsule-path suppression only. Proxy-path (body_field tet body)
# is out of scope until B5 ships.
#
# Identifier-lookup gotcha: GDExtension classes register at
# MODULE_INITIALIZATION_LEVEL_SCENE — after the GDScript parser has
# resolved identifiers in `--script` mode. Tests instantiate via
# ClassDB.instantiate(...) to sidestep the parse-time lookup.

const DT := 1.0 / 60.0
const SETTLE_FRAMES := 60

const _OrificeProfile := preload(
		"res://addons/tentacletech/scripts/resources/orifice_profile.gd")
const _OrificeSuppression := preload(
		"res://addons/tentacletech/scripts/util/orifice_suppression.gd")


var _ran: bool = false


# _init() runs before the SceneTree finishes wiring `root`. Defer to the
# first _process tick where the tree is live.
func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_run_tests()
	return true


func _run_tests() -> void:
	if not ClassDB.class_exists("Orifice"):
		push_error("[FAIL] tentacletech extension not loaded (Orifice missing)")
		quit(2)
		return
	if not ClassDB.class_exists("Tentacle"):
		push_error("[FAIL] tentacletech extension not loaded (Tentacle missing)")
		quit(2)
		return

	var passed: int = 0
	var failed: int = 0

	for test_name in [
		"test_profile_effective_set_unions",
		"test_orifice_resolves_bone_names_to_object_ids",
		"test_suppression_drops_capsule_contact_in_ei",
		"test_suppression_does_not_affect_non_ei_tentacles",
		"test_no_skeleton_no_suppression",
		"test_unresolvable_bone_name_warns_but_doesnt_crash",
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
	for c in root.get_children():
		root.remove_child(c)
		c.free()


# ---------------------------------------------------------------------------
# Test 1 — OrificeProfile.get_effective_suppression_set unions auto + manual
# with no duplicates.

func test_profile_effective_set_unions() -> bool:
	# Case A — both empty.
	var p_empty := _OrificeProfile.new()
	if p_empty.get_effective_suppression_set().size() != 0:
		push_error("empty profile should produce empty set")
		return false

	# Case B — auto-only.
	var p_auto := _OrificeProfile.new()
	p_auto.suppressed_bones = PackedStringArray(["Hips", "Spine"])
	var s_auto: PackedStringArray = p_auto.get_effective_suppression_set()
	if s_auto.size() != 2 or not s_auto.has("Hips") or not s_auto.has("Spine"):
		push_error("auto-only union failed: %s" % str(s_auto))
		return false

	# Case C — manual-only.
	var p_manual := _OrificeProfile.new()
	p_manual.manual_suppressed_bones = PackedStringArray(["Neck", "Chest"])
	var s_man: PackedStringArray = p_manual.get_effective_suppression_set()
	if s_man.size() != 2 or not s_man.has("Neck") or not s_man.has("Chest"):
		push_error("manual-only union failed: %s" % str(s_man))
		return false

	# Case D — auto + manual with overlap.
	var p_both := _OrificeProfile.new()
	p_both.suppressed_bones = PackedStringArray(["Hips", "Spine"])
	p_both.manual_suppressed_bones = PackedStringArray(["Spine", "Neck"])
	var s_both: PackedStringArray = p_both.get_effective_suppression_set()
	if s_both.size() != 3:
		push_error("union dedup failed: size %d (expected 3) → %s" %
				[s_both.size(), str(s_both)])
		return false
	for required in ["Hips", "Spine", "Neck"]:
		if not s_both.has(required):
			push_error("union missing '%s': %s" % [required, str(s_both)])
			return false
	return true


# ---------------------------------------------------------------------------
# Test 2 — bone-name → PhysicalBone3D.ObjectID resolution.
#
# Build a Skeleton3D with bones Hips/Spine/Neck and matching PhysicalBone3D
# children whose `bone_name` is the same. Profile suppresses Spine only.
# After apply_to_orifice, the orifice's is_object_id_suppressed returns true
# only for Spine's PhysicalBone3D.

func test_orifice_resolves_bone_names_to_object_ids() -> bool:
	var skel: Skeleton3D = _make_skeleton_with_bones(
			PackedStringArray(["Hips", "Spine", "Neck"]))
	var sim: Node = _attach_physical_bones(skel,
			PackedStringArray(["Hips", "Spine", "Neck"]))

	var o: Node3D = ClassDB.instantiate("Orifice")
	root.add_child(o)

	var profile := _OrificeProfile.new()
	profile.manual_suppressed_bones = PackedStringArray(["Spine"])
	var ids: PackedInt64Array = _OrificeSuppression.apply_to_orifice(
			o, profile, skel)
	if ids.size() != 1:
		push_error("expected 1 resolved ID, got %d (%s)" % [ids.size(), str(ids)])
		return false

	# Find Hips / Spine / Neck PhysicalBone3D children.
	var hips_id: int = _find_pb_id(sim, "Hips")
	var spine_id: int = _find_pb_id(sim, "Spine")
	var neck_id: int = _find_pb_id(sim, "Neck")
	if spine_id <= 0 or hips_id <= 0 or neck_id <= 0:
		push_error("missing PhysicalBone3D children (hips=%d spine=%d neck=%d)" %
				[hips_id, spine_id, neck_id])
		return false

	if not o.is_object_id_suppressed(spine_id):
		push_error("Spine PB not in suppression set")
		return false
	if o.is_object_id_suppressed(hips_id):
		push_error("Hips PB unexpectedly in suppression set")
		return false
	if o.is_object_id_suppressed(neck_id):
		push_error("Neck PB unexpectedly in suppression set")
		return false

	# Snapshot accessor returns the resolved IDs by copy.
	var snap: PackedInt64Array = o.get_suppressed_object_ids_snapshot()
	if snap.size() != 1 or snap[0] != spine_id:
		push_error("snapshot mismatch: %s expected [%d]" % [str(snap), spine_id])
		return false

	return true


# ---------------------------------------------------------------------------
# Test 3 — When a tentacle has an active EI on an orifice whose suppression
# set contains a body the tentacle touches, the EnvironmentContact slot
# for that body is flagged hit_suppressed AND hit_depth zeroes.
#
# Setup: create a StaticBody3D acting as a "rib capsule" right where the
# tentacle particle 1 sits. With no suppression, the probe reports a hit
# (control). After adding the body's ID to the orifice and registering
# the tentacle as having an active EI, the same probe reports the slot
# as suppressed.

func test_suppression_drops_capsule_contact_in_ei() -> bool:
	var t: Node3D = _make_minimal_tentacle(Vector3.ZERO)
	# Static body at the tentacle particle 1 position, sized large enough
	# that the sphere probe (collision radius 0.04) overlaps.
	var p1_world: Vector3 = t.global_position + Vector3(0, 0, 0.05)
	var body: StaticBody3D = _make_static_sphere(p1_world, 0.10)

	# Control: tick once without suppression — probe should hit.
	t.tick(DT)
	var snap_ctrl: Array = t.get_environment_contacts_snapshot()
	var hit_anywhere: bool = _any_contact_hit(snap_ctrl, body.get_instance_id())
	if not hit_anywhere:
		push_error("control: expected at least one contact on the static body, got none")
		return false

	# Build a minimal orifice with suppression on the body's ID.
	var o: Node3D = ClassDB.instantiate("Orifice")
	root.add_child(o)
	o.set_suppressed_object_ids(PackedInt64Array([body.get_instance_id()]))
	# Verify suppression set populated.
	if not o.is_object_id_suppressed(body.get_instance_id()):
		push_error("orifice failed to record suppressed object id")
		return false

	# Simulate "tentacle has an active EI on this orifice" by calling the
	# C++ registration API directly (this is what Orifice's EI lifecycle
	# does internally).
	t.register_active_ei_orifice(o)
	if t.get_active_ei_orifice_count() != 1:
		push_error("active_ei_orifice_count != 1 after register: %d" %
				t.get_active_ei_orifice_count())
		return false

	# Tick again — now the suppression filter should mark slot 0 suppressed.
	t.tick(DT)
	var snap_sup: Array = t.get_environment_contacts_snapshot()
	var saw_suppressed: bool = false
	for entry in snap_sup:
		var slots: Array = entry.get("contacts", [])
		for slot in slots:
			if int(slot.get("hit_object_id", 0)) == body.get_instance_id():
				if slot.get("hit_suppressed", false):
					saw_suppressed = true
				if float(slot.get("hit_depth", -1.0)) > 0.0:
					push_error("suppressed slot still has positive depth %f" %
							float(slot.get("hit_depth", 0.0)))
					return false
	if not saw_suppressed:
		push_error("no contact slot flagged hit_suppressed in EI-active tick")
		return false

	# Unregister — next tick, contact should NOT be suppressed.
	t.unregister_active_ei_orifice(o)
	if t.get_active_ei_orifice_count() != 0:
		push_error("active_ei_orifice_count != 0 after unregister")
		return false
	t.tick(DT)
	var snap_un: Array = t.get_environment_contacts_snapshot()
	for entry in snap_un:
		var slots: Array = entry.get("contacts", [])
		for slot in slots:
			if int(slot.get("hit_object_id", 0)) == body.get_instance_id():
				if slot.get("hit_suppressed", false):
					push_error("contact still suppressed after unregister")
					return false
	return true


# ---------------------------------------------------------------------------
# Test 4 — Suppression does NOT affect tentacles without an active EI on
# the orifice, even when the same body is in the orifice's suppression
# set. Two tentacles, one registered, one not — only the registered one
# sees suppression.

func test_suppression_does_not_affect_non_ei_tentacles() -> bool:
	var t_ei: Node3D = _make_minimal_tentacle(Vector3.ZERO)
	var t_free: Node3D = _make_minimal_tentacle(Vector3(0.5, 0, 0))
	# Two distinct bodies, each at the per-tentacle particle 1 position.
	var b_ei: StaticBody3D = _make_static_sphere(
			t_ei.global_position + Vector3(0, 0, 0.05), 0.10)
	var b_free: StaticBody3D = _make_static_sphere(
			t_free.global_position + Vector3(0, 0, 0.05), 0.10)

	var o: Node3D = ClassDB.instantiate("Orifice")
	root.add_child(o)
	# Suppress BOTH bodies — the difference must come from the EI link,
	# not from which body is in the set.
	o.set_suppressed_object_ids(PackedInt64Array([
			b_ei.get_instance_id(), b_free.get_instance_id()]))
	t_ei.register_active_ei_orifice(o)

	t_ei.tick(DT)
	t_free.tick(DT)

	# t_ei should see suppression on b_ei.
	var snap_ei: Array = t_ei.get_environment_contacts_snapshot()
	var saw_ei_supp: bool = false
	for entry in snap_ei:
		for slot in entry.get("contacts", []):
			if int(slot.get("hit_object_id", 0)) == b_ei.get_instance_id():
				if slot.get("hit_suppressed", false):
					saw_ei_supp = true
	if not saw_ei_supp:
		push_error("t_ei did not see suppression on its body")
		return false

	# t_free must NOT see suppression on b_free (no EI link).
	var snap_free: Array = t_free.get_environment_contacts_snapshot()
	for entry in snap_free:
		for slot in entry.get("contacts", []):
			if int(slot.get("hit_object_id", 0)) == b_free.get_instance_id():
				if slot.get("hit_suppressed", false):
					push_error("t_free saw suppression despite no EI registration")
					return false
	return true


# ---------------------------------------------------------------------------
# Test 5 — no skeleton → resolve returns empty list → orifice has no IDs
# → per-tick filter trivially passes.

func test_no_skeleton_no_suppression() -> bool:
	var o: Node3D = ClassDB.instantiate("Orifice")
	root.add_child(o)
	var profile := _OrificeProfile.new()
	profile.manual_suppressed_bones = PackedStringArray(["Hips", "Spine"])

	var ids: PackedInt64Array = _OrificeSuppression.apply_to_orifice(
			o, profile, null)
	if ids.size() != 0:
		push_error("no-skeleton path produced non-empty ID list: %s" % str(ids))
		return false
	if o.get_suppressed_object_ids_snapshot().size() != 0:
		push_error("orifice has non-empty set despite null skeleton")
		return false

	# A tentacle in range of any body should not have suppressed contacts.
	var t: Node3D = _make_minimal_tentacle(Vector3.ZERO)
	var body: StaticBody3D = _make_static_sphere(
			t.global_position + Vector3(0, 0, 0.05), 0.10)
	t.register_active_ei_orifice(o)
	t.tick(DT)
	var snap: Array = t.get_environment_contacts_snapshot()
	for entry in snap:
		for slot in entry.get("contacts", []):
			if int(slot.get("hit_object_id", 0)) == body.get_instance_id():
				if slot.get("hit_suppressed", false):
					push_error("contact suppressed with empty ID set")
					return false
	return true


# ---------------------------------------------------------------------------
# Test 6 — unresolvable bone names produce a warning but don't crash.
# resolve_bone_names_to_object_ids returns the valid subset.

func test_unresolvable_bone_name_warns_but_doesnt_crash() -> bool:
	var skel: Skeleton3D = _make_skeleton_with_bones(
			PackedStringArray(["Hips", "Spine"]))
	var _sim: Node = _attach_physical_bones(skel,
			PackedStringArray(["Hips", "Spine"]))

	var profile := _OrificeProfile.new()
	profile.manual_suppressed_bones = PackedStringArray(
			["Hips", "NoSuchBone", "Spine"])

	var o: Node3D = ClassDB.instantiate("Orifice")
	root.add_child(o)

	var ids: PackedInt64Array = _OrificeSuppression.apply_to_orifice(
			o, profile, skel)
	# Two valid → two IDs; the bogus name was skipped.
	if ids.size() != 2:
		push_error("expected 2 resolved IDs, got %d (%s)" % [ids.size(), str(ids)])
		return false
	return true


# ---------------------------------------------------------------------------
# Helpers

func _make_skeleton_with_bones(bones: PackedStringArray) -> Skeleton3D:
	var skel := Skeleton3D.new()
	skel.name = "TestSkeleton"
	root.add_child(skel)
	for b in bones:
		skel.add_bone(b)
	skel.reset_bone_poses()
	return skel


# Attach a PhysicalBoneSimulator3D + one PhysicalBone3D per bone name.
# Returns the simulator node so callers can introspect.
func _attach_physical_bones(skel: Skeleton3D, bones: PackedStringArray) -> Node:
	# Skeleton3D's PhysicalBoneSimulator3D is the §10.4 source-of-truth;
	# add it as a child of the skeleton so PhysicalBone3D nodes can find
	# the skeleton via parenting (same pattern Godot's default ragdoll
	# build uses).
	var sim := PhysicalBoneSimulator3D.new()
	sim.name = "PhysicalBoneSimulator3D"
	skel.add_child(sim)
	for b in bones:
		var pb := PhysicalBone3D.new()
		pb.bone_name = b
		pb.name = "PB_" + b
		sim.add_child(pb)
	return sim


# Find the instance ID of the PhysicalBone3D under `sim` whose bone_name
# matches; -1 if not found.
func _find_pb_id(sim: Node, bone_name: String) -> int:
	for child in sim.get_children():
		if not child is PhysicalBone3D:
			continue
		if String(child.bone_name) == bone_name:
			return child.get_instance_id()
	return -1


# Minimal tentacle for contact tests. 4 particles, segment 0.05 m, anchored
# at p_pos. The chain hangs straight along +Z by default at rest.
func _make_minimal_tentacle(p_pos: Vector3) -> Node3D:
	var t: Node3D = ClassDB.instantiate("Tentacle")
	t.particle_count = 4
	t.segment_length = 0.05
	t.position = p_pos
	# No gravity — keep the chain near rest so contacts are predictable.
	t.gravity = Vector3.ZERO
	t.environment_probe_distance = 1.0
	t.particle_collision_radius = 0.04
	root.add_child(t)
	return t


func _make_static_sphere(p_pos: Vector3, p_radius: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = p_pos
	root.add_child(body)
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = p_radius
	shape.shape = sphere
	body.add_child(shape)
	return body


func _any_contact_hit(snap: Array, target_object_id: int) -> bool:
	for entry in snap:
		var slots: Array = entry.get("contacts", [])
		for slot in slots:
			if int(slot.get("hit_object_id", 0)) == target_object_id:
				return true
	return false
