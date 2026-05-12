class_name CanalConstrictionZone
extends Resource

## Per-zone constriction descriptor consumed by §6.12.4 step 2a.
## Stored on `CanalParameters.constriction_zones`. The runtime
## integration loop evaluates each zone's smoothstep falloff against
## `(s_k − arc_length_s)` and folds the result into the per-cell
## muscle activation. Six fields, one-to-one with the §6.12.3 struct.

## Position along the canal centerline, in arc-length units (m).
@export var arc_length_s: float = 0.0

## Axial extent of the zone (m). Falloff is smoothstep from full at
## `arc_length_s` to zero at `arc_length_s ± half_width`.
@export var half_width: float = 0.05

## Peak tightness inside the zone, 0..1. Multiplied with
## `current_strength` and the zone's smoothstep falloff before being
## added to the per-cell muscle scalar.
@export_range(0.0, 1.0, 0.01) var max_contraction: float = 0.5

## Reverie-modulated strength, 0..1. The runtime (5F+) reads this each
## tick; Reverie writes it via the modulation channel.
@export_range(0.0, 1.0, 0.01) var current_strength: float = 0.0

## Per-cell μ multiplier bonus inside the zone — adds on top of the
## tentacle's composed friction (§4.3 + 4S.3). Used when a zone should
## grip more than the rest of the canal wall.
@export var friction_bonus: float = 0.0

## Fraction of this zone's contraction already baked into the rest
## mesh (so the runtime adds only the delta beyond the rest pose).
## 0 = nothing baked (full live contraction); 1 = all baked
## (no live contraction needed). Useful for static sphincter-like
## features authored into the canal interior mesh.
@export_range(0.0, 1.0, 0.01) var baked_at_rest: float = 0.0
