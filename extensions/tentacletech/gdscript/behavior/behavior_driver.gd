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
## Pose distribution: motion amplitude grows from 0 at the base to peak at
## the tip via a `s_norm` envelope, so the base stays anchored and the tip
## swings — the chain's bending stiffness fills in the smooth body curve
## between them. The whole body moves coherently because every particle
## reads the same wave phase + perpendicular axes; only the per-particle
## spatial-phase offset differentiates them along the arc-length.

# --- Wiring ----------------------------------------------------------------

@export var enabled: bool = true
@export var tentacle_path: NodePath = NodePath("..") :
	set(v):
		tentacle_path = v
		_resolve_tentacle()

# --- Wave motion (the core) ------------------------------------------------

@export_group("Wave")
## Master wave intensity. Multiplies both the sin and smooth-noise
## amplitudes (which are 5% / 3% of chain length at scale=1). 0 = still,
## 2 = roughly doubled swing.
@export_range(0.0, 3.0) var wave_amplitude_scale: float = 1.0
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

@export_group("Thrust")
@export_range(0.0, 5.0) var thrust_frequency: float = 0.0     ## Hz
@export_range(0.0, 0.5) var thrust_amplitude: float = 0.0     ## fraction of chain length
@export_range(-1.0, 1.0) var thrust_bias: float = 0.0         ## -1 = always retracting; +1 = always thrusting

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

# --- Attractor (target bias) -----------------------------------------------

@export_group("Attractor")
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
@export var time_scale: float = 1.0
@export var randomize_phase_on_ready: bool = true

# --- Internal state --------------------------------------------------------

var _tentacle: Node3D = null
var _attractor: Node3D = null
var _wave_phase: float = 0.0
var _wave_drift_angle: float = 0.0
var _time: float = 0.0  # for thrust phase

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
		_time = randf() * 100.0
	_resolve_tentacle()
	_resolve_attractor()


func _physics_process(p_delta: float) -> void:
	if not enabled or _tentacle == null:
		return

	var dt: float = p_delta * time_scale
	_wave_phase += dt * wave_temporal_freq
	_wave_drift_angle += dt * wave_drift_speed
	_time += dt

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

	var thrust_phase: float = sin(_time * TAU * thrust_frequency) + thrust_bias
	var current_extent: float = rest_extent + thrust_amplitude * thrust_phase

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
	# Multiply by amplitude_scale for the master "intensity" knob.
	var amp_a: float = 0.05 * chain_len * wave_amplitude_scale
	var amp_b: float = 0.03 * chain_len * wave_amplitude_scale

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
		var rest_pos: Vector3 = rest_dir * (s_norm * chain_len * current_extent)

		var sin_term: float = sin(_wave_phase + float(k) * wave_spatial_phase)
		var noise_term: float = _smooth_noise(_wave_phase * wave_noise_freq, float(k))
		var offset: Vector3 = (perp1 * (amp_a * sin_term)
				+ perp2 * (amp_b * noise_term)) * s_norm

		var target_local: Vector3 = rest_pos + offset
		var target_world: Vector3 = xform * target_local

		if has_attractor:
			# Tip-weighted lerp: bias × s_norm. Base ≈ 0 weight, tip ≈ bias.
			target_world = target_world.lerp(attractor_pos,
					clampf(attractor_bias * s_norm, 0.0, 1.0))

		_pose_indices[k - 1] = k
		_pose_world_positions[k - 1] = target_world
		_pose_stiffnesses[k - 1] = pose_stiffness

	_tentacle.set_pose_targets(_pose_indices, _pose_world_positions, _pose_stiffnesses)


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
