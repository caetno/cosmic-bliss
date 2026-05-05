# Current State

Snapshot — moves frequently. When in doubt cross-check against `extensions/<extension>/CLAUDE.md` files in the repo for the live state.

## TentacleTech

**Phases 1–5 done; Phase 5H landed 2026-05-05.**

What's stable:
- PBD chain (XPBD, Jacobi-with-atomic-deltas-and-SOR, per-segment + per-contact lambda accumulators)
- 7 collision types of which type-1 (env), type-2 (rim), type-4 (chain self-collision) are implemented end-to-end with feature silhouette
- Orifice rim particle loop with anisotropic distance, J-curve, plastic memory, host-bone soft attachment
- EntryInteraction lifecycle + geometric tracking + grip ramp + damage + §6.3 reaction-on-host-bone closure
- Feature silhouette baking + sampling integrated into type-1/2/4 contact thresholds
- TentacleMesh authoring with feature modifiers (Knots, Ribs, WartClusters, SuckerRows, Spines, Ribbons, Fins)

**Active investigation: wedge contact stability under PBD↔ragdoll coupling.**

User-reported failure: tentacle pinched between Kasumi's leg ragdoll bones jitters visibly in the editor; jitter increases strongly with `tentacle_lubricity`. Up to 3 contact gizmos flickering per particle in real-time but a screenshot shows only 1 (gizmo redraw stutter #71979 explains the screenshot side; the real-time flicker is real contact-set churn).

Diagnosis (current understanding):
- The static-collider repro under-reads the failure — under static walls the lubricity dependence is mild
- The user's actual scene has **moving ragdoll colliders** (legs, pelvic floor) with joint angular springs, so the per-tick `body_apply_impulse` reciprocal moves the collider, the next PBD tick re-probes against the moved bone, and a coupled oscillation emerges
- High lubricity = chain slides freely → reciprocal impulse direction flips per tick → bone wobbles → contact churns
- Low friction = chain pinned → impulse is a steady push → bone deflects to a steady equilibrium → contact stable

Fix landscape under design (slice naming **4Q** — re-opens Phase 4 close-out work):
- **Substep default flip** 1×4 → 4×1 (Obi convention) — biggest single intervention; lets ragdoll physics interleave inside the PBD outer dt
- **Contact-point persistence in body-local space** — anchor the contact to the body, only re-probe when drift exceeds a hysteresis radius
- **RID-keyed lambda warm-start** — preserve per-contact lambdas across ticks for stable contact pairs
- **`MAX_CONTACTS_PER_PARTICLE` 2 → 3** — needed for orifice rim wedges in Phase 5; also Kasumi between-leg case (2 thighs + pelvic floor; potential +2 glutes; future +3 orifice ring bones)
- **Decouple `support_in_contact` from slot 0** — depth-weighted sum of all active contact normals so single-slot flips don't reverse gravity projection

Sub-Claude is in diagnostic round 2 with a coupled-body geometry (`RigidBody3D` + `Generic6DOFJoint3D` substituted for `PhysicalBone3D` for headless reproducibility).

**Next gate: canal interior model (slices 5E + 5F + 5G).**

`docs/Cosmic_Bliss_Update_2026-05-04_canal_interior_model.md` is the amendment doc; the architecture-doc apply pass is queued. After 4Q closes, 5E (canal infrastructure) opens; 5F (texture dynamics + bilateral split) consumes feature silhouette from day one; 5G (muscle activation field).

**Phase 6+ blocked.**

Stimulus bus (Phase 6, includes `OrificeDamaged` channel + `GripBroke` event + slime system implementation), bulgers + capsules + x-ray (Phase 7), multi-tentacle / advanced scenarios (Phase 8), polish (Phase 9) all blocked on Phase 5 closure.

## Marionette

Active across multiple sub-phases. Recent landings:
- SPD per-joint controller
- Cost-weighted IK composer
- BoneProfile + BoneCollisionProfile resources
- Calibrate action — refreshes live `MarionetteBone` masses
- Anatomical mass_fraction defaults seeded by Calibrate
- Re-Calibrate refreshes live mass values without restart
- Collider wireframes via permanent `MeshInstance3D` children of bones
- Jiggle bones — first cut (breast only on Kasumi's rig); translation-only SPD with mass-portable kp/kd; `BoneCollisionProfile.non_cascade_bones` drives spawn

Open questions (user's auto-memory):
- BoneProfile facing axis convention (per-rig calibration signal — yellow-tripod gizmo)
- Hips bone semantics (hip vs. waist)
- Proximal phalanges defaults

## Tenticles

Paused. Scoped self-contained — does not subscribe to the Stimulus Bus directly. Future GPU particle work for slime / fluid / smoke. Not on the critical path; will resume after TentacleTech Phase 6+.

## Reverie

Not started. Interface contract defined in `docs/architecture/Reverie_Planning.md` so TentacleTech's emission format doesn't lock the future implementation out.

## Recent commits (top)

- `83ba3dd` TentacleTech: phase 4 slice 4K — gravity supported by contact
- `431e51e` Marionette: collider wireframes via permanent MeshInstance3D children
- `9bb5104` TentacleTech: phase 4 slice 4J — final collision cleanup pass
- `7240982` Marionette: re-Calibrate refreshes live MarionetteBone masses
- `a8ad902` Marionette: anatomical mass_fraction defaults seeded by Calibrate

Recent uncommitted changes include Phase 5 5C-C / 5D / 5H landing.

## Open design questions worth a conversation

- Whether to flip `substep_count` default to 4 globally or per-mood (currently leaning global, with mood overrides)
- Whether canals warrant a separate `Cavity` primitive for sacs (uterus, stomach), or stay with `closed_terminal` Canal — currently the latter
- Per-rim-particle arc-length offset in the §6.3 wedge math (currently approximated as zero) — Phase 8 follow-up
- Multi-tentacle cap-3 per orifice — defined in spec, not enforced in code yet
- Twist tracking for the feature silhouette body-frame — features rotate with the chain rather than staying anatomically anchored under roll
- BoneProfile rig-specific defaults the user accepted but may revisit
- Dynamic girth-scale-aware silhouette evolution — silhouette is currently static per tentacle; should warts smooth out under high stretch?
- Spine direction signal for anisotropic friction — spines record `spine_tip_normal` only; friction modulation deferred
- Mask-only fragment features (Papillae, Photophore) — extension points left in place but not wired; would need a careful GTX 970 budget pass

These are good topics if you bring them up, but no decisions yet.
