@tool
class_name MarionetteMacroPresets
extends RefCounted

# Unity-style "Muscle Group Preview" macros for the muscle-test dock (P4.x).
# Each macro maps an affected bone to a Vector3 of per-axis coefficients in
# anatomical (flex, medial_rotation, abduction) space, range [-1, 1]. A macro
# slider value `v ∈ [-1, 1]` together with a coeff `c` produces an offset
# `apply_coefficient(v * c, rom_min, rom_max)` per axis, where the offset is
# scaled by `rom_max` when positive and by `|rom_min|` when negative — so
# bones with asymmetric ROM still reach their full natural pose at the
# extremes of the slider.
#
# Sign convention (CLAUDE.md §2): +X = flexion, +Y = medial rotation,
# +Z = abduction. Coefficient signs are stored once per bone — the right
# side does NOT get a sign flip because BoneEntry's permutation already maps
# anatomical-positive to the correct bone-local axis on each side.
#
# The seven macros below mirror Unity's labels (Open/Close, Left/Right,
# Roll Left/Right, In/Out, Roll In/Out, Finger Open/Close, Finger In/Out).
# Coefficient magnitudes are first-cut estimates; refine on visual review
# rather than rebuilding the dispatch.

const KEY_OPEN_CLOSE: StringName = &"open_close"
const KEY_LEFT_RIGHT: StringName = &"left_right"
const KEY_ROLL_LEFT_RIGHT: StringName = &"roll_left_right"
const KEY_IN_OUT: StringName = &"in_out"
const KEY_ROLL_IN_OUT: StringName = &"roll_in_out"
const KEY_FINGER_OPEN_CLOSE: StringName = &"finger_open_close"
const KEY_FINGER_IN_OUT: StringName = &"finger_in_out"

# Anatomical-axis macros: one slider per (region group, anatomical axis).
# Drives every SPD-eligible bone in the group along the named axis. Bones
# with zero ROM contribute nothing (apply_coefficient returns 0), so FIXED /
# locked-axis bones are silently inert.
const KEY_ALL_FLEX_EXT: StringName = &"all_flex_ext"
const KEY_ALL_MED_LAT: StringName = &"all_med_lat"
const KEY_ALL_ABD_ADD: StringName = &"all_abd_add"
const KEY_ARMS_FLEX_EXT: StringName = &"arms_flex_ext"
const KEY_ARMS_MED_LAT: StringName = &"arms_med_lat"
const KEY_ARMS_ABD_ADD: StringName = &"arms_abd_add"
const KEY_LEGS_FLEX_EXT: StringName = &"legs_flex_ext"
const KEY_LEGS_MED_LAT: StringName = &"legs_med_lat"
const KEY_LEGS_ABD_ADD: StringName = &"legs_abd_add"
const KEY_HANDS_FLEX_EXT: StringName = &"hands_flex_ext"
const KEY_HANDS_MED_LAT: StringName = &"hands_med_lat"
const KEY_HANDS_ABD_ADD: StringName = &"hands_abd_add"
const KEY_FEET_FLEX_EXT: StringName = &"feet_flex_ext"
const KEY_FEET_MED_LAT: StringName = &"feet_med_lat"
const KEY_FEET_ABD_ADD: StringName = &"feet_abd_add"
const KEY_BODY_FLEX_EXT: StringName = &"body_flex_ext"
const KEY_BODY_MED_LAT: StringName = &"body_med_lat"
const KEY_BODY_ABD_ADD: StringName = &"body_abd_add"

# Macro groups. Each maps to a section header in the muscle-test dock and
# to a list of macro keys. Order is the section render order.
const GROUP_UNITY: StringName = &"unity"
const GROUP_ALL: StringName = &"all"
const GROUP_ARMS: StringName = &"arms"
const GROUP_LEGS: StringName = &"legs"
const GROUP_HANDS: StringName = &"hands"
const GROUP_FEET: StringName = &"feet"
const GROUP_BODY: StringName = &"body"

const GROUP_ORDER: Array[StringName] = [
	GROUP_UNITY,
	GROUP_ALL,
	GROUP_ARMS,
	GROUP_LEGS,
	GROUP_HANDS,
	GROUP_FEET,
	GROUP_BODY,
]

const GROUP_LABELS: Dictionary[StringName, String] = {
	GROUP_UNITY: "Unity-style",
	GROUP_ALL: "All Muscles",
	GROUP_ARMS: "Arms",
	GROUP_LEGS: "Legs",
	GROUP_HANDS: "Hands",
	GROUP_FEET: "Feet",
	GROUP_BODY: "Body",
}

const GROUP_KEYS: Dictionary[StringName, Array] = {
	GROUP_UNITY: [
		KEY_OPEN_CLOSE,
		KEY_LEFT_RIGHT,
		KEY_ROLL_LEFT_RIGHT,
		KEY_IN_OUT,
		KEY_ROLL_IN_OUT,
		KEY_FINGER_OPEN_CLOSE,
		KEY_FINGER_IN_OUT,
	],
	GROUP_ALL: [KEY_ALL_FLEX_EXT, KEY_ALL_MED_LAT, KEY_ALL_ABD_ADD],
	GROUP_ARMS: [KEY_ARMS_FLEX_EXT, KEY_ARMS_MED_LAT, KEY_ARMS_ABD_ADD],
	GROUP_LEGS: [KEY_LEGS_FLEX_EXT, KEY_LEGS_MED_LAT, KEY_LEGS_ABD_ADD],
	GROUP_HANDS: [KEY_HANDS_FLEX_EXT, KEY_HANDS_MED_LAT, KEY_HANDS_ABD_ADD],
	GROUP_FEET: [KEY_FEET_FLEX_EXT, KEY_FEET_MED_LAT, KEY_FEET_ABD_ADD],
	GROUP_BODY: [KEY_BODY_FLEX_EXT, KEY_BODY_MED_LAT, KEY_BODY_ABD_ADD],
}

# ORDER kept for back-compat (any code that needs the flat list of all macro
# keys). New code should iterate GROUP_ORDER → GROUP_KEYS instead.
const ORDER: Array[StringName] = [
	KEY_OPEN_CLOSE,
	KEY_LEFT_RIGHT,
	KEY_ROLL_LEFT_RIGHT,
	KEY_IN_OUT,
	KEY_ROLL_IN_OUT,
	KEY_FINGER_OPEN_CLOSE,
	KEY_FINGER_IN_OUT,
	KEY_ALL_FLEX_EXT,
	KEY_ALL_MED_LAT,
	KEY_ALL_ABD_ADD,
	KEY_ARMS_FLEX_EXT,
	KEY_ARMS_MED_LAT,
	KEY_ARMS_ABD_ADD,
	KEY_LEGS_FLEX_EXT,
	KEY_LEGS_MED_LAT,
	KEY_LEGS_ABD_ADD,
	KEY_HANDS_FLEX_EXT,
	KEY_HANDS_MED_LAT,
	KEY_HANDS_ABD_ADD,
	KEY_FEET_FLEX_EXT,
	KEY_FEET_MED_LAT,
	KEY_FEET_ABD_ADD,
	KEY_BODY_FLEX_EXT,
	KEY_BODY_MED_LAT,
	KEY_BODY_ABD_ADD,
]

const LABELS: Dictionary[StringName, String] = {
	KEY_OPEN_CLOSE: "Open ↔ Close",
	KEY_LEFT_RIGHT: "Left ↔ Right",
	KEY_ROLL_LEFT_RIGHT: "Roll Left ↔ Right",
	KEY_IN_OUT: "In ↔ Out",
	KEY_ROLL_IN_OUT: "Roll In ↔ Out",
	KEY_FINGER_OPEN_CLOSE: "Finger Open ↔ Close",
	KEY_FINGER_IN_OUT: "Finger In ↔ Out",
	# Within each group's section the section header gives region context, so
	# the per-slider label is just the anatomical axis pair.
	KEY_ALL_FLEX_EXT: "Flex ↔ Ext",
	KEY_ALL_MED_LAT: "Med ↔ Lat",
	KEY_ALL_ABD_ADD: "Abd ↔ Add",
	KEY_ARMS_FLEX_EXT: "Flex ↔ Ext",
	KEY_ARMS_MED_LAT: "Med ↔ Lat",
	KEY_ARMS_ABD_ADD: "Abd ↔ Add",
	KEY_LEGS_FLEX_EXT: "Flex ↔ Ext",
	KEY_LEGS_MED_LAT: "Med ↔ Lat",
	KEY_LEGS_ABD_ADD: "Abd ↔ Add",
	KEY_HANDS_FLEX_EXT: "Flex ↔ Ext",
	KEY_HANDS_MED_LAT: "Med ↔ Lat",
	KEY_HANDS_ABD_ADD: "Abd ↔ Add",
	KEY_FEET_FLEX_EXT: "Flex ↔ Ext",
	KEY_FEET_MED_LAT: "Med ↔ Lat",
	KEY_FEET_ABD_ADD: "Abd ↔ Add",
	KEY_BODY_FLEX_EXT: "Flex ↔ Ext",
	KEY_BODY_MED_LAT: "Med ↔ Lat",
	KEY_BODY_ABD_ADD: "Abd ↔ Add",
}

# Anatomical axis index (matches Vector3 component / BoneEntry.rom_min layout):
# 0 = flex/ext (X), 1 = med/lat (Y), 2 = abd/add (Z).
const _AXIS_FLEX: int = 0
const _AXIS_MED: int = 1
const _AXIS_ABD: int = 2

# Region sets per group. Built once at first use to avoid repeated typing.
const _REGIONS_ARMS: Array[int] = [MarionetteBoneRegion.Region.LEFT_ARM, MarionetteBoneRegion.Region.RIGHT_ARM]
const _REGIONS_LEGS: Array[int] = [MarionetteBoneRegion.Region.LEFT_LEG, MarionetteBoneRegion.Region.RIGHT_LEG]
const _REGIONS_HANDS: Array[int] = [MarionetteBoneRegion.Region.LEFT_HAND, MarionetteBoneRegion.Region.RIGHT_HAND]
const _REGIONS_FEET: Array[int] = [MarionetteBoneRegion.Region.LEFT_FOOT, MarionetteBoneRegion.Region.RIGHT_FOOT]
const _REGIONS_BODY: Array[int] = [MarionetteBoneRegion.Region.SPINE, MarionetteBoneRegion.Region.HEAD_NECK]


# Returns coefficient table for the given macro key. Bone names absent from
# the table are unaffected. Each Vector3 = (flex_coeff, rot_coeff, abd_coeff)
# in [-1, 1].
# Memoized influence tables. Each macro key's coefficient table is fully
# determined by the static bone-region mapping, so building it once per
# session avoids the 80×N dict rebuilds per slider drag that the macro
# section was generating before — single biggest source of macro-slider lag
# on the muscle-test dock.
static var _influences_cache: Dictionary[StringName, Dictionary] = {}


static func influences_for(key: StringName) -> Dictionary[StringName, Vector3]:
	if _influences_cache.has(key):
		return _influences_cache[key]
	var result: Dictionary[StringName, Vector3] = _build_influences(key)
	_influences_cache[key] = result
	return result


static func _build_influences(key: StringName) -> Dictionary[StringName, Vector3]:
	match key:
		KEY_OPEN_CLOSE:
			return _open_close()
		KEY_LEFT_RIGHT:
			return _left_right()
		KEY_ROLL_LEFT_RIGHT:
			return _roll_left_right()
		KEY_IN_OUT:
			return _in_out()
		KEY_ROLL_IN_OUT:
			return _roll_in_out()
		KEY_FINGER_OPEN_CLOSE:
			return _finger_open_close()
		KEY_FINGER_IN_OUT:
			return _finger_in_out()
		# All-muscle axis macros: every region-mapped bone gets the axis coeff.
		KEY_ALL_FLEX_EXT:
			return _axis_for_regions([], _AXIS_FLEX)
		KEY_ALL_MED_LAT:
			return _axis_for_regions([], _AXIS_MED)
		KEY_ALL_ABD_ADD:
			return _axis_for_regions([], _AXIS_ABD)
		KEY_ARMS_FLEX_EXT:
			return _axis_for_regions(_REGIONS_ARMS, _AXIS_FLEX)
		KEY_ARMS_MED_LAT:
			return _axis_for_regions(_REGIONS_ARMS, _AXIS_MED)
		KEY_ARMS_ABD_ADD:
			return _axis_for_regions(_REGIONS_ARMS, _AXIS_ABD)
		KEY_LEGS_FLEX_EXT:
			return _axis_for_regions(_REGIONS_LEGS, _AXIS_FLEX)
		KEY_LEGS_MED_LAT:
			return _axis_for_regions(_REGIONS_LEGS, _AXIS_MED)
		KEY_LEGS_ABD_ADD:
			return _axis_for_regions(_REGIONS_LEGS, _AXIS_ABD)
		KEY_HANDS_FLEX_EXT:
			return _axis_for_regions(_REGIONS_HANDS, _AXIS_FLEX)
		KEY_HANDS_MED_LAT:
			return _axis_for_regions(_REGIONS_HANDS, _AXIS_MED)
		KEY_HANDS_ABD_ADD:
			return _axis_for_regions(_REGIONS_HANDS, _AXIS_ABD)
		KEY_FEET_FLEX_EXT:
			return _axis_for_regions(_REGIONS_FEET, _AXIS_FLEX)
		KEY_FEET_MED_LAT:
			return _axis_for_regions(_REGIONS_FEET, _AXIS_MED)
		KEY_FEET_ABD_ADD:
			return _axis_for_regions(_REGIONS_FEET, _AXIS_ABD)
		KEY_BODY_FLEX_EXT:
			return _axis_for_regions(_REGIONS_BODY, _AXIS_FLEX)
		KEY_BODY_MED_LAT:
			return _axis_for_regions(_REGIONS_BODY, _AXIS_MED)
		KEY_BODY_ABD_ADD:
			return _axis_for_regions(_REGIONS_BODY, _AXIS_ABD)
	var empty: Dictionary[StringName, Vector3] = {}
	return empty


static func label_for(key: StringName) -> String:
	return LABELS.get(key, String(key))


static func group_label_for(group: StringName) -> String:
	return GROUP_LABELS.get(group, String(group))


# Returns the macro keys that belong to `group`, in the order they should be
# rendered. Empty array if `group` is unknown.
static func keys_for_group(group: StringName) -> Array:
	return GROUP_KEYS.get(group, [])


# Returns an influence table where every region-mapped bone in any of
# `region_filter` (or every mapped bone if the array is empty) gets coeff 1.0
# on the named anatomical axis (and 0 on the other two). Used by the All /
# Arms / Legs / Hands / Feet / Body axis macros so they pick up every bone in
# their scope automatically — including bones we add to the profile later.
# Bones with zero ROM contribute nothing at compose time (apply_coefficient
# bottoms out at 0), so locked / FIXED bones don't pollute the result.
static func _axis_for_regions(region_filter: Array[int], axis: int) -> Dictionary[StringName, Vector3]:
	var coeff := Vector3.ZERO
	if axis >= 0 and axis < 3:
		coeff[axis] = 1.0
	var d: Dictionary[StringName, Vector3] = {}
	for bone_name: StringName in MarionetteBoneRegion.all_mapped_bones():
		if region_filter.is_empty() or region_filter.has(MarionetteBoneRegion.region_for(bone_name)):
			d[bone_name] = coeff
	return d


# Maps a normalized signed value (slider × coeff) to an anatomical-axis
# offset using the bone's ROM bounds. Positive maps to `rom_max`, negative
# to `|rom_min|`. Result is clamped to ROM at the extremes by definition.
static func apply_coefficient(signed_v: float, rom_min: float, rom_max: float) -> float:
	if signed_v >= 0.0:
		return signed_v * maxf(rom_max, 0.0)
	return signed_v * maxf(-rom_min, 0.0)


# Composes a per-bone anatomical offset from all currently-active macro
# slider values. `macro_values` is the dock's Dictionary[macro_key, float].
static func compose_offset(bone_name: StringName, rom_min: Vector3, rom_max: Vector3,
		macro_values: Dictionary) -> Vector3:
	var offset := Vector3.ZERO
	for key: StringName in macro_values.keys():
		var v: float = macro_values[key]
		if absf(v) < 0.0001:
			continue
		var influences: Dictionary[StringName, Vector3] = influences_for(key)
		if not influences.has(bone_name):
			continue
		var c: Vector3 = influences[bone_name]
		offset.x += apply_coefficient(v * c.x, rom_min.x, rom_max.x)
		offset.y += apply_coefficient(v * c.y, rom_min.y, rom_max.y)
		offset.z += apply_coefficient(v * c.z, rom_min.z, rom_max.z)
	return offset


# --- Per-macro coefficient tables ---
# Slider at +1 corresponds to the second word of the label (Close, Right,
# Out, etc.); -1 to the first (Open, Left, In). Coefficients chosen so the
# whole body reaches a recognizable pose at ±1 without exceeding ROM.

static func _open_close() -> Dictionary[StringName, Vector3]:
	# +1 = closed/fetal: spine + neck curl forward, shoulders + hips flex,
	# elbows + knees fold, wrists drop, ankles plantarflex.
	var d: Dictionary[StringName, Vector3] = {}
	# Spine — modest per-segment so the whole stack adds to a noticeable curl.
	d[&"Spine"] = Vector3(0.6, 0.0, 0.0)
	d[&"Chest"] = Vector3(0.6, 0.0, 0.0)
	d[&"UpperChest"] = Vector3(0.6, 0.0, 0.0)
	d[&"Neck"] = Vector3(0.7, 0.0, 0.0)
	d[&"Head"] = Vector3(0.6, 0.0, 0.0)
	# Shoulders + elbows fold across the body.
	d[&"LeftUpperArm"] = Vector3(0.7, 0.0, 0.0)
	d[&"RightUpperArm"] = Vector3(0.7, 0.0, 0.0)
	d[&"LeftLowerArm"] = Vector3(1.0, 0.0, 0.0)
	d[&"RightLowerArm"] = Vector3(1.0, 0.0, 0.0)
	d[&"LeftHand"] = Vector3(0.5, 0.0, 0.0)
	d[&"RightHand"] = Vector3(0.5, 0.0, 0.0)
	# Hips + knees pull legs to chest.
	d[&"LeftUpperLeg"] = Vector3(0.9, 0.0, 0.0)
	d[&"RightUpperLeg"] = Vector3(0.9, 0.0, 0.0)
	d[&"LeftLowerLeg"] = Vector3(1.0, 0.0, 0.0)
	d[&"RightLowerLeg"] = Vector3(1.0, 0.0, 0.0)
	# Ankles plantarflex (toes pointed) — flex axis is dorsiflexion-positive,
	# so plantarflex requires a negative coeff.
	d[&"LeftFoot"] = Vector3(-0.6, 0.0, 0.0)
	d[&"RightFoot"] = Vector3(-0.6, 0.0, 0.0)
	return d


static func _left_right() -> Dictionary[StringName, Vector3]:
	# +1 = bend right (lateral flexion of trunk + neck about abduction axis).
	# Each spine segment contributes a small share of the total side-bend.
	var d: Dictionary[StringName, Vector3] = {}
	d[&"Spine"] = Vector3(0.0, 0.0, 0.5)
	d[&"Chest"] = Vector3(0.0, 0.0, 0.5)
	d[&"UpperChest"] = Vector3(0.0, 0.0, 0.5)
	d[&"Neck"] = Vector3(0.0, 0.0, 0.5)
	d[&"Head"] = Vector3(0.0, 0.0, 0.5)
	return d


static func _roll_left_right() -> Dictionary[StringName, Vector3]:
	# +1 = twist right (axial rotation of trunk + neck about long axis).
	var d: Dictionary[StringName, Vector3] = {}
	d[&"Spine"] = Vector3(0.0, 0.5, 0.0)
	d[&"Chest"] = Vector3(0.0, 0.5, 0.0)
	d[&"UpperChest"] = Vector3(0.0, 0.5, 0.0)
	d[&"Neck"] = Vector3(0.0, 0.5, 0.0)
	d[&"Head"] = Vector3(0.0, 0.5, 0.0)
	return d


static func _in_out() -> Dictionary[StringName, Vector3]:
	# +1 = limbs out (T-pose / wide stance). Shoulder + hip abduct away from
	# the midline; -1 brings limbs to the body's centerline. Sign-aligned
	# convention: +Z = abduction (away from midline) on both sides.
	var d: Dictionary[StringName, Vector3] = {}
	d[&"LeftUpperArm"] = Vector3(0.0, 0.0, 1.0)
	d[&"RightUpperArm"] = Vector3(0.0, 0.0, 1.0)
	d[&"LeftUpperLeg"] = Vector3(0.0, 0.0, 1.0)
	d[&"RightUpperLeg"] = Vector3(0.0, 0.0, 1.0)
	# Clavicles add a touch of follow-through so the arms don't pivot from
	# the bare humerus.
	d[&"LeftShoulder"] = Vector3(0.0, 0.0, 0.4)
	d[&"RightShoulder"] = Vector3(0.0, 0.0, 0.4)
	return d


static func _roll_in_out() -> Dictionary[StringName, Vector3]:
	# +1 = externally rotated (palms back, knees flared). External rotation
	# is opposite of medial rotation, so the coeff is negative on +Y.
	var d: Dictionary[StringName, Vector3] = {}
	d[&"LeftUpperArm"] = Vector3(0.0, -1.0, 0.0)
	d[&"RightUpperArm"] = Vector3(0.0, -1.0, 0.0)
	d[&"LeftUpperLeg"] = Vector3(0.0, -1.0, 0.0)
	d[&"RightUpperLeg"] = Vector3(0.0, -1.0, 0.0)
	# Forearm pronation is a follow-through on the same axis where ROM allows.
	d[&"LeftLowerArm"] = Vector3(0.0, -0.5, 0.0)
	d[&"RightLowerArm"] = Vector3(0.0, -0.5, 0.0)
	return d


static func _finger_open_close() -> Dictionary[StringName, Vector3]:
	# +1 = closed fist (every phalanx flexes). All finger bones use
	# +X = flexion, so coeff = +1. Thumb metacarpal opposes via flex too.
	var d: Dictionary[StringName, Vector3] = {}
	for side: String in ["Left", "Right"]:
		d[StringName("%sThumbMetacarpal" % side)] = Vector3(0.6, 0.0, 0.0)
		d[StringName("%sThumbProximal" % side)] = Vector3(1.0, 0.0, 0.0)
		d[StringName("%sThumbDistal" % side)] = Vector3(1.0, 0.0, 0.0)
		for finger: String in ["Index", "Middle", "Ring", "Little"]:
			d[StringName("%s%sProximal" % [side, finger])] = Vector3(1.0, 0.0, 0.0)
			d[StringName("%s%sIntermediate" % [side, finger])] = Vector3(1.0, 0.0, 0.0)
			d[StringName("%s%sDistal" % [side, finger])] = Vector3(1.0, 0.0, 0.0)
	return d


static func _finger_in_out() -> Dictionary[StringName, Vector3]:
	# +1 = fingers spread apart (abduction at MCP / thumb metacarpal).
	# Saddle joints carry the abduction DOF; intermediate / distal phalanges
	# are pure hinges and don't participate.
	var d: Dictionary[StringName, Vector3] = {}
	for side: String in ["Left", "Right"]:
		d[StringName("%sThumbMetacarpal" % side)] = Vector3(0.0, 0.0, 1.0)
		for finger: String in ["Index", "Middle", "Ring", "Little"]:
			d[StringName("%s%sProximal" % [side, finger])] = Vector3(0.0, 0.0, 1.0)
	return d
