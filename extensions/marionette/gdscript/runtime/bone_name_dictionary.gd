@tool
class_name BoneNameDictionary
extends RefCounted

## Per-convention dictionaries mapping `MarionetteHumanoidProfile` slot names
## to expected source-bone names. Source of truth: `docs/marionette/arp_mapping.md`
## for ARP, real-rig listings under `game/tests/marionette/skeletons/` for
## Mixamo / Rigify / godot_ARP.
##
## Conventions covered:
##   - arp_standard  : ARP "Game Engine Export", `.l/.r/.x` suffix.
##   - arp_ue        : ARP "UE Humanoid" preset, `_l/_r` suffix.
##   - mixamo        : Adobe Mixamo, `mixamorig_LeftX` PascalCase.
##   - rigify        : Blender Rigify deform layer, `DEF-X.L/.R`.
##   - bip01         : 3DS Max biped (Unity legacy), `Bip01_L_X` infix.
##   - godot_native  : `SkeletonProfileHumanoid` 1:1, `LeftX` PascalCase.
##
## A missing key for a (slot, convention) pair means the convention has no
## bone for that slot — e.g. Mixamo has no toe phalanges; Rigify has no
## finger metacarpals.

## All 84 slot names from `MarionetteHumanoidProfile`. Order matches the
## shipped `marionette_humanoid_bone_map.tres`. Stored as `Array[String]`
## because `PackedStringArray(...)` is not a constant expression in GDScript 4.6.
const SLOT_NAMES: Array[String] = [
	"Root", "Hips", "Spine", "Chest", "UpperChest", "Neck", "Head",
	"LeftEye", "RightEye", "Jaw",
	"LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand",
	"LeftThumbMetacarpal", "LeftThumbProximal", "LeftThumbDistal",
	"LeftIndexProximal", "LeftIndexIntermediate", "LeftIndexDistal",
	"LeftMiddleProximal", "LeftMiddleIntermediate", "LeftMiddleDistal",
	"LeftRingProximal", "LeftRingIntermediate", "LeftRingDistal",
	"LeftLittleProximal", "LeftLittleIntermediate", "LeftLittleDistal",
	"RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand",
	"RightThumbMetacarpal", "RightThumbProximal", "RightThumbDistal",
	"RightIndexProximal", "RightIndexIntermediate", "RightIndexDistal",
	"RightMiddleProximal", "RightMiddleIntermediate", "RightMiddleDistal",
	"RightRingProximal", "RightRingIntermediate", "RightRingDistal",
	"RightLittleProximal", "RightLittleIntermediate", "RightLittleDistal",
	"LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "LeftToes",
	"RightUpperLeg", "RightLowerLeg", "RightFoot", "RightToes",
	"LeftBigToeProximal", "LeftBigToeDistal",
	"LeftToe2Proximal", "LeftToe2Intermediate", "LeftToe2Distal",
	"LeftToe3Proximal", "LeftToe3Intermediate", "LeftToe3Distal",
	"LeftToe4Proximal", "LeftToe4Intermediate", "LeftToe4Distal",
	"LeftToe5Proximal", "LeftToe5Intermediate", "LeftToe5Distal",
	"RightBigToeProximal", "RightBigToeDistal",
	"RightToe2Proximal", "RightToe2Intermediate", "RightToe2Distal",
	"RightToe3Proximal", "RightToe3Intermediate", "RightToe3Distal",
	"RightToe4Proximal", "RightToe4Intermediate", "RightToe4Distal",
	"RightToe5Proximal", "RightToe5Intermediate", "RightToe5Distal",
]

const CONVENTIONS: Array[String] = [
	"arp_standard", "arp_ue", "mixamo", "rigify", "bip01", "godot_native",
]

# Slot → { convention → expected_source_bone_name }.
# Built lazily because GDScript dictionary literals can't reference each other.
static var _slot_dict: Dictionary = {}


static func slot_dict() -> Dictionary:
	if _slot_dict.is_empty():
		_slot_dict = _build_slot_dict()
	return _slot_dict


## All non-empty expected names across all conventions for a given slot.
## Used by the matcher as the candidate set to score against.
static func expected_names(slot: StringName) -> PackedStringArray:
	var d: Dictionary = slot_dict()
	var out: PackedStringArray = PackedStringArray()
	if not d.has(slot):
		return out
	var per_conv: Dictionary = d[slot]
	for conv: String in per_conv:
		var name: String = per_conv[conv]
		if not name.is_empty() and not out.has(name):
			out.append(name)
	return out


## Inverse lookup: which convention does this expected name belong to?
## Returns "" if not found. Used for telemetry only.
static func convention_for_expected_name(slot: StringName, expected_name: String) -> String:
	var d: Dictionary = slot_dict()
	if not d.has(slot):
		return ""
	var per_conv: Dictionary = d[slot]
	for conv: String in per_conv:
		if per_conv[conv] == expected_name:
			return conv
	return ""


static func _build_slot_dict() -> Dictionary:
	var d: Dictionary = {}

	# --- Body axis (7) ---
	d[&"Root"] = {}  # ARP `c_traj` is locomotion-only; intentionally unmapped.
	d[&"Hips"] = {
		"arp_standard": "root.x",
		"arp_ue": "pelvis",
		"mixamo": "mixamorig_Hips",
		"rigify": "DEF-spine",
		"bip01": "Bip01_Pelvis",
		"godot_native": "Hips",
	}
	d[&"Spine"] = {
		"arp_standard": "spine_01.x",
		"arp_ue": "spine_01",
		"mixamo": "mixamorig_Spine",
		"rigify": "DEF-spine.001",
		"bip01": "Bip01_Spine",
		"godot_native": "Spine",
	}
	d[&"Chest"] = {
		"arp_standard": "spine_02.x",
		"arp_ue": "spine_02",
		"mixamo": "mixamorig_Spine1",
		"rigify": "DEF-spine.002",
		"bip01": "Bip01_Spine1",
		"godot_native": "Chest",
	}
	d[&"UpperChest"] = {
		"arp_standard": "spine_03.x",
		"arp_ue": "spine_03",
		"mixamo": "mixamorig_Spine2",
		"rigify": "DEF-spine.003",
		"bip01": "Bip01_Spine2",
		"godot_native": "UpperChest",
	}
	d[&"Neck"] = {
		"arp_standard": "neck.x",
		"arp_ue": "neck_01",
		"mixamo": "mixamorig_Neck",
		"rigify": "DEF-spine.004",
		"bip01": "Bip01_Neck",
		"godot_native": "Neck",
	}
	d[&"Head"] = {
		"arp_standard": "head.x",
		"arp_ue": "head",
		"mixamo": "mixamorig_Head",
		"rigify": "DEF-spine.006",
		"bip01": "Bip01_Head",
		"godot_native": "Head",
	}

	# --- Face (3) — out of scope for Marionette but kept for retargeting. ---
	d[&"LeftEye"] = {
		"arp_ue": "eye_l",
		"godot_native": "LeftEye",
	}
	d[&"RightEye"] = {
		"arp_ue": "eye_r",
		"godot_native": "RightEye",
	}
	d[&"Jaw"] = {
		"arp_ue": "jaw",
		"godot_native": "Jaw",
	}

	# --- Arms (4 × 2) ---
	_register_sided(d, "Shoulder", {
		"arp_standard_l": "shoulder.l",
		"arp_ue_l": "clavicle_l",
		"mixamo_l": "mixamorig_LeftShoulder",
		"rigify_l": "DEF-shoulder.L",
		"bip01_l": "Bip01_L_Clavicle",
		"godot_native_l": "LeftShoulder",
	})
	_register_sided(d, "UpperArm", {
		"arp_standard_l": "arm_stretch.l",
		"arp_ue_l": "upperarm_l",
		"mixamo_l": "mixamorig_LeftArm",
		"rigify_l": "DEF-upper_arm.L",
		"bip01_l": "Bip01_L_UpperArm",
		"godot_native_l": "LeftUpperArm",
	})
	_register_sided(d, "LowerArm", {
		"arp_standard_l": "forearm_stretch.l",
		"arp_ue_l": "lowerarm_l",
		"mixamo_l": "mixamorig_LeftForeArm",
		"rigify_l": "DEF-forearm.L",
		"bip01_l": "Bip01_L_Forearm",
		"godot_native_l": "LeftLowerArm",
	})
	_register_sided(d, "Hand", {
		"arp_standard_l": "hand.l",
		"arp_ue_l": "hand_l",
		"mixamo_l": "mixamorig_LeftHand",
		"rigify_l": "DEF-hand.L",
		"bip01_l": "Bip01_L_Hand",
		"godot_native_l": "LeftHand",
	})

	# --- Fingers (15 × 2) ---
	# Naming notes per convention:
	#   ARP Standard fingers use `c_<finger>N.l` for all phalanges.
	#   Mixamo: thumb = HandThumb1/2/3 (metacarpal/prox/distal); other fingers
	#           HandIndex1/2/3 = prox/inter/distal (no metacarpal slot).
	#   Rigify: thumb.01/02/03 = metacarpal/prox/distal; f_<n>.01/02/03 =
	#           prox/inter/distal (no per-finger metacarpal exposed via DEF).
	#   Bip01: Finger0 chain = thumb (Finger0/01/02 = metacarpal/prox/distal);
	#          Finger1 = index, 2 = middle, 3 = ring, 4 = pinky (each 3 segs).
	_register_sided(d, "ThumbMetacarpal", {
		"arp_standard_l": "c_thumb1.l",
		"arp_ue_l": "thumb_01_l",
		"mixamo_l": "mixamorig_LeftHandThumb1",
		"rigify_l": "DEF-thumb.01.L",
		"bip01_l": "Bip01_L_Finger0",
		"godot_native_l": "LeftThumbMetacarpal",
	})
	_register_sided(d, "ThumbProximal", {
		"arp_standard_l": "c_thumb2.l",
		"arp_ue_l": "thumb_02_l",
		"mixamo_l": "mixamorig_LeftHandThumb2",
		"rigify_l": "DEF-thumb.02.L",
		"bip01_l": "Bip01_L_Finger01",
		"godot_native_l": "LeftThumbProximal",
	})
	_register_sided(d, "ThumbDistal", {
		"arp_standard_l": "c_thumb3.l",
		"arp_ue_l": "thumb_03_l",
		"mixamo_l": "mixamorig_LeftHandThumb3",
		"rigify_l": "DEF-thumb.03.L",
		"bip01_l": "Bip01_L_Finger02",
		"godot_native_l": "LeftThumbDistal",
	})
	_register_finger_chain(d, "Index", "index", "f_index", "Index", 1)
	_register_finger_chain(d, "Middle", "middle", "f_middle", "Middle", 2)
	_register_finger_chain(d, "Ring", "ring", "f_ring", "Ring", 3)
	_register_finger_chain(d, "Little", "pinky", "f_pinky", "Pinky", 4)

	# --- Legs (4 × 2) ---
	_register_sided(d, "UpperLeg", {
		"arp_standard_l": "thigh_stretch.l",
		"arp_ue_l": "thigh_l",
		"mixamo_l": "mixamorig_LeftUpLeg",
		"rigify_l": "DEF-thigh.L",
		"bip01_l": "Bip01_L_Thigh",
		"godot_native_l": "LeftUpperLeg",
	})
	_register_sided(d, "LowerLeg", {
		"arp_standard_l": "leg_stretch.l",
		"arp_ue_l": "calf_l",
		"mixamo_l": "mixamorig_LeftLeg",
		"rigify_l": "DEF-shin.L",
		"bip01_l": "Bip01_L_Calf",
		"godot_native_l": "LeftLowerLeg",
	})
	_register_sided(d, "Foot", {
		"arp_standard_l": "foot.l",
		"arp_ue_l": "foot_l",
		"mixamo_l": "mixamorig_LeftFoot",
		"rigify_l": "DEF-foot.L",
		"bip01_l": "Bip01_L_Foot",
		"godot_native_l": "LeftFoot",
	})
	_register_sided(d, "Toes", {
		"arp_ue_l": "ball_l",
		"mixamo_l": "mixamorig_LeftToeBase",
		"rigify_l": "DEF-toe.L",
		"bip01_l": "Bip01_L_Toe0",
		"godot_native_l": "LeftToes",
	})

	# --- Toe phalanges (14 × 2) ---
	# Only ARP Standard / ARP UE / godot_native have these. Mixamo / Rigify /
	# Bip01 don't expose per-toe phalanges.
	_register_toe(d, "BigToeProximal",      "c_toes_thumb1.l",  "big_toe_01_l",       "LeftBigToeProximal")
	_register_toe(d, "BigToeDistal",        "c_toes_thumb2.l",  "big_toe_02_l",       "LeftBigToeDistal")
	_register_toe(d, "Toe2Proximal",        "c_toes_index1.l",  "index_toe_01_l",     "LeftToe2Proximal")
	_register_toe(d, "Toe2Intermediate",    "c_toes_index2.l",  "index_toe_02_l",     "LeftToe2Intermediate")
	_register_toe(d, "Toe2Distal",          "c_toes_index3.l",  "index_toe_03_l",     "LeftToe2Distal")
	_register_toe(d, "Toe3Proximal",        "c_toes_middle1.l", "middle_toe_01_l",    "LeftToe3Proximal")
	_register_toe(d, "Toe3Intermediate",    "c_toes_middle2.l", "middle_toe_02_l",    "LeftToe3Intermediate")
	_register_toe(d, "Toe3Distal",          "c_toes_middle3.l", "middle_toe_03_l",    "LeftToe3Distal")
	_register_toe(d, "Toe4Proximal",        "c_toes_ring1.l",   "ring_toe_01_l",      "LeftToe4Proximal")
	_register_toe(d, "Toe4Intermediate",    "c_toes_ring2.l",   "ring_toe_02_l",      "LeftToe4Intermediate")
	_register_toe(d, "Toe4Distal",          "c_toes_ring3.l",   "ring_toe_03_l",      "LeftToe4Distal")
	_register_toe(d, "Toe5Proximal",        "c_toes_pinky1.l",  "pinky_toe_01_l",     "LeftToe5Proximal")
	_register_toe(d, "Toe5Intermediate",    "c_toes_pinky2.l",  "pinky_toe_02_l",     "LeftToe5Intermediate")
	_register_toe(d, "Toe5Distal",          "c_toes_pinky3.l",  "pinky_toe_03_l",     "LeftToe5Distal")

	return d


# Helper: register a slot pair that has a Left/Right side. The `_l`-suffixed
# entries describe the LEFT side; the RIGHT side is built by mirroring naming
# rules (`.l → .r`, `_l → _r`, `Left → Right`, `.L → .R`).
static func _register_sided(d: Dictionary, slot_suffix: String, left_entries: Dictionary) -> void:
	var left_slot: StringName = StringName("Left" + slot_suffix)
	var right_slot: StringName = StringName("Right" + slot_suffix)
	var left_dict: Dictionary = {}
	var right_dict: Dictionary = {}
	for k: String in left_entries:
		var conv: String = k.trim_suffix("_l")
		var left_name: String = left_entries[k]
		left_dict[conv] = left_name
		right_dict[conv] = _mirror_l_to_r(left_name)
	d[left_slot] = left_dict
	d[right_slot] = right_dict


static func _register_finger_chain(d: Dictionary, slot_root: String,
		arp_token: String, rigify_token: String, mixamo_token: String,
		bip01_finger_index: int) -> void:
	# Marionette has Proximal / Intermediate / Distal for non-thumb fingers
	# (no per-finger metacarpal slot).
	for i: int in 3:
		var phalanx: String = ["Proximal", "Intermediate", "Distal"][i]
		var arp_n: int = i + 1  # ARP uses 1/2/3
		var rigify_n: int = i + 1  # Rigify uses 01/02/03 → matches digit
		var mixamo_n: int = i + 1  # Mixamo uses 1/2/3
		var bip01_suffix: String  # Finger1 / 11 / 12 (proximal/intermediate/distal)
		match i:
			0: bip01_suffix = str(bip01_finger_index)
			1: bip01_suffix = "%d1" % bip01_finger_index
			2: bip01_suffix = "%d2" % bip01_finger_index
		_register_sided(d, slot_root + phalanx, {
			"arp_standard_l": "c_%s%d.l" % [arp_token, arp_n],
			"arp_ue_l": "%s_0%d_l" % [arp_token, arp_n],
			"mixamo_l": "mixamorig_LeftHand%s%d" % [mixamo_token, mixamo_n],
			"rigify_l": "DEF-%s.0%d.L" % [rigify_token, rigify_n],
			"bip01_l": "Bip01_L_Finger%s" % bip01_suffix,
			"godot_native_l": "Left%s%s" % [slot_root, phalanx],
		})


static func _register_toe(d: Dictionary, slot_suffix: String,
		arp_l: String, arp_ue_l: String, godot_l: String) -> void:
	_register_sided(d, slot_suffix, {
		"arp_standard_l": arp_l,
		"arp_ue_l": arp_ue_l,
		"godot_native_l": godot_l,
	})


static func _mirror_l_to_r(name: String) -> String:
	# Suffix patterns first (most specific — applied as exact suffix match).
	for rule: Array in [[".l", ".r"], [".L", ".R"], ["_l", "_r"],
			["_left", "_right"], ["_Left", "_Right"]]:
		if name.ends_with(rule[0]):
			return name.substr(0, name.length() - rule[0].length()) + rule[1]
	# Infix patterns (Bip01 `_L_` style).
	for rule: Array in [["_L_", "_R_"], ["_l_", "_r_"]]:
		var idx_i: int = name.find(rule[0])
		if idx_i >= 0:
			return name.substr(0, idx_i) + rule[1] + name.substr(idx_i + rule[0].length())
	# Word-boundary Left → Right (prefix or after non-letter — handles both
	# `LeftFoot` and `mixamorig_LeftArm`).
	for rule: Array in [["Left", "Right"], ["left", "right"]]:
		var from: String = rule[0]
		var to: String = rule[1]
		var idx: int = name.find(from)
		while idx >= 0:
			var word_boundary: bool = idx == 0 or not _is_letter(name[idx - 1])
			if word_boundary:
				return name.substr(0, idx) + to + name.substr(idx + from.length())
			idx = name.find(from, idx + 1)
	return name  # No side marker — return as-is (center bones).


static func _is_letter(c: String) -> bool:
	return c.length() == 1 and ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z"))
