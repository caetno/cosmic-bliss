@tool
class_name BoneStateProfile
extends Resource

# P3.3 — per-bone state controlling participation in physics + (later) muscle
# control. Swappable at runtime for injury / shock / surrender state changes.
#
#   Kinematic — follows animation directly, no physics simulation. Jaw + eyes
#               default here (out of Marionette scope per CLAUDE.md §9).
#   Powered   — dynamic body, SPD pulls toward target pose. (SPD lands in P5.)
#   Unpowered — dynamic body with no SPD; falls limp.
#
# Strength modulation (CLAUDE.md §12) is the *continuous* dial between Powered
# and Unpowered. State transitions here are persistent mode changes that
# rebuild which bones SPD touches at all.

enum State { KINEMATIC, POWERED, UNPOWERED }

@export var states: Dictionary[StringName, int] = {}


# Default for any SkeletonProfile: every bone Powered, except jaw + eyes
# Kinematic. Used by Marionette.build_ragdoll() when bone_state_profile is
# left null so the runtime always has something to read.
static func default_for_skeleton_profile(profile: SkeletonProfile) -> BoneStateProfile:
	var bsp := BoneStateProfile.new()
	if profile == null:
		return bsp
	for i in range(profile.bone_size):
		var bone_name: StringName = profile.get_bone_name(i)
		if bone_name == &"Jaw" or bone_name == &"LeftEye" or bone_name == &"RightEye":
			bsp.states[bone_name] = State.KINEMATIC
		else:
			bsp.states[bone_name] = State.POWERED
	return bsp


func get_state(bone_name: StringName) -> State:
	return states.get(bone_name, State.POWERED)
