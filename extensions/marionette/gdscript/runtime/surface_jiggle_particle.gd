@tool
class_name SurfaceJiggleParticle
extends Node3D

## Translation-only SPD virtual particle, driven by a SurfaceJiggleAttachment
## (body_field §17.5). Pure Node3D — no Jolt body, no collision hull —
## distinct from JiggleBone (PhysicalBone3D + hull). Spawned by
## Marionette.build_ragdoll Pass 4 for every SurfaceJiggleAttachment in the
## bound BodySurfaceField.attachments list.
##
## Physics is identical in shape to JiggleBone's: critically-tunable
## (reach_seconds, damping_ratio) → (ω, ζ) → mass-cancelled (stiffness=ω²,
## damping=2ζω) → semi-implicit Euler. Mass is implicit unity — the particle
## has no Jolt body to scale, so build-time derivation skips the m factor
## that JiggleBone applies via hull-volume × tissue density.
##
## Snapshot discipline (Mar-I5 fix style): host bone pose + skeleton world
## are cached once per _physics_process tick. SPD step reads only the cache.
## SurfaceJiggleParticle lives outside the PhysicalBoneSimulator3D so there's
## no Jolt parallel-dispatch race today, but the discipline is the same
## (kinematic_targets composers in body_field v1.5+ may write bone poses
## mid-frame; staying snapshot-based is forward-compatible).

## Skeleton bone the particle hangs off; named at spawn time for
## diagnostics. Resolution to the skeleton-index happens in configure_spring.
@export var host_bone_name: StringName = &""

## Stiffness ω² = (TAU / reach_seconds)². Mass-cancelled — no m factor;
## the particle is treated as unit mass. Set by Marionette at spawn time
## via the same JiggleProfile lookup JiggleBone uses, so the two paths share
## per-region tuning.
@export var stiffness: float = 0.0

## Damping coefficient 2ζω. Mass-cancelled, same as stiffness.
@export var damping: float = 0.0

# Cached refs populated by configure_spring. The seed position arrives in
# skeleton-local (≈ body-mesh local) frame; we pre-multiply by the host
# bone's global-rest inverse so the per-tick math matches JiggleBone's
# host_pose × bone_local_offset shape (no extra inversion in the hot path).
var _skel: Skeleton3D = null
var _host_skel_idx: int = -1
var _seed_in_bone_local: Transform3D = Transform3D.IDENTITY

# Spring state.
var _velocity: Vector3 = Vector3.ZERO

# Per-frame snapshots, populated in _physics_process and read by the SPD
# step that runs in the same callback. Kept as fields (not locals) so unit
# tests can inspect the snapshot value the SPD step actually used.
var _cached_host_global: Transform3D = Transform3D.IDENTITY
var _cached_skel_world: Transform3D = Transform3D.IDENTITY

# Armed by configure_spring once the skeleton refs + seed are set. The
# _physics_process and _compute_target_world paths both early-out when
# this is false, so an unconfigured particle is a no-op in the editor.
var _spring_enabled: bool = false


## Wires the skeleton refs, pre-computes the seed offset in host-bone-local
## frame, and primes the per-frame snapshot cache so the first physics tick
## already has valid targets (no phantom 1-tick spring kick toward world
## origin). Mirrors JiggleBone.configure_spring's contract.
func configure_spring(skel: Skeleton3D, host_skel_idx: int, seed_position_mesh_local: Vector3) -> void:
	_skel = skel
	_host_skel_idx = host_skel_idx
	# Convert seed_position from skeleton-local (≈ body-mesh local; the
	# convention assumes mesh transform = identity relative to skeleton —
	# kasumi-class scenes hold this. Heroes that need an explicit
	# mesh-to-skel transform can compose it into seed_position before
	# authoring.) into host-bone-local frame. After this, the runtime hot
	# path is identical in shape to JiggleBone's: host_pose × bone_local.
	var host_rest_global: Transform3D = skel.get_bone_global_rest(host_skel_idx)
	_seed_in_bone_local = host_rest_global.affine_inverse() * Transform3D(Basis.IDENTITY, seed_position_mesh_local)
	_spring_enabled = true
	# Prime snapshots. Guard on is_inside_tree() so the synthetic-skeleton
	# unit-test harness (which adds Skeleton3D pre-ENTER_TREE) doesn't
	# push_error on get_global_transform — matches JiggleBone's guard.
	if _skel.is_inside_tree():
		_cached_host_global = _skel.get_bone_global_pose(_host_skel_idx)
		_cached_skel_world = _skel.global_transform
	# Park the particle at the rest target so the first SPD tick sees zero
	# error (no startup kick). Use position vs global_position based on tree
	# state — global_position errors pre-ENTER_TREE.
	var target_world: Vector3 = _compute_target_world(_cached_host_global, _cached_skel_world, _seed_in_bone_local)
	if is_inside_tree():
		global_position = target_world
	else:
		position = target_world
	_velocity = Vector3.ZERO


## Pure helper, mirrors JiggleBone._compute_target_world. Returns the world-
## space position the spring rest pulls toward, given the three snapshot
## transforms. Static + pure so unit tests can pin the math without
## constructing a Node3D + Skeleton3D pair.
static func _compute_target_world(host_global: Transform3D, skel_world: Transform3D, seed_in_bone_local: Transform3D) -> Vector3:
	var target_local_to_skel: Transform3D = host_global * seed_in_bone_local
	return (skel_world * target_local_to_skel).origin


## Pure helper for the SPD step. Semi-implicit Euler:
##   v_new = v + (stiffness * error − damping * v) * dt
##   x_new = x + v_new * dt
## Mass-cancelled form — stiffness = ω², damping = 2ζω. Unconditionally
## stable for damped harmonic oscillators at any dt > 0. Static + pure so
## the SPD math is unit-testable in isolation.
static func _spd_step(
		position_world: Vector3,
		velocity: Vector3,
		target_world: Vector3,
		stiffness: float,
		damping: float,
		dt: float) -> Array:
	var error: Vector3 = target_world - position_world
	var accel: Vector3 = stiffness * error - damping * velocity
	var v_new: Vector3 = velocity + accel * dt
	var p_new: Vector3 = position_world + v_new * dt
	return [p_new, v_new]


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if not _spring_enabled or _skel == null or _host_skel_idx < 0:
		return
	# Snapshot once per physics frame; SPD step below reads the cache.
	_cached_host_global = _skel.get_bone_global_pose(_host_skel_idx)
	_cached_skel_world = _skel.global_transform
	var target_world: Vector3 = _compute_target_world(_cached_host_global, _cached_skel_world, _seed_in_bone_local)
	var result: Array = _spd_step(global_position, _velocity, target_world, stiffness, damping, delta)
	global_position = result[0]
	_velocity = result[1]
