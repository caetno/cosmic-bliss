class_name MarionetteClavicleSolver
extends RefCounted

# Clavicle archetype: small-ROM 3-DOF connecting UpperChest to UpperArm.
#
# The clavicle bone runs laterally outward (along the body's lateral axis at
# rest), so along-bone is roughly the body's lateral direction. That makes
# the lateral axis a poor choice for anatomical flex (it would be parallel
# to along-bone). Instead we use UP as the flex axis: positive flex of the
# clavicle = elevation of the shoulder (shrug).
#
# Abduction (= flex × along) ends up roughly forward/back, which corresponds
# to clavicle protraction/retraction.

static func solve(
		bone_world_rest: Transform3D,
		child_world_rest: Transform3D,
		muscle_frame: MuscleFrame,
		_is_left_side: bool) -> Basis:
	var along: Vector3 = MarionetteSolverUtils.along_bone_direction(bone_world_rest, child_world_rest)
	if along == Vector3.ZERO:
		along = bone_world_rest.basis.y.normalized()
	# Flex axis = up direction, made perpendicular to along.
	var flex: Vector3 = muscle_frame.up
	return MarionetteSolverUtils.make_anatomical_basis(flex, along)
