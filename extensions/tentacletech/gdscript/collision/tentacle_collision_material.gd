class_name TentacleCollisionMaterial
extends Resource

## Per-collider friction material consumed by TentacleTech's environment-probe
## pass. Attach via a `TentacleSurfaceTag` child of any `CollisionObject3D`;
## the tentacle composes (this, tentacle-implicit) per contact slot before
## the solver's friction step reads μ_s / μ_k.
##
## Direct port of Obi `Resources/Compute/CollisionMaterial.cginc:33-90`
## (slice 4S.3, 2026-05-11) restricted to friction. Stickiness /
## stickDistance / rollingFriction from Obi's original struct are
## deliberately omitted — they land alongside SolveAdhesion when that
## subsystem opens, not before. Dead-fields lesson from slice 4S.2's
## removed reseed API.
##
## Combine semantics: the tentacle never carries a `TentacleCollisionMaterial`
## (no resource attaches to a Tentacle node). Its implicit triple is
## (μ_s_tentacle, μ_k_tentacle, AVERAGE = 0), where the friction scalars
## come from `Tentacle.base_static_friction × (1 − tentacle_lubricity)`
## and the kinetic ratio. Per cginc:36 `max(a.combine, b.combine)` picks
## the rule, so any body-side `friction_combine > AVERAGE` wins — that's
## the documented "designer-friendly stack" intent. AVERAGE-tagged bodies
## get straight averaging with the tentacle implicit values.
##
## The combine helper itself lives on `PBDSolver.compose_friction_materials`
## (C++ static, bound via `ClassDB::bind_static_method`) — same pattern as
## `PBDSolver.compute_tension_taper_factor` from 4Q-fix. Tests + the
## environment-probe pass both call the C++ static so the formula has a
## single source of truth.

enum CombineMode {
	AVERAGE = 0,
	MIN = 1,
	MULTIPLY = 2,
	MAX = 3,
}

## Static friction coefficient. The friction step's static cone is
## `μ_s × normal_lambda`; tangent motion within the static cone is fully
## cancelled. Sensible authoring range [0.0, 2.0+]; values above ~1.0 are
## "very sticky" (e.g., rubber-on-rubber surrogate).
@export_range(0.0, 2.0, 0.01, "or_greater") var static_friction: float = 0.5

## Kinetic (dynamic) friction coefficient. Cap on the per-iter tangential
## λ delta once the static cone is breached. By convention 0.7-0.9× of
## `static_friction`. Independent field rather than a ratio so combine
## modes (Min / Max / Multiply) apply identically to both scalars.
@export_range(0.0, 2.0, 0.01, "or_greater") var dynamic_friction: float = 0.4

## Combine rule used when this material meets the tentacle's implicit
## AVERAGE material. `max(self.friction_combine, AVERAGE) = self.friction_combine`,
## so this field always wins. Applied identically to both static and
## dynamic friction scalars (matching cginc:39-64).
@export var friction_combine: CombineMode = CombineMode.AVERAGE
