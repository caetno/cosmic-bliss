# BoneMap Icon Resolution — Empirical Verification (PLAN P1.0)

## Purpose

`SkeletonProfileHumanoid` ships with `null` group textures. The silhouettes you see in Godot's BoneMap editor come from editor-theme SVGs (`BoneMapHumanBody` etc.), not profile data. This test disambiguates three hypotheses about how those icons actually get picked:

- **Option A (fallback)** — editor reads `profile.get_texture(group_idx)`; falls back to editor theme icon only if null.
- **Option B (hardcoded)** — editor ignores `profile.texture` for known built-in group names; always uses editor theme icons for those.
- **Option C (separate path)** — editor uses `profile.get_texture(group_idx)` exclusively; humanoid icons come from a `SkeletonProfileHumanoid`-specific path.

The outcome gates the P1.2 texture strategy and whether we need the P1.5 foot-group inspector supplement.

## How to run

1. Launch the Godot editor: `godot -e` from the project root.
2. In the FileSystem dock, navigate to `res://addons/marionette/data/`.
3. Double-click `bone_map_icon_test.tres` to open the BoneMap inspector.
4. Observe the group panels rendered at the top of the inspector.

Each of our six shipped test textures is a distinct solid color with a label — unmistakable if one of them renders.

| Group       | Shipped texture color | Label      |
|-------------|-----------------------|------------|
| `Body`      | red                   | "BODY custom"   |
| `Face`      | orange                | "FACE custom"   |
| `LeftHand`  | yellow                | "L HAND custom" |
| `RightHand` | green                 | "R HAND custom" |
| `LeftFoot`  | blue                  | "L FOOT custom" |
| `RightFoot` | purple                | "R FOOT custom" |

## Results

For each group, record one of:

- **custom** — our colored texture renders.
- **theme** — Godot's standard human silhouette renders instead of our texture.
- **blank** — nothing renders for this group.
- **missing** — the group panel itself does not appear.

| Group       | Rendered |
|-------------|----------|
| Body        |          |
| Face        |          |
| LeftHand    |          |
| RightHand   |          |
| LeftFoot    |          |
| RightFoot   |          |

## Decision matrix

| Body / Face / LeftHand / RightHand | LeftFoot / RightFoot | Option | P1.2 texture strategy |
|---|---|---|---|
| custom | custom | **A or C** | Assign all six via `set_texture()`. Optionally override built-ins with editor theme icons. P1.5 skipped. |
| theme  | custom | **A (fallback)** | Leave built-in four null (fall through to theme), assign foot textures via `set_texture()`. P1.5 skipped. |
| theme  | blank  | **B (hardcoded, new names unsupported)** | Do not assign any group textures. Built-ins use theme; LeftFoot/RightFoot blank in native UI. Ship P1.5 inspector supplement. |
| theme  | missing | **B' (group list filtered)** | Stronger form of B. Same conclusion: P1.5 supplement required. |

## Conclusion

- [ ] Option determined:
- [ ] P1.2 branch to take:
- [ ] P1.5 required:
- [ ] Date verified:
