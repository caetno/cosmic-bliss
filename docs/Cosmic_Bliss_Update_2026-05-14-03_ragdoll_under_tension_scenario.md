# Cosmic Bliss — Design Update 2026-05-14-03 — Ragdoll-under-tension scenario as the next testable target

> **Status: drafted 2026-05-14.** Names "ragdoll with muscle tension
> that tries to hold a pose while constrained and being penetrated"
> as the next acceptance-test target across Marionette + TentacleTech,
> captures the cross-extension readiness verdict against today's
> shipping state, lists the prerequisite slices broken out by
> extension, and amends one architectural decision in
> `docs/architecture/TentacleTech_Architecture.md` §6.12 (the
> canal-interior bend that previously did *not* emit host-bone
> impulses now does, under a new type-3 reaction pass).
>
> Builds on `docs/Cosmic_Bliss_Update_2026-05-14-02_cross_extension_audit_findings.md`
> (the cross-extension audit; this doc consumes its §2 / §3 / §4 / §5
> inventory) and supersedes the architectural decision documented at
> `TentacleTech_Architecture.md:1437` and `:2629`.
>
> **Audience: top-level Claude (canonical record). Marionette and
> TentacleTech supervisors read §3 / §4 (their respective slice
> lists) and §6 (the §6.12 architecture amendment they must
> implement).**

---

## TL;DR

1. **Named target scenario.** The next testable scenario is *a
   ragdoll with muscle tension that tries to hold a pose while
   constrained and being penetrated*. With kasumi as the test
   subject, against three tension settings, with a legible
   "fighting it" telemetry channel.

2. **Readiness verdict: NOT READY today.** The body-side (SPD,
   tension dial, rim transit, force-out at rim) is GREEN; the
   legibility side (`body_strain` channel, stimulus bus), the
   constraint side (`PinAnchor`), the canal-interior side (walls
   + walls-pushing-body), and two snapshot-discipline code bugs
   that bias exactly the high-tension regime are RED or YELLOW.

3. **User-chosen path: expressive-later.** Land all prerequisite
   slices before the test scene gets built. Multi-week, both
   extensions contributing.

4. **One architectural decision flips:** `TentacleTech_Architecture.md`
   §6.12 currently says canal-interior bend does NOT generate host-bone
   impulses (it's an explicit decision). This scenario requires that
   it does. §6 of this doc amends the architecture and defines the
   host-bone resolution rule for the new type-3 reaction pass.

5. **No code changes in this doc.** Top-level deliverables only:
   this update doc, the §6.12 architecture amendment, a tightening
   of project CLAUDE.md's snapshot-discipline "Never" bullet, and
   two `/handoff` nudges. All slice implementation goes to the
   per-extension supervisors.

---

## 1. Scenario specification

The named acceptance test for the next cross-extension milestone:

> **Kasumi-ragdoll holds a pose against gravity, wrists pinned to
> world anchors, while a single TentacleTech tentacle enters her
> orifice, traverses the canal interior, and pushes against the
> canal walls. The player can dial tension low → mid → high; at
> each setting the body visibly fights the tentacle with
> proportional displacement, the `body_strain` telemetry rises
> monotonically, and the stimulus bus emits the expected entry /
> traversal / grip events.**

This scenario is the cross-extension forcing function. It exercises
every body↔tentacle seam at once: SPD vs perturbation, rim closure,
canal-wall closure, host-bone reaction from canal interior, strain
telemetry, bus emission, constraint enforcement. Once it runs
cleanly, Reverie / Sonance / Visage can be wired without further
plumbing work on the physics side.

It is also a test-scene scope expansion: kasumi is a rigged
character, which the project CLAUDE.md "test scenes stay simple"
rule explicitly forbids without a separate explicit ask. This doc
is that ask, recorded in the canonical update log. Scope: this
single named scenario, kasumi as the only rigged subject, no
animation tracks, no side-authored Resource files beyond what
kasumi's existing hero stack already ships with.

---

## 2. Readiness verdict against today's state

Sourced from three sibling-explorer reports (Marionette, TentacleTech,
BodyField) reconciled against
`Cosmic_Bliss_Update_2026-05-14-02_cross_extension_audit_findings.md`.

| Requirement | Today | Reference |
|---|---|---|
| SPD ragdoll with per-bone × global tension dial | **GREEN** | `extensions/marionette/src/marionette_bone.cpp:218-280`; `gdscript/runtime/marionette.gd:800, 812, 831` |
| Target pose tracking | **GREEN** | `Marionette.set_bone_target()` |
| `body_strain` "fighting it" signal | **RED** | P10.7 in `docs/marionette/Marionette_plan.md:825, 851`; zero hits in src |
| First-class constraint / pin (`PinAnchor`) | **RED** | P10.2 specified, unimplemented |
| Orifice rim transit + §6.3 reaction-on-host-bone | **GREEN** | `extensions/tentacletech/src/orifice/orifice.cpp:155-160` |
| Force-out from rim to ragdoll | **GREEN** | `body_apply_impulse` on PhysicalBone3D, propagated via Jolt; SPD tracks against perturbation |
| Force-out from canal interior to ragdoll | **RED-by-design** | `TentacleTech_Architecture.md:1437, 2629` — explicitly says no extra impulse; §6 of this doc amends |
| Canal-interior wall dynamics (5F.B.B + 5F.B.C) | **RED** | `Canal.is_inactive()` pinned `true` (TT-L2 in 05-14-02 audit) |
| Snapshot discipline under high SPD stiffness | **YELLOW** | Mar-I6 at `marionette_bone.cpp:246`; Mar-I5 at `jiggle_bone.gd:66, 71` |
| §10.5 contact suppression | **RED** | TT-S3 unimplemented |
| `OrificeBusy` boolean retirement | **PENDING** | TT-S6 — not yet shipped, retire before ship |
| Stimulus bus event emission | **RED** | `src/stimulus_bus/` empty; Phase 6 blocked |
| `body_rhythm_phase` publisher | **RED** | Mar-I14 / 05-14-02 §4.2 |
| BodyField contact-surface upgrade | **N/A for this scenario** | Capsule fallback is sufficient; BodyField B1+ is its own track |

**Single biggest gap:** the canal-interior side. Walls don't push
back, and even if they did the architecture explicitly says they
wouldn't push the body around. §6 amends that.

**Single biggest legibility gap:** there is no `body_strain` signal
and no bus emission, so even when the physics is right, the
scenario is visually-only — no audio/face/Reverie response possible.

**Single biggest correctness risk:** Mar-I6 biases the high-tension
regime that *headlines* this scenario. Fix before drawing
conclusions.

---

## 3. Marionette slice list

In priority order. Implementation belongs in the Marionette
supervisor session; this list defines the contract.

1. **Mar-I6 snapshot fix** (`marionette_bone.cpp:246`). Snapshot
   parent basis once per substep via `MarionetteCore`; expose
   `core_ptr->get_parent_basis_snapshot(this)` to bones reading
   from inside `_integrate_forces`. Highest priority because the
   bug's amplitude scales with SPD stiffness — biases exactly the
   high-tension regime the scenario tests.

2. **Mar-I5 snapshot fix** (`jiggle_bone.gd:66, 71`). Snapshot in
   `_physics_process`, read cached value in `_integrate_forces`.
   In-scope because the chosen test subject is kasumi and kasumi
   has jiggle bones per `Marionette_plan.md` §15 / 05-11 hero
   skinning stack.

3. **`body_rhythm_phase` integrator-owner decision + publish**
   (Mar-I14, 05-14-02 §4.2). Pick P7.10 vs P10.10 — single source
   of truth — and publish `Marionette.body_rhythm_phase` so future
   consumers (TT `RhythmSyncedProbe`, Sonance, Visage) can
   subscribe. Not strictly required by this scenario, but it's a
   P0 cross-cutting blocker for three other consumers — ride along
   here, not in a separate slice.

4. **Apply-pass §7.4–§7.7** (`Marionette_plan.md` §15/§16/§17/§18
   per 05-14-02 audit table). One bundled doc-only PR.

5. **P10.2 `PinAnchor` minimum slice.** Signature:

   ```
   PinAnchor(bone: StringName, world_pos: Vector3, hard_weight: float = 100.0)
   ```

   A hard pin that the SPD target tracker respects. No IK soup, no
   goal-stack composer — just a per-bone world-space hard anchor
   that biases the SPD target each tick. Used for wrist + ankle
   ties in this scenario. Full P10 composer is deferred to its own
   slice once Reverie comes online.

6. **P10.7 `body_strain` publisher minimum slice.** Single scalar
   per region (or per-bone-aggregated). Acceptable v1 definition:

   ```
   body_strain[region] = clamp( |tracking_error| × strength, 0, 1 )
   ```

   where `tracking_error` is the SPD target-vs-actual quaternion
   distance accumulated over the bones in the region. Published as
   a `Dictionary` on `Marionette` per `Marionette_plan.md` §P7. Stub
   is enough — tighten when Reverie consumes it.

Phase 11 helpers (`apply_hit`, `GrabTarget`) and full P10 composer
(Mar-I8 / Mar-I9 math gaps, P10.6 engagement pump) are explicitly
out of scope for this scenario. They are aimed at the Reverie-era
expressive composition pass, not at body-side correctness under
load.

---

## 4. TentacleTech slice list

In priority order. Implementation belongs in the TT supervisor
session.

1. **Apply-pass §7.10** (`extensions/tentacletech/CLAUDE.md`
   dispatch table) per 05-14-02 audit. Bundle with B5 prompt.

2. **§10.5 contact suppression** (TT-S3). Implement per-bone
   capsule suppression for the bodies/regions in the orifice's
   `suppressed_bones` list at active EI. Without it the rim
   particles double-feel rim closure + outer-body capsule on the
   same anatomical region — visible double-push that will pollute
   the scenario's force readings.

3. **`OrificeBusy` boolean retirement** (TT-S6). Replace with
   area-conservation force scaling against active count. Land
   before cap-3 ever ships — currently not shipped, so the boolean
   has not yet fired in production. This is the right window to
   retire it.

4. **5F.B.B `tunnel_state` texture per-tick CPU integration.**
   Unblocks the rest of the canal-interior pipeline.

5. **5F.B.C type-3 canal-wall contact.** PBD-side: tentacle
   particles project against canal walls; walls deform per §6.12.4
   second-order dynamics; wall-state texture writes back.

6. **New canal-interior → host-bone impulse pass** per the §6.12
   architecture amendment in §6 of this doc. Without this, walls
   push tentacles but tentacles don't push the body back from
   inside the canal — the scenario's "muscle tension fights
   internal penetration" sensation isn't possible.

7. **TT Phase 6 stimulus bus minimum slice.** Emit at least the
   following events:

   - `PenetrationStart(orifice, tentacle, depth_normalized)` at rim entry
   - `RingTransitStart(orifice, tentacle, ring_index)` at each ring loop transit
   - `KnotEngulfed(orifice, tentacle, knot_id)` at girth-differential transit
   - `GripEngaged(orifice, tentacle, grip_strength)` continuous channel while gripped
   - `OrificeDamaged(orifice, rate)` continuous channel for the damage budget

   Per `TentacleTech_Architecture.md:1602-1633`. Stub bus
   acceptable — once it's emitting, Sonance + Reverie can subscribe
   without further TT-side plumbing.

8. **TT-S5 4Q-fix per-slot μ.** Refactor tension taper to read
   composed μ per slot once 4S.3 surface-tag composition is in
   play. Not blocking this scenario, but bundle into the slice
   stack since the surface-tag composition will land during this
   window.

Out of scope: anything BodyField-side; TT-L3 canal-solver
inheritance refactor (deferred until 5F.B.C composes with 4S.2 /
4R machinery); TT-T2 Reverie-shaped 5G test fixture (Reverie
doesn't exist yet).

---

## 5. Cross-cutting work in this session

This update doc is itself one of the deliverables. The others:

### 5.1 Project `CLAUDE.md` "Never" bullet tightened

Per 05-14-02 §4.1. Current:

> Querying `PhysicalBone3D.global_transform` during PBD iterations
> (snapshot once per tick)

New:

> Querying `Node3D::get_global_transform()` from inside an
> `_integrate_forces` callback or PBD iteration loop — snapshot
> once per substep at the substep boundary.

Reason: PR #9's §4.5 rewrite codified per-substep (not per-tick)
discipline, and made the rule about *all* Node3D transform reads
inside `_integrate_forces`, not just `PhysicalBone3D`. The
project-level bullet had drifted behind the architecture-level
rule.

### 5.2 `TentacleTech_Architecture.md` §6.12 amendment

See §6 below — the substantive design change in this doc.

### 5.3 Handoffs

Short nudges appended to `.claude/inbox/marionette.md` and
`.claude/inbox/tentacletech.md` pointing at this doc + the slice
lists in §3 / §4.

---

## 6. Architecture amendment: canal-interior → host-bone impulse pass

### 6.1 The decision being reversed

`TentacleTech_Architecture.md:1437` (in §6.12.10 "Stability and
gotchas") and the duplicate at `:2629` (in §14 gotchas) currently
read:

> Centerline bend produces wall asymmetry but not host-bone
> movement. The §6.3 reaction-on-host-bone closure operates only
> at rim particle loops. A canal interior bend transmits axial
> force to the host body through the CP bone rigging (CP bones
> are rigidly parented to host bones), but does NOT add an extra
> `body_apply_impulse` beyond what the centerline's spring-back
> to CP rest already implies. If gameplay needs canal-interior
> force feedback distinct from the rim's, add it as a separate
> pass — currently not in scope.

This was correct as scoped at the time — until the scenario in
§1 of this doc made it the load-bearing physical sensation. The
"separate pass" the original text reserves for is now scoped.

### 6.2 The new pass

A **canal-interior reaction pass** runs once per substep, after
type-3 canal-wall contact (5F.B.C) has resolved tentacle-particle
penetrations into wall-space deformation, and before bus event
emission. Per substep:

1. For each canal cross-section with non-zero wall displacement
   relative to rest (`max(displacement) > ε` over θ), compute a
   **net wall reaction**:

   ```
   reaction[s] = - Σ_θ ( wall_response_stiffness × displacement[s,θ] × n[s,θ] )
   ```

   where `n[s,θ]` is the rest-pose outward wall normal at
   parametric position `(s, θ)`. The sum is over the 8 (or
   configured) θ samples; the result is a 3-vector in world space
   pointing in the direction the wall would need to be *pushed
   back* to restore rest.

2. Distribute `reaction[s]` to host bones via the canal's CP bone
   rigging (canal interior is skinned to CP bones; CP bones are
   rigidly parented to host bones per §6.12.2):

   ```
   host_bone[s] = CP_bone[s].parent_host_bone
   bone_impulse[host_bone[s]] += reaction[s] × dt
   ```

   Single dominant host bone per cross-section — the CP→host
   parenting is rigid by construction, so there is no skin-weight
   basket here. The decision rule is "CP bone's rigid parent."

3. After all cross-sections accumulate, apply per host bone:

   ```
   PhysicsServer3D.body_apply_impulse(host_bone.body_rid,
                                       Σ(bone_impulse[host_bone]),
                                       application_point)
   ```

   where `application_point` is the world-space midpoint of the
   contributing cross-sections (for a uniformly-pushed canal it is
   the canal centerline midpoint; for asymmetric load it shifts).

### 6.3 Host-bone resolution rule

A canal interior is *not* a free mesh — it is skinned to CP bones
which are rigidly parented to host bones. The skin-weight basket
question that exists for outer-body surfaces (where one vertex
can be partially weighted to multiple bones) does not exist here
by construction. Each canal cross-section has *one* CP bone
controlling its rest position, and that CP bone has *one* rigid
host-bone parent.

The host-bone resolution rule is therefore:

```
canal_cross_section[s].host_bone = canal_cross_section[s].CP_bone.parent
```

Resolved once at `Canal` bake time, cached on the canal resource.
Never resolved per-substep. No basket distribution.

### 6.4 Third-law loop closure with rim

Rim closure (§6.3 reaction-on-host-bone) and canal-interior
reaction must not double-count at the rim transition zone — the
two regions overlap by ~1 ring's worth of axial extent (the rim
sits at the canal's entry plane and the first canal cross-section
sits just inside).

The §10.5 contact suppression machinery already handles this
correctly for the *outer-body capsule* vs *rim* overlap. The
extension here:

- §10.5 suppression masks outer-body capsule hits for particles
  inside the orifice's `suppressed_bones` region.
- The canal-interior reaction pass excludes the first `N_rim`
  cross-sections (configurable per orifice, default `N_rim = 1`)
  from the bone-impulse accumulation. Those cross-sections are
  considered "already covered by §6.3."

The two passes are now disjoint in their host-bone impulse
contribution. The §10.5 suppression list applies to outer-body
capsules; the canal-interior `N_rim` exclusion applies to
canal-wall contributions; rim closure stands alone at the rim.

### 6.5 Stability

The new pass introduces no new dynamics — it is a reaction
*readout* from state that 5F.B.C already integrates. The wall
displacement `displacement[s,θ]` is already computed by §6.12.4
step 2g. The reaction is its negation, scaled, summed, and
dispatched as a per-bone impulse. Per-substep cost: one inner
loop over canal cross-sections × θ samples per active canal,
plus N_active_canals `body_apply_impulse` calls. Bounded by
canal count × ~8 θ samples × per-canal section count
(`~16-32`) — sub-millisecond at gameplay densities.

The stability of the wall integration itself is unchanged
(still gated on `wall_response_rate * dt < 1` per §6.12.10).

### 6.6 Edits to `TentacleTech_Architecture.md`

Applied in this top-level session (architecture docs are top-level
scope per project CLAUDE.md). Three edits:

- **§6.12.10**, replace the bullet at `:1437` ("Centerline bend
  produces wall asymmetry but not host-bone movement.") with a
  short pointer to the new §6.12.12.
- **§6.12** new subsection `§6.12.12 Canal-interior reaction
  pass` containing the design from §6.2–§6.5 of this doc.
- **§14 gotchas**, replace the bullet at `:2629` ("Canal
  centerline bend does not move host bones.") with the new
  behavior summary plus the `N_rim` calibration note.

Code-side implementation (the actual reaction-pass pass in TT's
substep loop) is slice (6) in §4 and is owned by the TT
supervisor.

---

## 7. Verification

This update doc is the top-level deliverable. Acceptance:

- Doc lands and cross-references the 05-14-02 audit entries it
  consumes (TT-S3, TT-S6, TT-L2, Mar-I5, Mar-I6, Mar-I14,
  apply-pass §7.4–§7.7, §7.10, cross-cutting §4.1 + §4.2).
- Marionette inbox and TentacleTech inbox each have a fresh
  dated nudge pointing here + their slice list.
- Project `CLAUDE.md` "Never" bullet is the new tightened wording.
- Per §6.6, the `TentacleTech_Architecture.md` §6.12 amendment
  is applied in this session (architecture docs are top-level
  scope). The binding spec is §6.2–§6.5; the three concrete
  edits are listed at §6.6.

Downstream verification (multi-week, in per-extension sessions):

- Marionette slices (1) through (6) of §3 ship behind their own
  PRs. Mar-I6 first (gates everything else).
- TT slices (1) through (8) of §4 ship behind their own PRs.
  §7.10 first (apply-pass), then suppression + retirement, then
  the canal-interior stack in (4) → (5) → (6) sequence, then bus.
- Test scene gets stood up in a later session once the slices
  land, using kasumi per §1, against three tension settings, with
  `body_strain` HUD overlay and bus event log.

## 8. Out of scope

- Reverie / Sonance / Visage consumer wiring (downstream of bus +
  strain publisher; separate planning session once those land).
- BodyField B1+ promotion (capsule fallback is sufficient for this
  scenario; BodyField stays in v1 kinematic-only B0 state).
- Phase 11 helpers (`apply_hit`, `GrabTarget`); deferred to Reverie
  era.
- Full P10 composer (Mar-I8 / Mar-I9 / P10.6 engagement pump);
  deferred to Reverie era.
- The test scene file itself — separate explicit ask in a later
  session, scoped to this single scenario per the kasumi-rigged
  permission granted in §1.
