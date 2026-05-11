# Marionette — Automatic BoneMap Population

**Date:** 2026-05-10
**Target system:** Marionette
**Affects:** `docs/marionette/Marionette_plan.md` (new phase), `extensions/marionette/gdscript/runtime/`, `gdscript/editor/`

## Goal

Drop almost any standard humanoid skeleton (ARP Standard, ARP UE, Mixamo, Rigify,
Unity Bip01, Godot native `SkeletonProfileHumanoid`) into the project and have
Marionette produce a usable `BoneMap` automatically, without:

- renaming bones in Godot's GLTF import dialog,
- hand-authoring a `BoneMap.tres` per character,
- per-character resource side-files beyond the existing `BoneProfile.tres`.

The user clicks one button ("Auto-fill from Skeleton") on the BoneMap inspector;
the matcher fills the slots; the existing
`BoneProfileGenerator.generate_with_method(profile, live_skeleton, bone_map, ...)`
takes it from there unchanged.

## Why now

Bone mapping is the only remaining manual gate between "import a character" and
"working ragdoll." Everything downstream of the BoneMap is already automatic:
muscle frame builder, archetype dispatch, permutation matcher, ROM defaults,
calculated-frame fallback, calibration-quality signal (yellow tripods). The
`docs/marionette/arp_mapping.md` table proves we already know how each
convention maps to profile slots — that knowledge just doesn't live in code.

Without this, every new character costs a hand-authored BoneMap and the
silent-overwrite trap from `reference_godot_bonemap_property.md`. With this,
new characters are drop-in for at least the four conventions above.

## Current state (do not re-survey)

- `BoneProfileGenerator.generate_with_method` in
  `extensions/marionette/gdscript/runtime/bone_profile_generator.gd` already
  consumes `(SkeletonProfile, live_skeleton, BoneMap)` and bakes the
  `BoneProfile`. **No changes to this path are required.**
- `marionette_humanoid_bone_map.tres` is the canonical reference for ARP
  Standard mapping. It pairs with `marionette_humanoid_profile.tres` (84 slots:
  56 standard + 28 toe phalanges).
- `docs/marionette/arp_mapping.md` has the full ARP Standard / ARP UE name
  tables. Treat it as a data source, not just documentation.
- No name-heuristic or auto-mapping code exists today (one unrelated `heuristic`
  comment in `frame_validator.gd`; nothing else).
- Yellow tripods on calibrated ragdolls indicate per-bone calculated-frame
  fallback, **not** failure. Auto-fill must not suppress that signal — it
  operates strictly on the BoneMap (name → name), not on the BoneProfile (axis
  derivation).

## Architecture

Two-pass auto-filler, **authoring-time only**, pure GDScript. No C++ work.

### Pass 1 — Name analysis (known conventions)

Per profile slot, score each candidate source bone by normalized-name token
similarity against per-convention dictionaries.

Normalization rules applied to every source bone name before scoring:

- Lowercase.
- Strip well-known prefixes: `mixamorig:`, `mixamorig1:`, `def-`, `c_`, `bip01_`, `bip_`.
- Strip well-known suffixes: `_stretch`, `_twist`, `_twist_leaf`, `_leaf`,
  `_helper`, `_ik`, `_fk`.
- Extract a side tag (`L`, `R`, `X`/center) from suffix patterns
  `.l/.r/.x`, `_l/_r`, `_left/_right`, `left_/right_`, capitalized variants.
  Side tag is enforced as a hard constraint, not a soft score.
- Collapse remaining separators (`._-`) to a single delimiter for tokenization.

Per-convention dictionaries cover at least:

- **ARP Standard** — full mapping from `docs/marionette/arp_mapping.md`. Source of truth.
- **ARP UE / Unreal Mannequin** — full mapping from the same doc.
- **Mixamo** — `mixamorig:Hips`, `mixamorig:LeftArm` (= UpperArm),
  `mixamorig:LeftForeArm`, `mixamorig:LeftHandThumb1..3`, etc. Mixamo's
  `LeftArm` ≠ Marionette's `LeftShoulder` — that's the kind of trap the
  dictionary exists to encode. Toes: Mixamo has `LeftToeBase` only — leave
  the 14 phalanx slots unmapped.
- **Rigify (Blender) deform layer** — `DEF-spine.001`, `DEF-upper_arm.L`,
  `DEF-forearm.L`, `DEF-hand.L`, `DEF-thigh.L`, `DEF-shin.L`, `DEF-foot.L`,
  `DEF-f_index.01.L`..`.03.L`, etc.
- **Unity Bip01** — `Bip01_L_UpperArm`, `Bip01_L_Forearm`, `Bip01_L_Hand`,
  `Bip01_L_Finger0..4`.
- **Godot native** — `SkeletonProfileHumanoid` names match Marionette slot
  names 1:1 for the 56 non-toe bones; identity case must be supported.

Score = Jaccard over normalized tokens, with side-tag mismatch → score 0.
Output: best candidate per slot + confidence in [0, 1].

### Pass 2 — Structural verification & repair

Pass 1 alone is fragile and rots. Pass 2 makes "any standard skeleton" real.
Operates on `Skeleton3D` rest-pose geometry independently of names, then
reconciles with Pass 1.

Pipeline:

1. **Identify the body root.** Heaviest subtree by descendant count, with
   topology consistent with a humanoid pelvis (two leg chains + one spine
   chain branching from it). Reject scene-root / `c_traj`-style locomotion bones.
2. **Trace the spine.** Walk the upward chain from the body root that ends in
   the most-superior leaf-or-near-leaf bone with two lateral branches above it
   (the shoulders). Length 2–5 → assign Spine/Chest/UpperChest/Neck/Head, with
   slots that don't fit (e.g. only 2 spine bones) staying unmapped.
3. **Identify shoulder / arm chains.** The two lateral branches off the top
   spine segment, depth 3 ignoring helper bones, with ratios consistent with
   shoulder→upper-arm→lower-arm→hand. Sub-chains of depth 2–3 below the hand
   are fingers; classify thumb (lateral-most, often shorter) vs index/middle/
   ring/little by lateral position at rest.
4. **Identify leg chains.** Two downward branches from the body root, depth 3
   → upper-leg/lower-leg/foot. Sub-chains below foot are toes; assign
   big/2nd/3rd/4th/5th by lateral position; assign Proximal/Intermediate/
   Distal by depth.
5. **Symmetry repair.** Any slot Pass 1 left empty or low-confidence whose
   mirror is high-confidence is filled by reflecting across the sagittal plane
   in rest pose.
6. **Helper pruning.** Bones with zero descendants and a constant offset to a
   sibling, or matching `^(c_traj|.*_twist.*|.*_leaf|.*_ik|.*_fk|.*_helper|.*_target)$`,
   are excluded from candidacy.

### Reconciliation

For each slot, pick the higher-confidence answer between Pass 1 and Pass 2;
if both are confident and agree, mark green; if they disagree, prefer Pass 2
and mark yellow with the conflict logged; if neither is confident, mark red.

### UX

`BoneMap` inspector gains an "Auto-fill from Skeleton" button (a small
`EditorInspectorPlugin` parse hook on `BoneMap` resources whose profile is
`MarionetteHumanoidProfile`). User picks a `Skeleton3D` in the scene tree (or
the inspector resolves the active one). Button preview-fills the slots with
confidence color coding (green ≥0.9 / yellow 0.6–0.9 / red <0.6), shows a
diff against existing entries, applies on confirm with full undo. Logged to
the output panel: per-slot score, source bone, which pass produced it.

## First slice scope

Pass 1 + UX only. Slice 1 ships exactly:

- `extensions/marionette/gdscript/runtime/bone_name_dictionary.gd` — per-convention
  dictionaries (ARP Standard, ARP UE, Mixamo, Rigify DEF, Unity Bip01, Godot
  native). Pure data + lookup helpers.
- `extensions/marionette/gdscript/runtime/bone_name_normalizer.gd` — string
  pipeline (lowercase, prefix/suffix strip, side-tag extraction, tokenization).
- `extensions/marionette/gdscript/runtime/bone_map_auto_filler.gd` — Pass 1
  matcher returning `Dictionary[StringName, FillResult]` where `FillResult`
  carries `source_bone: StringName`, `confidence: float`, `pass: int` (1 or 2).
- `extensions/marionette/gdscript/editor/bone_map_inspector_plugin.gd` —
  inspector button, preview dialog, undo-aware apply. Registered in
  `plugin.gd` alongside the existing inspector plugins.
- Tests at `extensions/marionette/tests/`:
  - Unit: normalizer round-trips on every entry in every dictionary.
  - Unit: dictionary lookups on all 84 slots × 6 conventions.
  - Integration: load three rigs (Kasumi ARP Standard from
    `game/scenes/kasumi_local.tscn`, one Mixamo `.glb`, one Rigify `.glb`),
    auto-fill, assert ≥80% slot fill rate with confidence ≥0.9 on the
    expected slots. **User must drop the Mixamo and Rigify reference rigs
    into `game/assets/test_rigs/` before this test can run** — the brief
    ships placeholder paths and a `# TODO: enable once asset present` skip
    guard, not the rigs.
  - Regression: the existing `marionette_humanoid_bone_map.tres` is bit-equal
    to what the auto-filler produces against the Kasumi skeleton. (If not,
    the diff is actionable — either the table or the dictionary is wrong.)

Slice 1 explicitly **does not** include Pass 2. Pass 2 is the next slice and
should be designed against the failures observed when slice 1 is run on
unknown rigs.

## Slice 2 (gate, not a commitment)

`skeleton_topology_classifier.gd` — Pass 2 spatial pipeline. **Pair this
slice with a gizmo** that visualizes the classification on the live skeleton:
spine chain, arm chains, leg chains, helper-pruned bones, sagittal plane,
mirror pairs. Per `feedback_phase_slicing.md`, spatial algorithms ship with
their gizmo or the user cannot debug them. Gizmo color palette: cyan / magenta /
yellow + size hierarchy per `feedback_godot_gizmo_colors.md` (avoid
orange-yellow that Godot's default Skeleton3D gizmo eats).

Open before slice 2: do we add a `BoneMap` confidence sidecar (small `.tres`
storing per-slot confidence + source pass for diagnostics) or recompute on
demand? Defer the answer until slice 1 is in users' hands.

## Constraints sub-Claude must preserve

- **No changes to `BoneProfileGenerator`, `permutation_matcher.gd`,
  `archetype_solvers/`, `muscle_frame_builder.gd`, or any C++ code.** This
  feature is upstream of all of those — it produces a BoneMap, nothing else.
- **No new resource type.** A BoneMap is the output. Confidence reporting is
  ephemeral (output panel + inspector color), not serialized in slice 1.
- **Authoring-time only.** Do not call the auto-filler from runtime paths.
- **Static-typed GDScript everywhere.** Per `extensions/marionette/CLAUDE.md`.
- **Yellow-tripod calibration signal stays untouched.** Auto-fill produces
  BoneMap entries; whether they bake to permutation or calculated-frame
  fallback is the existing matcher's call.
- **Silent BoneMap overwrite trap.** When writing the BoneMap, use the
  `bone_map/<name>` (underscore) property prefix per
  `reference_godot_bonemap_property.md`. Verify by re-reading the resource
  through the inspector once before declaring slice 1 done.
- **Class-cache refresh.** Slice 1 introduces three new `class_name` globals.
  After deploying, run `godot --headless --path game --editor --quit` to
  refresh `global_script_class_cache.cfg` before running tests, per
  `reference_marionette_test_run.md`.
- **Test scene policy.** Auto-filler tests are headless GDScript scripts
  invoked by `tests/run_tests.gd`. **Do not create new `.tscn` files for this
  feature without explicit user permission**, and even with permission, no
  animations / baked lighting / Resource pipelines per
  `feedback_test_scene_policy.md`.
- **No fiddly authoring.** Per `feedback_no_fiddly_authoring.md`, the user
  must not need to hand-tune confidence thresholds per character. The
  dictionary + structural gates are the entire knob surface; per-rig overrides
  only exist if the auto-fill is wrong, in which case the user edits the
  resulting BoneMap directly.

## Questions for sub-Claude before implementation

Sub-Claude should answer these (against the live code, not assumptions) and
propose the answer back to top-level Claude before starting slice 1:

1. **Plan placement.** Where in `Marionette_plan.md` does this phase slot in?
   Existing phases go to at least P14. Propose a phase number (e.g. P2.15 or a
   new top-level phase) and confirm it doesn't collide with in-flight work.
2. **Inspector hook surface.** Is `EditorInspectorPlugin._parse_property`
   (or `_parse_begin`) the right hook for adding a button to a `BoneMap`
   resource inspector, or does the resource preview dock require a different
   plugin shape? Verify against current Godot 4.6 docs.
3. **Active-skeleton resolution.** When the user clicks "Auto-fill from
   Skeleton" with a `BoneMap.tres` open in the inspector, how does the plugin
   discover the live `Skeleton3D` to read rest poses from? Options: (a) user
   picks via a dropdown of `Skeleton3D` nodes in the open scene, (b) plugin
   walks the open scene for the first `Skeleton3D`, (c) inspector adds a
   transient `Skeleton3D` picker property. Propose one and justify.
4. **Mirror-symmetry detection in Pass 2.** Will rest-pose mirror search be
   robust against rigs whose A-pose has nontrivial arm rotation, or do we
   need a T-pose normalization step first? Decide before slice 2.
5. **Reference rigs.** Confirm with the user before slice 1 implementation:
   should we ship reference Mixamo and Rigify `.glb` files in
   `game/assets/test_rigs/` for the integration tests, or rely on the user
   dropping them in? (Top-level Claude leans toward user-provided to avoid
   licensing footguns; confirm.)

## Acceptance for slice 1

- The Kasumi ARP rig produces an identical BoneMap to the shipped
  `marionette_humanoid_bone_map.tres` via the auto-filler, with no manual
  intervention.
- A second rig (Mixamo or Rigify, whichever the user provides first)
  auto-fills with ≥56 of 84 slots green-confidence; the resulting BoneMap
  drives `BoneProfileGenerator` to a working ragdoll under the existing
  drop-test scene without further authoring.
- All slice 1 unit tests pass via `tests/run_tests.gd`.
- The shipped BoneMap regression test pinpoints any drift between the
  dictionary and the documented ARP mapping.
