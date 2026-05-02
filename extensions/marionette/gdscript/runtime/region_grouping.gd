@tool
class_name MarionetteRegionGrouping
extends RefCounted

# Tuning-oriented region grouping for the Tune & Test inspector widget.
# Coarser than the per-bone level the user might dive into, finer than
# the 11-region MarionetteBoneRegion classifier (which bundles shoulder
# + upper-arm + lower-arm into one "left_arm" — wrong granularity for
# spring stiffness, where each segment wants different values).
#
# Sides are collapsed: a "shoulders" region holds both LeftShoulder and
# RightShoulder. The Tune widget can sync L/R or split them per row;
# this helper just enumerates the pairs.

class Region extends RefCounted:
	enum Kind { HARD, SOFT }
	var name: StringName       # display name + identifier
	var kind: Kind
	var bones: Array[StringName] = []


# --- Hard regions: head-to-toe display order. ---
# Predicates run against entries in BoneProfile.bones in this order, with
# claimed-bone tracking — a bone in `fingers` is matched there and never
# falls through to `hands`.
const _HARD_REGIONS: Array[StringName] = [
	&"head", &"neck", &"spine",
	&"shoulders", &"upper_arms", &"lower_arms", &"hands", &"fingers",
	&"hips", &"upper_legs", &"lower_legs", &"feet", &"toes",
]


# Returns the full ordered region list for a Marionette's profiles. Hard
# regions first (head to toe), soft regions last (sorted by name). Empty
# regions (no matching bones in the profile) are dropped from the result
# so a profile that doesn't have e.g. fingers doesn't show an empty row.
static func derive(
		bone_profile: BoneProfile,
		jiggle_profile: JiggleProfile) -> Array[Region]:
	var regions: Array[Region] = []
	if bone_profile != null:
		# Track claimed bones so a finger doesn't also claim "hand" etc.
		var claimed: Dictionary[StringName, bool] = {}
		for rname: StringName in _HARD_REGIONS:
			var r := Region.new()
			r.name = rname
			r.kind = Region.Kind.HARD
			for bone_name: StringName in bone_profile.bones.keys():
				if claimed.has(bone_name):
					continue
				if _matches_region(rname, bone_name):
					r.bones.append(bone_name)
					claimed[bone_name] = true
			if not r.bones.is_empty():
				r.bones.sort()  # alphabetical within region; left-side first naturally
				regions.append(r)
	if jiggle_profile != null:
		regions.append_array(_derive_soft_regions(jiggle_profile))
	return regions


# Soft regions: groups the JiggleProfile entries by stripping the side
# suffix (`.l` / `.r` / `_l` / `_r` / `.x`). Bones with the same prefix
# end up in one region — c_breast_01.l and c_breast_01.r share a row;
# c_breast_02.l/r share the next.
static func _derive_soft_regions(jiggle_profile: JiggleProfile) -> Array[Region]:
	var groups: Dictionary[StringName, Array] = {}
	for bone_name: StringName in jiggle_profile.entries.keys():
		var key: StringName = _strip_side_suffix(bone_name)
		if not groups.has(key):
			groups[key] = []
		groups[key].append(bone_name)
	var sorted_keys: Array = groups.keys()
	sorted_keys.sort()
	var out: Array[Region] = []
	for key: StringName in sorted_keys:
		var r := Region.new()
		r.name = key
		r.kind = Region.Kind.SOFT
		var bones: Array = groups[key]
		bones.sort()
		for b in bones:
			r.bones.append(b)
		out.append(r)
	return out


# Drops the trailing .l / .r / _l / _r / .x marker so left/right pairs
# collapse to a single region key. Idempotent on names without a marker.
static func _strip_side_suffix(name: StringName) -> StringName:
	var s := String(name)
	for suffix: String in [".l", ".r", "_l", "_r", ".x"]:
		if s.ends_with(suffix):
			return StringName(s.substr(0, s.length() - suffix.length()))
	return name


# Region predicate dispatch. Intentionally narrow patterns — substring +
# suffix matches handle the kasumi / ARP rig and SkeletonProfileHumanoid
# names without pulling in unintended bones from other rigs.
static func _matches_region(region: StringName, bone_name: StringName) -> bool:
	var s := String(bone_name)
	match region:
		&"head":
			return s == "Head"
		&"neck":
			return s == "Neck"
		&"spine":
			return s == "Spine" or s == "Chest" or s == "UpperChest"
		&"shoulders":
			return s.ends_with("Shoulder")
		&"upper_arms":
			return s.ends_with("UpperArm")
		&"lower_arms":
			return s.ends_with("LowerArm")
		&"hands":
			# Just the wrist bone — finger phalanges are claimed by
			# `fingers` first in iteration order.
			return s.ends_with("Hand")
		&"fingers":
			return s.contains("Thumb") or s.contains("Index") or s.contains("Middle") \
					or s.contains("Ring") or s.contains("Little")
		&"hips":
			return s == "Hips" or s == "Root"
		&"upper_legs":
			return s.ends_with("UpperLeg")
		&"lower_legs":
			return s.ends_with("LowerLeg")
		&"feet":
			# Foot wrist; toe phalanges claimed by `toes` first.
			return s.ends_with("Foot")
		&"toes":
			# All toe phalanges. The aggregate "LeftToes/RightToes" bone
			# (when present) also matches and lives in this region.
			return s.contains("Toe")
	return false
