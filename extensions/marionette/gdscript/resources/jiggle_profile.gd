@tool
class_name JiggleProfile
extends Resource

# Per-character soft-tissue tuning. Marionette consumes this when spawning
# JiggleBones — each JiggleBone's spring stiffness / damping are derived
# from a per-bone JiggleEntry, falling back to the profile-level defaults,
# and finally to hardcoded constants if no profile is assigned at all.
#
# Companion to BoneCollisionProfile.non_cascade_bones: the collision
# profile decides WHICH bones spawn as soft regions; this profile decides
# HOW they feel. The two are kept separate so a hero can swap feel
# (gentle vs aggressive jiggle) without re-baking hulls.
#
# Region grouping is a UI concern — entries here are flat per-bone, and
# the Tune & Test widget (slice 7) groups them by name pattern for
# display.

# Per-bone tuning. Keyed by skeleton bone name (post-retarget). Bones
# present in BoneCollisionProfile.non_cascade_bones but absent here fall
# through to the profile defaults below.
@export var entries: Dictionary[StringName, JiggleEntry] = {}

# Profile-wide defaults applied when a bone has no explicit entry.
@export_range(0.05, 2.0, 0.01) var default_reach_seconds: float = 0.3
@export_range(0.0, 2.0, 0.01) var default_damping_ratio: float = 0.7


# Returns (reach_seconds, damping_ratio) for `bone_name`. Looks up an
# explicit entry first; falls back to the profile defaults. Marionette
# layers a hardcoded code default on top of this for the null-profile
# case.
func params_for(bone_name: StringName) -> Vector2:
	if entries.has(bone_name) and entries[bone_name] != null:
		var entry: JiggleEntry = entries[bone_name]
		return Vector2(entry.reach_seconds, entry.damping_ratio)
	return Vector2(default_reach_seconds, default_damping_ratio)
