@tool
class_name MarionetteBone
extends PhysicalBone3D

# P3.2 — per-bone physical body. Marker class for now: extends PhysicalBone3D
# so PhysicalBoneSimulator3D auto-attaches it to the named skeleton bone, and
# carries the BoneEntry forward so JointLimitGizmo and (later) the SPD path
# can look up anatomical metadata without re-reading the BoneProfile.
#
# SPD (Phase 5) lives in `_integrate_forces(state)` — added then; until then
# Powered bones are dynamic but have no muscle torque, so they fall limp.

@export var bone_entry: BoneEntry
