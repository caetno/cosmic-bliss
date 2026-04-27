class_name MarionettePivotSolver
extends RefCounted

# Pivot archetype: 1-DOF axial twist (forearm pronation/supination is the
# canonical example, though MarionetteHumanoidProfile doesn't use it by
# default — radio-ulnar twist is folded into LowerArm hinge in this rig).
#
# Reserved for skeletons that DO split twist out. The "flex" anatomical axis
# here is somewhat arbitrary since the only meaningful DOF is along-bone
# rotation. We pick the lateral axis for visual consistency with neighboring
# limb bones.

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
