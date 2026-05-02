@tool
class_name JiggleEntry
extends Resource

# Per-bone soft-tissue tuning, stored on JiggleProfile.entries[bone_name].
# Consumed by Marionette._build_jiggle_bone at ragdoll build time —
# converted into stiffness/damping on the spawned JiggleBone via the
# mass-portable SPD math (omega = 2π / reach, k = m·ω², c = 2·ζ·ω·m).
#
# Two scalars only for v1 — tuning a real soft region rarely needs more.
# Linear-excursion budget and mass override are candidates for future
# expansion; for now both are global constants in `_build_jiggle_bone`.

# Reach time in seconds: how long the spring takes to settle from a
# step-displacement back to rest. Lower = stiffer / snappier; higher =
# bouncier / floppier. 0.3 is a good baseline for breast tissue.
@export_range(0.05, 2.0, 0.01) var reach_seconds: float = 0.3

# Damping ratio: 0 = free oscillation (rings forever), 1 = critical
# (returns without overshoot), >1 = overdamped (slow return). 0.7 is
# slightly underdamped — small wobble after a step, no resonance.
@export_range(0.0, 2.0, 0.01) var damping_ratio: float = 0.7
