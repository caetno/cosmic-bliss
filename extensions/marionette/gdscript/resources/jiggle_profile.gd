@tool
class_name JiggleProfile
extends Resource

## Per-character soft-tissue tuning. Marionette consumes this when
## spawning JiggleBones — each spring's stiffness / damping is derived
## from a per-bone JiggleEntry, falling back to profile defaults, and
## finally to hardcoded constants if no profile is assigned.
##
## Companion to BoneCollisionProfile.non_cascade_bones: the collision
## profile decides WHICH bones spawn as soft regions; this one decides
## HOW they feel. Separated so a hero can swap feel (gentle vs aggressive)
## without re-baking hulls.

## Per-bone tuning, keyed by skeleton bone name (post-retarget). Bones
## listed in BoneCollisionProfile.non_cascade_bones but missing here
## fall through to the defaults below.
@export var entries: Dictionary[StringName, JiggleEntry] = {}

## Profile-wide reach time (seconds) applied to bones with no entry.
@export_range(0.05, 2.0, 0.01) var default_reach_seconds: float = 0.3

## Profile-wide damping ratio applied to bones with no entry.
@export_range(0.0, 2.0, 0.01) var default_damping_ratio: float = 0.7


## Returns (reach_seconds, damping_ratio) for `bone_name`. Looks up the
## explicit entry first, falls back to the profile defaults. Marionette
## layers a hardcoded code default on top for the null-profile case.
func params_for(bone_name: StringName) -> Vector2:
	if entries.has(bone_name) and entries[bone_name] != null:
		var entry: JiggleEntry = entries[bone_name]
		return Vector2(entry.reach_seconds, entry.damping_ratio)
	return Vector2(default_reach_seconds, default_damping_ratio)
