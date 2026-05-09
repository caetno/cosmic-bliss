# Cosmic Bliss — Design Update 2026-05-09 — Sonance + Visage

> **Status: drafted 2026-05-09, awaiting review.** Opens two new
> GDExtensions (`sonance` for audio synthesis, `visage` for facial
> expression / eye gaze / lip sync) and supersedes the audio + facial
> sections of two prior updates (2026-05-07 procedural audio +
> 2026-05-08 Sonance/Visage proposal). The architecture committed here
> is the **sample-first, migration-friendly** version: production path
> ships as sample-bank-with-modulation; procedural synthesis is added
> per-region as a stretch-goal R&D track that graduates incrementally
> (breath first, possibly moan / scream / gasp / grunt later) without
> blocking mainline.
>
> Reverie writes dimensional state on the bus. Sonance picks the
> rendering path. The seam between sample and procedural is internal
> to Sonance and invisible to Reverie / Visage / TentacleTech.

**Audience: top-level Claude (canonical record). Sub-Claudes read the
canonical extension docs once these are written.**

---

## TL;DR

Two new extensions, total goes from four to six:

- **Sonance** (audio synthesis) — voice production + physics-driven non-vocal sound. Single audio thread, single DSP runtime, two internal modules (`voice/`, `physics/`).
- **Visage** (face) — facial expression, eye gaze, lip sync. Frame-rate, blendshape and bone-target authoring.

Both are *not started* and gated on Reverie's interface contract being real + TentacleTech Phase 6 stimulus bus shipping + 4Q wedge stability closing.

The architectural commitments that distinguish this update from the 2026-05-08 proposal:

1. **Voice production is sample-first.** A sample-bank-with-modulation path covers the full vocal repertoire in v1. A breath-bed-loop library handles continuous voicing. SoundTouch (LGPL) does pitch / formant / time-stretch. Audio2Face stays in the offline-bake plan for sample sidecar curves.
2. **Procedural synthesis is a stretch-goal R&D track that graduates per-region.** Not always-on, not a parallel always-running stream. A `production_module` plugin interface lets sample and procedural modules coexist; the runtime picks per-cycle by state-space coverage. Migration is a flag-flip per region.
3. **Vocalization "types" are labels for regions of a continuous production space.** Per Anikin/Bååth/Persson 2018, named call categories (moan, scream, groan, etc.) are graded along a continuum, not discrete dispatch keys. The runtime routes by 8-axis state-space position, not by enum case. Categories survive as human-readable metadata.
4. **Motor state is path-agnostic.** Whether audio comes from a sample or a procedural module, the same motor channel (`jaw_open`, `lip_aperture`, `tongue_pos`, `velum_open`, `AES_constriction`, `larynx_height`, `breath_phase`) is published. This is what lets Visage's lip sync stay invariant across the migration. Silent-vocalization rendering (held breath before scream, silent sob, silent laugh) becomes free because motor state is decoupled from the phonation gate.
5. **Sample tags use the same eight production axes that procedural modules emit.** Migration trivially: when a procedural module replaces sample for a region, all downstream consumers (motor channel, mixer, Visage) operate in the same coordinate system.
6. **Reverie writes dimensional state.** Reverie does not know about production paths, sample banks, or procedural modules. The Reverie ↔ Sonance interface is purely dimensional state + dimensional event triggers.

The eight production axes, the temporal scaffold (respiratory FSM + episode arc + three-clock rhythm), and the motor-vs-phonation factoring all land in v1 even though procedural is stretch — because the sample path uses them too.

---

## Why now — what changed since the 2026-05-08 proposal

The 2026-05-08 proposal had Sonance shipping with two co-existing always-on streams: discrete sample stream + continuous runtime synth (clean-room soundgen reimplementation). User direction 2026-05-09: procedural non-verbal vocalization is a research-grade technique that produces *scientifically valid* outputs but not necessarily *good-feeling* outputs without prohibitive tuning. Build the sample path as the production path; treat procedural as a stretch goal that may graduate per-region if it ever sounds good enough. Don't block mainline on it.

This is the responsible call. Migration architecture lets the stretch goal exist without coupling cost — if it pans out, regions migrate one at a time; if it doesn't, mainline ships unaffected.

A second input landed 2026-05-09: a research synthesis of the production-mechanism taxonomy of human nonverbal vocalization (Anikin, Fitch, Reby, Pisanski, Bryant, Sauter, Cordaro, Cowen, Roubeau, Henrich, Titze, Story, Esling, Massenet et al. 2025). Three load-bearing structural claims from that synthesis are folded into this update:

1. **Vocalizations are graded, not categorical.** Architecture must route by state-space position, not by event-type enum.
2. **Eight production axes** organize the entire repertoire. Sample tagging and procedural rendering must operate in the same coordinate system.
3. **Motor state and phonation gate must be factored.** Silent vocalization (breath-hold before scream, silent sob, silent laugh) is a distinct motor state with no audio output; lip sync and face animation must work for it.

These three commitments survive whether or not procedural ever graduates.

---

## Extension table

| Extension | Domain | Status |
|---|---|---|
| TentacleTech | tentacle PBD physics, orifices, stimulus bus | active, most mature |
| Marionette | active ragdoll, SPD, IK composer | active |
| Tenticles | GPU particles (NGP-style) | paused |
| Reverie | mindset, emotion, attention, vocal-intent state | not started |
| **Sonance** | voice synthesis + physics-driven audio | **not started** |
| **Visage** | face expression, eye gaze, lip sync | **not started** |

Six extensions total. The legacy `dpg` continues to be phased out as a spline-math reference only.

---

## The Reverie ↔ Sonance interface — dimensional state

Reverie writes the following channels on the existing stimulus bus. Sonance subscribes. **Reverie does not address production paths, vocalization types, or sample IDs.**

| Channel | Range | Notes |
|---|---|---|
| `arousal` | 0..1 | already in TT §8.2; meaning generalizes |
| `valence` | -1..1 | new |
| `effort` | 0..1 | orthogonal to emotion (Raine, Pisanski & Reby 2017 *Anim. Behav.* — tennis grunts) — for grunts, throws, exertion |
| `breathiness` | 0..1 | independent fast-modulation axis — disambiguates pleasure / pain at high arousal (Anikin 2020 *Phonetica*) |
| `pain_index` | 0..1 | separate from valence — same NLP regime can read either way at high arousal |
| `pleasure_index` | 0..1 | separate from valence — combines with `pain_index` for ambiguous high-arousal states |
| `social_visibility` | 0..1 | volitional overlay (Brewer & Hendrie 2011) — controls vocalization rate / intensity at constant arousal |
| `body_size_signal` | 0..1 | size-signaling intent (deepens F0, lowers formants — Pisanski et al. 2016) |
| `body_rhythm_phase` | 0..2π | already from Marionette P7.10 |
| `breath_target_rate` | Hz | Reverie writes; Sonance Kuramoto-couples to body |
| `vocal_intent_event` | discrete queue | event payload is dimensional, not categorical — see below |

### Why `pain_index` and `pleasure_index` are separate channels

Per Anikin (2020 *Phonetica*) and Anikin & Persson (2017): at high arousal, the same NLP regime (subharmonics, biphonation, jitter) can read as pain *or* pleasure depending on context, with **breathiness** as the disambiguator. Having `pain_index` and `pleasure_index` as separate channels — combined with `breathiness` as an independent fast-modulation axis — lets sample selection and procedural rendering pick differently in ambiguous high-arousal regions. A single `valence` axis collapses this distinction and produces blurred vocal output at the high end.

### Discrete event queue

Reverie queues `VocalEvent` records on a separate channel:

```
struct VocalEvent {
    StateVector at_state;       // dimensional state at trigger
    StateVector target_state;   // where state pushes during the event
    float duration_hint;        // optional; can be inferred
    float urgency;              // 0..1 — controls interruption of currently-playing material
    EventTag tag;               // OPTIONAL hint, not dispatch key
};
```

`EventTag` is a hint for the path selector — tags like `"orgasm_peak"`, `"gasp_intake"`, `"sob_convulsion"` help the selector bias its region match, but they do not determine which module renders. Two modules can both claim coverage of `"gasp_intake"` and the selector picks by quality + availability.

### Sonance writes back

| Channel | Notes |
|---|---|
| `vocal_busy_until_t` | for Reverie's cooldown logic |
| `current_phonation_active` | bool — for Reverie state feedback |
| `current_motor_state` | full motor channel — Visage subscribes to this directly |
| `vocal_effort_now` | 0..1 — Reverie can use to feed back into emotion drift |

---

## The eight production axes

Per the research synthesis (Roubeau, Henrich, Castellengo 2009; Esling 1999 / 2005; Anikin 2019 *Behav. Res. Methods*; Massenet et al. 2025; Story & Titze 1995), the entire human nonverbal repertoire is organized along these axes:

| Axis | Symbol | Range | What it controls |
|---|---|---|---|
| A — Airstream | `airstream` | egressive / ingressive / null / glottalic / velaric | Direction and source of airflow; required for gasp / ingressive sob / kiss / click distinctions |
| B — Mechanism | `mechanism` | M0 / M1 / M2 / M3 + ventricular | Vocal-fold register; transitions are discrete events with frequency jumps |
| C — Glottal posture | `glottal_posture` | breathy ↔ modal ↔ pressed | H1-H2, aspiration, jitter floor; the pleasure / pain disambiguator |
| D — Ventricular engagement | `ventricular` | retracted / compressed / co-oscillating | False folds as independent oscillator (biphonation type II) for growl / scream / cry |
| E — Aryepiglottic constriction | `AES` | 0..1 | Twang / belt / ring / scream brightness / pain squeeze; 2-4 kHz boost |
| F — Vocal tract config | `tract` | vector | Larynx height, jaw, lips, tongue body, tongue root, velum (nasal coupling), pharyngeal cross-section |
| G — Respiratory pattern | `respiratory` | enum | Sustained exhale / short / sustained inhale / panting / sob convulsion / hyperventilation / breath hold / forced exhale |
| H — Body coupling | `body_coupling` | rate, depth, pulse shape | Diaphragmatic spasm (laugh ~4–5 Hz), sob convulsion (~0.5–2 Hz), shudder (~6–10 Hz), pelvic rhythm in sex (entrains "ah-ah-ah") |

These axes are the **shared coordinate system** between sample tagging and procedural rendering. They are also the runtime state in the synth — mostly slowly-varying (mechanism transitions and frequency jumps are events) — and are the mapping target from Reverie's dimensional input.

### What's *not* in the eight axes (deliberately)

- Categorical event types (moan / scream / groan / etc.) — those are labels for regions of the 8-axis space, used as human-readable metadata and as `EventTag` hints, not as a routing dimension.
- Per-vocalization style presets — those live as profile resources that bias the state-mapping (see "Per-character vocal profiles" below), not as a separate axis.
- Phonation gate — that's the on/off bit independent of the axes (silent vocalization has motor state defined on the axes but no audio).

---

## Sonance internal architecture

```
extensions/sonance/
├── CLAUDE.md
├── SConstruct
├── sonance.gdextension
│
├── src/
│   ├── state/                       # state vector definitions
│   │   ├── vocal_state.h            # 8-axis state-space point + dimensional-mapping intermediate
│   │   ├── reverie_state_reader.{h,cpp}    # subscribe to bus channels
│   │   └── state_to_axes_mapper.{h,cpp}    # Reverie dimensional → 8 production axes
│   │
│   ├── scaffold/                    # temporal hierarchy (research §11)
│   │   ├── respiratory_fsm.{h,cpp}  # inhale / hold / exhale / forced-exhale FSM, top-level
│   │   ├── episode_arc.{h,cpp}      # parametric build-plateau-climax-release; driven by
│   │   │                            # state evolution, not a fixed timeline
│   │   ├── bout_scheduler.{h,cpp}   # within-phase bout scheduling
│   │   └── kuramoto_breath.{h,cpp}  # body↔breath phase coupling
│   │
│   ├── selector/                    # path selection — the migration seam
│   │   ├── production_module.h      # interface every voice path implements
│   │   ├── module_registry.{h,cpp}  # module registration + region matching
│   │   └── path_dispatcher.{h,cpp}  # picks module per cycle by region match + quality
│   │
│   ├── voice/
│   │   ├── sample_module/           # PRODUCTION — covers the full repertoire
│   │   │   ├── sample_bank.{h,cpp}  # corpus organized by 8-axis tags
│   │   │   ├── tag_index.{h,cpp}    # nearest-neighbor lookup in production-axis space
│   │   │   ├── sample_scheduler.{h,cpp}     # respects respiratory FSM
│   │   │   ├── breath_bed_player.{h,cpp}    # crossfaded loops per state corner
│   │   │   ├── modulator/                   # SoundTouch-backed, runs on audio thread
│   │   │   │   ├── pitch_shift.{h,cpp}
│   │   │   │   ├── formant_shift.{h,cpp}
│   │   │   │   └── time_stretch.{h,cpp}
│   │   │   └── sidecar_curves.{h,cpp}       # per-sample motor-state curves
│   │   │
│   │   └── procedural/              # STRETCH — registers per-region modules
│   │       ├── breath/              # FIRST CANDIDATE per research §1, §10
│   │       │   ├── breath_synth.{h,cpp}     # noise + envelope + tract aperture
│   │       │   ├── ingressive_egressive.{h,cpp}
│   │       │   └── velum_branch.{h,cpp}     # oral / nasal mix
│   │       ├── (gasp/, moan/, scream/, etc. — register only when ready)
│   │
│   ├── physics/                     # physics-driven module (separate from voice)
│   │   ├── modal_contact.{h,cpp}    # 8–16 damped sinusoids, impulse-excited
│   │   ├── friction_dahl.{h,cpp}    # stick-slip oscillator, reads tentacle_lubricity
│   │   ├── bubble_minnaert.{h,cpp}  # 64–128 voice pool, low-Q damped sinusoid
│   │   └── reed_tube.{h,cpp}        # McIntyre/Schumacher/Woodhouse + delay-line
│   │
│   ├── motor/                       # PATH-AGNOSTIC output channel
│   │   ├── motor_state.h            # jaw / lip / tongue / velum / AES / larynx / breath
│   │   ├── phonation_gate.h         # decoupled from motor state
│   │   └── visage_publisher.{h,cpp} # publishes via bus to Visage
│   │
│   ├── audio_thread/                # shared infra (~70% of Sonance LoC)
│   │   ├── ring_buffers.{h,cpp}     # SPSC, physics-thread → audio-thread
│   │   ├── mixer.{h,cpp}
│   │   ├── biquad_bank.{h,cpp}
│   │   └── stream_generator.{h,cpp} # Godot AudioStreamGenerator integration
│   │
│   └── register_types.{h,cpp}
│
├── gdscript/
│   ├── authoring/                   # editor tools
│   │   ├── sample_tagger.gd         # 8-axis tag editor for samples
│   │   ├── breath_bed_editor.gd     # corner placement + crossfade boundaries
│   │   └── episode_arc_editor.gd    # arc-template editor
│   ├── profile/
│   │   └── vocal_profile.gd         # per-character preset deltas on the state mapping
│   └── debug/
│       ├── vocal_state_overlay.gd   # render current 8-axis state + active module
│       └── episode_arc_overlay.gd
│
└── shaders/                         # (none in v1)
```

### `production_module.h` — the migration seam

```cpp
class ProductionModule {
public:
    virtual ~ProductionModule() = default;

    // Does this module own the current state-space point?
    virtual bool covers_region(const VocalState& s) const = 0;

    // Quality score for tie-breaking when multiple modules cover.
    // Procedural modules graduate by demonstrating quality_score > sample
    // module across the region they own.
    virtual int quality_score(const VocalState& s) const = 0;

    // Produce both audio and motor state for one cycle.
    virtual void render(const VocalState& s,
                        AudioBuffer& audio_out,
                        MotorStateOut& motor_out,
                        const RespiratoryPhase& phase) = 0;

    virtual void cancel() = 0;       // for event-driven interruption
    virtual void reset() = 0;
};
```

The path dispatcher iterates registered modules each cycle, picks the highest-quality coverer, calls `render`. v1 has only the sample module registered — it covers everything. Procedural modules graduate by registering and announcing coverage of their region; the sample module remains as fallback for everything they don't claim.

### Why the sample module owns "everything" by default

The sample module's `covers_region` returns true for any state-space point, with a baseline `quality_score`. Procedural modules raise their score above baseline only inside their region. This means:

- v1 ships with samples covering everything.
- v1.1 adds the breath procedural module — it claims the breath-dominated subregion (low arousal × low phonation × airflow-noise-dominated) with a high quality score; the dispatcher routes those points to the procedural module; sample module still handles everything else.
- v1.2+ adds gasp / moan / etc. similarly.
- A procedural module that doesn't pan out simply doesn't graduate — its `quality_score` stays below sample's baseline and the dispatcher never picks it.

---

## Visage internal architecture

```
extensions/visage/
├── CLAUDE.md
├── SConstruct
├── visage.gdextension
│
├── src/
│   ├── state/
│   │   ├── reverie_state_reader.{h,cpp}    # emotional state reads
│   │   └── motor_state_reader.{h,cpp}      # subscribes to Sonance's motor channel
│   │
│   ├── face/
│   │   ├── blendshape_authoring.{h,cpp}    # ARKit 52 + extensions
│   │   ├── emotion_base_layer.{h,cpp}      # brow / cheek / nose from emotional state
│   │   ├── viseme_layer.{h,cpp}            # mouth shape from F1/F2 in motor state
│   │   ├── micro_tremor.{h,cpp}            # per-region amplitude tremor from emotional state
│   │   └── shader_param_writer.{h,cpp}     # flush / sweat / tear-track / SSS-warmth
│   │
│   ├── eyes/
│   │   ├── gaze_solver.{h,cpp}             # look-at IK to attention target
│   │   ├── eye_node_attachment.h           # eye Node3D children of head BoneAttachment3D
│   │   ├── pupil_dilation.{h,cpp}          # writes shape-key on eyeball mesh
│   │   ├── eyelid_blendshapes.{h,cpp}      # FaceIt ARKit blink / squint / wide
│   │   └── saccade_micro_motion.{h,cpp}    # writes eye-shader iris_offset uniform
│   │
│   ├── targets/                            # Visage as peer author into physics
│   │   ├── jaw_target_writer.{h,cpp}       # → Marionette IK composer
│   │   ├── lip_ring_offset_writer.{h,cpp}  # → TentacleTech rim rest-position offsets
│   │   └── lip_shape_blendshapes.{h,cpp}   # non-ring lip shape (corner pull, asymmetry)
│   │
│   ├── tongue/
│   │   └── tongue_blendshapes.{h,cpp}      # default; tongue bones routed via Marionette later
│   │
│   └── register_types.{h,cpp}
│
├── gdscript/
│   ├── authoring/
│   │   ├── face_puppet_editor.gd           # blendshape authoring tool
│   │   └── posture_pattern_editor.gd       # eye-gaze posture patterns
│   └── debug/
│       ├── motor_state_overlay.gd          # render current motor state
│       └── viseme_overlay.gd
│
└── shaders/                                # (eye shader stays in game/assets)
```

### Visage's authoring-target pattern

**Voice and face never directly move physical things.** Anatomical structures with physics responsibility (jaw bone, lip ring) are owned by the physics layer. Sonance and Visage are **peer authors** of targets into those structures. Marionette and TentacleTech arbitrate.

Concrete contracts:

- **Jaw bone** — Marionette's. Both Sonance (vocalization) and Visage (expression) write jaw targets to Marionette's IK composer; SPD turns combined target into torque. Tentacle impacts apply impulses via the existing reciprocal-impulse path. Physics arbitrates; physics wins under load (a tentacle shoving the jaw open while voice wants it closed → voice's intent damped by the constraint, automatically; a smile during a soft moan → both visible).
- **Lip ring** — TentacleTech's. Sonance and Visage both write per-particle rest-position offsets. PBD spring-back pulls toward `authored_rest + visage_offset + sonance_offset`. Rim's anisotropic compression-stretch and J-curve still govern under load (a tentacle pulling lips apart during a smile → strained smile, automatically).

This is exactly the IK-composer pattern Marionette already uses for body posing. Sonance and Visage are additional clients. No new architecture, no coupling to resolve.

### Composition rule (working assumption — confirm or override)

- **Channel-segmented for blendshapes.** Vocal-mouth-shape channels owned by Sonance's motor channel during voiced events; brow / cheek / nose channels owned by Visage's emotional layer. No overlap on shapes.
- **Additive-with-weights for jaw.** Sonance's jaw weight scales with `vocal_effort` so loud vocalizations dominate quiet expressions, but a closed-mouth smile still reads during a soft moan.
- **Additive-with-weights for lip ring offsets.** Same pattern.

Recommend committing to this as the v1 default rather than deferring.

### Visage's relationship to the eye shader

`docs/Eye_Shader.md` (landed 2026-05-07) covers iris / sclera / cornea **rendering** — fragment-stage math, calibration, texture conventions. Visage covers eye **animation** — bone rotations, eyelid blendshapes, pupil dilation shape key, saccade micro-motion. The shader's `iris_offset` uniform is now Visage-driven (saccade output). Eye Node3D children of the head's `BoneAttachment3D` is Visage-owned scene structure; no skinning, no deformation; eyeball mesh has a single shape key for pupil dilation.

---

## Temporal scaffold (mandatory for v1, sample path uses it too)

These commitments land in v1 even though procedural is stretch — because the sample-bank path needs them.

### Respiratory FSM

Top of the temporal stack. States: `inhale_silent`, `inhale_voiced`, `held_full`, `exhale_silent`, `exhale_voiced`, `forced_exhale_voiced`, `held_empty`, `panting`, `sob_convulsion`, `laugh_staircase` (per Filippelli et al. 2001), `hyperventilation`. Transitions driven by Reverie's `arousal`, `effort`, `breath_target_rate`, `vocal_intent_event`. Sample selection respects the active phase — moans schedule on egressive, gasps on the inhale-to-exhale transition, sighs on terminal exhale, sob convulsions on the convulsion state. Without the FSM, sample sequences drift out of phase with body rhythm and lose plausibility.

### Episode arc (parametric template)

A first-class object. Anikin 2024 *EHB* documents the inverted-U arousal curve over time for human sexual vocalization (longer, louder, higher F0, more voiced, more unpredictable toward orgasm). v1 templates:

- **`SexualEncounterArc`** — build / plateau / climax / release with parametric durations and per-phase target-state envelopes.
- **`GeneralArousalArc`** — generic build / release for non-sexual high-arousal events.

Deferred to later (decision 3): `SobSpellArc`, `LaughFitArc`, `CryBoutArc`. They follow the same parametric template; just need their own per-phase definitions.

The arc's progress is **driven by Reverie's state evolution**, not by a fixed timeline. Reverie pushes state; the arc maps state to its build / plateau / climax / release region; arc position drives slow modulators (mean F0 shift, breathiness target, NLP-regime weights, AES weight, body-coupling depth) that the sample modulator (and any procedural module) reads.

### Three independent rhythm clocks

Per research §4 — rhythm is multi-layered, not a single rate parameter:

1. **Respiratory rhythm** — driven by FSM. 0.3–5 Hz. Cry bouts, panting, sob convulsions, laugh "ha-ha", hiccups.
2. **Body-coupled rhythm** — `body_rhythm_phase` from Marionette P7.10. 0.5–3 Hz typical. Pelvic rhythm during sex entrains "ah-ah-ah" moan stutter on one push.
3. **Glottal / supralaryngeal rhythm** — vibrato / tremor 3–8 Hz, NLP roughness 30–150 Hz (intrinsic to vocal-fold dynamics).

The three can be coherent or incoherent. Sample-bank lookups query a coherence flag (`body_entrained`, `breath_entrained`, `independent`) to pick samples whose body-coupling matches the current configuration. Procedural modules have all three clocks available as input.

### Motor state vs phonation gate (the architectural lever)

`MotorStateOut` is published every cycle with the full set: `jaw_open`, `lip_aperture`, `lip_rounding`, `tongue_body_pos`, `tongue_root_advance`, `velum_open`, `pharynx_cross_section`, `larynx_height`, `AES_constriction`, `breath_phase`, `subglottal_pressure`. Visage subscribes regardless of whether audio is being produced.

The `PhonationGate` is a separate scalar (0..1) that determines whether the motor state produces audible output. Silent vocalization (silent scream, held breath before scream, silent sob, silent laugh, breath hold, controlled exhale) → motor state defined and animated, phonation gate = 0.

This factoring:
- Sample sidecar curves include motor state during voiced *and* silent segments.
- Procedural modules emit motor state directly from their internal parameters.
- Visage doesn't know which path produced the motor state.
- Silent vocalization is rendered for free — it's just motor state with phonation = 0.

### Ingressive flag (first-class)

Per research §10 and Anikin & Reby 2022: muting ingressive intakes alone reduces perceived emotional intensity. v1 sample bank must include ingressive variants where they exist (gasps, ingressive sobs, ingressive laughs, ingressive scream intakes); the scaffold dispatches them on inhale phases. Sample tags include the airstream axis (egressive / ingressive / null / glottalic / velaric).

---

## Sample tagging schema (eight-axis)

Each sample in the corpus carries:

```yaml
# sample tag schema
audio_path: "sample_corpus/moan_breathy_low_001.wav"
sidecar_motor_curves: "sample_corpus/moan_breathy_low_001.curves"  # baked at corpus prep
production_axes:
  airstream: egressive
  mechanism: M1
  glottal_posture: 0.78         # 0=breathy, 0.5=modal, 1.0=pressed
  ventricular: retracted
  AES: 0.12
  tract:
    larynx_height: 0.3
    jaw_open: 0.5
    lip_aperture: 0.6
    lip_rounding: 0.4
    tongue_body: [0.4, 0.6]
    tongue_root: 0.2
    velum_open: 0.1
    pharynx: 0.5
  respiratory: sustained_exhale
  body_coupling:
    rate_hz: 1.2
    depth: 0.5
    pulse_shape: smooth
nlp_regime:                     # per research §10 — distinguishes from glottal_posture
  base: clean
  episode_likelihood: low       # probability of NLP episode within sample
  episode_types: []             # [period_n, sidebands, biphonation_II, chaos, frequency_jump]
metadata:
  category_label: "moan"        # human-readable; selector hint, not dispatch
  intensity: 0.35
  duration_class: long          # short<300ms, mid<1s, long<3s, sustained
  emotion_corner: ["aroused", "pleasure"]
  arc_phase: ["build", "plateau"]   # which episode-arc phase(s) this fits
  is_ingressive_companion: false
  vocal_effort: 0.25
quality:
  loudness_lufs: -19.5
  peak_db: -3.2
  noise_floor: -52
```

### Eight-axis tagging IS NOT optional for v1

The tagging schema above is not a v2 feature. It's the v1 schema because:

- Sample selection at runtime queries the production-axis space directly. No category-name dispatch.
- When a procedural module replaces samples for a region in v1.x, downstream consumers (motor channel, mixer, Visage) keep working without changes because the production-axis space is shared.
- Without it, future migration requires re-tagging the entire corpus. That's an unrecoverable authoring debt.

This is the load-bearing decision that buys the migration story. It also means corpus prep (A2 in the 2026-05-08 proposal) takes longer than the proposal's "1–2 weeks" — realistically 4–8 weeks for ~200–300 samples + ~8–12 breath-bed loops, all 8-axis tagged with baked sidecar curves.

### Breath-bed loop library

Continuous voicing layer (always-on under-bed of soft breath / partial voicing) is handled in v1 by a small library of looping samples keyed to emotion-state corners. The 2026-05-08 proposal's "always-on continuous tone that morphs with arousal" via runtime synth is delivered in v1 as:

- ~10 breath-bed loops, mono, ~3-5s each, keyed to corners of `(arousal, valence, breathiness)` grid.
- Crossfade between loops as state moves between corners.
- Per-active-loop SoundTouch modulation (pitch shift with arousal; formant shift with vocal effort; amplitude envelope with breath_depth).

Net: continuous morph within a finite-state-corner-grid plus narrow-band per-corner modulation. Not as smooth as procedural would be, but plausible for v1.

### Production-axis gaps from research that affect v1 sample tagging

Per research §10's gap list, these axes the sample bank must tag for and support — even though procedural is deferred:

- **Ingressive flag** — already covered above. v1 mandatory.
- **Aryepiglottic (AES) constriction level** — sample bank includes belt / scream / pain-cry samples explicitly tagged with high AES; bright (2-4 kHz) variants of moans / cries.
- **Velum / nasal coupling** — closed-mouth moans, whimpers, snorts, sniffs, hums tagged with velum-open level.
- **Glottal posture (breathy ↔ modal ↔ pressed)** — independent of category. Sample bank for high-arousal regions includes breathy and pressed variants of the same content (the pleasure / pain disambiguator).
- **Mechanism (M0 / M1 / M2 / M3)** — sample bank distinguishes vocal-fry / modal / falsetto / whistle samples; transitions between are events, dispatched by the scheduler.
- **Ventricular engagement** — some samples in the corpus need ventricular co-oscillation (growl, biphonation type II). Sourced from existing literature recordings or specialist VO performers; this is corpus-curation work.
- **Subglottal-pressure ballistic perturbations** — not sample-tagged; these are produced naturally in laugh / sob / hiccup samples by the performer's diaphragm. Tagging captures "is this a ballistic-perturbation sample" so the scheduler picks them for laugh / sob events.

Items the sample path in v1 cannot reproduce honestly without procedural augmentation, flagged for stretch-goal coverage:

- **Frequency jumps as discrete events** (M1↔M2, octave breaks at climax). v1 covers via "yodel / break" sample variants but the transition is not parameterically smooth.
- **Biphonation type II** (true-fold + ventricular as independent oscillators). v1 covers via curated growl / cry samples; runtime parameterization of co-oscillation rate is procedural-only.
- **Continuous register-mechanism morph.** v1 is sample-discrete by mechanism; smooth morph between M1 and M2 within one continuous note is a procedural capability.

These three are honest limits of the sample path. They define the regions where procedural would graduate first if it pans out (after breath, which graduates first because it's the simplest).

---

## Phase plan

### Sonance phase plan

Gated on Reverie interface contract real + TT Phase 6 stimulus bus shipping + 4Q wedge stability closing. Don't start runtime work before that.

Parallel preparation work (does not block anything, can run now):

- **A1** — soundgen offline parameter discovery for stretch-goal R&D. Mirror Anikin's reference set (cogsci.se/soundgen/humans/humans.html), run scripts under current soundgen (2.9.0), curate which parameter sets map to which Reverie-state corners. Output: parameter library JSON in Sonance schema. Prioritize for breath-region coverage (the first procedural target).
- **A2** — voice sample corpus prep + 8-axis tagging + sidecar curve baking. ~200–300 discrete event samples + ~10 breath-bed loops. **The critical-path item.** 4–8 weeks. Decisions inside A2: VC pipeline yes/no (recommend no for v1 — burdensome infrastructure for marginal gain).
- **A3** — physics events for audio response. Identify which TT events Sonance's physics module subscribes to; specify event types in TT Phase 6 bus design.

Runtime phases (after gates open):

- **S1 — Audio thread infrastructure.** AudioStreamGenerator integration, SPSC ring buffers, mixer, biquad bank, motor state struct, phonation gate. Deliverable: audio thread runs with no audio sources registered. Acceptance: zero glitches over 60s with no input.
- **S2 — Sample module (production path).** Sample bank with 8-axis tag index, sample scheduler respecting respiratory FSM, breath-bed player, SoundTouch modulator integration, sidecar-curve playback into motor channel. Acceptance: full repertoire from corpus reads correctly; respiratory phase synchronization plausible; lip sync via sidecar curves works in Visage.
- **S3 — Episode arc + state mapper.** Reverie state vector → 8 production axes mapper, SexualEncounterArc + GeneralArousalArc templates, arc-driven slow modulators feeding sample selection and modulation. Acceptance: orgasm arc renders through samples; arc phase visible in debug overlay.
- **S4 — Physics module.** Modal contact + Dahl friction + Minnaert bubble + reed-tube. Subscribes to TT Phase 6 bus events. Acceptance: tentacle impacts produce modal hits; friction events produce squeaks/rubs; bubble events produce bloops.
- **S5 — Procedural breath module (stretch — first graduation candidate).** Parametric breath synthesis covering pant / sigh / controlled exhale / silent breath-hold motor / sniff. Registers for the breath-dominated state-space subregion with quality_score that exceeds sample only after acceptance. Acceptance: blind A/B vs sample-corner crossfade in the breath region — listener can't reliably distinguish or prefers procedural. If acceptance fails: the module exists but doesn't graduate; sample path stays.
- **S6+ — Additional procedural modules** (if S5 graduates and authoring effort is justified). Gasp, moan, scream, laugh, etc. — each independently scoped and acceptance-gated.

### Visage phase plan

Gated on the same things plus Sonance S1+S2 (Visage needs the motor channel to read).

- **V1 — Eye gaze + eye node hierarchy.** Look-at IK to attention target. Eye Node3D as `BoneAttachment3D` children. Pupil dilation shape key. Saccade micro-motion writing eye shader's `iris_offset` uniform. Acceptance: eyes track moving target; saccade noise on attention shifts.
- **V2 — Eyelid blendshapes + brow/cheek/nose emotional layer.** ARKit 52 set; emotional state → blendshape weights. Acceptance: emotional state visibly drives non-mouth face.
- **V3 — Lip sync via Sonance motor channel.** F1/F2 → viseme blendshape weights; jaw_open → Marionette IK composer client; lip rest-position offsets → TentacleTech rim author. Acceptance: lip sync plausible during voiced events; closed-mouth smile during soft moan reads correctly.
- **V4 — Shader parameter writes.** Flush, sweat, tear track, SSS warmth, goosebumps from emotional state. Acceptance: skin reflects emotional state.
- **V5 — Tongue blendshapes + posture pattern library.** Tongue blendshapes for default tongue rig; posture pattern resources for eye-gaze / micro-tremor stacks. Acceptance: posture patterns blend.

---

## What this update supersedes

Explicit retirements from prior canonical docs and updates:

| What retires | Where it was specified | What replaces it |
|---|---|---|
| TT §9.1 `ProceduralContactSynth` (4 voices: slip-friction, squelch, stretch, fluid film) | `TentacleTech_Architecture.md` §9.1 | Sonance physics module (modal + Dahl + Minnaert + reed-tube) |
| TT §11 audio src/ + gdscript additions | `TentacleTech_Architecture.md` §11 | Move to `extensions/sonance/src/audio_thread/` and similar |
| TT §13 Phase 6 item 22a (`ProceduralContactSynth` + `ProceduralContactSynthProfile`) | `TentacleTech_Architecture.md` §13 Phase 6 | Sonance S4 phase |
| Reverie §4.1 (facial blendshape dictionary at ~20 Hz) | `Reverie_Planning.md` §4.1 | Visage emotional-layer + viseme-layer |
| Reverie §4.3 Layer 1 (one-shot lines from sample bank) | `Reverie_Planning.md` §4.3 | Sonance sample module; selection logic stays in Reverie as queue requests, playback moves to Sonance |
| Reverie §4.3 Layer 2 (sustained vocal synthesis) | `Reverie_Planning.md` §4.3 | Sonance procedural breath module (S5, stretch) plus, if it graduates, additional procedural modules per region |
| Reverie §9 Phase R5 + R5.5 (vocalization queue + sustained synth) | `Reverie_Planning.md` §9 | Reverie publishes vocal-intent events + dimensional state on the bus; production lives entirely in Sonance |
| `Cosmic_Bliss_Update_2026-05-07_*` audio sections | that update doc | This update; soft-region work in the same prior update is unaffected |
| `Cosmic_Bliss_Update_2026-05-08_sonance_visage` (the prior proposal) | (untracked, conversation-only) | This update adopts the proposal with the de-risking modifications |

The 2026-05-07 BodySurfaceField update + soft-region work are independent and unaffected.

---

## Open decisions — defaults committed; redline if any are wrong

I committed to defaults for the six open decisions from the 2026-05-08 evaluation. Any of these can be reversed without restructuring:

1. **State-vector channels.** 11-channel proposal as drafted (arousal, valence, effort, breathiness, pain_index, pleasure_index, social_visibility, body_size_signal, body_rhythm_phase, breath_target_rate, vocal_intent_event). Pain and pleasure as separate channels rather than collapsed into valence — the research is explicit about ambiguity at high arousal, breathiness disambiguating.
2. **Sample tagging schema scope.** Eight production axes adopted as v1 mandatory. Buys the migration story; costs the corpus-prep effort.
3. **Episode arc instantiation in v1.** SexualEncounterArc + GeneralArousalArc only. SobSpellArc / LaughFitArc / CryBoutArc deferred until needed.
4. **Procedural breath module v1 scope.** Pant / sigh / controlled exhale / silent breath-hold motor / sniff. Snort deferred to v1.1 (nasal turbulence + velum control is more complex).
5. **Reverie facial blendshape ownership.** Retires entirely from Reverie. Visage owns blendshape authoring; Reverie writes emotional state. Reverie §4.1 retires.
6. **Composition rule for shared structures.** Channel-segmented for blendshapes; additive-with-weights for jaw and lip-ring offsets, with Sonance's weight scaling by `vocal_effort`. Committed as v1 default rather than deferred.

Additional decisions implicit in this draft:

7. **License posture for time-stretch / pitch-shift.** SoundTouch (LGPL) default. Rubber Band Pro (commercial license) is the upgrade path if SoundTouch quality is insufficient in playtesting.
8. **VC pipeline for sample corpus.** Default no for v1. Defer until playtesting reveals timbre-consistency problems.
9. **Procedural-graduation criterion.** Blind A/B against sample-corner crossfade in the same region; the procedural module graduates when listeners can't reliably distinguish (or prefer it). The bar is "listener doesn't notice the change" rather than "objectively better than samples."
10. **Sonance / Visage extension boundary.** Two extensions, not one. Voice + face have different thread models (audio thread vs frame-rate), different DSP needs, different authoring tooling. Merged-extension argument loses to the cleaner thread / lifecycle boundaries.
11. **Tongue ownership.** Visage owns tongue blendshapes by default. If the rig grows tongue bones later, those route through Marionette as additional bone targets (consistent with jaw).

---

## Caveats

- **Sample corpus is the critical path.** A2 is realistically 4–8 weeks of focused authoring + per-sample analyzer pass extracting motor-state sidecar curves. The "we'll just record some moans" framing is wrong; this is corpus-engineering work with an 8-axis tagging schema.
- **Procedural may never graduate.** That's fine. v1 ships without it; v1.x graduates per region as quality permits; the architecture costs nothing if the procedural side never lands.
- **The eight-axis sample-tagging schema is the load-bearing migration insurance.** If the corpus is tagged on emotion-only, the migration story collapses. Don't shortcut this.
- **Motor-vs-phonation factoring is the load-bearing path-agnosticism insurance.** If motor state and audio output are coupled in any module, silent vocalization breaks and Visage's lip sync depends on the audio path. Don't shortcut this.
- **Event-type categories survive as labels, not as dispatch.** Sample tags include `category_label` for human-readable curation; `EventTag` is a hint for the path selector. The runtime never branches on category.
- **Heat-method-style prefactored solves don't apply here.** Mentioned for completeness — Sonance's algorithms are time-domain DSP, not Laplacian-on-mesh. The prefactored-solve architectural pattern that the BodySurfaceField update commits to is unrelated.
- **Cross-cultural universality of vocalization is partial, not absolute.** Per research caveats: arousal and valence are universal; specific emotion categories are partly cultural. Profile resources (`vocal_profile.gd` per character) bias the state-mapping for character / cultural variation; the production-axis machinery is universal.
- **Spontaneous vs volitional dual-system finding.** Build (eventually) a `volitional_overlay` flag in vocal events — controls whether the sample / procedural module picks from the more-NLP-rich, more-F0-variable, shorter-burst spontaneous distribution or the more-rhythmic, more-vowel-stable, more-speech-like volitional distribution. Bryant 2018 supports this as universal across 21 societies. Not v1 mandatory; add when the corpus has both distributions tagged.

---

## What this updates in the canonical docs (pending-amendment notes added now; full edits land per phase)

Pending-amendment notes added 2026-05-09 to:

- `docs/architecture/TentacleTech_Architecture.md` §9 / §9.1 — points to this update as the supersession; §9 retains general "physics-driven sound is in TentacleTech's scope" framing (because it lives in the bus + Sonance subscribes), but §9.1's specific `ProceduralContactSynth` spec retires.
- `docs/architecture/TentacleTech_Architecture.md` §11 — audio src/ structure retires.
- `docs/architecture/TentacleTech_Architecture.md` §13 Phase 6 item 22a — retires; Sonance S4 phase replaces.
- `docs/architecture/Reverie_Planning.md` §4.1 — retires; Visage emotional-layer + viseme-layer.
- `docs/architecture/Reverie_Planning.md` §4.3 — retires Layer 1 + Layer 2; replaces with "Reverie publishes vocal-intent events + dimensional state, Sonance produces."
- `docs/architecture/Reverie_Planning.md` §9 Phase R5 + R5.5 — retires.
- `CLAUDE.md` — extension count goes from four to six; Sonance + Visage rows added.

Canonical specs land in:

- `docs/sonance/Sonance_Architecture.md` (does not exist yet; written when Sonance work opens).
- `docs/visage/Visage_Architecture.md` (does not exist yet; written when Visage work opens).

---

## Summary

Open Sonance and Visage as new extensions. Sonance ships sample-first with the full repertoire covered by a sample-bank-with-modulation path; procedural synthesis is a stretch-goal R&D track that graduates per-region (breath first) without blocking mainline. Migration works because the 8-axis sample tagging schema and motor-state-vs-phonation factoring make the production path internal-to-Sonance and invisible to Reverie, Visage, and TentacleTech. The sample path uses the temporal scaffold (respiratory FSM + episode arc + three-rhythm coupling + ingressive flag) that procedural would use too — these commitments are v1 mandatory, not stretch.

Visage is a peer author into Marionette's IK composer (jaw, posture) and TentacleTech's rim rest-offset system (lip ring), following the existing pattern. Eye gaze + eyelid blendshapes + emotional-layer blendshapes are Visage-owned directly. The eye shader (`docs/Eye_Shader.md`) handles rendering; Visage drives bone rotations + iris_offset uniform.

Both extensions are gated on Reverie's interface real + TT Phase 6 bus shipping + 4Q wedge stability closing. Parallel preparation work (sample corpus, soundgen offline R&D, physics event interface) does not block; recommend starting A2 (sample corpus + 8-axis tagging) now since it's the critical path and runs ~4–8 weeks.
