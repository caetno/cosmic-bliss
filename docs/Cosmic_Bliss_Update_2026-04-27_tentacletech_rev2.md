# Cosmic Bliss — Design Update 2026-04-27 — Tentacle/orifice physical chain (REV 2.1)

**Audience: Repo organizer Claude (Claude Code session).**

This brief supersedes `Cosmic_Bliss_Update_2026-04-27_tentacletech.md`. **Do not apply that doc.** Apply this one.

### Post-pushback corrections (REV 2 → REV 2.1)

After the REV 2 patch was reviewed by the implementer, four bugs were caught in §6.3 that REV 2 had quietly inherited or introduced. REV 2.1 fixes them:

- **§6.3 axial wedge — normalized form.** The `axial_hold = -p × dr/ds` form REV 2 used is fine for shallow slopes but goes unbounded at near-vertical flanges (a knot's leading face), exactly the geometry that matters most. Replaced with the normalized form `axial_hold = -p × drds / sqrt(1 + drds²)`, which is `-p × sin(θ)` and is bounded by `p` at the limit.
- **§6.3 `dr/ds` definition disambiguated.** REV 2 left the gradient direction implicit. Now explicit: `drds_outward` — gradient with respect to distance traveled along the orifice's `+entry_axis` (outward) at the contact, derived from the tentacle's intrinsic `dr/ds` by `drds_outward = drds_intrinsic × sign(dot(t_hat, entry_axis))`. Cleans up suspension geometry where the tentacle's intrinsic `+s` direction points opposite to `+entry_axis`.
- **§6.3 sign-direction prose corrected.** REV 2's explanatory comments described axial-force directions inverted from what the formula actually computes. Fixed: `drds_outward > 0` (knot apex on the cavity-exterior side of the rim contact) → axial force INTO CAVITY (engulfment-assist); `drds_outward < 0` (knot apex on the cavity-interior side) → axial force TOWARD EXIT (suspension-holding direction). Worked numerically against the canonical "hero hangs from a knot" geometry.
- **§6.3 third-law return path made case-specific.** REV 2 said "force returns via type-2 collision projection." That's true for the knot case but not the smooth-shaft case, where `drds_outward ≈ 0`, the wedge term vanishes, and the only axial path is friction. Both cases now spelled out explicitly.
- **`tangential_friction_per_dir[8]` declared in §6.2.** REV 2's §6.3 pseudocode referenced this field; it didn't exist. Added to the `EntryInteraction` struct, with population logic specified.
- **§4.3 type-2 friction reciprocal routing.** §4.3 (canonical) routes type-1 friction reciprocals to ragdoll bones. REV 2's §6.3 implicitly assumed type-2 reciprocals went to `host_bone` instead, but §4.3 didn't say so. Added an explicit type-2 routing rule to §4.3 that populates `EI.tangential_friction_per_dir[d]` and lets §6.3 do the host-bone application.
- **`apply_force_at_position` → `apply_impulse_at_position(total * dt, …)`** for consistency with §4.3's type-1 path. Same physics, same units; one form across the whole doc.
- **Tests:** added wedge-sign sanity (axial reaction must flip sign when a knot translates through the rim) and steep-flange numerical stability (a near-vertical leading face must produce finite, bounded force). Tightened the existing knot-suspension and smooth-shaft tests with explicit geometry and friction-only-hold reasoning.

### Changes from the prior `Cosmic_Bliss_Update_2026-04-27_tentacletech.md`:

- **§6.3 reaction-on-host-bone:** axial wedge formula corrected (`tan(local_taper)` → signed `dr/ds`); third-law return path stated honestly (type-2 collision projection, not the asymmetry write); terminology aligned to canonical `_per_dir[d]`.
- **§6.10 transient pulses:** `DrawInPulse` removed as a separate primitive (it is just a `ContractionPulse` with negative speed). `pulse_envelope` specified as a `Curve` resource with a documented default. Pulse repetition is now sugar at the emitter level — patterns queue lists of *atomic* `ContractionPulse`s; the per-tick code never sees `count` or `interval`.
- **§6.10 bitfield:** `BOTH` removed. `applies_to` is `TENTACLES = 1, BEADS = 2`.
- **§8.1 events:** lifecycle events (`OrgasmStart`/`End`, etc.) plus a single generic `ContractionPulseFired` carrying `pattern_id`, replacing per-pulse pattern-named events. Avoids enum bloat.
- **§6.5 refusal:** `accept_penetration` and `min_approach_angle_cos` dropped. Both were scripted-outcome levers in a system whose identity is physics-emergent. If soft physics can't refuse, the fix is the soft physics, not a hard reject.
- **§1 design principles:** added discipline rule against scripted-outcome levers, so the next time someone reaches for one we have a doc-anchored reason not to.
- **§10.2 split:** PrimitiveMesh subclass (UX fix) and modifier-model refactor (architectural change) are separate concerns, now separate subsections (§10.2a / §10.2b). Single concern per change.
- **§10.2b modifier model:** sections deferred to v2. v1 ships single flat `modifiers` list with per-modifier `t_start` / `t_end` / `feather`. Kernels + repeat + falloff land as planned.
- **§12 leaders+chorus:** Tenticles does not subscribe to `StimulusBus`. User-level GDScript glue reads the bus and writes Tenticles' public params. Tenticles stays self-contained per its existing scope boundary.
- **§3.3:** committed to chord-only `(i, i+2)` bending form (the existing canonical text was ambiguous). The non-uniform `bend_scale` correction sits on top of that committed form.
- **§3.6 iteration count:** non-uniform chains with > 2× length disparity want 5–6 iterations, not 4. Noted.
- **§4.3 contact stiffness ↔ iteration count:** these compound multiplicatively per tick; tune together.
- **§5.3 UV remap:** dependency on `rest_position.z == rest_arc_length` stated, so future curved-rest-pose authoring doesn't break it silently.
- **§13 jiggle:** rotational SPD deferred to v2; modeling-time skin-weight gotcha stated.
- **§14:** new gotcha — suspension requires a girth differential, not just compression.

Four-extension architecture unchanged. Numeric values are starting points.

---

## Project conventions you must honor

- **GDScript by default.** C++ (GDExtension) only for math-heavy inner loops, physics-tick work, low-level RenderingDevice. Compile/edit cost is real.
- **Godot 4.6** specifically. godot-cpp pinned to 4.6 branch.
- Never propose: per-frame `ArrayMesh` rebuilds, per-frame `ShaderMaterial` allocation, `MultiMesh` for deforming meshes, `SoftBody3D` for any core system, SSBOs in spatial shaders (use `RGBA32F` data textures).
- **Don't generate Godot test scenes.** Caetano creates those himself. Reference scenarios in milestones if needed.
- **No padding.** Match the declarative voice of the canonical docs.
- **Numbers are starting points.** Particle counts, ring counts, pulse magnitudes, periods, default thresholds — flag tunables as such.
- **Don't renumber existing phases.** Insert sub-phases (P5.x, P9.x) where ordering matters.
- **One concern per change.** If a decision touches three docs, write three localized patches.

Canonical docs (at repo root):

- `TentacleTech_Architecture.md`
- `TentacleTech_Scenarios.md`
- `Marionette_plan.md`
- `Reverie_Planning.md`
- `Tenticles_design.md`

---

## Summary of decisions

1. **Force chain closes at the rim.** §6.3 gains an explicit reaction-on-host-bone step, with corrected axial-wedge math and an honest accounting of which side of the third-law pair flows automatically.
2. **Active expulsion and suction become first-class.** New `ContractionPulse` primitive layers atop the existing peristalsis math (§6.9). Patterns are sugar-emitters that queue atomic pulses. Optional per-orifice `appetite` for autonomous "hungry rim."
3. **Reflex events are pattern-lifecycle + a generic per-pulse event,** not pattern-named per pulse. Avoids enum bloat.
4. **Targeted per-tentacle ejection.** `EntryInteraction.ejection_velocity` for one-shot kicks on a specific tentacle without disturbing others sharing the orifice.
5. **Refusal layered, soft-only.** Damage degrades grip via `smoothstep`; knot-aware grip ramp accelerates engagement when a girth differential straddles the rim. No hard refusal lever.
6. **Non-uniform particle distribution.** Tip-clustered chains; mass by segment volume; bend correction scaled by chord length; centripetal CR; arc-length UV in shader.
7. **Soft contact distance stiffness.** Per-pair distance stiffness drops in segments currently in collision contact.
8. **Shader-side UV remap from spline arc-length.** Decouples authored textures from per-segment-length variation.
9. **TentacleMesh as `PrimitiveMesh` subclass.** UX fix for slider-snap-back. Bake-to-static `.tres ArrayMesh` shipping path unchanged.
10. **Modifier model: kernel + repeat + falloff, single-section v1.** Three primitive kernels (`Ring`, `Vertex`, `Mask`) replace the flat features array. Per-modifier `t_start`/`t_end`/`feather` directly on `TentacleModifier`. Sections deferred to v2.
11. **Mass-wrap = "leaders + chorus."** TentacleTech leaders grab; Tenticles tubes form visual chorus reacting to hero SDF. Tenticles remains self-contained — bus coupling routes through user-level glue.
12. **Lightweight wrapping-grade tentacle profile.** Stripped constraint set + lower iteration count + smaller tessellation.
13. **Marionette jiggle bone clusters for non-rim soft tissue.** Closes autonomous-dynamics gap on gluteus / breast / belly.

---

## Changes to existing files

### `TentacleTech_Architecture.md`

#### §1 — Add discipline rule

Append to the design-principles table:

> | **Soft physics over scripted levers** | If a behavior can't be expressed via stiffness, friction, grip, damage thresholds, or modulation channels, the fix is the physics — not a boolean reject or an angle gate. Stopgap levers, when they must exist, are flagged as such and retire when the underlying geometry / stiffness model catches up. Boolean rejects in particular get used everywhere a designer doesn't want to tune the physics; do not introduce them. |

#### §3.1 — Per-particle mass initialization

Add to the description of `TentacleParticle`:

> **Mass initialization.** Per-particle mass is set proportional to the local segment volume:
>
> ```
> particle.mass = density × radius_at_arc_length² × local_segment_length
> particle.inv_mass = 1.0 / particle.mass
> ```
>
> A constant-mass chain produces a uniformly heavy tip that resists whipping; mass-by-volume gives the natural "thin tip whips, thick base anchors" feel for free. Pinned particles (`inv_mass = 0`) are unchanged.

#### §3.3 — Commit to chord-only bending; add scaling for non-uniform spacing

Replace the bending row's "Form" column to commit to the chord form, then append:

> **Form (committed).** The bending constraint operates on the (i, i+2) chord — i.e., projects the displacement of `p[i+1]` away from the line `p[i]→p[i+2]` toward zero, weighted by stiffness. This is the canonical PBD bending form; do not substitute angle-based variants.
>
> **Angular-stiffness invariance under non-uniform `rest_lengths`.** When the chain has non-uniform per-pair `rest_length[i]`, the bending correction must be scaled to keep *angular* stiffness consistent across the chain. Multiply the correction by:
>
> ```
> bend_scale = 1.0 / (rest_length[i] + rest_length[i+1])
> ```
>
> Without this, tip-clustered chains (short segments) become disproportionately stiff in bending compared to base segments.

#### §3.6 (new) — Non-uniform particle distribution

Insert after §3.5:

> ### 3.6 Non-uniform particle distribution
>
> A tentacle chain may distribute its particles non-uniformly along arc-length to concentrate resolution where it's needed (typically the tip, for fine wrap fidelity). The underlying solver already accepts per-pair `rest_length`; only initialization plumbing changes.
>
> **Init API on `Tentacle` / `PBDSolver`:**
>
> ```cpp
> void initialize_chain_with_lengths(const PackedFloat32Array& rest_lengths);
> // length = N - 1; sum sets total chain length.
>
> void set_distribution_curve(const Ref<Curve>& curve);
> // Convenience: derives rest_lengths from a [0..1] curve mapping
> // axial_t to local segment density. Curve area is normalized to total length.
> ```
>
> **Coupled changes when distribution is non-uniform:**
>
> 1. Mass-by-volume per §3.1 (otherwise short segments become low-mass islands).
> 2. Bending correction scaled per §3.3.
> 3. Spline parameterization switches to centripetal Catmull-Rom (§5.1) — uniform CR overshoots near dense knot regions.
> 4. Texture coordinates derived from arc-length in the shader (§5.3) so authored UVs do not stretch under varying segment length.
>
> **Iteration count.** PBD distance-constraint convergence degrades with length disparity. For non-uniform chains with ratio > 2× between shortest and longest segment, bump the iteration count from 4 to 5–6. Wrapping-grade chains (§12) override this with their own lower-iteration profile.
>
> Default chain remains uniform; non-uniform is opt-in per `TentacleType` profile.

#### §4.3 — Soft contact distance stiffness

Append to the friction-projection description:

> **Soft distance stiffness during contact.** Per-pair distance constraint stiffness drops from `1.0` to a tunable `contact_stiffness` (default `0.5`) for any segment whose either endpoint is in active collision contact this tick. The chain stretches *temporarily* over wrapped geometry, springing back when contact ends. Cheaper and more stable than full length-redistribution.
>
> ```
> for each distance constraint between particles a, b:
>     stiffness = (a.in_contact_this_tick || b.in_contact_this_tick)
>         ? contact_stiffness
>         : base_stiffness
>     project_distance_constraint(a, b, rest_length[i], stiffness)
> ```
>
> **Tuning interaction.** Per-iteration stiffness compounds across iterations within a single tick: effective single-tick stiffness ≈ `1 - (1 - stiffness)^iter_count`. So `contact_stiffness = 0.5` at 4 iterations gives ≈ 0.94 effective — most of the *visible* stretch comes from across-tick relaxation against collision push-back, not from a single tick's compounded projection. Tune `contact_stiffness` and `iteration_count` together; do not tune in isolation.
>
> **Length-redistribution / elastic-budget ("S-curve length storage")** is explicitly deferred. Re-evaluate only if soft stiffness alone produces visible slack.
>
> **Type-2 friction reciprocal routing (added 2026-04-27 rev 2.1).** The canonical §4.3 specifies that for type-1 (particle vs ragdoll capsule) collisions, the friction displacement is applied as an equal-and-opposite impulse on the contacted ragdoll bone. **Type-2 (particle vs orifice rim) is different.** The contact is with a kinematic ring, not a ragdoll bone — so the type-1 rule cannot be reused. Type-2 friction reciprocals are summed per ring direction onto `EI.tangential_friction_per_dir[d]` (§6.2) and routed to the orifice's `host_bone` by the §6.3 reaction-on-host-bone pass — not applied directly per-particle. This avoids double-routing and keeps the host-bone reaction self-consistent with the radial and axial-wedge components computed at the same place.
>
> ```
> // Inside §4.3 friction projection, after computing friction_applied for
> // a particle currently in type-2 contact at ring direction d:
> if contact_type == TYPE_2:
>     // Project friction_applied onto the tentacle tangent at the ring,
>     // accumulate scalar magnitude per direction. §6.3 takes it from there.
>     t_hat = evaluate_tentacle_tangent(EI.tentacle, ring.arc_length)
>     EI.tangential_friction_per_dir[d] += dot(friction_applied, t_hat) * effective_mass / dt
>     // Do NOT call bone.apply_impulse_at_position here — handled by §6.3.
> else if contact_type == TYPE_1:
>     // Existing canonical behavior: route reciprocal to ragdoll bone directly.
>     bone.apply_impulse_at_position(impulse_friction, contact_point)
> ```
>
> Cleared at the start of each PBD tick alongside other per-tick EI state.

#### §5.1 — Centripetal Catmull-Rom

Append to `CatmullSpline`:

> **Parameterization.** The spline supports α-parameterization:
>
> - `α = 0.0` — uniform (existing default; correct for evenly-spaced control points).
> - `α = 0.5` — centripetal (required when control points are non-uniformly spaced; eliminates overshoot loops near dense regions).
> - `α = 1.0` — chordal.
>
> Default to centripetal when the source chain has non-uniform `rest_lengths` (§3.6); otherwise uniform stays canonical for performance.
>
> ```cpp
> void set_parameterization(float alpha);   // 0.0 / 0.5 / 1.0
> ```

#### §5.3 — Shader-side UV remap from spline arc-length

Append to the vertex shader description:

> **Arc-length-driven V coordinate.** The vertex shader computes the vertex's current arc-length-along-the-spline from the spline data texture's distance LUT, normalizes by total current arc length, and uses the result as the V texture coordinate. The mesh's baked V is interpreted only as a *ring-index reference*, not a final UV.
>
> ```glsl
> float current_arc_length_at_vertex = arclen_lookup(vertex.rest_position.z);
> float current_total_arc_length     = arclen_total();
> vec2  uv_remapped = vec2(UV.x, current_arc_length_at_vertex / current_total_arc_length);
> ```
>
> **Dependency.** Assumes `vertex.rest_position.z == rest_arc_length` for that vertex's ring. The procedural generator and Blender pipeline (§10.1) guarantee this by construction (mesh aligned along +Z, V = arc-length). A future curved-rest-pose authoring path would silently break this assumption — revisit if added.
>
> **Decoupling.** This decouples authored / detail textures from per-segment-length variation introduced by §3.6 (non-uniform distribution) and §4.3 (soft contact stretch). Cost: one small partial sum per vertex; sub-microsecond at typical ring counts.
>
> **Fully procedural materials** (noise, distance fields, polar coordinates) drive off the same arc-length output and never need a baked UV.

#### §6.2 — EntryInteraction additions

Add to the struct:

> ```cpp
> struct EntryInteraction {
>     ...
>     // Per-tentacle one-shot ejection (added 2026-04-27).
>     // PBD prev_position kick along entry_axis; decays to zero quickly.
>     float ejection_velocity = 0.0;       // m/s, positive = expel outward
>     float ejection_decay    = 12.0;      // 1/s
>
>     // Cached "is in tunnel" classification, computed once per tick at the
>     // EI update step. Read by ejection_velocity application, peristalsis
>     // application, and any other per-tunnel-particle pass.
>     PackedInt32Array particles_in_tunnel;
>
>     // Per-direction tangential friction at the rim (added 2026-04-27 rev 2.1).
>     // Populated by §4.3 type-2 friction projection — summed per ring direction
>     // across all particles in type-2 contact at that direction this tick.
>     // Read by §6.3 reaction-on-host-bone, which routes the friction reciprocal
>     // to host_bone (NOT to a ragdoll bone — type-1 routing rule does not apply
>     // to type-2 contacts). Cleared at the start of each PBD tick.
>     float tangential_friction_per_dir[8] = {0};
>     ...
> };
> ```
>
> Per-tick application after the PBD step:
>
> ```
> if EI.ejection_velocity > 0.0:
>     for each particle index i in EI.particles_in_tunnel:
>         tentacle.particles[i].prev_position -= EI.entry_axis * EI.ejection_velocity * dt
>     EI.ejection_velocity *= (1.0 - EI.ejection_decay * dt)
> ```
>
> Used by `RefusalSpasmPattern` and `PainExpulsionPattern` emitters (§6.10) to eject one tentacle without disturbing others sharing the orifice.

#### §6.3 — Reaction-on-host-bone closure

After the existing pseudocode block ("Apply to orifice / Apply to tentacle"), append:

> **Reaction force on the orifice's host bone.** Each direction transmits its compression and friction back to the deform bone the orifice's `Center` is parented to. Without this step, a knot deforms the rim visually but does not transmit hero weight into the chain — i.e., suspension is not physically realized.
>
> Let `host_bone = orifice.Center.parent_ragdoll_bone` (per §6.1 hierarchy).
>
> ```
> for each ring direction d in [0..7]:
>     dir_d          = direction_vec[d]                          // outward in Center frame
>     ring_world_pos = orifice.Center.global × (dir_d × current_radius[d])
>     p              = pressure_per_dir[d]                       // ≥ 0 from bilateral compliance
>     s_intrinsic    = EI.arc_length_at_entry + r_offset_along_axis[d]
>
>     // Radial reaction: rim pushes back along its own outward axis
>     radial_force_on_host = -dir_d * p
>
>     // Axial wedge — surface-normal tilt at this ring's arc-length.
>     // dr/ds is taken with respect to distance traveled along +entry_axis
>     // (outward) at the contact, NOT along the tentacle's intrinsic arc-length.
>     // The intrinsic gradient is converted by the sign of the tangent's
>     // projection on entry_axis: a tentacle threading inward (tangent ·
>     // entry_axis < 0 — the typical suspension geometry) flips the sign.
>     drds_intrinsic = signed_girth_gradient_at_arc_length(EI.tentacle, s_intrinsic)
>     t_hat          = evaluate_tentacle_tangent(EI.tentacle, s_intrinsic)
>     drds_outward   = drds_intrinsic * sign(dot(t_hat, orifice.entry_axis))
>     norm           = sqrt(1.0 + drds_outward * drds_outward)
>     axial_hold     = -p * drds_outward / norm
>     axial_force_on_host = orifice.entry_axis * axial_hold
>     // Sign convention (numerically verified; see "Wedge sign sanity" test):
>     //   drds_outward > 0  (knot apex on the cavity-EXTERIOR side of this
>     //                      ring contact — knot mid-thrust into cavity, leading
>     //                      flange wedging the rim):
>     //                      axial force on host is INTO CAVITY. Engulfment-assist.
>     //   drds_outward < 0  (knot apex on the cavity-INTERIOR side of this
>     //                      ring contact — knot lodged inside, rim sitting on
>     //                      the knot's exterior-facing slope):
>     //                      axial force on host is TOWARD EXIT. This is the
>     //                      suspension-holding direction — host pulled toward
>     //                      anchor side, transmitting hero weight up the chain.
>
>     // Friction-tangential along the tentacle axis at this ring.
>     // tangential_friction_per_dir[d] is populated by §4.3 type-2 routing
>     // (a scalar magnitude); convert to vector by multiplying by t_hat.
>     friction_force_on_host = -t_hat * EI.tangential_friction_per_dir[d]
>
>     total = radial_force_on_host + axial_force_on_host + friction_force_on_host
>     host_bone.apply_impulse_at_position(total * dt, ring_world_pos)
>
>     EI.reaction_on_ragdoll += total
> ```
>
> **Why the normalized form, and why not `tan`.** The axial component of a normal force on a surface with axial gradient is `pressure × sin(θ)` where `tan(θ) = drds_outward`. The expression `-p × drds_outward / sqrt(1 + drds_outward²)` is exactly `-p × sin(θ)` — bounded by `p` at the limit (a vertical flange, where `sin → 1` while `tan → ∞`). Earlier drafts using `tan(local_taper)` blew up at the very geometry the system most needs to handle correctly. Earlier drafts using the unnormalized linearization `-p × drds_outward` are fine for shallow slopes (≤ ~30° taper) but degrade past that.
>
> **Where force returns to the tentacle (case-by-case).** §6.3's bilateral compliance writes `target_radius_per_dir[d]` and an asymmetry delta on near particles. The asymmetry write is a **shape-parameter modification** — it alters effective radius for subsequent collision queries, but does **not** push particles. Force feedback into the chain comes from elsewhere, and the path differs by case:
>
> - **Knot inside rim** (`drds_outward < 0` at the rim contact, knot apex on the cavity-interior side): the chain receives force via **type-2 collision projection** during PBD iterations — knot particles geometrically inside the spring-damper-driven ring radius (§6.4) are projected back outside it (§4.2 type-2 path). Tangential motion is then capped by the friction projection (§4.3). Both are real position corrections. This is the canonical suspension-holding path.
> - **Smooth shaft inside rim** (`drds_outward ≈ 0`, no knot, no taper): the wedge-axial term vanishes; radial projection is small, often within hysteresis. Hold is **purely friction at the rim** along the shaft direction (§4.3). Suspension on a smooth shaft is therefore friction-limited — see §14 gotcha and the "Smooth-shaft suspension fails" test.
> - **Knot mid-thrust into cavity** (`drds_outward > 0`, leading flange wedging the rim from outside): wedge axial force on the host is INTO CAVITY — the rim is dragged inward as the knot pushes through. This is engulfment-assist, not suspension. Friction direction depends on the tentacle's instantaneous axial velocity.
>
> The reaction-on-host-bone step closes the third-law loop on the **rim side**; the tentacle side is unchanged and runs through existing collision + friction projections.
>
> **Terminology.** All per-direction quantities use `_per_dir[d]` — canonical, established in §6.2. `pressure_per_ring[r]` and similar `_per_ring[r]` aliases used in earlier drafts are retired; do not reintroduce them.

Also append the damage→grip coupling:

> **Damage degrades grip gradually.** Effective grip strength decays via `smoothstep` against accumulated damage:
>
> ```
> dmg_t = clamp(EI.damage_accumulated_total / damage_failure_threshold, 0, 1)
> effective_grip_strength = base_grip_strength
>     × mod.grip_strength_mult
>     × (1.0 - smoothstep(0.0, 1.0, dmg_t))
> ```
>
> Smoothstep, not linear: linear gives a derivative discontinuity at the threshold (visible as a sudden cliff to zero). Smoothstep tails off gracefully.
>
> Sustained suspension or prolonged grip raises damage; grip slips well before the orifice "fails." `damage_failure_threshold` is per-orifice; default `1.0` arbitrary unit, scaled by per-tick damage rate.
>
> `OrificeDamaged` is a **continuous channel** (already in §8.1), not an event — don't emit per-tick events for accumulated damage.
>
> Emit one-shot `GripBroke` when `effective_grip_strength` first crosses below `0.1`. **Hysteresis:** do not re-emit until `effective_grip_strength` has recovered above `0.2` and crossed `0.1` again. Prevents flutter at the threshold.

#### §6.5 — Knot-aware grip ramp

Append:

> **Knot-aware grip ramp.** When a girth differential is straddling the rim, grip engagement ramps faster:
>
> ```
> knot_factor = clamp(|girth_gradient_at_rim| / reference_gradient, 0, 1)
> grip_engagement_rate_effective = base_rate * (1.0 + knot_factor)
> ```
>
> `girth_gradient_at_rim` is the signed axial derivative of girth where the tentacle crosses the entry plane — the same quantity used by the §6.3 axial wedge. Magnitude is large for a knot, near zero for the smooth shaft. Reference gradient is per-orifice (default `1.0`). Makes "trapped behind a knot" feel land reliably without affecting smooth-shaft scenarios.
>
> **Source of the gradient.** Bake `d(girth)/ds` as a second channel of the girth texture (§5.4) at mesh import / procedural-generation time. The same texture sample serves both §6.3 (axial wedge) and §6.5 (knot factor). Avoids per-tick finite-differencing.
>
> **No `accept_penetration` flag, no `min_approach_angle_cos` gate.** Per §1: if soft physics can't refuse, raise stretch_stiffness, raise grip strength, lower wetness, or write the appropriate `OrificeModulation` channels. Glancing-approach rejection waits for a connected curved-surface representation of the rim in type-2 collision (currently rings are 8 discrete radial bones; once they form a real surface, glancing approaches slide off naturally — see §14).

#### §6.9 — Peristalsis applies to all tunnel contents (mechanical clarification)

Add a clarifying note after the peristalsis equation introduced in the 2026-04-23-02 update:

> **Mechanical scope.** Peristalsis is implemented as a time-varying contribution to `target_radius_per_dir[d]` — the same channel bilateral compliance writes. Concretely, for each ring direction at every active tunnel ring along the orifice's tunnel:
>
> ```
> wave_phase = (arc_length_at_ring × peristalsis_wavelength
>             - peristalsis_wave_speed × t) × 2π
> peristalsis_target_radius =
>     rest_radius * (1.0 - peristalsis_amplitude * sin(wave_phase))
> target_radius_per_dir[d] = max(target_radius_per_dir[d], peristalsis_target_radius)
> ```
>
> (Or, depending on whether peristalsis is constrictive or dilatory at the trough, blend or `min`/`max` per the authored intent.)
>
> **Consequence.** Any particle in the tunnel — bead-chain or penetrating tentacle — that is in collision contact with the deformed wall radius is pushed by the same projection. Bilateral compliance writes asymmetry to nearby tentacle particles; type-3 collision (tunnel wall) handles the rest. **No separate "push tentacle particles" force path is needed.** This makes peristalsis the canonical mechanism for both ingestion (negative `peristalsis_wave_speed`) and expulsion (positive) of penetrating tentacles, alongside its bead-storage role.

#### §6.10 (new) — Transient pulse primitives and autonomous appetite

Insert after §6.9:

> ### 6.10 Transient pulse primitives
>
> Steady peristalsis (§6.9) covers continuous waves. Transient one-shot pulses cover punctuated reflexes — climax contractions, gag reflex, pain spasm, refusal spasm, knot-engulfment "gulp." Implemented as additive envelopes on top of `peristalsis_amplitude` / `peristalsis_wave_speed`, evaluated per tick.
>
> ```cpp
> struct ContractionPulse {
>     float       magnitude;     // 0..1, peak added to peristalsis_amplitude
>     float       speed;         // arc-length/sec, signed (positive = exit, negative = ingest)
>     float       wavelength;    // typically ≥ tunnel length → acts as one wave
>     float       duration;      // seconds (envelope total length)
>     float       t_started;     // populated on activation
>     Ref<Curve>  envelope;      // 0..1 over normalized age; default below
>     uint32_t    applies_to;    // bitfield: TENTACLES = 1, BEADS = 2
> };
>
> Vector<ContractionPulse> active_pulses;   // per orifice; cap ~4
> ```
>
> **Pulses are atomic.** No `count`, no `interval`. Repeating patterns (orgasm, etc.) are sugar at the *emitter* level: the pattern emits N atomic `ContractionPulse`s with staggered `t_started`. The orifice tick has one job — evaluate active pulses additively.
>
> Per-tick contribution:
>
> ```
> effective_amplitude = peristalsis_amplitude
> effective_speed     = peristalsis_wave_speed
> for each pulse p in active_pulses (filtered by applies_to):
>     age = current_time - p.t_started
>     if age >= p.duration:
>         retire and continue
>     env = p.envelope.sample_baked(age / p.duration)
>     effective_amplitude += p.magnitude * env
>     effective_speed     += p.speed     * env
> ```
>
> **Default envelope.** Built-in `Curve` resource: trapezoidal `0 → 1 → 1 → 0` with 20% attack, 60% sustain, 20% release. Authoring may override per-pulse with custom curves (sharp spike, slow swell, etc.).
>
> **Named patterns** (Reverie reaction-profile sugar — emitters that queue lists of atomic pulses; not new physics):
>
> - `OrgasmPattern` — 6 pulses, magnitudes `[0.8, 0.7, 0.6, 0.5, 0.4, 0.3]`, stagger 0.6 s, `speed +0.4 m/s`, default envelope.
> - `GagReflexPattern` — 1 pulse, magnitude 1.0, duration 0.4 s, sharp envelope (10% attack, 20% sustain, 70% release), `speed +0.6 m/s` on the oral tunnel; combined at the Reverie layer with `jaw_relaxation → 1` and head `voluntary_motion_vector` rear-ward.
> - `PainExpulsionPattern` — 1 pulse, magnitude 0.7, duration 0.3 s, sharp envelope.
> - `RefusalSpasmPattern` — 2 pulses, magnitude 0.5, alongside `active_contraction_target → 0.6` and host `voluntary_motion_vector` away.
> - `KnotEngulfPattern` — 1 pulse, *negative* speed, magnitude 0.7, duration 0.5 s, wavelength = tunnel length.
>
> The term "DrawInPulse" used in earlier drafts is **not** a separate type — it is a `ContractionPulse` with negative `speed`. Avoid the term in code; use `ContractionPulse` everywhere.
>
> **Autonomous `appetite` (optional).** Per-orifice `appetite: float` (default 0.0) drives automatic reverse peristalsis when a girth differential is detected at the entry plane:
>
> ```
> if orifice.appetite > 0 and girth_at_entry_plane > orifice.rest_radius * 1.05:
>     auto_speed     = -orifice.appetite * appetite_speed_scale
>     auto_amplitude = +orifice.appetite * appetite_amplitude_scale
>     effective_speed     += auto_speed
>     effective_amplitude += auto_amplitude
> ```
>
> Reverie owns the value of `appetite` (state-driven, can be 0 most of the time); the mechanical response is autonomous below it. Use to express character archetypes ("hungry rim") without scripting per-encounter pulses.

#### §8.1 — New events (lifecycle + generic pulse)

Append to the `StimulusEventType` enum:

> ```cpp
> // Pattern lifecycle (added 2026-04-27). Most subscribers want these,
> // not per-pulse fires.
> OrgasmStart, OrgasmEnd,
> GagReflexStart, GagReflexEnd,
> PainExpulsionStart, PainExpulsionEnd,
> RefusalSpasmStart, RefusalSpasmEnd,
>
> // Generic per-pulse fire — for fine-grained sound triggering or
> // physics-precise reactions. Most subscribers will ignore this and use
> // the lifecycle events above.
> ContractionPulseFired,        // extra: { pattern_id, magnitude, kind }
>
> // Discrete physical beats (added 2026-04-27)
> KnotEngulfed,                 // bulky girth crossing inward past the rim
>                               //   (counterpart to BulbPop)
> EntryRejected,                // EntryInteraction creation failed for soft-physics
>                               //   reasons. extra: { peak_pressure, reason }
> ```
>
> **No event-type-per-pattern.** Adding `OrgasmContraction`, `LustfulSpasm`, `PostCoitalRipple` as distinct event types would inflate the enum unboundedly. Patterns are data; events are type-checked enum values that subscribers compile against. The generic `ContractionPulseFired` carries pattern identity in its `extra` dictionary. Lifecycle events are coarse-grained brackets, kept as a small fixed set.
>
> **`EntryRejected` is for soft-physics rejection only.** There is no hard-refusal lever (per §1 discipline). `EntryRejected.reason` enumerates physics causes:
> - `InsufficientPressure` — approach pressure below grip-engagement threshold.
> - `FrictionStuck` — tentacle pinned by static friction before crossing the entry plane.
> - `OrificeBusy` — cap of 3 simultaneous tentacles per §6.5 reached.

#### §8.2 — Modulation channel additions

Append to `OrificeModulation`:

> ```cpp
> // Transient pulse activation (added 2026-04-27).
> // Reverie pushes new ContractionPulse entries into the orifice's
> // active_pulses array through a mutator method. Patterns are emitted as
> // multi-pulse sequences by the pattern emitter (sugar; not part of the
> // tick-level data).
> void queue_contraction_pulse(ContractionPulse p);
> void emit_pattern(StringName pattern_id);   // sugar: queues N atomic pulses
>
> // Autonomous appetite (added 2026-04-27).
> // 0..1; non-zero enables automatic reverse peristalsis when
> // girth_at_entry > rest_radius × 1.05.
> float appetite = 0.0;
> ```

#### §10.2a (new sub-section) — TentacleMesh as a `PrimitiveMesh` subclass

This is a UX fix; it does not change the modifier model.

> **Resource shape.** `TentacleMesh` is a `PrimitiveMesh` subclass (overrides `_create_mesh_array()`; calls `request_update()` from setters). Inspector edits regenerate live without per-set `ArrayMesh` allocation, fixing the slider-snap-back UX where setters that recreated `Mesh` / `Resource` triggered `notify_property_list_changed()` and dropped inspector focus.
>
> **Workflow remains two-stage:**
>
> 1. **Edit time.** `TentacleMesh` is a `PrimitiveMesh` assigned to `MeshInstance3D.mesh`. Property edits trigger `request_update()`; the engine regenerates surface arrays lazily on the next draw. No baked output yet.
> 2. **Bake to ship.** A "Bake" inspector action freezes the current state into a static `.tres ArrayMesh` plus the auxiliary outputs (`girth_texture`, `rest_length`, mask channels). The static `.tres` is what ships. Runtime regeneration remains supported but is not the gameplay path (§5.4 unchanged).
>
> **Auxiliary bake outputs unchanged.** Channel layout (UV0 / UV1 / COLOR.rgba / CUSTOM0) and girth-texture format are unchanged.
>
> **Predecessor.** This supersedes both the previous `TentacleMesh : Resource` shape (implementation state) and the §10.2 "TentacleMeshRoot Node3D with modifier child Nodes" authoring paradigm in the canonical doc. The Node-tree pattern is retired — modifiers are now part of the data model on `TentacleMesh` itself (see §10.2b).

#### §10.2b (new sub-section) — Modifier model: kernel + repeat + falloff

Architectural change to the modifier data model, independent of §10.2a.

> **Resource layout (v1):**
>
> ```
> TentacleMesh : PrimitiveMesh
> ├── length, base_radius, tip_radius, radius_curve
> ├── radial_segments, length_segments, cross_section
> ├── twist_total, twist_curve, seam_offset, intrinsic_axis_sign
> ├── distribution_curve : Curve            (controls non-uniform §3.6 init)
> ├── modifiers : Array[TentacleModifier]   (single flat list in v1)
> └── tip_shape : TentacleTipShape          (separate library: Pointed, Bulb, Flare,
>                                              Canal, Mouth, Rounded, …)
>
> TentacleModifier : Resource (abstract)
> ├── enabled : bool
> ├── t_start, t_end : float                (arc-length range, [0..1])
> ├── feather : float                       (smoothstep falloff at boundaries)
> ├── kernel : enum { Ring, Vertex, Mask }  (a modifier may declare multiple)
> ├── repeat : int                          (1 = single instance; N = N copies)
> ├── falloff_curve : Curve                 (k=0 at first instance, k=1 at last)
> ├── radial_mask : enum { AllAround, OneSide, TwoSide, Spiral }
> └── _apply(ctx, t_start, t_end, feather, repeat, falloff)
> ```
>
> **Sections deferred to v2.** A `TentacleSection` resource with shared, feathered boundaries is an authoring grouping for tentacles with 12+ stacked modifiers. v1 ships with per-modifier `t_start` / `t_end` / `feather` directly on `TentacleModifier` — no grouping container, no section-boundary slider semantics. Promote to multi-section once authoring needs it; the kernel / repeat / falloff factoring is unchanged when that happens.
>
> **Modifier kernels.** Three primitive kernel types cover the full feature catalog:
>
> - `Ring` — per-axial radius / normal modulation, full ring (knot, ripple, taper override, local twist).
> - `Vertex` — per-vertex offset as a function of (arc_s, theta) (wart, spine, sucker cup).
> - `Mask` — writes to COLOR.rgba / UV1 / CUSTOM0 only (papillae, photophore, color band, sheen band).
>
> A modifier may declare multiple kernel types (e.g. suckers = `Vertex + Mask`).
>
> **Stacking rule.** Within the modifier list, ring-kernel offsets sum; mask-kernel writes max-blend per channel; vertex-kernel offsets sum. No exposed blend modes.
>
> **Repeat + falloff.** Single primitive that wraps the kernel as a 1D instancer along the modifier's range:
>
> ```
> for k in 0..repeat:
>     local_t = lerp(t_start, t_end, k / max(repeat - 1, 1))
>     scale   = falloff_curve.sample(k / max(repeat - 1, 1))
>     apply_kernel(ctx, local_t, feather, scale * base_amplitude)
> ```
>
> **`SuckerRowFeature` reframes as `SuckersModifier`** — same params (count, position_curve, size_curve, side, rim_height, cup_depth, double_row_offset), now operating in the modifier list with `kernel = Vertex + Mask`.
>
> **Modifier catalog** (geometry + mask types — not all v1):
>
> | Modifier                | Kernel(s)       | v1?                                                |
> |---|---|---|
> | `SuckersModifier`       | Vertex + Mask   | yes (rename of existing)                           |
> | `KnotModifier`          | Ring            | yes (egg / sphere / ridged / custom-curve profile) |
> | `RippleModifier`        | Ring            | later                                              |
> | `RibsModifier`          | Ring            | later                                              |
> | `WartClusterModifier`   | Vertex          | later                                              |
> | `SpinesModifier`        | Vertex          | later                                              |
> | `RibbonModifier`        | Vertex          | later                                              |
> | `TwistOverrideModifier` | Ring            | later                                              |
> | `PapillaeModifier`      | Mask            | later                                              |
> | `PhotophoreModifier`    | Mask            | later                                              |
> | `ColorBandModifier`     | Mask            | later                                              |
> | `SheenBandModifier`     | Mask            | later                                              |
> | `EmissionBandModifier`  | Mask            | later                                              |
>
> **Validation against physics constraints** runs over the *aggregated* radius profile after all modifiers bake — soft amber zone before hard stop, with hover tooltip explaining which constraint (max girth-ratio per unit length, max twist rate, etc.).
>
> **Tip shape library** is separate from the modifier list. Each tip shape is a small `Resource` with its own params (Pointed: nothing extra; Bulb: bulb_radius, taper_in_length; Flare: flare_count, flare_depth; etc.). Picked once per tentacle. The tip is silhouette-defining and lives in the mesh layer per §5.0.

#### §12 — Performance budget refinements

Append:

> **Realistic active-tentacle ranges (mid-range desktop, ~RTX 3060 class, 1080p, 60 Hz):**
>
> | Scene | Active tentacles |
> |---|---|
> | Hero + tentacles, no orifice contact | 8–12 |
> | Hero + tentacles, 1–2 orifice interactions | 6–8 |
> | Heavy scenario (multiple orifices, tangle) | 4–6 |
> | Same scene, after Marionette SPD ports to C++ | + ~50% |
> | Steam Deck / mid laptop iGPU class | ~half of above |
>
> Counts are *active* — idle / off-screen / asleep tentacles cost essentially nothing (PBD trivially sleeps; spline texture upload skips when no particle moved past epsilon). Treat all values as ±50% until Phase 4 (collision) and Phase 5 (orifice) are measured with a real hero present.
>
> **Cost levers, in order of cost-effectiveness:**
>
> 1. Sleep when idle.
> 2. LOD iteration count (close: 8, mid: 4, far: 2).
> 3. LOD physics rate (60 / 30 / 15 Hz tiers by distance/relevance).
> 4. LOD mesh tessellation (cheap; mesh is GPU-skinned).
> 5. Port Marionette SPD to C++ (largest single CPU recovery; deferred).
> 6. Spatial-hash tuning (only relevant once tentacle↔tentacle is in).
> 7. Shader LOD (drop iridescence/SSS at distance).
>
> **Lightweight wrapping-grade tentacle profile** — for "many tentacles wrap the hero" scenarios:
>
> | Param | Hero-grade | Wrapping-grade |
> |---|---|---|
> | Particles | 32 | 12 |
> | PBD iterations | 8 | 4 |
> | Constraints | distance, bending, target, anchor, collision, friction, attachment | distance, bending, anchor, collision (no friction-in-iteration loop) |
> | Tentacle↔tentacle (Type 7) | yes | **no** (wrappers pass through each other) |
> | Orifice interaction | yes | no |
> | Bulger contributions | yes | no |
> | Mesh tessellation | 16 × 24 | 8 × 12 |
> | Sleep aggressively | optional | mandatory |
>
> A wrapper costs ~25–35% of a hero-grade tentacle. Acceptable budget shifts to ~12–18 wrappers + 2 leaders simultaneously active.
>
> **Role swap is not free.** Promoting a wrapper to a leader (or demoting) requires constraint-stack rebuild — type-7 spatial hash registration, friction-iteration enable, bulger registration, orifice eligibility flip. For static role assignment per encounter this never pays. For dynamic role swap mid-encounter, expect a few hundred microseconds and a one-tick visible discontinuity. Don't author swaps in hot loops; if a chorus tentacle needs to become a leader mid-encounter, fade it out and spawn a fresh leader instead.
>
> **Mass-wrap encounter pattern: leaders + chorus.**
>
> - **2–4 TentacleTech leaders** physically grab and constrain the hero (bilateral compliance, friction, asymmetry, orifice work, bus events).
> - **Surrounding mass of Tenticles tubes** (visual chorus) anchored to environment geometry, attracted to hero silhouette via voxelized SDF (`Tenticles_design.md` §1.7), with curl noise. Cannot apply force — purely visual mass.
> - **Termination trick:** place a few Tenticles tube tips near the leader contact points so the eye reads the whole tangle as one mass.
> - **Bus coupling stays at user level.** Tenticles does **not** subscribe to `StimulusBus`. User-level GDScript glue reads the bus and writes Tenticles' public params (curl-noise amplitude, attractor radius, etc.). Tenticles remains self-contained per its existing scope boundary (`Tenticles_design.md` §0).
>
> Hard scope boundary unchanged: Tenticles never collides with, attaches to, or applies force to the hero. Anything that touches the hero physically is TentacleTech.

#### §14 — New gotchas

Append:

> - **Suspension tentacles must be anchored to environment geometry, not to another character's ragdoll bone.** Hero gravity transmitted through a single Marionette joint (typically the lumbar) exceeds the active-ragdoll torque budget and produces visible jitter or collapse. Anchor to ceiling / wall / static level mesh. Unrelated to the tentacle chain itself, which transmits force fine through PBD distance + anchor constraints.
> - **Suspension requires a girth differential, not just compression.** A smooth shaft compressed past the rim transmits no radial reaction force into the chain — the rim is kinematic, contact projection only fires when a particle is geometrically inside the deformed rim. Suspensions must use a tentacle with a knot, bulb, ridge, or other girth differential straddling the rim. Author scenarios accordingly.
> - **No `accept_penetration`-style hard refusal levers exist.** If a scenario seems to need one, raise stretch_stiffness, raise grip strength, lower wetness, or write the appropriate `OrificeModulation` channels. See §1.
> - **Glancing-approach rejection is not modeled.** Currently rings are 8 discrete radial bones; a glancing tentacle slides along whatever rim geometry that produces. A future revision that builds a connected ring-cylinder surface for type-2 collision will let glancing approaches slide off naturally; until then, accept and absorb glancing approaches via the soft-physics path.

---

### `Marionette_plan.md`

#### Add: Soft-tissue jiggle bones for non-rim regions

> ### Jiggle bone clusters
>
> Non-rim soft tissue regions (gluteus, breast, belly, jowls, etc.) currently have no autonomous dynamics: TentacleTech's bulger system (`TentacleTech_Architecture.md` §7) deforms them while a contact is active, but bulger eviction fade is 2 frames (§7.5) — once contact ends, motion stops. Real fat tissue keeps wobbling for ~1 second after impact.
>
> **Solution: jiggle bone clusters.** Per soft region, 1–2 child bones with translation-only SPD (rotational SPD deferred — see below), parented to a host bone (hip / ribcage / pelvis). Authored once per hero in Blender; skin weights paint the soft region's vertices to the jiggle bone with falloff.
>
> ```
> hip_L
> └── glute_L_jiggle    (offset from hip_L; SPD on translation)
> ```
>
> Per tick:
>
> ```
> for each jiggle bone j:
>     parent_world = j.parent.global_transform
>     target_world = parent_world * j.rest_local_offset
>     // SPD with parent acceleration as feed-forward
>     j.world_position = spd_step(j.world_position, target_world,
>                                 j.velocity, j.k, j.d, dt)
>     j.local_position = parent_world.inverse() * j.world_position
> ```
>
> Same SPD code Marionette already runs on the spine; copy with different parameters per region. Stiffness and damping authored per-hero (broader hip / fuller bust → softer).
>
> **Cost.** Trivial. ~10–20 jiggle bones per hero × SPD step = sub-microsecond.
>
> **Authoring gotcha (mandatory).** Jiggle bones must be in the skeleton hierarchy at *modeling time*. Skin weights are painted to them in Blender during the same pass that paints to body bones. Adding a jiggle bone at runtime does not retroactively skin existing geometry to it. The `JiggleProfile` resource (below) configures *parameters* of jiggle bones the model already exposes; it cannot create new ones.
>
> **Rotational SPD (v2).** Real fat jiggle has rotational components — a glute swings as much as it translates relative to the parent hip. v1 ships translation-only because it covers most of the visible motion at lowest implementation cost; v2 adds a rotation-quaternion SPD on the same bone. The Phase 9 milestone gates v2 on visible motion-quality shortfall, not feature completeness.
>
> **Why not SoftBody3D.** Explicitly forbidden by repo convention (top-level `CLAUDE.md`).
>
> **Why not extend bulger eviction fade.** Bulgers are *displacement vectors* applied along the contact normal; freely 3D wobble (with inertia preserved across direction changes) requires a frame-of-reference (the parent bone), which a displacement vector lacks. Not a fade-time problem; a representation problem.
>
> **Authoring.** Jiggle bones are added by the same Blender script that authors orifice ring bones (`TentacleTech_Architecture.md` §10.4), under a separate "soft regions" pass. Per-hero parameter overrides land on a `JiggleProfile` resource analogous to `OrificeProfile`.

---

## New files to create

None. All additions are amendments to existing canonical docs.

---

## Out-of-scope / explicitly deferred

- **Length redistribution / "S-curve length storage"** (elastic length budget along the chain, total conserved, locally redistributable). The §4.3 soft-contact-stiffness option is the simpler first cut; revisit only if visible slack ruins the feel.
- **Multi-section modifier model** (`TentacleSection` resource with shared, feathered boundaries). v1 ships with a flat modifier list and per-modifier arc-length range. Promote once authoring needs grouping.
- **Hard refusal levers** (`accept_penetration` boolean, `min_approach_angle_cos` gate). Dropped. Soft-physics modulation owns refusal.
- **Rotational jiggle SPD.** v2; gate on visible motion-quality shortfall in Phase 9 testing.
- **In-scene Tentacle Builder UX** (camera-fade engage, occluder cutout, in-scene editing of modifiers + tip shape, controller-first input). The data model lands here in §10.2a/b; the UX layer ships separately as `Tentacle_Builder.md` once the model is settled.
- **Marionette SPD C++ port.** Held in reserve per top-level `CLAUDE.md`. Triggered only by profiling evidence at realistic character count.
- **Tenticles voxelizer** (required for hero-silhouette reaction in the chorus pattern). Tenticles is plan-stage; the voxelizer (`Tenticles_design.md` §1.7) is not the first vertical slice. The leaders+chorus encounter pattern can't ship until that lands.
- **Connected curved-surface representation of orifice rim.** Currently rings are 8 discrete radial bones; type-2 collision treats the rim as those discrete spokes. A future revision that builds a connected ring-cylinder surface would let glancing approaches slide off naturally — at which point a soft-only approach-angle behavior becomes geometrically real without a script lever.

---

## Phase plan touch-ups

- Phase 4 (collision) lands §4.3 soft-contact-stiffness alongside the type-1 friction projection — same code site.
- Phase 5 (orifice) lands the §6.3 reaction-on-host-bone closure, the §6.10 pulse primitives, the new §8.1 events, the per-`EntryInteraction` `ejection_velocity`, the damage→grip coupling, and the §6.9 mechanical clarification. This is the phase where suspension becomes physically real.
- Phase 9 (polish) lands the optional `appetite` autonomous mode, the knot-aware grip ramp, and the Marionette jiggle bones (translation-only SPD).

The §10.2a / §10.2b mesh-authoring changes (PrimitiveMesh shape; modifier kernel + repeat + falloff) can land independent of the physics phases — they are authoring-side and don't gate any runtime work.

---

## Test additions

Acceptance scenarios that fall out of these additions. Test scenes are authored by Caetano; this section names what they should demonstrate.

- **Suspension hold (knot, trailing edge).** Hero hangs from a knot inside a vaginal/anal orifice for ≥ 30 seconds before damage-driven release. Knot 1.5× rest radius, position chosen so the rim sits past the knot's widest point on the *exterior-facing* slope (`drds_outward < 0`). Force chain is correct iff hold transmits hero gravity into the tentacle chain (chain tension reads ≥ ~686 N for 70 kg hero) — confirms `axial_hold > 0` (axial force on host is `+entry_axis`, toward exit) and the chain receives force via type-2 projection on the knot particles, not via asymmetry writes.
- **Smooth-shaft suspension fails (friction-only hold).** Hero on a smooth (no-knot, no-taper) tentacle shaft inside an orifice with `grip_engagement = 1`, dry skin, μ_s ≈ 0.7. Hold force ≈ μ_k × `Σ pressure_per_dir[d]` (sum of compression pressures across all 8 ring directions, kinetic coefficient). With nominal `stretch_stiffness`, this is **insufficient** for a 70 kg hero unless `active_contraction_target` is raised (which raises ring compression pressures). Confirms suspension is not "compression equals force transfer" — friction is the *only* axial path on a smooth shaft, and that path is bounded.
- **Wedge sign sanity.** Slowly translate a knot through the rim along the orifice axis (e.g., quasi-static thrust into cavity from outside). The axial reaction force on `host_bone` should change sign as the knot's apex crosses the rim plane — INTO CAVITY before crossing (engulfment-assist, `drds_outward > 0`), zero exactly at the apex, TOWARD EXIT after crossing (suspension-holding, `drds_outward < 0`). If the sign is wrong, suspension fails to transmit weight to host (the rim's axial reaction points *with* gravity instead of opposing it, and the hero falls through). Drives the post-pushback fix; regression-protect this.
- **Steep-flange numerical stability.** A knot with a near-vertical leading face (`drds_outward → ∞` numerically — e.g., a sphere-cap knot sampled near its equator, or a single-frame sampling artifact in a chain) must produce **finite** axial reaction. The normalized form caps the contribution at `pressure_per_dir[d]` (since `|sin θ| ≤ 1`), not infinity. Test: run the §6.3 reaction step with `drds_intrinsic = 1e6` and verify `|axial_force_on_host| ≤ pressure_per_dir[d] + ε` (single-tick bound). Catches regressions that silently drop the `/ norm` term.
- **OrgasmPattern expels.** With a smooth shaft inside, fire `OrgasmPattern`. Tentacle ejected fully within 3 seconds. `OrgasmStart` fires once at start, `OrgasmEnd` fires once at end, six `ContractionPulseFired` events in between with `pattern_id = "orgasm"`.
- **OrgasmPattern holds knot.** With a knot just past the rim, fire same pattern. Knot remains engaged through the contractions (may visibly nudge outward but not expel).
- **Knot engulfment.** Approach the rim with a knot at low velocity, `appetite = 0.5`. Knot is drawn in autonomously; `KnotEngulfed` fires.
- **Damage-driven release.** Sustain a high-stretch interaction (knot held 60+ seconds). `effective_grip_strength` decays smoothly via `smoothstep`; tentacle slips out gradually with stick-slip chirps and a single final `GripBroke` (no flutter; hysteresis prevents re-emit).
- **Soft-physics rejection.** Drive an EntryInteraction attempt with insufficient pressure (low approach velocity into a high-stiffness orifice). EntryInteraction fails to form; `EntryRejected { reason: InsufficientPressure }` fires. Demonstrates that the soft-physics rejection path exists without any hard `accept_penetration` lever.
- **Non-uniform distribution wrap radius.** A wrapping-grade tentacle with 60% of particles in the tip 30% of length wraps a thin ragdoll bone (e.g. wrist) at minimum radius ≤ 50% of the uniform-distribution baseline.
- **Soft contact wrap.** A tentacle wrapping a thigh stretches by ≤ 5% peak and recovers to within 0.5% of rest length within 0.3 s of contact ending.
- **Jiggle decay.** Slap the gluteus with a tentacle and detach. Visible wobble persists ≥ 0.6 seconds after detachment, decaying smoothly.
