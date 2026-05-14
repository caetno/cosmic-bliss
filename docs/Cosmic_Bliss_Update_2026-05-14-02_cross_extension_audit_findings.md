# Cosmic Bliss — Design Update 2026-05-14-02 — Cross-extension audit findings

> **Status: drafted 2026-05-14.** Captures findings from a critical-
> analysis audit run on 2026-05-14 across the three active extensions
> (TentacleTech, body_field, Marionette) and the canonical architecture
> docs. The body_field-side findings are mostly closed (PR #6 landed
> 05-13 / 05-14 / project CLAUDE.md optionality rule; PR #8 rewrote the
> body_field supervisor brief; PR #9 applied the 05-14 pass to
> `docs/architecture/TentacleTech_Architecture.md` §4.2 / §4.5 / §10.5).
> Marionette and TentacleTech findings remain open and are handed off
> to those supervisors via short inbox nudges that point at this doc.
>
> Severity legend used throughout:
>
> - **BLOCKER** — design is wrong and will fail at the next slice that
>   touches it. Must land a fix before that slice opens.
> - **SHARP** — real defect or spec drift that will cost time/quality
>   the moment the affected area is touched. Schedule explicitly.
> - **LATENT** — known correctness or perf wart that hasn't bitten yet.
>   Fire-and-forget priority.
>
> **Audience: top-level Claude (canonical record). Per-extension
> supervisors read the relevant section + 05-14 §7 apply-pass items.**

---

## TL;DR

The audit ran three parallel explorer agents (TentacleTech, body_field,
Marionette) under critical-analysis prompts, then synthesized at
top-level. Total findings: 2 BLOCKER + 18 SHARP + 17 LATENT + 7
tensions. As of this writing:

| Extension | BLOCKER | SHARP | LATENT | Tensions | Status |
|---|---|---|---|---|---|
| body_field | 2 | 6 | 3 | 3 | **closed** (PRs #6 / #8) |
| TentacleTech | 2 | 6 | 6 | 3 | 2 BLOCKERs closed by PR #6's 05-14 brief + PR #9; rest open for TT supervisor |
| Marionette | 0 | 6 | 8 | 1 | open for Marionette supervisor |
| Cross-cutting | — | — | — | 3 | partially closed by PR #9's §4.5 rewrite |

Two cross-cutting themes drive most of the open work:

1. **Snapshot discipline bifurcated** — TT effectively retired the
   literal §4.5 ragdoll snapshot in favor of per-substep `get_rest_info`
   (codified in PR #9); but `jiggle_bone.gd:66, 71` and
   `marionette_bone.cpp:246` still read live transforms inside
   `_integrate_forces` callbacks, which is exactly what the discipline
   forbids under Jolt's parallel-tick partial-write hazard.
2. **`body_rhythm_phase` has no publisher** — three downstream
   consumers wait (TT `RhythmSyncedProbe`, Sonance, Visage); Marionette
   spec disagrees with itself on integrator ownership (P7.10.2 vs
   P10.10). Decide owner, implement publish, unblock consumers.

---

## 1. body_field — closed (record only)

Findings closed by the merged PRs are listed here for the audit record.
No action items remain for body_field at this writing.

### Closed BLOCKERs

| ID | Issue | Closure |
|---|---|---|
| BF-1 | Two-doc reconciliation gap: 05-13 awaiting apply pass; 05-12-02 still authoritative; `extensions/body_field/CLAUDE.md` reading order pointed at the wrong doc | PR #6 landed 05-14 (consolidated stack); PR #8 added status banners to 05-12-02 + 05-13 |
| BF-2 | Supervisor `CLAUDE.md` described a fictional XPBD v1 — in-scope list, non-negotiables, jiggle integration all v1.5+ | PR #8 rewrote `extensions/body_field/CLAUDE.md` against the merged 05-12-02 + 05-13 + 05-14 stack |

### Closed SHARP

| ID | Issue | Closure |
|---|---|---|
| BF-S1 | `.bin` v2 has no slot for tet skin weights that v1 kinematic-only requires; silent extension risk | 05-14 §6 bumped to v3; `tet_skin_indices` / `tet_skin_weights` slotted; reader rejects v != 3 |
| BF-S2 | `.bin` format ownership: writer at `~/desktop/blender-addon-tetmesh/`, reader in repo, spec drift risk | 05-14 §6 vendoring rule: Blender authoring chain ships into `tools/blender/body_field/` at B4 |
| BF-S3 | Boundary tet vert coincidence rule asserted but not authored; FloatTetwild doesn't preserve input verts by default | 05-14 §3.1 + §6 explicitly require boundary inheritance; B4 authoring chain documents the FloatTetwild boundary-preservation strategy |
| BF-S4 | Extremities region-tag scheme doesn't exist (no symmetric CUSTOM0 channel like canal interior has) | 05-13 §"Extremities mask" + 05-14 §3 specify the B4 authoring tag; pending implementation but no spec gap |
| BF-S5 | Per-particle region dispatch ownership unclear (Marionette/body_field/TT three-way coupling) | 05-14 §3 collapses dispatch into layer partition; no per-bone enum, no shared resource needed |
| BF-S6 | Stale §15 jiggle composition references in supervisor brief | PR #8 rewrote supervisor CLAUDE.md against the merged stack |

### Closed LATENT

| ID | Issue | Closure |
|---|---|---|
| BF-L1 | D4 BoneCollisionProfile → GPU SDF converter strands cross-extension consumer expectations when deferred to v1.5 | 05-14 §4 fallback table makes the deferral explicit; consumer expectations stay queued until v1.5 |
| BF-L2 | `render_influence` dead field in v1 contradicts "only painting surface" framing | 05-14 §6 + PR #8 reframe: artist doesn't paint it in v1 |
| BF-L3 | v1.5 "purely additive over v1" partially false (render-mesh ownership flips when surface_transfer ships) | 05-14 / PR #8 acknowledge: render-mesh-parallel invariant is v1-only; v1.5 changes that |

---

## 2. TentacleTech — partially open

### Closed by PR #6's 05-14 brief + PR #9

| ID | Issue | Closure |
|---|---|---|
| TT-B1 | 05-13 "per-particle per-region dispatch as single integer compare" wasn't implementable against `get_rest_info` probe | 05-14 §3.1 layer-partition + PR #9 §4.2 rewrite |
| TT-B2 | Friction reciprocal against single tet body RID is no-op for ragdoll motion | 05-14 §3.2 `BodyField::receive_external_impulse` + PR #9 §4.2 routing paragraph |
| TT-S2 | §4.2 type-1 row stale w.r.t. 05-13 | PR #9 §4.2 rewrite |
| TT-S4 | §4.5 ragdoll-snapshot rule silently retired in code but still canonical in spec | PR #9 §4.5 retitle + rewrite |
| TT-L6 | `_apply_contact_persistence_to_probe_results` re-reads `body_node->get_global_transform()` per substep — clarify "once per substep" vs "once per tick" | PR #9 §4.5 explicitly states "once per substep, not per PBD iteration" — confirms current code is compliant |

### Open — for TT supervisor

#### SHARP

- **TT-S1 `CUSTOM0` channel semantics are double-claimed.**
  `TentacleTech_Architecture.md:1379` says `CUSTOM0.r = canal_id + 1`
  (the §6.12 convention used by `canal_auto_baker.gd:253`).
  `TentacleTech_Architecture.md:2046–2047` says `CUSTOM0.x = Feature ID`
  and `CUSTOM0.y = Canal interior flag` (the §10.2 convention used by
  `bake_context.gd:28–31, 47`). No code conflict today because the
  tentacle mesh and hero mesh are different `ArrayMesh` objects, but
  the §10.2 table at line 2047 is stale (pre-2026-05-04 model).
  Reconcile before body_field B4 lands the extremities-mask authoring
  tooling on the same hero mesh (which would also consume a CUSTOM0
  channel).
- **TT-S3 §10.5 contact suppression is unimplemented.** Grep on
  `extensions/tentacletech/` returns zero hits for
  `capsule_suppression|suppressed_bones|OrificeProfile.manual_suppressed_bones`.
  PR #9's §10.5 rewrite reframed suppression as per-path dispatch, but
  the underlying mechanism still isn't shipped. Lands at B5 or earlier.
- **TT-S5 4Q-fix tension taper reads single per-tentacle
  `friction_static`.** `pbd_solver.cpp:276` per `PHASE_LOG.md:301`
  divergence (e) — under per-region material composition via 4S.3
  surface tags (05-14 §3.3), different chain particles will have
  different composed μ. The taper using one μ across the chain will
  under/over-fire on the proxy side. Reshape to read per-slot composed
  μ when per-region material composition lands.
- **TT-S6 `OrificeBusy` boolean reject violates soft-physics rule.**
  `TentacleTech_Architecture.md:1668`. Cap-3 enforcement deferred 4× per
  `PHASE_LOG.md:331, 377, 399, 419`. Now is the time to retire the
  boolean and replace with area-conservation force scaling with active
  count, before it ships. Project CLAUDE.md §"Soft physics over
  scripted levers" rule.
- **TT-7.10 apply-pass** — `extensions/tentacletech/CLAUDE.md`
  per-region dispatch table revision per 05-14 §7.10. Replace 05-13
  dispatch table with: "TT particles probe against
  `LAYER_BODY_PROXY | LAYER_BODY_CAPSULES_DETAIL | LAYER_BODY_CAPSULES_FULL | LAYER_WORLD`
  unconditionally. body_field's tet body, when present, occupies
  `_PROXY`. `BoneCollisionProfile` capsules populate `_DETAIL`
  (hands/feet only) when body_field is present, or `_FULL` (full
  skeleton) when body_field is absent. No per-particle dispatch table."

#### LATENT

- **TT-L1 `RhythmSyncedProbe` doesn't exist yet** (deferred 4× per
  `PHASE_LOG.md`). References in `extensions/tentacletech/CLAUDE.md:35,
  128` + §6.11 are aspirational. When it lands, must read
  `Marionette.body_rhythm_phase` via NodePath, never integrate (project
  CLAUDE.md cross-extension rule #3). Note: Marionette doesn't publish
  phase yet either — coordinate. See cross-cutting §4.2 below.
- **TT-L2 `Canal.is_inactive()` hard-pinned `true`** (`PHASE_LOG.md:619`
  divergence (a)). Production callers wiring `Canal.tick(dt)` drive
  nothing. Anything in 5G/5F.B that assumes the gate flips will be a
  surprise.
- **TT-L3 5F.A canal centerline solver is a *separate* PBD
  implementation**, not a reuse of `PBDSolver` (`PHASE_LOG.md:567`).
  Doesn't inherit 4S.2 body-local cache, 4R RID warm-start, or 4S.3
  per-slot material composition. When 5F.B.C type-3 collision lands,
  stability machinery has to be rebuilt or inherited.
- **TT-L4 `canal_gizmo_overlay.gd:79, 313` rebuilds `ImmediateMesh` per
  `_process`.** Project CLAUDE.md "Never" rule names `ArrayMesh`, not
  `ImmediateMesh` — either tighten the rule or carve out debug
  overlays. Cosmetic today (one canal × 12 particles); revisit if many
  active canals.
- **TT-L5 5C-C wedge math approximates per-rim-particle arc-length
  offset as zero** (`orifice.cpp:~1762`, `PHASE_LOG.md:397` divergence
  (c)). Deferred to Phase 8. Composes with body_field surface contact
  at the orifice rim when 5G/5F.B.C land — third-law loop leakage.

#### Tensions

- **TT-T1** v1 ships with no XPBD softbody; soft-region wobble is
  Marionette §15 jiggle on render-mesh additive offset + body_field
  tighter-collision-surface. Acceptable per 05-13 visible-quality bar;
  flag in B6 acceptance.
- **TT-T2** 5G `muscle[s,θ]` field's only listed consumer is Reverie
  which doesn't exist yet. Write the 5G test fixture as a *consumer*
  shape Reverie will eventually emit, not as an arbitrary muscle
  texture.
- **TT-T3** The 05-14 brief retains `BoneCollisionProfile` as
  authoritative for hand/foot capsules but B3 (converter) is deferred
  to v1.5. In v1, hand/foot particles route to capsules via Jolt's
  existing per-bone shapes, not via direct TT consumption. There's an
  implicit assumption that `BoneCollisionProfile` already drives
  Jolt-side bone shapes TT's probe sees — confirm at B5 prompt
  drafting.

---

## 3. Marionette — open

### SHARP

- **Mar-I1 §18 plan text describes XPBD v1, but 05-13 v1 is
  kinematic-only.** `docs/marionette/Marionette_plan.md:1561–1567`.
  Apply-pass §7.4.
- **Mar-I2 §15 jiggle composition note contradicts 05-13.**
  `Marionette_plan.md:1168` says jiggle bone poses "feed body_field's
  kinematic_targets compute pass". 05-13 line 230–232 says v1 jiggle
  stays on the render-mesh additive-offset path and does NOT feed the
  tet sim. Apply-pass §7.5.
- **Mar-I3 §18 retitle never landed** (`Marionette_plan.md:1555`).
  05-12-02 §D6 promised "Volumetric tet substrate (`body_field`
  extension)" but only the status flip landed. Apply-pass §7.4.
- **Mar-I4 §17 extension-home Q17.3 stale.** Lines 1532, 1549 still
  pose the open question. Decided per 05-12-02 §D7: §17 lives in
  `body_field`. Apply-pass §7.7.
- **Mar-I5 `JiggleBone._integrate_forces` reads live Skeleton3D state
  per tick.** `jiggle_bone.gd:66, 71` calls
  `_skel.get_bone_global_pose(_host_skel_idx)` and reads
  `_skel.global_transform` inside `_integrate_forces`. During Jolt's
  parallel `_integrate_forces` dispatch the bone pose is mid-write by
  `PhysicalBoneSimulator3D`. Fix: snapshot in `_physics_process`, read
  cached value in `_integrate_forces`. The PR #9 §4.5 rewrite codified
  this as a cross-extension rule.
- **Mar-I6 `MarionetteBone::_integrate_forces` reads parent Node3D
  `get_global_transform()` per tick.** `marionette_bone.cpp:246`.
  Comment at line 235 claims the rule is followed for self via
  `p_state->get_transform()`; the parent path circumvents it. Phantom
  damping coupling grows with SPD stiffness. Fix: snapshot all parent
  bases once at start of physics frame via `MarionetteCore` and pass
  via `core_ptr->get_parent_basis_snapshot(this)`.
- **Mar-I8 P10.6 engagement-pump composer math undefined projection.**
  `Marionette_plan.md:841–845` writes `pump_offset_lin × cos(...)`
  directly into `bone_target[b]` which is anatomical (flex/rot/abd);
  `pump_offset_lin` is a world-space vector. Parenthetical "(translated
  into per-bone rotation contribution)" defers the math. The basis
  matters (bone-local? pelvis-anchored?) — define before P10
  implementation.
- **Mar-I9 P10 cost-weight + DLS damping λ underspec.**
  `Marionette_plan.md:832` says "λ = damping (0.01..0.1, scaled by
  goal-error magnitude)" — ambiguous (multiplied? divided?
  saturating?). No Σw normalization in objective. Adding more
  low-weight posture priors monotonically pulls solver away from
  primary goals. Pitfall note at line 920 acknowledges calibration but
  doesn't fix the structural issue.
- **Mar-I14 `body_rhythm_phase` consumer contract has no publisher.**
  See cross-cutting §4.2.

### LATENT

- **Mar-I7 P7.10 phase-overflow `if + fmod` should be `while` + emit
  per cycle** (line 631–634). Single `if` can drop cycle events at low
  fps × high freq. Realistic project params don't trigger it; spec is
  still wrong.
- **Mar-I10 Strength-ramp `set_bone_strength` first-time-override edge
  case can swallow a drop on raise.** `marionette_core.cpp:74–87`.
  Caller-intent-dependent.
- **Mar-I11 `BoneMapAutoFiller` Jaccard 0.6 default drops sided helper
  variants on noisy rigs.** `bone_map_auto_filler.gd:40`. Example:
  ARP `thumb_metacarpal_l` vs `thumb_1_l` → tokens `{thumb, metacarpal}`
  vs `{thumb, 1}` → Jaccard = 0.33 < 0.6 → unmapped. P15.2 structural
  classifier mitigates if it opens.
- **Mar-I12 `_SKIP_SUBSTRINGS "_end"` filter excludes valid leaf-toe
  bones for ARP rigs** (`bone_map_auto_filler.gd:30`). e.g.
  `toe_05_end.l` skipped.
- **Mar-I15 `body_strain` published but no listed Reverie consumer in
  05-09.** Future-Reverie spec gap.
- **Mar-I16 Visage/Sonance jaw target is `jaw_open` scalar but
  composer takes `world_quat`** (05-09 lines 295, 321, 502). Adapter
  layer unspecified.
- **Mar-I18 Anatomical basis re-normalized per tick.**
  `marionette_bone.cpp:130–132`. 3 `sqrt`s × 84 bones × 60 Hz = 15K
  redundant sqrts/sec. Cache normalized columns at build time.
- **Mar-I20 §15 doc contradicts itself on gotcha retirement** —
  `Marionette_plan.md:1195` keeps an "Authoring gotcha (mandatory)"
  that line 1166 says retires post-§17.5. Apply-pass §7.5 resolves:
  the gotcha stays as the no-body_field authoring fallback
  indefinitely.

### Tensions

- **Mar-T1** DQS+DDM stack (05-11) vs §17 weight composition order at
  vertex shader is unspecified across briefs. Latent quality risk on
  visible jiggle / soft-region boundaries.

### Apply-pass items (05-14 §7.4 – §7.7)

| § | Section | Edit |
|---|---|---|
| 7.4 | `Marionette_plan.md` §18 (lines 1555–1591) | Retitle to "Volumetric tet substrate (`body_field` extension)"; rewrite lines 1561–1567 to v1 kinematic-only; phrase body_field references as "when present, ...; when absent, ..." |
| 7.5 | `Marionette_plan.md` §15 (lines ~1168, ~1166, ~1195) | Line 1168: v1 jiggle on render-mesh additive-offset; v1.5+ optionally feeds kinematic_targets *additively*. Resolve I20 contradiction toward keeping the "authoring gotcha (mandatory)" indefinitely. |
| 7.6 | `Marionette_plan.md` §16 (around lines 1213–1357) | Add fallback note: cluster particles compose with body_field tet substrate when present (v2+ B7); standalone cluster solver is the no-body_field path and v1 default. |
| 7.7 | `Marionette_plan.md` §17 (lines ~1532, ~1549) | Mark Q17.3 Resolved (§17 lives in body_field per 05-12-02 §D7). Add fallback note: consumers keep pre-§17 manual-authoring path live as the no-body_field fallback. |

---

## 4. Cross-cutting

### 4.1 Snapshot discipline bifurcation (partially closed)

PR #9's §4.5 rewrite codified the rule: "snapshot once per substep,
not per PBD iteration; never query `Node3D::get_global_transform()`
from inside an `_integrate_forces` callback." Code violations remain
on the Marionette side (Mar-I5 in `jiggle_bone.gd:66, 71` and Mar-I6
in `marionette_bone.cpp:246`).

Project CLAUDE.md "Never" list currently reads "Querying
`PhysicalBone3D.global_transform` during PBD iterations (snapshot once
per tick)". The wording is now slightly out of sync with the more
precise §4.5 rule. **Action**: tighten project CLAUDE.md "Never"
bullet to "Querying `Node3D::get_global_transform()` from inside an
`_integrate_forces` callback or PBD iteration loop — snapshot once per
substep at the substep boundary." Owner: top-level Claude
(`CLAUDE.md` is repo-root scope).

### 4.2 `body_rhythm_phase` publisher gap

Consumer contracts (TT `RhythmSyncedProbe`, Sonance, Visage) all assume
Marionette publishes integrated `body_rhythm_phase` at the cadence
specified in P7.10. **Marionette doesn't publish phase yet.** P7.10
isn't implemented; P7.10.2 (in `Marionette_plan.md` §P7) says
`Marionette` integrates phase in `_physics_process`; P10.10 (in
`Marionette_plan.md` §P10) says `MarionetteComposer` (C++) does. Two
specs disagree on integrator ownership.

**Action sequence:**
1. Decide integrator owner (P7.10 vs P10.10). Single source of truth.
2. Implement the publish (Marionette supervisor session).
3. Unblock TT `RhythmSyncedProbe` (TT-L1) and Sonance
   body-coupling clock and Visage gaze rhythm.

Owner: Marionette supervisor (decision + impl). TT and Sonance/Visage
unblock downstream.

### 4.3 Stranded apply-pass items in this session's authoring history

Worth noting in the audit record so a future audit doesn't re-surface
these as live issues:

- **05-13 brief's §"Two parallel paths" + §"Extremities mask"
  dispatch claims** were superseded by 05-14 §3 and a status banner
  was added (PR #8); the original wording remains in the doc body as
  historical record.
- **05-12-02 brief's full XPBD v1 framing** is superseded by 05-13
  (kinematic-only) and a status banner was added (PR #8). The
  original wording is retained as the v1.5+ reference.
- **PR #7 originally landed the body_field supervisor rewrite but
  merged into a stranded base** (PR #6 had already merged to main; PR
  #7's base never propagated). Recovery shipped as PR #8 via
  cherry-pick. Lesson: GitHub does not auto-retarget stacked PR bases
  on parent merge. Future stacked PRs either wait for parent merge or
  explicitly retarget via `mcp__github__update_pull_request` with
  `base: "main"`.

---

## 5. Recommended priorities

| Priority | Item | Owner | Where |
|---|---|---|---|
| **P0** | `body_rhythm_phase` integrator-owner decision + publish | Marionette supervisor | Mar-I14, cross-cutting §4.2 |
| **P0** | Apply-pass §7.4 – §7.7 (`Marionette_plan.md` §15/§16/§17/§18 wording) | Marionette supervisor | one bundled PR |
| **P0** | Apply-pass §7.10 (`extensions/tentacletech/CLAUDE.md` dispatch table) | TT supervisor | bundle with B5 prompt |
| P1 | Snapshot-discipline code fixes (Mar-I5, Mar-I6) | Marionette supervisor | per-fix slices |
| P1 | Project CLAUDE.md "Never" bullet tightening (cross-cutting §4.1) | top-level Claude | one-line edit |
| P1 | §10.5 contact suppression implementation (TT-S3) | TT supervisor | B5 or earlier |
| P1 | `OrificeBusy` boolean retirement (TT-S6) | TT supervisor | before cap-3 ships |
| P2 | `CUSTOM0` channel reconciliation (TT-S1) | TT supervisor | before body_field B4 |
| P2 | 4Q-fix tension taper per-slot μ (TT-S5) | TT supervisor | when 4S.3 surface-tag composition lands |
| P3 | P10 composer math gaps (Mar-I8, Mar-I9) | Marionette supervisor | before P10 implementation |
| P3 | Anatomical basis caching (Mar-I18) | Marionette supervisor | small perf win |
| P3 | Auto-bone-map filter edges (Mar-I11, Mar-I12) | Marionette supervisor | fire-and-forget |

The two P0 cross-extension items (`body_rhythm_phase` publisher; the
two doc apply passes) unblock the most downstream work. The P1 code
fixes are independent of those.

---

## 6. Apply checklist for top-level Claude

1. ✅ Audit run (three parallel explorers, 2026-05-14).
2. ✅ Synthesis at top-level (this doc captures the findings).
3. ✅ PR #6 landed 05-13 + 05-14 + project CLAUDE.md optionality rule
   (closes BF-1, BF-S1, BF-S2, BF-S5).
4. ✅ PR #8 landed body_field supervisor brief rewrite + 05-12-02 /
   05-13 status banners (closes BF-2, BF-S6).
5. ✅ PR #9 landed TentacleTech_Architecture §4.2 / §4.5 / §10.5
   apply pass (closes TT-B1, TT-B2, TT-S2, TT-S4, TT-L6).
6. **This PR** lands the audit findings doc itself.
7. **Short /handoff to Marionette** pointing at this doc + the four
   §7 apply-pass items.
8. **Short /handoff to TentacleTech** pointing at this doc + the §7.10
   apply-pass item.
9. **One-line edit to project CLAUDE.md "Never" bullet** to tighten
   the snapshot-discipline wording per cross-cutting §4.1.
   Lands in a separate small PR or piggybacks on whichever PR touches
   `CLAUDE.md` next.

---

## Summary

The cross-extension audit run on 2026-05-14 surfaced ~40 findings
across TentacleTech, body_field, and Marionette. The body_field-side
findings are closed by PRs #6 / #8 / #9. The two TentacleTech BLOCKERs
(per-region dispatch unimplementable; friction reciprocal silently
breaks) were closed by 05-14's layer-partition redesign and PR #9's
§4.2 rewrite. The remaining open work splits into two cross-cutting
themes — snapshot discipline (Marionette-side code violations against
the now-explicit cross-extension rule) and the missing
`body_rhythm_phase` publisher (Marionette decision + impl unblocks
three downstream consumers) — plus per-extension apply-pass items
queued for the Marionette and TentacleTech supervisor sessions.
