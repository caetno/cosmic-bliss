@tool
class_name MarionetteBallSolver
extends RefCounted

# Ball archetype: shoulder, hip. 3-DOF spherical joint.
#
# Anatomical flex of a ball joint (shoulder flex, hip flex) moves the limb
# tip *forward* (anteriorly). The flex rotation axis is the perpendicular to
# `along` that produces forward motion when crossed with `along`. We compute
# it directly via `along × forward` rather than starting from "body lateral"
# and orthogonalizing — this gives sign-correct flex on both sides without
# any per-side branching (the right arm's `along` is mirrored, so the cross
# yields a mirrored flex axis, and motion stays forward).

static func solve(
		bone_world_rest: Transform3D,
		child_world_rest: Transform3D,
		muscle_frame: MuscleFrame,
		is_left_side: bool,
		_parent_world_rest: Transform3D = Transform3D(),
		motion_target: Vector3 = Vector3.ZERO) -> Basis:
	var along: Vector3 = MarionetteSolverUtils.along_bone_direction(bone_world_rest, child_world_rest)
	if along == Vector3.ZERO:
		# No child: fall back to bone's own local +Y axis (Blender / ARP convention).
		along = bone_world_rest.basis.y.normalized()
	if motion_target == Vector3.ZERO:
		motion_target = muscle_frame.forward
	var flex: Vector3 = MarionetteSolverUtils.anatomical_flex_axis(
			along, motion_target, muscle_frame, is_left_side)
	return MarionetteSolverUtils.make_anatomical_basis(flex, along)
