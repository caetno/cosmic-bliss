@tool
class_name MarionetteSpineSegmentSolver
extends RefCounted

# SpineSegment archetype: each vertebra plus neck and head. 3-DOF small ROM.
#
# Spine segments differ from limb balls in two ways:
#   - The "child" hint is the next spine bone or head, which is *above*, not
#     below. So along-bone in world space points toward UP (up the chain),
#     not down a limb.
#   - There is no left/right side concept; flex axis is computed via
#     `along × forward` so that +flex bends the trunk anteriorly forward (the
#     anatomical flex direction) regardless of side. is_left_side is ignored.

static func solve(
		bone_world_rest: Transform3D,
		child_world_rest: Transform3D,
		muscle_frame: MuscleFrame,
		_is_left_side: bool,
		_parent_world_rest: Transform3D = Transform3D(),
		motion_target: Vector3 = Vector3.ZERO) -> Basis:
	var along: Vector3 = MarionetteSolverUtils.along_bone_direction(bone_world_rest, child_world_rest)
	if along == Vector3.ZERO:
		# No child (e.g. Head with no children): use bone's own +Y in world.
		along = bone_world_rest.basis.y.normalized()
		if along == Vector3.ZERO:
			along = muscle_frame.up
	if motion_target == Vector3.ZERO:
		motion_target = muscle_frame.forward
	# Spine has no side, but anatomical_flex_axis just signs the lateral
	# fallback by side — for a vertical along, the cross with motion_target
	# is already non-degenerate so the fallback path doesn't run.
	var flex: Vector3 = MarionetteSolverUtils.anatomical_flex_axis(
			along, motion_target, muscle_frame, true)
	return MarionetteSolverUtils.make_anatomical_basis(flex, along)
