# Marionette Update — T-Pose Calibration as Parallel Method

Status: proposal, not yet applied.
Affects: `extensions/marionette/gdscript/runtime/`, `extensions/marionette/gdscript/editor/`.
Does not change runtime SPD, ragdoll creation, validator schema, or any resource layout.

---

## 1. Context (current pipeline as code)

Three entry points, all calling one generator:

- `gdscript/editor/bone_profile_inspector.gd:40` — "Generate from Skeleton" button on the `BoneProfile` resource → `BoneProfileGenerator.generate(bp, null, null, true)` (template SkeletonProfile, no live rig).
- `gdscript/runtime/marionette.gd:314` — "Calibrate Profile from Skeleton" tool button on the `Marionette` node → `BoneProfileGenerator.generate(bone_profile, skel, bone_map, true)` (live rig, then `ResourceSaver.save` at `:332` to persist).
- `tests/run_tests.gd` — direct invocation.

`BoneProfileGenerator.generate()` (`gdscript/runtime/bone_profile_generator.gd:43-199`) per-bone loop:

1. Archetype lookup — `MarionetteArchetypeDefaults.archetype_for_bone(name)` (`:101`).
2. Child world resolution — `_resolve_child_world` falls back through explicit tail → first listed child → 2cm Y-axis nudge (`:202-222`).
3. Motion target — `MarionetteSolverUtils.anatomical_motion_target(name, archetype, muscle_frame)` (bone-name-keyed; `solver_utils.gd:114-139`).
4. **Solver dispatch** — `MarionetteArchetypeSolverDispatch.solve(...)` (`archetype_solver_dispatch.gd:27-43`) → one of six per-archetype solvers, each producing `target_basis: Basis` in profile space.
5. Permutation matcher — `MarionettePermutationMatcher.find_match(bone_world.basis, target_basis)` (`permutation_matcher.gd:88-110`); writes signed permutation onto entry for diagnostics only.
6. **Bake** (`bone_profile_generator.gd:157-158`):
   ```gdscript
   entry.calculated_anatomical_basis = bone_world.basis.inverse() * target_basis
   entry.use_calculated_frame = true
   ```
7. `mirror_abd` chirality flag (`:163-171`).
8. ROM defaults — `MarionetteRomDefaults.apply(entry, bone_name)` (`rom_defaults.gd:75-89`).

At ragdoll creation (separate path), `MarionetteBone.joint_rotation` is set from `entry.anatomical_basis_in_bone_local()`. None of the generation pipeline runs at runtime.

---

## 2. Proposed change

Add a **parallel** generator method that derives `target_basis` from a per-bone canonical T-pose along-direction table instead of from rest-pose bone-to-child geometry through archetype-specific solvers. Wire two new editor buttons that invoke it. **Do not remove the existing archetype-solver path.** Both methods coexist; the user can A/B them on the same rig and pick the cleaner result via the existing "Validate Joint Frames" diagnostic.

The naming throughout this doc calls the existing path the **"archetype" method** and the new one the **"T-pose" method**. T-pose here is a *reference frame for a lookup table*, not an action applied to the skeleton — the algorithm never mutates `Skeleton3D` and never poses the rig. Every step before and after `target_basis` derivation is shared verbatim with the archetype path.

---

## 3. Why this works (and why we keep both)

- The archetype solvers exist to derive a per-bone anatomical basis from arbitrary rest-pose geometry (T-pose, A-pose, bent rigs). Their per-archetype geometric tricks compensate for the fact that rest-pose bone direction may not match canonical T-pose direction.
- In T-pose, every bone's anatomical along-axis is known a priori from its role (`LeftUpperArm` → +right, `Spine*` → +up, `LeftFoot` → +forward, etc.). The basis derivation collapses to one cross product per bone, no archetype dispatch.
- This matches what Unity Mecanim does: bone mapping → canonical T-pose orientation per role → muscle referential (their `pre-rotation` = our `calculated_anatomical_basis`). Manual nudging in Unity is the exception; the mapping is normally sufficient.
- We keep the archetype path because it is exercised, has unit tests, and is producing correct ragdolls today. The T-pose method is a candidate replacement; promoting it to default requires evidence (validator agreement on real rigs).

### 3.1 Caveat — behavior on A-pose / non-T-pose rigs

The T-pose method is **strict** in the sense that `target_basis` is body-fixed canonical regardless of the rig's actual rest pose. That has a consequence worth spelling out, since it is initially counterintuitive:

- For an A-pose left upper arm, `along_for(...)` returns canonical body-lateral (`-mf.right`), not the bone's actual `(child - bone)` direction (which points 45° down-out).
- After the bake `bone_world.basis.inverse() * target_basis`, the joint frame at rest is therefore oriented to T-pose canonical anatomy in world — joint-local +Y points world body-lateral, while the bone itself points world down-out. The two are 45° apart.
- Visually: the JointLimitGizmo's ROM arcs render in horizontal planes (T-pose orientation), not tilted with the A-pose arm. CLAUDE.md §3 calls this "the joint frame, drawn truthfully." The "tilt" is real — joint-local is not aligned to any bone-local axis at this bone.
- Behaviorally: SPD targets in anatomical (flex, along, abd) coords drive the bone around canonical-anatomy axes — i.e., the motion plane and rotation axes look "as if the rig were in T-pose," even though the bone is in A-pose at rest.

This is the design of the T-pose method, not a bug. If you want axes that follow the bone's actual rest orientation (so ROM arcs tilt with an A-pose arm and SPD motion pivots around bone-perpendicular axes), use the **archetype method** — `MarionetteArchetypeSolverDispatch.solve` derives `along` from the rest geometry, which gives bone-attached axes on any rest pose.

The user's natural fix ("compute the canonical T-pose basis, then rotate it by the rest-to-T-pose delta") collapses to "use the actual rest direction as `along`" — which is exactly what the archetype method already does. So there is no clean third method to add; the rest-delta correction *is* the archetype path.

Practical guidance:
- T-pose rig (or canonical-aligned rest): both methods agree to within FP error, T-pose method is faster authoring.
- A-pose / non-T-pose rig: archetype method matches the "axes follow the bone" intuition; T-pose method gives canonical body-fixed axes regardless. Pick whichever the consumer's animation / pose authoring assumes.

---

## 4. Implementation plan

### 4.1 New file: `gdscript/runtime/canonical_t_pose_directions.gd`

Static table keyed by canonical SkeletonProfile bone name. For each bone, returns the along-bone direction in *muscle-frame coordinates* (not world): a linear combination of `muscle_frame.right`, `.up`, `.forward`, signed by `is_left_side`.

```gdscript
@tool
class_name MarionetteCanonicalDirections
extends RefCounted

# Returns the bone's along-bone direction in T-pose, expressed against the
# muscle frame and signed by side. Vector3.ZERO means "no canonical direction
# for this bone" — caller should fall back to rest-pose geometry or skip.
static func along_for(bone_name: StringName, mf: MuscleFrame, is_left_side: bool) -> Vector3:
    var s := String(bone_name)
    # Spine chain points along +up.
    if s == "Hips" or s.begins_with("Spine") or s == "Neck" or s == "Head":
        return mf.up
    # Arm chain points laterally outward from body midline.
    if s.ends_with("Shoulder") or s.ends_with("UpperArm") or s.ends_with("LowerArm") or s.ends_with("Hand"):
        return -mf.right if is_left_side else mf.right
    # Leg chain points along -up (down).
    if s.ends_with("UpperLeg") or s.ends_with("LowerLeg"):
        return -mf.up
    # Foot points forward (toes-direction).
    if s.ends_with("Foot"):
        return mf.forward
    # Toe phalanges + Toes block bone: forward.
    if s.contains("Toe") or s.contains("Hallux"):
        return mf.forward
    # Finger phalanges: laterally outward (continue the arm direction).
    if s.contains("Thumb") or s.contains("Index") or s.contains("Middle") \
            or s.contains("Ring") or s.contains("Little"):
        return -mf.right if is_left_side else mf.right
    return Vector3.ZERO
```

Authoring care points:
- Thumb deserves a different along-direction than the other fingers (it's not laterally outward in T-pose); decide on the convention and add a special case. Probably along forward + slight outward, but pin it.
- Hand palm orientation is determined later by the cross product with the motion target, not by this table — `anatomical_motion_target` for `Hand` returns `-muscle_frame.up` (palmar flex = down), which combined with a lateral `along` gives the correct flex axis.
- `Hips` is the root — its along-direction is the trunk axis. The root archetype currently does not use SPD, so this entry is informational; if the root is ever SPD-driven the choice matters.

Acceptance: every bone in `MarionetteHumanoidProfile`'s 84-bone list returns a non-zero `along_for`, *except* bones whose archetype is `ROOT`, `FIXED`, or out-of-scope (jaw, eyes — these stay Kinematic in `BoneStateProfile`).

### 4.2 New file: `gdscript/runtime/t_pose_basis_solver.gd`

Single-function solver replacing the entire `archetype_solvers/` directory for this code path.

```gdscript
@tool
class_name MarionetteTPoseBasisSolver
extends RefCounted

# T-pose method (P2.6 alternative). Replaces archetype-dispatched geometric
# derivation with a canonical-along-direction lookup + one cross product.
# Returns the anatomical target basis in profile/world space — same interface
# as MarionetteArchetypeSolverDispatch.solve, fewer inputs.
static func solve(
        bone_name: StringName,
        archetype: int,
        muscle_frame: MuscleFrame,
        is_left_side: bool) -> Basis:
    var along: Vector3 = MarionetteCanonicalDirections.along_for(bone_name, muscle_frame, is_left_side)
    if along == Vector3.ZERO:
        return Basis.IDENTITY  # caller treats as "no SPD frame" (ROOT/FIXED behavior)
    var motion: Vector3 = MarionetteSolverUtils.anatomical_motion_target(bone_name, archetype, muscle_frame)
    if motion == Vector3.ZERO:
        # Pivot / Root / Fixed — anatomical_motion_target returns ZERO for these.
        return Basis.IDENTITY
    var flex: Vector3 = MarionetteSolverUtils.anatomical_flex_axis(along, motion, muscle_frame, is_left_side)
    return MarionetteSolverUtils.make_anatomical_basis(flex, along)
```

Reuses `solver_utils.gd` helpers — `anatomical_motion_target`, `anatomical_flex_axis`, `make_anatomical_basis` — without modification.

### 4.3 Modify `gdscript/runtime/bone_profile_generator.gd`

Add a method enum and a parallel public entry point. The per-bone loop body is shared; only the `target_basis` derivation differs.

```gdscript
enum Method { ARCHETYPE, TPOSE }

static func generate_with_method(
        bone_profile: BoneProfile,
        method: Method,
        live_skeleton: Skeleton3D = null,
        bone_map: BoneMap = null,
        verbose: bool = false) -> GenerateReport:
    # ... existing setup (data substrate selection, world_rests, muscle_frame,
    # entries seed) is shared ...
    # In the per-bone loop, replace the archetype-dispatch block with:
    var target_basis: Basis
    match method:
        Method.ARCHETYPE:
            var motion_target: Vector3 = MarionetteSolverUtils.anatomical_motion_target(
                    bone_name, archetype, muscle_frame)
            target_basis = MarionetteArchetypeSolverDispatch.solve(
                    archetype, bone_world, child_world, muscle_frame,
                    is_left_side, parent_world, motion_target)
        Method.TPOSE:
            target_basis = MarionetteTPoseBasisSolver.solve(
                    bone_name, archetype, muscle_frame, is_left_side)
    # Permutation matcher, calculated_anatomical_basis bake, mirror_abd,
    # ROM defaults — all shared, unchanged.
```

Keep `generate(...)` as-is for backward compatibility; have it call `generate_with_method(..., Method.ARCHETYPE, ...)`. Tests that call `generate()` directly continue to work.

### 4.4 Modify `gdscript/editor/bone_profile_inspector.gd`

Add a second button. Keep wording explicit so the user knows which method ran.

```gdscript
func _parse_begin(object: Object) -> void:
    var bp: BoneProfile = object as BoneProfile
    if bp == null: return
    var arch_btn := Button.new()
    arch_btn.text = "Generate from Skeleton (Archetype)"
    arch_btn.tooltip_text = "Existing path: muscle frame -> per-archetype solver -> matcher -> ROM."
    arch_btn.pressed.connect(_on_pressed.bind(bp, BoneProfileGenerator.Method.ARCHETYPE))
    add_custom_control(arch_btn)
    var tpose_btn := Button.new()
    tpose_btn.text = "Generate from Skeleton (T-Pose)"
    tpose_btn.tooltip_text = "Canonical T-pose direction lookup + single cross product. No archetype dispatch."
    tpose_btn.pressed.connect(_on_pressed.bind(bp, BoneProfileGenerator.Method.TPOSE))
    add_custom_control(tpose_btn)

func _on_pressed(bp: BoneProfile, method: BoneProfileGenerator.Method) -> void:
    # ... same as current _on_pressed, calling generate_with_method(bp, method, null, null, true)
```

### 4.5 Modify `gdscript/runtime/marionette.gd`

Add a parallel `@export_tool_button` and method, mirroring the existing `calibrate_bone_profile_from_skeleton`. Same disk-persist path — only the method enum differs.

```gdscript
@export_tool_button("Calibrate Profile (T-Pose)") var _calibrate_tpose_btn: Callable = calibrate_bone_profile_from_skeleton_tpose

func calibrate_bone_profile_from_skeleton_tpose() -> void:
    _calibrate_with_method(BoneProfileGenerator.Method.TPOSE)

func calibrate_bone_profile_from_skeleton() -> void:  # existing — refactor body into _calibrate_with_method
    _calibrate_with_method(BoneProfileGenerator.Method.ARCHETYPE)

func _calibrate_with_method(method: BoneProfileGenerator.Method) -> void:
    # body lifted from current calibrate_bone_profile_from_skeleton(), with the
    # generator call swapped to:
    #   BoneProfileGenerator.generate_with_method(bone_profile, method, skel, bone_map, true)
```

### 4.6 Validator (no code change required)

`MarionetteFrameValidator.validate(...)` (`frame_validator.gd`) compares each entry's baked `calculated_anatomical_basis` against a recomputed solver target. After this change the validator will keep using the *archetype* solver as its reference target. That makes the validator's per-bone `flex_dot / along_dot / abd_dot` values into a direct A/B between the two methods: when the T-pose method's bake disagrees with the archetype solver's target, the dots are not 1.0. Look at the disagreements case-by-case; they are the input to deciding which method is preferred per bone class.

If we later want a validator that compares against the T-pose target instead, that's a one-line change in the validator and is a follow-up.

---

## 5. Tests

### 5.1 Unit tests (gdUnit4) under `extensions/marionette/tests/`

- `t_pose_basis_solver_test.gd`: for each `MarionetteHumanoidProfile` bone, given a canonical muscle frame (right=+X, up=+Y, forward=-Z), assert that `solve(...)` returns a basis whose along column matches the table entry exactly and whose flex × along produces motion in the `anatomical_motion_target` direction.
- `canonical_directions_test.gd`: every bone in the profile that is *not* `ROOT/FIXED/jaw/eye` returns a non-zero `along_for`. Bones that *are* `ROOT/FIXED/jaw/eye` return Vector3.ZERO. Coverage check across all 84 bones.
- `bone_profile_generator_method_parity_test.gd`: run the generator on the template `MarionetteHumanoidProfile` with both methods. For each bone, log `Quaternion(archetype_basis).angle_to(Quaternion(tpose_basis))` in degrees. Acceptance: shoulder/hip/elbow/knee/wrist/ankle agree within 5°. Spine and clavicle may differ more (their archetype solvers do non-trivial geometry and we expect the T-pose method to flatten that). Print a per-bone agreement table to the test log.

### 5.2 Manual acceptance

- On the development character (ARP-rigged): "Calibrate Profile (T-Pose)" → "Validate Joint Frames" → expect ok_count ≥ archetype-method's ok_count on the same rig, or document which bones regressed and why.
- "Build Ragdoll" with each method's BoneProfile → `MuscleTestDock` flex sliders on shoulder, hip, elbow, knee, wrist, ankle: motion direction matches anatomy in both cases.

---

## 6. Out of scope for this change

- Removing or deprecating archetype solvers. They stay; the T-pose method is parallel.
- Changing `BoneEntry`, `BoneProfile`, or any resource schema.
- Changing runtime SPD, ragdoll creation, joint-rotation baking, or validator output schema.
- Per-character ROM overrides as a separate `.tres` library. Discussed previously; not part of this change.
- "Force the skeleton into T-pose" mechanism. This change does not pose the skeleton; T-pose is purely a reference frame for the lookup table.
- Roll-error reporting as a primary diagnostic. The validator already surfaces this via matcher score; a dedicated roll-error number is a follow-up.

---

## 7. Open questions to confirm before implementing

1. **Thumb along-direction.** Decide on the canonical T-pose direction for thumb metacarpal and phalanges. Standard choice: along forward (anterior) + small outward (lateral) component, signed by side. Pin in the table.
2. **Foot along-direction in T-pose.** Forward (toes-direction) is the assumption above. Confirm this matches the ARP rest pose convention used for `MarionetteHumanoidProfile`.
3. **Spine subdivision.** The current archetype path treats each spine vertebra individually with `SpineSegmentSolver`. The T-pose method would treat all of `Spine`, `Spine1`, `Spine2`, `Neck`, `Head` as along=+up. Confirm that's acceptable — it implies a straight spine in T-pose, which is the standard simplification but worth explicit confirmation.
4. **Clavicle.** Archetype solver has nontrivial logic (uses muscle_frame.up as motion target, not forward). T-pose method would need the same — either by leaving `anatomical_motion_target` as the source of truth (already does this for clavicles per `solver_utils.gd:133-134`) or by special-casing in the canonical directions table. Confirm the existing `anatomical_motion_target` clavicle branch is sufficient.
5. **Naming.** "T-pose method" vs "Canonical method" vs "Mecanim-style method". Doc uses "T-pose"; rename if a different label is preferred.

---

## 8. Suggested commit sequence

1. `[P2] feat: canonical T-pose direction table` — adds `canonical_t_pose_directions.gd` + unit test.
2. `[P2] feat: T-pose basis solver` — adds `t_pose_basis_solver.gd` + unit test.
3. `[P2] feat: BoneProfileGenerator method enum + generate_with_method` — refactor existing `generate()` into the new shared path.
4. `[P2] feat: parallel "T-Pose" calibration buttons` — inspector + Marionette node.
5. `[P2] test: parity comparison archetype vs T-pose method on template profile`.

Each commit is independently reverable. Step 3 is the only one that touches an existing API surface; existing callers continue to work via `generate()` shim.
