@tool
class_name MarionetteTPoseBasisSolver
extends RefCounted

# T-pose alternative to `MarionetteArchetypeSolverDispatch` — derives the
# anatomical target basis from a per-bone canonical along-direction lookup
# (`MarionetteCanonicalDirections`) plus one cross product, instead of running
# archetype-specific geometric solvers over rest-pose bone-to-child geometry.
# See `docs/marionette/Marionette_Update_TPose_Calibration.md`.
#
# Same return shape as the archetype dispatch (target basis in profile/world
# space, columns flex/along/abd) and reuses the same `solver_utils.gd`
# helpers, so downstream baking, matching, ROM application are unchanged.


static func solve(
		bone_name: StringName,
		archetype: int,
		muscle_frame: MuscleFrame,
		is_left_side: bool) -> Basis:
	var along: Vector3 = MarionetteCanonicalDirections.along_for(
			bone_name, muscle_frame, is_left_side)
	if along == Vector3.ZERO:
		# Bone has no canonical T-pose along-direction (e.g. ROOT / FIXED /
		# unmapped). Caller treats Basis.IDENTITY as "no SPD frame".
		return Basis.IDENTITY
	var motion: Vector3 = MarionetteSolverUtils.anatomical_motion_target(
			bone_name, archetype, muscle_frame)
	if motion == Vector3.ZERO:
		# Pivot / Root / Fixed — anatomical_motion_target returns ZERO for
		# these archetypes. No flex DOF to derive.
		return Basis.IDENTITY
	var flex: Vector3 = MarionetteSolverUtils.anatomical_flex_axis(
			along, motion, muscle_frame, is_left_side)
	return MarionetteSolverUtils.make_anatomical_basis(flex, along)
