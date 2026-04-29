@tool
class_name MarionetteSaddleSolver
extends RefCounted

# Saddle archetype: wrist, ankle, MCP, MTP, thumb metacarpal. 2-DOF joint
# allowing flexion + abduction but no axial twist.
#
# When the limb has a meaningful bend at the joint (parent and bone segments
# non-collinear), the limb-plane normal is the canonical flex axis — same as
# Hinge. Sign is aligned so motion takes the bone tip forward (palmar flex
# for wrists, dorsiflexion for ankles measured anteriorly).
#
# When the limb is straight at the joint (T-pose wrist, straight finger MCP),
# `parent × along` is degenerate and we fall back to `along × forward`. That
# formula yields sign-correct flex on both sides automatically — same fix as
# in Ball / Spine solvers.

const _EPSILON: float = 1.0e-6
# Same straight-limb threshold as the Hinge solver — see comment there.
const _STRAIGHT_LIMB_SIN_SQ: float = 0.02


static func solve(
		bone_world_rest: Transform3D,
		child_world_rest: Transform3D,
		muscle_frame: MuscleFrame,
		is_left_side: bool,
		parent_world_rest: Transform3D = Transform3D(),
		motion_target: Vector3 = Vector3.ZERO) -> Basis:
	var along: Vector3 = MarionetteSolverUtils.along_bone_direction(bone_world_rest, child_world_rest)
	if along == Vector3.ZERO:
		along = bone_world_rest.basis.y.normalized()
	if motion_target == Vector3.ZERO:
		motion_target = muscle_frame.forward

	var parent_to_bone: Vector3 = bone_world_rest.origin - parent_world_rest.origin
	var parent_along: Vector3 = Vector3.ZERO
	if parent_to_bone.length_squared() > _EPSILON:
		parent_along = parent_to_bone.normalized()

	var flex: Vector3 = Vector3.ZERO
	if parent_along != Vector3.ZERO:
		flex = parent_along.cross(along)
	# Same two-stage logic as Hinge: try limb-plane normal first, fall back
	# to along × motion_target when either the limb is straight or the cross
	# axis points the wrong way for the anatomical motion.
	var use_fallback: bool = flex.length_squared() < _STRAIGHT_LIMB_SIN_SQ
	if not use_fallback:
		flex = flex.normalized()
		var motion: Vector3 = flex.cross(along)
		if motion.dot(motion_target) < 0.0:
			flex = -flex
			motion = -motion
		# Tightened to ~18° (cos 0.95). Hand + finger A-pose poses score the
		# cross-product axis ~0.68 with the target, well below the cutoff,
		# so they take the fallback and end up with pure target-direction
		# motion. We only keep the cross-product axis when the bone is
		# clearly *and* cleanly bent — A-pose elbow at ~30° still passes.
		if motion.dot(motion_target) < 0.95:
			use_fallback = true
	if use_fallback:
		flex = MarionetteSolverUtils.anatomical_flex_axis(
				along, motion_target, muscle_frame, is_left_side)
	return MarionetteSolverUtils.make_anatomical_basis(flex, along)
