@tool
class_name MarionetteRomDefaults
extends RefCounted

# P2.9 — clinical anatomical ROM defaults per archetype, with bone-name
# refinements (shoulder vs hip both Ball; elbow vs knee both Hinge; wrist vs
# ankle both Saddle). Authoring-time data; populates BoneEntry.rom_min /
# rom_max during "Generate from Skeleton" (P2.10).
#
# Convention (CLAUDE.md §2): ROM components are (flex, medial_rotation,
# abduction), stored positive-flex / positive-medial / positive-abduction
# regardless of side. Solver mirrors right side at runtime via is_left_side.
#
# All constants are declared in degrees for readability; conversion to
# radians happens once in `apply()`. Sources: standard clinical AROM
# references (Norkin/White; Marionette_plan P2.9).

const _ZERO: Vector2 = Vector2.ZERO

# Ball: shoulder. Generous flex, near-full rotation, near-full abduction.
const _SHOULDER_FLEX: Vector2 = Vector2(0.0, 150.0)
const _SHOULDER_ROT: Vector2 = Vector2(-75.0, 75.0)
const _SHOULDER_ABD: Vector2 = Vector2(0.0, 150.0)

# Ball: hip. Less flex (no over-the-shoulder gesture), modest rotation,
# narrow abduction.
const _HIP_FLEX: Vector2 = Vector2(-15.0, 100.0)
const _HIP_ROT: Vector2 = Vector2(-45.0, 45.0)
const _HIP_ABD: Vector2 = Vector2(0.0, 40.0)

# Hinge: elbow / knee. Flexion only; the small carrying-angle abduction is
# folded into the resting joint_rotation, not into ROM.
const _ELBOW_FLEX: Vector2 = Vector2(0.0, 140.0)
const _KNEE_FLEX: Vector2 = Vector2(0.0, 135.0)

# Saddle: wrist. Flex/extension symmetric-ish; ulnar deviation > radial.
const _WRIST_FLEX: Vector2 = Vector2(-55.0, 55.0)
const _WRIST_ABD: Vector2 = Vector2(-15.0, 35.0)

# Saddle: ankle. Plantarflexion (-) > dorsiflexion (+); inversion=eversion ≈ ±20.
const _ANKLE_FLEX: Vector2 = Vector2(-15.0, 40.0)
const _ANKLE_ABD: Vector2 = Vector2(-20.0, 20.0)

# Clavicle: small ROM all three (protraction/retraction, elevation/depression,
# slight axial rotation).
const _CLAVICLE_FLEX: Vector2 = Vector2(-15.0, 15.0)
const _CLAVICLE_ROT: Vector2 = Vector2(-15.0, 15.0)
const _CLAVICLE_ABD: Vector2 = Vector2(-15.0, 15.0)

# SpineSegment: per-vertebra contribution. Full-trunk ROM is the sum across
# segments — keep individual vertebrae small so we don't double-count.
const _VERTEBRA_FLEX: Vector2 = Vector2(-10.0, 10.0)
const _VERTEBRA_ROT: Vector2 = Vector2(-10.0, 10.0)
const _VERTEBRA_ABD: Vector2 = Vector2(-10.0, 10.0)

# Phalanx hinges: distal/intermediate finger and toe phalanges, plus the
# single "Toes" hinge bone in profiles without per-toe phalanges.
const _PHALANX_HINGE_FLEX: Vector2 = Vector2(0.0, 80.0)

# Proximal phalanx saddles: thumb metacarpal, finger MCP, toe MTP.
const _PROXIMAL_PHALANX_FLEX: Vector2 = Vector2(0.0, 90.0)
const _PROXIMAL_PHALANX_ABD: Vector2 = Vector2(-20.0, 20.0)

# Generic fall-throughs for archetypes that match no specific bone-name rule.
# These exist as safe placeholders; "Generate from Skeleton" should report
# bones that hit these so the user can refine the table.
const _GENERIC_BALL_FLEX: Vector2 = Vector2(-90.0, 90.0)
const _GENERIC_BALL_ROT: Vector2 = Vector2(-90.0, 90.0)
const _GENERIC_BALL_ABD: Vector2 = Vector2(-90.0, 90.0)
const _GENERIC_HINGE_FLEX: Vector2 = Vector2(0.0, 120.0)


# Writes default rom_min / rom_max into `entry` based on entry.archetype and
# `bone_name`. Sides are not distinguished — see header comment.
static func apply(entry: BoneEntry, bone_name: StringName) -> void:
	var rom: Array = _lookup(bone_name, entry.archetype)
	var flex_v: Vector2 = rom[0]
	var rot_v: Vector2 = rom[1]
	var abd_v: Vector2 = rom[2]
	entry.rom_min = Vector3(
		deg_to_rad(flex_v.x),
		deg_to_rad(rot_v.x),
		deg_to_rad(abd_v.x),
	)
	entry.rom_max = Vector3(
		deg_to_rad(flex_v.y),
		deg_to_rad(rot_v.y),
		deg_to_rad(abd_v.y),
	)


# Returns [flex_range, rot_range, abd_range] in degrees, each Vector2(min, max).
static func _lookup(bone_name: StringName, archetype: BoneArchetype.Type) -> Array:
	var name: String = String(bone_name)
	match archetype:
		BoneArchetype.Type.BALL:
			if name.ends_with("UpperArm"):
				return [_SHOULDER_FLEX, _SHOULDER_ROT, _SHOULDER_ABD]
			if name.ends_with("UpperLeg"):
				return [_HIP_FLEX, _HIP_ROT, _HIP_ABD]
			return [_GENERIC_BALL_FLEX, _GENERIC_BALL_ROT, _GENERIC_BALL_ABD]
		BoneArchetype.Type.HINGE:
			if name.ends_with("LowerArm"):
				return [_ELBOW_FLEX, _ZERO, _ZERO]
			if name.ends_with("LowerLeg"):
				return [_KNEE_FLEX, _ZERO, _ZERO]
			# All remaining humanoid hinges are phalanges (finger/toe distal
			# and intermediate, plus the single "Toes" block bone).
			return [_PHALANX_HINGE_FLEX, _ZERO, _ZERO]
		BoneArchetype.Type.SADDLE:
			if name.ends_with("Hand"):
				return [_WRIST_FLEX, _ZERO, _WRIST_ABD]
			if name.ends_with("Foot"):
				return [_ANKLE_FLEX, _ZERO, _ANKLE_ABD]
			# Thumb metacarpal + finger/toe proximal phalanges.
			return [_PROXIMAL_PHALANX_FLEX, _ZERO, _PROXIMAL_PHALANX_ABD]
		BoneArchetype.Type.SPINE_SEGMENT:
			return [_VERTEBRA_FLEX, _VERTEBRA_ROT, _VERTEBRA_ABD]
		BoneArchetype.Type.CLAVICLE:
			return [_CLAVICLE_FLEX, _CLAVICLE_ROT, _CLAVICLE_ABD]
		BoneArchetype.Type.PIVOT:
			return [_GENERIC_HINGE_FLEX, _ZERO, _ZERO]
	# ROOT, FIXED, or unknown: zero ROM. Joint isn't simulated by SPD.
	return [_ZERO, _ZERO, _ZERO]
