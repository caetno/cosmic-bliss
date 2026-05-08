---
name: TentacleTech state at 2026-05-07
description: Phase 4 close-out cluster active; Phase 4.5 (XPBD warm-start + Oriented Particles) opened 2026-05-07; Phase 6 grows §9.1 ProceduralContactSynth; soft-region clusters land downstream of 4.5
type: project
originSessionId: fdb3f1a6-d436-49f2-a7ec-40f5e922e2da
---

**Update 2026-05-07** — Phase 4.5 is now explicitly **opened** (was a deliberately-unopened placeholder). Trigger: techniques-survey review committed two upgrades — procedural contact audio (Phase 6 addition, §9.1) + Marionette soft-region particle clusters. The latter requires shared particle representation with TentacleTech, which is what Phase 4.5.C (Oriented Particles, Müller & Chentanez 2011) supplies. Brief: `docs/Cosmic_Bliss_Update_2026-05-07_procedural_audio_and_soft_regions.md`. Phase 4.5 slices: 4.5.A body-local persistent contacts (extends 4S brief, `MAX_CONTACTS_PER_PARTICLE = 3`); 4.5.B λ warm-start across ticks; 4.5.C per-particle quat + ω. Phase 6 grows item 22a `ProceduralContactSynth` (custom AudioStreamPlayback subclass on the audio thread, four voices: slip-friction / squelch / stretch / fluid film, all driven by existing bus channels). Marionette gains a new "Soft-region particle clusters" section after the jiggle-bone section, gated on Phase 4.5 landing.

---

**Current focus:** Phase 4 close-out cluster — slices 4M-pre, 4M, 4N, 4O.
Spec lives at `docs/Cosmic_Bliss_Update_2026-05-03_phase4_wedge_robustness.md`;
sub-Claude should follow that doc verbatim. Status table in
`extensions/tentacletech/CLAUDE.md` is current as of 2026-05-03.

The cluster addresses the "tentacle wedged between two solid colliders"
flicker that 4I/4J/4K/4L mitigated but never resolved. Root cause is
structural — `EnvironmentProbe::probe` uses `get_rest_info` which returns
one body per particle, so wedged particles see a flickering "nearest"
contact normal that no amount of damping or cleanup can lock.

**Why Phase 5 is gated behind 4O, not just 4M:** the orifice rim is itself
a multi-contact wedge geometry (8 ring bones around a particle = up to 8
simultaneous contacts). Starting Phase 5 on a single-contact probe would
compound the bug across two phases. 4O (sub-stepping) is bundled because
Phase 5 will produce thrust scenarios immediately and §13 had it deferred
to Phase 9.

## Non-obvious findings worth keeping

### Singleton-target path bypasses `pose_softness_when_blocked`

Slice 4F shipped `pose_softness_when_blocked` on TentacleMood +
BehaviorDriver as the documented fix for "tentacle jitters between legs".
The driver applies it in `behavior_driver.gd:478-479` *only* to the
distributed pose-target loop. The singleton target path
(`Tentacle::set_target` → `pbd_solver.cpp:154-157` calling
`project_target_pull`) ignores it entirely.

Any AI driver that writes a tip target via `Tentacle::set_target` (rather
than the distributed pose-target buffer) will see full-stiffness target
snap each iter regardless of contact state. The bundled `BehaviorDriver`
writes pose targets only, which is why this was missed across slices
4F → 4L.

Slice 4M-pre.2 fixes by moving the softening into the solver
(`set_target_softness_when_blocked`) so both target paths honor it. Watch
for this pattern when reviewing any future "soften X on contact" feature —
ask whether all upstream callers go through the same code path.

### Phase 4.5 placeholder (narrowed 2026-05-03)

After reading Obi 7.x's solver source (under `docs/pbd_research/Obi/`,
synthesis at `docs/pbd_research/findings_obi_synthesis.md`) the 4.5
placeholder shrank significantly:

**Moved INTO the close-out cluster (slice 4M / 4M-XPBD / 4P):**
- Per-contact persistent lambda accumulators (warm-starting). The
  *infrastructure* needed for multi-contact correctness anyway, so it
  comes free with 4M.
- XPBD compliance on the distance constraint. ~6 lines once the lambda
  buffer is in place. New slice 4M-XPBD bundles it with 4M.
- Sleep threshold + max depenetration cap. New slice 4P, two one-liners
  from Obi `Solver.compute`.
- Per-tick friction budget. Was flagged in
  `2026-05-02_phase4_friction_correction.md` "Known sub-correctness."
  Becomes moot under per-contact lambda accumulation — each contact's
  `normal_lambda` IS the friction budget for that contact.

**Still in 4.5, but smaller scope:**
- Per-collider material composition (Obi-style Average/Min/Multiply/Max
  combine modes). Open during Phase 6 (stimulus bus) when surface
  tagging lands.
- CCD against capsules. Promote only if sub-stepping (4O) proves
  insufficient for thrust scenarios.

**Won't borrow from Obi:**
- 2D friction pyramid — 1D cone is fine for chains.
- Rolling friction — particles don't rotate.
- Sequential vs Jacobi mode toggle — our CPU solver doesn't need both.
- Compute-shader port — wrong scale for our particle counts.

### Slice 4M reshape (2026-05-03)

The originally-drafted "bisector friction normal" heuristic for
multi-contact particles is superseded by the Jacobi-with-atomic-deltas-
and-SOR pattern Obi ships (`ContactHandling.cginc` + `AtomicDeltas.cginc`).
Each contact owns its own normal/tangent lambda accumulators; position
deltas accumulate via a per-particle scratch buffer; an apply pass
divides by per-particle constraint count and applies with an SOR factor
(default 1.0). Generalizes to N contacts without bisector special-cases.
The `iter_dn_buffer` patch from slice 4L and the 4J end-of-tick cleanup
both go away — both were patching the lack of lambda accumulation.

### Phase 5 head-start: PinholeConstraints is the orifice abstraction

Obi Rope's `PinholeConstraints.compute` (added 2026-05-03 with the
Rope/Cloth source drop) implements the full orifice mechanic we plan
in §6: a fixed offset on a collider grips a rope-edge `mix` point,
with XPBD compliance, motor force + target velocity, artificial
friction, range clamping, and edge advancement when the cursor slides
past edge boundaries. **When Phase 5 opens, re-read this file before
drafting the 8-direction-ring-bone orifice** — the 8 directions can
become 8 PinholeConstraint instances on the same collider with
different angular offsets, keeping the bilateral compliance idea but
using proven math. Full discussion in the synthesis doc § "Addendum
2026-05-03 (part 2)".

Adjacent finding: `ChainConstraints.compute` is a direct (non-iterative)
tridiagonal solver for the entire chain at once — O(N) per pass,
mathematically exact, but doesn't compose with multi-contact softening.
Park as Phase 9 polish for free-air segments only; does not change the
4M-XPBD per-segment plan.

### Workflow precedent for spec-doc edits

Architecture-doc edits flow through update docs, not direct edits. Pattern
established by `Cosmic_Bliss_Update_2026-05-02_phase4_friction_correction.md`:
update doc is written; sub-Claude implements; top-level reviews; once
approved, top-level applies the §X spec edits and stamps the update doc
"applied." The 2026-05-03 wedge-robustness doc has its post-review §13/§14
edits queued in its own "Spec edits to apply post-review" section.

## Tests known to be unrelated-broken

`test_tentacle_behavior` has 2 pre-existing failures unrelated to Phase 4
work — flagged in the slice 4L row of the CLAUDE.md status table. Don't
chase them as part of the close-out cluster.
