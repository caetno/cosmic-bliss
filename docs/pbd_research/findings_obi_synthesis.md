# Findings — Obi solver source synthesis (2026-05-03)

User dropped the full Obi 7.x Unity asset source into `pbd_research/Obi/`.
What follows is what's directly relevant to TentacleTech's Phase 4 close-out
cluster (slices 4M, 4N, 4O) and the Phase 4.5 placeholder (XPBD,
warm-starting). Citations point at file paths under
`pbd_research/Obi/Resources/Compute/` unless noted.

---

## TL;DR — the four things that change our plan

1. **Slice 4M's "bisector friction" idea is the wrong shape.** Obi handles
   N-contact-per-particle by the Jacobi-with-atomic-deltas-and-SOR pattern
   (`AtomicDeltas.cginc`). Each contact independently writes a position
   delta into a shared accumulator; a second pass divides by the per-particle
   constraint count and applies. Naturally handles 2, 4, 8 contacts; no
   bisector heuristic needed. Friction reads the contact's own accumulated
   normal lambda — not a per-particle `dn` budget — so multi-contact
   friction is correct without coordination.

2. **Per-contact persistent lambda accumulators are not a Phase 4.5
   luxury — they're the structural fix for our jitter.** Obi's `contact`
   struct (`ContactHandling.cginc`) carries `normalLambda`, `tangentLambda`,
   `bitangentLambda`, `stickLambda` across iterations within a substep.
   This is what makes friction cones `staticFrictionCone = normalLambda /
   dt * staticFriction` — the cone scales with how much normal impulse the
   contact has actually accumulated, not a per-iter `dn`. Removes the
   "iter 1 had penetration but iter 4 doesn't, so friction has nothing to
   bound against" bug we patched with `iter_dn_buffer` in slice 4L.

3. **XPBD is one extra term, not a rewrite.** Obi's distance constraint
   (`DistanceConstraints.compute:34-48`) is canonical XPBD:
   ```
   compliance = stiffness / (dt * dt)
   dlambda = (-constraint - compliance * lambdas[i]) /
             (w1 + w2 + compliance + EPSILON)
   delta = dlambda * direction
   lambdas[i] += dlambda
   ```
   Our current `project_distance` in `extensions/tentacletech/src/solver/
   constraints.cpp` is the un-compliant form (`correction = stiffness *
   diff / w_sum`); promoting it is ~6 lines plus a per-segment lambda
   buffer. The "changes the meaning of every existing stiffness knob" cost
   I cited in the Phase 4.5 placeholder is real — but the *implementation*
   cost is small.

4. **Obi defaults are `substeps = 4, iterations = 1` per substep** — the
   inverse of what we ship. `ObiSolver.cs:147` documents `public int
   substeps = 4;` and the convergence.html page confirms: *"for the same
   cost in performance, the quality improvement you get by reducing the
   timestep size is greater than you'd get by keeping the same timestep
   size and using more iterations."* Slice 4O (sub-stepping) is more than
   a tunneling fix; it's the canonical convergence path. Promote with
   intent.

---

## Confirmed by source — claim → file

### Multi-contact handling

- `ColliderCollisionConstraints.compute` `Project` kernel runs *one
  thread per contact*, not one per particle. Each thread calls
  `SolvePenetration(...)` which reads/writes its own contact's
  `normalLambda`, then writes the position correction via
  `AtomicAddPositionDelta(particleIndex, delta * invMass *
  pointA[j])`.
- `AtomicDeltas.cginc` `ApplyPositionDelta`:
  ```hlsl
  positions[index].xyz += delta * SOR / count;
  ```
  `count` is incremented by every constraint touching this particle in
  this iteration; `SOR` is a successive-over-relaxation factor (typical
  ~1.0). This naturally averages N contact corrections.
- This is **Jacobi mode**. Obi also has a sequential (Gauss-Seidel) mode
  per the convergence doc — there the deltas apply immediately, no
  accumulator needed. Both are valid; Jacobi parallelizes cleanly to GPU.

### Per-contact lambda accumulators

- `ContactHandling.cginc:8-23`:
  ```hlsl
  struct contact // 96 bytes
  {
      float4 pointA, pointB, normal, tangent;
      float dist;
      float normalLambda;
      float tangentLambda;
      float bitangentLambda;
      float stickLambda;
      float rollingFrictionImpulse;
      int bodyA, bodyB;
  };
  ```
- `SolvePenetration` accumulates: `c.normalLambda = max(c.normalLambda +
  dlambda, 0)`. The `max(., 0)` clamps to "contacts can only push, not
  pull" without losing accumulated state.
- `SolveFriction` reads `c.normalLambda` to size the cones, accumulates
  into `c.tangentLambda`/`c.bitangentLambda`, clamps via the *pyramid*
  (separate tangent and bitangent caps) rather than a true cone:
  ```hlsl
  if (abs(newTangentLambda) > staticFrictionCone)
      newTangentLambda = clamp(newTangentLambda,
                               -dynamicFrictionCone, dynamicFrictionCone);
  ```
  Same stick→slip pattern we have, but operates on accumulated impulses
  (Newton-seconds), not per-iter position deltas (meters). The unit
  difference is what makes the cone correct across multiple iters.
- Lambdas reset between substeps (the contact struct is rebuilt by the
  collision-detection pass). So they're warm-started *within* a substep,
  cold-started *between* substeps.

### XPBD compliance

- Distance: `DistanceConstraints.compute:34-45` (full snippet above).
- Bend, bend-twist, stretch-shear, volume, density: all follow the same
  `dlambda = (-constraint - compliance * lambda) / (sumW + compliance)`
  form. Compliance term `α = 1/(stiffness × dt²)` from Macklin 2016
  ("XPBD: Position-Based Simulation of Compliant Constrained Dynamics").
- Slack handling pattern: `constraint -= max(min(constraint, 0),
  -slack)`. Lets the constraint go slack (negative) but not stretch
  (positive). One-sided constraints in two lines.
- Pin/attachment constraints (`PinConstraints.compute`): same XPBD form
  with rotational compliance separately tracked.

### Sub-stepping as the primary convergence mechanism

- `ObiSolver.cs:147`: `public int substeps = 4;` (default).
- `ObiSolver.cs:1780-1789`:
  ```csharp
  // Divide each step into multiple substeps:
  for (int i = 0; i < frameSubsteps; ++i) {
      simulationHandle = implementation.Substep(...);
      timeLeft -= substepTime;
  }
  ```
- Inside each substep, the solver runs collision detection ONCE and then
  the constraint Project/Apply loop ONCE per constraint type. Iteration
  count per constraint type is per-constraint (Obi exposes a separate
  `iterations` per constraint kind: distance, bend, collision, etc.) —
  but the *baseline* recommendation in the docs is "1 iter per substep"
  because the substep itself is the iteration.
- The Project kernel in ColliderCollisionConstraints reads `stepTime`,
  `substepTime`, `steps`, `timeLeft` from CPU. Friction cones use
  `stepTime` (full frame), penetration uses `substepTime` (one substep).
  This is a deliberate split: position errors should converge per
  substep; impulse magnitudes should be measured against the full frame
  the user sees.

### Sleep threshold

- `Solver.compute:210-217`:
  ```hlsl
  if (velMagnitude * velMagnitude * 0.5f +
      angularVelMagnitude * angularVelMagnitude * 0.5f <= sleepThreshold)
  {
      positions[p] = prevPositions[p];
      orientations[p] = prevOrientations[p];
      velocities[p] = FLOAT4_ZERO;
      angularVelocities[p].xyz = float3(0,0,0);
  }
  ```
  Particles at rest have their position snapped back to `prevPosition`
  and velocity zeroed. Cleanly kills tick-rate jitter for settled
  particles. We don't have this; cheap to add.

### Collision material combine modes

- `CollisionMaterial.cginc:33-90`: friction / stickiness combine via
  one of {Average, Min, Multiply, Max}, selected by max() of the two
  materials' `frictionCombine` mode. Designer-friendly stack for the
  §4.4 modulator system once we open it. We currently bake friction at
  Tentacle level only; per-collider material composition is missing.

### Solver parameters Obi exposes that we don't

From `SolverParameters.cginc`:

- `maxDepenetration` — caps the depenetration velocity (m/s) so a
  deeply-penetrated particle can't be ejected at infinite velocity in
  one tick. **We should add this.** Maps directly to our
  `set_collision_radius` family.
- `collisionMargin` — distance at which contacts start being tracked.
  Equivalent to our `QUERY_BIAS=1.05` but expressed as an absolute
  margin, not a multiplier. Cleaner.
- `colliderCCD`, `particleCCD` — continuous collision detection
  parameters. Same problem as our slice 4O.
- `shockPropagation` — propagates impulses up through stacked particles
  (jenga stability). Not relevant for tentacles, would matter for
  rope-with-rigid-attachments.
- `damping` — global velocity damping. We have this.

---

## Slice plan revisions

### Slice 4M — replace "bisector friction" with Jacobi + atomic deltas + per-contact lambda

**What changes:**
- `EnvironmentContact` becomes a list of contacts (not a fixed-size
  slot array). Cap stays at 2 for now per the original plan; bump only
  when orifice phase hits a genuine 3+ case. *Buffer* the list in a
  flat `LocalVector<EnvironmentContact>` to keep cache coherent.
- Each contact owns its own `normal_lambda`, `tangent_lambda` (and
  `bitangent_lambda` once we go pyramid; cone is fine for v1). These
  reset in `predict()` per tick (or per substep once 4O lands).
- The iterate loop runs *over contacts*, not over particles. For each
  contact: compute lambda delta, accumulate into the contact's lambda,
  push position delta into a per-particle scratch buffer with
  `position_delta_count`. After all contacts processed in this iter,
  apply: `position += scratch_delta * SOR / count`.
- Friction reads its own contact's accumulated normal lambda for the
  cone. No `iter_dn_buffer`; that buffer goes away.
- Slice 4J cleanup goes away entirely. The end-of-tick penetration
  comes from un-converged constraints; with lambda accumulation that
  resolves properly within the iter loop.

**What stays:**
- Probe still uses `intersect_shape` to find up to 2 contacts.
- Sub-step 4M-pre.1 (`dt` clamp), 4M-pre.2 (singleton-target softening)
  are unchanged.
- Sub-step 4M-pre.3 (two-endpoint-wedged distance softening) is
  superseded by the lambda-accumulator approach but worth keeping as a
  cheaper fallback if we punt full XPBD on distance.

**SOR factor:** Obi defaults to `sorFactor = 1.0` for parallel mode.
For chains (2-4 contacts/particle typical), 1.0 is safe. Expose as a
solver-level knob. Higher `sorFactor` (1.5-2.0) is the over-relaxation
that speeds convergence but can overshoot; safer to leave at 1.0
default.

### Slice 4M-XPBD (new sub-slice) — distance constraint compliance

Land XPBD on the distance constraint *together with* the lambda
contact accumulators in 4M, because:

1. Both need the same per-constraint lambda buffer infrastructure.
2. XPBD distance fixes "stiffness fights collision" without needing
   the wedge-special-case softening from 4M-pre.3.
3. Lambdas reset per-substep cleanly when 4O lands.

**Migration path:** keep `set_distance_stiffness(0..1)` as the public
API. Internally translate to compliance:
`compliance = lerp(1e-9, 1e-3, 1 - stiffness)` — small at high
stiffness (near-rigid), large at low. The user-visible behavior of
"stiffness=1 means rigid" preserved; the math underneath becomes XPBD.
TentacleMood presets need re-tuning: existing `distance_stiffness=1.0`
will feel slightly less rigid than before because XPBD doesn't compound
across iterations the way our current form does.

This effectively moves Phase 4.5's "XPBD compliance" item *into Phase 4
close-out*. The previous reasoning ("would force re-tuning the whole
mood preset library") is still true, but contained — only distance
needs re-tune; bending stays chord-form (pre-XPBD); pose/target are
already lerp-style and don't change.

### Slice 4N — fresh contact snapshot

Unchanged. Still want this for the GDScript driver.

### Slice 4O — sub-stepping

Acceptance criterion shifts: instead of "no tunneling in thrust frame,"
the canonical default becomes "substeps=2, iterations=2 per substep" or
"substeps=4, iterations=1" matching Obi. Validate that current
TentacleMood presets still feel right under the new defaults; if
distance gets too soft, bump iter count not stiffness (preserves the
Obi convergence ordering).

Add `Tentacle::set_substep_count(int)` exposing the substep knob;
default 1 for backward compat with shipping behavior, recommend 2-4
for thrust-heavy moods. After a re-tune pass, flip default to 2.

### Slice 4P (new) — sleep threshold + max depenetration

Two cheap one-liners that close the loop on the wedge case:

1. **Sleep threshold.** In `predict()` (or a new `apply_sleep()` step
   after `iterate()`), if a particle's velocity squared is below a
   threshold, snap `position = prev_position` and zero its implicit
   velocity. Kills the residual jitter of marginally-converged contacts
   that the slice 4I damping never fully eliminates.
2. **Max depenetration cap.** In the iterate loop's collision step,
   clamp the per-iter normal correction to `max_depenetration *
   substep_time`. Prevents a deeply-penetrated particle from being
   ejected at infinite velocity, which is what makes the existing
   "tunneling through a wall on first frame" failure mode visually
   explosive.

Both are in `Solver.compute:204-216` and `ColliderCollisionConstraints.
compute:144` respectively in Obi. Each is < 10 lines.

---

## What we should NOT borrow

- **2D friction pyramid** (separate tangent + bitangent). Obi uses it
  because it's the standard rigid-body friction shape; for a 1D chain
  the tangential motion is dominated by one direction (chord-aligned)
  and the bitangent component is small. Keep our 1D cone; revisit if
  rolling/spinning particles become a thing (they aren't planned).
- **Rolling friction.** Same reason — only matters for rotating bodies.
- **Sequential (Gauss-Seidel) mode.** Obi exposes both because GPU
  parallelism strongly favors Jacobi and CPU favors Gauss-Seidel. Our
  C++ solver is CPU-only at modest particle counts (16-32 per
  tentacle, ~10 tentacles); Gauss-Seidel — what we already do — is
  fine. Don't add the Jacobi mode just to mirror Obi.
- **Compute-shader port.** TentacleTech's particle counts are 100s,
  not millions. Compute-shader infra costs more in plumbing than it
  saves in math. Stay CPU.
- **Particle sleeping for tentacles in motion.** The sleep threshold is
  good for *settled* particles (e.g. tentacle hanging at rest). For
  active-driven tentacles every particle moves every tick; the
  threshold check costs more than it saves. Make it opt-in per-tentacle
  via a mood flag.

---

## Reading order if continuing the dive

For sub-Claude or future research:

1. `ColliderCollisionConstraints.compute` — multi-contact pattern.
2. `ContactHandling.cginc` — contact struct + lambda accumulators.
3. `DistanceConstraints.compute` — canonical XPBD form, 70 lines.
4. `AtomicDeltas.cginc` — Jacobi accumulator + SOR apply pattern.
5. `Integration.cginc` — predict/differentiate cycle. 36 lines.
6. `Solver.compute` — predict, sleep, velocity update. Useful for
   slice 4P sleep threshold copy.
7. `ObiSolver.cs:1780-1789` — substep loop, in C# (more readable than
   the HLSL dispatcher).
8. `BendConstraints.compute`, `PinConstraints.compute`,
   `ChainConstraints.compute` — XPBD forms for the constraints we
   haven't touched yet. Read when promoting bending or adding chain.
9. `Burst/` directory — same kernels in C# Burst. Easier to read than
   HLSL if the GPU layer is unfamiliar.

The PDFs (`QuickstartGuide_*.pdf`) are user-facing setup tutorials,
not algorithmic. Skip unless you want to understand Obi's inspector
UX patterns — relevant only if we ever build similar editor tooling.

The CHANGELOGs are bug-fix logs, not design discussion. Skim only.

---

## Addendum 2026-05-03 (part 2) — Rope + Cloth source

The user dropped the Obi Rope and Obi Cloth Unity assets on top of the
Softbody/Fluid drop. Most of the compute kernels were already present
(Obi shares one HLSL set across all four products); the new value is in
`Scripts/RopeAndRod/` and three previously-unread compute kernels:
`ChainConstraints.compute`, `PinholeConstraints.compute`,
`TetherConstraints.compute`.

### The four new findings

1. **`ChainConstraints.compute` is a direct (non-iterative) tridiagonal
   solver for the entire chain at once.** It treats the N-1 distance
   constraints as a coupled linear system, builds the tridiagonal
   matrix from edge gradients, then forward + backward sweeps in O(N)
   to produce per-particle deltas that satisfy the entire chain
   simultaneously. No iteration count to tune. Supports `(minLength,
   maxLength)` so chains can have slack in compression but be rigid in
   extension — useful for ropes that should hang loose but not
   stretch. **Caveat: doesn't compose with other distance constraints
   touching the same particle**, so it's a chain-only solver.
2. **`PinholeConstraints.compute` is the Phase 5 orifice abstraction
   already implemented.** A pinhole is a fixed offset on a collider
   that a rope edge threads through. The constraint pulls the rope's
   `mix`-along-edge point to the pinhole offset, with motor force +
   target velocity, artificial friction, range clamping, and edge
   advancement when `mix` slides past 0/1. This *is* the §6.10
   ContractionPulse / orifice mechanic.
3. **`TetherConstraints.compute` is a one-sided XPBD distance** —
   only fires when `constraint > 0` (overstretch). Maps `maxLengthScale`
   to allow user-controlled slack range. The existing
   `wedge_distance_stiffness_factor=0.3` softening from 4M-pre.3 is
   really "let this segment go slack" — same idea, but tether expresses
   it as a length range rather than a stiffness softening.
4. **`ObiRopeCursor` runtime length adjustment.** Tentacles that grow,
   retract, or feed-through-orifice need a similar mechanism. The
   pattern is: a "cursor" tracks `(mu, sourceIndex)` along the chain
   and inserts/removes structural elements at the cursor's position
   as `cursorMu` changes. Worth flagging for future tentacle-length
   modulation.

### Effect on the cluster plan

**No change to slice 4M / 4M-XPBD.** ChainConstraints (direct solver) is
attractive but doesn't help the wedge case — wedged chains specifically
need *per-segment* compliance softening (some segments stiff, some soft,
based on contact state), which the coupled tridiagonal can't express
cleanly. Per-segment XPBD is the right call for Phase 4.

**ChainConstraints as Phase 9 polish.** For non-contact segments
(tentacle hanging in free air with no collider hits), the direct solver
is mathematically exact in O(N) versus our per-segment XPBD's "good
enough" iterative approximation. A future optimization could route
contact-free chains through the direct solver, contact chains through
per-segment XPBD. Out of scope for now; revisit only after Phase 5.

**Phase 5 (orifice) gets a head-start from PinholeConstraints.** The
abstraction is:

```
struct OrificeConstraint {
    int rope_edge_index;       // which (i, i+1) edge of the chain
    float edge_mu;             // 0..1 position along that edge
    int collider_index;        // host body
    Vec3 collider_offset;      // pinhole position in collider local space
    float compliance;          // XPBD compliance
    float friction;            // 0..1 — artificial friction blend
    float motor_target_velocity;
    float motor_max_force;
    int2 edge_range;           // first/last edge indices the cursor can slide across
    float2 edge_range_mus;     // mu clamps at the range boundaries
    bool clamp_on_end;         // if true, cursor stops at edge_range; if false, constraint detaches
};
```

Reading `PinholeConstraints.compute::Initialize` shows the per-tick
work:
1. Predict pinhole world position from collider velocity.
2. Compute current `mix` from the nearest-edge projection.
3. Apply motor: `targetAccel = (motor_target_vel - vel) / dt`,
   capped by `motor_max_force / mass`.
4. Apply artificial friction: `mix = lerp(mix, mix + vel*dt/edge_len,
   friction)`.
5. If `mix` slid past `[0,1]`, advance to next edge in the chain
   (with range clamping) — up to 10 edges per tick.

`Project` then runs XPBD between the rope edge and the pinhole offset:
```
gradient = projection - predicted_pinhole_offset
constraint = |gradient|
lambda = (-constraint - compliance * lambdas[i]) /
         (lerp(invMass[p1], invMass[p2], mix) +
          rb_linear_w + rb_angular_w + compliance + EPSILON)
```

Same XPBD form as everything else. The reciprocal impulse on the
collider's rigidbody is `-correction / frameEnd`.

**This unifies our planned §6 mechanics into one constraint type:**

- Ring bones with spring-damper → `compliance` parameter.
- Multi-tentacle in orifice → multiple OrificeConstraints sharing the
  same collider/offset, different `rope_edge_index`.
- ContractionPulse → time-varying `motor_target_velocity` + spike on
  `motor_max_force`.
- Tunnel projector → range-clamped pinhole that lets the rope slide
  through but not laterally.
- Reaction-on-host-bone closure (§6.3) → the existing reciprocal
  impulse `ApplyImpulse(rigidbodyIndex, -correction / frameEnd, ...)`
  already does this.

**Update 2026-05-03:** the originally-planned 8-direction-ring-bone
orifice structure has been retired. The orifice is now a closed-loop
rim of N PBD particles per loop (multi-loop per orifice supported)
governed by XPBD distance + volume + per-particle spring-back
constraints. See `docs/Cosmic_Bliss_Update_2026-05-03_orifice_rim_model.md`
(canonical amendment; architecture doc edited to match) and
`docs/Cosmic_Bliss_Update_2026-05-03_obi_realism_and_orifice.md` §2
(rationale). When Phase 5 opens, sub-Claude reads §6.1-§6.4 of the
amended architecture doc directly.

### Reading order if continuing the rope dive

1. `Resources/Compute/PinholeConstraints.compute` — orifice math (310 lines).
2. `Resources/Compute/ChainConstraints.compute` — direct chain solver (160 lines).
3. `Resources/Compute/TetherConstraints.compute` — one-sided XPBD (65 lines).
4. `Scripts/RopeAndRod/Actors/ObiRopeCursor.cs` — runtime length adjustment.
5. `Scripts/RopeAndRod/Actors/ObiRope.cs` + `ObiRopeBase.cs` — high-level
   class structure; relevant when designing the analogous Tentacle API
   surface for orifice threading.
6. `Resources/Compute/StretchShearConstraints.compute` and
   `BendTwistConstraints.compute` — for `ObiRod` (orientation-aware
   rope with twist). Read only if quaternion-per-particle becomes a
   thing for tentacles (currently not planned — rest-pose orientation
   is implicit from the chord direction).

Skip: `Scripts/Cloth/` (cloth-specific topology generation, not
algorithmically novel); `Resources/Compute/SkinConstraints.compute`
(cloth-skin-to-rigged-mesh — relevant for §10 mesh skinning if we
ever GPU-skin tentacles, but not for solver work).

