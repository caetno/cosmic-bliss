# Gameplay Mechanics

## Design philosophy

**Soft physics over scripted levers.** If a behaviour can't be expressed via stiffness, friction, grip, damage thresholds, or modulation channels, the fix is the physics, not a hard reject. Boolean rejects in particular get used everywhere a designer doesn't want to tune the physics — don't introduce them.

This applies cross-cutting: TentacleTech's contact handling, Reverie's reaction profiles, Marionette's overlay logic, and gameplay design itself. The game is what the physics does; the game is not a layer of guards on top of the physics.

## Skill surface

The player's skill expresses through reading and timing physics:

- **Grip-break timing.** EntryInteractions ramp `grip_engagement` under stationarity. The player induces motion to break grip — but mistime and the tentacle's hold reinforces. Read the ramp; time the pull.
- **Rib resonance.** Ribbed tentacle features have axial periodicity. Pulling at the right phase against a rim particle catches the rib's outward bump; pulling out of phase slides past. Subtle audio + haptic cues hint.
- **Wedge reading.** Where the tentacle is pinned between two surfaces (between thighs, between rim and canal wall) it can be loaded against one surface to release the other. Reading the wedge geometry is a learned skill.
- **Overwhelm management.** Multiple simultaneous EntryInteractions / contraction pulses cap at 3 tentacles per orifice (§6.5). Keeping count + managing what's active is part of the loop.
- **Pain–pleasure edge.** `damage_accumulated_per_loop_k` ramps under sustained pressure. Stop short of failure thresholds; hold the edge.

Other skill threads (developing): syncing tentacle rhythm to `body_rhythm_phase` for resonant thrust; loadout selection against active mindset.

## Persistence and progression

- **Mindset persists across runs.** Sensitivity-map state, learned reactions, body-area thresholds — these accumulate. There's no "new game"; the same Kasumi, more discovered.
- **No fail state.** The game does not end. Sessions are pause/resume.
- **Single-type currency.** No skill trees, no branching upgrades. One pool, used for clear unlocks.
- **Roguelite under consideration.** Run-based modulation of which mindset state is active, with the persistent layer underneath. Not committed.

## Hidden phenomenon achievements

Rare physics events — knot engulfs, double-tentacle helical wrap, contraction pulse synchronizing with tentacle thrust at the body-rhythm phase — are achievement triggers. The achievement reveals what just happened, naming a phenomenon the player didn't know was a thing. Discovery loop: notice → name → hunt for again.

This depends on the underlying physics being expressive enough that rare emergent events actually exist. The simulation has to surprise.

## Sensitivity map discovery

Kasumi's body has 20–30 named regions (not per-bone — semantic regions like "left inner thigh", "lower belly", "throat"). Each has a per-region sensitivity to pressure / friction / temperature / pulse rhythm. The map starts hidden; the player learns it through Reverie's emitted cues and the persistent mindset state.

This is Reverie's primary readout surface.

## Tentacle loadout

Player chooses a small set of tentacles to be present in a session. Tentacles vary by:
- Mesh feature mix (knots, ribs, suckers, spines, ribbons, fins)
- Mood preset (lubricity, friction, base stiffness, pose softness, substep count, plastic memory bias)
- Behaviour driver (idle / caress / probe / thrust / bind)
- Modulation channel response (how it picks up Reverie's pulse, body rhythm, etc.)

Loadout is a strategic choice that interacts with which mindset is active.

## Player input

- **Controller-first.** Keyboard/mouse supported but secondary.
- **Third-person orbit camera.** The player is positioned outside the body, observing.
- **Player as disembodied observer**, not embodied avatar. The player commands tentacles + camera; Kasumi reacts via Reverie + Marionette. There is no first-person possession of Kasumi.

See `docs/Camera_Input.md` for camera detail.

## What we deliberately don't do

- No scripted scenes. No predetermined outcomes. No quick-time events.
- No fail state. No game over.
- No traditional skill tree.
- No predetermined narrative beats. Mindset state is a soft narrative, not a plot.
- No combat/damage as a player goal. Damage is a physics consequence the player navigates around (or toward, as a skill expression), not an objective.
