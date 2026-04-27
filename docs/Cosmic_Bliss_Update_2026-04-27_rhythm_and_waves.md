# Cosmic Bliss — Design Update 2026-04-27 — Body Rhythm, Wave Motion, Tentacle Sync

**Audience: Repo organizer Claude (Claude Code session).**

This brief captures four architectural decisions made in a design session and tells you where each one lands in the canonical docs. Read the existing docs first, match their voice, don't expand scope beyond what's here.

---

## Project conventions you must honor

These are the same conventions the project owner (Caetano) follows. If you find yourself violating any of these, stop and reread.

- **GDScript by default.** C++ (GDExtension) only for math-heavy inner loops, physics-tick work, low-level RenderingDevice. Compile/edit cost is real.
- **Godot 4.6** specifically. godot-cpp pinned to 4.6 branch.
- Never propose: per-frame `ArrayMesh` rebuilds, per-frame `ShaderMaterial` allocation, `MultiMesh` for deforming meshes, `SoftBody3D` for any core system, SSBOs in spatial shaders (use `RGBA32F` data textures).
- **Don't generate Godot test scenes.** Caetano creates those himself. Reference them in milestones if needed (e.g. "video artifact in `docs/videos/...`") but don't author the `.tscn`.
- **No padding.** Match the declarative voice of the existing canonical docs. Don't restate context that's already in the doc you're editing.
- **Numbers are starting points.** Particle counts, ring bone counts, oscillator amplitudes, periods — flag tunables as such, don't carve them in stone.
- **Don't renumber existing phases.** Insert new sub-phases (P7.9, etc.).
- **One concern per change.** Don't conflate decisions; if a decision touches three docs, write three localized patches, not one sprawling one.

Canonical docs (at repo root):
- `TentacleTech_Architecture.md`
- `TentacleTech_Scenarios.md`
- `Marionette_plan.md`
- `Reverie_Planning.md`
- `Tenticles_design.md`

---

## What's being added

Five changes across three docs. Read all five before editing — they reference each other.

| # | Change                                              | Doc                              |
|---|-----------------------------------------------------|----------------------------------|
| 1 | `PropagationGraph` baked alongside `BoneProfile`    | `Marionette_plan.md` (Phase 2)   |
| 2 | `TravelingWaveCyclic` resource + evaluator          | `Marionette_plan.md` (new P7.9)  |
| 3 | Phase-relationship authoring UI for coupled cyclics | `Marionette_plan.md` (P7.7 amend)|
| 4 | `body_rhythm_phase` shared clock on `Marionette`    | `Marionette_plan.md` (new P7.10) |
| 5 | `RhythmSyncedProbe` modifier on `DPGPenetrator`     | `TentacleTech_Architecture.md`   |
| 6 | Reverie writes `body_rhythm_frequency`              | `Reverie_Planning.md`            |

---

## 1 — `PropagationGraph` (Marionette Phase 2 amendment)

**Concept.** A skeleton-static graph that assigns each bone a scalar position `s` along a propagation path plus per-bone anatomical axis weights. Used by `TravelingWaveCyclic` (change 2) and any future system that needs to talk about "position along the body" as a continuous coordinate. Authoring-time only; runtime reads baked values.

**Schema (resource, GDScript):**

```
PropagationGraph (Resource):
  trunk_path: Array[StringName]      # base→tip, e.g. [Hips, Spine, Spine1, Chest, Neck, Head]
  branches: Array[Branch]            # see below
  # Baked at authoring time:
  bone_s: Dictionary[StringName, float]            # arc length from trunk root
  bone_axis_weights: Dictionary[StringName, Vector3]  # (flex, rot, abd) weights per bone
  s_max: float                       # used for amplitude_curve normalization

Branch:
  attach_bone: StringName            # bone on trunk where this branch starts
  chain: Array[StringName]           # ordered, attach→tip
  s_offset_from_trunk: float         # MUST equal bone_s[attach_bone] at bake time
```

**Bake step (authoring).** Walk `trunk_path` accumulating rest-pose bone lengths into `bone_s`. For each branch, set `s_offset_from_trunk` to the trunk's `s` at `attach_bone`, then continue accumulating along `chain`. `bone_axis_weights` come from a per-region default (trunk = (1,0,0) flex; arms = (0.5,0,1) abd-leaning; legs = (1,0,0) flex) with per-bone overrides allowed in the inspector. None of this happens at runtime.

**Pitfall to flag in the doc.** If `s_offset_from_trunk` is zero (i.e. each branch starts its own coordinate from zero), waves passing through the body look like four separate limb wiggles instead of a single coherent disturbance. The bake step must inherit from the trunk.

**Where in `Marionette_plan.md`.** Phase 2 is "Muscle frame, archetype resolver, BoneProfile generation." Add a new task in that phase (e.g. `P2.13` or wherever sequencing makes sense) for `PropagationGraph` resource definition and authoring-time bake. Add a milestone bullet: "PropagationGraph baked from `MarionetteHumanoidProfile`: trunk + 4 limb branches, branch `s_offset_from_trunk` matches trunk `s` at attach point, total path length sane (1.5–2m typical for human-scale)."

---

## 2 — `TravelingWaveCyclic` (Marionette new sub-phase P7.9)

**Concept.** A cyclic resource that produces body-wide coherent motion by parameterizing oscillation by bone position along a `PropagationGraph`. Same composition pipeline as `RagdollCyclicAnimation` (additive in anatomical space, ROM-clamped at the end). One sample per bone per active wave per tick.

**Why it exists.** Per-joint independent noise looks dead — that's the failure mode. Sharing phase between neighboring bones via `(s, t)` parameterization makes motion look like a living thing. Coherent noise is the same evaluator with a different spatial sampler.

**Schema:**

```
TravelingWaveCyclic (Resource):
  graph: PropagationGraph
  spatial_function: enum { Sine, Triangle, Noise2D, Curve }
  custom_curve: Curve              # used when spatial_function == Curve
  wavenumber: float                # cycles per meter along path
  temporal_frequency: float        # Hz; wave speed = temporal_frequency / wavenumber
  amplitude_curve: Curve           # input: s_normalized in [0,1], output: amplitude (rad)
  blend_mode: enum { Additive, Override, Multiplicative }   # Additive default
```

**Per-tick evaluator (pseudocode):**

```
for bone_name in graph.bone_s:
    s = graph.bone_s[bone_name]
    s_norm = s / graph.s_max
    phase = TAU * (wavenumber * s - temporal_frequency * t)
    value = sample(spatial_function, phase) * amplitude_curve.sample_baked(s_norm)
    target[bone_name] += value * graph.bone_axis_weights[bone_name]
```

For `spatial_function == Noise2D`: replace `sample(...)` with `noise2D(s * wavenumber, t * temporal_frequency)`. Bones close in `s` get correlated values — organic squirming, not jitter.

**Composition.** Drops into the Phase 8 anatomical-additive pipeline alongside `RagdollCyclicAnimation`. ROM clamp at the end handles overshoot. Multiple waves coexist additively.

**Don't merge with `BoneOscillator`.** `BoneOscillator` is for genuinely-per-bone phenomena (Parkinsonian hand tremor, jaw chatter). `TravelingWaveCyclic` is for body-wide propagating disturbances. Same composition pipeline, different authoring intent — keep them separate resources.

**Pitfalls to flag in the doc.**
- Author `amplitude_curve` to fit within ROM at peak. The pipeline will clamp, but clamping looks bad if it happens mid-oscillation.
- Wave speed = `temporal_frequency / wavenumber`. Authors will reach for "I want a wave at 1 m/s" — mention that they get speed by ratio, not directly.

**Where in `Marionette_plan.md`.** Phase 7 is "Cyclic motion resources." Add a new sub-phase **P7.9** with tasks `P7.9.1` (resource definition), `P7.9.2` (evaluator integrated into Phase 7 cyclic evaluator), `P7.9.3` (sample preset: a slow spinal undulation, `spinal_undulation.tres`, period ~3s, wavenumber such that one full wavelength = total trunk length, amplitude ~5° flexion), `P7.9.4` (sample preset: `coherent_squirm.tres`, Noise2D spatial function). Milestone: visible difference between independent-noise (manual hack for comparison) and coherent-noise versions; recorded video.

---

## 3 — Phase-relationship authoring UI (Marionette P7.7 amendment)

**Concept.** Local coupled-phase oscillations (hip rocking, breathing-with-torso-twist) are authored as multiple `BoneOscillator`s with carefully-chosen phase offsets. Authoring against two raw `phase_offset` numbers is hard; authoring against a 2D Lissajous shape is easy.

**What to add to `P7.7` (cyclic authoring UI):**
- A 2D phase-relationship preview widget: pick two oscillators (any two — same bone different axes, or different bones same axis), see their (value_A, value_B) plotted over one period as a Lissajous curve.
- A Lissajous-shape authoring mode: drag a shape (circle → ellipse → figure-8 → diagonal line) and have it set the phase offset and frequency multiplier of the second oscillator relative to the first.
- 1:1 frequency ratio with 90° phase offset = ellipse. 2:1 ratio = figure-8. 1:1 ratio with 0° phase = diagonal line.

**Ship a preset to demonstrate.** `hip_invite.tres` (`RagdollCyclicAnimation`, period 2.5s, tunable):

```
oscillators:
  # Pelvic ellipse — coupled axes at 90°
  - bone: Hips,  axis: Rotation,  amp: 10°, freq_mult: 1, phase: 0
  - bone: Hips,  axis: Abduction, amp:  6°, freq_mult: 1, phase: π/2
  # Anterior/posterior tilt
  - bone: Hips,  axis: Flexion,   amp:  8°, freq_mult: 1, phase: π/4
  # Counter-motion in chest, smaller, phase-flipped
  - bone: Chest, axis: Rotation,  amp:  4°, freq_mult: 1, phase: π
  - bone: Chest, axis: Abduction, amp:  2°, freq_mult: 1, phase: π + π/2
  # Alternating knee bob
  - bone: LeftKnee,  axis: Flexion, amp: 3°, freq_mult: 1, phase: 0
  - bone: RightKnee, axis: Flexion, amp: 3°, freq_mult: 1, phase: π
```

Arms deliberately absent — they pick up incidental motion from the chest and stay under control of whatever `EmotionalBodyState` is active. All amplitudes are starting points; tune against context (a `tense` state would halve them).

**Where in `Marionette_plan.md`.** Inside the existing P7.7 task list, add the Lissajous widget + preview. Add `hip_invite.tres` to the preset library task in P7.8. Update the P7 milestone with: "`hip_invite.tres` produces a clean elliptical hip motion with synchronized chest counter-rotation; switching one pelvic axis from `freq_mult: 1` to `freq_mult: 2` in the authoring panel produces a figure-8 in real time."

---

## 4 — `body_rhythm_phase` shared clock (Marionette new sub-phase P7.10)

**Concept.** A single phase variable on `Marionette` that all cyclic evaluation reads as its time argument. Lets external systems (TentacleTech, Reverie) sync to the body's internal rhythm without each one running its own clock.

**API on `Marionette`:**

```
@export var body_rhythm_frequency: float = 0.4    # Hz, settable by Reverie
var body_rhythm_phase: float = 0.0                 # 0..TAU, advances every physics tick
signal body_rhythm_cycle_completed(cycle_index: int)
```

**Per-tick (in `_physics_process` or wherever the cyclic evaluator runs):**

```
body_rhythm_phase += body_rhythm_frequency * TAU * delta
if body_rhythm_phase >= TAU:
    body_rhythm_phase = fmod(body_rhythm_phase, TAU)
    cycle_index += 1
    body_rhythm_cycle_completed.emit(cycle_index)
```

**Cyclic evaluator change.** All `BoneOscillator` and `TravelingWaveCyclic` evaluation now reads `body_rhythm_phase` as the time argument, scaled by the resource's own `freq_mult` (oscillator) or `temporal_frequency` (wave) **relative to** `body_rhythm_frequency`. In effect, the resource specifies its frequency *as a multiple of the body's rhythm*, not in absolute Hz. This is the right semantics — you want the hip ellipse and the spinal undulation to slow down together when arousal drops, not drift apart.

**Pitfall to flag in the doc.** `body_rhythm_phase` must be **integrated** (`phase += freq * dt`), not recomputed (`phase = freq * t`). Otherwise a frequency change snaps the phase, which is visible in both the body and in any tentacle locked to it. Mandatory.

**Where in `Marionette_plan.md`.** New sub-phase **P7.10** at the end of Phase 7. Tasks: `P7.10.1` add fields/signal to `Marionette`, `P7.10.2` integrate phase per physics tick, `P7.10.3` migrate `BoneOscillator` and `TravelingWaveCyclic` evaluators to read `body_rhythm_phase`, `P7.10.4` resource fields renamed/repurposed (oscillator `frequency_multiplier` is now relative to `body_rhythm_frequency`; document migration). Milestone: changing `body_rhythm_frequency` from 0.4 to 1.6 over 0.5s produces a smooth speed-up of `hip_invite.tres` with no visible phase snap.

---

## 5 — `RhythmSyncedProbe` modifier (TentacleTech_Architecture.md)

**Concept.** A new modifier in the `DPGPenetrator` modifier system (siblings: ovipositor, grip, grapple). Reads `marionette.body_rhythm_phase` and drives the existing driven-insertion component (the active half of self-insertion, already specified) at a configurable phase offset.

**Schema:**

```
RhythmSyncedProbe (Node, child of DPGPenetrator):
  marionette_path: NodePath        # reference to the synced Marionette
  phase_offset_rad: float = PI     # offset from marionette.body_rhythm_phase
  amplitude_along_spline: float    # how far the insertion drives, in spline arc length
  insertion_curve: Curve           # value over phase: shape of the drive cycle
```

**Per-tick:**

```
phase = fmod(marionette.body_rhythm_phase + phase_offset_rad, TAU)
drive = insertion_curve.sample_baked(phase / TAU) * amplitude_along_spline
driven_insertion_component.set_drive(drive)
```

**Two presets worth shipping.** `probe_pumping.tres` with `phase_offset_rad = PI` (tentacle thrusts forward when hips rock backward — pumping coordination), `probe_yielding.tres` with `phase_offset_rad = 0` (tentacle and hips advance together — body presses into the thrust). Both reference the same `insertion_curve` shape; only the offset differs.

**Where in `TentacleTech_Architecture.md`.** Find the modifier system section (modifiers as child nodes of `DPGPenetrator`, alongside ovipositor, grip, grapple). Add a new subsection for `RhythmSyncedProbe` with the schema, the per-tick formula, and a sentence on how it composes with the existing driven-insertion component. Cross-reference `Marionette_plan.md` P7.10 for the `body_rhythm_phase` API.

---

## 6 — Reverie writes `body_rhythm_frequency` (Reverie_Planning.md)

**Concept.** Closes the bidirectional coupling loop. Reverie's arousal axis (or whatever the relevant emotional output is — read the doc to confirm naming) maps to `body_rhythm_frequency` and writes it to `Marionette` each tick, or on emotional state changes. Ramp protection (phase continuity) lives in `Marionette` (change 4), not here — Reverie just sets the target frequency.

**The loop end-to-end:**
1. Reverie's arousal axis → writes `body_rhythm_frequency` on `Marionette`
2. Body produces hip + spinal motion at that frequency
3. `RhythmSyncedProbe` (TentacleTech) locks tentacle drive to the same clock, offset by π or 0
4. Tentacle contact stimulus → feeds Reverie → raises arousal → raises frequency → loop

**Where in `Reverie_Planning.md`.** Find the section on Reverie's outputs (what Reverie writes to other systems). Add `body_rhythm_frequency` as an output channel from arousal, with a brief description of the coupling loop. Don't over-specify the mapping curve — that's a Reverie internal tuning detail, just note that it exists. Cross-reference `Marionette_plan.md` P7.10.

---

## What you should NOT do

- Don't merge `TravelingWaveCyclic` and `BoneOscillator` into a single resource. They serve different authoring intents.
- Don't rename existing types or move existing sections. Insertions only.
- Don't add gameplay features. Encounter design / progression / objectives are deliberately deferred.
- Don't touch `Tenticles_design.md` or `TentacleTech_Scenarios.md` — these decisions don't affect them.
- Don't author `.tscn` files. If a milestone wants a test scene, name it but leave the scene to Caetano.
- Don't expand the modifier system in TentacleTech beyond `RhythmSyncedProbe`. The other modifiers (ovipositor, grip, grapple) are already documented; just add this one as a sibling.

## Working order

1. Read all five canonical docs first to understand current voice and section structure.
2. Apply changes 1 and 2 to `Marionette_plan.md` (PropagationGraph in Phase 2, TravelingWaveCyclic as P7.9). These are foundational.
3. Apply changes 3 and 4 to `Marionette_plan.md` (P7.7 amendment, P7.10 new). Order doesn't matter between them.
4. Apply change 5 to `TentacleTech_Architecture.md`.
5. Apply change 6 to `Reverie_Planning.md`.
6. Verify cross-references resolve (P7.10 referenced from TentacleTech and Reverie).

After landing the patches, summarize in chat what changed in each doc — short, one paragraph per doc. Caetano won't read the patches end-to-end.
