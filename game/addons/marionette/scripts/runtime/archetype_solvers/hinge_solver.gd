@tool
class_name MarionetteHingeSolver
extends RefCounted

# Hinge archetype: elbow, knee, finger/toe phalanges (non-proximal).
#
# A pure 1-DOF joint. When the limb has a meaningful bend at this joint the
# rotation axis is the limb-plane normal: `parent_along × along`. Sign is
# aligned so the bone tip moves in the bone's anatomical motion-target
# direction on +flex. Caller passes that direction in via `motion_target`,
# which `solver_utils.anatomical_motion_target` resolves per bone:
#   elbow / finger phalanges      — anteriorly forward (wrist toward shoulder)
#   knee                          — anteriorly BACKWARD (foot toward butt;
#                                   anatomical knee flexion folds posteriorly)
#   toe phalanges                 — downward (curl)
# So +flex is "the natural anatomical fold" for each of these, even though
# the world direction differs — the knee is the carve-out.
#
# When the limb is straight at this joint (T-pose elbow, straight knee), the
# cross degenerates and we fall back to `along × motion_target`. That formula
# gives sign-correct flex on both sides — same fix as Ball / Saddle.

const _EPSILON: float = 1.0e-6
# sin²(8°) ≈ 0.019 — anything below this we treat as "straight limb" and use
# the along × motion_target fallback. The cross of nearly-collinear vectors
# produces a noisy small-magnitude axis that, after sign-align, can land
# 90° from the anatomical flex direction (caught the toe4/toe5 proximal
# phalanges in the template profile, where the toe shafts deviate ~5° from
# the foot direction). The fallback formula gives a clean axis on both sides.
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

	var hinge_axis: Vector3 = Vector3.ZERO
	if parent_along != Vector3.ZERO:
		hinge_axis = parent_along.cross(along)
	# Try the limb-plane normal first; fall back to along × motion_target if
	# either (a) the limb is too straight for a meaningful cross, or (b) the
	# cross-product axis would produce motion that's far from the target
	# direction. Case (b) catches bones whose rest pose deviates SIDEWAYS
	# from straight (toe 5 proximal phalanges, ~20° outward tilt) — the
	# cross there picks a sideways axis that fights the anatomical motion.
	var use_fallback: bool = hinge_axis.length_squared() < _STRAIGHT_LIMB_SIN_SQ
	if not use_fallback:
		hinge_axis = hinge_axis.normalized()
		var motion: Vector3 = hinge_axis.cross(along)
		if motion.dot(motion_target) < 0.0:
			hinge_axis = -hinge_axis
			motion = -motion
		# Tightened to ~18° (cos 0.95). See matching comment in saddle_solver.gd.
		if motion.dot(motion_target) < 0.95:
			use_fallback = true
	if use_fallback:
		hinge_axis = MarionetteSolverUtils.anatomical_flex_axis(
				along, motion_target, muscle_frame, is_left_side)
	return MarionetteSolverUtils.make_anatomical_basis(hinge_axis, along)
