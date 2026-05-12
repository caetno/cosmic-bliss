@tool
class_name TentacleSurfaceTag
extends Node

## Tag node that advertises a `TentacleCollisionMaterial` for the parent
## `CollisionObject3D`. The tentacle's environment-probe pass walks
## `body.find_children("*", "TentacleSurfaceTag", true, false)` on each
## hit body and reads the tag's `material` to compose friction per contact
## slot (slice 4S.3, 2026-05-11).
##
## Constraints:
##
## - **One tag per body for 4S.3.** Multi-region positional tagging
##   (different materials on different shapes of the same body) is out of
##   scope. The probe pass emits `WARN_PRINT` when `find_children`
##   returns >1 match and takes the first.
## - **No invalidation logic.** The probe-side cache is per outer tick;
##   runtime swaps of `material` or tag teardown are picked up on the
##   following tick automatically. `PhysicsMaterial` was considered as the
##   carrier and rejected — no `friction_combine` enum, conflates static
##   and dynamic friction.
## - Place the tag as a direct child of a `CollisionObject3D`
##   (`StaticBody3D`, `RigidBody3D`, `AnimatableBody3D`, `PhysicalBone3D`).
##   `find_children` recursion handles deeper placements but flat
##   placement is the recommended convention.

## The friction material advertised to TentacleTech. `null` is treated
## as "no tag present" by the probe (silent fallback to tentacle-implicit
## friction); explicitly assigning a default `TentacleCollisionMaterial`
## is the way to opt into the composition path.
@export var material: TentacleCollisionMaterial
