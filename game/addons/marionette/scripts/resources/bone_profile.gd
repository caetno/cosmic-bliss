@tool
class_name BoneProfile
extends Resource

## Per-character static authoring data: anatomical basis permutations,
## archetypes, ROM, joint spring params, mass fractions. Companion to
## a specific SkeletonProfile, populated at authoring time by Marionette's
## "Calibrate Profile from Skeleton" tool button.

## SkeletonProfile this BoneProfile is keyed against. Bones in the
## profile are assumed to use these names.
@export var skeleton_profile: SkeletonProfile

## Per-bone authoring data, keyed by SkeletonProfile bone name. Total
## ragdoll mass lives on the consuming Marionette node — per-bone mass
## is Marionette.total_mass × BoneEntry.mass_fraction. A BoneProfile is
## per-rig; one profile can drive many characters of different total mass.
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
