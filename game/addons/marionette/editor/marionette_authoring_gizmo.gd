@tool
class_name MarionetteAuthoringGizmo
extends EditorNode3DGizmoPlugin

# Authoring-time gizmo for visually verifying P2.6 (archetype solvers) and
# P2.7 (muscle frame builder) on a Marionette node before the rest of Phase 2
# lands (no permutation matcher, no editor button, no shipped BoneProfile).
#
# Activates whenever a Marionette node is selected. Reads the SkeletonProfile
# off the assigned BoneProfile. Renders:
#
#   1. The muscle frame as a large RGB tripod at the hip midpoint.
#         red   = character right
#         green = up (toward head)
#         blue  = forward (mesh-facing)
#
#   2. A small RGB tripod at each bone's world-rest origin showing the per-
#      bone solver target (P2.6 output) in anatomical convention:
#         red   = flex axis     (anatomical +X)
#         green = along-bone    (anatomical +Y)
#         blue  = abduction     (anatomical +Z)
#
# All coordinates are in the Marionette node's local frame (the gizmo system
# applies the node's global transform). The SkeletonProfile reference poses
# accumulate in the same frame, so we draw points directly without any
# further conversion.

const _MUSCLE_FRAME_LENGTH: float = 0.4
const _BONE_FRAME_LENGTH: float = 0.08

const _MAT_MUSCLE_X: StringName = &"muscle_right"
const _MAT_MUSCLE_Y: StringName = &"muscle_up"
const _MAT_MUSCLE_Z: StringName = &"muscle_forward"
const _MAT_BONE_X: StringName = &"bone_flex"
const _MAT_BONE_Y: StringName = &"bone_along"
const _MAT_BONE_Z: StringName = &"bone_abduction"


func _init() -> void:
	# All materials are unshaded with depth test disabled (on_top=true) so the
	# tripods stay readable on top of Godot's default Skeleton3D bone gizmo.
	# Muscle-frame colors are pure-saturated; per-bone colors are tinted lighter
	# so the body-level frame stays the dominant cue.
	create_material(_MAT_MUSCLE_X, Color(1.0, 0.15, 0.15), false, true)
	create_material(_MAT_MUSCLE_Y, Color(0.15, 1.0, 0.15), false, true)
	create_material(_MAT_MUSCLE_Z, Color(0.2, 0.4, 1.0), false, true)
	create_material(_MAT_BONE_X, Color(1.0, 0.55, 0.55), false, true)
	create_material(_MAT_BONE_Y, Color(0.55, 1.0, 0.55), false, true)
	create_material(_MAT_BONE_Z, Color(0.55, 0.7, 1.0), false, true)


# Render after Godot's built-in Skeleton3D gizmo (default priority -1.0) so
# our lines win the z-fight when on_top is on.
func _get_priority() -> float:
	return 1.0


func _get_gizmo_name() -> String:
	return "Marionette Authoring"


func _has_gizmo(for_node_3d: Node3D) -> bool:
	return for_node_3d is Marionette


func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var node: Marionette = gizmo.get_node_3d() as Marionette
	if node == null:
		return
	var bp: BoneProfile = node.bone_profile
	if bp == null or bp.skeleton_profile == null:
		return
	var profile: SkeletonProfile = bp.skeleton_profile
	if profile.bone_size == 0:
		return

	var live_skeleton: Skeleton3D = node.resolve_skeleton()
	var bone_map: BoneMap = node.bone_map
	var use_live: bool = live_skeleton != null and bone_map != null

	var world_rests: Dictionary[StringName, Transform3D]
	var muscle_frame: MuscleFrame
	# `source_to_local` transforms a point from the data source's frame into
	# the Marionette node's local frame (gizmo coords). For template data
	# the source frame is the Marionette's own local frame, so it's identity.
	# For live data, points come in skeleton-local coords and we need to go
	# skeleton-local -> world -> marionette-local.
	var source_to_local: Transform3D = Transform3D.IDENTITY
	if use_live:
		world_rests = MuscleFrameBuilder.compute_skeleton_world_rests(live_skeleton, profile, bone_map)
		muscle_frame = MuscleFrameBuilder.build_from_skeleton(live_skeleton, profile, bone_map)
		source_to_local = node.global_transform.affine_inverse() * live_skeleton.global_transform
	else:
		world_rests = MuscleFrameBuilder.compute_world_rests(profile)
		muscle_frame = MuscleFrameBuilder.build(profile)

	if world_rests.is_empty():
		return

	var hip_mid: Vector3 = _hip_midpoint_from_rests(world_rests)
	_draw_muscle_frame(gizmo, source_to_local * hip_mid, muscle_frame, source_to_local.basis)
	_draw_per_bone_targets(gizmo, profile, world_rests, muscle_frame, source_to_local)


static func _hip_midpoint_from_rests(world_rests: Dictionary[StringName, Transform3D]) -> Vector3:
	if world_rests.has(&"LeftUpperLeg") and world_rests.has(&"RightUpperLeg"):
		return (world_rests[&"LeftUpperLeg"].origin + world_rests[&"RightUpperLeg"].origin) * 0.5
	if world_rests.has(&"Hips"):
		return world_rests[&"Hips"].origin
	return Vector3.ZERO


func _draw_muscle_frame(
		gizmo: EditorNode3DGizmo,
		origin: Vector3,
		frame: MuscleFrame,
		direction_basis: Basis) -> void:
	var len: float = _MUSCLE_FRAME_LENGTH
	gizmo.add_lines(_segment(origin, origin + (direction_basis * frame.right) * len),
		get_material(_MAT_MUSCLE_X, gizmo))
	gizmo.add_lines(_segment(origin, origin + (direction_basis * frame.up) * len),
		get_material(_MAT_MUSCLE_Y, gizmo))
	gizmo.add_lines(_segment(origin, origin + (direction_basis * frame.forward) * len),
		get_material(_MAT_MUSCLE_Z, gizmo))


func _draw_per_bone_targets(
		gizmo: EditorNode3DGizmo,
		profile: SkeletonProfile,
		world_rests: Dictionary[StringName, Transform3D],
		muscle_frame: MuscleFrame,
		source_to_local: Transform3D) -> void:
	var bone_count: int = profile.bone_size
	# Build an index from parent-name to the first child's world-rest for the
	# child-hint each solver needs. SkeletonProfile.get_bone_tail() returns
	# an explicit tail when tail_direction == 1, otherwise we fall back to
	# scanning for the first child bone.
	var first_child: Dictionary[StringName, StringName] = {}
	for i in range(bone_count):
		var parent_name: StringName = profile.get_bone_parent(i)
		if parent_name != &"" and not first_child.has(parent_name):
			first_child[parent_name] = profile.get_bone_name(i)

	var direction_basis: Basis = source_to_local.basis
	for i in range(bone_count):
		var bone_name: StringName = profile.get_bone_name(i)
		var archetype: int = MarionetteArchetypeDefaults.archetype_for_bone(bone_name)
		if archetype < 0:
			continue
		# Skip bones not present in the data source (live skeleton may not
		# have every template bone mapped/found).
		if not world_rests.has(bone_name):
			continue
		var bone_world: Transform3D = world_rests[bone_name]

		# Resolve child world-rest. Order: explicit tail bone (tail_direction==1),
		# else first listed child, else nudge along bone-local +Y.
		var child_world: Transform3D = bone_world
		var explicit_tail: StringName = profile.get_bone_tail(i)
		if explicit_tail != &"" and world_rests.has(explicit_tail):
			child_world = world_rests[explicit_tail]
		elif first_child.has(bone_name) and world_rests.has(first_child[bone_name]):
			child_world = world_rests[first_child[bone_name]]
		else:
			# Synthesize: bone origin + small step along bone-local +Y.
			var nudge: Vector3 = bone_world.basis.y.normalized() * _BONE_FRAME_LENGTH
			if nudge == Vector3.ZERO:
				nudge = Vector3(0.0, _BONE_FRAME_LENGTH, 0.0)
			child_world = bone_world
			child_world.origin = bone_world.origin + nudge

		var is_left_side: bool = String(bone_name).begins_with("Left")
		var basis: Basis = MarionetteArchetypeSolverDispatch.solve(
				archetype, bone_world, child_world, muscle_frame, is_left_side)
		var origin: Vector3 = source_to_local * bone_world.origin
		var len: float = _BONE_FRAME_LENGTH
		gizmo.add_lines(_segment(origin, origin + (direction_basis * basis.x) * len),
			get_material(_MAT_BONE_X, gizmo))
		gizmo.add_lines(_segment(origin, origin + (direction_basis * basis.y) * len),
			get_material(_MAT_BONE_Y, gizmo))
		gizmo.add_lines(_segment(origin, origin + (direction_basis * basis.z) * len),
			get_material(_MAT_BONE_Z, gizmo))


static func _segment(a: Vector3, b: Vector3) -> PackedVector3Array:
	var arr: PackedVector3Array = PackedVector3Array()
	arr.append(a)
	arr.append(b)
	return arr
