# Cosmic Bliss — Project Overview for Claude AI

A Godot 4.6 sandbox where physics-simulated tentacles interact with an active-ragdoll humanoid. Built on custom GDExtensions; emergent physics over scripted scenarios.

## How to use this folder

These files brief Claude AI on the project so design / planning / ideation conversations don't start from zero each session. They are an OVERVIEW — the canonical specs live in the repository under `docs/architecture/` and aren't reproduced here in full.

Read the README first. Then dip into the topical files as relevant. Files are independent — read in any order.

## Files

1. `01_project_overview.md` — what Cosmic Bliss is, hero, status
2. `02_systems_architecture.md` — the four extensions + how they communicate
3. `03_physics_and_deformation.md` — PBD foundation, deformation model, realism levers (the technical-realism focus area)
4. `04_gameplay_mechanics.md` — skill surface, persistence, design philosophy
5. `05_character_and_authoring.md` — Kasumi, appearance, save schema, body areas
6. `06_asset_pipeline.md` — Blender → Godot, authoring conventions
7. `07_engine_constraints.md` — GTX 970 ceiling, Godot 4.6 quirks, perf rules
8. `08_current_state.md` — where development is now, active issues, what's blocked

## Working style

- Short answers for short questions. Don't pad.
- Plan before structural changes. Skim canonical docs before suggesting topology shifts.
- **Soft physics over scripted levers.** If a behaviour can't be expressed via stiffness, friction, grip, damage thresholds, or modulation channels, the fix is the physics — not a boolean reject or an angle gate. This applies to every extension and to gameplay design.
- Flag bad patterns when noticed, even if not asked (coordinate space bugs, per-frame allocs, MeshDataTool in hot paths, anything fragment-shader-heavy on a GTX 970).
- Don't write GDScript as C++ string literals or vice versa.
- Phase work proceeds in explicit small slices (one named slice per session). On "Continue", propose next slice scope before doing anything.

## What is NOT in these docs

- Code-level implementation detail. That stays in code sessions where the actual files are accessible.
- Obi 7.x physics asset internals. Local-only reference, paid third-party, not in the repo, not redistributable.
- Per-slice change logs. Those live in `docs/Cosmic_Bliss_Update_*.md` in the repo as a running changelog.
- Anything fragment-shader-heavy as a realism lever. Hardware target is a GTX 970; deformation realism comes from physics, not pixel shaders. See `07_engine_constraints.md`.

## Repository pointers (for when these docs aren't enough)

- `docs/architecture/TentacleTech_Architecture.md` — TentacleTech canonical spec, single source of truth
- `docs/architecture/TentacleTech_Scenarios.md` — AI control model + narrative scenarios that double as acceptance tests
- `docs/architecture/Reverie_Planning.md` — future reaction system contract
- `docs/marionette/Marionette_plan.md` — Marionette plan
- `docs/tenticles/Tenticles_design.md` — Tenticles plan
- `docs/Camera_Input.md`, `Appearance.md`, `Save_Persistence.md`, `Gameplay_Loop.md`, `Gameplay_Mechanics.md` — game layer
- `docs/Cosmic_Bliss_Update_*.md` — running amendment / changelog docs
