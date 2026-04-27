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
@export var alpha: float = 4.0
@export_range(0.0, 2.0, 0.001) var damping_ratio: float = 1.0

# Fraction of the parent BoneProfile's total_mass attributed to this bone.
# Sum across all bones must equal 1.
@export_range(0.0, 1.0, 0.0001) var mass_fraction: float = 0.0

@export var is_left_side: bool = false


# Returns the bone-local basis whose columns are (flex, along-bone, abduction)
# unit vectors. Used by ragdoll creation (P3.7) to derive joint_rotation, and
# by tests as a round-trip check on the permutation.
func bone_to_anatomical_basis() -> Basis:
	return Basis(
		SignedAxis.to_vector3(flex_axis),
		SignedAxis.to_vector3(along_bone_axis),
		SignedAxis.to_vector3(abduction_axis),
	)
