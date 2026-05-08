---
name: Godot import dialog requires Reimport to persist
description: Subresource assignments (BoneMap, materials, etc.) live only in memory until Reimport is clicked
type: reference
originSessionId: 8cd7bbcd-da41-41ce-9720-84dcdcfcb091
---
When assigning subresources in Godot's GLB/scene import dialog (Skeleton3D → Bone Map, materials, animation tracks, etc.), the assignment is held only in the dialog's in-memory state. The `.import` sidecar's `_subresources={}` is not updated until the **Reimport** button at the top of the import dock is clicked.

**Symptom:** Assign a BoneMap via Quick Load → mappings render correctly in the dialog → close the import window → reopen it → assignment is gone, `_subresources={}` still empty in the sidecar. Looks identical to "my changes were discarded" but the BoneMap .tres on disk is fine.

**Verification:** `cat path/to/asset.glb.import | grep _subresources` — empty `{}` means nothing persisted; populated dict means Reimport was clicked.

**How to apply:** When walking a user through the import dialog, always include the explicit Reimport step. When debugging "my mapping disappeared after closing the window," check the .import sidecar before assuming files were corrupted.
