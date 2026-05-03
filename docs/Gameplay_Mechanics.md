# Gameplay Mechanics — Skill Surface, Achievements, Discovery

Companion to `docs/Gameplay_Loop.md`. That doc defines the core loop (objective + payout + persistence). This doc defines what the player *does* moment-to-moment, what they get good at, and what keeps runs from feeling identical.

Scope: game-layer systems that sit on top of the four extensions. No new extension is introduced; everything here consumes existing TentacleTech, Reverie, Tenticles, and Marionette interfaces.

Numeric values are starting points, tunable with playtest.

---

## 1. Skill mechanics

Physics already produces these moments. Making them legible and aimable turns emergence into something the player can get good at.

### 1.1 Grip-break timing

Scenarios 2 and 4 produce snap release from accumulated static friction at the orifice ring. Cue the player on grip engagement state via:
- Hero vocal timbre shift (Reverie vocal output tagged `grip_holding`).
- Ring-shader parameter (subtle color / sheen pulse at high `grip_engagement`).

Reward well-timed withdrawals (axial velocity peak aligned with peak grip): larger `Ecstatic` spike, distinct Reverie vocal line (`snap_release_vocal`), minor mindset drift toward `Blissful + Yielding`.

Mistimed (withdraw at low grip, or withdraw sluggishly through peak grip): dull release, minor mindset drag toward `Dulled`.

No UI meter. Player reads the hero's body.

### 1.2 Rib-resonance tuning

Scenario 8 exists physically. A ribbed tentacle pumping near the orifice ring's natural frequency produces resonance and amplified reaction.

Cues the player can read:
- Visible rim pulsing (PBD rim particle loop driven by §6.3 constraints + per-loop target-area modulation per §6.4).
- Hero vocal rhythm entrainment (Reverie vocal output rhythm tied to ring oscillation phase).

Reward sustained resonance (e.g., ring amplitude > threshold for 2+ seconds): `PhenomenonAchieved(RibResonance, magnitude)` event, currency bonus, `Ecstatic` spike, optional vocal unlock for this tentacle type.

### 1.3 Angle / wedge reading

Scenario 3 already punishes oblique approaches with wedge lock and permanent angular damage.

No UI angle indicator. Feedback comes from:
- Physical stuck behavior.
- Asymmetric pressure on rim particles (visible skin deformation).
- Reverie reaction (mildly painful, not pleasurable).

A skilled player learns to read approach geometry and clears harder orifices faster. No dedicated mechanic — this is raw physics reading.

### 1.4 Overwhelm management

Reverie's `Overwhelmed` state gains with sustained multi-tentacle pressure. Too many active tentacles = fast Overwhelmed accumulation = vocalization and facial collapse to dissociated, mindset drift toward `Dulled`/`Lost` at high rates.

Player skill: balance parallel stimulus (enough for Aroused / Ecstatic to climb) against Overwhelmed saturation.

Release valve: player action `calm_nearest_uncontrolled_tentacle` — the nearest non-controlled tentacle's AI is biased toward Prowl or Recovery preset for 3 seconds. Cooldown 5 seconds. Bound to D-pad (reserved per `docs/Camera_Input.md`).

Does not remove the tentacle; just calms it. Physical contact continues at reduced intensity.

### 1.5 Pain-pleasure threshold

Reverie's `special_conversions` convert some pain events to `Ecstatic` at high `Blissful + Yielding` mindset (see `docs/architecture/Reverie_Planning.md §2.3`).

In a narrow mindset band, the player can intentionally use higher-intensity actions (Forced Stretch preset, larger-girth tentacles, faster thrust) that would normally be net-negative. Crossing into `In-pain` / `Overwhelmed` drops the bonus and nets a loss.

No UI. Reverie vocalization and facial state are the indicator. Skill: stay near the conversion edge without crossing.

---

## 2. Hidden phenomenon achievements

Rare emergent physical events get tagged as one-off recognitions.

### 2.1 `PhenomenonAchievement` resource

```gdscript
class_name PhenomenonAchievement extends Resource

@export var id: StringName              # stable identifier
@export var display_name: String
@export var description: String
@export var currency_bonus: int
@export var unlock_on_first: Array      # array of unlock ids (presets, voice lines, shader variants)
@export var repeatable: bool = false    # if true, bonus on every hit; otherwise first-time only
```

### 2.2 `PhenomenonDetector` component

GDScript node attached to the hero or encounter scene. Subscribes to the StimulusBus and inspects state each tick. When detection logic matches, emits `PhenomenonAchieved` with the matching achievement id.

Each achievement has a detection function (GDScript, per-achievement). Examples below.

### 2.3 Starter achievement set

| id | Detection | First-time unlocks |
|---|---|---|
| `RibResonance` | Ring amplitude (any direction) exceeds 2× baseline for ≥ 2s while tentacle in Pumping preset | Ribbed-tentacle shader variant |
| `ThroughPath` | `EntryInteraction` forms a downstream link (§6.7), tentacle tip exits via the downstream orifice | Through-path vocal set |
| `CourseCorrection` | Scenario-10 sequence: target orifice T, actual engaged N, scorer updates target within 2s, penetration in N persists ≥ 5s | "Adaptive" AI preset variant |
| `BulbRetentionSnap` | `GripBroke` event with ring radial velocity > threshold while tentacle is bulbed | Bulb-tentacle shader glow variant |
| `TripleOccupancy` | Three active `EntryInteraction`s on one orifice for ≥ 1s | "Crowded" reaction profile |
| `CleanDeposit` | `PayloadDeposited` on first tip-past-threshold without Scenario-1 slip | Ovipositor calibration variant |
| `CleanExpulsion` | `PayloadExpelled` with `peak_ring_stretch` < `damage_threshold × 0.8` | Smooth-birthing vocal set |
| `PainToEcstatic` | `special_conversion` fires in Reverie with net `Ecstatic` gain > threshold | Transcendence shader mode |
| `ResonanceCascade` | Two simultaneous `PhenomenonAchieved` events within 1s window | High-bonus currency, no further unlock |

Achievements unlocked persist in save (see `docs/Save_Persistence.md`).

Designers add achievements as `.tres` resources. Zero code to add new ones; only existing achievements whose detection needs new logic require code.

### 2.4 Feedback

On detection: non-diegetic sound cue (light, not celebratory), subtle bloom on the screen edge, entry in a run-summary panel at run end. No mid-run popup.

---

## 3. Sensitivity map discovery

Each hero has an authored `per-body-area sensitivity` map (`OrificeProfile.linked_body_areas` + `body_area_sensitivity[area_id]`, TentacleTech §8.3–8.4). At new-game, the map is hidden from the player.

### 3.1 Discovery mechanic

A body area is *discovered* when it accumulates enough stimulus over the save's lifetime: threshold = `discovery_stim_threshold` (scalar), per-area, measured as integrated `body_area_friction + body_area_pressure × press_to_stim_ratio`. When threshold is crossed, the area is marked discovered in save state.

Once discovered:
- The area shows subtly in an optional "anatomy view" debug overlay (if the player turns it on in settings).
- Reverie's reaction intensity at that area is slightly boosted (narrative: "she remembers you found this spot") via a `discovery_familiarity_mult` fed back into `body_area_sensitivity`. Small multiplier (1.1–1.2), capped; not game-breaking.

Not discovered: map entry not revealed; physics still reads the authored sensitivity (sensitivity isn't zero until discovered — it's just that the player doesn't *know*).

### 3.2 Save integration

Save schema gains (see `docs/Save_Persistence.md`):

```
sensitivity_discovery: {
    <hero_id>: {
        discovered_areas: [area_id, ...]
        stim_accumulator: {area_id -> float}
    }
}
```

### 3.3 Presentation

No inventory, no unlock screen. Discovery surfaces only through vocal/facial response getting subtly richer over time at discovered areas. Player who never opens the debug overlay still benefits; the overlay is a consolation for players who want legibility.

---

## 4. Tentacle loadout

### 4.1 Unlock pool

At new-game, the player has access to a small pool of `TentacleType` resources (authored; typically 3–5). Additional types unlock via:
- Phenomenon achievements (§2.3 `unlock_on_first` list).
- Mindset milestones (e.g., `Blissful` > +0.5 → unlock `TentacleType_Tender`).
- Currency purchase (a small portion of currency sink at run end; exact cost TBD).

Unlocks persist in save.

### 4.2 Pre-run selection

Before each run, the player picks a loadout of `N` tentacle types (N = 3–6, tunable; may scale with run structure once encounter design lands).

Selection UI: simple grid of unlocked types, drag-and-drop into N slots. Defer detailed UI until encounter design. Minimum viable: a debug menu.

### 4.3 Encounter spawn

TentacleTech spawns the loadout as the active tentacle set for the encounter. Spawn positions, anchor geometry, and AI scenarios are encounter-driven (deferred with encounter design).

### 4.4 Save integration

Save schema gains (see `docs/Save_Persistence.md`):

```
loadout: {
    unlocked_tentacle_types: [type_id, ...]
    current_loadout: [type_id, ...]
}
```

---

## 5. Integration points

| Mechanic | Reads from | Writes to |
|---|---|---|
| Grip-break timing | Reverie vocal tag, ring shader param | Player feedback only |
| Rib resonance | Ring amplitude, preset id | `PhenomenonAchieved` event |
| Angle/wedge | Physics feedback (pressure, stuck state) | — |
| Overwhelm management | Reverie `Overwhelmed` state | Tentacle scorer bias (temporary) |
| Pain-pleasure threshold | Reverie `special_conversions` | — |
| Achievements | Bus events, continuous channels, scorer output | `PhenomenonAchieved`, save |
| Sensitivity discovery | Continuous body-area channels | Save, `body_area_sensitivity` mult |
| Loadout | Save | TentacleTech encounter spawn |

Nothing here touches physics code. All detection, aggregation, and feedback runs in GDScript on top of the bus.

---

## 6. Phase placement

- **Bus-consumer infrastructure** (PhenomenonDetector skeleton, achievement resource type) lands whenever encounter design starts to materialize — not before.
- **Skill mechanics** rely only on cues already specced for Reverie output. Ship them as Reverie reaction profiles mature (Phase R3 onward).
- **Sensitivity discovery** piggybacks on body-area stim accumulation already in TentacleTech §8.4.
- **Loadout** needs only a debug menu until encounter design demands real UI.

The whole doc is build-once-thin, fill-in-as-systems-come-online. No phase of its own.

---

## 7. Explicitly deferred

- Encounter design (when tentacles spawn, where, in what environments).
- Exact run-pacing and length.
- Detailed UI for loadout, achievements, mindset feedback.
- Tutorial / first-run experience.
- Multiplayer / observer-mode framing.
- Non-hero-character customization (single hero per `docs/Appearance.md`).

Covered by `docs/Gameplay_Loop.md`'s own deferred list; repeated here for local reference.
