# CLAUDE.md — Marionette (Active Ragdoll System for Godot 4.6+)

Read before every coding session. Defines project invariants and style. See `PLAN.md` for the phased roadmap.

---

## Project summary

Marionette is an addon for Godot 4.6+ that drives a character skeleton via physics-based muscle control: animation tracking, forced poses (cramps, grabs, holds), cyclic procedural motion (shiver, tremor, breathing), impact reactions, and emotional body states with transient overlays.

Target engine: **Godot 4.6+ with Jolt Physics**. No Godot 3.x patterns. No GodotPhysics3D fallback paths.

Top-level node: `Marionette` (extends `Node3D`). Per-bone controller: `MarionetteBone` (extends `PhysicalBone3D`).

---

## Non-negotiable invariants

Changes to these require explicit user approval before writing code.

### 1. Two vocabularies coexist

Anatomical (public) and axis (debug) vocabularies both live in the codebase. Neither excludes the other.

**Anatomical vocabulary** — flexion/extension, medial/lateral rotation, abduction/adduction, plus clinical synonyms (dorsiflexion, pronation, ulnar deviation, eversion). Used in:
- Public API method names and parameter names
- Resource field names and dictionary keys (`RagdollPose.bone_angles["LeftElbow"]` is a Vector3 of anatomical components)
- Primary inspector panels
- Signal argument names
- User documentation
- Error messages visible to consumers

**Axis vocabulary** — angular_x/y/z, joint-local, basis columns, ±X/±Y/±Z. Used and welcome in:
- Debug prints and log messages
- Internal struct fields
- Code comments explaining anatomical→axis mapping
- Diagnostic panels (explicitly labeled "debug" or "advanced")
- The thin layer writing to `PhysicalBone3D`'s 6DOF API
- Unit test names and assertions
- Profiler output

Designers authoring content never see axis terminology. Developers debugging physics always can. Diagnostic displays show both side-by-side: `"Left Elbow — Flexion (angular_x): 23° (limit: 0°..140°)"`.

### 2. Anatomical frame convention

- **Flexion** is always +X rotation in the joint's local frame *after ragdoll creation*.
- **Along-bone** is +Y.
- **Abduction** is +Z (derived as X × Y).
- **Side symmetry**: right side mirrors left by negating Y and Z, keeping X. Stored as `is_left_side: bool` per bone.
- **Resources store anatomical angles in positive-flex / positive-medial / positive-abduction convention regardless of side.** Side flip happens at solver time.

### 3. Anatomical frame is baked into physics at ragdoll creation

This is the core architectural decision. At authoring time:
1. Geometric pipeline computes the target anatomical basis per bone (muscle frame derivation + archetype-specific solvers).
2. Permutation matcher finds the signed permutation of the bone's rest basis that best aligns with the target. Result is stored on the entry's `flex_axis` / `along_bone_axis` / `abduction_axis` fields **for diagnostics only** — the validator and authoring gizmos use it as a calibration-quality signal.
3. The exact (un-quantized) target basis is also stored, in bone-local space, as `BoneEntry.calculated_anatomical_basis`. `use_calculated_frame` is set to `true` unconditionally for SPD bones.
4. At ragdoll creation, `MarionetteBone.joint_rotation` is set from `BoneEntry.anatomical_basis_in_bone_local()`, which returns `calculated_anatomical_basis` when `use_calculated_frame` is true. Joint frame's columns are (flex, along-bone, abduction).

**After creation, the joint's local +X is literally the flex axis.** Runtime SPD, limit authoring, gizmos, debug panels all operate in joint-local space, which equals anatomical space. No per-frame permutation layer on SPD output.

Earlier the matcher's choice was authoritative for runtime baking, with the calculated frame as a fallback when score < threshold. That produced subtle motion errors: the 0.85 threshold accepted up to ±31° of axis tilt, so an A-pose elbow whose bone-local +X happens to be ~20° off the true perpendicular-to-limb-plane would bake a tilted joint frame. Slider drives then rotated around the tilted axis — anatomically wrong. Defaulting to the calculated frame eliminates this whole class of error: runtime motion always rotates around the exact solver-computed axis. The matcher result remains valuable as the calibration-quality signal — bones whose match score is low indicate ill-rolled or non-T-pose rigs that the user might want to fix in Blender, but the ragdoll works correctly either way.

Cost of always-calculated-frame: joint-local axes are not aligned to any single bone-local axis, so the authoring gizmo's tripod and the JointLimitGizmo's arcs render tilted at that bone. That's the joint frame, drawn truthfully.

The only runtime permutation is on the *input* side: reading bone-local animation poses from `Skeleton3D` and converting to anatomical angles. Done via basis-column rotations around `entry.anatomical_basis_in_bone_local()`'s columns, uniform across all bones.

### 4. Archetype-dispatched geometric authoring

At **authoring time only** (when pressing "Generate from Skeleton" on a `BoneProfile`), geometric derivation runs:
- Muscle frame computed from the `SkeletonProfile`'s reference poses (hip midpoint, head bone, toe/foot positions).
- Per-bone archetype classified from bone name (default map for humanoid profiles).
- Archetype-specific solver computes target anatomical axes.
- Permutation matcher picks the best signed permutation of the bone's rest basis.
- All results written into `BoneProfile`'s `BoneEntry` dictionary.

At **runtime**, none of this geometric work runs. The `BoneProfile` is consumed as static data. Muscle frame, archetype solvers, permutation matcher are authoring-time tools only.

Archetypes: `Ball, Hinge, Saddle, Pivot, SpineSegment, Clavicle, Root, Fixed`.

### 5. Physics backend: Jolt only

Project Settings → Physics → 3D → Physics Engine → "Jolt Physics". GodotPhysics3D's 6DOF motors and springs are stub code. Do not write compatibility paths for it.

### 6. Control method: SPD via `_integrate_forces`

Per-bone `MarionetteBone` uses `custom_integrator = true`, implements `_integrate_forces(state)`, applies torques via `state.apply_torque()`. SPD formulation (Tan/Liu/Turk 2011). No joint motors, no joint springs — those trigger Jolt joint rebuilds every frame.

Spring parameters authored as **alpha** (reach-in-N-steps) and **damping ratio** (0..1 wobble dial). Converted internally to kp/kd using per-bone mass. This makes parameters mass-independent and portable across characters.

### 7. Use `MarionetteBone`'s internal 6DOF joint

Set `joint_type = JOINT_TYPE_6DOF`. Do not add separate `Generic6DOFJoint3D` nodes. The internal joint connects to the parent `MarionetteBone` automatically via skeleton hierarchy. Dynamic property paths (`angular_limit_x/upper_angle`, etc.) expose all parameters via `set()`/`get()`.

### 8. Single-skeleton architecture

One `Skeleton3D` per character. `AnimationPlayer` writes target poses to it. `MarionetteBone` reads targets, converts to anatomical angles, drives SPD. `PhysicalBoneSimulator3D` writes physics results back to the skeleton. `MeshInstance3D` renders. No dual-skeleton pattern.

`PhysicalBoneSimulator3D.influence` stays at 1.0. Animation is target input, not output override.

### 9. Scope: body + head orientation only

Marionette drives body bones and head orientation via SPD. **Jaw bone and eye bones are out of scope** — they are driven by the separate facial expression system.

Default `BoneStateProfile` marks jaw and eye bones as `Kinematic` (follow animation directly, no SPD, no physics simulation). They remain in the `SkeletonProfile` for retargeting completeness.

Marionette emits signals about body state and active overlays. The facial expression system subscribes independently. Marionette does not drive face.

### 10. Profile decomposition: three resources

- **`BoneProfile`** — per-character static data: anatomical basis permutations, archetypes, ROM limits, muscle strength params (alpha/damping), mass fractions. Companion to a specific `SkeletonProfile`. Filled by "Generate from Skeleton" action, editable in inspector.
- **`BoneStateProfile`** — per-bone Kinematic / Powered / Unpowered enum. Swappable at runtime for injury states.
- **`CollisionExclusionProfile`** — bone pair exclusions + fully-disabled bones. Generated with parent-child defaults; editable.

Plus pose/cyclic/emotion resources (see §12).

### 11. Custom skeleton profile with toe bones

We ship `MarionetteHumanoidProfile` — 84 bones = 56 standard humanoid (matching `SkeletonProfileHumanoid`) + 28 toe bones (14 per foot: hallux 2 phalanges, toes 2-5 three phalanges each). Built via tool script from an ARP-rigged source character.

**Group textures**: `SkeletonProfileHumanoid` ships with `null` textures on all four groups. The body/face/hand silhouettes in the BoneMap editor are **editor-theme SVG icons** (`BoneMapHumanBody`, `BoneMapHumanFace`, `BoneMapHumanLeftHand`, `BoneMapHumanRightHand`), not profile data. How the BoneMap editor resolves these icons is unverified until the P1.0 empirical test. We author and ship `BoneMapHumanLeftFoot.svg` and `BoneMapHumanRightFoot.svg` for the new foot groups. See PLAN.md P1 for the branch on how foot textures are wired up (`set_texture()` on the profile vs. our own inspector supplement).

Auto-Rig Pro (with extended toe bones) is our reference rig. ARP is Blender-originated, so Y-along-bone is guaranteed per Blender convention. X/Z axes determined by bone roll; the permutation matcher resolves the anatomical mapping.

`SkeletonProfileHumanoid`-based characters (no toes) still supported via their own `BoneProfile`, but `MarionetteHumanoidProfile` is primary.

### 12. Emotional body state composition in Marionette

Marionette consumes two resource types for runtime behavior composition:

- **`EmotionalBodyState`** — baseline emotional body expression. Contains a base pose, cyclic overlays, per-bone strength modulation, global strength multiplier. One is active at a time, blended on transition.
- **`EmotionalBodyOverlay`** — transient response. Contains optional pose/cyclic/strength modulation plus an envelope curve and duration. Gameplay pushes overlays onto a dynamic array; they auto-remove when envelope ends.

Composition math runs in anatomical space before the anatomical→joint-local permutation:

```
final_target[bone] = base_state.base_pose[bone] * base_state.base_pose_weight
                   + sum(overlay.pose[bone] * overlay.weight * overlay.envelope(t))
                   + sum(cyclic.evaluate(bone, axis, phase) * cyclic.weight)
```

Strength is a separate axis from pose composition. SPD gain per bone is
`kp_per_bone = base_kp * bone_strength * global_strength_mult` (and likewise for
`kd`). **Strength is the continuous limp↔actively-held dial.** At strength 0
the SPD produces zero torque, so the bone tracks no target and falls under
gravity — functionally identical to `BoneStateProfile.Unpowered`, but without
crossing the state enum. It can be re-engaged on the next tick by ramping
strength back up, with no solver-state rebuild.

Use the two mechanisms differently:
- **`BoneStateProfile` enum** for persistent mode changes (injury makes a limb
  permanently `Unpowered`; jaw is permanently `Kinematic`). Swapping the
  profile rebuilds which bones participate in SPD.
- **Strength modulation (per-bone × global)** for transient limpness and the
  continuous spectrum from ragdoll to fully held. Post-orgasm recovery,
  surrender, shock — all drive strength toward zero without touching the
  profile. This is what "actively held pose ↔ limp ragdoll" refers to in the
  project description.

Marionette's public API:
- `set_body_state(state, blend_duration)`
- `push_overlay(overlay, weight) -> handle`
- `remove_overlay(handle)` (overlays also auto-remove when envelope returns to 0)
- Signals: `body_state_changed(state_name)`, `overlay_started(overlay_name)`, `overlay_ended(overlay_name)`

The higher-level stimulus→response system (sensing pain locations, applying character-specific response mappings) is **out of scope for Marionette**. That's the consumer's responsibility (GDScript glue in the game project) and consumes Marionette via the API above.

### 13. Animation input is procedural only

No `AnimationTree`, no `AnimationPlayer`, no keyframe animation input. The full animation vocabulary is:

- Poses (§12 — base and overlay pose targets)
- Cyclic animations (breathing, shiver, tremor — evaluated procedurally)
- Body-wide traveling waves (`TravelingWaveCyclic` — coherent disturbances parameterized by bone position along a `PropagationGraph`; see PLAN.md P7.9 / P2.14)
- Emotional body overlays (transient response resources)
- Motion macros (longer scripted procedural trajectories)
- Reverie-driven anatomical targets (via `BodyAreaModulation.pose_target_offset`)
- Attention-driven neck targets (via `CharacterModulation.attention_*`, consumed by `NeckAttentionDriver`; see `docs/architecture/Reverie_Planning.md §2.6`)

All of these compose additively on SPD-driven bones. No external clip or pose-graph source. This makes the authoring UI load-bearing — pose, cyclic, and wave resources *are* the animation system, not a supplement to one.

### 14. Body rhythm shared clock (cross-extension contract)

`Marionette` exposes a single phase variable that all cyclic / wave evaluation reads as its time argument:

```
@export var body_rhythm_frequency: float = 0.4    # Hz, settable by Reverie
var body_rhythm_phase: float = 0.0                 # 0..TAU, advances every physics tick
signal body_rhythm_cycle_completed(cycle_index: int)
```

- `body_rhythm_phase` is **integrated** (`phase += freq * TAU * delta`), never recomputed (`phase = freq * t`). Otherwise a frequency change snaps the phase, which is visible in both the body and in any tentacle locked to it.
- `BoneOscillator.frequency_multiplier` and `TravelingWaveCyclic.temporal_frequency` are interpreted as multipliers on `body_rhythm_frequency`, not as absolute Hz.
- TentacleTech's `RhythmSyncedProbe` (`docs/architecture/TentacleTech_Architecture.md §6.11`) reads `body_rhythm_phase` to lock tip drive to the body's rhythm at a configurable phase offset (`π` for pumping, `0` for yielding).
- Reverie writes `body_rhythm_frequency` from arousal axis (`docs/architecture/Reverie_Planning.md §3.2`). Phase-continuity / ramp protection is Marionette's responsibility, not Reverie's.

See PLAN.md P7.10 for tasks.

### 15. Soft-tissue jiggle bones (non-rim regions)

Per soft region (gluteus, breast, belly, jowls, etc.), 1–2 child bones with translation-only SPD parented to a host bone. Rotational SPD deferred to v2; gate on visible motion-quality shortfall. Authored once per hero in Blender — must exist in the skeleton hierarchy at modeling time, since skin weights are painted to them in Blender. The runtime `JiggleProfile` configures *parameters* of bones the model already exposes; it cannot create new ones. Closes the autonomous-dynamics gap on non-rim soft tissue (TentacleTech bulgers handle deformation during contact; jiggle bones own the post-contact wobble).

---

## Response style for this project

- Direct and technically precise. No hedging or preamble.
- Point out flaws or architectural problems proactively.
- If the user proposes something suboptimal, say so and explain why.
- Short answers for short questions.
- **Discuss before implementing for non-trivial changes.** Never write 500 lines of code in response to a one-sentence request.

## Technical defaults

- Godot 4.6+. Verify API signatures against `docs.godotengine.org`; don't rely on memory.
- **C++ GDExtension with GDScript glue.** The active-ragdoll core ships in C++ via SConstruct: `MarionetteBone` (SPD via `_integrate_forces`), `SPDMath`, `MarionetteComposer` (cost-weighted IK soup, posture-pattern blending, strain, engagement pump), `RhythmReadout`, `IKChainSolver`. GDScript ships: all `Resource` types (`BoneEntry`, `BoneProfile`, `BoneStateProfile`, `RagdollPose`, `PosturePattern`, `EngagementProfile`, `FrequencyComplianceCurve`, etc.), archetype solvers (authoring-time only), `MuscleFrameBuilder` (authoring-time), `Marionette.gd` autoload wrapper that owns the C++ composer instance, gizmos, editor tooling, inspector panels, import workflow scripts, test harnesses. Data flows GDScript → C++ via cached resource handoffs and once-per-change bound-method calls; C++ does not read GDScript callbacks per tick.
- Use static typing everywhere in GDScript. Typed GDScript is ~2-3x faster than dynamic and catches most coordinate-space bugs at parse time.
- Prefer nodes over nested resources for inspector-configured objects. Exception: `BoneProfile`, `RagdollPose`, etc. are resources because they're shared across characters.
- When referencing Jolt semantics, verify against Jolt docs and godot-jolt repo.

## What to search vs answer directly

- `docs.godotengine.org` for API signatures, class hierarchies, editor behavior.
- Recent syntax/features in shaders, compute shaders, RenderingDevice.
- Blender Python API and addon behaviors.
- Jolt constraint specifics: `jrouwe/JoltPhysics` docs and godot-jolt DeepWiki.

## Code review obligations

Flag proactively:

- **Public API using axis terminology** (internal code fine, public API not).
- **Resource field names/keys using axis terminology** (debug dumps fine, serialized field names not).
- **Generic solvers** hiding archetype logic in conditionals.
- **Runtime geometric work** that should have been baked at authoring time (muscle frame recomputation, permutation matching at runtime).
- **Coordinate space bugs**: bone-local vs joint-local vs world vs anatomical confusion. Joint-local = anatomical post-creation; pre-creation they differ.
- **Handedness errors**: left/right mirror logic that doesn't use the `is_left_side` bit correctly.
- **Per-frame joint property writes** (triggers Jolt rebuilds — must route through SPD torques instead).
- **Per-frame allocations** in `_integrate_forces`.
- **MeshDataTool or per-frame material creation** anywhere.
- **Head/jaw/eye scope creep**: jaw and eyes are out of scope; head bone is in scope.

## Testing expectations

- Unit tests via gdUnit4 (verify current recommendation for 4.6+ in Phase 0).
- Each archetype solver: unit tests across 3+ rest-pose variants (T-pose, A-pose, bent-knee).
- Permutation matcher: identity case, known roll, pathological-input-flags-unmatched.
- SPD math: hand-computed reference values.
- Anatomical ↔ joint-local round-trip returns identity for each bone.
- Every phase milestone produces a video in `docs/videos/phase_N_milestone.mp4`.

## File organization

Marionette lives in the monorepo as `extensions/marionette/` and builds as a C++ GDExtension.
`tools/build.sh marionette` compiles `src/` via SConstruct, deploys the resulting `.so` to
`game/addons/marionette/bin/`, and copies `gdscript/` → `game/addons/marionette/scripts/`
(mixed-mode `HAS_CPP=true` path). `plugin.cfg` at the extension root declares both the
`.gdextension` and the editor plugin entry point; it is lifted to the addon root on deploy.

```
extensions/marionette/
├── CLAUDE.md
├── plugin.cfg                          (addon manifest — lifted to game/addons/marionette/ on build)
├── marionette.gdextension              (GDExtension manifest)
├── SConstruct                          (godot-cpp submodule build, output to bin/)
├── src/                                (C++ core)
│   ├── register_types.cpp / .h         (registers MarionetteCore et al.)
│   ├── marionette_core.cpp / .h        (autoload-facing root class)
│   ├── marionette_bone.cpp / .h        (extends PhysicalBone3D; SPD in _integrate_forces)
│   ├── spd_math.cpp / .h               (static helpers)
│   ├── marionette_composer.cpp / .h    (cost-weighted IK soup, engagement pump, strain)
│   ├── rhythm_readout.cpp / .h         (band-pass filter, drive-axis estimators)
│   └── ik_chain_solver.cpp / .h        (DLS Jacobian, Huber-loss soft constraints)
├── gdscript/                           (deploys to game/addons/marionette/scripts/)
│   ├── plugin.gd
│   ├── resources/                      (Resource subclasses)
│   ├── runtime/
│   │   ├── marionette.gd               (autoload wrapper that owns the C++ composer)
│   │   └── archetype_solvers/          (one file per archetype, authoring-time only)
│   ├── editor/                         (EditorPlugin, gizmos, docks, inspectors)
│   ├── data/                           (shipped .tres: profile, default BoneProfile, etc.)
│   ├── poses/, cyclic/, macros/, emotions/, overlays/   (preset libraries)
│   ├── posture_patterns/               (PosturePattern.tres library)
│   └── textures/                       (foot textures for profile BoneMap display)
└── tests/

docs/marionette/                        (plan, ARP mapping, BoneMap notes — repo-level)
tools/test_scenes/marionette_*/         (demo scenes live here, not inside the extension)
```

## Out of scope

- IK solvers (use Godot's `SkeletonModifier3D` subclasses; foot IK arrives in the balancing phase).
- Facial animation, morph target blending — separate system.
- Network replication of ragdoll state.
- Quadruped archetypes (humanoid first, architecture allows extension).
- Cloth / soft body.
- Sound synthesis or voice — separate system.
- Stimulus response / character response profiles / reaction mapping — consumer-level GDScript glue.

## Commit conventions

- Phase prefix: `[P1]`, `[P2]`, ..., `[P9]`.
- Type prefix: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`.
- Example: `[P3] feat: SPD controller with anatomical target interface`.

## Red flags that should halt work and escalate

1. Writing a "generic solver" spanning multiple archetypes.
2. Axis terminology bleeding into the public API (not debug output).
3. Per-frame joint motor or spring writes.
4. Two skeletons on one character.
5. Case-splitting left vs right beyond the `is_left_side` bit and Y/Z sign flip.
6. Muscle frame or permutation computed at runtime (must be authoring-time only).
7. Head, jaw, or eye scope confusion (head in, jaw/eyes out).
8. `BoneProfile` values changed per-frame (it's static data).
9. Overlay composition that produces out-of-range anatomical angles (should clamp to ROM).
10. Jolt exhibiting behavior contradicting PLAN.md assumptions.

Each indicates an architectural assumption is wrong and needs discussion.

---

## Quick API reference (Godot, heavily used)

| API | Use |
|---|---|
| `Skeleton3D.get_bone_pose_rotation(idx)` | Read animation target (bone-local rotation) |
| `Skeleton3D.get_bone_rest(idx)` | Rest pose for authoring-time frame computation |
| `Skeleton3D.get_bone_parent(idx)` | Hierarchy walk |
| `PhysicalBone3D.joint_type = JOINT_TYPE_6DOF` | Enable 6DOF joint per bone |
| `PhysicalBone3D.joint_rotation` | **Bakes anatomical frame into physics at creation** |
| `PhysicalBone3D.set("joint_constraints/x/angular_limit_upper", v)` | Set 6DOF angular limits post-creation (4.6 path; verified via `get_property_list()`). Lower bound is `..._lower`. Linear lock: `joint_constraints/<x\|y\|z>/linear_limit_<lower\|upper>` |
| `PhysicalBone3D._integrate_forces(state)` | SPD torque application path |
| `PhysicsDirectBodyState3D.apply_torque(vec)` | World-space torque |
| `PhysicalBoneSimulator3D` | Controls which bones are simulated |
| `PhysicalBoneSimulator3D.physical_bones_add_collision_exception(rid)` | Parent-child exclusion |
| `SkeletonProfile` + subclass | Retargeting profile (our custom extends this) |
| `BoneMap` | Maps source bone names → profile names |
| `EditorPlugin` / `EditorInspectorPlugin` / `EditorNode3DGizmoPlugin` | Editor tooling |

---

## Authoring vs runtime responsibility split (quick reference)

| Concern | Where computed |
|---|---|
| Muscle frame | Authoring time (during "Generate from Skeleton") |
| Per-bone anatomical basis (permutation or calculated-frame fallback) | Authoring time, baked into `BoneProfile` |
| `MarionetteBone.joint_rotation` | Ragdoll creation time, from `BoneEntry.anatomical_basis_in_bone_local()` |
| Joint ROM limits | Ragdoll creation time, from `BoneProfile` |
| Anatomical → joint-local target rotation | Runtime, but joint-local = anatomical post-creation, so it's identity |
| Bone-local (animation) → anatomical angles | Runtime, basis-column rotation via cached anatomical basis |
| SPD torque | Runtime, `_integrate_forces` |
| Emotion state blend math | Runtime, in anatomical space |
| Overlay envelope evaluation | Runtime, per-tick |
