@tool
class_name BoneStateProfile
extends Resource

## Per-bone simulation state. Swappable at runtime for injury / shock /
## surrender mode changes — for the *continuous* powered↔unpowered dial,
## use the strength modulation system (CLAUDE.md §12) instead of touching
## this profile.
##
## States:
##   KINEMATIC — follows animation directly, no physics simulation.
##               Jaw + eyes default here (out of Marionette scope).
##   POWERED   — dynamic body, SPD pulls toward target pose. (SPD lands
##               in Phase 5.)
##   UNPOWERED — dynamic body with no SPD; falls limp.

enum State { KINEMATIC, POWERED, UNPOWERED }

## Per-bone state map. Keyed by skel/profile bone name. Bones absent
## from the dict default to POWERED on `get_state()`.
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
