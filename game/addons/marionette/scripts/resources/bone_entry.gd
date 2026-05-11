@tool
class_name BoneEntry
extends Resource

## Static per-bone authoring data, baked at Calibrate time and read at
## runtime. Anatomical convention: +X = flex, +Y = along-bone,
## +Z = abduction (= X × Y). ROM stored positive-flex / positive-medial-
## rotation / positive-abduction regardless of side — solver mirrors
## right-side bones via `is_left_side`.

## Joint behavior class (Ball / Hinge / Saddle / Pivot / SpineSegment /
## Clavicle / Root / Fixed). Drives ROM defaults, archetype solver
## selection, and per-axis spring stiffness defaults.
@export var archetype: BoneArchetype.Type = BoneArchetype.Type.FIXED

## Bone-local→anatomical permutation. Each field names the signed
## bone-local axis that aligns with the corresponding anatomical
## direction. Result of the matcher pass during Calibrate.
@export var flex_axis: SignedAxis.Axis = SignedAxis.Axis.PLUS_X
@export var along_bone_axis: SignedAxis.Axis = SignedAxis.Axis.PLUS_Y
@export var abduction_axis: SignedAxis.Axis = SignedAxis.Axis.PLUS_Z

## Anatomical ROM lower bound, radians. Components: (flex, medial, abd).
## Set by archetype-specific defaults at Calibrate; tunable per-bone.
@export var rom_min: Vector3 = Vector3.ZERO

## Anatomical ROM upper bound, radians. Components: (flex, medial, abd).
@export var rom_max: Vector3 = Vector3.ZERO

## SPD reach time in physics steps (mass-independent). Phase-5 SPD path
## reads this; not yet wired up at runtime.
@export var alpha: float = 4.0

## SPD damping ratio. 0 = unstable bounce, 1 = critical, >1 = overdamped.
## Phase-5 SPD path; independent of the joint-spring fields below.
@export_range(0.0, 2.0, 0.001) var damping_ratio: float = 1.0

## 6DOF joint angular spring stiffness, per anatomical axis
## (flex / medial / abd). Written to Jolt at Build Ragdoll. Zero on an
## axis disables that axis's spring. Jolt-direct units; safe envelope
## ~0.5 (toes) to ~4.0 (hips); values above ~5 risk integrator blowup.
## Defaulted by MarionetteSpringDefaults during Calibrate; tuning
## survives re-Calibrate (per-axis preservation).
@export var spring_stiffness: Vector3 = Vector3.ZERO

## 6DOF joint angular spring damping, per anatomical axis. Companion to
## `spring_stiffness` — meaningful only on axes where stiffness > 0.
@export var spring_damping: Vector3 = Vector3.ZERO

## Fraction of Marionette.total_mass attributed to this bone. Sum across
## all bones in the profile should equal 1; fallback distribution kicks
## in for bones with mass_fraction = 0.
@export_range(0.0, 1.0, 0.0001) var mass_fraction: float = 0.0

## True for left-side bones. Drives the runtime mirror of medial /
## abduction axes for the right side without needing duplicate authoring.
@export var is_left_side: bool = false

## Rest-pose anatomical offset, radians. Lets slider / ROM / SPD inputs
## live in canonical anatomy regardless of how the rig was modeled —
## the joint angle = slider value − rest_offset. Currently populated
## for HINGE bones (limb-plane bend angle, signed by motion target);
## other archetypes leave it Vector3.ZERO.
@export var rest_anatomical_offset: Vector3 = Vector3.ZERO

## Bone-local anatomical basis, baked when matcher score < threshold so
## non-T-pose rigs work without re-export. Columns are (flex, along-bone,
## abduction) unit vectors. Authoritative iff `use_calculated_frame`.
@export var calculated_anatomical_basis: Basis = Basis.IDENTITY

## True when this bone fell back to the calculated frame at Calibrate
## (matcher score < ~0.85). When true, runtime motion uses
## `calculated_anatomical_basis`; the signed-axis fields stay for
## diagnostic display only.
@export var use_calculated_frame: bool = false

## Chirality compensation for the abduction axis. When true the runtime
## sign-flips +abd input and rom_z bounds so anatomical "+abd" produces
## anatomical abduction regardless of which side the matcher chirality
## landed on. Authoring data stays in standard positive-abduction
## convention; this flag is the runtime translation layer.
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
