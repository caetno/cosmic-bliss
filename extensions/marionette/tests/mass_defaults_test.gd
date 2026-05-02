extends SceneTree

# Verifies BoneProfileGenerator.calibrate seeds anatomical mass_fractions
# (so build_ragdoll lands the right per-bone masses instead of every bone
# defaulting to total_mass/N ≈ 0.9 kg) and that user-tuned values survive
# re-Calibrate.
#
# Run:
#   godot --headless --path /home/caetano/desktop/cosmic-bliss/game \
#     --script /home/caetano/desktop/cosmic-bliss/extensions/marionette/tests/mass_defaults_test.gd

const KASUMI_SCENE: String = "res://tests/marionette/kasumi/kasumi.tscn"


func _init() -> void:
	print("==== Marionette mass-defaults seed + spawn test ====")
	var packed: PackedScene = load(KASUMI_SCENE)
	var inst: Node = packed.instantiate()
	root.add_child(inst)
	await process_frame

	var marionette: Marionette = _find_marionette(inst)
	if marionette == null:
		push_error("No Marionette in kasumi")
		quit(1)
		return

	# Reset and calibrate fresh.
	marionette.bone_profile.bones = {}
	marionette.calibrate_bone_profile_from_skeleton()

	var failures: int = 0

	# Spot-check mass_fraction values on a handful of representative bones.
	var fraction_checks: Array = [
		[&"Hips",            0.124],
		[&"UpperChest",      0.180],
		[&"Head",            0.069],
		[&"LeftUpperLeg",    0.100],
		[&"LeftLowerLeg",    0.046],
		[&"LeftUpperArm",    0.027],
		[&"LeftLowerArm",    0.016],
		[&"LeftHand",        0.004],
		[&"LeftShoulder",    0.005],
		[&"LeftFoot",        0.012],
		[&"LeftIndexProximal", 0.0008],
		[&"LeftIndexDistal",   0.0003],
		[&"LeftBigToeProximal", 0.0008],
		[&"LeftToe5Distal",     0.0002],
	]
	for spec in fraction_checks:
		var bone_name: StringName = spec[0]
		var expected: float = spec[1]
		var entry: BoneEntry = marionette.bone_profile.bones.get(bone_name)
		if entry == null:
			push_error("Missing bone: %s" % bone_name)
			failures += 1
			continue
		if not is_equal_approx(entry.mass_fraction, expected):
			push_error("%s mass_fraction expected %.4f, got %.4f"
					% [bone_name, expected, entry.mass_fraction])
			failures += 1

	# Sum across all entries should land near 1.0 (within a few percent;
	# kasumi has a few extra bones that get the _UNKNOWN fallback).
	var total: float = 0.0
	for bone_name: StringName in marionette.bone_profile.bones.keys():
		total += marionette.bone_profile.bones[bone_name].mass_fraction
	print("Total mass_fraction sum across %d bones: %.3f" % [
			marionette.bone_profile.bones.size(), total])
	if total < 0.85 or total > 1.15:
		push_error("mass_fraction sum %.3f out of [0.85, 1.15] band — table needs rebalancing"
				% total)
		failures += 1

	# Build the ragdoll and verify per-bone masses land. UpperLeg should be
	# ~7 kg (70 × 0.10), Index distal ~21 g (70 × 0.0003).
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

	var spawn_checks: Array = [
		# bone, expected_kg (with total_mass = 70)
		[&"Hips",            70.0 * 0.124],
		[&"UpperChest",      70.0 * 0.180],
		[&"LeftUpperLeg",    70.0 * 0.100],
		[&"LeftLowerArm",    70.0 * 0.016],
		[&"LeftIndexProximal", 70.0 * 0.0008],
		[&"LeftToe5Distal",  70.0 * 0.0002],
	]
	for spec in spawn_checks:
		var bone_name: StringName = spec[0]
		var expected_kg: float = spec[1]
		var b: MarionetteBone = bones_by_name.get(bone_name)
		if b == null:
			push_error("Bone not in simulator: %s" % bone_name)
			failures += 1
			continue
		if not is_equal_approx(b.mass, expected_kg):
			push_error("%s mass: expected %.3f kg, got %.3f kg"
					% [bone_name, expected_kg, b.mass])
			failures += 1
		else:
			print("  %-22s mass=%.3f kg (expected %.3f)" % [bone_name, b.mass, expected_kg])

	# Tune one bone, re-Calibrate, verify survival.
	print()
	print("Tuning Hips.mass_fraction = 0.300, then re-Calibrate ...")
	marionette.bone_profile.bones[&"Hips"].mass_fraction = 0.300
	marionette.calibrate_bone_profile_from_skeleton()
	var hips_after: float = marionette.bone_profile.bones[&"Hips"].mass_fraction
	if not is_equal_approx(hips_after, 0.300):
		push_error("Re-Calibrate clobbered Hips.mass_fraction: expected 0.300, got %.4f"
				% hips_after)
		failures += 1
	# Other bones should still be at defaults.
	var head_after: float = marionette.bone_profile.bones[&"Head"].mass_fraction
	if not is_equal_approx(head_after, 0.069):
		push_error("Re-Calibrate dropped Head default: expected 0.069, got %.4f" % head_after)
		failures += 1
	print("  Hips after tune+re-Calibrate: %.4f (preserved)" % hips_after)
	print("  Head after tune+re-Calibrate: %.4f (default seeded)" % head_after)

	# Re-Calibrate's refresh path must also push the new mass onto live
	# MarionetteBones (without needing a full Build Ragdoll). The Hips
	# bone in the simulator should now weigh 70 × 0.300 = 21 kg.
	var hips_bone: MarionetteBone = bones_by_name.get(&"Hips")
	if hips_bone == null:
		push_error("Hips not in simulator after re-Calibrate")
		failures += 1
	else:
		var expected_kg: float = 70.0 * 0.300
		if not is_equal_approx(hips_bone.mass, expected_kg):
			push_error("Hips mass not refreshed after re-Calibrate: expected %.2f kg, got %.2f kg"
					% [expected_kg, hips_bone.mass])
			failures += 1
		else:
			print("  Hips live MarionetteBone mass refreshed: %.3f kg" % hips_bone.mass)

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
