@tool
class_name BoneEntry
extends Resource

# Static per-bone authoring data, baked at "Generate from Skeleton" time and
# read at runtime. See CLAUDE.md §Authoring vs runtime split: nothing in this
# resource is recomputed at runtime.
#
# Anatomical convention (CLAUDE.md §2):
#   +X = flex, +Y = along-bone, +Z = abduction (= X × Y).
#   ROM is stored in positive-flex / positive-medial-rotation / positive-abduction
#   regardless of side — solver mirrors right-side bones using is_left_side.

@export var archetype: BoneArchetype.Type = BoneArchetype.Type.FIXED

# Bone-local→anatomical permutation. Each field names the signed bone-local axis
# that aligns with the corresponding anatomical direction.
@export var flex_axis: SignedAxis.Axis = SignedAxis.Axis.PLUS_X
@export var along_bone_axis: SignedAxis.Axis = SignedAxis.Axis.PLUS_Y
@export var abduction_axis: SignedAxis.Axis = SignedAxis.Axis.PLUS_Z

# Anatomical ROM, radians. Components: (flex, medial_rotation, abduction).
# Defaults are zero; populated by archetype-specific defaults at authoring time.
@export var rom_min: Vector3 = Vector3.ZERO
@export var rom_max: Vector3 = Vector3.ZERO

# SPD parameters (CLAUDE.md §6). alpha = reach-in-N-physics-steps, mass-independent.
# damping_ratio is the wobble dial: 0 = unstable bounce, 1 = critical, >1 = overdamped.
# Read by the SPD path in MarionetteBone._integrate_forces (Phase 5; not yet
# implemented). Independent of the joint-spring fields below.
@export var alpha: float = 4.0
@export_range(0.0, 2.0, 0.001) var damping_ratio: float = 1.0

# 6DOF joint angular spring, per anatomical axis (flex / medial_rotation /
# abduction). Read at Build Ragdoll time and written into Jolt's
# `joint_constraints/{x,y,z}/angular_limit_spring_{stiffness,damping}` fields
# on the spawned MarionetteBone. A zero stiffness on an axis disables the
# spring on that axis (Jolt's `_enabled` flag is derived: stiffness > 0).
#
# This is the Phase-5-stopgap path: until proper SPD lands, Jolt's joint
# springs keep dynamic bones from going fully limp. Values are Jolt-direct
# (no unit conversion); the user-facing scale is roughly 0.5 (toes) to 4.0
# (hips), with values above ~5 prone to integrator instability.
#
# Defaults populated by `MarionetteSpringDefaults.apply()` during Calibrate;
# the apply step only writes defaults if the existing value is zero, so
# tuned bones survive a re-Calibrate.
@export var spring_stiffness: Vector3 = Vector3.ZERO
@export var spring_damping: Vector3 = Vector3.ZERO

# Fraction of the parent BoneProfile's total_mass attributed to this bone.
# Sum across all bones must equal 1.
@export_range(0.0, 1.0, 0.0001) var mass_fraction: float = 0.0

@export var is_left_side: bool = false

# Anatomical configuration of the rest pose, expressed in canonical-anatomy
# (flex, medial_rot, abduction) radians. Lets ROM bounds and slider/SPD inputs
# live in canonical anatomy regardless of how the rig was modeled — at ragdoll
# build time we shift Jolt limits by `-rest_anatomical_offset`, and at apply
# time `AnatomicalPose.bone_local_rotation` subtracts the same offset before
# rotating around the joint-local axes. So:
#   slider value = canonical anatomical angle (e.g., 0° elbow flex = straight)
#   joint angle  = slider value − rest_offset
#   rest pose    = slider value of rest_offset
#
# Computed at "Generate from Skeleton" time. Currently populated for HINGE
# bones (rest_offset.x = limb-plane bend angle, signed by motion target).
# Other archetypes leave it at Vector3.ZERO until the follow-up slice — for
# T-pose rigs that's already correct because rest = canonical T-pose.
@export var rest_anatomical_offset: Vector3 = Vector3.ZERO

# Calculated-frame fallback: when the bone's rest basis is too far from the
# solver's target anatomical basis for any signed permutation to track it
# (matcher score < threshold), we abandon the permutation path and bake the
# calculated target directly into joint_rotation. Lets non-T-pose rigs work
# without re-export.
#
# `calculated_anatomical_basis` columns are (flex, along-bone, abduction) unit
# vectors expressed in *bone-local* space. It is the inverse of the bone's
# rest basis applied to the solver target, so it round-trips to the world-
# space target when composed back with bone_world.basis.
#
# When `use_calculated_frame` is false (the matched-bone default), the signed-
# axis fields above are authoritative and consumers go through
# bone_to_anatomical_basis(). When true, calculated_anatomical_basis is
# authoritative and the signed-axis fields are kept only for debug display.
@export var calculated_anatomical_basis: Basis = Basis.IDENTITY
@export var use_calculated_frame: bool = false

# Chirality compensation for the abduction axis.
#
# A right-handed basis with `flex × along = abd` forces +rotation around the
# abd axis to produce motion in the -flex direction. For some bone+side
# combinations that direction is anatomically correct; for others it's
# sign-flipped from the expected anatomical motion (LEFT shoulder/hip,
# RIGHT foot, etc — see the validator's abd_dot column for the live data).
#
# When this flag is true, the runtime treats the +abd slider value and the
# rom_z constraint bounds as anti-aligned with basis.z, sign-flipping at
# both endpoints so anatomical "+abd" produces anatomical abduction motion
# regardless of which side the chirality landed on. Authoring data
# (rom_min.z / rom_max.z) stays in the standard positive-abduction
# convention; this flag is the runtime translation layer.
@export var mirror_abd: bool = false


# Returns the bone-local basis whose columns are (flex, along-bone, abduction)
# unit vectors. Used by ragdoll creation (P3.7) to derive joint_rotation, and
# by tests as a round-trip check on the permutation.
func bone_to_anatomical_basis() -> Basis:
	return Basis(
		SignedAxis.to_vector3(flex_axis),
		SignedAxis.to_vector3(along_bone_axis),
		SignedAxis.to_vector3(abduction_axis),
	)


# Returns the bone-local anatomical basis that should actually be baked into
# joint_rotation. Branches on use_calculated_frame so all consumers
# (ragdoll build, anatomical pose, gizmos) stay aligned on which frame is live.
func anatomical_basis_in_bone_local() -> Basis:
	if use_calculated_frame:
		return calculated_anatomical_basis
	return bone_to_anatomical_basis()
