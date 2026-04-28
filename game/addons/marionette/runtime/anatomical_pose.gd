@tool
class_name AnatomicalPose
extends RefCounted

# P4.4 — anatomical (flex, medial rotation, abduction) angles → bone-local
# Quaternion. Drives `Skeleton3D.set_bone_pose_rotation()` for the muscle-test
# sliders, and (later, P5) feeds the SPD target.
#
# Each axis rotates around the corresponding signed bone-local axis stored on
# BoneEntry. Compose order is intrinsic flex → medial-rotation → abduction:
# the muscle-rotation axis follows the previous rotation, so the third
# component (abduction) sees a partially-rotated frame. This matches the
# clinical convention "first you flex the limb, then you rotate it about its
# new long-axis, then you abduct" — verified against the slider tests below.
#
# Single-axis input (others zero) collapses to a pure rotation around the
# chosen axis, which is what the muscle-test panel uses most. Multi-axis
# composition is well-defined but order-sensitive — keep tests locked to
# this order so future code stays consistent.


static func bone_local_rotation(entry: BoneEntry, flex: float, rot: float, abd: float) -> Quaternion:
	if entry == null:
		return Quaternion.IDENTITY
	var q := Quaternion.IDENTITY
	if absf(flex) > 0.0:
		q = q * Quaternion(SignedAxis.to_vector3(entry.flex_axis), flex)
	if absf(rot) > 0.0:
		q = q * Quaternion(SignedAxis.to_vector3(entry.along_bone_axis), rot)
	if absf(abd) > 0.0:
		q = q * Quaternion(SignedAxis.to_vector3(entry.abduction_axis), abd)
	return q
