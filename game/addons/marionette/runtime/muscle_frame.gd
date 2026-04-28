@tool
class_name MuscleFrame
extends RefCounted

# Body-level orthonormal frame derived from a SkeletonProfile's reference
# poses. Used as input to per-archetype solvers (P2.6) so they can pick the
# anatomical flex axis (= lateral) and abduction axis (= anterior-posterior)
# in a way that is independent of the character's world rotation.
#
# All three vectors are unit and mutually orthogonal. Expressed in the
# SkeletonProfile's own coordinate space (the same space the reference poses
# accumulate into).
#
# Convention (matches Godot Y-up, mesh-facing -Z):
#   right   = character's right (e.g., +X if character is built facing -Z and
#             LeftUpperLeg is at +X — which is the SkeletonProfileHumanoid case)
#   up      = head-above-hips direction
#   forward = character's facing direction (mesh-facing direction)

var right: Vector3 = Vector3.RIGHT
var up: Vector3 = Vector3.UP
var forward: Vector3 = Vector3.FORWARD


func _to_string() -> String:
	return "MuscleFrame(right=%s, up=%s, forward=%s)" % [right, up, forward]
