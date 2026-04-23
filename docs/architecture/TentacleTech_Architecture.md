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

---

## 2. System at a glance

```
┌──────────────────────────────────────────────────────────────────┐
│  HeroCharacter (CharacterBody3D + Skeleton3D)                   │
│  ┌──────────────────┐  ┌──────────────────────────────────┐    │
│  │ Ragdoll bones    │  │ Orifices (N per character)       │    │
│  │ + orifice rings  │  │ - ring bones (spring-damper)     │    │
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
3. **Orifice** — directional ring bones, EntryInteraction, bilateral compliance, multi-tentacle
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
    for each ring direction d with nonzero pressure:
        direction_local = world_to_particle_frame(ring_direction_d)
        particle.asymmetry -= direction_local.xy × pressure_d × dt × responsiveness
    
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
| 4 | Particle vs environment | Limited raycasts (3 per tentacle per tick) | Project out of surface along hit normal | Yes |
| 5 | Particle vs tentacle particle | Spatial hash (always on inside orifices) | Push apart symmetric, half each | Yes |
| 6 | Tentacle surface vs grab target | Explicit attachment constraint with slip | Particle pinned to target with friction-limited slip | Yes |
| 7 | Tip vs closed surface (probing) | Same as #1 until orifice boundary crossed | Same as #1 | Yes |

**Type 2 (orifice rim) is not a simple particle-surface projection.** It operates through the `EntryInteraction` and directional ring model. See §6.

**Type 6 (attachment) is how tentacles grab limbs.** Particle is pinned to a point on a target surface (ragdoll bone, static geometry, another tentacle). Attachment holds while tangential force is within static friction cone; breaks with slip accumulation.

### 4.3 Unified PBD friction projection

After normal correction for any collision type, apply friction to tangential displacement:

```
// Normal correction already applied:
Δn = magnitude of normal projection (positive)

// Tangential displacement since last tick
Δx = particle.position - particle.prev_position
Δx_tangent = Δx - (Δx · n) × n
tangent_mag = length(Δx_tangent)

// Friction cones
μ_s = compose_static_friction(surface_pair, modulators)     // §4.4
μ_k = μ_s × 0.8                                             // typical ratio
static_cone = μ_s × Δn
kinetic_cone = μ_k × Δn

if tangent_mag < static_cone:
    // Inside static cone: cancel tangential motion
    particle.position -= Δx_tangent
    friction_applied = Δx_tangent
else:
    // Outside static cone: cap to kinetic
    scale = 1.0 - (kinetic_cone / tangent_mag)
    particle.position -= Δx_tangent × scale
    friction_applied = Δx_tangent × scale
```

**This single block handles stick-slip, grip, rib modulation, and all surface interactions.** There is no state machine. The friction cone *is* the state — whether tangential motion falls inside or outside of it is computed each iteration from current values.

For each friction projection on a type-1 collision, the friction displacement is also applied as an equal-and-opposite impulse on the contacted ragdoll bone:

```
impulse_friction = friction_applied × effective_mass / dt
bone.apply_impulse_at_position(impulse_friction, contact_point)
```

Heavy tentacle dragging across skin pulls the hero's skin (and the bone under it) in the drag direction. This is where the "tentacle friction makes the hero move" feel comes from.

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

### 5.4 Auto-baked girth (no manual profile authoring)

The rest girth is **baked from mesh geometry automatically.** No `Curve` resource needed. The process:

1. After mesh import or procedural generation, iterate over the mesh vertices
2. For each ring of vertices (grouped by arc-length), compute max radial extent
3. Output a 1D texture (256 samples typical) of `radial_extent(arc_length)`
4. This texture is read by the physics code when it needs "girth at arc-length t" — for example, when computing EntryInteraction compression

The mesh's geometric detail (knots, ripples, bulbs) determines the girth profile implicitly. Physics and rendering are consistent because both derive from the same mesh.

**Procedural generator** (GDScript) outputs both mesh and bakes the girth texture in one step. **Blender-imported** meshes have the bake run automatically at resource load time by a small helper class.

Surface detail (ribbing, veins, scales) is mesh geometry — rides along with the lateral XY offsets and is scaled by the runtime `girth_scale` and asymmetry. No detail texture needed; concavities and full 3D surface features work naturally.

---

## 6. Orifice system

### 6.1 Ring bone structure

Per orifice on the hero, the rim is an edge loop of the continuous hero mesh at the point where the surface invaginates. Eight radial ring bones are placed at equal angular spacing around this rim loop, parented to a per-orifice center bone, which is parented to the nearest ragdoll bone. The rim is a single edge loop shared between the skin surface and the mucosa surface of the same mesh; skinning weights on that loop follow the ring bones, so ring-bone motion deforms skin and mucosa together at the rim.

```
<host_ragdoll_bone>                       (parent, e.g., "Pelvis")
└── Orifice_<n>_Center                    (opening center, aligned with opening axis)
    ├── Orifice_<n>_Ring_0                (8 radial bones at rest_radius)
    ├── Orifice_<n>_Ring_1
    ...
    └── Orifice_<n>_Ring_7
```

Ring bones are **driven, not simulated** — their positions are set directly by the orifice tick. No physics joints, no springs between bones.

Skin around the opening is weight-painted to the ring bones (angular interpolation between 2 nearest ring bones by angle, radial falloff outward). Moving a ring bone stretches the skin locally. See §10.4 for authoring.

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

    // Per-direction ring state (8 directions)
    float      orifice_radius_per_dir[8];
    float      orifice_radius_velocity[8];

    // Persistent state (hysteretic — reason the interaction object exists)
    float      grip_engagement;           // 0..1 ramps over time
    bool       in_stick_phase;            // friction state machine
    float      damage_accumulated_per_dir[8];

    // Forces computed this tick
    float      radial_pressure_per_dir[8];
    float      axial_friction_force;
    Vector3    reaction_on_ragdoll;
};
```

Lifecycle:
```
each tick:
    orifice finds all tentacles whose spline crosses its entry plane
    for each pairing:
        if EntryInteraction exists → reuse (preserves hysteretic state)
        else → create new, grip_engagement = 0
    update geometric state for each
    compute forces (§6.3)
    apply forces to tentacle particles, ring bones, ragdoll
    if tentacle withdrew completely → mark for retirement after grace period
```

### 6.3 Bilateral compliance

Tentacle-and-orifice deformation share pressure based on relative stiffness:

```
for each ring direction d:
    // Aggregate demand if multi-tentacle (§6.5)
    required_radius_d = compute_aggregate_demand(d)  // max over all tentacles
    
    gap = orifice.radius_per_dir[d] - required_radius_d
    if gap >= 0:
        // No contact in this direction
        pressure_per_dir[d] = 0
    else:
        compression = -gap
        // Nonlinear stretch (tissue-like stiffening above rest)
        stretch = max(0, orifice.radius_per_dir[d] - effective_rest_radius[d])
        effective_orifice_k = orifice.stretch_stiffness × pow(
            1.0 + stretch / rest_radius,
            orifice.stretch_nonlinearity - 1.0)
        
        // Springs in series
        effective_k = 1.0 / (1.0/tentacle.girth_stiffness + 1.0/effective_orifice_k)
        pressure_per_dir[d] = compression × effective_k
        
        // Allocate deformation by stiffness ratio
        orifice_share = tentacle.girth_stiffness / (tentacle.girth_stiffness + effective_orifice_k)
        
        // Apply to orifice (target radius delta)
        target_radius_per_dir[d] += pressure_per_dir[d] × orifice_share × dt
        
        // Apply to tentacle (asymmetry delta, §3.4)
        write_asymmetry_to_near_particles(d, pressure_per_dir[d] × (1 - orifice_share))
```

A rigid tentacle against a soft orifice: orifice stretches a lot, tentacle barely compresses. Soft tentacle against rigid orifice: tentacle flattens, orifice barely stretches. Same equation.

### 6.4 Spring-damper ring dynamics

Ring bones are NOT assigned directly to target radii. Each direction has its own spring-damper:

```
for each ring direction d:
    target_radius[d] = <from §6.3>
    
    // Spring toward target
    spring_force = (target_radius[d] - current_radius[d]) × ring_spring_k
    damping_force = -current_radius_velocity[d] × ring_damping
    
    current_radius_velocity[d] += (spring_force + damping_force) × dt
    current_radius[d] += current_radius_velocity[d] × dt
    
    // Hard clamp (runaway protection)
    current_radius[d] = clamp(current_radius[d], rest_radius × 0.3, max_radius × 1.2)
    if at clamp: current_radius_velocity[d] = 0
    
    // Optional axial drag from high friction (creates funnel deformation)
    axial_offset = compute_axial_drag(tentacle_friction_direction, drag_coupling)
    
    // Drive the bone
    bone_local_position = direction_vec[d] × current_radius[d] + orifice_axis × axial_offset
    skeleton.set_bone_pose_position(ring_bone[d], bone_local_position)
```

**This is where pull-out jiggle, retention, and wobble come from for free:**
- Fast retraction → target drops → spring lags → ring trails outward briefly → snaps back with damped oscillation
- Thick bulge inside → target rises when bulge approaches entry → ring resists → friction + compression produce retention

**Per-orifice tunables:**
- `ring_spring_k` (100–400 typical): return speed
- `ring_damping` (5–20 typical): wobble vs stability
- `drag_coupling` (0 default, 0.3–0.7 for dramatic orifices): axial funnel deformation amount

### 6.5 Multi-tentacle support

An orifice holds a list of `EntryInteraction`s, not just one. For each ring direction:

```
// Aggregate demand over all active interactions
target_radius[d] = 0
for each EntryInteraction in orifice.active_interactions:
    tentacle_girth = EI.tentacle_girth_here
    offset_component = dot(EI.center_offset_in_orifice, direction_vec[d])
    reach = offset_component + tentacle_girth
    target_radius[d] = max(target_radius[d], reach)
```

`max` over the list — if two tentacles are on opposite sides of the orifice, each drives its own side independently. Compression per tentacle computed individually against the resulting ring radius via bilateral compliance.

**Inter-tentacle separation inside an orifice:** type-5 (particle-particle) collision is always enabled for particles flagged as inside any orifice, even if disabled globally. This lets two tentacles jam in side-by-side and physically push each other apart.

**Cap: 3 simultaneous per orifice.** 4th is rejected at entry. Override flag exists for player/narrative-driven forced multi-entry.

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

**Birthing: ring transit.** When a bead reaches the orifice's inner entry plane, it is treated identically to a bulb on retraction (Scenario 2). Ring bones stretch nonlinearly to accommodate `bead.chain_radius`; bilateral compliance (§6.3) applies; grip hysteresis engages if grip was active; pop-release occurs past the ring's widest point. Emits `RingTransitStart` at initial contact and `RingTransitEnd` at completion, and `PayloadExpelled` with the bead reference as the full event payload.

Damage accumulates per §6 if `bead.chain_radius` exceeds `orifice.max_radius`.

**Tentacle-bead release on expulsion.** When a tentacle-root bead's pinned particles cross the entry plane outward, each pinned particle transitions `inv_mass` from 0 to the tentacle's normal per-particle mass in order. By the time the last pinned particle exits, the tentacle is fully free.

The freed tentacle is an ordinary `Tentacle` with a **"Free Float" scenario preset** (see `TentacleTech_Scenarios.md` §A4): zero target-pull, high noise, low stiffness. In zero-G environments this produces natural wiggling. The existing PBD bending constraints (§3.3) fill the role that cone-twist joints would on a `PhysicalBone3D` chain. **Do not use `PhysicalBone3D` chains for excreted tentacles** — one solver type for everything (§1 principle), and the `PhysicalBone3D` scaling bug (§14) would re-surface.

**Open design question (not blocking):** payload source for oviposition in gameplay — whether tentacles arrive pre-loaded, refill from environment sources, or have infinite capacity. Defer until encounter design lands.

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

Cavity meshes do not get ring bones of their own. Ring bones at each orifice rim rig shared rim vertices (see §6.1); the rim is a single edge loop of the continuous mesh, and ring-bone motion deforms the rim visible from both sides.

---

## 8. Stimulus bus

### 8.1 Events vs continuous channels

Two data types, cleanly separated:

**Events** — discrete moments with timestamp, published when something happens:
```cpp
enum StimulusEventType {
    PenetrationStart, PenetrationEnd,
    BulbPop, StickSlipBreak, GripEngaged, GripBroke,
    RingOverstretched, HardStopBottomedOut, FluidSeparation,
    Impact, TangentialSlap, SkinPressure,
    OrificeDamaged, TentacleTangled,
    EnvironmentalFlash, LoudSound, TemperatureDrop,  // external
    DialogueAddressed, ObserverArrived,              // external
    RunStarted, RunEnded,                            // run lifecycle
    PayloadDeposited, PayloadExpelled,               // oviposition / birthing
    StorageBeadMigrated,                             // storage chain movement
    RingTransitStart, RingTransitEnd,                // bead crossing rim
    PhenomenonAchieved,                              // rare emergent event (see docs/Gameplay_Mechanics.md)
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

Fluid strands: when a tentacle withdraws past the entry plane, spawn a `FluidStrand` (4–6 point spline between retreating tip and orifice center). Stretches with separation, breaks at threshold, snaps into two droplets. GPU-drawn triangle strip, ~50 lines of code.

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

### 10.2 Procedural generator (GDScript, in `gdscript/procedural/`)

CSG-like node tree in editor:

```
TentacleMeshRoot (Node3D, outputs ArrayMesh + bakes girth texture)
├── base_length, base_radius, segment_count, radial_segments
├── taper_curve (Curve resource)
└── modifier children (operate on parent's vertex data)
    ├── RippleModifier (start, end, frequency, amplitude, falloff)
    ├── KnotModifier (position, type, size, count, spacing, size_falloff)
    ├── TaperModifier
    ├── TwistModifier
    └── FlareModifier
```

Regenerates mesh live in editor. Bakes girth texture automatically (§5.4). Default presets provided: smooth, ribbed, bulbed, multi-bulb, barbed, ovipositor.

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

**Blender pipeline.**

1. Model hero mesh with standard humanoid skeleton.
2. Model cavities as invaginations of the same mesh — extrude inward at each orifice to form tunnel volumes terminating at closed ends or connecting to other orifices.
3. Assign skin material to exterior faces, mucosa materials to cavity faces. Material boundaries near the rim are fine either inside or on the edge loop.
4. Do NOT flip cavity normals. Normals should be outward-from-the-surface everywhere. Use "recalculate outside" with the mesh as a single closed topology.
5. For each orifice: place an empty object (`OrificeMarker`) at the opening center, with its local +Y axis aligned with the opening's outward axis. Parent to the nearest ragdoll bone.
6. Optional: place empty objects as `TunnelMarker`s along internal paths if auto-derived centerlines need correction.
7. Export GLB with skeleton, empties, and all material surfaces preserved.

**In Godot — auto-derivation (new).** A new `OrificeAutoBaker` tool (GDScript, editor plugin, extends the existing `ring_weight_generator`) runs at hero import time or on demand:

1. For each `OrificeMarker`: find the hero mesh edge loop nearest the marker, along the marker's local axis. This is the rim.
2. Compute rim centroid and `rest_radius` (mean distance from centroid to rim vertices).
3. Place 8 ring bones at equal angular intervals around the rim centroid, at rest radius, in the Skeleton3D. Parent to a per-orifice center bone parented to the marker's authored parent.
4. Weight-paint rim vertices to ring bones (angular-nearest-two with radial falloff outward per §6.1). Innermost rim loop gets full ring weight; outer loops taper to body-bone weights.
5. Skeletonize the cavity mesh volume downstream of the rim (medial-axis extraction); fit a Catmull spline to the medial curve. This is the tunnel centerline. Sample spacing tunable per-orifice.
6. At each tunnel sample, cast perpendicular rays to find distance-to-wall; output a rest-radius profile along arc-length. This is the tunnel girth profile used for type-3 collision.
7. Populate the orifice's `suppressed_bones` list with ragdoll capsules within N cm of the marker (N tunable, default 0.15 m). Author can override.

**Orifice ring weight painting** (computed per step 4 above; also available as a stand-alone helper for manual rigs):

```
For each vertex within orifice_influence_radius of opening:
    W_total_ring = radial_falloff(distance_from_opening_axis)  // 1.0 at edge → 0 at radius
    angle = atan2(vertex_local.y, vertex_local.x)
    ring_float = (angle / 2π) × 8
    ring_a = floor(ring_float) % 8
    ring_b = (ring_a + 1) % 8
    frac = fract(ring_float)
    W_ring[ring_a] = W_total_ring × (1.0 - frac)
    W_ring[ring_b] = W_total_ring × frac
    W_body = 1.0 - W_total_ring
```

Innermost vertex loop must have `W_total_ring = 1.0` (no body bone weight) so it follows the ring bones fully.

**Manual override hooks** (for weird topology — non-manifold cavities, non-clean rim loops, branching tunnels):
- `OrificeProfile.manual_ring_bones: Array[NodePath]` — short-circuits rim detection.
- `OrificeProfile.manual_tunnel_spline: Resource` — short-circuits centerline derivation.
- `OrificeProfile.manual_suppressed_bones: Array[String]` — short-circuits auto-suppression.

When any manual override is set, that step's auto-derivation is skipped; other steps still run.

**In Godot — scene setup (unchanged parts):**
- Instance the GLB, add `CharacterBody3D` + `Skeleton3D`.
- Add `PhysicalBone3D` nodes per ragdoll bone with capsules.
- Per orifice: add `Orifice` node referencing the `OrificeMarker`, assign the `OrificeProfile` (auto-baker populates ring bones and tunnel data at bake time; runtime reads them).
- Configure `SkinBulgeDriver` on hero.
- Assign hero shader (handles skin + mucosa surfaces via per-surface materials, includes `tentacle_lib.gdshaderinc` for bulger deform).

**Ragdoll colliders:** start with capsules everywhere (auto-generated from bone lengths). Upgrade specific bones to convex hulls only where capsules fail visibly (hands, feet). Start collision layer: `ragdoll_body`. Tentacles don't collide with it directly via physics server — they read the per-tick snapshot and apply per-tentacle suppression lists.

### 10.5 Capsule suppression during interactions

When a tentacle has an active `EntryInteraction` with an orifice, specific ragdoll capsules are excluded from its type-1 collision queries. The `OrificeProfile` lists these by bone name. Typical:
- Mouth orifice → suppress jaw, neck, upper chest
- Torso orifice → suppress pelvis, hips, upper thighs

This is the mechanism enabling tentacles to go *inside* the body at the orifice without fighting internal ragdoll geometry.

Auto-suppression per §10.4 populates this list from proximity at bake time; manual override remains available via `OrificeProfile.manual_suppressed_bones`.

---

## 11. File structure (C++/GDScript split)

```
extensions/tentacletech/
├── CLAUDE.md
├── SConstruct
├── tentacletech.gdextension
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
│   │   └── ring_weight_generator.gd     # editor plugin
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
7. Acceptance: stable at 60 Hz, volume preservation visible, responds to target pull

**Phase 3 — Mesh rendering**
8. Vertex shader + shader include (`tentacle_lib.gdshaderinc`)
9. Auto-baked girth texture from mesh geometry
10. Procedural generator (GDScript) with base presets
11. Acceptance: mesh smoothly follows spline, squash/stretch visible, no twisting

**Phase 4 — Collision and friction**
12. Ragdoll snapshot
13. Type-1, type-4 collision
14. Unified friction projection
15. Acceptance: tentacles don't phase through hero, drag-along behavior, stick-slip visible on ribbed tentacles

**Phase 5 — Orifice system**
16. Ring bones + weight painting auto-generator plugin
17. EntryInteraction + bilateral compliance (single tentacle first)
18. Spring-damper ring dynamics
19. Type-2, type-3 collision (orifice rim, tunnel walls, straight tunnels first)
20. Acceptance: tentacle penetrates, orifice stretches with jiggle, bulge retention on retract

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
38. Sub-stepping for fast motion
39. Per-region bulger stiffness
40. Profile on low-end hardware, cut iteration counts as needed

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
- **Tunneling at high velocity:** particle sub-stepping kicks in when displacement > 50% of safety radius. Default to 1×; escalate to 2–3× for tentacles currently in thrust scenarios.
- **Orifice boundary flipping:** hysteresis on "inside tunnel" vs "outside" — enter at 5cm past plane, exit at 2cm outside.
- **Double-counting at orifice entry:** type-1 capsule collision is suppressed per-particle for capsules in the orifice's `suppressed_bones` list. Prevents particle feeling both capsule push and ring compression.
- **Friction resonance/jitter:** high `μ_s` with low iteration count oscillates at the cone boundary. Add 5% dead-band around static cone threshold.
- **Ring runaway:** hard clamp on `current_radius` prevents spring from pushing past anatomical limits. Velocity zeroed at clamp.
- **Attachment slip compounding:** slip accumulates; after `max_slip_from_original` drift, detach entirely rather than re-anchor further.
- **PhysicalBone3D scale bug** (existing Godot bug): tentacle root must remain at scale 1. Document in setup.

**What not to do:**
- Don't use `MeshDataTool` in hot paths
- Don't use `SoftBody3D`
- Don't use `MultiMesh` for tentacle instancing (each needs unique deforming mesh)
- Don't copy DPG's `Penetrator`/`Penetrable` naming (use `Tentacle`/`Orifice`)
- Don't author girth profiles manually (auto-baked from mesh)
- Don't generate Godot test scenes automatically — user creates them

---

This document is the specification. The scenarios document covers what the system produces. The Reverie planning document covers the future reaction-system integration.
