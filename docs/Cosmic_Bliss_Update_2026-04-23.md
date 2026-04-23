# Cosmic Bliss — Design Update (2026-04-23)

This document consolidates design decisions made during a design-review session on 2026-04-23. Apply these changes to the existing canonical design docs (`TentacleTech_Architecture.md`, `TentacleTech_Scenarios.md`, `Marionette_plan.md`, `Reverie_Planning.md`, `Tenticles_design.md`) and create the new docs listed at the end.

**These are design additions and clarifications, not a restructure.** The four-extension architecture (TentacleTech, Tenticles, Marionette, Reverie) is unchanged. Plugin-architecture refactor discussions (StimulusBus extraction, interface abstractions, narrative-event relocation) are explicitly deferred and must not be applied.

Numeric values (budget caps, timing constants) remain tunable; treat them as starting points.

---

## Summary of decisions

1. **Tentacle rendering boundary.** TentacleTech renders hero-coupled tentacles; Tenticles renders environmental/ambient tentacles. No handover. Environmental tentacles never contact the hero.
2. **Wall-prop no-clip.** Vertex-shader capsule-push only. No ragdoll, no Marionette instance, no physics. Reactive wall props are explicitly out of scope, including as stretch goal.
3. **Mindset persistence.** Save-scoped, resets on new-game. Starts slightly below neutral per axis (authored per hero). Bliss is one desirable terminal state but not the only one.
4. **Marionette is purely procedural.** No AnimationTree, no AnimationPlayer, no keyframe animation input.
5. **Player control is priority override** on a single tentacle at a time. Autonomy-to-control-to-autonomy is a fade, not a swap.
6. **Reverie treats player-controlled tentacle specially via attention.** Hero head and eyes track the controlled tentacle as primary salience target.
7. **Attention is a first-class Reverie concept.** Target types: `Tentacle`, `BodyArea`, `World`, `Observer`, `None`. Drives Marionette neck SPD and facial eye kinematics.
8. **Customization is in scope.** Initial direction: space theme with skintight clothing and dissolve shader effects. No cloth physics. Owned by a new `Appearance` system at the game layer.
9. **Single-type currency, no run-failure state.** Worst-case run produces less or zero currency. Runs do not "game over."
10. **Player is a disembodied ethereal entity.** Attention can target the observer (camera focus point) as a world-space salience point.
11. **All-the-way-through is a valid penetrator path.** Tunnels may chain across multiple orifices on the same hero.
12. **Camera and input are greenfield.** Third-person orbit, controller-first. Lives in a new top-level `Camera_Input.md`.
13. **Bulger budget raised.** Cap from 32 to 64. Add temporal fade-in/out on eviction. Normalize external-bulger radius by a reference force.

---

## Changes to existing files

### TentacleTech_Architecture.md

**§6 Orifice system — add new subsection §6.7 Through-path tunnels.**

Insert after §6.6 (Jaw special case), before §7:

> ### 6.7 Through-path tunnels
>
> A tentacle may traverse multiple orifices as a chained path ("all-the-way-through"). Each `EntryInteraction` may be linked head-to-tail with another `EntryInteraction` belonging to a different orifice on the same hero.
>
> - Each `EntryInteraction` gains optional `downstream_interaction` and `upstream_interaction` pointers.
> - Tunnel projection sums along the linked chain; the tentacle spline passes through all orifices' tunnel splines in sequence.
> - Capsule suppression (§10.5) unions the suppression lists of all chained orifices.
> - Bulger sampling (§7.2) covers the full chained interior — allocate 6 samples per orifice in the chain, not 6 samples per tentacle.
> - AI targeting uses the entry orifice only; the exit orifice is emergent from physics.
> - Chain linking is detected by proximity: when a penetrating tentacle's tip enters a second orifice's entry plane while still engaged upstream, a downstream `EntryInteraction` is created and linked.

**§7.1 Bulger uniform array — raise cap from 32 to 64.**

Change `uniform vec4 bulgers[32]` to `uniform vec4 bulgers[64]`. Change `uniform int bulger_count; // 0..32` to `uniform int bulger_count; // 0..64`. Update the shader loop accordingly.

Update §7.1 trailing cost note: "64 bulgers × 15k vertices = 960k distance ops per frame. Still trivial on any GPU from the last decade, including integrated."

**§7.2 Bulger sources — add external-force normalization and update the cap.**

At the end of §7.2, replace "Max 32 total; if over cap, keep highest-magnitude bulgers." with:

> External bulger radius is computed as `clamp(normal_force / reference_force, 0, max_external_radius) × external_bulge_factor`. `reference_force` is set to approximately 1/10 of hero body weight (tunable; empirical). This decouples the external bulge scale from absolute PBD force magnitudes, which drift during solver tuning.
>
> Maximum 64 total bulgers per hero. If aggregated candidates exceed 64, keep highest-magnitude; see §7.5 for eviction fade behavior.

**§7 — add new subsection §7.5 Bulger eviction and fade.**

Insert as a new subsection under §7:

> ### 7.5 Bulger eviction and fade
>
> When the active bulger set changes between frames (a new bulger enters, an existing one is culled), apply a temporal fade to avoid visible popping under saturation:
>
> - Each aggregated bulger carries an `active_since_time` timestamp.
> - On entry to the active set: `display_radius` ramps from 0 to `target_radius` over 2 frames (linear).
> - On eviction from the active set: `display_radius` ramps from current to 0 over 2 frames, then the slot is released.
> - Eviction-in-progress bulgers are retained in the uniform array; the active-set cap of 64 refers to fully-active slots.
>
> Implemented CPU-side in `SkinBulgeDriver` before uniform upload. Adds negligible aggregation cost.

**§8.1 Stimulus events — add run-lifecycle events.**

Add to the `StimulusEventType` enum list:

> - `RunStarted` — fired at encounter/run begin. Payload: starting mindset vector, hero id.
> - `RunEnded` — fired at encounter/run completion. Payload: `payout` (currency amount, single type), final mindset vector, duration seconds.

Add a note below the enum:

> `RunStarted` / `RunEnded` are infrastructure-only at present. No physics subsystem emits or consumes them. The game layer will fire and listen to these once run structure is designed; defining them now keeps the schema stable.

**§8.2 Modulation channels — add attention fields to `CharacterModulation`.**

Add to the `CharacterModulation` struct:

> ```cpp
> enum AttentionTargetType { AttentionNone, AttentionTentacle, AttentionBodyArea, AttentionWorld, AttentionObserver };
>
> AttentionTargetType attention_target_type   = AttentionNone;
> int                 attention_target_tentacle_id = -1;    // used when type = Tentacle
> int                 attention_target_body_area_id = -1;   // used when type = BodyArea
> Vector3             attention_target_world_position;      // used when type = World or Observer
> float               attention_intensity         = 0.0;    // 0..1
> ```

**§8.1 Continuous channels — add player-control channel.**

Add to the continuous channels list:

> - `tentacle_controlled_by[tentacle_id]` — enum `{ AI, Player }`. Updated each tick by the tentacle controller. Reverie reads for salience; otherwise informational.

**§12 Performance budget — update bulger shader row.**

Change the "Hero skin vertex shader" row from `15k × 32 bulgers` to `15k × 64 bulgers`. Expected cost still well under 1 ms on mid-range GPUs.

### Reverie_Planning.md

**§2 — add new subsection §2.6 Attention and gaze.**

Insert after §2.5 Implementation sketch, before §3:

> ## 2.6 Attention and gaze
>
> Reverie owns attention-target selection. Each Reverie tick (~20 Hz) it selects a single primary target from a salience computation and writes it to the `CharacterModulation` attention channel on the StimulusBus.
>
> **Salience inputs:**
>
> - `tentacle_controlled_by[i] == Player` — large constant bump for the controlled tentacle. Player-controlled tentacles almost always win salience.
> - Tentacles with recent high-magnitude `SkinPressure`, `PenetrationStart`, `BulbPop` events — salience weighted by event magnitude with ~1s exponential decay.
> - Body areas with rising arousal — moderate salience.
> - Observer (the disembodied player-entity) — valid target during specific state distributions (high `Curious`, high `Lost`, low `Hopeless`). This is the mechanism for the hero looking up at the player.
> - World points of interest — context-driven; low baseline salience unless explicitly authored.
>
> **Hysteresis:** minimum 0.4s dwell time before switching targets, unless a new target's salience exceeds the current target's by >2×. Prevents visual jitter from bus-noise.
>
> **On player release:** attention does not snap. Previous target's salience decays over ~1s; gaze drifts away naturally as other targets rise in relative score.
>
> **Consumers of the attention channel:**
>
> - Marionette cervical (neck) chain SPD — biases skull orientation toward the attention world-position. Body does not rotate; only neck. See `Marionette_plan.md` P8.X.
> - Facial system — drives eye aim kinematically toward the attention world-position. Eye bones are kinematic, not Marionette-driven.
>
> **Attention intensity** scales both effects. At `intensity = 0`, gaze is idle (breath-level drift). At `intensity = 1`, gaze is locked on. State distribution modulates intensity (e.g., high `Hopeless` caps intensity at 0.3 — the hero doesn't track anything strongly).

**§2.3 Mindset — add pruning TODO note.**

Append to §2.3 after the axis list:

> **Pruning review pending.** Six axes may be excessive. `Broken↔Blissful`, `Resistant↔Yielding`, `Self-aware↔Lost` are core to the vision and load-bearing for the intended emotional range. `Alert↔Dulled`, `Anxious↔Trusting`, `Tender↔Feral` are under review for merging, removal, or correlation-to-other-axes once first playtest data exists. Authored mindsets through implementation should favor the three core axes and use the others conservatively.

**§2 — add new subsection §2.7 Persistence.**

Insert after new §2.6:

> ## 2.7 Persistence
>
> Mindset is save-scoped. The full 6D vector persists across run boundaries within a save file. New-game resets to a baseline that is **slightly below neutral** per axis; exact values are authored per hero in the hero resource. Save schema details live in `Save_Persistence.md`; Reverie writes the `reverie.mindset` block at save time and reads it at load time.

**§5 Reaction profiles — add player-controlled branching note.**

Add as a new paragraph in §5 (or near the reaction profile structure):

> Reaction profiles may branch on `tentacle_controlled_by == Player`. Player-controlled tentacles produce stronger attention and more intimate facial responses at equal physical stimulus; AI tentacles are treated as less-personal contact. **Physics is unaffected by this branching** — modulation writes to orifice/body-area channels use the same values for AI and player tentacles. The difference is confined to attention, facial, and vocalization outputs.

**§9 Phase plan — add Phase R3.5.**

Insert between Phase R3 (Facial blendshape output) and Phase R4 (Shader parameters):

> 3.5. **Phase R3.5 — Attention and gaze.** Implement salience function, attention-target selection with hysteresis, modulation-channel write-out. Verify that Marionette's neck driver and the facial system's eye aim both respond correctly to the attention channel. Test player-control branching by toggling `tentacle_controlled_by` manually and confirming gaze tracks.

### Marionette_plan.md

**Core architectural commitments — add item 9.**

Append to the numbered commitments list at the top:

> 9. **Animation input is procedural only.** No `AnimationTree`, no `AnimationPlayer`, no keyframe animation input. The full animation vocabulary is: poses + cyclic animations + emotional body overlays + motion macros + Reverie-driven anatomical targets + attention-driven neck targets, all composed additively on SPD-driven bones. This makes authoring UI load-bearing; Phases 4, 6, 7, 8 are the animation pipeline.

**Phase 8 — add attention-driven neck sub-phase P8.X.**

Add at the end of Phase 8 (Emotional body states):

> - **P8.X — Attention-driven neck target.** New `NeckAttentionDriver` GDScript component, attached to the hero. Subscribes to `CharacterModulation.attention_*` channels on the StimulusBus. Each tick:
>   1. Reads current attention target world-position from the bus.
>   2. Computes desired skull forward vector (normalized direction from skull bone to target).
>   3. Distributes the resulting orientation delta across the cervical chain — lower cervicals receive smaller contribution, upper cervicals larger. Simple weighted split, no full IK.
>   4. Converts each cervical bone's contribution to anatomical target (flex/rot/abd triple).
>   5. Writes targets via `Marionette.set_bone_target()` and scales stiffness by `attention_intensity`.
>
>   Body does not rotate. Eye bones are not Marionette-driven; they remain kinematic under the facial system.
>
>   **Milestone:** with the bus manually set to `attention_target_type = World, attention_target_world_position = <moving test point>, attention_intensity = 1.0`, the hero's head smoothly tracks the point. At `intensity = 0`, head returns to rest pose. Video artifact: `docs/videos/phase_8x_attention.mp4`.

### Tenticles_design.md

**Add scope-boundary statement near the top.**

Insert as a new subsection (before Phase 0 content, or as its own opening section titled "Scope Boundary"):

> ## Scope boundary with TentacleTech
>
> Tenticles renders environmental and ambient particles, including high-count tentacles that are part of level geometry or visual background. **Tenticles particles never collide with, attach to, or otherwise physically interact with the hero character.** Hero-coupled tentacles — any tentacle that can touch, grab, penetrate, or interact with the hero — are rendered by TentacleTech's PBD solver and vertex-shader skinning pipeline. There is no runtime handover between the two systems.
>
> If a scenario appears to require an environmental tentacle grabbing the hero, it is not an environmental tentacle. Author it as a TentacleTech tentacle anchored to level geometry.

**Add fluid roadmap paragraph.**

Insert near the Phase 7+ description or near the resource registry section:

> ## Fluids scope note
>
> Fluid simulation (slime dynamics, body-fluid pooling, dripping, ejaculation, saliva volumes beyond simple strands) is a Tenticles Phase 7+ concern. Until Tenticles reaches fluid-capable phases, hero body-fluid visuals are handled by two other mechanisms: (1) the hero skin shader reads a per-orifice `wetness` scalar from TentacleTech and drives shader parameters (sheen, flow, drip appearance); (2) TentacleTech's fluid-strand-on-withdrawal system (~50 lines in TentacleTech) handles single strands on separation. There is no fluid overlap between the two systems, and no fluids code should be duplicated across extensions.

### TentacleTech_Scenarios.md

**Add note about through-path scenarios as future acceptance tests.**

Append a new entry to the Part B scenario list (after Scenario 10), or in the B11 "How to use these scenarios" section:

> **Scenario 11 (future) — All-the-way-through.** A tentacle entering one orifice traverses and exits through a second orifice on the same hero. Acceptance test for §6.7 through-path tunnels. Specify once §6.7 implementation lands; use as Phase 8+ validation.

---

## New files to create

### Camera_Input.md

Path: project root (sibling to the extension folders).

```markdown
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
```

### Appearance.md

Path: project root.

```markdown
# Appearance — Customization and Hero Visual State

Game-layer system. Not a Godot extension. Owns: wardrobe, body customization, persistent visual state (accumulated marks and changes), and the editor panels for all of the above. Implementation deferred; this doc captures scope and architecture direction.

## Scope

**In scope:**
- Space-themed skintight clothing, rendered as a shell mesh with dissolve shader effects
- Body blendshape sliders (conservative range; not caricatured)
- Persistent decal layer for marks, scars, tattoos

**Out of scope:**
- Cloth physics or per-garment rigging
- Hair simulation
- Loose fabric, flowing garments
- Customization of non-hero characters (single hero only)

**Deferred:**
- Detailed customization UI
- Unlockable cosmetic content pipeline
- Save-scoped versioning of appearance items

## Hero visual state

Persistent across saves within a profile, resets on new-game:

- Body shape — blendshape weight vector
- Equipped clothing — single garment id (wardrobe is single-layer, no stacking)
- Clothing dissolve state — per-garment `dissolve_progress` 0..1
- Decal accumulator — positions, types, intensities of marks

## Dissolve shader

Each skintight garment is a shell mesh over the hero skin, sharing the underlying skeleton and skin weights. The garment material reads:

- `dissolve_mask` — authored texture; controls where dissolve initiates
- `dissolve_progress` — scalar 0..1
- `dissolve_edge_color`, `dissolve_edge_width`, `dissolve_noise_scale` — aesthetic knobs

Dissolve advances based on StimulusBus events (friction above threshold, stretch events, tearing events). Progress is monotonic within a run. Re-equipping resets progress.

## Decal accumulator

Bus events (`SkinPressure` above threshold, `OrificeDamaged` near-surface, grip-release marks) write decals into a render-target accumulator texture in hero UV space. The hero skin shader reads the accumulator as an additional material layer.

- Accumulator size: 2k × 2k, single texture, read-write
- Decal writes: small rasterization passes, not per-pixel CPU work
- Save/load: accumulator serialized as compressed image data or as a decal list replayed at load time (TBD; list is smaller if decal count is moderate)

## Authoring

A character editor panel belongs in the eventual "Cosmic Bliss Editor Plugin": body blendshape sliders, wardrobe picker, decal clear button, dissolve-preview slider, save/load appearance preset.

## Save integration

Appearance state is a save payload section (see `Save_Persistence.md`).
```

### Save_Persistence.md

Path: project root.

```markdown
# Save and Persistence

Single save file per profile. Versioned schema. Migrations run at load time. Minimal surface now; expand as subsystems stabilize.

## Scope

**Persistent across runs within a save, resets on new-game:**

- Mindset vector (6 axes; see `Reverie_Planning.md §2.7`)
- Appearance state (see `Appearance.md`)
- Accumulated currency (single type)
- Unlocked customization items
- Play stats (runs completed, total time)

**Per-session, not saved:**

- Current run state (active scenarios, active `EntryInteraction`s, Reverie state distribution)
- Pending bus events, ring-buffer contents
- Mid-run resume is deferred; a new run always starts clean

## Format

Godot `.tres` or `ConfigFile`. Top-level `schema_version: int` plus one block per subsystem:

```
schema_version: 1
reverie: { mindset: [f, f, f, f, f, f], ... }
appearance: { body_blendshapes: {...}, wardrobe_equipped: <id>, decals: [...] }
economy: { currency: int, unlocks: [<id>, ...] }
stats: { runs_completed: int, total_time_seconds: float }
```

## Migration

Each schema-version bump ships a `migrate_v<N>_to_v<N+1>(data)` function. Load-time flow:

1. Read `schema_version`.
2. For each version older than current, apply the matching migration in order.
3. Missing fields receive authored defaults; unknown fields are dropped with a log warning.

Migrations are mandatory for any schema change that adds, removes, or renames a field. Treat the save format as a versioned interface, not an implementation detail.

## Out of scope

- Cloud sync
- Save encryption
- Multiple save slots per profile (single slot initially)
- Binary save format (`.tres` is fine for current size)
```

### Gameplay_Loop.md

Path: project root.

```markdown
# Gameplay Loop — Early Notes

Gameplay structure is deliberately deferred until the four technical foundations are stable. This doc captures decisions made so far so that infrastructure can prepare correctly without prescribing final design.

## Committed decisions

- **Persistent mindset is the run-over-run progression vector.** The 6D mindset persists within a save and nudges per run.
- **Starting mindset is slightly below neutral** on each axis at new-game baseline. Exact values authored per hero.
- **Bliss is one desirable terminal state, not the only one.** Other emergent states of interest to be designed.
- **No run-failure state.** Worst-case run produces less or zero currency payout. Runs do not "game over."
- **Single-type currency.** Earned at run end. Payout function TBD.
- **Player is a disembodied ethereal entity.** No avatar, no inventory, no direct world interaction beyond tentacle control and possibly environmental actions (D-pad reserved).

## Under consideration

- **Roguelite structure** with run-based replay and meta-unlocks between runs. Not committed; scope hedge.

## Infrastructure needed now

- `RunStarted` / `RunEnded` bus events (see `TentacleTech_Architecture.md §8.1`)
- `economy.currency` field in save (see `Save_Persistence.md`)

## Explicitly deferred

- Encounter design
- Scenario-scorer tuning for run-payout calculation
- Unlock progression structure
- Tutorial / first-run experience
- UI for mindset feedback
- Run length, pacing, transitions between encounters
```

---

## Not included in this update (filed for later)

The following were discussed during this design-review session and are deliberately excluded from this update. Do not apply them:

- Extracting StimulusBus into its own extension
- Adding an `IPenetrable` interface abstraction in TentacleTech
- Removing narrative events (`DialogueAddressed`, `ObserverArrived`, `EnvironmentalFlash`, `LoudSound`, `TemperatureDrop`) from the StimulusBus core enum
- Splitting TentacleTech into SplineTech + OrificeTech
- Scenario-runner test harness tooling
- Open-source preparation for Marionette or Tenticles
- Shared bus-schema header/resource file across extensions

Revisit these after the Reverie bus interface has seen real use.
