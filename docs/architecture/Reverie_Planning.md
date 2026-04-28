# Reverie — Planning Notes

**Forward-looking design notes for the Reverie extension (reaction system + facial rig).** Reverie is not being implemented yet; this document captures the shape it needs to take so TentacleTech's stimulus bus interface is forward-compatible. Detailed Reverie architecture will be produced separately when implementation begins.

---

## 1. What Reverie does

Reverie consumes stimulus events and continuous state from the bus, maintains an internal representation of character emotional state and long-term mindset, and produces:

- **Modulation writes** back to the bus (affecting tentacle/orifice physics — grip tensing, seeking, jaw relaxation, voluntary motion)
- **Facial expressions** (via blendshape weights on the hero's face mesh)
- **Vocalization queue** (which audio lines to play, in what tone)
- **Shader parameter outputs** (skin flushing, sweat, goosebumps, tear tracks, pupil dilation)
- **Body target cues** (active ragdoll pose targets — consumed by Marionette)

Reverie does **not** directly modify physics state. Everything flows through modulation channels on the stimulus bus.

## 2. State model

### 2.1 Base states (short-term, seconds-scale)

States are a **distribution**, not mutually exclusive. At any moment, the character might be 60% aroused + 30% in-pain + 10% curious. Transitions are continuous.

Starting list:
- Hopeless, Confused, Aroused, Angry, Ecstatic, In-pain, Afraid, Exhausted, Curious, Surrendered, Embarrassed, Bored, Overwhelmed, Dissociated, Defiant, Tender, Anticipatory

Each state has an associated **reaction profile** — which facial expressions, body postures, vocalizations, breathing patterns it tends to produce. Reverie blends these profiles weighted by the state distribution.

### 2.2 State dynamics

Each state has:
- A **rate-of-gain function** reading from the bus (how quickly it grows given current stimulus)
- A **decay rate** (states decay toward baseline when not sustained)

Examples:
- Repeated high-magnitude pain events → In-pain gains; Overwhelmed gains if sustained
- Sustained gentle contact on high-sensitivity areas → Aroused and Tender gain
- Prolonged high-pressure engagement → Exhausted gains; Dissociated gains if very prolonged
- Successful resistance/escape → Angry, Defiant gain
- Peak moments → Ecstatic gains sharply, then Exhausted via refractory
- Novel stimulus → Anticipatory, Alert gain transiently

Implementation: 17 floats (the state distribution), updated each Reverie tick (~20 Hz is enough, doesn't need physics-tick rate).

### 2.3 Mindset (long-term, minutes-to-hours scale)

Mindset is a slower-moving modifier of state dynamics. Six continuous axes (each -1 to +1):

- Broken ↔ Blissful
- Anxious ↔ Trusting
- Alert ↔ Dulled
- Resistant ↔ Yielding
- Self-aware ↔ Lost
- Tender ↔ Feral

A character occupies a point in this 6D space. Combinations produce distinct "personalities": broken+anxious+resistant = stoically suffering; blissful+yielding+lost = transcendent abandon; etc.

Mindset modulates:
- **Which base states are easier to reach** (blissful → Ecstatic gains faster; broken → Hopeless gains faster)
- **How intensely states express** (feral → louder vocalizations; dulled → muted reactions)
- **Pain-to-pleasure conversion** (blissful + yielding → some pain events reinforce Ecstatic instead of In-pain)

**Pruning review pending.** Six axes may be excessive. `Broken↔Blissful`, `Resistant↔Yielding`, and `Self-aware↔Lost` are core to the vision and load-bearing for the intended emotional range. `Alert↔Dulled`, `Anxious↔Trusting`, and `Tender↔Feral` are under review for merging, removal, or correlation-to-other-axes once first playtest data exists. Authored mindsets through implementation should favor the three core axes and use the others conservatively.

### 2.4 Mindset dynamics

Shift slowly based on long-term accumulated stimulus:
- Prolonged pleasure → blissful, yielding direction
- Prolonged pain without respite → broken, dulled
- Repeated failed resistance → yielding
- Gradual safety → trusting
- Sudden betrayal/threat → anxious, resistant (sharp shift)
- Peak moments → lost, yielding (temporary)

Mindset shifts are always slower than state shifts. Typical rate: hours to shift one axis 0.5. Short encounters barely move mindset; long ones significantly.

### 2.5 Implementation sketch

```gdscript
class_name Reverie extends Node

var states: Dictionary = {}   # StateId -> float (distribution weight)
var mindset: Dictionary = {}  # AxisId -> float (-1 to 1)

func _ready():
    for state in StateId.values():
        states[state] = 0.0
    states[StateId.NEUTRAL] = 1.0
    for axis in MindsetAxis.values():
        mindset[axis] = 0.0

func _process(delta):
    _update_states(delta)
    _update_mindset(delta)
    _apply_reactions(delta)

func _update_states(delta):
    var recent_events = StimulusBus.query_events_since(last_tick_time)
    var continuous = StimulusBus.read_continuous_snapshot()
    
    for state in states.keys():
        var gain_rate = state_gain_function[state].call(recent_events, continuous, mindset)
        var decay_rate = state_decay_rate[state]
        states[state] += gain_rate * delta
        states[state] *= (1.0 - decay_rate * delta)
    
    _normalize_states()

func _apply_reactions(delta):
    # Blend reaction profiles by state distribution
    var facial = _blend_facial_expressions(states, mindset)
    _write_blendshapes(facial)
    
    var modulation = _compute_modulation(states, mindset, recent_events)
    _write_modulation_to_bus(modulation)
    
    var vocalization = _select_vocalization(states, mindset, recent_events)
    if vocalization:
        _queue_vocal_line(vocalization)
```

Mostly GDScript. Nothing here is physics-tick-rate performance-critical; ~20 Hz is fine.

## 2.6 Attention and gaze

Reverie owns attention-target selection. Each Reverie tick (~20 Hz) it selects a single primary target from a salience computation and writes it to the `CharacterModulation` attention channel on the StimulusBus (see `TentacleTech_Architecture.md §8.2`).

**Salience inputs:**

- `tentacle_controlled_by[i] == Player` — large constant bump for the controlled tentacle. Player-controlled tentacles almost always win salience.
- Tentacles with recent high-magnitude `SkinPressure`, `PenetrationStart`, `BulbPop` events — salience weighted by event magnitude with ~1s exponential decay.
- Body areas with rising arousal — moderate salience.
- Observer (the disembodied player-entity) — valid target during specific state distributions (high `Curious`, high `Lost`, low `Hopeless`). This is the mechanism for the hero looking up at the player.
- World points of interest — context-driven; low baseline salience unless explicitly authored.

**Hysteresis:** minimum 0.4s dwell time before switching targets, unless a new target's salience exceeds the current target's by >2×. Prevents visual jitter from bus-noise.

**On player release:** attention does not snap. Previous target's salience decays over ~1s; gaze drifts away naturally as other targets rise in relative score.

**Consumers of the attention channel:**

- Marionette cervical (neck) chain SPD — biases skull orientation toward the attention world-position. Body does not rotate; only neck. See `docs/marionette/Marionette_plan.md` P8.X.
- Facial system — drives eye aim kinematically toward the attention world-position. Eye bones are kinematic, not Marionette-driven.

**Attention intensity** scales both effects. At `intensity = 0`, gaze is idle (breath-level drift). At `intensity = 1`, gaze is locked on. State distribution modulates intensity (e.g., high `Hopeless` caps intensity at 0.3 — the hero doesn't track anything strongly).

## 2.7 Persistence

Mindset is save-scoped. The full 6D vector persists across run boundaries within a save file. New-game resets to a baseline that is **slightly below neutral** per axis; exact values are authored per hero in the hero resource. Save schema details live in `docs/Save_Persistence.md`; Reverie writes the `reverie.mindset` block at save time and reads it at load time.

## 3. Stimulus bus interface (from Reverie's side)

### 3.1 What Reverie reads

**Events** (via `query_events_since(t)`):
- All interaction events (PenetrationStart, BulbPop, StickSlipBreak, GripEngaged/Broke, RingOverstretched, HardStopBottomedOut, FluidSeparation)
- Contact events (Impact, TangentialSlap, SkinPressure)
- Structural (OrificeDamaged, TentacleTangled)
- External (EnvironmentalFlash, LoudSound, TemperatureDrop, DialogueAddressed, ObserverArrived)
- Oviposition / birthing: `PayloadDeposited`, `PayloadExpelled`, `StorageBeadMigrated`, `RingTransitStart`, `RingTransitEnd`
- `PhenomenonAchieved` — emitted when a rare emergent event is detected by a `PhenomenonDetector` (see `docs/Gameplay_Mechanics.md`); Reverie reads for state-gain purposes (novelty → Anticipatory, Ecstatic spikes on peak phenomena, etc.)

**Continuous channels:**
- `body_area_pressure[area_id]`
- `body_area_friction[area_id]`
- `body_area_contact_count[area_id]`
- `body_area_sensitivity[area_id]` (static, authored)
- `body_area_arousal[area_id]`
- `orifice_state[orifice_id]` (stretch, depth, wetness, damage, grip_engagement, rubbing rates, tentacle count)
- Environmental (light level, ambient sound)

### 3.2 What Reverie writes (modulation)

Per orifice:
- `grip_strength_mult`
- `stretch_stiffness_mult`
- `ring_spring_k_mult`
- `wetness_passive_rate_bias`
- `active_contraction_target`, `active_contraction_rate`
- `seek_intensity`, `seek_target_tentacle_id`
- `peristalsis_wave_speed`
- `peristalsis_amplitude`
- `peristalsis_wavelength`

Per body area:
- `pose_target_offset`, `pose_stiffness_mult`
- `voluntary_motion_vector`, `voluntary_motion_magnitude`, `voluntary_motion_rate`
- `receptivity_mult`

Global character:
- `global_tension_mult`
- `global_noise_amplitude`
- `breath_rate_mult`, `breath_depth_mult`, `breath_held`
- `jaw_relaxation`
- `pain_response_mult`
- `reaction_responsiveness_mult`
- `xray_reveal_intensity` — 0..1, written up to ~0.7 at state peaks (high `Ecstatic`, high `Lost`, high `Aroused`). Player input can clamp higher on top. Consumed by hero skin shader for translucency / reveal.

Per character / Marionette:
- `body_rhythm_frequency` — Hz, written to `Marionette.body_rhythm_frequency` (`docs/marionette/Marionette_plan.md` P7.10). Driven by arousal axis (or whichever emotional output the implementation settles on); tuning curve is a Reverie internal detail. The shared clock advances on `Marionette` and is read by `BoneOscillator`, `TravelingWaveCyclic`, and TentacleTech's `RhythmSyncedProbe` (`docs/architecture/TentacleTech_Architecture.md` §6.11). Phase-continuity / ramp protection lives on `Marionette` (integrated phase, never recomputed); Reverie just sets the target frequency.

  **Coupling loop end-to-end:**

  1. Reverie's arousal axis → writes `body_rhythm_frequency` on `Marionette`.
  2. Body produces hip + spinal motion at that frequency (P7.7 `hip_invite.tres`, P7.9 `spinal_undulation.tres`).
  3. `RhythmSyncedProbe` (TentacleTech) locks tentacle drive to the same clock, offset by `π` or `0`.
  4. Tentacle contact stimulus → feeds Reverie → raises arousal → raises frequency → loop.

Defaults = identity. Physics works correctly with Reverie absent.

### 3.3 Reverie also reads its own modulation

To know what it wrote last tick (for smooth ramping rather than jumping). Also allows external systems (cutscenes, scripted sequences) to override modulation — Reverie sees the override and doesn't fight it.

### 3.4 Engagement vector (write)

Reverie publishes a per-tick **engagement vector** consumed by `MarionetteComposer` (`docs/marionette/Marionette_plan.md` P10.4). It controls *how* the body adds to the rhythm — strength, phase relative to the body's own clock, and decoherence:

```
engagement_magnitude   ∈ [0, 1]    // how strongly the body adds to the rhythm
engagement_phase       ∈ (-π, π]   // offset from body_rhythm_phase
engagement_phase_noise ∈ [0, 1]    // decoherence; high values = phase scrambling
```

The vector is produced by Reverie's reaction-profile blend: each `ReactionProfile.tres` declares default values; Reverie blends across active mindset states with their distribution weights. The vector lives in a continuous (`magnitude × e^(i × phase)`) disk; the four named modes are regions:

| Mode | Magnitude | Phase | Noise |
|---|---|---|---|
| Refuse | high | irrelevant | high (scrambled) |
| Accept | ~0 | irrelevant | ~0 |
| Comply | moderate | 0 (phase-locked to displacement) | ~0 |
| Engage | high | +π/2 (phase-leads displacement → velocity-phase pump) | ~0 |

Mindset → engagement vector mapping is authored in `ReactionProfile.tres`; Reverie does not write joint angles. Marionette's composer consumes the vector and produces the per-bone effort via the predictive engagement pump (P10.6).

### 3.5 Frequency compliance (write)

The player (or any external driver — encounter scripting, AI suitor, etc.) publishes a `body_rhythm_frequency_proposed` value on the Stimulus Bus. Reverie does not pass it through directly. Each mindset state has a `FrequencyComplianceCurve` (`Resource`) defining:

```
preferred_band: Vector2  // min, max Hz
compliance_curve: Curve  // 0..1 across freq, peaks inside preferred_band
df_dt_max: float         // slew rate cap; max d(body_rhythm_frequency)/dt
```

Reverie computes the active mindset's effective curve as a weighted blend across the mindset distribution. Marionette's composer (P10.9) then lerps `body_rhythm_frequency` toward `proposed` at rate `compliance(proposed) × responsiveness`, capped by `df_dt_max`.

Authored starting points (tunable):

| Mindset | Preferred band | df_dt_max | Notes |
|---|---|---|---|
| Calm / Yielding | 0.3–0.6 Hz | 0.2 Hz/s | Slow lock at low rates |
| Aroused | 0.8–1.5 Hz | 0.5 Hz/s | Fast tracking |
| Edge / Blissful | 1.5–2.5 Hz | 0.7 Hz/s | Fast but Overwhelmed accumulates if held |
| Resistant | (compliance ≈ 0 across all freq) | 0.05 Hz/s | Body refuses |
| Overwhelmed / Dulled | unstable / narrow | 0.1 Hz/s | Tracks briefly, breaks |

This pipeline replaces the prior "Reverie writes `body_rhythm_frequency` directly" sketch in §3.2: Reverie now writes the *curve* (per mindset blend) and the *proposed* frequency goes on the bus from any source; the composer is the lerp/slew owner. The `body_rhythm_frequency` field on `Marionette` is still the read-back value other systems consume.

### 3.6 `body_strain` (continuous channel, read)

Marionette's composer publishes `body_strain ∈ [0, 1]` per tick, computed as the sum of saturation across all SPD-driven joints:

```
body_strain = clamp(Σ smoothstep(0.7, 1.0, required_torque[j] / max_torque[j])² / N, 0, 1)
```

Reverie consumes for:
- Vocal modulation (grunt, breath catch at high values)
- Facial tension (jaw clench, brow knot blendshapes)
- Breath rate adjustment (faster when straining)
- Mindset drift toward Overwhelmed when sustained above threshold for more than a few seconds

Closes the self-regulation loop: high strain → mindset shifts toward Overwhelmed → engagement_magnitude decreases → strain reduces.

Hysteresis (Schmitt-trigger): emit "high strain" when strain > 0.6; emit "strain cleared" only when strain < 0.4. Otherwise Reverie sees flutter at a single threshold.

## 4. Output surfaces

### 4.1 Facial expressions

Face mesh rigged with blendshapes. Reverie's output is a dictionary of blendshape weights, updated ~20 Hz (interpolate on render thread for smooth motion).

Blendshapes grouped:
- Eye shape: wide, half-lid, closed, rolled back, scrunched
- Eyebrows: raised, furrowed, neutral, angled pain, angled concern
- Mouth shape: various (layered on jaw rotation from the orifice system)
- Tongue: extended, curled, protruded
- Cheek flush (or via shader parameter)
- Micro-tremor amplitude per region

Reverie's reaction profiles map states to blendshape sets. Blending handles multi-state characters naturally (60% aroused + 30% in-pain = weighted average of those blendshape sets).

### 4.2 Active ragdoll pose targets

Body postures are not authored as full target poses or as `BodyAreaModulation.pose_target_offset` lerps. They are authored as `PosturePattern` resources (micro-expression per-bone delta maps) and pushed to Marionette's composer as a weighted stack — see §5.5. Marionette (P10.3) sums the stack into the soup's posture-prior cost term, perturbing the rest pose at low weight.

Reaction profiles select pattern stacks per mindset:
- Ecstatic: `back_arch.tres` (high), `jaw_slack.tres` (moderate), `hand_grasp.tres` (low)
- In-pain + Resistant: `toe_curl.tres`, `hand_grasp.tres`, `neck_loll.tres` (negative weight = anti-loll, stiffening)
- Surrendered: `jaw_slack.tres`, `neck_loll.tres`, `hip_drop_left.tres` + `hip_drop_right.tres`; combined with low `engagement_magnitude` (§3.4) for limp expression
- Defiant: anti-curl stack + high `engagement_magnitude` with low phase noise → forward-lean reads as posture, not pose target

`pose_stiffness_mult` is no longer the right knob; expression intensity is governed by pattern weights and engagement magnitude. The `BodyAreaModulation` channels remain for non-postural bone-area modulation (e.g., voluntary motion vector), but posture itself flows through the pattern library.

### 4.3 Vocalization

Reverie maintains a vocal state (current audibility, timbre, pace) and queues one-shot lines when events warrant.

Inputs to vocalization selection:
- Recent events (BulbPop often triggers a sharp gasp; GripBroke often triggers a release sigh)
- State distribution (what emotional color)
- Mindset (tone/pacing — feral = louder, tender = softer)
- Duration since last line (don't spam)

Output: line ID + volume + pitch + timbre. Consumed by an audio playback subsystem that holds the voice samples.

### 4.4 Shader parameters

Per-region skin shader parameters:
- Flush intensity (0..1 per body region, drives red tint in shader)
- Sweat sheen (0..1, drives specular multiplier)
- Goosebump displacement (0..1, drives small vertex displacement)
- Subsurface warmth (adjusts subsurface scattering color)
- Tear track intensity (for facial regions)

Fed by state + events (Afraid spikes goosebumps; Aroused raises flush in linked areas; peak events cause sweat pulse).

## 5. Authoring surface

### 5.1 Reaction profile resource

One per base state:
```gdscript
class_name ReactionProfile extends Resource
@export var blendshape_weights: Dictionary  # blendshape_name -> weight
@export var body_pose_offsets: Dictionary   # body_area_id -> Vector3
@export var body_stiffness: Dictionary
@export var vocal_timbre: VocalTimbre
@export var flush_by_region: Dictionary
# ...
```

Blended weighted by state distribution at runtime.

Reaction profiles may branch on `tentacle_controlled_by == Player`. Player-controlled tentacles produce stronger attention and more intimate facial responses at equal physical stimulus; AI tentacles are treated as less-personal contact. **Physics is unaffected by this branching** — modulation writes to orifice/body-area channels use the same values for AI and player tentacles. The difference is confined to attention, facial, and vocalization outputs.

### 5.2 Mindset modifier resource

One per mindset axis, defining how this axis changes state gain/decay rates and expression intensities:
```gdscript
class_name MindsetModifier extends Resource
@export var state_gain_modifiers: Dictionary  # StateId -> multiplier
@export var expression_intensity_mult: float
@export var special_conversions: Array         # e.g., "pain events feed Ecstatic instead of In-pain when value > 0.5"
```

### 5.3 Per-hero sensitivity map

Authored per body area — static sensitivity value. Genital/nipple regions higher; extremities lower. Combined with mindset's `global_arousal_multiplier` to compute arousal gain from stimulus.

### 5.4 Per-hero personality baseline

Authored starting mindset vector + default state distribution. Different heroes can have identical physics but react very differently due to different authored baselines.

### 5.5 Posture pattern library

Body postures are not authored as full target poses. They are authored as small per-bone delta maps (`PosturePattern.tres` resources) representing micro-expressions:

```
# PosturePattern.tres
name: StringName             # "toe_curl", "back_arch", "jaw_slack", "hand_grasp", "hip_drop_left", ...
bone_deltas: Dictionary[StringName, Quaternion]
default_weight_curve: Curve  # optional (e.g. ease-in for slower micro-expressions)
```

Reverie's reaction profiles point at one or more `PosturePattern` resources with per-mindset weights. Per-tick:

```
pattern_stack = []
for each active mindset state with distribution weight m:
    for each pattern in mindset.posture_patterns:
        pattern_stack.append((pattern, m × pattern.weight))
Marionette.set_posture_pattern_weights(pattern_stack)
```

Marionette's composer (P10.3) consumes the stack as the posture-prior cost term: composer sums weighted bone-deltas across the stack and uses the composed offset as a low-weight target perturbation in the IK soup.

Default starting library: `toe_curl.tres`, `back_arch.tres`, `jaw_slack.tres`, `hand_grasp.tres`, `hip_drop_left.tres`, `hip_drop_right.tres`, `neck_loll.tres`, `eye_roll.tres` (eye_roll lives on the face rig, not body — but pattern files are uniform; both consumers read the same shape).

**Pattern stack ordering matters when patterns conflict.** Two patterns prescribing opposing deltas on the same bone produce a weighted average; the composer's soup will sum and compromise. If a pattern *must* override (e.g., "back arch" overrides a less-specific "spine relax"), give it a much higher weight rather than relying on order.

### 5.6 EngagementProfile resource

Embedded in `ReactionProfile.tres` (per-mindset reaction profile), or stand-alone if useful:

```
class_name EngagementProfile extends Resource
@export var magnitude: float = 0.0          # 0..1
@export var phase: float = 0.0               # -π..π
@export var phase_noise: float = 0.0         # 0..1
```

Reverie blends engagement profiles weighted by mindset distribution and writes the resulting vector via `Marionette.set_engagement_vector(...)` (§3.4). The four named modes (Refuse / Accept / Comply / Engage) are regions in this disk, not enum values.

### 5.7 FrequencyComplianceCurve resource

```
class_name FrequencyComplianceCurve extends Resource
@export var preferred_band: Vector2          # min, max Hz
@export var compliance_curve: Curve          # 0..1 across freq domain
@export var df_dt_max: float = 0.3           # Hz/s slew limit
```

One per mindset state. Reverie blends across active mindsets and hands the resulting curve to the composer via `Marionette.set_frequency_compliance_curve(...)` (§3.5).

## 6. The character state → physics feedback loop

Full trace through one scenario (tip-test of an orifice by an exploring tentacle on a blissfully-mad character):

1. Physics: tentacle tip contacts orifice area → publishes `SkinPressure` event, updates `body_area_pressure[orifice area]`
2. Reverie next tick: reads recent events, reads continuous state
3. Reverie looks up current state distribution: `{Aroused: 0.6, Ecstatic: 0.25, Curious: 0.15}`
4. Reverie looks up current mindset: `Blissful: +0.8, Trusting: +0.6, Lost: +0.4, Yielding: +0.7` ("blissfully mad" region)
5. Reverie consults reaction profile for `(SkinPressure near orifice, Aroused+Blissful+Lost)`:
   - Facial: blend toward bliss_grin
   - Modulation changes:
     - `orifice.modulation.grip_strength_mult = 1.8`
     - `orifice.modulation.stretch_stiffness_mult = 1.4`
     - `orifice.modulation.seek_intensity = 0.7`
     - `orifice.modulation.seek_target_tentacle_id = <that tentacle>`
     - `body_area[orifice region].voluntary_motion_vector = toward_tentacle`
     - `body_area[orifice region].voluntary_motion_magnitude = 0.4`
   - Vocalization: breathy moan queued
6. Physics next ticks: orifice grip is 1.8×, pelvis drifts toward tentacle
7. Tentacle finds deeper contact than expected; new events; loop continues

## 7. Deferred-for-now design questions

Open questions for when Reverie actually starts development:

- **Exact state list and weights** — 17 starting states are a guess; validate with test play
- **Mindset axis independence** — some axes might not be independent (self-aware ↔ lost correlates with alert ↔ dulled); treat as correlated or force independent?
- **Timescales** — states update at ~20 Hz, mindset at ~0.1 Hz? Profile and tune
- **Per-scene vs persistent mindset** — does mindset carry between encounters, save with the game state, or reset each scene?
- **Voice system architecture** — does Reverie hold the voice lines or does a separate VoiceManager? Probably separate; Reverie just queues intent
- **Face rig performance** — ~30 blendshapes updated per tick is fine; keep the count down or mesh update cost grows
- **Authoring tools** — reaction profile resources are fiddly; worth building a graphical reaction editor?

## 8. What TentacleTech needs to provide (non-Reverie responsibilities)

For the bus to serve Reverie correctly when it's built:

- **Body area mapping** — each hero has a resource defining bone → body_area_id + sensitivity. This is TentacleTech territory because physics uses it too.
- **Orifice linked body areas** — each orifice profile lists body areas that feed its arousal. Also TentacleTech, because the wetness-arousal coupling runs in physics.
- **All events from the canonical list** (§3.1) — TentacleTech must emit each of these at the right moment
- **All continuous channels** — updated each tick from physics state
- **Modulation channel read support** — physics reads from bus each tick and applies

The TentacleTech architecture already specifies all of this. This section is a checklist that nothing gets dropped.

## 9. Phase plan for Reverie

Not starting yet; rough outline for later:

1. **Phase R1 — State skeleton.** GDScript class with state distribution, mindset vector, Reverie tick reading bus. No reactions yet, just verify state distribution shifts correctly with stimulus.
2. **Phase R2 — Modulation writes.** Simple reactive profile (e.g., pain events → tense → `global_tension_mult` rises briefly). Verify physics feels the modulation.
3. **Phase R3 — Facial blendshape output.** Author a first set of reaction profiles. Verify faces blend smoothly across state transitions.
3.5. **Phase R3.5 — Attention and gaze.** Implement salience function, attention-target selection with hysteresis, modulation-channel write-out. Verify that Marionette's neck driver and the facial system's eye aim both respond correctly to the attention channel. Test player-control branching by toggling `tentacle_controlled_by` manually and confirming gaze tracks.
4. **Phase R4 — Shader parameters.** Flushing, sweat, tear tracks. Hero looks alive in response to physics.
5. **Phase R5 — Vocalization queue.** Basic one-shot lines tied to major events.
6. **Phase R6 — Posture patterns + engagement vector + frequency compliance.** When Marionette's composer (P10) is ready, drive body postures via the pattern library (§5.5), publish the engagement vector (§3.4 / §5.6), and write the active frequency-compliance curve (§3.5 / §5.7). Reverie does not write joint angles; the composer turns the per-tick triple (`engagement_vector`, `pattern_stack`, `frequency_compliance_curve`) into per-bone effort. Read `body_strain` (§3.6) and feed back into mindset drift toward Overwhelmed.
6.5. **Phase R6.5 — Peristalsis and ritual reactions.** Wire Reverie to write `peristalsis_*` channels based on state (e.g., high `Surrendered` + event pressure → expulsion waves; high `Anxious` → retention waves). Implement reaction profile branches for `PayloadDeposited` / `PayloadExpelled` / `RingTransitStart` / `RingTransitEnd` (distinct vocalizations and facial beats). Test with Scenario 12 and Scenario 13 setups.
7. **Phase R7 — Mindset dynamics.** Long-term accumulators affecting state gains.
8. **Phase R8 — Polish and authoring tools.** Reaction profile editor, mindset tuning.

Starts after TentacleTech Phase 6 (bus) is stable.

---

This document will be replaced by a proper `Reverie_Architecture.md` when implementation begins. For now, its purpose is to ensure TentacleTech's bus interface doesn't lock us out of any of these future capabilities.
