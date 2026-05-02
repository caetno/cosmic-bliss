# Cosmic Bliss — Design Update 2026-05-02 — Phase 4 friction correction

> **Status: applied 2026-05-02.** Top-level review of the friction-projection
> implementation passed; the §4.3 spec text in `docs/architecture/TentacleTech_Architecture.md`
> was edited to match the corrected pseudocode plus three review-requested
> additions (explicit Δn → N mapping, per-iteration semantics caveat with
> forward-reference to the deferred per-tick budget, and `kinetic_friction_ratio`
> default + configurability note). This doc remains as changelog.

**Audience: Repo organizer Claude (top-level review).**

This update flags a bug in `TentacleTech_Architecture.md §4.3 Unified PBD friction projection` that the per-extension implementation has corrected, plus a follow-up default-value change. The architecture-doc text itself needs to be updated to match.

---

## TL;DR

The §4.3 friction-projection formula over-cancels tangential motion in the kinetic regime by a factor of roughly `tangent_mag / kinetic_cone`, which translates to the same factor of over-impulse on the type-1 reciprocal (slice 4E). In gameplay this manifests as:

- Heavy chain dragging on a ragdoll yeets light bones (toes, fingers) at 10–20× physical magnitude even with `tentacle_lubricity = 0.9`.
- Chain "sticks" to surfaces too aggressively — friction in the kinetic regime cancels almost all tangent motion per iteration regardless of μ.
- Tentacle wedged against geometry "fights back" because friction holds it in place against pose-target writes (jitter).

Fix is one line in `extensions/tentacletech/src/collision/friction_projection.h`. The architecture doc's §4.3 spec text needs to be updated to match. `body_impulse_scale` default flipped from 0.1 (pragmatic cap from slice 4F) to 1.0 (no cap needed with corrected friction).

---

## The bug

§4.3 currently specifies:

```
if tangent_mag < static_cone:
    particle.position -= Δx_tangent
    friction_applied = Δx_tangent
else:
    scale = 1.0 - (kinetic_cone / tangent_mag)
    particle.position -= Δx_tangent × scale
    friction_applied = Δx_tangent × scale
```

In the kinetic regime, `friction_applied = Δx_tangent × (1 − kinetic_cone/tangent_mag) = Δx_tangent − Δx_tangent_unit × kinetic_cone`. Magnitude: `tangent_mag − kinetic_cone`.

When `kinetic_cone << tangent_mag` (typical kinetic regime — fast tangential motion against a contact with shallow penetration), this cancels **most** of the tangent motion. The particle's post-friction tangential motion is `kinetic_cone` regardless of how much it was originally moving.

**Physical reality:** kinetic friction provides a force `F = μ_k × N`, capped over time `dt` to an impulse `J = μ_k × N × dt`. In PBD position units (per-iteration), that's a position correction of `μ_k × N × dt² / m = μ_k × dn` (where `dn` is the just-applied normal correction, since `dn ≈ N × dt² / m` for steady-state contact). So friction can cancel **up to `μ_k × dn` of tangential motion per iteration** — that's the friction's full capability, not the residual it leaves.

**Right form:**

```
if tangent_mag <= static_cone:
    particle.position -= Δx_tangent
    friction_applied = Δx_tangent
else:
    cancel = Δx_tangent_unit × kinetic_cone   # cap at kinetic friction's actual capacity
    particle.position -= cancel
    friction_applied = cancel
```

Same arithmetic complexity. One fewer divide. **Zero perf cost.**

Verification: in the new form, `friction_applied = kinetic_cone = μ_k × dn`. The type-1 reciprocal impulse becomes `friction_applied × m / dt = μ_k × m × dn / dt = μ_k × N × dt`, which is exactly the physically-correct kinetic friction impulse. ✓

## The fix (already landed in the implementation)

`extensions/tentacletech/src/collision/friction_projection.h` rewritten in slice 4G with:

```cpp
if (tangent_mag <= static_cone) {
    p.position -= dx_tangent;
    out_friction_applied = dx_tangent;
} else {
    Vector3 cancel = (dx_tangent / tangent_mag) * kinetic_cone;
    p.position -= cancel;
    out_friction_applied = cancel;
}
```

Header comment cross-references this update doc.

## Spec text changes required in `TentacleTech_Architecture.md` §4.3

Replace the current pseudocode block:

```
if tangent_mag < static_cone:
    particle.position -= Δx_tangent
    friction_applied = Δx_tangent
else:
    scale = 1.0 - (kinetic_cone / tangent_mag)
    particle.position -= Δx_tangent × scale
    friction_applied = Δx_tangent × scale
```

with:

```
if tangent_mag <= static_cone:
    particle.position -= Δx_tangent      # static — friction fully opposes
    friction_applied = Δx_tangent
else:
    # Kinetic — friction caps at μ_k × dn (the impulse μ_k × N × dt)
    cancel = (Δx_tangent / tangent_mag) × kinetic_cone
    particle.position -= cancel
    friction_applied = cancel
```

The narrative paragraph below it ("This single block handles stick-slip…") stays correct under the new form. Add a one-line note that the type-1 reciprocal impulse `J = friction_applied × m / dt` evaluates to `μ_k × N × dt` under this formulation — which was the implicit goal all along.

## Default-value changes

Slice 4F shipped a pragmatic `body_impulse_scale = 0.1` knob to mute the over-impulse. With the friction correction landed, this is no longer needed:

- **Old default**: 0.1 (10× cap below spec because the spec was wrong by ~10–20×)
- **New default**: 1.0 (full physics — spec impulse `J = μ_k × N × dt`)

The knob stays as a designer slider for "should this tentacle feel heavier than physics" tuning. Doc updated in `Tentacle.xml`.

## Test impact

Surprisingly minimal. The full tentacletech suite ran clean after the change:

- `test_collision_type4` 14/14
- `test_tentacle_mood` 7/7
- Other suites unchanged

Only one assertion needed updating: `test_body_impulse_scale_default_full` (was `..._is_gentle`) — verifies the 1.0 default instead of 0.1.

The friction-resists-lateral-drift test still passes because the static cone (μ_s = 0.4 at default) is large enough that low-velocity drift stays inside it. Stick behavior on a floor still works; chains just slide more readily under sustained tangential force.

## Known sub-correctness flagged for future work

PBD's iterative solver still applies friction once per iteration (currently 4×), which means in actively-driven contacts (pose target continuously pushing chain into a wall) friction may cancel up to `iter_count × kinetic_cone` per tick. For naturally-resolved contacts (gravity holds chain to floor), the iter 1 collision push leaves dn ≈ 0 in iters 2–4, so this naturally caps at 1× per tick.

In the worst case (chain wedged + actively driven) we're over-friction by up to ~4×. Acceptable for now since it's still vastly better than the previous ~10–20× over-friction. Real fix is a per-tick friction budget tracked on `TentacleParticle`, reset in `predict()`, decremented per friction projection. Slice for later if specific gameplay scenarios show problems.

Slice 4F's `pose_softness_when_blocked` knob (default 0.3 on `TentacleMood`) helps with the worst case by reducing pose-target stiffness for in-contact particles, so the driver doesn't drive the chain into walls at full strength to begin with.

## Apply checklist for top-level Claude

When applying this update:

1. **Update `TentacleTech_Architecture.md` §4.3** — replace the pseudocode block with the corrected form (see above). Add the type-1-reciprocal-evaluates-to-μ_k×N×dt note. Reference this update doc from §4.3 as the source of the change.
2. **Mark this doc as applied** in its header (or move to a "changelog" subdirectory if that's the convention).
3. **Don't touch tests** — they're already passing and are the source of truth for the corrected behavior.
4. **Don't change any defaults further** — `body_impulse_scale = 1.0`, `base_static_friction = 0.4`, `kinetic_friction_ratio = 0.8` are spec-aligned and shipping.

## What this doesn't address

- §4.4 modulator stack (rib / grip / barbed / anisotropy / adhesion) — still deferred.
- §4.6 wetness propagation — still deferred.
- The 4×-multiplier in driven contacts — flagged above as a future per-tick budget mechanism.
- Type-2 / type-3 / type-5 / type-6 / type-7 collision — still gated on Phase 5 orifice.
