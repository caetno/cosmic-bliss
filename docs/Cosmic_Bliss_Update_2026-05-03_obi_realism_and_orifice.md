# Cosmic Bliss — Design Update 2026-05-03 — Obi adoption matrix + orifice rethink + slime spec

> **Status (all sections resolved 2026-05-03):**
> §1 reference (no spec change).
> §2 approved + applied via `Cosmic_Bliss_Update_2026-05-03_orifice_rim_model.md`
>   — architecture doc edited to match. User added multi-loop confirmation
>   (outer + inner rims, jewelry rim + anatomical opening, multi-sphincter
>   tunnels) which is folded into the applied amendment doc.
> §3 (slime) approved + applied — architecture doc §6 fluid-strand
>   paragraph expanded into a five-behavior subsystem (strand / drip /
>   smear / pool / peel-sting); `WetSeparation` event added to §8 bus
>   event list; ~200 LOC GDScript scoped for Phase 6.
> §4 (realism gaps) approved + applied — three Phase 5 sub-slices
>   recorded in architecture doc §6.4 (4P-A anisotropic flesh stiffness
>   via one-sided XPBD distance, 4P-B strain-stiffening J-curve,
>   4P-C orifice memory slow recovery). Land alongside the rim model
>   implementation when Phase 5 opens.
>
> Lineage: this doc grew out of reading the Obi 7.x Unity asset source
> dropped under `docs/pbd_research/Obi/` (synthesis at
> `docs/pbd_research/findings_obi_synthesis.md`). The Obi Rope/Cloth
> drop on top of that surfaced two patterns
> (`PinholeConstraints.compute`, `VolumeConstraints.compute`) that
> reframe the orifice problem; the user asked what else from Obi we
> might want plus what else realism requires.

---

## TL;DR

1. **Obi adoption matrix** below sorts every Obi capability into Tier 1
   (already adopting), Tier 2 (worth porting if a scenario shows the
   need), or Tier 3 (skip). Most value is in *patterns* (XPBD form,
   lambda accumulators, pinhole-as-orifice, volume-as-orifice-balloon,
   sleep threshold) — not in porting Obi's *systems* wholesale.

2. **Drop the 8-direction discrete ring (§6.2).** Replace with a
   closed-loop rim of N particles (typically N=8 to 16) with distance
   constraints around the loop + an Obi-style volume constraint on the
   enclosed area + per-particle authored rest position. Naturally
   handles non-circular and non-elliptical rest shapes (slits,
   irregular jewelry, asymmetric anatomy) without per-shape special
   cases. Bilateral compliance becomes per-particle stiffness
   distribution. Active contraction becomes target-volume modulation +
   distance rest-length modulation. The 8-direction `_per_dir[d]`
   contract retires — quantities become `_per_rim_particle[k]`.

3. **Promote slime from one event line to a system** with five
   behaviors (strand, drip, smear, pool, peel-sting). Currently §6.10
   has one paragraph: "FluidStrand 4-6 point spline that snaps on
   separation." That's correct as a *primitive*; this update adds the
   system that consumes it. Implementation cost is small (decal
   accumulator already planned in `docs/Appearance.md`; wetness
   propagation already in §4.6).

4. **Cross-cutting realism checklist** at the end: ten properties that
   distinguish a soft-physics tentacle interaction from a scripted
   one. Most are already covered or in-scope; three are gaps worth
   fixing (anisotropic flesh stiffness, ring tension nonlinearity,
   orifice memory).

---

## §1 — Obi adoption matrix

### Tier 1 — Adopting now (Phase 4 close-out cluster)

| Capability | Source file | Where it lands | Status |
|---|---|---|---|
| Per-contact persistent lambda accumulators (warm-starting) | `ContactHandling.cginc` | Slice 4M | Pending |
| Jacobi-with-atomic-deltas + SOR apply pattern | `AtomicDeltas.cginc` | Slice 4M | Pending |
| Multi-contact via per-contact projection (no bisector) | `ColliderCollisionConstraints.compute` | Slice 4M | Pending |
| XPBD compliance form (canonical Macklin 2016) | `DistanceConstraints.compute` | Slice 4M-XPBD | Pending |
| Sub-step-as-primary-convergence default | `ObiSolver.cs:147,1780` | Slice 4O | Pending |
| Sleep threshold (snap to prev_pos when below KE threshold) | `Solver.compute:204-217` | Slice 4P | Pending |
| Max depenetration cap (m/s) | `SolverParameters.cginc` | Slice 4P | Pending |

All seven are bundled into the close-out cluster spec at
`Cosmic_Bliss_Update_2026-05-03_phase4_wedge_robustness.md`. No new
work to authorize here.

### Tier 2 — Worth porting when the scenario calls for it

| Capability | Source | When to open | Cost estimate |
|---|---|---|---|
| Pinhole constraint (orifice abstraction) | `PinholeConstraints.compute` | Phase 5 (orifice) | Medium — full port, ~300 LOC C++. Replaces multi-thousand-line ring-bone state machine. |
| Volume constraint (closed-loop area/volume preservation) | `VolumeConstraints.compute` | Phase 5 (orifice) — see §2 below | Small — ~80 LOC. Used by orifice rim, possibly by bulgers. |
| One-sided XPBD distance (tether) | `TetherConstraints.compute` | If anchor-pulls-tentacle scenarios show stretch artifacts | Trivial — 30 LOC. One conditional in `project_distance`. |
| ChainConstraints direct tridiagonal solver | `ChainConstraints.compute` | Phase 9 polish, free-air segments only | Medium — ~160 LOC. Doesn't compose with multi-contact softening. |
| ObiRopeCursor runtime length adjustment | `Scripts/RopeAndRod/Actors/ObiRopeCursor.cs` | Phase 8+ if tentacles need to grow/retract during play | Small — pattern is `(mu, source_index)` cursor + insertion/removal. |
| Per-collider material composition (Average/Min/Multiply/Max) | `CollisionMaterial.cginc` | Phase 6 (stimulus bus + surface tagging) | Small — 40 LOC + designer-facing inspector. |
| Force zones (per-particle force in a region) | `ObiForceZones` (script-side) | If ambient effects (wind, water current, magnetic field) become scope | Small — wraps gravity logic per-particle with region test. |
| Spatial queries against the particle system | `SpatialQueries.compute` | If reverie/AI needs particle-position queries | Skip for now; Godot PhysicsServer3D handles "is something near this point" for the AI side. |

### Tier 3 — Skip

| Capability | Why skip |
|---|---|
| Obi Fluid (full SPH: density, foam, surface tension, vorticity) | Heavy (1000s of particles, neighbor search every tick). Slime as we'll spec it (§3 below) does the visual job with PBD strands + decals. Reach for SPH only if a scenario truly needs cohesive-blob-flow behavior. |
| Obi Cloth (cloth-specific topology, skin constraints, aerodynamic lift) | `docs/Appearance.md` explicitly excludes cloth physics. Dissolve shaders + decals + dynamic-bone hair-like effects cover the visual job. |
| Obi Softbody (shape-matching, full volumetric soft-body) | Bulgers (§7.5, max 64 capsules with spring-damper) are the lighter alternative for our skin-deformation use case. Shape-matching would over-engineer it. |
| Aerodynamic constraints | Speculative; noise-driven sway in `BehaviorDriver` already covers ambient motion without the per-particle drag/lift cost. |
| Distance fields (`ObiDistanceField`) for collision | Heavy preprocessing, fast queries — but Godot collision shapes at our scale are fine. Revisit if tentacles need to collide against arbitrary mesh-derived SDFs (e.g. detailed cavity geometry beyond capsule + sphere primitives). |
| Bend-twist constraints (rod orientation) | Tentacles don't have per-particle quaternion state; rest-pose orientation is implicit from chord direction. Adding twist would require rewriting the spline-skinning shader to consume per-particle rotations — large cost for niche behavior (whip-cracking corkscrew). Punt indefinitely. |
| Stitch constraints (cloth seams) | No use case in Cosmic Bliss. |
| Pin constraints (point-to-rigidbody XPBD pin) | We have anchor (hard pin) and target-pull (soft pin); the XPBD pin sits between the two but our needs split cleanly. Adopt only if attachment-with-finite-stiffness becomes a recurring need. |
| Skin constraints (cloth-to-rigged-mesh) | Mesh skinning is via vertex shader (§5.3); per-particle skin constraints would duplicate that pipeline. |
| Compute-shader port of the solver | Already decided "no" earlier in this conversation. Math isn't the bottleneck at our particle counts; CPU↔GPU sync would tax every consumer (gizmos, behavior driver, ragdoll reciprocals, stimulus bus). |

---

## §2 — Orifice rim rethink (proposed amendment to §6.2)

### The current model

`TentacleTech_Architecture.md §6.2`: an orifice has 8 discrete radial
"ring bones" arrayed around its central axis. Each ring bone has a
spring-damper extension state. Per-direction quantities use
`_per_dir[d]` (canonical, established in §6.2 and locked as a
non-negotiable in `extensions/tentacletech/CLAUDE.md`).

This model handles:
- **Circular** rest shapes (all 8 directions same rest radius).
- **Elliptical** rest shapes (4-fold symmetric rest radii).
- **Bilateral asymmetry** (front/back stiffness differential).

This model does **not** handle cleanly:
- **Slit** orifices (mouth, urethra, anatomical slit). Two directions
  near-zero rest radius, two directions large; transitions between
  are 8 fixed steps. Discretization shows.
- **Irregular** jewelry rims (carved knot, decorative ring with
  arbitrary inner profile). 8 directions can't capture a 5-pointed
  star or a square.
- **Continuous deformation under load.** When a tentacle pushes
  off-axis, the rim deforms along a curve, not at 8 sample points.
  Discrete sampling produces visible faceting at high deformation.

§14 of the architecture doc already acknowledges:
> **Glancing-approach rejection is not modeled.** Currently rings are
> 8 discrete radial bones; a glancing tentacle slides along whatever
> rim geometry that produces. A future revision that builds a
> connected ring-cylinder surface for type-2 collision will let
> glancing approaches slide off naturally; until then, accept and
> absorb glancing approaches via the soft-physics path.

The "future revision" hinted at there is what this section makes
concrete.

### The proposed model

Replace the 8-direction discrete ring with a **closed-loop rim** of
N particles (configurable, typically N=8-16). The rim particles are
governed by:

1. **Distance constraints around the loop.** Each adjacent pair
   `(rim[k], rim[(k+1) % N])` has an XPBD distance constraint with
   per-pair authored rest length. Sum of rest lengths = rim
   circumference.
2. **Volume constraint on the enclosed cross-section.** Adopted from
   `pbd_research/Obi/Resources/Compute/VolumeConstraints.compute`.
   The constraint computes the polygon area enclosed by the N rim
   particles (projected onto a plane perpendicular to the orifice
   entry axis) and pulls toward a target area. Active contraction
   modulates the target.
3. **Per-particle spring-back to authored rest position.** Each rim
   particle has an XPBD soft pull toward its `rest_local_position`
   relative to the orifice frame. Bilateral compliance is the per-
   particle stiffness of this pull — front-of-mouth tighter than
   back-of-mouth, for example.
4. **Soft attachment to host bone.** The orifice frame inherits the
   `host_bone` global transform; rim particles' rest positions are
   in this frame. When the bone moves, rest positions move; the
   spring-back pulls particles along. This replaces the existing
   §6.3 reaction-on-host-bone routing as the way the rim "rides"
   the ragdoll.

### What this gives us

- **Arbitrary rest shapes**, just by authoring the per-particle
  rest_local_position. Slit = particles clustered along a line.
  Star = particles at star vertices + inner points. Circle = N
  evenly-spaced points on a radius.
- **Continuous deformation.** The rim is N actual particles, not 8
  sample points; deformation is geometrically smooth between them.
- **Volume preservation** (anatomically correct — surrounding tissue
  is incompressible). When a tentacle pushes through, the rim has
  to *go somewhere*; the volume constraint forces the displaced
  area to redistribute around the loop, naturally producing the
  "rim bulges around tentacle" visual.
- **Active contraction is one knob**, not 8. Modulate `target_volume`
  and a global rest-length scalar; rim contracts uniformly. To
  contract asymmetrically (one-sided sphincter), modulate per-
  particle rest positions instead.
- **ContractionPulse sugar applies cleanly.** The atomic
  `ContractionPulse` (§6.10) writes a time-varying delta to
  `target_volume` and per-rest-length scaling.
- **Multi-tentacle via PinholeConstraint** (Tier 2 above). Each
  tentacle in the orifice gets its own pinhole instance; pinholes
  reference the same rim particles via the `mix`-along-edge model.
- **No more `_per_dir[d]` plumbing.** All quantities become
  `_per_rim_particle[k]` for k in [0, N). The CLAUDE.md
  non-negotiable on `_per_dir` retires.

### What this costs

- **Spec edits.** §6.2 (orifice ring model), §6.3 (reaction-on-host-bone),
  §6.10 (ContractionPulse pattern emitters), §15.2 (snapshot accessors
  for the rim) all need updates. The CLAUDE.md non-negotiables list
  needs `_per_dir` removed and `_per_rim_particle` documented in its
  place. Ballpark: 3-4 hours of doc work.
- **Implementation.** Replace the planned `Orifice` C++ class structure
  with rim-particle-loop + volume-constraint + per-particle spring.
  This is **simpler** than 8-direction-spring-damper-per-orifice
  bookkeeping — fewer special cases. Net implementation cost should be
  *lower* than the current spec, not higher.
- **Authoring tooling.** Need a way to author rest positions per
  rim particle. Default presets (circle, ellipse, slit, custom curve)
  + an editor gizmo for hand-tuning. Phase 5 scope.
- **Re-tuning everything that interfaces with the rim.** Bilateral
  compliance, ContractionPulse patterns, multi-tentacle pressure
  distribution. Done as part of Phase 5 implementation.

### Recommendation

**Adopt the rethink** before Phase 5 implementation begins. The
current 8-direction model is a Phase-2-era simplification that hasn't
been built yet — easier to amend the spec now than to build and
discover the discretization problems later.

The Obi `PinholeConstraints` pattern in particular only makes sense
when the rim is a deformable loop you can grip at any `mix` point,
not a discrete 8-direction structure.

**If the rethink is approved**, the spec amendment ships as a
separate update doc (`Cosmic_Bliss_Update_2026-05-XX_orifice_rim_model.md`)
that rewrites §6.2 and §6.3 directly, with this doc cited as the
rationale. Sub-Claude doesn't touch any of this until Phase 5 opens
(Phase 4 close-out cluster blocks Phase 5 anyway).

### Do we even need a ring at all?

Worth asking. Alternative model: orifice is *just* a pinhole on a
host bone with a set of soft constraints — no rim particles, no
ring. The "rim" is geometric only, baked into the host mesh.

Pros: even simpler. No rim simulation cost.

Cons: loses the "rim deforms visibly around tentacle" visual,
which is anatomically core to the experience and is what makes
the bulge mechanic work. Volume preservation has to be faked
some other way (probably as a §7 bulger). Bilateral compliance
becomes per-pinhole-direction stiffness modulation, which loses
the smooth continuous feel.

**Verdict: keep the rim, but as a deformable particle loop, not a
discrete-direction structure.** The rim *is* the visual contract
of an orifice.

---

## §3 — Slime / drool / wetness system spec

### Current state

`TentacleTech_Architecture.md` has:
- §6.10: `FluidSeparation` event emitted when tentacle withdraws past
  the orifice plane.
- §6 (around line 1475): "Fluid strands: when a tentacle withdraws
  past the entry plane, spawn a `FluidStrand` (4-6 point spline
  between retreating tip and orifice center). Stretches with
  separation, breaks at threshold, snaps into two droplets. GPU-drawn
  triangle strip, ~50 lines of code."
- §4.6: wetness accumulation from external friction.
  `wetness_per_orifice` updates when nearby skin contact happens.
- `gdscript/stimulus/fluid_strand.gd` planned but not implemented.

`docs/Appearance.md`: hero customization with a "decal accumulator"
for clothing/dirt effects. Slime/wetness decals would naturally
ride this system.

### What's missing

The doc has the **strand snap event** (atomic) but not the **system
that produces and consumes wetness over time**. Five behaviors that
make wet tentacle interactions read as physical:

#### 3.1 Strand (already in spec, refine)

Spec is fine as-written. Implementation note: use the same
TentacleTech PBD solver to drive the 4-6 point strand. Anchor at
tentacle tip + anchor at orifice center, distance constraints with
breaking threshold (segment exceeds 4× rest length → constraint
detaches → particles fall under gravity). When the chain fully
breaks, the two halves continue as gravity-only particles for ~0.5s
before fading.

This is a TentacleTech use case for the existing PBD solver — no
new physics.

#### 3.2 Drip

When a strand particle's velocity falls below threshold AND it's
within `epsilon` of a downward-facing surface, convert the particle
to a "drip mark" — spawn a small decal at the contact point and
remove the particle from the simulation.

Decals accumulate over time. Each drip = one `Decal` entry in the
surface accumulator (Appearance.md system). Older drips fade after
configurable lifetime (default 30s).

#### 3.3 Smear

When a tentacle particle is in surface contact AND tangent velocity
exceeds `smear_threshold`, lay down a moisture decal at the contact
point. Decals overlap to build up a moisture trail.

This couples to friction: high `wetness_per_surface_region` →
modulator on μ_s (lower static friction). Inversely, dragging a
dry tentacle across a wet surface raises tentacle wetness (transfer
in both directions).

#### 3.4 Pool

Surface decals on horizontal-ish faces (`abs(normal.y) > 0.7`)
accumulate into pools. A pool is just a denser decal — visually a
small puddle.

Could be implemented as a simple counter per surface region:
`pool_density[region] += smear_or_drip_event * dt; pool_density
*= evaporation_rate`. When density crosses thresholds, swap between
"damp" / "wet" / "puddle" decal art. Fades to dry over configurable
time (default 60s).

#### 3.5 Peel-sting

When a tentacle particle separates from a surface AND surface_wetness
is above threshold AND separation velocity is above threshold,
emit a `WetSeparation` event on the stimulus bus. The audio system
plays a peel/sting sound (squelch, tch, suction-release). The visual
system spawns a brief micro-strand (1-2 PBD particles) at the
separation point that snaps within 100ms.

This is what makes wet contact feel sticky — the audio + brief
strand reads as adhesion-then-release.

### Implementation cost

- **Strand:** already speced; ~50 LOC in `fluid_strand.gd` (already
  scoped).
- **Drip:** ~30 LOC, decal system call on threshold.
- **Smear:** ~40 LOC, decal-on-tangent-velocity in the existing
  contact loop. New friction modulator on `surface_wetness`.
- **Pool:** ~50 LOC, counter + decal-art-swap. Could be a new
  `WetnessAccumulator` class.
- **Peel-sting:** ~30 LOC for event emission; audio + visual spawn
  is already covered by `MechanicalSoundEmitter` + `FluidStrand`.

Total ballpark: ~200 LOC GDScript, no new C++. Lands in TentacleTech
Phase 6 alongside the stimulus bus (since it's bus-driven).

### Spec amendment

`TentacleTech_Architecture.md` §6 (fluid strand paragraph) gets
expanded into a full "Fluid system" subsection covering all five
behaviors. Stimulus bus (§8) gets `WetSeparation` event added to the
event list. §4.6 wetness propagation is referenced as the source of
modulation; no change to its math.

---

## §4 — What "realistic tentacle interaction" requires (cross-cutting)

Inventory of properties that distinguish a soft-physics tentacle
interaction from a scripted one. Some are already in scope; flagging
the gaps.

| # | Property | Status | Notes |
|---|---|---|---|
| 1 | Surface adhesion modulated by moisture | **Gap** | Fixed by §3.5 peel-sting + §3.3 smear-to-friction-modulation. |
| 2 | Visual cohesion of stretching strands | **Covered** | §3.1 (strand). |
| 3 | Pooling and dripping | **Gap** | Fixed by §3.2 drip + §3.4 pool. |
| 4 | Smearing trails | **Gap** | Fixed by §3.3 smear. |
| 5 | Volume-conserving displacement (bulger) | **In scope** | §7 bulger system. Rim deformation in §2 above complements this. |
| 6 | Anisotropic flesh stiffness (compress > stretch) | **Gap, large** | Currently rim distance constraints are symmetric. Fix: use one-sided XPBD distance (Tether pattern from Obi) — rim segments resist *compression* strongly but allow modest *stretch* under load. Bulgers handle the displaced volume on the compressed side. |
| 7 | Friction × moisture inverse coupling | **Partial** | §4.6 wetness propagation is the source; the modulator path through to per-contact μ_s is implicit but should be made explicit in §4.4. |
| 8 | Ring tension scales nonlinearly with dilation | **Gap** | Currently spring-damper rings are linear. Real anatomical tissue has a J-curve: easy to deform a little, much harder to deform a lot (collagen strain stiffening). Fix: replace the rim spring-back's stiffness with a function of current strain — `stiffness(strain) = base * (1 + alpha * strain² + beta * strain⁴)`. Cheap modification once the rim is a particle loop (§2). |
| 9 | Soft contact peeling sound | **Covered by §3.5** | Already in `MechanicalSoundEmitter` plumbing; just needs the event hook. |
| 10 | Orifice memory (residual deformation after withdrawal) | **Gap, small** | Fix: rest-position spring-back has a slow component that ramps the rest position back to neutral over seconds, not instantly. Can be implemented as `rest_pos = lerp(rest_pos, neutral_pos, recovery_rate * dt)` in the orifice tick. ~5 LOC. |

**Out of scope intentionally:**
- Heat / temperature gradients
- Per-particle pH / chemistry
- Microscopic surface texture
- Real fluid dynamics (handled via the simplified §3 system)

### Three gaps worth opening tickets on

The realism inventory surfaces three meaningful gaps that aren't
covered by the close-out cluster or the Phase 5/6/7 scope:

1. **Anisotropic flesh stiffness.** Adopt one-sided XPBD distance
   (Obi tether pattern, Tier 2) for the rim. **Phase 5 scope.**
2. **Ring tension J-curve.** Strain-stiffening function on rim
   spring-back. **Phase 5 scope.**
3. **Orifice memory (slow recovery).** Lerp rest position back to
   neutral over time. **Phase 5 scope.**

All three are cheap once the rim becomes a particle loop (§2) and
should land in the same Phase 5 cluster as the rim refactor.

---

## Apply checklist

If approved:

1. **Adoption matrix (§1)** — no spec amendment; this section is
   reference. Capture the Tier 1/2/3 sort in
   `docs/pbd_research/findings_obi_synthesis.md` as a cross-reference
   if useful, but the matrix itself lives here as the canonical record.
2. **Orifice rim model (§2)** — pending review. If approved, draft a
   separate update doc that rewrites `TentacleTech_Architecture.md`
   §6.2 and §6.3 directly, removes the `_per_dir[d]` non-negotiable
   from `extensions/tentacletech/CLAUDE.md`, adds the rim-particle-
   loop + volume-constraint + per-particle-spring model in their
   place. Cite this doc as rationale.
3. **Slime system (§3)** — pending review. If approved, expand the
   §6 fluid strand paragraph in `TentacleTech_Architecture.md` into
   a full "Fluid system" subsection covering strand/drip/smear/pool/
   peel-sting. Add `WetSeparation` event to §8 bus event list.
4. **Realism gaps (§4)** — pending review. If approved, the three
   gap items (anisotropic stiffness, J-curve, orifice memory) become
   explicit Phase 5 sub-slices.
5. **Sub-Claude continues Phase 4 close-out cluster.** None of the
   above blocks the in-flight 4M+4M-XPBD work; the rim rethink
   matters for Phase 5 only.
