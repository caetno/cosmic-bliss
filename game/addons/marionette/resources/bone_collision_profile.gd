@tool
class_name BoneCollisionProfile
extends Resource

## Per-character convex-hull collider data, generated at authoring time
## from the rig's skinned mesh by Marionette's "Build Convex Colliders"
## tool button. Replaces the default per-bone capsule colliders.
##
## Hulls are stored already in bone-local rest space; auto_exclusions
## index into the live Skeleton3D's bone list (rig-specific).

## Per-bone hull input points, keyed by profile bone name. Each value
## is in bone-local rest space (Skin bind pose × mesh vertex), ready
## to drop into a ConvexPolygonShape3D.
@export var hulls: Dictionary[StringName, PackedVector3Array] = {}

## Soft-tissue bones (breast, glute, jowl, etc.) that should keep their
## own hull instead of cascading skin weights up to the nearest
## profile-bone ancestor. Bones listed here also get a translation-only
## PhysicalBone3D (JiggleBone) at Build Ragdoll time so they participate
## in collision + jiggle physics. CLAUDE.md §15.
@export var non_cascade_bones: Array[StringName] = []

## Skeleton3D bone-index pairs whose hulls overlap in rest pose. Applied
## as collision exceptions at start_simulation alongside the standard
## CollisionExclusionProfile.excluded_pairs.
@export var auto_exclusions: Array[Vector2i] = []

## Vertex weight floor for multi-bone overlap assignment during harvest.
## Vertices with weight ≥ threshold on a non-dominant bone are added to
## that bone's bucket too — produces overlapping hulls at joints,
## avoiding the silhouette gap a strict argmax would leave.
@export_range(0.0, 1.0, 0.01) var weight_threshold: float = 0.3

## Hard cap on hull input points per bone. ColliderBuilder runs
## stratified furthest-point sampling along each bucket's longest AABB
## axis to fill this budget — narrow cross-sections (wrist, ankle,
## toe-base) get their own quota so the hull doesn't pinch.
@export_range(8, 256, 1) var max_points_per_hull: int = 64

## Inward shrink toward each hull's centroid, in bone-local space.
## 0.02 = 2% — enough to prevent neighboring hulls from touching at the
## bind-pose seams. Higher trades silhouette accuracy for joint
## clearance; 0 keeps the raw skin envelope.
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
