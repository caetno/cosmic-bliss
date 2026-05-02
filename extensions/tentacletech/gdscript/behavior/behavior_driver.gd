@tool
class_name TentacleBehavior
extends Node3D
## Per-tick distributed pose-target driver. Motion model lifted from the
## legacy DPG wave: two perpendicular axes built from a slowly-rotating
## drift, one carrying a sin term and one carrying smooth-noise. Cheap,
## organic, deterministic, ~5 knobs. Drop as a child of a `Tentacle` node.
##
## Why DPG-style: the multi-curvature traveling-wave model proved hard to
## tune; too many independent frequencies/wavenumbers/phases interact
## non-intuitively. The DPG model collapses all that into a single phase
## accumulator + a single drift accumulator, with two amplitude scales for
## sin vs noise. The drift slowly rotates the wave plane around the
## tentacle's rest axis, which is what produces the "alive, exploring"
## feel without the user having to hand-tune wipe/curl/wiggle separately.
##
## Pose distribution: motion amplitude grows from 0 at the base via a
## `s_norm` envelope and then fades back to 0 inside a `tip_rigid_length`
## zone at the very end. The base stays anchored, the body curls, and
## the tip stays balanced — bending stiffness + distance constraints
## resolve any thrust slack as lateral coil rather than tip retraction
## (which is what produced the legacy backward-corkscrew on retract).
## Every particle reads the same wave phase + perpendicular axes; only
## the spatial-phase offset along the arc differentiates them.

# --- Wiring ----------------------------------------------------------------

## When false, the driver stops writing pose targets and clears any it had set.
## The chain falls back to gravity + bending only — useful for stunning the
## tentacle (frozen in place) or temporarily handing control to another driver.
@export var enabled: bool = true
## Path to the [code]Tentacle[/code] node this driver writes pose targets to.
## Default ".." assumes the driver is a direct child of the Tentacle, which
## matches the recommended scene layout.
@export var tentacle_path: NodePath = NodePath("..") :
	set(v):
		tentacle_path = v
		_resolve_tentacle()

# --- Wave motion (the core) ------------------------------------------------

@export_group("Wave")
## Master wave intensity. Multiplies both the sin and smooth-noise
## amplitudes (which are 5% / 3% of chain length at scale=1). 0 = still
## (default — wave / corkscrew is opt-in), 2 = roughly doubled swing.
## With `wave_spatial_phase = 0.7` and ~16 particles the chain bakes
## ~1.7 wavelengths along its length, which reads as a multi-bend
## S-curve — only enable when that's the look you want.
@export_range(0.0, 3.0) var wave_amplitude_scale: float = 0.0
## How fast the wave phase advances. Higher = faster swings.
@export_range(0.0, 20.0) var wave_temporal_freq: float = 2.0
## Rate at which the wave plane rotates around the rest axis. Positive
## values give a slow "wiping" sweep; alternating signs read as the
## tentacle "looking around". Set to 0 for purely-planar motion.
@export_range(-5.0, 5.0) var wave_drift_speed: float = 0.5
## Multiplier on the smooth-noise time input — higher = jittery, lower
## = smoother. The noise component breaks the otherwise-too-clean sin
## term and is what keeps the motion from looking metronomic.
@export_range(0.0, 10.0) var wave_noise_freq: float = 0.5
## Phase offset per particle along the chain (rad). Adjacent particles
## ride slightly out of phase so the motion reads as a *traveling* wave
## down the body rather than a rigid swing.
@export_range(0.0, 3.0) var wave_spatial_phase: float = 0.7

# --- Thrust (axial extend/retract) -----------------------------------------
#
# Thrust is split between body and tip on purpose. A snake-strike pose
# loads slack into the *body* (lateral coil) while the tip stays roughly
# put, then unloads forward through the chain. Modelling thrust as a
# uniform `s_norm * extent` axial scale would make the *tip* absorb the
# most motion — exactly the opposite — and combined with the wave-plane
# drift that reads as a backward corkscrew on retract. Instead we keep a
# `tip_rigid_length` zone where wave + thrust modulation fade toward the
# tip, and let bending stiffness express the slack as body curl.

@export_group("Thrust")
## Cycle rate of the load/strike thrust (Hz). 0 = no thrust (just wave).
## Combine with [member thrust_amplitude] to set how aggressive the strike
## is; 1–2 Hz reads as deliberate, 3+ as agitated.
@export_range(0.0, 5.0) var thrust_frequency: float = 0.0
## Peak axial extension of the strike, expressed as a fraction of chain
## length. Adds to [member rest_extent] on strike, subtracts on load. 0
## disables thrust without changing the cycle clock.
@export_range(0.0, 0.5) var thrust_amplitude: float = 0.0
## Shifts the load/strike duty cycle. -1 = always retracting (load only),
## 0 = symmetric, +1 = always thrusting (strike only). Combine with
## [member thrust_strike_sharpness] for explosive snake-strike timing.
@export_range(-1.0, 1.0) var thrust_bias: float = 0.0
## Length of tip-quiet zone (m) where wave/thrust fade out. Body coils
## below it; tip stays balanced. Set 0 for legacy uniform-scale behavior.
@export_range(0.0, 0.5) var tip_rigid_length: float = 0.08
## How much of the body's *strike* (positive) extension carries to the
## tip. 1.0 = tip extends as far as body on strike but never retracts on
## load; 0.0 = tip is pinned to rest_extent regardless of phase.
@export_range(0.0, 1.0) var tip_strike_share: float = 1.0
## Symmetric phase reshape. 1.0 = pure sin. >1 = flat extremes + sharp
## transitions through zero (reads as a snap). Combine with `thrust_bias`
## to weight the cycle toward load or strike.
@export_range(0.1, 4.0) var thrust_strike_sharpness: float = 1.0
## Explicit body-coil amplitude during load (negative thrust phase).
## Lateral offset along the wave's primary axis (`perp1`), enveloped by a
## `4·s·(1-s)` hill so it peaks mid-body and is zero at base + tip.
## Combine with `wave_drift_speed = 0` for a planar S-curve thrust;
## non-zero drift rotates the coil into a corkscrew. Fraction of chain
## length, applied only when thrust_phase < 0. 0 by default — opt in
## explicitly when a load/strike coil or corkscrew is wanted.
@export_range(0.0, 0.5) var coil_amplitude: float = 0.0

# --- Rest pose -------------------------------------------------------------

@export_group("Rest pose")
## Direction the chain rests along, in tentacle-local space. Default -Z
## matches `Tentacle::initialize_chain`'s spawn axis.
@export var rest_direction: Vector3 = Vector3(0.0, 0.0, -1.0)
## Fraction of full chain length the chain stretches to in rest. < 1
## leaves slack so the wave can swing without immediately maxing out
## distance constraints.
@export_range(0.0, 1.5) var rest_extent: float = 0.92

# --- Pose pull stiffness ---------------------------------------------------

@export_group("Stiffness")
## Per-particle pose-target stiffness. Higher = pinned to the wave;
## lower = laggy / smeary. 0.10–0.20 reads "muscular but loose".
@export_range(0.0, 1.0) var pose_stiffness: float = 0.15

# --- Easing ----------------------------------------------------------------
#
# Two flavors of easing applied to the motion:
#
# 1. Amplitude smoothing (temporal). When you flip wave / coil / thrust /
#    rest_extent at runtime, the change is exp-smoothed instead of jumping.
#    This is what makes "turn on the wave" read as a fade-in rather than
#    an instant snap, and stops kinks in the chain when knobs are dragged
#    in the inspector during play.
# 2. Smoothmax on the strike/load split. The legacy `max(0, thrust_phase)`
#    has a kink at thrust_phase = 0 (where tip extension and coil load
#    flip on/off). A smoothmax replaces it with a C1-continuous curve so
#    motion through zero feels rolled, not snapped.

@export_group("Easing")
## Time-constant rate for amplitude smoothing (Hz). Higher = faster
## response, less easing; lower = slower, smoother. Applies to
## wave_amplitude_scale, coil_amplitude, thrust_amplitude, and
## rest_extent. With rate=8 the time constant is ~125 ms (gentle
## ease-in/out); rate=20 is ~50 ms (snappier); 0 disables smoothing.
@export_range(0.0, 60.0) var amplitude_smoothing_rate: float = 8.0

## Smooths the strike/load discontinuity at thrust_phase = 0. 0 = legacy
## hard switch (kink at zero crossing); positive values produce a
## C1-continuous transition between strike and load halves. ~0.1 reads
## as "deliberate breath" between cycles.
@export_range(0.0, 0.5) var thrust_phase_edge_smoothing: float = 0.1

# --- Attractor (target bias) -----------------------------------------------

@export_group("Attractor")
## Optional [code]Node3D[/code] the tip is biased toward each tick. Leave
## empty to disable. The bias respects the wave: the body keeps moving,
## the tip leans toward the attractor with weight [member attractor_bias].
@export var attractor_path: NodePath :
	set(v):
		attractor_path = v
		_resolve_attractor()
## 0 = ignore; 1 = tip lerps fully to attractor (base stays anchored).
## Bias is *tip-weighted*: base barely moves, tip moves a lot — preserves
## the wave on the body while the tip seeks the attractor.
@export_range(0.0, 1.0) var attractor_bias: float = 0.0
## If > 0, clamp the attractor's world position to within this radius of
## the tentacle's anchor before lerping. Prevents the tip-pull from
## yanking the chain past its physical reach.
@export var attractor_max_distance: float = 0.0

# --- Time ------------------------------------------------------------------

@export_group("Time")
## Multiplier on dt before phase integration. 1.0 = real-time; 0.5 =
## half-speed (everything moves slower); 0 = frozen wave (rest pose
## still renders). Useful for slow-mo / hit-stop / pause.
@export var time_scale: float = 1.0
## When true, the wave / drift / noise / thrust phases are seeded with
## random offsets at [code]_ready[/code] so multiple tentacles in the
## same scene don't move in lockstep. Disable for deterministic tests.
@export var randomize_phase_on_ready: bool = true

# --- Mass distribution -----------------------------------------------------

@export_group("Mass from girth")
## When true, on _ready / refresh_wiring the per-particle inverse mass
## is sampled from the Tentacle's assigned `TentacleMesh` girth profile
## (mass ∝ girth^exponent — heavier base, lighter tip → more whip-snap).
## Particle 0 (anchor) is never written.
@export var mass_from_girth: bool = false :
	set(v):
		mass_from_girth = v
		_apply_mass_from_girth()
## 2.0 = cross-section area (right exponent for a uniform-length chain).
## Drop toward 1.0 for milder taper, push toward 3.0 for very-light tip.
@export_range(0.5, 4.0) var mass_exponent: float = 2.0 :
	set(v):
		mass_exponent = v
		_apply_mass_from_girth()
## Multiplier on the resulting mass. 1.0 = unit-mass at peak girth.
@export_range(0.01, 100.0) var mass_scale: float = 1.0 :
	set(v):
		mass_scale = v
		_apply_mass_from_girth()

# --- Internal state --------------------------------------------------------

var _tentacle: Node3D = null
var _attractor: Node3D = null
# Wave kinematic phases. All integrated (`+= dt * rate`) so the user can
# change freqs at runtime without seeing a jump in the sin/noise output.
# A multiplied formulation (sin(t * f) with mutable f) jumps by t·Δf
# whenever f changes — that's the jitter the user reported.
var _wave_phase: float = 0.0
var _wave_drift_angle: float = 0.0
var _noise_phase: float = 0.0
var _thrust_phase_t: float = 0.0  # accumulated radians for sin(thrust)

# Exp-smoothed mirrors of the user-facing amplitude / extent knobs. Read
# these in the per-tick math (never the @export vars directly) so changes
# to the inspector knobs ease in over `amplitude_smoothing_rate` instead
# of snapping. Initialized to the user values in _ready so scene load
# doesn't fade in from zero.
var _smoothed_wave_amp: float = 0.0
var _smoothed_coil_amp: float = 0.0
var _smoothed_thrust_amp: float = 0.0
var _smoothed_rest_extent: float = 0.0

# Pre-allocated buffers — sized once on first use, resized only when
# particle_count changes. Keeps the physics tick alloc-free.
var _pose_indices: PackedInt32Array = PackedInt32Array()
var _pose_world_positions: PackedVector3Array = PackedVector3Array()
var _pose_stiffnesses: PackedFloat32Array = PackedFloat32Array()
var _last_pose_size: int = -1


func _ready() -> void:
	if randomize_phase_on_ready and not Engine.is_editor_hint():
		_wave_phase = randf() * TAU
		_wave_drift_angle = randf() * TAU
		_noise_phase = randf() * 100.0
		_thrust_phase_t = randf() * TAU
	# Snap smoothing state to the user-set values so scene load uses them
	# directly, not a fade-in from zero. Only runtime mutations of the
	# knobs (inspector drag during play, GDScript writes) ease in.
	_smoothed_wave_amp = wave_amplitude_scale
	_smoothed_coil_amp = coil_amplitude
	_smoothed_thrust_amp = thrust_amplitude
	_smoothed_rest_extent = rest_extent
	_resolve_tentacle()
	_resolve_attractor()
	_apply_mass_from_girth()


func _physics_process(p_delta: float) -> void:
	if not enabled or _tentacle == null:
		return

	var dt: float = p_delta * time_scale
	# All phases are integrated (`phase += dt * rate`) rather than
	# computed as `sin(t * rate)`. The latter jumps by `t * Δrate` the
	# moment the user changes a frequency knob — that's the jitter on
	# wave_noise_freq / thrust_frequency the user flagged.
	_wave_phase += dt * wave_temporal_freq
	_wave_drift_angle += dt * wave_drift_speed
	_noise_phase += dt * wave_temporal_freq * wave_noise_freq
	_thrust_phase_t += dt * TAU * thrust_frequency

	# Exponential easing on amplitude knobs. Time-constant blend factor:
	# `1 - exp(-dt * rate)` is dt-correct (no frame-rate dependence) and
	# converges to the target with no overshoot. rate ≤ 0 short-circuits
	# straight to target (no smoothing).
	if amplitude_smoothing_rate > 0.0:
		var t: float = 1.0 - exp(-dt * amplitude_smoothing_rate)
		_smoothed_wave_amp = lerpf(_smoothed_wave_amp, wave_amplitude_scale, t)
		_smoothed_coil_amp = lerpf(_smoothed_coil_amp, coil_amplitude, t)
		_smoothed_thrust_amp = lerpf(_smoothed_thrust_amp, thrust_amplitude, t)
		_smoothed_rest_extent = lerpf(_smoothed_rest_extent, rest_extent, t)
	else:
		_smoothed_wave_amp = wave_amplitude_scale
		_smoothed_coil_amp = coil_amplitude
		_smoothed_thrust_amp = thrust_amplitude
		_smoothed_rest_extent = rest_extent

	var n: int = _tentacle.particle_count
	var seg: float = _tentacle.segment_length
	var chain_len: float = float(n) * seg
	if chain_len <= 0.0 or n < 2:
		return

	# --- Rest direction + thrust-modulated extent ------------------------

	var rest_dir: Vector3 = rest_direction
	if rest_dir.length_squared() < 1e-6:
		rest_dir = Vector3(0.0, 0.0, -1.0)
	rest_dir = rest_dir.normalized()

	# Sharpness reshape: |sin|^(1/k) preserves [-1,1] but flattens the
	# extremes when k>1 (long load + long strike, fast snap through zero).
	var raw_phase: float = sin(_thrust_phase_t)
	var shaped_phase: float
	if is_equal_approx(thrust_strike_sharpness, 1.0):
		shaped_phase = raw_phase
	else:
		shaped_phase = signf(raw_phase) * pow(absf(raw_phase),
				1.0 / thrust_strike_sharpness)
	var thrust_phase: float = clampf(shaped_phase + thrust_bias, -1.5, 1.5)

	# Body load-then-strike split is only valid when there's a lateral
	# release path for the slack — coil_amplitude provides that. Without
	# it, body retraction has nowhere to go: the pose curve compresses
	# axially every load half-cycle and the chain pulses back and forth
	# (the "accordion"). When coil is off, fall back to a uniform
	# extension-only pulse so the chain thrusts forward as a steel-wire
	# unit and rest-extent on load.
	var has_lateral_release: bool = _smoothed_coil_amp > 1e-4
	# Soft-max replacement for `max(0, thrust_phase)` so the strike/load
	# split has no kink at thrust_phase = 0. Edge ≈ 0 reproduces the legacy
	# hard switch.
	var strike: float = _smoothmax_zero(thrust_phase, thrust_phase_edge_smoothing)
	var body_factor: float
	var tip_factor: float
	if has_lateral_release:
		body_factor = _smoothed_rest_extent + _smoothed_thrust_amp * thrust_phase
		tip_factor = (_smoothed_rest_extent
				+ _smoothed_thrust_amp * strike * tip_strike_share)
	else:
		var pulse: float = _smoothed_thrust_amp * strike
		body_factor = _smoothed_rest_extent + pulse
		tip_factor = _smoothed_rest_extent + pulse

	# tip_env(s): 1.0 in body, smooth falloff to 0 in the top
	# `tip_rigid_length` of the chain. Used to lerp body↔tip thrust
	# factors and to gate the wave amplitude.
	var tip_rigid_norm: float = clampf(tip_rigid_length / chain_len, 0.0, 1.0)

	# --- Two perpendicular wave axes (DPG model) -------------------------
	#
	# perp1 = perp_base rotated around rest_dir by drift_angle (Rodrigues).
	# perp2 = rest_dir × perp1. As wave_drift_angle advances, the (perp1,
	# perp2) plane rotates around rest_dir — the wave's bend plane sweeps
	# around the tentacle's axis. That sweep is what reads as "alive".

	var helper: Vector3 = Vector3.UP
	if absf(rest_dir.dot(helper)) > 0.95:
		helper = Vector3.RIGHT
	var perp_base: Vector3 = (helper - rest_dir * rest_dir.dot(helper)).normalized()

	var ca: float = cos(_wave_drift_angle)
	var sa: float = sin(_wave_drift_angle)
	var perp1: Vector3 = (perp_base * ca
			+ rest_dir.cross(perp_base) * sa
			+ rest_dir * (rest_dir.dot(perp_base) * (1.0 - ca)))
	var perp2: Vector3 = rest_dir.cross(perp1).normalized()

	# DPG canonical amplitudes — sin gets ~5% of length, noise ~3%.
	# Multiply by smoothed master scale so inspector tweaks ease in.
	var amp_a: float = 0.05 * chain_len * _smoothed_wave_amp
	var amp_b: float = 0.03 * chain_len * _smoothed_wave_amp

	# --- Pose target buffer (alloc once per chain size) ------------------

	var pose_n: int = n - 1
	if _last_pose_size != pose_n:
		_pose_indices.resize(pose_n)
		_pose_world_positions.resize(pose_n)
		_pose_stiffnesses.resize(pose_n)
		_last_pose_size = pose_n

	var xform: Transform3D = _tentacle.global_transform

	# --- Resolved attractor world pos (one-shot per tick) ----------------

	var has_attractor: bool = _attractor != null and attractor_bias > 0.0
	var attractor_pos: Vector3 = Vector3.ZERO
	if has_attractor:
		attractor_pos = _attractor.global_position
		if attractor_max_distance > 0.0:
			var anchor_pos: Vector3 = _tentacle.global_position
			var to_a: Vector3 = attractor_pos - anchor_pos
			var dist: float = to_a.length()
			if dist > attractor_max_distance and dist > 1e-6:
				attractor_pos = anchor_pos + to_a * (attractor_max_distance / dist)

	# --- Per-particle synthesis -----------------------------------------

	# Skip particle 0 (anchored). For each k ∈ [1, n-1], compose:
	#   target = rest_dir * s_k * extent  +  s_k * (perp1·A·sin + perp2·B·noise)
	# The s_k envelope on the wave amplitude makes the base barely move and
	# the tip swing freely — body bend is emergent from chain stiffness.

	var inv_n_minus_1: float = 1.0 / float(n - 1)
	for k in range(1, n):
		var s_norm: float = float(k) * inv_n_minus_1

		# tip_env: 1 in body, smoothly falls to 0 inside the rigid tip zone.
		var tip_env: float = 1.0
		if tip_rigid_norm > 1e-4:
			tip_env = 1.0 - smoothstep(1.0 - tip_rigid_norm, 1.0, s_norm)

		var axial_factor: float = lerpf(tip_factor, body_factor, tip_env)
		var rest_pos: Vector3 = rest_dir * (s_norm * chain_len * axial_factor)

		var sin_term: float = sin(_wave_phase + float(k) * wave_spatial_phase)
		var noise_term: float = _smooth_noise(_noise_phase, float(k))
		var offset: Vector3 = (perp1 * (amp_a * sin_term)
				+ perp2 * (amp_b * noise_term)) * s_norm * tip_env

		# Explicit body coil during load. Hill envelope (4·s·(1-s)) peaks
		# mid-body, zero at base + tip. Locked to perp1 so wave_drift_speed
		# determines whether the coil is planar (drift=0 → S-curve) or
		# rotates with the wave plane (drift>0 → corkscrew). Uses
		# smoothmax(-thrust_phase) so the load envelope rolls into and
		# out of zero rather than snapping at thrust_phase = 0.
		var load_amount: float = _smoothmax_zero(-thrust_phase,
				thrust_phase_edge_smoothing)
		var coil_env: float = 4.0 * s_norm * (1.0 - s_norm)
		var coil_offset: Vector3 = perp1 * (_smoothed_coil_amp * load_amount
				* coil_env * chain_len * tip_env)

		var target_local: Vector3 = rest_pos + offset + coil_offset
		var target_world: Vector3 = xform * target_local

		if has_attractor:
			# Tip-weighted lerp: bias × s_norm. Base ≈ 0 weight, tip ≈ bias.
			target_world = target_world.lerp(attractor_pos,
					clampf(attractor_bias * s_norm, 0.0, 1.0))

		_pose_indices[k - 1] = k
		_pose_world_positions[k - 1] = target_world
		_pose_stiffnesses[k - 1] = pose_stiffness

	_tentacle.set_pose_targets(_pose_indices, _pose_world_positions, _pose_stiffnesses)


# Soft equivalent of max(x, 0): C∞ continuous, identical to max away from
# 0, smoothly rolled around 0. p_edge controls how wide the rolled region
# is (0 reproduces hard max). Used to remove the kink at thrust_phase = 0
# in the strike-only and load-only legs of the thrust split.
static func _smoothmax_zero(p_x: float, p_edge: float) -> float:
	if p_edge < 1e-5:
		return maxf(0.0, p_x)
	return 0.5 * (p_x + sqrt(p_x * p_x + p_edge * p_edge))


# DPG smooth pseudo-noise. Sum of three sines at irrationally-related
# frequencies, normalized to roughly [-1, +1]. Cheap, deterministic, no
# FastNoiseLite alloc — and the irrational ratios prevent obvious
# repetition at any reasonable timescale.
static func _smooth_noise(p_t: float, p_offset: float) -> float:
	var a: float = sin(p_t * 1.7 + p_offset * 3.1)
	var b: float = sin(p_t * 0.9 + p_offset * 7.3 + 1.234)
	var c: float = sin(p_t * 2.3 + p_offset * 11.7 + 5.678)
	return (a + b + c) * (1.0 / 3.0)


# --- Wiring helpers --------------------------------------------------------

func _resolve_tentacle() -> void:
	_tentacle = null
	if tentacle_path.is_empty():
		return
	var n: Node = get_node_or_null(tentacle_path)
	if n != null and n is Node3D and n.has_method("set_pose_targets"):
		_tentacle = n


func _resolve_attractor() -> void:
	_attractor = null
	if attractor_path.is_empty():
		return
	var n: Node = get_node_or_null(attractor_path)
	if n is Node3D:
		_attractor = n


func refresh_wiring() -> void:
	_resolve_tentacle()
	_resolve_attractor()
	_apply_mass_from_girth()


# Pulled out of `_ready` and exposed via the property setters so
# toggling `mass_from_girth` (or tweaking `mass_exponent` / `mass_scale`)
# in the inspector re-applies without a scene reload. Silently no-ops
# when the tentacle / mesh / extension aren't ready yet — common during
# editor scene-load order.
func _apply_mass_from_girth() -> void:
	if not mass_from_girth:
		return
	if _tentacle == null:
		return
	if not _tentacle.has_method("get_tentacle_mesh"):
		return
	if not ClassDB.class_exists("Tentacle"):
		return
	var GirthMass := preload(
			"res://addons/tentacletech/scripts/util/tentacle_mass.gd")
	GirthMass.apply_from_mesh(_tentacle, mass_scale, mass_exponent)
