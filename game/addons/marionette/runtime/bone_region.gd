@tool
class_name MarionetteBoneRegion
extends RefCounted

# Anatomical region classifier for the Muscle Test dock (P4.3). Maps every
# bone in MarionetteHumanoidProfile to one of ten regions; unrecognized
# bones fall into OTHER so a non-humanoid skeleton still slots in.
#
# Regions match the Marionette plan P4.3 ordering and are rendered in ORDER.

enum Region {
	SPINE,
	HEAD_NECK,
	LEFT_ARM,
	RIGHT_ARM,
	LEFT_HAND,
	RIGHT_HAND,
	LEFT_LEG,
	RIGHT_LEG,
	LEFT_FOOT,
	RIGHT_FOOT,
	OTHER,
}

const ORDER: Array[int] = [
	Region.SPINE,
	Region.HEAD_NECK,
	Region.LEFT_ARM,
	Region.RIGHT_ARM,
	Region.LEFT_HAND,
	Region.RIGHT_HAND,
	Region.LEFT_LEG,
	Region.RIGHT_LEG,
	Region.LEFT_FOOT,
	Region.RIGHT_FOOT,
	Region.OTHER,
]

const LABELS: Dictionary[int, String] = {
	Region.SPINE: "Spine",
	Region.HEAD_NECK: "Head / Neck",
	Region.LEFT_ARM: "Left Arm",
	Region.RIGHT_ARM: "Right Arm",
	Region.LEFT_HAND: "Left Hand",
	Region.RIGHT_HAND: "Right Hand",
	Region.LEFT_LEG: "Left Leg",
	Region.RIGHT_LEG: "Right Leg",
	Region.LEFT_FOOT: "Left Foot",
	Region.RIGHT_FOOT: "Right Foot",
	Region.OTHER: "Other",
}

const _BY_BONE: Dictionary[StringName, int] = {
	# --- Spine + base ---
	&"Root": Region.SPINE,
	&"Hips": Region.SPINE,
	&"Spine": Region.SPINE,
	&"Chest": Region.SPINE,
	&"UpperChest": Region.SPINE,

	# --- Head + face (Jaw + eyes are kinematic but render here for visibility) ---
	&"Neck": Region.HEAD_NECK,
	&"Head": Region.HEAD_NECK,
	&"Jaw": Region.HEAD_NECK,
	&"LeftEye": Region.HEAD_NECK,
	&"RightEye": Region.HEAD_NECK,

	# --- Left arm (shoulder → elbow) ---
	&"LeftShoulder": Region.LEFT_ARM,
	&"LeftUpperArm": Region.LEFT_ARM,
	&"LeftLowerArm": Region.LEFT_ARM,

	# --- Left hand (wrist + 15 finger bones) ---
	&"LeftHand": Region.LEFT_HAND,
	&"LeftThumbMetacarpal": Region.LEFT_HAND,
	&"LeftThumbProximal": Region.LEFT_HAND,
	&"LeftThumbDistal": Region.LEFT_HAND,
	&"LeftIndexProximal": Region.LEFT_HAND,
	&"LeftIndexIntermediate": Region.LEFT_HAND,
	&"LeftIndexDistal": Region.LEFT_HAND,
	&"LeftMiddleProximal": Region.LEFT_HAND,
	&"LeftMiddleIntermediate": Region.LEFT_HAND,
	&"LeftMiddleDistal": Region.LEFT_HAND,
	&"LeftRingProximal": Region.LEFT_HAND,
	&"LeftRingIntermediate": Region.LEFT_HAND,
	&"LeftRingDistal": Region.LEFT_HAND,
	&"LeftLittleProximal": Region.LEFT_HAND,
	&"LeftLittleIntermediate": Region.LEFT_HAND,
	&"LeftLittleDistal": Region.LEFT_HAND,

	# --- Right arm ---
	&"RightShoulder": Region.RIGHT_ARM,
	&"RightUpperArm": Region.RIGHT_ARM,
	&"RightLowerArm": Region.RIGHT_ARM,

	# --- Right hand ---
	&"RightHand": Region.RIGHT_HAND,
	&"RightThumbMetacarpal": Region.RIGHT_HAND,
	&"RightThumbProximal": Region.RIGHT_HAND,
	&"RightThumbDistal": Region.RIGHT_HAND,
	&"RightIndexProximal": Region.RIGHT_HAND,
	&"RightIndexIntermediate": Region.RIGHT_HAND,
	&"RightIndexDistal": Region.RIGHT_HAND,
	&"RightMiddleProximal": Region.RIGHT_HAND,
	&"RightMiddleIntermediate": Region.RIGHT_HAND,
	&"RightMiddleDistal": Region.RIGHT_HAND,
	&"RightRingProximal": Region.RIGHT_HAND,
	&"RightRingIntermediate": Region.RIGHT_HAND,
	&"RightRingDistal": Region.RIGHT_HAND,
	&"RightLittleProximal": Region.RIGHT_HAND,
	&"RightLittleIntermediate": Region.RIGHT_HAND,
	&"RightLittleDistal": Region.RIGHT_HAND,

	# --- Left leg (hip → knee) ---
	&"LeftUpperLeg": Region.LEFT_LEG,
	&"LeftLowerLeg": Region.LEFT_LEG,

	# --- Left foot (ankle + Toes compound + 14 toe bones) ---
	&"LeftFoot": Region.LEFT_FOOT,
	&"LeftToes": Region.LEFT_FOOT,
	&"LeftBigToeProximal": Region.LEFT_FOOT,
	&"LeftBigToeDistal": Region.LEFT_FOOT,
	&"LeftToe2Proximal": Region.LEFT_FOOT,
	&"LeftToe2Intermediate": Region.LEFT_FOOT,
	&"LeftToe2Distal": Region.LEFT_FOOT,
	&"LeftToe3Proximal": Region.LEFT_FOOT,
	&"LeftToe3Intermediate": Region.LEFT_FOOT,
	&"LeftToe3Distal": Region.LEFT_FOOT,
	&"LeftToe4Proximal": Region.LEFT_FOOT,
	&"LeftToe4Intermediate": Region.LEFT_FOOT,
	&"LeftToe4Distal": Region.LEFT_FOOT,
	&"LeftToe5Proximal": Region.LEFT_FOOT,
	&"LeftToe5Intermediate": Region.LEFT_FOOT,
	&"LeftToe5Distal": Region.LEFT_FOOT,

	# --- Right leg ---
	&"RightUpperLeg": Region.RIGHT_LEG,
	&"RightLowerLeg": Region.RIGHT_LEG,

	# --- Right foot ---
	&"RightFoot": Region.RIGHT_FOOT,
	&"RightToes": Region.RIGHT_FOOT,
	&"RightBigToeProximal": Region.RIGHT_FOOT,
	&"RightBigToeDistal": Region.RIGHT_FOOT,
	&"RightToe2Proximal": Region.RIGHT_FOOT,
	&"RightToe2Intermediate": Region.RIGHT_FOOT,
	&"RightToe2Distal": Region.RIGHT_FOOT,
	&"RightToe3Proximal": Region.RIGHT_FOOT,
	&"RightToe3Intermediate": Region.RIGHT_FOOT,
	&"RightToe3Distal": Region.RIGHT_FOOT,
	&"RightToe4Proximal": Region.RIGHT_FOOT,
	&"RightToe4Intermediate": Region.RIGHT_FOOT,
	&"RightToe4Distal": Region.RIGHT_FOOT,
	&"RightToe5Proximal": Region.RIGHT_FOOT,
	&"RightToe5Intermediate": Region.RIGHT_FOOT,
	&"RightToe5Distal": Region.RIGHT_FOOT,
}


static func region_for(bone_name: StringName) -> int:
	return _BY_BONE.get(bone_name, Region.OTHER)


static func label_for(region: int) -> String:
	return LABELS.get(region, "Region")


static func has_mapping_for(bone_name: StringName) -> bool:
	return _BY_BONE.has(bone_name)
