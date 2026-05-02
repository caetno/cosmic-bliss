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

# Skeleton bones that should keep their own bucket instead of cascading
# their skin weights up to the nearest profile-bone ancestor. Used for
# soft-tissue jiggle bones — c_breast_01.l/r, c_breast_02.l/r on ARP rigs;
# any custom belly / glute bones a hero adds. Each entry must be the
# Skeleton3D bone name (post-retarget if applicable). Bones in this list
# get their own hull entry under their literal skel name; the runtime
# spawns a translation-only PhysicalBone3D for each (CLAUDE.md §15) so
# they participate in collision and (slice 4) jiggle physics.
#
# Without this list, ColliderBuilder would cascade c_breast_01.l up to
# its UpperChest parent — the breast skin would absorb into the chest
# hull and there would be no separate body for jiggle to act on.
@export var non_cascade_bones: Array[StringName] = []

# Skeleton3D bone-index pairs whose hulls overlap in rest pose. Resolved
# against the live skeleton at apply-time (same convention as
# CollisionExclusionProfile.excluded_pairs).
@export var auto_exclusions: Array[Vector2i] = []

# Vertex weight floor for multi-bone overlap assignment. Vertices with
# weight >= threshold on a non-dominant bone are added to that bone's
# bucket too — produces overlapping hulls at joints, which avoids the
# silhouette gap a strict argmax assignment leaves on skinned meshes.
@export_range(0.0, 1.0, 0.01) var weight_threshold: float = 0.3

# Hard cap on hull input points per bone. ColliderBuilder runs stratified
# furthest-point sampling along each bucket's longest AABB axis to fill
# this budget — narrow cross-sections (wrist, ankle, toe-base) get their
# own quota so the hull doesn't pinch. Jolt builds the actual convex hull
# from these inputs.
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
