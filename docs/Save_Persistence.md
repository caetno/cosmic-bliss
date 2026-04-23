# Save and Persistence

Single save file per profile. Versioned schema. Migrations run at load time. Minimal surface now; expand as subsystems stabilize.

## Scope

**Persistent across runs within a save, resets on new-game:**

- Mindset vector (6 axes; see `docs/architecture/Reverie_Planning.md §2.7`)
- Appearance state (see `docs/Appearance.md`)
- Accumulated currency (single type)
- Unlocked customization items
- Play stats (runs completed, total time)
- Discovered sensitivity-map areas per hero and stim accumulator (see `docs/Gameplay_Mechanics.md §3`)
- Unlocked `TentacleType`s and current loadout (see `docs/Gameplay_Mechanics.md §4`)
- Unlocked phenomenon achievements (see `docs/Gameplay_Mechanics.md §2`)

**Per-session, not saved:**

- Current run state (active scenarios, active `EntryInteraction`s, Reverie state distribution)
- Pending bus events, ring-buffer contents
- Mid-run resume is deferred; a new run always starts clean

## Format

Godot `.tres` or `ConfigFile`. Top-level `schema_version: int` plus one block per subsystem:

```
schema_version: 1
reverie: { mindset: [f, f, f, f, f, f], ... }
appearance: { body_blendshapes: {...}, wardrobe_equipped: <id>, decals: [...] }
economy: { currency: int, unlocks: [<id>, ...] }
stats: { runs_completed: int, total_time_seconds: float }
sensitivity_discovery: { <hero_id>: { discovered_areas: [...], stim_accumulator: {...} } }
loadout: { unlocked_tentacle_types: [...], current_loadout: [...] }
achievements: { unlocked: [<id>, ...] }
```

## Migration

Each schema-version bump ships a `migrate_v<N>_to_v<N+1>(data)` function. Load-time flow:

1. Read `schema_version`.
2. For each version older than current, apply the matching migration in order.
3. Missing fields receive authored defaults; unknown fields are dropped with a log warning.

Migrations are mandatory for any schema change that adds, removes, or renames a field. Treat the save format as a versioned interface, not an implementation detail.

## Out of scope

- Cloud sync
- Save encryption
- Multiple save slots per profile (single slot initially)
- Binary save format (`.tres` is fine for current size)
