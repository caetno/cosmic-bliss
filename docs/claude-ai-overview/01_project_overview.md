# Project Overview

## What Cosmic Bliss is

A solo-dev Godot 4.6 game built around physics-simulated tentacle interactions with an active-ragdoll humanoid character. The technical core is four custom C++ GDExtensions; the game layer on top is GDScript.

The design value is **emergent physics over scripted scenarios**. The same physics that makes the tentacle wrap also makes it slip; the same physics that grips a rim also tears it under load; the host's leg responds to contact and that response feeds back into where the tentacle ends up next tick. There are no scripted set pieces. The player's experience is what comes out of the simulation under their inputs.

This means realism is the work — the simulation has to be expressive enough that rare emergent events actually exist, surprising even the designer.

## Hero

**Kasumi.** Humanoid female, the only character. Active ragdoll driven by Marionette's SPD solver. Persistent across play sessions: mindset, appearance, currency, unlocks, stats all save.

There is no fail state. The player's role is closer to disembodied observer than controlled avatar; see `04_gameplay_mechanics.md`.

## Setting and tone

Setting is deliberately not committed yet — gameplay-loop design is paused until the four extensions stabilize. Tone is physics-sandbox first, narrative-light. The intent is that the player learns Kasumi's body and the tentacles' behaviours through play, not through dialogue or tutorials.

## Engine and architecture at a glance

- **Godot 4.6**, with godot-cpp tracking master (4.6 branch not yet published)
- **Four C++ GDExtensions** in a monorepo:
  - **TentacleTech** — PBD tentacle physics, orifices, collision, stimulus bus
  - **Marionette** — active ragdoll, SPD, IK composer, jiggle bones
  - **Tenticles** — GPU particle system (NGP-style)
  - **Reverie** — reaction system, facial rig, mindset, expressions (future)
- **Game layer** in GDScript — camera, input, appearance, save, scenarios

The two cross-extension communication mechanisms are the **Stimulus Bus** (TentacleTech autoload) and the **`Marionette.body_rhythm_phase`** shared clock for body↔tentacle rhythm coupling. See `02_systems_architecture.md`.

A fifth extension (`dpg`, legacy DPG port) is being phased out and kept as a reference for spline-math salvage only. Don't carry conventions from it.

## Build status

Pre-alpha. Phase work proceeds in explicit small slices (one named slice per session). At time of writing:

- **TentacleTech** — Phases 1–5 done; canal interior model (5E/5F/5G) is next gate; active investigation into wedge contact stability under PBD↔ragdoll coupling.
- **Marionette** — solver + ROM + BoneCollisionProfile + jiggle-bones first cut; active feature work
- **Tenticles** — paused pending TentacleTech maturation
- **Reverie** — not started; interface contract defined

`08_current_state.md` carries the live status snapshot.

## Hardware target

**GTX 970** (4 GB VRAM) is the design ceiling. Implications throughout — see `07_engine_constraints.md`. The short version: realism comes from CPU physics + clever vertex-shader deformation, not from fragment-stage techniques.
