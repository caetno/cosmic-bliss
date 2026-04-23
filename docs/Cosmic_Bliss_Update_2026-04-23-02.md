# Cosmic Bliss — Design Update (2026-04-23, supplement 02)

Supplements the earlier `Cosmic_Bliss_Update_2026-04-23.md`. Same structural rules: apply these edits to the canonical docs and create the new files listed at the end. **These are additions and corrections, not a restructure.** Four-extension architecture unchanged.

A handful of items in here **supersede** prior specs (bulger representation, hero mesh topology, excreted-tentacle physics). Those are flagged explicitly in §5.

Numeric values are starting points; treat as tunable.

---

## Summary of decisions

1. **Bulgers are capsules, not spheres.** `uniform vec4 bulgers[64]` becomes two parallel arrays (endpoint A, endpoint B). Sphere bulgers are encoded as degenerate capsules (A == B). Supersedes §7.1 as previously specced.
2. **Hero is one continuous invaginated shell.** Skin and internal cavity walls share a single mesh; the surface folds inward at each orifice to become cavity wall, terminates at the cavity's closed end, or chains to another orifice for through-paths. Normals are outward-everywhere. Materials split per-surface (skin / mucosa).
3. **X-ray is a shader mask, not separate geometry.** Skin surface fragments `discard` in the masked region; the mucosa surface behind them is already there and renders naturally. Drivable by player input and by Reverie modulation at state peaks.
4. **Storage, oviposition, and birthing reuse existing systems.** Stored contents are PBD bead chains pinned to tunnel splines (§6.8). Peristalsis is a time-varying tunnel girth modulation written by Reverie (§6.9). Birthing ring transit is identical to Scenario-2 bulb retraction. Excreted tentacles are ordinary TentacleTech tentacles with a "Free Float" scenario preset — **no `PhysicalBone3D` chains**.
5. **Hero authoring is marker-plus-parameters; geometry is derived.** Ring bones, rest radii, tunnel centerlines, tunnel radius profiles, and suppressed-capsule lists auto-derive from mesh topology and a small number of authored markers. Manual override hooks preserve escape paths.
6. **Core gameplay loop: mindset-shift objective with state-richness payout.** Each run has a target state-distribution or mindset-delta vector, surfaced through emotional cues rather than UI. Currency = integral of (entropy × mean magnitude × event-intensity weighting). No run-failure; worst case = zero payout.
7. **Tentacle identity extends beyond shape.** `TentacleType` gains behavioral (scorer bias, preset whitelist, orifice preference), emotional-coupling (state-gain bias, mindset-drift bias, reaction-profile tag), and presentation (sound bank, shader identity) dimensions. All data, no new systems.
8. **Skill mechanics, hidden-phenomenon achievements, sensitivity-map discovery, and tentacle loadout** land in a new `Gameplay_Mechanics.md` at project root.

---

## Changes to existing files

### TentacleTech_Architecture.md

#### §6.1 — Update ring bones to describe rim on invaginated shell

Replace the opening paragraph of §6.1 (before the code block) with:

> Per orifice on the hero, the rim is an edge loop of the continuous hero mesh at the point where the surface invaginates. Eight radial ring bones are placed at equal angular spacing around this rim loop, parented to a per-orifice center bone, which is parented to the nearest ragdoll bone. The rim is a single edge loop shared between the skin surface and the mucosa surface of the same mesh; skinning weights on that loop follow the ring bones, so ring-bone motion deforms skin and mucosa together at the rim.

No change to the skeleton sketch or the skinning-weight rule below.

#### §6 — Insert new subsection §6.8 after §6.7 (through-path), before §7

> ### 6.8 Storage chain
>
> Each tunnel may host a **storage chain**: a PBD particle subchain whose particles are constrained to the tunnel's arc-length axis. Each particle in this chain is a **bead** with a type tag.
>
> **Bead types.**
>
> - **Sphere bead.** Fields: `radius`, `surface_material`. Simplest case — a stored spherical object (egg, orb).
> - **Tentacle-root bead.** References a `Tentacle`. The tentacle's first `K` particles (typically 2–4) participate in the storage chain's distance constraints. The remaining particles are free PBD particles that hang into the tunnel volume and can writhe inside (coiled stored tentacle).
>
> **Chain mechanics.**
>
> - Beads are sorted by arc-length along the tunnel. Bead-bead distance constraints prevent overlap; each bead carries an effective `chain_radius` equal to its maximum cross-section in the plane perpendicular to the tunnel tangent.
> - Friction against the tunnel wall (type-3 collision, §4.2) prevents free drift. Wetness reduces it; grip/peristalsis overcomes it.
> - Beads collide with tentacles currently inside the same tunnel (type-5). A penetrating tentacle pushes beads axially along the chain.
> - When the ragdoll moves, the tunnel spline moves; beads track the spline and the chain wobbles naturally.
>
> **Through-path chains.** When `EntryInteraction`s are linked into a through-path (§6.7), storage chains link across them — a single continuous chain can span multiple orifices on the same hero. Migration from one orifice's tunnel to another is emergent: a bead pushed past the downstream boundary transfers to the adjacent chain.
>
> **Runtime cost.** ~10 beads per active tunnel is typical; trivial compared to the existing 12×32 = 384 particle budget. Storage chains participate in the same PBD solver loop; no separate simulation.

#### §6 — Insert new subsection §6.9 after §6.8

> ### 6.9 Oviposition and birthing
>
> A tentacle may hold payloads to deposit, and a hero may expel stored contents. Both reuse existing machinery.
>
> **Oviposition: `OvipositorComponent`.** Attached as a child of a `Tentacle`. Holds a queue of payload specifications (sphere profile or `Tentacle` resource). While the queue is non-empty, the tip particle's `girth_scale` is raised by `carrying_girth_bonus` to produce a visible lump traveling the shaft as the tentacle fills (optional; disable via `suppress_visual_carry` if authored aesthetics call for it).
>
> Deposit trigger (AI, Reverie, or script-driven): when the tip is past `deposit_depth_threshold` in a tunnel with an active `EntryInteraction`, one payload is consumed off the queue and spliced into that tunnel's storage chain at the tip's current arc-length. Tip girth returns to baseline. Emits `PayloadDeposited`.
>
> For tentacle payloads: the queued `Tentacle` spawns with base particle `inv_mass = 0` (pinned) at the insertion arc-length, remaining particles released into the tunnel. The new tentacle participates in the solver as a normal `Tentacle`, with its base locked into the storage chain.
>
> **Birthing: peristalsis.** Reverie writes a peristalsis modulation to each tunnel via new modulation channels (see §8.2 updates). The tunnel's rest-girth profile becomes time-varying:
>
> ```
> girth(t, time) = rest_girth(t) × (1 + amp × sin((t − speed × time) × 2π × wavelength))
> ```
>
> Beads in the low-girth phase of the wave experience asymmetric ring pressure producing a net axial force along the tunnel gradient — the same wedge mechanic as orifice-rim compression, applied tunnel-to-bead. Reverie can drive expulsion (amplitude high, speed positive along exit direction) or retention (amplitude low, or speed reversed to pull beads inward).
>
> **Birthing: ring transit.** When a bead reaches the orifice's inner entry plane, it is treated identically to a bulb on retraction (Scenario 2). Ring bones stretch nonlinearly to accommodate `bead.chain_radius`; bilateral compliance (§6.3) applies; grip hysteresis engages if grip was active; pop-release occurs past the ring's widest point. Emits `RingTransitStart` at initial contact and `RingTransitEnd` at completion, and `PayloadExpelled` with the bead reference as the full event payload.
>
> Damage accumulates per §6 if `bead.chain_radius` exceeds `orifice.max_radius`.
>
> **Tentacle-bead release on expulsion.** When a tentacle-root bead's pinned particles cross the entry plane outward, each pinned particle transitions `inv_mass` from 0 to the tentacle's normal per-particle mass in order. By the time the last pinned particle exits, the tentacle is fully free.
>
> The freed tentacle is an ordinary `Tentacle` with a **"Free Float" scenario preset** (see `TentacleTech_Scenarios.md` §A4 update): zero target-pull, high noise, low stiffness. In zero-G environments this produces natural wiggling. The existing PBD bending constraints (§3.3) fill the role that cone-twist joints would on a `PhysicalBone3D` chain. **Do not use `PhysicalBone3D` chains for excreted tentacles** — one solver type for everything (§1 principle), and the `PhysicalBone3D` scaling bug (§14) would re-surface.
>
> **Open design question (not blocking):** payload source for oviposition in gameplay — whether tentacles arrive pre-loaded, refill from environment sources, or have infinite capacity. Defer until encounter design lands.

#### §7.1 — Replace sphere bulger spec with capsule bulger spec

Replace §7.1 in full with:

> ### 7.1 Bulger uniform arrays
>
> A **bulger** is a capsule of influence in world space: two endpoints plus a radius. The hero skin and cavity-surface shaders read the capsule array and displace affected vertices along their surface normal.
>
> ```glsl
> uniform int  bulger_count;              // 0..64
> uniform vec4 bulgers_a[64];             // xyz = endpoint A, w = radius
> uniform vec4 bulgers_b[64];             // xyz = endpoint B, w = strength
> ```
>
> A sphere bulger (single point-of-influence, e.g. external contact) is encoded as `A == B`; the segment-distance math degenerates to point-distance automatically.
>
> Vertex shader inner loop:
>
> ```glsl
> vec3 displacement = vec3(0.0);
> for (int i = 0; i < bulger_count; i++) {
>     vec3  a  = bulgers_a[i].xyz;
>     vec3  b  = bulgers_b[i].xyz;
>     float r  = bulgers_a[i].w;
>     float s  = bulgers_b[i].w;
>
>     // Closest point on segment [a,b] to VERTEX
>     vec3  ab = b - a;
>     float t  = clamp(dot(VERTEX - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
>     vec3  cp = a + t * ab;
>     float d  = length(VERTEX - cp);
>
>     float influence = r * 2.5;
>     if (d < influence) {
>         float falloff = 1.0 - smoothstep(r, influence, d);
>         // Normal-direction push — "flesh displaced from below"
>         displacement += NORMAL * falloff * r * s * 0.6;
>     }
> }
> VERTEX += displacement;
> ```
>
> 64 capsules × 15k vertices = 960k segment-distance ops per frame. Still trivial on modern GPUs including integrated.
>
> **Why capsules.** Sphere bulgers produce beads-on-a-string visuals and cannot represent a tentacle *tube* inside a cavity — the deformation gap between samples is always visible. Capsule bulgers span between adjacent PBD particles, so a tentacle inside a tunnel produces a continuous tube-shaped deformation in both the overlying skin and the cavity wall from the same uniform array.

#### §7.2 — Replace bulger sources section

Replace §7.2 in full with:

> ### 7.2 Bulger sources
>
> Each hero's `SkinBulgeDriver` aggregates capsule bulgers each tick from the following sources.
>
> **Internal tentacles** (penetrating, inside any tunnel):
> - For each PBD segment whose both endpoints are inside the tunnel, emit one capsule bulger with endpoints at the two particle world positions.
> - Radius = `tentacle_rest_girth_at_arc_length × particle.girth_scale` (use major-axis radius when asymmetry is non-zero — approximation; the mesh itself carries the full ellipse visually).
> - Strength = 1.0.
> - For tentacles with > 8 segments inside, sub-sample to 6–8 evenly spaced capsules to stay within the 64 cap under heavy scenes.
>
> **Storage beads** (stored contents in any tunnel):
> - For sphere beads: emit a capsule with `A == B` at bead world position, radius = `bead.chain_radius × storage_display_factor` (typical `storage_display_factor ≈ 0.9`).
> - For tentacle-root beads: emit capsules between the pinned particles (treats the stored tentacle's base as a short segmented shape in the tunnel).
> - Strength = 1.0. Priority tier = `Storage` (see §7.6).
>
> **External contacts** (type-1 capsule collisions with significant normal force):
> - Emit a capsule with `A == B` at contact point (degenerate = sphere).
> - Radius = `clamp(normal_force / reference_force, 0, max_external_radius) × external_bulge_factor` (§7.2 normalization from the prior update is preserved).
> - Strength = 1.0. Priority tier = `Transient`.
>
> Maximum 64 active bulgers. If aggregated candidates exceed 64, keep by `(priority_tier, magnitude)` descending (§7.6). Eviction fade per §7.5.

#### §7 — Insert new subsection §7.6 after §7.5

> ### 7.6 Bulger priority tiers
>
> Each aggregated bulger carries a `priority_tier` enum used for eviction ordering under the 64-cap:
>
> - `Storage` — stored contents (sphere beads, tentacle-root beads). Never evicted while the containing region is visible to the camera. Flicker on eviction would be highly visible as organs that suddenly un-deform.
> - `Internal` — tentacles currently inside a tunnel.
> - `Transient` — external contact bulgers.
>
> Sort order under saturation: `Storage` first (keep all), then `Internal` by magnitude descending, then `Transient` by magnitude descending. `Storage` slots still count against the cap; if storage alone exceeds 64 (pathological case), keep highest-magnitude storage beads and accept visual clipping on the rest.

#### §7 — Insert new subsection §7.7 after §7.6

> ### 7.7 Cavity surface integration
>
> Internal cavity walls are surfaces of the same continuous hero mesh as skin (see §10 updates for authoring). Both surfaces include the bulger-deform vertex shader block from §7.1 and read the same uniform arrays. A bulger inside a tunnel therefore produces:
>
> - Cavity-wall vertices within falloff radius: displaced along cavity-wall normal (outward from cavity interior = into surrounding tissue).
> - Overlying skin vertices within falloff radius: displaced along skin normal (outward into world).
>
> Both fall out of one uniform loop. Falloff radius gates reach — a bulger with 6 cm falloff cannot deform organs 20 cm away through the torso, and this is the only gating mechanism needed in v1. No body-region layer masks.
>
> Cavity meshes do not get ring bones of their own. Ring bones at each orifice rim rig shared rim vertices (see §6.1 update); the rim is a single edge loop of the continuous mesh, and ring-bone motion deforms the rim visible from both sides.

#### §8.1 — Add new stimulus events

Append to the `StimulusEventType` enum list:

> - `PayloadDeposited` — fired by an `OvipositorComponent` on successful deposit. Payload: `tentacle_id`, `tunnel_id`, `bead_type`, `bead_arc_length`, `resulting_chain_size`.
> - `PayloadExpelled` — fired at the end of a ring-transit sequence on exit. Payload: `orifice_id`, `bead_type`, `bead_id` (if tentacle-root), `peak_ring_stretch`, `final_velocity`.
> - `StorageBeadMigrated` — fired when a bead's tunnel arc-length changes by more than a threshold within a tick (significant motion). Payload: `tunnel_id`, `bead_id`, `delta_arc_length`.
> - `RingTransitStart` — fired when a bead crosses the inner entry plane on its way out. Payload: `orifice_id`, `bead_id`, `bead_radius`.
> - `RingTransitEnd` — fired when the bead has fully crossed the rim. Payload: same, plus `duration_seconds`.
> - `PhenomenonAchieved` — fired when a `PhenomenonDetector` recognizes a rare emergent event (see `Gameplay_Mechanics.md`). Payload: `phenomenon_id`, `magnitude`, `context` (extras).

#### §8.2 — Add peristalsis fields and x-ray intensity

Add to the `OrificeModulation` struct:

> ```cpp
> // Peristalsis (drives storage-chain expulsion/retention)
> float peristalsis_wave_speed   = 0.0;   // arc-length units/sec; positive = toward exit
> float peristalsis_amplitude    = 0.0;   // 0..1 fraction of rest girth
> float peristalsis_wavelength   = 1.0;   // waves per unit arc-length
> ```
>
> Peristalsis modulation is per-tunnel, attached to the orifice whose tunnel it controls. Through-path tunnels use the entry orifice's peristalsis state by default; a later authoring hook may override this per-segment.

Add to the `CharacterModulation` struct (alongside the `attention_*` fields from the prior update):

> ```cpp
> float xray_reveal_intensity = 0.0;   // 0..1; consumed by hero skin shader
> ```

#### §9 — Insert new subsection §9 (x-ray rendering) or renumber existing

The existing §9 is "Mechanical sound." Insert x-ray as a new §9.x subsection near the end of §9, or as a new standalone section between §9 and §10 titled **"9.5 X-ray rendering"** if section numbering allows. Content:

> ### X-ray rendering
>
> X-ray reveal is a skin-shader mask, not separate geometry. The hero skin surface reads `xray_mask` (a per-vertex or per-fragment falloff, typically a radial or box volume in hero-local space) and `xray_reveal_intensity` (from the `CharacterModulation` channel, §8.2).
>
> Within the masked region, skin fragments transition to a translucent fresnel-rim appearance (silhouette preserved, strong at grazing angles) and may `discard` at high reveal intensity to let the mucosa surface behind them render naturally. The mucosa surface is already present in the continuous hero mesh (§10); no separate internal-anatomy meshes are instanced or toggled for x-ray purposes.
>
> **Drivers.**
> - Player-toggled: a player input writes directly to `xray_reveal_intensity` — e.g., button tap = 2s reveal and fade; hold = sustained.
> - Reverie-triggered: at high `Ecstatic`, high `Lost`, and high `Aroused` state magnitudes, Reverie writes `xray_reveal_intensity` up to ~0.7 as a state-peak effect. Player input clamps on top to full 1.0.
>
> **Aesthetic.** The cosmic / psychedelic direction (hero becoming visually permeable at peak states) is the intended feel; skin rim color and internal ambient glow are shader knobs tuned per-hero.
>
> **Performance.** Negligible. Mucosa surfaces draw whether visible or not (they're part of the mesh); the shader mask costs a few instructions per skin fragment. No additional render passes.
>
> **Cavity mesh visibility.** Cavity surfaces are never culled as a visibility group; the mask controls visibility through the skin. This keeps bulger-driven cavity deformation continuous even when x-ray is off (so if the player enables x-ray mid-encounter, internal state is already consistent).

#### §10 — Replace §10.4 and §10.5 with updated authoring model

Replace §10.4 ("Hero authoring") content with:

> ### 10.4 Hero authoring
>
> The hero is **one continuous mesh** with multiple material surfaces. The surface invaginates at each orifice to form the corresponding cavity wall, terminates at the cavity's closed end, or chains to another orifice (through-path). Normals are consistently outward across the whole surface — no duplicated or flipped vertices at rim edges.
>
> Material assignment uses per-surface splits:
> - Surface 0: exterior skin.
> - Surface 1..N: cavity walls per anatomical region (oral, vaginal, anal, etc.), each with mucosa material.
>
> Material boundaries are set at the rim edge loop or just inside it; the boundary doesn't have to align with the topological rim geometrically.
>
> **Blender pipeline.**
> 1. Model hero mesh with standard humanoid skeleton.
> 2. Model cavities as invaginations of the same mesh — extrude inward at each orifice to form tunnel volumes terminating at closed ends or connecting to other orifices.
> 3. Assign skin material to exterior faces, mucosa materials to cavity faces. Material boundaries near the rim are fine either inside or on the edge loop.
> 4. Do NOT flip cavity normals. Normals should be outward-from-the-surface everywhere. Use "recalculate outside" with the mesh as a single closed topology.
> 5. For each orifice: place an empty object (`OrificeMarker`) at the opening center, with its local +Y axis aligned with the opening's outward axis. Parent to the nearest ragdoll bone.
> 6. Optional: place empty objects as `TunnelMarker`s along internal paths if auto-derived centerlines need correction.
> 7. Export GLB with skeleton, empties, and all material surfaces preserved.
>
> **In Godot — auto-derivation (new).** A new `OrificeAutoBaker` tool (GDScript, editor plugin, extends the existing `ring_weight_generator`) runs at hero import time or on demand:
>
> 1. For each `OrificeMarker`: find the hero mesh edge loop nearest the marker, along the marker's local axis. This is the rim.
> 2. Compute rim centroid and `rest_radius` (mean distance from centroid to rim vertices).
> 3. Place 8 ring bones at equal angular intervals around the rim centroid, at rest radius, in the Skeleton3D. Parent to a per-orifice center bone parented to the marker's authored parent.
> 4. Weight-paint rim vertices to ring bones (angular-nearest-two with radial falloff outward per §6.1). Innermost rim loop gets full ring weight; outer loops taper to body-bone weights.
> 5. Skeletonize the cavity mesh volume downstream of the rim (medial-axis extraction); fit a Catmull spline to the medial curve. This is the tunnel centerline. Sample spacing tunable per-orifice.
> 6. At each tunnel sample, cast perpendicular rays to find distance-to-wall; output a rest-radius profile along arc-length. This is the tunnel girth profile used for type-3 collision.
> 7. Populate the orifice's `suppressed_bones` list with ragdoll capsules within N cm of the marker (N tunable, default 0.15 m). Author can override.
>
> **Manual override hooks** (for weird topology — non-manifold cavities, non-clean rim loops, branching tunnels):
> - `OrificeProfile.manual_ring_bones: Array[NodePath]` — short-circuits rim detection.
> - `OrificeProfile.manual_tunnel_spline: Resource` — short-circuits centerline derivation.
> - `OrificeProfile.manual_suppressed_bones: Array[String]` — short-circuits auto-suppression.
>
> When any manual override is set, that step's auto-derivation is skipped; other steps still run.
>
> **In Godot — scene setup (unchanged parts):**
> - Instance the GLB, add `CharacterBody3D` + `Skeleton3D`.
> - Add `PhysicalBone3D` nodes per ragdoll bone with capsules.
> - Per orifice: add `Orifice` node referencing the `OrificeMarker`, assign the `OrificeProfile` (auto-baker populates ring bones and tunnel data at bake time; runtime reads them).
> - Configure `SkinBulgeDriver` on hero.
> - Assign hero shader (handles skin + mucosa surfaces via per-surface materials, includes `tentacle_lib.gdshaderinc` for bulger deform).
>
> **Ragdoll colliders:** unchanged from prior spec.

Keep §10.5 as-is but note at the end:

> Auto-suppression per §10.4 populates this list from proximity at bake time; manual override remains available via `OrificeProfile.manual_suppressed_bones`.

#### §12 — Update bulger and cavity rows

Update the "Hero skin vertex shader" row from the prior `15k × 64 bulgers` to:

> | Hero mesh vertex shader (skin + mucosa ~20k × 64 capsules) | < 1.1 ms GPU | Segment distance per bulger; still well under budget. |

Add a note under the table:

> Cavity surfaces add ~3–6k vertices to the hero mesh skinning pass. Included in the row above.

#### §13 — Phase placement for storage / oviposition / x-ray

Append to Phase 8 task list:

> - Storage chain (§6.8): bead types, pinned PBD subchain, multi-bead distance constraints, through-path linking.
> - Oviposition (§6.9): `OvipositorComponent`, deposit queue, tip-threshold deposit trigger, tentacle-root bead spawn.
> - Birthing (§6.9): peristalsis modulation channels, ring-transit reuse of §6.3, tentacle-root release on expulsion.
>
> Acceptance criterion for 6.8/6.9: Scenario 12 (oviposition cycle) and Scenario 13 (excreted tentacle, free float) — see `TentacleTech_Scenarios.md` updates.

Add new Phase 7.5 or merge into Phase 7 polish:

> **Phase 7.5 — Capsule bulgers and x-ray.**
> - Replace sphere bulger uniform with capsule arrays (§7.1).
> - Per-segment capsule emission for internal bulgers (§7.2).
> - Priority tiers (§7.6).
> - X-ray skin shader mask and `xray_reveal_intensity` modulation plumbing (new §9 subsection).
> - Acceptance: tube-shaped deformation visible along tentacle length on both skin and cavity surfaces; x-ray toggle reveals internal deformation cleanly.

#### §14 — Add to non-negotiable list

Append to the "Non-negotiable" bullet list:

> - Hero mesh is a single continuous invaginated shell. Do not author cavity meshes as separate `MeshInstance3D`s. Do not duplicate or flip normals at rims.
> - Excreted tentacles are `Tentacle` instances with the "Free Float" preset. Do not use `PhysicalBone3D` chains.
> - Storage bulgers are never evicted while their region is on-camera. Respect the priority tier.

---

### TentacleTech_Scenarios.md

#### §A4 — Add "Free Float" scenario preset

Add a new row to the scenario preset table after row 12 (Recovery):

> | 13 | Free Float | 0 fixed | 0.0 | 0.15 | 1.0 | 0.8 | 0 | 1.0 |

Add its description to the list below:

> - **Free Float** — no target-pull, very low stiffness, high noise, full lubricity. Used by excreted tentacles post-expulsion (§6.9) in zero-G or low-gravity environments. Tentacle drifts and writhes under its own noise layers with no directional intent.

Scoring note (append to §A5 examples):

> - Free Float: `+infinity` for freshly-excreted tentacle-root beads for a `post_expulsion_period` (5–10 s), decays to normal scoring afterward.

#### §A8 — Expand TentacleType resource with identity dimensions

Replace the "TentacleType resource" table in §A8 with an expanded version:

> ### TentacleType resource
>
> **Mechanical** (contact feel):
>
> | Property | Range | Effect |
> |---|---|---|
> | `girth_stiffness` | 0.1–10 | Resistance to radial compression |
> | `axial_stiffness` | 0.1–10 | Resistance to axial compression |
> | `bending_stiffness` | 0.1–1.0 | PBD bending constraint stiffness |
> | `target_pull_stiffness` | 0.05–0.3 | Tip target-pull stiffness (can differ from bending — "soft-tipped spear" etc.) |
> | `mass_per_length` | kg/m | Inertia; heavy tentacles drag the ragdoll harder on friction contact |
> | `surface_friction` | 0–2 | Coulomb coefficient |
> | `surface_pattern` | enum | smooth / ribbed / barbed / sticky |
> | `rib_frequency` | Hz/arc-length | Spatial rib rate (if ribbed) |
> | `rib_depth` | 0–1 | Friction oscillation amplitude |
> | `lubricity` | 0–1 | Multiplicative friction reduction |
> | `adhesion_strength` | 0–0.5 | Additive friction from stickiness |
> | `mesh` | ArrayMesh | Visual mesh (girth profile auto-baked) |
>
> **Behavioral** (how the AI plays it):
>
> | Property | Range | Effect |
> |---|---|---|
> | `scorer_bias` | Dict[ScenarioPreset → float] | Multiplier on each preset's score; defines personality (patient hunter, aggressor, holder, etc.) |
> | `preset_whitelist` | Array[ScenarioPreset] | If non-empty, only these presets are eligible |
> | `preset_blacklist` | Array[ScenarioPreset] | Always excluded from eligibility |
> | `orifice_preference` | Dict[OrificeTag → float] | Weight over orifice tags for target selection |
> | `sensory_responsiveness` | 0–1 | How strongly scorer reads Reverie state back (reactive vs. unaware) |
> | `attachment_preference` | 0–1 | Weight for type-6 attachments vs. penetration-seeking target pulls |
>
> **Emotional coupling** (Reverie):
>
> | Property | Range | Effect |
> |---|---|---|
> | `state_gain_bias` | Dict[StateId → float] | Multiplier on specific Reverie state gain rates during this tentacle's contact events |
> | `mindset_drift_bias` | Dict[MindsetAxis → float] | Per-axis drift rate bias while this tentacle is engaged with hero |
> | `reaction_profile_tag` | StringName | Selector key Reverie uses to branch reaction profiles (distinct voice / face for distinct type) |
>
> **Presentation:**
>
> | Property | Effect |
> |---|---|
> | `mechanical_sound_bank` | AudioStreamBank | Per-type sound samples (squelch, creak, slap, etc.) consumed by `MechanicalSoundEmitter` |
> | `shader_identity` | ShaderParams | Per-type material knobs (translucency, bioluminescence, flush-on-arousal color) |

#### Part B — Add Scenarios 12 and 13 as future acceptance tests

After the existing "Scenario 11 (future)" note, append:

> **Scenario 12 (future) — Oviposition cycle.** An ovipositor-type tentacle enters an orifice, deposits 2–3 sphere beads into the tunnel over the course of an interaction, then withdraws. Beads remain visible via bulger-driven outer-skin and cavity-wall deformation. Acceptance test for §6.8 storage chain and §6.9 oviposition. Use as Phase 8+ validation.
>
> **Scenario 13 (future) — Excreted tentacle, free float.** A previously-stored tentacle-root bead is expelled through the orifice via Reverie-driven peristalsis; on full exit, it transitions to a free `Tentacle` with the Free Float scenario preset. In zero-G, it drifts and writhes under layered noise with no anchor. Acceptance test for §6.9 tentacle-bead release and A4 Free Float preset. Use as Phase 8+ validation.

---

### Reverie_Planning.md

#### §3.1 — Add new events Reverie reads

Append to the event list:

> - Oviposition / birthing: `PayloadDeposited`, `PayloadExpelled`, `StorageBeadMigrated`, `RingTransitStart`, `RingTransitEnd`
> - `PhenomenonAchieved` — emitted when a rare emergent event is detected by a `PhenomenonDetector` (see `Gameplay_Mechanics.md`); Reverie reads for state-gain purposes (novelty → Anticipatory, Ecstatic spikes on peak phenomena, etc.)

#### §3.2 — Add peristalsis and x-ray modulation writes

Add to "Per orifice" modulation list:

> - `peristalsis_wave_speed`
> - `peristalsis_amplitude`
> - `peristalsis_wavelength`

Add to "Global character" modulation list:

> - `xray_reveal_intensity` — 0..1, written up to ~0.7 at state peaks (high `Ecstatic`, high `Lost`, high `Aroused`). Player input can clamp higher on top. Consumed by hero skin shader for translucency/reveal.

#### §9 Phase plan — Add birthing-related sub-phase

Insert between Phase R6 (Pose targets) and Phase R7 (Mindset dynamics):

> 6.5. **Phase R6.5 — Peristalsis and ritual reactions.** Wire Reverie to write `peristalsis_*` channels based on state (e.g., high `Surrendered` + event pressure → expulsion waves; high `Anxious` → retention waves). Implement reaction profile branches for `PayloadDeposited` / `PayloadExpelled` / `RingTransitStart` / `RingTransitEnd` (distinct vocalizations and facial beats). Test with Scenario 12 and Scenario 13 setups.

---

### Gameplay_Loop.md

Patch existing sections; keep structure.

#### "Committed decisions" — Add entries

Append to the bullet list:

> - **Run objective is a mindset-shift vector or target state distribution.** Surfaced to the player through hero emotional cues (facial, vocal, shader) rather than UI progress bars. Different hero or different starting mindset defines a different run-type (Bliss, Defiance-preservation, Broken-tender, etc.).
> - **Currency payout is the run-integral of state richness.** Richness ≈ (state-distribution entropy × mean state magnitude × event-intensity weighting). Rewards varied, intense, sustained activity; resists degenerate single-state grinding and single-peak rushing. Exact formula tunable; the shape is committed.
> - **Tentacle loadout per run.** Player selects a set of authored `TentacleType` resources before the encounter from an unlock pool. Loadout drives encounter variation. Details in `Gameplay_Mechanics.md`.
> - **Hidden-phenomenon achievements as currency bonus and unlock path.** Rare emergent physics events (rib resonance, through-path success, course-correction save, etc.) trigger one-off recognition. Details in `Gameplay_Mechanics.md`.
> - **Sensitivity map discovery.** Hero's authored per-body-area sensitivity map is hidden at new-game; discovered through play as a soft persistent progression. Details in `Gameplay_Mechanics.md`.

#### "Infrastructure needed now" — Extend

Append to the bullet list:

> - `PhenomenonAchieved` bus event (see `TentacleTech_Architecture.md §8.1`)
> - `PhenomenonDetector` component and `PhenomenonAchievement` resource type (see `Gameplay_Mechanics.md`)
> - Save fields for discovered sensitivity map regions and unlocked phenomenon achievements (see `Save_Persistence.md`)

#### "Explicitly deferred" — Keep

No change.

---

## New files to create

### Gameplay_Mechanics.md

Path: project root.

````markdown
# Gameplay Mechanics — Skill Surface, Achievements, Discovery

Companion to `Gameplay_Loop.md`. That doc defines the core loop (objective + payout + persistence). This doc defines what the player *does* moment-to-moment, what they get good at, and what keeps runs from feeling identical.

Scope: game-layer systems that sit on top of the four extensions. No new extension is introduced; everything here consumes existing TentacleTech, Reverie, Tenticles, and Marionette interfaces.

Numeric values are starting points, tunable with playtest.

---

## 1. Skill mechanics

Physics already produces these moments. Making them legible and aimable turns emergence into something the player can get good at.

### 1.1 Grip-break timing

Scenarios 2 and 4 produce snap release from accumulated static friction at the orifice ring. Cue the player on grip engagement state via:
- Hero vocal timbre shift (Reverie vocal output tagged `grip_holding`).
- Ring-shader parameter (subtle color / sheen pulse at high `grip_engagement`).

Reward well-timed withdrawals (axial velocity peak aligned with peak grip): larger `Ecstatic` spike, distinct Reverie vocal line (`snap_release_vocal`), minor mindset drift toward `Blissful + Yielding`.

Mistimed (withdraw at low grip, or withdraw sluggishly through peak grip): dull release, minor mindset drag toward `Dulled`.

No UI meter. Player reads the hero's body.

### 1.2 Rib-resonance tuning

Scenario 8 exists physically. A ribbed tentacle pumping near the orifice ring's natural frequency produces resonance and amplified reaction.

Cues the player can read:
- Visible ring bone pulsing (existing spring-damper output, §6.4).
- Hero vocal rhythm entrainment (Reverie vocal output rhythm tied to ring oscillation phase).

Reward sustained resonance (e.g., ring amplitude > threshold for 2+ seconds): `PhenomenonAchieved(RibResonance, magnitude)` event, currency bonus, `Ecstatic` spike, optional vocal unlock for this tentacle type.

### 1.3 Angle / wedge reading

Scenario 3 already punishes oblique approaches with wedge lock and permanent angular damage.

No UI angle indicator. Feedback comes from:
- Physical stuck behavior.
- Asymmetric pressure on ring bones (visible skin deformation).
- Reverie reaction (mildly painful, not pleasurable).

A skilled player learns to read approach geometry and clears harder orifices faster. No dedicated mechanic — this is raw physics reading.

### 1.4 Overwhelm management

Reverie's `Overwhelmed` state gains with sustained multi-tentacle pressure. Too many active tentacles = fast Overwhelmed accumulation = vocalization and facial collapse to dissociated, mindset drift toward `Dulled`/`Lost` at high rates.

Player skill: balance parallel stimulus (enough for Aroused / Ecstatic to climb) against Overwhelmed saturation.

Release valve: player action `calm_nearest_uncontrolled_tentacle` — the nearest non-controlled tentacle's AI is biased toward Prowl or Recovery preset for 3 seconds. Cooldown 5 seconds. Bound to D-pad (reserved per `Camera_Input.md`).

Does not remove the tentacle; just calms it. Physical contact continues at reduced intensity.

### 1.5 Pain-pleasure threshold

Reverie's `special_conversions` convert some pain events to `Ecstatic` at high `Blissful + Yielding` mindset (see `Reverie_Planning.md §2.3`).

In a narrow mindset band, the player can intentionally use higher-intensity actions (Forced Stretch preset, larger-girth tentacles, faster thrust) that would normally be net-negative. Crossing into `In-pain` / `Overwhelmed` drops the bonus and nets a loss.

No UI. Reverie vocalization and facial state are the indicator. Skill: stay near the conversion edge without crossing.

---

## 2. Hidden phenomenon achievements

Rare emergent physical events get tagged as one-off recognitions.

### 2.1 `PhenomenonAchievement` resource

```gdscript
class_name PhenomenonAchievement extends Resource

@export var id: StringName              # stable identifier
@export var display_name: String
@export var description: String
@export var currency_bonus: int
@export var unlock_on_first: Array      # array of unlock ids (presets, voice lines, shader variants)
@export var repeatable: bool = false    # if true, bonus on every hit; otherwise first-time only
```

### 2.2 `PhenomenonDetector` component

GDScript node attached to the hero or encounter scene. Subscribes to the StimulusBus and inspects state each tick. When detection logic matches, emits `PhenomenonAchieved` with the matching achievement id.

Each achievement has a detection function (GDScript, per-achievement). Examples below.

### 2.3 Starter achievement set

| id | Detection | First-time unlocks |
|---|---|---|
| `RibResonance` | Ring amplitude (any direction) exceeds 2× baseline for ≥ 2s while tentacle in Pumping preset | Ribbed-tentacle shader variant |
| `ThroughPath` | `EntryInteraction` forms a downstream link (§6.7), tentacle tip exits via the downstream orifice | Through-path vocal set |
| `CourseCorrection` | Scenario-10 sequence: target orifice T, actual engaged N, scorer updates target within 2s, penetration in N persists ≥ 5s | "Adaptive" AI preset variant |
| `BulbRetentionSnap` | `GripBroke` event with ring radial velocity > threshold while tentacle is bulbed | Bulb-tentacle shader glow variant |
| `TripleOccupancy` | Three active `EntryInteraction`s on one orifice for ≥ 1s | "Crowded" reaction profile |
| `CleanDeposit` | `PayloadDeposited` on first tip-past-threshold without Scenario-1 slip | Ovipositor calibration variant |
| `CleanExpulsion` | `PayloadExpelled` with `peak_ring_stretch` < `damage_threshold × 0.8` | Smooth-birthing vocal set |
| `PainToEcstatic` | `special_conversion` fires in Reverie with net `Ecstatic` gain > threshold | Transcendence shader mode |
| `Resonance Cascade` | Two simultaneous `PhenomenonAchieved` events within 1s window | High-bonus currency, no further unlock |

Achievements unlocked persist in save (see `Save_Persistence.md`).

Designers add achievements as `.tres` resources. Zero code to add new ones; only existing achievements whose detection needs new logic require code.

### 2.4 Feedback

On detection: non-diegetic sound cue (light, not celebratory), subtle bloom on the screen edge, entry in a run-summary panel at run end. No mid-run popup.

---

## 3. Sensitivity map discovery

Each hero has an authored `per-body-area sensitivity` map (`OrificeProfile.linked_body_areas` + `body_area_sensitivity[area_id]`, §8.3-8.4). At new-game, the map is hidden from the player.

### 3.1 Discovery mechanic

A body area is *discovered* when it accumulates enough stimulus over the save's lifetime: threshold = `discovery_stim_threshold` (scalar), per-area, measured as integrated `body_area_friction + body_area_pressure × press_to_stim_ratio`. When threshold is crossed, the area is marked discovered in save state.

Once discovered:
- The area shows subtly in an optional "anatomy view" debug overlay (if the player turns it on in settings).
- Reverie's reaction intensity at that area is slightly boosted (narrative: "she remembers you found this spot") via a `discovery_familiarity_mult` fed back into `body_area_sensitivity`. Small multiplier (1.1–1.2), capped; not game-breaking.

Not discovered: map entry not revealed; physics still reads the authored sensitivity (sensitivity isn't zero until discovered — it's just that the player doesn't *know*).

### 3.2 Save integration

Save schema gains (see `Save_Persistence.md` update below):

```
sensitivity_discovery: {
    <hero_id>: {
        discovered_areas: [area_id, ...]
        stim_accumulator: {area_id -> float}
    }
}
```

### 3.3 Presentation

No inventory, no unlock screen. Discovery surfaces only through vocal/facial response getting subtly richer over time at discovered areas. Player who never opens the debug overlay still benefits; the overlay is a consolation for players who want legibility.

---

## 4. Tentacle loadout

### 4.1 Unlock pool

At new-game, the player has access to a small pool of `TentacleType` resources (authored; typically 3–5). Additional types unlock via:
- Phenomenon achievements (§2.3 `unlock_on_first` list).
- Mindset milestones (e.g., `Blissful` > +0.5 → unlock `TentacleType_Tender`).
- Currency purchase (a small portion of currency sink at run end; exact cost TBD).

Unlocks persist in save.

### 4.2 Pre-run selection

Before each run, the player picks a loadout of `N` tentacle types (N = 3–6, tunable; may scale with run structure once encounter design lands).

Selection UI: simple grid of unlocked types, drag-and-drop into N slots. Defer detailed UI until encounter design. Minimum viable: a debug menu.

### 4.3 Encounter spawn

TentacleTech spawns the loadout as the active tentacle set for the encounter. Spawn positions, anchor geometry, and AI scenarios are encounter-driven (deferred with encounter design).

### 4.4 Save integration

Save schema gains (see `Save_Persistence.md` update below):

```
loadout: {
    unlocked_tentacle_types: [type_id, ...]
    current_loadout: [type_id, ...]
}
```

---

## 5. Integration points

| Mechanic | Reads from | Writes to |
|---|---|---|
| Grip-break timing | Reverie vocal tag, ring shader param | Player feedback only |
| Rib resonance | Ring amplitude, preset id | `PhenomenonAchieved` event |
| Angle/wedge | Physics feedback (pressure, stuck state) | — |
| Overwhelm management | Reverie `Overwhelmed` state | Tentacle scorer bias (temporary) |
| Pain-pleasure threshold | Reverie `special_conversions` | — |
| Achievements | Bus events, continuous channels, scorer output | `PhenomenonAchieved`, save |
| Sensitivity discovery | Continuous body-area channels | Save, `body_area_sensitivity` mult |
| Loadout | Save | TentacleTech encounter spawn |

Nothing here touches physics code. All detection, aggregation, and feedback runs in GDScript on top of the bus.

---

## 6. Phase placement

- **Bus-consumer infrastructure** (PhenomenonDetector skeleton, achievement resource type) lands whenever encounter design starts to materialize — not before.
- **Skill mechanics** rely only on cues already specced for Reverie output. Ship them as Reverie reaction profiles mature (Phase R3 onward).
- **Sensitivity discovery** piggybacks on body-area stim accumulation already in §8.4.
- **Loadout** needs only a debug menu until encounter design demands real UI.

The whole doc is build-once-thin, fill-in-as-systems-come-online. No phase of its own.

---

## 7. Explicitly deferred

- Encounter design (when tentacles spawn, where, in what environments).
- Exact run-pacing and length.
- Detailed UI for loadout, achievements, mindset feedback.
- Tutorial / first-run experience.
- Multiplayer / observer-mode framing.
- Non-hero-character customization (single hero per `Appearance.md`).

Covered by `Gameplay_Loop.md`'s own deferred list; repeated here for local reference.
````

---

## Save schema additions

Append to `Save_Persistence.md` under the "Persistent across runs" block:

> - Discovered sensitivity-map areas per hero and stim accumulator (see `Gameplay_Mechanics.md §3`)
> - Unlocked `TentacleType`s and current loadout (see `Gameplay_Mechanics.md §4`)
> - Unlocked phenomenon achievements (see `Gameplay_Mechanics.md §2`)

Append to the top-level save example:

```
sensitivity_discovery: { <hero_id>: { discovered_areas: [...], stim_accumulator: {...} } }
loadout: { unlocked_tentacle_types: [...], current_loadout: [...] }
achievements: { unlocked: [<id>, ...] }
```

---

## Explicit supersessions (watch for stale references)

When applying this update, the following parts of prior docs are **replaced, not supplemented**:

1. **Sphere bulger uniform** (`vec4 bulgers[64]`) — replaced by capsule arrays in §7.1. Any shader code paths referencing `bulgers[i].w` as radius with `bulgers[i].xyz` as single point need updating to the two-array segment-distance form. Sphere bulger call sites (external contacts) now emit with `A == B`.

2. **"Separate internal anatomy meshes" / "cavity `MeshInstance3D` per organ"** — this framing was discussed during design but not committed to any doc. The canonical model is a single continuous invaginated shell with multi-surface materials (§10.4). If any stale design doc, scratch note, or CLAUDE.md still suggests separate cavity meshes, update it to match.

3. **`PhysicalBone3D` + cone-twist chain as implementation for excreted tentacles** — this was briefly considered in conversation. The canonical model is a TentacleTech `Tentacle` with the "Free Float" scenario preset (A4 update). Do not add `PhysicalBone3D` code paths for excreted tentacles.

4. **Bulger sphere cost note** ("64 × 15k = 960k distance ops") — retained number-wise because segment distance is cheap, but the *nature* of the work changed from point-distance to segment-distance. Update any cost commentary accordingly.

---

## Not included in this update (filed for later)

Deliberately excluded; do not apply:

- Encounter spawn logic, environmental anchor points for tentacles.
- Ovipositor payload-source design (infinite, refillable, environmental).
- UI for mindset feedback, loadout selection, achievement gallery.
- Cloth / hair simulation on hero (still out of scope per `Appearance.md`).
- Tenticles-side fluid simulation for ejaculation / birthing fluids (still Phase 7+ in `Tenticles_design.md`).
- Branching-tunnel support (single-chain tunnels per orifice are sufficient for v1).
- Non-hero characters with TentacleTech orifice systems.
- Observer avatars, player-visible NPCs.

Revisit after Phase 8 (multi-tentacle + through-path + storage + oviposition + x-ray + capsule bulgers) is stable.
