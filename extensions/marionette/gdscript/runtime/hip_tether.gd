@tool
class_name MarionetteHipTether
extends RefCounted

# Editor-side hip tether for Ragdoll Test mode (P5.8 / slice 8b).
#
# When the muscle-test dock enters Ragdoll Test it constructs a single
# Generic6DOFJoint3D between a StaticBody3D anchor and the root MarionetteBone.
# All linear axes are locked tight (zero range), angular axes get ±60° with
# moderate stiffness. The character ragdoll-falls in place but doesn't
# wander off-screen — designers can see SPD doing its job without setting
# up foot-IK first.
#
# This is editor scaffolding, not runtime behavior — the joint lives under
# the Marionette node and gets freed on Ragdoll-Test exit. No counterpart
# in the C++ core.
#
# Design notes:
# - Tether owns both anchor and joint nodes. Engage/release lifecycle is
#   pair-locked: every engage matches one release.
# - Anchor is a StaticBody3D with no CollisionShape3D. Joints don't need
#   shapes on either body; collisions are unrelated.
# - Linear axes use `set_flag_x/y/z(FLAG_ENABLE_LINEAR_LIMIT, true)` and
#   set lower=upper=0 — the documented "lock tight" recipe.
# - Angular range stays permissive (±60° per axis). Hip can rotate visibly
#   under load; foot-IK / proper balance handles real anchoring later.
# - `set_param_x/y/z` takes raw radians (verified for the C++ API path),
#   not the radians_as_degrees property hint used by PhysicalBone3D's
#   internal joint. See reference_godot_physicalbone_jolt_angle_units.md.

const ANCHOR_NAME: StringName = &"_RagdollTestAnchor"
const JOINT_NAME: StringName = &"_RagdollTestTether"

const _ANGULAR_RANGE: float = PI / 3.0  # ±60° per axis
const _LINEAR_SPRING_STIFFNESS: float = 1000.0
const _LINEAR_SPRING_DAMPING: float = 50.0
const _ANGULAR_SPRING_STIFFNESS: float = 50.0
const _ANGULAR_SPRING_DAMPING: float = 5.0

var anchor: StaticBody3D
var joint: Generic6DOFJoint3D


# Construct anchor + joint as children of `marionette`, connecting the
# StaticBody3D anchor (at `hip` world position) to the root MarionetteBone.
# `hip` is the root MarionetteBone returned by `MarionetteCore::get_root_bone()`.
# Idempotent on a fresh tether instance; call `release()` before re-engaging.
func engage(marionette: Node3D, hip: PhysicalBone3D) -> void:
	if marionette == null or hip == null:
		push_error("MarionetteHipTether.engage: marionette or hip is null")
		return
	if anchor != null or joint != null:
		push_warning("MarionetteHipTether.engage: already engaged")
		return

	# Anchor at hip world position. StaticBody3D doesn't need a collision
	# shape for the joint to bind.
	anchor = StaticBody3D.new()
	anchor.name = String(ANCHOR_NAME)
	marionette.add_child(anchor)
	anchor.global_transform = Transform3D(Basis.IDENTITY, hip.global_transform.origin)

	# Joint at the same world position; node_a / node_b paths refer through
	# the joint's parent (marionette).
	joint = Generic6DOFJoint3D.new()
	joint.name = String(JOINT_NAME)
	marionette.add_child(joint)
	joint.global_transform = Transform3D(Basis.IDENTITY, hip.global_transform.origin)
	joint.node_a = joint.get_path_to(anchor)
	joint.node_b = joint.get_path_to(hip)

	# Lock all linear axes tight (zero range). Spring path adds extra
	# stiffness in case Jolt's limit alone allows micro-drift.
	for axis: String in ["x", "y", "z"]:
		joint.set("linear_limit_%s/enabled" % axis, true)
		joint.set("linear_limit_%s/lower_distance" % axis, 0.0)
		joint.set("linear_limit_%s/upper_distance" % axis, 0.0)
		joint.set("linear_limit_%s/softness" % axis, 0.1)
		joint.set("linear_spring_%s/enabled" % axis, true)
		joint.set("linear_spring_%s/stiffness" % axis, _LINEAR_SPRING_STIFFNESS)
		joint.set("linear_spring_%s/damping" % axis, _LINEAR_SPRING_DAMPING)
		joint.set("linear_spring_%s/equilibrium_point" % axis, 0.0)
	# Angular: permissive — hip can rotate visibly under impulse, just
	# doesn't free-spin. ±60° matches the spec ("medium-stiffness angular
	# lock — hip can rotate a bit, not translate or spin freely").
	for axis: String in ["x", "y", "z"]:
		joint.set("angular_limit_%s/enabled" % axis, true)
		joint.set("angular_limit_%s/lower_angle" % axis, -_ANGULAR_RANGE)
		joint.set("angular_limit_%s/upper_angle" % axis, _ANGULAR_RANGE)
		joint.set("angular_spring_%s/enabled" % axis, true)
		joint.set("angular_spring_%s/stiffness" % axis, _ANGULAR_SPRING_STIFFNESS)
		joint.set("angular_spring_%s/damping" % axis, _ANGULAR_SPRING_DAMPING)


# Tear down both nodes. Safe to call when not engaged. After release,
# the tether instance can be `engage()`d again without re-construction.
func release() -> void:
	if joint != null:
		joint.queue_free()
		joint = null
	if anchor != null:
		anchor.queue_free()
		anchor = null


func is_engaged() -> bool:
	return joint != null and anchor != null
