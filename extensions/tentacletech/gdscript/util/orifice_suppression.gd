@tool
class_name OrificeSuppression
extends RefCounted

## Slice TT-S3 (§10.5) — small GDScript glue that resolves an
## `OrificeProfile`'s `suppressed_bones` / `manual_suppressed_bones` to
## the Object IDs of the matching `PhysicalBone3D` children of a host
## `Skeleton3D` (typically the skeleton's `PhysicalBoneSimulator3D`
## child).
##
## Static utility — no state. Call once at hero-init (after the orifice
## profile is assigned AND the skeleton is in the tree AND the ragdoll
## bodies have been spawned), then forget. The result is pushed straight
## into the `Orifice` C++ class via `Orifice.set_suppressed_object_ids`.
##
## Returns the (possibly empty) Object-ID list as a `PackedInt64Array`
## ready to hand to `Orifice.set_suppressed_object_ids`. Empty list +
## `Orifice.clear_suppressed_object_ids()` is the right call when the
## skeleton has no ragdoll bodies yet — the suppression mechanism
## layers naturally (no IDs → no suppression).

const PHYSICAL_BONE_CLASS := "PhysicalBone3D"


## Walks `skeleton`'s `PhysicalBone3D` descendants and collects the
## Object IDs of those whose `bone_name` is in `bone_names`. Bones not
## found in the skeleton or not backed by a `PhysicalBone3D` produce a
## warning and are skipped (best-effort §10.5 contract).
##
## `skeleton` may be `null`: the function returns an empty array
## without warning. This is the "no ragdoll yet" path — the orifice
## ends up with no suppression IDs and the per-tick filter trivially
## passes every contact.
static func resolve_bone_names_to_object_ids(
		skeleton: Skeleton3D,
		bone_names: PackedStringArray) -> PackedInt64Array:
	var out := PackedInt64Array()
	if skeleton == null:
		return out
	if bone_names.is_empty():
		return out

	# Validate every name resolves to a real bone — push_warning the
	# ones that don't, but keep scanning so the caller learns about
	# all typos in one go. Build the lookup set as we go.
	var wanted := {}
	for n in bone_names:
		if n.is_empty():
			continue
		var idx := skeleton.find_bone(n)
		if idx < 0:
			push_warning(
					"OrificeSuppression: bone name '%s' not found in skeleton '%s'" %
					[n, skeleton.name])
			continue
		wanted[n] = true

	if wanted.is_empty():
		return out

	# Walk PhysicalBone3D descendants. The §10.5 contract says the
	# bodies live as PhysicalBone3D children under the Skeleton3D
	# (typically inside a PhysicalBoneSimulator3D, but we walk the
	# full subtree so legacy / authored variants still work).
	var seen_ids := {}
	for child in _collect_physical_bones(skeleton):
		var b_name: StringName = child.get("bone_name")
		# `bone_name` is empty until the editor has resolved it, and
		# some scenes leave it default-constructed — skip those.
		if String(b_name).is_empty():
			continue
		if not wanted.has(String(b_name)):
			continue
		var oid: int = child.get_instance_id()
		if seen_ids.has(oid):
			continue
		seen_ids[oid] = true
		out.append(oid)

	return out


## Convenience: resolves + writes directly to the orifice. Returns the
## list of IDs that were written (empty == no suppression).
static func apply_to_orifice(
		orifice: Object,
		profile: Resource,
		skeleton: Skeleton3D) -> PackedInt64Array:
	if orifice == null:
		return PackedInt64Array()
	if profile == null:
		# Caller wants to clear any previous set.
		if orifice.has_method("clear_suppressed_object_ids"):
			orifice.call("clear_suppressed_object_ids")
		return PackedInt64Array()
	var names: PackedStringArray = profile.call("get_effective_suppression_set")
	var ids := resolve_bone_names_to_object_ids(skeleton, names)
	if orifice.has_method("set_suppressed_object_ids"):
		orifice.call("set_suppressed_object_ids", ids)
	return ids


static func _collect_physical_bones(root: Node) -> Array:
	# Walks the subtree and collects every node whose class matches
	# PhysicalBone3D. We can't use `find_children(..., PHYSICAL_BONE_CLASS, true)`
	# because the typed-class form is class-cache sensitive in
	# `--script` mode; a manual walk sidesteps that.
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.is_class(PHYSICAL_BONE_CLASS):
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out
