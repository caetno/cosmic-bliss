# Systems Architecture

## The four extensions

| Name | Role | Language mix | State |
|---|---|---|---|
| **TentacleTech** | PBD tentacle physics, orifices, collision, stimulus bus | C++ core (PBD hot path) + GDScript glue | Active, most mature |
| **Marionette** | Active ragdoll solver (SPD), cost-weighted IK composer | C++ core + GDScript glue (resources, gizmos, editor tooling) | Active |
| **Tenticles** | GPU particle system (NGP-style) | C++ core (RenderingDevice-driven) | Paused |
| **Reverie** | Reaction system, facial rig, mindset, expressions | GDScript (future) | Not started |

A fifth (`dpg`, legacy DPG port) is being phased out — kept as a reference for spline-math salvage only.

## TentacleTech

The most-developed extension. Implements:

- **PBD chain solver** (XPBD with per-segment lambda accumulators; substep + iter loop; Jacobi-with-atomic-deltas-and-SOR pattern)
- **7 collision types** under unified PBD friction cone:
  - type-1: tentacle ↔ ragdoll bone (with reciprocal impulse to the bone)
  - type-2: tentacle ↔ orifice rim particle (bilateral compliance)
  - type-3: tentacle ↔ canal wall (texture-driven; under design)
  - type-4: tentacle ↔ static environment
  - type-5/6/7: future
- **Orifice** as a multi-loop closed rim of PBD particles with XPBD distance + volume + spring-back, plastic memory, anisotropic compression-vs-stretch, J-curve strain stiffening
- **EntryInteraction** — per-(tentacle, orifice) state object with hysteretic grip ramp, damage accumulation, friction at type-2, §6.3 reaction-on-host-bone closure
- **TentacleMesh** as a `PrimitiveMesh` subclass + feature modifier model (KnotField, Ribs, WartCluster, SuckerRow, Spines, Ribbon, Fin)
- **Feature silhouette** — 2D R32F texture (256 axial × 16 angular) baked from features, sampled at contact time to perturb collision threshold (slice 5H, 2026-05-05)
- **Canal** (in design) — 2D tunnel-state texture + PBD centerline particle chain for moving cavities (vagina, anus; future stomach / uterus)
- **Stimulus Bus** (autoload) — events + continuous channels + bidirectional modulation between physics and reaction layer

Spec: `docs/architecture/TentacleTech_Architecture.md`. AI / scenarios: `docs/architecture/TentacleTech_Scenarios.md`.

## Marionette

Active ragdoll for Kasumi. The solver maps motion intent into joint torques via Stable PD (SPD), so the ragdoll **animates itself** under physics rather than playing back animation tracks. Reactive to external forces from TentacleTech without giving up animation authority.

Components:
- SPD per-joint controller
- Cost-weighted IK composer (combines targets across the body)
- `BoneProfile` resource (anatomical mass fractions, ROM defaults; user-calibrated per rig)
- `BoneCollisionProfile` — per-bone collision shape authoring; `non_cascade_bones` excluded from automatic shape inference (used to mark jiggle bones)
- Jiggle bones — translation-only SPD with mass-portable kp/kd; currently breast-only on Kasumi's rig
- **`body_rhythm_phase: float`** (0..2π) — integrated phase for body-driven rhythm; **never recomputed**, only integrated. Reverie writes `body_rhythm_frequency`; TentacleTech's `RhythmSyncedProbe` reads `body_rhythm_phase`. This is the shared clock that couples body and tentacle rhythm.

Spec: `docs/marionette/Marionette_plan.md`.

## Tenticles

GPU particle system for things that aren't PBD chains — fluids, slime strands, smoke. Drives a `RenderingDevice`-backed particle pipeline (NGP-style, Material Point Method-adjacent). Currently paused pending TentacleTech maturation; not on the critical path.

Tenticles is **scoped self-contained** — does not subscribe to the Stimulus Bus directly. User-level GDScript glue reads the bus and writes Tenticles' public params; the extension stays clean of higher-level coupling.

Spec: `docs/tenticles/Tenticles_design.md`.

## Reverie (future)

Reaction system. Reads physics events + continuous channels from the Stimulus Bus; writes mindset state, facial expressions, vocalizations, and modulation back into the bus (per-region sensitivity, body-rhythm frequency, expression-driven muscle tensions). Not implemented yet; interface contract is defined so TentacleTech's emission format doesn't lock the future implementation out.

Spec: `docs/architecture/Reverie_Planning.md`.

## Cross-extension communication

Three mechanisms:

1. **Signals / resources / nodes** in the scene tree — same as any Godot project
2. **Stimulus Bus** (TentacleTech autoload) — physics state, events, modulation channels. The bus is **bidirectional**: physics writes events + continuous state, reaction writes modulation (and vice-versa)
3. **`Marionette.body_rhythm_phase`** — shared phase clock for body↔tentacle rhythm coupling

Hard rule: extensions do **not** `#include` each other's internal headers. Shared types go in `extensions/shared/include/`. All cross-extension communication is via GDScript-level interfaces; never C++ coupling.

## Game layer

GDScript on top, in `game/scripts/` (and `game/addons/<extension>/scripts/` for extension-shipped GDScript):

- **Camera + Input** — third-person orbit camera, controller-first. Player as disembodied observer, not embodied avatar. See `docs/Camera_Input.md`.
- **Appearance** — dissolve-shader clothing, decal accumulator. No cloth physics. See `docs/Appearance.md`.
- **Save** — single save per profile, versioned migrations. Persists mindset + appearance + currency + unlocks + stats. See `docs/Save_Persistence.md`.
- **Gameplay loop** — committed decisions (persistent mindset, no fail state, single-type currency, roguelite under consideration). Loop design deliberately deferred until the four extensions stabilize. See `docs/Gameplay_Loop.md`.
- **Gameplay mechanics** — skill surface on top of physics. See `docs/Gameplay_Mechanics.md` and `04_gameplay_mechanics.md`.

## Default to GDScript

C++ is reserved for:
- Code that runs at physics-tick rate (60+ Hz) with nontrivial per-tick cost
- Math-heavy inner loops (PBD iterations, collision projection, spline evaluation)
- Direct `RenderingDevice` interaction

Everything else stays in GDScript: AI, behaviour, scenarios, control plumbing, stimulus consumption, reactions, editor tooling, mesh generation (TentacleMesh), configuration resources. The compile-edit cycle is a real cost; the C++ surface stays small on purpose.
