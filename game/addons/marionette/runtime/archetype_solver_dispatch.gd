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
		is_left_side: bool) -> Basis:
	match archetype:
		BoneArchetype.Type.BALL:
			return MarionetteBallSolver.solve(bone_world_rest, child_world_rest, muscle_frame, is_left_side)
		BoneArchetype.Type.HINGE:
			return MarionetteHingeSolver.solve(bone_world_rest, child_world_rest, muscle_frame, is_left_side)
		BoneArchetype.Type.SADDLE:
			return MarionetteSaddleSolver.solve(bone_world_rest, child_world_rest, muscle_frame, is_left_side)
		BoneArchetype.Type.PIVOT:
			return MarionettePivotSolver.solve(bone_world_rest, child_world_rest, muscle_frame, is_left_side)
		BoneArchetype.Type.SPINE_SEGMENT:
			return MarionetteSpineSegmentSolver.solve(bone_world_rest, child_world_rest, muscle_frame, is_left_side)
		BoneArchetype.Type.CLAVICLE:
			return MarionetteClavicleSolver.solve(bone_world_rest, child_world_rest, muscle_frame, is_left_side)
		BoneArchetype.Type.ROOT:
			return MarionetteRootSolver.solve(bone_world_rest, child_world_rest, muscle_frame, is_left_side)
		BoneArchetype.Type.FIXED:
			return MarionetteFixedSolver.solve(bone_world_rest, child_world_rest, muscle_frame, is_left_side)
	return Basis.IDENTITY
