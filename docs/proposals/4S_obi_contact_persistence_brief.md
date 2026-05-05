# 4S brief — Obi contact-local-frame persistence + adjacent mechanisms

Reference paths in this brief use the gitignored Obi source at `docs/pbd_research/Obi/`.
File:line citations are reproducible verbatim from a fresh clone of that source.

## TL;DR

**Obi does NOT structurally solve the lub=1.0 (frictionless tangential slide) jitter case
the way the top-level Claude's hypothesis assumed.** Obi's contact `pointB` field is stored
in *solver space* (i.e., world frame from the solver's POV), NOT in body-local space. It is
populated at fresh-zero by the per-shape `GenerateContacts` kernel, which is called *once per
outer simulation step* (not per substep). Within an outer step, lambdas + the cached contact
plane persist across substeps + iters. Across outer steps, contacts are fully regenerated
from scratch — no body-local frame transform, no cross-step warm-start.

For our scene this means: Obi's mechanism would be approximately *equivalent to our current
`substep_count = 1` configuration with the 4M lambda accumulator*. The per-tick churn the
user observed at lub=1.0 (340 hit_point shifts, 725 normal flips over 240 ticks) would
manifest *the same way in Obi* against a faceted convex hull — Obi just regenerates contacts
each frame and calls it a day.

Obi DOES contain four other patterns that are jitter-relevant and worth borrowing:

1. **Symplectic Euler integration** (NOT position-Verlet like ours). Velocity is a
   first-class state variable; gravity adds to velocity, then position += velocity × dt.
   This is **invariant under substepping** (total velocity gain across N substeps =
   `N × g × sub_dt = g × outer_dt` exactly). Our position-Verlet under-integrates gravity
   by ~5/8× under 4×1 substepping — that's the math reason the 4R default flip caused the
   probing regression.
2. **Frank-Wolfe convex optimization for surface point** — finds an analytic closest point
   on a convex shape rather than relying on per-face physics-server queries. Smooth across
   face crossings.
3. **Per-shape `contactOffset` + per-material `stickDistance` speculative margins** —
   broadphase expands AABB by both, contact triggers slightly above the surface, hysteresis
   prevents on/off flicker.
4. **Per-collider friction material composition** with Average / Min / Multiply / Max
   combine modes. Independent slice; small lift.

**Recommended scope for 4S-impl**: NOT a one-shot "mimic Obi's contact persistence" slice
(because Obi doesn't have the persistence the user hypothesized). Instead, three sequenced
small/medium slices:

- **4S.1 (medium)** — Symplectic Euler integration. Unlocks 4R's default flip without the
  feedback regression. Touches `predict()` + `finalize()`. ~100 lines.
- **4S.2 (medium)** — Body-local-frame contact persistence (genuinely new mechanism, not
  imported from Obi but motivated by the lub=1.0 evidence). Per-particle cache of last
  contact transformed through `body.global_transform` into body-local space; re-probe only
  triggers on hysteresis breach. ~150 lines.
- **4S.3 (small-medium)** — Per-collider material composition (mirror Obi's `CombineWith`).
  Independent of 4S.1/4S.2; low risk. ~80 lines.

4S.1 is the load-bearing prerequisite for revisiting 4R's default flip; it should land
first regardless of whether 4S.2 is approved.

---

## Findings

### Q1 — contact data storage and frame

**Citation: `Resources/Compute/ContactHandling.cginc:7-24`**

```hlsl
struct contact // 96 bytes
{
    float4 pointA; // point A, expressed as simplex barycentric coords for simplices, as a solver-space position for colliders.
    float4 pointB; // point B, expressed as simplex barycentric coords for simplices, as a solver-space position for colliders.
    float4 normal;
    float4 tangent;
    float dist;
    float normalLambda;
    float tangentLambda;
    float bitangentLambda;
    float stickLambda;
    float rollingFrictionImpulse;
    int bodyA;
    int bodyB;
};
```

**Citation: `Resources/Compute/CapsuleShape.compute:46,61-65`** (representative — every shape's
`GenerateContacts` follows the same template):

```hlsl
contact c = (contact)0;                                  // line 46 — fresh zero-init
...
SurfacePoint surfacePoint = Optimize(capsuleShape, ...); // line 58 — Frank-Wolfe in solver space
c.pointB = surfacePoint.pos;                              // line 61 — solver-space point
c.normal = surfacePoint.normal * capsuleShape.s.isInverted();
c.pointA = simplexBary;                                  // barycentric for the particle simplex
c.bodyA = simplexIndex;                                   // int index into simplex table
c.bodyB = colliderIndex;                                  // int index into shape/collider table
```

**Frame**: `pointB` is **solver-space** (== world-space from the solver's POV), NOT body-local.
The shape is brought into solver space via `colliderToSolver = worldToSolver[0].Multiply(transforms[colliderIndex])`
(line 49) before optimization, so `surfacePoint.pos` is the closest point ON the shape EXPRESSED in
solver space. `bodyA`/`bodyB` are *table indices*, not RIDs — used to look up the rigidbody /
collider data structures during constraint projection.

**Lambdas (`normalLambda`, `tangentLambda`, etc.)** are part of the contact struct and are
zero-initialized at GenerateContacts time alongside `pointB`/`normal`.

**When does GenerateContacts run?** From `Scripts/Common/Backends/Burst/Solver/BurstSolverImpl.cs:114`:
```cs
burstHandle.jobHandle = GenerateContacts(burstHandle.jobHandle, stepTime);
```
This is called from the parent step entry, NOT from `Substep(...)` (line 117+ where the substep
loop body lives). One contact set per outer step; substeps + iters share it.

**Adaptation to our pipeline**:

- Our `EnvironmentContact` struct already stores `hit_point[k]` + `hit_normal[k]` in world space —
  matches Obi's `pointB` semantics exactly. ✓
- Our `set_environment_contacts_multi(... rids)` (slice 4R) is called per substep currently.
  Obi calls equivalent ONCE per outer step. We could match by short-circuiting probe+set on
  substeps 2-4 (cheaper, plus removes per-substep face-jump churn) — but that requires solving
  the substep-gravity-scaling issue first (Q5).
- Body-local-frame storage is **NOT** what Obi does. If we want it, that's a NEW mechanism
  beyond Obi.

---

### Q2 — contact transformation at projection time

**Citation: `Resources/Compute/ColliderCollisionConstraints.compute:171-180`** (the `Project` kernel):

```hlsl
// project position to the end of the full step:
float4 posA = lerp(simplexPrevPosition, simplexPosition, substepsToEnd);
posA += -contacts[i].normal * simplexRadius;

float4 posB = contacts[i].pointB;       // line 174 — cached, NOT re-evaluated
int rbContacts = 1;
if (rigidbodyIndex >= 0)
{
    posB += GetRigidbodyVelocityAtPoint(rigidbodies[rigidbodyIndex], contacts[i].pointB,
                                        asfloat(linearDeltasAsInt[rigidbodyIndex]),
                                        asfloat(angularDeltasAsInt[rigidbodyIndex]),
                                        inertialSolverFrame[0]) * frameEnd;
    rbContacts = rigidbodies[rigidbodyIndex].constraintCount;
}
```

**Mechanism**: cached `pointB` is **velocity-extrapolated forward by `frameEnd` (the full outer
step time)** using the rigidbody's predicted velocity at that point. There is NO body-local
transform applied; the cached solver-space point is treated as moving in solver space at the
rigidbody's velocity-at-point. For static colliders (rigidbodyIndex < 0), `posB = contacts[i].pointB`
unchanged across all substeps + iters.

**Per-iter? Per-substep?** Per-iter — the `Project` kernel runs once per iter, but it only reads
`contacts[i].pointB` and uses it via the velocity extrapolation. The contact field itself is
NEVER modified during Project. Only the `lambda` accumulators are written (`SolveAdhesion`,
`SolvePenetration`, `SolveFriction` all `inout contact c`).

**Hysteresis radius / re-probe trigger**: NONE. Obi just regenerates contacts at the start of
the next outer step.

**Adaptation**: this is the pattern we'd most directly *invert* — instead of caching
`pointB` in solver space and extrapolating by velocity, cache it in *body-local* space and
transform through `body.global_transform` per substep. Obi can get away with velocity
extrapolation because `frameEnd` is short (single physics tick) and `velocity` is constant
within a step. Body-local would be more accurate for our case where:
- The chain probes per Godot physics tick (60 Hz) — long enough that velocity extrapolation
  on PhysicalBone3D could miss rotation-driven contact-point shifts.
- Faceted convex hulls produce per-face hit_point jumps that aren't captured by linear
  velocity extrapolation alone.

---

### Q3 — what happens when a particle drifts away from the persisted contact point?

**Finding**: there is no "release" condition during projection. The contact constraint
`(posA - posB) · normal ≥ 0` is satisfied or it isn't. If the particle drifts tangentially
beyond the cached contact point, the projection still pushes it toward the cached plane —
which is fine for a flat surface but introduces error on a curved hull.

**At-end-of-step**: contacts get regenerated from scratch, so a new contact is computed at
the current particle position. Effective release threshold = "next outer step boundary".

**Citation: `Resources/Compute/ColliderGrid.compute:107,111`** (broadphase, NOT the projection):

```hlsl
// Expand bounds by rigidbody's linear velocity
if (rb >= 0)
    bounds.Sweep(rigidbodies[rb].velocity * deltaTime);

// Expand bounds by collision material's stick distance:
if (shapes[i].materialIndex >= 0)
    bounds.Expand(collisionMaterials[shapes[i].materialIndex].stickDistance);
```

The stickDistance expansion is the closest thing to a "speculative margin" / "re-probe
hysteresis": a particle within `stickDistance` of the surface enters the broadphase and gets
a contact generated. Re-probe trigger is implicit (= "new outer step + AABB overlap").

**Adaptation**: if we adopt body-local-frame persistence (4S.2), we'd want an explicit
release threshold — e.g., re-probe when the persisted contact's body-local point projected
back to world space is more than `2 × collision_radius` from the particle position. Obi
doesn't have this because it never persists across steps; we'd be inventing it.

---

### Q4 — RID/transform discontinuity defenses

**Finding**: minimal. Each frame's contact set is built fresh from active colliders. A
vanished collider just doesn't generate contacts that frame. There's no defensive cleanup
of stale contact state because nothing persists.

**Citation: `Resources/Compute/ColliderGrid.compute:106`**:
```hlsl
// (check against out of bounds rigidbody access, can happen when a destroyed collider references a rigidbody that has just been destroyed too)
if (rb >= 0)// && rb < rigidbodies.Length)
    bounds.Sweep(rigidbodies[rb].velocity * deltaTime);
```
The commented-out length check + the comment hints that the C# scheduler is responsible for
destroying / repacking the rigidbody table cleanly between frames. The compute side trusts
its inputs.

**Adaptation**: if we add body-local persistence, we MUST handle:
- RID disappearance: cached contact gets invalidated; particle reverts to "no contact" state.
- Body teleport (transform jumps discontinuously): velocity extrapolation would be wrong;
  detect via "transform delta > N × collision_radius this tick → invalidate cache."
- Body destroyed mid-tick: the cached `body.global_transform` query would fail; needs a
  validity check before each lookup.

Our slice 4R already tracks RID per slot, so RID-based invalidation is already half-built.

---

### Q5 — substep gravity / external-force scaling

**Citation: `Resources/Compute/Solver.compute:128-156`** (the `PredictPositions` kernel):

```hlsl
float4 effectiveGravity = float4(gravity, 0);
...
// apply external forces and gravity:
float4 vel = velocities[p] + (invMasses[p] * externalForces[p] + effectiveGravity) * deltaTime;
...
velocities[p] = vel;
...
positions[p] = IntegrateLinear(positions[p], velocities[p], deltaTime);
orientations[p] = IntegrateAngular(orientations[p], angularVelocities[p], deltaTime);
```

**Citation: `Resources/Compute/Integration.cginc:6-9`** (the `IntegrateLinear` definition):

```hlsl
float4 IntegrateLinear(float4 position, float4 velocity, float dt)
{
    return position + velocity * dt;
}
```

**This is symplectic Euler**: velocity is a first-class state variable stored in `velocities[]`.
Per substep:
1. `velocity += (force + gravity) × sub_dt`
2. `position += velocity × sub_dt`

After N substeps from rest:
- Velocity gain: `Σ g·sub_dt = N · g · (dt/N) = g · dt` ✓ invariant.
- Position gain: approximately `½ · g · dt²` (Euler converges to this for small sub_dt; the
  truncation error decreases with N).

**Compare to our position-Verlet** (`extensions/tentacletech/src/solver/pbd_solver.cpp:139-161`):
```cpp
Vector3 velocity = (p.position - temp_prev) * damping;  // implicit, from prev_position
Vector3 gravity_step = gravity * dt2;                    // dt2 = sub_dt²
p.position += velocity + gravity_step;
```

Position-Verlet from rest with N substeps:
- Substep 1: Δx = `g · sub_dt²`
- Substep 2: Δx = `2 g · sub_dt²` (cumulative position from Verlet recurrence)
- Substep N: Δx_total ≈ `(N(N+1)/2) · g · sub_dt² = (N+1)/(2N) · g · dt²`
- For N=4: Δx_total ≈ `5/8 · g · dt²` — under-integrates by ~37%.

**This is the math reason 4R's default flip caused the probing regression**: at substep_count=4
our chain gets only 5/8× the gravity displacement per outer tick, which means 5/8× normal
penetration → 5/8× normal_lambda → 5/8× friction cone → chain slips far more often. The
warm-start preserved the small lambdas across substeps but the underlying force budget was
wrong.

**Adaptation**: 4S.1 = port `predict()` to symplectic Euler. Add `Vector3 velocity` as a
first-class state on `TentacleParticle`. `predict()` becomes:
```cpp
particle.velocity += gravity × dt;  // add gravity acceleration to velocity
particle.position += particle.velocity × dt;
```
And `finalize()` no longer needs the implicit velocity computation; velocity is already there.

**Risks**:
- All existing constraint projections currently update `position` and rely on the implicit
  Verlet `velocity = (position - prev_position) / dt`. Migrating to explicit velocity means
  velocity must also be updated when constraints change position. That's the Obi pattern
  (UpdateVelocities kernel runs after ApplyConstraints, recomputing velocities via
  `DifferentiateLinear(position, prevPosition, dt)`).
- Mood-tunable `damping` is currently a multiplicative scaler on the implicit Verlet velocity
  — would need to migrate to a velocity_scale applied per substep (Obi: `velocityScale =
  pow(1 - damping, sub_dt)`, see `BurstSolverImpl.cs:158` excerpt).

---

### Q6 — lambda warm-start across substeps / outer ticks

**Within an outer step, across substeps + iters**: lambdas accumulate. The contact struct
is populated once at GenerateContacts time (Q1), and `Project` reads + writes `c.normalLambda`,
`c.tangentLambda`, etc. across all subsequent passes. See
`Resources/Compute/ContactHandling.cginc:147-154` (SolvePenetration) and
`ContactHandling.cginc:175-193` (SolveFriction) — both `inout contact c` and
`c.normalLambda + dlambda`.

**Across outer steps**: NO warm-start. Contacts regenerate fresh-zero at GenerateContacts
(Q1: `c = (contact)0`).

**Interaction with contact-point persistence**: there is none, because Obi doesn't persist
contact points across outer steps either.

**How this maps to our 4R warm-start**:
- We currently zero lambdas at outer-tick boundary (`Tentacle::tick → reset_environment_contact_lambdas`)
  — matches Obi's "regenerate contacts fresh" semantics. ✓
- We RID-key the warm-start across substeps within an outer tick — Obi does this implicitly
  because the contact struct lives unchanged through the substep loop. We do it explicitly
  because our probe runs per substep. Both achieve the same outcome.
- Effectively: at substep_count=1, our 4R warm-start path is equivalent to Obi's pattern
  (single substep, lambdas accumulate within iters, reset at next tick). At substep_count>1,
  our pattern is *more* aggressive than Obi's because Obi only generates contacts ONCE per
  outer step whereas we re-probe per substep. This is potentially better (catches body
  motion within a tick) but more expensive AND introduces per-substep face-jump churn.

**Adaptation**: matches our current 4R behaviour. No change needed.

---

### Q7 — per-collider friction material composition

**Citation: `Resources/Compute/CollisionMaterial.cginc:33-90`**:

```hlsl
collisionMaterial CombineWith(collisionMaterial a, collisionMaterial b)
{
    int frictionCombineMode = max(a.frictionCombine, b.frictionCombine);
    int stickCombineMode = max(a.stickinessCombine, b.stickinessCombine);

    switch (frictionCombineMode)
    {
        case 0: default:  // Average
            result.dynamicFriction = (a.dynamicFriction + b.dynamicFriction) * 0.5f;
            result.staticFriction = (a.staticFriction + b.staticFriction) * 0.5f;
            ...
        case 1:  // Min
            result.dynamicFriction = min(a.dynamicFriction, b.dynamicFriction);
            ...
        case 2:  // Multiply
            result.dynamicFriction = a.dynamicFriction * b.dynamicFriction;
            ...
        case 3:  // Max
            result.dynamicFriction = max(a.dynamicFriction, b.dynamicFriction);
            ...
    }
    ...
    result.stickDistance = max(a.stickDistance, b.stickDistance);   // ALWAYS max
    result.rollingContacts = a.rollingContacts | b.rollingContacts;  // ALWAYS or
}
```

**Citation: `Resources/Compute/CollisionMaterial.cginc:92-107`** (handles missing materials):

```hlsl
collisionMaterial CombineCollisionMaterials(int materialA, int materialB)
{
    if (materialA >= 0 && materialB >= 0)
        combined = CombineWith(collisionMaterials[materialA], collisionMaterials[materialB]);
    else if (materialA >= 0)
        combined = collisionMaterials[materialA];
    else if (materialB >= 0)
        combined = collisionMaterials[materialB];
    else
        combined = EmptyCollisionMaterial();
    return combined;
}
```

**Combine mode** is decided by `max(a.frictionCombine, b.frictionCombine)` — i.e., the
material with the higher mode wins, where mode 3 (Max) > 2 (Multiply) > 1 (Min) > 0 (Average).
This is a deterministic resolution that gives "stronger" behaviors precedence.

**Material struct** (`CollisionMaterial.cginc:4-14`):
```hlsl
struct collisionMaterial
{
    float dynamicFriction;
    float staticFriction;
    float rollingFriction;
    float stickiness;
    float stickDistance;
    int frictionCombine;
    int stickinessCombine;
    int rollingContacts;
};
```

**Adaptation**: 4S.3 — directly portable. We currently compose friction per-tentacle as
`mu_s = base_static_friction × (1 - tentacle_lubricity)`. To add per-collider materials:
- Surface a `CollisionMaterial` resource (or just StaticBody3D physics_material attached) and
  read it in the probe pipeline.
- Pass per-slot composed `mu_s_combined` + `mu_k_combined` through the contact pipeline
  alongside `nlam` / `tlam`.
- Solver reads composed values instead of `friction_static` / `friction_kinetic_ratio`.
- Default mode = Average for backward compat.

Risk: existing `tentacle_lubricity` knob remains the per-tentacle modulator; combining with
per-collider material is straightforward per Obi's pattern.

Sized at ~80 lines of pipeline plumbing (extension of existing `set_environment_contacts_multi`
to also pass per-slot materials, plus solver-side reads + binding).

---

### Q8 — anything else jitter-relevant

| Pattern | Citation | One-line characterization |
|---|---|---|
| Velocity & angular velocity clamping | `Solver.compute:201-208` | `min(maxVelocity, ‖v‖)` per particle per UpdatePositions; we already have a `base_angular_velocity_limit` near anchors — Obi clamps globally. |
| Kinetic-energy sleep threshold | `Solver.compute:211-217` | `if (½‖v‖² + ½‖ω‖² ≤ sleepThreshold) snap to prev_position` — same shape as our 4P sleep_threshold but KE-based, not just `‖Δx‖/dt`. |
| Speculative margin (broadphase) | `ColliderGrid.compute:107` | `bounds.Sweep(rigidbody.velocity × dt)` — anticipate body motion. |
| Speculative margin (material) | `ColliderGrid.compute:111` | `bounds.Expand(material.stickDistance)` — adhesion radius. |
| Per-shape contactOffset | `ColliderDefinitions.cginc:40` | `float contactOffset` per shape — a "skin" around the collider. We don't have this. |
| Frank-Wolfe analytic surface point | `Optimization.cginc:32-90` | 16-iter convex optimization to find closest point on shape; smooth across face crossings. We rely on Godot's `get_rest_info` which on Jolt + ConvexPolygonShape3D returns per-face hits. |
| Per-step interpolation for rendering | `Solver.compute:264-287` | Renderable position is lerp(start, end, blendFactor) — decouples rendering from physics step boundary. We don't need this. |
| `SolveAdhesion` (stickiness) | `ContactHandling.cginc:109-132` | Adhesive normal force when particle within stickDistance of surface. Material-driven. We don't have this. |
| `SolveRollingFriction` | `ContactHandling.cginc:199-226` | Rolling friction torque on rotating particle. We don't model particle rotation; not applicable. |
| Tangent + bitangent friction pyramid | `ContactHandling.cginc:160-197` | 2D friction (tangent × bitangent), not our 1D scalar. Per-axis lambda accumulator. Spec divergence we already flagged in 4M. |
| Gauss-Seidel batch sorting | `Scripts/.../BurstSolverImpl.cs` | Contact sorter divides contacts into independent batches for sequential GS-style solve. Avoids race conditions. We do Jacobi+SOR via atomic deltas (slice 4M); both work. |
| `colliderCCD` / `particleCCD` flags | `SolverParameters.cginc:16-17` | Continuous collision detection flags. Out of scope per slice. |

---

## Risks and divergences

For each pattern we'd consider adopting:

### 4S.1 — Symplectic Euler integration

**Implementation risk**:
- Interaction with **4M lambda accumulator**: lambda accumulators are `inout contact` style —
  agnostic to Verlet vs Euler. Should compose cleanly. Lambdas measure constraint impulse,
  not implicit velocity, so they don't care which integrator is upstream.
- Interaction with **4Q-fix taper**: taper reads `tlam / (mu_s × nlam)`. Both lambdas come
  from the friction step which uses position-delta projected onto contact tangent plane. With
  Euler, the "position delta" is `velocity × sub_dt`, semantically equivalent. Taper should
  behave identically.
- Interaction with **4R RID warm-start**: warm-start matches RID and copies lambdas. Doesn't
  care about integrator. ✓
- **Damping semantics shift**: our current `damping` is multiplicative on the implicit
  Verlet velocity (`(position - prev_position) × damping`). Under Euler, it'd become
  `velocity *= velocity_scale` where `velocity_scale = pow(1 - damping_per_sec, dt)` for
  dt-correctness. **Mood preset re-tune required** for damping field — current values may
  read different at the new integrator. Probably small adjustment, but flag it.
- **Contact velocity damping** (`contact_velocity_damping`): currently a lerp of prev_position
  toward position at end of finalize(). Under Euler, equivalent is a velocity decay
  (`velocity *= (1 - contact_velocity_damping × dt)`). Re-tune required.
- **Sleep threshold semantics**: currently `‖position - prev_position‖ ≤ threshold × dt` →
  snap to prev_position. Under Euler with explicit velocity, naturally becomes
  `‖velocity‖ ≤ threshold` → snap to prev_position. Cleaner.

**Performance**: net wash. Verlet had implicit velocity computation each predict() (one
subtract + multiply per particle); Euler stores velocity explicitly (one extra Vector3 per
particle = +12 B × N — trivial; ~200 B for a 16-particle chain). Euler eliminates the
prev_position read in predict() but requires UpdateVelocities at the end of finalize(). Net:
roughly equivalent, slightly cleaner code.

**Spec divergence**: Obi runs `UpdateVelocities` AFTER constraints have modified positions —
`v = (position - prevPosition) / dt`. This is explicit-velocity-from-position, NOT
"velocity stays as set in predict". Our implementation should match: predict adds gravity to
velocity, constraints modify position, UpdateVelocities recomputes velocity from position
delta. This means damping applies post-constraint (good).

**Sized at ~100 lines**: predict() rewrite (~30 lines), finalize()/UpdateVelocities (~20
lines), TentacleParticle struct + initialize_chain (~10), mood preset re-tune skim (~30
lines of doc/test adjustments), one regression test sweep across moods to verify no preset
broke (~10 lines).

---

### 4S.2 — Body-local-frame contact persistence (NOT in Obi)

**Implementation risk**:
- Requires per-particle contact cache that survives across outer ticks. **Direct conflict**
  with our current `Tentacle::tick → reset_environment_contact_lambdas` (4R) which clears
  lambdas every outer tick. We'd be inverting that decision: persist contacts (and lambdas)
  across ticks, with explicit invalidation rules.
- **Jolt RigidBody3D + Godot transform timing**: PhysicalBone3D / RigidBody3D's
  `global_transform` is read at solver-tick time. Across our outer tick, the body integrates
  ONCE (we don't substep the physics server). Cached body-local point transformed to world
  via current `global_transform` should be accurate.
- **PhysicalBone3D quirks**: `global_transform` queries during PBD iterations are explicitly
  banned by CLAUDE.md. We'd need to snapshot once per Tentacle::tick and reuse — same
  pattern as the existing collision/probe layer.
- **Interaction with 4Q-fix taper**: taper would now operate on lambdas that persist across
  ticks. `tlam` could grow unboundedly (the same failure mode 4R hit at substep level, but
  now at tick level). Need an explicit decay or normalization. Probably: clamp `tlam` to the
  static cone at end of finalize() so no tick can carry over more than `mu_s × nlam` of
  tangent_lambda.
- **Interaction with 4R RID warm-start**: complementary. RID match + body-local transform
  together: same body persists → cache hit; different body → cache miss + new probe.
- **Hysteresis design**: re-probe trigger = "particle moved > X relative to cached
  body-local point" or "tick counter exceeded". Default radius needs measurement; the
  user's lub=1.0 evidence (340 hit_point shifts in 240 ticks) suggests current churn is
  particle-by-mm scale on a cm-radius particle, so `re_probe_radius ≈ collision_radius / 2`
  is a starting guess.

**Performance**: per particle per substep, `Transform3D × Vector3` matrix-vector multiply
(== 9 mul + 6 add for 3D) + a `Vector3 - Vector3` for the displacement check. ~20 FLOPs per
particle per substep, vs the current `get_rest_info` query which is hundreds-of-microseconds
per call. **Net win**: cache hit avoids a PhysicsServer3D query, which is the dominant cost.

**Spec divergence**: Obi does NOT do this. We're inventing a mechanism beyond Obi to address
a case Obi doesn't handle (because Obi's typical user scene doesn't exhibit it — fluids and
ropes interacting with single bodies don't slide tangentially across faceted hulls the same
way). Document explicitly.

**Sized at ~150 lines**: per-particle cache struct (`Transform3D inverse_body_transform`,
`Vector3 body_local_point`, `Vector3 body_local_normal`, `RID body_rid`, `int tick_age`) —
~40 lines on the C++ side; probe-cache integration (~50 lines); invalidation logic (~30
lines); test (~30 lines).

---

### 4S.3 — Per-collider material composition

**Implementation risk**:
- **Pipeline change**: we'd need per-slot material data flowing from probe → solver. New
  field on `set_environment_contacts_multi` (parallel to RIDs). Interaction with 4R: clean
  extension; same per-slot indexing.
- **Interaction with 4Q-fix taper**: taper reads `friction_static` directly. Per-slot
  composed `mu_s` would need to be looked up by slot index inside the taper. Small change.
- **Backward compat**: when no material is provided (StaticBody3D without PhysicsMaterial),
  default to `EmptyCollisionMaterial()` — falls back to the per-tentacle `tentacle_lubricity`
  modulation only. ✓
- **CollisionMaterial resource**: define a new `TentacleCollisionMaterial : Resource` (we
  don't want to use Godot's `PhysicsMaterial` directly because it doesn't expose
  combineMode). Or extend Godot's via a thin wrapper. Decide before implementation.

**Performance**: trivial. One material struct per slot stored in the contact array, looked
up per iter at friction step. 16 contact slots × 32 bytes per material = 512 B for a
typical chain. No measurable cost.

**Spec divergence**: minor — Obi's combineMode is enum 0..3 (Average/Min/Multiply/Max). Same
contract.

**Sized at ~80 lines**: material struct + combine helper (~30 lines), pipeline plumbing
(~30 lines), binding + tests (~20 lines).

---

## Proposed implementation scope for 4S-impl

Three slices, sized realistically. Recommended order:

1. **4S.1 — Symplectic Euler integration** [medium, ~100 lines]
   - Justification: prerequisite for any future work that wants to revisit substep flip;
     fixes the 4R failure mode at its source.
   - Touches: `pbd_solver.{h,cpp}::predict`, `finalize`, `TentacleParticle`. No new pipeline
     surface.
   - Risk: mood-preset damping re-tune; flag in slice. All test files to re-run + verify.
   - Acceptance: full suite green, regression test still A/B-passing at default substep_count=1,
     and a substep_count=4 spot-check shows leg_ang_max BELOW the substep_count=1 value
     (proving the substep flip now reduces leg motion the way 4R hypothesised).

2. **4S.2 — Body-local-frame contact persistence** [medium, ~150 lines]
   - Justification: directly addresses the user's lub=1.0 jitter case the diagnostic data
     reproduces. NOT an Obi pattern; document as TT-specific.
   - Depends on: 4S.1 (so substep_count=4 is viable). Can in principle land at
     substep_count=1 too — works for the per-tick churn either way.
   - Touches: `EnvironmentContact` (new fields), `EnvironmentProbe::probe` (cache check + body
     transform read), `Tentacle::tick` (cache invalidation logic). Solver side untouched
     (still reads `hit_point` / `hit_normal` post-transform).
   - Risk: Jolt + PhysicalBone3D transform stability — a bone that teleports invalidates the
     cache; need explicit detection. Unbounded lambda accumulation across ticks; need decay
     or end-of-tick clamp.
   - Acceptance: lub=1.0 churn metrics reduced ≥ 5×: hit_point shifts ≤ 70 (was 340),
     hit_normal flips ≤ 150 (was 725), in the 240-tick measurement window. New unit test
     covering cache hit (same body, particle barely moves) + cache miss (body teleports) +
     RID disappear (body destroyed mid-tick).

3. **4S.3 — Per-collider material composition** [small-medium, ~80 lines]
   - Justification: Obi-direct port; opens the door for varied surfaces (slick / sticky /
     rough leg sections). Independent of 4S.1 and 4S.2.
   - Touches: new `TentacleCollisionMaterial` resource, probe pass-through, solver friction
     read.
   - Risk: minimal. Backward-compat fallback to `EmptyCollisionMaterial` for unauthored
     bodies.
   - Acceptance: existing tests green; new test verifies Average/Min/Multiply/Max combine
     modes produce expected friction values on a constructed scenario.

**4S.1 is the load-bearing prerequisite.** 4S.2 and 4S.3 can land independently of each other
after 4S.1.

**Out of scope for 4S-impl entirely** (defer to later slices):
- Frank-Wolfe analytic closest-point optimization (would replace Godot's `get_rest_info` —
  large effort, marginal benefit if 4S.2 already addresses the per-face churn).
- Tangent + bitangent friction pyramid (1D scalar already ratified per the 4M spec divergence).
- Adhesion / `SolveAdhesion` (no current scenario need; revisit if a "sticky" mood preset is
  authored).
- CCD against capsules / colliders (Phase 9 polish per architecture).
- Per-particle rotational state + rolling friction (we don't model particle rotation).
- Renderable interpolation (we don't have the substep-vs-frame split Obi has).

---

## Spot-check anchors

For each major claim, here's the file:line for 30-second verification:

| Claim | Evidence |
|---|---|
| pointB stored in solver-space, NOT body-local | `Resources/Compute/ContactHandling.cginc:9-10` |
| Contacts zero-init at GenerateContacts | `Resources/Compute/CapsuleShape.compute:46` |
| GenerateContacts called once per outer step | `Scripts/Common/Backends/Burst/Solver/BurstSolverImpl.cs:114` (search `GenerateContacts(burstHandle.jobHandle, stepTime)`) |
| pointB extrapolated by velocity × frameEnd | `Resources/Compute/ColliderCollisionConstraints.compute:178-180` |
| Symplectic Euler integration | `Resources/Compute/Solver.compute:135,156` + `Resources/Compute/Integration.cginc:6-9` |
| Friction material combine modes | `Resources/Compute/CollisionMaterial.cginc:39-65` |
| Material composition handles missing materials | `Resources/Compute/CollisionMaterial.cginc:92-107` |
| Lambda persistence within step (across substeps + iters) | `Resources/Compute/ContactHandling.cginc:147-154` (SolvePenetration), `:175-193` (SolveFriction); contact struct survives substep loop unchanged |
| Lambda reset across outer steps | `Resources/Compute/CapsuleShape.compute:46` (`c = (contact)0`) — contact regenerated with zeroed lambdas |
| Speculative margin from material stickDistance | `Resources/Compute/ColliderGrid.compute:111` |
| Broadphase rigidbody sweep | `Resources/Compute/ColliderGrid.compute:107` |
| Sleep threshold based on KE | `Resources/Compute/Solver.compute:211-217` |
| Velocity clamp | `Resources/Compute/Solver.compute:201-208` |
| Per-shape contactOffset field | `Resources/Compute/ColliderDefinitions.cginc:40` |

---

## Files NOT read this slice (out of scope per prompt)

The prompt listed `ColliderUpdate.compute` as a priority file — that file does not exist in
the Obi 7.x source. The closest equivalent (collider transform updates per substep) is
plumbed via `transforms[]` and `worldToSolver[]` StructuredBuffers updated by the C# scheduler;
the per-substep update path is in `Scripts/Common/Backends/Burst/Solver/BurstSolverImpl.cs`,
which I read partially for the Substep dispatch order but not in full.

References to other potentially-relevant files (NOT read this slice):
- `BurstSolverImpl.cs` — the Substep dispatch order / iteration scheduling. Read partially
  for Q1 + Q5 evidence.
- `BurstColliderWorld.cs` — collider table maintenance and per-substep transform updates.
  Could be relevant for understanding cache invalidation timing.
- `Resources/Compute/InertialFrame.cginc` — solver-space ↔ world-space frame transform.
  Relevant for understanding the `frame.TransformPoint` calls inside `GetRigidbodyVelocityAtPoint`.
- `Resources/Compute/Phases.cginc`, `Resources/Compute/Bounds.cginc` — supporting
  infrastructure; not core to the questions.

If the top-level review wants additional confidence on any specific question (e.g., "does
Obi update collider transforms PER SUBSTEP or only per outer step?"), `BurstColliderWorld.cs`
+ the parts of `BurstSolverImpl.cs` not yet read would answer that.
