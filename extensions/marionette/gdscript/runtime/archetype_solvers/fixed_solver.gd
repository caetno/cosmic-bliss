@tool
class_name MarionetteFixedSolver
extends RefCounted

# Fixed archetype: jaw, eyes. Out of Marionette's SPD scope (driven by the
# facial expression system). The geometric solver still produces a basis so
# the gizmo can show that the bone exists and where it sits, but no
# anatomical motion convention is enforced.

static func solve(
		bone_world_rest: Transform3D,
		_child_world_rest: Transform3D,
		_muscle_frame: MuscleFrame,
		_is_left_side: bool) -> Basis:
	# Just echo the bone's own rest basis so the gizmo aligns with the bone.
	return bone_world_rest.basis.orthonormalized()
