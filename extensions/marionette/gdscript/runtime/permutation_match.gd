class_name MarionettePermutationMatch
extends RefCounted

# Result of MarionettePermutationMatcher.match(): the best signed permutation
# of the bone's rest basis whose columns align with a solver target's
# (flex, along-bone, abduction) anatomical axes, plus an alignment score and
# matched flag for the "Generate from Skeleton" report (P2.10).
#
# Score is the worst per-axis dot product across the three anatomical
# columns, in [-1, 1]; higher is better. `matched` is the threshold check
# the matcher applied (default 0.85 ≈ cos(31°)). Unmatched bones surface in
# the gizmo as yellow tripods (P2.11) and in the diagnostic dock (P2.12).

var flex_axis: SignedAxis.Axis = SignedAxis.Axis.PLUS_X
var along_bone_axis: SignedAxis.Axis = SignedAxis.Axis.PLUS_Y
var abduction_axis: SignedAxis.Axis = SignedAxis.Axis.PLUS_Z
var score: float = 0.0
var matched: bool = false


# Convenience: copy the resolved permutation into a BoneEntry, leaving its
# other fields untouched. Used by the authoring pipeline (P2.10) once
# matched=true; unmatched bones get the same write but flagged separately
# for the user to review.
func write_into(entry: BoneEntry) -> void:
	entry.flex_axis = flex_axis
	entry.along_bone_axis = along_bone_axis
	entry.abduction_axis = abduction_axis
