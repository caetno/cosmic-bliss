# Cosmic Bliss — Design Update 2026-05-03 — Orifice rim model amendment

> **Status: applied 2026-05-03.** Replaces the driven 8-direction ring-
> bone orifice model in `docs/architecture/TentacleTech_Architecture.md`
> §6.1–§6.4 with a rim-particle-loop model. Architecture doc edited to
> match; this doc remains as changelog. Lineage: proposed in
> `Cosmic_Bliss_Update_2026-05-03_obi_realism_and_orifice.md` §2 after
> reading Obi 7.x's `VolumeConstraints.compute` and
> `PinholeConstraints.compute` (synthesis at
> `docs/pbd_research/findings_obi_synthesis.md`). User approved
> 2026-05-03 with multi-loop support added.

**Audience: top-level Claude (canonical record). Sub-Claude reads the
architecture doc, not this one.**

---

## TL;DR

The previous spec drove a discrete number of "ring bones" kinematically
each tick — bones positioned by `set_radius_per_dir[d]`, with a spring-
damper on the *target radius* (not on the bone-to-bone forces). The
spec already said "ring count is variable, do not hard-code 8" but in
practice the per-direction `_per_dir[d]` contract leaked into every
data structure and was elevated to a CLAUDE.md non-negotiable. The
result was a model that handled circles and ellipses well, asymmetric
anatomy with effort, and slits / irregular jewelry / non-elliptical
rest shapes badly.

The new model treats the rim as a **closed loop of N PBD particles**
(N typically 8-16 per loop, configurable per orifice) governed by:

1. **XPBD distance constraints** around the loop (chord segments,
   per-pair authored rest length). Sum of rest lengths = rim
   circumference.
2. **XPBD volume constraint** on the polygon area enclosed by the
   loop, projected onto the plane perpendicular to the orifice entry
   axis. Adopted from `pbd_research/Obi/Resources/Compute/
   VolumeConstraints.compute`. Active contraction modulates the
   target area.
3. **Per-particle spring-back to authored rest position** in the
   orifice frame. Bilateral compliance becomes the per-particle
   stiffness distribution (front vs back, dorsal vs ventral, etc.).
4. **Soft attachment to host bone** via the orifice frame. The frame
   inherits `host_bone.global_transform`; rim particle rest positions
   live in this frame; the spring-back pulls particles along when the
   bone moves. This replaces the §6.1 driven-bone-via-Center-parent
   plumbing for the dynamics layer (the *visual rig* — mesh skin
   weights to rim anchors — stays as authored).

**Multi-loop per orifice:** an orifice owns a *list* of rim loops,
not exactly one. Each loop has its own particle count, rest
positions, distance/volume/spring constraints, and (optionally)
inter-loop coupling springs. Anatomical examples — outer lips +
inner mouth opening, vulva + introitus, anus pucker + inner sphincter,
decorative jewelry rim + inner anatomical opening. See "Multi-loop
support" below.

**The rim *anchor* bones** authored in Blender stay as they were —
they're the parents of rim particle rest positions in the host's
skeleton, and they're what skin weights point at. What changes is
that the particles are now PBD-driven *with* the rim anchors as
rest-pose targets, instead of the rim anchors being directly
kinematic.

---

## What changes (canonical text — applied to architecture doc)

### §6.1 — Rim structure (was: "Ring bone structure")

The rim is an edge loop of the continuous hero mesh at the point
where the surface invaginates, authored in Blender. **Rim anchor
bones** (renamed from "ring bones") are placed along this loop and
ship with the hero GLB. Skin weights on the rim loop follow the
anchors so anchor motion deforms skin and mucosa together.

```
<host_deform_bone>                        (parent — pelvis/hip/jaw etc.)
└── <Prefix>_Center                       (transform anchor; non-deforming; no weights)
    ├── <Prefix>_RimAnchor_0              (deform bones; arc-length-regular along rim;
    ├── <Prefix>_RimAnchor_1               authored rest positions for the rim particles)
    ...
    └── <Prefix>_RimAnchor_{N-1}
```

**Orifice rim count is variable per loop.** N is per-loop, set by
the `OrificeProfile.rim_loops[i].particle_count`. Typical defaults:
8 for symmetrical openings, 12-16 for irregular shapes (slits, star
profiles), 4-6 for tight openings (urethra, decorative pinholes).
Logic must be N-agnostic.

**Placement is arc-length-regular along the rim loop.** Each anchor's
authored offset from `<Prefix>_Center` is its rim particle's rest
position in Center frame. The Blender authoring script enforces
arc-length spacing; physics never assumes angular regularity.

**Local frame**, consistent across every rim anchor on every orifice
(set by the Blender authoring script):
- **Y** — radial outward (from Center toward the rim).
- **Z** — along the opening axis (outward from the cavity).
- **X** — tangent along the rim loop.

**Rim anchors are kinematic targets, not driven outputs.** Runtime
does not write to anchor positions. The orifice's rim particles
(per §6.2) are PBD-driven with anchors as XPBD spring rest positions.
The visible mesh skin tracks rim particles via a per-tick uniform
upload (mesh skin weights remain bound to anchor names; skinning
shader uses live rim particle positions in place of anchor world
transforms — see §10.4 update for the binding mechanism).

Skin around the opening is weight-painted in Blender to rim anchors
with angular interpolation between bracketing anchors and radial
falloff outward. See §10.4 for the Godot-side import workflow and
§10.6 for the full Blender → Godot authoring pipeline.

**Multi-loop support.** An orifice can own multiple rim loops, each a
fully independent particle loop with its own constraints. Loop 0 is
the canonical "primary rim" used by EntryInteraction geometry checks
(entry plane, tunnel projection); additional loops are visual /
secondary contact surfaces. Common configurations:

- **Single loop** (default): one rim loop, simple orifice.
- **Outer + inner loop** (anatomical): an outer "lip" loop with low
  stiffness and a larger rest radius, an inner "opening" loop with
  higher stiffness and the actual passage radius. Inter-loop
  coupling springs (per-particle pairs, soft) make them deform
  somewhat together while preserving differential stiffness.
- **Decorated rim** (jewelry, prosthetic): inner loop is the
  anatomical opening; outer loop is jewelry geometry with very high
  stiffness (rim deforms freely, jewelry barely moves).
- **Compound openings** (ribbed canal, multiple sphincters along a
  single tunnel): a sequence of loops along the tunnel axis, each
  with its own rest radius and contraction modulation. Used for
  peristalsis (§6.7 through-path tunnels) — each loop is one
  contractile ring along the tunnel.

Inter-loop coupling, when present, is a per-particle XPBD soft pull
between corresponding particles in adjacent loops. Stiffness is
authored per-pair; zero coupling means loops are visually adjacent
but mechanically independent.

### §6.2 — EntryInteraction (was: "EntryInteraction and persistent state")

Struct fields change as follows. Per-direction quantities indexed by
ring direction `[d]` become per-rim-particle quantities indexed by
particle index `[k]` and (for multi-loop) loop index `[l]`. The shape
of the data follows the actual rim particle count, which varies per
loop.

```cpp
struct RimLoopState {
    int                    particle_count;                       // = N for this loop
    Vector<RimParticle>    rim_particles;                        // size N
    Vector<float>          rim_segment_rest_lengths;             // size N (closed loop)
    float                  target_enclosed_area;                 // volume constraint target
    Vector<float>          rim_particle_rest_stiffness_per_k;    // bilateral compliance
};

struct RimParticle {
    Vector3 position;
    Vector3 prev_position;
    float   inv_mass;
    Vector3 rest_position_in_center_frame;  // authored from Blender anchor
    float   distance_lambda_to_next;        // XPBD lambda (per closed-loop segment)
    float   spring_lambda;                  // XPBD lambda (per spring-back constraint)
};

struct EntryInteraction {
    Tentacle*   tentacle;
    Orifice*    orifice;

    // Geometric (recomputed each tick) — unchanged
    float       arc_length_at_entry;
    Vector3     entry_point;
    Vector3     entry_axis;
    Vector3     center_offset_in_orifice;
    float       approach_angle_cos;
    float       tentacle_girth_here;
    Vector2     tentacle_asymmetry_here;
    float       penetration_depth;
    float       axial_velocity;

    // Per-rim-particle state. Indexed [loop_index][particle_index].
    // Sized to orifice.rim_loops[l].particle_count per loop.
    Vector<Vector<float>> orifice_radius_per_loop_k;       // current radius at particle k
    Vector<Vector<float>> orifice_radius_velocity_per_loop_k;

    // Persistent (hysteretic)
    float                 grip_engagement;
    bool                  in_stick_phase;
    Vector<Vector<float>> damage_accumulated_per_loop_k;

    // Forces this tick — per particle, summed across loops where applicable
    Vector<Vector<float>> radial_pressure_per_loop_k;
    float                 axial_friction_force;
    Vector3               reaction_on_ragdoll;

    float                 ejection_velocity = 0.0;
    float                 ejection_decay    = 12.0;
    PackedInt32Array      particles_in_tunnel;

    // Tangential friction at the rim, per-rim-particle per-loop.
    // Populated by §4.3 type-2 friction projection; consumed by §6.3.
    // NOTE: was `tangential_friction_per_dir[8]` in the pre-2026-05-03
    // model. Index is now (loop_index, rim_particle_k). Cleared per tick.
    Vector<Vector<float>> tangential_friction_per_loop_k;
};
```

Lifecycle is unchanged. The aggregate operations that previously ran
"for each ring direction d in [0..N-1]" now run "for each loop l, for
each rim particle k in [0..N_l-1]" — a flat `(l, k)` pair iteration.

### §6.3 — Bilateral compliance (was: "Bilateral compliance via 8-direction rings")

Pseudocode rewritten to iterate over rim particles. Volume constraint
on the enclosed area replaces the per-direction radial spring as the
bulk anatomical-tissue-resists-displacement mechanism; per-particle
spring-back handles local deformation; distance-around-the-loop
handles rim circumference preservation.

```
for each loop l in orifice.rim_loops:
    rim = l.rim_particles
    N = rim.length

    // Per-particle pressure from tentacle-rim contact. Computed by
    // type-2 collision projection during PBD iterations (§4.2);
    // EntryInteraction reads the result.
    for each rim particle k:
        // Projection-based: type-2 collision projects rim particle k
        // out of any tentacle particle within collision radius. The
        // projection magnitude × inv_mass^-1 / dt² → "pressure" at k.
        // Friction tangent direction handled by §4.3 type-2 routing.
        pressure_per_loop_k[l][k] = max(0, type_2_projection_lambda[l][k])

    // Volume constraint (Obi VolumeConstraints pattern). The enclosed
    // polygon area is pulled toward target_enclosed_area each iteration.
    // Active contraction modulates the target.
    current_area = polygon_area_of_loop(rim, projected_to_perp_plane)
    area_constraint = current_area - l.target_enclosed_area
    apply_xpbd_volume_constraint(rim, area_constraint, l.area_compliance, dt)

    // Distance constraints around the loop (closed). Standard XPBD
    // distance per pair (rim[k], rim[(k+1) % N]).
    for each pair (k, k+1) cyclic:
        apply_xpbd_distance_constraint(rim[k], rim[(k+1) % N],
            l.rim_segment_rest_lengths[k], l.distance_compliance, dt)

    // Per-particle spring-back to authored rest position in Center frame.
    // Bilateral compliance is the per-particle stiffness distribution.
    for each rim particle k:
        rest_world = orifice.Center.global_transform * rim.rest_position_in_center_frame
        compliance = stiffness_to_compliance(l.rim_particle_rest_stiffness_per_k[k])
        apply_xpbd_spring_constraint(rim[k], rest_world, compliance, dt)

    // Inter-loop coupling (if any). Per-particle XPBD soft pull
    // between rim[l][k] and rim[l+1][k] (or whatever pairing is
    // authored in the loop's `coupling_pairs` table).
    for each (k1, k2, compliance) in l.coupling_to_outer_loop:
        apply_xpbd_distance_constraint(rim[k1], outer_loop.rim[k2],
            authored_rest, compliance, dt)
```

Bilateral compliance is now an emergent property: per-particle
stiffness × volume constraint compliance × distance constraint
compliance together determine how each rim particle responds to
load. The two-line "if rigid tentacle then orifice deforms a lot" /
"if soft tentacle then it flattens" intuition still holds, but the
math is now per-particle XPBD springs instead of per-direction
spring-damper allocation.

**Reaction force on the orifice's host bone.** Each rim particle's
type-2 collision projection produces a position correction; the
equal-and-opposite reaction goes on the host bone via the same
impulse path as before (§4.3 type-2 routing). The wedge math (axial
component from `drds_outward`) is unchanged — it's per-particle now,
applied at each rim particle's contact point in turn.

```
for each loop l, for each rim particle k:
    if pressure_per_loop_k[l][k] == 0: continue

    p              = pressure_per_loop_k[l][k]
    contact_pos    = rim[k].position
    s_intrinsic    = EI.arc_length_at_entry + r_offset_along_axis_at_k
    dir_outward    = normalize(rim[k].position - orifice.Center.position).xy
                     // projected to perp plane

    radial_force_on_host = -dir_outward * p

    drds_intrinsic = signed_girth_gradient_at_arc_length(EI.tentacle, s_intrinsic)
    t_hat          = evaluate_tentacle_tangent(EI.tentacle, s_intrinsic)
    drds_outward   = drds_intrinsic * sign(dot(t_hat, orifice.entry_axis))
    norm           = sqrt(1.0 + drds_outward * drds_outward)
    axial_hold     = -p * drds_outward / norm
    axial_force_on_host = orifice.entry_axis * axial_hold

    friction_force_on_host = -t_hat * EI.tangential_friction_per_loop_k[l][k]

    total = radial_force_on_host + axial_force_on_host + friction_force_on_host
    host_bone.apply_impulse_at_position(total * dt, contact_pos)
    EI.reaction_on_ragdoll += total
```

Same wedge math (`-p * drds_outward / sqrt(1 + drds_outward²)`),
applied per-rim-particle instead of per-direction. The numerical
stability properties (bounded by `p` at near-vertical flanges) carry
over.

### §6.4 — Rim particle dynamics (was: "Spring-damper ring dynamics")

Replaced by §6.3's XPBD constraint set. There is no longer a separate
"spring-damper on target radius" — radial extent emerges from the
balance of distance constraint + volume constraint + per-particle
spring-back + type-2 collision projection. The "underdamped ring
oscillates after each impulse" behavior cited in scenarios (§6.4 of
the old spec, scenario references in `TentacleTech_Scenarios.md`) is
now a function of XPBD compliance values + the global solver damping
factor. Tuning is per-loop instead of per-orifice; soft `spring_back`
+ low `distance_compliance` produces a snappy rim, the inverse
produces a sluggish one.

### §6.5 onward — Mostly unchanged

§6.5 (multi-tentacle) — the "max 3 tentacles" cap stays. Multi-
tentacle aggregation uses `compute_aggregate_demand(rim particle k)`
in place of the per-direction version: max over all tentacles of the
required radial position at that particle.

§6.6 (jaw) — unchanged. The jaw's hinge dynamics sit above the rim
loop; rim loop handles lip deformation as a soft-physics layer
beneath the jaw hinge.

§6.7 (through-path tunnels) — peristalsis becomes "modulate per-loop
target area along the tunnel", not "modulate target_radius_per_dir".
Each contractile ring is one rim loop in the tunnel; peristalsis is
a wave of `target_enclosed_area` modulation across loops in sequence.

§6.8 / §6.9 (storage chain, oviposition, birthing) — unchanged at
the conceptual level; the rim-loop change is invisible to these
systems (they consume `EI.penetration_depth`, axial geometry, etc.).

§6.10 (transient pulse primitives, ContractionPulse) — pulses
modulate `target_enclosed_area` and per-particle rest-position
displacement. The atomic ContractionPulse interface stays;
implementation routes to the new model.

§6.11 (RhythmSyncedProbe) — unchanged. Rhythm clock drives the same
modulation channels that bilateral compliance writes (now per-loop
target area + per-particle rest-position deltas).

---

## CLAUDE.md non-negotiable updates

Replace these lines in `extensions/tentacletech/CLAUDE.md`:

**Old:**
- Orifice system: 8-direction ring bones with spring-damper, EntryInteraction with persistent hysteretic state, bilateral compliance, multi-tentacle support (cap 3)
- Per-direction quantities use `_per_dir[d]` (canonical, established in §6.2). The `_per_ring[r]` aliases used in earlier drafts are retired; do not reintroduce them.
- Type-2 friction reciprocals do NOT route per-particle to a ragdoll bone. They sum into `EI.tangential_friction_per_dir[d]` (§6.2) and the §6.3 reaction-on-host-bone pass routes them to `host_bone`. Type-1 routing rule (§4.3) does not apply to type-2 contacts.

**New:**
- Orifice system: closed-loop rim of N PBD particles per loop (multi-loop per orifice supported — outer/inner/jewelry/multi-sphincter), XPBD distance constraints around the loop, XPBD volume constraint on enclosed area, per-particle spring-back to authored rest position. Bilateral compliance is per-particle stiffness distribution. Multi-tentacle support (cap 3). See `docs/Cosmic_Bliss_Update_2026-05-03_orifice_rim_model.md` for the model rationale.
- Per-rim-particle quantities use `_per_loop_k[l][k]` where `l` is loop index and `k` is rim particle index. The `_per_dir[d]` and `_per_ring[r]` indexing schemes from earlier drafts are retired; do not reintroduce them.
- Type-2 friction reciprocals do NOT route per-particle to a ragdoll bone. They sum into `EI.tangential_friction_per_loop_k[l][k]` (§6.2) and the §6.3 reaction-on-host-bone pass routes them to `host_bone` per rim particle. Type-1 routing rule (§4.3) does not apply to type-2 contacts.

---

## Knock-on effects elsewhere

| Doc | What changes |
|---|---|
| `docs/Description.md` | "8 radial bones per opening" → "deformable rim particle loop per opening, multi-loop supported" |
| `docs/Gameplay_Mechanics.md` | "ring bone pulsing" → "rim pulsing" (or "rim particle pulsing" — pick the more readable phrasing per context) |
| `docs/architecture/TentacleTech_Scenarios.md` | "ring bones" → "rim particles" / "rim" in narrative scenarios. "ring bones snap back" → "rim snaps back" |
| `docs/architecture/Reverie_Planning.md` | `RingOverstretched` event keeps its name (event names are stable identifiers; renaming would force consumer updates), but the prose around it shifts to "rim overstretched" |
| `docs/marionette/Marionette_plan.md` | "Blender script that authors orifice ring bones" → "Blender script that authors orifice rim anchors" |
| `docs/pbd_research/findings_obi_synthesis.md` | "Action: when Phase 5 opens, re-read PinholeConstraints.compute and draft the orifice as a single PinholeConstraint-like type rather than the originally-planned 8-direction-ring-bone structure" → flip from forward-looking to "this landed; see `Cosmic_Bliss_Update_2026-05-03_orifice_rim_model.md`" |
| `docs/Cosmic_Bliss_Update_2026-05-03_obi_realism_and_orifice.md` | Status flip: §2 approved and applied (this doc); §3 (slime) and §4 (realism gaps) still pending review |

---

## Apply checklist for top-level Claude

1. ✅ This doc written.
2. **Apply edits to `TentacleTech_Architecture.md`** §6.1, §6.2, §6.3, §6.4 — rewrite per the canonical text above. Update §1 architecture diagram. Update §3.4 asymmetry pseudocode. Update §4.2 / §4.3 type-2 references. Update §10.4 / §10.6 to reflect rim anchors instead of ring bones. Update §14 — remove the "8 discrete radial bones" gotcha (resolved by this amendment). Update §15.2 — snapshot accessor signatures (per-loop, per-rim-particle).
3. **Apply edits to `extensions/tentacletech/CLAUDE.md`** — replace the three non-negotiable lines per "CLAUDE.md non-negotiable updates" above. Update the in-scope bullet.
4. **Apply edits to `docs/Description.md` + `docs/Gameplay_Mechanics.md` + scenarios + Reverie_Planning + Marionette_plan + findings_obi_synthesis + obi_realism_and_orifice** per the "Knock-on effects" table.
5. **Phase 5 plan re-derives from the new model.** When Phase 5 opens, sub-Claude reads the amended §6 directly; no need to consult this update doc except for the rationale.

Phase 4 close-out cluster (in flight) is unaffected — the rim model lives at the orifice layer; the Phase 4 wedge robustness work is at the tentacle-vs-environment-collider layer.
