# Cosmic Bliss — Design Update 2026-04-28 — Active Ragdoll C++ Core, Cost-Weighted Composer, Engagement Vector

**Audience: Repo organizer Claude (Claude Code session).**

This brief captures a set of architectural decisions made in a design session focused on (a) promoting Marionette's active-ragdoll core from GDScript to C++ from the start, (b) replacing the authored-profile body composer with a cost-weighted soup IK, (c) introducing a `(magnitude, phase, phase_noise)` engagement vector from Reverie that drives predictive rhythmic motion, and (d) deferring self-balancing and catch-step. Read every section before editing. Match the declarative voice of the existing canonical docs.

---

## Project conventions you must honor

Same conventions as prior updates, with one rule flipped for **Marionette specifically**:

- **GDScript by default — except Marionette's ragdoll core.** Marionette joins TentacleTech / Tenticles as a C++ extension. The justification under the existing top-level rule already applies (physics-tick rate at 60+ Hz, math-heavy inner loops). The `extensions/marionette/CLAUDE.md` line "ships as pure GDScript" and the `Marionette_plan.md` line "no GDExtension / C++ scaffolding here" both flip in this update.
- **Godot 4.6**, godot-cpp pinned per-submodule.
- Never propose: per-frame `ArrayMesh` rebuilds, per-frame `ShaderMaterial` allocation, `MultiMesh` for deforming meshes, `SoftBody3D` for any core system, SSBOs in spatial shaders.
- **Don't generate Godot test scenes.** Reference them in milestones, don't author the `.tscn`.
- **No padding.** Match the existing canonical voice; don't restate context.
- **Numbers are starting points.** Cost weights, frequency bands, response times — flag as tunable.
- **Don't renumber existing phases unless explicitly told.** This update tells you to: Phase 10 content is fully replaced, and the old Phase 10 content moves to a new Phase 14. Phase 12 (optional C++ port) is deleted. Sub-phase insertions inside other phases follow the existing P7.9 / P7.10 convention.
- **One concern per change.** Localized patches.

Canonical docs:
- `docs/architecture/TentacleTech_Architecture.md`
- `docs/architecture/TentacleTech_Scenarios.md`
- `docs/architecture/Reverie_Planning.md`
- `docs/marionette/Marionette_plan.md`
- `docs/tenticles/Tenticles_design.md`
- Top-level `CLAUDE.md`
- Per-extension `extensions/<name>/CLAUDE.md`

---

## Summary of changes

| # | Change | Doc(s) |
|---|---|---|
| 1 | Marionette becomes a C++ GDExtension; ragdoll core, SPD math, composer in C++ | `Marionette_plan.md` header; `extensions/marionette/CLAUDE.md`; top-level `CLAUDE.md` systems table |
| 2 | New Phase 2.0 — Marionette extension scaffold (SConstruct, .gdextension, register_types) | `Marionette_plan.md` (insert before existing P2.1) |
| 3 | Phase 5 SPD math + `MarionetteBone._integrate_forces` ship in C++ from the start | `Marionette_plan.md` (P5 patch) |
| 4 | Phase 10 fully replaced — was "balance + catch-step + foot IK"; now "composer + cost-weighted IK soup + engagement vector + strain" | `Marionette_plan.md` (P10 rewrite) |
| 5 | Old Phase 10 content (balance, catch-step, COM PD, support polygon, foot IK as balance aid) deferred to new Phase 14 | `Marionette_plan.md` (move) |
| 6 | Phase 12 (optional C++ port of SPD) deleted — ragdoll core is C++ from the start | `Marionette_plan.md` (remove) |
| 7 | Reverie writes `engagement_vector = (magnitude, phase, phase_noise)` per tick; consumed by composer | `Reverie_Planning.md` (new sub-section in §3 / Phase R6) |
| 8 | Reverie writes `body_rhythm_frequency_proposed → body_rhythm_frequency` via mindset-gated **frequency compliance curve** | `Reverie_Planning.md` (extend rhythm_and_waves R6 entry) |
| 9 | New continuous Stimulus Bus channel `body_strain` written by composer, read by Reverie for vocal/facial/breath/mindset modulation | `Reverie_Planning.md`; `TentacleTech_Architecture.md §8.1` (channel registration) |
| 10 | **Posture pattern library** (`PosturePattern` resources): mindset-driven micro-expression body deltas, blended additively into composer's posture-prior cost term — not target-pose lerps | `Reverie_Planning.md` (Phase R6) |
| 11 | **Predictive engagement pump** — composer estimates dominant drive axis from cycle-averaged pelvis velocity, then writes per-bone target oscillations using `body_rhythm_phase` directly. Lag-free. Replaces the reactive "read instantaneous velocity, push along it" sketch. | `Marionette_plan.md` (in P10 rewrite) |
| 12 | TentacleTech §6.11 (`RhythmSyncedProbe`) gets a one-paragraph note that the same `body_rhythm_phase` is now also read by Marionette's composer for the engagement pump | `TentacleTech_Architecture.md §6.11` (light amendment) |

---

## Why these changes

The current Marionette plan has SPD math + IK + composer in GDScript with C++ as a Phase 12 reserve. Profiling-driven porting is the right default for most extensions, but for Marionette specifically the design discussion ran into a wall: any time a feature with realism implications came up (cost-weighted multi-anchor IK, inverse-dynamics strain, predictive engagement pump), the answer was "we'll have to simplify because GDScript at 60Hz × 84 bones × 30 DOFs × Jacobian operations isn't viable." The user has explicitly chosen to remove that constraint by going C++-first, so the design isn't compromised by the implementation language. Mitigations for the compile-edit cost: every tunable lives in `.tres` resources or `@export` GDScript wrappers; iteration on weights, bands, mindset curves, posture patterns does not require a rebuild.

The composer change replaces the "blend authored profiles additively" model with a cost-weighted soup-of-goals optimizer. This is required because two concrete features cannot be expressed as profile blends: goal-directed reach (multi-anchor IK to a runtime target point) and engagement-vector pumping that adapts its DOF axis based on the drive geometry (in-sync vs antiphase tentacles). Profile blending is preserved as a *cost term contribution* to the soup — authored macros and Reverie reaction profiles still write to the body, but they do so by perturbing the posture-prior cost rather than directly writing SPD targets.

The engagement vector + frequency compliance + body_strain together close the perception ↔ action loop on the hero side. Player rhythm-tap proposes a frequency, Reverie's mindset gates compliance, Marionette integrates phase, composer applies engagement, body acts, strain feeds back to Reverie, mindset shifts, compliance changes. No state machines, no scripted unlocks — only continuous channels and one optimizer.

---

## Architectural decisions (binding)

These are commitments. Implement them; don't renegotiate.

1. **Composer is soup-of-goals, not layered priority.** Single weighted-cost optimization per tick. Hard-anchor goals get high weight (~100); primary reach goals moderate (~10); posture priors low (~1). Soft constraints use **Huber loss**, not L2 — this prevents ugly compromise poses when goals conflict.
2. **Composer feeds SPD as soft targets, not hard constraints.** SPD chases; failure is graceful. SPD itself is unchanged in structure (per-bone PD), just ported to C++.
3. **Engagement pump is 100% predictive.** Composer maintains cycle-averaged drive-direction estimators (`drive_axis_linear`, `drive_axis_angular`) updated once per cycle from pelvis velocity. Per-bone target oscillations are written using `cos(body_rhythm_phase + engagement_phase)`, not by reading instantaneous velocity. No filter latency in the active output.
4. **Posture priors are pattern-library superposition.** Mindset distribution writes weights into a stack of `PosturePattern` resources (toe curl, back arch, jaw slack, hand grasp, hip drop, neck loll, etc.). Composer sums weighted patterns into the posture-prior cost term. Reverie reaction profiles point at pattern stacks; this is consistent with how facial reactions already blend.
5. **Strain feeds Reverie via continuous Stimulus Bus channel `body_strain`.** Composer publishes scalar per tick = Σ saturation across all SPD-driven joints. Reverie consumes for vocal grunt / breath / facial tension / mindset drift toward Overwhelmed.
6. **Frequency lerp is slew-rate-limited** per mindset. `df_dt_max(mindset)` capped — body cannot jump tempos suddenly. Slow for resistant/overwhelmed; fast for aroused/edge.
7. **Two-stage strain.** IK solves once without strain cost (cheap path, most ticks). If any joint saturates in the solved pose, re-solve with strain penalty added. Avoids paying inverse-dynamics cost every tick.
8. **Pelvis is the single rhythm-readout anchor for v1.** Composer reads only pelvis linear + angular velocity for drive-axis estimation. Future expansion (sternum, head) is one-line addition; not in v1.
9. **Self-balancing, catch-step, COM PD, support polygon, foot IK as ground-tracking are deferred.** They become Phase 14 (a new late phase). Phase 10 in the active plan is now the composer + reach + engagement.
10. **Marionette ships as a C++ GDExtension from the first commit of Phase 2.** No "GDScript first, port later." `MarionetteBone`, `SPDMath`, `MarionetteComposer` are C++ classes registered via `register_types`. GDScript holds: resources, archetype solvers (authoring-time only), `MuscleFrameBuilder` (authoring-time), gizmos, editor tooling, test harnesses, pattern library `.tres`.

---

## C++ / GDScript boundary (binding)

Place these in C++:

- `MarionetteBone` (extends `PhysicalBone3D`, runs SPD in `_integrate_forces`)
- `SPDMath` (static helpers: `error_quaternion`, `compute_torque`, alpha/damping_ratio → kp/kd)
- `MarionetteComposer` (per-tick: reads body_rhythm_phase, integrates frequency, runs IK soup, computes strain, writes per-bone targets, publishes `body_strain`)
- `RhythmReadout` (band-pass filter on pelvis velocity feeding `drive_axis_*` estimators)
- `IKChainSolver` (DLS Jacobian, soup-of-goals, Huber-loss soft constraints; standalone helper class consumed by composer)

Place these in GDScript:

- All `Resource` types: `BoneEntry`, `BoneArchetype`, `BoneProfile`, `SignedAxis`, `PosturePattern`, `EngagementProfile`, `FrequencyComplianceCurve`, `RhythmAnchorBone` config
- All archetype solvers (`ball_solver.gd`, `hinge_solver.gd`, etc.) — authoring-time only, called from gizmo / build_ragdoll, not at runtime
- `MuscleFrameBuilder.gd` — authoring-time
- `Marionette.gd` (the autoload / scene-tree-facing wrapper that owns the C++ composer instance and exposes `set_bone_target()`, `set_goal()`, `clear_goals()`, `set_engagement_vector()`)
- All editor tooling, gizmos, inspector panels, import workflow scripts
- Test harnesses (`extensions/marionette/tests/run_tests.gd`)

Data exchange rule: GDScript writes resources and per-frame intent (goals, engagement vector, posture pattern weights) to `Marionette.gd`; that wrapper passes them once-per-change to the C++ composer via bound methods. C++ does not read GDScript callbacks per tick; it reads its own cached state.

---

## Phase reordering (binding)

| Old | New |
|---|---|
| P2 (existing P2.1–P2.14) | Unchanged. Insert **new P2.0** before P2.1: extension scaffolding (SConstruct, .gdextension, register_types, hello-world C++ class). |
| P5 (SPD math, MarionetteBone) | Unchanged structure. **Implementation language flips to C++.** All P5 sub-tasks (P5.1 SPDMath, P5.3 MarionetteBone, etc.) ship as C++ from the first commit of P5. |
| P10 (balance, catch-step, foot IK) | **Fully replaced.** Old content moves to new Phase 14. New P10 = "Composer, cost-weighted IK soup, engagement vector, posture pattern blending, strain feedback." |
| P11 (strength variants — already in plan) | Unchanged. |
| P12 (optional C++ port of SPD) | **Deleted.** Core is C++ from the start; nothing to port. |
| New P14 (was P10 content) | Self-balancing, catch-step, COM PD, support polygon, foot IK as balance/ground-tracking aid. Same task list as the deleted P10. |

---

## Patches

Each patch is targeted at a specific doc / section. Apply localized; do not bundle.

---

### Patch 1 — top-level `CLAUDE.md` systems table

Update the Marionette row in the Systems table:

> **Before:**
> | **Marionette** | Active ragdoll solver (SPD) | GDScript (SPD hot-path C++ port held in reserve — triggered only by profiling evidence at realistic character count) |
>
> **After:**
> | **Marionette** | Active ragdoll solver (SPD), cost-weighted IK composer | C++ core (SPD, composer, IK, strain, engagement) + GDScript glue (resources, authoring-time solvers, gizmos, editor tooling) |

No other change to top-level `CLAUDE.md`.

---

### Patch 2 — `extensions/marionette/CLAUDE.md`

Flip the language framing. The file currently characterizes Marionette as "pure GDScript" with C++ deferred. Replace that framing throughout with:

- The extension is a C++ GDExtension built via SConstruct.
- C++ ships: `MarionetteBone`, `SPDMath`, `MarionetteComposer`, `RhythmReadout`, `IKChainSolver`.
- GDScript ships: resources, archetype solvers (authoring-time), `MuscleFrameBuilder`, `Marionette.gd` autoload wrapper, editor tooling, tests.
- Data flows from GDScript → C++ via cached resource handoffs, not per-tick callbacks.

Preserve all existing content about archetype solvers, bone profiles, muscle frame, etc. — the GDScript-side architecture is unchanged. Only the C++/GDScript split framing flips.

---

### Patch 3 — `Marionette_plan.md` header

The plan currently states (paraphrasing): "no GDExtension / C++ scaffolding here. The addon ships as pure GDScript. A targeted C++ port of SPD math is held in reserve as an optional Phase 12, triggered only by profiling evidence."

Replace this paragraph with:

> Marionette ships as a C++ GDExtension from the start. The active-ragdoll core (SPD math, per-bone integration, composer, IK, strain, engagement) runs in C++ to avoid design compromises imposed by GDScript per-tick cost at 60Hz × 84 bones × 30 DOFs. Resources, archetype solvers (authoring-time), muscle frame builder, gizmos, editor tooling, and test harnesses remain GDScript. Tunables (cost weights, frequency bands, mindset curves, posture pattern libraries) live in `.tres` resources or `@export` properties on the GDScript wrapper, so iteration on parameters does not require a rebuild.

Remove the prior "C++ port held in reserve" wording entirely.

---

### Patch 4 — `Marionette_plan.md` new Phase 2.0 (extension scaffold)

Insert before existing P2.1:

> ## Phase 2.0 — Marionette C++ extension scaffold
>
> **Goal**: `extensions/marionette/` builds as a C++ GDExtension; the addon registers a `MarionetteCore` class accessible from GDScript with a no-op tick.
>
> ### Tasks
>
> - **P2.0.1** — `extensions/marionette/SConstruct` (mirror `extensions/tentacletech/SConstruct` structure — godot-cpp submodule, output to `bin/`).
> - **P2.0.2** — `extensions/marionette/marionette.gdextension` manifest.
> - **P2.0.3** — `src/register_types.cpp` / `register_types.h` — registers placeholder `MarionetteCore` class.
> - **P2.0.4** — `src/marionette_core.cpp` / `.h` — placeholder C++ class with `_process(delta)` no-op + `hello()` returning a string. Confirms GDScript can call into the extension.
> - **P2.0.5** — `tools/build.sh marionette` deploys to `game/addons/marionette/bin/`. Build script already supports both pure-GDScript and C++ addons; ensure mixed-mode (`HAS_CPP=true` path) deploys gdscript/ → `addons/marionette/scripts/`.
> - **P2.0.6** — Update `extensions/marionette/plugin.cfg` to declare both the `.gdextension` and the editor plugin entry point.
> - **P2.0.7** — Sanity test: GDScript test harness instantiates `MarionetteCore`, calls `hello()`, asserts return value. Establishes the bridge.
>
> ### Milestone
>
> Build succeeds. GDScript test calls into C++. Existing GDScript-side resources (BoneEntry, BoneProfile, archetype solvers from P2.1+) are unaffected. Subsequent phases will populate `MarionetteCore` with real logic.

---

### Patch 5 — `Marionette_plan.md` Phase 5 (SPD math) — implementation language flip

Phase 5's task list is structurally fine. Update the header to specify C++ implementation, and add explicit notes on each sub-task:

- **P5.1 SPDMath** → ships in `src/spd_math.cpp` / `.h`. Static methods: `error_quaternion(current, target)`, `compute_torque(error_axis_angle, omega, kp, kd, dt)`. Bound to GDScript via godot-cpp class registration only for unit-test access.
- **P5.2 alpha/damping_ratio → kp/kd converter** — same. Static C++.
- **P5.3 MarionetteBone** → C++ class extending `PhysicalBone3D` from godot-cpp. SPD runs in `_integrate_forces`. Reads target rotation from a cached value set by the composer. No per-tick GDScript dispatch.
- **P5.4 strength multiplier** — `MarionetteCore::set_global_strength(float)`, applied in C++.
- **P5.5 contact-triggered alpha reduction** — C++.
- **P5.10 unit tests** — GDScript test harness calls into C++ SPDMath via bound methods; verifies bit-equivalent output to a hand-computed reference vector.

The hip-tether + slider scaffolding (P5.6–P5.9) stays GDScript scene-side; sliders write to `Marionette.set_bone_target()` (the GDScript wrapper) which forwards to C++ via a bound method.

---

### Patch 6 — `Marionette_plan.md` Phase 10 — full replacement

Replace the entire existing Phase 10 section ("Self-balancing and foot IK") with the following:

> ## Phase 10 — Composer, cost-weighted IK soup, engagement vector, strain
>
> **Goal**: `MarionetteComposer` (C++) takes a soup of weighted goals (anchors, end-effector positions, posture priors from pattern library, engagement-vector pumping) and produces per-bone target rotations consumed by SPD. Strain is published as a continuous Stimulus Bus channel.
>
> Self-balancing, catch-step, support polygon, COM PD, and ground-tracking foot IK are **deferred to Phase 14**.
>
> ### Tasks
>
> - **P10.1** — `IKChainSolver` (C++): damped-least-squares Jacobian solver. Inputs: chain bones, goal stack, ROM limits per joint. Output: per-joint angle deltas. Soft constraints use Huber loss, not L2. Single iteration per tick (DLS converges acceptably in 1–2 iterations for soft-target chases). Hard goals (anchors) get weight ~100; primary reach goals ~10; posture prior ~1; engagement-pump targets ~5.
> - **P10.2** — Goal types: `PositionGoal(end_effector_bone, target_world_pos, weight)`, `OrientationGoal(end_effector_bone, target_quat, weight)`, `PinAnchor(bone, world_pos, hard_weight=100)`. All soft (composer feeds SPD as targets, not hard constraints).
> - **P10.3** — Posture-prior cost: composer maintains a stack of `PosturePattern` resources with weights. Each pattern is a per-bone delta map (StringName → Quaternion delta). Composer sums weighted deltas; the composed offset is applied as a low-weight cost term toward the perturbed rest pose.
> - **P10.4** — Engagement vector input: `MarionetteComposer::set_engagement_vector(magnitude, phase, phase_noise)`. Reverie writes per tick. Composer reads.
> - **P10.5** — `RhythmReadout` (C++): biquad band-pass filter on pelvis linear + angular velocity, bandwidth scaled to current `body_rhythm_frequency` (Q ≈ 2–3). Output cycle-averaged `drive_axis_linear` (3-vec) and `drive_axis_angular` (3-vec) updated once per cycle (not per tick — averaging window = one rhythm period).
> - **P10.6** — Predictive engagement pump:
>   ```
>   for each bone b in PropagationGraph with weight w_b > 0:
>     pump_offset_lin = w_b × magnitude × |drive_axis_linear|
>                     × drive_axis_linear_unit × cos(body_rhythm_phase + engagement_phase)
>     pump_offset_ang = (analogous, using angular axis)
>     bone_target[b] += pump_offset_lin (translated into per-bone rotation contribution)
>     bone_target[b] += pump_offset_ang
>     if engagement_phase_noise > 0:
>       bone_target[b] += per-bone-decoherent jitter scaled by phase_noise
>   ```
>   Pump direction is observed (estimator), pump phase is committed (read from `body_rhythm_phase` directly). No filter lag in the active output.
> - **P10.7** — Strain computation: per-tick, composer queries each `MarionetteBone` for current required-vs-clamp ratio. `body_strain = Σ smoothstep(0.7, 1.0, required_torque[j] / max_torque[j])²`. Published on Stimulus Bus continuous channel `body_strain`.
> - **P10.8** — Two-stage strain solve: solve IK once without strain cost. Compute strain. If any joint saturates above threshold, re-solve with `strain_cost` term added. Most ticks pay only the cheap pass.
> - **P10.9** — Frequency compliance integration: composer reads `body_rhythm_frequency_proposed` (Reverie writes) and lerps `body_rhythm_frequency` toward it at rate `compliance × dt × responsiveness`, capped by `df_dt_max` from the current mindset's frequency compliance curve.
> - **P10.10** — `body_rhythm_phase` integration in C++ — never reset, monotonically increasing modulo 2π for evaluation, integrated continuously from `body_rhythm_frequency × dt`. (The rev2 doc already commits this; this task confirms the integrator lives in `MarionetteComposer`.)
> - **P10.11** — Bind composer API to GDScript: `Marionette.set_engagement_vector(...)`, `Marionette.add_position_goal(...)`, `Marionette.clear_goals()`, `Marionette.set_posture_pattern_weights(Dictionary)`, `Marionette.get_body_strain()`, `Marionette.get_body_rhythm_phase()`, etc.
> - **P10.12** — `RhythmAnchorBone` config resource: lists which bones the rhythm-readout reads from. Default: pelvis only. Future-extensible to sternum/head without breaking the API.
> - **P10.13** — Composer diagnostic gizmo: in editor mode, draw `drive_axis_linear`, `drive_axis_angular`, current strain per joint as colored badge, current `body_rhythm_phase` and frequency, current engagement vector. Editor-only, no runtime cost.
>
> ### Performance budget (informational, profile to confirm)
>
> Per character per physics tick:
> - IK soup (DLS Jacobian on ~30 DOFs, ~5–10 cost terms, 1–2 iterations): target ≤ 0.3 ms in C++
> - Engagement readout + cycle-avg: ≤ 0.05 ms
> - Posture pattern stack blend: ≤ 0.05 ms
> - Strain (two-stage, mostly single-stage): ≤ 0.1 ms avg
> - SPD per bone × 84 bones: ≤ 0.1 ms
> - **Total composer + SPD ≤ 0.6 ms per character.**
>
> If profiling shows the Jacobian operation dominates, the cheap mitigation is **chain decomposition**: solve `(anchor → root)` and `(root → end_effector)` as separate sub-problems sharing the root, instead of one full-body block. Reserved as a fallback; not in P10.1.
>
> ### Milestone
>
> - GDScript test harness writes anchor goals + a position goal; composer produces a pose; SPD chases; final pose error ≤ 5 cm at the goal end-effector under no contact.
> - Engagement vector at `(magnitude=0.7, phase=π/2, phase_noise=0)` on a tethered character produces visible velocity-phase pumping along whatever DOF the test rig drives the pelvis along (vertical drive → vertical bob; rotational drive → pelvic rocking). Same code path; different DOF emerges.
> - Strain channel publishes scalar > 0 when goal is geometrically reachable but torque-bounded; composer's two-stage solve redistributes load; channel value drops once a feasible distribution is found.
> - Frequency compliance: in a "calm" mindset (preferred band 0.3–0.6 Hz), proposed frequency = 1.5 Hz produces only slow drift in `body_rhythm_frequency` (does not converge). In an "aroused" mindset (preferred 0.8–1.5 Hz), same proposed frequency converges within ~2–3 cycles.

---

### Patch 7 — `Marionette_plan.md` new Phase 14 (deferred balance content)

Insert as a new phase at the end of the existing phase list (after current P11 — strength variants, and any other phases):

> ## Phase 14 — Self-balancing, catch-step, foot IK as ground-tracking
>
> **Goal**: character stands against small pushes, takes a procedural catch-step against larger pushes, falls cleanly on overwhelming pushes. Feet track uneven ground.
>
> This phase contains the task list previously assigned to Phase 10, deferred until the composer + IK + engagement system (new P10) has stabilized. Foot IK in this phase is *as a goal in the composer's soup* — feet contribute a `PositionGoal` toward ground-raycast points with moderate weight.
>
> ### Tasks
>
> [Carry the original P10.1–P10.10 task list verbatim, with one structural change: P10.4's "IK outputs feed SPD as targets" is now satisfied by the composer's existing soup; foot IK becomes "add foot ground-track goal to the composer's goal stack at a per-leg weight." Other tasks (COM, support polygon, balance PD, catch-step, state machine, balance tab) stay as written.]
>
> ### Milestone
>
> [Carry the original P10 milestone verbatim.]

---

### Patch 8 — `Marionette_plan.md` Phase 12 deletion

Remove the existing "Phase 12 (optional) — Targeted C++ port of SPD hot path" section in its entirety. The core is C++ from the start; this phase no longer exists. If any other section cross-references P12, replace with "see P5 (C++ from the start)".

---

### Patch 9 — `Reverie_Planning.md` engagement vector outputs

In the section that lists Reverie's outputs to other systems (currently mentions facial blendshapes, vocal output, body postures), add a new sub-section:

> ### Engagement vector
>
> Reverie publishes a per-tick engagement vector consumed by `MarionetteComposer`:
>
> ```
> engagement_magnitude   ∈ [0, 1]    // how strongly the body adds to the rhythm
> engagement_phase       ∈ (-π, π]   // offset from body_rhythm_phase
> engagement_phase_noise ∈ [0, 1]    // decoherence; high values = phase scrambling
> ```
>
> The vector is produced by Reverie's reaction profile blend: each `ReactionProfile.tres` declares default values; Reverie blends across active mindset states with their distribution weights. The vector lives in a continuous (`magnitude × e^(i × phase)`) disk; the four named modes are regions:
>
> | Mode | Magnitude | Phase | Noise |
> |---|---|---|---|
> | Refuse | high | irrelevant | high (scrambled) |
> | Accept | ~0 | irrelevant | ~0 |
> | Comply | moderate | 0 (phase-locked to displacement) | ~0 |
> | Engage | high | +π/2 (phase-leads displacement → velocity-phase pump) | ~0 |
>
> Mindset → engagement vector mapping is authored in `ReactionProfile.tres`; Reverie does not write joint angles. Marionette's composer consumes the vector and produces the per-bone effort.

---

### Patch 10 — `Reverie_Planning.md` frequency compliance curve

In the same Phase R6 / outputs section (or in a new sub-section about rhythm coupling — the rev2 update already ties Reverie to `body_rhythm_frequency`):

> ### Frequency compliance
>
> The player (or any external driver — encounter scripting, AI suitor, etc.) publishes a `body_rhythm_frequency_proposed` value on the Stimulus Bus. Reverie does not pass it through directly. Each mindset state has a `FrequencyComplianceCurve` (`Resource`) defining:
>
> ```
> preferred_band: Vector2  // min, max Hz
> compliance_curve: Curve  // 0..1 across freq, peaks inside preferred_band
> df_dt_max: float         // slew rate cap; max d(body_rhythm_frequency)/dt
> ```
>
> Reverie computes the active mindset's effective curve as a weighted blend across the mindset distribution. Marionette's composer (P10.9) then lerps `body_rhythm_frequency` toward `proposed` at rate `compliance(proposed) × responsiveness`, capped by `df_dt_max`.
>
> Authored starting points (tunable):
>
> | Mindset | Preferred band | df_dt_max | Notes |
> |---|---|---|---|
> | Calm / Yielding | 0.3–0.6 Hz | 0.2 Hz/s | Slow lock at low rates |
> | Aroused | 0.8–1.5 Hz | 0.5 Hz/s | Fast tracking |
> | Edge / Blissful | 1.5–2.5 Hz | 0.7 Hz/s | Fast but Overwhelmed accumulates if held |
> | Resistant | (compliance ≈ 0 across all freq) | 0.05 Hz/s | Body refuses |
> | Overwhelmed / Dulled | unstable / narrow | 0.1 Hz/s | Tracks briefly, breaks |

---

### Patch 11 — `Reverie_Planning.md` `body_strain` channel

Add the channel to the Stimulus Bus channels Reverie reads (the existing list mentions `orifice_state`, `arousal`, etc.):

> ### `body_strain` (continuous channel, read)
>
> Marionette's composer publishes `body_strain ∈ [0, 1]` per tick, computed as the sum of saturation across all SPD-driven joints:
>
> ```
> body_strain = clamp(Σ smoothstep(0.7, 1.0, required_torque[j] / max_torque[j])² / N, 0, 1)
> ```
>
> Reverie consumes for:
> - Vocal modulation (grunt, breath catch at high values)
> - Facial tension (jaw clench, brow knot blendshapes)
> - Breath rate adjustment (faster when straining)
> - Mindset drift toward Overwhelmed when sustained above threshold for more than a few seconds
>
> Closes the self-regulation loop: high strain → mindset shifts toward Overwhelmed → engagement_magnitude decreases → strain reduces.

---

### Patch 12 — `Reverie_Planning.md` posture pattern library

In Phase R6 (the existing "drive body postures" sub-phase that the rhythm_and_waves doc and earlier planning placed there):

> ### Posture pattern library
>
> Body postures are not authored as full target poses. They are authored as small per-bone delta maps (`PosturePattern.tres` resources) representing micro-expressions:
>
> ```
> # PosturePattern.tres
> name: StringName             // "toe_curl", "back_arch", "jaw_slack", "hand_grasp", "hip_drop_left", ...
> bone_deltas: Dictionary[StringName, Quaternion]
> default_weight_curve: Curve  // optional (e.g. ease-in for slower micro-expressions)
> ```
>
> Reverie's reaction profiles point at one or more `PosturePattern` resources with per-mindset weights. Per-tick:
>
> ```
> pattern_stack = []
> for each active mindset state with distribution weight m:
>     for each pattern in mindset.posture_patterns:
>         pattern_stack.append((pattern, m × pattern.weight))
> Marionette.set_posture_pattern_weights(pattern_stack)
> ```
>
> Marionette's composer (P10.3) consumes the stack as the posture-prior cost term: composer sums weighted bone-deltas across the stack and uses the composed offset as a low-weight target perturbation in the IK soup.
>
> Default starting library: `toe_curl.tres`, `back_arch.tres`, `jaw_slack.tres`, `hand_grasp.tres`, `hip_drop_left.tres`, `hip_drop_right.tres`, `neck_loll.tres`, `eye_roll.tres` (eye_roll lives on the face rig, not body — but pattern files are uniform; both consumers read the same shape).

---

### Patch 13 — `TentacleTech_Architecture.md` §6.11 light amendment

In §6.11 (`RhythmSyncedProbe` — body-rhythm-locked self-insertion), add one paragraph at the end:

> **Note on shared clock consumers.** The same `Marionette.body_rhythm_phase` integrated by Marionette is now also read by `MarionetteComposer` (Marionette plan P10) for predictive engagement pumping of the body. `RhythmSyncedProbe` and the composer therefore share a single phase variable for body-tentacle rhythm coupling — no replication. Frequency is set by Reverie via the frequency-compliance pipeline (Reverie planning, frequency compliance curve); both consumers see the same value automatically.

---

## Concrete schemas

### `EngagementProfile.tres` (Reverie-side)

Embedded in `ReactionProfile.tres` (per-mindset reaction profile), or stand-alone if useful:

```
class_name EngagementProfile extends Resource
@export var magnitude: float = 0.0          # 0..1
@export var phase: float = 0.0               # -π..π
@export var phase_noise: float = 0.0         # 0..1
```

### `FrequencyComplianceCurve.tres`

```
class_name FrequencyComplianceCurve extends Resource
@export var preferred_band: Vector2          # min, max Hz
@export var compliance_curve: Curve          # 0..1 across freq domain
@export var df_dt_max: float = 0.3           # Hz/s slew limit
```

### `PosturePattern.tres`

```
class_name PosturePattern extends Resource
@export var pattern_name: StringName
@export var bone_deltas: Dictionary          # StringName bone_name → Quaternion delta
@export var default_weight_curve: Curve      # optional ease curve
```

### Composer C++ public API (called from `Marionette.gd`)

```cpp
class MarionetteComposer : public Object {
public:
    // Goal management
    void clear_goals();
    void add_position_goal(StringName end_effector, Vector3 world_pos, float weight);
    void add_orientation_goal(StringName end_effector, Quaternion world_quat, float weight);
    void add_pin_anchor(StringName bone, Vector3 world_pos, float weight);

    // Posture pattern stack
    void set_posture_pattern_weights(TypedArray<Dictionary> stack);  // [{pattern, weight}, ...]

    // Engagement vector (Reverie-driven)
    void set_engagement_vector(float magnitude, float phase, float phase_noise);

    // Frequency / rhythm
    void set_proposed_rhythm_frequency(float hz);
    void set_frequency_compliance_curve(Ref<Resource> curve);
    float get_body_rhythm_phase() const;
    float get_body_rhythm_frequency() const;

    // Strain readout
    float get_body_strain() const;
    PackedFloat32Array get_strain_per_bone() const;

    // Configuration
    void set_rhythm_anchor_bone(StringName bone);    // default "Pelvis"
    void set_propagation_graph(Ref<Resource> graph);

    // Tick (called by Marionette.gd from _physics_process)
    void tick(float dt);
};
```

### Cost-term formulas (in C++ composer)

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

### IK solver — DLS Jacobian (in `IKChainSolver`)

Standard damped-least-squares form:
```
J  = ∂goals/∂joint_angles    // stacked Jacobian, one row per scalar goal
λ  = damping (0.01..0.1, scaled by goal-error magnitude)
Δθ = J^T (J J^T + λ² I)⁻¹ × goal_error
```

For a 30-DOF chain × ~10 scalar goals, the matrix `(J J^T + λ² I)` is 10×10 — invert via Cholesky or LU; well under 1000 ops in C++.

---

## Pitfalls and forward-looking notes

- **Soup weights need calibration before posture costs are tuned.** If hard-anchor weights are too low, the body floats away from its anchors when other goals conflict. Default starting weights: anchors 100, primary goals 10, engagement-pump targets 5, posture priors 1. Verify before authoring patterns.
- **Huber δ must be tuned per cost term.** A position goal in meters, an orientation goal in radians, a posture prior in radians per bone — each has its own scale. Default: δ_pos = 0.05 m, δ_ang = 0.1 rad, δ_posture = 0.05 rad. Per-term `@export`.
- **Drive-axis estimator needs warm-up.** First cycle after rhythm starts has no estimate; engagement_magnitude should ramp from 0 over ~one cycle to avoid jumps. Author the ramp inside the composer, not as a Reverie obligation.
- **Pattern stack ordering matters when patterns conflict.** Two patterns prescribing opposing deltas on the same bone produce a weighted average; soup will sum and compromise. If a pattern *must* override (e.g., "back arch" overrides a less-specific "spine relax"), give it a much higher weight rather than relying on order.
- **Frequency slew rate limit interacts with phase integration.** When `body_rhythm_frequency` is changing, `body_rhythm_phase` keeps advancing smoothly because it integrates the *current* frequency every tick. There's no phase glitch on frequency change. Document this in the composer comment.
- **Strain channel can oscillate near threshold.** Add hysteresis (Schmitt-trigger style): emit "high strain" when strain > 0.6; emit "strain cleared" only when strain < 0.4. Otherwise Reverie sees flutter at a single threshold.
- **Composer tick ordering.** Per physics tick: (1) integrate body_rhythm_frequency toward proposed (slew-limited); (2) integrate body_rhythm_phase from frequency; (3) update RhythmReadout estimators (cycle-avg if a cycle just completed); (4) build goal soup; (5) solve IK; (6) compute strain; (7) if saturated, re-solve with strain term; (8) apply engagement pump offsets to bone targets; (9) hand targets to SPD; (10) publish body_strain. Keep this order in the composer comment header.
- **Chain decomposition is the perf escape hatch.** If profiling shows the full-body Jacobian dominates, decompose into sub-chains sharing the root. Don't pre-decompose in v1; default to whole-body for correctness, profile, decompose only if needed.
- **Per-bone pumpable flag is unnecessary.** PropagationGraph weights of 0 already exclude bones from the pump. Don't add a parallel flag.

---

## Informal validation scenarios

These are not phase milestones; they are thought-experiment-grade acceptance scenarios that the composer + engagement + strain stack should be able to produce. Mention in the docs as informal validation; do not author `.tscn` files for them without explicit ask.

1. **Hanging-toe-reach.** Hero suspended by both hands (pin anchors); soft position goal on the toe pointing at runtime-controlled target P. Same composer; varying P produces the bifurcations described in the design discussion (close P → only knee/hip flex; marginal P → spine + hip + leg all engage; unreachable P → body extends along residual gradient, body_strain rises). Mindset modulates posture-prior weights, changing the *shape* of the reach (rigid arched vs curled yielding).

2. **Two-tentacle bifurcation (in-sync vs antiphase).** Hero in X-suspension; two tentacles on pelvic orifices. With engagement_magnitude = 0.8, engagement_phase = π/2: in-sync drive produces vertical pelvis bob (drive_axis_linear dominant, drive_axis_angular ≈ 0); antiphase drive produces pelvic pitch rocking (angular dominant, linear ≈ 0). Same code path, no scenario-specific logic.

3. **Frequency lock from rhythm-tap.** Player taps rhythm via mouse; `proposed_rhythm_frequency` published on the bus; mindset = "aroused" (preferred band 0.8–1.5 Hz); `body_rhythm_frequency` converges toward proposed within ~2–3 cycles. Repeat with mindset = "calm" + same proposal: convergence does not happen; body_rhythm_frequency stays in 0.3–0.6 Hz band.

4. **Strain self-regulation.** Set engagement_magnitude artificially high (1.0) on a hero with weak strength multiplier (0.5). body_strain rises within a few cycles; Reverie consumes; mindset drifts toward Overwhelmed; Overwhelmed reaction profile sets engagement_magnitude lower; strain falls. Loop closes without scripted intervention.

5. **Refuse breaks resonance.** Engagement_magnitude = 0.8, engagement_phase_noise = 0.9. Even with player-tapped rhythm matching the orifice ring's natural frequency, ring amplitude does not bloom (phase-decoherent body contribution dissipates rather than reinforces). Confirms refuse mode is decoherence, not phase opposition.

---

## Final notes for the repo organizer

- These patches touch four canonical docs and one extension-level CLAUDE. Land them as separate localized commits. Do not bundle into a megacommit.
- Verify cross-references: rhythm_and_waves_2026-04-27 already established `body_rhythm_phase` and `body_rhythm_frequency`; this update *consumes* and *extends* those; make sure both docs read consistently after edits.
- The composer + IK + engagement work is large. The phase content in Patch 6 is intentionally specific so the implementer has unambiguous targets. If a sub-task surfaces an architectural question (e.g., a cost term needs a specialization not anticipated here), surface it in a follow-up design-update doc rather than improvising in the canonical doc.
- The rhythm anchor is pelvis-only for v1. Resist expanding to multi-anchor in this update; that's a future expansion.
- Self-balancing returns in Phase 14. Don't delete its task list — preserve it verbatim from the old Phase 10.

End of update.
