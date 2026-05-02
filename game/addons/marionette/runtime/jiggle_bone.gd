@tool
class_name JiggleBone
extends PhysicalBone3D

# Translation-driven soft-tissue body — breast, glute, belly, etc. — spawned
# alongside the regular MarionetteBones at ragdoll build time. CLAUDE.md §15.
#
# Lives in the same simulator as the rest of the ragdoll so its collisions
# share the world space. Joint setup locks all three angular axes (no
# rotation relative to the host) and exposes a small linear excursion
# budget on each axis — physics offsets the body's position from its
# skin-driven rest, with translation-only SPD spring-damping it back.
#
# Sibling class to MarionetteBone (both extend PhysicalBone3D directly).
# JiggleBones don't carry a BoneEntry — their physics is purely a
# translation spring, no anatomical-frame metadata is needed. Code that
# iterates the simulator's bones must accept either subclass; helpers
# parameterized as PhysicalBone3D handle both.

# Skeleton bone whose pose drives this jiggle body's rest position. For ARP
# breast bones, this is the bone's actual skeleton parent (UpperChest); for
# custom rigs the host can be different.
@export var host_bone_name: StringName = &""

# Spring stiffness in N/m. Marionette.build_ragdoll initializes this from
# the desired reach time and the bone's mass; raw kp is exposed because
# downstream tuning typically wants to nudge stiffness directly when a
# specific region looks too floppy or too stiff.
@export var stiffness: float = 0.0

# Damping in N·s/m. Critical damping for a given stiffness/mass is
# 2·sqrt(k·m); slightly underdamped (~0.7×critical) gives a natural
# breast/butt wobble. Build-time defaulting handles this; the field is
# exposed for inspector tuning.
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


# Caches the data `_integrate_forces` needs and arms the spring path. Called
# from Marionette.build_ragdoll once the bone is in the scene tree.
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
