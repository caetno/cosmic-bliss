---
name: Godot BoneMap property serialization
description: Authoring BoneMap .tres files by hand — correct property prefix and silent-overwrite gotcha
type: reference
originSessionId: 8cd7bbcd-da41-41ce-9720-84dcdcfcb091
---
Godot's `BoneMap` resource serializes per-bone source-name entries as `bone_map/<ProfileBoneName>` (with underscore), not `bonemap/<ProfileBoneName>`. Value type is StringName, written as `&"source_bone_name"` in .tres syntax. Empty/unmapped slots use `&""`.

**Silent failure:** If you author a BoneMap .tres with the wrong property name (e.g. `bonemap/Hips`), Godot's `_set` returns false → the entry is dropped → the inspector shows the BoneMap with everything unmapped. The first time the inspector touches the file, Godot resaves it in canonical form with all empty defaults, **destroying any malformed entries you had**. No error or warning is printed.

**Verification:** Open the deployed BoneMap once via the editor, then `head -20` the file. If you see `bone_map/<name> = &"<source>"` lines, the format is right. If you see `bone_map/<name> = &""` for every line and your file used `bonemap/`, Godot ate your data.

**Reference rig (Cosmic Bliss):** `extensions/marionette/gdscript/data/marionette_humanoid_bone_map.tres` is the canonical example — 78 mapped slots for the Kasumi ARP rig (`game/scenes/kasumi_local.tscn`, 116-bone source skeleton).
