@tool
class_name BoneStateValidator
extends RefCounted

## Authoring-time check: if a `Powered` bone has a `Kinematic` ancestor in the
## skeleton hierarchy, the resulting physics is nonsensical (Kinematic =
## frozen, but the Powered child needs the joint to react against a mobile
## parent). The validator walks the chain and promotes the offending
## ancestors to `Unpowered` in a returned in-memory states dict — the saved
## `BoneStateProfile.tres` is not mutated.
##
## Why `Unpowered` (not `Powered`)? `Unpowered` is the minimum mode where
## physics propagates through the joint without the ancestor itself running
## SPD. A `Kinematic` ancestor of an `Unpowered` bone is a legitimate "limp
## arm hanging from a frozen shoulder" case — only the `Powered` descendant
## triggers the promotion.
##
## Slice 7 of Phase 5 (P5.7). Run by `Marionette.build_ragdoll` after
## defaulting the profile and before the pass-2 build loop.


# Walks `parents` from `bone` upward, collecting ancestor profile names in
# order (closest first). Stops at the root (parent missing from dict).
static func _ancestor_chain(bone: StringName, parents: Dictionary[StringName, StringName]) -> Array[StringName]:
	var chain: Array[StringName] = []
	var cur: StringName = parents.get(bone, &"")
	while cur != &"":
		chain.append(cur)
		cur = parents.get(cur, &"")
	return chain


## Returns a fresh states dict where Kinematic ancestors of any Powered bone
## have been promoted to Unpowered. `parents` maps each profile bone name to
## its profile parent name (use the BoneMap-translated names, matching
## `BoneStateProfile.states` keys). Missing parent = root.
##
## `warnings` (out): one entry per promotion, suitable for `push_warning`.
static func validate(
		states: BoneStateProfile,
		parents: Dictionary[StringName, StringName],
		warnings: Array[String] = []) -> Dictionary[StringName, int]:
	var corrected: Dictionary[StringName, int] = {}
	# Seed corrected with every key seen in states + parents. The validator
	# must handle bones that exist in the parent map but not in
	# states.states (defaults to POWERED).
	var all_bones: Dictionary[StringName, bool] = {}
	for k: StringName in states.states.keys():
		all_bones[k] = true
	for k: StringName in parents.keys():
		all_bones[k] = true
	for k: StringName in all_bones.keys():
		corrected[k] = states.get_state(k)

	# For each Powered bone, walk ancestors. Promote any Kinematic ancestor
	# to Unpowered. Powered/Unpowered ancestors are left alone — only
	# Kinematic is the problem.
	for bone: StringName in corrected.keys():
		if corrected[bone] != BoneStateProfile.State.POWERED:
			continue
		for ancestor: StringName in _ancestor_chain(bone, parents):
			if corrected.get(ancestor, BoneStateProfile.State.POWERED) == BoneStateProfile.State.KINEMATIC:
				corrected[ancestor] = BoneStateProfile.State.UNPOWERED
				warnings.append(
						"BoneStateProfile: '%s' (Kinematic) is an ancestor of '%s' (Powered) — promoted to Unpowered in-memory (saved profile unchanged)" %
						[ancestor, bone])
	return corrected


## Convenience: builds the parent map from a Skeleton3D + bone-name resolver
## callable (skel bone name -> profile bone name; `&""` for "skip this
## bone"). Returns a `parents` dict keyed by PROFILE name. Used by
## `Marionette.build_ragdoll` to feed `validate`.
static func parents_from_skeleton(
		skel: Skeleton3D,
		resolve_profile_name: Callable) -> Dictionary[StringName, StringName]:
	var parents: Dictionary[StringName, StringName] = {}
	for i in range(skel.get_bone_count()):
		var pname: StringName = resolve_profile_name.call(skel.get_bone_name(i))
		if pname == &"":
			continue
		var pi: int = skel.get_bone_parent(i)
		while pi >= 0:
			var anc: StringName = resolve_profile_name.call(skel.get_bone_name(pi))
			if anc != &"":
				parents[pname] = anc
				break
			pi = skel.get_bone_parent(pi)
	return parents
