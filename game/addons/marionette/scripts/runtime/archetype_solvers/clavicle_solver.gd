@tool
class_name MarionetteClavicleSolver
extends RefCounted

# Clavicle archetype: small-ROM 3-DOF connecting UpperChest to UpperArm.
#
# Anatomical flex of the clavicle = elevation of the shoulder (shrug). The
# bone tip moves *up*. We derive the flex axis as `along × up` so the cross-
# product motion `flex × along` lands on muscle_frame.up regardless of which
# side the clavicle is on. (The clavicle bone's `along` is body-lateral, so
# `along × up` is roughly muscle_frame.forward direction — perpendicular to
# both lateral and vertical, in the body's sagittal plane.)
#
# Abduction (= flex × along) ends up roughly up, which corresponds to
# clavicle elevation. Medial rotation drives clavicle protraction/retraction.

static func solve(
		bone_world_rest: Transform3D,
		child_world_rest: Transform3D,
		muscle_frame: MuscleFrame,
		_is_left_side: bool,
		_parent_world_rest: Transform3D = Transform3D(),
		motion_target: Vector3 = Vector3.ZERO) -> Basis:
	var along: Vector3 = MarionetteSolverUtils.along_bone_direction(bone_world_rest, child_world_rest)
	if along == Vector3.ZERO:
		along = bone_world_rest.basis.y.normalized()
	if motion_target == Vector3.ZERO:
		motion_target = muscle_frame.up
	var flex: Vector3 = MarionetteSolverUtils.anatomical_flex_axis(
			along, motion_target, muscle_frame, true)
	return MarionetteSolverUtils.make_anatomical_basis(flex, along)
