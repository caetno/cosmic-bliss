@tool
class_name MarionetteArchetypeDefaults
extends RefCounted

# Default bone-name → archetype map for MarionetteHumanoidProfile (84 bones).
# Each entry classifies the joint connecting the bone to its parent.
#
# Per Marionette_plan P2.5:
#   - Hinges: elbows, knees, finger/toe phalanges except proximal
#   - Ball: shoulders (UpperArm), hips (UpperLeg)
#   - Saddle: wrists (Hand), ankles (Foot), plus thumb metacarpal and the
#     proximal MCP/MTP joints (2-DOF flex+abduction)
#   - Clavicle: shoulders (Shoulder bone, the clavicle connector)
#   - SpineSegment: spine, neck, head
#   - Pivot: (none default in humanoid; reserved)
#   - Root: Root and Hips
#   - Fixed: jaw, eyes (out of Marionette scope, kinematic)

const HUMANOID_BY_BONE: Dictionary[StringName, int] = {
	# --- Trunk + head ---
	&"Root": BoneArchetype.Type.ROOT,
	&"Hips": BoneArchetype.Type.ROOT,
	&"Spine": BoneArchetype.Type.SPINE_SEGMENT,
	&"Chest": BoneArchetype.Type.SPINE_SEGMENT,
	&"UpperChest": BoneArchetype.Type.SPINE_SEGMENT,
	&"Neck": BoneArchetype.Type.SPINE_SEGMENT,
	&"Head": BoneArchetype.Type.SPINE_SEGMENT,

	# --- Face (out of scope; kinematic) ---
	&"LeftEye": BoneArchetype.Type.FIXED,
	&"RightEye": BoneArchetype.Type.FIXED,
	&"Jaw": BoneArchetype.Type.FIXED,

	# --- Left arm ---
	&"LeftShoulder": BoneArchetype.Type.CLAVICLE,
	&"LeftUpperArm": BoneArchetype.Type.BALL,
	&"LeftLowerArm": BoneArchetype.Type.HINGE,
	&"LeftHand": BoneArchetype.Type.SADDLE,

	# Left fingers: thumb metacarpal saddle, proximal MCP saddle, others hinge.
	&"LeftThumbMetacarpal": BoneArchetype.Type.SADDLE,
	&"LeftThumbProximal": BoneArchetype.Type.HINGE,
	&"LeftThumbDistal": BoneArchetype.Type.HINGE,
	&"LeftIndexProximal": BoneArchetype.Type.SADDLE,
	&"LeftIndexIntermediate": BoneArchetype.Type.HINGE,
	&"LeftIndexDistal": BoneArchetype.Type.HINGE,
	&"LeftMiddleProximal": BoneArchetype.Type.SADDLE,
	&"LeftMiddleIntermediate": BoneArchetype.Type.HINGE,
	&"LeftMiddleDistal": BoneArchetype.Type.HINGE,
	&"LeftRingProximal": BoneArchetype.Type.SADDLE,
	&"LeftRingIntermediate": BoneArchetype.Type.HINGE,
	&"LeftRingDistal": BoneArchetype.Type.HINGE,
	&"LeftLittleProximal": BoneArchetype.Type.SADDLE,
	&"LeftLittleIntermediate": BoneArchetype.Type.HINGE,
	&"LeftLittleDistal": BoneArchetype.Type.HINGE,

	# --- Right arm ---
	&"RightShoulder": BoneArchetype.Type.CLAVICLE,
	&"RightUpperArm": BoneArchetype.Type.BALL,
	&"RightLowerArm": BoneArchetype.Type.HINGE,
	&"RightHand": BoneArchetype.Type.SADDLE,

	&"RightThumbMetacarpal": BoneArchetype.Type.SADDLE,
	&"RightThumbProximal": BoneArchetype.Type.HINGE,
	&"RightThumbDistal": BoneArchetype.Type.HINGE,
	&"RightIndexProximal": BoneArchetype.Type.SADDLE,
	&"RightIndexIntermediate": BoneArchetype.Type.HINGE,
	&"RightIndexDistal": BoneArchetype.Type.HINGE,
	&"RightMiddleProximal": BoneArchetype.Type.SADDLE,
	&"RightMiddleIntermediate": BoneArchetype.Type.HINGE,
	&"RightMiddleDistal": BoneArchetype.Type.HINGE,
	&"RightRingProximal": BoneArchetype.Type.SADDLE,
	&"RightRingIntermediate": BoneArchetype.Type.HINGE,
	&"RightRingDistal": BoneArchetype.Type.HINGE,
	&"RightLittleProximal": BoneArchetype.Type.SADDLE,
	&"RightLittleIntermediate": BoneArchetype.Type.HINGE,
	&"RightLittleDistal": BoneArchetype.Type.HINGE,

	# --- Left leg + foot ---
	&"LeftUpperLeg": BoneArchetype.Type.BALL,
	&"LeftLowerLeg": BoneArchetype.Type.HINGE,
	&"LeftFoot": BoneArchetype.Type.SADDLE,
	&"LeftToes": BoneArchetype.Type.HINGE,

	# Left toes: proximal phalanges = saddle (MTP), all others = hinge.
	&"LeftBigToeProximal": BoneArchetype.Type.SADDLE,
	&"LeftBigToeDistal": BoneArchetype.Type.HINGE,
	&"LeftToe2Proximal": BoneArchetype.Type.SADDLE,
	&"LeftToe2Intermediate": BoneArchetype.Type.HINGE,
	&"LeftToe2Distal": BoneArchetype.Type.HINGE,
	&"LeftToe3Proximal": BoneArchetype.Type.SADDLE,
	&"LeftToe3Intermediate": BoneArchetype.Type.HINGE,
	&"LeftToe3Distal": BoneArchetype.Type.HINGE,
	&"LeftToe4Proximal": BoneArchetype.Type.SADDLE,
	&"LeftToe4Intermediate": BoneArchetype.Type.HINGE,
	&"LeftToe4Distal": BoneArchetype.Type.HINGE,
	&"LeftToe5Proximal": BoneArchetype.Type.SADDLE,
	&"LeftToe5Intermediate": BoneArchetype.Type.HINGE,
	&"LeftToe5Distal": BoneArchetype.Type.HINGE,

	# --- Right leg + foot ---
	&"RightUpperLeg": BoneArchetype.Type.BALL,
	&"RightLowerLeg": BoneArchetype.Type.HINGE,
	&"RightFoot": BoneArchetype.Type.SADDLE,
	&"RightToes": BoneArchetype.Type.HINGE,

	&"RightBigToeProximal": BoneArchetype.Type.SADDLE,
	&"RightBigToeDistal": BoneArchetype.Type.HINGE,
	&"RightToe2Proximal": BoneArchetype.Type.SADDLE,
	&"RightToe2Intermediate": BoneArchetype.Type.HINGE,
	&"RightToe2Distal": BoneArchetype.Type.HINGE,
	&"RightToe3Proximal": BoneArchetype.Type.SADDLE,
	&"RightToe3Intermediate": BoneArchetype.Type.HINGE,
	&"RightToe3Distal": BoneArchetype.Type.HINGE,
	&"RightToe4Proximal": BoneArchetype.Type.SADDLE,
	&"RightToe4Intermediate": BoneArchetype.Type.HINGE,
	&"RightToe4Distal": BoneArchetype.Type.HINGE,
	&"RightToe5Proximal": BoneArchetype.Type.SADDLE,
	&"RightToe5Intermediate": BoneArchetype.Type.HINGE,
	&"RightToe5Distal": BoneArchetype.Type.HINGE,
}


# Returns the archetype for the named bone, or -1 if not in the default map.
static func archetype_for_bone(bone_name: StringName) -> int:
	return HUMANOID_BY_BONE.get(bone_name, -1)


static func has_archetype_for(bone_name: StringName) -> bool:
	return HUMANOID_BY_BONE.has(bone_name)
