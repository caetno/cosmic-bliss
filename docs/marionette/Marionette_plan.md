# Marionette — Implementation Plan

Incremental, testable delivery. Every phase ends with a **verifiable milestone** (a scene, a slider, a recorded video, or a diff) that proves the phase works. Do not proceed until the current milestone passes.

No timelines. The agent proceeds phase by phase, blocked only by milestone validation.

---

## Core architectural commitments

Read these before every phase. Full detail in `CLAUDE.md`.

1. **Two vocabularies coexist** — anatomical in public API and resources; axis in debug/internal/diagnostics.
2. **Flexion is always +X** in the joint-local frame *after ragdoll creation*. Y = along-bone. Z = abduction. Side mirror = negate Y and Z.
3. **Anatomical frame baked into physics at creation.** Authoring-time geometric pipeline writes per-bone permutation into `BoneProfile`; ragdoll creation applies it via `MarionetteBone.joint_rotation`. Runtime has no geometric work.
4. **Archetype-dispatched solvers** at authoring time only.
5. **Jolt Physics, `MarionetteBone` internal 6DOF, SPD via `_integrate_forces`, single skeleton, `PhysicalBoneSimulator3D.influence = 1.0`.**
6. **Scope**: body + head orientation. Jaw, eye bones: kinematic, driven by separate facial system.
7. **Profiles**: `BoneProfile` (static), `BoneStateProfile` (runtime state), `CollisionExclusionProfile`. Plus `RagdollPose`, `RagdollCyclicAnimation`, `EmotionalBodyState`, `EmotionalBodyOverlay`, `MotionMacro`.
8. **Custom `MarionetteHumanoidProfile`** with 84 bones (ARP-sourced, toe bones included).
9. **Animation input is procedural only.** No `AnimationTree`, no `AnimationPlayer`, no keyframe animation input. The full animation vocabulary is: poses + cyclic animations + emotional body overlays + motion macros + Reverie-driven anatomical targets + attention-driven neck targets, all composed additively on SPD-driven bones. This makes authoring UI load-bearing; Phases 4, 6, 7, 8 are the animation pipeline.

---

## Phase 0 — Project scaffolding

**Goal**: repo structure, build system, empty addon loads cleanly.

### Tasks

- Create repo with `addons/marionette/` structure matching `CLAUDE.md` file organization.
- `plugin.cfg` + minimal `plugin.gd` loading without error. Registers nothing yet.
- Test framework setup. Verify gdUnit4 is current recommendation for Godot 4.6+; if not, pick accordingly.
- Smoke test (asserts `1 + 1 == 2`).
- `demo/empty.tscn` with `Node3D` root opens cleanly.

**Note**: Marionette ships as a C++ GDExtension from the start. The active-ragdoll core (SPD math, per-bone integration, composer, IK, strain, engagement) runs in C++ to avoid design compromises imposed by GDScript per-tick cost at 60Hz × 84 bones × 30 DOFs. Resources, archetype solvers (authoring-time), muscle frame builder, gizmos, editor tooling, and test harnesses remain GDScript. Tunables (cost weights, frequency bands, mindset curves, posture pattern libraries) live in `.tres` resources or `@export` properties on the GDScript wrapper, so iteration on parameters does not require a rebuild. Phase 0 ships the empty addon; Phase 2.0 adds the C++ extension scaffold.

### Milestone

- Plugin enabled in project settings, zero errors in output panel.
- Tests report "0 tests, 0 failures" (or one passing smoke test).

### Files

```
addons/marionette/
├── plugin.cfg
├── plugin.gd
tests/
└── test_smoke.gd
demo/
└── empty.tscn
CLAUDE.md
PLAN.md
```

---

## Phase 1 — Custom skeleton profile with toe bones

**Goal**: `MarionetteHumanoidProfile` as a ready-to-use `SkeletonProfile` subclass with 84 bones (56 standard + 28 toe). Usable as BoneMap target, shows foot group with toe handles in BoneMap editor.

### Critical context on group textures

`SkeletonProfileHumanoid`'s C++ constructor sets group names ("Body", "Face", "LeftHand", "RightHand") but **never** calls `set_texture()` on any group. All four ship with null textures. The silhouettes visible in the BoneMap editor come from editor-theme SVG icons (`BoneMapHumanBody`, `BoneMapHumanFace`, `BoneMapHumanLeftHand`, `BoneMapHumanRightHand`), not from the profile's `texture` field.

How the native BoneMap editor resolves these icons is **not yet verified** (source is in `editor/scene/3d/bone_map_editor_plugin.cpp`, not directly readable through the current toolchain). Three possibilities:
- **A (fallback)**: editor reads `profile.get_texture(group_idx)`; if null, falls back to editor theme icon by known group name
- **B (hardcoded)**: editor ignores profile texture for known group names; always uses editor theme icons
- **C (separate path)**: editor uses `profile.get_texture(group_idx)` exclusively; icons applied via a `SkeletonProfileHumanoid`-specific code path outside the profile

**P1 starts with a 10-minute empirical test** (see P1.0) to disambiguate. This determines the implementation path for the rest of the phase.

### Tasks

- **P1.0 (blocker)** — Empirical verification of BoneMap icon resolution. Create a test `SkeletonProfile` subclass with 6 groups (Body, Face, LeftHand, RightHand, LeftFoot, RightFoot). Assign a distinctive custom texture (any recognizable image) to each group via `set_texture()`. Load into a BoneMap in the editor. Observe which textures render:
  - If all 6 custom textures show → **Option A or C** (effectively the same for our purposes): foot textures via `set_texture` will work, and we can optionally override the built-in four groups too
  - If the four built-in group names still show editor icons but LeftFoot/RightFoot show our custom textures → **Option A (fallback)**: foot textures via `set_texture` work, but the four built-in groups fall back to theme icons regardless
  - If LeftFoot/RightFoot render as blank → **Option B (hardcoded)**: we need our own BoneMap UI
  Document outcome in `docs/bonemap_icon_verification.md`. P1.1+ branches on the result.
- **P1.1** — Foot group SVG icons. Author `BoneMapHumanLeftFoot.svg` and `BoneMapHumanRightFoot.svg` matching the visual style of Godot's existing body/hand/face SVGs. Top-down foot outline with toe positions visible. Ship in `addons/marionette/textures/`. SVG not PNG, to match Godot convention and stay resolution-independent.
- **P1.2** — `MarionetteHumanoidProfile` resource script. Extends `SkeletonProfile`. At construction time:
  - Instantiates `SkeletonProfileHumanoid` internally as a source to read its bone/group/handle data.
  - Copies all 56 standard bones: names, parents, tail directions, reference poses, handle offsets, group assignments.
  - Adds 28 toe bones with correct parent relationships (feet → metatarsal-bone-per-toe → phalanges):
    - Per foot: `Big_Toe_Proximal`, `Big_Toe_Distal` (hallux, 2 phalanges)
    - Per foot: `Toe_2_Proximal/Middle/Distal`, `Toe_3_*`, `Toe_4_*`, `Toe_5_*` (3 phalanges each, 12 bones per foot for toes 2-5)
  - Adds `LeftFoot` and `RightFoot` group entries; sets handle offsets for each toe (pixel positions matching the foot SVG).
  - Group texture handling depends on P1.0 outcome:
    - **Option A or C**: Assign all six textures via `set_texture()`. For Body/Face/LeftHand/RightHand, fetch the editor theme icons via `EditorInterface.get_editor_theme().get_icon(&"BoneMapHumanBody", &"EditorIcons")` etc. For LeftFoot/RightFoot, load our shipped SVGs. Assignment happens in an editor-only post-construction step (likely via an `EditorInspectorPlugin` or the addon's `_enter_tree()`), since editor theme is only available inside `EditorInterface`.
    - **Option B**: Do not assign any group textures on `MarionetteHumanoidProfile`. The built-in four groups will render with editor theme icons via the BoneMap editor's hardcoded path. LeftFoot/RightFoot will render blank in the native BoneMap editor — we accept this for now and ship our own foot-group-only inspector supplement in P1.5 (added below).
- **P1.3** — `BoneMap` editor verification: create a test scene with a `BoneMap` resource using `MarionetteHumanoidProfile`. Verify all 6 groups render with appropriate visuals; all 84 bone handles are clickable.
- **P1.4** — Auto-Rig Pro bone name mapping reference. Document (in `docs/arp_mapping.md`) which ARP export bone name corresponds to each `MarionetteHumanoidProfile` bone. Needed for automatic BoneMap population of ARP characters.
- **P1.5 (conditional, only if P1.0 returns Option B)** — Foot-group inspector supplement. An `EditorInspectorPlugin` that detects when the edited `BoneMap` has a `MarionetteHumanoidProfile` assigned, and adds two extra panels below the native BoneMap UI: LeftFoot and RightFoot, each rendering our SVG with clickable handle circles for the toe bones. Follows the visual conventions of the native BoneMapper.

### Milestone

- `MarionetteHumanoidProfile.tres` loads in editor without errors.
- `docs/bonemap_icon_verification.md` exists with the resolved option documented.
- BoneMap editor displays Body/Face/LeftHand/RightHand groups with Godot's standard silhouettes and LeftFoot/RightFoot groups with our new foot SVGs (via P1.2 Option A/C, or via P1.5 supplement if Option B).
- All 84 bone handles (56 standard + 28 toe) are clickable.
- Test character imported with ARP toe bones: BoneMap populates all 84 entries via name matching using the mapping reference in `docs/arp_mapping.md`.
- Video artifact: `docs/videos/phase_1_milestone.mp4` showing BoneMap view with all groups and a test import.

### Files

```
addons/marionette/
├── resources/
│   └── marionette_humanoid_profile.gd
├── editor/
│   └── (P1.5 conditional: foot_group_inspector.gd)
├── data/
│   └── marionette_humanoid_profile.tres
├── textures/
│   ├── bone_map_human_left_foot.svg
│   └── bone_map_human_right_foot.svg
docs/
├── arp_mapping.md
└── bonemap_icon_verification.md
demo/
└── profile_test.tscn
```

---

## Phase 2.0 — Marionette C++ extension scaffold

**Goal**: `extensions/marionette/` builds as a C++ GDExtension; the addon registers a `MarionetteCore` class accessible from GDScript with a no-op tick. Establishes the GDScript → C++ bridge that all later phases (P5 SPD, P10 composer/IK/engagement, P14 balance) build on.

### Tasks

- **P2.0.1** — `extensions/marionette/SConstruct` (mirror `extensions/tentacletech/SConstruct` structure — godot-cpp submodule, output to `bin/`).
- **P2.0.2** — `extensions/marionette/marionette.gdextension` manifest.
- **P2.0.3** — `src/register_types.cpp` / `register_types.h` — registers placeholder `MarionetteCore` class.
- **P2.0.4** — `src/marionette_core.cpp` / `.h` — placeholder C++ class with `_process(delta)` no-op + `hello()` returning a string. Confirms GDScript can call into the extension.
- **P2.0.5** — `tools/build.sh marionette` deploys to `game/addons/marionette/bin/`. Build script already supports both pure-GDScript and C++ addons; ensure mixed-mode (`HAS_CPP=true` path) deploys `gdscript/` → `addons/marionette/scripts/`.
- **P2.0.6** — Update `extensions/marionette/plugin.cfg` to declare both the `.gdextension` and the editor plugin entry point.
- **P2.0.7** — Sanity test: GDScript test harness instantiates `MarionetteCore`, calls `hello()`, asserts return value. Establishes the bridge.

### Milestone

- Build succeeds. GDScript test calls into C++. Existing GDScript-side resources (`BoneEntry`, `BoneProfile`, archetype solvers from P2.1+) are unaffected. Subsequent phases populate `MarionetteCore` with real logic.
- Video artifact: none (text-level milestone — captured in build log + test pass).

---

## Phase 2 — Muscle frame, archetype resolver, BoneProfile generation

**Goal**: authoring-time geometric pipeline that computes anatomical bone frames from a `SkeletonProfile`'s reference poses, populates a `BoneProfile` with archetype + permutation + ROM defaults. Gizmo visualization for immediate debugging.

### Tasks

- **P2.1** — `BoneArchetype` enum resource: `Ball, Hinge, Saddle, Pivot, SpineSegment, Clavicle, Root, Fixed`.
- **P2.2** — `SignedAxis` enum (PlusX..MinusZ) and conversion helpers (to `Vector3`, sign/index extraction, inverse).
- **P2.3** — `BoneEntry` struct (`Resource` or Dictionary entry; decide during implementation): archetype, bone_to_anatomical permutation (three signed axes), ROM limits in anatomical space, alpha, damping_ratio, mass_fraction, is_left_side.
- **P2.4** — `BoneProfile` resource: total mass, `bones: Dictionary<StringName, BoneEntry>`, reference to the companion `SkeletonProfile`.
- **P2.5** — Default bone name → archetype map for `MarionetteHumanoidProfile`:
  - Hinges: elbows, knees, finger/toe phalanges except proximal
  - Ball: shoulders, hips
  - Saddle: wrists, ankles
  - Clavicle: clavicles
  - SpineSegment: spine bones, neck bones
  - Pivot: (none default in humanoid, reserved)
  - Root: hips/root
  - Fixed: jaw, eyes
- **P2.6** — Per-archetype geometric solvers (`runtime/archetype_solvers/`), each ~30 lines:
  - Input: bone rest transform, child rest transform (or hint), muscle frame, is_left_side
  - Output: target anatomical basis (3 axes in bone-local space)
  - One file per archetype
- **P2.7** — Muscle frame builder: from a `SkeletonProfile`'s reference poses, compute UP/FORWARD/RIGHT. Uses hip midpoint, head bone, toe/foot positions.
- **P2.8** — Permutation matcher: given target anatomical basis (from solver) and the bone's rest basis, enumerate 24 signed-permutation candidates, score each by per-column minimum dot product (worst-axis-alignment), return best with score. Threshold for "unmatched" flag.
- **P2.9** — Clinical anatomical ROM defaults per archetype:
  - Ball (shoulder): flex 0..150, rot ±75, abd 0..150
  - Ball (hip): flex -15..100, rot ±45, abd 0..40
  - Hinge (elbow): flex 0..140
  - Hinge (knee): flex 0..135
  - Saddle (wrist): flex ±55, abd -15..35
  - Saddle (ankle): flex -15..40, abd ±20
  - Clavicle: small ROM all three axes
  - SpineSegment (per vertebra): small ROM all three
  - Toe phalanges: flex 0..80 typical
- **P2.10** — `BoneProfile` editor: "Generate from Skeleton" button in inspector. Runs muscle frame builder + archetype classification + solver + permutation matcher + ROM defaults for every bone in the referenced `SkeletonProfile`. Populates all entries.
- **P2.11** — `MarionetteBoneFrameGizmo` (`EditorNode3DGizmoPlugin`). Draws three colored arrows at each bone's joint origin (at the child's rest position, in the bone's local frame after applying the stored permutation):
  - Red = flex axis (X), green = along-bone (Y), blue = abduction (Z)
  - Hover tooltips: "Flex+" / "Twist+" / "Abduct+"
  - Small corner badge shows axis letter ("X" / "Y" / "Z") for debug vocabulary
  - For unmatched bones (low permutation score): drawn yellow with warning label
- **P2.12** — Diagnostic panel (right-side dock, first tab): select a bone in the scene tree, see per-bone details:
  - Archetype
  - Permutation (anatomical → axis): "Flex = +X, AlongBone = +Y, Abduction = +Z"
  - Permutation match score
  - ROM limits (anatomical values)
  - Reference pose transform
  - Use axis terminology freely here — this is the developer's debugging view.
- **P2.13** — Ship default `BoneProfile` for `MarionetteHumanoidProfile`. Generated once via the editor button, saved as `data/marionette_humanoid_bone_profile.tres`.
- **P2.14** — `PropagationGraph` resource + authoring-time bake. Skeleton-static graph that assigns each bone a scalar position `s` along a propagation path plus per-bone anatomical axis weights. Used by `TravelingWaveCyclic` (P7.9) and any future system that needs a continuous "position along the body" coordinate. **Authoring-time only; runtime reads baked values.** Schema:

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

  **Bake step.** Walk `trunk_path` accumulating rest-pose bone lengths into `bone_s`. For each branch, set `s_offset_from_trunk` to the trunk's `s` at `attach_bone`, then continue accumulating along `chain`. `bone_axis_weights` come from a per-region default (trunk = (1,0,0) flex; arms = (0.5,0,1) abd-leaning; legs = (1,0,0) flex) with per-bone overrides allowed in the inspector.

  **Pitfall.** If `s_offset_from_trunk` is zero (each branch starts its own coordinate from zero), waves passing through the body look like four separate limb wiggles instead of a single coherent disturbance. The bake step must inherit from the trunk.

### Milestone

- Opening a `BoneProfile` in the inspector and clicking "Generate from Skeleton" fills all 84 entries for `MarionetteHumanoidProfile` without errors.
- Gizmos render in the viewport for a test character: red arrows perpendicular to the sagittal plane on limb bones, along-bone green arrows running down each limb, abduction blue arrows perpendicular.
- Diagnostic panel shows permutation details for the selected bone using axis terminology.
- `PropagationGraph` baked from `MarionetteHumanoidProfile`: trunk + 4 limb branches, branch `s_offset_from_trunk` matches trunk `s` at attach point, total path length sane (1.5–2 m typical for human-scale).
- Unit tests pass: archetype solvers across T-pose, A-pose, bent-knee reference skeletons; permutation matcher picks identity for well-rigged input and non-identity for known-rolled input.
- Video artifact: `docs/videos/phase_2_milestone.mp4` showing generation action + gizmo review across 3 rest-pose variants.

### Files

```
addons/marionette/
├── resources/
│   ├── bone_archetype.gd
│   ├── signed_axis.gd
│   ├── bone_entry.gd
│   ├── bone_profile.gd
│   └── propagation_graph.gd
├── runtime/
│   ├── muscle_frame_builder.gd
│   ├── permutation_matcher.gd
│   ├── archetype_defaults.gd
│   ├── propagation_graph_baker.gd
│   └── archetype_solvers/
│       ├── ball_solver.gd
│       ├── hinge_solver.gd
│       ├── saddle_solver.gd
│       ├── pivot_solver.gd
│       ├── spine_segment_solver.gd
│       ├── clavicle_solver.gd
│       ├── root_solver.gd
│       └── fixed_solver.gd
├── editor/
│   ├── marionette_editor_plugin.gd
│   ├── bone_frame_gizmo.gd
│   ├── diagnostic_panel.gd
│   ├── right_dock.gd
│   └── bone_profile_inspector.gd
├── data/
│   ├── humanoid_archetype_map.tres
│   ├── marionette_humanoid_bone_profile.tres
│   └── marionette_humanoid_propagation_graph.tres
tests/
├── test_archetype_solvers.gd
├── test_permutation_matcher.gd
└── test_muscle_frame_builder.gd
demo/
└── bone_profile_test.tscn
```

---

## Phase 3 — Physical skeleton, collision exclusions, ragdoll creation wizard

**Goal**: the `Marionette` node creates a working physical skeleton with sensible defaults. Passive drop test validates the output. No muscle control yet; this is the ragdoll-creation workflow milestone.

### Tasks

- **P3.1** — `Marionette` node: extends `Node3D`. Initial properties:
  - `bone_profile: BoneProfile` (required)
  - `bone_state_profile: BoneStateProfile` (optional, defaults generated if null)
  - `collision_exclusion_profile: CollisionExclusionProfile` (optional, defaults generated if null)
  - `skeleton: NodePath` (to sibling or child `Skeleton3D`)
- **P3.2** — `MarionetteBone`: extends `PhysicalBone3D`. Placeholder for Phase 5 SPD logic. Currently just a marker node with bone name association and reference to its `BoneEntry`.
- **P3.3** — `BoneStateProfile`: resource with `states: Dictionary<StringName, BoneState>` where `BoneState` is enum `Kinematic, Powered, Unpowered`. Default for humanoid: all body bones `Powered`, jaw and eyes `Kinematic`, feet metatarsals potentially `Unpowered` initially (debate in implementation).
- **P3.4** — `CollisionExclusionProfile`: resource with `excluded_pairs: Array[Vector2i]` (bone index pairs) and `disabled_bones: PackedStringArray`. Default generator produces all parent-child pairs excluded; optional "also exclude siblings" flag.
- **P3.5** — Ragdoll creation wizard (`RagdollCreationWindow`, separate `Window`). Tabs:
  - **Colliders tab**: per-bone collider selector. Default: capsule (matches Godot's "Create Physical Skeleton" behavior). Options per bone: capsule, box, sphere, convex hull (from skin weights), custom mesh.
  - **Collision tab**: display generated `CollisionExclusionProfile`. Toggle for sibling exclusions. Add/remove pairs manually.
  - **State tab**: per-bone state selector (Kinematic/Powered/Unpowered). Validator warns if a `Powered` bone's parent is `Kinematic`.
  - **Weights tab** (stub for Phase 6): total mass + per-bone fraction sliders with L/R symmetric toggle, red-past-100% warning. Defaults computed from anatomical fractions.
- **P3.6** — Convex hull collider generator. Reads skin weights from a `MeshInstance3D` via `ArrayMesh.surface_get_arrays()`, clusters vertices by dominant bone influence (threshold configurable, default 0.5), computes `ConvexPolygonShape3D` per bone. Used when the dev switches a bone from capsule to convex hull in the wizard. Not default.
- **P3.7** — `Marionette.build_ragdoll()` method:
  - Reads `BoneProfile`, `BoneStateProfile`, `CollisionExclusionProfile`
  - Creates `PhysicalBoneSimulator3D` as child of `Skeleton3D` (if not present)
  - For each bone, creates a `MarionetteBone` with:
    - Capsule collider (default) or other per wizard selection
    - `joint_type = JOINT_TYPE_6DOF`
    - `joint_rotation` computed from the bone's `BoneEntry.bone_to_anatomical` permutation (so joint-local +X = anatomical flex)
    - Angular limits applied from `BoneEntry` ROM values, expressed in the (now anatomical) joint frame
    - Linear axes all locked to 0
    - State applied: Kinematic bones get `freeze = true, freeze_mode = FREEZE_MODE_KINEMATIC`; Unpowered get dynamic; Powered get dynamic (SPD added in Phase 5)
  - Applies collision exclusions via `PhysicalBoneSimulator3D.physical_bones_add_collision_exception`
  - Sets initial `gravity_scale` per `Marionette.gravity_scale` property
- **P3.8** — "Create Ragdoll" button in `Marionette` inspector launches the wizard; "Apply" in wizard calls `build_ragdoll()`.
- **P3.9** — Joint limit gizmos (`JointLimitGizmo`, second gizmo plugin). RGB disc sectors in the three joint-local planes:
  - Red sector in YZ plane: flexion limits, saturated-fill stripe at min/max boundary
  - Green sector in XZ plane: rotation limits
  - Blue sector in XY plane: abduction limits
  - Radius proportional to bone length
  - Current-angle indicator line
- **P3.10** — Passive drop test scene: character placed at 2m above a ground plane, no muscle control, gravity active. Expected: physically plausible crumple, no hyperextended joints, no interpenetration between parent-child bones.

### Milestone

- Loading a rigged character (ARP-humanoid), assigning the shipped `BoneProfile` to a `Marionette` node, clicking "Create Ragdoll" → wizard opens, default settings produce a working physical skeleton.
- "Apply" builds the ragdoll. Scene tree shows `PhysicalBoneSimulator3D` populated with `MarionetteBone`s. Joint limit gizmos visible in viewport.
- Dropping the character from 2m: crumples physically, elbows don't hyperextend, knees don't bend backward, neck doesn't rotate freely, no interpenetration between parent-child bones.
- Switching one bone (e.g., upper arm) from capsule to convex hull in the wizard and rebuilding: collider visibly follows mesh shape.
- Joint limit gizmos render correctly in joint-local frame, sectors match ROM values.
- Video artifact: `docs/videos/phase_3_milestone.mp4` showing wizard use, build, drop test, gizmo review.

### Files

```
addons/marionette/
├── runtime/
│   ├── marionette.gd
│   ├── marionette_bone.gd
│   ├── convex_hull_generator.gd
│   └── collision_exclusion_builder.gd
├── resources/
│   ├── bone_state_profile.gd
│   ├── bone_state.gd
│   └── collision_exclusion_profile.gd
├── editor/
│   ├── ragdoll_creation_window.gd
│   ├── collider_tab.gd
│   ├── collision_tab.gd
│   ├── state_tab.gd
│   ├── weights_tab.gd
│   └── joint_limit_gizmo.gd
├── data/
│   ├── humanoid_bone_state_default.tres
│   └── humanoid_anatomical_mass_fractions.tres
demo/
└── passive_ragdoll_drop.tscn
```

---

## Phase 4 — Muscle test panel (Skeleton3D preview mode only)

**Goal**: anatomical muscle sliders drive the `Skeleton3D` directly (no physics), for frame verification. Macro sliders for grouped motions. Right-side dock's "Muscle Test" tab fully functional.

### Tasks

- **P4.1** — Right-side dock gains "Muscle Test" tab. Reuses the existing dock infrastructure from P2.12.
- **P4.2** — Per-bone slider widget: anatomical DOFs matching archetype (Ball: 3 sliders, Hinge: 1, Saddle: 2, Pivot: 1, etc.). Slider labels anatomical ("Flexion", "Medial Rotation", "Abduction"). Range = ROM from active `BoneProfile`, displayed as colored band on the track.
- **P4.3** — Grouping: bones grouped by body region (LeftArm, RightArm, Spine, LeftLeg, RightLeg, Head/Neck, LeftHand, RightHand, LeftFoot, RightFoot). Collapsible sections.
- **P4.4** — Slider callbacks write to `Skeleton3D.set_bone_pose_rotation()` directly via the bone's anatomical basis (use the permutation from `BoneProfile` to convert anatomical angle → bone-local rotation).
- **P4.5** — "Symmetric" toggle: moving a slider on the left side mirrors to the right using sign-flip rule.
- **P4.6** — "Reset to Rest" button: restores all bones to rest pose.
- **P4.7** — **Rest-pose restoration on panel exit / mode change.** Critical: no editor interaction ever leaves the scene in non-default state. Undo integration where possible.
- **P4.8** — `MotionMacro` resource: `name`, `entries: Array[MacroEntry]` where `MacroEntry` is `{bone_name, axis (anatomical enum), curve}`.
- **P4.9** — Macro slider UI: for each shipped macro, a single slider that drives all its entries simultaneously via curve lookup.
- **P4.10** — Ship default macro library: per-limb flex/extend, abd/add, med/lat rotation for both sides, whole-body flex/extend/twist, squat, reach-up, arm-reach.
- **P4.11** — Unit tests: slider at known value produces known bone rotation; symmetric toggle produces mirrored result; macros interpolate curves correctly; rest-pose restoration returns bone poses to identity.

### Milestone

- Muscle Test tab shows all 84 bones grouped by region, sliders labeled anatomically.
- "Left Elbow Flexion" slider at +90° on T-pose, A-pose, and bent-knee characters: elbow bends identically (forearm curls toward biceps) on all three.
- Symmetric toggle: left slider also moves right to matching pose.
- "Right Shoulder Flexion" at +90°: right arm raises forward, identically to left at same setting.
- All toe sliders functional on `MarionetteHumanoidProfile` characters.
- Macro sliders: "Squat" at 100% flexes hips+knees+ankles in coordinated motion; "Arm Reach" drives shoulder+elbow+wrist+fingers.
- Closing the panel or changing tabs restores rest pose immediately.
- Video artifact: `docs/videos/phase_4_milestone.mp4` showing slider testing across three characters and macro use.

### Files

```
addons/marionette/
├── editor/
│   ├── muscle_test_tab.gd
│   ├── muscle_slider_widget.gd
│   ├── bone_region_grouping.gd
│   └── rest_pose_guard.gd
├── resources/
│   ├── motion_macro.gd
│   └── macro_entry.gd
├── macros/
│   ├── left_arm_reach.tres, right_arm_reach.tres
│   ├── squat.tres
│   ├── torso_twist.tres
│   ├── neck_look.tres
│   ├── whole_body_flex.tres, whole_body_extend.tres
│   └── ...
tests/
└── test_muscle_slider_math.gd
demo/
└── muscle_test_characters.tscn
```

---

## Phase 5 — SPD muscle controller (Ragdoll Test mode)

**Goal**: `MarionetteBone` runs SPD; the character actively poses itself via muscle sliders. Hip tether enables in-place testing. Strength parameter takes character from limp to rigid continuously.

**Implementation language**: the SPD hot path (`SPDMath`, `MarionetteBone._integrate_forces`, strength application, contact-triggered alpha reduction) ships in C++ from the first commit of this phase, building on the Phase 2.0 scaffold. GDScript holds the orchestrator wrapper (`Marionette.gd`), the hip-tether scaffolding (P5.6–P5.9), and unit-test harnesses; sliders write to `Marionette.set_bone_target()` (GDScript) which forwards once-per-change to C++ via a bound method.

### Tasks

- **P5.1** — `SPDMath` static helpers in `src/spd_math.cpp` / `.h`: `error_quaternion(current, target)`, `compute_torque(error_axis_angle, omega, kp, kd, dt)` using SPD formulation. Bound to GDScript via godot-cpp class registration only for unit-test access.
- **P5.2** — Alpha/damping_ratio → kp/kd converter (static C++). Inputs: alpha, damping_ratio, bone mass, physics dt. Output: kp, kd. Formulation: `omega_n = 1 / (alpha * dt)`, `kp = mass * omega_n²`, `kd = mass * 2 * damping_ratio * omega_n`.
- **P5.3** — `MarionetteBone` in C++ (`src/marionette_bone.cpp` / `.h`), extending `PhysicalBone3D` from godot-cpp. SPD runs in `_integrate_forces`. Reads target rotation from a cached value set by the composer/wrapper (no per-tick GDScript dispatch):
  - If `current_state == Kinematic`: return (body is frozen, skeleton drives it)
  - If `current_state == Unpowered`: return (pure ragdoll, no control torques)
  - If `current_state == Powered`:
    - Read cached anatomical target written by `MarionetteCore` from `Marionette.set_bone_target(...)` (GDScript wrapper hands it across once per change).
    - Convert anatomical target to joint-local quaternion (joint-local = anatomical post-creation, so identity rotation, just axis-angle construction)
    - Compute current rotation relative to parent `MarionetteBone`
    - Compute SPD torque with strength-scaled kp, kd, max_torque
    - Apply torque via `state.apply_torque()`
  - Contact-triggered alpha reduction: if any contact detected this frame, reduce effective alpha for N frames (configurable) to prevent wall vibration. Implemented in C++.
- **P5.4** — `Marionette` orchestrator (GDScript wrapper `Marionette.gd` + C++ `MarionetteCore::set_global_strength(float)`):
  - `global_strength: float = 1.0` (applied in C++)
  - Per-bone anatomical target storage in C++ cache; GDScript-side `Dictionary<StringName, Vector3>` mirror for tooling.
  - Per-bone strength override forwarded to C++ via bound method.
  - `set_bone_target(bone_name, anatomical_vec3)` API on `Marionette.gd`, calls C++.
  - `set_bone_strength(bone_name, value)` API, calls C++.
  - `set_global_strength(value)` API, calls C++.
- **P5.5** — Gravity handling (C++ `MarionetteCore`): `gravity_scale` property applied to all `MarionetteBone` bodies. Optional `hip_upward_nudge` constant force on root bone while `global_strength > threshold` to counter sagging.
- **P5.6** — Alpha ramp-up helper: when strength changes from low to high (e.g., 0 → 1), effective strength ramps over N seconds to prevent snap-to-pose pop.
- **P5.7** — Hierarchical constraint validator: at `build_ragdoll()`, validate `BoneStateProfile` — if any `Powered` bone has a `Kinematic` ancestor, log warning or auto-fix (promote ancestor to at least `Unpowered`).
- **P5.8** — Muscle Test tab gains mode toggle: "Skeleton3D Preview" (P4 behavior) vs "Ragdoll Test". Ragdoll Test mode:
  - Physics active
  - Character hip-tethered: single 6DOF joint between hip `MarionetteBone` and a fixed pivot point in the scene (high-stiffness linear lock, medium-stiffness angular lock — hip can rotate a bit, not translate or spin freely).
  - Zero gravity (visible ground plane optional).
  - Global strength slider exposed.
  - Sliders drive SPD targets via `Marionette.set_bone_target()` instead of kinematic writes.
  - "Apply Impulse" tool: click-drag on a bone in the viewport applies a test impulse.
- **P5.9** — Rest-pose guard extended: exiting Ragdoll Test mode stops physics, resets all bones to rest, removes tether.
- **P5.10** — Unit tests: GDScript test harness calls into C++ `SPDMath` via bound methods. SPD torque matches hand-computed reference for known inputs (bit-equivalent against a reference vector); alpha/damping → kp/kd conversion correct; anatomical→joint-local target conversion is identity post-creation (roundtrip verified).

### Milestone

- Character in Ragdoll Test mode at global strength 1.0 holds upright pose for 10+ seconds without drift (tether visible but permissive).
- Global strength 0.0: character collapses instantly.
- Global strength 1.0 again: reconstructs pose from collapse within 2-3 seconds.
- 500N impulse applied to torso at strength 0.7: character stumbles (deflects visibly), then recovers to rest pose.
- Muscle Test sliders in Ragdoll mode: "Left Shoulder Flexion" at +90° at strength 0.8 actively holds arm up; pushing down with impulses gets resisted.
- Wall contact test: character poses against a wall — no visible vibration, smooth contact.
- Per-bone strength override: reducing right arm strength to 0.2 makes that arm go limp while rest stays rigid.
- Diagnostic panel shows live per-bone torque and error plots.
- Video artifact: `docs/videos/phase_5_milestone.mp4`.

### Files

```
extensions/marionette/
├── src/
│   ├── spd_math.cpp / .h               (P5.1 — C++ SPD helpers)
│   ├── spd_gain_converter.cpp / .h     (P5.2 — alpha/damping → kp/kd)
│   └── marionette_bone.cpp / .h        (P5.3 — _integrate_forces SPD)
├── gdscript/
│   ├── runtime/
│   │   ├── hip_tether.gd               (P5.8 scaffolding)
│   │   └── strength_ramp.gd            (P5.6)
│   └── editor/
│       ├── ragdoll_test_mode.gd
│       ├── impulse_tool.gd
│       └── diagnostic_overlay.gd
└── tests/
    ├── test_spd_math.gd                (P5.10 — calls into C++ via bound methods)
    └── test_gain_converter.gd
demo/
└── ragdoll_test_scene.tscn
```

---

## Phase 6 — Pose resources, weight profile

**Goal**: capture/apply/mirror anatomical poses as `.tres` resources. Weight distribution editable with anatomical defaults.

### Tasks

- **P6.1** — `RagdollPose` resource: `bone_angles: Dictionary<StringName, Vector3>`, `bone_strength: Dictionary<StringName, float>` (optional), `display_name`, `tags`.
- **P6.2** — Pose capture button in Muscle Test tab: writes current slider state to a new `.tres`.
- **P6.3** — Pose apply button: loads `.tres`, sets all bone targets via `Marionette.set_bone_target()`. Optional per-bone strength overrides applied.
- **P6.4** — Pose mirror operation: given a `RagdollPose`, produces a mirrored version by swapping left/right bone name entries and applying sign-flip on Y and Z components.
- **P6.5** — Forced pose source: `Marionette.set_pose_source(PoseSource)` where `PoseSource` enum is `Default, Animation, Forced, Blend`. When `Forced`, targets come from a pose resource regardless of other inputs.
- **P6.6** — Ship default pose library: `tpose.tres`, `apose.tres`, `fetal.tres`, `cramp_back_arch.tres` (tetanus opisthotonus), `reach_up.tres`, a few emotional-baseline poses for later use.
- **P6.7** — Weight profile editor (inspector plugin for `BoneProfile`'s mass section):
  - Total mass field at top
  - Per-bone fractional sliders, grouped by region
  - L/R symmetric toggle (default on)
  - Running total with green/red indicator (red past 100%, also red if far below e.g. <95%)
  - Soft limit (warn, don't renormalize)
- **P6.8** — Anatomical mass fraction defaults shipped: head ~8%, torso ~43%, each upper arm ~3%, each forearm ~2%, each hand ~0.6%, each thigh ~11%, each shin ~5%, each foot ~1.4%, etc. Summing to ~100%.

### Milestone

- Pose character with sliders, Capture → saved `.tres`. Reload scene, Apply → character drives to that pose via SPD.
- `cramp_back_arch.tres` at global strength 1.2: character arches backward and holds; impulse deflects briefly, snaps back.
- Mirror a left-side-authored pose: right version is anatomically correct (not just reflected geometry — semantic preservation).
- Open saved `.tres` in text editor: keys are bone names, values labeled anatomically.
- Weight profile editor: L/R symmetric change to upper leg updates both sides; total stays at 100% with green indicator; deliberately overshooting to 110% shows red warning.
- Video artifact: `docs/videos/phase_6_milestone.mp4`.

### Files

```
addons/marionette/
├── resources/
│   └── ragdoll_pose.gd
├── runtime/
│   ├── pose_applier.gd
│   ├── pose_mirror.gd
│   └── pose_source.gd
├── editor/
│   ├── pose_capture_controls.gd
│   └── weight_profile_inspector.gd
├── poses/
│   ├── tpose.tres
│   ├── apose.tres
│   ├── fetal.tres
│   ├── cramp_back_arch.tres
│   └── reach_up.tres
```

---

## Phase 7 — Cyclic motion resources

**Goal**: procedural cyclic motion (shiver, tremor, breathing) as resources. Layer additively with poses and animation via anatomical blending.

### Tasks

- **P7.1** — `AnatomicalAxis` enum: `Flex, Rotation, Abduction`. Used in oscillator and macro entries for anatomical labeling.
- **P7.2** — `Waveform` enum: `Sine, Noise, Square, Triangle, Curve`.
- **P7.3** — `BoneOscillator` resource: bone_name, axis, waveform, amplitude_rad, frequency_multiplier, phase_offset, custom_curve (used when waveform == Curve).
- **P7.4** — `RagdollCyclicAnimation` resource: period, amplitude, blend_mode enum (`Additive, Override, Multiplicative`), oscillators array.
- **P7.5** — Cyclic evaluator: per tick, for each oscillator in active cyclic, compute value via waveform, add to bone's anatomical target.
- **P7.6** — `Marionette.play_cyclic(cyclic)` and `stop_cyclic()` API. Multiple cyclics can be active concurrently via the emotion overlay system (Phase 8); the raw API supports one primary cyclic.
- **P7.7** — Cyclic authoring UI in Muscle Test tab: per-bone-axis oscillator controls (frequency, amplitude, phase, waveform). Live preview when Ragdoll Test mode is active. "Capture Oscillator Set" saves as `.tres`. **Phase-relationship preview + Lissajous authoring mode.** Authoring against two raw `phase_offset` numbers is hard; authoring against a 2D Lissajous shape is easy. Add:
  - A 2D phase-relationship preview widget: pick two oscillators (any two — same bone different axes, or different bones same axis), see their `(value_A, value_B)` plotted over one period as a Lissajous curve.
  - A Lissajous-shape authoring mode: drag a shape (circle → ellipse → figure-8 → diagonal line) and have it set the phase offset and frequency multiplier of the second oscillator relative to the first.
  - Reference shapes: 1:1 frequency ratio with 90° phase offset = ellipse; 2:1 ratio = figure-8; 1:1 ratio with 0° phase = diagonal line.
- **P7.8** — Preset library: `shiver.tres` (5-8 Hz, 2-4°, spine+shoulders+jaw-equivalent), `tremor_parkinsonian.tres` (4-6 Hz, hands+forearms), `breathing.tres` (0.25 Hz, thorax+abdomen), `shiver_cold.tres` (faster, tighter), `hip_invite.tres` (`RagdollCyclicAnimation`, period 2.5 s — coupled pelvic ellipse + chest counter-rotation + alternating knee bob; arms deliberately absent so they pick up incidental motion from the chest):

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

  All amplitudes are starting points; tune against context (a `tense` state would halve them).

### Sub-phase P7.9 — `TravelingWaveCyclic`

Body-wide coherent motion produced by parameterizing oscillation by bone position along a `PropagationGraph` (P2.14). Same composition pipeline as `RagdollCyclicAnimation` (additive in anatomical space, ROM-clamped at the end). One sample per bone per active wave per tick.

**Why it exists.** Per-joint independent noise looks dead — that's the failure mode. Sharing phase between neighboring bones via `(s, t)` parameterization makes motion look like a living thing. Coherent noise is the same evaluator with a different spatial sampler.

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

Per-tick evaluator (pseudocode):

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

**Pitfalls.**
- Author `amplitude_curve` to fit within ROM at peak. The pipeline will clamp, but clamping looks bad if it happens mid-oscillation.
- Wave speed = `temporal_frequency / wavenumber`. Authors will reach for "I want a wave at 1 m/s" — they get speed by ratio, not directly.

Tasks:
- **P7.9.1** — `TravelingWaveCyclic` resource definition (GDScript).
- **P7.9.2** — Evaluator integrated into Phase 7 cyclic evaluator (uses `body_rhythm_phase` after P7.10 lands; until then, owns its own `t`).
- **P7.9.3** — Sample preset `spinal_undulation.tres`: period ~3 s, wavenumber such that one full wavelength = total trunk length, amplitude ~5° flexion.
- **P7.9.4** — Sample preset `coherent_squirm.tres`: `Noise2D` spatial function, full-body amplitude.

### Sub-phase P7.10 — `body_rhythm_phase` shared clock

A single phase variable on `Marionette` that all cyclic evaluation reads as its time argument. Lets external systems (TentacleTech, Reverie) sync to the body's internal rhythm without each running its own clock.

API on `Marionette`:

```
@export var body_rhythm_frequency: float = 0.4    # Hz, settable by Reverie
var body_rhythm_phase: float = 0.0                 # 0..TAU, advances every physics tick
signal body_rhythm_cycle_completed(cycle_index: int)
```

Per-tick (in `_physics_process` or wherever the cyclic evaluator runs):

```
body_rhythm_phase += body_rhythm_frequency * TAU * delta
if body_rhythm_phase >= TAU:
    body_rhythm_phase = fmod(body_rhythm_phase, TAU)
    cycle_index += 1
    body_rhythm_cycle_completed.emit(cycle_index)
```

**Cyclic evaluator change.** All `BoneOscillator` and `TravelingWaveCyclic` evaluation reads `body_rhythm_phase` as the time argument, scaled by the resource's own `freq_mult` (oscillator) or `temporal_frequency` (wave) **relative to** `body_rhythm_frequency`. The resource specifies its frequency *as a multiple of the body's rhythm*, not in absolute Hz. This is the right semantics — the hip ellipse and the spinal undulation should slow down together when arousal drops, not drift apart.

**Pitfall (mandatory).** `body_rhythm_phase` must be **integrated** (`phase += freq * dt`), not recomputed (`phase = freq * t`). Otherwise a frequency change snaps the phase, which is visible in both the body and in any tentacle locked to it (e.g. `RhythmSyncedProbe`, `TentacleTech_Architecture.md` §6.11).

Tasks:
- **P7.10.1** — Add `body_rhythm_frequency`, `body_rhythm_phase`, `body_rhythm_cycle_completed` to `Marionette`.
- **P7.10.2** — Integrate phase per physics tick (integrated, never recomputed).
- **P7.10.3** — Migrate `BoneOscillator` and `TravelingWaveCyclic` evaluators to read `body_rhythm_phase`.
- **P7.10.4** — Resource fields renamed/repurposed: oscillator `frequency_multiplier` is now relative to `body_rhythm_frequency`; document the migration. `TravelingWaveCyclic.temporal_frequency` becomes a multiplier rather than absolute Hz.

### Milestone

- `breathing.tres` on standing character (strength 1.0): visible chest rise/fall at 0.25 Hz.
- `cramp_back_arch.tres` (pose) + `shiver.tres` (cyclic) simultaneously: character holds arched cramp while shivering on top, layered additively.
- `tremor_parkinsonian.tres` only: hands tremble at 4-6 Hz, rest of body calm.
- Tune a new cyclic in the panel (set left shoulder abduction to 1 Hz, 15° amplitude), capture, reload: same visible motion reproduced.
- Saved `.tres`: oscillator axis stored as `Flex`/`Rotation`/`Abduction` enum name in the serialized data.
- `hip_invite.tres` produces a clean elliptical hip motion with synchronized chest counter-rotation; switching one pelvic axis from `freq_mult: 1` to `freq_mult: 2` in the authoring panel produces a figure-8 in the Lissajous preview in real time.
- `spinal_undulation.tres` produces visible head-to-tail wave through the trunk. Side-by-side comparison with a manually-authored independent-noise version: the wave reads as a single coherent disturbance, the independent-noise version reads as four separate limb wiggles.
- Changing `body_rhythm_frequency` from 0.4 → 1.6 Hz over 0.5 s produces a smooth speed-up of `hip_invite.tres` with no visible phase snap.
- Video artifact: `docs/videos/phase_7_milestone.mp4`.

### Files

```
addons/marionette/
├── resources/
│   ├── anatomical_axis.gd
│   ├── waveform.gd
│   ├── bone_oscillator.gd
│   ├── ragdoll_cyclic_animation.gd
│   └── traveling_wave_cyclic.gd
├── runtime/
│   ├── cyclic_evaluator.gd
│   └── body_rhythm_clock.gd
├── editor/
│   ├── cyclic_capture_controls.gd
│   └── lissajous_preview_widget.gd
├── cyclic/
│   ├── shiver.tres
│   ├── shiver_cold.tres
│   ├── tremor_parkinsonian.tres
│   ├── breathing.tres
│   ├── hip_invite.tres
│   ├── spinal_undulation.tres
│   └── coherent_squirm.tres
```

---

## Phase 8 — Emotional body state + overlay composition

**Goal**: bundle pose + cyclic + strength modulation as `EmotionalBodyState` resources. Transient `EmotionalBodyOverlay`s with envelopes push on top. Integration point for future stimulus→response system.

### Tasks

- **P8.1** — `EmotionalBodyState` resource:
  - `base_pose: RagdollPose` (optional)
  - `base_pose_weight: float`
  - `cyclics: Array[CyclicEntry]` where `CyclicEntry = {animation, weight, phase_speed}`
  - `strength_modulation: Dictionary<StringName, float>` (per-bone alpha/damping multipliers)
  - `global_strength_multiplier: float`
  - `display_name`, `tags`
- **P8.2** — `EmotionalBodyOverlay` resource:
  - Optional `pose: RagdollPose`
  - Optional `cyclic: RagdollCyclicAnimation`
  - Optional `strength_modulation: Dictionary`
  - `envelope: Curve` (weight over 0..1 time)
  - `duration: float`
  - `display_name`, `tags`
- **P8.3** — `Marionette` composition pipeline (per-tick, in anatomical space):
  - Start with zeroed target per bone
  - Add current `EmotionalBodyState.base_pose * base_pose_weight`
  - For each active overlay: add `overlay.pose * overlay.weight * overlay.envelope(overlay_t)`
  - For each cyclic (from current state + overlays): add oscillator evaluations
  - For each bone: clamp anatomical target to ROM (from `BoneEntry` limits)
  - Write composed target via existing `set_bone_target()` path → SPD consumes
- **P8.4** — Strength modulation composition: base strength × state's global_strength_multiplier × product of overlay weight-scaled modulations per bone.
- **P8.5** — Public API on `Marionette`:
  - `set_body_state(state: EmotionalBodyState, blend_duration: float)` — crossfade current to new state over duration
  - `push_overlay(overlay: EmotionalBodyOverlay, weight: float) -> OverlayHandle`
  - `remove_overlay(handle: OverlayHandle)`
  - Auto-remove when envelope ends
- **P8.6** — Signals:
  - `body_state_changed(state_name: StringName)` emitted when a state transition begins
  - `overlay_started(overlay_name: StringName, handle: OverlayHandle)`
  - `overlay_ended(overlay_name: StringName, handle: OverlayHandle)`
- **P8.7** — Ship preset bundles:
  - States: `calm.tres`, `tense.tres`, `exhausted.tres`, `terrified.tres`, `aroused.tres`
  - Overlays: `pain_flinch.tres`, `surprise.tres`, `orgasm_full.tres`, `shiver_reflex.tres`
- **P8.8** — Overlay debugging: diagnostic panel shows active overlays, their current envelope value, remaining duration.

### Milestone

- Set `terrified.tres` as body state: character adopts hunched pose, slight tremor, reduced leg strength (slight wobble). Transition from `calm.tres` takes 1s and is smooth.
- While in `terrified`, push `pain_flinch.tres` overlay at weight 0.8: character briefly flinches (envelope peaks, decays), returns to terrified baseline when envelope ends.
- Multiple simultaneous overlays: push `pain_flinch` and `surprise` with overlapping envelopes: additive composition produces blended reaction without visible conflict.
- Strength modulation: `exhausted.tres` sets global_strength_multiplier to 0.5; character's SPD is visibly weaker (slower response to slider changes, more affected by impulses).
- Emitted signals logged and subscribable from test GDScript.
- Video artifact: `docs/videos/phase_8_milestone.mp4`.

### Files

```
addons/marionette/
├── resources/
│   ├── emotional_body_state.gd
│   ├── emotional_body_overlay.gd
│   ├── cyclic_entry.gd
│   └── overlay_handle.gd
├── runtime/
│   ├── state_composer.gd
│   ├── overlay_stack.gd
│   └── anatomical_rom_clamper.gd
├── editor/
│   └── overlay_debug_panel.gd
├── emotions/
│   ├── calm.tres, tense.tres, exhausted.tres, terrified.tres, aroused.tres
├── overlays/
│   ├── pain_flinch.tres, surprise.tres, orgasm_full.tres, shiver_reflex.tres
```

### P8.X — Attention-driven neck target

New `NeckAttentionDriver` GDScript component, attached to the hero. Subscribes to `CharacterModulation.attention_*` channels on the StimulusBus (see `docs/architecture/TentacleTech_Architecture.md §8.2` and `docs/architecture/Reverie_Planning.md §2.6`). Each tick:

1. Reads current attention target world-position from the bus.
2. Computes desired skull forward vector (normalized direction from skull bone to target).
3. Distributes the resulting orientation delta across the cervical chain — lower cervicals receive smaller contribution, upper cervicals larger. Simple weighted split, no full IK.
4. Converts each cervical bone's contribution to anatomical target (flex/rot/abd triple).
5. Writes targets via `Marionette.set_bone_target()` and scales stiffness by `attention_intensity`.

Body does not rotate. Eye bones are not Marionette-driven; they remain kinematic under the facial system.

**Milestone:** with the bus manually set to `attention_target_type = World, attention_target_world_position = <moving test point>, attention_intensity = 1.0`, the hero's head smoothly tracks the point. At `intensity = 0`, head returns to rest pose. Video artifact: `docs/marionette/videos/phase_8x_attention.mp4`.

---

## Phase 9 — Animation integration

**Goal**: `AnimationPlayer` output feeds SPD targets. Character tracks animations while physically responsive.

### Tasks

- **P9.1** — Pose source = `Animation`: per tick, read `Skeleton3D.get_bone_pose_rotation(idx)`, convert bone-local rotation to anatomical angles using bone-to-anatomical permutation from `BoneEntry` (inverse direction from ragdoll creation; cheap sign-flip/swap).
- **P9.2** — Per-bone pose source override: `set_pose_source(bone_name, source)` allows some bones on `Animation` while others on `Forced` or `Default`.
- **P9.3** — Blend source: `pose_source = Blend` with `blend_weight: float` and two source pose specifications. All blending in anatomical space.
- **P9.4** — Free-floating root policy: hip's target position decoupled from animation's root position. Animation provides hip *rotation* but not world-space hip position — that emerges from physics. Character root node follows hip body's physics position, not the other way around.
- **P9.5** — Integration with emotion system: `Animation` pose source provides baseline targets; `EmotionalBodyState.base_pose` and overlays layer additively on top in anatomical space.

### Milestone

- Walking animation at strength 1.0: character walks.
- At strength 0.3: tries to walk, stumbles realistically.
- Mid-walk hip impulse: stumble, recover or fall based on strength.
- Mid-walk, left arm set to `Forced` with `reach_up.tres`: character walks with left arm stuck reaching up, right arm swings normally.
- Mid-walk + `shiver.tres` via emotion overlay: visible shiver layered on walking animation.
- Free-floating root: applying a horizontal impulse moves the character in world space (hips translate from physics); the animation continues playing locally.
- Video artifact: `docs/videos/phase_9_milestone.mp4`.

### Files

```
addons/marionette/
├── runtime/
│   ├── animation_target_reader.gd
│   ├── pose_blender.gd
│   └── free_floating_root.gd
demo/
└── walking_character.tscn
```

---

## Phase 10 — Composer, cost-weighted IK soup, engagement vector, strain

**Goal**: `MarionetteComposer` (C++) takes a soup of weighted goals (anchors, end-effector positions, posture priors from pattern library, engagement-vector pumping) and produces per-bone target rotations consumed by SPD. Strain is published as a continuous Stimulus Bus channel. Frequency compliance integrates `body_rhythm_frequency` from a Reverie-proposed value through a mindset-gated curve.

Self-balancing, catch-step, support polygon, COM PD, and ground-tracking foot IK are **deferred to Phase 14**.

### Architectural commitments

These are binding for this phase. Implement them; don't renegotiate.

1. **Composer is soup-of-goals, not layered priority.** Single weighted-cost optimization per tick. Hard-anchor goals get high weight (~100); primary reach goals moderate (~10); engagement-pump targets ~5; posture priors low (~1). Soft constraints use **Huber loss**, not L2 — prevents ugly compromise poses when goals conflict.
2. **Composer feeds SPD as soft targets, not hard constraints.** SPD chases; failure is graceful. SPD itself is unchanged in structure (per-bone PD), just C++-resident from P5.
3. **Engagement pump is 100% predictive.** Composer maintains cycle-averaged drive-direction estimators (`drive_axis_linear`, `drive_axis_angular`) updated once per cycle from pelvis velocity. Per-bone target oscillations are written using `cos(body_rhythm_phase + engagement_phase)`, not by reading instantaneous velocity. No filter latency in the active output.
4. **Posture priors are pattern-library superposition.** Mindset distribution writes weights into a stack of `PosturePattern` resources (toe curl, back arch, jaw slack, hand grasp, hip drop, neck loll, etc.). Composer sums weighted patterns into the posture-prior cost term. Reverie reaction profiles point at pattern stacks.
5. **Strain feeds Reverie via continuous Stimulus Bus channel `body_strain`.** Composer publishes scalar per tick = Σ saturation across all SPD-driven joints. Reverie consumes for vocal grunt / breath / facial tension / mindset drift toward Overwhelmed.
6. **Frequency lerp is slew-rate-limited per mindset.** `df_dt_max(mindset)` capped — body cannot jump tempos suddenly. Slow for resistant/overwhelmed; fast for aroused/edge.
7. **Two-stage strain.** IK solves once without strain cost (cheap path, most ticks). If any joint saturates in the solved pose, re-solve with strain penalty added. Avoids paying inverse-dynamics cost every tick.
8. **Pelvis is the single rhythm-readout anchor for v1.** Composer reads only pelvis linear + angular velocity for drive-axis estimation. Future expansion (sternum, head) is one-line addition; not in v1.

### Tasks

- **P10.1** — `IKChainSolver` (C++, `src/ik_chain_solver.cpp`/.h): damped-least-squares Jacobian solver. Inputs: chain bones, goal stack, ROM limits per joint. Output: per-joint angle deltas. Soft constraints use Huber loss, not L2. Single iteration per tick (DLS converges acceptably in 1–2 iterations for soft-target chases). Hard goals (anchors) get weight ~100; primary reach goals ~10; posture prior ~1; engagement-pump targets ~5.
- **P10.2** — Goal types: `PositionGoal(end_effector_bone, target_world_pos, weight)`, `OrientationGoal(end_effector_bone, target_quat, weight)`, `PinAnchor(bone, world_pos, hard_weight=100)`. All soft (composer feeds SPD as targets, not hard constraints).
- **P10.3** — Posture-prior cost: composer maintains a stack of `PosturePattern` resources with weights. Each pattern is a per-bone delta map (StringName → Quaternion delta). Composer sums weighted deltas; the composed offset is applied as a low-weight cost term toward the perturbed rest pose.
- **P10.4** — Engagement vector input: `MarionetteComposer::set_engagement_vector(magnitude, phase, phase_noise)`. Reverie writes per tick. Composer reads.
- **P10.5** — `RhythmReadout` (C++, `src/rhythm_readout.cpp`/.h): biquad band-pass filter on pelvis linear + angular velocity, bandwidth scaled to current `body_rhythm_frequency` (Q ≈ 2–3). Output cycle-averaged `drive_axis_linear` (3-vec) and `drive_axis_angular` (3-vec) updated once per cycle (not per tick — averaging window = one rhythm period).
- **P10.6** — Predictive engagement pump:

  ```
  for each bone b in PropagationGraph with weight w_b > 0:
    pump_offset_lin = w_b × magnitude × |drive_axis_linear|
                    × drive_axis_linear_unit × cos(body_rhythm_phase + engagement_phase)
    pump_offset_ang = (analogous, using angular axis)
    bone_target[b] += pump_offset_lin (translated into per-bone rotation contribution)
    bone_target[b] += pump_offset_ang
    if engagement_phase_noise > 0:
      bone_target[b] += per-bone-decoherent jitter scaled by phase_noise
  ```

  Pump direction is observed (estimator), pump phase is committed (read from `body_rhythm_phase` directly). No filter lag in the active output.
- **P10.7** — Strain computation: per-tick, composer queries each `MarionetteBone` for current required-vs-clamp ratio. `body_strain = Σ smoothstep(0.7, 1.0, required_torque[j] / max_torque[j])²`. Published on Stimulus Bus continuous channel `body_strain`.
- **P10.8** — Two-stage strain solve: solve IK once without strain cost. Compute strain. If any joint saturates above threshold, re-solve with `strain_cost` term added. Most ticks pay only the cheap pass.
- **P10.9** — Frequency compliance integration: composer reads `body_rhythm_frequency_proposed` (Reverie writes) and lerps `body_rhythm_frequency` toward it at rate `compliance × dt × responsiveness`, capped by `df_dt_max` from the current mindset's frequency compliance curve.
- **P10.10** — `body_rhythm_phase` integration in C++ — never reset, monotonically increasing modulo 2π for evaluation, integrated continuously from `body_rhythm_frequency × dt`. (P7.10 commits this; this task confirms the integrator lives in `MarionetteComposer`.)
- **P10.11** — Bind composer API to GDScript on `Marionette.gd`: `set_engagement_vector(magnitude, phase, phase_noise)`, `add_position_goal(end_effector, world_pos, weight)`, `add_orientation_goal(end_effector, world_quat, weight)`, `add_pin_anchor(bone, world_pos, weight)`, `clear_goals()`, `set_posture_pattern_weights(Array of {pattern, weight})`, `set_proposed_rhythm_frequency(hz)`, `set_frequency_compliance_curve(curve)`, `get_body_rhythm_phase()`, `get_body_rhythm_frequency()`, `get_body_strain()`, `get_strain_per_bone()`.
- **P10.12** — `RhythmAnchorBone` config resource: lists which bones the rhythm-readout reads from. Default: pelvis only. Future-extensible to sternum/head without breaking the API.
- **P10.13** — Composer diagnostic gizmo: in editor mode, draw `drive_axis_linear`, `drive_axis_angular`, current strain per joint as colored badge, current `body_rhythm_phase` and frequency, current engagement vector. Editor-only, no runtime cost.

### Composer tick ordering

Document the order in the composer's C++ header comment. Per physics tick:

1. Integrate `body_rhythm_frequency` toward `body_rhythm_frequency_proposed` (slew-limited by `df_dt_max`).
2. Integrate `body_rhythm_phase` from current `body_rhythm_frequency`.
3. Update `RhythmReadout` estimators (cycle-avg if a cycle just completed).
4. Build goal soup (pin anchors, position/orientation goals, posture-prior cost from pattern stack).
5. Solve IK (cheap pass, no strain cost).
6. Compute strain.
7. If saturated, re-solve with strain term.
8. Apply engagement-pump offsets to bone targets.
9. Hand targets to SPD.
10. Publish `body_strain` on the Stimulus Bus.

### Cost-term formulas

```
hard_anchor_cost  = weight_anchor × |bone.world_pos − target|²       (Huber for soft, L2 acceptable for hard)
position_goal     = huber(weight_goal,    |end_effector.world_pos − target|, δ_pos)
orientation_goal  = huber(weight_orient,  |angle(end_effector.quat, target_quat)|, δ_ang)
posture_prior     = Σ_b weight_posture × |bone.quat − (rest.quat × pattern_delta[b])|²
engagement_pump   = handled separately — written directly into bone_target as oscillating offset, not as a cost term
strain_penalty    = Σ_j smoothstep(0.7, 1.0, required_torque[j] / max_torque[j])²
                    (only included in second-stage solve)

total_objective = Σ all_cost_terms
```

Huber loss with parameter δ:
```
huber(weight, error, δ) = weight × {  0.5 × error²              if |error| ≤ δ
                                    {  δ × (|error| − 0.5 × δ)  otherwise
```

Default δ starting points (tunable via `@export` per cost term): `δ_pos = 0.05 m`, `δ_ang = 0.1 rad`, `δ_posture = 0.05 rad`. Each cost term has its own scale.

### IK solver — DLS Jacobian

```
J  = ∂goals/∂joint_angles    // stacked Jacobian, one row per scalar goal
λ  = damping (0.01..0.1, scaled by goal-error magnitude)
Δθ = J^T (J J^T + λ² I)⁻¹ × goal_error
```

For a 30-DOF chain × ~10 scalar goals, the matrix `(J J^T + λ² I)` is 10×10 — invert via Cholesky or LU; well under 1000 ops in C++.

### Performance budget (informational, profile to confirm)

Per character per physics tick:
- IK soup (DLS Jacobian on ~30 DOFs, ~5–10 cost terms, 1–2 iterations): target ≤ 0.3 ms in C++
- Engagement readout + cycle-avg: ≤ 0.05 ms
- Posture pattern stack blend: ≤ 0.05 ms
- Strain (two-stage, mostly single-stage): ≤ 0.1 ms avg
- SPD per bone × 84 bones: ≤ 0.1 ms
- **Total composer + SPD ≤ 0.6 ms per character.**

If profiling shows the Jacobian operation dominates, the cheap mitigation is **chain decomposition**: solve `(anchor → root)` and `(root → end_effector)` as separate sub-problems sharing the root, instead of one full-body block. Reserved as a fallback; not in P10.1.

### Pitfalls

- **Soup weights need calibration before posture costs are tuned.** If hard-anchor weights are too low, the body floats away from anchors when other goals conflict. Default starting weights: anchors 100, primary goals 10, engagement-pump targets 5, posture priors 1. Verify before authoring patterns.
- **Drive-axis estimator needs warm-up.** First cycle after rhythm starts has no estimate; `engagement_magnitude` should ramp from 0 over ~one cycle to avoid jumps. Author the ramp inside the composer, not as a Reverie obligation.
- **Pattern stack ordering matters when patterns conflict.** Two patterns prescribing opposing deltas on the same bone produce a weighted average; soup will sum and compromise. If a pattern *must* override (e.g., "back arch" overrides a less-specific "spine relax"), give it a much higher weight rather than relying on order.
- **Frequency slew rate limit interacts with phase integration.** When `body_rhythm_frequency` is changing, `body_rhythm_phase` keeps advancing smoothly because it integrates the *current* frequency every tick. There's no phase glitch on frequency change. Document this in the composer comment.
- **Strain channel can oscillate near threshold.** Add hysteresis (Schmitt-trigger style): emit "high strain" when strain > 0.6; emit "strain cleared" only when strain < 0.4. Otherwise Reverie sees flutter at a single threshold.
- **Per-bone pumpable flag is unnecessary.** `PropagationGraph` weights of 0 already exclude bones from the pump. Don't add a parallel flag.

### Milestone

- GDScript test harness writes anchor goals + a position goal; composer produces a pose; SPD chases; final pose error ≤ 5 cm at the goal end-effector under no contact.
- Engagement vector at `(magnitude=0.7, phase=π/2, phase_noise=0)` on a tethered character produces visible velocity-phase pumping along whatever DOF the test rig drives the pelvis along (vertical drive → vertical bob; rotational drive → pelvic rocking). Same code path; different DOF emerges.
- Strain channel publishes scalar > 0 when goal is geometrically reachable but torque-bounded; composer's two-stage solve redistributes load; channel value drops once a feasible distribution is found.
- Frequency compliance: in a "calm" mindset (preferred band 0.3–0.6 Hz), proposed frequency = 1.5 Hz produces only slow drift in `body_rhythm_frequency` (does not converge). In an "aroused" mindset (preferred 0.8–1.5 Hz), same proposed frequency converges within ~2–3 cycles.
- Video artifact: `docs/videos/phase_10_milestone.mp4`.

### Files

```
extensions/marionette/
├── src/
│   ├── marionette_composer.cpp / .h    (P10.1–P10.11 — soup, engagement, strain, frequency compliance)
│   ├── ik_chain_solver.cpp / .h        (P10.1 — DLS Jacobian, Huber loss)
│   └── rhythm_readout.cpp / .h         (P10.5 — band-pass + cycle-avg drive axis)
├── gdscript/
│   ├── resources/
│   │   ├── posture_pattern.gd          (P10.3)
│   │   ├── engagement_profile.gd       (P10.4 — embedded in ReactionProfile)
│   │   ├── frequency_compliance_curve.gd (P10.9)
│   │   └── rhythm_anchor_bone.gd       (P10.12)
│   ├── posture_patterns/               (P10.3 default library: toe_curl, back_arch, jaw_slack, hand_grasp, hip_drop_*, neck_loll, eye_roll)
│   └── editor/
│       └── composer_diagnostic_gizmo.gd (P10.13)
```

---

## Phase 11 — Interaction helpers

**Goal**: grab/hold, impact reactions, injury (local strength clamping). These are convenience nodes that build on the existing API.

### Tasks

- **P11.1** — `GrabTarget` node: attachable to `Marionette`, drives a specific bone's target toward a grabber transform. Downstream bones get reduced strength for natural dangling.
- **P11.2** — Impact reactor helper: `apply_hit(bone, impulse, location)` applies impulse + pushes a transient strength-reduction overlay on the hit bone and neighbors.
- **P11.3** — `InjuryManager` node: per-bone `injury_level: float` that clamps max effective strength. Persistent; unaffected by state transitions.
- **P11.4** — `BoneStateProfile` runtime swap helpers: transitions between profiles are staggered over time (prevents popping).

### Milestone

- Rigidbody "hand" approaches character's left wrist, activates `GrabTarget`: arm tracks hand with shoulder resistance.
- Projectile hit on right shoulder via `apply_hit`: local strength drops, arm goes limp briefly, recovers over ~1s.
- `injury_level = 0.8` on left knee: character walks with a limp (knee can't fully extend/power).
- Runtime `BoneStateProfile` swap from full-powered to "disabled arm" profile: transition is smooth over 0.5s.
- Video artifact: `docs/videos/phase_11_milestone.mp4`.

### Files

```
addons/marionette/
├── runtime/
│   ├── grab_target.gd
│   ├── impact_reactor.gd
│   ├── injury_manager.gd
│   └── bone_state_transitioner.gd
demo/
└── interaction_test.tscn
```

---

## Phase 13 — Polish and editor tooling

**Goal**: production-quality authoring experience.

### Tasks

- **P13.1** — ROM envelope cone/wedge gizmos beyond the RGB sectors: combined swing cone per archetype.
- **P13.2** — "Test Frame Setup" button: applies +30° flexion everywhere simultaneously; highlights bones that move wrong.
- **P13.3** — Mode A/B comparison report for `BoneProfile` (developer tool for evaluating permutation choices on non-ARP rigs).
- **P13.4** — User guide with screenshots.
- **P13.5** — Migration guide from Unity ConfigurableJoint and Hairibar.Ragdoll (anatomical concept map for Unity devs).
- **P13.6** — Frame mode decision guide; anatomical terminology glossary.

### Milestone

- External developer produces working active ragdoll in under 15 minutes from an unfamiliar ARP character.
- Documentation covers: profile authoring, ragdoll creation wizard, muscle test, pose/cyclic authoring, emotion states, balancing, common problems.

---

## Phase 14 — Self-balancing, catch-step, foot IK as ground-tracking

**Goal**: character stands against small pushes, takes a procedural catch-step against larger pushes, falls cleanly on overwhelming pushes. Feet track uneven ground.

This phase contains the task list previously assigned to Phase 10, deferred until the composer + IK + engagement system (new P10) has stabilized. Foot IK in this phase is *as a goal in the composer's soup* — feet contribute a `PositionGoal` toward ground-raycast points with moderate weight. SPD-feed wiring is satisfied by P10's existing soup-of-goals path; this phase only adds the new goals + balance machinery on top.

### Tasks

- **P14.1** — Foot IK as a composer goal. Verify Godot 4.6 provides a usable IK `SkeletonModifier3D` for any in-editor authoring needs; runtime foot IK is contributed as a `PositionGoal` in the composer's soup, weighted moderately, not as a standalone solver. (Original P10.1's "FABRIK as `SkeletonModifier3D`" path is no longer needed; the composer subsumes it.)
- **P14.2** — Per-leg foot goal config: target world position, target orientation, hip bone, foot bone. Output: a `PositionGoal` (and optionally `OrientationGoal`) added to the composer per leg per tick.
- **P14.3** — Ground raycast per foot: from ankle position downward, hit provides target foot position + normal for orientation. Feeds P14.2.
- **P14.4** — Foot ground-track goal added to composer's goal stack at a per-leg weight (replaces original P10.4's "IK outputs feed SPD as targets" — that wiring is satisfied by the composer's existing soup).
- **P14.5** — COM computation from mass-weighted `MarionetteBone` positions.
- **P14.6** — Support polygon: convex hull of foot contact points (or foot rectangles when grounded).
- **P14.7** — Balance PD controller: COM offset from support polygon center → hip target adjustment + ankle torque bias. Separate PD on COM velocity.
- **P14.8** — Procedural catch-step:
  - Trigger condition: COM exits support polygon beyond threshold AND COM velocity exceeds threshold
  - Compute step target: COM projection + velocity × step_lead_time (crude capture point)
  - Generate foot trajectory: Hermite through (current foot, apex above midpoint, target), duration = f(step length)
  - During step: swing leg strength stays high (tracks trajectory), stance leg stays high, hip target shifts toward stance foot
  - On foot contact or trajectory complete: switch stance, return to Standing
- **P14.9** — State machine: `Standing`, `Stepping`, `Falling`. Transitions based on COM-outside-polygon duration + body tilt.
- **P14.10** — Balance tab in right dock: support polygon visualization, COM gizmo, tilt threshold slider, step parameters (lead time, apex height, min/max step length).

### Milestone

- Character stands in place with strength 1.0: stable for 30+ seconds, small COM oscillations as balance PD compensates.
- Small push (200N impulse to chest): character sways but recovers without stepping.
- Medium push (500N impulse): character takes one catch-step in the push direction, recovers upright.
- Large push (1500N impulse): character steps but loses balance, enters Falling, collapses cleanly.
- Uneven ground: feet IK to terrain, character remains level and balanced.
- Video artifact: `docs/videos/phase_14_milestone.mp4`.

### Files

```
extensions/marionette/
├── gdscript/
│   ├── runtime/
│   │   ├── foot_ground_goal.gd         (P14.2/P14.3 — adds composer goal per leg)
│   │   ├── com_computer.gd             (P14.5)
│   │   ├── support_polygon.gd          (P14.6)
│   │   ├── balance_controller.gd       (P14.7)
│   │   ├── catch_step_planner.gd       (P14.8)
│   │   └── balance_state_machine.gd    (P14.9)
│   └── editor/
│       └── balance_tab.gd              (P14.10)
demo/
└── balancing_character.tscn
```

---

## Soft-tissue jiggle bone clusters

Non-rim soft tissue regions (gluteus, breast, belly, jowls, etc.) currently have no autonomous dynamics: TentacleTech's bulger system (`docs/architecture/TentacleTech_Architecture.md` §7) deforms them while a contact is active, but bulger eviction fade is 2 frames (§7.5) — once contact ends, motion stops. Real fat tissue keeps wobbling for ~1 second after impact.

**Solution: jiggle bone clusters.** Per soft region, 1–2 child bones with translation-only SPD (rotational SPD deferred — see below), parented to a host bone (hip / ribcage / pelvis). Authored once per hero in Blender; skin weights paint the soft region's vertices to the jiggle bone with falloff.

```
hip_L
└── glute_L_jiggle    (offset from hip_L; SPD on translation)
```

Per tick:

```
for each jiggle bone j:
    parent_world = j.parent.global_transform
    target_world = parent_world * j.rest_local_offset
    // SPD with parent acceleration as feed-forward
    j.world_position = spd_step(j.world_position, target_world,
                                j.velocity, j.k, j.d, dt)
    j.local_position = parent_world.inverse() * j.world_position
```

Same SPD code Marionette already runs on the spine; copy with different parameters per region. Stiffness and damping authored per-hero (broader hip / fuller bust → softer).

**Cost.** Trivial. ~10–20 jiggle bones per hero × SPD step = sub-microsecond.

**Authoring gotcha (mandatory).** Jiggle bones must be in the skeleton hierarchy at *modeling time*. Skin weights are painted to them in Blender during the same pass that paints to body bones. Adding a jiggle bone at runtime does not retroactively skin existing geometry to it. The `JiggleProfile` resource configures *parameters* of jiggle bones the model already exposes; it cannot create new ones.

**Rotational SPD (v2).** Real fat jiggle has rotational components — a glute swings as much as it translates relative to the parent hip. v1 ships translation-only because it covers most of the visible motion at lowest implementation cost; v2 adds a rotation-quaternion SPD on the same bone. Promotion to v2 is gated on visible motion-quality shortfall, not feature completeness.

**Why not SoftBody3D.** Explicitly forbidden by repo convention (top-level `CLAUDE.md`).

**Why not extend bulger eviction fade.** Bulgers are *displacement vectors* applied along the contact normal; freely 3D wobble (with inertia preserved across direction changes) requires a frame-of-reference (the parent bone), which a displacement vector lacks. Not a fade-time problem; a representation problem.

**Authoring.** Jiggle bones are added by the same Blender script that authors orifice rim anchors (`docs/architecture/TentacleTech_Architecture.md` §10.4 / §10.6, post-2026-05-03 amendment), under a separate "soft regions" pass. Per-hero parameter overrides land on a `JiggleProfile` resource analogous to `OrificeProfile`.

**Acceptance.** Slap the gluteus with a tentacle and detach. Visible wobble persists ≥ 0.6 s after detachment, decaying smoothly.

---

## Cross-cutting testing strategy

### Unit tests (CI on every commit)
- `test_archetype_solvers.gd`, `test_permutation_matcher.gd`, `test_muscle_frame_builder.gd`
- `test_spd_math.gd`, `test_gain_converter.gd`
- `test_anatomical_roundtrip.gd` (anatomical → joint-local → anatomical = identity)
- `test_pose_mirror.gd` (double-mirror returns original)
- `test_overlay_composition.gd`

### Integration tests (per phase milestone, manual)
- Three rest-pose variants (T, A, bent-knee) produce identical slider responses
- Passive drop plausibility (Phase 3)
- Strength sweep collapse/recover (Phase 5)
- Emotion state + overlay composition visual check (Phase 8)
- Balance push tests at three magnitudes (Phase 10)

### Regression videos
Each phase milestone produces `docs/videos/phase_N_milestone.mp4`. Future changes validated against these.
