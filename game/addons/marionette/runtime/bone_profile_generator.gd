class_name BoneProfileGenerator
extends RefCounted

# P2.10 — fills a BoneProfile by running the authoring-time pipeline:
#   muscle frame -> archetype lookup -> per-archetype solver
#   -> permutation matcher -> clinical ROM defaults.
#
# Pure data path; the inspector button (`MarionetteBoneProfileInspector`)
# wraps this with a press handler. CLI tests call `generate()` directly.
#
# Existing entries in the BoneProfile are replaced — regeneration is
# idempotent. Bones not in `MarionetteArchetypeDefaults` (or absent from the
# data source's world rests) are left absent from the dict so the user can
# hand-author them; they show up in `report.skipped_bones`.
#
# By default the SkeletonProfile's reference poses drive the muscle frame and
# rest bases (the path the inspector button takes — the shipped default
# BoneProfile is template-derived). Pass a live `Skeleton3D` + `BoneMap` to
# calibrate against a specific rig instead; the matcher then sees that rig's
# rest bases including any per-bone roll baked at modeling time.

const _CHILD_NUDGE: float = 0.02


# Result of a generate() pass. Reported back so the inspector button can
# print a one-line summary and the test harness can spot-check counts.
class GenerateReport extends RefCounted:
	var generated: int = 0
	var matched: int = 0
	var unmatched: int = 0
	var skipped: int = 0
	var unmatched_bones: Array[StringName] = []
	var skipped_bones: Array[StringName] = []
	var error: String = ""


static func generate(
		bone_profile: BoneProfile,
		live_skeleton: Skeleton3D = null,
		bone_map: BoneMap = null) -> GenerateReport:
	var report := GenerateReport.new()
	if bone_profile == null:
		report.error = "bone_profile is null"
		return report
	var profile: SkeletonProfile = bone_profile.skeleton_profile
	if profile == null:
		report.error = "bone_profile.skeleton_profile is null"
		return report
	if profile.bone_size == 0:
		report.error = "skeleton_profile has zero bones"
		return report

	var use_live: bool = live_skeleton != null and bone_map != null
	var world_rests: Dictionary[StringName, Transform3D]
	var muscle_frame: MuscleFrame
	if use_live:
		world_rests = MuscleFrameBuilder.compute_skeleton_world_rests(live_skeleton, profile, bone_map)
		muscle_frame = MuscleFrameBuilder.build_from_skeleton(live_skeleton, profile, bone_map)
	else:
		world_rests = MuscleFrameBuilder.compute_world_rests(profile)
		muscle_frame = MuscleFrameBuilder.build(profile)

	# parent-name -> first-listed-child-name lookup, for the child-hint each
	# solver needs when SkeletonProfile.get_bone_tail() isn't set.
	var first_child: Dictionary[StringName, StringName] = {}
	for i in range(profile.bone_size):
		var pn: StringName = profile.get_bone_parent(i)
		if pn != &"" and not first_child.has(pn):
			first_child[pn] = profile.get_bone_name(i)

	var entries: Dictionary[StringName, BoneEntry] = {}

	for i in range(profile.bone_size):
		var bone_name: StringName = profile.get_bone_name(i)
		var archetype: int = MarionetteArchetypeDefaults.archetype_for_bone(bone_name)
		if archetype < 0:
			report.skipped += 1
			report.skipped_bones.append(bone_name)
			continue
		if not world_rests.has(bone_name):
			report.skipped += 1
			report.skipped_bones.append(bone_name)
			continue

		var bone_world: Transform3D = world_rests[bone_name]
		var child_world: Transform3D = _resolve_child_world(profile, i, bone_world, world_rests, first_child)
		var is_left_side: bool = String(bone_name).begins_with("Left")

		var entry := BoneEntry.new()
		entry.archetype = archetype
		entry.is_left_side = is_left_side

		# ROOT and FIXED bones aren't SPD-driven; the matcher score is
		# meaningless for them. Leave permutation at BoneEntry defaults
		# (PLUS_X / PLUS_Y / PLUS_Z) — write_into() would only echo that anyway.
		if archetype != BoneArchetype.Type.ROOT and archetype != BoneArchetype.Type.FIXED:
			var target_basis: Basis = MarionetteArchetypeSolverDispatch.solve(
					archetype, bone_world, child_world, muscle_frame, is_left_side)
			var match_result: MarionettePermutationMatch = MarionettePermutationMatcher.find_match(
					bone_world.basis, target_basis)
			match_result.write_into(entry)
			if match_result.matched:
				report.matched += 1
			else:
				report.unmatched += 1
				report.unmatched_bones.append(bone_name)

		MarionetteRomDefaults.apply(entry, bone_name)

		entries[bone_name] = entry
		report.generated += 1

	bone_profile.bones = entries
	return report


# Resolve the bone's child world-rest transform: explicit tail bone first,
# then first listed child bone, then a small nudge along bone-local +Y so
# terminal bones still produce a non-degenerate hint.
static func _resolve_child_world(
		profile: SkeletonProfile,
		bone_index: int,
		bone_world: Transform3D,
		world_rests: Dictionary[StringName, Transform3D],
		first_child: Dictionary[StringName, StringName]) -> Transform3D:
	var explicit_tail: StringName = profile.get_bone_tail(bone_index)
	if explicit_tail != &"" and world_rests.has(explicit_tail):
		return world_rests[explicit_tail]
	var bone_name: StringName = profile.get_bone_name(bone_index)
	if first_child.has(bone_name) and world_rests.has(first_child[bone_name]):
		return world_rests[first_child[bone_name]]
	var nudge: Vector3 = bone_world.basis.y.normalized() * _CHILD_NUDGE
	if nudge == Vector3.ZERO:
		nudge = Vector3(0.0, _CHILD_NUDGE, 0.0)
	var fallback: Transform3D = bone_world
	fallback.origin = bone_world.origin + nudge
	return fallback
