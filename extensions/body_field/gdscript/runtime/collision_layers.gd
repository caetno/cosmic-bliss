class_name BodyFieldLayers

## Project-wide collision-layer assignments owned by body_field.
##
## Per `docs/Cosmic_Bliss_Update_2026-05-14_body_field_optionality_and_dispatch.md`
## §3.1, TentacleTech particles probe against
##   `LAYER_BODY_PROXY | LAYER_BODY_CAPSULES_DETAIL | LAYER_BODY_CAPSULES_FULL | LAYER_WORLD`
## unconditionally. body_field's tet body, when present, occupies `_PROXY`.
## `BoneCollisionProfile` capsules populate `_DETAIL` (hands/feet only) when
## body_field is present, or `_FULL` (full skeleton) when body_field is absent.
##
## Layer-bit choice (B3): bits 5, 6, 7 (one-indexed) → 1<<4, 1<<5, 1<<6.
## Verified clean at B3 land: `game/project.godot` declares no
## `physics_layer_N/name` entries and no extension code writes
## `collision_layer = <small literal>` against layers 5/6/7. Marionette's
## `ragdoll_tuner.gd:213` writes `collision_layer = 1` (layer 1, unrelated).
## TentacleTech `Tentacle::environment_collision_layer_mask` defaults to
## `0xFFFFFFFF` — all layers including ours; will be narrowed at B5.

const LAYER_BODY_PROXY           = 1 << 4   # tet proxy body (body_field-present hero)
const LAYER_BODY_CAPSULES_DETAIL = 1 << 5   # BoneCollisionProfile, hands/feet only
const LAYER_BODY_CAPSULES_FULL   = 1 << 6   # BoneCollisionProfile, full skeleton (no body_field)
