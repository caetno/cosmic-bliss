@tool
class_name TentacleMood
extends Resource
## Behavioural preset for a [code]TentacleBehavior[/code] driver. Holds the
## knobs that vary by mood (curious / idle / probing / caressing) — physics
## character (collision_radius, friction, mass, segment_length, particle_count)
## stays on the [code]Tentacle[/code] node because those don't change when
## the same tentacle's mood swaps at runtime.
##
## Authoring flow: drag a [code].tres[/code] from [code]presets/moods/[/code]
## into the [code]mood[/code] slot on a TentacleBehavior. Values copy onto the
## driver's @exports; tweaking the resource (or hot-reloading from disk)
## re-applies via the [code]changed[/code] signal.
##
## Manual override: editing the driver's @exports directly still works — the
## last-applied mood values remain visible in the inspector and the user can
## modify them ad-hoc until the resource is re-assigned.

# --- Wave motion -----------------------------------------------------------

@export_group("Wave")
## Master wave intensity. Multiplies the sin + smooth-noise amplitudes
## (5%/3% of chain length at scale=1). 0 = still chain, 1 = baseline,
## 2 = roughly doubled swing.
@export_range(0.0, 3.0) var wave_amplitude_scale: float = 0.0
## Phase advance rate (rad/s implicit unit). Higher = faster swings.
@export_range(0.0, 20.0) var wave_temporal_freq: float = 2.0
## Rate the wave plane rotates around the rest axis. Positive = slow
## "wiping" sweep; alternating signs read as "looking around"; 0 = planar.
@export_range(-5.0, 5.0) var wave_drift_speed: float = 0.5
## Multiplier on the smooth-noise time input. Higher = jittery, lower =
## smoother. The noise component is what keeps the motion from looking
## metronomic.
@export_range(0.0, 10.0) var wave_noise_freq: float = 0.5
## Phase offset per particle (rad). Adjacent particles ride out of phase
## so motion reads as a *traveling* wave rather than a rigid swing.
@export_range(0.0, 3.0) var wave_spatial_phase: float = 0.7

# --- Thrust ----------------------------------------------------------------

@export_group("Thrust")
## Cycle rate of the load/strike thrust (Hz). 0 = no thrust (just wave).
## 1–2 Hz reads as deliberate; 3+ as agitated.
@export_range(0.0, 5.0) var thrust_frequency: float = 0.0
## Peak axial extension of strike, as fraction of chain length. Adds to
## [code]rest_extent[/code] on strike, subtracts on load.
@export_range(0.0, 0.5) var thrust_amplitude: float = 0.0
## Shifts the load/strike duty cycle. -1 = always retracting, 0 =
## symmetric, +1 = always thrusting.
@export_range(-1.0, 1.0) var thrust_bias: float = 0.0
## Symmetric phase reshape. 1.0 = pure sin; >1 = flat extremes + sharp
## transitions through zero (snake-strike snap).
@export_range(0.1, 4.0) var thrust_strike_sharpness: float = 1.0
## Body-coil amplitude during load. Lateral offset along the wave's
## primary axis, peaks mid-body. With [code]wave_drift_speed = 0[/code]
## reads as a planar S-curve thrust; non-zero drift makes it a corkscrew.
@export_range(0.0, 0.5) var coil_amplitude: float = 0.0

# --- Rest pose -------------------------------------------------------------

@export_group("Rest pose")
## Fraction of full chain length the chain stretches to in rest. < 1
## leaves slack so the wave can swing without maxing out distance
## constraints. The driver smooths transitions in this value when the
## mood swaps.
@export_range(0.0, 1.5) var rest_extent: float = 0.92

# --- Stiffness -------------------------------------------------------------

@export_group("Stiffness")
## Per-particle pose-target stiffness. Higher = pinned to the wave;
## lower = laggy / smeary. 0.10–0.20 reads "muscular but loose".
@export_range(0.0, 1.0) var pose_stiffness: float = 0.15

# --- Attractor -------------------------------------------------------------

@export_group("Attractor")
## How strongly the tip leans toward the [code]TentacleBehavior.attractor_path[/code]
## target. 0 = ignore, 1 = tip lerps fully. Tip-weighted: base barely
## moves so the wave on the body is preserved while the tip seeks.
@export_range(0.0, 1.0) var attractor_bias: float = 0.0

# --- Easing ----------------------------------------------------------------

@export_group("Easing")
## Smoothing rate (Hz) for amplitude transitions. Drag-changing knobs
## ease in/out at this rate instead of jumping; rate=8 → ~125 ms time
## constant; 0 disables.
@export_range(0.0, 60.0) var amplitude_smoothing_rate: float = 8.0
## Smooths the strike/load discontinuity at thrust_phase = 0. ~0.1 reads
## as a "deliberate breath" between cycles.
@export_range(0.0, 0.5) var thrust_phase_edge_smoothing: float = 0.1

# --- Time ------------------------------------------------------------------

@export_group("Time")
## Multiplier on dt before phase integration. 1 = real-time, 0.5 =
## half-speed, 0 = frozen wave. Useful for slow-mo / hit-stop / sensual
## moods.
@export var time_scale: float = 1.0
