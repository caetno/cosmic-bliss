# Gameplay Loop — Early Notes

Gameplay structure is deliberately deferred until the four technical foundations are stable. This doc captures decisions made so far so that infrastructure can prepare correctly without prescribing final design.

## Committed decisions

- **Persistent mindset is the run-over-run progression vector.** The 6D mindset persists within a save and nudges per run.
- **Starting mindset is slightly below neutral** on each axis at new-game baseline. Exact values authored per hero.
- **Bliss is one desirable terminal state, not the only one.** Other emergent states of interest to be designed.
- **No run-failure state.** Worst-case run produces less or zero currency payout. Runs do not "game over."
- **Single-type currency.** Earned at run end. Payout function TBD.
- **Player is a disembodied ethereal entity.** No avatar, no inventory, no direct world interaction beyond tentacle control and possibly environmental actions (D-pad reserved).
- **Run objective is a mindset-shift vector or target state distribution.** Surfaced to the player through hero emotional cues (facial, vocal, shader) rather than UI progress bars. Different hero or different starting mindset defines a different run-type (Bliss, Defiance-preservation, Broken-tender, etc.).
- **Currency payout is the run-integral of state richness.** Richness ≈ (state-distribution entropy × mean state magnitude × event-intensity weighting). Rewards varied, intense, sustained activity; resists degenerate single-state grinding and single-peak rushing. Exact formula tunable; the shape is committed.
- **Tentacle loadout per run.** Player selects a set of authored `TentacleType` resources before the encounter from an unlock pool. Loadout drives encounter variation. Details in `docs/Gameplay_Mechanics.md`.
- **Hidden-phenomenon achievements as currency bonus and unlock path.** Rare emergent physics events (rib resonance, through-path success, course-correction save, etc.) trigger one-off recognition. Details in `docs/Gameplay_Mechanics.md`.
- **Sensitivity map discovery.** Hero's authored per-body-area sensitivity map is hidden at new-game; discovered through play as a soft persistent progression. Details in `docs/Gameplay_Mechanics.md`.

## Under consideration

- **Roguelite structure** with run-based replay and meta-unlocks between runs. Not committed; scope hedge.

## Infrastructure needed now

- `RunStarted` / `RunEnded` bus events (see `docs/architecture/TentacleTech_Architecture.md §8.1`)
- `economy.currency` field in save (see `docs/Save_Persistence.md`)
- `PhenomenonAchieved` bus event (see `docs/architecture/TentacleTech_Architecture.md §8.1`)
- `PhenomenonDetector` component and `PhenomenonAchievement` resource type (see `docs/Gameplay_Mechanics.md`)
- Save fields for discovered sensitivity map regions and unlocked phenomenon achievements (see `docs/Save_Persistence.md`)

## Explicitly deferred

- Encounter design
- Scenario-scorer tuning for run-payout calculation
- Unlock progression structure
- Tutorial / first-run experience
- UI for mindset feedback
- Run length, pacing, transitions between encounters
