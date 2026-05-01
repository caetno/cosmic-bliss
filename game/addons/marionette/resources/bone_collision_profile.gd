@tool
class_name BoneCollisionProfile
extends Resource

# Per-character convex-hull collider data, generated at authoring time from
# a skinned mesh. Replaces the default capsule colliders Marionette builds
# in `_make_capsule_collider`. Kept on the Marionette node alongside the
# other profiles (BoneProfile / BoneStateProfile / CollisionExclusionProfile);
# see CLAUDE.md §10.
#
# Storage: `hulls[profile_bone_name]` holds the hull's input points already
# in bone-local rest space (post-shrink), ready to drop into a
# ConvexPolygonShape3D — Jolt computes the hull internally on assignment.
# `auto_exclusions` lists Skeleton3D bone-index pairs whose hull AABBs
# overlap; consumers merge these with the standard CollisionExclusionProfile
# pairs so adjacent hulls don't fight at joints.
#
# Authoring parameters are persisted on the resource so a re-build with the
# same knobs is a one-click action (see ColliderBuilder.build_profile).

@export var hulls: Dictionary[StringName, PackedVector3Array] = {}

# Skeleton3D bone-index pairs whose hulls overlap in rest pose. Resolved
# against the live skeleton at apply-time (same convention as
# CollisionExclusionProfile.excluded_pairs).
@export var auto_exclusions: Array[Vector2i] = []

# Vertex weight floor for multi-bone overlap assignment. Vertices with
# weight >= threshold on a non-dominant bone are added to that bone's
# bucket too — produces overlapping hulls at joints, which avoids the
# silhouette gap a strict argmax assignment leaves on skinned meshes.
@export_range(0.0, 1.0, 0.01) var weight_threshold: float = 0.3

# Adaptive decimation target. ColliderBuilder grows the per-hull point
# count until silhouette quality (mean directional-extent ratio over the
# Fibonacci-sphere probe) reaches this fraction, then stops.
@export_range(0.5, 1.0, 0.01) var silhouette_quality: float = 0.97

# Hard cap on points per hull. Even when the silhouette threshold isn't
# reached, decimation stops here. Jolt convex hulls handle large input
# sets fine — the cap is mostly to keep the .tres readable and rebuilds
# fast.
@export_range(8, 256, 1) var max_points_per_hull: int = 64

# Inward shrink toward each hull's centroid, in bone-local space.
# 0.02 = 2% — tiny but enough to prevent neighboring hulls from touching
# at the bind-pose seams. Higher values trade silhouette accuracy for
# joint clearance; set to 0 to keep the raw skin envelope.
@export_range(0.0, 0.3, 0.005) var shrink_factor: float = 0.02


func has_hull(bone_name: StringName) -> bool:
	if not hulls.has(bone_name):
		return false
	return hulls[bone_name].size() >= 4


# Builds a ConvexPolygonShape3D for `bone_name` from the stored points.
# Returns null when the bone has no hull or fewer than 4 points (Jolt
# refuses to hull degenerate sets). Caller is responsible for owning /
# parenting the returned CollisionShape3D.
func make_shape(bone_name: StringName) -> ConvexPolygonShape3D:
	if not has_hull(bone_name):
		return null
	var shape := ConvexPolygonShape3D.new()
	shape.points = hulls[bone_name]
	return shape
