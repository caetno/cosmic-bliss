# Cosmic Bliss — Design Update 2026-05-03 — Phase 4 wedge robustness

> **Status: pending — slice 4M reshaped 2026-05-03 after Obi source review.**
> Initial slice plan for sub-Claude in `extensions/tentacletech/`. Top-level
> review of Web-Claude-Code's wedge-case analysis confirmed the structural
> mismatch flagged as deferred slice 4M is real, plus four other issues
> worth bundling into a Phase 4 close-out cluster. Architecture-doc edits
> in §"Spec edits to apply post-review" are held until the implementation
> lands and review passes (per the friction-correction workflow precedent
> in `Cosmic_Bliss_Update_2026-05-02_phase4_friction_correction.md`).
>
> **Revision 2026-05-03 (Obi source review):** the user dropped the full
> Obi 7.x Unity asset source under `docs/pbd_research/Obi/`. Reading their
> contact-handling and constraint kernels showed slice 4M's "bisector
> friction" approach is the wrong shape — the canonical PBD answer to
> N-contact-per-particle is Jacobi + atomic position deltas + SOR apply,
> with per-contact persistent lambda accumulators. Slice 4M below is
> revised accordingly. Two new sub-slices (4M-XPBD, 4P) added; Phase 4.5
> placeholder narrows. Full synthesis at
> `docs/pbd_research/findings_obi_synthesis.md` — read it before starting
> 4M.

**Audience: sub-Claude in `extensions/tentacletech/`.**

This update specifies four slices (4M-pre, 4M, 4N, 4O) that close out Phase 4
by addressing the "tentacle wedged between two solid colliders" failure
mode. Until 4O lands, Phase 5 (orifice) stays blocked — the orifice rim is
itself a multi-contact wedge geometry, and starting Phase 5 on top of a
single-contact probe would compound the same bug across two phases.

---

## TL;DR

The wedge case (a tentacle particle simultaneously touching two thighs, two
ribs, two finger pads, etc.) currently flickers because the per-particle
probe records only the nearest of the active contacts. Each tick the
"nearest" can flip; collision push-out, gravity-tangent projection, and the
4J cleanup all act on the freshly-cached single normal and so periodically
push the particle deeper into the *other* contact. The 4I velocity damping
fights the symptom (residual velocity) but never wins, because every tick's
gravity + target + bending + anchor all replenish the energy reservoir.

Fix is structural: the probe needs to return up to 2 contacts per particle,
the iterate loop needs to project against both, and friction needs to use
the bisector normal. Three smaller fixes (dt clamp, singleton-target
softening, two-endpoint-wedged distance softening) cut confounds and ship
in the same cluster.

Sub-stepping for thrust-frame tunneling (deferred to Phase 9 by the current
phase plan) gets promoted into the same cluster — Phase 5 will start
producing thrust scenarios as soon as it opens, and we'd rather hit a
self-contained Phase 4 sub-step pass now than wedge it into Phase 5.

---

## Verdict on Web-Claude-Code's review

Cross-referenced every claim against the actual code. Graded:

| Claim | Verdict | Notes |
|---|---|---|
| Single-contact probe fails wedge | ✅ Correct | Already deferred as 4M; this update promotes to active. `environment_probe.cpp:94` (`get_rest_info`). |
| Stale contact through iter loop | ✅ Correct (intentional) | `tentacle.cpp:83-84` probes once before `iterate()`. Tradeoff documented at `pbd_solver.cpp:234-235`; only breaks under normal-flip. Becomes safe once 4M lands a stable manifold. |
| Target pull is per-iter snap; runs before collision | ✅ Correct on the snap; iter order is bending→target→collision→distance→friction→anchor (WCC missed friction step). Singleton-target path *does* bypass `pose_softness_when_blocked` — real bug, fixed by 4M-pre.2. |
| No sub-stepping | ✅ Correct | Deferred to Phase 9 by `TentacleTech_Architecture.md §13` item 38; promoted to slice 4O. |
| No `dt` clamp | ✅ Correct | Already flagged in CLAUDE.md Phase 2 row. Fixed by 4M-pre.1. |
| Friction baseline uses whole-tick `prev_position` | ✅ Correct, intentional | Fine for single-sided; acceptable under 4M's manifold. Not in this cluster. |
| 4J cleanup uses cached probe contact | Partial | Real concern, but "skip 4J when 4I > 0" is the wrong remedy — they fix orthogonal symptoms. Right fix is folding all-contacts into 4J's loop, which 4M does naturally. |
| Bend+distance+contact compound; bump iters to 6 | Partial | `MAX_ITERATION_COUNT = 6` already; per-mood opt-in is the right shape, not a global default bump. No action this cluster. |
| Pose-softness reads stale snapshot | ✅ Correct | One-tick stale per `behavior_driver.gd:408-409` comment. Slice 4N adds a fresh-this-tick accessor. |
| `contact_stiffness=0.5` too stiff for two-sided wedge | ✅ Plausible | Lowering globally regresses single-sided wrapping; the right shape is "drop further when *both* endpoints flagged." Slice 4M-pre.3. |
| XPBD compliance, contact warm-starting, CCD, spatial smoothing | All real | None Phase-4 scope. Park as Phase 4.5 placeholder; do not open until orifice is landed. |

The new finding worth capturing in a memory: the singleton-target path in
`pbd_solver.cpp:154-157` does not consume the same `pose_softness_when_blocked`
the pose-target loop honors. Any AI driver that writes a tip target via
`Tentacle::set_target` (rather than the distributed pose-target buffer) will
see full-stiffness target snap each iter regardless of contact state. This
was missed across slices 4F → 4L because the bundled `BehaviorDriver` writes
pose targets only.

---

## Slice 4M-pre — Confound elimination

One PR, three small items. Lands first because each one removes a
confounding variable from the wedge regression test in slice 4M.

### 4M-pre.1 — `dt` clamp in `Tentacle::tick`

**File:** `extensions/tentacletech/src/solver/tentacle.cpp` at the top of
`Tentacle::tick(float p_delta)` (currently line 76).

```cpp
void Tentacle::tick(float p_delta) {
    if (solver.is_null()) {
        return;
    }
    // Clamp dt to a sane range — first-frame hiccups (scene load, alt-tab)
    // can deliver dt > 50ms, which spikes gravity (gravity × dt² is the
    // Verlet integrator's gravity step) and target-pull's catch-up to the
    // point where the chain teleports through whatever is in front of it.
    // Floor stays small so tests that explicitly tick at < 1ms still run
    // (used in the jitter regression suite).
    if (p_delta < 1e-4f) return;
    if (p_delta > 1.0f / 40.0f) p_delta = 1.0f / 40.0f;
    if (!anchor_override) {
        solver->set_anchor(0, get_global_transform());
    }
    // ... rest unchanged
}
```

**Test:** add `test_dt_clamp_caps_at_25ms` to `test_collision_type4` —
verify particle motion is bounded for `tick(0.5)` regardless of gravity
magnitude.

### 4M-pre.2 — `pose_softness_when_blocked` for the singleton-target path

The pose-target loop in `behavior_driver.gd:478-479` softens stiffness for
in-contact particles, but the C++ singleton target path
(`pbd_solver.cpp:154-157`) ignores it. Move the softening into the solver
so both paths benefit, and so AI drivers that don't use the bundled
`BehaviorDriver` get the same correctness.

**Files:**
- `extensions/tentacletech/src/solver/pbd_solver.h` — add field
  `float target_softness_when_blocked = 0.3f;` and accessors
  `set_target_softness_when_blocked(float)` /
  `get_target_softness_when_blocked()`.
- `extensions/tentacletech/src/solver/pbd_solver.cpp` — inside the iterate
  loop step 2 (currently line 154), before calling `project_target_pull`
  on the singleton target, look up
  `particles[target_particle_index].in_contact_this_tick` and multiply
  `target_stiffness` by `target_softness_when_blocked` if blocked. The
  flag is set during the *previous* iter's collision step, or the previous
  tick on iter 0; that's accurate enough for stiffness modulation.
- Same change in the pose-target loop (currently line 158-169) — read the
  per-particle flag and apply the same softening multiplier. Then
  `behavior_driver.gd:411-415,478-479` becomes redundant; delete the
  `in_contact` snapshot read and the `blocked_stiffness` computation. Keep
  the `pose_softness_when_blocked` @export on `TentacleMood` /
  `BehaviorDriver` and forward it to
  `solver->set_target_softness_when_blocked(...)` from the same place
  `contact_stiffness` is forwarded today.
- `extensions/tentacletech/src/solver/tentacle.cpp` — passthrough
  set/get + `ADD_PROPERTY` line in `_bind_methods`.

**Test:** add `test_singleton_target_softens_on_contact` to
`test_collision_type4` — set a tip target *into* a static wall, verify the
tip stops at `wall_pos + collision_radius * (1 + ε)` rather than oscillating
past it.

### 4M-pre.3 — Two-endpoint-wedged distance softening

**File:** `extensions/tentacletech/src/solver/pbd_solver.cpp` step 4
(currently line 218-226), the distance constraint loop. Current code:

```cpp
float seg_stiffness = (particles[i].in_contact_this_tick ||
        particles[i + 1].in_contact_this_tick)
        ? contact_stiffness
        : distance_stiffness;
```

Replace with three-way:

```cpp
bool both = particles[i].in_contact_this_tick &&
        particles[i + 1].in_contact_this_tick;
bool either = particles[i].in_contact_this_tick ||
        particles[i + 1].in_contact_this_tick;
float seg_stiffness = both
        ? (contact_stiffness * wedge_distance_stiffness_factor)
        : (either ? contact_stiffness : distance_stiffness);
```

New constant: `wedge_distance_stiffness_factor = 0.3f` (default in
`pbd_solver.h`), with `set_/get_` and a `Tentacle` passthrough + export.
Forward from `TentacleMood` alongside `contact_stiffness`.

Single-sided wrapping (the case 4C was designed for) is unchanged. Two-sided
wedging gets a stiffness of `0.5 × 0.3 = 0.15` (vs `0.5` today) — much
gentler, lets the chain stretch over the pinch instead of fighting it.

**Test:** add `test_two_sided_wedge_softens_distance` — particle wedged
between two static spheres at narrow apex, verify segment stretch is at
least 1.2× rest within 5 ticks (vs ~1.0× today, indicating distance fights
collision).

**Acceptance for 4M-pre:** `test_jitter_does_not_scale_with_iter_count`
(landed in 4L) still passes; new tests pass; visible jitter in the existing
"tentacle between legs" failure scene is reduced even before 4M lands the
multi-contact probe.

---

## Slice 4M — Multi-contact probe + Jacobi-with-lambda contacts

> **Reshaped 2026-05-03 after Obi source review.** Original draft used a
> "bisector friction normal" heuristic to handle two-contact particles.
> Replaced with the Jacobi-with-atomic-deltas-and-SOR pattern Obi uses
> (`docs/pbd_research/Obi/Resources/Compute/AtomicDeltas.cginc` +
> `ColliderCollisionConstraints.compute`). Naturally generalizes to N
> contacts per particle without bisector heuristics; per-contact lambda
> accumulators make friction cones correct under multi-contact without
> the `iter_dn_buffer` we patched in slice 4L. See
> `docs/pbd_research/findings_obi_synthesis.md` § "Slice plan revisions"
> for the rationale.

The structural fix. Goes in alone; do not bundle with anything else.

### 4M.0 — Adopt the Jacobi-atomic-delta accumulator (foundation)

This is the infrastructure piece every other 4M sub-step builds on.
Lifted directly from `pbd_research/Obi/Resources/Compute/AtomicDeltas.cginc`,
adapted to single-threaded C++ (no atomics needed; we're not on GPU).

**Files:** `extensions/tentacletech/src/solver/pbd_solver.{h,cpp}`.

Add two per-particle scratch buffers, sized in `initialize_chain`:

```cpp
std::vector<godot::Vector3> position_delta_scratch; // size N
std::vector<int> position_delta_count;              // size N
```

Helpers:

```cpp
inline void add_position_delta(int i, const godot::Vector3 &d) {
    position_delta_scratch[i] += d;
    position_delta_count[i] += 1;
}

inline void apply_position_delta(int i, float sor_factor) {
    int c = position_delta_count[i];
    if (c > 0) {
        particles[i].position += position_delta_scratch[i] * (sor_factor / (float)c);
        position_delta_scratch[i] = godot::Vector3();
        position_delta_count[i] = 0;
    }
}
```

`sor_factor` (successive over-relaxation, default `1.0f`) is exposed
via `set_sor_factor(float)` + Tentacle passthrough. Higher values
(1.5–2.0) speed convergence but can overshoot — leave at 1.0 default,
expose for Mood tuning.

The iterate loop pattern changes from "constraint mutates particle
position directly" to "constraint calls `add_position_delta`, then once
per iter all particles call `apply_position_delta`." Existing
`project_distance` / `project_bending` / `project_target_pull` change
from `position += correction` to `add_position_delta(i, correction)`,
followed by an `apply_position_delta` pass at the end of each iter.

Anchor (`project_anchor`) keeps its hard-set behavior — anchors are
not constraints in the lambda sense.

### 4M.1 — `EnvironmentContact` becomes a slot array

**File:** `extensions/tentacletech/src/collision/environment_probe.h`.

Replace the single-hit fields with a small fixed-size array. Suggest
`MAX_CONTACTS_PER_PARTICLE = 2` for now (bump only when Phase 5 orifice
shows a need; bumping past 4 starts costing real per-particle memory and
cache). Each contact slot also carries persistent lambda accumulators —
this is the key change that lets friction cones use the contact's own
accumulated normal impulse instead of the per-particle `iter_dn_buffer`
we have today:

```cpp
struct ContactSlot {
    godot::Vector3 hit_point;
    godot::Vector3 hit_normal;
    float hit_depth;
    uint64_t hit_object_id = 0;
    godot::RID hit_rid;
    godot::Vector3 hit_linear_velocity;
    // Persistent across iters within a tick (or substep once 4O lands):
    float normal_lambda = 0.0f;
    godot::Vector3 tangent_lambda = godot::Vector3();
    // Friction reciprocal output (slice 4M.5):
    godot::Vector3 friction_applied = godot::Vector3();
};

struct EnvironmentContact {
    int particle_index = -1;
    godot::Vector3 query_origin;
    int contact_count = 0;
    bool hit = false;  // == (contact_count > 0)
    ContactSlot contacts[MAX_CONTACTS_PER_PARTICLE];
};
```

Lambdas reset to zero in `predict()` (per tick today; per substep once
4O lands). Keep the singular `hit_*` getters as alias accessors that
return `contacts[0].*` for the existing snapshot dictionary builder in
`tentacle.cpp:587-617`.

The `iter_dn_buffer` introduced in slice 4L goes away — the friction
cone no longer needs a per-particle max-across-iters depth, because each
contact reads its own `normal_lambda` directly.

```cpp
struct EnvironmentContact {
    int particle_index = -1;
    godot::Vector3 query_origin;
    int contact_count = 0;            // 0..MAX_CONTACTS_PER_PARTICLE
    bool hit = false;                 // == (contact_count > 0), kept for snapshot compat
    // Per-contact slots (parallel arrays inside the struct — keeps things
    // cache-coherent when contact_count is iterated):
    godot::Vector3 hit_point[MAX_CONTACTS_PER_PARTICLE];
    godot::Vector3 hit_normal[MAX_CONTACTS_PER_PARTICLE];
    float hit_depth[MAX_CONTACTS_PER_PARTICLE];
    uint64_t hit_object_id[MAX_CONTACTS_PER_PARTICLE] = {0, 0};
    godot::RID hit_rid[MAX_CONTACTS_PER_PARTICLE];
    godot::Vector3 hit_linear_velocity[MAX_CONTACTS_PER_PARTICLE];
};
```

Keep the singular `hit_*` getters as alias accessors that return `[0]` so
the existing snapshot dictionary builder in `tentacle.cpp:587-617` keeps
compiling; add new `get_environment_contacts_snapshot()` paths only if the
overlay actually needs both contacts (defer).

### 4M.2 — `EnvironmentProbe::probe` switches to `intersect_shape`

**File:** `extensions/tentacletech/src/collision/environment_probe.cpp`.

`get_rest_info` returns one body. Switch to
`PhysicsDirectSpaceState3D::intersect_shape` with `max_results = 4`. For
each result, recompute the surface normal/depth via a per-shape closest-point
pass against the same sphere shape. Sphere-vs-sphere, sphere-vs-capsule,
sphere-vs-box are all closed-form and cheap; sphere-vs-convex uses GJK via
the existing `get_rest_info` per-shape (cast the result's RID to a
`PhysicsDirectBodyState3D` for the closest point) as a fallback. Keep the
top-2 by penetration depth.

Order matters: the higher-depth contact lands at slot `[0]`, lower at `[1]`.
Tests downstream rely on slot 0 being "primary."

Cost budget: today's probe is ~12-30 queries/tentacle/tick (one per
particle). `intersect_shape` returns up to 4 results in one query, so the
shape count stays at one per particle; the per-result closest-point math is
trivial. Rough budget: 1.3-1.5× current probe time. Profile with
`test_collision_type4` after the change; flag if it's worse than 2×.

### 4M.3 — Solver iterate loop: per-contact lambda projection

**File:** `extensions/tentacletech/src/solver/pbd_solver.cpp` step 3
(currently lines 192-210).

Pattern lifted from `pbd_research/Obi/Resources/Compute/
ColliderCollisionConstraints.compute` `Project` kernel + `ContactHandling.
cginc::SolvePenetration`. Each contact maintains its own `normal_lambda`
(N·s, accumulated across iters within the tick/substep). Lambda
accumulation enables: (a) friction cones bound by the contact's actual
accumulated normal impulse, (b) graceful settling under multi-contact
without the `iter_dn_buffer` patch.

```cpp
if (have_contacts) {
    for (int i = 0; i < n; i++) {
        EnvironmentContact &ec = env_contacts[i];
        if (ec.contact_count == 0) continue;
        TentacleParticle &p = particles[i];
        if (p.inv_mass <= 0.0f) continue;
        float radius = collision_radius * p.girth_scale;
        if (radius < 1e-5f) continue;
        p.in_contact_this_tick = true;
        for (int k = 0; k < ec.contact_count; k++) {
            ContactSlot &cs = ec.contacts[k];
            // Constraint value: signed distance from particle surface
            // to contact plane. Negative = penetrating.
            float dist = (p.position - cs.hit_point).dot(cs.hit_normal) - radius;
            float normal_mass = p.inv_mass; // collider is treated as infinite-mass for now
            if (normal_mass <= 0.0f) continue;
            // XPBD-style lambda update (no compliance for collision):
            float dlambda = -dist / normal_mass;
            // Clamp to depenetration cap — Obi's `maxDepenetration`:
            float max_dlambda = max_depenetration * dt; // dt = current sub/tick step
            if (dlambda > max_dlambda) dlambda = max_dlambda;
            // One-sided constraint: contacts only push out, never pull in.
            float new_lambda = std::max(cs.normal_lambda + dlambda, 0.0f);
            float lambda_change = new_lambda - cs.normal_lambda;
            cs.normal_lambda = new_lambda;
            if (std::abs(lambda_change) > 1e-8f) {
                add_position_delta(i, cs.hit_normal * (lambda_change * p.inv_mass));
            }
        }
    }
    // Apply once per particle this iter:
    for (int i = 0; i < n; i++) apply_position_delta(i, sor_factor);
}
```

Pinch cases (two normals anti-parallel) emerge naturally: both contacts
push outward, deltas average to ~zero via the SOR division, particle
stays at the pinch point. Detect via `dot(n0, n1) < -0.5` post-iter and
emit a `pinched` event on the bus (deferred to Phase 6).

The slice 4J cleanup pass (lines 265-296) **goes away entirely.** With
lambda accumulation, the iter loop converges within itself — there's
no end-of-tick residual penetration to clean up. `iter_dn_buffer`
(introduced 4L) also goes away.

### 4M.4 — Per-contact friction with lambda-bounded cones

**File:** `extensions/tentacletech/src/solver/pbd_solver.cpp` step 5
(currently lines 236-257) plus
`extensions/tentacletech/src/collision/friction_projection.h`.

Pattern from `ContactHandling.cginc::SolveFriction`. Each contact runs
its own friction projection, bounded by *that contact's* accumulated
normal lambda. Multi-contact friction is now correct by construction —
no bisector heuristic, no per-particle dn budget. Friction deltas
accumulate via the same Jacobi+SOR path.

```cpp
if (have_contacts && friction_static > 0.0f) {
    for (int i = 0; i < n; i++) {
        EnvironmentContact &ec = env_contacts[i];
        if (ec.contact_count == 0) continue;
        TentacleParticle &p = particles[i];
        if (p.inv_mass <= 0.0f) continue;
        float mu_s = friction_static;
        float mu_k = friction_static * friction_kinetic_ratio;
        for (int k = 0; k < ec.contact_count; k++) {
            ContactSlot &cs = ec.contacts[k];
            if (cs.normal_lambda <= 0.0f) continue; // not pressing
            // Tangential motion this tick:
            Vector3 dx = p.position - p.prev_position;
            Vector3 dx_tan = dx - cs.hit_normal * dx.dot(cs.hit_normal);
            float tan_mag = dx_tan.length();
            if (tan_mag < 1e-8f) continue;
            // Friction cones from accumulated normal lambda:
            float static_cone = mu_s * cs.normal_lambda;
            float kinetic_cone = mu_k * cs.normal_lambda;
            // Tangent lambda update (clamped by cone):
            Vector3 dx_tan_dir = dx_tan / tan_mag;
            float tan_lambda_delta;
            if (tan_mag <= static_cone / std::max(p.inv_mass, 1e-8f)) {
                tan_lambda_delta = -tan_mag / std::max(p.inv_mass, 1e-8f);
            } else {
                tan_lambda_delta = -kinetic_cone;
            }
            // Friction is one-sided too — opposes motion only.
            Vector3 friction_delta = dx_tan_dir * (tan_lambda_delta * p.inv_mass);
            add_position_delta(i, friction_delta);
            cs.tangent_lambda += dx_tan_dir * tan_lambda_delta;
            cs.friction_applied -= friction_delta; // for slice 4M.5 reciprocal
        }
    }
    for (int i = 0; i < n; i++) apply_position_delta(i, sor_factor);
}
```

Note: the existing `friction_projection.h` `project_friction` function
becomes unused. Keep the file but mark deprecated; remove in a follow-up
PR after sub-Claude confirms no other callers.

### 4M.5 — Tentacle `_apply_collision_reciprocals` walks all contacts

**File:** `extensions/tentacletech/src/solver/tentacle.cpp` lines 89-151.

`ContactSlot::friction_applied` (set by 4M.4) is now per-contact. The
reciprocal pass loops over `ec.contact_count` and routes each slot's
impulse to its own RID. Buffer cost at MAX_CONTACTS=2 and 16 particles
is 32 Vector3s — trivial.

```cpp
for (uint32_t i = 0; i < contacts.size(); i++) {
    const EnvironmentContact &ec = contacts[i];
    if (ec.contact_count == 0) continue;
    float inv_mass = solver->get_particle_inv_mass(ec.particle_index);
    if (inv_mass <= 0.0f) continue;
    float eff_mass = 1.0f / inv_mass;
    for (int k = 0; k < ec.contact_count; k++) {
        const ContactSlot &cs = ec.contacts[k];
        if (cs.hit_object_id == 0) continue;
        Vector3 fa = cs.friction_applied;
        if (fa.length_squared() < 1e-10f) continue;
        Vector3 impulse = fa * (eff_mass * body_impulse_scale / p_delta);
        if (impulse.length_squared() < 1e-12f) continue;
        Object *obj = ObjectDB::get_instance(ObjectID((uint64_t)cs.hit_object_id));
        Node3D *body_node = Object::cast_to<Node3D>(obj);
        Vector3 offset = (body_node != nullptr)
            ? cs.hit_point - body_node->get_global_position()
            : cs.hit_point;
        ps->body_apply_impulse(cs.hit_rid, impulse, offset);
    }
}
```

### 4M acceptance test

Extend `test_collision_type4` with a wedge sweep:

```gdscript
# Particle dropped between two static capsules at apex angles
# 30°, 60°, 90°, 120°, 160°. Tick for 60 frames at dt=1/60.
# Pre-4M: jitter at all apex angles (max |Δpos| > collision_radius × 0.1
#         for the last 30 frames).
# Post-4M targets:
#   - apex ≥ 90°:  settled within 5 ticks; max |Δpos| over last 30 frames
#                  ≤ collision_radius × 0.05.
#   - apex 30°–60° (deep wedge): settled within 15 ticks; same bound.
#   - apex < 20° (anti-parallel pinch): no jitter, no escape. Particle
#     stays at the pinch point. Friction zeroes out, position drifts only
#     along the unconstrained axis (the wedge's longitudinal direction).
```

Plus a regression on the existing single-sided cases — settled chain on a
floor must still settle, contact_velocity_damping must still bleed
oscillations, and the tunnel-through-a-wall scene from slice 4B must still
not tunnel.

---

## Slice 4M-XPBD — Distance constraint compliance (new sub-slice)

> **Added 2026-05-03 after Obi source review.** The lambda-accumulator
> infrastructure 4M lands is the same infrastructure XPBD distance needs.
> Bundling them keeps the buffer plumbing in one PR. See
> `pbd_research/Obi/Resources/Compute/DistanceConstraints.compute` —
> the entire kernel is 70 lines and is canonical XPBD.

**File:** `extensions/tentacletech/src/solver/constraints.cpp`
(`project_distance` function).

Current form (post-PBD, no compliance):

```cpp
Vector3 correction = dir * (p_stiffness * diff / w_sum);
p_a.position += correction * p_a.inv_mass;
p_b.position -= correction * p_b.inv_mass;
```

XPBD form (Macklin 2016 / Obi DistanceConstraints):

```cpp
// Per-segment lambda buffer, sized N-1, reset in predict() per
// tick (or per substep once 4O lands):
float &lambda = distance_lambdas[segment_index];
// Compliance from public stiffness knob — small at high stiffness:
float compliance = stiffness_to_compliance(p_stiffness) / (dt * dt);
float dlambda = (-diff - compliance * lambda) /
                (w_sum + compliance + 1e-8f);
lambda += dlambda;
Vector3 delta = dir * dlambda;
add_position_delta(idx_a, delta * p_a.inv_mass);
add_position_delta(idx_b, -delta * p_b.inv_mass);
```

`stiffness_to_compliance` maps the public 0..1 knob to physical
compliance:

```cpp
inline float stiffness_to_compliance(float s) {
    // s=1 → near-rigid (compliance 1e-9)
    // s=0 → very soft (compliance 1e-3)
    s = std::clamp(s, 0.0f, 1.0f);
    float log_compliance = -9.0f + 6.0f * (1.0f - s);
    return std::pow(10.0f, log_compliance);
}
```

Backward-compat note: the public `set_distance_stiffness(float)` API is
preserved. Existing TentacleMood presets with `distance_stiffness=1.0`
will feel slightly less rigid than before (XPBD doesn't compound stiffness
across iterations the way our current form does — that compounding was
covering for stiffness-fights-collision). Re-tuning is a one-liner per
preset; document in the PR notes.

**Bending stays chord-form** (no XPBD on bending in this slice). Only
distance migrates. Bending's chord form already uses `stiffness * diff`
which converges fine since bending isn't load-bearing in the same way
distance is.

**Pose-target and singleton-target** stay lerp-style. They're
soft-by-construction; XPBD doesn't help.

**Wedge distance softening from 4M-pre.3** is *superseded* by the
XPBD distance — under XPBD, both-endpoints-in-contact no longer requires
a special case. Keep 4M-pre.3 if landed first as a stopgap; remove when
4M-XPBD lands. If sub-Claude can land 4M-pre+4M+4M-XPBD in one cluster,
skip 4M-pre.3 entirely.

**Lambda reset:** in `predict()`, zero `distance_lambdas` per tick (today)
or per substep (post-4O). The reset is what makes XPBD position-correct
across time without compounding error. Forgetting to reset = exploding
oscillation; verify with a test.

**Test:** `test_distance_xpbd_matches_steady_state` — under sustained
gravity load on a hanging chain, XPBD with stiffness=1 should converge
to the same per-segment stretch as the current PBD form within ε. Plus
`test_distance_xpbd_does_not_explode_without_lambda_reset` — a deliberate
omission of the reset should produce diverging oscillation, used as a
canary that the reset is wired in.

---

## Slice 4N — Fresh-this-tick contact snapshot

**Problem:** `BehaviorDriver` reads `solver.get_particle_in_contact_snapshot()`
once per tick to compute `pose_softness_when_blocked` (or `target_softness_when_blocked`
after 4M-pre.2). The flag reflects last tick's iterate-loop result —
one-tick stale. Fast contact onset (collision impacts) softens stiffness one
beat after the chain has already started fighting the obstacle.

**Fix:** the probe runs *before* `solver.tick` (see `tentacle.cpp:83-84`),
which means the per-particle "is this particle going to be in contact this
tick" answer is known after the probe and before iterate. Expose it.

**File:** `extensions/tentacletech/src/solver/tentacle.cpp`.

After `_run_environment_probe()` finishes (line 84), populate a `PackedByteArray`
from `env_contact_active_scratch` into a member `_in_contact_this_tick_snapshot`.
Add accessor `Tentacle::get_in_contact_this_tick_snapshot()` that returns it
by-copy. This snapshot is written once per `tick()` call, before iterate.

Driver (`behavior_driver.gd:411-414`) switches from
`solver.get_particle_in_contact_snapshot()` (last-tick) to
`_tentacle.get_in_contact_this_tick_snapshot()` (this-tick-fresh). One-line
change. Process-order requirement: `BehaviorDriver._physics_process` must
run *after* `Tentacle._physics_process`. The Godot default is parent-first
which gives us that for free if the driver is a child of the Tentacle (which
the bundled scenes already do); document the requirement in
`behavior_driver.gd`'s class docstring.

If a project ever inverts the order (driver above Tentacle), the snapshot
falls back to last-tick semantics — same as today. No regression.

**Test:** add `test_in_contact_snapshot_is_fresh_this_tick` — drop a
particle onto a floor at `t=0`, verify the snapshot reads "in contact" on
the first tick (not the second) when the driver runs after the Tentacle.

---

## Slice 4O — Sub-stepping for thrust-frame tunneling

**Problem:** §13 phase plan defers sub-stepping to Phase 9 polish. Phase 5
(orifice, immediately after this cluster) opens the first thrust scenarios
in the codebase — penetrative driver writes a target 1-2× chain length away
with stiffness 0.5+, and the tip's per-tick displacement can exceed
`collision_radius`. Single-tick collision misses the wall on the way in;
the chain rebounds off the far surface as a visible snap.

Promoting sub-stepping into Phase 4 close-out is cheap (the probe and
iterate are already self-contained per call) and unblocks Phase 5
authoring.

### 4O.1 — Per-particle displacement budget

**File:** `extensions/tentacletech/src/solver/tentacle.cpp::tick`.

After the dt clamp from 4M-pre.1, before `_run_environment_probe()`, predict
worst-case displacement:

```cpp
// Estimate worst-case per-tick displacement to decide if sub-stepping is
// needed. The target pull at stiffness 1.0 snaps the targeted particle to
// `target_position` in one iteration, so its displacement budget is the
// distance from current position to target. Gravity contributes
// `||gravity|| × dt²`. Pose targets contribute up to their stiffness ×
// distance, but the worst case is dominated by the singleton target if
// active. We're conservative — better to sub-step a frame that didn't
// strictly need it than tunnel through a thigh.
float radius = solver->get_collision_radius();
float max_disp = solver->get_gravity().length() * p_delta * p_delta;
if (solver->has_target()) {
    int ti = solver->get_target_particle_index();
    Vector3 from = solver->get_particle_position(ti);
    float d = (solver->get_target_position() - from).length();
    max_disp = MAX(max_disp, d * solver->get_target_stiffness());
}
int sub_steps = 1;
if (radius > 1e-5f && max_disp > 0.5f * radius) {
    sub_steps = (int)Math::ceil(max_disp / (0.5f * radius));
    if (sub_steps > 4) sub_steps = 4;     // cap; beyond 4 the cost dominates
}
```

### 4O.2 — Re-probe per sub-step

In the sub-step loop, run the probe + solver tick once per sub-step:

```cpp
float sub_dt = p_delta / (float)sub_steps;
for (int s = 0; s < sub_steps; s++) {
    if (!anchor_override) {
        solver->set_anchor(0, get_global_transform());
    }
    _run_environment_probe();
    solver->tick(sub_dt);
}
_apply_collision_reciprocals(p_delta); // total dt — impulse magnitudes still scale correctly
_update_spline_data_texture();
```

Reciprocal pass stays once per outer tick. Inside the sub-step loop the
solver's `friction_applied` accumulator is reset per `tick`, so the
reciprocal call after the loop reads only the final sub-step's friction.
That's wrong; switch the reciprocal call to read per-sub-step and sum, or
have the solver opt-out of reset-per-tick and let the Tentacle clear
explicitly. **Recommend:** add `PBDSolver::reset_friction_applied()` and call
it once before the sub-step loop; the loop accumulates across sub-steps;
reciprocal pass reads the sum. No semantics change for the no-sub-step case
(a single sub-step still triggers one reset + one accumulate + one read).

### 4O.3 — Sub-step count exposed for debugging

Add `Tentacle::get_last_substep_count() -> int` returning the most recent
tick's sub-step count. Useful for the gizmo overlay (color particles by
sub-step count to find scenes that are paying for sub-stepping unnecessarily).

### 4O acceptance test

`test_substep_thrust_does_not_tunnel`: place a static wall 0.4m in front of
a 16-particle tentacle whose tip has a 1.5m target with stiffness 0.7.
Single-tick (`dt = 1/60`). Pre-4O: tip teleports through wall, settles
beyond it. Post-4O: tip stops at `wall_pos + collision_radius`, sub-step
count reports ≥ 2.

---

## Slice 4P — Sleep threshold + max depenetration (new sub-slice)

> **Added 2026-05-03 after Obi source review.** Two cheap one-liners
> Obi ships that close the loop on residual jitter and tunneling
> visuals. Both directly transcribed from
> `pbd_research/Obi/Resources/Compute/Solver.compute:204-217` and
> `SolverParameters.cginc`.

### 4P.1 — Sleep threshold

**File:** `extensions/tentacletech/src/solver/pbd_solver.cpp::finalize`
(after the existing contact_velocity_damping block).

```cpp
if (sleep_threshold > 0.0f) {
    float thr2 = sleep_threshold * sleep_threshold;
    for (int i = 0; i < n; i++) {
        TentacleParticle &p = particles[i];
        if (p.inv_mass <= 0.0f) continue;
        Vector3 v = p.position - p.prev_position;
        if (v.length_squared() <= thr2 * (p_dt * p_dt)) {
            // Below sleep threshold — snap back to prev_position to
            // kill residual jitter from un-converged constraints.
            p.position = p.prev_position;
        }
    }
}
```

Default `sleep_threshold = 0.0` (off — preserves shipping behavior).
Recommended ~0.005 (m/s) for tentacles that hang at rest. Opt-in per
TentacleMood; "active" moods leave it at 0.

The slice 4I `contact_velocity_damping` becomes mostly redundant under
XPBD (lambda accumulation kills the residual implicit velocity at the
source) but is harmless; leave for now.

### 4P.2 — Max depenetration cap

**File:** `extensions/tentacletech/src/solver/pbd_solver.h` — new
parameter `float max_depenetration = 1.0f;` (m/s). Already wired into
the slice 4M.3 collision projection (the `max_dlambda` cap there).

Public API: `set_max_depenetration(float)` + Tentacle export. Default
1.0 m/s — gentle enough that a deeply-penetrated particle (e.g.
spawned inside a wall) is ejected over ~10 ticks rather than in one
explosive frame, but fast enough that legitimate deep contacts don't
drag the simulation. Per-mood tunable.

---

## Spec edits to apply post-review

Once 4O lands and top-level review approves the cluster, apply these edits
to the canonical docs:

### `docs/architecture/TentacleTech_Architecture.md` §13 Phase plan

In the **Phase 4** block, add after item 14:

```
14a. Multi-contact probe (slice 4M) — per-particle manifold, bisected friction
14b. Sub-stepping for thrust frames (slice 4O) — promoted from Phase 9 polish
```

In the **Phase 9** block, *remove* item 38 ("Sub-stepping for fast motion")
and renumber the remaining items.

### `docs/architecture/TentacleTech_Architecture.md` §14 Gotchas

Append three bullets to the **Gotchas:** list (after the existing "Friction
resonance/jitter" bullet):

- **Two-sided contact (wedge) requires multi-contact probe and bisected friction normal.** Single-normal projection oscillates at any wedge half-angle below ~80° because the cached "nearest" contact flips per-tick. Manifold form lands in slice 4M (`docs/Cosmic_Bliss_Update_2026-05-03_phase4_wedge_robustness.md`); without it, particles wedged between two solid colliders flicker and never settle.
- **Anti-parallel pinch (normal · normal < −0.5) is geometrically degenerate.** Both contact projections cancel; PBD has nothing to push against. Friction zeroes out by design (no useful tangent direction). Detect and emit a `pinched` event on the bus (Phase 6) rather than thrashing the iterate loop.
- **Fresh-contact snapshot vs last-tick snapshot.** `Solver::get_particle_in_contact_snapshot()` reflects the previous tick's iterate-loop flags. Behavior drivers that reduce stiffness on contact should consume `Tentacle::get_in_contact_this_tick_snapshot()` (slice 4N) for one-tick-fresh data; the legacy accessor stays for backwards compat.

### `docs/architecture/TentacleTech_Architecture.md` §4.2 / §4.3

Add a one-line note in §4.2 that the type-4 environment probe returns up to
`MAX_CONTACTS_PER_PARTICLE` simultaneous contacts (currently 2) and that
the iterate loop's collision step projects against each in turn; in §4.3
that the friction tangent uses the bisector when the manifold has multiple
contacts.

---

## What this cluster does NOT address

> **Revised 2026-05-03:** XPBD distance + per-contact lambda warm-starting
> have moved *into* the cluster (4M and 4M-XPBD). The Phase 4.5 placeholder
> narrows accordingly.

- **XPBD on bending and pose targets.** Bending stays chord-form;
  pose/target stay lerp-style. Both are soft-by-construction and XPBD
  doesn't help. Promote later only if a specific gameplay scenario
  shows compounding bending stiffness causing visible artifacts.
- **2D friction pyramid (separate tangent + bitangent).** Obi uses it
  for general rigid-body friction; for a 1D chain the tangential
  motion is dominated by one direction (chord-aligned). Stay 1D cone.
- **Rolling friction.** Particles don't rotate in our model.
- **Sequential (Gauss-Seidel) constraint mode.** Our C++ solver is
  single-threaded at modest particle counts; the existing in-place
  pattern is fine. The Jacobi+SOR pattern in 4M is needed for
  multi-contact correctness, not for parallelism.
- **Compute-shader port.** TentacleTech particle counts are 100s, not
  millions. Stay CPU.
- **Spatial smoothing of contact normals across adjacent particles.**
  Three-tap median over (i-1, i, i+1) breaks chain-wavelength
  oscillation. Not needed under XPBD + Jacobi + per-contact lambdas;
  the convergence model resolves cluster oscillation at the source.
- **CCD against capsules.** Sub-stepping (4O) is the cheaper
  alternative and matches the §13 gotchas language. CCD belongs in
  Phase 9 polish.
- **Per-tick friction budget.** The `2026-05-02_phase4_friction_correction.md`
  flag is also superseded — under per-contact lambdas, the friction
  budget *is* the contact's normal_lambda accumulator. The "4× over-friction
  in driven contacts" worst case from that doc no longer applies.
- **"Skip 4J when 4I > 0."** Wrong remedy as originally written; the
  4J pass is removed entirely by 4M.3 anyway.
- **Bumping default `iteration_count` to 6.** Per-mood opt-in already
  exists via `Tentacle::set_iteration_count`. Don't pay 50% more
  solver cost everywhere for one scenario. Under XPBD + lambda
  accumulation, 4 iters per tick (or 2 iters × 2 substeps once 4O
  lands) is plenty.

**Phase 4.5 placeholder — narrowed:**
- Per-collider material composition (Obi's CollisionMaterial combine
  modes — Average / Min / Multiply / Max). §4.4 modulator stack work.
  Open during Phase 6 (stimulus bus) when the surface tagging system
  lands.
- Continuous collision detection (CCD) against capsules. Promote only
  if sub-stepping (4O) proves insufficient for fast-thrust orifice
  scenarios.

---

## Apply checklist for sub-Claude

> **Revised ordering 2026-05-03.** 4M-pre.3 (wedge distance softening) is
> now optional — 4M-XPBD supersedes it. If the cluster ships in
> sequence, skip 4M-pre.3 outright.

When working through this cluster:

0. **Read `docs/pbd_research/findings_obi_synthesis.md` first.** The
   approach to slice 4M was reshaped after reviewing Obi's solver
   source; that doc explains the rationale and shows the source
   patterns being borrowed. The synthesis is shorter than this update
   doc — under 15 minutes to read.
1. **Land 4M-pre.1 + 4M-pre.2 as one PR.** Skip 4M-pre.3. Run
   `test_collision_type4` + `test_tentacle_mood` + the two new tests;
   report pass counts.
2. **Land 4M + 4M-XPBD together as one PR.** This is the largest
   slice — give it its own review cycle. Profile probe cost; flag if
   > 2× the pre-4M baseline. Re-tune any TentacleMood preset whose
   `distance_stiffness=1.0` reads visibly softer post-XPBD; document
   the re-tuning in the PR notes.
3. **Land 4N as a small follow-up.** One accessor + one driver line +
   one test.
4. **Land 4O as the convergence-model promotion.** Run the new
   tunneling test plus a full regression sweep including the slice 4L
   jitter test. Validate that flipping `substeps` default from 1 → 2
   doesn't break the existing mood library.
5. **Land 4P as the close-out.** Two cheap fixes; one PR.
6. **Update `extensions/tentacletech/CLAUDE.md` Status table Phase 4
   row** after each slice — flip pending → done with a one-liner;
   preserve the 4A → 4L history.
7. **Do NOT edit `TentacleTech_Architecture.md` directly** — those
   edits are in §"Spec edits to apply post-review" above and are
   applied by top-level Claude after the cluster lands.
8. **Do NOT touch other extensions.** If marionette or tenticles needs
   changes for sub-stepping coordination (it doesn't, as far as I can
   see), raise it in the report.
