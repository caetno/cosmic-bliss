# Character and Authoring

## Kasumi

The hero. Humanoid female, the only character. Active ragdoll driven by Marionette's SPD solver. Persistent across sessions.

Built around an active-ragdoll skeleton with `BoneCollisionProfile` per-bone collision shapes. Marionette's SPD solver and IK composer drive joint torques to express animation intent without giving up reactive physics — the ragdoll animates itself under physics constraints rather than playing back animation tracks.

## Persistence

- **Single save per profile**, versioned with migrations.
- **Persisted state**: mindset, appearance, currency, unlocks, stats. See `docs/Save_Persistence.md`.
- Save format is forward-compatible by design — adding new mindset fields or appearance dimensions migrates rather than wipes.

## Mindset

A persistent, evolving state — the closest the game has to "character development" — written by Reverie in response to physics events + continuous channels emitted by TentacleTech.

Mindset surfaces include:
- Per-region sensitivity (the discovered sensitivity map)
- Body-rhythm baseline frequency (what `Marionette.body_rhythm_frequency` settles to)
- Reaction expression bias (calm / alarmed / euphoric / submissive / defiant — illustrative; not finalized)
- Threshold knobs that influence how the same physics state reads downstream

Mindset is **persistent** and **slow-moving**. Sessions nudge it; nothing nukes it.

## Appearance

Customization comes from the **Appearance** game-layer system, not from cloth physics.

- **Dissolve-shader clothing.** Clothes don't tear or slide — they dissolve. State is per-region, per-clothing-piece, persisted.
- **Decal accumulator.** Persistent body decals: bruising, marking, oil, fluid residue. Sampled into a body-space decal map and rendered as a fragment-shader layer on the skin.
- **No cloth physics.** Cloth simulation isn't worth the GTX 970 budget; dissolve covers the gameplay-meaningful surface and matches the no-tearing aesthetic.

See `docs/Appearance.md`.

## Body areas (semantic regions)

20–30 named regions, **not per-bone**. Examples:
- left/right inner thigh
- lower belly
- chest, neck, throat
- vulva, clitoris, vaginal entry, vaginal canal, cervix, uterus
- anus, anal canal
- (and so on through the anatomical surface)

Regions are the unit of:
- Reverie's per-region sensitivity
- Stimulus Bus continuous channel emission (e.g., `BodyAreaPressure[region] = float`)
- Decal accumulator binning
- Clothing dissolve state

Bones drive the region positions; regions are NOT 1:1 with bones. A semantic region may span multiple bones; conversely a bone may carry no region.

## Bone authoring

Marionette ships:
- **`BoneProfile` resource** — anatomical mass fractions (sum-to-1 over the whole body), ROM defaults per bone, joint axis conventions. `kasumi_humanoid_bone_profile.tres` is the current profile; users calibrate per rig.
- **`BoneCollisionProfile` resource** — per-bone collision shape (capsule / box / hull) with per-axis dimensions, plus a `non_cascade_bones` list excluding bones from automatic shape inference.
- **Calibrate** action — re-fits the profile against the current Skeleton3D's pose; refreshes `MarionetteBone` masses live.

The user keeps `BoneProfile` defaults rig-specific where bone semantics differ (proximal phalanges, hip vs. waist as "Hips", facing axis); these are flagged as open questions in their auto-memory.

## Marionette gizmos

Custom Marionette gizmos use **CMY + RGB + size hierarchy** — NOT orange-yellow. Godot's default Skeleton3D gizmo is orange-yellow and visually swallows warm-hued additions. Project convention.

## Test scene policy

A **simple** test scene is "node tree + scripts + a few `@export` numbers." That's the bar.

Beyond that — animation tracks, `AnimationPlayer`/`AnimationTree`, baked lighting, multi-resource asset pipelines, custom `Resource` files authored on the side, rigged characters — does not get added without explicit OK from the user, and even then certain things require a separate explicit ask.

The reason: past failure mode is helpful but unwanted scaffolding the user then has to hand-clean. Bar is low-effort scenes after the user OKs them.
