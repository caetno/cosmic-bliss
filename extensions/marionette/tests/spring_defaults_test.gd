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

	# Slice 3: build the ragdoll and verify spring/limit values landed on
	# the spawned MarionetteBones via Jolt's joint_constraints/* property
	# paths.
	print()
	print("Building ragdoll to verify _apply_joint_constraints writes ...")
	marionette.build_ragdoll()
	var sim: PhysicalBoneSimulator3D = null
	var skel: Skeleton3D = marionette.resolve_skeleton()
	for c: Node in skel.get_children():
		if c is PhysicalBoneSimulator3D:
			sim = c
			break
	if sim == null:
		push_error("Marionette didn't build a simulator")
		quit(1)
		return
	var bones_by_name: Dictionary[StringName, MarionetteBone] = {}
	for c: Node in sim.get_children():
		if c is MarionetteBone and not (c is JiggleBone):
			bones_by_name[StringName((c as MarionetteBone).bone_name)] = c

	# Spring readbacks: flex axis carries the user-tuned value; locked axes
	# get spring_enabled = false.
	var spring_checks: Array = [
		# bone, axis, expected_k, expected_c, expected_enabled
		[&"LeftBigToeDistal",   "x", 0.5, 2.0, true],
		[&"LeftBigToeDistal",   "y", 0.0, 0.0, false],
		[&"LeftBigToeDistal",   "z", 0.0, 0.0, false],
		[&"LeftFoot",           "x", 1.2, 2.8, true],
		[&"LeftFoot",           "y", 0.0, 0.0, false],
		# LeftFoot.z damping = 9.9 was carried over from the earlier
		# tune+re-Calibrate step; the build_ragdoll path should land it.
		[&"LeftFoot",           "z", 1.2, 9.9, true],
		[&"LeftUpperArm",       "y", 1.5, 3.0, true],   # BALL — all 3 axes
		[&"LeftLowerArm",       "x", 7.7, 2.5, true],   # carried over from earlier tuning
	]
	for check in spring_checks:
		var bn: StringName = check[0]
		var ax: String = check[1]
		var ek: float = check[2]
		var ec: float = check[3]
		var ee: bool = check[4]
		var b: MarionetteBone = bones_by_name.get(bn)
		if b == null:
			push_error("Bone not in simulator: %s" % bn)
			failures += 1
			continue
		var got_e: bool = b.get("joint_constraints/%s/angular_spring_enabled" % ax)
		var got_k: float = b.get("joint_constraints/%s/angular_spring_stiffness" % ax)
		var got_c: float = b.get("joint_constraints/%s/angular_spring_damping" % ax)
		if got_e != ee:
			push_error("%s.%s spring_enabled: expected %s, got %s" % [bn, ax, ee, got_e])
			failures += 1
		if ee:  # only check k/c when the spring is on; disabled axes leave the fields untouched
			if not is_equal_approx(got_k, ek):
				push_error("%s.%s stiffness: expected %.2f, got %.2f" % [bn, ax, ek, got_k])
				failures += 1
			if not is_equal_approx(got_c, ec):
				push_error("%s.%s damping: expected %.2f, got %.2f" % [bn, ax, ec, got_c])
				failures += 1

	# Unit sanity: write goes through rad_to_deg. ROM stored in BoneEntry is
	# radians; readback should be degrees. Pick a bone with a clearly
	# asymmetric authored ROM where the difference between rad and deg is
	# unambiguous. LeftFoot (SADDLE ankle): authored x ROM is roughly
	# (-15°, +40°) ≈ (-0.26 rad, +0.70 rad). Readback should be ~ -15 / +40
	# in degrees, not -0.26 / +0.70 in radians (and not the X-flip negated
	# variant — that flip is HINGE-only).
	var foot_bone: MarionetteBone = bones_by_name.get(&"LeftFoot")
	if foot_bone != null:
		var lo_x: float = foot_bone.get("joint_constraints/x/angular_limit_lower")
		var up_x: float = foot_bone.get("joint_constraints/x/angular_limit_upper")
		# Tolerance loose because rest_anatomical_offset shifts the bounds a
		# few degrees. Magnitudes still > 5 — radians would be < 1 here.
		if abs(lo_x) < 5.0 and abs(up_x) < 5.0:
			push_error("LeftFoot.x angular limits look like radians (got %.3f / %.3f); rad_to_deg conversion missing"
					% [lo_x, up_x])
			failures += 1
		print("  LeftFoot.x angular limit (deg): [%.1f, %.1f]" % [lo_x, up_x])

	# HINGE X-flip sanity: an elbow's authored flex range is roughly
	# (0°, 140°). After rest_anatomical_offset (~20° carrying angle) and
	# the HINGE swap-and-negate, readback lands somewhere like (-120°, 20°)
	# — large-magnitude lower, small-magnitude upper. Without the flip the
	# readback would be mirrored: (-20°, 120°). The signature of "the flip
	# happened" is the negative-leaning center: (lo + up) < 0.
	var elbow_bone: MarionetteBone = bones_by_name.get(&"LeftLowerArm")
	if elbow_bone != null:
		var lo_x: float = elbow_bone.get("joint_constraints/x/angular_limit_lower")
		var up_x: float = elbow_bone.get("joint_constraints/x/angular_limit_upper")
		if (lo_x + up_x) >= 0.0:
			push_error("LeftLowerArm.x angular limits don't look HINGE-flipped: [%.1f, %.1f] center=%.1f"
					% [lo_x, up_x, (lo_x + up_x) * 0.5])
			failures += 1
		# Magnitudes must be in degrees (rom in radians is < π ≈ 3.14).
		if abs(lo_x) < 5.0 or abs(up_x) < 5.0:
			# Hmm, upper might be small by design (post-flip max ~20°).
			# Only flag if BOTH are radian-magnitude.
			if abs(lo_x) < 5.0 and abs(up_x) < 5.0:
				push_error("LeftLowerArm.x angular limits look like radians: [%.3f, %.3f]"
						% [lo_x, up_x])
				failures += 1
		print("  LeftLowerArm.x angular limit (deg, post-HINGE-flip): [%.1f, %.1f]" % [lo_x, up_x])

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
