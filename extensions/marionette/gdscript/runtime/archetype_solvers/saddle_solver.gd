@tool
class_name MarionetteSaddleSolver
extends RefCounted

# Saddle archetype: wrist, ankle, MCP, MTP, thumb metacarpal. 2-DOF joint
# allowing flexion + abduction but no axial twist.
#
# Same axis derivation as Ball; the matcher will simply find that the bone's
# rest basis has no native twist DOF (or the runtime will lock angular_y to 0).

static func solve(
		bone_world_rest: Transform3D,
		child_world_rest: Transform3D,
		muscle_frame: MuscleFrame,
		is_left_side: bool) -> Basis:
	var along: Vector3 = MarionetteSolverUtils.along_bone_direction(bone_world_rest, child_world_rest)
	if along == Vector3.ZERO:
		along = bone_world_rest.basis.y.normalized()
	var flex: Vector3 = MarionetteSolverUtils.limb_flex_axis(muscle_frame, is_left_side)
	return MarionetteSolverUtils.make_anatomical_basis(flex, along)
