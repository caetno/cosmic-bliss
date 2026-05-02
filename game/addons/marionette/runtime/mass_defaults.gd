@tool
class_name MarionetteMassDefaults
extends RefCounted

## Per-bone default mass_fraction values, applied during Calibrate
## alongside ROM and spring defaults. Anthropometric values from
## standard segment-mass tables (Plagenhoef / Dempster, rounded);
## sum across the kasumi-class profile lands at ≈ 1.0 so
## Marionette.total_mass distributes proportionally.
##
## Preserves user tuning the same way spring defaults do: an entry
## with mass_fraction > 0 is left alone; only zero-mass entries get
## the default. Sum drifts if the user tunes some bones — that's by
## design (no auto-normalization), so total bone mass may diverge
## slightly from total_mass when bones are individually tuned.
##
## Per-bone values (where applicable; pattern-based fallbacks below):

# ---- Trunk + head ----
const _HIPS: float           = 0.124
const _SPINE: float          = 0.045
const _CHEST: float          = 0.090
const _UPPER_CHEST: float    = 0.180
const _NECK: float           = 0.015
const _HEAD: float           = 0.069

# ---- Arms (one side; the apply step writes both L and R) ----
const _SHOULDER: float       = 0.005
const _UPPER_ARM: float      = 0.027
const _LOWER_ARM: float      = 0.016
const _HAND: float           = 0.004

# ---- Legs (one side) ----
const _UPPER_LEG: float      = 0.100
const _LOWER_LEG: float      = 0.046
const _FOOT: float           = 0.012

# ---- Phalanx fallbacks (per-finger / per-toe) ----
# Finger phalanges: proximal larger than distal; meta(carpal) sized like
# proximal. Each finger ~0.0016, ×5 fingers/hand × 2 hands = ~0.016.
const _THUMB_METACARPAL: float = 0.0008
const _THUMB_PROXIMAL: float   = 0.0006
const _THUMB_DISTAL: float     = 0.0004
const _FINGER_PROXIMAL: float  = 0.0008
const _FINGER_INTERM: float    = 0.0005
const _FINGER_DISTAL: float    = 0.0003

# Toe phalanges: smaller than fingers. Big toe larger than the rest.
const _BIG_TOE_PROXIMAL: float = 0.0008
const _BIG_TOE_DISTAL: float   = 0.0005
const _TOE_PROXIMAL: float     = 0.0005
const _TOE_INTERM: float       = 0.0003
const _TOE_DISTAL: float       = 0.0002

# Generic small-bone fallback for anything not matched. ~0.5 kg at
# total_mass = 70.
const _UNKNOWN: float          = 0.005


## Writes the default mass_fraction onto `entry` based on bone_name.
## A non-zero existing value is preserved (user tuning survives
## re-Calibrate), matching the per-axis preservation pattern in
## MarionetteSpringDefaults.
static func apply(entry: BoneEntry, bone_name: StringName) -> void:
	if entry == null:
		return
	if entry.mass_fraction > 0.0:
		return  # tuned
	entry.mass_fraction = _default_for(bone_name)


static func _default_for(bone_name: StringName) -> float:
	var s := String(bone_name)
	# Exact-name matches first (trunk + head).
	match s:
		"Hips":        return _HIPS
		"Spine":       return _SPINE
		"Chest":       return _CHEST
		"UpperChest":  return _UPPER_CHEST
		"Neck":        return _NECK
		"Head":        return _HEAD
		"Root":        return 0.0      # not simulated
		"Jaw", "LeftEye", "RightEye": return 0.0  # FIXED, kinematic
	# Per-side suffixed bones.
	if s.ends_with("Shoulder"):  return _SHOULDER
	if s.ends_with("UpperArm"):  return _UPPER_ARM
	if s.ends_with("LowerArm"):  return _LOWER_ARM
	if s.ends_with("Hand"):      return _HAND
	if s.ends_with("UpperLeg"):  return _UPPER_LEG
	if s.ends_with("LowerLeg"):  return _LOWER_LEG
	if s.ends_with("Foot"):      return _FOOT
	# Toe aggregates (rare; ARP doesn't have these but SkeletonProfileHumanoid does).
	if s.ends_with("Toes"):      return _FOOT * 0.4
	# Phalanges. Order matters — Distal/Intermediate/Proximal.
	if s.contains("Thumb"):
		if s.ends_with("Metacarpal"): return _THUMB_METACARPAL
		if s.ends_with("Proximal"):   return _THUMB_PROXIMAL
		if s.ends_with("Distal"):     return _THUMB_DISTAL
	if s.contains("Index") or s.contains("Middle") or s.contains("Ring") or s.contains("Little"):
		if s.ends_with("Distal"):       return _FINGER_DISTAL
		if s.ends_with("Intermediate"): return _FINGER_INTERM
		if s.ends_with("Proximal"):     return _FINGER_PROXIMAL
	if s.contains("BigToe"):
		if s.ends_with("Distal"):   return _BIG_TOE_DISTAL
		if s.ends_with("Proximal"): return _BIG_TOE_PROXIMAL
	if s.contains("Toe"):
		if s.ends_with("Distal"):       return _TOE_DISTAL
		if s.ends_with("Intermediate"): return _TOE_INTERM
		if s.ends_with("Proximal"):     return _TOE_PROXIMAL
	return _UNKNOWN
