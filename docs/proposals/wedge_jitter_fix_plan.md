# Wedge Jitter Fix Plan — slices 4S through 4X + MAX bump

Drafted 2026-05-05 after the 4Q diagnostic + 4Q-fix + 4R landed. Captures the residual-jitter fix queue + adjacent Phase 5 rim robustness work, sequencing, and acceptance criteria.

The queue covers two related but distinct concerns:
1. **Wedge jitter fixes** (4S–4V + MAX bump): the active-probing leg-swing + tentacle-particle-flicker problem
2. **Phase 5 rim robustness** (4X): preventing tentacle slip-through under stretched orifice rims — separate concern, lives here because it touches the same orifice contact code path

## Problem statement

User-reported visible jitter under active probing (mood preset = `probing.tres`) while a tentacle is wedged between Kasumi's leg ragdoll bones. Two distinct failure modes confirmed by round-1 through round-4 diagnostics at `game/tests/tentacletech/test_4q_*.gd`:

**Mode A — stick-slip oscillation** (low lubricity / high friction, active driver). Probing target pull builds tangent_lambda past static cone → kinetic release → 1–2 tick high-velocity slip → reciprocal impulse swings the leg → contact re-establishes at displaced point → next stick phase. Visible as cm-scale leg swing (1.39 rad/s peak at lub=0.0 baseline).

**Mode B — contact-point churn** (high lubricity / low friction, active driver). Driver continuously pushes the chain into the wedge; chain particles slide tangentially across the convex-hull surface; probe re-samples a different `hit_point` every tick because contact is re-acquired fresh each call. Visible as tentacle-particle flicker (340 hit_point shifts in 240 ticks at lub=1.0). Legs don't move (no friction reciprocal at lub=1.0) but the tentacle visibly oscillates.

## Design floor: unconscious must work

The simulation must be stable without leaning on Marionette's active layers (SPD damping, reaction clenching, body_rhythm phase-lock). Unconscious is a real gameplay state and the worst-case stability scenario — the body is approximately the passive ragdoll our test scenes have been simulating. Active reactions become amplitude reduction *on top of* an already-stable base, not the load-bearing stability mechanism.

Implication: every fix in this plan must work standalone in TentacleTech without depending on what Marionette does.

## What 4Q-fix and 4R already shipped

- **4Q-fix (2026-05-05)**: tension-aware target softening — per-iter taper that reduces target pull when `|tangent_lambda| / static_cone > 0.8`. Reduces leg ang_max from 1.395 → 0.757 rad/s at lub=0.0 (~46% improvement). Doesn't extinguish stick-slip; equilibrium settles past saturation under heavy probing.
- **4R (2026-05-05)**: RID-keyed lambda warm-start machinery — `set_environment_contacts_multi` now matches incoming RIDs to previous slot RIDs and preserves `normal_lambda` + `tangent_lambda` across calls. New `reset_environment_contact_lambdas()` for outer-tick boundary. Default substep flip (1×4 → 4×1) was implemented end-to-end but reverted: it interacts destructively with the 4Q-fix taper formula (warm-started tlam at iter 0 of single-iter substeps creates a hard taper switch instead of the multi-iter ramp the formula was tuned for). Machinery in place; default unchanged.

Current best: lub=0.0 leg_ang_max = 0.757 rad/s, lub=1.0 hit_point shifts = 340/240 ticks. Both still visible.

## Slice queue

### 4S — contact-local-frame persistence (in flight; verify-first brief out)

**Closes Mode B.** Mimics Obi's contact persistence pattern: store contact point + normal in the colliding body's local frame, transform through the body's current world transform at solve time. Re-probe only when particle drifts past a hysteresis radius. Moving collider's contact moves with it; sliding particle sees a smooth track instead of a tick-discretized re-sample.

Status: verify-first brief out to sub-Claude (`docs/proposals/4S_obi_contact_persistence_brief.md`). Brief reads relevant Obi 7.x source files and reports findings + adaptation proposal before any code lands. Implementation slice (4S-impl) gates on brief approval.

Bundles **substep gravity rescale** (5-line bug fix in `predict()`) since both touch the substepping path and gravity rescale doesn't enable anything alone.

### 4T — pose-target rate limiting (next; independent of 4S)

**Source-side complement to 4Q-fix; universal across consciousness states.** Currently the driver can write arbitrarily large per-tick target deltas and the solver tries to satisfy them in one tick. Rate limit caps the per-tick target movement at `target_velocity_max × dt`, smoothing input regardless of what friction can hold. Source-side cap on tension build, complementary to the cone-side 4Q-fix.

Highest-leverage TentacleTech-side mechanism that doesn't depend on Marionette's active layers — works equally well against an awake, sleeping, or unconscious body.

### 4U — per-collider material composition (Phase 4.5 placeholder)

**Friction headroom for unconscious-state contacts.** Promote `friction_static` from a tentacle-global to a per-contact composition: `μ = combine(particle_material, collider_material, mode)` where mode is Average / Min / Max / Multiply (Obi convention). Author "high friction on Kasumi's leg/torso surfaces" without globally raising lubricity. Critical for unconscious states where active grip from the body is absent and friction is the only thing holding contacts.

Larger scope: introduces a surface-tagging system on colliders. Defer until 4S + 4T land; not the immediate next step.

### 4V — substep gravity rescale

**5-line bug fix.** Position-Verlet under N substeps under-applies gravity by 1/N (per-substep `gravity × sub_dt²` totals `gravity × outer_dt² / N` instead of `gravity × outer_dt²`). Obi rescales per-substep. We don't. Doesn't enable substep flip alone but removes one structural reason 4R's flip was misshapen. Bundle with 4S-impl since both touch the substep path.

### MAX_CONTACTS_PER_PARTICLE 2 → 3

**Independent slice; Phase 5 dependency.** Needed for orifice rim 3-surface wedges and for the Kasumi-with-glutes case (5 adjacent colliders potential). Memory cost trivial. Not a wedge-jitter-fix proper but lands cleanly alongside any other slice in this queue.

### 4X — capsule contacts between rim beads (Phase 5 rim robustness, NOT jitter)

**Closes tentacle slip-through under stretched rim.** Currently the type-2 contact algorithm tests tentacle particles against discrete rim bead spheres. At 8 beads per loop and 4× rim stretch, bead spacing reaches ~50 mm — comparable to or exceeding tentacle particle radius. A fast-moving tentacle could geometrically slip *between* two adjacent rim beads with no contact resolution.

**The fix:** each rim segment between bead k and bead k+1 becomes a stretchy capsule for collision purposes — endpoints are the live particle positions, length stretches with the rim, radius is per-segment authored (default = mean of endpoint contact radii). Type-2 contact algorithm switches from "tentacle particle vs each rim bead sphere" to "tentacle particle vs each rim segment capsule." Closest-point-on-segment is closed-form (one dot product + clamp).

Bilateral push back into the rim distributes barycentrically: contact at parameter `t ∈ [0, 1]` along segment k→k+1 splits the rim-side delta as `(1−t)` to bead k and `t` to bead k+1. Same lambda accumulators per contact slot; same `inv_mass` weighting; just shared between two endpoints instead of one.

This is what Obi does for rope-vs-rope and chain-style contacts (their `chain` colliders). Mechanically natural. Cost ~128 ops per loop per tick — trivially cheap.

**Why this matters even without jitter:**
- 8 anchors authored per orifice (the user's working assumption for Blender weight painting time) is fine *at typical stretch* but slip-vulnerable at extreme stretch with thin tentacles. Capsules close that vulnerability geometrically.
- Stretchy capsules track dilation naturally — contact remains continuous around the rim circumference at any stretch, regardless of bead count.
- Lets the user keep authoring discipline at 8 beads per loop without having to compensate with denser rigging on every orifice.

**Independent of 4S/4T/4U/4V.** Touches `_collect_type2_contacts` in `orifice.cpp` only. Can land before, after, or in parallel with the wedge-jitter slices. Sized small (1-day slice).

## Sequencing

Recommended order:

1. **4T pose-target rate limiting** — independent, high leverage, source-side. Can land while 4S brief is in review.
2. **4S brief review** → **4S-impl + 4V substep gravity rescale** bundled.
3. Visualize. If residual jitter is below threshold, stop.
4. **4U per-collider material composition** if friction headroom is still the limiting factor, or **MAX 2 → 3** if Phase 5 needs it sooner.

**4X is independent** of the above sequence. Land it whenever convenient — between any of 1–4, or after 4 if it hasn't surfaced as urgent. Since it touches `orifice.cpp::_collect_type2_contacts` only, no scheduling conflict with the chain-side work.

Marionette-side work (SPD wiring, joint stiffness/damping tuning) is no longer counted against the wedge-jitter fix path. It's still useful for active-state polish but not load-bearing for the floor case.

## Acceptance criteria (per slice)

Every slice in this queue ships with:

1. **Stick-slip regression preserved.** `test_4q_probing_regression.gd` A/B bound (taper-on ≤ 70% of taper-off `leg_ang_max`) must not regress.
2. **Full tentacletech suite green.** Currently 166/166.
3. **One new test specific to the slice** demonstrating the fix mechanism.
4. **Status table updated** in `extensions/tentacletech/CLAUDE.md` with sub-slice notes + spec divergences.
5. **Spec divergences flagged** explicitly in the sub-Claude report.
6. **SDF-preparation guards respected** (see "Future direction — body SDF primitives" below). Specifically: solver stays agnostic about contact source; per-particle contact count stays variable; host-bone resolution stays abstracted (refactor to a single lookup point if not already); surface tags / materials attach to entities not hull faces; no `if shape_kind == X` branching in solver / §6.3 / reciprocal code. Each slice's report notes which guards it touched and confirms compliance.

## Open questions / things to verify

- **4S brief outcome.** Does Obi structurally solve Mode B the way I've assumed (contact-local-frame persistence)? If not, the slice gets reframed.
- **4T default `target_velocity_max`.** Probing thrust at 1.5 Hz × 0.15 m amplitude = ~1.4 m/s peak. Default 5.0 m/s allows headroom; 2.0 m/s would clamp normal probing. Tune after first regression run.
- **4U surface-tagging API.** Per-collider material on `Node3D` metadata, on a sibling `CollisionShape3D` resource, or on a separate `BoneMaterialProfile` on the skeleton? Defer decision until 4S + 4T land.
- **Mode B residual after 4S.** Some hit_point churn may persist if particles cross body-local space at face boundaries even with persistence. May need SDF-based contacts as a Phase 9 polish item.
- **Whether 4R's substep flip default is rehabitable.** With contact-local-frame persistence + substep gravity rescale, does 4×1 stop creating the taper feedback loop? Speculative; revisit after 4S + 4V.

## What's NOT in this queue

- Marionette joint stiffness/damping tuning (Marionette work; orthogonal to TentacleTech jitter fix path)
- Marionette SPD wiring on test scenes (Marionette work)
- Direct tridiagonal chain solver (Phase 9 polish; high lift, real win, but speculative until profiling shows distance-iter convergence is the bottleneck)
- Velocity-level constraint solving (architectural shift; PBD is position-only by design; defer)
- `RhythmSyncedProbe` phase-lock (already on Phase 6 roadmap; addresses *active* state coupling, not floor case)
- Reverie consciousness-aware driver parameters (gameplay design; future)
- **Inter-loop coupling springs** for multi-loop orifices (outer + inner ring of a sphincter that should interact). Currently loops are mechanically independent. Phase 5 close-out polish; not in this queue.
- **Wobble / overshoot tuning** on rim spring-back (currently implicit in finalize compliance, not explicitly tuned for visible wobble on release). Phase 5 close-out polish.

## Adjacent authoring tooling that compounds the simulation

These aren't slices in this queue but are worth noting because they have **outsized leverage on visible quality** relative to their authoring cost. List as standalone tooling tasks for whenever authoring-time pain motivates them:

- **Ring weight auto-generator plugin (Blender, §10.4 in the architecture doc).** Auto-generates rim mesh skin weights from rim anchor bones using angular falloff between adjacent anchors + radial falloff outward to the host bone. Without this, manual rim weight painting either hard-binds vertices to single anchors (visible polygonal deformation around the rim) or requires careful manual blending at every vertex. Current state: spec'd, not yet implemented. Bigger lever for visible smoothness than upping the bead count from 8 → 12. When this lands, 8 beads per loop will look like 16 beads currently look.
- **Capsule contact gizmo overlay** (lands with 4X). Visualizes the rim segment capsules in the editor so authors can see where contact actually happens vs. where the bead spheres alone would have been. Helps spot under-radius authoring issues at edit time.
- **Rim authoring helper** that converts a Blender edge-loop selection + count into N rim anchor bones with arc-length-regular spacing. Currently anchor placement is fully manual; helper would shift effort from positioning to weight-painting (which auto-generator above handles).

## Future direction — body SDF primitives for tentacle contact

A meaningful architectural shift, NOT in the immediate queue, but worth preparing for so we don't paint ourselves into a corner.

### The split

Three collision regimes, three representations, each best-suited:

| Pair | Representation | Why |
|---|---|---|
| Tentacle ↔ body | **SDF primitives** | Smooth contact for tangential sliding |
| Body ↔ body, body ↔ world | **Convex hulls (existing Marionette `BoneCollisionProfile`)** | Ragdoll dynamics, settling |
| Tentacle ↔ static world | **Convex hulls (existing PhysicsServer3D probe)** | World isn't SDF; no change needed |

The body carries *two* representations: hulls for ragdoll physics, SDF for tentacle queries. They coexist on the same skeleton; tentacle queries route through the SDF, ragdoll queries route through the hulls, neither sees the other.

### Mechanism

A `BodySDFProfile : Resource` (shared via `extensions/shared/include/`, authored on or alongside the Marionette skeleton) lists ~20–25 analytic primitives bone-by-bone — capsules for limbs, ellipsoids/rounded boxes for torso/head/hands/feet, smoothing fills at joints (hip, shoulder, knee). Each primitive carries a bone-relative transform + analytic distance function. Composed via smooth-min: `d = -log(Σ exp(-d_i / k)) × k`, where `k` controls join smoothness.

Per-particle tentacle query: `min` (or smooth-min) over all primitives → signed distance, surface normal (gradient), nearest primitive's host bone. Cost ~100 ns per particle, ~100 μs per tentacle per tick. Negligible.

### Why this is the right long-term direction

- **Collapses Mode B entirely.** Sliding tentacles see smooth normals; no more contact-point churn under any lubricity. Fundamentally, not just dampened.
- **Composes with everything else.** 4Q-fix taper, 4T rate limit, 4U per-collider material — all still apply (per-primitive material instead of per-collider).
- **Scales gracefully** to more colliders. The 5-adjacent-collider Kasumi-with-glutes case becomes "more primitives in the smooth-union," not "MAX_CONTACTS_PER_PARTICLE blowup."
- **No bake step.** Primitives are analytic; they move with bones every frame at zero re-bake cost. Only baked SDFs would cost VRAM, and we explicitly don't go there.
- **Authoring is an extension of existing Marionette work.** Calibrate could auto-generate primitives from `BoneCollisionProfile` (capsule per bone is the easy default), with manual override for joint smoothing.

### Estimated scope

2–3 weeks of focused work, spans both TentacleTech and Marionette:

- New shared resource type (`BodySDFProfile`) in `extensions/shared/include/`
- New SDF primitive types (Capsule, Sphere, Ellipsoid, RoundedBox + maybe SweptArc) with analytic distance + gradient functions
- New probe path in TentacleTech: query SDF per particle, populate the existing contact arrays from SDF results
- Marionette-side authoring: `BodySDFProfile` resource shipped from the Marionette extension, auto-gen from `BoneCollisionProfile`, override hooks
- New gizmo for visualizing the smooth-union iso-surface (non-trivial; ImmediateMesh marching-cubes approximation or polyline contour)
- §6.3 reaction-on-host-bone routing: SDF returns "dominant primitive's bone" instead of `result["collider_id"]`; the routing call site should already be abstracted by then (see "preparing for the path" below)
- Migration: existing test scenes choose hull probe or SDF (probably hull probe stays the default for tests; production scenes opt-in to SDF)

### When to do it

After 4S brief returns, 4S-impl + 4V land, 4T lands, 4U lands, AND the user visualizes the integrated state. If lub=1.0 contact-point churn is still visible after all of those, SDF becomes the next slice. If not, defer to genuine Phase 9 polish.

### Preparing the path now (small architectural guards)

While working through 4S, 4T, 4U, 4V — and any other near-term TentacleTech slice — keep these architectural choices so we don't have to re-do them later. Each is small; the cost of preparing now is essentially zero. The cost of NOT preparing is significant rework when SDF lands.

1. **Solver stays agnostic about contact source.** The solver consumes contacts via `set_environment_contacts_multi(...)` and does not query the source. Already true today; preserve. Don't add probe-specific fields to the solver's contact data — anything that's `PhysicsDirectSpaceState3D::get_rest_info`-shaped should live in the Tentacle/probe layer that *fills* the contact arrays, not in the solver's storage.

2. **Per-particle contact count stays variable.** `env_contact_count[i]` is the truth; `MAX_CONTACTS_PER_PARTICLE` is just a buffer cap. Don't write code that assumes "always 2 slots filled" or "slot 0 always exists." When MAX bumps to 3 (Phase 5 dependency) it's a one-line change; when SDF returns 1 contact, the same code handles it.

3. **Host-bone resolution is abstracted.** The §6.3 reaction-on-host-bone routing in `Orifice::_apply_reaction_on_host_bone` and the type-1 reciprocal in `Tentacle::_apply_collision_reciprocals` currently look up the host body by casting to `PhysicalBone3D` from `result["collider_id"]`. Wrap this in a "given a contact, return body RID + transform + bone metadata" lookup so probe and SDF can both implement it. **First action item:** when 4S-impl lands, factor this lookup into a single function so SDF can swap the implementation later without touching the call sites.

4. **Surface tags / per-collider materials (4U) attach to colliding entities, not specifically hull faces.** When 4U lands, design the surface-tag attachment such that a tag can apply to a hull, a primitive, or anything else that produces contacts. Avoid hull-face-id-keyed material lookups. A material tag should be addressable as "this collider/primitive's material" — same conceptual model whether the entity is a hull or an SDF primitive.

5. **Probe lifecycle stays per-tentacle.** Each tentacle has its own probe today; same shape will work for SDF (each tentacle has its own body-SDF binding via `body_sdf_profile_path: NodePath`). No global contact-state singletons; no shared probe across tentacles.

6. **Contact-local-frame persistence (4S) is SDF-friendly by construction.** SDF primitives are already body-local. 4S essentially extracts the same pattern SDF would use natively — when SDF lands, the persistence machinery reads the same body-local point/normal but generates them analytically instead of caching from probe results. Good convergence; preserve the abstraction.

7. **Don't introduce new code paths that branch on collision shape kind.** If you're tempted to write `if collider is ConvexShape3D ...`, refactor — the contact provider should hide that detail. Keep "what kind of shape produced this contact" out of the solver and out of the §6.3 / reciprocal code.

These guards add ~zero overhead per slice but keep the SDF migration cheap. Each near-term slice should explicitly note which guards apply in its acceptance criteria.

## File pointers

- Diagnostic scripts: `game/tests/tentacletech/test_4q_*.gd`
- Stick-slip regression: `game/tests/tentacletech/test_4q_probing_regression.gd`
- 4S verify-first brief: `docs/proposals/4S_obi_contact_persistence_brief.md` (in progress)
- Phase plan source of truth: `docs/architecture/TentacleTech_Architecture.md` §13
- Status table source of truth: `extensions/tentacletech/CLAUDE.md`
