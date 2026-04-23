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

Appearance state is a save payload section (see `docs/Save_Persistence.md`).
