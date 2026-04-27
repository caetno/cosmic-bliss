class_name MarionetteHingeSolver
extends RefCounted

# Hinge archetype: elbow, knee, finger/toe phalanges (non-proximal).
#
# A pure 1-DOF joint around the lateral axis. The flex axis is the only
# physically meaningful one; along-bone and abduction are still reported so
# the matcher (P2.8) and gizmo (P2.11) can position the basis consistently.
#
# We look at *both* the parent's bone direction and the child's to get a
# stable hinge axis even when the limb is bent at rest (knees in A-pose,
# elbows in T-pose). The hinge axis is perpendicular to both, which equals
# the lateral axis when the limb lies in the sagittal plane.

static func solve(
		bone_world_rest: Transform3D,
		child_world_rest: Transform3D,
		muscle_frame: MuscleFrame,
		is_left_side: bool) -> Basis:
	var along: Vector3 = MarionetteSolverUtils.along_bone_direction(bone_world_rest, child_world_rest)
	if along == Vector3.ZERO:
		along = bone_world_rest.basis.y.normalized()
	# For a bent hinge in rest pose, the hinge axis is parent_along × along.
	# We approximate parent_along by the bone's own +Y in world space (the
	# direction the bone's parent considered "down the limb"). Falls back to
	# the lateral axis if those are nearly collinear (T-pose limbs).
	var parent_along: Vector3 = bone_world_rest.basis.y.normalized()
	var hinge_axis: Vector3 = parent_along.cross(along)
	if hinge_axis.length_squared() < 1e-6:
		hinge_axis = MarionetteSolverUtils.limb_flex_axis(muscle_frame, is_left_side)
	else:
		hinge_axis = hinge_axis.normalized()
		# Ensure the hinge axis points the same way as the body lateral axis
		# (consistency across knees, toes, etc.).
		var lateral: Vector3 = MarionetteSolverUtils.limb_flex_axis(muscle_frame, is_left_side)
		if hinge_axis.dot(lateral) < 0.0:
			hinge_axis = -hinge_axis
	return MarionetteSolverUtils.make_anatomical_basis(hinge_axis, along)
