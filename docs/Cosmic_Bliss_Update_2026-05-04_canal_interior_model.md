# Cosmic Bliss — Design Update 2026-05-04 — Canal interior model

> **Status: drafted 2026-05-04, amended 2026-05-04 (centerline particle
> chain + skinning-skip + sac/curved-canal authoring), awaiting
> application.** Replaces the "compound openings — sequence of rim loops
> along tunnel axis" interior model from
> `docs/Cosmic_Bliss_Update_2026-05-03_orifice_rim_model.md` §6.1 with a
> 2D `tunnel_state` texture model + a PBD centerline particle chain.
> Rim particle loops remain at orifice boundaries only. Lineage:
> extended discussion 2026-05-03/04 covering character-creation
> pipeline, asymmetric multi-tentacle deformation, plastic memory,
> wall-lag air pockets, decoupled squeeze/propulsion, canal bend under
> load, and skinning-skip via per-vert simulation routing. User
> direction 2026-05-04: model canal interiors in Blender (no procedural
> generation), no JSON sidecar, naming convention only, 2D texture
> state, no per-vert weight painting on canal interior verts, support
> curved canals + closed-end sacs (uterus, bladder) without a separate
> primitive.

**Audience: top-level Claude (canonical record). Sub-Claude reads the
architecture doc, not this one.**

---

## TL;DR

The 2026-05-03 rim-loop amendment correctly removed the 8-direction-bone
model from orifices but extended rim loops into canal interiors via
"compound openings — a sequence of loops along the tunnel axis." That
extension is wrong: high authoring cost (one rim anchor bone set per
feature, ~144 bones in a colon with 8 haustra), runtime cost compounds
(PBD constraint solving on every interior loop), and several gameplay-
or-realism behaviors aren't naturally expressible (plastic memory, wall
lag → air pockets, decoupled squeeze ↔ propulsion, active intake drag,
many cheap constriction zones, asymmetric multi-tentacle deformation,
canal bend under load).

The new model:

1. **Rim particle loops only at true orifices** (mouth, anus,
   vagina×2, cervix, optionally cardia/pylorus). Multi-loop per orifice
   (§6.1 amendment) is unchanged. The "compound openings — sequence
   along tunnel axis" sub-bullet retires.

2. **Canal interior is texture-driven.** Each canal owns a 2D
   `tunnel_state` RGBA32F texture indexed by `(arc_length_sample,
   angular_sector)` — typically 32×8 cells. CPU integrates per-tick
   wall dynamics from authored modulation + bulger SDF input; shader
   samples for vertex displacement; PBD type-3 collision reads the
   same texture for wall position and friction.

3. **Canal centerline is a PBD particle chain** (M particles, default
   12), anchored at orifice Center frames or closed terminals. The
   chain has XPBD distance + bending + spring-back to CP-bone-rest +
   optional lateral plastic memory. A bulger pushing the wall
   asymmetrically *splits* its force between wall radius (texture) and
   centerline lateral shift (chain) by relative compliance. Real canals
   bend visibly under load; the centerline chain is what makes that
   geometric.

4. **Canal mesh is hand-modeled in Blender**, part of the continuous
   hero mesh. No procedural tube generator. Static features (haustra,
   taeniae, Houston's valves, anal columns, rectal columns) are baked
   into the modeled mesh. Canals can curve freely (vagina toward
   lumbar, colon flexures, esophagus through diaphragm) — the only
   constraint is tubular topology + non-self-intersecting +
   sufficient CP bone density.

5. **No per-vert weight painting on canal interior verts.** Single
   marker per vert: `CUSTOM0.r = canal_id + 1`. Vertex shader reads
   per-canal data (deformed centerline + `tunnel_state` texture) and
   per-vert baked `(s, θ, rest_radius_at_vert, rest_outward_normal)`
   stored in `CUSTOM1` + `CUSTOM2` to displace. The AutoBaker computes
   the per-vert bake at scene init by projecting rest-pose verts onto
   the rest centerline. Authoring is "model + click + done."

6. **Constriction zones** replace per-feature rim loops. A zone is
   pure data (`{arc_length_s, half_width, max_contraction,
   current_strength, friction_bonus, baked_at_rest}`) on the canal's
   resource. Many zones cost essentially nothing.

7. **Muscle activation field** unifies modulation. Reverie writes a
   per-cell `muscle[s,θ]` field; physics derives `radius_mult`,
   `axial_surface_vel`, constriction strengths, and asymmetric
   contraction patterns. An additional **per-centerline-particle
   `muscular_curl_delta`** lets Reverie actively bend the canal
   independent of radial squeeze. Replaces the ad-hoc `peristalsis_*`
   channel triplet (kept as backward-compat sugar).

8. **Sacs (uterus, bladder)** use the Canal primitive with
   `closed_terminal = true` (distal centerline particle hard-pinned
   instead of anchored to an exit orifice). **Two-opening sacs
   (stomach)** use the Canal primitive with both `entry_orifice_path`
   and `exit_orifice_path` plus an aggressively variable
   `rest_radius_profile`. No separate `Cavity` primitive — defer until
   gameplay surfaces a demand the Canal doesn't satisfy.

9. **Authoring uses bone naming convention** —
   `<Prefix>_RimAnchor_*` (existing) for orifice rim anchors,
   `<Canal>_CP_*` (new) for canal centerline control points,
   optionally `<Canal>_TerminalPin` for closed-terminal sacs. **No
   JSON sidecar.**

Authoring cost drops 5–10× for canal interiors (no per-haustra bones,
no per-vert weight painting). Runtime cost drops 3–5× total per hero
(orifice rim particles unchanged; canal interior PBD work removed;
texture work + small centerline chain added is a fraction). Realism
increases on every measurable axis (plastic memory, asymmetric
deformation, air pockets, decoupled propulsion, intake drag, dense
constriction zones, **canal bend under load**).

---

## What changes (canonical text — to be applied to architecture doc)

### §6.1 — Rim structure (amendment to the 2026-05-03 amendment)

**Retire** the "Compound openings (ribbed canal, multiple sphincters
along a single tunnel)" sub-bullet of the multi-loop support paragraph
(line 615). Compound axial sequencing of rim loops is no longer the
canal interior model. The remaining multi-loop configurations stay:

- **Single loop** (default): one rim loop, simple orifice.
- **Outer + inner loop** (anatomical): outer "lip" + inner "opening"
  with differential stiffness and inter-loop coupling springs.
- **Decorated rim** (jewelry, prosthetic): inner anatomical opening +
  high-stiffness decorative outer.

Multi-loop per orifice continues to refer to **stacked loops at a
single rim location** (lips + opening), not sequences of loops along
a tunnel. Canal interior dynamics are the §6.12 texture model.

### §6.7 — Through-path tunnels (rewritten)

A tentacle may traverse multiple orifices as a chained path. Each
`EntryInteraction` may be linked head-to-tail with another belonging
to a different orifice on the same hero.

- Each `EntryInteraction` gains optional `downstream_interaction`
  and `upstream_interaction` pointers.
- Tunnel projection sums along the linked chain; the tentacle spline
  passes through all orifices' tunnel splines in sequence.
- Capsule suppression (§10.5) unions the suppression lists of all
  chained orifices.
- Bulger sampling (§7.2) covers the full chained interior — allocate
  6 samples per orifice in the chain, not 6 samples per tentacle.
- AI targeting uses the entry orifice only; the exit orifice is
  emergent from physics.
- Chain linking is detected by proximity: when a penetrating
  tentacle's tip enters a second orifice's entry plane while still
  engaged upstream, a downstream `EntryInteraction` is created and
  linked.
- **Each linked tunnel has its own `tunnel_state` texture +
  centerline particle chain (§6.12).** Bulger SDF queries are global
  — every active canal sees every active bulger regardless of which
  orifice the bulger's tentacle entered through. A tentacle spanning
  vagina → cervix → uterus deforms the vaginal, cervical, and uterine
  wall textures simultaneously through per-cell SDF evaluation, AND
  bends each canal's centerline chain laterally per the bilateral
  wall/centerline split.

### §6.9 — Oviposition and birthing (revised "Birthing: peristalsis" subsection)

Replace the "Mechanical scope" paragraph (lines 1055–1067) with:

**Mechanical scope.** Peristalsis is implemented as time-varying
contributions to the `muscle[s,θ]` field (§6.12) on the canal's
`tunnel_state` texture. The traveling wave of `radius_mult` (derived
from `muscle`) creates a moving constriction; the wedge math
(`drds_outward` per cell) produces axial force on contents in contact
with the wall via type-3 collision projection. `axial_surface_vel`
(derived from longitudinal `muscle` gradient) adds Coulomb-capped
friction drag on contents independent of squeeze. Both compose
naturally; both are continuous physical channels (no scripted force
paths).

```
# Per cell at (s_k, θ_j), each tick:
muscle_kj         = canal.muscle_field.evaluate(s_k, θ_j, t)
radius_mult_k     = mean over θ of (1 - muscle_kj * canal.contraction_gain)
axial_vel_k       = (∂muscle/∂s averaged over θ) * canal.surface_vel_gain

target_radius_kj  = max(rest_radius_kj + plastic_offset_kj,
                        rest_radius_kj * radius_mult_k,
                        bulger_SDF_target_kj)
```

The dynamic_wall_radius integration (§6.12) lags the target with
finite response rate; the result feeds both the vertex shader (visual
displacement) and type-3 collision (wall position).

Beads in the wave's low-radius phase experience asymmetric ring
pressure producing net axial force; expulsion (high amplitude,
positive wave speed) and ingestion/retention (negative wave speed, or
`axial_surface_vel < 0`) are symmetric uses of the same primitive.

The remainder of §6.9 (ring transit, tentacle-bead release on
expulsion, payload deposit) is unchanged — it consumes geometric
quantities (`penetration_depth`, ring crossings) that don't depend on
the interior model.

### §6.10 — Transient pulse primitives (composition revision)

`ContractionPulse` retains its struct definition. Per-tick application
changes:

```
# Old: pulses add to peristalsis_amplitude / peristalsis_wave_speed
# New: pulses add to the muscle activation field

for each pulse p in active_pulses (filtered by applies_to):
    age = current_time - p.t_started
    if age >= p.duration: retire and continue
    env = p.envelope.sample_baked(age / p.duration)

    # Contribution shape: traveling wave centered on tunnel
    for each cell (s_k, θ_j):
        wave_phase = (s_k - p.speed * age) * 2π / p.wavelength
        contribution = p.magnitude * env * sin(wave_phase)
        canal.muscle_field[s_k, θ_j] += contribution
```

Named patterns (`OrgasmPattern`, `GagReflexPattern`, etc.) keep their
sugar-emitter role; they queue atomic `ContractionPulse`s as before.

### §6.12 — Canal interior texture model (NEW SECTION)

The canal interior between orifices is governed by **two coupled
simulation states**:

1. A **2D `tunnel_state` texture** per canal — per-cell wall radius,
   plastic memory, friction multiplier, damage. Sampled by both
   vertex shader (visual wall displacement) and PBD type-3 collision
   (wall position + friction). Resolution per-canal
   (`canal_axial_segments × canal_angular_sectors`), default 32×8,
   packed as RGBA32F.

2. A **centerline particle chain** per canal — M PBD particles
   (default 12) along the canal axis, anchored at the entry orifice's
   Center frame (or a closed terminal) and the exit orifice's Center
   (or open distal end). XPBD distance + bending + spring-back to
   CP-bone-rest. Bulger pressure asymmetric to the canal axis splits
   between wall radius (texture) and centerline lateral shift (chain)
   by relative compliance. The chain is what makes canals visibly
   bend under load.

The two states are coupled: the texture's `(s, θ)` parameterization
is *intrinsic to the deformed centerline*, not the rest one. Each tick
the centerline chain settles first; the wall texture integration
follows using the deformed centerline frames.

#### §6.12.1 — Centerline particle chain

```cpp
struct CenterlineParticle {
    Vector3 position;
    Vector3 prev_position;
    float inv_mass;
    Vector3 rest_position_world;   // refreshed each tick from CP bones
    float distance_lambda_to_next; // XPBD lambdas (reset per tick)
    Vector3 bending_lambda;
    Vector3 spring_lambda;
};

struct CanalCenterline {
    Vector<CenterlineParticle> particles;       // M, typically 8–16
    Vector<float> rest_arc_lengths;              // M-1, segment rest lengths
    Vector<Vector3> rest_positions_in_host_frame;  // baked from CP bones at init

    float distance_compliance;        // axial length stiffness
    float bending_compliance;         // curvature stiffness
    float spring_back_compliance;     // pull toward CP-bone-rest
    float lateral_compliance;         // bilateral split allocation share

    // Plastic memory along the axis (lateral bend persistence)
    Vector<Vector3> plastic_lateral_offset;     // per particle, accumulated
    float lateral_plastic_accumulate_rate;
    float lateral_plastic_recover_rate;
    float lateral_plastic_max_offset;

    // Active muscular curl (Reverie-writable, per particle)
    Vector<Vector3> muscular_curl_delta;        // per particle, additive to rest
};
```

Per-tick centerline update (same Jacobi+SOR pattern as the rim loop):

1. **Refresh rest positions** from the CP bones (live host-bone
   transforms; once per tick before iterate, same discipline as §4.5
   ragdoll snapshot).
2. **XPBD distance** between consecutive particles — preserves canal
   length, with axial-plastic compliance for sustained-stretch memory.
3. **XPBD bending** at each interior triple — preserves smooth rest
   curvature.
4. **XPBD spring-back** to `rest_position_world + plastic_lateral_offset
   + muscular_curl_delta` — controls how stiff the canal axis is.
   Per-particle stiffness distribution is the per-canal "bend
   compliance" knob.
5. **Optional anchor pin** at canal endpoints (orifice Center frames
   or sealed terminals).

Cost: M=12 particles × ~100 ops/tick ≈ 1200 ops per active canal.
Negligible.

#### §6.12.2 — `tunnel_state` texture state channels

Per cell at `(s_k, θ_j)`, CPU-integrated per tick:

```cpp
struct TunnelStateCell {
    float dynamic_wall_radius;  // current effective wall radius (m)
    float plastic_offset;       // accumulated radial stretch memory (m)
    float damage;               // accumulated tissue damage (Pa·s units)
    // Optional fourth channel (RGBA32F packing has slot for one of these):
    //   wall_radial_velocity     — for second-order ringing dynamics
    //   friction_mult            — per-cell μ multiplier
    // Pack choice authored per-canal via `canal.fourth_channel_mode` enum.
};
```

#### §6.12.3 — Modulation inputs (Reverie-writable)

```cpp
struct CanalMuscleField {
    // Spatial muscle activation, 0..1 per cell.
    Vector<Vector<float>> muscle;  // [axial][angular]

    // Sugar accessors (backward-compat with existing peristalsis channels)
    void set_peristalsis(amplitude, wave_speed, wavelength);
    void set_constriction_zones(Array[CanalConstrictionZone]);
};

struct CanalConstrictionZone {
    float arc_length_s;       // position along canal
    float half_width;         // axial extent
    float max_contraction;    // 0..1, peak tightness
    float current_strength;   // 0..1, modulated each tick
    float friction_bonus;     // extra μ in zone
    float baked_at_rest;      // 0..1, fraction baked into rest mesh
};
```

#### §6.12.4 — Per-tick CPU integration

Run once per active canal each outer tick, AFTER the centerline
chain has settled (so the deformed centerline frames are current):

```
# 1. Centerline tick (§6.12.1) — settles bend/length/curl
canal.centerline.tick(dt)

# 2. Per-cell wall integration
for each cell (s_k, θ_j) in canal.tunnel_state:

    # 2a. Evaluate muscle activation
    muscle = canal.muscle_field.evaluate(s_k, θ_j, t)
    for each zone z in canal.constriction_zones:
        d = abs(s_k - z.arc_length_s)
        if d < z.half_width:
            falloff = smoothstep(z.half_width, 0, d)
            muscle += z.current_strength * z.max_contraction * falloff

    # 2b. Compute the cell's world position (uses DEFORMED centerline)
    cell_world_pos = canal.centerline.evaluate(s_k)
                   + canal.outward_at(s_k, θ_j) * dynamic_wall_radius_kj

    # 2c. Bulger SDF contribution (concrete formula, all active bulgers)
    bulger_target = 0
    for each active bulger b in scene.bulgers:
        # Closest point on bulger surface to cell's outward ray
        closest = b.closest_surface_point_to(cell_world_pos)
        sdf = (cell_world_pos - closest).length() - b.radius
        if sdf < 0:
            # Cell is inside the bulger — wall must move outward to expel.
            # Project bulger center onto cell's outward direction from
            # the centerline at s_k.
            projected = (b.center - canal.centerline.evaluate(s_k))
                        .dot(canal.outward_at(s_k, θ_j))
            bulger_target = max(bulger_target, projected + b.radius)

    # 2d. Centerline curvature → wall asymmetry (visible bend response)
    curvature_kj = canal.centerline.curvature_at(s_k)         # scalar magnitude
    bend_axis    = canal.centerline.bend_axis_at(s_k)         # unit vector
    inside_factor = -dot(canal.outward_at(s_k, θ_j), bend_axis)  # -1..+1
    curvature_offset = curvature_kj * inside_factor * canal.curvature_response_gain

    # 2e. Compute target wall radius
    rest = canal.rest_radius_profile[s_k][θ_j]
    target = max(
        rest + plastic_offset[k][j] - rest * muscle * canal.contraction_gain * 0.5,
        bulger_target,                                          # contact pressure
        canal.min_wall_radius,                                  # safety floor
    )
    target += curvature_offset                                  # bend asymmetry

    # 2f. Bilateral wall/centerline split (when a bulger's depth exceeds
    # the wall_compliance_share). Most of the deflection goes to the
    # wall texture (handled above); the centerline lateral shift is
    # written via add_external_position_delta on the nearest centerline
    # particle inside the centerline tick step (§6.12.1). The split
    # allocation is by canal.lateral_compliance vs implicit wall
    # compliance.

    # 2g. Integrate dynamic_wall_radius with finite response rate.
    # Stability clamp: the per-tick gain wall_response_rate * dt must
    # stay below 1; clamped here defensively.
    rate = clamp(canal.wall_response_rate, 1.0, (1.0 / dt) - 1e-3)
    delta = (target - dynamic_wall_radius[k][j]) * rate * dt
    dynamic_wall_radius[k][j] += delta

    # 2h. Optional second-order wall dynamics (ringing/overshoot)
    if canal.use_second_order_wall:
        wall_radial_velocity[k][j] += delta * canal.wall_acceleration_gain
        wall_radial_velocity[k][j] *= (1 - canal.wall_damping * dt)
        dynamic_wall_radius[k][j] += wall_radial_velocity[k][j] * dt

    # 2i. Plastic memory accumulation + recovery (radial)
    stretch = max(0, dynamic_wall_radius[k][j] - rest)
    plastic_offset[k][j] += max(0, stretch - plastic_offset[k][j])
                            * canal.plastic_accumulate_rate * dt
    plastic_offset[k][j] -= plastic_offset[k][j] * canal.plastic_recover_rate * dt
    plastic_offset[k][j] = clamp(plastic_offset[k][j], 0, canal.plastic_max_offset)

    # 2j. Per-cell damage accumulation (sustained pressure)
    pressure_estimate = max(0, target - rest)
    damage[k][j] += pressure_estimate * dt * canal.damage_rate
    # Damage feeds back into plastic capacity (high-damage cells stretch more)
    plastic_max_local = canal.plastic_max_offset *
                       (1.0 + damage[k][j] * canal.damage_plastic_gain)
    plastic_offset[k][j] = clamp(plastic_offset[k][j], 0, plastic_max_local)

    # 2k. Friction multiplier from muscle + zones + damage
    friction_mult[k][j] = 1.0 + muscle * canal.muscle_friction_gain
                        + zone_friction_bonus_at(s_k, θ_j)
                        - damage[k][j] * canal.damage_friction_loss
```

Runtime cost: 32×8 = 256 cells × ~40 ops ≈ 10K ops per canal per
tick, plus 256 × N_bulgers × ~30 ops ≈ 75K ops with N_bulgers=10
(bulger SDF queries dominate). Centerline tick adds ~1.2K ops. Total
per active canal per tick: ~85K ops, or ~85µs at 1GHz/op throughput.
Trivial.

#### §6.12.5 — Vertex shader sampling (canal interior verts)

Canal interior verts are tagged with `CUSTOM0.r = canal_id + 1` and
carry per-vert baked `(s, θ, rest_radius_at_vert, rest_outward_normal)`
in `CUSTOM1` + `CUSTOM2`. The AutoBaker computes these at scene init
by projecting the rest-pose vert position onto the rest centerline
(§10.6 step 10).

```glsl
int canal_id = int(CUSTOM0.r) - 1;
if (canal_id >= 0) {
    // Per-vert baked rest-frame coordinates
    float s            = CUSTOM1.r;       // arc length along rest centerline
    float theta        = CUSTOM1.g;       // angular position around rest centerline
    float rest_radius  = CUSTOM1.b;       // baked rest distance from spline axis
    vec3 rest_normal   = CUSTOM2.rgb;     // baked rest outward normal in canal frame

    // Per-canal data (uniforms / textures, uploaded each tick)
    vec3 deformed_pos = centerline_eval(canal_id, s);
    mat3 deformed_basis = centerline_basis(canal_id, s);  // TBN at s
    vec3 deformed_outward = deformed_basis * vec3(cos(theta), sin(theta), 0);

    // Sample dynamic wall radius from texture
    float dynamic_radius = texture(tunnel_state[canal_id],
                                    vec2(s_norm, theta_norm)).r;

    // Final vertex position — pure simulation output
    VERTEX = deformed_pos + deformed_outward * dynamic_radius;

    // Normal transform: keep the modeled-mesh normal detail, but rotate
    // it by the deformed-vs-rest basis so haustral ridges etc. light
    // correctly when the canal bends.
    NORMAL = deformed_basis * inverse(rest_basis_at_s) * rest_normal;
}
```

**No per-vert bone weights are required for canal interior verts.**
The (s, θ, rest_radius, rest_normal) bake replaces them entirely. The
artist's authoring step is "select all interior verts, click 'assign
to canal X'." See §10.4 for the workflow.

#### §6.12.6 — Type-3 collision (PBD particle vs. canal wall)

```
# Project tentacle particle position into canal (s, θ) coords
# using the DEFORMED centerline (not the rest one)
(s, θ) = canal.deformed_spline_project(particle.position)
wall_radius = sample_dynamic_wall_radius(s, θ)
if particle.dist_from_axis(s) > wall_radius - particle.collision_radius:
    project particle outward to wall_radius - particle.collision_radius
    record contact normal = canal.deformed_outward_at(s, θ)

# Friction tangent uses surface velocity
axial_vel = sample_axial_surface_vel(s)
rel_vel_tangent = particle.velocity_tangent - axial_vel * deformed_spline_tangent
apply Coulomb friction with μ = base_μ * sample_friction_mult(s, θ)
```

#### §6.12.7 — Surface velocity

Derived from the longitudinal gradient of `muscle[s,θ]` averaged over
θ. This is the muscular wall-drag channel: positive = wall surface
moves toward exit, drags content out; negative = wall moves toward
interior, pulls content in. Independent of `radius_mult`, so a canal
can pull without squeezing or squeeze without pulling.

#### §6.12.8 — Multi-tentacle asymmetric deformation

Two tentacles in the same cross-section produce two bulger
contributions; each cell at (s, θ_j) takes its own SDF max; the wall
develops a peanut-shaped cross-section. The 2D state (per (s,θ)
rather than per s) is what enables this.

Additionally, the bilateral wall/centerline split routes some of the
asymmetric pressure into the centerline as a lateral force, so the
canal *bends* toward the unbalanced side — visible as a curving canal
under load, not just radial deformation at the contact point.

#### §6.12.9 — Hierarchical activation

A canal with no active EntryInteraction, no storage chain content, and
no Reverie modulation skips both the centerline tick and the texture
integration entirely. The shader continues to read the last-uploaded
texture + last-uploaded centerline (which are the rest pose).
Reactivation occurs when an EntryInteraction engages, a bead enters
storage, or Reverie writes a non-zero muscle value. Most canals are
inactive most of the time; this saves the bulk of the runtime cost.

#### §6.12.10 — Stability and gotchas

- **`wall_response_rate * dt < 1`** for first-order integration
  stability. Defensively clamped to `min(rate, 1/dt - ε)` per integration
  loop. Add to §14 gotchas: a designer cranking `wall_response_rate >
  60Hz` with default 60Hz physics step will see oscillation.
- **Pumping resonance.** A tentacle pumping at `~1 / wall_response_rate`
  excites wall ringing — discoverable gameplay phenomenon analogous to
  the §1.2 rib resonance. With `use_second_order_wall = true` it
  becomes pronounced. Worth flagging in `Gameplay_Mechanics.md` as a
  hidden phenomenon.
- **Centerline bend produces wall asymmetry but not host-bone
  movement.** The §6.3 reaction-on-host-bone closure operates only at
  rim particle loops. A canal interior bend transmits axial force to
  the host body through the CP bone rigging (since CP bones are
  rigidly parented to host bones), but does NOT add an extra
  body_apply_impulse beyond what the centerline's spring-back to CP
  rest already implies. If gameplay needs canal-interior force
  feedback to the host body distinct from the rim's, add it as a
  separate pass — currently not in scope.
- **Centerline curvature math** uses `canal.centerline.curvature_at(s)`
  — finite-difference on three adjacent particle positions. Returns
  scalar magnitude + signed bend axis. Documented in
  `CanalCenterline::evaluate` comment.

### §7.1 / §7.2 — Bulger feed into canal (additive)

The bulger array (§7.1) and its sources (§7.2) are unchanged. The new
consumers are each canal's per-tick CPU integration (texture wall
update) and centerline particle chain (lateral force). When computing
`target_radius` per cell and per-particle bulger lateral push, the
canal queries every active bulger globally. Bulgers are not filtered
by canal ownership.

The vertex shader path also splits:
- **Body skin verts** (exterior + non-canal): displace from bulger
  array per the existing §7.1 inner loop. Unchanged.
- **Canal interior verts**: displace from `tunnel_state` texture +
  deformed centerline. The texture already incorporates bulger
  contributions via CPU integration, so the shader does not loop over
  bulgers for these verts — single texelFetch per vert.

Identification of canal interior verts uses `CUSTOM0.r = canal_id + 1`
(§10.4 step 10). No sidecar required.

### §8.2 — Modulation channels (additions)

Add to `OrificeModulation`:

```cpp
struct OrificeModulation {
    // ... existing fields unchanged ...

    // Canal interior modulation (§6.12). Reverie writes the muscle
    // activation field directly for spatial control; the legacy
    // peristalsis_* fields below are sugar that derive a uniform
    // wave on top of muscle[s,θ].
    void set_muscle_activation(int s_k, int θ_j, float value);
    void apply_muscle_pattern(StringName pattern_id);  // sugar emitter

    // Surface velocity (independent of squeeze).
    float axial_surface_vel_gain = 1.0;

    // Constriction zones (active modulation per zone strength).
    void set_constriction_zone_strength(int zone_index, float strength);

    // Active muscular curl (per centerline particle, additive to rest).
    // Lets Reverie author behaviors like "the canal flexes around the
    // tentacle" or "the canal arches to direct movement" — independent
    // of radial squeeze. Composes with muscle[s,θ] field cleanly.
    void set_muscular_curl_delta(int particle_index, Vector3 delta);
    float muscular_curl_gain = 1.0;
};
```

Legacy `peristalsis_amplitude` / `peristalsis_wave_speed` /
`peristalsis_wavelength` retained as sugar — when set, they synthesize
a sinusoidal contribution to `muscle[s,θ]`. Existing scenarios that
wrote these channels continue to work without source changes. The
sugar layer lives in `CanalMuscleField::set_peristalsis`.

### §10.4 — Hero authoring (canal interior addition)

Add new steps to the Blender pipeline list:

> 9. **Model canal interiors directly in the body mesh.** Cavities
>    are invaginations (existing step 2) extended inward through their
>    full anatomical length. Static features — haustra (colon),
>    taeniae (longitudinal ridges), Houston's valves (rectal folds),
>    anal columns, rectal columns — are modeled as mesh geometry, not
>    added by procedural displacement. The modeled rest pose is what
>    the runtime starts from; the `tunnel_state` texture +
>    centerline-driven vertex shader (§6.12) deforms it per tick.
>
>    **Curved canals are fully supported.** Bend the canal naturally
>    into the belly, around the pelvic floor, through the diaphragm —
>    whatever anatomy demands. Constraints:
>      - Tubular topology (each cross-section perpendicular to the
>        centerline is convex and contains the centerline).
>      - No fold-back (the centerline doesn't double back on itself
>        within less than ~one canal radius).
>      - No self-intersection in the modeled mesh.
>      - Sufficient CP bone density for the curvature (rule of thumb:
>        one CP bone per ~5° of bend, or one per anatomical landmark).
>        A vagina tilting toward the lumbar takes 6 CP bones; a colon
>        with hepatic + splenic flexures takes 10–14.
>
>    **Sacs vs canals.** Tubular canals (vagina, esophagus, colon,
>    rectum, urethra) use the Canal primitive with two anchor orifices
>    end to end. **Closed-end sacs (uterus, bladder)** use the Canal
>    primitive with `closed_terminal = true` — distal centerline
>    particle hard-pinned at a `<Canal>_TerminalPin` bone position
>    instead of anchored to an exit orifice. **Two-opening sacs
>    (stomach)** use the Canal primitive with both `entry_orifice_path`
>    (cardia) and `exit_orifice_path` (pylorus) plus an aggressively
>    variable `rest_radius_profile` to capture the J-shape. Plastic
>    memory parameters can be tuned per-canal: high `plastic_max_offset`
>    + slow `plastic_recover_rate` for uterine remodeling under
>    sustained pressure; modest values for daily-use canals.
>
>    **Out of current scope:** small intestine (~6 m of curls — segment
>    at major flexures if ever needed), bladder (Canal with closed
>    terminal works but unused gameplay-wise), oral cavity (uses §6.6
>    jaw special case, not Canal). The dedicated `Cavity` primitive is
>    deferred until a gameplay scenario demands it.
>
> 10. **Mark canal interior verts** by selecting them in Blender and
>    assigning canal_id via a one-click operator that writes
>    `CUSTOM0.r = canal_index + 1`. **No skin weight painting on canal
>    interior verts.** They are not bone-driven — the vertex shader
>    routes them to the simulation pipeline (deformed centerline +
>    `tunnel_state` texture + per-vert baked (s, θ, rest_radius,
>    normal) in `CUSTOM1` + `CUSTOM2`).
>
>    The "assign to canal" Blender operator is a small bpy script
>    (~50 lines) shipped under `tools/blender/` that writes the
>    custom attribute on all selected verts. Authoring tooling todo:
>    a complementary cell-grid overlay (visualizes the canal's
>    `axial_segments × angular_sectors` grid on the modeled mesh) so
>    the artist can align features with cell boundaries.
>
> 11. **Place canal centerline CP bones** (`<Canal>_CP_*`) along each
>    canal's anatomical axis. Each CP bone is a non-deforming bone
>    parented to a host body bone (typically pelvis/lumbar/abdomen),
>    with optional local offset. The AutoBaker derives the canal
>    spline from these bones at scene init. Per-canal CP count is a
>    free authoring choice (typically 4–14 depending on curvature).
>
>    **For closed-terminal sacs**: also place a `<Canal>_TerminalPin`
>    bone at the closed distal position. AutoBaker reads it as the
>    fixed pin location for the centerline chain's distal particle.
>
> 12. **(Optional) Paint a rim ↔ canal transition blend factor** in
>    `CUSTOM2.a` for verts in the 1–2 cm band where rim influence
>    fades to canal influence. Default zero everywhere = pure canal
>    path. Default one in rim region = pure rim path. Smooth gradient
>    in the band gives a clean visual transition; the vertex shader
>    lerps between rim displacement (existing §6.1 path) and canal
>    displacement (new §6.12 path).
>
> 13. **AutoBaker runs at scene init**: per canal interior vert,
>    computes `(s, θ, rest_radius_at_vert, rest_outward_normal)` from
>    the rest-pose vert's projection onto the rest centerline, writes
>    them to `CUSTOM1` + `CUSTOM2`. One-time at scene load; never
>    re-runs at runtime. Cost: ~50 ops per canal interior vert × ~10K
>    canal verts = ~500K ops per canal at load. Sub-millisecond.

Skin weighting summary:
- **Canal interior verts** (`canal_id ≥ 1` via `CUSTOM0.r`) → no bone
  weights at all. Driven by the canal's centerline chain + texture via
  the vertex shader. Per-vert baked (s, θ, rest_radius, normal)
  replaces skin weights entirely.
- **Inner rim loop verts at orifices** → rim anchor bones with §6.1
  bracketing-pair angular interpolation, falloff radius
  `OrificeProfile.physics_rim.anchor_falloff_radius_mm`.
- **Body skin verts** (everything else) → standard host-body rig +
  bulger array displacement per §7.1.
- **Rim/canal transition band** → optional blend factor in `CUSTOM2.a`,
  shader lerps both paths.

**No JSON sidecar.** All authoring metadata is carried by:
- Bone naming convention (`<Prefix>_RimAnchor_*`,
  `<Canal>_CP_*`, `<Canal>_TerminalPin`, `<Prefix>_Center`).
- Vertex custom attributes (`CUSTOM0.r` canal_id, `CUSTOM1`/`CUSTOM2`
  baked geometry — written by AutoBaker, not authored manually).
- Vertex group `canal_interior_<name>` (used by the bpy operator that
  populates `CUSTOM0.r`; vertex group itself isn't read at runtime).
- `OrificeProfile.tres` / `CanalParameters.tres` Resource files
  (carry numeric parameters: rim particle counts, falloff radii,
  rest-radius profile curves, plastic params, wall response rate,
  constriction zones, muscle field rest values, centerline chain
  compliance, etc.).

### §10.6 — `OrificeAutoBaker` (canal addition)

Add to the AutoBaker steps:

> 6. **For each canal, derive the spline from CP bones.** Scan the
>    skeleton for bones matching `<Canal>_CP_*`, sort by index, build
>    a Catmull spline through their resolved world positions. Store
>    on the corresponding `CanalParameters` resource.
>
> 7. **Compute the canal's per-cell rest radius** (`canal_axial_segments
>    × canal_angular_sectors`). For each cell at `(s_k, θ_j)`, cast a
>    ray from the spline at `s_k` outward in the angular direction
>    `θ_j` and record distance to the canal interior mesh wall. This
>    populates the `rest_radius_per_cell` table consumed by §6.12
>    integration.
>
> 8. **Allocate the canal's `tunnel_state` RGBA32F texture** sized
>    `canal_axial_segments × canal_angular_sectors`. Initialize all
>    cells to `(rest_radius, 0, 0, 1.0)`.
>
> 9. **Allocate the canal's centerline particle chain** (§6.12.1).
>    M particles spaced uniformly along the rest spline; rest
>    positions stored in `rest_positions_in_host_frame`. Anchor
>    constraint:
>    - Proximal particle pinned to the entry orifice's Center frame.
>    - Distal particle pinned to either:
>      - The exit orifice's Center frame (open canals: vagina,
>        colon, esophagus, etc.), OR
>      - The `<Canal>_TerminalPin` bone position (closed-terminal
>        sacs: uterus, bladder).
>    Default M = 12; configurable per canal via
>    `CanalParameters.centerline_particle_count`.
>
> 10. **Per canal interior vert, bake `(s, θ, rest_radius_at_vert,
>    rest_outward_normal)`.** Iterate vertices with `CUSTOM0.r ≥ 1`,
>    project each onto the corresponding canal's rest centerline:
>    - `s` = arc length of the projection on the spline
>    - `θ` = angular position around the spline tangent at s
>    - `rest_radius_at_vert` = signed distance from the spline axis
>    - `rest_outward_normal` = the vert's authored normal in canal-
>      local frame (decomposed from world-space normal via rest spline
>      basis at s)
>    Write `(s, θ, rest_radius)` into `CUSTOM1.rgb`,
>    `rest_outward_normal` into `CUSTOM2.rgb`, leave `CUSTOM2.a` for
>    optional rim-blend factor.

Step 4 of the existing AutoBaker (tunnel girth profile via
perpendicular ray casts) is now subsumed by step 7 above for
procedurally-derived canals; retained for orifice tunnel-projection
lookup at the entry plane.

### `CanalParameters` Resource (NEW)

```
class_name CanalParameters
extends Resource

# ─── Identity + linkage ────────────────────────────────────────────
@export var canal_name: StringName
@export var entry_orifice_path: NodePath
@export var entry_loop_index: int = 0          # which rim loop on the entry orifice
@export var exit_orifice_path: NodePath        # null for closed-terminal canals
@export var exit_loop_index: int = 0
@export var spline_cp_bone_prefix: StringName  # "Vag_CP", "Col_CP" etc.

@export var closed_terminal: bool = false      # uterus, bladder
@export var terminal_pin_bone: StringName      # "Uterus_TerminalPin"
                                               # if closed_terminal && bone exists,
                                               # AutoBaker uses bone position;
                                               # else uses terminal_position_in_host_frame
@export var terminal_position_in_host_frame: Vector3 = Vector3.ZERO

# ─── Resolution ────────────────────────────────────────────────────
@export var canal_axial_segments: int = 32
@export var canal_angular_sectors: int = 8
@export var centerline_particle_count: int = 12

# ─── Rest pose ─────────────────────────────────────────────────────
@export var rest_radius_profile: Curve         # axial fallback
                                               # (per-cell from AutoBaker
                                               # overrides this if available)
@export var min_wall_radius: float = 0.001     # safety floor

# ─── Wall dynamics (texture path) ──────────────────────────────────
@export var wall_response_rate: float = 30.0   # 1/s, first-order lag
@export var use_second_order_wall: bool = false
@export var wall_acceleration_gain: float = 1.0
@export var wall_damping: float = 5.0
@export_enum("damage", "wall_radial_velocity", "friction_mult") \
    var fourth_channel_mode: int = 0           # which channel goes in RGBA32F's 4th slot

# ─── Plastic memory (radial) ───────────────────────────────────────
@export var plastic_accumulate_rate: float = 0.05
@export var plastic_recover_rate: float = 0.001
@export var plastic_max_offset: float = 0.02

# ─── Centerline particle chain (§6.12.1) ───────────────────────────
@export var centerline_distance_compliance: float = 1e-6
@export var centerline_bending_compliance: float = 1e-4
@export var centerline_spring_back_compliance: float = 1e-3
@export var centerline_lateral_compliance: float = 1e-2
@export var lateral_plastic_accumulate_rate: float = 0.02
@export var lateral_plastic_recover_rate: float = 0.0005
@export var lateral_plastic_max_offset: float = 0.01

# ─── Curvature → wall asymmetry ────────────────────────────────────
@export var curvature_response_gain: float = 0.3

# ─── Damage ────────────────────────────────────────────────────────
@export var damage_rate: float = 0.05
@export var damage_plastic_gain: float = 5.0     # multiplier on plastic_max
@export var damage_friction_loss: float = 0.5    # subtract from friction mult

# ─── Muscle / constriction (texture path) ──────────────────────────
@export var contraction_gain: float = 1.0
@export var surface_vel_gain: float = 0.3
@export var muscle_friction_gain: float = 2.0
@export var constriction_zones: Array[CanalConstrictionZone]
@export var rest_muscle_field_2d: Texture2D    # optional baseline
                                               # asymmetric activation

# ─── Active muscular curl (centerline) ─────────────────────────────
@export var muscular_curl_gain: float = 1.0
```

---

## Comparison vs. current spec

| Dimension | Current spec (rim-loop, 2026-05-03) | New (modeled + 2D texture + centerline chain) |
|---|---|---|
| Canal interior representation | Sequence of N PBD rim loops along tunnel axis | 2D `tunnel_state` texture (32×8 cells) + 12-particle centerline chain |
| Canal bend under load | Implicit via per-loop spring positions; coarse | First-class via PBD centerline chain with bilateral wall/centerline split |
| Authoring per canal feature | Place 16 anchor bones + paint skin weights + add to OrificeProfile.rim_loops | Add `CanalConstrictionZone` entry to resource |
| Bones for a typical colon | ~144 (9 loops × 16 anchors) | 0 (orifice-only — anus has 16) + ~10 CP bones |
| Per-vert weight painting on canal interior | Required | Not required — canal_id marker + AutoBaker bake replaces it |
| Rim particles per canal | 144 | 0 (canal interior is texture state + chain) |
| XPBD constraints per canal per tick | ~144 distance + ~9 volume + ~144 spring per loop iteration | 12 distance + 10 bending + 12 spring on the centerline chain |
| Texture state per canal | None | 4 KB (32×8×RGBA32F) + 144 bytes centerline uniform |
| CPU integration per canal per tick | None | ~85K ops (centerline + wall + bulger SDF) |
| Plastic deformation memory | Not in spec | First-class, per-cell radial + per-particle lateral |
| Asymmetric multi-tentacle deformation | Per-loop only at loop positions; interpolated between | Per-cell along entire canal length + centerline lateral bend |
| Air pockets from fast tentacle wiggle | Not in spec — bulger displacement is kinematic | First-class via `wall_response_rate` lag (+ optional second-order ringing) |
| Decoupled squeeze ↔ propulsion | Coupled via `peristalsis_amplitude` + `_wave_speed` | Independent: `radius_mult` (squeeze), `axial_surface_vel` (propulsion), `muscular_curl` (bend) |
| Active intake drag without squeeze | Only via reverse `peristalsis_wave_speed` | Native via negative `axial_surface_vel` |
| Static features (haustra, valves, columns) | Per-loop bones | Modeled directly in Blender mesh + optional zone overlay |
| Through-path coupling (tentacle deforms multiple canals) | Per-loop, via separate per-canal loops | Bulger SDF queried globally per-cell, every canal sees every bulger |
| Sacs (uterus, bladder, stomach) | Awkward to express | Canal with `closed_terminal` or two-opening + variable rest profile |
| Curved canals | Awkward — per-loop bones at every bend | First-class — sufficient CP bone density does it |
| Authoring tool burden | Blender + per-loop bone placement script + skin painting per feature | Blender mesh + bone naming + click-to-assign + Resource files |
| Hot-path C++ surface | XPBD constraint solving per loop (existing 5A pattern extended) | Centerline chain (~12 particles, existing 5A pattern reused 1×) + texture cell update loop |

**Authoring cost reduction:** ~5–10× for canal interiors.
**Runtime cost reduction:** ~3–5× total per hero.
**Realism:** improved on every measurable axis, including canal bend.

---

## Improvements folded in

Beyond the texture model itself:

1. **Bendable centerline particle chain.** Real canals bend visibly
   under load. The PBD chain + bilateral wall/centerline split routes
   asymmetric pressure into both wall radius (texture) AND centerline
   lateral shift, producing geometrically correct deformation.

2. **No per-vert skin weights on canal interiors.** Single canal_id
   marker + AutoBaker bake replaces traditional skinning entirely.
   Authoring drops to "model + click + done."

3. **Curvature → wall asymmetry.** Tight bends in the centerline
   compress wall on inside, stretch on outside — visible asymmetric
   deformation that's geometrically correct.

4. **Per-cell damage channel** on `tunnel_state`. Sustained pressure
   accumulates; high-damage cells get larger `plastic_max_offset`
   locally (anatomically grounded — damaged tissue remodels with more
   permanent stretch). Damage also reduces friction (worn tissue
   slips easier).

5. **Active muscular curl modulation** per centerline particle. Reverie
   can author behaviors like "the canal flexes around the tentacle"
   independent of radial squeeze. Anatomically real (haustral
   coordination, vaginal walls under pelvic floor activation).

6. **Hierarchical canal activation.** Inactive canals (no EI, no
   storage content, no modulation) skip both centerline tick and
   texture integration. Most canals are inactive most of the time.

7. **Concrete bulger SDF formula** specified, not left as
   `bulger_SDF_at(s_k, θ_j)` black box. Sub-Claude doesn't need to
   reinvent it during 5F implementation.

8. **Wall response stability clamp.** First-order lag's gain
   `rate * dt` defensively clamped to `< 1`. Documented as a §14
   gotcha.

9. **Pumping resonance** identified as discoverable phenomenon.
   `Gameplay_Mechanics.md` gets a hidden-phenomenon entry.

10. **Sacs supported via Canal with `closed_terminal`** — uterus and
    bladder don't need a separate primitive. Two-opening sacs (stomach)
    use the standard Canal with both entry + exit + variable rest
    profile.

11. **Plastic memory along the centerline.** Sustained sideways
    pressure produces a small permanent bend that recovers slowly.
    Anatomically real ("a canal that's been used a lot remembers it
    in its shape").

12. **Optional second-order wall dynamics.** `wall_radial_velocity`
    per cell + acceleration gain + damping give true ringing/overshoot
    when desired. Default off (canals are heavily damped tissue;
    first-order suffices).

13. **Per-cell friction multiplier** for sticky patches / slippery
    sections. Authored statically (rest map) or dynamically (Reverie
    writes spasm/grip patterns).

---

## CLAUDE.md non-negotiable updates

In `extensions/tentacletech/CLAUDE.md`, add to the "in scope" / "never"
lists:

**New (in scope):**
- Canal interior model: 2D `tunnel_state` RGBA32F texture per canal
  (CPU-integrated, GPU-uploaded each tick, indexed by
  `(arc_length_sample, angular_sector)`) + centerline particle chain
  (M PBD particles, default 12, anchored at orifice Centers or closed
  terminals). Per-cell channels: `dynamic_wall_radius`,
  `plastic_offset`, `damage`, configurable fourth slot. Hierarchical
  activation skips integration for inactive canals.
- Constriction zones replace per-feature rim loops along canal axes.
  Zone is pure data on `CanalParameters` resource.
- Muscle activation field (`muscle[s,θ]`) is the canonical Reverie
  modulation primitive for canal interior; legacy `peristalsis_*`
  channels are sugar.
- Active muscular curl (per-centerline-particle delta) is the
  canonical Reverie modulation primitive for canal *bend*.
- Canal interior verts (`CUSTOM0.r ≥ 1`) carry no skin weights.
  Per-vert bake (s, θ, rest_radius, normal) in `CUSTOM1`/`CUSTOM2`
  replaces them; vertex shader routes via the simulation pipeline.

**Never:**
- Per-vert weight painting on canal interior verts. The
  `canal_id`-tagged path is exclusive — these verts are simulation-
  driven, not bone-driven.
- Procedural canal mesh generation. Canals are hand-modeled in
  Blender; static features (haustra, taeniae, valves, columns) are
  baked into the modeled mesh.

**Replace / clarify (existing):**
- "Per-rim-particle quantities use `_per_loop_k[l][k]`" — clarify
  that this applies **only to orifice rim loops**, not to canal
  interior features. Canal interior features use `_per_cell_kj[k][j]`
  indexing on the 2D `tunnel_state` texture and `_per_centerline[m]`
  for the centerline particle chain.

**Bulger architecture clarification:**
- Vertex shader displacement path splits at vertex group boundary:
  body skin verts read bulger uniform array (§7.1); canal interior
  verts (`CUSTOM0.r ≥ 1`) read the canal's `tunnel_state` texture +
  deformed centerline. Single texelFetch per canal vert; canal texture
  already incorporates bulger contributions via CPU integration.

---

## Knock-on effects elsewhere

| Doc | What changes |
|---|---|
| `docs/architecture/TentacleTech_Architecture.md` §6.1 | Retire "Compound openings" sub-bullet of multi-loop support paragraph. Multi-loop refers only to stacked loops at one rim, not axial sequences. |
| `docs/architecture/TentacleTech_Architecture.md` §6.7 | Rewritten per "Through-path tunnels" canonical text above. Each linked canal owns its own `tunnel_state` texture + centerline chain; bulger SDF queries are global per-cell. |
| `docs/architecture/TentacleTech_Architecture.md` §6.9 | "Mechanical scope" paragraph rewritten to drive `muscle[s,θ]` field rather than per-loop `target_enclosed_area`. Wedge math generalized to per-cell. |
| `docs/architecture/TentacleTech_Architecture.md` §6.10 | ContractionPulse contribution rewritten as additive contribution to `muscle[s,θ]`. Atomic struct unchanged. Pattern emitters (OrgasmPattern etc.) unchanged. |
| `docs/architecture/TentacleTech_Architecture.md` §6.12 | NEW SECTION — full canal interior texture model + centerline particle chain (canonical text above). |
| `docs/architecture/TentacleTech_Architecture.md` §7.1 | Add note: vertex shader path splits at canal_id (CUSTOM0.r); canal interior verts sample `tunnel_state` texture + deformed centerline, not bulger array. |
| `docs/architecture/TentacleTech_Architecture.md` §7.2 | Add note: canals' per-tick CPU integration consumes bulger array as SDF source globally; no canal-ownership filtering. Concrete bulger SDF formula in §6.12.4. |
| `docs/architecture/TentacleTech_Architecture.md` §8.2 | Add `set_muscle_activation`, `apply_muscle_pattern`, `axial_surface_vel_gain`, `set_constriction_zone_strength`, `set_muscular_curl_delta`, `muscular_curl_gain` to `OrificeModulation`. Note legacy `peristalsis_*` are sugar. |
| `docs/architecture/TentacleTech_Architecture.md` §10.4 | Add steps 9–13 (model canal interiors, mark canal_id, place CP bones + optional TerminalPin, optional rim/canal blend, AutoBaker bake). State explicitly "no JSON sidecar" + "no skin weights on canal interior verts." Curved canal + sac authoring guidance. |
| `docs/architecture/TentacleTech_Architecture.md` §10.6 | Add AutoBaker steps 6–10 (derive canal spline from CP bones, compute per-cell rest radius via raycasts, allocate `tunnel_state` texture, allocate centerline particle chain, per-vert bake of (s, θ, rest_radius, normal) into CUSTOM channels). |
| `docs/architecture/TentacleTech_Architecture.md` §14 | Add gotchas: `wall_response_rate * dt < 1` stability constraint; pumping resonance discoverability; centerline bend doesn't drive host-bone movement (only rim loops do). |
| `extensions/tentacletech/CLAUDE.md` | Add canal interior model + centerline chain + constriction zones + muscle field + curl modulation to in-scope. Clarify `_per_loop_k` indexing applies to rim only; introduce `_per_cell_kj` for canal interior + `_per_centerline[m]` for centerline chain. Add never-rule: no per-vert skin weights on canal interior verts. |
| `docs/architecture/Reverie_Planning.md` §3.5 / §6.5 | Update peristalsis modulation references — Reverie writes `muscle[s,θ]` patterns + per-particle `muscular_curl_delta` rather than `peristalsis_amplitude` triplet. Existing reaction profiles continue to work (sugar layer); new profiles get spatial control. |
| `docs/Description.md` / `docs/Gameplay_Mechanics.md` | "Ring bone pulsing" → "rim pulsing at orifices, canal wall undulation + canal bend in interiors." Mention plastic memory, air pockets, and pumping resonance as discoverable phenomena. |
| `docs/Cosmic_Bliss_Update_2026-05-03_orifice_rim_model.md` | Status header gains a forward-pointer: "compound openings sub-bullet superseded 2026-05-04 by `Cosmic_Bliss_Update_2026-05-04_canal_interior_model.md`." |
| `docs/marionette/Marionette_plan.md` | No change — Marionette is rim-physics-agnostic. CP bones are rigged to host body bones via standard rig. |
| `docs/pbd_research/findings_obi_synthesis.md` | Add: per-cell texture integration + centerline chain + per-vert (s,θ) bake for canal interior is not Obi-derived; Obi handles rim-particle XPBD only. |

---

## Phase impact

**Currently in flight:** Phase 5 (Orifice). 5A + 5B + 5C-A + 5C-B +
5C-C done (third-law loop closed 2026-05-04). Pending: 5D (realism
sub-slices 4P-A/B/C). None of these are affected by this amendment —
they operate on the rim particle loop primitive at orifice boundaries,
which stays.

**New / re-scoped slices** (deferred Phase 5 work, after 5D):

- **5E — Canal infrastructure.** `Canal : Node3D` registration,
  `CanalParameters` Resource, AutoBaker spline derivation from
  `<Canal>_CP_*` bones + optional `<Canal>_TerminalPin`, per-cell
  rest_radius computation, `tunnel_state` texture allocation,
  **`CanalCenterline` particle chain allocation** (M particles
  spaced along the rest spline, anchor pins at endpoints), **per-vert
  AutoBaker bake of (s, θ, rest_radius, normal) into CUSTOM1/CUSTOM2**.
  Mostly GDScript per CLAUDE.md split (no hot-path C++).
  Test scene: a single canal with a static rest pose and gizmo overlay
  showing texture cells + centerline chain + per-vert bake validation.

- **5F — Canal texture dynamics + centerline chain dynamics.**
  Per-tick CPU integration loop (`dynamic_wall_radius`, `plastic_offset`,
  `damage`, optional fourth channel), bulger SDF query per cell with
  the concrete formula from §6.12.4, **bilateral wall/centerline
  split**, **centerline curvature → wall asymmetry**, centerline chain
  PBD tick (distance + bending + spring-back + lateral plastic),
  texture upload, vertex shader sampling for canal interior verts.
  Hierarchical activation gating. GDScript with potential C++ promotion
  if profiling demands it.

- **5G — Muscle activation field + constriction zones + active
  muscular curl.** Reverie modulation API (`set_muscle_activation`,
  zone strength setters, `set_muscular_curl_delta`), derivation of
  `radius_mult`, `axial_surface_vel`, friction multiplier from muscle
  field, per-particle curl delta into the centerline chain spring-back
  rest. Backward-compat sugar for legacy `peristalsis_*` channels.

- **§6.7 through-path linking** (existing planned slice) implements
  per-canal coupling via global bulger SDF + per-canal centerline
  chains.

- **§6.8 storage chain, §6.9 oviposition, §6.10 ContractionPulse,
  §6.11 RhythmSyncedProbe** — all consume the new texture + chain
  model; largely unaffected at the API level.

---

## Apply checklist for top-level Claude

1. ✅ This doc written.
2. **Wait for 5D to land** before applying any of the architecture-doc
   edits below. The amendment doesn't affect 5C-C / 5D in flight, but
   applying now risks stale references if 5D drift reshapes the
   cross-cutting sections.
3. **Apply edits to `TentacleTech_Architecture.md`** §6.1, §6.7, §6.9,
   §6.10, §7.1, §7.2, §8.2, §10.4, §10.6, §14 per the canonical text
   in this doc. Add new §6.12 (Canal interior texture model +
   centerline chain). Add `CanalParameters` Resource definition near
   the existing `OrificeProfile` definition in §10. Update §1
   architecture diagram to show canal-interior texture + centerline
   chain as a distinct subsystem.
4. **Apply edits to `extensions/tentacletech/CLAUDE.md`** —
   in-scope additions, never-rule on per-vert skin weights for canal
   interior, indexing-convention clarifications, vertex shader path
   split note.
5. **Apply edits to `docs/architecture/Reverie_Planning.md`** —
   peristalsis modulation references updated; `muscle[s,θ]` +
   `muscular_curl_delta` become the canonical primitives. Sugar layer
   preserved.
6. **Apply edits to `docs/Description.md` + `docs/Gameplay_Mechanics.md`** —
   canal interior phenomenology language updated; pumping resonance
   added as a hidden phenomenon.
7. **Apply edit to `docs/Cosmic_Bliss_Update_2026-05-03_orifice_rim_model.md`** —
   add forward-pointer note in status header.
8. **Phase planning update in `extensions/tentacletech/CLAUDE.md`** —
   add 5E / 5F / 5G slice entries with clear scope (revised per
   centerline chain + per-vert bake additions). 5C-C ✅ done; 5D
   remains ahead of them in the queue.
9. **Author the Blender bpy operators** (`tools/blender/`) for
   "assign canal id to selected verts" + "visualize cell grid" before
   sub-Claude implements 5E so the artist workflow is testable.
