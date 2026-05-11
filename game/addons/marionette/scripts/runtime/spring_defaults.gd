@tool
class_name MarionetteSpringDefaults
extends RefCounted

# Per-archetype default 6DOF joint angular spring values, with bone-name
# refinements where the archetype default isn't enough (toes need less
# stiffness than other hinges, hips need more than other balls). Authoring-
# time data; populates BoneEntry.spring_stiffness / spring_damping during
# "Calibrate Profile from Skeleton" (P2.10's spring-tuning slice).
#
# Values are Jolt-direct (no unit conversion); the safe envelope is
# approximately 0.5..4.0 stiffness, 1.5..4.0 damping. Above ~5 stiffness
# the integrator gets unstable and the ragdoll explodes; below ~0.3 the
# bone ignores its joint angular target and flops under gravity.
#
# Per-axis: components are (flex / medial_rotation / abduction) — same
# ordering as ROM. Hinge bones get spring on the flex axis only; saddle
# bones get flex + abduction (medial axis is locked); ball / spine /
# clavicle get all three.
#
# Apply policy: a non-zero existing value on `entry` is preserved (the user
# tuned it). Zeros get the default. So re-running Calibrate doesn't lose
# tuning.

# ---- Per-archetype defaults ----
# Single-axis archetypes leave the locked axes at zero so we don't waste
# Jolt cycles on a degenerate spring.
const _BALL_K: Vector3            = Vector3(1.5, 1.5, 1.5)
const _BALL_C: Vector3            = Vector3(3.0, 3.0, 3.0)
const _HINGE_K: Vector3           = Vector3(1.0, 0.0, 0.0)
const _HINGE_C: Vector3           = Vector3(2.5, 0.0, 0.0)
const _SADDLE_K: Vector3          = Vector3(1.0, 0.0, 1.0)
const _SADDLE_C: Vector3          = Vector3(2.5, 0.0, 2.5)
const _PIVOT_K: Vector3           = Vector3(0.0, 0.5, 0.0)
const _PIVOT_C: Vector3           = Vector3(0.0, 1.5, 0.0)
const _SPINE_SEGMENT_K: Vector3   = Vector3(1.5, 1.5, 1.5)
const _SPINE_SEGMENT_C: Vector3   = Vector3(3.0, 3.0, 3.0)
const _CLAVICLE_K: Vector3        = Vector3(0.8, 0.8, 0.8)
const _CLAVICLE_C: Vector3        = Vector3(2.5, 2.5, 2.5)

# ---- Bone-name refinements (override the archetype default) ----
# Toes: user-confirmed values that prevent flop without explosion.
const _TOE_HINGE_K: Vector3       = Vector3(0.5, 0.0, 0.0)
const _TOE_HINGE_C: Vector3       = Vector3(2.0, 0.0, 0.0)
# Toe MTP saddles want the same gentle scale as the toe hinges.
const _TOE_SADDLE_K: Vector3      = Vector3(0.5, 0.0, 0.5)
const _TOE_SADDLE_C: Vector3      = Vector3(2.0, 0.0, 2.0)
# Finger phalanges (DIP/PIP hinges and MCP saddles): light bones, low spring.
const _FINGER_HINGE_K: Vector3    = Vector3(0.4, 0.0, 0.0)
const _FINGER_HINGE_C: Vector3    = Vector3(1.8, 0.0, 0.0)
const _FINGER_SADDLE_K: Vector3   = Vector3(0.4, 0.0, 0.4)
const _FINGER_SADDLE_C: Vector3   = Vector3(1.8, 0.0, 1.8)
# Wrist / Hand (SADDLE): boost slightly so the hand doesn't dangle.
const _HAND_K: Vector3            = Vector3(1.2, 0.0, 1.2)
const _HAND_C: Vector3            = Vector3(2.8, 0.0, 2.8)
# Foot / Ankle (SADDLE): boost similarly so the foot tracks the leg.
const _FOOT_K: Vector3            = Vector3(1.2, 0.0, 1.2)
const _FOOT_C: Vector3            = Vector3(2.8, 0.0, 2.8)
# Hip (BALL): heavy joint carrying body weight + leg.
const _HIP_K: Vector3             = Vector3(2.0, 2.0, 2.0)
const _HIP_C: Vector3             = Vector3(3.5, 3.5, 3.5)


static func apply(entry: BoneEntry, bone_name: StringName) -> void:
	if entry == null:
		return
	var defaults: Array = _defaults_for(entry.archetype, bone_name)
	var k_default: Vector3 = defaults[0]
	var c_default: Vector3 = defaults[1]
	# Per-axis preservation: if the user has tuned a specific axis, keep that
	# axis even when neighbors get the default. A bone whose existing value
	# is (0.0, 1.5, 0.0) on stiffness keeps the 1.5 and gets the default on
	# axes 0 and 2.
	var k_out := Vector3(
			entry.spring_stiffness.x if entry.spring_stiffness.x > 0.0 else k_default.x,
			entry.spring_stiffness.y if entry.spring_stiffness.y > 0.0 else k_default.y,
			entry.spring_stiffness.z if entry.spring_stiffness.z > 0.0 else k_default.z)
	var c_out := Vector3(
			entry.spring_damping.x if entry.spring_damping.x > 0.0 else c_default.x,
			entry.spring_damping.y if entry.spring_damping.y > 0.0 else c_default.y,
			entry.spring_damping.z if entry.spring_damping.z > 0.0 else c_default.z)
	entry.spring_stiffness = k_out
	entry.spring_damping = c_out


# Returns [stiffness_default, damping_default] for the bone's archetype +
# name. Specific bone-name rules win over generic archetype rules.
static func _defaults_for(archetype: int, bone_name: StringName) -> Array:
	var n := String(bone_name)
	# Bone-name overrides first.
	if n.contains("Toe"):
		if archetype == BoneArchetype.Type.SADDLE:
			return [_TOE_SADDLE_K, _TOE_SADDLE_C]
		if archetype == BoneArchetype.Type.HINGE:
			return [_TOE_HINGE_K, _TOE_HINGE_C]
	if _is_finger_bone(n):
		if archetype == BoneArchetype.Type.SADDLE:
			return [_FINGER_SADDLE_K, _FINGER_SADDLE_C]
		if archetype == BoneArchetype.Type.HINGE:
			return [_FINGER_HINGE_K, _FINGER_HINGE_C]
	if n.ends_with("Hand"):
		return [_HAND_K, _HAND_C]
	if n.ends_with("Foot"):
		return [_FOOT_K, _FOOT_C]
	if n.ends_with("UpperLeg"):
		return [_HIP_K, _HIP_C]
	# Generic per-archetype.
	match archetype:
		BoneArchetype.Type.BALL:
			return [_BALL_K, _BALL_C]
		BoneArchetype.Type.HINGE:
			return [_HINGE_K, _HINGE_C]
		BoneArchetype.Type.SADDLE:
			return [_SADDLE_K, _SADDLE_C]
		BoneArchetype.Type.PIVOT:
			return [_PIVOT_K, _PIVOT_C]
		BoneArchetype.Type.SPINE_SEGMENT:
			return [_SPINE_SEGMENT_K, _SPINE_SEGMENT_C]
		BoneArchetype.Type.CLAVICLE:
			return [_CLAVICLE_K, _CLAVICLE_C]
		_:
			# ROOT and FIXED — no spring (kinematic / not driven).
			return [Vector3.ZERO, Vector3.ZERO]


static func _is_finger_bone(n: String) -> bool:
	return n.contains("Thumb") or n.contains("Index") or n.contains("Middle") \
			or n.contains("Ring") or n.contains("Little")
