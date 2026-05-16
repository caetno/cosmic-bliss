@tool
class_name SurfaceJiggleAttachment
extends SurfaceAttachment

## Stub. Concrete bake() lands at §17.5 (Marionette jiggle migration).
##
## Authoring vision (§17.5 prompt): user places a Node3D under the hero
## scene at the jiggle's origin; `host_bone` names the bone the jiggle
## hangs off; the bake derives per-vertex skinning weight from the
## cotan-Laplacian diffusion seeded near the placement point.

func bake(_field) -> PackedFloat32Array:
	push_warning("SurfaceJiggleAttachment.bake() — stub; concrete impl lands at §17.5 (Marionette jiggle migration)")
	return PackedFloat32Array()
