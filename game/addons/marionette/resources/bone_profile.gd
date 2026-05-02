@tool
class_name BoneProfile
extends Resource

# Per-character static data: anatomical basis permutations, archetypes, ROM,
# SPD params, mass fractions. Companion to a specific SkeletonProfile, populated
# at authoring time by "Generate from Skeleton" (P2.10).

@export var skeleton_profile: SkeletonProfile

# Keys: bone names from skeleton_profile. Values: per-bone authoring data.
# Total ragdoll mass lives on the consuming Marionette node (Marionette.
# total_mass) — per-bone mass = Marionette.total_mass * BoneEntry.mass_fraction.
# A profile is per-rig; total mass is per-character; one profile can drive
# many characters of different total mass.
@export var bones: Dictionary[StringName, BoneEntry] = {}


func get_entry(bone_name: StringName) -> BoneEntry:
	return bones.get(bone_name)


func has_entry(bone_name: StringName) -> bool:
	return bones.has(bone_name)


# Sums mass_fraction across every entry. Used by validation: should be ~1.0
# once the profile is fully authored.
func mass_fraction_total() -> float:
	var s: float = 0.0
	for entry: BoneEntry in bones.values():
		s += entry.mass_fraction
	return s
