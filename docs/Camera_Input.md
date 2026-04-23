# Camera and Input

Game-layer scope. Neither TentacleTech, Tenticles, Marionette, nor Reverie owns the camera or input scheme. This doc specifies both.

## Camera

Third-person free orbit. Spring-arm boom with player-controlled yaw/pitch. Focus on hero pelvis by default.

**Auto-frame on player control.** When the player takes control of a tentacle, the camera's focus point blends from hero pelvis toward the midpoint of `(hero_pelvis, controlled_tentacle_tip)` over ~0.5s. Boom length adjusts so both points fit the frame. Release of control blends focus back to pelvis over ~0.5s. A player toggle disables auto-frame if the player wants to compose shots manually.

**No first-person camera.** Hiding the hero's face and body defeats the purpose of procedural reaction systems.

**No cinematic/director cameras.** Pre-authored angles conflict with the emergent-physics identity.

**Camera collision.** Standard spring-arm pull-in on environment contact. The hero ragdoll and active tentacles do not push the camera (camera collision layer excludes them).

## Input — controller (primary)

| Input | Function |
|---|---|
| Left stick | Camera orbit drift |
| Right stick | Controlled tentacle `target_direction` |
| RT | `engagement_depth` (analog, -1 to +1) |
| LT | `target_weight` (analog; feather = nudge, pull = commit) |
| A / X | Cycle which tentacle is controlled (nearest-to-camera-center on press) |
| B / Circle | Release control |
| LB | Toggle `girth_modulation` |
| RB | Toggle `stiffness` |
| Left stick click | Toggle camera auto-frame |
| D-pad | Reserved (environmental actions, scenario prompts) |

## Input — keyboard + mouse (parity)

| Input | Function |
|---|---|
| WASD | Camera orbit drift |
| Mouse | Controlled tentacle `target_direction` |
| RMB (hold) | `engagement_depth`; scroll adjusts magnitude |
| LMB | `target_weight` |
| Tab | Cycle tentacle |
| Space | Release control |
| Q | Toggle `girth_modulation` |
| E | Toggle `stiffness` |
| V | Toggle auto-frame |

## Player identity

The player is a disembodied ethereal entity with no in-world avatar. Input manipulates tentacles directly; the player has no inventory, no physical presence, no collision. The hero's attention can target the player's position (camera focus point) as `AttentionTarget.Observer` — this is the mechanism for "hero looks up at you."

## Status

This spec is a starting point. Revise once player takeover is actually playable. Controller is primary; keyboard parity exists but is not first-class.
