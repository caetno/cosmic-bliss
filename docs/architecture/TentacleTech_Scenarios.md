# TentacleTech — Scenarios and AI Model

**Canonical specification for how the tentacle system behaves at the behavioral level.** Pairs with `TentacleTech_Architecture.md`. Two parts:

- **Part A — Control and AI model:** how tentacles are controlled, how the AI works, what the parameter space looks like
- **Part B — Narrative scenarios:** concrete physics-emergent stories that double as acceptance tests

---

# Part A — Control and AI Model

## A1. The control surface

Every tentacle reads exactly one struct per frame. Whoever writes it (player, AI, scripted sequence) is interchangeable.

```cpp
struct TentacleControl {
    // Targeting
    Vector3  target_direction;         // unit vector, where tip wants to go
    float    engagement_depth;         // -1..+1 (far retreat → fully inserted)
    float    target_weight;            // 0..1 (weak → strong intent)

    // Material / shape modulation
    float    stiffness;                // 0..1 bending constraint multiplier
    float    girth_modulation;         // 0.5..2.0 multiplier on rest girth
    float    lubricity;                // 0..1 adds to surface slickness

    // Motion bias
    float    axial_velocity_bias;      // -1..+1 continuous along tentacle axis

    // Aliveness
    float    noise_amplitude;          // 0..1 master on all noise layers
    Vector3  noise_frequency_mix;      // weights for (drift, writhe, breath)

    // Target selection
    Orifice* target_orifice;           // biases intent toward this orifice
};
```

14 scalars plus object pointers. Every behavioral knob is here.

## A2. Layered aliveness

A tentacle never sits still. The behavior driver builds the effective target each frame from multiple noise layers plus the control's intent:

| Layer | Source | Frequency | Amplitude |
|---|---|---|---|
| Intent | `target_direction` + `target_weight` | discrete changes | full |
| Drift | 3D simplex noise on time | 0.2–0.5 Hz | 10–30 cm |
| Breath | sinusoid, modulates girth | 0.3 Hz | ±3% girth |
| Writhe | high-freq noise per-particle, injected as small forces | 2–5 Hz | 1–3 cm |
| Curiosity | weak pull toward nearest `PointOfInterest` | continuous | 5–10% of intent |

Each layer is independent. Noise seeds persist across scenario transitions — layers don't reset when the AI changes its mind, they keep their character.

**Autonomy envelope:** layers 2–5 are always on. Player input only modulates the `intent` layer's weight and direction. Release input → intent decays over ~1s → layers 2–5 continue at full. Tentacle never freezes.

## A3. The AI is parameter drift

No behavior tree. No state machine. Just:

1. **Utility scorer** picks a scenario preset every 0.3–2.0 seconds (randomized)
2. **Interpolation** smoothly lerps parameters toward the new preset over ~0.5–2s
3. **Noise** applied on top of the interpolating parameter values (noise on setpoint of a noisy controller)
4. **Noise seeds persist** across scorer decisions

The compounded noise is why the system produces infinite variation. Same preset twice never plays out the same way.

Per-tentacle AI loop:
```
every 0.3–2.0 seconds (randomized):
    for each scenario preset:
        score against current context
    pick highest-scoring preset (with some randomization)
    begin lerping parameters toward the new preset

each tick:
    update lerping interpolation
    apply noise on top of current lerped values
    write resulting TentacleControl for solver
```

## A4. Scenario presets

Scenarios are **named points in parameter space**, not discrete states. Twelve starting presets; the system supports arbitrarily many more as data.

| # | Name | `depth` | `target_w` | `stiff` | `girth` | `lube` | `axial_v` | `noise` |
|---|---|---|---|---|---|---|---|---|
| 1 | Prowl | −0.4 ± 0.3 | 0.3 | 0.3 | 1.0 | 0.6 | 0 | 0.7 |
| 2 | First Contact | 0.0 ± 0.1 | 0.4 | 0.5 | 1.0 | 0.4 | 0.15 | 0.5 |
| 3 | Slow Insertion | 0.0→0.5 ramp | 0.6 | 0.6 | 1.0 | 0.6 | 0.2 | 0.3 |
| 4 | Pumping | 0.6 ± 0.3 sin | 0.7 | 0.7 | 1.0 | 0.7 | ±0.5 sin | 0.2 |
| 5 | Thrash | 0.5 ± 0.5 | 0.4 | 0.4 | 1.0 | 0.7 | noisy | 1.0 |
| 6 | Deep Writhe | 0.9 ± 0.05 | 0.3 | 0.2 | 1.0 | 0.8 | 0 | 0.8 |
| 7 | Lock | 0.7 fixed | 0.8 | 0.9 | 1.05 | 0.2 | 0 | 0.15 |
| 8 | Forced Stretch | 0.0→0.4 slow | 0.9 | 0.9 | 1.6 | 0.3 | 0.3 | 0.2 |
| 9 | Bulb Sequence | staged 0→0.9 | 0.8 | 0.7 | 1.0 | 0.5 | 0.4 | 0.3 |
| 10 | Curved Reach | 0.8 | 0.2 | 0.8 | 1.0 | 0.7 | 0 | 0.5 |
| 11 | Withdrawal | 0.7→0.0 slow | 0.6 | 0.5 | 1.0 | 0.4 | −0.15 | 0.3 |
| 12 | Recovery | 0.3 ± 0.2 | 0.3 | 0.3 | 0.9 | 0.9 | ±0.1 | 0.5 |
| 13 | Free Float | 0 fixed | 0.0 | 0.15 | 1.0 | 0.8 | 0 | 1.0 |

Brief descriptions:
- **Prowl** — never commits; wanders near entry
- **First Contact** — tip presses at rim, no penetration
- **Slow Insertion** — deliberate entry, long duration
- **Pumping** — rhythmic, the "stable center" scenario that others branch from
- **Thrash** — chaos, use sparingly
- **Deep Writhe** — serpentine motion inside, shines with curved tunnels
- **Lock** — stops moving, orifice grip engages, the scariest-feeling scenario
- **Forced Stretch** — inflated girth forces entry against resistance, accumulates damage
- **Bulb Sequence** — only valid for bulbed tentacles; staccato pops at each bulb
- **Curved Reach** — stiff tentacle pushing through curved internal anatomy
- **Withdrawal** — retraction, breaks through grip if engaged, produces snap
- **Recovery** — post-encounter settling, reduced stiffness, gentle
- **Free Float** — no target-pull, very low stiffness, high noise, full lubricity. Used by excreted tentacles post-expulsion (`TentacleTech_Architecture.md §6.9`) in zero-G or low-gravity environments. Tentacle drifts and writhes under its own noise layers with no directional intent.

Presets are `ScenarioPreset` resources (GDScript). Designers add/tune without touching C++.

## A5. The utility scorer

```
each scoring tick (every 0.3–2.0 seconds, randomized):
    context = ScenarioContext{
        current_engagement_depth,
        actual_engaged_orifice,            // may differ from target — see below
        orifice_grip_engagement,
        orifice_damage,
        orifice_wetness,
        time_in_current_scenario,
        hero_struggle_intensity,           // from ragdoll velocity magnitude
        tentacle_is_bulbed,
        ...
    }
    
    for each scenario s:
        scores[s] = score_function[s](context) + random_noise()
    
    // Large penalty for "same scenario for too long" built into scoring
    new_scenario = argmax(scores)
    begin_transition(new_scenario)
```

**Key rule:** the scorer reads *actual* current state, not plan state. If the tentacle intended to enter orifice T but slipped into orifice N (see Scenario 1 below), the scorer sees `actual_engaged_orifice = N` and picks a scenario appropriate to being in N. No explicit "oops, wrong orifice" logic needed.

Scoring weights per scenario: ~5 lines each. Examples:
- Prowl: higher when `current_engagement_depth < 0` and `time_in_current_scenario > 3`
- Lock: higher when `grip_engagement > 0.5` and `hero_struggle < 0.3`
- Thrash: higher when `hero_struggle > 0.7`
- Bulb Sequence: `-infinity` if `!tentacle_is_bulbed`
- Free Float: `+infinity` for freshly-excreted tentacle-root beads for a `post_expulsion_period` (5–10 s), decays to normal scoring afterward.

## A6. Transition smoothing

When the scorer picks a new preset, all parameters lerp toward new values over ~0.5–2s (scenario-dependent). Faster for Thrash (0.3s), slower for Recovery (3s).

Noise seeds are unchanged by transitions — drift and writhe continue their character through the transition. This is what makes transitions feel natural rather than cutting between states.

## A7. Player control

Player overrides a subset of `TentacleControl` each frame. Automation continues writing the rest:

| Parameter | Player | Automation |
|---|---|---|
| `target_direction` | mouse/stick | — |
| `engagement_depth` | trigger | — |
| `target_weight` | fixed high with input | decays on release |
| `axial_velocity_bias` | derivative of depth | — |
| `girth_modulation` | button toggle | — |
| `stiffness` | button toggle | — |
| `lubricity` | — | context-driven |
| `noise_amplitude` | reduced to ~0.3 during input | full when idle |

Result: macro motion player-controlled, micro motion always alive, seamless handoff at input release/resume.

## A8. Physical properties per tentacle and orifice

Beyond the runtime `TentacleControl`, each tentacle and orifice has authored physical properties.

### TentacleType resource

**Mechanical** (contact feel):

| Property | Range | Effect |
|---|---|---|
| `girth_stiffness` | 0.1–10 | Resistance to radial compression |
| `axial_stiffness` | 0.1–10 | Resistance to axial compression |
| `bending_stiffness` | 0.1–1.0 | PBD bending constraint stiffness |
| `target_pull_stiffness` | 0.05–0.3 | Tip target-pull stiffness (can differ from bending — "soft-tipped spear" etc.) |
| `mass_per_length` | kg/m | Inertia; heavy tentacles drag the ragdoll harder on friction contact |
| `surface_friction` | 0–2 | Coulomb coefficient |
| `surface_pattern` | enum | smooth / ribbed / barbed / sticky |
| `rib_frequency` | Hz/arc-length | Spatial rib rate (if ribbed) |
| `rib_depth` | 0–1 | Friction oscillation amplitude |
| `lubricity` | 0–1 | Multiplicative friction reduction |
| `adhesion_strength` | 0–0.5 | Additive friction from stickiness |
| `mesh` | ArrayMesh | Visual mesh (girth profile auto-baked) |

**Behavioral** (how the AI plays it):

| Property | Range | Effect |
|---|---|---|
| `scorer_bias` | Dict[ScenarioPreset → float] | Multiplier on each preset's score; defines personality (patient hunter, aggressor, holder, etc.) |
| `preset_whitelist` | Array[ScenarioPreset] | If non-empty, only these presets are eligible |
| `preset_blacklist` | Array[ScenarioPreset] | Always excluded from eligibility |
| `orifice_preference` | Dict[OrificeTag → float] | Weight over orifice tags for target selection |
| `sensory_responsiveness` | 0–1 | How strongly scorer reads Reverie state back (reactive vs. unaware) |
| `attachment_preference` | 0–1 | Weight for type-6 attachments vs. penetration-seeking target pulls |

**Emotional coupling** (Reverie):

| Property | Range | Effect |
|---|---|---|
| `state_gain_bias` | Dict[StateId → float] | Multiplier on specific Reverie state gain rates during this tentacle's contact events |
| `mindset_drift_bias` | Dict[MindsetAxis → float] | Per-axis drift rate bias while this tentacle is engaged with hero |
| `reaction_profile_tag` | StringName | Selector key Reverie uses to branch reaction profiles (distinct voice / face for distinct type) |

**Presentation:**

| Property | Effect |
|---|---|
| `mechanical_sound_bank` | AudioStreamBank | Per-type sound samples (squelch, creak, slap, etc.) consumed by `MechanicalSoundEmitter` |
| `shader_identity` | ShaderParams | Per-type material knobs (translucency, bioluminescence, flush-on-arousal color) |

### OrificeProfile resource

| Property | Range | Effect |
|---|---|---|
| `rest_radius` | m | Unstressed opening |
| `max_radius` | m | Beyond this, damage accumulates |
| `stretch_stiffness` | 10–1000 N/m | Linear spring |
| `stretch_nonlinearity` | 1–4 | Exponent; >1 = tissue-like stiffening |
| `angular_compliance` | 0–1 | 0 = rigid ring, 1 = fully independent directions |
| `grip_strength` | 0–100 N | Active contraction force |
| `grip_onset_time` | s | Ramp time for grip engagement |
| `wetness` | 0–1 | Friction multiplier (reduces) |
| `wetness_accumulation_rate` | rate | From external friction |
| `wetness_passive_rate` | rate | From linked body area arousal (Reverie) |
| `damping` | 0–1 | Ring bone oscillation damping |
| `ring_spring_k` | 100–400 | Ring bone spring stiffness |
| `ring_damping` | 5–20 | Ring bone damping |
| `drag_coupling` | 0–0.7 | Axial ring deformation from friction |
| `damage_threshold` | m | Stretch at which damage accumulates |
| `recovery_rate` | 1/s | Damage decay |
| `max_concurrent_tentacles` | 1–3 | Hard cap on simultaneous |
| `suppressed_bones` | List | Ragdoll capsules to hide from tentacles during interaction |
| `linked_body_areas` | List | For arousal → wetness coupling |
| `interior_surface_material` | enum | Typically "mucosa" |

---

# Part B — Narrative Scenarios

Ten scenarios, each a beat-by-beat physics-emergent story. Every beat is annotated with the architecture rule that produces it. **These double as acceptance tests** — if the system is implemented correctly, each scenario should play out when initial conditions are set up, without any scripted logic.

---

## Scenario 1 — Slip to the Neighbor

A tentacle aims at one orifice but geometry and resistance route it into an easier adjacent one.

### Setup
- Tentacle A: uniform girth 1.2× target orifice rest_radius, `stiffness = 0.8`, `target_weight = 0.6`, `lubricity = 0.5`
- Target Orifice T: small, `rest_radius = small`, `stretch_stiffness = 500`, `stretch_nonlinearity = 3`
- Neighbor Orifice N: ~15cm laterally offset from T, larger, `stretch_stiffness = 80`, `stretch_nonlinearity = 1.5`
- Approach angle: ~20° oblique
- AI scenario: Slow Insertion targeting T

### Beats
1. Tentacle advances; tip aimed at T (→ target-pull constraint)
2. Tip contacts T's rim off-center due to oblique angle (→ geometry)
3. `EntryInteraction` with T created; `center_offset` large (→ §6.2 lifecycle)
4. Radial pressure from nonlinear stretch curve hits hard (→ §6.3 bilateral compliance)
5. Wedge component: `tan(20°)` adds to axial reaction; tentacle can't advance (→ §6 wedge mechanics)
6. Tentacle's `girth_scale` drops slightly (mild squash); high stiffness keeps most deformation on orifice side (→ §6.3)
7. Asymmetric pressure (off-center contact) produces lateral force on tentacle (→ §6.3 unbalanced ring)
8. Tentacle tip slides laterally along T's rim (→ PBD constraint equilibrium)
9. Noise drift pushes tip further along slide direction (→ §A2 noise layers)
10. Tip crosses into N's entry plane (→ §6.2 orifice detection)
11. N has lower stiffness, compression small, resistance low (→ §6.3)
12. Existing `axial_velocity_bias` now produces forward motion (→ same force, less resistance)
13. T's `EntryInteraction` decays (no contact); N's becomes active (→ §6.2 lifecycle)
14. AI scorer next tick: sees `target_orifice = T`, `actual_engaged_orifice = N`. Updates target to N; picks Pumping. (→ §A5 scorer on actual state)

### Outcome
Tentacle ends up pumping in N. T unpenetrated. No scripted "oops" logic — emerged from off-center contact producing lateral force + noise pushing tip across threshold.

---

## Scenario 2 — The Bulb That Wouldn't Let Go

Bulbed tentacle enters easily, catches on retraction. Grip amplifies the catch.

### Setup
- Tentacle B: bulbed tip, shaft girth = 0.8× rest_radius, bulb peak = 1.4×, bulb at arc-length 0.15 (near tip), `stiffness = 0.5`, `lubricity = 0.7`
- Orifice: medium, `stretch_stiffness = 150`, `stretch_nonlinearity = 2`, `grip_strength = 20 N`, `grip_onset_time = 0.8s`
- AI: Slow Insertion → Lock → Withdrawal

### Beats
1. Shaft enters freely (shaft girth < rest_radius) (→ no contact)
2. Bulb reaches entry plane at `engagement_depth` ≈ 0.85 (→ depth tracking)
3. `girth_at_entry` samples bulb arc-length, returns 1.4 (→ §5.4 auto-baked profile)
4. Nonlinear stretch ramps hard; pressure spike on rim particles (→ §6.3)
5. Rim particles stretch outward to accommodate; skin around orifice distends; ragdoll gets inward impulse (→ §6.4 + reaction forces)
6. Bulb passes entry plane; rim particles snap back toward rest; ragdoll gets brief outward impulse (→ §6.4 rim particle dynamics)
7. Shaft inside; tentacle settles at `engagement_depth = 0.95`
8. AI transitions to Lock (→ §A4)
9. Orifice detects stationarity; `grip_engagement` ramps from 0 to 1 over 0.8s (→ §6.2 persistent state)
10. Rim particles actively contract below rest radius onto thin shaft via reduced `target_enclosed_area` (→ §6 grip)
11. AI transitions to Withdrawal; `axial_velocity_bias = -0.15`
12. Shaft slides easily on retreat (thin, moderate friction) (→ §4.4)
13. Bulb approaches entry from inside; compression returns (→ §5.4 profile sampling)
14. Ring must re-stretch for bulb to exit — but grip is still engaged, actively pulling inward (→ §6.2)
15. Static friction engages (normal force × μ × static multiplier). Tentacle held (→ §4.3)
16. Accumulating target-pull force eventually exceeds static cone (→ §4.3)
17. **Snap release.** `in_stick_phase` flips; bulb exits; rim whips back; ragdoll gets sharp outward impulse (→ §4.3 + §6.4)
18. Tentacle retracts freely; `grip_engagement` decays (→ §6 grip)

### Outcome
Insertion = single pressure pulse. Retraction = held moment + snap. Geometric symmetry, asymmetric behavior due to grip hysteresis.

---

## Scenario 3 — Wedge Lock

Oblique thrust gets stuck. Harder = worse. AI repositions.

### Setup
- Tentacle C: uniform `girth = 1.1×`, `stiffness = 0.9`, `lubricity = 0.3`
- Orifice: medium, `stretch_stiffness = 300`, `grip_strength = 0`
- Approach angle: 50°
- AI: Forced Stretch

### Beats
1. Tentacle approaches at 50°, high `target_weight`, `axial_velocity_bias = 0.3`
2. Tip contacts rim; `center_offset` large; `approach_angle_cos ≈ 0.64` (→ §6.2)
3. Wedge: `axial_reaction += radial_pressure × tan(50°) ≈ × 1.19` (→ wedge mechanics)
4. High stiffness means tentacle doesn't bend to align; whole length resists
5. Pressure accumulates at contact; asymmetric rim particle displacement (→ §6.3)
6. Tentacle `asymmetry` grows — directional squeeze (→ §3.4)
7. Ragdoll gets strong lateral push (→ §6 reaction forces)
8. AI noise perturbs tip laterally but wedge geometry converts axial effort → lateral rim pressure
9. **Deadlock:** higher axial effort → more wedge force → more rim pressure → no forward motion
10. Rim particles on contact side cross `damage_threshold`; damage accumulates (→ §6 damage)
11. Tentacle asymmetry caps at 0.5 magnitude; visible flattening (→ §3.4 + §5.3 vertex shader)
12. Hero struggle rises from continuous lateral force; scorer detects via ragdoll velocity (→ §A5)
13. Scorer picks Withdrawal (pinned config scores worse over time)
14. Tentacle retracts; rim whips back; damage persists (→ §6)
15. Orifice's per-rim-particle effective rest position is now larger on contact side than opposite (→ per-particle damage)
16. Subsequent attempt from different angle finds asymmetric resistance — different feel

### Outcome
Failed penetration with permanent consequence. Orifice "remembers" asymmetric stretch. Later attempts encode state history.

---

## Scenario 4 — Grip Surprise

Tentacle rests thinking idle. Orifice quietly locks on. Next attempt at motion, tentacle is held.

### Setup
- Tentacle D: uniform `girth ≈ rest_radius`, `stiffness = 0.3`, `lubricity = 0.4`
- Orifice: medium, `stretch_stiffness = 150`, `grip_strength = 60 N`, `grip_onset_time = 1.0s`
- AI: Deep Writhe → ...

### Beats
1. Tentacle at `engagement_depth = 0.9`, `noise_amplitude = 0.8`, writhing slowly (→ Deep Writhe preset)
2. `noise_frequency_mix` weighted toward drift (low freq); motion is slow serpentine
3. Scorer picks Lock (low hero struggle, deep engagement, time > threshold) (→ §A5)
4. Transition: `target_weight → 0.8`, `noise_amplitude → 0.15`, `stiffness → 0.9` over 1.5s
5. With low noise, only breath layer remains; tentacle effectively still
6. Orifice: `axial_velocity ≈ 0`; `grip_engagement` begins ramping (→ §6.2)
7. Over 1 second, engagement reaches ~1; ring contracts below rest onto tentacle (→ §6 grip)
8. Effective friction boosted by grip (→ §4.4 grip modulation)
9. Scorer next tick: hero struggling (raised ragdoll velocity); rolls Thrash (→ §A5 reactive)
10. Thrash: `axial_velocity_bias` noise, `target_direction` noise both up
11. Tentacle wants to move; particles near entry have high applied force but static friction holds (→ §4.3 stick)
12. Target pulls tip; tentacle bends around the pinned entry particles (→ PBD)
13. Eventually applied force exceeds static limit. Break (→ §4.3)
14. Tentacle snaps free; ring whips back from grip position (→ §6.4 spring)
15. Ragdoll gets sharp impulse from whip-back (→ §4.3 reaction)
16. `grip_engagement` decays over 1s (→ §6 grip disengage)

### Outcome
Emergent "captured" moment from Lock + grip dynamics. Subsequent struggle must break grip to proceed. System doesn't understand "capture" — it just happens.

---

## Scenario 5 — Two Tentacles, One Orifice

Two tentacles converge on the same target. Multi-tentacle support handles it naturally.

### Setup
- Tentacle E: uniform, moderate girth, approaching from left
- Tentacle F: uniform, slightly thicker, approaching from right, 0.3s behind E
- Orifice: small, `stretch_stiffness = 200`, `max_concurrent_tentacles = 3`
- Both AI: Slow Insertion targeting this orifice

### Beats
1. Both tentacles move toward entry (→ both scorers independently picked same target)
2. E arrives first; `EntryInteraction(E, O)` created (→ §6.2)
3. E's tip crosses plane; ring stretches (→ §6.3)
4. F's tip arrives 0.3s later at entry plane
5. F's `EntryInteraction(F, O)` created (→ §6.5 multi-tentacle list)
6. Directional ring radius = `max` over both tentacles in each direction (→ §6.5)
7. Since both want the center, they can't both be there. Particle-vs-particle collision inside orifice activates (→ §4.2 type 5, always on inside orifices)
8. E and F particles push apart laterally; both develop `center_offset` away from center (→ §6.5 separation)
9. Ring demand is max over their separated positions — stretches asymmetrically, wider than either alone (→ §6.5)
10. Each tentacle experiences asymmetric compression from the ring (squeeze on outer side, other tentacle on inner side) (→ §6.3)
11. Both tentacles develop `asymmetry` pointing toward the inter-tentacle axis (→ §3.4)
12. Both visibly squished against each other inside a maximally-stretched ring

### Outcome
Two tentacles inside one orifice, physically fighting for space, both asymmetrically deformed. Multi-tentacle aggregation + particle-particle separation handles it; no special code.

---

## Scenario 6 — Fighting the Curve

Stiff tentacle deep in curved tunnel presses against outer wall. Bulge migrates under skin as tentacle breathes.

### Setup
- Hero with tunnel curving 60° through torso
- Tentacle G: uniform, `stiffness = 0.8`, `axial_velocity_bias = 0`, at `engagement_depth = 0.9`
- AI: Curved Reach

### Beats
1. Tentacle particles inside tunnel; projected onto tunnel spline with radius tolerance each tick (→ §6 tunnel constraint)
2. At curve, tunnel bends 60°; tentacle bending constraint (stiffness 0.8) wants to straighten; tunnel constraint forces correction (→ §6 stiffer than bending)
3. Correction magnitude per curve particle = `wall_pressure_at_t` (→ §6)
4. Wall pressure distributed to ragdoll bones via `tunnel_bone_weights` (→ §6)
5. `SkinBulgeDriver` samples tentacle's actual spline (not tunnel centerline) — spline is slightly offset toward outer curve (→ §7.2)
6. Bulgers appear at outer wall of curve; skin displaces there (→ §7 normal-direction displacement)
7. Visible bulge on hero's body along outer anatomical curve
8. Breath layer oscillates girth at 0.3 Hz; girth variations change pressure (→ §A2)
9. Writhe layer perturbs particles within tunnel tolerance; they shift laterally (→ §A2)
10. As noise shifts tentacle laterally inside tunnel, "outer wall" it presses on rotates around the tunnel (→ §6 projection finds nearest wall)
11. Bulger positions shift; skin bulge migrates around circumference (→ §7.4)
12. Ragdoll bones associated with curve region get varying force vectors; torso sways (→ §6 tunnel-bone distribution)

### Outcome
Continuous visible activity from a tentacle that's supposedly stationary. Curved tunnel converts idle noise into migrating anatomical pressure. Main payoff of curved tunnels.

---

## Scenario 7 — Probing for Fit

Too-large tentacle probes repeatedly at varying angles. Each attempt adds damage. Eventually one succeeds.

### Setup
- Tentacle H: uniform `girth = 1.3× rest_radius`, `stiffness = 0.7`, `lubricity = 0.5`
- Orifice: small, `stretch_stiffness = 400`, `stretch_nonlinearity = 2.5`, `damage_threshold = modest`, `recovery_rate = slow`
- AI: First Contact → Slow Insertion loops

### Beats
1. First Contact: tip presses at entry with slight axial bias
2. Compression immediate (oversized); nonlinear stretch makes resistance severe (→ §6.3)
3. Scorer rolls Slow Insertion after First Contact establishes sustained contact
4. Ramps axial force; ring stretches hard but not enough (→ compression geometry)
5. Rim approaches `damage_threshold`; damage accumulates on contact-side rim particles (→ §6 damage)
6. Hero struggle / noise breaks contact; scorer picks Prowl (→ §A5)
7. Tentacle retreats; rim recovers to rest; damage persists (→ §6 recovery_rate slow)
8. Prowl briefly; scorer picks Slow Insertion again; noise gives slightly different angle (→ §A2 target noise)
9. New contact point rotated angularly; rim particles at the new contact location have slightly elevated rest positions from earlier damage (→ §6 per-particle damage)
10. Resistance marginally lower at this rim location
11. Attempt fails again, adds damage at new rim particles
12. Several attempts later, orifice's effective rest configuration is elevated across multiple rim particles (→ aggregate damage)
13. Eventually compression below force budget; tentacle passes through (→ §6.3)
14. Rim stretches maximally but accepts; penetration occurs

### Outcome
Scripted-looking "keeps trying until success" sequence with zero scripting. Damage accumulation + repeated scoring + noise-varied angles produce it naturally. Different every run.

---

## Scenario 8 — Rib Resonance

Ribbed tentacle in rhythmic motion hits resonance with orifice ring. Whole system locks into visible pulsing.

### Setup
- Tentacle I: ribbed, `rib_frequency` several Hz/arc-length, `rib_depth = 0.15`
- Orifice: `stretch_stiffness = 200`, low solver damping per loop (underdamped)
- AI: Pumping with rib-pass frequency near ring natural frequency

### Beats
1. Pumping drives axial velocity sinusoidally; ribs pass through ring region (→ §A4 Pumping preset)
2. Rib friction coefficient modulates sinusoidally as ribs pass (→ §4.4 rib modulation)
3. Friction spikes → axial force spikes → rim particle radial impulses (→ §4.3)
4. Underdamped rim particles oscillate after each impulse (→ §6.4 rim particle dynamics; tune via per-loop compliance + solver damping)
5. Next rib timing may reinforce or cancel — depends on match between rib-pass freq and rim natural freq (→ physics resonance)
6. If matched: resonance builds; rim amplitude grows per rib pass (→ driven oscillator)
7. Rim particles pulse rhythmically far exceeding what girth alone would produce (→ emergent amplitude)
8. Ragdoll gets increasingly strong rhythmic impulses (→ §4.3 reaction)
9. AI has no concept of resonance; continues Pumping
10. Eventually either noise perturbs frequency off resonance OR scorer picks new scenario
11. Resonance decays (underdamped but damped) (→ §6.4)

### Outcome
Physical resonance phenomenon. No code "knows" about it — it falls out of rib friction + rim particle dynamics. **Design risk:** tune per-loop compliance + global solver damping carefully or resonance can look ugly. Playtest ribbed tentacles early.

---

## Scenario 9 — Cascade from a Broken Grip

One grip breaks; ragdoll moves; other tentacles' interaction geometry shifts mid-action. System handles without replanning.

### Setup
- Hero held by 3 tentacles: J (wrist grab via attachment), K (orifice #1, Pumping), L (orifice #2, Lock)
- Hero actively struggling (ragdoll velocity nonzero)

### Beats
1. J's attachment has `grip_engagement ≈ 1.0`; arm bone pulled taut (→ §4.2 type 6 attachment)
2. Hero struggle increases; wrist velocity rises; tangential force exceeds J's static cone (→ §4.3)
3. J's attachment slips; accumulated slip crosses threshold; detaches (→ §4.2)
4. Freed arm snaps under gravity + momentum (→ ragdoll physics)
5. Arm motion propagates through ragdoll chain; shoulder and torso shift
6. Orifices #1 and #2 (torso-parented) shift in world space (→ orifice parented to skeleton)
7. K mid-Pumping; its target was at fixed world position; orifice just moved (→ target lag)
8. K's PBD sees particles' positions no longer align with entry; tunnel constraint projects differently (→ §6.2 geometric state refresh)
9. K's target pull still active at old position; creates conflict with new geometry; lateral force spike (→ constraint fight)
10. K's rim particles get asymmetric stress (→ §6.3)
11. K's scorer next tick: reads new actual state; updates target; interpolates to corrected target over 0.5s (→ §A5 current-state scoring)
12. L's grip engagement was holding; relative velocity broke it briefly (→ §6 grip)
13. L's disengagement produces release impulse; further perturbs torso (→ §4.3)
14. System settles over ~1s as scorers catch up, ragdoll damps

### Outcome
Cascade handled without any "replan" code. Every tentacle solver reads current state each tick. Global effect emergent. Plan-based AI would hitch visibly; current-state AI doesn't.

---

## Scenario 10 — Successful Penetration with Course Correction

The "slip then notice and adapt" sequence.

### Setup
- Tentacle M: `target_weight = 0.5`, `stiffness = 0.8`, `lubricity = 0.5`
- Target Orifice T: small, high resistance, `stretch_stiffness = 500`
- Neighbor Orifice N: larger, `stretch_stiffness = 150`
- AI: Slow Insertion targeting T

### Beats
1. Tentacle advances toward T, `axial_velocity_bias = 0.2`, high stiffness (→ bending constraint)
2. Moderate noise perturbs target_direction and writhe (→ §A2)
3. Tip contacts T; nonlinear resistance exceeds force budget (→ §6.3)
4. Slight squash; high stiffness puts most deformation on orifice side (→ §6.3)
5. Tentacle bends slightly — tip blocked, rear particles still advancing (→ PBD)
6. Asymmetric pressure; net lateral force on tip (→ §6.3)
7. Noise drift pushes `target_direction`; tip slides along T's rim
8. Rim slopes toward N; tip slides down under combined axial + lateral force (→ geometry)
9. Tip crosses into N; `EntryInteraction(M, N)` created (→ §6.2)
10. N compliant; compression small; existing axial bias produces forward motion (→ §6.3)
11. Particles advance; tunnel constraint engages; depth increases (→ §6 tunnel)
12. Scorer next tick: `target_orifice = T`, `actual_engaged_orifice = N`, `engagement_depth = 0.3`. Penetration successful, wrong target (→ §A5)
13. Scorer weighs: Slow Insertion (targeting N now) vs retreat-and-retry. Picks continuation.
14. New preset: `target_orifice = N`, `noise_amplitude` lerps down (0.5→0.3), `stiffness` lerps down (0.8→0.6) (→ §A6 smoothing)
15. Tentacle deliberately advances; N's tunnel accepts; skin bulges move inward (→ §7)
16. At `engagement_depth ≈ 0.7`, scorer considers Pumping or Deep Writhe

### Outcome
The user's described sequence plays out. Tentacle *notices* penetration via scorer seeing `actual_engaged_orifice`. *Decreases noise amplitude* via preset transition. *Carefully advances* via maintained axial bias + reduced noise. All emergent from scorer reading current state and interpolating to appropriate preset.

---

## Scenario 11 (future) — All-the-way-through

A tentacle entering one orifice traverses and exits through a second orifice on the same hero. Acceptance test for `TentacleTech_Architecture.md §6.7` through-path tunnels. Specify once §6.7 implementation lands; use as Phase 8+ validation.

## Scenario 12 (future) — Oviposition cycle

An ovipositor-type tentacle enters an orifice, deposits 2–3 sphere beads into the tunnel over the course of an interaction, then withdraws. Beads remain visible via bulger-driven outer-skin and cavity-wall deformation. Acceptance test for §6.8 storage chain and §6.9 oviposition. Use as Phase 8+ validation.

## Scenario 13 (future) — Excreted tentacle, free float

A previously-stored tentacle-root bead is expelled through the orifice via Reverie-driven peristalsis; on full exit, it transitions to a free `Tentacle` with the Free Float scenario preset. In zero-G, it drifts and writhes under layered noise with no anchor. Acceptance test for §6.9 tentacle-bead release and A4 Free Float preset. Use as Phase 8+ validation.

---

## B11. How to use these scenarios

### As acceptance tests
After each phase completes, verify relevant scenarios play out. Phase 5 (orifice) unlocks 1, 2, 3, 4, 7. Phase 6 (bus) doesn't break anything. Phase 7 (bulges) is visible in 2, 4, 6. Phase 8 (multi-tentacle, curved tunnels, attachments) unlocks 5, 6, 9.

### As AI tuning references
If a scenario doesn't play out as described, either scorer weights are wrong or noise isn't varied enough. Trace which.

### As content authoring seeds
A designer picks a scenario, sets up geometry, runs the encounter. System produces the narrative from parameters. Tweaking parameters creates variants.

### What they aren't
These are not exhaustive. The parameter-space × noise × scorer × history combinations produce effectively infinite sequences. These ten are chosen for illustrative range — one per major rule set.
