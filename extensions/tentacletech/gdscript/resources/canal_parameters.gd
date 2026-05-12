class_name CanalParameters
extends Resource

## Per-canal authoring + runtime parameters consumed by the `Canal`
## node, `CanalAutoBaker`, and (5F+) the per-tick texture integration
## loop. Verbatim port of the schema from
## `docs/Cosmic_Bliss_Update_2026-05-04_canal_interior_model.md`
## under "CanalParameters Resource (NEW)" + cross-referenced against
## `docs/architecture/TentacleTech_Architecture.md` §6.12.
##
## 5E implements identity + linkage + resolution + rest-pose fields and
## the per-cell texture allocation; the rest are inert defaults
## consumed by 5F's per-tick integration (§6.12.4).

# ─── Identity + linkage ────────────────────────────────────────────

## Human-readable name; also used to derive Reverie modulation channel
## paths and the `<canal_name>_TerminalPin` bone lookup.
@export var canal_name: StringName = &""

## Path to the entry orifice — the centerline chain's proximal
## particle is hard-pinned at this orifice's Center frame.
@export var entry_orifice_path: NodePath

## Which rim loop on the entry orifice the canal joins. 0 = outermost.
@export var entry_loop_index: int = 0

## Path to the exit orifice (open-canal mode). Left empty for
## closed-terminal sacs (uterus, bladder).
@export var exit_orifice_path: NodePath

## Which rim loop on the exit orifice the canal joins.
@export var exit_loop_index: int = 0

## Bone-name prefix for the CP spline control bones in the skeleton —
## e.g. "Vag_CP" pulls Vag_CP_0, Vag_CP_1, ... sorted by trailing
## numeric suffix.
@export var spline_cp_bone_prefix: StringName = &""

## True for sacs with one opening (uterus, bladder). The distal
## centerline particle is pinned at a TerminalPin bone (or the
## host-frame fallback) rather than an exit orifice's Center.
@export var closed_terminal: bool = false

## Bone name of the terminal pin for closed-terminal sacs. If
## `closed_terminal == true` and this bone resolves, the AutoBaker
## uses its world position as the distal anchor. Otherwise falls back
## to `terminal_position_in_host_frame`.
@export var terminal_pin_bone: StringName = &""

## Host-frame fallback position for the distal anchor when
## `closed_terminal == true` and `terminal_pin_bone` doesn't resolve.
@export var terminal_position_in_host_frame: Vector3 = Vector3.ZERO

# ─── Resolution ────────────────────────────────────────────────────

## Number of axial cells in the `tunnel_state` texture (texture
## width). Default 32 per §6.12 sizing analysis.
@export_range(2, 256) var canal_axial_segments: int = 32

## Number of angular cells in the `tunnel_state` texture (texture
## height). Default 8 per §6.12 sizing analysis.
@export_range(2, 64) var canal_angular_sectors: int = 8

## Number of PBD centerline particles. Default 12; tune up for very
## curved canals (colon ~16), down for short/straight ones.
@export_range(2, 64) var centerline_particle_count: int = 12

# ─── Rest pose ─────────────────────────────────────────────────────

## Fallback axial-only rest radius profile, sampled at
## `s_k / canal_axial_segments`. Used when per-cell raycasts miss in
## AutoBaker step 7. Per-cell results from step 7 override this.
@export var rest_radius_profile: Curve

## Floor on the dynamic wall radius so a fully-contracted canal still
## has a tiny lumen (numerical safety).
@export var min_wall_radius: float = 0.001

# ─── Wall dynamics (texture path, 5F+) ─────────────────────────────

## First-order lag rate (1/s) for `dynamic_wall_radius` toward the
## per-cell target. Clamped at runtime to `1/dt − ε` for integration
## stability (§6.12.10).
@export_range(0.1, 240.0) var wall_response_rate: float = 30.0

## Enables the second-order ringing dynamics in §6.12.4 step 2h.
@export var use_second_order_wall: bool = false

## Acceleration gain for the second-order wall dynamics (when
## `use_second_order_wall` is true).
@export var wall_acceleration_gain: float = 1.0

## Velocity damping for the second-order wall dynamics.
@export var wall_damping: float = 5.0

## Which signal occupies the 4th channel of the RGBA32F
## `tunnel_state` texture: damage, wall_radial_velocity (for second-
## order ringing), or friction_mult (per-cell μ multiplier).
@export_enum("damage", "wall_radial_velocity", "friction_mult") \
		var fourth_channel_mode: int = 0

# ─── Plastic memory (radial) ───────────────────────────────────────

## Per-second rate at which `plastic_offset` accumulates from current
## stretch (§6.12.4 step 2i).
@export var plastic_accumulate_rate: float = 0.05

## Per-second recovery rate for `plastic_offset` toward zero.
@export var plastic_recover_rate: float = 0.001

## Hard cap on `plastic_offset`. Damaged cells get an effectively
## larger cap via `damage_plastic_gain`.
@export var plastic_max_offset: float = 0.02

# ─── Centerline particle chain (§6.12.1) ───────────────────────────

## XPBD compliance for inter-particle distance constraints on the
## centerline chain.
@export var centerline_distance_compliance: float = 1e-6

## XPBD compliance for the centerline chain's bending constraints.
@export var centerline_bending_compliance: float = 1e-4

## XPBD compliance for the spring-back to CP-bone rest positions.
@export var centerline_spring_back_compliance: float = 1e-3

## Compliance governing how much asymmetric wall pressure routes into
## the centerline as a lateral shift (§6.12.4 step 2f).
@export var centerline_lateral_compliance: float = 1e-2

## Lateral plastic memory accumulation rate (per-particle axis-
## lateral memory; §6.12.1 + 6.12.4 lateral split).
@export var lateral_plastic_accumulate_rate: float = 0.02

## Lateral plastic recovery rate.
@export var lateral_plastic_recover_rate: float = 0.0005

## Hard cap on lateral plastic offset magnitude.
@export var lateral_plastic_max_offset: float = 0.01

# ─── Curvature → wall asymmetry ────────────────────────────────────

## Gain for the centerline-curvature-driven wall asymmetry term
## (§6.12.4 step 2d). 0 disables; defaults to a visible-but-subtle
## response.
@export var curvature_response_gain: float = 0.3

# ─── Damage ────────────────────────────────────────────────────────

## Per-second rate at which `damage` accumulates from pressure
## (§6.12.4 step 2j).
@export var damage_rate: float = 0.05

## Multiplier on `plastic_max_offset` for cells with accumulated
## damage. Damaged tissue remodels with more permanent stretch.
@export var damage_plastic_gain: float = 5.0

## Subtractive friction loss per unit damage. Worn tissue is slipperier.
@export var damage_friction_loss: float = 0.5

# ─── Muscle / constriction (texture path, 5F+) ─────────────────────

## Multiplier on the per-cell muscle contraction in §6.12.4 step 2e.
@export var contraction_gain: float = 1.0

## Gain for the longitudinal-gradient surface velocity (§6.12.7).
@export var surface_vel_gain: float = 0.3

## Additive friction-multiplier bonus from per-cell muscle activation.
@export var muscle_friction_gain: float = 2.0

## Per-canal constriction zones. Default-empty; runtime sums each
## zone's smoothstep falloff into the per-cell muscle field.
##
## Note (`reference_godot_4_6_const_typed_array.md`): authoring
## defaults inline for `Array[CustomResource]` can trip the parser;
## leave default = `[]` and let the inspector add entries.
@export var constriction_zones: Array[CanalConstrictionZone] = []

## Optional baseline asymmetric muscle activation, sampled at
## `(s_norm, theta_norm)`. Folded additively into per-cell muscle in
## the integration loop.
@export var rest_muscle_field_2d: Texture2D

# ─── Active muscular curl (centerline) ─────────────────────────────

## Gain for Reverie-written per-particle `muscular_curl_delta` on the
## centerline chain (§6.12.1). Drives canal flex independent of
## radial squeeze.
@export var muscular_curl_gain: float = 1.0
