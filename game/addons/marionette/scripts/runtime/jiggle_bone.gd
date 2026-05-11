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


# Translation-only SPD: spring-and-damp the body back toward its skin-driven
# rest position (host pose × rest local). Rotation is locked at the joint
# (all 3 angular limits = 0), so we only need apply_central_force.
#
# Force law (mass-cancelling form already applied via configure_spring's
# stiffness/damping derivation):
#   target_world = skel_global × host_global × rest_local
#   error = target_origin - state_origin
#   F = stiffness · error − damping · linear_velocity
func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if not _spring_enabled or _skel == null or _host_skel_idx < 0:
		return
	var host_global: Transform3D = _skel.get_bone_global_pose(_host_skel_idx)
	var target_local_to_skel: Transform3D = host_global * _rest_local
	# Skeleton3D global → world transform varies with the rig's parent. We
	# read it via the cached skel ref every tick; cheap (single property
	# access) and avoids stale state if the rig is teleported.
	var target_world: Vector3 = (_skel.global_transform * target_local_to_skel).origin
	var error: Vector3 = target_world - state.transform.origin
	var force: Vector3 = stiffness * error - damping * state.linear_velocity
	state.apply_central_force(force)
