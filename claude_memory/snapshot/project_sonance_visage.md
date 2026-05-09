---
name: Sonance + Visage opened 2026-05-09 — sample-first voice with procedural-per-region migration
description: Two new GDExtensions for audio synthesis (Sonance) and face/eye/lipsync (Visage). Sample-first voice production; procedural is stretch goal that graduates per region. 8-axis sample tagging is migration insurance. Motor-state channel is path-agnostic.
type: project
originSessionId: ccaf24fd-acfe-4024-b9b6-7c19b411e9a1
---
**Decision 2026-05-09:** opened Sonance (audio synthesis) and Visage (face) as new GDExtensions. Brief at `docs/Cosmic_Bliss_Update_2026-05-09_sonance_visage.md`. Extension count goes from four to six.

**The de-risking commitment.** Procedural non-verbal vocalization is treated as a stretch goal, not a v1 feature. Voice production ships sample-first via sample-bank-with-modulation (SoundTouch LGPL for pitch/formant/time-stretch + breath-bed-loop library for continuous voicing). Procedural modules register per-region via a `production_module` plugin interface; they graduate when blind-A/B against sample-corner crossfade in the same region shows listeners can't reliably distinguish (or prefer procedural). Breath is the first procedural-graduation candidate per research §10. If procedural never pans out, mainline ships unaffected.

**The two load-bearing migration commitments that ARE v1 mandatory:**

1. **8-axis sample tagging schema** matches the production axes that procedural modules emit. Without it, future procedural migration would require re-tagging the entire corpus. The eight axes are airstream, mechanism (M0-M3 + ventricular), glottal posture (breathy↔modal↔pressed), ventricular engagement, AES (aryepiglottic constriction), tract config, respiratory pattern, body coupling. Per Roubeau/Henrich/Castellengo 2009, Esling 1999/2005, Anikin 2019, Massenet et al. 2025.
2. **Motor-state channel is path-agnostic.** `MotorStateOut` (jaw, lip, tongue, velum, AES, larynx, breath_phase, subglottal_pressure) published every cycle by whichever module renders, decoupled from `PhonationGate`. Visage subscribes regardless of which path produced the audio. Silent vocalization (held breath, silent sob, silent scream) is rendered by motor state with phonation = 0.

**Reverie ↔ Sonance interface is dimensional only.** Reverie does not know about production paths or vocalization types. Reverie writes 11 channels (arousal, valence, effort, breathiness, pain_index, pleasure_index, social_visibility, body_size_signal, body_rhythm_phase, breath_target_rate, vocal_intent_event). `pain_index` and `pleasure_index` are separate channels (not collapsed into valence) because Anikin 2020 *Phonetica* shows the same NLP regime reads as pain or pleasure depending on breathiness; collapsing the channels blurs vocal output at high arousal. Vocal events have dimensional payload + optional category tag as hint, not as dispatch.

**Vocalization "types" are graded, not categorical.** Per Anikin/Bååth/Persson 2018, named call categories (moan, scream, groan, etc.) form a single graded continuum organized by pitch and noisiness. Runtime routes by 8-axis state-space position, not by enum case. Categories survive as human-readable tag metadata + selector hints.

**Visage authors targets to physics — never moves physical things directly.** Jaw bone is Marionette's; both Sonance and Visage write jaw targets to the IK composer. Lip ring is TentacleTech's; both write per-particle rest-position offsets. PBD/SPD arbitrate. This is the existing IK-composer pattern with two new clients.

**Composition rule (committed v1 default):** channel-segmented for blendshapes (Sonance owns mouth-shape during voiced events; Visage owns brow/cheek/nose); additive-with-weights for jaw and lip-ring offsets, with Sonance's weight scaling by `vocal_effort` so loud vocalizations dominate quiet expressions but a closed-mouth smile reads during a soft moan.

**Eye shader (`docs/Eye_Shader.md`) handles rendering; Visage handles animation.** Visage drives bone rotations + eyelid blendshapes + pupil dilation shape key + saccade micro-motion writing the shader's `iris_offset` uniform. Eye Node3D children of head's `BoneAttachment3D` is Visage-owned scene structure.

**Temporal scaffold is v1 mandatory** (sample path uses it too): respiratory FSM at top (inhale/hold/exhale phases dispatch sample selection); episode arc as parametric template (SexualEncounterArc + GeneralArousalArc in v1; sob/laugh/cry arcs deferred); three independent rhythm clocks (respiratory, body-coupled, glottal). Without this, sample sequences drift out of phase with body rhythm and lose plausibility.

**Pending-amendment notes added to:** `TentacleTech_Architecture.md` §9 (procedural sound moves to Sonance), `Reverie_Planning.md` §4.1 (facial blendshape dictionary retires; Visage takes over), §4.3 (vocalization Layer 1+2 retire; Sonance takes over), §9 (R3, R4, R5, R5.5 retire), `CLAUDE.md` (extension count from four to six).

**License posture:** SoundTouch (LGPL) for pitch/formant/time-stretch in v1. Rubber Band Pro (commercial license) is the upgrade path if SoundTouch quality is insufficient in playtesting.

**Critical-path item:** sample corpus prep + 8-axis tagging + sidecar motor-state curve baking. ~200–300 discrete samples + ~10 breath-bed loops. Realistically 4–8 weeks. Recommend starting now since it doesn't block on TT 4Q / Phase 6.

**Gating:** runtime work blocked on Reverie interface contract real + TT Phase 6 stimulus bus shipping + 4Q wedge stability closing.

**What this supersedes:** TT §9.1 ProceduralContactSynth, TT §11 audio src/, TT Phase 6 item 22a, Reverie §4.1 + §4.3 + Phase R5/R5.5, the audio sections of `Cosmic_Bliss_Update_2026-05-07_procedural_audio_and_soft_regions.md`. Soft-region work in that earlier update is independent and unaffected.
