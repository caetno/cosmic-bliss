@tool
class_name MarionetteRootSolver
extends RefCounted

# Root archetype: pelvis / world root. Not driven by SPD; the basis is only
# used by the gizmo for visual orientation. We align flex with body lateral
# and along-bone with body up so the displayed tripod matches the muscle
# frame at the root.

static func solve(
		_bone_world_rest: Transform3D,
		_child_world_rest: Transform3D,
		muscle_frame: MuscleFrame,
		_is_left_side: bool) -> Basis:
	return MarionetteSolverUtils.make_anatomical_basis(-muscle_frame.right, muscle_frame.up)
