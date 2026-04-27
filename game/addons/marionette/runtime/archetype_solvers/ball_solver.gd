class_name MarionetteBallSolver
extends RefCounted

# Ball archetype: shoulder, hip. 3-DOF spherical joint.
#
# Convention:
#   along_bone   = direction from bone origin to child origin (down the limb)
#   flex_axis    = body lateral axis (limb_flex_axis), perpendicularized against along
#   abduction    = flex × along
#
# Both shoulders share the same world flex axis (the lateral line through both
# shoulders). is_left_side is unused here at the geometric level — handedness
# is captured later by the permutation matcher (P2.8) when it picks which
# bone-local signed axis aligns with the world flex axis.

static func solve(
		bone_world_rest: Transform3D,
		child_world_rest: Transform3D,
		muscle_frame: MuscleFrame,
		is_left_side: bool) -> Basis:
	var along: Vector3 = MarionetteSolverUtils.along_bone_direction(bone_world_rest, child_world_rest)
	if along == Vector3.ZERO:
		# No child: fall back to bone's own local +Y axis (Blender / ARP convention).
		along = bone_world_rest.basis.y.normalized()
	var flex: Vector3 = MarionetteSolverUtils.limb_flex_axis(muscle_frame, is_left_side)
	return MarionetteSolverUtils.make_anatomical_basis(flex, along)
