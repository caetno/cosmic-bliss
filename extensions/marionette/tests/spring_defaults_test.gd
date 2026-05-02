extends SceneTree

# Slice-2 verification: BoneProfileGenerator seeds spring_stiffness /
# spring_damping with archetype-refined defaults, and a hand-tuned bone
# survives a re-Calibrate.
#
# Run:
#   godot --headless --path /home/caetano/desktop/cosmic-bliss/game \
#     --script /home/caetano/desktop/cosmic-bliss/extensions/marionette/tests/spring_defaults_test.gd

const KASUMI_SCENE: String = "res://tests/marionette/kasumi/kasumi.tscn"


func _init() -> void:
	print("==== Marionette spring-defaults seed + preserve test ====")
	var packed: PackedScene = load(KASUMI_SCENE)
	if packed == null:
		push_error("Failed to load kasumi scene")
		quit(1)
		return
	var inst: Node = packed.instantiate()
	root.add_child(inst)
	await process_frame

	var marionette: Marionette = _find_marionette(inst)
	if marionette == null:
		push_error("No Marionette node in kasumi scene")
		quit(1)
		return

	# Reset the bone_profile so we exercise the seed-defaults path on a
	# truly empty start.
	marionette.bone_profile.bones = {}

	print("Calibrating fresh profile ...")
	marionette.calibrate_bone_profile_from_skeleton()

	var failures: int = 0
	# Spot-check a handful of representative bones across archetypes.
	var checks: Array = [
		# bone_name, expected stiffness component on the primary axis,
		# expected damping component on the primary axis, axis index
		# (0=X/flex, 1=Y/medial, 2=Z/abd).
		[&"LeftUpperArm",        1.5, 3.0, 0],   # BALL shoulder, default ball
		[&"LeftUpperLeg",        2.0, 3.5, 0],   # BALL hip, refined
		[&"LeftLowerArm",        1.0, 2.5, 0],   # HINGE elbow
		[&"LeftLowerLeg",        1.0, 2.5, 0],   # HINGE knee
		[&"LeftHand",            1.2, 2.8, 0],   # SADDLE wrist refined
		[&"LeftFoot",            1.2, 2.8, 0],   # SADDLE ankle refined
		[&"LeftBigToeDistal",    0.5, 2.0, 0],   # HINGE toe — user numbers
		[&"LeftBigToeProximal",  0.5, 2.0, 0],   # SADDLE toe MTP
		[&"LeftIndexDistal",     0.4, 1.8, 0],   # HINGE finger
		[&"LeftIndexProximal",   0.4, 1.8, 0],   # SADDLE finger MCP
		[&"Spine",               1.5, 3.0, 0],   # SPINE_SEGMENT
		[&"LeftShoulder",        0.8, 2.5, 0],   # CLAVICLE
	]
	for check in checks:
		var bone_name: StringName = check[0]
		var expected_k: float = check[1]
		var expected_c: float = check[2]
		var axis: int = check[3]
		if not marionette.bone_profile.bones.has(bone_name):
			push_error("Missing bone in calibrated profile: %s" % bone_name)
			failures += 1
			continue
		var entry: BoneEntry = marionette.bone_profile.bones[bone_name]
		var actual_k: float = entry.spring_stiffness[axis]
		var actual_c: float = entry.spring_damping[axis]
		if not is_equal_approx(actual_k, expected_k):
			push_error("%s: expected stiffness[%d]=%.2f, got %.2f"
					% [bone_name, axis, expected_k, actual_k])
			failures += 1
		if not is_equal_approx(actual_c, expected_c):
			push_error("%s: expected damping[%d]=%.2f, got %.2f"
					% [bone_name, axis, expected_c, actual_c])
			failures += 1
		print("  %-22s archetype=%-8s k=%s c=%s" % [
				bone_name, BoneArchetype.to_name(entry.archetype),
				entry.spring_stiffness, entry.spring_damping])

	# Tune two bones to nonsense values, re-Calibrate, verify survival.
	print()
	print("Tuning LeftLowerArm.stiffness.x = 7.7 and LeftFoot.damping = (0,0,9.9), then re-Calibrate ...")
	var elbow: BoneEntry = marionette.bone_profile.bones[&"LeftLowerArm"]
	elbow.spring_stiffness = Vector3(7.7, 0.0, 0.0)
	var foot: BoneEntry = marionette.bone_profile.bones[&"LeftFoot"]
	foot.spring_damping = Vector3(0.0, 0.0, 9.9)

	marionette.calibrate_bone_profile_from_skeleton()

	var elbow_after: BoneEntry = marionette.bone_profile.bones[&"LeftLowerArm"]
	if not is_equal_approx(elbow_after.spring_stiffness.x, 7.7):
		push_error("Re-Calibrate clobbered LeftLowerArm.stiffness.x: expected 7.7, got %.2f"
				% elbow_after.spring_stiffness.x)
		failures += 1
	# Y/Z were 0 before tuning, should get default (0 for HINGE on those axes).
	if not is_equal_approx(elbow_after.spring_stiffness.y, 0.0):
		push_error("Re-Calibrate didn't preserve elbow Y zero: %s" % elbow_after.spring_stiffness)
		failures += 1

	var foot_after: BoneEntry = marionette.bone_profile.bones[&"LeftFoot"]
	if not is_equal_approx(foot_after.spring_damping.z, 9.9):
		push_error("Re-Calibrate clobbered LeftFoot.damping.z: expected 9.9, got %.2f"
				% foot_after.spring_damping.z)
		failures += 1
	# X was 0 before tuning, should get FOOT default (2.8).
	if not is_equal_approx(foot_after.spring_damping.x, 2.8):
		push_error("Re-Calibrate didn't seed LeftFoot.damping.x default: expected 2.8, got %.2f"
				% foot_after.spring_damping.x)
		failures += 1

	print("After re-Calibrate:")
	print("  LeftLowerArm  k=%s c=%s" % [elbow_after.spring_stiffness, elbow_after.spring_damping])
	print("  LeftFoot      k=%s c=%s" % [foot_after.spring_stiffness, foot_after.spring_damping])

	if failures > 0:
		push_error("%d failure(s)" % failures)
		quit(1)
	else:
		print()
		print("PASS")
		quit(0)


func _find_marionette(node: Node) -> Marionette:
	if node is Marionette:
		return node
	for c: Node in node.get_children():
		var m: Marionette = _find_marionette(c)
		if m != null:
			return m
	return null
