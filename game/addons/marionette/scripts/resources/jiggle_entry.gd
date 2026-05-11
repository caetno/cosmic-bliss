@tool
class_name JiggleEntry
extends Resource

## Per-bone soft-tissue tuning, stored on JiggleProfile.entries[bone_name].
## Marionette._build_jiggle_bone reads this at Build Ragdoll and converts
## to per-bone stiffness/damping via mass-portable SPD math
## (ω = TAU / reach, k = m·ω², c = 2·ζ·ω·m).

## Spring settle time in seconds. Lower = stiffer / snappier; higher =
## bouncier / floppier. 0.3 is a good baseline for breast tissue.
@export_range(0.05, 2.0, 0.01) var reach_seconds: float = 0.3

## Damping ratio. 0 = free oscillation (rings forever), 1 = critical
## (returns without overshoot), >1 = overdamped (slow return). 0.7 is
## slightly underdamped — small wobble after a step, no resonance.
@export_range(0.0, 2.0, 0.01) var damping_ratio: float = 0.7
