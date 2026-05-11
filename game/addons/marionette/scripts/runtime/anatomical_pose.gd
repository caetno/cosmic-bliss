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
	# Inputs are in canonical anatomy (e.g. flex=0 means straight elbow, even
	# on an A-pose rig with bent rest). Joint identity rotation = rest pose,
	# so subtract the rest's anatomical configuration before composing — that
	# way `flex = rest_offset.x` lands the bone exactly on rest. See
	# `BoneEntry.rest_anatomical_offset` for the contract.
	flex -= entry.rest_anatomical_offset.x
	rot -= entry.rest_anatomical_offset.y
	abd -= entry.rest_anatomical_offset.z
	# Use the basis columns rather than signed-axis enums so the calculated-
	# frame fallback (entry.use_calculated_frame=true) composes around its non-
	# axis-aligned columns. For matched bones the columns are pure ±X/±Y/±Z
	# and Quaternion(axis, angle) reproduces the previous behaviour exactly.
	var ab: Basis = entry.anatomical_basis_in_bone_local()
	# Side-mirror chirality compensation. The basis on the RIGHT side of the
	# body comes out with bone-local +Y (and +Z, for some bones) anti-aligned
	# with the LEFT side — a consequence of the limb's `along` direction
	# being signed outward (`-mf.right` for left, `+mf.right` for right).
	# Without compensation, +med_rot / +abd on the right produces the
	# opposite anatomical motion from the left. mirror_abd handles +Z;
	# medial rotation gets the same treatment for sided BALL / CLAVICLE
	# archetypes (the only archetypes where rom_y is non-trivial AND the
	# bone is left/right). SPINE_SEGMENT bones also have rom_y (axial twist)
	# but they're centerline — entry.is_left_side is false there but the
	# bone isn't a "right" bone, so we leave them alone.
	var rot_signed: float = rot
	var is_sided_med_rot: bool = (
			entry.archetype == BoneArchetype.Type.BALL
			or entry.archetype == BoneArchetype.Type.CLAVICLE)
	if is_sided_med_rot and not entry.is_left_side:
		rot_signed = -rot
	# When the basis chirality flipped abd against anatomical convention
	# (entry.mirror_abd=true), invert the abd rotation direction here so that
	# +abd_slider always means anatomical abduction regardless of side.
	var abd_signed: float = -abd if entry.mirror_abd else abd
	var q := Quaternion.IDENTITY
	if absf(flex) > 0.0:
		q = q * Quaternion(ab.x.normalized(), flex)
	if absf(rot_signed) > 0.0:
		q = q * Quaternion(ab.y.normalized(), rot_signed)
	if absf(abd_signed) > 0.0:
		q = q * Quaternion(ab.z.normalized(), abd_signed)
	return q
