# Cosmic Bliss — Design Update 2026-05-04 — Canal interior model

> **Status: drafted 2026-05-04, awaiting application.** Replaces the
> "compound openings — sequence of rim loops along tunnel axis"
> interior model from `docs/Cosmic_Bliss_Update_2026-05-03_orifice_rim_model.md`
> §6.1 with a 2D `tunnel_state` texture model. Rim particle loops remain at
> orifice boundaries only. Lineage: extended discussion 2026-05-03/04 covering
> character-creation pipeline, asymmetric multi-tentacle deformation,
> plastic memory, wall-lag air pockets, and decoupled squeeze/propulsion.
> User direction 2026-05-04: model canal interiors in Blender (no procedural
> generation), no JSON sidecar, naming convention only, 2D texture state.

**Audience: top-level Claude (canonical record). Sub-Claude reads the
architecture doc, not this one.**

---

## TL;DR

The 2026-05-03 rim-loop amendment correctly removed the 8-direction-bone
model from orifices. It also extended the rim-loop primitive into the canal
interior via "compound openings — a sequence of loops along the tunnel
axis" (§6.1, line 615). For canals like the colon, this means N PBD rim
loops along the canal length — one per haustral boundary, one per Houston's
valve, etc. — each with its own anchor bones, skin weights, and per-tick
XPBD constraint solving.

Authoring cost is high (one rim anchor bone set per feature, ~144 bones in
a colon with 8 haustra), and runtime cost compounds (PBD constraint solving
on every interior loop). Several behaviors that gameplay/realism wants are
not naturally expressible in the rim-loop model:

- Plastic deformation memory (canals retain stretch over time).
- Wall lag producing air pockets when a tentacle wiggles faster than the
  wall can respond.
- Decoupled squeeze (visual contraction) versus propulsion (axial drive).
- Active intake drag (canal grabs and pulls without squeezing).
- Many cheap constriction zones (haustra, valves, ad-hoc sphincters).

The new model:

1. **Rim particle loops only at true orifices** (mouth, anus, vagina×2,
   cervix, optionally cardia/pylorus). Multi-loop per orifice (§6.1
   amendment) is unchanged. The "compound openings — sequence along
   tunnel axis" sub-bullet is retired.

2. **Canal interior is texture-driven.** Each canal owns a 2D
   `tunnel_state` RGBA32F texture indexed by `(arc_length_sample,
   angular_sector)` — typically 32×8 or 64×8 cells. CPU integrates
   per-tick wall dynamics from authored modulation + bulger SDF input;
   shader samples for vertex displacement; PBD type-3 collision reads
   the same texture for wall position and friction.

3. **Canal mesh is hand-modeled in Blender**, part of the continuous
   hero mesh. No procedural tube generator. Canal interior verts skin
   to host body bones via standard rig; rim region verts skin to rim
   anchors with §6.1 falloff. Static features (haustra, taeniae,
   Houston's valves, anal columns, rectal columns) are baked into the
   modeled mesh.

4. **Constriction zones** replace per-feature rim loops. A zone is
   pure data (`{arc_length_s, half_width, max_contraction,
   current_strength, friction_bonus, baked_at_rest}`) on the canal's
   resource. Many zones cost essentially nothing.

5. **Muscle activation field** unifies modulation. Reverie writes a
   per-cell `muscle[s,θ]` field; physics derives `radius_mult`,
   `axial_surface_vel`, constriction strengths, and asymmetric
   contraction patterns from it. Replaces the ad-hoc
   `peristalsis_*` channel triplet (kept as backward-compat sugar).

6. **Authoring uses bone naming convention** — `<Prefix>_RimAnchor_*`
   (existing) for orifice rim anchors and `<Canal>_CP_*` (new) for
   canal centerline control points. **No JSON sidecar.**

Authoring cost drops 5–10× for canal interiors (no per-haustra bones).
Runtime cost drops 3–5× (orifice rim particles only; texture work is
cheaper than chained PBD loops). Realism increases on every measurable
axis (plastic memory, asymmetric deformation, air pockets, decoupled
propulsion, intake drag, dense constriction zones).

---

## What changes (canonical text — to be applied to architecture doc)

### §6.1 — Rim structure (amendment to the 2026-05-03 amendment)

**Retire** the "Compound openings (ribbed canal, multiple sphincters along
a single tunnel)" sub-bullet of the multi-loop support paragraph (line
615). Compound axial sequencing of rim loops is no longer the canal
interior model. The remaining multi-loop configurations stay:

- **Single loop** (default): one rim loop, simple orifice.
- **Outer + inner loop** (anatomical): outer "lip" + inner "opening"
  with differential stiffness and inter-loop coupling springs.
- **Decorated rim** (jewelry, prosthetic): inner anatomical opening +
  high-stiffness decorative outer.

Multi-loop per orifice continues to refer to **stacked loops at a single
rim location** (lips + opening), not sequences of loops along a tunnel.
Canal interior dynamics are the §6.12 texture model.

### §6.7 — Through-path tunnels (rewritten)

A tentacle may traverse multiple orifices as a chained path. Each
`EntryInteraction` may be linked head-to-tail with another belonging to a
different orifice on the same hero.

- Each `EntryInteraction` gains optional `downstream_interaction` and
  `upstream_interaction` pointers.
- Tunnel projection sums along the linked chain; the tentacle spline
  passes through all orifices' tunnel splines in sequence.
- Capsule suppression (§10.5) unions the suppression lists of all
  chained orifices.
- Bulger sampling (§7.2) covers the full chained interior — allocate 6
  samples per orifice in the chain, not 6 samples per tentacle.
- AI targeting uses the entry orifice only; the exit orifice is
  emergent from physics.
- Chain linking is detected by proximity: when a penetrating tentacle's
  tip enters a second orifice's entry plane while still engaged
  upstream, a downstream `EntryInteraction` is created and linked.
- **Each linked tunnel has its own `tunnel_state` texture (§6.12).**
  Bulger SDF queries are global — every active canal sees every active
  bulger regardless of which orifice the bulger's tentacle entered
  through. A tentacle spanning vagina → cervix → uterus deforms the
  vaginal, cervical, and uterine wall textures simultaneously through
  per-cell SDF evaluation.

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
                        bulger_SDF_at(s_k, θ_j))
```

The dynamic_wall_radius integration (§6.12) lags the target with finite
response rate; the result feeds both the vertex shader (visual
displacement) and type-3 collision (wall position).

Beads in the wave's low-radius phase experience asymmetric ring
pressure producing net axial force; expulsion (high amplitude, positive
wave speed) and ingestion/retention (negative wave speed, or
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

The canal interior between orifices is governed by a **2D `tunnel_state`
texture** per canal, sampled by both vertex shader (for visual wall
displacement) and PBD type-3 collision (for wall position and friction).
Texture resolution is per-canal (`canal_axial_segments` ×
`canal_angular_sectors`), default 32×8, packed as RGBA32F.

**State channels** (CPU-integrated, GPU-uploaded each tick):

```cpp
struct TunnelStateCell {
    float dynamic_wall_radius;  // current effective wall radius (m)
    float plastic_offset;       // accumulated stretch memory (m)
    float wall_radial_velocity; // optional, for second-order ringing
    float free_or_friction_mult;// per-cell Coulomb μ multiplier
};
```

**Modulation inputs** (Reverie-writable, evaluated per tick):

```cpp
struct CanalMuscleField {
    // Spatial muscle activation, 0..1 per cell.
    // Reverie writes spatial patterns; physics derives consequences.
    Vector<Vector<float>> muscle;  // [axial][angular]

    // Sugar accessors (backward-compat with existing peristalsis channels):
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
                              // (zero if purely dynamic)
};
```

**Per-tick CPU integration** (per canal):

```
for each cell (s_k, θ_j) in canal.tunnel_state:
    # 1. Evaluate muscle activation
    muscle = canal.muscle_field.evaluate(s_k, θ_j, t)
    for each zone z in canal.constriction_zones:
        d = abs(s_k - z.arc_length_s)
        if d < z.half_width:
            falloff = smoothstep(z.half_width, 0, d)
            muscle += z.current_strength * z.max_contraction * falloff

    # 2. Compute target wall radius for this cell
    rest = canal.rest_radius_profile[s_k]
    target = max(
        rest + plastic_offset[k][j] - rest * muscle * 0.5,  # axisymmetric squeeze
        bulger_SDF_at(s_k, θ_j),                             # contact pressure
        canal.min_wall_radius,                               # safety floor
    )

    # 3. Integrate dynamic_wall_radius with finite response rate
    delta = (target - dynamic_wall_radius[k][j]) * canal.wall_response_rate * dt
    dynamic_wall_radius[k][j] += delta

    # (optional, second-order)
    if canal.use_second_order_wall:
        wall_radial_velocity[k][j] += delta * canal.wall_acceleration_gain
        wall_radial_velocity[k][j] *= (1 - canal.wall_damping * dt)
        dynamic_wall_radius[k][j] += wall_radial_velocity[k][j] * dt

    # 4. Plastic memory accumulation + recovery
    stretch = max(0, dynamic_wall_radius[k][j] - rest)
    plastic_offset[k][j] += max(0, stretch - plastic_offset[k][j])
                            * canal.plastic_accumulate_rate * dt
    plastic_offset[k][j] -= plastic_offset[k][j] * canal.plastic_recover_rate * dt
    plastic_offset[k][j] = clamp(plastic_offset[k][j], 0, canal.plastic_max_offset)

    # 5. Friction multiplier from muscle + zones
    friction_mult[k][j] = 1.0 + muscle * canal.muscle_friction_gain
```

Runtime cost: 32×8 = 256 cells × ~30 ops = ~8K ops per canal per tick.
Bulger SDF query per cell: 256 × N_bulgers × ~20 ops ≈ 50K ops with
N_bulgers=10. Trivial.

**Vertex shader sampling** (canal interior surfaces only — body skin
uses bulger array directly per §7.1):

```glsl
// Compute (s, θ) from VERTEX position via canal spline frame
vec2 st = canal_spline_project(VERTEX);
float dynamic_radius = texelFetch(tunnel_state_tex,
                                  to_cell(st), 0).r;
vec3 displacement = canal_outward_normal_at(st) *
                    (dynamic_radius - rest_radius_at(st));
VERTEX += displacement;
```

**Type-3 collision** (PBD particle vs. canal wall):

```
# Project tentacle particle position into canal (s, θ) coords
(s, θ) = canal.spline_project(particle.position)
wall_radius = sample_dynamic_wall_radius(s, θ)
if particle.dist_from_axis(s) > wall_radius - particle.collision_radius:
    project particle outward to wall_radius - particle.collision_radius
    record contact normal = canal_outward_normal_at(s, θ)

# Friction tangent uses surface velocity
axial_vel = sample_axial_surface_vel(s)
rel_vel_tangent = particle.velocity_tangent - axial_vel * spline_tangent
apply Coulomb friction with μ = base_μ * sample_friction_mult(s, θ)
```

**Surface velocity** (`axial_surface_vel`) is derived from the
longitudinal gradient of `muscle[s,θ]` averaged over θ. This is the
muscular wall-drag channel: positive = wall surface moves toward exit,
drags content out; negative = wall moves toward interior, pulls content
in. Independent of `radius_mult`, so a canal can pull without squeezing
or squeeze without pulling.

**Multi-tentacle asymmetric deformation** is handled natively. Two
tentacles in the same cross-section produce two bulger contributions;
each cell at (s, θ_j) takes its own SDF max; the wall develops a
peanut-shaped cross-section. The 2D state (per (s,θ) rather than per s)
is what enables this — a 1D scalar-per-arc-length state cannot represent
non-circular cross-sections.

**Hierarchical activation.** A canal with no active EntryInteraction, no
storage chain content, and no Reverie modulation skips texture
integration entirely. The shader continues to read the last-uploaded
texture (which is the rest pose). Reactivation occurs when an
EntryInteraction engages or Reverie writes a non-zero muscle value.
Most canals are inactive most of the time; this saves the bulk of the
runtime cost.

### §7.1 / §7.2 — Bulger feed into canal texture (additive)

The bulger array (§7.1) and its sources (§7.2) are unchanged. The new
consumer is each canal's per-tick CPU integration: when computing
`target_radius` per cell, the canal queries every active bulger for its
SDF contribution at that cell's world position. Bulgers are not
filtered by canal ownership — a tentacle's bulgers contribute to every
canal whose arc-length range overlaps the bulger's world position.

The vertex shader path also splits:
- **Body skin verts** (exterior + non-canal): displace from bulger array
  per the existing §7.1 inner loop. Unchanged.
- **Canal interior verts**: displace from `tunnel_state` texture. The
  texture already incorporates bulger contributions via CPU integration,
  so the shader does not loop over bulgers for these verts — single
  texelFetch per vert.

Identification of canal interior verts uses a vertex group / material
slot the artist assigns during authoring (§10.6 update). No sidecar
required.

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

    // Surface velocity (independent of squeeze). Positive = wall surface
    // moves toward exit, drags content outward. Negative = drags inward.
    float axial_surface_vel_gain = 1.0;  // scales derivation from muscle gradient

    // Constriction zones list (active modulation per zone strength).
    void set_constriction_zone_strength(int zone_index, float strength);
};
```

Legacy `peristalsis_amplitude` / `peristalsis_wave_speed` /
`peristalsis_wavelength` retained as sugar — when set, they synthesize a
sinusoidal contribution to `muscle[s,θ]`. Existing scenarios that wrote
these channels continue to work without source changes.

### §10.4 — Hero authoring (canal interior addition)

Add a new step to the Blender pipeline list:

> 9. **Model canal interiors directly in the body mesh.** Cavities are
>    invaginations (existing step 2) extended inward through their full
>    anatomical length. Static features — haustra (colon), taeniae
>    (longitudinal ridges), Houston's valves (rectal folds), anal
>    columns, rectal columns — are modeled as mesh geometry, not added
>    by procedural displacement. The modeled rest pose is what the
>    runtime starts from; the `tunnel_state` texture (§6.12) deforms it
>    per tick.
>
> 10. **Mark canal interior verts** with vertex group `canal_interior`
>    (or per-canal `canal_interior_<name>` if multiple canals share
>    material). The vertex shader uses this to route those verts to the
>    `tunnel_state` texture sampler instead of the bulger-array
>    displacement path.
>
> 11. **Place canal centerline bones** named `<Canal>_CP_0..M-1` along
>    each canal's anatomical axis. Each CP bone is a non-deforming bone
>    parented to a host body bone (typically pelvis/lumbar/abdomen),
>    with optional local offset. The AutoBaker derives the canal spline
>    from these bones at scene init. Per-canal CP count is a free
>    authoring choice (typically 4–8).

Skin weighting:
- Canal interior verts (the `canal_interior` vertex group) → host body
  bones only, standard rig weighting. They follow the body when the
  host moves; per-tick `tunnel_state` texture provides interior
  deformation on top.
- Inner rim loop verts at orifices → rim anchor bones with §6.1
  bracketing-pair angular interpolation, falloff radius
  `OrificeProfile.physics_rim.anchor_falloff_radius_mm`.

**No JSON sidecar.** All authoring metadata is carried by:
- Bone naming convention (`<Prefix>_RimAnchor_*`,
  `<Canal>_CP_*`, `<Prefix>_Center`).
- Skin weight assignments (rim falloff weights, body skin weights).
- Vertex groups (`canal_interior`, `canal_interior_<name>`).
- `OrificeProfile.tres` / `CanalParameters.tres` Resource files
  (carry numeric parameters: rim particle counts, falloff radii,
  rest-radius profile curves, plastic params, wall response rate,
  constriction zones, muscle field rest values, etc.).

### §10.6 — `OrificeAutoBaker` (canal addition)

Add to the AutoBaker steps:

> 6. **For each canal, derive the spline from CP bones.** Scan the
>    skeleton for bones matching `<Canal>_CP_*`, sort by index, build
>    a Catmull spline through their resolved world positions. Store
>    on the corresponding `CanalParameters` resource.
>
> 7. **Compute the canal's per-cell rest radius** (`canal_axial_segments
>    × canal_angular_sectors`). For each cell at (s_k, θ_j), cast a ray
>    from the spline at s_k outward in the angular direction θ_j and
>    record distance to the canal interior mesh wall. This populates
>    the rest_radius_per_cell table consumed by §6.12 integration.
>
> 8. **Allocate the canal's `tunnel_state` RGBA32F texture** sized
>    `canal_axial_segments × canal_angular_sectors`. Initialize all
>    cells to `(rest_radius, 0, 0, 1.0)`.

Step 4 of the existing AutoBaker (tunnel girth profile via perpendicular
ray casts) is now subsumed by step 7 above for procedurally-derived
canals; retained for orifice tunnel-projection lookup at the entry
plane.

### `CanalParameters` Resource (NEW)

```
class_name CanalParameters
extends Resource

# Identity + linkage
@export var canal_name: StringName
@export var entry_orifice_path: NodePath
@export var entry_loop_index: int = 0          # which rim loop on the entry orifice
@export var exit_orifice_path: NodePath        # null for closed-end canals
@export var exit_loop_index: int = 0
@export var spline_cp_bone_prefix: StringName  # "Vag_CP" etc.

# Resolution
@export var canal_axial_segments: int = 32
@export var canal_angular_sectors: int = 8

# Rest pose
@export var rest_radius_profile: Curve         # axial fallback (per-cell from
                                               # AutoBaker overrides this if available)
@export var min_wall_radius: float = 0.001     # safety floor

# Wall dynamics
@export var wall_response_rate: float = 30.0   # 1/s, first-order lag
@export var use_second_order_wall: bool = false
@export var wall_acceleration_gain: float = 1.0
@export var wall_damping: float = 5.0

# Plastic memory
@export var plastic_accumulate_rate: float = 0.05
@export var plastic_recover_rate: float = 0.001
@export var plastic_max_offset: float = 0.02

# Muscle / constriction
@export var contraction_gain: float = 1.0
@export var surface_vel_gain: float = 0.3
@export var muscle_friction_gain: float = 2.0
@export var constriction_zones: Array[CanalConstrictionZone]
@export var rest_muscle_field_2d: Texture2D    # optional baseline
                                               # asymmetric activation
```

---

## Comparison vs. current spec

| Dimension | Current spec (rim-loop, 2026-05-03) | New (modeled + 2D texture) |
|---|---|---|
| Canal interior representation | Sequence of N PBD rim loops along tunnel axis (compound openings) | 2D `tunnel_state` texture per canal (32×8 cells default) |
| Authoring per canal feature (haustra, valve) | Place 16 anchor bones + paint skin weights + add to OrificeProfile.rim_loops | Add `CanalConstrictionZone` entry to resource |
| Bones for a typical colon | ~144 (9 loops × 16 anchors) | 0 (orifice-only — anus has 16) |
| Rim particles per canal | 144 | 0 (canal interior is texture state) |
| XPBD constraints per canal per tick | ~144 distance + ~9 volume + ~144 spring per loop iteration | 0 |
| Texture state per canal | None | 4 KB (32×8×RGBA32F) |
| CPU integration per canal per tick | None | ~8K + ~50K SDF = ~60K ops |
| Plastic deformation memory | Not in spec | First-class, per-cell |
| Asymmetric multi-tentacle deformation | Per-loop only at loop positions; interpolated between | Per-cell along entire canal length |
| Air pockets from fast tentacle wiggle | Not in spec — bulger displacement is kinematic | First-class via `wall_response_rate` lag |
| Decoupled squeeze ↔ propulsion | Coupled via `peristalsis_amplitude` + `_wave_speed` | Independent: `radius_mult` (squeeze) and `axial_surface_vel` (propulsion) |
| Active intake drag without squeeze | Only via reverse `peristalsis_wave_speed` | Native via negative `axial_surface_vel` |
| Static features (haustra, valves, columns) | Per-loop bones | Modeled directly in Blender mesh + optional zone overlay |
| Through-path coupling (tentacle deforms multiple canals) | Per-loop, via separate per-canal loops | Bulger SDF queried globally per-cell, every canal sees every bulger |
| Authoring tool burden | Blender + per-loop bone placement script + skin painting per feature | Blender mesh + bone naming + Resource files |
| Hot-path C++ surface | XPBD constraint solving per loop (existing 5A pattern extended) | Texture cell update loop (cheap; could stay GDScript per CLAUDE.md C++/GDScript split) |

**Authoring cost reduction:** ~5–10× for canal interiors.
**Runtime cost reduction:** ~3–5× total per hero (orifice rim particles
unchanged; canal interior PBD work removed; texture work added is a
fraction).
**Realism:** improved on every measurable axis.

---

## Improvements folded in

Beyond the texture model itself:

1. **Hierarchical canal activation.** Inactive canals (no EI, no
   storage content, no modulation) skip integration. Most canals are
   inactive most of the time. Saves majority of runtime cost in typical
   scenes.

2. **Muscle activation field as unified primitive.** Reverie writes
   `muscle[s,θ]`; physics derives `radius_mult`,
   `axial_surface_vel`, constriction strengths. Anatomically grounded
   (real canals have circumferential and longitudinal muscle layers
   contracting independently). Replaces the ad-hoc trio of
   `peristalsis_*` channels with one spatial field.

3. **Inter-canal bulger sharing.** A tentacle spanning multiple linked
   canals deforms each canal's wall via global per-cell SDF queries —
   no per-canal filtering. Through-path deformation coupling is free.

4. **Optional second-order wall dynamics.** `wall_radial_velocity` per
   cell + `wall_acceleration_gain` + `wall_damping` give true
   ringing/overshoot per cell when desired. Default off (canals are
   heavily damped tissue; first-order lag is usually enough).

5. **Per-cell friction multiplier.** Local "sticky patches" or
   "slippery sections" via `friction_mult[s,θ]` channel. Authored
   statically (rest map) or dynamically (Reverie writes spasm/grip
   patterns).

---

## CLAUDE.md non-negotiable updates

In `extensions/tentacletech/CLAUDE.md`, add to the "in scope" / "never"
lists:

**New (in scope):**
- Canal interior model: 2D `tunnel_state` RGBA32F texture per canal,
  CPU-integrated, GPU-uploaded each tick. Indexed by
  `(arc_length_sample, angular_sector)`. Per-cell channels:
  `dynamic_wall_radius`, `plastic_offset`, optional
  `wall_radial_velocity`, `friction_mult`. Hierarchical activation
  skips integration for inactive canals.
- Constriction zones replace per-feature rim loops along canal axes.
  Zone is pure data on `CanalParameters` resource.
- Muscle activation field (`muscle[s,θ]`) is the canonical Reverie
  modulation primitive for canal interior; legacy `peristalsis_*`
  channels are sugar.

**Replace / clarify (existing):**
- "Per-rim-particle quantities use `_per_loop_k[l][k]`" — clarify that
  this applies **only to orifice rim loops**, not to canal interior
  features. Canal interior features use `_per_cell_kj[k][j]` indexing
  on the 2D `tunnel_state` texture.

**Bulger architecture clarification:**
- Vertex shader displacement path splits at vertex group boundary:
  body skin verts read bulger uniform array (§7.1); canal interior
  verts (`canal_interior` vertex group) read the canal's
  `tunnel_state` texture. Single texelFetch per canal vert; canal
  texture already incorporates bulger contributions via CPU
  integration.

---

## Knock-on effects elsewhere

| Doc | What changes |
|---|---|
| `docs/architecture/TentacleTech_Architecture.md` §6.1 | Retire "Compound openings" sub-bullet of multi-loop support paragraph. Multi-loop refers only to stacked loops at one rim, not axial sequences. |
| `docs/architecture/TentacleTech_Architecture.md` §6.7 | Rewritten per "Through-path tunnels" canonical text above. Each linked canal owns its own `tunnel_state` texture; bulger SDF queries are global per-cell. |
| `docs/architecture/TentacleTech_Architecture.md` §6.9 | "Mechanical scope" paragraph rewritten to drive `muscle[s,θ]` field rather than per-loop `target_enclosed_area`. Wedge math generalized to per-cell. |
| `docs/architecture/TentacleTech_Architecture.md` §6.10 | ContractionPulse contribution rewritten as additive contribution to `muscle[s,θ]`. Atomic struct unchanged. Pattern emitters (OrgasmPattern etc.) unchanged. |
| `docs/architecture/TentacleTech_Architecture.md` §6.12 | NEW SECTION — full canal interior texture model (canonical text above). |
| `docs/architecture/TentacleTech_Architecture.md` §7.1 | Add note: vertex shader path splits at `canal_interior` vertex group; canal interior verts sample `tunnel_state` texture, not bulger array. |
| `docs/architecture/TentacleTech_Architecture.md` §7.2 | Add note: canals' per-tick CPU integration consumes bulger array as SDF source globally; no canal-ownership filtering. |
| `docs/architecture/TentacleTech_Architecture.md` §8.2 | Add `set_muscle_activation`, `apply_muscle_pattern`, `axial_surface_vel_gain`, `set_constriction_zone_strength` to `OrificeModulation`. Note legacy `peristalsis_*` are sugar. |
| `docs/architecture/TentacleTech_Architecture.md` §10.4 | Add steps 9–11 (model canal interiors, mark `canal_interior` vertex group, place `<Canal>_CP_*` bones). State explicitly "no JSON sidecar." |
| `docs/architecture/TentacleTech_Architecture.md` §10.6 | Add AutoBaker steps 6–8 (derive canal spline from CP bones, compute per-cell rest radius via raycasts, allocate `tunnel_state` texture). |
| `extensions/tentacletech/CLAUDE.md` | Add canal interior model + constriction zones + muscle field to in-scope. Clarify `_per_loop_k` indexing applies to rim only; introduce `_per_cell_kj` for canal interior. |
| `docs/architecture/Reverie_Planning.md` §3.5 / §6.5 | Update peristalsis modulation references — Reverie writes `muscle[s,θ]` patterns rather than `peristalsis_amplitude` triplet. Existing reaction profiles continue to work (sugar layer); new profiles get spatial control. |
| `docs/Description.md` / `docs/Gameplay_Mechanics.md` | "Ring bone pulsing" → "rim pulsing at orifices, canal wall undulation in interiors." Mention plastic memory and air pockets as discoverable phenomena where appropriate. |
| `docs/Cosmic_Bliss_Update_2026-05-03_orifice_rim_model.md` | Status header gains a forward-pointer: "compound openings sub-bullet superseded 2026-05-04 by `Cosmic_Bliss_Update_2026-05-04_canal_interior_model.md`." |
| `docs/marionette/Marionette_plan.md` | No change — Marionette is rim-physics-agnostic at the canal interior layer. Body bone skinning of canal interiors uses the existing rig. |
| `docs/pbd_research/findings_obi_synthesis.md` | Add: per-cell texture integration for canal interior is not Obi-derived; Obi handles rim-particle XPBD only. |

---

## Phase impact

**Currently in flight:** Phase 5 (Orifice). 5A + 5B + 5C-A + 5C-B done.
Pending: 5C-C (friction + reaction-on-host-bone), 5D (realism polish).
None of these are affected by this amendment — they operate on the rim
particle loop primitive, which stays.

**New / re-scoped slices** (deferred Phase 5 work, after 5D):

- **5E — Canal infrastructure.** `Canal : Node3D` registration,
  `CanalParameters` Resource, AutoBaker spline derivation from
  `<Canal>_CP_*` bones, per-cell rest_radius computation, texture
  allocation. Mostly GDScript per CLAUDE.md split (no hot-path C++).
  Test scene: a single canal with a static rest pose and gizmo overlay
  showing texture cells.

- **5F — Canal texture dynamics.** Per-tick CPU integration loop
  (`dynamic_wall_radius`, `plastic_offset`, `friction_mult`),
  bulger SDF query per cell, texture upload, vertex shader sampling
  for canal interior verts. Hierarchical activation gating. GDScript
  with potential C++ promotion if profiling demands it.

- **5G — Muscle activation field + constriction zones.** Reverie
  modulation API (`set_muscle_activation`, zone strength setters),
  derivation of `radius_mult`, `axial_surface_vel`, friction
  multiplier from muscle field. Backward-compat sugar for legacy
  `peristalsis_*` channels.

- **§6.7 through-path linking** (existing planned slice) implements
  per-canal texture coupling via global bulger SDF.

- **§6.8 storage chain, §6.9 oviposition, §6.10 ContractionPulse,
  §6.11 RhythmSyncedProbe** — all consume the new texture model;
  largely unaffected at the API level.

---

## Apply checklist for top-level Claude

1. ✅ This doc written (`docs/Cosmic_Bliss_Update_2026-05-04_canal_interior_model.md`).
2. **Apply edits to `TentacleTech_Architecture.md`** §6.1, §6.7, §6.9,
   §6.10, §7.1, §7.2, §8.2, §10.4, §10.6 per the canonical text in this
   doc. Add new §6.12 (Canal interior texture model). Add
   `CanalParameters` Resource definition near the existing
   `OrificeProfile` definition in §10. Update §1 architecture diagram
   to show canal-interior texture as a distinct subsystem.
3. **Apply edits to `extensions/tentacletech/CLAUDE.md`** —
   in-scope additions, indexing-convention clarifications, vertex
   shader path split note.
4. **Apply edits to `docs/architecture/Reverie_Planning.md`** —
   peristalsis modulation references updated; `muscle[s,θ]` becomes
   the canonical primitive. Sugar layer preserved.
5. **Apply edits to `docs/Description.md` + `docs/Gameplay_Mechanics.md`** —
   canal interior phenomenology language updated.
6. **Apply edit to `docs/Cosmic_Bliss_Update_2026-05-03_orifice_rim_model.md`** —
   add forward-pointer note in status header.
7. **Phase planning update in `extensions/tentacletech/CLAUDE.md`** —
   add 5E / 5F / 5G slice entries with clear scope. 5C-C and 5D remain
   ahead of them in the queue.
