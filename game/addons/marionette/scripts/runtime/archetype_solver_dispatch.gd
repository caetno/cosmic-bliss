@tool
class_name MarionetteArchetypeSolverDispatch
extends RefCounted

# Single entry point for archetype-dispatched authoring solvers (P2.6).
# Each branch hands off to a per-archetype file so the dispatch never grows
# beyond a switch — CLAUDE.md §"Generic solvers hiding archetype logic in
# conditionals" applies to bodies, not to a thin dispatch.

static func solve(
		archetype: BoneArchetype.Type,
		bone_world_rest: Transform3D,
		child_world_rest: Transform3D,
		muscle_frame: MuscleFrame,
		is_left_side: bool,
		parent_world_rest: Transform3D = Transform3D(),
		motion_target: Vector3 = Vector3.ZERO) -> Basis:
	# `motion_target` overrides the solver's per-archetype default. Sentinel
	# Vector3.ZERO means "use the default" (forward for limb/spine, up for
	# clavicle, etc). Generator / validator pass the resolved direction here
	# so foot dorsiflex (up) and toe curl (down) come out correct without
	# baking those special cases into each solver.
	if motion_target == Vector3.ZERO:
		motion_target = muscle_frame.forward
		if archetype == BoneArchetype.Type.CLAVICLE:
			motion_target = muscle_frame.up
	match archetype:
		BoneArchetype.Type.BALL:
			return MarionetteBallSolver.solve(bone_world_rest, child_world_rest, muscle_frame, is_left_side, parent_world_rest, motion_target)
		BoneArchetype.Type.HINGE:
			return MarionetteHingeSolver.solve(bone_world_rest, child_world_rest, muscle_frame, is_left_side, parent_world_rest, motion_target)
		BoneArchetype.Type.SADDLE:
			return MarionetteSaddleSolver.solve(bone_world_rest, child_world_rest, muscle_frame, is_left_side, parent_world_rest, motion_target)
		BoneArchetype.Type.PIVOT:
			return MarionettePivotSolver.solve(bone_world_rest, child_world_rest, muscle_frame, is_left_side, parent_world_rest)
		BoneArchetype.Type.SPINE_SEGMENT:
			return MarionetteSpineSegmentSolver.solve(bone_world_rest, child_world_rest, muscle_frame, is_left_side, parent_world_rest, motion_target)
		BoneArchetype.Type.CLAVICLE:
			return MarionetteClavicleSolver.solve(bone_world_rest, child_world_rest, muscle_frame, is_left_side, parent_world_rest, motion_target)
		BoneArchetype.Type.ROOT:
			return MarionetteRootSolver.solve(bone_world_rest, child_world_rest, muscle_frame, is_left_side, parent_world_rest)
		BoneArchetype.Type.FIXED:
			return MarionetteFixedSolver.solve(bone_world_rest, child_world_rest, muscle_frame, is_left_side, parent_world_rest)
	return Basis.IDENTITY
