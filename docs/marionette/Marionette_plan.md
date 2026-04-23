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

**Note**: no GDExtension / C++ scaffolding here. The addon ships as pure GDScript. A targeted C++ port of SPD math is held in reserve as an optional Phase 12, triggered only by profiling evidence.

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

### Milestone

- Opening a `BoneProfile` in the inspector and clicking "Generate from Skeleton" fills all 84 entries for `MarionetteHumanoidProfile` without errors.
- Gizmos render in the viewport for a test character: red arrows perpendicular to the sagittal plane on limb bones, along-bone green arrows running down each limb, abduction blue arrows perpendicular.
- Diagnostic panel shows permutation details for the selected bone using axis terminology.
- Unit tests pass: archetype solvers across T-pose, A-pose, bent-knee reference skeletons; permutation matcher picks identity for well-rigged input and non-identity for known-rolled input.
- Video artifact: `docs/videos/phase_2_milestone.mp4` showing generation action + gizmo review across 3 rest-pose variants.

### Files

```
addons/marionette/
├── resources/
│   ├── bone_archetype.gd
│   ├── signed_axis.gd
│   ├── bone_entry.gd
│   └── bone_profile.gd
├── runtime/
│   ├── muscle_frame_builder.gd
│   ├── permutation_matcher.gd
│   ├── archetype_defaults.gd
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
│   └── marionette_humanoid_bone_profile.tres
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

### Tasks

- **P5.1** — `SPDMath` static helpers: `error_quaternion(current, target)`, `compute_torque(error_axis_angle, omega, kp, kd, dt)` using SPD formulation.
- **P5.2** — Alpha/damping_ratio → kp/kd converter. Inputs: alpha, damping_ratio, bone mass, physics dt. Output: kp, kd. Formulation: `omega_n = 1 / (alpha * dt)`, `kp = mass * omega_n²`, `kd = mass * 2 * damping_ratio * omega_n`.
- **P5.3** — `MarionetteBone._integrate_forces(state)` implementation:
  - If `current_state == Kinematic`: return (body is frozen, skeleton drives it)
  - If `current_state == Unpowered`: return (pure ragdoll, no control torques)
  - If `current_state == Powered`:
    - Read anatomical target from `Marionette.get_bone_target(bone_name)`
    - Convert anatomical target to joint-local quaternion (joint-local = anatomical post-creation, so identity rotation, just axis-angle construction)
    - Compute current rotation relative to parent `MarionetteBone`
    - Compute SPD torque with strength-scaled kp, kd, max_torque
    - Apply torque via `state.apply_torque()`
  - Contact-triggered alpha reduction: if any contact detected this frame, reduce effective alpha for N frames (configurable) to prevent wall vibration.
- **P5.4** — `Marionette` orchestrator gains:
  - `global_strength: float = 1.0`
  - Per-bone anatomical target storage: `Dictionary<StringName, Vector3>` (flex, rot, abd)
  - Per-bone strength override: `Dictionary<StringName, float>`
  - `set_bone_target(bone_name, anatomical_vec3)` API
  - `set_bone_strength(bone_name, value)` API
  - `set_global_strength(value)` API
- **P5.5** — Gravity handling: `gravity_scale` property on `Marionette` applied to all `MarionetteBone` bodies. Optional `hip_upward_nudge` constant force on root bone while `global_strength > threshold` to counter sagging.
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
- **P5.10** — Unit tests: SPD torque matches hand-computed reference for known inputs; alpha/damping → kp/kd conversion correct; anatomical→joint-local target conversion is identity post-creation (roundtrip verified).

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
addons/marionette/
├── runtime/
│   ├── spd_math.gd
│   ├── spd_gain_converter.gd
│   ├── hip_tether.gd
│   └── strength_ramp.gd
├── editor/
│   ├── ragdoll_test_mode.gd
│   ├── impulse_tool.gd
│   └── diagnostic_overlay.gd
tests/
├── test_spd_math.gd
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
- **P7.7** — Cyclic authoring UI in Muscle Test tab: per-bone-axis oscillator controls (frequency, amplitude, phase, waveform). Live preview when Ragdoll Test mode is active. "Capture Oscillator Set" saves as `.tres`.
- **P7.8** — Preset library: `shiver.tres` (5-8 Hz, 2-4°, spine+shoulders+jaw-equivalent), `tremor_parkinsonian.tres` (4-6 Hz, hands+forearms), `breathing.tres` (0.25 Hz, thorax+abdomen), `shiver_cold.tres` (faster, tighter).

### Milestone

- `breathing.tres` on standing character (strength 1.0): visible chest rise/fall at 0.25 Hz.
- `cramp_back_arch.tres` (pose) + `shiver.tres` (cyclic) simultaneously: character holds arched cramp while shivering on top, layered additively.
- `tremor_parkinsonian.tres` only: hands tremble at 4-6 Hz, rest of body calm.
- Tune a new cyclic in the panel (set left shoulder abduction to 1 Hz, 15° amplitude), capture, reload: same visible motion reproduced.
- Saved `.tres`: oscillator axis stored as `Flex`/`Rotation`/`Abduction` enum name in the serialized data.
- Video artifact: `docs/videos/phase_7_milestone.mp4`.

### Files

```
addons/marionette/
├── resources/
│   ├── anatomical_axis.gd
│   ├── waveform.gd
│   ├── bone_oscillator.gd
│   └── ragdoll_cyclic_animation.gd
├── runtime/
│   └── cyclic_evaluator.gd
├── editor/
│   └── cyclic_capture_controls.gd
├── cyclic/
│   ├── shiver.tres
│   ├── shiver_cold.tres
│   ├── tremor_parkinsonian.tres
│   └── breathing.tres
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

## Phase 10 — Self-balancing and foot IK

**Goal**: character stands against small pushes, takes a procedural catch-step against larger pushes, falls cleanly on overwhelming pushes.

### Tasks

- **P10.1** — Foot IK modifier. Verify Godot 4.6 provides a usable IK `SkeletonModifier3D`; if yes, use it; if no, implement 2-segment FABRIK as a custom `SkeletonModifier3D`.
- **P10.2** — Per-leg foot IK config: target position (world space), target orientation, hip bone, foot bone. Outputs hip/knee/ankle bone poses.
- **P10.3** — Ground raycast per foot: from ankle position downward, hit provides target foot position + normal for orientation.
- **P10.4** — IK outputs feed SPD as targets (target generator pattern). Not hard constraints.
- **P10.5** — COM computation from mass-weighted `MarionetteBone` positions.
- **P10.6** — Support polygon: convex hull of foot contact points (or foot rectangles when grounded).
- **P10.7** — Balance PD controller: COM offset from support polygon center → hip target adjustment + ankle torque bias. Separate PD on COM velocity.
- **P10.8** — Procedural catch-step:
  - Trigger condition: COM exits support polygon beyond threshold AND COM velocity exceeds threshold
  - Compute step target: COM projection + velocity × step_lead_time (crude capture point)
  - Generate foot trajectory: Hermite through (current foot, apex above midpoint, target), duration = f(step length)
  - During step: swing leg strength stays high (tracks trajectory), stance leg stays high, hip target shifts toward stance foot
  - On foot contact or trajectory complete: switch stance, return to Standing
- **P10.9** — State machine: `Standing`, `Stepping`, `Falling`. Transitions based on COM-outside-polygon duration + body tilt.
- **P10.10** — Balance tab in right dock: support polygon visualization, COM gizmo, tilt threshold slider, step parameters (lead time, apex height, min/max step length).

### Milestone

- Character stands in place with strength 1.0: stable for 30+ seconds, small COM oscillations as balance PD compensates.
- Small push (200N impulse to chest): character sways but recovers without stepping.
- Medium push (500N impulse): character takes one catch-step in the push direction, recovers upright.
- Large push (1500N impulse): character steps but loses balance, enters Falling, collapses cleanly.
- Uneven ground: feet IK to terrain, character remains level and balanced.
- Video artifact: `docs/videos/phase_10_milestone.mp4`.

### Files

```
addons/marionette/
├── runtime/
│   ├── foot_ik_modifier.gd
│   ├── com_computer.gd
│   ├── support_polygon.gd
│   ├── balance_controller.gd
│   ├── catch_step_planner.gd
│   └── balance_state_machine.gd
├── editor/
│   └── balance_tab.gd
demo/
└── balancing_character.tscn
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

## Phase 12 (optional) — Targeted C++ port of SPD hot path

**Goal**: triggered only if profiling at realistic character count shows `_integrate_forces` SPD math as the dominant cost. Port *only* `MarionetteBone._integrate_forces` and `SPDMath`; leave orchestrator, resources, composition, and editor tooling in GDScript.

**Trigger condition**: at target character count, SPD torque computation dominates frame cost AND the overhead is clearly GDScript dispatch (not Jolt's own solver, not contact resolution, not composition math). Record in `docs/perf_profile.md` before starting the port.

### Tasks

- **P12.1** — Profile runs at representative load (N characters × 84 bones × 60Hz physics). Record flamegraph / per-system cost. If SPD is not dominant, close the phase — the pure-GDScript build ships as-is.
- **P12.2** — Set up godot-cpp submodule (verify current 4.6+ compatible branch on github.com/godotengine/godot-cpp), SConstruct, `marionette.gdextension` manifest, `register_types.cpp`.
- **P12.3** — Port `MarionetteBone._integrate_forces` and `SPDMath` to C++. Public API surface unchanged. GDScript fallback path preserved for users without a C++ toolchain (manifest lists the library as optional or ships prebuilt binaries per platform).
- **P12.4** — C++ doctest ports of existing SPD math unit tests. GDScript and C++ implementations must produce bit-equivalent torque for the reference test vectors.

### Milestone

- Profile rerun: same scenes, same character count, C++ SPD < 2ms/frame total at target load.
- Public API surface unchanged from the GDScript baseline.
- Pure-GDScript install still works end-to-end for users who skip the native build.

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
