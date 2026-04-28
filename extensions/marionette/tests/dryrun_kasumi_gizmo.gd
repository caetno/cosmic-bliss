extends SceneTree

# Headless equivalent of the authoring gizmo's per-bone solver+matcher loop,
# run against the Kasumi test scene. Reports a sorted list of match scores so
# we can see — without opening the editor — which bones are matching and
# which are flagged.
#
# Run: cd game && godot --headless --script /abs/path/to/dryrun_kasumi_gizmo.gd

const KASUMI_SCENE_PATH := "res://tests/marionette/kasumi/kasumi.tscn"
const PROFILE_PATH := "res://addons/marionette/data/marionette_humanoid_profile.tres"
const BONE_PROFILE_PATH := "res://addons/marionette/data/marionette_humanoid_bone_profile.tres"
const BONE_MAP_PATH := "res://addons/marionette/data/marionette_humanoid_bone_map.tres"


func _init() -> void:
	var packed: PackedScene = load(KASUMI_SCENE_PATH)
	if packed == null:
		push_error("could not load %s" % KASUMI_SCENE_PATH)
		quit(1)
		return
	var root: Node = packed.instantiate()
	if root == null:
		push_error("could not instantiate %s" % KASUMI_SCENE_PATH)
		quit(1)
		return

	var marionette: Node3D = _find_marionette(root)
	if marionette == null:
		push_error("could not find Marionette node in scene")
		quit(1)
		return

	# Resolve dependencies the gizmo would resolve.
	var skeleton: Skeleton3D = _find_skeleton(root)
	var bone_profile: BoneProfile = load(BONE_PROFILE_PATH) as BoneProfile
	var bone_map: BoneMap = load(BONE_MAP_PATH) as BoneMap
	if skeleton == null or bone_profile == null or bone_profile.skeleton_profile == null or bone_map == null:
		push_error("dependency resolution failed — skeleton=%s bone_profile=%s bone_map=%s"
				% [skeleton, bone_profile, bone_map])
		quit(1)
		return

	var profile: SkeletonProfile = bone_profile.skeleton_profile
	print("skeleton bone count: ", skeleton.get_bone_count())
	print("profile bone count:  ", profile.bone_size)
	print("matcher candidates:  ", MarionettePermutationMatcher.candidate_count())

	var world_rests: Dictionary[StringName, Transform3D] = MuscleFrameBuilder.compute_skeleton_world_rests(
			skeleton, profile, bone_map)
	var muscle_frame: MuscleFrame = MuscleFrameBuilder.build_from_skeleton(skeleton, profile, bone_map)
	print("world_rests resolved: ", world_rests.size())
	print("muscle_frame: right=%v up=%v forward=%v" % [muscle_frame.right, muscle_frame.up, muscle_frame.forward])

	var first_child: Dictionary[StringName, StringName] = {}
	for i in range(profile.bone_size):
		var pn: StringName = profile.get_bone_parent(i)
		if pn != &"" and not first_child.has(pn):
			first_child[pn] = profile.get_bone_name(i)

	var rows: Array = []
	for i in range(profile.bone_size):
		var bone_name: StringName = profile.get_bone_name(i)
		var archetype: int = MarionetteArchetypeDefaults.archetype_for_bone(bone_name)
		if archetype < 0:
			continue
		if archetype == BoneArchetype.Type.ROOT or archetype == BoneArchetype.Type.FIXED:
			continue
		if not world_rests.has(bone_name):
			continue
		var bone_world: Transform3D = world_rests[bone_name]

		var child_world: Transform3D = bone_world
		var explicit_tail: StringName = profile.get_bone_tail(i)
		if explicit_tail != &"" and world_rests.has(explicit_tail):
			child_world = world_rests[explicit_tail]
		elif first_child.has(bone_name) and world_rests.has(first_child[bone_name]):
			child_world = world_rests[first_child[bone_name]]
		else:
			var nudge: Vector3 = bone_world.basis.y.normalized() * 0.02
			if nudge == Vector3.ZERO:
				nudge = Vector3(0.0, 0.02, 0.0)
			child_world.origin = bone_world.origin + nudge

		var is_left_side: bool = String(bone_name).begins_with("Left")
		var target_basis: Basis = MarionetteArchetypeSolverDispatch.solve(
				archetype, bone_world, child_world, muscle_frame, is_left_side)
		var match_result: MarionettePermutationMatch = MarionettePermutationMatcher.find_match(
				bone_world.basis, target_basis)

		rows.append([match_result.score, match_result.matched, String(bone_name), String(BoneArchetype.to_name(archetype))])

	rows.sort_custom(func(a, b): return a[0] > b[0])

	var matched_count: int = 0
	var unmatched_count: int = 0
	for r in rows:
		if r[1]:
			matched_count += 1
		else:
			unmatched_count += 1

	print("\n--- per-bone scores (sorted descending) ---")
	for r in rows:
		var marker := "PASS" if r[1] else "FAIL"
		print("  %s  %.3f  %-22s  (%s)" % [marker, r[0], r[2], r[3]])

	print("\nsummary: %d matched, %d unmatched (threshold = %.2f)" % [
		matched_count, unmatched_count, MarionettePermutationMatcher.DEFAULT_MATCH_THRESHOLD])

	root.queue_free()
	quit(0)


func _find_marionette(node: Node) -> Marionette:
	if node is Marionette:
		return node
	for child in node.get_children():
		var found: Marionette = _find_marionette(child)
		if found != null:
			return found
	return null


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found: Skeleton3D = _find_skeleton(child)
		if found != null:
			return found
	return null
