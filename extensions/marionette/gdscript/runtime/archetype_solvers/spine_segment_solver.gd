class_name MarionetteSpineSegmentSolver
extends RefCounted

# SpineSegment archetype: each vertebra plus neck and head. 3-DOF small ROM.
#
# Spine segments differ from limb balls in two ways:
#   - The "child" hint is the next spine bone or head, which is *above*, not
#     below. So along-bone in world space points toward UP (up the chain),
#     not down a limb.
#   - There is no left/right side concept; flex axis is body lateral
#     unconditionally. is_left_side is ignored.
#
# Functionally the basis composition is the same as a Ball joint (lateral
# flex axis + along-bone + abduction), but factored out so future per-segment
# tweaks (e.g. neck flex limits per vertebra level) can land in this file
# without touching ball_solver.

static func solve(
		bone_world_rest: Transform3D,
		child_world_rest: Transform3D,
		muscle_frame: MuscleFrame,
		_is_left_side: bool) -> Basis:
	var along: Vector3 = MarionetteSolverUtils.along_bone_direction(bone_world_rest, child_world_rest)
	if along == Vector3.ZERO:
		# No child (e.g. Head with no children): use bone's own +Y in world.
		along = bone_world_rest.basis.y.normalized()
		if along == Vector3.ZERO:
			along = muscle_frame.up
	var flex: Vector3 = -muscle_frame.right  # body left direction; same for spine on both halves of body
	return MarionetteSolverUtils.make_anatomical_basis(flex, along)
