extends SceneTree

# Verifies the Phase 5 slice 3a anatomical target cache: set/get round-trip,
# absent-bone sentinel, clear_bone_targets() teardown.
#
# Run:
#   godot --headless --path /home/caetano/desktop/cosmic-bliss/game \
#     --script /home/caetano/desktop/cosmic-bliss/extensions/marionette/tests/test_bone_target_cache.gd

const _CORE_CLASS := "MarionetteCore"


func _init() -> void:
	print("==== Marionette anatomical target cache test ====")
	if not ClassDB.class_exists(_CORE_CLASS):
		push_error("%s class not registered (GDExtension not loaded?)" % _CORE_CLASS)
		quit(1)
		return

	var core: Object = ClassDB.instantiate(_CORE_CLASS)
	if core == null:
		push_error("ClassDB.instantiate(%s) returned null" % _CORE_CLASS)
		quit(1)
		return

	var failures: int = 0

	# Absent-bone sentinel: empty cache returns Vector3.ZERO.
	var initial: Vector3 = core.call(&"get_bone_target", &"LeftElbow")
	if initial != Vector3.ZERO:
		push_error("absent-bone sentinel: expected ZERO, got %s" % str(initial))
		failures += 1
	else:
		print("  absent-bone sentinel = %s" % str(initial))

	# Round-trip a single target.
	var elbow_target := Vector3(0.5, 0.0, 0.0)
	core.call(&"set_bone_target", &"LeftElbow", elbow_target)
	var got_elbow: Vector3 = core.call(&"get_bone_target", &"LeftElbow")
	if got_elbow != elbow_target:
		push_error("LeftElbow round-trip: expected %s, got %s" % [elbow_target, got_elbow])
		failures += 1
	else:
		print("  LeftElbow round-trip = %s" % str(got_elbow))

	# A second bone is independent of the first.
	var knee_target := Vector3(-0.2, 0.1, 0.3)
	core.call(&"set_bone_target", &"RightKnee", knee_target)
	var got_knee: Vector3 = core.call(&"get_bone_target", &"RightKnee")
	if got_knee != knee_target:
		push_error("RightKnee round-trip: expected %s, got %s" % [knee_target, got_knee])
		failures += 1
	var still_elbow: Vector3 = core.call(&"get_bone_target", &"LeftElbow")
	if still_elbow != elbow_target:
		push_error("LeftElbow clobbered by RightKnee write: got %s" % still_elbow)
		failures += 1

	# Overwrite returns the new value.
	var elbow_target_2 := Vector3(1.0, 0.0, 0.25)
	core.call(&"set_bone_target", &"LeftElbow", elbow_target_2)
	var overwritten: Vector3 = core.call(&"get_bone_target", &"LeftElbow")
	if overwritten != elbow_target_2:
		push_error("LeftElbow overwrite: expected %s, got %s" % [elbow_target_2, overwritten])
		failures += 1

	# clear_bone_targets drops every entry — both bones return sentinel.
	core.call(&"clear_bone_targets")
	var cleared_elbow: Vector3 = core.call(&"get_bone_target", &"LeftElbow")
	var cleared_knee: Vector3 = core.call(&"get_bone_target", &"RightKnee")
	if cleared_elbow != Vector3.ZERO or cleared_knee != Vector3.ZERO:
		push_error("clear_bone_targets: expected ZERO/ZERO, got %s / %s"
				% [cleared_elbow, cleared_knee])
		failures += 1
	else:
		print("  post-clear sentinels = %s / %s" % [cleared_elbow, cleared_knee])

	core.free()

	if failures > 0:
		push_error("%d failure(s)" % failures)
		quit(1)
	else:
		print()
		print("PASS")
		quit(0)
