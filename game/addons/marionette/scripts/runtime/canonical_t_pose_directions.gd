@tool
class_name MarionetteCanonicalDirections
extends RefCounted

# Canonical T-pose along-directions per humanoid bone, expressed against the
# muscle frame and signed by side. Used by `MarionetteTPoseBasisSolver` as the
# "T-pose" alternative to archetype-dispatched geometric authoring (see
# `docs/marionette/Marionette_Update_TPose_Calibration.md`).
#
# T-pose here is a *reference frame for a lookup table* — the algorithm never
# poses the rig; it only reads the bone's expected along-direction in the
# canonical configuration. Vector3.ZERO means "no canonical direction" — the
# caller treats that as the ROOT/FIXED behavior (no SPD frame).


# Returns the bone's along-bone direction in T-pose, expressed against the
# muscle frame and signed by side. Vector3.ZERO -> caller skips.
static func along_for(
		bone_name: StringName,
		mf: MuscleFrame,
		is_left_side: bool) -> Vector3:
	var s: String = String(bone_name)
	# Spine chain (Hips through Head) points along +up.
	if s == "Hips" or s == "Chest" or s == "UpperChest" \
			or s.begins_with("Spine") \
			or s == "Neck" or s == "Head":
		return mf.up
	# Arm chain points laterally outward from the body midline.
	if s.ends_with("Shoulder") or s.ends_with("UpperArm") \
			or s.ends_with("LowerArm") or s.ends_with("Hand"):
		return -mf.right if is_left_side else mf.right
	# Leg chain points along -up (down).
	if s.ends_with("UpperLeg") or s.ends_with("LowerLeg"):
		return -mf.up
	# Foot points forward (toes-direction in T-pose).
	if s.ends_with("Foot"):
		return mf.forward
	# Toes compound + toe phalanges: forward along the foot's anterior axis.
	# `BigToe*` matches via "Toe" too, so no separate Hallux branch needed for
	# the current MarionetteHumanoidProfile naming. The Hallux check is kept
	# for forward-compat with profiles that use clinical names.
	if s.contains("Toe") or s.contains("Hallux"):
		return mf.forward
	# Finger phalanges (incl. thumb): laterally outward, continuing the arm's
	# along direction. Thumb gets the same direction as the other fingers in
	# this first cut — see Marionette_Update_TPose_Calibration.md §4.1
	# "Authoring care points" for the open question on a thumb-specific
	# canonical direction (forward + outward mix).
	if s.contains("Thumb") or s.contains("Index") or s.contains("Middle") \
			or s.contains("Ring") or s.contains("Little"):
		return -mf.right if is_left_side else mf.right
	return Vector3.ZERO
