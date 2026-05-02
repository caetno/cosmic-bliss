@tool
class_name MarionetteBone
extends PhysicalBone3D

## Per-bone physical body. Extends PhysicalBone3D so
## PhysicalBoneSimulator3D auto-attaches it to the named skeleton bone,
## and carries the BoneEntry forward so JointLimitGizmo and (later) the
## SPD path can look up anatomical metadata without re-reading the
## BoneProfile.
##
## SPD (Phase 5) will live in _integrate_forces(state). Until then,
## Powered bones are dynamic but have no muscle torque — Jolt's joint
## angular springs (slice 3) keep them from going fully limp.

## The BoneProfile entry this bone was built from. Used by gizmos and
## the SPD path to look up archetype, ROM, anatomical basis, etc.
@export var bone_entry: BoneEntry
