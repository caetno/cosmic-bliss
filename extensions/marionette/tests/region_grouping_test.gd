extends SceneTree

# Slice-7 verification: MarionetteRegionGrouping.derive() produces the
# expected regions for a calibrated kasumi BoneProfile + a small
# JiggleProfile with breast entries. Validates the static name-pattern
# predicates and the soft-region side-suffix collapse.
#
# Run:
#   godot --headless --path /home/caetano/desktop/cosmic-bliss/game \
#     --script /home/caetano/desktop/cosmic-bliss/extensions/marionette/tests/region_grouping_test.gd

const KASUMI_SCENE: String = "res://tests/marionette/kasumi/kasumi.tscn"


func _init() -> void:
	print("==== Marionette region grouping test ====")
	var packed: PackedScene = load(KASUMI_SCENE)
	var inst: Node = packed.instantiate()
	root.add_child(inst)
	await process_frame

	var marionette: Marionette = _find_marionette(inst)
	if marionette == null:
		push_error("No Marionette in kasumi")
		quit(1)
		return

	# Calibrate so the profile has all kasumi's bones populated.
	marionette.bone_profile.bones = {}
	marionette.calibrate_bone_profile_from_skeleton()

	# Build a small JiggleProfile: breast_01 + breast_02 + a simulated
	# glute_01 (bones don't exist in kasumi's rig but the entry suffices
	# to exercise the grouping).
	var jp := JiggleProfile.new()
	jp.entries[&"c_breast_01.l"] = JiggleEntry.new()
	jp.entries[&"c_breast_01.r"] = JiggleEntry.new()
	jp.entries[&"c_breast_02.l"] = JiggleEntry.new()
	jp.entries[&"c_breast_02.r"] = JiggleEntry.new()
	jp.entries[&"c_glute_01.l"] = JiggleEntry.new()
	jp.entries[&"c_glute_01.r"] = JiggleEntry.new()

	var regions := MarionetteRegionGrouping.derive(marionette.bone_profile, jp)

	var failures: int = 0
	# Convert to (name, count) for table-driven assertions.
	var counts: Dictionary[StringName, int] = {}
	var kinds: Dictionary[StringName, int] = {}
	for r: MarionetteRegionGrouping.Region in regions:
		counts[r.name] = r.bones.size()
		kinds[r.name] = r.kind
		print("  %-14s kind=%s n=%d  bones=%s" % [
				r.name,
				"HARD" if r.kind == MarionetteRegionGrouping.Region.Kind.HARD else "SOFT",
				r.bones.size(),
				r.bones])

	# Hard-region expectations against kasumi's 78-bone calibrated profile.
	# The kasumi rig has no LeftToes/RightToes aggregate bones (per
	# arp_mapping.md), so the "toes" region is just phalanges (28 bones).
	var hard_expected: Array = [
		[&"head",        1, MarionetteRegionGrouping.Region.Kind.HARD],
		[&"neck",        1, MarionetteRegionGrouping.Region.Kind.HARD],
		[&"spine",       3, MarionetteRegionGrouping.Region.Kind.HARD],   # Spine + Chest + UpperChest
		[&"shoulders",   2, MarionetteRegionGrouping.Region.Kind.HARD],
		[&"upper_arms",  2, MarionetteRegionGrouping.Region.Kind.HARD],
		[&"lower_arms",  2, MarionetteRegionGrouping.Region.Kind.HARD],
		[&"hands",       2, MarionetteRegionGrouping.Region.Kind.HARD],
		[&"fingers",     30, MarionetteRegionGrouping.Region.Kind.HARD],  # 15 per hand
		[&"hips",        1, MarionetteRegionGrouping.Region.Kind.HARD],
		[&"upper_legs",  2, MarionetteRegionGrouping.Region.Kind.HARD],
		[&"lower_legs",  2, MarionetteRegionGrouping.Region.Kind.HARD],
		[&"feet",        2, MarionetteRegionGrouping.Region.Kind.HARD],
		[&"toes",        28, MarionetteRegionGrouping.Region.Kind.HARD], # 14 per foot, no aggregate Toes bone in kasumi
	]
	for spec in hard_expected:
		var rname: StringName = spec[0]
		var expected_n: int = spec[1]
		var expected_kind: int = spec[2]
		if not counts.has(rname):
			push_error("Missing region: %s" % rname)
			failures += 1
			continue
		if counts[rname] != expected_n:
			push_error("%s expected %d bones, got %d" % [rname, expected_n, counts[rname]])
			failures += 1
		if kinds[rname] != expected_kind:
			push_error("%s expected kind=%d, got %d" % [rname, expected_kind, kinds[rname]])
			failures += 1

	# Soft regions: c_breast_01 (.l + .r), c_breast_02 (.l + .r),
	# c_glute_01 (.l + .r). Side suffix stripped.
	var soft_expected: Array = [
		[&"c_breast_01", 2, MarionetteRegionGrouping.Region.Kind.SOFT],
		[&"c_breast_02", 2, MarionetteRegionGrouping.Region.Kind.SOFT],
		[&"c_glute_01",  2, MarionetteRegionGrouping.Region.Kind.SOFT],
	]
	for spec in soft_expected:
		var rname: StringName = spec[0]
		var expected_n: int = spec[1]
		var expected_kind: int = spec[2]
		if not counts.has(rname):
			push_error("Missing soft region: %s" % rname)
			failures += 1
			continue
		if counts[rname] != expected_n:
			push_error("%s expected %d bones, got %d" % [rname, expected_n, counts[rname]])
			failures += 1
		if kinds[rname] != expected_kind:
			push_error("%s expected kind=SOFT, got %d" % [rname, kinds[rname]])
			failures += 1

	# Sanity: every kasumi bone in the profile is claimed by *some* hard
	# region (no holes). 78 bones distributed across hard regions:
	var hard_total: int = 0
	for r: MarionetteRegionGrouping.Region in regions:
		if r.kind == MarionetteRegionGrouping.Region.Kind.HARD:
			hard_total += r.bones.size()
	var profile_count: int = marionette.bone_profile.bones.size()
	if hard_total != profile_count:
		push_error("Hard regions claim %d bones, profile has %d (some bone falls through)"
				% [hard_total, profile_count])
		failures += 1

	if failures > 0:
		push_error("%d failure(s)" % failures)
		quit(1)
	else:
		print()
		print("PASS  (%d hard bones across %d hard regions, %d soft regions)"
				% [hard_total, hard_expected.size(), soft_expected.size()])
		quit(0)


func _find_marionette(node: Node) -> Marionette:
	if node is Marionette:
		return node
	for c: Node in node.get_children():
		var m: Marionette = _find_marionette(c)
		if m != null:
			return m
	return null
