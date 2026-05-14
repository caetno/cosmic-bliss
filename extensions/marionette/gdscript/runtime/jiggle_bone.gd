@tool
class_name JiggleBone
extends PhysicalBone3D

## Translation-driven soft-tissue body — breast, glute, belly. Spawned
## alongside the regular MarionetteBones at Build Ragdoll. CLAUDE.md §15.
##
## Joint setup locks all 3 angular axes (no rotation vs host) and
## exposes a small linear excursion budget per axis. Physics offsets the
## body's position from its skin-driven rest; translation-only SPD
## spring-damps it back.
##
## Sibling class to MarionetteBone — both extend PhysicalBone3D directly.
## JiggleBone does not carry a BoneEntry (no anatomical-frame metadata).

## Skeleton bone whose pose drives this jiggle body's rest position. For
## ARP breast bones, the bone's skeleton parent (UpperChest); for custom
## rigs the host can be different.
@export var host_bone_name: StringName = &""

## Spring stiffness in N/m. Marionette.build_ragdoll derives this from
## the JiggleProfile's reach time × bone mass; exposed for direct tuning
## (tightens / loosens a specific bone without touching the profile).
@export var stiffness: float = 0.0

## Spring damping in N·s/m. Critical damping for a given k/m is 2·√(k·m);
## ~0.7×critical gives a natural soft-tissue wobble. Set at build time;
## exposed for direct override.
@export var damping: float = 0.0

# Cached skeleton refs populated by Marionette.build_ragdoll so
# `_integrate_forces` doesn't string-resolve every physics tick. Both must
# be valid before custom_integrator gets switched on.
var _skel: Skeleton3D = null
var _host_skel_idx: int = -1
var _rest_local: Transform3D = Transform3D.IDENTITY
var _skel_global_inverse_cached: bool = false
# Mar-I5 — snapshot once per physics frame, read inside _integrate_forces.
# The skeleton's bone poses are written by PhysicalBoneSimulator3D in the
# same physics tick; reading them live from inside the integrator races
# with Jolt's parallel _integrate_forces dispatch. CLAUDE.md "Never" /
# PR #9 §4.5 snapshot-discipline rule. Audit: 05-14-02 SHARP Mar-I5.
var _cached_host_global: Transform3D = Transform3D.IDENTITY
var _cached_skel_world: Transform3D = Transform3D.IDENTITY
# Tracks whether _integrate_forces should attempt the spring path. Stays
# false in @tool (editor) so the spawned body is fully passive in the
# inspector — physics-only behavior runs in-game / in the play preview.
var _spring_enabled: bool = false


## Caches the skeleton refs that `_integrate_forces` reads each tick and
## arms the spring path. Called by Marionette.build_ragdoll once the
## bone is parented under the simulator.
func configure_spring(skel: Skeleton3D, host_skel_idx: int, rest_local: Transform3D) -> void:
	_skel = skel
	_host_skel_idx = host_skel_idx
	_rest_local = rest_local
	_spring_enabled = true
	# Prime the per-frame snapshot cache so the first _integrate_forces tick
	# after build_ragdoll already has valid targets — without this the cached
	# Transform3D.IDENTITY defaults would produce a one-tick spring kick
	# pulling the jiggle body toward world origin. configure_spring is the
	# natural seam (called once per build) so the extra get_bone_global_pose
	# call is build-time cost, not per-tick.
	#
	# Guard on is_inside_tree(): Node3D.get_global_transform push_errors
	# pre-ENTER_TREE. build_ragdoll runs against a tree-attached skeleton at
	# runtime so this guard is normally a no-op; it silences the harness
	# case where configure_spring may be called against a synthetic skel
	# before the SceneTree has wired it up. _physics_process will populate
	# the cache on the first tick regardless.
	if _skel.is_inside_tree():
		_cached_host_global = _skel.get_bone_global_pose(_host_skel_idx)
		_cached_skel_world = _skel.global_transform


# Translation-only SPD: spring-and-damp the body back toward its skin-driven
# rest position (host pose × rest local). Rotation is locked at the joint
# (all 3 angular limits = 0), so we only need apply_central_force.
#
# Force law (mass-cancelling form already applied via configure_spring's
# stiffness/damping derivation):
#   target_world = skel_global × host_global × rest_local
#   error = target_origin - state_origin
#   F = stiffness · error − damping · linear_velocity
func _physics_process(_delta: float) -> void:
	# Snapshot host bone pose + skeleton world transform once per frame for
	# _integrate_forces. Same guard predicate as the integrator's early-return
	# so the two stay in sync; in @tool / inspector mode _spring_enabled is
	# false and we don't read anything.
	if not _spring_enabled or _skel == null or _host_skel_idx < 0:
		return
	_cached_host_global = _skel.get_bone_global_pose(_host_skel_idx)
	_cached_skel_world = _skel.global_transform


# Pure helper extracted so the snapshot vs live behavior is unit-testable
# without constructing a PhysicsDirectBodyState3D. Returns the world-space
# target origin the spring should pull toward.
static func _compute_target_world(host_global: Transform3D, skel_world: Transform3D, rest_local: Transform3D) -> Vector3:
	var target_local_to_skel: Transform3D = host_global * rest_local
	return (skel_world * target_local_to_skel).origin


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if not _spring_enabled or _skel == null or _host_skel_idx < 0:
		return
	# Mar-I5 — read from snapshots populated in _physics_process. Live
	# _skel.get_bone_global_pose / _skel.global_transform reads here race
	# with PhysicalBoneSimulator3D mid-write under Jolt parallel dispatch.
	var target_world: Vector3 = _compute_target_world(_cached_host_global, _cached_skel_world, _rest_local)
	var error: Vector3 = target_world - state.transform.origin
	var force: Vector3 = stiffness * error - damping * state.linear_velocity
	state.apply_central_force(force)
