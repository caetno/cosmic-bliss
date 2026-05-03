# TentacleTech — Architecture

**Canonical technical specification for the TentacleTech extension.** Supersedes all previous architecture documents. This is the single source of truth for how the system works; companion documents cover scenarios/AI (`TentacleTech_Scenarios.md`) and future reaction-system planning (`Reverie_Planning.md`).

---

## 1. Design principles

| Principle | Consequence |
|---|---|
| **Physics first, animation last** | Tentacle shape is the output of a solver; there is no "rig" to fight against |
| **One solver type for everything** | PBD handles length, bending, collision, friction, attachment — no mixing of Verlet + IK + springs |
| **GPU does per-vertex work. CPU does per-segment work** | Tentacles have 16–48 particles on CPU, thousands of mesh vertices on GPU |
| **No per-frame mesh rebuilds** | Orifice stretching uses skeleton bones; mesh deformation is pure vertex shader |
| **Position-based everything** | Friction, collisions, constraints all project positions in PBD iterations; no explicit velocity or impulse integration |
| **State is explicit and cheap to read** | Every system publishes to the stimulus bus; anyone can subscribe |
| **"Alive" is a noise-and-shader problem, not a behavior-tree problem** | Motion emerges from layered noise on parameters, not from discrete states |
| **Soft physics over scripted levers** | If a behavior can't be expressed via stiffness, friction, grip, damage thresholds, or modulation channels, the fix is the physics — not a boolean reject or an angle gate. Stopgap levers, when they must exist, are flagged as such and retire when the underlying geometry / stiffness model catches up. Boolean rejects in particular get used everywhere a designer doesn't want to tune the physics; do not introduce them. |

---

## 2. System at a glance

```
┌──────────────────────────────────────────────────────────────────┐
│  HeroCharacter (CharacterBody3D + Skeleton3D)                   │
│  ┌──────────────────┐  ┌──────────────────────────────────┐    │
│  │ Ragdoll bones    │  │ Orifices (N per character)       │    │
│  │ + orifice rims   │  │ - rim particle loops (XPBD)      │    │
│  │ + tunnel markers │  │ - entry spline + tunnel spline   │    │
│  └────────┬─────────┘  └──────────────┬───────────────────┘    │
│           │                           │                         │
│  ┌────────┴────────────┐              │                        │
│  │ SkinBulgeDriver     │◄─────────────┤                        │
│  │ vec4 bulgers[32]    │              │                        │
│  │ (spring-damper)     │              │                        │
│  └─────────────────────┘              │                        │
└───────────────────────────────────────┼────────────────────────┘
                                        │ sampled + aggregated
┌───────────────────────────────────────┼────────────────────────┐
│  TentacleManager (autoload)           │                        │
│                                       ▼                        │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                     │
│  │Tentacle A│  │Tentacle B│  │Tentacle C│  ...                │
│  │  16–48   │  │          │  │          │                     │
│  │particles │  │          │  │          │                     │
│  │  + mesh  │  │          │  │          │                     │
│  │  + driver│  │          │  │          │                     │
│  └──────────┘  └──────────┘  └──────────┘                     │
└────────────┬───────────────────────────────────────────────────┘
             │ writes + reads
┌────────────┴───────────────────────────────────────────────────┐
│  StimulusBus (autoload)                                         │
│  ┌────────────────┐ ┌────────────────┐ ┌────────────────┐      │
│  │ Events         │ │ Continuous     │ │ Modulation     │      │
│  │ (ring buffer)  │ │ channels       │ │ channels       │      │
│  └────────────────┘ └────────────────┘ └────────────────┘      │
│        ▲▼ physics          ▲▼ consumers (many)                │
└────────────────────────────────────────────────────────────────┘
             ▲
             │ reads events/state, writes modulation
┌────────────┴───────────────────────────────────────────────────┐
│  Reverie (separate extension — reads bus, writes modulation)   │
└────────────────────────────────────────────────────────────────┘
```

Major subsystems:
1. **PBD core** — particle solver, constraints, spline math
2. **Collision** — 7 types, unified friction projection
3. **Orifice** — rim particle loops (XPBD distance + volume + spring-back), EntryInteraction, bilateral compliance, multi-tentacle, multi-loop per orifice
4. **Rendering** — GPU spline skinning, bulger uniform array, spring-damper jiggle
5. **Stimulus bus** — events, continuous channels, modulation (bidirectional)
6. **Mechanical sound** — physics-driven audio events
7. **Authoring** — procedural tentacle generator, mesh-to-girth auto-bake

---

## 3. The PBD core

### 3.1 Particle state

Per-particle, all necessary to describe a tentacle chain completely:

```cpp
struct TentacleParticle {
    Vector3 position;
    Vector3 prev_position;    // velocity is implicit: (pos - prev_pos) / dt
    float   inv_mass;         // 0 = pinned (base), 1/m otherwise
    float   girth_scale;      // scalar radial compression, 0.3..1.5 (1 = rest)
    Vector2 asymmetry;        // directional squeeze in particle's local frame
                              // (right, up); magnitude capped at 0.5
};
```

`girth_scale` and `asymmetry` are updated post-solve from segment lengths (volume preservation) and orifice ring pressures, respectively. See §3.4 and §6.3.

**Mass initialization.** Per-particle mass is set proportional to the local segment volume:

```
particle.mass = density × radius_at_arc_length² × local_segment_length
particle.inv_mass = 1.0 / particle.mass
```

A constant-mass chain produces a uniformly heavy tip that resists whipping; mass-by-volume gives the natural "thin tip whips, thick base anchors" feel for free. Pinned particles (`inv_mass = 0`) are unchanged.

### 3.2 Solver loop and iteration order

Fixed per-tick loop with prediction → iteration × N → finalization:

```
PBD tick (60 Hz):

predict:
    for each particle:
        temp_prev = prev_position
        prev_position = position
        position += (position - temp_prev) * damping + gravity * dt²
        // target-pull and any external forces applied here as position deltas

iterate (for iter in [0, iteration_count), default 4):
    1. project distance constraints       (segment length)
    2. project bending constraints        (curvature stiffness)
    3. project target-pull constraint     (behavior driver intent)
    4. project collision normals          (§4 — all 7 types)
    5. project friction (tangential)      (§4.3 — unified cone projection)
    6. project anchor constraint          (base pinning, hard)

finalize:
    for each segment: compute girth_scale from length ratio (§3.4)
    for each particle: decay asymmetry, smooth neighbors (§3.4)
    update spline data texture for rendering
    publish stimulus bus events for this tick
```

**Iteration count:** 4 default; 6 when multi-tentacle is active in an orifice. Cap at 6.

**Anchor is last** so it overrides any violation by earlier constraints.

**Friction is after collision normals** because tangential motion cannot be computed until the normal correction is known.

### 3.3 Constraints

| Constraint | Form | Stiffness range | Applied where |
|---|---|---|---|
| Distance | `\|pᵢ − pⱼ\| = rest_length` | 0.9–1.0 | Adjacent particle pairs |
| Bending | Based on angle between `(pᵢ₋₁, pᵢ)` and `(pᵢ, pᵢ₊₁)` | 0.1–0.9 | Every triple |
| Target-pull | Soft pull of specific particle toward world target | 0.05–0.3 | Tip particle, usually |
| Anchor | Hard pin to world transform | 1.0 | Base particle |
| Collision (normal) | Projection outside obstacle surface | 1.0 | Any particle in contact |
| Friction (tangential) | Cone projection on tangential displacement | Derived from coefficients | Any particle in contact |
| Attachment | Particle to external point with slip threshold | 0.8–1.0 | Grabbing tentacles |

All projection math operates on particle positions directly. No force accumulation.

**Bending — form (committed).** The bending constraint operates on the `(i, i+2)` chord — projects the displacement of `p[i+1]` away from the line `p[i]→p[i+2]` toward zero, weighted by stiffness. This is the canonical PBD bending form; do not substitute angle-based variants.

**Bending — angular-stiffness invariance under non-uniform `rest_lengths`.** When the chain has non-uniform per-pair `rest_length[i]` (§3.6), the bending correction must be scaled to keep *angular* stiffness consistent across the chain. Multiply the correction by:

```
bend_scale = 1.0 / (rest_length[i] + rest_length[i+1])
```

Without this, tip-clustered chains (short segments) become disproportionately stiff in bending compared to base segments.

### 3.4 Volume preservation and asymmetry propagation

After the iteration loop completes:

**Per-segment volume preservation:**
```
for each segment i between particles i and i+1:
    current_length = |p[i+1] - p[i]|
    stretch_ratio = current_length / rest_segment_length
    segment_girth_scale[i] = pow(1.0 / stretch_ratio, 0.5)  // √-relation preserves volume

for each particle i:
    particle[i].girth_scale = 0.5 × (segment_girth_scale[i-1] + segment_girth_scale[i])
```

**Asymmetry from orifice pressure** (computed during orifice tick, written to affected particles):
```
for each particle near an active EntryInteraction:
    for each loop l, for each rim particle k with nonzero pressure_per_loop_k[l][k]:
        direction_local = world_to_particle_frame(r.authored_radial_axis)
        particle.asymmetry -= direction_local.xy × pressure_per_loop_k[l][k] × dt × responsiveness
    
    // Elastic decay toward zero
    particle.asymmetry *= (1.0 - recovery_rate × dt)
    
    // Clamp magnitude to prevent cross-section inversion
    if length(asymmetry) > 0.5:
        asymmetry = normalize(asymmetry) × 0.5
```

**Neighbor smoothing** (one pass each tick, prevents visible discontinuities between particles):
```
for each particle i (excluding endpoints):
    girth_scale[i] = 0.5 × girth_scale[i] + 0.25 × (girth_scale[i-1] + girth_scale[i+1])
    asymmetry[i]  = 0.5 × asymmetry[i]  + 0.25 × (asymmetry[i-1]  + asymmetry[i+1])
```

Volume preservation responds to stretch. Asymmetry responds to cross-sectional squeeze. They are orthogonal and composed multiplicatively in the vertex shader.

### 3.5 Why PBD

- **Stable at large time steps.** No mass-spring explosion.
- **Uniform constraint interface.** Every collision, friction, attachment is a projection.
- **Final positions on exit.** No integration step that could violate constraints.
- **Small footprint.** Solver core is ~300–400 lines of C++.
- **Godot's `SoftBody3D` is mesh-based** and doesn't fit a 1D chain.

### 3.6 Non-uniform particle distribution

A tentacle chain may distribute its particles non-uniformly along arc-length to concentrate resolution where it's needed (typically the tip, for fine wrap fidelity). The underlying solver already accepts per-pair `rest_length`; only initialization plumbing changes.

**Init API on `Tentacle` / `PBDSolver`:**

```cpp
void initialize_chain_with_lengths(const PackedFloat32Array& rest_lengths);
// length = N - 1; sum sets total chain length.

void set_distribution_curve(const Ref<Curve>& curve);
// Convenience: derives rest_lengths from a [0..1] curve mapping
// axial_t to local segment density. Curve area is normalized to total length.
```

**Coupled changes when distribution is non-uniform:**

1. Mass-by-volume per §3.1 (otherwise short segments become low-mass islands).
2. Bending correction scaled per §3.3.
3. Spline parameterization switches to centripetal Catmull-Rom (§5.1) — uniform CR overshoots near dense knot regions.
4. Texture coordinates derived from arc-length in the shader (§5.3) so authored UVs do not stretch under varying segment length.

**Iteration count.** PBD distance-constraint convergence degrades with length disparity. For non-uniform chains with ratio > 2× between shortest and longest segment, bump the iteration count from 4 to 5–6. Wrapping-grade chains (§12) override this with their own lower-iteration profile.

Default chain remains uniform; non-uniform is opt-in per `TentacleType` profile.

---

## 4. Collision and friction

### 4.1 Particle effective radius

A particle is not a point. Its collision radius derives from the tentacle's rest girth at its arc-length, scaled by runtime deformation:

```
particle_radius(i, contact_direction) =
    rest_girth_at_arc_length(arc_length_of_i)
    × particle.girth_scale
    × asymmetry_applied(particle.asymmetry, contact_direction)
```

Where `asymmetry_applied` returns the elliptical cross-section's radius in the direction of the contact normal. For zero asymmetry, this is just 1.0 (isotropic). For maximum asymmetry (magnitude 0.5), the minor axis is 0.5× and the major axis is 1.25×.

**Every collision test in the system uses this radius.** A squeezed tentacle collides differently on its flattened axis than its perpendicular axis. This is how tentacle cross-section deformation becomes visible in contact behavior, not just as mesh wobble.

### 4.2 The seven collision types

All share the PBD projection pattern from §4.3. Different detection and different body participation.

| # | Type | Detection | Resolution | Has friction |
|---|---|---|---|---|
| 1 | Particle vs ragdoll capsule | Once-per-tick snapshot + AABB broadphase | Project outside capsule surface; apply reaction impulse to bone | Yes |
| 2 | Particle vs orifice rim | EntryInteraction geometric test | Per-direction ring bilateral compliance (§6.3) | Yes |
| 3 | Particle vs tunnel wall | Spline projection with radius tolerance | Project onto tunnel cylinder; record wall pressure | Yes |
| 4 | Particle vs environment | Per-particle sphere `get_rest_info` query, iterated up to `MAX_CONTACTS_PER_PARTICLE = 2` slots with growing exclude list (slice 4M, 2026-05-03) | Per-contact XPBD penetration projection with persistent `normal_lambda` accumulator; Jacobi+SOR position apply averages multi-contact deltas | Yes (per-contact lambda-bounded cone) |
| 5 | Particle vs tentacle particle | Spatial hash (always on inside orifices) | Push apart symmetric, half each | Yes |
| 6 | Tentacle surface vs grab target | Explicit attachment constraint with slip | Particle pinned to target with friction-limited slip | Yes |
| 7 | Tip vs closed surface (probing) | Same as #1 until orifice boundary crossed | Same as #1 | Yes |

**Type 2 (orifice rim) is not a simple particle-surface projection.** It operates through the `EntryInteraction` and rim particle loop model. See §6.

**Type 6 (attachment) is how tentacles grab limbs.** Particle is pinned to a point on a target surface (ragdoll bone, static geometry, another tentacle). Attachment holds while tangential force is within static friction cone; breaks with slip accumulation.

### 4.3 Unified PBD friction projection

After normal correction for any collision type, apply friction to tangential displacement:

```
// Normal correction already applied:
Δn = magnitude of normal projection (positive); the equivalent normal
     force is N = m × Δn / dt² (steady-state correspondence)

// Tangential displacement since last tick
Δx = particle.position - particle.prev_position
Δx_tangent = Δx - (Δx · n) × n
tangent_mag = length(Δx_tangent)

// Friction cones
μ_s = compose_static_friction(surface_pair, modulators)     // §4.4
μ_k = μ_s × kinetic_friction_ratio                          // default 0.8;
                                                            // per-tentacle export
static_cone = μ_s × Δn
kinetic_cone = μ_k × Δn

if tangent_mag <= static_cone:
    // Inside static cone: friction fully opposes the tangent motion.
    particle.position -= Δx_tangent
    friction_applied = Δx_tangent
else:
    // Kinetic regime: friction caps at μ_k × Δn — it can cancel up to
    // `kinetic_cone` of motion this iteration. Particle continues with
    // (tangent_mag − kinetic_cone) of tangential motion.
    cancel = (Δx_tangent / tangent_mag) × kinetic_cone
    particle.position -= cancel
    friction_applied = cancel
```

**This single block handles stick-slip, grip, rib modulation, and all surface interactions.** There is no state machine. The friction cone *is* the state — whether tangential motion falls inside or outside of it is computed each iteration from current values.

**Per-iteration semantics.** Friction projects every PBD iteration. In *naturally-resolved* contacts (gravity holds the chain to a floor) iter 1's collision push leaves Δn ≈ 0 in iters 2–4, so per-tick cancellation tapers to ~1× `kinetic_cone` automatically — `Δx` is measured from `prev_position` so iter 1 already canceled what it could against the start-of-tick reference. In *actively-driven* contacts (a pose target continuously pushing the chain into a wall) the depth re-accumulates each iter and friction can stack to `iter_count × kinetic_cone` per tick — a ~4× over-friction worst case at default `iter_count = 4`. Acceptable for now; a per-tick friction budget on `TentacleParticle` (reset in `predict()`, decremented per friction projection) is the proper fix when specific scenarios force it. See `Cosmic_Bliss_Update_2026-05-02_phase4_friction_correction.md`.

**Per-contact lambda-bounded cone (slice 4M, 2026-05-03).** The block above is the original tightly-coupled-to-Δn form. The shipping implementation lifts from Obi `ContactHandling.cginc::SolveFriction`: each environment contact slot maintains a persistent `normal_lambda` accumulator (`max(λ + dlambda, 0)` clamped, where `dlambda` comes from XPBD-style penetration projection) that survives across iterations within an outer tick. Friction cones are sized by *that contact's* accumulated normal impulse (`static_cone = μ_s × normal_lambda`, `kinetic_cone = μ_k × normal_lambda` in m·kg units), not the per-iter Δn. The "4× over-friction worst case" the original form had under repeated iterations is gone — `normal_lambda` can only grow during the iter loop (clamped to ≥ 0), so subsequent iters see the same or larger cone, never an inflated copy. Multi-contact friction is per-slot — a particle in two contacts gets two friction projections, position deltas Jacobi-averaged via SOR. Per-slot `friction_applied` is unaveraged so the type-1 reciprocal pass routes each slot's share to its own colliding body (a particle rubbing against two surfaces correctly produces full reciprocal impulse on each). See `Cosmic_Bliss_Update_2026-05-03_phase4_wedge_robustness.md` for the full reshape and `pbd_research/findings_obi_synthesis.md` for the source-level synthesis. **Spec divergence flagged in CLAUDE.md status row:** the cone is scalar 1D (along current `dx_tan_dir`), not Obi's tangent/bitangent pyramid — acceptable for a 1D chain where tangent motion is dominated by the chord direction.

For each friction projection on a type-1 collision, the friction displacement is also applied as an equal-and-opposite impulse on the contacted ragdoll bone:

```
impulse_friction = friction_applied × effective_mass / dt
bone.apply_impulse_at_position(impulse_friction, contact_point)
```

Δn is the just-applied normal correction in position units; the equivalent normal force is `N = m × Δn / dt²`. The friction reciprocal impulse `J = friction_applied × m / dt` therefore evaluates to `μ_k × N × dt` — the kinetic-friction impulse over `dt`. A `body_impulse_scale` multiplier (default 1.0) on the `Tentacle` lets designers tune per-tentacle for "feels heavier than physics" or "feels lighter".

Heavy tentacle dragging across skin pulls the hero's skin (and the bone under it) in the drag direction. This is where the "tentacle friction makes the hero move" feel comes from.

**Soft distance stiffness during contact.** Per-pair distance constraint stiffness drops from `1.0` to a tunable `contact_stiffness` (default `0.5`) for any segment whose either endpoint is in active collision contact this tick. The chain stretches *temporarily* over wrapped geometry, springing back when contact ends. Cheaper and more stable than full length-redistribution.

```
for each distance constraint between particles a, b:
    stiffness = (a.in_contact_this_tick || b.in_contact_this_tick)
        ? contact_stiffness
        : base_stiffness
    project_distance_constraint(a, b, rest_length[i], stiffness)
```

**Tuning interaction.** Per-iteration stiffness compounds across iterations within a single tick: effective single-tick stiffness ≈ `1 - (1 - stiffness)^iter_count`. So `contact_stiffness = 0.5` at 4 iterations gives ≈ 0.94 effective — most of the *visible* stretch comes from across-tick relaxation against collision push-back, not from a single tick's compounded projection. Tune `contact_stiffness` and `iteration_count` together; do not tune in isolation.

**Length-redistribution / elastic-budget ("S-curve length storage")** is explicitly deferred. Re-evaluate only if soft stiffness alone produces visible slack.

**Type-2 friction reciprocal routing.** The type-1 path above applies the friction displacement as an equal-and-opposite impulse on the contacted ragdoll bone. **Type-2 (particle vs orifice rim) is different.** The contact is with a rim particle (PBD-driven, attached to host_bone via the orifice frame), not a ragdoll bone — so the type-1 rule cannot be reused. Type-2 friction reciprocals are summed per rim particle onto `EI.tangential_friction_per_loop_k[l][k]` (§6.2) and routed to the orifice's `host_bone` by the §6.3 reaction-on-host-bone pass — not applied directly per-particle. This avoids double-routing and keeps the host-bone reaction self-consistent with the radial and axial-wedge components computed at the same place.

```
// Inside §4.3 friction projection, after computing friction_applied for
// a particle currently in type-2 contact at ring direction d:
if contact_type == TYPE_2:
    // Project friction_applied onto the tentacle tangent at the ring,
    // accumulate scalar magnitude per direction. §6.3 takes it from there.
    t_hat = evaluate_tentacle_tangent(EI.tentacle, ring.arc_length)
    EI.tangential_friction_per_loop_k[l][k] += dot(friction_applied, t_hat) * effective_mass / dt
    // Do NOT call bone.apply_impulse_at_position here — handled by §6.3.
else if contact_type == TYPE_1:
    // Existing canonical behavior (above): route reciprocal to ragdoll bone directly.
    bone.apply_impulse_at_position(impulse_friction, contact_point)
```

`tangential_friction_per_loop_k` is cleared at the start of each PBD tick alongside other per-tick `EntryInteraction` state.

### 4.4 Friction coefficient composition

```
μ_s = base_friction_pair(tentacle_surface, contact_surface)
μ_s *= (1.0 - tentacle.lubricity)
μ_s *= (1.0 - contact.wetness)
μ_s *= rib_modulation(tentacle, arc_length_at_contact)  // sinusoidal for ribbed
μ_s *= grip_modulation(orifice, grip_engagement)        // × (1 + engagement × multiplier)
μ_s *= anisotropy_factor(surface, tangent_direction)    // for scaled/directional surfaces
μ_s += adhesion_bonus(tentacle_surface, contact_surface) // sticky tentacles
μ_s = clamp(μ_s, 0.0, 4.0)
```

**Rib modulation** on ribbed tentacles:
```
phase = arc_length × tentacle.rib_frequency
rib_modulation = 1.0 + tentacle.rib_depth × sin(phase × 2π)
```

Ribs produce stick-slip *automatically* because the oscillating coefficient causes the tangential displacement to alternate inside/outside the static cone. No special code.

**Barbed surfaces** (asymmetric friction):
```
if BARBED:
    direction = sign(Δx · tentacle_axis_at_contact)
    if retracting: μ_s *= 3.0
    else:          μ_s *= 0.7
```

**Base friction coefficients** by surface pair:

| Tentacle ↓ / Contact → | Skin dry | Skin wet | Mucosa | Bone | Cloth |
|---|---|---|---|---|---|
| Smooth | 0.4 | 0.15 | 0.2 | 0.5 | 0.6 |
| Ribbed | 0.7 | 0.3 | 0.4 | 0.8 | 0.9 |
| Barbed | 0.9 | 0.5 | 0.7 | 1.1 | 1.5 |
| Sticky | 0.6 +adh 0.4 | 0.4 +adh 0.2 | 0.5 +adh 0.3 | 0.7 +adh 0.4 | 0.8 +adh 0.5 |

### 4.5 Once-per-tick ragdoll snapshot

**The single most important performance rule.** Before the PBD iteration loop:

```
ragdoll_snapshot = []
for each PhysicalBone3D in the hero's skeleton:
    capsule_a_world = bone.global_transform × capsule.endpoint_a
    capsule_b_world = bone.global_transform × capsule.endpoint_b
    ragdoll_snapshot.append({
        a: capsule_a_world,
        b: capsule_b_world,
        radius: capsule.radius,
        bone_ref: bone,
        surface_material: bone.surface_material
    })
```

During PBD iterations, type-1 collision reads from this array. **Never query `PhysicalBone3D.global_transform` inside the iteration loop** — it triggers physics-server synchronization and destroys performance.

### 4.6 Wetness accumulation from external friction

As tentacles rub the hero's external skin (type-1 contacts), nearby orifices accumulate wetness:

```
for each friction contact per tick:
    friction_energy = μ_k × Δn × |Δx_tangent|
    for each orifice o within wetness_propagation_radius of the contact:
        o.wetness += friction_energy × wetness_accumulation_rate
        o.wetness = min(o.wetness, max_wetness)
```

External stimulation → linked orifices become wetter → subsequent entry is easier. This is a gameplay-feel mechanism, set `wetness_accumulation_rate = 0` to disable.

---

## 5. Spline and mesh deformation

### 5.0 Layer responsibilities (partition rule)

A single invariant governs the mesh / vertex shader / fragment shader split. Any new feature is tagged against this rule before being scoped:

| Layer | Owns |
|---|---|
| **Mesh** (`TentacleMesh` resource, §10.2) | Silhouette and radial-profile changes — suckers, knots, ribs, fins, spines, mouth, tip variants. **Plus** the vertex-color / vertex-attribute masks driving sub-silhouette detail. |
| **Vertex shader** (§5.3) | Only physics-driven deformation — spline curve, `girth_scale`, asymmetry. Never adds vertices, never punches holes, never moves authored features. The mesh is its input; the PBD solver is its driver. |
| **Fragment shader** | Sub-silhouette surface detail — papillae bumps via normal map / parallax, emissive photophores, wetness, sheen variation. Reads the masks the mesh authored. |

**Stated as one rule:** the mesh decides silhouette and authors masks; the fragment shader interprets masks; the vertex shader only deforms — never customizes. Any feature proposal must say which layer owns it before being approved.

Sub-silhouette detail (papillae, scales, micro-warts) is shader-only — the polygon cost of expressing it as geometry is wasted on shapes the silhouette never reveals. Suckers, knots, ribs, fins are silhouette-defining and live in the mesh.

### 5.1 CatmullSpline

Generic primitive (to be built in Phase 1 by scavenging DPG's math). Pure math, independent of TentacleTech-specific types.

API:
```cpp
class CatmullSpline {
    void build_from_points(const PackedVector3Array& points);
    Vector3 evaluate_position(float t) const;
    Vector3 evaluate_tangent(float t) const;
    void    evaluate_frame(float t, Vector3& out_tangent, Vector3& out_normal, Vector3& out_binormal) const;
    float   get_arc_length() const;
    float   parameter_to_distance(float t) const;  // via distance LUT
    float   distance_to_parameter(float d) const;  // binary search in LUT
    void    build_distance_lut(int sample_count);
    void    build_binormal_lut(int sample_count);  // parallel transport, not Frenet
};
```

**Parallel transport binormals** (not Frenet) are critical — Frenet frames twist at inflection points; parallel transport stays smooth. Use for rendering and for tunnel projection.

**Parameterization.** The spline supports α-parameterization:

- `α = 0.0` — uniform (existing default; correct for evenly-spaced control points).
- `α = 0.5` — centripetal (required when control points are non-uniformly spaced; eliminates overshoot loops near dense regions).
- `α = 1.0` — chordal.

Default to centripetal when the source chain has non-uniform `rest_lengths` (§3.6); otherwise uniform stays canonical for performance.

```cpp
void set_parameterization(float alpha);   // 0.0 / 0.5 / 1.0
```

### 5.2 GPU data texture encoding

Godot spatial shaders do not support SSBOs. Spline data is encoded into an `RGBA32F` texture and sampled with `texelFetch`:

```
Data to pack per tentacle:
- point count, arc length (2 floats)
- weight array: precomputed a, b, c, d for each segment (16 segments × 4 points × 4 coefs = 256 floats)
- distance LUT (64 floats)
- binormal LUT (64 × 3 = 192 floats)
- per-particle girth_scale (48 floats max)
- per-particle asymmetry (48 × 2 = 96 floats max)

Total: ~660 floats → 165 RGBA32F pixels, texture is 165×1
```

Packed once per frame in C++; written to `ImageTexture` via `Image.create` + `ImageTexture.update`. Sampled per-vertex in the shader.

`SplineDataPacker` utility class handles packing/unpacking generically — accepts a spline plus arbitrary per-point scalar arrays, produces the texture.

### 5.3 Vertex shader deformation stack

Three multiplicative layers, in order:

```glsl
// Given: vertex.rest_position in tentacle-local straight space
// (Z = arc-length, XY = lateral offset from centerline)

float arc_length = vertex.rest_position.z;
float t = arc_length / tentacle_length;

// Layer 1: rest girth (already baked into vertex positions from mesh geometry)
vec2 lateral = vertex.rest_position.xy;
// No explicit rest_girth multiply — it's in the mesh already

// Layer 2: per-particle girth_scale (interpolated)
float scale = interpolate_particle_girth_scale(t);
lateral *= scale;

// Layer 3: asymmetric squeeze
vec2 asym = interpolate_particle_asymmetry(t);
if (length(asym) > 0.001) {
    vec2 axis = normalize(asym);
    float mag = length(asym);
    float along  = dot(lateral, axis);
    float across = dot(lateral, vec2(-axis.y, axis.x));
    along  *= (1.0 - mag);
    across *= (1.0 + mag * 0.5);
    lateral = axis * along + vec2(-axis.y, axis.x) * across;
}

// Place in spline frame
vec3 spline_pos = evaluate_spline_position(arc_length);
vec3 n, b;
evaluate_spline_frame(arc_length, n, b);

VERTEX = spline_pos + n * lateral.x + b * lateral.y;
// NORMAL transforms similarly
```

**Arc-length-driven V coordinate.** The vertex shader computes the vertex's current arc-length-along-the-spline from the spline data texture's distance LUT, normalizes by total current arc length, and uses the result as the V texture coordinate. The mesh's baked V is interpreted only as a *ring-index reference*, not a final UV.

```glsl
float current_arc_length_at_vertex = arclen_lookup(vertex.rest_position.z);
float current_total_arc_length     = arclen_total();
vec2  uv_remapped = vec2(UV.x, current_arc_length_at_vertex / current_total_arc_length);
```

**Dependency.** Assumes `vertex.rest_position.z == rest_arc_length` for that vertex's ring. The procedural generator and Blender pipeline (§10.1) guarantee this by construction (mesh aligned along +Z, V = arc-length). A future curved-rest-pose authoring path would silently break this assumption — revisit if added.

**Decoupling.** This decouples authored / detail textures from per-segment-length variation introduced by §3.6 (non-uniform distribution) and §4.3 (soft contact stretch). Cost: one small partial sum per vertex; sub-microsecond at typical ring counts.

**Fully procedural materials** (noise, distance fields, polar coordinates) drive off the same arc-length output and never need a baked UV.

### 5.4 Auto-baked girth (no manual profile authoring)

The rest girth is **baked from mesh geometry automatically.** No `Curve` resource needed. The process:

1. After mesh import or procedural generation, iterate over the mesh vertices
2. For each ring of vertices (grouped by arc-length), compute max radial extent
3. Output a 1D texture (256 samples typical) of `radial_extent(arc_length)`
4. This texture is read by the physics code when it needs "girth at arc-length t" — for example, when computing EntryInteraction compression

The mesh's geometric detail (knots, ripples, bulbs) determines the girth profile implicitly. Physics and rendering are consistent because both derive from the same mesh.

**Procedural generator** (GDScript) outputs both mesh and bakes the girth texture in one step — see `TentacleMesh` in §10.2. **Blender-imported** meshes have the bake run automatically at resource load time by a small helper class.

Surface detail (ribbing, veins, scales) is mesh geometry — rides along with the lateral XY offsets and is scaled by the runtime `girth_scale` and asymmetry. No detail texture needed; concavities and full 3D surface features work naturally. Sub-silhouette detail (papillae, photophores, wetness) lives in the fragment shader, masked by vertex color authored on the mesh — see §5.0.

**Runtime regeneration policy.** Default workflow is **edit-time bake** to a `.tres` `ArrayMesh` (or to the `TentacleMesh` resource cache); shipping gameplay loads the static result. Runtime regeneration is *supported* (the `PrimitiveMesh`-style auto-rebuild path on property change works) but *not relied on for gameplay* — physics-driven motion is the spline shader's job, not mesh re-bake. Use cases for runtime mutation are limited to dev tooling, livecoding, and edit-time inspector dragging.

---

## 6. Orifice system

### 6.1 Rim structure

> **Amended 2026-05-03** (was: "Ring bone structure"). Replaced the
> driven-kinematic 8-direction ring-bone model with a closed-loop
> rim of N PBD particles per loop, multi-loop per orifice supported.
> Rationale + full diff: `docs/Cosmic_Bliss_Update_2026-05-03_orifice_rim_model.md`.
> See `docs/Cosmic_Bliss_Update_2026-05-03_obi_realism_and_orifice.md`
> for the analytical context (Obi `VolumeConstraints.compute` +
> `PinholeConstraints.compute` adoption).

Per orifice on the hero, the rim is an edge loop of the continuous hero mesh at the point where the surface invaginates. **Rim anchor bones** are authored in Blender along this rim loop (not generated in Godot) and ship with the hero GLB. The rim is a single edge loop shared between the skin surface and the mucosa surface of the same mesh; skinning weights on that loop follow the rim anchors, so rim motion deforms skin and mucosa together at the rim.

```
<host_deform_bone>                        (parent — pelvis/hip for pelvic orifices, jaw for oral)
└── <Prefix>_Center                       (transform anchor; use_deform = False; no weights)
    ├── <Prefix>_RimAnchor_0              (deform bones; arc-length-regular along rim;
    ├── <Prefix>_RimAnchor_1               authored rest positions for the rim particles)
    ...
    └── <Prefix>_RimAnchor_{N-1}
```

**Rim anchors are kinematic targets, not driven outputs.** Runtime does **not** write to anchor positions. Each orifice owns one or more **rim particle loops** (PBD-driven) whose particles' rest positions are the anchor offsets in Center frame; XPBD spring-back constraints pull particles toward those rest positions each tick. The visible mesh skin tracks the live rim particle positions (skin weights remain bound to anchor names; the skinning shader uses live particle positions in place of anchor world transforms — see §10.4 for the binding mechanism).

**Per-loop particle count is variable.** N is per-loop, set by `OrificeProfile.rim_loops[i].particle_count`. Typical defaults: 8 for symmetrical openings, 12-16 for irregular shapes (slits, star profiles), 4-6 for tight openings (urethra, decorative pinholes). Logic must be N-agnostic.

**Placement is arc-length-regular along the rim loop, not angular-regular at `i × 360/N`.** Rim loops are rarely circular — a jaw opening, a vulva, a sphincter are all irregular — and even arc-length spacing keeps skin-deform quality uniform around the opening. Each anchor's authored offset from `<Prefix>_Center` is its rim particle's rest position in Center frame. Physics never assumes angular regularity.

**Local frame**, consistent across every rim anchor on every orifice (set by the Blender authoring script):
- **Y** — radial outward (from Center toward the rim).
- **Z** — along the opening axis (outward from the cavity).
- **X** — tangent along the rim loop.

Skin around the opening is weight-painted (also in Blender) to the rim anchors with angular interpolation between the two bracketing anchors and radial falloff outward. See §10.4 for the Godot-side import workflow and §10.6 for the full Blender → Godot authoring pipeline.

**Multi-loop support.** An orifice can own multiple rim loops, each a fully independent particle loop with its own constraints. Loop 0 is the canonical "primary rim" used by EntryInteraction geometry checks (entry plane, tunnel projection); additional loops are visual / secondary contact surfaces. Common configurations:

- **Single loop** (default): one rim loop, simple orifice.
- **Outer + inner loop** (anatomical): an outer "lip" loop with low stiffness and a larger rest radius, an inner "opening" loop with higher stiffness and the actual passage radius. Inter-loop coupling springs (per-particle pairs, soft) make them deform somewhat together while preserving differential stiffness.
- **Decorated rim** (jewelry, prosthetic): inner loop is the anatomical opening; outer loop is jewelry geometry with very high stiffness (rim deforms freely, jewelry barely moves).
- **Compound openings** (ribbed canal, multiple sphincters along a single tunnel): a sequence of loops along the tunnel axis, each with its own rest radius and contraction modulation. Used for peristalsis (§6.7 through-path tunnels) — each loop is one contractile ring along the tunnel.

Inter-loop coupling, when present, is a per-particle XPBD soft pull between corresponding particles in adjacent loops. Stiffness is authored per-pair; zero coupling means loops are visually adjacent but mechanically independent.

### 6.2 EntryInteraction and persistent state

Every active tentacle-orifice contact is represented by an `EntryInteraction`. Multiple interactions can be active per orifice simultaneously (§6.5).

```cpp
struct EntryInteraction {
    // Identity
    Tentacle*  tentacle;
    Orifice*   orifice;

    // Geometric (recomputed each tick)
    float      arc_length_at_entry;
    Vector3    entry_point;
    Vector3    entry_axis;
    Vector3    center_offset_in_orifice;  // tentacle offset from orifice center
    float      approach_angle_cos;
    float      tentacle_girth_here;
    Vector2    tentacle_asymmetry_here;
    float      penetration_depth;         // arc-length of tentacle inside
    float      axial_velocity;

    // Per-rim-particle state. Indexed [loop_index][particle_index].
    // Sized to orifice.rim_loops[l].particle_count per loop. Per-loop
    // arrays of per-particle data — outer index is loop, inner is k.
    // (Was `_per_ring[r]` indexed by ring direction in the pre-2026-05-03
    // model; see Cosmic_Bliss_Update_2026-05-03_orifice_rim_model.md.)
    Vector<Vector<float>>  orifice_radius_per_loop_k;
    Vector<Vector<float>>  orifice_radius_velocity_per_loop_k;

    // Persistent state (hysteretic — reason the interaction object exists)
    float      grip_engagement;           // 0..1 ramps over time
    bool       in_stick_phase;            // friction state machine
    Vector<Vector<float>>  damage_accumulated_per_loop_k;

    // Forces computed this tick — per rim particle, summed across loops
    Vector<Vector<float>>  radial_pressure_per_loop_k;
    float      axial_friction_force;
    Vector3    reaction_on_ragdoll;

    // Per-tentacle one-shot ejection (added 2026-04-27).
    // PBD prev_position kick along entry_axis; decays to zero quickly.
    float      ejection_velocity = 0.0;       // m/s, positive = expel outward
    float      ejection_decay    = 12.0;      // 1/s

    // Cached "is in tunnel" classification, computed once per tick at the
    // EI update step. Read by ejection_velocity application, peristalsis
    // application, and any other per-tunnel-particle pass.
    PackedInt32Array particles_in_tunnel;

    // Per-rim-particle tangential friction at the rim. (Was
    // `tangential_friction_per_dir[8]` in the pre-2026-05-03 model;
    // see orifice_rim_model amendment doc.) Indexed [loop_index][k].
    // Populated by §4.3 type-2 friction projection — summed per rim
    // particle across all tentacle particles in type-2 contact at that
    // rim particle this tick. Read by §6.3 reaction-on-host-bone, which
    // routes the friction reciprocal to host_bone (NOT to a ragdoll
    // bone — type-1 routing rule does not apply to type-2 contacts).
    // Cleared at the start of each PBD tick.
    Vector<Vector<float>>  tangential_friction_per_loop_k;
};
```

Per-tick application after the PBD step (ejection):

```
if EI.ejection_velocity > 0.0:
    for each particle index i in EI.particles_in_tunnel:
        tentacle.particles[i].prev_position -= EI.entry_axis * EI.ejection_velocity * dt
    EI.ejection_velocity *= (1.0 - EI.ejection_decay * dt)
```

Used by `RefusalSpasmPattern` and `PainExpulsionPattern` emitters (§6.10) to eject one tentacle without disturbing others sharing the orifice.

Lifecycle:
```
each tick:
    orifice finds all tentacles whose spline crosses its entry plane
    for each pairing:
        if EntryInteraction exists → reuse (preserves hysteretic state)
        else → create new, grip_engagement = 0
    update geometric state for each
    compute forces (§6.3)
    apply forces to tentacle particles, rim particles, ragdoll
    if tentacle withdrew completely → mark for retirement after grace period
```

### 6.3 Bilateral compliance

> **Amended 2026-05-03**. Per-direction spring-damper allocation
> replaced by XPBD constraints on the rim particle loop. Bilateral
> compliance is now an emergent property of per-particle stiffness ×
> volume constraint compliance × distance constraint compliance.

Each orifice runs the following per tick, for each of its rim loops, after the tentacle PBD step has produced the per-rim-particle pressure values via type-2 collision projection (§4.2):

```
for each loop l in orifice.rim_loops:
    rim = l.rim_particles
    N = rim.length

    // Per-particle pressure from tentacle-rim contact. Computed by
    // type-2 collision projection during PBD iterations (§4.2);
    // EntryInteraction reads the result.
    for each rim particle k in [0..N-1]:
        // Type-2 projection moves rim particle k away from any
        // tentacle particle within collision radius. The XPBD lambda
        // accumulated by that projection is the "pressure" — same
        // units across radial / friction / wedge force terms.
        pressure_per_loop_k[l][k] = max(0, type_2_projection_lambda[l][k])

    // Volume constraint (Obi VolumeConstraints pattern). The enclosed
    // polygon area is pulled toward target_enclosed_area each iteration.
    // Active contraction modulates the target. This is the bulk
    // anatomical-tissue-resists-displacement mechanism.
    current_area = polygon_area_of_loop(rim, projected_to_perp_plane)
    area_constraint = current_area - l.target_enclosed_area
    apply_xpbd_volume_constraint(rim, area_constraint, l.area_compliance, dt)

    // Distance constraints around the loop (closed). Standard XPBD
    // distance per pair (rim[k], rim[(k+1) % N]).
    for each pair (k, k+1) cyclic:
        apply_xpbd_distance_constraint(
            rim[k], rim[(k+1) % N],
            l.rim_segment_rest_lengths[k], l.distance_compliance, dt)

    // Per-particle spring-back to authored rest position in Center frame.
    // Bilateral compliance is the per-particle stiffness distribution
    // (front vs back, dorsal vs ventral, etc.).
    for each rim particle k:
        rest_world = orifice.Center.global_transform * rim[k].rest_position_in_center_frame
        compliance = stiffness_to_compliance(l.rim_particle_rest_stiffness_per_k[k])
        apply_xpbd_spring_constraint(rim[k], rest_world, compliance, dt)

    // Inter-loop coupling (if any). Per-particle XPBD soft pull
    // between rim[l][k] and rim[l_other][k_other], pairing authored
    // in the loop's `coupling_pairs` table. Used for outer+inner
    // anatomical loops and for jewelry-on-anatomical configurations.
    for each (k1, l_other, k2, compliance) in l.coupling_pairs:
        apply_xpbd_distance_constraint(
            rim[k1], orifice.rim_loops[l_other].rim_particles[k2],
            authored_rest, compliance, dt)
```

A rigid tentacle against a soft orifice: orifice stretches a lot (rim particles displace far from rest, volume constraint allows the area expansion via low compliance), tentacle barely compresses. Soft tentacle against rigid orifice: tentacle flattens (asymmetry write under §3.4), orifice barely stretches (rim particle stiffness clamps displacement). Same constraint set.

**Reaction force on the orifice's host bone.** Each direction transmits its compression and friction back to the deform bone the orifice's `Center` is parented to. Without this step, a knot deforms the rim visually but does not transmit hero weight into the chain — i.e., suspension is not physically realized.

Let `host_bone = orifice.Center.parent_ragdoll_bone` (per §6.1 hierarchy).

```
for each loop l, for each rim particle k in [0..N_l-1]:
    p              = pressure_per_loop_k[l][k]                 // ≥ 0 from §4.2 type-2 projection
    if p == 0: continue
    contact_pos    = rim[k].position
    dir_outward    = normalize_in_perp_plane(rim[k].position - orifice.Center.position)
    s_intrinsic    = EI.arc_length_at_entry + r_offset_along_axis_at_k

    // Radial reaction: rim pushes back along its own outward axis
    radial_force_on_host = -dir_outward * p

    // Axial wedge — surface-normal tilt at this rim particle's arc-length.
    // dr/ds is taken with respect to distance traveled along +entry_axis
    // (outward) at the contact, NOT along the tentacle's intrinsic arc-length.
    // The intrinsic gradient is converted by the sign of the tangent's
    // projection on entry_axis: a tentacle threading inward (tangent ·
    // entry_axis < 0 — the typical suspension geometry) flips the sign.
    drds_intrinsic = signed_girth_gradient_at_arc_length(EI.tentacle, s_intrinsic)
    t_hat          = evaluate_tentacle_tangent(EI.tentacle, s_intrinsic)
    drds_outward   = drds_intrinsic * sign(dot(t_hat, orifice.entry_axis))
    norm           = sqrt(1.0 + drds_outward * drds_outward)
    axial_hold     = -p * drds_outward / norm
    axial_force_on_host = orifice.entry_axis * axial_hold
    // Sign convention (numerically verified; see "Wedge sign sanity" test):
    //   drds_outward > 0  (knot apex on the cavity-EXTERIOR side of this
    //                      ring contact — knot mid-thrust into cavity, leading
    //                      flange wedging the rim):
    //                      axial force on host is INTO CAVITY. Engulfment-assist.
    //   drds_outward < 0  (knot apex on the cavity-INTERIOR side of this
    //                      ring contact — knot lodged inside, rim sitting on
    //                      the knot's exterior-facing slope):
    //                      axial force on host is TOWARD EXIT. This is the
    //                      suspension-holding direction — host pulled toward
    //                      anchor side, transmitting hero weight up the chain.

    // Friction-tangential along the tentacle axis at this rim particle.
    // tangential_friction_per_loop_k[l][k] is populated by §4.3 type-2
    // routing (a scalar magnitude); convert to vector by multiplying by
    // t_hat.
    friction_force_on_host = -t_hat * EI.tangential_friction_per_loop_k[l][k]

    total = radial_force_on_host + axial_force_on_host + friction_force_on_host
    host_bone.apply_impulse_at_position(total * dt, contact_pos)

    EI.reaction_on_ragdoll += total
```

**Why the normalized form, and why not `tan`.** The axial component of a normal force on a surface with axial gradient is `pressure × sin(θ)` where `tan(θ) = drds_outward`. The expression `-p × drds_outward / sqrt(1 + drds_outward²)` is exactly `-p × sin(θ)` — bounded by `p` at the limit (a vertical flange, where `sin → 1` while `tan → ∞`). Earlier drafts using `tan(local_taper)` blew up at the very geometry the system most needs to handle correctly. Earlier drafts using the unnormalized linearization `-p × drds_outward` are fine for shallow slopes (≤ ~30° taper) but degrade past that.

**Where force returns to the tentacle (case-by-case).** §6.3's bilateral compliance writes per-rim-particle position deltas (via the XPBD constraint set) and an asymmetry delta on near tentacle particles. The asymmetry write is a **shape-parameter modification** — it alters effective radius for subsequent collision queries, but does **not** push particles. Force feedback into the chain comes from elsewhere, and the path differs by case:

- **Knot inside rim** (`drds_outward < 0` at the rim contact, knot apex on the cavity-interior side): the chain receives force via **type-2 collision projection** during PBD iterations — knot particles geometrically inside the rim particle loop (§6.4) are projected back outside it (§4.2 type-2 path), and the loop pushes back via its XPBD constraint set. Tangential motion is then capped by the friction projection (§4.3). Both are real position corrections. This is the canonical suspension-holding path.
- **Smooth shaft inside rim** (`drds_outward ≈ 0`, no knot, no taper): the wedge-axial term vanishes; radial projection is small, often within hysteresis. Hold is **purely friction at the rim** along the shaft direction (§4.3). Suspension on a smooth shaft is therefore friction-limited — see §14 gotcha and the "Smooth-shaft suspension fails" test.
- **Knot mid-thrust into cavity** (`drds_outward > 0`, leading flange wedging the rim from outside): wedge axial force on the host is INTO CAVITY — the rim is dragged inward as the knot pushes through. This is engulfment-assist, not suspension. Friction direction depends on the tentacle's instantaneous axial velocity.

The reaction-on-host-bone step closes the third-law loop on the **rim side**; the tentacle side is unchanged and runs through existing collision + friction projections.

**Terminology.** All per-rim-particle quantities use `_per_loop_k[l][k]` — canonical, established in §6.2 after the 2026-05-03 amendment. `pressure_per_dir[d]`, `pressure_per_ring[r]`, and similar earlier-draft indexing schemes are retired; do not reintroduce them.

**Damage degrades grip gradually.** Effective grip strength decays via `smoothstep` against accumulated damage:

```
dmg_t = clamp(EI.damage_accumulated_total / damage_failure_threshold, 0, 1)
effective_grip_strength = base_grip_strength
    × mod.grip_strength_mult
    × (1.0 - smoothstep(0.0, 1.0, dmg_t))
```

Smoothstep, not linear: linear gives a derivative discontinuity at the threshold (visible as a sudden cliff to zero). Smoothstep tails off gracefully.

Sustained suspension or prolonged grip raises damage; grip slips well before the orifice "fails." `damage_failure_threshold` is per-orifice; default `1.0` arbitrary unit, scaled by per-tick damage rate.

`OrificeDamaged` is a **continuous channel** (already in §8.1), not an event — don't emit per-tick events for accumulated damage.

Emit one-shot `GripBroke` when `effective_grip_strength` first crosses below `0.1`. **Hysteresis:** do not re-emit until `effective_grip_strength` has recovered above `0.2` and crossed `0.1` again. Prevents flutter at the threshold.

### 6.4 Rim particle dynamics

> **Amended 2026-05-03** (was: "Spring-damper ring dynamics"). The
> separate spring-damper-on-target-radius layer is gone. Rim radial
> extent now emerges from the XPBD constraint balance described in
> §6.3 — distance constraints around the loop + volume constraint on
> the enclosed area + per-particle spring-back to authored rest
> position + type-2 collision projection. Pull-out jiggle, retention,
> and wobble fall out of the same constraint set; tuning is per-loop
> (compliance values + global solver damping) instead of per-orifice
> ring spring/damping.

**Per-loop tunables:**
- `area_compliance` (`1e-9..1e-3`): how rigidly the loop preserves
  enclosed area. Low → near-incompressible (anatomical baseline).
  High → loop can collapse / expand freely (jewelry-thin rim).
- `distance_compliance` (`1e-9..1e-3`): how rigidly the rim
  circumference is preserved. Low → rim can't stretch
  circumferentially (taut). High → rim can stretch like a rubber
  band.
- `rim_particle_rest_stiffness_per_k[N]`: per-particle stiffness of
  the spring-back to authored rest position. Bilateral compliance is
  this distribution — front-of-mouth tighter than back-of-mouth, etc.
- `target_enclosed_area`: active-contraction modulation channel. A
  ContractionPulse (§6.10) writes a time-varying delta here.
- Inter-loop coupling springs (multi-loop only): per-pair compliance
  authored in `coupling_pairs`.

**Where pull-out jiggle, retention, and wobble come from:**
- Fast retraction → tentacle particle no longer pushes the rim
  particles → distance + volume + spring-back constraints pull the
  loop back toward its rest configuration → loop overshoots slightly
  due to integrated momentum → damped oscillation (governed by
  global solver damping + compliance values). Same emergent visual,
  no separate per-target spring-damper.
- Thick bulge inside → bulge particles push rim particles outward
  via type-2 projection → rim resists via volume + distance + spring-
  back → §6.3 reaction-on-host-bone transmits hold force.

**Three Phase 5 realism sub-slices** (approved 2026-05-03, lands
alongside the rim model implementation; see
`Cosmic_Bliss_Update_2026-05-03_obi_realism_and_orifice.md` §4 for
the rationale and inventory of all ten realism properties):

**4P-A — Anisotropic flesh stiffness.** Rim segment distance
constraints become **one-sided XPBD** (Obi tether pattern from
`pbd_research/Obi/Resources/Compute/TetherConstraints.compute`):
they resist *compression* strongly (rim can't collapse below
authored circumference) but allow modest *stretch* under load.
The bulk anatomical "tissue is incompressible but compliant
under tension" behavior emerges. Bulgers (§7) handle the
displaced volume on the compressed side. Per-loop knob to
disable for cases where two-sided distance is preferred (e.g.
jewelry rim).

**4P-B — Strain-stiffening (J-curve).** Real anatomical tissue
has a J-curve stiffness response: easy to deform a little, much
harder to deform a lot (collagen strain stiffening). The
per-particle spring-back compliance becomes strain-dependent:
`compliance(strain) = base_compliance / (1 + alpha × strain² +
beta × strain⁴)`. Cheap once the rim is a particle loop —
strain is `||rim[k].position - rest_pos||`, J-curve coefficients
are per-loop tunables.

**4P-C — Orifice memory (slow rest-position recovery).** Per-
particle rest positions lerp slowly back to neutral after
displacement: `rest_pos = lerp(rest_pos, neutral_pos,
recovery_rate × dt)`. ~5 LOC in the orifice tick. Required for
"orifice remembers" in Scenarios 3 and 7 (asymmetric stretch
persists across attempts but recovers over seconds-to-minutes).
Per-orifice `recovery_rate`; default 0.05/s (~20s recovery time
constant).

### 6.5 Multi-tentacle support

An orifice holds a list of `EntryInteraction`s, not just one. Aggregation iterates over the orifice's authored rings; each ring's radial axis is its authored local Y in Center space (§6.1), not an indexed angular slot:

```
// Aggregate demand over all active interactions, per authored ring.
for each ring r in orifice.rings:
    dir_r = r.authored_radial_axis
    target_radius[r] = 0
    for each EntryInteraction in orifice.active_interactions:
        tentacle_girth = EI.tentacle_girth_here
        offset_component = dot(EI.center_offset_in_orifice, dir_r)
        reach = offset_component + tentacle_girth
        target_radius[r] = max(target_radius[r], reach)
```

`max` over the list — if two tentacles are on opposite sides of the orifice, each drives its own side independently. Compression per tentacle is computed individually against the resulting ring radius via bilateral compliance.

When a tentacle needs to resolve its own angular location against the authored rings (e.g. to deposit pressure at angle θ in Center-XY), find the two rings that *bracket* θ in the profile's sorted authored-angle table and interpolate between them. Never assume uniform angular spacing — irregular rim loops produce irregular authored angles.

**Inter-tentacle separation inside an orifice:** type-5 (particle-particle) collision is always enabled for particles flagged as inside any orifice, even if disabled globally. This lets two tentacles jam in side-by-side and physically push each other apart.

**Cap: 3 simultaneous per orifice.** 4th is rejected at entry. Override flag exists for player/narrative-driven forced multi-entry.

**Knot-aware grip ramp.** When a girth differential is straddling the rim, grip engagement ramps faster:

```
knot_factor = clamp(|girth_gradient_at_rim| / reference_gradient, 0, 1)
grip_engagement_rate_effective = base_rate * (1.0 + knot_factor)
```

`girth_gradient_at_rim` is the signed axial derivative of girth where the tentacle crosses the entry plane — the same quantity used by the §6.3 axial wedge. Magnitude is large for a knot, near zero for the smooth shaft. Reference gradient is per-orifice (default `1.0`). Makes "trapped behind a knot" feel land reliably without affecting smooth-shaft scenarios.

**Source of the gradient.** Bake `d(girth)/ds` as a second channel of the girth texture (§5.4) at mesh import / procedural-generation time. The same texture sample serves both §6.3 (axial wedge) and §6.5 (knot factor). Avoids per-tick finite-differencing.

**No `accept_penetration` flag, no `min_approach_angle_cos` gate.** Per §1: if soft physics can't refuse, raise stretch_stiffness, raise grip strength, lower wetness, or write the appropriate `OrificeModulation` channels. Glancing-approach rejection emerges naturally from the rim particle loop (§6.1, 2026-05-03 amendment) — the loop *is* a connected curved surface in type-2 collision, so glancing tentacles slide off it.

### 6.6 Jaw special case

The jaw is a **hinge joint**, not a radial ring. Opening the mouth rotates the lower jaw around the TMJ axis. Modeled differently:

```cpp
struct JawOrifice : Orifice {
    BoneName jaw_bone;                   // mandible
    Vector3  jaw_hinge_axis;             // TMJ axis, in skull space
    float    jaw_rest_angle;             // 0° = closed
    float    jaw_max_angle;              // ~45° anatomical max
    float    jaw_closure_strength;       // muscular closing force
    float    jaw_relaxation;             // 0..1, driven by Reverie
    BoneName upper_lip_bones[4];         // fixed to skull
    BoneName lower_lip_bones[4];         // move with jaw
};
```

Tick logic:
```
// Compute opening demand from tentacle pressure along hinge-perpendicular axis
target_angle = 0
for each active EntryInteraction:
    girth_vertical = component of tentacle_girth perpendicular to hinge axis
    required_angle = asin(girth_vertical / mouth_depth)
    target_angle = max(target_angle, required_angle)

// Torque balance
closure_force = jaw_closure_strength × (1.0 - jaw_relaxation)
torque_open   = force_from_tentacle(interactions)
torque_close  = -closure_force × current_angle
torque_damp   = -current_angular_velocity × jaw_damping

current_angular_velocity += (torque_open + torque_close + torque_damp) × dt / jaw_moi
current_angle += current_angular_velocity × dt

// Hard anatomical limits
if current_angle < 0: current_angle = 0, current_angular_velocity = max(0, ω)
if current_angle > jaw_max_angle:
    overpressure = torque_open  // couldn't be absorbed
    publish_event(HardStopBottomedOut, magnitude: overpressure)
    jaw_damage += overpressure × dt × damage_rate
    apply_impulse_to_skull(overpressure × skull_kickback_factor)
    current_angle = jaw_max_angle
    current_angular_velocity = min(0, ω)

skeleton.set_bone_pose_rotation(jaw_bone, rotation_around(jaw_hinge_axis, current_angle))
```

Lips: upper lips stay fixed relative to skull; lower lips ride the jaw. Optionally add a smaller ring-bone layer on the lips for local compression against tentacle, driven by the usual bilateral compliance but at a sub-mouth scale.

`jaw_relaxation` = 0 when tense/alert, = 1 when unconscious/surrendered. Written by Reverie via modulation channel (§8.2). Controls how strongly the jaw resists forced opening.

### 6.7 Through-path tunnels

A tentacle may traverse multiple orifices as a chained path ("all-the-way-through"). Each `EntryInteraction` may be linked head-to-tail with another `EntryInteraction` belonging to a different orifice on the same hero.

- Each `EntryInteraction` gains optional `downstream_interaction` and `upstream_interaction` pointers.
- Tunnel projection sums along the linked chain; the tentacle spline passes through all orifices' tunnel splines in sequence.
- Capsule suppression (§10.5) unions the suppression lists of all chained orifices.
- Bulger sampling (§7.2) covers the full chained interior — allocate 6 samples per orifice in the chain, not 6 samples per tentacle.
- AI targeting uses the entry orifice only; the exit orifice is emergent from physics.
- Chain linking is detected by proximity: when a penetrating tentacle's tip enters a second orifice's entry plane while still engaged upstream, a downstream `EntryInteraction` is created and linked.

### 6.8 Storage chain

Each tunnel may host a **storage chain**: a PBD particle subchain whose particles are constrained to the tunnel's arc-length axis. Each particle in this chain is a **bead** with a type tag.

**Bead types.**

- **Sphere bead.** Fields: `radius`, `surface_material`. Simplest case — a stored spherical object (egg, orb).
- **Tentacle-root bead.** References a `Tentacle`. The tentacle's first `K` particles (typically 2–4) participate in the storage chain's distance constraints. The remaining particles are free PBD particles that hang into the tunnel volume and can writhe inside (coiled stored tentacle).

**Chain mechanics.**

- Beads are sorted by arc-length along the tunnel. Bead-bead distance constraints prevent overlap; each bead carries an effective `chain_radius` equal to its maximum cross-section in the plane perpendicular to the tunnel tangent.
- Friction against the tunnel wall (type-3 collision, §4.2) prevents free drift. Wetness reduces it; grip/peristalsis overcomes it.
- Beads collide with tentacles currently inside the same tunnel (type-5). A penetrating tentacle pushes beads axially along the chain.
- When the ragdoll moves, the tunnel spline moves; beads track the spline and the chain wobbles naturally.

**Through-path chains.** When `EntryInteraction`s are linked into a through-path (§6.7), storage chains link across them — a single continuous chain can span multiple orifices on the same hero. Migration from one orifice's tunnel to another is emergent: a bead pushed past the downstream boundary transfers to the adjacent chain.

**Runtime cost.** ~10 beads per active tunnel is typical; trivial compared to the existing 12×32 = 384 particle budget. Storage chains participate in the same PBD solver loop; no separate simulation.

### 6.9 Oviposition and birthing

A tentacle may hold payloads to deposit, and a hero may expel stored contents. Both reuse existing machinery.

**Oviposition: `OvipositorComponent`.** Attached as a child of a `Tentacle`. Holds a queue of payload specifications (sphere profile or `Tentacle` resource). While the queue is non-empty, the tip particle's `girth_scale` is raised by `carrying_girth_bonus` to produce a visible lump traveling the shaft as the tentacle fills (optional; disable via `suppress_visual_carry` if authored aesthetics call for it).

Deposit trigger (AI, Reverie, or script-driven): when the tip is past `deposit_depth_threshold` in a tunnel with an active `EntryInteraction`, one payload is consumed off the queue and spliced into that tunnel's storage chain at the tip's current arc-length. Tip girth returns to baseline. Emits `PayloadDeposited`.

For tentacle payloads: the queued `Tentacle` spawns with base particle `inv_mass = 0` (pinned) at the insertion arc-length, remaining particles released into the tunnel. The new tentacle participates in the solver as a normal `Tentacle`, with its base locked into the storage chain.

**Birthing: peristalsis.** Reverie writes a peristalsis modulation to each tunnel via new modulation channels (see §8.2 updates). The tunnel's rest-girth profile becomes time-varying:

```
girth(t, time) = rest_girth(t) × (1 + amp × sin((t − speed × time) × 2π × wavelength))
```

Beads in the low-girth phase of the wave experience asymmetric ring pressure producing a net axial force along the tunnel gradient — the same wedge mechanic as orifice-rim compression, applied tunnel-to-bead. Reverie can drive expulsion (amplitude high, speed positive along exit direction) or retention (amplitude low, or speed reversed to pull beads inward).

**Mechanical scope.** Peristalsis is implemented as a time-varying contribution to per-loop `target_enclosed_area` (and, optionally, per-particle rest-position deltas for asymmetric peristaltic shapes) — the same channels bilateral compliance writes. Concretely, for each rim particle at every active tunnel loop along the orifice's tunnel:

```
wave_phase = (arc_length_at_ring × peristalsis_wavelength
            - peristalsis_wave_speed × t) × 2π
peristalsis_target_radius =
    rest_radius * (1.0 - peristalsis_amplitude * sin(wave_phase))
target_enclosed_area_per_loop[l] = max(target_enclosed_area_per_loop[l], peristalsis_target_area)
```

(Or, depending on whether peristalsis is constrictive or dilatory at the trough, blend or `min`/`max` per the authored intent.)

**Consequence.** Any particle in the tunnel — bead-chain or penetrating tentacle — that is in collision contact with the deformed wall radius is pushed by the same projection. Bilateral compliance writes asymmetry to nearby tentacle particles; type-3 collision (tunnel wall) handles the rest. **No separate "push tentacle particles" force path is needed.** This makes peristalsis the canonical mechanism for both ingestion (negative `peristalsis_wave_speed`) and expulsion (positive) of penetrating tentacles, alongside its bead-storage role.

**Birthing: ring transit.** When a bead reaches the orifice's inner entry plane, it is treated identically to a bulb on retraction (Scenario 2). Ring bones stretch nonlinearly to accommodate `bead.chain_radius`; bilateral compliance (§6.3) applies; grip hysteresis engages if grip was active; pop-release occurs past the ring's widest point. Emits `RingTransitStart` at initial contact and `RingTransitEnd` at completion, and `PayloadExpelled` with the bead reference as the full event payload.

Damage accumulates per §6 if `bead.chain_radius` exceeds `orifice.max_radius`.

**Tentacle-bead release on expulsion.** When a tentacle-root bead's pinned particles cross the entry plane outward, each pinned particle transitions `inv_mass` from 0 to the tentacle's normal per-particle mass in order. By the time the last pinned particle exits, the tentacle is fully free.

The freed tentacle is an ordinary `Tentacle` with a **"Free Float" scenario preset** (see `TentacleTech_Scenarios.md` §A4): zero target-pull, high noise, low stiffness. In zero-G environments this produces natural wiggling. The existing PBD bending constraints (§3.3) fill the role that cone-twist joints would on a `PhysicalBone3D` chain. **Do not use `PhysicalBone3D` chains for excreted tentacles** — one solver type for everything (§1 principle), and the `PhysicalBone3D` scaling bug (§14) would re-surface.

**Open design question (not blocking):** payload source for oviposition in gameplay — whether tentacles arrive pre-loaded, refill from environment sources, or have infinite capacity. Defer until encounter design lands.

### 6.10 Transient pulse primitives

Steady peristalsis (§6.9) covers continuous waves. Transient one-shot pulses cover punctuated reflexes — climax contractions, gag reflex, pain spasm, refusal spasm, knot-engulfment "gulp." Implemented as additive envelopes on top of `peristalsis_amplitude` / `peristalsis_wave_speed`, evaluated per tick.

```cpp
struct ContractionPulse {
    float       magnitude;     // 0..1, peak added to peristalsis_amplitude
    float       speed;         // arc-length/sec, signed (positive = exit, negative = ingest)
    float       wavelength;    // typically ≥ tunnel length → acts as one wave
    float       duration;      // seconds (envelope total length)
    float       t_started;     // populated on activation
    Ref<Curve>  envelope;      // 0..1 over normalized age; default below
    uint32_t    applies_to;    // bitfield: TENTACLES = 1, BEADS = 2
};

Vector<ContractionPulse> active_pulses;   // per orifice; cap ~4
```

**Pulses are atomic.** No `count`, no `interval`. Repeating patterns (orgasm, etc.) are sugar at the *emitter* level: the pattern emits N atomic `ContractionPulse`s with staggered `t_started`. The orifice tick has one job — evaluate active pulses additively.

Per-tick contribution:

```
effective_amplitude = peristalsis_amplitude
effective_speed     = peristalsis_wave_speed
for each pulse p in active_pulses (filtered by applies_to):
    age = current_time - p.t_started
    if age >= p.duration:
        retire and continue
    env = p.envelope.sample_baked(age / p.duration)
    effective_amplitude += p.magnitude * env
    effective_speed     += p.speed     * env
```

**Default envelope.** Built-in `Curve` resource: trapezoidal `0 → 1 → 1 → 0` with 20% attack, 60% sustain, 20% release. Authoring may override per-pulse with custom curves (sharp spike, slow swell, etc.).

**Named patterns** (Reverie reaction-profile sugar — emitters that queue lists of atomic pulses; not new physics):

- `OrgasmPattern` — 6 pulses, magnitudes `[0.8, 0.7, 0.6, 0.5, 0.4, 0.3]`, stagger 0.6 s, `speed +0.4 m/s`, default envelope.
- `GagReflexPattern` — 1 pulse, magnitude 1.0, duration 0.4 s, sharp envelope (10% attack, 20% sustain, 70% release), `speed +0.6 m/s` on the oral tunnel; combined at the Reverie layer with `jaw_relaxation → 1` and head `voluntary_motion_vector` rear-ward.
- `PainExpulsionPattern` — 1 pulse, magnitude 0.7, duration 0.3 s, sharp envelope.
- `RefusalSpasmPattern` — 2 pulses, magnitude 0.5, alongside `active_contraction_target → 0.6` and host `voluntary_motion_vector` away.
- `KnotEngulfPattern` — 1 pulse, *negative* speed, magnitude 0.7, duration 0.5 s, wavelength = tunnel length.

The term "DrawInPulse" used in earlier drafts is **not** a separate type — it is a `ContractionPulse` with negative `speed`. Avoid the term in code; use `ContractionPulse` everywhere.

**Autonomous `appetite` (optional).** Per-orifice `appetite: float` (default 0.0) drives automatic reverse peristalsis when a girth differential is detected at the entry plane:

```
if orifice.appetite > 0 and girth_at_entry_plane > orifice.rest_radius * 1.05:
    auto_speed     = -orifice.appetite * appetite_speed_scale
    auto_amplitude = +orifice.appetite * appetite_amplitude_scale
    effective_speed     += auto_speed
    effective_amplitude += auto_amplitude
```

Reverie owns the value of `appetite` (state-driven, can be 0 most of the time); the mechanical response is autonomous below it. Use to express character archetypes ("hungry rim") without scripting per-encounter pulses.

### 6.11 `RhythmSyncedProbe` — body-rhythm-locked self-insertion

A modifier component on `Tentacle` (sibling pattern to `OvipositorComponent`, §6.9). Reads `marionette.body_rhythm_phase` (`docs/marionette/Marionette_plan.md` P7.10) and drives the tentacle's tip target along an active `EntryInteraction`'s tunnel at a configurable phase offset. This is how a tentacle locks rhythmically to the host body's pelvic motion — pumping coordination ("thrust when hips rock back") or yielding coordination ("advance when hips press in"), differing only in `phase_offset_rad`.

**Schema:**

```
RhythmSyncedProbe (Node, child of Tentacle):
  marionette_path: NodePath        # reference to the synced Marionette
  entry_interaction_id: int        # which EI on this tentacle to drive (-1 = first active)
  phase_offset_rad: float = PI     # offset from marionette.body_rhythm_phase
  amplitude_along_spline: float    # how far the insertion drives, in tunnel arc length
  insertion_curve: Curve           # value over phase: shape of the drive cycle
```

**Per-tick:**

```
phase = fmod(marionette.body_rhythm_phase + phase_offset_rad, TAU)
drive = insertion_curve.sample_baked(phase / TAU) * amplitude_along_spline
# drive is added to the tentacle's tip target along the EI's tunnel arc-length;
# composes with the existing target-pull constraint (§3.3) — does not replace it.
tentacle.set_tunnel_drive(EI, drive)
```

**Composition.** The drive is a position offset along the `EntryInteraction`'s tunnel arc-length, applied as a target-pull (§3.3). It composes additively with whatever target the tentacle's behavior driver is otherwise writing — high-level intent stays in charge of *which* orifice is engaged; the rhythm probe owns *when* it pushes within that engagement.

**Two presets worth shipping:**

- `probe_pumping.tres` with `phase_offset_rad = PI` — tentacle thrusts forward when hips rock backward (pumping coordination).
- `probe_yielding.tres` with `phase_offset_rad = 0` — tentacle and hips advance together (body presses into the thrust).

Both reference the same `insertion_curve` shape; only the offset differs.

**Why on `Marionette`'s clock and not the tentacle's own.** Per `docs/marionette/Marionette_plan.md` P7.10, `body_rhythm_phase` is integrated, not recomputed; a frequency change driven by Reverie produces a smooth tempo change in the body and in any tentacle locked to it. A tentacle with its own clock would phase-snap when arousal shifts. Mandatory.

**Note on shared clock consumers.** The same `Marionette.body_rhythm_phase` integrated by Marionette is now also read by `MarionetteComposer` (`docs/marionette/Marionette_plan.md` P10) for predictive engagement pumping of the body. `RhythmSyncedProbe` and the composer therefore share a single phase variable for body-tentacle rhythm coupling — no replication. Frequency is set via the frequency-compliance pipeline (`docs/architecture/Reverie_Planning.md §3.5`): Reverie writes the per-mindset compliance curve, the composer slew-limits `body_rhythm_frequency` toward `body_rhythm_frequency_proposed`; both consumers see the same value automatically.

---

## 7. Hero skin bulges

### 7.1 Bulger uniform arrays

A **bulger** is a capsule of influence in world space: two endpoints plus a radius. The hero skin and cavity-surface shaders read the capsule array and displace affected vertices along their surface normal.

```glsl
uniform int  bulger_count;              // 0..64
uniform vec4 bulgers_a[64];             // xyz = endpoint A, w = radius
uniform vec4 bulgers_b[64];             // xyz = endpoint B, w = strength
```

A sphere bulger (single point-of-influence, e.g. external contact) is encoded as `A == B`; the segment-distance math degenerates to point-distance automatically.

Vertex shader inner loop:

```glsl
vec3 displacement = vec3(0.0);
for (int i = 0; i < bulger_count; i++) {
    vec3  a  = bulgers_a[i].xyz;
    vec3  b  = bulgers_b[i].xyz;
    float r  = bulgers_a[i].w;
    float s  = bulgers_b[i].w;

    // Closest point on segment [a,b] to VERTEX
    vec3  ab = b - a;
    float t  = clamp(dot(VERTEX - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
    vec3  cp = a + t * ab;
    float d  = length(VERTEX - cp);

    float influence = r * 2.5;
    if (d < influence) {
        float falloff = 1.0 - smoothstep(r, influence, d);
        // Normal-direction push — "flesh displaced from below"
        displacement += NORMAL * falloff * r * s * 0.6;
    }
}
VERTEX += displacement;
```

64 capsules × 15k vertices = 960k segment-distance ops per frame. Still trivial on modern GPUs including integrated.

**Why capsules.** Sphere bulgers produce beads-on-a-string visuals and cannot represent a tentacle *tube* inside a cavity — the deformation gap between samples is always visible. Capsule bulgers span between adjacent PBD particles, so a tentacle inside a tunnel produces a continuous tube-shaped deformation in both the overlying skin and the cavity wall from the same uniform array.

### 7.2 Bulger sources

Each hero's `SkinBulgeDriver` aggregates capsule bulgers each tick from the following sources.

**Internal tentacles** (penetrating, inside any tunnel):
- For each PBD segment whose both endpoints are inside the tunnel, emit one capsule bulger with endpoints at the two particle world positions.
- Radius = `tentacle_rest_girth_at_arc_length × particle.girth_scale` (use major-axis radius when asymmetry is non-zero — approximation; the mesh itself carries the full ellipse visually).
- Strength = 1.0.
- For tentacles with > 8 segments inside, sub-sample to 6–8 evenly spaced capsules to stay within the 64 cap under heavy scenes.

**Storage beads** (stored contents in any tunnel):
- For sphere beads: emit a capsule with `A == B` at bead world position, radius = `bead.chain_radius × storage_display_factor` (typical `storage_display_factor ≈ 0.9`).
- For tentacle-root beads: emit capsules between the pinned particles (treats the stored tentacle's base as a short segmented shape in the tunnel).
- Strength = 1.0. Priority tier = `Storage` (see §7.6).

**External contacts** (type-1 capsule collisions with significant normal force):
- Emit a capsule with `A == B` at contact point (degenerate = sphere).
- Radius = `clamp(normal_force / reference_force, 0, max_external_radius) × external_bulge_factor`.
- Strength = 1.0. Priority tier = `Transient`.

Maximum 64 active bulgers. If aggregated candidates exceed 64, keep by `(priority_tier, magnitude)` descending (§7.6). Eviction fade per §7.5.

### 7.3 Spring-damper jiggle

Each bulger has spring-damper state for position and radius:

```cpp
struct BulgerState {
    Vector3 target_position;       // sampled from tentacle / contact point
    Vector3 display_position;      // what gets written to uniform
    Vector3 velocity;
    float   target_radius;
    float   display_radius;
    float   radius_velocity;
};
```

Per-tick update:
```
for each bulger b:
    // Position spring
    spring_f = (b.target_position - b.display_position) × bulger_spring_k
    damp_f   = -b.velocity × bulger_damping
    b.velocity += (spring_f + damp_f) × dt
    b.display_position += b.velocity × dt
    
    // Radius spring
    r_spring_f = (b.target_radius - b.display_radius) × bulger_radius_spring_k
    r_damp_f   = -b.radius_velocity × bulger_radius_damping
    b.radius_velocity += (r_spring_f + r_damp_f) × dt
    b.display_radius += b.radius_velocity × dt

write_to_uniform: bulgers[i] = vec4(b.display_position, max(0, b.display_radius))
```

**Skin jiggles naturally after rapid tentacle motion.** Fast retraction → position spring overshoots → skin wobbles. Deflation → radius springs down, overshoots to near zero, damps back. All for ~38K ops/sec CPU.

### 7.4 Tuning

- `bulger_spring_k = 120` (position stiffness)
- `bulger_damping = 8` (position damping, moderate)
- `bulger_radius_spring_k = 200` (radius responds faster)
- `bulger_radius_damping = 12`

Per-body-region stiffness maps are possible but one global value is fine for Phase 5.

### 7.5 Bulger eviction and fade

When the active bulger set changes between frames (a new bulger enters, an existing one is culled), apply a temporal fade to avoid visible popping under saturation:

- Each aggregated bulger carries an `active_since_time` timestamp.
- On entry to the active set: `display_radius` ramps from 0 to `target_radius` over 2 frames (linear).
- On eviction from the active set: `display_radius` ramps from current to 0 over 2 frames, then the slot is released.
- Eviction-in-progress bulgers are retained in the uniform array; the active-set cap of 64 refers to fully-active slots.

Implemented CPU-side in `SkinBulgeDriver` before uniform upload. Adds negligible aggregation cost.

### 7.6 Bulger priority tiers

Each aggregated bulger carries a `priority_tier` enum used for eviction ordering under the 64-cap:

- `Storage` — stored contents (sphere beads, tentacle-root beads). Never evicted while the containing region is visible to the camera. Flicker on eviction would be highly visible as organs that suddenly un-deform.
- `Internal` — tentacles currently inside a tunnel.
- `Transient` — external contact bulgers.

Sort order under saturation: `Storage` first (keep all), then `Internal` by magnitude descending, then `Transient` by magnitude descending. `Storage` slots still count against the cap; if storage alone exceeds 64 (pathological case), keep highest-magnitude storage beads and accept visual clipping on the rest.

### 7.7 Cavity surface integration

Internal cavity walls are surfaces of the same continuous hero mesh as skin (see §10 updates for authoring). Both surfaces include the bulger-deform vertex shader block from §7.1 and read the same uniform arrays. A bulger inside a tunnel therefore produces:

- Cavity-wall vertices within falloff radius: displaced along cavity-wall normal (outward from cavity interior = into surrounding tissue).
- Overlying skin vertices within falloff radius: displaced along skin normal (outward into world).

Both fall out of one uniform loop. Falloff radius gates reach — a bulger with 6 cm falloff cannot deform organs 20 cm away through the torso, and this is the only gating mechanism needed in v1. No body-region layer masks.

Cavity meshes do not get rim anchors of their own. Rim anchors at each orifice rim rig shared rim vertices (see §6.1); the rim is a single edge loop of the continuous mesh, and rim particle motion (per §6.4) deforms the rim visible from both sides.

---

## 8. Stimulus bus

### 8.1 Events vs continuous channels

Two data types, cleanly separated:

**Events** — discrete moments with timestamp, published when something happens:
```cpp
enum StimulusEventType {
    PenetrationStart, PenetrationEnd,
    BulbPop, StickSlipBreak, GripEngaged, GripBroke,
    RingOverstretched, HardStopBottomedOut, FluidSeparation, WetSeparation,
    Impact, TangentialSlap, SkinPressure,
    OrificeDamaged, TentacleTangled,
    EnvironmentalFlash, LoudSound, TemperatureDrop,  // external
    DialogueAddressed, ObserverArrived,              // external
    RunStarted, RunEnded,                            // run lifecycle
    PayloadDeposited, PayloadExpelled,               // oviposition / birthing
    StorageBeadMigrated,                             // storage chain movement
    RingTransitStart, RingTransitEnd,                // bead crossing rim
    PhenomenonAchieved,                              // rare emergent event (see docs/Gameplay_Mechanics.md)

    // Pattern lifecycle (added 2026-04-27). Most subscribers want these,
    // not per-pulse fires.
    OrgasmStart, OrgasmEnd,
    GagReflexStart, GagReflexEnd,
    PainExpulsionStart, PainExpulsionEnd,
    RefusalSpasmStart, RefusalSpasmEnd,

    // Generic per-pulse fire — for fine-grained sound triggering or
    // physics-precise reactions. Most subscribers will ignore this and use
    // the lifecycle events above.
    ContractionPulseFired,        // extra: { pattern_id, magnitude, kind }

    // Discrete physical beats (added 2026-04-27)
    KnotEngulfed,                 // bulky girth crossing inward past the rim
                                  //   (counterpart to BulbPop)
    EntryRejected,                // EntryInteraction creation failed for soft-physics
                                  //   reasons. extra: { peak_pressure, reason }
};

struct StimulusEvent {
    StimulusEventType type;
    float   magnitude;         // normalized 0..1 where possible
    float   raw_value;
    Vector3 world_position;
    int     body_area_id;
    int     source_id;
    int     target_id;
    float   timestamp;
    Dictionary extra;
};
```

Stored in a ring buffer (256 entries default, ~2s TTL). Consumers query recent events.

`RunStarted` carries the starting mindset vector and hero id; `RunEnded` carries `payout` (currency amount, single type), final mindset vector, and duration in seconds. These are infrastructure-only at present — no physics subsystem emits or consumes them. The game layer will fire and listen to these once run structure is designed (see `docs/Gameplay_Loop.md`); defining them now keeps the schema stable.

Oviposition / birthing payloads:
- `PayloadDeposited` (`tentacle_id`, `tunnel_id`, `bead_type`, `bead_arc_length`, `resulting_chain_size`) — fired by an `OvipositorComponent` on successful deposit.
- `PayloadExpelled` (`orifice_id`, `bead_type`, `bead_id`, `peak_ring_stretch`, `final_velocity`) — fired at end of ring transit on exit.
- `StorageBeadMigrated` (`tunnel_id`, `bead_id`, `delta_arc_length`) — fired when a bead's tunnel arc-length changes by more than a threshold within a tick.
- `RingTransitStart` (`orifice_id`, `bead_id`, `bead_radius`) — bead crosses inner entry plane on the way out.
- `RingTransitEnd` (same plus `duration_seconds`) — bead has fully crossed the rim.
- `PhenomenonAchieved` (`phenomenon_id`, `magnitude`, `context`) — fired by a `PhenomenonDetector` when a rare emergent event is recognized (see `docs/Gameplay_Mechanics.md`).

Pattern + per-pulse + discrete-beat events (added 2026-04-27):

- `OrgasmStart` / `OrgasmEnd`, `GagReflexStart` / `GagReflexEnd`, `PainExpulsionStart` / `PainExpulsionEnd`, `RefusalSpasmStart` / `RefusalSpasmEnd` — pattern lifecycle brackets emitted by the §6.10 pattern emitters. Coarse-grained; most subscribers (sound, animation, Reverie) consume these rather than per-pulse fires.
- `ContractionPulseFired` (`pattern_id`, `magnitude`, `kind`) — fired once per atomic `ContractionPulse` activation. Use when fine-grained sound triggering or physics-precise reactions are needed.
- `KnotEngulfed` — counterpart to `BulbPop`; fired when a bulky girth differential crosses inward past the rim (e.g. autonomous `appetite` consuming a knot, §6.10).
- `EntryRejected` (`peak_pressure`, `reason`) — soft-physics rejection of an entry attempt. Reasons:
  - `InsufficientPressure` — approach pressure below grip-engagement threshold.
  - `FrictionStuck` — tentacle pinned by static friction before crossing the entry plane.
  - `OrificeBusy` — cap of 3 simultaneous tentacles per §6.5 reached.

  There is no hard-refusal lever (per §1 discipline). `EntryRejected` exists to tell subscribers that a soft-physics rejection happened, not to be triggered by a script.

**No event-type-per-pattern.** Adding `OrgasmContraction`, `LustfulSpasm`, `PostCoitalRipple` as distinct event types would inflate the enum unboundedly. Patterns are data; events are type-checked enum values that subscribers compile against. The generic `ContractionPulseFired` carries pattern identity in its `extra` dictionary. Lifecycle events are coarse-grained brackets, kept as a small fixed set.

**Continuous channels** — values that exist every frame, updated in place:
```
body_area_pressure[area_id]        // per body region
body_area_friction[area_id]        // friction energy rate
body_area_contact_count[area_id]
body_area_sensitivity[area_id]     // authored, static
body_area_arousal[area_id]         // accumulating

orifice_state[orifice_id] = {
    stretch_amount, depth, wetness, damage, grip_engagement,
    internal_rubbing_rate, external_rubbing_rate, active_tentacle_count
}

tentacle_controlled_by[tentacle_id]    // enum { AI, Player }
                                       // updated each tick by the tentacle controller;
                                       // Reverie reads for salience, otherwise informational

ambient_light_level, ambient_sound_level, ...
```

### 8.2 Modulation channels (bidirectional)

Reverie writes to modulation channels; physics reads them and applies multiplicatively on top of base parameters:

```cpp
struct OrificeModulation {
    float grip_strength_mult       = 1.0;
    float stretch_stiffness_mult   = 1.0;
    float ring_spring_k_mult       = 1.0;
    float wetness_passive_rate_bias = 0.0;
    float active_contraction_target = 0.0;   // 0..1, rhythmic tensing
    float active_contraction_rate   = 0.0;   // Hz
    float seek_intensity            = 0.0;   // host bone bias toward target
    int   seek_target_tentacle_id  = -1;

    // Peristalsis (drives storage-chain expulsion / retention; see §6.9)
    float peristalsis_wave_speed   = 0.0;    // arc-length units/sec; positive = toward exit
    float peristalsis_amplitude    = 0.0;    // 0..1 fraction of rest girth
    float peristalsis_wavelength   = 1.0;    // waves per unit arc-length

    // Transient pulse activation (added 2026-04-27). See §6.10.
    // Reverie pushes new ContractionPulse entries into the orifice's
    // active_pulses array through a mutator method. Patterns are emitted as
    // multi-pulse sequences by the pattern emitter (sugar; not part of the
    // tick-level data).
    void queue_contraction_pulse(ContractionPulse p);
    void emit_pattern(StringName pattern_id);   // sugar: queues N atomic pulses

    // Autonomous appetite (added 2026-04-27).
    // 0..1; non-zero enables automatic reverse peristalsis when
    // girth_at_entry > rest_radius × 1.05.
    float appetite                 = 0.0;
};

// Peristalsis modulation is per-tunnel, attached to the orifice whose tunnel
// it controls. Through-path tunnels (§6.7) use the entry orifice's peristalsis
// state by default; a later authoring hook may override this per-segment.

struct BodyAreaModulation {
    Vector3 pose_target_offset;
    float   pose_stiffness_mult   = 1.0;
    Vector3 voluntary_motion_vector;
    float   voluntary_motion_magnitude  = 0.0;
    float   voluntary_motion_rate       = 0.0;   // Hz for cyclic
    float   receptivity_mult            = 1.0;
};

enum AttentionTargetType { AttentionNone, AttentionTentacle, AttentionBodyArea, AttentionWorld, AttentionObserver };

struct CharacterModulation {
    float global_tension_mult           = 1.0;
    float global_noise_amplitude        = 1.0;
    float breath_rate_mult              = 1.0;
    float breath_depth_mult             = 1.0;
    bool  breath_held                   = false;
    float jaw_relaxation                = 0.0;
    float pain_response_mult            = 1.0;
    float reaction_responsiveness_mult  = 1.0;

    AttentionTargetType attention_target_type      = AttentionNone;
    int                 attention_target_tentacle_id  = -1;   // used when type = Tentacle
    int                 attention_target_body_area_id = -1;   // used when type = BodyArea
    Vector3             attention_target_world_position;      // used when type = World or Observer
    float               attention_intensity        = 0.0;     // 0..1

    float               xray_reveal_intensity      = 0.0;     // 0..1; consumed by hero skin shader (see §9.5)
};
```

Physics reads via `read_orifice_modulation(id)` and applies:
```
effective_grip = base_grip × mod.grip_strength_mult
effective_stretch_stiffness = base_stretch_stiffness × mod.stretch_stiffness_mult
// etc.
```

Default values = identity. Physics works correctly with no reaction system present.

### 8.3 Body area abstraction

**Not per-bone, not per-vertex.** 20–30 named regions per hero, each mapping to a set of ragdoll bones plus a sensitivity value. Authored once per hero model.

Per body area:
- List of bones that belong to it (for contact detection)
- Static sensitivity (0..3, authored; erogenous regions higher)
- Linked orifice list (arousal from this area propagates to linked orifices)

When a physics contact happens on a bone, look up the bone's body_area_id and aggregate friction/pressure there. The reaction system and arousal coupling read body areas, not bones.

### 8.4 Wetness-sensitivity coupling

```
for each body area a each tick:
    stim = body_area_friction[a] + body_area_pressure[a] × press_to_stim_ratio
    arousal_gain = stim × sensitivity[a] × global_arousal_mult
    body_area_arousal[a] += arousal_gain × dt
    body_area_arousal[a] *= (1.0 - decay_rate × dt)

for each orifice o:
    linked_arousal = mean(body_area_arousal[a] for a in o.linked_areas)
    effective_wetness_rate = linked_arousal × responsiveness
                           + orifice.modulation.wetness_passive_rate_bias
                           - evaporation_rate
    o.wetness += effective_wetness_rate × dt
```

Different heroes with different sensitivity maps respond differently to the same physics.

### 8.5 Bus as autoload

Single autoload (`StimulusBus`) holding all events, continuous channels, and modulation state. Physics writes events and continuous channels. Anyone can read. Reverie writes modulation. Single shared object, lock-free if used cooperatively (single-threaded physics, single-threaded reaction ticks interleaved).

---

## 9. Mechanical sound

Physics-driven sound lives in TentacleTech. Character voice lives in Reverie.

Each tentacle and orifice has a `MechanicalSoundEmitter` component subscribing to stimulus bus events and continuous state:

| Sound | Triggered by | Volume from | Pitch from |
|---|---|---|---|
| Squelch | Friction inside orifice/tunnel above threshold | Friction energy | Wetness (drier = lower) |
| Friction slide | Continuous tangential motion | Same | Velocity |
| Ring creak | Ring radius velocity above threshold | Stretch rate | Ring size |
| Stick-slip chirp | StickSlipBreak event | Normal force | Rib frequency if ribbed |
| Impact/slap | Impact event above threshold | Impact magnitude | Body stiffness |
| Spring snap-back | Ring velocity reverses with high magnitude | Peak velocity | Spring frequency |
| Fluid separation | FluidSeparation event | Strand stretch | Ambient wetness |
| Bulb pop | Girth spike through entry | Girth differential | Orifice stiffness |

Spatialized as `AudioStreamPlayer3D`. Priority-capped to prevent mixer saturation (impacts high, squelch capped at 2 concurrent per hero).

### Fluid system (slime / drool / wetness)

> **Amended 2026-05-03** (was: a single paragraph on FluidStrand). Promoted
> to a five-behavior subsystem per
> `Cosmic_Bliss_Update_2026-05-03_obi_realism_and_orifice.md` §3 (approved
> 2026-05-03). All five behaviors reuse existing TentacleTech PBD + the
> `docs/Appearance.md` decal accumulator + the stimulus bus. ~200 LOC
> GDScript total, no new C++. Phase 6 scope (lands alongside the bus).

The fluid system covers visual cohesion of wetness without simulating SPH.
Five behaviors:

**1. Strand.** When a tentacle withdraws past the orifice entry plane (or
separates from any wet surface above a wetness threshold), spawn a
`FluidStrand` — a 4-6 particle PBD chain anchored at the retreating tip
and the separation point on the surface. Driven by the existing
TentacleTech PBD solver with distance constraints + breaking threshold:
when any segment exceeds 4× rest length the constraint detaches; the two
resulting halves continue under gravity for ~0.5s before fading.
Render as GPU triangle strip with girth taper. ~50 LOC `fluid_strand.gd`.

**2. Drip.** When a strand particle's velocity falls below threshold AND
it's within `epsilon` of a downward-facing surface, convert the particle
to a drip mark — spawn one decal at the contact point and remove the
particle from the simulation. Decals accumulate via the
`docs/Appearance.md` decal accumulator. Each drip = one entry in the
surface accumulator with configurable lifetime (default 30s fade).

**3. Smear.** When a tentacle particle is in surface contact AND tangent
velocity exceeds `smear_threshold`, lay down a moisture decal at the
contact point. Decals overlap to build up a trail. Bidirectional
wetness coupling: high `wetness_per_surface_region` modulates μ_s
(lower static friction on wet surfaces); dragging a dry tentacle across
a wet surface raises tentacle wetness (transfer in both directions).
Couples to §4.4 friction modulator stack via a new `surface_wetness`
modulator.

**4. Pool.** Surface decals on horizontal-ish faces (`abs(normal.y) >
0.7`) accumulate into pools. Implemented as a per-region density
counter: `pool_density[region] += smear_or_drip_event * dt;
pool_density *= evaporation_rate`. Density crossings swap between
"damp" / "wet" / "puddle" decal art. Default fade-to-dry over 60s.
Lives in `WetnessAccumulator` GDScript class.

**5. Peel-sting.** When a tentacle particle separates from a surface
AND `surface_wetness` is above threshold AND separation velocity is
above threshold, emit a `WetSeparation` event on the bus. Audio system
plays a peel/sting sound (squelch, tch, suction-release) via the
existing `MechanicalSoundEmitter`. Visual system spawns a brief
micro-strand (1-2 PBD particles) at the separation point that snaps
within 100ms. The audio + brief strand together read as adhesion-then-
release.

The wetness propagation in §4.6 is the source of `wetness_per_surface_region`
and `wetness_per_orifice` — no change to that math; the fluid system reads
those channels and drives decals + audio + strand spawn. Modulation of
friction by wetness (smear → friction modulator) is added to §4.4.

---

## 9.5. X-ray rendering

X-ray reveal is a skin-shader mask, not separate geometry. The hero skin surface reads `xray_mask` (a per-vertex or per-fragment falloff, typically a radial or box volume in hero-local space) and `xray_reveal_intensity` (from the `CharacterModulation` channel, §8.2).

Within the masked region, skin fragments transition to a translucent fresnel-rim appearance (silhouette preserved, strong at grazing angles) and may `discard` at high reveal intensity to let the mucosa surface behind them render naturally. The mucosa surface is already present in the continuous hero mesh (§10); no separate internal-anatomy meshes are instanced or toggled for x-ray purposes.

**Drivers.**
- Player-toggled: a player input writes directly to `xray_reveal_intensity` — e.g., button tap = 2s reveal and fade; hold = sustained.
- Reverie-triggered: at high `Ecstatic`, high `Lost`, and high `Aroused` state magnitudes, Reverie writes `xray_reveal_intensity` up to ~0.7 as a state-peak effect. Player input clamps on top to full 1.0.

**Aesthetic.** The cosmic / psychedelic direction (hero becoming visually permeable at peak states) is the intended feel; skin rim color and internal ambient glow are shader knobs tuned per-hero.

**Performance.** Negligible. Mucosa surfaces draw whether visible or not (they're part of the mesh); the shader mask costs a few instructions per skin fragment. No additional render passes.

**Cavity mesh visibility.** Cavity surfaces are never culled as a visibility group; the mask controls visibility through the skin. This keeps bulger-driven cavity deformation continuous even when x-ray is off (so if the player enables x-ray mid-encounter, internal state is already consistent).

---

## 10. Authoring

### 10.1 Tentacle mesh topology

- Cylindrical, aligned along +Z (conventionally)
- Origin at base center, base ring in z=0 plane
- ≥1 ring of vertices per 2cm of rest length (20+ rings for 40cm tentacle)
- Closed tip (capsule-like); base can be open
- Consistent radial vertex count per ring (8, 12, 16, or 24)
- Cylindrical UV unwrap: V = arc-length, U = angle

### 10.2 TentacleMesh authoring resource (GDScript, in `gdscript/procedural/`)

Authoring a tentacle is a **`Resource` with a base shape plus an array of features**. The `TentacleMesh` resource is `@tool`-driven: dragging a slider in the inspector rebakes the mesh at edit time; the result is saved as a static `ArrayMesh` referenced by `MeshInstance3D` at runtime. (Per §5.4 runtime regeneration is supported but not relied on for gameplay.)

Supersedes the earlier modifier-tree sketch. The historical proposal lives at `docs/proposals/TentacleMesh_proposal.md`.

#### Resource layout

```
TentacleMesh : Resource
├── length                                          (m)
├── base_radius, tip_radius                         (m, range guidance 0.005–0.5)
├── radius_curve : Curve                            (overrides linear taper when set)
├── radial_segments, length_segments
├── cross_section : enum                            (Circular / Ellipse(a:b) / NGon(n) / Lobed(count, depth))
├── twist_total : float                             (rad; optional twist_curve overrides linear)
├── seam_offset : float                             (radial angle owning the UV seam — placed dorsal, away from sucker rows)
├── intrinsic_axis : Vector3                        (must be -Z to match Tentacle::initialize_chain)
└── features : Array[TentacleFeature]               (applied in array order; vertex-color writes are last-writer-wins)

TentacleFeature : Resource (abstract)
├── enabled : bool
└── _apply(bake_context : BakeContext) : void       (subclass override)
```

A feature subclass declares which masks it writes (`_get_required_masks() -> PackedStringArray`); the bake validates ordering at edit time and warns if a feature reads a mask another feature later overwrites.

#### Feature catalog

**Geometry features** (modify topology / positions; only included when silhouette-defining):

| Feature | Properties |
|---|---|
| `SuckerRowFeature` | `count`, `position_curve`, `size_curve`, `side` ∈ {OneSide, TwoSide, AllAround, Spiral}, `rim_height`, `cup_depth`, `double_row_offset` |
| `KnotFieldFeature` | `count`, `spacing_curve`, `profile` ∈ {Gaussian, Sharp, Asymmetric}, `max_radius_multiplier` (modulates base radius; no extra topology) |
| `RibsFeature` | `count`, `spacing_curve`, `depth`, `profile` ∈ {V, U} (circumferential grooves) |
| `RibbonFeature` | `fin_count` (1/2/4), `radial_positions`, `width_curve`, `ruffle_frequency`, `ruffle_amplitude` |
| `SpinesFeature` | `count`, `angle_radial`, `angle_axial`, `length_curve`, `base_width`, `sharpness` |
| `WartClusterFeature` | `density` (per m²), `size_min/max`, `seed`, `axial_band`, `clustering_exponent` (geometry only for silhouette-meaningful sizes) |

**Mask-only features** (no topology change; vertex color authored, fragment shader interprets):

| Feature | Properties | Mask channel |
|---|---|---|
| `PapillaeFeature` | `density`, `axial_band`, `seed` | `COLOR.g` density |
| `PhotophoreFeature` | `count`, `distribution`, `emit_color` | `COLOR.b` mask + UV1 disc-space |

#### Tip and base

`TipFeature` (one per mesh) is a discriminated union:

- `Pointed(sharpness)` (default), `Rounded(radius)`, `Bulb(bulb_radius, bulb_length, neck_pinch)`
- `Canal(canal_radius, internal_depth)` — open-ended, exposes interior geometry. Used by ovipositor and storage-container paths. **Geometry only**; physics for the cavity is owned by §6 and reads `COLOR.a`'s canal-interior flag (see bake contract below). Interactive internal physics defers to Phase 8.
- `Flare(flare_radius, flare_length)`, `Mouth(petal_count, petal_curl, opening_radius)`

`BaseFeature`: `Flush` / `Collar(radius, length)` / `Flange`.

#### Bake-output contract (the channel layout shaders read)

| Channel | Meaning |
|---|---|
| `UV0` | Longitudinal U (base→tip), circumferential V |
| `UV1` | Per-feature local UVs (sucker disc-space, fin span). Multiple features share UV1; CUSTOM0 disambiguates. |
| `COLOR.r` | Sucker mask |
| `COLOR.g` | Wart / papillae density |
| `COLOR.b` | Fin / photophore mask |
| `COLOR.a` | Tip blend (smooth gradient, 0 mid-body → 1 at tip apex) |
| `CUSTOM0.x` | Feature ID (uint cast to float; `0` = body, `1+` = feature-specific) |
| `CUSTOM0.y` | Canal interior flag (binary, 1 inside canal lumen, 0 elsewhere) |
| `CUSTOM0.zw` | Reserved per-feature scalars |

**Reservation rule:** new features that need additional per-vertex data extend `CUSTOM1`/`CUSTOM2`; the bake header records which channels are in use, the fragment shader branches on `CUSTOM0.x` (feature ID).

#### Authoring rules

- **`SuckerRowFeature.side` interacts with `seam_offset`.** `seam_offset` defines the dorsal axis; "OneSide" / "TwoSide" radiate from it. The bake errors if suckers would land *on* the seam.
- **`intrinsic_axis = -Z` is canonical.** Matches `Tentacle::initialize_chain`'s particle layout. A freshly authored `TentacleMesh` drops into a `Tentacle` Node3D with no orient transform.
- **Feature ordering matters.** Features apply in array order; vertex-color writes are last-writer-wins per channel. Bake validates that no feature reads a channel a later feature overwrites.
- **Single material with shader-branched feature look.** Suckers, photophores, papillae all read the same `tentacle.gdshader`; vertex masks + feature ID drive the branch. No multi-slot until profiling shows shader branching costs > batching savings (Phase 9 review).
- **Silhouette-defining → geometry; sub-silhouette → shader mask** (per §5.0). Adding a "geometry" feature requires justifying the silhouette contribution.

#### Bake language

GDScript, in `gdscript/procedural/`. Edit-time only; no 60Hz cost. Sub-millisecond at typical density (~1k verts × ~5 features). C++ port deferred to Phase 9 if profiling shows inspector drag stalls.

#### Default presets

Provided as `.tres` resources under `gdscript/procedural/presets/`: `smooth.tres`, `ribbed.tres`, `bulbed.tres`, `multi_bulb.tres`, `barbed.tres`, `ovipositor.tres`. Phase-3 first cut ships only `smooth.tres` and `ribbed.tres`; the rest land per phase as the corresponding features are implemented.

#### Non-goals

- **LOD generation** — defer to Phase 9 polish.
- **Composition of multiple `TentacleMesh` resources into one** (e.g., chained tentacles via mesh merge) — Phase 9 polish if motivated.
- **Animating mesh-shape properties at runtime** — physics motion is the spline shader's job, not mesh rebakes.

### 10.2a TentacleMesh as a `PrimitiveMesh` subclass (UX fix)

This is a UX fix; it does not change the modifier model itself.

**Resource shape.** `TentacleMesh` is a `PrimitiveMesh` subclass (overrides `_create_mesh_array()`; calls `request_update()` from setters). Inspector edits regenerate live without per-set `ArrayMesh` allocation, fixing the slider-snap-back UX where setters that recreated `Mesh` / `Resource` triggered `notify_property_list_changed()` and dropped inspector focus.

**Workflow remains two-stage:**

1. **Edit time.** `TentacleMesh` is a `PrimitiveMesh` assigned to `MeshInstance3D.mesh`. Property edits trigger `request_update()`; the engine regenerates surface arrays lazily on the next draw. No baked output yet.
2. **Bake to ship.** A "Bake" inspector action freezes the current state into a static `.tres ArrayMesh` plus the auxiliary outputs (`girth_texture`, `rest_length`, mask channels). The static `.tres` is what ships. Runtime regeneration remains supported but is not the gameplay path (§5.4 unchanged).

**Auxiliary bake outputs unchanged.** Channel layout (UV0 / UV1 / COLOR.rgba / CUSTOM0) and girth-texture format are unchanged.

**Predecessor.** This supersedes the previous `TentacleMesh : Resource` shape used in §10.2's resource layout, and any earlier "TentacleMeshRoot Node3D with modifier child Nodes" authoring paradigm. The Node-tree pattern is retired — modifiers are part of the data model on `TentacleMesh` itself (see §10.2b).

### 10.2b Modifier model: kernel + repeat + falloff

Architectural change to the modifier data model, independent of §10.2a. Reframes §10.2's flat `features` list into a `modifiers` list with three primitive kernels.

**Resource layout (v1):**

```
TentacleMesh : PrimitiveMesh
├── length, base_radius, tip_radius, radius_curve
├── radial_segments, length_segments, cross_section
├── twist_total, twist_curve, seam_offset, intrinsic_axis_sign
├── distribution_curve : Curve            (controls non-uniform §3.6 init)
├── modifiers : Array[TentacleModifier]   (single flat list in v1)
└── tip_shape : TentacleTipShape          (separate library: Pointed, Bulb, Flare,
                                             Canal, Mouth, Rounded, …)

TentacleModifier : Resource (abstract)
├── enabled : bool
├── t_start, t_end : float                (arc-length range, [0..1])
├── feather : float                       (smoothstep falloff at boundaries)
├── kernel : enum { Ring, Vertex, Mask }  (a modifier may declare multiple)
├── repeat : int                          (1 = single instance; N = N copies)
├── falloff_curve : Curve                 (k=0 at first instance, k=1 at last)
├── radial_mask : enum { AllAround, OneSide, TwoSide, Spiral }
└── _apply(ctx, t_start, t_end, feather, repeat, falloff)
```

**Sections deferred to v2.** A `TentacleSection` resource with shared, feathered boundaries is an authoring grouping for tentacles with 12+ stacked modifiers. v1 ships with per-modifier `t_start` / `t_end` / `feather` directly on `TentacleModifier` — no grouping container, no section-boundary slider semantics. Promote to multi-section once authoring needs it; the kernel / repeat / falloff factoring is unchanged when that happens.

**Modifier kernels.** Three primitive kernel types cover the full feature catalog:

- `Ring` — per-axial radius / normal modulation, full ring (knot, ripple, taper override, local twist).
- `Vertex` — per-vertex offset as a function of `(arc_s, theta)` (wart, spine, sucker cup).
- `Mask` — writes to COLOR.rgba / UV1 / CUSTOM0 only (papillae, photophore, color band, sheen band).

A modifier may declare multiple kernel types (e.g. suckers = `Vertex + Mask`).

**Stacking rule.** Within the modifier list, ring-kernel offsets sum; mask-kernel writes max-blend per channel; vertex-kernel offsets sum. No exposed blend modes.

**Repeat + falloff.** Single primitive that wraps the kernel as a 1D instancer along the modifier's range:

```
for k in 0..repeat:
    local_t = lerp(t_start, t_end, k / max(repeat - 1, 1))
    scale   = falloff_curve.sample(k / max(repeat - 1, 1))
    apply_kernel(ctx, local_t, feather, scale * base_amplitude)
```

**`SuckerRowFeature` reframes as `SuckersModifier`** — same params (count, position_curve, size_curve, side, rim_height, cup_depth, double_row_offset), now operating in the modifier list with `kernel = Vertex + Mask`.

**Modifier catalog** (geometry + mask types — not all v1):

| Modifier                | Kernel(s)       | v1?                                                |
|---|---|---|
| `SuckersModifier`       | Vertex + Mask   | yes (rename of existing)                           |
| `KnotModifier`          | Ring            | yes (egg / sphere / ridged / custom-curve profile) |
| `RippleModifier`        | Ring            | later                                              |
| `RibsModifier`          | Ring            | later                                              |
| `WartClusterModifier`   | Vertex          | later                                              |
| `SpinesModifier`        | Vertex          | later                                              |
| `RibbonModifier`        | Vertex          | later                                              |
| `TwistOverrideModifier` | Ring            | later                                              |
| `PapillaeModifier`      | Mask            | later                                              |
| `PhotophoreModifier`    | Mask            | later                                              |
| `ColorBandModifier`     | Mask            | later                                              |
| `SheenBandModifier`     | Mask            | later                                              |
| `EmissionBandModifier`  | Mask            | later                                              |

**Validation against physics constraints** runs over the *aggregated* radius profile after all modifiers bake — soft amber zone before hard stop, with hover tooltip explaining which constraint (max girth-ratio per unit length, max twist rate, etc.).

**Tip shape library** is separate from the modifier list. Each tip shape is a small `Resource` with its own params (Pointed: nothing extra; Bulb: bulb_radius, taper_in_length; Flare: flare_count, flare_depth; etc.). Picked once per tentacle. The tip is silhouette-defining and lives in the mesh layer per §5.0.

### 10.3 Blender pipeline

For hero-asset tentacles:
1. Model along +Z axis
2. Cylindrical UV unwrap with V = arc-length
3. Export GLB
4. Assign mesh to `TentacleType` resource; girth texture auto-baked at resource load

### 10.4 Hero authoring

The hero is **one continuous mesh** with multiple material surfaces. The surface invaginates at each orifice to form the corresponding cavity wall, terminates at the cavity's closed end, or chains to another orifice (through-path). Normals are consistently outward across the whole surface — no duplicated or flipped vertices at rim edges.

Material assignment uses per-surface splits:
- Surface 0: exterior skin.
- Surface 1..N: cavity walls per anatomical region (oral, vaginal, anal, etc.), each with mucosa material.

Material boundaries are set at the rim edge loop or just inside it; the boundary doesn't have to align with the topological rim geometrically.

**Blender pipeline.** Orifice rim anchors and their skin weights are now authored in Blender (see §10.6 for the full pipeline and tooling). Summary:

1. Model hero mesh with standard humanoid skeleton (Auto-Rig Pro base; see §10.6).
2. Model cavities as invaginations of the same mesh — extrude inward at each orifice to form tunnel volumes terminating at closed ends or connecting to other orifices.
3. Assign skin material to exterior faces, mucosa materials to cavity faces. Material boundaries near the rim are fine either inside or on the edge loop.
4. Do NOT flip cavity normals. Normals should be outward-from-the-surface everywhere. Use "recalculate outside" with the mesh as a single closed topology.
5. For each orifice, run the Blender authoring script (§10.6) on the selected rim edge loop. It places `<Prefix>_Center` (use_deform = False, parented to the appropriate host deform bone — pelvis/hip for pelvic orifices, jaw for oral) and N `<Prefix>_Ring_i` deform bones at arc-length-regular intervals along the loop, with the consistent local frame (Y radial, Z axial, X tangent) per §6.1. N is a parameter of the script (default 8).
6. Paint rim and near-rim weights to the rim anchors — also handled by the Blender authoring script (angular-bracket interpolation between nearest anchors, radial falloff outward; innermost rim loop = full anchor weight, no body bone).
7. Optional: place empty objects as `TunnelMarker`s along internal paths if auto-derived centerlines need correction.
8. Export GLB with skeleton, the authored orifice bones, tunnel markers, and all material surfaces preserved. ARP export settings: Standard naming, toe breakdown on, "Rename bones for Godot" **off** (matches `docs/marionette/arp_mapping.md`).

**In Godot — `OrificeAutoBaker`.** Now a verification and struct-population pass, not a geometry-creation pass. Runs at hero import time or on demand:

1. **Verify** that each `OrificeProfile`'s authored bone references resolve in the imported skeleton: `<Prefix>_Center` exists, is non-deforming, and parents N `<Prefix>_Ring_i` deform bones (contiguous from 0 to N−1). Error with a clear message if any are missing — do not attempt to fabricate them.
2. **Populate the profile's ring table** from authored data: for each ring, read its rest-pose head offset from Center and record `(authored_angle = atan2(offset.x, offset.?_tangent_of_center), rest_radius = offset.length(), bone_idx)`. Sort by angle; this sorted table is what runtime uses for angle-bracket lookup (§6.1, §6.5).
3. **Derive the tunnel centerline** from the cavity mesh volume downstream of the rim (medial-axis extraction); fit a Catmull spline to the medial curve. Sample spacing tunable per-orifice.
4. **Compute the tunnel girth profile**: at each tunnel sample, cast perpendicular rays to find distance-to-wall; output a rest-radius profile along arc-length for type-3 collision.
5. **Populate `suppressed_bones`** with ragdoll capsules within N cm of Center (N tunable, default 0.15 m). Author can override.

Steps 3–5 are the only parts that derive new data; 1–2 just cache authored values into the runtime-friendly shape.

> **Reimport reminder.** Subresource assignments on the `OrificeProfile` live in memory only until Reimport is clicked. If the AutoBaker runs, remember to Reimport the scene so the populated ring table and tunnel data persist to disk.

**Manual override hooks** (for weird topology — non-manifold cavities, branching tunnels, cases where the authored bones are wrong or missing and you want to patch without re-exporting):
- `OrificeProfile.manual_rim_anchors: Array[NodePath]` — short-circuits step 1–2; supplies rim anchors (and authored offsets are still read from their rest positions).
- `OrificeProfile.manual_tunnel_spline: Resource` — short-circuits step 3 centerline derivation.
- `OrificeProfile.manual_suppressed_bones: Array[String]` — short-circuits step 5 auto-suppression.

When any manual override is set, that step's auto-derivation is skipped; other steps still run.

**In Godot — scene setup:**
- Instance the GLB, add `CharacterBody3D` + `Skeleton3D`.
- Add `PhysicalBone3D` nodes per ragdoll bone with capsules.
- Per orifice: add `Orifice` node referencing the authored `<Prefix>_Center` bone, assign the `OrificeProfile` (the AutoBaker fills in the ring table, tunnel spline/girth profile, and suppressed bones at bake time; runtime reads them).
- Configure `SkinBulgeDriver` on hero.
- Assign hero shader (handles skin + mucosa surfaces via per-surface materials, includes `tentacle_lib.gdshaderinc` for bulger deform).

**Ragdoll colliders:** start with capsules everywhere (auto-generated from bone lengths). Upgrade specific bones to convex hulls only where capsules fail visibly (hands, feet). Start collision layer: `ragdoll_body`. Tentacles don't collide with it directly via physics server — they read the per-tick snapshot and apply per-tentacle suppression lists.

### 10.5 Capsule suppression during interactions

When a tentacle has an active `EntryInteraction` with an orifice, specific ragdoll capsules are excluded from its type-1 collision queries. The `OrificeProfile` lists these by bone name. Typical:
- Mouth orifice → suppress jaw, neck, upper chest
- Torso orifice → suppress pelvis, hips, upper thighs

This is the mechanism enabling tentacles to go *inside* the body at the orifice without fighting internal ragdoll geometry.

Auto-suppression per §10.4 populates this list from proximity at bake time; manual override remains available via `OrificeProfile.manual_suppressed_bones`.

### 10.6 Authoring workflow — ARP + FaceIt + Godot export

The hero asset is assembled in Blender across three rigging systems that each own a subset of the deform skeleton, then exported to Godot as a single GLB. TentacleTech consumes the result; it does not author the base rig or the face rig.

**Base humanoid rig — Auto-Rig Pro (ARP).** Standard ARP is the canonical source for body bones (spine, limbs, fingers, toes). Marionette's humanoid profile maps against ARP's **Standard** naming (`.l`/`.r`/`.x` suffixes, `_stretch` on main limb segments) — the full ARP → profile table is in `docs/marionette/arp_mapping.md`. TentacleTech reads the same skeleton; it parents orifice Centers to ARP deform bones:

- **Pelvic orifices** (anal, vaginal) — parent `<Prefix>_Center` to the pelvis/hip deform bone (`root.x` in ARP Standard).
- **Oral orifice** — parent `<Prefix>_Center` to the jaw deform bone (owned by FaceIt, below).
- Other orifices — parent to the nearest anatomically meaningful deform bone.

**Face rig — FaceIt.** FaceIt owns the facial deform bones (jaw, eyes, blendshape drivers) and ARKit-compatible shape keys. TentacleTech's jaw orifice (§6.6) uses FaceIt's jaw bone as the hinge; the jaw is authored entirely by FaceIt and the `JawOrifice` reads `jaw_hinge_axis` / `jaw_rest_angle` / `jaw_max_angle` from the rig's rest pose. The oral orifice's `<Prefix>_Center` parents to the FaceIt jaw bone so the ring follows the mandible.

**Orifice bones — Blender authoring script.** Ring bones and their skin weights are authored by a dedicated Blender script, run after ARP + FaceIt rigging is complete. For each rim edge loop selected by the author, the script:

1. Creates `<Prefix>_Center` at the rim centroid (use_deform = False), parented to the author-specified host deform bone.
2. Walks the rim loop at arc-length-regular intervals, placing N `<Prefix>_Ring_i` deform bones (default N = 8; override per orifice). Placement is along the loop geometry itself — no assumption of circularity.
3. Aligns each ring's local frame to the §6.1 convention: Y radial outward, Z along the opening axis (Center's authored +Z), X tangent along the rim.
4. Paints rim + near-rim vertex weights: innermost loop = 100% ring weight, angular interpolation between the two bracketing rings, radial falloff outward to the host deform bone.
5. Validates: no `*_twist` / `*_leaf` bones under Center, Center is non-deforming, rim anchors are contiguous from 0 to N−1.

The script is canonical tooling for hero authoring — it will be pluginified (Blender addon) and committed under `tools/blender/` alongside its ARP/FaceIt integration notes. Until then, treat any ad-hoc ring placement as disposable; re-run the script rather than hand-editing.

**Export conventions.**

- **ARP Game Engine Export**, Standard naming, toe breakdown **on**, "Rename bones for Godot" **off** (matches `docs/marionette/arp_mapping.md`).
- The authored orifice bones are appended to the ARP deform skeleton *before* export; they pass through the ARP exporter as ordinary deform bones because they are not in ARP's internal rename table.
- FaceIt bones and shape keys are preserved via the FaceIt export path (GLB with shape keys + bone drivers).
- Empties (`TunnelMarker`s) are exported as GLB nodes parented to the skeleton, not merged into the mesh.

**Godot import.**

- `OrificeAutoBaker` (§10.4) verifies the authored bones and populates the profile's ring table, tunnel spline, and suppressed-bones list. It does not create or move bones.
- Subresource assignments on `OrificeProfile` are in-memory until **Reimport** is clicked — a known Godot gotcha. Always Reimport after AutoBaker runs or after any subresource assignment, or the populated ring table will be silently discarded on next project load.
- BoneMap keys for Marionette retargeting use `bone_map/` (underscore) not `bonemap/` — wrong key is silently overwritten (another Godot gotcha).

**Division of responsibility.**

| System    | Owns                                                        |
|-----------|-------------------------------------------------------------|
| ARP       | Body skeleton (spine, limbs, fingers, toes). Retarget source for Marionette. |
| FaceIt    | Face bones (jaw, eyes), ARKit shape keys. Source for `JawOrifice` rest data. |
| Blender orifice script | `<Prefix>_Center` + N `<Prefix>_Ring_i` bones, rim/near-rim skin weights. |
| Godot `OrificeAutoBaker` | Verification, ring-table population, tunnel centerline + girth profile, suppressed-bones list. |

---

## 11. File structure (C++/GDScript split)

```
extensions/tentacletech/
├── CLAUDE.md
├── SConstruct
├── tentacletech.gdextension
├── plugin.cfg                           # added Phase 3 — registers as EditorPlugin (§15.5)
├── plugin.gd                            # GDScript, registers EditorNode3DGizmoPlugins
│
├── src/                                # C++ (math-heavy, hot path)
│   ├── spline/
│   │   ├── catmull_spline.{h,cpp}
│   │   └── spline_data_packer.{h,cpp}
│   ├── solver/
│   │   ├── pbd_solver.{h,cpp}
│   │   ├── constraints.{h,cpp}
│   │   └── tentacle_particle.h
│   ├── collision/
│   │   ├── ragdoll_snapshot.{h,cpp}
│   │   ├── friction.{h,cpp}
│   │   ├── spatial_hash.{h,cpp}
│   │   └── surface_material.{h,cpp}
│   ├── orifice/
│   │   ├── entry_interaction.{h,cpp}
│   │   ├── orifice.{h,cpp}
│   │   ├── jaw_orifice.{h,cpp}
│   │   └── tunnel_projector.{h,cpp}
│   ├── bulger/
│   │   └── bulger_system.{h,cpp}
│   ├── stimulus_bus/
│   │   ├── stimulus_bus.{h,cpp}
│   │   ├── stimulus_event.h
│   │   └── modulation_state.h
│   └── register_types.{h,cpp}
│
├── gdscript/                           # GDScript glue (deployed to game/addons/)
│   ├── behavior/
│   │   ├── noise_layers.gd
│   │   ├── behavior_driver.gd
│   │   └── thrust_trajectory.gd
│   ├── control/
│   │   ├── tentacle_control.gd
│   │   ├── player_controller.gd
│   │   └── tentacle_ai.gd
│   ├── scenarios/
│   │   ├── scenario_preset.gd
│   │   └── scenario_library.gd
│   ├── stimulus/
│   │   ├── mechanical_sound_emitter.gd
│   │   └── fluid_strand.gd
│   ├── orifice/
│   │   ├── orifice_setup.gd
│   │   └── orifice_auto_baker.gd        # editor plugin — verification + profile struct population (§10.4)
│   ├── debug/                              # §15.1–4 — runtime overlay
│   │   ├── debug_gizmo_overlay.gd
│   │   └── gizmo_layers/
│   │       ├── particles_layer.gd
│   │       ├── constraints_layer.gd
│   │       ├── contacts_layer.gd        # phase 4+
│   │       ├── orifice_layer.gd         # phase 5+
│   │       ├── events_layer.gd          # phase 6+
│   │       └── bulgers_layer.gd         # phase 7+
│   ├── gizmo_plugin/                       # §15.5 — editor selection gizmos (added Phase 3)
│   │   ├── tentacle_gizmo.gd
│   │   ├── orifice_gizmo.gd             # phase 5+
│   │   └── bulger_gizmo.gd              # phase 7+
│   └── procedural/
│       ├── tentacle_mesh_root.gd
│       ├── ripple_modifier.gd
│       ├── knot_modifier.gd
│       └── ...
│
└── shaders/
    ├── tentacle.gdshader
    ├── tentacle_lib.gdshaderinc
    ├── hero_skin.gdshader
    └── girth_bake.glsl
```

**Rule of thumb:** anything running inside the 60 Hz physics tick and touching particles or constraints is C++. Everything else (AI, behavior, procedural generation, scenario presets, sound triggers, editor tooling) is GDScript.

---

## 12. Performance budget

Target: 60 Hz on Intel UHD / Steam Deck low / mobile Vulkan.

| System | Cost/tick | Notes |
|---|---|---|
| PBD solver, 12 tentacles × 32 particles × 4 iter | < 0.5 ms CPU | Core work |
| Spline rebuild + texture upload, 12 tentacles | < 0.3 ms CPU | |
| Ragdoll capsule snapshot (~15 capsules) | < 0.05 ms CPU | Once per tick |
| Collision broadphase (type 1) | < 0.15 ms CPU | AABB rejection first |
| Collision resolution + friction | < 0.25 ms CPU | |
| Orifice ring updates (~32 bones) | < 0.05 ms CPU | Spring-damper + driven positions |
| Bulger aggregation + spring update | < 0.1 ms CPU | 64 bulgers × spring |
| EntryInteraction updates (3 active typical) | < 0.05 ms CPU | |
| Stimulus bus event emission | < 0.05 ms CPU | Ring buffer push |
| Tentacle vertex shader (12 × 2k verts) | < 0.5 ms GPU | |
| Hero mesh vertex shader (skin + mucosa ~20k × 64 capsules) | < 1.1 ms GPU | Segment distance per bulger; still well under budget. Cavity surfaces add ~3–6k vertices to the hero mesh skinning pass (included). |

**Total: ~1.5 ms CPU + 1.3 ms GPU.** Under 20% of a 16.6 ms frame.

**Hard caps:**
- Concurrent tentacles: 16
- Bulgers per hero: 64
- Solver iterations: 6 (escalation only; default 4)
- Particles per tentacle: 48
- Tentacles per orifice: 3

**Realistic active-tentacle ranges (mid-range desktop, ~RTX 3060 class, 1080p, 60 Hz):**

| Scene | Active tentacles |
|---|---|
| Hero + tentacles, no orifice contact | 8–12 |
| Hero + tentacles, 1–2 orifice interactions | 6–8 |
| Heavy scenario (multiple orifices, tangle) | 4–6 |
| Same scene, after Marionette SPD ports to C++ | + ~50% |
| Steam Deck / mid laptop iGPU class | ~half of above |

Counts are *active* — idle / off-screen / asleep tentacles cost essentially nothing (PBD trivially sleeps; spline texture upload skips when no particle moved past epsilon). Treat all values as ±50% until Phase 4 (collision) and Phase 5 (orifice) are measured with a real hero present.

**Cost levers, in order of cost-effectiveness:**

1. Sleep when idle.
2. LOD iteration count (close: 8, mid: 4, far: 2).
3. LOD physics rate (60 / 30 / 15 Hz tiers by distance/relevance).
4. LOD mesh tessellation (cheap; mesh is GPU-skinned).
5. Port Marionette SPD to C++ (largest single CPU recovery; deferred).
6. Spatial-hash tuning (only relevant once tentacle↔tentacle is in).
7. Shader LOD (drop iridescence/SSS at distance).

**Lightweight wrapping-grade tentacle profile** — for "many tentacles wrap the hero" scenarios:

| Param | Hero-grade | Wrapping-grade |
|---|---|---|
| Particles | 32 | 12 |
| PBD iterations | 8 | 4 |
| Constraints | distance, bending, target, anchor, collision, friction, attachment | distance, bending, anchor, collision (no friction-in-iteration loop) |
| Tentacle↔tentacle (Type 7) | yes | **no** (wrappers pass through each other) |
| Orifice interaction | yes | no |
| Bulger contributions | yes | no |
| Mesh tessellation | 16 × 24 | 8 × 12 |
| Sleep aggressively | optional | mandatory |

A wrapper costs ~25–35% of a hero-grade tentacle. Acceptable budget shifts to ~12–18 wrappers + 2 leaders simultaneously active.

**Role swap is not free.** Promoting a wrapper to a leader (or demoting) requires constraint-stack rebuild — type-7 spatial hash registration, friction-iteration enable, bulger registration, orifice eligibility flip. For static role assignment per encounter this never pays. For dynamic role swap mid-encounter, expect a few hundred microseconds and a one-tick visible discontinuity. Don't author swaps in hot loops; if a chorus tentacle needs to become a leader mid-encounter, fade it out and spawn a fresh leader instead.

**Mass-wrap encounter pattern: leaders + chorus.**

- **2–4 TentacleTech leaders** physically grab and constrain the hero (bilateral compliance, friction, asymmetry, orifice work, bus events).
- **Surrounding mass of Tenticles tubes** (visual chorus) anchored to environment geometry, attracted to hero silhouette via voxelized SDF (`docs/tenticles/Tenticles_design.md` §1.7), with curl noise. Cannot apply force — purely visual mass.
- **Termination trick:** place a few Tenticles tube tips near the leader contact points so the eye reads the whole tangle as one mass.
- **Bus coupling stays at user level.** Tenticles does **not** subscribe to `StimulusBus`. User-level GDScript glue reads the bus and writes Tenticles' public params (curl-noise amplitude, attractor radius, etc.). Tenticles remains self-contained per its existing scope boundary (`docs/tenticles/Tenticles_design.md` §0).

Hard scope boundary unchanged: Tenticles never collides with, attaches to, or applies force to the hero. Anything that touches the hero physically is TentacleTech.

---

## 13. Phase plan

Phase 1 is the immediate focus. Subsequent phases are each self-contained and testable.

**Phase 1 — Spline primitives** (scavenge from DPG)
1. `CatmullSpline` class with full API (§5.1)
2. `SplineDataPacker` utility
3. Unit tests for spline math accuracy
4. Acceptance: spline math matches analytical reference within 0.1%

**Phase 2 — PBD core**
5. `TentacleParticle`, `PBDSolver` with distance, bending, anchor, target-pull constraints
6. Basic single-tentacle `Tentacle` Node3D
7. Phase-2 snapshot accessors and minimum gizmo overlay (§15.2, §15.3)
8. Acceptance: stable at 60 Hz; volume preservation visible (gizmo color shift on stretch); responds to target pull (gizmo arrow tracks tip movement)

**Phase 3 — Mesh rendering**
8. Vertex shader + shader include (`tentacle_lib.gdshaderinc`)
9. Auto-baked girth texture from mesh geometry
10. Procedural generator (GDScript) with base presets
11. EditorPlugin (§15.5) — `plugin.cfg` + `plugin.gd` + `gdscript/gizmo_plugin/tentacle_gizmo.gd` for selection-time gizmos in the editor
12. Acceptance: mesh smoothly follows spline, squash/stretch visible, no twisting; selecting a `Tentacle` in the editor draws its rest-pose gizmos

**Phase 4 — Collision and friction**
12. Ragdoll snapshot
13. Type-1, type-4 collision
14. Unified friction projection
14a. **Multi-contact probe + Jacobi+lambda solver loop** (slice 4M; per-particle manifold up to 2 contacts via iterated `get_rest_info` + exclude list, Jacobi-with-atomic-deltas-and-SOR position accumulator, per-contact persistent `normal_lambda` + `tangent_lambda` accumulators replacing the per-particle dn budget; lifted from Obi `ContactHandling.cginc` + `AtomicDeltas.cginc` + `ColliderCollisionConstraints.compute`)
14b. **XPBD compliance on the distance constraint** (slice 4M-XPBD; canonical Macklin form per Obi `DistanceConstraints.compute`, per-segment lambda buffer reset in `predict()` per outer tick — required for repeated-solve position correctness)
14c. **Fresh-this-tick contact snapshot** (slice 4N; `Tentacle::get_in_contact_this_tick_snapshot()` written between probe and iterate, gives consumers running between those points one-tick-fresh manifold flags)
14d. **Sub-stepping for thrust frames** (slice 4O; promoted from Phase 9 polish — outer-frame substep loop with displacement-driven heuristic floor, friction_applied accumulates across substeps via `reset_friction_applied`, reciprocal impulse uses outer dt for correct momentum)
14e. **Sleep threshold + max depenetration cap** (slice 4P; settle in-contact particles below `||position − prev_position||² ≤ (threshold·dt)²` by snapping to `prev_position`; cap per-iter normal-lambda growth to `max_depenetration · dt` so deep penetrations resolve over multiple ticks not one explosive frame)
15. Acceptance: tentacles don't phase through hero, drag-along behavior, stick-slip visible on ribbed tentacles, settled chains converge under multi-contact wedge geometry without per-tick flicker, thrust scenarios with target stiffness ≥ 0.5 don't tunnel through static walls

**Phase 4 close-out cluster reference docs** (all 2026-05-03): plan in `Cosmic_Bliss_Update_2026-05-03_phase4_wedge_robustness.md`; Obi 7.x source synthesis in `docs/pbd_research/findings_obi_synthesis.md`. Phase 4 fully landed 2026-05-03; Phase 5 unblocked.

**Phase 5 — Orifice system** (rim particle loop model per `Cosmic_Bliss_Update_2026-05-03_orifice_rim_model.md`; supersedes the pre-2026-05-03 driven 8-direction ring-bone draft)
16. Rim anchor authoring + skin weighting in Blender (rim anchors are kinematic targets for rim particle rest positions in Center frame, NOT driven outputs; mesh skin weights bind to anchor names but skinning shader reads live rim particle world positions)
17. `RimParticle` / `RimLoopState` data structures + `Orifice` C++ owning per-loop XPBD constraint set (closed-loop distance + volume on enclosed area + per-particle spring-back to authored rest position + soft attachment to host bone via orifice frame)
18. Multi-loop per orifice — single (default), outer + inner anatomical, decorated rim (jewelry + anatomical opening), compound openings (multi-sphincter tunnels for peristalsis); inter-loop coupling springs authored per-pair, optional
19. EntryInteraction + bilateral compliance via per-particle stiffness distribution (single tentacle first; multi-loop authoring path open)
20. Type-2, type-3 collision (orifice rim is the closed PBD loop; tunnel walls; straight tunnels first); reaction-on-host-bone closure per-rim-particle with the existing wedge math
20a. Realism sub-slices from `Cosmic_Bliss_Update_2026-05-03_obi_realism_and_orifice.md` §4: **4P-A** one-sided XPBD distance for compress > stretch anisotropy (Obi tether pattern); **4P-B** strain-stiffening J-curve on rim spring-back; **4P-C** slow rest-position recovery for orifice memory
21. Acceptance: tentacle penetrates, rim deforms with continuous (non-faceted) silhouette under load, multi-loop configurations (outer + inner) supported, orifice memory persists across attempts, glancing approaches slide off the rim naturally without scripted angle gates

**Phase 6 — Stimulus bus + mechanical sound**
21. StimulusBus autoload with events, continuous channels, modulation channels
22. MechanicalSoundEmitter components
23. Body area mapping per hero
24. Acceptance: physics events produce spatial sounds, bus events visible in debug overlay

**Phase 7 — Hero skin bulges**
25. SkinBulgeDriver + bulger shader
26. Internal bulgers from penetrating tentacles
27. External bulgers from surface contacts
28. Spring-damper bulger state
29. Acceptance: skin bulges visible, normal-direction displacement looks right, jiggle on rapid motion

**Phase 7.5 — Capsule bulgers and x-ray**
29a. Replace sphere bulger uniform with capsule arrays (§7.1).
29b. Per-segment capsule emission for internal bulgers (§7.2).
29c. Priority tiers (§7.6).
29d. X-ray skin shader mask and `xray_reveal_intensity` modulation plumbing (§9.5).
29e. Acceptance: tube-shaped deformation visible along tentacle length on both skin and cavity surfaces; x-ray toggle reveals internal deformation cleanly.

**Phase 8 — Multi-tentacle + curved tunnels + advanced**
30. Multi-tentacle per orifice (EntryInteraction list)
31. Type-5 collision (always on inside orifices)
32. Type-6 attachment constraints (limb grabbing)
33. Curved tunnels with tunnel-bone pressure distribution
34. Jaw special case
35. Fluid strands on separation
36. Storage chain (§6.8): bead types, pinned PBD subchain, multi-bead distance constraints, through-path linking.
37. Oviposition (§6.9): `OvipositorComponent`, deposit queue, tip-threshold deposit trigger, tentacle-root bead spawn.
38. Birthing (§6.9): peristalsis modulation channels, ring-transit reuse of §6.3, tentacle-root release on expulsion.
39. Acceptance: all 10 narrative scenarios from `TentacleTech_Scenarios.md` reproducible, plus Scenario 12 (oviposition cycle) and Scenario 13 (excreted tentacle, free float).

**Phase 9 — Polish**
37. Tentacle-vs-tentacle outside orifices (optional)
38. ChainConstraints direct tridiagonal solver for *free-air* (non-contact) chain segments — promoted from Obi 7.x research (`pbd_research/findings_obi_synthesis.md`); O(N) one-pass exact for pure chains, but doesn't compose with multi-contact softening, so contact-touching segments stay on per-segment XPBD
39. Per-region bulger stiffness
40. CCD against capsules (only if 4O sub-stepping proves insufficient for thrust scenarios; 4O typically makes this unnecessary)
41. Profile on low-end hardware, cut iteration counts as needed

---

## 14. Gotchas and non-negotiable rules

**Non-negotiable:**
- Snapshot ragdoll capsules ONCE per tick. Never during PBD iterations.
- Position-based friction inside iterations. No force-based between ticks.
- No per-frame `ArrayMesh` rebuilds. Ever.
- No per-frame `ShaderMaterial` allocation. Create once per tentacle.
- Unique `ShaderMaterial` per tentacle instance; shared `.gdshader`.
- Data textures (RGBA32F) for spline data — no SSBOs in spatial shaders in Godot 4.6.
- godot-cpp pre-compiled at `../../godot-cpp/`. Don't rebuild.
- Hero mesh is a single continuous invaginated shell. Do not author cavity meshes as separate `MeshInstance3D`s. Do not duplicate or flip normals at rims.
- Excreted tentacles are `Tentacle` instances with the "Free Float" preset. Do not use `PhysicalBone3D` chains.
- Storage bulgers are never evicted while their region is on-camera. Respect the priority tier.

**Gotchas:**
- **Tunneling at high velocity:** outer-frame substep loop (slice 4O, 2026-05-03) auto-bumps the per-frame substep count when worst-case predicted displacement (gravity·dt² + singleton-target snap) exceeds `0.5 × collision_radius`. `substep_count` @export on Tentacle/TentacleMood is a FLOOR (heuristic can exceed it), hard-capped at 4. Pose-target driven thrust intentionally omitted from the heuristic — thrust-heavy moods set `substep_count` manually (typical 2-4). Strict no-tunnel guarantee requires CCD against capsules (Phase 9, only if sub-stepping proves insufficient).
- **Multi-contact wedge:** chain particle pinched between two solid colliders requires multi-contact probe + per-contact lambda accumulator (slice 4M, 2026-05-03; `MAX_CONTACTS_PER_PARTICLE = 2`). Single-normal projection would oscillate at any wedge half-angle below ~80° because the cached "nearest" contact flips per-tick. Jacobi+SOR position-delta averaging handles N contacts naturally without bisector heuristics; the per-contact `normal_lambda` accumulator scales each slot's friction cone independently.
- **Anti-parallel pinch (n0·n1 < −0.5)** is geometrically degenerate: both contact projections cancel under Jacobi averaging — PBD has nothing to push against. Friction zeroes out by design (no useful tangent direction). Detect and emit a `pinched` event on the bus (Phase 6) rather than thrashing the iterate loop. Particle stays at the pinch point; this is correct.
- **Fresh-contact snapshot vs last-tick snapshot:** `PBDSolver::get_particle_in_contact_snapshot()` reflects the previous tick's iterate-loop flags (gated on `inv_mass > 0`). Behavior drivers reducing stiffness on contact should consume `Tentacle::get_in_contact_this_tick_snapshot()` (slice 4N, 2026-05-03; written between probe and iterate, fires for any particle within probe range including pinned). The two accessors have different semantics by design — choose by use case. Process-order requirement: drivers consuming the fresh accessor must run their `_physics_process` after the Tentacle's; default parent-first ordering when the driver is a child of the Tentacle gives this for free.
- **`predict()` clears `in_contact_this_tick`:** the `target_softness_when_blocked` modulation in iterate step 2 (slice 4M-pre.2) reads the flag set by the *previous* iter's collision step, so iter 0 of every tick pulls at full strength regardless of contact state — a 1-iter latency on the softening. Acceptable for headless tests (steady-state convergence dominates); flagged for future work if a scenario shows soft-vs-stiff difference invisibly.
- **Orifice boundary flipping:** hysteresis on "inside tunnel" vs "outside" — enter at 5cm past plane, exit at 2cm outside.
- **Double-counting at orifice entry:** type-1 capsule collision is suppressed per-particle for capsules in the orifice's `suppressed_bones` list. Prevents particle feeling both capsule push and ring compression.
- **Friction resonance/jitter:** high `μ_s` with low iteration count oscillates at the cone boundary. Add 5% dead-band around static cone threshold.
- **Ring runaway:** hard clamp on `current_radius` prevents spring from pushing past anatomical limits. Velocity zeroed at clamp.
- **Attachment slip compounding:** slip accumulates; after `max_slip_from_original` drift, detach entirely rather than re-anchor further.
- **PhysicalBone3D scale bug** (existing Godot bug): tentacle root must remain at scale 1. Document in setup.
- **Suspension tentacles must be anchored to environment geometry, not to another character's ragdoll bone.** Hero gravity transmitted through a single Marionette joint (typically the lumbar) exceeds the active-ragdoll torque budget and produces visible jitter or collapse. Anchor to ceiling / wall / static level mesh. Unrelated to the tentacle chain itself, which transmits force fine through PBD distance + anchor constraints.
- **Suspension requires a girth differential, not just compression.** A smooth shaft compressed past the rim transmits no radial reaction force into the chain — the rim is kinematic, contact projection only fires when a particle is geometrically inside the deformed rim. Suspensions must use a tentacle with a knot, bulb, ridge, or other girth differential straddling the rim. Author scenarios accordingly.
- **No `accept_penetration`-style hard refusal levers exist.** If a scenario seems to need one, raise stretch_stiffness, raise grip strength, lower wetness, or write the appropriate `OrificeModulation` channels. See §1.
- **Glancing-approach rejection** is now modeled (resolved 2026-05-03 by the rim particle loop amendment in §6.1). The rim is a connected closed loop of N PBD particles; type-2 collision treats it as a real curved surface; glancing tentacles slide off it via the standard soft-physics friction path. The 8-discrete-radial-bone limitation that motivated this gotcha is gone.

**What not to do:**
- Don't use `MeshDataTool` in hot paths
- Don't use `SoftBody3D`
- Don't use `MultiMesh` for tentacle instancing (each needs unique deforming mesh)
- Don't copy DPG's `Penetrator`/`Penetrable` naming (use `Tentacle`/`Orifice`)
- Don't author girth profiles manually (auto-baked from mesh)
- Don't generate Godot test scenes without explicit user confirmation. Confirmed scenes must stay simple: node tree + scripts + a few `@export` numbers. No animation tracks, `AnimationPlayer`/`AnimationTree`, baked lighting, side-authored Resource files, or rigged characters — those need a separate explicit ask

---

## 15. Debug visualization

A physics-driven emergent game cannot be developed blind. Debug gizmos are a cross-cutting system that grows with each phase, not a separate phase.

### 15.1 Architecture

- **C++ exposes read-only snapshot accessors.** Particle positions, segment stretch ratios, contact lists, ring extensions, bulger capsule transforms, etc. The same accessors that unit tests use.
- **GDScript `DebugGizmoOverlay` reads accessors per-frame and rebuilds an `ImmediateMesh`** for line/point geometry; `Label3D` (or a pooled set) for floating annotations. One `MeshInstance3D` per overlay layer.
- **Toggleable.** F-key by default; settings flag for persistent on. Layers individually maskable (particles/constraints/contacts/orifices/bulgers/events).
- **Zero cost when off.** Overlay visibility flag short-circuits the per-frame rebuild. The C++ accessors are always available — emission cost is on the GDScript reader, not the solver.
- **Never bake gizmo emission into the hot path.** No `if (debug) draw_line(...)` inside PBD iterations. Pull, never push.

### 15.2 Accessor contract (per phase)

Each phase that lands physics state also lands the snapshot accessors that gizmos and tests both consume. Naming convention: `Tentacle.get_*_snapshot()` returns a copy or `PackedArray` view; never live pointers into solver state.

| Phase | Accessors |
|---|---|
| 2 — PBD core | `Tentacle.get_particle_positions()` → `PackedVector3Array`<br>`Tentacle.get_particle_inv_masses()` → `PackedFloat32Array`<br>`Tentacle.get_segment_stretch_ratios()` → `PackedFloat32Array`<br>`Tentacle.get_target_pull_state()` → `Dictionary { active, target, particle_index, force_dir }`<br>`Tentacle.get_anchor_state()` → `Dictionary { particle_index, world_xform }` |
| 3 — Mesh | `CatmullSpline` is already a public class; overlay calls `evaluate_position` and `evaluate_frame` at sample t∈[0,1] |
| 4 — Collision | `Tentacle.get_contact_snapshot()` → `Array[Dictionary]` per particle in contact: `{ point, normal, penetration_depth, friction_state ∈ STICK/SLIP/FREE, friction_displacement, surface_id }`<br>`Hero.get_ragdoll_capsules()` → `Array[Dictionary]` for wireframe rendering |
| 5 — Orifice | `Orifice.get_rim_loop_state(loop_index)` → `Array[Dictionary]` per rim particle: `{ rest_position, current_position, current_velocity, pressure, spring_lambda }`<br>`Orifice.get_rim_loop_count()` → `int`<br>`EntryInteraction.get_state()` → `Dictionary { tentacle_id, depth, rim_pressures_per_loop, bilateral_phase }` |
| 6 — Stimulus bus | `StimulusBus.get_recent_events(time_window)` → `Array[StimulusEvent]` (already public for Reverie) — overlay draws timed-fade `Label3D` at event position |
| 7 / 7.5 — Bulgers | `BulgerSystem.get_active_bulgers()` → `Array[Dictionary]` per bulger: `{ capsule_a, capsule_b, radius, squish, priority_tier, source_kind }` |

Snapshot accessors are part of phase acceptance, not optional polish. They land with the physics they describe.

### 15.3 Gizmo set (cumulative)

| Phase | Gizmos added |
|---|---|
| 2 — PBD core | Particles as spheres (color = `inv_mass`: red = pinned, white = free, gradient between); distance constraints as line segments (color hue = stretch ratio: blue = compressed, white = rest, red = stretched); bending angle arcs at every triple (subtle); target-pull arrow from particle to target; anchor markers at pinned particles; spline polyline (16 samples) with TBN frames at sample points |
| 3 — Mesh | Girth profile read-back as a halo around the spline at each sample; mesh wireframe toggle |
| 4 — Collision | Ragdoll capsule wireframes (yellow); contact points as spheres at hit location with normal arrows; friction cone wireframes per contact (cone half-angle = atan(μ_s)); friction displacement arrows; per-particle friction state badge (STICK = green, SLIP = orange, FREE = invisible) |
| 5 — Orifice | Ring bones as 8-point circles, color hue = `current_radius / rest_radius`; spring extension as radial bar from rest to current radius; EntryInteraction tentacle-membership lines from tentacle particles to associated rings; bilateral compliance phase as concentric ring color pulse |
| 6 — Stimulus bus | Stimulus events as floating `Label3D` at emission point, fade over 1s; modulation channel values as a corner HUD bar graph |
| 7 / 7.5 — Bulgers | Capsule wireframes at bulger transforms, color = priority tier (storage = magenta, internal = cyan, external = green); squish factor as radius scale visible in wireframe; eviction-fade alpha follows §7.5 timing |

### 15.4 Implementation rules

- **Pull, never push.** The solver does not know the overlay exists.
- **One `MeshInstance3D` per layer**, owning one `ImmediateMesh` rebuilt per `_process` (not `_physics_process`). Sub-tick interpolation is unnecessary for debug; visual lag of one frame is fine.
- **Pool `Label3D`s** rather than create/free per emission. Stimulus event labels are the only floating text source; ~32 pooled instances suffice.
- **Use a single `StandardMaterial3D` per layer** with `vertex_color_use_as_albedo = true`; encode color in vertices, not per-line materials.
- **Layer masks expose individually** (particles, constraints, contacts, orifices, bulgers, events). Default-on layers depend on the active phase during development; everything off in shipped builds.
- **Overlay lives in `gdscript/debug/`** — it is GDScript, not C++. No reason to put a debug renderer in the hot path's language.

### 15.5 Editor gizmo plugin (companion to the runtime overlay)

The runtime overlay covers debugging during simulation. For *authoring* — dropping a `Tentacle` or `Orifice` into a scene and seeing its structure in the editor on selection — TentacleTech also ships an `EditorPlugin` that registers an `EditorNode3DGizmoPlugin` per physics class. **All GDScript** in `gdscript/gizmo_plugin/`, alongside `plugin.cfg` + `plugin.gd` at the addon root.

Two things to keep straight:

| Concern | Runtime overlay (§15.1–4) | Editor gizmo plugin (§15.5) |
|---|---|---|
| When | Runs at simulation time | Editor selection only |
| Surface | `DebugGizmoOverlay` Node3D added to a scene | Auto-renders when a registered class is selected in the editor |
| Source of truth | Snapshot accessors (§15.2) | Same snapshot accessors |
| Authoring concern | Useful during gameplay debugging | Useful at scene construction |
| Registers via | Just sits in the scene tree | `EditorPlugin._enter_tree` adds an `EditorNode3DGizmoPlugin` subclass |

**Gizmo plugin scope (cumulative, mirrors §15.3):**

| Phase | Editor gizmo for |
|---|---|
| 3 | `Tentacle` — particles + constraint segments + spline polyline + TBN frame at samples |
| 5 | `Orifice` — rim particle loops (multi-loop), bilateral compliance state |
| 7 / 7.5 | Bulger emitters at authoring time (cavity capsules in rest pose) |

**Implementation rules:**

- One `EditorPlugin` (`plugin.gd`) owns registration; one `EditorNode3DGizmoPlugin` subclass per physics class type, in `gdscript/gizmo_plugin/<class>_gizmo.gd`.
- Gizmo `_redraw(gizmo)` reads the same `Tentacle.get_*_snapshot()` accessors the overlay uses. No data path duplication.
- Gizmo refresh on transform change is automatic; for live-updating during `@tool` simulation in editor, the node calls `update_gizmos()` after each tick. (Trivial; one line at the end of `_physics_process` gated by `Engine.is_editor_hint()`.)
- Editor gizmos do **not** replace the runtime overlay. Both ship in the same addon. The user picks based on whether they're authoring or simulating.

---

This document is the specification. The scenarios document covers what the system produces. The Reverie planning document covers the future reaction-system integration.
