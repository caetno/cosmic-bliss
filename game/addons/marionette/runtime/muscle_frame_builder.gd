@tool
class_name MuscleFrameBuilder
extends RefCounted

# P2.7 — Builds a MuscleFrame from a SkeletonProfile's reference poses.
# Authoring-time only; runtime reads the baked basis off BoneEntry.
#
# Algorithm:
#   1. Accumulate every bone's reference_pose into a world-rest transform
#      (parent-relative -> profile-space) by walking the bone list in
#      topological order. SkeletonProfile lists bones parent-first, so a
#      single forward pass suffices.
#   2. UP = direction from hip midpoint to Head bone position.
#   3. LEFT = direction from RightUpperLeg origin to LeftUpperLeg origin,
#      orthogonalized against UP.
#   4. FORWARD = UP × LEFT  (right-hand rule -> -Z when LEFT is +X and UP is +Y,
#      which matches Godot's mesh-facing convention).
#   5. RIGHT = -LEFT.
#
# We deliberately *don't* hardcode -Z as forward: the lateral axis comes from
# actual hip positions, so the muscle frame is consistent for any character
# whose left/right hip bones are correctly named, regardless of world rotation
# baked into the rest poses.

const _LEFT_HIP_BONE := &"LeftUpperLeg"
const _RIGHT_HIP_BONE := &"RightUpperLeg"
const _HEAD_BONE := &"Head"
const _HIPS_BONE := &"Hips"


# Returns world-space (== profile-space) accumulated rest transforms for
# every bone in the profile. Key: bone name. Value: cumulative Transform3D
# from profile origin to the bone's joint origin.
static func compute_world_rests(profile: SkeletonProfile) -> Dictionary[StringName, Transform3D]:
	var result: Dictionary[StringName, Transform3D] = {}
	var bone_count: int = profile.bone_size
	for i in range(bone_count):
		var bone_name: StringName = profile.get_bone_name(i)
		var local: Transform3D = profile.get_reference_pose(i)
		var parent_name: StringName = profile.get_bone_parent(i)
		if parent_name == &"" or not result.has(parent_name):
			result[bone_name] = local
		else:
			result[bone_name] = result[parent_name] * local
	return result


# Returns the midpoint between LeftUpperLeg and RightUpperLeg world origins,
# falling back to Hips (or origin) if either is missing.
static func hip_midpoint(profile: SkeletonProfile, world_rests: Dictionary[StringName, Transform3D] = {}) -> Vector3:
	var rests: Dictionary[StringName, Transform3D] = world_rests
	if rests.is_empty():
		rests = compute_world_rests(profile)
	var has_left: bool = rests.has(_LEFT_HIP_BONE)
	var has_right: bool = rests.has(_RIGHT_HIP_BONE)
	if has_left and has_right:
		return (rests[_LEFT_HIP_BONE].origin + rests[_RIGHT_HIP_BONE].origin) * 0.5
	if rests.has(_HIPS_BONE):
		return rests[_HIPS_BONE].origin
	return Vector3.ZERO


static func build(profile: SkeletonProfile) -> MuscleFrame:
	if profile == null or profile.bone_size == 0:
		return MuscleFrame.new()
	var world_rests: Dictionary[StringName, Transform3D] = compute_world_rests(profile)
	return _build_from_rests(world_rests)


# Live-skeleton variant: walks the live Skeleton3D using the BoneMap to
# resolve template bone names -> rig bone names, then runs the same muscle-
# frame derivation on those positions. Returns IDENTITY if any required bone
# (LeftUpperLeg, RightUpperLeg, Head) is missing from the live rig.
#
# Returned vectors are in the SKELETON's local frame (the same frame the
# Skeleton3D's get_bone_global_pose returns). Caller is responsible for
# transforming into whatever frame they ultimately draw in.
static func build_from_skeleton(
		skeleton: Skeleton3D,
		profile: SkeletonProfile,
		bone_map: BoneMap) -> MuscleFrame:
	if skeleton == null or profile == null or bone_map == null:
		return MuscleFrame.new()
	var world_rests: Dictionary[StringName, Transform3D] = compute_skeleton_world_rests(skeleton, profile, bone_map)
	return _build_from_rests(world_rests)


# Internal: shared muscle-frame computation given a dictionary of accumulated
# rest transforms keyed by canonical SkeletonProfile bone name.
static func _build_from_rests(world_rests: Dictionary[StringName, Transform3D]) -> MuscleFrame:
	var frame := MuscleFrame.new()
	if not world_rests.has(_LEFT_HIP_BONE) or not world_rests.has(_RIGHT_HIP_BONE):
		return frame

	var hip_left: Vector3 = world_rests[_LEFT_HIP_BONE].origin
	var hip_right: Vector3 = world_rests[_RIGHT_HIP_BONE].origin
	var hip_mid: Vector3 = (hip_left + hip_right) * 0.5
	var head_pos: Vector3 = world_rests.get(_HEAD_BONE, Transform3D(Basis.IDENTITY, hip_mid + Vector3.UP)).origin

	var up: Vector3 = head_pos - hip_mid
	if up.length_squared() < 1e-8:
		up = Vector3.UP
	up = up.normalized()

	var left: Vector3 = hip_left - hip_right
	if left.length_squared() < 1e-8:
		left = Vector3.LEFT
	left = (left - up * left.dot(up))
	if left.length_squared() < 1e-8:
		left = Vector3.RIGHT - up * Vector3.RIGHT.dot(up)
	left = left.normalized()

	# Right-hand rule: UP × LEFT yields a vector perpendicular to both.
	# Whether the result points toward the character's anatomical front or
	# back depends on the rig's orientation: the convention only fixes that
	# (right, up, forward) is a consistent right-handed triple. The gizmo
	# drawing code labels this vector "forward"; if your character ends up
	# facing the opposite direction it's because their rig has a different
	# facing convention than the SkeletonProfileHumanoid template.
	var forward: Vector3 = up.cross(left).normalized()

	frame.up = up
	frame.right = -left
	frame.forward = forward
	return frame


# Returns accumulated rest transforms for every SkeletonProfile bone that has
# a mapping in `bone_map` *and* exists in `skeleton`. Result is keyed by the
# canonical SkeletonProfile bone name (so downstream code is bone-map-blind).
# Transforms are in skeleton-local space (Skeleton3D's reference frame).
static func compute_skeleton_world_rests(
		skeleton: Skeleton3D,
		profile: SkeletonProfile,
		bone_map: BoneMap) -> Dictionary[StringName, Transform3D]:
	var result: Dictionary[StringName, Transform3D] = {}
	if skeleton == null or profile == null or bone_map == null:
		return result
	# First, build a per-skeleton-bone-index global rest. Skeleton3D lists
	# bones parent-first, so a single forward pass works.
	var bone_count: int = skeleton.get_bone_count()
	var skeleton_global: Array[Transform3D] = []
	skeleton_global.resize(bone_count)
	for i in range(bone_count):
		var local: Transform3D = skeleton.get_bone_rest(i)
		var parent: int = skeleton.get_bone_parent(i)
		if parent < 0:
			skeleton_global[i] = local
		else:
			skeleton_global[i] = skeleton_global[parent] * local

	# Resolve each skeleton bone to a profile bone via reverse lookup:
	#   1. Ask BoneMap for the profile name that corresponds to this rig bone.
	#      Using `find_profile_bone_name` rather than `get_skeleton_bone_name`
	#      avoids the C++ error spam when the bone_map doesn't have a key for
	#      every profile bone.
	#   2. If unmapped, fall back to direct match — the post-retarget workflow
	#      renames source bones to canonical SkeletonProfile names, leaving
	#      the BoneMap's pre-retarget mappings stale but the skeleton itself
	#      self-describing.
	# Build the profile-bone-name set once for the fallback check.
	var profile_names: Dictionary[StringName, bool] = {}
	for i in range(profile.bone_size):
		profile_names[profile.get_bone_name(i)] = true
	for i in range(bone_count):
		var skel_name: StringName = skeleton.get_bone_name(i)
		var profile_name: StringName = bone_map.find_profile_bone_name(skel_name)
		if profile_name == &"":
			if profile_names.has(skel_name):
				profile_name = skel_name
			else:
				continue
		result[profile_name] = skeleton_global[i]
	return result


# Live-pose variant of compute_skeleton_world_rests: returns each profile
# bone's *current* skeleton-local transform via get_bone_global_pose, so
# gizmos that read this follow the armature when sliders / animation move
# bones. Same name-resolution rules (BoneMap then direct match).
static func compute_skeleton_global_poses(
		skeleton: Skeleton3D,
		profile: SkeletonProfile,
		bone_map: BoneMap) -> Dictionary[StringName, Transform3D]:
	var result: Dictionary[StringName, Transform3D] = {}
	if skeleton == null or profile == null or bone_map == null:
		return result
	var profile_names: Dictionary[StringName, bool] = {}
	for i in range(profile.bone_size):
		profile_names[profile.get_bone_name(i)] = true
	var bone_count: int = skeleton.get_bone_count()
	for i in range(bone_count):
		var skel_name: StringName = skeleton.get_bone_name(i)
		var profile_name: StringName = bone_map.find_profile_bone_name(skel_name)
		if profile_name == &"":
			if profile_names.has(skel_name):
				profile_name = skel_name
			else:
				continue
		result[profile_name] = skeleton.get_bone_global_pose(i)
	return result
