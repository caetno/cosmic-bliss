# Cosmic Bliss — Design Update 2026-05-07 — Procedural contact audio + soft-region clusters

> **Status: drafted 2026-05-07, applied 2026-05-07.** Two additive features:
> (1) procedural contact-audio synthesis for slimy/slippery sustained sound
> in TentacleTech (§9.1, Phase 6); (2) soft-region particle clusters for
> glute/thigh/breast tissue deformation under tentacle pressure in
> Marionette (post-jiggle deformation layer, gated on TentacleTech
> Phase 4.5). Phase 4.5 (XPBD warm-start cluster + Oriented Particles) is
> opened by this update because the soft-region clusters require it; it
> was previously a deliberately-unopened placeholder.

**Audience: top-level Claude (canonical record). Sub-Claude reads the
architecture / plan docs, not this one.**

---

## TL;DR

Two upgrades, both decided 2026-05-07 after a techniques-survey review:

1. **Procedural contact audio** — TentacleTech §9 grows a continuous-synthesis layer alongside its existing event-trigger sample bank. Slimy/slippery sustained contact sound is synthesized on the audio thread from continuous bus channels (`slip_velocity`, `friction_energy`, `lubricity`, `wetness_per_*`, `contact_pressure`) rather than sampled. Reverie §4.3 grows a sustained-vocal synthesis layer (formant + breath, driven by `body_rhythm_phase` + `breath_*_mult` + `body_strain`) that runs underneath the existing one-shot line bank for moans / breath / drawn-out gasps.

2. **Soft-region particle clusters** — Marionette's jiggle bones gain a deformation layer on top: a sparse particle lattice inside an authored volume primitive, shape-matched (Müller 2005) against a bone-driven rest pose, contacting tentacle particles via the existing PBD pass. The visible mesh is re-skinned per-vertex by a `cluster_blend ∈ [0, 1]` derived automatically from the volume's signed distance — *no per-vertex artist authoring at the boundary*. This is what unlocks "tentacle glides through inner thigh, deforming tissue" instead of pushing a rigid bone-with-spring out of the way.

Both upgrades were chosen against alternatives:

- **Audio:** chose continuous synthesis over expanding the sample bank because the physics already publishes the continuous channels procedural audio wants; expanding samples to cover the same variation is combinatorial.
- **Soft body:** chose particle clusters with shape-matching over tetrahedral XPBD because tet authoring is the canonical "fiddly artistic aspect" we need to avoid (user direction 2026-05-07). Reference architecture: Obi softbody — same primitives (overlapping-cluster shape matching + oriented particles + per-vertex skinning), same authoring shape (volume + numeric parameters).

---

## Why now

Both items came out of a techniques-survey review (2026-05-07) that mapped CG/physics/audio research candidates onto the existing roadmap. Two stood out as high-leverage and architecturally clean:

- Procedural audio synthesis (Farnell *Designing Sound*, friction-driven primitives) hooks directly into channels the bus already publishes. The integration is purely additive — no rework of physics, no new bus channels, no new authoring resources beyond a `ProceduralContactSynthProfile`. Slimy/slippery contact sound is impossible to do well with samples alone; the variability of `slip_velocity × lubricity × pressure` is continuous, and a sample-only path either loops audibly or requires combinatorial WAV authoring.
- Soft-region clusters require shared particle representation with TentacleTech. That representation is Phase 4.5 Oriented Particles (Müller & Chentanez 2011), which was already on the deferred-but-likely list and which several Phase 4 wedge fixes asymptotically point at. The two features together justify opening Phase 4.5 now rather than later.

---

## What changes (file by file)

### `docs/architecture/TentacleTech_Architecture.md`

- **§9 (Mechanical sound)** restructured into two layers: existing event-trigger sample bank (table unchanged) + new continuous-synthesis layer.
- **§9.1 (new)** — `ProceduralContactSynth` C++ component (custom `AudioStreamPlayback` subclass running on the audio thread at 48 kHz) with four voices:
  - Slip-friction noise (driven by `slip_velocity`, `lubricity`, `contact_pressure`)
  - Squelch bed (filtered noise + amplitude jitter; driven by wetness, contact-pressure rate)
  - Stretch tone (resonant filter; driven by ring or canal radial-strain rate)
  - Fluid film (granular noise; driven by wetness channels)

  Each voice is presence-gated on a smoothstep of its driving channel — below threshold the voice idles to zero amplitude, no DSP cost. No new physics state; consumes existing bus channels only.
- **§11 (file structure)** gains `extensions/tentacletech/src/audio/` with `procedural_contact_synth.{h,cpp}` + four voice files; `gdscript/stimulus/procedural_contact_synth_profile.gd`.
- **§13 (phase plan)** gains **Phase 4.5** (XPBD warm-start cluster + Oriented Particles), opened explicitly:
  - **4.5.A** body-local persistent contacts (extends 4S brief), `MAX_CONTACTS_PER_PARTICLE = 3`
  - **4.5.B** λ warm-start across ticks, gated on contact identity persistence
  - **4.5.C** Oriented Particles — per-particle quat + ω on `TentacleParticle`; replaces RMF parallel transport for feature-frame accuracy under host-bone roll. Architectural prerequisite for Marionette §16.
- **§13 Phase 6** acceptance updated — slimy/slippery contact must modulate continuously with `slip_velocity` and `lubricity` (no audible looping or rate-discretization).

### `docs/architecture/Reverie_Planning.md`

- **§4.3 (Vocalization)** restructured into two layers:
  - **Layer 1** unchanged — one-shot lines from a sample bank, selected by events + state + mindset + cooldown.
  - **Layer 2 (new)** — sustained vocal synthesis (formant filter bank + breath generator + glottal envelope), driven by `body_rhythm_phase` + `breath_rate_mult` + `breath_depth_mult` + `body_strain` + state distribution + mindset. No new bus channels; consumes existing reads/writes. Mixed alongside line samples through the same `AudioStreamPlayer3D`.
- Layer 1 ships in Reverie Phase 1; Layer 2 follows TentacleTech Phase 6 (shared audio-thread infrastructure).

### `docs/marionette/Marionette_plan.md`

- New section **"Soft-region particle clusters (post-jiggle deformation layer)"** added after the existing jiggle-bone section. Six numbered slices (§16.1–§16.6) plus an explicit deferred follow-on (§16.7 overlapping subclusters). Authoring contract is exactly three things per region:
  1. host bone (`NodePath`)
  2. volume primitive (`Sphere | Capsule | Ellipsoid` with extents, gizmo-edited)
  3. handful of numeric `@export` parameters on `SoftRegionProfile`

  Everything else (particle lattice, rest configuration, per-vertex blend / indices / weights, AABB) is baked automatically by `SoftRegionBaker`.
- Visual mesh deformation uses a `cluster_blend ∈ [0, 1]` per vertex, derived automatically from the volume's signed distance (smoothstep across `boundary_blend_radius`). Vertices outside the volume stay pure-LBS; vertices inside follow LBS + cluster offset; the boundary band is a smooth interpolation. **The artist never paints the boundary.**
- Cluster particles use the Phase 4.5 `ClusterParticle` representation (shared with tentacle particles) and contact tentacle particles in the same PBD pass. Phase placement explicitly gated on TentacleTech Phase 4.5 landing.

---

## What was rejected

- **Tetrahedral XPBD + neo-Hookean (Macklin & Müller 2021).** Higher fidelity, but tet authoring is the canonical fiddly artistic aspect we need to avoid. Volume primitive + auto-baked particle lattice produces sufficient deformation for the body regions in scope (rounded soft tissue, no internal hard structure).
- **Modal sound synthesis (O'Brien / James et al.).** Excellent for solid impacts (bone hits, hard objects), wrong fit for wet contact texture which is what the user wants to address. Sample-bank impacts are the right grain for those events; modal would be Phase 9+ if at all.
- **Expanding the sample bank to cover slimy/slippery variation.** Combinatorial authoring cost; can't match continuous channel variation; sample-loop artifacts at long contact durations.
- **`SoftBody3D` for soft regions.** Still forbidden per repo convention.
- **Bidirectional cluster ↔ ragdoll force feedback this phase.** The jiggle bone is the only ragdoll-side handle; cluster lives entirely in the PBD layer this phase. Future scenarios needing ragdoll torque feedback from cluster deformation are a separate phase.

---

## Authoring constraint (load-bearing user direction 2026-05-07)

The single hardest design constraint on the soft-region work is:

> "the hardest part would be mixing softbody and un-simulated body regions, the authoring must be easy and should not involve fiddly artistic aspects."

This shaped four specific decisions:

1. **No tet meshes anywhere.** Volume primitive only.
2. **No per-vertex artist authoring of soft-vs-rigid masks.** The blend is derived automatically from the volume SDF and the existing skin weights.
3. **Continuous blend, not discrete partition.** A vertex's `cluster_blend` is a smoothstep of signed distance to the volume — C1 across the boundary, no visible seam, no artist tweaking.
4. **Reference architecture is Obi softbody, not film-pipeline FEM.** Obi's primitives (overlapping-cluster shape matching + oriented particles + per-vertex skinning) match the authoring shape we need: artist places a volume primitive and tunes a few sliders. We are not implementing Obi, but the boundaries of what we implement match Obi's authoring contract.

Any future deviation from this constraint requires explicit user reconfirmation — this is not a default to drift away from.

---

## Phase ordering summary

```
TentacleTech
  Phase 4 close-out          (in flight; 4M-pre/4M/4N/4O/4P)
  Phase 4 follow-on          (4S Obi contact persistence — was planned)
  Phase 4.5 (NEW, opened)    4.5.A body-local persistent contacts
                             4.5.B λ warm-start
                             4.5.C Oriented Particles
  Phase 5 (unblocked)        canal interior 5E/5F/5G
  Phase 6                    Stimulus bus + mechanical sound
                             + §9.1 ProceduralContactSynth (NEW)
  Phase 7+                   bulgers, x-ray, multi-tentacle, etc.

Marionette
  Existing                   jiggle bones v1 (translation SPD; shipped, breast only)
                             jiggle bones v2 (rotational SPD; gated)
  Soft-region clusters (NEW) §16.1 SoftRegionProfile + Library resources
                             §16.2 SoftRegionBaker editor tool
                             §16.3 SoftRegionSolver C++ (uses Phase 4.5 particles)
                             §16.4 skin shader CUSTOMx fetch
                             §16.5 author 2 regions on kasumi end-to-end
                             §16.6 acceptance
                             §16.7 overlapping subclusters (deferred)

Reverie
  Phase 1 (planned)          one-shot vocal lines (Layer 1)
  Phase 1+ (NEW)             sustained vocal synthesis (Layer 2)
                             follows TentacleTech Phase 6 for shared audio-thread infra
```

The two "interesting" upgrades land at different phases — slimy/slippery procedural audio is Phase 6, soft-region clusters land after Phase 4.5. Both have clean architectural slots and concrete acceptance criteria. No retroactive rework of existing phases.

---

## Open question carried forward

The TL;DR for soft-region clusters defers single-cluster vs overlapping-subcluster shape matching as a tuning decision. Single-cluster ships in §16.3; if visible deformation looks too uniform under non-uniform contact, subclusters land as §16.7 with no re-authoring required (same particles, additional shape-match constraints). Worth revisiting at the §16.5 end-to-end test on kasumi.
