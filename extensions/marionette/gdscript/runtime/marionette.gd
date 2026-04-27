@tool
class_name Marionette
extends Node3D

# Top-level Marionette node. Phase 3 will grow this into the active-ragdoll
# orchestrator (build_ragdoll, BoneStateProfile, CollisionExclusionProfile,
# Skeleton3D plumbing). For now it's a minimal host so the authoring gizmo
# (P2.11 partial) has something to attach to.
#
# Gizmo data sources (the gizmo prefers live data when complete):
#   - bone_profile.skeleton_profile   — template reference poses (always used
#                                        as the bone-name authority).
#   - skeleton (NodePath -> Skeleton3D) + bone_map — when both are set, the
#                                        gizmo recomputes the muscle frame
#                                        and per-bone tripods from the live
#                                        rig's bone positions, mapped through
#                                        the BoneMap.
# When the live path is incomplete, the gizmo falls back to drawing the
# template reference-pose layout (canonical T-pose, scaled per the template).

@export var bone_profile: BoneProfile:
	set(value):
		if bone_profile == value:
			return
		bone_profile = value
		update_gizmos()

# Translates BoneProfile/SkeletonProfile bone names to your rig's bone names.
# Required to draw the gizmo on the live skeleton; without it, the gizmo
# falls back to the template reference-pose layout.
@export var bone_map: BoneMap:
	set(value):
		if bone_map == value:
			return
		bone_map = value
		update_gizmos()

# Path to a sibling/child Skeleton3D. When set together with bone_map, the
# gizmo draws on the live rig.
@export_node_path("Skeleton3D") var skeleton: NodePath:
	set(value):
		if skeleton == value:
			return
		skeleton = value
		update_gizmos()


func resolve_skeleton() -> Skeleton3D:
	if skeleton.is_empty():
		return null
	var node: Node = get_node_or_null(skeleton)
	return node as Skeleton3D
